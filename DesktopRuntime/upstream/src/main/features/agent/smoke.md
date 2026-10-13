# Agent runtime smoke test (real CLI)

Proves one full turn end-to-end through `ClaudeCodeAdapter` (spawn → Write
tool → streamed text → turn-complete → transcript on disk) against the user's
own installed Claude Code, outside Electron.

Requirements: `claude` ≥ 2.1 installed and logged in (`claude auth status`).
It spends a small number of tokens (haiku, one tiny turn).

```bash
BANDAL_AGENT_SMOKE=1 pnpm vitest run tests/main/agent/smoke.test.ts
```

The test is skipped in the normal `pnpm test` run (no real CLI required in CI).
Wire-format details it depends on are documented in ./SPIKE-NOTES.md.
