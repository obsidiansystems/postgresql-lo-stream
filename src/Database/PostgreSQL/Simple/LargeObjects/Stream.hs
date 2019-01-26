{-# LANGUAGE LambdaCase #-}
module Database.PostgreSQL.Simple.LargeObjects.Stream where

import Control.Exception.Lifted (AssertionFailed (..), bracket, throwIO)
import Control.Monad.Loops (whileJust_)
import Control.Monad.State as State
import qualified Data.ByteString as BS
import Data.ByteString.Builder (byteString)
import qualified Data.ByteString.Builder as BS
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.Semigroup ((<>))
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.LargeObjects (LoFd, Oid (..))
import qualified Database.PostgreSQL.Simple.LargeObjects as Sql
import System.IO (IOMode (ReadMode, WriteMode))
import System.IO.Streams (makeOutputStream)
import qualified System.IO.Streams as Streams

-- | Given a strict ByteString, create a postgres large object and fill it with those contents.
newLargeObjectBS
  :: Connection
  -> BS.ByteString
  -> IO Oid
newLargeObjectBS conn contents = do
  oid <- Sql.loCreat conn
  n <- withLargeObject conn oid WriteMode $ \lofd -> Sql.loWrite conn lofd contents
  let l = BS.length contents
  when (n /= l) . throwIO . AssertionFailed $
    "newLargeObjectBS: loWrite reported writing " <> show n <> " bytes, expected " <> show l <> "."
  return oid

-- | Given a lazy ByteString, create a postgres large object and fill it with those contents.
-- Also returns the total length of the data written.
newLargeObjectLBS
  :: Connection
  -> LBS.ByteString
  -> IO (Oid, Int)
newLargeObjectLBS conn = newLargeObjectStream conn <=< Streams.fromLazyByteString

-- | Create a new large object from an input stream, returning its object id and overall size.
newLargeObjectStream
  :: Connection
  -> Streams.InputStream BS.ByteString
  -> IO (Oid, Int)
newLargeObjectStream conn s = do
  oid <- Sql.loCreat conn
  t <- withLargeObject conn oid WriteMode $ \lofd -> do
    whileJust_ (Streams.read s) $ \chunk -> do
      n <- Sql.loWrite conn lofd chunk
      let l = BS.length chunk
      when (n /= l) . throwIO . AssertionFailed $
        "newLargeObjectStream: loWrite reported writing " <> show n <> " bytes, expected " <> show l <> "."
    Sql.loTell conn lofd
  return (oid, t)

-- | Act on a large object given by id, opening and closing the file descriptor appropriately.
withLargeObject
  :: Connection
  -> Oid
  -> IOMode
  -> (LoFd -> IO a)
  -> IO a
withLargeObject conn oid mode f =
  bracket (Sql.loOpen conn oid mode)
          (\lofd -> Sql.loClose conn lofd)
          f

-- | Stream the contents of a database large object to the given output stream. Useful with Snap's 'addToOutput'.
streamLargeObject
  :: Connection
  -> Oid
  -> Streams.OutputStream BS.Builder
  -> IO ()
streamLargeObject conn oid os =
  withLargeObject conn oid ReadMode $ \lofd ->
    fix $ \again -> do
      chunk <- Sql.loRead conn lofd 8192 -- somewhat arbitrary
      case BS.length chunk of
        0 -> return ()
        _ -> do
          Streams.write (Just $ byteString chunk) os
          again

-- | Stream the contents of a database large object to the given output stream. Useful with Snap's 'addToOutput'.
streamLargeObjectRange
  :: Connection
  -> Oid
  -> Int
  -> Int
  -> Streams.OutputStream BS.Builder
  -> IO ()
streamLargeObjectRange conn oid start end os =
  withLargeObject conn oid ReadMode $ \lofd -> do
    _ <- Sql.loSeek conn lofd Sql.AbsoluteSeek start
    let again n = do
          let nextChunkSize = min 8192 (end - n)
          chunk <- Sql.loRead conn lofd nextChunkSize
          case BS.length chunk of
            0 -> return ()
            k -> do
              Streams.write (Just $ byteString chunk) os
              again (n + k)
    again start

-- | Act on the contents of a LargeObject as a Lazy ByteString
withLargeObjectLBS :: Connection -> Oid -> (LBS.ByteString -> IO ()) -> IO ()
withLargeObjectLBS conn oid f = do
  lo <- newIORef mempty
  cb <- makeOutputStream $ \case
    Just chunk -> modifyIORef lo $ \chunks -> chunks <> chunk
    Nothing -> do
      payload <- readIORef lo
      f $ BS.toLazyByteString payload
  streamLargeObject conn oid cb
  Streams.write Nothing cb
