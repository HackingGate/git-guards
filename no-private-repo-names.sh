#!/usr/bin/env bash
# Refuse to write a private repo's name into a public one.
#
# A public repo's commit messages and history are permanent and indexable. A
# private repo named there discloses that it exists, who owns it, and often what
# it does — and unlike a PR description, a commit message cannot be corrected
# afterwards without rewriting published history.
#
# It happens by accident, not by carelessness: you fix a shared tool in a public
# repo *because* of something you hit in a private one, and paste the real error
# output into the message.
#
# Modes:
#   no-private-repo-names.sh <commit-msg-file>   commit-msg: the message
#   no-private-repo-names.sh --staged            pre-commit: lines being added
#   no-private-repo-names.sh --tracked           every file in the tree this
#                                                operation is introducing
#   no-private-repo-names.sh --text [FILE]       any text; FILE or stdin
#
# --text exists because git is not the only way a private name reaches a public
# place, and it is not the way it usually does. A pull request body is typed
# into a CLI and goes straight to a public API without passing a single hook;
# so does an issue title, a release note and a branch name. The rule for all of
# them is this one, and a second implementation of it would be a second rule
# that agrees with this one until it does not.
#
# --tracked closes the other half. Staged mode judges what a commit ADDS, which
# is the right unit at commit time and blind by construction to a line that is
# already there: a name that arrived under --no-verify, through a merge, or in a
# checkout where the hook was never installed is never looked at again. It scans
# every tracked file for the same reason prevent-unusual-unicode-in-files does.
#
# WHICH tracked files is decided by git-guards-scope.sh and not here, and that
# is the point of it living there: this mode and prevent-unusual-unicode-in-files
# ask one question -- which bytes is this operation actually introducing -- and
# two implementations of that are two answers that agree until they do not. They
# did not. This scan read the WORKING TREE, so at pre-push it judged whatever
# branch happened to be checked out: a private name committed on a feature
# branch, with main checked out and the file not even on disk, was reported
# Passed by the hook registered at pre-push precisely to catch it, and reached
# the remote. The resolver's answer is the index at pre-commit and at
# pre-merge-commit, the commit being pushed at pre-push, and HEAD where there is
# no index; its own header carries the whole of the reasoning.
#
# FIVE things are read out of that scope rather than one, and none of the last
# four is an edge case. `git grep` covers the regular files, which is what makes
# a tree-wide scan cost one process instead of one per file. Then:
#
#   * A SYMLINK's blob is TEXT -- git stores the target path as the file's entire
#     content -- and git grep does not look inside one. A committed
#     `ptr -> acme/hidden-repo` is a private repository's name in a public
#     repository's history, indexed and permanent like any other, and the
#     tree-wide backstop reported it clean while catching the identical string
#     in a plain file. So the symlink entries are enumerated and read directly.
#
#   * A PATH is that same fact one step further out. `vendor/acme/hidden-repo/
#     README` publishes the name in the tree listing, and so does a SUBMODULE
#     gitlink at that path, which has no blob in this repository at all. The
#     scope resolver has always emitted the path beside the mode and the oid;
#     the PATH half was discarded for everything but symlinks, and
#     `vendor/acme/hidden-repo/README` reached a remote with every hook green at
#     commit, at push and at manual.
#
#   * A BLOB THE PUSHED RANGE INTRODUCED, at push time. A push publishes a range
#     of commits and the tree-wide scans read the TIP's tree, so a file added in
#     one pushed commit and deleted in the next is on the remote permanently, is
#     in no tip tree, and was read by nothing. Measured: two commits, the first
#     adding a file naming a private repository and the second removing it,
#     fast-forwarded in from a hookless clone -- every hook green, no override of
#     any kind, and the bytes still there afterwards. The resolver marks those
#     entries with the commit that introduced them; they have no path in the
#     tree being pushed, so git grep is given the OBJECT.
#
#   * A COMMIT MESSAGE, at push time. The commit-msg guard runs when `git commit`
#     writes a message, and a commit can be made without that ever happening --
#     `git commit-tree`, a rebase, a cherry-pick, `git am`, `--no-verify`, or a
#     fast-forward carrying somebody else's commit in from a hookless clone. The
#     pre-push guards read the TREE, so those messages were published unread.
#     git-guards-scope.sh --messages names the range; its header states what the
#     range is when the remote ref is new or unknown.
#
# And the denominator is what was SEARCHED rather than what was enumerated,
# because git's own binary determination consults the `diff` ATTRIBUTE before it
# looks for a NUL byte. A committed two-line `.gitattributes` holding
# `*.log -diff`, or `* -diff`, or `*.csv binary`, made plain-ASCII files
# invisible to --staged AND --tracked at every stage, with the exit status still
# 0 or 1, nothing on stderr, and a denominator counting files nobody had read.
# So this file asks git which paths it actually read, reads the rest itself out
# of the object database -- which no attribute can stop -- and answers the binary
# question on the bytes.
#
# ## Two boundaries this rule cannot cross
#
# A MULTI-REF PUSH IS JUDGED ON ONE REF. prek 0.3.12 exports a single
# PRE_COMMIT_TO_REF pair and its shim has already consumed git's ref-update
# stream from stdin, so `git push origin clean1 dirty1` scans clean1 and
# publishes dirty1. Push one ref at a time, or run the manual stage in CI over
# the whole tree.
#
# AN ANNOTATED TAG'S MESSAGE IS NEVER SCANNED. git has no tag-message hook type,
# so `git tag -a -m '...'` reaches nothing here. Check one first with
# `no-private-repo-names.sh --text`. The tag's TREE is covered: the scope
# resolver peels a tag to its commit, so pushing a tag that points at a dirty
# tree is refused exactly as pushing the branch would be.
#
# It is registered at pre-merge-commit, pre-push and manual, deliberately NOT at
# pre-commit, and the arithmetic is why. A tree-wide scan asks the forge about every distinct
# name anywhere in the repository, not about the handful a commit touches: on
# this repository that is 46 names and 41 network round trips, because a name
# the forge has never heard of is the common case in a tree full of examples and
# fixtures. Measured here, that is 19.4 seconds of a commit against 0.08 seconds
# with `gh` off PATH -- the whole of it is waiting for the network. A guard that
# adds twenty seconds to every commit is one somebody eventually deletes, and a
# deleted guard protects nothing.
#
# Moving it costs nothing that staged mode does not already cover. What a commit
# ADDS is checked at pre-commit, by --staged, at no network cost at all when
# there is nothing to look up. What --tracked adds is the line that arrived
# WITHOUT passing a hook, and no later commit is a natural moment to notice
# that; the last moment before the work becomes shared is, which is pre-push.
# manual is how CI reaches it, and how a scheduled run finds it rather than
# whoever pushes next.
#
# pre-merge-commit is the third, and it is there because a merge runs NONE of
# the pre-commit hooks. git runs `pre-merge-commit` for a merge and `pre-commit`
# for a commit, and they are different hook types with different install lines,
# so a branch that picked up a private name under --no-verify carries it into
# the trunk through `git merge --no-ff` with no file guard consulted at all --
# which is the "arrived through a merge" case named two paragraphs up, arriving
# past the backstop that names it. A merge is rare enough that the network cost
# which rules out pre-commit does not rule this out.
#
# It differs from message mode in one deliberate way: it does NOT strip lines
# beginning with `#`. Git strips those from a commit message, but a `## Heading`
# in a pull request body is content -- and a private name inside a heading is
# exactly as published as one in a paragraph.
set -euo pipefail

allow_var=GIT_GUARDS_ALLOW_PRIVATE_NAMES
private_owners="${GIT_GUARDS_PRIVATE_OWNERS:-}"
public_repos="${GIT_GUARDS_PUBLIC_REPOS:-}"

if [ "${GIT_GUARDS_ALLOW_PRIVATE_NAMES:-}" = "1" ]; then
    # Drain stdin before leaving, but ONLY for the one invocation that actually
    # pipes: `--text` with no FILE. A filter that exits without reading its
    # input kills the writer with SIGPIPE, which under the `set -o pipefail` any
    # careful caller runs becomes the pipeline's status -- 141, from a guard
    # that meant to say yes.
    #
    # It is a race rather than a certainty, which is why it survived this long:
    # a short message fits in the pipe buffer and the writer finishes before the
    # exit. The same command passed here and failed on a CI runner.
    #
    # The condition is narrow on purpose. Draining whenever stdin is merely not
    # a terminal blocks forever when stdin is a descriptor the caller inherited
    # and nobody closes -- which is every other mode, and which hung the whole
    # suite when this was first written that way. Mode is parsed further down;
    # this reads the arguments directly rather than moving the bypass, because
    # the bypass answering before anything else is examined is the point of it.
    if [ "${1:-}" = '--text' ] && { [ "$#" -eq 1 ] || [ "${2:-}" = '-' ]; }; then
        cat >/dev/null 2>&1 || true
    fi
    exit 0
