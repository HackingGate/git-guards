#!/usr/bin/env bash
set -euo pipefail

# Hook to prevent AI-authored commits.
# Checks the commit message for AI authorship markers such as
# Co-Authored-By trailers with noreply email addresses.
#
# When called natively by git commit-msg, receives the message file as $1. So
# does a run under prek or pre-commit, both of which forward exactly one path
# for a hook declared `pass_filenames: true` -- which this one is, in
# .pre-commit-hooks.yaml, for the reason set out there. The fallback below is
# for a caller that forwards nothing at all.

msg_file="${1:-}"

if [ -z "$msg_file" ] || [ ! -f "$msg_file" ]; then
    # Nothing was forwarded, so fall back to the file git itself wrote. Under
    # `git commit` that is the right message; under a runner asked to check a
    # NAMED file it is the previous commit's, so a guard that lands here reports
    # a pass over a file it never opened. Registering this hook with
    # `pass_filenames: true` is what keeps it out of reach.
    git_dir="$(git rev-parse --git-dir 2>/dev/null)" || true
    if [ -n "${git_dir:-}" ] && [ -f "$git_dir/COMMIT_EDITMSG" ]; then
        msg_file="$git_dir/COMMIT_EDITMSG"
    fi
fi

if [ -z "$msg_file" ] || [ ! -f "$msg_file" ]; then
    echo "prevent-ai-author: no commit message file found" >&2
    exit 1
fi

found=0

# Block Co-Authored-By lines with noreply email addresses.
# AI services (Claude, etc.) use noreply@ emails; human co-authors use real ones.
if grep -qiE '^Co-Authored-By:.*<noreply@' "$msg_file"; then
    echo "error: AI-authored commit detected (Co-Authored-By with noreply email)" >&2
    found=1
fi

# Block "Generated with" attributions from AI coding tools.
# Examples: "🤖 Generated with [Claude Code]", "Generated with Claude Code",
# "Generated with GitHub Copilot", etc.
if grep -qiE 'Generated with.*(Claude|GPT|Copilot|Cody|Codeium|Anthropic|OpenAI)' "$msg_file"; then
    echo "error: AI-authored commit detected (Generated with attribution)" >&2
    found=1
fi

if [ "$found" -eq 1 ]; then
    echo "" >&2
    echo "The commit message contains markers of AI authorship. Remove them" >&2
    echo "and ensure the commit represents your own work." >&2
    echo "" >&2
    echo "Override once with: git commit --no-verify" >&2
    exit 1
fi

exit 0
