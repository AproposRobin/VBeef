using System;
using System.Collections;
using System.Diagnostics;
using VisualBeef.Document;

namespace VisualBeef.Catalog
{
	enum NodeEntryKind : uint8
	{
		Call,   // function with exec pins
		Pure,   // function without exec pins
		Get,    // read a field / property
		Set,    // write a field / property
		Event,  // an Event<...> field (bind / invoke)
		Flow    // [ExpandEnumAsFlow]: one flow output per case
	}

	[CRepr]
	struct CatalogEntry
	{
		public int32 Member;
		public int32 Category;
		public StrRef Display;   // in the StoreCatalog pool
		public StrRef Search;    // lowercase search key in the pool
		public StrRef Keywords;  // in the pool
		public uint64 CharMask;  // letters/digits present in Search
		public NodeEntryKind Kind;
		public uint8 Flags;
		public uint16 Pad;

		public const uint8 cStatic = 1;
		public const uint8 cConversion = 2;
		public const uint8 cAdvanced = 4;
		public const uint8 cCompact = 8;
		public const uint8 cGeneric = 16;
		public const uint8 cOverloaded = 32;
		public const uint8 cAttributed = 64;

		public bool IsStatic => (Flags & cStatic) != 0;
	}

	/// One pin of a node spec.
	class PinSpec
	{
		public String Name = new .() ~ delete _;     // parameter name (code)
		public String Label = new .() ~ delete _;    // shown on the pin ([Pin(Name=...)] or the name)
		public String Type = new .() ~ delete _;
		public String Default = new .() ~ delete _;  // Beef default value or [Pin(Default=...)]
		public String Tooltip = new .() ~ delete _;  // [Pin(Tooltip)] or <param> doc
		public String Modifier = new .() ~ delete _; // ref / out / params
		public bool Advanced;
		/// `[Pin(Out=true)]` on a `ref` parameter: shown as an output pin like `out`.
		public bool OutRef;

		/// The parameter is an output of the node: `out`, or `ref` marked `[Pin(Out=true)]`.
		public bool IsOutput => OutRef || IsOutModifier(Modifier);
		public bool IsRef => !OutRef && HasWord(Modifier, "ref");

		public static bool IsOutModifier(StringView modifier) => HasWord(modifier, "out");

		public static bool HasWord(StringView text, StringView word)
		{
			for (var part in text.Split(' '))
			{
				part.Trim();
				if (part == word)
					return true;
			}
			return false;
		}
	}

	/// Everything the editor needs to show and create one catalog entry.
	class NodeSpec
	{
		public int32 Id = -1;
		public NodeEntryKind Kind;
		public String Label = new .() ~ delete _;        // menu text (display name + overload hint)
		public String DisplayName = new .() ~ delete _;
		public String Category = new .() ~ delete _;
		public String Keywords = new .() ~ delete _;
		public String Tooltip = new .() ~ delete _;
		/// Code to call: "Math.Lerp" (static), "TakeDamage" (instance), "Type.Field".
		public String CallName = new .() ~ delete _;
		public String MemberName = new .() ~ delete _;
		public String OwnerType = new .() ~ delete _;     // declaring type ("List<T>" for generics)
		public String Namespace = new .() ~ delete _;
		public String ReturnType = new .() ~ delete _;    // value type for Get/Set
		public String ParamsText = new .() ~ delete _;    // "float a, float b = 0.5f"
		public List<PinSpec> Pins = new .() ~ DeleteContainerAndItems!(_);
		public String ExpandEnumParam = new .() ~ delete _;
		public List<String> EnumCases = new .() ~ DeleteContainerAndItems!(_);
		public bool IsStatic;
		public bool IsConversion;
		public bool IsCompact;
		public String CompactTitle = new .() ~ delete _;
		public bool IsPure => Kind == .Pure || Kind == .Get;
	}

	/// The catalog entries of one symbol store, with their own string pool.
	class StoreCatalog
	{
		public SymbolStore Store;
		public String Pool = new .() ~ delete _;
		public List<CatalogEntry> Entries = new .() ~ delete _;

		public StringView Str(StrRef r) => (r.Len == 0) ? "" : StringView(Pool, r.Off, r.Len);

		public StrRef Add(StringView s)
		{
			if (s.IsEmpty)
				return default;
			StrRef r = .() { Off = (int32)Pool.Length, Len = (int32)s.Length };
			Pool.Append(s);
			return r;
		}
	}

	/// A node of the category tree ("Math" > "Vector").
	class CategoryNode
	{
		public String Name = new .() ~ delete _;
		public String Path = new .() ~ delete _;
		public List<CategoryNode> Children = new .() ~ DeleteContainerAndItems!(_);
		public List<int32> Entries = new .() ~ delete _;
		/// Entries in this node and below.
		public int32 Total;

		/// Children by name (a generated SDK puts thousands of classes under one parent, so a
		/// linear scan made the first tree take most of a second).
		Dictionary<StringView, CategoryNode> mByName ~ delete _;

		public CategoryNode Child(StringView name)
		{
			if (mByName == null)
				mByName = new .();
			if (mByName.TryGetValue(name, let found))
				return found;
			CategoryNode n = new .();
			n.Name.Set(name);
			if (!Path.IsEmpty)
				n.Path.AppendF("{}|", Path);
			n.Path.Append(name);
			Children.Add(n);
			mByName[n.Name] = n;
			return n;
		}
	}

