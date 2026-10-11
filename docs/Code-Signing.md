---
audience: developer
title: Release integrity
summary: Releases are unsigned; how the public workflow, build attestations and checksums let you verify a download.
order: 19
---

# Release integrity

VisualBeef releases are **not code-signed**. The project has no code-signing certificate, so Windows SmartScreen shows
"unknown publisher" the first time a new version runs. Trust comes from three things anyone can check:

1. **The public workflow.** Every release is built by `.github/workflows/windows.yml` on GitHub-hosted runners from a tagged
   commit of the public repository (`https://github.com/AproposRobin/VBeef`). Nothing that ships comes from a developer machine.
2. **Build attestations.** The workflow attaches a GitHub build attestation to each package and its `.sha256` file, tying the
   file to the workflow run and commit that produced it.
3. **Checksums.** The `.sha256` file beside each download holds the expected SHA-256 of the zip.

How to verify a download, step by step, is in the README section
[About the download warning](../README.md#about-the-download-warning); the commands are repeated below.

Releases are unsigned on purpose. A code-signing certificate costs money every year and a free one has to be applied for,
and the project has neither. It does not apply for a certificate and does not plan to; the workflow has no signing steps.
What this page and the README promise is exactly what the workflow does: build in public, attest, publish checksums.
See [CI.md](CI.md).

## What a release contains

| File | Notes |
|---|---|
| `VisualBeefEditor.exe` | the editor |
| `vbhost.dll` | the native window / rendering host, built from this repository's source |
| the `.zip` packages | published with a `.sha256` file |
| Linux packages | tarball and AppImage, also built by a public workflow |

Libraries from other projects (Dear ImGui, SDL2, the C++ runtime) are compiled into those files. Their licences are in
`THIRD_PARTY.md` and `THIRD_PARTY/`. `scripts/package.ps1` checks the exe's product name (`VisualBeef`), product version,
company and copyright before packaging.

## How a release is made

1. A maintainer tags a commit of the default branch `v<major>.<minor>.<patch>`.
2. The workflow downloads pinned tools (sha256 checked), builds `vbhost.dll` and `VisualBeefEditor.exe` from the tagged
   commit, runs the test suites, and packages the result.
3. It writes the `.sha256` files, creates the build attestations and attaches everything to the GitHub Release of the tag.

## Team

VisualBeef is maintained by one person, AproposRobin, who reviews every contribution from other people. Contributions come
in as pull requests ([CONTRIBUTING.md](../CONTRIBUTING.md)).

## Privacy

VisualBeef does not collect or send any data. It makes no network connections of its own, has no telemetry and no update
check. It reads and writes only the files you open and, in your user profile, its own settings, logs, crash reports and
recovery files (`%LOCALAPPDATA%\VisualBeef`, or the folder in `VB_HOME`). Compiling and debugging start the Beef toolchain
installed on your machine (`BeefBuild`, the debugger engine); their own behaviour is described by the Beef project. The
editor never changes system settings, and the package is a plain folder: delete it to remove it (the settings folder above
can be deleted too). Third-party components bundled in the binaries (Dear ImGui, SDL2) do not transmit data either.

## Verify a download

1. Attestation (needs the [GitHub CLI](https://cli.github.com/)):

   ```powershell
   gh attestation verify VisualBeef-<version>-win64.zip --owner AproposRobin
   ```

2. Compare the SHA-256 of the zip with the `.sha256` file next to it on the Releases page:

   ```powershell
   (Get-FileHash .\VisualBeef-<version>-win64.zip -Algorithm SHA256).Hash
   ```

3. The version information of the exe (Properties, or `(Get-Item .\VisualBeefEditor.exe).VersionInfo`) shows product name
   `VisualBeef` and the version of the release; `VisualBeefEditor.exe --version` prints the version and channel.

If a check fails, delete the file and do not run it.

## Reporting a problem

If you believe a release file is malicious or does not come from this project's workflow, report it as described in
[SECURITY.md](../SECURITY.md).
