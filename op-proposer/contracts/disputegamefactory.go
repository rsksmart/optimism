package contracts

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/ethereum-optimism/optimism/op-service/bigs"
	"github.com/ethereum-optimism/optimism/op-service/sources/batching"
	"github.com/ethereum-optimism/optimism/op-service/sources/batching/rpcblock"
	"github.com/ethereum-optimism/optimism/op-service/txmgr"
	"github.com/ethereum-optimism/optimism/packages/contracts-bedrock/snapshots"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

const (
	methodGameCount   = "gameCount"
	methodGameAtIndex = "gameAtIndex"
	methodInitBonds   = "initBonds"
	methodCreateGame  = "create"
	methodVersion     = "version"
	methodGames       = "games"

	methodGameCreator = "gameCreator"
	methodRootClaim   = "rootClaim"
	methodClaim       = "claimData"
)

type gameInfo struct {
	GameType  uint32
	Timestamp time.Time
	Address   common.Address
}

type proposalMetadata struct {
	Proposer common.Address
	Claim    common.Hash
}

type DisputeGameFactory struct {
	caller         *batching.MultiCaller
	contract       *batching.BoundContract
	gameABI        *abi.ABI
	networkTimeout time.Duration
}

func NewDisputeGameFactory(addr common.Address, caller *batching.MultiCaller, networkTimeout time.Duration) *DisputeGameFactory {
	factoryABI := snapshots.LoadDisputeGameFactoryABI()
	// Note: Games might have different ABIs (eg SuperFaultDisputeGame) but since only a very small part of the ABI
	// is actually needed, proposer always uses the latest FaultDisputeGameABI. Compatibility with other ABIs is tested
	// in disputegamefactory_test.go
	gameABI := snapshots.LoadFaultDisputeGameABI()
	return &DisputeGameFactory{
		caller:         caller,
		contract:       batching.NewBoundContract(factoryABI, addr),
		gameABI:        gameABI,
		networkTimeout: networkTimeout,
	}
}

func (f *DisputeGameFactory) Version(ctx context.Context) (string, error) {
	cCtx, cancel := context.WithTimeout(ctx, f.networkTimeout)
	defer cancel()
	result, err := f.caller.SingleCall(cCtx, rpcblock.Latest, f.contract.Call(methodVersion))
	if err != nil {
		return "", fmt.Errorf("failed to get version: %w", err)
	}
	return result.GetString(0), nil
}

// HasProposedSince attempts to find a game with the specified game type created by the specified proposer after the
// given cut off time. If one is found, returns true and the time the game was created at.
// If no matching proposal is found, returns false, time.Time{}, nil
func (f *DisputeGameFactory) HasProposedSince(ctx context.Context, proposer common.Address, cutoff time.Time, gameType uint32) (bool, time.Time, common.Hash, error) {
	gameCount, err := f.gameCount(ctx)
	if err != nil {
		return false, time.Time{}, common.Hash{}, fmt.Errorf("failed to get dispute game count: %w", err)
	}
	if gameCount == 0 {
		return false, time.Time{}, common.Hash{}, nil
	}
	for idx := gameCount - 1; ; idx-- {
		game, err := f.gameAtIndex(ctx, idx)
		if err != nil {
			return false, time.Time{}, common.Hash{}, fmt.Errorf("failed to get dispute game %d: %w", idx, err)
		}
		if game.Timestamp.Before(cutoff) {
			// Reached a game that is before the expected cutoff, so we haven't found a suitable proposal
			return false, time.Time{}, common.Hash{}, nil
		}
		if game.GameType == gameType {
			metadata, err := f.loadGameMetadata(ctx, game.Address)
			if err != nil {
				// Skip a game whose getters revert (an old implementation that lacks
				// them) so old games don't block the proposer. Any other error is
				// returned: a flaky or lagging RPC must not hide our own recent game,
				// or we would propose again before ProposalInterval.
				if !rskIsRevert(err) {
					return false, time.Time{}, common.Hash{}, fmt.Errorf("failed to get metadata for dispute game %d: %w", idx, err)
				}
				if idx == 0 {
					return false, time.Time{}, common.Hash{}, nil
				}
				continue
			}
			if metadata.Proposer == proposer {
				// Found a matching proposal
				return true, game.Timestamp, metadata.Claim, nil
			}
		}
		if idx == 0 { // Need to check here rather than in the for condition to avoid underflow
			// Checked every game and didn't find a match
			return false, time.Time{}, common.Hash{}, nil
		}
	}
}

