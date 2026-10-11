---
audience: user
title: Files and safety
summary: What VisualBeef writes and when, how saves are protected, and how conflicts and deletes are handled.
order: 9
---

# Files and safety

What VisualBeef writes, when, and how it protects your sources. The `.bf` text is the single
source of truth; everything else is a cache or a convenience.

## What is written when

| Step | Writes |
|---|---|
| Open a project, a file, a graph; auto-layout; scrolling, selecting, compiling | **Nothing.** No `.vblayout`, no backup. |
| Move or resize nodes / comment boxes / reroute knots, create orphan nodes | `File.bf.vblayout` (quietly, about every 2 s after the drag ends), only for that file, only if the content changed. |
| Save (Ctrl+S) / Save All (Ctrl+Shift+S) / Compile (F7, saves first) | `File.bf` atomically, plus `File.bf.bak`, plus the sidecar if the layout was touched or the save carries an edit. Files that are not modified are not rewritten. |
| New class / struct / enum / interface / file / folder / project | The new file or folder only (never overwrites). |
| Rename a type | The one file, rewritten with just the rename (see below). |
| Rename a file or folder | A move; the `.vblayout` follows the file. |
| Delete | Recycle Bin only (the freedesktop.org Trash on Linux). |
| Settings, dock layout | `%LOCALAPPDATA%\VisualBeef\settings.json` and `layout.ini` (or under `%VB_HOME%`), never the working directory or the project (also in read-only mode). The old `VisualBeef_settings.txt` / `VisualBeef_layout.ini` in the working directory are read once to migrate and no longer written. |
| Every Output Log line | `%LOCALAPPDATA%\VisualBeef\logs\visualbeef-<date>.log` (the session log). |
| Unsaved document text, every 30 s while it changes | `%LOCALAPPDATA%\VisualBeef\recovery\<pid>-<start>\<hash>.vbrec` (the recovery journal; never next to your sources). Deleted on save, revert and clean exit. |
| A crash | `logs\visualbeef-crash-<date>-<time>.log` and `.dmp`, plus a last journal write of every unsaved document. |

## Recovery journal and crash recovery

The `.bf` file is only ever written by a save. Unsaved edits are protected separately, outside
the project:

* **Journal.** Every **Recovery Journal** seconds (Preferences > Saving, 30 by default, 0 = off)
  the text of each modified document is copied to `%LOCALAPPDATA%\VisualBeef\recovery\<pid>-<start time>\`
  (atomically, and only when it changed since the last copy). An entry is a small header
  (`#vbrecovery`, the source path) and the full text. Saving the document, undoing back to
  the saved text, closing it or reloading it deletes its entry; a clean exit deletes the
  session folder.
* **On a crash** the crash handler writes the current text of every journaled document once
  more (raw writes, no allocation), so edits made since the last journal tick are not lost
  when the slot existed (a document gets its slot on the first frame it is modified).
* **Liveness.** Each session holds `session.lock` in its folder open without sharing and with
  delete-on-close, so a folder whose lock is gone (or deletable) belongs to a dead session;
  two editors running at once never treat each other's journal as a crash.
* **Next start.** Entries of dead sessions are offered in **Recover unsaved changes?**
  (newest entry per file). **Recover** opens each file and applies the recovered text as an
  unsaved, undoable change; nothing is written until you save. **Discard** deletes them,
  **Decide Later** keeps them. A file that no longer exists is reported and its journal kept.
* **Autosave** (Preferences > Saving > Autosave Interval, off by default) is different: it
  saves modified files into the project every N minutes, with the usual atomic save, backup
  and conflict check.

## Viewer (read-only) mode

* `VisualBeefEditor.exe --view <folder|file>` opens read-only. In the app: **File > Open Project
  (Read-only)...**, or toggle **File > Read-only (viewer) mode**.
* Every write is refused with a status message: saves, sidecars, creating, renaming, deleting.
  The status bar shows `[LOCKED read-only]`.
* The default is editable, but still write-on-change only.

## Atomic saves and backups

1. The text is written to `File.bf.tmp` and flushed to disk (`FlushFileBuffers`).
2. `ReplaceFileW` swaps it in and keeps the previous content as `File.bf.bak` (falls back to a
   copy plus `MoveFileEx` with `REPLACE_EXISTING | WRITE_THROUGH`). Without a backup it is a
   single `MoveFileEx`.
3. If anything fails, the original is untouched, `.tmp` is removed and an error dialog explains.

One backup is kept (the content before the last save). Turn it off with **File > Keep .bak
backup when saving**; add `*.bak`, `*.tmp` and `*.vblayout` to `.gitignore` as you prefer.

## Conflicts: the file changed on disk

The document remembers a fingerprint (length + hash) of the file as loaded or last saved. Before
every save (single, Save All, Compile) the file is compared. If it differs (a touch with
identical content does not count), nothing is written and a modal offers:

* **Overwrite**: write your version (the disk version ends up in `.bak`).
* **Reload**: discard your edits and take the disk version.
* **Cancel**.

Save All and Compile report the conflict and stop; quitting with "Save All" stays open if a save
was refused. Unmodified documents reload automatically when the file changes; modified ones show
the existing "changed on disk" banner.

## A graph with errors is not saved

