package proposer

// RSK fork coverage for op-proposer/proposer/driver.go FetchDGFOutput.
//
// Upstream's only identity-based duplicate check compares the claim returned by
// HasProposedSince against the fresh output root, and that claim is zero on
// every branch that reaches the comparison, so the check never fires. The fork
// asks the factory instead (DGFContract.GameExists), which is the predicate
// create() reverts GameAlreadyExists on. None of those branches has upstream
// coverage.
//
// Internal test package: FetchDGFOutput is exported, but driving it needs the
// unexported L2OutputSubmitter fields (dgfContract, ctx, cancel, done) that no
// exported constructor sets without dialling L1/L2. Upstream seams
// (StubDGFContract, newEndpointProvider, testlog) are reused; everything added
// here is rsk-prefixed (see AGENTS_rsk.md).

import (
	"context"
	"encoding/binary"
	"fmt"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/log"
	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-proposer/metrics"
	"github.com/ethereum-optimism/optimism/op-proposer/proposer/source"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/testlog"
	txmgrmocks "github.com/ethereum-optimism/optimism/op-service/txmgr/mocks"
)

const (
	// Non-zero so the assertions below prove the driver forwards the configured
	// game type rather than a zero value that would match by accident.
	rskTestGameType = uint32(1)
	rskTestBlockNum = uint64(42)
)

// Differs from the claim StubDGFContract.HasProposedSince returns (0xdd), so
// the fork's slot check is what decides these tests, not upstream's comparison.
var rskTestOutputRoot = eth.Bytes32{0xaa}

// GameExists keeps the upstream StubDGFContract satisfying DGFContract, which
// the fork extended. Reporting every slot free leaves the upstream proposal
// paths behaving exactly as they did. Declared here, on the upstream type, so
// driver_test.go stays byte-identical to upstream and can't conflict on sync.
func (m *StubDGFContract) GameExists(_ context.Context, _ uint32, _ common.Hash, _ []byte) (bool, error) {
	return false, nil
}

// rskStubDGFContract records what the driver asks the factory, so a probe of the
// wrong slot fails the test instead of passing on a canned answer.
type rskStubDGFContract struct {
	StubDGFContract
	gameExists    bool
	gameExistsErr error

	gameExistsCount     int
	gameExistsGameType  uint32
	gameExistsRootClaim common.Hash
	gameExistsExtraData []byte
}

func (m *rskStubDGFContract) GameExists(_ context.Context, gameType uint32, rootClaim common.Hash, extraData []byte) (bool, error) {
	m.gameExistsCount++
	m.gameExistsGameType = gameType
	m.gameExistsRootClaim = rootClaim
	m.gameExistsExtraData = extraData
	return m.gameExists, m.gameExistsErr
}

// rskRequireProbedSlot asserts the factory was asked about the exact slot
// create() would key: the configured game type, the fetched output root, and
// the 32-byte big-endian sequence number that source.Proposal.ExtraData builds.
func rskRequireProbedSlot(t *testing.T, dgf *rskStubDGFContract, wantCalls int, wantSeqNum uint64) {
	t.Helper()
	require.Equal(t, wantCalls, dgf.gameExistsCount)
	require.Equal(t, rskTestGameType, dgf.gameExistsGameType, "must probe the configured game type")
	require.Equal(t, common.Hash(rskTestOutputRoot), dgf.gameExistsRootClaim, "must probe the fetched output root")

	var wantExtraData [32]byte
	binary.BigEndian.PutUint64(wantExtraData[24:], wantSeqNum)
	require.Equal(t, wantExtraData[:], dgf.gameExistsExtraData, "must probe the ABI-encoded sequence number")
}

// rskSetupFetchOnly builds a submitter for exercising FetchDGFOutput directly.
// The upstream setup() registers a one-shot Send expectation that only loop()
// satisfies, so reusing it here would fail on unmet expectations.
func rskSetupFetchOnly(t *testing.T) (*L2OutputSubmitter, *mockRollupEndpointProvider, *rskStubDGFContract, *testlog.CapturingHandler) {
	ep := newEndpointProvider()
	tm := txmgrmocks.NewTxManager(t)
	tm.On("From").Return(common.Address{0xab}).Maybe()

	lgr, logs := testlog.CaptureLogger(t, log.LevelDebug)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	ps := &L2OutputSubmitter{
		DriverSetup: DriverSetup{
			Log:  lgr,
			Metr: metrics.NoopMetrics,
			Cfg: ProposerConfig{
				PollInterval:     time.Microsecond,
				ProposalInterval: time.Microsecond,
				DisputeGameType:  rskTestGameType,
			},
			Txmgr:          tm,
			ProposalSource: source.NewRollupProposalSource(ep),
		},
		done:   make(chan struct{}),
		ctx:    ctx,
		cancel: cancel,
	}
	stub := new(rskStubDGFContract)
	ps.dgfContract = stub
	return ps, ep, stub, logs
}

