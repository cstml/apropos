module Main (main) where

import Spec.IntCompact
import Spec.IntSimple

import Test.Tasty
import Test.Tasty.Hedgehog (fromGroup, testProperty)
import Test.Tasty.HUnit (testCase)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "all tests"
    [ testGroup
        "Simple Int types with logic"
        [ testProperty "Bad property test: this should fail!" intSimpleBadProperty 
        , testCase "This is why:" intSimpleExampleUnit 
        , fromGroup intSimpleSelfTest 
        , fromGroup intSimpleAproposExample 
        ]
    , testGroup
        "Compact Int types"
        [ fromGroup intCompactSelfTest
        , testCase "Failing example" intCompactExampleUnit
        , fromGroup intCompactAproposExample  
        ]
    ]
