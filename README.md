# git-guards

Reusable [pre-commit](https://pre-commit.com/) / [prek](https://github.com/j178/prek)
hooks for keeping local Git history clean across a multi-repo workspace — the
canonical home for these guards, referenced remotely instead of copying
`scripts/*.sh` into every repo.

## Hooks

| id | stage | purpose |
|---|---|---|
| `prevent-ai-author` | commit-msg | reject commits carrying AI-authorship trailers |
| `prevent-author-mismatch` | pre-commit | block commits whose author/committer doesn't match your global `~/.gitconfig` identity |
| `prevent-unusual-unicode` | commit-msg | reject control/zero-width/emoji/unusual unicode in messages |
| `prevent-public-push` | pre-push | block pushes outside the workspace owner allow-list (any platform) |
| `no-local-merge` | pre-merge-commit | disable local `git merge` (merge via your forge's PR/MR workflow) |
| `no-merge-commit` | pre-commit | block in-progress merge / squash-merge commits |

`prevent-public-push` parses the remote URL to extract the owner, checks it
against `<OWNER>_ALLOWED_PUSH_OWNERS`, and blocks the push if it doesn't match.
Works with any platform — GitHub, GitLab, Bitbucket, self-hosted, etc.

The default allowed-owners list is `WORKSPACE_ALLOWED_PUSH_OWNERS` (falls back
to the `origin` remote's owner). Set `<OWNER>_ALLOWED_PUSH_OWNERS` to override
for a specific workspace. Set `<OWNER>_ALLOW_UNSAFE_PUSH=1` (or
`WORKSPACE_ALLOW_UNSAFE_PUSH=1`) to bypass the guard entirely.

`prevent-author-mismatch` requires the author **and** committer of each commit
to match your global identity — the `user.name` / `user.email` in `~/.gitconfig`
(`git config --global`). The identity it checks is resolved via `git var`, so it
catches a stray repo-local `user.email`, `git commit --author=...`, and
`GIT_AUTHOR_*`/`GIT_COMMITTER_*` environment overrides alike. This stops an agent
from `git init`-ing a fresh repo and committing under the wrong author. There are
no env vars or extra config to set: the global identity is the single source of
truth. Bypass once with `git commit --no-verify`.

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
    rev: main
    hooks:
      - id: prevent-ai-author
      - id: prevent-author-mismatch
      - id: prevent-unusual-unicode
      - id: prevent-public-push
      - id: no-local-merge
      - id: no-merge-commit
```

Then `prek install` (or `pre-commit install`). Repo-specific hooks (cargo, zig,
ruff, shellcheck, branding checks, CI) stay in the consuming repo's own config.

## Updating

Consumers track `rev: main`, so edits here reach every repo on its next
`prek autoupdate` (or `prek clean`) — no per-release `rev:` bump to make here or
in the consumers. The `v1.0.0` tag marks a stable snapshot you can pin instead
of `main` if you ever need to.

## Claude Code Agent Setup

The `prevent-ai-author` commit-msg hook rejects commits and PRs containing AI
authorship markers: `Co-Authored-By` trailers with `noreply@` addresses and
`Generated with [Claude/Copilot/…]` lines.

Claude Code appends these markers by default. Configure your agent so it doesn't
trip the hooks — choose one of the levels below.

### Setup

Add to `~/.claude/settings.json` (HOME root) or `.claude/settings.local.json` (project root):

```json
{
  "attribution": {
    "commit": "",
    "pr": ""
  }
}
```

### What the keys do

- `commit` — suppresses the `Co-Authored-By: Claude <noreply@anthropic.com>`
  trailer and the `Generated with Claude Code` line from commit messages.
- `pr` — suppresses the `Generated with Claude Code` footer from PR bodies.
