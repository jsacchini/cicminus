{-# LANGUAGE PackageImports, FlexibleInstances, TypeSynonymInstances,
  GeneralizedNewtypeDeriving, FlexibleContexts, MultiParamTypeClasses,
  DeriveDataTypeable, RankNTypes, StandaloneDeriving
  #-}

module TCM where

import Control.Applicative
import qualified Control.Exception as E

import Data.Typeable

import "mtl" Control.Monad.Error
import "mtl" Control.Monad.Identity
import "mtl" Control.Monad.Reader
import "mtl" Control.Monad.State

import Internal hiding (lift)
import Environment
import MonadUndo

import Text.ParserCombinators.Parsec.Prim
import Text.ParserCombinators.Parsec

-- Type checking

data TypeError 
    = NotConvertible Term Term
    | NotFunction Term
    | NotSort Term
    | InvalidProductRule Term Term
    | IdentifierNotFound Name
    | ConstantError String
    deriving(Typeable,Show)

instance E.Exception TypeError


{-
data TCState' = TCState' { global :: GlobalEnv, 
                           goal :: ETerm,
                           subgoals :: Local
                           }

-}

type TCState = GlobalEnv
type TCEnv = [Type]

newtype TCM a = TCM { unTCM :: UndoT TCState
                               (ReaderT TCEnv IO) a }
    deriving (Monad,
              MonadIO,
              Functor,
              MonadState TCState,
              MonadUndo TCState,
              MonadReader TCEnv)

instance MonadError TypeError TCM where
  throwError = liftIO . E.throwIO
  catchError m h = TCM $ UndoT $ StateT $ \s -> ReaderT $ \e ->
    runReaderT (runUndoT (unTCM m) (current s)) e
    `E.catch` \err -> runReaderT (runUndoT (unTCM (h err)) (current s)) e

-- mapTCMT :: (forall a. m a -> n a) -> TCM a -> TCMT n a
-- mapTCMT f = TCM . mapUndoT (mapReaderT f) . unTCM

instance MonadGE TCM where
    lookupGE x = do g <- get
                    case lookupEnv x g of
                      Just t -> return t
                      Nothing -> typeError $ IdentifierNotFound x

class ( MonadIO tcm
      , MonadReader TCEnv tcm
      , MonadError TypeError tcm
--      , MonadState TCState tcm
      , MonadGE tcm
      ) => MonadTCM tcm where
--    liftTCM :: TCM a -> tcm a

instance MonadTCM TCM where
--    liftTCM = id -- mapTCMT liftIO

-- instance (Error err, MonadTCM tcm) => MonadTCM (ErrorT err tcm) where
--     liftTCM = lift . liftTCM

-- instance MonadTrans TCM where
--     lift = TCM . lift . lift

-- We want a special monad implementation of fail.
-- instance Monad TCM where
--     return  = TCM . return
--     m >>= k = TCM $ unTCM m >>= unTCM . k
--     fail    = throwError . InternalError

-- instance MonadIO TCM where
--   liftIO m = TCM $ liftIO $ m `E.catch` catchP `E.catch` catchIO
--              where catchP :: ParseError -> IO a
--                    catchP = E.throwIO . ParsingError
--                    catchIO :: E.IOException -> IO a
--                    catchIO = E.throwIO . IOException

-- | Running the type checking monad
-- runTCM :: TCM a -> IO (Either TCErr a)
-- runTCM m = (Right <$> runTCM' m) `E.catch` (return . Left)

-- runTCM' :: TCM a -> IO a
-- runTCM' = flip runReaderT initialTCEnv .
--           flip evalUndoT initialTCState .
--           unTCM

-- runTCM2 :: TCEnv -> TCState -> TCM a -> IO (a, History TCState)
-- runTCM2 g s = flip runReaderT g .
--               flip runUndoT s .
--               unTCM

initialTCState :: TCState
initialTCState = emptyEnv

initialTCEnv :: TCEnv
initialTCEnv = []

-- typeError :: (MonadTCM tcm) => TypeError -> tcm a
-- typeError = liftTCM . throwError . TypeError

typeError :: (MonadTCM tcm) => TypeError -> tcm a
typeError = throwError

-- internalError :: (MonadTCM tcm) => String -> tcm a
-- internalError = liftTCM . throwError . InternalError

-- addGlobal :: (MonadTCM tcm) => Name -> Type -> Term -> tcm ()
-- addGlobal x t u = do g <- get
--                      when (bindedEnv x g) (liftTCM $ throwError $ AlreadyDefined x)
--                      put (extendEnv x (Def t u) g)

-- addAxiom :: (MonadTCM tcm) => Name -> Type -> tcm ()
-- addAxiom x t = do g <- get
--                   when (bindedEnv x g) (liftTCM $ throwError $ AlreadyDefined x)
--                   put (extendEnv x (Axiom t) g)

-- lookupGlobal :: (MonadTCM tcm) => Name -> tcm Global
-- lookupGlobal x = do g <- get
--                     case lookupEnv x g of
--                       Just t -> return t
--                       Nothing -> typeError $ IdentifierNotFound x



