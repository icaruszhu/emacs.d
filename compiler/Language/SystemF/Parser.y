{
{-# LANGUAGE RankNTypes #-}

module Language.SystemF.Parser where

-- References:
-- http://www.haskell.org/onlinereport/exps.html

import Data.Maybe       (fromMaybe)
import qualified Data.Map as Map

import qualified Language.Java.Syntax as J (Op (..))

import Language.SystemF.Syntax
import Language.SystemF.Lexer
import Language.SystemF.TypeCheck       (infer, unsafeGeneralize)
}

%name parser
%tokentype  { Token }
%error      { parseError }

%token

    "("      { OParen }
    ")"      { CParen }
    "/\\"    { TLam }
    "\\"     { Lam }
    ":"      { Colon }
    "forall" { Forall }
    "->"     { Arrow }
    "."      { Dot }
    "let"    { Let }
    "rec"    { Rec }
    "="      { Eq }
    "and"    { And }
    "in"     { In }
    "fix"    { Fix }
    "Int"    { TyInt }
    "if0"    { If0 }
    "then"   { Then }
    "else"   { Else }
    ","      { Comma }

    "*"      { PrimOp J.Mult   }
    "/"      { PrimOp J.Div    }
    "%"      { PrimOp J.Rem    }
    "+"      { PrimOp J.Add    }
    "-"      { PrimOp J.Sub    }
    "<"      { PrimOp J.LThan  }
    "<="     { PrimOp J.LThanE }
    ">"      { PrimOp J.GThan  }
    ">="     { PrimOp J.GThanE }
    "=="     { PrimOp J.Equal  }
    "!="     { PrimOp J.NotEq  }
    "&&"     { PrimOp J.CAnd   }
    "||"     { PrimOp J.COr    }

    INTEGER  { Integer $$ }
    UPPERID  { UpperId $$ }
    LOWERID  { LowerId $$ }
    UNDERID  { UnderId $$ }

-- Precedence and associativity directives
%nonassoc EOF

%right "in"
%right "->"
%nonassoc "else"

-- http://en.wikipedia.org/wiki/Order_of_operations#Programming_languages
%left "||"
%left "&&"
%nonassoc "==" "!="
%nonassoc "<" "<=" ">" ">="
%left "+" "-"
%left "*" "/" "%"
%nonassoc UMINUS

%%

-- Reference for rules:
-- https://github.com/ghc/ghc/blob/master/compiler/parser/Parser.y.pp#L1453

exp : infixexp %prec EOF        { $1 }

infixexp
    : exp10                     { $1 }
    | infixexp "*"  infixexp    { \e -> FPrimOp ($1 e) J.Mult   ($3 e) }
    | infixexp "/"  infixexp    { \e -> FPrimOp ($1 e) J.Div    ($3 e) }
    | infixexp "%"  infixexp    { \e -> FPrimOp ($1 e) J.Rem    ($3 e) }
    | infixexp "+"  infixexp    { \e -> FPrimOp ($1 e) J.Add    ($3 e) }
    | infixexp "-"  infixexp    { \e -> FPrimOp ($1 e) J.Sub    ($3 e) }
    | infixexp "<"  infixexp    { \e -> FPrimOp ($1 e) J.LThan  ($3 e) }
    | infixexp "<=" infixexp    { \e -> FPrimOp ($1 e) J.LThanE ($3 e) }
    | infixexp ">"  infixexp    { \e -> FPrimOp ($1 e) J.GThan  ($3 e) }
    | infixexp ">=" infixexp    { \e -> FPrimOp ($1 e) J.GThanE ($3 e) }
    | infixexp "==" infixexp    { \e -> FPrimOp ($1 e) J.Equal  ($3 e) }
    | infixexp "!=" infixexp    { \e -> FPrimOp ($1 e) J.NotEq  ($3 e) }
    | infixexp "&&" infixexp    { \e -> FPrimOp ($1 e) J.CAnd   ($3 e) }
    | infixexp "||" infixexp    { \e -> FPrimOp ($1 e) J.COr    ($3 e) }

exp10
    : "/\\" tvar "." exp                { \(tenv, env, i) -> FBLam (\a -> $4 (Map.insert $2 a tenv, env, i)) }
    | "\\" "(" var ":" typ ")" "." exp  { \(tenv, env, i) -> FLam ($5 tenv) (\x -> $8 (tenv, Map.insert $3 x env, i)) }

    --    let x = e1 : T in e2
    -- ~> (\(x : T). e2) e1

    | "let" var "=" exp ":" typ "in" exp
        { \(tenv, env, i) -> FApp (FLam ($6 tenv) (\x -> $8 (tenv, Map.insert $2 x env, i))) ($4 (tenv, env, i)) }

    --    let x = e1 in e2
    -- ~> (\(x : (infer e1)). e2) e1

    | "let" var{-2-} "=" exp "in" exp{-6-}
        { \(tenv, env, i) ->
            let e1 = $4 (tenv, env, i) in
            FApp (FLam (infer i e1) (\x -> $6 (tenv, Map.insert $2 x env, i))) e1
        }

    {- De-sugar of let-rec without mutual recursion

            let rec f A1 ... An (x1 : T1) ... (xn : Tn) : T(n+1) = e1 in e2
        ~~> let f = /\A1. ... /\An. (fix (f : T1 -> T2 -> ... -> Tn -> T(n+1)). \x1. (\(x2 : T2). ... \(xn : Tn). e1)) in e2
                   --------------------------------------------------------------------------------------------------
        ~~> (\(f : (infer e3). e2) e3
    -}

    | "let" "rec" binding{-3-} "in" exp{-5-}
        { \(tenv, env, i) ->
            let (var, tvars, varannot, varannots, typ, exp) = $3 in
            let e3 = (wrapWithBLams tvars (\(tenv, env, i) ->
                        FFix
                            (\y -> \x -> (wrapWithLams tenv varannots exp)
                                (tenv, (Map.insert (fst varannot) x . Map.insert var y) env, i))
                            ((snd varannot) tenv)
                            (mkFunType tenv (map snd varannots ++ [typ]))
                     )) (tenv, env, i)
            in
            FApp (FLam (infer i e3) (\f -> $5 (tenv, Map.insert var f env, i))) e3
        }

    {- De-sugar of mutually recursive let-rec

             let rec f1 A1_1 ... A1_n (x1_0 : T1_0) (x1_1 : T1_1) ... (x1_n : T1_n) = e1
             and     f2 A2_1 ... A2_n (x2_0 : T2_0) (x2_1 : T2_1) ... (x2_n : T2_n) = e2
             ...
             and     fn An_1 ... An_n (xn_0 : Tn_0) (xn_1 : Tn_1) ... (xn_n : Tn_n) = en
             in
             e

        ~~>  let rec m (dummy : Int) : (sig1, sig2, ..., sign) =
                ( /\A1_1. ... /\A1_n. \(x1_0 : T1_0). \(x1_1 : T1_1). ... \(x1_n : T1_n). e1
                , ...
                , /\An_1. ... /\An_n. \(xn_0 : Tn_0). \(xn_1 : Tn_1). ... \(xn_n : Tn_n). en
                )
            in
            e
            where in the environment:
                f1 |-> (m 0)._0
                f2 |-> (m 0)._1
                ...
                fn |-> (m 0)._(n-1)
    -}

    | "let" "rec" bindings "in" exp { \(tenv, env, i) -> FLit 1 -- TODO }

    -- This syntax is about to replaced by the 'let rec' syntax.
    | "fix" "(" var ":" atyp{-5-} "->" typ{-7-} ")" "." "\\" var "." exp
        { \(tenv, env, i) -> FFix (\y -> \x -> $13 (tenv, (Map.insert $11 x . Map.insert $3 y) env, i)) ($5 tenv) ($7 tenv) }

    | "if0" exp "then" exp "else" exp   { \e -> FIf0 ($2 e) ($4 e) ($6 e) }
    | "-" INTEGER %prec UMINUS          { \e -> FLit (-$2) }
    | fexp                              { $1 }

binding : var tvars varannot varannots ":" typ "=" exp      { ($1, $2, $3, $4, $6, $8) }

bindings
    : binding "and" binding     { [$1, $3] }
    | binding "and" bindings    { $1:$3    }

fexp
    : fexp aexp         { \(tenv, env, i) -> FApp  ($1 (tenv, env, i)) ($2 (tenv, env, i)) }
    | fexp typ          { \(tenv, env, i) -> FTApp ($1 (tenv, env, i)) ($2 tenv) }
    | aexp              { $1 }

aexp   : aexp1          { $1 }

aexp1  : aexp2          { $1 }

aexp2
    : var               { \(tenv, env, i) -> FVar $1 (fromMaybe (error $ "Unbound variable: `" ++ $1 ++ "'") (Map.lookup $1 env)) }
    | INTEGER           { \_e -> FLit $1 }
    | aexp "." UNDERID  { \e -> FProj $3 ($1 e) }
    | "(" exp ")"       { $2 }
    | "(" tup_exprs ")" { \(tenv, env, i) -> FTuple (map ($ (tenv, env, i)) $2) }

tup_exprs
    : exp "," exp       { [$1, $3] }
    | exp "," tup_exprs { $1:$3    }

typ
    : "forall" tvar "." typ     { \tenv -> FForall (\a -> $4 (Map.insert $2 a tenv)) }

    -- Require an atyp on the LHS so that `for A. A -> A` cannot be
    -- parsed as `(for A. A) -> A` since `for A. A` is not a valid atyp.
    | atyp "->" typ             { \tenv -> FFun ($1 tenv) ($3 tenv) }

    | atyp                      { $1 }

atyp
    : tvar              { \tenv -> FTVar (fromMaybe (error $ "Unbound type variable: `" ++ $1 ++ "'") (Map.lookup $1 tenv)) }
    | "Int"             { \_    -> FInt }
    | "(" typ ")"       { $2 }
    | "(" tup_typs ")"  { \tenv -> FProduct (map ($ tenv) $2) }

tup_typs
    : typ "," typ       { $1:[$3] }
    | typ "," tup_typs  { $1:$3   }

var  : LOWERID          { $1 }
tvar : UPPERID          { $1 }

varannot : "(" var ":" typ ")"  { ($2, $4) }

varannots
    : varannot varannots        { $1:$2 }
    | {- empty -}               { [] }

tvars
    : tvar tvars        { $1:$2 }
    | {- empty -}       { []    }

{
wrapWithBLams
    :: forall t e.
        [String]
    -> ((Map.Map String t, Map.Map String e, Int) -> PFExp t e)
    -> ((Map.Map String t, Map.Map String e, Int) -> PFExp t e)
wrapWithBLams []     expr = expr
wrapWithBLams (a:as) expr = \(tenv, env, i) -> FBLam (\x -> (wrapWithBLams as expr) (Map.insert a x tenv, env, i))

wrapWithLams
    :: forall t e.
       Map.Map String t
    -> [(String, Map.Map String t -> PFTyp t)]   -- Annotated types
    -> ((Map.Map String t, Map.Map String e, Int) -> PFExp t e)
    -> ((Map.Map String t, Map.Map String e, Int) -> PFExp t e)
wrapWithLams tenv []              expr = expr
wrapWithLams tenv ((var, typ):xs) expr = \(tenv, env, i) -> FLam (typ tenv) (\x -> (wrapWithLams tenv xs expr) (tenv, Map.insert var x env, i))

mkFunType :: (Map.Map String t) -> [Map.Map String t -> PFTyp t] -> PFTyp t
mkFunType tenv []     = error "mkFunType: impossible case reached"
mkFunType tenv [t]    = t tenv
mkFunType tenv (t:ts) = FFun (t tenv) (mkFunType tenv ts)

parseError :: [Token] -> a
parseError tokens = error $ "Parse error before tokens:\n\t" ++ show tokens

reader :: String -> PFExp t e
reader = unsafeGeneralize . (\parser -> parser (Map.empty, Map.empty, 0)) . parser . lexer
}
