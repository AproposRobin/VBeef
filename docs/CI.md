---
audience: developer
title: Continuous integration
summary: The GitHub workflows that build, test and package VisualBeef.
order: 15
---

# Continuous integration

Two GitHub workflows build, test and package VisualBeef. Both run on GitHub-hosted runners from a clean
checkout; nothing that ships comes from a developer machine. Releases are not code-signed: trust comes from the public workflow, build attestations and
checksums ([Code-Signing.md](Code-Signing.md)).

| Workflow | Runner | What it produces |
|---|---|---|
| `.github/workflows/windows.yml` | `windows-latest` | `VisualBeef-<version>-win64.zip` (full), `VisualBeef-<version>-<channel>-win64.zip` (minimal), their `.sha256`; attestations on tags; a GitHub Release on a `v*` tag |
| `.github/workflows/linux.yml` | `ubuntu-24.04` | tarball and AppImage, see [Linux.md](Linux.md#continuous-integration) |

Every third-party step (`uses:`) is pinned to a commit sha (the version is in the comment beside it), and downloaded tools are
checked against sha256 values kept in the repository. The build job has read-only permissions; only the
`release` job (tags only) can write, and only to contents.

## The Windows workflow, step by step

The steps are implemented in `scripts/ci-windows.ps1`, so the workflow and the local proof
(`scripts/ci-github-local.ps1`) run the same code.

1. **Checkout** with full history (the exe's file version is `major.minor.patch.<commit count>`).
2. **Cache tool downloads** (`C:\vb\tools\dl`). The cache is only a speed-up: every file is checked against its
   sha256 before use.
3. **fetch**: downloads and unpacks, with the sha256 checked first:

   | Tool | Version | sha256 |
   |---|---|---|
   | Beef (BeefSetup, a nightly build; unpacked with 7-Zip, the installer is not run) | 0.43.6, build 2026-09-14, commit `19ee8d2e` (`BeefSetup_0_43_6__09_14_2026.exe` from `nightly.beeflang.org`) | `65ee0f1cda0a89637d69eb660a4459efd6e3281d417d1dc41a12edad4bb21880` |
   | llvm-mingw | 20261006, `llvm-mingw-20261006-ucrt-x86_64.zip` | `317492c456aa27ee607a5919f1d2d38dcdc1112516a24d0bf4b00d078f52d17a` |
   | SDL2 mingw development files | 2.32.10, `SDL2-devel-2.32.10-mingw.zip` | `f15cff5fca62ec9381a016ef1d42a95c638cd72d2f226ba5781c76fe43dbd1ac` |

   Beef 0.43.6 has no release on GitHub (the last release there is 0.43.5); the nightly archive keeps each day's
   build under a dated name, which does not change. Beef is unpacked into `C:\Program Files\BeefLang`, because the
   test suites look for it there; `bin\BeefConfig.toml` (written by Beef's installer) is created by the script.
4. **host**: rebuilds `Native\bin\win64\vbhost.dll` and `vbhost.lib` from source with `Native\build_windows.ps1`
   (clang, lld, libc++ from llvm-mingw; SDL2 and the C++ runtime linked statically). It then compares the export
   list of the DLL committed in the repository with the rebuilt one and **fails when they differ**, so a source
   change that was not followed by a rebuilt DLL is caught. The package always contains the DLL built in CI; the
   committed one is never what ships.
5. **build**: `BeefBuild` for `VisualBeefTests` (Debug, the configuration `docs/Testing.md` uses), and
   `VisualBeefCore` and `VisualBeefTests` in Release. The editor itself is built by the package step.
6. **test**: every suite that needs no outside source corpus, one at a time: `edits flow calls lifetime textforms
   classes safety parser catalog diagnostics hotkeys update ump vocabulary stress compile debug`, then `edits classes
   parser safety stress update` again on the Release build (a bug that only shows in Release, such as a delete of a
   scope-allocated object, is caught there). The table is written to the job summary. The corpus suites
   (`roundtrip`, `orphans`, `loadall`, `savecheck`, `debugmap`, `inits`) read other projects' sources and are run by
   hand before a release (`docs/Testing.md`).
7. **package**: `scripts\package.ps1` (full package) and `scripts\package.ps1 -Minimal`; both check the exe's
   version information, icon and `--version` output, refuse build leftovers, and write the zip and its `.sha256`.
8. **Upload packages** as the artifact `visualbeef-win64`.
9. **release** job (tags only): downloads that artifact, creates a build attestation for every zip and `.sha256` file
   (the GitHub build-provenance attestation step) and attaches them to **one draft pre-release** of the tag with
   `gh release` (the Linux workflow's own release job adds the tarball, the AppImage and their `.sha256` files to the same
   draft). The release stays a draft until the owner signs `release.json` and publishes it with `scripts/release.mjs`
   ([Releasing.md](Releasing.md)); the signing key is never in CI.

Pull requests run steps 1 to 8 without any secret.

## Build attestation and how to verify

Releases are not code-signed ([Code-Signing.md](Code-Signing.md)). The `release` job has `id-token: write` and
`attestations: write` and nothing else is needed: no secrets and no repository variables. The attestation is a GitHub
provenance statement that ties each zip and `.sha256` file to the repository, the workflow run and the commit that built
it. To verify a download (GitHub CLI) and compare its hash:

```powershell
gh attestation verify VisualBeef-<version>-win64.zip --owner AproposRobin
(Get-FileHash .\VisualBeef-<version>-win64.zip -Algorithm SHA256).Hash
```

The hash must equal the content of the `.sha256` file beside the download.

## Moving a tool forward

Change the version, URL and sha256 together in `scripts/ci-windows.ps1` (the `$Pins` table), and for llvm-mingw
or SDL2 also in the header of `Native/build_windows.ps1` and in `THIRD_PARTY.md`; rename the cache key in
`windows.yml`. For a third-party step, look up the commit of the tag (`git ls-remote --tags <step repo>`) and replace
the sha and the comment. Run `actionlint` on the workflows.

## Proving it locally

`scripts\ci-github-local.ps1 -Scratch <empty folder> [-Compare]` clones the repository (`git clone --depth 1`,
committed files only), downloads and unpacks all three tools afresh into the scratch folder with the hashes
checked, and runs `ci-windows.ps1` with the same steps. With `-Compare` it also builds a normal
`scripts\package.ps1` zip from your working copy and compares the entry lists. Nothing is installed and the
registry is not touched. One difference from the workflow: the suites find Beef at `C:\Program Files\BeefLang`,
so on a machine with Beef installed there, the compile, debug and catalog suites use that copy instead of the
unpacked one.

`actionlint` (pinned release, checked by sha256) is the check for the workflow files:
`actionlint .github/workflows/windows.yml .github/workflows/linux.yml`.

## Release smoke (local gate)

`scripts\release-smoke.ps1` is a local gate, not a workflow: it drives the packaged editor's real windows, so it needs a desktop session and runs on the owner's machine before `release.mjs publish` ([Testing.md](Testing.md#release-smoke), [Releasing.md](Releasing.md)).

## Beef canary

`.github/workflows/beef-canary.yml` builds and tests VisualBeef on the newest Beef builds once a week (Mondays 06:17 UTC,
and on demand with **Run workflow** on the workflow runs page), so that a breaking change in Beef shows up before the pin is
moved. It is **not a required check** and no merge or release waits for it. A failure shows as a red run; nothing is
continued-on-error.

| Job | Beef | What it runs |
|---|---|---|
| `windows-nightly` (`windows-latest`) | the newest dated nightly listed at `nightly.beeflang.org` (the archive page gives each build's date and commit; the job takes the newest date) | `scripts\ci-windows.ps1 -Step fetch -AllowUnpinned`, then `host`, `build` (VisualBeefTests Debug, VisualBeefCore and VisualBeefTests Release), `test` (the short suites of step 6 above, plus the Release re-runs) |
| `linux-master` (`ubuntu-24.04`) | the `master` branch of `beefytech/Beef`, resolved at run time with `git ls-remote` | the build of `linux.yml` (LLVM 22.1, `bin/build.sh`, `Native/build_linux.sh clean`), then `scripts/linux-ci.sh` |

- **Unpinned mode.** `scripts\ci-windows.ps1 -AllowUnpinned` takes Beef from the nightly index instead of the pinned file.
  The file is unpacked the same way, and the job summary gets its file name, build date, SHA-256, the commit the archive
  index lists, and BeefBuild's FileVersion and ProductVersion. llvm-mingw and SDL2 stay pinned. `windows.yml` and
  `linux.yml` never pass the switch, so the pinned workflows keep refusing an unpinned Beef.
- **Job summary.** Each job records the Beef build it used, the suite table with a `Suites: N run, F failed` line, and a
  `Verdict` section: PASS, or FAIL with the first step that broke (and the first failing suite on Windows).
- **Logs.** A failed run uploads `windows-canary-logs` or `linux-canary-logs` (GitHub keeps artifacts 90 days by default).
- **Notifications.** GitHub's default applies: a failed scheduled run is listed on the workflow runs page and emails the user who
  last changed its `schedule` line (normally the repository owner). GitHub also turns scheduled workflows off in a public
  repository after 60 days without repository activity; the owner re-enables the workflow on the workflow runs page when that happens.
- **Badge.** The owner decides whether it goes into the README. With the public repository:

  ```markdown
  [![Beef canary](<badge image of beef-canary.yml>)](<link to beef-canary.yml>)
  ```

- **Checking the workflow file.** `actionlint .github/workflows/beef-canary.yml` (see "Proving it locally"). The canary
  itself runs only on GitHub.
