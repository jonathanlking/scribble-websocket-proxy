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

> {-# LANGUAGE OverloadedStrings #-}
> {-# LANGUAGE GeneralizedNewtypeDeriving #-}
> {-# LANGUAGE DuplicateRecordFields #-}
> {-# LANGUAGE DeriveGeneric #-}
> {-# LANGUAGE ScopedTypeVariables #-}

For generic-lens...

> {-# LANGUAGE AllowAmbiguousTypes       #-}
> {-# LANGUAGE DataKinds                 #-}
> {-# LANGUAGE DeriveGeneric             #-}
> {-# LANGUAGE DuplicateRecordFields     #-}
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
>   show (Session _ rs t) = "Session " ++ show t ++ ": " ++ show rs

> data Pending
>   = Pending
>   { protocol    :: Protocol
>   , clients     :: Map Role WS.Connection
>   , assignments :: Map Role Ident
>   , waiting     :: Set Role
>   , assembled   :: Event
>   } deriving (Generic)

> instance Show Pending where
>   show (Pending p _ rs wrs _)
>     = unlines [ "Pending: "
>               , show p
>               , show rs 
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
>     ass = Map.fromList [(Role "Buyer1", Ident "Jonathan"), (Role "Buyer2",
>               Ident "Nick"), (Role "Seller", Ident "Nobuko")]
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
>   mreq <- decode <$> WS.receiveData conn
>   case mreq of
>     Nothing -> do 
>       WS.sendClose conn ("Could not parse proxy request" :: Text)
>       return ()
>     Just (Req prot ass role) -> do
>       state <- takeMVar stateV
>       let entry = Map.lookup (prot, ass) (pending state)
>       accepted <- case entry of
>         Nothing  -> do
>           -- Case 1.
>           newPendV <- newEmptyMVar
>           let state' = state { pending = Map.insert (prot, ass) newPendV (pending state) }
>           putMVar stateV state'
>           seq state' (return ()) -- force evaluation

We now have a 'lock' on the new pending session, which has been added to the
global state, so it's safe to release our lock on the global state.

We should now create our new pending session and put it in the MVar, 'releasing'
the lock on it.

>           e <- Event.new
>           let newPend = Pending 
>                   { protocol = prot
>                   , clients = Map.insert role conn Map.empty
>                   , assignments = ass 
>                   , waiting = Set.delete role $ Map.keysSet ass
>                   , assembled = e
>                   }
>           putMVar newPendV newPend
>           seq newPend (return True) -- force evaluation


>         (Just pv) -> do
>           p@(Pending _ cs _ w _) <- takeMVar pv

We now no longer need a lock on the global state as we are only interested in
this particular pending session, which we have now locked.

>           putMVar stateV state
>           case Set.member role w of
>             False -> do
>               -- Case 2.
>               WS.sendClose conn ("Role has already been taken" :: Text)
>               return False
>             True -> do
>               let p' = p & field @"clients" .~ Map.insert role conn cs
>                          & field @"waiting" .~ Set.delete role w
>               putMVar pv p'
>               seq p' (return True)

We have released our locks on first the global state and then on the pending session.
We should check to see if the connection was 'accepted' or not, and if not we should
check to see if all the roles are now 'assembled'

>       case accepted of
>         False -> return ()
>         True -> do
>           state <- takeMVar stateV
>           let entry = Map.lookup (prot, ass) (pending state)
>           accepted <- case entry of
>             Nothing   -> putMVar stateV state

The state has been modified by another thread, so it is no longer pending (now
an active session) - we can relax!

>             (Just pv) -> do
>               p@(Pending _ cs _ w e) <- takeMVar pv
>               case Set.null w of
>                 False -> do
>                   putMVar pv p
>                   putMVar stateV state

We are still waiting for more roles to connect - release the pending and global
states.

>                 True  -> do
>                   let tok = nextToken state
>                   let sess = Session cs ass tok
>                   newSessV <- newMVar sess
>                   let state' = state & field @"sessions" %~ Map.insert tok newSessV
>                                      & field @"pending" %~ Map.delete (prot, ass)
>                                      & field @"nextToken" %~ (+1)
>                   putMVar stateV state'
>                   seq state' (return ())

Set the 'assembled' event, so the other clients can now continue to the 'proxy'
stage.

>                   Event.set e

>           return undefined  


  case res of
    Just ((slots, e), conn) 
      -> flip finally disconnect $ do
        if full slots then do 
          Event.set e
          putStrLn "All parties present, time to send messages!"
        else putStrLn "Still waiting for more people to join!"
        putStrLn "masky!"
        ms <- getMaskingState
        putStrLn (show ms ++ " ms")
        Event.wait e
        putStrLn "after"
        cons <- fst <$> readMVar state
        proxy conn cons
    Nothing -> putStrLn "Connection rejected as slots are full!"

data Handled = UpdatedState Integer | AlreadyTaken | StartSession Pending

handleReq :: ProxyState -> SessionReq -> WS.Connection -> IO (ProxyState, Handled)
handleReq state@(ss, pend, i) (Req p rs ident r) conn
  = case Map.lookupMin $ Map.filter pred pend of
      Nothing -> do
         e <- Event.new
         return ((ss, Map.insert i (new e) pend, i + 1), UpdatedState i) -- Case 1.
      (Just (_, Pending p' cs' rs' wrs' tok ready))
        | Set.member r wrs' && Set.size wrs' > 1  -- Case 2.
           -> return ((ss, Map.insert tok updated pend', i), UpdatedState tok)
        | Set.member r wrs' -> return ((ss, pend', i), StartSession updated) -- Case 3.
        | otherwise -> return (state, AlreadyTaken) -- Case 4.
        where
          updated = Pending p' (Map.insert r conn cs') (Set.insert (r, ident) rs') (Set.delete r wrs') tok ready
  where
    pred (Pending p' _ rs' _ _ _) = p == p' && rs == rs'
    pend' = Map.filter (not . pred) pend
    new = Pending p (Map.insert r conn Map.empty) rs (Set.delete r $ Set.map fst rs) i


    accept s@(slots, e) = do
      if full slots then do
        WS.rejectRequest pending "Slots are currently full"
        return (s, Nothing)
      else do 
        conn <- WS.acceptRequest pending
        WS.forkPingThread conn 30
        let s' = (insert (Just conn) slots, e)
        return (s', Just (s', conn))
    disconnect = do
        putStrLn "Somone disconnected"
        modifyMVar state $ \(slots, _) -> do
          forM_ (extract slots) (\conn -> WS.sendClose conn ("A client has closed the connection" :: Text))
          s <- newState
          return (s, s)



-- Pre: No waiting roles
initSession :: Pending -> MVar ProxyState -> IO ()
initSession (Pending p cs rs _ tok ready) sv = do
  forM_ cs setup
  Event.set ready
  modifyMVar_ sv (\(ss, pend, i) -> let s = (Map.insert tok (Session cs rs tok) ss, pend, i) in return s)
  where
    setup conn = do
      flip finally disconnect $ do
        WS.sendTextData conn (encode rs)
    disconnect = do  
      forM_ cs (\conn -> WS.sendClose conn ("A client has closed the connection" :: Text))
      modifyMVar_ sv (\(ss'', pend'', i) -> return (Map.delete tok ss'', pend'', i))

proxyOld :: MVar ProxyState -> WS.ServerApp
proxyOld sv pending = do
  conn <- WS.acceptRequest pending
  readMVar sv >>= print 
  mreq <- decode <$> WS.receiveData conn
  WS.forkPingThread conn 30
  WS.sendTextData conn (encode example)
  case mreq of
    Nothing -> WS.sendClose conn ("Invalid proxy request" :: Text)
    Just req -> do
      h <- modifyMVar sv (\state -> handleReq state req conn)
      case h of
        (StartSession pend) -> do
          initSession pend sv
          comm conn sv ((token :: Pending -> Token) pend)
        AlreadyTaken -> WS.sendClose conn ("Role has already been taken" :: Text)
        (UpdatedState tok) -> comm conn sv tok

comm :: WS.Connection -> MVar ProxyState -> Integer -> IO ()
comm conn sv tok = do 
  (_, pend,_) <- readMVar sv
  case fmap (ready :: Pending -> Event) $ Map.lookup tok pend of
    (Just e) -> Event.wait e
    Nothing -> return ()
  myThreadId >>= \i -> print $ "foo " ++ show i
  (ss, _, _) <- readMVar sv
  let (Just cs) = fmap (clients :: Session -> Map Role WS.Connection) $ Map.lookup tok ss 
  forever $ do
    (Just (Message r msg)) <- decode <$> WS.receiveData conn
    let (Just conn) = Map.lookup r cs
    WS.sendTextData conn msg
    print msg

main :: IO ()
main = do
    state <- newMVar newState
    WS.runServer "0.0.0.0" 9160 $ proxyOld state

================================================

Slot based proxy

> main :: IO ()
> main = do
>   print $ encode $ SMessage One "Hello world!"
>   state <- newState' >>= newMVar
>   WS.runServer "127.0.0.1" 9160 $ slotApplication state

> type SlotState' = (Maybe WS.Connection, Maybe WS.Connection, Maybe WS.Connection)
> type SlotState = (SlotState', Event)

> newState' :: IO SlotState
> newState' = (,) (Nothing, Nothing, Nothing) <$> Event.new

> full ((Just _), (Just _), (Just _)) = True
> full _ = False

> insert x (Nothing, y, z) = (x, y, z)
> insert y (x, Nothing, z) = (x, y, z)
> insert z (x, y, Nothing) = (x, y, z)
> insert _ _ = error "full!"

> slotApplication :: MVar SlotState -> WS.ServerApp
> slotApplication state pending = do
>   res <- modifyMVar state accept
>   case res of
>     Just ((slots, e), conn) 
>       -> flip finally disconnect $ do
>         if full slots then do 
>           Event.set e
>           putStrLn "All parties present, time to send messages!"
>         else putStrLn "Still waiting for more people to join!"
>         putStrLn "masky!"
>         ms <- getMaskingState
>         putStrLn (show ms ++ " ms")
>         Event.wait e
>         putStrLn "after"
>         cons <- fst <$> readMVar state
>         proxy conn cons
>     Nothing -> putStrLn "Connection rejected as slots are full!"
>   where
>     accept s@(slots, e) = do
>       if full slots then do
>         WS.rejectRequest pending "Slots are currently full"
>         return (s, Nothing)
>       else do 
>         conn <- WS.acceptRequest pending
>         WS.forkPingThread conn 30
>         let s' = (insert (Just conn) slots, e)
>         return (s', Just (s', conn))
>     disconnect = do
>         putStrLn "Somone disconnected"
>         modifyMVar state $ \(slots, _) -> do
>           forM_ (extract slots) (\conn -> WS.sendClose conn ("A client has closed the connection" :: Text))
>           s <- newState'
>           return (s, s)

> extract (x, y, z) = catMaybes [x, y, z]

> data Slot = One 
>           | Two 
>           | Three deriving (Generic, Show)
> instance FromJSON Slot 
> instance ToJSON Slot 

> data SMessage 
>   = SMessage
>   { to :: Slot
>   , body :: Text
>   } deriving (Generic, Show)
> instance FromJSON SMessage
> instance ToJSON SMessage

> select :: Slot -> (a, a, a) -> a
> select One (x, _, _)   = x
> select Two (_, y, _)   = y
> select Three (_, _, z) = z

> proxy :: WS.Connection -> SlotState' -> IO ()
> proxy conn cons = forever $ do
>   msg <- decode <$> WS.receiveData conn
>   case msg >>= (\(SMessage t b) -> (,) b <$> select t cons) of
>     Nothing -> return ()
>     (Just (body, conn)) -> WS.sendTextData conn body 
