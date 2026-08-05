---
sidebar_position: 30
title: Harness DSL v2
---

# Harness DSL v2

OMA's harness DSL bumped from `version: 1` to `version: 2` in release
v0.3b. The bump is **purely additive** — existing v1 files compile
unchanged and emit the same `.mcp.json` / `kiro-agents/*.agent.json`
output they did before.

## What is new

v2 adds four optional top-level sections on top of v1:

| Section | Status in v0.3b | Purpose |
|---------|-----------------|---------|
| `metadata` | Accepted, ignored by the compiler | Kubernetes-style `labels` / `annotations` |
| `workflows` | Validated as a DAG; no runtime executor | Named sequences of agent/skill steps |
| `telemetry` | Free-form object (body validated in v0.4) | OpenTelemetry Collector wiring |
| `policies` | Validated body; **compiled into a PreToolUse enforcement hook** | Declarative runtime deny rules — pure Claude Code, no external policy engine |

`metadata`, `workflows`, and `telemetry` do not change the files emitted by
`oma-compile`. **`policies` is the exception**: each policy carries an
`enforce` block that the compiler turns into `hooks/harness-rules.json` plus a
`PreToolUse` entry in `hooks/hooks.json`, bundling `hooks/enforce.py` into the
plugin. Once installed, those rules block matching tool calls before they run.

## Migrating a v1 file

1. Change the top-level `version: 1` to `version: 2`.
2. Keep every other key exactly as it was.
3. Optionally add any of the four new sections.

Example — adding a workflow DAG:

```yaml
version: 2
plugin: ai-infra

metadata:
  labels:
    aidlc-phase: construction

agents:
  - id: platform-architect
    runtime: kiro
    mcp: [eks]
  - id: vllm-deployer
    runtime: kiro
    mcp: [eks]

mcp:
  eks:
    command: uvx
    args: ["awslabs.eks-mcp-server==0.1.28"]

workflows:
  platform-bootstrap:
    description: 5-checkpoint platform bootstrap
    steps:
      - id: preflight
        agent_ref: platform-architect
      - id: provision
        agent_ref: vllm-deployer
        depends_on: [preflight]
        on_failure: rollback
```

## Workflow DAG validation

The compiler rejects the file before emission if any of these hold:

- a `depends_on` entry does not name a step in the same workflow;
- the `depends_on` graph contains a cycle;
- an `agent_ref` does not match an `agents[].id` in the same file;
- two steps share the same `id` inside one workflow.

## Policy enforcement (pure Claude Code)

A `policies` entry declares a **runtime deny rule**. The compiler translates
the block into `hooks/harness-rules.json` and registers a `PreToolUse` hook in
`hooks/hooks.json` that runs the bundled `hooks/enforce.py`. Because the hook
fires at the harness level, a denied tool call never reaches the model — this
is enforcement, not prompt guidance.

**Before (v0.4-preview, OPA/Rego — removed):**

```yaml
policies:
  - id: require-approval-for-prod
    rego_ref: policies/examples/deployment-approval.rego   # external .rego file
    severity: blocking
    phase: [construction, operations]
```

That path shelled out to an `opa` binary at validate time. If `opa` was not
installed it silently fell through (fail-open) — fatal for a safety device.

**After (pure Claude Code — declarative `enforce`):**

```yaml
policies:
  - id: deny-eks-mutating-kubectl
    severity: blocking
    phase: [construction, operations]
    description: Block mutating kubectl; EKS writes need an approved Deployment.
    enforce:
      tool: Bash                       # omit to match every tool
      deny_if:
        command_matches: "kubectl\\s+(apply|delete|patch|scale)"
      decision: deny                   # deny | ask
      reason: "Harness: mutating kubectl is blocked. Use platform-bootstrap."
```

`deny_if` supports `command_matches`, `command_matches_any` (list),
`file_path_matches` (Write/Edit/Read), and `input_field` (`{path, matches}` for
arbitrary tool inputs). A rule fires when the tool matches **and every**
declared condition matches; the first firing rule wins.

