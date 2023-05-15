{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Subscription.Case.Publishing
  ( testPublishing,
  )
where

import Data.Morpheus.Subscriptions
  ( Event (..),
  )
import Data.Morpheus.Subscriptions.Internal
  ( Input,
    SUB,
    connect,
    empty,
  )
import Subscription.API
  ( Channel (..),
    EVENT,
    Info (..),
    app,
  )
import Subscription.Utils
  ( Signal,
    SimulationState (..),
    apolloConnectionAck,
    apolloInit,
    apolloRes,
    apolloStop,
    inputsAreConsumed,
    simulate,
    simulatePublish,
    storeSubscriptions,
    subscribe,
    testResponse,
  )
import Test.Tasty
  ( TestTree,
    testGroup,
  )
import Prelude

newDeity :: Int -> Signal
newDeity = subscribe "subscription MySubscription { newDeity { name , age }}"

newHuman :: Int -> Signal
newHuman = subscribe "subscription MySubscription { newHuman { name , age }}"

simulateSubscriptions :: IO (Input SUB, SimulationState EVENT)
simulateSubscriptions = do
  input <- connect
  state <- simulate app input initial
  pure (input, state)
  where
    initial =
      SimulationState
        { inputs =
            [ apolloInit,
              newDeity 1,
              newDeity 2,
              newDeity 3,
              newHuman 4,
              apolloStop 1
            ],
          outputs = [],
          store = empty
        }

triggerSubscription ::
  IO TestTree
triggerSubscription = do
  (input, state) <- simulateSubscriptions
  SimulationState {inputs, outputs, store} <-
    simulatePublish (Event [DEITY] Info {name = "Zeus", age = 1200}) state
      >>= simulatePublish (Event [HUMAN] Info {name = "Hercules", age = 18})
  pure $
    testGroup
      "publish event"
      [ inputsAreConsumed inputs,
        testResponse
          -- triggers subscriptions by channels
          [ apolloConnectionAck,
            apolloRes
              2
              "{\"newDeity\":{\"name\":\"Zeus\",\"age\":1200}}",
            apolloRes
              3
              "{\"newDeity\":{\"name\":\"Zeus\",\"age\":1200}}",
            apolloRes
              4
              "{\"newHuman\":{\"name\":\"Hercules\",\"age\":18}}"
          ]
          outputs,
        storeSubscriptions
          input
          ["2", "3", "4"]
          store
      ]

testPublishing :: IO TestTree
testPublishing = do
  trigger <- triggerSubscription
  return $ testGroup "Publishing" [trigger]
