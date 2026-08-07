#!/usr/bin/env bash
# Behaviour tests for no-stale-hook-pins.py.
#
# Two lanes, because the check has two halves that fail in different ways.
#
# The stub lane puts a `git` on PATH that answers `ls-remote` out of a fixture
# directory and hands every other subcommand to the real one -- the same trick
# tests/no-private-repo-names-test.sh plays with `gh`. It is offline and
# deterministic, so it can pin down the answers a network cannot be asked for
# on demand: an upstream with no tags, one whose tags are all code names, one
# whose newest release is behind a release candidate, and a remote that is
# simply not there. Every one of those is a case where the wrong answer is
# "up to date", so every one of them is asserted on the exit code AND on what
# the message says.
#
# The network lane runs the real thing against a real public repository, once
# in each direction, because a check that has only ever seen a fixture has only
# ever proved that the fixture parses. It is skipped -- loudly, and counted --
# when there is no network, and the stub lane still covers the same outcomes.
#
# Every stub case runs through BOTH config readers: the PyYAML one and the
# narrow fallback, forced by shadowing `yaml` with a module that refuses to
# import. Two readers are two rules that agree until they do not, and the only
# way that stays untrue is to run the same fixtures through both and require
# the same answer.
#
# One section builds a real work tree instead of a config file, because the
# question there is not what the check reads but what it goes looking for: prek
# runs a nested .pre-commit-config.yaml, so the sweep that finds them is part of
# the denominator and is asserted on a repository with a root config, a tracked
# nested one, an untracked nested one and an ignored one.
#
# The negative assertion carries most of the weight in this file. `!every pin
# was compared` appears beside nearly every refusal, because a reader that walks
# past an entry does not announce it -- it reports a shorter denominator and the
# same cheerful sentence, and only an assertion that the sentence is ABSENT can
# tell those two runs apart.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Hermetic against the caller's environment. tests/hermetic-env.sh names every
# variable a git-guards test must not inherit and why; the loop is here rather
# than there because unsetting has to happen in THIS shell.
while IFS= read -r leaked_name; do
    [ -n "$leaked_name" ] || continue
    unset "$leaked_name"
done < <("$repo_root/tests/hermetic-env.sh")

guard="$repo_root/no-stale-hook-pins.py"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
skipped=0

# ── the git stub ────────────────────────────────────────────────────────
# REAL_GIT is resolved BEFORE the stub goes on PATH, or the stub would exec
# itself and the suite would hang instead of failing.
REAL_GIT="$(command -v git)"
export REAL_GIT
export LS_REMOTE_FIXTURES="$work/tags"
export LS_REMOTE_ERRORS="$work/errors"
mkdir -p "$LS_REMOTE_FIXTURES" "$LS_REMOTE_ERRORS"

stub_bin="$work/bin"
mkdir -p "$stub_bin"

# Written by a function rather than once, because one case below replaces this
# stub with a different one and has to put it back. A second copy of the stub
# would be a second claim about the world, and the two would agree until they
# did not.
install_git_stub() {
    cat > "$stub_bin/git" <<'STUB'
#!/usr/bin/env bash
# Answers `ls-remote` from a fixture, delegates everything else. A URL with no
# fixture gets what a real unreachable remote gets: git's own words, on stderr,
# and exit 128 -- unless an error fixture says what those words are, which is
# how the non-UTF-8 stderr case below is reproduced without a Japanese locale
# installed on the machine running this.
if [ "${1:-}" = "ls-remote" ]; then
    url=""
    for arg in "$@"; do
        case "$arg" in
            ls-remote | --tags | --refs | --) ;;
            *) url="$arg" ;;
        esac
    done
    key="$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')"
    if [ -f "$LS_REMOTE_FIXTURES/$key" ]; then
        cat "$LS_REMOTE_FIXTURES/$key"
        exit 0
    fi
    if [ -f "$LS_REMOTE_ERRORS/$key" ]; then
        cat "$LS_REMOTE_ERRORS/$key" >&2
        exit 128
    fi
    printf 'remote: Repository not found.\n' >&2
    printf 'fatal: repository %s not found\n' "$url" >&2
    exit 128
fi
exec "$REAL_GIT" "$@"
STUB
    chmod +x "$stub_bin/git"
}
install_git_stub

original_path="$PATH"
export PATH="$stub_bin:$PATH"

# One fixture: a URL and the tags that URL has. No arguments after the URL
# means a repository that exists and has never been tagged, which is a
# different answer from one that could not be reached.
fixture() {
    local url="$1" key tag
    shift
    key="$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')"
    : > "$LS_REMOTE_FIXTURES/$key"
    for tag in "$@"; do
        printf '%040d\trefs/tags/%s\n' 0 "$tag" >> "$LS_REMOTE_FIXTURES/$key"
    done
}

# The other half of a fixture: a URL whose `ls-remote` fails, with these exact
# bytes on stderr. Read from stdin rather than taken as an argument so the
# non-UTF-8 case can be written as octal escapes and stay readable.
error_fixture() {
    local url="$1" key
    key="$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')"
    cat > "$LS_REMOTE_ERRORS/$key"
}

# ── the reader lanes ────────────────────────────────────────────────────
# A `yaml` package that raises on import, so `import yaml` fails exactly as it
# does on a system interpreter that never had PyYAML installed.
mkdir -p "$work/no-yaml/yaml"
printf 'raise ImportError("PyYAML is not installed in this lane")\n' \
    > "$work/no-yaml/yaml/__init__.py"

readers=(narrow)
if python3 -c 'import yaml' 2>/dev/null; then
    readers=(pyyaml narrow)
else
    printf 'SKIP the PyYAML reader lane: PyYAML is not importable here\n'
    skipped=$((skipped + 1))
fi

reader_path() {
    case "$1" in
        narrow) printf '%s\n' "$work/no-yaml" ;;
        *) printf '\n' ;;
    esac
}

# A config, written from stdin, whose path is printed. Every case gets its own
# file so a failure names something a person can open.
config() {
    local path="$work/$1.yaml"
    cat > "$path"
    printf '%s\n' "$path"
}

# The assertion. Exit code AND message, always: a check that exits non-zero
# without naming the pin sends somebody to read the whole config, and one that
# names it while exiting 0 is the failure this whole hook exists to end.
#
# A needle beginning with `!` asserts the opposite -- the run must NOT say this.
# Without it, "said nothing" and "said the wrong thing" pass the same
# assertion.
check() {
    local name="$1" expected="$2" needle="$3" cfg="$4"
    shift 4
    local reader status output matched
    for reader in "${readers[@]}"; do
        status=0
        output="$(env PYTHONPATH="$(reader_path "$reader")" "$@" \
            python3 "$guard" "$cfg" 2>&1)" || status=$?

        matched=no
        if [ "${needle:0:1}" = "!" ]; then
            [[ "$output" != *"${needle:1}"* ]] && matched=yes
        else
            [[ "$output" == *"$needle"* ]] && matched=yes
        fi

        if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
            printf 'ok   [%s] %s\n' "$reader" "$name"
            continue
        fi
        printf 'FAIL [%s] %s (expected exit %s matching %q, got %s)\n%s\n' \
            "$reader" "$name" "$expected" "$needle" "$status" "$output"
        failures=$((failures + 1))
    done
}

# The same assertion against ONE reader. The narrow reader refuses constructs
# PyYAML resolves -- an anchor, a second document -- and that asymmetry is
# deliberate: a fallback that guessed would be the second rule this suite
# exists to prevent. So those cases are asserted where they apply.
#
# A needle beginning with `!` inverts, exactly as in check() above. It is the
# assertion that matters most in the one-reader cases: a fallback that drops an
# entry it cannot read reports a SHORT pin list, and a short pin list is what
# "every pin was compared" is printed from.
check_reader() {
    local reader="$1" name="$2" expected="$3" needle="$4" cfg="$5"
    shift 5
    local status=0 output matched=no
    output="$(env PYTHONPATH="$(reader_path "$reader")" "$@" \
        python3 "$guard" "$cfg" 2>&1)" || status=$?
    if [ "${needle:0:1}" = "!" ]; then
        [[ "$output" != *"${needle:1}"* ]] && matched=yes
    else
        [[ "$output" == *"$needle"* ]] && matched=yes
    fi
    if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
        printf 'ok   [%s] %s\n' "$reader" "$name"
        return
    fi
    printf 'FAIL [%s] %s (expected exit %s matching %q, got %s)\n%s\n' \
        "$reader" "$name" "$expected" "$needle" "$status" "$output"
    failures=$((failures + 1))
}

