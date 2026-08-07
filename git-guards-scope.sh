#!/usr/bin/env bash
# Which bytes is this operation actually introducing?
#
# Two guards here scan a whole repository rather than a diff --
# `no-private-repo-names.sh --tracked` and `prevent-unusual-unicode-in-files.py
# --files` -- and each used to answer that question for itself, out of the
# WORKING TREE. Both answers were wrong, in the same direction, for three
# different reasons, and every one of them ends with a green tick over bytes
# nobody looked at:
#
#   * At pre-commit the working tree is not what is being committed. A line
#     staged and then edited away is in the commit and not on disk; a line typed
#     and never staged is on disk and not in the commit. The scan judged the
#     second and missed the first.
#   * At pre-push the working tree is not what is being pushed. Commit a private
#     name on a branch, check out another, push the branch: the file is not even
#     on disk, the guard registered at pre-push exactly to catch a name that got
#     in without passing a hook reads a clean tree, prints Passed, and the name
#     reaches the remote.
#   * A symlink's content is not the file it points at. Git stores the TARGET
#     PATH as the blob, so `ln -s $'t<U+200B>gt' link` commits a zero-width
#     space -- while any reader that follows the link scans some other file's
#     bytes and reports on those instead.
#
# Two guards asking one question two ways is two rules that agree until they do
# not, so the question is answered ONCE, here, and both of them read the answer.
# The rule is:
#
#   THE INDEX, unless a push says otherwise.
#
# The index is the tree the next commit will have, which makes it the right
# artifact at pre-commit and at pre-merge-commit (git has already merged into it
# by the time the hook runs). At the manual stage, in a checkout CI has just
# made, the index is HEAD -- so the same answer covers that stage too without
# needing to know which stage it is, and a runner does not tell a hook its stage.
#
# A push is the one operation with no index at all: what becomes shared is a
# COMMIT, and the working tree beside it may be on a different branch entirely.
# There the artifact is the commit being pushed, and its whole tree PLUS every
# blob the pushed RANGE introduces. The two halves catch different things and
# neither is a superset of the other:
#
#   * THE TIP'S TREE catches what arrived BEFORE this range -- a name committed
#     under --no-verify last month, carried forward by every commit since. No
#     diff over this push names it, because to this push it is not new.
#   * THE RANGE catches what passed THROUGH it. A blob added in one pushed
#     commit and removed in the next is in the remote's history permanently, is
#     in no tip tree, and was read by nothing. Measured: two commits, one adding
#     a file naming a private repository and carrying a zero-width space, the
#     next deleting it, fast-forwarded in from a hookless clone and pushed --
#     every hook green, no override of any kind, and `cat-file` on the remote
#     hands the bytes back afterwards.
#
# They are cheap together because the expensive half -- working out WHICH
# commits are being sent -- is already done for `--messages`, and range_revs
# below is the one place that decides it.
#
# HEAD is the last resort, for a repository with no index to read: a bare clone,
# or a scan pointed at a rev by hand.
#
# ## How a push is recognised
#
# Git hands a pre-push hook its ref updates on STDIN, one line per ref as
# `<local ref> <local sha> <remote ref> <remote sha>`. A hook runner consumes
# that stream itself and re-exports it, and this file reads the runner's
# rendering rather than the stream, because by the time a hook the runner
# launched is running, the stream has already been read by somebody else.
# Measured under prek 0.3.12, a push exports:
#
#   PRE_COMMIT_TO_REF / PRE_COMMIT_SOURCE     the LOCAL sha being pushed
#   PRE_COMMIT_FROM_REF / PRE_COMMIT_ORIGIN   the remote sha, absent for a new branch
#   PRE_COMMIT_REMOTE_NAME, PRE_COMMIT_REMOTE_URL, and the two branch names
#
# pre-commit spells the first pair the same way, and the older names are its
# own. The local sha names the commit whose tree is about to become shared; the
# remote sha narrows that to the range, which is what the commits in it publish
# besides that tree.
#
# STDIN is deliberately not read. Under every other stage the same runner leaves
# a hook's stdin open and empty, so a read would stall each commit for its
# timeout and then learn nothing -- and there is no signal that separates "a
# pre-push stream that has not arrived yet" from "a pre-commit run with nothing
# to say". A guard that costs a second per commit is a guard somebody deletes.
#
# ## What a push publishes besides a tree
#
# A commit is a tree AND a message, and only one of those two was ever read at
# push time. The message is checked by a commit-msg hook, which runs when `git
# commit` makes the commit -- and a commit can be made without that ever
# happening: `git commit-tree`, a rebase, a cherry-pick, `git am`, `--no-verify`,
# or a fast-forward that carries somebody else's commit in from a clone where no
# hook was installed. None of those runs commit-msg, and the pre-push guards read
# the TREE, so a message reaches the remote unread. Measured: two commits carried
# a private repository's name and a zero-width space in their subject lines to a
# remote with every hook green and no override of any kind.
#
# So `--messages` names the third thing a push introduces. WHICH commits, and
# range_revs is the single answer for both it and the range half of `--entries`:
#
#   * the runner names what the remote already has (`PRE_COMMIT_FROM_REF`, or
#     pre-commit's older `PRE_COMMIT_ORIGIN`), and the range is `FROM..TO` --
#     exactly the commits this push adds to that ref.
#   * a NEW or unknown remote ref exports neither, measured under prek 0.3.12,
#     which exports nothing at all rather than git's all-zeros. Then the range is
#     `TO --not --remotes=<remote>`: every commit reachable from the tip being
#     pushed that no OTHER ref of that remote already holds. A remote whose
#     tracking refs this clone has never fetched narrows nothing, so the range
#     degenerates to the whole history of TO -- which is the honest answer for a
#     remote this clone knows nothing about, and errs toward reading too much
#     rather than too little.
#   * a ref being DELETED (an all-zeros local sha) publishes no commit and no
#     message, and neither `--messages` nor the range half prints anything.
#
# `git rev-list` decides what is reachable, so a commit already on the remote
# through some other branch is not read twice.
#
# ## Which blobs the range introduces
#
# `git rev-list` over that same range, into `git diff-tree`, which names the
# blobs each commit adds. Four decisions in that command, each of them reachable:
#
# A MERGE IS DIFFED AGAINST ITS FIRST PARENT (`--diff-merges=first-parent`).
# git's default is to print NOTHING for a merge, which would be the same silence
# this whole scan exists to end. `-m` prints a diff per parent, which reads more
# and covers nothing extra: every other parent is ITSELF in the range and answers
# for its own side. That is the whole argument, and it holds because a commit
# whose first parent has left the range has left it into what the remote already
# holds -- so the walk terminates on published objects or on a root. Note that
# `git diff-tree -m --first-parent` is NOT this: measured on git 2.47.3, the
# `--first-parent` is accepted and ignored, and the parent-2 diff is printed too.
#
# A ROOT COMMIT NEEDS `--root`. Without it git prints nothing for one, so the
# first push of a brand-new repository would have its whole first commit unread
# unless the blobs survived to the tip.
#
# `--diff-filter=AMT`, NOT `AM`. A file REPLACED BY A SYMLINK is a type change,
# and git spells that `T`: `--diff-filter=AM` drops it, and the blob it drops is
# the symlink's target path -- committed text that both guards read, and one of
# the two shapes this repository has already been caught reporting clean.
#
# `--no-renames`, so a record is always one status and one path. Rename detection
# would only re-describe the same blob under two names.
#
# ## What is read twice, and what is not
#
# Deduplicated across the whole union -- the tip's tree included -- so a blob
# touched in ten commits is read once. The key is the (OID, PATH) PAIR and not
# the OID alone, because an entry is two pieces of committed text and only one
# of them is the blob: a file added as `acme/hidden/notes.md` and renamed to
# `docs/notes.md` in the next commit publishes both names, and keying on the OID
# would drop the first. Measured on a 705-commit history the two keys differed by
# one entry in 2177, so the pair costs nothing to prefer.
#
# A GITLINK is keyed on its PATH alone. Its oid is another repository's commit
# and there is no blob here to read twice; its path is the whole of what it
# publishes. Keying it on the oid would make every submodule POINTER BUMP a
# separate entry -- 1385 of those same 2177 records, every one of them a path the
# tip tree already holds, and a skip line apiece in both guards' reports.
#
# A path holding a NEWLINE is never recorded in the index and so is never matched
# by it: the index is newline-joined, such a path cannot be told from two other
# entries in it, and the wrong answer is a blob dropped because its NAME looked
# like something else. Those entries are emitted every time they are seen, which
# costs a re-read and never a miss.
#
# ## What it costs
#
# Measured on a real 705-commit repository, 148 files at its tip, this board.
# "additional" is what survives the deduplication above -- what the range
# published that the tip's tree does not hold:
#
#   push of   1 commit      0 additional   resolver 0.08s   file-unicode scan 0.34s
#   push of  20 commits     0              resolver 0.15s   file-unicode scan 0.41s
#   push of 100 commits   119              resolver 0.19s   file-unicode scan 0.77s
#   push of 300 commits   488              resolver 0.55s   file-unicode scan 1.36s
#   whole history         700              resolver 0.53s   file-unicode scan 1.83s
#
# An ordinary push adds NOTHING, and the reason is worth saying: a commit's
# blobs are usually still in the tip's tree, where they were already being read.
# What the range half costs is proportional to what a push DELETED or REPLACED
# on its way, which is the thing that had no reader at all.
#
# The private-name scan reads the same bytes in the same `git grep` -- 782 blobs
# in 0.20s, against 9.7s to fetch and search them one `git cat-file` at a time --
# but it then asks the forge about every distinct NAME it turned up, and the
# range took that from 180 names to 492 on this repository. That is a cost per
# NAME rather than per blob, its answers are cached, and it is the same cost the
# tree half has always had.
#
# There is no cap. A cap would have to drop commits from the range to be worth
# anything, and a range with commits missing from it is precisely the defect
# above wearing a limit as a disguise. What the number does instead is stay
# visible: both guards report the two halves separately, so a scan that read 148
# paths and 700 more blobs says so.
#
# ## The interface
#
#   git-guards-scope.sh --scopes           one `TOKEN<TAB>LABEL` line per scope
#   git-guards-scope.sh --entries TOKEN    NUL-terminated `MODE OID ORIGIN<TAB>PATH`
#   git-guards-scope.sh --messages TOKEN   NUL-terminated `SHA<TAB>MESSAGE`
#
# A TOKEN is `:index` or a commit sha. The colon is what keeps the two apart:
# git rejects it in a ref name, so no rev can ever be spelled `:index`.
#
# An ORIGIN is `:tree` for an entry the scope's own tree holds, and the sha of
# the commit that introduced it for a blob that only the pushed range holds. The
# same colon keeps those apart, and a caller needs the distinction twice over: a
# range blob is at no path in the tree being pushed, so a reader that locates
# findings by path cannot locate one in it -- and a report that cannot say how
# many of its files came from each half is back to one number for two questions.
#
# `--messages` prints NOTHING, and exits 0, for any scope that is not a push:
# there is no commit at `:index`, and the HEAD fallback is a scan somebody
# pointed at a repository rather than an operation publishing anything.
#
# The LABEL is for a report. A scan whose denominator is a whole repository has
# to be able to say WHICH repository-shaped thing it read, because "25 files
# scanned" is the same sentence whether it read the commit being pushed or a
# checkout of something else.
#
# ## Two boundaries, stated rather than worked around
#
# BOUNDARY A: A MULTI-REF PUSH IS JUDGED ON ONE REF. `--scopes` prints a LIST
# though it prints one line today, and that one line is the whole of what this
# file can know. A push is plural in git's own protocol -- one line per ref on
# the hook's stdin, and `git push --all` sends many -- but prek 0.3.12 exports a
# single PRE_COMMIT_TO_REF pair, and its shim has already consumed git's
# ref-update stream, so the stream cannot be re-read here to recover the rest.
# Measured: `git push origin clean1 dirty1` exports clean1 and publishes both.
# Callers loop, so a runner that starts forwarding every ref needs no change
# beyond this file -- but until one does, the guard covers ONE ref per push.
# Push one ref at a time, or run the manual stage in CI over the whole tree.
#
# BOUNDARY B: AN ANNOTATED TAG'S MESSAGE IS NEVER SCANNED. git has no
# tag-message hook type at all, so `git tag -a -m '...'` reaches nothing here and
# nothing anywhere else in this repository. Check one before cutting it with
# `no-private-repo-names.sh --text`. What IS covered: resolve_commit below peels
# a tag with `^{commit}`, so pushing a tag that points at a dirty tree scans that
# tree exactly as pushing the branch would -- measured, and refused with the
# finding named. A tag pointing at a commit the remote already holds introduces
# no bytes, and prek starts no hook for one, which is the answer a second push of
# an unchanged branch also gets. It is the tag's own message, and only that,
# which no hook can reach.
#
# Tree entries are emitted with git's own `--format`, so the shape is identical
# for the index and for a tree and neither caller has to know which produced it.
# That needs git 2.38 or newer; an older git rejects the option and this script
# exits 2 rather than parsing something else's output as though it were this.
# `--diff-merges=first-parent` needs 2.31, which the same floor covers.
#
# The mode is carried because it is the only thing that distinguishes the three
# kinds of entry a tree holds, and the callers act on all three: 100644/100755 a
# file, 120000 a SYMLINK whose blob is the target path, 160000 a submodule
# gitlink with no blob in this repository at all.
#
# Every failure here is exit 2, never exit 1 and never a silent empty list.
# "Could not work out what to read" is not "there was nothing to read", and the
# whole reason both callers now share this file is that the second sentence was
# being printed for the first.
set -euo pipefail

