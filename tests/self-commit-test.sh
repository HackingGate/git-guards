#!/usr/bin/env bash
# Can this repository commit to itself?
#
# Every other test here runs a guard directly and asks what it decided. This one
# installs the hooks the way a contributor does and makes a real commit -- and a
# real merge -- because the defects it exists for live in neither guard.
# .pre-commit-config.yaml installs four hook types, and a hook that declares no
# `stages:` runs at ALL of them. At commit-msg the only file a runner has to
# offer is
# .git/COMMIT_EDITMSG, so a hook that declared no stages would have check-toml
# TOML-parse the commit message and actionlint lint it as a workflow, and
# `git commit -m "chore: a plain ascii subject line"` exits 1 with the commit
# never made.
#
# That is invisible to a config lint that only reads the YAML, and invisible to
# every hook run with --all-files. The only instrument that sees it is a commit,
# which is why this file makes one.
#
# Both directions, like every other test in this repository: a clean subject
# line has to LAND, and a subject line carrying a codepoint nobody can see has
# to be REFUSED. Without the second, a config that switched every commit-msg
# hook off would pass this file.
#
# When a case fails, the runner's own output is printed with it. A test that
# reports `this repo can commit to itself ... Failed` and discards what the
# runner said names neither the hook that refused nor the file it refused over,
# and the next person has to reconstruct the run by hand to learn either.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Hermetic against the caller's environment. tests/hermetic-env.sh names every
# variable a git-guards test must not inherit and why; the loop is here rather
# than there because unsetting has to happen in THIS shell.
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$REPO_ROOT/tests/hermetic-env.sh")

failures=0
skipped=0

# The optional fourth argument is a file holding whatever the runner printed.
# It is shown only on failure: on a green run it is noise, and on a red one it
# is the entire diagnosis.
check() {
    local name="$1" want="$2" got="$3" log="${4:-}"
    if [ "$want" = "$got" ]; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s (want %s, got %s)\n' "$name" "$want" "$got"
        if [ -n "$log" ] && [ -s "$log" ]; then
            printf '     ---- what the runner printed ----\n'
            sed 's/^/     /' "$log"
            printf '     ---------------------------------\n'
        fi
        failures=$((failures + 1))
    fi
}

# ── the fixture, in bytes, because the fixture is what broke ────────────
#
# U+200B is planted four times below, and every case asserting a REFUSAL is
# worth exactly as much as those three bytes reaching the file. A \u escape does
# not put them there. bash renders one through the CURRENT LOCALE's charset, and
# when the charset cannot hold the codepoint it emits the escape itself as
# literal ASCII. Spelling the zero-width space the obvious way and asking for the
# bytes back:
#
#   under en_US.UTF-8   74 69 64 79 e2 80 8b 75 70      tidy<U+200B>up
#   under LC_ALL=C      74 69 64 79 5c 75 32 30 30 42 75 70
#
# The second is `tidy`, a backslash, `u200B`, `up`: twelve ASCII characters, no
# zero-width space among them, and a capital B the source never wrote. `$'...'`,
# `printf '%b'` and a `$(...)` capture of any of them degrade identically; only
# the enclosing locale decides.
#
# So on a runner with no UTF-8 locale installed -- which is what CI gives you --
# every guard correctly passed a clean message, every "is refused" case failed,
# and nothing in the output suggested the fixture. Seven failures that read as
# seven broken guards.
#
# Octal escapes are BYTES. printf writes them unconverted in every locale, which
# is the property a fixture needs and \u does not have. Written once here and
# interpolated, so there is one spelling to get right instead of four.
ZWSP="$(printf '\342\200\213')"

# And asserted, because the failure mode is a fixture that quietly stops being
# the thing under test. A degraded ZWSP does not break these cases, it INVERTS
# them: each one hands a guard a clean message and records the approval.
#
# `od` and not `${#ZWSP}`: the length of a string is itself locale-dependent --
# ${#ZWSP} is 1 under a UTF-8 locale and 3 under C -- so a check written that way
# would be measuring the very thing it is supposed to be independent of.
zwsp_bytes="$(printf '%s' "$ZWSP" | od -An -tx1 | tr -d ' \n')"
if [ "$zwsp_bytes" != "e2808b" ]; then
    printf 'FAIL the U+200B fixture is not U+200B\n'
    printf '     planted bytes %s, wanted e2808b\n' "${zwsp_bytes:-nothing}"
    printf '     every "is refused" case below would be handing a guard a clean\n'
    printf '     message and recording that it passed\n'
    exit 1
