module Core.CaseBuilder

import Core.CaseTree
import Core.Context
import Core.Core
import Core.Env
import Core.Normalise
import Core.TT
import Core.Value

import Data.LengthMatch
import Data.List

import Decidable.Equality

%default covering

public export
data Phase = CompileTime RigCount | RunTime

Eq Phase where
  CompileTime r == CompileTime r' = r == r'
  RunTime == RunTime = True
  _ == _ = False

data ArgType : List Name -> Type where
     Known : RigCount -> (ty : Term vars) -> ArgType vars -- arg has type 'ty'
     Stuck : (fty : Term vars) -> ArgType vars
         -- ^ arg will have argument type of 'fty' when we know enough to
         -- calculate it
     Unknown : ArgType vars
         -- arg's type is not yet known due to a previously stuck argument

{ns : _} -> Show (ArgType ns) where
  show (Known c t) = "Known " ++ show c ++ " " ++ show t
  show (Stuck t) = "Stuck " ++ show t
  show Unknown = "Unknown"

record PatInfo (pvar : Name) (vars : List Name) where
  constructor MkInfo
  {idx : Nat}
  {name : Name}
  pat : Pat
  0 loc : IsVar name idx vars
  argType : ArgType vars -- Type of the argument being inspected (i.e.
                         -- *not* refined by this particular pattern)

{vars : _} -> Show (PatInfo n vars) where
  show pi = show (pat pi) ++ " : " ++ show (argType pi)

{-
NamedPats is a list of patterns on the LHS of a clause. Each entry in
the list gives a pattern, and a proof that there is a variable we can
inspect to see if it matches the pattern.

A definition consists of a list of clauses, which are a 'NamedPats' and
a term on the RHS. There is an assumption that corresponding positions in
NamedPats always have the same 'Elem' proof, though this isn't expressed in
a type anywhere.
-}

data NamedPats : List Name -> -- pattern variables still to process
                 List Name -> -- the pattern variables still to process,
                              -- in order
                 Type where
     Nil : NamedPats vars []
     (::) : PatInfo pvar vars ->
            -- ^ a pattern, where its variable appears in the vars list,
            -- and its type. The type has no variable names; any names it
            -- refers to are explicit
            NamedPats vars ns -> NamedPats vars (pvar :: ns)

getPatInfo : NamedPats vars todo -> List Pat
getPatInfo [] = []
getPatInfo (x :: xs) = pat x :: getPatInfo xs

updatePats : {vars, todo : _} ->
             {auto c : Ref Ctxt Defs} ->
             Env Term vars ->
             NF vars -> NamedPats vars todo -> Core (NamedPats vars todo)
updatePats env nf [] = pure []
updatePats {todo = pvar :: ns} env (NBind fc _ (Pi c _ farg) fsc) (p :: ps)
  = case argType p of
         Unknown =>
            do defs <- get Ctxt
               empty <- clearDefs defs
               pure (record { argType = Known c !(quote empty env farg) } p
                          :: !(updatePats env !(fsc defs (toClosure defaultOpts env (Ref fc Bound pvar))) ps))
         _ => pure (p :: ps)
updatePats env nf (p :: ps)
  = case argType p of
         Unknown =>
            do defs <- get Ctxt
               empty <- clearDefs defs
               pure (record { argType = Stuck !(quote empty env nf) } p :: ps)
         _ => pure (p :: ps)

substInPatInfo : {pvar, vars, todo : _} ->
                 {auto c : Ref Ctxt Defs} ->
                 FC -> Name -> Term vars -> PatInfo pvar vars ->
                 NamedPats vars todo ->
                 Core (PatInfo pvar vars, NamedPats vars todo)
substInPatInfo {pvar} {vars} fc n tm p ps
    = case argType p of
           Known c ty => pure (record { argType = Known c (substName n tm ty) } p, ps)
           Stuck fty =>
             do defs <- get Ctxt
                empty <- clearDefs defs
                let env = mkEnv fc vars
                case !(nf defs env (substName n tm fty)) of
                     NBind pfc _ (Pi c _ farg) fsc =>
                       pure (record { argType = Known c !(quote empty env farg) } p,
                                 !(updatePats env
                                       !(fsc defs (toClosure defaultOpts env
                                             (Ref pfc Bound pvar))) ps))
                     _ => pure (p, ps)
           Unknown => pure (p, ps)

-- Substitute the name with a term in the pattern types, and reduce further
-- (this aims to resolve any 'Stuck' pattern types)
substInPats : {vars, todo : _} ->
              {auto c : Ref Ctxt Defs} ->
              FC -> Name -> Term vars -> NamedPats vars todo ->
              Core (NamedPats vars todo)
substInPats fc n tm [] = pure []
substInPats fc n tm (p :: ps)
    = do (p', ps') <- substInPatInfo fc n tm p ps
         pure (p' :: !(substInPats fc n tm ps'))

getPat : {idx : Nat} ->
         (0 el : IsVar name idx ps) -> NamedPats ns ps -> PatInfo name ns
getPat First (x :: xs) = x
getPat (Later p) (x :: xs) = getPat p xs

dropPat : {idx : Nat} ->
          (0 el : IsVar name idx ps) ->
          NamedPats ns ps -> NamedPats ns (dropVar ps el)
dropPat First (x :: xs) = xs
dropPat (Later p) (x :: xs) = x :: dropPat p xs

{vars : _} -> {todo : _} -> Show (NamedPats vars todo) where
  show xs = "[" ++ showAll xs ++ "]"
    where
      showAll : {vs, ts : _} -> NamedPats vs ts -> String
      showAll [] = ""
      showAll {ts = t :: _ } [x]
          = show t ++ " " ++ show (pat x) ++ " [" ++ show (argType x) ++ "]"
      showAll {ts = t :: _ } (x :: xs)
          = show t ++ " " ++ show (pat x) ++ " [" ++ show (argType x) ++ "]"
                     ++ ", " ++ showAll xs

Weaken ArgType where
  weaken (Known c ty) = Known c (weaken ty)
  weaken (Stuck fty) = Stuck (weaken fty)
  weaken Unknown = Unknown