fail() {
    printf 'git-guards-scope: %s\n' "$1" >&2
    exit 2
}

usage() {
    printf 'usage: git-guards-scope.sh --scopes\n' >&2
    printf '       git-guards-scope.sh --entries <token>\n' >&2
    printf '       git-guards-scope.sh --messages <token>\n' >&2
    exit 2
}

# Everything below reads from the top of the work tree, and it is not a tidy-up.
# `git ls-files`, `git ls-tree -r` and `git grep` all list from the CURRENT
# directory down -- ls-tree included, which is the surprising one, and it also
# renames what it prints to be relative to that directory. A scope enumerated
# from a subdirectory is therefore a different scope with the same name, and it
# reports a denominator and exits 0 like any other. A hook runner happens to
# invoke from the root; a person running a scan by hand does not.
if toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$toplevel" ]; then
    cd "$toplevel" || fail "cannot enter the work tree at $toplevel"
fi

# A local sha of all zeros is git's way of saying a ref is being DELETED. There
# is no tree to scan for one, and no bytes are being introduced by it.
is_zero_sha() { [[ "$1" =~ ^0+$ ]]; }

resolve_commit() {
    git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null
}

# The local sha a runner says is being pushed, or nothing at all. Both spellings
# are read because both are in use: `PRE_COMMIT_TO_REF` is what prek and current
# pre-commit export, `PRE_COMMIT_SOURCE` is pre-commit's older name for the same
# value and is still exported beside it.
pushed_sha() {
    local to="${PRE_COMMIT_TO_REF:-}"
    [ -n "$to" ] || to="${PRE_COMMIT_SOURCE:-}"
    [ -n "$to" ] && ! is_zero_sha "$to" && printf '%s' "$to"
}

