# Releases

The mapping between what is live on the phones and what is in this repository.
Every Shorebird release or patch must add a row here; see AGENTS.md for the rules
that keep this table honest.

## How a release commit is identified

A release commit is the one whose `pubspec.yaml` version matches the release and
which reproduces the shipped artifact. For `1.1.9+24` that was confirmed by:

- the installed `base.apk` on device `7d99a8b5` is **byte-identical** to the
  packaged `InfinityCore-1.1.9+24-universal-OTA.apk`
  (sha256 `9e60b32712da5505d204fa1c1e2d345576578326e63a4565c16ef88e059a8f08`),
  so the phone is not running a Play-re-signed build and the artifact is the
  ground truth for what 1.1.9+24 is;
- rebuilding the commit produces `libapp.so` at **exactly** 10 945 416 bytes, the
  same size as the release binary, with an identical string set;
- `shorebird patch android --release-version=1.1.9+24 --dry-run` reports
  **"No issues detected"**, i.e. a near-zero Dart diff and no native or asset
  warnings;
- the rebuilt `.aab` is 70 314 057 bytes against the packaged 70 314 245 bytes
  (188 bytes, explained by signing metadata and build timestamps).

## Releases

| Version | Commit | Git tag | Shorebird release ID | Flutter | Build date | Artifact SHA-256 | Patches | Notes |
|---|---|---|---|---|---|---|---|---|
| 1.1.9+24 | `c18defa` | `release/v1.1.9+24` | 888750 | 3.47.6 (`c98f9e9a90`) | 2026-10-10 10:55 | universal APK `9e60b32712da5505d204fa1c1e2d345576578326e63a4565c16ef88e059a8f08` (93 083 072 B); AAB `6a499062145752b56c030ad7f380e81ed97b339c39a8e68b125e1e4b55b955e7`; IPA `49dbf6768c24e3da5b596fe259fd5d3fe6101b041dfcfb20ea01f1309b5b00b0` | #1 `708893` stable · #2 `710759` stable, **rolled back** · #3 `711061` stable · #4 `711514` stable · #5 `712193` stable (android) · #6 `712224` stable (ios) · #7 `712752` **no track** (not this repo's — see Patch source commits) · #8 `712755` stable (android) · #9 `712773` stable (ios) | default ABI set (32-bit device crashed on arm64-only APK). Release source verified as above. Create-account hotfix shipped as patches #5/#6; messaging fixes (staff search + tab-scoped FAB) as #8/#9. |
| 1.1.9+23 | `1b6e7c2` | — | 888742 | 3.47.6 | 2026-10-10 | not recorded | none | OTA-enabled full release (queue PRAGMA + Add Fence layout). |
| 1.1.9+22 | `9355964` | — | 888690 | 3.47.6 | 2026-10-10 | not recorded | none | native apikey repair + Dart cadence fallback. |
| 1.1.8+21 | `6cfdd62` | `v1.1.8+21` | 888564 | 3.47.6 | 2026-10-10 | not recorded | none | offline-queue guarantees + clock-independent tracking. Only other tag in the repo. |
| 1.1.8+20 | `3eb157b` | — | 887671 | 3.47.6 | 2026-10-10 | not recorded | none | Use My Location on Add fence, resilient heartbeat GPS, tracking SQL pack. |
| 1.1.8+19 | `4d00bf5` | — | 886692 | 3.47.6 | 2026-10-10 | not recorded | none | 1.1.7 launch crash (R8/WorkManager) + tracking hardening. |

Rows above 1.1.9+24 are reconstructed from `git log` and `shorebird releases
list`. Their artifact hashes and patch histories were **not** verified, because
only the 1.1.9+24 artifacts were available on disk — treat those cells as
UNVERIFIED rather than assume they are right.

## Patch source commits

Shorebird exposes no creation timestamp through `patches list`, and
`shorebird patches info` hangs, so a patch's source commit cannot be read from
the server. What is known:

| Patch | Track | Source | Evidence |
|---|---|---|---|
| #3 `711061` | stable | `423024f` (role_guard gate change only) | **Known.** Built deliberately from the release commit `c18defa` plus the `lib/core/security/role_guard.dart` diff of `423024f` and nothing else, so the patch carries only that change. |
| #4 `711514` | stable | `3cd776f` (Employee Tracking 48 h filter) | Recorded from the existing git tag `patch/v1.1.9+24-4`, which names the source commit. Tagged 2026-10-11 but never given a row until now. |
| #5 `712193` (android) · #6 `712224` (ios) | stable | `6b9d2a7` (Create account login hotfix) | **Known.** Built from `main` at `6b9d2a7` — the release commit `c18defa` plus a docs-only commit and this one Dart-only change. `--dry-run` on both platforms reported **"No issues detected"**. One commit, two platform patches, published to stable together. |
| #7 `712752` | **no track** | UNVERIFIED | Published from an unknown source between #6 and #8 (a parallel agent was active in the `mobile-messages-fix` worktree at the time). Not built, tracked or promoted from this repository. |
| #8 `712755` (android) · #9 `712773` (ios) | stable | `0e059f5` (staff search + tab-scoped FAB) | **Known.** Built from `main` at `0e059f5`, which is the release commit `c18defa` plus two Dart-only commits (no new SQL: the fix calls the already-live `get_messaging_directory` RPC). `--dry-run` on both platforms reported **"No issues detected"**. Numbering jumps #6 → #8 because #7 is another agent's untracked patch. |
| #1 `708893` | stable | UNVERIFIED | No creation time available. |
| #2 `710759` | stable, rolled back | UNVERIFIED | No creation time available. Cannot be deleted — Shorebird has no delete operation; it is inert because it is rolled back. |

A shorebird patch is a **Dart-only** diff against the base release. Native code
and assets cannot travel in a patch, so a change to either needs a new release,
never a patch.

## Post-release work (not on `main`)

`main` is the release state. Everything built after `c18defa` lives on its own
branch and was deliberately **not** merged into `main`:

| Branch | Commits ahead of main | What it is |
|---|---|---|
| `release/1.1.7-offline-queue` | 3 (`a501c26`, `6ac4617`, `423024f`) | Employee Tracking reading the same source as web; mobile reporting the same reason as web; widened Staff Analytics / Employee Tracking / Geofences. |
| `feat/director-intelligence-mobile` | 1 (`a501c26`) | the tracking-source change above. |
| `fix/messages-visibility` | 0 | already contained in the release history; its worktree holds an uncommitted edit to `lib/features/messages/messages_screen.dart` belonging to another agent. |
| `wip/pre-sync-20261011-1754` | 4 | the three above plus a preserved test-coverage change to `test/smart_navigation_test.dart`. |
