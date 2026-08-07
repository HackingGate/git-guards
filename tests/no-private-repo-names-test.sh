#!/usr/bin/env bash
# Behaviour tests for no-private-repo-names.sh.
#
# `gh` is stubbed on PATH, so these are offline and deterministic: the stub
# answers `public` for acme/public-tool and `private` for acme/secret-thing, and
# 404s for anything else — the same three answers the real API gives.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Hermetic against the caller's environment. tests/hermetic-env.sh names every
# variable a git-guards test must not inherit and why; the loop is here rather
# than there because unsetting has to happen in THIS shell.
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$repo_root/tests/hermetic-env.sh")

guard="$repo_root/no-private-repo-names.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export XDG_CACHE_HOME="$work/cache"

# The visibility cache, named once here because several sections below plant
# entries in it and then assert on what the guard makes of them.
cache_file="$XDG_CACHE_HOME/git-guards/repo-visibility"

# ── gh stub ─────────────────────────────────────────────────────────────
# The 404 branch prints the API's error body to STDOUT and then exits non-zero,
# because that is what `gh api --jq` really does -- it does not fail silently.
# A stub that merely exited 1 would hand the guard an empty string, which is the
# one input that makes the unresolved path work, and every test below asserting
# that a failed lookup is not a pass would be green against behaviour the real
# tool never produces. A stub is a claim about the world and has to be one.
#
# The stderr line is part of that claim and not decoration. `gh` writes a
# one-line summary ending in `(HTTP <code>)` there for ANY non-2xx, and the code
# is the only thing that tells "the forge answered" apart from "the question
# never arrived" -- a distinction the guard now acts on, so a stub that omitted
# it would leave the acting untested. Recorded verbatim from `gh 2.97.0`:
#
#   $ gh api repos/acme/definitely-not-a-real-repo-xyz --jq .visibility
#   stdout: {"message":"Not Found",...,"status":"404"}
#   stderr: gh: Not Found (HTTP 404)
#
# and for a host that cannot be reached, stdout is EMPTY and stderr carries no
# status at all:
#
#   stderr: error connecting to nonexistent.invalid
#           check your internet connection or https://githubstatus.com
gh_404_body='{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/repos#get-a-repository","status":"404"}'
gh_404_stderr='gh: Not Found (HTTP 404)'
gh_offline_stderr='error connecting to api.github.com'

stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"repos/acme/secret-thing"*) echo private ;;
    *"repos/acme/public-tool"*)  echo public ;;
    *"repos/acme/internal-kit"*) echo internal ;;
    *) echo '$gh_404_body'; echo '$gh_404_stderr' >&2; exit 1 ;;
esac
STUB
chmod +x "$stub_bin/gh"
export PATH="$stub_bin:$PATH"

project="$work/project"
git init -q "$project"
git -C "$project" remote add origin https://github.com/acme/public-tool.git
cd "$project"

failures=0

check_message() {
    local name="$1" expected="$2" message="$3"
    shift 3
    local status=0 output
    printf '%s\n' "$message" > "$work/COMMIT_MSG"
    output="$(env "$@" bash "$guard" "$work/COMMIT_MSG" 2>&1)" || status=$?

    if [ "$status" -eq "$expected" ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s, got %s)\n%s\n' "$name" "$expected" "$status" "$output"
    failures=$((failures + 1))
}

# ── the case this exists for ────────────────────────────────────────────
check_message "a forge URL naming a private repo is refused" 1 \
    'fix: the error was

    error: blocked push to https://github.com/acme/secret-thing.git'

check_message "a cross-repo issue reference to a private repo is refused" 1 \
    'fix: port the workaround from acme/secret-thing#12'

check_message "an internal repo counts as private" 1 \
    'chore: sync with https://github.com/acme/internal-kit'

# ── it has to stay usable ───────────────────────────────────────────────
check_message "naming a public repo is fine" 0 \
    'chore: bump https://github.com/acme/public-tool to v2'

check_message "a message naming nothing is fine" 0 \
    'fix: resolve the workspace from git, not from the script path'

check_message "file paths are not repository names" 0 \
    'refactor: move src/main.rs and tests/run.sh, see docs/design.md'

check_message "an unknown owner/repo is not assumed private" 0 \
    'docs: mention stranger/unrelated-thing in passing'

# ── configuration ───────────────────────────────────────────────────────
check_message "an allowlisted repo is permitted" 0 \
    'fix: as in https://github.com/acme/secret-thing' \
    GIT_GUARDS_PUBLIC_REPOS=acme/secret-thing

check_message "the bypass is honoured" 0 \
    'fix: as in https://github.com/acme/secret-thing' \
    GIT_GUARDS_ALLOW_PRIVATE_NAMES=1

# A declared-private owner is matched with no forge lookup at all, which is what
# lets the guard work on forges `gh` cannot answer for.
check_message "a bare owner/repo is caught for a declared-private owner" 1 \
    'fix: mirror the change in mycorp/platform' \
    GIT_GUARDS_PRIVATE_OWNERS=mycorp PATH="/usr/bin:/bin"

check_message "a bare owner/repo is left alone otherwise" 0 \
    'fix: mirror the change in mycorp/platform'

# ...and the sentence that case does NOT support, pinned so the README cannot
# drift back into claiming it.
#
# The case above runs with `gh` off PATH and still refuses -- but only because
# an earlier case in this file already resolved this fixture's origin and left
# `public` in the shared cache. A COLD cache is the state a consumer without
# `gh` is actually in, and there the declared owner buys nothing: the visibility
# question is asked FIRST, "unknown" turns the guard off, and the name is never
# looked at. Exit 0, and not one word -- which a hook runner draws as `Passed`.
#
# So the offline path is BOTH variables, and the pair below is the whole of the
# assertion: the same message, the same absent `gh`, the same cold cache, and
# the only difference is that the second one answers the question the forge
# would have been asked.
cold_cache="$work/cold-cache"
rm -rf "$cold_cache"
printf 'fix: mirror the change in mycorp/platform\n' > "$work/COLD_MSG"

cold_status=0
env -i HOME="$HOME" PATH=/usr/bin:/bin XDG_CACHE_HOME="$cold_cache" \
    GIT_GUARDS_PRIVATE_OWNERS=mycorp \
    bash "$guard" "$work/COLD_MSG" >"$work/cold.out" 2>&1 || cold_status=$?
if [ "$cold_status" -eq 0 ] && [ ! -s "$work/cold.out" ]; then
    printf 'ok   %s\n' "a declared owner alone is NOT an offline path -- silent 0"
else
    printf 'FAIL %s (exit %s)\n%s\n' \
        "a declared owner alone is NOT an offline path -- silent 0" \
        "$cold_status" "$(cat "$work/cold.out")"
    failures=$((failures + 1))
fi

rm -rf "$cold_cache"
cold_status=0
env -i HOME="$HOME" PATH=/usr/bin:/bin XDG_CACHE_HOME="$cold_cache" \
    GIT_GUARDS_PRIVATE_OWNERS=mycorp GIT_GUARDS_REPO_VISIBILITY=public \
    bash "$guard" "$work/COLD_MSG" >"$work/cold.out" 2>&1 || cold_status=$?
if [ "$cold_status" -eq 1 ] && grep -q 'mycorp/platform' "$work/cold.out"; then
    printf 'ok   %s\n' "...and the pair of them IS one, with no forge at all"
else
    printf 'FAIL %s (exit %s)\n%s\n' \
        "...and the pair of them IS one, with no forge at all" \
        "$cold_status" "$(cat "$work/cold.out")"
    failures=$((failures + 1))
fi
rm -rf "$cold_cache"

# ── only public repos are protected ─────────────────────────────────────
check_message "inside a private repo, private names are fine" 0 \
    'fix: see https://github.com/acme/secret-thing#4' \
    GIT_GUARDS_REPO_VISIBILITY=private

check_message "unknown visibility does not start blocking commits" 0 \
    'fix: see https://github.com/acme/secret-thing#4' \
    GIT_GUARDS_REPO_VISIBILITY=unknown

# GIT_GUARDS_REPO_VISIBILITY answers the question the forge would be asked, so
# it is held to the forge's vocabulary. Anything else was trusted, and every
# value below made the guard decide this repository is not public and exit 0
# without examining a name -- with a message that names a private repository
# sitting right there. `publlic` is the one that matters: it is what somebody
# types meaning `public`, and it turned the guard off rather than on.
#
# Each is asserted against the SAME message that exits 1 under `public`, which
# is the pairing that makes it a fail-open rather than a preference.
check_message "a spelled-out visibility is honoured" 1 \
    'fix: see https://github.com/acme/secret-thing' \
    GIT_GUARDS_REPO_VISIBILITY=public

for bad_visibility in false true 0 yes publlic Public. 'public '; do
    check_message "visibility '$bad_visibility' is refused, not trusted" 2 \
        'fix: see https://github.com/acme/secret-thing' \
        GIT_GUARDS_REPO_VISIBILITY="$bad_visibility"
done

# A refusal that does not say which variable to go and look at leaves somebody
# reading this script to find out.
printf 'fix: see https://github.com/acme/secret-thing\n' > "$work/COMMIT_MSG"
status=0
output="$(GIT_GUARDS_REPO_VISIBILITY=publlic bash "$guard" "$work/COMMIT_MSG" 2>&1)" || status=$?
if [ "$status" -eq 2 ] && [[ "$output" == *"GIT_GUARDS_REPO_VISIBILITY"* ]] &&
    [[ "$output" == *"publlic"* ]]; then
    printf 'ok   %s\n' "the visibility refusal names the variable and the value"
else
    printf 'FAIL %s (expected exit 2 naming both, got %s)\n%s\n' \
        "the visibility refusal names the variable and the value" "$status" "$output"
    failures=$((failures + 1))
fi

