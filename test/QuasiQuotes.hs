{-# LANGUAGE Safe #-}

module QuasiQuotes where

import safe Control.Monad (Monad(return), MonadFail(fail))
import safe Data.Function (($), (.), const)
import safe Data.String (String)

import safe Language.Haskell.TH (Exp(LitE), Lit(StringL))
import safe Language.Haskell.TH.Quote (QuasiQuoter(..))

text :: QuasiQuoter
text =
  QuasiQuoter
    { quoteExp = return . LitE . StringL . normalizeNewlines
    , quotePat = const $ fail "pattern not implemented"
    , quoteType = const $ fail "type not implemented"
    , quoteDec = const $ fail "declaration not implemented"
    }

normalizeNewlines :: String -> String
normalizeNewlines [] = []
normalizeNewlines ('\r':'\n':cs) = '\n' : normalizeNewlines cs
normalizeNewlines ('\r':cs) = '\n' : normalizeNewlines cs
normalizeNewlines (c:cs) = c : normalizeNewlines cs