// rskIsRevert reports whether err is a reverted call: geth's "execution
// reverted" or RSKj's "VM Exception while processing transaction". Transport,
// node and context errors are not, nor is an empty result that fails to decode,
// which is what a backend that hasn't seen the game yet returns. A joined error
// counts only if every part does, as loadGameMetadata joins the getters' error
// with the claimData(0) fallback's.
//
// It matches messages rather than geth's ErrorData(), which every JSON-RPC
// error implements (a rate limit too).
func rskIsRevert(err error) bool {
	switch e := err.(type) {
	case nil:
		return false
	case interface{ Unwrap() []error }:
		errs := e.Unwrap()
		for _, inner := range errs {
			if !rskIsRevert(inner) {
				return false
			}
		}
		return len(errs) > 0
	case interface{ Unwrap() error }:
		return rskIsRevert(e.Unwrap())
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "execution reverted") || strings.Contains(msg, "vm exception")
}

// GameExists reports whether a game already occupies the factory slot for this
// (gameType, rootClaim, extraData) triple.
//
// This is the exact predicate create() reverts on: the slot is keyed by
// keccak256(abi.encode(gameType, rootClaim, extraData)) and is never cleared, so
// a resolved game still blocks re-proposing the same output root at the same
// sequence number. It is also proposer-independent, so unlike HasProposedSince —
// which matches on the proposer address — it sees a slot taken by someone else.
func (f *DisputeGameFactory) GameExists(ctx context.Context, gameType uint32, rootClaim common.Hash, extraData []byte) (bool, error) {
	cCtx, cancel := context.WithTimeout(ctx, f.networkTimeout)
	defer cancel()
	result, err := f.caller.SingleCall(cCtx, rpcblock.Latest, f.contract.Call(methodGames, gameType, rootClaim, extraData))
	if err != nil {
		return false, fmt.Errorf("failed to look up existing game: %w", err)
	}
	return result.GetAddress(0) != (common.Address{}), nil
}

func (f *DisputeGameFactory) ProposalTx(ctx context.Context, gameType uint32, outputRoot common.Hash, extraData []byte) (txmgr.TxCandidate, error) {
	cCtx, cancel := context.WithTimeout(ctx, f.networkTimeout)
	defer cancel()
	result, err := f.caller.SingleCall(cCtx, rpcblock.Latest, f.contract.Call(methodInitBonds, gameType))
	if err != nil {
		return txmgr.TxCandidate{}, fmt.Errorf("failed to fetch init bond: %w", err)
	}
	initBond := result.GetBigInt(0)
	call := f.contract.Call(methodCreateGame, gameType, outputRoot, extraData)
	candidate, err := call.ToTxCandidate()
	if err != nil {
		return txmgr.TxCandidate{}, err
	}
	candidate.Value = initBond
	return candidate, err
}

func (f *DisputeGameFactory) gameCount(ctx context.Context) (uint64, error) {
	cCtx, cancel := context.WithTimeout(ctx, f.networkTimeout)
	defer cancel()
	result, err := f.caller.SingleCall(cCtx, rpcblock.Latest, f.contract.Call(methodGameCount))
	if err != nil {
		return 0, fmt.Errorf("failed to load game count: %w", err)
	}
	return bigs.Uint64Strict(result.GetBigInt(0)), nil
}

func (f *DisputeGameFactory) gameAtIndex(ctx context.Context, idx uint64) (gameInfo, error) {
	cCtx, cancel := context.WithTimeout(ctx, f.networkTimeout)
	defer cancel()
	result, err := f.caller.SingleCall(cCtx, rpcblock.Latest, f.contract.Call(methodGameAtIndex, new(big.Int).SetUint64(idx)))
	if err != nil {
		return gameInfo{}, fmt.Errorf("failed to load game %v: %w", idx, err)
	}
	return gameInfo{
		GameType:  result.GetUint32(0),
		Timestamp: time.Unix(int64(result.GetUint64(1)), 0),
		Address:   result.GetAddress(2),
	}, nil
}

func (f *DisputeGameFactory) loadGameMetadata(ctx context.Context, address common.Address) (proposalMetadata, error) {
	gameContract := batching.NewBoundContract(f.gameABI, address)
	cCtx, cancel := context.WithTimeout(ctx, f.networkTimeout)
	defer cancel()
	results, metadataErr := f.caller.Call(cCtx, rpcblock.Latest,
		gameContract.Call(methodGameCreator),
		gameContract.Call(methodRootClaim),
	)
	var claimant common.Address
	var claim common.Hash
	if metadataErr == nil {
		claimant = results[0].GetAddress(0)
		claim = results[1].GetHash(0)
	} else {
		cCtx, cancel = context.WithTimeout(ctx, f.networkTimeout)
		defer cancel()
		result, legacyErr := f.caller.SingleCall(cCtx, rpcblock.Latest, gameContract.Call(methodClaim, big.NewInt(0)))
		if legacyErr != nil {
			return proposalMetadata{}, errors.Join(
				fmt.Errorf("common getters failed: %w", metadataErr),
				fmt.Errorf("legacy claimData(0) failed: %w", legacyErr),
			)
		}
		claimant = result.GetAddress(2)
		claim = result.GetHash(4)
	}

	return proposalMetadata{
		Proposer: claimant,
		Claim:    claim,
	}, nil
}
