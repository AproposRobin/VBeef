using System;
using System.Collections;
using VisualBeef.Syntax;

namespace VisualBeef.Graph
{
	/// Content-keyed layout keys.
	///
	/// A saved position is stored under `methodKey|path#hash`: the node's structural path
	/// ("s3/true/s0") and an 8-digit hash of what the node says (kind, text, constant inputs;
	/// whitespace and comments don't count). Loading matches saved entries to the current
	/// nodes, so a line inserted above, a deleted, edited or reordered statement leaves the
	/// other nodes where they were. Entries without `#hash` are the old positional form.
	static class LayoutKeys
	{
		public static uint32 Fnv(StringView s, uint32 seed = 2166136261)
		{
			uint32 h = seed;
			for (let c in s.RawChars)
			{
				h ^= (uint8)c;
				h *= 16777619;
			}
			return h;
		}

		public static uint32 Combine(uint32 a, uint32 b)
		{
			uint32 h = a;
			h ^= b + 0x9e3779b9 + (h << 6) + (h >> 2);
			return h;
		}

		/// Source text without comments or whitespace differences: tokens joined by one space.
		public static void Normalize(StringView text, String outText)
		{
			if (text.IsEmpty)
				return;
			List<Token> toks = scope .();
			Lexer.Tokenize(text, toks);
			bool first = true;
			for (let t in toks)
			{
				if (t.Kind == .EOF)
					continue;
				if (!first)
					outText.Append(' ');
				first = false;
				outText.Append(StringView(text, t.Start, t.End - t.Start));
			}
		}

		/// Hash of what one node says by itself (not its children or neighbours).
		public static uint32 ContentHash(Graph graph, Node n)
		{
			if (n == graph.Entry)
				return 0; // the signature may change without moving the entry node
			String s = scope .();
			s.AppendF("{}|", (int)n.Kind);
			Normalize(n.Text, s);
			s.Append('|');
			Normalize(n.Text2, s);
			s.AppendF("|{}{}{}{}|", n.NullCond ? 1 : 0, n.Cascade ? 1 : 0, n.Postfix ? 1 : 0, n.IsPure ? 1 : 0);
			if (n.Alloc != null || n.IsArray)
				s.AppendF("alloc={}{}|", n.Alloc, n.IsArray ? "[]" : "");
			if (n.Attributes != null)
			{
				s.Append("attr=");
				Normalize(n.Attributes, s);
				s.Append('|');
			}
			// Calls hash like before the call model, so positions saved then still match exactly:
			// a static call's qualifier was the text of its Target pin, and a Target wired from a
			// plain name (`obj.Foo()`, `this.Foo()`) was that name as text.
			if (n.Kind == .Call && n.Binding == .Static && n.Qualifier != null && !n.Qualifier.IsEmpty)
			{
				s.Append("target=");
				Normalize(n.Qualifier, s);
				s.Append(';');
			}
			for (let p in n.Inputs)
			{
				if (p.Kind != .Data)
					continue;
				s.Append(p.Name);
				s.Append('=');
				let link = graph.FindLinkTo(p);
				if (link != null)
				{
					let src = link.From.Owner;
					if (n.Kind == .Call && p.Name == "target" && (src.Kind == .This || src.Kind == .Base || (src.Kind == .Get && src.Inputs.IsEmpty)) && src.Original != null)
						Normalize(src.Text, s);
					else if ((src.Kind == .Construct || src.Kind == .Lambda) && src.Original != null && src.Original.Length <= 48 && !src.Original.Contains('\n'))
						Normalize(src.Original, s); // a short allocation / lambda was the pin's text before these nodes
					else if (src.Kind == .Format && src.Original != null)
						Normalize(src.Original, s); // an interpolated string was the pin's text before Format nodes
					else
						s.Append("<link>");
				}
				else
					Normalize(p.Default, s);
				s.Append(';');
			}
			return Fnv(s);
		}

		/// `path#hash` for ordinary nodes; orphans keep their plain key.
		public static void Compose(Node n, String outKey)
		{
			outKey.Append(n.Key);
			if (n.Key.StartsWith("orphan"))
				return;
			outKey.AppendF("#{:x8}", n.KeyHash);
		}

		/// Splits a saved node key into path and hash. hasHash is false for old positional keys.
		public static void Split(StringView key, out StringView path, out uint32 hash, out bool hasHash)
		{
			int i = key.IndexOf('#');
			hash = 0;
			hasHash = false;
			if (i < 0)
			{
				path = key;
				return;
			}
			path = key.Substring(0, i);
			var h = key.Substring(i + 1);
			uint32 v = 0;
			bool ok = h.Length > 0 && h.Length <= 8;
			for (let c in h.RawChars)
			{
				uint32 d = 0;
				if (c >= '0' && c <= '9') d = (uint32)(c - '0');
				else if (c >= 'a' && c <= 'f') d = (uint32)(c - 'a' + 10);
				else { ok = false; break; }
				v = (v << 4) | d;
			}
			if (ok)
			{
				hash = v;
				hasHash = true;
			}
		}

