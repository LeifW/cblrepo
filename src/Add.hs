{-
 - Copyright 2011 Per Magnus Therning
 -
 - Licensed under the Apache License, Version 2.0 (the "License");
 - you may not use this file except in compliance with the License.
 - You may obtain a copy of the License at
 -
 -     http://www.apache.org/licenses/LICENSE-2.0
 -
 - Unless required by applicable law or agreed to in writing, software
 - distributed under the License is distributed on an "AS IS" BASIS,
 - WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 - See the License for the specific language governing permissions and
 - limitations under the License.
 -}

module Add where

-- {{{1 imports
-- {{{2 local
import OldPkgDB
import Util.Misc

-- {{{2 system
import Codec.Archive.Tar as Tar
import Codec.Compression.GZip as GZip
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Data.List
import Data.Maybe
import Data.Version
import Distribution.Compiler
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration
import Distribution.PackageDescription.Parse
import Distribution.System
import Distribution.Text
import Distribution.Verbosity
import Distribution.Version
import System.Directory
import System.FilePath
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Distribution.Package as P
import System.Posix.Files
import System.Unix.Directory
import System.Process
import System.Exit
import System.IO

-- {{{1 add
add :: ReaderT Cmds IO ()
add = do
    b <- cfgGet isBase
    if b
        then addBase
        else addNoneBase

-- {{{2 Add base package
addBase :: ReaderT Cmds IO ()
addBase = let
        unpackPkgVer s = (p, v)
            where
                (p, _:v) = span (/= ',') s
    in do
        pkgs <- liftM (map unpackPkgVer) (cfgGet cbls)
        dR <- cfgGet dryRun
        guard $ isJust $ (sequence $ map (simpleParse . snd) pkgs :: Maybe [Version])
        let ps = map (\ (n, v) -> (n, fromJust $ simpleParse v)) pkgs
        dbFn <- cfgGet dbFile
        db <- liftIO $ readDb dbFn
        case doAddBase db ps of
            Left brkOthrs -> liftIO $ mapM_ printBrksOth brkOthrs
            Right newDb -> liftIO $ unless dR $ saveDb newDb dbFn

doAddBase db pkgs = let
        canBeAdded db n v = null $ checkDependants db n v
        (_, fails) = partition (\ (n, v) -> canBeAdded db n v) pkgs
        newDb = foldl (\ d (n, v) -> addBasePkg d n v) db pkgs
        brkOthrs = map (\ (n, v) -> ((n, v), checkDependants db n v)) fails
    in if null fails
        then Right newDb
        else Left brkOthrs

-- {{{2 Add non-base package
addNoneBase :: ReaderT Cmds IO ()
addNoneBase = do
    dbFn <- cfgGet dbFile
    db <- liftIO $ readDb dbFn
    pD <- cfgGet patchDir
    cbls <- cfgGet cbls
    dR <- cfgGet dryRun
    genPkgs <- liftIO $ mapM (\ c -> withTemporaryDirectory "/tmp/cblrepo." (readCabal pD c)) cbls
    let pkgNames = map ((\ (P.PackageName n) -> n ) . P.pkgName . package . packageDescription) genPkgs
    let tmpDb = filter (\ p -> not $ pkgName p `elem` pkgNames) db
    case doAdd tmpDb genPkgs of
        Left (unSats, brksOthrs) -> liftIO (mapM_ printUnSat unSats >> mapM_ printBrksOth brksOthrs)
        Right newDb -> liftIO $ unless dR $ saveDb newDb dbFn

doAdd db pkgs = let
        (succs, fails) = partition (canBeAdded db) pkgs
        newDb = foldl addPkg2 db (map (fromJust . finalizeToCblPkg db) succs)
        unSats = catMaybes $ map (finalizeToDeps db) fails
        genPkgName = ((\ (P.PackageName n) -> n ) . P.pkgName . package . packageDescription)
        genPkgVer = P.pkgVersion . package . packageDescription
        brksOthrs = filter (not . null . snd) $ map (\ p -> ((genPkgName p, genPkgVer p), checkDependants db (genPkgName p) (genPkgVer p))) fails
    in case (succs, fails) of
        (_, []) -> Right newDb
        ([], _) -> Left (unSats, brksOthrs)
        (_, _) -> doAdd newDb fails

canBeAdded db p = let
        finable = either (const False) (const True) (finalizePkg db p)
        n = ((\ (P.PackageName n) -> n ) . P.pkgName . package . packageDescription) p
        v = P.pkgVersion $ package $ packageDescription p
        depsOK = null $ checkDependants db n v
    in finable && depsOK

finalizeToCblPkg db p = case finalizePkg db p of
    Right (pd, _) -> Just $ createCblPkg pd
    _ -> Nothing

finalizeToDeps db p = case finalizePkg db p of
    Left ds -> Just $ (((\ (P.PackageName n) -> n ) . P.pkgName . package . packageDescription) p, ds)
    _ -> Nothing
