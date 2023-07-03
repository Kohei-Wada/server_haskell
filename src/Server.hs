{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Server (serverMain) where

import Control.Concurrent (forkFinally) 
import Control.Monad (join, when, forever, void) 
import Network.Socket hiding (Broadcast) 
import Network.Socket.ByteString (recv, sendAll) 

import qualified Data.ByteString.Char8 as B8
import Text.Printf (printf)

import Control.Concurrent.STM.TVar
import Control.Concurrent.Async (race_) 
import Control.Concurrent.STM.TChan 
import Control.Monad.STM

import Data.ByteString (ByteString) 
import qualified Data.ByteString as B

import Control.Exception (mask, finally, bracket, bracketOnError) 

import Data.Map (Map)
import qualified Data.Map as M

port :: String
port = "4444"

data Server = Server 
    { clients :: TVar (Map ClientName Client) 
    , serverChan :: TChan Message
    , serverSock :: Socket
    } 

type ClientName = ByteString

data Client = Client 
    { clientName     :: ClientName
    , clientSock     :: Socket
    , clientKicked   :: TVar (Maybe ByteString) 
    , clientSendChan :: TChan Message 
    , broadcastChan  :: TChan Message
    }

data Message = Notice ByteString
             | Tell ClientName ByteString
             | Broadcast ClientName ByteString
             | Command ByteString

newClient :: Server -> ClientName -> Socket -> STM Client
newClient Server{..} name s = do 
    c <- newTChan 
    k <- newTVar Nothing
    bchan <- dupTChan serverChan
    pure Client 
        { clientName = name
        , clientSock = s
        , clientKicked = k 
        , clientSendChan = c
        , broadcastChan = bchan
        }


-- | Send a message to the specified client.
sendMessage :: Client -> Message -> STM ()  
sendMessage Client{..} msg = writeTChan clientSendChan msg


-- | Send a message to all connected clients.
broadcast :: Server -> Message -> STM () 
broadcast Server{..} msg = writeTChan serverChan msg


-- | Check if the given client name is alreay in use.
checkAddClient :: Server -> ClientName -> Socket -> IO (Maybe Client)
checkAddClient s@Server{..} name clientSock = atomically $ do
    clientMap <- readTVar clients
    if M.member name clientMap 
       then do 
           pure Nothing
       else do 
           client <- newClient s name clientSock
           writeTVar clients $ M.insert name client clientMap
           broadcast s $ Notice (name <> " has connected")
           pure (Just client) 


-- | Disconnect from the specified client.
removeClient :: Server -> Client -> IO ()
removeClient server@Server{..} Client{..} = atomically $ do
    modifyTVar' clients $ M.delete clientName
    broadcast server $ Notice (clientName <> " has disconnected")


talk :: Socket -> Server -> IO ()  
talk peerSock server = readName where
    readName = do 
        sendAll peerSock "What is your name?\n"
        name <- B8.init <$> recv peerSock 1024
        if B.null name 
           then readName
           else mask $ \restore -> do 
               ok <- checkAddClient server name peerSock
               case ok of 
                 Nothing -> restore $ do 
                     sendAll peerSock $ "The name " <> name <> " is in use, pelase choose another\n"
                     readName
                 Just client -> do 
                     sendAll peerSock "Enter '/help' to show help.\n"
                     restore (communicate server client) `finally` removeClient server client


communicate :: Server -> Client -> IO ()
communicate server client@Client{..} = loop `race_` receiver `race_` observer
    where
        receiver = forever $ do 
            bstring <- B8.init <$> recv clientSock 1024
            atomically $ sendMessage client (Command bstring)
        
        observer = forever $ atomically $ do 
            msg <- readTChan broadcastChan 
            sendMessage client msg

        loop = join $ atomically $ do
            k <- readTVar clientKicked
            case k of 
              Just reason -> pure $
                  sendAll clientSock $ "you have been kicked :" <> reason
              Nothing -> do 
                  msg <- readTChan clientSendChan
                  pure $ do 
                      continue <- handleMessage server client msg
                      when continue $ loop


handleMessage :: Server -> Client -> Message -> IO Bool
handleMessage server client@Client{..} message = do 
    case message of 
      Notice msg         -> output $ "*** " <> msg 
      Tell name msg      -> output $ "*" <> name <> "*:" <> msg 
      Broadcast name msg -> output $ "<" <> name <> ">" <> msg 
      Command msg -> 
          case B8.words msg of
            ["/quit"] -> do 
                sendAll clientSock "Goodbye!\n"
                pure False

            "/tell" : who : what -> do 
                tell server client who (B8.unwords what)
                pure True

            ["/kick", who] -> do 
                atomically $ kick server who clientName
                pure True

            ["/help"] -> do
                output helpMessage

            ["/?"] -> do
                output helpMessage

            [] -> pure True

            _ -> do 
                atomically $ broadcast server $ Broadcast clientName msg
                pure True
    where 
        output m = sendAll clientSock (m <> "\n") >> pure True


-- | Disconnect a client that specified by connected user.
kick :: Server -> ClientName -> ClientName -> STM () 
kick server@Server{..} who by = do 
    clientMap <- readTVar clients 
    case M.lookup who clientMap of 
      Nothing -> 
          void $ sendToName server by $ Notice (who <> " is not connected.")
      Just victim -> do 
          writeTVar (clientKicked victim) $ Just ("by " <> by)
          void $ sendToName server by $ Notice ("you kicked " <> who)


sendToName :: Server -> ClientName -> Message -> STM Bool
sendToName Server{..} name msg = do 
    clientMap <- readTVar clients
    case M.lookup name clientMap of 
      Nothing     -> pure False
      Just client -> sendMessage client msg >> pure True


tell :: Server -> Client -> ClientName -> ByteString -> IO () 
tell server Client{..} who msg = do 
    ok <- atomically $ sendToName server who (Tell clientName msg) 
    if ok 
       then pure () 
       else sendAll clientSock $ who <> " is not connected.\n"


resolveAddr :: IO AddrInfo
resolveAddr = do
    let mhost = Nothing
        hints = defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Stream }
    head <$> getAddrInfo (Just hints) mhost (Just port)


-- | Initialize the server instance.
newServer :: IO Server
newServer = do
    cs <- newTVarIO M.empty
    bchan <- newBroadcastTChanIO

    a <- resolveAddr
    sock <- openSocket a
    setSocketOption sock ReuseAddr 1
    bind sock $ addrAddress a

    pure $ Server
        { clients = cs
        , serverChan = bchan
        , serverSock = sock
        }


helpMessage :: ByteString
helpMessage = "Command are: /help, /tell, /kick, /quit, /?"


-- | discard the server instance.
discardServer :: Server -> IO ()
discardServer Server{..} = do
    close serverSock
    printf "Close server socket\n"


runServer :: Server -> IO ()
runServer s@Server{..} = do
    listen serverSock 1024
    printf "Listen on port %s\n" port

    forever $ do
        bracketOnError acceptPeer closePeer serve
            where
                acceptPeer = do
                    (peerSock, peer) <- accept serverSock
                    printf "Accepted connection from %s\n" (show peer)
                    pure (peerSock, peer)

                closePeer (peerSock, peer) = do
                    printf "Connection is closed by %s\n" (show peer)
                    close peerSock

                serve (peerSock, peer) = void $
                    forkFinally (talk peerSock s) $ \_ -> do
                            printf "Closed connection from %s\n" (show peer)
                            gracefulClose peerSock 5000


serverMain :: IO ()
serverMain = withSocketsDo $ bracket newServer discardServer runServer
