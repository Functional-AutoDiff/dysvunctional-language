{-# LANGUAGE NoImplicitPrelude, TypeOperators, MultiParamTypeClasses #-}
module FOL.Optimize.Sra where

import FOL.Language.Common
import FOL.Language.Expression
import FOL.Language.Pretty
import FOL.Language.TypeCheck
import FOL.Language.Unique

import Control.Applicative

data SraExpr
    = SraVar Name
    | SraNil
    | SraBool Bool
    | SraReal Real
    | SraIf SraExpr SraExpr SraExpr
    | SraLetValues (Bindings [Name] SraExpr) SraExpr
    | SraValues [SraExpr]
    | SraProcCall Name [SraExpr]
      deriving (Eq, Show)

instance SraExpr :<: Expr where
    inj (SraVar x)  = Var x
    inj SraNil      = Nil
    inj (SraBool b) = Bool b
    inj (SraReal r) = Real r
    inj (SraIf p c a) = If (inj p) (inj c) (inj a)
    inj (SraLetValues (Bindings bs) body)
        = mkLet bs1 $ mkLetValues bs' (inj body)
        where
          bs1 = [(x,  inj e) | ([x], e)      <- bs]
          bs' = [(xs, inj e) | (xs@(_:_), e) <- bs]
    inj (SraValues es) = Values (map inj es)
    inj (SraProcCall proc args) = ProcCall proc (map inj args)

data SraDefn = SraDefn ShapedName [ShapedName] SraExpr
               deriving (Eq, Show)

instance SraDefn :<: Defn where
    inj (SraDefn proc args body) = Defn proc args (inj body)

data SraProg = SraProg [SraDefn] SraExpr
               deriving (Eq, Show)

instance SraProg :<: Prog where
    inj (SraProg defns expr) = Prog (map inj defns) (inj expr)

annShape :: Shape -> Unique (AnnShape Name)
annShape NilSh  = AnnNilSh  <$> uniqueName "sra"
annShape RealSh = AnnRealSh <$> uniqueName "sra"
annShape BoolSh = AnnBoolSh <$> uniqueName "sra"
annShape (ConsSh s1 s2) = liftA2 AnnConsSh (annShape s1) (annShape s2)
annShape (VectorSh ss)  = AnnVectorSh <$> mapM annShape ss
annShape (ValuesSh ss)  = AnnValuesSh <$> mapM annShape ss

vars :: [Name] -> [SraExpr]
vars = map SraVar

values :: [Name] -> SraExpr
values = SraValues . vars

sraExpr :: [(Name, AnnShape Name)] -> AnnExpr Type -> Unique SraExpr
sraExpr env (_, AnnVar x)
    | Just s <- lookup x env, let xs = annots s
    = return (values xs)
    | otherwise
    = error $ "Unbound variable: " ++ pprint x
sraExpr _ (_, AnnNil)    = return (SraValues [SraNil])
sraExpr _ (_, AnnBool b) = return (SraValues [SraBool b])
sraExpr _ (_, AnnReal r) = return (SraValues [SraReal r])
sraExpr env (_, AnnIf p c a)
    = liftA3 SraIf (sraExpr env p) (sraExpr env c) (sraExpr env a)
sraExpr env (_, AnnLet (Bindings bs) body)
    = do es' <- mapM (sraExpr env) es
         ss' <- mapM annShape ss
         let bs'  = zip xss es'
             xss  = map annots ss'
             env' = zip xs  ss'
         body' <- sraExpr (env' ++ env) body
         return $ SraLetValues (Bindings bs') body'
    where
      (xs, es) = unzip bs
      ss       = [s | (PrimTy s, _) <- es]
sraExpr env (_, AnnLetValues (Bindings bs) body)
    = do es'  <- mapM (sraExpr env) es
         sss' <- mapM (mapM annShape) sss
         let bs'  = zip xss' es'
             xss' = map concat xsss
             xsss = map (map annots) sss'
             env' = zip (concat xss) (concat sss')
         body' <- sraExpr (env' ++ env) body
         return $ SraLetValues (Bindings bs') body'
    where
      (xss, es) = unzip bs
      sss       = [ss | (PrimTy (ValuesSh ss), _) <- es]
sraExpr env (_, AnnCar e)
    = do e'  <- sraExpr env e
         s1' <- annShape s1
         s2' <- annShape s2
         let bs = [(xs1 ++ xs2, e')]
             xs1 = annots s1'
             xs2 = annots s2'
         return $ SraLetValues (Bindings bs) (values xs1)
    where
      (PrimTy (ConsSh s1 s2), _) = e
sraExpr env (_, AnnCdr e)
    = do e'  <- sraExpr env e
         s1' <- annShape s1
         s2' <- annShape s2
         let bs = [(xs1 ++ xs2, e')]
             xs1 = annots s1'
             xs2 = annots s2'
         return $ SraLetValues (Bindings bs) (values xs2)
    where
      (PrimTy (ConsSh s1 s2), _) = e
sraExpr env (_, AnnVectorRef e i)
    = do e' <- sraExpr env e
         ss' <- mapM annShape ss
         let bs = [(concat xss, e')]
             xss = map annots ss'
         return $ SraLetValues (Bindings bs) (values (xss !! i))
    where
      (PrimTy (VectorSh ss), _) = e
sraExpr env (_, AnnCons e1 e2)
    = do e1' <- sraExpr env e1
         e2' <- sraExpr env e2
         s1' <- annShape s1
         s2' <- annShape s2
         let bs  = [(xs1, e1'), (xs2, e2')]
             xs1 = annots s1'
             xs2 = annots s2'
         return $ SraLetValues (Bindings bs) (values (xs1 ++ xs2))
    where
      (PrimTy s1, _) = e1
      (PrimTy s2, _) = e2
sraExpr env (_, AnnVector es)
    = do es' <- mapM (sraExpr env) es
         ss' <- mapM annShape ss
         let bs  = zip xss es'
             xss = map annots ss'
         return $ SraLetValues (Bindings bs) (values (concat xss))
    where
      ss  = [s | (PrimTy s, _) <- es]
sraExpr env (_, AnnValues es)
    = do es' <- mapM (sraExpr env) es
         ss' <- mapM annShape ss
         let bs  = zip xss es'
             xss = map annots ss'
         return $ SraLetValues (Bindings bs) (values (concat xss))
    where
      ss  = [s | (PrimTy s, _) <- es]
sraExpr env (_, AnnProcCall proc args)
    = do args' <- mapM (sraExpr env) args
         ss'   <- mapM annShape ss
         let bs  = zip xss args'
             xss = map annots ss'
         return $ SraLetValues (Bindings bs) (SraProcCall proc (vars (concat xss)))
    where
      ss  = [s | (PrimTy s, _) <- args]

-- The expression argument is expected to have shape (VALUES ss), with
-- the list ss parallel to the annots of the shape argument.
shapeSraExpr :: SraExpr -> AnnShape Name -> Expr
shapeSraExpr e s = mkLetValues [(annots s, inj e)] (exprOfShape s)

-- Given a shape with named primitive parts, construct (using variable
-- with those names) an expression that returns values of that shape
-- when the variables are bound to values of right type.
exprOfShape :: AnnShape Name -> Expr
exprOfShape (AnnNilSh  x)     = Var x
exprOfShape (AnnBoolSh x)     = Var x
exprOfShape (AnnRealSh x)     = Var x
exprOfShape (AnnConsSh s1 s2) = Cons (exprOfShape s1) (exprOfShape s2)
exprOfShape (AnnVectorSh ss)  = Vector (map exprOfShape ss)
exprOfShape (AnnValuesSh ss)  = Values (map exprOfShape ss)

sraDefn :: AnnDefn Type -> Unique SraDefn
sraDefn (_, AnnDefn proc args body)
    = do ss' <- mapM annShape ss
         let args' = concatMap fringe ss'
             env   = zip xs ss'
         body' <- sraExpr env body
         return $ SraDefn proc args' body'
    where
      (xs, ss) = unzip args

sraProg :: AnnProg Type -> Unique SraProg
sraProg (_, AnnProg defns expr)
    = liftA2 SraProg (mapM sraDefn defns) (sraExpr [] expr)

sra :: AnnProg Type -> Unique Prog
sra = liftA inj . sraProg