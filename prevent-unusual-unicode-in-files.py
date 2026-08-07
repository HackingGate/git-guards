#!/usr/bin/env python3
"""Reject unusual Unicode -- in a commit message, and in committed files.

Two modes, one home. A rule with two implementations is two rules that agree
until they do not.

## Mode 1 (default): a commit message

Whitelist, not blacklist -- the set of characters that belong in a commit
message is small and nameable, while the set that does not is unbounded:

  1. ASCII printable (0x20-0x7E) plus tab and newline
  2. Unicode letters, numbers, combining marks and separators (L* N* M* Z*),
     so CJK, Cyrillic and Arabic prose pass unchanged
  3. A curated set of non-ASCII punctuation and symbols that technical and
     financial writing actually uses

What that leaves out is the point: emoji, private-use codepoints, control
characters and zero-width joiners, none of which a human typed on purpose.

One thing a whitelist by category cannot leave out: a codepoint categorised as a
LETTER, a MARK or a SEPARATOR that draws nothing. U+3164 HANGUL FILLER is `Lo`;
U+034F COMBINING GRAPHEME JOINER is `Mn`; U+00A0 NO-BREAK SPACE is `Zs` and
U+2028 LINE SEPARATOR is `Zl`. All four sit inside `L* N* M* Z*` and not one of
them puts ink on the page, so a whitelist by category says yes to them for the
same reason it says yes to a kanji: a category describes what a codepoint IS,
and for this class that is the opposite of what a reader sees.

So the invisible test is the SAME test in both modes, and it is asked FIRST in
both, before either mode's own rule -- exactly the class mode 2 names below,
less the space, tab and newline any text may hold. A commit message is published
history and cannot be corrected without rewriting it, which makes it the worse
of the two places to lose a codepoint nobody can see, not the more forgiving
one. A non-breaking space is refused in a subject line for the same reason it is
refused in a YAML key.

## Mode 2 (--files): committed file content

A DIFFERENT rule, deliberately, and the difference is the load-bearing part.
A whitelist is right for a message -- a short line typed in a terminal, whose
legitimate vocabulary is nameable. It is wrong for a repository's files, where
the legitimate vocabulary is not. Real repositories commit CJK punctuation
(ideographic comma and full stop, corner brackets, fullwidth parentheses) in
their prose, box-drawing characters in their diagrams, and emoji as DATA -- a
label value read by a dashboard, a status glyph in a fixture -- so a whitelist
inherited from mode 1 would delete a feature to satisfy a lint.

So mode 2 bans a named class instead: characters that are INVISIBLE or
DECEPTIVE in a file, where the reader cannot see what the machine will do.

  * Cc  control characters other than tab and newline -- including a carriage
        return, which is how a CRLF file enters a repository that has none
  * Cf  format characters: zero-width space and joiner, the bidirectional
        overrides of the trojan-source class (CVE-2021-42574), a stray BOM
  * Co  private use -- a Nerd Font glyph pasted from a prompt, which renders
        as a box or as nothing depending on who opens the file
  * Cs  surrogates, which cannot appear in well-formed text at all
  * Cn  unassigned codepoints
  * Zs  a space that is not U+0020 -- a non-breaking space in a shell script or
        a YAML key is invisible to the reviewer and syntactically different to
        the parser. It is the likeliest of all of these to be present and the
        hardest to see, which is why it is also the one a whitelist by category
        would wave through: `Z` is an allowed category in mode 1, so mode 1 asks
        this list first rather than trusting its own categories.
  * Zl  Zp  line and paragraph separators, which split a line for some readers
        and not for others

A category is not enough, though, and the six characters that proved it are the
reason the rule now carries a table as well:

  * Default_Ignorable_Code_Point, which is Unicode's own name for a codepoint a
        renderer is instructed to draw as nothing. Most of that property is Cf
        or Cn and so was already refused above; the part that was NOT is the
        part that matters, because those codepoints are classified as LETTERS
        and MARKS and therefore pass every test written in terms of categories.
        U+3164 HANGUL FILLER is an invisible `Lo`, which is what makes it the
        character of choice for smuggling one identifier past a reviewer reading
        another. U+115F, U+1160 and U+FFA0 are the same trick in the same block;
        U+034F COMBINING GRAPHEME JOINER and U+17B4..U+17B5 KHMER VOWEL INHERENT
        AQ/AA are the same trick in `Mn`.
  * U+2800 BRAILLE PATTERN BLANK, the one character named on its own. It is not
        Default_Ignorable -- Unicode considers it a symbol like any other Braille
        cell -- and its category is `So`, alongside every emoji this mode
        deliberately permits. What decides it is neither: the cell with no raised
        dots is drawn as empty space, and empty space is the whole subject here.

Everything visible stays legal. An emoji, a box-drawing character and a
fullwidth parenthesis are all things somebody can see and therefore chose.

The one member of that table this rule does NOT refuse outright is a variation
selector, and the exception draws the boundary rather than dodging it.
Everything named above renders as nothing AND changes nothing: it takes a
position in the text where the reader sees absence. A variation selector takes
no position of its own -- its entire job is to choose how the character BEFORE
it is drawn, and the reader sees that choice. `U+26A0 U+FE0F` is how the warning
sign that renders as an emoji is spelled, and a rule that admits emoji as data
while refusing half their spellings is a rule its own author cannot predict.

So a selector is legal exactly where it is DOING that job -- and whether it is
doing it depends on WHICH selector it is. There are 260 of them and they are not
one family. Each family chooses among the alternate forms of a different kind of
character, so "is there something visible in front of it" answers none of them:
that question admits 149,262 carriers for U+FE0F alone, and it hands the
ideographic selectors 50,580 carriers that are not ideographs, where there is
nothing to choose between however the font is drawn.

The question is therefore asked once per family, and each family has exactly
one:

  * U+FE0E and U+FE0F choose between the text and the emoji presentation, so the
        base has to be a character that HAS both. That set is neither a category
        nor a range: it is the 354 bases of the standardized emoji variation
        sequences, carried below as a table for the same reason the
        default-ignorable table is carried -- it can be diffed against the file
        it came from. U+26A0 WARNING SIGN is in it. U+1F680 ROCKET is not: it has
        only ever had the one presentation, so a selector after it selects
        nothing, which is the sentence this whole class is refused by.
  * U+E0100..U+E01EF are the IDEOGRAPHIC variation selectors. They choose between
        the registered glyph forms of a CJK ideograph, so the base has to be an
        ideograph. `葛<U+E0100>` is how a Japanese proper noun is written down;
        `7<U+E0100>` and `a<U+E0100>` are a digit and a letter with a codepoint
        nobody can see after them.
  * U+180B..U+180D and U+180F are Mongolian's free variation selectors and choose
        between the forms of a Mongolian letter, so the base has to be Mongolian.
  * U+FE00..U+FE0D are the remaining standardized variation selectors. The
        sequences a repository actually commits with them are the CJK ones, so
        the base has to be an ideograph here too. A repository that commits one
        of the rare mathematical variants declares it with --allow, where a
        reviewer reads it in a diff -- the same door every other exception to
        this rule goes through.

Below U+0080 the answer is no for every family, with one exception, and it is an
exception for a WHOLE SEQUENCE rather than for its first character. The twelve
keycap bases -- `#`, `*` and the ten digits -- do have emoji variation
sequences, so the table alone would admit them, and that would hand back the
twelve characters that appear in every file of every repository. A keycap is
three codepoints, `1<U+FE0F><U+20E3>`, so an ASCII base is a licence only when
the U+FE0F and the U+20E3 are both actually there. `port: 80<VS16>80` and a
subject line reading `bump to v1<VS16>.3.0` are not keycaps; they are
`user<VS16>name` again, spelled with digits.

The sequence ENDS at the U+20E3, and the mark does not become a carrier in its
turn. U+20E3 has no emoji variation sequence of its own and is not an ideograph,
so `1<U+FE0F><U+20E3><U+FE0F>` and `1<U+FE0F><U+20E3><U+E0100>` are both refused
even though each renders exactly like the bare keycap. A permitted sequence
hands back no free selector.

Submodules are not scanned: each is its own repository, and consumes this hook
itself. That boundary is only sound because the rule lives HERE rather than in
one workspace -- a superproject-only copy covers the superproject's own files and
leaves the repositories where the code actually lives unguarded, which is the
state this hook exists to prevent.

## Symlinks

A symlink IS scanned, and what is scanned is the symlink's own blob -- the
target path, as a string -- rather than whatever that path resolves to. That is
what git stores for a symlink and therefore what a commit publishes.

It is written down here because the obvious reading of "scan every tracked file"
produces the opposite, silently. `Path(raw).read_bytes()` FOLLOWS the link and
returns the target file's bytes, so the scan reported on a file that may not be
tracked, may not be in the repository, and may not exist -- while the bytes git
actually committed went unread. `ln -s $'t<U+200B>gt' link` committed a
zero-width space in a blob of six bytes, the whole hook set passed, and a fresh
clone of the pushed commit still carried it. The target's own content is not
this entry's business: if that file is tracked, it is scanned under its own
name, and if it is not tracked, it is not being committed.

A submodule's gitlink is the third kind of entry and has no blob in this
repository at all, so it is a declared skip and named as one.

## Which tree

With no paths given, the set of entries comes from git-guards-scope.sh, which is
shared with no-private-repo-names.sh --tracked because the two ask one question:
which bytes is this operation actually introducing. Its own header carries the
reasoning; the short version is that the answer is the INDEX at pre-commit and
pre-merge-commit, the commit being PUSHED at pre-push, and HEAD where there is
no index. It is not the working tree, and the difference is not academic: a
hidden character staged and then edited back out of the file on disk is in the
commit and was not in the scan.

A push publishes two things besides that tree and its paths, and both are read
at pre-push and only there.

The MESSAGES of the commits being sent, judged by the MESSAGE rule rather than
this file's own -- see scope_messages. The gap they close is not theoretical:
the commit-msg guard runs when `git commit` writes a message, and `git
commit-tree`, a rebase, a cherry-pick, `git am`, `--no-verify` and a
fast-forward from a hookless clone all make a commit without that ever
happening. Measured: a subject line carrying U+200B rode a `git merge --ff-only`
from a hookless clone to a remote with no override.

And the BLOBS THE RANGE INTRODUCES. A push publishes a range of commits; a scan
of the tip's tree reads the last of them. A file added in one pushed commit and
deleted in the next is on the remote permanently, is in no tip tree, and was
read by nothing -- measured, a file carrying U+200B, fast-forwarded in from a
hookless clone, every hook green. The resolver answers with the union of the two
and marks each entry with where it came from, so the two halves stay countable;
a range entry names the commit that introduced it, because that commit is the
only thing left to act on once the file itself is gone.

## Two boundaries this rule cannot cross

A MULTI-REF PUSH IS JUDGED ON ONE REF. prek 0.3.12 exports a single
PRE_COMMIT_TO_REF pair and its shim has already consumed git's ref-update stream
from stdin, so `git push origin clean1 dirty1` scans clean1 and publishes
dirty1. Push one ref at a time, or run the manual stage in CI over the whole
tree.

AN ANNOTATED TAG'S MESSAGE IS NEVER SCANNED. git has no tag-message hook type,
so `git tag -a -m '...'` reaches nothing here. A tag's TREE is covered, because
the scope resolver peels a tag to its commit; it is the tag's own message, and
only that, which nothing can reach.

The rule is a Python program rather than a shell one because a rule embedded in
a shell string cannot be imported, cannot be type-checked, and cannot be
tested -- and a rejection rule nobody can test is a rule nobody can trust to
reject. tests/prevent-unusual-unicode-in-files-test.py exercises both
directions of both modes, including the cases where the two modes disagree.

Usage:
  prevent-unusual-unicode-in-files.py [COMMIT_MSG_FILE]
  prevent-unusual-unicode-in-files.py --files PATH [PATH ...]

Called natively by git's commit-msg hook, the message file arrives as argv[1].
Called through prek, which forwards no argument, it falls back to the
repository's own COMMIT_EDITMSG.
"""

