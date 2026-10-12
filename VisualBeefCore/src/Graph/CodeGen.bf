using System;
using System.Collections;
using VisualBeef.Catalog;
using VisualBeef.Syntax;

namespace VisualBeef.Graph
{
	/// Formatting conventions detected from the file being edited.
	struct CodeStyle
	{
		public String IndentUnit; // "\t" or N spaces
		public bool Allman;       // braces on their own line

		public static void Detect(CompilationUnit unit, String outIndentUnit, out bool allman)
		{
			int tabLines = 0;
			int spaceLines = 0;
			int minSpaces = int.MaxValue;
			for (let line in unit.Text.Split('\n'))
			{
				if (line.StartsWith('\t'))
					tabLines++;
				else if (line.StartsWith(' '))
				{
					int n = 0;
					while (n < line.Length && line[n] == ' ')
						n++;
					if (n < line.Length && n >= 2)
					{
						spaceLines++;
						minSpaces = Math.Min(minSpaces, n);
					}
				}
			}
			if (spaceLines > tabLines && minSpaces != int.MaxValue)
				outIndentUnit.Append(' ', Math.Clamp(minSpaces, 2, 8));
			else
				outIndentUnit.Append('\t');

			// Brace style: is '{' usually the first token on its line?
			int ownLine = 0;
			int sameLine = 0;
			for (int i = 1; i < unit.Tokens.Count; i++)
			{
				if (unit.TokenText(i) != "{")
					continue;
				let lead = unit.LeadingTrivia(i);
				let prevTrail = unit.TrailingTrivia(i - 1);
				if (lead.Contains('\n') || prevTrail.EndsWith('\n'))
					ownLine++;
				else
					sameLine++;
			}
			allman = ownLine >= sameLine;
		}

		/// Spacing conventions: `if (` or `if(`, and `} else` on one line or two. Votes are
		/// counted; a tie leaves the caller's default.
		public static void DetectSpacing(CompilationUnit unit, out int spaced, out int tight, out int elseNewLine, out int elseSameLine)
		{
			spaced = 0;
			tight = 0;
			elseNewLine = 0;
			elseSameLine = 0;
			for (int i = 0; i + 1 < unit.Tokens.Count; i++)
			{
				let t = unit.TokenText(i);
				if (t == "if" || t == "while" || t == "for" || t == "switch")
				{
					if (unit.TokenText(i + 1) != "(")
						continue;
					if (unit.TrailingTrivia(i).IsEmpty && unit.LeadingTrivia(i + 1).IsEmpty)
						tight++;
					else
						spaced++;
				}
				else if (t == "else" && i > 0 && unit.TokenText(i - 1) == "}")
				{
					if (unit.LeadingTrivia(i).Contains('\n') || unit.TrailingTrivia(i - 1).EndsWith('\n'))
						elseNewLine++;
					else
						elseSameLine++;
				}
			}
		}
	}

	/// Converts a graph back into Beef source for the method body.
	///
	/// The generator never emits a "best effort" for a graph it cannot express: such graphs get
	/// errors on the offending nodes (Graph.Errors) and SourceDocument.Commit refuses to write
	/// them. See docs/Codegen.md for the rules (temporaries, merges, scopes, style).
	///
	/// Generation runs twice: a planning pass records where every statement lands (block tree
	/// and order), which values are read where, and finds errors; the second pass writes the
	/// text, with declarations hoisted where the plan says so.
	class CodeGen
	{
		/// A block (`{ }`) in the generated code: the method body or a body of a compound
		/// statement.
		class ScopeInfo
		{
			public ScopeInfo Parent;
			/// The compound statement whose body this is; null for the method body.
			public StmtInfo Owner;
			public int Depth;
			/// The exec output whose body this is (a Branch's true / false, a Result's Ok / Err).
			public Pin Arm;
		}

		/// Where a statement node was written.
		class StmtInfo
		{
			public Node Node;
			public ScopeInfo Scope;
			/// Preorder position in the generated code.
			public int Seq;
		}

		/// Character offsets into a compound statement's Original text, used to keep the
		/// author's header and brace formatting when only the body changes.
		struct CompoundSplit
		{
			public int HeadEnd;      // end of the header: "while (x)", "do"
			public int BodyOpen;     // '{' of the first body; -1 if it had no braces
			public int BodyEnd;      // just after that body's '}'
			public int ElseStart;    // 'else'
			public int ElseEnd;
			public int ElseBodyOpen; // '{' after else
			public int TailStart;    // do-while: just after the body's '}'
		}

		Graph mGraph;
		String mUnit;
		bool mAllman;
		/// Indentation of the statement being written (a lambda's block body is indented from it).
		String mStmtIndent = new .() ~ delete _;
		bool mKwSpace = true;
		bool mElseSameLine;
		/// Switch `case` lines are indented one level inside the braces.
		bool mCaseIndented;
		bool mStyleDetected;
		Dictionary<Node, String> mTempNames = new .() ~ DeleteDictionaryAndValues!(_);
		HashSet<Node> mOnPath = new .() ~ delete _;
		/// The previous statement ended without a line break (original text continues the line).
		bool mNeedNewline;
		public List<String> Warnings = new .() ~ DeleteContainerAndItems!(_);

		/// Exec nodes reached by the execution flow (these are the ones written as statements).
		HashSet<Node> mInFlow = new .() ~ delete _;
		/// Every node that produces code: the flow plus the data feeding it.
		HashSet<Node> mEmitted = new .() ~ delete _;
		/// Values read by more than one input that must be computed once: written as
		/// `let __vN = <expr>;` before the first statement that reads them.
		HashSet<Node> mValueTemps = new .() ~ delete _;
		/// Value temps declared so far in this pass, and the block they were declared in.
		Dictionary<Node, ScopeInfo> mDeclared = new .() ~ delete _;

		bool mPlanning;
		Dictionary<Node, StmtInfo> mStmts = new .() ~ delete _;
		List<ScopeInfo> mScopeStore = new .() ~ DeleteContainerAndItems!(_);
		List<StmtInfo> mStmtStore = new .() ~ DeleteContainerAndItems!(_);
		ScopeInfo mScope;
		StmtInfo mCurStmt;
		int mSeq;
		/// Planning pass: statements reading the value of an exec node (impure call result,
		/// local variable, loop element).
		Dictionary<Node, List<StmtInfo>> mUses = new .() ~ DeleteDictionaryAndValues!(_);
		/// Impure calls whose result is read after the block they run in: their temp is declared
		/// (`T name = default;`) before the anchor statement, and the call assigns it.
		Dictionary<Node, List<Node>> mHoistAt = new .() ~ DeleteDictionaryAndValues!(_);
		HashSet<Node> mHoisted = new .() ~ delete _;
		/// Merge points of branches (see Continuation).
		Dictionary<Node, Node> mMergeCache = new .() ~ delete _;
		HashSet<Node> mMergeBusy = new .() ~ delete _;
		HashSet<Node> mVisitBusy = new .() ~ delete _;

		/// Planning pass: the statements reading each out pin.
		Dictionary<Pin, List<StmtInfo>> mOutUses = new .() ~ DeleteDictionaryAndValues!(_);
		/// Planning pass: the statement an inline call with out pins (a pure call, or one outside
		/// the flow) is written in. Calls in the flow are their own statement (mStmts).
		Dictionary<Node, StmtInfo> mOutHome = new .() ~ delete _;
		/// Declarations of out variables (`T name;`) written before an anchor statement, in order.
		Dictionary<Node, List<Pin>> mOutDeclAt = new .() ~ DeleteDictionaryAndValues!(_);
		/// Out pins whose declaration is not right before the call's own statement.
		HashSet<Pin> mOutHoisted = new .() ~ delete _;

		/// How each out pin is written this time (decided after the planning pass).
		enum OutSpell
		{
			/// `out b` / `out let a`: kept exactly as read.
			AsIs,
			/// `?`
			Discard,
			/// `var name` (or the `let` it was read with)
			Inline,
			/// `T name;` right before the call's statement, `out name` (`ref name`) at the call.
			DeclHere,
			/// `T name;` before an enclosing statement (read after the block), `out name`.
			Hoisted
		}
		Dictionary<Pin, OutSpell> mOutSpell = new .() ~ delete _;

		public this(Graph graph, StringView indentUnit, bool allman)
		{
			mGraph = graph;
			mUnit = new String(indentUnit);
			mAllman = allman;
		}

		public ~this()
		{
			delete mUnit;
		}

		int mFileSpaced;
		int mFileTight;
		int mFileElseNewLine;
		int mFileElseSameLine;

		/// Uses the file's spacing conventions where the method itself shows none.
		public void SetFileStyle(CompilationUnit unit)
		{
			CodeStyle.DetectSpacing(unit, out mFileSpaced, out mFileTight, out mFileElseNewLine, out mFileElseSameLine);
		}

		/// True when the generator refused the graph (see Graph.Errors).
		public bool HasErrors => !mGraph.Errors.IsEmpty;

		void AddError(Node node, StringView message)
		{
			if (mPlanning)
				mGraph.AddError(node, message);
		}

		void Warn(StringView message, Node node = null)
		{
			if (!mPlanning)
				return;
			if (node != null)
				mGraph.AddWarning(node, message);
			for (let w in Warnings)
				if (w == message)
					return;
			Warnings.Add(new String(message));
		}

		void CollectFlow()
		{
			mEmitted.Clear();
			mGraph.GetReachable(mEmitted);
			mInFlow.Clear();
			List<Node> stack = scope .();
			if (mGraph.Entry != null)
				stack.Add(mGraph.Entry);
			// A lambda's block body runs where the lambda is called: its statements are written
			// as statements too (inside the lambda's text).
			for (let n in mEmitted)
			{
				if (!n.IsPure)
					continue;
				for (let p in n.Outputs)
				{
					if (p.Kind != .Exec)
						continue;
					let next = mGraph.ExecTarget(p);
					if (next != null)
						stack.Add(next);
				}
			}
			while (!stack.IsEmpty)
			{
				let n = stack.PopBack();
				if (!mInFlow.Add(n))
					continue;
				for (let p in n.Outputs)
				{
					if (p.Kind != .Exec)
						continue;
					let next = mGraph.ExecTarget(p);
					if (next != null)
						stack.Add(next);
				}
			}
		}

		/// Generates the text that replaces everything between the end of the body's '{' and the
		/// start of its '}' token. Check HasErrors afterwards: an invalid graph still produces
		/// text (for snippets), but it must not be written to the file.
		public void GenerateBody(StringView braceIndent, String o)
		{
			mGraph.ClearErrors();
			CollectFlow();
			// Node-anchored checks that need no code (Target / self, required inputs, ref
			// arguments, wire types): their errors refuse the commit like the generator's own.
			GraphValidator.Validate(mGraph, mEmitted);
			AssignFlowFields();
			FindValueTemps();

			mPlanning = true;
			WarnUnwritten();
			{
				String scratch = scope .();
				EmitBody(braceIndent, scratch);
			}
			AnalyzeProducers();
			AnalyzeOuts();
			AssignOutNames();
			AnalyzeLifetimes();
			mPlanning = false;
			ResetPass();
			EmitBody(braceIndent, o);
			ResetPass();
			RecordOutForms();
		}

		/// Nodes the execution flow never reaches (and no reached node reads) produce no code. They
		/// are kept in the Sheet, but a commit that leaves them out says so: a warning on each.
		void WarnUnwritten()
		{
			for (let n in mGraph.Nodes)
			{
				if (n.Kind == .Entry || mEmitted.Contains(n))
					continue;
				Warn("Not connected to the execution flow: nothing is written for this node. Connect it to a statement, or delete it.", n);
			}
		}

		void ResetPass()
		{
			mDeclared.Clear();
			mStmts.Clear();
			ClearAndDeleteItems!(mScopeStore);
			ClearAndDeleteItems!(mStmtStore);
			for (let kv in mUses)
				delete kv.value;
			mUses.Clear();
			for (let kv in mOutUses)
				delete kv.value;
			mOutUses.Clear();
			mOutHome.Clear();
			for (let kv in mNameUses)
			{
				delete kv.key;
				delete kv.value;
			}
			mNameUses.Clear();
			mScope = null;
			mCurStmt = null;
			mSeq = 0;
			mOnPath.Clear();
			mVisitBusy.Clear();
			mNeedNewline = false;
		}

		void EmitBody(StringView braceIndent, String o)
		{
			mScope = PushScope(null);
			if (mGraph.RawOpenTrail != null)
			{
				o.Append(mGraph.RawOpenTrail);
				mNeedNewline = !mGraph.RawOpenTrail.EndsWith('\n');
			}
			else
				o.Append('\n');
			String indent = scope .(braceIndent);
			indent.Append(mUnit);
			// The function's Locals first, in list order, then the flow.
			for (let local in mGraph.Locals)
				GenStatement(local, indent, o);
			GenChain(mGraph.Entry.Then, indent, o, null);
			let closeLead = mGraph.RawCloseLead;
			if (closeLead != null && (closeLead.Contains('\n') || mNeedNewline || (mGraph.CloseAtLineStart && o.EndsWith('\n'))))
				o.Append(closeLead);
			else
			{
				if (mNeedNewline)
					o.Append('\n');
				if (mGraph.EndComments != null)
					AppendCommentLines(mGraph.EndComments, indent, o);
				o.Append(braceIndent);
			}
			mNeedNewline = false;
		}

		// ------------------------------------------------------------------ blocks and positions

		ScopeInfo PushScope(StmtInfo owner)
		{
			ScopeInfo s = new .();
			s.Parent = mScope;
			s.Owner = owner;
			s.Depth = (mScope != null) ? mScope.Depth + 1 : 0;
			mScopeStore.Add(s);
			mScope = s;
			return s;
		}

		void PopScope()
		{
			mScope = mScope.Parent;
		}

		StmtInfo RecordStmt(Node node)
		{
			if (mStmts.ContainsKey(node))
			{
				AddError(node, "Two flow wires lead into this node, so its code would be written twice. Connect it once, or wire every output of a Branch / Switch (Default too) into it: it is then written after the if / else / switch.");
			}
			StmtInfo info = new .();
			info.Node = node;
			info.Scope = mScope;
			info.Seq = mSeq++;
			mStmtStore.Add(info);
			mStmts[node] = info;
			return info;
		}

		/// `inner` is `outer` or nested in it.
		static bool IsWithin(ScopeInfo inner, ScopeInfo outer)
		{
			for (var s = inner; s != null; s = s.Parent)
				if (s == outer)
					return true;
			return false;
		}

		static ScopeInfo CommonScope(ScopeInfo a, ScopeInfo b)
		{
			var a;
			var b;
			while (a.Depth > b.Depth)
				a = a.Parent;
			while (b.Depth > a.Depth)
				b = b.Parent;
			while (a != b)
			{
				a = a.Parent;
				b = b.Parent;
			}
			return a;
		}

		/// The statement directly in block `a` that contains (or is) `s`.
		static StmtInfo ChildIn(ScopeInfo a, StmtInfo s)
		{
			if (s.Scope == a)
				return s;
			var sc = s.Scope;
			while (sc.Parent != a)
				sc = sc.Parent;
			return sc.Owner;
		}

