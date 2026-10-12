---
audience: user
title: Updating VisualBeef
summary: How new versions arrive, how they are checked before they are installed, how to turn the check off, the preview channel, and a manual download.
order: 10
---

# Updating VisualBeef

VisualBeef looks for new versions on its public release page,
<https://github.com/AproposRobin/VBeef/releases>, and installs one only when you say so.

## How an update arrives

1. A few seconds after VisualBeef starts (and once a day while it stays open) it downloads a small file,
   `release.json`, from the newest release. Nothing else is sent: no account, no identifier, only the VisualBeef
   version as the user agent.
2. When that release is newer than yours, a line appears under the toolbar:
   **VisualBeef 0.2.0-alpha is available.** with **Update**, **Release notes** and **Later**.
   **Later** hides the line for this session only: the next start shows it again. **Release notes** opens the release page.
3. **Update** downloads the package for your system into VisualBeef's own folder (see
   [Where the files go](#where-the-files-go)). The line shows the progress; **Cancel** stops it.
4. When the download is checked (below), the line says **VisualBeef 0.2.0-alpha is downloaded and verified** with
   **Restart to finish**.
5. **Restart to finish** closes VisualBeef, installs the new version and starts it again.
   Unsaved work is never lost: with unsaved files the button refuses with **Save your work first**, and while a compile
   or a debugging session runs it asks you to wait for it.

The next start shows **VisualBeef was updated to 0.2.0-alpha.** in the notifications.

**Help > Check for Updates...** checks at once and tells you the result (up to date, a new version, or why it could not
check).

## Where to trigger an update

While a newer version is known, the update can be started or finished from more than the line under the toolbar:

* **Editor Preferences > Updates** (Edit menu): **VisualBeef 0.2.0-alpha is available.** with **Update now** and
  **Release notes**. When the package is downloaded and verified the same place shows **Restart to finish**. When
  VisualBeef is up to date it shows only the status of the last check.
* **Help > Update to 0.2.0-alpha...** starts the download when the version is available. Once it is downloading or
  downloaded it opens Editor Preferences > Updates, where the progress and **Restart to finish** are. With no version
  known the entry reads **Check for Updates...**.
* **Status bar** (bottom right): after **Later** hid the line, **Update available** (or **Update ready to finish**,
  **Downloading update**) stays there. A click opens Editor Preferences > Updates.

The checks, the verification and the restart rules are the same wherever you start the update.

## What is checked before anything is installed

* `release.json` is **signed** by the VisualBeef release key. VisualBeef carries the public half of that key and refuses
  a `release.json` whose signature does not match, so a changed or forged file is never used.
* Each release has a **sequence number** that only grows. VisualBeef never installs a release whose number is not above
  the one it is running (no downgrade, and an old signed release cannot be offered again).
* The downloaded package must have exactly the **size and SHA-256** written in the signed `release.json`; otherwise it is
  deleted and the line says why ("The update was refused: ...").
* On Windows the unpacked folder must hold the editor and its `VERSION.txt` must name the signed version.
* After the restart, the new version has to start and draw its window within a minute. If it does not, the previous
  version is put back and started, and you see **Update failed: ...** with the reason.

A build that has no release key (for example one you compiled yourself) never installs updates and says
**Updates are not set up in this build.** A copy started from a folder without `VERSION.txt` is a development build:
it does not check by itself and does not install.

## Turning the check off

**Edit > Editor Preferences > Updates**:

| Setting | What it does |
|---|---|
| **Check at Start** | On (default): check a few seconds after start and once a day. Off: only when you use **Check Now** or **Help > Check for Updates...** |
| **Channel** | **Stable** (default): published releases. **Preview**: also pre-releases, which can be less finished. |
| **Status** | The result of the last check. |
| **Check Now**, **Open Release Page** | Check at once; open the release page in your browser. |

The settings are kept in `settings.json` under `"updates"`: `"check": true | false` and `"channel": "stable" | "preview"`.

Without a network connection (offline or on an isolated network) the automatic check stays silent: it writes one line to
the Output Log and nothing else. VisualBeef uses the system's `curl` for the download (part of Windows 10 and later, and
of every common Linux desktop).

## The preview channel

Preview releases are marked as pre-releases on the release page. With **Channel: Preview** VisualBeef offers the newest
release of either kind; with **Stable** it never offers a pre-release. Switching back to Stable does not undo a preview
version you installed: the next stable release with a higher number is offered when it is published.

## Where the files go

Downloads and the previous version are kept in the per-user folder, never in your projects:

| What | Where |
|---|---|
| The downloaded package, while it waits for **Restart to finish** | `%LOCALAPPDATA%\VisualBeef\update\staging\<version>\` |
| The previous version (what an update replaced) | `%LOCALAPPDATA%\VisualBeef\update\previous\` |
| The update log | `%LOCALAPPDATA%\VisualBeef\update\update.log` |

On Linux the folder is `~/.local/share/VisualBeef/update/`. `VB_HOME` moves all of it.

## Windows and Linux

* **Windows (zip)**: the update replaces the files of the folder you unzipped (the editor, `vbhost.dll`, `assets`,
  the licence files, `docs` when your copy has them). Your settings and projects are elsewhere and are not touched.
  A folder you cannot write to (for example under Program Files) is not updated: unzip the new version by hand.
* **Linux (AppImage)**: the new AppImage replaces the file you started, under the same name, and is started. The
  previous file is kept in the `previous` folder.
* **Linux (tarball)**: VisualBeef tells you about new versions; download and unpack the new tarball yourself.
* **A copy another program bundles**: when VisualBeef ships inside another program's folder, that program
  updates it, so the bundled copy does not check or install by itself.

## Going back

The previous version is in `update\previous\`. To go back by hand, close VisualBeef and copy the contents of that folder
over your VisualBeef folder (Linux AppImage: copy the file back over the AppImage). Older versions stay on the release
page.

## Manual download

Every release on <https://github.com/AproposRobin/VBeef/releases> carries the packages, a `.sha256` file for each, and
`release.json`. To check a download yourself before you unzip it:

Windows (PowerShell):

```powershell
(Get-FileHash .\VisualBeef-<version>-win64.zip -Algorithm SHA256).Hash.ToLower()
Get-Content .\VisualBeef-<version>-win64.zip.sha256
```

Linux:

```sh
sha256sum -c VisualBeef-<version>-alpha-x86_64.AppImage.sha256
```

The two hashes must be equal. The same value is in `release.json` (`assets` > `sha256`), which is signed.
