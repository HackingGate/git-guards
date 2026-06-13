#!/usr/bin/env bash
set -euo pipefail

# Block local merge commits and squash merges. Use `gh pr merge` instead.
# Runs at the pre-commit stage in the consuming repository.

if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    echo "A merge is in progress and local merges are disabled. Run \`git merge --abort\`, then merge via \`gh pr merge\`."
    exit 1
fi

git_dir="$(git rev-parse --git-dir 2>/dev/null)" || true
if [ -n "${git_dir:-}" ] && [ -f "$git_dir/SQUASH_MSG" ]; then
    echo "A squash merge is in progress and local squash merges are disabled. Run \`git reset --hard HEAD\`, then merge via \`gh pr merge\`."
    exit 1
fi
