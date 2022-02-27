{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}

module CMM.Inference.State where

import safe Control.Lens.Getter (use)
import safe Control.Lens.Setter ((+=), (%=))
import safe Control.Lens.TH (makeLenses)
import safe Control.Monad.State.Lazy (MonadIO, MonadState)
import safe Data.Map (Map)
import safe Data.Bimap (Bimap)
import safe qualified Data.Bimap as Bimap
import safe Data.Set (Set)
import safe Data.Text (Text)

import safe CMM.Data.Bounds
import safe CMM.Inference.Type
import safe CMM.Inference.TypeHandle

type Subst = Map TypeVar

data Inferencer =
  Inferencer
    {
    -- | Maps variables to their respective superKinding variables (forms a graph)
    _subKinding :: Map TypeVar (Set TypeVar)
    ,
    -- | Maps variables to their respective superKinding variables (forms a graph)
    _kindingBounds :: Map TypeVar (Bounds DataKind)
    ,
    -- | Maps variables to their respective subConsting variables (forms a graph - should overlap with transposed `_kinding` graph)
    _subConsting :: Map TypeVar (Set TypeVar)
    ,
    -- | Maps variables to their respective subConsting variables (forms a graph - should overlap with transposed `_kinding` graph)
    _constingBounds :: Map TypeVar (Bounds Constness)
    ,
    -- | TODO: Unifs
    _unifs :: Map TypeVar TypeVar
    ,
    -- | TODO: Typize
    _typize :: Bimap TypeVar PrimType
    ,
    -- | TODO: Handlize
    _handlize :: Bimap TypeVar TypeHandle
    ,
    -- | TODO
    _handleCounter :: Int
    ,
    -- | TODO
    _errors :: [UnificationError]
    ,
    -- | TODO
    _classSchemes :: Map Text (Scheme TypeVar)
    ,
    -- | TODO
    _instanceSchemes :: Map Text (Set (Scheme TypeVar))
    ,
    -- | TODO
    _schemes :: Map TypeVar (Set (Scheme Type))
    }
  deriving (Show)

initInferencer :: Int -> Inferencer
initInferencer handleCounter =
  Inferencer
    { _subKinding = mempty
    , _kindingBounds = mempty
    , _subConsting = mempty
    , _constingBounds = mempty
    , _unifs = mempty
    , _typize = Bimap.empty
    , _handlize = Bimap.empty
    , _handleCounter = handleCounter
    , _classSchemes = mempty
    , _instanceSchemes = mempty
    , _errors = mempty
    , _schemes = mempty
    }

data UnificationError
  = Occurs TypeVar Type
  | Mismatch Text Type Type
  | NoSubType Type Type -- supertype; subtype
  | NoConstness Constness Type
  | NoKind Text Type
  | NoRegister Text Type
  | TupleMismatch [Type] [Type]
  | GotErrorType Text
  | IllegalPolytype Type
  | BadKind Type Type
  | FalseKind
  | FalseConst
  deriving (Show)

type MonadInferencer m = (MonadState Inferencer m, MonadIO m)

makeLenses ''Inferencer

freshTypeHelper :: MonadInferencer m => TypeKind -> m TypeVar
freshTypeHelper tKind = do
  handleCounter += 1
  counter <- use handleCounter
  let tVar = TypeVar counter tKind
  handlize %= Bimap.insert tVar (initTypeHandle NoTypeAnnot tVar)
  return tVar