		/// Registers the statements nested in a compound written verbatim from its original text.
		void RegisterNested(Node node)
		{
			let info = mCurStmt;
			for (let p in node.Outputs)
			{
				if (p.Kind != .Exec || p.Name == "then")
					continue;
				PushScope(info);
				var n = mGraph.ExecTarget(p);
				int guard = 0;
				while (n != null && guard++ < 100000 && !mOnPath.Contains(n))
				{
					let ni = RecordStmt(n);
					let prev = mCurStmt;
					mCurStmt = ni;
					mOnPath.Add(n);
					RegisterNested(n);
					mOnPath.Remove(n);
					mCurStmt = prev;
					n = mGraph.ExecTarget(n.Then);
				}
				PopScope();
			}
		}

		// ------------------------------------------------------------------ execution merges

		/// The node that runs after `node` in the same block: its `then` link or, for a node whose
		/// arms are exclusive and all lead to the same node (a diamond: Branch, Switch, FlipFlop,
		/// looping MultiGate), that node.
		Node Continuation(Node node)
		{
			let next = mGraph.ExecTarget(node.Then);
			if (next != null || !FlowMacros.HasMerge(node))
				return next;
			return MergePoint(node);
		}

		/// First node reached by every arm of a node (Branch true/false, each Switch case and
		/// Default...), or null. An empty arm means "nothing runs after the arm", so there is no
		/// merge then.
		Node MergePoint(Node branch)
		{
			if (mMergeCache.TryGetValue(branch, let cached))
				return cached;
			if (!mMergeBusy.Add(branch))
				return null;
			List<List<Node>> arms = scope .();
			defer { for (let l in arms) delete l; }
			bool anyEmpty = false;
			for (let p in branch.Outputs)
			{
				if (p.Kind != .Exec || p.Name == "then")
					continue;
				let seq = new List<Node>();
				arms.Add(seq);
				WalkArm(p, seq);
				if (seq.IsEmpty)
					anyEmpty = true;
			}
			Node result = null;
			if (arms.Count >= 2 && !anyEmpty)
			{
				List<HashSet<Node>> sets = scope .();
				defer { for (let h in sets) delete h; }
				for (int i = 1; i < arms.Count; i++)
				{
					let h = new HashSet<Node>();
					for (let n in arms[i])
						h.Add(n);
					sets.Add(h);
				}
				for (let n in arms[0])
				{
					bool inAll = true;
					for (let h in sets)
						if (!h.Contains(n))
							inAll = false;
					if (inAll)
					{
						result = n;
						break;
					}
				}
			}
			mMergeBusy.Remove(branch);
			mMergeCache[branch] = result;
			return result;
		}

		void WalkArm(Pin start, List<Node> outSeq)
		{
			HashSet<Node> seen = scope .();
			var n = mGraph.ExecTarget(start);
			while (n != null && seen.Add(n) && outSeq.Count < 100000)
			{
				outSeq.Add(n);
				n = Continuation(n);
			}
		}

		// ------------------------------------------------------------------ shared values

		/// Text that is a plain name or literal: reading it twice is the same as reading it once.
		static bool IsTrivialText(StringView text)
		{
			var t = text;
			t.Trim();
			if (t.Contains('(') || t.Contains('[') || t.Contains("++") || t.Contains("--") || t.Contains('='))
				return false;
			if (t.StartsWith("new ") || t.StartsWith("scope") || t.StartsWith("append "))
				return false;
			return IsAtomic(t);
		}

		/// A value without side effects that is cheap to compute: names, literals, member reads,
		/// and operators / casts / selects / indexers over those. Such a value may be written
		/// once per input that reads it. Everything else (any call, `++`, unknown code) shared
		/// by several inputs is computed once into a temporary.
		/// `inFlow`: exec nodes in the execution flow (an impure call outside it is called where
		/// its value is used); null treats every impure call as being in the flow.
		public static bool IsTrivialValue(Graph g, Node n, HashSet<Node> inFlow, int depth = 0)
		{
			if (depth > 64)
				return false;
			if (!n.IsPure)
				return !(n.Kind == .Call && inFlow != null && !inFlow.Contains(n));
			switch (n.Kind)
			{
			case .Expr:
				return IsTrivialText(n.Text);
			case .This, .Base:
				return true;
			case .Operator:
				if (n.Text == "++" || n.Text == "--")
					return false;
			case .Get, .Cast, .Select, .Index:
			default:
				return false;
			}
			for (let p in n.Inputs)
			{
				if (p.Kind != .Data)
					continue;
				let src = g.DataSource(p);
				if (src == null)
				{
					if (!IsTrivialText(p.Default))
						return false;
				}
				else if (!IsTrivialValue(g, src, inFlow, depth + 1))
					return false;
			}
			return true;
		}

		void FindValueTemps()
		{
			mValueTemps.Clear();
			Dictionary<Node, int> uses = scope .();
			HashSet<Node> outRead = scope .();
			for (let l in mGraph.Links)
			{
				if (l.From.Kind != .Data || !mEmitted.Contains(l.To.Owner) || !mEmitted.Contains(l.From.Owner))
					continue;
				// Reading an out pin reads its variable, not the call's value.
				if (l.From.IsOutArg)
				{
					outRead.Add(l.From.Owner);
					continue;
				}
				if (uses.TryAdd(l.From.Owner, let keyPtr, let valuePtr))
					*valuePtr = 1;
				else
					(*valuePtr)++;
			}
			// A Math Expression reads a pin once for every time its name appears in the expression.
			for (let l in mGraph.Links)
			{
				if (l.To.Owner.Kind != .MathExpr || l.From.Kind != .Data || l.From.IsOutArg || !mEmitted.Contains(l.To.Owner))
					continue;
				int extra = MathExpression.UseCount(l.To.Owner.Text, l.To.Name) - 1;
				if (extra > 0 && uses.TryGetValue(l.From.Owner, let count))
					uses[l.From.Owner] = count + extra;
			}
			for (let kv in uses)
			{
				let n = kv.key;
				bool candidate = n.IsPure || (n.Kind == .Call && !mInFlow.Contains(n));
				if (candidate && kv.value >= 2 && !IsTrivialValue(mGraph, n, mInFlow))
					mValueTemps.Add(n);
			}
			// A call written where its value is read (pure, or outside the flow) whose value
			// nothing reads, while its out pins are read: it runs once, as a statement of its own
			// before the first reader (Blueprint evaluates such a pure node once per use).
			for (let n in outRead)
			{
				bool isInline = n.Kind == .Call && (n.IsPure || !mInFlow.Contains(n));
				if (isInline && !uses.ContainsKey(n))
					mValueTemps.Add(n);
			}
			// A value that is no longer shared forgets its temp name.
			for (let n in mGraph.Nodes)
				if (n.IsPure && !n.Text2.IsEmpty && !mValueTemps.Contains(n) && n.Text2.StartsWith("__v"))
					n.Text2.Clear();
		}

		/// Walks the values a statement's own inputs read (not its bodies): records reads of exec
		/// nodes' values, and collects shared values not declared yet, dependencies first.
		void VisitHeader(Node node, List<Node> outNewTemps)
		{
			bool loopCond = node.Kind == .While || node.Kind == .DoWhile;
			for (let p in node.Inputs)
			{
				if (p.Kind != .Data)
					continue;
				let link = mGraph.FindLinkTo(p);
				if (link != null)
					VisitValue(link.From.Owner, link.From, outNewTemps, loopCond || (node.Kind == .For && p.Name == "count"));
			}
		}

		void VisitInputs(Node node, List<Node> outNewTemps, bool loopCond)
		{
			if (!mVisitBusy.Add(node))
				return; // data loop; reported when the expression is written
			for (let p in node.Inputs)
			{
				if (p.Kind != .Data)
					continue;
				let link = mGraph.FindLinkTo(p);
				if (link != null)
					VisitValue(link.From.Owner, link.From, outNewTemps, loopCond);
			}
			mVisitBusy.Remove(node);
		}

		void VisitValue(Node src, Pin fromPin, List<Node> outNewTemps, bool loopCond)
		{
			bool temp = mValueTemps.Contains(src);
			if (fromPin != null && fromPin.IsOutArg)
			{
				// Reads the out variable. The call itself is written in its own statement, or
				// where its value is read, or (a temp) before the first reader.
				RecordOutUse(fromPin);
				if (!temp)
					return;
			}
			if (!src.IsPure && !temp)
			{
				if (src.Kind == .Call && !mInFlow.Contains(src))
				{
					NoteOutHome(src);
					VisitInputs(src, outNewTemps, loopCond); // called where it is used
					return;
				}
				if (src.Kind == .Call || src.Kind == .LocalVar || src.Kind == .ForEach || src.Kind == .Using || src.IsCountingLoop)
					RecordUse(src);
				return;
			}
			if (temp)
			{
				if (loopCond)
					AddError(src, "This value feeds a loop condition and other inputs too. A shared value is computed once, so the condition would never change. Give the condition its own node.");
				if (mDeclared.TryGetValue(src, let declScope))
				{
					if (!IsWithin(mScope, declScope))
						AddError(src, "This value is shared by nodes in different blocks: it is first computed inside a branch or loop body and read outside it. Store it in a Local Variable before the branch and read that.");
					return;
				}
				VisitInputs(src, outNewTemps, loopCond);
				mDeclared[src] = mScope;
				NoteOutHome(src);
				outNewTemps.Add(src);
				return;
			}
			if (src.Kind == .Call)
				NoteOutHome(src);
			if (src.Kind == .Get)
				RecordNameUse(src);
			VisitInputs(src, outNewTemps, loopCond);
		}

		void RecordOutUse(Pin outPin)
		{
			if (!mPlanning || mCurStmt == null)
				return;
			List<StmtInfo> list;
			if (!mOutUses.TryGetValue(outPin, out list))
			{
				list = new .();
				mOutUses[outPin] = list;
			}
			list.Add(mCurStmt);
		}

		/// An inline call with out pins is written in the statement being visited.
		void NoteOutHome(Node call)
		{
			if (!mPlanning || mCurStmt == null || call.Kind != .Call || !call.HasOutArgs)
				return;
			mOutHome.TryAdd(call, mCurStmt);
		}

		/// True when writing this statement would declare a shared value first.
		bool HeaderHasNewTemps(Node node)
		{
			List<Node> temps = scope .();
			Dictionary<Node, ScopeInfo> saved = scope .();
			for (let kv in mDeclared)
				saved[kv.key] = kv.value;
			bool planning = mPlanning;
			mPlanning = false; // no errors / uses from this probe
			VisitHeader(node, temps);
			mPlanning = planning;
			mDeclared.Clear();
			for (let kv in saved)
				mDeclared[kv.key] = kv.value;
			return !temps.IsEmpty;
		}

		void RecordUse(Node producer)
		{
			if (!mPlanning || mCurStmt == null)
				return;
			List<StmtInfo> list;
			if (!mUses.TryGetValue(producer, out list))
			{
				list = new .();
				mUses[producer] = list;
			}
			list.Add(mCurStmt);
		}

		/// Shared order of declaration for a statement's new temps, as the generator writes them
		/// (GraphBuilder uses it to decide whether `let __vN = ...;` lines can fold back into a
		/// shared node without moving code).
		public static void CollectHeaderTemps(Graph g, Node stmt, HashSet<Node> temps, HashSet<Node> declared, List<Node> outOrder)
		{
			HashSet<Node> busy = scope .();
			for (let p in stmt.Inputs)
			{
				if (p.Kind != .Data)
					continue;
				let src = g.DataSource(p);
				if (src != null)
					CollectTempsRec(g, src, temps, declared, busy, outOrder);
			}
			if (stmt.Kind == .Defer)
			{
				List<Node> shared = scope .();
				DeferSharedTemps(g, stmt, temps, shared);
				for (let t in shared)
					CollectTempsRec(g, t, temps, declared, busy, outOrder);
			}
		}

		/// A Defer's Deferred body reading a shared value that a statement after the Defer reads too
		/// (`let __v0 = new T(); defer delete __v0; __v0.Run();`, the Defer -> Delete form): the
		/// value is declared before the Defer, in the block both are in. A value read only inside
		/// the deferred body is left where it is (computing it earlier would change when it runs).
		public static void DeferSharedTemps(Graph g, Node deferNode, HashSet<Node> temps, List<Node> outTemps)
		{
			let bodyPin = deferNode.FindOutput("body");
			if (bodyPin == null)
				return;
			HashSet<Node> body = scope .();
			List<Node> stack = scope .();
			let first = g.ExecTarget(bodyPin);
			if (first != null)
				stack.Add(first);
			while (!stack.IsEmpty)
			{
				let n = stack.PopBack();
				if (!body.Add(n))
					continue;
				for (let p in n.Outputs)
					if (p.Kind == .Exec)
					{
						let next = g.ExecTarget(p);
						if (next != null)
							stack.Add(next);
					}
			}
			// The values the body's statements read, through pure nodes.
			HashSet<Node> seen = scope .();
			List<Node> values = scope .();
			for (let n in body)
				for (let p in n.Inputs)
					if (p.Kind == .Data)
					{
						let src = g.DataSource(p);
						if (src != null)
							values.Add(src);
					}
			while (!values.IsEmpty)
			{
				let v = values.PopFront();
				if (!seen.Add(v) || body.Contains(v))
					continue;
				if (temps.Contains(v))
				{
					bool outside = false;
					for (let l in g.Links)
						if (l.From.Owner == v && l.From.Kind == .Data && !body.Contains(l.To.Owner) && !l.To.Owner.IsPure)
							outside = true;
					if (outside && !outTemps.Contains(v))
						outTemps.Add(v);
					continue;
				}
				if (!v.IsPure)
					continue;
				for (let p in v.Inputs)
					if (p.Kind == .Data)
					{
						let src = g.DataSource(p);
						if (src != null)
							values.Add(src);
					}
			}
		}

		static void CollectTempsRec(Graph g, Node src, HashSet<Node> temps, HashSet<Node> declared, HashSet<Node> busy, List<Node> outOrder)
		{
			bool temp = temps.Contains(src);
			if (!src.IsPure && !temp)
				return;
			if (temp && (declared.Contains(src) || outOrder.Contains(src)))
				return;
			if (!busy.Add(src))
				return;
			for (let p in src.Inputs)
			{
				if (p.Kind != .Data)
					continue;
				let s = g.DataSource(p);
				if (s != null)
					CollectTempsRec(g, s, temps, declared, busy, outOrder);
			}
			busy.Remove(src);
			if (temp)
				outOrder.Add(src);
		}

		/// The out pins a statement writes, in the order they appear in its code: a call's Target
		/// first, then its arguments, nested calls where they sit. Statements read as values
		/// (calls in the flow, locals) are not entered. GraphBuilder uses the same order to check
		/// that `T a;` lines in front of a statement fold back into out pins exactly.
		/// `inFlow` null treats every impure call as a statement.
		public static void CollectOutPins(Graph g, Node stmt, HashSet<Node> inFlow, List<Pin> outPins)
		{
			HashSet<Node> seen = scope .();
			CollectOutPinsRec(g, stmt, inFlow, seen, outPins);
		}

