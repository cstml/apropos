{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE UndecidableSuperClasses #-}

module Apropos.Description(
  Description(..),
  VariableRep,
  variableSet,
  allVariables,
  typeLogic,
  DeepHasDatatypeInfo
) where

import Data.Set (Set)
import qualified Data.Set as Set

import Data.Tree ( Tree(Node) )

import Data.List.Index ( iconcatMap, imap )

import Generics.SOP
    ( constructorInfo,
      constructorName,
      moduleName,
      unI,
      hmap,
      hcliftA2,
      hcmap,
      unSOP,
      Proxy(Proxy),
      ConstructorInfo(Constructor, Infix, Record),
      ConstructorName,
      DatatypeInfo,
      Generic(from, Code),
      HasDatatypeInfo(datatypeInfo),
      I,
      K(..),
      HCollapse(hcollapse),
      HPure(hcpure),
      All,
      All2,
      SListI,
      NP,
      SOP )

import Data.Tagged ( unproxy, untag, Tagged )

import SAT.MiniSat (Formula((:&&:),(:||:),(:++:),(:->:),(:<->:)))
import SAT.MiniSat qualified as SAT

class Description a d | d -> a where
  describe :: a -> d

  additionalLogic :: Formula (VariableRep a)
  additionalLogic = SAT.Yes

-- | A constraint asserting that a type and the types of all its fields recursively
-- implement 'HasDatatypeInfo'.
class    (HasDatatypeInfo a, All2 DeepHasDatatypeInfo (Code a)) => DeepHasDatatypeInfo a
instance (HasDatatypeInfo a, All2 DeepHasDatatypeInfo (Code a)) => DeepHasDatatypeInfo a

-- | A datatype-agnostic representation of an object, consisting of a string
-- representing the constructor and a list of recursive structures representing
-- the fields.
-- The type parameter is unused except to add a bit of type safety.
newtype FlatPack a = FlatPack { unFlatPack :: Tree ConstructorName }

-- | Generically construct a 'FlatPack'.
--
-- This method operates on any type where
-- it and the types of all its fields recursively implement:
--
-- @
--   deriving stock (GHC.Generic)
--   deriving anyclass (Generics.SOP.Generic, Generics.SOP.HasDatatypeInfo)
-- @
flatpack :: forall a. (DeepHasDatatypeInfo a) => a -> FlatPack a
flatpack = flatpack' (datatypeInfo (Proxy @a)) . from
    where
      flatpack' :: (All2 DeepHasDatatypeInfo xss) => DatatypeInfo xss -> SOP I xss -> FlatPack a
      flatpack' ty =
        hcollapse .
        hcliftA2 (Proxy @(All DeepHasDatatypeInfo)) constr (qualifiedConstructorInfo ty) .
        unSOP

      constr :: (All DeepHasDatatypeInfo xs) => ConstructorInfo xs -> NP I xs -> K (FlatPack a) xs
      constr con =
        K .
        FlatPack .
        Node (constructorName con) .
        hcollapse .
        hcmap (Proxy @DeepHasDatatypeInfo) (K . unFlatPack . flatpack . unI)

-- | Type of a variable representing the coice of a single constructor within a 
-- datatype. A datatype is described by a set of such variables, one for each of
-- its constructors recursively.
--
-- The representation consists of a string representing the name of the constructor,
-- and a path of '(ConstructorName, Int)' pairs, each component representing a
-- containing constructor and field number.
data VariableRep a = Var [(ConstructorName, Int)] ConstructorName 
  deriving stock (Eq, Ord, Show)

rootVarRep :: ConstructorName -> VariableRep a
rootVarRep = Var []

pushVR :: ConstructorName -> Int -> VariableRep a -> VariableRep a
pushVR cn i (Var vrs cn') = Var ((cn, i) : vrs) cn'

-- | Calculate the set of variables for an object.
--
-- This method operates on any type where
-- it and the types of all its fields recursively implement:
--
-- @
--   deriving stock (GHC.Generic)
--   deriving anyclass (Generics.SOP.Generic, Generics.SOP.HasDatatypeInfo)
-- @
-- = Examples
--
-- >>> variableSet True
-- fromList [Var [] "True"]
--
-- >>> variableSet False
-- fromList [Var [] "False"]
--
-- >>> variableSet (True, False)
-- fromList [Var [] "(,)", Var [("(,)",0)] "True", Var [("(,)",1)] "False"]
--
-- >>> variableSet (Just True)
-- fromList [Var [] "Just", Var [("Just",0)] "True"]
--
-- >>> variableSet (Nothing @(Maybe Bool))
-- fromList [Var [] "Nothing"]
variableSet :: (DeepHasDatatypeInfo a) => a -> Set (VariableRep a)
variableSet = constructorsToVariables . unFlatPack .  flatpack

data Constructor = Cstr 
  { cstrName :: ConstructorName
  , cstrFields :: [[Constructor]]
  }
  deriving stock (Show)

toConstructors :: forall a. (DeepHasDatatypeInfo a) => [Constructor]
toConstructors = untag (toConstructors' @a)
  where
    toConstructors' :: forall a'. (DeepHasDatatypeInfo a') => Tagged a' [Constructor]
    toConstructors' = 
        unproxy $ 
          hcollapse . 
          hcmap (Proxy @(All DeepHasDatatypeInfo)) constr . 
          qualifiedConstructorInfo . 
          datatypeInfo
      
    constr :: forall xs. (All DeepHasDatatypeInfo xs) => ConstructorInfo xs -> K Constructor xs
    constr ci = K $ Cstr (constructorName ci) (hcollapse $ aux @xs)
      
    aux :: forall xs. (All DeepHasDatatypeInfo xs) => NP (K [Constructor]) xs
    aux = hcpure (Proxy @DeepHasDatatypeInfo) constructorK

    constructorK :: forall a'. DeepHasDatatypeInfo a' => K [Constructor] a'
    constructorK = K $ untag (toConstructors' @a')

-- | Calculate a set of logical constraints governing valid @Set VariableRep@s
-- for a type.
--
-- = Examples (simplified)
-- >>> typeLogic @Bool
-- ExactlyOne [Var Var [] "False", Var Var [] "True"]
--
-- >>> typeLogic @(Bool, Bool)
-- All [
--   ExactlyOne [Var Var [("(,)",0)] "False", Var Var [("(,)",0)] "True"],
--   ExactlyOne [Var Var [("(,)",1)] "False", Var Var [("(,)",1)] "True"] 
-- ]
--
-- >>> typeLogic @(Either Bool Bool)
-- All [
--   ExactlyOne [Var Var [] "Left",Var Var [] "Right"],
--   Var Var [] "Left" :->: All [
--     ExactlyOne [Var Var [("Left",0)] "False",Var Var [("Left",0)] "True"],
--   ],
--   Not (Var (Var [] "Left")) :->: None [Var Var [("Left",0)] "False",Var Var [("Left",0)] "True"],
--   Var Var [] "Right" :->: All [
--     ExactlyOne [Var Var [("Right",0)] "False",Var Var [("Right",0)] "True"]
--   ],
--   Not (Var (Var [] "Right")) :->: None [Var Var [("Right",0)] "False",Var Var [("Right",0)] "True"]
-- ]
typeLogic :: forall a. (DeepHasDatatypeInfo a) => Formula (VariableRep a)
typeLogic = SAT.All . sumLogic $ toConstructors @a
  where
    sumLogic :: [Constructor] -> [Formula (VariableRep a)]
    -- Only one of the constructors can be selected
    sumLogic cs = SAT.ExactlyOne (map (rootVar . cstrName) cs) : 
      -- apply 'prodLogic' to all the fields
      concatMap prodLogic cs

    prodLogic :: Constructor -> [Formula (VariableRep a)]
    prodLogic (Cstr cn cs) =
      -- for each present constructor, apply 'sumLogic'
      [          rootVar cn  :->: SAT.All  (iconcatMap (\i -> map (pushdownFormula cn i                     ) . sumLogic) cs)
      -- for each absent constructor, none of the constructors of its fields can be selected
      , SAT.Not (rootVar cn) :->: SAT.None (iconcatMap (\i -> map (pushdownFormula cn i . rootVar . cstrName)           ) cs)
      ]

    pushdownFormula :: ConstructorName -> Int -> Formula (VariableRep a) -> Formula (VariableRep a)
    pushdownFormula cn i = mapFormula (pushVR cn i)

    mapFormula :: (v -> v) -> Formula v -> Formula v
    mapFormula f (SAT.Var v)         = SAT.Var (f v)
    mapFormula _  SAT.Yes            = SAT.Yes
    mapFormula _  SAT.No             = SAT.No
    mapFormula f (SAT.Not a)         = SAT.Not (mapFormula f a)
    mapFormula f (a :&&: b)          = mapFormula f a :&&: mapFormula f b
    mapFormula f (a :||: b)          = mapFormula f a :||: mapFormula f b
    mapFormula f (a :++: b)          = mapFormula f a :++: mapFormula f b
    mapFormula f (a :->: b)          = mapFormula f a :->: mapFormula f b
    mapFormula f (a :<->: b)         = mapFormula f a :<->: mapFormula f b
    mapFormula f (SAT.All fs)        = SAT.All (map (mapFormula f) fs)
    mapFormula f (SAT.Some fs)       = SAT.Some (map (mapFormula f) fs)
    mapFormula f (SAT.None fs)       = SAT.None (map (mapFormula f) fs)
    mapFormula f (SAT.ExactlyOne fs) = SAT.ExactlyOne (map (mapFormula f) fs)
    mapFormula f (SAT.AtMostOne fs)  = SAT.AtMostOne (map (mapFormula f) fs)
    mapFormula f (SAT.Let a f')      = SAT.Let (mapFormula f a) f'
    mapFormula _ (SAT.Bound i)       = SAT.Bound i

    rootVar :: ConstructorName -> Formula (VariableRep a)
    rootVar = SAT.Var . rootVarRep

allVariables :: forall a. (DeepHasDatatypeInfo a) => Set (VariableRep a)
allVariables =
 Set.unions . 
 map (constructorsToVariables . flattenConstructor) $
 toConstructors @a
  where
    flattenConstructor :: Constructor -> Tree ConstructorName
    flattenConstructor (Cstr cn flds) =
      Node cn (map flattenConstructor . concat $ flds)

constructorsToVariables :: Tree ConstructorName -> Set (VariableRep a)
constructorsToVariables (Node cn cs) =
  Set.singleton (rootVarRep cn) <>
    Set.unions (imap (\i -> Set.map (pushVR cn i) . constructorsToVariables) cs)

qualifiedConstructorInfo :: (SListI xss) => DatatypeInfo xss -> NP ConstructorInfo xss
qualifiedConstructorInfo di = hmap adjust (constructorInfo di)
  where
    adjust :: ConstructorInfo xs -> ConstructorInfo xs
    adjust (Constructor cn) = Constructor (qualify cn)
    adjust (Infix cn ass fix) = Infix (qualify cn) ass fix
    adjust (Record cn fis) = Record (qualify cn) fis

    qualify :: ConstructorName -> ConstructorName
    qualify cn = moduleName di ++ "." ++ cn