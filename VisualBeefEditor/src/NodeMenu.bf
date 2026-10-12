using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	enum MenuEntryKind
	{
		CallMethod,     // A = name, B = params text, C = return type, Static/self
		CallCustom,     // A = name typed in search
		CallMember,     // A = name typed in search (with Target pin)
		CallInstance,   // A = name, B = params text, C = return type (with Target pin), OnType = target type
		GetVar,         // A = name, B = type
		SetVar,         // A = name, B = type
		LocalVar,
		Branch,
		While,
		DoWhile,
		For,
		ForEach,
		Return,
		Break,
		Continue,
		Code,
		Switch,         // A = value type (int, String, an enum), B = case labels separated by newlines
		Flow,           // A = macro name (FlowMacros), B = number of outputs (Sequence / MultiGate)
		LoopBreak,      // A = "foreach" or "for": a loop with `if (false) break;` already in its body
		Expr,           // A = expression text, B = result type (literals)
		Operator,       // A = op, Binary flag in B ("2")
		Select,
		Cast,           // A = type to cast to (empty = int)
		Index,
		GetMember,
		GetField,       // A = field name, B = field type, OnType = target type (`target.Field`)
		This,           // "Get a reference to this": `this` as a value (wire it into the Receiver)
		Base,           // "Get a reference to base": `base` (the parent's version of a function)
		// Lifetime nodes (docs/Lifetime-Nodes.md)
		Construct,      // A = type (`.` inferred, `$` for scope $"..."), B = alloc keyword, C = "array" for T[n]
		Delete,         // A = keyword (`delete`)
		Defer,
		Using,
		ResultMatch,    // A = case tested ("Ok" / "Err")
		// The last text forms (docs/Flow-Nodes.md)
		Scope,          // a nested block `{ ... }`
		Lambda,         // A = parameters (`(a, b)`), B = alloc, C = "block" for a Body (else Returns)
		Delegate,       // A = method name, B = alloc: `new => Method`
		LocalFunc,      // A = header (`void Helper()`), C = "block" or "expr"
		Format,         // A = template with empty holes (`$"x = {}"`)
		MathExpr        // A = the expression (`a + b`)
	}

	class NodeItem
	{
		public MenuEntryKind Kind;
		public String Category = new .() ~ delete _;
		public String Label = new .() ~ delete _;
		public String A = new .() ~ delete _;
		public String B = new .() ~ delete _;
		public String C = new .() ~ delete _;
		public String Tooltip = new .() ~ delete _;
		/// CallInstance / GetField: the type the target pin expects.
		public String OnType = new .() ~ delete _;
		/// Relevance to the context pin (0 = no context, 1 = loose, 2 = good, 3 = exact/target).
		public int32 Relevance;
		/// Search score this frame.
		public float Score;
		/// A copy shown in the Favorites or Recently Used group: the category it really belongs to
		/// (Category holds the group's name).
		public String OrigCategory = new .() ~ delete _;
		/// The node catalog entry this item shows (-1 = a built-in or local item).
		public int32 CatalogId = -1;
		/// Catalog entries without exec pins ([Pure], getters, [NodeLibrary] functions).
		public bool Pure;
		/// CallMethod of the type being edited: a static function (no Target pin). OnType holds
		/// the type, so the node is a member call with self otherwise.
		public bool Static;

		public void CopyFrom(NodeItem o)
		{
			Kind = o.Kind;
			Category.Set(o.Category);
			Label.Set(o.Label);
			A.Set(o.A);
			B.Set(o.B);
			C.Set(o.C);
			Tooltip.Set(o.Tooltip);
			OnType.Set(o.OnType);
			OrigCategory.Set(o.OrigCategory);
			Relevance = o.Relevance;
			CatalogId = o.CatalogId;
			Pure = o.Pure;
			Static = o.Static;
		}

		/// Does a node made from this item have exec pins?
		public bool IsStatement
		{
			get
			{
				if (Pure)
					return false;
				switch (Kind)
				{
				case .CallMethod, .CallCustom, .CallMember, .CallInstance, .SetVar, .LocalVar, .Branch, .While, .DoWhile,
					 .For, .ForEach, .Return, .Break, .Continue, .Code, .Switch, .Flow, .LoopBreak, .Delete, .Defer, .Using, .ResultMatch,
					 .Scope, .LocalFunc:
					return true;
				default:
					return false;
				}
			}
		}

		public bool IsCall => Kind == .CallMethod || Kind == .CallCustom || Kind == .CallMember || Kind == .CallInstance;

		/// Key for favorites, node hotkeys and recents ("Category\tLabel", the real category for a
		/// copy in the Favorites or Recently Used group).
		public void GetKey(String outKey) => outKey.AppendF("{}\t{}", OrigCategory.IsEmpty ? Category : OrigCategory, Label);
	}

	/// Where the action menu was opened from (UE's "context sensitive" filtering).
	enum NodeMenuContext
	{
		None,
		/// Dragged from an exec output (or input): statements only.
		Exec,
		/// Dragged from a data output: actions that take a value of the pin's type.
		DataOut,
		/// Dragged from a data input: actions that produce a value of the pin's type.
		DataIn
	}

	/// Favorites, node hotkeys and recently used nodes. Favorites and hotkeys are global settings in
	/// settings.json (`editor.favorites`, `editor.nodeHotkeys`; docs/Editor-UI.md, "Node hotkeys and
	/// favorites"), seeded with the default keys on first run. Recents stay in
	/// %LOCALAPPDATA%\VisualBeef\node_menu.txt (an old action_menu.txt is renamed once); the favorite
	/// lines that file used to hold move to settings.json once.
	class NodeMenuPrefs
	{
		public NodeHotkeys Hotkeys = new .() ~ delete _;
		public List<String> Favorites => Hotkeys.Favorites;
		public List<String> Recents = new .() ~ DeleteContainerAndItems!(_);
		bool mLoaded;

		static void FilePath(String outPath)
		{
			LibraryIndex.CacheDir(outPath); // ...\VisualBeef\index
			int slash = outPath.LastIndexOf('\\');
			if (slash > 0)
				outPath.RemoveToEnd(slash);
			outPath.AppendF("{}node_menu.txt", System.IO.Path.DirectorySeparatorChar);
		}

		public void Load()
		{
			if (mLoaded)
				return;
			mLoaded = true;
			String path = scope .();
			FilePath(path);
			if (!File.Exists(path))
			{
				// One-time migration from the file's old name; the favourites are kept.
				String old = scope .(path);
				old.RemoveFromEnd("node_menu.txt".Length);
				old.Append("action_menu.txt");
				if (File.Exists(old))
					File.Move(old, path).IgnoreError();
			}
			List<String> oldFavorites = scope .();
			defer { ClearAndDeleteItems!(oldFavorites); }
			String text = scope .();
			if (File.ReadAllText(path, text) case .Ok)
			{
				for (var line in text.Split('\n'))
				{
					line.TrimEnd();
					if (line.StartsWith("fav\t"))
						oldFavorites.Add(new String(line.Substring(4)));
					else if (line.StartsWith("recent\t"))
						Recents.Add(new String(line.Substring(7)));
				}
			}
			LoadSettings(oldFavorites);
		}

		/// Favorites and hotkeys from settings.json; on first run the defaults (plus the favorites of
		/// the old node_menu.txt), written back at once.
		void LoadSettings(List<String> oldFavorites)
		{
			Settings.Load();
			let editor = Settings.Root.Get("editor");
			let keys = (editor != null) ? editor.Get("nodeHotkeys") : null;
			if (keys == null || keys.Type != .Object)
			{
				Hotkeys.ResetToDefaults();
				for (let f in oldFavorites)
					Hotkeys.AddFavorite(f);
				SaveSettings();
				if (!oldFavorites.IsEmpty)
					Save(); // node_menu.txt keeps only the recents
				return;
			}
			Hotkeys.Clear();
			let favs = editor.Get("favorites");
			if (favs != null && favs.Type == .Array)
				for (let f in favs.Items)
					if (f.Type == .String)
						Hotkeys.AddFavorite(f.Str);
			for (int i < keys.Keys.Count)
			{
				let letter = keys.Keys[i];
				let node = keys.Items[i];
				if (node.Type != .String)
					continue;
				String owner = scope .();
				let r = (letter.Length == 1) ? Hotkeys.Assign(letter[0], node.Str, owner) : NodeHotkeys.AssignResult.Invalid;
				if (r != .Ok)
				{
					String why = scope .();
					NodeHotkeys.Describe(r, (letter.Length == 1) ? letter[0] : '?', owner, why);
					Notify.Log(.Warning, "Editor", scope $"settings.json: node hotkey '{letter}' for {NodeHotkeys.LabelOf(node.Str)} ignored: {why}");
				}
			}
		}

		/// Writes `editor.favorites` and `editor.nodeHotkeys` to settings.json.
		public void SaveSettings()
		{
			Settings.Load();
			let editor = Settings.Root.Obj("editor");
			let favs = Json.NewArray();
			for (let f in Hotkeys.Favorites)
				favs.Items.Add(Json.NewString(f));
			editor.Set("favorites", favs);
			let keys = Json.NewObject();
			List<(char8 key, StringView nodeKey)> bindings = scope .();
			Hotkeys.GetBindings(bindings);
			for (let b in bindings)
				keys.Set(scope String()..Append(b.key), Json.NewString(b.nodeKey));
			editor.Set("nodeHotkeys", keys);
			Settings.Save();
		}

		public void Save()
		{
			String path = scope .();
			FilePath(path);
			String dir = scope .();
			Path.GetDirectoryPath(path, dir).IgnoreError();
			if (!Directory.Exists(dir))
				Directory.CreateDirectory(dir).IgnoreError();
			String text = scope .();
			for (let r in Recents)
				text.AppendF("recent\t{}\n", r);
			File.WriteAllText(path, text).IgnoreError();
		}

		public bool IsFavorite(StringView key) => Hotkeys.IsFavorite(key);

		/// Adds or removes a favorite (removing one also removes its hotkey). True when it is a
		/// favorite afterwards.
		public bool ToggleFavorite(StringView key)
		{
			let now = Hotkeys.ToggleFavorite(key);
			SaveSettings();
			return now;
		}

		/// Gives a node a hotkey (it becomes a favorite). Refusals (a reserved letter, a letter another
		/// node has) leave everything as it was; `outMessage` says what happened either way.
		public bool AssignHotkey(StringView key, char8 letter, String outMessage)
		{
			String owner = scope .();
			let r = Hotkeys.Assign(letter, key, owner);
			if (r != .Ok)
			{
				NodeHotkeys.Describe(r, letter, owner, outMessage);
				return false;
			}
			SaveSettings();
			outMessage.AppendF("{} is now the hotkey of {}.", letter.ToUpper, NodeHotkeys.LabelOf(key));
			return true;
		}

		/// Removes a node's hotkey (the favorite stays).
		public bool ClearHotkey(StringView key)
		{
			if (!Hotkeys.ClearNode(key))
				return false;
			SaveSettings();
			return true;
		}

		/// The default favorites and keys (Editor Preferences > Node Hotkeys > Reset).
		public void ResetHotkeys()
		{
			Hotkeys.ResetToDefaults();
			SaveSettings();
		}

		public void Used(StringView key)
		{
			for (let r in Recents)
				if (r == key)
				{
					Recents.Remove(r);
					delete r;
					break;
				}
			Recents.Insert(0, new String(key));
			while (Recents.Count > 12)
				delete Recents.PopBack();
			Save();
		}
	}

	/// Blueprint-style "All nodes for this Sheet" menu: search, collapsible categories,
	/// keyboard navigation and context-sensitive filtering when opened by dragging off a pin.
	///
	/// Two sources: the local items built when the menu opens (flow control, operators, this
	/// type's variables and functions, parameters, locals, literals) and the NodeCatalog (every
	/// project and library member offered as a node, see docs/Catalog-and-Types.md). Filtering
	/// runs only when the search text or the context changes, never per frame; catalog entries
	/// become NodeItems only when they are shown.
	class NodeMenu
	{
		EditorApp mApp;
		/// Resolver + catalog shared with GraphBuilder and the wire checks.
		public TypeService Types ~ delete _;
		public NodeMenuPrefs Prefs = new .() ~ delete _;
		public List<NodeItem> Items = new .() ~ DeleteContainerAndItems!(_);
		TextBuffer mSearch = new .(256) ~ delete _;
		String mLastSearch = new .() ~ delete _;
		/// The search text changed and the list has not been filtered for it yet (debounce).
		bool mSearchPending;
		double mSearchChangedAt;
		const double cSearchDebounce = 0.080;
		/// The menu waits for a debounced search: the idle loop must wake soon.
		public bool SearchPending => mSearchPending;
		public ImVec2 SpawnPos;
		/// The sheet's graph the menu was opened for, and whether the popup is up: the canvas draws the
		/// pending wire (source pin to SpawnPos) while a pin-opened menu is showing.
		public Object ContextGraph;
		bool mShown;
		public bool PinMenuActive => ContextPinId != 0 && ContextGraph != null && (OpenRequested || mShown);
		public int32 ContextPinId;
		/// Self-test captures: the popup opens here (screen pixels) instead of at the mouse.
		public ImVec2 SelfTestPos;
		public bool OpenRequested;
		/// Closes the popup on its next draw (self-test captures: a posted Escape does not reach SDL).
		public bool CloseRequested;
		bool mFocusSearch;
		/// UE's "Context Sensitive" checkbox.
		public bool ContextSensitive = true;
		NodeMenuContext mContext;
		String mContextType = new .() ~ delete _;
		String mContextLabel = new .() ~ delete _;
		/// Return type of the function being edited (for Return).
		String mReturnType = new .() ~ delete _;
		/// The owner type of the graph (its own members are local items, not catalog ones).
		String mOwnerName = new .() ~ delete _;
		/// The menu was opened from a call's Target pin (Self is the first suggestion).
		bool mContextIsTarget;

		/// Keyboard highlight: an item of `Items` or one of the free-form entries (by label).
		NodeItem mHighlight;
		String mHighlightLabel = new .() ~ delete _;
		bool mScrollToHighlight;
		/// Force categories open/closed for one frame (after the search text changed).
		int mForceOpen = 1;
		/// Items in the order they were drawn last frame (for up/down).
		List<NodeItem> mNavOrder = new .() ~ delete _;

		/// Catalog entries turned into items, by catalog id (cleared when the catalog changes).
		Dictionary<int32, NodeItem> mCatalogItems = new .() ~ DeleteDictionaryAndValues!(_);
		int32 mCatalogGeneration = -1;
		/// The current filter result: categories in display order with their items.
		List<String> mGroupOrder = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, List<NodeItem>> mGroups = new .() ~ DeleteDictionaryAndValues!(_);
		int mVisibleCount;
		/// Catalog results are capped while searching (the best ones are kept).
		const int cMaxCatalogHits = 300;
		/// Context-sensitive catalog matches, computed once per open.
		List<int32> mContextIds = new .() ~ delete _;
		bool mContextIdsValid;
		bool mDirty = true;
		bool mHighlightCustom;
		/// Free-form entries rebuilt when the search text changes.
		NodeItem mCustom ~ delete _;
		NodeItem mCustomMember ~ delete _;
		NodeItem mCustomExpr ~ delete _;
		/// Dragged off an enum-typed output: `Switch on <EnumName>`, the first row.
		NodeItem mSwitchOn ~ delete _;

		public this(EditorApp app)
		{
			mApp = app;
			Types = new TypeService(app.Index);
			// Libraries come from the editor's background indexer (EditorApp.PollIndexing), never
			// from a synchronous load on the UI thread.
			Types.AutoLoadLibraries = false;
			Types.Install();
		}

		public NodeCatalog Catalog => Types.Catalog;

		NodeItem Add(MenuEntryKind kind, StringView category, StringView label, StringView a = "", StringView b = "", StringView c = "")
		{
			NodeItem item = new .();
			item.Kind = kind;
			item.Category.Set(category);
			item.Label.Set(label);
			item.A.Set(a);
			item.B.Set(b);
			item.C.Set(c);
			Items.Add(item);
			return item;
		}

		/// Switch and the Blueprint flow macros (see docs/Flow-Nodes.md).
		void AddFlowItems(MethodGraph mg)
		{
			Add(.Switch, "Flow Control", "Switch", "int", "0\n1").Tooltip.Set("switch (value) { case 0: ... default: ... } - change what it switches on (a number, a character, text or an enum) in Properties");
			Add(.Flow, "Flow Control", "Sequence", FlowMacros.Sequence, "2").Tooltip.Set("Runs each Then block in order (written as consecutive { } blocks under // vb:sequence)");
			Add(.Flow, "Flow Control", "Do Once", FlowMacros.DoOnce).Tooltip.Set("if (!__doOnce_N) { __doOnce_N = true; ... }");
			Add(.Flow, "Flow Control", "Do Once  (Reset)", FlowMacros.DoOnceReset).Tooltip.Set("__doOnce_N = false;");
			Add(.Flow, "Flow Control", "Do N", FlowMacros.DoN).Tooltip.Set("if (__doN_N < n) { __doN_N++; ... }");
			Add(.Flow, "Flow Control", "Do N  (Reset)", FlowMacros.DoNReset).Tooltip.Set("__doN_N = 0;");
			Add(.Flow, "Flow Control", "Flip Flop", FlowMacros.FlipFlop).Tooltip.Set("Alternates between A and B: if (!__flipFlop_N) { ... = true; A } else { ... = false; B }");
			Add(.Flow, "Flow Control", "Gate", FlowMacros.Gate).Tooltip.Set("if (!__gateClosed_N) { ... }  (open / close / toggle it with the Gate nodes)");
			Add(.Flow, "Flow Control", "Gate  (Open)", FlowMacros.GateOpen).Tooltip.Set("Opens a Gate");
			Add(.Flow, "Flow Control", "Gate  (Close)", FlowMacros.GateClose).Tooltip.Set("Closes a Gate");
			Add(.Flow, "Flow Control", "Gate  (Toggle)", FlowMacros.GateToggle).Tooltip.Set("Toggles a Gate: __gate = !__gate;");
			Add(.Flow, "Flow Control", "Multi Gate", FlowMacros.MultiGate, "3").Tooltip.Set("Runs the next output each time: if (state == 0) { ... } else if (state == 1) { ... }");
			Add(.Flow, "Flow Control", "Multi Gate  (Reset)", FlowMacros.MultiGateReset).Tooltip.Set("__multiGate_N = 0;");
			Add(.LoopBreak, "Flow Control", "For Each Loop with Break", "foreach").Tooltip.Set("for (let item in Collection) { if (Condition) break; ... }");
			Add(.LoopBreak, "Flow Control", "For Loop with Break", "for").Tooltip.Set("for (int i = 0; i < 10; i++) { if (Condition) break; ... }");
		}

		/// "Construct <Type>  (new)" for the classes and structs of the project's other files that
		/// this file can name as written: the same namespace (or an enclosing one), a namespace
		/// the file has a `using` for, or no namespace. Static, abstract, generic and nested types
		/// are left out (Beef cannot make them with a plain `new T()`).
		void AddProjectConstructs(MethodGraph mg, HashSet<String> offered)
		{
			let project = Types?.Project;
			if (project == null)
				return;
			IndexedFile here = null;
			for (let f in project.Files)
				if (ProjectIndex.SamePath(f.Path, mg.Doc.FilePath))
					here = f;
			List<String> visible = scope .();
			defer { ClearAndDeleteItems!(visible); }
			visible.Add(new String(""));
			if (here != null)
			{
				for (let t in here.Types)
				{
					// `namespace A.B` sees A.B and A.
					var ns = StringView(t.Namespace);
					while (!ns.IsEmpty)
					{
						if (!visible.ContainsAlt(ns))
							visible.Add(new String(ns));
						int dot = ns.LastIndexOf('.');
						ns = (dot > 0) ? StringView(ns, 0, dot) : "";
					}
				}
				for (let u in here.Usings)
					if (!u.StartsWith("static ") && !visible.ContainsAlt(u))
						visible.Add(new String(u));
			}
			for (let f in project.Files)
			{
				if (ProjectIndex.SamePath(f.Path, mg.Doc.FilePath))
					continue;
				for (let t in f.Types)
				{
					if ((t.Kind != "class" && t.Kind != "struct") || t.IsAbstract || t.IsStaticType || !t.Outer.IsEmpty || !t.GenericParams.IsEmpty)
						continue;
					if (t.Visibility == .Private || !visible.ContainsAlt(t.Namespace))
						continue;
					if (mContext == .DataIn && !IsWild(mContextType) && t.Name == mContextType)
						continue;
					if (offered.ContainsAlt(t.Name))
						continue;
					offered.Add(new String(t.Name));
					Add(.Construct, "Lifetime", scope $"Construct {t.Name}  (new)", t.Name, "new").Tooltip.AppendF("new {}() - you delete it (Delete, or Defer -> Delete)", t.Name);
				}
			}
		}

		/// Construct / Delete / Defer / Using / Result (docs/Lifetime-Nodes.md).
		void AddLifetimeItems(MethodGraph mg)
		{
			// "Construct <Type>" for the type a data input wants, and for this file's classes.
			if (mContext == .DataIn && !IsWild(mContextType) && !TypeRules.IsPrimitive(mContextType))
			{
				String t = scope .();
				NormalizeType(mContextType, t);
				Add(.Construct, "Lifetime", scope $"Construct {t}  (scope)", t, "scope").Tooltip.AppendF("scope {}() - freed when the block ends", t);
				Add(.Construct, "Lifetime", scope $"Construct {t}  (new)", t, "new").Tooltip.AppendF("new {}() - you delete it (Delete, or Defer -> Delete)", t);
			}
			HashSet<String> offered = scope .();
			defer { for (let s in offered) delete s; }
			if (mg != null && mg.Doc != null && mg.Doc.Unit != null)
			{
				List<Member> types = scope .();
				mg.Doc.Unit.CollectTypes(types);
				for (let t in types)
				{
					if (t.TypeKind != "class" && t.TypeKind != "struct")
						continue;
					if (t.IsStatic || ProjectIndex.HasWord(t.Modifiers, "static") || ProjectIndex.HasWord(t.Modifiers, "abstract"))
						continue;
					if (mContext == .DataIn && !IsWild(mContextType) && t.Name == mContextType)
						continue;
					if (offered.ContainsAlt(t.Name))
						continue;
					offered.Add(new String(t.Name));
					Add(.Construct, "Lifetime", scope $"Construct {t.Name}  (new)", t.Name, "new").Tooltip.AppendF("new {}() - you delete it (Delete, or Defer -> Delete)", t.Name);
				}
				AddProjectConstructs(mg, offered);
			}
			Add(.Construct, "Lifetime", "Construct  (scope .())", ".", "scope").Tooltip.Set("scope .() - the type comes from where the value goes; set it in Properties. Freed when the block ends.");
			Add(.Construct, "Lifetime", "Construct  (new .())", ".", "new").Tooltip.Set("new .() - the type comes from where the value goes; set it in Properties. You delete it.");
			Add(.Construct, "Lifetime", "Construct String  (scope $\"...\")", "$", "scope").Tooltip.Set("scope $\"text {value}\" - a String made from an interpolated string, freed when the block ends");
			Add(.Construct, "Lifetime", "Construct Array  (new T[n])", "int", "new", "array").Tooltip.Set("new int[n] - an array of Count elements; set the element type in Properties");
			Add(.Delete, "Lifetime", "Delete", "delete").Tooltip.Set("delete obj; - frees an object made with new");
			Add(.Defer, "Lifetime", "Defer").Tooltip.Set("defer { Deferred } - runs Deferred when the block ends (the last Defer runs first)");
			Add(.Using, "Lifetime", "Using").Tooltip.Set("using (Value) { Body } - disposes Value when Body ends (the lock idiom: using (lock.Enter()))");
			Add(.ResultMatch, "Lifetime", "Result: match", "Ok").Tooltip.Set("if (Result case .Ok(let value)) { Ok } else { Err } - Value is set in the Ok arm");
			Add(.ResultMatch, "Lifetime", "Result: match Err", "Err").Tooltip.Set("if (Result case .Err) { Err } else { Ok }");
		}

		// ------------------------------------------------------------------ types

		/// Strips nullable markers, ref/out modifiers and whitespace.
		public static void NormalizeType(StringView type, String outType)
		{
			var t = type;
			t.Trim();
			for (let mod in StringView[?]("ref ", "out ", "in ", "params ", "mut "))
			{
				if (t.StartsWith(mod))
				{
					t = t.Substring(mod.Length);
					t.Trim();
				}
			}
			if (t.EndsWith('?'))
				t.RemoveFromEnd(1);
			outType.Append(t);
		}

		public static bool IsWild(StringView t) => t.IsEmpty || t == "var" || t == "let" || t == "Object" || t == "Variant" ||
			TypeRules.IsGenericParam(t);

		static bool IsIntType(StringView t) => TypeRules.IsInt(t) || TypeRules.IsChar(t);

		public static bool IsNumeric(StringView t) => TypeRules.IsNumeric(t) || TypeRules.IsChar(t);

		static bool IsStringType(StringView t) => TypeRules.IsStringLike(t);

		public static bool IsCollection(StringView t)
		{
			if (t.EndsWith("[]") || t.EndsWith("]"))
				return true;
			for (let prefix in StringView[?]("List<", "Dictionary<", "HashSet<", "Span<", "Queue<", "IEnumerable<", "SizedArray<", "Array", "TArray<"))
				if (t.StartsWith(prefix))
					return true;
			return t == "String" || t == "StringView";
		}

		/// The type name without generic arguments ("List<int>" -> "List").
		public static StringView BaseTypeName(StringView t)
		{
			int lt = t.IndexOf('<');
			var s = (lt > 0) ? t.Substring(0, lt) : t;
			int dot = s.LastIndexOf('.');
			if (dot >= 0)
				s = s.Substring(dot + 1);
			return s;
		}

		/// 2 = same type, 1 = compatible (wildcards, implicit conversions), 0 = no.
		public static int32 TypeMatch(StringView provided, StringView wanted)
		{
			String a = scope .();
			String b = scope .();
			NormalizeType(provided, a);
			NormalizeType(wanted, b);
			if (a == b && !IsWild(a))
				return 2;
			if (IsWild(a) || IsWild(b))
				return 1;
			switch (TypeRules.CanConvert(a, b))
			{
			case .Exact: return 2;
			case .Implicit, .Unchecked: return 1;
			case .Refused: return 0;
			}
		}

		/// Types of a parameter list ("int a, List<int> b = null" -> ["int", "List<int>"]).
		public static void ParamTypes(StringView paramsText, List<String> outTypes)
		{
			int depth = 0;
			int segStart = 0;
			for (int i = 0; i <= paramsText.Length; i++)
			{
				bool end = i == paramsText.Length;
				char8 c = end ? ',' : paramsText[i];
				if (c == '<' || c == '(' || c == '[')
					depth++;
				else if (c == '>' || c == ')' || c == ']')
					depth--;
				else if (c == ',' && depth == 0)
				{
					var part = paramsText.Substring(segStart, i - segStart);
					segStart = i + 1;
					int eq = part.IndexOf('=');
					if (eq > 0)
						part = part.Substring(0, eq);
					part.Trim();
					if (part.IsEmpty)
						continue;
					int space = part.LastIndexOf(' ');
					String t = new .();
					NormalizeType((space > 0) ? part.Substring(0, space) : "", t);
					outTypes.Add(t);
				}
			}
		}

		// ------------------------------------------------------------------ build

		/// Rebuilds the local action list from the current document context (once per open).
		public void Build(MethodGraph mg)
		{
			ClearAndDeleteItems!(Items);
			Catalog.Refresh();
			bool haveCorlib = !Types.Libraries.IsEmpty;

			if (mContext == .DataIn)
				AddLiterals();
			if (mContext == .DataOut && !IsWild(mContextType) && !haveCorlib)
				AddBuiltinMembersOf(mContextType);

			// Functions of the current type (private ones included, as in UE)
			if (mg != null && mg.Owner != null && mg.Owner.Members != null)
			{
				for (let m in mg.Owner.Members)
				{
					if (m.Kind != .Method || m.IsCtor || m.IsDtor)
						continue;
					String paramsText = scope .();
					for (let p in m.Params)
					{
						if (@p.Index > 0)
							paramsText.Append(", ");
						if (!p.Modifier.IsEmpty)
							paramsText.AppendF("{} ", p.Modifier);
						paramsText.AppendF("{} {}", p.Type, p.Name);
						if (p.Default != null)
							paramsText.AppendF(" = {}", p.Default);
					}
					let item = Add(.CallMethod, scope $"Functions | {mg.Owner.Name}", scope $"{m.Name}({paramsText})", m.Name, paramsText, m.TypeText);
					// The type's own functions: static ones have no Target, member ones call self.
					item.OnType.Set(mg.Owner.Name);
					item.Static = m.IsStatic || ProjectIndex.HasWord(m.Modifiers, "static") || mg.Owner.IsStatic || ProjectIndex.HasWord(mg.Owner.Modifiers, "static");
					item.Tooltip.AppendF("{} {}({})\nReceiver is {} ({})", m.TypeText, m.Name, paramsText, mg.Owner.Name, item.Static ? "static" : "this");
				}
				// A pin that takes a function (`function uint64(uint64)`, a hook's callback): the
				// type's static functions with that exact shape, written `=> Name` (no typing).
				if (mContext == .DataIn && mContextType.StartsWith("function "))
				{
					for (let m in mg.Owner.Members)
					{
						if (m.Kind != .Method || m.IsCtor || m.IsDtor || !(m.IsStatic || ProjectIndex.HasWord(m.Modifiers, "static")))
							continue;
						String shape = scope .();
						shape.AppendF("function {}(", m.TypeText);
						for (let p in m.Params)
						{
							if (@p.Index > 0)
								shape.Append(", ");
							if (!p.Modifier.IsEmpty)
								shape.AppendF("{} ", p.Modifier);
							shape.Append(p.Type);
						}
						shape.Append(')');
						if (!SameFunctionShape(shape, mContextType))
							continue;
						let item = Add(.Delegate, scope $"Functions | {mg.Owner.Name}", scope $"{m.Name}  (as the function: => {m.Name})", m.Name, "", "fits");
						item.Tooltip.AppendF("=> {} - passes the function {} itself ({}); it runs when the function it is given to calls it back", m.Name, m.Name, shape);
					}
				}
				for (let m in mg.Owner.Members)
				{
					if (m.Kind != .Field && m.Kind != .Property)
						continue;
					Add(.GetVar, "Variables", scope $"Get {m.Name}", m.Name, m.TypeText).Tooltip.AppendF("{} {}", m.TypeText, m.Name);
					Add(.SetVar, "Variables", scope $"Set {m.Name}", m.Name, m.TypeText).Tooltip.AppendF("{} = value  ({})", m.Name, m.TypeText);
				}
			}
			// Parameters and locals of this method
			if (mg != null)
			{
				for (let p in mg.Method.Params)
				{
					Add(.GetVar, "Variables | Parameters", scope $"Get {p.Name}", p.Name, p.Type).Tooltip.AppendF("{} {}  (parameter)", p.Type, p.Name);
					Add(.SetVar, "Variables | Parameters", scope $"Set {p.Name}", p.Name, p.Type).Tooltip.AppendF("{} = value  ({})", p.Name, p.Type);
				}
				// The function's Locals (Properties > Locals), like member variables.
				for (let n in mg.Graph.Locals)
				{
					Add(.GetVar, "Variables | Locals", scope $"Get {n.Text}", n.Text, n.Text2).Tooltip.AppendF("{} {}  (Local of {})", n.Text2, n.Text, mg.Method.Name);
					Add(.SetVar, "Variables | Locals", scope $"Set {n.Text}", n.Text, n.Text2).Tooltip.AppendF("{} = value  ({})", n.Text, n.Text2);
				}
				for (let n in mg.Graph.Nodes)
				{
					if (n.Kind == .LocalVar)
					{
						String t = scope .(n.Text2);
						if ((t == "let" || t == "var") && n.FindOutput("variable") != null && !n.FindOutput("variable").TypeName.IsEmpty)
							t.Set(n.FindOutput("variable").TypeName);
						Add(.GetVar, "Variables | Local Variables", scope $"Get {n.Text}", n.Text, t).Tooltip.AppendF("{} {}  (local)", t, n.Text);
						Add(.SetVar, "Variables | Local Variables", scope $"Set {n.Text}", n.Text, t).Tooltip.AppendF("{} = value  ({})", n.Text, t);
					}
					else if (n.Kind == .ForEach)
					{
						String t = scope .(n.Text2);
						let el = n.FindOutput("element");
						if ((t == "let" || t == "var") && el != null && !el.TypeName.IsEmpty)
							t.Set(el.TypeName);
						Add(.GetVar, "Variables | Local Variables", scope $"Get {n.Text}", n.Text, t).Tooltip.AppendF("{} {}  (loop element)", t, n.Text);
					}
					else if (n.IsCountingLoop)
					{
						let t = n.FindOutput("counter").TypeName;
						Add(.GetVar, "Variables | Local Variables", scope $"Get {n.Text}", n.Text, t).Tooltip.AppendF("{} {}  (loop counter)", t, n.Text);
					}
				}
			}

			// UE's "Get a reference to this" (only where there is a self).
			if (mg != null && mg.Owner != null && !mg.Graph.StaticContext)
			{
				Add(.This, "Variables", "Get a reference to this").Tooltip.AppendF("this ({})\nWire it into the Receiver to call a function on this object.", mg.Owner.Name);
				String parent = scope .();
				ClassModel.BaseClassOf(mg.Doc.Unit, mg.Owner, parent);
				if (!parent.IsEmpty)
					Add(.Base, "Variables", "Get a reference to base").Tooltip.AppendF("base ({})\nWire it into the Receiver to call the base version of a function (base.Foo()).", parent);
			}
			AddInheritedItems(mg);

			Add(.Branch, "Flow Control", "Branch").Tooltip.Set("if (Condition) { True } else { False }");
			Add(.ForEach, "Flow Control", "For Each Loop").Tooltip.Set("for (let item in Collection) { Loop Body }");
			Add(.For, "Flow Control", "For Loop").Tooltip.Set("for (int i = 0; i < count; i++) { Loop Body }: the counter i is an output pin");
			Add(.While, "Flow Control", "While Loop").Tooltip.Set("while (Condition) { Loop Body }");
			Add(.DoWhile, "Flow Control", "Do While Loop").Tooltip.Set("repeat { Loop Body } while (Condition);");
			AddFlowItems(mg);
			Add(.Scope, "Flow Control", "Scope Block  ({ ... })").Tooltip.Set("{ Body } - a nested block: its locals and scope allocations end with it");
			Add(.Return, "Flow Control", "Return").Tooltip.AppendF("return{};", mReturnType.IsEmpty || mReturnType == "void" ? "" : " value");
			Add(.Break, "Flow Control", "Break").Tooltip.Set("break;");
			Add(.Continue, "Flow Control", "Continue").Tooltip.Set("continue;");


			// Everyday calls (the Beef equivalents of Blueprint's Print String etc.). With corlib
			// indexed the Math functions come from the catalog with their real overloads.
			// Print takes any value (text, a number, an object): WriteLine(Object), so a wired int
			// is accepted the way Beef accepts it. A typed text literal reads back as WriteLine(StringView).
			Add(.CallMethod, "Utilities | Print", "Print  (Console.WriteLine)", "Console.WriteLine", "Object obj", "void").Tooltip.Set("void Console.WriteLine(Object obj) - prints any value (text, a number, an object) and a new line");
			Add(.CallMethod, "Utilities | Print", "Console.Write", "Console.Write", "Object obj", "void").Tooltip.Set("void Console.Write(Object obj) - prints any value (text, a number, an object)");
			if (!haveCorlib)
			{
				Add(.CallMethod, "Math", "Min", "Math.Min", "var a, var b", "var").Tooltip.Set("T Math.Min(T a, T b)");
				Add(.CallMethod, "Math", "Max", "Math.Max", "var a, var b", "var").Tooltip.Set("T Math.Max(T a, T b)");
				Add(.CallMethod, "Math", "Clamp", "Math.Clamp", "var value, var min, var max", "var").Tooltip.Set("T Math.Clamp(T value, T min, T max)");
				Add(.CallMethod, "Math", "Abs", "Math.Abs", "var value", "var").Tooltip.Set("T Math.Abs(T value)");
				Add(.CallMethod, "Math", "Sqrt", "Math.Sqrt", "double value", "double").Tooltip.Set("double Math.Sqrt(double value)");
				Add(.CallMethod, "Math", "Lerp", "Math.Lerp", "float a, float b, float t", "float").Tooltip.Set("float Math.Lerp(float a, float b, float t)");
				Add(.CallMethod, "Utilities | Debug", "Assert", "Runtime.Assert", "bool condition", "void").Tooltip.Set("void Runtime.Assert(bool condition)");
			}
			AddLifetimeItems(mg);
			Add(.Lambda, "Functions | Lambda", "Lambda  (scope (args) => expr)", "()", "scope", "expr").Tooltip.Set("scope (a, b) => a + b - a function value; set the parameters in Properties. Freed when the block ends.");
			Add(.Lambda, "Functions | Lambda", "Lambda with a body  (scope [&] (args) => { ... })", "()", "scope", "block").Tooltip.Set("scope [&] (x) => { Body } - captures the locals it reads by reference");
			Add(.Lambda, "Functions | Lambda", "Lambda  (new (args) => ...)", "()", "new", "block").Tooltip.Set("new (x) => { Body } - for a delegate that outlives the block (an event, a thread); you delete it");
			Add(.Delegate, "Functions | Lambda", "Create Delegate  (new => Method)", "Method", "new").Tooltip.Set("new => Method - a delegate bound to a function; wire it into an event's Add or +=");
			Add(.LocalFunc, "Functions", "Local Function  (void Helper() { ... })", "void Helper()", "", "block").Tooltip.Set("A function declared inside this one; call it by name after it");
			Add(.Format, "Utilities | String", "Format Text  ($\"... {value} ...\")", "$\"value = {}\"").Tooltip.Set("$\"text {value}\" - an interpolated string; every {hole} is an input. Set the text in Properties.");
			Add(.Code, "Code", "Code (raw Beef statement)").Tooltip.Set("Any Beef statement(s), kept verbatim");
			Add(.Expr, "Code", "Expression (raw Beef expression)").Tooltip.Set("Any Beef expression, kept verbatim");
			Add(.GetMember, "Utilities", "Get Member (Receiver.Name)").Tooltip.Set("Receiver.Member");
			Add(.Index, "Utilities | Array", "Get [ ] (Index)").Tooltip.Set("Receiver[Index]");
			Add(.Select, "Utilities | Flow", "Select (a ? b : c)").Tooltip.Set("Condition ? True : False");
			if (mContext == .DataIn && !IsWild(mContextType))
				Add(.Cast, "Utilities | Casting", scope $"Cast To {mContextType}", mContextType).Tooltip.AppendF("({})value", mContextType);
			else
				Add(.Cast, "Utilities | Casting", "Cast To...").Tooltip.Set("(Type)value");

			StringView[?] binaryOps = .("+", "-", "*", "/", "%", "==", "!=", "<", ">", "<=", ">=", "&&", "||", "&", "|", "^", "<<", ">>", "??");
			StringView[?] binaryNames = .("Add", "Subtract", "Multiply", "Divide", "Modulo", "Equal", "Not Equal", "Less", "Greater",
				"Less Or Equal", "Greater Or Equal", "AND (boolean)", "OR (boolean)", "Bitwise AND", "Bitwise OR", "Bitwise XOR",
				"Shift Left", "Shift Right", "Null Coalesce");
			for (int i < binaryOps.Count)
				Add(.Operator, "Math | Operators", scope $"{binaryOps[i]}  {binaryNames[i]}", binaryOps[i], "2").Tooltip.AppendF("A {} B", binaryOps[i]);
			Add(.MathExpr, "Math | Operators", "Math Expression  (a * b + c)", "a + b").Tooltip.Set("Type an expression on the node: every name in it becomes an input, the value is its Result. The Beef it writes is the expression itself.");
			Add(.Operator, "Math | Operators", "!  NOT (boolean)", "!", "1").Tooltip.Set("!A");
			Add(.Operator, "Math | Operators", "-  Negate", "-", "1").Tooltip.Set("-A");
			Add(.Operator, "Math | Operators", "~  Bitwise NOT", "~", "1").Tooltip.Set("~A");
		}

		/// A few members of String and the collections for when corlib isn't indexed.
		void AddBuiltinMembersOf(StringView type)
		{
			let baseName = BaseTypeName(type);
			String category = scope $"Receiver is {baseName}";
			void Builtin(StringView name, StringView paramsText, StringView ret)
			{
				let item = Add(.CallInstance, category, scope $"{name}({paramsText})", name, paramsText, ret);
				item.OnType.Set(baseName);
				item.Tooltip.AppendF("{} {}({})\nReceiver is {}", ret, name, paramsText, baseName);
			}
			void BuiltinProp(StringView name, StringView ret)
			{
				let item = Add(.GetField, category, scope $"Get {name}", name, ret);
				item.OnType.Set(baseName);
				item.Tooltip.AppendF("{} {}.{}", ret, baseName, name);
			}
			String elem = scope .();
			int lt = type.IndexOf('<');
			if (lt > 0 && type.EndsWith('>'))
				elem.Append(type.Substring(lt + 1, type.Length - lt - 2));
			switch (baseName)
			{
			case "String", "StringView":
				BuiltinProp("Length", "int");
				BuiltinProp("IsEmpty", "bool");
				Builtin("Contains", "StringView str", "bool");
				Builtin("StartsWith", "StringView str", "bool");
				Builtin("EndsWith", "StringView str", "bool");
				Builtin("IndexOf", "StringView str", "int");
				if (baseName == "String")
				{
					Builtin("Append", "StringView str", "void");
					Builtin("Clear", "", "void");
					Builtin("Set", "StringView str", "void");
				}
			case "List":
				BuiltinProp("Count", "int");
				BuiltinProp("IsEmpty", "bool");
				Builtin("Add", scope $"{elem} item", "void");
				Builtin("Remove", scope $"{elem} item", "bool");
				Builtin("Contains", scope $"{elem} item", "bool");
				Builtin("IndexOf", scope $"{elem} item", "int");
				Builtin("Insert", scope $"int index, {elem} item", "void");
				Builtin("RemoveAt", "int index", "void");
				Builtin("Clear", "", "void");
			case "Dictionary":
				BuiltinProp("Count", "int");
				Builtin("ContainsKey", "var key", "bool");
				Builtin("Remove", "var key", "bool");
				Builtin("Clear", "", "void");
			case "HashSet":
				BuiltinProp("Count", "int");
				Builtin("Add", scope $"{elem} item", "bool");
				Builtin("Contains", scope $"{elem} item", "bool");
				Builtin("Remove", scope $"{elem} item", "bool");
				Builtin("Clear", "", "void");
			default:
			}
		}

		/// UE's "Make Literal" entries for a data input.
		void AddLiterals()
		{
			String t = scope .();
			NormalizeType(mContextType, t);
			void Lit(StringView text, StringView type)
			{
				Add(.Expr, "Literals", scope $"Make Literal  {text}", text, type).Tooltip.AppendF("{}  ({})", text, type.IsEmpty ? "expression" : type);
			}
			if (t == "bool")
			{
				Lit("true", "bool");
				Lit("false", "bool");
			}
			else if (TypeRules.IsInt(t))
				Lit("0", t);
			else if (t == "float")
				Lit("0.0f", t);
			else if (t == "double")
				Lit("0.0", t);
			else if (TypeRules.IsChar(t))
				Lit("' '", t);
			else if (IsStringType(t))
				Lit("\"\"", t);
			else if (IsWild(t))
			{
				Lit("0", "int");
				Lit("true", "bool");
				Lit("\"\"", "String");
			}
			let fam = TypeRules.Family(t);
			if (fam == .Object || fam == .Interface || fam == .Pointer || fam == .Delegate || fam == .Unknown || fam == .Wildcard || t == "String")
				Lit("null", "");
			Lit("default", t);
		}

		public void Open(MethodGraph mg, ImVec2 spawnPos, int32 contextPinId)
		{
			Prepare(mg, spawnPos, contextPinId);
			mSearch.Set("");
			// Test hook (docs/Testing.md > Verifying the UI): typing cannot be posted to SDL, so a scripted run
			// pre-fills the search box; choosing a result is still a real (posted) click.
			String debugSearch = scope .();
			if (Environment.GetEnvironmentVariable("VB_DEBUG_NODE_MENU_SEARCH", debugSearch) case .Ok && !debugSearch.IsEmpty)
				mSearch.Set(debugSearch);
			mLastSearch.Set("\x01"); // force a refresh on the first frame
			mDirty = true;
			OpenRequested = true;
			mFocusSearch = true;
			SetHighlight(null);
			mNavOrder.Clear();
			mCaptureFor.Clear();
			mHotkeyMessage.Clear();
		}

		/// The context (the pin dragged from) and the local items for `mg`: what the menu lists when
		/// it opens there, without opening it.
		void Prepare(MethodGraph mg, ImVec2 spawnPos, int32 contextPinId)
		{
			SpawnPos = spawnPos;
			ContextPinId = contextPinId;
			ContextGraph = (mg != null) ? mg.Graph : null;
			mContext = .None;
			mContextType.Clear();
			mContextLabel.Clear();
			mReturnType.Clear();
			mOwnerName.Clear();
			mContextIsTarget = false;
			Prefs.Load();
			if (mg != null && mg.Method.TypeText != null)
				mReturnType.Set(mg.Method.TypeText);
			if (mg != null && mg.Owner != null)
				mOwnerName.Set(mg.Owner.Name);
			let pin = (mg != null && contextPinId != 0) ? mg.Graph.FindPin(contextPinId) : null;
			if (pin != null)
			{
				NormalizeType(pin.TypeName, mContextType);
				if (pin.Kind == .Exec)
				{
					mContext = .Exec;
					mContextLabel.Set("Flow nodes");
				}
				else if (!pin.IsInput)
				{
					mContext = .DataOut;
					mContextLabel.AppendF("Nodes taking a{} {}", StartsWithVowel(mContextType) ? "n" : "", IsWild(mContextType) ? "value" : mContextType);
				}
				else
				{
					mContext = .DataIn;
					mContextLabel.AppendF("Nodes returning a{} {}", StartsWithVowel(mContextType) ? "n" : "", IsWild(mContextType) ? "value" : mContextType);
					mContextIsTarget = pin.Name == "target" && pin.Owner.Kind == .Call;
				}
			}
			Build(mg);
			mContextIdsValid = false;
			mDirty = true;
		}

		/// Node hotkeys: the item a node key names, built for `mg` as the menu would list it there with
		/// the pin `contextPinId` (0 = none) as its context; SpawnPos and ContextPinId are set for the
		/// placement (EditorApp.ExecuteAction). Returns a copy the caller deletes, or null when this
		/// Sheet does not offer the node (Get a reference to this in a static function, a library
		/// node that is no longer indexed).
		public NodeItem ItemForKey(MethodGraph mg, ImVec2 spawnPos, int32 contextPinId, StringView key)
		{
			Prepare(mg, spawnPos, contextPinId);
			let found = FindItemByKey(key);
			if (found == null)
				return null;
			NodeItem copy = new .();
			copy.CopyFrom(found);
			copy.OrigCategory.Clear();
			return copy;
		}

		/// A local item or catalog entry by its key ("Category\tLabel"), or null.
		NodeItem FindItemByKey(StringView key)
		{
			int tab = key.IndexOf('\t');
			if (tab < 0)
				return null;
			let cat = key.Substring(0, tab);
			let label = key.Substring(tab + 1);
			for (let item in Items)
				if (item.Category == cat && item.Label == label)
					return item;
			// Catalog entry: find it by category and label (search by the label's words).
			List<SearchHit> hits = scope .();
			String q = scope .(label);
			int paren = q.IndexOf('(');
			if (paren > 0)
				q.RemoveToEnd(paren);
			Catalog.Search(q, hits, 50);
			for (let h in hits)
			{
				let ci = CatalogItem(h.Id);
				if (ci.Label == label && ci.Category == cat)
					return ci;
			}
			return null;
		}

		static bool StartsWithVowel(StringView s) => !s.IsEmpty && "aeiouAEIOU".Contains(s[0]) && !IsWild(s);

		// ------------------------------------------------------------------ catalog items

		/// Drops cached catalog items when the type index was rebuilt. Returns true when it did.
		bool SyncCatalogCache()
		{
			if (mCatalogGeneration == Types.Generation)
				return false;
			for (let kv in mCatalogItems)
				delete kv.value;
			mCatalogItems.Clear();
			mCatalogGeneration = Types.Generation;
			return true;
		}

		/// The NodeItem for a catalog entry (made on first use).
		NodeItem CatalogItem(int32 id)
		{
			SyncCatalogCache();
			if (mCatalogItems.TryGetValue(id, let existing))
				return existing;
			NodeSpec spec = scope .();
			Catalog.GetSpec(id, spec);
			NodeItem item = new .();
			item.CatalogId = id;
			for (var part in StringView(spec.Category).Split('|'))
			{
				part.Trim();
				if (part.IsEmpty)
					continue;
				if (!item.Category.IsEmpty)
					item.Category.Append(" | ");
				item.Category.Append(part);
			}
			item.Label.Set(spec.Label);
			item.Tooltip.Set(spec.Tooltip);
			item.Pure = spec.IsPure;
			switch (spec.Kind)
			{
			case .Call, .Pure, .Flow:
				item.Kind = spec.IsStatic ? .CallMethod : .CallInstance;
				item.A.Set(spec.IsStatic ? (StringView)spec.CallName : (StringView)spec.MemberName);
				item.B.Set(spec.ParamsText);
				item.C.Set(spec.ReturnType);
				item.OnType.Set(spec.OwnerType);
			case .Get, .Event:
				item.Kind = spec.IsStatic ? .GetVar : .GetField;
				item.A.Set(spec.IsStatic ? (StringView)spec.CallName : (StringView)spec.MemberName);
				item.B.Set(spec.ReturnType);
				item.OnType.Set(spec.OwnerType);
			case .Set:
				item.Kind = .SetVar;
				item.A.Set(spec.CallName);
				item.B.Set(spec.ReturnType);
			}
			mCatalogItems[id] = item;
			return item;
		}

		/// Is this catalog entry declared in the type whose graph is open? (Those are local items.)
		bool IsOwnMember(int32 id)
		{
			if (mOwnerName.IsEmpty)
				return false;
			let sc = Catalog.StoreOfId(id);
			if (sc.Store.IsLibrary)
				return false;
			let e = ref sc.Entries[NodeCatalog.EntryOf(id)];
			let m = ref sc.Store.Members[e.Member];
			return sc.Store.TypeName(m.Owner) == mOwnerName;
		}

		/// Creates the node for a catalog item (typed pins, defaults, pure/exec from attributes).
		/// Returns null for non-catalog items.
		public Node CreateCatalogNode(VisualBeef.Graph.Graph g, NodeItem item, bool wantExec)
		{
			if (item.CatalogId < 0)
				return null;
			NodeSpec spec = scope .();
			Catalog.GetSpec(item.CatalogId, spec);
			if (spec.Label != item.Label)
				return null; // the catalog changed since the menu was drawn
			return NodeFactory.FromSpec(g, spec, wantExec);
		}

		/// Remembers the choice in "Recently Used".
		public void NoteUsed(NodeItem item)
		{
			String key = scope .();
			item.GetKey(key);
			Prefs.Used(key);
		}

		// ------------------------------------------------------------------ filtering

		/// How well a local item fits the pin the menu was opened from (0 = hide it).
		int32 ContextRelevance(NodeItem item)
		{
			let T = mContextType;
			bool wild = IsWild(T);
			let fam = TypeRules.Family(T);
			switch (mContext)
			{
			case .None:
				return 1;
			case .Exec:
				return item.IsStatement ? 1 : 0;
			case .DataOut:
				// The new node needs an input that accepts a T.
				switch (item.Kind)
				{
				case .CallInstance, .GetField:
					if (wild)
						return 1;
					return (BaseTypeName(item.OnType) == BaseTypeName(T)) ? 2 : 0;
				case .CallMethod:
					if (item.A == "Console.WriteLine" || item.A == "Console.Write")
						return IsStringType(T) || wild ? 2 : 0;
					List<String> types = scope .();
					defer { ClearAndDeleteItems!(types); }
					ParamTypes(item.B, types);
					int32 best = 0;
					for (let pt in types)
					{
						if (pt == "Object")
							continue; // everything is an Object: not a fit
						let m = TypeMatch(T, pt);
						// A `var` parameter accepts anything but says little: only show it for
						// generic helpers (Math) or when the pin's type is unknown.
						if (m == 1 && IsWild(pt) && !wild && !item.Category.StartsWith("Math"))
							continue;
						best = Math.Max(best, m);
					}
					return best;
				case .CallCustom, .CallMember:
					return 1;
				case .SetVar:
					return wild ? 1 : (TypeMatch(T, item.B) == 2 ? 2 : (IsWild(item.B) ? 1 : 0));
				case .LocalVar, .Switch:
					return 1;
				case .Branch, .While, .DoWhile:
					return (T == "bool") ? 2 : (wild ? 1 : 0);
				case .ForEach:
					return IsCollection(T) ? 2 : (wild ? 1 : 0);
				case .ResultMatch:
					return (BaseTypeName(T) == "Result") ? 3 : (wild ? 1 : 0);
				case .Delete:
					return (wild || fam == .Object || fam == .Pointer || fam == .String || fam == .Interface || IsCollection(T)) ? 2 : 0;
				case .Using:
					return (wild || fam == .Struct || fam == .Object || fam == .Interface) ? 1 : 0;
				case .Return:
					if (mReturnType.IsEmpty || mReturnType == "void")
						return 0;
					return TypeMatch(T, mReturnType);
				case .Operator:
					return OperatorTakes(item.A, item.B == "2", T);
				case .Select:
					return (T == "bool") ? 2 : 1;
				case .MathExpr:
					return (wild || fam == .Int || fam == .Float || T == "bool") ? 2 : 0;
				case .Cast:
					// Casting makes sense for numbers, enums and objects (down-casts), not bools.
					return (wild || fam == .Int || fam == .Float || fam == .Char || fam == .Enum || fam == .Object || fam == .Interface || fam == .Pointer) ? 1 : 0;
				case .GetMember:
					return (wild || fam == .Object || fam == .Struct || fam == .Vector || fam == .Interface || fam == .Pointer || fam == .String) ? 1 : 0;
				case .Index:
					return (IsCollection(T) || wild) ? 1 : 0;
				default:
					return 0;
				}
			case .DataIn:
				// The new node needs an output that produces a T.
				switch (item.Kind)
				{
				case .GetVar:
					return TypeMatch(item.B, T);
				case .GetField:
					return TypeMatch(item.B, T);
				case .CallMethod, .CallInstance:
					if (item.C.IsEmpty || item.C == "void")
						return 0;
					let m = TypeMatch(item.C, T);
					if (m == 1 && IsWild(item.C) && !wild && !item.Category.StartsWith("Math"))
						return 0;
					return m;
				case .CallCustom, .CallMember:
					return 1;
				case .Operator:
					return OperatorGives(item.A, item.B == "2", T);
				case .Expr:
					return item.B.IsEmpty ? 1 : Math.Max(TypeMatch(item.B, T), 1);
				case .Cast:
					return item.A.IsEmpty ? 1 : 2;
				case .MathExpr:
					return (wild || fam == .Int || fam == .Float || T == "bool") ? 2 : 0;
				case .Select, .Index, .GetMember:
					return 1;
				case .Construct:
					if (item.A == "$")
						return IsStringType(T) ? 2 : (wild ? 1 : 0);
					if (item.A == ".")
						return (wild || !TypeRules.IsPrimitive(T)) ? 1 : 0;
					return (item.C == "array") ? 0 : TypeMatch(item.A, T);
				case .Delegate:
					// A function of this type with the pin's exact shape; the generic
					// `new => Method` only fits a delegate pin.
					if (item.C == "fits")
						return 3;
					return (wild || (TypeRules.Family(T) == .Delegate && !T.StartsWith("function "))) ? 1 : 0;
				case .This:
					// Dragged off a Target pin: self comes first.
					if (mContextIsTarget)
						return 3;
					return wild ? 1 : TypeMatch(mOwnerName, T);
				case .Base:
					return mContextIsTarget ? 2 : 1;
				default:
					return 0;
				}
			}
		}

		/// `function uint64(uint64 Year)` and `function uint64(uint64)`: the same shape (return and
		/// parameter types; names and spaces do not count).
		public static bool SameFunctionShape(StringView a, StringView b)
		{
			String na = scope .();
			String nb = scope .();
			FunctionShapeKey(a, na);
			FunctionShapeKey(b, nb);
			return !na.IsEmpty && na == nb;
		}

		static void FunctionShapeKey(StringView text, String outKey)
		{
			var t = text;
			t.Trim();
			if (!t.StartsWith("function "))
				return;
			t = t.Substring(9);
			int open = t.IndexOf('(');
			if (open < 0 || !t.EndsWith(")"))
				return;
			var ret = t.Substring(0, open);
			ret.Trim();
			outKey.Append(ret);
			outKey.Append('(');
			let inner = t.Substring(open + 1, t.Length - open - 2);
			int i = 0;
			for (var part in inner.Split(','))
			{
				part.Trim();
				if (part.IsEmpty)
					continue;
				// Drop a trailing parameter name: `uint64 Year` -> `uint64` (a type ends with an
				// identifier character, `*`, `]`, `>` or `?`; a name follows a space).
				int sp = part.LastIndexOf(' ');
				if (sp > 0)
				{
					let last = part.Substring(sp + 1);
					let first = part.Substring(0, sp);
					bool isMod = first == "ref" || first == "out" || first == "in";
					if (!isMod && last.Length > 0 && (last[0].IsLetter || last[0] == '_' || last[0] == '@'))
						part = first;
				}
				if (i++ > 0)
					outKey.Append(',');
				for (let c in part.RawChars)
					if (c != ' ')
						outKey.Append(c);
			}
			outKey.Append(')');
		}

		static bool IsComparison(StringView op) => op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=";
		static bool IsLogical(StringView op) => op == "&&" || op == "||" || op == "!";
		static bool IsBitwise(StringView op) => op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>" || op == "~";

		static int32 OperatorTakes(StringView op, bool binary, StringView T)
		{
			if (IsWild(T))
				return 1;
			if (T == "bool")
				return (IsLogical(op) || op == "==" || op == "!=") ? 2 : 0;
			if (IsNumeric(T))
			{
				if (IsLogical(op) || op == "??")
					return 0;
				if (IsBitwise(op) && !IsIntType(T))
					return 0;
				return 2;
			}
			if (IsStringType(T))
				return (op == "+" || op == "==" || op == "!=" || op == "??") ? 2 : 0;
			return (op == "==" || op == "!=" || op == "??") ? 1 : 0;
		}

		static int32 OperatorGives(StringView op, bool binary, StringView T)
		{
			if (IsWild(T))
				return 1;
			if (T == "bool")
				return (IsComparison(op) || IsLogical(op)) ? 2 : 0;
			if (IsComparison(op) || IsLogical(op))
				return 0;
			if (IsNumeric(T))
				return (IsBitwise(op) && !IsIntType(T)) ? 0 : 2;
			if (IsStringType(T))
				return (op == "+" || op == "??") ? 1 : 0;
			return (op == "??") ? 1 : 0;
		}

		/// Every word must appear (case-insensitive), or the letters must appear in order.
		static float LocalScore(NodeItem item, StringView search)
		{
			if (search.IsEmpty)
				return 1;
			String key = scope .();
			key.AppendF("{} {}", item.Label, item.Category);
			key.ToLower();
			String q = scope .(search);
			q.ToLower();
			List<StringView> words = scope .();
			for (let w in q.Split(' '))
				if (!w.IsEmpty)
					words.Add(w);
			var score = NodeCatalog.ScoreKey(key, item.Label, words);
			if (score <= 0)
				return 0;
			if (StringView(item.Label).Equals(search, true))
				score += 30;
			score -= item.Label.Length * 0.05f;
			// "Call <typed text>()" / "Expression: ..." always match exactly; prefer real actions.
			if (item.Category == "Custom")
				score -= 200;
			return score;
		}

		/// Catalog entries that fit the context pin (once per open).
		void ComputeContextIds()
		{
			mContextIds.Clear();
			mContextIdsValid = true;
			if (mContext != .DataOut && mContext != .DataIn && mContext != .Exec)
				return;
			if ((mContext == .DataOut || mContext == .DataIn) && IsWild(mContextType))
				return; // an untyped pin: the catalog stays unfiltered (search to find things)
			let ctx = (mContext == .DataOut) ? PinContext.TakesValue : PinContext.GivesValue;
			for (int si < Catalog.Stores.Count)
			{
				let sc = Catalog.Stores[si];
				for (int ei < sc.Entries.Count)
				{
					let id = NodeCatalog.MakeId(si, ei);
					let e = ref sc.Entries[ei];
					if (mContext == .Exec)
					{
						if (e.Kind == .Call || e.Kind == .Set || e.Kind == .Flow)
							mContextIds.Add(id);
						continue;
					}
					if (Catalog.ContextRelevance(id, ctx, mContextType) >= 2)
						mContextIds.Add(id);
				}
			}
		}

		void ClearGroups()
		{
			for (let kv in mGroups)
				delete kv.value;
			mGroups.Clear();
			ClearAndDeleteItems!(mGroupOrder);
			mVisibleCount = 0;
		}

		void AddToGroup(NodeItem item)
		{
			if (!mGroups.TryGetValue(item.Category, var list))
			{
				list = new List<NodeItem>();
				let key = new String(item.Category);
				mGroupOrder.Add(key);
				mGroups[key] = list;
			}
			list.Add(item);
			mVisibleCount++;
		}

		/// Dragged off an enum-typed output pin: the `Switch on <EnumName>` item, one case per member
		/// (the first row of the menu). Null for any other context. The caller owns the item.
		public NodeItem MakeSwitchOn()
		{
			if (mContext != .DataOut || mContextType.IsEmpty)
				return null;
			let ct = MemberInit.TypeOf(mContextType, Types);
			if (ct.Kind != .Enum || ct.IsPointer)
				return null;
			List<String> ms = scope .();
			defer { ClearAndDeleteItems!(ms); }
			MemberInit.EnumMembers(ct.BaseText, Types, ms);
			if (ms.IsEmpty)
				return null;
			NodeItem item = new .();
			item.Kind = .Switch;
			item.Category.Set("Suggested");
			item.Label.AppendF("Switch on {}", BaseTypeName(mContextType));
			item.A.Set(ct.BaseText);
			for (let m in ms)
			{
				if (!item.B.IsEmpty)
					item.B.Append('\n');
				item.B.Append(m);
			}
			item.Tooltip.AppendF("switch ({}) {{ one case per member }}", ct.BaseText);
			return item;
		}

		/// Recomputes what is shown. Runs when the search text, the context checkbox or the
		/// catalog changes, not every frame.
		void Refilter(StringView search)
		{
			ClearGroups();
			bool filterByContext = mContext != .None && ContextSensitive;
			bool catalogContext = filterByContext && (mContext == .Exec || !IsWild(mContextType));
			if (catalogContext && !mContextIdsValid)
				ComputeContextIds();

			// Free-form entries from the search text
			DeleteAndNullify!(mCustom);
			DeleteAndNullify!(mCustomMember);
			DeleteAndNullify!(mCustomExpr);
			DeleteAndNullify!(mSwitchOn);
			if (!search.IsEmpty)
			{
				var name = search;
				bool isIdent = true;
				for (let c in name.RawChars)
					if (!Syntax.CharUtil.IsIdentChar(c) && c != '.' && c != '<' && c != '>' && c != ',' && c != ' ')
						isIdent = false;
				if (isIdent && !name.IsEmpty)
				{
					mCustom = new .();
					mCustom.Kind = .CallCustom;
					mCustom.Category.Set("Custom");
					mCustom.Label.AppendF("Call {}()", name);
					mCustom.A.Set(name);
					mCustom.Tooltip.AppendF("{}()  (a function not in the index)", name);
					mCustomMember = new .();
					mCustomMember.Kind = .CallMember;
					mCustomMember.Category.Set("Custom");
					mCustomMember.Label.AppendF("Call Receiver.{}()", name);
					mCustomMember.A.Set(name);
					mCustomMember.Tooltip.AppendF("Receiver.{}()", name);
				}
				mCustomExpr = new .();
				mCustomExpr.Kind = .Expr;
				mCustomExpr.Category.Set("Custom");
				mCustomExpr.Label.AppendF("Expression: {}", name);
				mCustomExpr.A.Set(name);
				mCustomExpr.Tooltip.AppendF("{}  (kept verbatim)", name);
			}

			// Scored candidates: local items and catalog hits together.
			List<NodeItem> scored = scope .();
			void ConsiderLocal(NodeItem item)
			{
				item.Relevance = (mContext != .None) ? ContextRelevance(item) : 1;
				if (filterByContext && item.Relevance == 0)
					return;
				let s = LocalScore(item, search);
				if (s <= 0)
					return;
				item.Score = s + item.Relevance * 15;
				scored.Add(item);
			}
			for (let item in Items)
				ConsiderLocal(item);
			if (mCustom != null) ConsiderLocal(mCustom);
			if (mCustomMember != null) ConsiderLocal(mCustomMember);
			if (mCustomExpr != null) ConsiderLocal(mCustomExpr);
			mSwitchOn = MakeSwitchOn();
			if (mSwitchOn != null)
			{
				let before = scored.Count;
				ConsiderLocal(mSwitchOn);
				if (scored.Count > before)
				{
					scored.Remove(mSwitchOn);
					mSwitchOn.Score += 1000;
					scored.Insert(0, mSwitchOn);
				}
			}

			// Favorites and recents first when nothing is typed.
			if (search.IsEmpty)
			{
				AddPrefGroup(cFavoritesGroup, Prefs.Favorites, scored, filterByContext);
				AddPrefGroup(cRecentGroup, Prefs.Recents, scored, filterByContext);
			}

			List<SearchHit> hits = scope .();
			let ctxKind = (mContext == .DataOut) ? PinContext.TakesValue : ((mContext == .DataIn) ? PinContext.GivesValue : PinContext.None);
			if (!search.IsEmpty)
			{
				HashSet<int32> allowed = null;
				if (catalogContext)
				{
					allowed = scope:: .();
					for (let id in mContextIds)
						allowed.Add(id);
				}
				Catalog.Search(search, hits, cMaxCatalogHits,
					scope (id) => (allowed == null || allowed.Contains(id)) && !IsOwnMember(id),
					scope (id) => (ctxKind != .None && !IsWild(mContextType)) ? Catalog.ContextRelevance(id, ctxKind, mContextType) * 8.0f : 0);
			}
			else if (catalogContext)
			{
				// Context with no search: every matching entry, best relevance first.
				for (let id in mContextIds)
				{
					if (IsOwnMember(id))
						continue;
					float rel = (ctxKind != .None) ? Catalog.ContextRelevance(id, ctxKind, mContextType) : 1;
					hits.Add(.() { Id = id, Score = rel * 10 });
					if (hits.Count >= 2000)
						break;
				}
				hits.Sort(scope (a, b) => b.Score <=> a.Score);
			}
			for (let h in hits)
			{
				let item = CatalogItem(h.Id);
				item.Relevance = (int32)Math.Max(1, (ctxKind != .None) ? Catalog.ContextRelevance(h.Id, ctxKind, mContextType) : 1);
				item.Score = h.Score + (search.IsEmpty ? 0 : 0);
				scored.Add(item);
			}

			// Group: categories ordered by their best item (or by first appearance when browsing).
			if (!search.IsEmpty)
				scored.Sort(scope (a, b) => b.Score <=> a.Score);
			for (let item in scored)
				AddToGroup(item);
			if (search.IsEmpty)
			{
				// Keep categories that share a top-level name together, in first-appearance order.
				List<String> sorted = scope .();
				List<StringView> tops = scope .();
				for (let c in mGroupOrder)
				{
					let top = TopLevel(c);
					if (!tops.Contains(top))
						tops.Add(top);
				}
				for (let top in tops)
					for (let c in mGroupOrder)
						if (TopLevel(c) == top)
							sorted.Add(c);
				mGroupOrder.Clear();
				mGroupOrder.AddRange(sorted);
			}
		}

		const String cFavoritesGroup = "Favorites";
		const String cRecentGroup = "Recently Used";

		/// Favorite / recent keys turned back into items (local ones, or catalog ones by label).
		void AddPrefGroup(StringView groupName, List<String> keys, List<NodeItem> scored, bool filterByContext)
		{
			if (keys.IsEmpty)
				return;
			for (let key in keys)
			{
				let found = FindItemByKey(key);
				if (found == null)
					continue;
				if (filterByContext)
				{
					int32 rel = (found.CatalogId >= 0) ? 2 : ContextRelevance(found);
					if (found.CatalogId >= 0 && !mContextIds.IsEmpty)
						rel = mContextIds.Contains(found.CatalogId) ? 2 : 0;
					if (rel == 0)
						continue;
				}
				// A copy in the pref group (the original stays in its own category).
				NodeItem copy = new .();
				copy.CopyFrom(found);
				copy.OrigCategory.Set(found.Category);
				copy.Category.Set(groupName);
				mPrefCopies.Add(copy);
				AddToGroup(copy);
			}
		}
		List<NodeItem> mPrefCopies = new .() ~ DeleteContainerAndItems!(_);

		// ------------------------------------------------------------------ draw

		/// Draws the popup. Returns the chosen item (a new copy the caller deletes) or null.
		public NodeItem Draw()
		{
			if (OpenRequested)
			{
				Gui.OpenPopup("##nodes");
				OpenRequested = false;
			}
			// Sized with the display scale, never taller than the window (the list scrolls).
			let vpSize = Gui.igGetMainViewport().Size;
			Gui.igSetNextWindowSize(.(Math.Min(440 * Look.Scale, vpSize.x - 16), Math.Min(500 * Look.Scale, vpSize.y - 48 * Look.Scale)), Cond.Always);
			if (SelfTestPlace)
				Gui.igSetNextWindowPos(SelfTestPopupPos, Cond.Always, .(0, 0));
			else if (SelfTestPos.x > 0)
				Gui.igSetNextWindowPos(SelfTestPos, Cond.Always, .(0, 0));
			if (!Gui.BeginPopup("##nodes"))
			{
				mShown = false;
				CloseRequested = false;
				SelfTestPlace = false;
				return null;
			}
			mShown = true;
			if (CloseRequested)
			{
				CloseRequested = false;
				mShown = false;
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return null;
			}

			NodeItem chosen = null;
			Gui.TextColored(Gui.Color(220, 220, 220), "All nodes for this Sheet");
			{
				// Always drawn, right-aligned from its measured width (box + label), so no scale or
				// window width can push it out of view. Disabled when the menu has no pin context.
				const String cLabel = "Context Sensitive";
				float boxW = Gui.igGetFrameHeight() + Gui.CalcTextSize(cLabel).x + 8 * Look.Scale;
				Gui.SameLine(Math.Max(Gui.igGetCursorPosX() + 8 * Look.Scale, Gui.igGetWindowSize().x - boxW - 16 * Look.Scale), -1);
				bool hasPin = mContext != .None;
				Gui.igBeginDisabled(!hasPin);
				if (Gui.Checkbox(cLabel, &ContextSensitive))
					mDirty = true;
				Gui.igEndDisabled();
				if (Gui.igIsItemHovered(1024)) // AllowWhenDisabled
					Gui.Tooltip(hasPin ? "Only show nodes that can connect to the pin you dragged from" : "Drag from a pin to filter by what can connect");
			}
			if (mContext != .None && ContextSensitive)
				Gui.TextColored(Theme.TextDim, mContextLabel);
			if (!mHotkeyMessage.IsEmpty)
				Gui.TextColored(mHotkeyMessageError ? Look.Error : Theme.TextDim, mHotkeyMessage);
			if (mFocusSearch)
			{
				Gui.igSetKeyboardFocusHere(0);
				mFocusSearch = false;
			}
			Gui.igSetNextItemWidth(-1);
			// A capture typed into the box: a new id makes the box read the text set from outside.
			Gui.PushID(mSelfTestSearchGen);
			bool enter = Gui.igInputTextWithHint("##search", "Search", mSearch.Ptr, (.)mSearch.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
			Gui.PopID();
			// Keep typing going to the search box, like UE. Never while a mouse button is down:
			// clicking a row deactivates the search box, and grabbing focus back on the next frame
			// would steal the active id from the row being pressed, so a click held longer than
			// a frame or two never registered (only Enter could place a node).
			// While a hotkey is being captured the letter goes to the key-capture control, not the search box.
			if (!mCaptureFor.IsEmpty && Gui.igIsItemActive())
				igClearActiveID();
			if (!Gui.igIsItemActive() && !Gui.igIsAnyItemActive() && !Gui.igIsAnyMouseDown() && mCaptureFor.IsEmpty)
				mFocusSearch = true;
			var search = mSearch.View;
			search.Trim();
			bool searchChanged = search != mLastSearch;
			if (searchChanged)
			{
				// Debounce: while keys keep coming, the list waits until typing pauses for
				// cSearchDebounce (Enter, an emptied box and the first frame filter at once).
				bool first = mLastSearch == "\x01";
				mLastSearch.Set(search);
				mSearchPending = true;
				mSearchChangedAt = Desktop.Now;
				if (first)
					mSearchChangedAt = 0;
			}
			searchChanged = mSearchPending && (enter || search.IsEmpty || Desktop.Now - mSearchChangedAt >= cSearchDebounce);
			if (searchChanged)
				mSearchPending = false;
			// The index was rebuilt: drop the cached catalog items and filter again. (This used to
			// compare without syncing, and browsing with an empty search never touches a catalog
			// item, so the menu re-filtered, re-forced its category open state and re-scrolled to
			// the highlight on every frame: categories could not be clicked open and the list
			// fought the mouse wheel.)
			if (SyncCatalogCache())
			{
				mNavOrder.Clear();
				SetHighlight(null);
				mDirty = true;
			}
			if (searchChanged || mDirty)
			{
				// Refilter frees the free-form and preference rows last frame's list points at:
				// the arrow keys below must not walk that list.
				mNavOrder.Clear();
				ClearAndDeleteItems!(mPrefCopies);
				Refilter(search);
				mDirty = false;
				searchChanged = true;
			}
			bool browsing = search.IsEmpty && !(mContext != .None && ContextSensitive);

			// Best match: re-picked whenever the results change.
			if (searchChanged)
			{
				mForceOpen = (!search.IsEmpty || mVisibleCount <= 40) ? 1 : -1;
				SetHighlight(null);
				NodeItem best = null;
				float bestScore = float.MinValue;
				for (let c in mGroupOrder)
				{
					for (let item in mGroups[c])
					{
						float sc = search.IsEmpty ? (item.Relevance * 10.0f) : item.Score;
						if (best == null || sc > bestScore)
						{
							best = item;
							bestScore = sc;
						}
					}
				}
				if (best != null)
					SetHighlight(best);
				mScrollToHighlight = true;
			}

			// Arrow keys move the highlight through what was drawn last frame.
			int navDelta = 0;
			if (Gui.igIsKeyPressed_Bool(Key.DownArrow, true))
				navDelta = 1;
			if (Gui.igIsKeyPressed_Bool(Key.UpArrow, true))
				navDelta = -1;
			if (Gui.igIsKeyPressed_Bool(Key.PageDown, true))
				navDelta = 10;
			if (Gui.igIsKeyPressed_Bool(Key.PageUp, true))
				navDelta = -10;
			if (navDelta != 0 && !mNavOrder.IsEmpty)
			{
				int cur = -1;
				for (let it in mNavOrder)
					if (IsHighlighted(it))
						cur = @it.Index;
				int next = (cur < 0) ? 0 : Math.Clamp(cur + navDelta, 0, mNavOrder.Count - 1);
				SetHighlight(mNavOrder[next]);
				mScrollToHighlight = true;
			}
			if (!mCaptureFor.IsEmpty)
				UpdateCapture();
			else if (Gui.IsKeyPressed(Key.Escape))
				Gui.igCloseCurrentPopup();

			if (Gui.igBeginChild_Str("##list", .(0, 0), 0, 0))
			{
				mNavOrder.Clear();
				mAuditSeen.Clear();
				if (mVisibleCount == 0 && !browsing)
					Gui.TextDisabled((mContext != .None && ContextSensitive) ? "No matching nodes for this pin.\nUntick Context Sensitive to see everything." : "No matching nodes.");
				if (DrawGroups())
					chosen = mClicked;
				// Browsing with nothing typed: the whole catalog as UE's "All Actions" tree.
				if (browsing && chosen == null)
				{
					let tree = Catalog.Tree;
					if (tree.Total > 0)
					{
						Gui.Separator();
						Gui.TextColored(Theme.TextDim, scope $"Library  ({tree.Total} nodes)");
						for (let child in tree.Children)
						{
							if (DrawCatalogNode(child, 0))
							{
								chosen = mClicked;
								break;
							}
						}
					}
				}
				mForceOpen = 0;
				Gui.igEndChild();
			}
			if (enter && chosen == null)
			{
				for (let it in mNavOrder)
					if (IsHighlighted(it))
						chosen = it;
				if (chosen == null && !mNavOrder.IsEmpty)
					chosen = mNavOrder[0];
			}

			if (chosen != null)
			{
				// Copy out: free-form and catalog items belong to the menu.
				NodeItem copy = new .();
				copy.CopyFrom(chosen);
				if (!copy.OrigCategory.IsEmpty)
				{
					// A Favorites / Recently Used copy: back to its real category, so it is found again.
					copy.Category.Set(copy.OrigCategory);
					copy.OrigCategory.Clear();
				}
				mCaptureFor.Clear();
				if (copy.Category != "Custom")
					NoteUsed(copy);
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return copy;
			}
			Gui.EndPopup();
			return null;
		}

		NodeItem mClicked;

		/// Self-test hook (`VB_SELFTEST=ids`): when on, every tree row and item row drawn in a frame has its
		/// ImGui ID recorded and a repeat counts in IdDuplicates (ImGui shows these as "conflicting ID").
		public bool AuditIds;
		/// With AuditIds: the Library tree is drawn fully open (to the given depth).
		public int AuditOpenDepth;
		/// Self-test captures: the Library tree node with this path (and its parents) is drawn open.
		public String OpenPath = new .() ~ delete _;
		public int IdDuplicates;
		public int IdsSeen;
		HashSet<uint32> mAuditSeen = new .() ~ delete _;

		void AuditNote()
		{
			if (!AuditIds)
				return;
			IdsSeen++;
			if (!mAuditSeen.Add(Gui.igGetItemID()))
				IdDuplicates++;
		}

		/// Self test: how many rows the menu would list for an empty search with Context Sensitive
		/// on or off (leaves the setting as asked).
		public int SelfTestVisibleCount(bool contextSensitive)
		{
			ContextSensitive = contextSensitive;
			Refilter("");
			return mVisibleCount;
		}

		public bool SelfTestHasContext => mContext != .None;

		/// Self test: the rows the menu lists for `search` (Context Sensitive as set), in the order
		/// shown, copied into `outItems` (the caller deletes them).
		public void SelfTestRows(StringView search, List<NodeItem> outItems)
		{
			Refilter(search);
			for (let key in mGroupOrder)
				if (mGroups.TryGetValue(key, let list))
					for (let it in list)
					{
						NodeItem copy = new .();
						copy.CopyFrom(it);
						outItems.Add(copy);
					}
		}

		int32 mSelfTestSearchGen;

		/// Self-test: logs the paths of the Library tree down to `depth` (to pick a `menu-open:` path).
		public void SelfTestDumpTree(int depth)
		{
			void Walk(CategoryNode n, int d)
			{
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] tree {n.Path} ({n.Total})");
				if (d < depth)
					for (let c in n.Children)
						Walk(c, d + 1);
			}
			for (let c in Catalog.Tree.Children)
				Walk(c, 1);
		}

		/// Self-test hook (captures): the popup's top-left corner while it is open (else it opens at the mouse).
		public ImVec2 SelfTestPopupPos;
		public bool SelfTestPlace;

		/// Self-test hook: the item whose label starts with `label` is found by `search`.
		public bool SelfTestFinds(StringView label, StringView search)
		{
			for (let it in Items)
				if (it.Label.StartsWith(label))
					return LocalScore(it, search) > 0;
			return false;
		}

		/// Self-test hook: types into the search box.
		public void SelfTestSetSearch(StringView text)
		{
			mSearch.Set(text);
			mSelfTestSearchGen++;
		}

		// ------------------------------------------------------------------ favorites and node hotkeys

		/// The node key whose hotkey the key-capture control is waiting for ("" = none).
		String mCaptureFor = new .() ~ delete _;
		/// The last hotkey assignment's outcome, under the search box (a refusal names the owner).
		String mHotkeyMessage = new .() ~ delete _;
		bool mHotkeyMessageError;

		/// The key-capture control of a favorite's row: "Press a key" until a letter (assigned, or
		/// refused with the reason), Esc (the hotkey is cleared) or a click elsewhere.
		public void StartCapture(StringView key)
		{
			mCaptureFor.Set(key);
			mFocusSearch = false;
			mHotkeyMessage.Set("Press a letter for the hotkey of ");
			mHotkeyMessage.Append(NodeHotkeys.LabelOf(key));
			mHotkeyMessage.Append(". Esc clears it.");
			mHotkeyMessageError = false;
		}

		public bool IsCapturing => !mCaptureFor.IsEmpty;
		public StringView HotkeyMessage => mHotkeyMessage;

		/// The capture's keys, before the rows are drawn.
		void UpdateCapture()
		{
			if (Gui.IsKeyPressed(Key.Escape, false))
				CaptureEscape();
			else if (Gui.igIsMouseClicked_Bool(0, false) || Gui.igIsMouseClicked_Bool(1, false))
			{
				// A click elsewhere ends the capture (a click on the control starts it again).
				mCaptureFor.Clear();
				mHotkeyMessage.Clear();
			}
			else if (!Gui.IsCtrlDown && !Gui.IsAltDown)
			{
				for (int i < 26)
				{
					if (Gui.IsKeyPressed(cKeyA + (int32)i, false))
					{
						CaptureKey((char8)('A' + i));
						break;
					}
				}
			}
		}

		/// Esc in the key-capture control: the node's hotkey is cleared.
		public void CaptureEscape()
		{
			let label = scope String(NodeHotkeys.LabelOf(mCaptureFor));
			mHotkeyMessage.Clear();
			mHotkeyMessage.AppendF(Prefs.ClearHotkey(mCaptureFor) ? "Hotkey of {} cleared." : "{} has no hotkey.", label);
			mHotkeyMessageError = false;
			mCaptureFor.Clear();
			mFocusSearch = true;
			mDirty = true;
		}

		/// A letter typed into the key-capture control (also the session self test's path). A refusal
		/// keeps the control waiting and names the reason.
		public bool CaptureKey(char8 letter)
		{
			let key = scope String(mCaptureFor);
			mHotkeyMessage.Clear();
			let ok = Prefs.AssignHotkey(key, letter, mHotkeyMessage);
			mHotkeyMessageError = !ok;
			if (ok)
			{
				mCaptureFor.Clear();
				mFocusSearch = true;
				mDirty = true;
			}
			return ok;
		}

		[CLink] static extern void igClearActiveID();

		/// ImGuiKey_A; the letters follow in order.
		public const int32 cKeyA = 546;

		/// One selectable row: the type dot, the label, the hotkey badge (favorites and nodes with a
		/// key; on a favorite it is the key-capture control) and the favorite star. Returns true when
		/// the row was clicked.
		bool DrawItem(NodeItem item)
		{
			mNavOrder.Add(item);
			Gui.PushID((int32)mNavOrder.Count);
			bool highlighted = IsHighlighted(item);
			// Type-coloured dot like the variable entries.
			uint32 dot = ItemColor(item);
			let dl = Gui.igGetWindowDrawList();
			let cp = Gui.igGetCursorScreenPos();
			float fh = Gui.igGetFontSize();
			Gui.ImDrawList_AddCircleFilled(dl, .(cp.x + 5, cp.y + fh * 0.5f + 1), 3.5f, dot, 0);
			Gui.igSetCursorScreenPos(.(cp.x + 14, cp.y));
			String key = scope .();
			item.GetKey(key);
			bool custom = item.Category == "Custom";
			bool fav = !custom && Prefs.IsFavorite(key);
			char8 hotkey = custom ? '\0' : Prefs.Hotkeys.KeyOf(key);
			bool capturing = !custom && mCaptureFor == key;
			Gui.igSetNextItemAllowOverlap();
			bool clicked = Gui.Selectable(item.Label, highlighted);
			AuditNote();
			let rMin = Gui.igGetItemRectMin();
			let rMax = Gui.igGetItemRectMax();
			bool rowHovered = Gui.igIsItemHovered(0);
			if (highlighted && mScrollToHighlight)
			{
				Gui.igSetScrollHereY(0.5f);
				mScrollToHighlight = false;
			}
			if (rowHovered)
			{
				String tip = scope .();
				tip.Append(item.Tooltip.IsEmpty ? item.Label : item.Tooltip);
				if (item.Relevance >= 2 && mContext != .None)
					tip.Append(item.Relevance >= 3 ? "\n(exact type match)" : "\n(converts implicitly)");
				if (hotkey != '\0')
					tip.AppendF("\nNode hotkey {0}: hold {0} and click the Sheet, or press {0} while dragging a wire", hotkey);
				Gui.Tooltip(tip);
			}
			if (Gui.igBeginPopupContextItem("##fav", 1))
			{
				if (!custom)
				{
					if (Gui.MenuItem(fav ? "Remove from Favorites" : "Add to Favorites"))
					{
						Prefs.ToggleFavorite(key);
						mDirty = true;
					}
					if (Gui.MenuItem((hotkey != '\0') ? scope $"Change Hotkey ({hotkey})..." : "Set Hotkey..."))
						StartCapture(key);
					if (hotkey != '\0' && Gui.MenuItem("Clear Hotkey"))
					{
						Prefs.ClearHotkey(key);
						mDirty = true;
					}
				}
				Gui.EndPopup();
			}
			if (!custom)
			{
				float h = rMax.y - rMin.y;
				float starW = fh * 1.4f;
				bool showKey = fav || hotkey != '\0' || capturing;
				float keyW = capturing ? Gui.CalcTextSize("Press a key").x + 12 * Look.Scale : fh * 1.5f;
				float x = rMax.x - starW - (showKey ? keyW + 4 : 0);
				if (showKey)
				{
					Gui.SameLine();
					Gui.igSetCursorScreenPos(.(x, rMin.y));
					if (Gui.igInvisibleButton("##hotkey", .(keyW, h), 0))
					{
						if (capturing)
							mCaptureFor.Clear();
						else
							StartCapture(key);
						capturing = !mCaptureFor.IsEmpty;
					}
					bool keyHovered = Gui.igIsItemHovered(0);
					let b0 = ImVec2(x, rMin.y + 1);
					let b1 = ImVec2(x + keyW, rMax.y - 1);
					if (capturing)
					{
						Gui.ImDrawList_AddRectFilled(dl, b0, b1, Look.Primary, 3, 0);
						StringView t = "Press a key";
						let ts = Gui.CalcTextSize(t);
						Gui.ImDrawList_AddText_Vec2(dl, .(x + (keyW - ts.x) * 0.5f, rMin.y + (h - ts.y) * 0.5f), Gui.Color(255, 255, 255), t.Ptr, t.Ptr + t.Length);
					}
					else
					{
						bool on = hotkey != '\0';
						Gui.ImDrawList_AddRectFilled(dl, b0, b1, on ? Look.Dropdown : Theme.WithAlpha(Look.Dropdown, keyHovered ? 255 : 90), 3, 0);
						Gui.ImDrawList_AddRect(dl, b0, b1, keyHovered ? Look.Hover2 : Look.DropdownOutline, 3, 1, 0);
						String t = scope .();
						if (on)
							t.Append(hotkey);
						else if (keyHovered || rowHovered)
							t.Append("+");
						if (!t.IsEmpty)
						{
							let ts = Gui.CalcTextSize(t);
							Gui.ImDrawList_AddText_Vec2(dl, .(x + (keyW - ts.x) * 0.5f, rMin.y + (h - ts.y) * 0.5f), on ? Look.ForegroundHover : Look.ForegroundDim, t.Ptr, t.Ptr + t.Length);
						}
					}
					if (keyHovered)
					{
						if (capturing)
							Gui.Tooltip("Press a letter for this node's hotkey. Esc clears it.");
						else if (hotkey != '\0')
							Gui.Tooltip(scope $"Node hotkey {hotkey}: hold {hotkey} and click the Sheet, or press {hotkey} while dragging a wire.\nClick to change it.");
						else
							Gui.Tooltip("Give this favorite a node hotkey");
					}
					x += keyW + 4;
				}
				Gui.SameLine();
				Gui.igSetCursorScreenPos(.(x, rMin.y));
				if (Gui.igInvisibleButton("##star", .(starW, h), 0))
				{
					fav = Prefs.ToggleFavorite(key);
					if (!fav && capturing)
						mCaptureFor.Clear();
					mDirty = true;
				}
				bool starHovered = Gui.igIsItemHovered(0);
				if (fav || starHovered || rowHovered)
				{
					StringView star = Icon.Loaded ? Icon.Star : "*";
					let ts = Gui.CalcTextSize(star);
					uint32 col = fav ? Look.AccentYellow : (starHovered ? Look.ForegroundHover : Look.ForegroundDim);
					Gui.ImDrawList_AddText_Vec2(dl, .(x + (starW - ts.x) * 0.5f, rMin.y + (h - ts.y) * 0.5f), col, star.Ptr, star.Ptr + star.Length);
				}
				if (starHovered)
					Gui.Tooltip(fav ? "Remove from Favorites" : "Add to Favorites");
			}
			Gui.PopID();
			if (clicked)
				mClicked = item;
			return clicked;
		}

		/// The filtered result as a category tree ("A | B" is the subcategory B of A). Rows that share
		/// a path are one row, whichever source or order they arrive in.
		bool DrawGroups()
		{
			let root = MergedCategory.Build(mGroupOrder);
			defer delete root;
			StringView firstTop = (mGroupOrder.Count > 0) ? TopLevel(mGroupOrder[0]) : default;
			bool clicked = false;
			for (let child in root.Children)
			{
				if (DrawGroupNode(child, firstTop))
				{
					clicked = true;
					break;
				}
			}
			return clicked;
		}

		bool DrawGroupNode(MergedCategory node, StringView firstTop)
		{
			// Many results: only the first (most relevant) category starts open.
			if (mForceOpen != 0)
			{
				bool pref = node.Path == cFavoritesGroup || node.Path == cRecentGroup;
				Gui.igSetNextItemOpen(mForceOpen > 0 || pref || (TopOf(node.Path) == firstTop), Cond.Always);
			}
			else if (node.Path == node.Name)
				Gui.igSetNextItemOpen(true, Cond.Once);
			Gui.igPushStyleColor_U32(Col.Text, Gui.Color(235, 235, 235));
			bool open = Gui.TreeNode(scope $"{node.Name}##grp|{node.Path}", TreeNodeFlags.SpanAvailWidth);
			Gui.igPopStyleColor(1);
			AuditNote();
			if (!open)
				return false;
			bool clicked = false;
			for (let cat in node.Cats)
			{
				for (let item in mGroups[cat])
				{
					if (DrawItem(item))
					{
						clicked = true;
						break;
					}
				}
				if (clicked)
					break;
			}
			if (!clicked)
			{
				for (let child in node.Children)
				{
					if (DrawGroupNode(child, firstTop))
					{
						clicked = true;
						break;
					}
				}
			}
			Gui.TreePop();
			return clicked;
		}

		static StringView TopOf(StringView path)
		{
			int bar = path.IndexOf('|');
			return (bar >= 0) ? path.Substring(0, bar) : path;
		}

		/// A catalog category in browse mode: children and items are only visited when open.
		bool DrawCatalogNode(CategoryNode node, int depth)
		{
			if (node.Total == 0)
				return false;
			if (AuditIds && depth < AuditOpenDepth)
				Gui.igSetNextItemOpen(true, Cond.Always);
			else if (!OpenPath.IsEmpty && (OpenPath == node.Path || (OpenPath.Length > node.Path.Length && OpenPath.StartsWith(node.Path) && OpenPath[node.Path.Length] == '|')))
				Gui.igSetNextItemOpen(true, Cond.Always);
			else if (mForceOpen != 0)
				Gui.igSetNextItemOpen(false, Cond.Always);
			Gui.igPushStyleColor_U32(Col.Text, Gui.Color(235, 235, 235));
			bool open = Gui.TreeNode(scope $"{node.Name}##{node.Path}", TreeNodeFlags.SpanAvailWidth);
			Gui.igPopStyleColor(1);
			AuditNote();
			if (!OpenPath.IsEmpty && OpenPath == node.Path)
				Gui.igSetScrollHereY(0.1f); // self-test captures: bring the opened node into view
			if (!open)
				return false;
			bool clicked = false;
			for (let child in node.Children)
			{
				if (DrawCatalogNode(child, depth + 1))
				{
					clicked = true;
					break;
				}
			}
			if (!clicked)
			{
				const int cMaxShown = 400;
				int shown = 0;
				for (let id in node.Entries)
				{
					if (IsOwnMember(id))
						continue;
					if (shown++ >= cMaxShown)
					{
						Gui.TextDisabled(scope $"... {node.Entries.Count - cMaxShown} more: type to search");
						break;
					}
					let item = CatalogItem(id);
					item.Relevance = 1;
					if (DrawItem(item))
					{
						clicked = true;
						break;
					}
				}
			}
			Gui.TreePop();
			return clicked;
		}

		static StringView TopLevel(StringView cat)
		{
			int bar = cat.IndexOf('|');
			var s = (bar >= 0) ? cat.Substring(0, bar) : cat;
			s.Trim();
			return s;
		}

		void SetHighlight(NodeItem item)
		{
			// Free-form items are rebuilt with the search text: remember those by label.
			mHighlightCustom = item != null && item.Category == "Custom";
			mHighlight = mHighlightCustom ? null : item;
			mHighlightLabel.Set((item != null) ? item.Label : "");
		}

		/// Free-form items are matched by label.
		bool IsHighlighted(NodeItem item) => (mHighlight != null && item == mHighlight) ||
			(mHighlightCustom && item.Category == "Custom" && item.Label == mHighlightLabel);

		uint32 ItemColor(NodeItem item)
		{
			switch (item.Kind)
			{
			case .GetVar, .SetVar, .GetField: return TypeRules.PinColor(item.B);
			case .CallMethod, .CallInstance, .CallCustom, .CallMember:
				if (item.Pure)
					return Theme.HeaderPure;
				return (item.C.IsEmpty || item.C == "void") ? Theme.HeaderCall : Theme.HeaderPure;
			case .Branch, .While, .DoWhile, .For, .ForEach, .Break, .Continue, .Return, .Switch, .Flow, .LoopBreak,
				 .Defer, .Using, .ResultMatch, .Scope: return Gui.Color(200, 200, 200);
			case .LocalFunc: return Theme.HeaderCall;
			case .Delete: return Theme.HeaderCall;
			case .Expr: return TypeRules.PinColor(item.B);
			default: return Theme.HeaderPure;
			}
		}

		// ------------------------------------------------------------------ auto-wiring

		/// Connects a node just created from the menu to the pin the menu was dragged from,
		/// choosing the best pin by kind and type (UE's auto-wiring). Exec chains keep their
		/// continuation; a statement spawned from a data output of a statement is inserted after it.
		public static void WireToContext(VisualBeef.Graph.Graph g, Node n, Pin ctx, NodeItem item)
		{
			if (ctx == null || n == null)
				return;
			if (ctx.Kind == .Exec)
			{
				if (!ctx.IsInput)
				{
					let execIn = n.ExecIn;
					if (execIn == null)
						return;
					let oldNext = g.ExecTarget(ctx);
					g.Connect(ctx, execIn);
					if (oldNext != null && n.Then != null)
						g.Connect(n.Then, oldNext.ExecIn);
				}
				else
				{
					// Dragged from an exec input: the new node runs before it.
					Pin outPin = n.Then;
					if (outPin == null)
						for (let p in n.Outputs)
							if (p.Kind == .Exec)
							{
								outPin = p;
								break;
							}
					if (outPin == null)
						return;
					let prevLink = g.FindLinkTo(ctx);
					let prev = prevLink?.From;
					g.Connect(outPin, ctx);
					if (prev != null && n.ExecIn != null && prev.Owner != n)
						g.Connect(prev, n.ExecIn);
				}
				return;
			}

			String ctxType = scope .();
			NormalizeType(ctx.TypeName, ctxType);
			if (!ctx.IsInput)
			{
				// Data output -> an input of the new node.
				Pin best = null;
				int32 bestScore = -1;
				bool wantsTarget = item != null && (item.Kind == .CallInstance || item.Kind == .GetField || item.Kind == .GetMember ||
					item.Kind == .CallMember || item.Kind == .Index);
				for (let p in n.Inputs)
				{
					if (p.Kind != .Data)
						continue;
					if (!VisualBeef.Graph.Graph.TypesCompatible(ctx, p))
						continue;
					int32 score = TypeMatch(ctx.TypeName, p.TypeName) * 10;
					if (p.Name == "target")
						score = wantsTarget ? 100 : -5;
					else if (score == 0 && !IsWild(p.TypeName) && !IsWild(ctxType))
						score = -1;
					if (n.Kind == .ForEach && p.Name == "collection")
						score = 50;
					if (g.IsLinked(p))
						score -= 3;
					if (score > bestScore)
					{
						best = p;
						bestScore = score;
					}
				}
				if (best == null)
					return;
				if (n.Kind == .Set && best.Name == "target")
				{
					// Never wire a value into the variable slot of a Set.
					let v = n.FindInput("value");
					if (v != null)
						best = v;
				}
				g.Connect(ctx, best);

				// A statement made from a value of another statement runs right after it (or at the
				// start of its loop body for loop elements), like UE.
				let src = ctx.Owner;
				if (n.ExecIn != null && !g.IsLinked(n.ExecIn) && src.IsExecNode)
				{
					Pin after = src.FindOutput("body");
					if (after == null || (ctx.Name != "element" && ctx.Name != "counter"))
						after = src.Then;
					if (after != null)
					{
						let oldNext = g.ExecTarget(after);
						g.Connect(after, n.ExecIn);
						if (oldNext != null && n.Then != null && oldNext != n)
							g.Connect(n.Then, oldNext.ExecIn);
					}
				}
			}
			else
			{
				// Data input <- an output of the new node.
				Pin best = null;
				int32 bestScore = -1;
				for (let p in n.Outputs)
				{
					if (p.Kind != .Data)
						continue;
					if (!VisualBeef.Graph.Graph.TypesCompatible(p, ctx))
						continue;
					int32 score = TypeMatch(p.TypeName, ctx.TypeName) * 10;
					if (p.Name == "result" || p.Name == "variable")
						score += 5;
					if (score > bestScore)
					{
						best = p;
						bestScore = score;
					}
				}
				if (best != null)
					g.Connect(best, ctx);
			}
		}
	}
}