from __future__ import annotations

import fnmatch
import subprocess
import sys
import threading
import unicodedata
from pathlib import Path
from typing import TYPE_CHECKING, NamedTuple

if TYPE_CHECKING:
    from collections.abc import Callable, Iterator, Sequence

#: The shared answer to "which bytes is this operation introducing", resolved
#: from this file's own directory rather than from $PWD: a hook runner copies
#: the whole hook repository into its cache and runs the entry from there, so
#: the two files travel together while $PWD is somebody else's checkout.
#:
#: It is a shell script called from Python, which is worth a sentence. The
#: alternative is a second implementation of the rule in a second language, and
#: the reason this file exists at all is that two implementations of one rule
#: were disagreeing about which tree to read -- each wrong, in its own way, and
#: each green. A subprocess is the cheap price of there being one answer.
SCOPE_TOOL = Path(__file__).resolve().parent / "git-guards-scope.sh"

# Curated non-ASCII characters that belong in this repo's commit messages.
CURATED = frozenset(
    "¢£¤¥€"  # currency: cent pound currency yen euro
    "©®™"  # copyright registered trademark
    "°±"  # degree plus-minus
    "–—"  # en dash, em dash
    "…"  # ellipsis
    "‰"  # per mille
    "“”‘’"  # smart quotes
    "←↑→↓"  # arrows
    "✓✗"  # check and ballot marks (common in CI output)
    "×÷"  # multiplication, division
    "≤≥"  # less-or-equal, greater-or-equal
)

ALLOWED_CATEGORIES = frozenset("LNMZ")

#: Mode 2. Why each class is refused in a file, keyed by Unicode category. The
#: reason travels with the finding: a reviewer who cannot see the character has
#: nothing else to go on, and "unusual Unicode" is not a diagnosis.
INVISIBLE_CATEGORIES: dict[str, str] = {
    "Cc": "control character (a stray CR, an escape, a bell)",
    "Cf": "format character -- zero-width or bidirectional, invisible to a reviewer",
    "Co": "private-use codepoint -- renders differently for everyone who opens it",
    "Cs": "surrogate -- cannot occur in well-formed text",
    "Cn": "unassigned codepoint",
    "Zs": "a space that is not U+0020 -- looks like a space, is not one",
    "Zl": "line separator -- splits the line for some readers and not others",
    "Zp": "paragraph separator -- splits the text for some readers and not others",
}

#: The two characters in those categories that every file may hold.
FILE_EXEMPT = frozenset("\t\n")

#: Unicode's Default_Ignorable_Code_Point property, copied row for row from
#: DerivedCoreProperties.txt (Unicode 15.1, the version Python 3.13 carries).
#: A table rather than a query because `unicodedata` exposes CATEGORIES and not
#: properties, and this is the one property whose definition is already the
#: sentence this rule wants: a conforming renderer is told to display nothing
#: for these. Most rows are Cc/Cf/Cn and duplicate a category refused above --
#: they are kept anyway, because the table's value is that it can be diffed
#: against the file it came from, and a table with the boring rows deleted
#: cannot be. The rows that are NOT duplicates are the whole reason it exists:
#: 034F, 115F..1160, 17B4..17B5, 180B..180D, 180F, 3164, FE00..FE0F, FFA0 and
#: E0100..E01EF are `Lo` and `Mn`, which is to say letters and marks that draw
#: nothing, which is to say the characters no category test can reach.
DEFAULT_IGNORABLE_RANGES: tuple[tuple[int, int], ...] = (
    (0x00AD, 0x00AD),  # SOFT HYPHEN
    (0x034F, 0x034F),  # COMBINING GRAPHEME JOINER
    (0x061C, 0x061C),  # ARABIC LETTER MARK
    (0x115F, 0x1160),  # HANGUL CHOSEONG FILLER, HANGUL JUNGSEONG FILLER
    (0x17B4, 0x17B5),  # KHMER VOWEL INHERENT AQ, AA
    (0x180B, 0x180D),  # MONGOLIAN FREE VARIATION SELECTOR ONE..THREE
    (0x180E, 0x180E),  # MONGOLIAN VOWEL SEPARATOR
    (0x180F, 0x180F),  # MONGOLIAN FREE VARIATION SELECTOR FOUR
    (0x200B, 0x200F),  # ZERO WIDTH SPACE..RIGHT-TO-LEFT MARK
    (0x202A, 0x202E),  # LEFT-TO-RIGHT EMBEDDING..RIGHT-TO-LEFT OVERRIDE
    (0x2060, 0x2064),  # WORD JOINER..INVISIBLE PLUS
    (0x2065, 0x2065),  # reserved
    (0x2066, 0x206F),  # LEFT-TO-RIGHT ISOLATE..NOMINAL DIGIT SHAPES
    (0x3164, 0x3164),  # HANGUL FILLER
    (0xFE00, 0xFE0F),  # VARIATION SELECTOR-1..16
    (0xFEFF, 0xFEFF),  # ZERO WIDTH NO-BREAK SPACE (the BOM)
    (0xFFA0, 0xFFA0),  # HALFWIDTH HANGUL FILLER
    (0xFFF0, 0xFFF8),  # reserved
    (0x1BCA0, 0x1BCA3),  # SHORTHAND FORMAT LETTER OVERLAP..UP STEP
    (0x1D173, 0x1D17A),  # MUSICAL SYMBOL BEGIN BEAM..END PHRASE
    (0xE0000, 0xE0FFF),  # the tag block: LANGUAGE TAG, TAG SPACE..CANCEL TAG,
    #                      VARIATION SELECTOR-17..256, and its reserved tail
)

#: Expanded once, at import. Four thousand-odd codepoints, 3,600 of them the
#: reserved tail of the tag block, in exchange for a membership test that costs
#: a hash lookup -- which is what a hook reading every character of every tracked
#: file should be paying, rather than a walk over twenty-one ranges per character.
DEFAULT_IGNORABLE = frozenset(
    cp for lo, hi in DEFAULT_IGNORABLE_RANGES for cp in range(lo, hi + 1)
)

#: The variation selectors, which are in that table and are not refused outright
#: -- see the module docstring for why. They are one PROPERTY and four FAMILIES,
#: and the families are what the rule asks about, because each one selects among
#: the alternate forms of a different kind of character. Asking a single question
#: for all 260 answers none of them.
VARIATION_SELECTORS = frozenset(
    (*range(0x180B, 0x180E), 0x180F, *range(0xFE00, 0xFE10), *range(0xE0100, 0xE01F0))
)

#: U+FE0E TEXT and U+FE0F EMOJI presentation: the two that ask a question about
#: presentation, and the only two a keycap can be spelled with.
EMOJI_PRESENTATION_SELECTORS = frozenset({0xFE0E, 0xFE0F})

#: U+FE00..U+FE0D. The standardized variation sequences that are not about
#: emoji: the CJK ones a repository actually commits, and a handful of
#: mathematical forms it does not. They get the ideograph question, and --allow
#: is the declared door for the rest -- see the module docstring.
OTHER_STANDARDIZED_SELECTORS = frozenset(range(0xFE00, 0xFE0E))

#: U+E0100..U+E01EF, the ideographic variation selectors -- 240 of the 260, and
#: the reason "is the character in front of it visible" was never the question.
IDEOGRAPHIC_VARIATION_SELECTORS = frozenset(range(0xE0100, 0xE01F0))

#: Mongolian's free variation selectors, spelled differently and doing the same
#: job for the forms of a Mongolian letter.
MONGOLIAN_VARIATION_SELECTORS = frozenset((*range(0x180B, 0x180E), 0x180F))

