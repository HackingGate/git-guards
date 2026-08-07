# git-guards

Reusable [pre-commit](https://pre-commit.com/) / [prek](https://github.com/j178/prek)
hooks for keeping local Git history clean across a multi-repo workspace — the
canonical home for these guards, referenced remotely instead of copying
`scripts/*.sh` into every repo.

## Hooks

Eleven hook ids, and this table is the whole published surface — the `stage`
column is what `.pre-commit-hooks.yaml` declares, not a suggestion.

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

`no-private-repo-names.sh --text [FILE]` is a fourth mode of the private-name
rule rather than a twelfth hook id: it takes a file or stdin and is meant for
callers that are not git at all. It is described with the other three modes
below.

### What these hooks cannot see

Four limits, stated here rather than left to be discovered, because none of
them shows up as a failure anywhere. A guard that names what it cannot see is
honest; one that stays silent is a green tick over bytes nobody looked at.

**A multi-ref push is judged on one ref.** `git push origin branch-a branch-b`
sends two refs, and git hands a `pre-push` hook one line per ref on stdin — but
the hook runner reads that stream itself and re-exports a *single*
`PRE_COMMIT_TO_REF` pair, measured under prek 0.3.12. By the time these guards
run the stream is gone and cannot be re-read, so the scan covers `branch-a` and
`branch-b` is published unexamined. It is not a bug that can be fixed here: the
information has been consumed before the hook starts. Two things to do instead —
**push one ref at a time**, and **run the manual stage in CI** (`prek run
--all-files --hook-stage manual`), which reads the whole tree with no ref
involved. That second one is a partial remedy and worth being exact about: with
no push there is no range and no ref, so a manual run reads a checkout's **tree**
and neither the messages nor the blobs a range introduced. Pushing one ref at a
time is the remedy that covers all three. The scope resolver already prints a
*list* of scopes rather than one, so a runner that starts forwarding every ref
needs no change to these guards.

**An annotated tag's message is never scanned.** git has no tag-message hook
type — there is no `tag-msg` to install — so `git tag -a -m '…'` reaches none of
the three commit-msg guards and nothing at push time either. Check one before
cutting it: `no-private-repo-names.sh --text` takes a file or stdin and applies
the identical rule. What *is* covered is the tag's **tree**: the scope resolver
peels a tag to the commit it points at, so pushing a tag over a tree that names
a private repository is refused exactly as pushing the branch would be —
measured, `git push origin v3` for a tag on an unpushed commit is refused with
the finding named. A tag pointing at a commit the remote *already* holds
introduces no bytes, and the runner starts no hook for one, which is the same
answer a second push of an unchanged branch gets. It is the tag's own message,
and only that, which no hook can reach.

**`no-local-merge` cannot stop a fast-forward merge.** git creates no commit for
one and runs no `pre-merge-commit` hook, so there is no moment to refuse at. What
a fast-forward brings in is judged at the next push, over all three of the things
that push publishes: the tree it arrives at, the **messages** of the commits it
carries, and every **blob those commits introduce**, including one added and
deleted again before the tip. What is *not* covered is the tag case above and a
second ref of a multi-ref push.

**The three private-name modes go silent when this repository's visibility is
unknown**, and a runner draws that as `Passed`. No `gh`, no network, or a forge
that will not say: exit `0`, nothing printed, no name examined.
`GIT_GUARDS_PRIVATE_OWNERS` alone does not change this — the offline path is
that variable **and** `GIT_GUARDS_REPO_VISIBILITY=public`, which is spelled out
under *no-private-repo-names* below. The tree-wide mode still prints its
denominator, so there the silence is at least a countable one; the staged and
commit-message modes print nothing at all.

The three commit-msg hooks are published with `pass_filenames: true`, which is
how they are handed the message file — `.git/COMMIT_EDITMSG` under `git commit`,
and whatever you name under
`prek run --hook-stage commit-msg --commit-msg-filename <file>`. Registering one
of them yourself with `pass_filenames: false` still works under a real commit,
because each guard falls back to `.git/COMMIT_EDITMSG`; it stops working the
moment you check the guard by naming a file, because the fallback is then the
*previous* commit's message and the guard reports a pass over a file it never
opened.

`no-private-repo-names` keeps a private repo's name out of a public repo's
history. It fires only when the repo you are committing to is **public**, and it
looks for repo names in the three forms that actually name one: a forge URL, a
cross-repo issue reference (`owner/repo#123`), and — for owners you have
declared private — a bare `owner/repo`. Anything it finds is resolved with `gh`
and refused if the answer is `private` or `internal`. `src/main.rs` is not a
repository, and a guard that cries wolf gets bypassed by reflex, so bare pairs
are otherwise left alone.

It exists because the mistake is a natural one: you fix a shared tool in a
public repo *because* of something you hit in a private one, and paste the real
error output into the commit message. A PR description can be edited afterwards;
a commit message cannot, without rewriting published history.

`no-private-repo-names-in-files` is the half the other two cannot cover. Staged
mode judges what a commit **adds**, which is the right unit at commit time and
blind by construction to a line that is already there. A name that arrived under
`--no-verify`, through a merge, or from a checkout where nobody ran `prek
install` is not an addition to any later commit, so nothing looks at it again —
and a `.pre-commit-config.yaml` line pointing a public repo at a private one is
exactly that shape. It scans the whole tree for the same reason
`prevent-unusual-unicode-in-files` does — see *Which bytes a tree-wide scan
reads* below — and runs at three stages for three different reasons.
**pre-push** is the last local moment before the work becomes shared.
**pre-merge-commit** is there because git runs no `pre-commit` hook for a merge,
so without it the "arrived through a merge" case in the sentence above walks
straight past the guard that names it. **manual** is how CI reaches what a local
hook may never have been installed to catch.

One deliberate difference in that mode: unresolved names stay quiet. A tree-wide
scan crosses every example URL, every placeholder and every forge `gh` cannot
answer for, so reporting them would bury the finding under names nobody can act
on. `GIT_GUARDS_REFUSE_UNKNOWN=1` still reports them, and still exits `2`.

It prints its **denominator** on a passing run as well as a failing one: how
many files it **searched** out of how many it found, how many symlink targets,
how many path names, how many commit messages, and which tree all of it came out
of. Searched rather than found is the load-bearing word — the two used to be the
same number, which is what let a `.gitattributes` line move files from one to
the other in silence. Every path in the gap is named with its reason. A
tree-wide scan that prints only findings cannot be told apart from one that read
nothing, and "25 path(s)" is the same sentence about the index, about the commit
being pushed, and about a checkout of something else.

`--text` makes the rule callable by things that are not git. A pull request
body is typed into a CLI and reaches a public API without passing a single
hook, and so do issue titles, release notes and branch names — the rule for all
of them is this one, and a second implementation would be a second rule that
agrees with this one until it does not. Two deliberate differences: it does not
strip `#` lines, because a Markdown heading is content rather than a comment,
and it does not ask whether the *current* repository is public, because the
caller already decided that — the text is usually written from a checkout that
is not where it is going.

| variable | effect |
|---|---|
| `GIT_GUARDS_PRIVATE_OWNERS` | owners always treated as private — catches bare `owner/repo`, needs no network, works on any forge |
| `GIT_GUARDS_PUBLIC_REPOS` | `owner` or `owner/repo` entries to exempt |
| `GIT_GUARDS_REPO_VISIBILITY` | answer this repo's visibility instead of asking `gh`. Exactly `public`, `private`, `internal` or `unknown` (case-insensitive); anything else exits `2` naming the value, because a typo for the value that turns the guard **on** would otherwise turn it off |
| `GIT_GUARDS_ALLOW_PRIVATE_NAMES=1` | one-off bypass |
| `GIT_GUARDS_REFUSE_UNKNOWN=1` | treat a name the forge could not answer for as private (exit 2) |

Visibility **answers** are cached under `${XDG_CACHE_HOME:-~/.cache}/git-guards`,
in a file called `repo-visibility`. Only the forge's own three words — `public`,
`private`, `internal` — count as a visibility, and the test is applied on both
sides of the cache. A failed lookup is not an answer and is not written:
remembering it would switch the guard off for that repository permanently, for
the one repository it had just failed to resolve.

A line may carry a fourth word, `absent`, and it is not a visibility. It records
the forge replying **404** — "no such repository, or none visible to this token"
— which is an answer, and one that does not change between two runs a second
apart. Not storing it is what made a tree-wide scan pay a round trip per name on
every run, warm cache or cold: on this repository 41 of 46 names 404, so the
cache saved five of forty-six and the scan took 19.4 seconds against 0.08 with
`gh` off `PATH`. Storing it is safe in the only direction that matters, because
it reads back as `unknown`: the name is still reported as unresolved,
`GIT_GUARDS_REFUSE_UNKNOWN=1` still refuses it, and nothing is ever concluded to
be not-private from a stored 404. Only a 404 — not a 401, a 403 or a 5xx, which
answer 404-shaped for every name at once and would write off a whole tree from
one expired token. Where a name has both an `absent` line and a visibility, the
visibility wins, whichever was written first.

A cached line that is not one of those four words is not read as an answer at
all, and is treated as a miss.

The cache has **no expiry**, and that is a real limit rather than a claim that
visibility never changes. It changes in the direction that matters: a repository
answered `public` once and made private afterwards is answered `public` forever
here, and a repository going private is precisely the event this guard exists
for. An entry is never expired because the guard has no way to tell a stale
answer from a current one without asking the forge again — which is the lookup
an expiry exists to avoid — and because a time-based reread would quietly
resurrect the JSON-blob and failed-lookup entries the vocabulary check keeps
out. The same applies to an `absent` line for a repository this token has since
been given access to; that one only ever costs a name going on being reported as
unresolved, which is the answer it was already giving. So the rule is manual and
it is one command: **delete
`${XDG_CACHE_HOME:-~/.cache}/git-guards/repo-visibility`** when a repository's
visibility changes, and every name is looked up again from scratch. It is a
cache; nothing is lost with it.

Without `gh`, or when *this* repository's visibility cannot be determined, the
three git-facing modes go **completely quiet**: exit `0`, nothing printed, no
name examined. That is deliberate — naming a sibling private repo inside a
private repo is fine, so a guard that fired on "do not know" would cry wolf in
every repository it could not resolve — but it is a silence worth reading twice,
because a runner renders it as `Passed`.

`GIT_GUARDS_PRIVATE_OWNERS` does **not** on its own get you an offline path.
It is what a name is matched *against*, and it needs no network to do that; the
question of whether this repository is public is asked first, and reaching it is
what the network was for. Measured, cold cache, `gh` off `PATH`: with only
`GIT_GUARDS_PRIVATE_OWNERS=acme` a message reading `mirror the change in
acme/platform` exits `0` in silence. **The offline path is both variables**:

```sh
export GIT_GUARDS_REPO_VISIBILITY=public   # answer the question gh would answer
export GIT_GUARDS_PRIVATE_OWNERS=acme      # and the names to match against it
```

with the same message then refused, and no forge involved in either half.
`--text` is the one mode that does not ask, because its caller has already
decided — see above.

A **named** repository the forge could not answer for is different, and is
reported. `gh api` returns 404 both for a repository that does not exist and for
a private one this token cannot see, and the second is the case this guard is
here for; passing silently would be the guard reporting a clean result for a
question it never got an answer to. The default prints the names and exits `0`,
because a lookup failure is common and blocking every commit on one would get
the hook removed. `GIT_GUARDS_REFUSE_UNKNOWN=1` makes it exit `2` instead —
"could not look", distinct from the `1` a confirmed private name gets. A
confirmed finding still wins: exit `1` is the more specific answer.

## Which bytes a tree-wide scan reads

`no-private-repo-names-in-files` and `prevent-unusual-unicode-in-files` are both
tree-wide, and both ask one question: **which bytes is this operation actually
introducing?** `git-guards-scope.sh` answers it once, for both, and the answer is
never the working tree:

| stage | what is read |
|---|---|
| pre-commit, pre-merge-commit | the **index** — the tree this commit would have |
| pre-push | the **commit being pushed**, whichever branch is checked out; **every blob the pushed range introduces**, including one a later commit in the same push removed; **and the messages of the commits being sent** |
| manual | the index, or `HEAD` where there is no work tree to hold one |

The working tree is a different tree, and every way it differed was a green tick
over bytes nobody looked at. A line staged and then edited back out of the file
on disk is in the commit and was not in the scan. A private name committed on a
feature branch, with `main` checked out and the file not even present, was
reported `Passed` by the hook registered at **pre-push** precisely to catch it,
and reached the remote. A tracked file that was `chmod 000` or deleted from the
checkout produced exit `0` and not one word — reading git's objects retires that
whole class, because a mode bit cannot stop a blob being read out of the object
database.

**Symlinks** are scanned as what git stores them as: a symlink's blob *is* its
target path, and that string is the file's entire committed content. Neither
guard follows one. `ln -s $'t<U+200B>gt' link` committed a zero-width space in a
six-byte blob, and a committed `ptr -> acme/hidden-repo` is a private
repository's name in a public repository's history — both were reported clean
while the identical bytes in a plain file were caught. `git grep` does not look
inside a symlink at all, so the private-name scan reads those blobs directly.

**Paths** are scanned as committed text in their own right, by both guards. A
directory named `acme/hidden-repo` publishes that name in the tree listing
exactly as a line of a file would — `vendor/acme/hidden-repo/README` reached a
remote with every hook green at commit, at push and at manual — and a filename
carrying `U+200B` is the invisible-character attack in the one place nobody
opens a file to look. The private-name scan reads a path as its **adjacent
segment pairs**, one per line, which is what keeps it from asking the forge
about a deep directory tree: a two-segment line cannot match the forge-URL form,
so only a declared-private owner (`GIT_GUARDS_PRIVATE_OWNERS`) can match, and it
matches with no network at all. A directory named after a declared-private owner
will report its children as repository names; `GIT_GUARDS_PUBLIC_REPOS` exempts
one.

A **submodule** is skipped and named as one — but its **path** is not. It
arrives as a gitlink with no blob in this repository, it is its own repository,
and it consumes these hooks itself; the path it sits at is this repository's own
committed text and is read like any other.

**Commit messages** are read at **pre-push**, by both guards, over the commits
being sent. A commit is a tree *and* a message, and the message is checked by a
`commit-msg` hook — which runs when `git commit` writes one. `git commit-tree`,
a rebase, a cherry-pick, `git am`, `--no-verify` and a fast-forward from a clone
with no hooks installed all produce a commit without that ever happening, and
until this the pre-push guards read only the tree. Which commits: `FROM..TO`
when the runner says what the remote already holds, and everything reachable
from the pushed tip that no other ref of that remote holds when it does not —
for a brand-new branch, or a remote this clone has never fetched, that is the
whole history of the tip, which reads too much rather than too little. The
private-name rule is the same one the commit-msg guard applies; the unicode rule
applied here is the **message** whitelist, not the file ban, because a message
does not stop being a message for being read a stage later.

**The blobs the range introduces** are read at **pre-push** too, over that same
range, and they are the half a tip-tree scan cannot reach. A push publishes a
range of commits; the tree-wide guards read the last of them. A file added in
one pushed commit and deleted in the next is in the remote's history
permanently, is in no tip tree, and was read by nothing — measured: two commits,
one adding a file that named a private repository and carried `U+200B`, the next
deleting it, fast-forwarded in from a hookless clone and pushed with every hook
green and no override of any kind, and `git cat-file` on the remote handing the
bytes back afterwards.

Both halves are needed and neither contains the other. The **tree** catches what
arrived *before* this range and is still there — a name committed under
`--no-verify` last month is in no diff over this push, because to this push it
is not new. The **range** catches what passed *through* it. So the union is
scanned, deduplicated by `(blob, path)` so a file touched in ten commits is read
once, and each entry says which half it came from: a finding in a range blob
names the **commit that added it**, because once the file is gone that commit is
the only thing left to act on.

Four decisions in reading that range, each of them reachable. A **merge** is
diffed against its **first parent** — git's default is to print nothing at all
for one, and diffing against every parent reads more while covering nothing
extra, since each other parent is itself in the range and answers for its own
side. A **root commit** needs `--root` or git prints nothing for it, so a brand
new repository's first push would go unread. The filter is `AMT` and not `AM`: a
file **replaced by a symlink** is a type change, and the blob dropped with it is
the symlink's target path. And rename detection is off, so a record is always one
status and one path.

What it costs, measured on a real 705-commit repository with 148 files at its
tip: an ordinary push adds **nothing**, because a commit's blobs are usually
still in the tip's tree where they were already being read. A push of 100
commits added 119 blobs and 0.4s; the whole 705-commit history added 700 blobs
and 1.5s. There is **no cap** — a cap would have to drop commits from the range
to be worth anything, and a range with commits missing from it is this same
defect wearing a limit as a disguise. Both guards print the two halves of their
denominator instead, so a scan that read 148 paths and 700 more blobs says so.

**Attributes cannot hide a file.** git decides "binary" from the `diff`
**attribute** before it ever looks for a NUL byte, and both `git grep -I` and
`git diff --cached` obey it. A committed two-line `.gitattributes` holding
`*.log -diff` — or `* -diff`, or `*.csv binary` — made plain-ASCII files
invisible to `--staged` and `--tracked` alike, at every stage, with the exit
status still `0` or `1`, nothing on stderr, and a denominator counting files
nobody had read. So the private-name scan asks git **which paths it actually
read**, fetches the rest itself through `git cat-file` — which no attribute can
stop — and answers the binary question on the bytes, the way git's own heuristic
does: a NUL in the first 8000. Staged mode does the same for every path git
declined to diff as text. The denominator states both numbers, and every path in
the gap is named with the reason it went unread.

Any word `git grep` writes to **stderr** ends the run, whatever it exited. `git
grep` prints `error: '<path>': unable to read <oid>` for a blob it cannot
produce and still exits `1`, so a scan that only refuses a status above `1`
discards the complaint and reports a clean tree over a file that was never
opened.

`prevent-unusual-unicode-in-files` is the same rule's second mode and a
deliberately **different** ban. A commit message gets a whitelist, because the set
of characters that belong in one is small and nameable. A repository's files get
an invisible-character ban instead, because their legitimate vocabulary is not
nameable: real repositories commit CJK punctuation, box-drawing diagrams and emoji
that are *data*. So it refuses only what a reader cannot see — control characters,
zero-width and bidirectional format characters (the trojan-source class,
CVE-2021-42574), private-use codepoints, surrogates, unassigned codepoints, and
any space that is not `U+0020`. Everything visible stays legal.

Categories alone do not cover that, and the characters that prove it are the
reason the rule also carries a table of Unicode's `Default_Ignorable_Code_Point`
property. `U+3164` HANGUL FILLER is classified `Lo` — a **letter** — and draws
nothing, which is what makes it the character of choice for smuggling one
identifier past a reviewer reading another; `U+115F`, `U+1160` and `U+FFA0` are
the same trick in the same block, and `U+034F` COMBINING GRAPHEME JOINER and
`U+17B4`–`U+17B5` are it in `Mn`. `U+2800` BRAILLE PATTERN BLANK is named on its
own: it is an ordinary `So` symbol, filed beside every emoji, and its glyph is
empty space.

A variation selector is the one member of that table that stays legal, and only
where it is **doing its job** — immediately after a character that has an
alternate presentation for it to select. `U+26A0 U+FE0F` is how the warning sign
that renders as an emoji is spelled, and a rule that admits emoji as data while
refusing half their spellings is one its own author cannot predict.

That takes two conditions, not one, and the second is what keeps the exception
inside the rule. "Anything visible in front of it" would admit
`user<U+FE0F>name` in an identifier and `exa<U+FE0F>mple.com` in a YAML value:
there is no second way to draw a Latin small letter U, so the selector renders as
nothing *and* changes nothing, which is the sentence the whole class is refused
by — and it is the shape a payload of one hidden codepoint per carrier letter
takes, where no two selectors are ever adjacent. So the base must be above
`U+007F`, where presentation selection and ideographic variation actually live.

The one exception below that line is the keycap, and it is an exception for the
whole three-codepoint sequence rather than for its first character.
`1<U+FE0F><U+20E3>` is how a keycap emoji is written down, so one of the twelve
bases (`#`, `*` and the digits) is a licence only when the `U+FE0F` and the
`U+20E3` are both actually there. A digit carrying a selector that no enclosing
mark follows — `port: 80<U+FE0F>80` in a config, `v1<U+FE0F>.3.0` in a subject
line — is not a keycap, it is the identifier attack spelled with the characters
that appear in every file of every repository; and only `U+FE0F` can finish a
keycap, so an *ideographic* selector after a digit (`build 7<U+E0100>`) is
refused too, because no continuation of it is a keycap. A selector anywhere
else — after nothing, after a space, after an ASCII letter, after another
selector — is refused like the rest of the table.

An allowance may be scoped to a path:

```yaml
      - id: prevent-unusual-unicode-in-files
        args: ["--allow", "U+3000", "--allow", "U+00A0:tests/fixtures/**"]
```

`U+3000` there is declared everywhere, for a codebase whose parsers match an
ideographic space as data. `U+00A0` is declared only under `tests/fixtures/`,
which is the case scoping exists for: a repository tracking **captured
artifacts** — pages an upstream actually served, committed byte-for-byte so a
parser can be tested against them — contains whatever the upstream's markup
contains. Allowing `U+00A0` repo-wide to accommodate a fixture also allows it in
the code, where a non-breaking space is exactly the defect this rule is for.

The glob is matched against the path as given, with fnmatch semantics: `*`
crosses directory separators. An allowance is still spelled as a codepoint, at
the invocation, so a reviewer reads it in a diff — scoping narrows where it
applies without changing what makes it reviewable. An allowance that matches no
scanned file is reported, because an exception nobody has needed is one nobody is
reviewing either.

`--exclude` takes a whole path out of the scan, and it is the blunter of the two:

```yaml
      - id: prevent-unusual-unicode-in-files
        args: ["--exclude", "vendor/**", "--exclude", "*.min.js"]
```

Prefer `--allow` when you can name the character. `--exclude` is for the case
where you cannot: a **vendored third-party tree**, where a minified bundle
carries control characters *because* it is minified, and the repository that
vendors it has neither written them nor any way to fix them short of forking the
dependency. Listing codepoints there would mean enumerating whatever the
upstream's build emitted this week.

Same fnmatch semantics as an allowance's scope, matched against the path as git
reports it. An excluded path is **counted and printed as a skip** on a passing
run as well as a failing one — a glob that quietly grew to cover the tree should
be visible as a number, not as the reason the scan came back clean.

A declared exclusion and a binary file are the only two ways a path goes unread
without failing the run — the first because somebody wrote it down and a
reviewer read it in a diff, the second because a binary has no lines for a
character to hide in. Everything else — unreadable, absent, text with one stray
byte — is a failure, because "cannot say" is not "clean". Excluding *everything*
is a failure too: a scan with nothing left to read reports that, rather than the
clean tree it could otherwise claim.

It scans the **whole tree** the operation is introducing, not the files a commit
touches — and at a push, the blobs the pushed range introduces as well. See
*Which bytes a tree-wide scan reads* above. A hidden character checked on its way
in and never again is invisible forever once it arrives under `--no-verify` or
through a merge, which is why it runs at four stages rather than one.
`pre-merge-commit`: git runs no `pre-commit` hook for a merge. `pre-push`: a
**fast-forward** merge creates no commit at all, so no `pre-merge-commit` hook
runs either, and a commit carrying `U+200B` rode a `git merge --ff-only` from a
hookless clone to a remote with every hook green — the push is the only moment
left. `manual`: without it, CI's `--hook-stage manual` ran no file-unicode check
whatsoever. It prints its denominator, what the denominator is *of*, and how
much of it came from each half; and it fails closed on every way the scan can
cover nothing: git unreachable, no scope to read, an empty scope, or a path set
with nothing readable in it.

`prevent-public-push` parses the remote URL to extract the owner, checks it
against `<OWNER>_ALLOWED_PUSH_OWNERS`, and blocks the push if it doesn't match.
Works with any platform — GitHub, GitLab, Bitbucket, self-hosted, etc.

The first three come in pairs. `WORKSPACE_…` applies to every workspace;
`<OWNER>_…` names one and **takes precedence** where both are set. `<OWNER>` is
the workspace owner upper-cased with every character that is not a letter, digit
or underscore replaced by `_` — so a workspace owned by `acme-corp` reads
`ACME_CORP_ALLOWED_PUSH_OWNERS`.

| variable | effect |
|---|---|
| `<OWNER>_ALLOWED_PUSH_OWNERS` / `WORKSPACE_ALLOWED_PUSH_OWNERS` | owners a push may target. Defaults to the workspace's own owner |
| `<OWNER>_ALLOWED_PUSH_REPOS` / `WORKSPACE_ALLOWED_PUSH_REPOS` | a finer list, as `owner/repo`. Checked **before** the owner list, which is what makes it useful: allowing one repository must not mean allowing everything its owner will ever hold |
| `<OWNER>_ALLOW_UNSAFE_PUSH=1` / `WORKSPACE_ALLOW_UNSAFE_PUSH=1` | bypass the guard entirely for this push |
| `WORKSPACE_PINNED_OWNER` | pin the owner instead of deriving it from `origin`. No per-owner spelling — the owner is what it declares, so there is nothing to key one on |

### Pin the owner; do not derive it

The owner this guard judges against **should be declared, not inferred**. Deriving
it from `origin` is tautological for the one remote most likely to be wrong:
repointing origin at a public upstream — the exact accident the guard exists to
prevent — also repoints the allow-list, so the push is permitted and the hook
exits 0. A pinned constant cannot be moved by the mistake it guards.

Two ways to declare it, checked in this order:

| where | notes |
|---|---|
| `WORKSPACE_PINNED_OWNER` | environment; convenient, and as durable as the environment is |
| `.git-guards-owner` in the workspace root | one line, committed. **The stronger one:** repointing origin cannot touch it, and changing it is a diff somebody reviews |

With a pin in place, a repointed `origin` is refused outright rather than quietly
becoming the new allow-list. With neither, the guard falls back to the
origin-derived owner, so it still works in a repository that has declared
nothing — it is simply the weaker mode, and it says so.

The workspace is resolved from the repo being pushed — `git rev-parse
--show-toplevel`, then out through any enclosing work trees, stopping below
`$HOME`. So a submodule, or a plain clone sitting inside another checkout, is
judged against the owner of the workspace that contains it, and `$HOME` being a
dotfiles repo never turns into "the workspace" for everything beneath it. The
owner comes from that workspace's `origin`, else the pushed repo's own; the
directory name is a last resort.

It is deliberately *not* inferred from this script's own path: hook runners copy
these files into a cache (`~/.cache/prek/repos/<hash>/`), so `dirname($0)/..`
names the cache, not your workspace — which reads `repos` as the entire
allow-list and refuses every push, including a repo pushing to its own origin.
`tests/` covers this by running the guard from a cache-shaped copy.

`prevent-author-mismatch` requires the author **and** committer of each commit
to match your global identity — the `user.name` / `user.email` in `~/.gitconfig`
(`git config --global`). The identity it checks is resolved via `git var`, so it
catches a stray repo-local `user.email`, `git commit --author=...`, and
`GIT_AUTHOR_*`/`GIT_COMMITTER_*` environment overrides alike. This stops an agent
from `git init`-ing a fresh repo and committing under the wrong author. There are
no env vars or extra config to set: the global identity is the single source of
truth. Bypass once with `git commit --no-verify`.

`no-stale-hook-pins` reads every `- repo:` / `rev:` pair in
`.pre-commit-config.yaml`, asks each upstream for its tags with `git ls-remote`,
and exits non-zero naming any pin that is behind — the repo, the version it is
pinned to, and the version that exists.

It exists because the `rev:` is the only version of a shared hook a repository
actually runs, and nothing else looks at it. Runners fetch exactly what the pin
names and report a clean run, so a pin two releases behind and a pin written
this morning are the same green tick. What used to watch them was a dependency
updater, and the way it stopped is the point: its release-cooldown filter is on
by default, so with no cooldown configured anywhere it still applied one —
it saw the newer version, discarded it, kept the old one, wrote
`Latest version is <the old one>` into a job log, and raised no pull request.
Dozens of repositories sat two versions behind for weeks while every surface
said healthy.

So the three outcomes are kept apart, and the third one is the reason this is
worth having:

| exit | meaning |
|---|---|
| `0` | every remote pin was compared against its upstream and is current |
| `1` | at least one pin is **behind**, with both versions named |
| `2` | at least one pin could not be checked **at all** |

A remote that timed out, an upstream with no tags, an upstream whose tags are
all code names, a `rev:` that is a branch or a commit sha, a `rev:` naming a tag
the upstream no longer has — none of those is evidence that a pin is current,
and answering `0` for them would be reproducing, in fewer lines, the
`Latest version is …` this replaces. Cannot look is not up to date.

A config whose entries are all `local` or `meta` exits `0` and says
`NOTHING was verified`, because "checked four and they are level" and "checked
none" must not print the same sentence.

A prerelease is a candidate only when the upstream has no stable release at all.
An upstream that tags an `rc` is not asking every consumer onto it, and a check
that demanded the move is one people switch off — but an upstream that has *only*
ever tagged prereleases still has a newest one, and calling that "no versions
here" would be a false clean answer.

The known cost of that rule, so it is a decision rather than a surprise: semver
reads everything after a hyphen as a prerelease, and a Debian-style revision
suffix is spelled the same way. While *every* tag carries one there is no stable
pool, the whole set competes, and the newest wins; but one bare tag appearing
beside them flips the pool to stable-only and the suffixed releases stop being
candidates. With tags `v3.13.0-1`, `v3.13.1-1`, `v3.14.0` and `v3.15.0-1`, a pin
of `v3.14.0` is judged **current**. The alternative is to guess which hyphen
means what, and a check that guesses about version order is the thing this
replaces.

| variable | effect |
|---|---|
| `GIT_GUARDS_PINS_HELD` | pins deliberately not moved: `owner/repo` or `owner/repo@rev`, comma or space separated |
| `GIT_GUARDS_ALLOW_UNCHECKED_PINS=1` | a pin that could not be checked becomes a printed note and exit `0` — the offline path |
| `GIT_GUARDS_ALLOW_STALE_PINS=1` | one-off bypass |
| `GIT_GUARDS_PIN_TIMEOUT` | seconds per `git ls-remote` (default 20). Unreadable is refused, not silently defaulted |

Write a hold as `owner/repo@rev`. That form expires by itself the moment the pin
moves; a bare `owner/repo` is an exemption with no end date, which is how a
temporary decision becomes a permanent one nobody remembers making. A hold that
matches no behind or unchecked pin is reported, for the same reason an unused
allowance is.

It runs at **pre-push** and **manual**, never at pre-commit: one `git ls-remote`
per hook repo is a network round trip, and a check that adds one to every commit
gets commented out. It takes no file list, and `always_run` — at pre-push a
runner passes the files being pushed, and `.pre-commit-config.yaml` is almost
never one of them. A pin check that runs only when the pin file changes never
runs, because the config not changing *is* the problem.

It reads **one config**: the `.pre-commit-config.yaml` at the top of the current
work tree. That is a limit worth knowing, because prek is a *workspace* runner —
it discovers and runs a nested `.pre-commit-config.yaml` under a subdirectory,
and inside a nested independent repository, and a pin that is behind in one of
those is a pin this check never looked at. So every run prints the configs it
read, above the counts, and "every pin was compared" is a claim about exactly
those files. Name more of them as arguments to cover a monorepo:
`no-stale-hook-pins.py a/.pre-commit-config.yaml b/.pre-commit-config.yaml`.

There is deliberately **no cache**. Remembering each upstream's newest tag for a
day is the same idea as the cooldown that caused this, and it fails the same
way: the stale answer is indistinguishable from a fresh one at the point where
somebody reads it. Within a single run each URL is asked once.

It is Python rather than shell for two reasons that are both about honesty.
Version order is not string order — `git ls-remote` lists `v1.7.9` after
`v1.7.12`, so the naive shell answer is wrong in the direction that reports a
behind pin as current, and `sort -V` does not exist on BSD sort. And a `rev:` is
one line of YAML: grepping for it reads a `rev:` inside a hook's `args:`, inside
a `local` hook's `entry:`, and inside a comment. The config is parsed with
PyYAML when it is importable — `yaml.compose`, so scalars arrive as written and
findings carry a line number — and otherwise by a narrow reader that refuses,
by name and line, anything it does not model. `tests/` runs every case through
both and requires the same answer.

Where the two readers *cannot* agree, the config is unreadable rather than
judged. A duplicated `repo:` or `rev:` is the case: YAML 1.2 calls it an error,
PyYAML — what pre-commit runs — lets the **last** one win, and prek refuses the
file outright, so there is no interpretation that is right about every runner.
It is exit `2` naming the line, which is one deleted line away from being fixed.

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

Then `prek install` (or `pre-commit install`). Repo-specific hooks (cargo, zig,
ruff, shellcheck, branding checks, CI) stay in the consuming repo's own config.

## Updating

A release is a new tag, and consumers bump their `rev:` to it. The tempting
alternative is one tag that moves with `main`, so nobody has to sweep dozens of
consumers — and it is the worse half of a trade, because it makes every
consumer's pin a statement about whatever `main` happened to be the day their
cache was filled. Two repositories on the same `rev:` would then be running
different code, and neither could say which.

So the sweep is real, and `no-stale-hook-pins` is what makes it visible: run it,
and every pin that is behind names itself, both versions included.

The other cost is caching. Runners cache by `rev`, so a machine that already
fetched a tag keeps its copy until `prek clean` — if a fix "isn't working", that
is the first thing to check, and the reason CI (which starts cold) can disagree
with a laptop.

## Claude Code Agent Setup

The `prevent-ai-author` commit-msg hook reads one thing — the commit message
file — and rejects two markers in it: a `Co-Authored-By` trailer with a
`noreply@` address, and a `Generated with [Claude/Copilot/…]` line.

It does **not** see pull request bodies. Nothing installed as a git hook can:
a PR description is typed into a CLI or a web form and reaches the forge without
passing through git at all. Keeping a marker out of a PR body is what the `pr`
key below is for, and `no-private-repo-names --text` is the mode for checking
text that is on its way somewhere git will never look.

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
