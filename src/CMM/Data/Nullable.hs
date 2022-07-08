{-# LANGUAGE Safe #-}

module CMM.Data.Nullable where

import safe Data.Map (Map)
import safe Data.Monoid (Sum)
import safe Data.Set (Set)

import safe CMM.Data.Bimap (Bimap)
import safe qualified CMM.Data.Bimap as Bimap
import safe qualified Data.Map as Map
import safe qualified Data.Set as Set

infixr 5 ??

-- | Like `Alternative`, but for values
class Fallbackable a where
  (??) :: a -> a -> a

-- | Class for object that have a `null`-like or empty value
class Nullable a where
  nullVal :: a

instance Fallbackable (Maybe a) where
  Nothing ?? a = a
  a ?? _ = a

instance Nullable (Maybe a) where
  nullVal = Nothing

instance Fallbackable Bool where
  (??) = (||)

instance Nullable Bool where
  nullVal = False

instance Nullable (Map k a) where
  nullVal = Map.empty

instance Nullable (Set k) where
  nullVal = Set.empty

instance Nullable (Bimap k a) where
  nullVal = Bimap.empty

instance Num a => Nullable (Sum a) where
  nullVal = mempty

instance Fallbackable (Either a b) where
  Left _ ?? a = a
  a ?? _ = a