# ── the case this exists for ────────────────────────────────────────────
# A pin two releases behind, exactly as it was found: the upstream had tagged
# twice, the config still named the old one, and every surface said healthy.
fixture https://github.com/acme/guards v1.0.0 v1.1.0 v1.2.0 v1.3.0

behind_cfg="$(config behind <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.1.0
    hooks:
      - id: some-guard
YAML
)"

check "a pin behind its upstream is refused" 1 \
    "hook pins are behind" "$behind_cfg"
check "...naming the repository" 1 \
    "https://github.com/acme/guards" "$behind_cfg"
check "...naming the version it is pinned to" 1 \
    "pinned v1.1.0" "$behind_cfg"
check "...and the version that exists" 1 \
    "newest is v1.3.0" "$behind_cfg"
check "...and where the rev is written" 1 \
    "behind.yaml:3" "$behind_cfg"

current_cfg="$(config current <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
    hooks:
      - id: some-guard
YAML
)"

check "a pin at the newest tag passes" 0 \
    "every pin was compared and is at its upstream's newest tag" "$current_cfg"
check "...and states its denominator" 0 \
    "1 remote pin(s) read, 1 compared against their upstream, 0 not checked" "$current_cfg"
# ...and names what it read. The sentence above is a claim about specific files,
# and the files are not obvious: prek is a workspace runner and will run a
# nested .pre-commit-config.yaml this check never opens unless it is named. A
# scope printed nowhere is a scope the reader supplies from imagination.
check "...and names the config the claim is about" 0 \
    "read $current_cfg" "$current_cfg"

# ── nothing checked is not everything checked ───────────────────────────
local_cfg="$(config local-only <<'YAML'
repos:
  - repo: local
    hooks:
      - id: house-rule
        name: a rule that lives here
        entry: ./rule.sh
        language: script
  - repo: meta
    hooks:
      - id: check-hooks-apply
YAML
)"

check "a config with no remote repos passes" 0 \
    "NOTHING was verified" "$local_cfg"
check "...counting what it did not check" 0 \
    "0 remote pin(s) read, 0 compared against their upstream, 0 not checked, 2 local/meta entries skipped" "$local_cfg"
check "...and never claiming it verified a pin" 0 \
    '!every pin was compared' "$local_cfg"

# ── could not look is not up to date ────────────────────────────────────
# The whole reason for exit 2. Every case below is one where the tempting
# answer is 0, and 0 is the answer that let dozens of repositories rot.
unreachable_cfg="$(config unreachable <<'YAML'
repos:
  - repo: https://github.com/acme/vanished
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"

check "an unreachable remote is not a pass" 2 \
    "could not be checked" "$unreachable_cfg"
check "...naming the remote" 2 \
    "https://github.com/acme/vanished" "$unreachable_cfg"
check "...quoting what git said" 2 \
    "remote unreachable: remote: Repository not found." "$unreachable_cfg"
check "...and never claiming the pin is current" 2 \
    '!every pin was compared' "$unreachable_cfg"
# The denominator has to survive this: a pin READ out of the config and a pin
# COMPARED against its upstream are different numbers, and one count covering
# both is how a remote that never answered gets described as checked.
check "...and counting it as read but not compared" 2 \
    "1 remote pin(s) read, 0 compared against their upstream, 1 not checked" \
    "$unreachable_cfg"

check "the offline downgrade is a deliberate act, and still reports" 0 \
    "https://github.com/acme/vanished" "$unreachable_cfg" \
    GIT_GUARDS_ALLOW_UNCHECKED_PINS=1

fixture https://github.com/acme/untagged
untagged_cfg="$(config untagged <<'YAML'
repos:
  - repo: https://github.com/acme/untagged
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"

check "an upstream with no tags is its own outcome" 2 \
    "the upstream has no tags at all" "$untagged_cfg"
check "...and is not reported as behind" 2 \
    '!behind' "$untagged_cfg"

fixture https://github.com/acme/codenames tip nightly release-train
codenames_cfg="$(config codenames <<'YAML'
repos:
  - repo: https://github.com/acme/codenames
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"

check "tags that are not versions do not crash it" 2 \
    "none of the upstream's 3 tag(s) names a version" "$codenames_cfg"

# A repository that carries both. The junk must neither crash the comparison
# nor win it.
fixture https://github.com/acme/mixed latest v1.9.0 nightly v2.0.0 keys/signing
mixed_cfg="$(config mixed <<'YAML'
repos:
  - repo: https://github.com/acme/mixed
    rev: v1.9.0
    hooks:
      - id: some-guard
YAML
)"

check "a version is chosen from among tags that are not versions" 1 \
    "newest is v2.0.0" "$mixed_cfg"

# THE ONE A SHELL ONE-LINER GETS WRONG. `git ls-remote` returns tags in
# lexicographic order, where v1.7.9 sorts after v1.7.12 -- so the naive answer
# is not imprecise, it is wrong in the direction that reports a behind pin as
# current.
fixture https://github.com/acme/lexical v1.7.9 v1.7.10 v1.7.11 v1.7.12
lexical_cfg="$(config lexical <<'YAML'
repos:
  - repo: https://github.com/acme/lexical
    rev: v1.7.9
    hooks:
      - id: some-guard
YAML
)"
check "v1.7.9 is behind v1.7.12, not ahead of it" 1 \
    "newest is v1.7.12" "$lexical_cfg"

lexical_ok_cfg="$(config lexical-ok <<'YAML'
repos:
  - repo: https://github.com/acme/lexical
    rev: v1.7.12
    hooks:
      - id: some-guard
YAML
)"
check "...and v1.7.12 is current" 0 \
    "every pin was compared and is at its upstream's newest tag" "$lexical_ok_cfg"

# A release candidate is not a release. An upstream that tags an rc is not
# asking every consumer onto it, and a check that demanded the move is one
# people switch off.
fixture https://github.com/acme/candidate v1.3.0 v1.4.0-rc.1
candidate_cfg="$(config candidate <<'YAML'
repos:
  - repo: https://github.com/acme/candidate
    rev: v1.3.0
    hooks:
      - id: some-guard
YAML
)"
check "a release candidate does not make a release stale" 0 \
    "every pin was compared and is at its upstream's newest tag" "$candidate_cfg"

# ...but an upstream that has ONLY ever tagged candidates still has a newest
# one, and "no versions here" for it would be a false clean answer.
fixture https://github.com/acme/prerelease-only v0.9.0-rc.1 v0.9.0-rc.2
prerelease_cfg="$(config prerelease-only <<'YAML'
repos:
  - repo: https://github.com/acme/prerelease-only
    rev: v0.9.0-rc.1
    hooks:
      - id: some-guard
YAML
)"
check "with nothing but candidates, the newest candidate counts" 1 \
    "newest is v0.9.0-rc.2" "$prerelease_cfg"

# A rev with no place in a version order. Pinning a sha is a legitimate thing
# to do and this check cannot judge it -- which makes it exit 2, not exit 0.
sha_cfg="$(config sha <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: 4f2c1b8d9e7a3c5f0b6d2e8a1c4f7b3d5e9a0c2b
    hooks:
      - id: some-guard
YAML
)"
check "a commit sha is not silently passed as current" 2 \
    "is not a version" "$sha_cfg"

# A rev that parses as a version the upstream does not have: a deleted tag, a
# typo, or a tag that only exists on somebody's laptop.
absent_cfg="$(config absent <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.1.5
    hooks:
      - id: some-guard
