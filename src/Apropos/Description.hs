{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableSuperClasses #-}

module Apropos.Description (
  Description (describe, refineDescription, genDescribed),
  Formula (
    Yes,
    No,
    Not,
    (:&&:),
    (:||:),
    (:++:),
    (:->:),
    (:<->:),
    All,
    Some,
    None,
    ExactlyOne,
    AtMostOne
  ),
  Attribute (Attr),
  FieldSelector,
  typeLogic,
  DeepGeneric,
  attr,
  variablesToDescription,
  logic,
  allAttributes,
  enumerateScenariosWhere,
  scenarios,
  satisfies,
) where

import Data.String (IsString (fromString))

import Data.Set (Set)
import Data.Set qualified as Set

import Data.Tree (Tree)
import Data.Tree qualified as Tree

import Data.Proxy (Proxy (Proxy))

import Data.List.Index (iconcatMap, imap)

import Data.Semigroup (First (First), getFirst)

import Generics.SOP (All, I, K (K), NP, NS, SOP (SOP), unI, unK, unSOP)
import Generics.SOP qualified as SOP
import Generics.SOP.GGP (
  GCode,
  GDatatypeInfo,
  GFrom,
  GTo,
  gdatatypeInfo,
  gfrom,
  gto,
 )

import GHC.Generics (Generic)

import Data.Tagged (Tagged, unproxy, untag)

import Data.List (elemIndex)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromJust, fromMaybe)

import Data.Kind (Constraint, Type)
import Hedgehog (MonadGen)
import SAT.MiniSat qualified as MiniSAT

{- | Define a description type - an ADT that captures interesting properties of a type.

Defining an instance of this typeclass is the first step for writing apropos tests.

Instances of this typeclass should observe the following law:

@
forall d. forAll (genDescribed d) >>= (\a -> describe a === d)
@

'Apropos.selfTest' is provided for testing adherence to this law.

The type @d@ and the types of all its fields recursively must derive 'Generic'.
-}
type Description :: Type -> Type -> Constraint
class (DeepGeneric d) => Description d a | d -> a where
  -- | Describe a value
  --
  --  Generate a description from a value.
  describe :: a -> d

  -- | Add logic constraining valid description values
  --
  --  Not all constructible description values may be valid. This optional method allows you to specify which. See 'Formula' for more information how to specify
  --  these values.
  refineDescription :: Formula d
  refineDescription = Yes

  -- | Generate test values matching a description.
  --
  --  You specify a Hedgehog 'Hedgehog.Gen' that generates a value for a given description.
  genDescribed :: forall (m :: Type -> Type). (MonadGen m) => d -> m a

{- |

This somewhat strange constraint enforces that description types and all their
fields implement 'GHC.Generic'and are of a suitable shape. This is used
by many Apropos functions. You can probably ignore this, but it may be helful for
building combinators on top of Apropos.
-}
type DeepGeneric :: Type -> Constraint
class (Generic a, GDatatypeInfo a, GFrom a, GTo a, SOP.All2 DeepGeneric (GCode a)) => DeepGeneric a

instance (Generic a, GDatatypeInfo a, GFrom a, GTo a, SOP.All2 DeepGeneric (GCode a)) => DeepGeneric a

{- | A datatype-agnostic representation of an object, consisting of a string
 representing the constructor and a list of recursive structures representing
 the fields.
 The type parameter is unused except to add a bit of type safety.
-}
type FlatPack :: Type -> Type
newtype FlatPack a = FlatPack {unFlatPack :: Tree SOP.ConstructorName}
  deriving newtype (Show)

{- | Generically construct a 'FlatPack'.

 This method operates on any type where it and the types of all its fields
 recursively implement @GHC.Generic@.
-}
flatten :: forall (a :: Type). (DeepGeneric a) => a -> FlatPack a
flatten =
  FlatPack
    . SOP.hcollapse
    . SOP.hcliftA2 (Proxy @(All DeepGeneric)) constr (SOP.constructorInfo (gdatatypeInfo (Proxy @a)))
    . unSOP
    . gfrom
  where
    constr :: forall (xs :: [Type]). (All DeepGeneric xs) => SOP.ConstructorInfo xs -> NP I xs -> K (Tree SOP.ConstructorName) xs
    constr con =
      K
        . Tree.Node (SOP.constructorName con)
        . SOP.hcollapse
        . SOP.hcmap (Proxy @DeepGeneric) (K . unFlatPack . flatten . unI)

