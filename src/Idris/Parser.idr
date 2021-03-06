module Idris.Parser

import        Core.Options
import        Idris.Syntax
import public Parser.Source
import        Parser.Lexer.Source
import        TTImp.TTImp

import public Text.Parser
import        Data.List
import        Data.List.Views
import        Data.List1
import        Data.Maybe
import        Data.Strings

%default covering

-- Forward declare since they're used in the parser
topDecl : FileName -> IndentInfo -> Rule (List PDecl)
collectDefs : List PDecl -> List PDecl

-- Some context for the parser
public export
record ParseOpts where
  constructor MkParseOpts
  eqOK : Bool -- = operator is parseable
  withOK : Bool -- = with applications are parseable

peq : ParseOpts -> ParseOpts
peq = record { eqOK = True }

pnoeq : ParseOpts -> ParseOpts
pnoeq = record { eqOK = False }

export
pdef : ParseOpts
pdef = MkParseOpts True True

pnowith : ParseOpts
pnowith = MkParseOpts True False

export
plhs : ParseOpts
plhs = MkParseOpts False False

%hide Prelude.(>>=)
%hide Core.Core.(>>=)
%hide Prelude.pure
%hide Core.Core.pure

boundToFC : String -> WithBounds t -> FC
boundToFC fname b = MkFC fname (start b) (end b)

atom : FileName -> Rule PTerm
atom fname
    = do x <- bounds $ exactIdent "Type"
         pure (PType (boundToFC fname x))
  <|> do x <- bounds $ name
         pure (PRef (boundToFC fname x) x.val)
  <|> do x <- bounds $ constant
         pure (PPrimVal (boundToFC fname x) x.val)
  <|> do x <- bounds $ symbol "_"
         pure (PImplicit (boundToFC fname x))
  <|> do x <- bounds $ symbol "?"
         pure (PInfer (boundToFC fname x))
  <|> do x <- bounds $ holeName
         pure (PHole (boundToFC fname x) False x.val)
  <|> do x <- bounds $ pragma "MkWorld"
         pure (PPrimVal (boundToFC fname x) WorldVal)
  <|> do x <- bounds $ pragma "World"
         pure (PPrimVal (boundToFC fname x) WorldType)
  <|> do x <- bounds $ pragma "search"
         pure (PSearch (boundToFC fname x) 50)

whereBlock : FileName -> Int -> Rule (List PDecl)
whereBlock fname col
    = do keyword "where"
         ds <- blockAfter col (topDecl fname)
         pure (collectDefs (concat ds))

-- Expect a keyword, but if we get anything else it's a fatal error
commitKeyword : IndentInfo -> String -> Rule ()
commitKeyword indents req
    = do mustContinue indents (Just req)
         keyword req
         mustContinue indents Nothing

commitSymbol : String -> Rule ()
commitSymbol req
    = symbol req
       <|> fatalError ("Expected '" ++ req ++ "'")

continueWith : IndentInfo -> String -> Rule ()
continueWith indents req
    = mustContinue indents (Just req) *> symbol req

iOperator : Rule Name
iOperator
    = operator <|> (symbol "`" *> name <* symbol "`")

data ArgType
    = ExpArg PTerm
    | ImpArg (Maybe Name) PTerm
    | WithArg PTerm

argTerm : ArgType -> PTerm
argTerm (ExpArg t) = t
argTerm (ImpArg _ t) = t
argTerm (WithArg t) = t