	/// Library catalogs built on the indexing worker (NodeCatalog.Prebuild) with their own
	/// category table; the UI thread adopts them (NodeCatalog.Adopt), renumbering categories.
	class PrebuiltCatalogs
	{
		public List<StoreCatalog> Stores = new .() ~ DeleteContainerAndItems!(_);
		public List<String> Categories = new .() ~ DeleteContainerAndItems!(_);
		public double BuildMs;
	}

	struct SearchHit
	{
		public int32 Id;
		public float Score;
	}

	/// Which pins a context-sensitive search is for.
	enum PinContext : uint8
	{
		None,
		/// Dragged from a data output: entries with an input (or target) that takes the type.
		TakesValue,
		/// Dragged from a data input: entries with an output of the type.
		GivesValue
	}

	/// Every node VisualBeef can offer from code: the project's and the libraries' members,
	/// filtered and labelled by the VisualBeefMeta attributes (or by visibility when a store uses
	/// none). Entries are flat records; search runs over a precomputed lowercase key with a
	/// character-mask prefilter, so 100k entries search in milliseconds without allocating.
	class NodeCatalog
	{
		TypeService mService;
		public List<StoreCatalog> Stores = new .() ~ DeleteContainerAndItems!(_);
		public List<String> Categories = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, int32> mCategoryIds = new .() ~ delete _;
		int32 mGeneration = -1;
		CategoryNode mTree ~ delete _;
		Dictionary<int, StoreCatalog> mByStore = new .() ~ delete _;
		/// Memo of context checks: (store, type string offset, context) -> relevance.
		Dictionary<int64, int8> mContextMemo = new .() ~ delete _;
		String mContextType = new .() ~ delete _;
		PinContext mContextKind;

		public double LastBuildMs;
		public int TotalEntries;

		/// Library catalogs made on the indexing worker, waiting for Refresh to take them.
		List<PrebuiltCatalogs> mPrebuilt = new .() ~ DeleteContainerAndItems!(_);
		/// Ms the last Refresh spent adopting prebuilt catalogs (renumbering their categories).
		public double LastAdoptMs;

		public this(TypeService service)
		{
			mService = service;
		}

		/// Builds the catalog entries of library stores off the UI thread (the indexing worker
		/// calls it right after loading them). Touches only the stores and the result.
		public static PrebuiltCatalogs Prebuild(List<SymbolStore> stores)
		{
			let sw = scope Stopwatch(true);
			NodeCatalog tmp = scope .(null);
			PrebuiltCatalogs p = new .();
			for (let store in stores)
			{
				StoreCatalog sc = new .();
				sc.Store = store;
				tmp.BuildStore(sc);
				p.Stores.Add(sc);
			}
			Swap!(p.Categories, tmp.Categories);
			p.BuildMs = sw.Elapsed.TotalMilliseconds;
			return p;
		}

		/// Hands catalogs built by Prebuild to this catalog: the next Refresh uses them for their
		/// stores instead of building on the UI thread.
		public void Adopt(PrebuiltCatalogs prebuilt)
		{
			if (prebuilt != null)
				mPrebuilt.Add(prebuilt);
		}

		/// The prebuilt catalog of a store, with its categories renumbered into this catalog.
		StoreCatalog TakePrebuilt(SymbolStore store)
		{
			for (let p in mPrebuilt)
			{
				for (let sc in p.Stores)
				{
					if (sc.Store != store)
						continue;
					p.Stores.Remove(sc);
					int32[] remap = scope .[p.Categories.Count];
					for (int i < remap.Count)
						remap[i] = -1;
					for (int ei < sc.Entries.Count)
					{
						var e = ref sc.Entries[ei];
						var id = ref remap[e.Category];
						if (id < 0)
							id = CategoryId(p.Categories[e.Category]);
						e.Category = id;
					}
					return sc;
				}
			}
			return null;
		}

		public static int32 MakeId(int store, int entry) => (int32)((store << 24) | entry);
		public static int StoreOf(int32 id) => (id >> 24) & 0xFF;
		public static int EntryOf(int32 id) => id & 0xFFFFFF;

		public ref CatalogEntry Entry(int32 id) => ref Stores[StoreOf(id)].Entries[EntryOf(id)];
		public StoreCatalog StoreOfId(int32 id) => Stores[StoreOf(id)];

		/// Rebuilds the entries of stores that changed since the last call.
		public void Refresh()
		{
			mService.Sync();
			if (mGeneration == mService.Generation)
				return;
			mGeneration = mService.Generation;
			let sw = scope Stopwatch(true);
			LastAdoptMs = 0;
			InvalidateSearchCache();
			List<SymbolStore> stores = scope .();
			mService.AllStores(stores);
			// Library catalogs survive project edits; the project's is rebuilt.
			List<StoreCatalog> old = scope .();
			old.AddRange(Stores);
			Stores.Clear();
			mByStore.Clear();
			for (let store in stores)
			{
				StoreCatalog sc = null;
				for (let o in old)
				{
					if (o.Store == store && store.IsLibrary)
					{
						sc = o;
						old.Remove(o);
						break;
					}
				}
				if (sc == null && store.IsLibrary)
				{
					let swAdopt = scope Stopwatch(true);
					sc = TakePrebuilt(store);
					if (sc != null)
						LastAdoptMs += swAdopt.Elapsed.TotalMilliseconds;
				}
				if (sc == null)
				{
					sc = new .();
					sc.Store = store;
					BuildStore(sc);
				}
				mByStore[(int)Internal.UnsafeCastToPtr(store)] = sc;
				Stores.Add(sc);
			}
			ClearAndDeleteItems!(old);
			// Prebuilt catalogs whose store is gone (a re-index replaced it) are dropped.
			ClearAndDeleteItems!(mPrebuilt);
			DeleteAndNullify!(mTree);
			mContextMemo.Clear();
			mContextType.Clear();
			TotalEntries = 0;
			for (let sc in Stores)
				TotalEntries += sc.Entries.Count;
			LastBuildMs = sw.Elapsed.TotalMilliseconds;
		}

