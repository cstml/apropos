module Spec.Description.IntSimple (
  intSimpleGenTests,
) where

import Apropos
import Apropos.Description
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (fromGroup)

data IntDescr = IntDescr
  { sign :: Sign
  , size :: Size
  , isBound :: Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (SOPGeneric, HasDatatypeInfo)

data Sign = Positive | Negative | Zero
  deriving stock (Generic, Eq, Show)
  deriving anyclass (SOPGeneric, HasDatatypeInfo)

data Size = Large | Small
  deriving stock (Generic, Eq, Show)
  deriving anyclass (SOPGeneric, HasDatatypeInfo)

instance Description IntDescr Int where
  describe i =
    IntDescr
      { sign =
          if i < 0
            then Negative
            else
              if i == 0
                then Zero
                else Positive
      , size =
          if i > 10 || i < -10
            then Large
            else Small
      , isBound = i == minBound || i == maxBound
      }

  additionalLogic =
    All
      [ Var (V [("Spec.Description.IntSimple.IntDescr", 0)] "Spec.Description.IntSimple.Zero") :->: Var (V [("Spec.Description.IntSimple.IntDescr", 1)] "Spec.Description.IntSimple.Small")
      , Var (V [("Spec.Description.IntSimple.IntDescr", 2)] "GHC.Types.True") :->: Var (V [("Spec.Description.IntSimple.IntDescr", 1)] "Spec.Description.IntSimple.Large")
      ]

instance HasParameterisedGenerator (VariableRep IntDescr) Int where
  parameterisedGenerator s =
    case sign s of
      Zero -> pure 0
      Positive ->
        if isBound s
          then pure maxBound
          else intGen (size s)
      Negative ->
        if isBound s
          then pure minBound
          else negate <$> intGen (size s)
    where
      intGen :: Size -> Gen Int
      intGen Small = int (linear 1 10)
      intGen Large = int (linear 11 (maxBound - 1))

intSimpleGenTests :: TestTree
intSimpleGenTests =
  testGroup "intGenTests" $
    fromGroup
      <$> [ runGeneratorTestsWhere "Int Generator" (Yes @(VariableRep IntDescr))
          ]