# Case is not the objection; a value that is not a visibility is.
check_message "an upper-case visibility is still a visibility" 1 \
    'fix: see https://github.com/acme/secret-thing' \
    GIT_GUARDS_REPO_VISIBILITY=PUBLIC

# The runner difference that would otherwise split behaviour in two: prek does
# not forward the message path, so the hook has to find COMMIT_EDITMSG itself.
printf 'fix: see https://github.com/acme/secret-thing\n' > "$project/.git/COMMIT_EDITMSG"
status=0
output="$(bash "$guard" 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
    printf 'ok   %s\n' "a runner that forwards no path still finds the message"
else
    printf 'FAIL %s (expected exit 1, got %s)\n%s\n' "a runner that forwards no path still finds the message" "$status" "$output"
    failures=$((failures + 1))
fi

# ── staged content ──────────────────────────────────────────────────────
printf 'see https://github.com/acme/secret-thing for context\n' > "$project/NOTES.md"
git -C "$project" add NOTES.md
status=0
output="$(bash "$guard" --staged 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
    printf 'ok   %s\n' "added lines naming a private repo are refused"
else
    printf 'FAIL %s (expected exit 1, got %s)\n%s\n' "added lines naming a private repo are refused" "$status" "$output"
    failures=$((failures + 1))
fi

git -C "$project" reset -q
printf 'nothing to see here\n' > "$project/NOTES.md"
git -C "$project" add NOTES.md
status=0
output="$(bash "$guard" --staged 2>&1)" || status=$?
if [ "$status" -eq 0 ]; then
    printf 'ok   %s\n' "clean added lines pass"
else
    printf 'FAIL %s (expected exit 0, got %s)\n%s\n' "clean added lines pass" "$status" "$output"
    failures=$((failures + 1))
fi

# A commit is repository-wide whatever directory it was typed in, so a check on
# what the commit ADDS that stops at $PWD is answering about a different set of
# changes than the one being committed. `git diff --cached -- .` did exactly
# that: from a subdirectory the staged addition at the top of the tree was
# invisible and the hook exited 0. The pair is deliberate -- the same index, the
# same guard, the only difference being where it was started from.
git -C "$project" reset -q
printf 'see https://github.com/acme/secret-thing for context\n' > "$project/ELSEWHERE.md"
mkdir -p "$project/sub/dir"
printf 'nothing here\n' > "$project/sub/dir/inner.md"
git -C "$project" add ELSEWHERE.md sub/dir/inner.md

status=0
output="$(cd "$project" && bash "$guard" --staged 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
    printf 'ok   %s\n' "staged: a private name added at the top of the tree is refused"
else
    printf 'FAIL %s (expected exit 1, got %s)\n%s\n' \
        "staged: a private name added at the top of the tree is refused" "$status" "$output"
    failures=$((failures + 1))
fi

status=0
output="$(cd "$project/sub/dir" && bash "$guard" --staged 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
    printf 'ok   %s\n' "staged: ...and still refused when the hook starts in a subdirectory"
else
    printf 'FAIL %s (expected exit 1, got %s)\n%s\n' \
        "staged: ...and still refused when the hook starts in a subdirectory" "$status" "$output"
    failures=$((failures + 1))
fi

git -C "$project" reset -q
rm -rf "$project/ELSEWHERE.md" "$project/sub"

# ── --text: the same rule, for text that never touches git ──────────────
# A pull request body goes straight to a public API without passing a hook, so
# the rule has to be callable on plain text. Every case below is paired with
# the neighbour that must behave the other way.
check_text() {
    local name="$1" expected="$2" text="$3"
    shift 3
    local status=0 output
    output="$(printf '%s\n' "$text" | env "$@" bash "$guard" --text 2>&1)" || status=$?

    if [ "$status" -eq "$expected" ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s, got %s)\n%s\n' "$name" "$expected" "$status" "$output"
    failures=$((failures + 1))
}

check_text "text: a forge URL naming a private repo is refused" 1 \
    'see https://github.com/acme/secret-thing for context'

check_text "text: a cross-repo reference to a private repo is refused" 1 \
    'Related: acme/secret-thing#549'

check_text "text: ordinary prose passes" 0 \
    'Two changes, both from a downstream fork that had diverged.'

check_text "text: a path is not a repository" 0 \
    'the fix is in src/main.rs and tests/main.rs'

# The one deliberate difference from message mode. git strips `#` lines from a
# commit message; a Markdown heading in a PR body is content, and a private
# name inside one is exactly as published as one in a paragraph.
check_text "text: a name inside a Markdown heading is refused" 1 \
    '## Related: acme/secret-thing#12'

check_message "message: a `#` line is still stripped, as git does" 0 \
    '# Related: acme/secret-thing#12'

# The destination is the CALLER's business here: the text is usually written
# from a checkout that is not where it is going, so re-deriving visibility from
# $PWD would answer about the wrong repository. This project's origin is
# public, but the assertion is that it is not consulted at all.
check_text "text: a declared-private owner is refused with no forge lookup" 1 \
    'acme/whatever-thing is where it lives' \
    GIT_GUARDS_PRIVATE_OWNERS=acme PATH="/usr/bin:/bin"

check_text "text: the one-off bypass still applies" 0 \
    'see https://github.com/acme/secret-thing' \
    GIT_GUARDS_ALLOW_PRIVATE_NAMES=1

# The discriminating case for "the destination is the caller's business": run
# from a directory that is NOT a public repo -- not a repo at all -- and the
# refusal must stand. This is the normal situation, not an edge one: a PR body
# is written from whatever checkout happens to be current, which is routinely
# not the repository it is going to.
mkdir -p "$work/nowhere"
status=0
output="$(cd "$work/nowhere" && printf 'see acme/secret-thing#1\n' \
    | bash "$guard" --text 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
    printf 'ok   %s\n' "text: refused from a cwd that is not a public repo"
else
    printf 'FAIL %s (expected exit 1, got %s)\n%s\n' \
        "text: refused from a cwd that is not a public repo" "$status" "$output"
    failures=$((failures + 1))
fi

status=0
output="$(printf 'see acme/secret-thing#1\n' > "$work/body.md"; bash "$guard" --text "$work/body.md" 2>&1)" || status=$?
if [ "$status" -eq 1 ]; then
    printf 'ok   %s\n' "text: a named FILE is read as well as stdin"
else
    printf 'FAIL %s (expected exit 1, got %s)\n%s\n' "text: a named FILE is read as well as stdin" "$status" "$output"
    failures=$((failures + 1))
fi

# ── could not look is not a pass ────────────────────────────────────────
# `gh api` answers 404 both for a repository that does not exist and for a
# private one this token cannot see. The stub 404s for acme/ghost-thing, which
# is the same answer the real API gives for the case this guard exists for.
check_output() {
    local name="$1" expected="$2" needle="$3" text="$4"
    shift 4
    local status=0 output
    printf '%s\n' "$text" > "$work/COMMIT_MSG"
    output="$(env "$@" bash "$guard" "$work/COMMIT_MSG" 2>&1)" || status=$?

    # A needle beginning with `!` asserts the opposite: the run must NOT say
    # this. Without it, "reported nothing" and "reported the wrong thing" pass
    # the same assertion.
    local matched=no
    if [ "${needle:0:1}" = "!" ]; then
        [[ "$output" != *"${needle:1}"* ]] && matched=yes
    else
        [[ "$output" == *"$needle"* ]] && matched=yes
    fi

    if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s matching %q, got %s)\n%s\n' \
        "$name" "$expected" "$needle" "$status" "$output"
    failures=$((failures + 1))
}

check_output "an unresolvable name is reported, not silently passed" 0 \
    "could not determine" \
    'fix: as in https://github.com/acme/ghost-thing'

check_output "an unresolvable name is refused when asked to refuse" 2 \
    "could not determine" \
    'fix: as in https://github.com/acme/ghost-thing' \
    GIT_GUARDS_REFUSE_UNKNOWN=1

# A confirmed finding outranks an unresolved one: exit 1 is the more specific
# answer, and reporting could-not-look instead would lose it.
check_output "a private name still exits 1 alongside an unresolved one" 1 \
    "acme/secret-thing" \
    'fix: see https://github.com/acme/secret-thing and https://github.com/acme/ghost-thing' \
    GIT_GUARDS_REFUSE_UNKNOWN=1

check_output "an allowlisted name is not reported as unresolved" 0 \
    '!could not determine' \
    'fix: as in https://github.com/acme/ghost-thing' \
    GIT_GUARDS_PUBLIC_REPOS=acme/ghost-thing

check_output "unknown visibility for this repo can be made to refuse" 2 \
    "could not determine whether this repository is public" \
    'fix: see https://github.com/acme/secret-thing' \
    GIT_GUARDS_REPO_VISIBILITY=unknown GIT_GUARDS_REFUSE_UNKNOWN=1

# A lookup that FAILED must not be remembered. The stub cannot reach the forge
# on its first call for acme/late-thing and succeeds afterwards: if that were
# stored, the second run would still pass -- and it would have switched the
# guard off for precisely the repository it had just failed to resolve.
#
# The failure is a transport error, which is what a failed lookup actually is.
# It matters that it is not a 404: a 404 is the forge ANSWERING, and the two are
# stored differently on purpose (see the negative-cache cases below). A fixture
# that modelled a failed lookup as a 404 would be asserting this rule over an
# input it does not govern.
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"repos/acme/secret-thing"*) echo private ;;
    *"repos/acme/public-tool"*)  echo public ;;
    *"repos/acme/internal-kit"*) echo internal ;;
    *"repos/acme/late-thing"*)
        if [ -e "\$GH_STUB_STATE/late-thing.seen" ]; then
            echo private
        else
            : > "\$GH_STUB_STATE/late-thing.seen"
            echo '$gh_offline_stderr' >&2; exit 1
        fi
        ;;
    *) echo '$gh_404_body'; echo '$gh_404_stderr' >&2; exit 1 ;;
