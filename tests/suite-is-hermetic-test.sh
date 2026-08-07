#!/usr/bin/env bash
# Does this suite's answer depend on the environment of whoever runs it?
#
# It did. `GIT_GUARDS_PRIVATE_OWNERS=acme ./tests/no-private-repo-names-test.sh`
# failed 19 assertions, and with the fuller set a consumer might reasonably have
# exported -- an owner list, a visibility, REFUSE_UNKNOWN, a public-repo
# allowance, the two pin bypasses, a push allow-list and a pinned owner -- 285
# assertions failed across five files. Not one of them was a defect in a guard.
# Every one was a case asserting one thing while the caller's environment
# answered another.
#
# That is worse than an ordinary flake, because of WHO hits it. The person most
# likely to export those variables is the person who has just read the README
# and is about to decide whether to adopt these hooks; the suite fails for them
# and passes for the author, and the failure looks like the guards being broken.
#
# Two instruments, because the cheap one cannot cover the expensive suites and
# the expensive one cannot cover them all:
#
#   * every test file must consume tests/hermetic-env.sh -- a static check, so
#     a suite added later without the scrub is caught the day it lands rather
#     than the day somebody exports something
#   * two suites are actually RUN under a polluted environment, and one of them
#     is the one that failed 12 assertions under it
#
# This file scrubs its own environment first, for the same reason as the rest.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$REPO_ROOT/tests/hermetic-env.sh")

failures=0

check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$name" "$want" "$got"
        failures=$((failures + 1))
    fi
}

# ── every test file scrubs ──────────────────────────────────────────────
#
# Named by absence: the list of test files that do NOT mention the scrub. It is
# empty or it names them, which is more use than a count.
unscrubbed=""
for candidate in "$REPO_ROOT"/tests/*.sh "$REPO_ROOT"/tests/*.py; do
    base="$(basename "$candidate")"
    # The scrub itself, and this file, which consumes it above.
    [ "$base" = "hermetic-env.sh" ] && continue
    if ! grep -q 'hermetic-env.sh' "$candidate"; then
        unscrubbed="$unscrubbed $base"
    fi
done
check "every test file consumes tests/hermetic-env.sh" "" "${unscrubbed# }"

# A denominator for that check, because a glob that matched nothing would agree
# with the empty set above and this file would pass having compared nothing.
counted="$(ls "$REPO_ROOT"/tests/*.sh "$REPO_ROOT"/tests/*.py 2>/dev/null | wc -l | tr -d ' ')"
if [ "$counted" -ge 5 ]; then
    printf 'ok   read %s test file(s) to check\n' "$counted"
else
    printf 'FAIL read only %s test file(s), which is not the suite\n' "$counted"
    failures=$((failures + 1))
fi

# ── and two of them are run to prove it ─────────────────────────────────
#
# The static check above says a file mentions the scrub, not that the scrub
# works. These two are the cheapest suites that measurably failed without it --
# git-guards-scope-test.sh by 3 assertions, prevent-public-push-test.sh by 12 --
# and together they cost about a second and a half.
#
# The values are the ones the README tells a consumer to export. PRE_COMMIT_TO_REF
# is the sharp one: it is what a hook runner exports at pre-push, so it is what
# a suite run from inside somebody's own push would inherit, and it makes the
# scope resolver answer about THAT push instead of the fixture under test.
polluted() {
    env \
        GIT_GUARDS_PRIVATE_OWNERS=acme \
        GIT_GUARDS_REPO_VISIBILITY=public \
        GIT_GUARDS_REFUSE_UNKNOWN=1 \
        GIT_GUARDS_PUBLIC_REPOS=acme/anything \
        GIT_GUARDS_ALLOW_STALE_PINS=1 \
        GIT_GUARDS_ALLOW_UNCHECKED_PINS=1 \
        WORKSPACE_ALLOW_UNSAFE_PUSH=1 \
        WORKSPACE_ALLOWED_PUSH_OWNERS=somebody-else \
        WORKSPACE_PINNED_OWNER=somebody-else \
        PRE_COMMIT_TO_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        "$@"
}

for suite in git-guards-scope-test.sh prevent-public-push-test.sh; do
    status=0
    output="$(polluted "$REPO_ROOT/tests/$suite" 2>&1)" || status=$?
    if [ "$status" -eq 0 ]; then
        printf 'ok   %s passes with the guards'"'"' own variables exported\n' "$suite"
    else
        printf 'FAIL %s failed (exit %s) with the guards'"'"' own variables exported\n' \
            "$suite" "$status"
        printf '%s\n' "$output" | grep '^FAIL' | head -5
        failures=$((failures + 1))
    fi
done

if [ "$failures" -ne 0 ]; then
    printf '\n%s hermeticity test(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall hermeticity tests passed\n'
