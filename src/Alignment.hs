{-# LANGUAGE RankNTypes #-}
module Alignment
( hasChanges
, linesInRangeOfSource
, numberedRows
, splitAbstractedTerm
, splitDiffByLines
, Row
) where

import Control.Arrow
import Control.Comonad.Trans.Cofree
import Data.Functor.Foldable hiding (Foldable)
import Control.Monad
import Control.Monad.Trans.Free
import Data.Adjoined
import Data.Align
import Data.Bifunctor.These
import Data.Coalescent
import Data.Copointed
import Data.Foldable
import Data.Functor.Both as Both
import Data.Functor.Identity
import Data.Maybe
import Data.Monoid
import qualified Data.OrderedMap as Map
import qualified Data.Text as T
import Diff
import Info
import Line
import Patch
import Prologue hiding (first, fst, snd)
import qualified Prologue
import Range
import Source hiding (fromList, uncons)
import SplitDiff
import Syntax
import Term

-- | Assign line numbers to the lines on each side of a list of rows.
numberedRows :: [Row a] -> [Both (Int, Line a)]
numberedRows = countUp (pure 1)
  where countUp from (row : rows) = ((,) <$> from <*> row) : countUp ((+) <$> from <*> (lineIncrement <$> row)) rows
        countUp _ [] = []

-- | Determine whether a line contains any patches.
hasChanges :: Line (SplitDiff leaf Info) -> Bool
hasChanges = or . fmap (or . (True <$))

-- | Split a diff, which may span multiple lines, into rows of split diffs paired with the Range of characters spanned by that Row on each side of the diff.
splitDiffByLines :: Both (Source Char) -> Diff leaf Info -> [Row (SplitDiff leaf Info, Range)]
splitDiffByLines sources = toList . iter (\ (infos :< syntax) -> splitAbstractedTerm ((free .)  . (Free .) . (:<)) sources (infos :< syntax)) . fmap (splitPatchByLines sources)

-- | Split a patch, which may span multiple lines, into rows of split diffs.
splitPatchByLines :: Both (Source Char) -> Patch (Term leaf Info) -> Adjoined (Both (Line (SplitDiff leaf Info, Range)))
splitPatchByLines sources patch = wrapTermInPatch <$> splitAndFoldTerm (unPatch patch)
    where
      splitAndFoldTerm :: These (Term leaf Info) (Term leaf Info) -> Adjoined (Both (Line (Term leaf Info, Range)))
      splitAndFoldTerm (This deleted) = tsequenceL mempty $ both (runIdentity <$> cata (splitAbstractedTerm ((cofree.) . (:<)) (Identity $ fst sources)) (hylo (cofree . annotationMap Identity) runCofree deleted)) nil
      splitAndFoldTerm (That inserted) = tsequenceL mempty $ both nil (runIdentity <$> cata (splitAbstractedTerm ((cofree .) . (:<)) (Identity $ snd sources)) (hylo (cofree . annotationMap Identity) runCofree inserted))
      splitAndFoldTerm (These deleted inserted) = tsequenceL mempty $ both (runIdentity <$> cata (splitAbstractedTerm ((cofree  .) . (:<)) (Identity $ fst sources)) (hylo (cofree . annotationMap Identity) runCofree deleted)) (runIdentity <$> cata (splitAbstractedTerm ((cofree .) . (:<)) (Identity $ snd sources)) (hylo (cofree . annotationMap Identity) runCofree inserted))
      wrapTermInPatch = fmap (fmap (first (free . Pure . constructor patch)))
      constructor (Replace _ _) = SplitReplace
      constructor (Insert _) = SplitInsert
      constructor (Delete _) = SplitDelete

annotationMap :: (a -> b) -> TermF leaf a f -> TermF leaf b f
annotationMap f (a :< r) = f a :< r

-- | Split a term comprised of an Info & Syntax up into one `outTerm` (abstracted by an alignment function & constructor) per line in `Source`.
splitAbstractedTerm :: (Applicative f, Coalescent (f (Line (Maybe (Identity outTerm), Range))), Coalescent (f (Line (Maybe (T.Text, outTerm), Range))), Foldable f, TotalCrosswalk f) => (Info -> Syntax leaf outTerm -> outTerm) -> f (Source Char) -> CofreeF (Syntax leaf) (f Info) (Adjoined (f (Line (outTerm, Range)))) -> Adjoined (f (Line (outTerm, Range)))
splitAbstractedTerm makeTerm sources (infos :< syntax) = case syntax of
  Leaf a -> let lineRanges = linesInRangeOfSource <$> (characterRange <$> infos) <*> sources in
    tsequenceL (pure mempty)
      $ fmap <$> ((\ info -> fmap (\ range -> (makeTerm info { characterRange = range } (Leaf a), range))) <$> infos) <*> lineRanges
  Indexed children -> adjoinChildren sources infos (constructor (Indexed . fmap runIdentity)) (Identity <$> children)
  Fixed children -> adjoinChildren sources infos (constructor (Fixed . fmap runIdentity)) (Identity <$> children)
  Keyed children -> adjoinChildren sources infos (constructor (Keyed . Map.fromList)) (Map.toList children)
  where constructor with info = makeTerm info . with

-- | Adjoin a branch term’s lines, wrapping children & context in branch nodes using a constructor.
adjoinChildren :: (Copointed c, Functor c, Applicative f, Coalescent (f (Line (Maybe (c a), Range))), Foldable f, TotalCrosswalk f) => f (Source Char) -> f Info -> (Info -> [c a] -> outTerm) -> [c (Adjoined (f (Line (a, Range))))] -> Adjoined (f (Line (outTerm, Range)))
adjoinChildren sources infos constructor children = wrap <$> leadingContext <> lines
  where (lines, next) = foldr (childLines sources) (mempty, end <$> ranges) children
        ranges = characterRange <$> infos
        categories = Info.categories <$> infos
        sizes = size <$> infos
        leadingContext = tsequenceL (pure mempty) $ makeContextLines <$> (linesInRangeOfSource <$> (Range <$> (start <$> ranges) <*> next) <*> sources)
        wrap = (wrapLineContents <$> (makeBranchTerm constructor <$> categories <*> sizes <*> next) <*>)
        makeBranchTerm constructor categories size next children = let range = unionRangesFrom (rangeAt next) $ Prologue.snd <$> children in
          (constructor (Info range categories size) . catMaybes . toList $ Prologue.fst <$> children, range)

-- | Accumulate the lines of and between a branch term’s children.
childLines :: (Copointed c, Functor c, Applicative f, Coalescent (f (Line (Maybe (c a), Range))), Foldable f, TotalCrosswalk f) => f (Source Char) -> c (Adjoined (f (Line (a, Range)))) -> (Adjoined (f (Line (Maybe (c a), Range))), f Int) -> (Adjoined (f (Line (Maybe (c a), Range))), f Int)
-- We depend on source ranges increasing monotonically. If a child invalidates that, e.g. if it’s a move in a Keyed node, we don’t output rows for it in this iteration. (It will still show up in the diff as context rows.) This works around https://github.com/github/semantic-diff/issues/488.
childLines sources child (nextLines, next) | or ((>) . end <$> childRanges <*> next) = (nextLines, next)
                                           | otherwise = ((makeChildLines <$> copoint child)
                                                         <> tsequenceL (pure mempty) (makeContextLines <$> trailingContextLines)
                                                         <> nextLines, start <$> childRanges)
  where makeChildLines = fmap (fmap (first (Just . (<$ child))))
        trailingContextLines = linesInRangeOfSource <$> (Range <$> (end <$> childRanges) <*> next) <*> sources
        childRanges = unionRangesFrom <$> (rangeAt <$> next) <*> (concat . fmap (fmap Prologue.snd . unLine) <$> sequenceA (copoint child))

makeContextLines :: Adjoined (Line Range) -> Adjoined (Line (Maybe a, Range))
makeContextLines = fmap (fmap ((,) Nothing))

-- | Produce open/closed lines for the portion of the source spanned by a range.
linesInRangeOfSource :: Range -> Source Char -> Adjoined (Line Range)
linesInRangeOfSource range source = fromList $ pureBy (openRange source) <$> actualLineRanges range source

-- | Does this Range in this Source end with a newline?
openRange :: Source Char -> Range -> Bool
openRange source range = (at source <$> maybeLastIndex range) /= Just '\n'

-- | A row in a split diff, composed of a before line and an after line.
type Row a = Both (Line a)