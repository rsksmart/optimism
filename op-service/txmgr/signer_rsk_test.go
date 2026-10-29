package txmgr_test

import (
	"context"
	"errors"
	"math/big"
	"net/http/httptest"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rpc"
	"github.com/stretchr/testify/require"

	opcrypto "github.com/ethereum-optimism/optimism/op-service/crypto"
	"github.com/ethereum-optimism/optimism/op-service/log"
	"github.com/ethereum-optimism/optimism/op-service/testlog"
	"github.com/ethereum-optimism/optimism/op-service/txmgr"
)

const rskTestChainID = 33

type rskChainIDAPI struct{}

func (rskChainIDAPI) ChainId() *hexutil.Big { return (*hexutil.Big)(big.NewInt(rskTestChainID)) }

func rskL1RPC(t *testing.T) string {
	t.Helper()
	srv := rpc.NewServer()
	require.NoError(t, srv.RegisterName("eth", rskChainIDAPI{}))
	httpSrv := httptest.NewServer(srv)
	t.Cleanup(func() {
		httpSrv.Close()
		srv.Stop()
	})
	return httpSrv.URL
}

func rskCLIConfig(t *testing.T) txmgr.CLIConfig {
	t.Helper()
	return txmgr.NewCLIConfig(rskL1RPC(t), txmgr.DefaultBatcherFlagValues)
}

func TestRSK_NewConfig_SignerFactoryFnReplacesStockSigners(t *testing.T) {
	from := common.HexToAddress("0x00000000000000000000000000000000000000a1")
	var calls int
	var boundChainID *big.Int
	var signedFor common.Address
	cfg := rskCLIConfig(t)
	cfg.SignerFactoryFn = func() (opcrypto.SignerFactory, common.Address, error) {
		calls++
		factory := func(chainID *big.Int) opcrypto.SignerFn {
			boundChainID = chainID
			return func(_ context.Context, addr common.Address, tx *types.Transaction) (*types.Transaction, error) {
				signedFor = addr
				return tx, nil
			}
		}
		return factory, from, nil
	}

	conf, err := txmgr.NewConfig(cfg, testlog.Logger(t, log.LevelCrit))
	require.NoError(t, err)
	t.Cleanup(conf.Backend.Close)

	require.Equal(t, 1, calls)
	require.Equal(t, from, conf.From)
	require.Equal(t, big.NewInt(rskTestChainID), boundChainID, "the factory is bound to the L1 chain ID")
	_, err = conf.Signer(context.Background(), from, types.NewTx(&types.LegacyTx{}))
	require.NoError(t, err)
	require.Equal(t, from, signedFor)
}

func TestRSK_NewConfig_SignerFactoryFnErrorFailsConfig(t *testing.T) {
	hookErr := errors.New("kms unavailable")
	cfg := rskCLIConfig(t)
	cfg.SignerFactoryFn = func() (opcrypto.SignerFactory, common.Address, error) {
		return nil, common.Address{}, hookErr
	}

	_, err := txmgr.NewConfig(cfg, testlog.Logger(t, log.LevelCrit))
	require.ErrorIs(t, err, hookErr)
}

func TestRSK_NewConfig_SignerFactoryFnNilFactoryFailsConfig(t *testing.T) {
	cfg := rskCLIConfig(t)
	cfg.SignerFactoryFn = func() (opcrypto.SignerFactory, common.Address, error) {
		return nil, common.HexToAddress("0x00000000000000000000000000000000000000a1"), nil
	}

	_, err := txmgr.NewConfig(cfg, testlog.Logger(t, log.LevelCrit))
	require.ErrorContains(t, err, "SignerFactoryFn returned a nil signer factory")
}

func TestRSK_NewConfig_SignerFactoryFnZeroAddressFailsConfig(t *testing.T) {
	cfg := rskCLIConfig(t)
	cfg.SignerFactoryFn = func() (opcrypto.SignerFactory, common.Address, error) {
		factory := func(*big.Int) opcrypto.SignerFn {
			return func(_ context.Context, _ common.Address, tx *types.Transaction) (*types.Transaction, error) {
				return tx, nil
			}
		}
		return factory, common.Address{}, nil
	}

	_, err := txmgr.NewConfig(cfg, testlog.Logger(t, log.LevelCrit))
	require.ErrorContains(t, err, "SignerFactoryFn returned the zero address")
}

func TestRSK_NewConfig_NilSignerFactoryFnKeepsStockSigner(t *testing.T) {
	key, err := crypto.GenerateKey()
	require.NoError(t, err)
	cfg := rskCLIConfig(t)
	cfg.PrivateKey = hexutil.Encode(crypto.FromECDSA(key))

	conf, err := txmgr.NewConfig(cfg, testlog.Logger(t, log.LevelCrit))
	require.NoError(t, err)
	t.Cleanup(conf.Backend.Close)

	require.Equal(t, crypto.PubkeyToAddress(key.PublicKey), conf.From)
}

func TestRSK_Check_SignerFactoryFnIsExclusive(t *testing.T) {
	hook := func() (opcrypto.SignerFactory, common.Address, error) { return nil, common.Address{}, nil }
	for _, tt := range []struct {
		name  string
		set   func(*txmgr.CLIConfig)
		valid bool
	}{
		{name: "hook alone", set: func(*txmgr.CLIConfig) {}, valid: true},
		{name: "with private key", set: func(c *txmgr.CLIConfig) { c.PrivateKey = "0x01" }},
		{name: "with mnemonic", set: func(c *txmgr.CLIConfig) { c.Mnemonic = "test test test" }},
		{name: "with remote signer", set: func(c *txmgr.CLIConfig) {
			c.SignerCLIConfig.Endpoint = "http://signer:8080"
			c.SignerCLIConfig.Address = "0x00000000000000000000000000000000000000a1"
		}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			cfg := txmgr.NewCLIConfig("http://l1:8545", txmgr.DefaultBatcherFlagValues)
			cfg.SignerFactoryFn = hook
			tt.set(&cfg)
			err := cfg.Check()
			if tt.valid {
				require.NoError(t, err)
				return
			}
			require.ErrorContains(t, err, "signer factory")
		})
	}
}
