#!/usr/bin/env bash
set -euo pipefail

# The outermost work tree enclosing $1, stopping below $HOME.
#
# A nested repo — a submodule, or a plain clone sitting inside another checkout
# — belongs to the workspace that contains it, and it is that workspace's owner
# the push is judged against. The climb stops at $HOME so a dotfiles repo at
# $HOME can never become "the workspace" for every project beneath it.
outermost_worktree() {
    local root="$1" parent
    while [ "$root" != "/" ] && [ "$root" != "${HOME:-/}" ]; do
        parent="$(git -C "$root/.." rev-parse --show-toplevel 2>/dev/null || true)"
        [ -n "$parent" ] || break
        [ "$parent" != "$root" ] || break
        [ "$parent" != "${HOME:-}" ] || break
        root="$parent"
    done
    printf '%s\n' "$root"
}

# Ask git which repo is being pushed; never infer it from this script's path.
#
# pre-commit, prek and lefthook all run hooks with the working directory at the
# project root, so git can answer. The script's own location cannot: hook
# runners *fetch* this file into a cache (`~/.cache/prek/repos/<hash>/`), where
# `dirname($0)/..` is the cache directory. Its basename — `repos` — then became
# the entire allow-list, and every push was refused, including a repo pushing to
# its own origin. A guard whose allow-list is a cache path name is not a guard.
pushed_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
workspace_root="$(outermost_worktree "$pushed_repo_root")"

remote_name="${PRE_COMMIT_REMOTE_NAME:-${1:-origin}}"
remote_url="${PRE_COMMIT_REMOTE_URL:-${2:-}}"

if [ -z "$remote_url" ]; then
    remote_url="$(git -C "$pushed_repo_root" remote get-url --push "$remote_name" 2>/dev/null || true)"
fi

if [ -z "$remote_url" ]; then
    remote_url="$(git -C "$pushed_repo_root" remote get-url "$remote_name" 2>/dev/null || true)"
fi

redact_url() {
    local url="$1"

    if [[ "$url" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/@]+@)(.*)$ ]]; then
        printf '%s<redacted>@%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
        return
    fi

    printf '%s\n' "$url"
}

