{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Shelley.TxBody
  ( DCert (..),
    DelegCert (..),
    Delegation (..),
    GenesisDelegCert (..),
    MIRCert (..),
    MIRPot (..),
    MIRTarget (..),
    PoolCert (..),
    PoolMetadata (..),
    PoolParams (..),
    Ptr (..),
    RewardAcnt (..),
    StakePoolRelay (..),
    TxBody
      ( TxBody,
        TxBodyConstr,
        _inputs,
        _outputs,
        _certs,
        _wdrls,
        _txfee,
        _ttl,
        _txUpdate,
        _mdHash
      ),
    ShelleyEraTxBody (..),
    TxBodyRaw (..),
    EraIndependentTxBody,
    TxOut (TxOut, TxOutCompact),
    Url,
    Wdrl (..),
    --
    module Cardano.Ledger.Keys.WitVKey,
    witKeyHash,
    wvkBytes,
    --
    SizeOfPoolOwners (..),
    SizeOfPoolRelays (..),
  )
where

import Cardano.Binary
  ( Annotator (..),
    FromCBOR (fromCBOR),
    ToCBOR (..),
    encodeListLen,
  )
import qualified Cardano.Crypto.Hash.Class as HS
import Cardano.Ledger.Address (Addr (..), RewardAcnt (..))
import Cardano.Ledger.AuxiliaryData (AuxiliaryDataHash)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), Url)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.CompactAddress (CompactAddr, compactAddr, decompactAddr)
import Cardano.Ledger.Compactible
import qualified Cardano.Ledger.Core as Core
import Cardano.Ledger.Credential (Credential (..), Ptr (..))
import qualified Cardano.Ledger.Crypto as CC
import Cardano.Ledger.Era
import Cardano.Ledger.Hashes (EraIndependentTxBody)
import Cardano.Ledger.Keys (KeyHash (..), KeyRole (..))
import Cardano.Ledger.Keys.WitVKey
import Cardano.Ledger.SafeHash (HashAnnotated, SafeToHash)
import Cardano.Ledger.Serialization
  ( decodeRecordNamed,
    decodeSet,
    decodeStrictSeq,
    encodeFoldable,
    mapFromCBOR,
    mapToCBOR,
  )
import Cardano.Ledger.Shelley.Core (ShelleyEra)
import Cardano.Ledger.Shelley.Delegation.Certificates
  ( DCert (..),
    DelegCert (..),
    Delegation (..),
    GenesisDelegCert (..),
    MIRCert (..),
    MIRPot (..),
    MIRTarget (..),
    PoolCert (..),
  )