esac
STUB
chmod +x "$stub_bin/gh"
export GH_STUB_STATE="$work"

check_output "a failed lookup is not cached as an answer" 0 \
    "could not determine" \
    'fix: as in https://github.com/acme/late-thing'

check_output "the retry after a failed lookup finds it" 1 \
    "acme/late-thing (private)" \
    'fix: as in https://github.com/acme/late-thing'

# ── the negative cache ──────────────────────────────────────────────────
# The forge saying it has no such repository visible to this token is an ANSWER,
# and one that does not change between two runs a second apart. Not storing it
# is what made a tree-wide scan cost a network round trip per name on EVERY run,
# warm cache or cold: on this repository 41 of 46 names 404, so the cache saved
# five of forty-six and the scan took 19.4 seconds against 0.08 with `gh` off
# PATH. That is a guard somebody deletes.
#
# Three properties, and the middle one is the one that makes storing it safe.
gh_calls="$work/gh-calls"
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$gh_calls"
case "\$*" in
    *"repos/acme/secret-thing"*) echo private ;;
    *"repos/acme/public-tool"*)  echo public ;;
    *"repos/acme/internal-kit"*) echo internal ;;
    *) echo '$gh_404_body'; echo '$gh_404_stderr' >&2; exit 1 ;;
esac
STUB
chmod +x "$stub_bin/gh"

# One: it is asked once and not again.
: > "$gh_calls"
printf 'fix: as in https://github.com/acme/absent-thing\n' > "$work/COMMIT_MSG"
bash "$guard" "$work/COMMIT_MSG" >/dev/null 2>&1 || true
first_calls="$(grep -c 'absent-thing' "$gh_calls" || true)"
: > "$gh_calls"
bash "$guard" "$work/COMMIT_MSG" >/dev/null 2>&1 || true
second_calls="$(grep -c 'absent-thing' "$gh_calls" || true)"
if [ "$first_calls" -eq 1 ] && [ "$second_calls" -eq 0 ]; then
    printf 'ok   %s\n' "a name the forge cannot see is asked about once, not every run"
else
    printf 'FAIL %s (expected 1 then 0 lookups, got %s then %s)\n' \
        "a name the forge cannot see is asked about once, not every run" \
        "$first_calls" "$second_calls"
    failures=$((failures + 1))
fi

# Two: and the verdict does not move because of it. This is the whole licence
# for storing a 404 at all -- a stored absence reads back as `unknown`, so the
# name is still reported and GIT_GUARDS_REFUSE_UNKNOWN=1 still refuses it. A
# stale positive entry fails OPEN; this fails closed, which is why one is
# permitted and the other is not. Asserted on the SECOND run, from the cache.
check_output "a remembered absence is still unresolved, not not-private" 0 \
    "could not determine" \
    'fix: as in https://github.com/acme/absent-thing'

check_output "...and is still refused when asked to refuse" 2 \
    "could not determine" \
    'fix: as in https://github.com/acme/absent-thing' \
    GIT_GUARDS_REFUSE_UNKNOWN=1

# Three: a failure that is not the forge answering is not stored, whatever it
# is. A bad credential and a rate limit fail for every name at once, so storing
# those would write off a whole tree from one expired token -- the exact bug the
# absence entry is carefully not. The stub answers 403 for acme/limited-thing
# the first time and `private` after, so a stored 403 shows up as a miss.
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$gh_calls"
case "\$*" in
    *"repos/acme/limited-thing"*)
        if [ -e "\$GH_STUB_STATE/limited.seen" ]; then
            echo private
        else
            : > "\$GH_STUB_STATE/limited.seen"
            echo '{"message":"API rate limit exceeded","status":"403"}'
            echo 'gh: API rate limit exceeded (HTTP 403)' >&2
            exit 1
        fi
        ;;
    *"repos/acme/secret-thing"*) echo private ;;
    *"repos/acme/public-tool"*)  echo public ;;
    *) echo '$gh_404_body'; echo '$gh_404_stderr' >&2; exit 1 ;;
esac
STUB
chmod +x "$stub_bin/gh"

check_output "a rate limit is not remembered as an absence" 0 \
    "could not determine" \
    'fix: as in https://github.com/acme/limited-thing'

check_output "...so the retry after a rate limit finds it" 1 \
    "acme/limited-thing (private)" \
    'fix: as in https://github.com/acme/limited-thing'

# A visibility outranks an absence when both are on file for one name. The two
# can only ever appear together because two runs disagreed -- most plainly when
# one had a token that could see the repository and the other did not -- and of
# those, the run that got an answer learned something while the run that got a
# 404 learned only what it could not see. Taking whichever was written first
# would let the poorer-credentialled run decide and go on deciding, because
# nothing is asked twice once an entry exists.
#
# Planted in the order that discriminates: the absence FIRST, so a reader that
# stops at the first matching line answers `unknown` and the private name is
# never reported.
printf '%s\n' 'acme/two-minds absent' >> "$cache_file"
printf '%s\n' 'acme/two-minds private' >> "$cache_file"
check_output "a recorded visibility beats a recorded absence above it" 1 \
    "acme/two-minds (private)" \
    'fix: as in https://github.com/acme/two-minds'

# The specific way this goes wrong when the forge's answer is not held to a
# vocabulary, asserted on the cache rather than on the exit code, because the
# exit code recovers on its own once the value is rejected. `gh api` puts the
# API's error body on stdout, so an unchecked 404 reaches the cache as a JSON
# blob -- neither `private`, so the name passes, nor `unknown`, so the
# never-cache-a-non-answer rule does not apply to it. The entry would then
# answer every later lookup for that repository, from the cache, forever.
#
# The file has to EXIST for this to mean anything. An assertion that only looks
# for a blob is satisfied by a cache that was never written at all, so it would
# stay green if caching broke entirely -- and every line is matched against the
# shape an entry is allowed to have, rather than against the one wrong shape
# somebody thought of, because the failure being guarded against was a value
# nobody predicted.
#
# `absent` is the fourth word a line may carry and it is an answer too -- the
# forge replying that it has no such repository visible to this token. It is
# admitted here and nowhere else: it reads back as `unknown`, never as a
# visibility, so no line in this file can make the guard conclude a name is
# safe. A JSON blob still fails this, which is the property being kept.
if [ ! -s "$cache_file" ]; then
    printf 'FAIL %s (the cache is missing or empty, so it proves nothing)\n' \
        "the cache holds answers and only answers"
    failures=$((failures + 1))
elif malformed="$(grep -vE '^[a-z0-9._/-]+ (public|private|internal|absent)$' "$cache_file")"; then
    printf 'FAIL %s\n%s\n' "the cache holds answers and only answers" "$malformed"
    failures=$((failures + 1))
else
    printf 'ok   %s\n' "the cache holds answers and only answers"
fi

# ── the cache KEY, not the cache value ──────────────────────────────────
# `.` is legal in a repository name and a wildcard in a basic regular
# expression, so `grep "^$repo "` let one repository's cached answer be returned
# for another. `acme/my-app public` is what an ordinary clean run writes about a
# genuinely public repository, and it answered the lookup for the private
# `acme/my.app`: exit 0, nothing printed, and no way to see it -- the value
# returned IS one of the three words, so GIT_GUARDS_REFUSE_UNKNOWN=1 has nothing
# to refuse and the allow-list on the way out is satisfied.
#
# The entry is planted rather than produced, because the point is a name that
# this run never asked about. The stub answers `private` for acme/my.app, so a
# reader that matches the key literally reaches the forge and finds it.
cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"repos/acme/secret-thing"*) echo private ;;
    *"repos/acme/public-tool"*)  echo public ;;
    *"repos/acme/internal-kit"*) echo internal ;;
    *"repos/acme/my.app"*)       echo private ;;
    *"repos/acme/pub.tool"*)     echo public ;;
    *) echo '$gh_404_body'; echo '$gh_404_stderr' >&2; exit 1 ;;
esac
STUB
chmod +x "$stub_bin/gh"

printf '%s\n' 'acme/my-app public' >> "$cache_file"

check_output "a cached answer for one repo does not answer for another" 1 \
    "acme/my.app (private)" \
    'fix: as in https://github.com/acme/my.app'

# The same hole under this_repo_is_public, where it is worse. A wrong answer
# there does not mislead one lookup: the guard concludes there is nothing to
# protect and exits 0 before a single name is examined, in every mode, silently.
# So this one is run from a checkout whose own origin carries a dot, against a
# planted line about a DIFFERENT repository that the dot matches as a regex.
lookalike="$work/lookalike"
git init -q "$lookalike"
git -C "$lookalike" remote add origin https://github.com/acme/pub.tool.git
printf '%s\n' 'acme/pub-tool private' >> "$cache_file"

printf 'fix: see https://github.com/acme/secret-thing\n' > "$lookalike/MSG"
status=0
output="$(cd "$lookalike" && bash "$guard" "$lookalike/MSG" 2>&1)" || status=$?
if [ "$status" -eq 1 ] && [[ "$output" == *"acme/secret-thing (private)"* ]]; then
    printf 'ok   %s\n' "a look-alike cache entry does not switch the guard off"
else
    printf 'FAIL %s (expected exit 1 naming the private repo, got %s)\n%s\n' \
        "a look-alike cache entry does not switch the guard off" "$status" "$output"
    failures=$((failures + 1))
fi

# And the consequence that made it a fail-open rather than a wrong log line: a
# 404 is what the forge returns for a private repository this token cannot see,
# which is the case the guard exists for. Asked to refuse what it could not
# resolve, it has to refuse -- a JSON blob is not an answer that a name is safe.
check_output "a 404 body is treated as unresolved, not as not-private" 2 \
    "could not determine" \
    'fix: as in https://github.com/acme/never-heard-of-it' \
    GIT_GUARDS_REFUSE_UNKNOWN=1