		public int32 CategoryId(StringView path)
		{
			if (mCategoryIds.TryGetValueAlt(path, let id))
				return id;
			String s = new .(path);
			Categories.Add(s);
			let nid = (int32)(Categories.Count - 1);
			mCategoryIds[s] = nid;
			return nid;
		}

		// ------------------------------------------------------------------ build

		/// "ApplyDamage" -> "Apply Damage", "mHealth" -> "Health", "GetHTTPCode" -> "Get HTTP Code".
		public static void Words(StringView name, String outText)
		{
			var n = name;
			if (n.Length > 1 && n[0] == 'm' && n[1].IsUpper)
				n = n.Substring(1);
			if (n.Length > 1 && (n[0] == 'b') && n[1].IsUpper)
				n = n.Substring(1);
			for (int i < n.Length)
			{
				let c = n[i];
				if (c == '_')
				{
					if (!outText.IsEmpty && !outText.EndsWith(' '))
						outText.Append(' ');
					continue;
				}
				if (i > 0 && c.IsUpper && !outText.EndsWith(' '))
				{
					let prev = n[i - 1];
					bool nextLower = i + 1 < n.Length && n[i + 1].IsLower;
					if (prev.IsLower || prev.IsDigit || (prev.IsUpper && nextLower))
						outText.Append(' ');
				}
				outText.Append(c);
			}
		}

		static uint64 CharMask(StringView s)
		{
			uint64 mask = 0;
			for (let c in s.RawChars)
			{
				if (c >= 'a' && c <= 'z')
					mask |= 1UL << (c - 'a');
				else if (c >= '0' && c <= '9')
					mask |= 1UL << (26 + (c - '0'));
				else if (c >= 'A' && c <= 'Z')
					mask |= 1UL << (c - 'A');
			}
			return mask;
		}

		/// Is a member offered as a node? (rules in docs/Catalog-and-Types.md)
		static bool Offered(SymbolStore store, TypeRec type, MemberRec m, List<AttrInfo> typeAttrs, List<AttrInfo> attrs, bool typeIsLibrary)
		{
			if (AttributeParser.Find(attrs, "NodeHidden") != null || AttributeParser.Find(typeAttrs, "NodeHidden") != null)
				return false;
			let name = store.Str(m.Name);
			if (name.IsEmpty || name.Contains('.') || name.StartsWith('~') || m.IsMixin || m.Kind == .Ctor)
				return false;
			if (store.UsesNodeAttributes)
			{
				// A project Node Library (`static class`): every public static member is offered.
				if (!store.IsLibrary && (type.TypeFlags & TypeRec.cStatic) != 0 && store.Str(type.Kind) == "class" && m.IsStatic && m.Visibility == .Public)
					return true;
				// Attributed store: only what is tagged (or public static in a [NodeLibrary]).
				if (AttributeParser.Find(attrs, "Node") != null || AttributeParser.Find(attrs, "Pure") != null ||
					AttributeParser.Find(attrs, "Expose") != null || AttributeParser.Find(attrs, "Conversion") != null)
					return true;
				return typeIsLibrary && m.IsStatic && m.Visibility == .Public && m.IsMethod;
			}
			// No attributes anywhere: every public member (internal too inside the project).
			if (m.Visibility == .Public)
				return true;
			return m.Visibility == .Internal && !store.IsLibrary;
		}

