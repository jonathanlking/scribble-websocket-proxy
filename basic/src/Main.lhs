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

> module Main where
> import Data.Char (isPunctuation, isSpace)
> import Data.Monoid (mappend)
> import Data.Text (Text)
> import Control.Exception (finally, getMaskingState)
> import Control.Monad (forever)
> import Data.Foldable (forM_)
> import Control.Concurrent (MVar, newMVar, modifyMVar_, modifyMVar, readMVar, myThreadId)
> import Data.Aeson
> import GHC.Generics
> import Control.Concurrent.Event ( Event )
> import Data.Ord (comparing)
> import Data.Maybe (catMaybes)
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

> newtype Role = Role Text deriving (Generic, Show, Eq, Ord)
> instance FromJSON Role
> instance ToJSON Role

> newtype Ident = Ident Text deriving (Generic, Show, Eq, Ord)
> instance FromJSON Ident
> instance ToJSON Ident

> newtype Protocol = Protocol Text deriving (Generic, Show, Eq)
> instance FromJSON Protocol
> instance ToJSON Protocol

> data OldMessage 
>   = OldMessage
>   { to :: Role
>   , body :: Text
>   } deriving (Generic, Show)
> instance FromJSON OldMessage
> instance ToJSON OldMessage

> data Session 
>   = Session 
>   { clients :: Map.Map Role WS.Connection
>   , roles   :: Set.Set (Role, Ident)
>   , token :: Integer
>   } 

> instance Show Session where
>   show (Session _ rs t) = "Session " ++ show t ++ ": " ++ show rs

> instance Eq Session where
>   p == p' =  (token :: Session -> Integer) p == (token :: Session -> Integer) p'
> instance Ord Session where
>   compare = comparing (token :: Session -> Integer)

> data Pending
>   = Pending
>   { protocol :: Protocol
>   , clients  :: Map.Map Role WS.Connection
>   , roles    :: Set.Set (Role, Ident)
>   , waiting  :: Set.Set Role
>   , token    :: Integer
>   , ready    :: Event
>   }

> instance Show Pending where
>   show (Pending p _ rs wrs t _) = "Pending: " ++ show p ++ " " ++ show rs ++ " |waiting: " ++ show wrs ++ " | token: " ++ show t

> instance Eq Pending where
>   p == p' =  (token :: Pending -> Integer) p == (token :: Pending -> Integer) p'
> instance Ord Pending where
>   compare = comparing (token :: Pending -> Integer)

> data SessionReq
>   = Req
>   { protocol :: Protocol
>   , roles    :: Set.Set (Role, Ident)
>   , ident    :: Ident
>   , role     :: Role -- Semi-redundant, could be inferred from ident and roles
>   } deriving (Generic, Show)

> instance FromJSON SessionReq
> instance ToJSON SessionReq

> example = Req (Protocol "TwoBuyer") roles (Ident "Jonathan") (Role "Buyer1")
>   where
>     roles = Set.fromList [(Role "Buyer1", Ident "Jonathan"), (Role "Buyer2",
>               Ident "Nick"), (Role "Seller", Ident "Nobuko")]

The connection handler needs to have some way to 'get' the connection of another
role in the session in order to forward the message.

> type Token = Integer
> type ProxyState = (Map.Map Token Session, Map.Map Token Pending, Integer)

> newProxyState :: ProxyState
> newProxyState = (Map.empty, Map.empty, 0)

Go through the pending states and see if any of them are waiting for this client
to connect. If a request matches an existing pending session it will be
rejected. This is to prevent competing request groups which could result in a
deadlock.

There are four possible cases:

1. No Pending - so create a new one
2. Pending - role not taken - so take it
3. Pending - now complete - should start session and become Session
4. Pending - role already taken - throw an error


> -- Pre: No waiting roles
> initSession :: Pending -> MVar ProxyState -> IO ()
> initSession (Pending p cs rs _ tok ready) sv = do
>   forM_ cs setup
>   Event.set ready
>   modifyMVar_ sv (\(ss, pend, i) -> let s = (Map.insert tok (Session cs rs tok) ss, pend, i) in return s)
>   where
>     setup conn = do
>       flip finally disconnect $ do
>         WS.sendTextData conn (encode rs)
>     disconnect = do  
>       forM_ cs (\conn -> WS.sendClose conn ("A client has closed the connection" :: Text))
>       modifyMVar_ sv (\(ss'', pend'', i) -> return (Map.delete tok ss'', pend'', i))

> data Handled = UpdatedState Integer | AlreadyTaken | StartSession Pending

