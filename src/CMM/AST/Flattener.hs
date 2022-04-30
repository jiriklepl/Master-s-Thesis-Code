{-# LANGUAGE Safe #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE UndecidableInstances #-}

module CMM.AST.Flattener where

import safe Control.Applicative (Applicative(pure), liftA2)
import safe Control.Monad (Functor(fmap), Monad(return), sequence)
import safe Control.Monad.State.Lazy (MonadState(get, put), evalState)
import safe Data.Function (($), (.), flip, id)
import safe Data.Functor ((<$>))
import safe Data.Int (Int)
import safe Data.List ((++), concat, length, reverse, take, zip)
import safe Data.Maybe (Maybe(Just, Nothing))
import safe Data.Monoid ((<>))
import safe Data.String (String)
import safe Data.Text (Text)
import safe qualified Data.Text as T
import safe GHC.Err (error)
import safe Text.Show (Show(show))

import safe CMM.AST
  ( Actual
  , Alias
  , Arm(Arm)
  , Asserts
  , Body(Body)
  , BodyItem(BodyDecl, BodyStackDecl, BodyStmt)
  , CallAnnot
  , Class(Class)
  , Export
  , Expr(LVExpr)
  , Flow
  , Formal
  , Import
  , Init
  , Instance(Instance)
  , KindName
  , LValue(LVName)
  , Lit
  , Name(Name)
  , ParaType
  , Pragma
  , Procedure(Procedure)
  , ProcedureDecl(ProcedureDecl)
  , ProcedureHeader(ProcedureHeader)
  , Range
  , Registers
  , Section(SecDatum, SecDecl, SecProcedure, SecSpan)
  , Size
  , Stmt(EmptyStmt, GotoStmt, IfStmt, LabelStmt, SpanStmt, SwitchStmt)
  , Struct
  , TargetDirective
  , Targets
  , TopLevel(TopClass, TopDecl, TopInstance, TopProcedure, TopSection,
         TopStruct)
  , Type
  , Unit(Unit)
  )
import safe CMM.AST.Annot (Annot, Annotation(Annot), withAnnot)
import safe CMM.Data.Num (Num((+)))
import safe CMM.Utils (addPrefix)

class Flatten n where
  flatten :: n a -> n a
  flatten = id

class Functor n =>
      FlattenTrivial n


helperName :: String -> Name a
helperName = Name . addPrefix flattenerPrefix . T.pack

flattenerPrefix :: Text
flattenerPrefix = "F"

instance Flatten n => Flatten (Annot n) where
  flatten (Annot n a) = Annot (flatten n) a

deriving instance {-# OVERLAPPABLE #-}
         FlattenTrivial n => Flatten n

instance Flatten Unit where
  flatten (Unit topLevels) = Unit $ flatten <$> topLevels

instance Flatten TopLevel where
  flatten topLevel = case topLevel of
    TopSection strLit items -> TopSection strLit $ flatten <$> items
    TopProcedure procedure -> TopProcedure $ flatten procedure
    TopDecl {} -> topLevel
    TopClass class' -> TopClass $ flatten class'
    TopInstance instance' -> TopInstance $ flatten instance'
    TopStruct {} -> topLevel

instance Flatten Class where
  flatten (Class paraNames paraName methods) =
    Class paraNames paraName $ flatten <$> methods

instance Flatten Instance where
  flatten (Instance paraNames paraName methods) =
    Instance paraNames paraName $ flatten <$> methods

instance FlattenTrivial Struct

instance Flatten Section where
  flatten = \case
    SecDecl decl -> SecDecl decl
    SecProcedure procedure -> SecProcedure $ flatten procedure
    SecDatum datum -> SecDatum datum
    SecSpan left right items ->
      SecSpan (flatten left) (flatten right) (flatten <$> items)

instance FlattenTrivial TargetDirective

instance FlattenTrivial Import

instance FlattenTrivial Export

instance FlattenTrivial Init

instance FlattenTrivial Registers

instance FlattenTrivial Size

fresh :: MonadState Int m => m Int
fresh = do
  num <- get
  put $ num + 1
  return num

class FlattenBodyItems n where
  flattenBodyItems :: MonadState Int m => [n a] -> m [Annot BodyItem a]

instance Flatten Body where
  flatten (Body bodyItems) = Body $ evalState (flattenBodyItems bodyItems) 0

instance FlattenBodyItems (Annot Body) where
  flattenBodyItems [] = pure []
  flattenBodyItems (Annot (Body bodyItems) _:bodies) =
    liftA2 (++) (flattenBodyItems bodyItems) (flattenBodyItems bodies)

class FlattenStmt n where
  flattenStmt :: MonadState Int m => n a -> m [Annot BodyItem a]

instance FlattenBodyItems (Annot BodyItem) where
  flattenBodyItems [] = pure []
  flattenBodyItems (decl@(Annot BodyDecl {} _):bodyItems) =
    (decl :) <$> flattenBodyItems bodyItems
  flattenBodyItems (stackDecl@(Annot BodyStackDecl {} _):bodyItems) =
    (stackDecl :) <$> flattenBodyItems bodyItems
  flattenBodyItems (stmt:bodyItems) =
    liftA2 (<>) (flattenStmt stmt) (flattenBodyItems bodyItems)

instance {-# OVERLAPPING #-} FlattenStmt (Annot BodyItem) where
  flattenStmt (Annot (BodyStmt stmt) _) = flattenStmt stmt
  flattenStmt _ = error "Not a statement"

toBodyStmt :: Annot Stmt annot -> Annot BodyItem annot
toBodyStmt stmt@(Annot _ a) = Annot (BodyStmt stmt) a

toBody :: Annot BodyItem a -> Annot Body a
toBody bodyItem@(Annot _ a) = withAnnot a $ Body [bodyItem]

trivialGoto :: a -> Name a -> Annot Stmt a
trivialGoto a =
  withAnnot a .
  flip GotoStmt Nothing . withAnnot a . LVExpr . withAnnot a . LVName

brCond :: Annot Expr a -> Name a -> Name a -> a -> Annot Stmt a
brCond cond tName eName a =
  withAnnot a $
  IfStmt
    cond
    (toBody . toBodyStmt $ trivialGoto a tName)
    (Just . toBody . toBodyStmt $ trivialGoto a eName)

instance FlattenStmt (Annot Stmt) where
  flattenStmt stmt@(stmt' `Annot` annot) = case stmt' of
    LabelStmt n ->
      return $ toBodyStmt (trivialGoto annot n) : [toBodyStmt stmt]
    IfStmt cond tBody Nothing -> do
      num <- show <$> fresh
      let tName = helperName $ "then_" ++ num
          fName = helperName $ "fi_" ++ num
      tTransl <- flattenBodyItems [tBody]
      pure $
        toBodyStmt (brCond cond tName fName annot) :
        (toBodyStmt . withAnnot annot $ LabelStmt tName) :
        tTransl ++ [toBodyStmt . withAnnot annot $ LabelStmt fName]
    IfStmt cond tBody (Just eBody) -> do
      num <- show <$> fresh
      let tName = helperName $ "then_" ++ num
          eName = helperName $ "else_" ++ num
          fName = helperName $ "fi_" ++ num
      tTransl <- flattenBodyItems [tBody]
      eTransl <- flattenBodyItems [eBody]
      pure $
        toBodyStmt (brCond cond tName eName annot) :
        (toBodyStmt . withAnnot annot $ LabelStmt tName) :
        tTransl ++
        toBodyStmt (trivialGoto annot fName) :
        (toBodyStmt . withAnnot annot $ LabelStmt eName) :
        eTransl ++ [toBodyStmt . withAnnot annot $ LabelStmt fName]
    SwitchStmt expr arms -> do
      num <- show <$> fresh
      let endName = helperName $ "switch_" ++ num ++ "_end"
          caseNames =
            helperName . (("switch_" ++ num ++ "_") ++) . show <$>
            take (length arms) [(1 :: Int) ..]
      armsTransl <-
        sequence
          [ ((toBodyStmt . withAnnot a $ LabelStmt caseName) :) .
          reverse . ((toBodyStmt $ trivialGoto annot endName) :) . reverse <$>
          flattenBodyItems [body]
          | (Annot (Arm _ body) a, caseName) <- zip arms caseNames
          ]
      let newArms =
            [ withAnnot a . Arm ranges . toBody . toBodyStmt $
            trivialGoto a caseName
            | (Annot (Arm ranges _) a, caseName) <- zip arms caseNames
            ]
      pure $
        toBodyStmt (withAnnot annot $ SwitchStmt expr newArms) :
        concat armsTransl ++ [toBodyStmt . withAnnot annot $ LabelStmt endName]
    SpanStmt lExpr rExpr body -> do
      bodyTransl <- flattenBodyItems [body]
      pure
        [ toBodyStmt . withAnnot annot . SpanStmt lExpr rExpr . withAnnot annot $
          Body bodyTransl
        ]
    EmptyStmt -> pure []
    _ -> pure [toBodyStmt stmt]

instance Flatten Procedure where
  flatten (Procedure header body) = Procedure (flatten header) (flatten body)

instance Flatten ProcedureDecl where
  flatten (ProcedureDecl header) = ProcedureDecl $ flatten header

instance Flatten ProcedureHeader where
  flatten (ProcedureHeader mConv name formals mType) =
    ProcedureHeader
      mConv
      (flatten name)
      (flatten <$> formals)
      (fmap flatten <$> mType)

instance FlattenTrivial Formal

instance FlattenTrivial Actual

instance FlattenTrivial KindName

instance Flatten Arm where
  flatten (Arm ranges body) = Arm (flatten <$> ranges) (flatten body)

instance FlattenTrivial Range

instance FlattenTrivial LValue

instance FlattenTrivial Flow

instance FlattenTrivial Alias

instance FlattenTrivial CallAnnot

instance FlattenTrivial Targets

instance FlattenTrivial Expr

instance FlattenTrivial Lit

instance FlattenTrivial Type

instance FlattenTrivial ParaType

instance FlattenTrivial Asserts

instance FlattenTrivial Name

instance FlattenTrivial Pragma
