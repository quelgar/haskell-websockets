{- | How do you use this library? Here's how:

 * Get a 'Handle' to your connected client.

 * Perform the initial handshake with 'shakeHands' (or 'getRequest' and 'putResponse').

 * Send and receive strict bytestrings with 'putFrame' and 'getFrame'.

And here's a short example of a server that accepts clients, greets
them with a welcome message, checks for disconnects and replies to all
messages by echoing them back with an appended meow:

> import Network.WebSockets (shakeHands, getFrame, putFrame)
> import Network (listenOn, PortID(PortNumber), accept, withSocketsDo)
> import System.IO (Handle, hClose)
> import qualified Data.ByteString as B (append, null)
> import Data.ByteString.UTF8 (fromString) -- this is from utf8-string
> import Control.Monad (forever)
> import Control.Concurrent (forkIO)
>
> -- Accepts clients, spawns a single handler for each one.
> main :: IO ()
> main = withSocketsDo $ do
>   socket <- listenOn (PortNumber 8088)
>   putStrLn "Listening on port 8088."
>   forever $ do
>     (h, _, _) <- accept socket
>     forkIO (talkTo h)
>
> -- Shakes hands with client. If no error, starts talking.
> talkTo :: Handle -> IO ()
> talkTo h = do
>   request <- shakeHands h
>   case request of
>     Left err -> print err
>     Right  _ -> do
>       putFrame h (fromString "Do you read me, Lieutenant Bowie?")
>       putStrLn "Shook hands, sent welcome message."
>       talkLoop h
>
> -- Talks to the client (by echoing messages back) until EOF.
> talkLoop :: Handle -> IO ()
> talkLoop h = do
>   msg <- getFrame h
>   if B.null msg
>      then do
>        putStrLn "EOF encountered. Closing handle."
>        hClose h
>      else do
>        putFrame h $ B.append msg (fromString ", meow.")
>        talkLoop h

The example above will suffice if you wish to accept any
WebSocket-capable client, regardless of its origin or target. It won't
suffice if you have to filter the incoming clients by the contents of
their requests. For that, you can use 'getRequest' and 'putResponse',
which allow you to inspect the request details /before/ you send back
a response, if any.

If you have any suggestions, bug reports and\/or fixes, feel free to
send them to <mailto:sinisa@bidin.cc>. Thanks! -}
module Network.WebSockets (
shakeHands, getRequest, putResponse, createResponse, getFrame,
putFrame, createToken, Request(..), HandshakeError(..)) where

import System.IO (Handle, hFlush)
import Data.Binary (encode)
import Data.Int (Int32)

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Digest.Pure.MD5 (md5)
import Data.Char (isDigit, chr, ord)
import Data.List (isPrefixOf, isSuffixOf)
import qualified Control.Exception as E
import qualified Data.Map as M
import Control.Applicative
import Network.HTTP.Headers (Header, mkHeader, headerMap)


-- | Contains the request details.
data Request = Request {
  reqHost :: String, -- ^ The requested host.
  reqPath :: String, -- ^ The requested path.
  reqOrigin :: String, -- ^ The origin of the request.
  reqKey1 :: String, -- ^ The first security key.
  reqKey2 :: String, -- ^ The second security key.
  reqToken :: String -- ^ The given eight-byte token.
} deriving (Show)


-- Contains the client's request. The eight-byte token is under key
-- \"Token\", while the requested path is under key \"Path\". Others
-- are the same as in the request header: \"Origin\", \"Upgrade\" and
-- \"Sec-WebSocket-Key2\", to name a few.
type RawRequest = M.Map String String


-- | Error in case of failed handshake.
data HandshakeError = HsIOError String
                    | HsInvalidGETRequest String
                    | HsInvalidHeaderLine String
                    | HsMissingHeaderKeys String
                    | HsBadFirstSecurityKey String
                    | HsBadSecondSecurityKey String
                      deriving (Show)