YAML
)"
check "a rev the upstream does not have is reported" 2 \
    "the upstream has no tag 'v1.1.5'" "$absent_cfg"

# A confirmed finding outranks an unresolved one: exit 1 is the more specific
# answer and losing it would be the worse trade.
both_cfg="$(config both <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.1.0
    hooks:
      - id: some-guard
  - repo: https://github.com/acme/vanished
    rev: v1.0.0
    hooks:
      - id: another-guard
YAML
)"
check "a behind pin outranks an unreachable one" 1 \
    "newest is v1.3.0" "$both_cfg"
check "...and the unreachable one is still reported" 1 \
    "https://github.com/acme/vanished" "$both_cfg"

# ── declared exceptions ─────────────────────────────────────────────────
check "a hold pinned to the rev it was granted for is honoured" 0 \
    "held by acme/guards@v1.1.0" "$behind_cfg" \
    GIT_GUARDS_PINS_HELD=acme/guards@v1.1.0
check "...and does not claim the pin is current" 0 \
    '!every pin was compared' "$behind_cfg" \
    GIT_GUARDS_PINS_HELD=acme/guards@v1.1.0
# An exemption printed without the version it is refusing tells a reader
# nothing they can act on, and a hold nobody can act on is a hold nobody
# revisits.
check "...and says what it is being held back from" 0 \
    "newest is v1.3.0" "$behind_cfg" \
    GIT_GUARDS_PINS_HELD=acme/guards@v1.1.0
check "a hold naming another rev does not apply" 1 \
    "hook pins are behind" "$behind_cfg" \
    GIT_GUARDS_PINS_HELD=acme/guards@v1.0.0
check "a hold naming another repo does not apply" 1 \
    "hook pins are behind" "$behind_cfg" \
    GIT_GUARDS_PINS_HELD=acme/somewhere-else
check "a hold nobody needed is said aloud" 0 \
    "matched no behind or unchecked pin" "$current_cfg" \
    GIT_GUARDS_PINS_HELD=acme/guards@v1.3.0
check "the one-off bypass is honoured, and announces itself" 0 \
    "GIT_GUARDS_ALLOW_STALE_PINS=1 set" "$behind_cfg" \
    GIT_GUARDS_ALLOW_STALE_PINS=1

# A misspelled timeout must not quietly become the default: a configuration
# somebody believes is in force and is not is how this class of defect starts.
check "an unreadable timeout is refused, not guessed at" 2 \
    "GIT_GUARDS_PIN_TIMEOUT expects" "$current_cfg" \
    GIT_GUARDS_PIN_TIMEOUT=soon

# ── reading the config ──────────────────────────────────────────────────
# THE TRAP A REGEX FALLS INTO. `repo:` and `rev:` appear inside a local hook's
# entry and args, and a line-wise grep reads them as pins -- inventing a
# remote that does not exist and, worse, missing that the denominator is wrong.
decoy_cfg="$(config decoy <<'YAML'
repos:
  - repo: local
    hooks:
      - id: pin-lint
        name: complain about a rev
        entry: ./lint.sh --repo https://github.com/acme/not-a-pin
        args: ["--expect", "rev: v0.0.1", "- repo: https://github.com/acme/nope"]
        language: script
  - repo: https://github.com/acme/guards
    rev: v1.3.0
    hooks:
      - id: some-guard
YAML
)"
check "a rev inside a hook's args is not a pin" 0 \
    "1 remote pin(s) read, 1 compared against their upstream, 0 not checked, 1 local/meta entry skipped" "$decoy_cfg"
check "...and the invented remote is never contacted" 0 \
    '!not-a-pin' "$decoy_cfg"

quoted_cfg="$(config quoted <<'YAML'
repos:
  - repo: "https://github.com/acme/guards"
    rev: "v1.1.0"  # holding this back for now
    hooks:
      - id: some-guard
YAML
)"
check "a quoted rev with a trailing comment is read" 1 \
    "pinned v1.1.0" "$quoted_cfg"

# Covering nothing is not a clean tree, and a config that was never read is not
# a config whose pins are current.
check "a config that does not exist is refused" 2 \
    "no such file" "$work/there-is-no-such-config.yaml"

# A merge key is where the two readers would have parted company, and this pair
# is the case that caught them at it. PyYAML's `compose` does not apply merges
# -- merging happens when a loader CONSTRUCTS a mapping, and this never gets
# that far because it wants the scalars as written -- so reading past one would
# judge a pin whose rev came from a node neither reader looked at. Both stop,
# in the same place, with the same sentence.
merged_cfg="$(config merged <<'YAML'
common: &common
  rev: v1.1.0
repos:
  - repo: https://github.com/acme/guards
    <<: *common
    hooks:
      - id: some-guard
YAML
)"
check "a merge key is refused rather than half-read" 2 \
    "a merge key, which this check does not resolve" "$merged_cfg"
check "...naming the file and the line" 2 \
    "merged.yaml:" "$merged_cfg"

# The asymmetry that IS deliberate, asserted in both directions so it stays a
# decision rather than a surprise: PyYAML resolves an alias used as a value,
# and the fallback refuses it by name instead of guessing at the pin.
aliased_cfg="$(config aliased <<'YAML'
pinned: &pinned v1.1.0
repos:
  - repo: https://github.com/acme/guards
    rev: *pinned
    hooks:
      - id: some-guard
YAML
)"
check_reader narrow "an alias the fallback cannot resolve is refused" 2 \
    "an anchor or alias" "$aliased_cfg"
check_reader narrow "...and the refusal names the file and line" 2 \
    "aliased.yaml:4" "$aliased_cfg"
if [ "${#readers[@]}" -eq 2 ]; then
    check_reader pyyaml "PyYAML resolves the same alias and finds the pin" 1 \
        "pinned v1.1.0" "$aliased_cfg"
fi

tabbed_cfg="$(config tabbed <<'YAML'
repos:
  - repo: https://github.com/acme/guards
	rev: v1.1.0
YAML
)"
check_reader narrow "a tab in the indentation is refused, not guessed at" 2 \
    "a tab in the indentation" "$tabbed_cfg"

# The narrow reader's LAST branch: a line at a repos entry's own depth that is
# not a key at all. Its entire job is to stop the fallback returning a short pin
# list and calling it a clean config, which is the exact failure the two-reader
# design is built against -- and it is the only case here that reaches it, so
# replacing that `raise` with `pass` leaves the rest of the suite green. A bare
# sequence item is the shape that gets there: no colon, so no key, at the depth
# where a repos entry's keys live.
#
# Both readers refuse it, in different words and at the same line, so the shared
# assertion is the location and the specific sentences are asserted per reader.
bare_item_cfg="$(config bare-item <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
    hooks:
      - id: some-guard
  - just-a-string
YAML
)"
check "a bare sequence item at repos depth is refused, not skipped" 2 \
    "bare-item.yaml:6" "$bare_item_cfg"
check_reader narrow "...and the fallback says which line it could not read" 2 \
    "not a key this reader can read: '- just-a-string'" "$bare_item_cfg"
if [ "${#readers[@]}" -eq 2 ]; then
    check_reader pyyaml "...and PyYAML refuses the same file for the same reason" 2 \
        "a repos entry is not a mapping" "$bare_item_cfg"
fi
# The half that makes it a rule rather than a crash: the pin above it is real,
# and a reader that skipped the bad line would have found it and reported a
# clean config. Exit 2 has to win over a short answer that looks like exit 0.
check "...rather than reporting the pin it did manage to read" 2 \
    '!every pin was compared' "$bare_item_cfg"

# ── the same constructs, in the FIRST entry ─────────────────────────────
# Every refusal fixture above puts its construct on a later line, and position
# is a whole second axis. The narrow reader learns `key_column` -- the column a
# repos entry's own keys sit at -- from the first `- ` line it sees, so until one
# has been seen the column is -1 and every guard written as `indent <= key_column`
# compares against -1 and cannot fire. A first entry that is not a plain `- key:`
# line is therefore the one place a whole entry can be dropped in silence, with
# the run going on to print that every pin was compared and is current.
#
# So each case below is one of those spellings, in position one, with a pin
# inside it that is genuinely two releases behind. The negative assertion is
# the point of the exercise: a reader that drops the only entry in the file
# reports zero pins, and zero pins is a sentence that reads like success.
first_flow_cfg="$(config first-flow <<'YAML'
repos:
  - {repo: https://github.com/acme/guards, rev: v1.1.0}
YAML
)"
check_reader narrow "a flow mapping as the FIRST entry is refused, not dropped" 2 \
    "not a repos entry this reader can read" "$first_flow_cfg"
