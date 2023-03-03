{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Main (main) where

import Control.Concurrent (forkFinally) 
import Control.Monad (join, when, forever, void) 
import Network.Socket hiding (Broadcast) 
import Network.Socket.ByteString (recv, sendAll) 

import qualified Data.ByteString.Char8 as B8
import Text.Printf (printf)

import Control.Concurrent.STM.TVar
import Control.Concurrent.Async (race) 
import Control.Concurrent.STM.TChan 
import Control.Monad.STM

import Data.ByteString (ByteString) 
import qualified Data.ByteString as B

import Control.Exception (mask, finally) 
import qualified Control.Exception as E

import Data.Map (Map)
import qualified Data.Map as M

port :: String
port = "4444"

newtype Server = Server 
    { clients :: TVar (Map ClientName Client) 
    } 

type ClientName = ByteString

data Client = Client 
    { clientName     :: ClientName
    , clientSock     :: Socket
    , clientKicked   :: TVar (Maybe ByteString) 
    , clientSendChan :: TChan Message 
    }

data Message = Notice ByteString
             | Tell ClientName ByteString
             | Broadcast ClientName ByteString
             | Command ByteString

newClient :: ClientName -> Socket -> STM Client
newClient name s = do 
    c <- newTChan 
    k <- newTVar Nothing
    pure Client 
        { clientName = name
        , clientSock = s
        , clientKicked = k 
        , clientSendChan = c
        }

sendMessage :: Client -> Message -> STM ()  
sendMessage Client{..} msg = writeTChan clientSendChan msg

newServer :: IO Server
newServer = do 
    cs <- newTVarIO M.empty 
    pure $ Server { clients = cs } 

broadcast :: Server -> Message -> STM () 
broadcast Server{..} msg = do 
    clientMap <- readTVar clients
    mapM_ (\client -> sendMessage client msg) (M.elems clientMap) 


checkAddClient :: Server -> ClientName -> Socket -> IO (Maybe Client) 
checkAddClient server@Server{..} name s = atomically $ do 
    clientMap <- readTVar clients
    if M.member name clientMap 
       then do 
           pure Nothing
       else do 
           client <- newClient name s
           writeTVar clients $ M.insert name client clientMap
           broadcast server $ Notice (name <> " has connected")
           pure (Just client) 


removeClient :: Server -> ClientName -> IO () 
removeClient server@Server{..} name = atomically $ do 
    modifyTVar' clients $ M.delete name
    broadcast server $ Notice (name <> " has disconnected")


talk :: Socket -> Server -> IO ()  
talk s server = readName where
    readName = do 
        sendAll s "What is your name?\n"
        name <- B.init <$> recv s 1024
        if B.null name 
           then readName
           else mask $ \restore -> do 
               ok <- checkAddClient server name s
               case ok of 
                 Nothing -> restore $ do 
                     sendAll s $ "The name " <> name <> " is in use, pelase choose another\n"
                     readName
                 Just client -> do 
                     restore (runClient server client) `finally` removeClient server name


runClient :: Server -> Client -> IO () 
runClient serv client@Client{..} = void $ race server receive
    where
        receive = forever $ do 
            msg <- B.init <$> recv clientSock 1024
            atomically $ sendMessage client (Command msg)
        
        server = join $ atomically $ do 
            k <- readTVar clientKicked
            case k of 
              Just reason -> pure $
                  sendAll clientSock $ "You have been kicked :" <> reason
              Nothing -> do 
                  msg <- readTChan clientSendChan
                  pure $ do 
                      continue <- handleMessage serv client msg
                      when continue $ server


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

            "/" : _  -> output $ msg <> " is unrecognized command."

            "/tell" : who : what -> do 
                tell server client who (B8.unwords what)
                pure True

            ["/kick", who] -> do 
                atomically $ kick server who clientName
                pure True

            [] -> pure True

            _ -> do 
                atomically $ broadcast server $ Broadcast clientName msg
                pure True
    where 
        output m = sendAll clientSock (m <> "\n") >> pure True


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


main :: IO () 
main = withSocketsDo $ do 
    let mhost = Nothing
        hints = defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Stream }

    server <- newServer
    addr   <- head <$> getAddrInfo (Just hints) mhost (Just port) 

    E.bracket 
        (do 
            sock <- openSocket addr 
            setSocketOption sock ReuseAddr 1
            bind sock $ addrAddress addr 
            listen sock 1024
            printf "Listen on port %s\n" port
            pure sock 
        ) 

        (\sock -> do 
            printf "Close server socket\n"
            close sock
        )

        (\sock -> 
            forever $ do 
                E.bracketOnError 
                    (do
                        (conn, peer) <- accept sock 
                        printf "Accepted connection from %s\n" (show peer)
                        pure (conn, peer)
                    )

                    (\(conn, peer) -> do 
                        printf "Connection is closed by %s\n" (show peer)
                        close conn
                    )

                    (\(conn, peer) -> do 
                        forkFinally (talk conn server) 
                            (\_ -> do
                                printf "Closed connection from %s\n" (show peer)
                                gracefulClose conn 5000
                            ) 
                    )
        )
