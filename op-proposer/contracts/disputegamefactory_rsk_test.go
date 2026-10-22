package contracts_test

// RSK fork coverage for op-proposer/contracts/disputegamefactory.go
// GameExists, which upstream does not have. External test package with
// rsk-prefixed helpers; method names mirror the Solidity ABI (see
// AGENTS_rsk.md).

import (
	"context"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-proposer/contracts"
	"github.com/ethereum-optimism/optimism/op-service/sources/batching"
	"github.com/ethereum-optimism/optimism/op-service/sources/batching/rpcblock"
	batchingTest "github.com/ethereum-optimism/optimism/op-service/sources/batching/test"
	"github.com/ethereum-optimism/optimism/packages/contracts-bedrock/snapshots"
)

const rskMethodGames = "games"

var rskFactoryAddr = common.Address{0xff, 0xff}

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
			stubRpc := batchingTest.NewAbiBasedRpc(t, rskFactoryAddr, snapshots.LoadDisputeGameFactoryABI())
			caller := batching.NewMultiCaller(stubRpc, batching.DefaultBatchSize)
			factory := contracts.NewDisputeGameFactory(rskFactoryAddr, caller, time.Minute)
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
