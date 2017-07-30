{-

A collection of miscellaneous helpers.

-}



-- module

module Web.Sleep.Common.Misc (
  clamp,
  fromTimestamp,
  toTimestamp,
  ) where



-- imports

import           Data.Time.Clock
import           Data.Time.Clock.POSIX



-- exported functions

clamp :: Ord a => a -> a -> a -> a
clamp a b
  | a < b     = max a . min b
  | otherwise = max b . min a

fromTimestamp :: Integer -> UTCTime
fromTimestamp = posixSecondsToUTCTime . realToFrac . secondsToDiffTime

toTimestamp :: UTCTime -> Integer
toTimestamp = round . utcTimeToPOSIXSeconds