# The other side of the same defect, and the side a write-side fix cannot reach.
# The cache is never expired -- a repository's visibility is not the kind of fact
# that goes stale on a timer -- so an entry written by an older run outlives the
# fix that stops new ones being written. Planted here rather than produced,
# because the whole point is that the script which wrote it is gone.
#
# The good entry is left in place BELOW the blob, so this also pins the reading
# rule: a line that is not an answer is a cache miss and the read keeps going,
# rather than the first line for the repository being taken as the verdict.
printf '%s %s\n' 'acme/secret-thing' "$gh_404_body" > "$work/poisoned"
cat "$cache_file" >> "$work/poisoned"
cp "$work/poisoned" "$cache_file"

check_output "a poisoned cache entry is not read as an answer" 1 \
    "acme/secret-thing (private)" \
    'fix: as in https://github.com/acme/secret-thing'

# ── --tracked: the line that is already there ───────────────────────────
# Staged mode judges what a commit ADDS. A name that arrived under --no-verify,
# through a merge, or from a checkout with no hooks installed is not an addition
# to any later commit, so nothing looks at it again. Every case below is one
# staged mode cannot see.
check_tracked() {
    local name="$1" expected="$2" needle="$3"
    shift 3
    local status=0 output
    output="$(env "$@" bash "$guard" --tracked 2>&1)" || status=$?

    local matched=no
    if [ "${needle:0:1}" = "!" ]; then
        [[ "$output" != *"${needle:1}"* ]] && matched=yes
    else
        [[ "$output" == *"$needle"* ]] && matched=yes
    fi

    if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s matching %q, got %s)\n%s\n' \
        "$name" "$expected" "$needle" "$status" "$output"
    failures=$((failures + 1))
}

git -C "$project" reset -q
printf 'context: https://github.com/acme/secret-thing\n' > "$project/DESIGN.md"
git -C "$project" add DESIGN.md
git -C "$project" -c user.email=t@example.test -c user.name=T \
    commit -q --no-verify -m 'add design notes'

check_tracked "a committed private name is found after the fact" 1 \
    "acme/secret-thing (private)"

check_tracked "the finding names the file and the line" 1 \
    "DESIGN.md:1:"

check_tracked "a private repo's own tree is not its problem" 0 \
    '!secret-thing' \
    GIT_GUARDS_REPO_VISIBILITY=private

check_tracked "the allowlist applies here too" 0 \
    '!secret-thing' \
    GIT_GUARDS_PUBLIC_REPOS=acme/secret-thing

# A tree-wide scan crosses every example URL and every forge `gh` cannot answer
# for. Reporting those by default would bury the finding under names nobody can
# act on -- but they are still reachable when asked for.
printf 'see https://github.com/acme/ghost-thing\n' > "$project/NOTES2.md"
git -C "$project" add NOTES2.md
git -C "$project" -c user.email=t@example.test -c user.name=T \
    commit -q --no-verify -m 'add notes'

check_tracked "unresolvable names are quiet in a tree-wide scan" 1 \
    '!ghost-thing'

check_tracked "and reportable when asked for" 2 \
    "ghost-thing" \
    GIT_GUARDS_PUBLIC_REPOS=acme/secret-thing GIT_GUARDS_REFUSE_UNKNOWN=1

# An owner list that is not a list of names. Every entry is read TWICE under
# different rules -- literally by list_has, and as part of an extended regular
# expression by the prefilter and the extractor -- so an entry that is not a
# plain name makes those two readings disagree. Both ways it goes wrong are
# asserted against the SAME tree that exits 1 in the case above, which is what
# makes each a fail-open rather than a difference of opinion about a pattern.
check_tracked "an owner that is not a name stops the run" 2 \
    "GIT_GUARDS_PRIVATE_OWNERS holds an entry that is not a name" \
    GIT_GUARDS_PRIVATE_OWNERS='ac(me'

check_tracked "...and the refusal quotes the entry" 2 \
    "ac(me" \
    GIT_GUARDS_PRIVATE_OWNERS='ac(me'

check_tracked "a backwards repetition count is refused too" 2 \
    "is not a name" \
    GIT_GUARDS_PRIVATE_OWNERS='{2,1}'

# The entry that COMPILES and is worse for it. `acme|widgets` is an alternation
# to the extractor, so `widgets/secret` comes out as a candidate; to list_has it
# is one item equal to neither owner, so the candidate is NOT recognised as
# declared-private and goes to the forge like any other name. The forge 404s and
# the run exits 0 having said nothing -- with the owner list apparently in force
# the whole time. The paired case below is the same tree with the same intent
# spelled as a comma, which must still refuse.
check_message "an owner list spelled as an alternation is refused" 2 \
    'fix: mirror the change in widgets/secret' \
    GIT_GUARDS_PRIVATE_OWNERS='acme|widgets'

check_message "...and spelled as a comma it catches the name" 1 \
    'fix: mirror the change in widgets/secret' \
    GIT_GUARDS_PRIVATE_OWNERS='acme,widgets'

# The public list is validated on the same grounds. It never reaches a regex, so
# a bogus entry cannot break a scan -- it silently never matches, which is an
# allowance somebody believes they have and does not.
check_message "a public-repo entry that is not a name is refused" 2 \
    'fix: as in https://github.com/acme/secret-thing' \
    GIT_GUARDS_PUBLIC_REPOS='acme|secret-thing'

# A dot is legal in a name and a wildcard in a regular expression. Declared
# unescaped, `acme.corp` also extracts `acmeXcorp/thing` as a candidate -- and
# because list_has then compares literally and finds no match, the invented name
# is not flagged but sent to the forge like any other, coming back unresolved.
# The exit code hides it, which is why these two are asserted the way they are:
# with GIT_GUARDS_REFUSE_UNKNOWN=1 an unresolved name is a refusal, so the
# wildcard's phantom shows up as exit 2 over a tree that contains no such
# repository, and the output is checked for the name it invented.
check_output "a declared owner's dot is a dot, not a wildcard" 0 \
    '!acmeXcorp' \
    'fix: mirror the change in acmeXcorp/thing' \
    GIT_GUARDS_PRIVATE_OWNERS='acme.corp' GIT_GUARDS_REFUSE_UNKNOWN=1

check_output "...and it still matches itself" 1 \
    "acme.corp/thing (owner in GIT_GUARDS_PRIVATE_OWNERS)" \
    'fix: mirror the change in acme.corp/thing' \
    GIT_GUARDS_PRIVATE_OWNERS='acme.corp'

# THE MODES MUST AGREE. A configuration this script cannot read is not a
# property of the mode you happened to invoke: the same environment used to
# refuse a tree scan with exit 2 and pass a commit message with exit 0, because
# --tracked builds its pattern for `git grep` (which reports a bad one) and the
# others build theirs for greps whose `|| true` swallowed the status.
for bad_mode_case in "message" "--staged" "--tracked" "--text"; do
    status=0
    printf 'fix: mirror acme/secret\n' > "$work/BADCFG"
    case "$bad_mode_case" in
        message) output="$(GIT_GUARDS_PRIVATE_OWNERS='ac(me' bash "$guard" "$work/BADCFG" 2>&1)" || status=$? ;;
        --text) output="$(GIT_GUARDS_PRIVATE_OWNERS='ac(me' bash "$guard" --text "$work/BADCFG" 2>&1)" || status=$? ;;
        *) output="$(GIT_GUARDS_PRIVATE_OWNERS='ac(me' bash "$guard" "$bad_mode_case" 2>&1)" || status=$? ;;
    esac
    if [ "$status" -eq 2 ] && [[ "$output" == *"is not a name"* ]]; then
        printf 'ok   %s\n' "an unreadable owner list refuses in $bad_mode_case mode too"
    else
        printf 'FAIL %s (expected exit 2 naming the entry, got %s)\n%s\n' \
            "an unreadable owner list refuses in $bad_mode_case mode too" "$status" "$output"
        failures=$((failures + 1))
    fi
done

# The prefilter's own failure, which the validated owner list keeps out of reach
# and which is refused anyway. git grep has three statuses and they are not two:
# anything above 1 is an error, and reading it as "found nothing" is a scan that
# reports a clean tree having read no file at all. Driven through a `git` on
# PATH that fails the grep and only the grep, because the branch's contract is
# about the STATUS, and a tree that cannot be constructed to produce one is not
# evidence that nothing ever will.
grep_fail_bin="$work/gitfail"
mkdir -p "$grep_fail_bin"
cat > "$grep_fail_bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = grep ]; then
    echo "fatal: unable to read files to scan" >&2
    exit 128
fi
exec /usr/bin/env -u PATH_STUB /usr/bin/git "$@"
STUB
chmod +x "$grep_fail_bin/git"
status=0
output="$(PATH="$grep_fail_bin:$PATH" bash "$guard" --tracked 2>&1)" || status=$?
if [ "$status" -eq 2 ] && [[ "$output" == *"the tree-wide scan could not run"* ]] &&
    [[ "$output" == *"unable to read files to scan"* ]]; then
    printf 'ok   %s\n' "tracked: a prefilter that errors is refused, quoting git"
else
    printf 'FAIL %s (expected exit 2 quoting git, got %s)\n%s\n' \
        "tracked: a prefilter that errors is refused, quoting git" "$status" "$output"
    failures=$((failures + 1))
fi

# `git grep` and `git ls-files` search from the current directory down. A scan
# started in a subdirectory would cover that subtree and report a clean result
# for the rest -- the exact failure this mode exists to prevent, arriving
# through the scan itself.
mkdir -p "$project/deep/nested"
printf 'placeholder\n' > "$project/deep/nested/inner.md"
git -C "$project" add deep/nested/inner.md
git -C "$project" -c user.email=t@example.test -c user.name=T \
    commit -q --no-verify -m 'add nested file'

