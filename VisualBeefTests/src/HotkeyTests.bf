using System;
using System.Collections;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests hotkeys`: the node hotkey map and favorites (NodeHotkeys): the defaults,
	/// assignment, conflicts (a reserved letter, a letter another node owns, with the owner named),
	/// one letter per node, clearing, and favorites owning their hotkeys.
	static class HotkeyTests
	{
		static int sChecks;
		static int sFailures;

		static void Check(bool cond, StringView what)
		{
			sChecks++;
			if (cond)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		public static int Run()
		{
			sChecks = 0;
			sFailures = 0;
			Defaults();
			Conflicts();
			Clearing();
			Favorites();
			Console.WriteLine("hotkey checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}

		static void Defaults()
		{
			Console.WriteLine("defaults");
			HashSet<char8> keys = scope .();
			HashSet<String> nodes = scope .();
			bool allAssignable = true;
			for (let d in NodeHotkeys.Defaults)
			{
				keys.Add(d.Key);
				nodes.Add(scope:: String(d.NodeKey));
				if (!NodeHotkeys.IsAssignable(d.Key))
					allAssignable = false;
			}
			Check(NodeHotkeys.Defaults.Count == 11, scope $"11 default hotkeys ({NodeHotkeys.Defaults.Count})");
			Check(keys.Count == NodeHotkeys.Defaults.Count && nodes.Count == NodeHotkeys.Defaults.Count, "default letters and nodes are distinct");
			Check(allAssignable, "no default letter is reserved by the Sheet (C, F, M, Q)");
			let map = scope NodeHotkeys();
			map.ResetToDefaults();
			Check(map.KeyCount == 11 && map.Favorites.Count == 11, scope $"seeded: 11 keys, 11 favorites ({map.KeyCount}, {map.Favorites.Count})");
			Check(map.NodeOf('B') == "Flow Control\tBranch" && map.NodeOf('b') == "Flow Control\tBranch", "B (and b) is Branch");
			Check(map.NodeOf('P') == "Utilities | Print\tPrint  (Console.WriteLine)", "P is Print (Console.WriteLine)");
			Check(map.KeyOf("Flow Control\tReturn") == 'R', "Return has R");
			Check(map.KeyOf("Flow Control\tSequence") == 'S' && map.KeyOf("Variables\tLocal Variable") == 'L', "Sequence S, Local Variable L");
			Check(map.NodeOf('Z').IsEmpty && map.KeyOf("Flow Control\tGate") == '\0', "unbound letter and node: empty");
			Check(map.IsFavorite("Flow Control\tBranch"), "a default node is a favorite");
			Check(NodeHotkeys.LabelOf("Flow Control\tFor Each Loop") == "For Each Loop", "LabelOf gives the label");
			List<(char8 key, StringView nodeKey)> b = scope .();
			map.GetBindings(b);
			Check(b.Count == 11 && b[0].key == 'B' && b[b.Count - 1].key == 'W', "bindings in letter order (B first, W last)");
		}

		static void Conflicts()
		{
			Console.WriteLine("conflicts");
			let map = scope NodeHotkeys();
			map.ResetToDefaults();
			String owner = scope .();
			String msg = scope .();
			var r = map.Assign('B', "Flow Control\tGate", owner);
			Check(r == .Taken && owner == "Flow Control\tBranch", scope $"B for Gate refused: owned by Branch ({r}, '{owner}')");
			NodeHotkeys.Describe(r, 'b', owner, msg);
			Check(msg == "B is already the hotkey of Branch.", scope $"message names the owner: \"{msg}\"");
			Check(map.NodeOf('B') == "Flow Control\tBranch" && map.KeyOf("Flow Control\tGate") == '\0', "refusal changes nothing");
			r = map.Assign('C', "Flow Control\tGate", owner);
			msg.Clear();
			NodeHotkeys.Describe(r, 'C', owner, msg);
			Check(r == .Reserved && msg == "C is taken by the Sheet (Comment box).", scope $"C refused: \"{msg}\"");
			Check(map.Assign('F', "Flow Control\tGate", null) == .Reserved && map.Assign('M', "x\ty", null) == .Reserved && map.Assign('Q', "x\ty", null) == .Reserved, "F, M, Q refused");
			r = map.Assign('5', "Flow Control\tGate", owner);
			msg.Clear();
			NodeHotkeys.Describe(r, '5', owner, msg);
			Check(r == .Invalid && msg.Contains("A to Z"), scope $"a digit refused: \"{msg}\"");
			Check(map.Assign('B', "Flow Control\tBranch", owner) == .Ok && map.KeyOf("Flow Control\tBranch") == 'B', "re-assigning a node its own letter is Ok");
			Check(map.Assign('g', "Flow Control\tGate", owner) == .Ok && map.NodeOf('G') == "Flow Control\tGate", "a free letter (lower case g) binds G");
			Check(map.IsFavorite("Flow Control\tGate"), "assigning a key makes the node a favorite");
			Check(map.Assign('K', "Flow Control\tGate", owner) == .Ok && map.NodeOf('G').IsEmpty && map.KeyOf("Flow Control\tGate") == 'K', "a node has one letter: G moves to K");
		}

		static void Clearing()
		{
			Console.WriteLine("clear");
			let map = scope NodeHotkeys();
			map.ResetToDefaults();
			Check(map.ClearKey('b') && map.NodeOf('B').IsEmpty && map.KeyCount == 10, "ClearKey(b) frees B");
			Check(!map.ClearKey('B'), "clearing a free letter: false");
			Check(map.IsFavorite("Flow Control\tBranch"), "clearing a key keeps the favorite");
			Check(map.Assign('B', "Flow Control\tGate", null) == .Ok, "a cleared letter can be reused (B for Gate)");
			Check(map.ClearNode("Flow Control\tReturn") && map.NodeOf('R').IsEmpty, "ClearNode(Return) frees R");
			Check(!map.ClearNode("Flow Control\tReturn"), "clearing a node with no key: false");
			map.Clear();
			Check(map.KeyCount == 0 && map.Favorites.IsEmpty, "Clear empties keys and favorites");
			map.ResetToDefaults();
			Check(map.KeyCount == 11 && map.NodeOf('B') == "Flow Control\tBranch", "ResetToDefaults restores the table");
		}

		static void Favorites()
		{
			Console.WriteLine("favorites");
			let map = scope NodeHotkeys();
			Check(map.AddFavorite("Math\tMin") && !map.AddFavorite("Math\tMin"), "AddFavorite once");
			Check(map.Assign('X', "Math\tMin", null) == .Ok && map.KeyOf("Math\tMin") == 'X', "favorite gets X");
			Check(!map.ToggleFavorite("Math\tMin") && !map.IsFavorite("Math\tMin") && map.NodeOf('X').IsEmpty, "removing a favorite removes its hotkey");
			Check(map.ToggleFavorite("Math\tMin") && map.IsFavorite("Math\tMin") && map.KeyOf("Math\tMin") == '\0', "toggled back: a favorite with no key");
			map.AddFavorite("A\tOne");
			Check(map.Favorites.Count == 2 && map.Favorites[0] == "Math\tMin" && map.Favorites[1] == "A\tOne", "favorites keep their order");
			Check(!map.AddFavorite(""), "an empty key is not a favorite");
		}
	}
}