When a graph has errors (GraphValidator or the code generator refused it), its edits are not in the
text: the file still has the code from the last good commit. Saving then would store that text as if
the edits were saved, so **Save, Save All and Compile refuse** (`SaveOutcome.GraphErrors`, the reason
in the status bar and the Output Log) until the errors are fixed (or undone). See
[Calls-and-Receivers.md](Calls-and-Receivers.md#graphvalidator).

## Unparsed members are kept

A file is never written back with less than it had. The `.bf` text is the document: every save
writes the current text (`Unit.Text`) with only the edits spliced in, so a member the parser
could not read is written exactly as it was read, whatever else is edited.

* **What the parser cannot read** becomes a Broken member with its exact text (brackets that do
  not close, a declaration that starts inside a member, and since 2026-10-11 any declaration
  that looks like a function or member variable but did not parse: a keyword as its type, a
  member variable typed `var` / `let`, a member with no name). It is listed in the **Outline**
  in red (`!  Name (unreadable)`, or `unparsed member at line N` when no name can be recovered)
  with the parser's message as tooltip, opens as a read-only red node holding its text, and is
  listed in **Problems** (no compile needed) with its file and line. Fix it in **Beef Source >
  File** (Apply Text To Graph) or in another editor. Declarations the editor keeps as text on
  purpose (`using`, `typealias`, `delegate` / `function` types, enum `case`s, operators,
  `Event<...> m ~ _.Dispose();` members) are not reported.
* **A declaration error the compiler would report** on a function that did parse is shown on
  the function: `var F()` outside a `[Comptime]` function and `let F()` (Beef only infers a return
  type for comptime functions). The function keeps its graph; its Outline row is red, its entry
  node carries the error and Problems lists it. Nothing is refused: fixing **Properties >
  Outputs > Return Type** clears it. The Return Type picker offers `void` and never `var` / `let`;
  parameter, member variable, Construct and Cast types never offer them either (local variables
  and For Each elements do), and the Add Function / Add Variable dialogs refuse them.
* **Compile messages** in a line no graph shows still appear in Problems; a click opens the file
  in Beef Source > File at that line (or the unreadable member's red node).

Why: on 2026-10-10 a user's `public static var Main()` (picked from the Return Type list, which
offered `var`) made the parser drop to a hidden text member: `Main` vanished from the Outline,
its compile error opened nothing, and the user could only see it in the file. The file itself
was not cut by a save (saves splice text; the missing `Run()` is exactly the span
`DeleteMember` removes: Outline > Delete Function or a hand edit), but a member that cannot be seen cannot be fixed or trusted.

Test: `VisualBeefTests safety` group 18 and `VisualBeefTests savecheck <folders>` (every file:
load + save without an edit is byte for byte, a graph edit and an added member variable keep
every other member), `parser` (the recovery cases), and `VB_SELFTEST=unreadable` in the editor.

## Rename / delete of a type does not save other edits

Renaming or deleting a type rewrites its file. If the file has other unsaved edits you get an
error asking you to save or reload first, instead of those edits being written silently.
Otherwise only the rename/delete is written; if the disk changed meanwhile the change is rolled
back and nothing is written.

## Delete: Recycle Bin or nothing

Deletes go through `SHFileOperation` with Undo. There is no permanent-delete fallback: if the
move fails (or you decline Windows' "permanently delete?" prompt for something too big for the
bin) the item stays and an error dialog says so. A deleted file's `.vblayout` goes along.

On Linux the same rule uses the freedesktop.org Trash (`FreedesktopTrash.bf`): the item is renamed
into `$XDG_DATA_HOME/Trash/files` (else `~/.local/share/Trash/files`) with an
`info/<name>.trashinfo` holding its original path and the deletion date, so the desktop's file
manager lists it and can restore it. An item on another file system goes to that file system's
`.Trash/<uid>` (when an administrator made a sticky `.Trash`) or `.Trash-<uid>`. If no trash can be
made or the rename fails, nothing is deleted and the error says so.

## Creating assets

* The create dialog opens from the docked browser and from the Ctrl+Space drawer (the drawer no
  longer closes under the dialog).
* Files and types go to the `src` folder of the nearest enclosing `BeefProj.toml` project. A
  folder that is the project root or a non-source subfolder redirects to `<project>/src` (the
  dialog says so). A folder in no project asks: create a project here, create anyway, or cancel.
* Names must be unique **per namespace** (the same name in another namespace is fine), with a
  message naming the clashing file.
* Failures (existing file, write error, read-only) appear in a modal and the status bar.

## Dirty state and undo

* Dirty = the current text differs from the last saved or loaded text. Undoing back to the saved
  text clears the `*`.
* One undo step per node drag, comment move/resize and knot drag (a drag is one step). Layout-only
  changes never mark the source dirty; they are saved through the sidecar.
* Menu Paste lands at the centre of the visible canvas; Ctrl+V at the mouse.

## `.vblayout` sidecar

* First line `#vblayout<TAB>2` (format 2 = content-keyed entries `methodKey|path#hash`; read into `LayoutFileVersion`). Headerless files and the legacy `#version<TAB>2` line are accepted; a newer version is read but the
  file is never overwritten.
* Unknown extra columns on a line are ignored (room for a future `key`/`hash` field).
* On write, entries of nodes that no longer exist in a built method are dropped; entries of
  methods that no longer exist are dropped when a save carries an edit (not on the quiet
  autosave, in case the file temporarily fails to parse).
* An unchanged sidecar is never rewritten, and none is created for a file with nothing to store.
