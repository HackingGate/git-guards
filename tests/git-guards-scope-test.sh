#!/usr/bin/env bash
# Behaviour tests for git-guards-scope.sh, the shared answer to "which bytes is
# this operation actually introducing".
#
# It has its own file because it is now the single point of failure for two
# guards. Before it existed each of them answered the question for itself and
# both answered it wrong -- one followed symlinks to somebody else's bytes, both
# read the working tree at pre-push -- and the sum of their suites could not go
# red on any of it. A shared answer with no instrument of its own would just be
# the same arrangement with fewer places to look.
#
# Everything here is offline and needs no forge: the resolver asks git and
# nothing else.
set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Hermetic against the caller's environment. tests/hermetic-env.sh names every
# variable a git-guards test must not inherit and why; the loop is here rather
# than there because unsetting has to happen in THIS shell.
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$repo_root/tests/hermetic-env.sh")

scope="$repo_root/git-guards-scope.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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

check_status() {
    local name="$1" want="$2"
    shift 2
    local status=0
    "$@" >/dev/null 2>&1 || status=$?
    check "$name" "$want" "$status"
}

new_repo() {
    local dir="$1"
    rm -rf "$dir"
    git init -q -b main "$dir"
    git -C "$dir" config user.email t@example.test
    git -C "$dir" config user.name T
    git -C "$dir" config commit.gpgsign false
}

# Entries arrive NUL-terminated so a path may hold anything a path may hold.
# Rendered one per line here, which is the only place in this repository that is
# safe to do -- a test may assume its own fixtures have ordinary names.
entries_of() {
    "$scope" --entries "$1" 2>/dev/null | tr '\0' '\n'
}

project="$work/project"
new_repo "$project"
printf 'placeholder\n' > "$project/keep.md"
mkdir -p "$project/sub/deep"
printf 'inner\n' > "$project/sub/deep/inner.md"
git -C "$project" add -A
git -C "$project" commit -q -m base

cd "$project"

# ── which scope ─────────────────────────────────────────────────────────
#
# The index, unless a push says otherwise. It is the tree the next commit will
# have, which makes it right at pre-commit and at pre-merge-commit, and equal to
# HEAD in a checkout CI has just made -- so one answer covers three stages, which
# matters because a runner does not tell a hook which stage it is at.
check "a work tree with no push declared resolves to the index" \
    ":index" "$("$scope" --scopes | cut -f1)"

check "...and the label says so, for a report that has to name what it read" \
    "the index, which is the tree this commit would have" \
    "$("$scope" --scopes | cut -f2)"

# `git ls-files`, `git ls-tree -r` and `git grep` all list from the CURRENT
# directory down -- ls-tree included, which is the surprising one, and it renames
# what it prints to be relative to that directory too. A scope enumerated from a
# subdirectory is a different scope wearing the same name, and it reports a
# denominator and exits 0 like any other.
check "a scan started in a subdirectory still covers the whole tree" \
    "keep.md sub/deep/inner.md" \
    "$(cd "$project/sub/deep" && entries_of :index | cut -f2 | paste -sd' ' -)"

head_sha="$(git rev-parse HEAD)"

check "a declared push resolves to the commit being pushed" \
    "$head_sha" "$(PRE_COMMIT_TO_REF="$head_sha" "$scope" --scopes | cut -f1)"

# pre-commit's older spelling of the same value, still exported beside the new
# one. A resolver that reads only one name works under one runner and not the
# other, and the two runners are both supported here.
check "PRE_COMMIT_SOURCE names the pushed commit too" \
    "$head_sha" "$(PRE_COMMIT_SOURCE="$head_sha" "$scope" --scopes | cut -f1)"

# A local sha of all zeros is git saying a ref is being DELETED. No bytes are
# introduced by one, so there is no commit to scan and the index is the answer
# again -- rather than a refusal, which would fail a push nobody should have to
# think about.
check "a ref being deleted falls back to the index" \
    ":index" \
    "$(PRE_COMMIT_TO_REF=0000000000000000000000000000000000000000 "$scope" --scopes | cut -f1)"

