package rsk_api

import (
	"context"
	"github.com/ethereum-optimism/optimism/op-rsk/rsk-types"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/log"
	"github.com/ethereum/go-ethereum/rpc"
)

// TODO(iago) Reminder for January :D
// I was running the setup step:
//
//	go run cmd/main.go genesis l2 \
//		--deploy-config ../packages/contracts-bedrock/deploy-config/getting-started.json \
//		--deployment-dir ../packages/contracts-bedrock/deployments/getting-started/ \
//		--outfile.l2 genesis.json \
//		--outfile.rollup rollup.json \
//		--l1-rpc $L1_RPC_URL
//
// Plan:
//
//	1- be able to map from the rpc request to a RskBlock
//	2- create the L1Block interface that holds all types.Block methods, even if returning empty for now (types.Block access is through methods, which is good for our interface usage)
//	3- try to use L1Block directly in cmd.go
//	4- I could not use it, not directly, the dependant classes need types.Block, which is implementing L1Block now but this does not work in Golang
//	5- I need to change the dependant methods to receive L1Block instead of types.Block where possible and, where not, try to generate a types.Block from RskBlock
//	6- TBD in January :)
func GetBlockByHash(l1RPC string, blockHash common.Hash) (rsk_types.L1Block, error) {
	client, err := rpc.Dial(l1RPC) // TODO(iago) properly configure a client
	if err != nil {
		log.Error("Could not start client", err)
		return nil, err
	}

	// Call eth_getBlockByHash RPC method
	var header rsk_types.RskHeader
	err = client.CallContext(context.Background(), &header, "eth_getBlockByHash", blockHash, true)
	if err != nil {
		log.Error("Could not use client", err)
		return nil, err
	}

	return rsk_types.NewBlock(&header), nil
}
