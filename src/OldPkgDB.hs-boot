module OldPkgDB where

import qualified Distribution.Package as P
import qualified Distribution.Version as V

type CblPkg = (String, (V.Version, [P.Dependency], Int))
type CblDB = [CblPkg]

lookupPkg :: CblDB -> String -> Maybe CblPkg
