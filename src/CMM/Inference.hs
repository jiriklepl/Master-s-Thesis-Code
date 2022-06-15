{-# LANGUAGE Safe #-}
{-# LANGUAGE Rank2Types #-}

-- TODO: add the overlap check for instances
module CMM.Inference where

import safe Control.Applicative (Applicative((*>), (<*), (<*>), liftA2, pure))
import safe Control.Lens (Lens')
import safe Control.Lens.Getter (Getter, (^.), use, uses, view)
import safe Control.Lens.Setter ((%=), (%~), (.=), (.~))
import safe Control.Lens.Traversal (both)
import safe Control.Lens.Tuple (_1, _2)
import safe Control.Monad (Monad((>>=), return), sequence, when)
import safe Data.Bool (Bool(False, True), (&&), (||), not, otherwise)
import safe Data.Data (Data(gmapT))
import safe Data.Either (Either(Left, Right))
import safe Data.Eq (Eq((/=), (==)))
import safe Data.Foldable (Foldable (foldl'), for_, traverse_)
import safe Data.Function (($), (.), flip, id)
import safe Data.Functor (Functor((<$), fmap), ($>), (<$>), (<&>), void)
import safe Data.Generics.Aliases (extT)
import safe Data.Graph (SCC(AcyclicSCC, CyclicSCC), stronglyConnCompR)
import safe qualified Data.Graph as Graph
import safe Data.Int (Int)
import safe Data.List
  ( all
  , any
  , concat
  , filter
  , foldr
  , head
  , null
  , or
  , partition
  , unzip
  , zip
  )
import safe Data.Map (Map)
import safe qualified Data.Map as Map
import safe Data.Maybe (Maybe(Just, Nothing), fromMaybe, maybe)
import safe Data.Monoid (Monoid(mappend, mconcat, mempty))
import safe Data.Ord (Ord((<), (>)))
import safe Data.PartialOrd (PartialOrd)
import safe Data.Semigroup (Semigroup((<>)))
import safe Data.Set (Set)
import safe qualified Data.Set as Set
import safe Data.Text (Text)
import safe Data.Traversable (Traversable(traverse))
import safe Data.Tuple (snd, swap, uncurry)
import safe GHC.Err (undefined)

import safe qualified CMM.Data.Bimap as Bimap
import safe CMM.Data.Bounded (Bounded(maxBound, minBound))
import safe CMM.Data.Bounds
  ( Bounds(Bounds)
  , isTrivialOrAbsurd
  , lowerBound
  , normalizeAbsurd
  , upperBound
  )
import safe CMM.Data.Function (fOr)
import safe CMM.Data.Lattice (Lattice)
import safe CMM.Data.Nullable (Nullable(nullVal))
import safe CMM.Data.Num (Num((+)))
import safe CMM.Data.Ordered (Ordered(Ordered))
import safe CMM.Data.OrderedBounds ()
import safe CMM.Inference.DataKind (DataKind)
import safe CMM.Inference.Fact
  ( Fact
  , Facts
  , FlatFact(ClassConstraint, ClassDetermine, ClassFact,
         ConstnessBounds, InstType, KindBounds, OnRegister, SubConst,
         SubKind, SubType, Typing, Union)
  , FlatFacts
  , NestedFact(Fact, NestedFact)
  , Qual((:=>))
  , Scheme((:.))
  , subConst
  , subKind
  , typeConstraint
  , typeUnion
  )
import safe CMM.Inference.FreeTypeVars (freeTypeVars)
import safe CMM.Inference.HandleCounter (getHandleCounter, nextHandleCounter)
import safe CMM.Inference.Preprocess.HasTypeHole (HasTypeHole(getTypeHole))
import safe CMM.Inference.Preprocess.TypeHole
  ( TypeHole(EmptyTypeHole, LVInstTypeHole, MemberTypeHole,
         MethodTypeHole, SimpleTypeHole)
  )
import safe CMM.Inference.State
  ( Inferencer
  , InferencerState
  , addUnificationErrors
  , classFacts
  , classSchemes
  , collectPrimeTVars
  , constingBounds
  , freshAnnotatedTypeHelper
  , freshTypeHelperWithHandle
  , getConsting
  , getHandle
  , getKinding
  , getTyping
  , handlize
  , handlizeTVar
  , kindingBounds
  , popParent
  , pushConstBounds
  , pushKindBounds
  , pushParent
  , pushSubConst
  , pushSubKind
  , readBoundsFrom
  , readLowerBound
  , reconstruct
  , registerScheme
  , schemes
  , subConsting
  , subKinding
  , typize
  , unifs
  )
import safe CMM.Inference.Subst
  ( Apply(apply)
  , ApplyShallow(applyShallow)
  , Subst
  , foldTVarSubsts
  )
import safe CMM.Inference.Type
  ( ToType(toType)
  , Type(ComplType, ErrorType, VarType)
  )
import safe CMM.Inference.TypeAnnot (TypeAnnot(NoTypeAnnot, TypeInst))
import safe CMM.Inference.TypeCompl
  ( PrimType
  , TypeCompl(AddrType, AppType, FunctionType, TupleType)
  )
import safe CMM.Inference.TypeHandle
  ( TypeHandle
  , consting
  , handleId
  , initTypeHandle
  , kinding
  , typing
  )
import safe CMM.Inference.TypeKind (getTypeKind)
import safe CMM.Inference.TypeVar
  ( TypeVar(NoType, TypeVar, tVarId, tVarParent)
  , predecessor
  )
import safe CMM.Inference.Unify (unify, unifyFold, unifyLax)
import safe CMM.Inference.GetParent ( GetParent(getParent) )
import safe CMM.Data.Way ( Way(Backward, Forward, Both) )

class FactCheck a where
  factCheck :: a -> Inferencer ()

instance (Foldable t, FactCheck a) => FactCheck (t a) where
  factCheck = traverse_ factCheck

instance {-# OVERLAPPING #-} FactCheck (TypeCompl Type) where
  factCheck = \case
    TupleType ts -> factCheck ts
    FunctionType ts t -> factCheck ts *> factCheck t
    AppType t t' -> factCheck t *> factCheck t'
    AddrType t -> factCheck t
    _ -> return ()

instance FactCheck Type where
  factCheck = \case
    VarType t -> factCheck t
    ComplType t -> factCheck t
    _ -> return ()

instance {-# OVERLAPPING #-} FactCheck Fact where
  factCheck fact =
    case fact of
      Fact f -> factCheck f
      NestedFact (tVars :. facts :=> fact') ->
        factCheck tVars *> factCheck facts *> factCheck fact'

instance FactCheck TypeVar where
  factCheck tVar = do
    handlize %= Bimap.tryInsert tVar (initTypeHandle NoTypeAnnot tVar)

elaborate :: PrimType -> Inferencer (TypeCompl Type)
elaborate primType = do
  handles <- use handlize
  let oneLevel t = maybe (VarType t) (view typing) (t `Bimap.lookup` handles)
  return $ oneLevel <$> primType

simplify :: Type -> Inferencer TypeVar
simplify =
  \case
    ErrorType _ -> undefined
    VarType tVar -> do
      uses handlize (tVar `Bimap.lookup`) >>= \case
        Just _ -> return tVar
        Nothing -> handlizeTVar tVar
    ComplType complType ->
      traverse simplify complType >>= \primType ->
        uses typize (primType `Bimap.lookupR`) >>= \case
          Nothing -> do
            tVar <- freshTypeHelperWithHandle $ getTypeKind primType
            typize %= Bimap.insert tVar primType
            t <- elaborate primType
            handlize %= Bimap.adjust (typing .~ ComplType t) tVar
            return tVar
          Just tVar -> return tVar

pushTyping :: TypeHandle -> TypeHandle -> Inferencer ()
pushTyping handle handle' = do
  let t = handle ^. typing
      t' = handle' ^. typing
  case unify t t' of
    Left errs -> addUnificationErrors errs
    Right (subst, _) -> do
      let fixIt = do
            fixTypize >>= \case
              True ->
                fixHandlize >>= \case
                  True -> fixIt
                  False -> fixSubs
              False -> fixSubs
      safeHandlizeUpdate (_2 . typing %~ apply subst) >>= flip when (void fixIt)

mineAST :: (HasTypeHole a, Foldable n) => n a -> Inferencer ()
mineAST = traverse_ (addHandles . getTypeHole)
  where
    addHandle handle = handlize %= Bimap.insert (handleId handle) handle
    addHandles =
      \case
        EmptyTypeHole -> return ()
        SimpleTypeHole handle -> addHandle handle
        LVInstTypeHole handle hole -> addHandle handle *> addHandles hole
        MethodTypeHole handle handle' handle'' ->
          addHandle handle *> addHandle handle' *> addHandle handle''
        MemberTypeHole handle handles handles' ->
          addHandle handle *> traverse_ addHandle handles *>
          traverse_ addHandle handles'

fixClasses :: Inferencer ()
fixClasses = do
  unifs' <- use unifs
  classFacts %= fmap (Set.map $ apply unifs')

fixAll :: Inferencer Bool
fixAll = do
  results <- sequence [fixTypize, fixHandlize, fixSubs]
  if or results
    then do
      fixClasses
      True <$ fixAll
    else return False

mapFold :: (Ord a, Semigroup b) => [(a, b)] -> Map a b
mapFold = foldl' (flip . uncurry $ Map.insertWith (<>)) Map.empty

fixSubGraph ::
     Bool
  -> Lens' InferencerState (Map TypeVar (Set TypeVar))
  -> Subst TypeVar
  -> Inferencer ()
fixSubGraph isShallow which subst = do
  let applyUnifs =
        (_1 %~
         (if isShallow
            then applyShallow
            else apply)
           subst) .
        (_2 %~ Set.fromList .
         ((if isShallow
             then applyShallow
             else apply)
            subst <$>) .
         Set.toList)
  whichList <- uses which $ (applyUnifs <$>) . Map.toList
  let which' = mapFold whichList
  which .= Map.filter (not . null) (Map.mapWithKey Set.delete which')

fixBounds ::
     Lattice a
  => Bool
  -> Lens' InferencerState (Map TypeVar (Bounds a))
  -> Subst TypeVar
  -> Inferencer ()
fixBounds isShallow which subst = do
  whichList <-
    uses which $
    ((_1 %~
      (if isShallow
         then applyShallow
         else apply)
        subst) <$>) .
    Map.toList
  which .= mapFold whichList

fixSubs :: Inferencer Bool
fixSubs = do
  unifs' <- use unifs
  let fixBoth ::
           (Bounded a, Eq a, Ord (Ordered a), Lattice a)
        => Lens' InferencerState (Map TypeVar (Set TypeVar))
        -> Lens' InferencerState (Map TypeVar (Bounds a))
        -> Inferencer (Subst TypeVar)
      fixBoth sub bounds = do
        fixSubGraph False sub unifs'
        fixBounds False bounds unifs'
        subst <- subUnifs
        fixSubGraph True sub subst
        fixBounds True bounds $ subst `apply` unifs'
        propagateBounds bounds sub
        boundsUnifs bounds >>= go subst
        where
          subUnifs = liftA2 deduceUnifs getHandleCounter (use sub)
          go accum subst
            | null subst = return accum
            | otherwise = do
              fixSubGraph True sub subst
              subst' <- subUnifs
              fixSubGraph True sub subst'
              let subst'' = subst' `apply` subst
              fixBounds True bounds subst''
              propagateBounds bounds sub
              boundsUnifs bounds >>= go (subst'' `apply` accum)
  subst <- fixBoth subKinding kindingBounds
  subst' <- fixBoth subConsting constingBounds
  if null subst && null subst'
    then return False
    else safeHandlizeUpdate $ (_2 . kinding %~ apply subst) .
         (_2 . consting %~ apply subst')

unsafeTypizeUpdate ::
     ((TypeVar, PrimType) -> (TypeVar, PrimType)) -> Inferencer ()
unsafeTypizeUpdate change =
  typize %= Bimap.fromList . (change <$>) . Bimap.toList

unsafeHandlizeUpdate ::
     ((TypeVar, TypeHandle) -> (TypeVar, TypeHandle)) -> Inferencer ()
unsafeHandlizeUpdate change =
  handlize %= Bimap.fromList . (change <$>) . Bimap.toList

isSingleton :: Set a -> Bool
isSingleton = (== 1) . Set.size

-- TODO: reduce duplication
safeHandlizeUpdate ::
     ((TypeVar, TypeHandle) -> (TypeVar, TypeHandle)) -> Inferencer Bool
safeHandlizeUpdate change = do
  handles' <- uses handlize ((change <$>) . Bimap.toList)
  let handlize' = Bimap.fromList handles'
      collapsedKeys = mapCollect handles'
      collapsedValues = mapCollect (swap <$> handles')
      goValues [] tSubst cSubst kSubst = return (tSubst, cSubst, kSubst)
      goValues ((handle:handle':handles):others) tSubst cSubst kSubst = do
        (tSubst', _) <-
          apply tSubst (handle ^. typing) `unify`
          apply tSubst (handle' ^. typing)
        (cSubst', _) <-
          apply cSubst (handle ^. consting) `unifyLax`
          apply cSubst (handle' ^. consting)
        (kSubst', _) <-
          apply kSubst (handle ^. kinding) `unifyLax`
          apply kSubst (handle' ^. kinding)
        goValues
          ((handle' : handles) : others)
          (tSubst' `apply` tSubst)
          (cSubst' `apply` cSubst)
          (kSubst' `apply` kSubst)
      goValues (_:others) tSubst cSubst kSubst =
        goValues others tSubst cSubst kSubst
      goKeys [] subst = return subst
      goKeys ((tVar:tVar':tVars):others) subst = do
        (subst', _) <- apply subst tVar `unify` apply subst tVar'
        goKeys ((tVar' : tVars) : others) $ subst' `apply` subst
      goKeys (_:others) subst = goKeys others subst
  handlize .= handlize'
  if all isSingleton collapsedKeys && all isSingleton collapsedValues
    then return False
    else do
      let performForgotten = do
            (tSubst, cSubst, kSubst) <-
              goValues
                (Set.toList . snd <$> Map.toList collapsedKeys)
                (mempty :: Map TypeVar Type)
                (mempty :: Map TypeVar TypeVar)
                (mempty :: Map TypeVar TypeVar)
            subst <-
              goKeys
                (Set.toList . snd <$> Map.toList collapsedValues)
                (mempty :: Map TypeVar TypeVar)
            return (tSubst, cSubst, kSubst, subst)
      case performForgotten of
        Left errs -> do
          addUnificationErrors errs
          return False
        Right (tSubst, cSubst, kSubst, subst) -> do
          unifs %= apply subst
          fixSubGraph True subConsting cSubst
          fixSubGraph True subKinding kSubst
          fixBounds True constingBounds cSubst
          fixBounds True kindingBounds kSubst
          (True <$) . safeHandlizeUpdate $ apply subst .
            (_2 . typing %~ apply tSubst) .
            (_2 . consting %~ applyShallow cSubst) .
            (_2 . kinding %~ applyShallow kSubst)

fixHandlize :: Inferencer Bool
fixHandlize = uses unifs apply >>= safeHandlizeUpdate

mapCollect :: (Ord a, Ord b) => [(a, b)] -> Map a (Set b)
mapCollect = Map.fromListWith mappend . fmap (_2 %~ Set.singleton)

onCandidates :: [t1] -> (t1 -> t2 -> Maybe a) -> t2 -> Maybe a
onCandidates (candidate:candidates) lookup' database =
  case candidate `lookup'` database of
    Just result -> return result
    Nothing -> onCandidates candidates lookup' database
onCandidates [] _ _ = Nothing

fixTypize :: Inferencer Bool
fixTypize = do
  types' <- uses unifs (fmap . apply) <*> uses typize Bimap.toList
  let typize' = Bimap.fromList types'
      collapsedKeys = mapCollect types'
      collapsedValues = mapCollect (swap <$> types')
    -- TODO: reduce duplication; consider continuing despite errors
      goValues [] subst = return subst
      goValues ((primType:primType':primTypes):others) subst =
        case apply subst primType `unify` apply subst primType' of
          Left errs -> do
            addUnificationErrors errs
            return subst
          Right (subst', _) ->
            goValues ((primType' : primTypes) : others) $ subst' `apply` subst
      goValues (_:others) subst = goValues others subst
      goKeys [] subst = return subst
      goKeys ((tVar:tVar':tVars):others) subst =
        case apply subst tVar `unify` apply subst tVar' of
          Left errs -> do
            addUnificationErrors errs
            return subst
          Right (subst', _) ->
            goKeys ((tVar' : tVars) : others) $ subst' `apply` subst
      goKeys (_:others) subst = goKeys others subst
  typize .= typize'
  if all isSingleton collapsedKeys && all isSingleton collapsedValues
    then return False
    else do
      subst <-
        goValues
          (Set.toList . snd <$> Map.toList collapsedValues)
          (mempty :: Subst TypeVar) >>=
        goKeys (Set.toList . snd <$> Map.toList collapsedKeys)
      unifs %= apply subst
      True <$ fixTypize

fixFacts :: Facts -> Inferencer Facts
fixFacts facts = uses unifs $ flip fmap facts . apply

wrapParent :: FlatFacts -> Inferencer a -> Inferencer a
wrapParent flatFacts wrapped =
  case determineParent flatFacts of
    Just parent -> pushParent parent *> wrapped <* popParent
    Nothing -> wrapped
  where
    determineParent [VarType tVar `Union` _] = Just tVar
    determineParent _ = undefined

flattenFacts :: [NestedFact Type] -> FlatFacts
flattenFacts = fmap go
  where
    go (Fact fact) = fact
    go _ = undefined -- TODO: error

reverseFacts :: FlatFacts -> FlatFacts
reverseFacts = fmap go
  where
    go (ClassFact name t) = ClassConstraint name t
    go _ = undefined -- TODO: error

reduceOne :: Facts -> Inferencer (Bool, Facts)
reduceOne [] = fixAll $> (False, [])
reduceOne (fact:facts) =
  case fact of
    Fact (SubType t t') -> do
      tVar <- simplify t
      tVar' <- simplify t'
      continueWith $ Fact (tVar `subKind` tVar') :
        Fact (tVar `typeConstraint` tVar') :
        Fact (tVar `subConst` tVar') :
        facts
    Fact (SubKind t t') -> do
      handle <- simplify t >>= getHandle
      handle' <- simplify t' >>= getHandle
      pushSubKind handle handle'
      continue
    Fact (SubConst t t') -> do
      handle <- simplify t >>= getHandle
      handle' <- simplify t' >>= getHandle
      pushSubConst handle handle'
      continue
    Fact (Typing t t') -> do
      handle <- simplify t >>= getHandle
      handle' <- simplify t' >>= getHandle
      pushTyping handle handle'
      fixFacts facts >>= continueWith
    Fact (Union t t') -> do
      tVar <- simplify t
      tVar' <- simplify t'
      case tVar `unify` tVar' of
        Left errs -> addUnificationErrors errs
        Right (subst, _) -> unifs %= (subst `apply`)
      _ <- fixAll
      fixFacts facts >>= continueWith
    Fact (ClassConstraint name t) ->
      uses classSchemes (name `Map.lookup`) >>= \case
        Nothing -> skip
        Just (tVars :. facts' :=> tVar', _) -> do
          tVar <- simplify t
          subst <- refresher tVars
          continueWith $
            (Fact <$> ClassDetermine name (toType tVar) :
             typeUnion tVar (subst `apply` tVar') :
             (apply subst <$> facts')) <>
            facts
    Fact (ClassFact name t) ->
      uses classSchemes (name `Map.lookup`) >>= \case
        Nothing -> skip
        Just (tVars :. facts' :=> tVar', _) -> do
          tVar <- simplify t
          subst <- refresher tVars
          classFacts %= Map.insertWith mappend name (Set.singleton tVar)
          continueWith $
            (Fact <$> typeUnion tVar (subst `apply` tVar') :
             (apply subst <$> facts')) <>
            facts
    Fact (ClassDetermine name t) ->
      uses classFacts (name `Map.lookup`) >>= \case -- TODO: Map.lookup perhaps too strong
        Nothing -> skip
        Just tVars -> do
          tVar <- simplify t
          if tVar `Set.member` tVars
            then continue
            else skipWith . Fact $ ClassDetermine name (VarType tVar)
    Fact (ConstnessBounds bounds t) -> do
      handle <- simplify t >>= getHandle
      pushConstBounds handle bounds
      continue
    Fact (KindBounds (Bounds (Ordered minKind) (Ordered maxKind)) t) -> do
      handle <- simplify t >>= getHandle
      pushKindBounds handle $ minKind `Bounds` maxKind
      continue
    Fact (OnRegister reg t) -> do
      handle <- simplify t >>= getHandle
      kind <- registerKind reg
      pushKindBounds handle $ kind `Bounds` kind
      continue
    NestedFact (tVars :. [ClassConstraint name t] :=> nesteds) -> do
      tVars' <- uses unifs $ (`Set.map` tVars) . apply
      t' <- uses unifs (`apply` t)
      classSchemes %=
        Map.insertWith
          undefined
          name
          (tVars' :. flattenFacts nesteds :=> t', mempty) -- TODO: error
      continue
    NestedFact (tVars :. [ClassFact name t] :=> nesteds) -> do
      uses classSchemes (name `Map.lookup`) >>= \case
        Nothing -> skip
        Just (scheme@(tVars'' :. facts'' :=> t''), consts) -> do
          t' <- uses unifs (`apply` t)
          tVars' <- uses unifs $ (`Set.map` tVars) . apply
          subst <- refresher tVars''
          classSchemes %=
            Map.insert
              name
              (scheme, (tVars' :. flattenFacts nesteds :=> t') : consts)
          continueWith $
            (Fact <$> typeUnion t' (subst `apply` t'') : flattenFacts nesteds <>
             reverseFacts (apply subst <$> facts'')) <>
            facts
    NestedFact (tVars :. facts' :=> nesteds) -> do
      (changed, nesteds') <- wrapParent facts' $ reduceOne nesteds
      (_1 %~ (|| changed)) <$>
        skipWith (NestedFact (tVars :. facts' :=> nesteds'))
    Fact _ -> skip
  where
    skip = skipWith fact
    skipWith fact' = (_2 %~ (fact' :)) <$> reduceOne facts
    continue = continueWith facts
    continueWith = ((_1 .~ True) <$>) . reduceOne

reduceMany :: Facts -> Inferencer (Bool, Facts)
reduceMany facts = do
  (change, facts') <- reduceOne facts
  if change
    then (_1 .~ True) <$> reduceMany facts'
    else return (False, facts)

reduce :: Facts -> Inferencer (Bool, Facts)
reduce facts = do
  (change, facts') <- reduceMany facts
  let (facts'', sccs) = makeCallGraph facts'
  (change', facts''') <- closeSCCs facts'' sccs
  return (change || change', facts''')

minimizeSubs :: TypeVar -> Inferencer ()
minimizeSubs parent = do
  constings <- uses subConsting transformMap
  constBounds <- use constingBounds
  kindings <- uses subKinding transformMap
  kindBounds <- use kindingBounds
  let (cSubsts, cRest) = laundry parent constBounds constings
      cSubst = foldTVarSubsts cSubsts
      (kSubsts, kRest) = laundry parent kindBounds kindings
      kSubst = foldTVarSubsts kSubsts
  fixSubGraph True subConsting cSubst
  fixBounds True constingBounds cSubst
  fixSubGraph True subKinding kSubst
  fixBounds True kindingBounds kSubst
  cRest `for_` \case
    Just ((_, limits), tVar)
      | null limits -> minimizeBounds constingBounds tVar
      | otherwise -> subConsting %= Map.insert tVar limits
    Nothing -> return ()
  kRest `for_` \case
    Just ((_, limits), tVar)
      | null limits -> minimizeBounds kindingBounds tVar
      | otherwise -> subKinding %= Map.insert tVar limits
    Nothing -> return ()
  void $
    safeHandlizeUpdate
      ((_2 . consting %~ apply cSubst) . (_2 . kinding %~ apply kSubst))
  where
    transformMap =
      Map.toList . fmap (Set.filter setFilter) . Map.filterWithKey mapFilter
    setFilter = predecessor parent . tVarParent
    mapFilter from _ = tVarParent from == parent

laundry ::
     ( Bounded a
     , Lattice a
     , Eq a
     , Ord (Ordered a)
     , Applicative f
     , Nullable (f ((Ordered a, Set TypeVar), TypeVar))
     )
  => TypeVar
  -> Map TypeVar (Bounds a)
  -> [(TypeVar, Set TypeVar)]
  -> ([Map TypeVar TypeVar], [f ((Ordered a, Set TypeVar), TypeVar)])
laundry parent boundsMap subGraph =
  let scc =
        Graph.stronglyConnCompR $
        (\(from, to) -> (from `readBoundsFrom` boundsMap, from, Set.toList to)) <$>
        subGraph
      depends = getDepends scc mempty
      clusters =
        Map.toList . Map.fromListWith mappend .
        fmap (\(a, (b, c)) -> ((Ordered <$> b, c), Set.singleton a)) $
        Map.toList depends
   in unzip $ fromClusters <$> clusters
  where
    fromClusters ((Ordered lower `Bounds` _, limits), tVars)
      | null limits = def
      | Set.size limits == 1 =
        let tVar' = Set.findMin limits
         in if readLowerBound tVar' boundsMap == lower
              then let Right (subst', _) =
                         apply subst tVar `unify` apply subst tVar'
                    in (subst' `apply` subst, nullVal)
              else def
      | otherwise = def
      where
        def = (subst, pure ((Ordered lower, limits), tVar))
        Right (subst, Just tVar) = unifyFold $ Set.toList tVars
    getDepends [] acc = acc
    getDepends (Graph.AcyclicSCC (bounds, tVar, tVars):others) acc
      | tVarParent tVar == parent =
        getDepends others $
        Map.insert tVar (bounds, mconcat (getLimits <$> tVars)) acc
      | otherwise = getDepends others acc
      where
        getLimits tVar'
          | tVarParent tVar' == parent =
            Set.filter relevant . view _2 . fromMaybe (mempty, mempty) $ tVar' `Map.lookup`
            acc
          | parent `predecessor` tVarParent tVar' =
            if relevant tVar'
              then Set.singleton tVar'
              else mempty
          | otherwise = undefined -- TODO: error
        relevant tVar' =
          not . isTrivialOrAbsurd $ readBoundsFrom tVar' boundsMap <> bounds
    getDepends _ _ = undefined -- TODO: error

minimizeBounds ::
     Bounded a
  => Lens' InferencerState (Map TypeVar (Bounds a))
  -> TypeVar
  -> Inferencer ()
minimizeBounds what tVar = do
  low <- uses what (tVar `readLowerBound`)
  what %= Map.insert tVar (low `Bounds` low)

-- TODO: remove parent (implicit)
freeParented :: TypeVar -> Inferencer ([TypeVar], [TypeVar])
freeParented parent = do
  (consts, kinds) <- uses handlize $ unzip . fmap mineSubs . Bimap.elems
  subConsts <- use subConsting
  subKinds <- use subKinding
  return
    ( filter (isFreeParented subConsts) consts
    , filter (isFreeParented subKinds) kinds)
  where
    isFreeParented with tVar@TypeVar {} =
      not (tVar `Map.member` with) && tVarParent tVar == parent
    isFreeParented _ NoType = False
    mineSubs handle = (handle ^. consting, handle ^. kinding)

minimizeFree :: TypeVar -> Inferencer ()
minimizeFree parent = do
  (consts, kinds) <- freeParented parent
  minimizeBounds constingBounds `traverse_` consts
  minimizeBounds kindingBounds `traverse_` kinds

-- TODO: remove parent (implicit)
floatSubs :: TypeVar -> Inferencer ()
floatSubs parent = do
  (consts, kinds) <- (both %~ Set.fromList) <$> freeParented parent
  constBounds <- use constingBounds
  kindBounds <- use kindingBounds
  Set.intersection consts kinds `for_` \tVar -> do
    tVar' <- makeFloated tVar
    constingBounds %= Map.insert tVar' (tVar `readBoundsFrom` constBounds)
    kindingBounds %= Map.insert tVar' (tVar `readBoundsFrom` kindBounds)
  Set.difference consts kinds `for_` \tVar -> do
    tVar' <- makeFloated tVar
    constingBounds %= Map.insert tVar' (tVar `readBoundsFrom` constBounds)
  Set.difference kinds consts `for_` \tVar -> do
    tVar' <- makeFloated tVar
    kindingBounds %= Map.insert tVar' (tVar `readBoundsFrom` kindBounds)
  where
    makeFloated tVar = do
      int <- nextHandleCounter
      return tVar {tVarId = int, tVarParent = NoType}

-- TODO: remove newParent (implicit)
reParent :: Data d => TypeVar -> Set TypeVar -> d -> d
reParent newParent oldParents
  | oldParents == Set.singleton newParent = id
reParent newParent oldParents = go
  where
    go :: Data d => d -> d
    go = gmapT go `extT` tVarCase
    tVarCase tVar@TypeVar {tVarParent = parent}
      | parent `Set.member` oldParents = tVar {tVarParent = newParent}
      | otherwise = tVar
    tVarCase NoType = NoType

refresher :: Set TypeVar -> Inferencer (Map TypeVar TypeVar)
refresher tVars =
  sequence $
  Map.fromSet
    (\tVar -> freshAnnotatedTypeHelper (TypeInst tVar) $ getTypeKind tVar)
    tVars

unSchematize :: Facts -> Inferencer Facts
unSchematize [] = return []
unSchematize (Fact (InstType (VarType scheme) inst):others) =
  uses schemes (scheme `Map.lookup`) >>= \case
    Just (tVars :. facts :=> t) -> do
      instSubst <- refresher tVars
      let facts' = Fact . apply instSubst <$> facts
          t' = instSubst `apply` t
      ((Fact (inst `Union` t') : facts') <>) <$> unSchematize others
    Nothing -> (Fact (VarType scheme `Union` inst) :) <$> unSchematize others
unSchematize (fact:others) = (fact :) <$> unSchematize others

-- TODO: check whether all typings are set (otherwise error)
schematize :: Facts -> Set TypeVar -> Inferencer Facts
schematize facts tVars = do
  parent <- getParent
  x <- Set.toList . Set.unions <$> traverse collectPrimeTVars (Set.toList tVars)
  constings <- Set.fromList <$> traverse getConsting x
  kindings <- Set.fromList <$> traverse getKinding x
  -- TODO: leave out trivial
  typings <- zip x <$> traverse getTyping x
  subConsts <-
    uses subConsting $ filter (keyParentedBy parent `fOr` presentIn constings) .
    Map.toList
  subKinds <-
    uses subKinding $ filter (keyParentedBy parent `fOr` presentIn kindings) .
    Map.toList
  constFacts <- translateSubs constingBounds SubConst ConstnessBounds subConsts
  kindFacts <-
    translateSubs kindingBounds SubKind (KindBounds . fmap Ordered) subKinds
  (determineFacts, factsRest) <-
    do let elaborate' t = do
             tVar <- simplify t
             reconstruct tVar
           construct (Fact (ClassDetermine name t):others) = do
             t' <- elaborate' t
             let pair = (t', ClassConstraint name t')
             (_1 %~ (pair :)) <$> construct others
           construct (fact:others) = (_2 %~ (fact :)) <$> construct others
           construct [] = return ([], [])
       (factPairs, others) <- construct facts
       let (filtered, rest) =
             partition
               (any ((`Set.member` Set.fromList x) `fOr` parentedBy parent) .
                freeTypeVars .
                view _1)
               factPairs
       return (view _2 <$> filtered, (Fact . view _2 <$> rest) <> others)
  let typingFacts =
        [ fact
        | fact@(Union t t') <- uncurry typeConstraint <$> typings
        , t /= t'
        ]
      facts' = typingFacts <> determineFacts <> constFacts <> kindFacts
  tVars `for_` \tVar -> do
    t <- reconstruct tVar
    let scheme =
          Set.filter
            ((`Set.member` freeTypeVars t) `fOr` parentedBy parent)
            (freeTypeVars facts') :.
          facts' :=>
          t
    registerScheme tVar scheme
  return factsRest
  where
    translateSubs _ _ _ [] = return []
    translateSubs bounds subConstr boundsConstr ((tVar, limits):others) = do
      let facts' =
            (\tVar' -> toType tVar `subConstr` toType tVar') <$>
            Set.toList limits
          translateOthers =
            (facts' <>) <$> translateSubs bounds subConstr boundsConstr others
      uses bounds (tVar `Map.lookup`) >>= \case
        Nothing -> translateOthers
        Just bounds' ->
          (boundsConstr bounds' (toType tVar) :) <$> translateOthers
    keyParentedBy parent (key, _) = tVarParent key == parent
    parentedBy parent TypeVar {tVarParent = par} = parent == par
    parentedBy _ _ = False
    presentIn where' (key, _) = key `Set.member` where'

closeSCCs ::
     Facts -> [SCC (Fact, TypeVar, [TypeVar])] -> Inferencer (Bool, Facts)
closeSCCs facts [] = return (False, facts)
closeSCCs facts (scc:others) =
  case scc of
    AcyclicSCC trio -> followUp $ pure trio
    CyclicSCC trios -> followUp trios
  where
    followUp trios = do
      let parents = getParents trios
          parent = head parents
          rePar :: Data d => d -> d
          rePar = reParent parent (Set.fromList parents)
      typize %= Bimap.fromList . rePar . Bimap.toList
      handlize %= Bimap.fromList . rePar . Bimap.toList
      subConsting %= rePar
      constingBounds %= rePar
      subKinding %= rePar
      kindingBounds %= rePar
      unifs %= rePar
      pushParent parent
      (_, facts') <-
        traverse transformFact (fmap rePar trios) >>= reduceMany .
        (<> fmap rePar facts) .
        concat
      minimizeSubs parent
      minimizeFree parent
      _ <- fixAll
      parent' <- uses unifs (`apply` parent)
      popParent *> pushParent parent'
      floatSubs parent'
      _ <- fixAll
      parent'' <- uses unifs (`apply` parent)
      popParent *> pushParent parent''
      (_, facts'') <- fixFacts facts' >>= reduceMany
      parents' <- uses unifs ((<$> parents) . apply)
      facts''' <- schematize facts'' $ Set.fromList parents'
      (_1 .~ True) <$> (popParent *> closeSCCs facts''' others)
    transformFact (NestedFact (_ :. [fact] :=> fs), _, _) = do
      fact' <- uses unifs (`apply` fact)
      (Fact fact' :) <$> unSchematize fs
    transformFact _ = undefined
    getParents = \case
      [] -> []
      (_, tVar, _):rest -> tVar : getParents rest

makeCallGraph :: Facts -> (Facts, [SCC (Fact, TypeVar, [TypeVar])])
makeCallGraph = (_2 %~ stronglyConnCompR) . foldr transform ([], [])
  where
    transform fact =
      case fact of
        NestedFact (_ :. [Union (VarType tVar) _] :=> fs) ->
          _2 %~ ((fact, tVar, foldr out [] fs) :)
        NestedFact (_ :. [Union {}] :=> _) -> undefined -- TODO: logic error
        _ -> _1 %~ (fact :)
    out fact =
      case fact of
        Fact (InstType (VarType scheme) _) -> (scheme :)
        Fact InstType {} -> undefined
        _ -> id

collectCounts :: Facts -> Subst Int
collectCounts = foldr countIn mempty
  where
    countIn = \case
      NestedFact (_ :. [Union (VarType tVar) _] :=> _) ->
        Map.insertWith (+) tVar 1
      NestedFact (_ :. [Union {}] :=> _) ->
        undefined -- TODO: logic error
      _ -> id

collectPairs :: Way -> Int -> Map TypeVar (Set TypeVar) -> [(TypeVar, TypeVar)]
collectPairs way handles from = pairs <&> both %~ \i -> varMap Map.! i
  where
    edges = concat ((\(f, t) -> (f, ) <$> Set.toList t) <$> Map.toList from)
    varMap =
      Map.fromList $ (\tVar -> (tVarId tVar, tVar)) <$>
      uncurry (<>) (unzip edges)
    graph = Graph.buildG (1, handles) $ (both %~ tVarId) <$> edges
    vs = Map.keys varMap
    pairs =
      case way of
        Forward -> [(v, v') | v <- vs, v' <- vs, v /= v', Graph.path graph v v']
        Backward -> [(v, v') | v <- vs, v' <- vs, v /= v', Graph.path graph v' v]
        Both ->
          [ (v, v')
          | v <- vs
          , v' <- vs
          , v < v' -- this is to prevent duplication
          , Graph.path graph v v'
          , Graph.path graph v' v
          ]

deduceUnifs :: Int -> Map TypeVar (Set TypeVar) -> Map TypeVar TypeVar
deduceUnifs handles which = go pairs mempty
  where
    pairs = collectPairs Both handles which
    go [] subst = subst
    go ((tVar, tVar'):others) subst =
      case apply subst tVar `unifyLax` apply subst tVar' of
        Left _ -> undefined -- logic error
        Right (subst', _) -> go others $ subst' `apply` subst

propagateBounds ::
     (Lattice a, Bounded a)
  => Lens' InferencerState (Map TypeVar (Bounds a))
  -> Getter InferencerState (Map TypeVar (Set TypeVar))
  -> Inferencer ()
propagateBounds which by = do
  pairs <- liftA2 (collectPairs Forward) getHandleCounter (use by)
  for_ pairs $ \(v, v') -> do
    uses which (v' `Map.lookup`) >>=
      traverse_ ((which %=) . Map.insertWith (<>) v . (lowerBound .~ minBound))
    uses which (v `Map.lookup`) >>=
      traverse_ ((which %=) . Map.insertWith (<>) v' . (upperBound .~ maxBound))

boundsUnifs ::
     (PartialOrd a, Eq a, Ord (Ordered a), Bounded a)
  => Getter InferencerState (Map TypeVar (Bounds a))
  -> Inferencer (Subst TypeVar)
boundsUnifs which = do
  whichList <- filter (isTrivialOrAbsurd . view _2) <$> uses which Map.toList
  let trivialGroups =
        mapFold $ (_2 %~ Set.singleton) . (_1 %~ Ordered . normalizeAbsurd) .
        swap <$>
        whichList
  let nontrivialTrivialGroups =
        (Set.toList <$>) . Map.elems $
        Map.filter ((> 1) . Set.size) trivialGroups
  return $ go nontrivialTrivialGroups mempty
  where
    go ((first:second:others):rest) subst =
      case apply subst first `unifyLax` apply subst second of
        Left _ -> undefined -- logic error
        Right (subst', _) -> go ((first : others) : rest) $ subst' `apply` subst
    go (_:rest) subst = go rest subst
    go [] subst = subst

registerKind :: Text -> Inferencer DataKind
registerKind = undefined
