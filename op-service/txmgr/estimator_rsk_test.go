package txmgr_test

// RSK fork coverage for op-service/txmgr/estimator.go.
//
// Upstream's DefaultGasPriceEstimatorFn only ever exercises the EIP-1559 path
// (baseFee from the block header + tip). The RSK fork adds a pre-EIP-1559
// fallback to eth_gasPrice for chains that report a nil header BaseFee (RSK),
// plus an explicit "neither available" error. Those branches have no upstream
// coverage, so they live here. See AGENTS_rsk.md for the _rsk_test.go / TestRSK_
// convention.

import (
	"context"
	"errors"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-service/txmgr"
)

// rskEstimatorBackend is a minimal txmgr.ETHBackend used to drive
// DefaultGasPriceEstimatorFn. It deliberately does NOT implement the
// (unexported) gasPriceSuggester interface, so a *rskEstimatorBackend exercises
// the "neither EIP-1559 nor eth_gasPrice" branch. Embed it in
// rskLegacyBackend to add the SuggestGasPrice method and reach the RSK
// pre-EIP-1559 fallback.
type rskEstimatorBackend struct {
	baseFee     *big.Int // BaseFee reported by HeaderByNumber; nil => pre-EIP-1559 chain.
	blobBaseFee *big.Int // value returned by BlobBaseFee.
	tip         *big.Int // value returned by SuggestGasTipCap.
	tipErr      error    // error returned by SuggestGasTipCap.
	headerErr   error    // error returned by HeaderByNumber.
}

func (b *rskEstimatorBackend) HeaderByNumber(_ context.Context, _ *big.Int) (*types.Header, error) {
	if b.headerErr != nil {
		return nil, b.headerErr
	}
	return &types.Header{Number: big.NewInt(1), BaseFee: b.baseFee}, nil
}

func (b *rskEstimatorBackend) SuggestGasTipCap(_ context.Context) (*big.Int, error) {
	return b.tip, b.tipErr
}

func (b *rskEstimatorBackend) BlobBaseFee(_ context.Context) (*big.Int, error) {
	return b.blobBaseFee, nil
}

// Remaining ETHBackend methods are unused by DefaultGasPriceEstimatorFn; they
// exist only to satisfy the interface.
func (b *rskEstimatorBackend) BlockNumber(_ context.Context) (uint64, error) {
	return 0, errors.New("rsk: unimplemented")
}

func (b *rskEstimatorBackend) CallContract(_ context.Context, _ ethereum.CallMsg, _ *big.Int) ([]byte, error) {
	return nil, errors.New("rsk: unimplemented")
}

func (b *rskEstimatorBackend) TransactionReceipt(_ context.Context, _ common.Hash) (*types.Receipt, error) {
	return nil, errors.New("rsk: unimplemented")
}

func (b *rskEstimatorBackend) SendTransaction(_ context.Context, _ *types.Transaction) error {
	return errors.New("rsk: unimplemented")
}

func (b *rskEstimatorBackend) NonceAt(_ context.Context, _ common.Address, _ *big.Int) (uint64, error) {
	return 0, errors.New("rsk: unimplemented")
}

func (b *rskEstimatorBackend) PendingNonceAt(_ context.Context, _ common.Address) (uint64, error) {
	return 0, errors.New("rsk: unimplemented")
}

func (b *rskEstimatorBackend) EstimateGas(_ context.Context, _ ethereum.CallMsg) (uint64, error) {
	return 0, errors.New("rsk: unimplemented")
}

func (b *rskEstimatorBackend) Close() {}

// rskLegacyBackend augments rskEstimatorBackend with SuggestGasPrice, so it
// satisfies txmgr's unexported gasPriceSuggester interface and reaches the
// eth_gasPrice fallback (as go-ethereum's ethclient.Client does for RSK).
type rskLegacyBackend struct {
	rskEstimatorBackend
	gasPrice    *big.Int
	gasPriceErr error
}

func (b *rskLegacyBackend) SuggestGasPrice(_ context.Context) (*big.Int, error) {
	return b.gasPrice, b.gasPriceErr
}

// TestRSK_DefaultGasPriceEstimator_EIP1559Path is the control: when the header
// carries a BaseFee and the tip is available, the estimator uses the EIP-1559
// values verbatim and never consults the eth_gasPrice fallback.
func TestRSK_DefaultGasPriceEstimator_EIP1559Path(t *testing.T) {
	t.Parallel()

	tip := big.NewInt(2)
	baseFee := big.NewInt(100)
	blobBaseFee := big.NewInt(7)
	backend := &rskEstimatorBackend{baseFee: baseFee, tip: tip, blobBaseFee: blobBaseFee}

	gotTip, gotBaseFee, gotBlob, err := txmgr.DefaultGasPriceEstimatorFn(context.Background(), backend)
	require.NoError(t, err)
	require.Equal(t, tip, gotTip)
	require.Equal(t, baseFee, gotBaseFee)
	require.Equal(t, blobBaseFee, gotBlob)
}

