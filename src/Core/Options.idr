module Core.Options

import Core.Core
import Core.Name
import Core.TT
import Utils.Binary
import Utils.Path

import Data.List
import Data.Maybe
import Data.Strings

import System.Info

%default total

public export
record Dirs where
  constructor MkDirs
  working_dir : String
  source_dir : Maybe String -- source directory, relative to working directory
  build_dir : String -- build directory, relative to working directory
  output_dir : Maybe String -- output directory, relative to working directory
  prefix_dir : String -- installation prefix, for finding data files (e.g. run time support)
  extra_dirs : List String -- places to look for import files
  lib_dirs : List String -- places to look for libraries (for code generation)
  data_dirs : List String -- places to look for data file

export
execBuildDir : Dirs -> String
execBuildDir d = build_dir d </> "exec"

export
outputDirWithDefault : Dirs -> String
outputDirWithDefault d = fromMaybe (build_dir d </> "exec") (output_dir d)

public export
toString : Dirs -> String
toString d@(MkDirs wdir sdir bdir odir dfix edirs ldirs ddirs) =
  unlines [ "+ Working Directory      :: " ++ show wdir
          , "+ Source Directory       :: " ++ show sdir
          , "+ Build Directory        :: " ++ show bdir
          , "+ Output Directory       :: " ++ show (outputDirWithDefault d)
          , "+ Installation Prefix    :: " ++ show dfix
          , "+ Extra Directories      :: " ++ show edirs
          , "+ CG Library Directories :: " ++ show ldirs
          , "+ Data Directories       :: " ++ show ddirs]

public export
data CG = Chez
        | Racket
        | Gambit
        | Node
        | Javascript
        | Other String

export
Eq CG where
  Chez == Chez = True
  Racket == Racket = True
  Gambit == Gambit = True
  Node == Node = True
  Javascript == Javascript = True
  Other s == Other t = s == t
  _ == _ = False

export
Show CG where
  show Chez = "chez"
  show Racket = "racket"
  show Gambit = "gambit"
  show Node = "node"
  show Javascript = "javascript"
  show (Other s) = s

public export
record PairNames where
  constructor MkPairNs
  pairType : Name
  fstName : Name
  sndName : Name

public export
record RewriteNames where
  constructor MkRewriteNs
  equalType : Name
  rewriteName : Name

public export
record PrimNames where
  constructor MkPrimNs
  fromIntegerName : Maybe Name
  fromStringName : Maybe Name
  fromCharName : Maybe Name

public export
data LangExt
     = ElabReflection
     | Borrowing -- not yet implemented
     | PostfixProjections

export
Eq LangExt where
  ElabReflection == ElabReflection = True
  Borrowing == Borrowing = True
  PostfixProjections == PostfixProjections = True
  _ == _ = False

-- Other options relevant to the current session (so not to be saved in a TTC)
public export
record ElabDirectives where
  constructor MkElabDirectives
  lazyActive : Bool
  unboundImplicits : Bool
  totality : TotalReq
  ambigLimit : Nat
  autoImplicitLimit : Nat

public export
record Session where
  constructor MkSessionOpts
  noprelude : Bool
  nobanner : Bool
  findipkg : Bool
  codegen : CG
  directives : List String
  logLevel : Nat
  logTimings : Bool
  debugElabCheck : Bool -- do conversion check to verify results of elaborator
  dumpcases : Maybe String -- file to output compiled case trees
  dumplifted : Maybe String -- file to output lambda lifted definitions
  dumpanf : Maybe String -- file to output ANF definitions
  dumpvmcode : Maybe String -- file to output VM code definitions

public export
record PPrinter where
  constructor MkPPOpts
  showImplicits : Bool
  showFullEnv : Bool
  fullNamespace : Bool

public export
record Options where
  constructor MkOptions
  dirs : Dirs
  printing : PPrinter
  session : Session
  elabDirectives : ElabDirectives
  pairnames : Maybe PairNames
  rewritenames : Maybe RewriteNames
  primnames : PrimNames
  extensions : List LangExt
  additionalCGs : List (String, CG)


export
availableCGs : Options -> List (String, CG)
availableCGs o
    = [("chez", Chez),
       ("racket", Racket),
       ("node", Node),
       ("javascript", Javascript),
       ("gambit", Gambit)] ++ additionalCGs o

export
getCG : Options -> String -> Maybe CG
getCG o cg = lookup (toLower cg) (availableCGs o)

defaultDirs : Dirs
defaultDirs = MkDirs "." Nothing "build" Nothing
                     "/usr/local" ["."] [] []

defaultPPrint : PPrinter
defaultPPrint = MkPPOpts False True False

export
defaultSession : Session
defaultSession = MkSessionOpts False False False Chez [] 0
                               False False Nothing Nothing
                               Nothing Nothing

export
defaultElab : ElabDirectives
defaultElab = MkElabDirectives True True CoveringOnly 3 50

export
defaults : Options
defaults = MkOptions defaultDirs defaultPPrint defaultSession
                     defaultElab Nothing Nothing
                     (MkPrimNs Nothing Nothing Nothing) []
                     []

-- Reset the options which are set by source files
export
clearNames : Options -> Options
clearNames = record { pairnames = Nothing,
                      rewritenames = Nothing,
                      primnames = MkPrimNs Nothing Nothing Nothing,
                      extensions = []
                    }

export
setPair : (pairType : Name) -> (fstn : Name) -> (sndn : Name) ->
          Options -> Options
setPair ty f s = record { pairnames = Just (MkPairNs ty f s) }

export
setRewrite : (eq : Name) -> (rwlemma : Name) -> Options -> Options
setRewrite eq rw = record { rewritenames = Just (MkRewriteNs eq rw) }

export
setFromInteger : Name -> Options -> Options
setFromInteger n = record { primnames->fromIntegerName = Just n }

export
setFromString : Name -> Options -> Options
setFromString n = record { primnames->fromStringName = Just n }

export
setFromChar : Name -> Options -> Options
setFromChar n = record { primnames->fromCharName = Just n }

export
setExtension : LangExt -> Options -> Options
setExtension e = record { extensions $= (e ::) }

export
isExtension : LangExt -> Options -> Bool
isExtension e opts = e `elem` extensions opts

export
addCG : (String, CG) -> Options -> Options
addCG cg = record { additionalCGs $= (cg::) }
