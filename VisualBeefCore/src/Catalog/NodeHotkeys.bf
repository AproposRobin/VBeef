using System;
using System.Collections;

namespace VisualBeef.Catalog
{
	/// Node hotkeys and favorites (docs/Editor-UI.md, "Node hotkeys and favorites").
	///
	/// A node is named by its Node menu key, "Category\tLabel" (the same key the menu's favorites and
	/// recents use). Favorites are an ordered list of keys; a hotkey is a plain letter A-Z bound to one
	/// key. A letter has at most one node and a node at most one letter. Letters the Sheet already uses
	/// on their own (C, F, M, Q) are refused, as is a letter another node owns (the owner is named).
	/// The editor stores both in settings.json (`editor.favorites`, `editor.nodeHotkeys`).
	class NodeHotkeys
	{
		public struct DefaultKey
		{
			public char8 Key;
			public StringView NodeKey;

			public this(char8 key, StringView nodeKey)
			{
				Key = key;
				NodeKey = nodeKey;
			}
		}

		/// The keys seeded on first run (each node is also a favorite).
		public static readonly DefaultKey[?] Defaults = .(
			.('B', "Flow Control\tBranch"),
			.('S', "Flow Control\tSequence"),
			.('E', "Flow Control\tFor Each Loop"),
			.('O', "Flow Control\tFor Loop"),
			.('W', "Flow Control\tWhile Loop"),
			.('R', "Flow Control\tReturn"),
			.('L', "Variables\tLocal Variable"),
			.('T', "Variables\tGet a reference to this"),
			.('P', "Utilities | Print\tPrint  (Console.WriteLine)"),
			.('N', "Lifetime\tConstruct  (new .())"),
			.('D', "Lifetime\tDefer"));

		/// Letters the Sheet uses on their own, and what for.
		public static StringView ReservedUse(char8 key)
		{
			switch (key.ToUpper)
			{
			case 'C': return "Comment box";
			case 'F': return "Frame the selection";
			case 'M': return "Minimap";
			case 'Q': return "Straighten wires";
			default: return "";
			}
		}

		public enum AssignResult
		{
			Ok,
			/// Not a letter A-Z.
			Invalid,
			/// A letter the Sheet already uses (ReservedUse names it).
			Reserved,
			/// Another node has this letter (the owner's key is returned).
			Taken
		}

		public List<String> Favorites = new .() ~ DeleteContainerAndItems!(_);
		/// Index 0 = 'A' ... 25 = 'Z'; null = no node.
		String[26] mKeys;

		public ~this()
		{
			for (let s in mKeys)
				delete s;
		}

		static int Slot(char8 key)
		{
			let k = key.ToUpper;
			return (k >= 'A' && k <= 'Z') ? (int)(k - 'A') : -1;
		}

		/// The display name of a node key (its label: "Flow Control\tBranch" -> "Branch").
		public static StringView LabelOf(StringView nodeKey)
		{
			int tab = nodeKey.IndexOf('\t');
			return (tab >= 0) ? nodeKey.Substring(tab + 1) : nodeKey;
		}

		/// A letter that can be a node hotkey (A-Z, not reserved).
		public static bool IsAssignable(char8 key) => Slot(key) >= 0 && ReservedUse(key).IsEmpty;

		public void Clear()
		{
			ClearAndDeleteItems!(Favorites);
			for (int i < mKeys.Count)
				DeleteAndNullify!(mKeys[i]);
		}

		/// Replaces everything with the defaults (the default nodes are favorites, with their keys).
		public void ResetToDefaults()
		{
			Clear();
			for (let d in Defaults)
			{
				AddFavorite(d.NodeKey);
				Assign(d.Key, d.NodeKey, null);
			}
		}

		// ------------------------------------------------------------------ keys

		/// The node of a letter ("" when none).
		public StringView NodeOf(char8 key)
		{
			let s = Slot(key);
			return (s >= 0 && mKeys[s] != null) ? (StringView)mKeys[s] : "";
		}