mutual
  appExpr : ParseOpts -> FileName -> IndentInfo -> Rule PTerm
  appExpr q fname indents
      = case_ fname indents
    <|> doBlock fname indents
    <|> lambdaCase fname indents
    <|> lazy fname indents
    <|> if_ fname indents
    <|> with_ fname indents
    <|> do b <- bounds (MkPair <$> simpleExpr fname indents <*> many (argExpr q fname indents))
           (f, args) <- pure b.val
           pure (applyExpImp (start b) (end b) f args)
    <|> do b <- bounds (MkPair <$> iOperator <*> expr pdef fname indents)
           (op, arg) <- pure b.val
           pure (PPrefixOp (boundToFC fname b) op arg)
    <|> fail "Expected 'case', 'if', 'do', application or operator expression"
    where
      applyExpImp : FilePos -> FilePos -> PTerm ->
                    List ArgType ->
                    PTerm
      applyExpImp start end f [] = f
      applyExpImp start end f (ExpArg exp :: args)
          = applyExpImp start end (PApp (MkFC fname start end) f exp) args
      applyExpImp start end f (ImpArg n imp :: args)
          = applyExpImp start end (PImplicitApp (MkFC fname start end) f n imp) args
      applyExpImp start end f (WithArg exp :: args)
          = applyExpImp start end (PWithApp (MkFC fname start end) f exp) args

  argExpr : ParseOpts -> FileName -> IndentInfo -> Rule ArgType
  argExpr q fname indents
      = do continue indents
           arg <- simpleExpr fname indents
           the (SourceEmptyRule _) $ case arg of
                PHole loc _ n => pure (ExpArg (PHole loc True n))
                t => pure (ExpArg t)
    <|> do continue indents
           arg <- implicitArg fname indents
           pure (ImpArg (fst arg) (snd arg))
    <|> if withOK q
           then do continue indents
                   symbol "|"
                   arg <- expr (record {withOK = False} q) fname indents
                   pure (WithArg arg)
           else fail "| not allowed here"

  implicitArg : FileName -> IndentInfo -> Rule (Maybe Name, PTerm)
  implicitArg fname indents
      = do x <- bounds (symbol "{" *> unqualifiedName)
           (do tm <- symbol "=" *> commit *> expr pdef fname indents <* symbol "}"
               pure (Just (UN x.val), tm))
             <|> (do b <- bounds (symbol "}")
                     pure (Just (UN x.val), PRef (boundToFC fname (mergeBounds x b)) (UN x.val)))
    <|> do symbol "@{"
           commit
           tm <- expr pdef fname indents
           symbol "}"
           pure (Nothing, tm)

  with_ : FileName -> IndentInfo -> Rule PTerm
  with_ fname indents
      = do b <- bounds (do keyword "with"
                           commit
                           ns <- singleName <|> nameList
                           end <- location
                           rhs <- expr pdef fname indents
                           pure (ns, rhs))
           (ns, rhs) <- pure b.val
           pure (PWithUnambigNames (boundToFC fname b) ns rhs)
    where
      singleName : Rule (List Name)
      singleName = do
        n <- name
        pure [n]

      nameList : Rule (List Name)
      nameList = do
        symbol "["
        commit
        ns <- sepBy1 (symbol ",") name
        symbol "]"
        pure ns

  opExpr : ParseOpts -> FileName -> IndentInfo -> Rule PTerm
  opExpr q fname indents
      = do l <- bounds (appExpr q fname indents)
           (if eqOK q
               then do r <- bounds (continue indents *> symbol "=" *> opExpr q fname indents)
                       pure (POp (boundToFC fname (mergeBounds l r)) (UN "=") l.val r.val)
               else fail "= not allowed")
             <|>
             (do b <- bounds (MkPair <$> (continue indents *> iOperator) <*> opExpr q fname indents)
                 (op, r) <- pure b.val
                 pure (POp (boundToFC fname (mergeBounds l b)) op l.val r))
               <|> pure l.val

  dpairType : FileName -> WithBounds t -> IndentInfo -> Rule PTerm
  dpairType fname start indents
      = do loc <- bounds (do x <- unqualifiedName
                             symbol ":"
                             ty <- expr pdef fname indents
                             pure (x, ty))
           (x, ty) <- pure loc.val
           (do symbol "**"
               rest <- bounds ((nestedDpair fname loc indents <|> expr pdef fname indents) <* symbol ")")
               pure (PDPair (boundToFC fname (mergeBounds start rest))
                            (PRef (boundToFC fname loc) (UN x))
                            ty
                            rest.val))
              <|> pure ty

  nestedDpair : FileName -> WithBounds t -> IndentInfo -> Rule PTerm
  nestedDpair fname start indents
      = dpairType fname start indents
    <|> do l <- expr pdef fname indents
           loc <- bounds (symbol "**")
           rest <- bounds (nestedDpair fname loc indents <* symbol ")")
           pure (PDPair (boundToFC fname (mergeBounds start rest))
                        l
                        (PImplicit (boundToFC fname (mergeBounds start rest)))
                        rest.val)

  bracketedExpr : FileName -> WithBounds t -> IndentInfo -> Rule PTerm
  bracketedExpr fname s indents
      -- left section. This may also be a prefix operator, but we'll sort
      -- that out when desugaring: if the operator is infix, treat it as a
      -- section otherwise treat it as prefix
      = do b <- bounds (do op <- iOperator
                           e <- expr pdef fname indents
                           continueWith indents ")"
                           pure (op, e))
           (op, e) <- pure b.val
           pure (PSectionL (boundToFC fname (mergeBounds s b)) op e)
    <|> do  -- (.y.z)  -- section of projection (chain)
           b <- bounds (MkPair <$> (some $ postfixApp fname indents) <*> (many $ simpleExpr fname indents))
           (projs, args) <- pure b.val
           symbol ")"
           pure $ PPostfixProjsSection (boundToFC fname b) projs args
      -- unit type/value
    <|> do b <- bounds (continueWith indents ")")
           pure (PUnit (boundToFC fname (mergeBounds s b)))
      -- dependent pairs with type annotation (so, the type form)
    <|> do dpairType fname s indents
    <|> do here <- location
           e <- bounds (expr pdef fname indents)
           -- dependent pairs with no type annotation
           (do loc <- bounds (symbol "**")
               rest <- bounds ((nestedDpair fname loc indents <|> expr pdef fname indents) <* symbol ")")
               pure (PDPair (boundToFC fname (mergeBounds s rest))
                            e.val
                            (PImplicit (boundToFC fname (mergeBounds s rest)))
                            rest.val)) <|>
             -- right sections
             ((do op <- bounds (iOperator <* symbol ")")
                  pure (PSectionR (boundToFC fname (mergeBounds s op)) e.val op.val)
               <|>
              -- all the other bracketed expressions
              tuple fname s indents e.val))

  getInitRange : List PTerm -> SourceEmptyRule (PTerm, Maybe PTerm)
  getInitRange [x] = pure (x, Nothing)
  getInitRange [x, y] = pure (x, Just y)
  getInitRange _ = fatalError "Invalid list range syntax"

  listRange : FileName -> WithBounds t -> IndentInfo -> List PTerm -> Rule PTerm
  listRange fname s indents xs
      = do b <- bounds (symbol "]")
           let fc = boundToFC fname (mergeBounds s b)
           rstate <- getInitRange xs
           pure (PRangeStream fc (fst rstate) (snd rstate))
    <|> do y <- bounds (expr pdef fname indents <* symbol "]")
           let fc = boundToFC fname (mergeBounds s y)
           rstate <- getInitRange xs
           pure (PRange fc (fst rstate) (snd rstate) y.val)

  listExpr : FileName -> WithBounds t -> IndentInfo -> Rule PTerm
  listExpr fname s indents
      = do b <- bounds (do ret <- expr pnowith fname indents
                           symbol "|"
                           conds <- sepBy1 (symbol ",") (doAct fname indents)
                           symbol "]"
                           pure (ret, conds))
           (ret, conds) <- pure b.val
           pure (PComprehension (boundToFC fname (mergeBounds s b)) ret (concat conds))
    <|> do xs <- sepBy (symbol ",") (expr pdef fname indents)
           (do symbol ".."
               listRange fname s indents xs)
             <|> (do b <- bounds (symbol "]")
                     pure (PList (boundToFC fname (mergeBounds s b)) xs))

  -- A pair, dependent pair, or just a single expression
  tuple : FileName -> WithBounds t -> IndentInfo -> PTerm -> Rule PTerm
  tuple fname s indents e
      = do rest <- bounds (some (symbol "," *> bounds (expr pdef fname indents)) <* continueWith indents ")")
           pure (PPair (boundToFC fname (mergeBounds s rest)) e
                       (mergePairs rest rest.val))
     <|> do end <- bounds (continueWith indents ")")
            pure (PBracketed (boundToFC fname (mergeBounds s end)) e)
    where
      mergePairs : WithBounds t' -> List (WithBounds PTerm) -> PTerm
      mergePairs end [] = PUnit (boundToFC fname (mergeBounds s end))
      mergePairs end [exp] = exp.val
      mergePairs end (exp :: rest)
          = PPair (boundToFC fname (mergeBounds exp end)) exp.val (mergePairs end rest)

  postfixApp : FileName -> IndentInfo -> Rule PTerm
  postfixApp fname indents
    = do di <- bounds dotIdent
         pure $ PRef (boundToFC fname di) di.val
    <|> (symbol ".(" *> commit *> expr pdef fname indents <* symbol ")")

  simpleExpr : FileName -> IndentInfo -> Rule PTerm
  simpleExpr fname indents
    = do  -- x.y.z
          b <- bounds (do root <- simplerExpr fname indents
                          projs <- many $ postfixApp fname indents
                          pure (root, projs))
          (root, projs) <- pure b.val
          pure $ case projs of
            [] => root
            _  => PPostfixProjs (boundToFC fname b) root projs

  simplerExpr : FileName -> IndentInfo -> Rule PTerm
  simplerExpr fname indents
      = do b <- bounds (do x <- unqualifiedName
                           symbol "@"
                           commit
                           expr <- simpleExpr fname indents
                           pure (x, expr))
           (x, expr) <- pure b.val
           pure (PAs (boundToFC fname b) (UN x) expr)
    <|> atom fname
    <|> binder fname indents
    <|> rewrite_ fname indents
    <|> record_ fname indents
    <|> do b <- bounds (symbol ".(" *> commit *> expr pdef fname indents <* symbol ")")
           pure (PDotted (boundToFC fname b) b.val)
    <|> do b <- bounds (symbol "`(" *> expr pdef fname indents <* symbol ")")
           pure (PQuote (boundToFC fname b) b.val)
    <|> do b <- bounds (symbol "`{{" *> name <* symbol "}}")
           pure (PQuoteName (boundToFC fname b) b.val)
    <|> do b <- bounds (symbol "`[" *> nonEmptyBlock (topDecl fname) <* symbol "]")
           pure (PQuoteDecl (boundToFC fname b) (collectDefs (concat b.val)))
    <|> do b <- bounds (symbol "~" *> simpleExpr fname indents)
           pure (PUnquote (boundToFC fname b) b.val)
    <|> do start <- bounds (symbol "(")
           bracketedExpr fname start indents
    <|> do start <- bounds (symbol "[")
           listExpr fname start indents
    <|> do b <- bounds (symbol "!" *> simpleExpr fname indents)
           pure (PBang (boundToFC fname b) b.val)
    <|> do b <- bounds (symbol "[|" *> expr pdef fname indents <* symbol "|]")
           pure (PIdiom (boundToFC fname b) b.val)
    <|> do b <- bounds (pragma "runElab" *> expr pdef fname indents)
           pure (PRunElab (boundToFC fname b) b.val)
    <|> do b <- bounds (MkPair <$> (pragma "logging" *> intLit) <*> expr pdef fname indents)
           (lvl, e) <- pure b.val
           pure (PUnifyLog (boundToFC fname b) (integerToNat lvl) e)

  multiplicity : SourceEmptyRule (Maybe Integer)
  multiplicity
      = do c <- intLit
           pure (Just c)