# A sha a runner named and this repository cannot resolve is refused rather than
# fallen back on. Falling back would scan the index -- a different tree, quite
# possibly a clean one -- and report on it under the push's name, which is the
# substitution the whole file exists to stop.
check_status "an unresolvable pushed sha is refused, not substituted" 2 \
    env PRE_COMMIT_TO_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$scope" --scopes

# Not a work tree at all: no index to read and no HEAD to fall back to. Exit 2,
# because "could not work out what to read" is not "there was nothing to read",
# and printing an empty list here is how the callers used to report a clean tree.
mkdir -p "$work/nowhere"
check_status "outside a repository it refuses rather than printing nothing" 2 \
    env -C "$work/nowhere" "$scope" --scopes

check_status "an unknown argument is refused" 2 "$scope" --whatever
check_status "no argument is refused" 2 "$scope"
check_status "--entries with no token is refused" 2 "$scope" --entries
check_status "--entries with a token that is not a tree is refused" 2 \
    "$scope" --entries not-a-rev
check_status "--messages with no token is refused" 2 "$scope" --messages

# An ANNOTATED TAG is a different object from the commit it names, and a push of
# one is a push of that object. The resolver peels it with `^{commit}`, so the
# tree scanned is the tree the tag publishes -- which is the half of the tag
# story that IS covered, and worth an instrument so the boundary stated in the
# README stays exact rather than alarming. The tag's own MESSAGE is the half
# nothing can reach: git has no tag-message hook type.
git -C "$project" tag -a -m 'a tag message no hook will ever read' v-scope-test
tag_object="$(git -C "$project" rev-parse v-scope-test)"
check "an annotated tag is not its own commit" \
    "tag" "$(git -C "$project" cat-file -t "$tag_object")"
check "...and a push of one resolves to the commit it points at" \
    "$head_sha" "$(PRE_COMMIT_TO_REF="$tag_object" "$scope" --scopes | cut -f1)"

# ── what a push publishes besides a tree ────────────────────────────────
#
# A commit is a tree AND a message. The message is checked by a commit-msg hook,
# which runs when `git commit` writes one -- and `git commit-tree`, a rebase, a
# cherry-pick, `git am`, `--no-verify` and a fast-forward from a hookless clone
# all make a commit without that happening. Everything below uses --no-verify
# for exactly that reason.
messages="$work/messages"
new_repo "$messages"
git -C "$messages" remote add origin "$work/nowhere.git"
printf 'one\n' > "$messages/f.md"
git -C "$messages" add f.md
git -C "$messages" commit -q --no-verify -m 'first subject'
msg_base="$(git -C "$messages" rev-parse HEAD)"
printf 'two\n' >> "$messages/f.md"
git -C "$messages" commit -q --no-verify -am 'second subject'
printf 'three\n' >> "$messages/f.md"
git -C "$messages" commit -q --no-verify -am 'third subject'
msg_tip="$(git -C "$messages" rev-parse HEAD)"

# NUL-terminated `SHA<TAB>MESSAGE`, the same shape --entries uses, because a
# message holds newlines and blank lines by construction and any line-based
# rendering of one is a rendering of something else. Rendered one per line here,
# which only a test may do, and only about fixtures whose messages it wrote.
check "the range is what the push ADDS, not the whole history" \
    "third subject second subject" \
    "$(cd "$messages" && PRE_COMMIT_TO_REF="$msg_tip" PRE_COMMIT_FROM_REF="$msg_base" \
        "$scope" --messages "$msg_tip" | tr '\0' '\n' | cut -f2 | grep . | paste -sd' ' -)"

# A NEW remote ref exports no FROM at all -- measured under prek 0.3.12, which
# exports nothing rather than git's all-zeros. Everything the named remote does
# not already hold, which for a clone with no tracking refs is the whole history
# of the tip: too much rather than too little, which is the direction to err in.
check "...and a new remote ref falls back to everything the remote lacks" \
    "third subject second subject first subject" \
    "$(cd "$messages" && PRE_COMMIT_TO_REF="$msg_tip" PRE_COMMIT_REMOTE_NAME=origin \
        "$scope" --messages "$msg_tip" | tr '\0' '\n' | cut -f2 | grep . | paste -sd' ' -)"