		void BuildStore(StoreCatalog sc)
		{
			let store = sc.Store;
			List<AttrInfo> typeAttrs = scope .();
			List<AttrInfo> attrs = scope .();
			defer { ClearAndDeleteItems!(typeAttrs); ClearAndDeleteItems!(attrs); }
			String category = scope .();
			String display = scope .();
			String search = scope .();
			String keywords = scope .();
			String typeCategory = scope .();
			for (int ti < store.Types.Count)
			{
				let type = ref store.Types[ti];
				let kind = store.Str(type.Kind);
				if (kind == "enum" || kind == "interface")
					continue;
				// Nested private types and private types don't offer nodes.
				if (type.Visibility == .Private && !store.Str(type.Outer).IsEmpty)
					continue;
				ClearAndDeleteItems!(typeAttrs);
				let typeAttrText = store.Str(type.Attributes);
				if (!typeAttrText.IsEmpty)
					AttributeParser.Parse(typeAttrText, typeAttrs);
				let lib = AttributeParser.Find(typeAttrs, "NodeLibrary");
				let typeName = store.Str(type.Name);
				let ns = store.Str(type.Namespace);
				bool projectLibrary = lib == null && !store.IsLibrary && (type.TypeFlags & TypeRec.cStatic) != 0 && kind == "class";
				typeCategory.Clear();
				if (lib != null && !lib.Get("Category", 0).IsEmpty)
					typeCategory.Set(lib.Get("Category", 0));
				else
				{
					if (!ns.IsEmpty)
					{
						typeCategory.Append(ns);
						typeCategory.Replace('.', '|');
					}
					else
						typeCategory.Append(store.IsLibrary ? (StringView)store.Name : "Project");
					typeCategory.Append('|');
					if (projectLibrary)
					{
						typeCategory.Clear();
						if (ns.IsEmpty)
							typeCategory.AppendF("Libraries|{}", typeName);
						else
							typeCategory.AppendF("Libraries|{}.{}", ns, typeName); // the namespace names the group, as a class's does
					}
					else if (kind == "static")
						typeCategory.Append("Global Functions");
					else
					{
						let outer = store.Str(type.Outer);
						if (!outer.IsEmpty)
							typeCategory.AppendF("{}.", outer);
						typeCategory.Append(typeName);
					}
				}
				bool typeGeneric = !store.Str(type.GenericParams).IsEmpty;

				for (int mi = type.FirstMember; mi < type.FirstMember + type.MemberCount; mi++)
				{
					let m = ref store.Members[mi];
					ClearAndDeleteItems!(attrs);
					let attrText = store.Str(m.Attributes);
					if (!attrText.IsEmpty)
						AttributeParser.Parse(attrText, attrs);
					if (!Offered(store, type, m, typeAttrs, attrs, lib != null))
						continue;
					let name = store.Str(m.Name);
					let node = AttributeParser.Find(attrs, "Node");
					let pure = AttributeParser.Find(attrs, "Pure");
					let expose = AttributeParser.Find(attrs, "Expose");
					let conv = AttributeParser.Find(attrs, "Conversion");
					let expand = (AttributeParser.Find(attrs, "ExpandEnumAsFlow") ?? AttributeParser.Find(attrs, "ExpandEnumAsExecs"));

					category.Clear();
					StringView explicitCat = default;
					if (node != null) explicitCat = node.Get("Category", 0);
					if (explicitCat.IsEmpty && pure != null) explicitCat = pure.Get("Category", 0);
					if (explicitCat.IsEmpty && expose != null) explicitCat = expose.Get("Category", 0);
					if (!explicitCat.IsEmpty)
						category.Set(explicitCat);
					else
						category.Set(typeCategory);
					// A static variable is a global: Get / Set from any sheet under Globals > Owner.
					if (explicitCat.IsEmpty && !m.IsMethod && m.IsStatic && !store.IsLibrary && !store.Str(m.Type).StartsWith("Event<"))
					{
						category.Clear();
						category.AppendF("Globals|{}", typeName);
					}
					int32 catId = CategoryId(category);

					display.Clear();
					StringView explicitName = default;
					if (node != null) explicitName = node.Get("DisplayName");
					if (explicitName.IsEmpty && expose != null) explicitName = expose.Get("DisplayName");
					if (!explicitName.IsEmpty)
						display.Set(explicitName);
					else
						Words(name, display);

					keywords.Clear();
					if (node != null)
						keywords.Set(node.Get("Keywords"));

					uint8 flags = 0;
					if (m.IsStatic) flags |= CatalogEntry.cStatic;
					if (conv != null) flags |= CatalogEntry.cConversion;
					if (node != null && node.GetBool("Advanced")) flags |= CatalogEntry.cAdvanced;
					if (node != null && node.GetBool("Compact")) flags |= CatalogEntry.cCompact;
					if (typeGeneric || !store.Str(m.GenericParams).IsEmpty) flags |= CatalogEntry.cGeneric;
					if (node != null || pure != null || expose != null || conv != null) flags |= CatalogEntry.cAttributed;

					void AddEntry(NodeEntryKind ek, StringView prefix)
					{
						CatalogEntry e = default;
						e.Member = (int32)mi;
						e.Category = catId;
						String disp = scope .();
						if (!prefix.IsEmpty)
							disp.AppendF("{} ", prefix);
						disp.Append(display);
						e.Display = sc.Add(disp);
						search.Clear();
						search.AppendF("{} {} {} {}", disp, name, keywords, typeName);
						search.ToLower();
						e.Search = sc.Add(search);
						e.Keywords = sc.Add(keywords);
						e.CharMask = CharMask(search);
						e.Kind = ek;
						e.Flags = flags;
						sc.Entries.Add(e);
					}

					if (m.IsMethod)
					{
						NodeEntryKind ek = .Call;
						let ret = store.Str(m.Type);
						bool hasRefOut = false;
						for (int pi < m.ParamCount)
						{
							let mod = store.Str(store.Params[m.FirstParam + pi].Modifier);
							if (mod.Contains("ref") || mod.Contains("out"))
								hasRefOut = true;
						}
						if (pure != null || (node != null && node.GetBool("Pure")))
							ek = .Pure;
						else if (node == null && lib != null && m.IsStatic && ret != "void" && !hasRefOut)
							ek = .Pure; // [NodeLibrary] default
						if (expand != null)
							ek = .Flow;
						AddEntry(ek, "");
					}
					else
					{
						let ftype = store.Str(m.Type);
						if (ftype.StartsWith("Event<"))
						{
							AddEntry(.Event, "");
							continue;
						}
						AddEntry(.Get, "Get");
						bool readOnly = expose != null && expose.GetBool("ReadOnly");
						// Set nodes write a variable by name, so only static members get one; instance
						// members are set through their own type's variables.
						if (m.Writable && !readOnly && m.IsStatic)
							AddEntry(.Set, "Set");
					}
				}
			}
			// Overloads: same display name in the same type -> label shows parameter types.
			Dictionary<int64, int32> firstByKey = scope .();
			for (int i < sc.Entries.Count)
			{
				var e = ref sc.Entries[i];
				let owner = store.Members[e.Member].Owner;
				int64 key = ((int64)owner << 32) ^ (int64)StringView(sc.Str(e.Display)).GetHashCode();
				if (firstByKey.TryGetValue(key, let first))
				{
					sc.Entries[first].Flags |= CatalogEntry.cOverloaded;
					e.Flags |= CatalogEntry.cOverloaded;
				}
				else
					firstByKey[key] = (int32)i;
			}
		}

