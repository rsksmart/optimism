package derive_test

// RSK fork coverage for the FetchReceipts-not-found handling that the fork adds
// to L1 traversal.
//
// Upstream's L1Traversal.AdvanceL1Block and L1TraversalManaged.ProvideNextL1
// only classify a failed sysCfg receipt fetch as a temporary error. The RSK
// fork adds a reorg-aware branch: when FetchReceipts reports the block is no
// longer found, the block may have been reorged out between the ref lookup and
// the receipt fetch (more likely on RSK's faster/re-orgier L1). The fork then
// distinguishes a genuine reorg (reset the pipeline) from a transient miss
// (retry). These branches have no upstream coverage.
//
// See AGENTS_rsk.md for the _rsk_test.go / TestRSK_ convention.

import (
	"context"
	"errors"
	"math/rand"
	"testing"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/log"
	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-node/rollup"
	"github.com/ethereum-optimism/optimism/op-node/rollup/derive"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/testlog"
	"github.com/ethereum-optimism/optimism/op-service/testutils"
)

// rskTraversalConfig builds a minimal rollup.Config for the traversal tests.
func rskTraversalConfig(rng *rand.Rand, sysCfg eth.SystemConfig) *rollup.Config {
	return &rollup.Config{
		Genesis:               rollup.Genesis{SystemConfig: sysCfg},
		L1SystemConfigAddress: testutils.RandomAddress(rng),
	}
}

// TestRSK_L1Traversal_FetchReceiptsNotFoundReorg covers the fork's reset path:
// FetchReceipts returns NotFound, and re-fetching the block by number yields a
// different hash — an L1 reorg — so AdvanceL1Block must return a reset error.
func TestRSK_L1Traversal_FetchReceiptsNotFoundReorg(t *testing.T) {
	rng := rand.New(rand.NewSource(1234))
	sysCfg := eth.SystemConfig{BatcherAddr: testutils.RandomAddress(rng)}

	origin := testutils.RandomBlockRef(rng)
	next := testutils.NextRandomRef(rng, origin) // extends origin (ParentHash == origin.Hash)
	// The block re-fetched by number after the NotFound has a different hash:
	// the canonical chain reorged to a competing block at the same height.
	reorged := testutils.RandomBlockRef(rng)
	reorged.Number = next.Number
	require.NotEqual(t, next.Hash, reorged.Hash)

	src := &testutils.MockL1Source{}
	src.ExpectL1BlockRefByNumber(origin.Number+1, next, nil)
	src.ExpectFetchReceipts(next.Hash, nil, nil, ethereum.NotFound)
	// The refetch-by-number (same number) returns the competing block.
	src.ExpectL1BlockRefByNumber(next.Number, reorged, nil)

	tr := derive.NewL1Traversal(testlog.Logger(t, log.LevelError), rskTraversalConfig(rng, sysCfg), src)
	_ = tr.Reset(context.Background(), origin, sysCfg)

	err := tr.AdvanceL1Block(context.Background())
	require.ErrorIs(t, err, derive.ErrReset)
	src.AssertExpectations(t)
}

// TestRSK_L1Traversal_FetchReceiptsNotFoundSameHash covers the fork's retry
// path: FetchReceipts returns NotFound but the block re-fetched by number has
// the same hash (no reorg — a transient RPC miss), so AdvanceL1Block must
// return a temporary error and not a reset.
func TestRSK_L1Traversal_FetchReceiptsNotFoundSameHash(t *testing.T) {
	rng := rand.New(rand.NewSource(1234))
	sysCfg := eth.SystemConfig{BatcherAddr: testutils.RandomAddress(rng)}

	origin := testutils.RandomBlockRef(rng)
	next := testutils.NextRandomRef(rng, origin)

	src := &testutils.MockL1Source{}
	src.ExpectL1BlockRefByNumber(origin.Number+1, next, nil)
	src.ExpectFetchReceipts(next.Hash, nil, nil, ethereum.NotFound)
	// Refetch returns the same block (hash unchanged) => not a reorg.
	src.ExpectL1BlockRefByNumber(next.Number, next, nil)

	tr := derive.NewL1Traversal(testlog.Logger(t, log.LevelError), rskTraversalConfig(rng, sysCfg), src)
	_ = tr.Reset(context.Background(), origin, sysCfg)

	err := tr.AdvanceL1Block(context.Background())
	require.ErrorIs(t, err, derive.ErrTemporary)
	require.NotErrorIs(t, err, derive.ErrReset)
	src.AssertExpectations(t)
}

