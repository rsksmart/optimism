package sources

// RSK fork coverage for the pluggable, non-Ethereum L1 hooks added to
// op-service/sources (eth_client.go, receipts_rpc.go, types.go).
//
// The fork lets an operator override four Ethereum-specific verification /
// hashing steps so RSK (binary Unitrie, RSKIP-92 hashing, divergent tx hashes)
// can be used as the L1. Each hook is nil by default (standard Ethereum
// behavior) and, when set, fully replaces the default. Upstream never sets
// these, so the dispatch has no upstream coverage.
//
// This file needs the unexported runHeaderVerify / runBlockVerify methods and
// the unexported EthClient hook fields, so it lives in the internal `sources`
// test package (see AGENTS_rsk.md — internal package only when unexported
// access is required). Test helpers/mocks are rsk-prefixed.

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"testing"

	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/ethereum-optimism/optimism/op-service/bigs"
	"github.com/ethereum-optimism/optimism/op-service/eth"
)

// rskTamperHash returns a copy of h with the first byte flipped, so that a
// header/block carrying it fails the default hash recomputation.
func rskTamperHash(h common.Hash) common.Hash {
	h[0]++
	return h
}

// TestRSK_EthClient_HeaderVerifierHook covers eth_client.go runHeaderVerify:
// a nil HeaderVerifier uses the default Ethereum hash recomputation, while a
// non-nil one fully replaces it.
func TestRSK_EthClient_HeaderVerifierHook(t *testing.T) {
	ctx := context.Background()
	_, good := randHeader() // self-consistent: default VerifyHash passes

	bad := *good
	bad.Hash = rskTamperHash(bad.Hash) // default VerifyHash now fails

	t.Run("nil hook accepts a valid header via default path", func(t *testing.T) {
		s := &EthClient{} // headerVerifier == nil
		require.NoError(t, s.runHeaderVerify(ctx, good))
	})

	t.Run("nil hook rejects a tampered header via default path", func(t *testing.T) {
		s := &EthClient{}
		err := s.runHeaderVerify(ctx, &bad)
		require.Error(t, err)
		require.Contains(t, err.Error(), "verify block hash")
	})

	t.Run("non-nil hook is invoked and its error propagates", func(t *testing.T) {
		wantErr := errors.New("rsk: header rejected by RSKIP-92 verifier")
		var gotHeader *types.Header
		s := &EthClient{headerVerifier: func(_ context.Context, hdr *types.Header) error {
			gotHeader = hdr
			return wantErr
		}}
		// good header would pass the default path; the hook must still run and reject.
		err := s.runHeaderVerify(ctx, good)
		require.ErrorIs(t, err, wantErr)
		require.NotNil(t, gotHeader)
		require.Equal(t, uint64(good.Number), bigs.Uint64Strict(gotHeader.Number))
	})

	t.Run("non-nil hook overrides the default (accepts a tampered header)", func(t *testing.T) {
		called := false
		s := &EthClient{headerVerifier: func(_ context.Context, _ *types.Header) error {
			called = true
			return nil
		}}
		// tampered header would fail the default path; the hook accepts it instead.
		require.NoError(t, s.runHeaderVerify(ctx, &bad))
		require.True(t, called, "hook must replace the default verifier")
	})
}

// TestRSK_EthClient_BlockVerifierHook covers eth_client.go runBlockVerify:
// a nil BlockVerifier uses the default RPCBlock.Verify (block hash + tx-trie
// root + withdrawals), while a non-nil one fully replaces it.
func TestRSK_EthClient_BlockVerifierHook(t *testing.T) {
	ctx := context.Background()
	rng := rand.New(rand.NewSource(99))
	good, _ := randomRpcBlockAndReceipts(rng, 2) // self-consistent: default Verify passes

	bad := *good
	bad.Hash = rskTamperHash(bad.Hash) // default Verify now fails

	t.Run("nil hook accepts a valid block via default path", func(t *testing.T) {
		s := &EthClient{} // blockVerifier == nil
		require.NoError(t, s.runBlockVerify(ctx, good))
	})

	t.Run("nil hook rejects a tampered block via default path", func(t *testing.T) {
		s := &EthClient{}
		err := s.runBlockVerify(ctx, &bad)
		require.Error(t, err)
		require.Contains(t, err.Error(), "verify block hash")
	})

	t.Run("non-nil hook is invoked with header and txs, error propagates", func(t *testing.T) {
		wantErr := errors.New("rsk: block rejected by unitrie verifier")
		var gotHeader *types.Header
		var gotTxs types.Transactions
		s := &EthClient{blockVerifier: func(_ context.Context, hdr *types.Header, txs types.Transactions) error {
			gotHeader, gotTxs = hdr, txs
			return wantErr
		}}
		err := s.runBlockVerify(ctx, good)
		require.ErrorIs(t, err, wantErr)
		require.NotNil(t, gotHeader)
		require.Len(t, gotTxs, len(good.Transactions), "hook must receive the block transactions")
	})

	t.Run("non-nil hook overrides the default (accepts a tampered block)", func(t *testing.T) {
		called := false
		s := &EthClient{blockVerifier: func(_ context.Context, _ *types.Header, _ types.Transactions) error {
			called = true
			return nil
		}}
		require.NoError(t, s.runBlockVerify(ctx, &bad))
		require.True(t, called, "hook must replace the default verifier")
	})
}