		static void CollectOutPinsRec(Graph g, Node n, HashSet<Node> inFlow, HashSet<Node> seen, List<Pin> outPins)
		{
			if (!seen.Add(n))
				return;
			void Source(Pin input)
			{
				let src = g.DataSource(input);
				if (src == null)
					return;
				if (!src.IsPure && !(src.Kind == .Call && inFlow != null && !inFlow.Contains(src)))
					return;
				CollectOutPinsRec(g, src, inFlow, seen, outPins);
			}
			if (n.Kind == .Call)
			{
				let target = n.FindInput("target");
				if (target != null)
					Source(target);
				List<Pin> args = scope .();
				n.GetArgPins(args);
				for (let p in args)
				{
					if (p.IsInput)
						Source(p);
					else if (p.IsOutArg)
						outPins.Add(p);
				}
				return;
			}
			for (let p in n.Inputs)
				if (p.Kind == .Data)
					Source(p);
		}

		/// The statement a call with out pins is written in (null: inside unchanged code).
		StmtInfo OutHomeOf(Node call)
		{
			if (mInFlow.Contains(call) && !call.IsPure)
			{
				if (mStmts.TryGetValue(call, let info))
					return info;
				return null;
			}
			if (mOutHome.TryGetValue(call, let info))
				return info;
			return null;
		}

		static bool IsLoopKind(NodeKind k) => k == .While || k == .DoWhile || k == .For || k == .ForEach;

		/// After the planning pass: decides how every out pin is written and where its variable
		/// is declared (docs/Calls-and-Receivers.md):
		///  - nothing reads it: `?` for a new pin, or the spelling it was read with;
		///  - read in the call's statement, its bodies, or later in its block: `var name` in the
		///    argument (a `var` in a loop header only lives inside the loop, so a read after the
		///    loop declares `T name;` right before it);
		///  - read after the block the call runs in: `T name;` hoisted before the statement of the
		///    innermost block holding the call and every reader, like a hoisted call result;
		///  - read where the call has not run (another branch, earlier): refused.
		void AnalyzeOuts()
		{
			mOutSpell.Clear();
			for (let n in mGraph.Nodes)
			{
				if (n.Kind != .Call || !mEmitted.Contains(n) || !n.HasOutArgs)
					continue;
				let home = OutHomeOf(n);
				String title = scope .();
				n.GetTitle(title);
				for (let p in n.Outputs)
				{
					if (!p.IsOutArg)
						continue;
					if (p.Form == .Existing || (p.Form == .Inline && p.OutKeyword) || home == null)
					{
						mOutSpell[p] = .AsIs;
						continue;
					}
					ScopeInfo hoistTo = null;
					bool bad = false;
					bool declBeforeLoop = false;
					List<StmtInfo> uses = null;
					mOutUses.TryGetValue(p, out uses);
					if (uses != null)
					{
						for (let u in uses)
						{
							if (u == home)
								continue;
							bool inBody = false;
							for (var s = u.Scope; s != null; s = s.Parent)
								if (s.Owner == home)
									inBody = true;
							if (inBody)
							{
								// A do-while body runs before its condition.
								if (home.Node.Kind == .DoWhile)
								{
									bad = true;
									AddError(u.Node, scope $"Reads the out value '{p.Label}' of '{title}' inside the loop body, which runs before the condition that calls it.");
								}
								continue;
							}
							if (u.Seq > home.Seq && IsWithin(u.Scope, home.Scope))
							{
								if (IsLoopKind(home.Node.Kind))
									declBeforeLoop = true;
								continue;
							}
							let common = CommonScope(home.Scope, u.Scope);
							let sc = ChildIn(common, home);
							let su = ChildIn(common, u);
							if (sc.Seq < su.Seq)
							{
								if (hoistTo == null || common.Depth < hoistTo.Depth)
									hoistTo = common;
							}
							else
							{
								bad = true;
								AddError(u.Node, scope $"Reads the out value '{p.Label}' of '{title}', which has not run on this path (it is in another branch, or later in the flow).");
							}
						}
					}
					if (bad)
					{
						AddError(n, scope $"The out value '{p.Label}' of '{title}' is read where this call has not run (another branch, or earlier in the flow). Wire it only into nodes that run after the call.");
						continue;
					}
					OutSpell spell;
					if (hoistTo != null)
						spell = .Hoisted;
					else if (p.Form == .Declared || p.Form == .DeclaredRef || declBeforeLoop)
						spell = .DeclHere;
					else if (uses == null && (p.Form == .Discard || (p.OutAuto && !p.OutKeepName)))
						spell = .Discard;
					else
						spell = .Inline;
					if (spell == .DeclHere || spell == .Hoisted)
					{
						let type = OutDeclType(p);
						if (type.IsEmpty || type == "var" || type == "let" || type == "void")
						{
							AddError(n, scope $"The out value '{p.Label}' of '{title}' is read after the block it is set in, so its variable must be declared before that block, but its type is unknown. Read it inside the block, or use a typed Local Variable.");
							continue;
						}
					}
					mOutSpell[p] = spell;
					if (spell != .DeclHere && spell != .Hoisted)
						continue;
					var anchor = home;
					if (hoistTo != null)
					{
						anchor = ChildIn(hoistTo, home);
						if (anchor != home && anchor.Node.Kind == .Flow && anchor.Node.Text == FlowMacros.Sequence)
						{
							AddError(n, scope $"The out value '{p.Label}' of '{title}' is read after the Sequence it runs in. Store it in a typed Local Variable declared before the Sequence instead.");
							continue;
						}
					}
					List<Pin> list;
					if (!mOutDeclAt.TryGetValue(anchor.Node, out list))
					{
						list = new .();
						mOutDeclAt[anchor.Node] = list;
					}
					list.Add(p);
					if (anchor != home || p.Form != .Declared && p.Form != .DeclaredRef)
						mOutHoisted.Add(p);
				}
			}
			// Order: declarations moved here from inner statements first, then the anchor's own in
			// code order (the order GraphBuilder checks when it folds `T a;` lines back).
			for (let kv in mOutDeclAt)
			{
				let list = kv.value;
				List<Pin> own = scope .();
				CollectOutPins(mGraph, kv.key, mInFlow, own);
				List<Pin> sorted = scope .();
				for (let p in list)
					if (!own.Contains(p))
						sorted.Add(p);
				for (let p in own)
					if (list.Contains(p) && !sorted.Contains(p))
						sorted.Add(p);
				for (let p in list)
					if (!sorted.Contains(p))
						sorted.Add(p);
				list.Clear();
				list.AddRange(sorted);
			}
		}

		/// Gives every out variable that is written with a name and has none (or, for a name the
		/// generator chose, one that is now taken) a name: the parameter name, made unique.
		/// Names read from the code are never changed.
		void AssignOutNames()
		{
			for (let kv in mOutSpell)
			{
				let p = kv.key;
				let spell = kv.value;
				if (spell == .AsIs || spell == .Discard)
					continue;
				bool hasName = p.OutName != null && !p.OutName.IsEmpty;
				if (hasName && (!p.OutAuto || !OutNameTaken(p, p.OutName)))
					continue;
				String name = scope .();
				NodeFactory.FreshOutName(mGraph, p.Label, p, name);
				String baseName = scope .(name);
				for (int suffix = 2; OutNameTaken(p, name); suffix++)
				{
					name.Set(baseName);
					name.AppendF("{}", suffix);
				}
				if (p.OutName == null)
					p.OutName = new String(name);
				else
					p.OutName.Set(name);
				p.Owner.Edited = true;
			}
		}

		/// After writing: the pins remember the spelling the code now has, so the live graph
		/// matches what a fresh read of the file gives.
		void RecordOutForms()
		{
			for (let kv in mOutSpell)
			{
				let p = kv.key;
				switch (kv.value)
				{
				case .Discard:
					p.Form = .Discard;
				case .Inline:
					p.Form = .Inline;
					if (p.OutDecl == null)
						p.OutDecl = new String("var");
					else if (p.OutDecl != "let")
						p.OutDecl.Set("var");
				case .DeclHere, .Hoisted:
					if (p.Form != .DeclaredRef)
					{
						String type = scope .(OutDeclType(p));
						p.Form = .Declared;
						if (p.OutDecl == null)
							p.OutDecl = new String(type);
						else
							p.OutDecl.Set(type);
					}
				default:
				}
			}
		}

		bool OutNameTaken(Pin pin, StringView name)
		{
			if (TempNameTaken(null, name, pin))
				return true;
			if (mOwnerFields != null && mOwnerFields.ContainsAlt(name))
				return true;
			for (let n in mGraph.Nodes)
			{
				if (n.Kind == .Call && n.Text2 == name)
					return true;
				for (let p in n.Outputs)
					if (p != pin && p.IsOutArg && p.OutName == name)
						return true;
			}
			return false;
		}

		/// After the planning pass: checks that every read of a call result, local variable or
		/// loop element is in scope, and hoists call results read after their block.
		void AnalyzeProducers()
		{
			for (let kv in mUses)
			{
				let producer = kv.key;
				if (!mStmts.TryGetValue(producer, let pinfo))
					continue;
				switch (producer.Kind)
				{
				case .LocalVar:
					for (let u in kv.value)
					{
						if (IsWithin(u.Scope, pinfo.Scope) && pinfo.Seq < u.Seq)
							continue;
						AddError(producer, scope $"Local '{producer.Text}' is read outside the block that declares it, or before it is declared.");
						AddError(u.Node, scope $"Reads local '{producer.Text}', which is not in scope here.");
					}
				case .ForEach:
					for (let u in kv.value)
					{
						bool inBody = false;
						for (var s = u.Scope; s != null; s = s.Parent)
							if (s.Owner == pinfo)
								inBody = true;
						if (inBody)
							continue;
						AddError(producer, scope $"The loop element '{producer.Text}' is read outside the loop body.");
						AddError(u.Node, scope $"Reads the loop element '{producer.Text}' outside its loop.");
					}
				case .Using:
					for (let u in kv.value)
					{
						bool inBody = false;
						for (var s = u.Scope; s != null; s = s.Parent)
							if (s.Owner == pinfo)
								inBody = true;
						if (inBody)
							continue;
						AddError(producer, scope $"'{producer.Text}' of this Using is read outside its body (it is disposed when the body ends).");
						AddError(u.Node, scope $"Reads '{producer.Text}' outside the Using that declares it.");
					}
				case .Call:
					String title = scope .();
					producer.GetTitle(title);
					ScopeInfo hoistTo = null;
					bool bad = false;
					for (let u in kv.value)
					{
						if (IsWithin(u.Scope, pinfo.Scope) && pinfo.Seq < u.Seq)
							continue;
						let common = CommonScope(pinfo.Scope, u.Scope);
						let sc = ChildIn(common, pinfo);
						let su = ChildIn(common, u);
						if (sc.Seq < su.Seq)
						{
							if (hoistTo == null || common.Depth < hoistTo.Depth)
								hoistTo = common;
						}
						else
						{
							bad = true;
							AddError(u.Node, scope $"Reads the result of '{title}', which has not run on this path (it is in another branch, or later in the flow).");
						}
					}
					if (bad)
						AddError(producer, scope $"The result of '{title}' is read where this call has not run (another branch, or earlier in the flow). Wire the value only into nodes that run after the call.");
					else if (hoistTo != null)
					{
						let result = producer.Result;
						StringView type = (result != null) ? (StringView)result.TypeName : "";
						if (type.IsEmpty || type == "var" || type == "let" || type == "void")
						{
							AddError(producer, scope $"The result of '{title}' is read after the block it runs in, so it must be declared before that block, but its type is unknown. Store it in a typed Local Variable declared before the block instead.");
							continue;
						}
						let anchor = ChildIn(hoistTo, pinfo).Node;
						if (anchor.Kind == .Flow && anchor.Text == FlowMacros.Sequence)
						{
							AddError(producer, scope $"The result of '{title}' is read after the Sequence it runs in. Store it in a typed Local Variable declared before the Sequence instead.");
							continue;
						}
						List<Node> list;
						if (!mHoistAt.TryGetValue(anchor, out list))
						{
							list = new .();
							mHoistAt[anchor] = list;
						}
						list.Add(producer);
						mHoisted.Add(producer);
					}
				default:
				}
			}
		}

		// ------------------------------------------------------------------ style

		void EnsureStyle()
		{
			if (mStyleDetected)
				return;
			mStyleDetected = true;
			{
				int indentedVotes = 0;
				int flatVotes = 0;
				for (let n in mGraph.Nodes)
				{
					if (n.Kind != .Switch || n.Original == null || n.Line <= 0)
						continue;
					if (SplitSwitch(n, var ss))
					{
						if (ss.CaseIndented == 1)
							indentedVotes++;
						else if (ss.CaseIndented == 0)
							flatVotes++;
					}
				}
				mCaseIndented = indentedVotes > flatVotes;
			}
			if (mFileSpaced != mFileTight)
				mKwSpace = mFileSpaced > mFileTight;
			if (mFileElseNewLine != mFileElseSameLine)
				mElseSameLine = mFileElseSameLine > mFileElseNewLine;

			// The method's own statements win over the file.
			int spaced = 0;
			int tight = 0;
			int allman = 0;
			int kr = 0;
			int elseNl = 0;
			int elseSame = 0;
			for (let n in mGraph.Nodes)
			{
				if (n.Original == null || n.Line <= 0)
					continue;
				if (n.Kind != .Branch && n.Kind != .While && n.Kind != .For && n.Kind != .ForEach && n.Kind != .DoWhile && n.Kind != .Flow && n.Kind != .Using && n.Kind != .ResultMatch)
					continue;
				if (n.Kind != .DoWhile)
				{
					int k = 0;
					while (k < n.Original.Length && CharUtil.IsIdentChar(n.Original[k]))
						k++;
					if (k < n.Original.Length)
					{
						if (n.Original[k] == '(')
							tight++;
						else if (n.Original[k] == ' ')
							spaced++;
					}
				}
				if (!SplitCompound(n, var sp))
					continue;
				if (sp.BodyOpen >= 0)
				{
					if (StringView(n.Original, sp.HeadEnd, sp.BodyOpen - sp.HeadEnd).Contains('\n'))
						allman++;
					else
						kr++;
				}
				if (sp.ElseStart >= 0)
				{
					if (StringView(n.Original, sp.BodyEnd, sp.ElseStart - sp.BodyEnd).Contains('\n'))
						elseNl++;
					else
						elseSame++;
				}
			}
			if (spaced != tight)
				mKwSpace = spaced > tight;
			if (allman != kr)
				mAllman = allman > kr;
			if (elseNl != elseSame)
				mElseSameLine = elseSame > elseNl;
		}

		void Kw(StringView keyword, String o)
		{
			EnsureStyle();
			o.Append(keyword);
			o.Append(mKwSpace ? " (" : "(");
		}

		static StringView TokText(StringView text, Token tok) => StringView(text, tok.Start, tok.End - tok.Start);

		static int MatchClose(StringView text, List<Token> toks, int open, int count)
		{
			let o = TokText(text, toks[open]);
			StringView c = (o == "(") ? ")" : ((o == "{") ? "}" : "]");
			int depth = 0;
			for (int i = open; i < count; i++)
			{
				if (toks[i].Kind != .Symbol)
					continue;
				let t = TokText(text, toks[i]);
				if (t == o)
					depth++;
				else if (t == c)
				{
					depth--;
					if (depth == 0)
						return i;
				}
			}
			return -1;
		}

