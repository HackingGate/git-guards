#!/usr/bin/env bash
# The environment variables a git-guards test must not inherit, named.
#
# A suite whose result depends on the caller's environment cannot be trusted by
# the person most likely to run it. Every variable this file names is one the
# README tells a consumer to export, and exporting them is what somebody does
# just before running the tests to see whether the guards work. Measured on the
# suite as it stood:
#
#   GIT_GUARDS_PRIVATE_OWNERS=acme ./tests/no-private-repo-names-test.sh
#       19 assertions failed
#
# and with the full set a consumer might have exported -- the private-owner
# list, a visibility, REFUSE_UNKNOWN, a public-repo allowance, the pin bypasses,
# the push allow-list and a pinned owner -- 285 assertions failed across five
# files. None of them was a defect in a guard. Every one was the suite asserting
# one thing and the environment answering another, in whichever direction the
# caller's exports happened to point.
#
# PRE_COMMIT_* is in the list for a different reason, and a sharper one. The
# scope resolver reads PRE_COMMIT_TO_REF to learn which commit is being pushed,
# so a suite run from inside somebody's own pre-push hook -- which is exactly
# where a hook runner runs a test declared at that stage -- would make every
# tree-wide scan below read THAT push's commit instead of the fixture it just
# built. The failure would be a scan of the wrong repository reporting a
# denominator and exiting 0, which is the whole class of defect these guards
# exist to refuse.
#
# ONE list, read by every test, because a scrub each file wrote for itself is a
# scrub the next test file forgets. Shell tests source it:
#
#   while IFS= read -r name; do unset "$name"; done < <("$here/hermetic-env.sh")
#
# and the Python test runs it as a subprocess and pops each name out of
# os.environ. A child process inherits the environment it is being asked about,
# which is what makes one implementation serve both languages.
#
# Names, not assignments: a test that needs one of these sets it itself, per
# case, where a reader can see which value the case is about.
set -euo pipefail

# `compgen -e` lists EXPORTED names, which is the whole of what a child process
# can inherit and therefore the whole of what matters here.
#
# The three prefixes are the guards' own namespaces. The four suffixes are the
# per-owner spellings prevent-public-push accepts -- `<OWNER>_ALLOWED_PUSH_OWNERS`
# and friends, where <OWNER> is any workspace owner upper-cased -- which have no
# common prefix to match on and must be matched by their tails instead.
compgen -e | LC_ALL=C grep -E \
    '^(GIT_GUARDS_|PRE_COMMIT_|WORKSPACE_)|_ALLOWED_PUSH_(OWNERS|REPOS)$|_ALLOW_UNSAFE_PUSH$|_PINNED_OWNER$' ||
    true
