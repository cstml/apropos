module Apropos.LogicalModel (
  LogicalModel (..),
  Enumerable (..),
  enumerateScenariosWhere,
  satisfiesFormula,
  enumerateSolutions,
  module Apropos.LogicalModel.Formula,
  module Apropos.LogicalModel.Enumerable,
) where

import Apropos.LogicalModel.Enumerable
import Apropos.LogicalModel.Formula
import Data.Map qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

class (Enumerable p, Eq p, Ord p, Show p) => LogicalModel p where
  logic :: Formula p

  scenarios :: [Set p]
  scenarios = enumerateScenariosWhere (logic :: Formula p)

  satisfiedBy :: [p]
  satisfiedBy = Set.toList $
    case scenarios of
      [] -> error "no solutions found for model logic"
      (sol : _) -> sol

enumerateScenariosWhere :: forall p. LogicalModel p => Formula p -> [Set p]
enumerateScenariosWhere holds = enumerateSolutions $ logic :&&: holds :&&: allPresentInFormula
  where
    allPresentInFormula :: Formula p
    allPresentInFormula = All (mention <$> (enumerated :: [p]))
    mention :: p -> Formula p
    mention p = Var p :||: Not (Var p)

enumerateSolutions :: LogicalModel p => Formula p -> [Set p]
enumerateSolutions f = fromSolution <$> solveAll f
  where
    fromSolution :: LogicalModel p => Map.Map p Bool -> Set p
    fromSolution m = Set.fromList $ filter isInSet enumerated
      where
        isInSet k = Just True == Map.lookup k m

satisfiesFormula :: forall p. Enumerable p => Formula p -> Set p -> Bool
satisfiesFormula f s = satisfiable $ f :&&: All (Var <$> set) :&&: None (Var <$> unset)
  where
    set :: [p]
    set = Set.toList s
    unset :: [p]
    unset = filter (`notElem` s) (enumerated :: [p])
