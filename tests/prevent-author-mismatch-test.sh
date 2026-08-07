#!/usr/bin/env bash
# Behaviour tests for prevent-author-mismatch.sh.
#
# The identity this guard reads is not a string it is handed; it is whatever
# `git var GIT_AUTHOR_IDENT` resolves to, which is the sum of the global config,
# the repo-local config, `--author`, and the GIT_AUTHOR_*/GIT_COMMITTER_*
# environment. So every case below drives it the way the thing it guards against
# arrives -- through git's own resolution -- rather than by asserting on a
# function in isolation.
#
# The global config is redirected with GIT_CONFIG_GLOBAL, because `git config
# --global` is the guard's one source of truth and a suite that read the
# developer's real ~/.gitconfig would pass or fail by whose machine it ran on.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Hermetic against the caller's environment. tests/hermetic-env.sh names every
# variable a git-guards test must not inherit and why; the loop is here rather
# than there because unsetting has to happen in THIS shell.
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$repo_root/tests/hermetic-env.sh")

guard="$repo_root/prevent-author-mismatch.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export HOME="$work/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$work/gitconfig-global"
export GIT_CONFIG_SYSTEM=/dev/null

project="$work/project"
git init -q "$project"

failures=0

# $1 name, $2 expected exit, $3 the global config body, then env for the run.
check() {
    local name="$1" expected="$2" global="$3"
    shift 3
    local status=0 output
    printf '%s' "$global" > "$GIT_CONFIG_GLOBAL"
    output="$(cd "$project" && env "$@" bash "$guard" 2>&1)" || status=$?

    if [ "$status" -eq "$expected" ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s, got %s)\n%s\n' "$name" "$expected" "$status" "$output"
    failures=$((failures + 1))
}

# The same, plus what the run said. `!` at the front of the needle asserts the
# opposite: the run must NOT have said it.
check_says() {
    local name="$1" expected="$2" needle="$3" global="$4"
    shift 4
    local status=0 output matched=no
    printf '%s' "$global" > "$GIT_CONFIG_GLOBAL"
    output="$(cd "$project" && env "$@" bash "$guard" 2>&1)" || status=$?

    if [ "${needle:0:1}" = "!" ]; then
        [[ "$output" != *"${needle:1}"* ]] && matched=yes
    else
        [[ "$output" == *"$needle"* ]] && matched=yes
    fi

    if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s saying %q, got %s)\n%s\n' \
        "$name" "$expected" "$needle" "$status" "$output"
    failures=$((failures + 1))
}

both='[user]
	name = Real Person
	email = real@example.test
'
email_only='[user]
	email = real@example.test
'
name_only='[user]
	name = Real Person
'
neither=''

matching=(
    GIT_AUTHOR_NAME="Real Person" GIT_AUTHOR_EMAIL=real@example.test
    GIT_COMMITTER_NAME="Real Person" GIT_COMMITTER_EMAIL=real@example.test
)

# ── the identity matches ────────────────────────────────────────────────
check "a matching identity passes" 0 "$both" "${matching[@]}"

# Addresses are compared case-insensitively; a mail address is not case
# sensitive in its domain and treating one as a mismatch would be a guard
# refusing a commit over nothing.
check "an address differing only in case passes" 0 "$both" \
    GIT_AUTHOR_NAME="Real Person" GIT_AUTHOR_EMAIL=Real@Example.TEST \
    GIT_COMMITTER_NAME="Real Person" GIT_COMMITTER_EMAIL=Real@Example.TEST

# ── the cases it exists for ─────────────────────────────────────────────
# An agent that runs `git init` and commits under whatever it has to hand.
check "a foreign author address is refused" 1 "$both" \
    GIT_AUTHOR_NAME="Real Person" GIT_AUTHOR_EMAIL=bot@noreply.test \
    GIT_COMMITTER_NAME="Real Person" GIT_COMMITTER_EMAIL=real@example.test

check "a foreign author name is refused" 1 "$both" \
    GIT_AUTHOR_NAME="Somebody Else" GIT_AUTHOR_EMAIL=real@example.test \
    GIT_COMMITTER_NAME="Real Person" GIT_COMMITTER_EMAIL=real@example.test

# The committer is checked as well as the author, and separately: `git commit
# --author=...` moves one and leaves the other, so a guard that read only the
# author would pass the commit that names somebody else as its author.
check "a foreign committer is refused even when the author is right" 1 "$both" \
    GIT_AUTHOR_NAME="Real Person" GIT_AUTHOR_EMAIL=real@example.test \
    GIT_COMMITTER_NAME="Build Bot" GIT_COMMITTER_EMAIL=bot@ci.test

