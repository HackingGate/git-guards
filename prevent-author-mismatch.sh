#!/usr/bin/env bash
set -euo pipefail

# Hook to prevent committing under an identity that does not match your global
# Git identity (the user.name / user.email in ~/.gitconfig).
#
# Guards against a wrong author slipping into a repo -- e.g. an agent that runs
# `git init` and commits under a stray local user.email, a `git commit
# --author=...`, or a GIT_AUTHOR_*/GIT_COMMITTER_* override in the environment.
# The identity git is about to record (resolved via `git var`, which reflects
# all of the above) must match the name and email in your global config.
#
# Override once with: git commit --no-verify

ident_name()  { local s="$1"; printf '%s' "${s%% <*}"; }
ident_email() { local s="$1"; s="${s#*<}"; printf '%s' "${s%%>*}"; }
lc()          { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }

# Expected identity: the global ~/.gitconfig user (not the repo-local one).
expected_name="$(git config --global user.name 2>/dev/null || true)"
expected_email="$(git config --global user.email 2>/dev/null || true)"

# Nothing to enforce if the global identity isn't configured. The address is the
# part that has to be there: it is what a forge keys attribution on, and it is
# the half an agent gets wrong.
[ -n "$expected_email" ] || exit 0
expected_email_lc="$(lc "$expected_email")"

# A global user.email with no user.name beside it is an ordinary configuration,
# and comparing the two halves alike would refuse every commit in every
# repository holding one: the empty expectation is compared against whatever
# name git resolved, and never matches. The only remedy such a refusal could
# offer is `git config user.name ""`, which is not a command anybody can act on
# -- git will not commit under an empty name, so following the instruction
# exactly leaves the commit refused by git instead of by this hook.
#
# Half a configured identity is enforced as half. Dropping the check outright
# because the name is missing would be the fail-open: the address is still
# declared, and an agent committing under a stray address is the case this hook
# exists for. What is not declared is not enforced, and the report below says
# which of the two was compared so nobody has to infer it from a blank.

# Identity git is about to record (honours --author and GIT_*_* overrides).
author_ident="$(git var GIT_AUTHOR_IDENT 2>/dev/null || true)"
committer_ident="$(git var GIT_COMMITTER_IDENT 2>/dev/null || true)"

# If git can't resolve an identity at all, let `git commit` surface that error.
[ -n "$author_ident" ] || exit 0

mismatches=""
check() {
    local role="$1" ident="$2" name email
    name="$(ident_name "$ident")"
    email="$(ident_email "$ident")"
    if [ "$(lc "$email")" != "$expected_email_lc" ]; then
        mismatches+="  $role: $name <$email>"$'\n'
        return
    fi
    if [ -n "$expected_name" ] && [ "$name" != "$expected_name" ]; then
        mismatches+="  $role: $name <$email>"$'\n'
    fi
}

check "author" "$author_ident"
[ -n "$committer_ident" ] && check "committer" "$committer_ident"

[ -n "$mismatches" ] || exit 0

echo "error: commit identity does not match your global Git identity" >&2
echo "" >&2
printf '%s' "$mismatches" >&2
echo "" >&2
echo "Expected (from ~/.gitconfig):" >&2
if [ -n "$expected_name" ]; then
    echo "  $expected_name <$expected_email>" >&2
else
    echo "  <$expected_email>" >&2
    echo "  (no user.name is set globally, so only the address was compared)" >&2
fi
echo "" >&2
echo "Fix this repo's identity with:" >&2
# Only the halves that are actually declared. `git config user.name ""` is not a
# command anybody can act on, and printing it turns a remedy into a dead end.
[ -z "$expected_name" ] || echo "  git config user.name  \"$expected_name\"" >&2
echo "  git config user.email \"$expected_email\"" >&2
echo "" >&2
echo "Override once with: git commit --no-verify" >&2
exit 1
