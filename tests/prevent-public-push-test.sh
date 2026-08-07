#!/usr/bin/env bash
# Behaviour tests for prevent-public-push.sh.
#
# The guard is run the way hook runners actually run it: from a *copy in a hook
# cache*, with the working directory at the project root. That is the shape the
# guard got wrong — inferring the workspace from its own path put the allow-list
# at the cache directory's name and refused every push, including a repo pushing
# to its own origin. Tests that invoke the script from the repo it lives in
# cannot see that, so these deliberately do not.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Hermetic against the caller's environment. tests/hermetic-env.sh names every
# variable a git-guards test must not inherit and why; the loop is here rather
# than there because unsetting has to happen in THIS shell.
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$repo_root/tests/hermetic-env.sh")

guard_source="$repo_root/prevent-public-push.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The cache layout prek uses: <cache>/repos/<hash>/<script>. A guard inferring
# its workspace from its own path takes the directory named `repos` for the
# entire allow-list, which is what these fixtures exist to catch.
cache_dir="$work/cache/repos/d3bd30cf402d21e4"
mkdir -p "$cache_dir"
cp "$guard_source" "$cache_dir/prevent-public-push.sh"
guard="$cache_dir/prevent-public-push.sh"

# HOME must not be an ancestor of the fixtures, or the climb stops early.
export HOME="$work/home"
mkdir -p "$HOME"

new_repo() {
    local dir="$1" origin="$2"
    mkdir -p "$dir"
    git -C "$dir" init -q
    [ -z "$origin" ] || git -C "$dir" remote add origin "$origin"
}

# A workspace owned by Acme, with a nested clone inside it (the shape of a
# submodule, or of a sibling checkout that is simply not tracked).
workspace="$work/Acme"
new_repo "$workspace" "https://github.com/Acme/Acme.git"
nested="$workspace/widget"
new_repo "$nested" "https://github.com/Acme/widget.git"

# A standalone repo with no enclosing workspace.
standalone="$work/solo"
new_repo "$standalone" "git@github.com:Acme/solo.git"

failures=0

check() {
    local name="$1" expected="$2" dir="$3" url="$4"
    shift 4
    local status=0 output
    output="$(cd "$dir" && env "$@" PRE_COMMIT_REMOTE_NAME=origin PRE_COMMIT_REMOTE_URL="$url" \
        bash "$guard" 2>&1)" || status=$?

    if [ "$status" -eq "$expected" ]; then
        printf 'ok   %s\n' "$name"
        return
    fi

    printf 'FAIL %s (expected exit %s, got %s)\n%s\n' "$name" "$expected" "$status" "$output"
    failures=$((failures + 1))
}

