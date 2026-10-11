using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Catalog
{
	enum InheritedKind : uint8
	{
		Method,
		Property,
		Indexer
	}

	/// A member a type can override or must implement: a virtual / abstract / override member of
	/// its base chain, or a member of an interface it lists. Generic parameters of the base are
	/// already substituted (`T` -> `int` for `: Base<int>`).
	class InheritedMember
	{
		public InheritedKind Kind;
		public String Name = new .() ~ delete _;
		/// The type that declares it ("UMPMod", "IDamageable").
		public String OwnerType = new .() ~ delete _;
		/// Method return type, property / indexer type.
		public String ReturnType = new .() ~ delete _;
		public List<String> ParamTypes = new .() ~ DeleteContainerAndItems!(_);
		public List<String> ParamNames = new .() ~ DeleteContainerAndItems!(_);
		public List<String> ParamModifiers = new .() ~ DeleteContainerAndItems!(_);
		public bool IsAbstract;
		public bool IsVirtual;
		public bool IsOverride;
		public bool FromInterface;
		public bool HasSetter;
		public SymbolVisibility Visibility;

		public bool IsVoid => ReturnType.IsEmpty || ReturnType == "void";

		/// "Tick(float)", "Score", "this[int]": what decides "already implemented".
		public void Signature(String o)
		{
			ClassModel.MakeSignature(Kind, Name, ParamTypes, ParamModifiers, o);
		}

		/// "float DeltaSeconds, out int value"
		public void ParamsText(String o)
		{
			for (int i < ParamTypes.Count)
			{
				if (i > 0)
					o.Append(", ");
				if (!ParamModifiers[i].IsEmpty)
					o.AppendF("{} ", ParamModifiers[i]);
				o.AppendF("{} {}", ParamTypes[i], ParamNames[i]);
			}
		}

		/// "DeltaSeconds, out value" (a call passing the parameters on).
		public void ArgsText(String o)
		{
			for (int i < ParamNames.Count)
			{
				if (i > 0)
					o.Append(", ");
				let mod = ParamModifiers[i];
				if (mod.Contains("out"))
					o.Append("out ");
				else if (mod.Contains("ref"))
					o.Append("ref ");
				o.Append(ParamNames[i]);
			}
		}

		/// "void Tick(float DeltaSeconds)" / "int Score { get; set; }"
		public void Display(String o)
		{
			switch (Kind)
			{
			case .Method:
				o.AppendF("{} {}(", IsVoid ? "void" : ReturnType, Name);
				ParamsText(o);
				o.Append(')');
			case .Property:
				o.AppendF("{} {} {{ get;{} }}", ReturnType, Name, HasSetter ? " set;" : "");
			case .Indexer:
				o.AppendF("{} this[", ReturnType);
				ParamsText(o);
				o.AppendF("] {{ get;{} }}", HasSetter ? " set;" : "");
			}
		}
	}

	/// What ClassModel.Analyze found out about a type declaration.
	class ClassInfo
	{
		public String TypeName = new .() ~ delete _;
		public String Kind = new .() ~ delete _;
		public bool IsAbstract;
		/// The base class (structs: base struct) as written; "" when none.
		public String BaseClass = new .() ~ delete _;
		/// Interfaces of the base list as written.
		public List<String> Interfaces = new .() ~ DeleteContainerAndItems!(_);
		/// Base names (here or further up) that no index knows: nothing is reported as missing
		/// while this is not empty (the compiler stays the judge).
		public List<String> Unresolved = new .() ~ DeleteContainerAndItems!(_);
		/// Members the Override dropdown offers: virtual / abstract members of the base chain and
		/// interface members, minus what the type declares itself.
		public List<InheritedMember> Overridable = new .() ~ DeleteContainerAndItems!(_);
		/// Members that must be implemented (abstract base members of a non-abstract class,
		/// interface members without a default body) and are not.
		public List<InheritedMember> Missing = new .() ~ DeleteContainerAndItems!(_);
		/// Document-level errors ("Enemy does not implement ..."), one line each.
		public List<String> Problems = new .() ~ DeleteContainerAndItems!(_);
		/// Own members marked `override` that have nothing to override (signatures).
		public List<String> OverridesWithoutBase = new .() ~ DeleteContainerAndItems!(_);

		/// The parent's own instance constructors the new ones can chain to with `: base(...)`:
		/// each one's parameters as written ("int a, String b"; "" for the parameterless one).
		/// Private ones are left out.
		public List<String> BaseCtors = new .() ~ DeleteContainerAndItems!(_);

		public bool Complete => Unresolved.IsEmpty;

		public InheritedMember FindOverridable(StringView signature)
		{
			String s = scope .();
			for (let m in Overridable)
			{
				s.Clear();
				m.Signature(s);
				if (s == signature)
					return m;
			}
			return null;
		}
	}

	/// One type a parent / interface picker can offer.
	struct TypeChoice
	{
		public StringView Name;
		public StringView Namespace;
		public StringView Kind;
		public StringView Library;   // "" for the project
	}

	/// The type-level model (docs/Classes-and-Members.md): base class and interfaces of a
	/// declaration, what it can override, what it still has to implement, stub text, valid
	/// parents, and the checks GraphValidator runs on `override` functions.
	static class ClassModel
	{
		public static void MakeSignature(InheritedKind kind, StringView name, List<String> paramTypes, List<String> paramMods, String o)
		{
			if (kind == .Property)
			{
				o.Append(name);
				return;
			}
			o.Append((kind == .Indexer) ? "this[" : scope String()..AppendF("{}(", name));
			String norm = scope .();
			for (int i < paramTypes.Count)
			{
				if (i > 0)
					o.Append(',');
				if (paramMods != null && i < paramMods.Count)
				{
					if (paramMods[i].Contains("out"))
						o.Append("out ");
					else if (paramMods[i].Contains("ref"))
						o.Append("ref ");
				}
				norm.Clear();
				TypeRules.Normalize(paramTypes[i], norm);
				o.Append(norm);
			}
			o.Append((kind == .Indexer) ? ']' : ')');
		}

		/// The signature of a declaration in the source (methods, properties, indexers).
		public static bool OwnSignature(Member m, String o)
		{
			if (m.Kind == .Method && !m.IsCtor && !m.IsDtor && !m.IsAccessor)
			{
				List<String> types = scope .();
				List<String> mods = scope .();
				for (let p in m.Params)
				{
					types.Add(p.Type);
					mods.Add(p.Modifier);
				}
				MakeSignature(.Method, m.Name, types, mods, o);
				return true;
			}
			if (m.Kind == .Property)
			{
				if (m.IsIndexer)
				{
					List<String> types = scope .();
					List<String> mods = scope .();
					if (m.Params != null)
					{
						for (let p in m.Params)
						{
							types.Add(p.Type);
							mods.Add(p.Modifier);
						}
					}
					MakeSignature(.Indexer, "this", types, mods, o);
				}
				else
					o.Append(m.Name);
				return true;
			}
			return false;
		}

		static void FromRec(TypeHandle t, int mi, Dictionary<String, String> map, InheritedMember im)
		{
			let s = t.Store;
			let rec = ref s.Members[mi];
			im.Name.Set(s.Str(rec.Name));
			im.OwnerType.Set(s.Str(t.Rec.Name));
			TypeRules.Substitute(s.Str(rec.Type), map, im.ReturnType);
			im.IsAbstract = rec.IsAbstract;
			im.IsVirtual = rec.IsVirtual;
			im.IsOverride = rec.IsOverride;
			im.Visibility = rec.Visibility;
			im.Kind = (rec.Kind == .Property) ? .Property : .Method;
			im.HasSetter = rec.Writable;
			for (int i < rec.ParamCount)
			{
				let p = ref s.Params[rec.FirstParam + i];
				String type = new .();
				TypeRules.Substitute(s.Str(p.Type), map, type);
				im.ParamTypes.Add(type);
				im.ParamNames.Add(new String(s.Str(p.Name)));
				im.ParamModifiers.Add(new String(s.Str(p.Modifier)));
			}
		}

		static bool IsInterface(TypeHandle t) => t.Store.Str(t.Rec.Kind) == "interface";

		/// Object's virtual functions, for when corlib is not loaded (an override of one of
		/// them cannot be checked then).
		static bool IsObjectVirtual(StringView name) => name == "ToString" || IsObjectInternal(name);

		/// Object's runtime hooks: real virtuals, but nothing a user overrides (not offered).
		static bool IsObjectInternal(StringView name) => name == "GCMarkMembers" ||
			name == "DynamicCastToTypeId" || name == "DynamicCastToInterface" || name == "DynamicCastToSignature";

		/// Reads the declaration `type` of `unit` against what the TypeService knows.
		public static void Analyze(CompilationUnit unit, Member type, TypeService svc, ClassInfo info)
		{
			info.TypeName.Set(type.Name);
			info.Kind.Set(type.TypeKind ?? "");
			info.IsAbstract = Mods.Has(type.Modifiers, "abstract");
			if (svc == null || type.Kind != .Type)
			{
				info.Unresolved.Add(new String("(no type information)"));
				return;
			}
			let kind = StringView(info.Kind);
			if (kind == "enum" || kind == "extension" || kind == "static")
				return;
			let ctx = ResolveContext.Make(unit, type);
			defer delete ctx;

			// The base list: the first class (struct) is the base, interfaces are interfaces.
			List<String> bases = scope .();
			defer { ClearAndDeleteItems!(bases); }
			if (type.BaseColonTok >= 0 && type.BaseLastTok > type.BaseColonTok)
				TypeDeclInfo.SplitTopLevel(unit, type.BaseColonTok + 1, type.BaseLastTok, bases);
			TypeHandle baseHandle = .Invalid;
			for (let b in bases)
			{
				let h = svc.FindType(b, ctx);
				if (!h.IsValid)
				{
					info.Unresolved.Add(new String(b));
					continue;
				}
				let bk = h.Store.Str(h.Rec.Kind);
				if (bk == "interface")
				{
					info.Interfaces.Add(new String(b));
					continue;
				}
				if (kind == "interface")
				{
					info.Problems.Add(new String(scope $"{type.Name} is an interface: it can only list interfaces, and {b} is {(bk == "struct" ? "a struct" : "a class")}."));
					continue;
				}
				if (!info.BaseClass.IsEmpty)
				{
					info.Problems.Add(new String(scope $"{type.Name} already derives from {info.BaseClass}: {b} is not an interface, and a type has only one base."));
					continue;
				}
				if (kind == "class" && bk == "struct")
					info.Problems.Add(new String(scope $"{type.Name} is a class and cannot derive from the struct {b}."));
				else if (kind == "struct" && bk != "struct")
					info.Problems.Add(new String(scope $"{type.Name} is a struct and can only derive from a struct; {b} is a {bk}."));
				else if ((h.Rec.TypeFlags & TypeRec.cSealed) != 0)
					info.Problems.Add(new String(scope $"{b} is sealed: {type.Name} cannot derive from it."));
				// Beef lets a static class derive from a static class (UMP's resolvers do), not anything else.
				else if ((h.Rec.TypeFlags & TypeRec.cStatic) != 0 && !type.IsStatic && !ProjectIndex.HasWord(type.Modifiers, "static"))
					info.Problems.Add(new String(scope $"{b} is a static class: {type.Name} cannot derive from it."));
				info.BaseClass.Set(b);
				baseHandle = h;
			}

			if (baseHandle.IsValid)
			{
				let brec = ref baseHandle.Rec;
				let bs = baseHandle.Store;
				for (int mi = brec.FirstMember; mi < brec.FirstMember + brec.MemberCount; mi++)
				{
					let mr = ref bs.Members[mi];
					if (mr.Kind != .Ctor || mr.IsStatic || mr.Visibility == .Private)
						continue;
					String ptext = new .();
					for (int i < mr.ParamCount)
					{
						let p = ref bs.Params[mr.FirstParam + i];
						if (i > 0)
							ptext.Append(", ");
						let pm = bs.Str(p.Modifier);
						if (!pm.IsEmpty)
							ptext.AppendF("{} ", pm);
						ptext.AppendF("{} {}", bs.Str(p.Type), bs.Str(p.Name));
					}
					info.BaseCtors.Add(ptext);
				}
			}

			// Own declarations.
			Dictionary<String, Member> own = scope .();
			defer { for (let k in own.Keys) delete k; }
			if (type.Members != null)
			{
				for (let m in type.Members)
				{
					String sig = new .();
					if (OwnSignature(m, sig) && !own.ContainsKey(sig))
						own[sig] = m;
					else
						delete sig;
				}
			}

			// The base chain (implicitly Object for a class without a base).
			Dictionary<String, InheritedMember> chain = scope .();
			List<InheritedMember> chainOrder = scope .();
			HashSet<String> implemented = scope .();
			defer
			{
				for (let k in chain.Keys) delete k;
				ClearAndDeleteItems!(chainOrder);
				for (let k in implemented) delete k;
			}
			bool checkOverrides = kind == "class";
			String chainRoot = scope .(info.BaseClass);
			if (!baseHandle.IsValid && info.BaseClass.IsEmpty && kind == "class")
			{
				baseHandle = svc.FindType("Object", ctx);
				chainRoot.Set("Object");
			}
			bool objectKnown = svc.FindType("Object", ctx).IsValid;
			delegate bool(TypeHandle, Dictionary<String, String>) visitChain = scope [&] (t, map) =>
				{
					if (IsInterface(t))
						return true;
					let rec = ref t.Rec;
					for (int mi = rec.FirstMember; mi < rec.FirstMember + rec.MemberCount; mi++)
					{
						let mr = ref t.Store.Members[mi];
						if (mr.Kind == .Ctor || mr.Kind == .Field || mr.IsStatic)
							continue;
						InheritedMember im = new .();
						FromRec(t, mi, map, im);
						String sig = scope .();
						im.Signature(sig);
						if (chain.ContainsKeyAlt(sig))
						{
							delete im;
							continue;
						}
						chain[new String(sig)] = im;
						chainOrder.Add(im);
						if (!im.IsAbstract)
							implemented.Add(new String(sig));
					}
					return true;
				};
			if (baseHandle.IsValid)
				svc.VisitHierarchy(baseHandle, chainRoot, visitChain, info.Unresolved);
			// Every class ends in Object (ToString, ...), also when its chain does not say so.
			if (kind == "class" && chainRoot != "Object")
			{
				let obj = svc.FindType("Object", ctx);
				if (obj.IsValid)
					svc.VisitHierarchy(obj, "Object", visitChain);
			}

			String sig = scope .();
			for (let im in chainOrder)
			{
				if (!(im.IsVirtual || im.IsAbstract || im.IsOverride) || im.Visibility == .Private || (im.OwnerType == "Object" && IsObjectInternal(im.Name)))
					continue;
				sig.Clear();
				im.Signature(sig);
				let mine = own.GetValueOrDefault(sig);
				if (mine == null)
				{
					info.Overridable.Add(Copy(im));
					if (im.IsAbstract && !info.IsAbstract)
						info.Missing.Add(Copy(im));
				}
			}

			// Interfaces (and the interfaces they extend).
			HashSet<String> seenIface = scope .();
			defer { for (let k in seenIface) delete k; }
			for (let iface in info.Interfaces)
			{
				let h = svc.FindType(iface, ctx);
				if (!h.IsValid)
					continue;
				svc.VisitHierarchy(h, iface, scope [&] (t, map) =>
				{
					if (!IsInterface(t))
						return true;
					let rec = ref t.Rec;
					for (int mi = rec.FirstMember; mi < rec.FirstMember + rec.MemberCount; mi++)
					{
						let mr = ref t.Store.Members[mi];
						if (mr.Kind == .Ctor || mr.Kind == .Field || mr.IsStatic)
							continue;
						InheritedMember im = new .();
						FromRec(t, mi, map, im);
						im.FromInterface = true;
						im.IsAbstract = mr.IsAbstract;
						String s = scope .();
						im.Signature(s);
						if (seenIface.Contains(s) || own.ContainsKeyAlt(s) || implemented.Contains(s))
						{
							delete im;
							continue;
						}
						seenIface.Add(new String(s));
						if (im.IsAbstract)
							info.Missing.Add(Copy(im));
						info.Overridable.Add(im);
					}
					return true;
				}, info.Unresolved);
			}

			// Own `override` members need something to override.
			if (checkOverrides && info.Unresolved.IsEmpty && type.Members != null)
			{
				for (let m in type.Members)
				{
					if (!Mods.Has(m.Modifiers, "override"))
						continue;
					sig.Clear();
					if (!OwnSignature(m, sig))
						continue;
					if (!objectKnown && IsObjectVirtual(m.Name))
						continue;
					let b = chain.GetValueOrDefault(sig);
					if (b == null || !(b.IsVirtual || b.IsAbstract || b.IsOverride))
					{
						info.OverridesWithoutBase.Add(new String(sig));
						info.Problems.Add(new String(scope $"{type.Name}.{sig} is marked override, but no base class of {type.Name} has a virtual or abstract {sig}."));
					}
				}
			}

			if (!info.Unresolved.IsEmpty)
			{
				// Something is unknown: never claim a member is missing.
				ClearAndDeleteItems!(info.Missing);
				return;
			}
			String d = scope .();
			for (let m in info.Missing)
			{
				d.Clear();
				m.Display(d);
				if (m.FromInterface)
					info.Problems.Add(new String(scope $"{type.Name} does not implement {m.OwnerType}.{m.Name}: {d}. Use Type Settings > Implement Missing Members."));
				else
					info.Problems.Add(new String(scope $"{type.Name} does not implement the abstract {m.OwnerType}.{m.Name}: {d}. Override it, or make {type.Name} abstract."));
			}
		}

		static InheritedMember Copy(InheritedMember src)
		{
			InheritedMember im = new .();
			im.Kind = src.Kind;
			im.Name.Set(src.Name);
			im.OwnerType.Set(src.OwnerType);
			im.ReturnType.Set(src.ReturnType);
			for (let s in src.ParamTypes) im.ParamTypes.Add(new String(s));
			for (let s in src.ParamNames) im.ParamNames.Add(new String(s));
			for (let s in src.ParamModifiers) im.ParamModifiers.Add(new String(s));
			im.IsAbstract = src.IsAbstract;
			im.IsVirtual = src.IsVirtual;
			im.IsOverride = src.IsOverride;
			im.FromInterface = src.FromInterface;
			im.HasSetter = src.HasSetter;
			im.Visibility = src.Visibility;
			return im;
		}

		// ------------------------------------------------------------------ stubs

		static void VisibilityWord(InheritedMember m, String o)
		{
			if (m.FromInterface)
			{
				o.Append("public");
				return;
			}
			switch (m.Visibility)
			{
			case .Public: o.Append("public");
			case .Protected: o.Append("protected");
			case .Internal: o.Append("internal");
			case .Private: o.Append("private");
			}
		}

		static void Open(String o, StringView indent, StringView header, bool allman)
		{
			if (allman)
				o.AppendF("{0}{1}\n{0}{{\n", indent, header);
			else
				o.AppendF("{0}{1} {{\n", indent, header);
		}

		static void Close(String o, StringView indent)
		{
			o.AppendF("{}}}\n", indent);
		}

		/// The declaration that overrides / implements `m`, as member text at `indent` (one
		/// trailing newline). `callBase` adds UE's "call to parent function" to a virtual (not
		/// abstract, not interface) member; otherwise non-void members return `default` and out
		/// parameters are assigned `default`.
		public static void StubText(InheritedMember m, bool callBase, StringView indent, StringView indentUnit, bool allman, String o)
		{
			String header = scope .();
			VisibilityWord(m, header);
			bool isOverride = !m.FromInterface;
			if (isOverride)
				header.Append(" override");
			bool useBase = callBase && isOverride && !m.IsAbstract;
			String inner = scope .(indent);
			inner.Append(indentUnit);
			String inner2 = scope .(inner);
			inner2.Append(indentUnit);
			switch (m.Kind)
			{
			case .Method:
				header.AppendF(" {} {}(", m.IsVoid ? "void" : m.ReturnType, m.Name);
				m.ParamsText(header);
				header.Append(')');
				Open(o, indent, header, allman);
				if (useBase)
				{
					String args = scope .();
					m.ArgsText(args);
					o.AppendF("{}{}base.{}({});\n", inner, m.IsVoid ? "" : "return ", m.Name, args);
				}
				else
				{
					for (int i < m.ParamNames.Count)
						if (m.ParamModifiers[i].Contains("out"))
							o.AppendF("{}{} = default;\n", inner, m.ParamNames[i]);
					if (!m.IsVoid)
						o.AppendF("{}return default;\n", inner);
				}
				Close(o, indent);
			case .Property, .Indexer:
				String access = scope .();
				if (m.Kind == .Indexer)
				{
					header.AppendF(" {} this[", m.ReturnType);
					m.ParamsText(header);
					header.Append(']');
					access.Append("base[");
					m.ArgsText(access);
					access.Append(']');
				}
				else
				{
					header.AppendF(" {} {}", m.ReturnType, m.Name);
					access.AppendF("base.{}", m.Name);
				}
				Open(o, indent, header, allman);
				Open(o, inner, "get", allman);
				o.AppendF("{}return {};\n", inner2, useBase ? access : "default");
				Close(o, inner);
				if (m.HasSetter)
				{
					Open(o, inner, "set", allman);
					if (useBase)
						o.AppendF("{}{} = value;\n", inner2, access);
					Close(o, inner);
				}
				Close(o, indent);
			}
		}

		// ------------------------------------------------------------------ pickers

		/// Types a picker offers, from the project and every library: `kinds` is a list like
		/// "class" or "interface" or "class,struct"; sealed and static classes are left out when
		/// `forDerive`. Search is a case-insensitive substring; at most `max` results.
		public static void ListTypes(TypeService svc, StringView kinds, StringView search, bool forDerive, int max, List<TypeChoice> outList)
		{
			if (svc == null)
				return;
			List<SymbolStore> stores = scope .();
			svc.AllStores(stores);
			HashSet<String> seen = scope .();
			defer { for (let k in seen) delete k; }
			String key = scope .();
			for (let store in stores)
			{
				for (int ti < store.Types.Count)
				{
					let rec = ref store.Types[ti];
					let kind = store.Str(rec.Kind);
					bool want = false;
					for (var k in kinds.Split(','))
					{
						k.Trim();
						if (k == kind)
							want = true;
					}
					if (!want || !store.Str(rec.Outer).IsEmpty)
						continue;
					if (forDerive && (rec.TypeFlags & (TypeRec.cSealed | TypeRec.cStatic)) != 0)
						continue;
					let name = store.Str(rec.Name);
					if (!search.IsEmpty && name.IndexOf(search, true) < 0)
						continue;
					key.Clear();
					key.AppendF("{}.{}", store.Str(rec.Namespace), name);
					if (seen.Contains(key))
						continue;
					seen.Add(new String(key));
					TypeChoice c;
					c.Name = name;
					c.Namespace = store.Str(rec.Namespace);
					c.Kind = kind;
					c.Library = store.IsLibrary ? StringView(store.Name) : "";
					outList.Add(c);
					if (outList.Count >= max)
						return;
				}
			}
		}

		/// The parent class of a declaration as written ("" when it has none or only interfaces):
		/// the first base the TypeService (or the project index) knows as a class or struct; when
		/// nothing is known, the first base.
		public static void BaseClassOf(CompilationUnit unit, Member owner, String outName)
		{
			if (owner == null || owner.BaseColonTok < 0 || owner.BaseLastTok <= owner.BaseColonTok)
				return;
			List<String> bases = scope .();
			defer { ClearAndDeleteItems!(bases); }
			TypeDeclInfo.SplitTopLevel(unit, owner.BaseColonTok + 1, owner.BaseLastTok, bases);
			bool anyKnown = false;
			for (let b in bases)
			{
				String kind = scope .();
				if (TypeService.Current != null)
				{
					let h = TypeService.Current.FindType(b, null);
					if (h.IsValid)
						kind.Set(h.Store.Str(h.Rec.Kind));
				}
				if (kind.IsEmpty && GraphBuilder.Index != null)
				{
					let st = GraphBuilder.Index.FindType(b);
					if (st != null)
						kind.Set(st.Kind);
				}
				if (kind.IsEmpty)
					continue;
				anyKnown = true;
				if (kind != "interface")
				{
					outName.Set(b);
					return;
				}
			}
			if (!anyKnown && !bases.IsEmpty)
				outName.Set(bases[0]);
		}

		// ------------------------------------------------------------------ graph checks

		/// A Parent (`base`) node needs an instance: there is none in a static function.
		public static void CheckBaseNode(Graph g, Node n)
		{
			if (g.StaticContext)
				g.AddError(n, "There is no base here: this function is static, so there is no this.");
		}

		/// GraphValidator's check of a function's declaration: an `override` function needs a
		/// virtual or abstract member to override. Only reported when the whole base chain is
		/// known; the error goes on the Entry node (the function's header).
		public static void CheckEntry(Graph g)
		{
			let svc = TypeService.Current;
			if (svc == null || g.Entry == null || g.SelfType.IsEmpty || !Mods.Has(g.DeclModifiers, "override"))
				return;
			let name = StringView(g.MethodName);
			if (name.Contains('.'))
				return; // accessors carry the property's modifiers
			let t = svc.FindType(g.SelfType, null);
			if (!t.IsValid || t.Store.Str(t.Rec.Kind) != "class")
				return;
			// Two classes with this name (other namespaces): which one is meant is not known here.
			{
				int classes = 0;
				List<SymbolStore> stores = scope .();
				svc.AllStores(stores);
				for (let store in stores)
					for (let ti in store.TypesNamed(g.SelfType))
						if (store.Str(store.Types[ti].Kind) == "class")
							classes++;
				if (classes > 1)
					return;
			}
			// Parameter types and modifiers from the method key: `Type.Name(int,out float)`.
			List<String> types = scope .();
			List<String> mods = scope .();
			defer { ClearAndDeleteItems!(types); ClearAndDeleteItems!(mods); }
			let key = StringView(g.MethodKey);
			int open = key.IndexOf('(');
			int close = key.LastIndexOf(')');
			if (open < 0 || close < open)
				return;
			if (close > open + 1)
			{
				int depth = 0;
				int seg = open + 1;
				for (int i = open + 1; i <= close; i++)
				{
					char8 c = key[i];
					if (c == '<' || c == '(' || c == '[')
						depth++;
					else if ((c == '>' || c == ']' || (c == ')' && i < close)))
						depth--;
					if ((c == ',' && depth == 0) || i == close)
					{
						var p = key.Substring(seg, i - seg);
						p.Trim();
						String mod = new .();
						StringView[4] words = .("out ", "ref ", "in ", "params ");
						for (let w in words)
						{
							if (p.StartsWith(w))
							{
								mod.Set(w);
								mod.Trim();
								p = p.Substring(w.Length);
								p.Trim();
							}
						}
						types.Add(new String(p));
						mods.Add(mod);
						seg = i + 1;
					}
				}
			}
			// Method keys do not keep `ref` / `out`: compare names and types only.
			String want = scope .();
			MakeSignature(.Method, name, types, null, want);
			// The base chain: everything the type inherits, not the type itself.
			bool found = false;
			List<String> unresolved = scope .();
			defer { ClearAndDeleteItems!(unresolved); }
			String baseName = scope .();
			String sig = scope .();
			svc.VisitHierarchy(t, g.SelfType, scope [&] (bt, map) =>
			{
				if (IsInterface(bt) || (bt.Store.Str(bt.Rec.Name) == t.Store.Str(t.Rec.Name) && bt.Store.Str(bt.Rec.Namespace) == t.Store.Str(t.Rec.Namespace)))
					return true;
				if (baseName.IsEmpty)
					baseName.Set(bt.Store.Str(bt.Rec.Name));
				let rec = ref bt.Rec;
				for (int mi = rec.FirstMember; mi < rec.FirstMember + rec.MemberCount; mi++)
				{
					let mr = ref bt.Store.Members[mi];
					if (!mr.IsMethod || bt.Store.Str(mr.Name) != name || !(mr.IsVirtual || mr.IsAbstract || mr.IsOverride))
						continue;
					InheritedMember im = scope .();
					FromRec(bt, mi, map, im);
					sig.Clear();
					MakeSignature(.Method, im.Name, im.ParamTypes, null, sig);
					if (sig == want)
					{
						found = true;
						return false;
					}
				}
				return true;
			}, unresolved);
			if (found || !unresolved.IsEmpty)
				return;
			// Every class ends in Object; without corlib only Object's own virtuals are unknown.
			let obj = svc.FindType("Object", null);
			if (!obj.IsValid)
			{
				if (IsObjectVirtual(name))
					return;
			}
			else
			svc.VisitHierarchy(obj, "Object", scope [&] (bt, map) =>
			{
				let rec = ref bt.Rec;
				for (int mi = rec.FirstMember; mi < rec.FirstMember + rec.MemberCount; mi++)
				{
					let mr = ref bt.Store.Members[mi];
					if (!mr.IsMethod || bt.Store.Str(mr.Name) != name || !(mr.IsVirtual || mr.IsAbstract || mr.IsOverride))
						continue;
					InheritedMember im = scope .();
					FromRec(bt, mi, map, im);
					sig.Clear();
					MakeSignature(.Method, im.Name, im.ParamTypes, null, sig);
					if (sig == want)
					{
						found = true;
						return false;
					}
				}
				return true;
			});
			if (found)
				return;
			String msg = scope .();
			msg.AppendF("'{}' is marked override, but no base class of {} has a virtual or abstract {} to override. ", name, g.SelfType, want);
			msg.Append("Pick it from the Override dropdown, or remove `override` in Properties.");
			g.AddError(g.Entry, msg);
		}
	}

	/// New-type templates (Project Browser > Add and the UMP visual mod).
	static class TypeTemplates
	{
		/// A file with one type: `kind` class / struct / interface / enum; `baseList` the text after
		/// ':' ("" for none; for an enum the underlying type); `members` member text indented with
		/// two tabs ("" = the default members of the kind: none for a class).
		public static void Make(StringView kind, StringView ns, StringView name, StringView modifiers, StringView baseList, StringView members, String outText)
		{
			outText.Append("using System;\n\n");
			outText.AppendF("namespace {}\n{{\n", ns);
			outText.Append('\t');
			if (!modifiers.IsEmpty)
				outText.AppendF("{} ", modifiers);
			outText.AppendF("{} {}", kind, name);
			if (!baseList.IsEmpty)
				outText.AppendF(" : {}", baseList);
			outText.Append("\n\t{\n");
			if (!members.IsEmpty)
				outText.Append(members);
			else
			{
				switch (kind)
				{
				case "struct":
					outText.Append("\t\tpublic int Value;\n");
				case "enum":
					outText.Append("\t\tNewEnumerator0,\n\t\tNewEnumerator1\n");
				default:
				}
			}
			outText.Append("\t}\n}\n");
		}

		/// The UMP mod entry point VisualBeef opens as a visual mod (production audit 8.2): the
		/// same shape as UMP's code template (`src/Mods/ModTemplate.bf`), with block bodies so
		/// every override is a graph. `className` is normally "ModMain".
		///
		/// This is the source of truth for a visual mod's `src\ModMain.bf` (docs/UMP-Integration.md):
		/// UnrealUMP's launcher writes the same bytes (`ModTemplate.AppendVisualModSource`, pinned by its
		/// `--selftest-template`), and `--new-ump-mod` writes it through here. Change both together.
		/// The id, name and version are written as escaped string literals.
		public static void MakeUMPMod(StringView ns, StringView className, StringView modId, StringView modName, StringView version, String outText)
		{
			void Str(StringView s)
			{
				outText.Append('"');
				for (let c in s.RawChars)
				{
					if (c == '"' || c == '\\')
						outText.Append('\\');
					outText.Append(c);
				}
				outText.Append('"');
			}

			outText.Append("using System;\nusing UMPDebug;\nusing UMPSDK;\nusing UnrealUMP.Unreal;\n\n");
			outText.AppendF("namespace {}\n{{\n", ns);
			outText.Append("\t[AlwaysInclude, StaticInitAfter(typeof(UMPModHost))]\n");
			outText.AppendF("\tstatic class {}Entry\n\t{{\n", className);
			outText.AppendF("\t\tstatic this() => UMPModHost.Register(new {}());\n\t}}\n\n", className);
			outText.AppendF("\tclass {} : UMPMod\n\t{{\n", className);
			outText.Append("\t\tpublic override FUMPModIdentity Info() => .(");
			Str(modId);
			outText.Append(", ");
			Str(modName);
			outText.Append(", ");
			Str(version);
			outText.Append("); // must match ModConfig.json\n\n");
			outText.Append("\t\t/// Once, at the phase in ModConfig.json, on the runtime worker thread. Return .Err to refuse loading.\n");
			outText.Append("\t\tpublic override Result<void> Initialize()\n\t\t{\n");
			outText.Append("\t\t\tLog(.Info, ");
			Str(scope $"{modName} loaded");
			outText.Append(");\n");
			outText.Append("\t\t\treturn .Ok;\n\t\t}\n\n");
			outText.Append("\t\t/// Every frame on the game thread, after the engine's tick; engine calls are safe here.\n");
			outText.Append("\t\tpublic override void Tick(float DeltaSeconds)\n\t\t{\n\t\t}\n\n");
			outText.Append("\t\t/// Once at process teardown; remove hooks here.\n");
			outText.Append("\t\tpublic override void Shutdown()\n\t\t{\n\t\t}\n");
			outText.Append("\t}\n}\n");
		}
	}
}
