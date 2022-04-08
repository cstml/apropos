module Apropos.HasPermutationGenerator (
  HasPermutationGenerator (..),
  Morphism (..),
  Abstraction (..),
  abstract,
  gotoSum,
  abstractsProperties,
  (&&&),
  (>>>),
) where

import Apropos.Gen
import Apropos.Gen.BacktrackingTraversal
import Apropos.HasLogicalModel
import Apropos.HasPermutationGenerator.Abstraction
import Apropos.HasPermutationGenerator.Contract
import Apropos.HasPermutationGenerator.Morphism
import Apropos.LogicalModel
import Apropos.Type
import Control.Monad (join, void)
import Data.Function (on)
import Data.Graph (Graph, buildG, path, scc)
import Data.List (minimumBy)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.String (fromString)
import Hedgehog (Group (..), failure, property)
import Text.PrettyPrint (
  Style (lineLength),
  hang,
  renderStyle,
  style,
  ($+$),
 )
import Text.Show.Pretty (ppDoc)

class (HasLogicalModel p m, Show m) => HasPermutationGenerator p m where
  generators :: [Morphism p m]
  traversalRetryLimit :: (m :+ p) -> Int
  traversalRetryLimit _ = 100

  allowRedundentMorphisms :: (p :+ m) -> Bool
  allowRedundentMorphisms = const False

  permutationGeneratorSelfTest :: Bool -> (Morphism p m -> Bool) -> Gen m -> [Group]
  permutationGeneratorSelfTest testForSuperfluousEdges pefilter bgen =
    let pedges = findMorphisms (Apropos :: m :+ p)
        (_, ns) = numberNodes (Apropos :: m :+ p)
        mGen = buildGen bgen
        graph = buildGraph pedges
        isco = isStronglyConnected graph
     in if null (Map.keys pedges)
          then
            [ Group
                "No permutation edges defined."
                [
                  ( fromString "no edges defined"
                  , property $ void $ forAll (failWithFootnote "no Morphisms defined" :: Gen String)
                  )
                ]
            ]
          else
            if isco
              then case findDupEdgeNames of
                [] ->
                  testEdge testForSuperfluousEdges ns pedges mGen
                    <$> filter pefilter generators
                dups ->
                  [ Group "HasPermutationGenerator edge names must be unique." $
                      [ (fromString $ dup <> " not unique", property failure)
                      | dup <- dups
                      ]
                  ]
              else
                [ Group
                    "HasPermutationGenerator Graph Not Strongly Connected"
                    [
                      ( fromString "Not strongly connected"
                      , property $ void $ forAll (abortNotSCC ns graph :: Gen String)
                      )
                    ]
                ]
    where
      abortNotSCC ns graph =
        let (a, b) = findNoPath (Apropos :: m :+ p) ns graph
         in failWithFootnote $
              renderStyle ourStyle $
                "Morphisms do not form a strongly connected graph."
                  $+$ hang "No Edge Between here:" 4 (ppDoc a)
                  $+$ hang "            and here:" 4 (ppDoc b)
      findDupEdgeNames =
        [ name g | g <- generators :: [Morphism p m], length (filter (== g) generators) > 1
        ]
      testEdge ::
        Bool ->
        Map Int (Set p) ->
        Map (Int, Int) [Morphism p m] ->
        (Set p -> Traversal p m) ->
        Morphism p m ->
        Group
      testEdge testRequired ns pem mGen pe =
        Group (fromString (name pe)) $
          addRequiredTest
            testRequired
            [ (edgeTestName f t, runEdgeTest f)
            | (f, t) <- matchesEdges
            ]
        where
          addRequiredTest False l = l
          addRequiredTest True l = (fromString "Is Required", runRequiredTest) : l
          matchesEdges = [e | (e, v) <- Map.toList pem, pe `elem` v]
          edgeTestName f t = fromString $ name pe <> " : " <> show (Set.toList (lut ns f)) <> " -> " <> show (Set.toList (lut ns t))
          isRequired =
            let inEdges = [length v | (_, v) <- Map.toList pem, pe `elem` v]
             in elem 1 inEdges
          runRequiredTest = property $
            forAll $ do
              if isRequired || allowRedundentMorphisms (Apropos :: p :+ m)
                then pure ()
                else
                  failWithFootnote $
                    renderStyle ourStyle $
                      fromString ("Morphism " <> name pe <> " is not required to make graph strongly connected.")
                        $+$ hang "Edge:" 4 (ppDoc $ name pe)
          runEdgeTest f = property $ do
            void $ traversalContainRetry (traversalRetryLimit (Apropos :: m :+ p)) $ Traversal (mGen (lut ns f)) (\_ -> pure [wrapMorphismWithContractCheck pe])

  buildGen :: Gen m -> Set p -> Traversal p m
  buildGen s tp = do
    let pedges = findMorphisms (Apropos :: m :+ p)
        edges = Map.keys pedges
        distmap = distanceMap edges
        (sn, ns) = numberNodes (Apropos :: m :+ p)
        graph = buildGraph pedges
        isco = isStronglyConnected graph
        go targetProperties m = do
          if null pedges
            then failWithFootnote "no Morphisms defined"
            else pure ()
          if isco
            then pure ()
            else
              let (a, b) = findNoPath (Apropos :: m :+ p) ns graph
               in failWithFootnote $
                    renderStyle ourStyle $
                      "Morphisms do not form a strongly connected graph."
                        $+$ hang "No Edge Between here:" 4 (ppDoc a)
                        $+$ hang "            and here:" 4 (ppDoc b)
          transformModel sn pedges edges distmap m targetProperties
     in Traversal (Source s) (go tp)

  findNoPath ::
    m :+ p ->
    Map Int (Set p) ->
    Graph ->
    (Set p, Set p)
  findNoPath _ m g =
    minimumBy
      (compare `on` uncurry score)
      [ (lut m a, lut m b)
      | a <- Map.keys m
      , b <- Map.keys m
      , not (path g a b)
      ]
    where
      -- The score function is designed to favor sets which are similar and small
      -- The assumption being that smaller traversalims are more general
      score :: Ord a => Set a -> Set a -> (Int, Int)
      score l r = (hamming l r, length $ l `Set.intersection` r)
      hamming :: Ord a => Set a -> Set a -> Int
      hamming l r = length (l `setXor` r)
      setXor :: Ord a => Set a -> Set a -> Set a
      setXor l r = (l `Set.difference` r) `Set.union` (r `Set.difference` l)

  transformModel ::
    Map (Set p) Int ->
    Map (Int, Int) [Morphism p m] ->
    [(Int, Int)] ->
    Map Int (Map Int Int) ->
    m ->
    Set p ->
    Gen [Morphism p m]
  transformModel nodes pedges edges distmap m to = do
    pathOptions <- findPathOptions (Apropos :: m :+ p) edges distmap nodes (properties m) to
    sequence $ traversePath pedges pathOptions

  traversePath ::
    Map (Int, Int) [Morphism p m] ->
    [(Int, Int)] ->
    [Gen (Morphism p m)]
  traversePath edges es = go <$> es
    where
      go :: (Int, Int) -> Gen (Morphism p m)
      go h = do
        pe <- case Map.lookup h edges of
          Nothing -> failWithFootnote "this should never happen"
          Just so -> pure so
        wrapMorphismWithContractCheck <$> element pe

  -- TODO move to Morphism module
  wrapMorphismWithContractCheck :: Morphism p m -> Morphism p m
  wrapMorphismWithContractCheck mo = mo {morphism = wrap}
    where
      wrap m = do
        let inprops = properties m
            mexpected = runContract (contract mo) (name mo) inprops
        case mexpected of
          Left e -> failWithFootnote e
          Right Nothing ->
            failWithFootnote $
              renderStyle ourStyle $
                "Morphism doesn't work. This is a model error"
                  $+$ "This should never happen at this point in the program."
          Right (Just expected) -> do
            if satisfiesFormula logic expected
              then pure ()
              else
                failWithFootnote $
                  renderStyle ourStyle $
                    "Morphism contract produces invalid model"
                      $+$ hang "Edge:" 4 (ppDoc $ name mo)
                      $+$ hang "Input:" 4 (ppDoc inprops)
                      $+$ hang "Output:" 4 (ppDoc expected)
            label $ fromString $ name mo
            nm <- morphism mo m
            let observed = properties nm
            if expected == observed
              then pure nm
              else edgeFailsContract mo m nm expected observed

  findPathOptions ::
    m :+ p ->
    [(Int, Int)] ->
    Map Int (Map Int Int) ->
    Map (Set p) Int ->
    Set p ->
    Set p ->
    Gen [(Int, Int)]
  findPathOptions _ edges distmap ns from to = do
    fn <- case Map.lookup from ns of
      Nothing ->
        failWithFootnote $
          renderStyle ourStyle $
            "Model logic inconsistency found."
              $+$ hang "A model was found that satisfies these properties:" 4 (ppDoc from)
      Just so -> pure so
    tn <- case Map.lookup to ns of
      Nothing -> failWithFootnote "to node not found"
      Just so -> pure so
    rpath <- genRandomPath edges distmap fn tn
    pure $ pairPath rpath

  buildGraph :: Map (Int, Int) [Morphism p m] -> Graph
  buildGraph pedges =
    let edges = Map.keys pedges
        ub = max (maximum (fst <$> edges)) (maximum (snd <$> edges))
     in buildG (0, ub) edges

  mapsBetween :: Map Int (Set p) -> Int -> Int -> Morphism p m -> Bool
  mapsBetween m a b pedge =
    case runContract (contract pedge) (name pedge) (lut m a) of
      Left e -> error e
      Right Nothing -> False
      Right (Just so) -> satisfiesFormula (match pedge) (lut m a) && so == lut m b

  findMorphisms ::
    m :+ p ->
    Map (Int, Int) [Morphism p m]
  findMorphisms apropos =
    let nodemap = snd $ numberNodes apropos
        nodes = Map.keys nodemap
     in Map.fromList
          [ ((a, b), options)
          | a <- nodes
          , b <- nodes
          , let options = filter (mapsBetween nodemap a b) generators
          , not (null options)
          ]
  numberNodes ::
    m :+ p ->
    (Map (Set p) Int, Map Int (Set p))
  numberNodes _ =
    let scenarios = enumerateScenariosWhere (logic :: Formula p)
        scennums = Map.fromList $ zip scenarios [0 ..]
        numsscen = Map.fromList $ zip [0 ..] scenarios
     in (scennums, numsscen)