status=0
output="$(cd "$project/deep/nested" && bash "$guard" --tracked 2>&1)" || status=$?
if [ "$status" -eq 1 ] && [[ "$output" == *"DESIGN.md"* ]]; then
    printf 'ok   %s\n' "tracked: a scan from a subdirectory still covers the whole tree"
else
    printf 'FAIL %s (expected exit 1 naming DESIGN.md, got %s)\n%s\n' \
        "tracked: a scan from a subdirectory still covers the whole tree" "$status" "$output"
    failures=$((failures + 1))
fi

# The prefilter decides which lines reach extract_candidates, which matches the
# URL form case-insensitively. A narrower prefilter drops the line first, and
# the scan then reports a clean tree for text it never looked at.
git -C "$project" rm -q DESIGN.md
printf 'context: HTTPS://GitHub.com/ACME/Secret-Thing\n' > "$project/SHOUTING.md"
git -C "$project" add SHOUTING.md
git -C "$project" -c user.email=t@example.test -c user.name=T \
    commit -q --no-verify -m 'shout'

check_tracked "the prefilter is a superset of the extractor" 1 \
    "SHOUTING.md"

git -C "$project" rm -q SHOUTING.md
printf 'context: https://github.com/acme/secret-thing\n' > "$project/DESIGN.md"
git -C "$project" add DESIGN.md
git -C "$project" -c user.email=t@example.test -c user.name=T \
    commit -q --no-verify -m 'restore design notes'

# Covering nothing is not a clean tree.
mkdir -p "$work/empty" && git init -q "$work/empty"
status=0
output="$(cd "$work/empty" && GIT_GUARDS_REPO_VISIBILITY=public bash "$guard" --tracked 2>&1)" || status=$?
if [ "$status" -eq 2 ]; then
    printf 'ok   %s\n' "tracked: a tree with no tracked files exits 2"
else
    printf 'FAIL %s (expected exit 2, got %s)\n%s\n' \
        "tracked: a tree with no tracked files exits 2" "$status" "$output"
    failures=$((failures + 1))
fi

# ── WHICH TREE the tree-wide mode reads ─────────────────────────────────
#
# Every case above commits its fixture and leaves the working tree matching it,
# so all of them pass for a scan that reads the working tree and all of them
# pass for a scan that reads the commit. That is the shape of a suite that
# cannot go red on the defect it is meant to hold: `git grep` with no rev and no
# --cached reads whatever is on disk, and the words worktree, unstaged, index
# and TO_REF appeared nowhere in this file.
#
# What it cost, measured end to end with a clean working tree and no
# --no-verify at push time: commit a private name on `feature`, check out
# `main`, push `feature`. The file is not on disk at all, the hook registered at
# pre-push -- the stage .pre-commit-hooks.yaml calls "the last moment before the
# work becomes shared" -- printed Passed, the push succeeded, and the name was
# in the remote.
#
# So every case below separates the two trees deliberately, and each is PAIRED
# with the one that has to behave the other way. Without the pairs, a scan that
# had simply started refusing everything would pass the lot.
artifact_repo() {
    local dir="$1"
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" config user.email t@example.test
    git -C "$dir" config user.name T
    git -C "$dir" config commit.gpgsign false
}

# A declared-private owner and a stated visibility, so no case here needs `gh`,
# a network or an origin remote, and the answer is the same on a laptop and on a
# cold runner.
tracked_in() {
    local dir="$1" name="$2" expected="$3" needle="$4"
    shift 4
    local status=0 output
    output="$(cd "$dir" && env GIT_GUARDS_REPO_VISIBILITY=public \
        GIT_GUARDS_PRIVATE_OWNERS=acme "$@" bash "$guard" --tracked 2>&1)" || status=$?

    local matched=no
    if [ -z "$needle" ]; then
        matched=yes
    elif [ "${needle:0:1}" = "!" ]; then
        [[ "$output" != *"${needle:1}"* ]] && matched=yes
    else
        [[ "$output" == *"$needle"* ]] && matched=yes
    fi

    if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s matching %q, got %s)\n%s\n' \
        "$name" "$expected" "$needle" "$status" "$output"
    failures=$((failures + 1))
}

# ── the index, not the file on disk ─────────────────────────────────────
artifact="$work/artifact"
artifact_repo "$artifact"
printf 'see https://github.com/acme/secret-thing\n' > "$artifact/notes.md"
git -C "$artifact" add notes.md
git -C "$artifact" commit -q --no-verify -m notes

printf 'nothing to see here\n' > "$artifact/notes.md"
tracked_in "$artifact" "tracked: the commit is judged, not the edited-away worktree copy" 1 \
    "acme/secret-thing"
git -C "$artifact" checkout -q -- notes.md

# The pair, in a repository whose index is clean so that the only place the name
# appears is the working tree. A name typed into a file and never staged is in
# no commit and no push, so it is not this operation's problem -- it becomes one
# the moment it is staged, where --staged catches it, or committed, where this
# mode does. Without this case the one above is satisfied by a guard that
# refuses on sight.
unstaged="$work/unstaged"
artifact_repo "$unstaged"
printf 'placeholder\n' > "$unstaged/keep.md"
git -C "$unstaged" add keep.md
git -C "$unstaged" commit -q --no-verify -m base

printf 'see https://github.com/acme/secret-thing\n' > "$unstaged/loose.md"
tracked_in "$unstaged" "tracked: ...and an unstaged file is in no commit, so it is not one" 0 \
    '!secret-thing'

# Staged and not yet committed is the tree this commit WOULD have, which is what
# a pre-commit hook is being asked about. Same file, same bytes, same directory:
# the only thing that changed is whether the commit would carry it.
git -C "$unstaged" add loose.md
tracked_in "$unstaged" "tracked: ...and staging it makes it the commit's problem" 1 \
    "loose.md"

# ── could not read is not clean ─────────────────────────────────────────
#
# Both of these used to exit 0 with no output at all: a tracked file the scan
# could not open was silently not scanned, while its sibling
# prevent-unusual-unicode-in-files treated exactly this as a failure and the
# README asserted that discipline in print. Reading git's objects retires the
# class rather than reporting it -- a mode bit and a missing working-tree copy
# cannot stop a blob coming out of the object database -- so the assertion is
# the stronger one: not "it refused", but "it found the name".
chmod 000 "$artifact/notes.md"
tracked_in "$artifact" "tracked: a file that will not open is still scanned, from the index" 1 \
    "acme/secret-thing"
chmod 644 "$artifact/notes.md"

rm -f "$artifact/notes.md"
tracked_in "$artifact" "tracked: ...and so is one deleted from the working tree" 1 \
    "acme/secret-thing"
git -C "$artifact" checkout -q -- notes.md

# ── symlinks ────────────────────────────────────────────────────────────
#
# A symlink's blob IS its target path: that string is the file's entire
# committed content, as permanent and as indexable as any other line. `git grep`
# does not look inside one, so the tree-wide backstop reported a committed
# `ptr -> acme/hidden-repo` clean while catching the identical string in a plain
# file -- the one guard meant to catch a name that arrived without passing a
# hook, passing it.
links="$work/links"
artifact_repo "$links"
printf 'placeholder\n' > "$links/keep.md"
ln -s 'acme/hidden-repo' "$links/ptr"
git -C "$links" add keep.md ptr
git -C "$links" commit -q --no-verify -m ptr

tracked_in "$links" "tracked: a private name in a symlink's target is found" 1 \
    "acme/hidden-repo"
tracked_in "$links" "tracked: ...and the finding names the symlink" 1 \
    "ptr: a symlink whose target is"

# The pair, so the case above is a finding about the target rather than a ban on
# symlinks.
git -C "$links" rm -q ptr
ln -s keep.md "$links/harmless"
git -C "$links" add harmless
git -C "$links" commit -q --no-verify -m harmless
tracked_in "$links" "tracked: ...and an ordinary symlink is not a finding" 0 \
    '!hidden-repo'

# A blob git will not hand over is "cannot say", and cannot say is not clean.
# Driven through a `git` on PATH that fails `cat-file blob` and nothing else,
# because the branch's contract is about that failure and a tree that cannot be
# built to produce one is not evidence that nothing ever will.
git -C "$links" rm -q harmless
ln -s 'acme/hidden-repo' "$links/ptr"
git -C "$links" add ptr
git -C "$links" commit -q --no-verify -m ptr-again

catfile_fail_bin="$work/gitcatfail"
mkdir -p "$catfile_fail_bin"
cat > "$catfile_fail_bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = cat-file ] && [ "$2" = blob ]; then
    echo "fatal: unable to read the object" >&2
    exit 128
fi
exec /usr/bin/git "$@"
STUB
chmod +x "$catfile_fail_bin/git"
tracked_in "$links" "tracked: a blob git will not produce is refused, not skipped" 2 \
    "could not read the symlink" PATH="$catfile_fail_bin:$PATH"

# ── the commit being PUSHED ─────────────────────────────────────────────
#
# The headline defect. At pre-push a runner exports the local sha it is about to
# send -- measured under prek 0.3.12 as PRE_COMMIT_TO_REF and PRE_COMMIT_SOURCE
# -- and the scan read the working tree instead, which at pre-push is whatever
# branch happens to be checked out. Both directions here: the branch being
# pushed decides, and the checkout does not.
pushed="$work/pushed"
artifact_repo "$pushed"
printf 'placeholder\n' > "$pushed/keep.md"
git -C "$pushed" add keep.md
git -C "$pushed" commit -q --no-verify -m base
git -C "$pushed" checkout -q -b feature
printf 'see https://github.com/acme/secret-thing\n' > "$pushed/notes.md"
git -C "$pushed" add notes.md
git -C "$pushed" commit -q --no-verify -m notes
git -C "$pushed" checkout -q -

