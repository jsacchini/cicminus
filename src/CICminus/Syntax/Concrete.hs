{- cicminus
 - Copyright 2011-2015 by Jorge Luis Sacchini
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

{-# LANGUAGE DeriveFoldable       #-}
{-# LANGUAGE DeriveFunctor        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE PatternGuards        #-}
{-# LANGUAGE TypeSynonymInstances #-}


-- | Concrete syntax returned by the parser.

module CICminus.Syntax.Concrete where

import qualified Data.Foldable            as Fold
import           Data.List
import           Data.Maybe
import           Data.Monoid              hiding ((<>))

import           CICminus.Syntax.Common
import           CICminus.Syntax.Position

import           CICminus.Utils.Pretty


-- | Identifier kinds (for color prettyprinting)
data IdentifierKind
  = UnknownIdent
  | CoInductiveIdent
  | ConstructorIdent
  | GlobalIdent
  | LocalIdent
  deriving(Show, Eq)


-- | The main data type of expressions returned by the parser.
data GExpr a
  = Ann Range (GExpr a) (GExpr a)     -- ^ Annotated term with type, e.g. @ M :: T @
  | Sort Range Sort
  | Pi Range (GContext a) (GExpr a)   -- ^ Dependent product type.
                            --   e.g. @ forall (x1 ... xn : A), B @
  -- | Arrow Range ArgType Expr Expr
  --                           -- ^ Non-dependent function.
  | Ident Range Name IdentifierKind        -- ^ Identifiers
  | SApp Range Name IdentifierKind a
                            -- ^ Size application
                            --   e.g. nat<i>, listnat<i>
  | Lam Range (GContext a) (GExpr a)  -- ^ Abstractions, e.g. @fun (x1 ... xn : A) => B@
  | App Range (GExpr a) ArgType (GExpr a)     -- ^ Applications
  | Case (GCaseExpr a)           -- ^ Case expressions
  | Fix (GFixExpr a)             -- ^ (Co)fixpoints
  | Meta Range (Maybe Int)  -- ^ Unspecified terms
  | Number Range Int        -- ^ built-in numbers
  deriving(Show, Functor, Fold.Foldable)

type Expr = GExpr SizeExpr
type GContext a = (Ctx (GBind a))
type Context = GContext SizeExpr

data SizeExpr
  = SizeExpr Range Name Int   -- i^n
  | SizeStar Range
  deriving(Show)


instance Pretty SizeExpr where
  pretty (SizeExpr _ x n) =
    langle <> (pretty x <>
                  if n > 0
                  then text "+" <> text (show n)
                  else empty) <> rangle
  pretty (SizeStar _) = text "*"


-- | Constrained types
data GConstrExpr a
  = ConstrExpr Range [Name] (GExpr a) -- ^ Constrained type of the form
                                 --   { i j k } -> T
                                 --   where i j k are size variables
  deriving(Show, Functor, Fold.Foldable)

type ConstrExpr = GConstrExpr SizeExpr

mkProp :: Range -> Expr
mkProp r = Sort r Prop


mkType :: Range -> Int -> Expr
mkType r n = Sort r (Type n)


mkApp :: Expr -> [Expr] -> Expr
mkApp = foldl (\x y -> App (fuseRange x y) x explicitArg y)


unApp :: Expr -> (Expr, [(ArgType, Expr)])
unApp (App _ e1 a e2) = (func, args ++ [(a, e2)])
  where
    (func, args) = unApp e1
unApp e = (e, [])


unPi :: Expr -> (Context, Expr)
unPi (Pi _ ctx e) = (ctxCat ctx ctx', e')
  where
    (ctx', e') = unPi e
unPi e = (ctxEmpty, e)


unLam :: Expr -> (Context, Expr)
unLam (Pi _ ctx e) = (ctxCat ctx ctx', e')
  where
    (ctx', e') = unLam e
unLam e = (ctxEmpty, e)


hasStar :: Expr -> Bool
hasStar = getAny . Fold.foldMap isStar
  where
    isStar (SizeStar _) = Any True
    isStar _            = Any False

hasSize :: Expr -> Bool
hasSize = getAny . Fold.foldMap isSize
  where
    isSize (SizeExpr {}) = Any True
    isSize _             = Any False


-- | Binds and context
data GBind a
  = Bind Range [Name] (Arg (GExpr a))
                     -- ^ e.g. @(x y : A)@. Name list must be non-empty.
  | LetBind Range Name (GExpr a) (Arg (Maybe (GExpr a)))
                     -- ^ @x := e2 : e1@
  | BindName Range ArgType Name
  deriving(Show, Functor, Fold.Foldable)

type Bind = GBind SizeExpr

-- type Context = Ctx Bind


instance HasNames Bind where
  name (Bind _ x _)      = name x
  name (LetBind _ x _ _) = name x
  name (BindName _ _ x)  = name x


instance SetRange Bind where
  setRange r (Bind _ x y) = Bind r x y


instance HasImplicit Bind where
  isImplicit (Bind _ _ arg) = isImplicit arg
  isImplicit (LetBind _ _ _ arg) = isImplicit arg
  isImplicit (BindName _ arg _) = isImplicit arg
  modifyImplicit f (Bind r xs arg) = Bind r xs (modifyImplicit f arg)
  modifyImplicit f (LetBind r xs e arg) = LetBind r xs e (modifyImplicit f arg)
  modifyImplicit f (BindName r arg x) = BindName r (modifyImplicit f arg) x


-- | Patterns
data GSinglePattern a
  = PatternVar Range Name
  | PatternDef Range Name (GExpr a)
  deriving(Show, Functor, Fold.Foldable)

type SinglePattern = GSinglePattern SizeExpr

instance HasNames SinglePattern where
  name (PatternVar _ x)   = name x
  name (PatternDef _ x _) = name x

instance HasRange SinglePattern where
  range (PatternVar r _)   = r
  range (PatternDef r _ _) = r

type GPattern a = [GSinglePattern a]
type Pattern = [SinglePattern]



-- | Case expressions
data GCaseExpr a
  = CaseExpr { caseRange    :: Range
             , caseArg      :: GExpr a
               -- ^ Argument of the case
             , caseAsName   :: Name
               -- ^ Bind for the argument in the return type
             , caseIndices  :: Maybe (GIndicesSpec a)
               -- ^ Specification of the subfamily of the
               -- inductive type of the argument
             , caseReturn   :: Maybe (GExpr a)
               -- ^ Return type
             , caseBranches :: [GBranch a]
             }
  deriving(Show, Functor, Fold.Foldable)

type CaseExpr = GCaseExpr SizeExpr

data GIndicesSpec a
  = IndicesSpec { indspecRange :: Range
                , indspecType  :: Name
                  -- ^ The inductive type of the case
                , indspecArgs  :: GPattern a
                  -- ^ The specification of the subfamily
                }
  deriving(Show, Functor, Fold.Foldable)

instance HasRange (GIndicesSpec a) where
  range = indspecRange

type IndicesSpec = GIndicesSpec SizeExpr

type NamedArg a = Named (Arg a)


data GBranch a
  = Branch { brRange     :: Range
           , brConstr    :: Name
           , brArgsNames :: GPattern a
           , brBody      :: GExpr a
           }
  deriving(Show, Functor, Fold.Foldable)

type Branch = GBranch SizeExpr

instance HasNames IndicesSpec where
  name = name . indspecArgs


-- | (Co-)fix expressions
data GFixExpr a
  = FixExpr { fixRange :: Range
            , fixKind  :: InductiveKind
            , fixName  :: Name
            , fixSpec  :: FixSpec
            , fixArgs  :: GContext a
            , fixType  :: GExpr a
            , fixBody  :: GExpr a
            }
  deriving(Show, Functor, Fold.Foldable)

type FixExpr = GFixExpr SizeExpr

data FixSpec
  = FixStruct Range Name  -- Recursive argument
  | FixPosition     -- Position type (types annotated with stars)
  | FixStage Range Name   -- Recursive size variable
  deriving(Show)


-- | Global declarations
data GDeclaration a
  = Definition Range Name (Maybe (GConstrExpr a)) (GExpr a)
  | Cofixpoint (GFixExpr a)
  | Assumption Range Name (GConstrExpr a)
  | Inductive Range (GInductiveDef a)
  | Eval (GExpr a)
  | Check (GExpr a) (Maybe (GExpr a))
  | Print Range Name
  deriving(Show, Functor, Fold.Foldable)

type Declaration = GDeclaration SizeExpr

-- | (Co-)inductive definitions
data GInductiveDef a
  = InductiveDef { indName       :: Name
                 , indKind       :: InductiveKind
                 , indPars       :: GContext a
                 , indPolarities :: [Polarity]
                 , indType       :: GExpr a
                 , indConstr     :: [GConstructor a]
                 }
  deriving(Show, Functor, Fold.Foldable)

type InductiveDef = GInductiveDef SizeExpr

-- | Contructors
data GConstructor a
  = Constructor { constrRange :: Range
                , constrName  :: Name
                , constrType  :: GExpr a
                }
  deriving(Show, Functor, Fold.Foldable)

type Constructor = GConstructor SizeExpr


-- HasRange and SetRange instances
instance HasRange Expr where
  range (Ann r _ _) = r
  range (Sort r _) = r
  range (Pi r _ _) = r
  -- range (Arrow r _ _ _) = r
  range (Ident r _ _) = r
  range (SApp r _ _ _) = r
  range (Lam r _ _) = r
  range (App r _ _ _) = r
  range (Case c) = range c
  range (Fix f) = range f
  range (Meta r _) = r
  range (Number r _) = r

instance HasRange SizeExpr where
  range (SizeExpr r _ _) = r
  range (SizeStar r) = r

instance HasRange ConstrExpr where
  range (ConstrExpr r _ _) = r


instance HasRange Bind where
  range (Bind r _ _) = r
  range (LetBind r _ _ _) = r
  range (BindName r _ _) = r

instance HasRange CaseExpr where
  range = caseRange


instance HasRange FixExpr where
  range = fixRange


instance SetRange Expr where
  setRange r (Ann _ x y) = Ann r x y
  setRange r (Sort _ x) = Sort r x
  setRange r (Pi _ x y) = Pi r x y
  -- setRange r (Arrow _ x t y) = Arrow r x t y
  setRange r (Ident _ x k) = Ident r x k
  setRange r (Meta _ x) = Meta r x
  setRange r (Lam _ x y) = Lam r x y
  setRange r (App _ x t y) = App r x t y
  setRange r (Case c) = Case $ setRange r c
  setRange r (Fix f) = Fix $ setRange r f


instance SetRange ConstrExpr where
  setRange r (ConstrExpr _ x y) = ConstrExpr r x y


instance SetRange CaseExpr where
  setRange r c = c { caseRange = r }


instance SetRange FixExpr where
  setRange r f = f { fixRange = r }


instance HasRange Constructor where
  range (Constructor r _ _) = r


instance HasRange Branch where
  range = brRange


-- | Instances of Show and Pretty. For bound variables, the pretty printer uses
--   the name directly.
--
--   Printing a parsed expression should give back the same result modulo
--   comments, whitespaces, precedence and parenthesis.
--
--   However, there is no effort in removing unused variable names (e.g.,
--   changing @ forall x:A, B @ for @ A -> B @ if @ x @ is not free in @ B @.
--   This is done in the conversion from the Internal syntax.

-- TODO:
--  * check precedences
--  * use proper aligment of constructors and branches


-- | Colors

prettyKeyword :: String -> Doc
prettyKeyword = white . text


prettyIdent :: IdentifierKind -> Name -> Doc
prettyIdent kind = color kind . pretty
  where
    color UnknownIdent     = plain
    color CoInductiveIdent = green
    color ConstructorIdent = magenta
    color GlobalIdent      = cyan
    color LocalIdent       = plain


colorize :: (Doc -> Doc) -> Doc -> Doc
colorize c = c

sortColor :: Doc -> Doc
sortColor = yellow

prettySize :: SizeExpr -> Doc
prettySize = red . pretty


prettySizeVar :: Name -> Doc
prettySizeVar = red . pretty


-- Pretty printing Pi context
data PiGroup
  = PiForall [([Name], Expr)]
  | PiArrow Expr
  deriving(Show)

groupBinds :: [Bind] -> [PiGroup]
groupBinds [] = []
groupBinds (Bind _ [] _:bs) = groupBinds bs
groupBinds (Bind r (x:xs) e1:bs) =
  case groupBinds (Bind r xs e1:bs) of
    gs@(PiForall ((ys, e2) : g) : gs1)
      | not (isNull x) && show e1 == show e2 ->
        PiForall ((x:ys, e2):g) : gs1
      | isNull x -> PiArrow (unArg e1) : gs
      | otherwise -> PiForall [([x], unArg e1)] : gs
    gs
      | isNull x -> PiArrow (unArg e1) : gs
      | otherwise -> PiForall [([x], unArg e1)] : gs
-- groupBinds [] = []
-- groupBinds (Bind _ [] _:bs) = groupBinds bs
-- groupBinds (Bind r (x:xs) e1:bs) = PiArrow (unArg e1) : groupBinds (Bind r xs e1:bs)


prettyPi :: [PiGroup] -> Expr -> Doc
prettyPi [] e = pretty e
prettyPi (PiArrow e1 : gs) e2 = prettyDec 1 e1 <+> arrow <+> prettyPi gs e2
prettyPi (PiForall bs : gs) e2
  | [b] <- bs = text "Π" <+> prettyGroup b
                <> dot <+> prettyPi gs e2
  | otherwise = text "Π" <+> hsep (map (parens . prettyGroup) bs)
                <> dot <+> prettyPi gs e2
  where
    prettyGroup (xs, e) = hsep (map pretty xs) <> colon <+> pretty e


prettyCtx :: Context -> Doc
prettyCtx CtxEmpty = empty
prettyCtx (Bind _ xs e :> ctx) =
  parens (hsep (map pretty xs) <> colon <+> pretty (unArg e))
  <+> pretty ctx



instance Pretty Expr where
  prettyDec = pp
    where
      pp :: Int -> Expr -> Doc
      pp n (Ann _ e1 e2) = parensIf (n > 1) $ hsep [pp 2 e1, doubleColon,
                                                    pp 0 e2]
      pp _ (Sort _ s) = colorize sortColor $ pretty s
      pp n e@(Pi _ _ _) =
        parensIf (n > 0) -- $ nestedPi 1 (joinPiBind (explodeCtx ctx)) e'
        $ prettyPi (groupBinds (bindings ctx)) e'
        where
          (ctx, e') = unPi e
      -- pp n (Arrow _ _ e1 e2) = parensIf (n > 0) $ sep [ pp 0 e1
      --                                                 , text "->"
      --                                                 , pp 0 e2 ]
      pp _ (Ident _ x k) = prettyIdent k x
      pp _ (Meta _ Nothing) = text "_"
      pp _ (Meta _ (Just k)) = text "?" <> int k
      pp n (Lam _ bs e) = parensIf (n > 0) $
                          sep [ prettyKeyword "λ" <+> pretty (joinLamBind bs) <+> implies
                               , prettyDec n e ]
      pp n (App _ e1 _ e2) = parensIf (n > 2) $ hsep [pp 2 e1, pp 3 e2]
      pp n (Case c) = parensIf (n > 0) $ pretty c
      pp n (Fix f) = parensIf (n > 0) $ ppKind (fixKind f) <+> pretty f
        where
          ppKind I   = prettyKeyword "fix"
          ppKind CoI = prettyKeyword "cofix"

      pp _ (Number _ n) = text $ show n
      pp _ (SApp _ x k s) = prettyIdent k x <> prettySize s

  -- = Bind Range [Name] (Arg (GExpr a))
  --                    -- ^ e.g. @(x y : A)@. Name list must be non-empty.
  -- | LetBind Range Name (GExpr a) (Arg (Maybe (GExpr a)))
  --                    -- ^ @x := e2 : e1@
  -- | BindName Range ArgType Name



      -- groupBinds :: [Bind] -> [[Bind]]
      -- groupBinds = groupBy nameEq
      --   where
      --     nameEq (Bind _ xs e1) (Bind _ ys e2) =
      --       all (not . isNull) (xs ++ ys) && show e1 == show e2
      -- squashBinds :: [Bind] -> Bind
      -- squashBinds = foldr1 (\(Bind _ xs _) (Bind rg ys e) -> Bind rg (xs++ys) e)

      -- prettyPi :: [Bind] -> Expr -> Doc
      -- prettyPi [] e = pretty e
      -- prettyPi (Bind _ [x] e1:bs) e2 | isNull x = prettyPi e1 <+> arrow <+> prettyPi e2
      -- prettyPi (b:bs) e2

      nestedPi :: Int -> [Bind] -> Expr -> Doc
      nestedPi _ [] e = pretty e
      nestedPi n (b@(Bind _ xs e1) : ctx) e2
        | [x] <- xs, isNull x =
          prettyDec n (unArg e1) <+> arrow <+> nestedPi n ctx e2
        | otherwise = hsep [prettyKeyword "Π" <+> pretty b <> dot
                          , nestedPi n ctx e2 ]
        where
          -- TODO: remove unnecessary parenthesis and Π

      explodeCtx :: Context -> [Bind]
      explodeCtx CtxEmpty = []
      explodeCtx (Bind _ [] _ :> ctx) = explodeCtx ctx
      explodeCtx (Bind r (x:xs) e :> ctx) =
        Bind r [x] e : explodeCtx (Bind r xs e :> ctx)

      joinPiBind :: [Bind] -> [Bind]
      joinPiBind [] = []
      joinPiBind [b] = [b]
      joinPiBind (b@(Bind _ xs e1) : ctx0@(Bind _ ys e2 : ctx))
        | show e1 == show e2
          && all (not . isNull) xs
          && all (not . isNull) ys = joinPiBind (Bind noRange (xs++ys) e1 : ctx)
        | otherwise = b : joinPiBind ctx0


      joinLamBind :: Context -> Context
      joinLamBind CtxEmpty = CtxEmpty
      joinLamBind ctx@(Bind _ _ _ :> CtxEmpty) = ctx
      joinLamBind (Bind r1 xs e1 :> Bind r2 ys e2 :> ctx)
        | show e1 == show e2 = joinLamBind (Bind r1 (xs++ys) e1 :> ctx)
        | otherwise = Bind r1 xs e1 :> joinLamBind (Bind r2 ys e2 :> ctx)




instance Pretty Bind where
  pretty (Bind _ xs t) =  parens (hsep [ hsep (map pretty xs)
                                            , colon, pretty (unArg t)])
  pretty (LetBind _ x e t) =
    parens (hsep [ pretty x, defEq, pretty e ]
            <+> if isNothing (unArg t)
                then empty
                else colon <+> pretty (fromJust (unArg t)))
  pretty (BindName _ _ x) = pretty x


instance Pretty CaseExpr where
  pretty (CaseExpr _ arg x indices ret brs) =
    sep [ maybePPrint ppRet ret
        , vsep [ sep [ hsep [ prettyKeyword "case"<> ppAs x
                            , pretty arg <> maybePPrint ppIn indices
                            , prettyKeyword "of" ]
                     ]
               , sep (map (nest 1 . (bar <+>) . pretty) brs)
               ]
        ]
      where
        ppRet r   = hcat [langle, pretty r, rangle]
        ppAs a | isNull a  = empty
               | otherwise = empty <+> pretty a <+> defEq
        ppIn i | all isNull (name i) = empty
               | otherwise = hsep [empty, prettyKeyword "in", pretty i]
        maybePPrint :: (Pretty a) => (a -> Doc) -> Maybe a -> Doc
        maybePPrint = maybe empty


instance Pretty IndicesSpec where
  pretty (IndicesSpec _ i patt) = pretty i
                                       <+> pretty (Pat patt)

newtype Pat = Pat Pattern
instance Pretty Pat where
  pretty (Pat pats) = hsep $ map pretty pats


instance Pretty SinglePattern where
  pretty (PatternVar _ x) = pretty x
  pretty (PatternDef _ x e)
        | isNull x = parens (pretty e) -- TODO: add precedence to e
        | otherwise = parens (pretty x <+> defEq <+> pretty e)


instance Pretty Branch where
  pretty (Branch _ constr patt body) =
    hsep [ pretty constr, pretty (Pat patt)
         , implies
         , pretty body ]


instance Pretty FixExpr where
  pretty (FixExpr _ _ f spec args tp body) =
    hsep [pretty f <> prettyStage spec,
          prettyCtx args <> prettySpec spec, colon, pretty tp, defEq]
    $$ (pretty body)
    where
      prettySpec (FixStruct _ x) = empty <+> braces (prettyKeyword "rec" <+> pretty x)
      prettySpec _ = empty
      prettyStage (FixStage _ x) = empty <+> red (text "<" <> pretty x <> text ">")
      prettyStage _ = empty


instance Pretty ConstrExpr where
  pretty (ConstrExpr _ xs e) = ppConstraint <+> pretty e
    where
      ppConstraint | null xs = empty
                   | otherwise = braces (hsep (map prettySizeVar xs)) <+> implies


instance Pretty Declaration where
  pretty (Definition _ x (Just e1) e2) =
    sep [ sep [ hsep [prettyKeyword "define", pretty x]
              , nest 2 $ hsep [colon, pretty e1] ]
        , nest 2 $ hsep [ defEq, pretty e2]
        ]
  pretty (Definition _ x Nothing e2) =
    hsep [prettyKeyword "define", pretty x, defEq] </> nest 2 (pretty e2)
  pretty (Assumption _ x e) =
    hsep [prettyKeyword "assume", pretty x, colon, pretty e]
  pretty (Inductive _ indDef) = pretty indDef
  pretty (Eval e) =
    hsep [prettyKeyword "eval", pretty e]
  pretty (Check e1 e2) =
    hsep [prettyKeyword "check", pretty e1, ppMaybe e2]
    where
      ppMaybe (Just e) = colon <+> pretty e
      ppMaybe Nothing  = empty
  pretty (Cofixpoint f) = prettyKeyword kind <+> pretty f
    where
      kind = case fixKind f of
        I -> "fixpoint"
        CoI -> "cofixpoint"
  pretty (Print _ x) = prettyKeyword "print" <+> pretty x


instance Pretty InductiveDef where
  pretty (InductiveDef x kind pars _ e cs) =
    sep $ ind : map (nest 2 . (bar <+>) . pretty) cs
      where ind = hsep [ppKind kind, pretty x,
                        pretty pars, colon,
                        pretty e, defEq]
            ppKind k = prettyKeyword $ case k of
                           I   -> "data"
                           CoI -> "codata"


instance Pretty Constructor where
  pretty c =
    hsep [pretty (constrName c), colon, pretty (constrType c)]


instance Pretty [Declaration] where
  pretty = vcat . map ((<> dot) . pretty)
