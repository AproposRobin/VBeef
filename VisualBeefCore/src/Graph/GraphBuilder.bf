using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Graph
{
	/// Converts a method's AST into a Blueprint-style graph.
	///
	/// Statements become exec nodes chained left to right; expressions become pure data nodes
	/// feeding their inputs. Literals (and short code that has no visual form) become editable
	/// pin defaults. Every node keeps its original text so unchanged code is reproduced verbatim.
	class GraphBuilder
	{
		/// Optional project-wide symbols (set by the editor) for labeling calls into other files.
		public static ProjectIndex Index;

		CompilationUnit mUnit;
		Graph mGraph;
		Member mMethod;
		Member mOwner;
		/// Known variable types (fields, params, locals) for pin coloring.
		Dictionary<String, String> mVarTypes = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		/// Namespace/usings/owner for type resolution (only with a TypeService installed).
		ResolveContext mResolveCtx ~ delete _;

		/// `let <name>Result = Call();` temps folded into an impure Call node: name -> node, plus
		/// how many reads of the name were turned into links from the node's result.
		Dictionary<String, (Node node, int uses)> mTemps = new .() ~ DeleteDictionaryAndKeys!(_);
		/// Temp names that must stay plain locals (a read could not be turned into a link).
		HashSet<String> mNoFold;

		/// `let __vN = <expr>;` lines (CodeGen's shared values) folded into the value's node, in
		/// runs of consecutive lines, each followed by the statement that first reads them.
		class FoldRun
		{
			public Node Next;
			public List<Node> Temps = new .() ~ delete _;
		}
		List<FoldRun> mFoldRuns = new .() ~ DeleteContainerAndItems!(_);
		List<Node> mValueFolds = new .() ~ delete _;

		/// Out variables in scope for the statements being built: `out let a` (Inline) and
		/// folded `T a;` lines (Declared). Reads of the name become wires from the out pin.
		List<(String name, Pin pin)> mOutVars = new .() ~ { for (let v in _) delete v.name; delete _; };
		/// How many reads of each out pin's variable were turned into wires.
		Dictionary<Pin, int> mOutUses = new .() ~ delete _;
		/// Out pins folded from a `T name;` line: verified after the build (every read wired).
		List<Pin> mDeclFolds = new .() ~ delete _;
		/// Out pins declared inline (`var a`): their name is kept when not every use is wired.
		List<Pin> mInlineOuts = new .() ~ delete _;
		/// A fold of `T name;` lines failed while building (wrong statement, order): rebuild.
		bool mDeclFoldFailed;

		/// `T name;` (or `T name = default;`) lines right before a statement that passes `out name`
		/// (`ref name` for a `[Pin(Out=true)]` parameter): the shape CodeGen writes for out pins.
		class PendingDecl
		{
			public Stmt Decl;
			public bool RefForm;
			public Pin Pin;
		}
		List<PendingDecl> mPending;

		public static Graph Build(CompilationUnit unit, Member method, Member ownerType)
		{
			HashSet<String> noFold = scope .();
			defer { for (let s in noFold) delete s; }
			while (true)
			{
				GraphBuilder b = scope .();
				b.mUnit = unit;
				b.mMethod = method;
				b.mOwner = ownerType;
				b.mNoFold = noFold;
				b.mGraph = new Graph();
				b.Run();
				if (b.VerifyTemps(noFold))
					return b.mGraph;
				// Some temp is read in a way that has no wire (inside raw code, a string, a
				// for-header...). Build again keeping those temps as ordinary locals.
				delete b.mGraph;
			}
		}

		// ------------------------------------------------------------------ temps

		/// Names CodeGen gives impure-call temps: `fooResult`, `fooResult2`...
		static bool IsTempName(StringView name)
		{
			var n = name;
			while (!n.IsEmpty && CharUtil.IsDigit(n[n.Length - 1]))
				n.RemoveFromEnd(1);
			return n.Length > 6 && n.EndsWith("Result") && CharUtil.IsIdentStart(n[0]);
		}

		bool CanFoldTemp(Stmt s)
		{
			if (s.Alloc != null || s.Attributes != null)
				return false;
			if (s.VarType != "let" || s.Expr == null || s.Expr.Kind != .Call || s.VarName == null || !IsTempName(s.VarName))
				return false;
			if (mNoFold.ContainsAlt(StringView(s.VarName)) || mTemps.ContainsKeyAlt(StringView(s.VarName)))
				return false;
			return true;
		}

		/// `let fooResult = Foo(x);` -> an impure Foo call whose result output is wired to every
		/// read of fooResult. This is exactly what CodeGen writes for such a call.
		Node BuildTempCall(Stmt s)
		{
			Node n = NewStatementNode(.Call, s);
			mGraph.AddExecOut(n, "then");
			FillCall(n, s.Expr);
			if (n.Result == null)
				mGraph.AddDataOut(n, "result", "Return Value");
			if (n.Result.TypeName.IsEmpty)
				InferType(s.Expr, n.Result.TypeName);
			n.Text2.Set(s.VarName);
			AddVarType(s.VarName, n.Result.TypeName);
			mTemps[new String(s.VarName)] = (n, 0);
			return n;
		}

		Node FindTemp(StringView name)
		{
			if (mTemps.TryGetAlt(name, var matchKey, var entry))
				return entry.node;
			return null;
		}

		void CountTempUse(StringView name)
		{
			if (mTemps.TryGetRefAlt(name, var matchKey, var entry))
				entry.uses++;
		}

		/// Reads of a folded temp become a link from the call's result; reads of an out variable a
		/// link from the out pin.
		bool TryLinkTemp(Expr e, Pin input)
		{
			if (e == null || e.Kind != .Name)
				return false;
			let call = FindTemp(e.Op);
			if (call == null)
			{
				let outPin = FindOutVar(e.Op);
				if (outPin == null)
					return false;
				mGraph.Connect(outPin, input);
				CountOutUse(outPin);
				return true;
			}
			mGraph.Connect(call.Result, input);
			CountTempUse(e.Op);
			return true;
		}

		/// The folded temp a name chain (`fooResult.a.b`) starts with, or null.
		Node ChainTemp(Expr e, out StringView rootName)
		{
			rootName = default;
			var root = e;
			while (root != null && root.Kind == .Member)
				root = root.A;
			if (root == null || root.Kind != .Name)
				return null;
			rootName = root.Op;
			return FindTemp(root.Op);
		}

		/// Every read of every folded temp must have become a link; otherwise the round trip
		/// would lose the variable. Returns false (and records the names) when some did not.
		bool VerifyTemps(HashSet<String> noFold)
		{
			bool ok = VerifyDeclFolds(noFold);
			if (mTemps.IsEmpty)
				return ok;
			for (let kv in mTemps)
			{
				int refs = CountNameRefs(kv.key);
				// The declaration itself is one reference.
				if (kv.value.uses == 0 || kv.value.uses != refs - 1)
				{
					if (!noFold.ContainsAlt(StringView(kv.key)))
						noFold.Add(new String(kv.key));
					ok = false;
				}
			}
			if (!VerifyValueFolds(noFold))
				ok = false;
			return ok;
		}

		/// A folded `T name;` line is exactly what CodeGen writes for an out pin only when every
		/// other read of `name` became a wire from the pin (and the fold itself worked).
		bool VerifyDeclFolds(HashSet<String> noFold)
		{
			for (let p in mInlineOuts)
			{
				int uses = 0;
				mOutUses.TryGetValue(p, out uses);
				// The declaration in the argument is one reference.
				if (CountNameRefs(p.OutName) != uses + 1)
					p.OutKeepName = true;
			}
			bool ok = !mDeclFoldFailed;
			for (let p in mDeclFolds)
			{
				int uses = 0;
				mOutUses.TryGetValue(p, out uses);
				// The declaration and the `out name` argument are two references.
				if (CountNameRefs(p.OutName) != uses + 2)
				{
					if (!noFold.ContainsAlt(StringView(p.OutName)))
						noFold.Add(new String(p.OutName));
					ok = false;
				}
			}
			return ok;
		}

		/// A folded shared value must be exactly what CodeGen writes back: shared (read at least
		/// twice), not trivial, and declared right before the statement that first reads it, in
		/// the order CodeGen declares them. Otherwise the line stays an ordinary local, so
		/// regenerating can never move code.
		bool VerifyValueFolds(HashSet<String> noFold)
		{
			if (mFoldRuns.IsEmpty)
				return true;
			bool ok = true;
			HashSet<Node> all = scope .();
			for (let n in mValueFolds)
				all.Add(n);
			for (let run in mFoldRuns)
			{
				bool good = run.Next != null && run.Next.Kind != .While && run.Next.Kind != .DoWhile;
				for (let t in run.Temps)
				{
					int uses = 0;
					if (mTemps.TryGetAlt(StringView(t.Text2), var matchKey, var entry))
						uses = entry.uses;
					if (uses < 2 || CodeGen.IsTrivialValue(mGraph, t, null))
						good = false;
				}
				if (good)
				{
					HashSet<Node> declared = scope .();
					for (let n in mValueFolds)
						if (!run.Temps.Contains(n))
							declared.Add(n);
					List<Node> order = scope .();
					CodeGen.CollectHeaderTemps(mGraph, run.Next, all, declared, order);
					if (order.Count != run.Temps.Count)
						good = false;
					else
					{
						for (int i < order.Count)
							if (order[i] != run.Temps[i])
								good = false;
					}
				}
				if (!good)
				{
					for (let t in run.Temps)
						if (!noFold.ContainsAlt(StringView(t.Text2)))
							noFold.Add(new String(t.Text2));
					ok = false;
				}
			}
			return ok;
		}

		/// Names CodeGen gives shared values: `__v1`, `__v2`...
		static bool IsValueTempName(StringView name)
		{
			if (name.Length < 4 || !name.StartsWith("__v"))
				return false;
			for (int i = 3; i < name.Length; i++)
				if (!CharUtil.IsDigit(name[i]))
					return false;
			return true;
		}

		bool CanFoldValueTemp(Stmt s)
		{
			if (s.Alloc != null || s.Attributes != null)
				return false;
			if (s.Kind != .LocalVar || s.VarType != "let" || s.Expr == null || s.VarName == null || !IsValueTempName(s.VarName))
				return false;
			if (mNoFold.ContainsAlt(StringView(s.VarName)) || mTemps.ContainsKeyAlt(StringView(s.VarName)))
				return false;
			return true;
		}

		/// `let __v1 = list.Pop();` -> the `list.Pop()` node, wired to every read of __v1.
		Node BuildValueTemp(Stmt s)
		{
			let e = Unparen(s.Expr);
			Node n = BuildExprNode(e);
			n.Text2.Set(s.VarName);
			SetTrivia(n, s);
			mTemps[new String(s.VarName)] = (n, 0);
			mValueFolds.Add(n);
			return n;
		}

		int CountNameRefs(StringView name)
		{
			let body = mMethod.Body;
			if (body == null || !body.HasSpan)
				return 0;
			int last = (body.CloseTok >= 0) ? body.CloseTok : body.LastTok;
			int count = 0;
			for (int i = body.FirstTok; i <= last; i++)
			{
				let tok = mUnit.Tokens[i];
				let text = mUnit.TokenText(i);
				if (tok.Kind == .Identifier)
				{
					if (text == name || (text.StartsWith('@') && text.Substring(1) == name))
						count++;
				}
				else if (tok.Kind == .String)
				{
					// Interpolated strings can read it too.
					int at = 0;
					while (at < text.Length)
					{
						let idx = text.Substring(at).IndexOf(name);
						if (idx < 0)
							break;
						let s = at + idx;
						let e = s + name.Length;
						bool startOk = s == 0 || !CharUtil.IsIdentChar(text[s - 1]);
						bool endOk = e >= text.Length || !CharUtil.IsIdentChar(text[e]);
						if (startOk && endOk)
							count++;
						at = e;
					}
				}
			}
			return count;
		}

		// ------------------------------------------------------------------ well-known symbols

		/// A few corlib functions the action menu offers, so calls to them look the same whether
		/// or not the project index has them (e.g. no `Return Value` on Console.WriteLine).
		static List<SymbolType> sWellKnown ~ DeleteContainerAndItems!(_);

		static void AddWellKnown(StringView typeName, StringView methodName, StringView returnType, StringView paramsText)
		{
			SymbolType type = null;
			for (let t in sWellKnown)
				if (t.Name == typeName)
					type = t;
			if (type == null)
			{
				type = new .();
				type.Name.Set(typeName);
				type.Kind.Set("class");
				sWellKnown.Add(type);
			}
			SymbolMethod m = new .();
			m.Name.Set(methodName);
			m.ReturnType.Set(returnType);
			m.ParamsText.Set(paramsText);
			m.IsStatic = true;
			for (var part in paramsText.Split(','))
			{
				part.Trim();
				if (part.IsEmpty)
					continue;
				int space = part.LastIndexOf(' ');
				m.ParamTypes.Add(new String(part.Substring(0, Math.Max(space, 0))));
				m.ParamNames.Add(new String(part.Substring(space + 1)));
			}
			type.Methods.Add(m);
		}

		public static SymbolType FindWellKnownType(StringView typeName)
		{
			if (sWellKnown == null)
			{
				sWellKnown = new .();
				AddWellKnown("Console", "WriteLine", "void", "String format");
				AddWellKnown("Console", "Write", "void", "String format");
				AddWellKnown("Math", "Min", "var", "var a, var b");
				AddWellKnown("Math", "Max", "var", "var a, var b");
				AddWellKnown("Math", "Clamp", "var", "var value, var min, var max");
				AddWellKnown("Math", "Abs", "var", "var value");
				AddWellKnown("Math", "Sqrt", "double", "double value");
				AddWellKnown("Math", "Lerp", "float", "float a, float b, float t");
				AddWellKnown("Runtime", "Assert", "void", "bool condition");
			}
			for (let t in sWellKnown)
				if (t.Name == typeName)
					return t;
			return null;
		}

		public static void MakeMethodKey(Member method, Member owner, String outKey)
		{
			if (owner != null)
			{
				outKey.Append(owner.Name);
				outKey.Append(".");
			}
			outKey.Append(method.Name);
			outKey.Append("(");
			if (method.Params != null)
			{
				for (let p in method.Params)
				{
					if (@p.Index > 0)
						outKey.Append(",");
					outKey.Append(p.Type);
				}
			}
			outKey.Append(")");
			if (method.KeySuffix != null)
				outKey.Append(method.KeySuffix); // ` [else BF_X]`: one of two arms of an #if
			if (method.Kind == .Broken)
				outKey.Append("!broken");
		}

		/// Declaration errors the compiler would report on the function itself, shown on its
		/// entry node (read-only: nothing is refused, the text is what the user wrote):
		/// `var F()` outside a [Comptime] function and `let F()`. Called again when the
		/// signature changes (SourceDocument.Rekey).
		public static void SetEntryDeclError(Node entry, Member m)
		{
			DeleteAndNullify!(entry.Error);
			if (m == null || m.Kind != .Method)
				return;
			String msg = scope .();
			if (m.GetDeclError(msg))
				entry.Error = new String(msg);
		}

		void AddVarType(StringView name, StringView type)
		{
			if (name.IsEmpty)
				return;
			String key = scope .(name);
			if (mVarTypes.TryGetValue(key, let existing))
			{
				existing.Set(type);
				return;
			}
			mVarTypes[new String(name)] = new String(type);
		}

		void Run()
		{
			if (TypeService.Current != null)
				mResolveCtx = ResolveContext.Make(mUnit, mOwner);
			MakeMethodKey(mMethod, mOwner, mGraph.MethodKey);
			mGraph.MethodName.Set(mMethod.Name);
			if (mMethod.CondPath != null)
				mGraph.CondPath = new String(mMethod.CondPath);
			mGraph.DeclModifiers.Set(mMethod.Modifiers);
			if (mOwner != null)
				mGraph.SelfType.Set(mOwner.Name);
			mGraph.StaticContext = IsStaticMember(mMethod, mOwner) || mOwner == null;
			mGraph.InLibrary = mOwner != null && mOwner.IsNodeLibrary;

			if (mOwner != null && mOwner.Members != null)
			{
				for (let m in mOwner.Members)
					if (m.Kind == .Field || m.Kind == .Property)
						AddVarType(m.Name, m.TypeText);
			}

			Node entry = mGraph.AddNode(.Entry);
			entry.Text.Set(mMethod.Name);
			if (mMethod.TypeText != null)
				entry.Text2.Set(mMethod.TypeText);
			mGraph.AddExecOut(entry, "then");
			for (let p in mMethod.Params)
			{
				AddVarType(p.Name, p.Type);
				// Parameters are shown on the entry node for reference; they're read with Get nodes.
				let pin = mGraph.AddDataOut(entry, scope $"param{@p.Index}", p.Name);
				pin.TypeName.Set(p.Type);
			}
			entry.Original = new String("");
			SetEntryDeclError(entry, mMethod);
			SetLines(entry, mMethod);
			if (mMethod.Body != null && mMethod.Body.HasSpan)
				entry.LineEnd = mUnit.LineOf(mUnit.Tokens[mMethod.Body.FirstTok].Start);
			mGraph.Entry = entry;

			if (mMethod.Kind == .Broken)
			{
				// The parser could not read this member: one red read-only node holds its text.
				mGraph.ReadOnly = true;
				Node broken = mGraph.AddNode(.Code);
				broken.Text.Set(mUnit.NodeText(mMethod));
				broken.Original = new String(broken.Text);
				broken.Error = new String(mMethod.Error);
				mGraph.AddExecIn(broken);
				mGraph.Connect(entry.Then, broken.ExecIn);
				broken.Edited = false;
				return;
			}

			let body = mMethod.Body;
			if (body == null)
				return;

			// Trivia after '{' and before '}'
			{
				mGraph.RawOpenTrail = new String(mUnit.TrailingTrivia(body.FirstTok));
				mGraph.RawCloseLead = new String(mUnit.LeadingTrivia(body.CloseTok));
				mGraph.CloseAtLineStart = mUnit.TrailingTrivia(body.CloseTok - 1).EndsWith('\n');
				String end = scope .();
				NormalizeComments(mUnit.LeadingTrivia(body.CloseTok), end);
				if (!end.IsEmpty)
					mGraph.EndComments = new String(end);
			}

			BuildChain(body.Body, entry.Then);
			InferConstructTypes();

			for (let n in mGraph.Nodes)
			{
				n.Edited = false;
				n.Moved = false;
			}
			// Wires that come from the code (GraphValidator re-checks only the ones made later).
			for (let l in mGraph.Links)
				l.Parsed = true;
		}

		/// A member of a static type, a `static { }` block, or declared `static`.
		static bool IsStaticMember(Member m, Member owner)
		{
			if (m.IsStatic || ProjectIndex.HasWord(m.Modifiers, "static"))
				return true;
			return owner != null && (owner.IsStatic || ProjectIndex.HasWord(owner.Modifiers, "static"));
		}

		// ------------------------------------------------------------------ trivia

		/// Trims a trailing-trivia string down to its comment ("// foo"), or empty.
		public static void TrimComment(StringView trivia, String outComment)
		{
			var t = trivia;
			t.Trim();
			if (t.StartsWith("//") || t.StartsWith("/*"))
				outComment.Append(t);
		}

		/// Converts leading trivia into normalized comment lines. Blank lines become "" entries;
		/// leading indentation is stripped. The final (indentation-only) line is dropped.
		public static void NormalizeComments(StringView trivia, String outLines)
		{
			List<StringView> lines = scope .();
			for (let line in trivia.Split('\n'))
				lines.Add(line);
			if (lines.Count <= 1)
				return; // only indentation before the token
			// Every line except the last ends with '\n' in the original; the last is the indent
			// before the token. Blank lines are kept as empty lines.
			for (int i = 0; i < lines.Count - 1; i++)
			{
				var line = lines[i];
				line.Trim();
				outLines.Append(line);
				outLines.Append("\n");
			}
		}

		void SetTrivia(Node node, SyntaxNode syntax)
		{
			SetTriviaRange(node, syntax.FirstTok, syntax.LastTok);
		}

		void SetTriviaRange(Node node, int firstTok, int lastTok)
		{
			node.RawLead = new String(mUnit.LeadingTrivia(firstTok));
			node.RawTrail = new String(mUnit.TrailingTrivia(lastTok));
			String lead = scope .();
			NormalizeComments(mUnit.LeadingTrivia(firstTok), lead);
			if (!lead.IsEmpty)
				node.LeadingComments = new String(lead);
			String trail = scope .();
			TrimComment(mUnit.TrailingTrivia(lastTok), trail);
			if (!trail.IsEmpty)
				node.TrailingComment = new String(trail);
		}

		// ------------------------------------------------------------------ statements

		void BuildChain(List<Stmt> stmts, Pin execOut)
		{
			var execOut;
			// Out variables declared in this block are visible to its later statements and to
			// nested blocks, not after the block.
			int outScope = mOutVars.Count;
			let outerPending = mPending;
			mPending = null;
			List<PendingDecl> pending = scope .();
			defer
			{
				while (mOutVars.Count > outScope)
					delete mOutVars.PopBack().name;
				mPending = outerPending;
				ClearAndDeleteItems!(pending);
			}
			FoldRun run = null;
			for (int i = 0; i < stmts.Count; i++)
			{
				let s = stmts[i];
				// `T a;` lines CodeGen writes in front of a statement that passes `out a`.
				if (run == null && CanFoldOutDecl(stmts, i, let refForm))
				{
					PendingDecl d = new .();
					d.Decl = s;
					d.RefForm = refForm;
					pending.Add(d);
					mPending = pending;
					continue;
				}
				if (CanFoldValueTemp(s))
				{
					let t = BuildValueTemp(s);
					if (run == null)
					{
						run = new .();
						mFoldRuns.Add(run);
					}
					run.Temps.Add(t);
					continue;
				}
				Node n = IsSequenceStart(s) ? BuildSequence(stmts, ref i) : BuildStatement(s);
				if (!pending.IsEmpty)
				{
					CheckPending(n, pending);
					ClearAndDeleteItems!(pending);
					mPending = null;
				}
				if (run != null)
				{
					run.Next = n;
					run = null;
				}
				if (execOut != null)
					mGraph.Connect(execOut, n.ExecIn);
				execOut = n.Then;
			}
		}

		// ------------------------------------------------------------------ out variables

		/// `T name;` with a type (not let / var) and no value, or `T name = default;`.
		bool IsOutDeclShape(Stmt s, out bool refForm)
		{
			refForm = false;
			if (s.Alloc != null || s.Attributes != null)
				return false;
			if (s.Kind != .LocalVar || s.VarName == null || s.VarType == null || s.VarType == "let" || s.VarType == "var")
				return false;
			if (s.Expr != null)
			{
				let v = Unparen(s.Expr);
				if (v.Kind != .Literal || mUnit.NodeText(v) != "default")
					return false;
				refForm = true;
			}
			return !mNoFold.ContainsAlt(StringView(s.VarName)) && !mTemps.ContainsKeyAlt(StringView(s.VarName));
		}

		/// stmts[i] is a declaration CodeGen writes for an out pin of the statement after the
		/// declarations (and shared-value lines): that statement passes `out name` (`ref name`).
		bool CanFoldOutDecl(List<Stmt> stmts, int i, out bool refForm)
		{
			if (!IsOutDeclShape(stmts[i], out refForm))
				return false;
			int j = i + 1;
			while (j < stmts.Count && (IsOutDeclShape(stmts[j], ?) || CanFoldValueTemp(stmts[j])))
				j++;
			if (j >= stmts.Count)
				return false;
			let next = stmts[j];
			if (next.Kind == .Raw || next.Kind == .Block || !next.HasSpan)
				return false;
			StringView word = refForm ? "ref" : "out";
			let name = stmts[i].VarName;
			for (int t = next.FirstTok; t < next.LastTok; t++)
				if (mUnit.TokenText(t) == word && mUnit.TokenText(t + 1) == name)
					return true;
			return false;
		}

		/// The declaration pending for `out name` / `ref name` in the statement being built.
		PendingDecl TakePending(StringView name, bool refForm)
		{
			if (mPending == null)
				return null;
			for (let d in mPending)
				if (d.Pin == null && d.RefForm == refForm && d.Decl.VarName == name)
					return d;
			return null;
		}

		/// After the statement: every pending declaration became an out pin of it, in the order
		/// CodeGen declares them. Otherwise the names stay ordinary locals (rebuild).
		void CheckPending(Node stmt, List<PendingDecl> pending)
		{
			bool ok = true;
			for (let d in pending)
				if (d.Pin == null)
					ok = false;
			if (ok)
			{
				List<Pin> order = scope .();
				CodeGen.CollectOutPins(mGraph, stmt, null, order);
				int k = 0;
				for (let p in order)
				{
					bool mine = false;
					for (let d in pending)
						if (d.Pin == p)
							mine = true;
					if (!mine)
						continue;
					if (k >= pending.Count || pending[k].Pin != p)
						ok = false;
					k++;
				}
				if (k != pending.Count)
					ok = false;
			}
			if (ok)
				return;
			mDeclFoldFailed = true;
			for (let d in pending)
				if (!mNoFold.ContainsAlt(StringView(d.Decl.VarName)))
					mNoFold.Add(new String(d.Decl.VarName));
		}

		void AddOutVar(StringView name, Pin pin)
		{
			mOutVars.Add((new String(name), pin));
		}

		Pin FindOutVar(StringView name)
		{
			for (int i = mOutVars.Count - 1; i >= 0; i--)
				if (mOutVars[i].name == name)
					return mOutVars[i].pin;
			return null;
		}

		void CountOutUse(Pin pin)
		{
			if (mOutUses.TryAdd(pin, let keyPtr, let valuePtr))
				*valuePtr = 1;
			else
				(*valuePtr)++;
		}

		/// An out variable declared in the argument (an argument the parser keeps as text):
		/// Beef's `var a` / `let a`, or `out let a`, `out var a`, `out int a` (`keyword`).
		bool ParseInlineOut(Expr e, out bool keyword, out StringView decl, out StringView name)
		{
			keyword = false;
			decl = default;
			name = default;
			if (!e.HasSpan)
				return false;
			int first = e.FirstTok;
			let last = (int)e.LastTok;
			if (mUnit.TokenText(first) == "out")
			{
				keyword = true;
				first++;
			}
			if (last - first < 1 || mUnit.Tokens[last].Kind != .Identifier)
				return false;
			let declText = mUnit.SpanText(first, last - 1);
			if (!keyword && declText != "var" && declText != "let")
				return false;
			for (int t = first; t < last; t++)
			{
				let tok = mUnit.Tokens[t];
				let text = mUnit.TokenText(t);
				if (tok.Kind == .Identifier)
					continue;
				if (text == "." || text == "<" || text == ">" || text == "," || text == "*" || text == "?" || text == "[" || text == "]")
					continue;
				return false;
			}
			name = mUnit.TokenText(last);
			if (Parser.IsReservedWord(name))
				return false;
			decl = declText;
			return true;
		}

		/// A `ref` parameter tagged `[Pin(Out=true)]`.
		static bool IsOutRefAttr(StringView attributes)
		{
			if (attributes.IsEmpty || !attributes.Contains("Out"))
				return false;
			List<AttrInfo> attrs = scope .();
			defer { ClearAndDeleteItems!(attrs); }
			AttributeParser.Parse(attributes, attrs);
			let pin = AttributeParser.Find(attrs, "Pin");
			return pin != null && pin.GetBool("Out");
		}

		/// A `{ }` block whose leading comments hold the line `// vb:sequence` starts a Sequence
		/// macro: that block and the plain blocks right after it are its Then outputs.
		bool IsSequenceStart(Stmt s)
		{
			if (s.Kind != .Block || !s.HasSpan)
				return false;
			for (let line in mUnit.LeadingTrivia(s.FirstTok).Split('\n'))
			{
				var l = line;
				l.Trim();
				if (l == FlowMacros.SequenceMarker)
					return true;
			}
			return false;
		}

		Node BuildSequence(List<Stmt> stmts, ref int i)
		{
			let first = stmts[i];
			int last = i;
			while (last + 1 < stmts.Count && stmts[last + 1].Kind == .Block && !IsSequenceStart(stmts[last + 1]))
				last++;
			let lastStmt = stmts[last];
			Node n = mGraph.AddNode(.Flow);
			n.Original = new String(mUnit.SpanText(first.FirstTok, lastStmt.LastTok));
			n.Line = mUnit.LineOf(mUnit.Tokens[first.FirstTok].Start);
			n.LineEnd = mUnit.LineOf(mUnit.Tokens[lastStmt.LastTok].End);
			SetTriviaRange(n, first.FirstTok, lastStmt.LastTok);
			mGraph.AddExecIn(n);
			FlowMacros.Setup(mGraph, n, FlowMacros.Sequence, last - i + 1);
			for (int k = i; k <= last; k++)
				BuildBody(stmts[k], n.FindOutput(scope $"seq{k - i}"));
			i = last;
			return n;
		}

		/// The statements of a block after its first `skip` ones (a macro's own bookkeeping line).
		void BuildBlockFrom(Stmt block, int skip, Pin execOut)
		{
			List<Stmt> rest = scope .();
			for (int i = skip; i < block.Body.Count; i++)
				rest.Add(block.Body[i]);
			BuildChain(rest, execOut);
			if (block.CloseTok >= 0)
			{
				String end = scope .();
				NormalizeComments(mUnit.LeadingTrivia(block.CloseTok), end);
				if (!end.IsEmpty)
					execOut.EndComments = new String(end);
			}
		}

		void BuildBody(Stmt s, Pin execOut)
		{
			if (s == null)
				return;
			if (s.Kind == .Block)
			{
				BuildChain(s.Body, execOut);
				if (s.CloseTok >= 0)
				{
					String end = scope .();
					NormalizeComments(mUnit.LeadingTrivia(s.CloseTok), end);
					if (!end.IsEmpty)
						execOut.EndComments = new String(end);
				}
				return;
			}
			List<Stmt> single = scope .();
			single.Add(s);
			BuildChain(single, execOut);
		}

		void SetLines(Node n, SyntaxNode syntax)
		{
			if (!syntax.HasSpan)
				return;
			n.Line = mUnit.LineOf(mUnit.Tokens[syntax.FirstTok].Start);
			n.LineEnd = mUnit.LineOf(mUnit.Tokens[syntax.LastTok].End);
		}

		Node NewStatementNode(NodeKind kind, Stmt s)
		{
			Node n = mGraph.AddNode(kind);
			n.Original = new String(mUnit.NodeText(s));
			SetLines(n, s);
			SetTrivia(n, s);
			if (s.Attributes != null)
				n.Attributes = new String(s.Attributes);
			mGraph.AddExecIn(n);
			return n;
		}

		Node BuildStatement(Stmt s)
		{
			switch (s.Kind)
			{
			case .Expr:
				let e = Unparen(s.Expr);
				if (e.Kind == .Call)
				{
					Node n = NewStatementNode(.Call, s);
					mGraph.AddExecOut(n, "then");
					FillCall(n, e);
					return n;
				}
				if (e.Kind == .Assign)
				{
					let action = TryBuildFlowAction(s, e);
					if (action != null)
						return action;
					Node n = NewStatementNode(.Set, s);
					mGraph.AddExecOut(n, "then");
					n.Text.Set(e.Op);
					// The variable being set (a field, parameter or local), not a call's Receiver.
					let target = mGraph.AddDataIn(n, "target", "Variable");
					BuildTargetInput(target, e.A, false);
					let value = mGraph.AddDataIn(n, "value", "Value");
					BuildInput(value, e.B);
					target.TypeName.Set(value.TypeName);
					if (target.TypeName.IsEmpty)
						InferType(e.A, target.TypeName);
					return n;
				}
				if (e.Kind == .Unary && (e.Op == "++" || e.Op == "--"))
				{
					Node n = NewStatementNode(.Set, s);
					mGraph.AddExecOut(n, "then");
					n.Text.Set(e.Op);
					n.Postfix = e.Postfix;
					let target = mGraph.AddDataIn(n, "target", "Variable");
					BuildTargetInput(target, e.A, false);
					InferType(e.A, target.TypeName);
					return n;
				}
				return BuildCodeNode(s);

			case .LocalVar:
				if (CanFoldTemp(s))
					return BuildTempCall(s);
				Node n = NewStatementNode(.LocalVar, s);
				mGraph.AddExecOut(n, "then");
				n.Text.Set(s.VarName);
				n.Text2.Set(s.VarType);
				if (s.Alloc != null)
					n.Alloc = new String(s.Alloc); // `const` / `ref`
				let varOut = mGraph.AddDataOut(n, "variable", s.VarName);
				let value = mGraph.AddDataIn(n, "value", "Value");
				value.Optional = true;
				if (s.Expr != null)
					BuildInput(value, s.Expr);
				if (s.VarType != "let" && s.VarType != "var")
				{
					value.TypeName.Set(s.VarType);
					AddVarType(s.VarName, s.VarType);
				}
				else
					AddVarType(s.VarName, value.TypeName);
				varOut.TypeName.Set(value.TypeName);
				return n;

			case .If:
				let macro = TryBuildFlowIf(s);
				if (macro != null)
					return macro;
				let match = TryBuildResultMatch(s);
				if (match != null)
					return match;
				Node n = NewStatementNode(.Branch, s);
				let cond = mGraph.AddDataIn(n, "condition", "Condition");
				cond.TypeName.Set("bool");
				BuildInput(cond, s.Expr);
				let t = mGraph.AddExecOut(n, "true", "True");
				let f = mGraph.AddExecOut(n, "false", "False");
				mGraph.AddExecOut(n, "then", "Completed");
				BuildBody(s.Then, t);
				BuildBody(s.Else, f);
				return n;

			case .While, .DoWhile:
				Node n = NewStatementNode((s.Kind == .While) ? .While : .DoWhile, s);
				if (s.Alloc != null)
					n.Alloc = new String(s.Alloc); // `repeat`
				let cond = mGraph.AddDataIn(n, "condition", "Condition");
				cond.TypeName.Set("bool");
				BuildInput(cond, s.Expr);
				let body = mGraph.AddExecOut(n, "body", "Loop Body");
				mGraph.AddExecOut(n, "then", "Completed");
				BuildBody(s.Then, body);
				return n;

			case .For:
				Node n = NewStatementNode(.For, s);
				let body = mGraph.AddExecOut(n, "body", "Loop Body");
				mGraph.AddExecOut(n, "then", "Completed");
				if (s.VarName != null && s.Expr2 != null)
				{
					// A counting loop: the counter is an output pin, start and count are inputs.
					n.Text.Set(s.VarName);
					n.Text2.Set(s.VarType);
					bool typed = s.VarType != "var";
					if (s.Expr != null)
					{
						let first = mGraph.AddDataIn(n, "start", "Start");
						if (typed)
							first.TypeName.Set(s.VarType);
						BuildInput(first, s.Expr);
					}
					let count = mGraph.AddDataIn(n, "count", "Count");
					if (typed)
						count.TypeName.Set(s.VarType);
					BuildInput(count, s.Expr2);
					let counter = mGraph.AddDataOut(n, "counter", s.VarName);
					if (typed)
						counter.TypeName.Set(s.VarType);
					else if (s.Expr != null)
						InferType(s.Expr, counter.TypeName);
					if (counter.TypeName.IsEmpty)
						counter.TypeName.Set("int");
					AddVarType(s.VarName, counter.TypeName);
				}
				else
					n.Text.Set(s.ForHeader);
				BuildBody(s.Then, body);
				return n;

			case .ForEach:
				Node n = NewStatementNode(.ForEach, s);
				n.Text.Set(s.VarName);
				n.Text2.Set(s.VarType);
				let coll = mGraph.AddDataIn(n, "collection", "Collection");
				BuildInput(coll, s.Expr);
				let body = mGraph.AddExecOut(n, "body", "Loop Body");
				mGraph.AddExecOut(n, "then", "Completed");
				let element = mGraph.AddDataOut(n, "element", s.VarName);
				if (s.VarType != "let" && s.VarType != "var")
				{
					AddVarType(s.VarName, s.VarType);
					element.TypeName.Set(s.VarType);
				}
				BuildBody(s.Then, body);
				return n;

			case .Return:
				Node n = NewStatementNode(.Return, s);
				let value = mGraph.AddDataIn(n, "value", "Return Value");
				value.Optional = true;
				if (mMethod.TypeText != null)
					value.TypeName.Set(mMethod.TypeText);
				if (s.Expr != null)
					BuildInput(value, s.Expr);
				mGraph.AddExecOut(n, "then"); // only used for code after the return
				return n;

			case .Break, .Continue:
				Node n = NewStatementNode((s.Kind == .Break) ? .Break : .Continue, s);
				mGraph.AddExecOut(n, "then");
				return n;

			case .Switch:
				return BuildSwitch(s);

			case .Block:
				// A nested `{ }` block: a Scope node whose Body is the block.
				Node n = NewStatementNode(.Scope, s);
				let body = mGraph.AddExecOut(n, "body", "Body");
				mGraph.AddExecOut(n, "then", "Completed");
				BuildBody(s, body);
				return n;

			case .LocalFunc:
				return BuildLocalFunc(s);

			case .Raw:
				return BuildCodeNode(s);

			case .Delete:
				return BuildDelete(s);

			case .Defer:
				return BuildDefer(s);

			case .Using:
				return BuildUsing(s);
			}
		}

		Node BuildCodeNode(Stmt s)
		{
			Node n = NewStatementNode(.Code, s);
			n.Text.Set(mUnit.NodeText(s));
			if (s.RawReason != null)
				n.Reason = new String(s.RawReason);
			mGraph.AddExecOut(n, "then");
			return n;
		}

		// ------------------------------------------------------------------ switch

		Node BuildSwitch(Stmt s)
		{
			Node n = NewStatementNode(.Switch, s);
			let value = mGraph.AddDataIn(n, "value", "Value");
			BuildInput(value, s.Expr);
			int caseIndex = 0;
			bool hasDefault = false;
			for (let c in s.Cases)
			{
				Pin pin;
				if (c.IsDefault)
				{
					hasDefault = true;
					pin = mGraph.AddExecOut(n, "default", "Default");
					pin.Optional = true;
				}
				else
					pin = mGraph.AddExecOut(n, scope $"case{caseIndex++}", c.Label);
				pin.RawLead = new String(mUnit.LeadingTrivia(c.FirstTok));
				let colon = mUnit.Tokens[c.ColonTok];
				let caseStart = mUnit.Tokens[c.FirstTok].Start;
				pin.RawTail = new String(StringView(mUnit.Text, caseStart, colon.TrailEnd - caseStart));
				if (c.BindName != null)
				{
					// `case .Ok(let v):` - the payload is a pin, read by wires inside this case only.
					let payload = mGraph.AddDataOut(n, scope $"{pin.Name}.payload", c.BindName);
					payload.Mode = .Out;
					payload.Form = .Inline;
					payload.OutName = new String(c.BindName);
					payload.OutDecl = new String(c.BindDecl);
					if (c.BindCase == "Ok" || c.BindCase == "Err")
						ResultPayloadType(value.TypeName, c.BindCase == "Ok", payload.TypeName);
					AddVarType(c.BindName, payload.TypeName);
					int scopeMark = mOutVars.Count;
					AddOutVar(c.BindName, payload);
					mInlineOuts.Add(payload);
					BuildChain(c.Body, pin);
					while (mOutVars.Count > scopeMark)
						delete mOutVars.PopBack().name;
					continue;
				}
				BuildChain(c.Body, pin);
			}
			if (!hasDefault)
				mGraph.AddExecOut(n, "default", "Default");
			let then = mGraph.AddExecOut(n, "then", "Completed");
			if (s.CloseTok >= 0)
			{
				String end = scope .();
				NormalizeComments(mUnit.LeadingTrivia(s.CloseTok), end);
				if (!end.IsEmpty)
					then.EndComments = new String(end);
			}
			return n;
		}

		// ------------------------------------------------------------------ lifetime nodes

		/// `delete x;` -> a Delete node whose Object input reads x (docs/Lifetime-Nodes.md).
		Node BuildDelete(Stmt s)
		{
			Node n = NewStatementNode(.Delete, s);
			n.Alloc = new String(s.Alloc);
			let value = mGraph.AddDataIn(n, "value", "Object");
			BuildInput(value, s.Expr);
			mGraph.AddExecOut(n, "then");
			return n;
		}

		/// `defer <stmt>` / `defer { ... }` -> a Defer node; the statements hang off Deferred.
		Node BuildDefer(Stmt s)
		{
			Node n = NewStatementNode(.Defer, s);
			n.Alloc = new String(s.Alloc);
			let body = mGraph.AddExecOut(n, "body", "Deferred");
			mGraph.AddExecOut(n, "then", "Completed");
			BuildBody(s.Then, body);
			if (s.Then != null && s.Then.Kind != .Block)
			{
				// `defer delete x;`: the statement's own lead is the space after `defer`, which is
				// no indentation once the body becomes a block.
				let inner = mGraph.ExecTarget(body);
				if (inner != null)
					DeleteAndNullify!(inner.RawLead);
			}
			return n;
		}

		/// `using (value) body` / `using (let x = value) body` -> a Using node.
		Node BuildUsing(Stmt s)
		{
			Node n = NewStatementNode(.Using, s);
			let value = mGraph.AddDataIn(n, "value", "Value");
			BuildInput(value, s.Expr);
			let body = mGraph.AddExecOut(n, "body", "Body");
			mGraph.AddExecOut(n, "then", "Completed");
			if (s.VarName != null)
			{
				n.Text.Set(s.VarName);
				n.Text2.Set(s.VarType);
				if (s.VarType != "let" && s.VarType != "var")
					value.TypeName.Set(s.VarType);
				let varOut = mGraph.AddDataOut(n, "variable", s.VarName);
				varOut.TypeName.Set(value.TypeName);
				AddVarType(s.VarName, value.TypeName);
			}
			BuildBody(s.Then, body);
			return n;
		}

		// ------------------------------------------------------------------ lambdas, local functions

		/// The parameter names of a lambda or local function parameter list (`a, b`, `int x`,
		/// `ref T v`): the last word of each comma-separated part, with its type when given.
		public static void SplitParams(StringView paramText, List<(StringView name, StringView type)> outParams)
		{
			int depth = 0;
			int partStart = 0;
			for (int i <= paramText.Length)
			{
				char8 c = (i < paramText.Length) ? paramText[i] : ',';
				if (c == '(' || c == '<' || c == '[')
					depth++;
				else if (c == ')' || c == '>' || c == ']')
					depth--;
				else if (c == ',' && depth <= 0)
				{
					var part = paramText.Substring(partStart, i - partStart);
					part.Trim();
					partStart = i + 1;
					if (part.IsEmpty)
						continue;
					int e = part.Length;
					int s = e;
					while (s > 0 && CharUtil.IsIdentChar(part[s - 1]))
						s--;
					StringView name = part.Substring(s, e - s);
					var type = part.Substring(0, s);
					type.Trim();
					for (let mod in StringView[?]("ref ", "out ", "in ", "mut ", "params "))
					{
						if (type.StartsWith(mod))
						{
							type.RemoveFromStart(mod.Length);
							type.Trim();
						}
					}
					outParams.Add((name, type));
				}
			}
		}

		/// `T Name(params) { ... }` / `=> expr;` inside a body -> a Local Function node.
		Node BuildLocalFunc(Stmt s)
		{
			Node n = NewStatementNode(.LocalFunc, s);
			n.Text.Set(s.VarName);
			n.Text2.Set(s.ForHeader);
			mGraph.AddExecOut(n, "then");
			int open = s.ForHeader.IndexOf('(');
			if (open >= 0 && s.ForHeader.EndsWith(')'))
			{
				List<(StringView name, StringView type)> ps = scope .();
				SplitParams(StringView(s.ForHeader, open + 1, s.ForHeader.Length - open - 2), ps);
				for (let p in ps)
				{
					let pin = mGraph.AddDataOut(n, scope $"param{@p.Index}", p.name);
					pin.TypeName.Set(p.type);
					if (!p.type.IsEmpty)
						AddVarType(p.name, p.type);
				}
			}
			if (s.Then != null)
			{
				let body = mGraph.AddExecOut(n, "body", "Body");
				BuildBody(s.Then, body);
			}
			else
			{
				let result = mGraph.AddDataIn(n, "expr", "Returns");
				result.TypeName.Set(s.VarType);
				BuildInput(result, s.Expr);
			}
			return n;
		}

		/// `(a, b) => expr`, `x => { ... }`, `scope [&] () => { ... }`, `new => Method` -> a
		/// Lambda node: the parameters as outputs (read by name inside), the expression body as
		/// the `result` input or the block body hanging off `body`.
		Node BuildLambda(Expr e)
		{
			Node n = NewExprNode(.Lambda, e);
			n.Alloc = new String(e.Op);
			if (e.Captures != null)
				n.Attributes = new String(e.Captures);
			if (e.Params == null)
			{
				// `=> Method`: a delegate bound to a method.
				n.Text2.Set(mUnit.NodeText(e.A));
				return n;
			}
			if (e.ParamParens)
				n.Text.AppendF("({})", e.Params);
			else
				n.Text.Set(e.Params);
			List<(StringView name, StringView type)> ps = scope .();
			SplitParams(e.Params, ps);
			for (let p in ps)
			{
				let pin = mGraph.AddDataOut(n, scope $"param{@p.Index}", p.name);
				pin.TypeName.Set(p.type);
				if (!p.type.IsEmpty)
					AddVarType(p.name, p.type);
			}
			if (e.Body != null)
			{
				let body = mGraph.AddExecOut(n, "body", "Body");
				BuildBody(e.Body, body);
			}
			else
			{
				let result = mGraph.AddDataIn(n, "expr", "Returns");
				BuildInput(result, e.A);
			}
			return n;
		}

		/// `$"x = {x}, y = {Get(y):X2}"` -> a Format node: one input per hole, built like any
		/// other expression; the template keeps the text, `{{`, format and alignment parts. Null
		/// when the string has no hole or a hole is not a plain expression (kept as text).
		Node TryBuildFormat(Expr e)
		{
			let lit = mUnit.NodeText(e);
			List<(int exprStart, int exprEnd, int holeStart, int holeEnd)> holes = scope .();
			if (!CodeGen.SplitInterpolated(lit, holes) || holes.IsEmpty)
				return null;
			List<CompilationUnit> units = scope .();
			List<Expr> exprs = scope .();
			defer
			{
				for (let ex in exprs)
					delete ex;
				for (let u in units)
					delete u;
			}
			for (let h in holes)
			{
				let x = Parser.ParseExpression(StringView(lit, h.exprStart, h.exprEnd - h.exprStart), let unit);
				if (x == null)
					return null;
				units.Add(unit);
				exprs.Add(x);
				// Out arguments and declarations in a hole stay text.
				if (x.Kind == .Assign || x.Kind == .Lambda)
					return null;
			}
			Node n = NewExprNode(.Format, e);
			n.Result.TypeName.Set("String");
			int pos = 0;
			for (let h in holes)
			{
				n.Text.Append(StringView(lit, pos, h.exprStart - pos));
				pos = h.exprEnd;
			}
			n.Text.Append(StringView(lit, pos));
			int firstNew = mGraph.Nodes.Count;
			let outer = mUnit;
			for (int i < holes.Count)
			{
				let pin = mGraph.AddDataIn(n, scope $"arg{i}", scope $"{{{i}}}");
				mUnit = units[i];
				BuildInput(pin, exprs[i]);
				mUnit = outer;
			}
			for (int i = firstNew; i < mGraph.Nodes.Count; i++)
			{
				mGraph.Nodes[i].Line = n.Line;
				mGraph.Nodes[i].LineEnd = n.LineEnd;
			}
			return n;
		}

		/// `.Ok`, `.Err`, `.Ok(let v)`, `.Err(var e)`: the case and the binding; false otherwise.
		bool ParseResultPattern(Expr pattern, out StringView caseName, out StringView decl, out StringView name)
		{
			caseName = default;
			decl = default;
			name = default;
			if (pattern == null || !pattern.HasSpan)
				return false;
			int first = pattern.FirstTok;
			int count = pattern.LastTok - first + 1;
			if (count < 2 || mUnit.TokenText(first) != "." || (mUnit.TokenText(first + 1) != "Ok" && mUnit.TokenText(first + 1) != "Err"))
				return false;
			caseName = mUnit.TokenText(first + 1);
			if (count == 2)
				return true;
			if (count != 6 || mUnit.TokenText(first + 2) != "(" || mUnit.TokenText(first + 5) != ")")
				return false;
			decl = mUnit.TokenText(first + 3);
			name = mUnit.TokenText(first + 4);
			return (decl == "let" || decl == "var") && mUnit.Tokens[first + 4].Kind == .Identifier && !Parser.IsReservedWord(name);
		}

		/// The payload type of a Result: `T` of `Result<T>` (Ok), `E` of `Result<T, E>` (Err).
		static void ResultPayloadType(StringView resultType, bool ok, String outType)
		{
			if (TypeRules.BaseName(resultType) != "Result")
				return;
			List<StringView> args = scope .();
			TypeRules.GenericArgs(resultType, args);
			int i = ok ? 0 : 1;
			if (i < args.Count)
				outType.Set(args[i]);
		}

		/// `if (X case .Ok(let v)) A else B` (or `.Err`, or no binding) -> a Result node: Ok and
		/// Err outputs, the bound value as the payload pin, read by wires inside its arm.
		Node TryBuildResultMatch(Stmt s)
		{
			let cond = s.Expr;
			if (cond == null || cond.Kind != .Binary || cond.Op != "case" || cond.A == null)
				return null;
			if (!ParseResultPattern(cond.B, let caseName, let decl, let name))
				return null;
			bool okTest = caseName == "Ok";
			Node n = NewStatementNode(.ResultMatch, s);
			n.Text.Set(caseName);
			let value = mGraph.AddDataIn(n, "value", "Result");
			BuildInput(value, cond.A);
			let ok = mGraph.AddExecOut(n, "ok", "Ok");
			let err = mGraph.AddExecOut(n, "err", "Err");
			mGraph.AddExecOut(n, "then", "Completed");
			let payload = mGraph.AddDataOut(n, "payload", okTest ? "Value" : "Error");
			payload.Mode = .Out;
			ResultPayloadType(value.TypeName, okTest, payload.TypeName);
			let tested = okTest ? ok : err;
			let other = okTest ? err : ok;
			if (name.IsEmpty)
			{
				payload.Form = .Discard;
				BuildBody(s.Then, tested);
			}
			else
			{
				payload.Form = .Inline;
				payload.OutName = new String(name);
				payload.OutDecl = new String(decl);
				AddVarType(name, payload.TypeName);
				// The bound value exists in the tested arm only.
				int scopeMark = mOutVars.Count;
				AddOutVar(name, payload);
				mInlineOuts.Add(payload);
				BuildBody(s.Then, tested);
				while (mOutVars.Count > scopeMark)
					delete mOutVars.PopBack().name;
			}
			BuildBody(s.Else, other);
			return n;
		}

		/// The type a `new` expression makes: `T` (`T*` for `new` of a known struct), `T[]`;
		/// empty for `.()` (filled from where the value goes, InferConstructTypes).
		void ConstructType(Expr e, String outType)
		{
			if (e.TypeText == null || e.TypeText == ".")
				return;
			if (e.TypeText == "$")
			{
				outType.Set("String");
				return;
			}
			outType.Set(e.TypeText);
			if (e.IsArray)
			{
				outType.Append("[]");
				return;
			}
			if (e.Op.StartsWith("new") && TypeRules.Hierarchy != null)
			{
				String kind = scope .();
				TypeRules.Hierarchy.KindOf(e.TypeText, kind);
				if (kind == "struct")
					outType.Append('*');
			}
		}

		/// The constructor `new T(args)` calls: the type's own `this(...)` (same file), the
		/// project index or the TypeService. Null when unknown (the pins are then `Arg N`).
		SymbolMethod ResolveCtor(StringView typeText, List<Expr> args, out Member own)
		{
			own = null;
			if (mOwner != null && typeText == mOwner.Name)
			{
				own = FindOwnMethod("this", args);
				if (own != null)
					return null;
			}
			if (TypeService.Current != null)
			{
				List<String> argTypes = scope .();
				defer { ClearAndDeleteItems!(argTypes); }
				for (let a in args)
				{
					String at = new .();
					InferType(a, at);
					argTypes.Add(at);
				}
				let m = TypeService.Current.ResolveCall(typeText, "", "this", args.Count, argTypes, mResolveCtx);
				if (m != null && m.IsCtor)
					return m;
			}
			if (Index != null)
			{
				let st = Index.FindType(typeText);
				if (st != null)
				{
					for (let m in st.Methods)
						if (m.IsCtor && m.Name == "this" && m.ParamNames.Count == args.Count)
							return m;
				}
			}
			// A type declared in this file (no index needed).
			List<Member> types = scope .();
			mUnit.CollectTypes(types);
			for (let t in types)
			{
				if (t.Name != typeText || t.Members == null)
					continue;
				for (let m in t.Members)
				{
					if (m.Kind != .Method || !m.IsCtor || m.Params == null)
						continue;
					int minArgs = 0;
					int maxArgs = m.Params.Count;
					for (let p in m.Params)
					{
						if (p.Modifier.Contains("params"))
							maxArgs = int.MaxValue;
						else if (p.Default == null)
							minArgs = @p.Index + 1;
					}
					if (args.Count >= minArgs && args.Count <= maxArgs)
					{
						own = m;
						return null;
					}
				}
			}
			return null;
		}

		/// `new T(a, b)` -> a Construct node: the allocation keyword, the type, one input per
		/// constructor argument (named and typed from the constructor when it is known).
		Node BuildConstruct(Expr e)
		{
			Node n = NewExprNode(.Construct, e);
			n.Text.Set(e.TypeText);
			n.Alloc = new String(e.Op);
			n.IsArray = e.IsArray;
			if (e.IsArray)
			{
				for (let arg in e.Args)
				{
					String label = scope .("Count");
					if (e.Args.Count > 1)
						label.AppendF(" {}", @arg.Index);
					let pin = mGraph.AddDataIn(n, scope $"arg{@arg.Index}", label);
					pin.TypeName.Set("int");
					BuildInput(pin, arg);
				}
				return n;
			}
			if (e.TypeText == "$")
			{
				// `scope $"..."`: the text is the one input.
				let pin = mGraph.AddDataIn(n, "arg0", "Text");
				pin.TypeName.Set("String");
				BuildInput(pin, e.Args[0]);
				return n;
			}
			Member own = null;
			SymbolMethod ext = null;
			if (e.TypeText != ".")
				ext = ResolveCtor(e.TypeText, e.Args, out own);
			for (let arg in e.Args)
			{
				int i = @arg.Index;
				String label = scope .();
				String type = scope .();
				if (own != null && own.Params != null && i < own.Params.Count)
				{
					label.Set(own.Params[i].Name);
					type.Set(own.Params[i].Type);
				}
				else if (ext != null && i < ext.ParamNames.Count)
				{
					label.Set(ext.ParamNames[i]);
					type.Set(ext.ParamTypes[i]);
				}
				else
					label.AppendF("Arg {}", i);
				BuildArg(n, i, arg, label, type, false);
			}
			return n;
		}

		/// `scope .()` takes the type of where its value goes (the local it initialises, the
		/// parameter it is passed to).
		void InferConstructTypes()
		{
			for (let n in mGraph.Nodes)
			{
				if (!((n.Kind == .Construct && n.Text == ".") || n.Kind == .Lambda) || n.Result == null || !n.Result.TypeName.IsEmpty)
					continue;
				for (let l in mGraph.Links)
				{
					if (l.From == n.Result && !l.To.TypeName.IsEmpty)
					{
						n.Result.TypeName.Set(l.To.TypeName);
						break;
					}
				}
			}
		}

		// ------------------------------------------------------------------ flow macros

		static Expr NameExpr(Expr e)
		{
			let u = Unparen(e);
			return (u != null && u.Kind == .Name) ? u : null;
		}

		/// `!name` -> the name expression.
		static Expr NotName(Expr e)
		{
			let u = Unparen(e);
			if (u != null && u.Kind == .Unary && u.Op == "!" && !u.Postfix)
				return NameExpr(u.A);
			return null;
		}

		bool IsLiteralText(Expr e, StringView text)
		{
			let u = Unparen(e);
			return u != null && u.Kind == .Literal && mUnit.NodeText(u) == text;
		}

		/// `name = <text>;`
		bool IsAssignOf(Stmt s, StringView name, StringView text)
		{
			if (s == null || s.Kind != .Expr || s.Expr == null)
				return false;
			let e = Unparen(s.Expr);
			if (e.Kind != .Assign || e.Op != "=")
				return false;
			let target = NameExpr(e.A);
			return target != null && target.Op == name && IsLiteralText(e.B, text);
		}

		/// `name++;` / `++name;`
		static bool IsIncrementOf(Stmt s, StringView name)
		{
			if (s == null || s.Kind != .Expr || s.Expr == null)
				return false;
			let e = Unparen(s.Expr);
			if (e.Kind != .Unary || e.Op != "++")
				return false;
			let target = NameExpr(e.A);
			return target != null && target.Op == name;
		}

		static Stmt FirstOf(Stmt block) => (block != null && block.Kind == .Block && block.Body.Count > 0) ? block.Body[0] : null;

		Node NewFlow(Stmt s, StringView macro, int arms = 2)
		{
			Node n = NewStatementNode(.Flow, s);
			FlowMacros.Setup(mGraph, n, macro, arms);
			return n;
		}

		/// DoOnce, DoN, FlipFlop, Gate and MultiGate in the shapes CodeGen writes; null otherwise.
		Node TryBuildFlowIf(Stmt s)
		{
			let cond = Unparen(s.Expr);
			if (cond == null)
				return null;

			// if (!__doOnce_1) { __doOnce_1 = true; ... }
			let flag = NotName(cond);
			if (flag != null && s.Else == null && flag.Op.StartsWith(FlowMacros.PrefixDoOnce) && IsAssignOf(FirstOf(s.Then), flag.Op, "true"))
			{
				Node n = NewFlow(s, FlowMacros.DoOnce);
				n.Text2.Set(flag.Op);
				BuildBlockFrom(s.Then, 1, n.FindOutput("body"));
				return n;
			}

			// if (__doN_1 < n) { __doN_1++; ... }
			if (cond.Kind == .Binary && cond.Op == "<" && s.Else == null)
			{
				let counter = NameExpr(cond.A);
				if (counter != null && counter.Op.StartsWith(FlowMacros.PrefixDoN) && IsIncrementOf(FirstOf(s.Then), counter.Op))
				{
					Node n = NewFlow(s, FlowMacros.DoN);
					n.Text2.Set(counter.Op);
					BuildInput(n.FindInput("n"), cond.B);
					BuildBlockFrom(s.Then, 1, n.FindOutput("body"));
					return n;
				}
			}

			// if (!__flipFlop_1) { __flipFlop_1 = true; A } else { __flipFlop_1 = false; B }
			if (flag != null && s.Else != null && s.Else.Kind == .Block && flag.Op.StartsWith(FlowMacros.PrefixFlipFlop) &&
				IsAssignOf(FirstOf(s.Then), flag.Op, "true") && IsAssignOf(FirstOf(s.Else), flag.Op, "false"))
			{
				Node n = NewFlow(s, FlowMacros.FlipFlop);
				n.Text2.Set(flag.Op);
				BuildBlockFrom(s.Then, 1, n.FindOutput("a"));
				BuildBlockFrom(s.Else, 1, n.FindOutput("b"));
				return n;
			}

			// if (__gateOpen_1) { ... }   /   if (!__gateClosed_1) { ... }
			if (s.Else == null)
			{
				let open = NameExpr(cond);
				StringView gate = default;
				if (open != null && open.Op.StartsWith(FlowMacros.PrefixGateOpen))
					gate = open.Op;
				else if (flag != null && flag.Op.StartsWith(FlowMacros.PrefixGateClosed))
					gate = flag.Op;
				if (!gate.IsEmpty)
				{
					Node n = NewFlow(s, FlowMacros.Gate);
					n.Text2.Set(gate);
					BuildBody(s.Then, n.FindOutput("body"));
					return n;
				}
			}

			return TryBuildMultiGate(s);
		}

		/// if (__multiGate_1 == 0) { __multiGate_1 = 1; ... } else if (__multiGate_1 == 1) { ... }
		Node TryBuildMultiGate(Stmt s)
		{
			List<Stmt> chain = scope .();
			String field = scope .();
			var cur = s;
			bool loop = false;
			while (cur != null && cur.Kind == .If)
			{
				let cond = Unparen(cur.Expr);
				if (cond == null || cond.Kind != .Binary || cond.Op != "==")
					return null;
				let name = NameExpr(cond.A);
				if (name == null || !name.Op.StartsWith(FlowMacros.PrefixMultiGate))
					return null;
				if (chain.IsEmpty)
					field.Set(name.Op);
				else if (name.Op != field)
					return null;
				int k = chain.Count;
				if (!IsLiteralText(cond.B, scope $"{k}"))
					return null;
				let first = FirstOf(cur.Then);
				bool isLast = cur.Else == null;
				if (!isLast && cur.Else.Kind != .If)
					return null;
				if (IsAssignOf(first, field, scope $"{k + 1}"))
				{
				}
				else if (isLast && IsAssignOf(first, field, "0"))
					loop = true;
				else
					return null;
				chain.Add(cur);
				cur = cur.Else;
			}
			if (chain.IsEmpty)
				return null;
			Node n = NewFlow(s, FlowMacros.MultiGate, chain.Count);
			n.Text2.Set(field);
			n.Postfix = loop;
			for (int k < chain.Count)
				BuildBlockFrom(chain[k].Then, 1, n.FindOutput(scope $"out{k}"));
			return n;
		}

		/// `__doOnce_1 = false;`, `__gateOpen_1 = true;`... -> reset / open / close / toggle nodes.
		Node TryBuildFlowAction(Stmt s, Expr e)
		{
			if (e.Op != "=")
				return null;
			let target = NameExpr(e.A);
			if (target == null)
				return null;
			let field = target.Op;
			let macro = FlowMacros.MacroOfField(field);
			if (macro.IsEmpty)
				return null;
			StringView action = default;
			if (macro == FlowMacros.DoOnce && IsLiteralText(e.B, "false"))
				action = FlowMacros.DoOnceReset;
			else if (macro == FlowMacros.DoN && IsLiteralText(e.B, "0"))
				action = FlowMacros.DoNReset;
			else if (macro == FlowMacros.MultiGate && IsLiteralText(e.B, "0"))
				action = FlowMacros.MultiGateReset;
			else if (macro == FlowMacros.Gate)
			{
				bool startsClosed = field.StartsWith(FlowMacros.PrefixGateOpen);
				let notSelf = NotName(e.B);
				if (notSelf != null && notSelf.Op == field)
					action = FlowMacros.GateToggle;
				else if (IsLiteralText(e.B, "true"))
					action = startsClosed ? FlowMacros.GateOpen : FlowMacros.GateClose;
				else if (IsLiteralText(e.B, "false"))
					action = startsClosed ? FlowMacros.GateClose : FlowMacros.GateOpen;
			}
			if (action.IsEmpty)
				return null;
			Node n = NewFlow(s, action);
			n.Text2.Set(field);
			return n;
		}

		// ------------------------------------------------------------------ expressions

		static Expr Unparen(Expr e)
		{
			var e;
			while (e != null && e.Kind == .Paren)
				e = e.A;
			return e;
		}

		/// Expressions shown inline as a pin's default value rather than as a node.
		bool IsInlineValue(Expr e)
		{
			switch (e.Kind)
			{
			case .Literal:
				return true;
			case .Unary:
				return (e.Op == "-" || e.Op == "+") && e.A.Kind == .Literal;
			case .Raw:
				let text = mUnit.NodeText(e);
				return text.Length <= 48 && !text.Contains('\n');
			default:
				return false;
			}
		}

		/// True for `a`, `a.b.c`, `Foo<T>.Bar` - plain references with no calls.
		static bool IsNameChain(Expr e)
		{
			if (e.Kind == .Name)
				return true;
			if (e.Kind == .Member && !e.NullCond && !e.Cascade && e.A != null)
				return IsNameChain(e.A);
			if (e.Kind == .Literal && (e.Op == "this" || e.Op == "base"))
				return true;
			return false;
		}

		void InferType(Expr e, String outType)
		{
			let u = Unparen(e);
			if (u == null)
				return;
			switch (u.Kind)
			{
			case .Literal:
				switch (u.LitKind)
				{
				case .String, .VerbatimString, .InterpolatedString, .RawString: outType.Set("String");
				case .Char8: outType.Set("char8");
				case .Char32: outType.Set("char32");
				case .Int: outType.Set("int");
				case .UInt: outType.Set("uint");
				case .Long: outType.Set("int64");
				case .ULong: outType.Set("uint64");
				case .Float: outType.Set("float");
				case .Double: outType.Set("double");
				case .Bool: outType.Set("bool");
				default:
				}
				if (outType.IsEmpty && u.Op == "this" && mOwner != null)
					outType.Set(mOwner.Name);
				else if (outType.IsEmpty && u.Op == "base" && mOwner != null)
					ClassModel.BaseClassOf(mUnit, mOwner, outType);
			case .Name:
				if (mVarTypes.TryGetValue(u.Op, let type))
					outType.Set(type);
			case .Member:
				if (u.A != null && u.A.Kind == .Literal && u.A.Op == "this")
				{
					if (mVarTypes.TryGetValue(u.Op, let type))
						outType.Set(type);
				}
				else if (Index != null && u.A != null)
				{
					// field of a known type, or a static field `Type.Field`
					String targetType = scope .();
					if (u.A.Kind == .Name && Index.FindType(u.A.Op) != null && !mVarTypes.ContainsKeyAlt(u.A.Op))
						targetType.Set(u.A.Op);
					else
						InferType(u.A, targetType);
					if (!targetType.IsEmpty)
					{
						let st = Index.FindType(targetType);
						let f = st?.FindField(u.Op);
						if (f != null)
							outType.Set(f.Type);
						else if (TypeService.Current != null)
						{
							String ft = scope .();
							if (TypeService.Current.FindMemberType(targetType, u.Op, mResolveCtx, ft))
								outType.Set(ft);
						}
					}
				}
				else if (TypeService.Current != null && u.A != null)
				{
					// Corlib / library members without a project index: `str.Length`, `Type.Field`.
					String targetType = scope .();
					if (u.A.Kind == .Name && !mVarTypes.ContainsKeyAlt(u.A.Op) && TypeService.Current.FindType(u.A.Op, mResolveCtx).IsValid)
						targetType.Set(u.A.Op);
					else
						InferType(u.A, targetType);
					String ft = scope .();
					if (!targetType.IsEmpty && TypeService.Current.FindMemberType(targetType, u.Op, mResolveCtx, ft))
						outType.Set(ft);
				}
			case .New:
				ConstructType(u, outType);
			case .Binary:
				if (u.Op == "==" || u.Op == "!=" || u.Op == "<" || u.Op == ">" || u.Op == "<=" || u.Op == ">=" ||
					u.Op == "&&" || u.Op == "||" || u.Op == "is" || u.Op == "===" || u.Op == "!==" || u.Op == "case")
					outType.Set("bool");
				else
					InferType(u.A, outType);
			case .Unary:
				if (u.Op == "!")
					outType.Set("bool");
				else if (u.Op == "&" && !u.Postfix)
				{
					// Address of: a pointer to the operand's type.
					InferType(u.A, outType);
					if (!outType.IsEmpty)
						outType.Append('*');
				}
				else if (u.Op == "*" && !u.Postfix)
				{
					// Dereference: what the pointer points to.
					String inner = scope .();
					InferType(u.A, inner);
					inner.Trim();
					if (inner.EndsWith('*'))
					{
						inner.RemoveFromEnd(1);
						outType.Set(inner);
					}
				}
				else
					InferType(u.A, outType);
			case .Cast:
				outType.Set(u.TypeText);
			case .Call:
				let callee = Unparen(u.A);
				if (callee != null && callee.Kind == .Name && (callee.Op == "Try!" || callee.Op == "TrySilent!") && u.Args != null && u.Args.Count == 1)
				{
					// Try!(Result<T>) is a T.
					String inner = scope .();
					InferType(u.Args[0], inner);
					if (TypeRules.BaseName(inner) == "Result")
					{
						List<StringView> args = scope .();
						TypeRules.GenericArgs(inner, args);
						if (!args.IsEmpty)
							outType.Set(args[0]);
					}
				}
				else if (callee != null && callee.Kind == .Name)
				{
					let m = FindOwnMethod(callee.Op, u.Args);
					if (m != null && m.TypeText != null && m.TypeText != "void")
						outType.Set(m.TypeText);
					else if (m == null)
					{
						let sm = ResolveExternal(null, callee.Op, u.Args);
						if (sm != null && sm.ReturnType != "void")
							outType.Set(sm.ReturnType);
					}
				}
				else if (callee != null && callee.Kind == .Member)
				{
					let sm = ResolveExternal(callee.A, callee.Op, u.Args);
					if (sm != null && sm.ReturnType != "void")
						outType.Set(sm.ReturnType);
				}
			default:
			}
		}

		/// A method of the owner type: the first with that name, or with arguments the overload
		/// that takes that many (defaults and `params` counted) and, when several do, the one
		/// whose parameter types fit the argument types best.
		/// The last FindOwnMethod picked between overloads that fit the (all known) argument
		/// types equally well.
		bool mLastOwnTie;
		/// The overloads behind mLastOwnTie (the pick first).
		List<Member> mLastOwnTied = new .() ~ delete _;

		Member FindOwnMethod(StringView name, List<Expr> args = null)
		{
			mLastOwnTie = false;
			mLastOwnTied.Clear();
			if (mOwner == null || mOwner.Members == null)
				return null;
			Member first = null;
			List<Member> fits = scope .();
			for (let m in mOwner.Members)
			{
				if (m.Kind != .Method || m.Name != name)
					continue;
				if (first == null)
					first = m;
				if (args == null || m.Params == null)
					return m;
				int minArgs = 0;
				int maxArgs = m.Params.Count;
				for (let p in m.Params)
				{
					if (p.Modifier.Contains("params"))
						maxArgs = int.MaxValue;
					else if (p.Default == null)
						minArgs = @p.Index + 1;
				}
				if (args.Count >= minArgs && args.Count <= maxArgs)
					fits.Add(m);
			}
			if (fits.IsEmpty)
				return first;
			if (fits.Count == 1)
				return fits[0];
			// Overloads with the same arity: score the argument types.
			Member best = fits[0];
			int bestScore = int.MinValue;
			List<String> argTypes = scope .();
			defer { ClearAndDeleteItems!(argTypes); }
			bool allKnown = true;
			for (let a in args)
			{
				String t = new .();
				InferType(a, t);
				if (t.IsEmpty || TypeRules.IsWildcard(t))
					allKnown = false;
				argTypes.Add(t);
			}
			bool tie = false;
			for (let m in fits)
			{
				int score = 0;
				for (int i < Math.Min(argTypes.Count, m.Params.Count))
				{
					if (argTypes[i].IsEmpty)
						continue;
					// Doubled, with `Object` a step below any other implicit conversion (as in
					// TypeService.ChooseOverload).
					switch (TypeRules.CanConvert(argTypes[i], m.Params[i].Type))
					{
					case .Exact: score += 8;
					case .Implicit: score += (TypeRules.BaseName(m.Params[i].Type) == "Object" && TypeRules.BaseName(argTypes[i]) != "Object") ? 3 : 4;
					case .Unchecked: score += 2;
					case .Refused: score -= 200;
					}
				}
				if (score > bestScore)
				{
					bestScore = score;
					best = m;
					tie = false;
					mLastOwnTied.Clear();
					mLastOwnTied.Add(m);
				}
				else if (score == bestScore)
				{
					tie = true;
					mLastOwnTied.Add(m);
				}
			}
			mLastOwnTie = tie && allKnown;
			return best;
		}

		/// Fills an input pin from an expression: inline default or a linked node.
		void BuildInput(Pin input, Expr expr)
		{
			let e = Unparen(expr);
			if (e == null)
				return;
			if (expr.Kind == .Paren && e.Kind != .Name && e.Kind != .Literal && e.Kind != .Member && e.Kind != .Call)
				input.Parens = true;
			if (input.TypeName.IsEmpty)
				InferType(e, input.TypeName);
			if (TryLinkTemp(e, input))
				return;
			if (e.Kind == .Literal && e.LitKind == .InterpolatedString)
			{
				let format = TryBuildFormat(e);
				if (format != null)
				{
					mGraph.Connect(format.Result, input);
					return;
				}
			}
			if (IsInlineValue(e))
			{
				input.Default.Set(mUnit.NodeText(e));
				return;
			}
			Node n = BuildExprNode(e);
			mGraph.Connect(n.Result, input);
		}

		/// Assignment targets and member / index targets: name chains stay inline ("mList"),
		/// except reads of a folded temp or (when `read`) of an out variable, which are wired.
		void BuildTargetInput(Pin input, Expr expr, bool read = true)
		{
			let e = Unparen(expr);
			if (e != null && IsNameChain(e) && ChainTemp(e, ?) == null && (!read || ChainOutVar(e) == null))
			{
				input.Default.Set(mUnit.NodeText(e));
				return;
			}
			BuildInput(input, e);
		}

		/// The out variable a name chain (`a`, `a.b`) starts with, or null.
		Pin ChainOutVar(Expr e)
		{
			var root = e;
			while (root != null && root.Kind == .Member)
				root = root.A;
			if (root == null || root.Kind != .Name)
				return null;
			return FindOutVar(root.Op);
		}

		Node NewExprNode(NodeKind kind, Expr e)
		{
			Node n = mGraph.AddNode(kind);
			n.Original = new String(mUnit.NodeText(e));
			SetLines(n, e);
			let result = mGraph.AddDataOut(n, "result", "");
			InferType(e, result.TypeName);
			return n;
		}

		/// Finds a method declared on the static type or the inferred type of a call target. With a
		/// TypeService installed, corlib and libraries are searched too, namespaces and `using`s
		/// are honoured and the overload is chosen by argument count and types.
		SymbolMethod ResolveExternal(Expr target, StringView methodName, List<Expr> args = null)
		{
			if (TypeService.Current != null)
			{
				let r = ResolveWithService(target, methodName, args);
				if (r != null)
					return r;
			}
			if (target != null)
			{
				let t = Unparen(target);
				// Static call `TypeName.Method()`
				if (t.Kind == .Name && !mVarTypes.ContainsKeyAlt(t.Op))
				{
					var st = (Index != null) ? Index.FindType(t.Op) : null;
					if (st == null)
						st = FindWellKnownType(t.Op);
					if (st != null)
						return st.FindMethod(methodName);
				}
				if (Index == null)
					return null;
				String typeName = scope .();
				InferType(t, typeName);
				if (!typeName.IsEmpty)
					return Index.FindMethod(typeName, methodName);
				return null;
			}
			if (Index == null)
				return null;
			if (mOwner != null)
			{
				let m = Index.FindMethod(mOwner.Name, methodName);
				if (m != null)
					return m;
			}
			return Index.FindGlobalMethod(methodName);
		}

		SymbolMethod ResolveWithService(Expr target, StringView methodName, List<Expr> args)
		{
			let svc = TypeService.Current;
			String staticType = scope .();
			String targetType = scope .();
			if (target != null)
			{
				let t = Unparen(target);
				if (t.Kind == .Name && !mVarTypes.ContainsKeyAlt(t.Op) && svc.FindType(t.Op, mResolveCtx).IsValid)
					staticType.Set(t.Op);
				else if (t.Kind == .Member && IsNameChain(t) && ChainTemp(t, ?) == null)
				{
					// `System.Math.Max` or `Outer.Inner.F`: a type path, unless it starts at a variable.
					var root = t;
					while (root.Kind == .Member && root.A != null)
						root = root.A;
					let text = mUnit.NodeText(t);
					if (root.Kind == .Name && !mVarTypes.ContainsKeyAlt(root.Op) && svc.FindType(text, mResolveCtx).IsValid)
						staticType.Set(text);
				}
				if (staticType.IsEmpty)
				{
					InferType(t, targetType);
					if (targetType.IsEmpty)
						return null;
				}
			}
			List<String> argTypes = null;
			if (args != null)
			{
				argTypes = scope:: .();
				for (let a in args)
				{
					String at = scope:: .();
					InferType(a, at);
					argTypes.Add(at);
				}
			}
			return svc.ResolveCall(staticType, targetType, methodName, (args != null) ? args.Count : -1, argTypes, mResolveCtx);
		}

		/// What the text before `.Foo()` is.
		enum TargetShape
		{
			/// `this`: wired to a Self node.
			This,
			/// `base`: wired to a Base (Parent) node.
			Base,
			/// A value (a variable, field, parameter, any expression): wired to its node.
			Value,
			/// A type (`Console`, `System.Math`): a static call, no Target pin.
			Type,
			/// Something that can't be told apart (`base`, an unknown name): kept as text in the
			/// Target pin, as before.
			Text
		}

		TargetShape ClassifyTarget(Expr target)
		{
			let u = Unparen(target);
			if (u == null)
				return .Text;
			if (u.Kind == .Literal)
			{
				if (u.Op == "this")
					return .This;
				if (u.Op == "base")
					return .Base;
				return .Value;
			}
			if (!IsNameChain(u))
				return .Value;
			var root = u;
			while (root.Kind == .Member && root.A != null)
				root = root.A;
			if (root.Kind == .Literal)
				return (root.Op == "this") ? .Value : .Text;
			if (root.Kind != .Name)
				return .Text;
			if (mVarTypes.ContainsKeyAlt(root.Op) || FindTemp(root.Op) != null || FindOutVar(root.Op) != null)
				return .Value;
			if (IsTypeText(mUnit.NodeText(u)))
				return .Type;
			return .Text;
		}

		bool IsTypeText(StringView text)
		{
			if (TypeService.Current != null && TypeService.Current.FindType(text, mResolveCtx).IsValid)
				return true;
			if (text.Contains('.'))
				return false;
			if (Index != null && Index.FindType(text) != null)
				return true;
			return FindWellKnownType(text) != null;
		}

		/// How `Foo(...)` (no qualifier) binds to the type's own methods: Static or Instance when
		/// every overload that takes that many arguments agrees, else Unresolved.
		CallBinding OwnBinding(StringView name, List<Expr> args)
		{
			if (mOwner == null || mOwner.Members == null)
				return .Unresolved;
			bool anyStatic = false;
			bool anyInstance = false;
			for (let m in mOwner.Members)
			{
				if (m.Kind != .Method || m.Name != name || m.IsCtor)
					continue;
				if (args != null && m.Params != null)
				{
					int minArgs = 0;
					int maxArgs = m.Params.Count;
					for (let p in m.Params)
					{
						if (p.Modifier.Contains("params"))
							maxArgs = int.MaxValue;
						else if (p.Default == null)
							minArgs = @p.Index + 1;
					}
					if (args.Count < minArgs || args.Count > maxArgs)
						continue;
				}
				if (IsStaticMember(m, mOwner))
					anyStatic = true;
				else
					anyInstance = true;
			}
			if (anyStatic == anyInstance)
				return .Unresolved;
			return anyStatic ? .Static : .Instance;
		}

		void SetOwner(Node n, StringView owner)
		{
			if (owner.IsEmpty)
				return;
			if (n.OwnerType == null)
				n.OwnerType = new String(owner);
			else
				n.OwnerType.Set(owner);
		}

		/// A Self node (`this`) wired into `input`.
		void BuildSelf(Pin input, Expr thisExpr)
		{
			Node self = mGraph.AddNode(.This);
			self.Text.Set("this");
			self.Original = new String(mUnit.NodeText(thisExpr));
			SetLines(self, thisExpr);
			let r = mGraph.AddDataOut(self, "result", "This");
			r.TypeName.Set(mGraph.SelfType);
			mGraph.Connect(r, input);
		}

		/// A Base node (`base`) wired into `input`, typed with the parent class.
		void BuildBase(Pin input, Expr baseExpr)
		{
			Node b = mGraph.AddNode(.Base);
			b.Text.Set("base");
			b.Original = new String(mUnit.NodeText(baseExpr));
			SetLines(b, baseExpr);
			let r = mGraph.AddDataOut(b, "result", "Base");
			ClassModel.BaseClassOf(mUnit, mOwner, r.TypeName);
			mGraph.Connect(r, input);
		}

		void FillCall(Node n, Expr call)
		{
			let callee = Unparen(call.A);
			Member known = null;
			SymbolMethod ext = null;
			if (callee.Kind == .Member && callee.A != null)
			{
				n.Text.Set(callee.Op);
				n.NullCond = callee.NullCond;
				n.Cascade = callee.Cascade;
				ext = ResolveExternal(callee.A, callee.Op, call.Args);
				let shape = ClassifyTarget(callee.A);
				if (shape == .Type && !n.NullCond && !n.Cascade)
				{
					// `Console.WriteLine(...)`: static, no Target pin; the qualifier is kept as written.
					n.Binding = .Static;
					n.Qualifier = new String(mUnit.NodeText(callee.A));
					if (ext != null && !ext.OwnerType.IsEmpty)
						SetOwner(n, ext.OwnerType);
					else
					{
						String owner = scope .();
						NodeFactory.OwnerOfQualifier(n.Qualifier, owner);
						SetOwner(n, owner);
					}
				}
				else
				{
					let target = mGraph.AddDataIn(n, "target", "Receiver");
					switch (shape)
					{
					case .This:
						n.Binding = .Instance;
						BuildSelf(target, Unparen(callee.A));
						if (ext == null)
						{
							// `this.Foo()`: the type's own method.
							known = FindOwnMethod(callee.Op, call.Args);
							if (known != null)
								SetOwner(n, mOwner.Name);
						}
					case .Value:
						n.Binding = .Instance;
						BuildInput(target, callee.A);
					case .Base:
						// `base.Foo()`: the parent's version, Target wired from a Base node.
						n.Binding = .Instance;
						BuildBase(target, Unparen(callee.A));
					default:
						// Unknown names: text in the pin, as written.
						n.Binding = (ext != null && !ext.IsStatic) ? .Instance : .Unresolved;
						BuildTargetInput(target, callee.A);
					}
					if (target.TypeName.IsEmpty)
						InferType(callee.A, target.TypeName);
					if (ext != null && !ext.IsStatic)
					{
						SetOwner(n, ext.OwnerType);
						if (target.TypeName.IsEmpty)
							target.TypeName.Set(ext.OwnerType);
					}
				}
			}
			else if (callee.Kind == .Name || callee.Kind == .Literal)
			{
				n.Text.Set(callee.Op);
				// A delegate in a variable (`mOnTick()`) is invoked, not a method of the type.
				bool isValue = callee.Kind == .Name && (mVarTypes.ContainsKeyAlt(callee.Op) || FindOutVar(callee.Op) != null);
				if (!isValue)
				{
					known = FindOwnMethod(callee.Op, call.Args);
					if (known != null && mLastOwnTie)
					{
						n.Ambiguous = true;
						n.Overloads = new .();
						for (let m in mLastOwnTied)
						{
							String sig = new .();
							sig.AppendF("{}(", m.Name);
							for (let p in m.Params)
							{
								if (@p.Index > 0)
									sig.Append(", ");
								if (!p.Modifier.IsEmpty)
									sig.AppendF("{} ", p.Modifier);
								sig.AppendF("{} {}", p.Type, p.Name);
							}
							sig.Append(')');
							n.Overloads.Add(sig);
						}
					}
					if (known == null)
						ext = ResolveExternal(null, callee.Op, call.Args);
				}
				if (known != null)
				{
					n.Binding = OwnBinding(callee.Op, call.Args);
					SetOwner(n, mOwner.Name);
				}
				else if (ext != null)
				{
					// A static method (own, a base's, a global function) or, outside a static
					// context, an inherited member function. A member function seen from a static
					// context is left unresolved: only the type's own declarations are trusted to
					// report "there is no self" (the compiler is the judge otherwise).
					if (ext.IsStatic)
						n.Binding = .Static;
					else if (!mGraph.StaticContext)
						n.Binding = .Instance;
					if (n.Binding != .Unresolved)
						SetOwner(n, ext.OwnerType);
				}
				if (n.Binding == .Instance)
				{
					let target = mGraph.AddDataIn(n, "target", "Receiver");
					target.TypeName.Set((n.OwnerType != null) ? (StringView)n.OwnerType : (StringView)mGraph.SelfType);
				}
			}
			else
			{
				// Invoke an arbitrary expression: `GetFn()(x)`
				let target = mGraph.AddDataIn(n, "target", "Receiver");
				BuildInput(target, callee);
			}

			for (let arg in call.Args)
			{
				int i = @arg.Index;
				String label = scope .();
				String type = scope .();
				bool outRef = false;
				if (known != null && i < known.Params.Count)
				{
					label.Set(known.Params[i].Name);
					type.Set(known.Params[i].Type);
					outRef = known.Params[i].Attributes != null && IsOutRefAttr(known.Params[i].Attributes);
				}
				else if (ext != null && i < ext.ParamNames.Count)
				{
					label.Set(ext.ParamNames[i]);
					type.Set(ext.ParamTypes[i]);
					outRef = i < ext.ParamAttributes.Count && IsOutRefAttr(ext.ParamAttributes[i]);
				}
				else
					label.AppendF("Arg {}", i);
				if (call.Args.Count == 1 && type == "StringView" && IsConsolePrint(n, ext))
				{
					// A print read from `Console.WriteLine("text")` takes any value, like a Print
					// placed from the Node menu (WriteLine(Object obj)): wiring a number into it
					// writes `Console.WriteLine(i)`. The text as written is unchanged.
					label.Set("obj");
					type.Set("Object");
				}
				BuildArg(n, i, arg, label, type, outRef);
			}

			if (ext != null && ext.Ambiguous)
			{
				n.Ambiguous = true;
				if (ext.Candidates != null && n.Overloads == null)
				{
					n.Overloads = new .();
					for (let s in ext.Candidates)
						n.Overloads.Add(new String(s));
				}
			}
			StringView retType = (known != null) ? (StringView)known.TypeText : ((ext != null) ? (StringView)ext.ReturnType : "");
			if (known != null || ext != null)
			{
				if (!retType.IsEmpty && retType != "void")
				{
					let result = mGraph.AddDataOut(n, "result", "Return Value");
					result.TypeName.Set(retType);
				}
			}
			else
				mGraph.AddDataOut(n, "result", "Return Value");
		}

		/// `Console.WriteLine` / `Console.Write` resolved to the corlib's static functions.
		static bool IsConsolePrint(Node n, SymbolMethod ext)
		{
			if (ext == null || !ext.IsStatic || (ext.Name != "WriteLine" && ext.Name != "Write"))
				return false;
			StringView owner = ext.OwnerType;
			return owner == "Console" || owner == "System.Console";
		}

		/// One call argument: an input (a value or `ref x`), or an out pin for `out x`,
		/// `out let x` and the `T x;` + `out x` shape CodeGen writes.
		void BuildArg(Node n, int i, Expr arg, StringView label, StringView type, bool paramOutRef)
		{
			if (arg.Kind == .Unary && arg.Op == "out" && arg.A != null)
			{
				let target = Unparen(arg.A);
				let p = mGraph.AddDataOut(n, scope $"arg{i}", label);
				p.Mode = .Out;
				let pending = (target.Kind == .Name) ? TakePending(target.Op, false) : null;
				if (pending != null)
				{
					FoldDecl(p, pending, .Declared);
					return;
				}
				// `out b`: writes a variable that exists anyway; readers read b themselves.
				p.Form = .Existing;
				p.OutName = new String(mUnit.NodeText(arg.A));
				p.TypeName.Set(type);
				if (p.TypeName.IsEmpty)
					InferType(target, p.TypeName);
				return;
			}
			if (arg.Kind == .Raw && mUnit.NodeText(arg) == "?")
			{
				// `?`: the value is discarded.
				let p = mGraph.AddDataOut(n, scope $"arg{i}", label);
				p.Mode = .Out;
				p.Form = .Discard;
				p.TypeName.Set(type);
				return;
			}
			if (arg.Kind == .Raw && ParseInlineOut(arg, let keyword, let decl, let name))
			{
				// `var a` / `let a`: the declaration is part of the argument.
				let p = mGraph.AddDataOut(n, scope $"arg{i}", label);
				p.Mode = .Out;
				p.Form = .Inline;
				p.OutKeyword = keyword;
				p.OutName = new String(name);
				p.OutDecl = new String(decl);
				if (decl != "let" && decl != "var")
					p.TypeName.Set(decl);
				else
					p.TypeName.Set(type);
				AddVarType(name, p.TypeName);
				AddOutVar(name, p);
				mInlineOuts.Add(p);
				return;
			}
			if (arg.Kind == .Unary && arg.Op == "ref" && arg.A != null)
			{
				let target = Unparen(arg.A);
				if (paramOutRef && target.Kind == .Name)
				{
					let pending = TakePending(target.Op, true);
					if (pending != null)
					{
						let p = mGraph.AddDataOut(n, scope $"arg{i}", label);
						p.Mode = .Out;
						FoldDecl(p, pending, .DeclaredRef);
						return;
					}
				}
				let p = mGraph.AddDataIn(n, scope $"arg{i}", label);
				p.Mode = .Ref;
				p.TypeName.Set(type);
				BuildInput(p, arg.A);
				return;
			}
			let pin = mGraph.AddDataIn(n, scope $"arg{i}", label);
			pin.TypeName.Set(type);
			BuildInput(pin, arg);
		}

		/// The out pin stands for a `T name;` line in front of the statement.
		void FoldDecl(Pin p, PendingDecl pending, OutForm form)
		{
			let decl = pending.Decl;
			p.Form = form;
			p.OutName = new String(decl.VarName);
			p.OutDecl = new String(decl.VarType);
			p.TypeName.Set(decl.VarType);
			String raw = new .();
			raw.Append(mUnit.LeadingTrivia(decl.FirstTok));
			raw.Append(mUnit.NodeText(decl));
			raw.Append(mUnit.TrailingTrivia(decl.LastTok));
			p.OutDeclRaw = raw;
			pending.Pin = p;
			AddVarType(decl.VarName, decl.VarType);
			AddOutVar(decl.VarName, p);
			mDeclFolds.Add(p);
		}

		Node BuildExprNode(Expr e)
		{
			switch (e.Kind)
			{
			case .Name:
				Node n = NewExprNode(.Get, e);
				n.Text.Set(e.Op);
				return n;

			case .Member:
				if (IsNameChain(e))
				{
					Node n = NewExprNode(.Get, e);
					let text = mUnit.NodeText(e);
					let temp = ChainTemp(e, let rootName);
					if (temp != null && text.StartsWith(rootName) && text.Length > rootName.Length + 1 && text[rootName.Length] == '.')
					{
						// `fooResult.a.b` on a folded temp: member access wired to the call.
						n.Text.Set(text.Substring(rootName.Length + 1));
						let target = mGraph.AddDataIn(n, "target", "Receiver");
						mGraph.Connect(temp.Result, target);
						CountTempUse(rootName);
						return n;
					}
					let outPin = (temp == null) ? ChainOutVar(e) : null;
					if (outPin != null && text.StartsWith(rootName) && text.Length > rootName.Length + 1 && text[rootName.Length] == '.')
					{
						// `a.Length` on an out variable: member access wired to the out pin.
						n.Text.Set(text.Substring(rootName.Length + 1));
						let target = mGraph.AddDataIn(n, "target", "Receiver");
						mGraph.Connect(outPin, target);
						CountOutUse(outPin);
						return n;
					}
					n.Text.Set(text);
					return n;
				}
				Node n = NewExprNode(.Get, e);
				n.Text.Set(e.Op);
				n.NullCond = e.NullCond;
				n.Cascade = e.Cascade;
				// Target goes first so it lines up like a Blueprint "Target" pin.
				let target = mGraph.AddDataIn(n, "target", "Receiver");
				BuildTargetInput(target, e.A);
				return n;

			case .Call:
				Node n = mGraph.AddNode(.Call);
				n.IsPure = true;
				n.Original = new String(mUnit.NodeText(e));
				SetLines(n, e);
				FillCall(n, e);
				if (n.Result == null)
					mGraph.AddDataOut(n, "result", "Return Value");
				InferType(e, n.Result.TypeName);
				return n;

			case .Index:
				Node n = NewExprNode(.Index, e);
				n.NullCond = e.NullCond;
				let target = mGraph.AddDataIn(n, "target", "Receiver");
				BuildTargetInput(target, e.A);
				for (let arg in e.Args)
				{
					let pin = mGraph.AddDataIn(n, scope $"arg{@arg.Index}", "Index");
					BuildInput(pin, arg);
				}
				return n;

			case .Unary:
				Node n = NewExprNode(.Operator, e);
				n.Text.Set(e.Op);
				n.Postfix = e.Postfix;
				let a = mGraph.AddDataIn(n, "a", "");
				BuildInput(a, e.A);
				return n;

			case .Binary:
				Node n = NewExprNode(.Operator, e);
				n.Text.Set(e.Op);
				let a = mGraph.AddDataIn(n, "a", "");
				BuildInput(a, e.A);
				let b = mGraph.AddDataIn(n, "b", "");
				if (e.Op == "is" || e.Op == "as" || e.Op == "case")
					b.Default.Set(mUnit.NodeText(e.B));
				else
					BuildInput(b, e.B);
				return n;

			case .Conditional:
				Node n = NewExprNode(.Select, e);
				let c = mGraph.AddDataIn(n, "condition", "Condition");
				c.TypeName.Set("bool");
				BuildInput(c, e.A);
				let a = mGraph.AddDataIn(n, "a", "True");
				BuildInput(a, e.B);
				let b = mGraph.AddDataIn(n, "b", "False");
				BuildInput(b, e.C);
				return n;

			case .Cast:
				Node n = NewExprNode(.Cast, e);
				n.Text.Set(e.TypeText);
				let v = mGraph.AddDataIn(n, "value", "Value");
				BuildInput(v, e.A);
				return n;

			case .Paren:
				return BuildExprNode(Unparen(e));

			case .Literal, .Raw, .Assign:
				Node n = NewExprNode(.Expr, e);
				n.Text.Set(mUnit.NodeText(e));
				return n;

			case .New:
				return BuildConstruct(e);

			case .Lambda:
				return BuildLambda(e);
			}
		}
	}
}
