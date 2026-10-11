using System;
using System.Collections;
using System.Diagnostics;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Catalog
{
	struct TypeHandle
	{
		public SymbolStore Store;
		public int32 Index;

		public bool IsValid => Store != null && Index >= 0;
		public static TypeHandle Invalid => .() { Store = null, Index = -1 };
		public ref TypeRec Rec => ref Store.Types[Index];
	}

	struct MemberHandle
	{
		public SymbolStore Store;
		public int32 Index;

		public ref MemberRec Rec => ref Store.Members[Index];
	}

	/// Where a name is being resolved: the file's `using`s, the enclosing namespace and type.
	class ResolveContext
	{
		public List<String> Usings = new .() ~ DeleteContainerAndItems!(_);
		public String Namespace = new .() ~ delete _;
		public String OwnerType = new .() ~ delete _;

		/// Context of code inside `owner` (a type member of `unit`, may be null).
		public static ResolveContext Make(CompilationUnit unit, Member owner)
		{
			ResolveContext ctx = new .();
			if (unit != null)
				Collect(unit, unit.Members, "", owner, ctx);
			if (owner != null)
				ctx.OwnerType.Set(owner.Name);
			return ctx;
		}

		static bool Collect(CompilationUnit unit, List<Member> members, StringView ns, Member owner, ResolveContext ctx)
		{
			for (let m in members)
			{
				if (m.Kind == .Using)
				{
					var text = unit.NodeText(m);
					if (text.StartsWith("using"))
						text = text.Substring(5);
					if (text.EndsWith(';'))
						text.RemoveFromEnd(1);
					text.Trim();
					ctx.Usings.Add(new String(text));
				}
				else if (m.Kind == .Namespace && m.Members != null)
				{
					String inner = scope .(ns);
					var nm = StringView(m.Name);
					nm.Trim();
					if (!inner.IsEmpty && !nm.IsEmpty)
						inner.Append('.');
					inner.Append(nm);
					if (Collect(unit, m.Members, inner, owner, ctx))
						return true;
				}
				else if (m.Kind == .Type)
				{
					if (m == owner)
					{
						ctx.Namespace.Set(ns);
						return true;
					}
					if (m.Members != null && owner != null && owner.FirstTok > m.FirstTok && owner.LastTok <= m.LastTok)
					{
						if (Collect(unit, m.Members, ns, owner, ctx))
							return true;
					}
				}
			}
			return false;
		}
	}

	/// Types without a compiler (step A): resolves type names (namespaces, usings, nested types,
	/// primitives), members through base classes and extensions, overloads by arity then argument
	/// types, and generic arguments (`List<int>.Add(T)` takes an int). Owns the project's symbol
	/// store (rebuilt when the ProjectIndex changes), the library stores and the NodeCatalog.
	class TypeService : ITypeHierarchy
	{
		static int Rank(Conversion c) => (c == .Exact) ? 3 : (c == .Implicit) ? 2 : (c == .Unchecked) ? 1 : 0;

		/// The service the graph builder and wire checks use (set by the editor or a test).
		public static TypeService Current;

		public ProjectIndex Project;
		public SymbolStore ProjectStore = new .() ~ delete _;
		public List<SymbolStore> Libraries = new .() ~ DeleteContainerAndItems!(_);
		public NodeCatalog Catalog ~ delete _;
		/// Find and load corlib/BeefLibs/workspace dependencies when the project root changes.
		public bool AutoLoadLibraries = true;
		/// Milliseconds spent loading libraries for the current root, and how many came from cache.
		public double LibraryLoadMs;
		public int LibraryCacheHits;
		/// Bumped when any store changes (the action menu rebuilds its view).
		public int32 Generation;

		int32 mProjectVersion = -1;
		String mLibraryRoot = new .() ~ delete _;
		bool mLibrariesLoaded;

		/// Materialized signatures handed to the graph builder; freed two generations later so a
		/// caller holding one across a nested lookup never sees it deleted.
		List<SymbolMethod> mMaterialized = new .() ~ DeleteContainerAndItems!(_);
		List<SymbolMethod> mOldMaterialized = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, SymbolMethod> mCallCache = new .() ~ DeleteDictionaryAndKeys!(_);
		Dictionary<String, String> mKindCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		Dictionary<String, bool> mSubtypeCache = new .() ~ DeleteDictionaryAndKeys!(_);

		public this(ProjectIndex project)
		{
			Project = project;
			ProjectStore.Name.Set("Project");
			Catalog = new NodeCatalog(this);
		}

		public ~this()
		{
			if (Current == this)
				Current = null;
			if (TypeRules.Hierarchy == this)
				TypeRules.Hierarchy = null;
		}

		/// Makes this the service used by GraphBuilder and wire checks.
		public void Install()
		{
			Current = this;
			TypeRules.Hierarchy = this;
		}

		void NewGeneration()
		{
			ClearAndDeleteItems!(mOldMaterialized);
			Swap!(mOldMaterialized, mMaterialized);
			for (let kv in mCallCache)
				delete kv.key;
			mCallCache.Clear();
			for (let kv in mKindCache)
			{
				delete kv.key;
				delete kv.value;
			}
			mKindCache.Clear();
			for (let kv in mSubtypeCache)
				delete kv.key;
			mSubtypeCache.Clear();
			Generation++;
		}

		/// Brings the stores up to date with the project index (cheap when nothing changed).
		public void Sync()
		{
			if (Project != null && AutoLoadLibraries && !Project.Root.IsEmpty && (!mLibrariesLoaded || !ProjectIndex.SamePath(mLibraryRoot, Project.Root)))
				LoadLibrariesFor(Project.Root);
			if (Project != null && Project.Version != mProjectVersion)
			{
				mProjectVersion = Project.Version;
				ProjectStore.BuildFrom(Project);
				ProjectStore.Name.Set("Project");
				NewGeneration();
			}
		}

		/// Discovers and loads (or parses and caches) every library the folder depends on.
		public void LoadLibrariesFor(StringView root)
		{
			mLibraryRoot.Set(root);
			mLibrariesLoaded = true;
			ClearAndDeleteItems!(Libraries);
			let sw = scope Stopwatch(true);
			List<LibraryRef> libs = scope .();
			defer { ClearAndDeleteItems!(libs); }
			// Generated SDKs under the root were skipped by the project index: load them as libraries.
			LibraryIndex.Discover(root, libs, (Project != null && ProjectIndex.SamePath(Project.Root, root)) ? Project.GeneratedLibraries : null);
			LibraryCacheHits = 0;
			for (let lib in libs)
			{
				let store = LibraryIndex.Load(lib);
				if (store == null)
					continue;
				if (LibraryIndex.LastWasCacheHit)
					LibraryCacheHits++;
				Libraries.Add(store);
			}
			LibraryLoadMs = sw.Elapsed.TotalMilliseconds;
			NewGeneration();
		}

		/// Replaces every library with stores loaded elsewhere (the editor's background IndexJob)
		/// for `root`. Takes ownership of the stores and empties `stores`.
		public void SetLibraries(List<SymbolStore> stores, StringView root, double loadMs = 0, int cacheHits = 0)
		{
			ClearAndDeleteItems!(Libraries);
			Libraries.AddRange(stores);
			stores.Clear();
			mLibraryRoot.Set(root);
			mLibrariesLoaded = true;
			LibraryLoadMs = loadMs;
			LibraryCacheHits = cacheHits;
			NewGeneration();
		}

		/// Adds an already-built store (tests, or a host that loads libraries itself).
		public void AddLibrary(SymbolStore store)
		{
			mLibrariesLoaded = true;
			if (Project != null)
				mLibraryRoot.Set(Project.Root);
			Libraries.Add(store);
			NewGeneration();
		}

		public void AllStores(List<SymbolStore> outStores)
		{
			outStores.Add(ProjectStore);
			outStores.AddRange(Libraries);
		}

		// ------------------------------------------------------------------ types

		static void StripDecorations(StringView typeText, String outType)
		{
			TypeRules.Normalize(typeText, outType);
			while (outType.EndsWith('?') || outType.EndsWith('*'))
				outType.RemoveFromEnd(1);
			if (outType.EndsWith(']'))
			{
				int br = outType.IndexOf('[');
				if (br > 0)
					outType.RemoveToEnd(br);
			}
		}

		/// The number of generic arguments written in `t` (0 when none) and the name without them in
		/// `outName`. A tuple argument `(int, int)` is one argument, however many commas it holds.
		public static int GenericArgs(StringView t, String outName)
		{
			int count = 0;
			int depth = 0;
			int nest = 0; // inside (...) or [...]
			for (let c in t.RawChars)
			{
				if (c == '(' || c == '[')
					nest++;
				else if (c == ')' || c == ']')
					nest--;
				if (nest > 0 && depth > 0)
					continue;
				if (c == '<')
				{
					if (depth == 0)
						count = 1;
					depth++;
					continue;
				}
				if (c == '>')
				{
					depth--;
					continue;
				}
				if (depth == 1 && nest == 0 && c == ',')
					count++;
				if (depth == 0)
					outName.Append(c);
			}
			return count;
		}

		/// Finds the declaration of a type name as seen from `ctx` (null = no context).
		public TypeHandle FindType(StringView typeText, ResolveContext ctx = null)
		{
			Sync();
			String t = scope .();
			StripDecorations(typeText, t);
			if (t.IsEmpty || TypeRules.IsUnknown(t))
				return .Invalid;
			// Generic arguments don't take part in the lookup.
			String noArgs = scope .();
			int genericCount = GenericArgs(t, noArgs);
			StringView simple = noArgs;
			StringView qualifier = "";
			int dot = noArgs.LastIndexOf('.');
			if (dot >= 0)
			{
				simple = noArgs.Substring(dot + 1);
				qualifier = noArgs.Substring(0, dot);
			}
			let prim = TypeRules.PrimitiveStruct(simple);
			bool isPrimitive = prim != simple;
			if (isPrimitive)
			{
				simple = prim;
				qualifier = "System";
			}

			TypeHandle best = .Invalid;
			int bestScore = -1;
			List<SymbolStore> stores = scope .();
			AllStores(stores);
			for (let store in stores)
			{
				for (let ti in store.TypesNamed(simple))
				{
					let rec = ref store.Types[ti];
					let kind = store.Str(rec.Kind);
					let ns = store.Str(rec.Namespace);
					let outer = store.Str(rec.Outer);
					int score = 1;
					if (!qualifier.IsEmpty)
					{
						// "A.B.Type": namespace "A.B", or outer type "B" (in namespace "A").
						if (ns == qualifier || ns.EndsWith(scope $".{qualifier}"))
							score = 6;
						else if (outer == qualifier || qualifier.EndsWith(scope $".{outer}") && !outer.IsEmpty)
							score = 6;
						else
							continue;
					}
					else if (ctx != null)
					{
						if (!ctx.OwnerType.IsEmpty && outer == ctx.OwnerType)
							score = 7; // nested in the current type
						else if (ns == ctx.Namespace)
							score = 6;
						else if (!ns.IsEmpty && ctx.Namespace.StartsWith(ns) && (ctx.Namespace.Length == ns.Length || ctx.Namespace[ns.Length] == '.'))
							score = 5;
						else if (ctx.Usings.Contains(scope String(ns)))
							score = 4;
						else if (ns.IsEmpty)
							score = 3;
						else if (ns == "System")
							score = 2; // corlib's System is what most code means
					}
					else if (ns == "System" || ns.IsEmpty)
						score = 2;
					if (kind == "extension")
						score -= 3; // the declaration itself is preferred over extensions
					int arity = 0;
					let gp = store.Str(rec.GenericParams);
					if (!gp.IsEmpty)
					{
						arity = 1;
						for (let c in gp.RawChars)
							if (c == ',')
								arity++;
					}
					if (arity == genericCount)
						score += 1;
					if (score > bestScore)
					{
						bestScore = score;
						best = .() { Store = store, Index = ti };
					}
				}
			}
			return best;
		}

		/// The `using`s and namespace a type's own declaration sees (for its base list).
		ResolveContext ContextOf(TypeHandle t)
		{
			ResolveContext ctx = new .();
			List<StringView> usings = scope .();
			t.Store.Usings(t.Rec.File, usings);
			for (let u in usings)
				ctx.Usings.Add(new String(u));
			ctx.Namespace.Set(t.Store.Str(t.Rec.Namespace));
			ctx.OwnerType.Set(t.Store.Str(t.Rec.Name));
			return ctx;
		}

		/// Generic parameter -> argument for a use of a type ("List<int>" on List<T>: T -> int).
		void GenericMap(TypeHandle t, StringView typeText, Dictionary<String, String> map)
		{
			let gp = t.Store.Str(t.Rec.GenericParams);
			if (gp.IsEmpty)
				return;
			String norm = scope .();
			TypeRules.Normalize(typeText, norm);
			List<StringView> args = scope .();
			TypeRules.GenericArgs(norm, args);
			int i = 0;
			for (var name in gp.Split(','))
			{
				name.Trim();
				if (i < args.Count && !map.ContainsKeyAlt(name))
				{
					String value = new .();
					Substitute(args[i], map, value);
					map[new String(name)] = value;
				}
				i++;
			}
		}

		static void Substitute(StringView text, Dictionary<String, String> map, String outText)
		{
			TypeRules.Substitute(text, map, outText);
		}

		/// Each type that contributes members to `t`: itself, extensions of it, then its bases
		/// (with their generic maps). `visit` returns false to stop.
		/// Visits `t` and everything it inherits (extensions and partial declarations, base types,
		/// interfaces), most derived first, with each type's generic map (`T` -> `int` for
		/// `Base<int>`). Return false from `visit` to stop. Used by ClassModel.
		/// `outUnresolved` (optional) receives every base type name met on the way that could not
		/// be found, so callers can tell "no such member" from "not everything is known".
		public void VisitHierarchy(TypeHandle t, StringView useText, delegate bool(TypeHandle type, Dictionary<String, String> map) visit, List<String> outUnresolved = null)
		{
			mUnresolvedSink = outUnresolved;
			defer { mUnresolvedSink = null; }
			WalkHierarchy(t, useText, visit);
		}

		List<String> mUnresolvedSink;

		void WalkHierarchy(TypeHandle t, StringView useText, delegate bool(TypeHandle type, Dictionary<String, String> map) visit)
		{
			HashSet<int> seen = scope .();
			Dictionary<String, String> map = scope .();
			defer { for (let kv in map) { delete kv.key; delete kv.value; } }
			GenericMap(t, useText, map);
			WalkRec(t, map, seen, visit, 0);
		}

		bool WalkRec(TypeHandle t, Dictionary<String, String> map, HashSet<int> seen, delegate bool(TypeHandle, Dictionary<String, String>) visit, int depth)
		{
			if (depth > 10)
				return true;
			int key = (int)Internal.UnsafeCastToPtr(t.Store) * 31 + t.Index;
			if (!seen.Add(key))
				return true;
			if (!visit(t, map))
				return false;
			// Extensions and partial declarations with the same name and namespace.
			let name = t.Store.Str(t.Rec.Name);
			let ns = t.Store.Str(t.Rec.Namespace);
			List<SymbolStore> stores = scope .();
			AllStores(stores);
			for (let store in stores)
			{
				for (let ti in store.TypesNamed(name))
				{
					if (store == t.Store && ti == t.Index)
						continue;
					let rec = ref store.Types[ti];
					let kind = store.Str(rec.Kind);
					let ens = store.Str(rec.Namespace);
					if (kind != "extension" && !(store == t.Store && ens == ns && store.Str(rec.Kind) == t.Store.Str(t.Rec.Kind)))
						continue;
					if (kind == "extension" && !ens.IsEmpty && !ns.IsEmpty && ens != ns)
						continue;
					TypeHandle ext = .() { Store = store, Index = ti };
					int ekey = (int)Internal.UnsafeCastToPtr(store) * 31 + ti;
					if (!seen.Add(ekey))
						continue;
					if (!visit(ext, map))
						return false;
				}
			}
			// Bases
			let bases = t.Store.Str(t.Rec.BaseTypes);
			if (bases.IsEmpty)
				return true;
			let ctx = ContextOf(t);
			defer delete ctx;
			for (var b in bases.Split(';'))
			{
				if (b.IsEmpty)
					continue;
				String bt = scope .();
				Substitute(b, map, bt);
				let bh = FindTypeNoSync(bt, ctx);
				if (!bh.IsValid)
				{
					mUnresolvedSink?.Add(new String(bt));
					continue;
				}
				Dictionary<String, String> bmap = scope .();
				defer { for (let kv in bmap) { delete kv.key; delete kv.value; } }
				GenericMap(bh, bt, bmap);
				if (!WalkRec(bh, bmap, seen, visit, depth + 1))
					return false;
			}
			return true;
		}

		TypeHandle FindTypeNoSync(StringView typeText, ResolveContext ctx) => FindType(typeText, ctx);

		// ------------------------------------------------------------------ members

		public struct Candidate
		{
			public MemberHandle Member;
			public int32 MapIndex; // index into a list of generic maps owned by the caller
		}

		/// Methods named `name` on a type (its extensions and bases included).
		public void FindMethods(TypeHandle t, StringView typeText, StringView name, List<MemberHandle> outMembers, List<Dictionary<String, String>> outMaps)
		{
			WalkHierarchy(t, typeText, scope [&] (type, map) =>
			{
				let rec = ref type.Rec;
				for (int mi = rec.FirstMember; mi < rec.FirstMember + rec.MemberCount; mi++)
				{
					let m = ref type.Store.Members[mi];
					if (!m.IsMethod || type.Store.Str(m.Name) != name)
						continue;
					outMembers.Add(.() { Store = type.Store, Index = (int32)mi });
					Dictionary<String, String> copy = new .();
					for (let kv in map)
						copy[new String(kv.key)] = new String(kv.value);
					outMaps.Add(copy);
				}
				return true;
			});
		}

		/// The type of a field or property `name` on `typeText` (generic arguments applied).
		public bool FindMemberType(StringView typeText, StringView name, ResolveContext ctx, String outType)
		{
			let t = FindType(typeText, ctx);
			if (!t.IsValid)
				return false;
			bool found = false;
			WalkHierarchy(t, typeText, scope [&] (type, map) =>
			{
				let rec = ref type.Rec;
				for (int mi = rec.FirstMember; mi < rec.FirstMember + rec.MemberCount; mi++)
				{
					let m = ref type.Store.Members[mi];
					if (m.IsMethod || type.Store.Str(m.Name) != name)
						continue;
					Substitute(type.Store.Str(m.Type), map, outType);
					found = true;
					return false;
				}
				return true;
			});
			return found;
		}

		/// Minimum and maximum argument counts (max = int.MaxValue with `params`).
		public static void Arity(MemberHandle m, out int minArgs, out int maxArgs)
		{
			let rec = ref m.Rec;
			minArgs = 0;
			maxArgs = rec.ParamCount;
			for (int i < rec.ParamCount)
			{
				let p = ref m.Store.Params[rec.FirstParam + i];
				let mod = m.Store.Str(p.Modifier);
				if (mod.Contains("params"))
				{
					maxArgs = int.MaxValue;
					continue;
				}
				if (p.Default.IsEmpty)
					minArgs = i + 1;
			}
		}

		/// The last ChooseOverload found another candidate with the best score (a tie).
		public bool LastChoiceTied;

		/// Picks the overload for `argCount` arguments of the given types (null/"" = unknown):
		/// arity first, then the best conversion score.
		/// The candidates that scored as well as the pick in the last ChooseOverload (the pick first).
		public List<int> LastTied = new .() ~ delete _;

		public int ChooseOverload(List<MemberHandle> candidates, List<Dictionary<String, String>> maps, int argCount, List<String> argTypes)
		{
			int best = -1;
			int bestScore = int.MinValue;
			LastChoiceTied = false;
			LastTied.Clear();
			for (int ci < candidates.Count)
			{
				let m = candidates[ci];
				int score = 0;
				if (argCount >= 0)
				{
					Arity(m, var minArgs, var maxArgs);
					if (argCount < minArgs || argCount > maxArgs)
						continue;
					if (argCount == m.Rec.ParamCount)
						score += 4;
				}
				if (argTypes != null)
				{
					let rec = ref m.Rec;
					for (int ai < argTypes.Count)
					{
						let at = argTypes[ai];
						if (at == null || at.IsEmpty)
							continue;
						if (rec.ParamCount == 0)
							break;
						int pi = Math.Min(ai, rec.ParamCount - 1);
						let p = ref m.Store.Params[rec.FirstParam + pi];
						String pt = scope .();
						Substitute(m.Store.Str(p.Type), maps[ci], pt);
						var conv = TypeRules.CanConvert(at, pt, null, this);
						// `params T[]` / `params Span<T>`: an argument may be the array itself (normal
						// form) or one element (expanded form); score the better of the two.
						if (m.Store.Str(p.Modifier).Contains("params"))
						{
							StringView elem = pt;
							if (pt.EndsWith("[]"))
								elem = StringView(pt, 0, pt.Length - 2);
							else if (pt.StartsWith("Span<") && pt.EndsWith('>'))
								elem = StringView(pt, 5, pt.Length - 6);
							let e = TypeRules.CanConvert(at, elem, null, this);
							if (Rank(e) > Rank(conv))
								conv = e;
						}
						// Scores are doubled so that one rule can break a tie without changing any
						// other order: a value taken as `Object` (the root every value converts to)
						// fits less well than any other implicit conversion, as in Beef, where
						// `Console.WriteLine("x")` calls WriteLine(StringView) and not WriteLine(Object).
						switch (conv)
						{
						case .Exact: score += 8;
						case .Implicit: score += (TypeRules.BaseName(pt) == "Object" && TypeRules.BaseName(at) != "Object") ? 3 : 4;
						case .Unchecked: score += 2;
						case .Refused: score -= 200;
						}
					}
				}
				// Prefer instance members of the type itself over inherited ones: earlier wins ties.
				if (score > bestScore)
				{
					bestScore = score;
					best = ci;
					LastChoiceTied = false;
					LastTied.Clear();
					LastTied.Add(ci);
				}
				else if (score == bestScore && !SameParams(candidates[best], m))
				{
					LastChoiceTied = true;
					LastTied.Add(ci);
				}
			}
			return best;
		}

		/// Two members with the same parameter types (an override, or the same declaration seen
		/// twice): not a real choice.
		static bool SameParams(MemberHandle a, MemberHandle b)
		{
			let ra = ref a.Rec;
			let rb = ref b.Rec;
			if (ra.ParamCount != rb.ParamCount)
				return false;
			for (int i < ra.ParamCount)
			{
				let pa = ref a.Store.Params[ra.FirstParam + i];
				let pb = ref b.Store.Params[rb.FirstParam + i];
				if (a.Store.Str(pa.Type) != b.Store.Str(pb.Type) || a.Store.Str(pa.Modifier) != b.Store.Str(pb.Modifier))
					return false;
			}
			return true;
		}

		/// A SymbolMethod for the graph builder: generic arguments applied, pin labels from
		/// [Pin(Name=...)]. Owned by the service (valid until two generations later).
		public SymbolMethod Materialize(MemberHandle m, Dictionary<String, String> map)
		{
			let rec = ref m.Rec;
			let s = m.Store;
			SymbolMethod sm = new .();
			mMaterialized.Add(sm);
			sm.Name.Set(s.Str(rec.Name));
			if (rec.Owner >= 0 && rec.Owner < s.Types.Count)
				sm.OwnerType.Set(s.Str(s.Types[rec.Owner].Name));
			Substitute(s.Str(rec.Type), map, sm.ReturnType);
			sm.IsStatic = rec.IsStatic;
			sm.IsCtor = rec.Kind == .Ctor;
			sm.IsMixin = rec.IsMixin;
			sm.HasBody = (rec.Flags & MemberRec.cHasBody) != 0;
			sm.IsVirtual = rec.IsVirtual;
			sm.IsAbstract = rec.IsAbstract;
			sm.IsOverride = rec.IsOverride;
			sm.IsSealed = (rec.Flags & MemberRec.cSealed) != 0;
			sm.Visibility = rec.Visibility;
			sm.Line = rec.Line;
			sm.Attributes.Set(s.Str(rec.Attributes));
			sm.Doc.Set(s.Str(rec.Doc));
			sm.GenericParams.Set(s.Str(rec.GenericParams));
			List<AttrInfo> attrs = scope .();
			defer { ClearAndDeleteItems!(attrs); }
			for (int i < rec.ParamCount)
			{
				let p = ref s.Params[rec.FirstParam + i];
				String type = new .();
				Substitute(s.Str(p.Type), map, type);
				String label = new .(s.Str(p.Name));
				let pa = s.Str(p.Attributes);
				if (!pa.IsEmpty)
				{
					ClearAndDeleteItems!(attrs);
					AttributeParser.Parse(pa, attrs);
					let pin = AttributeParser.Find(attrs, "Pin");
					if (pin != null)
					{
						let n = pin.Get("Name", 0);
						if (!n.IsEmpty)
							label.Set(n);
					}
				}
				if (i > 0)
					sm.ParamsText.Append(", ");
				let mod = s.Str(p.Modifier);
				if (!mod.IsEmpty)
					sm.ParamsText.AppendF("{} ", mod);
				sm.ParamsText.AppendF("{} {}", type, s.Str(p.Name));
				sm.ParamNames.Add(label);
				sm.ParamTypes.Add(type);
				sm.ParamDefaults.Add(new String(s.Str(p.Default)));
				sm.ParamModifiers.Add(new String(mod));
				sm.ParamAttributes.Add(new String(pa));
			}
			return sm;
		}

		/// Resolves a call for the graph builder.
		///   staticType: `Type.Method()` (the text before the dot names a type), else empty
		///   targetType: the inferred type of the call target for `value.Method()`, else empty
		///   neither:    a call without target (the owner type, its bases, global functions)
		/// argCount < 0 = unknown; argTypes entries may be empty.
		public SymbolMethod ResolveCall(StringView staticType, StringView targetType, StringView name, int argCount, List<String> argTypes, ResolveContext ctx)
		{
			Sync();
			String key = scope .();
			key.AppendF("{}|{}|{}|{}|", staticType, targetType, name, argCount);
			if (argTypes != null)
				for (let a in argTypes)
					key.AppendF("{},", a);
			if (ctx != null)
				key.AppendF("|{}|{}", ctx.Namespace, ctx.OwnerType);
			if (mCallCache.TryGetValue(key, let cached))
				return cached;

			List<MemberHandle> cands = scope .();
			List<Dictionary<String, String>> maps = scope .();
			defer { for (let m in maps) DeleteDictionaryAndKeysAndValues!(m); }

			if (!staticType.IsEmpty || !targetType.IsEmpty)
			{
				StringView use = staticType.IsEmpty ? targetType : staticType;
				let t = FindType(use, ctx);
				if (t.IsValid)
					FindMethods(t, use, name, cands, maps);
			}
			else
			{
				if (ctx != null && !ctx.OwnerType.IsEmpty)
				{
					let t = FindType(ctx.OwnerType, ctx);
					if (t.IsValid)
						FindMethods(t, ctx.OwnerType, name, cands, maps);
				}
				if (cands.IsEmpty)
				{
					// Global functions (`static { }` blocks) and `using static` types.
					List<SymbolStore> stores = scope .();
					AllStores(stores);
					for (let store in stores)
						for (let ti in store.TypesNamed("Globals"))
							if (store.Str(store.Types[ti].Kind) == "static")
								FindMethods(.() { Store = store, Index = ti }, "Globals", name, cands, maps);
					if (ctx != null)
					{
						for (let u in ctx.Usings)
						{
							if (!u.StartsWith("static "))
								continue;
							let t = FindType(StringView(u, 7), ctx);
							if (t.IsValid)
								FindMethods(t, StringView(u, 7), name, cands, maps);
						}
					}
				}
			}
			SymbolMethod result = null;
			if (!cands.IsEmpty)
			{
				int pick = ChooseOverload(cands, maps, argCount, argTypes);
				// A tie only means something when every argument type is known.
				bool allKnown = argTypes != null && argCount >= 0;
				if (argTypes != null)
					for (let a in argTypes)
						if (a == null || a.IsEmpty || TypeRules.IsWildcard(a))
							allKnown = false;
				bool tied = LastChoiceTied && allKnown;
				if (pick < 0 && argCount >= 0)
					pick = -1; // no overload takes that many arguments
				if (pick >= 0)
				{
					// Method generics bind from the arguments: Max<T>(1, 2) returns an int.
					let m = cands[pick];
					let gp = m.Store.Str(m.Rec.GenericParams);
					if (!gp.IsEmpty && argTypes != null)
					{
						let map = maps[pick];
						for (int ai < Math.Min(argTypes.Count, m.Rec.ParamCount))
						{
							let at = argTypes[ai];
							if (at == null || TypeRules.IsWildcard(at))
								continue;
							var pt = m.Store.Str(m.Store.Params[m.Rec.FirstParam + ai].Type);
							pt.Trim();
							if (!TypeRules.IsGenericParam(pt, gp) || map.ContainsKeyAlt(pt))
								continue;
							map[new String(pt)] = new String(at);
						}
					}
					result = Materialize(m, maps[pick]);
					result.Ambiguous = tied;
					if (tied)
					{
						result.Candidates = new .();
						for (let ci in LastTied)
						{
							let c = Materialize(cands[ci], maps[ci]);
							String sig = new .();
							sig.AppendF("{}(", c.Name);
							for (int pi < c.ParamTypes.Count)
							{
								if (pi > 0)
									sig.Append(", ");
								if (!c.ParamModifiers[pi].IsEmpty)
									sig.AppendF("{} ", c.ParamModifiers[pi]);
								sig.AppendF("{} {}", c.ParamTypes[pi], c.ParamNames[pi]);
							}
							sig.Append(')');
							result.Candidates.Add(sig);
						}
					}
				}
			}
			mCallCache[new String(key)] = result;
			return result;
		}

		// ------------------------------------------------------------------ ITypeHierarchy

		public void KindOf(StringView typeName, String outKind)
		{
			String key = scope .();
			TypeRules.Normalize(typeName, key);
			if (mKindCache.TryGetValue(key, let kind))
			{
				outKind.Append(kind);
				return;
			}
			let t = FindType(key, null);
			String k = new .();
			if (t.IsValid)
				k.Set(t.Store.Str(t.Rec.Kind));
			// An extension says nothing about what the type is.
			if (k == "extension")
				k.Clear();
			mKindCache[new String(key)] = k;
			outKind.Append(k);
		}

		public bool IsSubtype(StringView derived, StringView baseType)
		{
			String key = scope .();
			key.AppendF("{}>{}", derived, baseType);
			if (mSubtypeCache.TryGetValue(key, let r))
				return r;
			let t = FindType(derived, null);
			bool result = false;
			if (t.IsValid)
			{
				let want = TypeRules.BaseName(baseType);
				WalkHierarchy(t, derived, scope [&] (type, map) =>
				{
					if (type.Index != t.Index || type.Store != t.Store)
					{
						if (type.Store.Str(type.Rec.Name) == want)
						{
							result = true;
							return false;
						}
					}
					return true;
				});
			}
			mSubtypeCache[new String(key)] = result;
			return result;
		}
	}
}