--     <|> do symbol "&"
--            pure (Just 2) -- Borrowing, not implemented
    <|> pure Nothing

  getMult : Maybe Integer -> SourceEmptyRule RigCount
  getMult (Just 0) = pure erased
  getMult (Just 1) = pure linear
  getMult Nothing = pure top
  getMult _ = fatalError "Invalid multiplicity (must be 0 or 1)"

  pibindAll : FC -> PiInfo PTerm -> List (RigCount, Maybe Name, PTerm) ->
              PTerm -> PTerm
  pibindAll fc p [] scope = scope
  pibindAll fc p ((rig, n, ty) :: rest) scope
           = PPi fc rig p n ty (pibindAll fc p rest scope)

  bindList : FileName -> WithBounds t -> IndentInfo ->
             Rule (List (RigCount, PTerm, PTerm))
  bindList fname start indents
      = sepBy1 (symbol ",")
               (do rigc <- multiplicity
                   pat <- simpleExpr fname indents
                   ty <- option
                            (PInfer (boundToFC fname start))
                            (symbol ":" *> opExpr pdef fname indents)
                   rig <- getMult rigc
                   pure (rig, pat, ty))

  pibindListName : FileName -> IndentInfo ->
                   Rule (List (RigCount, Name, PTerm))
  pibindListName fname indents
       = do rigc <- multiplicity
            ns <- sepBy1 (symbol ",") binderName
            symbol ":"
            ty <- expr pdef fname indents
            atEnd indents
            rig <- getMult rigc
            pure (map (\n => (rig, UN n, ty)) ns)
     <|> sepBy1 (symbol ",")
                (do rigc <- multiplicity
                    n <- binderName
                    symbol ":"
                    ty <- expr pdef fname indents
                    rig <- getMult rigc
                    pure (rig, UN n, ty))
    where
      -- _ gets treated specially here, it means "I don't care about the name"
      binderName : Rule String
      binderName = unqualifiedName <|> (symbol "_" *> pure "_")

  pibindList : FileName -> IndentInfo ->
               Rule (List (RigCount, Maybe Name, PTerm))
  pibindList fname indents
    = do params <- pibindListName fname indents
         pure $ map (\(rig, n, ty) => (rig, Just n, ty)) params

  bindSymbol : Rule (PiInfo PTerm)
  bindSymbol
      = (symbol "->" *> pure Explicit)
    <|> (symbol "=>" *> pure AutoImplicit)

  explicitPi : FileName -> IndentInfo -> Rule PTerm
  explicitPi fname indents
      = do b <- bounds (do s <- bounds (symbol "(")
                           binders <- pibindList fname indents
                           symbol ")"
                           exp <- bindSymbol
                           scope <- typeExpr pdef fname indents
                           pure (binders, exp, scope))
           (binders, exp, scope) <- pure b.val
           pure (pibindAll (boundToFC fname b) exp binders scope)

  autoImplicitPi : FileName -> IndentInfo -> Rule PTerm
  autoImplicitPi fname indents
      = do b <- bounds (do s <- bounds (symbol "{")
                           keyword "auto"
                           commit
                           binders <- pibindList fname indents
                           symbol "}"
                           symbol "->"
                           scope <- typeExpr pdef fname indents
                           pure (binders, scope))
           (binders, scope) <- pure b.val
           pure (pibindAll (boundToFC fname b) AutoImplicit binders scope)

  defaultImplicitPi : FileName -> IndentInfo -> Rule PTerm
  defaultImplicitPi fname indents
      = do b <- bounds (do s <- bounds (symbol "{")
                           keyword "default"
                           commit
                           t <- simpleExpr fname indents
                           binders <- pibindList fname indents
                           symbol "}"
                           symbol "->"
                           scope <- typeExpr pdef fname indents
                           pure (t, binders, scope))
           (t, binders, scope) <- pure b.val
           pure (pibindAll (boundToFC fname b) (DefImplicit t) binders scope)

  forall_ : FileName -> IndentInfo -> Rule PTerm
  forall_ fname indents
      = do b <- bounds (do keyword "forall"
                           commit
                           ns <- bounds $ sepBy1 (symbol ",") unqualifiedName
                           let binders = map (\n => (erased {a=RigCount},
                                                     Just (UN n), PImplicit (boundToFC fname ns))) ns.val
                           symbol "."
                           scope <- typeExpr pdef fname indents
                           pure (binders, scope))
           (binders, scope) <- pure b.val
           pure (pibindAll (boundToFC fname b) Implicit binders scope)

  implicitPi : FileName -> IndentInfo -> Rule PTerm
  implicitPi fname indents
      = do b <- bounds (do s <- bounds (symbol "{")
                           binders <- pibindList fname indents
                           symbol "}"
                           symbol "->"
                           scope <- typeExpr pdef fname indents
                           pure (binders, scope))
           (binders, scope) <- pure b.val
           pure (pibindAll (boundToFC fname b) Implicit binders scope)

  lam : FileName -> IndentInfo -> Rule PTerm
  lam fname indents
      = do b <- bounds (do s <- bounds (symbol "\\")
                           binders <- bindList fname s indents
                           symbol "=>"
                           mustContinue indents Nothing
                           scope <- expr pdef fname indents
                           pure (binders, scope))
           (binders, scope) <- pure b.val
           pure (bindAll (boundToFC fname b) binders scope)
     where
       bindAll : FC -> List (RigCount, PTerm, PTerm) -> PTerm -> PTerm
       bindAll fc [] scope = scope
       bindAll fc ((rig, pat, ty) :: rest) scope
           = PLam fc rig Explicit pat ty (bindAll fc rest scope)

  letBinder : FileName -> IndentInfo ->
              Rule (FilePos, FilePos, RigCount, PTerm, PTerm, PTerm, List PClause)
  letBinder fname indents
      = do b <- bounds (do s <- bounds (MkPair <$> multiplicity <*> expr plhs fname indents)
                           (rigc, pat) <- pure s.val
                           ty <- option (PImplicit (boundToFC fname s))
                                        (do symbol ":"
                                            typeExpr (pnoeq pdef) fname indents)
                           symbol "="
                           val <- expr pnowith fname indents
                           alts <- block (patAlt fname)
                           rig <- getMult rigc
                           pure (rig, pat, ty, val, alts))
           (rig, pat, ty, val, alts) <- the (SourceEmptyRule (RigCount, PTerm, PTerm, PTerm, List PClause)) (pure b.val)
           pure (start b, end b, rig, pat, ty, val, alts)

  buildLets : FileName ->
              List (FilePos, FilePos, RigCount, PTerm, PTerm, PTerm, List PClause) ->
              PTerm -> PTerm
  buildLets fname [] sc = sc
  buildLets fname ((start, end, rig, pat, ty, val, alts) :: rest) sc
      = let fc = MkFC fname start end in
            PLet fc rig pat ty val
                 (buildLets fname rest sc) alts

  buildDoLets : FileName ->
                List (FilePos, FilePos, RigCount, PTerm, PTerm, PTerm, List PClause) ->
                List PDo
  buildDoLets fname [] = []
  buildDoLets fname ((start, end, rig, PRef fc' (UN n), ty, val, []) :: rest)
      = let fc = MkFC fname start end in
            if lowerFirst n
               then DoLet fc (UN n) rig ty val :: buildDoLets fname rest
               else DoLetPat fc (PRef fc' (UN n)) ty val []
                         :: buildDoLets fname rest
  buildDoLets fname ((start, end, rig, pat, ty, val, alts) :: rest)
      = let fc = MkFC fname start end in
            DoLetPat fc pat ty val alts :: buildDoLets fname rest

  let_ : FileName -> IndentInfo -> Rule PTerm
  let_ fname indents
      = do b <- bounds (do keyword "let"
                           res <- nonEmptyBlock (letBinder fname)
                           commitKeyword indents "in"
                           scope <- typeExpr pdef fname indents
                           pure (res, scope))
           (res, scope) <- pure b.val
           pure (buildLets fname res scope)

    <|> do b <- bounds (do keyword "let"
                           commit
                           ds <- nonEmptyBlock (topDecl fname)
                           commitKeyword indents "in"
                           scope <- typeExpr pdef fname indents
                           pure (ds, scope))
           (ds, scope) <- pure b.val
           pure (PLocal (boundToFC fname b) (collectDefs (concat ds)) scope)

  case_ : FileName -> IndentInfo -> Rule PTerm
  case_ fname indents
      = do b <- bounds (do keyword "case"
                           scr <- expr pdef fname indents
                           commitKeyword indents "of"
                           alts <- block (caseAlt fname)
                           pure (scr, alts))
           (scr, alts) <- pure b.val
           pure (PCase (boundToFC fname b) scr alts)

  lambdaCase : FileName -> IndentInfo -> Rule PTerm
  lambdaCase fname indents
      = do b <- bounds (do endCase <- bounds (symbol "\\" *> keyword "case")
                           commit
                           alts <- block (caseAlt fname)
                           pure (endCase, alts))
           (endCase, alts) <- pure b.val
           pure $
            (let fc = boundToFC fname b
                 fcCase = boundToFC fname endCase
                 n = MN "lcase" 0 in
              PLam fcCase top Explicit (PRef fcCase n) (PInfer fcCase) $
                PCase fc (PRef fcCase n) alts)

  caseAlt : FileName -> IndentInfo -> Rule PClause
  caseAlt fname indents
      = do lhs <- bounds (opExpr plhs fname indents)
           caseRHS fname lhs indents lhs.val

  caseRHS : FileName -> WithBounds t -> IndentInfo -> PTerm -> Rule PClause
  caseRHS fname start indents lhs
      = do rhs <- bounds (symbol "=>" *> mustContinue indents Nothing *> expr pdef fname indents)
           atEnd indents
           pure (MkPatClause (boundToFC fname (mergeBounds start rhs)) lhs rhs.val [])
    <|> do end <- bounds (keyword "impossible")
           atEnd indents
           pure (MkImpossible (boundToFC fname (mergeBounds start end)) lhs)

  if_ : FileName -> IndentInfo -> Rule PTerm
  if_ fname indents
      = do b <- bounds (do keyword "if"
                           x <- expr pdef fname indents
                           commitKeyword indents "then"
                           t <- expr pdef fname indents
                           commitKeyword indents "else"
                           e <- expr pdef fname indents
                           pure (x, t, e))
           atEnd indents
           (x, t, e) <- pure b.val
           pure (PIfThenElse (boundToFC fname b) x t e)

  record_ : FileName -> IndentInfo -> Rule PTerm
  record_ fname indents
      = do b <- bounds (do keyword "record"
                           symbol "{"
                           commit
                           fs <- sepBy1 (symbol ",") (field fname indents)
                           symbol "}"
                           pure fs)
           pure (PUpdate (boundToFC fname b) b.val)

  field : FileName -> IndentInfo -> Rule PFieldUpdate
  field fname indents
      = do path <- map fieldName <$> [| name :: many recFieldCompat |]
           upd <- (symbol "=" *> pure PSetField)
                      <|>
                  (symbol "$=" *> pure PSetFieldApp)
           val <- opExpr plhs fname indents
           pure (upd path val)
    where
      fieldName : Name -> String
      fieldName (UN s) = s
      fieldName _ = "_impossible"

      -- this allows the dotted syntax .field
      -- but also the arrowed syntax ->field for compatibility with Idris 1
      recFieldCompat : Rule Name
      recFieldCompat = dotIdent <|> (symbol "->" *> name)

  rewrite_ : FileName -> IndentInfo -> Rule PTerm
  rewrite_ fname indents
      = do b <- bounds (do keyword "rewrite"
                           rule <- expr pdef fname indents
                           commitKeyword indents "in"
                           tm <- expr pdef fname indents
                           pure (rule, tm))
           (rule, tm) <- pure b.val
           pure (PRewrite (boundToFC fname b) rule tm)

  doBlock : FileName -> IndentInfo -> Rule PTerm
  doBlock fname indents
      = do b <- bounds (do keyword "do"
                           block (doAct fname))
           pure (PDoBlock (boundToFC fname b) Nothing (concat b.val))
    <|> do nsdo <- bounds namespacedIdent
           the (SourceEmptyRule PTerm) $ case nsdo.val of
                ("do" :: ns) =>
                   do actions <- bounds (block (doAct fname))
                      pure (PDoBlock (boundToFC fname (mergeBounds nsdo actions))
                                     (Just (reverse ns)) (concat actions.val))
                _ => fail "Not a namespaced 'do'"

  lowerFirst : String -> Bool
  lowerFirst "" = False
  lowerFirst str = assert_total (isLower (prim__strHead str))

  validPatternVar : Name -> SourceEmptyRule ()
  validPatternVar (UN n)
      = if lowerFirst n then pure ()
                        else fail "Not a pattern variable"
  validPatternVar _ = fail "Not a pattern variable"

  doAct : FileName -> IndentInfo -> Rule (List PDo)
  doAct fname indents
      = do b <- bounds (do n <- name
                           -- If the name doesn't begin with a lower case letter, we should
                           -- treat this as a pattern, so fail
                           validPatternVar n
                           symbol "<-"
                           val <- expr pdef fname indents
                           pure (n, val))
           atEnd indents
           (n, val) <- pure b.val
           pure [DoBind (boundToFC fname b) n val]
    <|> do keyword "let"
           res <- block (letBinder fname)
           atEnd indents
           pure (buildDoLets fname res)
    <|> do b <- bounds (keyword "let" *> block (topDecl fname))
           atEnd indents
           pure [DoLetLocal (boundToFC fname b) (concat b.val)]
    <|> do b <- bounds (keyword "rewrite" *> expr pdef fname indents)
           atEnd indents
           pure [DoRewrite (boundToFC fname b) b.val]
    <|> do e <- bounds (expr plhs fname indents)
           (do atEnd indents
               pure [DoExp (boundToFC fname e) e.val])
             <|> (do b <- bounds (do symbol "<-"
                                     val <- expr pnowith fname indents
                                     alts <- block (patAlt fname)
                                     pure (val, alts))
                     atEnd indents
                     (v, alts) <- pure b.val
                     pure [DoBindPat (boundToFC fname (mergeBounds e b)) e.val v alts])

  patAlt : FileName -> IndentInfo -> Rule PClause
  patAlt fname indents
      = do symbol "|"
           caseAlt fname indents

  lazy : FileName -> IndentInfo -> Rule PTerm
  lazy fname indents
      = do tm <- bounds (exactIdent "Lazy" *> simpleExpr fname indents)
           pure (PDelayed (boundToFC fname tm) LLazy tm.val)
    <|> do tm <- bounds (exactIdent "Inf" *> simpleExpr fname indents)
           pure (PDelayed (boundToFC fname tm) LInf tm.val)
    <|> do tm <- bounds (exactIdent "Delay" *> simpleExpr fname indents)
           pure (PDelay (boundToFC fname tm) tm.val)
    <|> do tm <- bounds (exactIdent "Force" *> simpleExpr fname indents)
           pure (PForce (boundToFC fname tm) tm.val)

  binder : FileName -> IndentInfo -> Rule PTerm
  binder fname indents
      = let_ fname indents
    <|> autoImplicitPi fname indents
    <|> defaultImplicitPi fname indents
    <|> forall_ fname indents
    <|> implicitPi fname indents
    <|> explicitPi fname indents
    <|> lam fname indents

  typeExpr : ParseOpts -> FileName -> IndentInfo -> Rule PTerm
  typeExpr q fname indents
      = do arg <- bounds (opExpr q fname indents)
           (do continue indents
               rest <- bounds (some (do exp <- bindSymbol
                                        op <- opExpr pdef fname indents
                                        pure (exp, op)))
               pure (mkPi (start arg) (end rest) arg.val rest.val))
             <|> pure arg.val
    where
      mkPi : FilePos -> FilePos -> PTerm -> List (PiInfo PTerm, PTerm) -> PTerm
      mkPi start end arg [] = arg
      mkPi start end arg ((exp, a) :: as)
            = PPi (MkFC fname start end) top exp Nothing arg
                  (mkPi start end a as)

  export
  expr : ParseOpts -> FileName -> IndentInfo -> Rule PTerm
  expr = typeExpr

visOption : Rule Visibility
visOption
    = (keyword "public" *> keyword "export" *> pure Public)
  <|> (keyword "export" *> pure Export)
  <|> (keyword "private" *> pure Private)

visibility : SourceEmptyRule Visibility
visibility
    = visOption
  <|> pure Private

tyDecl : String -> FileName -> IndentInfo -> Rule PTypeDecl
tyDecl predoc fname indents
    = do b <- bounds (do doc   <- option "" documentation
                         n     <- name
                         symbol ":"
                         mustWork $
                            do ty  <- expr pdef fname indents
                               pure (doc, n, ty))
         atEnd indents
         (doc, n, ty) <- pure b.val
         pure (MkPTy (boundToFC fname b) n (predoc ++ doc) ty)

withFlags : SourceEmptyRule (List WithFlag)
withFlags
    = do pragma "syntactic"
         fs <- withFlags
         pure $ Syntactic :: fs
  <|> pure []

mutual
  parseRHS : (withArgs : Nat) ->
             FileName -> WithBounds t -> Int ->
             IndentInfo -> (lhs : PTerm) -> Rule PClause
  parseRHS withArgs fname start col indents lhs
       = do b <- bounds (symbol "=" *> mustWork (
                           do rhs <- expr pdef fname indents
                              ws <- option [] (whereBlock fname col)
                              pure (rhs, ws)))
            atEnd indents
            (rhs, ws) <- pure b.val
            pure (MkPatClause (boundToFC fname (mergeBounds start b)) lhs rhs ws)
     <|> do b <- bounds (do keyword "with"
                            flags <- bounds (withFlags)
                            symbol "("
                            wval <- bracketedExpr fname flags indents
                            ws <- nonEmptyBlock (clause (S withArgs) fname)
                            pure (flags, wval, ws))
            (flags, wval, ws) <- pure b.val
            pure (MkWithClause (boundToFC fname (mergeBounds start b)) lhs wval flags.val ws)
     <|> do end <- bounds (keyword "impossible")
            atEnd indents
            pure (MkImpossible (boundToFC fname (mergeBounds start end)) lhs)

  ifThenElse : Bool -> Lazy t -> Lazy t -> t
  ifThenElse True t e = t
  ifThenElse False t e = e

  clause : Nat -> FileName -> IndentInfo -> Rule PClause
  clause withArgs fname indents
      = do b <- bounds (do col <- column
                           lhs <- expr plhs fname indents
                           extra <- many parseWithArg
                           pure (col, lhs, extra))
           (col, lhs, extra) <- pure b.val
           -- Can't have the dependent 'if' here since we won't be able
           -- to infer the termination status of the rule
           ifThenElse (withArgs /= length extra)
              (fatalError "Wrong number of 'with' arguments")
              (parseRHS withArgs fname b col indents (applyArgs lhs extra))
    where
      applyArgs : PTerm -> List (FC, PTerm) -> PTerm
      applyArgs f [] = f
      applyArgs f ((fc, a) :: args) = applyArgs (PApp fc f a) args

      parseWithArg : Rule (FC, PTerm)
      parseWithArg
          = do symbol "|"
               tm <- bounds (expr plhs fname indents)
               pure (boundToFC fname tm, tm.val)

mkTyConType : FC -> List Name -> PTerm
mkTyConType fc [] = PType fc
mkTyConType fc (x :: xs)
   = PPi fc linear Explicit Nothing (PType fc) (mkTyConType fc xs)

mkDataConType : FC -> PTerm -> List ArgType -> PTerm
mkDataConType fc ret [] = ret
mkDataConType fc ret (ExpArg x :: xs)
    = PPi fc linear Explicit Nothing x (mkDataConType fc ret xs)
mkDataConType fc ret (ImpArg n (PRef fc' x) :: xs)
    = if n == Just x
         then PPi fc linear Implicit n (PType fc')
                          (mkDataConType fc ret xs)
         else PPi fc linear Implicit n (PRef fc' x)
                          (mkDataConType fc ret xs)
mkDataConType fc ret (ImpArg n x :: xs)
    = PPi fc linear Implicit n x (mkDataConType fc ret xs)
mkDataConType fc ret (WithArg a :: xs)
    = PImplicit fc -- This can't happen because we parse constructors without
                   -- withOK set

simpleCon : FileName -> PTerm -> IndentInfo -> Rule PTypeDecl
simpleCon fname ret indents
    = do b <- bounds (do cdoc   <- option "" documentation
                         cname  <- name
                         params <- many (argExpr plhs fname indents)
                         pure (cdoc, cname, params))
         atEnd indents
         (cdoc, cname, params) <- pure b.val
         pure (let cfc = boundToFC fname b in
                   MkPTy cfc cname cdoc (mkDataConType cfc ret params))

simpleData : FileName -> WithBounds t -> Name -> IndentInfo -> Rule PDataDecl
simpleData fname start n indents
    = do b <- bounds (do params <- many name
                         tyend <- bounds (symbol "=")
                         let tyfc = boundToFC fname (mergeBounds start tyend)
                         let conRetTy = papply tyfc (PRef tyfc n) (map (PRef tyfc) params)
                         cons <- sepBy1 (symbol "|") (simpleCon fname conRetTy indents)
                         pure (params, tyfc, cons))
         (params, tyfc, cons) <- pure b.val
         pure (MkPData (boundToFC fname (mergeBounds start b)) n
                       (mkTyConType tyfc params) [] cons)

dataOpt : Rule DataOpt
dataOpt
    = (exactIdent "noHints" *> pure NoHints)
  <|> (exactIdent "uniqueSearch" *> pure UniqueSearch)
  <|> do exactIdent "search"
         ns <- some name
         pure (SearchBy ns)
  <|> (exactIdent "external" *> pure External)
  <|> (exactIdent "noNewtype" *> pure NoNewtype)

dataBody : FileName -> Int -> WithBounds t -> Name -> IndentInfo -> PTerm ->
          SourceEmptyRule PDataDecl
dataBody fname mincol start n indents ty
    = do atEndIndent indents
         pure (MkPLater (boundToFC fname start) n ty)
  <|> do b <- bounds (do keyword "where"
                         opts <- option [] (do symbol "["
                                               dopts <- sepBy1 (symbol ",") dataOpt
                                               symbol "]"
                                               pure dopts)
                         cs <- blockAfter mincol (tyDecl "" fname)
                         pure (opts, cs))
         (opts, cs) <- pure b.val
         pure (MkPData (boundToFC fname (mergeBounds start b)) n ty opts cs)

gadtData : FileName -> Int -> WithBounds t -> Name -> IndentInfo -> Rule PDataDecl
gadtData fname mincol start n indents
    = do symbol ":"
         commit
         ty <- expr pdef fname indents
         dataBody fname mincol start n indents ty

dataDeclBody : FileName -> IndentInfo -> Rule PDataDecl
dataDeclBody fname indents
    = do b <- bounds (do col <- column
                         keyword "data"
                         n <- name
                         pure (col, n))
         (col, n) <- pure b.val
         simpleData fname b n indents <|> gadtData fname col b n indents

dataDecl : FileName -> IndentInfo -> Rule PDecl
dataDecl fname indents
    = do b <- bounds (do doc   <- option "" documentation
                         vis   <- visibility
                         dat   <- dataDeclBody fname indents
                         pure (doc, vis, dat))
         (doc, vis, dat) <- pure b.val
         pure (PData (boundToFC fname b) doc vis dat)

stripBraces : String -> String
stripBraces str = pack (drop '{' (reverse (drop '}' (reverse (unpack str)))))
  where
    drop : Char -> List Char -> List Char
    drop c [] = []
    drop c (c' :: xs) = if c == c' then drop c xs else c' :: xs

onoff : Rule Bool
onoff
   = (exactIdent "on" *> pure True)
 <|> (exactIdent "off" *> pure False)

extension : Rule LangExt
extension
    = (exactIdent "ElabReflection" *> pure ElabReflection)
  <|> (exactIdent "PostfixProjections" *> pure PostfixProjections)
  <|> (exactIdent "Borrowing" *> pure Borrowing)

totalityOpt : Rule TotalReq
totalityOpt
    = (keyword "partial" *> pure PartialOK)
  <|> (keyword "total" *> pure Total)
  <|> (keyword "covering" *> pure CoveringOnly)

directive : FileName -> IndentInfo -> Rule Directive
directive fname indents
    = do pragma "hide"
         n <- name
         atEnd indents
         pure (Hide n)
--   <|> do pragma "hide_export"
--          n <- name
--          atEnd indents
--          pure (Hide True n)
  <|> do pragma "logging"
         lvl <- intLit
         atEnd indents
         pure (Logging (fromInteger lvl))
  <|> do pragma "auto_lazy"
         b <- onoff
         atEnd indents
         pure (LazyOn b)
  <|> do pragma "unbound_implicits"
         b <- onoff
         atEnd indents
         pure (UnboundImplicits b)
  <|> do pragma "ambiguity_depth"
         lvl <- intLit
         atEnd indents
         pure (AmbigDepth (fromInteger lvl))
  <|> do pragma "auto_implicit_depth"
         dpt <- intLit
         atEnd indents
         pure (AutoImplicitDepth (fromInteger dpt))
  <|> do pragma "pair"
         ty <- name
         f <- name
         s <- name
         atEnd indents
         pure (PairNames ty f s)
  <|> do pragma "rewrite"
         eq <- name
         rw <- name
         atEnd indents
         pure (RewriteName eq rw)
  <|> do pragma "integerLit"
         n <- name
         atEnd indents
         pure (PrimInteger n)
  <|> do pragma "stringLit"
         n <- name
         atEnd indents
         pure (PrimString n)
  <|> do pragma "charLit"
         n <- name
         atEnd indents
         pure (PrimChar n)
  <|> do pragma "name"
         n <- name
         ns <- sepBy1 (symbol ",") unqualifiedName
         atEnd indents
         pure (Names n ns)
  <|> do pragma "start"
         e <- expr pdef fname indents
         atEnd indents
         pure (StartExpr e)
  <|> do pragma "allow_overloads"
         n <- name
         atEnd indents
         pure (Overloadable n)
  <|> do pragma "language"
         e <- extension
         atEnd indents
         pure (Extension e)
  <|> do pragma "default"
         tot <- totalityOpt
         atEnd indents
         pure (DefaultTotality tot)

fix : Rule Fixity
fix
    = (keyword "infixl" *> pure InfixL)
  <|> (keyword "infixr" *> pure InfixR)
  <|> (keyword "infix"  *> pure Infix)
  <|> (keyword "prefix" *> pure Prefix)

namespaceHead : Rule (List1 String)
namespaceHead = keyword "namespace" *> commit *> namespacedIdent

namespaceDecl : FileName -> IndentInfo -> Rule PDecl
namespaceDecl fname indents
    = do b <- bounds (do doc   <- option "" documentation
                         col   <- column
                         ns    <- namespaceHead
                         ds    <- blockAfter col (topDecl fname)
                         pure (doc, ns, ds))
         (doc, ns, ds) <- pure b.val
         pure (PNamespace (boundToFC fname b) (List1.toList ns) (concat ds))

transformDecl : FileName -> IndentInfo -> Rule PDecl
transformDecl fname indents
    = do b <- bounds (do pragma "transform"
                         n <- strLit
                         lhs <- expr plhs fname indents
                         symbol "="
                         rhs <- expr pnowith fname indents
                         pure (n, lhs, rhs))
         (n, lhs, rhs) <- pure b.val
         pure (PTransform (boundToFC fname b) n lhs rhs)

runElabDecl : FileName -> IndentInfo -> Rule PDecl
runElabDecl fname indents
    = do tm <- bounds (pragma "runElab" *> expr pnowith fname indents)
         pure (PRunElabDecl (boundToFC fname tm) tm.val)

mutualDecls : FileName -> IndentInfo -> Rule PDecl
mutualDecls fname indents
    = do ds <- bounds (keyword "mutual" *> commit *> assert_total (nonEmptyBlock (topDecl fname)))
         pure (PMutual (boundToFC fname ds) (concat ds.val))

paramDecls : FileName -> IndentInfo -> Rule PDecl
paramDecls fname indents
    = do b <- bounds (do keyword "parameters"
                         commit
                         symbol "("
                         ps <- sepBy (symbol ",")
                                     (do x <- unqualifiedName
                                         symbol ":"
                                         ty <- typeExpr pdef fname indents
                                         pure (UN x, ty))
                         symbol ")"
                         ds <- assert_total (nonEmptyBlock (topDecl fname))
                         pure (ps, ds))
         (ps, ds) <- pure b.val
         pure (PParameters (boundToFC fname b) ps (collectDefs (concat ds)))

usingDecls : FileName -> IndentInfo -> Rule PDecl
usingDecls fname indents
    = do b <- bounds (do keyword "using"
                         commit
                         symbol "("
                         us <- sepBy (symbol ",")
                                     (do n <- option Nothing
                                                (do x <- unqualifiedName
                                                    symbol ":"
                                                    pure (Just (UN x)))
                                         ty <- typeExpr pdef fname indents
                                         pure (n, ty))
                         symbol ")"
                         ds <- assert_total (nonEmptyBlock (topDecl fname))
                         pure (us, ds))
         (us, ds) <- pure b.val
         pure (PUsing (boundToFC fname b) us (collectDefs (concat ds)))

fnOpt : Rule PFnOpt
fnOpt = do x <- totalityOpt
           pure $ IFnOpt (Totality x)

fnDirectOpt : FileName -> Rule PFnOpt
fnDirectOpt fname
    = do pragma "hint"
         pure $ IFnOpt (Hint True)
  <|> do pragma "globalhint"
         pure $ IFnOpt (GlobalHint False)
  <|> do pragma "defaulthint"
         pure $ IFnOpt (GlobalHint True)
  <|> do pragma "inline"
         commit
         pure $ IFnOpt Inline
  <|> do pragma "tcinline"
         commit
         pure $ IFnOpt TCInline
  <|> do pragma "extern"
         pure $ IFnOpt ExternFn
  <|> do pragma "macro"
         pure $ IFnOpt Macro
  <|> do pragma "spec"
         ns <- sepBy (symbol ",") name
         pure $ IFnOpt (SpecArgs ns)
  <|> do pragma "foreign"
         cs <- block (expr pdef fname)
         pure $ PForeign cs

visOpt : FileName -> Rule (Either Visibility PFnOpt)
visOpt fname
    = do vis <- visOption
         pure (Left vis)
  <|> do tot <- fnOpt
         pure (Right tot)
  <|> do opt <- fnDirectOpt fname
         pure (Right opt)

getVisibility : Maybe Visibility -> List (Either Visibility PFnOpt) ->
               SourceEmptyRule Visibility
getVisibility Nothing [] = pure Private
getVisibility (Just vis) [] = pure vis
getVisibility Nothing (Left x :: xs) = getVisibility (Just x) xs
getVisibility (Just vis) (Left x :: xs)
   = fatalError "Multiple visibility modifiers"
getVisibility v (_ :: xs) = getVisibility v xs

getRight : Either a b -> Maybe b
getRight (Left _) = Nothing
getRight (Right v) = Just v

constraints : FileName -> IndentInfo -> SourceEmptyRule (List (Maybe Name, PTerm))
constraints fname indents
    = do tm <- appExpr pdef fname indents
         symbol "=>"
         more <- constraints fname indents
         pure ((Nothing, tm) :: more)
  <|> do symbol "("
         n <- name
         symbol ":"
         tm <- expr pdef fname indents
         symbol ")"
         symbol "=>"
         more <- constraints fname indents
         pure ((Just n, tm) :: more)
  <|> pure []

implBinds : FileName -> IndentInfo -> SourceEmptyRule (List (Name, RigCount, PTerm))
implBinds fname indents
    = do symbol "{"
         m <- multiplicity
         rig <- getMult m
         n <- name
         symbol ":"
         tm <- expr pdef fname indents
         symbol "}"
         symbol "->"
         more <- implBinds fname indents
         pure ((n, rig, tm) :: more)
  <|> pure []

ifaceParam : FileName -> IndentInfo -> Rule (Name, PTerm)
ifaceParam fname indents
    = do symbol "("
         n <- name
         symbol ":"
         tm <- expr pdef fname indents
         symbol ")"
         pure (n, tm)
  <|> do n <- bounds name
         pure (n.val, PInfer (boundToFC fname n))

ifaceDecl : FileName -> IndentInfo -> Rule PDecl
ifaceDecl fname indents
    = do b <- bounds (do doc   <- option "" documentation
                         vis   <- visibility
                         col   <- column
                         keyword "interface"
                         commit
                         cons   <- constraints fname indents
                         n      <- name
                         params <- many (ifaceParam fname indents)
                         det    <- option []
                                     (do symbol "|"
                                         sepBy (symbol ",") name)
                         keyword "where"
                         dc <- option Nothing
                                 (do exactIdent "constructor"
                                     n <- name
                                     pure (Just n))
                         body <- assert_total (blockAfter col (topDecl fname))
                         pure (\fc : FC => PInterface fc
                                      vis cons n doc params det dc (collectDefs (concat body))))
         pure (b.val (boundToFC fname b))

implDecl : FileName -> IndentInfo -> Rule PDecl
implDecl fname indents
    = do b <- bounds (do doc     <- option "" documentation
                         visOpts <- many (visOpt fname)
                         vis     <- getVisibility Nothing visOpts
                         let opts = mapMaybe getRight visOpts
                         col <- column
                         option () (keyword "implementation")
                         iname <- option Nothing (do symbol "["
                                                     iname <- name
                                                     symbol "]"
                                                     pure (Just iname))
                         impls  <- implBinds fname indents
                         cons   <- constraints fname indents
                         n      <- name
                         params <- many (simpleExpr fname indents)
                         nusing <- option [] (do keyword "using"
                                                 names <- some name
                                                 pure names)
                         body <- optional (do keyword "where"
                                              blockAfter col (topDecl fname))
                         pure $ \fc : FC =>
                            (PImplementation fc vis opts Single impls cons n params iname nusing
                                             (map (collectDefs . concat) body)))
         atEnd indents
         pure (b.val (boundToFC fname b))

fieldDecl : FileName -> IndentInfo -> Rule (List PField)
fieldDecl fname indents
      = do doc <- option "" documentation
           symbol "{"
           commit
           fs <- fieldBody doc Implicit
           symbol "}"
           atEnd indents
           pure fs
    <|> do doc <- option "" documentation
           fs <- fieldBody doc Explicit
           atEnd indents
           pure fs
  where
    fieldBody : String -> PiInfo PTerm -> Rule (List PField)
    fieldBody doc p
        = do b <- bounds (do m <- multiplicity
                             rigin <- getMult m
                             let rig = if isErased rigin then erased else linear
                             ns <- sepBy1 (symbol ",") name
                             symbol ":"
                             ty <- expr pdef fname indents
                             pure (\fc : FC => map (\n => MkField fc doc rig p n ty) ns))
             pure (b.val (boundToFC fname b))

recordParam : FileName -> IndentInfo -> Rule (List (Name, RigCount, PiInfo PTerm,  PTerm))
recordParam fname indents
    = do symbol "("
         params <- pibindListName fname indents
         symbol ")"
         pure $ map (\(c, n, tm) => (n, c, Explicit, tm)) params
  <|> do symbol "{"
         commit
         info <- the (SourceEmptyRule (PiInfo PTerm))
                 (pure  AutoImplicit <* keyword "auto"
              <|>(do
                  keyword "default"
                  t <- simpleExpr fname indents
                  pure $ DefImplicit t)
              <|> pure      Implicit)
         params <- pibindListName fname indents
         symbol "}"
         pure $ map (\(c, n, tm) => (n, c, info, tm)) params
  <|> do n <- bounds name
         pure [(n.val, top, Explicit, PInfer (boundToFC fname n))]

recordDecl : FileName -> IndentInfo -> Rule PDecl
recordDecl fname indents
    = do b <- bounds (do doc   <- option "" documentation
                         vis   <- visibility
                         col   <- column
                         keyword "record"
                         n       <- name
                         paramss <- many (recordParam fname indents)
                         let params = concat paramss
                         keyword "where"
                         dcflds <- blockWithOptHeaderAfter col ctor (fieldDecl fname)
                         pure (\fc : FC => PRecord fc doc vis n params (fst dcflds) (concat (snd dcflds))))
         pure (b.val (boundToFC fname b))
  where
  ctor : IndentInfo -> Rule Name
  ctor idt = do exactIdent "constructor"
                n <- name
                atEnd idt
                pure n

claim : FileName -> IndentInfo -> Rule PDecl
claim fname indents
    = do b <- bounds (do doc     <- option "" documentation
                         visOpts <- many (visOpt fname)
                         vis     <- getVisibility Nothing visOpts
                         let opts = mapMaybe getRight visOpts
                         m   <- multiplicity
                         rig <- getMult m
                         cl  <- tyDecl doc fname indents
                         pure (doc, vis, opts, rig, cl))
         (doc, vis, opts, rig, cl) <- pure b.val
         pure (PClaim (boundToFC fname b) rig vis opts cl)

definition : FileName -> IndentInfo -> Rule PDecl
definition fname indents
    = do nd <- bounds (clause 0 fname indents)
         pure (PDef (boundToFC fname nd) [nd.val])

fixDecl : FileName -> IndentInfo -> Rule (List PDecl)
fixDecl fname indents
    = do b <- bounds (do fixity <- fix
                         commit
                         prec <- intLit
                         ops <- sepBy1 (symbol ",") iOperator
                         pure (fixity, prec, ops))
         (fixity, prec, ops) <- pure b.val
         pure (map (PFixity (boundToFC fname b) fixity (fromInteger prec)) ops)

directiveDecl : FileName -> IndentInfo -> Rule PDecl
directiveDecl fname indents
    = do b <- bounds ((do d <- directive fname indents
                          pure (\fc : FC => PDirective fc d))
                     <|>
                      (do pragma "runElab"
                          tm <- expr pdef fname indents
                          atEnd indents
                          pure (\fc : FC => PReflect fc tm)))
         pure (b.val (boundToFC fname b))

-- Declared at the top
-- topDecl : FileName -> IndentInfo -> Rule (List PDecl)
topDecl fname indents
    = do d <- dataDecl fname indents
         pure [d]
  <|> do d <- claim fname indents
         pure [d]
  <|> do d <- definition fname indents
         pure [d]
  <|> fixDecl fname indents
  <|> do d <- ifaceDecl fname indents
         pure [d]
  <|> do d <- implDecl fname indents
         pure [d]
  <|> do d <- recordDecl fname indents
         pure [d]
  <|> do d <- namespaceDecl fname indents
         pure [d]
  <|> do d <- mutualDecls fname indents
         pure [d]
  <|> do d <- paramDecls fname indents
         pure [d]
  <|> do d <- usingDecls fname indents
         pure [d]
  <|> do d <- runElabDecl fname indents
         pure [d]
  <|> do d <- transformDecl fname indents
         pure [d]
  <|> do d <- directiveDecl fname indents
         pure [d]
  <|> do dstr <- bounds (terminal "Expected CG directive"
                          (\x => case x.val of
                                      CGDirective d => Just d
                                      _ => Nothing))
         pure [let cgrest = span isAlphaNum dstr.val in
                   PDirective (boundToFC fname dstr)
                        (CGAction (fst cgrest) (stripBraces (trim (snd cgrest))))]
  <|> fatalError "Couldn't parse declaration"

-- All the clauses get parsed as one-clause definitions. Collect any
-- neighbouring clauses into one definition. This might mean merging two
-- functions which are different, if there are forward declarations,
-- but we'll split them in Desugar.idr. We can't do this now, because we
-- haven't resolved operator precedences yet.
-- Declared at the top.
-- collectDefs : List PDecl -> List PDecl
collectDefs [] = []
collectDefs (PDef annot cs :: ds)
    = let (cs', rest) = spanMap isClause ds in
          PDef annot (cs ++ cs') :: assert_total (collectDefs rest)
  where
    spanMap : (a -> Maybe (List b)) -> List a -> (List b, List a)
    spanMap f [] = ([], [])
    spanMap f (x :: xs) = case f x of
                               Nothing => ([], x :: xs)
                               Just y => case spanMap f xs of
                                              (ys, zs) => (y ++ ys, zs)

    isClause : PDecl -> Maybe (List PClause)
    isClause (PDef annot cs)
        = Just cs
    isClause _ = Nothing
collectDefs (PNamespace annot ns nds :: ds)
    = PNamespace annot ns (collectDefs nds) :: collectDefs ds
collectDefs (PMutual annot nds :: ds)
    = PMutual annot (collectDefs nds) :: collectDefs ds
collectDefs (d :: ds)
    = d :: collectDefs ds

export
import_ : FileName -> IndentInfo -> Rule Import
import_ fname indents
    = do b <- bounds (do keyword "import"
                         reexp <- option False (do keyword "public"
                                                   pure True)
                         ns <- namespacedIdent
                         nsAs <- option ns (do exactIdent "as"
                                               namespacedIdent)
                         pure (reexp, ns, nsAs))
         atEnd indents
         (reexp, ns, nsAs) <- pure b.val
         pure (MkImport (boundToFC fname b) reexp (List1.toList ns) (List1.toList nsAs))

export
prog : FileName -> SourceEmptyRule Module
prog fname
    = do b <- bounds (do doc    <- option "" documentation
                         nspace <- option ["Main"]
                                     (do keyword "module"
                                         namespacedIdent)
                         imports <- block (import_ fname)
                         pure (doc, nspace, imports))
         ds      <- block (topDecl fname)
         (doc, nspace, imports) <- pure b.val
         pure (MkModule (boundToFC fname b)
                        (List1.toList nspace) imports doc (collectDefs (concat ds)))

export
progHdr : FileName -> SourceEmptyRule Module
progHdr fname
    = do b <- bounds (do doc    <- option "" documentation
                         nspace <- option ["Main"]
                                     (do keyword "module"
                                         namespacedIdent)
                         imports <- block (import_ fname)
                         pure (doc, nspace, imports))
         (doc, nspace, imports) <- pure b.val
         pure (MkModule (boundToFC fname b)
                        (List1.toList nspace) imports doc [])

parseMode : Rule REPLEval
parseMode
     = do exactIdent "typecheck"
          pure EvalTC
   <|> do exactIdent "tc"
          pure EvalTC
   <|> do exactIdent "normalise"
          pure NormaliseAll
   <|> do exactIdent "normalize" -- oh alright then
          pure NormaliseAll
   <|> do exactIdent "execute"
          pure Execute
   <|> do exactIdent "exec"
          pure Execute

setVarOption : Rule REPLOpt
setVarOption
    = do exactIdent "eval"
         mode <- parseMode
         pure (EvalMode mode)
  <|> do exactIdent "editor"
         e <- unqualifiedName
         pure (Editor e)
  <|> do exactIdent "cg"
         c <- unqualifiedName
         pure (CG c)

setOption : Bool -> Rule REPLOpt
setOption set
    = do exactIdent "showimplicits"
         pure (ShowImplicits set)
  <|> do exactIdent "shownamespace"
         pure (ShowNamespace set)
  <|> do exactIdent "showtypes"
         pure (ShowTypes set)
  <|> if set then setVarOption else fatalError "Unrecognised option"

replCmd : List String -> Rule ()
replCmd [] = fail "Unrecognised command"
replCmd (c :: cs)
    = exactIdent c
  <|> symbol c
  <|> replCmd cs

export
editCmd : Rule EditCmd
editCmd
    = do replCmd ["typeat"]
         line <- intLit
         col <- intLit
         n <- name
         pure (TypeAt (fromInteger line) (fromInteger col) n)
  <|> do replCmd ["cs"]
         upd <- option False (symbol "!" *> pure True)
         line <- intLit
         col <- intLit
         n <- name
         pure (CaseSplit upd (fromInteger line) (fromInteger col) n)
  <|> do replCmd ["ac"]
         upd <- option False (symbol "!" *> pure True)
         line <- intLit
         n <- name
         pure (AddClause upd (fromInteger line) n)
  <|> do replCmd ["ps", "proofsearch"]
         upd <- option False (symbol "!" *> pure True)
         line <- intLit
         n <- name
         pure (ExprSearch upd (fromInteger line) n [])
  <|> do replCmd ["psnext"]
         pure ExprSearchNext
  <|> do replCmd ["gd"]
         upd <- option False (symbol "!" *> pure True)
         line <- intLit
         n <- name
         nreject <- option 0 intLit
         pure (GenerateDef upd (fromInteger line) n (fromInteger nreject))
  <|> do replCmd ["gdnext"]
         pure GenerateDefNext
  <|> do replCmd ["ml", "makelemma"]
         upd <- option False (symbol "!" *> pure True)
         line <- intLit
         n <- name
         pure (MakeLemma upd (fromInteger line) n)
  <|> do replCmd ["mc", "makecase"]
         upd <- option False (symbol "!" *> pure True)
         line <- intLit
         n <- name
         pure (MakeCase upd (fromInteger line) n)
  <|> do replCmd ["mw", "makewith"]
         upd <- option False (symbol "!" *> pure True)
         line <- intLit
         n <- name
         pure (MakeWith upd (fromInteger line) n)
  <|> fatalError "Unrecognised command"

export
data CmdArg : Type where
     ||| The command takes no arguments.
     NoArg : CmdArg

     ||| The command takes a name.
     NameArg : CmdArg

     ||| The command takes an expression.
     ExprArg : CmdArg

     ||| The command takes a list of declarations
     DeclsArg : CmdArg

     ||| The command takes a number.
     NumberArg : CmdArg

     ||| The command takes a number or auto.
     AutoNumberArg : CmdArg

     ||| The command takes an option.
     OptionArg : CmdArg

     ||| The command takes a file.
     FileArg : CmdArg

     ||| The command takes a module.
     ModuleArg : CmdArg

     ||| The command takes a string
     StringArg : CmdArg

     ||| The command takes a on or off.
     OnOffArg : CmdArg

     ||| The command takes multiple arguments.
     Args : List CmdArg -> CmdArg

export
Show CmdArg where
  show NoArg = ""
  show NameArg = "<name>"
  show ExprArg = "<expr>"
  show DeclsArg = "<decls>"
  show NumberArg = "<number>"
  show AutoNumberArg = "<number|auto>"
  show OptionArg = "<option>"
  show FileArg = "<file>"
  show ModuleArg = "<module>"
  show StringArg = "<module>"
  show OnOffArg = "(on|off)"
  show (Args args) = showSep " " (map show args)

export
data ParseCmd : Type where
     ParseREPLCmd : List String -> ParseCmd
     ParseKeywordCmd : String -> ParseCmd
     ParseIdentCmd : String -> ParseCmd

CommandDefinition : Type
CommandDefinition = (List String, CmdArg, String, Rule REPLCmd)

CommandTable : Type
CommandTable = List CommandDefinition

extractNames : ParseCmd -> List String
extractNames (ParseREPLCmd names) = names
extractNames (ParseKeywordCmd keyword) = [keyword]
extractNames (ParseIdentCmd ident) = [ident]

runParseCmd : ParseCmd -> Rule ()
runParseCmd (ParseREPLCmd names) = replCmd names
runParseCmd (ParseKeywordCmd keyword') = keyword keyword'
runParseCmd (ParseIdentCmd ident) = exactIdent ident

noArgCmd : ParseCmd -> REPLCmd -> String -> CommandDefinition
noArgCmd parseCmd command doc = (names, NoArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      pure command

nameArgCmd : ParseCmd -> (Name -> REPLCmd) -> String -> CommandDefinition
nameArgCmd parseCmd command doc = (names, NameArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      n <- name
      pure (command n)

stringArgCmd : ParseCmd -> (String -> REPLCmd) -> String -> CommandDefinition
stringArgCmd parseCmd command doc = (names, StringArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      s <- strLit
      pure (command s)

moduleArgCmd : ParseCmd -> (List String -> REPLCmd) -> String -> CommandDefinition
moduleArgCmd parseCmd command doc = (names, ModuleArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      n <- moduleIdent
      pure (command (List1.toList n))

exprArgCmd : ParseCmd -> (PTerm -> REPLCmd) -> String -> CommandDefinition
exprArgCmd parseCmd command doc = (names, ExprArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      tm <- expr pdef "(interactive)" init
      pure (command tm)

declsArgCmd : ParseCmd -> (List PDecl -> REPLCmd) -> String -> CommandDefinition
declsArgCmd parseCmd command doc = (names, DeclsArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd
    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      tm <- topDecl "(interactive)" init
      pure (command tm)

optArgCmd : ParseCmd -> (REPLOpt -> REPLCmd) -> Bool -> String -> CommandDefinition
optArgCmd parseCmd command set doc = (names, OptionArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      opt <- setOption set
      pure (command opt)

numberArgCmd : ParseCmd -> (Nat -> REPLCmd) -> String -> CommandDefinition
numberArgCmd parseCmd command doc = (names, NumberArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      i <- intLit
      pure (command (fromInteger i))

autoNumberArgCmd : ParseCmd -> (Maybe Nat -> REPLCmd) -> String -> CommandDefinition
autoNumberArgCmd parseCmd command doc = (names, AutoNumberArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      (do keyword "auto"; pure (command Nothing)) <|> (do i <- intLit; pure (command (Just (fromInteger i))))

onOffArgCmd : ParseCmd -> (Bool -> REPLCmd) -> String -> CommandDefinition
onOffArgCmd parseCmd command doc = (names, OnOffArg, doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      i <- onOffLit
      pure (command i)

compileArgsCmd : ParseCmd -> (PTerm -> String -> REPLCmd) -> String -> CommandDefinition
compileArgsCmd parseCmd command doc
    = (names, Args [FileArg, ExprArg], doc, parse)
  where
    names : List String
    names = extractNames parseCmd

    parse : Rule REPLCmd
    parse = do
      symbol ":"
      runParseCmd parseCmd
      n <- unqualifiedName
      tm <- expr pdef "(interactive)" init
      pure (command tm n)

parserCommandsForHelp : CommandTable
parserCommandsForHelp =
  [ exprArgCmd (ParseREPLCmd ["t", "type"]) Check "Check the type of an expression"
  , nameArgCmd (ParseREPLCmd ["printdef"]) PrintDef "Show the definition of a function"
  , nameArgCmd (ParseREPLCmd ["s", "search"]) ProofSearch "Search for values by type"
  , nameArgCmd (ParseIdentCmd "di") DebugInfo "Show debugging information for a name"
  , moduleArgCmd (ParseKeywordCmd "module") ImportMod "Import an extra module"
  , noArgCmd (ParseREPLCmd ["q", "quit", "exit"]) Quit "Exit the Idris system"
  , noArgCmd (ParseREPLCmd ["cwd"]) CWD "Displays the current working directory"
  , optArgCmd (ParseIdentCmd "set") SetOpt True "Set an option"
  , optArgCmd (ParseIdentCmd "unset") SetOpt False "Unset an option"
  , compileArgsCmd (ParseREPLCmd ["c", "compile"]) Compile "Compile to an executable"
  , exprArgCmd (ParseIdentCmd "exec") Exec "Compile to an executable and run"
  , stringArgCmd (ParseIdentCmd "directive") CGDirective "Set a codegen-specific directive"
  , noArgCmd (ParseREPLCmd ["r", "reload"]) Reload "Reload current file"
  , noArgCmd (ParseREPLCmd ["e", "edit"]) Edit "Edit current file using $EDITOR or $VISUAL"
  , nameArgCmd (ParseREPLCmd ["miss", "missing"]) Missing "Show missing clauses"
  , nameArgCmd (ParseKeywordCmd "total") Total "Check the totality of a name"
  , nameArgCmd (ParseIdentCmd "doc") Doc "Show documentation for a name"
  , moduleArgCmd (ParseIdentCmd "browse") Browse "Browse contents of a namespace"
  , numberArgCmd (ParseREPLCmd ["log", "logging"]) SetLog "Set logging level"
  , autoNumberArgCmd (ParseREPLCmd ["consolewidth"]) SetConsoleWidth "Set the width of the console output (0 for unbounded) (auto by default)"
  , onOffArgCmd (ParseREPLCmd ["color", "colour"]) SetColor "Whether to use color for the console output (enabled by default)"
  , noArgCmd (ParseREPLCmd ["m", "metavars"]) Metavars "Show remaining proof obligations (metavariables or holes)"
  , noArgCmd (ParseREPLCmd ["version"]) ShowVersion "Display the Idris version"
  , noArgCmd (ParseREPLCmd ["?", "h", "help"]) Help "Display this help text"
  , declsArgCmd (ParseKeywordCmd "let") NewDefn "Define a new value"
  ]

export
help : List (List String, CmdArg, String)
help = (["<expr>"], NoArg, "Evaluate an expression") ::
         map (\ (names, args, text, _) =>
               (map (":" ++) names, args, text)) parserCommandsForHelp

nonEmptyCommand : Rule REPLCmd
nonEmptyCommand =
  choice (map (\ (_, _, _, parser) => parser) parserCommandsForHelp)

eval : Rule REPLCmd
eval = do
  tm <- expr pdef "(interactive)" init
  pure (Eval tm)

export
command : SourceEmptyRule REPLCmd
command
    = do eoi
         pure NOP
  <|> nonEmptyCommand
  <|> do symbol ":?"; pure Help -- special case, :? doesn't fit into above scheme
  <|> do symbol ":"; cmd <- editCmd
         pure (Editing cmd)
  <|> eval