check_reader narrow "...and the refusal names the file and line" 2 \
    "first-flow.yaml:2" "$first_flow_cfg"
check_reader narrow "...and never claims the pin inside it was compared" 2 \
    '!every pin was compared' "$first_flow_cfg"
if [ "${#readers[@]}" -eq 2 ]; then
    check_reader pyyaml "PyYAML reads the same flow mapping and finds it behind" 1 \
        "pinned v1.1.0" "$first_flow_cfg"
fi

first_bare_cfg="$(config first-bare <<'YAML'
repos:
  -
    repo: https://github.com/acme/guards
    rev: v1.1.0
YAML
)"
check_reader narrow "a bare dash as the FIRST entry is refused, not dropped" 2 \
    "not a repos entry this reader can read" "$first_bare_cfg"
check_reader narrow "...and the refusal names the dash's own line" 2 \
    "first-bare.yaml:2" "$first_bare_cfg"
check_reader narrow "...and never claims the pin under it was compared" 2 \
    '!every pin was compared' "$first_bare_cfg"
if [ "${#readers[@]}" -eq 2 ]; then
    check_reader pyyaml "PyYAML reads the same bare dash and finds it behind" 1 \
        "pinned v1.1.0" "$first_bare_cfg"
fi

# A quoted key. `- "repo":` is the same mapping to YAML and not a `- key:` line
# to a reader that only knows unquoted keys, which is what makes it the
# spelling most likely to arrive from a formatter rather than from an attacker.
first_quoted_cfg="$(config first-quoted <<'YAML'
repos:
  - "repo": https://github.com/acme/guards
    rev: v1.1.0
YAML
)"
check_reader narrow "a quoted key as the FIRST entry is refused, not dropped" 2 \
    "not a repos entry this reader can read" "$first_quoted_cfg"
check_reader narrow "...and never claims the pin was compared" 2 \
    '!every pin was compared' "$first_quoted_cfg"

# The shape this takes in the wild, and the one the cases above cannot pin on
# their own: an unreadable first entry with a perfectly ordinary SECOND entry
# under it, already at its newest tag. A reader that drops the first and answers
# from the second exits 0 and prints that every pin was compared -- one pin
# short, with nothing anywhere saying so. The denominator is asserted as well as
# the exit code, because "1 remote pin(s) read" from a file holding two is the
# whole finding.
first_flow_pair_cfg="$(config first-flow-pair <<'YAML'
repos:
  - {repo: https://github.com/acme/guards, rev: v1.1.0}
  - repo: https://github.com/acme/other
    rev: v2.0.0
    hooks:
      - id: some-guard
YAML
)"
fixture https://github.com/acme/other v2.0.0
check_reader narrow "an unreadable first entry is refused even when the second reads" 2 \
    "not a repos entry this reader can read" "$first_flow_pair_cfg"
check_reader narrow "...and the run never answers from the entries it could read" 2 \
    '!every pin was compared' "$first_flow_pair_cfg"
check_reader narrow "...and never states a denominator short by one" 2 \
    '!1 remote pin(s) read' "$first_flow_pair_cfg"

# An anchor on the entry itself. The alias case above proves the fallback
# refuses an anchor it would have to resolve; this proves it refuses one it
# would merely have to step over, which is the easier one to wave through.
first_anchor_cfg="$(config first-anchor <<'YAML'
repos:
  - &guards
    repo: https://github.com/acme/guards
    rev: v1.1.0
YAML
)"
check_reader narrow "an anchored FIRST entry is refused, not dropped" 2 \
    "not a repos entry this reader can read" "$first_anchor_cfg"
check_reader narrow "...and never claims the pin was compared" 2 \
    '!every pin was compared' "$first_anchor_cfg"

# ── one file, one answer ────────────────────────────────────────────────
# Every case here is asserted with check() rather than check_reader(), which
# runs BOTH readers and requires the same exit code from each. That is the
# assertion: the file's design is that a machine with PyYAML and a machine
# without give the same verdict, and each of these is a construct where the two
# could easily part company. None of them would produce a false "current" -- they
# would produce two different right-ish answers about one file, which is the
# state that ends in somebody trusting whichever one they saw first.
#
# A duplicated key, which is the one with a real cost. YAML 1.2 calls it an
# error, PyYAML lets the LAST win, and prek refuses the file. A reader taking the
# FIRST would judge `rev: v5.0.0` above `rev: v1.0.0` as current on v5.0.0 while
# pre-commit ran v1.0.0; a reader taking the last would call the same file
# behind. Three answers. Refusing is the only one that is not wrong about
# somebody's runner.
duplicate_cfg="$(config duplicate <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v5.0.0
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"
check "a duplicated rev: is refused rather than resolved" 2 \
    "appears more than once" "$duplicate_cfg"
check "...naming the line of the second one" 2 \
    "duplicate.yaml:4" "$duplicate_cfg"
check "...and never judging the file on whichever one it picked" 2 \
    '!every pin was compared' "$duplicate_cfg"

duplicate_repo_cfg="$(config duplicate-repo <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    repo: https://github.com/acme/other
    rev: v1.3.0
YAML
)"
check "a duplicated repo: is refused too" 2 \
    "appears more than once" "$duplicate_repo_cfg"

# `repos:` with nothing under it is `repos: null`, and null is not a list. A
# fallback that walked off the end of the file would report NOTHING was verified
# at exit 0 -- the looser answer, about a config no runner would accept.
null_repos_cfg="$(config null-repos <<'YAML'
repos:
YAML
)"
check "a repos key with no list under it is refused" 2 \
    "is not a list" "$null_repos_cfg"

# And its opposite, which must NOT be refused: a repository that has declared it
# runs no hooks. This is the one flow collection the fallback reads, because
# there is nothing inside it to misread. Refusing it as flow style would be exit
# 2 on a machine without PyYAML and exit 0 on one with it.
empty_list_cfg="$(config empty-list <<'YAML'
repos: []
YAML
)"
check "an explicitly empty repos list is a config, not a refusal" 0 \
    "NOTHING was verified" "$empty_list_cfg"
check "...and is never reported as a clean comparison" 0 \
    '!every pin was compared' "$empty_list_cfg"

# An entry with no `repo:` key at all. The same silence as a first entry the
# reader cannot place, arriving by another door: close_item() returning without a
# word drops the entry from the denominator, and a config whose only entry is
# this one answers exit 0 and NOTHING was verified while PyYAML answers exit 2.
no_repo_key_cfg="$(config no-repo-key <<'YAML'
repos:
  - hooks:
      - id: some-guard
YAML
)"
check "a repos entry with no repo: is refused, not dropped" 2 \
    "has no \`repo:\`" "$no_repo_key_cfg"
check "...and never counted as nothing to verify" 2 \
    '!NOTHING was verified' "$no_repo_key_cfg"

# A duplicated key that is none of this check's business. prek refuses the file
# for a second `hooks:` exactly as it does for a second `rev:`, so a reader that
# noticed only the keys it reads would be judging a config its own runner will
# not run. Both readers scan the whole entry, so both refuse.
duplicate_other_cfg="$(config duplicate-other <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
    hooks:
      - id: one
    hooks:
      - id: two
YAML
)"
check "a duplicated key this check does not read is refused too" 2 \
    "\`hooks:\` appears more than once" "$duplicate_other_cfg"
check "...and never judged on the pin beside it" 2 \
    '!every pin was compared' "$duplicate_other_cfg"

