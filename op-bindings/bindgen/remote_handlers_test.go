package main

import (
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/ethereum-optimism/optimism/op-bindings/etherscan"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/google/go-cmp/cmp"
)

var generator bindGenGeneratorRemote = bindGenGeneratorRemote{}

func configureGenerator() error {
	generator.contractDataClients.eth = etherscan.NewEthereumClient(os.Getenv("ETHERSCAN_APIKEY_ETH"))
	generator.contractDataClients.op = etherscan.NewOptimismClient(os.Getenv("ETHERSCAN_APIKEY_OP"))

	var err error
	if generator.rpcClients.eth, err = ethclient.Dial(os.Getenv("RPC_URL_ETH")); err != nil {
		return fmt.Errorf("error initializing Ethereum client: %w", err)
	}
	if generator.rpcClients.op, err = ethclient.Dial(os.Getenv("RPC_URL_OP")); err != nil {
		return fmt.Errorf("error initializing Optimism client: %w", err)
	}

	return nil
}

func TestFetchContractData(t *testing.T) {
	if err := configureGenerator(); err != nil {
		t.Error(err)
	}

	for _, tt := range fetchContractDataTests {
		t.Run(tt.name, func(t *testing.T) {
			contractData, err := generator.fetchContractData(tt.contractVerified, tt.chain, tt.deploymentAddress)
			if err != nil {
				t.Error(err)
			}
			if !reflect.DeepEqual(contractData, tt.expectedContractData) {
				t.Errorf("Retrieved contract data doens't match expected. Expected: %s Retrieved: %s", tt.expectedContractData, contractData)
			}
		})
	}
}

func TestFetchContractDataFailures(t *testing.T) {
	if err := configureGenerator(); err != nil {
		t.Error(err)
	}

	for _, tt := range fetchContractDataTestsFailures {
		t.Run(tt.name, func(t *testing.T) {
			_, err := generator.fetchContractData(tt.contractVerified, tt.chain, tt.deploymentAddress)
			if err == nil {
				t.Errorf("Expected error: %s but didn't receive it", tt.expectedError)
				return
			}

			if !strings.Contains(err.Error(), tt.expectedError) {
				t.Errorf("Expected error: %s Received: %s", tt.expectedError, err)
				return
			}
		})
	}
}

func TestRemoveDeploymentSalt(t *testing.T) {
	for _, tt := range removeDeploymentSaltTests {
		t.Run(tt.name, func(t *testing.T) {
			got, _ := generator.removeDeploymentSalt(tt.deploymentData, tt.deploymentSalt)
			if diff := cmp.Diff(tt.expected, got); diff != "" {
				t.Errorf("%s mismatch (-want +got):\n%s", tt.name, diff)
			}
		})
	}
}

func TestRemoveDeploymentSaltFailures(t *testing.T) {
	for _, tt := range removeDeploymentSaltTestsFailures {
		t.Run(tt.name, func(t *testing.T) {
			_, err := generator.removeDeploymentSalt(tt.deploymentData, tt.deploymentSalt)

			if err == nil {
				t.Errorf("Expected error: %s but didn't receive it", tt.expectedError)
				return
			}

			if !strings.Contains(err.Error(), tt.expectedError) {
				t.Errorf("Expected error: %s Received: %s", tt.expectedError, err)
				return
			}
		})
	}
}

func TestCompareBytecodeWithOp(t *testing.T) {
	if err := configureGenerator(); err != nil {
		t.Error(err)
	}

	for _, tt := range compareBytecodeWithOpTests {
		t.Run(tt.name, func(t *testing.T) {
			err := generator.compareBytecodeWithOp(&tt.contractMetadataEth, tt.compareInitialization, tt.compareDeployment)
			if err != nil {
				t.Error(err)
			}
		})
	}
}

func TestCompareBytecodeWithOpFailures(t *testing.T) {
	if err := configureGenerator(); err != nil {
		t.Error(err)
	}

	for _, tt := range compareBytecodeWithOpTestsFailures {
		t.Run(tt.name, func(t *testing.T) {
			err := generator.compareBytecodeWithOp(&tt.contractMetadataEth, tt.compareInitialization, tt.compareDeployment)
			if err == nil {
				t.Errorf("Expected error: %s but didn't receive it", tt.expectedError)
				return
			}

			if !strings.Contains(err.Error(), tt.expectedError) {
				t.Errorf("Expected error: %s Received: %s", tt.expectedError, err)
				return
			}
		})
	}
}

func TestCompareDeployedBytecodeWithRpc(t *testing.T) {
	if err := configureGenerator(); err != nil {
		t.Error(err)
	}

	for _, tt := range compareDeployedBytecodeWithRpcTests {
		t.Run(tt.name, func(t *testing.T) {
			err := generator.compareDeployedBytecodeWithRpc(&tt.contractMetadataEth, tt.chain)
			if err != nil {
				t.Error(err)
			}
		})
	}
}

func TestCompareDeployedBytecodeWithRpcFailures(t *testing.T) {
	if err := configureGenerator(); err != nil {
		t.Error(err)
	}

	for _, tt := range compareDeployedBytecodeWithRpcTestsFailures {
		t.Run(tt.name, func(t *testing.T) {
			err := generator.compareDeployedBytecodeWithRpc(&tt.contractMetadataEth, tt.chain)
			if err == nil {
				t.Errorf("Expected error: %s but didn't receive it", tt.expectedError)
				return
			}

			if !strings.Contains(err.Error(), tt.expectedError) {
				t.Errorf("Expected error: %s Received: %s", tt.expectedError, err)
				return
			}
		})
	}
}
