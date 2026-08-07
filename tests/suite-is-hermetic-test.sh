#!/usr/bin/env bash
# Does this suite's answer depend on the environment of whoever runs it?
#
# Two kinds of dependence, found one after the other. The variables came first
# and are described below. The LOCALE came second, and it was worse, because it
# reached the fixtures rather than the guards: on a machine with no UTF-8 locale
# installed -- an ordinary CI runner -- seven cases in self-commit-test.sh
# failed, and every one of them looked like a broken guard. None was. bash
# renders a backslash-u escape through the current locale's charset and, when
# that charset cannot hold the codepoint, emits the escape back as literal
# ASCII, so the zero-width space those cases plant was never planted and the
# guards were correctly approving a clean message.
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

# ── and no shell fixture is spelled through the locale ─────────────────
#
# A backslash-u escape in a shell script is not a codepoint, it is a REQUEST to
# the current locale for one, and a locale that cannot answer hands back the
# escape as text. So any test that plants a non-ASCII fixture that way plants a
# different fixture on a different machine -- and in the direction that matters,
# an ASCII one, which every guard then correctly passes.
#
# Banned outright rather than inspected case by case. Deciding whether a given
# occurrence is "really" a fixture means parsing shell, and an enforcement rule
# that can be argued with is one that gets argued with. Octal escapes are bytes,
# printf writes them unconverted in every locale, and they cost nothing:
#
#   ZWSP="$(printf '\342\200\213')"
#
# Shell only. Python's escapes of the same shape are resolved by the compiler
# against Unicode itself and never consult a locale, which is why
# prevent-unusual-unicode-in-files-test.py may keep its hundred of them.
#
# This file is scanned along with the rest. A rule that exempts its own enforcer
# is a rule with one guaranteed hole in it.
locale_spelled=""
for candidate in "$REPO_ROOT"/tests/*.sh; do
    # `grep -c` prints a count and exits 1 when that count is zero, so the exit
    # code carries no information and `|| true` costs nothing. An EMPTY answer is
    # a different thing entirely -- grep could not read the file -- and is
    # reported rather than counted as clean, which is the direction an unreadable
    # test file would otherwise fail in.
    hits="$(grep -cE '\\u[0-9a-fA-F]{4}' "$candidate" 2>/dev/null || true)"
    case "$hits" in
        0) continue ;;
        [1-9]*) locale_spelled="$locale_spelled $(basename "$candidate"):$hits" ;;
        *) locale_spelled="$locale_spelled $(basename "$candidate"):unreadable" ;;
    esac
done
check "no test shell script spells a fixture through a backslash-u escape" \
    "" "${locale_spelled# }"

# A denominator for that check, because a glob that matched nothing would agree
# with the empty set above and this file would pass having compared nothing.
counted="$(ls "$REPO_ROOT"/tests/*.sh "$REPO_ROOT"/tests/*.py 2>/dev/null | wc -l | tr -d ' ')"
if [ "$counted" -ge 5 ]; then
    printf 'ok   read %s test file(s) to check\n' "$counted"
else
    printf 'FAIL read only %s test file(s), which is not the suite\n' "$counted"
    failures=$((failures + 1))
fi

# ── and two of them are run in each environment to prove it ────────────
#
# The static checks above say a file mentions the scrub and spells its fixtures
# in bytes. Neither says the suite actually SURVIVES the environment. These two
# are the cheapest suites that measurably failed in one -- git-guards-scope-test.sh
# by 3 assertions under the exported variables, prevent-public-push-test.sh by
# 12 -- and the scope suite is also the one that plants a non-ASCII filename, so
# it is the cheap suite with something to lose under a C locale.
#
# `guard_vars` are the values the README tells a consumer to export.
# PRE_COMMIT_TO_REF is the sharp one: it is what a hook runner exports at
# pre-push, so it is what a suite run from inside somebody's own push would
# inherit, and it makes the scope resolver answer about THAT push instead of the
# fixture under test.
guard_vars=(
    GIT_GUARDS_PRIVATE_OWNERS=acme
    GIT_GUARDS_REPO_VISIBILITY=public
    GIT_GUARDS_REFUSE_UNKNOWN=1
    GIT_GUARDS_PUBLIC_REPOS=acme/anything
    GIT_GUARDS_ALLOW_STALE_PINS=1
    GIT_GUARDS_ALLOW_UNCHECKED_PINS=1
    WORKSPACE_ALLOW_UNSAFE_PUSH=1
    WORKSPACE_ALLOWED_PUSH_OWNERS=somebody-else
    WORKSPACE_PINNED_OWNER=somebody-else
    PRE_COMMIT_TO_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
)

# A machine with no UTF-8 locale installed. LANGUAGE is emptied as well as the
# other two because glibc lets it override LC_MESSAGES on its own, and a variable
# that is only MOSTLY unset is the kind of thing this file exists to refuse.
c_locale=(LC_ALL=C LANG=C LANGUAGE=)

run_under() {
    case "$1" in
        variables) env "${guard_vars[@]}" "$2" 2>&1 ;;
        locale) env "${c_locale[@]}" "$2" 2>&1 ;;
        both) env "${guard_vars[@]}" "${c_locale[@]}" "$2" 2>&1 ;;
    esac
}

for environment in variables locale both; do
    case "$environment" in
        variables) as="with the guards' own variables exported" ;;
        locale) as="on a machine with no UTF-8 locale" ;;
        both) as="with both at once" ;;
    esac
    for suite in git-guards-scope-test.sh prevent-public-push-test.sh; do
        status=0
        output="$(run_under "$environment" "$REPO_ROOT/tests/$suite")" || status=$?
        if [ "$status" -eq 0 ]; then
            printf 'ok   %s passes %s\n' "$suite" "$as"
        else
            printf 'FAIL %s failed (exit %s) %s\n' "$suite" "$status" "$as"
            printf '%s\n' "$output" | grep '^FAIL' | head -5
            failures=$((failures + 1))
        fi
    done
done

# self-commit-test.sh is deliberately NOT run here, and the reason is worth
# stating because it is the suite the locale actually broke. It installs a hook
# runner into a copy and commits, and this file's own hook runs at pre-commit in
# that copy -- so running it from here is a loop that terminates only by running
# out of disk. It is a manual-stage hook, CI runs it, and the runner CI runs it
# on is the machine with no UTF-8 locale. The static check above is what covers
# it here, and covers every suite written after it as well.

if [ "$failures" -ne 0 ]; then
    printf '\n%s hermeticity test(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall hermeticity tests passed\n'