// TestRSK_DefaultGasPriceEstimator_PreEIP1559Fallback covers the core RSK
// change: a nil header BaseFee makes the estimator fall back to eth_gasPrice,
// returning tip=0 and baseFee=gasPrice. calcGasFeeCap (gasTipCap + 2*baseFee)
// then yields a 2x buffer of 2*gasPrice, matching the EIP-1559 baseFee margin.
func TestRSK_DefaultGasPriceEstimator_PreEIP1559Fallback(t *testing.T) {
	t.Parallel()

	gasPrice := big.NewInt(1_000)
	// Realistic RSK backend: pre-EIP-1559, so SuggestGasTipCap is unsupported and
	// the header carries no BaseFee — but eth_gasPrice works. The fallback must
	// still succeed and force tip=0 even though the tip lookup itself failed.
	backend := &rskLegacyBackend{
		rskEstimatorBackend: rskEstimatorBackend{
			baseFee: nil,
			tipErr:  errors.New("rsk: eth_maxPriorityFeePerGas unsupported"),
		},
		gasPrice: gasPrice,
	}

	gotTip, gotBaseFee, gotBlob, err := txmgr.DefaultGasPriceEstimatorFn(context.Background(), backend)
	require.NoError(t, err)

	// tip is forced to 0 so the whole fee comes from the gasPrice-derived cap.
	require.NotNil(t, gotTip)
	require.Zero(t, gotTip.Sign(), "fallback must return a zero tip")
	// baseFee is the eth_gasPrice value.
	require.Equal(t, gasPrice, gotBaseFee)
	// blobBaseFee is nil: pre-EIP-1559 chains have no eth_blobBaseFee.
	require.Nil(t, gotBlob)

	// Document the resulting 2x buffer: gasFeeCap = tip + 2*baseFee = 2*gasPrice.
	wantFeeCap := new(big.Int).Mul(gasPrice, big.NewInt(2))
	gotFeeCap := new(big.Int).Add(gotTip, new(big.Int).Mul(gotBaseFee, big.NewInt(2)))
	require.Equal(t, wantFeeCap, gotFeeCap)
}

// TestRSK_DefaultGasPriceEstimator_SuggestGasPriceError verifies that an
// eth_gasPrice RPC failure on the fallback path is surfaced to the caller.
func TestRSK_DefaultGasPriceEstimator_SuggestGasPriceError(t *testing.T) {
	t.Parallel()

	wantErr := errors.New("rsk: eth_gasPrice boom")
	backend := &rskLegacyBackend{
		rskEstimatorBackend: rskEstimatorBackend{baseFee: nil, tip: big.NewInt(9)},
		gasPriceErr:         wantErr,
	}

	tip, baseFee, blob, err := txmgr.DefaultGasPriceEstimatorFn(context.Background(), backend)
	require.ErrorIs(t, err, wantErr)
	require.Nil(t, tip)
	require.Nil(t, baseFee)
	require.Nil(t, blob)
}

// TestRSK_DefaultGasPriceEstimator_NeitherAvailable covers the RSK "neither
// EIP-1559 baseFee nor eth_gasPrice" error: a nil header BaseFee on a backend
// that does not implement SuggestGasPrice yields an explicit error rather than
// a panic or a silently wrong estimate.
func TestRSK_DefaultGasPriceEstimator_NeitherAvailable(t *testing.T) {
	t.Parallel()

	// tip succeeds (tipErr == nil) so the error is the explicit "neither
	// available" one, not a propagated tip error.
	backend := &rskEstimatorBackend{baseFee: nil, tip: big.NewInt(3)}

	tip, baseFee, blob, err := txmgr.DefaultGasPriceEstimatorFn(context.Background(), backend)
	require.Error(t, err)
	require.Contains(t, err.Error(), "cannot estimate gas")
	require.Nil(t, tip)
	require.Nil(t, baseFee)
	require.Nil(t, blob)
}

// TestRSK_DefaultGasPriceEstimator_NeitherAvailable_TipError verifies that when
// the tip lookup failed and the backend exposes no eth_gasPrice fallback, the
// tip error is surfaced in preference to the generic "neither available"
// message. The fallback is skipped here because rskEstimatorBackend doesn't
// implement gasPriceSuggester — not because the tip failed.
func TestRSK_DefaultGasPriceEstimator_NeitherAvailable_TipError(t *testing.T) {
	t.Parallel()

	wantErr := errors.New("rsk: eth_maxPriorityFeePerGas unsupported")
	backend := &rskEstimatorBackend{baseFee: nil, tipErr: wantErr}

	tip, baseFee, blob, err := txmgr.DefaultGasPriceEstimatorFn(context.Background(), backend)
	require.ErrorIs(t, err, wantErr)
	require.Nil(t, tip)
	require.Nil(t, baseFee)
	require.Nil(t, blob)
}
