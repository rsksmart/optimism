package contracts_test

// RSK fork coverage for op-proposer/contracts/disputegamefactory.go
// HasProposedSince.
//
// Upstream aborts the whole proposer scan if any dispute game fails to load.
// The fork makes the scan resilient: a game that can't be loaded (e.g. an old
// game with an incompatible implementation / missing ABI methods) is skipped
// instead of blocking new proposals — while genuine context cancellation /
// deadline errors are still surfaced. These branches have no upstream coverage.
//
// The stock AbiBasedRpc stub can only inject errors into zero-output methods,
// so we wrap it (rskFailGameAtIndexRPC) to fail the multi-output gameAtIndex
// call for a chosen index. External test package with rsk-prefixed helpers;
// method names mirror the Solidity ABI (see AGENTS_rsk.md).

import (
	"bytes"
	"context"
	"errors"
	"math"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-proposer/contracts"
	"github.com/ethereum-optimism/optimism/op-service/sources/batching"
	"github.com/ethereum-optimism/optimism/op-service/sources/batching/rpcblock"
	batchingTest "github.com/ethereum-optimism/optimism/op-service/sources/batching/test"
	"github.com/ethereum-optimism/optimism/packages/contracts-bedrock/snapshots"
)

const (
	rskMethodGameCount   = "gameCount"
	rskMethodGameAtIndex = "gameAtIndex"
	rskMethodClaim       = "claimData"
)

var (
	rskFactoryAddr  = common.Address{0xff, 0xff}
	rskProposerAddr = common.Address{0xaa, 0xbb}
)

// rskFailGameAtIndexRPC wraps an AbiBasedRpc and makes gameAtIndex(failIdx)
// return failErr (as a real dispute game with an incompatible implementation
// would), while delegating every other call to the underlying stub. The factory
// loads each game as its own single-element batch, which the MultiCaller
// dispatches through CallContext (getSingle), so failing it there surfaces the
// error just as the stub's SetError would. (BatchCallContext is inherited from
// the embedded stub and unused on this path.)
type rskFailGameAtIndexRPC struct {
	*batchingTest.AbiBasedRpc
	selector []byte // gameAtIndex 4-byte method ID
	failIdx  int64
	failErr  error
}

func (r *rskFailGameAtIndexRPC) targetsFailingCall(method string, args []interface{}) bool {
	if method != "eth_call" || len(args) < 1 {
		return false
	}
	opts, ok := args[0].(map[string]any)
	if !ok {
		return false
	}
	input, ok := opts["input"].(hexutil.Bytes)
	if !ok || len(input) < 4+32 {
		return false
	}
	if !bytes.Equal(input[:4], r.selector) {
		return false
	}
	idx := new(big.Int).SetBytes(input[4 : 4+32])
	return idx.Int64() == r.failIdx
}

func (r *rskFailGameAtIndexRPC) CallContext(ctx context.Context, out interface{}, method string, args ...interface{}) error {
	if r.targetsFailingCall(method, args) {
		return r.failErr
	}
	return r.AbiBasedRpc.CallContext(ctx, out, method, args...)
}

// rskSetupFactory builds a DisputeGameFactory whose gameAtIndex(failIdx) fails
// with failErr. Returns the underlying stub so callers can stub the rest.
func rskSetupFactory(t *testing.T, failIdx int64, failErr error) (*batchingTest.AbiBasedRpc, *contracts.DisputeGameFactory) {
	fdgAbi := snapshots.LoadDisputeGameFactoryABI()
	stubRpc := batchingTest.NewAbiBasedRpc(t, rskFactoryAddr, fdgAbi)
	rpc := &rskFailGameAtIndexRPC{
		AbiBasedRpc: stubRpc,
		selector:    fdgAbi.Methods[rskMethodGameAtIndex].ID,
		failIdx:     failIdx,
		failErr:     failErr,
	}
	caller := batching.NewMultiCaller(rpc, batching.DefaultBatchSize)
	factory := contracts.NewDisputeGameFactory(rskFactoryAddr, caller, time.Minute)
	return stubRpc, factory
}

