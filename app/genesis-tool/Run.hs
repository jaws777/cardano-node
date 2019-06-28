{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

module Run (
    decideKeyMaterialOps
  , runCommand
  ) where

import           Prelude (String, error, id)

import           Codec.CBOR.Write (toLazyByteString)
import           Control.Monad
import           Data.Semigroup ((<>))
import           Data.Text (Text)
import qualified Data.ByteString.Lazy as LB
import           System.Posix.Files (ownerReadMode, setFileMode)
import           System.Directory (createDirectory, doesPathExist)
import           Text.Printf (printf)

import qualified Text.JSON.Canonical as CanonicalJSON

import qualified Crypto.SCRAPE as Scrape

import           Cardano.Prelude hiding (option)

import           Cardano.Crypto.Random (runSecureRandom)
import           Cardano.Crypto.Signing (SigningKey(..), toCBORXPrv)

import           Cardano.Chain.Genesis

import qualified Byron.Legacy as Legacy
import           CLI

runCommand :: KeyMaterialOps IO -> Command -> IO ()
runCommand
  KeyMaterialOps{..}
  (Genesis
    outDir
    startTime
    protocolParametersFile
    blockCount
    protocolMagic
    giTestBalance
    giFakeAvvmBalance
    giAvvmBalanceFactor
    giSeed)
  = do

    exists <- doesPathExist outDir
    if exists
      then error $ "Genesis output directory must not already exist: " <> outDir
      else createDirectory outDir

    protoParamsRaw <- LB.readFile protocolParametersFile
    let protocolParameters = either (error . show) id $ canonicalDecPre protoParamsRaw

    -- We're relying on the generator to fake AVVM and delegation.
    mGenesisDelegation <- runExceptT $ mkGenesisDelegation []
    let genesisDelegation   = either (error . show) id mGenesisDelegation
        genesisAvvmBalances = GenesisAvvmBalances mempty

    let mGenesisSpec =
          mkGenesisSpec
          genesisAvvmBalances -- :: !GenesisAvvmBalances
          genesisDelegation   -- :: !GenesisDelegation
          protocolParameters  -- :: !ProtocolParameters
          blockCount          -- :: !BlockCount
          protocolMagic       -- :: !ProtocolMagic
          genesisInitializer  -- :: !GenesisInitializer
        genesisInitializer =
          GenesisInitializer
          giTestBalance       -- :: !TestnetBalanceOptions
          giFakeAvvmBalance   -- :: !FakeAvvmOptions
          giAvvmBalanceFactor -- :: !LovelacePortion
          giUseHeavyDlg       -- :: !Bool
          giSeed              -- :: !Integer
        giUseHeavyDlg =
          True                -- Not using delegate keys unsupported.

    let genesisSpec = either (error . show) id mGenesisSpec

    -- Generate (mostly)
    res <- runExceptT $ generateGenesisData startTime genesisSpec
    let (genesisData, GeneratedSecrets{..}) = either (error . show) id res

    -- Write out (mostly)
    let genesisJSONFile = outDir <> "/genesis.json"
    LB.writeFile genesisJSONFile =<< kmoSerialiseGenesis genesisData

    writeSecrets outDir "genesis-keys"  "key"  kmoSerialiseGenesisKey   gsDlgIssuersSecrets
    writeSecrets outDir "delegate-keys" "key"  kmoSerialiseDelegateKey  gsRichSecrets
    writeSecrets outDir "poor-keys"     "key"  kmoSerialisePoorKey      gsPoorSecrets
    writeSecrets outDir "avvm-seed"     "seed" (pure . LB.fromStrict)   gsFakeAvvmSeeds

decideKeyMaterialOps :: SystemVersion -> KeyMaterialOps IO
decideKeyMaterialOps =
  let serialiseSigningKey (SigningKey x) = toLazyByteString $ toCBORXPrv x
  in \case
  ByronLegacy ->
    KeyMaterialOps
    { kmoSerialiseGenesisKey  = pure . serialiseSigningKey
    , kmoSerialiseDelegateKey = \sk->
        toLazyByteString . Legacy.encodeLegacyDelegateKey . Legacy.LegacyDelegateKey sk
        <$> runSecureRandom Scrape.keyPairGenerate
    , kmoSerialisePoorKey     = pure . serialiseSigningKey . poorSecretToKey
    , kmoSerialiseGenesis     = pure . canonicalEncPre
    }
  ByronPBFT ->
    KeyMaterialOps
    { kmoSerialiseGenesisKey  = pure . serialiseSigningKey
    , kmoSerialiseDelegateKey = pure . serialiseSigningKey
    , kmoSerialisePoorKey     = pure . serialiseSigningKey . poorSecretToKey
    , kmoSerialiseGenesis     = pure . canonicalEncPre
    }

writeSecrets :: FilePath -> String -> String -> (a -> IO LB.ByteString) -> [a] -> IO ()
writeSecrets outDir prefix suffix secretOp xs =
  forM_ (zip xs $ [0::Int ..]) $
  \(secret, nr)-> do
    let filename = outDir <> "/" <> prefix <> "." <> printf "%03d" nr <> "." <> suffix
    secretOp secret >>= LB.writeFile filename
    setFileMode                      filename ownerReadMode

-- Stolen from: cardano-prelude/test/Test/Cardano/Prelude/Tripping.hs
canonicalEncPre
  :: forall a . CanonicalJSON.ToJSON Identity a => a -> LB.ByteString
canonicalEncPre x =
  LB.fromStrict
    . encodeUtf8
    . toS
    $ CanonicalJSON.prettyCanonicalJSON
    $ runIdentity
    $ CanonicalJSON.toJSON x

-- Stolen from: cardano-prelude/test/Test/Cardano/Prelude/Tripping.hs
canonicalDecPre
  :: forall a
   . CanonicalJSON.FromJSON (Either SchemaError) a
  => LB.ByteString
  -> Either Text a
canonicalDecPre bs = do
  eVal <- first toS (CanonicalJSON.parseCanonicalJSON bs)
  first show (CanonicalJSON.fromJSON eVal :: Either SchemaError a)
