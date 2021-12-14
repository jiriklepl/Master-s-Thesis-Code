{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Rank2Types #-}

module CMM.AST.Variables.State where

import safe Control.Lens.TH (makeLenses)
import safe Control.Monad.State (MonadIO, MonadState)
import safe Data.Map (Map)
import safe qualified Data.Map as Map
import safe Data.Text (Text)
import safe Prettyprinter (Pretty)
import safe Control.Lens.Getter (uses)
import safe Control.Lens.Setter ((%=), (+=))

import safe CMM.AST.HasName (HasName(..))
import safe CMM.Parser.HasPos (HasPos)
import safe CMM.Inference.Type ( TypeKind )
import safe CMM.Pretty ()
import safe CMM.Warnings (makeMessage, mkError, mkWarning)

data CollectedVariables =
  CollectedVariables
    { _variables :: Map Text TypeKind
    , _typeVariables :: Map Text TypeKind
    , _errors :: Int
    , _warnings :: Int
    }

initCollectedVariables :: CollectedVariables
initCollectedVariables =
  CollectedVariables
    {_variables = mempty, _typeVariables = mempty, _errors = 0, _warnings = 0}

type MonadCollectVariables m = (MonadState CollectedVariables m, MonadIO m)

makeLenses ''CollectedVariables

registerError ::
     (HasPos n, Pretty n, MonadCollectVariables m) => n -> Text -> m ()
registerError node message = do
  errors += 1
  makeMessage mkError node message

registerWarning ::
     (HasPos n, Pretty n, MonadCollectVariables m) => n -> Text -> m ()
registerWarning node message = do
  warnings += 1
  makeMessage mkWarning node message

addVar :: (HasPos n, Pretty n, MonadCollectVariables m) => n -> Text -> TypeKind -> m ()
addVar node var tKind = do
  uses variables (var `Map.member`) >>= \case
    True -> registerError node "Duplicate variable"
    False -> variables %= Map.insert var tKind

addVarTrivial ::
     (HasPos n, Pretty n, HasName n, MonadCollectVariables m) => n -> TypeKind -> m n
addVarTrivial n tKind = n <$ addVar n (getName n) tKind

addTVar :: (HasPos n, Pretty n, MonadCollectVariables m) => n -> Text -> TypeKind -> m ()
addTVar node tVar tKind = do
  uses variables (tVar `Map.member`) >>= \case
    True -> registerError node "Duplicate type variable"
    False -> variables %= Map.insert tVar tKind

addTVarTrivial ::
     (HasPos n, Pretty n, HasName n, MonadCollectVariables m) => n -> TypeKind -> m n
addTVarTrivial n tKind = n <$ addTVar n (getName n) tKind