		// ------------------------------------------------------------------ details

		/// Fills a spec for an entry: labels, pins (with defaults and tooltips), call text.
		public void GetSpec(int32 id, NodeSpec spec)
		{
			let sc = StoreOfId(id);
			let store = sc.Store;
			let e = ref sc.Entries[EntryOf(id)];
			let m = ref store.Members[e.Member];
			let type = ref store.Types[m.Owner];
			spec.Id = id;
			spec.Kind = e.Kind;
			spec.DisplayName.Set(sc.Str(e.Display));
			spec.Category.Set(Categories[e.Category]);
			spec.Keywords.Set(sc.Str(e.Keywords));
			spec.MemberName.Set(store.Str(m.Name));
			spec.IsStatic = m.IsStatic;
			spec.IsConversion = (e.Flags & CatalogEntry.cConversion) != 0;
			spec.IsCompact = (e.Flags & CatalogEntry.cCompact) != 0;
			spec.Namespace.Set(store.Str(type.Namespace));
			let typeName = store.Str(type.Name);
			let kind = store.Str(type.Kind);
			spec.OwnerType.Set(typeName);
			let gp = store.Str(type.GenericParams);
			if (!gp.IsEmpty)
				spec.OwnerType.AppendF("<{}>", gp);
			spec.ReturnType.Set(store.Str(m.Type));

			List<AttrInfo> attrs = scope .();
			defer { ClearAndDeleteItems!(attrs); }
			AttributeParser.Parse(store.Str(m.Attributes), attrs);
			let node = AttributeParser.Find(attrs, "Node");
			let expose = AttributeParser.Find(attrs, "Expose");
			let expand = (AttributeParser.Find(attrs, "ExpandEnumAsFlow") ?? AttributeParser.Find(attrs, "ExpandEnumAsExecs"));
			if (node != null)
				spec.CompactTitle.Set(node.Get("CompactTitle"));
			if (expand != null)
				spec.ExpandEnumParam.Set(expand.Get("Param", 0));

			// Call text: static members are qualified by their type (global functions are not).
			if (m.IsStatic && kind != "static")
				spec.CallName.AppendF("{}.{}", typeName, spec.MemberName);
			else
				spec.CallName.Set(spec.MemberName);

			// Tooltip: [Node(Tooltip)] / [Expose(Tooltip)], else the doc comment summary.
			StringView tip = default;
			if (node != null) tip = node.Get("Tooltip");
			if (tip.IsEmpty && expose != null) tip = expose.Get("Tooltip");
			let doc = store.Str(m.Doc);
			if (!tip.IsEmpty)
				spec.Tooltip.Set(tip);
			else
				DocComment.Summary(doc, spec.Tooltip);

			if (m.IsMethod)
			{
				List<AttrInfo> pattrs = scope .();
				defer { ClearAndDeleteItems!(pattrs); }
				for (int pi < m.ParamCount)
				{
					let p = ref store.Params[m.FirstParam + pi];
					PinSpec pin = new .();
					pin.Name.Set(store.Str(p.Name));
					// `@X` (a verbatim identifier, as UMP's SDK writes every parameter) is labelled X.
					pin.Label.Set(pin.Name.StartsWith('@') ? pin.Name.Substring(1) : pin.Name);
					pin.Type.Set(store.Str(p.Type));
					pin.Default.Set(store.Str(p.Default));
					pin.Modifier.Set(store.Str(p.Modifier));
					ClearAndDeleteItems!(pattrs);
					AttributeParser.Parse(store.Str(p.Attributes), pattrs);
					let pa = AttributeParser.Find(pattrs, "Pin");
					if (pa != null)
					{
						let n = pa.Get("Name", 0);
						if (!n.IsEmpty)
							pin.Label.Set(n);
						pin.Tooltip.Set(pa.Get("Tooltip"));
						if (pin.Default.IsEmpty)
							pin.Default.Set(pa.Get("Default"));
						pin.Advanced = pa.GetBool("Advanced");
						pin.OutRef = pa.GetBool("Out") && PinSpec.HasWord(pin.Modifier, "ref");
					}
					if (pin.Tooltip.IsEmpty)
						DocComment.Param(doc, pin.Name, pin.Tooltip);
					if (pi > 0)
						spec.ParamsText.Append(", ");
					if (!pin.Modifier.IsEmpty)
						spec.ParamsText.AppendF("{} ", pin.Modifier);
					spec.ParamsText.AppendF("{} {}", pin.Type, pin.Name);
					if (!pin.Default.IsEmpty)
						spec.ParamsText.AppendF(" = {}", pin.Default);
					spec.Pins.Add(pin);
				}
				if (spec.ExpandEnumParam == "return")
					EnumCasesOf(store, type, spec.ReturnType, spec.EnumCases);
			}

			// Menu label: display name, plus parameter types when overloaded.
			spec.Label.Set(spec.DisplayName);
			if ((e.Flags & CatalogEntry.cOverloaded) != 0 && m.IsMethod)
			{
				spec.Label.Append(" (");
				for (let pin in spec.Pins)
				{
					if (@pin.Index > 0)
						spec.Label.Append(", ");
					spec.Label.Append(pin.Type);
				}
				spec.Label.Append(")");
			}

			// Signature line under the tooltip text, as UE shows "Receiver is ...".
			String sig = scope .();
			if (m.IsMethod)
				sig.AppendF("{} {}({})", spec.ReturnType.IsEmpty ? "void" : spec.ReturnType, spec.CallName, spec.ParamsText);
			else
				sig.AppendF("{} {}", spec.ReturnType, spec.CallName);
			if (!m.IsStatic)
				sig.AppendF("\nReceiver is {}", spec.OwnerType);
			if (!spec.Tooltip.IsEmpty)
				spec.Tooltip.Append("\n\n");
			spec.Tooltip.Append(sig);
		}

