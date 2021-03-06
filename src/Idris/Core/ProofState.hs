{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, PatternGuards #-}

{- Implements a proof state, some primitive tactics for manipulating
   proofs, and some high level commands for introducing new theorems,
   evaluation/checking inside the proof system, etc. --}

module Idris.Core.ProofState(ProofState(..), newProof, envAtFocus, goalAtFocus,
                  Tactic(..), Goal(..), processTactic,
                  dropGiven, keepGiven) where

import Idris.Core.Typecheck
import Idris.Core.Evaluate
import Idris.Core.TT
import Idris.Core.Unify

import Control.Monad.State.Strict
import Control.Applicative hiding (empty)
import Data.List
import Debug.Trace

import Util.Pretty hiding (fill)

data ProofState = PS { thname   :: Name,
                       holes    :: [Name], -- holes still to be solved
                       usedns   :: [Name], -- used names, don't use again
                       nextname :: Int,    -- name supply
                       pterm    :: Term,   -- current proof term
                       ptype    :: Type,   -- original goal
                       dontunify :: [Name], -- explicitly given by programmer, leave it
                       unified  :: (Name, [(Name, Term)]),
                       notunified :: [(Name, Term)],
                       solved   :: Maybe (Name, Term),
                       problems :: Fails,
                       injective :: [Name],
                       deferred :: [Name], -- names we'll need to define
                       instances :: [Name], -- instance arguments (for type classes)
                       previous :: Maybe ProofState, -- for undo
                       context  :: Context,
                       plog     :: String,
                       unifylog :: Bool,
                       done     :: Bool
                     }

data Goal = GD { premises :: Env,
                 goalType :: Binder Term
               }

data Tactic = Attack
            | Claim Name Raw
            | Reorder Name
            | Exact Raw
            | Fill Raw
            | MatchFill Raw
            | PrepFill Name [Name]
            | CompleteFill
            | Regret
            | Solve
            | StartUnify Name
            | EndUnify
            | Compute
            | ComputeLet Name
            | Simplify
            | HNF_Compute
            | EvalIn Raw
            | CheckIn Raw
            | Intro (Maybe Name)
            | IntroTy Raw (Maybe Name)
            | Forall Name Raw
            | LetBind Name Raw Raw
            | ExpandLet Name Term
            | Rewrite Raw
            | Induction Name
            | Equiv Raw
            | PatVar Name
            | PatBind Name
            | Focus Name
            | Defer Name
            | DeferType Name Raw [Name]
            | Instance Name
            | SetInjective Name
            | MoveLast Name
            | MatchProblems Bool
            | UnifyProblems
            | ProofState
            | Undo
            | QED
    deriving Show

-- Some utilites on proof and tactic states

instance Show ProofState where
    show (PS nm [] _ _ tm _ _ _ _ _ _ _ _ _ _ _ _ _ _)
          = show nm ++ ": no more goals"
    show (PS nm (h:hs) _ _ tm _ _ _ _ _ _ _ i _ _ ctxt _ _ _)
          = let OK g = goal (Just h) tm
                wkenv = premises g in
                "Other goals: " ++ show hs ++ "\n" ++
                showPs wkenv (reverse wkenv) ++ "\n" ++
                "-------------------------------- (" ++ show nm ++
                ") -------\n  " ++
                show h ++ " : " ++ showG wkenv (goalType g) ++ "\n"
         where showPs env [] = ""
               showPs env ((n, Let t v):bs)
                   = "  " ++ show n ++ " : " ++
                     showEnv env ({- normalise ctxt env -} t) ++ "   =   " ++
                     showEnv env ({- normalise ctxt env -} v) ++
                     "\n" ++ showPs env bs
               showPs env ((n, b):bs)
                   = "  " ++ show n ++ " : " ++
                     showEnv env ({- normalise ctxt env -} (binderTy b)) ++
                     "\n" ++ showPs env bs
               showG ps (Guess t v) = showEnv ps ({- normalise ctxt ps -} t) ++
                                         " =?= " ++ showEnv ps v
               showG ps b = showEnv ps (binderTy b)

instance Pretty ProofState OutputAnnotation where
  pretty (PS nm [] _ _ trm _ _ _ _ _ _ _ _ _ _ _ _ _ _) =
    pretty nm <+> colon <+> text " no more goals."
  pretty p@(PS nm (h:hs) _ _ tm _ _ _ _ _ _ _ i _ _ ctxt _ _ _) =
    let OK g  = goal (Just h) tm in
    let wkEnv = premises g in
      text "Other goals" <+> colon <+> pretty hs <+>
      prettyPs wkEnv (reverse wkEnv) <+>
      text "---------- " <+> text "Focussing on" <> colon <+> pretty nm <+> text " ----------" <+>
      pretty h <+> colon <+> prettyGoal wkEnv (goalType g)
    where
      prettyGoal ps (Guess t v) =
        prettyEnv ps t <+> text "=?=" <+> prettyEnv ps v
      prettyGoal ps b = prettyEnv ps $ binderTy b

      prettyPs env [] = empty
      prettyPs env ((n, Let t v):bs) =
        nest nestingSize (pretty n <+> colon <+>
        prettyEnv env t <+> text "=" <+> prettyEnv env v <+>
        nest nestingSize (prettyPs env bs))
      prettyPs env ((n, b):bs) =
        nest nestingSize (pretty n <+> colon <+> prettyEnv env (binderTy b) <+>
        nest nestingSize (prettyPs env bs))

same Nothing n  = True
same (Just x) n = x == n

hole (Hole _)    = True
hole (Guess _ _) = True
hole _           = False

holeName i = sMN i "hole"

qshow :: Fails -> String
qshow fs = show (map (\ (x, y, _, _, t) -> (t, x, y)) fs)

match_unify' :: Context -> Env -> TT Name -> TT Name ->
                StateT TState TC [(Name, TT Name)]
match_unify' ctxt env topx topy =
   do ps <- get
      let dont = dontunify ps
      let inj = injective ps
      traceWhen (unifylog ps)
                ("Matching " ++ show (topx, topy) ++ 
                 " in " ++ show env ++
                 "\nHoles: " ++ show (holes ps)
                  ++ "\n" 
                  ++ "\n" ++ show (pterm ps) ++ "\n\n"
                 ) $
       case match_unify ctxt env topx topy inj (holes ps) of
            OK u -> do let (h, ns) = unified ps
                       put (ps { unified = (h, u ++ ns) })
                       return u
            Error e -> do put (ps { problems = (topx, topy, env, e, Match) :
                                                  problems ps })
                          return []
--       traceWhen (unifylog ps)
--             ("Matched " ++ show (topx, topy) ++ " without " ++ show dont ++
--              "\nSolved: " ++ show u 
--              ++ "\nCurrent problems:\n" ++ qshow (problems ps)
-- --              ++ show (pterm ps)
--              ++ "\n----------") $

unify' :: Context -> Env -> TT Name -> TT Name ->
          StateT TState TC [(Name, TT Name)]
unify' ctxt env topx topy =
   do ps <- get
      let dont = dontunify ps
      let inj = injective ps
      (u, fails) <- traceWhen (unifylog ps)
                        ("Trying " ++ show (topx, topy) ++
                         "\nNormalised " ++ show (normalise ctxt env topx,
                                                  normalise ctxt env topy) ++ 
                         " in " ++ show env ++
                         "\nHoles: " ++ show (holes ps)
                         ++ "\nInjective: " ++ show (injective ps) 
                         ++ "\n") $
                     lift $ unify ctxt env topx topy inj (holes ps)
      let notu = filter (\ (n, t) -> case t of
                                        P _ _ _ -> False
                                        _ -> n `elem` dont) u
      traceWhen (unifylog ps)
            ("Unified " ++ show (topx, topy) ++ " without " ++ show dont ++
             "\nSolved: " ++ show u ++ "\nNew problems: " ++ qshow fails
             ++ "\nNot unified:\n" ++ show (notunified ps) 
             ++ "\nCurrent problems:\n" ++ qshow (problems ps)
--              ++ show (pterm ps)
             ++ "\n----------") $
        do ps <- get
           let (h, ns) = unified ps
           let (ns', probs') = updateProblems (context ps) (u ++ ns)
                                              (fails ++ problems ps)
                                              (injective ps)
                                              (holes ps)
           put (ps { problems = probs',
                     unified = (h, ns'),
                     injective = updateInj u (injective ps),
                     notunified = notu ++ notunified ps })
           return u
  where updateInj ((n, a) : us) inj
              | (P _ n' _, _) <- unApply a,
                n `elem` inj = updateInj us (n':inj)
              | (P _ n' _, _) <- unApply a,
                n' `elem` inj = updateInj us (n:inj)
        updateInj (_ : us) inj = updateInj us inj
        updateInj [] inj = inj

getName :: Monad m => String -> StateT TState m Name
getName tag = do ps <- get
                 let n = nextname ps
                 put (ps { nextname = n+1 })
                 return $ sMN n tag

action :: Monad m => (ProofState -> ProofState) -> StateT TState m ()
action a = do ps <- get
              put (a ps)

addLog :: Monad m => String -> StateT TState m ()
addLog str = action (\ps -> ps { plog = plog ps ++ str ++ "\n" })

newProof :: Name -> Context -> Type -> ProofState
newProof n ctxt ty = let h = holeName 0
                         ty' = vToP ty in
                         PS n [h] [] 1 (Bind h (Hole ty')
                            (P Bound h ty')) ty [] (h, []) []
                            Nothing [] []
                            [] []
                            Nothing ctxt "" False False

type TState = ProofState -- [TacticAction])
type RunTactic = Context -> Env -> Term -> StateT TState TC Term
type Hole = Maybe Name -- Nothing = default hole, first in list in proof state

envAtFocus :: ProofState -> TC Env
envAtFocus ps
    | not $ null (holes ps) = do g <- goal (Just (head (holes ps))) (pterm ps)
                                 return (premises g)
    | otherwise = fail "No holes"

goalAtFocus :: ProofState -> TC (Binder Type)
goalAtFocus ps
    | not $ null (holes ps) = do g <- goal (Just (head (holes ps))) (pterm ps)
                                 return (goalType g)
    | otherwise = Error . Msg $ "No goal in " ++ show (holes ps) ++ show (pterm ps)

goal :: Hole -> Term -> TC Goal
goal h tm = g [] tm where
    g env (Bind n b@(Guess _ _) sc)
                        | same h n = return $ GD env b
                        | otherwise
                           = gb env b `mplus` g ((n, b):env) sc
    g env (Bind n b sc) | hole b && same h n = return $ GD env b
                        | otherwise
                           = g ((n, b):env) sc `mplus` gb env b
    g env (App f a)   = g env f `mplus` g env a
    g env t           = fail "Can't find hole"

    gb env (Let t v) = g env v `mplus` g env t
    gb env (Guess t v) = g env v `mplus` g env t
    gb env t = g env (binderTy t)

tactic :: Hole -> RunTactic -> StateT TState TC ()
tactic h f = do ps <- get
                (tm', _) <- atH (context ps) [] (pterm ps)
                ps <- get -- might have changed while processing
                put (ps { pterm = tm' })
  where
    updated o = do o' <- o
                   return (o', True)

    ulift2 c env op a b
                  = do (b', u) <- atH c env b
                       if u then return (op a b', True)
                            else do (a', u) <- atH c env a
                                    return (op a' b', u)

    -- Search the things most likely to contain the binding first!

    atH :: Context -> Env -> Term -> StateT TState TC (Term, Bool)
    atH c env binder@(Bind n b@(Guess t v) sc)
        | same h n = updated (f c env binder)
        | otherwise
            = do -- binder first
                 (b', u) <- ulift2 c env Guess t v
                 if u then return (Bind n b' sc, True)
                      else do (sc', u) <- atH c ((n, b) : env) sc
                              return (Bind n b' sc', u)
    atH c env binder@(Bind n b sc)
        | hole b && same h n = updated (f c env binder)
        | otherwise -- scope first
            = do (sc', u) <- atH c ((n, b) : env) sc
                 if u then return (Bind n b sc', True)
                      else do (b', u) <- atHb c env b
                              return (Bind n b' sc', u)
    atH c env (App f a)    = ulift2 c env App f a
    atH c env t            = return (t, False)

    atHb c env (Let t v)   = ulift2 c env Let t v
    atHb c env (Guess t v) = ulift2 c env Guess t v
    atHb c env t           = do (ty', u) <- atH c env (binderTy t)
                                return (t { binderTy = ty' }, u)

computeLet :: Context -> Name -> Term -> Term
computeLet ctxt n tm = cl [] tm where
   cl env (Bind n' (Let t v) sc)
       | n' == n = let v' = normalise ctxt env v in
                       Bind n' (Let t v') sc
   cl env (Bind n' b sc) = Bind n' (fmap (cl env) b) (cl ((n, b):env) sc)
   cl env (App f a) = App (cl env f) (cl env a)
   cl env t = t

attack :: RunTactic
attack ctxt env (Bind x (Hole t) sc)
    = do h <- getName "hole"
         action (\ps -> ps { holes = h : holes ps })
         return $ Bind x (Guess t (newtm h)) sc
  where
    newtm h = Bind h (Hole t) (P Bound h t)
attack ctxt env _ = fail "Not an attackable hole"

claim :: Name -> Raw -> RunTactic
claim n ty ctxt env t =
    do (tyv, tyt) <- lift $ check ctxt env ty
       lift $ isType ctxt env tyt
       action (\ps -> let (g:gs) = holes ps in
                          ps { holes = g : n : gs } )
       return $ Bind n (Hole tyv) t -- (weakenTm 1 t)

reorder_claims :: RunTactic
reorder_claims ctxt env t
    = -- trace (showSep "\n" (map show (scvs t))) $
      let (bs, sc) = scvs t []
          newbs = reverse (sortB (reverse bs)) in
          traceWhen (bs /= newbs) (show bs ++ "\n ==> \n" ++ show newbs) $
            return (bindAll newbs sc)
  where scvs (Bind n b@(Hole _) sc) acc = scvs sc ((n, b):acc)
        scvs sc acc = (reverse acc, sc)

        sortB :: [(Name, Binder (TT Name))] -> [(Name, Binder (TT Name))]
        sortB [] = []
        sortB (x:xs) | all (noOcc x) xs = x : sortB xs
                     | otherwise = sortB (insertB x xs)

        insertB x [] = [x]
        insertB x (y:ys) | all (noOcc x) (y:ys) = x : y : ys
                         | otherwise = y : insertB x ys

        noOcc (n, _) (_, Let t v) = noOccurrence n t && noOccurrence n v
        noOcc (n, _) (_, Guess t v) = noOccurrence n t && noOccurrence n v
        noOcc (n, _) (_, b) = noOccurrence n (binderTy b)

focus :: Name -> RunTactic
focus n ctxt env t = do action (\ps -> let hs = holes ps in
                                            if n `elem` hs
                                               then ps { holes = n : (hs \\ [n]) }
                                               else ps)
                        ps <- get
                        return t

movelast :: Name -> RunTactic
movelast n ctxt env t = do action (\ps -> let hs = holes ps in
                                              if n `elem` hs
                                                  then ps { holes = (hs \\ [n]) ++ [n] }
                                                  else ps)
                           return t

instanceArg :: Name -> RunTactic
instanceArg n ctxt env (Bind x (Hole t) sc)
    = do action (\ps -> let hs = holes ps
                            is = instances ps in
                            ps { holes = (hs \\ [x]) ++ [x],
                                 instances = x:is })
         return (Bind x (Hole t) sc)

setinj :: Name -> RunTactic
setinj n ctxt env (Bind x b sc)
    = do action (\ps -> let is = injective ps in
                            ps { injective = n : is })
         return (Bind x b sc)

defer :: Name -> RunTactic
defer n ctxt env (Bind x (Hole t) (P nt x' ty)) | x == x' =
    do action (\ps -> let hs = holes ps in
                          ps { holes = hs \\ [x] })
       return (Bind n (GHole (length env) (mkTy (reverse env) t))
                      (mkApp (P Ref n ty) (map getP (reverse env))))
  where
    mkTy []           t = t
    mkTy ((n,b) : bs) t = Bind n (Pi (binderTy b)) (mkTy bs t)

    getP (n, b) = P Bound n (binderTy b)

-- as defer, but build the type and application explicitly
deferType :: Name -> Raw -> [Name] -> RunTactic
deferType n fty_in args ctxt env (Bind x (Hole t) (P nt x' ty)) | x == x' =
    do (fty, _) <- lift $ check ctxt env fty_in
       action (\ps -> let hs = holes ps
                          ds = deferred ps in
                          ps { holes = hs \\ [x],
                               deferred = n : ds })
       return (Bind n (GHole 0 fty)
                      (mkApp (P Ref n ty) (map getP args)))
  where
    getP n = case lookup n env of
                  Just b -> P Bound n (binderTy b)
                  Nothing -> error ("deferType can't find " ++ show n)

regret :: RunTactic
regret ctxt env (Bind x (Hole t) sc) | noOccurrence x sc = 
    do action (\ps -> let hs = holes ps in
                          ps { holes = hs \\ [x] })
       return sc
regret ctxt env (Bind x (Hole t) _)
    = fail $ show x ++ " : " ++ show t ++ " is not solved..."

exact :: Raw -> RunTactic
exact guess ctxt env (Bind x (Hole ty) sc) =
    do (val, valty) <- lift $ check ctxt env guess
       lift $ converts ctxt env valty ty
       return $ Bind x (Guess ty val) sc
exact _ _ _ _ = fail "Can't fill here."

-- As exact, but attempts to solve other goals by unification

fill :: Raw -> RunTactic
fill guess ctxt env (Bind x (Hole ty) sc) =
    do (val, valty) <- lift $ check ctxt env guess
--        let valtyn = normalise ctxt env valty
--        let tyn = normalise ctxt env ty
       ns <- unify' ctxt env valty ty
       ps <- get
       let (uh, uns) = unified ps
--        put (ps { unified = (uh, uns ++ ns) })
--        addLog (show (uh, uns ++ ns))
       return $ Bind x (Guess ty val) sc
fill _ _ _ _ = fail "Can't fill here."

-- As fill, but attempts to solve other goals by matching

match_fill :: Raw -> RunTactic
match_fill guess ctxt env (Bind x (Hole ty) sc) =
    do (val, valty) <- lift $ check ctxt env guess
--        let valtyn = normalise ctxt env valty
--        let tyn = normalise ctxt env ty
       ns <- match_unify' ctxt env valty ty
       ps <- get
       let (uh, uns) = unified ps
--        put (ps { unified = (uh, uns ++ ns) })
--        addLog (show (uh, uns ++ ns))
       return $ Bind x (Guess ty val) sc
match_fill _ _ _ _ = fail "Can't fill here."

prep_fill :: Name -> [Name] -> RunTactic
prep_fill f as ctxt env (Bind x (Hole ty) sc) =
    do let val = mkApp (P Ref f Erased) (map (\n -> P Ref n Erased) as)
       return $ Bind x (Guess ty val) sc
prep_fill f as ctxt env t = fail $ "Can't prepare fill at " ++ show t

complete_fill :: RunTactic
complete_fill ctxt env (Bind x (Guess ty val) sc) =
    do let guess = forget val
       (val', valty) <- lift $ check ctxt env guess
       ns <- unify' ctxt env valty ty
       ps <- get
       let (uh, uns) = unified ps
--        put (ps { unified = (uh, uns ++ ns) })
       return $ Bind x (Guess ty val) sc
complete_fill ctxt env t = fail $ "Can't complete fill at " ++ show t

-- When solving something in the 'dont unify' set, we should check
-- that the guess we are solving it with unifies with the thing unification
-- found for it, if anything.

solve :: RunTactic
solve ctxt env (Bind x (Guess ty val) sc)
   = do ps <- get
        let (uh, uns) = unified ps
        case lookup x (notunified ps) of
            Just tm -> match_unify' ctxt env tm val
            _ -> return []
        action (\ps -> ps { holes = holes ps \\ [x],
                            solved = Just (x, val),
                            notunified = updateNotunified [(x,val)]
                                           (notunified ps),
                            instances = instances ps \\ [x] })
        let tm' = subst x val sc in 
            return tm'
solve _ _ h@(Bind x t sc)
   = do ps <- get
        case findType x sc of
             Just t -> lift $ tfail (CantInferType (show t))
             _ -> fail $ "Not a guess " ++ show h ++ "\n" ++ show (holes ps, pterm ps)
   where findType x (Bind n (Let t v) sc)
              = findType x v `mplus` findType x sc
         findType x (Bind n t sc) 
              | P _ x' _ <- binderTy t, x == x' = Just n
              | otherwise = findType x sc
         findType x _ = Nothing

introTy :: Raw -> Maybe Name -> RunTactic
introTy ty mn ctxt env (Bind x (Hole t) (P _ x' _)) | x == x' =
    do let n = case mn of
                  Just name -> name
                  Nothing -> x
       let t' = case t of
                    x@(Bind y (Pi s) _) -> x
                    _ -> hnf ctxt env t
       (tyv, tyt) <- lift $ check ctxt env ty
--        ns <- lift $ unify ctxt env tyv t'
       case t' of
           Bind y (Pi s) t -> let t' = subst y (P Bound n s) t in
                                  do ns <- unify' ctxt env s tyv
                                     ps <- get
                                     let (uh, uns) = unified ps
--                                      put (ps { unified = (uh, uns ++ ns) })
                                     return $ Bind n (Lam tyv) (Bind x (Hole t') (P Bound x t'))
           _ -> lift $ tfail $ CantIntroduce t'
introTy ty n ctxt env _ = fail "Can't introduce here."

intro :: Maybe Name -> RunTactic
intro mn ctxt env (Bind x (Hole t) (P _ x' _)) | x == x' =
    do let n = case mn of
                  Just name -> name
                  Nothing -> x
       let t' = case t of
                    x@(Bind y (Pi s) _) -> x
                    _ -> hnf ctxt env t
       case t' of
           Bind y (Pi s) t -> -- trace ("in type " ++ show t') $
               let t' = subst y (P Bound n s) t in
                   return $ Bind n (Lam s) (Bind x (Hole t') (P Bound x t'))
           _ -> lift $ tfail $ CantIntroduce t'
intro n ctxt env _ = fail "Can't introduce here."

forall :: Name -> Raw -> RunTactic
forall n ty ctxt env (Bind x (Hole t) (P _ x' _)) | x == x' =
    do (tyv, tyt) <- lift $ check ctxt env ty
       unify' ctxt env tyt (TType (UVar 0))
       unify' ctxt env t (TType (UVar 0))
       return $ Bind n (Pi tyv) (Bind x (Hole t) (P Bound x t))
forall n ty ctxt env _ = fail "Can't pi bind here"

patvar :: Name -> RunTactic
patvar n ctxt env (Bind x (Hole t) sc) =
    do action (\ps -> ps { holes = holes ps \\ [x],
                           notunified = updateNotunified [(x,P Bound n t)]
                                          (notunified ps),
                           injective = addInj n x (injective ps) })
       return $ Bind n (PVar t) (subst x (P Bound n t) sc)
  where addInj n x ps | x `elem` ps = n : ps
                      | otherwise = ps
patvar n ctxt env tm = fail $ "Can't add pattern var at " ++ show tm

letbind :: Name -> Raw -> Raw -> RunTactic
letbind n ty val ctxt env (Bind x (Hole t) (P _ x' _)) | x == x' =
    do (tyv,  tyt)  <- lift $ check ctxt env ty
       (valv, valt) <- lift $ check ctxt env val
       lift $ isType ctxt env tyt
       return $ Bind n (Let tyv valv) (Bind x (Hole t) (P Bound x t))
letbind n ty val ctxt env _ = fail "Can't let bind here"

expandLet :: Name -> Term -> RunTactic
expandLet n v ctxt env tm =
       return $ subst n v tm

rewrite :: Raw -> RunTactic
rewrite tm ctxt env (Bind x (Hole t) xp@(P _ x' _)) | x == x' =
    do (tmv, tmt) <- lift $ check ctxt env tm
       let tmt' = normalise ctxt env tmt
       case unApply tmt' of
         (P _ (UN q) _, [lt,rt,l,r]) | q == txt "=" ->
            do let p = Bind rname (Lam lt) (mkP (P Bound rname lt) r l t)
               let newt = mkP l r l t
               let sc = forget $ (Bind x (Hole newt)
                                       (mkApp (P Ref (sUN "replace") (TType (UVal 0)))
                                              [lt, l, r, p, tmv, xp]))
               (scv, sct) <- lift $ check ctxt env sc
               return scv
         _ -> lift $ tfail (NotEquality tmv tmt') 
  where rname = sMN 0 "replaced"
rewrite _ _ _ _ = fail "Can't rewrite here"

-- To make the P for rewrite, replace syntactic occurrences of l in ty with
-- an x, and put \x : lt in front
mkP :: TT Name -> TT Name -> TT Name -> TT Name -> TT Name
mkP lt l r ty | l == ty = lt
mkP lt l r (App f a) = let f' = if (r /= f) then mkP lt l r f else f
                           a' = if (r /= a) then mkP lt l r a else a in
                           App f' a'
mkP lt l r (Bind n b sc)
                     = let b' = mkPB b
                           sc' = if (r /= sc) then mkP lt l r sc else sc in
                           Bind n b' sc'
    where mkPB (Let t v) = let t' = if (r /= t) then mkP lt l r t else t
                               v' = if (r /= v) then mkP lt l r v else v in
                               Let t' v'
          mkPB b = let ty = binderTy b
                       ty' = if (r /= ty) then mkP lt l r ty else ty in
                             b { binderTy = ty' }
mkP lt l r x = x

induction :: Name -> RunTactic
induction nm ctxt env (Bind x (Hole t) (P _ x' _)) | x == x' = do
  (tmv, tmt) <- lift $ check ctxt env (Var nm)
  let tmt' = normalise ctxt env tmt
  case unApply tmt' of
    (P _ tnm _, tyargs) -> do
        case lookupTy (SN (ElimN tnm)) ctxt of
          [elimTy] -> do
             param_pos <- case lookupMetaInformation tnm ctxt of
                               [DataMI param_pos] -> return param_pos
                               m | length tyargs > 0 -> fail $ "Invalid meta information for " ++ show tnm ++ " where the metainformation is " ++ show m ++ " and definition is" ++ show (lookupDef tnm ctxt)
                               _ -> return []
             let (params, indicies) = splitTyArgs param_pos tyargs
             let args     = getArgTys elimTy
             let pmargs   = take (length params) args
             let args'    = drop (length params) args
             let propTy   = head args'
             let restargs = init $ tail args'
             let consargs = take (length restargs - length indicies) $ restargs
             let indxargs = drop (length restargs - length indicies) $ restargs
             let scr      = last $ tail args'
             let indxnames = makeIndexNames indicies
             prop <- replaceIndicies indxnames indicies $ Bind nm (Lam tmt') t
             let res = flip (foldr substV) params $ (substV prop $ bindConsArgs consargs (mkApp (P Ref (SN (ElimN tnm)) (TType (UVal 0)))
                                                        (params ++ [prop] ++ map makeConsArg consargs ++ indicies ++ [tmv])))
             action (\ps -> ps {holes = holes ps \\ [x]})
             mapM_ addConsHole (reverse consargs)
             let res' = forget $ res
             (scv, sct) <- lift $ check ctxt env res'
             let scv' = specialise ctxt env [] scv
             return scv'
          [] -> fail $ "Induction needs an eliminator for " ++ show tnm
          xs -> fail $ "Multiple definitions found when searching for the eliminator of " ++ show tnm
    _ -> fail "Unkown type for induction"
    where scname = sMN 0 "scarg"
          makeConsArg (nm, ty) = P Bound nm ty
          bindConsArgs ((nm, ty):args) v = Bind nm (Hole ty) $ bindConsArgs args v
          bindConsArgs [] v = v
          addConsHole (nm, ty) =
            action (\ps -> ps { holes = nm : holes ps })
          splitTyArgs param_pos tyargs =
            let (params, indicies) = partition (flip elem param_pos . fst) . zip [0..] $ tyargs
            in (map snd params, map snd indicies)
          makeIndexNames = foldr (\_ nms -> (uniqueNameCtxt ctxt (sMN 0 "idx") nms):nms) []
          replaceIndicies idnms idxs prop = foldM (\t (idnm, idx) -> do (idxv, idxt) <- lift $ check ctxt env (forget idx)
                                                                        let var = P Bound idnm idxt
                                                                        return $ Bind idnm (Lam idxt) (mkP var idxv var t)) prop $ zip idnms idxs
induction tm ctxt env _ = do fail "Can't do induction here"


equiv :: Raw -> RunTactic
equiv tm ctxt env (Bind x (Hole t) sc) =
    do (tmv, tmt) <- lift $ check ctxt env tm
       lift $ converts ctxt env tmv t
       return $ Bind x (Hole tmv) sc
equiv tm ctxt env _ = fail "Can't equiv here"

patbind :: Name -> RunTactic
patbind n ctxt env (Bind x (Hole t) (P _ x' _)) | x == x' =
    do let t' = case t of
                    x@(Bind y (PVTy s) t) -> x
                    _ -> hnf ctxt env t
       case t' of
           Bind y (PVTy s) t -> let t' = subst y (P Bound n s) t in
                                    return $ Bind n (PVar s) (Bind x (Hole t') (P Bound x t'))
           _ -> fail "Nothing to pattern bind"
patbind n ctxt env _ = fail "Can't pattern bind here"

compute :: RunTactic
compute ctxt env (Bind x (Hole ty) sc) =
    do return $ Bind x (Hole (normalise ctxt env ty)) sc
compute ctxt env t = return t

hnf_compute :: RunTactic
hnf_compute ctxt env (Bind x (Hole ty) sc) =
    do let ty' = hnf ctxt env ty in
--          trace ("HNF " ++ show (ty, ty')) $
           return $ Bind x (Hole ty') sc
hnf_compute ctxt env t = return t

-- reduce let bindings only
simplify :: RunTactic
simplify ctxt env (Bind x (Hole ty) sc) =
    do return $ Bind x (Hole (specialise ctxt env [] ty)) sc
simplify ctxt env t = return t

check_in :: Raw -> RunTactic
check_in t ctxt env tm =
    do (val, valty) <- lift $ check ctxt env t
       addLog (showEnv env val ++ " : " ++ showEnv env valty)
       return tm

eval_in :: Raw -> RunTactic
eval_in t ctxt env tm =
    do (val, valty) <- lift $ check ctxt env t
       let val' = normalise ctxt env val
       let valty' = normalise ctxt env valty
       addLog (showEnv env val ++ " : " ++
               showEnv env valty ++
--                     " in " ++ show env ++
               " ==>\n " ++
               showEnv env val' ++ " : " ++
               showEnv env valty')
       return tm

start_unify :: Name -> RunTactic
start_unify n ctxt env tm = do -- action (\ps -> ps { unified = (n, []) })
                               return tm

tmap f (a, b, c) = (f a, b, c)

solve_unified :: RunTactic
solve_unified ctxt env tm =
    do ps <- get
       let (_, ns) = unified ps
       let unify = dropGiven (dontunify ps) ns (holes ps)
       action (\ps -> ps { holes = holes ps \\ map fst unify })
       action (\ps -> ps { pterm = updateSolved unify (pterm ps) })
       return (updateSolved unify tm)

dropGiven du [] hs = []
dropGiven du ((n, P Bound t ty) : us) hs
   | n `elem` du && not (t `elem` du)
     && n `elem` hs && t `elem` hs
            = (t, P Bound n ty) : dropGiven du us hs
dropGiven du (u@(n, _) : us) hs
   | n `elem` du = dropGiven du us hs
-- dropGiven du (u@(_, P a n ty) : us) | n `elem` du = dropGiven du us
dropGiven du (u : us) hs = u : dropGiven du us hs

keepGiven du [] hs = []
keepGiven du ((n, P Bound t ty) : us) hs
   | n `elem` du && not (t `elem` du)
     && n `elem` hs && t `elem` hs
            = keepGiven du us hs
keepGiven du (u@(n, _) : us) hs
   | n `elem` du = u : keepGiven du us hs
keepGiven du (u : us) hs = keepGiven du us hs

updateSolved xs x = updateSolved' xs x
updateSolved' [] x = x
updateSolved' xs (Bind n (Hole ty) t)
    | Just v <- lookup n xs 
        = case xs of
               [_] -> psubst n v t
               _ -> psubst n v (updateSolved' xs t)
updateSolved' xs (Bind n b t)
    | otherwise = Bind n (fmap (updateSolved' xs) b) (updateSolved' xs t)
updateSolved' xs (App f a) 
    = App (updateSolved' xs f) (updateSolved' xs a)
updateSolved' xs (P _ n@(MN _ _) _)
    | Just v <- lookup n xs = v
updateSolved' xs t = t

updateEnv [] e = e
updateEnv ns [] = []
updateEnv ns ((n, b) : env) = (n, fmap (updateSolved ns) b) : updateEnv ns env

updateError [] err = err
updateError ns (CantUnify b l r e xs sc)
 = CantUnify b (updateSolved ns l) (updateSolved ns r) (updateError ns e) xs sc
updateError ns e = e

solveInProblems x val [] = []
solveInProblems x val ((l, r, env, err) : ps)
   = ((psubst x val l, psubst x val r, 
       updateEnv [(x, val)] env, err) : solveInProblems x val ps)

updateNotunified [] nu = nu
updateNotunified ns nu = up nu where
  up [] = []
  up ((n, t) : nus) = let t' = updateSolved ns t in
                          ((n, t') : up nus)

updateProblems ctxt [] ps inj holes = ([], ps)
updateProblems ctxt ns ps inj holes = up ns ps where
  up ns [] = (ns, [])
  up ns ((x, y, env, err, um) : ps) =
    let x' = updateSolved ns x
        y' = updateSolved ns y
        err' = updateError ns err
        env' = updateEnv ns env in
--         trace ("Updating " ++ show (x',y')) $ 
          case unify ctxt env' x' y' inj holes of
            OK (v, []) -> -- trace ("Added " ++ show v ++ " from " ++ show (x', y')) $
                               up (ns ++ v) ps
            e -> -- trace ("Failed " ++ show e) $
                  let (ns', ps') = up ns ps in
                     (ns', (x',y',env',err', um) : ps')

-- attempt to solve remaining problems with match_unify
matchProblems all ctxt ps inj holes = up [] ps where
  up ns [] = (ns, [])
  up ns ((x, y, env, err, um) : ps) 
       | all || um == Match =
    let x' = updateSolved ns x
        y' = updateSolved ns y
        err' = updateError ns err
        env' = updateEnv ns env in
        case match_unify ctxt env' x' y' inj holes of
            OK v -> -- trace ("Added " ++ show v ++ " from " ++ show (x', y')) $
                               up (ns ++ v) ps
            _ -> let (ns', ps') = up ns ps in
                     (ns', (x',y',env',err',um) : ps')
  up ns (p : ps) = let (ns', ps') = up ns ps in
                       (ns', p : ps')

processTactic :: Tactic -> ProofState -> TC (ProofState, String)
processTactic QED ps = case holes ps of
                           [] -> do let tm = {- normalise (context ps) [] -} (pterm ps)
                                    (tm', ty', _) <- recheck (context ps) [] (forget tm) tm
                                    return (ps { done = True, pterm = tm' },
                                            "Proof complete: " ++ showEnv [] tm')
                           _  -> fail "Still holes to fill."
processTactic ProofState ps = return (ps, showEnv [] (pterm ps))
processTactic Undo ps = case previous ps of
                            Nothing -> fail "Nothing to undo."
                            Just pold -> return (pold, "")
processTactic EndUnify ps
    = let (h, ns_in) = unified ps
          ns = dropGiven (dontunify ps) ns_in (holes ps)
          ns' = map (\ (n, t) -> (n, updateSolved ns t)) ns
          (ns'', probs') = updateProblems (context ps) ns' (problems ps)
                                          (injective ps) (holes ps)
          tm' = updateSolved ns'' (pterm ps) in
          return (ps { pterm = tm',
                       unified = (h, []),
                       problems = probs',
                       notunified = updateNotunified ns'' (notunified ps),
                       holes = holes ps \\ map fst ns'' }, "")
processTactic (Reorder n) ps
    = do ps' <- execStateT (tactic (Just n) reorder_claims) ps
         return (ps' { previous = Just ps, plog = "" }, plog ps')
processTactic (ComputeLet n) ps
    = return (ps { pterm = computeLet (context ps) n (pterm ps) }, "")
processTactic UnifyProblems ps
    = let (ns', probs') = updateProblems (context ps) []
                                         (problems ps)
                                         (injective ps)
                                         (holes ps)
          pterm' = updateSolved ns' (pterm ps) in
      return (ps { pterm = pterm', solved = Nothing, problems = probs',
                   previous = Just ps, plog = "",
                   notunified = updateNotunified ns' (notunified ps),
                   holes = holes ps \\ (map fst ns') }, plog ps)
processTactic (MatchProblems all) ps
    = let (ns', probs') = matchProblems all (context ps)
                                            (problems ps)
                                            (injective ps)
                                            (holes ps)
          pterm' = updateSolved ns' (pterm ps) in
      return (ps { pterm = pterm', solved = Nothing, problems = probs',
                   previous = Just ps, plog = "",
                   notunified = updateNotunified ns' (notunified ps),
                   holes = holes ps \\ (map fst ns') }, plog ps)
processTactic t ps
    = case holes ps of
        [] -> fail "Nothing to fill in."
        (h:_)  -> do ps' <- execStateT (process t h) ps
                     let (ns', probs')
                                = case solved ps' of
                                    Just s -> traceWhen (unifylog ps')
                                                ("SOLVED " ++ show s) $
                                               updateProblems (context ps')
                                                      [s] (problems ps')
                                                      (injective ps')
                                                      (holes ps')
                                    _ -> ([], problems ps')
                     -- rechecking problems may find more solutions, so
                     -- apply them here
                     let pterm'' = updateSolved ns' (pterm ps')
                     return (ps' { pterm = pterm'',
                                   solved = Nothing,
                                   problems = probs',
                                   notunified = updateNotunified ns' (notunified ps'),
                                   previous = Just ps, plog = "",
                                   holes = holes ps' \\ (map fst ns')}, plog ps')

process :: Tactic -> Name -> StateT TState TC ()
process EndUnify _
   = do ps <- get
        let (h, _) = unified ps
        tactic (Just h) solve_unified
process t h = tactic (Just h) (mktac t)
   where mktac Attack            = attack
         mktac (Claim n r)       = claim n r
         mktac (Exact r)         = exact r
         mktac (Fill r)          = fill r
         mktac (MatchFill r)     = match_fill r
         mktac (PrepFill n ns)   = prep_fill n ns
         mktac CompleteFill      = complete_fill
         mktac Regret            = regret
         mktac Solve             = solve
         mktac (StartUnify n)    = start_unify n
         mktac Compute           = compute
         mktac Simplify          = Idris.Core.ProofState.simplify
         mktac HNF_Compute       = hnf_compute
         mktac (Intro n)         = intro n
         mktac (IntroTy ty n)    = introTy ty n
         mktac (Forall n t)      = forall n t
         mktac (LetBind n t v)   = letbind n t v
         mktac (ExpandLet n b)   = expandLet n b
         mktac (Rewrite t)       = rewrite t
         mktac (Induction t)     = induction t
         mktac (Equiv t)         = equiv t
         mktac (PatVar n)        = patvar n
         mktac (PatBind n)       = patbind n
         mktac (CheckIn r)       = check_in r
         mktac (EvalIn r)        = eval_in r
         mktac (Focus n)         = focus n
         mktac (Defer n)         = defer n
         mktac (DeferType n t a) = deferType n t a
         mktac (Instance n)      = instanceArg n
         mktac (SetInjective n)  = setinj n
         mktac (MoveLast n)      = movelast n
