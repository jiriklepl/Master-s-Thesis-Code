{-# LANGUAGE Safe #-}

module Main where

import Control.Lens.Getter (view)
import Control.Monad.State as State (Monad(return), runState)
import Data.Either (Either(..), either)
import Data.Function (($), (.), id)
import Data.List (head)
import Data.Monoid (Monoid(mempty))
import GHC.Err (undefined)

import qualified Data.Text.IO as TS
-- import qualified Data.Map as Map
-- import Control.Lens
-- import Data.Text as T
import safe System.IO (IO, putStrLn)

-- import Data.Tuple
import Text.Megaparsec hiding (parse)

-- import Data.Text.Lazy as T
-- import Data.Text.Lazy.IO as T
-- import LLVM.Pretty -- from the llvm-hs-pretty package
-- import LLVM.IRBuilder.Module
-- import LLVM.IRBuilder.Monad
import Prettyprinter

import CMM.AST.Annot
import CMM.AST.Blockifier
import qualified CMM.AST.Blockifier.State as B
import CMM.AST.Flattener
import CMM.AST.Variables
import CMM.Inference as Infer
import CMM.Inference.Preprocess as Infer
import CMM.Inference.Preprocess.State as Infer
import qualified CMM.Inference.Preprocess.State
import CMM.Inference.State as InferState

import safe CMM.Inference.HandleCounter
  ( HasHandleCounter(handleCounter)
  , setHandleCounter
  )
-- import CMM.Inference.Type as Infer
-- import CMM.Inference.TypeKind as Infer
import CMM.Lexer
import CMM.Monomorphize (Monomorphize(monomorphize))
import CMM.Monomorphize.Monomorphized as Infer
import CMM.Parser
import CMM.Pretty ()
import Data.Functor
import GHC.Show

-- import CMM.Translator
-- import qualified CMM.Translator.State as Tr
-- import Data.Foldable (traverse_)
main :: IO ()
main = do
  contents <- TS.getContents
  let tokens' = either undefined id $ parse tokenize contents
  let ast = either undefined id $ parse unit tokens'
  let flattened = flatten ast
  let (mined, miner) = runState (preprocess ast) initPreprocessor
  let (_, _) = runState (blockify flattened) B.initBlockifier
  -- let translated =
  --       ppllvm $
  --       flip
  --         evalState
  --         Tr.initTranslState
  --           { Tr._controlFlow = B._controlFlow blockifier
  --           , Tr._blockData = B._blockData blockifier
  --           , Tr._blocksTable =
  --               Map.fromList . (swap <$>) . Map.toList $
  --               B._blocksTable blockifier
  --           } $
  --       buildModuleT "llvm" $
  --       runIRBuilderT emptyIRBuilder $ translate blockified
  -- T.putStr translated
  let _ = globalVariables $ unAnnot ast
  -- print $ CMM.Inference.Preprocess.State._facts miner
  let (msg, inferencer) =
        (`runState` InferState.initInferencer) $ do
          setHandleCounter $ view handleCounter miner
          let fs = head $ view CMM.Inference.Preprocess.State.facts miner
          mineAST mined
        -- liftIO $ print fs
          void $ reduce fs
          monomorphize mempty mined <&> \case
            Left what -> show what
            Right mined' -> show . pretty $ view Infer.node mined'
  putStrLn msg
  void $ return inferencer

parse :: Parsec e s a -> s -> Either (ParseErrorBundle s e) a
parse parser = runParser parser "stdin"
