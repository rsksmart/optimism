package sequencing

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/log"

	"github.com/ethereum-optimism/optimism/op-node/rollup"
	"github.com/ethereum-optimism/optimism/op-node/rollup/derive"
	"github.com/ethereum-optimism/optimism/op-node/rollup/engine"
	"github.com/ethereum-optimism/optimism/op-service/clock"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/event"
	"github.com/ethereum-optimism/optimism/op-service/testlog"
	"github.com/ethereum-optimism/optimism/op-service/testutils"
)

// These tests cover the hold the sequencer applies after an engine reset that lands below the
// head it was sequencing on (or the first reset after start-up): no block is built until
// derivation reports idle, so the canonical chain is rebuilt from L1 first.

type rskSequencerFixture struct {
	seq     *Sequencer
	deps    *sequencerTestDeps
	emitter *testutils.MockEmitter
	clock   *clock.SimpleClock
	head    eth.L2BlockRef // head 100 at L1 origin 1000, fed by rskFeedHead
	genesis eth.L2BlockRef
}

// rskNewSequencer boots a sequencer the way the driver does (Init, then one action that only
// requests a forkchoice update), before any head is known. It reuses createSequencer and the
// fakes of sequencer_test.go.
func rskNewSequencer(t *testing.T, active bool) *rskSequencerFixture {
	t.Helper()
	logger := testlog.Logger(t, log.LevelError)
	seq, deps := createSequencer(logger)
	testClock := clock.NewSimpleClock()
	seq.timeNow = testClock.Now
	testClock.SetTime(30000)
	emitter := &testutils.MockEmitter{}
	seq.AttachEmitter(emitter)
	deps.conductor.leader = true
	seq.SetDerivationEnabled(true) // as the driver does outside follow-source mode

	require.NoError(t, seq.Init(context.Background(), active))
	emitter.AssertExpectations(t)
	if active {
		// zero head: only requests a forkchoice update, nothing is emitted
		seq.OnEvent(context.Background(), SequencerActionEvent{})
		emitter.AssertExpectations(t)
	}
	return &rskSequencerFixture{
		seq: seq, deps: deps, emitter: emitter, clock: testClock,
		head: eth.L2BlockRef{
			Hash:     common.Hash{0x22},
			Number:   100,
			L1Origin: eth.BlockID{Hash: common.Hash{0x11, 0xa}, Number: 1000},
			Time:     uint64(testClock.Now().Unix()),
		},
		genesis: eth.L2BlockRef{
			Hash:     deps.cfg.Genesis.L2.Hash,
			Number:   deps.cfg.Genesis.L2.Number,
			L1Origin: deps.cfg.Genesis.L1,
			Time:     deps.cfg.Genesis.L2Time,
		},
	}
}

// rskNewActiveSequencer is rskNewSequencer plus the first head, the state before any reset.
func rskNewActiveSequencer(t *testing.T, active bool) *rskSequencerFixture {
	t.Helper()
	f := rskNewSequencer(t, active)
	f.rskFCU(t, f.head)
	require.Equal(t, f.head, f.seq.latestHead)
	return f
}

func (f *rskSequencerFixture) rskFCU(t *testing.T, head eth.L2BlockRef) {
	t.Helper()
	f.seq.OnEvent(context.Background(), engine.ForkchoiceUpdateEvent{UnsafeL2Head: head, SafeL2Head: head})
	f.emitter.AssertExpectations(t)
}

// rskResetTo replays what the engine controller does on a reset: the reset signal, the
// forkchoice update carrying the head the engine actually has, then the reset confirmation.
func (f *rskSequencerFixture) rskResetTo(t *testing.T, resetHead eth.L2BlockRef) {
	t.Helper()
	f.seq.OnEvent(context.Background(), rollup.ResetEvent{})
	_, ok := f.seq.NextAction()
	require.False(t, ok, "no action until the reset is confirmed")

	f.rskFCU(t, resetHead)
	_, ok = f.seq.NextAction()
	require.False(t, ok, "the forkchoice update of the reset itself does not re-arm")
	require.Equal(t, resetHead, f.seq.latestHead)

	f.seq.OnEvent(context.Background(), engine.EngineResetConfirmedEvent{
		LocalUnsafe: resetHead, CrossUnsafe: resetHead,
		LocalSafe: resetHead, CrossSafe: resetHead, Finalized: resetHead,
	})
	f.emitter.AssertExpectations(t)
}