// TestRSK_EthClient_TxHashesFromBlockHook covers eth_client.go FetchReceipts:
// with a nil TxHashesFromBlock the receipt-fetch tx hashes are derived locally
// (eth.TransactionsToHashes); when set, the hook fully replaces that source, and
// an error from it aborts the fetch. A capturing ReceiptsValidator records the
// tx hashes actually handed to the receipts fetch, so each case can assert which
// source won.
func TestRSK_EthClient_TxHashesFromBlockHook(t *testing.T) {
	ctx := context.Background()
	const numTxs = 1

	// buildClient wires an EthClient with the given TxHashesFromBlock hook and a
	// validator that captures the tx hashes passed to the receipts fetch.
	buildClient := func(hook TxHashesFromBlockFn) (*EthClient, *RPCBlock, *[]common.Hash) {
		m := new(mockRPC)
		block, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(7)), numTxs)
		m.On("CallContext", ctx, mock.Anything, "eth_getTransactionReceipt", mock.Anything).
			Return([]error{nil})
		m.On("CallContext", ctx, mock.Anything, "eth_getBlockByHash", mock.Anything).
			Run(func(args mock.Arguments) { *(args[1].(**RPCBlock)) = block }).
			Return([]error{nil})

		captured := new([]common.Hash)
		rp := NewRPCReceiptsFetcher(m, nil, RPCReceiptsConfig{
			ReceiptsValidator: func(_ context.Context, _ eth.BlockID, _ common.Hash, txHashes []common.Hash, _ types.Receipts) error {
				*captured = txHashes
				return nil
			},
		})
		ethcl := newEthClientWithCaches(nil, numTxs)
		ethcl.client = m
		ethcl.recProvider = rp
		ethcl.trustRPC = true // skip default block verification; isolate the hook
		ethcl.txHashesFromBlock = hook
		return ethcl, block, captured
	}

	t.Run("nil hook derives tx hashes locally (default Ethereum path)", func(t *testing.T) {
		ethcl, block, captured := buildClient(nil)
		_, _, err := ethcl.FetchReceipts(ctx, block.Hash)
		require.NoError(t, err)
		require.Equal(t, eth.TransactionsToHashes(block.Transactions), *captured,
			"nil hook must feed locally-derived tx hashes to the receipts fetch")
	})

	t.Run("non-nil hook overrides the tx-hash source", func(t *testing.T) {
		want := []common.Hash{{0xab}}
		called := false
		ethcl, block, captured := buildClient(func(_ context.Context, _ common.Hash) ([]common.Hash, error) {
			called = true
			return want, nil
		})
		_, _, err := ethcl.FetchReceipts(ctx, block.Hash)
		require.NoError(t, err)
		require.True(t, called, "TxHashesFromBlock hook must be invoked")
		require.Equal(t, want, *captured, "hook's tx hashes must be used for the receipts fetch")
	})

	t.Run("non-nil hook error aborts the fetch", func(t *testing.T) {
		wantErr := errors.New("rsk: cannot map RSK tx hashes")
		ethcl, block, _ := buildClient(func(_ context.Context, _ common.Hash) ([]common.Hash, error) {
			return nil, wantErr
		})
		_, _, err := ethcl.FetchReceipts(ctx, block.Hash)
		require.ErrorIs(t, err, wantErr)
		require.Contains(t, err.Error(), "fetching tx hashes from L1 block")
	})
}