# The index is a commit that does not exist yet: its message is the commit-msg
# guards' business at the moment it is written, and there is nothing here to
# hand over. Empty output and exit 0, which is an answer -- not exit 2, which
# would fail every pre-commit run in every repository.
check "the index publishes no message" \
    "" "$(cd "$messages" && "$scope" --messages :index | tr -d '\0')"
check_status "...and says so by exiting 0, not by refusing" 0 \
    env -C "$messages" "$scope" --messages :index

# A sha the runner named as what the remote already holds and this repository
# cannot resolve is refused, for the reason an unresolvable TO is refused:
# falling back would scan a DIFFERENT range and report on it under this push's
# name.
check_status "an unresolvable FROM is refused, not fallen back on" 2 \
    env -C "$messages" PRE_COMMIT_TO_REF="$msg_tip" \
    PRE_COMMIT_FROM_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
    "$scope" --messages "$msg_tip"

# All-zeros is git's spelling of "the remote has no such ref", and pre-commit
# exports it where prek exports nothing. Both mean the same thing and must be
# read the same way.
check "an all-zeros FROM reads as a new ref, not as a range from nowhere" \
    "third subject second subject first subject" \
    "$(cd "$messages" && PRE_COMMIT_TO_REF="$msg_tip" PRE_COMMIT_REMOTE_NAME=origin \
        PRE_COMMIT_FROM_REF=0000000000000000000000000000000000000000 \
        "$scope" --messages "$msg_tip" | tr '\0' '\n' | cut -f2 | grep . | paste -sd' ' -)"

# ── what a scope holds ──────────────────────────────────────────────────
#
# One shape for the index and for a tree, produced by git's own --format, so
# neither caller has to know which it got. The mode is carried because it is the
# only thing separating the three kinds of entry, and both callers act on all
# three.
printf 'staged only\n' > "$project/staged.md"
git -C "$project" add staged.md

check "the index holds what is staged, committed or not" \
    "keep.md staged.md sub/deep/inner.md" \
    "$(entries_of :index | cut -f2 | paste -sd' ' -)"

check "...and a commit's tree does not" \
    "keep.md sub/deep/inner.md" \
    "$(entries_of "$head_sha" | cut -f2 | paste -sd' ' -)"

git -C "$project" rm -q --cached staged.md
rm -f "$project/staged.md"

# A symlink is a 120000 entry whose blob is the TARGET PATH -- the string, not
# the file it names. Both guards read that blob as content, because it is the
# content: git stores nothing else for a symlink.
ln -s 'sub/deep/inner.md' "$project/ptr"
git -C "$project" add ptr
link_row="$(entries_of :index | grep 'ptr$')"
check "a symlink is a 120000 entry" "120000" "${link_row%% *}"

link_oid="${link_row#* }"
link_oid="${link_oid%% *}"
check "...and its blob is the target path, not the target's content" \
    "sub/deep/inner.md" "$(git -C "$project" cat-file blob "$link_oid")"

# The third metadata field is where the entry CAME FROM. `:tree` is the scope's
# own tree; anything else is the sha of the commit that introduced a blob
# somewhere in the pushed range. The index has no range, so every entry in it is
# a tree entry, and the colon is what keeps that from ever reading as a sha --
# git rejects it in a ref name.
check "an index entry is marked as coming from the tree" \
    ":tree" "$(entries_of :index | grep 'keep.md$' | cut -d' ' -f3 | cut -f1)"

git -C "$project" rm -q --cached ptr
rm -f "$project/ptr"

# A submodule is a 160000 gitlink with no blob in this repository at all, which
# is how a caller knows to skip it rather than trying to read one. Planted with
# update-index rather than by adding a real submodule, because the entry is the
# subject and a second repository would only be scenery.
git -C "$project" update-index --add --cacheinfo "160000,$head_sha,vendored"
check "a submodule is a 160000 gitlink" \
    "160000" "$(entries_of :index | grep 'vendored$' | cut -d' ' -f1)"