print_scopes() {
    local to sha

    to="$(pushed_sha || true)"
    if [ -n "$to" ]; then
        # A sha a runner named and this repository cannot resolve is refused
        # rather than fallen back on. Falling back would scan the index -- a
        # different artifact, quite possibly a clean one -- and report on it
        # under the push's name, which is the substitution this whole file
        # exists to stop.
        sha="$(resolve_commit "$to")" ||
            fail "the runner named $to as the commit being pushed, and this repository cannot resolve it"
        printf '%s\tthe commit being pushed, %s\n' "$sha" "${sha:0:12}"
        return
    fi

    if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ]; then
        printf ':index\tthe index, which is the tree this commit would have\n'
        return
    fi

    sha="$(resolve_commit HEAD)" ||
        fail 'no push was declared, there is no work tree to read an index from, and HEAD names no commit'
    printf '%s\tHEAD, %s\n' "$sha" "${sha:0:12}"
}

#: An entry the scope's own tree holds. The header says why the origin is
#: carried; the colon is what keeps it from ever being read as a commit sha.
TREE_ORIGIN=':tree'

#: One record shape, `MODE OID ORIGIN<TAB>PATH`, built from git's CLASSIC `-z`
#: listings rather than from `--format`.
#:
#: `--format` is the obvious way to ask for exactly these fields, and it is the
#: wrong one, because `%(path)` renders through `core.quotePath` while a classic
#: `-z` listing is documented to emit the path verbatim. That difference is not
#: cosmetic for these guards: a path is BYTES, and the whole question one of
#: them asks is which characters a name holds. A name replaced by a spelling of
#: itself -- backslashes and octal digits -- cannot hold any of them.
#:
#: Measured on git 2.47.3, one tree, one moment, names holding U+00E9 and U+200B:
#:
#:   git ls-files -z --format=...    ->  src/hel<U+200B>lo.py
#:   git ls-tree -r -z --format=...  ->  "src/hel\342\200\213lo.py"
#:
#: so the index and the commit being pushed answered differently about the same
#: tree. A filename carrying U+200B was refused at the index and reported clean
#: at pre-push -- counted as scanned, exit 0 -- and the branch reached the
#: remote.
#:
#: The first fix for that was `-c core.quotePath=false` on both commands, which
#: reconciles them on 2.47.3 and DOES NOT on 2.54.0, where CI caught it. That is
#: the lesson worth keeping: a per-version workaround for a formatting question
#: is the wrong shape when a format that never quotes already exists. The
#: classic listings carry every field needed here, in different positions, and
#: normalising those positions is a fixed cost paid once:
#:
#:   git ls-files -s -z       ->  MODE OID STAGE<TAB>PATH
#:   git ls-tree -r -z <rev>  ->  MODE TYPE OID<TAB>PATH
#:
#: It also drops the git 2.38 floor that `--format` imposed.
#:
#: The split is on the FIRST tab only, because a path may hold tabs, spaces and
#: newlines, and the metadata git puts before that tab never does.
normalise_entries() {
    local field="$1" rec meta path mode oid
    while IFS= read -r -d '' rec; do
        meta="${rec%%$'\t'*}"
        path="${rec#*$'\t'}"
        mode="${meta%% *}"
        meta="${meta#* }"
        if [ "$field" = 'stage' ]; then
            oid="${meta%% *}"
        else
            oid="${meta#* }"
        fi
        printf '%s %s %s\t%s\0' "$mode" "$oid" "$TREE_ORIGIN" "$path"
    done
}

