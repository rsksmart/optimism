package contracts_test

// RSK fork coverage for op-proposer/contracts/disputegamefactory.go
// HasProposedSince.
//
// Upstream aborts the whole proposer scan if any dispute game fails to load.
// The fork skips a game whose metadata getters revert (an old game with an
// incompatible implementation / missing ABI methods) instead of blocking new
// proposals. Every other error is still returned — transport, context, a
// non-revert JSON-RPC error, or the empty result of a backend that hasn't seen
// the game yet — so a flaky or lagging RPC can't hide the proposer's own recent
// game and make it propose again before ProposalInterval. The factory's own
// gameAtIndex read is a plain storage read, so it keeps upstream's rule: any
// error is returned. These branches have no upstream coverage.
//
// The stock AbiBasedRpc stub can only inject errors into zero-output methods,
// so we wrap it (rskFailGameRPC) to fail every call to one game's address.
// External test package with rsk-prefixed helpers; method names mirror the
// Solidity ABI (see AGENTS_rsk.md).

import (
	"context"
	"errors"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/rpc"
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
	rskMethodGameCreator = "gameCreator"
	rskMethodRootClaim   = "rootClaim"
	rskMethodClaimData   = "claimData"
	rskMethodGames       = "games"
)

var (
	rskFactoryAddr  = common.Address{0xff, 0xff}
	rskProposerAddr = common.Address{0xaa, 0xbb}
)

// rskFailGameRPC wraps an AbiBasedRpc and, when game is set, fails every
// eth_call to that address: with errs[selector] when the call's 4-byte
// selector has an entry, else with err. Every other call goes to the stub.
type rskFailGameRPC struct {
	*batchingTest.AbiBasedRpc
	game *common.Address
	err  error
	errs map[[4]byte]error
}

// failingCallErr returns the error to inject for this call, or nil to let the
// stub answer it.
func (r *rskFailGameRPC) failingCallErr(method string, args []interface{}) error {
	if r.game == nil || method != "eth_call" || len(args) < 1 {
		return nil
	}
	opts, ok := args[0].(map[string]any)
	if !ok {
		return nil
	}
	if to, ok := opts["to"].(*common.Address); !ok || to == nil || *to != *r.game {
		return nil
	}
	if input, _ := opts["input"].(hexutil.Bytes); len(input) >= 4 {
		if err, ok := r.errs[[4]byte(input[:4])]; ok {
			return err
		}
	}
	return r.err
}

func (r *rskFailGameRPC) CallContext(ctx context.Context, out interface{}, method string, args ...interface{}) error {
	if err := r.failingCallErr(method, args); err != nil {
		return err
	}
	return r.AbiBasedRpc.CallContext(ctx, out, method, args...)
}

// BatchCallContext answers like a geth client: each call's error goes in its
// own element and the batch itself succeeds, so batching takes the same
// per-element path as in production.
func (r *rskFailGameRPC) BatchCallContext(ctx context.Context, b []rpc.BatchElem) error {
	for i := range b {
		b[i].Error = r.CallContext(ctx, b[i].Result, b[i].Method, b[i].Args...)
	}
	return nil
}

// rskSetupFactory builds a DisputeGameFactory over the failure wrapper. Returns
// the underlying stub so callers can stub the calls that succeed.
func rskSetupFactory(t *testing.T) (*batchingTest.AbiBasedRpc, *rskFailGameRPC, *contracts.DisputeGameFactory) {
	stubRpc := batchingTest.NewAbiBasedRpc(t, rskFactoryAddr, snapshots.LoadDisputeGameFactoryABI())
	wrapper := &rskFailGameRPC{AbiBasedRpc: stubRpc}
	caller := batching.NewMultiCaller(wrapper, batching.DefaultBatchSize)
	return stubRpc, wrapper, contracts.NewDisputeGameFactory(rskFactoryAddr, caller, time.Minute)
}

// rskGameAddr is the address rskStubValidGame / rskStubGameAtIndex use for idx.
func rskGameAddr(idx int64) common.Address {
	return common.Address{byte(0x10 + idx)}
}

// rskStubGameAtIndex stubs only the factory's gameAtIndex(idx) entry.
func rskStubGameAtIndex(stubRpc *batchingTest.AbiBasedRpc, idx int64, gameType uint32, ts time.Time) common.Address {
	gameAddr := rskGameAddr(idx)
	stubRpc.SetResponse(rskFactoryAddr, rskMethodGameAtIndex, rpcblock.Latest,
		[]interface{}{big.NewInt(idx)},
		[]interface{}{gameType, uint64(ts.Unix()), gameAddr})
	stubRpc.AddContract(gameAddr, snapshots.LoadFaultDisputeGameABI())
	return gameAddr
}

