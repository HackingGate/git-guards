# git-guards

Reusable [pre-commit](https://pre-commit.com/) / [prek](https://github.com/j178/prek)
hooks for keeping local Git history clean across a multi-repo workspace.

## Hooks

| id | stage | purpose |
|---|---|---|
| `prevent-ai-author` | commit-msg | reject a **commit message** carrying AI-authorship trailers |
| `prevent-author-mismatch` | pre-commit | block commits whose author/committer doesn't match your global `~/.gitconfig` identity |
| `prevent-unusual-unicode` | commit-msg | reject control/zero-width/emoji/unusual unicode in messages |
| `prevent-unusual-unicode-in-files` | pre-commit, pre-merge-commit, pre-push, manual | reject invisible/deceptive characters in committed **file content** |
| `no-private-repo-names` | commit-msg | block a commit message that names a private repo, when this repo is public |
| `no-private-repo-names-staged` | pre-commit | the same check over the lines a commit adds |
| `no-private-repo-names-in-files` | pre-merge-commit, pre-push, manual | the same check over the **whole tree** being committed or pushed — and, at a push, every blob the range introduces — not only added lines |
| `prevent-public-push` | pre-push | block pushes outside the workspace owner allow-list (any platform) |
| `no-local-merge` | pre-merge-commit | block a local merge that would make a **merge commit** (merge via your forge's PR/MR workflow) |
| `no-merge-commit` | pre-commit | block in-progress merge / squash-merge commits |
| `no-stale-hook-pins` | pre-push, manual | fail when a `rev:` in `.pre-commit-config.yaml` is behind its upstream's newest tag |

`no-private-repo-names.sh --text [FILE]` is a fourth mode of the private-name rule
rather than a twelfth hook id: it takes a file or stdin, for callers that are not git
at all. It does not strip `#` lines and does not ask whether the *current* repository
is public, because the caller already decided that.

### What these hooks cannot see

| not covered | what to do instead |
|---|---|
| a **multi-ref push** — the runner consumes git's ref stream and re-exports a single pair, so the scan covers one ref | push one ref at a time; `prek run --all-files --hook-stage manual` in CI reads a tree, but neither the messages nor the blobs a range introduced |
| an **annotated tag's message** — git has no `tag-msg` hook type | check it first with `no-private-repo-names.sh --text`. The tag's *tree* is covered: the scope resolver peels a tag to its commit |
| a **fast-forward merge** — git creates no commit and runs no `pre-merge-commit` hook | what it brings in is judged at the next push: the tree, the messages, and every blob those commits introduce |
| the three private-name modes when this repo's **visibility is unknown** — exit `0`, nothing printed, and a runner draws it as `Passed` | set both `GIT_GUARDS_REPO_VISIBILITY=public` and `GIT_GUARDS_PRIVATE_OWNERS`; neither alone is an offline path |

The three commit-msg hooks are published with `pass_filenames: true`, which is how they
are handed the message file. Registering one with `pass_filenames: false` still works
under a real commit — each guard falls back to `.git/COMMIT_EDITMSG` — but not when you
check the guard by naming a file, because the fallback is then the *previous* message.

## Private repo names

Fires only when the repo you are committing to is **public**, and looks for repo names
in the three forms that actually name one: a forge URL, a cross-repo issue reference
(`owner/repo#123`), and — for owners you have declared private — a bare `owner/repo`.
Anything found is resolved with `gh` and refused if the answer is `private` or
`internal`. Bare pairs are otherwise left alone.

| variable | effect |
|---|---|
| `GIT_GUARDS_PRIVATE_OWNERS` | owners always treated as private — catches bare `owner/repo`, needs no network, works on any forge |
| `GIT_GUARDS_PUBLIC_REPOS` | `owner` or `owner/repo` entries to exempt |
| `GIT_GUARDS_REPO_VISIBILITY` | answer this repo's visibility instead of asking `gh`. Exactly `public`, `private`, `internal` or `unknown` (case-insensitive); anything else exits `2` naming the value |
| `GIT_GUARDS_ALLOW_PRIVATE_NAMES=1` | one-off bypass |
| `GIT_GUARDS_REFUSE_UNKNOWN=1` | treat a name the forge could not answer for as private (exit 2) |

Exit `1` is a confirmed private name and wins over `2`, "could not look". A named
repository the forge could not answer for is printed and exits `0` by default; in
tree-wide mode unresolved names stay quiet unless `GIT_GUARDS_REFUSE_UNKNOWN=1`.

Visibility **answers** are cached under `${XDG_CACHE_HOME:-~/.cache}/git-guards`, in a
file called `repo-visibility`. A failed lookup is not an answer and is not written; a
forge 404 is stored as `absent` and reads back as `unknown`. The cache has **no expiry**
— delete the file when a repository's visibility changes.

## Tree-wide scans

`no-private-repo-names-in-files` and `prevent-unusual-unicode-in-files` both ask which
bytes an operation introduces. `git-guards-scope.sh` answers it for both, and the answer
is never the working tree:

| stage | what is read |
|---|---|
| pre-commit, pre-merge-commit | the **index** — the tree this commit would have |
| pre-push | the **commit being pushed**, whichever branch is checked out; **every blob the pushed range introduces**, including one a later commit in the same push removed; **and the messages of the commits being sent** |
| manual | the index, or `HEAD` where there is no work tree to hold one |

**Symlinks** are scanned as what git stores them as — a symlink's blob *is* its target
path — and neither guard follows one. **Paths** are scanned as committed text in their
own right. Both print their denominator on a passing run as well as a failing one, and
fail closed on every way a scan can cover nothing.

`prevent-unusual-unicode-in-files` bans only what a reader cannot see: control
characters, zero-width and bidirectional format characters (the trojan-source class,
CVE-2021-42574), private-use codepoints, surrogates, unassigned codepoints, and any
space that is not `U+0020`. Everything visible stays legal, and `--allow U+3000` exempts
a codepoint a repository commits as data.

## Pushes

`prevent-public-push` parses the remote URL to extract the owner and blocks the push if
it is outside the allow-list. `WORKSPACE_…` applies to every workspace; `<OWNER>_…` names
one and **takes precedence** where both are set. `<OWNER>` is the workspace owner
upper-cased with every character that is not a letter, digit or underscore replaced by
`_` — so a workspace owned by `acme-corp` reads `ACME_CORP_ALLOWED_PUSH_OWNERS`.

| variable | effect |
|---|---|
| `<OWNER>_ALLOWED_PUSH_OWNERS` / `WORKSPACE_ALLOWED_PUSH_OWNERS` | owners a push may target. Defaults to the workspace's own owner |
| `<OWNER>_ALLOWED_PUSH_REPOS` / `WORKSPACE_ALLOWED_PUSH_REPOS` | a finer list, as `owner/repo`. Checked **before** the owner list |
| `<OWNER>_ALLOW_UNSAFE_PUSH=1` / `WORKSPACE_ALLOW_UNSAFE_PUSH=1` | bypass the guard entirely for this push |
| `WORKSPACE_PINNED_OWNER` | pin the owner instead of deriving it from `origin`. No per-owner spelling |

### Pin the owner; do not derive it

Declared, not inferred. Two ways, checked in this order:

| where | notes |
|---|---|
| `WORKSPACE_PINNED_OWNER` | environment; convenient, and as durable as the environment is |
| `.git-guards-owner` in the workspace root | one line, committed. **The stronger one:** repointing origin cannot touch it, and changing it is a diff somebody reviews |

With a pin in place, a repointed `origin` is refused outright. With neither, the guard
falls back to the origin-derived owner — the weaker mode, and it says so. The workspace
is resolved from the repo being pushed: `git rev-parse --show-toplevel`, then out through
any enclosing work trees, stopping below `$HOME`.

## Stale hook pins

| exit | meaning |
|---|---|
| `0` | every remote pin was compared against its upstream and is current |
| `1` | at least one pin is **behind**, with both versions named |
| `2` | at least one pin could not be checked **at all** |

| variable | effect |
|---|---|
| `GIT_GUARDS_PINS_HELD` | pins deliberately not moved: `owner/repo` or `owner/repo@rev`, comma or space separated |
| `GIT_GUARDS_ALLOW_UNCHECKED_PINS=1` | a pin that could not be checked becomes a printed note and exit `0` — the offline path |
| `GIT_GUARDS_ALLOW_STALE_PINS=1` | one-off bypass |
| `GIT_GUARDS_PIN_TIMEOUT` | seconds per `git ls-remote` (default 20). Unreadable is refused, not silently defaulted |

Write a hold as `owner/repo@rev`, which expires by itself the moment the pin moves. A
prerelease is a candidate only when the upstream has no stable release at all. It reads
**one config**, the `.pre-commit-config.yaml` at the top of the current work tree; name
more as arguments to cover a monorepo —
`no-stale-hook-pins.py a/.pre-commit-config.yaml b/.pre-commit-config.yaml`.

## Author identity

`prevent-author-mismatch` requires the author **and** committer of each commit to match
your global identity — the `user.name` / `user.email` in `~/.gitconfig`. It is resolved
via `git var`, so it catches a stray repo-local `user.email`, `git commit --author=...`,
and `GIT_AUTHOR_*`/`GIT_COMMITTER_*` overrides alike. Bypass once with
`git commit --no-verify`.

## Usage

In a consuming repo's `.pre-commit-config.yaml`:

```yaml
default_install_hook_types:
  - pre-commit
  - pre-merge-commit
  - pre-push
  - commit-msg

repos:
  - repo: https://github.com/HackingGate/git-guards
    rev: v1.0.0
    hooks:
      - id: prevent-ai-author
      - id: prevent-author-mismatch
      - id: prevent-unusual-unicode
      - id: prevent-unusual-unicode-in-files
      - id: no-private-repo-names
      - id: no-private-repo-names-staged
      - id: no-private-repo-names-in-files
      - id: prevent-public-push
      - id: no-local-merge
      - id: no-merge-commit
      - id: no-stale-hook-pins
```

Then `prek install` (or `pre-commit install`). Repo-specific hooks (cargo, zig, ruff,
shellcheck, branding checks, CI) stay in the consuming repo's own config.

## Updating

A release is a new tag, and consumers bump their `rev:` to it. `no-stale-hook-pins` is
what makes the sweep visible: run it, and every pin that is behind names itself, both
versions included.

Runners cache by `rev`, so a machine that already fetched a tag keeps its copy until
`prek clean` — if a fix "isn't working", that is the first thing to check, and the
reason CI (which starts cold) can disagree with a laptop.

## Claude Code Agent Setup

The `prevent-ai-author` commit-msg hook reads one thing — the commit message file — and
rejects two markers in it: a `Co-Authored-By` trailer with a `noreply@` address, and a
`Generated with [Claude/Copilot/…]` line. It does **not** see pull request bodies;
nothing installed as a git hook can. Add to `~/.claude/settings.json` (HOME root) or
`.claude/settings.local.json` (project root):

```json
{
  "attribution": {
    "commit": "",
    "pr": ""
  }
}
```

- `commit` — suppresses the `Co-Authored-By: Claude <noreply@anthropic.com>` trailer and
  the `Generated with Claude Code` line from commit messages.
- `pr` — suppresses the `Generated with Claude Code` footer from PR bodies.
