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
> import Control.Exception (finally)
> import Control.Monad (forever)
> import Data.Foldable (forM_)
> import Control.Concurrent (MVar, newMVar, modifyMVar_, modifyMVar, readMVar, myThreadId)
> import Data.Aeson
> import GHC.Generics
> import Control.Concurrent.Event ( Event )
> import Data.Ord (comparing)
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

> data Message 
>   = Message
>   { to :: Role
>   , body :: Text
>   } deriving (Generic, Show)
> instance FromJSON Message
> instance ToJSON Message

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

> proxy :: MVar ProxyState -> WS.ServerApp
> proxy sv pending = do
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
>     (Just (Message r msg)) <- decode <$> WS.receiveData conn
>     let (Just conn) = Map.lookup r cs
>     WS.sendTextData conn msg
>     print msg

> main :: IO ()
> main = do
>     state <- newMVar newProxyState
>     WS.runServer "127.0.0.1" 9160 $ proxy state

The state kept on the server is simply a list of connected clients. We've added
an alias and some utility functions, so it will be easier to extend this state
later on.

> type Client = (Text, WS.Connection)

> type ServerState = [Client]

Create a new, initial state:

> newServerState :: ServerState
> newServerState = []

Get the number of active clients:

> numClients :: ServerState -> Int
> numClients = length

Check if a user already exists (based on username):

> clientExists :: Client -> ServerState -> Bool
> clientExists client = any ((== fst client) . fst)

Add a client (this does not check if the client already exists, you should do
this yourself using `clientExists`):

> addClient :: Client -> ServerState -> ServerState
> addClient client clients = client : clients



Remove a client:

> removeClient :: Client -> ServerState -> ServerState
> removeClient client = filter ((/= fst client) . fst)

Send a message to all clients, and log it on stdout:

> broadcast :: Text -> ServerState -> IO ()
> broadcast message clients = do
>     T.putStrLn message
>     forM_ clients $ \(_, conn) -> WS.sendTextData conn message

The main function first creates a new state for the server, then spawns the
actual server. For this purpose, we use the simple server provided by
`WS.runServer`.

main :: IO ()
main = do
    state <- newMVar newServerState
    WS.runServer "127.0.0.1" 9160 $ application state


Our main application has the type:

> application :: MVar ServerState -> WS.ServerApp

Note that `WS.ServerApp` is nothing but a type synonym for
`WS.PendingConnection -> IO ()`.

Our application starts by accepting the connection. In a more realistic
application, you probably want to check the path and headers provided by the
pending request.

We also fork a pinging thread in the background. This will ensure the connection
stays alive on some browsers.

> application state pending = do
>     conn <- WS.acceptRequest pending
>     WS.forkPingThread conn 30

When a client is succesfully connected, we read the first message. This should
be in the format of "Hi! I am Jasper", where Jasper is the requested username.

>     msg <- WS.receiveData conn
>     clients <- readMVar state
>     case msg of

Check that the first message has the right format:

>         _   | not (prefix `T.isPrefixOf` msg) ->
>                 WS.sendTextData conn ("Wrong announcement" :: Text)

Check the validity of the username:

>             | any ($ fst client)
>                 [T.null, T.any isPunctuation, T.any isSpace] ->
>                     WS.sendTextData conn ("Name cannot " `mappend`
>                         "contain punctuation or whitespace, and " `mappend`
>                         "cannot be empty" :: Text)

Check that the given username is not already taken:

>             | clientExists client clients ->
>                 WS.sendTextData conn ("User already exists" :: Text)

All is right! We're going to allow the client, but for safety reasons we *first*
setup a `disconnect` function that will be run when the connection is closed.

>             | otherwise -> flip finally disconnect $ do

We send a "Welcome!", according to our own little protocol. We add the client to
the list and broadcast the fact that he has joined. Then, we give control to the
'talk' function.

>                modifyMVar_ state $ \s -> do
>                    let s' = addClient client s
>                    WS.sendTextData conn $
>                        "Welcome! Users: " `mappend`
>                        T.intercalate ", " (map fst s)
>                    broadcast (fst client `mappend` " joined") s'
>                    return s'
>                talk conn state client
>           where
>             prefix     = "Hi! I am "
>             client     = (T.drop (T.length prefix) msg, conn)
>             disconnect = do
>                 -- Remove client and return new state
>                 s <- modifyMVar state $ \s ->
>                     let s' = removeClient client s in return (s', s')
>                 broadcast (fst client `mappend` " disconnected") s

The talk function continues to read messages from a single client until he
disconnects. All messages are broadcasted to the other clients.

> talk :: WS.Connection -> MVar ServerState -> Client -> IO ()
> talk conn state (user, _) = forever $ do
>     msg <- WS.receiveData conn
>     readMVar state >>= broadcast
>         (user `mappend` ": " `mappend` msg)
