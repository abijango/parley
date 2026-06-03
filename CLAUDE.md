# Macsribe — project instructions

Native macOS menu-bar meeting transcriber. `Macsribe` is a **placeholder name**
(`grep -rn "TODO(app-name)"` finds every spot to sweep on rename).

## Building

`Macsribe.xcodeproj` is **generated** by `xcodegen generate` from `project.yml` — it is
git-ignored. Make project-*setting* changes in `project.yml`, never in the Xcode UI (they
get overwritten on the next regenerate).

- **Quick dev build:** `xcodegen generate` then open in Xcode (⌘R), or
  `xcodebuild build -project Macsribe.xcodeproj -scheme Macsribe -destination 'platform=macOS,arch=arm64'`.
- **Installed local release:** `Tools/localrelease.sh` (add `--open` to launch).

## `Tools/localrelease.sh` — use this for each rebuild the user runs locally

Builds the `Macsribe` scheme in **Release** and installs it to `~/Applications/Macsribe.app`,
replacing the previous copy. Prefer this over a raw `xcodebuild` whenever the user wants an
installed build they run between sessions.

Why it matters: the script signs every build with a **stable, self-signed cert**
(`<PRODUCT_NAME> Local Codesign`, auto-created once and reused). A stable signing identity
gives the app a constant designated requirement, so macOS preserves across rebuilds:

- TCC permissions (mic, system-audio capture, folder access)
- keychain grants
- the ANE specialization cache (`~/Library/Caches/<bundleID>/com.apple.e5rt.e5bundlecache`)

Xcode's default *ad-hoc* signing changes the code hash every build, which resets all three —
re-prompting for permissions and re-running the minutes-long ANE `Specializing…` step. The
cert is keyed to the app **name**, so a rename mints a fresh identity by design (the bundle
id changes too). It's a **local** identity only — not notarized; public distribution still
needs archive → export → notarize → staple.

## Gotchas

- Don't run two builds at once / edit source mid-build: a Release whole-module compile that
  reads files being edited fails with `Failed frontend command` (a `swift-frontend` crash),
  not a real `error:`. Re-run once the files settle.
- The app is **non-sandboxed** (`app-sandbox: false`) — required for Core Audio process taps,
  spawning `claude`, and writing to the vault. Deployment target is macOS **14.4+** (process
  taps).
