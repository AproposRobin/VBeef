---
audience: user
title: Debugging
summary: Set breakpoints on nodes, start a debug run, step through a graph and read the values on its pins.
order: 3
---

# Debugging

Run a program from VisualBeef, stop it on a node, look at the values on the pins, and step
through the Sheet node by node. Phase 1 debugs standalone Beef programs (a workspace whose
startup project is a console or Windows program, built in Debug). Attaching to a running game
for UMP mods is planned as phase 2.

![The debugger stopped on a node](images/debug-stopped.png)

## Quick start

1. Open a project folder that has a `BeefSpace.toml` (File > Open Project Folder...).
2. Open a Sheet and click the small circle on the top-left corner of a node (or select the node
   and press **F9**). A red dot means the node has a breakpoint.
3. Press **F5** (Debug > Start Debugging, or **Debug** on the toolbar). VisualBeef saves, compiles
   the workspace in **Debug** (whatever the configuration dropdown says) and runs the startup
   project.
4. The program stops before the node runs: the Sheet opens on it, the node gets a yellow outline
   and an arrow, and the values of its pins are written beside them.
5. Hover any pin of the Sheet to see its value. **F10** runs the node and stops at the next one,
   **F11** goes into the function the node calls, **Shift+F11** runs to the end of the function,
   **F5** continues to the next breakpoint, **Shift+F5** stops the program.

## Keys and commands

| Keys | Command | What it does |
|---|---|---|
| **F5** | Start Debugging / Continue | Not debugging: compile in Debug, then run. Stopped: continue. |
| **Shift+F5** | Stop Debugging | Ends the program. |
| (toolbar, Debug menu) | Pause | Stops a running program wherever it is (the main thread is shown). |
| **F9** | Toggle Breakpoint | On the selected node(s); also a click on the node's corner circle. |
| **F10** | Step Over | Runs the stopped node; stops at the next node of the Sheet. |
| **F11** | Step Into | Goes into the function the node calls, when it is your code. A call into a library (corlib, BeefLibs) is stepped over: stepping stays in the workspace's own files. |
| **Shift+F11** | Step Out | Runs to the end of the function; stops in the caller. |
| (Debug menu) | Attach to Process... | Disabled in phase 1 (tooltip: phase 2). |
| (Debug menu) | Remove All Breakpoints | For the current workspace. |

In the Project Browser, F5 still refreshes the browser.

## What you see

* **Breakpoints**: a red dot on the node's top-left corner. Moving the mouse near a node's corner
  shows a faint ring there: click it to set a breakpoint. A node that cannot have one says why in
  the ring's tooltip (see [Which nodes can have a breakpoint](#which-nodes-can-have-a-breakpoint)).
  Breakpoints are saved per workspace in `settings.json` (`projects.<workspace>.breakpoints`), never
  in the source. Each is stored as the file, the function and the node's content-keyed layout key
  (the key the `.vblayout` side file uses), so it stays on its node when lines move above it.
* **The stopped node**: yellow outline and an arrow on its left. The Sheet opens on it (a new tab
  if needed) and scrolls it into view. The editor window comes to the front.
* **Values on the stopped node**: each data pin with a value gets a small label beside it.
* **Values on hover**: while stopped, the tooltip of any data pin adds `Value: ...` (or why there
  is none). This works for every function on the call stack, not only the stopped one.
* **Locals** panel (docked with Properties): the variables of the selected frame with value and
  type; objects and structs expand member by member.
* **Call Stack** panel: one row per frame, your files in normal text, library and system frames
  dimmed; double-click a row to open that function's Sheet at the node (or the text at that line
  when the line is outside every Sheet). The selected frame also drives Locals and the pin values.
* **Debug Output** panel (with the Output Log): what the program writes to its console, with
  Clear and Copy. The program gets no console window.
* **Status bar**: "Running", "Stopped at Greeter.Hello" (with "(fault)" after a crash), "Not
  debugging" after a session.
* **Output Log**, category `Debug`: the command line, the engine used, "Process terminated.
  ExitCode: N." and the engine's messages; a toast says "The program exited with code N".

## Faults

An unhandled fault (an access violation, a failed check of the runtime) stops the program at the
node that faulted: the node is marked like any stop, the message ("The program stopped on a fault:
EXCEPTION_ACCESS_VIOLATION reading from 0x0 ...") is a toast and an error row in **Problems** (on
that node), and the status bar says "(fault)". When the fault happens inside a library, the Sheet
shown is the first frame of the call stack that is in your workspace. Continue passes the fault on
to the program (which usually ends it); Stop ends it.

## Which nodes can have a breakpoint

| Node | Line used |
|---|---|
| Statements (calls with flow pins, Set, Local with a value, Branch, loops, Switch, Return, Break, Continue, Code, Delete, Defer, Using, Result: match, ...) | the node's first line |
| The function's entry node | the line of the body's `{`: stops when the function starts (on its first statement) |
| Values (Get, operators, Cast, pure calls, Construct, Lambda, Format Text, ...) | the line of the statement that uses the value |
| No line (the circle is disabled and says why) | a node not in the code yet (unconnected, or not committed), a value nothing uses, a Local declared without a value, a local function's declaration, code that could not be read |

Several statements on one line share it: a stop on that line shows the innermost one.

## Limits (phase 1)

* Standalone programs only: no attach, no game, no hot reload (edit, F5 again).
* Values are read, never computed: properties and calls are not evaluated; a pure call's pin
  shows "Shown only by running code".
* Editing the Sheet while stopped is allowed, but the running program is the one that was built;
  lines may no longer match until the next F5.
* A breakpoint whose node was deleted is skipped (logged) at the next start; one the engine could
  not bind (no code at or after the line) never stops.
* Only Win64.
