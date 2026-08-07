#!/usr/bin/env bash
# Behaviour tests for prevent-ai-author.sh.
#
# Every refusal below is paired with the message that must be allowed through,
# because a guard that refuses a marker is only half of the claim: the other
# half is that it leaves an ordinary message alone. A hook nobody can commit
# under gets uninstalled, and an uninstalled hook refuses nothing.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Hermetic against the caller's environment. tests/hermetic-env.sh names every
# variable a git-guards test must not inherit and why; the loop is here rather
# than there because unsetting has to happen in THIS shell.
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$repo_root/tests/hermetic-env.sh")

guard="$repo_root/prevent-ai-author.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

project="$work/project"
git init -q "$project"

failures=0

check() {
    local name="$1" expected="$2" message="$3"
    local status=0 output
    printf '%s\n' "$message" > "$work/COMMIT_MSG"
    output="$(bash "$guard" "$work/COMMIT_MSG" 2>&1)" || status=$?

    if [ "$status" -eq "$expected" ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s, got %s)\n%s\n' "$name" "$expected" "$status" "$output"
    failures=$((failures + 1))
}

# ── the trailer ─────────────────────────────────────────────────────────
check "a Co-Authored-By with a noreply address is refused" 1 \
'fix: correct the ordering

Co-Authored-By: Some Assistant <noreply@example.test>'

# The address is what distinguishes the two, not the trailer. A human
# co-author is the reason the trailer exists, and refusing it would make the
# guard wrong about the case it is supposed to leave alone.
check "a Co-Authored-By with a real address passes" 0 \
'fix: correct the ordering

Co-Authored-By: A Colleague <colleague@example.test>'

# Trailers are matched case-insensitively because git itself accepts them that
# way, and a marker that survives being spelled `co-authored-by` is not a guard.
check "the trailer is matched whatever its case" 1 \
'fix: correct the ordering

co-authored-by: Some Assistant <NoReply@example.test>'

# ── the attribution line ────────────────────────────────────────────────
check "a Generated with attribution is refused" 1 \
'fix: correct the ordering

Generated with Claude Code'

check "the attribution is refused mid-line too" 1 \
'fix: correct the ordering

Some of this was Generated with GitHub Copilot and then edited.'

# The names are the point, not the phrase. Prose that happens to contain
# "generated with" is ordinary English and appears in real commit messages
# about, for instance, generated code.
check "generated with something that is not a tool passes" 0 \
'fix: the fixtures are now Generated with a seeded random number generator'

# ── ordinary messages ───────────────────────────────────────────────────
check "an ordinary message passes" 0 \
'fix: resolve the workspace from git, not from the script path'

check "an empty message passes" 0 ''

check "a message that merely mentions the tools passes" 0 \
'docs: note that Claude and Copilot both exist'

# ── how a runner calls it ───────────────────────────────────────────────
# prek does not forward the commit-message path, so the hook has to find
# COMMIT_EDITMSG itself. Without this the guard refuses every commit under one
# runner and passes under the others -- one rule with two behaviours, which is
# the shape a shared hook repository cannot ship.
printf 'fix: it\nCo-Authored-By: Some Assistant <noreply@example.test>\n' \
    > "$project/.git/COMMIT_EDITMSG"
status=0
output="$(cd "$project" && bash "$guard" 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
    printf 'ok   %s\n' "a runner that forwards no path still finds the message"
else
    printf 'FAIL %s (expected exit 1, got %s)\n%s\n' \
        "a runner that forwards no path still finds the message" "$status" "$output"
    failures=$((failures + 1))
fi

printf 'fix: it is fine\n' > "$project/.git/COMMIT_EDITMSG"
status=0
output="$(cd "$project" && bash "$guard" 2>&1)" || status=$?
if [ "$status" -eq 0 ]; then
    printf 'ok   %s\n' "...and passes a clean one found the same way"
else
    printf 'FAIL %s (expected exit 0, got %s)\n%s\n' \
        "...and passes a clean one found the same way" "$status" "$output"
    failures=$((failures + 1))
fi

# No message anywhere is not a clean message. Exiting 0 here would mean the one
# situation in which the guard reads nothing is also the one in which it says
# everything is fine.
mkdir -p "$work/nowhere"
status=0
output="$(cd "$work/nowhere" && bash "$guard" 2>&1)" || status=$?
if [ "$status" -eq 1 ] && [[ "$output" == *"no commit message file found"* ]]; then
    printf 'ok   %s\n' "no message file at all is refused, not passed"
else
    printf 'FAIL %s (expected exit 1 saying so, got %s)\n%s\n' \
        "no message file at all is refused, not passed" "$status" "$output"
    failures=$((failures + 1))
fi

# ── the refusal has to be actionable ────────────────────────────────────
printf 'fix: it\nCo-Authored-By: Some Assistant <noreply@example.test>\n' > "$work/COMMIT_MSG"
status=0
output="$(bash "$guard" "$work/COMMIT_MSG" 2>&1)" || status=$?
if [[ "$output" == *"--no-verify"* ]]; then
    printf 'ok   %s\n' "the refusal names the one-off override"
else
    printf 'FAIL %s (the refusal names no way out)\n%s\n' \
        "the refusal names the one-off override" "$output"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%s test(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nall prevent-ai-author tests passed\n'
