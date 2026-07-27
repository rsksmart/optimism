package forge_test

// RSK fork coverage for forge.Client.ExtraScriptOpts (client.go).
//
// The fork appends ExtraScriptOpts to every `forge script` invocation, after
// the caller-supplied opts and before the trailing `--sig`/script/arg, so RSK
// (pre-EIP-1559 L1) can inject `--legacy` without every Deploy*ViaForge callsite
// learning a new field. Upstream never sets ExtraScriptOpts, so this ordering
// has no upstream coverage.
//
// The test replaces the forge binary with a tiny shell script that echoes its
// argv, using the existing StaticBinary seam — no real forge needed. See
// AGENTS_rsk.md for the _rsk_test.go / TestRSK_ convention.

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-deployer/pkg/deployer/forge"
)

// rskArgEchoClient returns a forge.Client whose binary is a shell script that
// prints each received argument on its own line, so RunScript's captured
// output is exactly the argv passed to `forge`.
//
// Client.execCmd has no arg-capture seam, so a real subprocess is unavoidable.
// This couples the test to a Unix /bin/sh and an executable t.TempDir() — fine
// on the repo's Linux/macOS CI, but it would fail on a noexec temp mount or a
// non-Unix runner.
func rskArgEchoClient(t *testing.T) *forge.Client {
	t.Helper()
	scriptPath := filepath.Join(t.TempDir(), "fake-forge.sh")
	// `for a in "$@"` preserves argument boundaries; each arg is echoed verbatim.
	const body = "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n"
	require.NoError(t, os.WriteFile(scriptPath, []byte(body), 0o755))

	cl := forge.NewClient(forge.StaticBinary(scriptPath))
	cl.Stdout = io.Discard // RunScript captures argv via its own buffer
	cl.Stderr = io.Discard
	return cl
}

// TestRSK_Client_RunScript_AppendsExtraScriptOpts asserts ExtraScriptOpts land
// after the caller opts and before the trailing --sig/script/arg.
func TestRSK_Client_RunScript_AppendsExtraScriptOpts(t *testing.T) {
	cl := rskArgEchoClient(t)
	cl.ExtraScriptOpts = []string{"--legacy", "--slow"}

	out, err := cl.RunScript(context.Background(),
		"script/Foo.s.sol:Foo", "run()", []byte{0xab, 0xcd}, "--broadcast")
	require.NoError(t, err)

	got := strings.Split(strings.TrimSpace(out), "\n")
	require.Equal(t, []string{
		"script",
		"--broadcast",        // caller-supplied opt
		"--legacy", "--slow", // RSK ExtraScriptOpts, in order, right after opts
		"--sig", "run()",
		"script/Foo.s.sol:Foo",
		"0xabcd",
	}, got)
}

// TestRSK_Client_RunScript_NoExtraScriptOpts is the control: with no
// ExtraScriptOpts, the argv matches upstream exactly (no injected flags).
func TestRSK_Client_RunScript_NoExtraScriptOpts(t *testing.T) {
	cl := rskArgEchoClient(t) // ExtraScriptOpts nil

	out, err := cl.RunScript(context.Background(),
		"script/Foo.s.sol:Foo", "run()", []byte{0xab, 0xcd}, "--broadcast")
	require.NoError(t, err)

	got := strings.Split(strings.TrimSpace(out), "\n")
	require.Equal(t, []string{
		"script",
		"--broadcast",
		"--sig", "run()",
		"script/Foo.s.sol:Foo",
		"0xabcd",
	}, got)
	require.NotContains(t, got, "--legacy")
}