unflatten :: forall (a :: Type). (DeepGeneric a) => FlatPack a -> Maybe a
unflatten fp =
  fmap (gto . SOP . getFirst)
    . mconcat
    . SOP.hcollapse
    $ SOP.hcliftA2
      (Proxy @(All DeepGeneric))
      (constr (unFlatPack fp))
      (SOP.constructorInfo (gdatatypeInfo (Proxy @a)))
      (SOP.injections @(GCode a) @(NP I))
  where
    constr :: forall (xs :: [Type]). (All DeepGeneric xs) => Tree SOP.ConstructorName -> SOP.ConstructorInfo xs -> SOP.Injection (NP I) (GCode a) xs -> K (Maybe (First (NS (NP I) (GCode a)))) xs
    constr tree con (SOP.Fn inj)
      | Tree.rootLabel tree == SOP.constructorName con = K $ do
          flds <- SOP.fromList (Tree.subForest tree)
          prod <- SOP.hsequence . SOP.hcmap (Proxy @DeepGeneric) (unflatten . FlatPack . unK) $ flds
          return . First . unK . inj $ prod
      | otherwise = K Nothing

type Attribute :: Type -> Type -> Type
data Attribute i d = Attr
  { attrPath :: [(SOP.ConstructorName, i)]
  , attrConstr :: SOP.ConstructorName
  }
  deriving stock (Eq, Ord, Show, Generic)

{- |
  Type for specifying a field in a constructor, in an attribute path.

  This type is a little bit magic in that it is an instance of both 'Num' and
  'IsString', allowing you to specify both field names and integer indices using
  literal syntax.

  See the examples for 'allAttributes' for more information.
-}
type FieldSelector :: Type
data FieldSelector
  = Index Int
  | RecordField SOP.FieldName
  deriving stock (Eq, Ord)

instance Show FieldSelector where
  show (Index i) = show i
  show (RecordField l) = show l

instance Num FieldSelector where
  fromInteger = Index . fromInteger
  (+) = undefined
  (*) = undefined
  abs = undefined
  signum = undefined
  negate = undefined

instance IsString FieldSelector where
  fromString = RecordField

rootVarRep :: forall (i :: Type) (d :: Type). SOP.ConstructorName -> Attribute i d
rootVarRep = Attr []