		void EnumCasesOf(SymbolStore store, TypeRec owner, StringView typeText, List<String> outCases)
		{
			// Result<T> -> Ok / Err
			if (TypeRules.BaseName(typeText) == "Result")
			{
				outCases.Add(new String("Ok"));
				outCases.Add(new String("Err"));
				return;
			}
			let t = mService.FindType(typeText, null);
			if (!t.IsValid)
				return;
			for (var c in t.Store.Str(t.Rec.EnumCases).Split(';'))
				if (!c.IsEmpty)
					outCases.Add(new String(c));
		}

		// ------------------------------------------------------------------ search

		/// Fuzzy, ranked search: for every query word, prefix of the name (best) > start of a
		/// word > substring > letters in order; keywords and the type name count too. Results
		/// best first; `filter` (optional) can veto entries (return false) or not.
		/// Incremental search: the entries whose key matched the last query. A query that only
		/// adds characters to it matches a subset (every word test is monotonic), so typing the
		/// next letter scans those instead of the whole catalog.
		String mLastQuery = new .() ~ delete _;
		List<int32> mLastMatches = new .() ~ delete _;
		/// For each of mLastMatches: the sum of all its word scores, and of all but the last word.
		List<float> mLastFull = new .() ~ delete _;
		List<float> mLastPrefix = new .() ~ delete _;
		int mLastWordCount;
		bool mLastMatchesValid;
		/// How many entries the last Search scanned (for the scale test).
		public int LastScanned;

		public void ResetSearchCache() => InvalidateSearchCache();

		void InvalidateSearchCache()
		{
			mLastMatchesValid = false;
			mLastQuery.Clear();
			mLastMatches.Clear();
			mLastFull.Clear();
			mLastPrefix.Clear();
			mLastWordCount = 0;
		}

		/// `next` only adds characters to `prev` (same words so far, the last one longer or new
		/// words after a space).
		static bool Narrows(StringView prev, StringView next)
		{
			return !prev.IsEmpty && next.Length >= prev.Length && next.StartsWith(prev);
		}

