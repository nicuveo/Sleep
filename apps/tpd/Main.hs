{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}



-- imports

import           Control.Exception
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import           Data.Aeson
import           Data.ByteString.Lazy.Char8   (pack, unpack)
import           Data.Conduit
import           Data.Conduit.Binary
import           Data.String
import           Data.Typeable
import           GHC.Generics
import           Network.HTTP.Client          hiding (withResponse)
import           Network.HTTP.Client.Conduit
import           System.Directory
import           System.Environment
import           System.Exit
import           System.FilePath
import           Text.Printf

import           Web.Sleep.Tumblr
import           Web.Sleep.Tumblr.Simple



-- error handling and logging

logInfo, logWarning, logError, logFatal :: String -> IO ()
logInfo    = printf "I: %s\n"
logWarning = printf "W: %s\n"
logError   = printf "E: %s\n"
logFatal   = logError >=> const exitFailure

logFatalOnException :: IO () -> IO ()
logFatalOnException = handle hcf
  where hcf (SomeException e) =
          let typename = show $ typeOf e
              errormsg = show e
          in  logFatal $ printf "uncaught %s: %s" typename errormsg



-- config

data Config = Config { configOutDir :: FilePath
                     , configLastId :: Int
                     } deriving Generic

instance FromJSON Config
instance ToJSON   Config


newtype JSONException = JSONException String deriving (Show, Typeable)

instance Exception JSONException


appName :: String
appName = "TumblrDownloader"

configDir, configFile, lockFile :: String -> IO FilePath
configDir  blog = (</> blog)     <$> getAppUserDataDirectory appName
configFile blog = (</> "config") <$> configDir blog
lockFile   blog = (</> "lock")   <$> configDir blog

loadConfig :: String -> IO Config
loadConfig blog = do
  cf <- configFile blog
  e  <- doesFileExist cf
  if e
  then do
    fc <- readFile cf
    if not $ null fc
    then either (throw . JSONException) return $ eitherDecode $ pack fc
    else defaultConfig
  else defaultConfig
  where defaultConfig = do
          logWarning $ "config not found for " ++ blog
          getHomeDirectory >>= \hd -> return $ Config hd 0

writeConfig :: String -> Config -> IO ()
writeConfig blog config = do
  cf <- configFile blog
  writeFile cf $ unpack $ encode config



-- locking

unlock, lock :: FilePath -> IO ()
unlock = removeFile
lock l = do
  e <- doesFileExist l
  when e $ logFatal $ printf "lock file (%s) already exists: downloader already running?" l
  writeFile l ""

protect :: FilePath -> IO a -> IO a
protect mutex action = finally (lock mutex >> action) $ unlock mutex



-- sigh

instance MonadBase IO (ResourceT IO) where
  liftBase = lift



-- main

type TPDMonad = ReaderT (TumblrK IO) (ResourceT IO)

downloadPhoto :: Config -> (Int, Int, String) -> TPDMonad ()
downloadPhoto config (pid, index, url) = do
  let filepath = configOutDir config </> show pid ++ "-" ++ show index
  req <- parseRequest url
  liftIO $ logInfo $ printf "downloading %s from %s" filepath url
  withResponse req $ \resp -> runConduit $ responseBody resp .| sinkFile filepath

downloadPhotos :: BlogId -> Config -> Int -> TPDMonad Int
downloadPhotos b config o = do
  (PostList posts) <- callKT $ getPostsByType b PhotoType &= Offset o &= Limit 20
  let recentEnough = [post | post <- posts, pId (postBase post) > configLastId config]
      remaining = length recentEnough
  when (remaining == 20) $ void $ downloadPhotos b config $ o + 20
  when (remaining > 0) $ liftIO $ logInfo $ printf "%d file(s) remaining" $ length recentEnough
  forM_ [ ( pId $ postBase post
          , index
          , show $ photoURI $ photoOriginal photo
          )
        | post  <- reverse recentEnough
        , (index, photo) <- zip [1..] $ postPhotos post
        ] $ downloadPhoto config
  return $ maximum $ configLastId config : map (pId . postBase) recentEnough

main :: IO ()
main = logFatalOnException $ do
  let blog = "nicuveo.tumblr.com" -- FIXME
  configDir blog >>= createDirectoryIfMissing True
  config  <- loadConfig blog
  createDirectoryIfMissing True $ configOutDir config
  apiKey  <- fromString <$> getEnv "TUMBLR_API_KEY"
  mutex   <- lockFile blog
  network <- defaultIONetworkConfig <$> defaultManager
  lastId  <- protect mutex    $
    runResourceT              $
    withAPIKey network apiKey $
    downloadPhotos (fromString blog) config 0
  writeConfig blog $ config { configLastId = lastId }
