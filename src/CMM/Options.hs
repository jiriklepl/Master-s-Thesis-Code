{-# LANGUAGE Safe #-}


module CMM.Options where
import safe Options.Applicative
    ( (<**>),
      argument,
      auto,
      fullDesc,
      header,
      help,
      info,
      long,
      metavar,
      option,
      progDesc,
      short,
      showDefault,
      str,
      strOption,
      switch,
      value,
      internal,
      helper,
      Parser,
      ParserInfo )


data Options = Options
  { monosrc      :: Bool
  , prettify      :: Bool
  , output      :: String
  , handleStart      :: Int
  , maxCycles      :: Int
  , maxFunDeps      :: Int
  , quiet :: Bool
  , input :: String
  }
  deriving (Show)

options :: Parser Options
options = Options
  <$> switch
      ( long "monosrc"
      <> short 'm'
      <> help "Monomorphize the source without any flattening or blockifying" )
  <*> switch
      ( long "pretty"
      <> short 'p'
      <> help "Run as a prettyprinter" )
  <*> strOption
      ( long "output"
      <> short 'o'
      <> metavar "OUTPUT"
      <> showDefault
      <> value "a.out"
      <> help "Specify the output file" )
  <*> option auto
      ( long "handle_couter"
      <> short 'H'
      <> internal
      <> metavar "HANDLE_COUNTER"
      <> showDefault
      <> value 0
      <> help "Set the handle counter starting point" )
  <*> option auto
      ( long "max_cycles"
      <> short 'c'
      <> metavar "MAX_CYCLES"
      <> showDefault
      <> value 50
      <> help "Set the maximum of monomorphization cycles" )
  <*> option auto
      ( long "max_fundeps"
      <> short 'f'
      <> metavar "MAX_FUNDEPS"
      <> showDefault
      <> value 500
      <> help "Set the maximum number of functional dependency resolutions in course of the type inference" )
  <*> switch
      ( long "quiet"
      <> short 'q'
      <> help "Run in quiet mode, do not print any output if there are no warnings or errors"
      <> showDefault )
  <*> argument str (metavar "FILE")

opts :: ParserInfo Options
opts = info (options <**> helper)
  ( fullDesc
  <> progDesc "Compile a .chmmm file"
  <> header "A proof of concept compiler for a modified C-- language called CHMMM" )