// rskStubValidGame stubs gameAtIndex(idx) and the game's claimData so the game
// loads as a proposal by rskProposerAddr at ts.
func rskStubValidGame(stubRpc *batchingTest.AbiBasedRpc, idx int64, gameType uint32, ts time.Time) common.Hash {
	gameAddr := common.Address{byte(0x10 + idx)}
	claimHash := common.Hash{0xdd}
	stubRpc.SetResponse(rskFactoryAddr, rskMethodGameAtIndex, rpcblock.Latest,
		[]interface{}{big.NewInt(idx)},
		[]interface{}{gameType, uint64(ts.Unix()), gameAddr})
	stubRpc.AddContract(gameAddr, snapshots.LoadFaultDisputeGameABI())
	stubRpc.SetResponse(gameAddr, rskMethodClaim, rpcblock.Latest,
		[]interface{}{big.NewInt(0)},
		[]interface{}{
			uint32(math.MaxUint32), // parent (none => root)
			common.Address{},       // countered by
			rskProposerAddr,        // claimant == proposer
			big.NewInt(1000),       // bond
			claimHash,              // claim
			big.NewInt(1),          // position
			big.NewInt(100),        // clock
		})
	return claimHash
}

// TestRSK_HasProposedSince_SkipsIncompatibleGame: the newest game fails to load
// (incompatible ABI) but an older, valid, matching game exists — the scan must
// skip the bad one and still find the proposal instead of erroring.
func TestRSK_HasProposedSince_SkipsIncompatibleGame(t *testing.T) {
	cutoff := time.Unix(1000, 0)
	stubRpc, factory := rskSetupFactory(t, 1, errors.New("execution reverted: no such method"))

	stubRpc.SetResponse(rskFactoryAddr, rskMethodGameCount, rpcblock.Latest, nil,
		[]interface{}{big.NewInt(2)})
	// idx 1 (newest) fails via the wrapper; idx 0 is a valid, matching proposal.
	wantClaim := rskStubValidGame(stubRpc, 0, 0, cutoff.Add(10*time.Second))

	proposed, ts, claim, err := factory.HasProposedSince(context.Background(), rskProposerAddr, cutoff, 0)
	require.NoError(t, err, "an unloadable game must be skipped, not fatal")
	require.True(t, proposed)
	require.Equal(t, cutoff.Add(10*time.Second), ts)
	require.Equal(t, wantClaim, claim)
}

// TestRSK_HasProposedSince_AllGamesIncompatible_ReturnsNoProposal: the only
// game (idx 0) fails to load — the fork returns "no proposal found" (nil error)
// so the proposer isn't blocked, where upstream would return an error.
func TestRSK_HasProposedSince_AllGamesIncompatible_ReturnsNoProposal(t *testing.T) {
	cutoff := time.Unix(1000, 0)
	stubRpc, factory := rskSetupFactory(t, 0, errors.New("execution reverted"))

	stubRpc.SetResponse(rskFactoryAddr, rskMethodGameCount, rpcblock.Latest, nil,
		[]interface{}{big.NewInt(1)})

	proposed, ts, claim, err := factory.HasProposedSince(context.Background(), rskProposerAddr, cutoff, 0)
	require.NoError(t, err)
	require.False(t, proposed)
	require.Equal(t, time.Time{}, ts)
	require.Equal(t, common.Hash{}, claim)
}

// TestRSK_HasProposedSince_SurfacesContextError: a context cancellation while
// loading a game must be surfaced, not masked as "no proposal found".
func TestRSK_HasProposedSince_SurfacesContextError(t *testing.T) {
	cutoff := time.Unix(1000, 0)
	stubRpc, factory := rskSetupFactory(t, 0, context.Canceled)

	stubRpc.SetResponse(rskFactoryAddr, rskMethodGameCount, rpcblock.Latest, nil,
		[]interface{}{big.NewInt(1)})

	proposed, _, _, err := factory.HasProposedSince(context.Background(), rskProposerAddr, cutoff, 0)
	require.ErrorIs(t, err, context.Canceled)
	require.False(t, proposed)
}