#: The base characters that HAVE an emoji presentation: the 354 bases of the
#: standardized emoji variation sequences, copied row for row from
#: emoji-variation-sequences.txt (Emoji 14.0) and collapsed to ranges in
#: codepoint order so it can still be diffed against the file it came from.
#:
#: A table because there is no other way to ask. `unicodedata` exposes
#: CATEGORIES, not emoji properties, and the category cannot tell these apart:
#: U+26A0 WARNING SIGN and U+2705 WHITE HEAVY CHECK MARK are both `So`, and
#: U+FE0F after the first selects between a presentation the reader can see two
#: of, while after the second it selects nothing -- the check mark has only ever
#: been drawn one way. Refusing the second is not pedantry: it is the difference
#: between a carve-out worth 354 carriers and one worth 149,262.
EMOJI_VARIATION_BASE_RANGES: tuple[tuple[int, int], ...] = (
    (0x0023, 0x0023),  # NUMBER SIGN
    (0x002A, 0x002A),  # ASTERISK
    (0x0030, 0x0039),  # DIGIT ZERO..DIGIT NINE
    (0x00A9, 0x00A9),  # COPYRIGHT SIGN
    (0x00AE, 0x00AE),  # REGISTERED SIGN
    (0x203C, 0x203C),  # DOUBLE EXCLAMATION MARK
    (0x2049, 0x2049),  # EXCLAMATION QUESTION MARK
    (0x2122, 0x2122),  # TRADE MARK SIGN
    (0x2139, 0x2139),  # INFORMATION SOURCE
    (0x2194, 0x2199),  # LEFT RIGHT ARROW..SOUTH WEST ARROW
    (0x21A9, 0x21AA),  # LEFTWARDS ARROW WITH HOOK..RIGHTWARDS ARROW WITH HOOK
    (0x231A, 0x231B),  # WATCH..HOURGLASS
    (0x2328, 0x2328),  # KEYBOARD
    (0x23CF, 0x23CF),  # EJECT SYMBOL
    (0x23E9, 0x23EA),  # BLACK RIGHT-POINTING DOUBLE TRIANGLE..BLACK LEFT-POINTING DOUBLE TRIANGLE
    (0x23ED, 0x23EF),  # BLACK RIGHT-POINTING DOUBLE TRIANGLE WITH VERTICAL BAR..BLACK RIGHT-POINTING TRIANGLE WITH DOUBLE VERTICAL BAR
    (0x23F1, 0x23F3),  # STOPWATCH..HOURGLASS WITH FLOWING SAND
    (0x23F8, 0x23FA),  # DOUBLE VERTICAL BAR..BLACK CIRCLE FOR RECORD
    (0x24C2, 0x24C2),  # CIRCLED LATIN CAPITAL LETTER M
    (0x25AA, 0x25AB),  # BLACK SMALL SQUARE..WHITE SMALL SQUARE
    (0x25B6, 0x25B6),  # BLACK RIGHT-POINTING TRIANGLE
    (0x25C0, 0x25C0),  # BLACK LEFT-POINTING TRIANGLE
    (0x25FB, 0x25FE),  # WHITE MEDIUM SQUARE..BLACK MEDIUM SMALL SQUARE
    (0x2600, 0x2604),  # BLACK SUN WITH RAYS..COMET
    (0x260E, 0x260E),  # BLACK TELEPHONE
    (0x2611, 0x2611),  # BALLOT BOX WITH CHECK
    (0x2614, 0x2615),  # UMBRELLA WITH RAIN DROPS..HOT BEVERAGE
    (0x2618, 0x2618),  # SHAMROCK
    (0x261D, 0x261D),  # WHITE UP POINTING INDEX
    (0x2620, 0x2620),  # SKULL AND CROSSBONES
    (0x2622, 0x2623),  # RADIOACTIVE SIGN..BIOHAZARD SIGN
    (0x2626, 0x2626),  # ORTHODOX CROSS
    (0x262A, 0x262A),  # STAR AND CRESCENT
    (0x262E, 0x262F),  # PEACE SYMBOL..YIN YANG
    (0x2638, 0x263A),  # WHEEL OF DHARMA..WHITE SMILING FACE
    (0x2640, 0x2640),  # FEMALE SIGN
    (0x2642, 0x2642),  # MALE SIGN
    (0x2648, 0x2653),  # ARIES..PISCES
    (0x265F, 0x2660),  # BLACK CHESS PAWN..BLACK SPADE SUIT
    (0x2663, 0x2663),  # BLACK CLUB SUIT
    (0x2665, 0x2666),  # BLACK HEART SUIT..BLACK DIAMOND SUIT
    (0x2668, 0x2668),  # HOT SPRINGS
    (0x267B, 0x267B),  # BLACK UNIVERSAL RECYCLING SYMBOL
    (0x267E, 0x267F),  # PERMANENT PAPER SIGN..WHEELCHAIR SYMBOL
    (0x2692, 0x2697),  # HAMMER AND PICK..ALEMBIC
    (0x2699, 0x2699),  # GEAR
    (0x269B, 0x269C),  # ATOM SYMBOL..FLEUR-DE-LIS
    (0x26A0, 0x26A1),  # WARNING SIGN..HIGH VOLTAGE SIGN
    (0x26A7, 0x26A7),  # MALE WITH STROKE AND MALE AND FEMALE SIGN
    (0x26AA, 0x26AB),  # MEDIUM WHITE CIRCLE..MEDIUM BLACK CIRCLE
    (0x26B0, 0x26B1),  # COFFIN..FUNERAL URN
    (0x26BD, 0x26BE),  # SOCCER BALL..BASEBALL
    (0x26C4, 0x26C5),  # SNOWMAN WITHOUT SNOW..SUN BEHIND CLOUD
    (0x26C8, 0x26C8),  # THUNDER CLOUD AND RAIN
    (0x26CF, 0x26CF),  # PICK
    (0x26D1, 0x26D1),  # HELMET WITH WHITE CROSS
    (0x26D3, 0x26D4),  # CHAINS..NO ENTRY
    (0x26E9, 0x26EA),  # SHINTO SHRINE..CHURCH
    (0x26F0, 0x26F5),  # MOUNTAIN..SAILBOAT
    (0x26F7, 0x26FA),  # SKIER..TENT
    (0x26FD, 0x26FD),  # FUEL PUMP
    (0x2702, 0x2702),  # BLACK SCISSORS
    (0x2708, 0x2709),  # AIRPLANE..ENVELOPE
    (0x270C, 0x270D),  # VICTORY HAND..WRITING HAND
    (0x270F, 0x270F),  # PENCIL
    (0x2712, 0x2712),  # BLACK NIB
    (0x2714, 0x2714),  # HEAVY CHECK MARK
    (0x2716, 0x2716),  # HEAVY MULTIPLICATION X
    (0x271D, 0x271D),  # LATIN CROSS
    (0x2721, 0x2721),  # STAR OF DAVID
    (0x2733, 0x2734),  # EIGHT SPOKED ASTERISK..EIGHT POINTED BLACK STAR
    (0x2744, 0x2744),  # SNOWFLAKE
    (0x2747, 0x2747),  # SPARKLE
    (0x2753, 0x2753),  # BLACK QUESTION MARK ORNAMENT
    (0x2757, 0x2757),  # HEAVY EXCLAMATION MARK SYMBOL
    (0x2763, 0x2764),  # HEAVY HEART EXCLAMATION MARK ORNAMENT..HEAVY BLACK HEART
    (0x27A1, 0x27A1),  # BLACK RIGHTWARDS ARROW
    (0x2934, 0x2935),  # ARROW POINTING RIGHTWARDS THEN CURVING UPWARDS..ARROW POINTING RIGHTWARDS THEN CURVING DOWNWARDS
    (0x2B05, 0x2B07),  # LEFTWARDS BLACK ARROW..DOWNWARDS BLACK ARROW
    (0x2B1B, 0x2B1C),  # BLACK LARGE SQUARE..WHITE LARGE SQUARE
    (0x2B50, 0x2B50),  # WHITE MEDIUM STAR
    (0x2B55, 0x2B55),  # HEAVY LARGE CIRCLE
    (0x3030, 0x3030),  # WAVY DASH
    (0x303D, 0x303D),  # PART ALTERNATION MARK
    (0x3297, 0x3297),  # CIRCLED IDEOGRAPH CONGRATULATION
    (0x3299, 0x3299),  # CIRCLED IDEOGRAPH SECRET
    (0x1F004, 0x1F004),  # MAHJONG TILE RED DRAGON
    (0x1F170, 0x1F171),  # NEGATIVE SQUARED LATIN CAPITAL LETTER A..NEGATIVE SQUARED LATIN CAPITAL LETTER B
    (0x1F17E, 0x1F17F),  # NEGATIVE SQUARED LATIN CAPITAL LETTER O..NEGATIVE SQUARED LATIN CAPITAL LETTER P
    (0x1F202, 0x1F202),  # SQUARED KATAKANA SA
    (0x1F21A, 0x1F21A),  # SQUARED CJK UNIFIED IDEOGRAPH-7121
    (0x1F22F, 0x1F22F),  # SQUARED CJK UNIFIED IDEOGRAPH-6307
    (0x1F237, 0x1F237),  # SQUARED CJK UNIFIED IDEOGRAPH-6708
    (0x1F30D, 0x1F30F),  # EARTH GLOBE EUROPE-AFRICA..EARTH GLOBE ASIA-AUSTRALIA
    (0x1F315, 0x1F315),  # FULL MOON SYMBOL
    (0x1F31C, 0x1F31C),  # LAST QUARTER MOON WITH FACE
    (0x1F321, 0x1F321),  # THERMOMETER
    (0x1F324, 0x1F32C),  # WHITE SUN WITH SMALL CLOUD..WIND BLOWING FACE
    (0x1F336, 0x1F336),  # HOT PEPPER
    (0x1F378, 0x1F378),  # COCKTAIL GLASS
    (0x1F37D, 0x1F37D),  # FORK AND KNIFE WITH PLATE
    (0x1F393, 0x1F393),  # GRADUATION CAP
    (0x1F396, 0x1F397),  # MILITARY MEDAL..REMINDER RIBBON
    (0x1F399, 0x1F39B),  # STUDIO MICROPHONE..CONTROL KNOBS
    (0x1F39E, 0x1F39F),  # FILM FRAMES..ADMISSION TICKETS
    (0x1F3A7, 0x1F3A7),  # HEADPHONE
    (0x1F3AC, 0x1F3AE),  # CLAPPER BOARD..VIDEO GAME
    (0x1F3C2, 0x1F3C2),  # SNOWBOARDER
    (0x1F3C4, 0x1F3C4),  # SURFER
    (0x1F3C6, 0x1F3C6),  # TROPHY
    (0x1F3CA, 0x1F3CE),  # SWIMMER..RACING CAR
    (0x1F3D4, 0x1F3E0),  # SNOW CAPPED MOUNTAIN..HOUSE BUILDING
    (0x1F3ED, 0x1F3ED),  # FACTORY
    (0x1F3F3, 0x1F3F3),  # WAVING WHITE FLAG
    (0x1F3F5, 0x1F3F5),  # ROSETTE
    (0x1F3F7, 0x1F3F7),  # LABEL
    (0x1F408, 0x1F408),  # CAT
    (0x1F415, 0x1F415),  # DOG
    (0x1F41F, 0x1F41F),  # FISH
    (0x1F426, 0x1F426),  # BIRD
    (0x1F43F, 0x1F43F),  # CHIPMUNK
    (0x1F441, 0x1F442),  # EYE..EAR
    (0x1F446, 0x1F449),  # WHITE UP POINTING BACKHAND INDEX..WHITE RIGHT POINTING BACKHAND INDEX
    (0x1F44D, 0x1F44E),  # THUMBS UP SIGN..THUMBS DOWN SIGN
    (0x1F453, 0x1F453),  # EYEGLASSES
    (0x1F46A, 0x1F46A),  # FAMILY
    (0x1F47D, 0x1F47D),  # EXTRATERRESTRIAL ALIEN
    (0x1F4A3, 0x1F4A3),  # BOMB
    (0x1F4B0, 0x1F4B0),  # MONEY BAG
    (0x1F4B3, 0x1F4B3),  # CREDIT CARD
    (0x1F4BB, 0x1F4BB),  # PERSONAL COMPUTER
    (0x1F4BF, 0x1F4BF),  # OPTICAL DISC
    (0x1F4CB, 0x1F4CB),  # CLIPBOARD
    (0x1F4DA, 0x1F4DA),  # BOOKS
    (0x1F4DF, 0x1F4DF),  # PAGER
    (0x1F4E4, 0x1F4E6),  # OUTBOX TRAY..PACKAGE
    (0x1F4EA, 0x1F4ED),  # CLOSED MAILBOX WITH LOWERED FLAG..OPEN MAILBOX WITH LOWERED FLAG
    (0x1F4F7, 0x1F4F7),  # CAMERA
    (0x1F4F9, 0x1F4FB),  # VIDEO CAMERA..RADIO
    (0x1F4FD, 0x1F4FD),  # FILM PROJECTOR
    (0x1F508, 0x1F508),  # SPEAKER
    (0x1F50D, 0x1F50D),  # LEFT-POINTING MAGNIFYING GLASS
    (0x1F512, 0x1F513),  # LOCK..OPEN LOCK
    (0x1F549, 0x1F54A),  # OM SYMBOL..DOVE OF PEACE
    (0x1F550, 0x1F567),  # CLOCK FACE ONE OCLOCK..CLOCK FACE TWELVE-THIRTY
    (0x1F56F, 0x1F570),  # CANDLE..MANTELPIECE CLOCK
    (0x1F573, 0x1F579),  # HOLE..JOYSTICK
    (0x1F587, 0x1F587),  # LINKED PAPERCLIPS
    (0x1F58A, 0x1F58D),  # LOWER LEFT BALLPOINT PEN..LOWER LEFT CRAYON
    (0x1F590, 0x1F590),  # RAISED HAND WITH FINGERS SPLAYED
    (0x1F5A5, 0x1F5A5),  # DESKTOP COMPUTER
    (0x1F5A8, 0x1F5A8),  # PRINTER
    (0x1F5B1, 0x1F5B2),  # THREE BUTTON MOUSE..TRACKBALL
    (0x1F5BC, 0x1F5BC),  # FRAME WITH PICTURE
    (0x1F5C2, 0x1F5C4),  # CARD INDEX DIVIDERS..FILE CABINET
    (0x1F5D1, 0x1F5D3),  # WASTEBASKET..SPIRAL CALENDAR PAD
    (0x1F5DC, 0x1F5DE),  # COMPRESSION..ROLLED-UP NEWSPAPER
    (0x1F5E1, 0x1F5E1),  # DAGGER KNIFE
    (0x1F5E3, 0x1F5E3),  # SPEAKING HEAD IN SILHOUETTE
    (0x1F5E8, 0x1F5E8),  # LEFT SPEECH BUBBLE
    (0x1F5EF, 0x1F5EF),  # RIGHT ANGER BUBBLE
    (0x1F5F3, 0x1F5F3),  # BALLOT BOX WITH BALLOT
    (0x1F5FA, 0x1F5FA),  # WORLD MAP
    (0x1F610, 0x1F610),  # NEUTRAL FACE
    (0x1F687, 0x1F687),  # METRO
    (0x1F68D, 0x1F68D),  # ONCOMING BUS
    (0x1F691, 0x1F691),  # AMBULANCE
    (0x1F694, 0x1F694),  # ONCOMING POLICE CAR
    (0x1F698, 0x1F698),  # ONCOMING AUTOMOBILE
    (0x1F6AD, 0x1F6AD),  # NO SMOKING SYMBOL
    (0x1F6B2, 0x1F6B2),  # BICYCLE
    (0x1F6B9, 0x1F6BA),  # MENS SYMBOL..WOMENS SYMBOL
    (0x1F6BC, 0x1F6BC),  # BABY SYMBOL
    (0x1F6CB, 0x1F6CB),  # COUCH AND LAMP
    (0x1F6CD, 0x1F6CF),  # SHOPPING BAGS..BED
    (0x1F6E0, 0x1F6E5),  # HAMMER AND WRENCH..MOTOR BOAT
    (0x1F6E9, 0x1F6E9),  # SMALL AIRPLANE
    (0x1F6F0, 0x1F6F0),  # SATELLITE
    (0x1F6F3, 0x1F6F3),  # PASSENGER SHIP
)

