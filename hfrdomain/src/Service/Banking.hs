{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Service.Banking where

import qualified Money as Y
import           Data.Text hiding (foldl')
import           Data.Foldable
import           Data.Pool
import           Data.Time
import           Data.Maybe (fromJust)
import           Validation (Validation ( ..) )
import           Polysemy
import           Polysemy.Input
import           Control.Applicative
import           Control.Monad.Trans.Maybe 
import           Control.Lens hiding (element)
import           Database.Persist.Sqlite (SqlBackend)
import           Database.Redis (Connection)

import           Model.Schema
import           Model.Account (isAccountClosed)
import           Model.Transaction (makeTransaction)
import           Model.TransactionType
import qualified Repository.AccountRepository as AR
import qualified Repository.TransactionRepository as TR
import qualified Repository.AccountCache as AC

-- | a domain service for doing debit or credit transactions
transact :: Pool SqlBackend -> Connection -> TransactionType -> Text -> UTCTime -> Y.Dense "USD" -> IO ()
transact conn rconn txnType ano txnDate amount = runAllEffects conn rconn doTransaction
  where 
    doTransaction = do 
      maybeAcc  <- runMaybeT $ 
                         MaybeT (AC.fetchCachedAccount ano) 
                     <|> MaybeT (AR.queryAccount ano)

      maybe (error $ "Invalid account " ++ show ano) doDB maybeAcc
        where
          doDB acc =
            TR.store (makeFullTransaction Dr txnDate amount ano) >>
               AR.upsert updatedBalance
                 where 
                   updatedBalance = case txnType of
                     Dr -> acc & currentBalance %~ subtract amount
                     Cr -> acc & currentBalance %~ (+ amount)

doTransact :: Pool SqlBackend 
    -> Connection 
    -> UTCTime 
    -> TransactionType 
    -> Text 
    -> UTCTime 
    -> Y.Dense "USD" 
    -> IO ()
doTransact conn rconn utcCurrent txnType ano txnDate amount = runAllEffects conn rconn doTransaction
  where 
    doTransaction = do 
      maybeAcc  <- runMaybeT $ 
                         MaybeT (AC.fetchCachedAccount ano) 
                     <|> MaybeT (AR.queryAccount ano)

      maybe (error $ "Invalid account " ++ show ano) doDB maybeAcc
        where
          doDB acc = case makeTransaction utcCurrent Dr txnDate amount ano of
            Success txn -> TR.store txn >> AR.upsert (updatedBalance acc)
            Failure err -> error $ show err

          updatedBalance acc = case txnType of
             Dr -> acc & currentBalance %~ subtract amount
             Cr -> acc & currentBalance %~ (+ amount)

-- | a domain service that accesses multiple repositories to fetch account and
-- | transactions, computes the net value of all transactions fetched and updates
-- | the balance in the account repository
netValueTransactionsForAccount :: Pool SqlBackend -> Connection -> Text -> IO ()
netValueTransactionsForAccount conn rconn ano = runAllEffects conn rconn doNetValueComputation
  where 
    zeroDollars = 0 :: Y.Dense "USD"
    doNetValueComputation = do

      -- try to get the account from cache, if not found, fetch from database
      maybeAcc  <- runMaybeT $ 
                         MaybeT (AC.fetchCachedAccount ano) 
                     <|> MaybeT (AR.queryAccount ano)

      -- fail if the account does not exist
      -- if exists, check if the account is already closed
      let maybeCloseDate = maybe (fail $ "Invalid account " ++ show ano) 
                                 isAccountClosed 
                                 maybeAcc

      -- fail if the account is already closed
      -- otherwise compute net value of all transactions for the account and update
      maybe (computeNetValueAndUpdate $ fromJust maybeAcc) 
            accountClosedErr 
            maybeCloseDate

        where
          accountClosedErr closeDate = error ("Account number " ++ show ano ++ " is closed on " ++ show closeDate)
          computeNetValueAndUpdate acc = do
            txns <- TR.queryByAccount ano

            let amount = foldl' (+) zeroDollars (signValAmount <$> txns)
                updated = acc & currentBalance %~ (+ amount)

            AR.store updated
            AC.cacheAccount updated
              where 
                signValAmount txn = 
                  if txn ^. transactionType == Cr
                    then txn ^. transactionAmount
                    else (-1) * (txn ^. transactionAmount)

runAllEffects :: 
     Pool SqlBackend 
  -> Connection
  -> Sem '[AR.AccountRepository, TR.TransactionRepository, AC.AccountCache, Input (Pool SqlBackend), Input Connection, Embed IO] a 
  -> IO a

runAllEffects conn rconn program =
  program                    
    & AR.runAccountRepository
    & TR.runTransactionRepository
    & AC.runAccountCache
    & runInputConst conn  
    & runInputConst rconn  
    & runM
