{-# LANGUAGE Safe #-}
{-# LANGUAGE DeriveAnyClass #-}

module CMM.FillHoles where


import safe qualified CMM.Inference.State as State
import safe qualified CMM.AST as AST

import safe CMM.Inference.State.Impl ( Inferencer )
import safe CMM.AST.Annot ( withAnnot, Annot, Annotation(Annot) )
import safe CMM.Inference.Preprocess.TypeHole
    ( HasTypeHole(getTypeHole) )
import safe Data.Data ( Data(gmapM), Typeable )
import safe Data.Generics.Aliases ( extM )
import safe CMM.Parser.HasPos ( HasPos )
import safe CMM.Inference.TypeVar ( ToTypeVar(toTypeVar) )
import safe qualified CMM.Inference.Type as T
import safe CMM.Inference.TypeCompl
    ( TypeCompl(VoidType, TupleType, FunctionType, AppType, AddrType,
                ConstType, StringType, String16Type, LabelType, TBitsType,
                BoolType) )
import safe CMM.Err.IsError ( IsError )
import safe Prettyprinter ( (<+>), Pretty(pretty) )
import safe CMM.Parser.ASTError ( registerASTError )
import safe Data.Maybe ( fromMaybe )
import CMM.Inference.Type (unfoldApp)


newtype FillAnnotError
  = UnbackedType T.Type
  deriving (Show, Eq, IsError, Data)

instance Pretty FillAnnotError where
  pretty (UnbackedType t) =
    "The intermediate form type" <+> pretty t <+> "is currently not reflected in the syntax of C--"

class FillHoles n where
  fillHoles :: (Data (n a), Typeable n, Data a, HasTypeHole a, HasPos a) => Annot n a -> Inferencer (Annot n a)

typeFromHoled :: (HasTypeHole a, HasPos a) => a -> Inferencer (Maybe (AST.Type a))
typeFromHoled holed = do
  typing <- State.getTyping . toTypeVar $ getTypeHole holed
  case translType holed typing of
    Nothing -> do
      registerASTError holed $ UnbackedType typing
      return Nothing
    Just type' -> return $ Just type'


translType :: a -> T.Type -> Maybe (AST.Type a)
translType holed t = case t of
    T.VarType {} -> Nothing
    T.ComplType tc -> case tc of
      TupleType {} -> Nothing
      FunctionType {} -> Nothing
      AppType {} -> do
        app' <- withAnnot holed <$> translType holed app
        args' <- traverse (fmap (withAnnot holed) . translType holed) args
        return . AST.TPar . withAnnot holed $ AST.ParaType app' args'
        where (app:args) = unfoldApp t
      AddrType t' -> AST.TPtr . withAnnot holed <$> translType holed t'
      ConstType name _ _ -> Just . AST.TName $ AST.Name name
      StringType -> Nothing
      String16Type -> Nothing
      LabelType -> Just AST.TLabel
      TBitsType n -> Just $ AST.TBits n
      BoolType -> Just AST.TBool
      VoidType -> Just AST.TVoid



instance FillHoles n where
  fillHoles n@(_ `Annot` (_ :: annot)) = go n
    where
      go :: Data d => d -> Inferencer d
      go = gmapM go `extM` registersCase `extM` formalCase `extM` semiFormalCase
      registersCase  (AST.Registers mKind (t `Annot` b) nameStrLits `Annot` (a :: annot)) = do
        t' <- fromMaybe t <$> typeFromHoled b
        return (AST.Registers mKind (withAnnot b t') nameStrLits `Annot` a)
      formalCase (AST.Formal mKind bool (t `Annot` b) name `Annot` (a :: annot)) = do
        t' <- fromMaybe t <$> typeFromHoled b
        return (AST.Formal mKind bool (withAnnot b t') name `Annot` a)
      semiFormalCase (AST.SemiFormal mKind (t `Annot` b) `Annot` (a :: annot)) = do
        t' <- fromMaybe t <$> typeFromHoled b
        return (AST.SemiFormal mKind (withAnnot b t') `Annot` a)
