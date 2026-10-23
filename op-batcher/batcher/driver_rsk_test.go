package batcher

// RSK fork coverage for op-batcher/batcher/driver.go sendTx.
//
// Upstream sizes every batcher tx with maxFloorDataGas, which reserves
// Amsterdam's calldata floor (15000 + 64 gas per byte). RSK never activates
// Amsterdam and RSKj regtest caps a tx at 6,800,001 gas, so a full frame would
// be refused. The fork adds DriverSetup.TxGasLimit: nil keeps upstream's
// formula, non-nil replaces it. Upstream never sets it, so the dispatch has no
// upstream coverage.
//
// sendTx is unexported, so this file lives in the internal `batcher` test
// package and reuses upstream's setup / MockTxQueue seams.

import (
	"errors"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-service/txmgr"
)

func TestRSK_BatchSubmitter_sendTx_TxGasLimitHook(t *testing.T) {
	// 106,016 bytes is the smallest frame whose Amsterdam floor exceeds RSKj
	// regtest's 6,800,001 per-tx gas cap.
	data := make([]byte, 106_016)

	// rskSendTx runs data through sendTx with the given hook and returns the gas
	// limit of the candidate handed to the tx queue.
	rskSendTx := func(t *testing.T, hook TxGasLimitFn) uint64 {
		bs, _ := setup(t, nil)
		bs.TxGasLimit = hook
		q := new(MockTxQueue)
		td := txData{frames: []frameData{{data: data}}}
		candidate := txmgr.TxCandidate{To: &bs.RollupConfig.BatchInboxAddress, TxData: data}
		bs.sendTx(td, false, &candidate, q, make(chan txmgr.TxReceipt[txRef]))
		return q.Load(td.ID().String()).GasLimit
	}

	t.Run("nil hook keeps upstream's maxFloorDataGas", func(t *testing.T) {
		require.Equal(t, uint64(15_000+64*106_016), rskSendTx(t, nil))
	})

	t.Run("non-nil hook replaces the formula", func(t *testing.T) {
		var got []byte
		gasLimit := rskSendTx(t, func(txData []byte) (uint64, error) {
			got = txData
			return 4_261_640, nil
		})
		require.Equal(t, uint64(4_261_640), gasLimit)
		require.Equal(t, data, got, "hook must receive the candidate's calldata")
	})

	t.Run("hook returning 0 leaves the limit to the txmgr estimate", func(t *testing.T) {
		require.Zero(t, rskSendTx(t, func([]byte) (uint64, error) { return 0, nil }))
	})

	t.Run("hook error leaves the limit unset, as upstream does", func(t *testing.T) {
		require.Zero(t, rskSendTx(t, func([]byte) (uint64, error) {
			return 0, errors.New("rsk: cannot size tx")
		}))
	})
}
