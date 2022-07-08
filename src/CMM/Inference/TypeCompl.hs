{-# LANGUAGE Safe #-}

module CMM.Inference.TypeCompl where

import safe CMM.Pretty (arrowNice)
import safe Data.Data (Data)
import safe Data.Text (Text)

import safe Prettyprinter
  ( Pretty(pretty)
  , (<+>)
  , brackets
  , comma
  , parens
  , tupled
  )

import safe CMM.Inference.TypeKind
  ( HasTypeKind(getTypeKind, setTypeKind)
  , TypeKind((:->), GenericType, Star)
  , setTypeKindInvariantLogicError
  )
import safe CMM.Inference.TypeVar (TypeVar)

-- | The primitive patterns for types
data TypeCompl a
  = TupleType [a]
  | FunctionType [a] a
  | AppType a a
  | AddrType a
  | ConstType Text TypeKind TypeVar
  | StringType
  | String16Type
  | LabelType
  | TBitsType Int
  | BoolType
  | VoidType
  deriving (Show, Functor, Foldable, Traversable, Data)

instance Eq a => Eq (TypeCompl a) where
  t == t'
    | TupleType ts <- t
    , TupleType ts' <- t'
    , length ts == length ts' = and $ zipWith (==) ts ts'
    | FunctionType args ret <- t
    , FunctionType args' ret' <- t'
    , length args == length args' = and $ zipWith (==) (ret : args) (ret' : args')
    | AppType app arg <- t
    , AppType app' arg' <- t' = app == app' && arg == arg'
    | AddrType addr <- t
    , AddrType addr' <- t' = addr == addr'
    | ConstType text _ _ <- t
    , ConstType text' _ _ <- t' = text == text'
    | StringType <- t
    , StringType <- t' = True
    | String16Type <- t
    , String16Type <- t' = True
    | LabelType <- t
    , LabelType <- t' = True
    | TBitsType int <- t
    , TBitsType int' <- t' = int == int'
    | BoolType <- t
    , BoolType <- t' = True
    | VoidType <- t
    , VoidType <- t' = True
    | otherwise = False

instance Ord a => Ord (TypeCompl a) where
  t `compare` t'
    | TupleType ts <- t
    , TupleType ts' <- t' = compare ts ts' <> mconcat (zipWith compare ts ts')
    | FunctionType args ret <- t
    , FunctionType args' ret' <- t' =
      compare args args' <> mconcat (zipWith compare (ret : args) (ret' : args'))
    | AppType app arg <- t
    , AppType app' arg' <- t' = compare app app' <> compare arg arg'
    | AddrType addr <- t
    , AddrType addr' <- t' = addr `compare` addr'
    | ConstType text _ _ <- t
    , ConstType text' _ _ <- t' = text `compare` text'
    | StringType <- t
    , StringType <- t' = EQ
    | String16Type <- t
    , String16Type <- t' = EQ
    | LabelType <- t
    , LabelType <- t' = EQ
    | TBitsType int <- t
    , TBitsType int' <- t' = int `compare` int'
    | BoolType <- t
    , BoolType <- t' = EQ
    | TupleType {} <- t = LT
    | TupleType {} <- t' = GT
    | FunctionType {} <- t = LT
    | FunctionType {} <- t' = GT
    | AppType {} <- t = LT
    | AppType {} <- t' = GT
    | AddrType {} <- t = LT
    | AddrType {} <- t' = GT
    | ConstType {} <- t = LT
    | ConstType {} <- t' = GT
    | StringType {} <- t = LT
    | StringType {} <- t' = GT
    | String16Type {} <- t = LT
    | String16Type {} <- t' = GT
    | LabelType {} <- t = LT
    | LabelType {} <- t' = GT
    | TBitsType {} <- t = LT
    | TBitsType {} <- t' = GT
    | BoolType {} <- t = LT
    | BoolType {} <- t' = GT
    | VoidType <- t
    , VoidType <- t' = EQ

instance (HasTypeKind a, Show a) => HasTypeKind (TypeCompl a) where
  getTypeKind =
    \case
      AppType t _ ->
        case getTypeKind t of
          _ :-> k -> k
          GenericType -> GenericType
          _ -> error "kind cannot be applied"
      ConstType _ kind _ -> kind
      _ -> Star
  setTypeKind kind =
    \case
      AppType t t' -> AppType (setTypeKind (kind :-> getTypeKind t') t) t'
      ConstType int _ parent -> ConstType int kind parent
      tCompl
        | kind == Star -> tCompl
        | otherwise -> setTypeKindInvariantLogicError tCompl kind

instance Pretty a => Pretty (TypeCompl a) where
  pretty =
    \case
      TupleType [t] -> parens $ pretty t <> comma -- precedented by python
      TupleType ts -> tupled $ pretty <$> ts
      FunctionType args ret ->
        brackets mempty <> tupled (pretty <$> args) <+> arrowNice <+> pretty ret
      AppType app arg -> parens $ pretty app <+> pretty arg
      AddrType t -> "addr" <+> pretty t
      ConstType name kind _ -> pretty name <> "@" <> parens (pretty kind)
      StringType -> "str"
      String16Type -> "str16"
      LabelType -> "label"
      TBitsType n -> "bits" <> pretty n
      BoolType -> "bool"
      VoidType -> "void"

-- | Transforms the two given `Type`s into a function `Type`
makeFunction :: [a] -> a -> TypeCompl a
makeFunction = FunctionType

-- | Transforms the given list of `Type`s into a tuple `Type` (there are special cases for an empty list and for a singleton)
makeTuple :: [a] -> TypeCompl a
makeTuple = TupleType

infixl `makeApplication`

-- | Takes two types and applies one to the other
makeApplication :: a -> a -> TypeCompl a
makeApplication = AppType

-- | Creates an address type from the given type
makeAddress :: a -> TypeCompl a
makeAddress = AddrType

-- | The primitive pattern
type PrimType = TypeCompl TypeVar