		/// Finds the header / body / else positions in a compound statement's original text.
		static bool SplitCompound(Node node, out CompoundSplit sp)
		{
			sp = default;
			sp.HeadEnd = -1;
			sp.BodyOpen = -1;
			sp.BodyEnd = -1;
			sp.ElseStart = -1;
			sp.ElseEnd = -1;
			sp.ElseBodyOpen = -1;
			sp.TailStart = -1;
			let text = node.Original;
			if (text == null)
				return false;
			List<Token> toks = scope .();
			Lexer.Tokenize(text, toks);
			int count = toks.Count;
			while (count > 0 && toks[count - 1].Kind == .EOF)
				count--;
			if (count < 2)
				return false;
			let first = TokText(text, toks[0]);
			if (node.Kind == .DoWhile)
			{
				if ((first != "do" && first != "repeat") || TokText(text, toks[1]) != "{")
					return false;
				sp.HeadEnd = toks[0].End;
				sp.BodyOpen = toks[1].Start;
				let m = MatchClose(text, toks, 1, count);
				if (m < 0)
					return false;
				sp.BodyEnd = toks[m].End;
				sp.TailStart = toks[m].End;
				return true;
			}
			if ((first != "if" && first != "while" && first != "for" && first != "foreach" && first != "using") || TokText(text, toks[1]) != "(")
				return false;
			let k = MatchClose(text, toks, 1, count);
			if (k < 0)
				return false;
			sp.HeadEnd = toks[k].End;
			if (k + 1 < count && TokText(text, toks[k + 1]) == "{")
			{
				sp.BodyOpen = toks[k + 1].Start;
				let m = MatchClose(text, toks, k + 1, count);
				if (m < 0)
					return true;
				sp.BodyEnd = toks[m].End;
				if ((node.Kind == .Branch || node.Kind == .Flow || node.Kind == .ResultMatch) && m + 1 < count && TokText(text, toks[m + 1]) == "else")
				{
					sp.ElseStart = toks[m + 1].Start;
					sp.ElseEnd = toks[m + 1].End;
					if (m + 2 < count && TokText(text, toks[m + 2]) == "{")
						sp.ElseBodyOpen = toks[m + 2].Start;
				}
			}
			return true;
		}

		/// Same tokens in the same order (whitespace and comments may differ).
		public static bool SameTokens(StringView a, StringView b)
		{
			List<Token> ta = scope .();
			List<Token> tb = scope .();
			Lexer.Tokenize(a, ta);
			Lexer.Tokenize(b, tb);
			int ca = ta.Count;
			while (ca > 0 && ta[ca - 1].Kind == .EOF)
				ca--;
			int cb = tb.Count;
			while (cb > 0 && tb[cb - 1].Kind == .EOF)
				cb--;
			if (ca != cb)
				return false;
			for (int i < ca)
			{
				if (ta[i].Kind != tb[i].Kind || TokText(a, ta[i]) != TokText(b, tb[i]))
					return false;
			}
			return true;
		}

		/// Writes a regenerated header, or the original one when it has the same tokens.
		void AppendHeader(Node node, int origEnd, StringView newText, String o)
		{
			if (origEnd > 0 && node.Original != null && origEnd <= node.Original.Length)
			{
				let orig = StringView(node.Original, 0, origEnd);
				if (SameTokens(orig, newText))
				{
					o.Append(orig);
					return;
				}
			}
			o.Append(newText);
		}

		static StringView Slice(Node node, int start, int end)
		{
			return StringView(node.Original, start, end - start);
		}

		// ------------------------------------------------------------------ statements

		static void AppendCommentLines(StringView lines, StringView indent, String o)
		{
			int count = 0;
			for (let line in lines.Split('\n'))
				count++;
			int i = 0;
			for (let line in lines.Split('\n'))
			{
				if (i++ == count - 1)
					break; // text after the final '\n'
				if (line.IsEmpty)
					o.Append('\n');
				else
				{
					o.Append(indent);
					o.Append(line);
					o.Append('\n');
				}
			}
		}

		/// Writes the chain starting at `execOut` until it ends or reaches `stop` (the merge
		/// point that the enclosing statement writes after itself).
		public void GenChain(Pin execOut, StringView indent, String o, Node stop)
		{
			var node = mGraph.ExecTarget(execOut);
			List<Node> pathAdded = scope .();
			while (node != null && node != stop)
			{
				if (mOnPath.Contains(node))
				{
					AddError(node, "Execution loops back into this node. Use a loop node (While, For, For Each) to repeat code.");
					o.AppendF("{}// VisualBeef: execution cycle cut here\n", indent);
					break;
				}
				mOnPath.Add(node);
				pathAdded.Add(node);
				GenStatement(node, indent, o);
				node = Continuation(node);
			}
			for (let n in pathAdded)
				mOnPath.Remove(n);
		}

		static bool IsCompound(Node node)
		{
			switch (node.Kind)
			{
			case .Branch, .While, .DoWhile, .For, .ForEach, .Switch, .Flow, .Defer, .Using, .ResultMatch, .Scope: return true;
			case .LocalFunc: return node.FindOutput("body") != null;
			default: return false;
			}
		}

		void GenStatement(Node node, StringView indent, String o)
		{
			let info = RecordStmt(node);
			let prevStmt = mCurStmt;
			mCurStmt = info;

			List<Node> newTemps = scope .();
			VisitHeader(node, newTemps);
			if (node.Kind == .Defer)
			{
				List<Node> shared = scope .();
				DeferSharedTemps(mGraph, node, mValueTemps, shared);
				for (let t in shared)
					if (!mDeclared.ContainsKey(t))
						VisitValue(t, t.Result, newTemps, false);
			}
			List<Node> hoists = null;
			mHoistAt.TryGetValue(node, out hoists);
			List<Pin> outDecls = null;
			if (!mPlanning)
				mOutDeclAt.TryGetValue(node, out outDecls);
			bool hasPre = !newTemps.IsEmpty || hoists != null || outDecls != null;

			bool inPlace = !node.Moved;
			// Shared values that came from `let __vN = ...;` lines, and out variables from `T a;`
			// lines, keep those lines' trivia.
			bool preFromSource = hasPre && hoists == null && inPlace;
			if (preFromSource)
			{
				for (let t in newTemps)
					if (t.RawLead == null || t.RawTrail == null || !t.RawTrail.EndsWith('\n'))
						preFromSource = false;
				if (outDecls != null)
					for (let p in outDecls)
						if (p.OutDeclRaw == null || !p.OutDeclRaw.EndsWith('\n') || mOutHoisted.Contains(p) || !SameTokens(p.OutDeclRaw, scope $"{OutDeclType(p)} {p.OutName}{(p.Form == .DeclaredRef) ? " = default" : ""};"))
							preFromSource = false;
			}
			if (preFromSource)
			{
				if (outDecls != null)
					for (let p in outDecls)
						o.Append(p.OutDeclRaw);
				for (let t in newTemps)
				{
					o.Append(t.RawLead);
					TempDecl(t, o);
					o.Append(t.RawTrail);
				}
				mNeedNewline = false;
			}

			int leadStart = o.Length;
			// Comments belong to the statement: written after the declarations it needs, so they
			// read back on the statement (a `T a;` line folds into the out pin, its comments too).
			bool commentsAfterPre = hasPre && !preFromSource && !(inPlace && node.RawLead != null) && node.LeadingComments != null;
			if (inPlace && node.RawLead != null)
				o.Append(node.RawLead);
			else
			{
				if (mNeedNewline)
					o.Append('\n');
				if (node.LeadingComments != null && !commentsAfterPre)
					AppendCommentLines(node.LeadingComments, indent, o);
				o.Append(indent);
			}
			mNeedNewline = false;

			if (hasPre && !preFromSource)
			{
				if (hoists != null)
				{
					for (let c in hoists)
					{
						HoistDecl(c, o);
						o.Append('\n');
						o.Append(indent);
					}
				}
				if (outDecls != null)
				{
					for (let p in outDecls)
					{
						OutDecl(p, o);
						o.Append('\n');
						o.Append(indent);
					}
				}
				for (let t in newTemps)
				{
					TempDecl(t, o);
					o.Append('\n');
					o.Append(indent);
				}
				if (commentsAfterPre && o.EndsWith(indent))
				{
					o.RemoveFromEnd(indent.Length);
					AppendCommentLines(node.LeadingComments, indent, o);
					o.Append(indent);
				}
			}

			if (node.Kind == .Flow && node.Text == FlowMacros.Sequence)
			{
				// The marker must sit right in front of the first block.
				if (!StringView(o, leadStart).Contains(FlowMacros.SequenceMarker))
				{
					o.Append(FlowMacros.SequenceMarker);
					o.Append('\n');
					o.Append(indent);
				}
			}

			bool needsTemp = NeedsTempName(node);
			if (!mHoisted.Contains(node) && mGraph.IsClean(node) && (!needsTemp || OriginalDeclaresTemp(node)))
			{
				o.Append(node.Original);
				if (needsTemp)
					RegisterTemp(node, node.Text2);
				RegisterNested(node);
			}
			else
			{
				String text = scope .();
				let prevIndent = scope String(mStmtIndent);
				mStmtIndent.Set(indent);
				// Attributes keep the gap that followed them (`[ConstSkip]` + line break + indent).
				if (node.Attributes != null)
					text.Append(node.Attributes);
				StatementText(node, indent, text);
				mStmtIndent.Set(prevIndent);
				// Only edited statements change: an unchanged statement keeps its exact text.
				if (!IsCompound(node) && node.Original != null && SameTokens(text, node.Original))
					o.Append(node.Original);
				else
					o.Append(text);
			}

			if (inPlace && node.RawTrail != null)
			{
				o.Append(node.RawTrail);
				mNeedNewline = !node.RawTrail.EndsWith('\n');
			}
			else
			{
				if (node.TrailingComment != null)
				{
					o.Append(' ');
					o.Append(node.TrailingComment);
				}
				o.Append('\n');
			}
			mCurStmt = prevStmt;
		}

		/// The type an out variable is declared with.
		static StringView OutDeclType(Pin p) => (p.OutDecl != null && !p.OutDecl.IsEmpty && p.OutDecl != "var" && p.OutDecl != "let") ? (StringView)p.OutDecl : (StringView)p.TypeName;

		/// `T name;` before the statement. `T name = default;` for a `[Pin(Out=true)]` ref, and
		/// when the declaration is hoisted (on a path where the call did not run the value is
		/// `default`, as for a hoisted call result, and Beef wants it assigned).
		void OutDecl(Pin p, String o)
		{
			o.Append(OutDeclType(p));
			o.Append(' ');
			o.Append(p.OutName);
			OutSpell spell = .AsIs;
			mOutSpell.TryGetValue(p, out spell);
			if (p.Form == .DeclaredRef || spell == .Hoisted)
				o.Append(" = default");
			o.Append(';');
		}

		/// The call's value is read by some written node.
		bool ResultRead(Node call)
		{
			let result = call.Result;
			if (result == null)
				return false;
			for (let l in mGraph.Links)
				if (l.From == result && mEmitted.Contains(l.To.Owner))
					return true;
			return false;
		}

		/// `let __vN = <expr>;` for a shared value.
		void TempDecl(Node t, String o)
		{
			if (t.Kind == .Call && t.HasOutArgs && !ResultRead(t))
			{
				// Only its out pins are read: a plain call statement.
				mOnPath.Add(t);
				CallText(t, o);
				mOnPath.Remove(t);
				o.Append(';');
				return;
			}
			o.Append("let ");
			GetTempName(t, o);
			o.Append(" = ");
			if (!t.IsPure)
				CallText(t, o); // impure call outside the flow
			else if (mGraph.IsClean(t))
				o.Append(t.Original);
			else
			{
				mOnPath.Add(t);
				ExprText(t, o);
				mOnPath.Remove(t);
			}
			o.Append(';');
		}

		/// `T name = default;` for a call whose result is read after the block it runs in.
		void HoistDecl(Node call, String o)
		{
			o.Append(call.Result.TypeName);
			o.Append(' ');
			GetTempName(call, o);
			o.Append(" = default;");
		}

		/// An impure call whose value is read by code that is written (links into unconnected
		/// nodes don't count: they produce no code, so a temp would never be read).
		bool NeedsTempName(Node node)
		{
			if (node.Kind != .Call || node.IsPure)
				return false;
			let result = node.Result;
			if (result == null)
				return false;
			for (let l in mGraph.Links)
				if (l.From == result && mEmitted.Contains(l.To.Owner))
					return true;
			return false;
		}

		/// `let`, or `var` for a struct (or text) value that is the Receiver of another call: a `let` local
		/// is read-only, so a `mut` method (FString.ToOwnedString) could not be called on it.
		StringView TempKeyword(Node node)
		{
			let result = node.Result;
			if (result == null)
				return "let";
			let fam = TypeRules.Family(result.TypeName);
			if (fam != .Struct && fam != .Vector && fam != .String)
				return "let";
			for (let l in mGraph.Links)
				if (l.From == result && l.To.Name == "target" && l.To.Owner.Kind == .Call && mEmitted.Contains(l.To.Owner))
					return "var";
			return "let";
		}

		/// A Call parsed from `let <temp> = Call();` keeps that whole statement as its Original.
		static bool OriginalDeclaresTemp(Node node)
		{
			return node.Kind == .Call && !node.Text2.IsEmpty && node.Original != null && node.Original.StartsWith("let ");
		}

		void RegisterTemp(Node node, StringView name)
		{
			if (mTempNames.ContainsKey(node))
				return;
			mTempNames[node] = new String(name);
		}

		bool TempNameTaken(Node node, StringView name, Pin exceptPin = null)
		{
			for (let kv in mTempNames)
				if (kv.key != node && kv.value == name)
					return true;
			if (mGraph.FindLocal(name) != null)
				return true;
			for (let n in mGraph.Nodes)
			{
				if (n == node)
					continue;
				if ((n.Kind == .LocalVar || n.Kind == .ForEach || n.IsCountingLoop) && n.Text == name)
					return true;
				if (n.Kind == .Get && n.Text == name && n.FindInput("target") == null)
					return true;
				// Another call that will declare this name (e.g. a pasted copy) and is written first.
				if (n.Kind == .Call && !n.IsPure && n.Text2 == name && mTempNames.ContainsKey(n))
					return true;
			}
			if (mGraph.Entry != null)
				for (let p in mGraph.Entry.Outputs)
					if (p.Kind == .Data && p.Label == name)
						return true;
			// Out variables (`out a`, `T a;`).
			for (let n in mGraph.Nodes)
				if (n.Kind == .Call)
					for (let p in n.Outputs)
						if (p != exceptPin && p.IsOutArg && p.OutName == name)
							return true;
			return false;
		}

		/// The temp variable a call result or shared value is stored in. The name is remembered
		/// on the node (Text2) so it stays the same across regenerations and round trips.
		void GetTempName(Node node, String outName)
		{
			if (mTempNames.TryGetValue(node, let name))
			{
				outName.Append(name);
				return;
			}
			if (!node.Text2.IsEmpty && (!node.IsPure || node.Text2.StartsWith("__v")) && !TempNameTaken(node, node.Text2))
			{
				RegisterTemp(node, node.Text2);
				outName.Append(node.Text2);
				return;
			}
			if (node.IsPure)
			{
				String v = scope .();
				for (int i = 1; ; i++)
				{
					v.Clear();
					v.AppendF("__v{}", i);
					if (!TempNameTaken(node, v))
						break;
				}
				node.Text2.Set(v);
				RegisterTemp(node, v);
				outName.Append(v);
				return;
			}
			String baseName = scope .();
			for (let c in node.Text.RawChars)
			{
				if (CharUtil.IsIdentChar(c))
					baseName.Append(c);
				else
					break;
			}
			if (baseName.IsEmpty || !CharUtil.IsIdentStart(baseName[0]))
				baseName.Set("value");
			baseName[0] = baseName[0].ToLower;
			baseName.Append("Result");
			String n = scope .(baseName);
			for (int suffix = 2; TempNameTaken(node, n); suffix++)
			{
				n.Set(baseName);
				n.AppendF("{}", suffix);
			}
			node.Text2.Set(n);
			RegisterTemp(node, n);
			outName.Append(n);
		}