> handleReq :: ProxyState -> SessionReq -> WS.Connection -> IO (ProxyState, Handled)
> handleReq state@(ss, pend, i) (Req p rs ident r) conn
>   = case Map.lookupMin $ Map.filter pred pend of
>       Nothing -> do
>          e <- Event.new
>          return ((ss, Map.insert i (new e) pend, i + 1), UpdatedState i) -- Case 1.
>       (Just (_, Pending p' cs' rs' wrs' tok ready))
>         | Set.member r wrs' && Set.size wrs' > 1  -- Case 2.
>            -> return ((ss, Map.insert tok updated pend', i), UpdatedState tok)
>         | Set.member r wrs' -> return ((ss, pend', i), StartSession updated) -- Case 3.
>         | otherwise -> return (state, AlreadyTaken) -- Case 4.
>         where
>           updated = Pending p' (Map.insert r conn cs') (Set.insert (r, ident) rs') (Set.delete r wrs') tok ready
>   where
>     pred (Pending p' _ rs' _ _ _) = p == p' && rs == rs'
>     pend' = Map.filter (not . pred) pend
>     new = Pending p (Map.insert r conn Map.empty) rs (Set.delete r $ Set.map fst rs) i

> proxyOld :: MVar ProxyState -> WS.ServerApp
> proxyOld sv pending = do
>   conn <- WS.acceptRequest pending
>   readMVar sv >>= print 
>   mreq <- decode <$> WS.receiveData conn
>   WS.forkPingThread conn 30
>   WS.sendTextData conn (encode example)
>   case mreq of
>     Nothing -> WS.sendClose conn ("Invalid proxy request" :: Text)
>     Just req -> do
>       h <- modifyMVar sv (\state -> handleReq state req conn)
>       case h of
>         (StartSession pend) -> do
>           initSession pend sv
>           comm conn sv ((token :: Pending -> Token) pend)
>         AlreadyTaken -> WS.sendClose conn ("Role has already been taken" :: Text)
>         (UpdatedState tok) -> comm conn sv tok

> comm :: WS.Connection -> MVar ProxyState -> Integer -> IO ()
> comm conn sv tok = do 
>   (_, pend,_) <- readMVar sv
>   case fmap (ready :: Pending -> Event) $ Map.lookup tok pend of
>     (Just e) -> Event.wait e
>     Nothing -> return ()
>   myThreadId >>= \i -> print $ "foo " ++ show i
>   (ss, _, _) <- readMVar sv
>   let (Just cs) = fmap (clients :: Session -> Map.Map Role WS.Connection) $ Map.lookup tok ss 
>   forever $ do
>     (Just (OldMessage r msg)) <- decode <$> WS.receiveData conn
>     let (Just conn) = Map.lookup r cs
>     WS.sendTextData conn msg
>     print msg

main :: IO ()
main = do
    state <- newMVar newProxyState
    WS.runServer "0.0.0.0" 9160 $ proxyOld state

> main :: IO ()
> main = do
>   print $ encode $ Message One "Hello world!"
>   state <- newState >>= newMVar
>   WS.runServer "127.0.0.1" 9160 $ application state

> type State' = (Maybe WS.Connection, Maybe WS.Connection, Maybe WS.Connection)
> type State = (State', Event)

> newState :: IO State
> newState = (,) (Nothing, Nothing, Nothing) <$> Event.new

> full ((Just _), (Just _), (Just _)) = True
> full _ = False

> insert x (Nothing, y, z) = (x, y, z)
> insert y (x, Nothing, z) = (x, y, z)
> insert z (x, y, Nothing) = (x, y, z)
> insert _ _ = error "full!"

> application :: MVar State -> WS.ServerApp
> application state pending = do
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
>           s <- newState
>           return (s, s)

> extract (x, y, z) = catMaybes [x, y, z]

> data Slot = One 
>           | Two 
>           | Three deriving (Generic, Show)
> instance FromJSON Slot 
> instance ToJSON Slot 

> data Message 
>   = Message
>   { to :: Slot
>   , body :: Text
>   } deriving (Generic, Show)
> instance FromJSON Message
> instance ToJSON Message

> select :: Slot -> (a, a, a) -> a
> select One (x, _, _)   = x
> select Two (_, y, _)   = y
> select Three (_, _, z) = z

> proxy :: WS.Connection -> State' -> IO ()
> proxy conn cons = forever $ do
>   msg <- decode <$> WS.receiveData conn
>   case msg >>= (\(Message t b) -> (,) b <$> select t cons) of
>     Nothing -> return ()
>     (Just (body, conn)) -> WS.sendTextData conn body 
