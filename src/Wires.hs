{-# LANGUAGE TemplateHaskell, QuasiQuotes, OverloadedStrings, TypeFamilies, MultiParamTypeClasses, Arrows #-}

{- | Wires is an internal implementation module of "HWebUI". "HWebUI" is providing FRP-based GUI functionality for Haskell by utilizing the Web-Browser. See module "HWebUI" for main documentation. 
-}
module Wires (
  
  buttonW,
  checkBoxW,
  htmlW,
  multiSelectW,
  numberTextBoxW,
  radioButtonW,
  textBoxW,
  
  loopHWebUIWire,
  
  GUIWire
  ) where

import Yesod
import Network.Wai.Handler.Warp (runSettings, Settings(..), defaultSettings)
import qualified Network.WebSockets             as WS
import qualified Network.Wai.Handler.WebSockets as WS
import qualified Data.Aeson                     as J
import System.IO (hFlush, stdout)
import Control.Applicative
import Control.Monad
import Text.Julius (rawJS)
import Control.Concurrent
import Control.Exception (SomeException, mask, try)
import System.IO.Unsafe
import Control.Wire
import Prelude hiding ((.), id)
import Data.Map
import Data.Text
import Data.Vector (toList, fromList)
import Data.Attoparsec.Number as N

import GUIValue
import GUIEvent
import GUICommand
import GUISignal
import Messaging
import Widgets
import Server


-- Netwire Types
--
type GUIWire a b = Wire () IO a b

-- generic function to create a value wire, a value wire has type "GUIWire (Maybe a) a"

valueWireGen :: String -- ^ Element Id 
                -> Map String GSChannel -- ^ Channel Map
                -> (a -> GUIValue) -- ^ svalue creation function
                -> (GUIValue -> b) -- ^ svalue extraction function
                -> GUIElementType -- ^ type of GUI Element
                -> IO (GUIWire (Maybe a) b , Map String GSChannel) -- ^ (wire, new Channel Map)
                
valueWireGen elid gsMap svalCreator svalExtractor guitype = do
  
  channel <- createChannel
  let gsMapNew = Data.Map.insert elid channel gsMap
  
  let wire = mkFixM  (\t inVal -> do
                                                case inVal of
                                                  Just bState -> do
                                                    sendGMWriteChannel channel (GUIMessage elid (GUICommand SetValue) (svalCreator bState) guitype)
                                                    return $ Left ()
                                                  Nothing -> do
                                                    rcv <- receiveGMReadChannel channel
                                                    case rcv of
                                                      Just guimsg -> do
                                                        if (gmSignal guimsg) == (GUIEvent OnChange) then do
                                                          let bState = svalExtractor (gmValue guimsg)
                                                          return $ Right bState
                                                          else return $ Left ()
                                                      Nothing -> do
                                                        return $ Left () 
                    )
                                         
  return (wire, gsMapNew)  

-- | Basic wire for CheckBox GUI element functionality
checkBoxW :: String -- ^ Element Id
             -> Map String GSChannel -- ^ Channel Map (Internal)
             -> IO (GUIWire (Maybe Bool) Bool, Map String GSChannel) -- ^ resulting Wire
checkBoxW elid gsMap = valueWireGen elid gsMap SVBool (\svval -> let (SVBool bstate) = svval in bstate) CheckBox

-- | Basic wire for RadioButton GUI element functionality
radioButtonW :: String -- ^ Element Id
             -> Map String GSChannel -- ^ Channel Map (Internal)
             -> IO (GUIWire (Maybe Bool) Bool, Map String GSChannel) -- ^ resulting Wire
radioButtonW elid gsMap = valueWireGen elid gsMap SVBool (\svval -> let (SVBool bstate) = svval in bstate) RadioButton

-- | Basic wire for TextBox GUI element functionality
textBoxW :: String -- ^ Element Id
             -> Map String GSChannel -- ^ Channel Map (Internal)
             -> IO (GUIWire (Maybe String) String, Map String GSChannel) -- ^ resulting Wire
textBoxW elid gsMap = valueWireGen elid gsMap SVString (\svval -> let (SVString bstate) = svval in bstate) TextBox

-- | Basic wire for MultiSelect GUI element functionality
multiSelectW :: String -- ^ Element Id
             -> Map String GSChannel -- ^ Channel Map (Internal)
             -> IO (GUIWire (Maybe [String]) [Int], Map String GSChannel) -- ^ resulting Wire
multiSelectW elid gsMap = valueWireGen elid gsMap (\list -> SVList $ fmap SVString list) (\svlist -> let  
                                                                                             (SVList rval) = svlist 
                                                                                             rval' = fmap (\svval -> let (SVInt intval) = svval in intval) rval 
                                                                                             in rval')  MultiSelect


guiWireGen :: String -> Map String GSChannel -> (String -> GSChannel -> IO (GUIWire a b)) -> IO (GUIWire a b, Map String GSChannel)
guiWireGen elid gsMap wireIn = do
  chan <- createChannel
  let gsMapNew = Data.Map.insert elid chan gsMap
  wireOut <- wireIn elid chan
  return (wireOut, gsMapNew)  

numberTextBoxW' :: String -> GSChannel -> IO (GUIWire (Maybe Double) Double)
numberTextBoxW' boxid channel = do
  let wire =  mkStateM 0 (\t (trigger, s) -> do
                                 case trigger of
                                   Just bState -> do
                                     sendGMWriteChannel channel (GUIMessage boxid (GUICommand SetValue) (SVDouble bState) NumberTextBox)
                                     return (Right bState, bState)
                                   Nothing -> do
                                     rcv <- receiveGMReadChannel channel
                                     case rcv of
                                       Just guimsg -> do
                                         if (gmSignal guimsg) == (GUIEvent OnChange) then do
                                           let (SVDouble bState) = gmValue guimsg
                                           return (Right bState, bState)
                                           else
                                             return (Right s, s)
                                       Nothing -> do
                                         return (Right s, s)   )
  return wire                                                         
  
-- | Basic wire for NumberTextBox GUI element functionality
numberTextBoxW :: String -- ^ Element Id
             -> Map String GSChannel -- ^ Channel Map (Internal)
             -> IO (GUIWire (Maybe Double) Double, Map String GSChannel) -- ^ resulting Wire
numberTextBoxW elid gsMap = guiWireGen elid gsMap numberTextBoxW'

htmlW' :: String -> GSChannel -> IO (GUIWire (Maybe String) String)
htmlW' boxid channel = do
  let wire =  mkStateM "" (\t (trigger, s) -> do
                                 case trigger of
                                   Just bState -> do
                                     sendGMWriteChannel channel (GUIMessage boxid (GUICommand SetValue) (SVString bState) Html)
                                     return (Right bState, bState)
                                   Nothing -> do
                                     return (Right s, s) )
  return wire                                                         


-- | Basic wire for HTML GUI element functionality (output element with dynamic HTML)
htmlW :: String -- ^ Element Id
             -> Map String GSChannel -- ^ Channel Map (Internal)
             -> IO (GUIWire (Maybe String) String, Map String GSChannel) -- ^ resulting Wire
htmlW elid gsMap = guiWireGen elid gsMap htmlW'

-- button wire
--

buttonW' :: String -> GSChannel -> IO (GUIWire a a)
buttonW' boxid channel = do
  let wire =  mkFixM (\t var -> do
                                     rcv <- receiveGMReadChannel channel
                                     case rcv of
                                       Just gs -> do
                                           return $ Right var
                                       _ -> do
                                           return $ Left () )
  return wire                                                         
  
-- | Basic wire for Button GUI element functionality (output element with dynamic HTML)
buttonW :: String -- ^ Element Id
             -> Map String GSChannel -- ^ Channel Map (Internal)
             -> IO (GUIWire a a, Map String GSChannel) -- ^ resulting Wire
buttonW elid gsMap = guiWireGen elid gsMap buttonW'



_loopAWire wire session = do
    (r, wire',  session') <- stepSession wire session ()
    threadDelay 10000
    _loopAWire wire' session'
    return ()

loopHWebUIWire theWire = _loopAWire theWire clockSession