		void Block(Pin execOut, StringView indent, String o, Node stop, StringView openGap, StringView firstLine = default)
		{
			EnsureStyle();
			if (openGap.Ptr != null)
			{
				o.Append(openGap);
				o.Append("{\n");
			}
			else if (mAllman)
			{
				o.Append('\n');
				o.Append(indent);
				o.Append("{\n");
			}
			else
				o.Append(" {\n");
			mNeedNewline = false;
			String inner = scope .(indent);
			inner.Append(mUnit);
			let owner = mCurStmt;
			PushScope(owner);
			mScope.Arm = execOut;
			if (firstLine.Ptr != null)
			{
				// A macro's own bookkeeping line (`__doOnce_1 = true;`) opens the block.
				o.Append(inner);
				o.Append(firstLine);
				o.Append('\n');
			}
			GenChain(execOut, inner, o, stop);
			PopScope();
			mCurStmt = owner;
			if (mNeedNewline)
				o.Append('\n');
			if (execOut.EndComments != null)
				AppendCommentLines(execOut.EndComments, inner, o);
			mNeedNewline = false;
			o.Append(indent);
			o.Append('}');
		}

		bool ChainEmpty(Pin execOut, Node stop)
		{
			let t = mGraph.ExecTarget(execOut);
			return t == null || t == stop;
		}

		void StatementText(Node node, StringView indent, String o)
		{
			switch (node.Kind)
			{
			case .Entry:
			case .Call:
				if (mHoisted.Contains(node))
				{
					GetTempName(node, o);
					o.Append(" = ");
				}
				else if (NeedsTempName(node))
				{
					o.Append(TempKeyword(node));
					o.Append(' ');
					GetTempName(node, o);
					o.Append(" = ");
				}
				else if (node.Kind == .Call)
					node.Text2.Clear(); // result no longer used: no temp
				CallText(node, o);
				o.Append(';');

			case .Set:
				let target = node.FindInput("target");
				if (node.Text == "++" || node.Text == "--")
				{
					if (node.Postfix)
					{
						GenInput(target, Parser.PostfixPrecedence, o);
						o.Append(node.Text);
					}
					else
					{
						o.Append(node.Text);
						GenInput(target, Parser.PostfixPrecedence, o);
					}
				}
				else
				{
					GenInput(target, Parser.PostfixPrecedence, o);
					o.Append(' ');
					o.Append(node.Text);
					o.Append(' ');
					GenInput(node.FindInput("value"), 0, o);
				}
				o.Append(';');

			case .LocalVar:
				if (node.Alloc != null && !node.Alloc.IsEmpty)
				{
					o.Append(node.Alloc); // `const` / `ref`
					o.Append(' ');
				}
				o.Append(node.Text2.IsEmpty ? "var" : node.Text2);
				o.Append(' ');
				o.Append(node.Text);
				let value = node.FindInput("value");
				if (value != null && (mGraph.FindLinkTo(value) != null || !value.Default.IsEmpty))
				{
					o.Append(" = ");
					GenInput(value, 0, o);
				}
				o.Append(';');

			case .Branch:
				String head = scope .();
				Kw("if", head);
				GenInput(node.FindInput("condition"), 0, head);
				head.Append(')');
				IfElse(node, head, node.FindOutput("true"), node.FindOutput("false"), default, default, true, indent, o);

			case .Switch:
				SwitchText(node, indent, o);

			case .Flow:
				FlowText(node, indent, o);

			case .While:
				bool split = SplitCompound(node, var sp);
				String head = scope .();
				Kw("while", head);
				GenInput(node.FindInput("condition"), 0, head);
				head.Append(')');
				AppendHeader(node, split ? sp.HeadEnd : -1, head, o);
				Block(node.FindOutput("body"), indent, o, null, (split && sp.BodyOpen >= 0) ? Slice(node, sp.HeadEnd, sp.BodyOpen) : default);

			case .DoWhile:
				bool split = SplitCompound(node, var sp);
				o.Append((node.Alloc != null && !node.Alloc.IsEmpty) ? (StringView)node.Alloc : "do");
				Block(node.FindOutput("body"), indent, o, null, (split && sp.BodyOpen >= 0) ? Slice(node, sp.HeadEnd, sp.BodyOpen) : default);
				String tail = scope .();
				if (mAllman)
				{
					tail.Append('\n');
					tail.Append(indent);
				}
				else
					tail.Append(' ');
				Kw("while", tail);
				GenInput(node.FindInput("condition"), 0, tail);
				tail.Append(");");
				if (split && sp.TailStart >= 0 && SameTokens(StringView(node.Original, sp.TailStart), tail))
					o.Append(StringView(node.Original, sp.TailStart));
				else
					o.Append(tail);

			case .For:
				bool split = SplitCompound(node, var sp);
				String head = scope .();
				Kw("for", head);
				if (node.IsCountingLoop)
				{
					// `T i = start; i < count; i++`, or Beef's `T i < count` when there is no Start.
					head.Append(node.Text2.IsEmpty ? "int" : node.Text2);
					head.Append(' ');
					head.Append(node.Text);
					let first = node.FindInput("start");
					if (first != null)
					{
						head.Append(" = ");
						GenInput(first, 0, head);
						head.Append("; ");
						head.Append(node.Text);
					}
					head.Append(" < ");
					GenInput(node.FindInput("count"), 0, head);
					if (first != null)
					{
						head.Append("; ");
						head.Append(node.Text);
						head.Append("++");
					}
				}
				else
					head.Append(node.Text);
				head.Append(')');
				AppendHeader(node, split ? sp.HeadEnd : -1, head, o);
				Block(node.FindOutput("body"), indent, o, null, (split && sp.BodyOpen >= 0) ? Slice(node, sp.HeadEnd, sp.BodyOpen) : default);

			case .ForEach:
				bool split = SplitCompound(node, var sp);
				String head = scope .();
				Kw("for", head);
				head.Append(node.Text2.IsEmpty ? "let" : node.Text2);
				head.Append(' ');
				head.Append(node.Text);
				head.Append(" in ");
				GenInput(node.FindInput("collection"), 0, head);
				head.Append(')');
				AppendHeader(node, split ? sp.HeadEnd : -1, head, o);
				Block(node.FindOutput("body"), indent, o, null, (split && sp.BodyOpen >= 0) ? Slice(node, sp.HeadEnd, sp.BodyOpen) : default);

			case .Return:
				// Outputs: `name = value;` for each out parameter pin with a value, then the return.
				for (let p in node.Inputs)
				{
					if (p.Kind != .Data || !p.Name.StartsWith("out:") || (mGraph.FindLinkTo(p) == null && p.Default.IsEmpty))
						continue;
					o.Append(StringView(p.Name, 4));
					o.Append(" = ");
					GenInput(p, 0, o);
					o.Append(";\n");
					o.Append(indent);
				}
				o.Append("return");
				let value = node.FindInput("value");
				if (value != null && (mGraph.FindLinkTo(value) != null || !value.Default.IsEmpty))
				{
					o.Append(' ');
					GenInput(value, 0, o);
				}
				o.Append(';');

			case .Break:
				// In Beef a `break` inside a switch case leaves the switch, not the loop around it.
				if (mPlanning)
				{
					bool sawSwitch = false;
					for (var s = mScope; s != null; s = s.Parent)
					{
						if (s.Owner == null)
							continue;
						let k = s.Owner.Node.Kind;
						bool loop = k == .While || k == .DoWhile || k == .For || k == .ForEach;
						if (!sawSwitch)
						{
							if (k == .Switch)
								sawSwitch = true;
							else if (loop)
								break;
						}
						else if (loop)
						{
							Warn("'Break' inside a switch case only leaves the switch, not the loop around it (Beef's rule).");
							break;
						}
					}
				}
				o.Append("break;");
			case .Continue:
				o.Append("continue;");
			case .Code:
				o.Append(node.Text);

			case .Delete:
				o.Append((node.Alloc != null && !node.Alloc.IsEmpty) ? (StringView)node.Alloc : "delete");
				o.Append(' ');
				GenInput(node.FindInput("value"), Parser.UnaryPrecedence, o);
				o.Append(';');

			case .Defer:
				DeferText(node, indent, o);

			case .Using:
				UsingText(node, indent, o);

			case .ResultMatch:
				ResultMatchText(node, indent, o);

			case .Scope:
				// A nested block: `{` where the statement starts, the body, `}`.
				Block(node.FindOutput("body"), indent, o, null, StringView(""));

			case .LocalFunc:
				o.Append(node.Text2);
				let body = node.FindOutput("body");
				if (body != null)
					Block(body, indent, o, null, default);
				else
				{
					o.Append(" => ");
					GenInput(node.FindInput("expr"), 0, o);
					o.Append(';');
				}

			default:
				// Pure nodes are never statements
				AddError(node, "This node cannot be a statement.");
				o.Append("/* unexpected node */;");
			}
		}

		// ------------------------------------------------------------------ if / else

		/// `if (...) { true arm } else { false arm }` for a Branch and for the macros written as an
		/// if. `tFirst` / `fFirst` are bookkeeping lines (`__doOnce_1 = true;`) that open an arm;
		/// `f` is null for macros without an else.
		void IfElse(Node node, String head, Pin t, Pin f, StringView tFirst, StringView fFirst, bool allowElseIf, StringView indent, String o)
		{
			bool split = SplitCompound(node, var sp);
			AppendHeader(node, split ? sp.HeadEnd : -1, head, o);
			let stop = Continuation(node);
			Block(t, indent, o, stop, (split && sp.BodyOpen >= 0) ? Slice(node, sp.HeadEnd, sp.BodyOpen) : default, tFirst);
			if (f == null)
				return;
			if (fFirst.Ptr == null && ChainEmpty(f, stop) && f.EndComments == null)
				return;
			if (split && sp.ElseStart >= 0)
				o.Append(Slice(node, sp.BodyEnd, sp.ElseStart));
			else if (mElseSameLine && !mAllman)
				o.Append(' ');
			else
			{
				o.Append('\n');
				o.Append(indent);
			}
			o.Append("else");
			// `else if` chains: a lone Branch in the false path
			let first = mGraph.ExecTarget(f);
			bool firstIf = first != null && (first.Kind == .Branch || first.Kind == .ResultMatch);
			Node firstNext = firstIf ? Continuation(first) : null;
			if (allowElseIf && fFirst.Ptr == null && first != null && first != stop && firstIf && (firstNext == null || firstNext == stop) &&
				first.LeadingComments == null && f.EndComments == null && first.TrailingComment == null && !mOnPath.Contains(first) &&
				!mStmts.ContainsKey(first) && !mHoistAt.ContainsKey(first) && !HeaderHasNewTemps(first))
			{
				o.Append(' ');
				let owner = mCurStmt;
				PushScope(owner);
				let fi = RecordStmt(first);
				mCurStmt = fi;
				List<Node> none = scope .();
				VisitHeader(first, none);
				mOnPath.Add(first);
				if (mGraph.IsClean(first))
				{
					o.Append(first.Original);
					RegisterNested(first);
				}
				else
					StatementText(first, indent, o);
				mOnPath.Remove(first);
				mCurStmt = owner;
				PopScope();
			}
			else
				Block(f, indent, o, stop, (split && sp.ElseBodyOpen >= 0) ? Slice(node, sp.ElseEnd, sp.ElseBodyOpen) : default, fFirst);
		}

		// ------------------------------------------------------------------ lifetime nodes
		// Construct, Delete, Defer, Using and Result (docs/Lifetime-Nodes.md).

		/// Planning pass: the statements reading each plain name (Get nodes without a Target),
		/// by the name's root (`a` for `a.b`). Variables read from code are Get nodes, not wires.
		Dictionary<String, List<StmtInfo>> mNameUses = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

		void RecordNameUse(Node get)
		{
			if (!mPlanning || mCurStmt == null || get.FindInput("target") != null)
				return;
			StringView root = get.Text;
			int dot = root.IndexOf('.');
			if (dot >= 0)
				root = root.Substring(0, dot);
			root.Trim();
			if (root.IsEmpty)
				return;
			List<StmtInfo> list;
			if (mNameUses.TryGetAlt(root, var key, out list))
			{
				list.Add(mCurStmt);
				return;
			}
			list = new .();
			list.Add(mCurStmt);
			mNameUses[new String(root)] = list;
		}

		/// `new T(args)` / `scope .(args)` / `new:alloc T[n]`.
		void ConstructText(Node node, String o)
		{
			// An empty allocation is `.(args)` / `T(args)`: a value made in place.
			if (node.Alloc == null || !node.Alloc.IsEmpty)
			{
				o.Append((node.Alloc != null) ? (StringView)node.Alloc : "new");
				o.Append(' ');
			}
			if (node.Text == "$")
			{
				// `scope $"..."` while the Text input holds a string literal; `scope String(x)` otherwise.
				let text = node.FindInput("arg0");
				if (text != null && mGraph.FindLinkTo(text) == null &&
					(text.Default.StartsWith('$') || text.Default.StartsWith("@$")))
				{
					o.Append(text.Default);
					return;
				}
				let src = (text != null) ? mGraph.DataSource(text) : null;
				if (src != null && src.Kind == .Format && !mValueTemps.Contains(src))
				{
					// `scope $"x = {x}"` with the holes as wires.
					GenInput(text, 0, o);
					return;
				}
				o.Append("String(");
				GenInput(text, 0, o);
				o.Append(')');
				return;
			}
			o.Append(node.Text.IsEmpty ? "." : (StringView)node.Text);
			o.Append(node.IsArray ? '[' : '(');
			List<Pin> args = scope .();
			node.GetArgPins(args);
			bool first = true;
			for (let p in args)
			{
				if (!first)
					o.Append(", ");
				first = false;
				ArgText(p, o);
			}
			o.Append(node.IsArray ? ']' : ')');
		}

		/// `alloc [captures] (params) => expr`, `... => { body }`, `alloc => Method`.
		void LambdaText(Node node, String o)
		{
			if (node.Alloc != null && !node.Alloc.IsEmpty)
			{
				o.Append(node.Alloc);
				o.Append(' ');
			}
			if (node.Attributes != null && !node.Attributes.IsEmpty)
			{
				o.Append(node.Attributes);
				o.Append(' ');
			}
			if (node.Text.IsEmpty && !node.Text2.IsEmpty)
			{
				o.Append("=> ");
				o.Append(node.Text2);
				return;
			}
			o.Append(node.Text.IsEmpty ? "()" : (StringView)node.Text);
			o.Append(" =>");
			let body = node.FindOutput("body");
			if (body != null)
			{
				// The block is indented from the statement the lambda is written in.
				String indent = scope .(mStmtIndent);
				Block(body, indent, o, null, default);
				return;
			}
			o.Append(' ');
			GenInput(node.FindInput("expr"), 0, o);
		}

