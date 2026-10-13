# M4-H Spike Notes — Claude Code CLI headless behavior

Verified against the real binary: **claude 2.1.222** at `/Users/iseojun/.local/bin/claude`
(macOS, logged in via claude.ai, subscription `max`). Raw captures live in
`tests/main/agent/fixtures/*.jsonl` (real CLI output, committed as test fixtures).

Spawn shape used everywhere below:

```
claude -p --input-format stream-json --output-format stream-json \
  --include-partial-messages --verbose --permission-mode <mode> ... \
  (cwd = course folder, env without CLAUDECODE/CLAUDE_CODE_ENTRYPOINT)
```

Input line: `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}`.

## Spike 1 — stream-json round trip

- **Long-lived process works.** After the `result` event the process stays alive
  waiting for the next user line on stdin; it exits 0 when stdin closes. One
  process per course session is viable.
- **Init event**: first line is `{"type":"system","subtype":"init", session_id, cwd,
  model, permissionMode, tools[], mcp_servers[], claude_code_version,
  capabilities:["interrupt_receipt_v1","interrupt_cancel_queued_v1","msg_lifecycle_v1"], ...}`.
  - **NO `transcript_path` field.** Transcript lives at
    `~/.claude/projects/<cwd with [^A-Za-z0-9-] → "-">/<session_id>.jsonl` and the
    filename **equals session_id** in 2.1.222. We compute + verify it on disk and
    persist it (per Orca guidance, filename may drift from session_id in other
    versions — hence persisting the resolved path).
  - A **fresh `system:init` is emitted at the start of every turn** (same
    session_id). The mapper dedupes `session-started`.
- **stream_event wrapping**: `{"type":"stream_event","event":<raw Anthropic SSE event>,
  session_id, parent_tool_use_id, uuid}`. Raw event types observed:
  `message_start` (carries `message.id`, model, usage), `content_block_start`
  (index + `content_block.type` = `thinking|text|tool_use`; tool_use carries
  `id`/`name` with empty `input:{}`), `content_block_delta` (delta types
  `thinking_delta`, `signature_delta`, `text_delta`, `input_json_delta` with
  `partial_json`), `content_block_stop`, `message_delta` (stop_reason + usage
  incl. `output_tokens_details.thinking_tokens`), `message_stop`.
- **Double reporting confirmed**: after each content block finishes streaming, the
  CLI emits a top-level `{"type":"assistant","message":{...}}` whose `content`
  array contains the completed block (full text / full parsed tool input) —
  it arrives right *before* the corresponding `content_block_stop`.
  **Dedupe rule adopted**: deltas stream as `text-delta` / `tool-input-delta`
  per blockId; the assistant-final block becomes `text-final` (replaces the
  accumulated deltas for that blockId) and, for tool_use, a *refreshed*
  `tool-start` with the same `toolCallId` carrying the full parsed `input`
  (renderer must upsert by toolCallId — see report for M4-I).
- **Tool results** arrive as `{"type":"user","message":{content:[{type:"tool_result",
  tool_use_id, content, is_error?}]}}` plus a structured `tool_use_result` sibling.
- **`result` event**: `{type:"result", subtype:"success", is_error, stop_reason:"end_turn",
  terminal_reason:"completed", usage{input_tokens, output_tokens,
  cache_read_input_tokens, cache_creation_input_tokens}, total_cost_usd,
  duration_ms, num_turns, permission_denials[], result:"<final text>"}`.
- **Noise to ignore**: `system:status`, `system:thinking_tokens`,
  `rate_limit_event` with `rate_limit_info.status === "allowed"` (map to `limit`
  only when not allowed; `resetsAt` is epoch seconds).
- `--setting-sources user` still loads the user's MCP servers/plugins/agents
  (init showed 68 tools, figma/pencil MCP). Acceptable: it is the user's own
  environment; `--disallowedTools Bash` and the allowlist still apply.

## Spike 2 — can_use_tool control protocol: **WORKS in -p mode**

`--permission-prompt-tool stdio` (hidden from `--help`, but present in the binary
and used by the official Agent SDK) turns on the stdio control protocol:

- With `--permission-mode default`, a Write triggered:
  ```json
  {"type":"control_request","request_id":"<uuid>","request":{
     "subtype":"can_use_tool","tool_name":"Write","display_name":"Write",
     "input":{...},"description":"perm-test-allow.txt",
     "permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],
     "tool_use_id":"toolu_..."}}
  ```
  The turn **pauses** until we answer on stdin:
  ```json
  {"type":"control_response","response":{"subtype":"success","request_id":"<same>",
     "response":{"behavior":"allow","updatedInput":{...}}}}
  ```
  Allow → tool runs, file created, `result.permission_denials=[]`.
  Deny (`{"behavior":"deny","message":"User denied this action"}`) → tool_result
  comes back `is_error:true` with our message, the model continues gracefully,
  and the denial is listed in `result.permission_denials`.
- **Conclusion**: `interactivePermissions: true` is REAL. No fallback needed.
  Anything the allowlist does not match raises a real `permission-request` the
  renderer can answer. (Spike 5 revised the mode we ship — see below.)

