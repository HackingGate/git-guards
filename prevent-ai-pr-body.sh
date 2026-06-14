#!/usr/bin/env bash
# PreToolUse hook: block gh pr create commands whose body contains AI authorship markers.
# Reads tool input JSON from stdin, checks the command string for forbidden patterns,
# and exits 1 to block the tool call.
set -euo pipefail

input=$(cat)

# Only intercept Bash tool calls (safety check — matcher should filter already)
tool_name=$(echo "$input" | jq -r '.tool_name // ""')
if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

# Extract the command string
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only check gh pr create commands
if ! echo "$cmd" | grep -qE '^gh pr create\b'; then
    exit 0
fi

# Check the entire command string for AI attribution markers.
# This catches inline --body strings, heredocs, and file-based bodies.
found=0

# "Generated with" attributions
if echo "$cmd" | grep -qiE 'Generated with.*(Claude|GPT|Copilot|Cody|Codeium|Anthropic|OpenAI)'; then
    found=1
fi

# Co-Authored-By with noreply email
if echo "$cmd" | grep -qiE 'Co-Authored-By:.*<noreply@'; then
    found=1
fi

if [ "$found" -eq 1 ]; then
    cat >&2 << 'EOF'
{"continue": false, "stopReason": "PR body contains AI authorship marker (\"Generated with\" or Co-Authored-By noreply). Remove it before creating the PR."}
EOF
    exit 1
fi

exit 0