fi

# The character set an owner or a repository name is allowed to have. It is the
# same one repo_from_url accepts out of a parsed URL, and that is the point of
# writing it once: a name this script is willing to REPORT and a name somebody
# is allowed to DECLARE are the same kind of thing, and two definitions of that
# would agree until they did not.
name_form='[A-Za-z0-9][A-Za-z0-9._-]*'

# Refuse a configured value this script cannot read, before any mode reads it.
#
# All three variables below are authored by a person and consumed at run time,
# and the two lists are consumed TWICE under different rules: list_has compares
# an entry literally, while read_tracked_text and extract_candidates paste it
# into an extended regular expression. An entry that is not a plain name makes
# those two readings disagree, and the disagreement is silent in the direction
# that matters.
#
# `GIT_GUARDS_PRIVATE_OWNERS=acme|widgets` is the case that has to be refused
# rather than tolerated, because it COMPILES. As a regex it is an alternation,
# so `widgets/secret` is extracted as a candidate; as a literal it is a single
# item equal to neither `acme` nor `widgets`, so list_has does not recognise the
# owner as declared private -- and the candidate goes on to the forge as though
# it were any other name. The forge 404s, the run exits 0, nothing is printed,
# and the owner list looked like it was working the entire time.
#
# An entry that will not compile at all is the other half, and left to the modes
# it would be answered four different ways. --tracked builds its prefilter for
# `git grep`, which reports a bad pattern and exits 2; message, --staged and
# --text build theirs for greps whose status a `|| true` would swallow, so the
# identical environment would refuse a tree scan and pass a commit message.
# Validating here, above the mode switch, is what makes all four answer the same
# way -- no mode can reach a pattern the engine will not compile.
#
# Exit 2 rather than 1, because this is the could-not-check outcome: a list that
# cannot be read is not an empty list.
refuse_config() {
    printf 'no-private-repo-names: %s\n' "$1" >&2
    printf 'Each entry is a name -- letters, digits, and . _ - after the first\n' >&2
    printf 'character -- separated by commas. Every entry becomes both a literal\n' >&2
    printf 'comparison and part of a regular expression, and anything else makes\n' >&2
    printf 'those two disagree without saying so.\n' >&2
    exit 2
}

#   $1  the variable's name, for the message -- a refusal that does not say
#       which variable to go and look at sends somebody reading this file
#   $2  its value
#   $3  yes when an entry may be `owner/repo` as well as a bare `owner`
validate_name_list() {
    local var="$1" list="$2" repos_allowed="$3" item pattern
    if [ "$repos_allowed" = yes ]; then
        pattern="^$name_form(/$name_form)?$"
    else
        pattern="^$name_form$"
    fi
    # Split on commas, exactly as every other reader of these lists splits.
    for item in ${list//,/ }; do
        [ -n "$item" ] || continue
        [[ "$item" =~ $pattern ]] && continue
        refuse_config "$var holds an entry that is not a name: $item"
    done
}

validate_name_list GIT_GUARDS_PRIVATE_OWNERS "$private_owners" no
validate_name_list GIT_GUARDS_PUBLIC_REPOS "$public_repos" yes

# GIT_GUARDS_REPO_VISIBILITY answers the question the forge would otherwise be
# asked, so it is held to the forge's own vocabulary, plus `unknown` for saying
# outright that it cannot be established. Accepting anything else would be a
# fail-open with no floor, and the sharp case is a typo: `publlic` is what
# somebody typed meaning `public`, and an unvalidated read of it makes the guard
# decide this repository is not public and exit 0 without examining a single
# name -- the value that switches the guard ON, misspelt, switching it off. So
# would `false`, `true`, `0`, `yes`, `Public.` and `public ` with its trailing
# space.
#
# A value is not trimmed or corrected here on purpose. Guessing at what somebody
# meant is the same fail-open one step later, and it makes the variable mean
# whatever the guess was rather than what was written.
#
# Validated at the top of the file, above the mode switch, so every mode refuses
# alike rather than only the modes that go on to consult it.
repo_visibility_override="$(printf '%s' "${GIT_GUARDS_REPO_VISIBILITY:-}" |
    LC_ALL=C tr '[:upper:]' '[:lower:]')"
case "$repo_visibility_override" in
    '' | public | private | internal | unknown) ;;
    *)
        printf 'no-private-repo-names: GIT_GUARDS_REPO_VISIBILITY is not a visibility: %s\n' \
            "${GIT_GUARDS_REPO_VISIBILITY}" >&2
        printf 'Accepted values are public, private, internal and unknown.\n' >&2
        exit 2
        ;;
esac

# `.` is legal in a name and is a wildcard in an extended regular expression, so
# a declared owner reaches the pattern escaped. Unescaped, a declared `acme.corp`
# also matches `acmeXcorp/anything`, and the run then reports a repository the
# tree does not contain. The validated character set admits no other ERE
# metacharacter, which is what makes one substitution enough.
regex_escape_name() { printf '%s' "${1//./\\.}"; }

mode=message
subject="${1:-}"

if [ "$subject" = "--staged" ]; then
    mode=staged
    subject=""
elif [ "$subject" = "--tracked" ]; then
    mode=tracked
    subject=""
elif [ "$subject" = "--text" ]; then
    mode=text
    subject="${2:-}"
fi

# `git grep`, `git ls-files` and `git diff -- .` all read from the CURRENT
# directory down, so any of them started from a subdirectory covers a subtree
# and says nothing about the rest. That is the failure these modes exist to
# prevent, arriving through the check itself. Hook runners happen to invoke from
# the root; a person will not.
#
# Staged mode needs this every bit as much as the tree scan does, and it is the
# less obvious of the two: a commit is repository-wide whatever directory it was
# typed in, so a check on what the commit adds that stops at $PWD is answering
# about a different set of changes than the one being committed. From a
# subdirectory it exited 0 over a staged addition anywhere else in the tree.
if [ "$mode" = tracked ] || [ "$mode" = staged ]; then
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$toplevel" ]; then
        printf 'no-private-repo-names: not inside a git work tree\n' >&2
        exit 2
    fi
    cd "$toplevel" || exit 2
fi

# A runner that forwards no path at all still has to be answered, so fall back
# to the file git itself writes — as the other commit-msg guards here do.
#
# It is a fallback and not the normal path, which the comment here used to have
# backwards: it said prek does not forward the message path. prek does, and so
# does pre-commit, PROVIDED the hook is declared `pass_filenames: true` — which
# every commit-msg hook in .pre-commit-hooks.yaml is, for the reason set out
# there. What reaches this line is a hook somebody registered themselves with
# `pass_filenames: false`, or a bare `git commit` wiring that passes nothing.
#
# Which makes the fallback the dangerous half rather than the safe one, and
# worth saying out loud here: .git/COMMIT_EDITMSG is the file git wrote for the
# commit in progress, so under `git commit` it is exactly right, and under
# `prek run --hook-stage commit-msg --commit-msg-filename <a file>` it is the
# PREVIOUS commit's message. A guard that lands there reports Passed over a
# message it never opened, while the file named on the command line goes unread.
# tests/self-commit-test.sh drives that invocation for each commit-msg guard,
# with a clean message planted in COMMIT_EDITMSG so that a guard reading the
# fallback is visible as a pass rather than hidden by one.
if [ "$mode" = message ] && { [ -z "$subject" ] || [ ! -f "$subject" ]; }; then
    git_dir="$(git rev-parse --git-dir 2>/dev/null)" || true
    if [ -n "${git_dir:-}" ] && [ -f "$git_dir/COMMIT_EDITMSG" ]; then
        subject="$git_dir/COMMIT_EDITMSG"
    fi
fi

if [ "$mode" = message ] && { [ -z "$subject" ] || [ ! -f "$subject" ]; }; then
    printf 'no-private-repo-names: no commit message file found\n' >&2
    exit 1