func rskExpectOutputAt(ep *mockRollupEndpointProvider, blockNum uint64, times int) {
	ep.rollupClient.On("SyncStatus").
		Return(&eth.SyncStatus{FinalizedL2: eth.L2BlockRef{Number: blockNum}}, nil).Times(times)
	ep.rollupClient.ExpectOutputAtBlock(
		blockNum,
		&eth.OutputResponse{
			Version:    eth.OutputVersionV0,
			OutputRoot: rskTestOutputRoot,
			BlockRef:   eth.L2BlockRef{Number: blockNum},
			Status: &eth.SyncStatus{
				CurrentL1:   eth.L1BlockRef{Hash: common.Hash{}},
				FinalizedL2: eth.L2BlockRef{Number: blockNum},
			},
		},
		nil,
	).Times(times)
}

func TestRSK_FetchDGFOutput_SkipsWhenGameAlreadyExists(t *testing.T) {
	ps, ep, dgf, logs := rskSetupFetchOnly(t)
	rskExpectOutputAt(ep, rskTestBlockNum, 1)
	dgf.gameExists = true

	_, shouldPropose, err := ps.FetchDGFOutput(context.Background())

	require.NoError(t, err)
	require.False(t, shouldPropose, "must not propose into an occupied slot")
	rskRequireProbedSlot(t, dgf, 1, rskTestBlockNum)
	require.NotNil(t, logs.FindLog(testlog.NewMessageContainsFilter("a game already exists")))
}

func TestRSK_FetchDGFOutput_ProposesWhenSlotIsFree(t *testing.T) {
	ps, ep, dgf, _ := rskSetupFetchOnly(t)
	rskExpectOutputAt(ep, rskTestBlockNum, 1)
	dgf.gameExists = false

	output, shouldPropose, err := ps.FetchDGFOutput(context.Background())

	require.NoError(t, err)
	require.True(t, shouldPropose)
	require.Equal(t, rskTestBlockNum, output.SequenceNum)
	require.Equal(t, common.Hash(rskTestOutputRoot), output.Root)
	rskRequireProbedSlot(t, dgf, 1, rskTestBlockNum)
}

func TestRSK_FetchDGFOutput_GameExistsErrorSkipsTick(t *testing.T) {
	ps, ep, dgf, _ := rskSetupFetchOnly(t)
	rskExpectOutputAt(ep, rskTestBlockNum, 1)
	dgf.gameExistsErr = fmt.Errorf("TEST: L1 unreachable")

	_, shouldPropose, err := ps.FetchDGFOutput(context.Background())

	require.ErrorContains(t, err, "could not check whether a game already exists")
	require.False(t, shouldPropose)
	rskRequireProbedSlot(t, dgf, 1, rskTestBlockNum)
}

// The regression that matters: a stalled finalized head offers the same
// (root, sequenceNum) on two consecutive intervals. The first proposal lands,
// the second must be skipped rather than reverting GameAlreadyExists on-chain.
// Note this needs no restart — a stall alone reproduces it.
func TestRSK_FetchDGFOutput_StalledFinalizedHeadProposesOnlyOnce(t *testing.T) {
	ps, ep, dgf, _ := rskSetupFetchOnly(t)
	rskExpectOutputAt(ep, rskTestBlockNum, 2)

	_, shouldPropose, err := ps.FetchDGFOutput(context.Background())
	require.NoError(t, err)
	require.True(t, shouldPropose, "first proposal for a free slot")

	// The proposal landed, so the factory slot is now taken.
	dgf.gameExists = true

	_, shouldPropose, err = ps.FetchDGFOutput(context.Background())
	require.NoError(t, err)
	require.False(t, shouldPropose, "second attempt at the same root must be skipped")
	rskRequireProbedSlot(t, dgf, 2, rskTestBlockNum)
}
