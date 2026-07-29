package derive_test

// RSK fork coverage for op-node/rollup/derive/l1_block_info.go.
//
// L1InfoDeposit copies the L1 block's BaseFee into the L1-info deposit. On
// pre-EIP-1559 L1s (RSK) the header carries no base fee, so block.BaseFee()
// is nil. Upstream would marshal that nil straight into the deposit payload
// and panic; the RSK fork defaults a nil base fee to 0. This is the branch
// under test.
//
// See AGENTS_rsk.md for the _rsk_test.go / TestRSK_ convention.

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/params"
	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-node/rollup"
	"github.com/ethereum-optimism/optimism/op-node/rollup/derive"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/testutils"
)

// TestRSK_L1InfoDeposit_NilBaseFeeDefaultsToZero asserts that an L1 block with a
// nil BaseFee (pre-EIP-1559 / RSK) produces a valid L1-info deposit whose
// encoded BaseFee is 0, without panicking on the nil big.Int.
func TestRSK_L1InfoDeposit_NilBaseFeeDefaultsToZero(t *testing.T) {
	t.Parallel()

	// A pre-EIP-1559 L1 block: BaseFee() == nil.
	info := &testutils.MockBlockInfo{
		InfoHash:    common.HexToHash("0x5c0de"),
		InfoNum:     42,
		InfoTime:    1_700_000_000,
		InfoBaseFee: nil,
	}
	require.Nil(t, info.BaseFee(), "precondition: the L1 block reports a nil base fee")

	// Zero-value rollup config keeps us on the Bedrock encoding path.
	var rollupCfg rollup.Config
	l1Cfg := eth.SystemConfig{BatcherAddr: common.HexToAddress("0xba7c8e00000000000000000000000000000000fe")}

	// Must not panic on the nil base fee, and must produce a deposit tx.
	depTx, err := derive.L1InfoDeposit(&rollupCfg, params.MergedTestChainConfig, l1Cfg, 7, info, 0)
	require.NoError(t, err)
	require.NotNil(t, depTx)

	// Decode the deposit payload back and confirm BaseFee round-trips to 0.
	res, err := derive.L1BlockInfoFromBytes(&rollupCfg, info.Time(), depTx.Data)
	require.NoError(t, err)
	require.NotNil(t, res.BaseFee, "decoded base fee must be a non-nil zero, not nil")
	require.Zero(t, res.BaseFee.Sign(), "nil L1 base fee must default to 0")
	require.Zero(t, res.BaseFee.Cmp(big.NewInt(0)))

	// Sanity: the remaining L1-info fields still round-trip correctly.
	require.Equal(t, info.NumberU64(), res.Number)
	require.Equal(t, info.Time(), res.Time)
	require.Equal(t, info.Hash(), res.BlockHash)
	require.Equal(t, l1Cfg.BatcherAddr, res.BatcherAddr)
}
