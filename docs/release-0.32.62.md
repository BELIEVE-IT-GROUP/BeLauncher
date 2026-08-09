# BeLauncher 0.32.62

This release closes a concrete external-verification gap in the MCP part of the Brain plan.

## What changed

- `--diagnose-mcp` now includes a direct `BeLauncher direct MCP check` row.
- That row launches the current BeLauncher binary as a separate `--mcp` process, performs the MCP
  handshake, lists tools and calls `recall` against a temporary canary planted in the real index.
- Settings still summarises only real assistant clients, so the direct server check cannot make
  Claude, Cursor, Windsurf, VS Code or Codex look connected by accident.

## External verification

- `.build/debug/BeLauncher --diagnose-mcp`
- The local run reported all five steps green for:
  - `BeLauncher direct MCP check`
  - `Claude Desktop`
  - `Claude Code`
  - `Cursor`
  - `Windsurf`
  - `VS Code`
  - `Codex`

## Test verification

- `swift test --filter MCPHealthTests`
- `swift build`
- `swift test`
- `git diff --check`

## Plan status

This does not complete the full original plan. It strengthens the MCP requirement with an external
process check: the release can now prove the MCP server and the real Brain index answer through
stdio even before blaming or trusting any individual assistant configuration.