		public void Search(StringView query, List<SearchHit> outHits, int maxResults, delegate bool(int32 id) filter = null, delegate float(int32 id) bonus = null)
		{
			Refresh();
			String q = scope .(query);
			q.Trim();
			q.ToLower();
			// A raw member name is searchable as written (`m_LoopStart`, `bOverride_bCast`, a C++ name with
			// underscores): its pieces match the words of the label, and the whole text matching the
			// member name scores on top.
			String rawName = scope .();
			if (q.Contains('_') && !q.Contains(' '))
			{
				rawName.Set(q);
				q.Replace('_', ' ');
				q.Trim();
			}
			List<StringView> words = scope .();
			for (let w in q.Split(' '))
				if (!w.IsEmpty)
					words.Add(w);
			uint64 qmask = CharMask(q);
			String phrase = scope .();
			for (let w in words)
				phrase.AppendF("{}{}", phrase.IsEmpty ? "" : " ", w);
			bool incremental = mLastMatchesValid && Narrows(mLastQuery, q);
			// What the last query's scores can give: the words before the last one are the same
			// (the last word grew: reuse their sum), or every last word is the same (a new word
			// was started: reuse the whole sum).
			int reuse = 0; // 0 none, 1 = prefix sum (all but the last word), 2 = full sum
			if (incremental && words.Count >= 1 && mLastWordCount >= 1)
			{
				if (words.Count == mLastWordCount && mLastWordCount > 1)
					reuse = 1;
				else if (words.Count == mLastWordCount + 1 && q.Length > mLastQuery.Length && mLastQuery.Length > 0 &&
					q[mLastQuery.Length] == ' ' && !mLastQuery.EndsWith(' '))
					reuse = 2;
				else if (words.Count == mLastWordCount + 1 && mLastQuery.EndsWith(' '))
					reuse = 2;
			}
			List<int32> candidates = incremental ? scope:: List<int32>(mLastMatches.GetEnumerator()) : null;
			List<float> prevFull = (reuse != 0) ? scope:: List<float>(mLastFull.GetEnumerator()) : null;
			List<float> prevPrefix = (reuse != 0) ? scope:: List<float>(mLastPrefix.GetEnumerator()) : null;
			mLastMatches.Clear();
			mLastFull.Clear();
			mLastPrefix.Clear();
			mLastMatchesValid = !words.IsEmpty;
			mLastWordCount = words.Count;
			mLastQuery.Set(q);
			LastScanned = 0;
			// Bounded best-N: keep a list sorted by score, cut at maxResults.
			float worst = float.MinValue;
			int candidateAt = 0;
			for (int si < Stores.Count)
			{
				let sc = Stores[si];
				let pool = sc.Pool.Ptr;
				int count = sc.Entries.Count;
				for (int ei0 < count)
				{
					int ei = ei0;
					int ci = -1;
					if (candidates != null)
					{
						// Only the entries the shorter query matched, in order.
						if (candidateAt >= candidates.Count || StoreOf(candidates[candidateAt]) != si)
							break;
						ci = candidateAt;
						ei = EntryOf(candidates[candidateAt++]);
					}
					LastScanned++;
					let e = ref sc.Entries[ei];
					if ((e.CharMask & qmask) != qmask)
						continue;
					let key = StringView(pool + e.Search.Off, e.Search.Len);
					float score = 0;
					float prefixSum = 0;
					if (!words.IsEmpty)
					{
						let display = sc.Str(e.Display);
						if (reuse == 1 && ci >= 0)
							prefixSum = prevPrefix[ci];
						else if (reuse == 2 && ci >= 0)
							prefixSum = prevFull[ci];
						else
						{
							for (int wi < words.Count - 1)
							{
								let ws = WordScore(key, display, words[wi]);
								if (ws <= 0)
								{
									prefixSum = -1;
									break;
								}
								prefixSum += ws;
							}
							if (prefixSum < 0)
								continue;
						}
						let last = WordScore(key, display, words.Back);
						if (last <= 0)
							continue;
						score = prefixSum + last;
						if (mLastMatchesValid)
						{
							mLastPrefix.Add(prefixSum);
							mLastFull.Add(score);
						}
						if (words.Count > 1)
							score += PhraseBonus(key, display, words, phrase);
						if (!rawName.IsEmpty && key.Contains(rawName))
							score += 120;
					}
					let id = MakeId(si, ei);
					if (mLastMatchesValid)
						mLastMatches.Add(id);
					if (filter != null && !filter(id))
						continue;
					if (bonus != null)
						score += bonus(id);
					// Shorter names first among equals; advanced ones last.
					score -= e.Display.Len * 0.05f;
					if ((e.Flags & CatalogEntry.cAdvanced) != 0)
						score -= 20;
					if (outHits.Count >= maxResults && score <= worst)
						continue;
					SearchHit hit = .() { Id = id, Score = score };
					// insert sorted (descending)
					int lo = 0;
					int hi = outHits.Count;
					while (lo < hi)
					{
						int mid = (lo + hi) / 2;
						if (outHits[mid].Score >= score)
							lo = mid + 1;
						else
							hi = mid;
					}
					outHits.Insert(lo, hit);
					if (outHits.Count > maxResults)
						outHits.PopBack();
					if (outHits.Count >= maxResults)
						worst = outHits.Back.Score;
				}
			}
		}

		/// Scores one lowercase key against the query words (0 = no match).
		public static float ScoreKey(StringView key, StringView display, List<StringView> words, StringView phraseIn = default)
		{
			float total = 0;
			for (let w in words)
			{
				let best = WordScore(key, display, w);
				if (best <= 0)
					return 0;
				total += best;
			}
			return total + PhraseBonus(key, display, words, phraseIn);
		}

		/// One query word against a lowercase key: name prefix 100, word start 60 (+5 inside the
		/// display name), substring 30, acronym 40, letters in order 5+; 0 = no match.
		public static float WordScore(StringView key, StringView display, StringView w)
		{
			float best = 0;
			int at = key.IndexOf(w);
			if (at == 0)
				best = 100;
			else if (at > 0)
			{
				// Look for a word-start occurrence (after a space).
				int pos = at;
				bool wordStart = false;
				while (pos >= 0)
				{
					if (pos == 0 || key[pos - 1] == ' ' || key[pos - 1] == '.' || key[pos - 1] == '_')
					{
						wordStart = true;
						break;
					}
					let next = key.Substring(pos + 1).IndexOf(w);
					if (next < 0)
						break;
					pos = pos + 1 + next;
				}
				best = wordStart ? 60 : 30;
				// Matches inside the display name (the first part of the key) beat keywords.
				if (pos < display.Length)
					best += 5;
			}
			else if (IsAcronym(key, w))
				best = 40; // "gal" -> "Get Actor Location"
			else
			{
				// Fuzzy: the letters in order.
				int ki = 0;
				int matched = 0;
				int starts = 0;
				for (let c in w.RawChars)
				{
					while (ki < key.Length && key[ki] != c)
						ki++;
					if (ki >= key.Length)
						break;
					if (ki == 0 || key[ki - 1] == ' ')
						starts++;
					matched++;
					ki++;
				}
				if (matched < w.Length)
					return 0;
				best = 5 + starts * 4;
			}
			return best;
		}

		static float PhraseBonus(StringView key, StringView display, List<StringView> words, StringView phraseIn)
		{
			float total = 0;
			// The whole query as typed ("get actor location") beats the same words reordered.
			if (words.Count > 1)
			{
				// The caller can pass the phrase once per query (Search does) instead of per entry.
				StringView phrase = phraseIn;
				if (phrase.IsEmpty)
				{
					String built = scope:: .();
					for (let w in words)
					{
						if (!built.IsEmpty)
							built.Append(' ');
						built.Append(w);
					}
					phrase = built;
				}
				let at = key.IndexOf(phrase);
				if (at == 0)
					total += 80;
				else if (at > 0 && at < display.Length && key[at - 1] == ' ')
					total += 50;
			}
			return total;
		}

