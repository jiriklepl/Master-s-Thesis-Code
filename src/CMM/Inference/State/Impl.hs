{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE TemplateHaskell #-}

module CMM.Inference.State.Impl where

import safe Control.Lens.TH (makeFieldsNoPrefix)

import safe qualified CMM.Data.Bimap as Bimap
import safe Data.Map (Map)
import safe Data.Monoid (Monoid(mempty))
import safe Data.Set (Set)
import safe Data.Text (Text)
import safe Text.Show (Show)
import safe Control.Monad.State ( State )
import safe Control.Lens.Getter ( uses )
import safe Data.List ( head )
import safe qualified Data.Map as Map
import safe Control.Monad ( Monad(return, (>>=)), sequence )
import safe Data.Function ( ($) )
import safe Control.Lens.Setter ( (%=) )

import safe CMM.Data.Bimap (Bimap)
import safe CMM.Data.Bounds (Bounds)
import safe CMM.Err.State (ErrorState, HasErrorState(errorState))
import safe CMM.Inference.Constness (Constness)
import safe CMM.Inference.DataKind (DataKind)
import safe CMM.Inference.Fact (Scheme)
import safe CMM.Inference.HandleCounter
  ( HandleCounter
  , HasHandleCounter(handleCounter), freshAnnotatedTypeHelperWithParent
  )
import safe CMM.Inference.Type (Type)
import safe CMM.Inference.TypeCompl (PrimType)
import safe CMM.Inference.TypeHandle (TypeHandle, handleId, initTypeHandle)
import safe CMM.Inference.TypeVar (TypeVar(NoType))
import safe CMM.Inference.GetParent ( GetParent(getParent) )
import safe CMM.Data.Trilean ( Trilean )
import safe CMM.Inference.Refresh ( Refresher(refresher) )
import safe CMM.Inference.TypeAnnot ( TypeAnnot(TypeInst, NoTypeAnnot) )
import safe CMM.Inference.TypeKind
    ( HasTypeKind(getTypeKind), TypeKind )

data InferencerState =
  InferencerState
    { _subKinding :: Map TypeVar (Set TypeVar)
    -- ^ Maps variables to their respective superKinding variables (forms a graph)
    , _kindingBounds :: Map TypeVar (Bounds DataKind)
    -- ^ Maps variables to their respective subConsting variables (forms a graph - should overlap with transposed `_kinding` graph)
    , _subConsting :: Map TypeVar (Set TypeVar)
    -- ^ Maps variables to their respective subConsting variables (forms a graph - should overlap with transposed `_kinding` graph)
    , _constingBounds :: Map TypeVar (Bounds Constness)
    -- ^ TODO: Unifs
    , _unifs :: Map TypeVar TypeVar
    -- ^ TODO: Typize
    , _typize :: Bimap TypeVar PrimType
    -- ^ TODO: Handlize
    , _handlize :: Bimap TypeVar TypeHandle
    -- ^ Maps variables to their respective superKinding variables (forms a graph)
    , _handleCounter :: HandleCounter
    -- ^ TODO
    , _errorState :: ErrorState
    -- ^ TODO
    , _classSchemes :: Map Text (Scheme Type)
    -- ^ TODO
    , _classFacts :: Map Text (Set TypeVar)
    -- ^ TODO
    , _funDeps :: Map Text [[Trilean]]
    -- ^ TODO
    , _funFacts :: Map Text [Scheme Type]
    -- ^ TODO
    , _schemes :: Map TypeVar (Scheme Type)
    -- ^ TODO
    , _lockedVars :: Map TypeVar Type
    , _currentParent :: [TypeVar]
    -- ^ TODO
    }
  deriving (Show)

initInferencer :: InferencerState
initInferencer =
  InferencerState
    { _subKinding = mempty
    , _kindingBounds = mempty
    , _subConsting = mempty
    , _constingBounds = mempty
    , _unifs = mempty
    , _typize = Bimap.empty
    , _handlize = Bimap.empty
    , _handleCounter = mempty
    , _classSchemes = mempty
    , _classFacts = mempty
    , _funDeps = mempty
    , _errorState = mempty
    , _funFacts = mempty
    , _schemes = mempty
    , _lockedVars = mempty
    , _currentParent = [globalTVar]
    }

globalTVar :: TypeVar
globalTVar = NoType

makeFieldsNoPrefix ''InferencerState

type Inferencer = State InferencerState

instance GetParent Inferencer TypeVar where
  getParent = uses currentParent head

instance Refresher Inferencer where
  refresher tVars =
    sequence $
    Map.fromSet
      (\tVar -> freshAnnotatedTypeHelper (TypeInst tVar) $ getTypeKind tVar)
      tVars

freshAnnotatedTypeHelper :: TypeAnnot -> TypeKind -> Inferencer TypeVar
freshAnnotatedTypeHelper annot tKind = do
  handle <- getParent >>= freshAnnotatedTypeHelperWithParent annot tKind
  let tVar = handleId handle
  handlize %= Bimap.insert tVar handle
  return tVar

freshTypeHelper :: TypeKind -> Inferencer TypeVar
freshTypeHelper = freshAnnotatedTypeHelper NoTypeAnnot

freshTypeHelperWithHandle :: TypeKind -> Inferencer TypeVar
freshTypeHelperWithHandle kind = freshTypeHelper kind >>= handlizeTVar

handlizeTVar :: TypeVar -> Inferencer TypeVar
handlizeTVar tVar = do
  handlize %= Bimap.insert tVar (initTypeHandle NoTypeAnnot tVar)
  return tVar