feature_sha="$(git -C "$pushed" rev-parse feature)"
trunk_sha="$(git -C "$pushed" rev-parse HEAD)"

tracked_in "$pushed" "tracked: the branch being pushed is scanned, not the checkout" 1 \
    "acme/secret-thing" PRE_COMMIT_TO_REF="$feature_sha"

tracked_in "$pushed" "tracked: ...and a clean branch is clean, dirty siblings and all" 0 \
    '!secret-thing' PRE_COMMIT_TO_REF="$trunk_sha"

# pre-commit's older spelling of the same value, still exported beside the new
# one. A guard that reads only one name works under one runner and not the other.
tracked_in "$pushed" "tracked: PRE_COMMIT_SOURCE names the pushed commit too" 1 \
    "acme/secret-thing" PRE_COMMIT_SOURCE="$feature_sha"

# A ref being DELETED is all zeros and introduces no bytes at all, so there is
# nothing to scan for one and the index is the answer again.
tracked_in "$pushed" "tracked: a deleted ref falls back to the index, not to nothing" 0 \
    "the index" PRE_COMMIT_TO_REF=0000000000000000000000000000000000000000

# A sha the runner named and this repository cannot resolve is refused rather
# than fallen back on. Falling back would scan the index -- a different tree,
# quite possibly a clean one -- and report on it under the push's name.
tracked_in "$pushed" "tracked: an unresolvable pushed sha is refused, not substituted" 2 \
    "cannot resolve it" \
    PRE_COMMIT_TO_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

# ── the denominator ─────────────────────────────────────────────────────
#
# A tree-wide scan that prints only findings cannot be told apart from one that
# read nothing, and the label matters as much as the number: "2 path(s)" is the
# same sentence about the index, about the commit being pushed and about a
# checkout of something else.
#
# What is counted is what was SEARCHED, out of what was found. The two used to
# be one number, and their being one number is what let a committed
# `.gitattributes` move a file from the first to the second in silence -- the
# denominator never moved, and nothing said the bytes had gone unread.
tracked_in "$pushed" "tracked: a passing run states its denominator" 0 \
    "file(s) searched" PRE_COMMIT_TO_REF="$trunk_sha"

tracked_in "$pushed" "tracked: ...and says which tree it is a denominator of" 0 \
    "the commit being pushed" PRE_COMMIT_TO_REF="$trunk_sha"

tracked_in "$pushed" "tracked: ...naming the index when that is what was read" 0 \
    "the index"

# ── an attribute is not a binary determination ──────────────────────────
#
# The sharpest defect this mode had, and the one nothing here could go red on.
# `git grep -I` skips a file git calls binary, and git decides binary from the
# `diff` ATTRIBUTE before it ever looks for a NUL byte. So a committed two-line
# .gitattributes -- content, carried by the same commit if you like -- makes
# plain ASCII invisible to the scan at every stage, with the exit status still 0
# or 1, nothing on stderr, and a denominator counting the file it did not read.
#
# Real git and a real .gitattributes here, and no stub anywhere. The whole claim
# is about what git does, and a stubbed grep would only assert what the stub was
# written to do -- which is exactly how the old assertion in this file came to
# drive a status (128) that real git uses for something else entirely.
#
# Three spellings, because they are three different attribute mechanisms and a
# fix for one need not be a fix for another: `-diff` on a glob, `-diff` on
# everything including the .gitattributes file itself, and `binary`, which is a
# macro expanding to `-diff -merge -text`.
attributes_repo() {
    local dir="$1" line="$2"
    artifact_repo "$dir"
    printf 'see https://github.com/acme/secret-thing\n' > "$dir/build.log"
    printf 'rows,here\n1,2\n' > "$dir/data.csv"
    printf '%s\n' "$line" > "$dir/.gitattributes"
    git -C "$dir" add -A
    git -C "$dir" commit -q --no-verify -m attributes
}

blind="$work/blind-glob"
attributes_repo "$blind" '*.log -diff'
tracked_in "$blind" "tracked: a '*.log -diff' attribute does not hide the file" 1 \
    "acme/secret-thing"
tracked_in "$blind" "tracked: ...and the finding still names the file and the line" 1 \
    "build.log:1:"
tracked_in "$blind" "tracked: ...and every file is still counted as searched" 1 \
    "3 of 3 file(s) searched"

blind_all="$work/blind-all"
attributes_repo "$blind_all" '* -diff'
tracked_in "$blind_all" "tracked: a '* -diff' attribute does not hide anything" 1 \
    "acme/secret-thing"

blind_binary="$work/blind-binary"
attributes_repo "$blind_binary" '*.log binary'
tracked_in "$blind_binary" "tracked: the 'binary' attribute macro does not hide it either" 1 \
    "acme/secret-thing"

# The pair, and it is what makes the three above about the ATTRIBUTE rather than
# about reading everything twice. A file that really is binary has no line for a
# name to hide in, so it is skipped -- and NAMED, with its reason, because a
# count on its own is what makes a skip safe to ignore right up until one of
# them is the file somebody hid something in.
realbin="$work/real-binary"
artifact_repo "$realbin"
printf 'placeholder\n' > "$realbin/keep.md"
printf 'see https://github.com/acme/secret-thing\n' > "$realbin/logo.png"
head -c 8 /dev/zero >> "$realbin/logo.png"
git -C "$realbin" add -A
git -C "$realbin" commit -q --no-verify -m binary
tracked_in "$realbin" "tracked: a genuinely binary file is skipped, not searched" 0 \
    "skipped logo.png"
tracked_in "$realbin" "tracked: ...and the denominator says one of two was searched" 0 \
    "1 of 2 file(s) searched"

# ── the same attribute, in staged mode ──────────────────────────────────
#
# `git diff --cached` obeys the diff attribute exactly as `git grep` does: a
# plain-ASCII file becomes `Binary files a/x and b/x differ` and not one of its
# added lines reaches the extractor. Same fixture, other mode, because "at every
# stage" was the shape of the defect and one mode fixed is one mode fixed.
staged_in() {
    local dir="$1" name="$2" expected="$3" needle="$4"
    shift 4
    local status=0 output
    output="$(cd "$dir" && env GIT_GUARDS_REPO_VISIBILITY=public \
        GIT_GUARDS_PRIVATE_OWNERS=acme "$@" bash "$guard" --staged 2>&1)" || status=$?

    local matched=no
    if [ -z "$needle" ]; then
        matched=yes
    elif [ "${needle:0:1}" = "!" ]; then
        [[ "$output" != *"${needle:1}"* ]] && matched=yes
    else
        [[ "$output" == *"$needle"* ]] && matched=yes
    fi

    if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s (expected exit %s matching %q, got %s)\n%s\n' \
        "$name" "$expected" "$needle" "$status" "$output"
    failures=$((failures + 1))
}

staged_blind="$work/staged-blind"
artifact_repo "$staged_blind"
printf '*.log -diff\n' > "$staged_blind/.gitattributes"
git -C "$staged_blind" add .gitattributes
git -C "$staged_blind" commit -q --no-verify -m attributes
printf 'see https://github.com/acme/secret-thing\n' > "$staged_blind/build.log"
git -C "$staged_blind" add build.log
staged_in "$staged_blind" "staged: a -diff attribute does not hide an added line" 1 \
    "acme/secret-thing"

# The pair. A real binary file is not diffed as text either, and re-reading it
# would put its bytes through the extractor -- which is the other way to be
# wrong about the same question.
git -C "$staged_blind" reset -q
rm -f "$staged_blind/build.log"
printf 'see https://github.com/acme/secret-thing\n' > "$staged_blind/logo.png"
head -c 8 /dev/zero >> "$staged_blind/logo.png"
git -C "$staged_blind" add logo.png
staged_in "$staged_blind" "staged: ...and a genuinely binary file stays unread" 0 \
    '!secret-thing'

# ── a blob git will not produce, with no stub at all ────────────────────
#
# `git grep` prints `error: '<path>': unable to read <oid>` on stderr and exits
# 1 -- the same status it uses for "found nothing". A scan refusing only a
# status ABOVE 1 discards the complaint and reports a clean tree over a file
# nobody opened. The only assertion this file used to carry about "git refuses
# to produce something" stubbed `git grep` to exit 128, which is the status real
# git uses when the grep cannot START; the branch it reached was not the branch
# that fires. This one deletes a loose object out of the object database and
# lets real git say what it really says.
missing="$work/missing-object"
artifact_repo "$missing"
printf 'alpha\n' > "$missing/a.md"
printf 'beta\n' > "$missing/b.md"
git -C "$missing" add -A
git -C "$missing" commit -q --no-verify -m base
gone_oid="$(git -C "$missing" rev-parse :a.md)"
rm -f "$missing/.git/objects/${gone_oid:0:2}/${gone_oid:2}"

tracked_in "$missing" "tracked: a blob git cannot read is refused, not read as nothing" 2 \
    "unable to read"
tracked_in "$missing" "tracked: ...and the refusal says the scan did not finish" 2 \
    "the tree-wide scan could not run"

# The complaint check ON ITS OWN, with the other net taken out from under it.
# The case above is caught twice -- once because git grep complains, and once
# because the blob it could not read is read here directly and fails there too --
# so it cannot show which of the two acted. This one uses a `git` on PATH that
# writes a word to stderr and then does exactly what real git would: nothing
# else about the tree is wrong, every blob is readable, and the only thing to
# notice is the line on stderr under an exit status that says "found nothing".
#
# A shim, and said out loud: the branch being isolated is "git complained and
# did not fail", and a tree that provokes that without also provoking the other
# net is not something a fixture can build. The words are real git's, recorded
# from the deleted-object run above.
grep_warn_bin="$work/gitgrepwarn"
mkdir -p "$grep_warn_bin"
cat > "$grep_warn_bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = grep ]; then
    printf "error: 'notes.md': unable to read %s\n" \
        0000000000000000000000000000000000000000 >&2