# The same duplicate inside a `local` entry, which is where the two readers part
# company unless the whole mapping is scanned: `local` has no rev to compare, so
# a reader that looks up `rev:` only when it needs one never sees the second
# copy, calls the file clean, and answers NOTHING was verified at exit 0 about a
# config prek refuses outright.
duplicate_local_cfg="$(config duplicate-local <<'YAML'
repos:
  - repo: local
    rev: v1.0.0
    rev: v2.0.0
    hooks:
      - id: house-rule
YAML
)"
check "a duplicated key in a local entry is refused by both readers" 2 \
    "appears more than once" "$duplicate_local_cfg"
check "...and is never answered as nothing to verify" 2 \
    '!NOTHING was verified' "$duplicate_local_cfg"

# `repos: []` is read as the empty list it is, so anything indented under it is
# a list item inside a list that has already been closed -- which no YAML parser
# accepts and which a reader treating `[]` as a flag would walk straight into,
# reading the entries below as though the `[]` were not there.
empty_list_content_cfg="$(config empty-list-content <<'YAML'
repos: []
  - repo: https://github.com/acme/guards
    rev: v1.1.0
YAML
)"
check "content under an empty repos list is refused" 2 \
    '!every pin was compared' "$empty_list_content_cfg"
check_reader narrow "...and the fallback names the line and the empty list" 2 \
    "content indented under \`repos: []\`" "$empty_list_content_cfg"

# A document whose root is a sequence has no top-level key of any kind, so there
# is no `repos:` to find. Both readers say that, in the same words: it is the
# accurate sentence, and two different accurate sentences about one file is how
# a reader learns to trust whichever they saw first.
sequence_doc_cfg="$(config sequence-doc <<'YAML'
- repo: https://github.com/acme/guards
  rev: v1.1.0
YAML
)"
check "a document that is a list, not a mapping, has no repos key" 2 \
    "no top-level \`repos:\` key" "$sequence_doc_cfg"
check "...and is never reported as a pin that is behind" 2 \
    '!pinned v1.1.0' "$sequence_doc_cfg"

# ── leaving the repos block is a decision, with a line ──────────────────
# The fallback walks a config by indentation, so the moment it stops treating
# lines as repos entries is the moment it can start dropping pins in silence.
# Every case here holds a pin that is genuinely behind SOMEWHERE the reader
# might stop looking, and every one of them asserts '!every pin was compared':
# a reader that walks past an entry reports a short denominator, and a short
# denominator is what that sentence gets printed from.
fixture https://github.com/acme/downstream v2.0.0 v2.1.0

# Two top-level `repos:` keys. YAML 1.2 calls it an error and prek refuses the
# file; a reader that simply closes one block and opens another reads the pins
# of ONE of them. The behind pin is in the second, so the run that reads only
# the first exits 0 and says so.
two_repos_cfg="$(config two-repos <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
repos:
  - repo: https://github.com/acme/downstream
    rev: v2.0.0
YAML
)"
check "a second top-level repos: key is refused, not appended" 2 \
    "\`repos:\` appears more than once" "$two_repos_cfg"
check "...naming the line of the second one" 2 \
    "two-repos.yaml:4" "$two_repos_cfg"
check "...and never claiming the pins it did reach were all of them" 2 \
    '!every pin was compared' "$two_repos_cfg"

# THREE of them, because a reader that leaves the block on the second `repos:`
# line and re-enters on the third does not merely lose one list -- it ALTERNATES,
# reading the first and the third and skipping the second. The behind pin sits in
# the second, and the run reports two pins read out of a file holding three.
three_repos_cfg="$(config three-repos <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
repos:
  - repo: https://github.com/acme/downstream
    rev: v2.0.0
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
YAML
)"
check "a third top-level repos: key is refused at the second one" 2 \
    "\`repos:\` appears more than once" "$three_repos_cfg"
check "...and the alternating read never reports a verdict" 2 \
    '!every pin was compared' "$three_repos_cfg"
check "...and never states a denominator of the blocks it happened to enter" 2 \
    '!2 remote pin(s) read' "$three_repos_cfg"

# A sibling key at column zero in the MIDDLE of the list. The key ends the repos
# block -- correctly, that is what a key at column zero does -- and the entries
# under it then belong to nothing this reader is reading. Refusing names both
# lines: the pin that went unread, and the line the block ended on.
sibling_mid_cfg="$(config sibling-mid <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
default_language_version:
  python: python3
  - repo: https://github.com/acme/downstream
    rev: v2.0.0
YAML
)"
check "a pin below the repos list is refused, not skipped" 2 \
    '!every pin was compared' "$sibling_mid_cfg"
check_reader narrow "...and the fallback names the line the block ended on" 2 \
    "below the repos list, which ended at line 4" "$sibling_mid_cfg"
check_reader narrow "...and the line of the pin it did not read" 2 \
    "sibling-mid.yaml:6" "$sibling_mid_cfg"

# The same shape with a scalar sibling, because `foo: bar` and a key opening a
# mapping end the block by the same rule and a reader could easily handle one
# and not the other.
sibling_scalar_cfg="$(config sibling-scalar <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
fail_fast: true
  - repo: https://github.com/acme/downstream
    rev: v2.0.0
YAML
)"
check "a pin below a scalar sibling key is refused too" 2 \
    '!every pin was compared' "$sibling_scalar_cfg"
check_reader narrow "...naming the line the block ended on" 2 \
    "which ended at line 4" "$sibling_scalar_cfg"

# ...and the two configs that must NOT be refused by any of the above, because a
# guard that fires on an ordinary file is a guard somebody removes. A top-level
# key after the repos list is how every real config spells its defaults, and one
# of them carries a block sequence of its own at the same indentation the repos
# list used.
siblings_ok_cfg="$(config siblings-ok <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
    hooks:
      - id: some-guard
default_language_version:
  python: python3
default_stages:
  - pre-commit
  - pre-push
ci:
  autofix_prs: false
YAML
)"
check "ordinary top-level keys after the repos list are a config, not a refusal" 0 \
    "every pin was compared and is at its upstream's newest tag" "$siblings_ok_cfg"
check "...and its denominator is the one pin it holds" 0 \
    "1 remote pin(s) read, 1 compared against their upstream, 0 not checked" \
    "$siblings_ok_cfg"

# Depth, rather than position. A repos entry indented deeper than the repos list
# itself sits exactly where a `hooks:` item sits, and everything at that depth is
# deliberately none of this check's business -- which is what makes it the one
# place a whole entry can be dropped while the file still reads as ordinary. No
# hook definition has a `repo:` key, so a `- repo:` down there is a repos entry
# and nothing else.
deep_entry_cfg="$(config deep-entry <<'YAML'
repos:
- repo: https://github.com/acme/guards
  rev: v1.3.0
  - repo: https://github.com/acme/downstream
    rev: v2.0.0
YAML
)"
check "a repos entry indented deeper than the list is refused, not read as a hook" 2 \
    '!every pin was compared' "$deep_entry_cfg"
check_reader narrow "...and the fallback says which line and why" 2 \
    "deep-entry.yaml:4: a \`- repo:\` item indented deeper than the repos list" \
    "$deep_entry_cfg"
# The other half: a hooks list must still be a hooks list. The decoy case above
# proves a `rev:` inside `args:` is not a pin; this proves the guard that catches
# the entry above does not catch an ordinary hook id at the same depth.
deep_hooks_ok_cfg="$(config deep-hooks-ok <<'YAML'
repos:
- repo: https://github.com/acme/guards
  rev: v1.3.0
  hooks:
    - id: some-guard
    - id: another-guard
YAML
)"
check "a hooks list at that same depth is still a hooks list" 0 \
    "every pin was compared and is at its upstream's newest tag" "$deep_hooks_ok_cfg"