pairPath :: [Int] -> [(Int, Int)]
pairPath [] = []
pairPath [_] = []
pairPath (a : b : r) = (a, b) : pairPath (b : r)

isStronglyConnected :: Graph -> Bool
isStronglyConnected g = 1 == length (scc g)

lut :: Show a => Show b => Ord a => Map a b -> a -> b
lut m i = case Map.lookup i m of
  Nothing -> error $ "Not found: " <> show i <> " in " <> show m <> "\nthis should never happen..."
  Just so -> so

ourStyle :: Style
ourStyle = style {lineLength = 80}

genRandomPath :: [(Int, Int)] -> Map Int (Map Int Int) -> Int -> Int -> Gen [Int]
genRandomPath edges m from to
  | from == to = pure []
  | otherwise = go [] from
  where
    go breadcrumbs f =
      let shopasto = lut m f
          shopa = lut shopasto to
          awayfrom = snd <$> filter ((== f) . fst) edges
          diston = (\af -> (af, lut (lut m af) to)) <$> awayfrom
          options = fst <$> filter ((<= shopa) . snd) diston
          options' = filter (`notElem` breadcrumbs) options
          options'' = case options' of
            [] -> options
            _ -> options'
       in case shopa of
            0 -> pure []
            1 -> pure [f, to]
            _ -> do
              p <- element options''
              (f :) <$> go (p : breadcrumbs) p