fi
exec /usr/bin/git "$@"
STUB
chmod +x "$grep_warn_bin/git"

warned="$work/grep-warns"
artifact_repo "$warned"
printf 'nothing to see here\n' > "$warned/notes.md"
git -C "$warned" add -A
git -C "$warned" commit -q --no-verify -m base
tracked_in "$warned" "tracked: a word on stderr ends the run whatever git exited" 2 \
    "the tree-wide scan could not run" PATH="$grep_warn_bin:$PATH"

# ── a path is committed text ────────────────────────────────────────────
#
# `vendor/acme/hidden-repo/README` names a private repository in a public
# repository's tree listing, indexed and permanent, and the scope resolver has
# always handed the PATH over beside the blob -- it was discarded for everything
# but symlinks. Measured before this: on the remote, with every hook green at
# commit, at push and at manual.
paths="$work/paths"
artifact_repo "$paths"
mkdir -p "$paths/vendor/acme/hidden-repo"
printf 'nothing to see here\n' > "$paths/vendor/acme/hidden-repo/README"
git -C "$paths" add -A
git -C "$paths" commit -q --no-verify -m vendored

tracked_in "$paths" "tracked: a directory named after a private repo is a finding" 1 \
    "acme/hidden-repo"
tracked_in "$paths" "tracked: ...and the finding says where it read it" 1 \
    "the PATH itself names it"

# The pair, without which a guard that had started refusing every tree would
# satisfy the case above.
clean_paths="$work/clean-paths"
artifact_repo "$clean_paths"
mkdir -p "$clean_paths/vendor/other/tool"
printf 'nothing to see here\n' > "$clean_paths/vendor/other/tool/README"
git -C "$clean_paths" add -A
git -C "$clean_paths" commit -q --no-verify -m vendored
tracked_in "$clean_paths" "tracked: ...and an ordinary path is not one" 0 '!other/tool'

# A path is read as ADJACENT PAIRS and not as a whole path, which is what stops
# a deep directory tree manufacturing names for the forge to be asked about: a
# two-segment line cannot match the forge-URL form, because that needs
# `host.tld/owner/repo` and there is only one separator here. Asserted under
# REFUSE_UNKNOWN, where a candidate nobody can resolve is an exit 2 and
# therefore visible rather than swallowed.
deep="$work/deep-paths"
artifact_repo "$deep"
mkdir -p "$deep/docs/example.com/guides"
printf 'nothing to see here\n' > "$deep/docs/example.com/guides/intro.md"
git -C "$deep" add -A
git -C "$deep" commit -q --no-verify -m docs
tracked_in "$deep" "tracked: a deep path does not manufacture a name to look up" 0 \
    '!could not determine' GIT_GUARDS_REFUSE_UNKNOWN=1

# A submodule is skipped as CONTENT -- it is its own repository and carries its
# own hooks -- and its path is not skipped, because a gitlink has no blob here
# at all and the path is the whole of what it publishes.
gitlink="$work/gitlink"
artifact_repo "$gitlink"
printf 'placeholder\n' > "$gitlink/keep.md"
git -C "$gitlink" add keep.md
git -C "$gitlink" commit -q --no-verify -m base
gitlink_sha="$(git -C "$gitlink" rev-parse HEAD)"
git -C "$gitlink" update-index --add \
    --cacheinfo "160000,$gitlink_sha,vendor/acme/hidden-repo"
tracked_in "$gitlink" "tracked: a submodule whose PATH names a private repo is a finding" 1 \
    "acme/hidden-repo"
tracked_in "$gitlink" "tracked: ...and the submodule itself is named as a skip" 1 \
    "a submodule -- no blob in this repository"

# And it is not counted as a file it failed to search. The denominator's
# numerator and denominator are both about blobs of file CONTENT; a gitlink has
# none, and folding it in would make every repository with a submodule look
# like one the scan had given up on.
tracked_in "$gitlink" "tracked: ...and a gitlink is not counted as an unsearched file" 1 \
    "1 of 1 file(s) searched, 0 symlink target(s), 2 path name(s)"

# ── the blobs a push publishes that its tip does not hold ───────────────
#
# A push publishes a RANGE and this mode read the TIP's tree. A file added in
# one pushed commit and removed in the next is in the remote's history
# permanently, is in no tip tree, and was read by nothing -- measured, two
# commits fast-forwarded in from a hookless clone and pushed with every hook
# green and no override of any kind, and `git cat-file` on the remote handing
# the name back afterwards.
#
# The tree half is not redundant: it is what catches a name that arrived BEFORE
# this range and is still there, which no diff over the range can see. Both
# directions are asserted, and so is the trap itself -- a tip tree that is clean
# is exactly why this went unseen.
ranged="$work/pushed-range"
artifact_repo "$ranged"
git -C "$ranged" remote add origin "$work/nowhere.git"
printf 'placeholder\n' > "$ranged/keep.md"
git -C "$ranged" add keep.md
git -C "$ranged" commit -q --no-verify -m 'an ordinary subject line'
ranged_base="$(git -C "$ranged" rev-parse HEAD)"
printf 'ported from https://github.com/acme/secret-thing\n' > "$ranged/scratch.md"
git -C "$ranged" add scratch.md
git -C "$ranged" commit -q --no-verify -m 'add a scratch file'
ranged_added="$(git -C "$ranged" rev-parse HEAD)"
git -C "$ranged" rm -q scratch.md
git -C "$ranged" commit -q --no-verify -m 'clean up scratch files'
ranged_tip="$(git -C "$ranged" rev-parse HEAD)"

tracked_in "$ranged" "tracked: the tip's own tree hides nothing, which is the trap" 0 \
    '!secret-thing' PRE_COMMIT_TO_REF="$ranged_tip" PRE_COMMIT_FROM_REF="$ranged_tip"

tracked_in "$ranged" "tracked: a blob added and removed inside the range is still read" 1 \
    "acme/secret-thing" PRE_COMMIT_TO_REF="$ranged_tip" PRE_COMMIT_FROM_REF="$ranged_base"

# Named the way a reader can act on it. There is no file to open and no line to
# print: what is left to do is rewrite the commit that added it, so that is what
# the finding says.
tracked_in "$ranged" "tracked: ...and the finding names the commit that added it" 1 \
    "added by commit ${ranged_added:0:12}" \
    PRE_COMMIT_TO_REF="$ranged_tip" PRE_COMMIT_FROM_REF="$ranged_base"

# The denominator, in two halves. One number for both would read the same
# whether the range half found 148 blobs or was never asked at all.
tracked_in "$ranged" "tracked: the denominator states the two halves apart" 0 \
    "1 path(s) in the tree scanned, 0 additional blob(s) introduced by the pushed range" \
    PRE_COMMIT_TO_REF="$ranged_tip" PRE_COMMIT_FROM_REF="$ranged_tip"

# And the count moves when the scan reads more, over a range whose extra blob is
# clean -- a number that never moves is not a denominator.
clean_range="$work/pushed-range-clean"
artifact_repo "$clean_range"
printf 'placeholder\n' > "$clean_range/keep.md"
git -C "$clean_range" add keep.md
git -C "$clean_range" commit -q --no-verify -m 'an ordinary subject line'
clean_range_base="$(git -C "$clean_range" rev-parse HEAD)"
printf 'nothing private here\n' > "$clean_range/scratch.md"
git -C "$clean_range" add scratch.md
git -C "$clean_range" commit -q --no-verify -m 'add a scratch file'
git -C "$clean_range" rm -q scratch.md
git -C "$clean_range" commit -q --no-verify -m 'clean up scratch files'
clean_range_tip="$(git -C "$clean_range" rev-parse HEAD)"

tracked_in "$clean_range" "tracked: ...and the range half is counted when there is one" 0 \
    "1 path(s) in the tree scanned, 1 additional blob(s) introduced by the pushed range" \
    PRE_COMMIT_TO_REF="$clean_range_tip" PRE_COMMIT_FROM_REF="$clean_range_base"

# It is SEARCHED, not merely enumerated. The range blob has no path in the tree
# being pushed, so it is handed to git grep as an OBJECT; a scan that listed it
# and never read it would count it here and find nothing in it.
tracked_in "$clean_range" "tracked: ...and it is counted as searched, not just listed" 0 \
    "2 of 2 file(s) searched" \
    PRE_COMMIT_TO_REF="$clean_range_tip" PRE_COMMIT_FROM_REF="$clean_range_base"

# The SAME PATH, two blobs. A file whose private name is edited away in the
# next pushed commit leaves the tip's tree clean at that path -- and the scan's
# record of which paths git grep read is keyed on the PATH. So a range blob
# tested by path would be "already searched" on the strength of the clean blob
# that replaced it, which is a false green built out of the scan's own
# bookkeeping. Range entries are keyed on the OBJECT for exactly this.
overwritten="$work/pushed-range-overwrite"
artifact_repo "$overwritten"
printf 'placeholder\n' > "$overwritten/keep.md"
git -C "$overwritten" add keep.md
git -C "$overwritten" commit -q --no-verify -m base
overwritten_base="$(git -C "$overwritten" rev-parse HEAD)"
printf 'ported from https://github.com/acme/secret-thing\n' > "$overwritten/notes.md"
git -C "$overwritten" add notes.md
git -C "$overwritten" commit -q --no-verify -m 'notes with the name in them'
printf 'ported from a private workspace\n' > "$overwritten/notes.md"
git -C "$overwritten" commit -q --no-verify -am 'reword the notes'
overwritten_tip="$(git -C "$overwritten" rev-parse HEAD)"