fi

# The runner is a dependency of the test, not of the repository, so a machine
# without one is reported rather than passed. A skipped case that prints nothing
# is a green run that checked nothing.
runner=""
for candidate in prek pre-commit; do
    if command -v "$candidate" >/dev/null 2>&1; then
        runner="$candidate"
        break
    fi
done
if [ -z "$runner" ]; then
    printf 'SKIP the self-commit lane: neither prek nor pre-commit is on PATH\n'
    printf '     this is the only test that installs the hooks and commits\n'
    printf '\nall self-commit tests passed (1 lane skipped)\n'
    exit 0
fi

# git exports GIT_DIR, GIT_INDEX_FILE and friends to every hook it runs, and
# those beat `git -C` in every git command below. So a run of this file from
# inside somebody's commit would install hooks into THEIR repository and commit
# THEIR index, which is the one thing a test may never do. Cleared here rather
# than guarded against, because the copy needs no inherited git state at all.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY
unset GIT_COMMON_DIR GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG

work="$(mktemp -d)"
# A second area, outside the copy, for the push lane's bare remote and its
# hookless clone. Outside deliberately: a bare repository inside the work tree
# is a second .git for every tool that walks upward from a subdirectory.
push_area="$(mktemp -d)"
trap 'rm -rf "$work" "$push_area"' EXIT

# A copy of the WORK TREE, not a clone: the point is to exercise the config as
# it stands in the checkout being tested, including changes not yet committed.
# A fresh `git init` on top, so the installed hooks and the commits made below
# belong to the copy and can never touch the repository under test.
tar -C "$REPO_ROOT" --exclude=.git -cf - . | tar -C "$work" -xf -
git -C "$work" init -q .
git -C "$work" config user.name "git-guards self test"
git -C "$work" config user.email "self-test@example.invalid"
git -C "$work" config commit.gpgsign false
git -C "$work" add -A >/dev/null

if ! (cd "$work" && "$runner" install >/dev/null 2>&1); then
    printf 'FAIL %s install did not succeed in the copy\n' "$runner"
    exit 1
fi

# The heavy self-tests are skipped inside the copy's own commit, and only they.
# They are this suite, so leaving them in would make one test run the others
# recursively; this file's own hook is named too, because a commit that runs a
# test that makes a commit that runs the test does not terminate. They all
# declare their stages already, so none of them is what this file is measuring.
# Everything that had no `stages:` -- the upstream file hooks and actionlint,
# which are exactly what broke the commit -- stays in.
export SKIP="guard-tests,private-name-tests,pin-tests,unicode-in-files-selftest,self-commit-test"

runner_log="$work/runner-output.txt"

commit_in_copy() {
    local subject="$1"
    printf '%s\n' "$subject" >"$work/subject.txt"
    (cd "$work" && git commit -q -F subject.txt >"$runner_log" 2>&1)
    printf '%s' "$?"
}

before="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"
status="$(commit_in_copy 'chore: a plain ascii subject line')"
after="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"

check "a plain ascii subject line commits cleanly" 0 "$status" "$runner_log"
# Asserted separately from the exit code, because the outcome that matters is
# not what the runner printed but whether the history moved. A hook runner that
# exits 0 having aborted the commit would pass the line above.
check "...and the commit is actually in the history" 1 "$((after - before))" \
    "$runner_log"

# The other direction, in the mode where being wrong is permanent. U+200B is a
# zero-width space: the subject reads as `chore: tidy up` to every reviewer and
# to every log, and the commit-msg guard is the only thing between it and
# published history. If this passes, the fix above has switched the message mode
# off instead of scoping it.
printf 'chore: tidy%s up\n' "$ZWSP" >"$work/hidden.txt"
before="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"
(cd "$work" && git commit -q --allow-empty -F hidden.txt >"$runner_log" 2>&1)
status="$?"
after="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"

check "a hidden codepoint in the subject is refused" 1 "$status" "$runner_log"
check "...and no commit was made" 0 "$((after - before))" "$runner_log"