#: Belt and braces for the one command still asked for a formatted listing.
#: `diff-tree -r -z` emits raw output whose paths are already verbatim, so this
#: changes nothing today -- it is here so that a future edit reaching for
#: `--format` on that command does not silently reintroduce the quoting defect
#: the listings above were rewritten to eliminate.
QUOTE_OFF=(-c core.quotePath=false)

# WHICH commits this operation publishes, as arguments for `git rev-list` and
# `git log`. ONE answer, read by `--messages` and by the range half of
# `--entries`: two readers working the range out separately would be two ranges,
# agreeing until they did not, and "which bytes is this operation introducing"
# would have two answers again.
#
# Prints one argument per line. Exits 0 when there is a range, 1 when this scope
# publishes no commit at all -- the index, a deleted ref, or a scan somebody
# pointed at a rev by hand -- and 2, through fail, when a sha the runner named
# cannot be resolved. Callers must tell 1 from 2: the first is an answer and the
# second is a refusal.
range_revs() {
    local scope="$1" to from from_sha remote

    [ "$scope" != ':index' ] || return 1
    to="$(pushed_sha || true)"
    [ -n "$to" ] || return 1

    from="${PRE_COMMIT_FROM_REF:-}"
    [ -n "$from" ] || from="${PRE_COMMIT_ORIGIN:-}"

    if [ -n "$from" ] && ! is_zero_sha "$from"; then
        # Refused rather than fallen back on, for the reason print_scopes
        # refuses an unresolvable TO: falling back would scan a DIFFERENT range
        # and report on it under this push's name.
        from_sha="$(resolve_commit "$from")" ||
            fail "the runner named $from as what the remote already holds, and this repository cannot resolve it"
        printf '%s..%s\n' "$from_sha" "$scope"
        return 0
    fi

    # No FROM at all: a ref the remote does not have yet, or a runner that does
    # not say. Everything reachable from the tip that no other ref of the same
    # remote already holds -- and the whole history of the tip when this clone
    # has no tracking refs to narrow it by, which reads too much rather than too
    # little.
    remote="${PRE_COMMIT_REMOTE_NAME:-}"
    printf '%s\n--not\n' "$scope"
    if [ -n "$remote" ]; then
        printf -- '--remotes=%s\n' "$remote"
    else
        printf -- '--remotes\n'
    fi
}