#: Expanded once, at import, for the same reason DEFAULT_IGNORABLE is.
EMOJI_VARIATION_BASES = frozenset(
    cp for lo, hi in EMOJI_VARIATION_BASE_RANGES for cp in range(lo, hi + 1)
)

#: A character whose glyph is blank though nothing about its classification says
#: so. One entry, and it needs its own name because there is no category for
#: "a font draws nothing here": U+2800 is `So`, filed beside every emoji, and it
#: is the Braille cell with no raised dots. It is the character behind the
#: filenames and display names that appear to have no text in them at all.
BLANK_GLYPHS = frozenset({0x2800})

#: The mark that finishes a keycap sequence, and the reason a keycap base on its
#: own is not enough. `1<VS16><U+20E3>` is how the keycap emoji is written down;
#: `1<VS16>` is a digit followed by a codepoint nobody can see, and there is no
#: second way to draw a digit for that selector to have chosen -- so it renders
#: as nothing and changes nothing, which is the sentence this whole class is
#: refused by. A digit is in every file of every repository, in a version
#: string, a port number, a timestamp, a hash; so a carve-out that stops at the
#: base hands back twelve carriers and every one of the 260 selectors through
#: each of them, in the files where a smuggled codepoint does the most damage.
#: `port: 80<VS16>80` and a commit subject reading `bump to v1<VS16>.3.0` are
#: what that looks like written down.
#:
#: Written as an escape, like every other invisible codepoint named in this
#: repository: a literal U+20E3 here is one formatter run away from being
#: stripped, and the carve-out would then quietly stop admitting the one
#: sequence it exists to admit.
KEYCAP_COMBINING_MARK = "\u20e3"

#: The selector a keycap is spelled with. U+FE0F asks for the emoji
#: presentation, which is what a keycap IS; U+FE0E asks for the text one, which
#: is a digit drawn as a digit and therefore no keycap at all. So `1<U+FE0E>`
#: and `1<U+E0100>` are refused however the rest of the line continues, even
#: though `1` is a keycap base.
KEYCAP_PRESENTATION_SELECTOR = "\ufe0f"


def renders_as_nothing(char: str) -> bool:
    """Does this character put no ink on the page?

    The question both modes share, asked bluntly: U+0020 puts no ink on the page
    either, and this says so rather than pretending otherwise. What to tolerate
    is each mode's decision, made by its own caller -- a file tolerates a space,
    a tab and a newline, and nothing else that draws nothing.
    """
    cp = ord(char)
    if cp in DEFAULT_IGNORABLE or cp in BLANK_GLYPHS:
        return True
    return unicodedata.category(char) in INVISIBLE_CATEGORIES


def is_ideograph(char: str) -> bool:
    """Is this a CJK ideograph -- the thing an ideographic selector selects for?

    Asked of Unicode's own name for the character rather than of a range table,
    because the names are generated from the same UCD the interpreter ships and
    a hand-copied list of the ideograph blocks is a list that goes stale one
    Unicode release later, silently and in the permissive direction. Both
    spellings count: a variation sequence may be registered against a unified
    ideograph or a compatibility one.

    It costs a name lookup, which is affordable because nothing asks unless a
    variation selector has actually been found -- and outside CJK text with
    registered glyph variants, that is nothing at all.
    """
    return unicodedata.name(char, "").startswith(
        ("CJK UNIFIED IDEOGRAPH-", "CJK COMPATIBILITY IDEOGRAPH-")
    )