Weaken (PatInfo p) where
  weaken (MkInfo p el fty) = MkInfo p (Later el) (weaken fty)

-- FIXME: perhaps 'vars' should be second argument so we can use Weaken interface
weaken : {x, vars : _} ->
         NamedPats vars todo -> NamedPats (x :: vars) todo
weaken [] = []
weaken (p :: ps) = weaken p :: weaken ps

weakenNs : {vars : _} ->
           (ns : List Name) ->
           NamedPats vars todo -> NamedPats (ns ++ vars) todo
weakenNs ns [] = []
weakenNs ns (p :: ps)
    = weakenNs ns p :: weakenNs ns ps

(++) : NamedPats vars ms -> NamedPats vars ns -> NamedPats vars (ms ++ ns)
(++) [] ys = ys
(++) (x :: xs) ys = x :: xs ++ ys

tail : NamedPats vars (p :: ps) -> NamedPats vars ps
tail (x :: xs) = xs

take : (as : List Name) -> NamedPats vars (as ++ bs) -> NamedPats vars as
take [] ps = []
take (x :: xs) (p :: ps) = p :: take xs ps

data PatClause : (vars : List Name) -> (todo : List Name) -> Type where
     MkPatClause : List Name -> -- names matched so far (from original lhs)
                   NamedPats vars todo ->
                   Int -> (rhs : Term vars) -> PatClause vars todo

getNPs : PatClause vars todo -> NamedPats vars todo
getNPs (MkPatClause _ lhs pid rhs) = lhs

{vars : _} -> {todo : _} -> Show (PatClause vars todo) where
  show (MkPatClause _ ps pid rhs)
     = show ps ++ " => " ++ show rhs

substInClause : {a, vars, todo : _} ->
                {auto c : Ref Ctxt Defs} ->
                FC -> PatClause vars (a :: todo) ->
                Core (PatClause vars (a :: todo))
