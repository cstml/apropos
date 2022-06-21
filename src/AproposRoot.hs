module AproposRoot (
  Description(describe, additionalLogic, genForDescription),
  v,
  allVariables,
  Formula (Var, Yes, No, Not, (:&&:), (:||:), (:++:), (:->:), (:<->:), All, Some, None, ExactlyOne, AtMostOne),
  selfTest,
  selfTestWhere,
  satisfies,
  AproposTest (expect, test),
  runTests,
  runTestsWhere,
  -- Usefull Reexports
  Generic,
  SOPGeneric,
  HasDatatypeInfo,
) where

import Apropos.Formula
import Apropos.Generator
import Apropos.Runner
import Apropos.Description