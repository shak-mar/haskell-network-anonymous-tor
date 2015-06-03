{-# LANGUAGE OverloadedStrings #-}

-- | Protocol description
--
-- Defines functions that handle the advancing of the Tor control protocol.
--
--   __Warning__: This function is used internally by 'Network.Anonymous.Tor'
--                and using these functions directly is unsupported. The
--                interface of these functions might change at any time without
--                prior notice.
--
module Network.Anonymous.Tor.Protocol ( Availability (..)
                                      , isAvailable
                                      , socksPort
                                      , connect
                                      , connect'
                                      , protocolInfo
                                      , authenticate
                                      , mapOnion ) where

import           Control.Concurrent.MVar

import           Control.Monad                             (unless, void, when)
import           Control.Monad.Catch                       ( handle
                                                           , handleIOError )
import           Control.Monad.IO.Class

import qualified System.IO.Error as E
import qualified GHC.IO.Exception as E hiding (ProtocolError)

import qualified Data.Attoparsec.ByteString                as Atto
import qualified Data.Base32String.Default                 as B32
import qualified Data.ByteString                           as BS
import qualified Data.ByteString.Char8                     as BS8
import qualified Data.HexString                            as HS
import           Data.Maybe                                (fromJust)

import qualified Data.Text.Encoding                        as TE

import qualified Network.Attoparsec                        as NA
import qualified Network.Simple.TCP                        as NST

import qualified Network.Socket                            as Network hiding
                                                                       (recv,
                                                                       send)
import qualified Network.Socket.ByteString                 as Network
import qualified Network.Socks5                            as Socks

import qualified Network.Anonymous.Tor.Error               as E
import qualified Network.Anonymous.Tor.Protocol.Parser     as Parser
import qualified Network.Anonymous.Tor.Protocol.Parser.Ast as Ast
import qualified Network.Anonymous.Tor.Protocol.Types      as T

sendCommand :: MonadIO m
            => Network.Socket -- ^ Our connection with the Tor control port
            -> BS.ByteString  -- ^ The command / instruction we wish to send
            -> m [Ast.Line]
sendCommand sock = sendCommand' sock 250 E.protocolErrorType

sendCommand' :: MonadIO m
             => Network.Socket -- ^ Our connection with the Tor control port
             -> Integer        -- ^ The status code we expect
             -> E.TorErrorType -- ^ The type of error to throw if status code doesn't match
             -> BS.ByteString  -- ^ The command / instruction we wish to send
             -> m [Ast.Line]
sendCommand' sock status errorType msg = do
  _   <- liftIO $ Network.sendAll sock msg
  res <- liftIO $ NA.parseOne sock (Atto.parse Parser.reply)

  when (Ast.statusCode res /= status)
    (E.torError (E.mkTorError errorType))

  return res

-- | Represents the availability status of Tor for a specific port.
data Availability =
  Available |         -- ^ There is a Tor control service listening at the port
  ConnectionRefused | -- ^ There is no service listening at the port
  IncorrectPort       -- ^ There is a non-Tor control service listening at the port
  deriving (Show, Eq)

-- | Probes a port to see if there is a service at the remote that behaves
--   like the Tor controller daemon. Will return the status of the probed
--   port.
isAvailable :: MonadIO m
            => Integer        -- ^ The ports we wish to probe
            -> m Availability -- ^ The status of all the ports
isAvailable port = liftIO $ do

  result <- newEmptyMVar

  handle (\(E.TorError E.ProtocolError) -> putMVar result IncorrectPort)
    $ handleIOError (\e  ->
                      -- The error raised for a Connection Refused is a very descriptive OtherError
                      if   E.ioeGetErrorType e == E.OtherError || E.ioeGetErrorType e == E.NoSuchThing
                      then putMVar result ConnectionRefused
                      else E.ioError e)
    (performTest port result)

  takeMVar result

  where
    performTest port result =
      NST.connect "127.0.0.1" (show port) (\(sock, _) -> do
                                                _ <- protocolInfo sock
                                                putMVar result Available)
-- | Returns the configured SOCKS proxy port
socksPort :: MonadIO m
          => Network.Socket
          -> m Integer
socksPort s = do
  reply <- sendCommand s (BS8.pack "GETCONF SOCKSPORT\n")

  return . fst . fromJust . BS8.readInteger . fromJust . Ast.tokenValue . head . Ast.lineMessage . fromJust $ Ast.line (BS8.pack "SocksPort") reply

-- | Connect through a remote using the Tor SOCKS proxy. The remote might me a
--   a normal host/ip or a hidden service address. When you provide a FQDN to
--   resolve, it will be resolved by the Tor service, and as such is secure.
--
--   This function is provided as a convenience, since it doesn't actually use
--   the Tor control protocol, and can be used to talk with any Socks5 compatible
--   proxy server.
connect :: MonadIO m
        => Integer                  -- ^ Port our tor SOCKS server listens at.
        -> Socks.SocksAddress       -- ^ Address we wish to connect to
        -> (Network.Socket -> IO a) -- ^ Computation to execute once connection has been establised
        -> m a
connect sport remote callback = liftIO $ do
  (sock, _) <- Socks.socksConnect conf remote
  callback sock

  where
    conf = Socks.defaultSocksConf "127.0.0.1" (fromInteger sport)

connect' :: MonadIO m
         => Network.Socket           -- ^ Our connection with the Tor control port
         -> Socks.SocksAddress       -- ^ Address we wish to connect to
         -> (Network.Socket -> IO a) -- ^ Computation to execute once connection has been establised
         -> m a
connect' sock remote callback = do
  sport <- socksPort sock
  connect sport remote callback

-- | Requests protocol version information from Tor. This can be used while
--   still unauthenticated and authentication methods can be derived from this
--   information.
protocolInfo :: MonadIO m
             => Network.Socket
             -> m T.ProtocolInfo
protocolInfo s = do
  res <- sendCommand s (BS.concat ["PROTOCOLINFO", "\n"])

  return (T.ProtocolInfo (protocolVersion res) (torVersion res) (methods res) (cookieFile res))

  where

    protocolVersion :: [Ast.Line] -> Integer
    protocolVersion reply =
      fst . fromJust . BS8.readInteger . Ast.tokenKey . last . Ast.lineMessage . fromJust $ Ast.line (BS8.pack "PROTOCOLINFO") reply

    torVersion :: [Ast.Line] -> [Integer]
    torVersion reply =
      map (fst . fromJust . BS8.readInteger) . BS8.split '.' . fromJust . Ast.value "Tor" . Ast.lineMessage . fromJust $ Ast.line (BS8.pack "VERSION") reply

    methods :: [Ast.Line] -> [T.AuthMethod]
    methods reply =
      map (read . BS8.unpack) . BS8.split ',' . fromJust . Ast.value "METHODS" . Ast.lineMessage . fromJust $ Ast.line (BS8.pack "AUTH") reply

    cookieFile :: [Ast.Line] -> Maybe FilePath
    cookieFile reply =
      fmap BS8.unpack . Ast.value "COOKIEFILE" . Ast.lineMessage . fromJust $ Ast.line (BS8.pack "AUTH") reply

-- | Authenticates with the Tor control server, based on the authentication
--   information returned by PROTOCOLINFO.
authenticate :: MonadIO m
             => Network.Socket
             -> m ()
authenticate s = do
  info <- protocolInfo s

  -- Ensure that we can authenticate using a cookie file
  unless (T.Cookie `elem` T.authMethods info)
    (E.torError (E.mkTorError E.permissionDeniedErrorType))

  cookieData <- liftIO $ readCookie (T.cookieFile info)

  liftIO . void $ sendCommand' s 250 E.permissionDeniedErrorType (BS8.concat ["AUTHENTICATE ", TE.encodeUtf8 $ HS.toText cookieData, "\n"])

  where

    readCookie :: Maybe FilePath -> IO HS.HexString
    readCookie Nothing     = E.torError (E.mkTorError E.protocolErrorType)
    readCookie (Just file) = return . HS.fromBytes =<< BS.readFile file

-- | Creates a new hidden service and maps a public port to a local port. Useful
--   for bridging a local service (e.g. a webserver or irc daemon) as a Tor
--   hidden service.
mapOnion :: MonadIO m
         => Network.Socket     -- ^ Connection with tor Control port
         -> Integer            -- ^ Remote point of hidden service to listen at
         -> Integer            -- ^ Local port to map onion service to
         -> m B32.Base32String -- ^ The address/service id of the Onion without the .onion aprt
mapOnion s rport lport = do
  reply <- sendCommand s (BS8.concat ["ADD_ONION NEW:BEST Port=", BS8.pack (show rport), ",127.0.0.1:", BS8.pack(show lport), "\n"])

  return . B32.b32String' . fromJust . Ast.tokenValue . head . Ast.lineMessage . fromJust $ Ast.line (BS8.pack "ServiceID") reply