-- | Accept and perform a handshake, no matter the request contents.
--
-- As long as the request is well-formed, the client will receive a
-- response saying, essentially, \"proceed\". Use this function if you
-- don't care who you're connected to, as long as that someone speaks
-- the WebSocket protocol.
--
-- The function returns either a 'HandshakeError' in case of error, or
-- a 'Request' on success. The 'Request' is returned purely for
-- logging purposes, since the handshake has already been
-- executed. Use this function immediately after establishing the
-- connection.
--
-- If you wish not to blindly accept requests but to filter them
-- according to their contents, use the 'getRequest' and 'putResponse'
-- functions.
shakeHands :: Handle -> IO (Either HandshakeError Request)
shakeHands h = do
  request <- getRequest h
  case request of
    Right r -> putResponse h r >> return request
    Left  _ -> return request -- Returns the error.

exists :: (a -> Boolean) -> Maybe a -> Boolean
exists = maybe False

data HandshakeResult = PlainHTTP { 
    reqPath :: String,
    reqHeaders :: [Header]
    } |
  BadHandshake HandshakeError |
  GoodHandshake Request

getRequestOrHTTP :: Handle -> IO HandshakeResult
getRequestOrHTTP h = toString <$> B.hGetLine h >>= firstLine where
  firstLine first
    | "GET " `isPrefixOf` first && " HTTP/1.1\r" `isSuffixOf` first = headers (words first !! 1) M.empty
    | otherwise = return.BadHandshake $ HsInvalidGETRequest first
  headers path req = toString <$> B.hGetLine h >>= aLine path req
  aLine _    _   []   = return . BadHandshake $ HsInvalidHeaderLine []
  aLine path req line = aHeader path req $ break (==':') (init line)
  aHeader path req ("", "")
    | isWebSocket req = validate path req . B.unpack <$> B.hGet h 8
    | otherwise = return $ PlainHTTP path (toHeader <$> M.toList req)
  aHeader path req (k, v) = headers path $ M.insert k (fixValue v) req
  fixValue (':':' ':xs) = xs
  fixValue = tail
  validate path req token = either BadHandshake GoodHandshake $ validateRequest $ M.union req (M.fromList
    [("Path", path), ("Token", token)])
  isWebSocket req = exists (=="WebSocket") (M.lookup "Upgrade" req) &&
    exists (=="Upgrade") (M.lookup "Connection" req)
  toHeader (k, v) = mkHeader (fromMaybe $ HdrCustom k $ lookup k headerMap) v

-- | Reads the client's opening handshake and returns either a
-- 'Request' based on its contents, or a 'HandshakeError' in case of
-- an error.
getRequest :: Handle -> IO (Either HandshakeError Request)
getRequest h = do
  -- The first line should be "GET :path: HTTP/1.1".
  first <- toString `fmap` B.hGetLine h
  if "GET " `isPrefixOf` first && " HTTP/1.1\r" `isSuffixOf` first
    -- Start stepping through following headers, collecting them.
    then (step.M.singleton "Path" $ words first !! 1)
         `E.catch`
         (\e -> return . Left . HsIOError $ show (e::E.SomeException))
    else return.Left $ HsInvalidGETRequest first

  where
    -- Collect header keys and values.
    -- Stops in case of error or upon reading the final 8-byte token.
    step :: RawRequest -> IO (Either HandshakeError Request)
    step req = do
      line <- toString `fmap` B.hGetLine h
      if null line
        then return.Left $ HsInvalidHeaderLine line

        -- Else, split line in half. We get the header key (++':') and value.
        else case break (==' ') (init line) of
          ("", "") -> do
            -- The line is empty, so the next 8 bytes are the token.
            bytes <- (map (chr.fromIntegral) . BL.unpack) `fmap` BL.hGet h 8
            -- We have the whole request. Validate it and return result.
            return.validateRequest $ M.insert "Token" bytes req

          (key, val) ->
            step $ M.insert (init key) (tail val) req


