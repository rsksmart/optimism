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
	"math/big"
	"math/rand"
	"testing"

	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	optypes "github.com/ethereum-optimism/optimism/op-core/types"
	"github.com/ethereum-optimism/optimism/op-service/bigs"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/sources/caching"
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
// (RawTransactions.Hashes); when set, the hook fully replaces that source, and
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
		require.Equal(t, block.Transactions.Hashes(), *captured,
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

	t.Run("[null] receipt is rejected before the validator", func(t *testing.T) {
		// eth_getBlockReceipts (RPCKindStandard) can return a null element, which
		// the conversion handed to the hook would dereference.
		m := new(mockRPC)
		block, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(420)), numTxs)
		m.On("CallContext", ctx, mock.Anything, "eth_getBlockReceipts", mock.Anything).
			Run(func(args mock.Arguments) { *(args[1].(*optypes.Receipts)) = optypes.Receipts{nil} }).
			Return([]error{nil})
		called := false
		rp := NewRPCReceiptsFetcher(m, nil, RPCReceiptsConfig{
			ProviderKind: RPCKindStandard,
			ReceiptsValidator: func(context.Context, eth.BlockID, common.Hash, []common.Hash, types.Receipts) error {
				called = true
				return nil
			},
		})
		info := eth.HeaderBlockInfoTrusted(block.Hash, block.CreateGethHeader())

		_, err := rp.FetchReceipts(ctx, info, block.Transactions.Hashes())
		require.ErrorContains(t, err, "receipt of tx 0 returns nil on retrieval")
		require.False(t, called, "the validator must not see a null receipt")
	})
}

// TestRSK_EthClient_ByNumberAndLabelKeepRPCHash covers the by-number and
// by-label accessors of eth_client.go: each must report the block hash the RPC
// returned (eth.HeaderBlockInfoTrusted), not re-keccak the go-ethereum header
// (eth.HeaderBlockInfo). On Ethereum the two are equal, so upstream tests can't
// tell them apart; on RSK (RSKIP-92) they differ and the recomputed one is
// wrong.
func TestRSK_EthClient_ByNumberAndLabelKeepRPCHash(t *testing.T) {
	ctx := context.Background()

	// rskBlock returns a block whose RPC hash differs from its header's keccak,
	// as an RSK block's does. With deposit set, its first tx is a deposit.
	rskBlock := func(t *testing.T, deposit bool) *RPCBlock {
		block, _ := randomRpcBlockAndReceipts(rand.New(rand.NewSource(9)), 1)
		if deposit {
			raw, err := (&optypes.DepositTx{Value: new(big.Int), Gas: 21_000}).MarshalBinary()
			require.NoError(t, err)
			block.Transactions = append(RawTransactions{raw}, block.Transactions...)
		}
		block.Hash = rskTamperHash(block.Hash)
		require.NotEqual(t, block.CreateGethHeader().Hash(), block.Hash)
		return block
	}

	// rskClient serves block for every eth_getBlockByNumber call, behind
	// verifier hooks that accept it as RSK's do (the defaults would reject the
	// hash).
	rskClient := func(block *RPCBlock) *EthClient {
		m := new(mockRPC)
		m.On("CallContext", ctx, mock.Anything, "eth_getBlockByNumber", mock.Anything).
			Run(func(args mock.Arguments) {
				switch out := args[1].(type) {
				case **RPCHeader:
					*out = &block.RPCHeader
				case **RPCBlock:
					*out = block
				}
			}).
			Return([]error{nil})
		ethcl := newEthClientWithCaches(nil, 1)
		ethcl.blockRefsCache = caching.NewLRUCache[common.Hash, eth.BlockRef](nil, "blockrefs", 1)
		ethcl.client = m
		ethcl.headerVerifier = func(context.Context, *types.Header) error { return nil }
		ethcl.blockVerifier = func(context.Context, *types.Header, types.Transactions) error { return nil }
		return ethcl
	}

	infoHash := func(info eth.BlockInfo, err error) (common.Hash, error) {
		if err != nil {
			return common.Hash{}, err
		}
		return info.Hash(), nil
	}

	tests := []struct {
		name    string
		deposit bool
		hash    func(s *EthClient, num uint64) (common.Hash, error)
	}{
		{name: "InfoByNumber", hash: func(s *EthClient, num uint64) (common.Hash, error) {
			return infoHash(s.InfoByNumber(ctx, num))
		}},
		{name: "InfoByLabel", hash: func(s *EthClient, _ uint64) (common.Hash, error) {
			return infoHash(s.InfoByLabel(ctx, eth.Unsafe))
		}},
		{name: "InfoAndTxsByNumber", hash: func(s *EthClient, num uint64) (common.Hash, error) {
			info, _, err := s.InfoAndTxsByNumber(ctx, num)
			return infoHash(info, err)
		}},
		{name: "InfoAndTxsByLabel", hash: func(s *EthClient, _ uint64) (common.Hash, error) {
			info, _, err := s.InfoAndTxsByLabel(ctx, eth.Unsafe)
			return infoHash(info, err)
		}},
		{name: "InfoAndUserTxsByNumber", hash: func(s *EthClient, num uint64) (common.Hash, error) {
			info, _, err := s.InfoAndUserTxsByNumber(ctx, num)
			return infoHash(info, err)
		}},
		{name: "InfoAndDepositsByNumber", deposit: true, hash: func(s *EthClient, num uint64) (common.Hash, error) {
			info, _, err := s.InfoAndDepositsByNumber(ctx, num)
			return infoHash(info, err)
		}},
		{name: "InfoAndFirstDepositByNumber", deposit: true, hash: func(s *EthClient, num uint64) (common.Hash, error) {
			info, _, err := s.InfoAndFirstDepositByNumber(ctx, num)
			return infoHash(info, err)
		}},
		{name: "BlockRefByNumber", hash: func(s *EthClient, num uint64) (common.Hash, error) {
			ref, err := s.BlockRefByNumber(ctx, num)
			return ref.Hash, err
		}},
		{name: "BlockRefByLabel", hash: func(s *EthClient, _ uint64) (common.Hash, error) {
			ref, err := s.BlockRefByLabel(ctx, eth.Unsafe)
			return ref.Hash, err
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			block := rskBlock(t, tt.deposit)
			got, err := tt.hash(rskClient(block), uint64(block.Number))
			require.NoError(t, err)
			require.Equal(t, block.Hash, got, "must keep the RPC-reported hash, not recompute it from the header")
		})
	}
}
