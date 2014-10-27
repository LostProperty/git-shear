{-# LANGUAGE OverloadedStrings #-}

import System.IO
import System.Exit
import System.Process
import System.Environment
import qualified Data.Text    as T
import qualified Data.Text.IO as TIO
import Data.List              (sort)
import Data.Char              (isSpace)
import System.Console.GetOpt


exitIfErrors :: [String] -> IO String
exitIfErrors [] = return ""
exitIfErrors es = do
    u <- usage
    let msg = unlines(map rstrip es) ++ "\n\n" ++ u
    hPutStrLn stderr msg
    exitWith $ ExitFailure 10

showVersion :: Options -> IO Options
showVersion _ = do
    hPutStrLn stderr "0.1.0"
    exitSuccess


showHelp :: Options -> IO Options
showHelp _ = do
    prg <- getProgName
    hPutStrLn stderr (usageInfo prg options)
    exitSuccess


usage :: IO String
usage = do
    prg <- getProgName
    return $ usageInfo prg options


data Options = Options { optBranch  :: Maybe String
                       , optLimit   :: Maybe Int}
               deriving (Show, Eq)

defaultOptions :: Options
defaultOptions = Options { optBranch  = Nothing, optLimit = Nothing}

options :: [OptDescr (Options -> IO Options)]
options = [ Option "h" ["help"] (NoArg showHelp) "Display help message."
          , Option "v" ["version"] (NoArg showVersion) "Show the version."

          , Option "l" ["limit"]
            (ReqArg (\l opt -> return opt {optLimit = Just $ read l}) "LIMIT")
            "Limit the number of branches that will be deleted"
          ]


rstrip :: String -> String
rstrip = reverse . dropWhile isSpace . reverse


isProtectedBranch :: T.Text -> Bool
isProtectedBranch t = any isInfixOf ["origin/develop", "origin/master"]
    where isInfixOf = flip T.isInfixOf t

isNotProtectedBranch :: T.Text -> Bool
isNotProtectedBranch t = not (isProtectedBranch t)


filterBranches :: [T.Text] -> [T.Text]
filterBranches = filter isNotProtectedBranch


extractBranches :: T.Text -> [T.Text]
extractBranches s = map T.strip (T.lines s)


mergedRemotes :: String -> IO String
mergedRemotes refname = readProcess "git" ["branch", "-r", "--merged", refname] ""


data ShellError = ShellError String Int

refExists :: String -> IO (Either ShellError T.Text)
refExists refname = do
    (code, stdo, stde) <- readProcessWithExitCode "git" ["rev-parse", refname, "--"] ""
    case code of
        ExitFailure c -> return . Left $ ShellError stde c
        ExitSuccess   -> return . Right $ T.replace "\n--" "" (T.pack stdo)


getBranchNames :: String -> [T.Text]
getBranchNames s = sort . filterBranches . extractBranches $ T.pack s


branchCount :: [T.Text] -> T.Text
branchCount bs = "Would delete the following " `T.append` amount `T.append` " branch(es):"
    where amount = T.pack . show $ length bs


branchDelete :: [T.Text] -> [T.Text]
branchDelete bs = [T.append "git push origin --delete " x | x <- bs]


takeBranches :: Maybe Int -> [T.Text] -> [T.Text]
takeBranches _ []            = []
takeBranches Nothing  (x:xs) = x:xs
takeBranches (Just i) (x:xs) = take i (x:xs)


validateNonOptions :: [String] -> Either String String
validateNonOptions xs = case xs of
    []     -> Left "You must specify a refname"
    [i]    -> Right i
    (_:is) -> Left $ unlines ["Unsupported option: " ++ x | x <- is]


ss :: ShellError -> String
ss (ShellError stde code) = "Result: " ++ stde


exitWithShellError :: ShellError -> IO b
exitWithShellError sherror = do
    hPutStrLn stderr $ ss sherror
    exitWith $ ExitFailure 128


doNothing :: T.Text -> IO String
doNothing _ = return ""


main :: IO ()
main = do
    args <- getArgs
    let (actions, nonOptions, errors) = getOpt Permute options args
    opts <- foldl (>>=) (return defaultOptions) actions

    _ <- exitIfErrors errors
    _ <- case validateNonOptions nonOptions of
        Left err      -> exitIfErrors [err]
        Right refname -> do
            ref <- refExists refname
            either exitWithShellError doNothing ref

    let refname = either (error "mismatch") id (validateNonOptions nonOptions)
    output <- mergedRemotes refname
    let Options {optLimit = limit} = opts

    -- ideally, takeBranches should be part of getBranchNames so that we
    -- reduce the list of branches _before_ filtering and sorting it
    let bs = takeBranches limit . getBranchNames $ output
    TIO.putStrLn $ branchCount bs
    TIO.putStr . T.unlines $ branchDelete bs