		/// Splits an interpolated string literal into its text and holes. outHoles gets, for
		/// each `{...}` hole, the offsets of the expression and of the whole hole (from `{` to
		/// `}` inclusive); `{{` / `}}` are text. False for forms that are kept as text (raw
		/// strings, a hole that does not close).
		public static bool SplitInterpolated(StringView lit, List<(int exprStart, int exprEnd, int holeStart, int holeEnd)> outHoles)
		{
			int i = 0;
			bool verbatim = false;
			while (i < lit.Length && (lit[i] == '$' || lit[i] == '@'))
			{
				if (lit[i] == '@')
					verbatim = true;
				i++;
			}
			if (i >= lit.Length || lit[i] != '"' || lit.StartsWith("$\"\"\"") || lit.Length < i + 2 || lit[lit.Length - 1] != '"')
				return false;
			if (i + 2 < lit.Length && lit[i + 1] == '"' && lit[i + 2] == '"')
				return false; // raw string
			int end = lit.Length - 1;
			i++;
			while (i < end)
			{
				let c = lit[i];
				if (!verbatim && c == '\\')
				{
					i += 2;
					continue;
				}
				if (verbatim && c == '"' && i + 1 < end && lit[i + 1] == '"')
				{
					i += 2;
					continue;
				}
				if (c == '{' && i + 1 < end && lit[i + 1] == '{')
				{
					i += 2;
					continue;
				}
				if (c == '}' && i + 1 < end && lit[i + 1] == '}')
				{
					i += 2;
					continue;
				}
				if (c != '{')
				{
					i++;
					continue;
				}
				// A hole: the expression runs to a ':' / ',' / '}' at depth 0 outside strings.
				int holeStart = i;
				int j = i + 1;
				int depth = 0;
				int exprEnd = -1;
				char8 quote = 0;
				while (j < end)
				{
					let d = lit[j];
					if (quote != 0)
					{
						if (d == '\\')
						{
							j += 2;
							continue;
						}
						if (d == quote)
							quote = 0;
						j++;
						continue;
					}
					if (d == '"' || d == '\'')
					{
						if (verbatim)
							return false;
						quote = d;
					}
					else if (d == '(' || d == '[' || d == '{')
						depth++;
					else if ((d == ')' || d == ']') && depth > 0)
						depth--;
					else if (d == '}')
					{
						if (depth == 0)
							break;
						depth--;
					}
					else if (depth == 0 && exprEnd < 0 && (d == ',' || (d == ':' && !(j + 1 < end && lit[j + 1] == ':') && !(j > 0 && lit[j - 1] == ':'))))
						exprEnd = j;
					j++;
				}
				if (j >= end)
					return false;
				if (exprEnd < 0)
					exprEnd = j;
				var exprText = StringView(lit, holeStart + 1, exprEnd - holeStart - 1);
				exprText.Trim();
				if (exprText.IsEmpty)
					return false;
				outHoles.Add((holeStart + 1, exprEnd, holeStart, j + 1));
				i = j + 1;
			}
			return true;
		}

		/// `$"text {a} more {b:X2}"`: Node.Text is the literal with each hole's expression taken
		/// out (`$"text {} more {:X2}"`), the holes are the `arg<i>` inputs.
		/// A Math Expression: the expression as typed, every pin name replaced by the pin's value
		/// (in parentheses unless it is a name, a literal, a call or a member read).
		void MathText(Node node, String o)
		{
			let p = MathExpression.Parse(node.Text);
			defer delete p;
			if (!p.IsValid)
			{
				AddError(node, p.Error);
				o.Append("/* ? */");
				return;
			}
			MathExpression.Substitute(p, scope [&] (pin, outValue) =>
				{
					let input = node.FindInput(pin);
					if (input == null)
					{
						AddError(node, scope $"'{pin}' has no input pin: edit the expression again to make it.");
						outValue.Append("/* ? */");
						return;
					}
					GenInput(input, Parser.PostfixPrecedence, outValue);
				}, o);
		}

		void FormatText(Node node, String o)
		{
			let text = node.Text;
			List<(int exprStart, int exprEnd, int holeStart, int holeEnd)> holes = scope .();
			if (!SplitInterpolatedTemplate(text, holes))
			{
				AddError(node, "The interpolated string cannot be read.");
				o.Append(text);
				return;
			}
			int pos = 0;
			for (let h in holes)
			{
				o.Append(StringView(text, pos, h.exprStart - pos));
				String expr = scope .();
				GenInput(node.FindInput(scope $"arg{@h.Index}"), 0, expr);
				// A ':' / ',' / '?' at the top level would end the hole early: parenthesise.
				if (!CodeGen.IsAtomic(expr) && (expr.Contains(':') || expr.Contains(',') || expr.Contains('?')))
					o.AppendF("({})", expr);
				else
					o.Append(expr);
				pos = h.exprEnd;
			}
			o.Append(StringView(text, pos));
		}

		/// The holes of a Format node's template (`{}` / `{:X2}` / `{,5}`): exprStart == exprEnd
		/// is where the expression goes.
		public static bool SplitInterpolatedTemplate(StringView text, List<(int exprStart, int exprEnd, int holeStart, int holeEnd)> outHoles)
		{
			int i = 0;
			while (i < text.Length && (text[i] == '$' || text[i] == '@'))
				i++;
			bool verbatim = StringView(text, 0, i).Contains('@');
			if (i >= text.Length || text[i] != '"' || text.Length < i + 2)
				return false;
			int end = text.Length - 1;
			i++;
			while (i < end)
			{
				let c = text[i];
				if (!verbatim && c == '\\')
				{
					i += 2;
					continue;
				}
				if (verbatim && c == '"' && i + 1 < end && text[i + 1] == '"')
				{
					i += 2;
					continue;
				}
				if ((c == '{' || c == '}') && i + 1 < end && text[i + 1] == c)
				{
					i += 2;
					continue;
				}
				if (c == '{')
				{
					int j = text.IndexOf('}', i);
					if (j < 0)
						return false;
					outHoles.Add((i + 1, i + 1, i, j + 1));
					i = j + 1;
					continue;
				}
				i++;
			}
			return true;
		}

		/// The keyword(s) a Defer starts with, and where its body starts in the original text
		/// (-1 when it had no braces, or there is no original).
		static void SplitDefer(Node node, out int kwEnd, out int braceOpen, out int bodyStart)
		{
			kwEnd = -1;
			braceOpen = -1;
			bodyStart = -1;
			let text = node.Original;
			if (text == null)
				return;
			List<Token> toks = scope .();
			Lexer.Tokenize(text, toks);
			int i = 0;
			if (toks.Count < 2 || TokText(text, toks[0]) != "defer")
				return;
			i = 1;
			if (TokText(text, toks[i]) == "::")
				i++;
			else if (TokText(text, toks[i]) == ":" && i + 1 < toks.Count && toks[i + 1].Kind == .Identifier)
				i += 2;
			if (i >= toks.Count)
				return;
			kwEnd = toks[i - 1].End;
			bodyStart = toks[i].Start;
			if (TokText(text, toks[i]) == "{")
				braceOpen = toks[i].Start;
		}

		/// `defer <statement>` for one plain statement (written on the same line), `defer { ... }`
		/// otherwise, or when the code had braces.
		void DeferText(Node node, StringView indent, String o)
		{
			let body = node.FindOutput("body");
			o.Append((node.Alloc != null && !node.Alloc.IsEmpty) ? (StringView)node.Alloc : "defer");
			SplitDefer(node, let kwEnd, let braceOpen, let bodyStart);
			let first = mGraph.ExecTarget(body);
			bool oneLine = first != null && braceOpen < 0 && !IsCompound(first) && first.Kind != .Code && Continuation(first) == null &&
				body.EndComments == null && first.LeadingComments == null &&
				(first.TrailingComment == null || first.TrailingComment == node.TrailingComment) &&
				!mOnPath.Contains(first) && !mStmts.ContainsKey(first) && !mHoistAt.ContainsKey(first) && !mOutDeclAt.ContainsKey(first) &&
				!HeaderHasNewTemps(first) && !mHoisted.Contains(first);
			if (first != null && first.Kind == .Code && braceOpen < 0 && Continuation(first) == null && !first.Text.Contains('\n') &&
				first.LeadingComments == null && !mStmts.ContainsKey(first) && !mOnPath.Contains(first))
				oneLine = true; // `defer x.Dispose();` read as raw code stays on its line
			if (!oneLine)
			{
				StringView gap = default;
				if (braceOpen >= 0 && kwEnd >= 0)
					gap = StringView(node.Original, kwEnd, braceOpen - kwEnd);
				Block(body, indent, o, null, gap);
				return;
			}
			// The space between `defer` and the statement, as written.
			StringView gap = " ";
			if (kwEnd >= 0 && bodyStart > kwEnd && !first.Moved)
			{
				let g = StringView(node.Original, kwEnd, bodyStart - kwEnd);
				if (!g.IsEmpty && !g.Contains('\n'))
					gap = g;
			}
			o.Append(gap);
			let owner = mCurStmt;
			PushScope(owner);
			mScope.Arm = body;
			let fi = RecordStmt(first);
			mCurStmt = fi;
			List<Node> none = scope .();
			VisitHeader(first, none);
			mOnPath.Add(first);
			if (mGraph.IsClean(first) && !NeedsTempName(first))
			{
				o.Append(first.Original);
				RegisterNested(first);
			}
			else
			{
				String text = scope .();
				StatementText(first, indent, text);
				if (first.Original != null && SameTokens(text, first.Original))
					o.Append(first.Original);
				else
					o.Append(text);
			}
			mOnPath.Remove(first);
			mCurStmt = owner;
			PopScope();
		}

		/// `using (value)` / `using (let x = value)` with its body.
		void UsingText(Node node, StringView indent, String o)
		{
			bool split = SplitCompound(node, var sp);
			String head = scope .();
			Kw("using", head);
			if (node.FindOutput("variable") != null && !node.Text.IsEmpty)
			{
				head.Append(node.Text2.IsEmpty ? "let" : node.Text2);
				head.Append(' ');
				head.Append(node.Text);
				head.Append(" = ");
			}
			GenInput(node.FindInput("value"), 0, head);
			head.Append(')');
			AppendHeader(node, split ? sp.HeadEnd : -1, head, o);
			Block(node.FindOutput("body"), indent, o, null, (split && sp.BodyOpen >= 0) ? Slice(node, sp.HeadEnd, sp.BodyOpen) : default);
		}

		/// The payload pin of a Result node is read by a written node.
		bool PayloadRead(Pin payload)
		{
			for (let l in mGraph.Links)
				if (l.From == payload && mEmitted.Contains(l.To.Owner))
					return true;
			return false;
		}

		/// `if (value case .Ok(let v)) { Ok } else { Err }` (`.Err` first when Text is Err). The
		/// binding is written when the payload is read, or when the code had one.
		void ResultMatchText(Node node, StringView indent, String o)
		{
			bool okTest = node.Text != "Err";
			let payload = node.FindOutput("payload");
			String head = scope .();
			Kw("if", head);
			GenInput(node.FindInput("value"), Parser.PostfixPrecedence, head);
			head.Append(okTest ? " case .Ok" : " case .Err");
			if (payload != null)
			{
				bool read = PayloadRead(payload);
				bool keep = payload.Form == .Inline && !payload.OutAuto && payload.OutName != null && !payload.OutName.IsEmpty;
				if (read || keep)
				{
					if (payload.OutName == null || payload.OutName.IsEmpty)
					{
						String name = scope .();
						NodeFactory.FreshOutName(mGraph, okTest ? "value" : "error", payload, name);
						String baseName = scope .(name);
						for (int suffix = 2; OutNameTaken(payload, name); suffix++)
						{
							name.Set(baseName);
							name.AppendF("{}", suffix);
						}
						Graph.CopyStr(ref payload.OutName, name);
						node.Edited = true;
					}
					head.AppendF("({} {})", (payload.OutDecl == "var") ? "var" : "let", payload.OutName);
					if (!mPlanning)
					{
						payload.Form = .Inline;
						if (payload.OutDecl == null)
							payload.OutDecl = new String("let");
					}
				}
				else if (!mPlanning)
					payload.Form = .Discard;
			}
			head.Append(')');
			let ok = node.FindOutput("ok");
			let err = node.FindOutput("err");
			IfElse(node, head, okTest ? ok : err, okTest ? err : ok, default, default, true, indent, o);
		}

		/// The Defer statement whose deferred body holds `s` (innermost), or null.
		static StmtInfo DeferOf(StmtInfo s)
		{
			for (var sc = s.Scope; sc != null; sc = sc.Parent)
				if (sc.Owner != null && sc.Owner.Node.Kind == .Defer)
					return sc.Owner;
			return null;
		}

		/// `s` is inside the body of `owner` (any arm, any depth).
		static bool InBodyOf(StmtInfo s, StmtInfo owner)
		{
			for (var sc = s.Scope; sc != null; sc = sc.Parent)
				if (sc.Owner == owner)
					return true;
			return false;
		}

		/// A Construct written with `scope` (any form).
		static bool IsScopeAlloc(Node n) => n != null && n.Kind == .Construct && n.Alloc != null && n.Alloc.StartsWith("scope");

