using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=mathexpr` on a project with a `Shapes` class (`Length(int x, float y, float
	/// scale)`, `Sum(int p, int q)`, member variables `a`, `b`, `mTotal = 0`): a Math Expression
	/// picked from the Node menu off a Return's value (its first frame: the inputs need values),
	/// its expression typed and its inputs wired from the parameters (`return Math.Sqrt(x * x +
	/// y * y) * scale;`), a second one with an input left open (the error on the node) and a
	/// broken text typed into its field (the red frame); then Initial Value set to Expression on
	/// `mTotal` (the choice stays while the value is still `0`), `a + b` written, a broken
	/// expression refused, and Save writing the `#math` record. Captures `math-first`,
	/// `math-node`, `math-error`, `init-expr-chosen`, `init-expr-written`, `init-expr-refused`.
	extension EditorApp
	{
		int mMeStep;
		int mMeWait;
		String mMePath = new .() ~ delete _;
		int32 mMeNode;

		SourceDocument MeDoc => FindDoc(mMePath);

		MethodGraph MeOpen(StringView key)
		{
			let doc = MeDoc;
			let mg = (doc != null) ? doc.FindMethod(key) : null;
			if (mg != null)
				OpenTab(mg);
			return CurrentMethod;
		}

		static Pin MeParam(Graph g, StringView name)
		{
			for (let p in g.Entry.Outputs)
				if (p.Kind == .Data && p.Label == name)
					return p;
			return null;
		}

		Node MeNewest(Graph g, NodeKind kind)
		{
			Node found = null;
			for (let n in g.Nodes)
				if (n.Kind == kind && (found == null || n.Id > found.Id))
					found = n;
			return found;
		}

		void MeSelect(Node n)
		{
			let tab = CurrentTab;
			if (tab == null || n == null)
				return;
			tab.SelectedNodes.Clear();
			tab.SelectedNodes.Add(n.Id);
			mSelClassActive = false;
			mSelVarActive = false;
			// The canvas at 125% shows less of the graph: one zoom step out keeps the three nodes in view.
			float s = Look.Scale;
			tab.ZoomLevel = (s > 1.1f) ? Canvas.DefaultZoomLevel - 2 : Canvas.DefaultZoomLevel;
			tab.CenterOn(n.X + 155 * s, n.Y + 45 * s);
			tab.NeedsFocus = false;
			Panels.Focus(Panels.PropertiesId);
			mStatus.Clear();
		}

		/// The new node between the entry and the Return (the Return moved right to make room).
		static void MePlace(Graph g, Node n, Node ret)
		{
			float s = Look.Scale; // node sizes follow the UI scale
			n.X = Canvas.SnapIf(g.Entry.X + 170 * s);
			n.Y = Canvas.SnapIf(g.Entry.Y + 50 * s);
			n.HasPos = true;
			ret.X = Canvas.SnapIf(n.X + 360 * s);
			ret.Y = g.Entry.Y;
		}

		bool SelfTestMath()
		{
			if (mMeWait > 0)
			{
				mMeWait--;
				return false;
			}
			let step = mMeStep++;
			const String cLength = "Shapes.Length(int,float,float)";
			const String cSum = "Shapes.Sum(int,int)";
			switch (step)
			{
			case 0:
				for (let f in Index.Files)
				{
					let doc = OpenFile(f.Path, false);
					if (doc != null && doc.FindMethod(cLength) != null)
					{
						mMePath.Set(f.Path);
						break;
					}
				}
				let mg = MeOpen(cLength);
				SelfTestCheck(mg != null, "mathexpr 1: Shapes.Length opened");
				if (mg == null)
					return true;
				mStatus.Clear();
				mMeWait = 3;
			case 1:
				// Node menu off the Return's value: Math Expression (search words "math", "expression").
				let mg = MeOpen(cLength);
				let ret = FindNodeOf(mg.Graph, .Return);
				SelfTestCheck(ret != null, "mathexpr 2: the Return of Length");
				if (ret == null)
					return true;
				SessionPick(ret.FindInput("value"), "Math Expression", 380, 180);
				SelfTestCheck(mNodeMenu.SelfTestFinds("Math Expression", "math") && mNodeMenu.SelfTestFinds("Math Expression", "expression") &&
					mNodeMenu.SelfTestFinds("Math Expression", "math expression"), "mathexpr 2: the Node menu search finds it by \"math\" and \"expression\"");
				mMeWait = 3;
			case 2:
				let mg = MeOpen(cLength);
				let m = MeNewest(mg.Graph, .MathExpr);
				let ret = FindNodeOf(mg.Graph, .Return);
				SelfTestCheck(m != null && m.FindInput("a") != null && m.FindInput("b") != null && mg.Graph.DataSource(ret.FindInput("value")) == m,
					"mathexpr 2: picked from the Node menu: `a + b`, inputs a and b, its Result wired into the Return");
				if (m == null)
					return true;
				mMeNode = m.Id;
				MePlace(mg.Graph, m, ret);
				MeSelect(m);
				mMeWait = 3;
			case 3:
				if (!SelfTestShot("math-first"))
				{
					mMeStep--;
					return false;
				}
			case 4:
				// The expression typed (what the field on the node does), the parameters wired in.
				let mg = MeOpen(cLength);
				let g = mg.Graph;
				Node m = null;
				for (let n in g.Nodes)
					if (n.Id == mMeNode)
						m = n;
				if (m == null)
				{
					SelfTestCheck(false, "mathexpr 3: the node is gone");
					return true;
				}
				BeginEdit();
				m.Text.Set("Math.Sqrt(x * x + y * y) * scale");
				NodeFactory.SyncMath(g, m);
				for (let pin in m.Inputs)
				{
					let src = MeParam(g, pin.Name);
					if (src != null)
						g.Connect(src, pin);
				}
				CommitCurrent();
				mMeWait = 3;
			case 5:
				let mg = MeOpen(cLength);
				let m = MeNewest(mg.Graph, .MathExpr);
				SelfTestCheck(MeDoc.Text.Contains("\t\t\treturn Math.Sqrt(x * x + y * y) * scale;"),
					"mathexpr 3: typed and wired: `return Math.Sqrt(x * x + y * y) * scale;`");
				StringView resultType = (m != null) ? (StringView)m.Result.TypeName : "";
				SelfTestCheck(m != null && m.Inputs.Count == 3 && m.Result.TypeName == "float", scope $"mathexpr 3: inputs x, y, scale; the Result is float ({resultType})");
				MeSelect(m);
				mMeWait = 3;
			case 6:
				if (!SelfTestShot("math-node"))
				{
					mMeStep--;
					return false;
				}
			case 7:
				// A second one with an input left open: the error is on the node, nothing is written.
				let mg = MeOpen(cSum);
				let ret = FindNodeOf(mg.Graph, .Return);
				SessionPick(ret.FindInput("value"), "Math Expression", 380, 180);
				mMeWait = 3;
			case 8:
				let mg = MeOpen(cSum);
				let g = mg.Graph;
				let m = MeNewest(g, .MathExpr);
				if (m == null)
				{
					SelfTestCheck(false, "mathexpr 4: no Math Expression in Sum");
					return true;
				}
				MePlace(g, m, FindNodeOf(g, .Return));
				BeginEdit();
				m.Text.Set("p * q + r");
				NodeFactory.SyncMath(g, m);
				g.Connect(MeParam(g, "p"), m.FindInput("p"));
				g.Connect(MeParam(g, "q"), m.FindInput("q"));
				CommitCurrent();
				mMeNode = m.Id;
				mMeWait = 3;
			case 9:
				let mg = MeOpen(cSum);
				let m = MeNewest(mg.Graph, .MathExpr);
				bool said = false;
				for (let e in mg.Graph.Errors)
					if (m != null && e.NodeId == m.Id && e.Message.Contains("'r' needs a value"))
						said = true;
				SelfTestCheck(said && !MeDoc.Text.Contains("p * q"),
					"mathexpr 4: an input left open: the error on the node, Sum is not written");
				MeSelect(m);
				// A broken text being typed into the node's field: the frame turns red.
				mGraphPanel.SelfTestMathType(m.Id, "p * (q +");
				mMeWait = 3;
			case 10:
				if (!SelfTestShot("math-error"))
				{
					mMeStep--;
					return false;
				}
				mGraphPanel.SelfTestMathType(0, "");
			case 11:
				// Initial Value: Expression on `mTotal` (the variable in Properties).
				SelfTestVar("Shapes.mTotal");
				for (let t in Tabs)
					t.SelectedNodes.Clear();
				mStatus.Clear();
				mMeWait = 3;
			case 12:
				// The tab switch is done: no node selected, the variable shown.
				for (let t in Tabs)
					t.SelectedNodes.Clear();
				SelfTestVar("Shapes.mTotal");
				// What the chooser does when Expression is picked.
				let doc = MeDoc;
				let field = FindField(FindTypeIn(doc, "Shapes"), "mTotal");
				let t = MemberInit.TypeOf("int", TypeService.Current);
				MemberInit init = scope .();
				if (field == null || !doc.ReadMemberInit(field, t, init))
				{
					SelfTestCheck(false, "mathexpr 5: mTotal not read");
					return true;
				}
				StartValue(.Custom, t, init, TypeService.Current);
				ValueBufFor(init, mInitValueBuf);
				mInitExprChoice.Choose(scope $"{doc.FilePath}|Shapes|mTotal");
				mMeWait = 5;
			case 13:
				let doc = MeDoc;
				let field = FindField(FindTypeIn(doc, "Shapes"), "mTotal");
				let t = MemberInit.TypeOf("int", TypeService.Current);
				MemberInit init = scope .();
				doc.ReadMemberInit(field, t, init);
				let shown = mInitExprChoice.Apply(scope $"{doc.FilePath}|Shapes|mTotal", init);
				SelfTestCheck(shown && init.ValueKind == .Custom && doc.Text.Contains("public int mTotal = 0;"),
					"mathexpr 5: Expression chosen: it stays chosen over the value `0`, nothing written yet");
				mStatus.Clear();
			case 14:
				if (!SelfTestShot("init-expr-chosen"))
				{
					mMeStep--;
					return false;
				}
			case 15:
				// `a + b` typed and committed (what the Value box does on Enter).
				let doc = MeDoc;
				let type = FindTypeIn(doc, "Shapes");
				let field = FindField(type, "mTotal");
				let t = MemberInit.TypeOf("int", TypeService.Current);
				MemberInit init = scope .();
				doc.ReadMemberInit(field, t, init);
				mInitExprChoice.Apply(scope $"{doc.FilePath}|Shapes|mTotal", init);
				String text = scope .();
				String why = scope .();
				SelfTestCheck(MemberInit.CheckExpression("a + b", text, why), "mathexpr 6: `a + b` is accepted");
				init.ValueKind = .Custom;
				init.Value.Set(text);
				ApplyMemberInit(doc, type, field, init, false);
				mStatus.Clear();
				mMeWait = 3;
			case 16:
				let doc = MeDoc;
				let field = FindField(FindTypeIn(doc, "Shapes"), "mTotal");
				MemberInit init = scope .();
				doc.ReadMemberInit(field, MemberInit.TypeOf("int", TypeService.Current), init);
				SelfTestCheck(doc.Text.Contains("public int mTotal = a + b;") && init.ValueKind == .Custom && init.Value == "a + b",
					"mathexpr 6: written: `public int mTotal = a + b;`, read back as Expression");
			case 17:
				if (!SelfTestShot("init-expr-written"))
				{
					mMeStep--;
					return false;
				}
				// A broken expression in the Value box: the frame is red, nothing is written.
				mInitValueBuf.Set("a +");
				mMeWait = 3;
			case 18:
				if (!SelfTestShot("init-expr-refused"))
				{
					mMeStep--;
					return false;
				}
				String o = scope .();
				String why = scope .();
				SelfTestCheck(!MemberInit.CheckExpression(mInitValueBuf, o, why) && MeDoc.Text.Contains("public int mTotal = a + b;"),
					scope $"mathexpr 7: `a +` is refused ({why})");
				mInitValueBuf.Set("a + b");
			case 19:
				MeOpen(cSum);
				mMeWait = 3;
			case 20:
				// The open input of Sum gets a value: the error goes and Sum is written.
				let mg = MeOpen(cSum);
				let m = MeNewest(mg.Graph, .MathExpr);
				let r = m?.FindInput("r");
				SelfTestCheck(r != null, "mathexpr 8: the open input r");
				if (r != null)
					SessionSetPin(m, r, "1");
				mMeWait = 3;
			case 21:
				SelfTestCheck(MeDoc.Text.Contains("\t\t\treturn p * q + 1;") && MeDoc.FindMethod(cSum)?.Graph.Errors.IsEmpty == true,
					"mathexpr 8: a value typed into the open input: `return p * q + 1;`, no error");
			case 22:
				// Save: the side file keeps what makes the plain expression a Math Expression again.
				let ok = SaveAll();
				String layoutPath = scope .();
				SourceDocument.GetLayoutPath(mMePath, layoutPath);
				String layout = scope .();
				File.ReadAllText(layoutPath, layout).IgnoreError();
				SelfTestCheck(ok && layout.Contains("#math\tShapes.Length(int,float,float)\t") && layout.Contains("\tMath.Sqrt(x * x + y * y) * scale"),
					"mathexpr 9: saved: the side file has the #math record");
				mStatus.Clear();
				return true;
			}
			return false;
		}
	}
}
