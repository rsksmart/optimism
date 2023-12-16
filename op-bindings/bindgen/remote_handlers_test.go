package main

import (
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"
)

func TestRemoveDeploymentSalt(t *testing.T) {
	generator := bindGenGeneratorRemote{}

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
	generator := bindGenGeneratorRemote{}

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
