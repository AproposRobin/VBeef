using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Document
{
	enum RenameKind : uint8
	{
		Type,
		Member,     // field, property, method of a type
		Parameter,  // of one method
		Local       // a local variable of one method
	}

	/// What to rename. Type: `TypeName` = the type. Member: `TypeName` declares `OldName`.
	/// Parameter / Local: `TypeName` + `MethodKey` name the method.
	class RenameTarget
	{
		public RenameKind Kind;
		public String OldName = new .() ~ delete _;
		public String NewName = new .() ~ delete _;
		public String TypeName = new .() ~ delete _;
		public String MethodKey = new .() ~ delete _;
		/// The file that declares it.
		public String FilePath = new .() ~ delete _;
	}

	/// One identifier occurrence to rewrite: [Start, End) of the file text it was planned on.
	struct RenameEdit
	{
		public int32 Start;
		public int32 End;
		public int32 Line;
	}

	class RenameFile
	{
		public String Path = new .() ~ delete _;
		/// The text the edits refer to (the live text of an open document).
		public String Text = new .() ~ delete _;
		public List<RenameEdit> Edits = new .() ~ delete _;
	}

	/// The references a rename would rewrite, and every occurrence that could not be told
	/// apart (`Problems`): a plan with problems must not be applied.
	class RenamePlan
	{
		public RenameTarget Target = new .() ~ delete _;
		public List<RenameFile> Files = new .() ~ DeleteContainerAndItems!(_);
		/// "Player.bf(12): `p.Score` - 'p' is declared with var: its type is not known".
		public List<String> Problems = new .() ~ DeleteContainerAndItems!(_);
		/// Why the rename cannot be made at all ("Score is already a member of Player").
		public String Refusal = new .() ~ delete _;
		/// Find References: only the occurrences are wanted, so the rules that decide whether a
		/// rename may be made (overloads, overrides, interface members) do not stop the search.
		public bool FindOnly;

		public int Count
		{
			get
			{
				int n = 0;
				for (let f in Files)
					n += f.Edits.Count;
				return n;
			}
		}

		public bool CanApply => Refusal.IsEmpty && Problems.IsEmpty && Count > 0;

		public void Summary(String o)
		{
			if (!Refusal.IsEmpty)
			{
				o.Append(Refusal);
				return;
			}
			o.AppendF("{} reference{} in {} file{}", Count, (Count == 1) ? "" : "s", Files.Count, (Files.Count == 1) ? "" : "s");
			if (!Problems.IsEmpty)
				o.AppendF("; {} that cannot be renamed safely", Problems.Count);
		}
	}

	/// The project-wide reference finder (production audit 6.3) without the compiler: lex every
	/// project file, take identifier tokens equal to the old name, and keep those whose
	/// resolution is the renamed symbol (the declaring type and its subtypes for a member,
	/// through `this`, `base`, parameters, locals, fields and type names; the method's own span
	/// for parameters and locals). An occurrence whose meaning cannot be decided is a problem,
	/// and a plan with problems is refused. Libraries are never touched.
	static class RenameService
	{
		public struct Source
		{
			public StringView Path;
			public StringView Text;
		}

		class FileCtx
		{
			public CompilationUnit Unit ~ delete _;
			public RenameFile Out;
			public StringView Path;
		}

		/// Plans a rename over `sources` (every project file; open documents with their live text).
		public static void Plan(RenameTarget target, List<Source> sources, TypeService svc, RenamePlan plan)
		{
			let t = plan.Target;
			t.Kind = target.Kind;
			t.OldName.Set(target.OldName);
			t.NewName.Set(target.NewName);
			t.TypeName.Set(target.TypeName);
			t.MethodKey.Set(target.MethodKey);
			t.FilePath.Set(target.FilePath);

			String err = scope .();
			if (plan.FindOnly)
				t.NewName.Set("__vb_find_refs__"); // a name nothing uses: no clash checks fire
			if (!ValidName(t.NewName, err))
			{
				plan.Refusal.Set(err);
				return;
			}
			if (t.NewName == t.OldName)
			{
				plan.Refusal.Set("The new name is the same as the old one.");
				return;
			}
			List<FileCtx> files = scope .();
			defer { ClearAndDeleteItems!(files); }
			for (let s in sources)
			{
				FileCtx f = new .();
				f.Unit = Parser.Parse(s.Text);
				f.Path = s.Path;
				f.Out = new .();
				f.Out.Path.Set(s.Path);
				f.Out.Text.Set(s.Text);
				files.Add(f);
			}
			switch (t.Kind)
			{
			case .Type: PlanType(t, files, svc, plan);
			case .Member: PlanMember(t, files, svc, plan);
			case .Parameter, .Local: PlanLocal(t, files, plan);
			}
			for (let f in files)
			{
				if (f.Out.Edits.IsEmpty)
				{
					delete f.Out;
					continue;
				}
				f.Out.Edits.Sort(scope (a, b) => a.Start <=> b.Start);
				// The same token found twice (a declaration and a reference pass) counts once.
				for (int i = f.Out.Edits.Count - 1; i > 0; i--)
					if (f.Out.Edits[i].Start == f.Out.Edits[i - 1].Start)
						f.Out.Edits.RemoveAt(i);
				plan.Files.Add(f.Out);
			}
		}

		/// Every project reference to a type, member, parameter or local (Find References):
		/// the same resolution as a rename, without its refusals; occurrences that cannot be told
		/// apart are listed in `plan.Problems` ("maybe").
		public static void FindReferences(RenameTarget target, List<Source> sources, TypeService svc, RenamePlan plan)
		{
			plan.FindOnly = true;
			Plan(target, sources, svc, plan);
			plan.Target.NewName.Set(target.OldName);
		}

		public static bool ValidName(StringView name, String outError)
		{
			if (name.IsEmpty)
			{
				outError.Set("A name is needed.");
				return false;
			}
			if (!(name[0].IsLetter || name[0] == '_'))
			{
				outError.Set("A name starts with a letter or '_'.");
				return false;
			}
			for (let c in name)
			{
				if (!(c.IsLetterOrDigit || c == '_'))
				{
					outError.Set(scope $"'{c}' cannot be part of a name.");
					return false;
				}
			}
			if (Parser.IsReservedWord(name))
			{
				outError.Set(scope $"'{name}' is a Beef keyword.");
				return false;
			}
			return true;
		}

		/// Applies edits (sorted, planned on `text`) and writes the new text.
		public static void Apply(StringView text, List<RenameEdit> edits, StringView newName, String outText)
		{
			int at = 0;
			for (let e in edits)
			{
				outText.Append(text.Substring(at, e.Start - at));
				outText.Append(newName);
				at = e.End;
			}
			outText.Append(text.Substring(at));
		}

		// ------------------------------------------------------------------ helpers

		static void AddEdit(FileCtx f, int tokIdx)
		{
			let tok = f.Unit.Tokens[tokIdx];
			RenameEdit e;
			e.Start = tok.Start;
			e.End = tok.End;
			e.Line = f.Unit.LineOf(tok.Start);
			f.Out.Edits.Add(e);
		}

		static void AddProblem(RenamePlan plan, FileCtx f, int tokIdx, StringView why)
		{
			String file = scope .();
			System.IO.Path.GetFileName(f.Path, file);
			let tok = f.Unit.Tokens[tokIdx];
			// The line's text, trimmed, as context.
			let text = f.Unit.Text;
			int ls = tok.Start;
			while (ls > 0 && text[ls - 1] != '\n')
				ls--;
			int le = tok.Start;
			while (le < text.Length && text[le] != '\n' && text[le] != '\r')
				le++;
			var line = StringView(text, ls, le - ls);
			line.Trim();
			if (line.Length > 80)
				line = line.Substring(0, 80);
			plan.Problems.Add(new String(scope $"{file}({f.Unit.LineOf(tok.Start)}): `{line}` - {why}"));
		}

		static bool IsTok(CompilationUnit u, int i, StringView s) => i >= 0 && i < u.Tokens.Count && u.Tokens[i].Kind != .String && u.Tokens[i].Kind != .Char && u.TokenText(i) == s;

		static bool IsIdentTok(CompilationUnit u, int i) => i >= 0 && i < u.Tokens.Count && u.Tokens[i].Kind == .Identifier;

		/// The identifier text without a leading '@'.
		static StringView Ident(CompilationUnit u, int i)
		{
			var s = u.TokenText(i);
			if (s.StartsWith('@'))
				s = s.Substring(1);
			return s;
		}

		/// Innermost type and member (method / field / property; accessors for property
		/// bodies) whose spans hold token `i`.
		static void Enclosing(List<Member> members, int i, ref Member type, ref Member member)
		{
			for (let m in members)
			{
				if (!m.HasSpan || i < m.FirstTok || i > m.LastTok)
					continue;
				if (m.Kind == .Namespace)
				{
					if (m.Members != null)
						Enclosing(m.Members, i, ref type, ref member);
					return;
				}
				if (m.Kind == .Type)
				{
					type = m;
					member = null;
					if (m.Members != null)
						Enclosing(m.Members, i, ref type, ref member);
					return;
				}
				member = m;
				if (m.Kind == .Property && m.Members != null)
				{
					for (let a in m.Members)
						if (a.HasSpan && i >= a.FirstTok && i <= a.LastTok)
							member = a;
				}
				return;
			}
		}

		/// Locals declared in a method body: name -> declared type text ("var" / "let" when
		/// inferred; "?" when the declaration could not be read).
		static void CollectLocals(CompilationUnit u, Member method, Dictionary<String, String> outLocals)
		{
			if (method == null)
				return;
			if (method.Body != null)
				CollectStmt(u, method.Body, outLocals);
			// Out variables (`Get(1, var v)`), pattern variables and anything the statement
			// tree keeps as text: `var x` / `let x` anywhere in the body.
			int first = method.Body?.FirstTok ?? -1;
			int last = method.Body?.LastTok ?? -2;
			for (int i = first; i < last; i++)
			{
				let tx = u.TokenText(i);
				if ((tx == "var" || tx == "let") && IsIdentTok(u, i + 1) && u.Tokens[i].Kind == .Identifier)
				{
					String name = scope .(Ident(u, i + 1));
					if (!outLocals.ContainsKey(name))
						outLocals[new String(name)] = new String(tx);
				}
			}
		}

		static void AddLocal(Dictionary<String, String> outLocals, StringView name, StringView type)
		{
			if (name.IsEmpty)
				return;
			var n = name;
			if (n.StartsWith('@'))
				n = n.Substring(1);
			if (outLocals.TryGetAlt(n, var key, var value))
			{
				// Declared twice (two blocks, a lambda): its type is not one thing.
				if (value != type)
					value.Set("?");
				return;
			}
			outLocals[new String(n)] = new String(type);
		}

		static void CollectStmt(CompilationUnit u, Stmt s, Dictionary<String, String> outLocals)
		{
			if (s == null)
				return;
			switch (s.Kind)
			{
			case .LocalVar, .ForEach:
				if (s.VarName != null)
				{
					// `int a = 1, b = 2;` keeps "a" only; the others are found by the token scan.
					String type = scope .(s.VarType ?? "?");
					if ((type == "var" || type == "let") && s.Expr != null)
					{
						// `let p = new Player()` / `scope Player()`: the type is known.
						var init = u.NodeText(s.Expr);
						if (init.StartsWith("new ") || init.StartsWith("scope "))
						{
							int sp = init.IndexOf(' ');
							var rest = init.Substring(sp + 1);
							rest.TrimStart();
							int end = 0;
							while (end < rest.Length && (rest[end].IsLetterOrDigit || rest[end] == '_' || rest[end] == '.'))
								end++;
							if (end > 0 && end < rest.Length && rest[end] == '(')
								type.Set(rest.Substring(0, end));
						}
					}
					AddLocal(outLocals, s.VarName, type);
				}
			case .For:
				if (s.ForHeader != null)
				{
					// `int i = 0; ...` / `int i < n`
					var h = StringView(s.ForHeader);
					h.Trim();
					List<StringView> words = scope .();
					for (var w in h.Split(' ', '='))
					{
						w.Trim();
						if (!w.IsEmpty)
							words.Add(w);
					}
					if (words.Count >= 2 && CharUtil.IsIdentStart(words[1][0]))
						AddLocal(outLocals, words[1], words[0]);
				}
			default:
			}
			if (s.Body != null)
				for (let c in s.Body)
					CollectStmt(u, c, outLocals);
			CollectStmt(u, s.Then, outLocals);
			CollectStmt(u, s.Else, outLocals);
			if (s.Cases != null)
				for (let c in s.Cases)
					for (let b in c.Body)
						CollectStmt(u, b, outLocals);
		}

		/// The member text before `.` at token `dot` as a list of name tokens (`a.b.c`), or false
		/// when it is not a plain chain (a call, an index, a cast).
		static bool ChainBefore(CompilationUnit u, int dot, List<int> outToks)
		{
			int i = dot - 1;
			while (true)
			{
				if (!IsIdentTok(u, i))
					return false;
				outToks.Insert(0, i);
				if (IsTok(u, i - 1, ".") && !IsTok(u, i - 2, "."))
				{
					i -= 2;
					continue;
				}
				if (IsTok(u, i - 1, "?.") || IsTok(u, i - 1, ")") || IsTok(u, i - 1, "]"))
					return false;
				return true;
			}
		}

		/// The type a name chain evaluates to ("" when not known); `isType` when the chain names a
		/// type (static access).
		static bool ResolveChain(CompilationUnit u, List<int> toks, Member type, Member member, Dictionary<String, String> locals, TypeService svc, String outType, out bool isType)
		{
			isType = false;
			if (toks.IsEmpty)
				return false;
			let first = Ident(u, toks[0]);
			String cur = scope .();
			ResolveContext ctx = (svc != null) ? ResolveContext.Make(u, type) : null;
			defer { delete ctx; }
			if (first == "this")
				cur.Set(type?.Name ?? "");
			else if (first == "base")
			{
				if (type != null)
					ClassModel.BaseClassOf(u, type, cur);
			}
			else
			{
				bool found = false;
				// Parameters of the enclosing method / indexer.
				if (member != null && member.Params != null)
				{
					for (let p in member.Params)
					{
						if (p.Name == first)
						{
							cur.Set(p.Type);
							found = true;
						}
					}
				}
				if (!found && locals.TryGetValueAlt(first, let lt))
				{
					if (lt == "var" || lt == "let" || lt == "?")
						return false;
					cur.Set(lt);
					found = true;
				}
				if (!found && type != null && svc != null)
				{
					// A field or property of the type (or a base).
					if (svc.FindMemberType(type.Name, first, ctx, cur))
						found = true;
				}
				if (!found && svc != null)
				{
					// A type name, possibly namespace-qualified: try the longest prefix first.
					for (int n = toks.Count; n >= 1; n--)
					{
						let text = u.SpanText(toks[0], toks[n - 1]);
						if (svc.FindType(text, ctx).IsValid)
						{
							cur.Set(text);
							isType = true;
							for (int k = n; k < toks.Count; k++)
							{
								String next = scope .();
								if (!svc.FindMemberType(cur, Ident(u, toks[k]), ctx, next))
									return false;
								cur.Set(next);
								isType = false;
							}
							outType.Set(cur);
							return true;
						}
					}
					return false;
				}
				if (!found)
					return false;
			}
			if (cur.IsEmpty)
				return false;
			for (int k = 1; k < toks.Count; k++)
			{
				if (svc == null)
					return false;
				String next = scope .();
				if (!svc.FindMemberType(cur, Ident(u, toks[k]), ctx, next))
					return false;
				cur.Set(next);
			}
			// `Player*`, `Player?`: the type itself.
			while (cur.EndsWith('*') || cur.EndsWith('?'))
				cur.RemoveFromEnd(1);
			outType.Set(cur);
			return true;
		}

		static bool SameOrDerives(TypeService svc, StringView type, StringView baseType)
		{
			let bt = TypeRules.BaseName(type);
			if (bt == TypeRules.BaseName(baseType))
				return true;
			return svc != null && svc.IsSubtype(bt, baseType);
		}

		/// Occurrences of `name` inside the `{...}` holes of interpolated strings (char offsets).
		static void InterpolatedHits(CompilationUnit u, int tokIdx, StringView name, List<int> outOffsets)
		{
			let tok = u.Tokens[tokIdx];
			let text = u.TokenText(tokIdx);
			if (!text.StartsWith('$') && !text.StartsWith("@$"))
				return;
			int depth = 0;
			for (int i < text.Length)
			{
				char8 c = text[i];
				if (c == '{')
				{
					if (i + 1 < text.Length && text[i + 1] == '{' && depth == 0)
					{
						i++;
						continue;
					}
					depth++;
					continue;
				}
				if (c == '}')
				{
					if (depth > 0)
						depth--;
					continue;
				}
				if (depth == 0 || !CharUtil.IsIdentStart(c) || (i > 0 && CharUtil.IsIdentChar(text[i - 1])))
					continue;
				int e = i;
				while (e < text.Length && CharUtil.IsIdentChar(text[e]))
					e++;
				if (text.Substring(i, e - i) == name && !(i > 0 && text[i - 1] == '.'))
					outOffsets.Add(tok.Start + i);
				i = e - 1;
			}
		}

		// ------------------------------------------------------------------ parameters and locals

		static void PlanLocal(RenameTarget t, List<FileCtx> files, RenamePlan plan)
		{
			FileCtx f = null;
			Member method = null;
			for (let fc in files)
			{
				if (!ProjectIndex.SamePath(fc.Path, t.FilePath))
					continue;
				List<Member> methods = scope .();
				List<Member> owners = scope .();
				fc.Unit.CollectMethods(methods, owners);
				String key = scope .();
				for (int i < methods.Count)
				{
					key.Clear();
					VisualBeef.Graph.GraphBuilder.MakeMethodKey(methods[i], owners[i], key);
					if (key == t.MethodKey)
					{
						f = fc;
						method = methods[i];
					}
				}
			}
			if (method == null || !method.HasSpan)
			{
				plan.Refusal.Set(scope $"The function {t.MethodKey} was not found.");
				return;
			}
			let u = f.Unit;
			Dictionary<String, String> locals = scope .();
			defer { for (let kv in locals) { delete kv.key; delete kv.value; } }
			CollectLocals(u, method, locals);
			bool isParam = false;
			for (let p in method.Params)
				if (p.Name == t.OldName)
					isParam = true;
			if (t.Kind == .Parameter && !isParam)
			{
				plan.Refusal.Set(scope $"{t.OldName} is not a parameter of {method.Name}.");
				return;
			}
			if (t.Kind == .Local && !locals.ContainsKeyAlt(t.OldName))
			{
				plan.Refusal.Set(scope $"{t.OldName} is not a local variable of {method.Name}.");
				return;
			}
			if (isParam && locals.ContainsKeyAlt(t.OldName))
			{
				plan.Refusal.Set(scope $"{t.OldName} is both a parameter and a local of {method.Name}: rename it in the text.");
				return;
			}
			if (locals.TryGetValueAlt(t.OldName, let lt) && lt == "?")
			{
				plan.Refusal.Set(scope $"{t.OldName} is declared more than once in {method.Name} (two blocks or a lambda): rename it in the text.");
				return;
			}
			int first = method.FirstTok;
			int last = method.LastTok;
			// The new name must not be in use in the function (a local, a parameter, a member read
			// by its bare name).
			for (int i = first; i <= last; i++)
			{
				if (IsIdentTok(u, i) && Ident(u, i) == t.NewName && !IsTok(u, i - 1, "."))
				{
					plan.Refusal.Set(scope $"{t.NewName} is already used in {method.Name} (line {u.LineOf(u.Tokens[i].Start)}): the renamed variable would hide it or clash with it.");
					return;
				}
			}
			List<int> hits = scope .();
			for (int i = first; i <= last; i++)
			{
				if (u.Tokens[i].Kind == .String)
				{
					hits.Clear();
					InterpolatedHits(u, i, t.OldName, hits);
					for (let off in hits)
					{
						RenameEdit e;
						e.Start = (int32)off;
						e.End = (int32)(off + t.OldName.Length);
						e.Line = u.LineOf(off);
						f.Out.Edits.Add(e);
					}
					continue;
				}
				if (!IsIdentTok(u, i) || Ident(u, i) != t.OldName)
					continue;
				if (IsTok(u, i - 1, ".") || IsTok(u, i - 1, "?.") || IsTok(u, i - 1, ".."))
					continue; // a member with the same name (`this.x`, `other.x`)
				if (u.TokenText(i).StartsWith('@'))
				{
					AddProblem(plan, f, i, "written with '@': rename it in the text.");
					continue;
				}
				AddEdit(f, i);
			}
		}

		// ------------------------------------------------------------------ members

		static void PlanMember(RenameTarget t, List<FileCtx> files, TypeService svc, RenamePlan plan)
		{
			// The declaration, its overloads, what it overrides.
			int decls = 0;
			bool isOverride = false;
			bool isMethod = false;
			for (let f in files)
			{
				List<Member> types = scope .();
				f.Unit.CollectTypes(types);
				for (let type in types)
				{
					if (type.Name != t.TypeName || type.Members == null)
						continue;
					for (let m in type.Members)
					{
						if ((m.Kind == .Method || m.Kind == .Field || m.Kind == .Property) && !m.IsIndexer && m.Name == t.OldName && !m.IsCtor)
						{
							decls++;
							isMethod = m.Kind == .Method;
							if (Mods.Has(m.Modifiers, "override"))
								isOverride = true;
						}
						if ((m.Kind == .Method || m.Kind == .Field || m.Kind == .Property) && m.Name == t.NewName)
						{
							plan.Refusal.Set(scope $"{t.TypeName} already has a member named {t.NewName}.");
							return;
						}
					}
				}
			}
			if (decls == 0)
			{
				plan.Refusal.Set(scope $"{t.TypeName}.{t.OldName} was not found in the project.");
				return;
			}
			if (decls > 1 && isMethod && !plan.FindOnly)
			{
				plan.Refusal.Set(scope $"{t.TypeName}.{t.OldName} has {decls} overloads: renaming one would leave the calls of the others ambiguous. Rename them in the text.");
				return;
			}
			if (isOverride && !plan.FindOnly)
			{
				plan.Refusal.Set(scope $"{t.TypeName}.{t.OldName} overrides a base member: rename it in the base class (the overrides follow).");
				return;
			}
			if (svc != null && !plan.FindOnly)
			{
				// Implements an interface member? Then the interface decides the name.
				let th = svc.FindType(t.TypeName, null);
				if (th.IsValid)
				{
					bool fromInterface = false;
					svc.VisitHierarchy(th, t.TypeName, scope [&] (bt, map) =>
					{
						if (bt.Store.Str(bt.Rec.Kind) != "interface")
							return true;
						let rec = ref bt.Rec;
						for (int mi = rec.FirstMember; mi < rec.FirstMember + rec.MemberCount; mi++)
							if (bt.Store.Str(bt.Store.Members[mi].Name) == t.OldName)
								fromInterface = true;
						return !fromInterface;
					});
					if (fromInterface)
					{
						plan.Refusal.Set(scope $"{t.TypeName}.{t.OldName} implements an interface member: rename it in the interface.");
						return;
					}
				}
			}

			// Does any other type (project or library) have a member with the old name?
			bool uniqueName = true;
			if (svc != null)
			{
				List<SymbolStore> stores = scope .();
				svc.AllStores(stores);
				for (let store in stores)
				{
					for (int mi < store.Members.Count)
					{
						let mr = ref store.Members[mi];
						if (store.Str(mr.Name) != t.OldName)
							continue;
						let owner = store.Str(store.Types[mr.Owner].Name);
						if (!SameOrDerives(svc, owner, t.TypeName))
						{
							uniqueName = false;
							break;
						}
					}
					if (!uniqueName)
						break;
				}
			}
			else
				uniqueName = false;

			for (let f in files)
			{
				let u = f.Unit;
				Member lastMethod = null;
				Dictionary<String, String> locals = scope .();
				defer { for (let kv in locals) { delete kv.key; delete kv.value; } }
				List<int> chain = scope .();
				List<int> hits = scope .();
				for (int i < u.Tokens.Count)
				{
					let kind = u.Tokens[i].Kind;
					if (kind == .String)
					{
						hits.Clear();
						InterpolatedHits(u, i, t.OldName, hits);
						if (!hits.IsEmpty)
						{
							Member type = null;
							Member member = null;
							Enclosing(u.Members, i, ref type, ref member);
							if (type != null && SameOrDerives(svc, type.Name, t.TypeName))
								AddProblem(plan, f, i, scope $"'{t.OldName}' is read inside an interpolated string: rename it in the text.");
						}
						continue;
					}
					if (kind != .Identifier || Ident(u, i) != t.OldName)
						continue;
					Member type = null;
					Member member = null;
					Enclosing(u.Members, i, ref type, ref member);
					if (member != lastMethod)
					{
						for (let kv in locals) { delete kv.key; delete kv.value; }
						locals.Clear();
						CollectLocals(u, member, locals);
						lastMethod = member;
					}
					// A declaration's own name.
					if (member != null && member.NameTok == i && !member.IsAccessor)
					{
						if (type == null)
							continue;
						if (type.Name == t.TypeName)
						{
							AddEdit(f, i);
							continue;
						}
						if (SameOrDerives(svc, type.Name, t.TypeName))
						{
							if (Mods.Has(member.Modifiers, "override"))
								AddEdit(f, i);
							else
								AddProblem(plan, f, i, scope $"{type.Name} declares its own {t.OldName}, which hides the renamed one: rename it too or rename in the text.");
						}
						continue;
					}
					if (u.TokenText(i).StartsWith('@'))
					{
						if (type != null && SameOrDerives(svc, type.Name, t.TypeName))
							AddProblem(plan, f, i, "written with '@': rename it in the text.");
						continue;
					}
					bool afterDot = IsTok(u, i - 1, ".") || IsTok(u, i - 1, "?.");
					if (!afterDot)
					{
						if (type == null)
							continue;
						if (!SameOrDerives(svc, type.Name, t.TypeName))
						{
							// Object initializer `new T() { Score = 1 }` names a member of T.
							if ((IsTok(u, i - 1, "{") || IsTok(u, i - 1, ",")) && IsTok(u, i + 1, "="))
								AddProblem(plan, f, i, "could be an object initializer of the renamed member's type: rename it in the text.");
							continue;
						}
						// A parameter or local with the same name shadows the member.
						bool shadow = false;
						if (member != null && member.Params != null)
							for (let p in member.Params)
								if (p.Name == t.OldName)
									shadow = true;
						if (shadow)
							continue;
						if (locals.ContainsKeyAlt(t.OldName))
						{
							StringView who = (member != null) ? member.Name : "the function";
							AddProblem(plan, f, i, scope $"{who} has a local named {t.OldName} too: which one is meant here cannot be told.");
							continue;
						}
						AddEdit(f, i);
						continue;
					}
					// `x.Name`: what is x?
					chain.Clear();
					String resolved = scope .();
					bool chainOk = !IsTok(u, i - 1, "?.") && ChainBefore(u, i - 1, chain);
					if (!chainOk || !ResolveChain(u, chain, type, member, locals, svc, resolved, ?))
					{
						// Unknown left side: only the renamed member has this name anywhere, so
						// it can only be this one (or code that does not compile).
						if (uniqueName)
							AddEdit(f, i);
						else if (!chainOk)
							AddProblem(plan, f, i, scope $"what '.{t.OldName}' is read on cannot be told (a call, an index or a cast) and other types have a {t.OldName} too: rename it in the text.");
						else
							AddProblem(plan, f, i, scope $"the type of '{u.SpanText(chain[0], chain[chain.Count - 1])}' is not known here and other types have a {t.OldName} too: rename it in the text.");
						continue;
					}
					if (SameOrDerives(svc, resolved, t.TypeName))
						AddEdit(f, i);
				}
			}
		}

		// ------------------------------------------------------------------ types

		static void PlanType(RenameTarget t, List<FileCtx> files, TypeService svc, RenamePlan plan)
		{
			// Names that could also mean something else in a bare position.
			HashSet<String> other = scope .();
			defer { for (let s in other) delete s; }
			int typeDecls = 0;
			for (let f in files)
			{
				List<Member> types = scope .();
				f.Unit.CollectTypes(types);
				for (let type in types)
				{
					if (type.Name == t.OldName && type.TypeKind != "extension")
						typeDecls++;
					if (type.Name == t.NewName)
					{
						plan.Refusal.Set(scope $"A type named {t.NewName} already exists in the project.");
						return;
					}
					if (type.Members == null)
						continue;
					for (let m in type.Members)
					{
						if ((m.Kind == .Method || m.Kind == .Field || m.Kind == .Property) && m.Name == t.OldName)
							other.Add(new String(scope $"{type.Name}.{m.Name}"));
					}
				}
			}
			if (typeDecls > 1)
			{
				plan.Refusal.Set(scope $"There are {typeDecls} types named {t.OldName} in the project: rename in the text.");
				return;
			}
			for (let f in files)
			{
				let u = f.Unit;
				Member lastMethod = null;
				Dictionary<String, String> locals = scope .();
				defer { for (let kv in locals) { delete kv.key; delete kv.value; } }
				List<int> hits = scope .();
				for (int i < u.Tokens.Count)
				{
					let kind = u.Tokens[i].Kind;
					if (kind == .String)
					{
						hits.Clear();
						InterpolatedHits(u, i, t.OldName, hits);
						if (!hits.IsEmpty)
							AddProblem(plan, f, i, scope $"'{t.OldName}' is used inside an interpolated string: rename it in the text.");
						continue;
					}
					if (kind != .Identifier || Ident(u, i) != t.OldName)
						continue;
					Member type = null;
					Member member = null;
					Enclosing(u.Members, i, ref type, ref member);
					if (type != null && type.NameTok == i)
					{
						AddEdit(f, i); // the declaration (and extensions / partial declarations)
						continue;
					}
					if (member != null && member.NameTok == i && member.Kind != .Method)
						continue; // a field or property that happens to have the name
					if (member != null && member.Kind == .Method && member.NameTok == i)
						continue; // a method named like the type
					if (member != lastMethod)
					{
						for (let kv in locals) { delete kv.key; delete kv.value; }
						locals.Clear();
						CollectLocals(u, member, locals);
						lastMethod = member;
					}
					if (IsTok(u, i - 1, ".") || IsTok(u, i - 1, "?."))
					{
						// `NS.Player`: a namespace before it keeps it a type.
						List<int> chain = scope .();
						if (!IsTok(u, i - 1, "?.") && ChainBefore(u, i - 1, chain))
						{
							bool isNamespace = svc == null || !ResolveChain(u, chain, type, member, locals, svc, scope .(), ?);
							bool known = svc != null && svc.FindType(u.SpanText(chain[0], i), null).IsValid;
							if (isNamespace && (known || other.IsEmpty))
							{
								AddEdit(f, i);
								continue;
							}
						}
						AddProblem(plan, f, i, scope $"'.{t.OldName}' could be a member or the type: rename it in the text.");
						continue;
					}
					// Bare name: a local, parameter or member with that name would be ambiguous.
					bool shadow = locals.ContainsKeyAlt(t.OldName);
					if (member != null && member.Params != null)
						for (let p in member.Params)
							if (p.Name == t.OldName)
								shadow = true;
					if (!shadow && other.IsEmpty)
					{
						AddEdit(f, i);
						continue;
					}
					// Clear type positions: `Player p`, `new Player(`, `: Player`, `<Player>`, `(Player)x`,
					// `typeof(Player)`, `is Player`, `as Player`, `Player.Static`.
					bool typePos = IsIdentTok(u, i + 1) && !IsTok(u, i + 1, "is") && !IsTok(u, i + 1, "as") ||
						IsTok(u, i - 1, "new") || IsTok(u, i - 1, "scope") || IsTok(u, i - 1, "is") || IsTok(u, i - 1, "as") ||
						IsTok(u, i - 1, "<") || IsTok(u, i + 1, ">") ||
						(IsTok(u, i - 1, "(") && IsTok(u, i - 2, "typeof")) ||
						(type != null && type.BaseColonTok >= 0 && i > type.BaseColonTok && i <= type.BaseLastTok) ||
						(IsTok(u, i + 1, "*") && IsIdentTok(u, i + 2));
					if (typePos && !shadow)
						AddEdit(f, i);
					else
						AddProblem(plan, f, i, scope $"'{t.OldName}' here could be the type or a member / variable of the same name: rename it in the text.");
				}
			}
		}
	}
}