pushVR :: forall (i :: Type) (d :: Type). SOP.ConstructorName -> i -> Attribute i d -> Attribute i d
pushVR cn i (Attr vrs cn') = Attr ((cn, i) : vrs) cn'

{- | Calculate the set of variables for an object.

 This method operates on any type where
 it and the types of all its fields recursively implement:

 @
   deriving stock (GHC.Generic)
   deriving anyclass (Generics.SOP.Generic, Generics.SOP.HasDatatypeInfo)
 @
 = Examples

 >>> descriptionToVariables True
 fromList [Attr [] "True"]

 >>> descriptionToVariables False
 fromList [Attr [] "False"]

 >>> descriptionToVariables (True, False)
 fromList [Attr [] "(,)", Attr [("(,)",0)] "True", Attr [("(,)",1)] "False"]

 >>> descriptionToVariables (Just True)
 fromList [Attr [] "Just", Attr [("Just",0)] "True"]

 >>> descriptionToVariables (Nothing @(Maybe Bool))
 fromList [Attr [] "Nothing"]
-}
descriptionToVariables :: forall (d :: Type). (DeepGeneric d) => d -> Set (Attribute Int d)
descriptionToVariables =
  Tree.foldTree
    ( \cn flds ->
        Set.singleton (rootVarRep cn)
          <> Set.unions (imap (Set.map . pushVR cn) flds)
    )
    . unFlatPack
    . flatten

type MapTree :: Type -> Type -> Type
data MapTree k a = MapNode
  { mapRootLabel :: a
  , mapSubForest :: Map k (MapTree k a)
  }
  deriving stock (Show)

variablesToDescription :: forall (d :: Type). (DeepGeneric d) => Set (Attribute Int d) -> d
variablesToDescription s =
  let tree = collapseMapTree . buildMapTree $ s
   in case unflatten . FlatPack $ tree of
        Nothing -> error ("Invalid FlatPack " ++ Tree.drawTree tree)
        Just a -> a
  where
    collapseMapTree :: forall (i :: Type) (a :: Type). MapTree i a -> Tree a
    collapseMapTree mt =
      Tree.Node
        { rootLabel = mapRootLabel mt
        , subForest =
            map snd
              . Map.toAscList
              . Map.map collapseMapTree
              . mapSubForest
              $ mt
        }

    buildMapTree :: Set (Attribute Int d) -> MapTree Int SOP.ConstructorName
    buildMapTree = Set.foldr insertVar emptyMt

    emptyMt :: forall (k :: Type). MapTree k String
    emptyMt =
      MapNode
        { mapRootLabel = ""
        , mapSubForest = Map.empty
        }

    insertVar :: Attribute Int d -> MapTree Int SOP.ConstructorName -> MapTree Int SOP.ConstructorName
    insertVar (Attr [] cons) mt =
      mt {mapRootLabel = cons}
    insertVar (Attr ((_, i) : path) cons) mt =
      mt {mapSubForest = Map.alter (Just . insertVar (Attr path cons) . fromMaybe emptyMt) i (mapSubForest mt)}

type TwoTree :: Type -> Type
data TwoTree a = TwoNode
  { twoRootLabel :: a
  , twoSubForest :: [[TwoTree a]]
  }
  deriving stock (Functor, Show)

foldTwoTree :: forall (t :: Type) (b :: Type). (t -> [[b]] -> b) -> TwoTree t -> b
foldTwoTree f = go
  where
    go (TwoNode x tss) = f x (map (map go) tss)

type ConsInfo :: Type
data ConsInfo = ConsInfo
  { consName :: SOP.ConstructorName
  , consFields :: Maybe [SOP.FieldName]
  }
  deriving stock (Show)

toConstructors :: forall (a :: Type). (DeepGeneric a) => Proxy a -> [TwoTree ConsInfo]
toConstructors _ = untag (toConstructors' @a)
  where
    toConstructors' :: forall (a' :: Type). (DeepGeneric a') => Tagged a' [TwoTree ConsInfo]
    toConstructors' =
      unproxy $
        SOP.hcollapse
          . SOP.hcmap (Proxy @(All DeepGeneric)) constr
          . SOP.constructorInfo
          . gdatatypeInfo

    constr :: forall (xs :: [Type]). (All DeepGeneric xs) => SOP.ConstructorInfo xs -> K (TwoTree ConsInfo) xs
    constr ci = K $ TwoNode (ConsInfo {consName = SOP.constructorName ci, consFields = fields ci}) (SOP.hcollapse $ aux @xs)

    fields :: forall (xs :: [Type]). SOP.ConstructorInfo xs -> Maybe [SOP.FieldName]
    fields (SOP.Record _ flds) = Just . SOP.hcollapse . SOP.hmap (K . SOP.fieldName) $ flds
    fields _ = Nothing

    aux :: forall (xs :: [Type]). (All DeepGeneric xs) => NP (K [TwoTree ConsInfo]) xs
    aux = SOP.hcpure (Proxy @DeepGeneric) constructorK

    constructorK :: forall (a' :: Type). DeepGeneric a' => K [TwoTree ConsInfo] a'
    constructorK = K $ untag (toConstructors' @a')

{- | Calculate a set of logical constraints governing valid @Set Attribute@s
 for a type.

 = Examples (simplified)
 >>> typeLogic @Bool
 ExactlyOne [Attr Attr [] "False", Attr Attr [] "True"]

 >>> typeLogic @(Bool, Bool)
 All [
   ExactlyOne [Attr Attr [("(,)",0)] "False", Attr Attr [("(,)",0)] "True"],
   ExactlyOne [Attr Attr [("(,)",1)] "False", Attr Attr [("(,)",1)] "True"]
 ]

 >>> typeLogic @(Either Bool Bool)
 All [
   ExactlyOne [Attr Attr [] "Left",Attr Attr [] "Right"],
   Attr Attr [] "Left" :->: All [
     ExactlyOne [Attr Attr [("Left",0)] "False",Attr Attr [("Left",0)] "True"],
   ],
   Not (Attr (Attr [] "Left")) :->: None [Attr Attr [("Left",0)] "False",Attr Attr [("Left",0)] "True"],
   Attr Attr [] "Right" :->: All [
     ExactlyOne [Attr Attr [("Right",0)] "False",Attr Attr [("Right",0)] "True"]
   ],
   Not (Attr (Attr [] "Right")) :->: None [Attr Attr [("Right",0)] "False",Attr Attr [("Right",0)] "True"]
 ]
-}
typeLogic :: forall (d :: Type). (DeepGeneric d) => Formula d
typeLogic = All . sumLogic $ toConstructors (Proxy @d)
  where
    sumLogic :: [TwoTree ConsInfo] -> [Formula d]
    sumLogic cs =
      -- Only one of the top-level constructors can be selected
      ExactlyOne (subVars cs)
        :
        -- apply 'prodLogic' to all the fields
        concatMap prodLogic cs

    prodLogic :: TwoTree ConsInfo -> [Formula d]
    prodLogic (TwoNode (ConsInfo cn _) cs) =
      -- for each present constructor, one of the constructors of each of its fields can be selected
      [ rootVar cn :->: (All . imap (\i -> ExactlyOne . pushedSubvars cn i) $ cs)
      , -- for each absent constructor, none of the constructors of any of its fields can be selected
        Not (rootVar cn) :->: (None . iconcatMap (pushedSubvars cn) $ cs)
        -- recurse
      ]
        ++ iconcatMap (\i -> map (mapFormula $ pushVR cn i) . concatMap prodLogic) cs

    pushedSubvars :: SOP.ConstructorName -> Int -> [TwoTree ConsInfo] -> [Formula d]
    pushedSubvars cn i = map (mapFormula (pushVR cn i)) . subVars

    subVars :: [TwoTree ConsInfo] -> [Formula d]
    subVars = map (rootVar . consName . twoRootLabel)

rootVar :: forall (d :: Type). SOP.ConstructorName -> Formula d
rootVar = Var . rootVarRep

{- |
The full set of valid attributes for a type.

Call using a type application.

= Examples

>>> allAttributes @()
fromList [([],"()")]

>>> allAttributes @Bool
fromList
  [ ([],"False")
  , ([],"True")
  ]

>>> allAttributes @(Bool,Bool)
fromList
  [ ([],"(,)")
  , ([("(,)",0)],"False")
  , ([("(,)",0)],"True")
  , ([("(,)",1)],"False")
  , ([("(,)",1)],"True")
  ]

>>> allAttributes @(Either Bool Bool)
fromList
  [ ([],"Left")
  , ([],"Right")
  , ([("Left",0)],"False")
  , ([("Left",0)],"True")
  , ([("Right",0)],"False")
  , ([("Right",0)],"True")
  ]

>>> allAttributes @(Either Bool (Bool,Bool))
fromList
  [ ([],"Left")
  , ([],"Right")
  , ([("Left",0)],"False")
  , ([("Left",0)],"True")
  , ([("Right",0)],"(,)")
  , ([("Right",0),("(,)",0)],"False")
  , ([("Right",0),("(,)",0)],"True")
  , ([("Right",0),("(,)",1)],"False")
  , ([("Right",0),("(,)",1)],"True")
  ]

>>> allAttributes @(Bool, First Bool)
fromList
  [ ([],"(,)")
  , ([("(,)",0)],"False")
  , ([("(,)",0)],"True")
  , ([("(,)",1)],"First")
  , ([("(,)",1),("First","getFirst")],"False")
  , ([("(,)",1),("First","getFirst")],"True")
  ]
-}
allAttributes :: forall (d :: Type). (DeepGeneric d) => Proxy d -> Set ([(SOP.ConstructorName, FieldSelector)], SOP.ConstructorName)
allAttributes _ = Set.map ((\Attr {attrPath, attrConstr} -> (attrPath, attrConstr)) . attrIntToFS) $ allAttributes' @d

allAttributes' :: forall (d :: Type). (DeepGeneric d) => Set (Attribute Int d)
allAttributes' = Set.unions . map constructorAttributes $ toConstructors (Proxy @d)
  where
    constructorAttributes :: TwoTree ConsInfo -> Set (Attribute Int d)
    constructorAttributes =
      foldTwoTree
        ( \(ConsInfo cn _) flds ->
            Set.singleton (rootVarRep cn)
              <> Set.unions (imap (\i -> Set.map (pushVR cn i) . Set.unions) flds)
        )

{- | Match against descriptions containing the given attribute.

An attribute represents a single constructor nested somewhere within an ADT,
and hence a single property captured by a description type. Separate fields of
the same type are represented by different attributes. The 'allAttributes'
function can be used to query the possible attributes of a type.

'attr' takes two arguments:

* the \'path\' to locate the attribute within the ADT, as
a list of pairs of the containing field, and a field selector of type 'FieldSelector'.
The 'FieldSelector' type is a little bit magic, see its docs for more details.

* The name of the constructor representing the attribute.

See also the examples for 'allAttributes' to see what an attribute looks like.
-}
attr ::
  forall (d :: Type).
  (DeepGeneric d) =>
  -- | The \'path\' to the attribute.
  [(SOP.ConstructorName, FieldSelector)] ->
  -- | The name of the constructor corresponding to the attribute.
  SOP.ConstructorName ->
  Formula d
attr p = Var . attrFSToInt . Attr p

attrFSToInt :: forall (d :: Type). (DeepGeneric d) => Attribute FieldSelector d -> Attribute Int d
attrFSToInt Attr {attrPath, attrConstr} = Attr (resolvePath (toConstructors $ Proxy @d) attrPath) attrConstr
  where
    resolvePath :: [TwoTree ConsInfo] -> [(SOP.ConstructorName, FieldSelector)] -> [(SOP.ConstructorName, Int)]
    resolvePath _ [] = []
    resolvePath cs ((cn, fs) : p') = (cn, fld) : resolvePath (twoSubForest constr !! fld) p'
      where
        constr = findConstructor cn cs
        fld = resolveFS fs constr

    resolveFS :: FieldSelector -> TwoTree ConsInfo -> Int
    resolveFS (Index i) _ = i
    resolveFS (RecordField fld) con = resolveField fld con

    resolveField :: SOP.FieldName -> TwoTree ConsInfo -> Int
    resolveField fld con = fromJust $ elemIndex fld =<< (consFields . twoRootLabel $ con)

attrIntToFS :: forall (d :: Type). (DeepGeneric d) => Attribute Int d -> Attribute FieldSelector d
attrIntToFS Attr {attrPath, attrConstr} = Attr (resolvePath (toConstructors $ Proxy @d) attrPath) attrConstr
  where
    resolvePath :: [TwoTree ConsInfo] -> [(SOP.ConstructorName, Int)] -> [(SOP.ConstructorName, FieldSelector)]
    resolvePath _ [] = []
    resolvePath cs ((cn, i) : p) = (cn, fld) : resolvePath (twoSubForest constr !! i) p
      where
        constr = findConstructor cn cs
        fld = index (twoRootLabel constr) i

    index :: ConsInfo -> Int -> FieldSelector
    index cons i =
      case consFields cons of
        Nothing -> Index i
        Just flds -> RecordField (flds !! i)

findConstructor :: SOP.ConstructorName -> [TwoTree ConsInfo] -> TwoTree ConsInfo
findConstructor con = head . filter ((== con) . consName . twoRootLabel)

logic :: forall (d :: Type) (a :: Type). (Description d a) => Formula d
logic = typeLogic :&&: refineDescription

enumerateScenariosWhere :: forall (d :: Type) (a :: Type). (Description d a) => Formula d -> Set (Set (Attribute Int d))
enumerateScenariosWhere holds = enumerateSolutions $ logic :&&: holds

scenarios :: forall (d :: Type) (a :: Type). (Description d a) => Set (Set (Attribute Int d))
scenarios = enumerateScenariosWhere Yes

{- |
Whether a description satisfies a formula.

Useful for using a 'Formula' to create a predicate to pass to a runner.
-}
satisfies :: forall (d :: Type). (DeepGeneric d) => Formula d -> (d -> Bool)
satisfies f s = satisfiable $ f :&&: All (Var <$> Set.toList set) :&&: None (Var <$> Set.toList unset)
  where
    set :: Set (Attribute Int d)
    set = descriptionToVariables s
    unset :: Set (Attribute Int d)
    unset = Set.difference allAttributes' set

infixr 6 :&&:
infixr 5 :||:
infixr 4 :++:
infixr 2 :->:
infix 1 :<->:

{- |
  Logical expressions for matching description types.
-}
type Formula :: Type -> Type
data Formula attr
  = Var (Attribute Int attr)
  | Yes
  | No
  | Not (Formula attr)
  | Formula attr :&&: Formula attr
  | Formula attr :||: Formula attr
  | Formula attr :++: Formula attr
  | Formula attr :->: Formula attr
  | Formula attr :<->: Formula attr
  | All [Formula attr]
  | Some [Formula attr]
  | None [Formula attr]
  | ExactlyOne [Formula attr]
  | AtMostOne [Formula attr]
  deriving stock (Generic)

translateToSAT :: forall (attr :: Type). Formula attr -> MiniSAT.Formula (Attribute Int attr)
translateToSAT (Var var) = MiniSAT.Var var
translateToSAT Yes = MiniSAT.Yes
translateToSAT No = MiniSAT.No
translateToSAT (Not c) = MiniSAT.Not (translateToSAT c)
translateToSAT (a :&&: b) = translateToSAT a MiniSAT.:&&: translateToSAT b
translateToSAT (a :||: b) = translateToSAT a MiniSAT.:||: translateToSAT b
translateToSAT (a :++: b) = translateToSAT a MiniSAT.:++: translateToSAT b
translateToSAT (a :->: b) = translateToSAT a MiniSAT.:->: translateToSAT b
translateToSAT (a :<->: b) = translateToSAT a MiniSAT.:<->: translateToSAT b
translateToSAT (All cs) = MiniSAT.All (translateToSAT <$> cs)
translateToSAT (Some cs) = MiniSAT.Some (translateToSAT <$> cs)
translateToSAT (None cs) = MiniSAT.None (translateToSAT <$> cs)
translateToSAT (ExactlyOne cs) = MiniSAT.ExactlyOne (translateToSAT <$> cs)
translateToSAT (AtMostOne cs) = MiniSAT.AtMostOne (translateToSAT <$> cs)

mapFormula :: forall (a :: Type) (b :: Type). (Attribute Int a -> Attribute Int b) -> Formula a -> Formula b
mapFormula f (Var var) = Var (f var)
mapFormula _ Yes = Yes
mapFormula _ No = No
mapFormula f (Not c) = Not (mapFormula f c)
mapFormula f (a :&&: b) = mapFormula f a :&&: mapFormula f b
mapFormula f (a :||: b) = mapFormula f a :||: mapFormula f b
mapFormula f (a :++: b) = mapFormula f a :++: mapFormula f b
mapFormula f (a :->: b) = mapFormula f a :->: mapFormula f b
mapFormula f (a :<->: b) = mapFormula f a :<->: mapFormula f b
mapFormula f (All cs) = All (mapFormula f <$> cs)
mapFormula f (Some cs) = Some (mapFormula f <$> cs)
mapFormula f (None cs) = None (mapFormula f <$> cs)
mapFormula f (ExactlyOne cs) = ExactlyOne (mapFormula f <$> cs)
mapFormula f (AtMostOne cs) = AtMostOne (mapFormula f <$> cs)

instance (Eq attr) => Eq (Formula attr) where
  a == b = translateToSAT a == translateToSAT b

instance (Ord attr) => Ord (Formula attr) where
  compare a b = compare (translateToSAT a) (translateToSAT b)

instance (Show attr, DeepGeneric attr) => Show (Formula attr) where
  show a = show (translateToSAT a)

satisfiable :: forall (attr :: Type). Formula attr -> Bool
satisfiable = MiniSAT.satisfiable . translateToSAT

solveAll :: forall (attr :: Type). Formula attr -> [Map (Attribute Int attr) Bool]
solveAll = MiniSAT.solve_all . translateToSAT

enumerateSolutions :: forall (attr :: Type). Formula attr -> Set (Set (Attribute Int attr))
enumerateSolutions f = Set.fromList $ Map.keysSet . Map.filter id <$> solveAll f
