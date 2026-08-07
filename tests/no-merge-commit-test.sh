#!/usr/bin/env bash
# Behaviour tests for no-merge-commit.sh.
#
# The two states this guard reads are made by running the merges that make them,
# not by writing MERGE_HEAD and SQUASH_MSG into .git by hand. Those files are
# git's business: which one a given merge leaves behind, and whether it leaves
# one at all, is the fact under test, and a fixture that writes them asserts the
# author's belief about git rather than git's behaviour. A conflicting merge and
# a `--squash` merge are what a person actually does here.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Hermetic against the caller's environment. tests/hermetic-env.sh names every
# variable a git-guards test must not inherit and why; the loop is here rather
# than there because unsetting has to happen in THIS shell.
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$repo_root/tests/hermetic-env.sh")

guard="$repo_root/no-merge-commit.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export HOME="$work/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$work/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
printf '[user]\n\tname = T\n\temail = t@example.test\n' > "$GIT_CONFIG_GLOBAL"

failures=0

expect() {
    local name="$1" expected="$2" dir="$3" needle="${4:-}"
    local status=0 output matched=yes
    output="$(cd "$dir" && bash "$guard" 2>&1)" || status=$?
    [ -z "$needle" ] || { matched=no; [[ "$output" == *"$needle"* ]] && matched=yes; }

    if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s saying %q, got %s)\n%s\n' \
        "$name" "$expected" "$needle" "$status" "$output"
    failures=$((failures + 1))
}

# A repository with two branches that both touch the same line, so a merge of
# one into the other conflicts and stops -- leaving MERGE_HEAD in place, which
# is the state a person is in when they type `git commit` next.
diverged() {
    local dir="$1"
    git init -q -b main "$dir"
    printf 'one\n' > "$dir/f.txt"
    git -C "$dir" add f.txt
    git -C "$dir" commit -q --no-verify -m base
    git -C "$dir" checkout -q -b side
    printf 'side\n' > "$dir/f.txt"
    git -C "$dir" commit -q --no-verify -am side
    git -C "$dir" checkout -q main
    printf 'main\n' > "$dir/f.txt"
    git -C "$dir" commit -q --no-verify -am main
}

# ── an ordinary commit is not a merge ───────────────────────────────────
# The pair that matters: this guard runs at pre-commit, so it runs on EVERY
# commit. If it could not tell an ordinary one apart it would block all of them.
ordinary="$work/ordinary"
diverged "$ordinary"
printf 'more\n' >> "$ordinary/f.txt"
git -C "$ordinary" add f.txt
expect "an ordinary commit is allowed" 0 "$ordinary"

# ── a merge in progress ─────────────────────────────────────────────────
merging="$work/merging"
diverged "$merging"
git -C "$merging" merge --no-ff side >/dev/null 2>&1 || true
if ! git -C "$merging" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    printf 'FAIL %s (the fixture did not produce a merge in progress)\n' \
        "a merge in progress is refused"
    failures=$((failures + 1))
else
    expect "a merge in progress is refused" 1 "$merging" "merge --abort"
fi

# Resolving and finishing the merge is still a merge commit, so the guard must
# not go quiet the moment the conflict is fixed -- MERGE_HEAD is what it reads,
# and it survives the resolution.
printf 'resolved\n' > "$merging/f.txt"
git -C "$merging" add f.txt
expect "...and still refused once the conflict is resolved" 1 "$merging" "merge --abort"

# The state has to be reachable in the other direction too: aborting leaves a
# repository this guard is happy with, or `git merge --abort` is bad advice.
git -C "$merging" merge --abort
expect "...and allowed again after merge --abort" 0 "$merging"

# ── a squash merge in progress ──────────────────────────────────────────
# A different file and a different remedy. `git merge --squash` leaves no
# MERGE_HEAD at all -- it stages the result and writes SQUASH_MSG -- so a guard
# that read only MERGE_HEAD would wave the squash straight through, which is the
# same local merge under another name.
squashing="$work/squashing"
diverged "$squashing"
git -C "$squashing" merge --squash side >/dev/null 2>&1 || true
if git -C "$squashing" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    printf 'FAIL %s (fixture: --squash left MERGE_HEAD, so it proves nothing about SQUASH_MSG)\n' \
        "a squash merge is refused"
    failures=$((failures + 1))
elif [ ! -f "$squashing/.git/SQUASH_MSG" ]; then
    printf 'FAIL %s (the fixture did not produce a squash in progress)\n' \
        "a squash merge is refused"
    failures=$((failures + 1))
else
    expect "a squash merge is refused" 1 "$squashing" "reset --hard HEAD"
fi

git -C "$squashing" reset -q --hard HEAD
rm -f "$squashing/.git/SQUASH_MSG"
expect "...and allowed again once it is reset" 0 "$squashing"

# ── outside a repository ────────────────────────────────────────────────
# Neither state can be established here, and neither is claimed. This asserts
# the hook does not fall over rather than that it has an opinion: `git commit`
# outside a work tree fails on its own account, and a pre-commit hook that
# crashed first would replace git's clear message with a shell error.
mkdir -p "$work/nowhere"
expect "outside a work tree it does not crash" 0 "$work/nowhere"

if [ "$failures" -ne 0 ]; then
    printf '\n%s test(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nall no-merge-commit tests passed\n'
