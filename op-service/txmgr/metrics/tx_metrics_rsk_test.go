package metrics_test

// RSK fork coverage for op-service/txmgr/metrics/tx_metrics.go.
//
// The fork routes RecordBaseFee / RecordBlobBaseFee / RecordTipCap /
// RecordBlobTipCap through a nil-guarded helper. On pre-EIP-1559 L1s (RSK) the
// header BaseFee is nil, and on pre-EIP-4844 L1s the blob base fee is nil;
// upstream's `(*big.Int)(nil).Float64()` would panic. These nil calls have no
// upstream coverage.
//
// See AGENTS_rsk.md for the _rsk_test.go / TestRSK_ convention.

import (
	"math/big"
	"testing"

	"github.com/stretchr/testify/require"

	opmetrics "github.com/ethereum-optimism/optimism/op-service/metrics"
	txmetrics "github.com/ethereum-optimism/optimism/op-service/txmgr/metrics"
)

// TestRSK_TxMetrics_RecordNilFeesDoNotPanic asserts the four fee-recording
// metrics tolerate a nil *big.Int (RSK's missing base fee / blob base fee)
// instead of panicking.
func TestRSK_TxMetrics_RecordNilFeesDoNotPanic(t *testing.T) {
	m := txmetrics.MakeTxMetrics("rsktest", opmetrics.With(opmetrics.NewRegistry()))

	require.NotPanics(t, func() {
		m.RecordBaseFee(nil)
		m.RecordBlobBaseFee(nil)
		m.RecordTipCap(nil)
		m.RecordBlobTipCap(nil)
	})

	// Non-nil values must still work (control).
	require.NotPanics(t, func() {
		m.RecordBaseFee(big.NewInt(7))
		m.RecordBlobBaseFee(big.NewInt(11))
		m.RecordTipCap(big.NewInt(2))
		m.RecordBlobTipCap(big.NewInt(3))
	})
}