# ── a tag that leaves the pool takes the answer with it ─────────────────
# newest_tag drops a tag it cannot parse, which is right for `nightly` and wrong
# for a release somebody numbered in a scheme this file does not implement: the
# dropped tag may be the newest thing the upstream has, and every tag left is
# then older than the pin. That is exit 0 assembled from a pool the answer had
# already left -- the same shape as an undecodable tag name, arriving by
# arithmetic instead of by encoding. Each fixture below pairs the pinned version
# with exactly one newer tag, so the ONLY way to reach exit 0 is to lose it.
fixture https://github.com/acme/fourpart v1.0.0 v1.0.0.1
fourpart_cfg="$(config fourpart <<'YAML'
repos:
  - repo: https://github.com/acme/fourpart
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"
check "a fourth numeric part does not silently leave the pool" 2 \
    "written like a version" "$fourpart_cfg"
check "...naming the tag that could not be ordered" 2 \
    "'v1.0.0.1'" "$fourpart_cfg"
check "...and never reporting the pin as newest" 2 \
    '!every pin was compared' "$fourpart_cfg"

fixture https://github.com/acme/postrelease v1.0.0 v1.0.0.post1
postrelease_cfg="$(config postrelease <<'YAML'
repos:
  - repo: https://github.com/acme/postrelease
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"
check "a PEP 440 post-release does not silently leave the pool" 2 \
    "written like a version" "$postrelease_cfg"
check "...and never reports the pin as newest" 2 \
    '!every pin was compared' "$postrelease_cfg"

fixture https://github.com/acme/epoch 1.0.0 '2!1.0.0'
epoch_cfg="$(config epoch <<'YAML'
repos:
  - repo: https://github.com/acme/epoch
    rev: 1.0.0
    hooks:
      - id: some-guard
YAML
)"
check "a PEP 440 epoch does not silently leave the pool" 2 \
    "written like a version" "$epoch_cfg"
check "...and never reports the pin as newest" 2 \
    '!every pin was compared' "$epoch_cfg"

# The cost of that rule, asserted so it is a decision somebody made rather than
# a surprise somebody finds. `1.x` is written like a numeric release and is not
# one, so an upstream carrying it makes every pin against it exit 2 -- noise,
# bought at the price of never printing a clean answer from a pool with a hole
# in it, and switched off per run with the same variable as every other
# could-not-look.
fixture https://github.com/acme/branchtag v1.0.0 1.x
branchtag_cfg="$(config branchtag <<'YAML'
repos:
  - repo: https://github.com/acme/branchtag
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"
check "a branch-shaped numeric tag costs an exit 2, and says which tag" 2 \
    "'1.x'" "$branchtag_cfg"
check "...and the offline downgrade covers it like any other unchecked pin" 0 \
    "acme/branchtag" "$branchtag_cfg" GIT_GUARDS_ALLOW_UNCHECKED_PINS=1
# ...while a tag that is not written like a version at all stays a silent skip,
# which is what keeps the check usable on upstreams carrying `latest` and
# `nightly` beside their releases. The mixed fixture above asserts the same rule
# from the other side; this asserts that the new refusal did not swallow it.
check "a code-name tag beside real versions is still skipped in silence" 1 \
    "newest is v2.0.0" "$mixed_cfg"

# And the pin's own spelling. `v1.0.0.1` in a rev is not a branch and not a sha,
# and telling somebody it "is not a version" sends them looking for a mistake
# that is not in their config.
fixture https://github.com/acme/plain v1.0.0 v2.0.0
numeric_rev_cfg="$(config numeric-rev <<'YAML'
repos:
  - repo: https://github.com/acme/plain
    rev: v1.0.0.1
    hooks:
      - id: some-guard
YAML
)"
check "a rev written like a version says so, rather than 'not a version'" 2 \
    "rev 'v1.0.0.1' is written like a version" "$numeric_rev_cfg"
check "...and is not described as a branch or a commit sha" 2 \
    '!a branch or a commit sha' "$numeric_rev_cfg"

# ── a refusal that names the wrong thing ────────────────────────────────
# Exit 2 with the wrong sentence is not a false green, and it is not harmless
# either: it sends somebody to fix a file that is not broken, and it means the
# two readers disagree about what they are looking at. Each case below is a
# construct PyYAML reads without complaint, so the fallback agreeing with it --
# rather than refusing it under some other name -- is the answer.
#
# A byte order mark. Ordinary on a Windows checkout, invisible in every editor,
# and it decodes to one character in front of `repos:`.
bom_cfg="$work/bom.yaml"
{
    printf '\357\273\277repos:\n'
    printf '  - repo: https://github.com/acme/guards\n'
    printf '    rev: v1.1.0\n'
    printf '    hooks:\n'
    printf '      - id: some-guard\n'
} > "$bom_cfg"
check "a byte order mark is read, not reported as a missing repos key" 1 \
    "pinned v1.1.0" "$bom_cfg"
check "...and the file is never said to have no repos key" 1 \
    '!no top-level' "$bom_cfg"

# A %YAML directive above the document marker. It says which version of YAML the
# file is written in, PyYAML reads it and the document under it, and calling that
# document a SECOND document is both wrong and the one refusal most likely to
# hide a real one.
directive_cfg="$work/directive.yaml"
{
    printf '%%YAML 1.2\n'
    printf -- '---\n'
    printf 'repos:\n'
    printf '  - repo: https://github.com/acme/guards\n'
    printf '    rev: v1.1.0\n'
} > "$directive_cfg"
check "a YAML directive is not a second document" 1 \
    "pinned v1.1.0" "$directive_cfg"
check "...and is never reported as one" 1 \
    '!more than one document' "$directive_cfg"

# An explicit tag on the rev. PyYAML resolves `!!str v1.1.0` to the string
# v1.1.0, as prek does; the fallback does not resolve tags at all. The asymmetry
# is the same one the alias case makes and is asserted the same way -- what must
# not survive is the fallback comparing the TAG along with the version and
# reporting an ordinary pin as a rev that is not a version.
explicit_tag_cfg="$(config explicit-tag <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: !!str v1.1.0
    hooks:
      - id: some-guard
YAML
)"
check_reader narrow "an explicit tag the fallback cannot resolve is refused by name" 2 \
    "an explicit tag, which this reader does not resolve" "$explicit_tag_cfg"
check_reader narrow "...and is never called a rev that is not a version" 2 \
    '!is not a version' "$explicit_tag_cfg"
if [ "${#readers[@]}" -eq 2 ]; then
    check_reader pyyaml "PyYAML resolves the same tag and finds the pin behind" 1 \
        "pinned v1.1.0" "$explicit_tag_cfg"
fi

# ── text that is not UTF-8 ──────────────────────────────────────────────
# Three places where bytes this process did not choose are decoded, and every
# one of them ends the same way if it is decoded carelessly: a UnicodeDecodeError
# escaping as a traceback and exit 1. Exit 1 is this module's word for BEHIND, so
# each would announce a stale pin about something it had never read -- the single
# confusion the three exit codes exist to prevent. Every case here asserts exit 2
# AND that the message names what could not be read.
#
# The bytes are CP932, written as octal escapes: a Shift_JIS config is ordinary
# on a Japanese Windows checkout, and git's messages are localised, so neither
# of these is a contrived input.
sjis_cfg="$work/sjis.yaml"
{
    printf 'repos:\n'
    printf '  - repo: https://github.com/acme/guards\n'
    printf '    rev: v1.3.0  # \223\372\226\173\214\352\n'
    printf '    hooks:\n'
    printf '      - id: some-guard\n'
} > "$sjis_cfg"
check "a config that is not UTF-8 cannot be read, and says so" 2 \
    "sjis.yaml: cannot read" "$sjis_cfg"
check "...and is never reported as a pin that is behind" 2 \
    '!pinned v' "$sjis_cfg"

# A tag name is whatever the upstream's author typed, and `text=True` decodes
# stdout as UTF-8. One tag, unreadable, is an upstream this check cannot place
# in a version order -- which is exit 2 with its own sentence, not a traceback.
fixture https://github.com/acme/mojibake-tag "$(printf 'v1.0.0-\223\372\226\173')"
mojibake_tag_cfg="$(config mojibake-tag <<'YAML'
repos:
  - repo: https://github.com/acme/mojibake-tag
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"
check "a tag name that is not UTF-8 is unchecked, not behind" 2 \
    "acme/mojibake-tag" "$mojibake_tag_cfg"
