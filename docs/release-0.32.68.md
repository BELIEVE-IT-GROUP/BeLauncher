# BeLauncher 0.32.68

This release hardens the MCP path that external assistants use to read the Brain.

## What changed

- `BeLauncher --mcp` now migrates the semantic index tables before serving requests.
- The MCP process can be launched with explicit `--database` and `--vault-root` paths. Normal client
  configuration still uses the default real Brain; the flags exist for clean diagnostics and tests.
- Added a stdio integration test that launches the real `BeLauncher` executable, performs the MCP
  handshake, lists tools, calls `recall`, and verifies the reply contains a cited passage from a
  temporary index.
- The test asks for one unique word and expects another unique word that was never sent in the
  query. That proves the external process read the index instead of echoing the question.

## Verification

- `swift test --filter 'MCPStdioIntegrationTests|MCPServerTests|MCPToolsTests|MCPHealthTests'`
- `swift test`
- `git diff --check`

## Plan status

This advances the original MCP requirement: external clients must reach the real Brain over stdio
and receive cited material. It does not complete the full remaining plan.