// rskSeal replays a sealed block reaching the sequencer, including the async gossiper buffering it.
func (f *rskSequencerFixture) rskSeal(t *testing.T, ref eth.L2BlockRef) {
	t.Helper()
	envelope := &eth.ExecutionPayloadEnvelope{ExecutionPayload: &eth.ExecutionPayload{
		BlockHash: ref.Hash, ParentHash: ref.ParentHash, BlockNumber: eth.Uint64Quantity(ref.Number),
	}}
	f.emitter.ExpectOnce(engine.PayloadProcessEvent{Envelope: envelope, Ref: ref})
	f.seq.OnEvent(context.Background(), engine.BuildSealedEvent{Envelope: envelope, Ref: ref})
	f.emitter.AssertExpectations(t)
	f.deps.asyncGossip.Gossip(envelope)
	require.Equal(t, ref, f.seq.latestSealed)
}

func (f *rskSequencerFixture) rskIdle(number uint64) {
	f.seq.OnEvent(context.Background(), derive.DeriverIdleEvent{Origin: eth.L1BlockRef{Number: number}})
}

func (f *rskSequencerFixture) rskExpectHeld(t *testing.T, msgAndArgs ...any) {
	t.Helper()
	_, ok := f.seq.NextAction()
	require.False(t, ok, append([]any{"sequencer must not schedule work"}, msgAndArgs...)[0])
	require.True(t, f.seq.awaitingDerivation, "sequencer is waiting for derivation")
}

func (f *rskSequencerFixture) rskExpectResumed(t *testing.T) {
	t.Helper()
	next, ok := f.seq.NextAction()
	require.True(t, ok, "sequencer schedules work again")
	require.False(t, f.seq.awaitingDerivation)
	require.Equal(t, f.clock.Now().Add(time.Duration(f.deps.cfg.BlockTime)*time.Second), next,
		"same one-block delay as an ordinary reset")
}

func TestRSK_SequencerHoldsAfterRewindReset(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	_, ok := f.seq.NextAction()
	require.True(t, ok, "active sequencer with a head schedules work")

	f.rskResetTo(t, f.genesis)
	f.rskExpectHeld(t)
	require.Equal(t, f.head, f.seq.headBeforeReset)
}

func TestRSK_SequencerNoReleaseOnForkchoiceWhileHeld(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	f.rskResetTo(t, f.genesis)

	// derivation re-inserts blocks 1 and 2: each raises the unsafe head, none re-arms
	for n := uint64(1); n <= 2; n++ {
		derived := eth.L2BlockRef{Hash: common.Hash{0x33, byte(n)}, Number: n, Time: f.genesis.Time + n*f.deps.cfg.BlockTime}
		f.rskFCU(t, derived)
		f.rskExpectHeld(t)
		require.Equal(t, derived, f.seq.latestHead, "the head is still tracked while held")
	}

	// a temporary engine error re-arms the action timer as upstream does, but the action
	// itself is a no-op while held: no BuildStartEvent (the mock emitter has no expectation,
	// the fake origin selector would panic) and the timer is disarmed again.
	f.seq.OnEvent(context.Background(), rollup.EngineTemporaryErrorEvent{Err: engine.ErrEngineSyncing})
	f.seq.OnEvent(context.Background(), SequencerActionEvent{})
	f.emitter.AssertExpectations(t)
	f.rskExpectHeld(t)
}

