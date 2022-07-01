{-# LANGUAGE Safe #-}
{-# LANGUAGE Rank2Types #-}

-- TODO: make an alias for `Map Text (SourcePos, TypeKind)`
module CMM.AST.Variables.State
  ( module CMM.AST.Variables.State.Impl
  , module CMM.AST.Variables.State
  ) where

import safe Control.Lens.Getter (uses)
import safe Control.Lens.Setter ((%=))
import safe Control.Lens.Type (Lens')
import safe Control.Monad (unless)
import safe Control.Monad.State (State)
import safe qualified Data.Map as Map
import safe Data.Set (Set)
import safe Data.Text (Text)

import safe CMM.AST.GetName (GetName(getName))
import safe CMM.Inference.TypeKind (TypeKind)
import safe CMM.Parser.ASTError (registerASTError)
import safe CMM.Parser.HasPos (HasPos(getPos), SourcePos)

import safe CMM.AST.Variables.Error
  ( VariablesError
  , duplicateFunctionVariable
  , duplicateTypeConstant
  , duplicateVariable
  )
import safe CMM.AST.Variables.State.Impl
  ( CollectorState(CollectorState)
  , funcInstVariables
  , funcVariables
  , initCollector
  , structMembers
  , typeAliases
  , typeClasses
  , typeConstants
  , typeVariables
  , variables
  )

type Collector = State CollectorState

-- | adds a regular variable to the `Collector`
addVar :: (HasPos n, GetName n) => n -> TypeKind -> Collector ()
addVar = addVarImpl variables duplicateVariable

-- | template for the functions that add variables to the `Collector`
addVarImpl ::
     (HasPos n, GetName n)
  => Lens' CollectorState (Map.Map Text (SourcePos, b))
  -> (n -> VariablesError)
  -> n
  -> b
  -> Collector ()
addVarImpl place err node tKind = do
  uses place (getName node `Map.member`) >>= \case
    True -> registerASTError node $ err node
    False -> place %= Map.insert (getName node) (getPos node, tKind)

-- | adds a regular variable to the `Collector` and return the given node
addVarTrivial :: (HasPos n, GetName n) => n -> TypeKind -> Collector n
addVarTrivial n tKind = n <$ addVar n tKind

-- | adds a type constant to the `Collector`
addTCon :: (HasPos n, GetName n) => n -> TypeKind -> Collector ()
addTCon = addVarImpl typeConstants duplicateTypeConstant

-- | adds a type constant to the `Collector` and return the given node
addTConTrivial :: (HasPos n, GetName n) => n -> TypeKind -> Collector n
addTConTrivial n tKind = n <$ addTCon n tKind

-- | adds a type alias to the `Collector`
addTAlias :: (HasPos n, GetName n) => n -> TypeKind -> Collector ()
addTAlias = addVarImpl typeAliases duplicateTypeConstant

-- | adds a type alias to the `Collector` and return the given node
addTAliasTrivial :: (HasPos n, GetName n) => n -> TypeKind -> Collector n
addTAliasTrivial n tKind = n <$ addTAlias n tKind

-- | adds a type variable to the `Collector`
addTVar :: (HasPos n, GetName n) => n -> TypeKind -> Collector ()
addTVar node tKind = typeVariables %= Map.insert (getName node) (getPos node, tKind)

-- | adds a type variable to the `Collector` and return the given node
addTVarTrivial :: (HasPos n, GetName n) => n -> TypeKind -> Collector n
addTVarTrivial n tKind = n <$ addTVar n tKind

-- | adds a function to the `Collector`
addFVar :: (HasPos n, GetName n) => n -> TypeKind -> Collector ()
addFVar = addVarImpl funcVariables duplicateFunctionVariable

-- | adds a function to the `Collector` and return the given node
addFVarTrivial :: (HasPos n, GetName n) => n -> TypeKind -> Collector n
addFVarTrivial n tKind = n <$ addFVar n tKind

-- | adds a function instance to the `Collector`
addFIVar :: (HasPos n, GetName n) => n -> TypeKind -> Collector ()
addFIVar = addVarImpl funcInstVariables duplicateFunctionVariable

-- | adds a function instance to the `Collector` and return the given node
addFIVarTrivial :: (HasPos n, GetName n) => n -> TypeKind -> Collector n
addFIVarTrivial n tKind = n <$ addFVar n tKind

-- | adds a type class to the `Collector`
addTClass :: (HasPos n, GetName n) => n -> TypeKind -> Set Text -> Collector ()
addTClass node tKind methods = do
  uses typeClasses (getName node `Map.member`) >>=
    flip
      unless
      (typeClasses %= Map.insert (getName node) (getPos node, tKind, methods))

-- | adds a type class to the `Collector` and return the given node
addTClassTrivial ::
     (HasPos n, GetName n) => n -> TypeKind -> Set Text -> Collector n
addTClassTrivial n tKind methods = n <$ addTClass n tKind methods

-- | adds a struct  to the `Collector`
addSMem :: (HasPos n, GetName n) => n -> TypeKind -> Collector ()
addSMem node tKind = do
  uses structMembers (getName node `Map.member`) >>=
    flip
      unless
      (structMembers %= Map.insert (getName node) (getPos node, tKind))

-- | adds a struct  to the `Collector` and return the given node
addSMemTrivial :: (HasPos n, GetName n) => n -> TypeKind -> Collector n
addSMemTrivial n tKind = n <$ addSMem n tKind