fi

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/git-guards"
cache_file="$cache_dir/repo-visibility"

lower() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }

list_has() {
    local needle item list
    needle="$(lower "$1")"
    list="${2:-}"
    for item in ${list//,/ }; do
        [ -n "$item" ] || continue
        [ "$(lower "$item")" != "$needle" ] || return 0
    done
    return 1
}

gh_available() {
    command -v gh >/dev/null 2>&1
}

# Only the forge's own three words count as an answer; everything else is a
# failed lookup, whatever it looks like.
#
# This is not defensiveness. `gh api` writes the API's ERROR BODY to stdout and
# exits non-zero, so a 404 arrives as a line of JSON rather than as an empty
# string -- and a 404 is precisely what the forge returns for a private
# repository this token cannot see, which is the one case the whole guard exists
# for. Read literally that JSON is not `private`, so the name would pass; it is
# not `unknown` either, so it would never be reported as unresolved,
# GIT_GUARDS_REFUSE_UNKNOWN could not refuse it, and it would be cached as
# though the forge had answered. One unlucky lookup would switch the guard off
# for that repository permanently.
#
# An allow-list rather than a test for JSON, because the failure mode to avoid
# is a shape nobody predicted being read as a verdict. A value that is not one
# of these three is not an answer no matter what produced it.
#
# It is a function rather than two `case` statements because it is asked on both
# sides of the cache, and a rule with two implementations is two rules that
# agree until they do not.
is_a_visibility_answer() {
    case "$1" in
        public | private | internal) return 0 ;;
        *) return 1 ;;
    esac
}

# The fourth thing a cache line may record, and it is not a visibility: `absent`
# means the forge was asked and replied that it has no such repository visible
# to this token. Kept separate from the three words above because it is not one
# of them and must never be read as one -- every caller that asks what a name IS
# gets `unknown` for it, exactly as though the lookup had just happened.
is_a_cached_absence() {
    [ "$1" = absent ]
}

# Ask the forge once per repo, then remember. `gh` is optional: without it the
# guard still enforces GIT_GUARDS_PRIVATE_OWNERS, which needs no network.
lookup_visibility() {
    local repo="$1" cached visibility complaint forge_said cached_absence=no
    repo="$(lower "$repo")"

    # The allow-list is applied on the way OUT of the cache as well as on the
    # way in, and the read side is the one that cannot be skipped. The write
    # side stops a new blob being stored; it does nothing about the entries a
    # cache already holds, and the file is never expired, so a single poisoned
    # line would answer every later lookup for that repository, silently, no
    # matter how carefully the writing side is guarded. A line whose value is
    # not one this file is allowed to hold is not an entry; it is a cache miss,
    # so the loop keeps reading and the lookup happens again.
    #
    # The KEY is matched literally, and that is not a tidy-up. `grep "^$repo "`
    # interpolates a repository name into a basic regular expression, and `.` is
    # both legal in a repository name and a wildcard in a BRE -- so a line
    # `acme/my-app public`, written by an ordinary clean run against a genuinely
    # public repository, answered a lookup for the private `acme/my.app`. The
    # guard then said nothing and exited 0, and because the wrong value IS one
    # of the three words, GIT_GUARDS_REFUSE_UNKNOWN=1 had nothing to refuse. The
    # same hole under this_repo_is_public is worse again: one wrong `private`
    # there and the guard switches itself off for the whole repository, in every
    # mode. `grep -F` prefilters on the literal bytes, and the `case` anchors it
    # to the start of the line -- a quoted pattern in `case` is a literal
    # comparison, which is the property being bought here. The grep is kept
    # rather than replaced by the loop alone because it also normalises a final
    # line with no trailing newline.
    #
    # A visibility outranks an absence wherever the two appear for one name, and
    # the loop therefore reads every matching line rather than stopping at the
    # first. They can only appear together when two runs disagreed -- most
    # plainly when one had a token that could see the repository and the other
    # did not -- and of those two, the run that got an answer learned something,
    # while the run that got a 404 learned only what it could not see. Taking
    # whichever happened to be written first would let the poorer-credentialled
    # run decide, and go on deciding, because nothing is ever asked twice.
    if [ -f "$cache_file" ]; then
        while IFS= read -r cached; do
            case "$cached" in
                "$repo "*) ;;
                *) continue ;;
            esac
            cached="${cached#* }"
            if is_a_visibility_answer "$cached"; then
                printf '%s\n' "$cached"
                return
            fi
            # The forge has already said it cannot see this one. That is a fact
            # about the forge and the token, and asking again produces the same
            # 404 at the cost of a network round trip -- which is the whole of
            # what a tree-wide scan spends its time on. It answers `unknown`,
            # not `public`, so nothing downstream can tell this apart from the
            # lookup it replaces. Noted rather than returned, so that a real
            # visibility further down the file still wins.
            if is_a_cached_absence "$cached"; then
                cached_absence=yes
            fi
        done < <(grep -F -- "$repo " "$cache_file" 2>/dev/null || true)

        if [ "${cached_absence:-no}" = yes ]; then
            printf 'unknown\n'
            return
        fi
    fi

    gh_available || { printf 'unknown\n'; return; }

    # stdout and stderr are captured apart because the two carry different
    # facts. `gh api` writes the API's response body to stdout whatever the
    # status, and writes its own one-line summary -- ending in `(HTTP <code>)`
    # -- to stderr for any non-2xx. The status code is the only thing here that
    # distinguishes "the forge answered" from "the question never arrived", and
    # it is a code rather than a sentence, which is why it is what gets matched.
    complaint="$(mktemp)"
    visibility="$(gh api "repos/$repo" --jq .visibility 2>"$complaint" || true)"
    forge_said="$(cat "$complaint")"
    rm -f "$complaint"

    visibility="$(lower "${visibility:-unknown}")"
    is_a_visibility_answer "$visibility" || visibility=unknown

    # A 404 is an ANSWER, and separating it from a failed lookup is what makes
    # the cache do any work at all. Collapse the two into `unknown` and store
    # neither, and a tree full of example URLs and fixture names -- 41 of the 46
    # distinct names in this repository -- pays a full round trip on every single
    # run, warm cache or cold, with the cache saving five of forty-six.
    #
    # Storing it is safe in the one direction that matters. `absent` reads back
    # as `unknown`, so the verdict is bit-for-bit what an uncached run produces:
    # the name is still reported as unresolved, GIT_GUARDS_REFUSE_UNKNOWN=1
    # still refuses it, and nothing is ever concluded to be not-private on the
    # strength of a stored 404. A stale positive entry fails OPEN; a stale
    # `absent` fails closed, which is the asymmetry that permits one and not the
    # other.
    #
    # Only 404. Not 401, not 403, not 5xx: a bad credential and a rate limit
    # answer 404-shaped for every name at once, and storing those would be the
    # bug this is carefully not -- a whole tree's worth of names written off
    # from one expired token. Those stay uncached and stay a failed lookup.
    #
    # There is no batching here to be preferred instead. Once the absences are
    # remembered the steady state is zero round trips, so there is nothing left
    # to batch; and the REST API has no endpoint that takes forty-six arbitrary
    # names at once, so batching would mean adding a GraphQL query -- a second
    # way of asking the same question, to speed up a case this file does not
    # have.
    if [ "$visibility" = unknown ] && [[ "$forge_said" == *"(HTTP 404)"* ]]; then
        mkdir -p "$cache_dir"
        printf '%s absent\n' "$repo" >> "$cache_file"
        printf 'unknown\n'
        return
    fi

    # An unknown answer that is NOT a 404 is never cached. It means the lookup
    # failed -- no network, no token, a rate limit -- and caching it would switch
    # the guard off for that repository permanently, for exactly the repository
    # it just failed to resolve. A cache entry must record an answer, not the
    # absence of one.
    #
    # An answer that WAS given is kept forever, and that is a limit rather than
    # a claim that visibility never changes. It changes in the one direction
    # this guard is about: a repository answered `public` here and made private
    # afterwards is answered `public` for as long as the file survives, which is
    # the guard failing open on exactly the event it exists to catch. There is
    # no expiry because an expiry cannot tell a stale entry from a current one
    # without asking the forge again -- that is the lookup it was avoiding -- and
    # because a time-based reread would quietly resurrect the classes of bad
    # entry the vocabulary check above keeps out. The remedy is manual and it
    # is a single command: delete $cache_file when a repository's visibility
    # changes. It is a cache; nothing is lost with it. README.md says the same.
    #
    # The same remedy, and the same reasoning, covers an `absent` entry for a
    # repository this token has since been given access to. That one only ever
    # costs a name going on being reported as unresolved, which is the answer it
    # was already giving.
    if [ "$visibility" != unknown ]; then
        mkdir -p "$cache_dir"
        printf '%s %s\n' "$repo" "$visibility" >> "$cache_file"
    fi
    printf '%s\n' "$visibility"
}

