{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Subscription.Utils
  ( SimulationState (..),
    simulate,
    expectedResponse,
    SubM,
    testResponse,
    inputsAreConsumed,
    storeIsEmpty,
    storedSingle,
    stored,
    storeSubscriptions,
    simulatePublish,
    subscribe,
    apolloStop,
    apolloRes,
    apolloInit,
    apolloConnectionAck,
    apolloConnectionErr,
    apolloPing,
    apolloPong,
    testSimulation,
    Signal (..),
    signal,
    expectResponseError,
  )
where

import Data.Aeson (encode, fromJSON, genericLiftToJSON)
import Data.Aeson.Decoding (decode, eitherDecode)
import Data.Aeson.Types
  ( FromJSON (..),
    Options (..),
    ToJSON (toJSON),
    Value,
    defaultOptions,
    genericParseJSON,
    genericToJSON,
  )
import Data.ByteString.Lazy.Char8
  ( ByteString,
  )
import Data.Char (toLower)
import Data.List (lookup)
import Data.Morpheus
  ( App,
  )
import Data.Morpheus.Subscriptions
  ( Event,
  )
import Data.Morpheus.Subscriptions.Internal
  ( ApiContext (..),
    ClientConnectionStore,
    Input (..),
    SUB,
    connect,
    connectionSessionIds,
    empty,
    publish,
    runStreamWS,
    streamApp,
    toList,
  )
import Relude hiding
  ( ByteString,
    empty,
    toList,
  )
import Test.Tasty
  ( TestTree,
  )
import Test.Tasty.HUnit
  ( assertEqual,
    assertFailure,
    testCase,
  )

data SimulationState e = SimulationState
  { inputs :: [Signal],
    outputs :: [ByteString],
    store :: ClientConnectionStore e (SubM e)
  }

type Store e = ClientConnectionStore e (SubM e)

type SubM e = StateT (SimulationState e) IO

addOutput :: ByteString -> SimulationState e -> ((), SimulationState e)
addOutput x (SimulationState i xs st) = ((), SimulationState i (xs <> [x]) st)

mockUpdateStore :: (Store e -> Store e) -> SimulationState e -> ((), SimulationState e)
mockUpdateStore up (SimulationState i o st) = ((), SimulationState i o (up st))

readInput :: SimulationState e -> (ByteString, SimulationState e)
readInput (SimulationState (i : ins) o s) = (encode i, SimulationState ins o s)
readInput (SimulationState [] o s) = ("<Error>", SimulationState [] o s)

wsApp ::
  (Eq ch, Hashable ch) =>
  App (Event ch e) (SubM (Event ch e)) ->
  Input SUB ->
  SubM (Event ch e) ()
wsApp app =
  runStreamWS
    SubContext
      { updateStore = state . mockUpdateStore,
        listener = state readInput,
        callback = state . addOutput
      }
    . streamApp app

simulatePublish ::
  (Eq ch, Show ch, Hashable ch) =>
  Event ch con ->
  SimulationState (Event ch con) ->
  IO (SimulationState (Event ch con))
simulatePublish event s = snd <$> runStateT (publish event (store s)) s

simulate ::
  (Eq ch, Hashable ch) =>
  App (Event ch con) (SubM (Event ch con)) ->
  Input SUB ->
  SimulationState (Event ch con) ->
  IO (SimulationState (Event ch con))
simulate _ _ s@SimulationState {inputs = []} = pure s
simulate api input s = runStateT (wsApp api input) s >>= simulate api input . snd

testSimulation ::
  (Eq ch, Hashable ch) =>
  (Input SUB -> SimulationState (Event ch con) -> TestTree) ->
  [Signal] ->
  App (Event ch con) (SubM (Event ch con)) ->
  IO TestTree
testSimulation test simInputs api = do
  input <- connect
  s <- simulate api input (SimulationState simInputs [] empty)
  pure $ test input s

expectedResponse :: (Show a, Eq a) => [a] -> [a] -> IO ()
expectedResponse expected value
  | expected == value = pure ()
  | otherwise =
      assertFailure $ "expected: \n " <> show expected <> " \n but got: \n " <> show value

expectResponseError :: ByteString -> [ByteString] -> TestTree
expectResponseError err = testCase "expected response" . expectedResponse [err]

testResponse :: [Signal] -> [ByteString] -> TestTree
testResponse expected inputs = testCase "expected response" $
  do
    res <- either fail pure (traverse eitherDecode inputs)
    expectedResponse expected res

inputsAreConsumed :: [Signal] -> TestTree
inputsAreConsumed =
  testCase "inputs are consumed"
    . assertEqual
      "input stream should be consumed"
      []

storeIsEmpty :: (Show ch) => Store (Event ch con) -> TestTree
storeIsEmpty cStore
  | null (toList cStore) =
      testCase "connectionStore: is empty" $ pure ()
  | otherwise =
      testCase "connectionStore: is empty" $
        assertFailure $
          " must be empty but "
            <> show
              cStore

storedSingle :: (Show ch) => Store (Event ch con) -> TestTree
storedSingle cStore
  | length (toList cStore) == 1 =
      testCase "stored single connection" $ pure ()
  | otherwise =
      testCase "stored single connection" $
        assertFailure $
          "connectionStore must store single connection, but stored: "
            <> show
              cStore

stored :: (Show ch) => Input SUB -> Store (Event ch con) -> TestTree
stored (InitConnection uuid) cStore
  | isJust (lookup uuid (toList cStore)) =
      testCase "stored connection" $ pure ()
  | otherwise =
      testCase "stored connection" $
        assertFailure $
          " must store connection \""
            <> show uuid
            <> "\" but stored: "
            <> show
              cStore

storeSubscriptions ::
  (Show ch) =>
  Input SUB ->
  [Text] ->
  Store (Event ch con) ->
  TestTree
storeSubscriptions
  (InitConnection uuid)
  sids
  cStore =
    checkSession (lookup uuid (toList cStore))
    where
      checkSession (Just conn)
        | sort sids == sort (connectionSessionIds conn) =
            testCase "stored subscriptions" $ pure ()
        | otherwise =
            testCase "stored subscriptions" $
              assertFailure $
                " must store subscriptions with id \""
                  <> show sids
                  <> "\" but stored: "
                  <> show
                    (connectionSessionIds conn)
      checkSession _ =
        testCase "stored connection" $
          assertFailure $
            " must store connection \""
              <> show uuid
              <> "\" but: "
              <> show
                cStore

data PayloadQuery = PayloadQuery
  { variables :: Maybe Value,
    operationName :: String,
    query :: String
  }
  deriving (Generic, ToJSON)

newtype PayloadData = PayloadData {payloadData :: Value}
  deriving (Generic)

payloadOptions :: Options
payloadOptions =
  ( defaultOptions
      { fieldLabelModifier = map toLower . drop (length ("Payload" :: String)),
        omitNothingFields = True
      }
  )

instance ToJSON PayloadData where
  toJSON = genericToJSON payloadOptions

subscribe :: String -> Int -> Signal
subscribe query sid =
  Signal
    { signalId = Just (show sid),
      signalType = "subscribe",
      signalPayload =
        Just
          ( toJSON
              PayloadQuery
                { variables = Nothing,
                  operationName = "MySubscription",
                  query
                }
          )
    }

apolloStop :: Int -> Signal
apolloStop x = signal {signalType = "complete", signalId = Just (show x)}

apolloRes :: Int -> ByteString -> Signal
apolloRes sid value =
  Signal
    { signalId = Just (show sid),
      signalType = "next",
      signalPayload = toJSON . PayloadData <$> decode value
    }

apolloInit :: Signal
apolloInit = signal {signalType = "connection_init"}

apolloConnectionAck :: Signal
apolloConnectionAck = signal {signalType = "connection_ack"}

apolloConnectionErr :: Signal
apolloConnectionErr = signal {signalType = "connection_error"}

apolloPing :: Signal
apolloPing = signal {signalType = "ping"}

apolloPong :: Signal
apolloPong = signal {signalType = "pong"}

signal :: Signal
signal = Signal {signalType = "", signalPayload = Nothing, signalId = Nothing}

data Signal = Signal
  { signalType :: String,
    signalPayload :: Maybe Value,
    signalId :: Maybe String
  }
  deriving (Generic, Ord, Eq, Show)

options :: Options
options =
  defaultOptions
    { fieldLabelModifier = map toLower . drop 6,
      omitNothingFields = True
    }

instance FromJSON Signal where
  parseJSON = genericParseJSON options

instance ToJSON Signal where
  toJSON = genericToJSON options
