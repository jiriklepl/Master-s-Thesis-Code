{-# LANGUAGE Safe #-}

module CMM.Data.Function where

import safe Data.Bool (Bool, (&&), (||))
import safe Data.Function ( (&) )
import safe Data.Foldable ( Foldable(foldl') )

fOr :: (a -> Bool) -> (a -> Bool) -> a -> Bool
fOr f g x = f x || g x

fAnd :: (a -> Bool) -> (a -> Bool) -> a -> Bool
fAnd f g x = f x && g x

applyAll :: [a -> a] -> a -> a
applyAll fs a = foldl' (&) a fs