# ── the runner's own commit-msg entry point ─────────────────────────
#
# `git commit` is not the only way these guards are reached. A person checking
# whether a guard actually catches something runs the runner directly:
#
#   prek run --hook-stage commit-msg --commit-msg-filename <a message file>
#
# and that path has to give the same answer as a commit, because it is the path
# somebody uses to decide whether the guard works at all. A wrong answer here is
# worse than no answer: it is a green tick over a message the guard never read.
#
# The trap is that the message file arrives as an ARGUMENT, and a hook declaring
# `pass_filenames: false` is handed none -- the runner passes ARGC=0 and exports
# nothing naming the file, so the guard has no way to learn it exists and falls
# back to .git/COMMIT_EDITMSG. That file is left behind by the LAST successful
# commit, so it holds a clean subject, and the guards report Passed over it
# while the dirty file named on the command line goes unread.
#
# So .git/COMMIT_EDITMSG is planted with a CLEAN subject first, and that is what
# makes the cases below discriminating rather than decorative. git writes that
# file before it runs any hook, so the refused commit above left the hidden
# codepoint sitting in it -- and against a dirty fallback every "is refused"
# case below passes whether or not the guard ever opened the file it was handed.
# It would be a test that goes green for the defect it exists to catch.
#
# With a clean fallback in place the two answers separate completely: a guard
# reading the file it was GIVEN refuses, and a guard reading the fallback
# reports Passed over a message nobody wrote.
printf 'chore: a plain ascii subject line\n' >"$work/.git/COMMIT_EDITMSG"
planted="$(cat "$work/.git/COMMIT_EDITMSG")"
if [ "$planted" != "chore: a plain ascii subject line" ]; then
    printf 'FAIL the commit-msg-filename lane needs a clean COMMIT_EDITMSG to be meaningful\n'
    printf '     (planted a clean subject, read back %q)\n' "$planted"
    failures=$((failures + 1))
fi

# The private-name lane is driven entirely from the environment -- a declared
# private owner and a stated visibility -- so it needs neither `gh` nor a
# network nor an origin remote, and it answers the same way on a laptop and on a
# cold runner. Left to resolve on its own the copy has no origin at all, the
# guard would correctly decline to guess, and the lane would be green without
# having checked anything.
msg_lane() {
    local name="$1" want="$2" message="$3"
    printf '%b' "$message" >"$work/handed-over.txt"
    (
        cd "$work" &&
            GIT_GUARDS_REPO_VISIBILITY=public \
                GIT_GUARDS_PRIVATE_OWNERS=acme \
                "$runner" run --hook-stage commit-msg \
                --commit-msg-filename "$work/handed-over.txt" \
                >"$runner_log" 2>&1
    )
    check "$name" "$want" "$?" "$runner_log"
}

# A subject the guards must not object to, so a refusal below is the guard
# reading the file rather than the guard refusing everything.
msg_lane "a clean message handed to the runner passes" 0 \
    'chore: a plain ascii subject line\n'

# One case per commit-msg guard, each carrying what that guard alone refuses.
msg_lane "a hidden codepoint in the handed-over file is refused" 1 \
    "chore: tidy${ZWSP} up\n"
msg_lane "an AI-authorship trailer in the handed-over file is refused" 1 \
    'chore: tidy up\n\nCo-Authored-By: Someone <noreply@example.invalid>\n'
msg_lane "a private repo name in the handed-over file is refused" 1 \
    'fix: the same crash as in acme/ledger\n'

# ── a merge, which is the stage no other test can reach ──────────────────
#
# git runs `pre-merge-commit` for a merge and `pre-commit` for a commit. They
# are different hook types installed by different lines, so a config listing
# only pre-commit and commit-msg runs NO file guard for a merge at all -- and
# the tree-wide guards describe themselves, in this repository's own comments,
# as the backstop for a character or a name that "arrived through a merge". The
# comments were refuting themselves: a branch adding U+200B under --no-verify
# merged into the trunk with the whole hook set installed and silent, and pushed.
#
# Nothing else here can see that. Every other lane makes a COMMIT, and a commit
# is the one operation that does run pre-commit. `prek run --all-files` cannot
# see it either: every hook passes when it is run, and the defect is a hook that
# is never run. So this lane performs a real `git merge --no-ff` in the copy and
# asks git what happened to the history.
#
# Both directions, like everything else here. Without the clean half, a config
# that refused every merge outright would pass this lane -- and `no-local-merge`,
# which this repository publishes and deliberately does not run over itself, is
# exactly such a config one line away.
merge_lane_status() {
    local branch="$1" content="$2" subject="$3"
    git -C "$work" checkout -q -b "$branch" >/dev/null 2>&1
    printf '%b' "$content" >"$work/$branch.txt"
    git -C "$work" add "$branch.txt" >/dev/null 2>&1
    # --no-verify, because the point is a commit that never met a hook. That is
    # how the character gets onto the branch in the case being modelled.
    git -C "$work" commit -q --no-verify -m "chore: a branch that met no hook" \
        >/dev/null 2>&1
    git -C "$work" checkout -q - >/dev/null 2>&1
    git -C "$work" merge --no-ff -m "$subject" "$branch" >"$runner_log" 2>&1
    printf '%s' "$?"
}