tracked_in "$overwritten" "tracked: the tip's blob at that path is clean, which is the trap" 0 \
    '!secret-thing' PRE_COMMIT_TO_REF="$overwritten_tip" PRE_COMMIT_FROM_REF="$overwritten_tip"

tracked_in "$overwritten" "tracked: a blob replaced at the same path is still read" 1 \
    "acme/secret-thing" \
    PRE_COMMIT_TO_REF="$overwritten_tip" PRE_COMMIT_FROM_REF="$overwritten_base"

# The same collision, seen through the denominator rather than through a
# finding. A BINARY blob is the one kind git grep declines to read, and this one
# sits at a path whose tip blob it read happily -- so a range entry tested by
# path is counted as searched on the strength of somebody else's bytes, and the
# skip that should have been printed is not. What was SEARCHED, not what was
# enumerated, is the whole of this mode's denominator.
binary_swap="$work/pushed-range-binary"
artifact_repo "$binary_swap"
printf 'placeholder\n' > "$binary_swap/keep.md"
git -C "$binary_swap" add keep.md
git -C "$binary_swap" commit -q --no-verify -m base
binary_swap_base="$(git -C "$binary_swap" rev-parse HEAD)"
printf 'head\000tail\n' > "$binary_swap/data.txt"
git -C "$binary_swap" add data.txt
git -C "$binary_swap" commit -q --no-verify -m 'a binary blob'
printf 'plain text now\n' > "$binary_swap/data.txt"
git -C "$binary_swap" commit -q --no-verify -am 'and text at the same path'
binary_swap_tip="$(git -C "$binary_swap" rev-parse HEAD)"

tracked_in "$binary_swap" "tracked: a range blob git grep will not read is named as a skip" 0 \
    "data.txt (binary -- no repository name to read out of it)" \
    PRE_COMMIT_TO_REF="$binary_swap_tip" PRE_COMMIT_FROM_REF="$binary_swap_base"

tracked_in "$binary_swap" "tracked: ...and is not counted as one the scan searched" 0 \
    "2 of 3 file(s) searched" \
    PRE_COMMIT_TO_REF="$binary_swap_tip" PRE_COMMIT_FROM_REF="$binary_swap_base"

# A PATH the range published is committed text too, and it outlives the file.
# `vendor/acme/hidden-repo/README` added and deleted inside one push is a
# private repository's name in a public repository's history exactly as a line
# of a file would be.
range_path="$work/pushed-range-path"
artifact_repo "$range_path"
printf 'placeholder\n' > "$range_path/keep.md"
git -C "$range_path" add keep.md
git -C "$range_path" commit -q --no-verify -m base
range_path_base="$(git -C "$range_path" rev-parse HEAD)"
mkdir -p "$range_path/vendor/acme/secret-thing"
printf 'clean content\n' > "$range_path/vendor/acme/secret-thing/README"
git -C "$range_path" add -A
git -C "$range_path" commit -q --no-verify -m 'vendor it'
git -C "$range_path" rm -qr vendor
git -C "$range_path" commit -q --no-verify -m 'and unvendor it'
range_path_tip="$(git -C "$range_path" rev-parse HEAD)"

tracked_in "$range_path" "tracked: a PATH the range published is read too" 1 \
    "acme/secret-thing" \
    PRE_COMMIT_TO_REF="$range_path_tip" PRE_COMMIT_FROM_REF="$range_path_base"

# ── the message a push publishes ────────────────────────────────────────
#
# A commit is a tree AND a message, and only the tree was read here. The message
# is checked by a commit-msg hook, which runs when `git commit` writes one --
# and `git commit-tree`, a rebase, a cherry-pick, `git am`, `--no-verify` and a
# fast-forward from a hookless clone all make a commit without that happening.
# Every commit below is made with --no-verify, which is the cheapest way to
# spell "this message never met the commit-msg guard".
msgs="$work/pushed-messages"
artifact_repo "$msgs"
git -C "$msgs" remote add origin "$work/nowhere.git"
printf 'placeholder\n' > "$msgs/keep.md"
git -C "$msgs" add keep.md
git -C "$msgs" commit -q --no-verify -m 'an ordinary subject line'
msgs_base="$(git -C "$msgs" rev-parse HEAD)"
printf 'more\n' >> "$msgs/keep.md"
git -C "$msgs" commit -q --no-verify -am 'port the fix from https://github.com/acme/secret-thing'
msgs_tip="$(git -C "$msgs" rev-parse HEAD)"

tracked_in "$msgs" "tracked: a pushed commit's MESSAGE is read, not only its tree" 1 \
    "acme/secret-thing" PRE_COMMIT_TO_REF="$msgs_tip" PRE_COMMIT_FROM_REF="$msgs_base"

tracked_in "$msgs" "tracked: ...and the finding names the commit it came out of" 1 \
    "its MESSAGE names it" PRE_COMMIT_TO_REF="$msgs_tip" PRE_COMMIT_FROM_REF="$msgs_base"

tracked_in "$msgs" "tracked: ...and the denominator counts the messages read" 1 \
    "1 commit message(s)" PRE_COMMIT_TO_REF="$msgs_tip" PRE_COMMIT_FROM_REF="$msgs_base"

# The pair: a commit the remote already holds is not being published by this
# push, so it is outside the range and outside the scan. Without it, a guard
# that read every message in the repository every time would pass the cases
# above and refuse every push a consumer ever made after adopting it.
tracked_in "$msgs" "tracked: a message the remote already holds is not this push's" 0 \
    '!secret-thing' PRE_COMMIT_TO_REF="$msgs_base" PRE_COMMIT_FROM_REF="$msgs_base"

# A NEW remote ref exports no FROM at all -- measured under prek 0.3.12, which
# exports nothing rather than git's all-zeros. The range is then everything the
# named remote does not already hold, which for a clone with no tracking refs is
# the whole history of the tip: too much rather than too little.
tracked_in "$msgs" "tracked: a new remote ref still has its messages read" 1 \
    "acme/secret-thing" PRE_COMMIT_TO_REF="$msgs_tip" PRE_COMMIT_REMOTE_NAME=origin

# And nothing at a stage that publishes no commit: at pre-commit the message
# being written is the commit-msg guard's business, and there is no commit yet.
tracked_in "$msgs" "tracked: the index publishes no message, so none is read" 0 \
    "0 commit message(s)"

# ── the resolver is a dependency, not a preference ──────────────────────
#
# Absent, the answer to "which tree" is a refusal and not a fallback. The
# fallback there used to be is the defect, so a packaging mistake that drops the
# file must not quietly restore it.
lonely="$work/lonely"
mkdir -p "$lonely"
cp "$guard" "$lonely/no-private-repo-names.sh"
status=0
output="$(cd "$pushed" && GIT_GUARDS_REPO_VISIBILITY=public GIT_GUARDS_PRIVATE_OWNERS=acme \
    bash "$lonely/no-private-repo-names.sh" --tracked 2>&1)" || status=$?
if [ "$status" -eq 2 ] && [[ "$output" == *"git-guards-scope.sh is not beside this script"* ]]; then
    printf 'ok   %s\n' "tracked: a missing scope resolver refuses rather than guessing"
else
    printf 'FAIL %s (expected exit 2 naming the resolver, got %s)\n%s\n' \
        "tracked: a missing scope resolver refuses rather than guessing" "$status" "$output"
    failures=$((failures + 1))
fi

cd "$project"

# ── where the tree-wide mode is registered ──────────────────────────────
# The stage is a cost decision and it is the difference between a guard people
# keep and one they delete. --tracked asks the forge about every distinct name
# in the whole tree, not the few a commit touches: 46 names and 41 round trips
# here, 19.4 seconds against 0.08 with `gh` off PATH. At pre-commit that is paid
# on every commit forever, and nothing is gained by it, because
# no-private-repo-names-staged already covers what a commit ADDS.
#
# Asserted against the file rather than left to a comment, because a stage list
# is one word to change back and there is no run in which the cost shows up as a
# failure -- it shows up as everybody's commits being slow, which is not
# something a suite notices.
hooks_yaml="$repo_root/.pre-commit-hooks.yaml"
in_files_stages="$(awk '
    /^- id: /            { current = $3 }
    current == "no-private-repo-names-in-files" && /^  stages:/ {
        sub(/^  stages: /, ""); print; exit
    }
' "$hooks_yaml")"

# pre-merge-commit is in that list for a different reason, and it is not a cost
# decision: git runs `pre-merge-commit` for a merge and `pre-commit` for a
# commit, so without it a branch carrying a private name reaches the trunk
# through `git merge --no-ff` with no file guard consulted at all -- the exact
# "arrived through a merge" case this mode describes itself as the backstop for.
if [ "$in_files_stages" = "[pre-merge-commit, pre-push, manual]" ]; then
    printf 'ok   %s\n' "the tree-wide scan is registered at pre-merge-commit, pre-push and manual"
else
    printf 'FAIL %s (found %s)\n' \
        "the tree-wide scan is registered at pre-merge-commit, pre-push and manual" \
        "${in_files_stages:-nothing}"
    failures=$((failures + 1))
fi

# The half that must stay at pre-commit. Moving the tree scan is only defensible
# because this one is still there deciding what the commit adds.
staged_stages="$(awk '
    /^- id: /            { current = $3 }
    current == "no-private-repo-names-staged" && /^  stages:/ {
        sub(/^  stages: /, ""); print; exit
    }
' "$hooks_yaml")"

if [ "$staged_stages" = "[pre-commit]" ]; then
    printf 'ok   %s\n' "the staged scan is still registered at pre-commit"
else
    printf 'FAIL %s (found %s)\n' \
        "the staged scan is still registered at pre-commit" "${staged_stages:-nothing}"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%s test(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nall no-private-repo-names tests passed\n'