// rskStubValidGame stubs gameAtIndex(idx) and the game's gameCreator() and
// rootClaim() getters so the game loads as a proposal by rskProposerAddr at ts.
func rskStubValidGame(stubRpc *batchingTest.AbiBasedRpc, idx int64, gameType uint32, ts time.Time) common.Hash {
	gameAddr := rskStubGameAtIndex(stubRpc, idx, gameType, ts)
	claimHash := common.Hash{0xdd}
	stubRpc.SetResponse(gameAddr, rskMethodGameCreator, rpcblock.Latest, nil, []interface{}{rskProposerAddr})
	stubRpc.SetResponse(gameAddr, rskMethodRootClaim, rpcblock.Latest, nil, []interface{}{claimHash})
	return claimHash
}

// rskRPCDataError mimics geth's rpc.jsonError, which implements ErrorData() for
// every JSON-RPC error, not only reverts.
type rskRPCDataError struct {
	code int
	msg  string
}

func (e *rskRPCDataError) Error() string          { return e.msg }
func (e *rskRPCDataError) ErrorCode() int         { return e.code }
func (e *rskRPCDataError) ErrorData() interface{} { return nil }

// TestRSK_HasProposedSince_SkipsGameWhoseGettersRevert: the newest game has the
// wanted type, but every getter on it reverts (gameCreator/rootClaim and the
// legacy claimData(0) fallback), with geth's or RSKj's revert message. The scan
// must skip it and still find the older proposal; upstream returns an error
// here and blocks the proposer.
func TestRSK_HasProposedSince_SkipsGameWhoseGettersRevert(t *testing.T) {
	cutoff := time.Unix(1000, 0)
	for name, revert := range map[string]error{
		"geth": errors.New("execution reverted"),
		"RSKj": errors.New("VM Exception while processing transaction: transaction reverted"),
	} {
		t.Run(name, func(t *testing.T) {
			stubRpc, wrapper, factory := rskSetupFactory(t)
			stubRpc.SetResponse(rskFactoryAddr, rskMethodGameCount, rpcblock.Latest, nil,
				[]interface{}{big.NewInt(2)})
			badGame := rskStubGameAtIndex(stubRpc, 1, 0, cutoff.Add(20*time.Second))
			wrapper.game, wrapper.err = &badGame, revert
			wantClaim := rskStubValidGame(stubRpc, 0, 0, cutoff.Add(10*time.Second))

			proposed, ts, claim, err := factory.HasProposedSince(context.Background(), rskProposerAddr, cutoff, 0)
			require.NoError(t, err, "a game whose getters revert must be skipped, not fatal")
			require.True(t, proposed)
			require.Equal(t, cutoff.Add(10*time.Second), ts)
			require.Equal(t, wantClaim, claim)
		})
	}
}

// TestRSK_HasProposedSince_OnlyGameReverts_ReturnsNoProposal: the only game
// (idx 0) has getters that revert — the fork returns "no proposal found" (nil
// error) so the proposer isn't blocked, where upstream would return an error.
func TestRSK_HasProposedSince_OnlyGameReverts_ReturnsNoProposal(t *testing.T) {
	cutoff := time.Unix(1000, 0)
	stubRpc, wrapper, factory := rskSetupFactory(t)
	stubRpc.SetResponse(rskFactoryAddr, rskMethodGameCount, rpcblock.Latest, nil,
		[]interface{}{big.NewInt(1)})
	game := rskStubGameAtIndex(stubRpc, 0, 0, cutoff.Add(10*time.Second))
	wrapper.game, wrapper.err = &game, errors.New("execution reverted")

	proposed, ts, claim, err := factory.HasProposedSince(context.Background(), rskProposerAddr, cutoff, 0)
	require.NoError(t, err)
	require.False(t, proposed)
	require.Equal(t, time.Time{}, ts)
	require.Equal(t, common.Hash{}, claim)
}

