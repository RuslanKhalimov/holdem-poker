{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main
  ( main
  ) where

import           Control.Concurrent             (forkFinally)
import           Control.Concurrent.MVar        (MVar, newMVar, putMVar, takeMVar)
import           Control.Exception              (IOException, SomeException, bracket, try)
import           Data.Binary                    (encode, decode)
import qualified Data.Map as Map
import           Network.Socket          hiding (recv, sendAll)
import           Network.Socket.ByteString.Lazy (recv, sendAll)
import           System.Environment             (getArgs)
import           System.Exit                    (exitFailure)
import           System.Time                    (ClockTime(TOD), getClockTime)

import           Board        (Board (..), Hand(Showdown), Player (..))
import qualified BoardUtils as BU
import           CardUtils    (handValueFromCardSet)
import           PlayerAction (PlayerAction (..), bet, check, foldCards, quit)

type Connections = Map.Map Int Socket
type SharedInfo  = MVar (Bool, Board)

main :: IO()
main = withSocketsDo $ do
  args                 <- getArgs
  (port, playersCount) <- case args of port:playersCount:[] -> return (port, read playersCount)
                                       _                    -> do
                                                                 putStrLn "IncorrectArguments"
                                                                 putStrLn "Excpected <port> <playersCount>"
                                                                 exitFailure

  initialBoard <- BU.createBoard 0 playersCount

  addr <- resolve port
  bracket (open addr playersCount) close (runServer initialBoard)

resolve :: String -> IO AddrInfo
resolve port = do
  let hints = defaultHints { addrFlags = [AI_PASSIVE]
                           , addrSocketType = Stream
                           }
  addr:_ <- getAddrInfo (Just hints) Nothing (Just port)
  return addr

open :: AddrInfo -> Int -> IO Socket
open addr playersCount = do
  sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
  setSocketOption sock ReuseAddr playersCount
  bind sock (addrAddress addr)
  listen sock playersCount
  return sock

talkWithClient :: SharedInfo -> (Int, Socket) -> IO ()
talkWithClient boardMVar connection = do
  (needHide, board) <- takeMVar boardMVar
  sendBoard needHide board connection
  talkWithClient boardMVar connection

handleException :: Either SomeException () -> IO ()
handleException (Left exception) = putStrLn $ "Exception while sending board : " ++ show exception
handleException _                = putStrLn "Game finished"

runServer :: Board -> Socket -> IO ()
runServer board sock = do
  playersInfo    <- mapM (waitPlayerConnection sock) [0..playersCount board - 1]
  let connections = map snd $ playersInfo
  let names       = map fst playersInfo
  let newBoard    = board { players = Map.map (\p -> p { playerName = names !! playerId p }) (players board) }
  clientMVars    <- fmap Map.fromList
                  . fmap (zip [0..playersCount board - 1])
                  . mapM (newMVar . (True,))
                  $ replicate (playersCount newBoard) newBoard
  mapM_ (flip forkFinally handleException . (_talkWithClient clientMVars)) connections
  gameLoop 0 (Map.fromList connections) clientMVars newBoard
    where
      _talkWithClient :: Map.Map Int SharedInfo -> (Int, Socket) -> IO ()
      _talkWithClient clientMVars connection@(_id, _) = talkWithClient (clientMVars Map.! _id) connection

waitPlayerConnection :: Socket -> Int -> IO (String, (Int, Socket))
waitPlayerConnection sock _id = do
  (clientSock, addr) <- accept sock
  name               <- fmap decode $ recv clientSock 32
  putStrLn $ name ++ " from " ++ show addr ++ " connected"
  return (name, (_id, clientSock))

shareBoard :: Bool -> Connections -> Map.Map Int SharedInfo -> Board -> IO ()
shareBoard needHide connections clientMVars board = do
  mapM_ (\_id -> putMVar (clientMVars Map.! _id) (needHide, board)) $ Map.keysSet connections

applyAction :: PlayerAction -> Board -> Board
applyAction (Bet x) = bet x
applyAction Check   = check
applyAction Fold    = foldCards
applyAction Ok      = id
applyAction Quit    = quit

gameLoop :: Int -> Connections -> Map.Map Int SharedInfo -> Board -> IO ()
gameLoop firstPlayerId connections clientMVars board = do
  shareBoard True connections clientMVars board
  action            <- recvAction (connections Map.! activePlayerId board)
  let updatedBoard   = applyAction action board
  let newConnections = Map.filterWithKey (\_id _ -> Map.member _id (players updatedBoard)) connections

  let newBoard = BU.mergeBoards updatedBoard board
  if BU.isRoundFinished newBoard
  then do
    finalBoard <- finishRound firstPlayerId newConnections clientMVars newBoard
    if BU.isGameFinished finalBoard
    then
      finishGame newConnections clientMVars finalBoard
    else
      gameLoop (BU.getNextId finalBoard firstPlayerId) newConnections clientMVars finalBoard
  else
    if stepsInRound newBoard == Map.size (Map.filter isInGame $ players newBoard)
    then do
      let finalBoard = newBoard { visibleOnBoardCards = succ $ visibleOnBoardCards newBoard
                                , stepsInRound        = 0
                                , banks               = banks $ BU.fillBanks newBoard
                                , activePlayerId      = firstPlayerId
                                , players             = Map.map (\p -> p { playerBet = 0 }) (players newBoard)
                                }
      gameLoop firstPlayerId newConnections clientMVars finalBoard
    else do
      gameLoop firstPlayerId newConnections clientMVars
      $ newBoard { activePlayerId = BU.getNextId newBoard (activePlayerId newBoard) }

sendBoard :: Bool -> Board -> (Int, Socket) -> IO ()
sendBoard needHide board (_id, sock) = sendAll sock
                                     . encode
                                     . (if needHide
                                     then BU.hideCards (visibleOnBoardCards board) _id
                                     else (\b -> b { needAction = False, needAnyKey = True }))
                                     $ board

recvAction :: Socket -> IO PlayerAction
recvAction sock = do
  message <- try $ recv sock 512
  case message of
    Left (exception :: IOException) -> do
                                         putStrLn $ "Exception while receiving action from "
                                                 ++ show sock ++ ": " ++ show exception
                                         return Quit
    Right action                    -> return $ decode action

finishRound :: Int -> Connections -> Map.Map Int SharedInfo -> Board -> IO Board
finishRound firstPlayerId connections clientMVars board = do
  let cardSets   = BU.getCardSets board
  let handValues = Map.map handValueFromCardSet cardSets
  let finalBoard = BU.kickPlayers
                 . BU.giveMoney handValues
                 $ board { banks               = banks $ BU.fillBanks board
                         , visibleOnBoardCards = Showdown
                         , activePlayerId      = -1
                         , players             = Map.map (\p -> p { playerBet = 0 }) (players board)
                         }

  shareBoard False connections clientMVars finalBoard
  mapM_ recvAction connections

  (TOD time _) <- getClockTime
  return $ BU.nextDeal time (BU.getNextId finalBoard firstPlayerId) False finalBoard

finishGame :: Connections -> Map.Map Int SharedInfo -> Board -> IO ()
finishGame connections clientMVars board = do
  shareBoard False connections clientMVars board
