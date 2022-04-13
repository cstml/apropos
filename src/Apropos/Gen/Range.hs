module Apropos.Gen.Range (
  Range (..),
  linearFrom,
  linear,
  singleton,
  rangeSize,
  rangeHi,
  rangeLo,
) where

data Range = LinearFrom Int Int Int | Linear Int Int | Singleton Int

linearFrom :: Int -> Int -> Int -> Range
linearFrom = LinearFrom

linear :: Int -> Int -> Range
linear = Linear

singleton :: Int -> Range
singleton = Singleton

rangeSize :: Range -> Int
rangeSize (Singleton _) = 1
rangeSize (Linear lo hi) = 1 + fromIntegral (max 0 (hi - lo))
rangeSize (LinearFrom _ lo hi) = 1 + fromIntegral (max 0 (hi - lo))

rangeHi :: Range -> Int
rangeHi (Singleton s) = fromIntegral s
rangeHi (Linear _ hi) = fromIntegral hi
rangeHi (LinearFrom _ _ hi) = fromIntegral hi

rangeLo :: Range -> Int
rangeLo (Singleton s) = fromIntegral s
rangeLo (Linear lo _) = fromIntegral lo
rangeLo (LinearFrom _ lo _) = fromIntegral lo