git -C "$project" rm -q --cached vendored

# A path is BYTES, and the two scopes have to hand over the same ones.
#
# `git ls-files -z --format` prints a path raw. `git ls-tree -z --format` prints
# the same path QUOTED -- `"src/hel\342\200\213lo.py"`, C-escaped, with the
# quotes in it -- because `%(path)` is rendered through core.quotePath and -z
# does not turn that off for --format the way it does for the plain listing.
# Measured on git 2.47.3.
#
# So the index and the commit being pushed answered differently about the
# identical tree, and the difference is exactly the bytes a name-checking guard
# exists to look at: every non-ASCII codepoint in the name arrives as ASCII
# backslashes and digits. A filename carrying U+200B was refused at the index
# and reported clean at pre-push, with the file counted as scanned.
#
# The assertion is equality between the two scopes rather than a spelling,
# because that is the property both callers rely on and neither can check.
#
# The zero-width space is built from OCTAL escapes and checked against its bytes
# before it is used. Naming the codepoint with a backslash-u escape looks like
# the obvious spelling and is not one: bash resolves that through the current
# locale's charset, and under LC_ALL=C -- a runner with no UTF-8 locale -- it
# emits the escape back as six literal ASCII characters instead. The file would
# then be named in ASCII, this case would still pass, and the only non-ASCII name
# left in the fixture would be the café one: half the property under test gone,
# silently, with no failure anywhere to say so.
nonascii_dir="$work/nonascii"
new_repo "$nonascii_dir"
mkdir -p "$nonascii_dir/src"
zwsp="$(printf '\342\200\213')"
zwsp_bytes="$(printf '%s' "$zwsp" | od -An -tx1 | tr -d ' \n')"
check "the fixture's zero-width space really is U+200B" e2808b "$zwsp_bytes"
nonascii_zwsp_name="src/hel${zwsp}lo.py"
printf 'plain\n' > "$nonascii_dir/$nonascii_zwsp_name"
printf 'plain\n' > "$nonascii_dir/src/caf"$'é'".md"
git -C "$nonascii_dir" add -A
git -C "$nonascii_dir" commit -q -m nonascii
nonascii_head="$(git -C "$nonascii_dir" rev-parse HEAD)"

nonascii_index="$(cd "$nonascii_dir" && "$scope" --entries :index 2>/dev/null | tr '\0' '\n' | cut -f2 | LC_ALL=C sort | paste -sd' ' -)"
nonascii_commit="$(cd "$nonascii_dir" && "$scope" --entries "$nonascii_head" 2>/dev/null | tr '\0' '\n' | cut -f2 | LC_ALL=C sort | paste -sd' ' -)"

check "a commit's paths arrive as the bytes git stored, not git's quoted spelling" \
    "$nonascii_index" "$nonascii_commit"

check "...and those bytes are the name itself, with no escaping in them" \
    "src/caf"$'é'".md $nonascii_zwsp_name" \
    "$nonascii_commit"

# ── what the pushed RANGE introduces ────────────────────────────────────
#
# A push publishes a RANGE and the tree-wide guards read the TIP's tree. A blob
# added in one pushed commit and removed in the next is in the remote's history
# permanently, is in no tip tree, and was read by nothing: measured, two commits
# fast-forwarded in from a hookless clone reached a remote with every hook green
# and no override of any kind.
#
# The tree half is not redundant and the range half is not a superset of it: the
# tree catches what arrived BEFORE this range and is still there, the range
# catches what passed THROUGH it. Both directions are asserted below.
range="$work/range"
new_repo "$range"
git -C "$range" remote add origin "$work/nowhere.git"
printf 'placeholder\n' > "$range/keep.md"
git -C "$range" add keep.md
git -C "$range" commit -q -m base
range_base="$(git -C "$range" rev-parse HEAD)"
printf 'transient\n' > "$range/gone.md"
printf 'still here\n' > "$range/stays.md"
git -C "$range" add -A
git -C "$range" commit -q -m 'add both'
range_added="$(git -C "$range" rev-parse HEAD)"
git -C "$range" rm -q gone.md
git -C "$range" commit -q -m 'remove one of them'
range_tip="$(git -C "$range" rev-parse HEAD)"

