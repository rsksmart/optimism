package proposer

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/ethereum-optimism/optimism/op-proposer/metrics"
	"github.com/ethereum-optimism/optimism/op-proposer/proposer/source"
	"github.com/ethereum-optimism/optimism/op-service/dial"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/testlog"
	"github.com/ethereum-optimism/optimism/op-service/testutils"
	"github.com/ethereum-optimism/optimism/op-service/txmgr"
	txmgrmocks "github.com/ethereum-optimism/optimism/op-service/txmgr/mocks"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/log"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"
)

type StubDGFContract struct {
	hasProposedCount int
	gameExistsCount  int
	gameExists       bool
	gameExistsErr    error
}

func (m *StubDGFContract) GameExists(_ context.Context, _ uint32, _ common.Hash, _ []byte) (bool, error) {
	m.gameExistsCount++
	return m.gameExists, m.gameExistsErr
}

func (m *StubDGFContract) HasProposedSince(_ context.Context, _ common.Address, _ time.Time, _ uint32) (bool, time.Time, common.Hash, error) {
	m.hasProposedCount++
	return false, time.Unix(1000, 0), common.Hash{0xdd}, nil
}

func (m *StubDGFContract) ProposalTx(_ context.Context, _ uint32, _ common.Hash, _ []byte) (txmgr.TxCandidate, error) {
	return txmgr.TxCandidate{}, nil
}

func (m *StubDGFContract) Version(_ context.Context) (string, error) {
	panic("not implemented")
}

type mockRollupEndpointProvider struct {
	rollupClient    *testutils.MockRollupClient
	rollupClientErr error
}

func newEndpointProvider() *mockRollupEndpointProvider {
	return &mockRollupEndpointProvider{
		rollupClient: new(testutils.MockRollupClient),
	}
}

func (p *mockRollupEndpointProvider) RollupClient(context.Context) (dial.RollupClientInterface, error) {
	return p.rollupClient, p.rollupClientErr
}

func (p *mockRollupEndpointProvider) Close() {}

func setup(t *testing.T) (*L2OutputSubmitter, *mockRollupEndpointProvider, *StubDGFContract, *txmgrmocks.TxManager, *testlog.CapturingHandler) {
	ep := newEndpointProvider()

	proposerConfig := ProposerConfig{
		PollInterval:     time.Microsecond,
		ProposalInterval: time.Microsecond,
	}

	txmgr := txmgrmocks.NewTxManager(t)

	lgr, logs := testlog.CaptureLogger(t, log.LevelDebug)
	setup := DriverSetup{
		Log:            lgr,
		Metr:           metrics.NoopMetrics,
		Cfg:            proposerConfig,
		Txmgr:          txmgr,
		ProposalSource: source.NewRollupProposalSource(ep),
	}

	ctx, cancel := context.WithCancel(context.Background())

	l2OutputSubmitter := L2OutputSubmitter{
		DriverSetup: setup,
		done:        make(chan struct{}),
		ctx:         ctx,
		cancel:      cancel,
	}
	mockDGFContract := new(StubDGFContract)
	l2OutputSubmitter.dgfContract = mockDGFContract

	txmgr.On("Send", mock.Anything, mock.Anything).
		Return(&types.Receipt{Status: uint64(1), TxHash: common.Hash{}}, nil).
		Once().
		Run(func(_ mock.Arguments) {
			// let loops return after first Send call
			t.Log("Closing proposer.")
			close(l2OutputSubmitter.done)
		})

	return &l2OutputSubmitter, ep, mockDGFContract, txmgr, logs
}

func TestL2OutputSubmitter_OutputRetry(t *testing.T) {
	proposerAddr := common.Address{0xab}
	const numFails = 3

	ps, ep, dgfContract, txmgr, logs := setup(t)

	ep.rollupClient.On("SyncStatus").Return(&eth.SyncStatus{FinalizedL2: eth.L2BlockRef{Number: 42}}, nil).Times(numFails + 1)
	ep.rollupClient.ExpectOutputAtBlock(42, nil, fmt.Errorf("TEST: failed to fetch output")).Times(numFails)
	ep.rollupClient.ExpectOutputAtBlock(
		42,
		&eth.OutputResponse{
			Version:  eth.OutputVersionV0,
			BlockRef: eth.L2BlockRef{Number: 42},
			Status: &eth.SyncStatus{
				CurrentL1:   eth.L1BlockRef{Hash: common.Hash{}},
				FinalizedL2: eth.L2BlockRef{Number: 42},
			},
		},
		nil,
	)

	txmgr.On("From").Return(proposerAddr).Times(numFails + 1)

	ps.wg.Add(1)
	ps.loop()

	ep.rollupClient.AssertExpectations(t)

	require.Equal(t, numFails+1, dgfContract.hasProposedCount)

	require.Len(t, logs.FindLogs(testlog.NewMessageContainsFilter("Error getting proposal")), numFails)
	require.NotNil(t, logs.FindLog(testlog.NewMessageFilter("Proposer tx successfully published")))
	require.NotNil(t, logs.FindLog(testlog.NewMessageFilter("loop returning")))
}

