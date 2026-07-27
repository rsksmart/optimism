package broadcaster_test

// RSK fork coverage for broadcaster.KeyedBroadcasterOpts.TxMgrConfigHook
// (keyed.go).
//
// The fork lets a downstream mutate the assembled txmgr.Config after defaults
// are applied but before the tx manager is built — the seam RSK uses to set
// UseLegacyTx / GasPriceEstimatorFn / PrepareBackoff / wrap the backend. This
// test asserts the hook runs at that point and sees the pre-applied deployer
// defaults. Upstream never sets the hook, so it has no upstream coverage.
//
// See AGENTS_rsk.md for the _rsk_test.go / TestRSK_ convention.

import (
	"context"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/log"

	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-deployer/pkg/deployer/broadcaster"
	"github.com/ethereum-optimism/optimism/op-service/testlog"
	"github.com/ethereum-optimism/optimism/op-service/txmgr"
)

// TestRSK_KeyedBroadcaster_TxMgrConfigHookInvoked asserts the TxMgrConfigHook is
// invoked with the assembled txmgr.Config after the deployer defaults are
// applied (GasPriceEstimatorFn and MinTipCap are already set) and before the tx
// manager is constructed — the seam a downstream uses to inject RSK overrides
// such as UseLegacyTx.
func TestRSK_KeyedBroadcaster_TxMgrConfigHookInvoked(t *testing.T) {
	called := false
	var gotCfg *txmgr.Config

	opts := broadcaster.KeyedBroadcasterOpts{
		Logger: testlog.Logger(t, log.LevelCrit),
		From:   common.Address{0x1},
		Signer: func(_ context.Context, from common.Address, tx *types.Transaction) (*types.Transaction, error) {
			return tx, nil
		},
		TxMgrConfigHook: func(c *txmgr.Config) {
			called = true
			gotCfg = c
		},
	}

	// Client is nil, so NewSimpleTxManagerFromConfig may fail afterwards; that's
	// irrelevant — the hook fires before the tx manager is constructed.
	_, _ = broadcaster.NewKeyedBroadcaster(opts)

	require.True(t, called, "TxMgrConfigHook must be invoked")
	require.NotNil(t, gotCfg)
	require.NotNil(t, gotCfg.GasPriceEstimatorFn, "hook must see the deployer's assembled config")
	require.NotNil(t, gotCfg.MinTipCap.Load(), "hook must run after defaults are applied")
}

// TestRSK_KeyedBroadcaster_NilHookIsSafe is the control: a nil TxMgrConfigHook
// leaves construction on its upstream path (no panic from the added seam).
func TestRSK_KeyedBroadcaster_NilHookIsSafe(t *testing.T) {
	opts := broadcaster.KeyedBroadcasterOpts{
		Logger: testlog.Logger(t, log.LevelCrit),
		From:   common.Address{0x1},
		Signer: func(_ context.Context, from common.Address, tx *types.Transaction) (*types.Transaction, error) {
			return tx, nil
		},
		// TxMgrConfigHook: nil
	}
	require.NotPanics(t, func() {
		_, _ = broadcaster.NewKeyedBroadcaster(opts)
	})
}