# Rendered `MODE OID ORIGIN<TAB>PATH`; the path is field 2 of the tab split and
# the origin is the third space-separated word of field 1.
range_entries() {
    (cd "$range" && "$scope" --entries "$range_tip" 2>/dev/null | tr '\0' '\n')
}

check "with no push declared, a commit is still just its own tree" \
    "keep.md stays.md" \
    "$(range_entries | cut -f2 | LC_ALL=C sort | paste -sd' ' -)"

check "a push reads the tree AND every blob the range introduced" \
    "gone.md keep.md stays.md" \
    "$(PRE_COMMIT_TO_REF="$range_tip" PRE_COMMIT_FROM_REF="$range_base" \
        range_entries | cut -f2 | LC_ALL=C sort | paste -sd' ' -)"

# WHICH commit introduced it, because once the file is gone that commit is the
# only thing left for a reader to act on.
check "...and a range entry names the commit that introduced it" \
    "$range_added" \
    "$(PRE_COMMIT_TO_REF="$range_tip" PRE_COMMIT_FROM_REF="$range_base" \
        range_entries | grep 'gone.md$' | cut -d' ' -f3 | cut -f1)"

check "...while an entry the tree holds is still marked as the tree's" \
    ":tree" \
    "$(PRE_COMMIT_TO_REF="$range_tip" PRE_COMMIT_FROM_REF="$range_base" \
        range_entries | grep 'stays.md$' | cut -d' ' -f3 | cut -f1)"

# The dedup, and it is the reason the range half is affordable. `stays.md` is
# introduced by the same commit and survives to the tip: the tree names it and
# the range must not name it again.
check "a blob the range introduced and the tree still holds is listed once" \
    "1" \
    "$(PRE_COMMIT_TO_REF="$range_tip" PRE_COMMIT_FROM_REF="$range_base" \
        range_entries | grep -c 'stays.md$')"

# ...and the key is the (OID, PATH) PAIR, not the oid. An entry is TWO pieces of
# committed text and only one of them is the blob: a file added under one name
# and renamed under the next commit publishes BOTH names permanently, and the
# blob is byte-identical at each. Keying on the oid alone would drop the first
# name from the scan -- which is a path-shaped finding lost to a dedup meant to
# save a read.
renamed="$work/renamed"
new_repo "$renamed"
printf 'placeholder\n' > "$renamed/keep.md"
git -C "$renamed" add keep.md
git -C "$renamed" commit -q -m base
renamed_base="$(git -C "$renamed" rev-parse HEAD)"
mkdir -p "$renamed/acme-hidden" "$renamed/docs"
printf 'the very same bytes\n' > "$renamed/acme-hidden/notes.md"
git -C "$renamed" add -A
git -C "$renamed" commit -q -m 'added under one name'
git -C "$renamed" mv acme-hidden/notes.md docs/notes.md
git -C "$renamed" commit -q -m 'and renamed under the next'
renamed_tip="$(git -C "$renamed" rev-parse HEAD)"

check "the fixture renames rather than rewrites, so the blob is one object" \
    "same" \
    "$(cd "$renamed" &&
        if [ "$(git rev-parse "$renamed_tip:docs/notes.md")" = \
            "$(git rev-parse "$renamed_tip~1:acme-hidden/notes.md")" ]; then
            printf same
        else printf different; fi)"

check "a blob at two paths is listed under both, however identical the bytes" \
    "acme-hidden/notes.md docs/notes.md keep.md" \
    "$(cd "$renamed" && PRE_COMMIT_TO_REF="$renamed_tip" PRE_COMMIT_FROM_REF="$renamed_base" \
        "$scope" --entries "$renamed_tip" 2>/dev/null | tr '\0' '\n' |
        cut -f2 | LC_ALL=C sort | paste -sd' ' -)"

