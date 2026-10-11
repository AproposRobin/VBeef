---
audience: developer
title: SignPath application draft
summary: Draft answers for the SignPath Foundation application (owner only).
order: 21
---

# SignPath Foundation application: draft answers

For the form at <https://signpath.org/apply>. Fill in the placeholders; every other answer is backed by a file in
the public repository (`https://github.com/AproposRobin/VBeef`). This page is for the owner and is not part of the packages.

| Question | Answer |
|---|---|
| Project name | VisualBeef |
| One-line description | A node-graph editor for the Beef programming language: every graph is plain Beef source code, so the source stays the only truth and builds with the normal Beef toolchain. |
| Project home page | `https://github.com/AproposRobin/VBeef` |
| Source repository | `https://github.com/AproposRobin/VBeef` (GitHub) |
| Download page | `https://github.com/AproposRobin/VBeef/releases` |
| Licence | Apache License 2.0 (`LICENSE`); bundled third-party components are MIT, zlib, ISC, Apache-2.0 with LLVM Exceptions and permissive mingw-w64 licences, listed in `THIRD_PARTY.md` with their texts in `THIRD_PARTY/`. No dual licensing. |
| Is any part proprietary or closed source? | No. |
| Code signing policy URL | `https://github.com/AproposRobin/VBeef/blob/main/docs/Code-Signing.md` (also linked from the README, section "Code signing") |
| Privacy policy | Section "Privacy" of the code signing policy: VisualBeef collects and sends no data and makes no network connections. |
| What will be signed | `VisualBeefEditor.exe` (the editor) and `vbhost.dll` (its native window and rendering host, built from the repository's own source), as Authenticode signatures, inside the Windows release packages. Product name `VisualBeef`, one product version per release. |
| What will not be signed | The test program (not shipped), the zip files, Linux packages, any third-party binary. |
| Build system | GitHub workflow, `.github/workflows/windows.yml`, GitHub-hosted `windows-latest` runner, triggered by a `v*` tag. All third-party steps are pinned to commit hashes; Beef, llvm-mingw and SDL2 are downloaded from their upstream release pages and checked against sha256 values in `scripts/ci-windows.ps1`. The native DLL is built from source in the workflow, the editor with BeefBuild, and the test suites run before packaging. Documented in `docs/CI.md`. |
| Origin verification | The signing request is made by SignPath's official GitHub submit-signing-request step from the workflow run of the tag; SignPath's GitHub connector checks repository, commit and workflow. |
| Release process | Tag, workflow build and tests, manual approval of the signing request in SignPath by an approver, signed packages attached to the GitHub Release with SHA-256 files. |
| Is the project already released? | Yes: `https://github.com/AproposRobin/VBeef/releases/tag/v0.1.7` (alpha channel; first public release). |
| Is it actively maintained? | Yes: daily development since 2026-10-09, changelog in `docs/CHANGELOG.md`, roadmap in `docs/Roadmap.md`, automated tests on every change. |
| Functionality description on the download page | See README section "What VisualBeef does", repeated in the release notes. |
| Team roles | Authors: `<names>`. Reviewers: `<names>`. Approvers: `<names>`. (`docs/Code-Signing.md`) |
| Multi-factor authentication | Required for all team members on GitHub and SignPath. |
| Maintainer / contact | `<name>`, `<public contact e-mail>` |
| Attribution | The home page and the Releases page carry: "Free code signing provided by SignPath.io, certificate by SignPath Foundation". |
| Does the software install anything, change system settings or phone home? | No installer; the package is a folder that is deleted to remove it; no registry or system changes; no network connections; no telemetry. |
| Anything that could be seen as a hacking tool or PUP? | No. It edits source files the user opens, compiles them with the user's Beef toolchain and offers a debugger for the user's own programs. |

## Notes for the owner

* Apply only after the public repository has its first release (condition "already released").
* Have the artifact configuration ready: a zip with `VisualBeefEditor.exe` and `vbhost.dll` at the root, both
  `pe-file` entries with the metadata restriction product name `VisualBeef` and the release's product version.
  `vbhost.dll` needs its version resource first ([SignPath-Readiness.md](SignPath-Readiness.md), item 10).
* The five repository variables and secrets are listed in [CI.md](CI.md#variables-and-secrets).
