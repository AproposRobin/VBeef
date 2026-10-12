---
audience: developer
title: Vocabulary
summary: The words VisualBeef uses for its panels and nodes, and the older terms they replace.
order: 22
---

# Vocabulary

VisualBeef uses its own words for what it shows, so nobody mistakes it for another tool. Every
concept is the same as the one you may know from a visual scripting editor; only the name differs.
The table lists each VisualBeef word, what it means in one line, and the term it replaces for
people who come from Unreal Engine's Blueprints. This page is the only place in the project
where those older terms are written down; `VisualBeefTests vocabulary` fails if one appears
anywhere else a user can read it (string literals of the sources, the manual, the README).

| VisualBeef | Meaning | Coming from Blueprints |
|---|---|---|
| **Sheet** | The visual document: the node graph of one function, plus its tabs and layout. | Blueprint |
| **Outline** | The panel that lists the open type's variables, functions and overrides; drag entries into the graph. | My Blueprint panel |
| **Type Settings** | The base type, interfaces, modifiers, attributes and generics of the type being edited. | Class Settings |
| **Properties** | The panel with the fields of the selected node, variable, function or type. | Details panel |
| **Project Browser** / **Project Drawer** | The folder and file browser of the project; the drawer is the same view opened over the graph (Ctrl+Space). | Content Browser / Content Drawer |
| **Node menu** | The searchable list of nodes you can add (right-click the graph, or drag off a pin). | Action menu |
| **Receiver** | The pin that takes the object a function is called on. Unconnected it reads `this`. | Target pin |
| **`this`** | The object the code is running on; shown on an unconnected Receiver. | self |
| **This** node | A node that gives you `this` as a value ("Get a reference to this"). | Self node, "Get a reference to self" |
| **Base** node | A node that gives you `base`, to call the base type's version of a function. | Parent node |
| **Flow pins** | The white pins that carry the order statements run in. | Exec pins, execution pins |
| **Flow nodes** | Nodes that sit in the order of execution (statements, loops, branches, calls with side effects). | Executable actions |
| **Overrides** | Functions a type replaces from its base type; each opens as its own sheet with a red entry. | Events, "UE: Create Event" |
| **Create override** | The command that adds an override (Type Settings > Add Override, or FUNCTIONS > Override in the Outline). | Add Event / Create Event |
| **Tick override** | The `Tick` override of an entry class (a host's base class): runs every frame. | Event Tick |
| **Value call** | A call with no flow pins: it is evaluated where its value is used. | Pure Function Call |
| **Return** | The node that leaves the function (with a value when the function has one). | Return Node |
| **Find in Sheets** | Project-wide search for types, functions, variables and node text (Ctrl+Shift+F). | Find in Blueprints |
| **All nodes for this Sheet** | The node menu's list when "context sensitive" is off. | All Actions for this Blueprint |
| `VISUALBEEF` | The faint label in the corner of the graph, followed by the function's name. | BLUEPRINT watermark |
| `[ExposeType]` | Attribute: a type usable for variables and pins (with Make/Break nodes). `[BlueprintType]` is still read. | BlueprintType |
| `[ExpandEnumAsFlow]` | Attribute: one flow output per enum or `Result` case. `[ExpandEnumAsExecs]` is still read. | ExpandEnumAsExecs |

## Host names

VisualBeef is a standalone editor; a host tool that starts it or provides templates and node
libraries integrates through the generic contract in [Host-Integration.md](Host-Integration.md).
No host product is named anywhere in VisualBeef: not in the UI, the sources (comments included),
the test fixtures, the scripts or the docs. `VisualBeefTests vocabulary` enforces this with a list
of banned host names and identifier prefixes (in `VocabularyTests.bf`, the only file allowed to hold
them); `CHANGELOG.md`, the history, is exempt.

## What did not change

* Beef keywords stay as Beef writes them: `this`, `base`, `override`, `scope`, `defer`, `new`.
* Names that belong to a game's SDK (types, namespaces, attributes it declares) are shown as the
  SDK writes them.
* Pin ids, node kinds and layout hashes keep their old internal names, so a `.vblayout` file written
  before the rename still matches the same nodes (see [Parsing-and-Layout.md](Parsing-and-Layout.md)).
* The dock layout is rebuilt once after the rename, because the panels have new ids.