#: The range for this scope, one argument per element, or empty for a scope that
#: publishes no commit. Filled by read_range_revs, which is a function rather
#: than a command substitution because a `fail` inside one exits the subshell and
#: leaves the caller running.
range_args=()

read_range_revs() {
    local scope="$1" text status=0 line
    range_args=()
    text="$(range_revs "$scope")" || status=$?
    # 2 is range_revs refusing outright. Its own account is already on stderr.
    [ "$status" -ne 2 ] || exit 2
    [ "$status" -eq 0 ] || return 1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        range_args+=("$line")
    done <<<"$text"
    [ "${#range_args[@]}" -gt 0 ]
}

#: Which (blob, path) pairs have already been emitted, so nothing is read twice.
#: See the header for the key, for why a gitlink is keyed differently, and for
#: what happens to a path with a newline in it.
#:
#: Bucketed on the first three hex digits of the oid -- 4096 strings rather than
#: one -- because bash 3.2 is still what /bin/bash is on macOS and has no
#: associative arrays, and a single newline-joined string is quadratic in the
#: number of entries. Measured on a 705-commit history: 2325 entries considered,
#: 0.53s. One string would have been 95KB matched 2325 times.
seen_blobs=()
seen_gitlinks=$'\n'

# Record this entry unless it is already recorded. 0 means "new, emit it".
remember_entry() {
    local mode="$1" oid="$2" path="$3" key bucket index

    case "$path" in *$'\n'*) return 0 ;; esac

    if [ "$mode" = 160000 ]; then
        [[ "$seen_gitlinks" != *$'\n'"$path"$'\n'* ]] || return 1
        seen_gitlinks="$seen_gitlinks$path"$'\n'
        return 0
    fi

    key="$oid"$'\t'"$path"
    index=$((16#${oid:0:3}))
    bucket="${seen_blobs[$index]:-}"
    if [ -n "$bucket" ]; then
        [[ "$bucket" != *$'\n'"$key"$'\n'* ]] || return 1
    else
        bucket=$'\n'
    fi
    seen_blobs[index]="$bucket$key"$'\n'
    return 0
}

# The blobs the pushed range introduces and the tip's tree does not hold.
#
# `git rev-list` names the commits -- the same range `--messages` reads -- and
# `git diff-tree` names what each one adds. The header holds every decision in
# that command and why each is reachable.
#
# The stream is `<sha>` then, for each change, `:<srcmode> <dstmode> <srcoid>
# <dstoid> <status>` and the path, all NUL-terminated. A path may start with a
# colon, so a record is only ever read as metadata when no path is outstanding;
# anything else must be a commit sha, and one that is not is a shape this reader
# does not understand and refuses rather than guesses at.
print_range_entries() {
    local scope="$1" work commit='' meta='' mode oid rest rec

    work="$(mktemp -d)" || fail 'could not make a working directory'
    trap 'rm -rf "$work"' EXIT

    if ! git rev-list --reverse "${range_args[@]}" 2>"$work/complaint" |
        git "${QUOTE_OFF[@]}" diff-tree --stdin -r -z --root \
            --diff-merges=first-parent --diff-filter=AMT --no-renames \
            >"$work/range" 2>>"$work/complaint"; then
        printf 'git-guards-scope: could not read what %s introduces\n' "$scope" >&2
        cat "$work/complaint" >&2
        printf 'The line above is git%s own account of what stopped it.\n' "'" >&2
        exit 2
    fi

    while IFS= read -r -d '' rec; do
        if [ -n "$meta" ]; then
            # `:<srcmode> <dstmode> <srcoid> <dstoid> <status>`. The DESTINATION
            # side is the one that names a blob this push is introducing.
            rest="${meta#* }"
            mode="${rest%% *}"
            rest="${rest#* }"
            rest="${rest#* }"
            oid="${rest%% *}"
            meta=''
            [ -n "$commit" ] ||
                fail 'git diff-tree named a change before naming the commit it came from'
            if remember_entry "$mode" "$oid" "$rec"; then
                printf '%s %s %s\t%s\0' "$mode" "$oid" "$commit" "$rec"
            fi
            continue
        fi
        case "$rec" in
            :*)
                meta="$rec"
                continue
                ;;
        esac
        [[ "$rec" =~ ^[0-9a-f]{40,}$ ]] ||
            fail "git diff-tree said something this reader cannot place: ${rec:0:40}"
        commit="$rec"
    done <"$work/range"

    [ -z "$meta" ] ||
        fail 'git diff-tree named a change and then no path for it'

    rm -rf "$work"
    trap - EXIT
}

