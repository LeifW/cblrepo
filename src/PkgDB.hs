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

module PkgDB where

-- {{{1 imports
import Control.Exception as CE
import Control.Monad
import Data.Data
import Data.List
import Data.Maybe
import Data.Typeable
import Distribution.PackageDescription
import Distribution.Text
import System.IO.Error
import Text.JSON
import qualified Distribution.Package as P
import qualified Distribution.Version as V

-- {{{ temporary
_depName (P.Dependency (P.PackageName n) _) = n
_depVersionRange (P.Dependency _ vr) = vr

-- {{{1 types
data Pkg
    = GhcPkg { version :: V.Version }
    | DistroPkg { version :: V.Version, release :: String }
    | RepoPkg { version :: V.Version, deps :: [P.Dependency], release :: String }
    deriving (Eq, Show)

type CblPkg = (String, Pkg)
type CblDB = [CblPkg]

-- {{{1 packages
pkgName :: CblPkg -> String
pkgName (n, _) = n

pkgVersion :: CblPkg -> V.Version
pkgVersion (_, p) = version p

pkgDeps :: CblPkg -> [P.Dependency]
pkgDeps (_, RepoPkg { deps = d}) = d
pkgDeps _ = []

pkgRelease :: CblPkg -> Int
pkgRelease (_, GhcPkg {}) = -1
pkgRelease (_, DistroPkg { release = r }) = read r
pkgRelease (_, RepoPkg { release = r }) = read r

createGhcPkg n v = (n, GhcPkg v)
createDistroPkg n v r = (n, DistroPkg v r)
createRepoPkg n v d r = (n, RepoPkg v d r)

createCblPkg :: PackageDescription -> CblPkg
createCblPkg pd = createRepoPkg name version deps "1"
    where
        name = (\ (P.PackageName n) -> n) (P.pkgName $ package pd)
        version = P.pkgVersion $ package pd
        deps = buildDepends pd

getDependencyOn :: String -> CblPkg -> Maybe P.Dependency
getDependencyOn n p = find (\ d -> _depName d == n) (pkgDeps p)

isBasePkg :: CblPkg -> Bool
isBasePkg (_, DistroPkg {}) = False
isBasePkg _ = True

-- {{{1 database
emptyPkgDB :: CblDB
emptyPkgDB = []

addPkg :: CblDB -> String -> Pkg -> CblDB
addPkg db n p = nubBy cmp newdb
    where
        cmp (n1, _) (n2, _) = n1 == n2
        newdb = (n, p):db

addPkg2 :: CblDB -> CblPkg -> CblDB
addPkg2 db (n, p) = addPkg db n p

addBasePkg :: CblDB -> String -> V.Version -> CblDB
addBasePkg db n v = addPkg2 db (createGhcPkg n v)

delPkg :: CblDB -> String -> CblDB
delPkg db n = filter (\ p -> n /= pkgName p) db

bumpRelease :: CblDB -> String -> CblDB
bumpRelease db n = let
        doBump (n', p@RepoPkg { release = r }) = (n', p { release = nr })
            where
                nr = show $ (read r) + 1
        doBump p = p
    in maybe db (addPkg2 db . doBump) (lookupPkg db n)

lookupPkg :: CblDB -> String -> Maybe CblPkg
lookupPkg db n = maybe Nothing (\ p -> Just (n, p)) (lookup n db)

lookupDependants db n = map pkgName $ filter (\ p -> doesDependOn p n) db
    where
        doesDependOn p n = n `elem` (map _depName $ pkgDeps p)

transitiveDependants :: CblDB -> [String] -> [String]
transitiveDependants db names = keepLast $ concat $ map transUsersOfOne names
    where
        transUsersOfOne n = n : transitiveDependants db (lookupDependants db n)
        keepLast = reverse . nub . reverse

-- Todo: test
checkDependants :: CblDB -> String -> V.Version -> [(String, Maybe P.Dependency)]
checkDependants db n v = let
        d1 = catMaybes $ map (lookupPkg db) (lookupDependants db n)
        d2 = map (\ p -> (pkgName p, getDependencyOn n p)) d1
        fails = filter (not . V.withinRange v . _depVersionRange . fromJust . snd) d2
    in fails

readDb :: FilePath -> IO CblDB
readDb fp = (flip CE.catch)
    (\ e -> if isDoesNotExistError e
        then return emptyPkgDB
        else throwIO e)
    $ do
        r <- readFile fp >>= return . sequence . map decode . lines
        case r of
            Ok a -> return a
            Error s -> fail s

saveDb :: CblDB -> FilePath -> IO ()
saveDb db fp = writeFile fp s
    where
        s = unlines $ map encode db

-- {{{1 JSON instances
instance JSON V.Version where
    showJSON v = makeObj [ ("Version", showJSON $ display v) ]

    readJSON object = do
        obj <- readJSON object
        version <- valFromObj "Version" obj
        maybe (fail "Not a Version object") return (simpleParse version)

instance JSON P.Dependency where
    showJSON d = makeObj [ ("Dependency", showJSON $ display d) ]

    readJSON object = do
        obj <- readJSON object
        dep <- valFromObj "Dependency" obj
        maybe (fail "Not a Dependency object") return (simpleParse dep)

instance JSON Pkg where
    showJSON p@(GhcPkg { version = v}) = makeObj [("GhcPkg", showJSON v)]
    showJSON p@(DistroPkg { version = v, release = r}) =
        makeObj [("DistroPkg", showJSON (v, r))]
    showJSON p@(RepoPkg { version = v, deps = d, release = r }) =
        makeObj [("RepoPkg", showJSON (v, d, r))]

    readJSON object = let
            readGhc = do
                obj <- readJSON object
                v <- valFromObj "GhcPkg" obj >>= readJSON
                return $ GhcPkg v

            readDistro = do
                obj <- readJSON object
                (v, r) <- valFromObj "DistroPkg" obj >>= readJSON
                return $ DistroPkg v r

            readRepo = do
                obj <- readJSON object
                (v, d, r) <- valFromObj "RepoPkg" obj >>= readJSON
                return $ RepoPkg v d r

        in readGhc `mplus` readDistro `mplus` readRepo `mplus` fail "Not a Pkg object"
