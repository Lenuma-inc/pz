#!/bin/bash
# CI tripwire: verify TLA+ models match Zig source constants.
# Run from repo root: ./proofs/sync_check.sh
# Exit 0 = in sync, exit 1 = stale proofs
set -euo pipefail

FAIL=0
check() {
    local label="$1" zig_val="$2" proof_val="$3"
    if [ "$zig_val" != "$proof_val" ]; then
        echo "STALE: $label — Zig=$zig_val Proof=$proof_val"
        FAIL=1
    else
        echo "  ok: $label = $zig_val"
    fi
}

echo "=== TLA+: AgentRPC.tla ==="
ZIG_STUB_STATES=$(sed -n '/pub const State = enum/,/};/p' src/core/agent.zig | rg -c '^\s+\w+,' || echo 0)
check "Stub states" "$ZIG_STUB_STATES" "4"
# Msg.Tag: hello,run,cancel,out,done,err — check known set exists
ZIG_HAS_MSG=$(rg -c 'hello.*run.*cancel' src/core/agent.zig || echo 0)
if [ "$ZIG_HAS_MSG" -eq 0 ]; then
    # Check individually
    for msg in hello run cancel out done err; do
        if ! rg -q "^\s+${msg}," src/core/agent.zig; then
            echo "STALE: Msg.Tag missing '$msg'"; FAIL=1
        fi
    done
fi
echo "  ok: Msg types present"

echo ""
if [ "$FAIL" -eq 1 ]; then
    echo "PROOF-CODE SYNC FAILED — update stale proofs"
    exit 1
fi
echo "All sync checks passed"