# The same, plus what the run SAID. An exit code alone cannot tell a refusal for
# the right reason from a refusal for a different one, and this suite has been
# wrong about exactly that: the pinned-owner cases below all exited 1 whether or
# not the pin was being enforced, because their fixtures pushed outside the
# allow-list too. A needle beginning with `!` asserts the run did NOT say it.
check_says() {
    local name="$1" expected="$2" needle="$3" dir="$4" url="$5"
    shift 5
    local status=0 output matched=no
    output="$(cd "$dir" && env "$@" PRE_COMMIT_REMOTE_NAME=origin PRE_COMMIT_REMOTE_URL="$url" \
        bash "$guard" 2>&1)" || status=$?

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

# A nested repo pushing to its workspace's owner, with the guard running from
# the cache -- the shape that breaks when the workspace is taken from the
# script's own path. `~/.cache/prek/repos/<hash>/` makes `dirname($0)/..` name
# the cache, so the allow-list reads as the single owner `repos` and every push
# is refused, including a repo pushing to its own origin.
check "nested repo may push to the workspace owner" 0 \
    "$nested" "https://github.com/Acme/Acme.git"

check "nested repo may push to its own origin" 0 \
    "$nested" "https://github.com/Acme/widget.git"

check "standalone repo may push to its own origin" 0 \
    "$standalone" "git@github.com:Acme/solo.git"

# The guard still guards.
check "a push to another owner is refused" 1 \
    "$nested" "https://github.com/someone-else/widget.git"

check "a push to a personal fork is refused" 1 \
    "$standalone" "git@github.com:personal/solo.git"

# Overrides, keyed off the *workspace* owner — a bogus owner would mean a bogus
# variable name, and an override nobody can spell is an override that does not
# exist.
check "the owner-prefixed allow-list is honoured" 0 \
    "$nested" "https://github.com/partner/widget.git" ACME_ALLOWED_PUSH_OWNERS=partner

check "the generic allow-list is honoured" 0 \
    "$nested" "https://github.com/partner/widget.git" WORKSPACE_ALLOWED_PUSH_OWNERS=partner

check "the owner-prefixed bypass is honoured" 0 \
    "$nested" "https://github.com/someone-else/widget.git" ACME_ALLOW_UNSAFE_PUSH=1

# A repo with no origin at all: nothing to infer an owner from, so the guard
# must not invent one and wave the push through.
noremote="$work/orphan"
new_repo "$noremote" ""
check "a repo with no origin refuses a foreign owner" 1 \
    "$noremote" "https://github.com/someone-else/orphan.git"

# --- the pinned owner ---------------------------------------------------------
# Deriving the owner from `origin` is tautological for the one remote most likely
# to be wrong. These drive the pin from both places it can be declared, and prove
# the case the derivation cannot catch.

check "an env-pinned owner is honoured" 0 \
    "$nested" "https://github.com/Acme/widget.git" WORKSPACE_PINNED_OWNER=Acme

# THE CASE THE DERIVATION CANNOT CATCH. Origin has been repointed at a public
# upstream -- the exact accident -- so the derived allow-list would have moved with
# it and the push would be permitted. A pin cannot be moved by the mistake it
# guards.
hijacked="$work/Hijacked"
new_repo "$hijacked" "https://github.com/public-upstream/Hijacked.git"
check "a repointed origin is permitted when the owner is DERIVED" 0 \
    "$hijacked" "https://github.com/public-upstream/Hijacked.git"
check "...and refused when the owner is PINNED" 1 \
    "$hijacked" "https://github.com/public-upstream/Hijacked.git" WORKSPACE_PINNED_OWNER=Acme

# A committed file outranks the environment's absence, and repointing origin
# cannot touch it. This is the stronger of the two declarations.
pinned="$work/Pinned"
new_repo "$pinned" "https://github.com/public-upstream/Pinned.git"
printf 'Acme\n' >"$pinned/.git-guards-owner"
check "a committed .git-guards-owner refuses the repointed origin" 1 \
    "$pinned" "https://github.com/public-upstream/Pinned.git"
# ...and where origin AGREES with the pin, the pin simply is the allow-list. Note
# this needs its own fixture: in $pinned the origin is repointed, so a push to the
# right owner is still refused -- the mismatch is the alarm whatever this
# particular push targets, which is the point of pinning.
honest="$work/Honest"
new_repo "$honest" "https://github.com/Acme/Honest.git"
printf 'Acme\n' >"$honest/.git-guards-owner"
check "a committed .git-guards-owner permits its own owner" 0 \
    "$honest" "https://github.com/Acme/Honest.git"
check "...and still refuses a foreign one" 1 \
    "$honest" "https://github.com/someone-else/Honest.git"

# THE CASE THAT DISCRIMINATES, and without it none of the above does.
#
# Every pinned-owner fixture up to here pushes to an owner OUTSIDE the
# allow-list, so each exits 1 by the ordinary destination rule whether the pin
# is enforced or not. Deleting the entire pinned-owner block from the guard left
# all eighteen of them green: the feature had no test that could go red.
#
# This one pushes to Acme, which the pin ITSELF puts inside the allow-list, from
# a repo whose origin has been repointed at a public upstream. Enforced, the
# mismatch refuses regardless of where this particular push is going -- the
# workspace is not in the state its owner believes. Unenforced, it is exit 0.
# The message is asserted too, so a refusal arriving for some other reason
# cannot stand in for this one.
pinned_allowed="$work/PinnedAllowed"
new_repo "$pinned_allowed" "https://github.com/public-upstream/PinnedAllowed.git"
check_says "a repointed origin is refused even when the push targets the pin" 1 \
    "origin owner is public-upstream, but this workspace is pinned to Acme" \
    "$pinned_allowed" "https://github.com/Acme/PinnedAllowed.git" \
    WORKSPACE_PINNED_OWNER=Acme

check_says "...and it is exit 0 with no pin, which is what makes it the pin's work" 0 \
    '!pinned to' \
    "$pinned_allowed" "https://github.com/public-upstream/PinnedAllowed.git"

# The committed declaration has to be discriminated separately: it is a
# different code path to the environment variable, and it is the stronger of the
# two, so a test that only drove the env var would leave the one that matters
# more uncovered.
pinned_file_allowed="$work/PinnedFileAllowed"
new_repo "$pinned_file_allowed" "https://github.com/public-upstream/PinnedFileAllowed.git"
printf 'Acme\n' >"$pinned_file_allowed/.git-guards-owner"
check_says "a committed pin refuses a repointed origin even toward the pin" 1 \
    "origin owner is public-upstream, but this workspace is pinned to Acme" \
    "$pinned_file_allowed" "https://github.com/Acme/PinnedFileAllowed.git"

# --- the bypass has to actually bypass -----------------------------------------
# The README says <OWNER>_ALLOW_UNSAFE_PUSH and WORKSPACE_ALLOW_UNSAFE_PUSH
# "bypass the guard entirely". They did not: the pinned-owner check ran before
# allow_unsafe was read, so with a pin in place every documented escape still
# exited 1 -- against a refusal that named no escape at all. Somebody who sets
# the variable, sees the push fail anyway and reaches for --no-verify has turned
# off every hook in the repository instead of this one.
check_says "the generic bypass defeats a pinned-owner mismatch" 0 \
    "skipping push destination guard" \
    "$hijacked" "https://github.com/public-upstream/Hijacked.git" \
    WORKSPACE_PINNED_OWNER=Acme WORKSPACE_ALLOW_UNSAFE_PUSH=1

check_says "the owner-prefixed bypass defeats it too" 0 \
    "skipping push destination guard" \
    "$hijacked" "https://github.com/public-upstream/Hijacked.git" \
    WORKSPACE_PINNED_OWNER=Acme ACME_ALLOW_UNSAFE_PUSH=1

check_says "the committed pin's mismatch is bypassable as well" 0 \
    "skipping push destination guard" \
    "$pinned" "https://github.com/public-upstream/Pinned.git" \
    ACME_ALLOW_UNSAFE_PUSH=1

# ...and the refusal has to name the escape, or the escape may as well not exist.
check_says "the pinned-owner refusal names the way out" 1 \
    "ACME_ALLOW_UNSAFE_PUSH=1" \
    "$hijacked" "https://github.com/public-upstream/Hijacked.git" \
    WORKSPACE_PINNED_OWNER=Acme

# An allow-list is not a bypass, and must not act as one. It says which
# DESTINATIONS are acceptable; the mismatch says the workspace is not in the
# state its owner thinks it is, which is true of this repository whatever this
# push targets.
check_says "an allow-list does not silence a repointed origin" 1 \
    "pinned to Acme" \
    "$hijacked" "https://github.com/public-upstream/Hijacked.git" \
    WORKSPACE_PINNED_OWNER=Acme WORKSPACE_ALLOWED_PUSH_OWNERS=public-upstream

# --- no origin is not a foreign origin -----------------------------------------
# `orphan` in that sentence was the DIRECTORY's name, reached through a last
# resort that belongs to the question "what owner should we assume", landing in
# a sentence about origin. There is no remote to go and look at.
check_says "a repo with no origin is not accused of having a foreign one" 0 \
    '!origin owner is' \
    "$noremote" "https://github.com/Acme/orphan.git" WORKSPACE_PINNED_OWNER=Acme

check "a repo with no origin still judges the push against the pin" 1 \
    "$noremote" "https://github.com/someone-else/orphan.git" WORKSPACE_PINNED_OWNER=Acme

# --- the per-repo allow-list --------------------------------------------------
# An owner is a blunt unit: allowing one to let a single repository through allows
# every repository that owner will ever have.
check "the per-repo allow-list admits exactly one repo" 0 \
    "$nested" "https://github.com/partner/widget.git" ACME_ALLOWED_PUSH_REPOS=partner/widget
check "...and not its sibling" 1 \
    "$nested" "https://github.com/partner/other.git" ACME_ALLOWED_PUSH_REPOS=partner/widget

if [ "$failures" -ne 0 ]; then
    printf '\n%s test(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nall prevent-public-push tests passed\n'
