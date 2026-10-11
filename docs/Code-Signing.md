---
audience: developer
title: Code signing policy
summary: The code signing policy for the Windows packages and how to verify a download.
order: 19
---

# Code signing policy

This page is the code signing policy of VisualBeef. It is linked from the README of the public repository
(`https://github.com/AproposRobin/VBeef`) and from the Releases page, where the Windows packages are downloaded.

> **Status: not signed yet.** The project has applied for free code signing from the SignPath Foundation.
> Until the application is approved and the first signed release is published, the Windows packages are
> **not** signed, and the attribution below does not apply. Windows SmartScreen may warn about them; compare
> the SHA-256 value on the Releases page with the file you downloaded (see below).

## What is signed

| File | Signed | Notes |
|---|---|---|
| `VisualBeefEditor.exe` | yes | the editor |
| `vbhost.dll` | yes | the native window / rendering host, built from this repository's source |
| `VisualBeefTests.exe` | not shipped, not signed | the test program is a build output only |
| the `.zip` packages | no (the files inside are) | published with a `.sha256` file |
| Linux packages | no | Authenticode is a Windows mechanism |

Only binaries built from this repository's own source are signed. Libraries from other projects that are
linked in (Dear ImGui, SDL2, the C++ runtime, ...) are compiled into those two files; no third-party binary
is signed on its own, and none is shipped unsigned beside them except system libraries that Windows provides.
The licences of those components are in `THIRD_PARTY.md` and `THIRD_PARTY/`.

## How a signed release is made

1. A maintainer tags a commit of the default branch `v<major>.<minor>.<patch>` in the public repository.
2. The GitHub workflow `.github/workflows/windows.yml` runs on that tag. It downloads pinned tools
   (sha256 checked), builds `vbhost.dll` and `VisualBeefEditor.exe` from the tagged commit on a GitHub-hosted
   runner, runs the test suites, and packages the result. More in [CI.md](CI.md).
3. The workflow submits the two binaries to SignPath. SignPath verifies the origin of the request (the
   repository, the commit and the workflow run on GitHub) against the signing policy, and the request needs
   the manual approval of an approver named below.
4. The workflow rebuilds the packages with the signed binaries (it refuses an invalid signature) and
   attaches them, with their SHA-256 files, to the GitHub Release of the tag.

Nothing is signed from a developer machine. The signing certificate is held by SignPath; the project never
has the private key.

## Roles

| Role | What it may do | Who |
|---|---|---|
| Authors | change source code without a second review | `<fill in: GitHub accounts>` (owner: AproposRobin) |
| Reviewers | review every change from non-committers (pull requests) | `<fill in>` |
| Approvers | approve each signing request in SignPath | `<fill in>` |

All members use multi-factor authentication for GitHub and SignPath.

## Metadata of signed files

SignPath is configured to refuse a file whose version information differs from this:

| File | Product name | Product version |
|---|---|---|
| `VisualBeefEditor.exe` | `VisualBeef` | the version of the release, for example `0.1.7` (the same for every file of that release) |
| `vbhost.dll` | `VisualBeef` | the same |

`scripts/package.ps1` checks the exe's product name, product version, company and copyright before packaging.

## Privacy

VisualBeef does not collect or send any data. It makes no network connections of its own, has no telemetry
and no update check. It reads and writes only the files you open and, in your user profile, its own settings,
logs, crash reports and recovery files (`%LOCALAPPDATA%\VisualBeef`, or the folder in `VB_HOME`). Compiling and
debugging start the Beef toolchain installed on your machine (`BeefBuild`, the debugger engine); their own
behaviour is described by the Beef project. The editor never changes system settings, and the package is
a plain folder: delete it to remove it (the settings folder above can be deleted too). Third-party
components bundled in the binaries (Dear ImGui, SDL2) do not transmit data either.

## Verify a download

1. Compare the SHA-256 of the zip with the `.sha256` file next to it on the Releases page:

   ```powershell
   (Get-FileHash .\VisualBeef-<version>-win64.zip -Algorithm SHA256).Hash
   ```

2. After unzipping, check the signatures (signed releases only):

   ```powershell
   Get-AuthenticodeSignature .\VisualBeefEditor.exe, .\vbhost.dll |
       Format-List Path, Status, @{n='Signer';e={$_.SignerCertificate.Subject}}, @{n='Issuer';e={$_.SignerCertificate.Issuer}}
   ```

   `Status` must be `Valid` for both files. Equivalent: right-click the file, Properties, Digital Signatures.
3. The version information of the file (the Version information in the file's Properties, or `(Get-Item .\VisualBeefEditor.exe).VersionInfo`)
   shows product name `VisualBeef` and the version of the release; `VisualBeefEditor.exe --version` prints the
   version and channel.

## Attribution

*Once approved, this paragraph is shown unchanged on the repository home page and on the Releases page:*

> Free code signing provided by [SignPath.io](https://signpath.io), certificate by
> [SignPath Foundation](https://signpath.org).

## Reporting a problem

If you believe a signed VisualBeef file is malicious or was signed by mistake, open an issue in the public
repository or write to the owner listed there; the maintainers will help SignPath with any investigation.