# The other direction, which is what makes "both halves" a claim rather than a
# preference: a name that arrived before this range is in no diff over it. Only
# the TREE can catch that one, and a range-only scan would have been the same
# defect facing the other way.
check "a blob that arrived before the range is still read, from the tree" \
    "keep.md" \
    "$(PRE_COMMIT_TO_REF="$range_tip" PRE_COMMIT_FROM_REF="$range_base" \
        range_entries | cut -f2 | grep '^keep.md$')"

check "a new remote ref, with no FROM, still reads the whole range" \
    "gone.md keep.md stays.md" \
    "$(PRE_COMMIT_TO_REF="$range_tip" PRE_COMMIT_REMOTE_NAME=origin \
        range_entries | cut -f2 | LC_ALL=C sort | paste -sd' ' -)"

# A ROOT COMMIT prints nothing under `git diff-tree` unless it is asked with
# `--root`, so the first push of a brand-new repository would have its first
# commit unread. Only a blob the root ADDED and a later commit REMOVED can show
# that: one that survives to the tip is in the tip's tree and would be read
# either way, which is why the fixture is its own repository rather than a line
# added to the one above.
rooted="$work/rooted"
new_repo "$rooted"
git -C "$rooted" remote add origin "$work/nowhere.git"
printf 'placeholder\n' > "$rooted/keep.md"
printf 'in the first commit only\n' > "$rooted/root-only.md"
git -C "$rooted" add -A
git -C "$rooted" commit -q -m 'the root commit'
git -C "$rooted" rm -q root-only.md
git -C "$rooted" commit -q -m 'and it is gone'
rooted_tip="$(git -C "$rooted" rev-parse HEAD)"

check "a blob the ROOT commit introduced and no tree holds is still read" \
    "keep.md root-only.md" \
    "$(cd "$rooted" && PRE_COMMIT_TO_REF="$rooted_tip" PRE_COMMIT_REMOTE_NAME=origin \
        "$scope" --entries "$rooted_tip" 2>/dev/null | tr '\0' '\n' |
        cut -f2 | LC_ALL=C sort | paste -sd' ' -)"

# A file REPLACED BY A SYMLINK is a type change, which git spells `T` and
# `--diff-filter=AM` drops. The blob dropped with it is the symlink's target
# path -- committed text both guards read, and one of the two shapes this
# repository has already been caught reporting clean.
typechange="$work/typechange"
new_repo "$typechange"
printf 'plain\n' > "$typechange/swap"
git -C "$typechange" add swap
git -C "$typechange" commit -q -m base
type_base="$(git -C "$typechange" rev-parse HEAD)"
rm -f "$typechange/swap"
ln -s 'acme/hidden-repo' "$typechange/swap"
git -C "$typechange" add swap
git -C "$typechange" commit -q -m 'file becomes a symlink'
printf 'plain again\n' > "$typechange/other.md"
git -C "$typechange" rm -q swap
git -C "$typechange" add -A
git -C "$typechange" commit -q -m 'and the symlink goes'
type_tip="$(git -C "$typechange" rev-parse HEAD)"

check "a file replaced by a symlink is a type change, and its blob is read" \
    "120000" \
    "$(cd "$typechange" && PRE_COMMIT_TO_REF="$type_tip" PRE_COMMIT_FROM_REF="$type_base" \
        "$scope" --entries "$type_tip" 2>/dev/null | tr '\0' '\n' |
        grep 'swap$' | grep -v ':tree' | cut -d' ' -f1)"