The compiler rejects the file before emission if any policy:

- has an `enforce.deny_if` regex that does not compile (fail-closed at build);
- declares an empty `deny_if` (the schema requires at least one condition).

At runtime `enforce.py` fails **open** only when there is no ruleset or the
event cannot be parsed, and fails **closed per rule** — one malformed rule is
skipped without disabling the others.

`skill_ref` is **not** validated against the plugin file — skills are
resolved at runtime by the harness.

## Hook events (`hooks:`)

The `hooks:` block declares plugin-bundled hooks the compiler emits into
`hooks/hooks.json`. Each key is an event; `runs` is a script path that must stay
inside the plugin root (so `/plugin install` ships it — a `../`-escaping path is
a compile error). `PreToolUse` is **not** declared here; it is derived from the
`policies:` block above.

| Event | Emitted as | Bundled script | Purpose |
|-------|-----------|----------------|---------|
| `session-start` | `SessionStart` | `session-start-ontology.sh` | Inject active ontology state (Budgets, Incidents, Deployments) at session start |
| `stop` | `Stop` | `stop-gate.sh` | Turn-end phase-gate enforcement — block the turn from ending while a gate is blocked |
| `stop-failure` | `StopFailure` | `stop-gate.sh` | Remind about blocked gates on a failed turn (never blocks) |

```yaml
hooks:
  session-start:
    runs: hooks/session-start-ontology.sh
  stop:
    runs: hooks/stop-gate.sh
  stop-failure:
    runs: hooks/stop-gate.sh
```

### Phase-gate enforcement (`stop` / `stop-failure`)

The `quality-gates` skill writes a per-phase verdict to
`.omao/state/gates/<phase>.json` (`status: passed|blocked`,
`next_phase_allowed`, `blockers`, waiver reconciliation). `stop-gate.sh` is the
**enforcement half**: it does not re-derive the verdict, it trusts the recorded
one. When any gate is blocked (`status == "blocked"` or
`next_phase_allowed == false`):

- **`Stop`** returns `{"decision": "block", "reason": ...}` so the turn cannot
  end — the agent that authored the work cannot silently skip its own gate
  (the self-grading failure mode).
- **`StopFailure`** never blocks (that would trap a failing session in a loop);
  it surfaces a `systemMessage` reminder only.

Controls:

- `OMA_GATE_MODE=warn` — downgrade the `Stop` block to a non-blocking
  `systemMessage`.
- `OMA_DISABLE_GATES=1` — kill switch; the hook always passes through.
- Reentry guard — Claude Code sets `stop_hook_active: true` when it re-runs the
  Stop hook after a prior block; the hook passes through in that case to avoid a
  deadlock.

Like `session-start-ontology.sh`, the script is self-contained (reads only
`.omao/state/gates/`, no repo-root dependency) and requires a real JSON encoder
(`jq`, then `python3`) so user-editable gate files cannot inject keys.

## Backward compatibility guarantees

- v1 files continue to validate under the same `dsl.schema.json`.
- v1 files are **explicitly prohibited** from using the v2-only sections
  (enforced via a schema `allOf[0].if/then`).
- Under `oma compile --strict-enterprise` (v0.5) only v2 files are
  accepted; the baseline `oma compile` continues to accept both.

## What comes next

- **v0.4** fills in the body schemas for `telemetry` and `policies`.
  Policies are enforced as **pure Claude Code**: the compiler emits a
  PreToolUse hook (`hooks/enforce.py` + `hooks/harness-rules.json`) that
  blocks matching tool calls at the harness level. There is no external
  policy engine and no `opa` dependency — enforcement travels inside the
  installed plugin via `${CLAUDE_PLUGIN_ROOT}`.
- **v0.5** regenerates `ai-infra.oma.yaml`'s native outputs as a
  byte-diff baseline and migrates the remaining four plugins to v2.