-- Checks if a given raw request is valid or not. A valid request
-- won't cause a division by zero when calculating a response token
-- and contains all the neccessary data to create a response. Returns
-- either a 'HandshakeError' if the request is not valid, or a valid
-- 'Request'.
validateRequest :: RawRequest -> Either HandshakeError Request
validateRequest req
  | lacksHeaderKeys = Left $ HsMissingHeaderKeys (show req)
  | faultyKey 1 = Left $ HsBadFirstSecurityKey (show req)
  | faultyKey 2 = Left $ HsBadSecondSecurityKey (show req)
  | otherwise = Right $ fromRaw req

  where
    -- Is there a header key (and value) that we don't have, but need?
    lacksHeaderKeys = any (`M.notMember` req)
                          ["Host", "Path", "Origin", "Token",
                           "Sec-WebSocket-Key1", "Sec-WebSocket-Key2"]

    -- Are there no spaces in a security key value? We can't divide by 0.
    -- If there are no spaces, return False.
    faultyKey :: Int -> Bool
    faultyKey n =
      let key = req M.! ("Sec-WebSocket-Key" ++ show n)
      in  null $ filter (==' ') key

    -- Converts a RawRequest to a final Request.
    fromRaw :: RawRequest -> Request
    fromRaw r = Request { reqHost   = r M.! "Host"
                        , reqPath   = r M.! "Path"
                        , reqOrigin = r M.! "Origin"
                        , reqKey1   = r M.! "Sec-WebSocket-Key1"
                        , reqKey2   = r M.! "Sec-WebSocket-Key2"
                        , reqToken  = r M.! "Token" }


-- | Sends an accepting response based on the given 'Request', thus
-- accepting and ending the handshake.
putResponse :: Handle -> Request -> IO ()
putResponse h req = B.hPutStr h (createResponse req)


-- | Returns an accepting response based on the given
-- 'Request'. 'putResponse' uses this function internally.
createResponse :: Request -> B.ByteString
createResponse req = B.append (fromString header) (createToken req)
  where header =
          "HTTP/1.1 101 WebSocket Protocol Handshake\r\n\
           \Upgrade: WebSocket\r\n\
           \Connection: Upgrade\r\n\
           \Sec-WebSocket-Origin: "++ reqOrigin req ++"\r\n\
           \Sec-WebSocket-Location: ws://"++ reqHost req ++ reqPath req ++"\r\n\
           \Sec-WebSocket-Protocol: sample\r\n\r\n"


-- | Constructs the response token by using the two security keys the
-- and eight-byte token given in the request, as defined by the
-- protocol.
createToken :: Request -> B.ByteString
createToken req  = B.pack $ BL.unpack (encode hash)
  where
    hash         = md5 $ BL.concat [num1, num2, token]
    [num1, num2] = map (encode.divBySpaces) [reqKey1 req, reqKey2 req]
    token        = BL.pack $ map (fromIntegral.ord) (reqToken req)


-- Divides the number hiding in the string by the number of spaces in
-- the string, as defined in the protocol. Assumes division by zero
-- will not occur, since the request was verified to be valid
-- beforehand.
divBySpaces :: String -> Int32
divBySpaces str =
  let number = read $ filter isDigit str :: Integer
      spaces = fromIntegral . length $ filter (==' ') str
  in  fromIntegral $ number `div` spaces


-- | Send a strict ByteString. Call this function only after having
-- performed the handshake.
putFrame :: Handle -> B.ByteString -> IO ()
putFrame h bs = do
  let frame = B.cons 0 (B.snoc bs 255)
  B.hPutStr h frame
  hFlush h


-- | Receive a strict ByteString. Call this function only after having
-- performed the handshake. This function will block until an entire
-- frame is read. If the writing end of the handle is closed, the
-- function returns an empty ByteString.
getFrame :: Handle -> IO B.ByteString
getFrame h = do
  first <- B.hGet h 1 -- The first byte should be zero.
  if B.null first -- In case of EOF, return empty ByteString.
     then return B.empty

     -- What if the first byte isn't zero? The frame is invalid.
     -- Ignore this and consider the byte part of the frame contents.
     else if first /= B.singleton 0
             then readUntil255 first -- Byte becomes first in buffer.
             else readUntil255 B.empty -- Start with empty buffer, as should be.

  where
    -- Read bytes from the handle, accumulating them, until 255 is reached.
    readUntil255 buf = do
      b <- B.hGet h 1
      if B.null b
         then return B.empty -- Return empty in case of EOF.
         else if b == B.singleton 255
                 then return buf
                 else readUntil255 (B.append buf b)



-- Quick and dirty String<->B.ByteString conversions.
fromString :: String -> B.ByteString
fromString = B.pack . map (fromIntegral.ord)

toString :: B.ByteString -> String
toString = map (chr.fromIntegral) . B.unpack
