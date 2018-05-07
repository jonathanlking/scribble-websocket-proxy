Multiparty WebSocket Proxy
==========================

This is an implementation of the WebSocket proxy which performs matchmaking and
routing for multiparty WebSocket sessions. This implementation is inspired by
the example chat server from the [`websockets`
library](https://github.com/jaspervdj/websockets/blob/master/example/server.lhs).

During session initialisation all parties communicate with each other and
establish communication channels between all roles. It is difficult however to
open a direct peer to peer connection between two web browsers, as you might not
know the IP address of the browser you want to connect to (and incoming requests
might be blocked). The aim of this proxy is to provide a single statically known
address where all parties can connect and sent and receive messages from.
Messages are correctly routed to the correct role and network failure events are
propagated to all parties.

TODO: Handle masking correctly during state mutation

> {-# LANGUAGE OverloadedStrings #-}
> {-# LANGUAGE GeneralizedNewtypeDeriving #-}
> {-# LANGUAGE DuplicateRecordFields #-}
> {-# LANGUAGE DeriveGeneric #-}
> {-# LANGUAGE ScopedTypeVariables #-}

Required for generic-lens:

> {-# LANGUAGE AllowAmbiguousTypes       #-}
> {-# LANGUAGE DataKinds                 #-}
> {-# LANGUAGE FlexibleContexts          #-}
> {-# LANGUAGE NoMonomorphismRestriction #-}
> {-# LANGUAGE TypeApplications          #-}

> module Main where
> import Data.Char (isPunctuation, isSpace)
> import Data.Monoid (mappend)
> import Data.Text (Text)
> import Data.Function (on)
> import Control.Exception (finally, getMaskingState)
> import Control.Monad (forever)
> import Control.Lens
> import Data.Foldable (forM_)
> import Control.Concurrent (MVar, newMVar, newEmptyMVar, modifyMVar_, modifyMVar, readMVar, myThreadId, takeMVar, putMVar)
> import Data.Aeson
> import GHC.Generics
> import Control.Concurrent.Event (Event)
> import Data.Map.Strict (Map)
> import Data.Set (Set)
> import Data.Ord (comparing)
> import Data.Maybe (catMaybes)
> import Data.Generics.Product
> import qualified Control.Concurrent.Event as Event
> import qualified Data.List as List
> import qualified Data.Text as T
> import qualified Data.Text.IO as T
> import qualified Data.Map.Strict as Map
> import qualified Data.Set as Set
> import qualified Network.WebSockets as WS

Either a client is waiting for a session to begin (i.e. for the other roles to
connect) or it is part of an ongoing session. 

When a client connects it provides:
  * The name of the protocol
  * Its unique identifier and role it will perform
  * All other roles and identifiers of who will perform them

(If the identifier is not unique, there is a race condition on the connection
which will play the role in the session). A potential improvement is to be able
to underspecify - i.e. to introduce "don't care" identifiers for roles.

> newtype Role = Role Text
>   deriving (Generic, Show, Eq, Ord, ToJSONKey, FromJSONKey, ToJSON, FromJSON)

> newtype Ident = Ident Text
>   deriving (Generic, Show, Eq, Ord, ToJSON, FromJSON)

> data Protocol 
>   = Protocol
>   { name :: Text
>   , roles :: Set Role
>   } deriving (Generic, Show, Eq, Ord)

> instance FromJSON Protocol
> instance ToJSON Protocol

> data Message
>   = Message
>   { to :: Role
>   , body :: Text
>   } deriving (Generic, Show)
> instance FromJSON Message
> instance ToJSON Message

> data Session 
>   = Session 
>   { clients     :: Map Role WS.Connection
>   , assignments :: Map Role Ident
>   , token       :: Integer
>   } deriving (Generic)

> instance Show Session where
>   show (Session _ ass tok) = "Session " ++ show tok ++ ": " ++ show ass

> data Pending
>   = Pending
>   { protocol    :: Protocol
>   , clients     :: Map Role WS.Connection
>   , assignments :: Map Role Ident
>   , token       :: Integer
>   , waiting     :: Set Role
>   , assembled   :: Event
>   } deriving (Generic)

> instance Show Pending where
>   show (Pending p _ ass tok wrs _)
>     = unlines [ "Pending: (" ++ show tok ++ ")"
>               , show p
>               , show ass 
>               , "Waiting for: " ++ show wrs
>               ]

We need to write instances of Eq/Ord for Session and Pending as they are being
stored in Maps.

> instance Eq Session where
>   (==) = on (==) (token :: Session -> Integer)
> instance Ord Session where
>   compare = comparing (token :: Session -> Integer)

Cannot derive Eq/Ord for Pending because WS.Connection doesn't isn't an instance
+ it only makes sense to compare on protocol and assignments (as this uniquely
identifies any pending connection). Instead of writing the instances by hand
though we can make a duplicate (smaller) data type which we can derive the
instances for!

> data PendingOrd
>  = PendingOrd
>  { protocol :: Protocol
>  , assignments :: Map Role Ident
>  } deriving (Generic, Eq, Ord)

> instance Eq Pending where
>   (==) = on (==) (upcast :: Pending -> PendingOrd)
> instance Ord Pending where
>   compare = comparing (upcast :: Pending -> PendingOrd)

> data SessionReq
>   = Req
>   { protocol   :: Protocol
>   , assignment :: Map Role Ident
>   , role       :: Role
>   } deriving (Generic, Show)

> instance FromJSON SessionReq
> instance ToJSON SessionReq

> exampleReq = Req (Protocol "TwoBuyer" roles) ass (Role "Buyer1")
>   where
>     ass = Map.fromList [(Role "Buyer1", Ident "Alice"), (Role "Buyer2",
>               Ident "Bob"), (Role "Seller", Ident "Sarah")]
>     roles = Set.fromList [Role "Buyer1", Role "Buyer2", Role "Seller"]

The connection handler needs to have some way to 'get' the connection of another
role in the session in order to forward the message.

> type Token = Integer
> type PendingKey = (Protocol, Map Role Ident)

> data State
>   = State
>   { sessions  :: Map Token (MVar Session)
>   , pending   :: Map PendingKey (MVar Pending)
>   , nextToken :: Token
>   } deriving (Generic)

> newState :: State
> newState = State Map.empty Map.empty 0

Go through the pending states and see if any of them are waiting for this client
to connect. If a request matches an existing pending session it will be
rejected. This is to prevent competing request groups which could result in a
deadlock.

There are three possible cases:

1. No pending sessions -> create a new pending session
Pending: 
    2. Role already taken -> throw an error
    3. Role not taken -> take it

If all roles now connected -> set the `assembled` event

(Note that we must set the assembled event _before_ the final role starts the
proxy phase, otherwise we would block forever)

> application :: MVar State -> WS.ServerApp
> application stateV pend = do
>   conn <- WS.acceptRequest pend
>   WS.forkPingThread conn 30
>   mreq <- decode <$> WS.receiveData conn
>   case mreq of
>     Nothing -> do 
>       WS.sendClose conn ("Could not parse proxy request" :: Text)
>       print "Unable to parse proxy request"
>       return ()
>     Just (Req prot ass role) -> do
>       print ass 
>       state <- takeMVar stateV
>       let entry = Map.lookup (prot, ass) (pending state)
>       accepted <- case entry of
>         Nothing  -> do
>           -- Case 1.
>           newPendV <- newEmptyMVar
>           let tok = nextToken state
>           let state' = state & field @"pending" %~ Map.insert (prot, ass) newPendV
>                              & field @"nextToken" %~ (+1)
>           putMVar stateV state'
>           seq state' (return ())

We now have a 'lock' on the new pending session, which has been added to the
global state, so it's safe to release our lock on the global state.

We should now create our new pending session and put it in the MVar, 'releasing'
the lock on it.

>           e <- Event.new
>           let newPend = Pending 
>                   { protocol = prot
>                   , clients = Map.insert role conn Map.empty
>                   , assignments = ass 
>                   , token = tok
>                   , waiting = Set.delete role $ Map.keysSet ass
>                   , assembled = e
>                   }
>           putMVar newPendV newPend
>           seq newPend (return (Just (tok, e))) -- force evaluation


>         (Just pv) -> do
>           p@(Pending _ cs _ tok w e) <- takeMVar pv

We now no longer need a lock on the global state as we are only interested in
this particular pending session, which we have now locked.

>           putMVar stateV state
>           case Set.member role w of
>             False -> do
>               -- Case 2.
>               WS.sendClose conn ("Role has already been taken" :: Text)
>               return Nothing 
>             True -> do
>               let p' = p & field @"clients" .~ Map.insert role conn cs
>                          & field @"waiting" .~ Set.delete role w
>               putMVar pv p'
>               seq p' (return (Just (tok, e)))

We have released our locks on first the global state and then on the pending session.
We should check to see if the connection was 'accepted' or not, and if not we should
check to see if all the roles are now 'assembled'

>       case accepted of
>         Nothing -> return ()
>         (Just (tok, e)) -> do
>           state <- takeMVar stateV
>           let entry = Map.lookup (prot, ass) (pending state)
>           case entry of
>             Nothing   -> putMVar stateV state

The state has been modified by another thread, so it is no longer pending (now
an active session) - we can relax!

>             (Just pv) -> do
>               p@(Pending _ cs _ tok w _) <- takeMVar pv
>               case Set.null w of
>                 False -> do
>                   putMVar pv p
>                   putMVar stateV state

We are still waiting for more roles to connect - release the pending and global
states.

>                 True  -> do
>                   let sess = Session cs ass tok
>                   newSessV <- newMVar sess
>                   let state' = state & field @"sessions" %~ Map.insert tok newSessV
>                                      & field @"pending" %~ Map.delete (prot, ass)
>                   putMVar stateV state'
>                   seq state' (return ())

Set the 'assembled' event, so the other clients can now continue to the 'proxy'
stage.

>                   Event.set e
>           Event.wait e

The following will only be executed once the session has started

>           ss <- sessions <$> readMVar stateV
>           case Map.lookup tok ss of

The session is over before this client even got a chance to communicate... This
is because another client disconnected and destroyed the session.

>             Nothing -> return ()

We will get the assignment of roles to connections (once, as this shouldn't
change during a session) and then proceed to the routing phase.

>             (Just sessV) -> do
>               cons <- getField @"clients" <$> readMVar sessV
>               flip finally (disconnect cons) $ do
>                 forever $ do
>                   msg <- decode <$> WS.receiveData conn
>                   case msg >>= (\(Message role b) -> (,) b <$> Map.lookup role cons) of
>                     Nothing -> return () -- TODO: Do we really want to ignore?
>                     (Just (body, conn)) -> WS.sendTextData conn body
>               where
>                 disconnect cons = do
>                   state <- takeMVar stateV
>                   case Map.member tok (sessions state) of

The session has already been cleaned up - release the global state.

>                     False -> putMVar stateV state

We need to clean the session up.

>                     True  -> do                     
>                       putStrLn $ "Cleaning up session " ++ (show tok)
>                       forM_ cons (\conn -> WS.sendClose conn ("A client has closed the connection" :: Text))
>                       let state' = state & field @"sessions" %~ Map.delete tok
>                       putMVar stateV state'
>                       seq state' (return ())

> main :: IO ()
> main = do
>   putStrLn $ show $ encode $ exampleReq
>   state <- newMVar newState
>   WS.runServer "127.0.0.1" 9160 $ application state

A helper function to dump the state of the server

> dump :: MVar State -> IO ()
> dump sv = do
>   (State ss ps nt) <- readMVar sv
>   let f s = readMVar s >>= print
>   forM_ ss f  
>   forM_ ps f  
>   print nt
