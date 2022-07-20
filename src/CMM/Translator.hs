{-# LANGUAGE Trustworthy #-}

{-|
Module      : CMM.Translator
Description : The translation layer
Maintainer  : jiriklepl@seznam.cz

This module translates the AST with type annotations and block annotations int LLVM.
-}
module CMM.Translator where

import safe Control.Applicative (Alternative((<|>)), Applicative(liftA2))
import safe Control.Lens (Field2(_2), Field3(_3), (%=), (^.), use, uses)
import safe Control.Monad.State
  ( MonadState
  , evalState
  , forM_
  , modify
  , void
  , zipWithM
  )
import safe Data.Char (ord)
import safe Data.Data (Data(gmapQ, gmapT), Proxy(Proxy))
import safe Data.Foldable (find, traverse_)
import safe Data.Function ((&))
import safe Data.Functor (($>), (<&>))
import safe Data.Generics.Aliases (extQ, extT)
import safe Data.List (sortOn)
import safe qualified Data.List as List
import safe qualified Data.Map as Map
import safe Data.Map (Map)
import safe Data.Maybe (catMaybes, fromJust)
import safe qualified Data.Set as Set
import safe Data.Set (Set)
import safe Data.String (IsString(fromString))
import safe Data.Text (Text)
import safe qualified Data.Text as T
import safe Data.Tuple.Extra (first, swap)

import safe qualified LLVM.AST.Constant as LC
import safe qualified LLVM.AST.IntegerPredicate as L
import safe qualified LLVM.AST.Name as L
import safe qualified LLVM.AST.Operand as LO
import safe qualified LLVM.AST.Type as LT
import qualified LLVM.AST.Typed as L
import qualified LLVM.IRBuilder.Constant as LC
import qualified LLVM.IRBuilder.Instruction as L
import safe qualified LLVM.IRBuilder.Internal.SnocList as L
import qualified LLVM.IRBuilder.Module as L
import qualified LLVM.IRBuilder.Monad as L
import safe LLVM.Prelude (Word32)

import safe qualified CMM.AST as AST
import safe CMM.AST.Annot (Annot, Annotation(Annot))
import safe CMM.AST.BlockAnnot
  ( BlockAnnot(Begins, NoBlock, Unreachable)
  , HasBlockAnnot(getBlockAnnot)
  )
import safe CMM.AST.GetName (GetName(getName))
import safe CMM.AST.Utils (GetTrivialGotoTarget(getTrivialGotoTarget))
import safe CMM.Data.Function (fOr)
import safe qualified CMM.Inference.Preprocess.Elaboration as Ty
import safe CMM.Inference.Preprocess.Elaboration
  ( HasElaboration(getElaboration)
  )
import safe CMM.Inference.State (Inferencer)
import safe CMM.Parser.GetPos (GetPos)
import safe qualified CMM.Translator.State as State
import safe CMM.Translator.State (TranslState)
import safe CMM.TypeMiner
  ( makePacked
  , mineElaborated
  , mineStruct
  , mineStructName
  )
import safe CMM.Utils (HasCallStack, logicError, notYetImplemented)

type MonadTranslator m
   = (L.MonadIRBuilder m, L.MonadModuleBuilder m, MonadState TranslState m)

type TranslAnnotAssumps a
   = (HasBlockAnnot a, GetPos a, HasElaboration a, Data a)

type TranslAssumps a m = (TranslAnnotAssumps a, MonadTranslator m)

type OutVar = (Text, LO.Operand)

type OutVars = [OutVar]

translateName :: GetName n => n -> L.Name
translateName = L.mkName . T.unpack . getName

getIntWidth :: LT.Type -> Word32
getIntWidth =
  \case
    LT.IntegerType int -> int
    _ -> error "the operand does not have integer type"

translateParName :: GetName n => n -> L.ParameterName
translateParName = (\(L.Name n) -> L.ParameterName n) . translateName

class TranslAssumps a m =>
      Translate m n a b
  | m n -> b
  , b -> m
  where
  translate :: Annot n a -> b
  -- ^ translates the given AST node to llvm (emitted monadically)

instance TranslAssumps a m =>
         Translate m AST.Formal a (m (LT.Type, L.ParameterName)) where
  translate (AST.Formal _ True _ _ `Annot` _) = notYetImplemented
  translate (AST.Formal _ _ type' name `Annot` _) = do
    type'' <- getType type'
    return . (type'', ) $ translateParName name

instance TranslAssumps a m => Translate m AST.TopLevel a (m ()) where
  translate (topLevel `Annot` _) =
    case topLevel of
      AST.TopSection {} -> notYetImplemented
      AST.TopDecl {} -> notYetImplemented
      AST.TopProcedure procedure -> void $ translate procedure
      AST.TopClass {} -> logicError
      AST.TopInstance {} -> logicError
      AST.TopStruct struct -> do
        structs <- use State.structs
        struct' <- runInferencer $ mineStruct structs struct
        State.structs %= uncurry Map.insert struct'

getType :: (MonadTranslator m, HasElaboration a, HasCallStack) => a -> m LT.Type
getType annot = do
  structs' <- use State.structs
  runInferencer $ mineElaborated structs' annot

getStructName :: (MonadTranslator m, HasElaboration a) => a -> m Text
getStructName annot = runInferencer $ mineStructName annot

instance TranslAssumps a m => Translate m AST.Procedure a (m LO.Operand) where
  translate (AST.Procedure (Annot (AST.ProcedureHeader _ name formals _) _) body `Annot` annot) =
    go $ getBlockAnnot annot
    where
      go =
        \case
          Begins idx -> do
            formals' <- traverse translate formals
            type' <- getType annot
            L.function (translateName name) formals' (LT.resultType type') $ \pars -> do
              State.clearTranslState
              blockName <- uses State.blocksTable (Map.! idx)
              L.emitBlockStart . fromString $ T.unpack blockName
              rename' <-
                translate body idx . Map.fromList $ zip formalNames pars
              L.modifyBlock $ \bb ->
                bb
                  { L.partialBlockInstrs =
                      L.SnocList $ L.unSnocList (L.partialBlockInstrs bb) &
                      renameGeneric rename'
                  , L.partialBlockTerm =
                      L.partialBlockTerm bb & renameGeneric rename'
                  }
              L.liftIRState $ modify $ \s ->
                s
                  { L.builderBlocks =
                      L.SnocList $ L.unSnocList (L.builderBlocks s) &
                      renameGeneric rename'
                  , L.builderSupply =
                      fromInteger $ toInteger (L.builderSupply s) -
                      toInteger (Map.size rename')
                  }
          _ -> logicError
        where
          formalNames = getName <$> formals

applyRename :: Ord k => Map k k -> k -> Maybe k
applyRename subst name = Map.lookup name subst

renameGeneric :: Data d => Map LO.Operand LO.Operand -> d -> d
renameGeneric subst = go
  where
    go :: Data d => d -> d
    go = gmapT go `extT` nameCase
    nameCase (name :: LO.Operand) =
      case applyRename subst name of
        Just renamed -> renamed
        _ -> name

collectVarTypes ::
     (Data (n a), Data a, HasElaboration a)
  => Set Text
  -> Annot n a
  -> Map Text Ty.Elaboration
collectVarTypes names (n `Annot` (_ :: a)) =
  Map.fromList $ collectNames names (Proxy :: Proxy a) n

collectNames ::
     (Data d, Data a, HasElaboration a)
  => Set Text
  -> Proxy a
  -> d
  -> [(Text, Ty.Elaboration)]
collectNames names (proxy :: Proxy a) =
  (concat . gmapQ (collectNames names proxy)) `extQ` lvCase
  where
    lvCase ((AST.LVName (AST.Name name)) `Annot` (a :: a))
      | name `Set.member` names = [(name, getElaboration a)]
    lvCase lValue = concat $ gmapQ (collectNames names proxy) lValue

runInferencer :: MonadTranslator m => Inferencer a -> m a
runInferencer action = uses State.inferState $ evalState action

zip' :: [a] -> [b] -> [(a, b)]
zip' = zipWith' (,)

zipWith' :: HasCallStack => (t1 -> t2 -> a) -> [t1] -> [t2] -> [a]
zipWith' f (a:as) (b:bs) = f a b : zipWith' f as bs
zipWith' _ [] [] = []
zipWith' _ _ _ = logicError

instance TranslAssumps a m =>
         Translate m AST.Body a (Int -> Map Text LO.Operand -> m (Map LO.Operand LO.Operand)) where
  translate (Annot (AST.Body []) _) _ _ = return mempty
  translate bodyNode@(Annot (AST.Body items) _) zero newVars = do
    off <- uses State.offSets $ fromJust . Map.lookup zero
    blockData' <-
      uses State.blockData $ Map.filterWithKey $ \k _ ->
        k >= zero && k < zero + off
    let vars = blockData' <&> Map.keys . Map.filter ((^. _3) `fOr` (^. _2))
        varTypes =
          collectVarTypes (Set.fromList . concat $ Map.elems vars) bodyNode
    types <- traverse getType varTypes
    placeholders <-
      Map.elems <$>
      traverse
        (traverse $ \v ->
           (v, ) . LO.LocalReference (fromJust $ Map.lookup v types) <$>
           L.freshName (fromString $ T.unpack v))
        (Map.delete zero vars)
    stackDeclVars <- translateMany stackdeclItems newVars
    headerVars <- translateMany header stackDeclVars
    finalVars <-
      traverse (translateBlock zero (Map.toList headerVars) placeholders) .
      fmap swap .
      sortOn fst $
      fmap swap blocks
    return . Map.fromList . concat $
      zipWith' zip' (fmap snd <$> placeholders) (fmap snd <$> finalVars)
    where
      stmtItems = [item | item@(Annot AST.BodyStmt {} _) <- items]
      stackdeclItems = [item | item@(Annot AST.BodyStackDecl {} _) <- items]
      _ = [item | item@(Annot AST.BodyDecl {} _) <- items]
      (header, body) = tillNext stmtItems -- header = the rest of the entry block of the procedure
      blocks = splitBlocks body
      splitBlocks [] = []
      splitBlocks (item:items')
        | Begins idx <- getBlockAnnot item =
          (item : part, idx) : splitBlocks rest
        where
          (part, rest) = tillNext items'
      splitBlocks _ = logicError
      tillNext items'@(item:rest)
        | Begins {} <- annot = ([], items')
        | Unreachable {} <- annot = tillNext rest
        | NoBlock {} <- annot = tillNext rest
        where
          annot = getBlockAnnot item
      tillNext (item:items') = first (item :) $ tillNext items'
      tillNext [] = ([], [])

translateBlock ::
     TranslAssumps a m
  => Int
  -> OutVars
  -> [OutVars]
  -> ([Annot AST.BodyItem a], Int)
  -> m OutVars
translateBlock zero entry placeholders (~(item:items), idx) = do
  vars <-
    uses State.blockData (idx `Map.lookup`) <&>
    maybe [] (Map.keys . Map.filter (^. _3))
  from <- uses State.controlFlow $ (fst <$>) . filter (\(_, t) -> t == idx)
  names <- use State.blocksTable
  nVars <- translate item mempty
  nVars' <-
    Map.fromList <$>
    sequence
      [ do let sourceList =
                 [ let source =
                         fromJust $ find (\(v', _) -> v' == v) $
                         if f == zero
                           then entry
                           else placeholders !! (f - zero - 1)
                       mkRecord s = (s, L.mkName . T.unpack $ names Map.! f)
                    in mkRecord $ source ^. _2
                 | f <- from
                 ]
           o <- L.phi sourceList
           return (v, o)
      | v <- vars
      ]
  Map.toList <$> translateMany items (nVars' `Map.union` nVars)

translateMany ::
     (Translate m1 n a1 (a2 -> m2 a2), Monad m2) => [Annot n a1] -> a2 -> m2 a2
translateMany [] vars = return vars
translateMany (item:items) vars = translate item vars >>= translateMany items

instance TranslAssumps a m =>
         Translate m AST.BodyItem a (Map Text LO.Operand -> m (Map Text LO.Operand)) where
  translate (Annot (AST.BodyDecl decl) _) = translate decl
  translate (Annot (AST.BodyStackDecl stackDecl) _) = translate stackDecl
  translate (Annot (AST.BodyStmt stmt) _) = translate stmt

instance TranslAssumps a m =>
         Translate m AST.Decl a (Map Text LO.Operand -> m (Map Text LO.Operand)) where
  translate _ = return

{- |
Guarantees:
- Every IfStmt has two bodies consisting of trivial goto statements
- Every SwitchStmt's arm consists of a trivial goto statement
-}
instance TranslAssumps a m => Translate m AST.Unit a (m ()) where
  translate (AST.Unit topLevels `Annot` _) = do
    traverse_ translate $ topStructs <> topProcs <> topDecls <> topSections
    where
      topStructs = [struct | struct@(Annot AST.TopStruct {} _) <- topLevels]
      topProcs = [struct | struct@(Annot AST.TopProcedure {} _) <- topLevels]
      topDecls = [struct | struct@(Annot AST.TopDecl {} _) <- topLevels]
      topSections = [struct | struct@(Annot AST.TopSection {} _) <- topLevels]

instance TranslAssumps a m =>
         Translate m AST.Stmt a (Map Text LO.Operand -> m (Map Text LO.Operand)) where
  translate (stmt `Annot` _) vars =
    case stmt of
      AST.EmptyStmt -> return vars
      AST.IfStmt {}
        | AST.IfStmt c t (Just e) <- stmt -> do
          let Just tLab = getTrivialGotoTarget t
              Just eLab = getTrivialGotoTarget e
          c' <- translate c vars
          L.condBr c' (L.mkName $ T.unpack tLab) (L.mkName $ T.unpack eLab)
          return vars
        | otherwise -> logicError
      AST.SwitchStmt {} -> notYetImplemented
      AST.SpanStmt {} -> notYetImplemented
      AST.AssignStmt lvalues exprs -> do
        assigns <- catMaybes <$> zipWithM translPair lvalues exprs
        let vars' = Map.fromList assigns <> vars
        return vars'
        where translPair (Annot n@AST.LVName {} _) e =
                Just . (getName n, ) <$> translate e vars
              translPair (Annot (AST.LVRef Nothing r Nothing) _) e = do
                r' <- translate r vars
                translate e vars >>= L.store r' 0
                return Nothing
              translPair (Annot AST.LVRef {} _) _ = notYetImplemented
      AST.PrimOpStmt {} -> notYetImplemented
      AST.CallStmt {}
        | AST.CallStmt rets _ expr actuals Nothing [] <- stmt -> do
          actuals' <- traverse (`translate` vars) actuals
          expr' <- translate expr vars
          ret <- L.call expr' (fmap (, []) actuals')
          extract <-
            if null rets
              then return []
              else (L.extractValue ret . pure) `traverse`
                   [0 .. (fromInteger . toInteger $ length rets - 1)]
          let nVars = Map.fromList $ zip (getName <$> rets) extract
          return $ nVars <> vars
        | otherwise -> notYetImplemented
      AST.JumpStmt {} -> notYetImplemented
      AST.ReturnStmt {}
        | AST.ReturnStmt Nothing Nothing actuals <- stmt -> do
          retType <- makePacked <$> traverse getType actuals
          ret <- translateManyExprs vars actuals >>= makeTuple retType
          L.ret ret $> vars
        | otherwise -> notYetImplemented
      AST.LabelStmt name ->
        (L.emitBlockStart . fromString . T.unpack . getName) name $> vars
      AST.ContStmt {} -> notYetImplemented
      AST.GotoStmt {}
        | AST.GotoStmt _ Nothing <- stmt -> do
          let Just lab = getTrivialGotoTarget stmt
          L.br (L.mkName $ T.unpack lab)
          return vars
        | otherwise -> notYetImplemented
      AST.CutToStmt {} -> notYetImplemented
      AST.DroppedStmt {} -> logicError

instance TranslAssumps a m =>
         Translate m AST.Actual a (Map Text LO.Operand -> m LO.Operand) where
  translate (Annot (AST.Actual Nothing expr) _) vars = translate expr vars
  translate _ _ = notYetImplemented

undef :: LT.Type -> LO.Operand
undef = LO.ConstantOperand . LC.Undef

makeTuple :: MonadTranslator m => LT.Type -> [LO.Operand] -> m LO.Operand
makeTuple _ [] = return . LO.ConstantOperand $ LC.Struct Nothing True []
makeTuple type' args = go 0 args (undef type')
  where
    go _ [] to' = return to'
    go i (first':others) to' =
      L.insertValue to' first' [i] >>= go (i + 1) others

translateManyExprs ::
     (Translate m1 n a1 (t -> m2 a2), Monad m2) => t -> [Annot n a1] -> m2 [a2]
translateManyExprs _ [] = return []
translateManyExprs vars (expr:exprs) =
  liftA2 (:) (translate expr vars) (translateManyExprs vars exprs)

-- Source: https://www.cs.tufts.edu/~nr/c--/extern/man2.pdf (7.4)
instance TranslAssumps a m =>
         Translate m AST.Expr a (Map Text LO.Operand -> m LO.Operand) where
  translate (expr `Annot` _) vars =
    case expr of
      AST.LitExpr lit Nothing -> translate lit
      AST.LitExpr _ Just {} -> notYetImplemented
      AST.ParExpr expr' -> translate expr' vars
      AST.LVExpr lvalue -> translate lvalue vars
      AST.BinOpExpr o l r -> do
        l' <- translate l vars
        r' <- translate r vars
        (r' &) . (l' &) $
          case o
          -- https://llvm.org/docs/LangRef.html#icmp-instruction
                of
            AST.AddOp -> L.add
            AST.SubOp -> L.sub
            AST.MulOp -> L.mul
            AST.DivOp -> L.udiv
            AST.ModOp -> L.urem
            AST.AndOp -> L.and
            AST.OrOp -> L.or
            AST.XorOp -> L.xor
            AST.ShLOp -> L.shl
            AST.ShROp -> L.lshr
            AST.EqOp -> L.icmp L.EQ
            AST.NeqOp -> L.icmp L.NE
            AST.GtOp -> L.icmp L.UGT
            AST.LtOp -> L.icmp L.ULT
            AST.GeOp -> L.icmp L.UGE
            AST.LeOp -> L.icmp L.ULE
      AST.ComExpr expr' -> do
        expr'' <- translate expr' vars
        L.typeOf expr'' >>= \case
          Right (LT.IntegerType bits) ->
            L.xor expr'' . LO.ConstantOperand $ LC.Int bits (-1)
          _ -> error "Cannot create a binary complement to a non-int"
      AST.NegExpr expr' -> translate expr' vars >>= L.icmp L.EQ (LC.bit 0)
      AST.MemberExpr expr'@(_ `Annot` eAnnot) (AST.Name name `Annot` _) -> do
        sName <- getStructName eAnnot
        ~(Just (accessors, _)) <- uses State.structs $ Map.lookup sName
        let Just idx = name `List.lookup` accessors
        expr'' <- translate expr' vars
        L.gep expr'' [LC.int32 0, LC.int32 . fromInteger $ toInteger idx]
      AST.InfixExpr {} -> notYetImplemented
      AST.PrefixExpr {} -> notYetImplemented

instance TranslAssumps a m => Translate m AST.Lit a (m LO.Operand) where
  translate (lit `Annot` annot) =
    case lit of
      AST.LitInt int -> do
        t <- getIntWidth <$> getType annot
        return . LO.ConstantOperand $ LC.Int t $ toInteger int
      AST.LitFloat float -> return $ LC.single float
      AST.LitChar char -> do
        t <- getIntWidth <$> getType annot
        return . LO.ConstantOperand $ LC.Int t . toInteger $ ord char

instance TranslAssumps a m =>
         Translate m AST.LValue a (Map Text LO.Operand -> m LO.Operand) where
  translate (Annot lValue annot) vars = do
    records <- use State.records
    case lValue of
      AST.LVName name
        | Just op <- name' `Map.lookup` vars <|> name' `Map.lookup` records ->
          return op
        where name' = getName name
      AST.LVName name -> do
        t <- getType annot
        return . LO.ConstantOperand . LC.GlobalReference t $ translateName name
        -- NOTE: add traversing all frames (accessing global registers; also, accessing non-variables)
      AST.LVRef Nothing expr Nothing -> translate expr vars >>= (`L.load` 0)
      AST.LVRef {} -> notYetImplemented

instance TranslAssumps a m =>
         Translate m AST.StackDecl a (Map Text LO.Operand -> m (Map Text LO.Operand)) where
  translate (AST.StackDecl datums `Annot` _) = go mempty datums
    where
      go cache [] vars
        | null cache = return vars
        | otherwise = error $ "unresolved stackdata: " <> show cache
      go cache (Annot (datum :: AST.Datum a) _:datums') vars =
        case datum of
          AST.DatumLabel name -> go (getName name : cache) datums' vars
          AST.Datum _ t Nothing Nothing -> do
            t' <- getType t
            record <- L.alloca t' Nothing 0
            cache `forM_` \item -> State.records %= Map.insert item record
            go [] datums' vars
          AST.Datum {} -> notYetImplemented
          AST.DatumAlign {} -> notYetImplemented