is_private() {
    case "$1" in
        private | internal) return 0 ;;
        *) return 1 ;;
    esac
}

# Whether the repo being committed to is public, i.e. whether there is anything
# to protect here. Unknown means unknown: a guard that cannot tell must not
# start blocking commits on a guess.
this_repo_is_public() {
    local override remote repo visibility

    # Set alongside the return value, because "not public" and "could not tell"
    # are different answers and the caller needs to be able to distinguish them.
    this_repo_visibility=unknown

    # Already lowered, and already checked against the accepted vocabulary at
    # the top of the file, so that a misspelling is refused in every mode rather
    # than only in the modes that consult it.
    override="$repo_visibility_override"
    if [ -n "$override" ]; then
        this_repo_visibility="$override"
        [ "$this_repo_visibility" = "public" ]
        return
    fi

    remote="$(git remote get-url origin 2>/dev/null || true)"
    repo="$(repo_from_url "$remote" || true)"
    [ -n "$repo" ] || return 1

    visibility="$(lookup_visibility "$repo")"
    this_repo_visibility="$visibility"
    [ "$visibility" = "public" ]
}

repo_from_url() {
    local url="$1" path

    url="${url%%#*}"
    url="${url%%\?*}"

    if [[ "$url" =~ ^[^@/:]+@[^:]+:(.+)$ ]]; then
        path="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ ^[a-z]+://([^/@]+@)?[^/]+/(.+)$ ]]; then
        path="${BASH_REMATCH[2]}"
    else
        return 1
    fi

    path="${path#/}"
    path="${path%/}"
    path="${path%.git}"

    [[ "$path" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    printf '%s\n' "$path"
}

#: The three candidate forms as one regex, for the tree-wide scan. Only lines
#: that could hold a candidate are read, so the scan costs one `git grep` rather
#: than a read of every tracked file.
CANDIDATE_FORMS='[a-z0-9.-]+\.[a-z]{2,}[:/][A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*|[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*#[0-9]+'

# git-guards-scope.sh, beside this script, is what decides WHICH tree the scan
# below reads. It is resolved from this file's own path rather than from $PWD
# because a hook runner copies the whole hook repository into its cache and runs
# the entry from there, so the two files travel together and $PWD is somebody
# else's checkout.
#
# Missing, it is a refusal and not a fallback. The fallback there used to be --
# read the working tree -- is the defect the resolver exists to remove, and a
# guard that quietly reverts to the wrong artifact when a file is absent is a
# guard whose fix can be undone by a packaging mistake nobody will see.
guard_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || guard_dir=""
scope_tool="${guard_dir:-.}/git-guards-scope.sh"

#: The origin the resolver marks an entry with when the scope's own tree holds
#: it. Anything else is a commit sha: the blob is one the pushed RANGE
#: introduced and the tree being pushed does not hold, because a later commit in
#: the same push removed or replaced it. Those reach the remote permanently and
#: no tip tree names them.
SCOPE_TREE_ORIGIN=':tree'

#: Filled in by read_tracked_text and read afterwards by the report. They are
#: globals rather than a return value because a scan reports THREE things --
#: the text it read, what it read that text out of, and how much there was --
#: and a shell function has one stdout. The scan is therefore run with its
#: stdout redirected to a file rather than inside a command substitution, so
#: that these survive it: a subshell's assignments do not come back.
scan_scopes=()
scan_labels=()
scan_links=()
#: `TOKEN<TAB>PATH` for each blob this file had to read itself because git grep
#: would not read it as text. Kept so a finding can still be located: the same
#: grep that skipped it during the scan would skip it again during the report.
scan_direct=()
#: Every path in every scope, and every pushed commit's `SHA<TAB>MESSAGE`. Both
#: are text that a scan reads and that no `git grep` over file CONTENT can
#: locate a finding in afterwards.
scan_names=()
scan_msgs=()
#: Why a path went unread, itemised. A count on its own is what makes a skip
#: safe to ignore right up until one of them is the file somebody hid a name in.
scan_skipped=()
#: `TOKEN<TAB>OID<TAB>COMMIT<TAB>PATH` for each blob the resolver said the PUSHED
#: RANGE introduces and the tree being pushed does not hold. They are at no path
#: in that tree, so they are handed to git grep as OBJECTS and located as
#: objects; the commit travels with them because it is the only thing a reader
#: can act on -- the file is gone, the commit that added it is not.
scan_range=()
#: What git grep said it had actually read, joined by newlines with a leading and
#: trailing one, so a membership test is a single glob match. Keys are `p:<path>`
#: for a tree entry and `o:<oid>` for a range blob, which is the only thing
#: separating a path that happens to be forty hex digits from an object name. A
#: path holding a newline cannot be tested this way and is never claimed as
#: searched -- see entry_was_searched.
scan_searched_index=$'\n'
scan_entries=0
#: The two halves of the entry count, which is the whole reason the resolver
#: marks each entry with where it came from. "150 path name(s)" is the same
#: sentence over a tree of 150 and over a tree of 2 with 148 blobs that passed
#: through the range, and only one of those is a repository worth looking at.
scan_tree_entries=0
scan_range_entries=0
#: Entries that HAVE a blob of file content -- neither a symlink, whose blob is
#: a target path and is counted separately, nor a gitlink, which has no blob in
#: this repository at all. It is the denominator scan_searched is a numerator of,
#: and the pair only means anything because the two used to be one number.
scan_files=0
scan_searched=0
scan_symlinks=0
scan_messages=0

# A path is committed text in its own right, and this is the form it names a
# repository in. `vendor/acme/hidden-repo/README` publishes `acme/hidden-repo`
# exactly as a line of a file would -- indexed and permanent, and readable by
# anyone who lists the tree -- and so does a submodule gitlink at that path,
# which has no blob to read at all. Both were invisible to a scan that read
# only blob CONTENT, which is what the whole tree-wide mode is for.
#
# Emitted as ADJACENT SEGMENT PAIRS, one per line, rather than as the whole
# path, and the shape is the point. On a line holding exactly two segments the
# forge-URL form cannot match -- it needs `host.tld/owner/repo`, which is two
# separators, and there is only one here -- so a deep directory tree cannot
# manufacture candidates for the network to be asked about. What CAN match is
# the declared-private-owner form, anchored at the start of the line, which is
# the form that names a repository without asking anybody anything.
emit_path_pairs() {
    local rest="$1" left="" segment
    while [ -n "$rest" ]; do
        segment="${rest%%/*}"
        if [ "$segment" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        [ -n "$segment" ] || continue
        [ -z "$left" ] || printf '%s/%s\n' "$left" "$segment"
        left="$segment"
    done
}

# Did git grep read this entry AS TEXT during the scan?
#
# Takes a key: `p:<path>` for something in the tree being scanned, `o:<oid>` for
# a blob the range introduced that no path in that tree names.
#
# A path holding a NEWLINE is never claimed as searched, whatever the index
# says. The index is newline-joined, so such a path cannot be told from two
# other paths in it, and the wrong answer here is a file reported clean because
# its name looked like something else. Reading it directly costs one blob.
#
# One glob match per entry against one string, rather than an associative array,
# because bash 3.2 is still what /bin/bash is on macOS and a guard that will not
# start there is a guard nobody installs. The cost is quadratic in the number of
# entries and it is not hidden: a thousand-file tree is about a megabyte of
# matching, against a mode whose other half spends nineteen seconds on the
# network.
entry_was_searched() {
    case "$1" in
        *$'\n'*) return 1 ;;
    esac
    [[ "$scan_searched_index" == *$'\n'"$1"$'\n'* ]]
}

# Every path git grep was willing to READ, as opposed to every path it found
# something in. `-e ''` matches every line of every file it opens, so what comes
# back is the searched set itself -- the only thing there is to compare against
# what the tree actually holds.
grep_searched_paths() {
    grep_scope_with_range "$1" -zlI -e ''
}

# git grep's stderr is a REFUSAL, not a footnote, whatever the exit status says.
#
# `git grep` has three statuses and only two of them are about finding things: 0
# found something, 1 found nothing, above that an error. What that leaves out is
# that git also complains on stderr and exits 1 anyway -- `error: '<path>':
# unable to read <oid>` for a blob it cannot produce is exactly that, and a run
# that discards it reports a clean tree over a file nobody read. So any word on
# stderr ends the run, at any status. git's own account is repeated, because
# "the scan failed" without saying why sends somebody here to read this file
# instead of the error.
check_grep_complaint() {
    local status="$1" complaint="$2" work="$3"
    if [ "$status" -le 1 ] && [ ! -s "$complaint" ]; then
        return 0
    fi
    printf 'no-private-repo-names: the tree-wide scan could not run\n' >&2
    if [ -s "$complaint" ]; then
        cat "$complaint" >&2
    else
        printf 'git grep exited %s and said nothing.\n' "$status" >&2
    fi
    printf 'Nothing can be said about a tree whose scan git would not finish.\n' >&2
    printf 'The line above is git'"'"'s own account of what stopped it.\n' >&2
    rm -rf "$work"
    exit 2
}

# The whole tree an operation is introducing, not the lines a commit adds. A
# name checked on its way in and never again is permanent once it arrives --
# under --no-verify, through a merge, or in a commit made where the hook was
# never installed. The staged check cannot see it, because to that check the
# line is not new.
#
# Three things are read out of each scope and not one: the blob CONTENT, the
# PATHS, and -- at a push -- the MESSAGES of the commits being sent. Each is
# text a commit publishes, and each was reaching a remote unread.
#
# The denominator is what was SEARCHED and not what was enumerated, and that
# distinction is the whole of the fix for the sharpest defect this mode had.
# `git grep -I` skips a binary file, but git decides binary from the `diff`
# ATTRIBUTE before it ever looks for a NUL byte -- so a committed two-line
# `.gitattributes` holding `*.log -diff` makes plain-ASCII files invisible to
# --staged AND --tracked, at every stage, with the exit status still 0 or 1, no
# word on stderr, and a denominator counting the files it did not read. Asking
# git which paths it actually read, and reading the rest here through the object
# database, is what makes the number true: an attribute can stop git grep, and
# it cannot stop `git cat-file`.
#
# Fails closed on every way the scan can cover nothing: no resolver, a scope
# that will not resolve, an empty scope, a prefilter that reports an error
# rather than a result, a prefilter that complains and exits 1 anyway, or a blob
# git will not hand over. "Nothing to check" and "nothing found" are different
# answers, and this mode used to print the second for the first -- a tracked
# file that had been chmod 000'd, or deleted from the working tree while staying
# in the index, produced exit 0 and not one word. Reading the git objects rather
# than the filesystem is what retires that whole class: neither a mode bit nor a
# missing working-tree copy can stop a blob being read out of the object
# database, so the file is not skipped, it is SCANNED. What is left of "cannot
# say" is git refusing to produce something, and every one of those refusals
# lands on an exit 2 below.
read_tracked_text() {
    local forms="$CANDIDATE_FORMS" owner scanned status grep_status nul_count
    local work complaint scopes_file entries_file searched_file messages_file blob_file
    local token label rec entry_mode rest oid origin path target key

    for owner in ${private_owners//,/ }; do
        [ -n "$owner" ] || continue
        forms="$forms|$(regex_escape_name "$owner")/[A-Za-z0-9][A-Za-z0-9._-]*"
    done

    if [ ! -x "$scope_tool" ]; then
        printf 'no-private-repo-names: git-guards-scope.sh is not beside this script\n' >&2
        printf 'Looked for %s. Without it there is no answer to which tree this\n' "$scope_tool" >&2
        printf 'scan is about, and guessing at one is the defect it replaced.\n' >&2
        exit 2
    fi

    work="$(mktemp -d)"
    complaint="$work/complaint"
    scopes_file="$work/scopes"
    entries_file="$work/entries"
    searched_file="$work/searched"
    messages_file="$work/messages"
    blob_file="$work/blob"

    if ! "$scope_tool" --scopes >"$scopes_file" 2>"$complaint"; then
        printf 'no-private-repo-names: could not work out which tree to scan\n' >&2
        cat "$complaint" >&2
        rm -rf "$work"
        exit 2
    fi

    while IFS=$'\t' read -r token label; do
        [ -n "$token" ] || continue
        scan_scopes+=("$token")
        scan_labels+=("$label")
    done <"$scopes_file"

    if [ "${#scan_scopes[@]}" -eq 0 ]; then
        printf 'no-private-repo-names: the scope resolver named no tree to scan\n' >&2
        rm -rf "$work"
        exit 2
    fi

    for token in "${scan_scopes[@]}"; do
        # The entries FIRST, because two of the three reads below depend on
        # them. A push publishes a range as well as a tree, and a blob that
        # arrived in one pushed commit and left in the next is at no path in the
        # tree being pushed -- so it has to be handed to git grep as an object,
        # and grep_scope cannot assemble that list until this file has been
        # read. Everything else about the loop is unchanged: this is the same
        # file, read in the same place, one pass earlier.
        if ! "$scope_tool" --entries "$token" >"$entries_file" 2>"$complaint"; then
            printf 'no-private-repo-names: could not list what %s holds\n' "$token" >&2
            cat "$complaint" >&2
            rm -rf "$work"
            exit 2
        fi
        while IFS= read -r -d '' rec; do
            entry_mode="${rec%% *}"
            rest="${rec#* }"
            oid="${rest%% *}"
            rest="${rest#* }"
            origin="${rest%%$'\t'*}"
            path="${rest#*$'\t'}"
            # `:tree` is the tree being scanned; anything else is the sha of the
            # commit that introduced this blob somewhere in the pushed range.
            [ "$origin" != "$SCOPE_TREE_ORIGIN" ] || continue
            # See grep_scope for why these two kinds are not handed to git grep.
            case "$entry_mode" in
                160000 | 120000) continue ;;
            esac
            scan_range+=("$token"$'\t'"$oid"$'\t'"$origin"$'\t'"$path")
        done <"$entries_file"

        # -I skips binary files; -h drops the path, which is recovered per
        # finding.
        #
        # -i because extract_candidates matches the URL and owner forms
        # case-insensitively. This grep is only a prefilter -- it decides which
        # lines are worth extracting from -- so a narrower match here would drop
        # `HTTPS://GitHub.com/Owner/Repo` before the extractor ever saw it, and a
        # prefilter that is not a superset of the thing it feeds is a scan that
        # reports a clean tree for the lines it never looked at.
        #
        # A status above 1 is an error and ends the run; so does a word on
        # stderr at any status, which is the case a status test alone cannot
        # reach. check_grep_complaint holds both, and its header holds why.
        #
        # The pattern reaching here is checked before this function runs: every
        # owner in it matched a name's character set and had its dots escaped, so
        # it compiles. This stays regardless. It is not here to catch the owner
        # list; it is here because a scan whose denominator is the whole tree
        # must be able to say it did not run, whatever stopped it, and a guard
        # removed for want of a way to trigger it is a guard removed on an
        # assumption.
        #
        # stderr goes to its own file rather than into the capture: on a status
        # of 0 or 1 the captured text IS the subject of the scan, and a warning
        # line folded into it would be searched for repository names like any
        # other line.
        status=0
        scanned="$(grep_scope_with_range "$token" -hIEi -e "$forms" 2>"$complaint")" || status=$?
        check_grep_complaint "$status" "$complaint" "$work"
        printf '%s\n' "$scanned"

        # WHICH paths that grep actually read. Everything the tree holds and this
        # does not name went unsearched, and the reasons are invisible from the
        # exit status: git consults the `diff` attribute before it looks for a
        # NUL byte, so `*.log -diff` or `*.csv binary` in a committed
        # .gitattributes hides plain ASCII from every grep in this file while the
        # status stays 0 or 1 and stderr stays empty.
        status=0
        grep_searched_paths "$token" >"$searched_file" 2>"$complaint" || status=$?
        check_grep_complaint "$status" "$complaint" "$work"
        scan_searched_index=$'\n'
        while IFS= read -r -d '' path; do
            # For a rev scope git prefixes each path with `<rev>:`; for the
            # index it does not, and for a BLOB named as an object there is no
            # path at all -- git answers with the object name. The three are
            # kept apart by the key rather than by their spelling, so a tracked
            # file whose whole path is forty hex digits cannot be mistaken for
            # an object somebody else read.
            if [ "$token" = ':index' ]; then
                key="p:$path"
            elif [ "${path#"$token":}" != "$path" ]; then
                key="p:${path#"$token":}"
            else
                key="o:$path"
            fi
            scan_searched_index="$scan_searched_index$key"$'\n'
        done <"$searched_file"

        # The entries again, now for three things git grep cannot give: the
        # paths themselves, the symlinks it declines to open, and the blobs it
        # declined to read as text.
        #
        # A symlink's blob IS its target path -- that string is the file's entire
        # committed content, indexed and permanent like any other line -- and
        # `git grep` does not look inside one. So `ptr -> acme/hidden-repo`
        # was reported clean by the tree-wide backstop while the identical string
        # in a plain file was caught, which is the backstop passing exactly the
        # arrival it exists for. Read directly, one `git cat-file` per symlink,
        # and there are never many.
        while IFS= read -r -d '' rec; do
            scan_entries=$((scan_entries + 1))
            entry_mode="${rec%% *}"
            rest="${rec#* }"
            oid="${rest%% *}"
            rest="${rest#* }"
            origin="${rest%%$'\t'*}"
            path="${rest#*$'\t'}"
            if [ "$origin" = "$SCOPE_TREE_ORIGIN" ]; then
                scan_tree_entries=$((scan_tree_entries + 1))
                key="p:$path"
            else
                scan_range_entries=$((scan_range_entries + 1))
                key="o:$oid"
            fi

            # The PATH first, and for every kind of entry, because it is the one
            # thing every entry has. A gitlink has no blob in this repository at
            # all; its path is the whole of what it publishes -- and a path the
            # range introduced and the tree no longer holds published that name
            # just as permanently as one that survived to the tip.
            scan_names+=("$path")
            emit_path_pairs "$path"

            if [ "$entry_mode" = 120000 ]; then
                if ! target="$(git cat-file blob "$oid" 2>"$complaint")"; then
                    printf 'no-private-repo-names: could not read the symlink %s\n' "$path" >&2
                    cat "$complaint" >&2
                    printf 'git listed it, so something is wrong that a skip would hide.\n' >&2
                    rm -rf "$work"
                    exit 2
                fi
                scan_symlinks=$((scan_symlinks + 1))
                scan_links+=("$path"$'\t'"$target")
                printf '%s\n' "$target"
                continue
            fi

            if [ "$entry_mode" = 160000 ]; then
                # Its own repository, with its own hooks and its own object
                # database. There is no blob here to read and nothing hidden by
                # not reading one -- but the path above is this repository's.
                scan_skipped+=("$path (a submodule -- no blob in this repository)")
                continue
            fi

            scan_files=$((scan_files + 1))
            if entry_was_searched "$key"; then
                scan_searched=$((scan_searched + 1))
                continue
            fi

            # git grep would not read it. That is a verdict about git's
            # attributes and heuristics, not about the bytes, so the bytes are
            # fetched from the object database -- which no attribute can stop --
            # and the binary question is answered here, on the content, the way
            # git itself answers it: a NUL in the first 8000 bytes.
            if ! git cat-file blob "$oid" >"$blob_file" 2>"$complaint"; then
                printf 'no-private-repo-names: could not read %s\n' "$path" >&2
                cat "$complaint" >&2
                printf 'git listed it, so something is wrong that a skip would hide.\n' >&2
                rm -rf "$work"
                exit 2
            fi
            nul_count="$(LC_ALL=C head -c 8000 <"$blob_file" |
                LC_ALL=C tr -dc '\000' | wc -c)"
            if [ "$nul_count" -gt 0 ]; then
                scan_skipped+=("$path (binary -- no repository name to read out of it)")
                continue
            fi
            grep_status=0
            grep -Ei -e "$forms" <"$blob_file" || grep_status=$?
            if [ "$grep_status" -gt 1 ]; then
                printf 'no-private-repo-names: could not search %s\n' "$path" >&2
                printf 'grep exited %s over a blob git handed over in full.\n' "$grep_status" >&2
                rm -rf "$work"
                exit 2
            fi
            scan_searched=$((scan_searched + 1))
            # Only for a path the scope's tree actually holds. scan_direct is
            # replayed as a PATHSPEC against that tree, and a range blob is at
            # no path in it -- the pathspec would either match nothing or, worse,
            # match whatever blob sits at that path now and report the finding
            # against the wrong bytes. Range blobs are located as objects
            # instead, in report_range, which reaches every one of them and does
            # not need a list of the ones grep declined.
            [ "$origin" = "$SCOPE_TREE_ORIGIN" ] || continue
            scan_direct+=("$token"$'\t'"$path")
        done <"$entries_file"

        # The messages of the commits being published. A commit made without
        # `git commit` running hooks -- `git commit-tree`, a rebase, a
        # cherry-pick, `git am`, `--no-verify`, or a fast-forward carrying
        # somebody else's commit in from a hookless clone -- never met the
        # commit-msg guard, and until this the pre-push guards read only the
        # TREE. Measured: a subject line naming a private repository reached a
        # remote with every hook green and no override of any kind.
        if ! "$scope_tool" --messages "$token" >"$messages_file" 2>"$complaint"; then
            printf 'no-private-repo-names: could not read the messages %s publishes\n' "$token" >&2
            cat "$complaint" >&2
            rm -rf "$work"
            exit 2
        fi
        while IFS= read -r -d '' rec; do
            [ -n "$rec" ] || continue
            scan_messages=$((scan_messages + 1))
            scan_msgs+=("$rec")
            printf '%s\n' "${rec#*$'\t'}"
        done <"$messages_file"
    done

    rm -rf "$work"

    # An empty scope is a broken enumeration, never a clean tree. It is the same
    # refusal the old `git ls-files | head -n1` made, moved to the thing that
    # now decides what is in scope, so it still covers the empty repository and
    # additionally covers a resolver that named a tree with nothing in it.
    if [ "$scan_entries" -eq 0 ]; then
        printf 'no-private-repo-names: nothing to scan -- the tree named holds no files\n' >&2
        exit 2
    fi
}

# `--cached` is an OPTION and a rev is a POSITIONAL, so the two spellings cannot
# be produced by one array of extra arguments and the case below is the whole of
# the difference. It is a function because both readers need it, and a rule with
# two implementations is two rules.
#
# The blobs the pushed RANGE introduced go in as further positionals. `git grep`
# takes an object name where it takes a tree, so one process reads the tree being
# pushed and every blob that passed through the range on its way to being
# deleted: measured, 782 range blobs of a 705-commit history in 0.20s, against
# 9.7s to fetch and search them one `git cat-file` at a time. Two things follow
# from a blob having no path: git names the finding by OID, which report_range
# turns back into a path and a commit -- and no `diff` attribute can be consulted
# for it, so the case that hid a plain-ASCII file from every grep in this file
# cannot arise on this half at all.
#
# Gitlinks and symlinks are deliberately NOT in that list. A gitlink's oid is
# another repository's commit and git grep would refuse to read it -- a refusal
# on stderr ends the whole scan, correctly, over an object that was never this
# repository's to read. A symlink's blob is read by the entries loop itself,
# which is where the target is turned into text a candidate can be extracted
# from, and passing it here as well would search the same bytes twice.
#
# The list is an argument vector, so it is bounded by the kernel's, at forty-one
# bytes apiece: a range introducing tens of thousands of blobs would fail to
# START git grep. That lands on an empty result with a word on stderr, which
# check_grep_complaint turns into exit 2 -- a refusal naming the limit, not a
# clean tree.
grep_scope() {
    local scope="$1"
    shift
    if [ "$scope" = ':index' ]; then
        git grep --cached "$@"
    else
        git grep "$@" "$scope"
    fi
}

# The oids of the range blobs recorded for one scope, one per line. Safe to read
# line by line where nothing else here is: an object name is hex.
range_blobs_of() {
    local scope="$1" entry
    for entry in ${scan_range[@]+"${scan_range[@]}"}; do
        [ "${entry%%$'\t'*}" = "$scope" ] || continue
        entry="${entry#*$'\t'}"
        printf '%s\n' "${entry%%$'\t'*}"
    done
}

# The scope AND the blobs the range introduced, in one process. Separate from
# grep_scope because a pathspec is a question about a TREE: locate_candidate
# replays the paths git grep declined as `-- :(literal)<path>`, and objects
# named beside a pathspec are objects that pathspec cannot describe.
grep_scope_with_range() {
    local scope="$1" oid
    shift
    if [ "$scope" = ':index' ]; then
        git grep --cached "$@"
        return
    fi
    local -a blobs=()
    while IFS= read -r oid; do
        [ -n "$oid" ] || continue
        blobs+=("$oid")
    done < <(range_blobs_of "$scope")
    git grep "$@" "$scope" ${blobs[@]+"${blobs[@]}"}
}

# Where a confirmed name actually appears, so the report names a file and a line
# rather than only a repository.
#
# Every half of the scan again, and there are five. `git grep` over the same
# scope it was read from -- never the working tree, which is a different tree
# and may not hold the finding at all. The blobs that grep would not read as
# text, re-read with --text so the same attribute cannot hide the finding twice.
# The blobs the pushed RANGE introduced, which are at no path in that tree and
# are named as objects. The symlinks it skipped, quoted from the scan rather than
# opened again. And the paths and commit messages, which are text no grep over
# file CONTENT can find anything in at all.
locate_candidate() {
    local needle="$1" entry path target sha body oid hit
    local scope index count="${#scan_scopes[@]}"
    local -a specs blobs
    {
        for ((index = 0; index < count; index++)); do
            scope="${scan_scopes[$index]}"
            grep_scope "$scope" -nIFi -e "$needle" 2>/dev/null || true

            specs=()
            for entry in ${scan_direct[@]+"${scan_direct[@]}"}; do
                [ "${entry%%$'\t'*}" = "$scope" ] || continue
                specs+=(":(literal)${entry#*$'\t'}")
            done
            if [ "${#specs[@]}" -gt 0 ]; then
                grep_scope "$scope" -naFi -e "$needle" -- "${specs[@]}" 2>/dev/null || true
            fi

            # The range half, named the way a reader can act on it. A file the
            # push added and then deleted has no path to open and no line number
            # worth printing -- what there is to do about it is to rewrite the
            # commit that added it, so that is what the finding says. `-a`
            # because a blob git declined to read as text still holds the name;
            # `-l` because the whole point is WHICH object, and the object name
            # on its own tells a reader nothing.
            blobs=()
            while IFS= read -r oid; do
                [ -n "$oid" ] || continue
                blobs+=("$oid")
            done < <(range_blobs_of "$scope")
            if [ "${#blobs[@]}" -gt 0 ]; then
                while IFS= read -r hit; do
                    [ -n "$hit" ] || continue
                    for entry in ${scan_range[@]+"${scan_range[@]}"}; do
                        [ "${entry%%$'\t'*}" = "$scope" ] || continue
                        entry="${entry#*$'\t'}"
                        [ "${entry%%$'\t'*}" = "$hit" ] || continue
                        entry="${entry#*$'\t'}"
                        sha="${entry%%$'\t'*}"
                        printf '%s: added by commit %s and gone by the tip -- still in the range this push publishes\n' \
                            "${entry#*$'\t'}" "${sha:0:12}"
                    done
                done < <(git grep -laFi -e "$needle" "${blobs[@]}" 2>/dev/null || true)
            fi
        done
        for entry in ${scan_links[@]+"${scan_links[@]}"}; do
            path="${entry%%$'\t'*}"
            target="${entry#*$'\t'}"
            if printf '%s' "$target" | grep -qFi -- "$needle"; then
                printf '%s: a symlink whose target is %s\n' "$path" "$target"
            fi
        done
        for path in ${scan_names[@]+"${scan_names[@]}"}; do
            if printf '%s' "$path" | grep -qFi -- "$needle"; then
                printf '%s: the PATH itself names it\n' "$path"
            fi
        done
        for entry in ${scan_msgs[@]+"${scan_msgs[@]}"}; do
            sha="${entry%%$'\t'*}"
            body="${entry#*$'\t'}"
            if printf '%s' "$body" | grep -qFi -- "$needle"; then
                printf 'commit %s: its MESSAGE names it\n' "${sha:0:12}"
            fi
        done
    } | head -n 20 || true
}

# The denominator, and what it is a denominator OF. A tree-wide scan that prints
# only findings cannot be told apart from one that read nothing: the old mode
# exited 0 in silence whether it had crossed nine hundred files or none, and a
# reader had no way to see which. The label matters as much as the number,
# because "25 path(s)" is the same sentence about the index, about the commit
# being pushed, and about a checkout of something else entirely.
#
# The file count is what was SEARCHED, not what was enumerated, and the two are
# printed side by side because their difference is the whole story: a committed
# `*.log -diff` used to move files from one to the other silently, leaving the
# number unchanged and the bytes unread. Every path in the gap is named below,
# with the reason it was not searched, so the gap can never be a blank.
print_scan_denominator() {
    local label note
    printf 'no-private-repo-names: %s of %s file(s) searched, %s symlink target(s), %s path name(s), %s commit message(s)\n' \
        "$scan_searched" "$scan_files" "$scan_symlinks" \
        "$scan_entries" "$scan_messages"
    # THE TWO HALVES, because a push introduces both and they catch different
    # things. The tree catches what arrived before this range and is still
    # there; the range catches what passed through it -- a blob added in one
    # pushed commit and removed in the next, permanent on the remote and in no
    # tip tree. One total for the two would be a number that cannot tell a
    # repository of 150 files from a repository of 2 with 148 deletions in the
    # push, and the second is the one worth looking at.
    printf '  %s path(s) in the tree scanned, %s additional blob(s) introduced by the pushed range\n' \
        "$scan_tree_entries" "$scan_range_entries"
    for label in ${scan_labels[@]+"${scan_labels[@]}"}; do
        printf '  scanned %s\n' "$label"
    done
    for note in ${scan_skipped[@]+"${scan_skipped[@]}"}; do
        printf '  skipped %s\n' "$note"
    done
}

# The lines this commit ADDS, and then the paths git would not diff as text.
#
# `git diff` consults the `diff` ATTRIBUTE before it looks at a single byte,
# exactly as `git grep` does. A committed `*.log -diff` -- two lines, in the
# same commit if you like -- reduces a plain-ASCII file to `Binary files a/x and
# b/x differ`, so not one of its added lines reaches the extractor and this mode
# exits 0 with nothing printed. The attribute is a claim about how to RENDER a
# change; whether there is readable text in there is a question about the blob,
# and the second pass asks it of the blob.
#
# The second pass re-diffs only those paths, with --text, rather than reading
# the whole staged blob: the unit of this mode is what the commit ADDS, and a
# file that already named something is a problem to fix deliberately rather than
# a wall every later commit runs into. --tracked is what finds those.
staged_added_lines() {
    local rec added rest path oid blob nul_count

    # No pathspec. The index is the whole commit, and `-- .` limited it to
    # whatever directory the hook happened to start in.
    git diff --cached --no-color -U0 |
        grep -E '^\+' |
        grep -Ev '^\+\+\+' || true

    blob="$(mktemp)"
    while IFS= read -r -d '' rec; do
        added="${rec%%$'\t'*}"
        rest="${rec#*$'\t'}"
        path="${rest#*$'\t'}"
        if [ -z "$path" ]; then
            # A rename or a copy: -z spells it as this record and then the
            # source and the destination, each its own record.
            IFS= read -r -d '' path || break
            IFS= read -r -d '' path || break
        fi
        # `-` for both counts is git saying it did not diff this path as text.
        # That is the only signal there is, and it means "binary heuristic" and
        # "attribute" alike -- which is exactly why the blob is consulted next.
        [ "$added" = '-' ] || continue
        # Not in the index at all: the change is a deletion, and a deletion adds
        # no line to any commit.
        oid="$(git rev-parse --verify --quiet ":$path" 2>/dev/null)" || continue
        [ -n "$oid" ] || continue
        if ! git cat-file blob "$oid" >"$blob" 2>/dev/null; then
            printf 'no-private-repo-names: could not read the staged blob for %s\n' "$path" >&2
            printf 'git named it as changed, so a skip here would hide something.\n' >&2
            rm -f "$blob"
            exit 2
        fi
        nul_count="$(LC_ALL=C head -c 8000 <"$blob" | LC_ALL=C tr -dc '\000' | wc -c)"
        [ "$nul_count" -eq 0 ] || continue
        git diff --cached --no-color -U0 --text -- ":(literal)$path" |
            grep -E '^\+' |
            grep -Ev '^\+\+\+' || true
    done < <(git diff --cached --numstat -z)
    rm -f "$blob"
}

# The text to inspect: the message being written, or any text a caller names.
#
# Staged and tracked mode are not here, and their absence is deliberate. This
# function is called inside a command substitution, which is a subshell; the
# tree-wide scan has to leave its scopes, labels and counts behind it and the
# staged scan has to be able to exit 2 out of the whole script, and neither
# survives one. Both are invoked separately below, with stdout redirected to a
# file instead.
read_subject_text() {
    if [ "$mode" = text ]; then
        # A named file, or stdin. Nothing is stripped: see the header.
        if [ -n "$subject" ] && [ "$subject" != "-" ]; then
            cat -- "$subject"
        else
            cat
        fi
        return
    fi

    # Comment lines are stripped by git before the message is stored.
    grep -Ev '^[[:space:]]*#' "$subject" || true
}

# Candidate owner/repo mentions, in the three forms that actually name a repo:
# a forge URL, a cross-repo issue reference, and — only for owners already
# declared private — a bare `owner/repo`. Bare pairs are otherwise left alone:
# `src/main.rs` and `and/or` are not repositories, and a guard that cries wolf
# gets bypassed by reflex.
extract_candidates() {
    local text="$1"
    # Each form ends in `|| true`: a form that matches nothing is the normal
    # case, and under `set -e` its non-zero grep would abandon the whole group —
    # silently, with every later form unevaluated. A detector that stops looking
    # after the first miss reports "nothing found" for the wrong reason.
    {
        printf '%s\n' "$text" |
            grep -Eio '[a-z0-9.-]+\.[a-z]{2,}[:/][A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*' |
            sed -E 's#^[^:/]+[:/]##; s#\.git$##' || true

        printf '%s\n' "$text" |
            grep -Eo '[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*#[0-9]+' |
            sed -E 's/#[0-9]+$//' || true

        local owner
        for owner in ${private_owners//,/ }; do
            [ -n "$owner" ] || continue
            printf '%s\n' "$text" |
                grep -Eio "(^|[^A-Za-z0-9._/-])$(regex_escape_name "$owner")/[A-Za-z0-9][A-Za-z0-9._-]*" |
                sed -E 's#^[^A-Za-z0-9]##' || true
        done
    } | sed -E 's#\.$##' | sort -u
}

if [ "$mode" = tracked ]; then
    # Redirected to a file rather than captured, so that the scan runs in THIS
    # shell and its scopes, labels and counts are still set when the report is
    # written. A command substitution would fork, and everything it learned
    # about what it read would go with the fork.
    scan_output="$(mktemp)"
    read_tracked_text >"$scan_output"
    # Printed before any verdict, because it is true regardless of one: it says
    # what was read, and a run that goes on to exit 0 for a private repository,
    # or to find nothing at all, still owes a reader that sentence.
    print_scan_denominator
    text="$(cat "$scan_output")"
    rm -f "$scan_output"
elif [ "$mode" = staged ]; then
    # Redirected for the same reason, and one of its own: this scan can refuse
    # outright when git will not hand over a blob it has just named as changed,
    # and an `exit 2` inside a command substitution ends the subshell rather
    # than the run.
    scan_output="$(mktemp)"
    staged_added_lines >"$scan_output"
    text="$(cat "$scan_output")"
    rm -f "$scan_output"
else
    text="$(read_subject_text)"
fi
[ -n "$text" ] || exit 0

# In --text mode the caller has already decided the destination is public --
# that is why it is asking. Re-deriving the answer from $PWD would ask about
# the wrong repository entirely: the text is usually being written from a
# checkout that is not where it is going.
if [ "$mode" != text ]; then
    if ! this_repo_is_public; then
        if [ "${GIT_GUARDS_REFUSE_UNKNOWN:-}" = "1" ] &&
            [ "${this_repo_visibility:-unknown}" = unknown ]; then
            printf 'error: could not determine whether this repository is public.\n' >&2
            printf 'Refusing because GIT_GUARDS_REFUSE_UNKNOWN=1. Set\n' >&2
            printf 'GIT_GUARDS_REPO_VISIBILITY=public|private to answer it directly.\n' >&2
            exit 2
        fi
        exit 0
    fi
fi

# A candidate the forge could not answer for is its own outcome. `gh api`
# returns 404 both for a repository that does not exist and for a private one
# this token cannot see -- and the second is the case this guard exists for.
# Folding it into "not private" is the guard reporting a pass for a question it
# never got an answer to.
#
# Takes one argument: whether this call is allowed to end the run. It is not,
# when a private name was already found -- that refusal is exit 1 and more
# specific, and downgrading it to "could not look" would lose the finding.
report_unresolved() {
    local may_exit="$1" entry label
    [ "${#unresolved[@]}" -gt 0 ] || return 0

    if [ "${GIT_GUARDS_REFUSE_UNKNOWN:-}" = "1" ] && [ "$may_exit" = yes ]; then
        label=error
    else
        label=note
    fi
    printf '%s: could not determine whether these are private:\n' "$label" >&2
    for entry in "${unresolved[@]}"; do
        printf '  %s\n' "$entry" >&2
    done
    cat >&2 <<EOF
A 404 from the forge means "no such repository, or not visible to this token",
and this guard cannot tell those apart. Set GIT_GUARDS_PUBLIC_REPOS=owner/repo
once you have confirmed one, or GIT_GUARDS_REFUSE_UNKNOWN=1 to treat every
unresolved name as private.
EOF

    if [ "${GIT_GUARDS_REFUSE_UNKNOWN:-}" = "1" ] && [ "$may_exit" = yes ]; then
        exit 2
    fi
}

found=()
found_names=()
unresolved=()
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    owner="${candidate%%/*}"

    list_has "$candidate" "$public_repos" && continue
    list_has "$owner" "$public_repos" && continue

    if list_has "$owner" "$private_owners"; then
        found+=("$candidate (owner in GIT_GUARDS_PRIVATE_OWNERS)")
        found_names+=("$candidate")
        continue
    fi

    visibility="$(lookup_visibility "$candidate")"
    if is_private "$visibility"; then
        found+=("$candidate ($visibility)")
        found_names+=("$candidate")
    elif [ "$visibility" = unknown ]; then
        unresolved+=("$candidate")
    fi
done < <(extract_candidates "$text")

# A tree-wide scan crosses every example URL, every placeholder and every forge
# `gh` cannot answer for, so unresolved names are counted in the hundreds rather
# than the ones. Reporting them by default would bury the finding that matters
# under names nobody can act on. Ask for them and they are reported.
if [ "$mode" = tracked ] && [ "${GIT_GUARDS_REFUSE_UNKNOWN:-}" != "1" ]; then
    unresolved=()
fi

if [ "${#found[@]}" -eq 0 ]; then
    report_unresolved yes
    exit 0
fi

report_unresolved no

if [ "$mode" = text ]; then
    printf 'error: this text names a private repository:\n' >&2
elif [ "$mode" = staged ]; then
    printf 'error: staged changes name a private repository in a public repo:\n' >&2
elif [ "$mode" = tracked ]; then
    printf 'error: tracked files name a private repository in a public repo:\n' >&2
else
    printf 'error: this commit message names a private repository in a public repo:\n' >&2
fi

for index in "${!found[@]}"; do
    printf '  %s\n' "${found[$index]}" >&2
    if [ "$mode" = tracked ]; then
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            printf '    %s\n' "$hit" >&2
        done < <(locate_candidate "${found_names[$index]}")
    fi
done

cat >&2 <<EOF
A public repo's contents and history are permanent and indexable, and a commit
message cannot be edited afterwards without rewriting it. Describe the shape
instead and use a placeholder — github.com/acme/workspace.git, "a workspace with nested clones".
Redact owner and repo names before pasting real output.

Set GIT_GUARDS_PUBLIC_REPOS=owner/repo if this name is not actually private, or
$allow_var=1 for a deliberate one-off bypass.
EOF

exit 1