import Cardano.Ledger.Shelley.PParams (Update)
import Cardano.Ledger.Shelley.PoolParams
import Cardano.Ledger.Slot (SlotNo (..))
import qualified Cardano.Ledger.TxIn as Core
import Cardano.Ledger.Val (DecodeNonNegative (..))
import Cardano.Prelude (HeapWords (..))
import Control.DeepSeq (NFData (rnf))
import qualified Data.ByteString.Lazy as BSL
import Data.ByteString.Short (ShortByteString, pack)
import Data.Coders
  ( Decode (..),
    Density (..),
    Encode (..),
    Field,
    Wrapped (..),
    decode,
    encode,
    encodeKeyedStrictMaybe,
    field,
    invalidField,
    ofield,
    (!>),
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.MemoBytes (Mem, MemoBytes (..), memoBytes)
import Data.Proxy (Proxy (..))
import Data.Sequence.Strict (StrictSeq)
import qualified Data.Sequence.Strict as StrictSeq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Sharing
import Data.Typeable (Typeable)
import Data.Word (Word8)
import GHC.Generics (Generic)
import GHC.Stack
import Lens.Micro
import NoThunks.Class (InspectHeapNamed (..), NoThunks (..))

-- ========================================================================

newtype Wdrl crypto = Wdrl {unWdrl :: Map (RewardAcnt crypto) Coin}
  deriving (Show, Eq, Generic)
  deriving newtype (NoThunks, NFData)

instance CC.Crypto crypto => ToCBOR (Wdrl crypto) where
  toCBOR = mapToCBOR . unWdrl

instance CC.Crypto crypto => FromCBOR (Wdrl crypto) where
  fromCBOR = Wdrl <$> mapFromCBOR

data TxOut era = TxOutCompact
  { txOutCompactAddr :: {-# UNPACK #-} !(CompactAddr (Crypto era)),
    txOutCompactValue :: !(CompactForm (Core.Value era))
  }

instance CC.Crypto crypto => Core.EraTxOut (ShelleyEra crypto) where
  type TxOut (ShelleyEra crypto) = TxOut (ShelleyEra crypto)

  mkBasicTxOut = TxOut

  txOutAddrEitherL =
    lens
      (Right . txOutCompactAddr)
      ( \txOut -> \case
          Left addr -> txOut {txOutCompactAddr = compactAddr addr}
          Right cAddr -> txOut {txOutCompactAddr = cAddr}
      )
  txOutValueEitherL =
    lens
      (Right . txOutCompactValue)
      ( \txOut -> \case
          Left value ->
            txOut
              { txOutCompactValue =
                  fromMaybe (error $ "Illegal value in TxOut: " <> show value) $ toCompact value
              }
          Right cValue -> txOut {txOutCompactValue = cValue}
      )

-- assume Shelley+ type address : payment addr, staking addr (same length as payment), plus 1 word overhead
instance (Era era, HeapWords (CompactForm (Core.Value era))) => HeapWords (TxOut era) where
  heapWords (TxOutCompact _ vl) =
    3
      + heapWords (packedADDRHASH (Proxy :: Proxy era))
      + heapWords vl

-- a ShortByteString of the same length as the ADDRHASH
-- used to calculate heapWords
packedADDRHASH :: forall proxy era. (CC.Crypto (Crypto era)) => proxy era -> ShortByteString
packedADDRHASH _ = pack (replicate (fromIntegral (1 + 2 * HS.sizeHash (Proxy :: Proxy (CC.ADDRHASH (Crypto era))))) (1 :: Word8))

instance
  (Core.EraTxOut era) =>
  Show (TxOut era)
  where
  show = show . viewCompactTxOut -- FIXME: showing TxOut as a tuple is just sad

deriving instance Eq (TxOut (ShelleyEra crypto))

instance NFData (TxOut era) where
  rnf = (`seq` ())

deriving via InspectHeapNamed "TxOut" (TxOut era) instance NoThunks (TxOut era)

pattern TxOut ::
  (HasCallStack, Core.EraTxOut era) =>
  Addr (Crypto era) ->
  Core.Value era ->
  TxOut era
pattern TxOut addr vl <-
  (viewCompactTxOut -> (addr, vl))
  where
    TxOut addr vl =
      TxOutCompact
        (compactAddr addr)
        (fromMaybe (error $ "Illegal value in TxOut: " <> show vl) $ toCompact vl)

{-# COMPLETE TxOut #-}

viewCompactTxOut ::
  Core.EraTxOut era =>
  TxOut era ->
  (Addr (Crypto era), Core.Value era)
viewCompactTxOut TxOutCompact {txOutCompactAddr, txOutCompactValue} =
  (decompactAddr txOutCompactAddr, fromCompact txOutCompactValue)

-- ---------------------------
-- WellFormed instances

-- ==============================
-- The underlying type for TxBody

data TxBodyRaw era = TxBodyRaw
  { _inputsX :: !(Set (Core.TxIn (Crypto era))),
    _outputsX :: !(StrictSeq (Core.TxOut era)),
    _certsX :: !(StrictSeq (DCert (Crypto era))),
    _wdrlsX :: !(Wdrl (Crypto era)),
    _txfeeX :: !Coin,
    _ttlX :: !SlotNo,
    _txUpdateX :: !(StrictMaybe (Update era)),
    _mdHashX :: !(StrictMaybe (AuxiliaryDataHash (Crypto era)))
  }
  deriving (Generic, Typeable)

deriving instance
  NoThunks (Core.PParamsDelta (ShelleyEra crypto)) =>
  NoThunks (TxBodyRaw (ShelleyEra crypto))

deriving instance
  (CC.Crypto crypto, NFData (Core.PParamsDelta (ShelleyEra crypto))) =>
  NFData (TxBodyRaw (ShelleyEra crypto))

deriving instance
  (CC.Crypto crypto, Eq (Core.PParamsDelta (ShelleyEra crypto))) =>
  Eq (TxBodyRaw (ShelleyEra crypto))

deriving instance
  ( CC.Crypto crypto,
    Show (Core.PParamsDelta (ShelleyEra crypto))
  ) =>
  Show (TxBodyRaw (ShelleyEra crypto))

instance
  (FromCBOR (Core.PParamsDelta (ShelleyEra crypto)), CC.Crypto crypto) =>
  FromCBOR (TxBodyRaw (ShelleyEra crypto))
  where
  fromCBOR =
    decode
      ( SparseKeyed
          "TxBody"
          baseTxBodyRaw
          boxBody
          [(0, "inputs"), (1, "outputs"), (2, "fee"), (3, "ttl")]
      )

instance
  ( ToCBOR (Core.PParamsDelta (ShelleyEra crypto)),
    Typeable crypto,
    CC.Crypto crypto,
    FromCBOR (Core.PParamsDelta (ShelleyEra crypto))
  ) =>
  FromCBOR (Annotator (TxBodyRaw (ShelleyEra crypto)))
  where
  fromCBOR = pure <$> fromCBOR

-- =================================================================
-- Composable components for building TxBody optional sparse serialisers.
-- The order of serializing optional fields, and their key values is
-- demanded by backward compatibility concerns.

-- | Choose a de-serialiser when given the key (of type Word).
--   Wrap it in a Field which pairs it with its update function which
--   changes only the field being deserialised.
boxBody ::
  (FromCBOR (Core.PParamsDelta (ShelleyEra crypto)), CC.Crypto crypto) =>
  Word ->
  Field (TxBodyRaw (ShelleyEra crypto))
boxBody 0 = field (\x tx -> tx {_inputsX = x}) (D (decodeSet fromCBOR))
boxBody 1 = field (\x tx -> tx {_outputsX = x}) (D (decodeStrictSeq fromCBOR))
boxBody 4 = field (\x tx -> tx {_certsX = x}) (D (decodeStrictSeq fromCBOR))
boxBody 5 = field (\x tx -> tx {_wdrlsX = x}) From
boxBody 2 = field (\x tx -> tx {_txfeeX = x}) From
boxBody 3 = field (\x tx -> tx {_ttlX = x}) From
boxBody 6 = ofield (\x tx -> tx {_txUpdateX = x}) From
boxBody 7 = ofield (\x tx -> tx {_mdHashX = x}) From
boxBody n = invalidField n

-- | Tells how to serialise each field, and what tag to label it with in the
--   serialisation. boxBody and txSparse should be Duals, visually inspect
--   The key order looks strange but was choosen for backward compatibility.
txSparse ::
  (ToCBOR (Core.PParamsDelta (ShelleyEra crypto)), CC.Crypto crypto) =>
  TxBodyRaw (ShelleyEra crypto) ->
  Encode ('Closed 'Sparse) (TxBodyRaw (ShelleyEra crypto))
txSparse (TxBodyRaw input output cert wdrl fee ttl update hash) =
  Keyed (\i o f t c w u h -> TxBodyRaw i o c w f t u h)
    !> Key 0 (E encodeFoldable input) -- We don't have to send these in TxBodyRaw order
    !> Key 1 (E encodeFoldable output) -- Just hack up a fake constructor with the lambda.
    !> Key 2 (To fee)
    !> Key 3 (To ttl)
    !> Omit null (Key 4 (E encodeFoldable cert))
    !> Omit (null . unWdrl) (Key 5 (To wdrl))
    !> encodeKeyedStrictMaybe 6 update
    !> encodeKeyedStrictMaybe 7 hash

-- The initial TxBody. We will overide some of these fields as we build a TxBody,
-- adding one field at a time, using optional serialisers, inside the Pattern.
baseTxBodyRaw :: TxBodyRaw (ShelleyEra crypto)
baseTxBodyRaw =
  TxBodyRaw
    { _inputsX = Set.empty,
      _outputsX = StrictSeq.empty,
      _txfeeX = Coin 0,
      _ttlX = SlotNo 0,
      _certsX = StrictSeq.empty,
      _wdrlsX = Wdrl Map.empty,
      _txUpdateX = SNothing,
      _mdHashX = SNothing
    }

instance
  (ToCBOR (Core.PParamsDelta (ShelleyEra crypto)), CC.Crypto crypto) =>
  ToCBOR (TxBodyRaw (ShelleyEra crypto))
  where
  toCBOR x = encode (txSparse x)

-- ====================================================
-- Introduce TxBody as a newtype around a MemoBytes

newtype TxBody era = TxBodyConstr (MemoBytes (TxBodyRaw era))
  deriving (Generic, Typeable)
  deriving newtype (SafeToHash)

instance CC.Crypto crypto => Core.EraTxBody (ShelleyEra crypto) where
  type TxBody (ShelleyEra crypto) = TxBody (ShelleyEra crypto)

  txBodyInputsG = to (\(TxBodyConstr (Memo m _)) -> _inputsX m)
  txBodyAllInputsG = Core.txBodyInputsG

  txBodyOutputsG = to (\(TxBodyConstr (Memo m _)) -> _outputsX m)

  txBodyTxFeeG = to (\(TxBodyConstr (Memo m _)) -> _txfeeX m)

  txBodyMintedG = to (const Set.empty) -- TODO: fix this wart

  txBodyAdHashG = to (\(TxBodyConstr (Memo m _)) -> _mdHashX m)

class Core.EraTxBody era => ShelleyEraTxBody era where
  txBodyWdrlsG :: SimpleGetter (Core.TxBody era) (Wdrl (Crypto era))

  txBodyTtlG :: SimpleGetter (Core.TxBody era) SlotNo

  txBodyUpdateG :: SimpleGetter (Core.TxBody era) (StrictMaybe (Update era))

  txBodyCertsG :: SimpleGetter (Core.TxBody era) (StrictSeq (DCert (Crypto era)))

instance CC.Crypto crypto => ShelleyEraTxBody (ShelleyEra crypto) where
  txBodyWdrlsG = to (\(TxBodyConstr (Memo m _)) -> _wdrlsX m)

  txBodyTtlG = to (\(TxBodyConstr (Memo m _)) -> _ttlX m)

  txBodyUpdateG = to (\(TxBodyConstr (Memo m _)) -> _txUpdateX m)

  txBodyCertsG = to (\(TxBodyConstr (Memo m _)) -> _certsX m)

deriving newtype instance
  ( Typeable crypto,
    NoThunks (Core.PParamsDelta (ShelleyEra crypto))
  ) =>
  NoThunks (TxBody (ShelleyEra crypto))

deriving newtype instance
  (CC.Crypto crypto, NFData (Core.PParamsDelta (ShelleyEra crypto))) =>
  NFData (TxBody (ShelleyEra crypto))

deriving instance
  ( CC.Crypto crypto,
    Show (Core.PParamsDelta (ShelleyEra crypto))
  ) =>
  Show (TxBody (ShelleyEra crypto))

deriving instance Eq (TxBody (ShelleyEra crypto))

deriving via
  (Mem (TxBodyRaw (ShelleyEra crypto)))
  instance
    ( Typeable crypto,
      CC.Crypto crypto,
      FromCBOR (Core.PParamsDelta (ShelleyEra crypto)),
      ToCBOR (Core.PParamsDelta (ShelleyEra crypto))
    ) =>
    FromCBOR (Annotator (TxBody (ShelleyEra crypto)))

-- | Pattern for use by external users
pattern TxBody ::
  (ToCBOR (Core.PParamsDelta (ShelleyEra crypto)), CC.Crypto crypto) =>
  Set (Core.TxIn (Crypto (ShelleyEra crypto))) ->
  StrictSeq (TxOut (ShelleyEra crypto)) ->
  StrictSeq (DCert (Crypto (ShelleyEra crypto))) ->
  Wdrl (Crypto (ShelleyEra crypto)) ->
  Coin ->
  SlotNo ->
  StrictMaybe (Update (ShelleyEra crypto)) ->
  StrictMaybe (AuxiliaryDataHash (Crypto (ShelleyEra crypto))) ->
  TxBody (ShelleyEra crypto)
pattern TxBody {_inputs, _outputs, _certs, _wdrls, _txfee, _ttl, _txUpdate, _mdHash} <-
  TxBodyConstr
    ( Memo
        TxBodyRaw
          { _inputsX = _inputs,
            _outputsX = _outputs,
            _certsX = _certs,
            _wdrlsX = _wdrls,
            _txfeeX = _txfee,
            _ttlX = _ttl,
            _txUpdateX = _txUpdate,
            _mdHashX = _mdHash
          }
        _
      )
  where
    TxBody _inputs _outputs _certs _wdrls _txfee _ttl _txUpdate _mdHash =
      TxBodyConstr $ memoBytes (txSparse (TxBodyRaw _inputs _outputs _certs _wdrls _txfee _ttl _txUpdate _mdHash))

{-# COMPLETE TxBody #-}

-- =========================================

instance HashAnnotated (TxBody (ShelleyEra crypto)) EraIndependentTxBody crypto

instance CC.Crypto crypto => ToCBOR (TxBody (ShelleyEra crypto)) where
  toCBOR (TxBodyConstr memo) = toCBOR memo

-- ===============================================================

instance CC.Crypto crypto => ToCBOR (TxOut (ShelleyEra crypto)) where
  toCBOR (TxOutCompact addr coin) =
    encodeListLen 2
      <> toCBOR addr
      <> toCBOR coin

instance CC.Crypto crypto => FromCBOR (TxOut (ShelleyEra crypto)) where
  fromCBOR = fromNotSharedCBOR

-- This instance does not do any sharing and is isomorphic to FromCBOR
-- use the weakest constraint necessary
instance (Core.EraTxOut era, DecodeNonNegative (Core.Value era)) => FromSharedCBOR (TxOut era) where
  type Share (TxOut era) = Interns (Credential 'Staking (Crypto era))
  fromSharedCBOR _ =
    decodeRecordNamed "TxOut" (const 2) $ do
      cAddr <- fromCBOR
      coin <- decodeNonNegative
      pure $ TxOutCompact cAddr coin

witKeyHash :: WitVKey kr crypto -> KeyHash 'Witness crypto
witKeyHash = witVKeyHash
{-# DEPRECATED witKeyHash "In favor of `witVKeyHash`" #-}

wvkBytes :: WitVKey kr crypto -> BSL.ByteString
wvkBytes = witVKeyBytes
{-# DEPRECATED wvkBytes "In favor of `witVKeyBytes`" #-}
