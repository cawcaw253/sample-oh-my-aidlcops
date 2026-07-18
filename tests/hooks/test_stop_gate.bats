#!/usr/bin/env bats
# tests/hooks/test_stop_gate.bats
#
# Behavioral tests for the plugin-bundled Stop / StopFailure phase-gate hook.
# The hook reads .omao/state/gates/<phase>.json verdicts (written by the
# quality-gates skill) and enforces them at turn-end.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HOOK="$REPO_ROOT/plugins/aidlc/hooks/stop-gate.sh"
    PROJECT="$(mktemp -d)"
    mkdir -p "$PROJECT/.omao/state/gates"
}

teardown() {
    rm -rf "$PROJECT"
}

_write_blocked_gate() {
    cat > "$PROJECT/.omao/state/gates/construction.json" <<'JSON'
{
  "phase": "construction",
  "status": "blocked",
  "blockers": ["risk-discovery category 2 (Security) BLOCK: plaintext secret in configmap"],
  "next_phase_allowed": false
}
JSON
}

_write_passed_gate() {
    cat > "$PROJECT/.omao/state/gates/inception.json" <<'JSON'
{ "phase": "inception", "status": "passed", "next_phase_allowed": true, "blockers": [] }
JSON
}

@test "Stop + blocked gate: blocks the turn (default block mode)" {
    _write_blocked_gate
    run env CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"Stop"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.decision == "block"' >/dev/null
    echo "$output" | jq -e '.reason | contains("construction")' >/dev/null
}

@test "Stop + blocked gate + OMA_GATE_MODE=warn: warns, does not block" {
    _write_blocked_gate
    run env CLAUDE_PROJECT_DIR="$PROJECT" OMA_GATE_MODE=warn bash "$HOOK" <<<'{"hook_event_name":"Stop"}'
    [ "$status" -eq 0 ]
    # jq -e exits non-zero on false, so the combined predicate covers both:
    # no decision key AND a systemMessage mentioning the block.
    echo "$output" | jq -e 'has("decision") | not' >/dev/null
    echo "$output" | jq -e '.systemMessage | contains("blocked")' >/dev/null
}

@test "StopFailure + blocked gate: never blocks, reminder only" {
    _write_blocked_gate
    run env CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"StopFailure"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'has("decision") | not' >/dev/null
    echo "$output" | jq -e '.systemMessage | contains("failed")' >/dev/null
}

@test "Stop + only passed gates: allows the turn" {
    _write_passed_gate
    run env CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"Stop"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'has("decision") | not' >/dev/null
}

@test "reentry guard: stop_hook_active=true passes through even when blocked" {
    _write_blocked_gate
    run env CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"Stop","stop_hook_active":true}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'has("decision") | not' >/dev/null
}

@test "OMA_DISABLE_GATES=1 passes through even when blocked" {
    _write_blocked_gate
    run env CLAUDE_PROJECT_DIR="$PROJECT" OMA_DISABLE_GATES=1 bash "$HOOK" <<<'{"hook_event_name":"Stop"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'has("decision") | not' >/dev/null
}

@test "next_phase_allowed=false alone (status omitted) blocks" {
    cat > "$PROJECT/.omao/state/gates/construction.json" <<'JSON'
{ "phase": "construction", "next_phase_allowed": false, "blockers": [] }
JSON
    run env CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"Stop"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.decision == "block"' >/dev/null
    # Empty blockers array degrades to a generic "gate blocked" message.
    echo "$output" | jq -e '.reason | contains("gate blocked")' >/dev/null
}

@test "no gates directory: hook passes through" {
    rm -rf "$PROJECT/.omao/state/gates"
    run env CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"Stop"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'has("decision") | not' >/dev/null
}

@test "crafted blocker text does not break JSON (injection safety)" {
    cat > "$PROJECT/.omao/state/gates/construction.json" <<'JSON'
{ "phase": "construction", "status": "blocked", "blockers": ["evil \"quote\" and\nnewline"], "next_phase_allowed": false }
JSON
    run env CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<'{"hook_event_name":"Stop"}'
    [ "$status" -eq 0 ]
    # Output must remain valid JSON with a single decision key.
    echo "$output" | jq -e '.decision == "block"' >/dev/null
}
