---
audience: developer
title: Releasing and the updater
summary: The release signing key, building a release from a tag, signing and publishing release.json, and what the editor's updater accepts.
order: 20
---

# Releasing and the updater

VisualBeef updates itself from the GitHub Releases of the public repository
(<https://github.com/AproposRobin/VBeef/releases>), the same way the UniversalUMP launcher does: every release carries a
signed descriptor, `release.json`, and the editor installs only what that descriptor names, after checking its
Ed25519 signature, its sequence and each file's size and SHA-256. The user's side is in [Updating.md](Updating.md).

## The rule: no release without a smoke pass

**Nothing is published without a verified stable build and a regression pass on the exact artifact that ships**
(owner, 2026-10-12). The pass is `scripts/release-smoke.ps1`: it takes the full win64 zip of the release, checks it,
unpacks it into a scratch folder and drives the packaged `VisualBeefEditor.exe` through the end-to-end session matrix,
a fresh-settings first start, the update end to end and a soak ([Testing.md](Testing.md#release-smoke) lists
every step). It writes `build/smoke/smoke-<first 12 hex of the zip's sha256>.json`, and `release.mjs publish` refuses
without a passed, complete report for the SHA-256 of the zip named in `release.json`. A report for another file, a
failed one and a partial one (`-Only`) do not count. The one escape is
`publish --force-unsmoked "<reason>"`: it publishes anyway and appends the reason to the release notes, so it is on the
release page for everyone to read. `sign` prints a warning while no report exists.

| Piece | Where |
|---|---|
| Descriptor, canonical text, signature check, version order, platform choice | `VisualBeefCore/src/Update/ReleaseDescriptor.bf` |
| Ed25519 + SHA-512 (pure Beef, from UniversalUMP's launcher, TweetNaCl port) | `VisualBeefCore/src/Update/Ed25519.bf` |
| **The trusted public key(s)** | `VisualBeefCore/src/Update/ReleaseKeys.bf` (one constant) |
| Check, download, verify, stage (worker thread) | `VisualBeefCore/src/Update/UpdateService.bf` |
| HTTPS through the system's curl | `VisualBeefCore/src/Update/UpdateHttp.bf` |
| Install helper, swap / rollback, health check | `VisualBeefCore/src/Update/UpdateApply.bf` |
| Small JSON reader | `VisualBeefCore/src/Update/UpdateJson.bf` |
| Notice line, Help > Check for Updates, Preferences > Updates | `VisualBeefEditor/src/Updates.bf` |
| Release tooling (keygen, sign, publish, verify) | `scripts/release.mjs` (Node 24, built-in crypto only) |
| The smoke pass that `publish` requires | `scripts/release-smoke.ps1`, [Testing.md](Testing.md#release-smoke) |
| Tests | `VisualBeefTests update` (and `update -net` by hand), [Testing.md](Testing.md#update) |

## The signing key (once)

The private key never enters a repository or a CI secret; the owner keeps it offline and signs on their own machine.

```powershell
# 1. Make the key pair. Default path: %USERPROFILE%\.ump\vb-release-signing.key (+ .pub). Refuses to overwrite.
node scripts\release.mjs keygen
#    or choose the place:
node scripts\release.mjs keygen --out D:\keys\vb-release-signing.key

# 2. Paste the printed public key (the .pub file's line) into VisualBeefCore\src\Update\ReleaseKeys.bf:
#      public const String Keys = "<base64 public key>";
#    and commit it. Builds made before that commit trust no key and never install an update.

# Print the public key of an existing private key:
node scripts\release.mjs public --key D:\keys\vb-release-signing.key
```

**Custody.** Back the private key up (two offline copies). Whoever has it can make every installed editor accept a
release, so it never goes to CI, chat, mail or a cloud folder. If it is lost, editors already installed cannot be updated
any more (the users download the next version by hand); if it leaks, publish a release whose `ReleaseKeys.bf` holds only a
new key and say so on the release page.

**Rotation.** `Keys` takes several keys separated by `;`. Add the new key next to the old one, release, sign the
following releases with the new key, then remove the old key in a later release.

## Making a release

1. Bump `VisualBeefInfo.Version` (and `Channel`) in `VisualBeefCore/src/Document/CommandLine.bf`, rebuild `vbhost.dll`
   when its version resource must follow ([Linux.md](Linux.md), `Native/build_windows.ps1`), commit, push.
2. Tag the commit `v<major>.<minor>.<patch>` and push the tag. The Windows workflow builds and tests, packages the full and
   the minimal zip, attests them and puts them with their `.sha256` files on **one draft pre-release** for the tag. The
   Linux workflow does the same for the tarball and the AppImage, on the same draft. Nothing is public yet.
3. **Smoke the exact zip.** On the owner's machine, in a desktop session (the editor opens real windows; leave the
   keyboard and mouse alone for about ten minutes), from the repository root:

   ```powershell
   powershell -File scripts\release-smoke.ps1 -Tag v0.2.0
   ```

   It downloads the full win64 zip and its `.sha256` from the draft, checks the hash and `gh attestation verify`, and runs
   the pass. Exit 0 and `RESULT: PASSED` mean `build\smoke\smoke-<sha12>.json` now exists. Exit 1: read the Markdown
   summary beside it, fix the cause, make a new build, and smoke that (a changed zip has another SHA-256, so the old report
   no longer counts). Never weaken the pass to get a release out.
4. When both workflows are green and the smoke pass is green, sign on the owner's machine (PowerShell, from the repository root; `gh` logged in):

   ```powershell
   $env:Path = "$env:USERPROFILE\.local\node;$env:Path"
   node scripts\release.mjs sign --tag v0.2.0 --notes-file notes.md
   #   --key <file>         another private key file (default %USERPROFILE%\.ump\vb-release-signing.key)
   #   --channel preview    a pre-release (only editors on the preview channel are offered it)
   #   --dir <folder>       sign local packages instead of downloading the draft's files
   #   --sequence <n>       a sequence by hand (default: one above the highest published)
   ```

   `sign` downloads the draft's packages, hashes them (and checks each against its `.sha256`), picks the next sequence
   (one above the highest `release.json` already published), and writes `release.json`. It refuses a key that is not in
   `ReleaseKeys.bf` (the editors would refuse the descriptor) unless `--force`.
5. Check it, then publish:

   ```powershell
   node scripts\release.mjs verify release.json
   node scripts\release.mjs publish --tag v0.2.0
   ```

   `publish` first demands the smoke report for the zip's SHA-256 (`--smoke-report <file>` for one that is elsewhere;
   `--force-unsmoked "<reason>"` is the documented escape), then verifies the signature against `ReleaseKeys.bf`, checks that every named file is on the release with the
   signed size, uploads `release.json`, and publishes the release: stable = not a pre-release and marked latest (that is
   what `releases/latest/download/release.json` serves); preview = stays a pre-release. Without CI (packages built
   locally): `publish --tag v0.2.0 --create --dir dist` creates the draft and uploads the packages first.

## release.json

```json
{
  "format": 1,
  "product": "VisualBeef",
  "version": "0.2.0-alpha",
  "channel": "stable",
  "sequence": 4,
  "tag": "v0.2.0",
  "publishedAt": "2026-10-12T10:00:00Z",
  "assets": [
    { "platform": "win64", "name": "VisualBeef-0.2.0-win64.zip", "size": 3500000, "sha256": "<64 hex>" },
    { "platform": "win64-minimal", "name": "VisualBeef-0.2.0-alpha-win64.zip", "size": 3400000, "sha256": "<64 hex>" },
    { "platform": "linux-x86_64-appimage", "name": "VisualBeef-0.2.0-alpha-x86_64.AppImage", "size": 9000000, "sha256": "<64 hex>" },
    { "platform": "linux-x86_64", "name": "VisualBeef-0.2.0-alpha-linux64.tar.gz", "size": 8000000, "sha256": "<64 hex>" }
  ],
  "notes": "What changed (plain text, not signed).",
  "signature": "<base64 Ed25519 signature of the canonical text>"
}
```

The signature covers this exact text (UTF-8, `\n` line ends), with the assets sorted by `platform` (ordinal):

```
visualbeef-release-v1
product=VisualBeef
version=0.2.0-alpha
channel=stable
sequence=4
tag=v0.2.0
publishedAt=2026-10-12T10:00:00Z
asset=linux-x86_64 VisualBeef-0.2.0-alpha-linux64.tar.gz 8000000 <sha256>
asset=linux-x86_64-appimage VisualBeef-0.2.0-alpha-x86_64.AppImage 9000000 <sha256>
asset=win64 VisualBeef-0.2.0-win64.zip 3500000 <sha256>
asset=win64-minimal VisualBeef-0.2.0-alpha-win64.zip 3400000 <sha256>
```

`version` is the package's `VERSION.txt` line (`<Version>-<Channel>`); the platform of a file comes from its name
(`scripts/package.ps1`, `scripts/package_linux.sh`). `notes` is not signed and is only shown as plain text. The download
address is never read from the file: the editor builds `<repository>/releases/download/<tag>/<name>` from the signed tag
and name.

## What the editor accepts

* **Signature**: must verify against a key in `ReleaseKeys.Keys`. Empty constant: every descriptor is refused and the
  editor says "Updates are not set up in this build." No network request is made then.
* **Shape**: format 1, product VisualBeef, channel `stable` or `preview`, a whole sequence above 0, tag / version / names
  of `[A-Za-z0-9._+-]`, lower-case 64-hex SHA-256, positive sizes, no platform twice, at most 64 KiB.
* **Channel**: the stable channel reads `releases/latest/download/release.json` and accepts only `channel: stable`. The
  preview channel reads `api.github.com/repos/<owner>/<repo>/releases` (the newest release that is not a draft and has a
  `release.json`) and accepts either channel.
* **Order**: the running build's sequence is recorded in `<data>/update/installed.json` when the updater installs it.
  With a known sequence, only a higher one is offered. Without one (a fresh unzip), the release is offered when its
  version is above the running `VERSION.txt` (semantic order: numbers, then a version without a suffix above one with a
  suffix, then the suffix parts). Never a downgrade.
* **Files**: the platform's file (Windows: `win64-minimal` for a copy without `docs`, else `win64`; Linux: the AppImage
  when started as one) must have the signed size and SHA-256; a Windows zip is unpacked with the system's `tar` and must
  hold `VisualBeefEditor.exe`, `vbhost.dll`, `LICENSE` and a `VERSION.txt` naming the signed version.
* **Requests**: HTTPS only (redirects too), 5 s to connect, 20 s for the descriptor, ETag remembered
  (`<data>/update/cache`), a size cap of the signed size for the package. Offline: one Output Log line.

## Install and rollback

Windows: **Restart to finish** copies the running `VisualBeefEditor.exe` and `vbhost.dll` to `<data>\update\helper\` and
starts that copy as

```
VisualBeefEditor.exe --apply-update <install folder> <editor pid> <staged folder> <data>\update
```

then closes. The helper (no window) waits for the editor to exit (60 s), copies every top-level item it will replace into
`<data>\update\previous\` (with `.added` listing items that are new), replaces the items (a folder as a whole; a locked
file is retried for 10 s, then everything is restored), writes `last-result.json`, and starts the new editor with
`health.request`. The new editor answers with `health.ok` after its 30th frame. If it exits first or does not answer in
60 s (`VB_UPDATE_HEALTH_MS` shortens it for tests), the helper restores `previous`, rewrites `last-result.json` as a
failure and starts the old editor. On success it records `installed.json` (`{version, sequence}`). Every step is in
`<data>\update\update.log`; the next start reports `last-result.json` as a notification and deletes it.

Linux AppImage: the editor keeps a copy of the running file in `<data>/update/previous/`, writes the new file beside the
running one as `.<name>.new`, renames it over the running file (the running image stays mounted until it exits), records
`installed.json`, starts it and closes. There is no health check on Linux.

Never updated in place: development builds (no `VERSION.txt`), the copy bundled in UniversalUMP's `tools\VisualBeef`
(the launcher replaces it), Linux tarball folders, and folders the user cannot write to.

## Testing the release side

* `VisualBeefTests update` (CI, Windows and Linux): see [Testing.md](Testing.md#update).
* `scripts\release-smoke.ps1` runs the end to end below, the session matrix and the rest on the shipped zip itself.
* `VisualBeefTests update -net` (by hand, needs the network): a real check of both channels against the public
  repository through curl, the ETag cache, a download through GitHub's redirect with progress, the size cap.
* End to end on Windows: package (`scripts\package.ps1 -Minimal -Out <scratch>\install`), unzip a second copy, change its
  `VERSION.txt`, and run the packaged editor with `VB_HOME=<scratch>\home` and
  `VB_SELFTEST=update-stage:<second copy>`: it stages that folder, restarts through the helper, and the update log ends
  with `update complete`; with the second copy's `VisualBeefEditor.exe` replaced by a program that exits at once, the log
  ends with `previous copy restored` and the old version runs again.
* `node scripts/release.mjs vectors` prints the descriptor signed with the fixed TEST seed that the `update` suite
  carries; regenerate the suite's constant if the canonical text ever changes.

## Smoke results

Each published release gets one line here when its smoke pass has run.

* **v0.2.0-alpha** (`VisualBeef-0.2.0-win64.zip`, sha256 `c85e70a44e49235da683d88b37f75404b5a1e71af91815b6f5d76fc9c242a7f8`),
  smoked 2026-10-11 after publication: **PASSED**, 401 s. Hash and `gh attestation verify` OK; `--version` 0.2.0-alpha;
  the session matrix (Dark and Darker, 1280x800 and 1920x1080, 100% and 125%) eight runs `done failures=0`, no `[ASSERT]`,
  25 captures each; fresh-settings start with and without a project `done failures=0`, Check for Updates answered "up to date
  (newest release: 0.2.0-alpha)" so the release key is compiled in; the update end to end installed 0.2.1-alpha
  (`update complete`, `installed.json` sequence 2) and rolled back a program that exits at once (`previous copy restored`);
  60 s soak with no unresponsive sample and exit code 0. The report was produced by `scripts/release-smoke.ps1 -Tag v0.2.0-alpha`.
