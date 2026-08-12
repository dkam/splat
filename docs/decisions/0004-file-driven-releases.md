# 0004 — The version constant cuts the release, and CI creates the tag

**Date:** 2026-08-12
**Status:** Accepted

## Context

Splat tracks two different things and had a name for only one of them.

- **version** — which release this is. Hand-set SemVer in `config/version.rb`,
  survives a rebuild of identical code, goes in a changelog, gets said out loud.
- **revision** — which commit the running container was actually built from.
  Precise, automatic, meaningless to read.

Splat had the version and no revision at all. The Dockerfile carried a comment
claiming "REVISION file is created by bin/build script"; `bin/build` had not
done that for as long as anyone could check. So "is the thing I deployed the
thing that's running?" had no answer beyond trusting the image tag.

Worse, the version had quietly stopped meaning anything in git.
`config/version.rb` read **1.14.0** while the newest git tag was **v1.7.8** —
eight releases with no commit you could check out. The image tags kept moving
because `build.yml` published them automatically; the git tags stopped because
tagging was a separate manual step, and manual steps stop happening.

## Decision

**Bumping `config/version.rb` on `main` is the release**, and everything else is
a consequence of it. `build.yml` already triggered on that path and published
the multi-arch image; it now also creates the git tag and GitHub Release in the
same run.

- The Dockerfile writes `VERSION` in the build stage from `ARG GIT_SHA`;
  `config/initializers/revision.rb` reads it at boot into `config.x.revision`,
  falling back to `git rev-parse` in **development only** — a deployed
  container has no business shelling out on boot.
- `bin/build` and CI both pass `--build-arg GIT_SHA`.
- A pre-release (any version with a hyphen) publishes its own image tag, does
  not move `:latest`, and earns no git tag.
- The tag job is idempotent: re-running the workflow on an unchanged version is
  a no-op, not a failure.

## Alternatives considered

**Tag-driven** — `git tag v1.2.0`, CI fires on `tags: v*`. Rejected: the version
would exist only in git, so the running app could not report its own version
without being told, and a release would not be reviewable — a tag has no diff.

**SHA-only** — build every push, no version at all. Honest, and it is what the
revision already gives us. Rejected as the *only* scheme because nothing would
have a human name, so "which release broke it" would have no answer.

**Leaving tagging manual.** Rejected by evidence: eight versions of drift is
what manual tagging produced here.

## Consequence worth expecting

The first run of the new `tag` job will create **v1.14.0**, skipping straight
past the v1.7.8..v1.13.x range that was never tagged. That is correct — those
releases exist as published images, not as commits anyone marked — and the gap
in the tag list is an accurate record of the period when this was manual.

## The part that nearly broke

Adding `GIT_SHA` meant touching the Dockerfile, which surfaced that
**nothing in this app ever boots in `RAILS_ENV=production` except
`assets:precompile`** — a boot with no runtime configuration present at all.
`config/application.rb` raised on a missing `SECRET_KEY_BASE`, and the build
only worked because the Dockerfile set `SECRET_KEY_BASE=1` to fake one past it.

The rule that resolves this class of problem: **a check that guards *serving
traffic* must not fire while *compiling assets*.** `SECRET_KEY_BASE_DUMMY` is
the signal Rails itself sets to mean "this boot will never serve a request", so
that is what the guard tests — not a faked secret, and not a task name. Pinned
by `test/config/build_boot_test.rb`, which asserts both that the exemption
exists and that there is exactly one of it.

`ci.yml` now builds the production image on every PR (amd64, `push: false`).
Without it the Dockerfile is first exercised *by the release itself*, which is
the worst possible moment to discover any of the above.
