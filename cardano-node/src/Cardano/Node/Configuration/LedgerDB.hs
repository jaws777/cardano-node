{-# LANGUAGE NumericUnderscores #-}

module Cardano.Node.Configuration.LedgerDB (
    BackingStoreSelectorFlag(..)
  , defaultLMDBLimits
  ) where

import           Prelude

import           Ouroboros.Consensus.Storage.LedgerDB.HD.LMDB (LMDBLimits (..))

-- | Choose the LedgerDB Backend
--
-- As of UTxO-HD, the LedgerDB now uses either an in-memory backend or LMDB to
-- keep track of differences in the UTxO set.
--
-- - 'InMemory': uses more memory than the minimum requirements but is somewhat
--   faster.
-- - 'LMDB': uses less memory but is somewhat slower.
--
-- See 'Ouroboros.Consnesus.Storage.LedgerDB.OnDisk.BackingStoreSelector'.
data BackingStoreSelectorFlag =
    LMDB (Maybe Int) -- ^ A map size can be specified, this is the maximum disk
                     -- space the LMDB database can fill. If not provided, the
                     -- default of 12Gi will be used.
  | InMemory
  deriving (Eq, Show)

-- | Recommended settings for the LMDB backing store.
--
-- The default @'LMDBLimits'@ uses an @'lmdbMapSize'@ of @16_000_000_000@
-- bytes, or 16 GigaBytes. @'lmdbMapSize'@ sets the size of the memory map
-- that is used internally by the LMDB backing store, and is also the
-- maximum size of the on-disk database. 16 GB should be sufficient for the
-- medium term, i.e., it is sufficient until a more performant alternative to
-- the LMDB backing store is implemented, which will probably replace the LMDB
-- backing store altogether.
--
-- Note(jdral): It is recommended not to set the @'lmdbMapSize'@ to a value
-- that is much smaller than 16 GB through manual configuration: the node will
-- die with a fatal error as soon as the database size exceeds the
-- @'lmdbMapSize'@. If this fatal error were to occur, we would expect that
-- the node can continue normal operation if it is restarted with a higher
-- @'lmdbMapSize'@ configured. Nonetheless, this situation should be avoided.
defaultLMDBLimits :: LMDBLimits
defaultLMDBLimits = LMDBLimits {
    lmdbMapSize = 16_000_000_000
  , lmdbMaxDatabases = 10
  , lmdbMaxReaders = 16
  }