		/// The letter of a node ('\0' when none).
		public char8 KeyOf(StringView nodeKey)
		{
			for (int i < mKeys.Count)
				if (mKeys[i] != null && mKeys[i] == nodeKey)
					return (char8)('A' + i);
			return '\0';
		}

		public int KeyCount
		{
			get
			{
				int n = 0;
				for (let s in mKeys)
					if (s != null)
						n++;
				return n;
			}
		}

		/// Binds `key` to `nodeKey` (and makes it a favorite). A node that had another letter loses it
		/// (one letter per node).
		/// Refused for a non-letter, a reserved letter or a letter another node owns (`outOwner` gets
		/// that node's key). Assigning a node its own letter again is Ok.
		public AssignResult Assign(char8 key, StringView nodeKey, String outOwner)
		{
			let s = Slot(key);
			if (s < 0 || nodeKey.IsEmpty)
				return .Invalid;
			if (!ReservedUse(key).IsEmpty)
				return .Reserved;
			if (mKeys[s] != null)
			{
				if (mKeys[s] == nodeKey)
					return .Ok;
				outOwner?.Set(mKeys[s]);
				return .Taken;
			}
			ClearNode(nodeKey);
			mKeys[s] = new String(nodeKey);
			AddFavorite(nodeKey); // a hotkey belongs to a favorite
			return .Ok;
		}

		/// Removes a letter's binding. False when it had none.
		public bool ClearKey(char8 key)
		{
			let s = Slot(key);
			if (s < 0 || mKeys[s] == null)
				return false;
			DeleteAndNullify!(mKeys[s]);
			return true;
		}

		/// Removes a node's letter. False when it had none.
		public bool ClearNode(StringView nodeKey)
		{
			for (int i < mKeys.Count)
			{
				if (mKeys[i] != null && mKeys[i] == nodeKey)
				{
					DeleteAndNullify!(mKeys[i]);
					return true;
				}
			}
			return false;
		}

		/// Every binding in letter order.
		public void GetBindings(List<(char8 key, StringView nodeKey)> outList)
		{
			for (int i < mKeys.Count)
				if (mKeys[i] != null)
					outList.Add(((char8)('A' + i), mKeys[i]));
		}

		/// The message for a refused assignment ("" for Ok).
		public static void Describe(AssignResult r, char8 key, StringView owner, String outText)
		{
			let k = key.ToUpper;
			switch (r)
			{
			case .Ok:
			case .Invalid: outText.Append("Node hotkeys are the letters A to Z.");
			case .Reserved: outText.AppendF("{} is taken by the Sheet ({}).", k, ReservedUse(k));
			case .Taken: outText.AppendF("{} is already the hotkey of {}.", k, LabelOf(owner));
			}
		}

		// ------------------------------------------------------------------ favorites

		public bool IsFavorite(StringView nodeKey) => Favorites.ContainsAlt(nodeKey);

		/// Adds a favorite at the end. False when it already was one.
		public bool AddFavorite(StringView nodeKey)
		{
			if (nodeKey.IsEmpty || IsFavorite(nodeKey))
				return false;
			Favorites.Add(new String(nodeKey));
			return true;
		}

		/// Removes a favorite and its hotkey (a hotkey belongs to a favorite). False when it was not one.
		public bool RemoveFavorite(StringView nodeKey)
		{
			for (int i < Favorites.Count)
			{
				if (Favorites[i] == nodeKey)
				{
					delete Favorites[i];
					Favorites.RemoveAt(i);
					ClearNode(nodeKey);
					return true;
				}
			}
			return false;
		}

		/// True when the node is a favorite afterwards.
		public bool ToggleFavorite(StringView nodeKey)
		{
			if (RemoveFavorite(nodeKey))
				return false;
			AddFavorite(nodeKey);
			return true;
		}
	}
}