check "...and the reason is that the newest tag cannot be established" 2 \
    "did not decode as UTF-8" "$mojibake_tag_cfg"

# The same undecodable tag with READABLE tags beside it, which is the case a
# per-tag rule gets wrong. `errors="replace"` leaves U+FFFD in the name, the name
# then fails to parse as a version and drops out of the pool -- and when the tag
# that dropped out is the NEWEST one, every tag left is older than the pin and
# the run reports it at its upstream's newest tag. Exit 0, assembled out of bytes
# nobody read. The tags here are ordered so that the one that vanishes is the
# only one that could have made the pin behind.
fixture https://github.com/acme/mojibake-newest \
    v1.0.0 v1.1.0 "$(printf 'v2.0.0-\223\372\226\173')"
mojibake_newest_cfg="$(config mojibake-newest <<'YAML'
repos:
  - repo: https://github.com/acme/mojibake-newest
    rev: v1.1.0
    hooks:
      - id: some-guard
YAML
)"
check "an undecodable tag beside readable ones is still unchecked" 2 \
    "acme/mojibake-newest" "$mojibake_newest_cfg"
check "...naming what could not be read" 2 \
    "did not decode as UTF-8" "$mojibake_newest_cfg"
check "...and never claiming the pin is current" 2 \
    '!every pin was compared' "$mojibake_newest_cfg"

# A lone 0xFF, which is not valid in any UTF-8 sequence at all, on the newest
# tag of three. Same shape, different bytes, because the CP932 case above could
# be read as being about one locale.
fixture https://github.com/acme/mojibake-byte \
    v1.0.0 v2.0.0 "$(printf 'v3.0.0\377')"
mojibake_byte_cfg="$(config mojibake-byte <<'YAML'
repos:
  - repo: https://github.com/acme/mojibake-byte
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"
check "a single undecodable byte on the newest tag is unchecked" 2 \
    "did not decode as UTF-8" "$mojibake_byte_cfg"
check "...and is not reported as behind the newest tag that did decode" 2 \
    '!newest is v2.0.0' "$mojibake_byte_cfg"

# git's stderr, under a locale that is not UTF-8. This is the one that needs no
# unusual repository at all: any `fatal:` line on a CP932 machine is these
# bytes, so an unreachable remote -- already a defined exit 2 -- crashed instead.
error_fixture https://github.com/acme/mojibake-stderr <<STDERR
$(printf 'fatal: \223\372\226\173\214\352 https://github.com/acme/mojibake-stderr\n')
STDERR
mojibake_stderr_cfg="$(config mojibake-stderr <<'YAML'
repos:
  - repo: https://github.com/acme/mojibake-stderr
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML
)"
check "git stderr that is not UTF-8 is an unreachable remote, not a crash" 2 \
    "remote unreachable" "$mojibake_stderr_cfg"
check "...and the finding names the remote" 2 \
    "acme/mojibake-stderr" "$mojibake_stderr_cfg"

# ── finding the config with no argument ─────────────────────────────────
# The runner passes no filenames (see .pre-commit-hooks.yaml), so the hook has
# to find the config itself -- from the top of the work tree, not from wherever
# the caller happens to stand. A subdirectory is where that goes wrong: reading
# ./.pre-commit-config.yaml would find nothing and, without this, report
# nothing wrong.
project="$work/project"
mkdir -p "$project/deep/nested"
"$REAL_GIT" init -q "$project"
cat > "$project/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.1.0
    hooks:
      - id: some-guard
YAML

for reader in "${readers[@]}"; do
    status=0
    output="$(cd "$project/deep/nested" && env PYTHONPATH="$(reader_path "$reader")" \
        python3 "$guard" 2>&1)" || status=$?
    if [ "$status" -eq 1 ] && [[ "$output" == *"acme/guards"* ]]; then
        printf 'ok   [%s] %s\n' "$reader" "with no argument, the config is found from the work tree root"
    else
        printf 'FAIL [%s] %s (expected exit 1 naming the pin, got %s)\n%s\n' \
            "$reader" "with no argument, the config is found from the work tree root" \
            "$status" "$output"
        failures=$((failures + 1))
    fi
done

# The third patched decoding site, and the only one with no failing-direction
# case: `git rev-parse --show-toplevel`'s stderr, which is read when the hook is
# handed no filename at all. Under a CP932 locale a `fatal: not a git
# repository` line is not UTF-8, so `text=True` raised inside the very call
# whose job is to fall back to the current directory -- a traceback and exit 1
# out of the path that exists to keep going. A directory that is not a
# repository at all is how it is reached without a Japanese locale on the
# machine: the stub answers rev-parse with those exact bytes.
cat > "$stub_bin/git" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "rev-parse" ] && [ "\${2:-}" = "--show-toplevel" ]; then
    printf 'fatal: \223\372\226\173\214\352\n' >&2
    exit 128
fi
exec "\$REAL_GIT" "\$@"
STUB
chmod +x "$stub_bin/git"
export PATH="$stub_bin:$original_path"

nowhere="$work/nowhere"
mkdir -p "$nowhere"
for reader in "${readers[@]}"; do
    status=0
    output="$(cd "$nowhere" && env PYTHONPATH="$(reader_path "$reader")" \
        python3 "$guard" 2>&1)" || status=$?
    # Both halves matter, and the second is the one the guarded exit would
    # otherwise hide: since every unforeseen exception now lands on exit 2, a
    # crash here would report the same NUMBER as the fallback working. So the
    # assertion is that the run reached the ordinary "no such config" answer,
    # and that it did not arrive there through the catch-all.
    if [ "$status" -eq 2 ] && [[ "$output" == *"no such file"* ]] &&
        [[ "$output" != *"the check itself failed"* ]]; then
        printf 'ok   [%s] %s\n' "$reader" \
            "rev-parse stderr that is not UTF-8 falls back instead of crashing"
    else
        printf 'FAIL [%s] %s (expected exit 2 naming the missing config, got %s)\n%s\n' \
            "$reader" "rev-parse stderr that is not UTF-8 falls back instead of crashing" \
            "$status" "$output"
        failures=$((failures + 1))
    fi
done
install_git_stub

# ── the whole work tree, not the top of it ──────────────────────────────
# prek is a workspace runner: it discovers and runs a nested
# .pre-commit-config.yaml under a subdirectory, so a check that opens only the
# root config has a denominator missing every pin below it -- and prints "every
# pin was compared" about the ones it did open. The fixture is built so that
# only the nested config is behind: a run that reads the root and stops exits 0
# and says everything is current, which is the exact sentence this whole file
# exists to stop being printed from a short list.
mono="$work/mono"
mkdir -p "$mono/sub" "$mono/untracked-sub" "$mono/ignored-sub" "$mono/deep/nested"
"$REAL_GIT" init -q "$mono"
cat > "$mono/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
    hooks:
      - id: some-guard
YAML
cat > "$mono/sub/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: https://github.com/acme/downstream
    rev: v2.0.0
    hooks:
      - id: some-guard
YAML
printf 'ignored-sub/\n' > "$mono/.gitignore"
"$REAL_GIT" -C "$mono" add -A >/dev/null 2>&1
# Added after the commit, and never staged: prek runs a config that exists,
# whether or not anybody has committed it yet.
cat > "$mono/untracked-sub/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: https://github.com/acme/lexical
    rev: v1.7.9
    hooks:
      - id: some-guard
YAML
# And the config the sweep does NOT reach, so the limit the run prints is a
# measured boundary rather than a phrase. Its pin is behind by two releases, and
# the assertions below say both halves out loud: it is not read, and the run
# never claims to have covered it.
cat > "$mono/ignored-sub/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: https://github.com/acme/candidate
    rev: v1.0.0
    hooks:
      - id: some-guard
YAML

