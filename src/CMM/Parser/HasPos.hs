{-# LANGUAGE Safe #-}

-- TODO: rename to GetPos?
module CMM.Parser.HasPos
  ( HasPos(..)
  , SourcePos
  ) where

import safe Prelude

import safe Text.Megaparsec.Pos (SourcePos)

import safe CMM.AST.Annot (Annot, takeAnnot)

class HasPos a
  -- | Retrieves a SourcePos annotation from the given variable
  where
  getPos :: a -> SourcePos

instance HasPos SourcePos where
  getPos = id

instance HasPos a => HasPos (Annot n a) where
  getPos = getPos . takeAnnot

instance HasPos (SourcePos, b) where
  getPos (pos, _) = pos

instance HasPos (SourcePos, b, c) where
  getPos (pos, _, _) = pos

instance HasPos (SourcePos, b, c, d) where
  getPos (pos, _, _, _) = pos
