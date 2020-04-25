{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE ViewPatterns #-}
{-# Language OverloadedStrings #-}
{-# Language PatternGuards #-}
{-# Language PatternSynonyms #-}
{-# Language ScopedTypeVariables #-}

module Unison.Runtime.ANF
  ( optimize
  , fromTerm
  , fromTerm'
  , term
  , minimizeCyclesOrCrash
  , pattern TVar
  , pattern TLit
  , pattern TApp
  , pattern TApv
  , pattern TCom
  , pattern TCon
  , pattern TReq
  , pattern TPrm
  , pattern THnd
  , pattern TLet
  , pattern TName
  , pattern TBind
  , pattern TTm
  , pattern TBinds
  , pattern TBinds'
  , pattern TMatch
  , Mem(..)
  , Lit(..)
  , SuperNormal(..)
  , SuperGroup(..)
  , POp(..)
  , close
  , float
  , lamLift
  , ANormalBF(..)
  , ANormalTF(.., AApv, ACom, ACon, AReq, APrm)
  , ANormal
  , ANormalT
  , ANFM
  , Branched(..)
  , Func(..)
  , superNormalize
  , anfTerm
  , sink
  ) where

import Unison.Prelude

import Control.Monad.Reader (ReaderT(..), MonadReader(..))
import Control.Monad.State (State, runState, MonadState(..), modify, gets)

import Data.Bifunctor (Bifunctor(..))
import Data.Bifoldable (Bifoldable(..))
import Data.List hiding (and,or)
import Prelude hiding (abs,and,or,seq)
import Unison.Term hiding (resolve, fresh, float)
import Unison.Var (Var, typed)
import Data.IntMap (IntMap)
import qualified Data.Map as Map
import qualified Data.IntMap.Strict as IMap
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Unison.ABT as ABT
import qualified Unison.ABT.Normalized as ABTN
import qualified Unison.Term as Term
import qualified Unison.Type as Ty
import qualified Unison.Var as Var
import Unison.Typechecker.Components (minimize')
import Unison.Pattern (PatternP(..))
import Unison.Reference (Reference(..))
-- import Debug.Trace
-- import qualified Unison.TermPrinter as TP
-- import qualified Unison.Util.Pretty as P

newtype ANF v a = ANF_ { term :: Term v a }

-- Replace all lambdas with free variables with closed lambdas.
-- Works by adding a parameter for each free variable. These
-- synthetic parameters are added before the existing lambda params.
-- For example, `(x -> x + y + z)` becomes `(y z x -> x + y + z) y z`.
-- As this replacement has the same type as the original lambda, it
-- can be done as a purely local transformation, without updating any
-- call sites of the lambda.
--
-- The transformation is shallow and doesn't transform the body of
-- lambdas it finds inside of `t`.
lambdaLift :: (Var v, Semigroup a) => (v -> v) -> Term v a -> Term v a
lambdaLift liftVar t = result where
  result = ABT.visitPure go t
  go t@(LamsNamed' vs body) = Just $ let
    fvs = ABT.freeVars t
    fvsLifted = [ (v, liftVar v) | v <- toList fvs ]
    a = ABT.annotation t
    subs = [(v, var a v') | (v,v') <- fvsLifted ]
    in if Set.null fvs then lam' a vs body -- `lambdaLift body` would make transform deep
       else apps' (lam' a (map snd fvsLifted ++ vs) (ABT.substs subs body))
                  (snd <$> subs)
  go _ = Nothing

expand
  :: (Var v, Monoid a)
  => Set v
  -> (v, Term v a)
  -> (v, Term v a)
expand keep (v, bnd) = (v, apps' (var a v) evs)
  where
  a = ABT.annotation bnd
  fvs = ABT.freeVars bnd
  evs = map (var a) . Set.toList $ Set.difference fvs keep

abstract :: (Var v) => Set v -> Term v a -> Term v a
abstract keep bnd = lam' a evs bnd
  where
  a = ABT.annotation bnd
  fvs = ABT.freeVars bnd
  evs = Set.toList $ Set.difference fvs keep

enclose
  :: (Var v, Monoid a)
  => Set v
  -> (Set v -> Term v a -> Term v a)
  -> Term v a
  -> Maybe (Term v a)
enclose keep rec (LetRecNamedTop' top vbs bd)
  = Just $ letRec' top lvbs lbd
  where
  xpnd = expand keep' <$> vbs
  keep' = Set.union keep . Set.fromList . map fst $ vbs
  lvbs = (map.fmap) (rec keep' . abstract keep' . ABT.substs xpnd) vbs
  lbd = rec keep' . ABT.substs xpnd $ bd
-- will be lifted, so keep this variable
enclose keep rec (Let1NamedTop' top v b@(LamsNamed' vs bd) e)
  = Just . let1' top [(v, lamb)] . rec (Set.insert v keep)
  $ ABT.subst v av e
  where
  (_, av) = expand keep (v, b) 
  keep' = Set.difference keep $ Set.fromList vs
  fvs = ABT.freeVars b
  evs = Set.toList $ Set.difference fvs keep
  a = ABT.annotation b
  lbody = rec keep' bd
  lamb = lam' a (evs ++ vs) lbody
enclose keep rec t@(LamsNamed' vs body)
  = Just $ if null evs then lamb else apps' lamb $ map (var a) evs
  where
  -- remove shadowed variables
  keep' = Set.difference keep $ Set.fromList vs
  fvs = ABT.freeVars t
  evs = Set.toList $ Set.difference fvs keep
  a = ABT.annotation t
  lbody = rec keep' body
  lamb = lam' a (evs ++ vs) lbody
enclose _ _ _ = Nothing

close :: (Var v, Monoid a) => Set v -> Term v a -> Term v a
close keep tm = ABT.visitPure (enclose keep close) tm

type FloatM v a r = State (Set v, [(v, Term v a)]) r

letFloater
  :: (Var v, Monoid a)
  => (Term v a -> FloatM v a (Term v a))
  -> [(v, Term v a)] -> Term v a
  -> FloatM v a (Term v a)
letFloater rec vbs e = do
  (cvs, ctx) <- get
  let shadows = [ (v, Var.freshIn cvs v)
                | (v, _) <- vbs, Set.member v cvs ]
      shadowMap = Map.fromList shadows
      rn v = Map.findWithDefault v v shadowMap
  fvbs <- traverse (\(v, b) -> (,) (rn v) <$> rec' (ABT.changeVars shadowMap b)) vbs
  let fcvs = Set.fromList . map fst $ fvbs
  put (cvs <> fcvs, ctx ++ fvbs)
  pure $ ABT.changeVars shadowMap e
  where
  rec' b@(LamsNamed' vs bd) = lam' (ABT.annotation b) vs <$> rec bd
  rec' b = rec b

lamFloater
  :: (Var v, Monoid a)
  => Maybe v -> a -> [v] -> Term v a -> FloatM v a v
lamFloater mv a vs bd
  = state $ \(cvs, ctx) ->
      let v = fromMaybe (ABT.freshIn cvs $ typed Var.Float) mv
       in (v, (Set.insert v cvs, ctx <> [(v, lam' a vs bd)]))

floater
  :: (Var v, Monoid a)
  => (Term v a -> FloatM v a (Term v a))
  -> Term v a -> Maybe (FloatM v a (Term v a))
floater rec (LetRecNamed' vbs e) = Just $ letFloater rec vbs e >>= rec
floater rec (Let1Named' v b e)
  | LamsNamed' vs bd <- b
  = Just $ rec bd >>= lamFloater (Just v) a vs >> rec e
  where a = ABT.annotation b
floater rec tm@(LamsNamed' vs bd) = Just $ do
  bd <- rec bd
  lv <- lamFloater Nothing a vs bd
  pure $ var a lv
  where a = ABT.annotation tm
floater _ _ = Nothing

float :: (Var v, Monoid a) => Term v a -> Term v a
float tm = case runState (go tm) (Set.empty, []) of
  (bd, (_, ctx)) -> letRec' True ctx bd
  where go = ABT.visit $ floater go

lamLift :: (Var v, Monoid a) => Term v a -> Term v a
lamLift = float . close Set.empty

optimize :: forall a v . (Semigroup a, Var v) => Term v a -> Term v a
optimize t = go t where
  ann = ABT.annotation
  go (Let1' b body) | canSubstLet b body = go (ABT.bind body b)
  go e@(App' f arg) = case go f of
    Lam' f -> go (ABT.bind f arg)
    f -> app (ann e) f (go arg)
  go (If' (Boolean' False) _ f) = go f
  go (If' (Boolean' True) t _) = go t
  -- todo: can simplify match expressions
  go e@(ABT.Var' _) = e
  go e@(ABT.Tm' f) = case e of
    Lam' _ -> e -- optimization is shallow - don't descend into lambdas
    _ -> ABT.tm' (ann e) (go <$> f)
  go e@(ABT.out -> ABT.Cycle body) = ABT.cycle' (ann e) (go body)
  go e@(ABT.out -> ABT.Abs v body) = ABT.abs' (ann e) v (go body)
  go e = e

  -- test for whether an expression `let x = y in body` can be
  -- reduced by substituting `y` into `body`. We only substitute
  -- when `y` is a variable or a primitive, otherwise this might
  -- end up duplicating evaluation or changing the order that
  -- effects are evaluated
  canSubstLet expr _body
    | isLeaf expr = True
    -- todo: if number of occurrences of the binding is 1 and the
    -- binding is pure, okay to substitute
    | otherwise   = False

isLeaf :: ABT.Term (F typeVar typeAnn patternAnn) v a -> Bool
isLeaf (Var' _) = True
isLeaf (Int' _) = True
isLeaf (Float' _) = True
isLeaf (Nat' _) = True
isLeaf (Text' _) = True
isLeaf (Boolean' _) = True
isLeaf (Constructor' _ _) = True
isLeaf (TermLink' _) = True
isLeaf (TypeLink' _) = True
isLeaf _ = False

minimizeCyclesOrCrash :: Var v => Term v a -> Term v a
minimizeCyclesOrCrash t = case minimize' t of
  Right t -> t
  Left e -> error $ "tried to minimize let rec with duplicate definitions: "
                 ++ show (fst <$> toList e)

fromTerm' :: (Monoid a, Var v) => (v -> v) -> Term v a -> Term v a
fromTerm' liftVar t = term (fromTerm liftVar t)

fromTerm :: forall a v . (Monoid a, Var v) => (v -> v) -> Term v a -> ANF v a
fromTerm liftVar t = ANF_ (go $ lambdaLift liftVar t) where
  ann = ABT.annotation
  isRef (Ref' _) = True
  isRef _ = False
  fixup :: Set v -- if we gotta create new vars, avoid using these
       -> ([Term v a] -> Term v a) -- do this with ANF'd args
       -> [Term v a] -- the args (not all in ANF already)
       -> Term v a -- the ANF'd term
  fixup used f args = let
    args' = Map.fromList $ toVar =<< (args `zip` [0..])
    toVar (b, i) | isLeaf b   = []
                 | otherwise = [(i, Var.freshIn used (Var.named . Text.pack $ "arg" ++ show i))]
    argsANF = map toANF (args `zip` [0..])
    toANF (b,i) = maybe b (var (ann b)) $ Map.lookup i args'
    addLet (b,i) body = maybe body (\v -> let1' False [(v,go b)] body) (Map.lookup i args')
    in foldr addLet (f argsANF) (args `zip` [(0::Int)..])
  go :: Term v a -> Term v a
  go e@(Apps' f args)
    | (isRef f || isLeaf f) && all isLeaf args = e
    | not (isRef f || isLeaf f) =
      let f' = ABT.fresh e (Var.named "f")
      in let1' False [(f', go f)] (go $ apps' (var (ann f) f') args)
    | otherwise = fixup (ABT.freeVars e) (apps' f) args
  go e@(Handle' h body)
    | isLeaf h = handle (ann e) h (go body)
    | otherwise = let h' = ABT.fresh e (Var.named "handler")
                  in let1' False [(h', go h)] (handle (ann e) (var (ann h) h') (go body))
  go e@(If' cond t f)
    | isLeaf cond = iff (ann e) cond (go t) (go f)
    | otherwise = let cond' = ABT.fresh e (Var.named "cond")
                  in let1' False [(cond', go cond)] (iff (ann e) (var (ann cond) cond') (go t) (go f))
  go e@(Match' scrutinee cases)
    | isLeaf scrutinee = match (ann e) scrutinee (fmap go <$> cases)
    | otherwise = let scrutinee' = ABT.fresh e (Var.named "scrutinee")
                  in let1' False [(scrutinee', go scrutinee)]
                      (match (ann e)
                             (var (ann scrutinee) scrutinee')
                             (fmap go <$> cases))
  -- MatchCase RHS, shouldn't conflict with LetRec
  go (ABT.Abs1NA' avs t) = ABT.absChain' avs (go t)
  go e@(And' x y)
    | isLeaf x = and (ann e) x (go y)
    | otherwise =
        let x' = ABT.fresh e (Var.named "argX")
        in let1' False [(x', go x)] (and (ann e) (var (ann x) x') (go y))
  go e@(Or' x y)
    | isLeaf x = or (ann e) x (go y)
    | otherwise =
        let x' = ABT.fresh e (Var.named "argX")
        in let1' False [(x', go x)] (or (ann e) (var (ann x) x') (go y))
  go e@(Var' _) = e
  go e@(Int' _) = e
  go e@(Nat' _) = e
  go e@(Float' _) = e
  go e@(Boolean' _) = e
  go e@(Text' _) = e
  go e@(Char' _) = e
  go e@(Blank' _) = e
  go e@(Ref' _) = e
  go e@(TermLink' _) = e
  go e@(TypeLink' _) = e
  go e@(RequestOrCtor' _ _) = e
  go e@(Lam' _) = e -- ANF conversion is shallow -
                     -- don't descend into closed lambdas
  go (Let1Named' v b e) = let1' False [(v, go b)] (go e)
  -- top = False because we don't care to emit typechecker notes about TLDs
  go (LetRecNamed' bs e) = letRec' False (fmap (second go) bs) (go e)
  go e@(Sequence' vs) =
    if all isLeaf vs then e
    else fixup (ABT.freeVars e) (seq (ann e)) (toList vs)
  go e@(Ann' tm typ) = Term.ann (ann e) (go tm) typ
  go e = error $ "ANF.term: I thought we got all of these\n" <> show e

data Mem = UN | BX deriving (Eq,Ord,Show,Enum)

-- Context entries with evaluation strategy
data CTE v s
  = ST v Mem s
  | LZ v (Either Int v) [v]

cbvar :: CTE v s -> v
cbvar (ST v _ _) = v
cbvar (LZ v _ _) = v

data ANormalBF v e
  = ALet Mem (ANormalTF v e) e
  | AName (Either Int v) [v] e
  | ATm (ANormalTF v e)
  deriving (Show)

data ANormalTF v e
  = ALit Lit
  | AMatch v (Branched e)
  | AHnd [Int] v (Maybe e) e
  | AApp (Func v) [v]
  | AFrc v
  | AVar v
  deriving (Show)

instance Functor (ANormalBF v) where
  fmap f (ALet m bn bo) = ALet m (f <$> bn) $ f bo
  fmap f (AName n as bo) = AName n as $ f bo
  fmap f (ATm tm) = ATm $ f <$> tm

instance Bifunctor ANormalBF where
  bimap f g (ALet m bn bo) = ALet m (bimap f g bn) $ g bo
  bimap f g (AName n as bo) = AName (f <$> n) (f <$> as) $ g bo
  bimap f g (ATm tm) = ATm (bimap f g tm)

instance Bifoldable ANormalBF where
  bifoldMap f g (ALet _ b e) = bifoldMap f g b <> g e
  bifoldMap f g (AName n as e) = foldMap f n <> foldMap f as <> g e
  bifoldMap f g (ATm e) = bifoldMap f g e

instance Functor (ANormalTF v) where
  fmap _ (AVar v) = AVar v
  fmap _ (ALit l) = ALit l
  fmap f (AMatch v br) = AMatch v $ f <$> br
  fmap f (AHnd rs h d e) = AHnd rs h (f <$> d) $ f e
  fmap _ (AFrc v) = AFrc v
  fmap _ (AApp f args) = AApp f args

instance Bifunctor ANormalTF where
  bimap f _ (AVar v) = AVar (f v)
  bimap _ _ (ALit l) = ALit l
  bimap f g (AMatch v br) = AMatch (f v) $ fmap g br
  bimap f g (AHnd rs v d e) = AHnd rs (f v) (g <$> d) $ g e
  bimap f _ (AFrc v) = AFrc (f v)
  bimap f _ (AApp fu args) = AApp (fmap f fu) $ fmap f args

instance Bifoldable ANormalTF where
  bifoldMap f _ (AVar v) = f v
  bifoldMap _ _ (ALit _) = mempty
  bifoldMap f g (AMatch v br) = f v <> foldMap g br
  bifoldMap f g (AHnd _ h d e) = f h <> foldMap g d <> g e
  bifoldMap f _ (AFrc v) = f v
  bifoldMap f _ (AApp func args) = foldMap f func <> foldMap f args

matchLit :: Term v a -> Maybe Lit
matchLit (Int' i) = Just $ I i
matchLit (Nat' n) = Just $ N n
matchLit (Float' f) = Just $ F f
matchLit (Boolean' b) = Just $ B b
matchLit (Text' t) = Just $ T t
matchLit (Char' c) = Just $ C c
matchLit _ = Nothing

pattern Lit' l <- (matchLit -> Just l)
pattern TLet v m bn bo = ABTN.TTm (ALet m bn (ABTN.TAbs v bo))
pattern TName v f as bo = ABTN.TTm (AName f as (ABTN.TAbs v bo))
pattern TTm e = ABTN.TTm (ATm e)
{-# complete TLet, TName, TTm #-}

pattern TLit l = TTm (ALit l)

pattern TApp f args = TTm (AApp f args)
pattern AApv v args = AApp (FVar v) args
pattern TApv v args = TApp (FVar v) args
pattern ACom r args = AApp (FComb r) args
pattern TCom r args = TApp (FComb r) args
pattern ACon r t args = AApp (FCon r t) args
pattern TCon r t args = TApp (FCon r t) args
pattern AReq r t args = AApp (FReq r t) args
pattern TReq r t args = TApp (FReq r t) args
pattern APrm p args = AApp (FPrim p) args
pattern TPrm p args = TApp (FPrim p) args

pattern THnd rs h d b = TTm (AHnd rs h d b)
pattern TMatch v cs = TTm (AMatch v cs)
pattern TVar v = TTm (AVar v)

{-# complete TLet, TName, TVar, TApp, TLit, THnd, TMatch #-}
{-# complete TLet, TName,
      TVar, TApv, TCom, TCon, TReq, TPrm, TLit, THnd, TMatch
  #-}

directVars :: Var v => ANormalT v -> Set.Set v
directVars = bifoldMap Set.singleton (const mempty)

freeVarsT :: Var v => ANormalT v -> Set.Set v
freeVarsT = bifoldMap Set.singleton ABTN.freeVars

bind :: Var v => Cte v -> ANormal v -> ANormal v
bind (ST u m bu) = TLet u m bu
bind (LZ u f as) = TName u f as

unbind :: Var v => ANormal v -> Maybe (Cte v, ANormal v)
unbind (TLet u m bu bd) = Just (ST u m bu, bd)
unbind (TName u f as bd) = Just (LZ u f as, bd)
unbind _ = Nothing

unbinds :: Var v => ANormal v -> (Ctx v, ANormal v)
unbinds (TLet u m bu (unbinds -> (ctx, bd))) = (ST u m bu:ctx, bd)
unbinds (TName u f as (unbinds -> (ctx, bd))) = (LZ u f as:ctx, bd)
unbinds tm = ([], tm)

unbinds' :: Var v => ANormal v -> (Ctx v, ANormalT v)
unbinds' (TLet u m bu (unbinds' -> (ctx, bd))) = (ST u m bu:ctx, bd)
unbinds' (TName u f as (unbinds' -> (ctx, bd))) = (LZ u f as:ctx, bd)
unbinds' (TTm tm) = ([], tm)

pattern TBind bn bd <- (unbind -> Just (bn, bd))
  where TBind bn bd = bind bn bd

pattern TBinds :: Var v => Ctx v -> ANormal v -> ANormal v
pattern TBinds ctx bd <- (unbinds -> (ctx, bd))
  where TBinds ctx bd = foldr bind bd ctx

pattern TBinds' :: Var v => Ctx v -> ANormalT v -> ANormal v
pattern TBinds' ctx bd <- (unbinds' -> (ctx, bd))
  where TBinds' ctx bd = foldr bind (TTm bd) ctx

{-# complete TBinds' #-}

data Branched e
  = MatchIntegral (IntMap e) (Maybe e)
  | MatchRequest (IntMap (IntMap ([Mem], e)))
  | MatchEmpty
  | MatchData Reference (IntMap ([Mem], e)) (Maybe e)
  deriving (Show, Functor, Foldable, Traversable)

data BranchAccum v
  = AccumEmpty
  | AccumIntegral Reference (Maybe (ANormal v)) (IntMap (ANormal v))
  | AccumDefault (ANormal v)
  | AccumRequest (IntMap (IntMap ([Mem],ANormal v))) (Maybe (ANormal v))
  | AccumData Reference (Maybe (ANormal v)) (IntMap ([Mem],ANormal v))

instance Semigroup (BranchAccum v) where
  AccumEmpty <> r = r
  l <> AccumEmpty = l
  AccumIntegral rl dl cl <> AccumIntegral rr dr cr
    | rl == rr = AccumIntegral rl (dl <|> dr) $ cl <> cr
  AccumData rl dl cl <> AccumData rr dr cr
    | rl == rr = AccumData rl (dl <|> dr) (cl <> cr)
  AccumDefault dl <> AccumIntegral r _ cr
    = AccumIntegral r (Just dl) cr
  AccumDefault dl <> AccumData rr _ cr
    = AccumData rr (Just dl) cr
  AccumIntegral r dl cl <> AccumDefault dr
    = AccumIntegral r (dl <|> Just dr) cl
  AccumData rl dl cl <> AccumDefault dr
    = AccumData rl (dl <|> Just dr) cl
  AccumRequest hl dl <> AccumRequest hr dr
    = AccumRequest hm $ dl <|> dr
    where
    hm = IMap.unionWith (<>) hl hr
  _ <> _ = error "cannot merge data cases for different types"

instance Monoid (BranchAccum e) where
  mempty = AccumEmpty

data Func v
  -- variable
  = FVar v
  -- top-level combinator
  | FComb !Int
  -- data constructor
  | FCon !Reference !Int
  -- ability request
  | FReq !Int !Int
  -- prim op
  | FPrim POp
  deriving (Show, Functor, Foldable, Traversable)

data Lit
  = I Int64
  | N Word64
  | F Double
  | B Bool
  | T Text
  | C Char
  deriving (Show)

litRef :: Lit -> Reference
litRef (I _) = Ty.intRef
litRef (N _) = Ty.natRef
litRef (F _) = Ty.floatRef
litRef (B _) = Ty.booleanRef
litRef (T _) = Ty.textRef
litRef (C _) = Ty.charRef

data POp
  -- Int
  = ADDI | SUBI | MULI | DIVI -- +,-,*,/
  | SGNI | NEGI | TRNI | MODI -- sgn,neg,trunc,mod
  | POWI | SHLI | SHRI        -- pow,shiftl,shiftr
  | INCI | DECI               -- inc,dec
  | LESI | LEQI | EQLI        -- <,<=,==
  -- Nat
  | ADDN | SUBN | MULN | DIVN -- +,-,*,/
  | MODN                      -- mod
  | POWN | SHLN | SHRN        -- pow,shiftl,shiftr
  | INCN | DECN               -- inc,dec
  | LESN | LEQN | EQLN        -- <,<=,==
  -- Float
  | ADDF | SUBF | MULF | DIVF -- +,-,*,/
  | LESF | LEQF | EQLF        -- <,<=,==
  deriving (Show,Eq,Ord)

type ANormal = ABTN.Term ANormalBF
type ANormalT v = ANormalTF v (ANormal v)

type Cte v = CTE v (ANormalT v)
type Ctx v = [Cte v]

-- Should be a completely closed term
data SuperNormal v
  = Lambda { conventions :: [Mem], bound :: ANormal v }
data SuperGroup v
  = Rec
  { group :: [(v, SuperNormal v)]
  , entry :: SuperNormal v
  }

type ANFM v
  = ReaderT (Set v, Reference -> Int)
      (State (Set v, [(v, SuperNormal v)]))

-- clear :: Var v => ANFM v ()
-- clear = do
--   (gl, _) <- ask
--   modify $ \(_, to) -> (Set.union gl . Set.fromList $ fst <$> to, to)

reset :: ANFM v a -> ANFM v a
reset m = do
  (av, _) <- get
  m <* modify (\(_, to) -> (av, to))

avoid :: Var v => [v] -> ANFM v ()
avoid = avoids . Set.fromList

avoids :: Var v => Set v -> ANFM v ()
avoids s = modify $ \(av, rs) -> (s `Set.union` av, rs)

avoidCtx :: Var v => Ctx v -> ANFM v ()
avoidCtx ctx = avoid $ cbvar <$> ctx

-- reserve :: ANFM v Int
-- reserve = state $ \(av, gl, to) -> (gl, (av, gl+1, to))

resolve :: Reference -> ANFM v Int
resolve r = ($r) . snd <$> ask

fresh :: Var v => ANFM v v
fresh = gets $ \(av, _) -> flip ABT.freshIn (typed Var.ANFBlank) av

contextualize :: Var v => ANormalT v -> ANFM v (Ctx v, v)
contextualize (AVar cv) = pure ([], cv)
contextualize tm = do
  fv <- reset $ avoids (freeVarsT tm) *> fresh
  avoid [fv]
  pure ([ST fv BX tm], fv)

record :: (v, SuperNormal v) -> ANFM v ()
record p = modify $ \(av, to) -> (av, p:to)

superNormalize
  :: Var v
  => (Reference -> Int)
  -> Term v a
  -> SuperGroup v
superNormalize rslv tm = Rec l c
  where
  (bs, e) | LetRecNamed' bs e <- tm = (bs, e)
          | otherwise = ([], tm)
  grp = Set.fromList $ fst <$> bs
  comp = traverse_ superBinding bs *> toSuperNormal e
  subc = runReaderT comp (grp, rslv)
  (c, (_,l)) = runState subc (grp, [])

superBinding :: Var v => (v, Term v a) -> ANFM v ()
superBinding (v, tm) = do
  nf <- toSuperNormal tm
  modify $ \(cvs, ctx) -> (cvs, (v,nf):ctx)

toSuperNormal :: Var v => Term v a -> ANFM v (SuperNormal v)
toSuperNormal tm = do
  (grp, _) <- ask
  if not . Set.null . (Set.\\ grp) $ freeVars tm
    then error $ "free variables in supercombinator: " ++ show tm
    else reset $ do
      avoid vs
      Lambda (BX <$ vs) . ABTN.TAbss vs <$> anfTerm body
  where
  (vs, body) = fromMaybe ([], tm) $ unLams' tm

anfTerm :: Var v => Term v a -> ANFM v (ANormal v)
anfTerm tm = uncurry TBinds' <$> anfBlock tm

anfBlock :: Var v => Term v a -> ANFM v (Ctx v, ANormalT v)
anfBlock (Var' v) = pure ([], AVar v)
anfBlock (If' c t f) = do
  (cctx, cc) <- anfBlock c
  cf <- anfTerm f
  ct <- anfTerm t
  (cx, v) <- contextualize cc
  let cases = MatchData
                (Builtin $ Text.pack "Boolean")
                (IMap.singleton 0 ([], cf))
                (Just ct)
  pure (cctx ++ cx, AMatch v cases)
anfBlock (And' l r) = do
  (lctx, vl) <- anfArg l
  (rctx, vr) <- anfArg r
  i <- resolve $ Builtin "Boolean.and"
  pure (lctx ++ rctx, ACom i [vl, vr])
anfBlock (Or' l r) = do
  (lctx, vl) <- anfArg l
  (rctx, vr) <- anfArg r
  i <- resolve $ Builtin "Boolean.or"
  pure (lctx ++ rctx, ACom i [vl, vr])
anfBlock (Handle' h body)
  = anfArg h >>= \(hctx, vh) ->
    anfBlock body >>= \case
      ([], ACom f as) -> do
        avoid as
        v <- fresh
        avoid [v]
        pure (hctx ++ [LZ v (Left f) as], AApp (FVar vh) [v])
      (_, _) ->
        error "handle body should be a call to a top-level combinator"
anfBlock (Match' scrut cas) = do
  (sctx, sc) <- anfBlock scrut
  (cx, v) <- contextualize sc
  brn <- anfCases v cas
  case brn of
    AccumDefault (TBinds' dctx df) -> do
      avoidCtx dctx
      pure (sctx ++ cx ++ dctx, df)
    AccumRequest abr df -> do
      (r, vs) <- reset $ do
        r <- fresh
        v <- fresh
        let hfb = ABTN.TAbs v . TMatch v $ MatchRequest abr
            hfvs = Set.toList $ ABTN.freeVars hfb
        record (r, Lambda (BX <$ hfvs) . ABTN.TAbss hfvs $ hfb)
        pure (r, hfvs)
      hv <- fresh
      let msc | [ST _ BX tm] <- cx = tm
              | [ST _ UN _] <- cx = error "anfBlock: impossible"
              | otherwise = AFrc v
      pure ( sctx ++ [LZ hv (Right r) vs]
           , AHnd (IMap.keys abr) hv df . TTm $ msc
           )
    AccumIntegral r df cs -> do
      i <- fresh
      let dcs = MatchData r
                  (IMap.singleton 0 ([UN], ABTN.TAbss [i] ics))
                  Nothing
          ics = TMatch i $ MatchIntegral cs df
      pure (sctx ++ cx, AMatch v dcs)
    AccumData r df cs ->
      pure (sctx ++ cx, AMatch v $ MatchData r cs df)
    AccumEmpty -> pure (sctx ++ cx, AMatch v MatchEmpty)
anfBlock (Let1Named' v b e) = do
  avoid [v]
  (bctx, cb) <- anfBlock b
  (ectx, ce) <- anfBlock e
  pure (bctx ++ ST v BX cb : ectx, ce)
anfBlock (Apps' f args) = do
  (fctx, cf) <- anfFunc f
  (actxs, cas) <- unzip <$> traverse anfArg args
  pure (fctx ++ concat actxs, AApp cf cas)
anfBlock (Constructor' r t) = do
  pure ([], ACon r t [])
anfBlock (Request' r t) = do
  r <- resolve r
  pure ([], AReq r t [])
anfBlock (Lit' l) = do
  lv <- fresh
  pure ([ST lv UN $ ALit l], ACon (litRef l) 0 [lv])
anfBlock (Blank' _) = error "tried to compile Blank"
anfBlock t = error $ "anf: unhandled term: " ++ show t

-- Note: this assumes that patterns have already been translated
-- to a state in which every case matches a single layer of data,
-- with no guards, and no variables ignored. This is not checked
-- completely.
anfInitCase
  :: Var v
  => v
  -> MatchCase p (Term v a)
  -> ANFM v (BranchAccum v)
anfInitCase u (MatchCase p guard (ABT.AbsN' vs bd))
  | Just _ <- guard = error "anfInitCase: unexpected guard"
  | UnboundP _ <- p
  , [] <- vs
  = AccumDefault <$> anfTerm bd
  | VarP _ <- p
  , [v] <- vs
  = AccumDefault . ABTN.rename v u <$> anfTerm bd
  | VarP _ <- p
  = error $ "vars: " ++ show (length vs)
  | IntP _ (fromIntegral -> i) <- p
  = AccumIntegral Ty.intRef Nothing . IMap.singleton i <$> anfTerm bd
  | NatP _ (fromIntegral -> i) <- p
  = AccumIntegral Ty.natRef Nothing . IMap.singleton i <$> anfTerm bd
  | ConstructorP _ r t ps <- p = do
    us <- expandBindings ps vs
    AccumData r Nothing
      . IMap.singleton t
      . (BX<$us,)
      . ABTN.TAbss us
      <$> anfTerm bd
  | EffectPureP _ q <- p = do
    us <- expandBindings [q] vs
    AccumRequest IMap.empty . Just . ABTN.TAbss us <$> anfTerm bd
  | EffectBindP _ r t ps pk <- p = do
    us <- expandBindings (ps ++ [pk]) vs
    n <- resolve r
    flip AccumRequest Nothing
       . IMap.singleton n
       . IMap.singleton t
       . (BX<$us,)
       . ABTN.TAbss us
      <$> anfTerm bd
anfInitCase _ (MatchCase p _ _)
  = error $ "anfInitCase: unexpected pattern: " ++ show p

expandBindings'
  :: Var v
  => Set v
  -> [PatternP p]
  -> [v]
  -> [v]
expandBindings' _ [] [] = []
expandBindings' avoid (UnboundP _:ps) vs
  = u : expandBindings' (Set.insert u avoid) ps vs
  where u = ABT.freshIn avoid $ typed Var.ANFBlank
expandBindings' avoid (VarP _:ps) (v:vs)
  = v : expandBindings' avoid ps vs
expandBindings' _ [] (_:_)
  = error "expandBindings': more bindings than expected"
expandBindings' _ (VarP _:_) []
  = error "expandBindings': more patterns than expected"
expandBindings' _ _ _
  = error "expandBindings': unexpected pattern"

expandBindings :: Var v => [PatternP p] -> [v] -> ANFM v [v]
expandBindings ps vs = (\(av,_) -> expandBindings' av ps vs) <$> get

anfCases
  :: Var v
  => v
  -> [MatchCase p (Term v a)]
  -> ANFM v (BranchAccum v)
anfCases u = fmap fold . traverse (anfInitCase u)

anfFunc :: Var v => Term v a -> ANFM v (Ctx v, Func v)
anfFunc (Var' v) = pure ([], FVar v)
anfFunc (Ref' r) = do
  n <- resolve r
  pure ([], FComb n)
anfFunc (Constructor' r t) = do
  pure ([], FCon r t)
anfFunc (Request' r t) = do
  n <- resolve r
  pure ([], FReq n t)
anfFunc tm = do
  (fctx, ctm) <- anfBlock tm
  (cx, v) <- contextualize ctm
  pure (fctx ++ cx, FVar v)

anfArg :: Var v => Term v a -> ANFM v (Ctx v, v)
anfArg tm = do
  (ctx, ctm) <- anfBlock tm
  (cx, v) <- contextualize ctm
  pure (ctx ++ cx, v)

sink :: Var v => v -> Mem -> ANormalT v -> ANormal v -> ANormal v
sink v mtm tm = dive $ freeVarsT tm
  where
  dive _ exp | v `Set.notMember` ABTN.freeVars exp = exp
  dive avoid exp@(TName u f as bo)
    | v `elem` as
    = let w = freshANF avoid (ABTN.freeVars exp)
       in TLet w mtm tm $ ABTN.rename v w exp
    | otherwise
    = TName u f as (dive avoid' bo)
    where avoid' = Set.insert u avoid
  dive avoid exp@(TLet u m bn bo)
    | v `Set.member` directVars bn -- we need to stop here
    = let w = freshANF avoid (ABTN.freeVars exp)
       in TLet w mtm tm $ ABTN.rename v w exp
    | otherwise
    = TLet u m bn' $ dive avoid' bo
    where
    avoid' = Set.insert u avoid
    bn' | v `Set.notMember` freeVarsT bn = bn
        | otherwise = dive avoid' <$> bn
  dive avoid exp@(TTm tm)
    | v `Set.member` directVars tm -- same as above
    = let w = freshANF avoid (ABTN.freeVars exp)
       in TLet w mtm tm $ ABTN.rename v w exp
    | otherwise = TTm $ dive avoid <$> tm

freshANF :: Var v => Set v -> Set v -> v
freshANF avoid free
  = ABT.freshIn (Set.union avoid free) (typed Var.ANFBlank)


