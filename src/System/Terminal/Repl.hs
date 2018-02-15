{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
module System.Terminal.Repl
  ( MonadRepl (..)
  , ReplT ()
  , runAnsiRepl
  , runReplT
  ) where

import           Control.Concurrent
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.STM
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.State
import           Data.Char
import           Data.Function              (fix)
import           Data.Typeable
import           System.Environment
import qualified System.Exit                as SE

import qualified System.Terminal            as T
import qualified System.Terminal.Color      as T
import qualified System.Terminal.Events     as T
import qualified System.Terminal.Pretty     as T

class MonadRepl m where
  getInputLine :: T.TermDoc -> m (Maybe String)
  exit         :: m ()
  exitWith     :: SE.ExitCode -> m ()

newtype ReplT m a = ReplT (StateT (Maybe SE.ExitCode) m a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadTrans)

instance (T.MonadPrinter m) => T.MonadPrinter (ReplT m) where
  putLn = lift T.putLn
  putChar = lift . T.putChar
  putString = lift . T.putString
  putStringLn = lift . T.putStringLn
  putText = lift . T.putText
  putTextLn = lift . T.putTextLn
  flush = lift T.flush

instance (T.MonadIsolate m) => T.MonadIsolate (ReplT m) where
  isolate (ReplT sma) = ReplT $ do
    st <- get
    (a,st') <- lift $ T.isolate $ runStateT sma st
    put st'
    pure a

instance (T.MonadColorPrinter m) => T.MonadColorPrinter (ReplT m) where
  setDefault = lift T.setDefault
  setForegroundColor = lift . T.setForegroundColor
  setBackgroundColor = lift . T.setBackgroundColor
  setUnderline = lift . T.setUnderline
  setNegative = lift . T.setNegative

instance (T.MonadScreen m) => T.MonadScreen (ReplT m) where
  clear = lift T.clear
  cursorUp = lift . T.cursorUp
  cursorDown = lift . T.cursorDown
  cursorForward = lift . T.cursorForward
  cursorBackward = lift . T.cursorBackward
  cursorPosition x y = lift $ T.cursorPosition x y
  cursorVisible = lift . T.cursorVisible
  getScreenSize = lift T.getScreenSize

instance (T.MonadEvent m) => T.MonadEvent (ReplT m) where
  withEventSTM = lift . T.withEventSTM

instance (T.MonadTerminal m) => T.MonadTerminal (ReplT m) where

runAnsiRepl :: ReplT (T.AnsiTerminalT IO) () -> IO ()
runAnsiRepl ma = do
  code <- T.runAnsiTerminalT $ runReplT ma
  SE.exitWith code

runReplT :: T.MonadTerminal m => ReplT m () -> m SE.ExitCode
runReplT (ReplT ma) = evalStateT loop Nothing
  where
    loop = ma >> get >>= \case
      Nothing -> loop
      Just code -> pure code

instance T.MonadTerminal m => MonadRepl (ReplT m) where
  exit = ReplT $ put (Just SE.ExitSuccess)
  exitWith = ReplT . put . Just
  getInputLine prompt = do
    lift $ T.putDoc prompt
    lift $ T.setDefault
    lift $ T.flush
    withStacks [] []
    where
      withStacks xss yss = lift (T.withEventSTM id) >>= \case
        T.EvKey (T.KChar 'C') [T.MCtrl] -> do
          lift $ T.putLn
          lift $ T.flush
          getInputLine prompt
        T.EvKey (T.KChar 'D') [T.MCtrl] -> do
          lift $ T.putLn
          lift $ T.flush
          pure Nothing
        T.EvKey T.KEnter [] -> do
          lift $ T.putLn
          lift $ T.flush
          pure (Just $ reverse xss ++ yss)
        T.EvKey (T.KBackspace 1) [] -> case xss of
          []     -> withStacks xss yss
          (x:xs) -> do
            lift $ T.cursorBackward 1
            lift $ T.putString yss
            lift $ T.putChar ' '
            lift $ T.cursorBackward (length yss + 1)
            lift $ T.flush
            withStacks xs yss
        T.EvKey (T.KLeft 1) [] -> case xss of
          []     -> withStacks xss yss
          (x:xs) -> do
            lift $ T.cursorBackward 1
            lift $ T.flush
            withStacks xs (x:yss)
        T.EvKey (T.KRight 1) [] -> case yss of
          []     -> withStacks xss yss
          (y:ys) -> do
            lift $ T.cursorForward 1
            lift $ T.flush
            withStacks (y:xss) ys
        T.EvKey (T.KChar c) []
          | isPrint c || isSpace c -> do
              lift $ T.putChar c
              lift $ T.flush
              withStacks (c:xss) yss
          | otherwise -> do
            withStacks xss yss
        ev -> do
          lift $ T.putStringLn (show ev)
          lift $ T.flush
          withStacks xss yss