print_entries() {
    local scope="$1" unmerged work rec rest mode oid path

    if [ "$scope" = ':index' ]; then
        # An index holding conflict stages is not a tree that any commit could
        # have, so there is no single answer to give about it. Reporting the
        # stage-2 side, or all three, would be answering a question nobody
        # asked. git runs no hook mid-conflict, so this is a person running a
        # scan by hand in the middle of a merge -- and telling them so is more
        # use than a number.
        unmerged="$(git ls-files -u -z)" || fail 'git ls-files could not read the index'
        if [ -n "$unmerged" ]; then
            fail 'the index holds unmerged paths, so it is not a tree this commit could have'
        fi
        if ! git ls-files -s -z 2>/dev/null | normalise_entries stage; then
            fail 'git ls-files could not list the index'
        fi
        return
    fi

    if ! read_range_revs "$scope"; then
        # No push, so no range: a bare clone's HEAD, or a scan pointed at a rev
        # by hand. The tree is the whole answer and it is streamed straight out,
        # which is also what keeps the manual stage costing exactly what it did.
        if ! git ls-tree -r -z "$scope" 2>/dev/null | normalise_entries type; then
            fail "git ls-tree could not list $scope"
        fi
        return
    fi

    # A push. The tree is emitted first and unchanged -- every path in it, even
    # where two paths share a blob, because a path is committed text in its own
    # right -- and recorded as it goes, so the range half can tell what is
    # genuinely additional.
    work="$(mktemp -d)" || fail 'could not make a working directory'
    trap 'rm -rf "$work"' EXIT
    if ! git ls-tree -r -z "$scope" 2>/dev/null | normalise_entries type \
        >"$work/tree"; then
        fail "git ls-tree could not list $scope"
    fi
    while IFS= read -r -d '' rec; do
        printf '%s\0' "$rec"
        mode="${rec%% *}"
        rest="${rec#* }"
        oid="${rest%% *}"
        path="${rest#*$'\t'}"
        remember_entry "$mode" "$oid" "$path" || true
    done <"$work/tree"
    rm -rf "$work"
    trap - EXIT

    print_range_entries "$scope"
}