## Spike 3 — interrupt + resume

- **Interrupt**: client→CLI `{"type":"control_request","request_id":"req_x",
  "request":{"subtype":"interrupt"}}` mid-stream. CLI acks with
  `{"type":"control_response","response":{"subtype":"success","request_id":"req_x",
  "response":{"still_queued":[]}}}`, streaming stops, and the turn ends with a
  `result` of `subtype:"error_during_execution"`, `is_error:true`,
  `stop_reason:null`, `terminal_reason:"aborted_streaming"`. The process stays
  alive and accepts the next user message. Mapper maps this result to
  `turn-complete {stopReason:'interrupted'}` when we initiated the interrupt.
- **Resume**: after `SIGKILL`, respawning with `--resume <session_id>` keeps the
  **same session_id**, does **not** replay prior messages on stdout, and has full
  context (recalled a fact from turn 1 and knew it had been interrupted).
  Transcript filename `== session_id` and resume appends to the same file.

## Spike 4 — list_models probe

One-shot process, same stream-json flags; send
`{"type":"control_request","request_id":"r","request":{"subtype":"list_models"}}`
before any user message → `control_response.response.response.models[]` with
`{value, resolvedModel, displayName, description, supportsEffort?, ...}`
(e.g. value `"default" | "opus[1m]" | "sonnet" | "haiku"`). Older CLIs answer
`subtype:"error"` → keep the static fallback list.

## Spike 5 — path-scoped allowlist rules confine Edit/Write to the course folder

Run against **claude 2.1.222** with cwd = a throwaway "course" dir and a sibling
"outside" dir. Every `can_use_tool` request was answered `deny`, so "no
permission request + file exists" means the write was silently pre-approved.

| # | `--permission-mode` | Edit/Write rule | target | permission card? | written? |
|---|---|---|---|---|---|
| A | `acceptEdits` | `Write` (blanket) | **outside** cwd | **no** | **yes** ← the vulnerability |
| D | `default` | `Write` (blanket) | outside cwd | **no** | **yes** |
| C | `default` | `Write(<abs course path>/**)` | *inside* cwd | yes | no ← rule never matched |
| B | `acceptEdits` | `Write(<abs course path>/**)` | outside cwd | yes | no |
| E | `default` | `Write(./**)` | inside cwd | **no** | yes |
| E | `default` | `Write(./**)` | outside cwd | **yes** | no |
| G | `default` | `Write(./**)` | `<cwd>/week3/deep.txt` | no | yes |
| F | `acceptEdits` | `Write(./**)` | inside / outside cwd | no / **yes** | yes / no |
| I | `default` | `Write(./**)` via one comma-joined value | inside / outside cwd | no / **yes** | yes / no |

Findings:

1. **A blanket `Edit`/`Write` allowlist rule matches every path on disk**, in
   both permission modes, and pre-approves writes anywhere — `~/.zshrc`
   included. The permission card never fires. This was the shipped config.
2. **`Edit(./**)` / `Write(./**)` works**: the glob resolves against the CLI's
   cwd (the course folder), covers nested subdirectories, and pushes every
   out-of-course path to a `can_use_tool` request. Denials come back to the
   model as a normal tool error and it continues gracefully ("that path is
   outside the working directory").
3. **Absolute paths inside a rule do NOT work.** `Write(/private/tmp/.../course/**)`
   matched nothing — even an *in-cwd* write raised a permission card. A single
   leading `/` is read as project-relative, so the cwd-relative form is the
   only one to use. (`//abs` may work; not tested, not needed.)
4. `acceptEdits` does **not** blanket-approve out-of-cwd writes on its own
   (case B) — but it *does* auto-approve in-cwd edits by itself, which means a
   broken rule fails **open**. With `--permission-mode default` the same rule
   fails **closed** (unmatched → permission card). We ship `default`.
5. `--allowedTools "a,b,c"` as a single comma-joined value behaves identically
   to splatting the rules as separate argv items (case I, both directions), and
   removes the risk flagged in backlog §5.19 of extras silently becoming
   positional arguments in `-p` mode. We ship the comma-joined form.

Shipped config after this spike:
`--permission-mode default --permission-prompt-tool stdio --allowedTools
Read,Glob,Grep,Edit(./**),Write(./**),WebSearch,WebFetch,TodoWrite
--disallowedTools Bash`.

Still open (out of scope here, tracked in backlog §5.6/§5.8): `Read`/`WebFetch`
remain blanket-allowed, and "항상 허용" still grants by bare tool name, so a
student can widen `Write` back to unscoped for a course.

## Misc

- `claude auth status --json` → `{loggedIn, authMethod, apiProvider, email,
  subscriptionType}` — powers `agent:availability`.
- Env hygiene: strip `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SSE_PORT`
  when spawning (Bandal may itself be launched from inside a Claude session).
- `--verbose` is required for stream-json output in -p mode; `--version` →
  `2.1.222 (Claude Code)`.
