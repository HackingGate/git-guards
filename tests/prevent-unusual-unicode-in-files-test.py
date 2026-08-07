#!/usr/bin/env python3
"""Self-test for prevent-unusual-unicode-in-files.py -- both directions, both modes.

The rule this guards is a REJECTION, so the test that matters is not "clean
messages pass" but "dirty messages are actually refused". A whitelist checker
that accepted everything would look identical from the outside on a clean
tree, which is why every case below is paired: an allowed character passes AND
its nearest disallowed neighbour fails.

The two modes hold DIFFERENT rules on purpose (a whitelist for a message, an
invisible-character ban for a file), so the cases where they disagree are
asserted explicitly. Without that, the next person to notice the divergence
tidies it away, and the compose files lose their dashboard.icon values to a
lint that was never meant to reach them.

Runs the checker as a subprocess so the exit code -- the only thing git reads
-- is what gets asserted, not an internal return value.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "prevent-unusual-unicode-in-files.py"
SHELL_HOOK = Path(__file__).resolve().parent.parent / "prevent-unusual-unicode.sh"
HERMETIC = Path(__file__).resolve().parent / "hermetic-env.sh"


def scrub_environment() -> None:
    """Drop every variable a git-guards test must not inherit.

    WHICH variables is tests/hermetic-env.sh's answer and not this file's, for
    the same reason the scope resolver is one shell script called from two
    languages: a list each caller wrote for itself is a list the next caller
    forgets. It is a child process, so it sees the very environment being asked
    about, which is what lets one implementation serve both languages.

    Every subprocess below inherits os.environ, including the ones that pass
    `env={**os.environ, ...}`, so scrubbing the parent covers all of them.
    """
    done = subprocess.run([str(HERMETIC)], capture_output=True, text=True, check=True)
    for name in done.stdout.split():
        os.environ.pop(name, None)


def run_on(message: str) -> int:
    with tempfile.TemporaryDirectory() as td:
        msg = Path(td) / "COMMIT_EDITMSG"
        msg.write_text(message, encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), str(msg)],
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.returncode


def run_shell_hook(message: str) -> subprocess.CompletedProcess[str]:
    """The commit-msg hook as a hook runner invokes it: the wired entry point.

    Asserted separately from run_on() because it is a DIFFERENT file. A rule
    reached through two entry points is only as good as the one nobody
    exercises, and this is the one git actually calls.
    """
    with tempfile.TemporaryDirectory() as td:
        msg = Path(td) / "COMMIT_EDITMSG"
        msg.write_text(message, encoding="utf-8")
        return subprocess.run(
            [str(SHELL_HOOK), str(msg)],
            capture_output=True,
            text=True,
            check=False,
        )


def run_on_file(content: str, name: str = "sample.txt") -> int:
    with tempfile.TemporaryDirectory() as td:
        target = Path(td) / name
        target.write_text(content, encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files", str(target)],
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.returncode


def report_on_file(content: str, name: str = "sample.txt") -> tuple[int, str]:
    """Exit code AND stderr, for the cases where the message is the finding.

    An invisible character the checker refuses without NAMING is a checker a
    reviewer cannot act on: there is nothing to see at the reported column, so
    the codepoint in the message is the entire evidence.
    """
    with tempfile.TemporaryDirectory() as td:
        target = Path(td) / name
        target.write_text(content, encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files", str(target)],
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.returncode, proc.stderr


def main() -> int:
    scrub_environment()
    failures: list[str] = []

    def check(name: str, cond: bool) -> None:
        if not cond:
            failures.append(name)

    # Plain ASCII, the overwhelming majority case.
    check("ascii passes", run_on("fix(parser): tighten the input corpus\n") == 0)

    # CJK prose passes: a repository whose working language is Japanese commits
    # it in message bodies as a matter of course, and a whitelist that named
    # only ASCII would make that collateral damage.
    check("cjk passes", run_on("日本語の本文はそのまま通る\n") == 0)

    # Curated symbols pass -- the punctuation technical writing actually uses.
    check("curated currency passes", run_on("rounded down to ¥0\n") == 0)
    check("curated dash passes", run_on("build -- test -- release\n") == 0)
    check("curated compare passes", run_on("assert n ≤ 250 lines\n") == 0)

    # Emoji: a Symbol-other codepoint, deliberately outside the whitelist.
    check("emoji fails", run_on("feat: ship it 🚀\n") == 1)

    # The invisible cases are written as ESCAPES, not literals. A literal
    # zero-width space in this source file is one formatter run away from
    # being stripped, and the test would then pass while asserting nothing --
    # a green that means the opposite of what it reads as.
    # Zero-width space: invisible, so nothing but a machine catches it. This is
    # the case the whole check exists for.
    check("zero width space fails", run_on("fix:\u200bsilent\n") == 1)

    # A private-use codepoint (typically a Nerd Font glyph pasted from a prompt).
    check("private use fails", run_on("chore: \ue0b0 prompt paste\n") == 1)

    # A control character other than tab/newline.
    check("control char fails", run_on("chore: \x07 bell\n") == 1)

    # A bullet: Po, not in the curated set. Included because it is the most
    # plausible "surely this is fine" character, and the answer is no -- the
    # list is the authority, not intuition.
    check("bullet fails", run_on("chore: item\n\n• one\n") == 1)

    # Tab and newline are explicitly allowed despite being control characters.
    check("tab passes", run_on("chore: x\n\n\tindented body\n") == 0)

    # The invisible LETTERS and MARKS. These are the cases a whitelist by
    # category cannot decide: U+3164 HANGUL FILLER is `Lo` and U+034F COMBINING
    # GRAPHEME JOINER is `Mn`, so `L* N* M* Z*` waves them through on exactly
    # the grounds it waves through a kanji and an acute accent. Paired with the
    # CJK case above, which must still pass -- the rule that refuses these is
    # one table away from banning Japanese.
    check("message: hangul filler fails", run_on("fix: a\u3164b\n") == 1)
    check("message: hangul choseong filler fails", run_on("fix: a\u115fb\n") == 1)
    check("message: halfwidth hangul filler fails", run_on("fix: a\uffa0b\n") == 1)
    check("message: combining grapheme joiner fails", run_on("fix: a\u034fb\n") == 1)
    check("message: khmer vowel inherent aq fails", run_on("fix: a\u17b4b\n") == 1)
    check("message: braille blank fails", run_on("fix: a\u2800b\n") == 1)
    # Korean prose is letters that are DRAWN, and stays legal. Without this the
    # ban above reads as "no Hangul", which is not what it says.
    check("message: korean prose passes", run_on("fix: 한국어 본문\n") == 0)

    # The same sentence, spelled with a variation selector instead of a filler.
    # A commit message cannot be corrected without rewriting published history,
    # so a subject line carrying a codepoint nobody can see is permanent. A
    # carve-out that asks only whether something visible stands in front of the
    # selector admits this one.
    check(
        "message: a selector inside the subject fails",
        run_on("chore: tighten the user\ufe0fname path\n") == 1,
    )
    # Its legitimate twin in this mode, which must keep passing. It is not an
    # emoji one, because emoji are outside the message whitelist for their own
    # reasons: it is an ideographic variation sequence, and a repository whose
    # working language is Japanese writes proper nouns with them.
    check(
        "message: an ideographic variation sequence passes",
        run_on("fix: 葛\U000e0100城の表記\n") == 0,
    )

    # A missing file is a failure, never a silent pass: a checker that cannot
    # read the message has not cleared it.
    with tempfile.TemporaryDirectory() as td:
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), str(Path(td) / "nope")],
            capture_output=True,
            text=True,
            check=False,
        )
        check("missing file fails closed", proc.returncode == 1)

    # ---- The wired commit-msg entry point --------------------------------
    #
    # Everything above drives the checker directly. What a hook runner actually
    # invokes for a commit message is prevent-unusual-unicode.sh, so the cases
    # below drive THAT, end to end. The rule has one implementation and this is
    # what proves the entry point reaches it: a second copy of the whitelist
    # living in a shell string would share every gap this one has, and a fix
    # applied to one of two copies is a fix applied to neither.
    check("shell hook: ascii passes", run_shell_hook("chore: plain\n").returncode == 0)
    check("shell hook: cjk passes", run_shell_hook("fix: 日本語\n").returncode == 0)
    check("shell hook: emoji fails", run_shell_hook("feat: \U0001f680\n").returncode == 1)
    proc = run_shell_hook("fix: a\u3164b\n")
    check(
        "shell hook: hangul filler fails and is named",
        proc.returncode == 1 and "U+3164" in proc.stderr,
    )
    check(
        "shell hook: combining grapheme joiner fails",
        run_shell_hook("fix: a\u034fb\n").returncode == 1,
    )
    check(
        "shell hook: braille blank fails",
        run_shell_hook("fix: a\u2800b\n").returncode == 1,
    )

    # The entry point delegates, so the case where it cannot find what it
    # delegates to is a real failure mode and has to be a LOUD one. A commit-msg
    # hook that exits 0 because the checker was not beside it reports a clean
    # message it never read, which is the exact shape of green this repository
    # exists to refuse.
    with tempfile.TemporaryDirectory() as td:
        orphan = Path(td) / "prevent-unusual-unicode.sh"
        orphan.write_bytes(SHELL_HOOK.read_bytes())
        orphan.chmod(0o755)
        msg = Path(td) / "COMMIT_EDITMSG"
        msg.write_text("chore: plain\n", encoding="utf-8")
        proc = subprocess.run(
            [str(orphan), str(msg)], capture_output=True, text=True, check=False
        )
        check(
            "shell hook: fails closed with no checker beside it",
            proc.returncode == 1 and "checker is not beside this hook" in proc.stderr,
        )

    # ---- Mode 2: file content -------------------------------------------
    # The invisible class, which is the whole reason this mode exists. Written
    # as escapes for the same reason as above: a literal here is one formatter
    # run from vanishing, and the test would then assert nothing.
    check("file: zero width space fails", run_on_file("a\u200bb\n") == 1)
    check("file: zero width joiner fails", run_on_file("a\u200db\n") == 1)
    # Trojan source (CVE-2021-42574): a bidi override reorders what the reviewer
    # reads without changing what the compiler reads.
    check("file: bidi override fails", run_on_file("if (x) {\u202e}\n") == 1)
    check("file: non-breaking space fails", run_on_file("key:\u00a0value\n") == 1)
    check("file: ideographic space fails", run_on_file("key:\u3000value\n") == 1)
    check("file: private use fails", run_on_file("prompt \ue0b0\n") == 1)
    check("file: carriage return fails", run_on_file("line\r\n") == 1)
    check("file: bom fails", run_on_file("\ufeffheader\n") == 1)
    check("file: bell fails", run_on_file("beep \x07\n") == 1)

    # The six a rule written entirely in categories cannot reach, each one
    # asserted on the exit code AND on the codepoint appearing in the finding.
    # For every other check in this file a reviewer could look at the line and
    # see what was wrong with it; for these there is nothing at the reported
    # column to look at, so a finding that does not NAME the character is a
    # finding nobody can act on.
    code, said = report_on_file('name = "user\u3164name"\n')
    check("file: hangul filler fails", code == 1 and "U+3164" in said)
    code, said = report_on_file("jamo = \u115f\n")
    check("file: hangul choseong filler fails", code == 1 and "U+115F" in said)
    code, said = report_on_file("jamo = \u1160\n")
    check("file: hangul jungseong filler fails", code == 1 and "U+1160" in said)
    code, said = report_on_file("halfwidth = \uffa0\n")
    check("file: halfwidth hangul filler fails", code == 1 and "U+FFA0" in said)
    code, said = report_on_file("joined = a\u034fb\n")
    check("file: combining grapheme joiner fails", code == 1 and "U+034F" in said)
    code, said = report_on_file("khmer = \u17b4\n")
    check("file: khmer vowel inherent aq fails", code == 1 and "U+17B4" in said)
    code, said = report_on_file("blank = \u2800\n")
    check("file: braille pattern blank fails", code == 1 and "U+2800" in said)

    # Not one of them is a control character, and every one of their categories
    # is a category this mode otherwise ALLOWS. Asserted so that a later
    # simplification back to "ban the C and Z categories" fails here rather than
    # in a repository.
    check("file: an invisible Lo is refused though Lo is allowed", run_on_file("\u3164\n") == 1)
    check("file: an invisible Mn is refused though Mn is allowed", run_on_file("a\u034f\n") == 1)
    check("file: an invisible So is refused though So is allowed", run_on_file("\u2800\n") == 1)

    # A variation selector is the one member of the class that stays legal, and
    # only where it is doing its job. U+26A0 U+FE0F is how the warning sign that
    # renders as an emoji is spelled, and this mode admits emoji as data -- so
    # refusing the selector would refuse one spelling of a character whose other
    # spelling passes, which is a rule its own author cannot predict.
    check("file: a variation selector after a visible character passes",
          run_on_file("status: \u26a0\ufe0f degraded\n") == 0)
    # A keycap emoji is base + U+FE0F + U+20E3, and its base is ASCII. That is
    # the one place in ASCII where a selector is genuinely selecting something,
    # so it is enumerated rather than reasoned about.
    check("file: a keycap sequence passes", run_on_file("1\ufe0f\u20e3\n") == 0)
    # ...and the exception is the whole SEQUENCE, not its first character. A
    # carve-out that asks only whether the previous character is a keycap base
    # hands back twelve carriers -- `#`, `*` and the ten digits -- and every one
    # of the 260 selectors through each of them, which is a payload channel
    # through the one class of character that is in every file of every
    # repository. A port number and a version string are what that looks like
    # written down.
    check(
        "file: a selector inside a port number fails",
        run_on_file("port: 80\ufe0f80\n", name="sample.yml") == 1,
    )
    check(
        "file: a selector inside a version string fails",
        run_on_file("image: app:1\ufe0f.2.3\n", name="sample.yml") == 1,
    )
    # Only U+FE0F can finish a keycap. An IDEOGRAPHIC variation selector selects
    # between glyph forms of a CJK ideograph and can say nothing at all about a
    # digit, so `7<U+E0100>` is refused however the rest of the line continues.
    # Its legitimate twin -- the same selector after an ideograph -- is asserted
    # passing just above, which is what makes this a boundary rather than a ban.
    check(
        "file: an ideographic selector after a keycap base fails",
        run_on_file("build 7\U000e0100\n") == 1,
    )
    # The same shape in the mode that cannot be corrected afterwards: a subject
    # line is published history, so a codepoint nobody can see is permanent
    # there. Asserted in both modes because both modes are reachable and only
    # one of them can be fixed after the fact.
    check(
        "message: a selector inside a version string fails",
        run_on("chore: bump the pinned rev to v1\ufe0f.3.0\n") == 1,
    )
    # The keycap that must keep passing in THIS mode too, so the four cases
    # above are read as a boundary and not as "no selectors after digits".
    check("message: a keycap sequence passes", run_on("fix: the 1\ufe0f\u20e3 case\n") == 0)
    # An ideographic variation sequence: a CJK ideograph and a selector from the
    # supplementary plane, which is the other legitimate use and the reason the
    # boundary is drawn at U+007F rather than at "emoji".
    check("file: an ideographic variation sequence passes",
          run_on_file("\u845b\U000e0100\n") == 0)

    # The half that makes it a rule, and the half "is there anything visible in
    # front of it" does not have. A selector after a Latin letter renders as
    # nothing AND selects nothing -- there is no second way to draw a small
    # letter U -- so it is the same finding as a lone one, arriving through the
    # exception rather than around it.
    check("file: a lone variation selector fails", run_on_file("\ufe0f\n") == 1)
    check("file: a variation selector after a space fails", run_on_file("a \ufe0f\n") == 1)
    check("file: a second variation selector fails", run_on_file("a\ufe0f\ufe0f\n") == 1)
    check(
        "file: a selector inside an identifier fails",
        run_on_file('var user\ufe0fname = "admin"\n', name="sample.go") == 1,
    )
    check(
        "file: a selector inside a hostname fails",
        run_on_file("host: exa\ufe0fmple.com\n", name="sample.yml") == 1,
    )
    # One selector per visible carrier: no two are adjacent, so the
    # consecutive-selector case above never sees it. This is the shape a
    # steganographic payload actually takes -- and ASCII carriers are the EASY
    # half of it. A payload does not need them: any visible character will
    # carry a selector, and the ones below are what a reviewer is least likely
    # to look at twice, because the line reads as ordinary prose in a language
    # they may not be reading closely.
    check(
        "file: one hidden selector per carrier letter fails",
        run_on_file("p\ufe00a\ufe01y\ufe02l\ufe03o\ufe04a\ufe05d\ufe06\n") == 1,
    )
    # Cyrillic homoglyphs: er, a, u and o, four letters that a reader sees as
    # Latin ones. The word is already a homoglyph attack, and each letter now
    # carries a selector as well. "Is the carrier visible" says yes to all four.
    check(
        "file: a non-ASCII carrier payload fails",
        run_on_file("\u0440\ufe00\u0430\ufe01\u0443\ufe02\u043e\ufe03\n") == 1,
    )
    check(
        "message: a non-ASCII carrier payload fails",
        run_on("chore: \u0440\ufe00\u0430\ufe01\u0443\ufe02\u043e\ufe03\n") == 1,
    )
    # An em dash and kana, which are exactly the characters this repository's
    # own prose and its Japanese fixtures are full of.
    check("file: a selector on an em dash fails", run_on_file("a \u2014\ufe0f b\n") == 1)
    check("message: a selector on an em dash fails", run_on("chore: a \u2014\ufe0f b\n") == 1)
    check("file: a selector on kana fails", run_on_file("\u30ab\ufe0f\n") == 1)
    check("message: a selector on kana fails", run_on("fix: \u30ab\ufe0f\n") == 1)
    # A combining mark is a carrier too. `cafe` followed by U+0301 COMBINING
    # ACUTE ACCENT is how NFD spells the French word for a coffee house, so the
    # selector rides a mark that draws real ink and is still selecting nothing:
    # there is no second presentation of an acute accent.
    check(
        "file: a selector on a combining mark fails",
        run_on_file("cafe\u0301\ufe0f\n") == 1,
    )
    check(
        "message: a selector on a combining mark fails",
        run_on("chore: cafe\u0301\ufe0f\n") == 1,
    )
    # A FULLWIDTH digit is not a keycap base. It looks like one to a reader and
    # is a different codepoint to everything else, which is the whole trick.
    check(
        "file: a selector on a fullwidth digit fails",
        run_on_file("\uff11\ufe0f\n") == 1,
    )
    check(
        "message: a selector on a fullwidth digit fails",
        run_on("chore: \uff11\ufe0f\n") == 1,
    )

    # THE EMOJI TABLE, in both directions. U+FE0F is legal after a character
    # that HAS two presentations and refused after one that does not, and no
    # category can tell those apart: U+26A0 and U+2705 are both `So`.
    check("file: a selector after a two-presentation emoji passes",
          run_on_file("status: \u26a0\ufe0f\n") == 0)
    check("file: a selector after a one-presentation emoji fails",
          run_on_file("status: \u2705\ufe0f\n") == 1)
    check("file: a selector after an emoji-plane pictograph fails",
          run_on_file("ship it \U0001f680\ufe0f\n") == 1)
    # The bare emoji, which is what a repository actually commits, keeps passing
    # in a file -- so the case above is a finding about the SELECTOR and not a
    # ban on the character.
    check("file: the same emoji without a selector passes",
          run_on_file("ship it \U0001f680\n") == 0)

    # THE IDEOGRAPHIC SELECTORS, which are 240 of the 260 and can only ever
    # speak about an ideograph. Paired against the sequence that must pass.
    check("file: an ideographic selector after a latin letter fails",
          run_on_file("var a\U000e0100b = 1\n", name="sample.go") == 1)
    check("file: an ideographic selector after kana fails",
          run_on_file("\u30ab\U000e0100\n") == 1)
    check("file: an ideographic selector after an emoji fails",
          run_on_file("\U0001f680\U000e0100\n") == 1)
    check("file: an ideographic selector after a compatibility ideograph passes",
          run_on_file("\ufa0e\U000e0100\n") == 0)

    # A KEYCAP HANDS BACK NO FREE SELECTOR. The sequence is three codepoints and
    # it ENDS at the enclosing mark: if U+20E3 is itself a carrier, then every
    # permitted keycap is a licence for one more invisible codepoint, and both
    # of these render exactly like the bare keycap they follow.
    check("file: a keycap followed by a free selector fails",
          run_on_file("1\ufe0f\u20e3\ufe0f\n") == 1)
    check("file: a keycap followed by an ideographic selector fails",
          run_on_file("1\ufe0f\u20e3\U000e0100\n") == 1)
    check("message: a keycap followed by a free selector fails",
          run_on("fix: the 1\ufe0f\u20e3\ufe0f case\n") == 1)
    # U+FE0E asks for the TEXT presentation, which is a digit drawn as a digit,
    # so it finishes no keycap however the line continues.
    check("file: a text-presentation selector after a digit fails",
          run_on_file("port: 80\ufe0e80\n", name="sample.yml") == 1)

    # Visible characters pass, whatever they are. Each of these is the kind of
    # thing a real repository commits, which is what makes them the cases that
    # matter.
    check("file: ascii passes", run_on_file("plain content\n") == 0)
    check("file: tab and newline pass", run_on_file("a\tb\n\nc\n") == 0)
    check("file: japanese punctuation passes", run_on_file("見出し（補足）。\n") == 0)
    check("file: ascii tree drawing passes", run_on_file("|-- src\n|-- tests\n") == 0)
    # Actual box drawing, which the ASCII line above does not exercise: those are
    # a pipe and two hyphens. These are U+251C, U+2500 and U+2514, the characters
    # a real diagram is made of and the ones a widened ban would take out.
    check("file: box drawing passes", run_on_file("├── src\n└── tests\n") == 0)
    check("file: middle dot passes", run_on_file("a · b\n") == 0)

    # THE DIVERGENCE, asserted in both directions so it cannot be tidied away.
    # An emoji is data in a compose label (dashboard.icon) and noise in a commit
    # message. Same character, two answers, on purpose.
    check("emoji fails in a message", run_on("feat: ship it \U0001f680\n") == 1)
    check(
        "emoji passes in a file",
        run_on_file('      dashboard.icon: "\U0001f510"\n') == 0,
    )
    # A second pair, so the divergence reads as a rule and not as one character's
    # special case: a box-drawing glyph is what a diagram in a README is made of
    # and is outside the message whitelist, which names its symbols one by one.
    check("box drawing fails in a message", run_on("docs: \u251c\u2500 tree\n") == 1)
    check("box drawing passes in a file", run_on_file("\u251c\u2500 src\n") == 0)

    # AND WHERE THEY MUST NOT DIVERGE. The invisible class is one class and both
    # modes refuse it, because the argument for refusing it does not mention
    # which mode is asking: the reviewer cannot see the character and the parser
    # can. A whitelist by category says yes to every one of these -- they are
    # `Zs`, `Zl` and `Zp`, and `Z` is an allowed category in a message -- so this
    # is the block that fails if mode 1 is ever left to its own categories again.
    # Asserted through the SHELL HOOK as well for U+00A0, because the entry point
    # git calls is the one that decides whether a commit lands.
    check("nbsp fails in a message", run_on("chore: a\u00a0b\n") == 1)
    check("nbsp fails in a file", run_on_file("chore: a\u00a0b\n") == 1)
    check(
        "shell hook: nbsp fails and is named",
        run_shell_hook("chore: a\u00a0b\n").returncode == 1
        and "U+00A0" in run_shell_hook("chore: a\u00a0b\n").stderr,
    )
    # U+2028 and U+2029 are the two that do not merely hide: they SPLIT the line
    # for some readers and not others, so a one-line subject becomes two and the
    # body of a commit message is not where the author put it.
    check("line separator fails in a message", run_on("chore: a\u2028b\n") == 1)
    check("paragraph separator fails in a message", run_on("chore: a\u2029b\n") == 1)
    # The rest of the `Z` categories, each one a space that is not a space.
    for name, ch in (
        ("ogham space mark", "\u1680"),
        ("en quad", "\u2000"),
        ("hair space", "\u200a"),
        ("narrow no-break space", "\u202f"),
        ("medium mathematical space", "\u205f"),
        ("ideographic space", "\u3000"),
    ):
        check(f"message: {name} fails", run_on(f"chore: a{ch}b\n") == 1)
    # The pair that keeps this from reading as "no spaces": the one space that
    # is a space stays legal, in both modes and everywhere in the line.
    check("message: an ordinary space passes", run_on("chore: a b c\n") == 0)
    check("file: an ordinary space passes", run_on_file("a b c\n") == 0)

    # With no paths, the mode scans every tracked file -- which is how the hook
    # is wired, so it is the invocation worth asserting. Run from THIS repository,
    # whose tree the rule must obviously pass: a guard that cannot survive its own
    # source is one nobody will adopt.
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--files"],
        capture_output=True,
        text=True,
        check=False,
        cwd=SCRIPT.parent,
    )
    check("file: tracked-file scan passes on a clean tree", proc.returncode == 0)
    check("file: tracked scan prints its denominator", "file(s) scanned" in proc.stdout)

    # Fail closed when git cannot be asked at all. Outside a repository there is
    # no file list, and "cannot say" must not read as "clean".
    with tempfile.TemporaryDirectory() as td:
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files"],
            capture_output=True,
            text=True,
            check=False,
            cwd=td,
        )
        check("file: no git repository fails closed", proc.returncode == 1)

    # ---- the tracked scan, over a repository built to break it -------------
    #
    # Everything above hands the checker its paths. The wired invocation does
    # not: it asks git, and every case below is a way that question has been
    # answered such that the scan covered less than the tree and said so in the
    # language of success -- a denominator, no findings, exit 0.
    def git(td: str, *args: str) -> None:
        subprocess.run(["git", *args], cwd=td, capture_output=True, check=True)

    def tracked_repo(td: str) -> None:
        """A repository with one file in a subdirectory, and nothing wrong yet.

        Each case below adds its own offender at the ROOT, so that a scan which
        covers only the current subtree misses it and a scan which covers the
        tree does not.
        """
        git(td, "init", "-q", "-b", "main")
        git(td, "config", "user.email", "test@example.invalid")
        git(td, "config", "user.name", "test")
        deep = Path(td) / "sub" / "deep"
        deep.mkdir(parents=True)
        (deep / "leaf.txt").write_text("fine\n", encoding="utf-8")
        git(td, "add", "-A")

    # A filename is committed text. `git ls-files` C-QUOTES a path it considers
    # unusual, so a name carrying U+200B comes back as the literal characters
    # `"a\342\200\213b.txt"`, which names no file on disk -- it fails to open,
    # is counted a skip, and the one file in the repository whose NAME is an
    # attack is the one the scan never looked at.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        (Path(td) / "a\u200bb.txt").write_text("clean content\n", encoding="utf-8")
        git(td, "add", "-A")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files"],
            capture_output=True,
            text=True,
            check=False,
            cwd=td,
        )
        check("tracked: a hidden character in a FILENAME fails", proc.returncode == 1)
        check(
            "tracked: and the filename finding names the codepoint",
            "U+200B" in proc.stderr and "FILE NAME" in proc.stderr,
        )

    # A tracked file that is text except for one byte. The skip covered the
    # WHOLE file, so every hidden character in the rest of it came back clean.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        (Path(td) / "bad.txt").write_bytes(b"key: value\n\xff\nmore: text\n")
        git(td, "add", "-A")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files"],
            capture_output=True,
            text=True,
            check=False,
            cwd=td,
        )
        check("tracked: an undecodable file fails rather than skipping", proc.returncode == 1)

    # THE SUBDIRECTORY. `git ls-files` lists from the current directory DOWN, so
    # the tree-wide scan run from `sub/deep` covers one file, reports a
    # denominator and exits 0 over a tree whose root file holds U+00A0. Nothing
    # about that output says it looked at a fifth of the repository. A hook
    # runner invokes from the root; a person does not.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        (Path(td) / "root.txt").write_text("key:\u00a0value\n", encoding="utf-8")
        git(td, "add", "-A")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files"],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(Path(td) / "sub" / "deep"),
        )
        check(
            "tracked: a scan from a subdirectory still covers the whole tree",
            proc.returncode == 1,
        )
        check(
            "tracked: and the finding is the root file it would have missed",
            "root.txt" in proc.stderr,
        )
        # Paired: from the root, the same tree gives the same answer. Without
        # this the case above passes for a checker that refuses everything.
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files"],
            capture_output=True,
            text=True,
            check=False,
            cwd=td,
        )
        check("tracked: the root invocation agrees", proc.returncode == 1)

    # And the clean tree from a subdirectory still passes, so none of the above
    # is a checker that has simply stopped saying yes.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files"],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(Path(td) / "sub" / "deep"),
        )
        check("tracked: a clean tree from a subdirectory passes", proc.returncode == 0)
        check(
            "tracked: and counts every file in it, not just the subtree",
            "1 file(s) scanned" in proc.stdout,
        )

    # ---- WHICH TREE the scan reads -----------------------------------------
    #
    # Every case above stages its fixture and leaves the working tree matching
    # it, so all of them pass for a scan that reads the working tree and all of
    # them pass for a scan that reads the index. That is a suite that cannot go
    # red on the difference, and the difference was the defect: this scan read
    # the working tree, through `Path(raw).read_bytes()`, which is neither the
    # bytes being committed nor -- for a symlink -- the bytes of the entry at
    # all.
    #
    # git-guards-scope.sh answers "which tree" for this checker and for
    # no-private-repo-names --tracked alike. Each case below separates the two
    # trees on purpose and is PAIRED with the one that must behave the other
    # way, because a checker that had simply started refusing everything would
    # pass all of them.
    def scan_in(cwd: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--files"],
            capture_output=True,
            text=True,
            check=False,
            cwd=cwd,
            env={**os.environ, **env},
        )

    # A SYMLINK's blob is its target path, and that string is the file's entire
    # committed content. Following the link scans some other file's bytes -- a
    # file that need not be tracked, need not be in the repository, and need not
    # exist -- while the six bytes git actually committed go unread. Measured:
    # `ln -s $'t<U+200B>gt' link` committed U+200B, the whole hook set passed,
    # and the pushed commit still carried it after a clean clone.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        # The target is deliberately UNTRACKED and its content deliberately
        # clean, so nothing but the link's own blob can produce the finding.
        (Path(td) / "t\u200bgt").write_text("clean\n", encoding="utf-8")
        (Path(td) / "link").symlink_to("t\u200bgt")
        git(td, "add", "link")
        proc = scan_in(td)
        check("symlink: a hidden codepoint in the TARGET PATH fails", proc.returncode == 1)
        check(
            "symlink: and the finding says it is the target, not the file",
            "SYMLINK TARGET" in proc.stderr and "U+200B" in proc.stderr,
        )

    # The pair, so the case above is a finding about the target and not a ban on
    # symlinks -- which would be a rule nobody could adopt.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        (Path(td) / "target.txt").write_text("clean\n", encoding="utf-8")
        (Path(td) / "link").symlink_to("target.txt")
        git(td, "add", "-A")
        proc = scan_in(td)
        check("symlink: an ordinary symlink passes", proc.returncode == 0)

    # ...and the other half of "not the file it points at": a link whose target
    # is dirty is not this entry's problem when the target is not tracked. If it
    # IS tracked it is scanned under its own name, which is where a finding
    # about it belongs.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        (Path(td) / "outside.txt").write_text("key:\u00a0value\n", encoding="utf-8")
        (Path(td) / "link").symlink_to("outside.txt")
        git(td, "add", "link")
        proc = scan_in(td)
        check(
            "symlink: an untracked target's content is not read through the link",
            proc.returncode == 0,
        )

    # The INDEX, not the file on disk. A hidden character staged and then edited
    # back out of the working copy is in the commit and was not in the scan.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        (Path(td) / "root.txt").write_text("key:\u200bvalue\n", encoding="utf-8")
        git(td, "add", "-A")
        (Path(td) / "root.txt").write_text("key: value\n", encoding="utf-8")
        proc = scan_in(td)
        check("index: what is staged is judged, not the edited-away copy", proc.returncode == 1)

    # The pair. A character typed into a file and never staged is in no commit,
    # so it is not this operation's problem; it becomes one the moment it is
    # staged, which is the case immediately above.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        (Path(td) / "root.txt").write_text("key: value\n", encoding="utf-8")
        git(td, "add", "-A")
        (Path(td) / "root.txt").write_text("key:\u200bvalue\n", encoding="utf-8")
        proc = scan_in(td)
        check("index: ...and an unstaged edit is in no commit, so it is not one", proc.returncode == 0)

    # "Cannot read it" used to be reported as hidden Unicode -- under the
    # heading `error: hidden Unicode in committed files`, with the
    # hidden-character remedy, for a file that had simply been deleted from the
    # checkout. Reading git's objects retires the whole class: neither a missing
    # working-tree copy nor a mode bit can stop a blob coming out of the object
    # database, so the file is not skipped and not complained about -- it is
    # SCANNED, and the assertion is on what it found.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        (Path(td) / "root.txt").write_text("key:\u200bvalue\n", encoding="utf-8")
        git(td, "add", "-A")
        (Path(td) / "root.txt").unlink()
        proc = scan_in(td)
        check("index: a file deleted from the checkout is still scanned", proc.returncode == 1)
        check(
            "index: ...and the finding is the codepoint, not a read error",
            "U+200B" in proc.stderr and "cannot read" not in proc.stderr,
        )

    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        (Path(td) / "root.txt").write_text("key: value\n", encoding="utf-8")
        git(td, "add", "-A")
        (Path(td) / "root.txt").unlink()
        proc = scan_in(td)
        check("index: ...and a deleted clean file is clean, not a refusal", proc.returncode == 0)

    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        unreadable = Path(td) / "root.txt"
        unreadable.write_text("key:\u200bvalue\n", encoding="utf-8")
        git(td, "add", "-A")
        unreadable.chmod(0o000)
        proc = scan_in(td)
        unreadable.chmod(0o644)
        check("index: a file that will not open is still scanned", proc.returncode == 1)

    # The commit being PUSHED. At pre-push the working tree is whatever branch
    # happens to be checked out, and a runner exports the local sha it is about
    # to send -- measured under prek 0.3.12 as PRE_COMMIT_TO_REF beside
    # PRE_COMMIT_SOURCE.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        git(td, "commit", "-q", "--no-verify", "-m", "base")
        git(td, "checkout", "-q", "-b", "feature")
        (Path(td) / "root.txt").write_text("key:\u200bvalue\n", encoding="utf-8")
        git(td, "add", "-A")
        git(td, "commit", "-q", "--no-verify", "-m", "hidden")
        git(td, "checkout", "-q", "main")

        feature = subprocess.run(
            ["git", "rev-parse", "feature"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        trunk = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()

        proc = scan_in(td, PRE_COMMIT_TO_REF=feature)
        check("push: the branch being pushed is scanned, not the checkout", proc.returncode == 1)
        proc = scan_in(td, PRE_COMMIT_TO_REF=trunk)
        check("push: ...and a clean branch is clean, dirty siblings and all", proc.returncode == 0)
        check(
            "push: ...and the denominator names the tree it read",
            "the commit being pushed" in proc.stdout,
        )

    # The FILE NAME check, at the push scope rather than the index.
    #
    # Every name case in this file used to read the index, and every push case
    # used a name spelled in ASCII, so the two never met -- which is the whole of
    # why this went unseen. `git ls-tree -z --format` renders `%(path)` through
    # core.quotePath and -z does not turn that off, so a commit's paths arrived
    # C-escaped: `"src/hel\342\200\213lo.py"`, quotes and all. Every non-ASCII
    # codepoint in a name became ASCII backslashes and digits before this guard
    # looked at it, and the file was counted as scanned. Measured through a real
    # `git push` under prek 0.3.12: refused at the index, `Passed` at pre-push,
    # and the branch reached the remote.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        git(td, "commit", "-q", "--no-verify", "-m", "base")
        git(td, "checkout", "-q", "-b", "feature")
        hidden_name = Path(td) / "src"
        hidden_name.mkdir(exist_ok=True)
        (hidden_name / "hel\u200blo.py").write_text("plain ascii\n", encoding="utf-8")
        git(td, "add", "-A")
        git(td, "commit", "-q", "--no-verify", "-m", "a module")
        feature = subprocess.run(
            ["git", "rev-parse", "feature"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        git(td, "checkout", "-q", "main")

        proc = scan_in(td, PRE_COMMIT_TO_REF=feature)
        check("push: a hidden character in a FILE NAME fails at the push scope",
              proc.returncode == 1)
        check(
            "push: ...and the finding says it is in the file name",
            "FILE NAME" in proc.stderr,
        )
        # The pair that makes the assertion about the BYTES and not about
        # refusing anything non-ASCII: an ordinary accented name is not a
        # finding, and a quoted path would have made it one had the fix been to
        # read the escapes as characters.
        git(td, "checkout", "-q", "feature")
        (hidden_name / "hel\u200blo.py").unlink()
        (hidden_name / "café.md").write_text("plain ascii\n", encoding="utf-8")
        git(td, "add", "-A")
        git(td, "commit", "-q", "--no-verify", "-m", "rename")
        accented = subprocess.run(
            ["git", "rev-parse", "feature"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        git(td, "checkout", "-q", "main")
        # The FROM is what keeps this pair about names. Without it the range is
        # everything no remote holds -- the whole history -- and the commit that
        # ADDED the hidden name is in it, which is the range half doing exactly
        # its job over a fixture that only means to ask about the tip. FROM is
        # the commit that added it, so the range under test is the rename alone.
        proc = scan_in(td, PRE_COMMIT_TO_REF=accented, PRE_COMMIT_FROM_REF=feature)
        check("push: ...and an ordinary accented name is not a finding",
              proc.returncode == 0)
        # And the range half of the very same push, asserted rather than assumed:
        # widen the range back past the commit that added the hidden name and
        # the scan finds it, in a file the tip does not have at all.
        proc = scan_in(td, PRE_COMMIT_TO_REF=accented)
        check(
            "push: a name added and deleted inside the range is still read",
            proc.returncode == 1 and "FILE NAME" in proc.stderr,
        )
        check(
            "push: ...and the finding names the commit that added it",
            f"added by commit {feature[:12]}" in proc.stderr,
        )

    # A directory COMPONENT is a filename too, and it is the component nobody
    # opens a file to look at. The case above plants the codepoint in a root
    # file's name; this one plants it in a directory the file sits under, which
    # is the shape a vendored tree takes.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        hidden_dir = Path(td) / "ven\u200bdor"
        hidden_dir.mkdir()
        (hidden_dir / "README").write_text("clean content\n", encoding="utf-8")
        git(td, "add", "-A")
        proc = scan_in(td)
        check("tracked: a hidden character in a DIRECTORY name fails", proc.returncode == 1)
        check(
            "tracked: ...and the finding says it is in the file name",
            "FILE NAME" in proc.stderr,
        )

    # A SUBMODULE is skipped as content and its path is not. A gitlink has no
    # blob in this repository at all, so the path is the whole of what it
    # publishes -- planted with update-index rather than by adding a real
    # submodule, because the entry is the subject and a second repository would
    # only be scenery.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        git(td, "commit", "-q", "--no-verify", "-m", "base")
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        git(td, "update-index", "--add", "--cacheinfo", f"160000,{head},ven\u200bdored")
        proc = scan_in(td)
        check("tracked: a submodule's PATH is scanned though its content is not",
              proc.returncode == 1)
        check(
            "tracked: ...and the finding says it is in the file name",
            "FILE NAME" in proc.stderr,
        )
        # The pair, and it is what makes the case above about the PATH rather
        # than about refusing gitlinks. A submodule at an ordinary path passes,
        # and is named as a skip rather than silently counted, because it is its
        # own repository and carries these hooks itself.
        git(td, "rm", "-q", "--cached", "ven\u200bdored")
        git(td, "update-index", "--add", "--cacheinfo", f"160000,{head},vendored")
        proc = scan_in(td)
        check("tracked: ...and an ordinary submodule path is not a finding",
              proc.returncode == 0)
        check(
            "tracked: ...and the submodule is named as a skip, not just counted",
            "vendored (a submodule" in proc.stdout,
        )

    # The MESSAGES a push publishes. A commit is a tree AND a message, and the
    # message is checked by a commit-msg hook -- which runs when `git commit`
    # writes one. `git commit-tree`, a rebase, a cherry-pick, `git am`,
    # `--no-verify` and a fast-forward from a hookless clone all produce a commit
    # without that ever happening, and this guard read only the tree. Measured:
    # a subject line carrying U+200B rode a `git merge --ff-only` from a hookless
    # clone to the remote with every hook green and no override of any kind.
    #
    # Every commit below is made with --no-verify, which is the cheapest way to
    # spell "this message never met the commit-msg guard".
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        git(td, "remote", "add", "origin", str(Path(td) / "nowhere.git"))
        git(td, "commit", "-q", "--no-verify", "-m", "an ordinary subject")
        base = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        (Path(td) / "sub" / "deep" / "leaf.txt").write_text("still fine\n", encoding="utf-8")
        git(td, "add", "-A")
        git(td, "commit", "-q", "--no-verify", "-m", "sub\u200bject")
        tip = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()

        proc = scan_in(td, PRE_COMMIT_TO_REF=tip, PRE_COMMIT_FROM_REF=base)
        check("push: a pushed commit's MESSAGE is read, not only its tree",
              proc.returncode == 1)
        check(
            "push: ...and the finding names the commit and the codepoint",
            tip[:12] in proc.stderr and "U+200B" in proc.stderr,
        )

        # The pair, twice over. A commit the remote already holds is outside the
        # range, and a clean message inside the range is not a finding -- without
        # both, a guard that had started refusing every push would pass the case
        # above and be unusable the moment anyone adopted it.
        proc = scan_in(td, PRE_COMMIT_TO_REF=base, PRE_COMMIT_FROM_REF=base)
        check("push: a message the remote already holds is not this push's",
              proc.returncode == 0)
        check(
            "push: ...and the denominator counts the messages read",
            "0 commit message(s)" in proc.stdout,
        )

        proc = scan_in(td, PRE_COMMIT_TO_REF=base)
        check("push: ...and an ordinary subject line passes at push time",
              proc.returncode == 0)
        check(
            "push: ...having actually read it",
            "1 commit message(s)" in proc.stdout,
        )

    # The BLOBS a push publishes that its tip's tree does not hold.
    #
    # A push publishes a RANGE and this scan read the TIP. A file added in one
    # pushed commit and removed in the next is on the remote permanently, is in
    # no tip tree, and was read by nothing -- measured, a hookless clone's two
    # commits fast-forwarded in and pushed with every hook green and no override
    # of any kind. Both halves are asserted here, because neither is a superset
    # of the other: the range catches what passed through it, and the TREE
    # catches what arrived before it and is still there.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        git(td, "commit", "-q", "--no-verify", "-m", "an ordinary subject")
        base = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        transient = Path(td) / "transient.txt"
        transient.write_text("zero\u200bwidth\n", encoding="utf-8")
        git(td, "add", "-A")
        git(td, "commit", "-q", "--no-verify", "-m", "add a scratch file")
        added = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        git(td, "rm", "-q", "transient.txt")
        git(td, "commit", "-q", "--no-verify", "-m", "clean up scratch files")
        tip = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()

        # The tip's tree is clean and stays clean: that is the whole reason this
        # went unseen, and it is asserted so the case below cannot pass for the
        # wrong reason.
        proc = scan_in(td, PRE_COMMIT_TO_REF=tip, PRE_COMMIT_FROM_REF=tip)
        check("push: the tip's own tree hides nothing, which is the trap",
              proc.returncode == 0)

        proc = scan_in(td, PRE_COMMIT_TO_REF=tip, PRE_COMMIT_FROM_REF=base)
        check("push: a blob added and removed inside the range is still read",
              proc.returncode == 1)
        check(
            "push: ...and the finding names the commit that added it",
            f"commit {added[:12]} ADDED" in proc.stderr and "U+200B" in proc.stderr,
        )

        # The denominator, both halves of it. One number for the two would read
        # the same whether the range half found a blob or was never asked.
        proc = scan_in(td, PRE_COMMIT_TO_REF=tip, PRE_COMMIT_FROM_REF=tip)
        check(
            "push: the denominator states the tree half and the range half apart",
            "0 additional blob(s) introduced by the pushed range" in proc.stdout,
        )

    # The same denominator over a range that introduces a blob and finds nothing
    # wrong with it, which is the run that has to stay readable: the count is
    # only worth printing if it moves when the scan reads more.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        git(td, "commit", "-q", "--no-verify", "-m", "an ordinary subject")
        base = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        (Path(td) / "scratch.txt").write_text("nothing hidden here\n", encoding="utf-8")
        git(td, "add", "-A")
        git(td, "commit", "-q", "--no-verify", "-m", "add a scratch file")
        git(td, "rm", "-q", "scratch.txt")
        git(td, "commit", "-q", "--no-verify", "-m", "clean up scratch files")
        tip = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        proc = scan_in(td, PRE_COMMIT_TO_REF=tip, PRE_COMMIT_FROM_REF=base)
        check(
            "push: the range half is counted when there is one, and passes clean",
            "1 additional blob(s) introduced by the pushed range" in proc.stdout
            and proc.returncode == 0,
        )

    # The MESSAGE rule and not this file's own, which is the whole reason the two
    # are separate. An emoji is DATA in a file and is refused in a message, so a
    # pushed commit whose subject carries one is refused at push exactly as it
    # would have been at commit-msg. A guard that applied the file ban here
    # would be a third rule, agreeing with the commit-msg guard until it did not.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        git(td, "commit", "-q", "--no-verify", "-m", "an ordinary subject")
        base = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        (Path(td) / "sub" / "deep" / "leaf.txt").write_text("still fine\n", encoding="utf-8")
        git(td, "add", "-A")
        git(td, "commit", "-q", "--no-verify", "-m", "ship it \U0001F680")
        tip = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=td, capture_output=True, text=True, check=True,
        ).stdout.strip()
        proc = scan_in(td, PRE_COMMIT_TO_REF=tip, PRE_COMMIT_FROM_REF=base)
        check("push: a message is judged by the MESSAGE rule, not the file ban",
              proc.returncode == 1)
        # And the same emoji in a FILE still passes, which is the disagreement
        # the two rules exist to have.
        check("file: ...while the same emoji in a file is data", run_on_file("ship it \U0001F680\n") == 0)

    # The resolver is a dependency and not a preference. Absent, "which tree" is
    # a refusal, because the fallback it replaced -- read the working tree -- is
    # the defect, and a packaging mistake must not quietly restore it.
    with tempfile.TemporaryDirectory() as td:
        tracked_repo(td)
        lonely = Path(td) / "lonely.py"
        lonely.write_bytes(SCRIPT.read_bytes())
        proc = subprocess.run(
            [sys.executable, str(lonely), "--files"],
            capture_output=True,
            text=True,
            check=False,
            cwd=td,
        )
        check("scope: a missing resolver fails closed", proc.returncode == 1)
        check(
            "scope: ...and says the scan did not happen",
            "did not happen" in proc.stderr,
        )

    # Fail closed on an empty scan.
    with tempfile.TemporaryDirectory() as td:
        # A directory is what a submodule gitlink looks like to the hook: it is
        # skipped, and skipping EVERYTHING must not report success.
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files", td],
            capture_output=True,
            text=True,
            check=False,
        )
        check("file: only unreadable paths fails closed", proc.returncode == 1)

        # A binary file is skipped, and a skip alongside a real scan is fine.
        # The bytes are a real PNG header: what makes it skippable is the NUL,
        # which is git's own test for a binary file and means there is no line
        # for a codepoint to hide in. A fixture that merely fails to decode is
        # NOT this case -- see the two below, which must fail.
        blob = Path(td) / "blob.bin"
        blob.write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")
        text = Path(td) / "clean.txt"
        text.write_text("fine\n", encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files", str(blob), str(text)],
            capture_output=True,
            text=True,
            check=False,
        )
        check("file: binary skipped beside a real scan passes", proc.returncode == 0)
        check("file: prints its denominator", "1 file(s) scanned" in proc.stdout)
        # And the skip is NAMED, not just counted. A number on its own is what
        # makes a skip safe to ignore; the reader has to be able to see which
        # file this run did not look at.
        check("file: the binary skip is named, not just counted", "blob.bin" in proc.stdout)

        # A file that is text everywhere except one byte is NOT binary and must
        # not be skipped: the skip covered the whole file, so every hidden
        # character in the other thousand bytes came back clean. "Cannot read
        # it" is not "there is nothing in it".
        nearly = Path(td) / "nearly.txt"
        nearly.write_bytes("key: value\n".encode() + b"\xff" + b"more: text\n")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files", str(nearly), str(text)],
            capture_output=True,
            text=True,
            check=False,
        )
        check("file: one bad byte fails rather than skipping the file", proc.returncode == 1)
        check(
            "file: and says the content was never examined",
            "never examined" in proc.stderr,
        )

        # UTF-16 is text. It is full of NUL bytes, so a binary test alone
        # dismisses it, and everything written in it -- here a non-breaking
        # space -- leaves the scan with the file. The BOM says what it is, so
        # the scan reads it and finds what is in it.
        wide = Path(td) / "wide.txt"
        wide.write_bytes("key:\u00a0value\n".encode("utf-16"))
        code, said = report_on_file("placeholder\n")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files", str(wide)],
            capture_output=True,
            text=True,
            check=False,
        )
        check("file: utf-16 content is scanned, not skipped", proc.returncode == 1)
        check("file: and the utf-16 finding names the codepoint", "U+00A0" in proc.stderr)
        # Paired: clean UTF-16 passes, so the case above is a finding and not a
        # ban on the encoding.
        wide_ok = Path(td) / "wide-ok.txt"
        wide_ok.write_bytes("key: value\n".encode("utf-16"))
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--files", str(wide_ok)],
            capture_output=True,
            text=True,
            check=False,
        )
        check("file: clean utf-16 passes", proc.returncode == 0)

        # --- declared allowances -------------------------------------------
        #
        # Every case is paired. An allowance that is one character too wide would
        # pass the permissive half of a one-sided test and stop being a rule.

        def run(*args: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [sys.executable, str(SCRIPT), "--files", *args],
                capture_output=True,
                text=True,
                check=False,
            )

        jp = Path(td) / "jp.go"
        jp.write_text("const sep = \"\u3000\"\n", encoding="utf-8")

        check("allow: U+3000 fails when not declared", run(str(jp)).returncode == 1)
        check(
            "allow: U+3000 passes when declared",
            run("--allow", "U+3000", str(jp)).returncode == 0,
        )
        check(
            "allow: the --allow=U+3000 spelling works too",
            run("--allow=U+3000", str(jp)).returncode == 0,
        )
        check(
            "allow: a bare hex codepoint works",
            run("--allow", "3000", str(jp)).returncode == 0,
        )

        # The same door opens for the invisible letters, and a repository that
        # processes Hangul jamo is the case it opens for: U+1160 HANGUL JUNGSEONG
        # FILLER is how a syllable with no vowel is written down. Paired, so that
        # an allowance for one filler cannot be read as an allowance for the
        # block -- U+3164 is a different character with a different use.
        jamo = Path(td) / "jamo.go"
        jamo.write_text("const noVowel = \"\u1160\"\n", encoding="utf-8")
        check("allow: U+1160 fails when not declared", run(str(jamo)).returncode == 1)
        check(
            "allow: U+1160 passes when declared",
            run("--allow", "U+1160", str(jamo)).returncode == 0,
        )
        filler = Path(td) / "filler.go"
        filler.write_text("const pad = \"\u3164\"\n", encoding="utf-8")
        check(
            "allow: an allowance for one filler does not admit another",
            run("--allow", "U+1160", str(filler)).returncode == 1,
        )

        # The half that matters. Allowing one codepoint must not admit the class.
        bidi = Path(td) / "bidi.go"
        bidi.write_text("// \u202eevil\n", encoding="utf-8")
        check(
            "allow: an allowance does not admit a bidi override",
            run("--allow", "U+3000", str(bidi)).returncode == 1,
        )

        check(
            "allow: a malformed codepoint is refused, not ignored",
            run("--allow", "not-a-codepoint", str(jp)).returncode != 0,
        )
        check(
            "allow: an unknown flag is refused rather than read as a path",
            run("--no-such-flag", str(jp)).returncode != 0,
        )

        # --- allowances scoped to a path ------------------------------------
        #
        # The case: a repository tracking CAPTURED ARTIFACTS -- pages an upstream
        # actually served, committed byte-for-byte so a parser can be tested
        # against them -- contains whatever the upstream's markup contains. Here
        # that is U+00A0. Allowing it repo-wide to accommodate the fixture also
        # allows it in the code, where a non-breaking space is the defect this
        # rule is for. Paired, like every case above.

        fixtures = Path(td) / "fixtures"
        fixtures.mkdir(exist_ok=True)
        captured = fixtures / "page.html"
        captured.write_text("<td>a\u00a0b</td>\n", encoding="utf-8")
        source = Path(td) / "source.go"
        source.write_text("const gap = \"a\u00a0b\"\n", encoding="utf-8")

        check(
            "scoped: U+00A0 fails in a fixture when nothing is declared",
            run(str(captured)).returncode == 1,
        )
        check(
            "scoped: an allowance scoped to the fixtures tree passes there",
            run("--allow", "U+00A0:*/fixtures/*", str(captured)).returncode == 0,
        )
        check(
            "scoped: and does NOT pass for the same character in the source",
            run("--allow", "U+00A0:*/fixtures/*", str(source)).returncode == 1,
        )
        check(
            "scoped: an unscoped allowance still applies everywhere",
            run("--allow", "U+00A0", str(source)).returncode == 0,
        )
        proc = run("--allow", "U+00A0:*/nowhere/*", str(text))
        check(
            "scoped: an allowance matching no scanned file says so",
            proc.returncode == 0 and "matched no scanned file" in proc.stdout,
        )
        check(
            "scoped: a scoped allowance does not admit the class either",
            run("--allow", "U+00A0:*/fixtures/*", str(bidi)).returncode == 1,
        )

        # --- declared exclusions ---------------------------------------------
        vendored = Path(td) / "third_party"
        vendored.mkdir(exist_ok=True)
        bundle = vendored / "bundle.js"
        bundle.write_text("var a=1;\u0007\n", encoding="utf-8")

        check("exclude: a vendored file fails when not excluded", run(str(bundle)).returncode == 1)
        proc = run("--exclude", "*/third_party/*", str(bundle), str(text))
        check("exclude: an excluded path is skipped", proc.returncode == 0)
        # A silent exclusion is how a glob grows to cover the tree and the scan
        # stays green. The skip has to be counted and printed.
        check("exclude: the skip is counted, not silent", "1 skipped" in proc.stdout)
        check(
            "exclude: a non-excluded offender still fails",
            run("--exclude", "*/third_party/*", str(bundle), str(bidi)).returncode == 1,
        )
        # Excluding everything leaves nothing scanned, which is not a pass.
        check(
            "exclude: excluding the whole selection fails closed",
            run("--exclude", "*", str(bundle)).returncode == 1,
        )

    if failures:
        print("prevent-unusual-unicode-in-files-test FAILURES: " + ", ".join(failures))
        return 1
    print("prevent-unusual-unicode-in-files-test: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
