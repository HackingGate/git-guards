#!/usr/bin/env bash
set -euo pipefail

# Hook to prevent unusual Unicode characters in commit messages.
# Uses a whitelist approach:
#   1. All ASCII printable (0x20-0x7E) + tab, newline
#   2. All Unicode letters, numbers, combining marks, and separators
#      (categories L*, N*, M*, Z*) - supports CJK, Cyrillic, Arabic, etc.
#   3. A curated whitelist of common non-ASCII punctuation/symbols
#      used in technical and financial writing.
#   4. Minus, ahead of all of that, every codepoint that is drawn as nothing -
#      which the categories above do NOT exclude. U+3164 HANGUL FILLER is a
#      letter, U+034F COMBINING GRAPHEME JOINER is a mark, and U+00A0 NO-BREAK
#      SPACE and U+2028 LINE SEPARATOR are separators, so all four are inside
#      the categories at 2 and none of them puts ink on the page.
#
# Catches: section signs, pilcrows, bullets, daggers, emoji, private-use,
# control chars, zero-width, the invisible letters and marks, and every space
# that is not U+0020.
#
# The rule itself is NOT here. It lives in prevent-unusual-unicode-in-files.py,
# which holds both modes of it -- this whitelist for a commit message, and an
# invisible-character ban for file content -- and this file is the commit-msg
# entry point and nothing else.
#
# One copy, deliberately. A whitelist re-implemented in a python heredoc here
# would be a second rule that agrees with the first until it does not, and it
# would be the copy that cannot be imported, cannot be type-checked and cannot
# be tested -- so it would be the copy a fix missed.
#
# When called natively by git commit-msg, receives the message file as $1 and
# forwards it. So does a run under prek or pre-commit, both of which forward
# exactly one path for a hook declared `pass_filenames: true` -- which this one
# is, in .pre-commit-hooks.yaml, for the reason set out there. Handed nothing,
# it forwards nothing and the checker falls back to .git/COMMIT_EDITMSG itself:
# the right message under `git commit`, and the PREVIOUS one under a runner
# asked about a named file, which is why the declaration matters.

self="${BASH_SOURCE[0]}"
# Installed natively rather than through prek, this hook is usually a SYMLINK at
# .git/hooks/commit-msg pointing into a checkout of this repository -- and the
# checker sits beside the real file, not beside the link. One level of
# indirection is resolved with plain `readlink`, which behaves the same on BSD
# and GNU; `readlink -f` does not, and a portability difference here would show
# up as a hook that refuses every commit on somebody else's machine.
if [ -L "$self" ]; then
    target="$(readlink "$self")"
    case "$target" in
        /*) self="$target" ;;
        *) self="$(dirname "$self")/$target" ;;
    esac
fi
here="$(cd "$(dirname "$self")" && pwd)"
checker="$here/prevent-unusual-unicode-in-files.py"

# Existence, not executability: the checker is handed to python3 below rather
# than run as a program, so a checkout that lost the exec bit still works and
# refusing it would block every commit over a file mode.
if [ ! -f "$checker" ]; then
    # Fail closed. A commit-msg hook that exits 0 because it could not find its
    # own rule is worse than no hook at all: it reports a clean message it never
    # read, and it does so silently, forever.
    echo "prevent-unusual-unicode: the checker is not beside this hook" >&2
    echo "  expected it at: $checker" >&2
    echo "  refusing to report a clean message that was never examined" >&2
    exit 1
fi

exec python3 "$checker" "$@"
