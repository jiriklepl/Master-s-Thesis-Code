{-# LANGUAGE Safe #-}

module CMM.Inference.TypeVar where

import safe Data.Bool (Bool(False, True), otherwise)
import safe Data.Data (Data)
import safe Data.Eq (Eq((==)))
import safe Data.Function ((.), id)
import safe Data.Int (Int)
import safe Data.Ord (Ord(compare), Ordering(EQ, GT, LT))
import safe Text.Show (Show)

import safe CMM.AST.Annot (Annot, takeAnnot)
import safe CMM.Data.Nullable (Fallbackable((??)), Nullable(nullVal))
import safe CMM.Data.Num (Num((+)))
import safe CMM.Inference.TypeKind
  ( HasTypeKind(getTypeKind, setTypeKind)
  , TypeKind(GenericType)
  , setTypeKindInvariantLogicError
  )

data TypeVar
  = NoType
  | TypeVar
      { tVarId :: Int
      , tVarKind :: TypeKind
      , tVarParent :: TypeVar
      }
  deriving (Show, Data)

typeVarIdLast :: TypeKind -> TypeVar -> Int -> TypeVar
typeVarIdLast kind parent int = TypeVar int kind parent

class FromTypeVar a where
  fromTypeVar :: TypeVar -> a

class ToTypeVar a where
  toTypeVar :: a -> TypeVar

instance ToTypeVar a => ToTypeVar (Annot n a) where
  toTypeVar = toTypeVar . takeAnnot

instance FromTypeVar TypeVar where
  fromTypeVar = id

instance ToTypeVar TypeVar where
  toTypeVar = id

instance Eq TypeVar where
  NoType == NoType = True
  TypeVar int _ _ == TypeVar int' _ _ = int == int'
  _ == _ = False

instance Ord TypeVar where
  NoType `compare` NoType = EQ
  TypeVar int _ _ `compare` TypeVar int' _ _ = int `compare` int'
  NoType `compare` _ = LT
  _ `compare` NoType = GT

instance Fallbackable TypeVar where
  NoType ?? tVar = tVar
  tVar ?? _ = tVar

instance Nullable TypeVar where
  nullVal = NoType

instance HasTypeKind TypeVar where
  getTypeKind =
    \case
      NoType {} -> GenericType
      TypeVar _ kind _ -> kind
  setTypeKind kind =
    \case
      t@NoType {}
        | kind == GenericType -> NoType {}
        | otherwise -> setTypeKindInvariantLogicError t kind
      tVar@TypeVar {} -> tVar {tVarKind = kind}

familyDepth :: TypeVar -> Int
familyDepth =
  \case
    NoType -> 0
    TypeVar {tVarParent = parent} -> familyDepth parent + 1

predecessor :: TypeVar -> TypeVar -> Bool
predecessor NoType NoType = True
predecessor NoType _ = False
predecessor whose@TypeVar {tVarParent = parent} who
  | whose == who = True
  | otherwise = predecessor parent who

noType :: FromTypeVar a => a
noType = fromTypeVar NoType
