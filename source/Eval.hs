-- Granule interpreter
{-# LANGUAGE ImplicitParams #-}
module Eval (eval) where

import Syntax.Expr
import Syntax.Pretty
import Syntax.Desugar
import Context
import Utils
import Data.Text (pack, unpack, append)
import qualified Data.Text.IO as Text

import System.IO (hFlush, stdout)
import qualified System.IO as SIO

evalBinOp :: String -> Value -> Value -> Value
evalBinOp "+" (NumInt n1) (NumInt n2) = NumInt (n1 + n2)
evalBinOp "*" (NumInt n1) (NumInt n2) = NumInt (n1 * n2)
evalBinOp "-" (NumInt n1) (NumInt n2) = NumInt (n1 - n2)
evalBinOp "+" (NumFloat n1) (NumFloat n2) = NumFloat (n1 + n2)
evalBinOp "*" (NumFloat n1) (NumFloat n2) = NumFloat (n1 * n2)
evalBinOp "-" (NumFloat n1) (NumFloat n2) = NumFloat (n1 - n2)
evalBinOp "==" (NumInt n) (NumInt m) = Constr (mkId . show $ (n == m)) []
evalBinOp "<=" (NumInt n) (NumInt m) = Constr (mkId . show $ (n <= m)) []
evalBinOp "<" (NumInt n) (NumInt m) = Constr (mkId . show $ (n < m)) []
evalBinOp ">=" (NumInt n) (NumInt m) = Constr (mkId . show $ (n >= m)) []
evalBinOp ">" (NumInt n) (NumInt m) = Constr (mkId . show $ (n > m)) []
evalBinOp "==" (NumFloat n) (NumFloat m) = Constr (mkId . show $ (n == m)) []
evalBinOp "<=" (NumFloat n) (NumFloat m) = Constr (mkId . show $ (n <= m)) []
evalBinOp "<" (NumFloat n) (NumFloat m) = Constr (mkId . show $ (n < m)) []
evalBinOp ">=" (NumFloat n) (NumFloat m) = Constr (mkId . show $ (n >= m)) []
evalBinOp ">" (NumFloat n) (NumFloat m) = Constr (mkId . show $ (n > m)) []
evalBinOp op v1 v2 = error $ "Unknown operator " ++ op
                             ++ " on " ++ show v1 ++ " and " ++ show v2

-- Call-by-value big step semantics
evalIn :: Ctxt Value -> Expr -> IO Value

evalIn _ (Val s (Var v)) | internalName v == "read" = do
    putStr "> "
    hFlush stdout
    val <- Text.getLine
    return $ Pure (Val s (StringLiteral val))

evalIn _ (Val s (Var v)) | internalName v == "readInt" = do
    putStr "> "
    hFlush stdout
    val <- readLn
    return $ Pure (Val s (NumInt val))

evalIn _ (Val _ (Abs p t e)) = return $ Abs p t e

evalIn ctxt (App _ e1 e2) = do
    v1 <- evalIn ctxt e1
    v2 <- evalIn ctxt e2
    case v1 of
      Primitive k -> k v2

      Abs p _ e3 -> do
        p <- pmatch ctxt [(p, e3)] v2
        case p of
          Just (e3, bindings) -> evalIn ctxt (applyBindings bindings e3)

      Constr c vs -> do
        return $ Constr c (vs ++ [v2])

      _ -> error $ show v1
      -- _ -> error "Cannot apply value"

evalIn ctxt (Binop _ op e1 e2) = do
     v1 <- evalIn ctxt e1
     v2 <- evalIn ctxt e2
     return $ evalBinOp op v1 v2

evalIn ctxt (LetDiamond _ p _ e1 e2) = do
     v1 <- evalIn ctxt e1
     case v1 of
       Pure e -> do
         v1' <- evalIn ctxt e
         p  <- pmatch ctxt [(p, e2)] v1'
         case p of
           Just (e2, bindings) -> evalIn ctxt (applyBindings bindings e2)
       other -> fail $ "Runtime exception: Expecting a diamonad value bug got: "
                      ++ pretty other

evalIn _ (Val _ (Var v)) | internalName v == "scale" = return
  (Abs (PVar nullSpan $ mkId " x") Nothing (Val nullSpan
    (Abs (PVar nullSpan $ mkId " y") Nothing (
      letBox nullSpan (PVar nullSpan $ mkId " ye")
         (Val nullSpan (Var (mkId " y")))
         (Binop nullSpan
           "*" (Val nullSpan (Var (mkId " x"))) (Val nullSpan (Var (mkId " ye"))))))))

evalIn ctxt (Val _ (Var x)) =
    case lookup x ctxt of
      Just val -> return val
      Nothing  -> fail $ "Variable '" ++ sourceName x ++ "' is undefined in context."

evalIn ctxt (Val s (Pair l r)) = do
  l' <- evalIn ctxt l
  r' <- evalIn ctxt r
  return $ Pair (Val s l') (Val s r')

evalIn _ (Val _ v) = return v

evalIn ctxt (Case _ gExpr cases) = do
    val <- evalIn ctxt gExpr
    p <- pmatch ctxt cases val
    case p of
      Just (ei, bindings) -> evalIn ctxt (applyBindings bindings ei)
      Nothing             ->
        error $ "Incomplete pattern match:\n  cases: " ++ show cases ++ "\n  val: " ++ show val

applyBindings :: Ctxt Expr -> Expr -> Expr
applyBindings [] e = e
applyBindings ((var, e'):bs) e = applyBindings bs (subst e' var e)

pmatch :: Ctxt Value -> [(Pattern, Expr)] -> Value -> IO (Maybe (Expr, Ctxt Expr))
pmatch _ [] _ =
   return Nothing

pmatch _ ((PWild _, e):_)  _ =
   return $ Just (e, [])

pmatch _ ((PConstr _ s, e):_) (Constr s' []) | s == s' =
   return $ Just (e, [])

pmatch _ ((PVar _ var, e):_) val =
   return $ Just (e, [(var, Val nullSpan val)])

pmatch ctxt ((PBox _ p, e):ps) (Promote e') = do
  v <- evalIn ctxt e'
  match <- pmatch ctxt [(p, e)] v
  case match of
    Just (_, bindings) -> return $ Just (e, bindings)
    Nothing -> pmatch ctxt ps (Promote e')

pmatch _ ((PInt _ n, e):_)      (NumInt m)   | n == m  =
   return $ Just (e, [])

pmatch _ ((PFloat _ n, e):_)    (NumFloat m) | n == m =
   return $ Just (e, [])

pmatch ctxt ((PApp _ p1 p2, e):ps) val@(Constr s vs) = do
  p <- pmatch ctxt [(p2, e)] (last vs)
  case p of
    Just (_, bindings) -> do
      p' <- pmatch ctxt [(p1, e)] (Constr s (init $ vs))
      case p' of
        Just (_, bindings') -> return $ Just (e, bindings ++ bindings')
        _                   -> pmatch ctxt ps val
    _                  -> pmatch ctxt ps val

pmatch ctxt ((PPair _ p1 p2, e):ps) vals@(Pair (Val _ v1) (Val _ v2)) = do
  match1 <- pmatch ctxt [(p1, e)] v1
  match2 <- pmatch ctxt [(p2, e)] v2
  case match1 of
    Nothing -> pmatch ctxt ps vals
    Just (_, bindings1) -> case match2 of
      Nothing -> pmatch ctxt ps vals
      Just (_, bindings2) -> return (Just (e, bindings1 ++ bindings2))

pmatch ctxt (_:ps) val = pmatch ctxt ps val

builtIns :: Ctxt Value
builtIns =
  [
    (mkId "pure",       Primitive $ \v -> return $ Pure (Val nullSpan v))
  , (mkId "intToFloat", Primitive $ \(NumInt n) -> return $ NumFloat (cast n))
  , (mkId "showInt",    Primitive $ \n -> case n of
                              NumInt n -> return . StringLiteral . pack . show $ n
                              n        -> error $ show n)
  , (mkId "write", Primitive $ \(StringLiteral s) -> do
                              Text.putStrLn s
                              return $ Pure (Val nullSpan (Constr (mkId "()") [])))
  , (mkId "openFile", Primitive openFile)
  , (mkId "hGetChar", Primitive hGetChar)
  , (mkId "hPutChar", Primitive hPutChar)
  , (mkId "hClose",   Primitive hClose)
  , (mkId "showChar",
        Primitive $ \(CharLiteral c) -> return $ StringLiteral $ pack [c])
  , (mkId "stringAppend",
        Primitive $ \(StringLiteral s) -> return $
          Primitive $ \(StringLiteral t) -> return $ StringLiteral $ s `append` t)
  , (mkId "isEOF", Primitive $ \(Handle h) -> do
        b <- SIO.isEOF
        let boolflag =
             case b of
               True -> Constr (mkId "True") []
               False -> Constr (mkId "False") []
        return $ Pure (Val nullSpan
                   (Pair (Val nullSpan (Handle h)) (Val nullSpan boolflag)))

        )
  ]
  where
    cast :: Int -> Double
    cast = fromInteger . toInteger

    openFile :: Value -> IO Value
    openFile (StringLiteral s) = return $
      Primitive (\(Constr m []) ->
        let mode = (read (internalName m)) :: SIO.IOMode
        in do
             h <- SIO.openFile (unpack s) mode
             return $ Pure (Val nullSpan (Handle h)))

    hPutChar :: Value -> IO Value
    hPutChar (Handle h) = return $
      Primitive (\(CharLiteral c) -> do
         SIO.hPutChar h c
         return $ Pure (Val nullSpan (Handle h)))

    hGetChar :: Value -> IO Value
    hGetChar (Handle h) = do
          c <- SIO.hGetChar h
          return $ Pure (Val nullSpan
                    (Pair (Val nullSpan (Handle h))
                          (Val nullSpan (CharLiteral c))))

    hClose :: Value -> IO Value
    hClose (Handle h) = do
         SIO.hClose h
         return $ Pure (Val nullSpan (Constr (mkId "()") []))


evalDefs :: (?globals :: Globals) => Ctxt Value -> AST -> IO (Ctxt Value)
evalDefs ctxt [] = return ctxt
evalDefs ctxt (Def _ var e [] _ : defs) = do
    val <- evalIn ctxt e
    evalDefs (extend ctxt var val) defs
evalDefs ctxt (ADT {} : defs) = evalDefs ctxt defs
evalDefs ctxt (d : defs) = do
    let d' = desugar d
    debugM "Desugaring" $ pretty d'
    evalDefs ctxt (d' : defs)

eval :: (?globals :: Globals) => AST -> IO (Maybe Value)
eval defs = do
    bindings <- evalDefs builtIns defs
    case lookup (mkId "main") bindings of
      Nothing -> return Nothing
      Just (Pure e)    -> fmap Just (evalIn bindings e)
      Just (Promote e) -> fmap Just (evalIn bindings e)
      Just val         -> return $ Just val
