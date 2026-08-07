#!/usr/bin/env bash
# Does the README describe the hooks this repository actually publishes?
#
# .pre-commit-hooks.yaml is what a consumer gets; the README table is what they
# read before getting it. Nothing keeps the two in step, and they drift in the
# direction that is hardest to notice: the manifest is edited because a stage
# was wrong, the table keeps the old answer, and the documentation goes on
# describing a hook that is no longer registered where it says.
#
# That drift has no other instrument. Every hook passes when it is run, so a
# README naming the wrong stage produces no failure anywhere -- it produces
# somebody wiring `pre-commit` for a hook published at `pre-push`, finding it
# never fires, and concluding the guard does not work.
#
# So the id set and the stage list are compared, both directions:
#
#   * every published id appears in the table -- otherwise a hook ships
#     undocumented, and an undocumented hook is one nobody installs
#   * every table row names a published id -- otherwise the table advertises
#     something that is not there
#   * the stages agree exactly
#
# Only what is mechanically checkable is checked here. Whether a `purpose` cell
# is TRUE is not something a test can decide, and pretending otherwise would be
# the false green this file exists to refuse.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Hermetic against the caller's environment. tests/hermetic-env.sh names every
# variable a git-guards test must not inherit and why; the loop is here rather
# than there because unsetting has to happen in THIS shell.
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$REPO_ROOT/tests/hermetic-env.sh")

readme="$REPO_ROOT/README.md"
hooks_yaml="$REPO_ROOT/.pre-commit-hooks.yaml"
failures=0

check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name"
        printf '     want: %s\n' "$want"
        printf '     got:  %s\n' "$got"
        failures=$((failures + 1))
    fi
}

for required in "$readme" "$hooks_yaml"; do
    if [ ! -f "$required" ]; then
        printf 'FAIL %s is missing, so nothing here was compared\n' "$required"
        exit 1
    fi
done

# The hooks table, and only it. Every other table in the README keys on a
# variable name, a path or an exit code, none of which is spelled as a bare
# lower-case id in backticks -- so the row pattern picks out the hook table
# without needing to know where in the file it sits.
readme_rows="$(awk -F'|' '
    /^\| `[a-z][a-z-]*` \|/ {
        id = $2; stages = $3
        gsub(/[`[:space:]]/, "", id)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", stages)
        print id "\t" stages
    }
' "$readme" | LC_ALL=C sort)"

# The manifest, normalised to the same shape: `stages: [pre-push, manual]`
# becomes `pre-push, manual`, which is how the README spells it.
manifest_rows="$(awk '
    /^- id: /     { id = $3 }
    /^  stages: / {
        line = $0
        sub(/^  stages: \[/, "", line)
        sub(/\]$/, "", line)
        print id "\t" line
    }
' "$hooks_yaml" | LC_ALL=C sort)"

# A denominator, stated rather than assumed. If either reader silently matched
# nothing, every comparison below would agree about the empty set and this file
# would pass having checked nothing at all.
readme_count="$(printf '%s\n' "$readme_rows" | grep -c . || true)"
manifest_count="$(printf '%s\n' "$manifest_rows" | grep -c . || true)"

if [ "$manifest_count" -lt 1 ]; then
    printf 'FAIL read no hooks at all from %s\n' "$hooks_yaml"
    exit 1
fi
if [ "$readme_count" -lt 1 ]; then
    printf 'FAIL read no hook rows at all from the README table\n'
    exit 1
fi
printf 'ok   read %s published hook(s) and %s README row(s)\n' \
    "$manifest_count" "$readme_count"

check "the README table lists exactly the published hooks, with their stages" \
    "$manifest_rows" "$readme_rows"

# Named separately, because the combined diff above says "these differ" and a
# reader still has to work out which half is wrong. These two say it outright.
readme_ids="$(printf '%s\n' "$readme_rows" | cut -f1)"
manifest_ids="$(printf '%s\n' "$manifest_rows" | cut -f1)"

undocumented="$(LC_ALL=C comm -13 <(printf '%s\n' "$readme_ids") \
    <(printf '%s\n' "$manifest_ids") | paste -sd' ' -)"
check "every published hook id appears in the README" "" "$undocumented"

invented="$(LC_ALL=C comm -23 <(printf '%s\n' "$readme_ids") \
    <(printf '%s\n' "$manifest_ids") | paste -sd' ' -)"
check "every README row names a published hook id" "" "$invented"

# ── a stage a guard is not registered at is code it cannot reach ────────
#
# The two tree-wide guards read git-guards-scope.sh, whose answer at a push is
# the COMMIT BEING PUSHED and whose answer everywhere else is the index. A
# caller not registered at pre-push never reaches that branch at all: the code
# is written, tested by the resolver's own suite, and dead from that hook's
# point of view. `prevent-unusual-unicode-in-files` was published at
# `[pre-commit, pre-merge-commit]` for exactly that reason, and a commit
# carrying U+200B rode a `git merge --ff-only` from a hookless clone to a remote
# with no override of any kind -- a fast-forward creates no commit, so
# pre-merge-commit never runs for one, and the push had nothing registered.
#
# `manual` is the second half and it fails the other way: without it CI's
# `--hook-stage manual` ran no file-unicode check whatsoever, which is the run a
# consumer relies on precisely because a local hook may never have been
# installed.
#
# Asserted here rather than left to the table above, because the table compares
# the README to the manifest and would agree perfectly with itself about two
# stages. This is a claim about which stages a tree-wide guard MUST have,
# whatever both documents say.
for tree_wide in no-private-repo-names-in-files prevent-unusual-unicode-in-files; do
    stages="$(printf '%s\n' "$manifest_rows" | awk -F'\t' -v id="$tree_wide" \
        '$1 == id { print $2 }')"
    missing=""
    case "$stages" in *pre-push*) ;; *) missing="pre-push" ;; esac
    case "$stages" in *manual*) ;; *) missing="$missing manual" ;; esac
    check "$tree_wide is registered at pre-push and manual" "" "${missing# }"
done

if [ "$failures" -ne 0 ]; then
    printf '\n%s README/manifest test(s) failed\n' "$failures"
    exit 1
fi
printf '\nall README/manifest tests passed (%s hooks compared)\n' "$manifest_count"
