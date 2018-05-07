{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}

module Main where

import           Prelude
import           Control.Monad       (forever, (>=>), void)
import           Control.Applicative ((<$>))
import           Data.Monoid         ((<>))
import           Data.String         (fromString)
import qualified Data.Text          as T
import qualified Network.WebSockets as WS
import           Network.Wai.Handler.Warp as WP
import           Network.Wai.Application.Static 
import           WaiAppStatic.Types (unsafeToPiece)
import           Control.Concurrent

main :: IO ()
main = do
  print $ "Listening on " <> host <> ":" <> show wsPort
  WS.runServer host wsPort (WS.acceptRequest >=> arithmetic)
--   forkIO $ WS.runServer host wsPort (WS.acceptRequest >=> server)
--   let warpSettings = WP.setPort serverPort $ WP.setHost (fromString host) WP.defaultSettings
--   WP.runSettings warpSettings $ staticApp $ (defaultWebAppSettings "/public_html") {ssIndices = [unsafeToPiece "index.html"]}
  where
    host = "localhost"
    serverPort = 8080
    wsPort = 9160

newtype Scribble = Scribble T.Text
newtype Name = Name T.Text
newtype Role = Role T.Text

-- mu t. [?Protocol &  ]
--
--

addition :: WS.Connection -> IO ()
addition conn = forever $ do 
  x <- (read . T.unpack) <$> WS.receiveData conn
  y <- (read . T.unpack) <$> WS.receiveData conn
  WS.sendTextData conn (T.pack $ show $ x + y)

arithmetic :: WS.Connection -> IO ()
arithmetic conn = forever $ do
  action <- WS.receiveData conn
--  print action
--  print "foo"
--  print action
  case T.unpack action of
    "\"add\"" -> do
--       print "add"
       x <- ((read :: String -> Integer) . T.unpack) <$> WS.receiveData conn
--       print x
       y <- ((read :: String -> Integer) . T.unpack) <$> WS.receiveData conn
--       print y
       WS.sendTextData conn (T.pack $ show $ x + y)
       arithmetic conn
    "\"multiply\"" -> do
--       print "multiply"
       x <- ((read :: String -> Integer) . T.unpack) <$> WS.receiveData conn
--       print x
       y <- ((read :: String -> Integer) . T.unpack) <$> WS.receiveData conn
--       print y
       WS.sendTextData conn (T.pack $ show $ x * y)
       arithmetic conn
    _ -> return ()

pinger :: WS.Connection -> IO ()
pinger conn = forever $ do
  threadDelay 1000000
  id <- myThreadId
  WS.sendTextData conn (T.pack (show id))
  WS.sendTextData conn (T.pack (show id))
  res <- (WS.receiveData conn :: IO T.Text)
  print res

server :: WS.Connection -> IO ()
server conn = forever $ do
  prot <- WS.receiveData conn
  print $ "Received protocol: " <> (prot :: T.Text)
  action <- WS.receiveData conn
  case T.unpack action of
    "check" -> checkProt (Scribble prot) >>= print
    _ -> return ()

--   if action == ("check" :: T.Text) then return ()
--       else return ()-- do
--                   res <- checkModule
--                   return ()
--     "project" ->
--     "fsm"     ->
--     _ -> return ()
--   WS.sendTextData conn (T.reverse msg :: T.Text)

checkProt :: Scribble -> IO (Either T.Text T.Text)
checkProt _ = return $ Left "Not yet implemented"

project :: Scribble -> Name -> Role -> IO (Either T.Text Scribble)
project = undefined