		/// Orders paths like a human would: "s2" before "s10", "s1/true/s0" after "s1".
		public static int ComparePaths(StringView a, StringView b)
		{
			int i = 0;
			int j = 0;
			while (i < a.Length && j < b.Length)
			{
				if (CharUtil.IsDigit(a[i]) && CharUtil.IsDigit(b[j]))
				{
					int si = i;
					int sj = j;
					while (i < a.Length && CharUtil.IsDigit(a[i])) i++;
					while (j < b.Length && CharUtil.IsDigit(b[j])) j++;
					int64 na = int64.Parse(a.Substring(si, i - si)).GetValueOrDefault();
					int64 nb = int64.Parse(b.Substring(sj, j - sj)).GetValueOrDefault();
					if (na != nb)
						return (na < nb) ? -1 : 1;
					continue;
				}
				if (a[i] != b[j])
					return (a[i] < b[j]) ? -1 : 1;
				i++;
				j++;
			}
			if (i < a.Length) return 1;
			if (j < b.Length) return -1;
			return 0;
		}

		/// Matches saved node keys to the current nodes. outMatch[i] is the index in `nodes` of
		/// the node the i-th saved key belongs to, or -1 when it matches nothing. In order:
		///   (a) the same path and hash,
		///   (b) the same hash on a different path (the statement moved), paired in source order,
		///   (c) the same path and a different hash (the statement was edited; old positional
		///       keys, which carry no hash, only ever match this way).
		/// Statements left over are new and get auto-layout; saved keys left over are stale.
		/// `samePlace` = false skips (c).
		public static void Reconcile(List<StringView> saved, List<Node> nodes, List<int> outMatch, bool samePlace = true)
		{
			outMatch.Clear();
			for (int i < saved.Count)
				outMatch.Add(-1);
			let nodeUsed = scope bool[nodes.Count];

			Dictionary<String, int> byFull = scope .();
			defer { for (let k in byFull.Keys) delete k; }
			Dictionary<String, int> byPath = scope .();
			defer { for (let k in byPath.Keys) delete k; }
			for (int ni < nodes.Count)
			{
				let n = nodes[ni];
				String full = new .();
				Compose(n, full);
				if (!byFull.TryAdd(full, ni))
					delete full;
				String path = new String(n.Key);
				if (!byPath.TryAdd(path, ni))
					delete path;
			}

			// (a) exact
			for (int si < saved.Count)
			{
				if (byFull.TryGetValueAlt(saved[si], let ni) && !nodeUsed[ni])
				{
					outMatch[si] = ni;
					nodeUsed[ni] = true;
				}
			}

			// (b) same hash, different path
			{
				Dictionary<uint32, List<int>> savedByHash = scope .();
				Dictionary<uint32, List<int>> nodesByHash = scope .();
				defer { for (let l in savedByHash.Values) delete l; }
				defer { for (let l in nodesByHash.Values) delete l; }
				for (int si < saved.Count)
				{
					if (outMatch[si] >= 0)
						continue;
					Split(saved[si], let path, let hash, let hasHash);
					if (!hasHash)
						continue;
					if (!savedByHash.TryGetValue(hash, var list))
					{
						list = new .();
						savedByHash[hash] = list;
					}
					list.Add(si);
				}
				for (int ni < nodes.Count)
				{
					if (nodeUsed[ni] || nodes[ni].Key.StartsWith("orphan"))
						continue;
					let h = nodes[ni].KeyHash;
					if (!savedByHash.ContainsKey(h))
						continue;
					if (!nodesByHash.TryGetValue(h, var list))
					{
						list = new .();
						nodesByHash[h] = list;
					}
					list.Add(ni);
				}
				for (let kv in savedByHash)
				{
					if (!nodesByHash.TryGetValue(kv.key, let nlist))
						continue;
					let slist = kv.value;
					slist.Sort(scope (x, y) =>
					{
						Split(saved[x], let px, ?, ?);
						Split(saved[y], let py, ?, ?);
						return ComparePaths(px, py);
					});
					nlist.Sort(scope (x, y) => ComparePaths(nodes[x].Key, nodes[y].Key));
					int count = Math.Min(slist.Count, nlist.Count);
					for (int k < count)
					{
						outMatch[slist[k]] = nlist[k];
						nodeUsed[nlist[k]] = true;
					}
				}
			}

			// (c) same path, different hash (or an old positional key)
			for (int si < saved.Count)
			{
				if (!samePlace)
					break;
				if (outMatch[si] >= 0)
					continue;
				Split(saved[si], let path, ?, ?);
				if (byPath.TryGetValueAlt(path, let ni) && !nodeUsed[ni] && !nodes[ni].Key.StartsWith("orphan"))
				{
					outMatch[si] = ni;
					nodeUsed[ni] = true;
				}
			}
		}
	}
}