// setupFetchOnly builds a submitter for exercising FetchDGFOutput directly.
// setup() registers a one-shot Send expectation that only loop() satisfies, so
// reusing it here would fail on unmet expectations.
func setupFetchOnly(t *testing.T) (*L2OutputSubmitter, *mockRollupEndpointProvider, *StubDGFContract, *testlog.CapturingHandler) {
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
			},
			Txmgr:          tm,
			ProposalSource: source.NewRollupProposalSource(ep),
		},
		done:   make(chan struct{}),
		ctx:    ctx,
		cancel: cancel,
	}
	stub := new(StubDGFContract)
	ps.dgfContract = stub
	return ps, ep, stub, logs
}

func expectOutputAt(ep *mockRollupEndpointProvider, blockNum uint64, times int) {
	ep.rollupClient.On("SyncStatus").
		Return(&eth.SyncStatus{FinalizedL2: eth.L2BlockRef{Number: blockNum}}, nil).Times(times)
	ep.rollupClient.ExpectOutputAtBlock(
		blockNum,
		&eth.OutputResponse{
			Version:  eth.OutputVersionV0,
			BlockRef: eth.L2BlockRef{Number: blockNum},
			Status: &eth.SyncStatus{
				CurrentL1:   eth.L1BlockRef{Hash: common.Hash{}},
				FinalizedL2: eth.L2BlockRef{Number: blockNum},
			},
		},
		nil,
	).Times(times)
}

func TestFetchDGFOutput_SkipsWhenGameAlreadyExists(t *testing.T) {
	ps, ep, dgf, logs := setupFetchOnly(t)
	expectOutputAt(ep, 42, 1)
	dgf.gameExists = true

	_, shouldPropose, err := ps.FetchDGFOutput(context.Background())

	require.NoError(t, err)
	require.False(t, shouldPropose, "must not propose into an occupied slot")
	require.Equal(t, 1, dgf.gameExistsCount)
	require.NotNil(t, logs.FindLog(testlog.NewMessageContainsFilter("a game already exists")))
}

func TestFetchDGFOutput_ProposesWhenSlotIsFree(t *testing.T) {
	ps, ep, dgf, _ := setupFetchOnly(t)
	expectOutputAt(ep, 42, 1)
	dgf.gameExists = false

	output, shouldPropose, err := ps.FetchDGFOutput(context.Background())

	require.NoError(t, err)
	require.True(t, shouldPropose)
	require.Equal(t, uint64(42), output.SequenceNum)
	require.Equal(t, 1, dgf.gameExistsCount)
}

func TestFetchDGFOutput_GameExistsErrorSkipsTick(t *testing.T) {
	ps, ep, dgf, _ := setupFetchOnly(t)
	expectOutputAt(ep, 42, 1)
	dgf.gameExistsErr = fmt.Errorf("TEST: L1 unreachable")

	_, shouldPropose, err := ps.FetchDGFOutput(context.Background())

	require.ErrorContains(t, err, "could not check whether a game already exists")
	require.False(t, shouldPropose)
}

// The regression that matters: a stalled finalized head offers the same
// (root, sequenceNum) on two consecutive intervals. The first proposal lands,
// the second must be skipped rather than reverting GameAlreadyExists on-chain.
// Note this needs no restart — a stall alone reproduces it.
func TestFetchDGFOutput_StalledFinalizedHeadProposesOnlyOnce(t *testing.T) {
	ps, ep, dgf, _ := setupFetchOnly(t)
	expectOutputAt(ep, 42, 2)

	_, shouldPropose, err := ps.FetchDGFOutput(context.Background())
	require.NoError(t, err)
	require.True(t, shouldPropose, "first proposal for a free slot")

	// The proposal landed, so the factory slot is now taken.
	dgf.gameExists = true

	_, shouldPropose, err = ps.FetchDGFOutput(context.Background())
	require.NoError(t, err)
	require.False(t, shouldPropose, "second attempt at the same root must be skipped")
	require.Equal(t, 2, dgf.gameExistsCount)
}