def is_mongolian(char: str) -> bool:
    """Is this a Mongolian character -- what a free variation selector acts on?

    Same reasoning, and the same source, as is_ideograph().
    """
    return unicodedata.name(char, "").startswith("MONGOLIAN ")


def selects_an_actual_alternative(
    previous: str, selector: str, following: str = ""
) -> bool:
    """Does this variation selector choose between forms that genuinely exist?

    The carve-out, and the whole of it. A selector is legal only where it is
    doing its job, and that is not one question -- it is one question per
    FAMILY, because each family selects among the alternate forms of a different
    kind of character. "Is the character in front of it visible" is not any of
    them: it admits 149,262 carriers for U+FE0F, and it hands the ideographic
    selectors 50,580 carriers that are not ideographs and never had a second
    glyph form for anything to choose between.

    Something has to be in front of it either way. `previous` is the empty
    string at the start of a line, which is exactly what a selector opening a
    line has to work with, and a selector after a space is refused for the same
    reason -- a space draws nothing, so choosing how it is drawn shows the
    reader nothing.

    Then, per family:

      * an EMOJI presentation selector (U+FE0E, U+FE0F) needs a base that has
        both presentations. U+26A0 does; U+1F680 ROCKET and the Latin letter `u`
        do not, so `user<VS16>name` reads as `username` to every reviewer and is
        a different string to every parser.
      * an IDEOGRAPHIC selector (U+E0100..U+E01EF) needs an ideograph.
      * a MONGOLIAN free variation selector needs a Mongolian letter.
      * the remaining standardized selectors (U+FE00..U+FE0D) need an ideograph
        too -- see the module docstring for where that boundary is drawn and how
        a repository declares its way past it.

    The twelve keycap bases are in the emoji table, so ASCII needs the extra
    condition: a keycap is three codepoints and the exception is the WHOLE
    SEQUENCE, which is why this asks for `selector` and `following` as well.
    `port: 80<VS16>80` is a base with no enclosing mark after it and is not a
    keycap.

    `following` defaults to the empty string for the same reason `previous`
    does: a caller with no context to offer gets the stricter answer, and a
    selector at the end of a line has nothing after it to complete a keycap.
    """
    if previous == "" or renders_as_nothing(previous):
        return False
    base = ord(previous)
    family = ord(selector)

    if family in EMOJI_PRESENTATION_SELECTORS:
        if base not in EMOJI_VARIATION_BASES:
            return False
        if base > 0x7F:
            return True
        # The only ASCII bases in the emoji table are the twelve keycap bases,
        # and a bare one of those is the carrier that appears in every file of
        # every repository. Nothing licenses it but the finished sequence.
        return (
            selector == KEYCAP_PRESENTATION_SELECTOR
            and following == KEYCAP_COMBINING_MARK
        )

    if family in IDEOGRAPHIC_VARIATION_SELECTORS:
        return is_ideograph(previous)

    if family in MONGOLIAN_VARIATION_SELECTORS:
        return is_mongolian(previous)

    return is_ideograph(previous)


def visible_in_a_file(char: str, previous: str = "", following: str = "") -> bool:
    """Is this character something a reader of the file can actually see?

    The mode-2 rule. Note what it does NOT ask: whether the character is
    unusual, or non-ASCII, or one somebody likes. A file may hold any visible
    character; what it may not hold is one that hides.

    `previous` and `following` both default to the empty string so that asking
    about a character on its own answers the stricter question -- a lone
    variation selector is an offender, and a caller that has no context to offer
    gets that answer rather than the permissive one.
    """
    if char in FILE_EXEMPT or char == " ":
        return True
    if ord(char) in VARIATION_SELECTORS:
        return selects_an_actual_alternative(previous, char, following)
    return not renders_as_nothing(char)


def allowed(char: str, previous: str = "", following: str = "") -> bool:
    """Is this character permitted in a commit message?"""
    if char in FILE_EXEMPT or char == " ":
        return True
    # The SAME invisible test mode 2 asks, asked BEFORE the whitelist, because
    # the whitelist cannot answer it. The Hangul fillers are `Lo`, the combining
    # grapheme joiner is `Mn`, and every non-breaking and ideographic space is
    # `Zs`, so `L* N* M* Z*` admits all of them on exactly the grounds it admits
    # a kanji: their category describes what they ARE and not what a reader
    # sees, and for this class those two answers are opposites.
    #
    # Deliberately not a narrower test than mode 2's. A subject line cannot be
    # corrected once it is published, so the mode that gets one attempt is not
    # the mode to be lenient in: U+2028 LINE SEPARATOR draws nothing AND splits
    # the line, and a whitelist by category called it a separator and let it go.
    if renders_as_nothing(char):
        return ord(char) in VARIATION_SELECTORS and selects_an_actual_alternative(
            previous, char, following
        )
    if 0x20 <= ord(char) <= 0x7E:
        return True
    if char in CURATED:
        return True
    return unicodedata.category(char)[0] in ALLOWED_CATEGORIES


class Offender:
    """One disallowed character, with everything needed to name it."""

    def __init__(self, line: int, col: int, char: str) -> None:
        self.line = line
        self.col = col
        self.char = char
        self.codepoint = ord(char)
        self.category = unicodedata.category(char)
        self.name = unicodedata.name(char, "UNKNOWN")

    def reason(self) -> str:
        """Why this character is refused, in words a reviewer can act on.

        Ordered most specific first. A zero-width space is both `Cf` and
        Default_Ignorable, and the category has the more useful sentence.
        """
        if self.codepoint in VARIATION_SELECTORS:
            # Deliberately not "nothing in front of it": the commoner shape is a
            # selector in front of a character that IS there and still has no
            # second form for this selector to choose -- a Latin letter, a
            # fullwidth digit, an emoji that has only ever been drawn one way,
            # an ideographic selector after something that is not an ideograph.
            # Every one of those is the same finding and gets the same sentence:
            # it drew nothing and it chose nothing.
            return (
                "a variation selector with nothing in front of it that it can "
                "select a form of -- it changes nothing and shows nothing"
            )
        if self.category in INVISIBLE_CATEGORIES:
            return INVISIBLE_CATEGORIES[self.category]
        if self.codepoint in DEFAULT_IGNORABLE:
            return (
                "default-ignorable -- Unicode's own name for a codepoint drawn as "
                "nothing, whatever its category says it is"
            )
        if self.codepoint in BLANK_GLYPHS:
            return "a symbol drawn as blank space -- it takes width and shows nothing"
        return "not permitted in a file"

    def describe(self) -> str:
        # A character that draws nothing has no glyph to show, so name its
        # codepoint instead of printing something invisible. The question is
        # whether it RENDERS as nothing rather than whether its category begins
        # with C, because U+3164 HANGUL FILLER is an `Lo` that draws nothing and
        # quoting it here would quote the empty string.
        shown = (
            f"U+{self.codepoint:04X}"
            if renders_as_nothing(self.char)
            else f"'{self.char}'"
        )
        return (
            f"  line {self.line}, col {self.col}: {shown}  "
            f"U+{self.codepoint:04X}  {self.category}  {self.name}"
        )

    def describe_in_file(self, path: Path, where: str = "") -> str:
        # file:line:col, so the finding is clickable. An invisible character is
        # never shown as a glyph here: printing nothing at the point of the
        # complaint is how a reviewer concludes the checker is broken.
        #
        # `where` names the part of the entry the offender was found in, and it
        # goes before the reason rather than after it so that the sentence still
        # ends on the reason. It is used for a symlink, whose committed content
        # is its target path: `link:1:2` looks like a complaint about a file the
        # reader would then open and find nothing wrong with.
        return (
            f"{path}:{self.line}:{self.col}: U+{self.codepoint:04X} "
            f"{self.name} ({self.category}){where} -- {self.reason()}"
        )


def _scan(text: str, permitted: Callable[[str, str, str], bool]) -> list[Offender]:
    # The character BEFORE each one travels with it, because one clause of the
    # rule is about a PAIR: a variation selector is legal after a character with
    # an alternate presentation and not on its own. Column 1 gets the empty
    # string, which is what a selector opening a line actually has in front of
    # it. It is carried forward through an explicit loop rather than re-derived
    # with `line[col - 2]`, which built a fresh one-character string for every
    # character in the repository to answer a question the loop already knew.
    #
    # The character AFTER it travels with it too, because one clause is about a
    # TRIPLE: a keycap is base + U+FE0F + U+20E3, and a rule that stops at the
    # first two admits `port: 80<VS16>80`. That one is a slice rather than a
    # carried variable -- `line[col : col + 1]`, empty at the end of a line,
    # which is exactly what a selector with nothing after it has to complete a
    # keycap with. It is built only for characters that reach `permitted`, and
    # the ASCII test below means almost nothing does.
    #
    # The ASCII test in front of `permitted` is what lets this hook read every
    # tracked file on every commit. Almost every character in almost every
    # repository is printable ASCII, and both modes say yes to all of them
    # unconditionally -- mode 1 returns True for 0x20..0x7E before it consults
    # anything else, and mode 2 finds them visible -- so calling out to decide
    # that again is the entire cost of the scan. Measured on a 698-file
    # repository, best of three: 5.88s without this line and 1.20s with it, and
    # the same 31 findings either way. A guard that runs on every commit is a
    # guard somebody eventually comments out if it is slow, so the number is
    # part of the rule and belongs beside it.
    #
    # Safe because it can only skip characters both modes ALREADY permit. A
    # declared --allow can grant a character, never revoke one, so no allowance
    # can turn a printable ASCII character into a finding.
    offenders: list[Offender] = []
    for lineno, line in enumerate(text.split("\n"), start=1):
        previous = ""
        for col, char in enumerate(line, start=1):
            if not (" " <= char <= "~") and not permitted(
                char, previous, line[col : col + 1]
            ):
                offenders.append(Offender(lineno, col, char))
            previous = char
    return offenders


