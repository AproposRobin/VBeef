---
audience: developer
title: SignPath Foundation readiness
summary: What is checked against the SignPath Foundation terms before signing.
order: 20
---

# SignPath Foundation readiness

Checked against the SignPath Foundation terms (<https://signpath.org/terms>) and the open source page
(<https://about.signpath.io/product/open-source>) on 2026-10-11. "The public repository" is the repository that
will be created from a clean export (`https://github.com/AproposRobin/VBeef`, see [Creating the public export](#creating-the-public-export));
the working repository stays private.

**Summary.** Everything that can be prepared inside the working repository is done. What is left needs the
owner (the public repository, the first release, names for the roles, the SignPath application) or the first
run on GitHub, plus one small build change: `vbhost.dll` carries no version information yet.

State values: **ready**, **owner** (needs the owner), **first run** (can only be shown by a run on GitHub),
**change** (a change in the repository is still needed).

| # | Condition | State | Evidence | What changes | Who |
|---|---|---|---|---|---|
| 1 | OSI-approved licence for all components, no commercial dual licensing | ready | `LICENSE` is Apache-2.0 (verbatim text), `NOTICE`; every bundled component is MIT, zlib, ISC, Apache-2.0 with LLVM Exceptions, public domain or a permissive mingw-w64 licence (`THIRD_PARTY.md` table, texts in `THIRD_PARTY/`) | nothing | - |
| 2 | No proprietary or non-open-source code, especially from maintainers or affiliates | ready | the audit in `THIRD_PARTY.md` lists every component with version and licence text; the tests that read other projects' sources (corpus suites) only read them from outside the repository | before exporting, confirm no file in the export was copied from a closed-source project | owner |
| 3 | The signing team develops, maintains and owns the repository, all sources and build scripts | ready | sole author `AproposRobin`; build scripts (`scripts/`, `Native/build_windows.ps1`, workflows) are in the repository | - | - |
| 4 | Actively maintained | ready | 169 commits between 2026-10-09 and 2026-10-11, `docs/CHANGELOG.md`, `docs/Roadmap.md`, a test suite run on every change | keep committing in the public repository after the export | owner |
| 5 | Already released in the form to be signed | owner | the packages are built by `windows.yml` as `VisualBeef-<version>-win64.zip` | create the public repository, push a `v0.1.7` tag, let the workflow publish the unsigned release; apply with that release | owner |
| 6 | Functionality documented on the download page | owner | README sections "What VisualBeef does" and "Code signing", `docs/Getting-Started.md`, `docs/Editor-UI.md` | paste the "What VisualBeef does" text (README) into the release notes of the Releases page and link `docs/Code-Signing.md` | owner |
| 7 | Code signing policy on the home page and download page | ready (text), owner (names) | `docs/Code-Signing.md`; README section "Code signing" links it | fill in the Authors, Reviewers and Approvers; link the policy from the release notes | owner |
| 8 | Fully automated, verifiable build from the public repository; origin verification | first run | `windows.yml`: pinned third-party steps, pinned and hash-checked tools, a build from the tagged commit on `windows-latest`, SignPath's official GitHub submit-signing-request step (pinned by commit) with the GitHub artifact id; `actionlint` clean; the same steps proven locally in a clean scratch folder from a fresh clone ([CI.md](CI.md#proving-it-locally)) | push to the public repository and watch the first run (differences between the runner and the local proof are listed in the next section); then create the SignPath project bound to that repository | owner |
| 9 | Attribution "Free code signing provided by SignPath.io, certificate by SignPath Foundation" | ready | text in `docs/Code-Signing.md`, marked "once approved" | show it unconditionally on the home and release pages after approval | owner |
| 10 | Metadata restrictions: product name = project name; one product version per release; on all signed binaries | change | `VisualBeefEditor.exe` carries `ProductName VisualBeef`, `ProductVersion 0.1.7` (checked by `package.ps1`) | `vbhost.dll` has **no** version resource: add a `VERSIONINFO` resource (product name `VisualBeef`, product version from `VisualBeefInfo.Version`) to `Native/build_windows.ps1` (llvm-windres is in the pinned llvm-mingw) and make `package.ps1` check it; alternatively sign only the exe | host build owner |
| 11 | Sign only own binaries; upstream binaries are not signed under the subscription | ready | only `VisualBeefEditor.exe` and `vbhost.dll` go to SignPath; the DLL is built from source in CI | - | - |
| 12 | End-user requirements: privacy, no hidden system changes, uninstall | ready | no network code, no telemetry, no registry writes (searched); portable folder, nothing installed; policy in `docs/Code-Signing.md` | - | - |
| 13 | Team security and roles; MFA for SignPath and the repository | owner | roles table in `docs/Code-Signing.md` | enable MFA on the GitHub and SignPath accounts; name the roles | owner |
| 14 | No malware, no hacking tools, no PUPs | ready | a source editor and debugger for the user's own programs | - | - |
| 15 | Each release gets a manual approval | owner | SignPath signing policy `release-signing` with approval required | configure in the SignPath console | owner |
| 16 | Possible later requirements (signed libraries, SBOM) | ready (basis) | `THIRD_PARTY.md` lists name, version, licence and source of every component | generate an SBOM from that list if SignPath asks | - |

Also open before the application:

* **The committed `vbhost.dll` is behind the source.** The CI check "committed DLL and rebuilt DLL export the
  same symbols" fails today: the source exports `vbh_raise_window` and `vbh_window_flags`, the committed DLL
  (1,692 exports) does not (the rebuilt one has 1,694). The package does not depend on the committed DLL (CI
  rebuilds it), but the commit must carry a rebuilt `Native/bin/win64/vbhost.dll` + `vbhost.lib`
  (`Native/build_windows.ps1`) so that the check passes on the public repository. Owner of `Native/`.
* **The suites find Beef at `C:\Program Files\BeefLang`** (hard-coded in `CompileTests.bf`, `DebugTests.bf`,
  `CatalogTests.bf`, `LibraryIndex.bf`, `DebugEngine.bf`). CI unpacks the pinned Beef there. Honouring
  `VB_BEEFBUILD` / `VB_BEEF_BIN` / `VB_BEEF_LIBS` on Windows as on Linux would let the local proof use the
  scratch copy; not needed for signing.
* **Beef 0.43.6 is a nightly build** (the archive keeps dated installers). If the nightly host ever removes the pinned
  file, move to the next dated build and re-run the suites. The cache of downloaded files in the workflow
  softens this.

## What can differ on the first GitHub run

* `windows-latest` (a Windows Server image) must allow unpacking into `C:\Program Files\BeefLang` (the runner
  user is an administrator) and has 7-Zip installed (the script finds `7z.exe` on `PATH` or in Program Files).
* Disk and time: Beef's install is about 0.8 GB unpacked, llvm-mingw 1.9 GB; the download cache keeps the
  archives. The workflow timeout is 90 minutes; the local run of the same steps takes a fraction of that.
* The Release link occasionally ran out of memory on a busy machine; `ci-windows.ps1` retries a build once.
* `package.ps1` and `Get-AuthenticodeSignature` run under Windows PowerShell 5.1 (`shell: powershell`).
* The SignPath steps have not run; they need the project, policy and artifact configuration of
  [CI.md](CI.md#variables-and-secrets) in the SignPath console.

## Creating the public export

The public repository is a separate repository with a clean history, created and pushed only by the owner; the
working repository stays private.

1. **Start from a tagged, verified commit** of the working repository: all suites pass (`docs/Testing.md`,
   including the corpus suites), the committed `vbhost.dll` matches the source (see above), the version in
   `VisualBeefCore/src/Document/CommandLine.bf` is the release version.
2. **Export the files, not the history**: `git archive <commit> | tar -x -C <empty folder>` (the folder is not a
   clone), then `git init` there and make the first commit with the owner's public identity, which is the GitHub
   `noreply` address `102644463+AproposRobin@users.noreply.github.com` (decided 2026-10-12; the working repository
   uses it for new commits from that date). Earlier history of the working repository carries a personal e-mail
   address in the author field and some internal notes; a fresh history avoids both. Later commits in the public
   repository are the real history.
3. **No private paths.** Search the export for the owner's user name and drive layouts and replace them with
   placeholders: `docs/Audit-2026-10-10.md` (a scratch path with a user name; or leave that page and
   `docs/Production-Audit-2026-10-10.md` out of the export), the `D:\VisualBeef`, `D:\UnrealUMP`, `D:\ClockWork`
   examples in `README.md`, `docs/Testing.md`, `docs/Getting-Started.md`, `docs/Catalog-and-Types.md`,
   `docs/Editor-UI.md`, `Native/build_windows.ps1` and the built-in test and test sources that take corpus paths.
   Re-run the vocabulary suite afterwards (it must stay at 0 hits).
4. **Licences complete**: `LICENSE`, `NOTICE`, `THIRD_PARTY.md`, `THIRD_PARTY/` (nine texts), the licence files
   inside `Native/third_party/`. `package.ps1` refuses to build without them.
5. **Both workflows present**: `.github/workflows/windows.yml` and `linux.yml` at the same paths. SignPath checks
   that a signing request comes from the workflow of the configured repository; the project in SignPath is
   created for the public repository's URL.
6. **Download page = the Releases page of the public repository.** Put the "What VisualBeef does" text and the link
   to `docs/Code-Signing.md` in the release notes template; the workflow's release step only attaches files.
7. **Secrets scan clean** (below) on the export: run it again on the new repository's single commit.
8. **Settings in the public repository**: workflows enabled; the five names from [CI.md](CI.md#variables-and-secrets)
   (leave `SIGNPATH_ENABLED` unset until approval); branch protection on the default branch; two-factor
   authentication on all accounts with write access; tags `v*` protected.
9. Push, let `windows.yml` run on the default branch, tag `v0.1.7`, check the Release, then apply
   ([SignPath-Application-Draft.md](SignPath-Application-Draft.md)).

## Secrets scan of the working repository

Scanned on 2026-10-11 over every ref (4 refs, 173 commits): the added lines of all patches, all file names ever
committed, and the three historic versions of each binary in `Native/bin`.

* Patterns: AWS, GitHub, Slack, Google and generic `sk-` keys; JWTs; private key blocks; `password` / `secret` /
  `token` / `api key` assignments with a long value; credentials in URLs.
* File names: no `.env`, key, certificate, keystore, database, log or archive files; the only binaries are
  `vbhost.dll`, `vbhost.lib`, `libvbhost.so` and the font.
* Binaries: no user-profile paths (the DLL carries the build path of the llvm-mingw CI machine, not a user's).
* **Result: no secret, token, key or password anywhere in the history.** The keyword hits are Dear ImGui's
  `ImGuiKey` names, the word "author" and a documentation example.
* Not secrets but worth knowing for the export: the author e-mail address in the commit metadata (item 2 above), one
  documentation page naming a local scratch folder with the user name, and the example drive paths (item 3).