		/// After the planning pass: the lifetime rules that need to know which block each statement
		/// is written in (docs/Lifetime-Nodes.md). The graph-only ones are in GraphValidator.
		void AnalyzeLifetimes()
		{
			// Result: the bound value exists in the tested arm only.
			for (let kv in mOutUses)
			{
				let p = kv.key;
				let n = p.Owner;
				if (n.Kind != .ResultMatch)
					continue;
				if (!mStmts.TryGetValue(n, let home))
					continue;
				let tested = n.FindOutput((n.Text == "Err") ? "err" : "ok");
				for (let u in kv.value)
				{
					bool inArm = false;
					for (var sc = u.Scope; sc != null; sc = sc.Parent)
						if (sc.Owner == home && sc.Arm == tested)
							inArm = true;
					if (inArm)
						continue;
					AddError(u.Node, scope $"Reads the {(n.Text == "Err") ? "Err" : "Ok"} value of a Result match outside its {n.Text} arm, where it does not exist.");
					AddError(n, scope $"The {(n.Text == "Err") ? "error" : "value"} of this match is only set in its {n.Text} arm; wire it only into nodes there.");
				}
			}

			// A deferred body runs when its block ends: what it computes can't be read after it.
			for (let kv in mUses)
			{
				if (!mStmts.TryGetValue(kv.key, let pinfo))
					continue;
				let d = DeferOf(pinfo);
				if (d == null)
					continue;
				for (let u in kv.value)
				{
					if (InBodyOf(u, d))
						continue;
					String title = scope .();
					kv.key.GetTitle(title);
					AddError(u.Node, scope $"Reads '{title}', which runs inside a Defer body: that code runs only when the block ends.");
					AddError(kv.key, scope $"'{title}' runs inside a Defer body (at the end of the block), so its value can't be read outside the body.");
				}
			}
			for (let kv in mOutUses)
			{
				let call = kv.key.Owner;
				if (call.Kind != .Call)
					continue;
				let home = OutHomeOf(call);
				if (home == null)
					continue;
				let d = DeferOf(home);
				if (d == null)
					continue;
				for (let u in kv.value)
					if (!InBodyOf(u, d) && u != home)
						AddError(u.Node, scope $"Reads the out value '{kv.key.Label}' of a call inside a Defer body: that code runs only when the block ends.");
			}

			// Leaving a deferred body: return anywhere in it, break / continue outside its loops.
			for (let kv in mStmts)
			{
				let s = kv.value;
				let k = s.Node.Kind;
				if (k != .Return && k != .Break && k != .Continue)
					continue;
				for (var sc = s.Scope; sc != null; sc = sc.Parent)
				{
					if (sc.Owner == null)
						break;
					let ok = sc.Owner.Node.Kind;
					if (k != .Return && (ok == .While || ok == .DoWhile || ok == .For || ok == .ForEach || (k == .Break && ok == .Switch)))
						break;
					if (ok == .Defer)
					{
						AddError(s.Node, (k == .Return) ? "A deferred body can't return: it runs while the block is being left." :
							"This Break / Continue would leave a Defer body, which Beef does not allow.");
						break;
					}
				}
			}

			// `scope` values: freed when the block that allocated them ends.
			for (let n in mGraph.Nodes)
			{
				if (!mStmts.TryGetValue(n, let s))
					continue;
				if (n.Kind == .Return)
				{
					let v = n.FindInput("value");
					let link = (v != null) ? mGraph.FindLinkTo(v) : null;
					if (link == null)
						continue;
					let src = link.From.Owner;
					Node alloc = IsScopeAlloc(src) ? src : null;
					if (alloc == null && (src.Kind == .Get || src.Kind == .LocalVar) && !link.From.IsOutArg)
						alloc = ScopeLocal(src.Kind == .Get ? (StringView)src.Text : (StringView)src.Text);
					if (alloc == null)
						continue;
					LifetimeIssue(n, alloc, link.Parsed, "Returns a value allocated with `scope`: it is freed when the method returns. Allocate it with `new` (and let the caller delete it), or return a copy.");
					continue;
				}
				if (n.Kind != .Set || n.Text != "=")
					continue;
				let value = n.FindInput("value");
				let vlink = (value != null) ? mGraph.FindLinkTo(value) : null;
				if (vlink == null || !IsScopeAlloc(vlink.From.Owner))
					continue;
				let alloc = vlink.From.Owner;
				if (alloc.Alloc == "scope::" || alloc.Alloc.Contains(':') && !alloc.Alloc.EndsWith("::"))
					continue; // `scope::` lives until the method returns; `scope:label` until that block ends
				let target = n.FindInput("target");
				String name = scope .();
				if (target != null && mGraph.FindLinkTo(target) == null)
					name.Set(target.Default);
				else if (target != null)
				{
					let ts = mGraph.DataSource(target);
					if (ts != null && (ts.Kind == .Get || ts.Kind == .LocalVar) && ts.FindInput("target") == null)
						name.Set(ts.Text);
				}
				name.Trim();
				if (name.StartsWith("this."))
					name.Remove(0, 5);
				int dot = name.IndexOf('.');
				if (dot >= 0)
					name.RemoveToEnd(dot);
				if (name.IsEmpty || s.Scope.Depth == 0)
					continue;
				if (!IsLocalName(name))
				{
					// A field (or anything that outlives the method).
					mGraph.AddWarning(n, scope $"Stores a value allocated with `scope` in '{name}', which outlives this block: the object is freed when the block ends.");
					continue;
				}
				bool bad = false;
				if (mNameUses.TryGetValue(name, let uses))
				{
					for (let u in uses)
					{
						if (u.Seq <= s.Seq || IsWithin(u.Scope, s.Scope))
							continue;
						bad = true;
						LifetimeIssue(u.Node, alloc, vlink.Parsed && n.Original != null, scope $"Reads '{name}' after the block that allocated its value with `scope` has ended: the object is already freed.");
					}
				}
				for (let kvu in mUses)
				{
					if (kvu.key.Kind != .LocalVar || kvu.key.Text != name)
						continue;
					for (let u in kvu.value)
					{
						if (u.Seq <= s.Seq || IsWithin(u.Scope, s.Scope))
							continue;
						bad = true;
						LifetimeIssue(u.Node, alloc, false, scope $"Reads '{name}' after the block that allocated its value with `scope` has ended: the object is already freed.");
					}
				}
				if (bad)
					LifetimeIssue(alloc, alloc, vlink.Parsed && n.Original != null, "This value was allocated with `scope` in a block that has ended. Allocate it with `scope::` to keep it until the method returns.");
			}

			// Defers run last-first: a later Defer that deletes x runs before an earlier one reading x.
			List<StmtInfo> defers = scope .();
			for (let kv in mStmts)
				if (kv.key.Kind == .Defer)
					defers.Add(kv.value);
			for (let a in defers)
			{
				for (let b in defers)
				{
					if (b.Scope != a.Scope || b.Seq <= a.Seq)
						continue;
					// Names b's body deletes.
					for (let kv in mStmts)
					{
						let del = kv.key;
						if (del.Kind != .Delete || !InBodyOf(kv.value, b))
							continue;
						let src = mGraph.DataSource(del.FindInput("value"));
						if (src == null || (src.Kind != .Get && src.Kind != .LocalVar) || src.FindInput("target") != null)
							continue;
						if (!mNameUses.TryGetValue(src.Text, let uses))
							continue;
						for (let u in uses)
						{
							if (!InBodyOf(u, a))
								continue;
							mGraph.AddWarning(a.Node, scope $"Deferred code runs last-first: the Defer on line {b.Node.Line} deletes '{src.Text}' before this one reads it.");
							break;
						}
					}
				}
			}
		}

		/// A local of this method (a Local Variable, loop element, Using variable, parameter, or a
		/// name never declared in the graph: unknown names count as locals only when declared).
		bool IsLocalName(StringView name)
		{
			if (mGraph.FindLocal(name) != null)
				return true;
			for (let n in mGraph.Nodes)
				if ((n.Kind == .LocalVar || n.Kind == .ForEach || n.Kind == .Using || n.IsCountingLoop) && n.Text == name)
					return true;
			for (let p in mGraph.Entry.Outputs)
				if (p.Kind == .Data && p.Label == name)
					return true;
			return false;
		}

		/// The `scope` Construct a local named `name` is initialised with, or null.
		Node ScopeLocal(StringView name)
		{
			for (let n in mGraph.Nodes)
			{
				if (n.Kind != .LocalVar || n.Text != name)
					continue;
				let src = mGraph.DataSource(n.FindInput("value"));
				if (IsScopeAlloc(src))
					return src;
			}
			return null;
		}

		/// A lifetime error on `node`, or a warning when everything involved was read from code
		/// (the compiler accepted it; the graph only reports what it sees).
		void LifetimeIssue(Node node, Node alloc, bool parsed, StringView message)
		{
			if (!mPlanning)
				return;
			if (parsed && alloc.Original != null && node.Original != null)
				mGraph.AddWarning(node, message);
			else
				mGraph.AddError(node, message);
		}

		// ------------------------------------------------------------------ switch

		struct SwitchSplit
		{
			public int HeadEnd;       // after the ')' of the header
			public int BodyOpen;      // the '{'
			public int OpenTrailEnd;  // end of the '{' token's trailing trivia
			public int CaseIndented;  // 1 / 0 / -1 (unknown): `case` lines are indented relative to the braces
		}

		/// Whitespace length in front of the token at `pos` when it starts its line, else -1. The
		/// first line of a node's text has lost its indentation, so it reports -1 too.
		static int LineIndentLen(StringView text, int pos)
		{
			int ls = pos;
			while (ls > 0 && text[ls - 1] != '\n')
				ls--;
			if (ls == 0)
				return -1;
			for (int i = ls; i < pos; i++)
				if (text[i] != ' ' && text[i] != '\t')
					return -1;
			return pos - ls;
		}

		static bool SplitSwitch(Node node, out SwitchSplit sp)
		{
			sp = default;
			sp.HeadEnd = -1;
			sp.BodyOpen = -1;
			sp.OpenTrailEnd = -1;
			sp.CaseIndented = -1;
			let text = node.Original;
			if (text == null)
				return false;
			List<Token> toks = scope .();
			Lexer.Tokenize(text, toks);
			int count = toks.Count;
			while (count > 0 && toks[count - 1].Kind == .EOF)
				count--;
			if (count < 4 || TokText(text, toks[0]) != "switch" || TokText(text, toks[1]) != "(")
				return false;
			let k = MatchClose(text, toks, 1, count);
			if (k < 0)
				return false;
			sp.HeadEnd = toks[k].End;
			if (k + 1 >= count || TokText(text, toks[k + 1]) != "{")
				return true;
			let open = k + 1;
			sp.BodyOpen = toks[open].Start;
			sp.OpenTrailEnd = toks[open].TrailEnd;
			let close = MatchClose(text, toks, open, count);
			if (close > open + 1)
			{
				let caseIndent = LineIndentLen(text, toks[open + 1].Start);
				var stmtIndent = LineIndentLen(text, toks[close].Start);
				if (stmtIndent < 0)
					stmtIndent = LineIndentLen(text, toks[open].Start);
				if (caseIndent >= 0 && stmtIndent >= 0)
					sp.CaseIndented = (caseIndent > stmtIndent) ? 1 : 0;
			}
			return true;
		}

		void SwitchText(Node node, StringView indent, String o)
		{
			EnsureStyle();
			bool split = SplitSwitch(node, var sp);
			String head = scope .();
			Kw("switch", head);
			GenInput(node.FindInput("value"), 0, head);
			head.Append(')');
			AppendHeader(node, split ? sp.HeadEnd : -1, head, o);
			let stop = Continuation(node);
			if (split && sp.BodyOpen >= 0)
			{
				o.Append(Slice(node, sp.HeadEnd, sp.BodyOpen));
				o.Append('{');
				o.Append(StringView(node.Original, sp.BodyOpen + 1, sp.OpenTrailEnd - sp.BodyOpen - 1));
				mNeedNewline = !o.EndsWith('\n');
			}
			else
			{
				if (mAllman)
				{
					o.Append('\n');
					o.Append(indent);
					o.Append("{\n");
				}
				else
					o.Append(" {\n");
				mNeedNewline = false;
			}

			bool indented = (split && sp.CaseIndented >= 0) ? (sp.CaseIndented == 1) : mCaseIndented;
			String clauseIndent = scope .(indent);
			if (indented)
				clauseIndent.Append(mUnit);
			String bodyIndent = scope .(clauseIndent);
			bodyIndent.Append(mUnit);
			let owner = mCurStmt;
			bool inPlace = !node.Moved;
			for (let p in node.Outputs)
			{
				if (p.Kind != .Exec || p.Name == "then")
					continue;
				bool isDefault = p.Name == "default";
				// An unused Default is not written; one that was in the source stays.
				if (isDefault && !p.Optional && ChainEmpty(p, stop) && p.EndComments == null)
					continue;
				String canonical = scope .();
				if (isDefault)
					canonical.Append("default:");
				else
				{
					if (p.Label.IsEmpty)
						AddError(node, "A case has no value. Type what it matches (for example 1, \"name\" or .Idle) in the Properties panel.");
					StringView labelText = p.Label;
					labelText.Trim();
					canonical.AppendF("case {}:", labelText);
				}
				if (inPlace && p.RawLead != null && p.RawTail != null)
				{
					if (mNeedNewline && !p.RawLead.Contains('\n'))
						o.Append('\n');
					o.Append(p.RawLead);
					if (SameTokens(p.RawTail, canonical))
					{
						o.Append(p.RawTail);
						mNeedNewline = !p.RawTail.EndsWith('\n');
					}
					else
					{
						o.Append(canonical);
						o.Append('\n');
						mNeedNewline = false;
					}
				}
				else
				{
					if (mNeedNewline)
						o.Append('\n');
					o.Append(clauseIndent);
					o.Append(canonical);
					o.Append('\n');
					mNeedNewline = false;
				}
				PushScope(owner);
				GenChain(p, bodyIndent, o, stop);
				PopScope();
				mCurStmt = owner;
				if (mNeedNewline)
				{
					o.Append('\n');
					mNeedNewline = false;
				}
			}
			let then = node.FindOutput("then");
			if (then != null && then.EndComments != null)
				AppendCommentLines(then.EndComments, clauseIndent, o);
			o.Append(indent);
			o.Append('}');
		}

		// ------------------------------------------------------------------ flow macros

		public class FieldNeed
		{
			public String Name = new .() ~ delete _;
			public String Type = new .() ~ delete _;
		}

		/// State fields the regenerated macro nodes use; SourceDocument adds the ones the owner
		/// type does not have yet.
		public List<FieldNeed> FieldNeeds = new .() ~ DeleteContainerAndItems!(_);

		void NeedField(Node node)
		{
			if (!mPlanning)
				return;
			for (let f in FieldNeeds)
				if (f.Name == node.Text2)
					return;
			let need = new FieldNeed();
			need.Name.Set(node.Text2);
			need.Type.Set(FlowMacros.FieldType(node.Text));
			FieldNeeds.Add(need);
		}

		/// Gives every stateful macro its own state field name (`__doOnce_1`...): a node with no
		/// name yet, a wrong prefix, or a name another macro in the graph already uses gets the
		/// next free one. Nodes read from the source keep theirs.
		void AssignFlowFields()
		{
			HashSet<String> used = scope .();
			defer { for (let s in used) delete s; }
			for (int pass < 2)
			{
				for (let n in mGraph.Nodes)
				{
					if (n.Kind != .Flow || !FlowMacros.IsStateful(n.Text) || !mEmitted.Contains(n))
						continue;
					if ((n.Original != null) != (pass == 0))
						continue;
					bool ok = !n.Text2.IsEmpty && FlowMacros.MacroOfField(n.Text2) == n.Text && !used.ContainsAlt(StringView(n.Text2));
					if (!ok)
					{
						StringView prefix = FlowMacros.DefaultPrefix(n.Text);
						if (n.Text == FlowMacros.Gate && n.Text2.StartsWith(FlowMacros.PrefixGateOpen))
							prefix = FlowMacros.PrefixGateOpen;
						String name = scope .();
						HashSet<String> taken = scope .();
						defer { for (let s in taken) delete s; }
						for (let s in used)
							taken.Add(new String(s));
						if (mOwnerFields != null)
							for (let s in mOwnerFields)
								if (!taken.ContainsAlt(StringView(s)))
									taken.Add(new String(s));
						n.Text2.Clear();
						FlowMacros.FreshFieldName(mGraph, prefix, taken, name);
						n.Text2.Set(name);
						n.Edited = true;
					}
					used.Add(new String(n.Text2));
				}
			}
		}

		/// Names of the fields of the owner type (set by SourceDocument) so new state fields do
		/// not collide with them.
		HashSet<String> mOwnerFields;
		public void SetOwnerFields(HashSet<String> names)
		{
			mOwnerFields = names;
		}