// TestRSK_RPCReceiptsFetcher_ReceiptsValidatorHook covers receipts_rpc.go:
// a nil ReceiptsValidator uses the default Ethereum validateReceipts, while a
// non-nil one fully replaces it and receives the block id, receipt-hash and
// tx hashes.
func TestRSK_RPCReceiptsFetcher_ReceiptsValidatorHook(t *testing.T) {
	ctx := context.Background()
	const numTxs = 1

	// buildClient wires an EthClient whose recProvider uses the given validator.
	buildClient := func(validator ReceiptsValidatorFn) (*EthClient, *RPCBlock) {
		m := new(mockRPC)
		block, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(420)), numTxs)
		m.On("CallContext", ctx, mock.Anything, "eth_getTransactionReceipt", mock.Anything).
			Return([]error{nil})
		m.On("CallContext", ctx, mock.Anything, "eth_getBlockByHash", mock.Anything).
			Run(func(args mock.Arguments) { *(args[1].(**RPCBlock)) = block }).
			Return([]error{nil})

		rp := NewRPCReceiptsFetcher(m, nil, RPCReceiptsConfig{ReceiptsValidator: validator})
		ethcl := newEthClientWithCaches(nil, numTxs)
		ethcl.client = m
		ethcl.recProvider = rp
		ethcl.trustRPC = true
		return ethcl, block
	}

	t.Run("nil validator uses the default Ethereum path", func(t *testing.T) {
		ethcl, block := buildClient(nil)
		_, _, err := ethcl.FetchReceipts(ctx, block.Hash)
		// The default validateReceipts runs and rejects the empty mock receipts.
		require.ErrorContains(t, err, "unexpected nil block number")
	})

	t.Run("non-nil validator replaces the default and receives block context", func(t *testing.T) {
		var gotReceiptHash common.Hash
		var gotBlock eth.BlockID
		gotTxHashes := -1
		validator := func(_ context.Context, block eth.BlockID, receiptHash common.Hash, txHashes []common.Hash, _ types.Receipts) error {
			gotBlock = block
			gotReceiptHash = receiptHash
			gotTxHashes = len(txHashes)
			return nil // accept: the default would have rejected the mock receipts
		}
		ethcl, block := buildClient(validator)

		_, _, err := ethcl.FetchReceipts(ctx, block.Hash)
		require.NoError(t, err, "custom validator accepted the receipts, bypassing the default")
		require.Equal(t, block.ReceiptHash, gotReceiptHash, "validator must receive the block's receipt-trie root")
		require.Equal(t, block.Hash, gotBlock.Hash, "validator must receive the block id")
		require.Equal(t, numTxs, gotTxHashes)
	})

	t.Run("non-nil validator error aborts the fetch", func(t *testing.T) {
		wantErr := errors.New("rsk: receipt trie root mismatch")
		validator := func(_ context.Context, _ eth.BlockID, _ common.Hash, _ []common.Hash, _ types.Receipts) error {
			return wantErr
		}
		ethcl, block := buildClient(validator)

		_, _, err := ethcl.FetchReceipts(ctx, block.Hash)
		require.ErrorIs(t, err, wantErr)
		require.NotContains(t, err.Error(), "unexpected nil block number")
	})
}

// rskEthClientConfig returns a copy of testEthClientConfig with the given
// TrustRPC value and BlockVerifier hook.
func rskEthClientConfig(trustRPC bool, hook BlockVerifierFn) *EthClientConfig {
	cfg := *testEthClientConfig
	cfg.TrustRPC = trustRPC
	cfg.BlockVerifier = hook
	return &cfg
}

// rskMockBlockRPC returns a mockRPC serving the given block for the fullTx
// eth_getBlockByHash / eth_getBlockByNumber calls, counting every hit so
// tests can assert whether a result was served from cache or re-fetched.
func rskMockBlockRPC(ctx context.Context, block *RPCBlock, rpcCalls *int) *mockRPC {
	m := new(mockRPC)
	serve := func(args mock.Arguments) {
		*rpcCalls++
		*(args[1].(**RPCBlock)) = block
	}
	m.On("CallContext", ctx, new(*RPCBlock),
		"eth_getBlockByHash", []any{block.Hash, true}).Run(serve).Return([]error{nil})
	m.On("CallContext", ctx, new(*RPCBlock),
		"eth_getBlockByNumber", []any{block.Number.String(), true}).Run(serve).Return([]error{nil})
	return m
}

