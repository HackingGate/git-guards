#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd -- "$script_dir/.." && pwd -P)"

remote_name="${PRE_COMMIT_REMOTE_NAME:-${1:-origin}}"
remote_url="${PRE_COMMIT_REMOTE_URL:-${2:-}}"

if [ -z "$remote_url" ]; then
    remote_url="$(git -C "$workspace_root" remote get-url --push "$remote_name" 2>/dev/null || true)"
fi

if [ -z "$remote_url" ]; then
    remote_url="$(git -C "$workspace_root" remote get-url "$remote_name" 2>/dev/null || true)"
fi

redact_url() {
    local url="$1"

    if [[ "$url" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/@]+@)(.*)$ ]]; then
        printf '%s<redacted>@%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
        return
    fi

    printf '%s\n' "$url"
}

github_repo_from_url() {
    local url="$1"
    local path owner repo extra

    url="${url%%#*}"
    url="${url%%\?*}"

    if [[ "$url" =~ ^https?://([^/@]+@)?github\.com[:/](.+)$ ]]; then
        path="${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^ssh://([^/@]+@)?github\.com(:[0-9]+)?/(.+)$ ]]; then
        path="${BASH_REMATCH[3]}"
    elif [[ "$url" =~ ^git@github\.com:(.+)$ ]]; then
        path="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ ^github\.com[:/](.+)$ ]]; then
        path="${BASH_REMATCH[1]}"
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

workspace_owner_from_origin() {
    local origin_url origin_repo

    origin_url="$(git -C "$workspace_root" remote get-url origin 2>/dev/null || true)"
    if [ -n "$origin_url" ] && origin_repo="$(github_repo_from_url "$origin_url")"; then
        printf '%s\n' "${origin_repo%%/*}"
        return
    fi

    basename "$workspace_root"
}

env_prefix_for_owner() {
    printf '%s' "$1" |
        LC_ALL=C tr '[:lower:]' '[:upper:]' |
        LC_ALL=C tr -c 'A-Z0-9_' '_'
}

workspace_owner="$(workspace_owner_from_origin)"
workspace_env_prefix="$(env_prefix_for_owner "$workspace_owner")"

allowed_owners_var="${workspace_env_prefix}_ALLOWED_PUSH_OWNERS"
allowed_repos_var="${workspace_env_prefix}_ALLOWED_PUSH_REPOS"
allow_external_var="${workspace_env_prefix}_ALLOW_EXTERNAL_PUSH"
allow_unsafe_var="${workspace_env_prefix}_ALLOW_UNSAFE_PUSH"

allowed_owners="${WORKSPACE_ALLOWED_PUSH_OWNERS:-$workspace_owner}"
allowed_repos="${WORKSPACE_ALLOWED_PUSH_REPOS:-}"
allow_external="${WORKSPACE_ALLOW_EXTERNAL_PUSH:-}"
allow_unsafe="${WORKSPACE_ALLOW_UNSAFE_PUSH:-}"

external_hint="$allow_external_var"
unsafe_hint="$allow_unsafe_var"

if [ -n "${WORKSPACE_ALLOW_EXTERNAL_PUSH+x}" ]; then
    external_hint=WORKSPACE_ALLOW_EXTERNAL_PUSH
fi

if [ -n "${WORKSPACE_ALLOW_UNSAFE_PUSH+x}" ]; then
    unsafe_hint=WORKSPACE_ALLOW_UNSAFE_PUSH
fi

if [ -n "${!allowed_owners_var+x}" ]; then
    allowed_owners="${!allowed_owners_var}"
fi

if [ -n "${!allowed_repos_var+x}" ]; then
    allowed_repos="${!allowed_repos_var}"
fi

if [ -n "${!allow_external_var+x}" ]; then
    allow_external="${!allow_external_var}"
    external_hint="$allow_external_var"
fi

if [ -n "${!allow_unsafe_var+x}" ]; then
    allow_unsafe="${!allow_unsafe_var}"
    unsafe_hint="$allow_unsafe_var"
fi

is_allowed_repo() {
    local github_repo="$1"
    local owner="${github_repo%%/*}"
    local owner_lc="${owner,,}"
    local repo_lc="${github_repo,,}"
    local item

    for item in ${allowed_repos//,/ }; do
        [ -n "$item" ] || continue
        if [ "${item,,}" = "$repo_lc" ]; then
            return 0
        fi
    done

    for item in ${allowed_owners//,/ }; do
        [ -n "$item" ] || continue
        if [ "${item,,}" = "$owner_lc" ]; then
            return 0
        fi
    done

    return 1
}

if [ "$allow_unsafe" = "1" ]; then
    printf 'warning: %s=1 set; skipping push destination guard for %s\n' \
        "$unsafe_hint" \
        "$(redact_url "$remote_url")" >&2
    exit 0
fi

if [ -z "$remote_url" ]; then
    printf 'error: blocked push because remote "%s" has no resolvable push URL\n' "$remote_name" >&2
    printf 'Set %s=1 for a deliberate one-off bypass.\n' "$unsafe_hint" >&2
    exit 1
fi

if github_repo="$(github_repo_from_url "$remote_url")"; then
    if is_allowed_repo "$github_repo"; then
        exit 0
    fi

    printf 'error: blocked push to %s\n' "$(redact_url "$remote_url")" >&2
    printf 'Remote "%s" resolves to GitHub repo "%s", which is outside allowed owner(s): %s\n' \
        "$remote_name" "$github_repo" "$allowed_owners" >&2
    printf 'This guard prevents accidental pushes to public upstreams or personal forks.\n' >&2
    printf 'Use %s=1 for a deliberate one-off bypass.\n' "$unsafe_hint" >&2
    exit 1
fi

if [ "$allow_external" = "1" ]; then
    exit 0
fi

printf 'error: blocked push to non-allowlisted remote %s\n' "$(redact_url "$remote_url")" >&2
printf 'Only github.com/%s/* pushes are allowed by default.\n' "$allowed_owners" >&2
printf 'Set %s=1 for trusted non-GitHub remotes, or %s=1 for a one-off bypass.\n' \
    "$external_hint" "$unsafe_hint" >&2
exit 1
