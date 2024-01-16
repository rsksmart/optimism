package rsk_types

import (
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"math/big"
)

// TODO(rootstock) remove this file if  finally not needed, leaving it as an example

type L1Block interface {
	Number() *big.Int
	NumberU64() uint64
	Hash() common.Hash
	Time() uint64
	BaseFee() *big.Int
}

type RskHeader struct {
	Difficulty       *hexutil.Big   `json:"difficulty"`
	Number           *hexutil.Big   `json:"number"`
	GasLimit         hexutil.Uint64 `json:"gasLimit"`
	GasUsed          hexutil.Uint64 `json:"gasUsed"`
	Timestamp        hexutil.Uint64 `json:"timestamp"`
	ExtraData        hexutil.Bytes  `json:"extraData"`
	MinimumGasPrice  *hexutil.Big   `json:"minimumGasPrice"`
	Hash             common.Hash    `json:"hash"`
	ParentHash       common.Hash    `json:"parentHash"`
	UncleHash        common.Hash    `json:"sha3Uncles"`
	StateRoot        common.Hash    `json:"stateRoot"`
	TransactionsRoot common.Hash    `json:"transactionsRoot"`
	ReceiptsRoot     common.Hash    `json:"receiptsRoot"`
	Bloom            types.Bloom    `json:"logsBloom" `
	// TODO(iago) add more fields when needed
}

type RskBlock struct {
	header *RskHeader
	// TODO(iago) add more fields when needed
}

func NewBlock(header *RskHeader) *RskBlock {
	return &RskBlock{header: header}
}

func (b *RskBlock) Hash() common.Hash { return b.header.Hash }

// TODO(iago) it would be better to do these type conversions on instantiation
func (b *RskBlock) Number() *big.Int         { return new(big.Int).Set(b.header.Number.ToInt()) }
func (b *RskBlock) GasLimit() uint64         { return uint64(b.header.GasLimit) }
func (b *RskBlock) GasUsed() uint64          { return uint64(b.header.GasUsed) }
func (b *RskBlock) Difficulty() *big.Int     { return b.header.Difficulty.ToInt() }
func (b *RskBlock) Time() uint64             { return uint64(b.header.Timestamp) }
func (b *RskBlock) NumberU64() uint64        { return b.header.Number.ToInt().Uint64() }
func (b *RskBlock) Bloom() types.Bloom       { return b.header.Bloom }
func (b *RskBlock) Root() common.Hash        { return b.header.StateRoot }
func (b *RskBlock) ParentHash() common.Hash  { return b.header.ParentHash }
func (b *RskBlock) TxHash() common.Hash      { return b.header.TransactionsRoot }
func (b *RskBlock) ReceiptHash() common.Hash { return b.header.ReceiptsRoot }
func (b *RskBlock) UncleHash() common.Hash   { return b.header.UncleHash }
func (b *RskBlock) Extra() []byte            { return common.CopyBytes(b.header.ExtraData) }
func (b *RskBlock) BaseFee() *big.Int {
	// we map BaseFee to Rootstock's MinimumGasPrice
	// TODO(iago) re-confirm with CORE/Research that this is a good approach
	if b.header.MinimumGasPrice == nil {
		return nil
	}
	return b.header.MinimumGasPrice.ToInt()
}