sweep_case() {
    local name="$1" from="$2" expected="$3" needle="$4"
    local reader status output matched
    for reader in "${readers[@]}"; do
        status=0
        output="$(cd "$from" && env PYTHONPATH="$(reader_path "$reader")" \
            python3 "$guard" 2>&1)" || status=$?
        matched=no
        if [ "${needle:0:1}" = "!" ]; then
            [[ "$output" != *"${needle:1}"* ]] && matched=yes
        else
            [[ "$output" == *"$needle"* ]] && matched=yes
        fi
        if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
            printf 'ok   [%s] %s\n' "$reader" "$name"
            continue
        fi
        printf 'FAIL [%s] %s (expected exit %s matching %q, got %s)\n%s\n' \
            "$reader" "$name" "$expected" "$needle" "$status" "$output"
        failures=$((failures + 1))
    done
}

sweep_case "a nested config is read with no argument, and its pin is refused" \
    "$mono/deep/nested" 1 "acme/downstream"
sweep_case "...naming the nested file the pin is written in" \
    "$mono/deep/nested" 1 "sub/.pre-commit-config.yaml:3"
sweep_case "...and never answering from the root config alone" \
    "$mono/deep/nested" 1 '!every pin was compared'
sweep_case "...and the run names the nested config among the files it read" \
    "$mono/deep/nested" 1 "read $mono/sub/.pre-commit-config.yaml"
sweep_case "...and the root config too, so the scope is the whole list" \
    "$mono/deep/nested" 1 "read $mono/.pre-commit-config.yaml"
# An untracked config is one somebody added this morning, and prek runs it. Its
# pin is behind as well, so a sweep that saw only committed files would report a
# denominator short by one and never say which one.
sweep_case "an untracked nested config is swept too" \
    "$mono/deep/nested" 1 "untracked-sub/.pre-commit-config.yaml"
sweep_case "...and all three configs are counted" \
    "$mono/deep/nested" 1 "3 remote pin(s) read, 3 compared against their upstream"

# What the sweep cannot reach, said out loud rather than assumed. An ignored
# directory is the standing limit; a directory that is not a work tree at all is
# the one where the sweep does not happen, and where a list of one config would
# otherwise look exactly like a list of one config from a sweep that worked.
sweep_case "the standing limit of the sweep is printed beside what it read" \
    "$mono/deep/nested" 1 "not swept -- an ignored path"
sweep_case "...and the config inside the ignored path is genuinely not read" \
    "$mono/deep/nested" 1 '!ignored-sub/.pre-commit-config.yaml'

outside="$work/outside-any-repo"
mkdir -p "$outside"
cat > "$outside/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: https://github.com/acme/guards
    rev: v1.3.0
    hooks:
      - id: some-guard
YAML
sweep_case "outside a work tree the run says the sweep could not happen" \
    "$outside" 0 "could not be listed"
sweep_case "...and still reports the config it did read" \
    "$outside" 0 "every pin was compared and is at its upstream's newest tag"

# ── an exception nobody predicted ───────────────────────────────────────
# The three cases above name three call sites that decode bytes carefully -- a
# config that is not UTF-8, a tag name that is not UTF-8, git's stderr under a
# CP932 locale -- and three careful call sites are not a rule. Python's default
# for an uncaught exception is exit 1, and 1 is this module's word for BEHIND, so
# ANY unforeseen failure would announce a stale pin about something it never read.
#
# `yaml.compose` raises RecursionError on a document nested past the
# interpreter's limit, and RecursionError is not a yaml.YAMLError, so the handler
# wrapped around that call does not see it. The depths are chosen from the
# measurement: 400 reaches the ordinary YAML error path, and 600 unwinds past
# every handler in the module. Both must be exit 2, and for the narrow reader
# neither is remarkable -- it does not recurse -- which is why the sentence is
# asserted against the PyYAML lane where the crash lives.
deep_ok="$work/deep-400.yaml"
deep_crash="$work/deep-600.yaml"
python3 -c 'import sys; open(sys.argv[1],"w").write("repos: "+"["*400+"]"*400+"\n")' "$deep_ok"
python3 -c 'import sys; open(sys.argv[1],"w").write("repos: "+"["*600+"]"*600+"\n")' "$deep_crash"

check "a document nested past the YAML limit is unchecked, not behind" 2 \
    '!every pin was compared' "$deep_ok"
check "a document nested past the INTERPRETER limit is unchecked, not behind" 2 \
    '!every pin was compared' "$deep_crash"
if [ "${#readers[@]}" -eq 2 ]; then
    check_reader pyyaml "...and the run says the check itself failed" 2 \
        "the check itself failed" "$deep_crash"
fi

# ── the network lane ────────────────────────────────────────────────────
# A fixture proves the fixture parses. These two prove the wiring: a real
# `git ls-remote` against a real public repository, once in each direction.
export PATH="$original_path"
live_repo="https://github.com/pre-commit/pre-commit-hooks"

if GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "$live_repo" >/dev/null 2>&1; then
    old_cfg="$(config live-old <<YAML
repos:
  - repo: $live_repo
    rev: v4.0.0
    hooks:
      - id: trailing-whitespace
YAML
)"
    status=0
    output="$(python3 "$guard" "$old_cfg" 2>&1)" || status=$?
    if [ "$status" -eq 1 ] &&
        [[ "$output" == *"$live_repo"* ]] && [[ "$output" == *"pinned v4.0.0"* ]]; then
        printf 'ok   [live] %s\n' "a real repository pinned to an old tag is refused"
    else
        printf 'FAIL [live] %s (expected exit 1, got %s)\n%s\n' \
            "a real repository pinned to an old tag is refused" "$status" "$output"
        failures=$((failures + 1))
    fi

    # The newest tag is taken from the run above rather than hard-coded: an
    # assertion naming today's version would start failing the day the upstream
    # tags, which is a test that measures the calendar.
    newest="$(printf '%s\n' "$output" | sed -n 's/.*newest is \(.*\)$/\1/p' | head -n1)"
    if [ -z "$newest" ]; then
        printf 'FAIL [live] %s\n' "the refusal did not name an available version"
        failures=$((failures + 1))
    else
        new_cfg="$(config live-new <<YAML
repos:
  - repo: $live_repo
    rev: $newest
    hooks:
      - id: trailing-whitespace
YAML
)"
        status=0
        output="$(python3 "$guard" "$new_cfg" 2>&1)" || status=$?
        if [ "$status" -eq 0 ] &&
            [[ "$output" == *"every pin was compared and is at its upstream's newest tag"* ]]; then
            printf 'ok   [live] %s (%s)\n' \
                "the same repository pinned to that tag passes" "$newest"
        else
            printf 'FAIL [live] %s (expected exit 0, got %s)\n%s\n' \
                "the same repository pinned to that tag passes" "$status" "$output"
            failures=$((failures + 1))
        fi
    fi

    # A real remote that does not exist, over the real network, with no stub in
    # the way. This is also the hang test: git must not stop to ask for a
    # username, so the guard forces GIT_TERMINAL_PROMPT=0 -- and if it ever
    # stops doing that, this case blocks forever instead of passing.
    gone_cfg="$(config live-gone <<'YAML'
repos:
  - repo: https://github.com/pre-commit/there-is-no-repository-by-this-name
    rev: v1.0.0
    hooks:
      - id: trailing-whitespace
YAML
)"
    status=0
    output="$(python3 "$guard" "$gone_cfg" 2>&1)" || status=$?
    if [ "$status" -eq 2 ] && [[ "$output" == *"remote unreachable"* ]]; then
        printf 'ok   [live] %s\n' "a real unreachable remote exits 2 without prompting"
    else
        printf 'FAIL [live] %s (expected exit 2, got %s)\n%s\n' \
            "a real unreachable remote exits 2 without prompting" "$status" "$output"
        failures=$((failures + 1))
    fi
else
    # Loudly, and counted. A skipped case that prints nothing is a green run
    # claiming coverage it does not have.
    printf 'SKIP the network lane: %s could not be reached\n' "$live_repo"
    printf '     the stub lane above covers the same outcomes offline\n'
    skipped=$((skipped + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%s test(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nall no-stale-hook-pins tests passed (readers: %s, %s lane(s) skipped)\n' \
    "${readers[*]}" "$skipped"