// TestRSK_HasProposedSince_ReturnsNonRevertErrors: the newest game is this
// proposer's own, and reading it fails in a way that may clear on the next
// poll. Skipping it would reach the older game before the cutoff and report
// "no recent proposal", so the proposer would post a new game every tick; the
// error must be returned instead, as upstream does.
func TestRSK_HasProposedSince_ReturnsNonRevertErrors(t *testing.T) {
	cutoff := time.Unix(1000, 0)
	transportErr := &rpc.HTTPError{StatusCode: 503, Status: "503 Service Unavailable"}
	claimDataSelector := [4]byte(snapshots.LoadFaultDisputeGameABI().Methods[rskMethodClaimData].ID)

	tests := []struct {
		name string
		// breakGame makes reads of the game at gameAddr fail and returns the
		// error HasProposedSince must wrap, or nil if any error will do.
		breakGame func(stubRpc *batchingTest.AbiBasedRpc, wrapper *rskFailGameRPC, gameAddr common.Address) error
	}{
		{
			name: "transport error",
			breakGame: func(_ *batchingTest.AbiBasedRpc, wrapper *rskFailGameRPC, gameAddr common.Address) error {
				wrapper.game, wrapper.err = &gameAddr, transportErr
				return transportErr
			},
		},
		{
			name: "context canceled",
			breakGame: func(_ *batchingTest.AbiBasedRpc, wrapper *rskFailGameRPC, gameAddr common.Address) error {
				wrapper.game, wrapper.err = &gameAddr, context.Canceled
				return context.Canceled
			},
		},
		{
			// geth's JSON-RPC errors all carry ErrorData(), so it can't tell a
			// revert from a rate limit.
			name: "non-revert JSON-RPC error",
			breakGame: func(_ *batchingTest.AbiBasedRpc, wrapper *rskFailGameRPC, gameAddr common.Address) error {
				rateLimit := &rskRPCDataError{code: -32005, msg: "limit exceeded"}
				wrapper.game, wrapper.err = &gameAddr, rateLimit
				return rateLimit
			},
		},
		{
			name: "getters revert but the claimData(0) fallback fails",
			breakGame: func(_ *batchingTest.AbiBasedRpc, wrapper *rskFailGameRPC, gameAddr common.Address) error {
				wrapper.game, wrapper.err = &gameAddr, errors.New("execution reverted")
				wrapper.errs = map[[4]byte]error{claimDataSelector: transportErr}
				return transportErr
			},
		},
		{
			// A backend that hasn't seen the game yet answers eth_call to its
			// address with empty data, which fails to decode.
			name: "game not visible yet",
			breakGame: func(stubRpc *batchingTest.AbiBasedRpc, _ *rskFailGameRPC, gameAddr common.Address) error {
				emptyABI := snapshots.LoadFaultDisputeGameABI()
				for _, name := range []string{rskMethodGameCreator, rskMethodRootClaim, rskMethodClaimData} {
					m := emptyABI.Methods[name]
					m.Outputs = nil
					emptyABI.Methods[name] = m
				}
				stubRpc.AddContract(gameAddr, emptyABI)
				stubRpc.SetResponse(gameAddr, rskMethodGameCreator, rpcblock.Latest, nil, nil)
				stubRpc.SetResponse(gameAddr, rskMethodRootClaim, rpcblock.Latest, nil, nil)
				stubRpc.SetResponse(gameAddr, rskMethodClaimData, rpcblock.Latest, []interface{}{big.NewInt(0)}, nil)
				return nil
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stubRpc, wrapper, factory := rskSetupFactory(t)
			stubRpc.SetResponse(rskFactoryAddr, rskMethodGameCount, rpcblock.Latest, nil,
				[]interface{}{big.NewInt(2)})
			ownGame := rskStubGameAtIndex(stubRpc, 1, 0, cutoff.Add(20*time.Second))
			wantErr := tt.breakGame(stubRpc, wrapper, ownGame)
			rskStubValidGame(stubRpc, 0, 0, cutoff.Add(-10*time.Second))

			proposed, _, _, err := factory.HasProposedSince(context.Background(), rskProposerAddr, cutoff, 0)
			if wantErr != nil {
				require.ErrorIs(t, err, wantErr)
			} else {
				require.Error(t, err)
			}
			require.False(t, proposed)
		})
	}
}

// TestRSK_GameExists covers the fork-added GameExists lookup, which asks the
// factory the same question create() reverts GameAlreadyExists on: is the slot
// keyed by (gameType, rootClaim, extraData) already taken?
func TestRSK_GameExists(t *testing.T) {
	const gameType = uint32(1)
	rootClaim := common.Hash{0xaa}
	// The 32-byte big-endian sequence number, exactly as source.Proposal.ExtraData
	// builds it. Asserted here so a change to that encoding breaks this test
	// rather than silently probing the wrong factory slot.
	extraData := common.BigToHash(big.NewInt(42)).Bytes()

	tests := []struct {
		name  string
		proxy common.Address
		want  bool
	}{
		{name: "occupied slot", proxy: common.Address{0xce}, want: true},
		{name: "free slot", proxy: common.Address{}, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stubRpc, _, factory := rskSetupFactory(t)
			// SetResponse asserts the call's decoded arguments, so an incorrect
			// (gameType, rootClaim, extraData) key fails the test rather than
			// falling through to a canned answer.
			stubRpc.SetResponse(rskFactoryAddr, rskMethodGames, rpcblock.Latest,
				[]interface{}{gameType, rootClaim, extraData},
				[]interface{}{tt.proxy, uint64(1234)})

			exists, err := factory.GameExists(context.Background(), gameType, rootClaim, extraData)
			require.NoError(t, err)
			require.Equal(t, tt.want, exists)
		})
	}
}