substInClause {vars} {a} fc (MkPatClause pvars (MkInfo pat pprf fty :: pats) pid rhs)
    = do pats' <- substInPats fc a (mkTerm vars pat) pats
         pure (MkPatClause pvars (MkInfo pat pprf fty :: pats') pid rhs)

data Partitions : List (PatClause vars todo) -> Type where
     ConClauses : {todo, vars, ps : _} ->
                  (cs : List (PatClause vars todo)) ->
                  Partitions ps -> Partitions (cs ++ ps)
     VarClauses : {todo, vars, ps : _} ->
                  (vs : List (PatClause vars todo)) ->
                  Partitions ps -> Partitions (vs ++ ps)
     NoClauses : Partitions []

{ps : _} -> Show (Partitions ps) where
  show (ConClauses cs rest) = "CON " ++ show cs ++ ", " ++ show rest
  show (VarClauses vs rest) = "VAR " ++ show vs ++ ", " ++ show rest
  show NoClauses = "NONE"

data ClauseType = ConClause | VarClause

namesIn : List Name -> Pat -> Bool
namesIn pvars (PAs _ n p) = (n `elem` pvars) && namesIn pvars p
namesIn pvars (PCon _ _ _ _ ps) = all (namesIn pvars) ps
namesIn pvars (PTyCon _ _ _ ps) = all (namesIn pvars) ps
namesIn pvars (PArrow _ _ s t) = namesIn pvars s && namesIn pvars t
namesIn pvars (PDelay _ _ t p) = namesIn pvars t && namesIn pvars p
namesIn pvars (PLoc _ n) = n `elem` pvars
namesIn pvars _ = True

namesFrom : Pat -> List Name
namesFrom (PAs _ n p) = n :: namesFrom p
namesFrom (PCon _ _ _ _ ps) = concatMap namesFrom ps
namesFrom (PTyCon _ _ _ ps) = concatMap namesFrom ps
namesFrom (PArrow _ _ s t) = namesFrom s ++ namesFrom t
namesFrom (PDelay _ _ t p) = namesFrom t ++ namesFrom p
namesFrom (PLoc _ n) = [n]
namesFrom _ = []

clauseType : Phase -> PatClause vars (a :: as) -> ClauseType
-- If it's irrelevant, a constructor, and there's no names we haven't seen yet
-- and don't see later, treat it as a variable
-- Or, if we're compiling for runtime we won't be able to split on it, so
-- also treat it as a variable
clauseType phase (MkPatClause pvars (MkInfo arg _ ty :: rest) pid rhs)
    = getClauseType phase arg ty
  where
    -- used to get the remaining clause types
    clauseType' : Pat -> ClauseType
    clauseType' (PCon _ _ _ _ xs) = ConClause
    clauseType' (PTyCon _ _ _ xs) = ConClause
    clauseType' (PConst _ x)      = ConClause
    clauseType' (PArrow _ _ s t)  = ConClause
    clauseType' (PDelay _ _ _ _)  = ConClause
    clauseType' _                 = VarClause

    getClauseType : Phase -> Pat -> ArgType vars -> ClauseType
    getClauseType (CompileTime cr) (PCon _ _ _ _ xs) (Known r t)
        = if isErased r && not (isErased cr) &&
             all (namesIn (pvars ++ concatMap namesFrom (getPatInfo rest))) xs
             then VarClause
             else ConClause
    getClauseType phase (PAs _ _ p) t = getClauseType phase p t
    getClauseType phase l (Known r t) = if isErased r
      then VarClause
      else clauseType' l
    getClauseType phase l _ = clauseType' l

partition : {a, as, vars : _} ->
            Phase -> (ps : List (PatClause vars (a :: as))) -> Partitions ps
partition phase [] = NoClauses
partition phase (x :: xs) with (partition phase xs)
  partition phase (x :: (cs ++ ps)) | (ConClauses cs rest)
        = case clauseType phase x of
               ConClause => ConClauses (x :: cs) rest
               VarClause => VarClauses [x] (ConClauses cs rest)
  partition phase (x :: (vs ++ ps)) | (VarClauses vs rest)
        = case clauseType phase x of
               ConClause => ConClauses [x] (VarClauses vs rest)
               VarClause => VarClauses (x :: vs) rest
  partition phase (x :: []) | NoClauses
        = case clauseType phase x of
               ConClause => ConClauses [x] NoClauses
               VarClause => VarClauses [x] NoClauses

data ConType : Type where
     CName : Name -> (tag : Int) -> ConType
     CDelay : ConType
     CConst : Constant -> ConType

conTypeEq : (x, y : ConType) -> Maybe (x = y)
conTypeEq (CName x tag) (CName x' tag')
   = do Refl <- nameEq x x'
        case decEq tag tag' of
             Yes Refl => Just Refl
             No contra => Nothing
conTypeEq CDelay CDelay = Just Refl
conTypeEq (CConst x) (CConst y)
   = case constantEq x y of
          Nothing => Nothing
          Just Refl => Just Refl
conTypeEq _ _ = Nothing

data Group : List Name -> -- variables in scope
             List Name -> -- pattern variables still to process
             Type where
     ConGroup : {newargs : _} ->
                Name -> (tag : Int) ->
                List (PatClause (newargs ++ vars) (newargs ++ todo)) ->
                Group vars todo
     DelayGroup : {tyarg, valarg : _} ->
                  List (PatClause (tyarg :: valarg :: vars)
                                  (tyarg :: valarg :: todo)) ->
                  Group vars todo
     ConstGroup : Constant -> List (PatClause vars todo) ->
                  Group vars todo

{vars : _} -> {todo : _} -> Show (Group vars todo) where
  show (ConGroup c t cs) = "Con " ++ show c ++ ": " ++ show cs
  show (DelayGroup cs) = "Delay: " ++ show cs
  show (ConstGroup c cs) = "Const " ++ show c ++ ": " ++ show cs

data GroupMatch : ConType -> List Pat -> Group vars todo -> Type where
  ConMatch : LengthMatch ps newargs ->
             GroupMatch (CName n tag) ps
               (ConGroup {newargs} n tag (MkPatClause pvs pats pid rhs :: rest))
  DelayMatch : GroupMatch CDelay []
               (DelayGroup {tyarg} {valarg} (MkPatClause pvs pats pid rhs :: rest))
  ConstMatch : GroupMatch (CConst c) []
                  (ConstGroup c (MkPatClause pvs pats pid rhs :: rest))
  NoMatch : GroupMatch ct ps g

checkGroupMatch : (c : ConType) -> (ps : List Pat) -> (g : Group vars todo) ->
                  GroupMatch c ps g
checkGroupMatch (CName x tag) ps (ConGroup {newargs} x' tag' (MkPatClause pvs pats pid rhs :: rest))
    = case checkLengthMatch ps newargs of
           Nothing => NoMatch
           Just prf => case (nameEq x x', decEq tag tag') of
                            (Just Refl, Yes Refl) => ConMatch prf
                            _ => NoMatch
checkGroupMatch (CName x tag) ps _ = NoMatch
checkGroupMatch CDelay [] (DelayGroup (MkPatClause pvs pats pid rhs :: rest))
    = DelayMatch
checkGroupMatch (CConst c) [] (ConstGroup c' (MkPatClause pvs pats pid rhs :: rest))
    = case constantEq c c' of
           Nothing => NoMatch
           Just Refl => ConstMatch
checkGroupMatch _ _ _ = NoMatch

data PName : Type where

nextName : {auto i : Ref PName Int} ->
           String -> Core Name
nextName root
    = do x <- get PName
         put PName (x + 1)
         pure (MN root x)

nextNames : {vars : _} ->
            {auto i : Ref PName Int} ->
            {auto c : Ref Ctxt Defs} ->
            FC -> String -> List Pat -> Maybe (NF vars) ->
            Core (args ** NamedPats (args ++ vars) args)
nextNames fc root [] fty = pure ([] ** [])
nextNames {vars} fc root (p :: pats) fty
     = do defs <- get Ctxt
          empty <- clearDefs defs
          n <- nextName root
          let env = mkEnv fc vars
          fa_tys <- the (Core (Maybe (NF vars), ArgType vars)) $
              case fty of
                   Nothing => pure (Nothing, Unknown)
                   Just (NBind pfc _ (Pi c _ (NErased _ _)) fsc) =>
                      pure (Just !(fsc defs (toClosure defaultOpts env (Ref pfc Bound n))),
                        Unknown)
                   Just (NBind pfc _ (Pi c _ farg) fsc) =>
                      pure (Just !(fsc defs (toClosure defaultOpts env (Ref pfc Bound n))),
                        Known c !(quote empty env farg))
                   Just t =>
                      pure (Nothing, Stuck !(quote empty env t))
          (args ** ps) <- nextNames {vars} fc root pats (fst fa_tys)
          let argTy = case snd fa_tys of
                           Unknown => Unknown
                           Known rig t => Known rig (weakenNs (n :: args) t)
                           Stuck t => Stuck (weakenNs (n :: args) t)
          pure (n :: args ** MkInfo p First argTy :: weaken ps)

-- replace the prefix of patterns with 'pargs'
newPats : (pargs : List Pat) -> LengthMatch pargs ns ->
          NamedPats vars (ns ++ todo) ->
          NamedPats vars ns
newPats [] NilMatch rest = []
newPats (newpat :: xs) (ConsMatch w) (pi :: rest)
  = record { pat = newpat} pi :: newPats xs w rest

updateNames : List (Name, Pat) -> List (Name, Name)
updateNames = mapMaybe update
  where
    update : (Name, Pat) -> Maybe (Name, Name)
    update (n, PLoc fc p) = Just (p, n)
    update _ = Nothing

updatePatNames : List (Name, Name) -> NamedPats vars todo -> NamedPats vars todo
updatePatNames _ [] = []
updatePatNames ns (pi :: ps)
    = record { pat $= update } pi :: updatePatNames ns ps
  where
    update : Pat -> Pat
    update (PAs fc n p)
        = case lookup n ns of
               Nothing => PAs fc n (update p)
               Just n' => PAs fc n' (update p)
    update (PCon fc n i a ps) = PCon fc n i a (map update ps)
    update (PTyCon fc n a ps) = PTyCon fc n a (map update ps)
    update (PArrow fc x s t) = PArrow fc x (update s) (update t)
    update (PDelay fc r t p) = PDelay fc r (update t) (update p)
    update (PLoc fc n)
        = case lookup n ns of
               Nothing => PLoc fc n
               Just n' => PLoc fc n'
    update p = p

groupCons : {a, vars, todo : _} ->
            {auto i : Ref PName Int} ->
            {auto ct : Ref Ctxt Defs} ->
            FC -> Name ->
            List Name ->
            List (PatClause vars (a :: todo)) ->
            Core (List (Group vars todo))
groupCons fc fn pvars cs
     = gc [] cs
  where
    addConG : {vars', todo' : _} ->
              Name -> (tag : Int) ->
              List Pat -> NamedPats vars' todo' ->
              Int -> (rhs : Term vars') ->
              (acc : List (Group vars' todo')) ->
              Core (List (Group vars' todo'))
    -- Group all the clauses that begin with the same constructor, and
    -- add new pattern arguments for each of that constructor's arguments.
    -- The type of 'ConGroup' ensures that we refer to the arguments by
    -- the same name in each of the clauses
    addConG {vars'} {todo'} n tag pargs pats pid rhs []
        = do cty <- the (Core (NF vars')) $ if n == UN "->"
                      then pure $ NBind fc (MN "_" 0) (Pi top Explicit (NType fc)) $
                              (\d, a => pure $ NBind fc (MN "_" 1) (Pi top Explicit (NErased fc False))
                                (\d, a => pure $ NType fc))
                      else do defs <- get Ctxt
                              Just t <- lookupTyExact n (gamma defs)
                                   | Nothing => pure (NErased fc False)
                              nf defs (mkEnv fc vars') (embed t)
             (patnames ** newargs) <- nextNames {vars=vars'} fc "e" pargs (Just cty)
             -- Update non-linear names in remaining patterns (to keep
             -- explicit dependencies in types accurate)
             let pats' = updatePatNames (updateNames (zip patnames pargs))
                                        (weakenNs patnames pats)
             let clause = MkPatClause {todo = patnames ++ todo'}
                              pvars
                              (newargs ++ pats')
                              pid (weakenNs patnames rhs)
             pure [ConGroup n tag [clause]]
    addConG {vars'} {todo'} n tag pargs pats pid rhs (g :: gs) with (checkGroupMatch (CName n tag) pargs g)
      addConG {vars'} {todo'} n tag pargs pats pid rhs
              ((ConGroup {newargs} n tag ((MkPatClause pvars ps tid tm) :: rest)) :: gs)
                   | (ConMatch {newargs} lprf)
        = do let newps = newPats pargs lprf ps
             let pats' = updatePatNames (updateNames (zip newargs pargs))
                                        (weakenNs newargs pats)
             let newclause : PatClause (newargs ++ vars') (newargs ++ todo')
                   = MkPatClause pvars
                                 (newps ++ pats')
                                 pid
                                 (weakenNs newargs rhs)
             -- put the new clause at the end of the group, since we
             -- match the clauses top to bottom.
             pure ((ConGroup n tag (MkPatClause pvars ps tid tm :: rest ++ [newclause]))
                         :: gs)
      addConG n tag pargs pats pid rhs (g :: gs) | NoMatch
        = do gs' <- addConG n tag pargs pats pid rhs gs
             pure (g :: gs')

    -- This rather ugly special case is to deal with laziness, where Delay
    -- is like a constructor, but with a special meaning that it forces
    -- evaluation when case analysis reaches it (dealt with in the evaluator
    -- and compiler)
    addDelayG : {vars', todo' : _} ->
                Pat -> Pat -> NamedPats vars' todo' ->
                Int -> (rhs : Term vars') ->
                (acc : List (Group vars' todo')) ->
                Core (List (Group vars' todo'))
    addDelayG {vars'} {todo'} pty parg pats pid rhs []
        = do let dty = NBind fc (MN "a" 0) (Pi erased Explicit (NType fc)) $
                        (\d, a =>
                            do a' <- evalClosure d a
                               pure (NBind fc (MN "x" 0) (Pi top Explicit a')
                                       (\dv, av => pure (NDelayed fc LUnknown a'))))
             ([tyname, argname] ** newargs) <- nextNames {vars=vars'} fc "e" [pty, parg]
                                                  (Just dty)
                | _ => throw (InternalError "Error compiling Delay pattern match")
             let pats' = updatePatNames (updateNames [(tyname, pty),
                                                      (argname, parg)])
                                        (weakenNs [tyname, argname] pats)
             let clause = MkPatClause {todo = tyname :: argname :: todo'}
                             pvars (newargs ++  pats')
                                   pid (weakenNs [tyname, argname] rhs)
             pure [DelayGroup [clause]]
    addDelayG {vars'} {todo'} pty parg pats pid rhs (g :: gs) with (checkGroupMatch CDelay [] g)
      addDelayG {vars'} {todo'} pty parg pats pid rhs
          ((DelayGroup {tyarg} {valarg} ((MkPatClause pvars ps tid tm) :: rest)) :: gs)
                 | (DelayMatch {tyarg} {valarg})
         = do let newps = newPats [pty, parg] (ConsMatch (ConsMatch NilMatch)) ps
              let pats' = updatePatNames (updateNames [(tyarg, pty),
                                                       (valarg, parg)])
                                         (weakenNs [tyarg, valarg] pats)
              let newclause : PatClause (tyarg :: valarg :: vars')
                                        (tyarg :: valarg :: todo')
                    = MkPatClause pvars (newps ++ pats') pid
                                        (weakenNs [tyarg, valarg] rhs)
              pure ((DelayGroup (MkPatClause pvars ps tid tm :: rest ++ [newclause]))
                         :: gs)
      addDelayG pty parg pats pid rhs (g :: gs) | NoMatch
         = do gs' <- addDelayG pty parg pats pid rhs gs
              pure (g :: gs')

    addConstG : {vars', todo' : _} ->
                Constant -> NamedPats vars' todo' ->
                Int -> (rhs : Term vars') ->
                (acc : List (Group vars' todo')) ->
                Core (List (Group vars' todo'))
    addConstG c pats pid rhs []
        = pure [ConstGroup c [MkPatClause pvars pats pid rhs]]
    addConstG {todo'} {vars'} c pats pid rhs (g :: gs) with (checkGroupMatch (CConst c) [] g)
      addConstG {todo'} {vars'} c pats pid rhs
              ((ConstGroup c ((MkPatClause pvars ps tid tm) :: rest)) :: gs) | ConstMatch
          = let newclause : PatClause vars' todo'
                  = MkPatClause pvars pats pid rhs in
                pure ((ConstGroup c
                      (MkPatClause pvars ps tid tm :: rest ++ [newclause])) :: gs)
      addConstG c pats pid rhs (g :: gs) | NoMatch
          = do gs' <- addConstG c pats pid rhs gs
               pure (g :: gs')

    addGroup : {vars, todo, idx : _} ->
               Pat -> (0 p : IsVar name idx vars) ->
               NamedPats vars todo -> Int -> Term vars ->
               List (Group vars todo) ->
               Core (List (Group vars todo))
    -- In 'As' replace the name on the RHS with a reference to the
    -- variable we're doing the case split on
    addGroup (PAs fc n p) pprf pats pid rhs acc
         = addGroup p pprf pats pid (substName n (Local fc (Just True) _ pprf) rhs) acc
    addGroup (PCon cfc n t a pargs) pprf pats pid rhs acc
         = if a == length pargs
              then addConG n t pargs pats pid rhs acc
              else throw (CaseCompile cfc fn (NotFullyApplied n))
    addGroup (PTyCon _ n a pargs) pprf pats pid rhs acc
         = addConG n 0 pargs pats pid rhs acc
    addGroup (PArrow _ _ s t) pprf pats pid rhs acc
         = addConG (UN "->") 0 [s, t] pats pid rhs acc
    -- Go inside the delay; we'll flag the case as needing to force its
    -- scrutinee (need to check in 'caseGroups below)
    addGroup (PDelay _ _ pty parg) pprf pats pid rhs acc
         = addDelayG pty parg pats pid rhs acc
    addGroup (PConst _ c) pprf pats pid rhs acc
         = addConstG c pats pid rhs acc
    addGroup _ pprf pats pid rhs acc = pure acc -- Can't happen, not a constructor
--         -- FIXME: Is this possible to rule out with a type? Probably.

    gc : {a, vars, todo : _} ->
         List (Group vars todo) ->
         List (PatClause vars (a :: todo)) ->
         Core (List (Group vars todo))
    gc acc [] = pure acc
    gc {a} acc ((MkPatClause pvars (MkInfo pat pprf fty :: pats) pid rhs) :: cs)
        = do acc' <- addGroup pat pprf pats pid rhs acc
             gc acc' cs

getFirstPat : NamedPats ns (p :: ps) -> Pat
getFirstPat (p :: _) = pat p

getFirstArgType : NamedPats ns (p :: ps) -> ArgType ns
getFirstArgType (p :: _) = argType p

-- Check whether all the initial patterns have the same concrete, known
-- and matchable type, which is multiplicity > 0.
-- If so, it's okay to match on it
sameType : {ns : _} ->
           {auto i : Ref PName Int} ->
           {auto c : Ref Ctxt Defs} ->
           FC -> Phase -> Name ->
           Env Term ns -> List (NamedPats ns (p :: ps)) ->
           Core ()
sameType fc phase fn env [] = pure ()
sameType {ns} fc phase fn env (p :: xs)
    = do defs <- get Ctxt
         case getFirstArgType p of
              Known _ t => sameTypeAs phase
                                      !(nf defs env t)
                                      (map getFirstArgType xs)
              ty => throw (CaseCompile fc fn DifferingTypes)
  where
    firstPat : NamedPats ns (np :: nps) -> Pat
    firstPat (pinf :: _) = pat pinf

    headEq : NF ns -> NF ns -> Phase -> Bool
    headEq (NBind _ _ (Pi _ _ _) _) (NBind _ _ (Pi _ _ _) _) _ = True
    headEq (NTCon _ n _ _ _) (NTCon _ n' _ _ _) _ = n == n'
    headEq (NPrimVal _ c) (NPrimVal _ c') _ = c == c'
    headEq (NType _) (NType _) _ = True
    headEq (NApp _ (NRef _ n) _) (NApp _ (NRef _ n') _) RunTime = n == n'
    headEq (NErased _ _) _ RunTime = True
    headEq _ (NErased _ _) RunTime = True
    headEq _ _ _ = False

    sameTypeAs : Phase -> NF ns -> List (ArgType ns) -> Core ()
    sameTypeAs _ ty [] = pure ()
    sameTypeAs ph ty (Known r t :: xs) =
         do defs <- get Ctxt
            if headEq ty !(nf defs env t) phase
               then sameTypeAs ph ty xs
               else throw (CaseCompile fc fn DifferingTypes)
    sameTypeAs p ty _ = throw (CaseCompile fc fn DifferingTypes)

-- Check whether all the initial patterns are the same, or are all a variable.
-- If so, we'll match it to refine later types and move on
samePat : List (NamedPats ns (p :: ps)) -> Bool
samePat [] = True
samePat (pi :: xs)
    = samePatAs (dropAs (getFirstPat pi))
                        (map (dropAs . getFirstPat) xs)
  where
    dropAs : Pat -> Pat
    dropAs (PAs _ _ p) = p
    dropAs p = p

    samePatAs : Pat -> List Pat -> Bool
    samePatAs p [] = True
    samePatAs (PTyCon fc n a args) (PTyCon _ n' _ _ :: ps)
        = n == n' && samePatAs (PTyCon fc n a args) ps
    samePatAs (PCon fc n t a args) (PCon _ n' t' _ _ :: ps)
        = n == n' && t == t' && samePatAs (PCon fc n t a args) ps
    samePatAs (PConst fc c) (PConst _ c' :: ps)
        = c == c' && samePatAs (PConst fc c) ps
    samePatAs (PArrow fc x s t) (PArrow _ _ s' t' :: ps)
        = samePatAs (PArrow fc x s t) ps
    samePatAs (PDelay fc r t p) (PDelay _ _ _ _ :: ps)
        = samePatAs (PDelay fc r t p) ps
    samePatAs (PLoc fc n) (PLoc _ _ :: ps) = samePatAs (PLoc fc n) ps
    samePatAs x y = False

getFirstCon : NamedPats ns (p :: ps) -> Pat
getFirstCon (p :: _) = pat p

-- Count the number of distinct constructors in the initial pattern
countDiff : List (NamedPats ns (p :: ps)) -> Nat
countDiff xs = length (distinct [] (map getFirstCon xs))
  where
    isVar : Pat -> Bool
    isVar (PAs _ _ p) = isVar p
    isVar (PCon _ _ _ _ _) = False
    isVar (PTyCon _ _ _ _) = False
    isVar (PConst _ _) = False
    isVar (PArrow _ _ _ _) = False
    isVar (PDelay _ _ _ p) = False
    isVar _ = True

    -- Return whether two patterns would lead to the same match
    sameCase : Pat -> Pat -> Bool
    sameCase (PAs _ _ p) p' = sameCase p p'
    sameCase p (PAs _ _ p') = sameCase p p'
    sameCase (PCon _ _ t _ _) (PCon _ _ t' _ _) = t == t'
    sameCase (PTyCon _ t _ _) (PTyCon _ t' _ _) = t == t'
    sameCase (PConst _ c) (PConst _ c') = c == c'
    sameCase (PArrow _ _ _ _) (PArrow _ _ _ _) = True
    sameCase (PDelay _ _ _ _) (PDelay _ _ _ _) = True
    sameCase x y = isVar x && isVar y

    distinct : List Pat -> List Pat -> List Pat
    distinct acc [] = acc
    distinct acc (p :: ps)
       = if elemBy sameCase p acc
            then distinct acc ps
            else distinct (p :: acc) ps

getScore : {ns : _} ->
           {auto i : Ref PName Int} ->
           {auto c : Ref Ctxt Defs} ->
           FC -> Phase -> Name ->
           List (NamedPats ns (p :: ps)) ->
           Core (Either CaseError ())
getScore fc phase name npss
    = do catch (do sameType fc phase name (mkEnv fc ns) npss
                   pure (Right ()))
               (\err => case err of
                             CaseCompile _ _ err => pure (Left err)
                             _ => throw err)

-- Pick the leftmost matchable thing with all constructors in the
-- same family, or all variables, or all the same type constructor.
pickNext : {p, ns, ps : _} ->
           {auto i : Ref PName Int} ->
           {auto c : Ref Ctxt Defs} ->
           FC -> Phase -> Name -> List (NamedPats ns (p :: ps)) ->
           Core (n ** NVar n (p :: ps))
-- last possible variable
pickNext {ps = []} fc phase fn npss
    = if samePat npss
         then pure (_ ** MkNVar First)
         else do Right () <- getScore fc phase fn npss
                       | Left err => throw (CaseCompile fc fn err)
                 pure (_ ** MkNVar First)
pickNext {ps = q :: qs} fc phase fn npss
    = if samePat npss
         then pure (_ ** MkNVar First)
         else  case !(getScore fc phase fn npss) of
                    Right () => pure (_ ** MkNVar First)
                    _ => do (_ ** MkNVar var) <- pickNext fc phase fn (map tail npss)
                            pure (_ ** MkNVar (Later var))

moveFirst : {idx : Nat} -> (0 el : IsVar name idx ps) -> NamedPats ns ps ->
            NamedPats ns (name :: dropVar ps el)
moveFirst el nps = getPat el nps :: dropPat el nps

shuffleVars : {idx : Nat} -> (0 el : IsVar name idx todo) -> PatClause vars todo ->
              PatClause vars (name :: dropVar todo el)
shuffleVars el (MkPatClause pvars lhs pid rhs)
    = MkPatClause pvars (moveFirst el lhs) pid rhs

mutual
  {- 'PatClause' contains a list of patterns still to process (that's the
     "todo") and a right hand side with the variables we know about "vars".
     So "match" builds the remainder of the case tree for
     the unprocessed patterns. "err" is the tree for when the patterns don't
     cover the input (i.e. the "fallthrough" pattern, which at the top
     level will be an error). -}
  match : {vars, todo : _} ->
          {auto i : Ref PName Int} ->
          {auto c : Ref Ctxt Defs} ->
          FC -> Name -> Phase ->
          List (PatClause vars todo) -> (err : Maybe (CaseTree vars)) ->
          Core (CaseTree vars)
  -- Before 'partition', reorder the arguments so that the one we
  -- inspect next has a concrete type that is the same in all cases, and
  -- has the most distinct constructors (via pickNext)
  match {todo = (_ :: _)} fc fn phase clauses err
      = do (n ** MkNVar next) <- pickNext fc phase fn (map getNPs clauses)
           let clauses' = map (shuffleVars next) clauses
           let ps = partition phase clauses'
           maybe (pure (Unmatched "No clauses"))
                 Core.pure
                !(mixture fc fn phase ps err)
  match {todo = []} fc fn phase [] err
       = maybe (pure (Unmatched "No patterns"))
               pure err
  match {todo = []} fc fn phase ((MkPatClause pvars [] pid (Erased _ True)) :: _) err
       = pure Impossible
  match {todo = []} fc fn phase ((MkPatClause pvars [] pid rhs) :: _) err
       = pure $ STerm pid rhs

  caseGroups : {pvar, vars, todo : _} ->
               {auto i : Ref PName Int} ->
               {auto c : Ref Ctxt Defs} ->
               FC -> Name -> Phase ->
               {idx : Nat} -> (0 p : IsVar pvar idx vars) -> Term vars ->
               List (Group vars todo) -> Maybe (CaseTree vars) ->
               Core (CaseTree vars)
  caseGroups {vars} fc fn phase el ty gs errorCase
      = do g <- altGroups gs
           pure (Case _ el (resolveNames vars ty) g)
    where
      altGroups : List (Group vars todo) -> Core (List (CaseAlt vars))
      altGroups [] = maybe (pure [])
                           (\e => pure [DefaultCase e])
                           errorCase
      altGroups (ConGroup {newargs} cn tag rest :: cs)
          = do crest <- match fc fn phase rest (map (weakenNs newargs) errorCase)
               cs' <- altGroups cs
               pure (ConCase cn tag newargs crest :: cs')
      altGroups (DelayGroup {tyarg} {valarg} rest :: cs)
          = do crest <- match fc fn phase rest (map (weakenNs [tyarg, valarg]) errorCase)
               cs' <- altGroups cs
               pure (DelayCase tyarg valarg crest :: cs')
      altGroups (ConstGroup c rest :: cs)
          = do crest <- match fc fn phase rest errorCase
               cs' <- altGroups cs
               pure (ConstCase c crest :: cs')

  conRule : {a, vars, todo : _} ->
            {auto i : Ref PName Int} ->
            {auto c : Ref Ctxt Defs} ->
            FC -> Name -> Phase ->
            List (PatClause vars (a :: todo)) ->
            Maybe (CaseTree vars) ->
            Core (CaseTree vars)
  conRule fc fn phase [] err = maybe (pure (Unmatched "No constructor clauses")) pure err
  -- ASSUMPTION, not expressed in the type, that the patterns all have
  -- the same variable (pprf) for the first argument. If not, the result
  -- will be a broken case tree... so we should find a way to express this
  -- in the type if we can.
  conRule {a} fc fn phase cs@(MkPatClause pvars (MkInfo pat pprf fty :: pats) pid rhs :: rest) err
      = do refinedcs <- traverse (substInClause fc) cs
           groups <- groupCons fc fn pvars refinedcs
           ty <- case fty of
                      Known _ t => pure t
                      _ => throw (CaseCompile fc fn UnknownType)
           caseGroups fc fn phase pprf ty groups err

  varRule : {a, vars, todo : _} ->
            {auto i : Ref PName Int} ->
            {auto c : Ref Ctxt Defs} ->
            FC -> Name -> Phase ->
            List (PatClause vars (a :: todo)) ->
            Maybe (CaseTree vars) ->
            Core (CaseTree vars)
  varRule {vars} {a} fc fn phase cs err
      = do alts' <- traverse updateVar cs
           match fc fn phase alts' err
    where
      updateVar : PatClause vars (a :: todo) -> Core (PatClause vars todo)
      -- replace the name with the relevant variable on the rhs
      updateVar (MkPatClause pvars (MkInfo (PLoc pfc n) prf fty :: pats) pid rhs)
          = pure $ MkPatClause (n :: pvars)
                        !(substInPats fc a (Local pfc (Just False) _ prf) pats)
                        pid (substName n (Local pfc (Just False) _ prf) rhs)
      -- If it's an as pattern, replace the name with the relevant variable on
      -- the rhs then continue with the inner pattern
      updateVar (MkPatClause pvars (MkInfo (PAs pfc n pat) prf fty :: pats) pid rhs)
          = do pats' <- substInPats fc a (mkTerm _ pat) pats
               let rhs' = substName n (Local pfc (Just True) _ prf) rhs
               updateVar (MkPatClause pvars (MkInfo pat prf fty :: pats') pid rhs')
      -- match anything, name won't appear in rhs but need to update
      -- LHS pattern types based on what we've learned
      updateVar (MkPatClause pvars (MkInfo pat prf fty :: pats) pid rhs)
          = pure $ MkPatClause pvars
                        !(substInPats fc a (mkTerm vars pat) pats) pid rhs

  mixture : {a, vars, todo : _} ->
            {auto i : Ref PName Int} ->
            {auto c : Ref Ctxt Defs} ->
            {ps : List (PatClause vars (a :: todo))} ->
            FC -> Name -> Phase ->
            Partitions ps ->
            Maybe (CaseTree vars) ->
            Core (Maybe (CaseTree vars))
  mixture fc fn phase (ConClauses cs rest) err
      = do fallthrough <- mixture fc fn phase rest err
           pure (Just !(conRule fc fn phase cs fallthrough))
  mixture fc fn phase (VarClauses vs rest) err
      = do fallthrough <- mixture fc fn phase rest err
           pure (Just !(varRule fc fn phase vs fallthrough))
  mixture fc fn {a} {todo} phase NoClauses err
      = pure err

mkPatClause : {auto c : Ref Ctxt Defs} ->
              FC -> Name ->
              (args : List Name) -> ClosedTerm ->
              Int -> (List Pat, ClosedTerm) ->
              Core (PatClause args args)
mkPatClause fc fn args ty pid (ps, rhs)
    = maybe (throw (CaseCompile fc fn DifferingArgNumbers))
            (\eq =>
               do defs <- get Ctxt
                  nty <- nf defs [] ty
                  ns <- mkNames args ps eq (Just nty)
                  pure (MkPatClause [] ns pid
                          (rewrite sym (appendNilRightNeutral args) in
                                   (weakenNs args rhs))))
            (checkLengthMatch args ps)
  where
    mkNames : (vars : List Name) -> (ps : List Pat) ->
              LengthMatch vars ps -> Maybe (NF []) ->
              Core (NamedPats vars vars)
    mkNames [] [] NilMatch fty = pure []
    mkNames (arg :: args) (p :: ps) (ConsMatch eq) fty
        = do defs <- get Ctxt
             empty <- clearDefs defs
             fa_tys <- the (Core (Maybe _, ArgType _)) $
                case fty of
                     Nothing => pure (Nothing, CaseBuilder.Unknown)
                     Just (NBind pfc _ (Pi c _ farg) fsc) =>
                        pure (Just !(fsc defs (toClosure defaultOpts [] (Ref pfc Bound arg))),
                                Known c (embed {more = arg :: args}
                                          !(quote empty [] farg)))
                     Just t =>
                        pure (Nothing,
                                Stuck (embed {more = arg :: args}
                                        !(quote empty [] t)))
             pure (MkInfo p First (Builtin.snd fa_tys)
                      :: weaken !(mkNames args ps eq (Builtin.fst fa_tys)))

export
patCompile : {auto c : Ref Ctxt Defs} ->
             FC -> Name -> Phase ->
             ClosedTerm -> List (List Pat, ClosedTerm) ->
             Maybe (CaseTree []) ->
             Core (args ** CaseTree args)
patCompile fc fn phase ty [] def
    = maybe (pure ([] ** Unmatched "No definition"))
            (\e => pure ([] ** e))
            def
patCompile fc fn phase ty (p :: ps) def
    = do let ns = getNames 0 (fst p)
         pats <- mkPatClausesFrom 0 ns (p :: ps)
         log 5 $ "Pattern clauses " ++ show pats
         i <- newRef PName (the Int 0)
         cases <- match fc fn phase pats
                        (rewrite sym (appendNilRightNeutral ns) in
                                 map (TT.weakenNs ns) def)
         pure (_ ** cases)
  where
    mkPatClausesFrom : Int -> (args : List Name) ->
                       List (List Pat, ClosedTerm) ->
                       Core (List (PatClause args args))
    mkPatClausesFrom i ns [] = pure []
    mkPatClausesFrom i ns (p :: ps)
        = do p' <- mkPatClause fc fn ns ty i p
             ps' <- mkPatClausesFrom (i + 1) ns ps
             pure (p' :: ps')

    getNames : Int -> List Pat -> List Name
    getNames i [] = []
    getNames i (x :: xs) = MN "arg" i :: getNames (i + 1) xs

toPatClause : {auto c : Ref Ctxt Defs} ->
              FC -> Name -> (ClosedTerm, ClosedTerm) ->
              Core (List Pat, ClosedTerm)
toPatClause fc n (lhs, rhs)
    = case getFnArgs lhs of
           (Ref ffc Func fn, args)
              => do defs <- get Ctxt
                    (np, _) <- getPosition n (gamma defs)
                    (fnp, _) <- getPosition fn (gamma defs)
                    if np == fnp
                       then pure (map argToPat args, rhs)
                       else throw (GenericMsg ffc ("Wrong function name in pattern LHS " ++ show (n, fn)))
           (f, args) => throw (GenericMsg fc "Not a function name in pattern LHS")

-- Assumption (given 'ClosedTerm') is that the pattern variables are
-- explicitly named. We'll assign de Bruijn indices when we're done, and
-- the names of the top level variables we created are returned in 'args'
export
simpleCase : {auto c : Ref Ctxt Defs} ->
             FC -> Phase -> Name -> ClosedTerm -> (def : Maybe (CaseTree [])) ->
             (clauses : List (ClosedTerm, ClosedTerm)) ->
             Core (args ** CaseTree args)
simpleCase fc phase fn ty def clauses
    = do logC 2 (do cs <- traverse (\c =>
                                do lhs <- toFullNames (fst c)
                                   rhs <- toFullNames (snd c)
                                   pure ("Clause " ++ show lhs ++ " = " ++ show rhs ++ "\n")) clauses
                    pure (concat cs))
         ps <- traverse (toPatClause fc fn) clauses
         defs <- get Ctxt
         patCompile fc fn phase ty ps def

findReached : CaseTree ns -> List Int
findReached (Case _ _ _ alts) = concatMap findRAlts alts
  where
    findRAlts : CaseAlt ns' -> List Int
    findRAlts (ConCase _ _ _ t) = findReached t
    findRAlts (DelayCase _ _ t) = findReached t
    findRAlts (ConstCase _ t) = findReached t
    findRAlts (DefaultCase t) = findReached t
findReached (STerm i _) = [i]
findReached _ = []

-- Returns the case tree, and a list of the clauses that aren't reachable
export
getPMDef : {auto c : Ref Ctxt Defs} ->
           FC -> Phase -> Name -> ClosedTerm -> List Clause ->
           Core (args ** (CaseTree args, List Clause))
-- If there's no clauses, make a definition with the right number of arguments
-- for the type, which we can use in coverage checking to ensure that one of
-- the arguments has an empty type
getPMDef fc phase fn ty []
    = do defs <- get Ctxt
         pure (!(getArgs 0 !(nf defs [] ty)) ** (Unmatched "No clauses", []))
  where
    getArgs : Int -> NF [] -> Core (List Name)
    getArgs i (NBind fc x (Pi _ _ _) sc)
        = do defs <- get Ctxt
             sc' <- sc defs (toClosure defaultOpts [] (Erased fc False))
             pure (MN "arg" i :: !(getArgs i sc'))
    getArgs i _ = pure []
getPMDef fc phase fn ty clauses
    = do defs <- get Ctxt
         let cs = map (toClosed defs) (labelPat 0 clauses)
         (_ ** t) <- simpleCase fc phase fn ty Nothing cs
         let reached = findReached t
         pure (_ ** (t, getUnreachable 0 reached clauses))
  where
    getUnreachable : Int -> List Int -> List Clause -> List Clause
    getUnreachable i is [] = []
    getUnreachable i is (c :: cs)
        = if i `elem` is
             then getUnreachable (i + 1) is cs
             else c :: getUnreachable (i + 1) is cs

    labelPat : Int -> List a -> List (String, a)
    labelPat i [] = []
    labelPat i (x :: xs) = ("pat" ++ show i ++ ":", x) :: labelPat (i + 1) xs

    mkSubstEnv : Int -> String -> Env Term vars -> SubstEnv vars []
    mkSubstEnv i pname [] = Nil
    mkSubstEnv i pname (v :: vs)
       = Ref fc Bound (MN pname i) :: mkSubstEnv (i + 1) pname vs

    close : {vars : _} ->
            Env Term vars -> String -> Term vars -> ClosedTerm
    close {vars} env pname tm
        = substs (mkSubstEnv 0 pname env)
              (rewrite appendNilRightNeutral vars in tm)

    toClosed : Defs -> (String, Clause) -> (ClosedTerm, ClosedTerm)
    toClosed defs (pname, MkClause env lhs rhs)
          = (close env pname lhs, close env pname rhs)