// TestRSK_BlockVerifierRunsWithTrustRPC (PAYROLLUP-117 T1) pins the hybrid
// validation policy: an installed BlockVerifier hook must run on the blockCall
// and payloadCall paths even with TrustRPC=true. TrustRPC only disables the
// default Ethereum verification, never a non-Ethereum hook installed
// explicitly to replace it.
func TestRSK_BlockVerifierRunsWithTrustRPC(t *testing.T) {
	ctx := context.Background()

	t.Run("blockCall by hash", func(t *testing.T) {
		block, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(1)), 2)
		hookCalls := 0
		var gotTxs types.Transactions
		hook := func(_ context.Context, _ *types.Header, txs types.Transactions) error {
			hookCalls++
			gotTxs = txs
			return nil
		}
		s, err := NewEthClient(rskMockBlockRPC(ctx, block, new(int)), nil, nil, rskEthClientConfig(true, hook))
		require.NoError(t, err)

		_, txs, err := s.InfoAndTxsByHash(ctx, block.Hash)
		require.NoError(t, err)
		require.Len(t, txs, len(block.Transactions))
		require.Equal(t, 1, hookCalls, "BlockVerifier must run on blockCall despite TrustRPC=true")
		require.Len(t, gotTxs, len(block.Transactions), "hook must receive the block transactions")
	})

	t.Run("blockCall by number", func(t *testing.T) {
		block, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(2)), 2)
		hookCalls := 0
		hook := func(_ context.Context, _ *types.Header, _ types.Transactions) error {
			hookCalls++
			return nil
		}
		s, err := NewEthClient(rskMockBlockRPC(ctx, block, new(int)), nil, nil, rskEthClientConfig(true, hook))
		require.NoError(t, err)

		_, _, err = s.InfoAndTxsByNumber(ctx, uint64(block.Number))
		require.NoError(t, err)
		require.Equal(t, 1, hookCalls, "BlockVerifier must run on blockCall despite TrustRPC=true")
	})

	t.Run("payloadCall", func(t *testing.T) {
		block, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(3)), 2)
		hookCalls := 0
		hook := func(_ context.Context, _ *types.Header, _ types.Transactions) error {
			hookCalls++
			return nil
		}
		s, err := NewEthClient(rskMockBlockRPC(ctx, block, new(int)), nil, nil, rskEthClientConfig(true, hook))
		require.NoError(t, err)

		envelope, err := s.PayloadByHash(ctx, block.Hash)
		require.NoError(t, err)
		require.Equal(t, block.Hash, envelope.ExecutionPayload.BlockHash)
		require.Equal(t, 1, hookCalls, "BlockVerifier must run on payloadCall despite TrustRPC=true")
	})
}

// TestRSK_BlockVerifierMismatchHaltsWithTrustRPC (PAYROLLUP-117 T2) pins the
// mismatch behavior with TrustRPC=true: the hook's error (carrying both the
// header root and the computed root, as rsk/l1source VerifyRSKBlock produces)
// halts the call, keeps both roots in the message, and the failed result is
// never cached — a later call re-queries the RPC.
func TestRSK_BlockVerifierMismatchHaltsWithTrustRPC(t *testing.T) {
	ctx := context.Background()
	headerRoot := randHash()
	computedRoot := randHash()
	wantErr := fmt.Errorf("tx root mismatch: header %s, computed %s", headerRoot, computedRoot)

	t.Run("blockCall", func(t *testing.T) {
		block, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(4)), 2)
		hookCalls := 0
		hook := func(_ context.Context, _ *types.Header, _ types.Transactions) error {
			hookCalls++
			return wantErr
		}
		rpcCalls := 0
		s, err := NewEthClient(rskMockBlockRPC(ctx, block, &rpcCalls), nil, nil, rskEthClientConfig(true, hook))
		require.NoError(t, err)

		_, _, err = s.InfoAndTxsByHash(ctx, block.Hash)
		require.ErrorIs(t, err, wantErr, "mismatch must halt blockCall despite TrustRPC=true")
		require.ErrorContains(t, err, headerRoot.String(), "error must keep the header root")
		require.ErrorContains(t, err, computedRoot.String(), "error must keep the computed root")

		_, _, err = s.InfoAndTxsByHash(ctx, block.Hash)
		require.ErrorIs(t, err, wantErr)
		require.Equal(t, 2, rpcCalls, "failed result must not be cached: second call re-queries the RPC")
		require.Equal(t, 2, hookCalls)
	})

	t.Run("payloadCall", func(t *testing.T) {
		block, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(5)), 2)
		hookCalls := 0
		hook := func(_ context.Context, _ *types.Header, _ types.Transactions) error {
			hookCalls++
			return wantErr
		}
		rpcCalls := 0
		s, err := NewEthClient(rskMockBlockRPC(ctx, block, &rpcCalls), nil, nil, rskEthClientConfig(true, hook))
		require.NoError(t, err)

		_, err = s.PayloadByHash(ctx, block.Hash)
		require.ErrorIs(t, err, wantErr, "mismatch must halt payloadCall despite TrustRPC=true")
		require.ErrorContains(t, err, headerRoot.String(), "error must keep the header root")
		require.ErrorContains(t, err, computedRoot.String(), "error must keep the computed root")

		_, err = s.PayloadByHash(ctx, block.Hash)
		require.ErrorIs(t, err, wantErr)
		require.Equal(t, 2, rpcCalls, "failed result must not be cached: second call re-queries the RPC")
		require.Equal(t, 2, hookCalls)
	})
}

