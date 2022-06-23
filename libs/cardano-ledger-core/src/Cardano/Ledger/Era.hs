-- | Support for multiple (Shelley-based) eras in the ledger.
module Cardano.Ledger.Era
  ( Era (..),
    getTxOutAddr,
    getTxOutCompactAddr,
    getTxOutEitherAddr,
    getTxOutBootstrapAddress,
    getAllTxInputs,
    PreviousEra,
    TranslationContext,
    TranslateEra (..),
    translateEra',
    translateEraMaybe,
    ValidateScript (..),
    -- $segWit
    SupportsSegWit (..),
  )
where

import Cardano.Ledger.Address (Addr (AddrBootstrap), BootstrapAddress)
import Cardano.Ledger.CompactAddress (CompactAddr, decompactAddr, isBootstrapCompactAddr)
import Cardano.Ledger.Core
import Cardano.Ledger.TxIn (TxIn)
import Data.Set (Set)
import Lens.Micro

-- | The validity of any individual block depends only on a subset
-- of the UTxO stored in the ledger state. The consensus layer makes
-- use of this fact, and uses the function below to to retrieve the
-- needed UTxO from disk and present only those to the ledger.
-- It is therefore neccessary that this function account for all the
-- different types of inputs inside a transaction.
getAllTxInputs :: EraTxBody era => TxBody era -> Set (TxIn (Crypto era))
getAllTxInputs txBody = txBody ^. txBodyAllInputsG

getTxOutEitherAddr ::
  EraTxOut era =>
  TxOut era ->
  Either (Addr (Crypto era)) (CompactAddr (Crypto era))
getTxOutEitherAddr txOut = txOut ^. txOutAddrEitherL

getTxOutAddr ::
  EraTxOut era =>
  TxOut era ->
  Addr (Crypto era)
getTxOutAddr txOut = txOut ^. txOutAddrL

getTxOutCompactAddr ::
  EraTxOut era =>
  TxOut era ->
  CompactAddr (Crypto era)
getTxOutCompactAddr txOut = txOut ^. txOutCompactAddrL

-- | Get the Bootsrap address from the TxOut. Returns `Nothing` if it is a
-- Shelley address or newer
getTxOutBootstrapAddress ::
  EraTxOut era =>
  TxOut era ->
  Maybe (BootstrapAddress (Crypto era))
getTxOutBootstrapAddress txOut =
  case getTxOutEitherAddr txOut of
    Left (AddrBootstrap bootstrapAddr) -> Just bootstrapAddr
    Right cAddr
      | isBootstrapCompactAddr cAddr -> do
          AddrBootstrap bootstrapAddr <- Just (decompactAddr cAddr)
          Just bootstrapAddr
    _ -> Nothing
