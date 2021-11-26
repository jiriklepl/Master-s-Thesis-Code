{-# LANGUAGE Safe #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveDataTypeable #-}

module CMM.AST.Annot where

import safe Data.Functor
import safe Data.Data

data Annotation node annot =
  Annot (node annot) annot
  deriving (Show, Functor, Data)

deriving instance (Eq (n a), Eq a) => Eq (Annotation n a)

deriving instance (Ord (n a), Ord a) => Ord (Annotation n a)

type Annot = Annotation

type Annotated = Functor

withAnnot :: a -> n a -> Annot n a
withAnnot = flip Annot

takeAnnot :: Annot n a -> a
takeAnnot (Annot _ annot) = annot

unAnnot :: Annot n a -> n a
unAnnot (Annot node _) = node

updateAnnots :: Annotated n => (a -> b) -> n a -> n b
updateAnnots = fmap

stripAnnots :: Annotated n => n a -> n ()
stripAnnots = void