// TestRSK_NilBlockVerifierKeepsUpstreamSemantics (PAYROLLUP-117 T3,
// characterization) protects the upstream semantics the hybrid policy must
// not change: with TrustRPC=true and no hook installed, no verification runs
// at all — a block whose hash would fail the default Verify is accepted.
func TestRSK_NilBlockVerifierKeepsUpstreamSemantics(t *testing.T) {
	ctx := context.Background()

	t.Run("blockCall", func(t *testing.T) {
		good, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(6)), 2)
		bad := *good
		bad.Hash = rskTamperHash(bad.Hash) // default Verify would reject this block

		s, err := NewEthClient(rskMockBlockRPC(ctx, &bad, new(int)), nil, nil, rskEthClientConfig(true, nil))
		require.NoError(t, err)

		_, txs, err := s.InfoAndTxsByHash(ctx, bad.Hash)
		require.NoError(t, err, "TrustRPC=true with nil hook must skip all verification (upstream semantics)")
		require.Len(t, txs, len(bad.Transactions))
	})

	t.Run("payloadCall", func(t *testing.T) {
		good, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(7)), 2)
		bad := *good
		bad.Hash = rskTamperHash(bad.Hash)

		s, err := NewEthClient(rskMockBlockRPC(ctx, &bad, new(int)), nil, nil, rskEthClientConfig(true, nil))
		require.NoError(t, err)

		envelope, err := s.PayloadByHash(ctx, bad.Hash)
		require.NoError(t, err, "TrustRPC=true with nil hook must skip all verification (upstream semantics)")
		require.Equal(t, bad.Hash, envelope.ExecutionPayload.BlockHash)
	})
}

// TestRSK_HeaderVerifyEthereumFallbackRejectsRSKIP92Hash (PAYROLLUP-117 T6,
// characterization) pins the known limit of the hybrid policy: with
// TrustRPC=false and no HeaderVerifier installed, headerCall falls back to the
// default Ethereum hash recomputation (hdr.VerifyHash), which cannot match an
// RSKIP-92-style header hash. Running against RSK therefore requires
// TrustRPC=true; this test documents the boundary, it is not a bug to fix.
func TestRSK_HeaderVerifyEthereumFallbackRejectsRSKIP92Hash(t *testing.T) {
	ctx := context.Background()
	_, rhdr := randHeader()
	rskip92 := *rhdr
	// An RSKIP-92 hash is not the keccak of the geth-style header; a tampered
	// hash stands in for it.
	rskip92.Hash = rskTamperHash(rhdr.Hash)

	m := new(mockRPC)
	m.On("CallContext", ctx, new(*RPCHeader),
		"eth_getBlockByHash", []any{rskip92.Hash, false}).Run(func(args mock.Arguments) {
		*args[1].(**RPCHeader) = &rskip92
	}).Return([]error{nil})

	s, err := NewEthClient(m, nil, nil, rskEthClientConfig(false, nil))
	require.NoError(t, err)

	_, err = s.InfoByHash(ctx, rskip92.Hash)
	require.ErrorContains(t, err, "failed to verify block hash",
		"Ethereum VerifyHash fallback must reject an RSKIP-92-style header hash")
}
