# git-guards

Reusable [pre-commit](https://pre-commit.com/) / [prek](https://github.com/j178/prek)
hooks for keeping local Git history clean across a multi-repo workspace — the
canonical home for these guards, referenced remotely instead of copying
`scripts/*.sh` into every repo.

## Hooks

| id | stage | purpose |
|---|---|---|
| `prevent-ai-author` | commit-msg | reject commits carrying AI-authorship trailers |
| `prevent-unusual-unicode` | commit-msg | reject control/zero-width/emoji/unusual unicode in messages |
| `prevent-public-push` | pre-push | block pushes outside the workspace owner allow-list |
| `no-local-merge` | pre-merge-commit | disable local `git merge` (use `gh pr merge`) |
| `no-merge-commit` | pre-commit | block in-progress merge / squash-merge commits |

`prevent-public-push` derives the allowed owner from the consuming repo's
`origin` URL and a `<OWNER>_ALLOW_UNSAFE_PUSH` env var — no per-repo edits needed.

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
      - id: prevent-unusual-unicode
      - id: prevent-public-push
      - id: no-local-merge
      - id: no-merge-commit
```

Then `prek install` (or `pre-commit install`). Repo-specific hooks (cargo, zig,
ruff, shellcheck, branding checks, CI) stay in the consuming repo's own config.

## Updating

Edit a script here, commit, then bump the tag:

```sh
git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z
```

Consumers move to the new `rev:` when ready (or via `prek autoupdate`).
