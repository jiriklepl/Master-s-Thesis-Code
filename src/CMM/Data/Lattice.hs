{-# LANGUAGE Safe #-}

module CMM.Data.Lattice where

import safe qualified Data.Set as Set
import safe Data.Set (Set)
import safe qualified Data.Map as Map
import safe Data.Map (Map)

class Lattice a where
  (/\) :: a -> a -> a
  (\/) :: a -> a -> a

meet :: Lattice a => a -> a -> a
join :: Lattice a => a -> a -> a

meet = (/\)
join = (\/)

instance Lattice Bool where
  (/\) = (&&)
  (\/) = (||)

instance Ord a => Lattice (Set a) where
  (/\) = Set.intersection
  (\/) = Set.union

instance Ord k => Lattice (Map k v) where
  (/\) = Map.intersection
  (\/) = Map.union