-- TODO is this a performance bottleneck?
distanceMap :: [(Int, Int)] -> Map Int (Map Int Int)
distanceMap edges =
  let initial = foldr ($) Map.empty (insertEdge <$> edges)
      nodes = Map.keys initial
      algo = distanceMapUpdate <$> nodes
   in go (foldr ($) initial algo) algo
  where
    go m algo =
      if distanceMapComplete m
        then m
        else foldr ($) m algo
    insertEdge :: (Int, Int) -> Map Int (Map Int Int) -> Map Int (Map Int Int)
    insertEdge (f, t) m =
      case Map.lookup f m of
        Nothing -> Map.insert f (Map.fromList [(f, 0), (t, 1)]) m
        Just so -> Map.insert f (Map.insert t 1 so) m
    distanceMapComplete :: Map Int (Map Int Int) -> Bool
    distanceMapComplete m =
      let nodes = Map.keys m
       in not $ any (> length nodes) $ join [snd <$> Map.toList (lut m node) | node <- nodes]
    distanceMapUpdate :: Int -> Map Int (Map Int Int) -> Map Int (Map Int Int)
    distanceMapUpdate node m =
      let nodes = Map.keys m
          know = Map.toList $ lut m node
          unknown = filter (not . (`elem` (fst <$> know))) $ Map.keys m
          news =
            join $
              [ (\(t, d) -> (t, d + dist)) <$> Map.toList (lut m known)
              | (known, dist) <- know <> zip unknown (repeat (length nodes + 1))
              ]
       in foldr updateDistance m news
      where
        updateDistance :: (Int, Int) -> Map Int (Map Int Int) -> Map Int (Map Int Int)
        updateDistance (t, d) ma =
          let curdists = lut ma node
           in case Map.lookup t curdists of
                Nothing -> Map.insert node (Map.insert t d curdists) ma
                Just d' | d < d' -> Map.insert node (Map.insert t d curdists) ma
                _ -> ma

edgeFailsContract ::
  forall m p a.
  HasLogicalModel p m =>
  Show m =>
  Morphism p m ->
  m ->
  m ->
  Set p ->
  Set p ->
  Gen a
edgeFailsContract tr m nm expected observed =
  failWithFootnote $
    renderStyle ourStyle $
      "Morphism fails its contract."
        $+$ hang "Edge:" 4 (ppDoc $ name tr)
        $+$ hang "InputModel:" 4 (ppDoc (ppDoc m))
        $+$ hang "InputProperties" 4 (ppDoc $ Set.toList (properties m :: Set p))
        $+$ hang "OutputModel:" 4 (ppDoc (ppDoc nm))
        $+$ hang "ExpectedProperties:" 4 (ppDoc (Set.toList expected))
        $+$ hang "ObservedProperties:" 4 (ppDoc (Set.toList observed))