		/// The letters of `w` are the first letters of later and later words of the key.
		static bool IsAcronym(StringView key, StringView w)
		{
			int wi = 0;
			for (int i < key.Length)
			{
				if (wi >= w.Length)
					break;
				bool start = i == 0 || key[i - 1] == ' ';
				if (start && key[i] == w[wi])
					wi++;
			}
			return wi >= w.Length && w.Length >= 2;
		}

		// ------------------------------------------------------------------ context

		/// Relevance of an entry to a pin (0 = can't connect, 1 = generic/unchecked,
		/// 2 = implicit conversion, 3 = exact / target type).
		public int8 ContextRelevance(int32 id, PinContext ctx, StringView pinType)
		{
			if (ctx == .None)
				return 1;
			if (mContextKind != ctx || mContextType != pinType)
			{
				mContextMemo.Clear();
				mContextKind = ctx;
				mContextType.Set(pinType);
			}
			let sc = StoreOfId(id);
			let store = sc.Store;
			let e = ref sc.Entries[EntryOf(id)];
			let m = ref store.Members[e.Member];
			bool generic = (e.Flags & CatalogEntry.cGeneric) != 0;
			int8 best = 0;
			int8 Check(StrRef typeRef, bool from, bool stripArray = false)
			{
				int64 key = ((int64)StoreOf(id) << 40) ^ ((int64)typeRef.Off << 2) ^ (from ? 1 : 0) ^ (stripArray ? 2 : 0);
				if (mContextMemo.TryGetValue(key, let r))
					return r;
				var t = store.Str(typeRef);
				if (stripArray && t.EndsWith("[]"))
					t.RemoveFromEnd(2);
				int8 rel = 0;
				Conversion c = from ? TypeRules.CanConvert(pinType, t, null, mService) : TypeRules.CanConvert(t, pinType, null, mService);
				switch (c)
				{
				case .Exact: rel = 3;
				case .Implicit:
					// Everything converts to Object: that says nothing about fit.
					rel = (t == "Object" || pinType == "Object") ? 0 : 2;
				case .Unchecked:
					rel = (TypeRules.IsGenericParam(t) || TypeRules.IsGenericParam(pinType)) ? 1 : 0;
				case .Refused: rel = 0;
				}
				mContextMemo[key] = rel;
				return rel;
			}
			if (ctx == .TakesValue)
			{
				if (!m.IsStatic && e.Kind != .Event)
				{
					// The pin can be the target: "Receiver is T".
					let ownerRef = store.Types[m.Owner].Name;
					int64 key = ((int64)StoreOf(id) << 40) ^ ((int64)ownerRef.Off << 2) ^ 3;
					int8 r;
					if (!mContextMemo.TryGetValue(key, out r))
					{
						let ownerName = store.Str(ownerRef);
						String pinCore = scope .();
						TypeRules.Normalize(pinType, pinCore);
						let pinBase = TypeRules.PrimitiveStruct(TypeRules.BaseName(pinCore));
						r = (pinBase == ownerName || (!TypeRules.IsPrimitive(pinCore) && mService.IsSubtype(pinCore, ownerName))) ? 3 : 0;
						mContextMemo[key] = r;
					}
					if (r == 3)
						return 3;
				}
				if (e.Kind == .Set)
					return Math.Max(best, Check(m.Type, true));
				if (m.IsMethod)
				{
					for (int pi < m.ParamCount)
					{
						let p = ref store.Params[m.FirstParam + pi];
						let mod = store.Str(p.Modifier);
						if (mod.Contains("out"))
							continue;
						var r = Check(p.Type, true, mod.Contains("params"));
						if (r == 1 && !generic)
							r = 0;
						best = Math.Max(best, r);
					}
				}
				return best;
			}
			// GivesValue
			if (e.Kind == .Get || (m.IsMethod && store.Str(m.Type) != "void" && !store.Str(m.Type).IsEmpty))
			{
				var r = Check(m.Type, false);
				if (r == 1 && !generic)
					r = 0;
				best = r;
			}
			return best;
		}

		// ------------------------------------------------------------------ tree

		/// The category tree over every entry (built on first use after a change).
		public CategoryNode Tree
		{
			get
			{
				Refresh();
				if (mTree == null)
				{
					mTree = new .();
					List<CategoryNode> byCat = scope .();
					for (let cat in Categories)
					{
						CategoryNode node = mTree;
						for (var part in cat.Split('|'))
						{
							part.Trim();
							if (part.IsEmpty)
								continue;
							node = node.Child(part);
						}
						byCat.Add(node);
					}
					for (int si < Stores.Count)
					{
						let sc = Stores[si];
						for (int ei < sc.Entries.Count)
						{
							let e = ref sc.Entries[ei];
							byCat[e.Category].Entries.Add(MakeId(si, ei));
						}
					}
					CountTotals(mTree);
				}
				return mTree;
			}
		}

		static int32 CountTotals(CategoryNode n)
		{
			int32 total = (int32)n.Entries.Count;
			for (let c in n.Children)
				total += CountTotals(c);
			n.Total = total;
			return total;
		}
	}
}