before="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"
status="$(merge_lane_status hidden-branch "key:${ZWSP}value\n" 'chore: merge a branch that met no hook')"
after="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"
check "a merge carrying a hidden codepoint is refused" 1 "$status" "$runner_log"
check "...and no merge commit was made" 0 "$((after - before))" "$runner_log"

# A refused merge leaves the working tree merged and MERGE_HEAD set, so the copy
# is put back before the paired case runs -- otherwise the second merge would be
# a completed one, and would tell us nothing.
git -C "$work" merge --abort >/dev/null 2>&1 || true
git -C "$work" reset -q --hard HEAD >/dev/null 2>&1

before="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"
status="$(merge_lane_status plain-branch 'key: value\n' 'chore: merge a clean branch')"
after="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"
check "a merge of a clean branch still lands" 0 "$status" "$runner_log"
check "...and the merge commit is in the history" 2 "$((after - before))" "$runner_log"

# ── a push, which no other lane can reach either ─────────────────────────
#
# A fast-forward merge creates NO commit, so git runs no pre-merge-commit hook
# for one -- the lane above cannot see it, and neither can any lane that makes a
# commit. The push is the only moment left, and until this repository registered
# the file-unicode guard at pre-push there was nothing there to look: a commit
# carrying U+200B rode a `git merge --ff-only` from a hookless clone to a remote
# with the whole hook set installed, green, and silent.
#
# What is exercised here is a real `git push` into a real bare repository, with
# the commit arriving exactly the way the measured one did: made in a CLONE with
# no hooks installed at all, then fast-forwarded in. Nothing is bypassed
# anywhere -- no --no-verify, no SKIP, no override -- which is the whole point.
# The character is in the commit MESSAGE, which is a thing a push publishes and
# which the pre-push guards did not read at all: they read the tree.
push_remote="$push_area/remote.git"
git init -q --bare "$push_remote"
git -C "$work" remote add push-target "$push_remote"
trunk="$(git -C "$work" symbolic-ref --short HEAD)"

remote_tip() {
    git -C "$push_remote" rev-parse --verify --quiet "refs/heads/$trunk" || printf 'none'
}

push_status() {
    (cd "$work" && git push push-target "$trunk" >"$runner_log" 2>&1)
    printf '%s' "$?"
}

# The clean half first, and it does two jobs: it proves the pre-push lane is not
# simply refusing everything, and it gives the remote a ref for the assertions
# below to compare against.
status="$(push_status)"
check "a clean history pushes" 0 "$status" "$runner_log"
clean_tip="$(remote_tip)"
check "...and the remote actually moved" "$(git -C "$work" rev-parse HEAD)" \
    "$clean_tip" "$runner_log"

# A clone of the copy, with nothing installed in it. This is where the commit is
# made, and it is made by an ordinary `git commit`: there is no hook in this
# repository to bypass, which is the situation being modelled rather than one
# being arranged.
hookless="$push_area/hookless"
git clone -q "$work" "$hookless"
git -C "$hookless" config user.name "somebody with no hooks"
git -C "$hookless" config user.email "hookless@example.invalid"
git -C "$hookless" config commit.gpgsign false
printf 'a line\n' >"$hookless/hookless-note.txt"
git -C "$hookless" add hookless-note.txt >/dev/null 2>&1
# Interpolated, not written out: a literal zero-width space in this file is one
# formatter away from being stripped, and the lane would then pass while
# asserting nothing. $ZWSP is checked against its bytes at the top of the file,
# which a literal here never would be.
git -C "$hookless" commit -q -m "chore: tidy${ZWSP} up"

# The fast-forward. No hook runs for one, and the assertion says so: if a hook
# had refused here the push assertions below would be measuring the wrong thing.
git -C "$work" fetch -q "$hookless" HEAD
before="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"
git -C "$work" merge --ff-only FETCH_HEAD >"$runner_log" 2>&1
merge_status="$?"
after="$(git -C "$work" rev-list --count HEAD 2>/dev/null || printf '0')"
check "a fast-forward merge runs no hook at all" 0 "$merge_status" "$runner_log"
check "...and the commit it carried is in the history" 1 "$((after - before))" \
    "$runner_log"