check_says "the report names which role was wrong" 1 "committer: Build Bot" "$both" \
    GIT_AUTHOR_NAME="Real Person" GIT_AUTHOR_EMAIL=real@example.test \
    GIT_COMMITTER_NAME="Build Bot" GIT_COMMITTER_EMAIL=bot@ci.test

# A repo-local user.email is the ordinary way this goes wrong, and it is not an
# environment variable, so it exercises git's resolution rather than the harness.
git -C "$project" config user.email stray@local.test
git -C "$project" config user.name "Real Person"
status=0
printf '%s' "$both" > "$GIT_CONFIG_GLOBAL"
output="$(cd "$project" && bash "$guard" 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
    printf 'ok   %s\n' "a stray repo-local user.email is refused"
else
    printf 'FAIL %s (expected exit 1, got %s)\n%s\n' \
        "a stray repo-local user.email is refused" "$status" "$output"
    failures=$((failures + 1))
fi
git -C "$project" config --unset user.email
git -C "$project" config --unset user.name

# ── nothing declared is nothing to enforce ──────────────────────────────
# A machine with no global identity has declared no expectation, and inventing
# one would refuse every commit on a fresh checkout.
check "no global identity enforces nothing" 0 "$neither" \
    GIT_AUTHOR_NAME="Anyone At All" GIT_AUTHOR_EMAIL=anyone@example.test \
    GIT_COMMITTER_NAME="Anyone At All" GIT_COMMITTER_EMAIL=anyone@example.test

# A global name with no address is the same: the address is what a forge keys
# attribution on and what an agent gets wrong, and there is none to compare to.
check "a global name with no address enforces nothing" 0 "$name_only" \
    GIT_AUTHOR_NAME="Somebody Else" GIT_AUTHOR_EMAIL=anyone@example.test \
    GIT_COMMITTER_NAME="Somebody Else" GIT_COMMITTER_EMAIL=anyone@example.test

# ── half a configured identity is enforced as half ──────────────────────
# THE CASE THAT BLOCKED EVERY COMMIT. A global user.email with no user.name
# beside it is an ordinary configuration. The empty expectation was compared
# against whatever name git resolved, never matched, and refused the commit --
# in every repository, for as long as the config stayed that way.
check "a matching address passes with no global name to compare" 0 "$email_only" \
    GIT_AUTHOR_NAME="Whatever Git Resolved" GIT_AUTHOR_EMAIL=real@example.test \
    GIT_COMMITTER_NAME="Whatever Git Resolved" GIT_COMMITTER_EMAIL=real@example.test

# ...and the half that IS declared is still enforced. Dropping the check because
# the name is missing would be the fail-open, and this is the pair that says so:
# the same config, the same absent name, a different address.
check "...and a foreign address is still refused" 1 "$email_only" \
    GIT_AUTHOR_NAME="Whatever Git Resolved" GIT_AUTHOR_EMAIL=bot@noreply.test \
    GIT_COMMITTER_NAME="Whatever Git Resolved" GIT_COMMITTER_EMAIL=bot@noreply.test

# The remedy has to be a command somebody can run. `git config user.name ""` is
# not: git refuses to commit under an empty name, so following the instruction
# exactly leaves the commit refused by git rather than by this hook.
check_says "the remedy never offers an empty user.name" 1 '!user.name  ""' "$email_only" \
    GIT_AUTHOR_NAME="Whatever Git Resolved" GIT_AUTHOR_EMAIL=bot@noreply.test \
    GIT_COMMITTER_NAME="Whatever Git Resolved" GIT_COMMITTER_EMAIL=bot@noreply.test

check_says "...and it still offers the address it did compare" 1 \
    'git config user.email "real@example.test"' "$email_only" \
    GIT_AUTHOR_NAME="Whatever Git Resolved" GIT_AUTHOR_EMAIL=bot@noreply.test \
    GIT_COMMITTER_NAME="Whatever Git Resolved" GIT_COMMITTER_EMAIL=bot@noreply.test

# A blank where a name should be reads as a bug in the hook rather than as a
# fact about the config, so it says which half it compared.
check_says "the report says only the address was compared" 1 \
    'only the address was compared' "$email_only" \
    GIT_AUTHOR_NAME="Whatever Git Resolved" GIT_AUTHOR_EMAIL=bot@noreply.test \
    GIT_COMMITTER_NAME="Whatever Git Resolved" GIT_COMMITTER_EMAIL=bot@noreply.test

if [ "$failures" -ne 0 ]; then
    printf '\n%s test(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nall prevent-author-mismatch tests passed\n'