func TestRSK_SequencerReleasesOnDeriverIdle(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	f.rskResetTo(t, f.genesis)
	derived := eth.L2BlockRef{
		Hash: common.Hash{0x33, 0x2}, Number: 2,
		L1Origin: f.head.L1Origin,
		Time:     uint64(f.clock.Now().Unix()),
	}
	f.rskFCU(t, derived)
	f.rskExpectHeld(t)

	f.rskIdle(f.head.L1Origin.Number)
	f.rskExpectResumed(t)

	// the next action builds on the head derivation left, not on the pre-reset one
	l1Origin := eth.L1BlockRef{
		Hash: common.Hash{0x11, 0xb}, ParentHash: f.head.L1Origin.Hash,
		Number: f.head.L1Origin.Number + 1, Time: f.head.Time - 2,
	}
	f.deps.l1OriginSelector.l1OriginFn = func(l2Head eth.L2BlockRef) (eth.L1BlockRef, error) { return l1Origin, nil }
	next, _ := f.seq.NextAction()
	f.clock.Set(next)
	f.emitter.ExpectOnceRun(func(ev event.Event) {
		x, ok := ev.(engine.BuildStartEvent)
		require.True(t, ok)
		require.Equal(t, derived, x.Attributes.Parent)
	})
	f.seq.OnEvent(context.Background(), SequencerActionEvent{})
	f.emitter.AssertExpectations(t)

	// idle while not held changes nothing
	before, beforeOK := f.seq.NextAction()
	f.rskIdle(f.head.L1Origin.Number + 1)
	after, afterOK := f.seq.NextAction()
	require.Equal(t, beforeOK, afterOK)
	require.Equal(t, before, after)
}

// The default path: a reset that confirms the head the sequencer already knew (an L1 reorg
// below the unsafe head, an inconsistent-origin reset, ...) keeps upstream's behaviour and
// re-arms one block time later without waiting for derivation.
func TestRSK_SequencerResetWithoutRewindKeepsUpstreamBehaviour(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	f.rskResetTo(t, f.head)
	f.rskExpectResumed(t)
}

// The first reset after start-up has no head to compare against: op-node may have been
// restarted against an engine that already rewound, so it waits for derivation too.
func TestRSK_SequencerHoldsOnStartupReset(t *testing.T) {
	f := rskNewSequencer(t, true)
	f.rskResetTo(t, f.genesis)
	f.rskExpectHeld(t)

	f.rskIdle(0)
	f.rskExpectResumed(t)
}

// A reset confirmation without a preceding reset signal (the follow-source initial reset,
// which never steps derivation and so never goes idle) must not hold.
func TestRSK_SequencerConfirmWithoutResetDoesNotHold(t *testing.T) {
	f := rskNewSequencer(t, true)
	f.seq.OnEvent(context.Background(), engine.ForkchoiceUpdateInitEvent{UnsafeL2Head: f.head})
	f.seq.OnEvent(context.Background(), engine.EngineResetConfirmedEvent{LocalUnsafe: f.head, CrossSafe: f.head})
	_, ok := f.seq.NextAction()
	require.True(t, ok)
	require.False(t, f.seq.awaitingDerivation)
}

// A confirmation with no reset signal is never held, even if an older reset left a higher head
// snapshot behind (interop replacement blocks and supervisor resets confirm without a signal).
func TestRSK_SequencerStaleSnapshotDoesNotHold(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	f.rskResetTo(t, f.head) // ordinary reset, snapshot = head 100, not held
	require.False(t, f.seq.awaitingDerivation)

	f.seq.OnEvent(context.Background(), engine.EngineResetConfirmedEvent{LocalUnsafe: f.genesis, CrossSafe: f.genesis})
	require.False(t, f.seq.awaitingDerivation)
	_, ok := f.seq.NextAction()
	require.True(t, ok)
}

// An idle signal whose L1 origin is below the one the sequencer was anchored to before the
// reset (an L1 endpoint answering "not found" early) does not release the hold.
func TestRSK_SequencerIgnoresIdleBelowPreResetOrigin(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	f.rskResetTo(t, f.genesis)

	f.rskIdle(f.head.L1Origin.Number - 1)
	f.rskExpectHeld(t)

	f.rskIdle(f.head.L1Origin.Number)
	f.rskExpectResumed(t)
}

