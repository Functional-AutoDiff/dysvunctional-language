-- ----------------------------------------------------------------------
-- Copyright 2010-2011 National University of Ireland.
-- ----------------------------------------------------------------------
-- This file is part of DysVunctional Language.
--
-- DysVunctional Language is free software; you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of the
--  License, or (at your option) any later version.
--
-- DysVunctional Language is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with DysVunctional Language.  If not, see <http://www.gnu.org/licenses/>.
-- ----------------------------------------------------------------------

{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module FOL.Language.Parser where

import FOL.Language.Common
import FOL.Language.Expression
import FOL.Language.Token

import Control.Applicative
import Control.Monad

import Data.Maybe

import Text.Parsec.Prim hiding (many, (<|>), parse)
import Text.ParserCombinators.Parsec.Prim (GenParser)
import Text.ParserCombinators.Parsec.Combinator (between)

-- A custom parser type that accepts streams of 'Token's.
type Parser = GenParser Token ()

-- Parser combinators

-- Accepts a token 't' with the result 'x' when 'test t' is 'Just x'.
-- Like 'token' from Text.Parsec.Prim, but uses the default token
-- pretty-printing function and ignores the position info.
tok :: (Token -> Maybe a) -> Parser a
tok = tokenPrim show (\pos _ _ -> pos)

-- Accepts the token 't' with the result 't'.
lit :: Token -> Parser Token
lit t = tok maybeLiteral
    where
      maybeLiteral x
          | x == t    = Just x
          | otherwise = Nothing

-- Accept a token 't' with the result 'n' when 't' is the symbol 'n'.
sym :: Parser String
sym = tok maybeSymbol
    where
      maybeSymbol (TokSymbol x) = Just x
      maybeSymbol _             = Nothing

-- Parse a symbol, try to match it agains a list of alternatives, and
-- if a match is found, apply the corresponding parser to the rest of
-- the input.
caseParser :: [(String, Parser a)] -> Parser a
caseParser alternatives = fromMaybe empty . flip lookup alternatives =<< sym

-- Literal parens.
lparen, rparen :: Parser Token
lparen = lit TokLParen
rparen = lit TokRParen

-- Accepts a token 't' with the result 'n' when 't' is the symbol 'n'
-- that is not a reserved keyword.
identifier :: Parser Name
identifier = tok maybeIdentifier
    where
      maybeIdentifier (TokSymbol x)
          | x `notElem` reserved = Just (Name x)
          | otherwise            = Nothing
      maybeIdentifier _          = Nothing

-- Accepts a token 't' with the result 'd' when 't' is the real 'd'.
real :: Parser Real
real = tok maybeReal
    where
      maybeReal (TokReal r) = Just r
      maybeReal _           = Nothing

-- To parse 'vector-ref's we must be able to parse integers, but I am
-- lazy to modify the tokenizer.  Whenever an integer is expected, it
-- is parsed as a real and is truncated.
int :: Parser Int
int = truncate <$> real

-- Helper combinators and aliases for better readability.

parens :: Parser a -> Parser a
parens = between lparen rparen

listOf :: Parser a -> Parser [a]
listOf p = parens (many p)

tagged :: String -> Parser a -> Parser a
tagged name body = parens (lit (TokSymbol name) >> body)

-- Empty list can occur both as expressions and as types, so it makes
-- sense to abstract the common bit.
parseEmptyList :: Parser ()
parseEmptyList = void lparen >> void rparen

-- Parsing shapes

parseNilSh, parseConsSh, parseVectorSh, parseValuesSh :: Parser Shape
parseShape :: Parser Shape
parseNilSh    = NilSh <$ parseEmptyList
parseConsSh   = liftA2 ConsSh parseShape parseShape
parseVectorSh = liftA  VectorSh (many parseShape)
parseValuesSh = liftA  ValuesSh (many parseShape)

parseShape = try parseNilSh <|> parseAtomicShape <|> parens parseCompoundShape
    where
      parseAtomicShape
          = caseParser [ ("real",   return RealSh)
                       , ("bool",   return BoolSh)
                       , ("escaping-function", return FunctionSh)
                       ]
      parseCompoundShape
          = caseParser [ ("cons",   parseConsSh  )
                       , ("vector", parseVectorSh)
                       , ("values", parseValuesSh)
                       ]

-- Parsing programs

parseNil :: Parser Expr
parseNil = Nil <$ parseEmptyList

parseVariable :: Parser Expr
parseVariable = Var <$> identifier

parseConstant :: Parser Expr
parseConstant = try parseNil <|> tok maybeConstant
    where
      maybeConstant (TokBool b) = Just (Bool b)
      maybeConstant (TokReal r) = Just (Real r)
      maybeConstant _           = Nothing

-- The list of reserved keywords.
reserved :: [String]
reserved = [ "begin"
           , "define"
           , "if"
           , "let"
           , "let-values"
           , "cons"
           , "vector"
           , "values"
           , "car"
           , "cdr"
           , "vector-ref"
           ]

parseDefn :: Parser Defn
parseDefn = tagged "define" $ do
              (proc, args) <- parens $ liftA2 (,) identifier (many identifier)
              shapes <- tagged "argument-types" (many parseShape)
              let proc_shape = last shapes
                  arg_shapes = init shapes
              when (length args /= length arg_shapes) (fail "parse error")
              body <- parseExpr
              return $ Defn (proc, proc_shape) (zip args arg_shapes) body

parseIf, parseLet, parseLetValues, parseCar, parseCdr :: Parser Expr
parseVectorRef, parseCons, parseVector, parseValues   :: Parser Expr

parseIf = liftA3 If predicate consequent alternate
    where
      predicate  = parseExpr
      consequent = parseExpr
      alternate  = parseExpr

parseLet = liftA2 Let bindings body
    where
      bindings = Bindings <$> listOf binding
      binding  = parens $ liftA2 (,) pattern expr
      pattern  = identifier
      expr     = parseExpr
      body     = parseExpr

parseLetValues = liftA2 LetValues bindings body
    where
      bindings = Bindings <$> listOf binding
      binding  = parens $ liftA2 (,) pattern expr
      pattern  = listOf identifier
      expr     = parseExpr
      body     = parseExpr

parseCar       = liftA  Car       parseExpr
parseCdr       = liftA  Cdr       parseExpr
parseVectorRef = liftA2 VectorRef parseExpr int
parseCons      = liftA2 Cons      parseExpr parseExpr
parseVector    = liftA  Vector    (many parseExpr)
parseValues    = liftA  Values    (many parseExpr)
parseLambda    = liftA2 Lambda formal parseExpr
    where
      formal = parens identifier

parseSpecialForm, parseApplication :: Parser Expr
parseSpecialForm = caseParser [ ("if"        , parseIf       )
                              , ("let"       , parseLet      )
                              , ("let-values", parseLetValues)
                              , ("cons"      , parseCons     )
                              , ("vector"    , parseVector   )
                              , ("values"    , parseValues   )
                              , ("lambda"    , parseLambda   )
                              , ("car"       , parseCar      )
                              , ("cdr"       , parseCdr      )
                              , ("vector-ref", parseVectorRef)
                              ]
parseApplication = liftA2 ProcCall proc args
    where
      proc = identifier
      args = many parseExpr

parseExpr :: Parser Expr
parseExpr = parseAtom <|> parseList
    where
      parseAtom = parseVariable <|> parseConstant
      parseList = parens $ try parseSpecialForm
                           <|> parseApplication

parseProg :: Parser Prog
parseProg = try (liftA2 Prog (pure []) parseExpr)
            <|> (tagged "begin" parseBegin)
    where
      parseBegin = try (do expr <- parseExpr
                           return $ Prog [] expr)
                   <|> (do defn <- parseDefn
                           Prog defns expr <- parseBegin
                           return $ Prog (defn:defns) expr)

parse :: String -> Prog
parse = either (\_ -> error "parse error") id
      . runParser parseProg () ""
      . tokenize
