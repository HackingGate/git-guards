#!/usr/bin/env python3
r"""Refuse a hook pin that is behind its upstream's newest tag.

A `rev:` in .pre-commit-config.yaml is a version, and it is the only version of
a shared guard that a repository actually runs. Nothing in the hook runner ever
asks whether it is the CURRENT one: pre-commit and prek fetch exactly what the
pin names, cache the checkout by rev, and report a clean run. From every local
surface, a pin two releases behind and a pin written this morning are the same
green tick.

What used to watch them was a dependency updater, and the way it stopped
watching is the reason this file exists. Its release-cooldown filter is ON BY
DEFAULT, so with no cooldown configured anywhere it still applied one: the
updater saw the newer version, discarded it, kept the old one, and wrote all
four facts into a job log --

    Available release version/ref is 1.3.0
    Applying cooldown filter for <the hook repo>
    Filtered 1 version(s) due to cooldown ... no eligible version found
    All candidate versions are in cooldown, keeping current version 1.1.0
    Latest version is 1.1.0

-- where the last line is a plain untruth about the world, and the only place
any of it appears is a log nobody opens. No pull request was raised, so no
surface anywhere said anything. Dozens of repositories sat two versions behind
for weeks while every dashboard said healthy.

The lesson is not "configure the updater". It is that the only check anybody
believed in could not say no, and reported success while holding the answer. So
this one lives beside the pins, is run by the same runner as the guards it
watches, and its whole job is to exit non-zero and name the pin.

## What it refuses, and what it merely cannot answer

Three outcomes, never folded together:

  exit 0  every remote pin was compared against its upstream and is current
  exit 1  at least one pin is BEHIND -- the finding, with both versions named
  exit 2  at least one pin could not be checked at all

Exit 2 is the one that matters most here. A remote that timed out, a repository
with no tags, a rev that is a branch name or a commit sha and therefore has no
place in a version order -- none of those is evidence that the pin is current,
and a check that answered 0 for them would be reproducing, in fewer lines, the
"Latest version is 1.1.0" it was written to replace. Cannot look is not up to
date. `GIT_GUARDS_ALLOW_UNCHECKED_PINS=1` downgrades exit 2 to a printed note,
for the offline case, and it is a thing somebody types on purpose.

A confirmed finding outranks an unresolved one: a run that is both behind and
unable to reach some other remote exits 1, because 1 is the more specific
answer and losing it would be the worse trade.

## Why it does not cache

The obvious optimisation -- remember each upstream's newest tag for a day -- is
the exact mechanism this hook exists to correct. A cooldown, a TTL and a cache
are the same idea, and the failure they share is that the stale answer is
indistinguishable from a fresh one at the point where somebody reads it. This
runs at pre-push and manual, not on every commit, so it can afford to ask.

Within a single run each URL is asked once, because a config naming the same
upstream twice is one question, not two.

## Why Python and not shell

The other guards here are shell, and this one would be a worse shell script for
two reasons that are both about being honest rather than about being tidy:

  * Version order is not string order. `git ls-remote` returns tags in
    lexicographic order, where v1.7.9 sorts after v1.7.12 -- so the naive shell
    answer is not merely imprecise, it is wrong in the direction that reports a
    behind pin as current. `sort -V` fixes that on GNU coreutils and does not
    exist on BSD sort, which is what a macOS consumer has.
  * A `rev:` is one line of YAML, and grepping for `^\s*rev:` reads a `rev:`
    inside a hook's `args:`, inside a `local` hook's `entry:`, and inside a
    comment. The parse has to know the STRUCTURE it is looking at, and a regex
    that does not is a check whose denominator nobody can state.

python3 is already a dependency of this repo (prevent-unusual-unicode-in-files.py
is a registered hook), so this introduces nothing new.

## How the YAML is read

PyYAML when it is importable, because pre-commit is itself a Python program
that reads this very file with PyYAML: agreeing with the tool whose config it
is means using the tool's own parser. Specifically `yaml.compose`, which keeps
the source line of every node -- so a finding names a file and a line -- and
returns the scalar as WRITTEN, so `rev: 1.0` is compared as the string the file
holds rather than as the float a loader would build from it.

PyYAML is not guaranteed: a `language: script` hook runs under the system
interpreter, with no environment created for it. So there is a fallback reader,
and it is deliberately narrow. It understands the shape a .pre-commit-config.yaml
actually has -- a `repos:` sequence of mappings -- and REFUSES, by name and line
number, anything it does not model: anchors, aliases, merge keys, explicit tags,
flow style, block scalars, tabs, a second document. A reader that guesses would
be a second rule that agrees with the first until it does not; a reader that
stops and says so is exit 2, which is already a defined outcome here.

The one thing that reader may never do is stop reading QUIETLY, because a pin it
walked past is a pin missing from a denominator nobody can see is short. So
every way out of the `repos:` block is a line it can name. The block ends where
a key at column zero begins, that line is remembered, and past it a `repo:` or a
`rev:` is a pin outside the list this reader read -- a refusal, naming both
lines, rather than a skip. The same rule governs depth: a `- repo:` item
indented deeper than the repos list itself is a repos entry wearing a hook's
indentation, and it is refused rather than counted as somebody's `hooks:` list.

A duplicated key is refused by both readers wherever either of them walks: a
second `repos:` at the top level, a second `rev:` in one entry. YAML 1.2 calls
it an error, PyYAML lets the last one win, prek refuses the file outright, and
there is no way to be right about all three, so the file is unreadable rather
than judged.

The two must agree, and the tests run every fixture through both to say so.

Usage:
  no-stale-hook-pins.py [CONFIG ...]

With no argument it reads EVERY .pre-commit-config.yaml in the current work
tree, not just the one at the top of it. prek is a workspace runner: it
discovers and runs a nested config under a subdirectory, so a pin that is behind
in `sub/.pre-commit-config.yaml` is a pin a run that opened only the root config
never looked at, and "every pin was compared" would be a sentence about a
denominator that quietly excluded it. The sweep is `git ls-files`, which reaches
tracked files, untracked files git is not ignoring, and submodule contents. It
does not reach a config inside an ignored directory, and it cannot run at all
outside a work tree -- both of which the run says out loud beside the list of
files it read, because a sweep that fell back to one file and did not mention it
is the same false denominator by another route.

Naming configs as arguments reads exactly those instead. It takes no file list
from the runner on purpose: see the hook registration in .pre-commit-hooks.yaml.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import traceback
from pathlib import Path
from typing import TYPE_CHECKING, NamedTuple

if TYPE_CHECKING:
    from collections.abc import Iterable, Iterator, Sequence

try:
    import yaml
except ImportError:  # see the module docstring: the fallback reader takes over
    yaml = None  # type: ignore[assignment]

TOOL = "no-stale-hook-pins"

DEFAULT_CONFIG = ".pre-commit-config.yaml"

#: `local` and `meta` are pre-commit's two non-remote repos. They hold no
#: version to be behind on, so they are skipped -- and COUNTED, because a config
#: that is all local entries has verified nothing and must say so rather than
#: printing the same "all current" a real check prints.
NON_REMOTE_REPOS = frozenset({"local", "meta"})

#: Seconds for one `git ls-remote`. A hook that hangs is a hook that gets
#: uninstalled, and an unbounded network call in a pre-push hook is a hang
#: waiting for a bad day.
DEFAULT_TIMEOUT_SECONDS = 20.0

EXIT_OK = 0
EXIT_BEHIND = 1
EXIT_UNCHECKED = 2

#: A tag that names a version: an optional `v`, one to three numeric parts, and
#: semver's optional prerelease and build metadata. Everything else -- `latest`,
#: `nightly`, `release-2024`, a signing key's tag -- is not a version and is
#: skipped rather than being an error, because upstreams carry those alongside
#: their releases and crashing on one would make the check unusable on exactly
#: the repositories that have the most tags.
VERSION_RE = re.compile(
    r"""^v?
        (?P<major>\d+)
        (?:\.(?P<minor>\d+))?
        (?:\.(?P<patch>\d+))?
        (?:-(?P<pre>[0-9A-Za-z.-]+))?
        (?:\+[0-9A-Za-z.-]+)?
        $""",
    re.VERBOSE,
)

#: A tag WRITTEN like a numeric release, whether or not VERSION_RE can order it.
#: The two together are the whole point: skipping a tag is safe when the tag is
#: `nightly`, and unsafe when it is `v1.0.0.1`, because the second one may be the
#: newest thing the upstream has. A tag that matches this and not VERSION_RE is
#: therefore not dropped from the pool -- it stops the comparison, because a
#: newest tag cannot be established from a list with a hole where its top was.
#:
#: It admits a PEP 440 epoch (`2!1.0.0`), a fourth numeric part (`v1.0.0.1`) and
#: a suffix after the release triple (`v1.0.0.post1`, `v2.0.0.RELEASE`): three
#: real spellings, none of which semver orders, all of which sort ABOVE the pin
#: in the only ordering their author had in mind.
#:
#: The cost, stated so it is a decision rather than a surprise: a tag such as
#: `1.x` is written like a numeric release and is not one, so an upstream
#: carrying it makes every pin against that upstream exit 2 until somebody sets
#: GIT_GUARDS_ALLOW_UNCHECKED_PINS=1. That is noise, and the alternative is a
#: silent exit 0 assembled from a pool the newest tag had already left.
NUMERIC_TAG_RE = re.compile(r"^v?(?:\d+!)?\d+(?:\.\d+)*(?:[.+_-][0-9A-Za-z.+_!-]*)?$")


class Version(NamedTuple):
    """A semver ordering key. Field order IS the comparison order.

    `stable` sits between the release triple and the prerelease identifiers
    because semver orders a prerelease BEFORE the release it leads to:
    1.3.0-rc.1 < 1.3.0. Encoding that as 0 < 1 in a tuple field means the whole
    comparison is Python's own tuple comparison, with nothing to get wrong in a
    hand-written __lt__.
    """

    release: tuple[int, int, int]
    stable: int
    prerelease: tuple[tuple[int, int, str], ...]

    def describe(self) -> str:
        return ".".join(str(part) for part in self.release)


def prerelease_id(part: str) -> tuple[int, int, str]:
    """One dot-separated prerelease identifier, as an ordering key.

    Semver: numeric identifiers compare numerically, alphanumeric ones compare
    in ASCII order, and numeric always sorts below alphanumeric. `isascii` is
    part of the test because `str.isdigit` is true for digits that `int` will
    happily parse and no upstream ever tagged with.
    """
    if part.isascii() and part.isdigit():
        return (0, int(part), "")
    return (1, 0, part)


def written_like_a_version(tag: str) -> bool:
    """Does this tag LOOK like a numeric release, whether or not it parses?

    The question separates the two reasons parse_version returns None. A tag
    this says no to is a code name, and dropping it loses nothing. A tag this
    says yes to is a release somebody numbered, in a scheme this file does not
    implement -- and dropping that one silently is how a run reports a pin as
    current against a pool the newest release had already left.
    """
    return NUMERIC_TAG_RE.match(tag.strip()) is not None


def parse_version(tag: str) -> Version | None:
    """A tag as a version, or None when the tag does not name one."""
    matched = VERSION_RE.match(tag.strip())
    if matched is None:
        return None
    release = (
        int(matched.group("major")),
        int(matched.group("minor") or 0),
        int(matched.group("patch") or 0),
    )
    pre = matched.group("pre")
    if pre is None:
        return Version(release=release, stable=1, prerelease=())
    return Version(
        release=release,
        stable=0,
        prerelease=tuple(prerelease_id(part) for part in pre.split(".")),
    )


def newest_tag(tags: Iterable[str], spelled_like: str = "") -> tuple[str, Version] | None:
    """The highest version among these tags, or None if none names a version.

    Prereleases are candidates only when there is no stable release at all. An
    upstream that tags an rc is not asking every consumer onto it, and a check
    that demanded the move would be one people switch off -- but an upstream
    that has ONLY ever tagged prereleases still has a newest one, and reporting
    "no versions here" for it would be a false clean answer.

    The known cost of that rule, stated here so it is a decision rather than a
    surprise: semver reads everything after a hyphen as a prerelease, and a
    Debian-style revision suffix is spelled the same way. An upstream tagging
    `v3.15.0-1` is releasing, not proposing, and this reads it as a prerelease.
    While EVERY tag carries a suffix the fallback saves it -- there is no stable
    pool, so the whole set competes and the newest wins -- but one bare tag
    appearing beside them flips the pool to stable-only and the suffixed
    releases stop being candidates. Measured, with tags v3.13.0-1, v3.13.1-1,
    v3.14.0 and v3.15.0-1: a pin of v3.14.0 is judged current. The alternative
    is to guess which hyphen means what, and a check that guesses about the
    version order is the thing this file exists to replace, so the answer is to
    say what it does.

    `spelled_like` is the rev currently written in the config, and it decides
    only which of several equal spellings to print: an upstream carrying both
    `1.3.0` and `v1.3.0` should be reported using the form the file already
    uses, because the message is meant to be pasted back into the file.
    """
    parsed = [(tag, version) for tag in tags if (version := parse_version(tag))]
    if not parsed:
        return None
    stable = [entry for entry in parsed if entry[1].stable]
    pool = stable or parsed
    best = max(version for _, version in pool)
    equals = [tag for tag, version in pool if version == best]
    prefixed = spelled_like.startswith("v")
    for tag in equals:
        if tag.startswith("v") == prefixed:
            return (tag, best)
    return (equals[0], best)


class ConfigUnreadable(Exception):
    """The config could not be read as a set of pins.

    Never a pass. A file this could not parse is a file whose pins were not
    checked, which is exit 2 like every other way of not knowing.
    """


class Pin(NamedTuple):
    """One `- repo:` / `rev:` pair, and where it is written."""

    url: str
    rev: str
    path: str
    line: int

    def where(self) -> str:
        return f"{self.path}:{self.line}"

    def slug(self) -> str:
        """`owner/repo`, for matching a declared hold and for shorter output.

        Falls back to the URL itself when it does not have that shape -- a
        self-hosted path can be deeper, and a hold that silently matched the
        wrong repository would be worse than one that has to be spelled in
        full.
        """
        trimmed = self.url.rstrip("/")
        if trimmed.endswith(".git"):
            trimmed = trimmed[: -len(".git")]
        parts = trimmed.split("/")
        if len(parts) >= 2 and parts[-1] and parts[-2]:
            return f"{parts[-2]}/{parts[-1]}"
        return self.url


# --- reading the config -------------------------------------------------------


def read_pins(path: Path) -> tuple[list[Pin], int]:
    """Every remote pin in one config, and the number of local/meta entries.

    The second half of that pair is the denominator: a config whose entries are
    all `local` has nothing to compare, and the difference between "checked
    four and they are current" and "checked none" has to survive into the
    output.
    """
    try:
        text = path.read_text(encoding="utf-8")
        # A byte order mark decodes to U+FEFF and stays at the head of the text,
        # where it belongs to neither reader's idea of a first line. PyYAML skips
        # it and reads the file; the narrow reader would see a first character
        # that is not a key character, fail to match `repos:`, and report no
        # top-level `repos:` key about a file that plainly has one -- a refusal
        # naming the wrong thing, and a second answer about one file. Dropping it
        # here is what makes the two readers agree, and it costs no line number:
        # a BOM occupies no line of its own.
        text = text.removeprefix("\ufeff")
    except (OSError, UnicodeDecodeError) as exc:
        # UnicodeDecodeError is caught here BY NAME because it is a ValueError
        # rather than an OSError, so it escapes the obvious `except OSError` and
        # leaves through main() as a traceback and exit 1 -- and 1 is this
        # module's word for BEHIND. A config saved in Shift_JIS would therefore
        # be reported as a pin that is behind its upstream when nothing was read
        # at all, which is the one confusion the three exit codes exist to
        # prevent. Cannot read is cannot look, and cannot look is exit 2.
        raise ConfigUnreadable(f"{path}: cannot read ({exc})") from exc

    if yaml is not None:
        return pins_via_pyyaml(text, str(path))
    return pins_via_narrow_reader(text, str(path))


def pins_via_pyyaml(text: str, path: str) -> tuple[list[Pin], int]:
    """The parser pre-commit itself reads this file with.

    `compose` rather than `safe_load`, for two reasons that both show up in the
    output: every node carries its source line, so a finding is clickable; and
    a scalar arrives as the text the file holds, so `rev: 1.0` is compared as
    `1.0` rather than as the float 1.0 that a loader would construct and then
    print back as `1.0` while meaning something else.
    """
    try:
        root = yaml.compose(text)
    except yaml.YAMLError as exc:
        raise ConfigUnreadable(f"{path}: not valid YAML ({exc})") from exc
    if root is None:
        raise ConfigUnreadable(f"{path}: empty document")

    # A document whose root is anything but a mapping has no top-level key at
    # all, and saying exactly that is what the fallback reader says about the
    # same file. Reaching mapping_keys with it would answer the same question in
    # different words.
    if not isinstance(root, yaml.MappingNode):
        raise ConfigUnreadable(f"{path}: no top-level `repos:` key")
    repos = mapping_keys(root, path).get("repos")
    if repos is None:
        raise ConfigUnreadable(f"{path}: no top-level `repos:` key")
    if not isinstance(repos, yaml.SequenceNode):
        raise ConfigUnreadable(f"{path}: `repos:` is not a list")

    pins: list[Pin] = []
    non_remote = 0
    for item in repos.value:
        if not isinstance(item, yaml.MappingNode):
            raise ConfigUnreadable(
                f"{path}:{item.start_mark.line + 1}: a repos entry is not a mapping"
            )
        # A merge key is the one construct `compose` does NOT resolve: merging
        # happens when a loader CONSTRUCTS a mapping, and this never gets that
        # far because it wants the scalars as written. Reading past one would
        # judge a pin whose rev came from a node this call never looked at, so
        # it stops here -- and stops in the same place, with the same sentence,
        # as the fallback reader that cannot resolve one either. It is asked
        # BEFORE the duplicate scan below so that a merge key written twice is
        # reported as the merge key it is, on the line the other reader stops on.
        merge = first_key_line(item, "<<")
        if merge:
            raise ConfigUnreadable(
                f"{path}:{merge}: a merge key, which this check does not resolve"
            )
        keys = mapping_keys(item, path)
        repo_node = keys.get("repo")
        if repo_node is None or not isinstance(repo_node, yaml.ScalarNode):
            raise ConfigUnreadable(
                f"{path}:{item.start_mark.line + 1}: a repos entry has no `repo:`"
            )
        url = repo_node.value.strip()
        if url in NON_REMOTE_REPOS:
            non_remote += 1
            continue
        rev_node = keys.get("rev")
        if rev_node is None or not isinstance(rev_node, yaml.ScalarNode):
            raise ConfigUnreadable(
                f"{path}:{repo_node.start_mark.line + 1}: {url} has no `rev:`"
            )
        pins.append(
            Pin(
                url=url,
                rev=rev_node.value.strip(),
                path=path,
                line=rev_node.start_mark.line + 1,
            )
        )
    return pins, non_remote


def first_key_line(node, key: str) -> int:
    """The source line of `key` in this mapping, or 0. No duplicate opinion."""
    for key_node, _ in node.value:
        if isinstance(key_node, yaml.ScalarNode) and key_node.value == key:
            return key_node.start_mark.line + 1
    return 0


def mapping_keys(node, path: str) -> dict[str, object]:
    """Every key of one mapping, by name. A duplicated key is refused.

    Refused rather than resolved, because there is no answer to resolve it to.
    YAML 1.2 calls a duplicated key an error outright. PyYAML -- what pre-commit
    actually runs -- accepts it and lets the LAST one win. prek refuses the file.
    A reader taking the FIRST would agree with nobody: `rev: v5.0.0` above
    `rev: v1.0.0` would be judged on v5.0.0, reported as at its upstream's newest
    tag, and run by pre-commit on v1.0.0. Picking any side makes this check right
    about one runner and wrong about another. So the file is unreadable: exit 2,
    naming the line, which is a verdict somebody can act on by deleting one of
    the two lines, and which is what the runner a consumer is most likely to have
    does with the same file.

    The whole mapping is scanned rather than the two or three keys this check
    cares about, so that the answer does not depend on WHICH key was duplicated.
    A `hooks:` written twice is the same error as a `rev:` written twice, prek
    refuses the file for either, and a reader that noticed only the second would
    be judging a file its own runner would not run. The mappings scanned are the
    ones this check walks -- the document root, and each repos entry -- which is
    also exactly what the fallback reader can see, so the two agree about which
    duplicates they are entitled to have an opinion on.

    A key that is not a plain scalar is refused for the same reason the fallback
    refuses one: it cannot be named, so it cannot be compared, so it cannot be
    counted.
    """
    keys: dict[str, object] = {}
    for key_node, value_node in node.value:
        if not isinstance(key_node, yaml.ScalarNode):
            raise ConfigUnreadable(
                f"{path}:{key_node.start_mark.line + 1}: a key that is not a "
                "plain scalar, which this check does not read"
            )
        if key_node.value in keys:
            raise ConfigUnreadable(
                f"{path}:{key_node.start_mark.line + 1}: `{key_node.value}:` "
                "appears more than once in one mapping, and the runners disagree "
                "about which one wins"
            )
        keys[key_node.value] = value_node
    return keys


#: A `key:` line, optionally opening a sequence item. Deliberately not a general
#: YAML tokeniser: it is paired with an indentation walk that decides which of
#: these lines are top-level keys of a repos entry, and the two together are
#: what stop `rev:` inside a hook's `args:` from being read as a pin.
NARROW_KEY_RE = re.compile(
    r"^(?P<indent>[ ]*)(?P<dash>-[ ]+)?(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)[ ]*:(?P<rest>.*)$"
)


def pins_via_narrow_reader(text: str, path: str) -> tuple[list[Pin], int]:
    """The fallback for an interpreter with no PyYAML.

    It models one shape -- a `repos:` sequence whose items are mappings -- and
    refuses everything else by name and line number. That refusal is the whole
    design: the alternative to a narrow reader is not a wide one, it is a
    reader that quietly returns the pins it happened to recognise, and a
    denominator that is silently short is how a check reports a clean result
    for lines it never looked at.

    Three pieces of state carry that rule, and they are the reason the walk is
    not just an indentation test. `in_repos` says whether the lines arriving now
    are entries of the repos list. `repos_ended_at` remembers the line where they
    stopped being that, so leaving the list is a decision with a location rather
    than a flag flipping in silence -- and a `repo:` or `rev:` arriving after it
    is a pin outside the list this reader read, which is a refusal that can name
    both lines. `top_level_keys` holds the keys already seen at column zero, so a
    second `repos:` is the duplicate it is instead of a fresh block that replaces
    the first one, or is dropped, depending on how many there were.
    """
    pins: list[Pin] = []
    non_remote = 0
    seen_content = False
    top_level_keys: dict[str, int] = {}
    in_repos = False
    repos_seen = False
    repos_seen_line = 0
    repos_is_an_empty_list = False
    repos_ended_at = 0
    entries = 0
    dash_indent = -1
    key_column = -1
    entry_keys: dict[str, int] = {}
    item_url = ""
    item_rev = ""
    item_rev_line = 0
    item_open = False
    item_line = 0

    def close_item() -> None:
        nonlocal non_remote, item_open, item_url, item_rev, item_rev_line
        if not item_open:
            return
        item_open = False
        if not item_url:
            # An entry with no `repo:` at all. Returning quietly here would drop
            # the entry from the denominator without a word, and a config whose
            # only entry is this one would answer exit 0 and "NOTHING was
            # verified" while PyYAML refuses the same file with the same
            # complaint this line makes.
            raise ConfigUnreadable(f"{path}:{item_line}: a repos entry has no `repo:`")
        if item_url in NON_REMOTE_REPOS:
            non_remote += 1
        elif not item_rev:
            raise ConfigUnreadable(f"{path}: {item_url} has no `rev:`")
        else:
            pins.append(
                Pin(url=item_url, rev=item_rev, path=path, line=item_rev_line)
            )
        item_url = ""
        item_rev = ""
        item_rev_line = 0

    for number, raw in enumerate(text.split("\n"), start=1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if raw[: len(raw) - len(raw.lstrip())].count("\t"):
            raise ConfigUnreadable(f"{path}:{number}: a tab in the indentation")
        if stripped in {"---", "..."}:
            # A document marker before any content is the harmless one. After
            # content it means a second document, which this reader does not
            # model -- and a config whose second document holds the pins would
            # otherwise be reported as having none.
            if seen_content:
                raise ConfigUnreadable(f"{path}:{number}: more than one document")
            continue
        if stripped.startswith("%") and not seen_content:
            # A directive, which may only appear above the first `---`. It is
            # skipped rather than refused because PyYAML reads a file carrying
            # one and finds the pins in it, and a fallback that called the same
            # file unreadable would be the two readers disagreeing about a
            # perfectly ordinary document. The one directive that could change
            # what a value MEANS is `%TAG`, which redefines a tag handle -- and a
            # value carrying an explicit tag is refused by scalar_of below, so a
            # redefined handle has no way to reach a pin this reader accepts.
            continue

        indent = len(raw) - len(raw.lstrip(" "))
        matched = NARROW_KEY_RE.match(raw)
        is_item = bool(matched and matched.group("dash"))

        if not seen_content and (stripped == "-" or stripped.startswith("- ")):
            # A document whose first content is a sequence item has no top-level
            # key at all, so there is no `repos:` to find. Said here, in PyYAML's
            # words for the same file, rather than left to the refusals below
            # which would describe the same document differently.
            raise ConfigUnreadable(f"{path}: no top-level `repos:` key")
        seen_content = True

        if in_repos and not (indent == 0 and not is_item):
            # --- inside the repos block ---
            if repos_is_an_empty_list:
                raise ConfigUnreadable(
                    f"{path}:{number}: content indented under `repos: []`, which "
                    "is an empty list"
                )
            # `key_column` is the column a repos entry's own keys sit at, learned
            # from the first `- ` line. Until one has been seen it is -1, so every
            # guard below written as `indent <= key_column` compares against -1
            # and cannot fire -- which is why the first entry is checked here,
            # explicitly, instead of relying on them. A flow mapping
            # `- {repo: ..., rev: ...}`, a bare `-` with the mapping on the lines
            # below it, a quoted `- "repo":`, an anchor `- &name`: each is a real
            # spelling of a real first entry, and each is a pin. A reader that
            # refuses a construct on line 5 and accepts it on line 2 is not
            # narrow, it is unpredictable.
            if key_column == -1 and not is_item:
                raise ConfigUnreadable(
                    f"{path}:{number}: not a repos entry this reader can read: "
                    f"{stripped!r}"
                )

            if is_item:
                if dash_indent == -1:
                    dash_indent = indent
                    key_column = indent + len(matched.group("dash"))
                if indent == dash_indent:
                    close_item()
                    item_open = True
                    item_line = number
                    entry_keys = {}
                    entries += 1
                elif indent < dash_indent:
                    raise ConfigUnreadable(
                        f"{path}:{number}: a list item left of the repos list"
                    )
                elif matched.group("key") == "repo":
                    # A repos entry wearing a hook's indentation. Everything
                    # deeper than the repos list is somebody's `hooks:` and none
                    # of this check's business -- except a `- repo:`, which no
                    # hook definition has and which is the one shape that makes
                    # this branch drop a pin. PyYAML refuses the same file; a
                    # `continue` here would read the entries above it and print
                    # that every pin was compared.
                    raise ConfigUnreadable(
                        f"{path}:{number}: a `- repo:` item indented deeper than "
                        f"the repos list, which begins at line {repos_seen_line} "
                        "-- a repos entry this reader would otherwise read as a "
                        "hook"
                    )
                else:
                    # A nested item -- the hooks list. Not a repos entry.
                    continue
            elif not matched:
                # A continuation line, a flow collection, a block scalar body:
                # not something this reader can place. Deeper than a repos
                # entry's own keys it belongs to `hooks:` and is none of this
                # check's business, which is also where the PyYAML path stops
                # looking -- the two readers refusing in different places would
                # be a reader difference that reaches the exit code.
                if indent <= key_column and stripped.lstrip("- ").startswith("<<"):
                    raise ConfigUnreadable(
                        f"{path}:{number}: a merge key, which this check does not resolve"
                    )
                if indent <= key_column:
                    raise ConfigUnreadable(
                        f"{path}:{number}: not a key this reader can read: {stripped!r}"
                    )
                continue
            elif indent != key_column:
                # Deeper than a repos entry's own keys, so it belongs to `hooks:`
                # or below. This is the line that a grep for `rev:` gets wrong.
                continue

            if not item_open:
                continue
            key = matched.group("key")
            # Every key of the entry is remembered, not only the two this check
            # reads, because mapping_keys refuses a duplicate anywhere in the
            # same mapping and the two readers have to answer alike. Assignment
            # alone would let a second `rev:` overwrite the first in silence
            # while PyYAML refused the file: three answers about one document.
            if key in entry_keys:
                raise ConfigUnreadable(
                    f"{path}:{number}: `{key}:` appears more than once in one "
                    "mapping, and the runners disagree about which one wins"
                )
            entry_keys[key] = number
            if key not in {"repo", "rev"}:
                continue
            value = scalar_of(matched.group("rest"), path, number)
            if not value:
                raise ConfigUnreadable(
                    f"{path}:{number}: `{key}:` has no value on its line"
                )
            if key == "repo":
                item_url = value
            else:
                item_rev = value
                item_rev_line = number
            continue

        if in_repos:
            # A key at column zero, so the repos list stops here -- on a line
            # this reader can name, which is the whole point of remembering it.
            close_item()
            in_repos = False
            repos_ended_at = number

        # --- outside the repos block ---
        if repos_ended_at and matched and matched.group("key") in {"repo", "rev"}:
            # A pin below the list this reader finished reading. It is either a
            # second repos list or a file no YAML parser accepts, and in both
            # cases it is a `rev:` that went unread while the run held a verdict
            # about the ones above it. Only checked AFTER the list has ended: the
            # anchor idiom puts a `rev:` under some other top-level key BEFORE
            # `repos:`, and that one is a template refused where it is used, at
            # the merge key, rather than where it is written.
            raise ConfigUnreadable(
                f"{path}:{number}: a `{matched.group('key')}:` line below the "
                f"repos list, which ended at line {repos_ended_at}"
            )

        if matched and indent == 0 and not is_item:
            key = matched.group("key")
            # The document root is a mapping too, and mapping_keys refuses a
            # duplicated key in it. A second `repos:` is the case that pays for
            # this: without it the branch above would simply close the first
            # block and open a second, so a file with two lists reports the pins
            # of one of them and a file with three reports the first and the
            # third -- exit 0 either way, with the missing entries named nowhere.
            if key in top_level_keys:
                raise ConfigUnreadable(
                    f"{path}:{number}: `{key}:` appears more than once in one "
                    "mapping, and the runners disagree about which one wins"
                )
            top_level_keys[key] = number
            if key == "repos":
                repos_seen = True
                repos_seen_line = number
                # `repos: []` is the one flow collection this reader reads, and
                # the reason is that there is nothing inside it to misread. It
                # is a real config -- a repository that has declared it runs no
                # hooks -- and PyYAML answers exit 0 with "NOTHING was verified"
                # for it. Refusing it here would be the two readers giving
                # different answers about one file, which is the thing this
                # fallback's design exists to make impossible.
                if empty_flow_sequence(matched.group("rest")):
                    repos_is_an_empty_list = True
                    in_repos = True
                    continue
                if scalar_of(matched.group("rest"), path, number):
                    raise ConfigUnreadable(
                        f"{path}:{number}: `repos:` is not a block sequence"
                    )
                in_repos = True
            continue

    close_item()
    if not repos_seen:
        raise ConfigUnreadable(f"{path}: no top-level `repos:` key")
    # `repos:` with nothing under it is `repos: null`, and null is not a list,
    # which is what PyYAML says about the same file. `repos: []` is the one shape
    # that genuinely IS an empty list, and it is admitted above rather than
    # counted here.
    if entries == 0 and not repos_is_an_empty_list:
        raise ConfigUnreadable(f"{path}: `repos:` is not a list")
    return pins, non_remote


def empty_flow_sequence(rest: str) -> bool:
    """Is the value written after `repos:` an explicitly empty list?

    Separate from scalar_of because scalar_of refuses every flow collection,
    which is the right rule for a value that could hold a pin and the wrong one
    for the two characters that cannot hold anything.
    """
    text = rest.strip()
    cut = text.find(" #")
    if cut != -1:
        text = text[:cut].strip()
    return text == "[]"


def scalar_of(rest: str, path: str, number: int) -> str:
    """The value written after `key:` on one line.

    Quoted or bare, with a trailing comment removed. Anything that continues
    onto another line, or that is not a plain scalar at all, is refused: this
    reader's job is to be right about the lines it accepts and loud about the
    rest.
    """
    text = rest.strip()
    if not text or text.startswith("#"):
        return ""
    first = text[0]
    if first in "|>":
        raise ConfigUnreadable(f"{path}:{number}: a block scalar, which this reader does not read")
    if first in "{[":
        raise ConfigUnreadable(f"{path}:{number}: flow style, which this reader does not read")
    if first in "&*":
        raise ConfigUnreadable(
            f"{path}:{number}: an anchor or alias, which this reader does not resolve"
        )
    if first == "!":
        # An explicit tag. `rev: !!str v1.0.0` is the string v1.0.0 to PyYAML and
        # to prek; taking the line verbatim would compare the tag along with the
        # version and report `!!str v1.0.0` as a rev that is not a version --
        # a refusal that names the wrong thing about a pin that is perfectly
        # ordinary. Stripping the tag instead would be guessing at a construct
        # this reader does not implement, which is the anchor's answer and is
        # this one's too.
        raise ConfigUnreadable(
            f"{path}:{number}: an explicit tag, which this reader does not resolve"
        )
    if first in "\"'":
        closing = text.find(first, 1)
        if closing == -1:
            raise ConfigUnreadable(f"{path}:{number}: an unterminated quoted value")
        tail = text[closing + 1 :].strip()
        if tail and not tail.startswith("#"):
            raise ConfigUnreadable(f"{path}:{number}: trailing text after a quoted value")
        return text[1:closing]
    # A bare scalar ends at ` #`, which is YAML's comment rule: a `#` that is
    # not preceded by a space is part of the value, and a rev may hold one.
    cut = text.find(" #")
    if cut != -1:
        text = text[:cut]
    return text.strip()


# --- asking the upstream ------------------------------------------------------


class RemoteUnreachable(Exception):
    """`git ls-remote` did not answer. Never folded into "no newer tag"."""


def remote_tags(url: str, timeout: float) -> list[str]:
    """Every tag the upstream has, by name.

    Two things in the environment are not left to chance. GIT_TERMINAL_PROMPT=0
    because a private or misspelled URL otherwise asks for a username on a
    terminal that a hook runner may not even have attached, and a guard that
    hangs at push time is a guard that gets uninstalled that afternoon. The ssh
    batch flag is set the same way and for the same reason, and only when the
    caller has not already said what ssh to use.

    `errors="replace"` because `text=True` decodes as UTF-8 and RAISES on
    anything else, and both streams here can carry bytes this process did not
    choose. A tag name is whatever the upstream's author typed, and git's stderr
    is localised -- a `fatal:` message under a CP932 locale is not UTF-8. Either
    would otherwise raise UnicodeDecodeError out of subprocess.run, escape as a
    traceback, and exit 1: this module's word for a pin that is BEHIND, announced
    about a remote that was never read. A mangled character in a `fatal:` line is
    a worse diagnostic than the original and an infinitely better one than a
    traceback.

    On stdout it costs something, and the tag loop below pays it. A tag name that
    did not decode comes back with U+FFFD in it, fails to parse as a version, and
    is dropped from the pool -- so if the NEWEST tag is the one that did not
    decode, every remaining tag is older than the pin and the run says the pin is
    at its upstream's newest tag. That is exit 0 built out of bytes nobody read,
    which is the single outcome this whole module is arranged against. Cannot
    read the tags is cannot look, and cannot look is exit 2.
    """
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env.setdefault("GIT_SSH_COMMAND", "ssh -oBatchMode=yes")
    try:
        done = subprocess.run(
            ["git", "ls-remote", "--tags", "--refs", "--", url],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            env=env,
            check=True,
        )
    except subprocess.TimeoutExpired:
        raise RemoteUnreachable(f"no answer within {timeout:g}s") from None
    except subprocess.CalledProcessError as exc:
        raise RemoteUnreachable(first_line(exc.stderr) or f"git exited {exc.returncode}") from None
    except OSError as exc:
        raise RemoteUnreachable(f"could not run git ({exc})") from None

    tags = []
    for line in done.stdout.split("\n"):
        _, _, ref = line.partition("refs/tags/")
        if not ref:
            continue
        # `--refs` already drops the peeled form; strip it anyway, because an
        # older git without that flag's behaviour would otherwise hand back
        # `v1.2.3^{}` and the version parser would refuse a tag that exists.
        tags.append(ref.removesuffix("^{}").strip())
    # U+FFFD is what `errors="replace"` leaves behind, and there is no other way
    # for it to reach here: a tag name that genuinely contained a replacement
    # character would have to have been pushed as one, which no version scheme
    # does. Refusing the WHOLE remote rather than the one tag is deliberate --
    # the question this function answers is "what is the newest tag", and a
    # newest tag cannot be established from a list with a hole in it. Dropping
    # the undecodable one and answering from the rest is exactly how the run
    # ends up saying a pin is current because the tag above it was unreadable.
    if any("�" in tag for tag in tags):
        raise RemoteUnreachable(
            "a tag name did not decode as UTF-8, so the newest tag here cannot "
            "be established"
        )
    return tags


def first_line(text: str) -> str:
    for line in (text or "").split("\n"):
        if line.strip():
            return line.strip()
    return ""


# --- deciding -----------------------------------------------------------------


class Verdict(NamedTuple):
    """One pin, judged.

    A declared hold is a separate field rather than a fourth state, so the
    count of pins that were actually COMPARED against their upstream survives
    it. Folding "held" into the state would leave the denominator unable to
    tell a held pin that was compared and found behind from a held pin whose
    remote never answered, and that distinction is the whole subject here.
    """

    pin: Pin
    state: str
    detail: str
    held: Hold | None = None


BEHIND = "behind"
CURRENT = "current"
UNCHECKED = "unchecked"


def judge(pin: Pin, tags: list[str]) -> Verdict:
    """Compare one pin against its upstream's tags.

    Every branch that is not "behind" and not "current" ends in UNCHECKED, and
    each carries its own sentence. They are genuinely different situations --
    an upstream with no tags at all, an upstream whose tags are dates or code
    names, a rev that is a commit sha, a rev naming a tag the upstream no
    longer has -- and a reader who is told only "could not check" has to go and
    find out which, so the check may as well say.
    """
    if not tags:
        return Verdict(pin, UNCHECKED, "the upstream has no tags at all")

    # A tag numbered in a scheme this file does not order is checked BEFORE
    # anything is compared, because it invalidates the pool rather than one
    # entry in it. The undecodable-tag rule in remote_tags is the same rule
    # about a different cause: the newest tag cannot be established from a list
    # whose top may be the item that was skipped, and answering from what is
    # left is exit 0 built out of tags nobody ordered.
    unorderable = [tag for tag in tags if parse_version(tag) is None and written_like_a_version(tag)]
    if unorderable:
        return Verdict(
            pin,
            UNCHECKED,
            f"the upstream tag {unorderable[0]!r} is written like a version and is "
            "not one this check can order, so the newest tag here cannot be "
            "established",
        )

    pinned = parse_version(pin.rev)
    if pinned is None:
        if written_like_a_version(pin.rev):
            # Distinguished from the branch-or-sha sentence below because the
            # two ask different things of the reader. A sha is a deliberate pin
            # this check simply cannot order; a rev written like a release is a
            # version whose scheme this file does not implement, and saying "not
            # a version" about `v1.0.0.1` sends somebody looking for a mistake
            # that is not in their config.
            return Verdict(
                pin,
                UNCHECKED,
                f"rev {pin.rev!r} is written like a version and is not one this "
                "check can order, so it has no place in a version order",
            )
        return Verdict(
            pin,
            UNCHECKED,
            f"rev {pin.rev!r} is not a version, so it has no place in a version "
            "order (a branch or a commit sha pins fine and cannot be compared)",
        )

    latest = newest_tag(tags, spelled_like=pin.rev)
    if latest is None:
        return Verdict(
            pin,
            UNCHECKED,
            f"none of the upstream's {len(tags)} tag(s) names a version",
        )

    tag_text, tag_version = latest
    if any(parse_version(tag) == pinned for tag in tags):
        if pinned < tag_version:
            return Verdict(pin, BEHIND, tag_text)
        return Verdict(pin, CURRENT, tag_text)

    # The pin parses as a version, and the upstream does not have it. A deleted
    # tag, a typo, or a tag that only exists on somebody's laptop -- and in all
    # three the runner is fetching something other than what the file appears
    # to promise.
    return Verdict(
        pin,
        UNCHECKED,
        f"the upstream has no tag {pin.rev!r} (its newest is {tag_text})",
    )


# --- declared exceptions ------------------------------------------------------


class Hold(NamedTuple):
    """A pin somebody has decided, on purpose, not to move.

    Spelled `owner/repo` or `owner/repo@rev`, in GIT_GUARDS_PINS_HELD. The
    second form is the one worth writing: a hold pinned to the version it was
    granted for expires by itself the moment the pin moves, while a bare
    `owner/repo` is an exemption with no end date, which is how a temporary
    decision becomes a permanent one nobody remembers making.
    """

    who: str
    rev: str

    def matches(self, pin: Pin) -> bool:
        who = self.who.lower()
        if who not in {pin.slug().lower(), pin.url.lower(), pin.url.lower().rstrip("/")}:
            return False
        return not self.rev or self.rev == pin.rev

    def describe(self) -> str:
        return f"{self.who}@{self.rev}" if self.rev else self.who


def declared_holds() -> list[Hold]:
    holds = []
    for token in os.environ.get("GIT_GUARDS_PINS_HELD", "").replace(",", " ").split():
        who, _, rev = token.partition("@")
        if who:
            holds.append(Hold(who=who, rev=rev))
    return holds


def timeout_seconds() -> float:
    """The per-remote timeout, and a refusal rather than a guess if it is junk.

    A misspelled timeout that silently became the default is a configuration
    somebody believes is in force and is not.
    """
    raw = os.environ.get("GIT_GUARDS_PIN_TIMEOUT", "").strip()
    if not raw:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        value = 0.0
    if value <= 0:
        # Exit 2, not 1: a configuration this could not read is a run that
        # checked nothing, which is the same answer as a remote that did not
        # reply -- and it must not share an exit code with a pin that IS behind.
        print(
            f"error: {TOOL}: GIT_GUARDS_PIN_TIMEOUT expects a positive number of "
            f"seconds, got {raw!r}",
            file=sys.stderr,
        )
        raise SystemExit(EXIT_UNCHECKED)
    return value


# --- the run ------------------------------------------------------------------


class Scope(NamedTuple):
    """The configs a run read, and what its sweep for them could not reach.

    The second field is not decoration. Every sentence this check prints is a
    claim about the first field, and a list of one file assembled because the
    sweep failed looks exactly like a list of one file assembled because there
    is one file. `limit` is how the difference reaches the reader.
    """

    paths: list[Path]
    limit: str


def work_tree_root() -> Path:
    """The top of the work tree, or the current directory when git cannot say.

    `errors="replace"` for the same reason as in remote_tags: git's stderr is
    localised, and under a CP932 locale a `fatal: not a git repository` line is
    not UTF-8. `text=True` would raise decoding it, out through a call whose
    whole purpose is to fall back to the current directory when git cannot
    answer -- a traceback and exit 1 instead of a fallback and a real check.
    """
    try:
        done = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            errors="replace",
            check=True,
        )
        return Path(done.stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        return Path.cwd()


def swept_configs(root: Path) -> tuple[list[Path], str]:
    """Every .pre-commit-config.yaml git can see in this work tree.

    Two listings, because one command does not cover the ground. `--cached
    --others --exclude-standard` reaches tracked files and untracked files git
    is not ignoring -- a nested config added this morning and not yet committed
    is still a config prek runs. `--recurse-submodules` reaches into submodules,
    which the first listing reports only as a gitlink, and which is a place
    pre-commit consumers routinely keep a second config. The union is taken
    because reading a config twice costs one parse and missing one costs the
    denominator.

    Names are matched in Python rather than by pathspec: `*/.pre-commit-config.yaml`
    depends on whether git's matcher lets `*` cross a slash, which varies with
    how the pathspec was spelled, and a sweep that silently matched nothing is
    the failure this whole function exists to prevent.

    The second half of the return value says what was NOT swept, and it is empty
    only when both listings answered.
    """
    found: list[Path] = []
    limits: list[str] = []
    for arguments, unreached in (
        (["--cached", "--others", "--exclude-standard"], "this work tree"),
        (["--recurse-submodules"], "the submodules of this work tree"),
    ):
        try:
            done = subprocess.run(
                ["git", "-C", str(root), "ls-files", "-z", *arguments],
                capture_output=True,
                text=True,
                errors="replace",
                check=True,
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            reason = first_line(getattr(exc, "stderr", "") or "") or first_line(str(exc))
            limits.append(f"{unreached} could not be listed ({reason})")
            continue
        for name in done.stdout.split("\0"):
            if not name or Path(name).name != DEFAULT_CONFIG:
                continue
            candidate = root / name
            if candidate.is_file() and candidate not in found:
                found.append(candidate)
    return found, "; ".join(limits)


def config_scope(argv: Sequence[str]) -> Scope:
    """The configs to read: the ones named, else every one in the work tree.

    prek is a workspace runner. It discovers and runs a nested
    .pre-commit-config.yaml under a subdirectory, inside a nested independent
    repository, and inside a submodule, so a pin that is behind in
    `sub/.pre-commit-config.yaml` is a pin a run that opened only the root config
    never looked at -- and "every pin was compared" would be a sentence whose
    denominator quietly excluded it. So the default is a sweep, not a file.

    The root config is listed first and unconditionally, so that a work tree with
    no config at all still reports the file it expected to find rather than
    reporting nothing, and so the ordinary case reads in the order a person
    expects.

    What the sweep does not reach is carried back rather than dropped: a config
    inside an ignored directory, and every config anywhere when git cannot list
    the tree at all. Both are printed beside the files that WERE read.
    """
    if argv:
        return Scope([Path(item) for item in argv], "")
    root = work_tree_root()
    root_config = root / DEFAULT_CONFIG
    paths = [root_config] if root_config.is_file() else []
    swept, limit = swept_configs(root)
    for candidate in swept:
        if candidate not in paths:
            paths.append(candidate)
    if not paths:
        # Nothing found anywhere. The run still names the file it went looking
        # for, so "no such file" is a sentence about a path somebody can check
        # rather than about an empty list.
        paths = [root_config]
    if not limit:
        limit = "an ignored path is not swept, and is not run by a hook runner either"
    return Scope(paths, limit)


def collect(paths: Iterable[Path]) -> Iterator[tuple[list[Pin], int]]:
    for path in paths:
        if not path.is_file():
            raise ConfigUnreadable(
                f"{path}: no such file -- refusing to report pins current from a "
                "config that was never read"
            )
        yield read_pins(path)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv

    if os.environ.get("GIT_GUARDS_ALLOW_STALE_PINS") == "1":
        print(
            f"warning: {TOOL}: GIT_GUARDS_ALLOW_STALE_PINS=1 set; pins not checked",
            file=sys.stderr,
        )
        return EXIT_OK

    timeout = timeout_seconds()
    holds = declared_holds()

    pins: list[Pin] = []
    non_remote = 0
    scope = config_scope(argv)
    try:
        for found, skipped in collect(scope.paths):
            pins.extend(found)
            non_remote += skipped
    except ConfigUnreadable as exc:
        print(f"error: {TOOL}: {exc}", file=sys.stderr)
        print(
            "A config that could not be read is a config whose pins were not "
            "checked, which is not the same as pins that are current.",
            file=sys.stderr,
        )
        return EXIT_UNCHECKED

    verdicts: list[Verdict] = []
    used_holds: set[Hold] = set()
    # One question per URL, within this run only. See the docstring on why there
    # is no cache that outlives it.
    answers: dict[str, list[str] | RemoteUnreachable] = {}
    for pin in pins:
        held = next((hold for hold in holds if hold.matches(pin)), None)
        if pin.url not in answers:
            try:
                answers[pin.url] = remote_tags(pin.url, timeout)
            except RemoteUnreachable as exc:
                answers[pin.url] = exc
        answer = answers[pin.url]
        if isinstance(answer, RemoteUnreachable):
            verdict = Verdict(pin, UNCHECKED, f"remote unreachable: {answer}")
        else:
            verdict = judge(pin, answer)
        if held is not None and verdict.state != CURRENT:
            used_holds.add(held)
            verdict = verdict._replace(held=held)
        verdicts.append(verdict)

    return report(verdicts, non_remote, holds, used_holds, scope)


def report(
    verdicts: list[Verdict],
    non_remote: int,
    holds: list[Hold],
    used_holds: set[Hold],
    scope: Scope,
) -> int:
    behind = [item for item in verdicts if item.state == BEHIND and item.held is None]
    unchecked = [item for item in verdicts if item.state == UNCHECKED and item.held is None]
    held = [item for item in verdicts if item.held is not None]
    # What was actually compared against an upstream, which is not the same as
    # what was read out of the config. A held pin still counts as compared:
    # somebody decided about it, and the check knows what it decided about.
    compared = sum(1 for item in verdicts if item.state in {BEHIND, CURRENT})
    could_not = sum(1 for item in verdicts if item.state == UNCHECKED)
    allow_unchecked = os.environ.get("GIT_GUARDS_ALLOW_UNCHECKED_PINS") == "1"

    if behind:
        print("error: hook pins are behind their upstream's newest tag", file=sys.stderr)
        print("", file=sys.stderr)
        for item in behind:
            print(f"  {item.pin.where()}: {item.pin.url}", file=sys.stderr)
            print(
                f"      pinned {item.pin.rev}, newest is {item.detail}",
                file=sys.stderr,
            )
        print("", file=sys.stderr)
        print(
            "A rev is the only version of a shared hook this repository actually "
            "runs, and nothing else here ever asks whether it is the current one.",
            file=sys.stderr,
        )
        print(
            "Bump the rev, or declare the hold where somebody reads it: "
            "GIT_GUARDS_PINS_HELD=owner/repo@rev.",
            file=sys.stderr,
        )
        print(
            "GIT_GUARDS_ALLOW_STALE_PINS=1 is a deliberate one-off bypass.",
            file=sys.stderr,
        )

    if unchecked:
        label = "note" if allow_unchecked else "error"
        print("", file=sys.stderr)
        print(
            f"{label}: {len(unchecked)} pin(s) could not be checked at all",
            file=sys.stderr,
        )
        for item in unchecked:
            print(f"  {item.pin.where()}: {item.pin.url}", file=sys.stderr)
            print(f"      pinned {item.pin.rev} -- {item.detail}", file=sys.stderr)
        if not allow_unchecked:
            print("", file=sys.stderr)
            print(
                "Not being able to look is not the same as being up to date -- "
                "reporting success here is the exact failure this check exists to "
                "end. Set GIT_GUARDS_ALLOW_UNCHECKED_PINS=1 to make this a note "
                "(offline, or a rev this check cannot order).",
                file=sys.stderr,
            )

    # What was READ, named, before what was found. Every sentence below is a
    # claim about these files and about nothing else, and the files are not
    # obvious: prek is a workspace runner and will happily run a nested
    # .pre-commit-config.yaml under a subdirectory or inside a submodule. "Every
    # pin was compared" printed on its own invites the reader to supply their own
    # scope for it.
    for path in scope.paths:
        print(f"{TOOL}: read {path}")
    if scope.limit:
        # And what the search for those files could not reach. A list of one
        # config because the sweep failed reads identically to a list of one
        # config because there is one, and the difference is a whole denominator.
        print(f"{TOOL}: not swept -- {scope.limit}")

    # The denominator, always, on success and on failure alike, and spelled as
    # three numbers rather than one. A checker that prints only findings cannot
    # be told apart from one that examined nothing -- and a single count of
    # "pins checked" would call a remote that never answered checked, which is
    # the precise word this whole hook exists to stop being used loosely.
    found = len(verdicts)
    print(
        f"{TOOL}: {found} remote pin(s) read, {compared} compared against their "
        f"upstream, {could_not} not checked, {non_remote} local/meta "
        f"entr{'y' if non_remote == 1 else 'ies'} skipped"
    )
    if found == 0:
        print(
            f"{TOOL}: NOTHING was verified -- there is no remote pin here to be "
            "behind on"
        )
    elif not behind and not unchecked and not held:
        # The sentence that claims something, kept apart from the counts that
        # state the denominator. It is printed only when every pin read was
        # compared against its upstream and came back level, so neither a run
        # that examined nothing nor one carrying a declared hold can emit it.
        print(f"{TOOL}: every pin was compared and is at its upstream's newest tag")
    for item in held:
        # What is being held back FROM, not merely that something is held: an
        # exemption printed without the version it is refusing tells a reader
        # nothing they can act on.
        why = (
            f"pinned {item.pin.rev}, newest is {item.detail}"
            if item.state == BEHIND
            else item.detail
        )
        print(f"  note: {item.pin.url} held by {item.held.describe()} -- {why}")
    for hold in holds:
        if hold not in used_holds:
            # Said aloud for the same reason an unused allowance is: an
            # exception nobody has needed is an exception nobody is reviewing,
            # and the reason it was granted usually left with the person.
            print(f"  note: hold {hold.describe()} matched no behind or unchecked pin")

    if behind:
        return EXIT_BEHIND
    if unchecked and not allow_unchecked:
        return EXIT_UNCHECKED
    return EXIT_OK


def guarded_main(argv: list[str] | None = None) -> int:
    """main(), with every unforeseen failure landing on the right exit code.

    This module has three exit codes and one rule about them: 1 means a pin is
    BEHIND, 2 means the check could not look, and confusing the two is the
    failure the whole file is arranged against. An exception nobody caught
    breaks that rule, because Python's own default for an uncaught exception is
    exit 1 -- so a traceback out of any line below would announce a stale pin
    about a remote that was never asked. Named call sites are decoded carefully
    one at a time further up (a config that is not UTF-8, a tag name that is not
    UTF-8, git's stderr under a CP932 locale), and a handful of careful call
    sites is not the same claim as "three outcomes, never folded together". This
    is what makes that claim true of the whole module.

    The kind of failure it is here for: `yaml.compose` on a deeply nested
    document raises RecursionError, which is not a yaml.YAMLError, so the handler
    around that call does not see it. Measured: a `repos:` value nested 400 deep
    reaches the ordinary YAML error path and is exit 2, and the same document at
    600 and at 4000 unwinds past every handler in this file.

    The traceback is still printed, because a checker that swallows the reason
    is worse than one that crashes -- what changes is only the number git reads.
    `except Exception` and not `BaseException`: SystemExit is how this module
    reports a bad GIT_GUARDS_PIN_TIMEOUT and already carries the right code, and
    a KeyboardInterrupt is somebody stopping the run rather than a defect in it.
    """
    try:
        return main(argv)
    except Exception:  # noqa: BLE001 -- the point is that it is every exception
        traceback.print_exc()
        print("", file=sys.stderr)
        print(
            f"error: {TOOL}: the check itself failed, above. That is a run that "
            "looked at nothing, which is not the same as pins that are current.",
            file=sys.stderr,
        )
        return EXIT_UNCHECKED


if __name__ == "__main__":
    raise SystemExit(guarded_main())
