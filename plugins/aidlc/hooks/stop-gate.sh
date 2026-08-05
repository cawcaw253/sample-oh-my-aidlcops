#!/usr/bin/env bash
# stop-gate.sh — plugin-bundled Stop / StopFailure hook (harness safety axis).
#
# Enforces AIDLC phase gates at turn-end. The quality-gates skill writes a
# verdict per phase to .omao/state/gates/<phase>.json:
#
#   { "phase": "...", "status": "passed|blocked", "next_phase_allowed": bool,
#     "blockers": [...], "waiver_ref": null|"..." }
#
# This hook is the ENFORCEMENT half: it does not re-derive the verdict (the
# skill already reconciles waivers/TTL), it only trusts the recorded verdict.
# If any gate is blocked (status=blocked OR next_phase_allowed=false) it stops
# Claude from ending the turn, so a gate cannot be silently skipped by the same
# agent that authored the work — the self-grading failure mode OMA targets.
#
# EVENTS (one script, two events; distinguished by stdin hook_event_name):
#   Stop         — a completed turn. In block mode a blocked gate returns
#                  {"decision":"block", ...} so the turn is not allowed to end.
#   StopFailure  — a failed turn. NEVER blocks (that would trap a failing
#                  session in a loop). Surfaces a systemMessage reminder only.
#
# SELF-CONTAINED BY DESIGN (same contract as session-start-ontology.sh): reads
# ONLY the project's .omao/state/gates/ and has NO repo-root dependency, so it
# works verbatim from an installed plugin copy.
#
# REENTRY GUARD: Claude Code sets stdin.stop_hook_active=true when it re-runs
# the Stop hook after a prior block. If we blocked again we would deadlock the
# session, so we pass through immediately in that case.
#
# CONTROLS:
#   OMA_DISABLE_GATES=1   kill switch — always pass through (no-op).
#   OMA_GATE_MODE=warn    downgrade block -> non-blocking systemMessage.
#                         Default (unset/anything else) is block.
#
# Emitted into hooks/hooks.json (Stop / StopFailure) by oma-compile from the
# DSL `hooks.stop` / `hooks.stop-failure` declarations. Do not hand-edit those
# hooks.json entries; edit the DSL and recompile.

set -euo pipefail

# A real JSON encoder is REQUIRED: gate files are user-editable and may contain
# quotes/newlines that naive shell interpolation would turn into key injection.
_emit_pass() {
  # An empty, valid payload the harness reads as a no-op (do not block).
  printf '{}\n'
  exit 0
}

_emit_json() {
  # $1 = event name, $2 = mode ("block"|"warn"), $3 = reason/message text.
  local event="$1" mode="$2" text="$3"
  if command -v jq >/dev/null 2>&1; then
    if [[ "$mode" == "block" ]]; then
      jq -n --arg reason "$text" '{decision: "block", reason: $reason}'
    else
      jq -n --arg msg "$text" '{systemMessage: $msg}'
    fi
  elif command -v python3 >/dev/null 2>&1; then
    OMA_TEXT="$text" OMA_MODE="$mode" python3 -c '
import json, os, sys
text = os.environ["OMA_TEXT"]
if os.environ["OMA_MODE"] == "block":
    out = {"decision": "block", "reason": text}
else:
    out = {"systemMessage": text}
sys.stdout.write(json.dumps(out)); sys.stdout.write("\n")
'
  else
    echo "stop-gate.sh: neither jq nor python3 available; refusing to emit unsafe JSON" >&2
    exit 1
  fi
  exit 0
}

# Kill switch.
if [[ "${OMA_DISABLE_GATES:-0}" == "1" ]]; then
  _emit_pass
fi

# Read the event payload once from stdin.
INPUT="$(cat 2>/dev/null || true)"

# Determine the event and the reentry flag. Fall back gracefully when jq is
# absent (grep the raw JSON) so the reentry guard never fails open into a loop.
EVENT=""
STOP_ACTIVE="false"
if command -v jq >/dev/null 2>&1 && [[ -n "$INPUT" ]]; then
  EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")"
  STOP_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")"
else
  # Best-effort textual detection without jq.
  case "$INPUT" in
    *'"stop_hook_active"'*'true'*) STOP_ACTIVE="true" ;;
  esac
  case "$INPUT" in
    *'"hook_event_name"'*StopFailure*) EVENT="StopFailure" ;;
    *'"hook_event_name"'*Stop*)        EVENT="Stop" ;;
  esac
fi

# Reentry guard: never block a turn that is already re-running after a block.
if [[ "$STOP_ACTIVE" == "true" ]]; then
  _emit_pass
fi

# Resolve the project directory. Claude Code passes CLAUDE_PROJECT_DIR to hooks
# (the cwd at `claude` startup); fall back to $PWD for other harnesses.
OMA_PROJ_DIR="${CLAUDE_PROJECT_DIR:-${OMA_PROJECT_DIR:-$PWD}}"
GATES_DIR="$OMA_PROJ_DIR/.omao/state/gates"

# No gate directory → nothing to enforce.
if [[ ! -d "$GATES_DIR" ]]; then
  _emit_pass
fi

# Collect blocked gates. A gate is blocked when status=blocked OR
# next_phase_allowed=false. We need jq for a trustworthy read; without it we
# cannot safely parse user JSON, so we pass through (the PreToolUse enforcer
# remains the hard backstop; this hook is a turn-end gate check).
if ! command -v jq >/dev/null 2>&1; then
  _emit_pass
fi

BLOCKED_LINES=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  line="$(jq -r '
    select(.status == "blocked" or .next_phase_allowed == false)
    | "\(.phase // "?"): \((.blockers // []) | if length == 0 then "gate blocked" else join("; ") end)"
  ' "$f" 2>/dev/null || true)"
  [[ -n "$line" ]] && BLOCKED_LINES+="  - $line"$'\n'
done < <(find "$GATES_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null)

# No blocked gate → allow the turn to end.
if [[ -z "$BLOCKED_LINES" ]]; then
  _emit_pass
fi

# Mode: default block, opt-in warn.
MODE="block"
[[ "${OMA_GATE_MODE:-block}" == "warn" ]] && MODE="warn"

if [[ "$EVENT" == "StopFailure" ]]; then
  # A failed turn must never be blocked (that would trap the session). Remind
  # only, regardless of MODE.
  _emit_json "StopFailure" "warn" "[OMA gate] The turn failed while AIDLC phase gate(s) are blocked:
$BLOCKED_LINES
Resolve the blockers, or add a signed waiver under .omao/state/gates/waivers/, before proceeding. Run the quality-gates skill to re-evaluate."
fi

# Stop event with a blocked gate.
if [[ "$MODE" == "block" ]]; then
  _emit_json "Stop" "block" "[OMA gate] Cannot end the turn: AIDLC phase gate(s) are blocked:
$BLOCKED_LINES
Resolve the blockers, or add a signed waiver under .omao/state/gates/waivers/, then re-run the quality-gates skill. Set OMA_GATE_MODE=warn to downgrade this to a warning, or OMA_DISABLE_GATES=1 to disable gate enforcement."
else
  _emit_json "Stop" "warn" "[OMA gate] AIDLC phase gate(s) are blocked (warn mode):
$BLOCKED_LINES
Consider resolving before proceeding. Run the quality-gates skill to re-evaluate."
fi
