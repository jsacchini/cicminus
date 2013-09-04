{- cicminus
 - Copyright 2011 by Jorge Luis Sacchini
 -
 - This file is part of cicminus.
 -
 - cicminus is free software: you can redistribute it and/or modify it under the
 - terms of the GNU General Public License as published by the Free Software
 - Foundation, either version 3 of the License, or (at your option) any later
 - version.

 - cicminus is distributed in the hope that it will be useful, but WITHOUT ANY
 - WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 - FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 - details.
 -
 - You should have received a copy of the GNU General Public License along with
 - cicminus. If not, see <http://www.gnu.org/licenses/>.
 -}

{-# LANGUAGE FlexibleContexts, TypeSynonymInstances, DeriveDataTypeable,
    MultiParamTypeClasses, FlexibleInstances, UndecidableInstances
  #-}

module TypeChecking.TCM where

import Prelude hiding (catch)
import Control.Applicative
import Control.Exception
import Control.Monad

import Data.List
import Data.Maybe
import qualified Data.Foldable as Fold
import Data.Typeable

import Data.Map (Map)
import qualified Data.Map as Map

import qualified Data.Graph.Inductive as GI

import Text.PrettyPrint.HughesPJ

import Control.Monad.State
import Control.Monad.Reader

import qualified Syntax.Internal as I
import Syntax.Common
import Syntax.Position
import Syntax.Size
import Utils.Fresh
import Utils.Pretty
import Utils.Sized

import TypeChecking.Constraints (CSet)
import qualified TypeChecking.Constraints as CS

-- Type checking errors
-- We include scope errors, so we have to catch only one type
data TypeError
    = NotConvertible (Maybe Range) TCEnv I.Term I.Term
    | NotFunction (Maybe Range) TCEnv I.Term
    | NotSort Range TCEnv I.Term
    | NotArity Range I.Term
    | NotConstructor TCEnv I.Term
    | InvalidProductRule (Maybe Range) I.Sort I.Sort
    | IdentifierNotFound (Maybe Range) Name
    | ConstantError String
    | CannotInferMeta Range
    -- Scope checking
    | WrongNumberOfArguments Range Name Int Int
    | WrongFixNumber Range Name Int
    | UndefinedName Range Name
    | NotInductive Name
    | ConstructorNotApplied Range Name
    | InductiveNotApplied Range Name
    | PatternNotConstructor Name
    | FixRecursiveArgumentNotPositive Range
    | AlreadyDefined Name
    -- Unification
    | NotUnifiable Int
    | NotImpossibleBranch Range
    deriving(Typeable)

instance Show TypeError where
    show (NotConvertible r e t1 t2) = "NotConvertible " ++ show r
    show (NotFunction r e t1) = "NotFunction " ++ show r
    show (NotSort r e t1) = "NotSort " ++ show r
    show (NotArity r t) = "NotArity " ++ show r
    show (InvalidProductRule r s1 s2) = "InvalidProductRule " ++ show r
    show (IdentifierNotFound r x) = "IdentifierNotFound " ++ show x ++ " " ++ show r
    show (ConstantError s) = "ConstantError " ++ s
    show (CannotInferMeta r) = "CannotInferMeta " ++ show r
    show (WrongNumberOfArguments r _ _ _) = "WrongNumberOfArguments " ++ show r
    show (WrongFixNumber r _ _) = "WrongFixNumber " ++ show r
    show (UndefinedName r _) = "UndefinedName " ++ show r
    show (NotInductive n) = "NotInductive " ++ show n
    show (ConstructorNotApplied r n) = "ConstructorNotApplied " ++ show r ++ " " ++ show n
    show (InductiveNotApplied r n) = "InductiveNotApplied " ++ show r ++ " " ++ show n
    show (PatternNotConstructor n) = "PatternNotConstructor " ++ show n
    show (FixRecursiveArgumentNotPositive r) = "FixRecursiveArgumentNotPositive " ++ show r
    show (AlreadyDefined n) = "AlreadyDefined " ++ show n
    show (NotUnifiable n) = "NotUnifiable " ++ show n
    show (NotImpossibleBranch r) = "NotImpossibleBranch " ++ show r


instance Exception TypeError

type Verbosity = Int
-- Global state containing definition, assumption, datatypes, etc..
data TCState =
  TCState { stSignature       :: Signature
          , stDefined         :: [Name] -- defined names in reverse order
          , stFresh           :: Fresh
          , stGoals           :: Map I.MetaVar I.Goal
          , stActiveGoal      :: Maybe I.MetaVar
          , stConstraints     :: CSet StageVar
          , stVerbosityLevel  :: Verbosity
          }

type Signature = Map Name I.Global

-- Fresh
data Fresh =
  Fresh { freshStage :: StageVar
        , freshMeta  :: I.MetaVar
        } deriving(Show)

instance HasFresh StageVar Fresh where
  nextFresh f = (i, f { freshStage = succ i })
    where i = freshStage f

instance HasFresh I.MetaVar Fresh where
  nextFresh f = (i, f { freshMeta = succ i })
    where i = freshMeta f

-- instance HasFresh i Fresh => HasFresh i TCState where
--   nextFresh s = (i, s { stFresh = f })
--     where (i, f) = nextFresh $ stFresh s

instance HasFresh StageVar TCState where
  nextFresh s = (i, s { stFresh = f
                      , stConstraints = CS.addNode i (stConstraints s) })
    where (i, f) = nextFresh $ stFresh s

instance HasFresh I.MetaVar TCState where
  nextFresh s = (i, s { stFresh = f })
    where (i, f) = nextFresh $ stFresh s

-- Local environment
type TCEnv = Env I.Bind

localLength :: (MonadTCM tcm) => tcm Int
localLength = liftM envLen ask

localGet :: (MonadTCM tcm) => Int -> tcm I.Bind
localGet k = liftM (`envGet` k) ask

data TCErr = TCErr TypeError
             deriving(Show,Typeable)

instance Exception TCErr

class (Functor tcm,
       Applicative tcm,
       MonadReader TCEnv tcm,
       MonadState TCState tcm,
       MonadIO tcm) => MonadTCM tcm

type TCM = ReaderT TCEnv (StateT TCState IO) -- StateT TCState (ReaderT TCEnv IO)

instance MonadTCM TCM

-- | Running the type checking monad
runTCM :: TCM a -> IO (Either TCErr a)
runTCM m = (Right <$> runTCM' m) `catch` (return . Left)

-- runTCM' :: TCM a -> IO a
-- runTCM' m = liftM fst $ runReaderT (runStateT m initialTCState) initialTCEnv
runTCM' m = liftM fst $ runStateT (runReaderT m initialTCEnv) initialTCState


initialTCState :: TCState
initialTCState =
  TCState { stSignature = Map.empty -- initialSignature,
          , stDefined = []
          , stFresh = initialFresh
          , stGoals = Map.empty
          , stActiveGoal = Nothing
          , stConstraints     = CS.addNode inftyStageVar CS.empty
          , stVerbosityLevel = 30
          }

-- | 'initialSignature' contains the definition of natural numbers as an
--   inductive type
initialSignature :: Signature
initialSignature = foldr (uncurry Map.insert) Map.empty
                   [(mkName "nat", natInd),
                    (mkName "O", natO),
                    (mkName "S", natS)]

initialFresh :: Fresh
initialFresh = Fresh { freshStage = succ inftyStageVar -- inftyStageVar is mapped to ∞
                     , freshMeta  = toEnum 0 }

initialTCEnv :: TCEnv
initialTCEnv = EnvEmpty

typeError :: (MonadTCM tcm) => TypeError -> tcm a
typeError = throw

throwNotFunction :: (MonadTCM tcm) => I.Term -> tcm a
throwNotFunction t = do e <- ask
                        typeError $ NotFunction Nothing e t

getSignature :: (MonadTCM tcm) => tcm [Named I.Global]
getSignature = (reverse . stDefined <$> get) >>= mapM mkGlobal
  where
    mkGlobal x = liftM (mkNamed x) (getGlobal x)

lookupGlobal :: (MonadTCM tcm) => Name -> tcm (Maybe I.Global)
lookupGlobal x = do sig <- stSignature <$> get
                    return $ Map.lookup x sig

isGlobal :: (MonadTCM tcm) => Name -> tcm Bool
isGlobal x = Map.member x . stSignature <$> get


getGlobal :: (MonadTCM tcm) => Name -> tcm I.Global
getGlobal x = (Map.! x) . stSignature <$> get


-- | addGlobal adds a global definition to the signature.
--   Checking that names are not repeated is handled by the scope checker
addGlobal :: (MonadTCM tcm) => Named I.Global -> tcm ()
addGlobal g = do st <- get
                 put $ st { stSignature = Map.insert x d (stSignature st)
                          , stDefined = x : stDefined st
                          }
  where
    x = nameTag g
    d = namedValue g

withCtx :: (MonadTCM tcm) => I.Context -> tcm a -> tcm a
withCtx ctx = local (const (ctxToEnv ctx))

withEnv :: (MonadTCM tcm) => TCEnv -> tcm a -> tcm a
withEnv = local . const

freshenName :: (MonadTCM tcm) => Name -> tcm Name
freshenName x | isNull x  = return noName
              | otherwise = do xs <- getLocalNames
                               return $ doFreshName xs x
              where
                doFreshName xs y | y `notElem` xs = y
                                 | otherwise = trySuffix xs y (0 :: Int)
                trySuffix xs y n | addSuffix y n `notElem` xs = addSuffix y n
                                 | otherwise = trySuffix xs y (n+1)
                addSuffix y n = modifyName (++ show n) y

freshenCtx :: (MonadTCM tcm) => I.Context -> tcm I.Context
freshenCtx CtxEmpty = return CtxEmpty
freshenCtx (b :> bs) =
  do
    y <- freshenName (I.bindName b)
    let b' = b { I.bindName = y }
    bs' <- pushBind b' (freshenCtx bs)
    return $ b' :> bs'

pushType :: (MonadTCM tcm) => I.Type -> tcm a -> tcm a
pushType tp m = do x <- freshenName (mkName "x")
                   pushBind (I.mkBind x tp) m

pushBind :: (MonadTCM tcm) => I.Bind -> tcm a -> tcm a
pushBind b m = do x <- freshenName (I.bindName b)
                  let b' = b { I.bindName = x }
                  local (:< b') m

-- TODO: it should not be necessary to freshen a context everytime
-- only freshening during scope checking should be enough
pushCtx :: (MonadTCM tcm) => I.Context -> tcm a -> tcm a
pushCtx ctx m = do ctx' <- freshenCtx ctx
                   local (<:> ctx') m


-- | Returns the number of parameters of an inductive type.
--   Assumes that the global declaration exists and that is an inductive type
numParam :: (MonadTCM tcm) => Name -> tcm Int
numParam x = (size . I.indPars) <$> getGlobal x


getLocalNames :: (MonadTCM tcm) => tcm [Name]
getLocalNames = ask >>= return . name

-- -- We don't need the real type of the binds for scope checking, just the names
-- -- Maybe should be moved to another place
-- fakeBinds :: (MonadTCM tcm, HasNames a) => a -> tcm b -> tcm b
-- fakeBinds b = pushCtx (mkFakeCtx b)
--   where
--     mkFakeCtx = ctxFromList . map mkFakeBind . name
--     mkFakeBind x = I.mkBind x (I.Sort I.Prop)

fakeNames :: (MonadTCM tcm) => Name -> tcm a -> tcm a
fakeNames x = pushCtx $ ctxSingle (I.mkBind x (I.Sort I.Prop))

-- Constraints

-- class HasConstraints s a where
--   getCSet    :: s -> CSet a
--   modifyCSet :: (CSet a -> CSet a) -> s -> s

-- instance HasConstraints TCState StageVar where
--   getCSet        = stConstraints
--   modifyCSet f s = s { stConstraints = f (stConstraints s) }

-- instance HasConstraints TCState I.SortVar where
--   getCSet        = stTypeConstraints
--   modifyCSet f s = s { stTypeConstraints = f (stTypeConstraints s) }

-- addConstraints :: (Enum a, MonadState s m, HasConstraints s a) => [CS.Constraint a] -> m ()
-- addConstraints cts = do
--   st <- get
--   put (modifyCSet (CS.addConstraints cts) st)


addStageConstraints :: (MonadTCM tcm) => [CS.Constraint StageVar] -> tcm ()
addStageConstraints cts =
  modify $ \st -> st { stConstraints = CS.addConstraints cts (stConstraints st) }


removeStages :: (MonadTCM tcm) => [StageVar] -> tcm ()
removeStages ans =
  modify $ \st -> st { stConstraints = CS.delNodes ans (stConstraints st) }

allStages :: (MonadTCM tcm) => tcm [StageVar]
allStages = (CS.listNodes . stConstraints) <$> get

allConstraints :: (MonadTCM tcm) => tcm (CSet StageVar)
allConstraints = stConstraints <$> get

newConstraints :: (MonadTCM tcm) => CSet StageVar -> tcm ()
newConstraints c = modify $ \st -> st { stConstraints = c }

resetConstraints :: (MonadTCM tcm) => tcm ()
resetConstraints = newConstraints (CS.addNode inftyStageVar CS.empty)

-- Goals

listGoals :: (MonadTCM tcm) => tcm [(I.MetaVar, I.Goal)]
listGoals = (filter (isNothing . I.goalTerm . snd) . Map.assocs . stGoals) <$> get

addGoal :: (MonadTCM tcm) => I.MetaVar -> I.Goal -> tcm ()
addGoal m g = do st <- get
                 put $ st { stGoals = Map.insert m g (stGoals st) }

setActiveGoal :: (MonadTCM tcm) => Maybe I.MetaVar -> tcm ()
setActiveGoal k = modify $ \st -> st { stActiveGoal = k }

giveTerm :: (MonadTCM tcm) => I.MetaVar -> I.Term -> tcm ()
giveTerm k t =
  modify $ \st -> st { stGoals = Map.adjust (\g -> g { I.goalTerm = Just t }) k (stGoals st) }

getActiveGoal :: (MonadTCM tcm) => tcm (Maybe (I.MetaVar, I.Goal))
getActiveGoal = do k <- stActiveGoal <$> get
                   case k of
                     Nothing -> return Nothing
                     Just k  -> getGoal k >>= \(Just g) -> return (Just (k, g))

getGoal :: (MonadTCM tcm) => I.MetaVar -> tcm (Maybe I.Goal)
getGoal k = (Map.lookup k . stGoals) <$> get

--- For debugging

levelBug, levelDetail :: Verbosity
levelBug    = 1
levelDetail = 80

getVerbosity :: (MonadTCM tcm) => tcm Verbosity
getVerbosity = stVerbosityLevel <$> get

setVerbosity :: (MonadTCM tcm) => Verbosity -> tcm ()
setVerbosity n = do st <- get
                    put $ st { stVerbosityLevel = n }

traceTCM :: (MonadTCM tcm) => Verbosity -> tcm Doc -> tcm ()
traceTCM n t = do k <- getVerbosity
                  d <- t
                  when (n <= k) $ liftIO $ print d

--- For testing
testTCM_ :: TCM a -> IO (Either TCErr a)
testTCM_ m = runTCM m'
  where m' = do addGlobal (mkNamed (mkName "nat") natInd)
                addGlobal (mkNamed (mkName "O")   natO)
                addGlobal (mkNamed (mkName "S")   natS)
                m


-- Initial signature
natInd :: I.Global
natInd =
  I.Inductive { I.indKind    = I
              , I.indPars    = ctxEmpty
              , I.indPol     = []
              , I.indIndices = ctxEmpty
              , I.indSort    = I.Type 0
              , I.indConstr  = [mkName "O", mkName "S"]
              }

natO :: I.Global
natO =
  I.Constructor { I.constrInd     = mkName "nat"
                , I.constrId      = 0
                , I.constrPars    = ctxEmpty
                , I.constrArgs    = ctxEmpty
                , I.constrRec     = []
                , I.constrIndices = []
                }

natS :: I.Global
natS =
  I.Constructor { I.constrInd     = mkName "nat"
                , I.constrId      = 1
                , I.constrPars    = ctxEmpty
                , I.constrArgs    = ctxSingle (I.unNamed (I.Ind Empty (mkName "nat") []))
                , I.constrRec     = [0]
                , I.constrIndices = []
                }