// A block sealed just before the reset is not on the chain derivation rebuilds: at release it
// is dropped from the async-gossip buffer and Stop no longer waits for it.
func TestRSK_SequencerDropsSealedBlockOnRelease(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	f.rskSeal(t, eth.L2BlockRef{Hash: common.Hash{0xaa}, ParentHash: f.head.Hash, Number: 101})
	f.rskResetTo(t, f.genesis)
	derived := eth.L2BlockRef{Hash: common.Hash{0x33, 120}, Number: 120, Time: f.head.Time}
	f.rskFCU(t, derived)
	require.NotNil(t, f.deps.asyncGossip.Get(), "buffer kept while held")

	f.rskIdle(f.head.L1Origin.Number)
	f.rskExpectResumed(t)
	require.Nil(t, f.deps.asyncGossip.Get(), "sealed payload dropped at release")
	require.Equal(t, derived, f.seq.latestSealed, "Stop has nothing to wait for")
}

// A second reset while held (a temporary error, another engine reset) must not lower the bar:
// latestHead tracks the chain derivation is rebuilding, well below where the sequencer was.
func TestRSK_SequencerSecondResetKeepsOriginalSnapshot(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	f.rskResetTo(t, f.genesis)
	f.rskExpectHeld(t)

	// derivation gets a few blocks in, on L1 origins far below the pre-reset one
	partial := eth.L2BlockRef{
		Hash: common.Hash{0x33, 5}, Number: 5,
		L1Origin: eth.BlockID{Hash: common.Hash{0x11, 0x5}, Number: 10},
		Time:     f.genesis.Time + 10,
	}
	f.rskFCU(t, partial)
	f.rskResetTo(t, partial) // second reset, confirmed at the partially rebuilt head
	f.rskExpectHeld(t)
	require.Equal(t, f.head, f.seq.headBeforeReset, "the pre-crash head stays the bar to clear")

	f.rskIdle(partial.L1Origin.Number)
	f.rskExpectHeld(t, "an idle at the partial head's origin must not release")

	f.rskIdle(f.head.L1Origin.Number)
	f.rskExpectResumed(t)
}

// A reset onto a different chain at the same height is as much a fork as a rewind.
func TestRSK_SequencerHoldsOnSameHeightFork(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	sibling := eth.L2BlockRef{
		Hash: common.Hash{0x99}, Number: f.head.Number,
		L1Origin: f.head.L1Origin, Time: f.head.Time,
	}
	f.rskResetTo(t, sibling)
	f.rskExpectHeld(t)
}

// Without a derivation pipeline (follow-source) nothing would ever emit DeriverIdleEvent, so
// the sequencer must not hold: it would wedge with no way out.
func TestRSK_SequencerDoesNotHoldWithoutDerivation(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	f.seq.SetDerivationEnabled(false)
	f.rskResetTo(t, f.genesis)
	require.False(t, f.seq.awaitingDerivation)
	_, ok := f.seq.NextAction()
	require.True(t, ok, "upstream behaviour when the hold cannot be released")
}

// Conductor path: the sequencer is started by an admin request while held. The start is
// accepted, but nothing is built until derivation is idle.
func TestRSK_SequencerStartWhileHeld(t *testing.T) {
	f := rskNewActiveSequencer(t, false)
	_, ok := f.seq.NextAction()
	require.False(t, ok, "not active yet")
	f.rskResetTo(t, f.genesis)
	require.True(t, f.seq.awaitingDerivation)

	require.NoError(t, f.seq.Start(context.Background(), f.genesis.Hash))
	require.True(t, f.seq.Active())
	f.rskExpectHeld(t, "Start must not arm the timer while held")
	f.seq.OnEvent(context.Background(), SequencerActionEvent{})
	f.emitter.AssertExpectations(t)
	f.rskExpectHeld(t)

	f.rskIdle(f.head.L1Origin.Number)
	f.rskExpectResumed(t)
}

// Stop waits for the head to reach the last sealed block; while held that block is off the
// chain being rebuilt, so the wait is skipped.
func TestRSK_SequencerStopWhileHeldDoesNotBlock(t *testing.T) {
	f := rskNewActiveSequencer(t, true)
	f.rskSeal(t, eth.L2BlockRef{Hash: common.Hash{0xaa}, ParentHash: f.head.Hash, Number: 101})
	f.rskResetTo(t, f.genesis)
	require.NotEqual(t, f.seq.latestHead.Hash, f.seq.latestSealed.Hash)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	head, err := f.seq.Stop(ctx)
	require.NoError(t, err)
	require.Equal(t, f.genesis.Hash, head)
	require.False(t, f.seq.Active())
}