// TestRSK_L1Traversal_FetchReceiptsNotFoundRefetchError verifies that if the
// reorg-probe refetch itself errors, AdvanceL1Block conservatively returns a
// temporary error (safe to retry) rather than a reset.
func TestRSK_L1Traversal_FetchReceiptsNotFoundRefetchError(t *testing.T) {
	rng := rand.New(rand.NewSource(1234))
	sysCfg := eth.SystemConfig{BatcherAddr: testutils.RandomAddress(rng)}

	origin := testutils.RandomBlockRef(rng)
	next := testutils.NextRandomRef(rng, origin)

	src := &testutils.MockL1Source{}
	src.ExpectL1BlockRefByNumber(origin.Number+1, next, nil)
	src.ExpectFetchReceipts(next.Hash, nil, nil, ethereum.NotFound)
	// The refetch-by-number probe fails; we cannot confirm a reorg, so retry.
	src.ExpectL1BlockRefByNumber(next.Number, eth.L1BlockRef{}, errors.New("rsk: refetch connection reset"))

	tr := derive.NewL1Traversal(testlog.Logger(t, log.LevelError), rskTraversalConfig(rng, sysCfg), src)
	_ = tr.Reset(context.Background(), origin, sysCfg)

	err := tr.AdvanceL1Block(context.Background())
	require.ErrorIs(t, err, derive.ErrTemporary)
	require.NotErrorIs(t, err, derive.ErrReset)
	src.AssertExpectations(t)
}

// TestRSK_L1TraversalManaged_FetchReceiptsNotFound covers the managed traversal
// (Interop) fork branch: FetchReceipts returning NotFound is treated directly
// as a reorg, so ProvideNextL1 returns a reset error.
func TestRSK_L1TraversalManaged_FetchReceiptsNotFound(t *testing.T) {
	rng := rand.New(rand.NewSource(1234))
	sysCfg := eth.SystemConfig{BatcherAddr: testutils.RandomAddress(rng)}

	origin := testutils.RandomBlockRef(rng)
	next := testutils.NextRandomRef(rng, origin)

	src := &testutils.MockL1Source{}
	src.ExpectFetchReceipts(next.Hash, nil, nil, ethereum.NotFound)

	tr := derive.NewL1TraversalManaged(testlog.Logger(t, log.LevelError), rskTraversalConfig(rng, sysCfg), src)
	_ = tr.Reset(context.Background(), origin, sysCfg) // sets internal block=origin, done=true

	err := tr.ProvideNextL1(context.Background(), next)
	require.ErrorIs(t, err, derive.ErrReset)
	src.AssertExpectations(t)
}

// TestRSK_L1TraversalManaged_FetchReceiptsTemporary verifies that a non-NotFound
// receipt-fetch failure in the managed traversal remains a temporary error.
func TestRSK_L1TraversalManaged_FetchReceiptsTemporary(t *testing.T) {
	rng := rand.New(rand.NewSource(1234))
	sysCfg := eth.SystemConfig{BatcherAddr: testutils.RandomAddress(rng)}

	origin := testutils.RandomBlockRef(rng)
	next := testutils.NextRandomRef(rng, origin)

	src := &testutils.MockL1Source{}
	src.ExpectFetchReceipts(next.Hash, nil, nil, errors.New("rsk: interrupted connection"))

	tr := derive.NewL1TraversalManaged(testlog.Logger(t, log.LevelError), rskTraversalConfig(rng, sysCfg), src)
	_ = tr.Reset(context.Background(), origin, sysCfg)

	err := tr.ProvideNextL1(context.Background(), next)
	require.ErrorIs(t, err, derive.ErrTemporary)
	require.NotErrorIs(t, err, derive.ErrReset)
	src.AssertExpectations(t)
}