def find_offenders(message: str) -> list[Offender]:
    """Mode 1: the commit-message whitelist."""
    return _scan(message, allowed)


def find_file_offenders(text: str, allowed: frozenset[str] = frozenset()) -> list[Offender]:
    """Mode 2: the invisible-and-deceptive class, in file content.

    `allowed` is the repository's DECLARED exceptions. It exists because the
    class this mode bans is defined by Unicode category, and one category has a
    member that is data rather than deception: U+3000 IDEOGRAPHIC SPACE is `Zs`,
    and a codebase that parses Japanese documents carries it in string literals
    it matches against source text and in fixtures reproducing what an upstream
    actually emitted.

    Forcing those to `\u3000` escapes would make the character invisible to a
    reviewer, which is the outcome this rule exists to prevent -- so the ban
    would have produced the harm it names. An allowance is per repository,
    declared in the hook invocation where a reviewer reads it in a diff, and
    never a default: in a YAML key or an identifier the same codepoint IS the
    confusable-space attack.

    The same door opens for the invisible LETTERS this mode also refuses:
    U+1160 HANGUL JUNGSEONG FILLER is how a Korean syllable with no vowel is
    written down, so a repository that processes Hangul jamo declares it and
    everybody else keeps the ban.
    """
    return _scan(
        text,
        lambda ch, prev, nxt: ch in allowed or visible_in_a_file(ch, prev, nxt),
    )


def default_message_file() -> Path | None:
    """prek forwards no path; fall back to git's own commit message file."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--git-dir"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    candidate = Path(out.stdout.strip()) / "COMMIT_EDITMSG"
    return candidate if candidate.is_file() else None


def resolve_message_file(argv: list[str]) -> Path | None:
    if argv:
        given = Path(argv[0])
        if given.is_file():
            return given
        # An argument that names no file is a caller bug, not a reason to go
        # looking elsewhere -- fall through only when nothing was passed.
        return None
    return default_message_file()


def repository_toplevel() -> Path | None:
    """The root of the work tree, or None if this is not one.

    `git ls-files` lists from the CURRENT directory DOWN, so running the
    tree-wide scan from a subdirectory covers a subtree and says nothing about
    the rest -- while still printing a denominator and exiting 0, which is the
    exact shape of false green this hook exists to refuse. A hook runner happens
    to invoke from the root; a person running it by hand does not.
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    top = out.stdout.strip()
    return Path(top) if top else None


#: What the resolver marks an entry with when the scope's own tree holds it.
#: Anything else is the sha of the commit that introduced the blob somewhere in
#: the pushed range, at a path the tree being pushed no longer has.
TREE_ORIGIN = ":tree"


class Entry(NamedTuple):
    """One thing to look at, and where its bytes are to be found.

    `mode` and `oid` are git's, and are None for a path named on the command
    line -- that invocation is deliberately not a git question, so it can be
    pointed at a file nobody has staged. Everything the scan decides about an
    entry is decided from the mode: 100644 and 100755 are files, 120000 is a
    SYMLINK whose blob is its target path, 160000 is a submodule gitlink with no
    blob in this repository at all.

    `origin` is `:tree` for an entry the scope's tree holds and a commit sha for
    a blob only the pushed range holds. It is carried rather than derived
    because nothing about the entry itself says which: the bytes, the mode and
    the path are identical either way, and the difference decides both what the
    finding can tell a reader to do and which half of the denominator the entry
    belongs to.
    """

    path: str
    mode: str | None
    oid: str | None
    on_disk: Path | None
    origin: str = TREE_ORIGIN


def run_scope_tool(root: Path, *args: str) -> subprocess.CompletedProcess[bytes] | None:
    if not SCOPE_TOOL.is_file():
        return None
    try:
        return subprocess.run(
            [str(SCOPE_TOOL), *args], cwd=root, capture_output=True, check=False
        )
    except OSError:
        return None


def scan_scopes(root: Path) -> list[tuple[str, str]] | None:
    """The trees to scan, each as (token, label), or None if that failed.

    One line today and a list all the same: a push is plural in git's own
    protocol, and a runner collapsing it to one pair is the runner's choice
    rather than the operation's.
    """
    done = run_scope_tool(root, "--scopes")
    if done is None or done.returncode != 0:
        return None
    scopes: list[tuple[str, str]] = []
    for line in done.stdout.decode("utf-8", "surrogateescape").splitlines():
        if not line:
            continue
        token, _, label = line.partition("\t")
        scopes.append((token, label or token))
    return scopes or None


def scope_messages(root: Path, scope: str) -> list[tuple[str, str]] | None:
    """The `(sha, message)` of every commit this push publishes, or None.

    Empty, and not None, for a scope that publishes no commit -- the index at
    pre-commit, or a scan somebody pointed at a repository by hand.

    A commit is a tree AND a message, and only the tree was ever read here. The
    message is checked by a commit-msg hook, which runs when `git commit` writes
    one -- and `git commit-tree`, a rebase, a cherry-pick, `git am`,
    `--no-verify` and a fast-forward from a hookless clone all make a commit
    without that happening. Measured: a subject line carrying U+200B rode a
    `git merge --ff-only` from a hookless clone to the remote with no override
    of any kind.

    Judged by the MESSAGE rule, not the file rule. The two are deliberately
    different -- a whitelist for a message, an invisible-character ban for file
    content -- and a message does not stop being a message because it is being
    read a stage later than usual. Applying the file rule here would be a third
    rule, agreeing with the commit-msg guard until it did not.
    """
    done = run_scope_tool(root, "--messages", scope)
    if done is None or done.returncode != 0:
        return None
    messages: list[tuple[str, str]] = []
    for raw in done.stdout.split(b"\0"):
        if not raw:
            continue
        sha, _, body = raw.partition(b"\t")
        messages.append(
            (
                sha.decode("ascii", "replace"),
                body.decode("utf-8", "surrogateescape"),
            )
        )
    return messages


def scope_entries(root: Path, scope: str) -> list[Entry] | None:
    """Everything one scope holds, or None if git could not be asked.

    Asked with -z, and the answer decoded here rather than by `text=True`, for
    one reason: without it git C-QUOTES any path it considers unusual, and a
    filename carrying U+200B is exactly such a path. It would come back as the
    literal seven characters `"a\\342\\200\\213b"`, which names no file at all,
    fails every read, and is counted a skip -- so the one filename in the
    repository built out of an invisible codepoint is the one the scan cannot
    see. With -z the bytes arrive as git stored them.

    surrogateescape because a tracked path is bytes, and a repository may hold
    one that is not UTF-8 at all. Decoding must not raise here: an undecodable
    name is a finding to report, not a reason to abandon the enumeration.
    """
    done = run_scope_tool(root, "--entries", scope)
    if done is None or done.returncode != 0:
        return None
    entries: list[Entry] = []
    for raw in done.stdout.split(b"\0"):
        if not raw:
            continue
        meta, _, path = raw.partition(b"\t")
        fields = meta.split(b" ")
        # mode, oid, origin. A record of any other shape is a resolver this
        # reader does not understand, and None here is a refusal that the caller
        # turns into "the scan did not happen" -- never an entry assembled out
        # of fields that meant something else.
        if len(fields) != 3 or not path:
            return None
        entries.append(
            Entry(
                path.decode("utf-8", "surrogateescape"),
                fields[0].decode("ascii", "replace"),
                fields[1].decode("ascii", "replace"),
                None,
                fields[2].decode("ascii", "replace"),
            )
        )
    return entries


