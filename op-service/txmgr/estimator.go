package txmgr

import (
	"context"
	"errors"
	"math/big"
)

type GasPriceEstimatorFn func(ctx context.Context, backend ETHBackend) (*big.Int, *big.Int, *big.Int, error)

// gasPriceSuggester is an optional interface that backends may implement to
// provide legacy (pre-EIP-1559) gas price estimation via eth_gasPrice.
// go-ethereum's ethclient.Client implements this.
type gasPriceSuggester interface {
	SuggestGasPrice(ctx context.Context) (*big.Int, error)
}

func DefaultGasPriceEstimatorFn(ctx context.Context, backend ETHBackend) (*big.Int, *big.Int, *big.Int, error) {
	tip, tipErr := backend.SuggestGasTipCap(ctx)

	head, err := backend.HeaderByNumber(ctx, nil)
	if err != nil {
		return nil, nil, nil, err
	}

	// EIP-1559 chain: use baseFee from header + tip.
	if head.BaseFee != nil && tipErr == nil {
		// BlobBaseFee is best-effort: chains without EIP-4844 (e.g. RSK)
		// don't support eth_blobBaseFee. A nil value here is fine — callers
		// that need blobs will fail later with an explicit error, while
		// calldata-only senders are unaffected.
		blobBaseFee, _ := backend.BlobBaseFee(ctx)
		return tip, head.BaseFee, blobBaseFee, nil
	}

	// Pre-EIP-1559 chain (e.g. RSK): fall back to eth_gasPrice.
	// Return gasPrice as baseFee with tip=0. calcGasFeeCap will compute
	// gasFeeCap = 0 + 2*gasPrice, providing a 2x buffer against price
	// fluctuations — the same margin EIP-1559 estimation uses for baseFee.
	if gps, ok := backend.(gasPriceSuggester); ok {
		gasPrice, err := gps.SuggestGasPrice(ctx)
		if err != nil {
			return nil, nil, nil, err
		}
		return new(big.Int), gasPrice, nil, nil
	}

	// Neither EIP-1559 nor eth_gasPrice available.
	if tipErr != nil {
		return nil, nil, nil, tipErr
	}
	return nil, nil, nil, errors.New("cannot estimate gas: neither EIP-1559 baseFee nor eth_gasPrice available")
}