repo_from_url() {
    local url="$1"
    local path owner repo extra

    url="${url%%#*}"
    url="${url%%\?*}"

    if [[ "$url" =~ ^[^@/:]+@([^:]+):(.+)$ ]]; then
        path="${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^ssh://([^/@]+@)?([^/:]+)(:[0-9]+)?/(.+)$ ]]; then
        path="${BASH_REMATCH[4]}"
    elif [[ "$url" =~ ^https?://([^/@]+@)?([^/:]+)(:[0-9]+)?/(.+)$ ]]; then
        path="${BASH_REMATCH[4]}"
    else
        return 1
    fi

    path="${path#/}"
    path="${path%/}"
    path="${path%.git}"

    IFS=/ read -r owner repo extra <<< "$path"
    [ -n "${owner:-}" ] || return 1
    [ -n "${repo:-}" ] || return 1

    repo="${repo%.git}"
    printf '%s/%s\n' "$owner" "$repo"
}

# The owner the push is judged against, DECLARED rather than derived.
#
# Deriving it from `origin` is tautological for the one remote most likely to be
# wrong: repointing origin at a public upstream — the exact accident this script
# exists to prevent — also repoints the allow-list, so the push is permitted and
# the hook exits 0. A pinned constant cannot be moved by the mistake it guards.
#
# Two places, checked in this order, and both are things a person changes on
# purpose rather than things a command changes as a side effect:
#
#   1. $WORKSPACE_PINNED_OWNER in the environment.
#   2. `.git-guards-owner` in the workspace root, one line, committed. This is the
#      stronger of the two: repointing origin cannot touch it, and changing it is a
#      diff somebody reviews.
#
# When neither is present this falls back to the origin-derived answer, so a
# repository that has declared nothing is still guarded. That fallback is the
# weaker mode -- it is the one the reasoning above says can be moved by the
# mistake it guards -- and it says so at the point of refusal rather than
# passing itself off as the pinned one.
pinned_owner() {
    if [ -n "${WORKSPACE_PINNED_OWNER:-}" ]; then
        printf '%s\n' "$WORKSPACE_PINNED_OWNER"
        return 0
    fi
    local declared="$workspace_root/.git-guards-owner"
    if [ -f "$declared" ]; then
        # One line, trimmed. A file with anything else in it is a config error and
        # must not be guessed at.
        local first
        first="$(head -n1 "$declared" | tr -d '[:space:]')"
        if [ -n "$first" ]; then
            printf '%s\n' "$first"
            return 0
        fi
    fi
    return 1
}

# The owner `origin` actually names — the workspace's, else the pushed repo's —
# or nothing at all when neither has an origin this script can read.
#
# "No origin" and "an origin naming somebody else" are different facts, and one
# caller below turns on telling them apart. Folding them together produced a
# refusal that read `origin owner is orphan, but this workspace is pinned to
# Acme` for a repository with no origin whatsoever: `orphan` was the directory's
# name, arriving through a last resort that belongs to a different question, and
# the sentence it landed in was about origin. Somebody then goes looking for a
# remote that is not there.
owner_named_by_origin() {
    local dir origin_url origin_repo

    for dir in "$workspace_root" "$pushed_repo_root"; do
        origin_url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
        if [ -n "$origin_url" ] && origin_repo="$(repo_from_url "$origin_url")"; then
            printf '%s\n' "${origin_repo%%/*}"
            return 0
        fi
    done

    return 1
}

# The owner to judge against when nothing was pinned. Here the directory name IS
# an acceptable last resort: some owner has to be picked, and the workspace's own
# name is the least surprising guess. It is a guess, and only this caller wants
# one.
workspace_owner_from_origin() {
    owner_named_by_origin && return 0
    basename "$workspace_root"
}

env_prefix_for_owner() {
    printf '%s' "$1" |
        LC_ALL=C tr '[:lower:]' '[:upper:]' |
        LC_ALL=C tr -c 'A-Z0-9_' '_'
}

owner_is_pinned=1
if ! workspace_owner="$(pinned_owner)"; then
    owner_is_pinned=0
    workspace_owner="$(workspace_owner_from_origin)"
fi
workspace_env_prefix="$(env_prefix_for_owner "$workspace_owner")"

allowed_owners_var="${workspace_env_prefix}_ALLOWED_PUSH_OWNERS"
# A per-REPO allow-list, finer than per-owner. An owner is a blunt unit: allowing
# one to let a single repository through allows every repository it will ever have.
allowed_repos_var="${workspace_env_prefix}_ALLOWED_PUSH_REPOS"
allow_unsafe_var="${workspace_env_prefix}_ALLOW_UNSAFE_PUSH"

allowed_owners="${WORKSPACE_ALLOWED_PUSH_OWNERS:-$workspace_owner}"
allowed_repos="${WORKSPACE_ALLOWED_PUSH_REPOS:-}"
allow_unsafe="${WORKSPACE_ALLOW_UNSAFE_PUSH:-}"

unsafe_hint="$allow_unsafe_var"

if [ -n "${WORKSPACE_ALLOW_UNSAFE_PUSH+x}" ]; then
    unsafe_hint=WORKSPACE_ALLOW_UNSAFE_PUSH
fi

if [ -n "${!allowed_owners_var+x}" ]; then
    allowed_owners="${!allowed_owners_var}"
fi

if [ -n "${!allowed_repos_var+x}" ]; then
    allowed_repos="${!allowed_repos_var}"
fi

if [ -n "${!allow_unsafe_var+x}" ]; then
    allow_unsafe="${!allow_unsafe_var}"
    unsafe_hint="$allow_unsafe_var"
fi

# A repo is allowed by its FULL name first, then by its owner. Checking the repo
# first is what makes the finer list useful: allowing one repository must not
# require allowing everything its owner will ever hold.
is_allowed_repo() {
    local full="$1"
    local owner_lc="${full%%/*}"
    owner_lc="${owner_lc,,}"
    local full_lc="${full,,}"
    local item

    for item in ${allowed_repos//,/ }; do
        [ -n "$item" ] || continue
        [ "${item,,}" = "$full_lc" ] && return 0
    done

    for item in ${allowed_owners//,/ }; do
        [ -n "$item" ] || continue
        [ "${item,,}" = "$owner_lc" ] && return 0
    done

    return 1
}

if [ "$allow_unsafe" = "1" ]; then
    printf 'warning: %s=1 set; skipping push destination guard for %s\n' \
        "$unsafe_hint" \
        "$(redact_url "$remote_url")" >&2
    exit 0
fi

# A repointed origin is not a new allow-list — it is the accident. Say so, and
# refuse, rather than quietly judging the push against wherever origin now points.
#
# BELOW the bypass, and that position is the whole of it. Run above it, this
# check would reach its `exit 1` before allow_unsafe had been read, and every
# escape the README documents — <OWNER>_ALLOW_UNSAFE_PUSH,
# WORKSPACE_ALLOW_UNSAFE_PUSH — would be inert the moment a pin existed. A guard
# with a documented bypass that does not work is worse than one with none:
# somebody sets the variable, watches the push fail anyway, and reaches for
# --no-verify, which turns off every hook here rather than this one.
#
# The allow-lists deliberately do NOT defeat it. `<OWNER>_ALLOWED_PUSH_OWNERS`
# says which destinations are acceptable; this says the workspace is not in the
# state its owner thinks it is, and that is true whatever this particular push
# targets. Only the bypass — which means "I know, do it anyway" — outranks it.
if [ "$owner_is_pinned" = 1 ] && origin_owner="$(owner_named_by_origin)"; then
    if [ "$origin_owner" != "$workspace_owner" ]; then
        printf 'error: origin owner is %s, but this workspace is pinned to %s\n' \
            "$origin_owner" "$workspace_owner" >&2
        printf 'A pinned owner is not derived from a remote, so a repointed origin cannot\n' >&2
        printf 'widen it. If the move is intended, change the pin.\n' >&2
        printf 'Set %s=1 for a deliberate one-off bypass.\n' "$unsafe_hint" >&2
        exit 1
    fi
fi

if [ -z "$remote_url" ]; then
    printf 'error: blocked push because remote "%s" has no resolvable push URL\n' "$remote_name" >&2
    printf 'Set %s=1 for a deliberate one-off bypass.\n' "$unsafe_hint" >&2
    exit 1
fi

if repo="$(repo_from_url "$remote_url")"; then
    if is_allowed_repo "$repo"; then
        exit 0
    fi

    printf 'error: blocked push to %s\n' "$(redact_url "$remote_url")" >&2
    printf 'Remote "%s" resolves to repo "%s" (outside allowed owner(s): %s).\n' \
        "$remote_name" "$repo" "$allowed_owners" >&2
    printf 'This guard prevents accidental pushes to public upstreams or personal forks.\n' >&2
    printf 'Use %s=1 for a deliberate one-off bypass.\n' "$unsafe_hint" >&2
    exit 1
fi

printf 'error: blocked push to unrecognised remote %s\n' "$(redact_url "$remote_url")" >&2
printf 'Could not parse owner/repo from the remote URL.\n' >&2
printf 'Set %s=1 for a deliberate one-off bypass.\n' "$unsafe_hint" >&2
exit 1
