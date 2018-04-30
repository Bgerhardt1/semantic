{-# LANGUAGE DeriveAnyClass, MultiParamTypeClasses, ScopedTypeVariables, UndecidableInstances #-}
module Data.Syntax.Directive where

import           Data.Abstract.Evaluatable
import           Data.Abstract.Module (ModuleInfo(..))
import qualified Data.ByteString.Char8 as BC
import           Diffing.Algorithm
import           Prologue

-- A file directive like the Ruby constant `__FILE__`.
data File a = File
  deriving (Diffable, Eq, Foldable, Functor, GAlign, Generic1, Mergeable, Ord, Show, Traversable, FreeVariables1, Declarations1)

instance Eq1 File where liftEq = genericLiftEq
instance Ord1 File where liftCompare = genericLiftCompare
instance Show1 File where liftShowsPrec = genericLiftShowsPrec

instance Evaluatable File where
  eval File = currentModule >>= string . BC.pack . modulePath