#: `%B` is the raw body -- subject and body exactly as stored, with nothing
#: stripped, because git has already stripped the `#` comment lines by the time a
#: message is in a commit. The sha travels with it so a finding can name the
#: commit rather than only quote the text, and `-z` separates the records because
#: a message holds newlines and blank lines by construction.
MESSAGE_FORMAT='%H%x09%B'

# The messages of the commits this push is publishing. See the header for the
# range and for why a message reaches a remote unread without one.
print_messages() {
    local scope="$1"

    # `:index` is a commit that does not exist yet, and its message is what the
    # commit-msg hooks read at the moment it is written. The HEAD fallback is a
    # scan somebody pointed at a repository, not an operation publishing
    # anything. Neither publishes a message, so neither has one to hand over --
    # and read_range_revs says so by returning 1, which is an answer, rather
    # than by the 2 it exits on for a range it could not work out.
    read_range_revs "$scope" || return 0

    git log -z --format="$MESSAGE_FORMAT" "${range_args[@]}" ||
        fail "git log could not read the commits $scope publishes"
}

case "${1:-}" in
    --scopes)
        [ "$#" -eq 1 ] || usage
        print_scopes
        ;;
    --entries)
        [ "$#" -eq 2 ] || usage
        [ -n "$2" ] || fail 'no scope token was given to --entries'
        print_entries "$2"
        ;;
    --messages)
        [ "$#" -eq 2 ] || usage
        [ -n "$2" ] || fail 'no scope token was given to --messages'
        print_messages "$2"
        ;;
    *) usage ;;
esac
