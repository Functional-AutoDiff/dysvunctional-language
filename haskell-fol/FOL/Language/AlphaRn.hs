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
module FOL.Language.AlphaRn (alphaRn) where

import FOL.Language.Common
import FOL.Language.Expression
import FOL.Language.Unique

import Control.Monad.State
import Control.Applicative

import Data.List
import Data.Maybe

type AlphaRnT = StateT NameList
type NameList = [Name]

evalAlphaRnT :: Monad m => AlphaRnT m a -> m a
evalAlphaRnT = flip evalStateT []

-- Rename a given name if it occurs in a given list of names.
rename :: NameList -> Name -> Unique Name
rename ns n@(Name name)
    | n `elem` ns = uniqueName name
    | otherwise   = return n

-- Record a given list of names as names already seen.
record :: Monad m => NameList -> AlphaRnT m ()
record names = modify (names `union`)

-- Extend a given environment with new bindings.
extend :: [Name] -> [v] -> [(Name, v)] -> [(Name, v)]
extend xs vs env = zip xs vs ++ env

alphaRnExpr :: [(Name, Name)] -> Expr -> AlphaRnT Unique Expr
alphaRnExpr env (Var x) = return (Var x')
    where
      x' = fromMaybe x (lookup x env)
alphaRnExpr _ Nil       = return Nil
alphaRnExpr _ (Bool b)  = return (Bool b)
alphaRnExpr _ (Real r)  = return (Real r)
alphaRnExpr env (If p c a)
    = liftA3 If (alphaRnExpr env p)
                (alphaRnExpr env c)
                (alphaRnExpr env a)
alphaRnExpr env (Let (Bindings bs) body)
    = do seen_names <- get
         xs' <- lift $ mapM (rename seen_names) xs
         record xs
         es' <- mapM (alphaRnExpr env) es
         let env' = extend xs xs' env
         body' <- alphaRnExpr env' body
         let bs' = zip xs' es'
         return (Let (Bindings bs') body')
    where
      (xs, es) = unzip bs
alphaRnExpr env (LetValues (Bindings bs) body)
    = do seen_names <- get
         xs' <- lift $ mapM (mapM (rename seen_names)) xs
         record (concat xs)
         es' <- mapM (alphaRnExpr env) es
         let env' = extend (concat xs) (concat xs') env
         body' <- alphaRnExpr env' body
         let bs' = zip xs' es'
         return (LetValues (Bindings bs') body')
    where
      (xs, es) = unzip bs
alphaRnExpr env (Car e) = Car <$> alphaRnExpr env e
alphaRnExpr env (Cdr e) = Cdr <$> alphaRnExpr env e
alphaRnExpr env (VectorRef e i)
    = liftA2 VectorRef (alphaRnExpr env e) (pure i)
alphaRnExpr env (Cons e1 e2)
    = liftA2 Cons (alphaRnExpr env e1) (alphaRnExpr env e2)
alphaRnExpr env (Vector es) = Vector <$> mapM (alphaRnExpr env) es
alphaRnExpr env (Values es) = Values <$> mapM (alphaRnExpr env) es
alphaRnExpr env (ProcCall proc args)
    = liftA2 ProcCall (pure proc) (mapM (alphaRnExpr env) args)

alphaRnDefn :: [(Name, Name)] -> Defn -> AlphaRnT Unique Defn
alphaRnDefn env (Defn proc args body)
    = do seen_names <- get
         arg_names' <- lift $ mapM (rename seen_names) arg_names
         record (proc_name : arg_names)
         let args' = zip arg_names' arg_shapes
             env'  = extend arg_names arg_names' env
         body' <- alphaRnExpr env' body
         -- We assume here that procedure names are already unique.
         -- Something should check this assumption and signal an
         -- error if it is not satisfied.
         return (Defn proc args' body')
    where
      (proc_name, _) = proc
      (arg_names, arg_shapes) = unzip args

alphaRnProg :: [(Name, Name)] -> Prog -> AlphaRnT Unique Prog
alphaRnProg env (Prog defns expr)
    = liftA2 Prog (mapM (alphaRnDefn env) defns) (alphaRnExpr env expr)

alphaRn :: Prog -> Unique Prog
alphaRn = evalAlphaRnT . alphaRnProg []
