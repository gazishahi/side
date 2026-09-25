# Distribution

*2026-09-24. Status: **in progress**: signing, packaging and updates built; notarization waits on the owner's credentials; the open-source packages are next.*
*Companion to `SIDE_PRODUCT_CONSTITUTION.md` (Heron and Alloy are engines Side is a client of).*

## What ships

| Thing | Form | License | Where |
|---|---|---|---|
| Side | Developer ID–signed, notarized `Side-<version>.dmg` | private (D4) | `gazishahi/side-releases` on GitHub (D2) |
| Heron | Swift package (`Packages/Heron` today) | Apache-2.0 (D3) | its own public repository (D5) |
| Alloy | Swift package (github.com/gazishahi/alloy, 0.1.1) | Apache-2.0 (D3) | its own public repository (D5) |

## Version

Side starts at **0.1.0** (`MARKETING_VERSION`), build **1** (`CURRENT_PROJECT_VERSION`). 0.x says
formats and behavior may still change. Each release raises the build number; the version moves at
milestones (0.2, 0.3…). **1.0** waits for: stable on-disk formats that migrate forward (tracks,
conversation records, settings), verified built-in agents, and a clean audit.

Heron and Alloy version on their own (SemVer from 0.1.0); Side pins the versions it ships with.

## Launch gates

1. Distribution (this document).
2. **Alloy built.** Decided by the owner 2026-09-24: Alloy ships before Side's first release. **Met 2026-09-24:** Make runs on Alloy only, inside every budget (`SIDE_RFC_ALLOY.md`, step 7); publishing it is step 8.
   Proposed in `SIDE_RFC_ALLOY.md`.
3. A fresh audit since 2026-09-01 (outside agents, multi-agent, Integration, Library landed after).
4. Codex, Gemini CLI and Pi verified live, or labelled experimental.
5. Dark mode, VoiceOver and text-size pass on the redesigned Preferences and Library.
6. A clean-account first-run walkthrough.
7. License, privacy note, crash-reporting decision, landing page.

## Side: signing and packaging

**Built 2026-09-24.** Release builds use the hardened runtime (Debug doesn't, so XCTest can inject
into the test host). Side needs no entitlement exceptions: it isn't sandboxed (an IDE runs your
tools), dictation is the system's, and Keychain items are the app's own. `scripts/release.sh`
archives, exports with Developer ID, verifies the signature, notarizes and staples the app, builds
and signs the DMG, notarizes and staples that, and writes its SHA-256. `--dry-run` stops before
notarization. Verified: a dry run with the owner's Developer ID certificate produced a signed
`Side-0.1.0.dmg` (Authority: Developer ID Application, flags: runtime).

**Needs the owner, once:** `xcrun notarytool store-credentials side-notary --apple-id … --team-id D3MM423T6V`
(an app-specific password; stored in the Keychain, never in the repo). Then `SIDE_TEAM_ID=D3MM423T6V scripts/release.sh`.

## Updates

**Built 2026-09-24.** Sparkle 2.10 (`Updates`): Side › Check for Updates…, and Preferences ›
General › Updates (automatic checks on or off, check now, the running version). Debug builds and
UI-test runs never check. The feed is the latest release's `appcast.xml` in the public releases
repository; each update is verified against `SUPublicEDKey` (Side's own key, Keychain account
`side`, separate from any other app's) and its Developer ID signature before it installs.
The app target sets `@executable_path/../Frameworks` as a runtime search path: without it
Sparkle's framework isn't found and the app dies at launch (found 2026-09-24; tests couldn't catch
it because the test runner supplies its own framework path), and `release.sh` now refuses a build
whose linked frameworks don't resolve inside the app. `scripts/release.sh` now writes the signed `appcast.xml` next to the DMG and prints the
`gh release create` command; publishing is left to the owner because it's public.

## Heron: ready to publish

**Built 2026-09-24 (local; nothing published).** `Packages/Heron` is laid out as its own
repository: `LICENSE` (Apache-2.0, the canonical text), `NOTICE`, `README.md`, `.gitignore`, and
a GitHub Actions workflow (`swift build`, `swift test` on macOS 15). The 24 test files that need
only Heron moved from `SIDETests` into `Packages/Heron/Tests/HeronTests`: 140 tests pass with
`swift test` alone. The app keeps its own 28. `scripts/test.sh` runs both.

Left before the split (D5): an API pass (today's `public` is whatever the app needed), then
`git subtree split --prefix=Packages/Heron` into `gazishahi/heron`, tag `0.1.0`, and point Side at
it by version. `gazishahi/heron` exists (created 2026-09-24) with GitHub's own initial LICENSE
commit; the split history won't descend from it, so the first push replaces it (`--force`, once,
on a repository with nothing else in it). `gazishahi/side-releases` exists with a README.

## Decisions

Answered by the owner 2026-09-24: **D1** Sparkle, **D2** GitHub Releases, **D3** Apache-2.0,
**D4** Side stays private; only Heron and Alloy are open source. So releases go to a public
repository of their own (`gazishahi/side-releases`: DMGs and appcasts, no source), since assets on
a private repository can't be downloaded.


- **D1: Updates.** *Recommend:* Sparkle 2 with an EdDSA-signed appcast. Sparkle is the standard
  for Developer ID apps, open source, and needs no server of ours beyond a static appcast file.
  The private signing key lives in the owner's Keychain; the public key ships in the app.
- **D2: Where the DMG and appcast live.** *Recommend:* GitHub Releases for the DMG, and the
  appcast on the landing page's host (or a Releases asset). No infrastructure to run.
- **D3: Heron and Alloy's license.** *Recommend:* Apache-2.0: permissive like MIT, plus an
  explicit patent grant, which matters for an engine others embed. MIT if simplicity wins.
- **D4: Is Side itself open source?** Decides whether the Heron repository is split out of a
  private Side repository (D5) or everything lives in one public one.
- **D5: How Heron leaves this repository.** *Recommend:* `git subtree split` so the public repo
  keeps Heron's history; Side then depends on it by version tag, with a local-path override for
  development. Before the split: tests that need only Heron move into `Packages/Heron/Tests` so
  the public repo builds and tests on its own (it already builds: `swift build` in the package),
  and the public API gets a pass (what's `public` today is whatever the app needed).
- **D6: Homebrew.** *Recommend:* a cask after 0.1 ships (`brew install --cask side`); it reads the
  same DMG.
