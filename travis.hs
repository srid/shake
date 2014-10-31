
import Data.Char
import Data.Function
import System.Directory.Extra
import System.Environment
import System.Time.Extra
import Data.List
import Control.Exception.Extra
import Control.Monad
import System.Process.Extra


requiresShake = words "ghc-make avr-shake shake-language-c"

ms x = show $ ceiling $ x * 1000

main = do
    args <- getArgs
    unless (null args) $ error "Terminating early"

    -- grab ninja
    system_ "git clone https://github.com/martine/ninja"
    system_ "cd ninja && ./bootstrap.py"
    copyFile "ninja/ninja" "nin"

    withCurrentDirectory "ninja" $ do

        replicateM_ 3 $ do
            (ninjaVer, _) <- duration $ system_ "../nin --version"
            (shakeVer, _) <- duration $ system_ "shake --version"
            putStrLn $ "--version for Ninja is " ++ ms ninjaVer ++ ", for Shake is " ++ ms shakeVer

        system_ "shake --version; shake -C does_not_exist; echo end" -- check for #22

        retry 3 $ do

            -- time Ninja
            system_ "../nin -t clean"
            (ninjaFull, _) <- duration $ system_ "../nin -j3 -d stats"
            ninjaProfile "build/.ninja_log"
            putStrLn =<< readFile "build/.ninja_log"
            (ninjaZero, _) <- duration $ system_ "../nin -j3 -d stats"

            -- time Shake
            system_ "../nin -t clean"
            (shakeFull, _) <- duration $ system_ "shake -j3 --quiet --timings"
            system_ "shake --no-build --report=-"
            (shakeZero, _) <- duration $ system_ "shake -j3 --quiet --timings"

            -- Diagnostics
            system_ "ls -l .shake* build/.ninja*"
            system_ "shake -VV"
            (shakeNone, _) <- duration $ system_ "shake --always-make --skip-commands --timings"
            putStrLn $ "--always-make --skip-commands took " ++ ms shakeNone

            putStrLn $ "Ninja was " ++ ms ninjaFull ++ " then " ++ ms ninjaZero
            putStrLn $ "Shake was " ++ ms shakeFull ++ " then " ++ ms shakeZero

            when (ninjaFull < shakeFull) $
                error "ERROR: Ninja build was faster than Shake"

            when (ninjaZero + 0.1 < shakeZero) $
                error "ERROR: Ninja zero build was more than 0.1s faster than Shake"

    {-
    -- Don't bother profiling, we only get under 25 ticks, which doesn't say anything useful
    system_ "ghc -threaded -rtsopts -isrc -i. Paths.hs Main.hs --make -O -prof -auto-all -caf-all"
    setCurrentDirectory "ninja"
    putStrLn "== PROFILE BUILDING FROM SCRATCH =="
    system_ "rm .shake*"
    system_ "../Main --skip-commands +RTS -p -V0.001"
    system_ "head -n32 Main.prof"

    putStrLn "== PROFILE BUILDING NOTHING =="
    system_ "../Main +RTS -p -V0.001"
    system_ "head -n32 Main.prof"
    setCurrentDirectory ".."
    -}

    createDirectoryIfMissing True "temp"
    withCurrentDirectory "temp" $
        system_ "shake --demo --keep-going"

    ver <- do
        src <- readFile "shake.cabal"
        return $ head [dropWhile isSpace x | x <- lines src, Just x <- [stripPrefix "version:" x]]
    forM_ requiresShake $ \x ->
        retry 3 $ system_ $ "cabal install " ++ x ++ " --constraint=shake==" ++ ver

ninjaProfile :: FilePath -> IO ()
ninjaProfile src = do
    src <- readFile src
    let times = [(read start, read stop)
                | start:stop:_ <- nubBy ((==) `on` (!! 3)) $
                        reverse $ map words $ filter (not . isPrefixOf "#") $ lines src]
    let work = sum $ map (uncurry subtract) times
    let last = maximum $ map snd times
    putStrLn $ "Ninja profile report: in " ++ show last ++ " ms did " ++ show work ++ " ms work, ratio of " ++ show (work / last)
