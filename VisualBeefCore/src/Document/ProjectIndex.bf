using System;
using System.Collections;
using System.IO;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Document
{
	/// Declared accessibility. Members without a modifier are private (interface and enum
	/// members are public; top-level types are public).
	enum SymbolVisibility : uint8
	{
		Private,
		Protected,
		Internal,
		Public
	}

	class SymbolMethod
	{
		public String Name = new .() ~ delete _;
		/// The type that declares the method (for an extension, the extended type); "" if unknown.
		public String OwnerType = new .() ~ delete _;
		public String ReturnType = new .() ~ delete _;
		/// "int a, float b = 1" as written (modifiers and defaults included)
		public String ParamsText = new .() ~ delete _;
		public List<String> ParamNames = new .() ~ DeleteContainerAndItems!(_);
		public List<String> ParamTypes = new .() ~ DeleteContainerAndItems!(_);
		/// Per parameter: default value text ("" = none), modifier ("ref", "out", "params", ""),
		/// and attribute text (`[Pin(Name="x")]` or "").
		public List<String> ParamDefaults = new .() ~ DeleteContainerAndItems!(_);
		public List<String> ParamModifiers = new .() ~ DeleteContainerAndItems!(_);
		public List<String> ParamAttributes = new .() ~ DeleteContainerAndItems!(_);
		/// Generic parameter names, comma separated ("T" for `Max<T>(T a, T b)`).
		public String GenericParams = new .() ~ delete _;
		/// Attribute text before the declaration, verbatim ("" = none).
		public String Attributes = new .() ~ delete _;
		/// The `///` doc comment above the declaration (comment markers removed).
		public String Doc = new .() ~ delete _;
		public SymbolVisibility Visibility;
		public bool IsStatic;
		public bool HasBody;
		public bool IsCtor;
		public bool IsMixin;
		/// `virtual`, `abstract` (also an interface method without a body), `override`, `sealed`.
		public bool IsVirtual;
		public bool IsAbstract;
		public bool IsOverride;
		public bool IsSealed;
		public int32 Line;
		/// Set by TypeService.ResolveCall: another overload fit the (all known) argument types
		/// exactly as well, so the pick is a guess (the node shows a warning when edited).
		public bool Ambiguous;
		/// When Ambiguous: every overload that fit equally well, as `Name(int a, float b)`.
		public List<String> Candidates ~ DeleteContainerAndItems!(_);
	}

	class SymbolField
	{
		public String Name = new .() ~ delete _;
		public String Type = new .() ~ delete _;
		public String Attributes = new .() ~ delete _;
		public String Doc = new .() ~ delete _;
		public SymbolVisibility Visibility;
		public bool IsStatic;
		public bool IsProperty;
		/// Properties: has a setter. Fields: not const/readonly.
		public bool Writable = true;
		/// Properties: `virtual` / `abstract` (or an interface property) / `override`.
		public bool IsVirtual;
		public bool IsAbstract;
		public bool IsOverride;
		public int32 Line;
	}

	class SymbolType
	{
		public String Name = new .() ~ delete _;
		public String Kind = new .() ~ delete _;
		public String FilePath = new .() ~ delete _;
		/// Name of the enclosing type for nested types; empty for top-level types.
		public String Outer = new .() ~ delete _;
		/// 1-based line of the declaration.
		public int32 Line;
		/// Enclosing namespace ("System.Collections"; empty for none).
		public String Namespace = new .() ~ delete _;
		/// Generic parameter names, comma separated ("TKey,TValue").
		public String GenericParams = new .() ~ delete _;
		/// Base class and interfaces as written (`: Base, IFoo`).
		public List<String> BaseTypes = new .() ~ DeleteContainerAndItems!(_);
		/// Enum case names (enums only).
		public List<String> EnumCases = new .() ~ DeleteContainerAndItems!(_);
		public String Attributes = new .() ~ delete _;
		public String Doc = new .() ~ delete _;
		public SymbolVisibility Visibility;
		/// Type modifiers: `abstract`, `sealed`, `static`.
		public bool IsAbstract;
		public bool IsSealed;
		public bool IsStaticType;
		public List<SymbolMethod> Methods = new .() ~ DeleteContainerAndItems!(_);
		public List<SymbolField> Fields = new .() ~ DeleteContainerAndItems!(_);

		public SymbolMethod FindMethod(StringView name)
		{
			for (let m in Methods)
				if (m.Name == name)
					return m;
			return null;
		}

		public SymbolField FindField(StringView name)
		{
			for (let f in Fields)
				if (f.Name == name)
					return f;
			return null;
		}
	}

	/// A member of a project file the editor cannot use as written (docs/Files-and-Safety.md >
	/// Unparsed members are kept): a Broken member or a declaration error (Member.GetDeclError).
	/// Listed in the Problems panel; the text itself is kept in the file byte for byte.
	class UnreadableMember
	{
		/// "Program.Main" (or "unparsed member at line N" when no name could be recovered).
		public String Name = new .() ~ delete _;
		public String Message = new .() ~ delete _;
		/// 1-based line of the member's first token.
		public int32 Line;
		public bool Broken;
	}

	class IndexedFile
	{
		public String Path = new .() ~ delete _;
		/// Members the editor could not read or that have a declaration error, in source order.
		public List<UnreadableMember> Unreadable = new .() ~ DeleteContainerAndItems!(_);
		public List<SymbolType> Types = new .() ~ DeleteContainerAndItems!(_);
		/// `using` directives of the file ("System.Collections", "static System.Math").
		public List<String> Usings = new .() ~ DeleteContainerAndItems!(_);
		/// Size + modification time of the file when it was parsed from disk; 0 when the entry
		/// came from live (possibly unsaved) editor text. A rescan re-parses only files whose
		/// stamp changed.
		public uint64 Stamp;
	}

	/// A lightweight symbol table of every .bf file under a project folder: types, their
	/// functions and fields. Lets graphs in one file call, label and navigate to code in others.
	class ProjectIndex
	{
		public String Root = new .() ~ delete _;
		public List<IndexedFile> Files = new .() ~ DeleteContainerAndItems!(_);
		/// Generated library projects found under Root. They are not parsed as
		/// project files: TypeService loads them through LibraryIndex (cached) instead.
		public List<String> GeneratedLibraries = new .() ~ DeleteContainerAndItems!(_);
		/// Bumped on every change, so caches built from the index (the node catalog) refresh.
		public int32 Version;
		/// Statistics of the last Build: files parsed and files reused unchanged.
		public int32 LastParsed;
		public int32 LastReused;

		public static bool SamePath(StringView a, StringView b)
		{
			if (a.Length != b.Length)
				return false;
			for (int i < a.Length)
			{
				char8 ca = a[i];
				char8 cb = b[i];
				if (ca == '\\') ca = '/';
				if (cb == '\\') cb = '/';
				if (ca.ToLower != cb.ToLower)
					return false;
			}
			return true;
		}

		public void Clear()
		{
			ClearAndDeleteItems!(Files);
			ClearAndDeleteItems!(GeneratedLibraries);
			Root.Clear();
			Version++;
		}

		/// Moves the content of another index (built on a worker thread) into this one, so
		/// everything holding this index sees the new files. `other` is left empty.
		public void TakeFrom(ProjectIndex other)
		{
			ClearAndDeleteItems!(Files);
			ClearAndDeleteItems!(GeneratedLibraries);
			Swap!(Files, other.Files);
			Swap!(GeneratedLibraries, other.GeneratedLibraries);
			Root.Set(other.Root);
			other.Root.Clear();
			LastParsed = other.LastParsed;
			LastReused = other.LastReused;
			Version = Math.Max(Version, other.Version) + 1;
			other.Version++;
		}

		/// Indexes every .bf file under root (skipping build output folders and generated
		/// library projects, which go to GeneratedLibraries). When the index already holds this
		/// root, files whose size and modification time did not change are kept as they are
		/// (rescans after creating, renaming or deleting a file cost a directory listing).
		/// `progress` (optional) reports per-file progress and can cancel: a cancelled build
		/// leaves the index partial, so the caller discards it.
		public void Build(StringView root, IndexProgress progress = null)
		{
			bool reuse = !Root.IsEmpty && SamePath(Root, root) && !Files.IsEmpty;
			List<IndexedFile> old = scope .();
			defer { ClearAndDeleteItems!(old); }
			if (reuse)
			{
				old.AddRange(Files);
				Files.Clear();
			}
			Clear();
			Root.Set(root);
			List<String> paths = scope .();
			defer { ClearAndDeleteItems!(paths); }
			List<uint64> stamps = scope .();
			progress?.SetPhase("Scanning project folder", 0);
			CollectFiles(root, 0, paths, stamps, GeneratedLibraries);
			// Sort paths and stamps together.
			List<int> order = scope .(paths.Count);
			for (int i < paths.Count)
				order.Add(i);
			order.Sort(scope (a, b) => String.Compare(paths[a], paths[b], true));
			Dictionary<String, IndexedFile> byPath = scope .();
			for (let f in old)
				if (f.Stamp != 0)
					byPath[f.Path] = f;
			progress?.SetPhase("Indexing project", (.)paths.Count);
			LastParsed = 0;
			LastReused = 0;
			for (let i in order)
			{
				if (progress != null && progress.Cancelled)
					return;
				let path = paths[i];
				let stamp = stamps[i];
				if (reuse && byPath.TryGetValue(path, let prev) && prev.Stamp == stamp)
				{
					old.Remove(prev);
					Files.Add(prev);
					LastReused++;
					progress?.Step();
					continue;
				}
				String text = scope .();
				if (File.ReadAllText(path, text, true) case .Err)
				{
					progress?.Step();
					continue;
				}
				let unit = Parser.Parse(text);
				Update(path, unit);
				delete unit;
				Files.Back.Stamp = stamp;
				LastParsed++;
				progress?.Step();
			}
			Version++;
		}

		public static void CollectFiles(StringView dir, int depth, List<String> outPaths)
		{
			CollectFiles(dir, depth, outPaths, null, null);
		}

		/// Collects .bf files. With `outLibraryDirs`, sub-folders that hold a generated library
		/// project (see IsGeneratedLibrary) are not entered: their folder is added there instead.
		/// With `outStamps`, the size + modification time of each file (MakeStamp) in step with
		/// `outPaths`.
		public static void CollectFiles(StringView dir, int depth, List<String> outPaths, List<uint64> outStamps, List<String> outLibraryDirs)
		{
			if (depth > 12 || outPaths.Count > 5000)
				return;
			if (depth > 0 && outLibraryDirs != null && IsGeneratedLibrary(dir))
			{
				outLibraryDirs.Add(new String(dir));
				return;
			}
			for (let entry in Directory.EnumerateFiles(dir))
			{
				String path = scope .();
				entry.GetFilePath(path);
				if (path.EndsWith(".bf", .OrdinalIgnoreCase))
				{
					outPaths.Add(new String(path));
					outStamps?.Add(MakeStamp(entry.GetLastWriteTimeUtc().Ticks, entry.GetFileSize()));
				}
			}
			for (let entry in Directory.EnumerateDirectories(dir))
			{
				String name = scope .();
				entry.GetFileName(name);
				if (name.StartsWith(".") || name == "build" || name == "recovery")
					continue;
				String path = scope .();
				entry.GetFilePath(path);
				CollectFiles(path, depth + 1, outPaths, outStamps, outLibraryDirs);
			}
		}

		public static uint64 MakeStamp(int64 ticks, int64 size)
		{
			uint64 h = ((uint64)ticks * 0x9E3779B97F4A7C15) ^ ((uint64)size + 0x632BE59BD9B4E019);
			return (h == 0) ? 1 : h;
		}

		/// True for a folder that holds a generated library project: a `BeefProj.toml` with
		/// `TargetType = "BeefLib"` whose sources are mostly generated (`*.g.bf`, as code
		/// generators write them), or any library folder with a `.vblibrary` marker file.
		/// Such a folder is indexed as a library (parsed once, cached by LibraryIndex), not as
		/// project sources.
		public static bool IsGeneratedLibrary(StringView dir)
		{
			String proj = scope .();
			proj.AppendF("{}{}BeefProj.toml", dir, Path.DirectorySeparatorChar);
			if (!File.Exists(proj))
				return false;
			String text = scope .();
			if (File.ReadAllText(proj, text, true) case .Err)
				return false;
			bool isLib = false;
			for (var line in text.Split('\n'))
			{
				line.Trim();
				if (line.StartsWith("TargetType") && line.Contains("BeefLib"))
					isLib = true;
			}
			if (!isLib)
				return false;
			String marker = scope .();
			marker.AppendF("{}{}.vblibrary", dir, Path.DirectorySeparatorChar);
			if (File.Exists(marker))
				return true;
			// Sample the sources: generated when more than half of them are *.g.bf.
			int total = 0;
			int generated = 0;
			CountSources(dir, 0, ref total, ref generated);
			return total > 0 && generated * 2 > total;
		}

		static void CountSources(StringView folder, int depth, ref int total, ref int generated)
		{
			if (depth > 4 || total >= 64)
				return;
			for (let entry in Directory.EnumerateFiles(folder))
			{
				String name = scope .();
				entry.GetFileName(name);
				if (!name.EndsWith(".bf", .OrdinalIgnoreCase))
					continue;
				total++;
				if (name.EndsWith(".g.bf", .OrdinalIgnoreCase))
					generated++;
				if (total >= 64)
					return;
			}
			for (let entry in Directory.EnumerateDirectories(folder))
			{
				String sub = scope .();
				entry.GetFilePath(sub);
				CountSources(sub, depth + 1, ref total, ref generated);
			}
		}

		public IndexedFile FindFile(StringView path)
		{
			for (let f in Files)
				if (SamePath(f.Path, path))
					return f;
			return null;
		}

		/// Re-indexes one file from a parse of it (call after edits).
		public void Update(StringView path, CompilationUnit unit)
		{
			var file = FindFile(path);
			if (file == null)
			{
				file = new IndexedFile();
				file.Path.Set(path);
				Files.Add(file);
			}
			Version++;
			ClearAndDeleteItems!(file.Types);
			ClearAndDeleteItems!(file.Usings);
			IndexMembers(file, unit, unit.Members, path, "", null);
			ClearAndDeleteItems!(file.Unreadable);
			CollectUnreadable(unit, file.Unreadable);
		}

		/// Every Broken member and every function with a declaration error in a parse.
		public static void CollectUnreadable(CompilationUnit unit, List<UnreadableMember> outList)
		{
			List<Member> methods = scope .();
			List<Member> owners = scope .();
			unit.CollectMethods(methods, owners);
			String msg = scope .();
			for (int i < methods.Count)
			{
				let m = methods[i];
				msg.Clear();
				if (!m.HasSpan || !m.GetDeclError(msg))
					continue;
				UnreadableMember u = new .();
				u.Line = unit.LineOf(unit.Tokens[m.FirstTok].Start);
				u.Broken = m.Kind == .Broken;
				u.Message.Set(msg);
				if (m.Name.IsEmpty || m.Name == "?")
					u.Name.AppendF("unparsed member at line {}", u.Line);
				else
				{
					if (owners[i] != null)
						u.Name.AppendF("{}.", owners[i].Name);
					u.Name.Append(m.Name);
				}
				outList.Add(u);
			}
			CollectFieldErrors(unit, unit.Members, null, outList);
		}

		/// Member variables and properties whose type does not fit (`void x;`, `var x;`).
		static void CollectFieldErrors(CompilationUnit unit, List<Member> members, Member owner, List<UnreadableMember> outList)
		{
			String msg = scope .();
			for (let m in members)
			{
				if ((m.Kind == .Field || m.Kind == .Property) && m.HasSpan)
				{
					msg.Clear();
					if (m.GetDeclError(msg))
					{
						UnreadableMember u = new .();
						u.Line = unit.LineOf(unit.Tokens[m.FirstTok].Start);
						u.Message.Set(msg);
						if (owner != null)
							u.Name.AppendF("{}.", owner.Name);
						u.Name.Append(m.Name);
						outList.Add(u);
					}
				}
				if (m.Members != null && m.Kind != .Property)
					CollectFieldErrors(unit, m.Members, (m.Kind == .Type) ? m : owner, outList);
			}
		}

		/// Adds the parse of a file that is not kept (libraries): same as Update for a new path.
		public void AddFile(StringView path, CompilationUnit unit)
		{
			IndexedFile file = new .();
			file.Path.Set(path);
			Files.Add(file);
			Version++;
			IndexMembers(file, unit, unit.Members, path, "", null);
		}

		void IndexMembers(IndexedFile file, CompilationUnit unit, List<Member> members, StringView path, StringView ns, Member outer)
		{
			for (let t in members)
			{
				if (t.Kind == .Using)
				{
					var text = unit.NodeText(t);
					if (text.StartsWith("using"))
						text = text.Substring(5);
					if (text.EndsWith(';'))
						text.RemoveFromEnd(1);
					text.Trim();
					if (!text.IsEmpty)
						file.Usings.Add(new String(text));
					continue;
				}
				if (t.Kind == .Namespace)
				{
					String inner = scope .(ns);
					var nm = StringView(t.Name);
					nm.Trim();
					if (!inner.IsEmpty && !nm.IsEmpty)
						inner.Append('.');
					inner.Append(nm);
					if (t.Members != null)
						IndexMembers(file, unit, t.Members, path, inner, outer);
					continue;
				}
				if (t.Kind != .Type)
					continue;
				SymbolType st = new .();
				st.Name.Set(t.Name);
				if (t.TypeKind != null)
					st.Kind.Set(t.TypeKind);
				st.FilePath.Set(path);
				st.Namespace.Set(ns);
				if (t.HasSpan)
					st.Line = unit.LineOf(unit.Tokens[t.FirstTok].Start);
				if (outer != null)
					st.Outer.Set(outer.Name);
				if (t.Attributes != null)
					st.Attributes.Set(t.Attributes);
				DocText(unit, t, st.Doc);
				// Top-level types are public unless marked otherwise; nested ones are private.
				st.Visibility = VisibilityOf(t.Modifiers, (outer == null) ? .Public : .Private);
				ReadTypeHeader(unit, t, st);
				st.IsAbstract = HasWord(t.Modifiers, "abstract");
				st.IsSealed = HasWord(t.Modifiers, "sealed");
				st.IsStaticType = HasWord(t.Modifiers, "static") || t.IsStatic;
				bool publicByDefault = st.Kind == "interface" || st.Kind == "enum";
				if (t.Members != null)
				{
					for (let m in t.Members)
					{
						if (m.Kind == .Method)
						{
							SymbolMethod sm = new .();
							sm.Name.Set(m.Name);
							sm.OwnerType.Set(t.Name);
							if (m.TypeText != null)
								sm.ReturnType.Set(m.TypeText);
							sm.IsStatic = m.IsStatic || HasWord(m.Modifiers, "static") || (st.IsStaticType && st.Kind == "class");
							sm.IsCtor = m.IsCtor || m.IsDtor;
							sm.IsMixin = m.IsMixin;
							sm.HasBody = m.Body != null;
							sm.IsVirtual = HasWord(m.Modifiers, "virtual");
							sm.IsOverride = HasWord(m.Modifiers, "override");
							sm.IsSealed = HasWord(m.Modifiers, "sealed");
							sm.IsAbstract = HasWord(m.Modifiers, "abstract") ||
								(st.Kind == "interface" && !sm.IsStatic && !HasImplementation(unit, m));
							sm.Visibility = VisibilityOf(m.Modifiers, publicByDefault ? .Public : .Private);
							if (m.Attributes != null)
								sm.Attributes.Set(m.Attributes);
							DocText(unit, m, sm.Doc);
							if (m.HasSpan)
								sm.Line = unit.LineOf(unit.Tokens[m.FirstTok].Start);
							MethodGenerics(unit, m, sm.GenericParams);
							if (m.Params != null)
							{
								for (let p in m.Params)
								{
									if (@p.Index > 0)
										sm.ParamsText.Append(", ");
									if (!p.Modifier.IsEmpty)
										sm.ParamsText.AppendF("{} ", p.Modifier);
									sm.ParamsText.AppendF("{} {}", p.Type, p.Name);
									if (p.Default != null)
										sm.ParamsText.AppendF(" = {}", p.Default);
									sm.ParamNames.Add(new String(p.Name));
									sm.ParamTypes.Add(new String(p.Type));
									sm.ParamDefaults.Add(new String(p.Default ?? ""));
									sm.ParamModifiers.Add(new String(p.Modifier));
									sm.ParamAttributes.Add(new String(p.Attributes ?? ""));
								}
							}
							// Both arms of `#if A ... #else ... #endif` parse as live code: keep one.
							if (FindSameSignature(st, sm) != null)
							{
								delete sm;
								continue;
							}
							st.Methods.Add(sm);
						}
						else if ((m.Kind == .Field || m.Kind == .Property) && !m.IsIndexer)
						{
							if (st.FindField(m.Name) != null)
								continue; // the other arm of an #if
							SymbolField sf = new .();
							sf.Name.Set(m.Name);
							if (m.TypeText != null)
								sf.Type.Set(m.TypeText);
							sf.IsStatic = m.IsStatic || HasWord(m.Modifiers, "static") || HasWord(m.Modifiers, "const") || (st.IsStaticType && st.Kind == "class");
							sf.IsProperty = m.Kind == .Property;
							sf.Visibility = VisibilityOf(m.Modifiers, publicByDefault ? .Public : .Private);
							if (m.Attributes != null)
								sf.Attributes.Set(m.Attributes);
							DocText(unit, m, sf.Doc);
							if (m.HasSpan)
								sf.Line = unit.LineOf(unit.Tokens[m.FirstTok].Start);
							if (sf.IsProperty)
							{
								sf.IsVirtual = HasWord(m.Modifiers, "virtual");
								sf.IsOverride = HasWord(m.Modifiers, "override");
								sf.IsAbstract = HasWord(m.Modifiers, "abstract") || (st.Kind == "interface" && !sf.IsStatic && !PropertyHasBodies(m));
							}
							if (sf.IsProperty)
								sf.Writable = PropertyHasSetter(unit, m);
							else
								sf.Writable = !HasWord(m.Modifiers, "const") && !HasWord(m.Modifiers, "readonly");
							st.Fields.Add(sf);
						}
						else if (m.Kind == .Raw && st.Kind == "enum" && st.EnumCases.IsEmpty)
							ReadEnumCases(unit, m, st);
					}
				}
				file.Types.Add(st);
				if (t.Members != null)
					IndexMembers(file, unit, t.Members, path, ns, t);
			}
		}

		static SymbolMethod FindSameSignature(SymbolType st, SymbolMethod sm)
		{
			for (let o in st.Methods)
			{
				if (o.Name != sm.Name || o.IsStatic != sm.IsStatic || o.ParamTypes.Count != sm.ParamTypes.Count)
					continue;
				bool same = true;
				for (int i < o.ParamTypes.Count)
					if (o.ParamTypes[i] != sm.ParamTypes[i] || o.ParamModifiers[i] != sm.ParamModifiers[i])
						same = false;
				if (same)
					return o;
			}
			return null;
		}

		public static bool HasWord(StringView text, StringView word)
		{
			for (var w in text.Split(' ', '\t', '\n', '\r'))
				if (w == word)
					return true;
			return false;
		}

		static SymbolVisibility VisibilityOf(StringView modifiers, SymbolVisibility defaultVis)
		{
			if (HasWord(modifiers, "public"))
				return .Public;
			if (HasWord(modifiers, "internal"))
				return .Internal;
			if (HasWord(modifiers, "protected"))
				return .Protected;
			if (HasWord(modifiers, "private"))
				return .Private;
			return defaultVis;
		}

		/// The `///` lines directly above a declaration (its span starts at its attributes).
		public static void DocText(CompilationUnit unit, Member m, String outDoc)
		{
			if (!m.HasSpan)
				return;
			let lead = unit.LeadingTrivia(m.FirstTok);
			if (!lead.Contains("///"))
				return;
			// Only the comment block that touches the declaration.
			List<StringView> lines = scope .();
			for (var line in lead.Split('\n'))
			{
				line.Trim();
				lines.Add(line);
			}
			int end = lines.Count;
			while (end > 0 && lines[end - 1].IsEmpty)
				end--;
			int start = end;
			while (start > 0 && lines[start - 1].StartsWith("///"))
				start--;
			for (int i = start; i < end; i++)
			{
				var l = lines[i].Substring(3);
				if (l.StartsWith(' '))
					l = l.Substring(1);
				if (!outDoc.IsEmpty)
					outDoc.Append('\n');
				outDoc.Append(l);
			}
		}

		static void MethodGenerics(CompilationUnit unit, Member m, String outNames)
		{
			if (m.NameTok < 0 || m.ParamsOpenTok <= m.NameTok + 1)
				return;
			if (unit.TokenText(m.NameTok + 1) != "<")
				return;
			GenericNames(unit, m.NameTok + 1, m.ParamsOpenTok - 1, outNames);
		}

		/// Names of `<A, B<C>>` at the top level, comma separated.
		static void GenericNames(CompilationUnit unit, int first, int last, String outNames)
		{
			int depth = 0;
			bool expectName = false;
			for (int i = first; i <= last; i++)
			{
				let tx = unit.TokenText(i);
				if (tx == "<")
				{
					depth++;
					if (depth == 1)
						expectName = true;
					continue;
				}
				if (tx == ">" || tx == ">>")
				{
					depth -= tx.Length;
					if (depth <= 0)
						return;
					continue;
				}
				if (depth == 1 && tx == ",")
				{
					expectName = true;
					continue;
				}
				if (depth == 1 && expectName && unit.Tokens[i].Kind == .Identifier && tx != "const")
				{
					if (!outNames.IsEmpty)
						outNames.Append(',');
					outNames.Append(tx);
					expectName = false;
				}
			}
		}

		/// Generic parameters and base list of a type: `class Foo<T> : Base, IBar where T : ...`.
		static void ReadTypeHeader(CompilationUnit unit, Member t, SymbolType st)
		{
			if (t.NameTok < 0)
				return;
			int last = (t.OpenBrace >= 0) ? t.OpenBrace - 1 : t.LastTok;
			int i = t.NameTok + 1;
			if (i <= last && unit.TokenText(i) == "<")
			{
				int depth = 0;
				int j = i;
				for (; j <= last; j++)
				{
					let tx = unit.TokenText(j);
					if (tx == "<") depth++;
					else if (tx == ">") depth--;
					else if (tx == ">>") depth -= 2;
					if (depth <= 0)
						break;
				}
				GenericNames(unit, i, Math.Min(j, last), st.GenericParams);
				i = j + 1;
			}
			if (i > last || unit.TokenText(i) != ":")
				return;
			i++;
			int segStart = i;
			int depth = 0;
			for (; i <= last + 1; i++)
			{
				bool atEnd = i > last;
				StringView tx = atEnd ? "" : unit.TokenText(i);
				if (!atEnd && (tx == "<" || tx == "(" || tx == "["))
					depth++;
				else if (!atEnd && (tx == ">" || tx == ")" || tx == "]"))
					depth--;
				else if (!atEnd && tx == ">>")
					depth -= 2;
				bool isWhere = !atEnd && depth == 0 && tx == "where";
				if (atEnd || isWhere || (depth == 0 && tx == ","))
				{
					if (i > segStart)
					{
						var bt = unit.SpanText(segStart, i - 1);
						bt.Trim();
						if (!bt.IsEmpty)
							st.BaseTypes.Add(new String(bt));
					}
					segStart = i + 1;
					if (isWhere || atEnd)
						break;
				}
			}
		}

		/// A method with a body or `=> expr;` (interface default implementations).
		public static bool HasImplementation(CompilationUnit unit, Member m)
		{
			if (m.Body != null)
				return true;
			if (!m.HasSpan || m.ParamsCloseTok < 0)
				return false;
			for (int i = m.ParamsCloseTok + 1; i <= m.LastTok; i++)
				if (unit.TokenText(i) == "=>")
					return true;
			return false;
		}

		/// A property whose accessors have bodies (or `=>`): not an abstract declaration.
		static bool PropertyHasBodies(Member m)
		{
			if (m.Members == null)
				return false;
			for (let a in m.Members)
				if (a.Body != null)
					return true;
			return false;
		}

		static bool PropertyHasSetter(CompilationUnit unit, Member m)
		{
			if (m.NameTok < 0 || !m.HasSpan)
				return false;
			int depth = 0;
			for (int i = m.NameTok + 1; i <= m.LastTok; i++)
			{
				let tx = unit.TokenText(i);
				if (tx == "{" || tx == "(" || tx == "[")
					depth++;
				else if (tx == "}" || tx == ")" || tx == "]")
					depth--;
				else if (depth == 1 && tx == "set")
					return true;
			}
			return false;
		}

		static void ReadEnumCases(CompilationUnit unit, Member raw, SymbolType st)
		{
			if (!raw.HasSpan)
				return;
			int depth = 0;
			bool expect = true;
			for (int i = raw.FirstTok; i <= raw.LastTok; i++)
			{
				let tok = unit.Tokens[i];
				let tx = unit.TokenText(i);
				if (tx == "(" || tx == "[" || tx == "{")
					depth++;
				else if (tx == ")" || tx == "]" || tx == "}")
					depth--;
				else if (depth == 0 && (tx == "," || tx == "case"))
					expect = true;
				else if (depth == 0 && expect && tok.Kind == .Identifier)
				{
					st.EnumCases.Add(new String(tx));
					expect = false;
				}
				else if (depth == 0 && tx == "=")
					expect = false;
			}
		}

		/// Strips generic arguments and nullable/pointer markers: "List<int>?" -> "List".
		public static void BaseTypeName(StringView typeName, String outName)
		{
			var t = typeName;
			t.Trim();
			int lt = t.IndexOf('<');
			if (lt >= 0)
				t = t.Substring(0, lt);
			while (t.EndsWith('?') || t.EndsWith('*'))
				t.RemoveFromEnd(1);
			int dot = t.LastIndexOf('.');
			if (dot >= 0)
				t = t.Substring(dot + 1);
			outName.Append(t);
		}

		public SymbolType FindType(StringView typeName)
		{
			String name = scope .();
			BaseTypeName(typeName, name);
			if (name.IsEmpty)
				return null;
			for (let f in Files)
				for (let t in f.Types)
					if (t.Name == name)
						return t;
			return null;
		}

		public SymbolMethod FindMethod(StringView typeName, StringView methodName)
		{
			let t = FindType(typeName);
			return t?.FindMethod(methodName);
		}

		/// Finds a function declared in a global `static { }` block.
		public SymbolMethod FindGlobalMethod(StringView methodName)
		{
			for (let f in Files)
				for (let t in f.Types)
					if (t.Kind == "static")
					{
						let m = t.FindMethod(methodName);
						if (m != null)
							return m;
					}
			return null;
		}

		/// Finds a method by name anywhere in the project (first match).
		public SymbolType FindMethodAnywhere(StringView methodName, out SymbolMethod method)
		{
			for (let f in Files)
			{
				for (let t in f.Types)
				{
					let m = t.FindMethod(methodName);
					if (m != null && m.HasBody)
					{
						method = m;
						return t;
					}
				}
			}
			method = null;
			return null;
		}
	}
}