		void FlowText(Node node, StringView indent, String o)
		{
			let macro = node.Text;
			let field = node.Text2;
			if (FlowMacros.IsStateful(macro))
				NeedField(node);
			let stop = Continuation(node);

			if (macro == FlowMacros.Sequence)
			{
				bool first = true;
				for (let p in node.Outputs)
				{
					if (p.Kind != .Exec || p.Name == "then")
						continue;
					if (!first)
					{
						o.Append('\n');
						o.Append(indent);
					}
					first = false;
					Block(p, indent, o, stop, StringView(""));
				}
				if (first)
				{
					AddError(node, "A Sequence needs at least one Then output.");
					o.Append("{\n");
					o.Append(indent);
					o.Append('}');
				}
			}
			else if (macro == FlowMacros.DoOnce)
			{
				String head = scope .();
				Kw("if", head);
				head.AppendF("!{})", field);
				IfElse(node, head, node.FindOutput("body"), null, scope $"{field} = true;", default, false, indent, o);
			}
			else if (macro == FlowMacros.DoN)
			{
				String head = scope .();
				Kw("if", head);
				head.AppendF("{} < ", field);
				GenInput(node.FindInput("n"), Parser.BinaryPrecedence("<") + 1, head);
				head.Append(')');
				IfElse(node, head, node.FindOutput("body"), null, scope $"{field}++;", default, false, indent, o);
			}
			else if (macro == FlowMacros.FlipFlop)
			{
				String head = scope .();
				Kw("if", head);
				head.AppendF("!{})", field);
				IfElse(node, head, node.FindOutput("a"), node.FindOutput("b"), scope $"{field} = true;", scope $"{field} = false;", false, indent, o);
			}
			else if (macro == FlowMacros.Gate)
			{
				String head = scope .();
				Kw("if", head);
				if (FlowMacros.GateStartsClosed(node))
					head.AppendF("{})", field);
				else
					head.AppendF("!{})", field);
				IfElse(node, head, node.FindOutput("body"), null, default, default, false, indent, o);
			}
			else if (macro == FlowMacros.MultiGate)
			{
				List<Pin> arms = scope .();
				for (let p in node.Outputs)
					if (p.Kind == .Exec && p.Name != "then")
						arms.Add(p);
				if (arms.IsEmpty)
				{
					AddError(node, "A Multi Gate needs at least one Out output.");
					o.Append("{ }");
					return;
				}
				for (int k < arms.Count)
				{
					int next = (k == arms.Count - 1 && node.Postfix) ? 0 : k + 1;
					String line = scope $"{field} = {next};";
					if (k == 0)
					{
						bool split = SplitCompound(node, var sp);
						String head = scope .();
						Kw("if", head);
						head.AppendF("{} == 0)", field);
						AppendHeader(node, split ? sp.HeadEnd : -1, head, o);
						Block(arms[0], indent, o, stop, (split && sp.BodyOpen >= 0) ? Slice(node, sp.HeadEnd, sp.BodyOpen) : default, line);
					}
					else
					{
						if (mElseSameLine && !mAllman)
							o.Append(' ');
						else
						{
							o.Append('\n');
							o.Append(indent);
						}
						o.Append("else ");
						Kw("if", o);
						o.AppendF("{} == {})", field, k);
						Block(arms[k], indent, o, stop, default, line);
					}
				}
			}
			else if (FlowMacros.IsAction(macro))
			{
				if (field.IsEmpty || FlowMacros.MacroOfField(field) != FlowMacros.TargetMacro(macro))
				{
					String title = scope .();
					node.GetTitle(title);
					AddError(node, scope $"'{title}' must name the state field of a {FlowMacros.TargetMacro(macro)} in this type. Pick it in the Properties panel.");
					o.Append("/* ? */;");
					return;
				}
				bool startsClosed = field.StartsWith(FlowMacros.PrefixGateOpen);
				if (macro == FlowMacros.DoOnceReset)
					o.AppendF("{} = false;", field);
				else if (macro == FlowMacros.DoNReset || macro == FlowMacros.MultiGateReset)
					o.AppendF("{} = 0;", field);
				else if (macro == FlowMacros.GateToggle)
					o.AppendF("{0} = !{0};", field);
				else if (macro == FlowMacros.GateOpen)
					o.AppendF("{} = {};", field, startsClosed ? "true" : "false");
				else
					o.AppendF("{} = {};", field, startsClosed ? "false" : "true");
			}
			else
			{
				AddError(node, scope $"Unknown flow macro '{macro}'.");
				o.Append("/* ? */;");
			}
		}

		/// `<qualifier>.Name(...)` for a static call, `<target>.Name(...)` for a member call with a
		/// wired (or typed) Target, `Name(...)` for self (an unconnected Target) and for calls
		/// without a qualifier. `ref` arguments are written `ref x`, out pins `out name`.
		void CallText(Node node, String o)
		{
			if (node.Binding == .Static)
			{
				if (node.Qualifier != null && !node.Qualifier.IsEmpty)
				{
					o.Append(node.Qualifier);
					o.Append('.');
				}
			}
			else
			{
				let target = node.FindInput("target");
				if (target != null && (mGraph.FindLinkTo(target) != null || !target.Default.IsEmpty))
				{
					GenInput(target, Parser.PostfixPrecedence, o);
					if (!node.Text.IsEmpty)
						o.Append(node.Cascade ? ".." : (node.NullCond ? "?." : "."));
				}
			}
			o.Append(node.Text);
			o.Append('(');
			List<Pin> args = scope .();
			node.GetArgPins(args);
			bool first = true;
			for (let p in args)
			{
				if (!first)
					o.Append(", ");
				first = false;
				ArgText(p, o);
			}
			o.Append(')');
		}

		void ArgText(Pin p, String o)
		{
			if (p.IsOutArg)
			{
				StringView name = (p.OutName != null) ? (StringView)p.OutName : "";
				OutSpell spell = .AsIs;
				if (!mPlanning)
					mOutSpell.TryGetValue(p, out spell);
				else if (p.Form == .Discard)
					spell = .Discard;
				switch (spell)
				{
				case .Discard:
					o.Append('?');
				case .Inline:
					o.AppendF("{} {}", (p.OutDecl == "let") ? "let" : "var", name);
				case .DeclHere, .Hoisted:
					o.AppendF("{} {}", (p.Form == .DeclaredRef) ? "ref" : "out", name);
				default:
					switch (p.Form)
					{
					case .Inline:
						o.AppendF("{}{} {}", p.OutKeyword ? "out " : "", (p.OutDecl != null) ? (StringView)p.OutDecl : "var", name);
					case .Discard:
						o.Append('?');
					case .DeclaredRef:
						o.AppendF("ref {}", name);
					default:
						o.AppendF("out {}", name);
					}
				}
				return;
			}
			if (p.IsRefArg)
			{
				o.Append("ref ");
				GenInput(p, Parser.UnaryPrecedence, o);
				return;
			}
			GenInput(p, 0, o);
		}

		/// Precedence of the expression a pure node produces (higher binds tighter).
		int NodePrecedence(Node node)
		{
			switch (node.Kind)
			{
			case .Operator:
				if (node.FindInput("b") == null)
					return node.Postfix ? Parser.PostfixPrecedence : Parser.UnaryPrecedence;
				return Parser.BinaryPrecedence(node.Text);
			case .Cast: return Parser.UnaryPrecedence;
			case .Select: return 0;
			case .Expr, .MathExpr:
				return IsAtomic(node.Text) ? 100 : 0;
			default: return 100;
			}
		}

		/// True when text can be used as an operand without parentheses.
		public static bool IsAtomic(StringView text)
		{
			var t = text;
			t.Trim();
			if (t.IsEmpty)
				return true;
			int depth = 0;
			char8 quote = 0;
			for (int i = 0; i < t.Length; i++)
			{
				let c = t[i];
				if (quote != 0)
				{
					if (c == '\\')
					{
						i++;
						continue;
					}
					if (c == quote)
						quote = 0;
					continue;
				}
				if (c == '"' || c == '\'')
				{
					quote = c;
					continue;
				}
				if (c == '(' || c == '[' || c == '{' || c == '<')
				{
					depth++;
					continue;
				}
				if (c == ')' || c == ']' || c == '}' || c == '>')
				{
					depth--;
					continue;
				}
				if (depth > 0)
					continue;
				if (CharUtil.IsIdentChar(c) || c == '.' || c == '@' || c == '$')
					continue;
				// `new Foo()` / `scope .()` bind like a primary expression.
				if (c == ' ' && (t.StartsWith("new ") || t.StartsWith("scope ") || t.StartsWith("append ") || t.StartsWith("scope:")) &&
					(t.EndsWith(')') || t.EndsWith(']') || t.EndsWith('}')))
					continue;
				// A leading '-' on a number is fine: "-1"
				if (i == 0 && c == '-' && t.Length > 1 && CharUtil.IsDigit(t[1]))
					continue;
				return false;
			}
			return true;
		}

		public void GenInput(Pin input, int minPrec, String o)
		{
			if (input == null)
				return;
			let link = mGraph.FindLinkTo(input);
			if (link == null)
			{
				bool signed = input.Default.StartsWith('-') || input.Default.StartsWith('+');
				if ((minPrec > 0 && !IsAtomic(input.Default)) || (minPrec >= Parser.UnaryPrecedence && signed))
				{
					o.Append('(');
					o.Append(input.Default);
					o.Append(')');
				}
				else
					o.Append(input.Default);
				return;
			}
			let src = link.From.Owner;
			if (input.Parens && src.IsPure && NodePrecedence(src) < 100 && !mValueTemps.Contains(src))
			{
				// Keep the author's explicit parentheses.
				o.Append('(');
				GenNodeExpr(src, link.From, 0, o);
				o.Append(')');
				return;
			}
			GenNodeExpr(src, link.From, minPrec, o);
		}

		void GenNodeExpr(Node node, Pin outPin, int minPrec, String o)
		{
			if (outPin != null && outPin.IsOutArg)
			{
				// An out pin reads its variable.
				if (outPin.OutName != null)
					o.Append(outPin.OutName);
				return;
			}
			if (mValueTemps.Contains(node))
			{
				// Shared value: computed once into its temp (see GenStatement).
				GetTempName(node, o);
				return;
			}
			if (!node.IsPure)
			{
				// Value produced by an exec node (an impure call): read the temp it was stored in.
				if (node.Kind == .Call)
				{
					if (mInFlow.Contains(node))
						GetTempName(node, o);
					else if (mOnPath.Contains(node))
					{
						AddError(node, "Data loop: this call's value depends on itself.");
						o.Append("/* loop */");
					}
					else
					{
						// Never executed as a statement, so there is no temp: call it where the
						// value is used. The node itself stays an impure call in the graph.
						String title = scope .();
						node.GetTitle(title);
						Warn(scope $"'{title}' is not connected to the execution flow; it is called where its value is used.", node);
						mOnPath.Add(node);
						CallText(node, o);
						mOnPath.Remove(node);
					}
				}
				else if (node.Kind == .Flow)
					o.Append(node.Text2); // a macro's counter / Is A output reads its state field
				else if (node.Kind == .Entry)
					o.Append(outPin.Label);
				else if (node.Kind == .ForEach || node.Kind == .LocalVar || node.Kind == .Using || node.IsCountingLoop)
					o.Append(node.Text); // the loop / local / using variable's name
				return;
			}

			if (mOnPath.Contains(node))
			{
				AddError(node, "Data loop: this node's value depends on itself.");
				o.Append("/* loop */");
				return;
			}

			int prec = NodePrecedence(node);
			bool paren = prec < minPrec;
			if (paren)
				o.Append('(');

			if (mGraph.IsClean(node))
				o.Append(node.Original);
			else
			{
				mOnPath.Add(node);
				ExprText(node, o);
				mOnPath.Remove(node);
			}

			if (paren)
				o.Append(')');
		}

		/// Mixing bitwise/shift/logical operators with other operators without parentheses is
		/// legal but confusing (and Beef warns about it), so such operands get parentheses.
		int ClarityPrec(Node parent, Pin input, int minPrec)
		{
			let src = mGraph.DataSource(input);
			if (src == null || src.Kind != .Operator || src.FindInput("b") == null || mValueTemps.Contains(src))
				return minPrec;
			// `x case .Ok` inside another operator (but `&&` / `||`) gets parentheses: Beef's grouping
			// of `case` with comparisons is not something to rely on.
			if (src.Text == "case" && parent.Text != "&&" && parent.Text != "||")
				return 100;
			StringView[?] picky = .("&", "|", "^", "<<", ">>", "&&", "||", "??");
			bool parentPicky = false;
			for (let op in picky)
				if (parent.Text == op)
					parentPicky = true;
			if (parentPicky && Parser.BinaryPrecedence(src.Text) != Parser.BinaryPrecedence(parent.Text))
				return 100;
			return minPrec;
		}

		void ExprText(Node node, String o)
		{
			switch (node.Kind)
			{
			case .Get:
				let target = node.FindInput("target");
				if (target != null && (mGraph.FindLinkTo(target) != null || !target.Default.IsEmpty))
				{
					GenInput(target, Parser.PostfixPrecedence, o);
					o.Append(node.Cascade ? ".." : (node.NullCond ? "?." : "."));
				}
				o.Append(node.Text);

			case .Call:
				CallText(node, o);

			case .Index:
				GenInput(node.FindInput("target"), Parser.PostfixPrecedence, o);
				o.Append('[');
				bool first = true;
				for (let p in node.Inputs)
				{
					if (!p.Name.StartsWith("arg"))
						continue;
					if (!first)
						o.Append(", ");
					first = false;
					GenInput(p, 0, o);
				}
				o.Append(']');

			case .Operator:
				let a = node.FindInput("a");
				let b = node.FindInput("b");
				if (b != null)
				{
					int prec = Parser.BinaryPrecedence(node.Text);
					bool rightAssoc = node.Text == "??";
					GenInput(a, ClarityPrec(node, a, rightAssoc ? prec + 1 : prec), o);
					o.Append(' ');
					o.Append(node.Text);
					o.Append(' ');
					if (node.Text == "is" || node.Text == "as" || node.Text == "case")
						o.Append(b.Default);
					else
						GenInput(b, ClarityPrec(node, b, rightAssoc ? prec : prec + 1), o);
				}
				else if (node.Postfix)
				{
					GenInput(a, Parser.PostfixPrecedence, o);
					o.Append(node.Text);
				}
				else
				{
					o.Append(node.Text);
					String operand = scope .();
					GenInput(a, Parser.UnaryPrecedence, operand);
					bool wordOp = !node.Text.IsEmpty && CharUtil.IsIdentStart(node.Text[0]);
					if (wordOp || (!operand.IsEmpty && (operand[0] == node.Text[node.Text.Length - 1])))
						o.Append(' ');
					o.Append(operand);
				}

			case .Select:
				// Beef's ?: binds tighter than comparisons, so a compound condition needs parens.
				GenInput(node.FindInput("condition"), 100, o);
				o.Append(" ? ");
				GenInput(node.FindInput("a"), 0, o);
				o.Append(" : ");
				GenInput(node.FindInput("b"), 0, o);

			case .Cast:
				o.Append('(');
				o.Append(node.Text);
				o.Append(')');
				// Operands starting with '-', '&', '*', ... would read as a binary expression.
				GenInput(node.FindInput("value"), Parser.PostfixPrecedence, o);

			case .Expr:
				o.Append(node.Text);

			case .This:
				o.Append("this");

			case .Base:
				o.Append("base");
			case .Construct:
				ConstructText(node, o);

			case .Lambda:
				LambdaText(node, o);

			case .Format:
				FormatText(node, o);

			case .MathExpr:
				MathText(node, o);

			default:
				AddError(node, "This node has no code form.");
				o.Append("/* ? */");
			}
		}
	}
}
