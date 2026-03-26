# Agent Configuration
# Defines which tools and capabilities this agent has access to

## ALLOWED TOOLS
- git (all operations except push --force)
- npm/yarn (install, run, test, build)
- Standard Unix tools (grep, sed, awk, find, etc.)
- Text editors (via shell commands)
- Docker (read-only operations)

## FORBIDDEN TOOLS
- rm -rf (use specific file deletions only)
- git push --force
- sudo (no privilege escalation)
- curl/wget to unknown domains (no downloading random scripts)

## MCP TOOLS
None configured by default. Add MCP endpoints here if needed.
