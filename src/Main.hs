{-# LANGUAGE OverloadedStrings #-}
module Main where

import System.Exit
import System.Process
import qualified Data.Text    as T
import qualified Data.Text.IO as TIO
import Data.List              (sort)
import Data.Char              (isSpace)
import Data.Either            (lefts, rights)
import Options.Applicative


data ShellError = ShellError { shellErrorMsg :: T.Text
                             , shellErrorCode :: Int }


rstrip :: T.Text -> T.Text
rstrip = T.reverse . T.dropWhile isSpace . T.reverse


isProtectedBranch :: T.Text -> Bool
isProtectedBranch t = any isInfixOf ["origin/develop", "origin/master"]
    where isInfixOf = flip T.isInfixOf t


filterBranches :: [T.Text] -> [T.Text]
filterBranches = filter isNotProtectedBranch
    where isNotProtectedBranch t = not (isProtectedBranch t)


extractBranches :: T.Text -> [T.Text]
extractBranches s = map T.strip (T.lines s)


mergedRemotes :: String -> IO String
mergedRemotes refname' = readProcess "git" ["branch", "-r", "--merged", refname'] ""


readProcess2 :: FilePath -> [String] -> String -> IO (ExitCode, T.Text, T.Text)
readProcess2 fp args stdin = do
    procResult <- readProcessWithExitCode fp args stdin
    return $ toText procResult
      where
          toText (a, b, c) = (a, T.pack b, T.pack c)


refExists :: String -> IO (Either ShellError T.Text)
refExists refname' = do
    (code, stdo, stde) <- readProcess2  "git" ["rev-parse", refname', "--"] ""
    case code of
        ExitFailure c -> return . Left $ ShellError stde c
        ExitSuccess   -> return . Right $ tidyName stdo
          where tidyName = rstrip . T.replace "--" ""


getBranchNames :: String -> [T.Text]
getBranchNames s = sort . filterBranches . extractBranches $ T.pack s


stripRemoteFromName :: T.Text -> [T.Text] -> [T.Text]
stripRemoteFromName r xs = map (T.replace (r `T.append` "/") "") xs


branchCount :: [T.Text] -> T.Text
branchCount bs = "Would delete the following " `T.append` amount `T.append` " branch(es):"
    where amount = T.pack . show $ length bs


branchDeleteCmds :: [T.Text] -> [T.Text]
branchDeleteCmds bs = [T.append "git push origin --delete " x | x <- bs]


shear :: Bool -> [T.Text] -> IO T.Text
shear doCommand cmds = case (doCommand, cmds) of
    (_, []) -> do
        error "No command to execute"
    (False, xs) -> do
        TIO.putStrLn $ branchCount xs
        exec $ getAllCmds $ map (flip T.append " --dry-run") xs
        return ""
    (True, xs) -> do
        exec $ getAllCmds xs
        return ""
    where separate (_:xx) = ("git", (map T.unpack xx))
          getAllCmds = map (separate .T.words)
          exec cs = do
            x <- mapM (\t -> runCmds (fst t) (snd t)) cs
            TIO.putStrLn $ T.unlines (rights x)
            TIO.putStrLn . T.unlines $ map shellErrorMsg (lefts x)


runCmds :: String -> [String] -> IO (Either ShellError T.Text)
runCmds fname args = do
    (code, _, stde) <- readProcess2 fname args ""
    case code of
        ExitFailure c -> return . Left $ ShellError stde c
        ExitSuccess   -> return . Right $ stde


takeBranches :: Int -> [T.Text] -> [T.Text]
takeBranches _ []     = []
takeBranches i (x:xs) = take i (x:xs)


data App = App { refname :: String
               , dryRun  :: Bool
               , limit   :: Int}

app :: Parser App
app = App
    <$> argument str (metavar "REFNAME")
    <*> switch (long "dry-run" <> short 'n' <> help "Show which branches would be deleted, without really deleting anything.")
    <*> option auto (long "limit" <> short 'l' <> help "Only delete L stale branches." <> metavar "L")


-- ideally, takeBranches should be part of getBranchNames so that we
-- reduce the list of branches _before_ filtering and sorting it

names :: String -> Int -> T.Text -> IO [T.Text]
names ref limit remote = fmap pipeline $ mergedRemotes ref
    where pipeline = (stripRemoteFromName remote) . (takeBranches limit) . getBranchNames


run :: App -> IO ()
run (App refname dryRun limit) = do
    ref <- refExists refname
    case ref of
         Left err   -> error . show $ shellErrorMsg err
         Right hash -> do
             branches <- names (T.unpack hash) limit "origin"
             _ <- shear (not dryRun) $ branchDeleteCmds branches
             return ()


main :: IO ()
main = execParser opts >>= run
      where
          opts = info (helper <*> app)
            (fullDesc
            <> progDesc "Delete branches that have been merged into REFNAME"
            <> header "git-shear - delete stale remote branches")