status="$(push_status)"
check "pushing a message that met no commit-msg hook is refused" 1 "$status" \
    "$runner_log"
check "...and nothing reached the remote" "$clean_tip" "$(remote_tip)" "$runner_log"

# Put the copy back, so the lanes after this one see the history they expect.
git -C "$work" reset -q --hard "$clean_tip"

# ── the same wiring, in the file consumers actually get ──────────────────
#
# Everything above is driven through .pre-commit-config.yaml, which is how this
# repository runs the guards over ITSELF. A consumer never reads that file: they
# get .pre-commit-hooks.yaml, and the two are free to drift. So the declaration
# the cases above depend on is asserted directly in the published manifest.
#
# It is one word per hook, its absence changes no behaviour under `git commit`,
# and there is no run in which flipping it back shows up as a failure -- it shows
# up as a guard that reports Passed over a message it never opened.
hooks_yaml="$REPO_ROOT/.pre-commit-hooks.yaml"
for msg_hook in prevent-ai-author prevent-unusual-unicode no-private-repo-names; do
    declared="$(awk -v want="$msg_hook" '
        /^- id: /                             { current = $3 }
        current == want && /^  pass_filenames:/ {
            print $2; exit
        }
    ' "$hooks_yaml")"
    check "$msg_hook is published with pass_filenames: true" true "${declared:-nothing}"
done

# ── the stages CI actually reaches ──────────────────────────────────────
#
# `--hook-stage manual` covers 11 of the 19 hooks this repository configures
# across its two file stages. The other 8 are pre-commit-only -- the upstream
# file hooks, actionlint, the staged private-name scan -- and they are exactly
# what decides whether an ordinary `git commit` succeeds here. A CI that runs
# only the manual set is green on a tree nobody can commit to.
#
# Asserted on the workflow because the shortfall has no other instrument. Every
# hook passes when it is run, so a stage that is never invoked reports nothing
# at all: there is no failure to notice, only a coverage number nobody computed.
#
# Both runners, which is why the counts are 2. `extra_args` is pre-commit's
# action, `extra-args` is prek's, and one spelling matching twice while the
# other matches nothing would leave a runner uncovered -- so each spelling is
# counted on its own rather than together.
workflow="$REPO_ROOT/.github/workflows/test.yml"
for spelling in extra_args extra-args; do
    commit_stage="$(grep -cE "^ +${spelling}: --all-files$" "$workflow")"
    manual_stage="$(grep -cE "^ +${spelling}: --all-files --hook-stage manual$" "$workflow")"
    check "CI runs the stage a contributor's commit runs ($spelling)" 1 "$commit_stage"
    check "...and the manual stage ($spelling)" 1 "$manual_stage"
done

# ── byte-compiled python is not this repository's content ───────────────
#
# Two of the guards here are Python, so a __pycache__ is a thing a checkout can
# grow: importing either module rather than spawning it writes one, and so does
# any tooling that loads them. Nothing in the suite does that today -- every
# test spawns the checkers as subprocesses, and Python never caches a __main__ --
# so this is prevention rather than a repair, and it is cheap prevention.
#
# What makes it worth a line: a .pyc is not valid UTF-8, and the file-content
# guard classifies a binary file as a declared skip. So a stray __pycache__ is
# the one kind of untracked directory this repository's own hooks would carry
# past without remark, all the way to whoever runs `git add -A`.
#
# Asserted in the copy, where a real .pyc-shaped file is created and git is
# asked what it sees, rather than by reading .gitignore for a line -- an ignore
# rule that is present and does not match is the failure this is for.
mkdir -p "$work/__pycache__"
printf '\xcf\x0d\x0d\x0a not utf-8 \x00\xff' >"$work/__pycache__/checker.cpython-313.pyc"
pycache_seen="$(git -C "$work" status --porcelain 2>/dev/null | grep -c '__pycache__' || true)"
check "a stray __pycache__ is ignored, not offered up for commit" 0 "$pycache_seen"

if [ "$failures" -ne 0 ]; then
    printf '\n%s self-commit test(s) failed\n' "$failures"
    exit 1
fi
printf '\nall self-commit tests passed (runner: %s, %s lane(s) skipped)\n' \
    "$runner" "$skipped"
