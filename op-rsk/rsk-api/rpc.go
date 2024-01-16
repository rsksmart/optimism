package rsk_api

import (
	"context"
	"github.com/ethereum-optimism/optimism/op-rsk/rsk-types"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/log"
	"github.com/ethereum/go-ethereum/rpc"
)

// Client defines typed wrappers for those Rootstock RPC API specific or differing methods.
type Client struct {
	c *rpc.Client
}

// Dial connects a client to the given URL.
func Dial(rawurl string) (*Client, error) {
	client, err := rpc.Dial(rawurl)
	if err != nil {
		log.Error("Could not start client", err)
		return nil, err
	}

	return &Client{c: client}, nil
}

// TODO(rootstock) remove if finally not needed, leaving it as an example
func (ec *Client) GetBlockByHash(blockHash common.Hash) (rsk_types.L1Block, error) {
	var header rsk_types.RskHeader
	err := ec.c.CallContext(context.Background(), &header, "eth_getBlockByHash", blockHash, true)
	if err != nil {
		log.Error("Error on eth_getBlockByHash", err)
		return nil, err
	}
	return rsk_types.NewBlock(&header), nil
}