def batched_blobs(root: Path, oids: Sequence[str]) -> Iterator[tuple[bytes | None, str]]:
    """The bytes of each oid in turn, or None and the reason there are none.

    One `git cat-file --batch` for the whole scan rather than one process per
    blob, and one blob in memory at a time rather than the tree: a repository
    where this hook's cost is worth arguing about is one where neither shortcut
    is affordable.

    The oids are fed from a thread because the process is a pipe in both
    directions. Writing them all before reading any deadlocks the moment git's
    answers fill its output buffer -- which is a tree of a few hundred files,
    not an exotic one.

    A malformed header means the stream and this loop no longer agree about
    where the next blob starts, and every entry after it would be read out of
    the middle of another file's bytes. So the desync is latched: from there on
    every remaining oid is reported unread, which is a failure apiece rather
    than a plausible-looking scan of the wrong content.
    """
    if not oids:
        return
    try:
        proc = subprocess.Popen(
            ["git", "cat-file", "--batch"],
            cwd=root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
    except OSError as exc:
        for _ in oids:
            yield None, f"could not start git cat-file ({exc})"
        return

    stdin, stdout = proc.stdin, proc.stdout
    assert stdin is not None
    assert stdout is not None

    def feed() -> None:
        try:
            for oid in oids:
                stdin.write(oid.encode("ascii") + b"\n")
            stdin.close()
        except (OSError, ValueError):
            # The reader gave up, or git died. Either way the reader is the one
            # that reports it: a message from here would arrive out of order
            # with the findings, on a thread nobody is waiting on.
            pass

    writer = threading.Thread(target=feed, daemon=True)
    writer.start()
    lost = ""
    try:
        for _ in oids:
            if lost:
                yield None, lost
                continue
            header = stdout.readline()
            if not header:
                lost = "git cat-file stopped answering"
                yield None, lost
                continue
            fields = header.decode("utf-8", "replace").split()
            if len(fields) == 2 and fields[1] == "missing":
                yield None, "git has no such object"
                continue
            if len(fields) != 3 or fields[1] != "blob":
                lost = f"git cat-file answered {header.decode('utf-8', 'replace').strip()!r}"
                yield None, lost
                continue
            try:
                size = int(fields[2])
            except ValueError:
                lost = f"git cat-file gave no readable size: {fields[2]!r}"
                yield None, lost
                continue
            data = stdout.read(size)
            stdout.read(1)
            if data is None or len(data) != size:
                lost = "git cat-file returned a short blob"
                yield None, lost
                continue
            yield data, ""
    finally:
        stdout.close()
        writer.join(timeout=5)
        proc.wait()


#: What a byte stream turned out to be, when it did not turn out to be text.
#: The distinction is the whole of finding "it could not be read" versus
#: "there was nothing to read": a PNG holds no line for a codepoint to hide in,
#: and a file that is text everywhere except one byte holds a great many.
BINARY = "binary"

#: Byte-order marks that announce an encoding this scan can still read. A
#: UTF-16 file is full of NUL bytes and would otherwise be dismissed as binary,
#: taking its content out of the scan while looking exactly like a skipped
#: image. The UTF-32 marks are listed FIRST because the little-endian one starts
#: with the UTF-16 little-endian one, and testing in the other order decodes a
#: UTF-32 file as UTF-16 and reports nonsense.
BOM_ENCODINGS: tuple[tuple[bytes, str], ...] = (
    (b"\xff\xfe\x00\x00", "utf-32"),
    (b"\x00\x00\xfe\xff", "utf-32"),
    (b"\xff\xfe", "utf-16"),
    (b"\xfe\xff", "utf-16"),
)


def decode_for_scan(data: bytes) -> tuple[str | None, str | None]:
    """The file's text, or None and the reason there is none.

    BYTES, then decode, never read_text(): universal-newline translation turns a
    CRLF into a newline before the scan sees it, so the carriage return this
    rule names in `Cc` would be invisible to the only thing looking for it.

    Only two answers mean "no text here, and that is fine": a byte-order mark
    for an encoding handled above, and a NUL byte, which is git's own test for a
    binary file and means there are no lines to hide a codepoint in. Anything
    else that fails to decode is text that this scan could not read, and the
    caller turns that into a failure -- one stray byte in a source file must not
    buy the rest of it a pass.
    """
    for bom, encoding in BOM_ENCODINGS:
        if data.startswith(bom):
            try:
                return data.decode(encoding), None
            except UnicodeDecodeError:
                return None, f"declares a {encoding.upper()} BOM and does not decode as one"
    try:
        return data.decode("utf-8"), None
    except UnicodeDecodeError:
        pass
    if b"\x00" in data:
        return None, BINARY
    return None, "not valid UTF-8, and not binary either"


def check_files(
    paths: list[str],
    allowed: tuple[Allowance, ...] = (),
    exclude: tuple[str, ...] = (),
) -> int:
    """Mode 2. Exit 0 iff every path in scope was examined and hides nothing.

    With no paths, scans the whole tree this operation is introducing, from the
    top of the work tree whatever directory it was invoked in. That is the
    wiring the hook uses, and it is deliberate: passing only the staged files
    would check a hidden character on its way in and never again, so one that
    arrived under --no-verify, or through a merge, would be permanently
    invisible to the only thing looking for it. The cost is what makes that
    affordable rather than principled: 698 tracked files, measured, 1.20s -- see
    the fast path in _scan, which is the whole reason that number is what it is.

    WHICH tree is git-guards-scope.sh's answer, not this file's, and the module
    docstring says why. The bytes come from git's object database rather than
    from disk, and that is not a detail: the working tree is a different tree,
    and reading it made the scan miss what was staged, follow a symlink to
    somebody else's bytes, and refuse over a file that had merely been deleted
    from the checkout.

    With paths given, they are read from the filesystem exactly as named. That
    invocation is deliberately not a git question -- it is how a person points
    the rule at a file, staged or not, tracked or not -- so nothing is resolved
    through git for it.

    A SKIP is the dangerous outcome here, not a failure, because it leaves the
    denominator and exits 0. So there are exactly two of them, and neither can
    hide a codepoint:

      * a path matching a DECLARED --exclude glob, which somebody wrote down and
        a reviewer read in a diff
      * a binary file, which has no lines for a character to hide in

    Every other way a path can go unread is a FAILURE. Unreadable is "cannot
    say"; a tracked path that is not there is "cannot say"; a file that is text
    except for one byte is the most literal "cannot say" of all, and treating it
    as a skip would buy the whole file a pass on the strength of the very byte
    that should have stopped it. Both skips are printed on success as well as on
    failure -- a denominator with an unexplained numerator beside it tells a
    reviewer nothing.

    The path itself is scanned before its content, because a filename is
    committed text too and U+200B sits in one just as happily as in a YAML key.

    Fails closed on every way this can cover nothing: not a work tree, git
    unreachable, no scope to read, an empty scope (a broken enumeration, never a
    clean tree), and a path set with nothing readable in it. A scan that
    examined nothing must not report success.
    """
    #: `(sha, message)` for every commit a push publishes. Empty at every other
    #: stage, and empty for an explicit path list, which is not a git question.
    messages: list[tuple[str, str]] = []
    if paths:
        entries = [Entry(raw, None, None, Path(raw)) for raw in paths]
        root = Path()
        scanned_from: list[str] = ["the paths given on the command line"]
    else:
        toplevel = repository_toplevel()
        if toplevel is None:
            print(
                "prevent-unusual-unicode: not inside a git work tree, so there is no "
                "tracked-file list; refusing to report success over a scan that did "
                "not happen",
                file=sys.stderr,
            )
            return 1
        scopes = scan_scopes(toplevel)
        if scopes is None:
            print(
                "prevent-unusual-unicode: could not work out which tree to scan; "
                "refusing to report success over a scan that did not happen",
                file=sys.stderr,
            )
            return 1
        entries = []
        scanned_from = []
        for token, label in scopes:
            found = scope_entries(toplevel, token)
            if found is None:
                print(
                    f"prevent-unusual-unicode: could not ask git what {token} holds; "
                    "refusing to report success over a scan that did not happen",
                    file=sys.stderr,
                )
                return 1
            said = scope_messages(toplevel, token)
            if said is None:
                print(
                    f"prevent-unusual-unicode: could not ask git what {token} "
                    "publishes as a message; refusing to report success over a "
                    "scan that did not happen",
                    file=sys.stderr,
                )
                return 1
            entries.extend(found)
            messages.extend(said)
            scanned_from.append(label)
        if not entries:
            print(
                "prevent-unusual-unicode: git reported NO files at all -- a broken "
                "enumeration, not a clean tree",
                file=sys.stderr,
            )
            return 1
        # git names paths from the top of the work tree, and the --exclude globs
        # are written against those names. Running git from the toplevel keeps
        # both true from any working directory, while the findings stay named
        # the way git named them.
        root = toplevel

    allowances: tuple[Allowance, ...] = tuple(allowed)

    # Two passes, because the content of every git entry comes from ONE
    # `git cat-file --batch` and a batch is answered in the order it was asked.
    # Deciding per entry whether it needs content, and only then asking for the
    # ones that do, is what keeps the questions and the answers lined up: an
    # entry excluded by a glob, or skipped as a submodule, must not consume
    # somebody else's blob.
    skipped: list[str] = []
    used: set[Allowance] = set()
    plan: list[tuple[Entry, frozenset[str], list[str], bool]] = []
    for entry in entries:
        raw = entry.path
        here = allowed_in(raw, allowances)
        used.update(a for a in allowances if a.applies_to(raw))
        # Declared exclusions, matched on the path as git reports it. The case
        # this is for is a vendored third-party tree: a minified bundle carries
        # control characters because it is minified, and a repository that
        # vendors one has not written them and cannot fix them without forking
        # its dependency. Every exclusion is COUNTED as a skip and reported, so
        # a glob that quietly grew to cover the whole tree is visible rather
        # than being the reason the scan is clean.
        if any(fnmatch.fnmatch(raw, pattern) for pattern in exclude):
            skipped.append(f"{raw} (excluded by a declared pattern)")
            continue
        # The NAME, before anything is opened, and whatever the content turns
        # out to be. A filename is committed text: it is read by reviewers, by
        # importers and by build rules, and a zero-width space in one is the
        # same attack in a place nobody thinks to look. A tab or a newline is
        # legal INSIDE a file and never legitimate in a path, so the two the
        # content rule exempts are named as findings here instead.
        #
        # A path only the pushed range holds says so, for the reason its content
        # findings do: the file is not at the tip, and a complaint naming a path
        # a reader cannot find reads as a broken checker rather than as a commit
        # to rewrite.
        added = (
            ""
            if entry.origin == TREE_ORIGIN
            else f" (added by commit {entry.origin[:12]}, removed before the tip)"
        )
        name_findings = [
            f"{raw}{added}: U+{off.codepoint:04X} {off.name} ({off.category}) in "
            f"the FILE NAME -- {off.reason()}"
            for off in find_file_offenders(raw, here)
        ]
        name_findings.extend(
            f"{raw!r}{added}: {what} in the FILE NAME -- legal inside a file, "
            "never in a path"
            for ch, what in (("\t", "a tab"), ("\n", "a newline"))
            if ch in raw
        )
        # A submodule is its own repository and carries its own hooks, so there
        # is nothing to read here and nothing hidden by not reading it. From git
        # it arrives as a gitlink, which is a mode rather than a guess; from the
        # command line it arrives as a directory, which is the same fact seen
        # through the filesystem.
        if entry.mode == "160000" or (
            entry.on_disk is not None and entry.on_disk.is_dir()
        ):
            plan.append((entry, here, name_findings, False))
            skipped.append(f"{raw} (a submodule or directory, scanned by its own repo)")
            continue
        plan.append((entry, here, name_findings, True))

    wanted = [
        entry.oid for entry, _, _, needs in plan if needs and entry.oid is not None
    ]
    blobs = batched_blobs(root, wanted)

    scanned = 0
    failures: list[str] = []
    for entry, here, name_findings, needs_content in plan:
        raw = entry.path
        failures.extend(name_findings)
        if not needs_content:
            continue

        if entry.oid is not None:
            data, why_not_read = next(blobs, (None, "git cat-file gave no answer"))
            if data is None:
                # Unreadable is "cannot say", and cannot say is not clean. git
                # listed it, so something is wrong that a skip would hide.
                failures.append(f"{raw}: cannot read ({why_not_read})")
                continue
        else:
            assert entry.on_disk is not None
            try:
                data = entry.on_disk.read_bytes()
            except OSError as exc:
                failures.append(f"{raw}: cannot read ({exc})")
                continue

        # A symlink's blob IS its target path, so the content scanned here is
        # that string. Said in the finding rather than left to be inferred: a
        # complaint about column 3 of a file whose apparent content is a
        # directory listing is one nobody can act on.
        where = " in the SYMLINK TARGET" if entry.mode == "120000" else ""
        # And the same courtesy for a blob only the range holds. There is no
        # such file to open at the tip: what is left to act on is the commit
        # that added it, so the finding names that instead of sending a reader
        # to a path that no longer exists.
        if entry.origin != TREE_ORIGIN:
            where += f" in a blob commit {entry.origin[:12]} ADDED and a later one removed"

        text, why_not = decode_for_scan(data)
        if text is None:
            if why_not == BINARY:
                skipped.append(f"{raw} (binary -- no text to hide a codepoint in)")
            else:
                failures.append(
                    f"{raw}: cannot be read as text ({why_not}); refusing to report "
                    "it clean over content that was never examined"
                )
            continue
        scanned += 1
        # Named the way git names it, not the way this process happened to
        # reach it: the finding then matches the --exclude globs, the diff and
        # everything else a reviewer will compare it against.
        failures.extend(
            off.describe_in_file(Path(raw), where)
            for off in find_file_offenders(text, here)
        )

    # The messages the push publishes, under the MESSAGE rule -- see
    # scope_messages for why that rule and not this file's own.
    for sha, body in messages:
        failures.extend(
            f"commit {sha[:12]}:{off.line}:{off.col}: U+{off.codepoint:04X} "
            f"{off.name} ({off.category}) in the COMMIT MESSAGE -- outside the "
            "set of characters a commit message may hold"
            for off in find_offenders(body)
        )

    if scanned == 0 and not messages and not failures:
        print(
            f"prevent-unusual-unicode: {len(entries)} path(s) given and none could be "
            "read as text; refusing to report success over nothing scanned",
            file=sys.stderr,
        )
        for note in skipped:
            print(f"  skipped {note}", file=sys.stderr)
        return 1

    if failures:
        print("error: hidden Unicode in committed files", file=sys.stderr)
        print("", file=sys.stderr)
        for line in failures:
            print(f"  {line}", file=sys.stderr)
        print("", file=sys.stderr)
        print(
            "A file may hold any character a reader can SEE -- emoji, box drawing and "
            "Japanese punctuation all pass. These cannot be seen, so the reviewer and "
            "the parser are reading different text.",
            file=sys.stderr,
        )
        print("", file=sys.stderr)
        print("Override once with: git commit --no-verify", file=sys.stderr)
        return 1

    # The denominator, on success: a checker that prints only failures cannot be
    # told apart from one that scanned nothing.
    print(
        f"prevent-unusual-unicode: {scanned} file(s) scanned, "
        f"{len(messages)} commit message(s), {len(skipped)} skipped"
    )
    # And WHAT it is a denominator of, because the same number is the same
    # sentence about the index, about the commit being pushed, and about a
    # checkout of something else entirely -- and the whole reason the scope is
    # resolved rather than assumed is that those three used to be confused.
    for where in scanned_from:
        print(f"  scanned {where}")
    # THE TWO HALVES of it. A push introduces a tree and a range, and they catch
    # different things: the tree catches what arrived before this push and is
    # still there, the range catches what passed through it and is not. One
    # number for the two reads the same whether the second half found 148 blobs
    # or was never asked, which is the shape of every false green in this file's
    # history.
    from_tree = sum(1 for entry in entries if entry.origin == TREE_ORIGIN)
    print(
        f"  {from_tree} path(s) in the tree scanned, "
        f"{len(entries) - from_tree} additional blob(s) introduced by the "
        "pushed range"
    )
    # And the numerator beside it, ITEMISED. A count on its own is the thing
    # that made a skip safe to ignore: "3 skipped" reads as housekeeping right
    # up until one of the three is the file somebody hid something in. Both
    # remaining kinds of skip are deliberate, so naming them costs a reader
    # nothing and tells them exactly what this run did not look at.
    for note in skipped:
        print(f"  skipped {note}")
    for allowance in allowances:
        if allowance not in used:
            # Not a failure -- a scan can legitimately not reach the tree an
            # allowance names. Said aloud because an exception nobody has needed
            # for a year is one nobody is reviewing either, and the reason it
            # was granted has usually left with the file.
            print(
                f"  note: allowance {allowance.describe()} matched no scanned file"
            )
    return 0


class Allowance(NamedTuple):
    """One declared exception: a codepoint, and optionally where it applies.

    An unscoped allowance switches the rule off for that character EVERYWHERE,
    including the source, and that is too much for the case that needs it. A
    repository carrying captured artifacts -- pages an upstream actually served,
    committed byte-for-byte so a parser can be tested against them -- contains
    whatever the upstream's markup contains. Allowing U+00A0 repo-wide to
    accommodate a fixture also allows it in the code, where a non-breaking space
    genuinely is the defect this rule exists to catch.

    So an allowance may name a path glob: `--allow U+00A0:tests/fixtures/**`.
    The declaration keeps the property that made it reviewable -- a codepoint,
    at the invocation, read in a diff -- and stops being a statement about the
    whole repository.
    """

    char: str
    glob: str | None = None

    def applies_to(self, path: str) -> bool:
        return self.glob is None or fnmatch.fnmatch(path, self.glob)

    def describe(self) -> str:
        named = unicodedata.name(self.char, "UNKNOWN")
        where = f" in {self.glob}" if self.glob else " everywhere"
        return f"U+{ord(self.char):04X} {named}{where}"


def parse_allowance(token: str) -> Allowance:
    """`U+3000` or `U+00A0:tests/fixtures/**`.

    The glob is matched against the path as git reports it, with fnmatch
    semantics -- `*` crosses directory separators, so `tests/fixtures/**` and
    `tests/fixtures/*` cover the same tree.
    """
    codepoint, _, glob = token.partition(":")
    return Allowance(parse_codepoint(codepoint), glob or None)


def allowed_in(path: str, allowances: tuple[Allowance, ...]) -> frozenset[str]:
    """The characters allowed in THIS file."""
    return frozenset(a.char for a in allowances if a.applies_to(path))


def parse_codepoint(token: str) -> str:
    """`U+3000`, `u+3000` or `3000` -> the character.

    Spelled as a codepoint rather than pasted as a character, because the whole
    point of an allowance is that a reviewer can see WHICH character is being
    allowed. A pasted U+3000 in a config file is exactly as invisible there as it
    is anywhere else, and reviewing it would mean trusting a space to be the
    space it claims to be.
    """
    cleaned = token.strip()
    if cleaned[:2].upper() == "U+":
        cleaned = cleaned[2:]
    try:
        value = int(cleaned, 16)
    except ValueError:
        raise SystemExit(
            f"prevent-unusual-unicode: --allow expects a codepoint like U+3000, got {token!r}"
        ) from None
    return chr(value)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "--files":
        # Hand-parsed rather than argparse, because everything after --files that
        # is not a flag is a PATH, and this has to keep working when pre-commit
        # appends its own file list.
        rest = argv[1:]
        allowances: list[Allowance] = []
        exclude: list[str] = []
        paths: list[str] = []
        i = 0
        while i < len(rest):
            token = rest[i]
            if token == "--allow" and i + 1 < len(rest):
                allowances.append(parse_allowance(rest[i + 1]))
                i += 2
            elif token.startswith("--allow="):
                allowances.append(parse_allowance(token.split("=", 1)[1]))
                i += 1
            elif token == "--exclude" and i + 1 < len(rest):
                exclude.append(rest[i + 1])
                i += 2
            elif token.startswith("--exclude="):
                exclude.append(token.split("=", 1)[1])
                i += 1
            elif token.startswith("--"):
                raise SystemExit(f"prevent-unusual-unicode: unknown flag {token!r}")
            else:
                paths.append(token)
                i += 1
        return check_files(paths, tuple(allowances), tuple(exclude))
    msg_file = resolve_message_file(argv)
    if msg_file is None:
        print(
            "prevent-unusual-unicode: no commit message file found",
            file=sys.stderr,
        )
        return 1

    offenders = find_offenders(msg_file.read_text(encoding="utf-8"))
    if not offenders:
        return 0

    print("error: commit message contains unusual Unicode characters", file=sys.stderr)
    print("", file=sys.stderr)
    for off in offenders:
        print(off.describe(), file=sys.stderr)
    print("", file=sys.stderr)
    print("These characters are not in the allowed set.", file=sys.stderr)
    print(
        "Allowed: ASCII printable, Unicode letters/numbers/marks/separators,",
        file=sys.stderr,
    )
    print("and a curated set of common technical symbols.", file=sys.stderr)
    print(
        "Excluded even so: every codepoint drawn as nothing, including the ones",
        file=sys.stderr,
    )
    print(
        "Unicode files under letters, marks and separators -- so every space",
        file=sys.stderr,
    )
    print("that is not U+0020 is refused here too.", file=sys.stderr)
    print("", file=sys.stderr)
    print("Override once with: git commit --no-verify", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
