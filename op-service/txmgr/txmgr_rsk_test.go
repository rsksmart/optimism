package txmgr

// RSK fork coverage for the txmgr Config knobs the fork adds for non-EIP-1559
// L1s (cli.go: UseLegacyTx, GasPriceEstimatorFn; consumed in txmgr.go craftTx /
// SuggestGasPriceCaps).
//
// This file uses the internal testHarness, mockBackend and craftTx, so it lives
// in the internal `txmgr` test package (see AGENTS_rsk.md — internal package
// only when unexported access is required). It reuses the shared harness but
// keeps its own TestRSK_ functions in a file upstream does not have; it adds no
// second TestMain.

import (
	"context"
	"errors"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/core/types"
	"github.com/stretchr/testify/require"
)

// TestRSK_CraftTx_UseLegacyTxProducesLegacyType asserts the fork's UseLegacyTx
// knob makes craftTx emit a legacy (type-0) transaction, as required by L1s
// (RSK) that reject EIP-1559 (type-2) txs. The gas price is set from the
// computed gasFeeCap.
func TestRSK_CraftTx_UseLegacyTxProducesLegacyType(t *testing.T) {
	cfg := configWithNumConfs(1)
	cfg.UseLegacyTx = true
	h := newTestHarnessWithConfig(t, cfg)

	tx, err := h.mgr.craftTx(context.Background(), h.createTxCandidate())
	require.NoError(t, err)
	require.Equal(t, uint8(types.LegacyTxType), tx.Type())
	require.Positive(t, tx.GasPrice().Sign(), "legacy tx must carry a positive gas price")
	// A legacy tx has no distinct tip; go-ethereum reports GasTipCap == GasPrice.
	require.Equal(t, tx.GasPrice(), tx.GasFeeCap())
}

// TestRSK_CraftTx_DefaultProducesDynamicType is the control: with UseLegacyTx
// unset, craftTx keeps upstream's EIP-1559 (type-2) behavior.
func TestRSK_CraftTx_DefaultProducesDynamicType(t *testing.T) {
	h := newTestHarness(t) // UseLegacyTx defaults to false

	tx, err := h.mgr.craftTx(context.Background(), h.createTxCandidate())
	require.NoError(t, err)
	require.Equal(t, uint8(types.DynamicFeeTxType), tx.Type())
}

// TestRSK_CraftTx_GasPriceEstimatorFn covers the fork's pluggable
// GasPriceEstimatorFn: NewSimpleTxManagerFromConfig installs it, and
// SuggestGasPriceCaps calls it during craftTx.
func TestRSK_CraftTx_GasPriceEstimatorFn(t *testing.T) {
	t.Run("custom estimator values flow into the tx", func(t *testing.T) {
		const tip, base = 11, 22
		called := false
		cfg := configWithNumConfs(1)
		cfg.UseLegacyTx = true // legacy => GasPrice == gasFeeCap, easy to assert
		cfg.GasPriceEstimatorFn = func(_ context.Context, _ ETHBackend) (*big.Int, *big.Int, *big.Int, error) {
			called = true
			return big.NewInt(tip), big.NewInt(base), nil, nil
		}
		h := newTestHarnessWithConfig(t, cfg)

		tx, err := h.mgr.craftTx(context.Background(), h.createTxCandidate())
		require.NoError(t, err)
		require.True(t, called, "the configured GasPriceEstimatorFn must be used")
		// gasFeeCap = tip + 2*baseFee (calcGasFeeCap).
		require.Equal(t, calcGasFeeCap(big.NewInt(base), big.NewInt(tip)), tx.GasPrice())
	})

	t.Run("custom estimator error aborts craftTx", func(t *testing.T) {
		wantErr := errors.New("rsk: gas estimation unavailable")
		cfg := configWithNumConfs(1)
		cfg.GasPriceEstimatorFn = func(_ context.Context, _ ETHBackend) (*big.Int, *big.Int, *big.Int, error) {
			return nil, nil, nil, wantErr
		}
		h := newTestHarnessWithConfig(t, cfg)

		_, err := h.mgr.craftTx(context.Background(), h.createTxCandidate())
		require.ErrorIs(t, err, wantErr)
	})
}