# ── which parent a MERGE is diffed against ──────────────────────────────
#
# git prints NOTHING for a merge by default, which would be the same silence
# this scan exists to end. The answer is the FIRST parent: every other parent is
# itself in the range and answers for its own side, so a first-parent walk that
# leaves the range leaves it into what the remote already holds.
#
# Both halves are asserted. A blob the merge itself introduced -- an "evil
# merge", in neither parent -- is caught by the first-parent diff. A blob added
# and removed on the SIDE branch is caught by the side commits' own diffs, which
# is why diffing a merge against its other parents as well would read more and
# find nothing further.
#
# The evil blob is REMOVED again by a commit after the merge, and that is the
# whole design of the fixture: a blob a merge introduces and the tip still holds
# is in the tip's tree, so it would be read whatever the merge did.
merged="$work/merged"
new_repo "$merged"
printf 'placeholder\n' > "$merged/keep.md"
git -C "$merged" add keep.md
git -C "$merged" commit -q -m base
merge_base="$(git -C "$merged" rev-parse HEAD)"
git -C "$merged" checkout -q -b side
printf 'side transient\n' > "$merged/side-gone.md"
git -C "$merged" add side-gone.md
git -C "$merged" commit -q -m 'side adds a file'
git -C "$merged" rm -q side-gone.md
git -C "$merged" commit -q -m 'side removes it again'
git -C "$merged" checkout -q main
printf 'trunk\n' > "$merged/trunk.md"
git -C "$merged" add trunk.md
git -C "$merged" commit -q -m 'trunk moves on'
git -C "$merged" merge -q --no-ff side -m 'merge side' >/dev/null
printf 'never on either side\n' > "$merged/evil.md"
git -C "$merged" add evil.md
git -C "$merged" commit -q --amend --no-edit >/dev/null
merge_commit="$(git -C "$merged" rev-parse HEAD)"
git -C "$merged" rm -q evil.md
git -C "$merged" commit -q -m 'and the resolution is undone'
merge_tip="$(git -C "$merged" rev-parse HEAD)"

check "the fixture's merge really is one, and its blob is in neither parent" \
    "2 parents, 0 parent(s) holding it" \
    "$(cd "$merged" &&
        parents="$(git rev-parse "$merge_commit^@")"
        held=0
        for parent in $parents; do
            git cat-file -e "$parent:evil.md" 2>/dev/null && held=$((held + 1))
        done
        printf '%s parents, %s parent(s) holding it' \
            "$(printf '%s\n' "$parents" | grep -c .)" "$held")"

merged_entries="$(cd "$merged" && PRE_COMMIT_TO_REF="$merge_tip" \
    PRE_COMMIT_FROM_REF="$merge_base" "$scope" --entries "$merge_tip" 2>/dev/null |
    tr '\0' '\n' | cut -f2 | LC_ALL=C sort | paste -sd' ' -)"

check "a merge is diffed against its first parent, so its own resolution is read" \
    "evil.md keep.md side-gone.md trunk.md" "$merged_entries"

# git's own default, stated as a measurement rather than as a claim: without an
# instruction about merges it prints nothing for one at all, which is the
# silence this half of the scan exists to end.
check "...and git's own default for a merge is to print nothing" \
    "" "$(cd "$merged" && git diff-tree -r --no-commit-id --diff-filter=AMT -z "$merge_commit" | tr -d '\0')"

# ── an index that is not a tree ─────────────────────────────────────────
#
# An index holding conflict stages is not a tree any commit could have, so there
# is no single answer to give about it, and answering with the stage-2 side --
# or with all three -- would be answering a question nobody asked. git runs no
# hook mid-conflict, so this is a person running a scan by hand in the middle of
# a merge, and telling them so is more use than a number.
conflict="$work/conflict"
new_repo "$conflict"
printf 'base\n' > "$conflict/f.md"
git -C "$conflict" add f.md
git -C "$conflict" commit -q -m base
git -C "$conflict" checkout -q -b other
printf 'theirs\n' > "$conflict/f.md"
git -C "$conflict" commit -q -am theirs
git -C "$conflict" checkout -q main
printf 'ours\n' > "$conflict/f.md"
git -C "$conflict" commit -q -am ours
git -C "$conflict" merge other >/dev/null 2>&1 || true

status=0
output="$(cd "$conflict" && "$scope" --entries :index 2>&1)" || status=$?
if [ "$status" -eq 2 ] && [[ "$output" == *"unmerged"* ]]; then
    printf 'ok   %s\n' "an unmerged index is refused, not reported as a tree"
else
    printf 'FAIL %s (expected exit 2 saying unmerged, got %s)\n%s\n' \
        "an unmerged index is refused, not reported as a tree" "$status" "$output"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%s scope test(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall git-guards-scope tests passed\n'
