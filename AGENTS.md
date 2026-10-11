# AGENTS.md

Rules for working in this repository. They exist because the folder has a
history of drifting away from what is actually shipping, and because two agents
have been working here in parallel.

## Workflow

- **Work from `main` on short-lived branches.** `main` is the production release
  state. Do not treat it as a staging area.
- After every Shorebird release **or patch**, add an annotated git tag and a
  `RELEASES.md` row in the same change. A release without a tag is a release
  nobody can find again.
- **Never build a release from uncommitted changes.** A script or agent doing a
  release must refuse a dirty tree. An artifact nobody can reproduce is not a
  release, it is a mystery.
- **Never reuse a version.** Each release gets a new version and a new tag.
- **Patches are Dart-only.** `shorebird patch` cannot carry native code or
  assets. If a change touches `android/` or `ios/`, it needs a release, not a
  patch.
- Verify a release commit before trusting it: rebuild it, confirm `libapp.so`
  has the same size and string set as the shipped artifact, and run
  `shorebird patch --release-version=<version> --dry-run`. A near-zero diff and
  "No issues detected" means you have the right commit.

## Never touch

- `shorebird.yaml`'s `app_id`, any keystore, `android/key.properties`, `key.*`,
  signing configuration, or the `Shorebird_Release_*` folders on the Desktop.
  Copy files **out** of the release folders; never edit them.
- Secrets are never committed. `key.properties.example` is the committed
  template; the real `key.properties` and `.env` are gitignored and stay that
  way.

## Publishing

- `shorebird release` and `shorebird patch` are **publishing** actions. Run
  `--dry-run` first, always. Never run a publish implicitly or as part of a
  build.
- A patch is only safe when it carries the one change it claims to. Build it
  from the release commit plus the intended diff, not from the tip of a
  feature branch, or you will sweep in whatever else is there.
- `shorebird patches promote` and `set-track` are also publishing actions and
  are deprecated in favour of `set-track`; check the flag before using either.

## Parallel agents

Check before you start: `git status`, `git worktree list`, and
`ps aux | grep -E "flutter|gradle|dart|shorebird"`. If a build or an uncommitted
edit you did not make is in progress, **stop and report** — another agent may be
working here.

Do all builds and comparisons in a **worktree**, never in the main folder, so a
build cannot dirty the tree someone else is using. Do not commit
`pubspec.lock` or `Podfile.lock` changes produced by `flutter pub get` in a
scratch worktree.
