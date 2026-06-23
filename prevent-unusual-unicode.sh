#!/usr/bin/env bash
set -euo pipefail

# Hook to prevent unusual Unicode characters in commit messages.
# Uses a whitelist approach:
#   1. All ASCII printable (0x20–0x7E) + tab, newline
#   2. All Unicode letters, numbers, combining marks, and separators
#      (categories L*, N*, M*, Z*) — supports CJK, Cyrillic, Arabic, etc.
#   3. A curated whitelist of common non-ASCII punctuation/symbols
#      used in technical and financial writing.
#
# Catches: § ¶ • † ‡ emoji, private-use, control chars, zero-width, etc.
#
# When called natively by git commit-msg, receives the message file as $1.
# When called via prek (which does not forward the arg), falls back to
# .git/COMMIT_EDITMSG.

msg_file="${1:-}"

if [ -z "$msg_file" ] || [ ! -f "$msg_file" ]; then
    # prek does not forward the commit message file path; fall back to the
    # standard git commit message file.
    git_dir="$(git rev-parse --git-dir 2>/dev/null)" || true
    if [ -n "${git_dir:-}" ] && [ -f "$git_dir/COMMIT_EDITMSG" ]; then
        msg_file="$git_dir/COMMIT_EDITMSG"
    fi
fi

if [ -z "$msg_file" ] || [ ! -f "$msg_file" ]; then
    echo "prevent-unusual-unicode: no commit message file found" >&2
    exit 1
fi

python3 - "$msg_file" << 'PYEOF'
import sys
import unicodedata

# Curated whitelist of common non-ASCII characters in technical/financial
# writing.  Each entry is (char, reason).
CURATED = set(
    # Currency (common in financial contexts)
    "¢£¤¥€"  # ¢ £ ¤ ¥ €
    "©®™"                # © ® ™
    "°±"                      # ° ± (degree, plus-minus)
    "–—"                      # – — (en dash, em dash)
    "…"                            # … (ellipsis)
    "‰"                            # ‰ (per mille)
    "“”‘’"          # "" '' (smart quotes)
    "←↑→↓"          # ← ↑ → ↓ (arrows)
    "✓✗"                      # ✓ ✗ (check marks, common in CI output)
    "×"                            # × (multiplication sign)
    "÷"                            # ÷ (division sign)
    "≤≥"                      # ≤ ≥ (comparison)
)

def allowed(char):
    """Return True if character is allowed in commit messages."""
    cp = ord(char)

    # Tab and newline
    if char == '\t' or char == '\n':
        return True

    # ASCII printable (space 0x20 through tilde 0x7E)
    if 0x20 <= cp <= 0x7E:
        return True

    # Curated whitelist
    if char in CURATED:
        return True

    # Unicode category whitelist:
    #   L*  letters (Lu Ll Lt Lm Lo) — all writing systems
    #   N*  numbers (Nd Nl No)
    #   M*  combining marks (Mn Mc Me) — diacritics
    #   Z*  separators (Zs Zl Zp) — space, line, paragraph separators
    cat = unicodedata.category(char)
    if cat[0] in 'LNMZ':
        return True

    return False

msg = open(sys.argv[1], encoding='utf-8').read()

offenders = []
for lineno, line in enumerate(msg.split('\n'), start=1):
    for col, char in enumerate(line, start=1):
        if not allowed(char):
            offenders.append(
                (lineno, col, char, ord(char), unicodedata.category(char),
                 unicodedata.name(char, 'UNKNOWN'))
            )

if offenders:
    print("error: commit message contains unusual Unicode characters", file=sys.stderr)
    print("", file=sys.stderr)
    for lineno, col, char, cp, cat, name in offenders:
        # Show the character visibly unless it's a control char
        if cat.startswith('C'):
            char_display = f"U+{cp:04X}"
        else:
            char_display = f"'{char}'"
        print(
            f"  line {lineno}, col {col}: {char_display}  "
            f"U+{cp:04X}  {cat}  {name}",
            file=sys.stderr,
        )
    print("", file=sys.stderr)
    print("These characters are not in the allowed set.", file=sys.stderr)
    print("Allowed: ASCII printable, Unicode letters/numbers/marks/separators,", file=sys.stderr)
    print("and a curated set of common technical symbols.", file=sys.stderr)
    print("", file=sys.stderr)
    print("Override once with: git commit --no-verify", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYEOF
