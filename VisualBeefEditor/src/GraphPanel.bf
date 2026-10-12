using System;
using System.Collections;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// What a mouse drag on the canvas is doing.
	enum CanvasMode
	{
		None,
		/// Right button pressed, not moved yet: becomes Pan on drag, a context menu on release.
		RightPending,
		Pan,
		Marquee,
		MoveNodes,
		/// Dragging a new wire out of `DragPin`.
		Wire,
		/// Ctrl+drag: moving the links of `DragPin` (ids in `DragLinks`) to another pin.
		Relink,
		/// Dragging the bottom-right corner of comment `DragComment`.
		ResizeComment,
		/// Dragging reroute knot `DragKnot` of the link `DragKnotFrom` -> `DragKnotTo`.
		MoveKnot
	}

	/// A reroute knot: the link (by its pins) and the knot's index along it.
	struct KnotRef : IEquatable<KnotRef>
	{
		public int32 FromPin;
		public int32 ToPin;
		public int32 Index;

		public this(int32 fromPin, int32 toPin, int32 index)
		{
			FromPin = fromPin;
			ToPin = toPin;
			Index = index;
		}

		public bool IsValid => FromPin != 0;
		public bool Equals(KnotRef o) => FromPin == o.FromPin && ToPin == o.ToPin && Index == o.Index;
	}

	/// One open function graph (a tab in the graph area) and its canvas view state.
	class GraphTab
	{
		static int32 sNextUid;
		/// The tab's identity in the tab bar: its method key changes with the parameter types
		/// (an input added), and the tab must stay the one in front.
		public int32 Uid = ++sNextUid;
		public SourceDocument Doc;
		public String MethodKey = new .() ~ delete _;
		public String Title = new .() ~ delete _;
		public Graph LastGraph;
		/// Graph.Serial of the graph last drawn: a freed graph's address can be reused, so identity
		/// is checked by serial.
		public int32 LastGraphSerial = -1;
		/// Frame the entry node on the next draw.
		public bool NeedsFocus = true;
		/// Keys of nodes to re-select after a regeneration.
		public List<String> ReselectKeys = new .() ~ DeleteContainerAndItems!(_);
		public List<int32> SelectedNodes = new .() ~ delete _;
		public List<int32> SelectedLinks = new .() ~ delete _;
		/// Selected comment boxes (GraphComment.Id) and reroute knot.
		public List<int32> SelectedComments = new .() ~ delete _;
		public KnotRef SelectedKnot;
		/// Comment whose title is being edited inline (0 = none).
		public int32 EditingComment;
		/// Top-left of the canvas on screen, and its size (updated every draw).
		public ImVec2 CanvasOrigin;
		public ImVec2 CanvasSize;
		public bool Open = true;

		// ---- View: screen = CanvasOrigin + (grid + Pan) * Zoom
		public ImVec2 Pan;
		public int32 ZoomLevel = Canvas.DefaultZoomLevel;
		public float Zoom => Canvas.ZoomLevels[ZoomLevel];
		public double ZoomChangedTime = -100;
		bool mHasPendingCenter;
		ImVec2 mPendingCenter;

		// ---- Drag state
		public CanvasMode Mode;
		public int32 ModeButton;
		public ImVec2 PressPos;
		public ImVec2 LastMouse;
		public bool Moved;
		public int32 DragPin;
		public List<int32> DragLinks = new .() ~ delete _;
		public Dictionary<int32, ImVec2> DragStart = new .() ~ delete _;
		public List<int32> MarqueeBase = new .() ~ delete _;
		public List<int32> MarqueeCommentBase = new .() ~ delete _;
		/// Comments moving with a MoveNodes drag (id -> start position) and the one being resized.
		public Dictionary<int32, ImVec2> DragCommentStart = new .() ~ delete _;
		public int32 DragComment;
		/// Start value of a resize / knot drag.
		public ImVec2 DragVec;
		public KnotRef DragKnot;
		public int32 PressComment;
		public bool PressCommentWasSelected;
		/// Ctrl+F "Find in Sheets" box.
		public bool FindOpen;
		public bool FindFocus;
		public int32 PressNode;
		public bool PressNodeWasSelected;
		/// Pin / link a right-click menu is open for.
		public int32 CtxPin;
		public int32 CtxLink;

		public this(SourceDocument doc, StringView methodKey, StringView title)
		{
			Doc = doc;
			MethodKey.Set(methodKey);
			Title.Set(title);
		}

		public bool IsSelected(int32 nodeId) => SelectedNodes.Contains(nodeId);

		public void ClearSelection()
		{
			SelectedNodes.Clear();
			SelectedLinks.Clear();
			SelectedComments.Clear();
			SelectedKnot = default;
		}

		public bool IsCommentSelected(int32 id) => SelectedComments.Contains(id);

		public void SelectOnly(int32 nodeId)
		{
			ClearSelection();
			SelectedNodes.Add(nodeId);
		}

		public void AddToSelection(int32 nodeId)
		{
			if (!SelectedNodes.Contains(nodeId))
				SelectedNodes.Add(nodeId);
		}

		public void ToggleSelection(int32 nodeId)
		{
			if (!SelectedNodes.Remove(nodeId))
				SelectedNodes.Add(nodeId);
		}

		/// Scrolls so grid point (x, y) is in the middle of the canvas (applied on the next draw).
		public void CenterOn(float x, float y)
		{
			mHasPendingCenter = true;
			mPendingCenter = .(x, y);
			NeedsFocus = false;
		}

		public void ApplyPendingCenter()
		{
			if (!mHasPendingCenter || CanvasSize.x <= 0)
				return;
			mHasPendingCenter = false;
			Pan = .(CanvasSize.x * 0.5f / Zoom - mPendingCenter.x, CanvasSize.y * 0.5f / Zoom - mPendingCenter.y);
		}

		// ---- Eased view jumps (saved views, Home): the middle of the canvas moves from one grid point
		// to another over about 150 ms.
		public const double ViewAnimSeconds = 0.15;
		/// The frame loop keeps drawing until this time (GraphTab.Animating).
		public static double sAnimUntil;
		public static bool Animating => Gui.igGetTime() < sAnimUntil;
		public bool ViewAnim;
		double mAnimStart;
		ImVec2 mAnimFrom;
		ImVec2 mAnimTo;

		/// The grid point in the middle of the canvas.
		public ImVec2 ViewCenter => .(CanvasSize.x * 0.5f / Zoom - Pan.x, CanvasSize.y * 0.5f / Zoom - Pan.y);

		/// Eases the view to a zoom level and a grid point in the middle. The zoom changes at once
		/// (about the current middle), the pan eases.
		public void AnimateTo(float cx, float cy, int32 levelIn)
		{
			NeedsFocus = false;
			mHasPendingCenter = false;
			let level = Math.Clamp(levelIn, 0, (int32)Canvas.ZoomLevels.Count - 1);
			if (CanvasSize.x <= 0)
			{
				ZoomLevel = level;
				CenterOn(cx, cy);
				return;
			}
			let c = ViewCenter;
			if (level != ZoomLevel)
			{
				ZoomLevel = level;
				ZoomChangedTime = Gui.igGetTime();
				Pan = .(CanvasSize.x * 0.5f / Zoom - c.x, CanvasSize.y * 0.5f / Zoom - c.y);
			}
			mAnimFrom = c;
			mAnimTo = .(cx, cy);
			mAnimStart = Gui.igGetTime();
			ViewAnim = true;
			sAnimUntil = mAnimStart + ViewAnimSeconds + 0.1;
		}

		/// Moves the view one step along the ease (called once per frame before drawing).
		public void StepViewAnim()
		{
			if (!ViewAnim || CanvasSize.x <= 0)
				return;
			float t = (float)((Gui.igGetTime() - mAnimStart) / ViewAnimSeconds);
			if (t >= 1)
			{
				t = 1;
				ViewAnim = false;
			}
			float e = 1 - (1 - t) * (1 - t) * (1 - t);
			float cx = mAnimFrom.x + (mAnimTo.x - mAnimFrom.x) * e;
			float cy = mAnimFrom.y + (mAnimTo.y - mAnimFrom.y) * e;
			Pan = .(CanvasSize.x * 0.5f / Zoom - cx, CanvasSize.y * 0.5f / Zoom - cy);
		}

		/// Ends an ease at once (a drag of the view or the minimap takes over).
		public void CancelViewAnim() { ViewAnim = false; }

		public ImVec2 GridToScreen(float x, float y) => .(CanvasOrigin.x + (x + Pan.x) * Zoom, CanvasOrigin.y + (y + Pan.y) * Zoom);
		public ImVec2 ScreenToGrid(ImVec2 s) => .((s.x - CanvasOrigin.x) / Zoom - Pan.x, (s.y - CanvasOrigin.y) / Zoom - Pan.y);

		/// Changes the zoom level keeping the grid point under `anchor` (screen) fixed.
		public void SetZoomLevel(int32 level, ImVec2 anchor)
		{
			let clamped = Math.Clamp(level, 0, (int32)Canvas.ZoomLevels.Count - 1);
			if (clamped == ZoomLevel)
				return;
			let g = ScreenToGrid(anchor);
			ZoomLevel = clamped;
			Pan = .((anchor.x - CanvasOrigin.x) / Zoom - g.x, (anchor.y - CanvasOrigin.y) / Zoom - g.y);
			ZoomChangedTime = Gui.igGetTime();
		}

		public void CancelInteraction()
		{
			Mode = .None;
			DragLinks.Clear();
			DragStart.Clear();
			MarqueeBase.Clear();
			MarqueeCommentBase.Clear();
			DragCommentStart.Clear();
			DragComment = 0;
			DragKnot = default;
			DragPin = 0;
			PressNode = 0;
			PressComment = 0;
		}
	}

	enum NodeShape
	{
		Normal,
		/// Variable getter pill.
		Getter,
		/// Headerless math node with a big symbol (also UE's compact pure calls with no inputs).
		Operator
	}

	/// Per-frame layout of one visible pin, in grid units relative to its node.
	struct PinLay
	{
		public Pin Pin;
		public NodeLay Node;
		/// Text shown next to the pin (usually Pin.Label; a Set's value row shows the variable).
		public StringView LabelText;
		/// Pin centre.
		public ImVec2 Off;
		public float RowY;
		/// Inputs: label left edge. Outputs: label right edge.
		public float LabelX;
		public float LabelW;
		public float FieldX;
		/// 0 = no inline value field.
		public float FieldW;
		public bool Check;
		/// The typed control of an unwired input (PinValue.KindOf); Expr when untyped.
		public PinValueKind VKind;
		public bool Visible;
		/// An unconnected Target of a member call: drawn as a greyed "self", like UE.
		public bool SelfHint;
	}

	/// Per-frame layout of one node, in grid units (zoom 1, base font size).
	class NodeLay
	{
		public Node Node;
		public NodeShape Shape;
		public float W;
		public float H;
		public float HeaderH;
		public String Title = new .() ~ delete _;
		public String Subtitle = new .() ~ delete _;
		public List<String> CodeLines = new .() ~ DeleteContainerAndItems!(_);
		public float CodeY;
		public float CodeH;
		/// A Math Expression: its expression is a field in the body (at CodeY, CodeH high).
		public bool MathField;
		public bool ShowArgs;
		public float ArgsY;
		public bool Orphan;
		public float OrphanY;
		public String Error;
		public float ErrorW;
		public float ErrorTextH;
		/// Warning (yellow badge: compiler or GraphValidator warning) when the node has no error.
		public String Warning;
		public float WarningTextH;
		/// The node's error is about its Target pin: the pin is drawn red.
		public bool TargetBad;
		public float SymbolSize;
		/// Title scale for headerless nodes (operators 1.8, compact calls ~1.2).
		public float SymbolScale = 1.8f;
		/// Header colour (UE colours per node kind / variable type).
		public uint32 Header;
		public bool Selected;
		public bool Visible;
		/// Screen y of the error / warning badge's top edge this frame (`PlaceBadges`).
		public float BadgeY;

		public void Reset()
		{
			Title.Clear();
			Subtitle.Clear();
			ClearAndDeleteItems!(CodeLines);
			MathField = false;
			ShowArgs = false;
			Orphan = false;
			Error = null;
			Warning = null;
			TargetBad = false;
			CodeH = 0;
		}
	}

	/// Draws a graph on a zoomable, pannable canvas (UE5 Blueprint look and feel) and turns
	/// user interaction into graph edits.
	class GraphPanel
	{
		EditorApp mApp;
		TextBuffer mScratch = new .(1024) ~ delete _;
		/// The typed value controls of unwired inputs (also driven by the self test).
		public PinValueEditor mPinEditor = new .() ~ delete _;
		List<Pin> mLeft = new .() ~ delete _;
		List<Pin> mRight = new .() ~ delete _;
		/// The inline value being typed into already pushed an undo step (commit on deactivate).
		bool mInlineEditPushedUndo;
		/// "+ arg" / "- arg" clicked inside a node (positive = add, negative = remove); applied
		/// after drawing so the node list isn't modified mid-iteration.
		int32 mPendingArgNode;
		/// A "VB_MEMBER" payload dropped on the canvas this frame (applied after drawing).
		int32 mPendingDrop = -1;
		ImVec2 mPendingDropPos;
		/// Something called mApp.CommitCurrent() this frame: stop touching the graph.
		bool mCommitted;
		/// Compile errors mapped onto nodes for the graph being drawn (node id -> message).
		Dictionary<int32, String> mNodeErrors = new .() ~ DeleteDictionaryAndValues!(_);
		/// Compiler / GraphValidator / generator warnings by node id (yellow badge, never block a commit; an error on the same node wins).
		Dictionary<int32, String> mNodeWarnings = new .() ~ DeleteDictionaryAndValues!(_);

		// Per-frame layout
		List<NodeLay> mLayPool = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<int32, NodeLay> mLayById = new .() ~ delete _;
		List<NodeLay> mOrder = new .() ~ delete _;
		List<PinLay> mPins = new .() ~ delete _;
		Dictionary<int32, int> mPinIndex = new .() ~ delete _;

		// Per-frame hover results
		int32 mHoverPin;
		int32 mHoverNode;
		int32 mHoverLink;
		/// Segment of the hovered link (0 = before the first reroute knot).
		int32 mHoverLinkSegment;
		KnotRef mHoverKnot;
		/// Comment whose title bar / resize corner is hovered.
		int32 mHoverComment;
		int32 mHoverCommentResize;

		// Comment boxes and reroutes of the graph being drawn (owned by the document).
		List<GraphComment> mComments = new .() ~ delete _;
		Dictionary<int64, GraphReroute> mRoutes = new .() ~ delete _;
		TextBuffer mCommentBuf = new .(512) ~ delete _;
		bool mFocusCommentEdit;
		int32 mFocusedCommentEdit;
		int32 mCtxComment;
		TextBuffer mFindBuf = new .(256) ~ delete _;

		// Hover tooltip for nodes (UE shows it after a short delay).
		int32 mTipNode;
		double mTipSince;

		// "Get X / Set X" menu after dropping a variable without Ctrl / Alt.
		bool mVarDropOpen;
		String mVarDropName = new .() ~ delete _;
		String mVarDropType = new .() ~ delete _;
		ImVec2 mVarDropPos;

		// Fonts / metrics (base size, zoom 1)
		ImFont* mFont;
		ImFont* mMono;
		float mFontSize = 16;
		float RowH => mFontSize + 10;

		public this(EditorApp app)
		{
			mApp = app;
		}

		bool HidePin(Graph g, Pin p)
		{
			// UE's SET node: the variable is the row label, not a pin, unless something is wired
			// into it (a computed object) or there is no value row to carry the name.
			if (IsSetVariableLabel(g, p))
				return true;
			// Static calls (Console.WriteLine, Math.Max, MyType.Make): UE shows no Target pin, just
			// "Receiver is X" under the title. The type stays editable in Properties.
			if (IsStaticTarget(g, p))
				return true;
			// A void function's Return has no value (UE shows no pin then).
			if (p.IsInput && p.Name == "value" && p.Owner.Kind == .Return && (p.TypeName.IsEmpty || p.TypeName == "void") &&
				p.Default.IsEmpty && !g.IsLinked(p))
				return true;
			// Statements after a return/break are legal but unusual: only show that pin if used.
			if (!p.IsInput && p.Kind == .Exec && p.Name == "then" &&
				(p.Owner.Kind == .Return || p.Owner.Kind == .Break || p.Owner.Kind == .Continue))
				return !g.IsLinked(p);
			return false;
		}

		static StringView[?] sStaticClasses = .("Console", "Math", "Runtime", "String", "Environment", "File", "Directory",
			"Path", "Debug", "Platform", "Internal", "Enum", "Char8", "Char16", "Char32", "Int", "Float", "Double");

		/// An unlinked call target naming a type rather than an object.
		bool IsStaticTarget(Graph g, Pin p)
		{
			if (p.Owner.Kind != .Call || p.Name != "target" || !p.IsInput || g.IsLinked(p))
				return false;
			StringView t = p.Default;
			t.Trim();
			if (t.IsEmpty || !t[0].IsUpper)
				return false;
			for (let c in t.RawChars)
				if (!c.IsLetterOrDigit && c != '_' && c != '.')
					return false;
			for (let sc in sStaticClasses)
				if (t == sc)
					return true;
			return mApp.Index != null && mApp.Index.FindType(t) != null;
		}

		static bool IsBoolLiteral(Pin p) => p.Default == "true" || p.Default == "false";

		/// A member call's Target with nothing wired or typed in: it means `this`.
		static bool IsSelfTarget(Graph g, Pin p)
		{
			return p.IsInput && p.Name == "target" && p.Owner.Kind == .Call && p.Owner.Binding == .Instance &&
				p.Default.IsEmpty && !g.IsLinked(p);
		}

		/// A Set node's unlinked "target" pin that is shown as the label of its value row.
		static bool IsSetVariableLabel(Graph g, Pin p)
		{
			if (p.Owner.Kind != .Set || p.Name != "target" || !p.IsInput)
				return false;
			return !g.IsLinked(p) && !p.Default.IsEmpty && p.Owner.FindInput("value") != null;
		}


		float InlineFieldWidth(Pin p)
		{
			float tw = Gui.CalcTextSize(p.Default).x;
			return Math.Clamp(tw + 18, 44, 260);
		}

		void GetDisplayTitle(Graph g, Node node, String title)
		{
			switch (node.Kind)
			{
			case .Set:
				// UE: "SET", with the compound operator when it isn't a plain assignment.
				title.Append("SET");
				if (node.Text != "=")
					title.AppendF(" ({})", node.Text);
				let target = node.FindInput("target");
				if (target != null && node.FindInput("value") == null && !g.IsLinked(target) && !target.Default.IsEmpty)
					title.AppendF("  {}", target.Default);
			case .LocalVar:
				title.AppendF("Local {}", node.Text);
			case .Return:
				title.Append("Return");
			case .ForEach:
				title.AppendF("For Each ({} {})", node.Text2, node.Text);
			case .Call:
				node.GetTitle(title);
				if (node.NullCond)
					title.Append(" (?.)");
			case .Entry:
				title.Append(node.Text);
			default:
				node.GetTitle(title);
			}
		}

		/// UE's grey "Receiver is X" line under a call's title.
		void GetSubtitle(Graph g, Node node, String sub)
		{
			if (node.Kind == .Entry && g.CondPath != null)
			{
				// A method inside `#if` arms: the condition, and whether this build uses it.
				sub.AppendF("#{}  ({})", g.CondPath, Preprocessor.IsActive(g.CondPath) ? "active" : "inactive in this build");
				return;
			}
			if (node.Kind == .LocalVar)
			{
				// `const int` / `ref FPage`: the modifier in front of the type.
				if (node.Alloc != null && !node.Alloc.IsEmpty)
					sub.AppendF("{} ", node.Alloc);
				if (!node.Text2.IsEmpty)
					sub.Append(node.Text2);
				// `let` / `var`: the type it takes from its value, so a type changed upstream
				// (the Construct it holds, a function's return type) shows on the node.
				if (node.Text2 == "let" || node.Text2 == "var")
				{
					let v = node.FindOutput("variable");
					if (v != null && !NodeMenu.IsWild(v.TypeName))
						sub.AppendF(" ({})", v.TypeName);
				}
				return;
			}
			if (node.Kind == .Flow)
			{
				if (!node.Text2.IsEmpty)
					sub.Append(node.Text2);
				return;
			}
			sCaptureGraph = g;
			if (LifetimeSubtitle(node, sub))
				return;
			if (node.Kind != .Call)
				return;
			defer AppendOverload(g, node, sub);
			if (node.Binding == .Static)
			{
				// "Receiver is Console": static, so the type is the fixed receiver and there is no Receiver pin.
				StringView owner = (node.Qualifier != null && !node.Qualifier.IsEmpty) ? (StringView)node.Qualifier : (StringView)(node.OwnerType ?? "");
				if (!owner.IsEmpty)
					sub.AppendF("Receiver is {}", owner);
				return;
			}
			let target = node.FindInput("target");
			if (target == null)
				return;
			// The class that declares the function ("Receiver is Actor").
			StringView name = (node.Binding == .Instance && node.OwnerType != null) ? (StringView)node.OwnerType : (StringView)target.TypeName;
			if (name.IsEmpty && !g.IsLinked(target) && !target.Default.IsEmpty && target.Default[0].IsUpper)
				name = target.Default;
			if (!name.IsEmpty)
				sub.AppendF("Receiver is {}", name);
		}

		/// A function with several overloads names the one the node calls: "WriteLine(StringView)"
		/// (docs/Calls-and-Receivers.md#overloads; Properties > Call > Overload switches it).
		void AppendOverload(Graph g, Node node, String sub)
		{
			if (CallOverloads.Count(g, node, TypeService.Current) < 2)
				return;
			if (!sub.IsEmpty)
				sub.Append("  \u{00B7}  ");
			CallOverloads.PinSignature(node, sub);
		}

		/// The graph whose lambdas LifetimeSubtitle lists captures for.
		static Graph sCaptureGraph;

		/// The allocation / lifetime line under a lifetime node's title (docs/Lifetime-Nodes.md):
		/// how long the object lives, when the deferred code runs, which case a Result node tests.
		public static bool LifetimeSubtitle(Node node, String sub)
		{
			switch (node.Kind)
			{
			case .Construct:
				StringView alloc = (node.Alloc != null) ? (StringView)node.Alloc : "new";
				if (alloc == "scope")
					sub.Append("scope: freed when the block ends");
				else if (alloc == "scope::")
					sub.Append("scope::  freed when the method returns");
				else if (alloc == "new")
					sub.Append("new: you delete it");
				else if (alloc == "append")
					sub.Append("append: lives in this object");
				else if (alloc == "" || alloc == "." || alloc == "value")
					sub.Append("value");
				else
					sub.AppendF("{}: custom allocator", alloc);
				return true;
			case .Delete:
				if (node.Alloc != null && node.Alloc != "delete")
					sub.Append(node.Alloc);
				return true;
			case .Defer:
				StringView alloc = (node.Alloc != null) ? (StringView)node.Alloc : "defer";
				if (alloc == "defer")
					sub.Append("runs at the end of the block");
				else if (alloc == "defer::")
					sub.Append("runs when the method returns");
				else
					sub.AppendF("{}: runs at the end of that scope", alloc);
				return true;
			case .Using:
				sub.Append("disposed when Body ends");
				return true;
			case .ResultMatch:
				let p = node.FindOutput("payload");
				sub.AppendF("case .{}{}", node.Text, (p != null && p.OutName != null && !p.OutName.IsEmpty && p.Form == .Inline) ? scope:: $"(let {p.OutName})" : "");
				return true;
			case .Call:
				if (node.Text == "Try!" || node.Text == "TrySilent!")
				{
					sub.Append("returns early on error");
					return true;
				}
				return false;
			case .Scope:
				if (node.Attributes != null)
				{
					var a = StringView(node.Attributes);
					a.Trim();
					sub.AppendF("{}: ", a);
				}
				sub.Append("locals and scope values end with the block");
				return true;
			case .DoWhile:
				sub.Append("Body runs once, then while Condition");
				return true;
			case .Lambda:
				StringView alloc = (node.Alloc != null) ? (StringView)node.Alloc : "";
				if (!alloc.IsEmpty)
					sub.AppendF("{}{}", alloc, (alloc == "scope") ? ": freed when the block ends" : ((alloc == "new") ? ": you delete it" : ""));
				if (node.Text.IsEmpty)
					return !alloc.IsEmpty;
				List<String> caps = scope .();
				defer { ClearAndDeleteItems!(caps); }
				sCaptureGraph?.GetCaptures(node, caps);
				if (!sub.IsEmpty)
					sub.Append(" | ");
				if (caps.IsEmpty)
					sub.Append("captures nothing");
				else
				{
					sub.AppendF("captures{} ", (node.Attributes == "[&]") ? " by ref" : "");
					for (let c in caps)
						sub.AppendF("{}{}", (@c.Index > 0) ? ", " : "", c);
				}
				return true;
			case .LocalFunc:
				sub.Append(node.Text2);
				return true;
			default:
				return false;
			}
		}

		// ------------------------------------------------------------------ layout

		NodeLay LayoutNode(GraphTab tab, Graph graph, Node node, int index)
		{
			while (mLayPool.Count <= index)
				mLayPool.Add(new NodeLay());
			let L = mLayPool[index];
			L.Reset();
			L.Node = node;
			L.Selected = tab.IsSelected(node.Id);
			mLayById[node.Id] = L;

			float fh = mFontSize;
			float rowH = RowH;
			GetDisplayTitle(graph, node, L.Title);
			L.Header = HeaderFor(graph, node);

			mLeft.Clear();
			mRight.Clear();
			for (let p in node.Inputs)
				if (!HidePin(graph, p))
					mLeft.Add(p);
			for (let p in node.Outputs)
				if (!HidePin(graph, p))
					mRight.Add(p);

			L.SymbolScale = 1.8f;
			if ((node.Kind == .Get && node.FindInput("target") == null) || node.Kind == .This || node.Kind == .Base)
				L.Shape = .Getter;
			else if (node.Kind == .Operator)
				L.Shape = .Operator;
			else if (node.Kind == .Call && node.IsPure && mLeft.IsEmpty)
			{
				// UE's compact pure node: no header, the name in the middle, output on the right.
				L.Shape = .Operator;
				L.SymbolScale = 1.15f;
			}
			else
				L.Shape = .Normal;
			bool compact = L.Shape == .Operator && node.Kind != .Operator;
			Pin setTarget = (node.Kind == .Set) ? node.FindInput("target") : null;
			bool setLabel = setTarget != null && IsSetVariableLabel(graph, setTarget);

			float titleW = Gui.CalcTextSize(L.Title).x;

			if (L.Shape == .Getter)
			{
				L.HeaderH = 0;
				L.W = Math.Max(14 + titleW + 34, 70);
				L.H = rowH + 4;
				for (let p in node.Outputs)
				{
					PinLay pl = default;
					pl.Pin = p;
					pl.Node = L;
					pl.Visible = (p == node.Result) || (node.Result == null && @p.Index == 0);
					pl.Off = .(L.W - 12, L.H * 0.5f);
					AddPin(pl);
				}
				for (let p in node.Inputs)
				{
					PinLay pl = default;
					pl.Pin = p;
					pl.Node = L;
					pl.Off = .(0, L.H * 0.5f);
					AddPin(pl);
				}
			}
			else
			{
				if (L.Shape == .Normal)
				{
					GetSubtitle(graph, node, L.Subtitle);
					L.HeaderH = fh + 10;
					if (!L.Subtitle.IsEmpty)
						L.HeaderH += fh * 0.85f + 2;
				}
				else
					L.HeaderH = 0;
				float startY = L.HeaderH + ((L.Shape == .Normal) ? 6 : 6);

				// Input rows
				float leftMax = 0;
				for (let p in mLeft)
				{
					PinLay pl = default;
					pl.Pin = p;
					pl.Node = L;
					pl.Visible = true;
					pl.RowY = startY + @p.Index * rowH;
					pl.Off = .(12, pl.RowY + rowH * 0.5f);
					pl.LabelX = 24;
					pl.LabelText = (setLabel && p.Name == "value") ? StringView(setTarget.Default) : StringView(p.Label);
					pl.LabelW = pl.LabelText.IsEmpty ? 0 : Gui.CalcTextSize(pl.LabelText).x;
					float w = 24 + pl.LabelW;
					if (IsSelfTarget(graph, p))
					{
						// UE: an unconnected Target reads "self"; there is nothing to type.
						pl.SelfHint = true;
						pl.FieldX = 24 + ((pl.LabelW > 0) ? pl.LabelW + 6 : 0);
						w = pl.FieldX + Gui.CalcTextSize("this").x;
					}
					else if (p.Kind == .Data && !graph.IsLinked(p))
					{
						pl.VKind = PinValue.KindOf(p.TypeName, p.Default, p.Name, TypeService.Current);
						pl.Check = (pl.VKind == .Bool) || (pl.VKind == .Expr && IsBoolLiteral(p));
						if (pl.Check)
							pl.FieldW = fh + 6;
						else if (PinValueEditor.Handles(pl.VKind))
							pl.FieldW = PinValueEditor.Width(pl.VKind, p, TypeService.Current);
						else if (pl.VKind == .None)
							pl.FieldW = p.Default.IsEmpty ? 0 : (Gui.CalcTextSize(p.Default).x + 4);
						else if (pl.VKind == .Custom)
						{
							// Grid units at scale 1 (the layout font); DrawPin draws at the zoomed size and
							// shortens the value with an ellipsis before the badge.
							float valueW = Math.Min(Gui.CalcTextSize(p.Default).x, cExpressionValueMaxW);
							pl.FieldW = valueW + Gui.CalcTextSize(cExpressionBadge).x + 22;
						}
						else
							pl.FieldW = InlineFieldWidth(p);
						pl.FieldX = 24 + ((pl.LabelW > 0) ? pl.LabelW + 6 : 0);
						w = pl.FieldX + pl.FieldW;
					}
					leftMax = Math.Max(leftMax, w + 10);
					AddPin(pl);
				}
				// Output rows (x filled in once the width is known)
				float rightMax = 0;
				int firstRight = mPins.Count;
				for (let p in mRight)
				{
					PinLay pl = default;
					pl.Pin = p;
					pl.Node = L;
					pl.Visible = true;
					pl.RowY = startY + @p.Index * rowH;
					pl.LabelText = compact ? "" : StringView(p.Label);
					// A Switch on an enum keeps its cases as `.Name` for the generated code; the pin shows the plain name.
					if (!compact && node.Kind == .Switch && p.Kind == .Exec && pl.LabelText.Length > 1 && pl.LabelText[0] == '.')
						pl.LabelText = pl.LabelText.Substring(1);
					pl.LabelW = pl.LabelText.IsEmpty ? 0 : Gui.CalcTextSize(pl.LabelText).x;
					rightMax = Math.Max(rightMax, 24 + pl.LabelW + 10);
					AddPin(pl);
				}
				int rows = Math.Max(mLeft.Count, mRight.Count);
				float y = startY + rows * rowH;

				if (L.Shape == .Operator)
				{
					L.SymbolSize = fh * L.SymbolScale;
					float symW = Gui.CalcTextSize(L.Title).x * L.SymbolScale + 20;
					L.W = Math.Max(leftMax + symW + rightMax, 90);
					L.H = Math.Max(y + 6, L.SymbolSize + 20);
					if (compact)
						L.H = Math.Max(L.H, rowH + 14);
				}
				else
				{
					float iconW = HeaderIconW(node);
					L.W = Math.Max(leftMax + rightMax + 16, titleW + 40 + iconW);
					if (!L.Subtitle.IsEmpty)
						L.W = Math.Max(L.W, Gui.CalcTextSize(L.Subtitle).x * 0.85f + 40 + iconW);
					L.W = Math.Max(L.W, 110);

					// Body text for code-like nodes (below the pins).
					if (node.Kind == .Code || node.Kind == .Expr || (node.Kind == .For && !node.IsCountingLoop))
					{
						BuildCodeLines(node, L.CodeLines);
						if (mMono != null)
							Gui.igPushFont(mMono, 0);
						float codeW = 0;
						for (let line in L.CodeLines)
							codeW = Math.Max(codeW, Gui.CalcTextSize(line).x);
						if (mMono != null)
							Gui.igPopFont();
						L.CodeY = y + 2;
						L.CodeH = L.CodeLines.Count * fh + 8;
						y += L.CodeH + 4;
						L.W = Math.Max(L.W, codeW + 24);
					}

					// A Math Expression: the expression is a field in the body (also in Properties).
					if (node.Kind == .MathExpr)
					{
						L.MathField = true;
						L.CodeY = y + 2;
						L.CodeH = fh + 8;
						y += L.CodeH + 6;
						if (mMono != null)
							Gui.igPushFont(mMono, MathFieldFont(1)); // the size the field is drawn at
						float textW = Gui.CalcTextSize(node.Text.IsEmpty ? "a * b + 1" : node.Text).x;
						if (mMono != null)
							Gui.igPopFont();
						L.W = Math.Max(L.W, Math.Min(textW + 32, 720 * Look.Scale)); // a long formula makes a wide node
						L.W = Math.Max(L.W, 170);
					}

					// "Add pin" affordance like Blueprint's variadic nodes, shown when selected.
					if ((node.Kind == .Call || node.Kind == .Index) && L.Selected)
					{
						L.ShowArgs = true;
						L.ArgsY = y + 2;
						y += fh + 8;
					}

					if (!node.IsPure && node != graph.Entry && node.ExecIn != null && !graph.IsLinked(node.ExecIn))
					{
						L.Orphan = true;
						L.OrphanY = y + 2;
						y += fh * 0.85f + 8;
						L.W = Math.Max(L.W, Gui.CalcTextSize("Not connected: no code yet").x * 0.85f + 24);
					}
					L.H = y + 6;
				}

				for (int i = firstRight; i < mPins.Count; i++)
				{
					var pl = ref mPins[i];
					pl.Off = .(L.W - 12, pl.RowY + rowH * 0.5f);
					pl.LabelX = L.W - 24;
				}
				// Hidden pins still need an anchor for any wire.
				for (let p in node.Inputs)
					if (!mPinIndex.ContainsKey(p.Id))
					{
						PinLay pl = default;
						pl.Pin = p;
						pl.Node = L;
						pl.Off = .(0, L.HeaderH * 0.5f);
						AddPin(pl);
					}
				for (let p in node.Outputs)
					if (!mPinIndex.ContainsKey(p.Id))
					{
						PinLay pl = default;
						pl.Pin = p;
						pl.Node = L;
						pl.Off = .(L.W, L.HeaderH * 0.5f);
						AddPin(pl);
					}
			}

			// Error (red) or warning (yellow) badge under the node, UE style; an error wins.
			if (mNodeErrors.TryGetValue(node.Id, let err))
			{
				L.Error = err;
				L.ErrorW = Math.Max(L.W, 240);
				L.ErrorTextH = Gui.igCalcTextSize(err.Ptr, err.Ptr + err.Length, false, L.ErrorW - 16).y;
				L.TargetBad = node.Kind == .Call && err.StartsWith("Receiver must be");
			}
			else if (mNodeWarnings.TryGetValue(node.Id, let warn))
			{
				L.Warning = warn;
				L.ErrorW = Math.Max(L.W, 240);
				L.WarningTextH = Gui.igCalcTextSize(warn.Ptr, warn.Ptr + warn.Length, false, L.ErrorW - 16).y;
			}
			return L;
		}

		void AddPin(PinLay pl)
		{
			mPinIndex[pl.Pin.Id] = mPins.Count;
			mPins.Add(pl);
		}

		/// Splits a code node's text into display lines, removing the common indentation of
		/// continuation lines (the first line has none). At most 14 lines plus "...".
		static void BuildCodeLines(Node node, List<String> outLines)
		{
			int minIndent = int.MaxValue;
			int lineNo = 0;
			for (let line in node.Text.Split('\n'))
			{
				if (lineNo++ == 0)
					continue;
				int col = 0;
				bool blank = true;
				for (let c in line.RawChars)
				{
					if (c == '\t') { col += 4; continue; }
					if (c == ' ') { col++; continue; }
					if (c == '\r') continue;
					blank = false;
					break;
				}
				if (!blank)
					minIndent = Math.Min(minIndent, col);
			}
			if (minIndent == int.MaxValue)
				minIndent = 0;
			lineNo = 0;
			for (let line in node.Text.Split('\n'))
			{
				if (outLines.Count == 14)
				{
					outLines.Add(new String("..."));
					break;
				}
				String disp = new String(line);
				disp.TrimEnd();
				disp.Replace("\t", "    ");
				if (lineNo > 0)
				{
					int remove = 0;
					while (remove < minIndent && remove < disp.Length && disp[remove] == ' ')
						remove++;
					disp.Remove(0, remove);
				}
				outLines.Add(disp);
				lineNo++;
			}
		}

		bool TryGetPin(int32 pinId, out PinLay pl)
		{
			if (mPinIndex.TryGetValue(pinId, let idx))
			{
				pl = mPins[idx];
				return true;
			}
			pl = default;
			return false;
		}

		ImVec2 PinScreen(GraphTab tab, PinLay pl) => tab.GridToScreen(pl.Node.Node.X + pl.Off.x, pl.Node.Node.Y + pl.Off.y);

		// ------------------------------------------------------------------ draw

		/// How many times a graph was drawn (the openall self test checks every tab got drawn).
		public static int DrawCount;

		public void Draw(GraphTab tab, MethodGraph mg)
		{
			DrawCount++;
			let graph = mg.Graph;
			// The code as read gets checked once (GraphValidator + the generator's checks), so its
			// problems show on the nodes before any edit.
			mApp.EnsureChecked(mg);
			mCommitted = false;
			mPendingArgNode = 0;
			mPendingDrop = -1;

			if (graph.Serial != tab.LastGraphSerial)
			{
				tab.LastGraph = graph;
				tab.LastGraphSerial = graph.Serial;
				tab.CancelInteraction();
			}

			mFont = Gui.igGetFont();
			mFontSize = Gui.igGetFontSize();
			mMono = Host.vbh_get_mono_font();

			tab.CanvasOrigin = Gui.igGetCursorScreenPos();
			var avail = Gui.igGetContentRegionAvail();
			avail.x = Math.Max(avail.x, 1);
			avail.y = Math.Max(avail.y, 1);
			tab.CanvasSize = avail;
			let origin = tab.CanvasOrigin;
			var mouse = Gui.igGetMousePos();
			if (SelfTestMouse.x > -1e30f)
				mouse = SelfTestMouse; // a capture holds the pointer on a spot (the real pointer cannot be moved)

			// Re-select nodes after a regeneration; drop selections of nodes that are gone.
			if (!tab.ReselectKeys.IsEmpty)
			{
				KeyAssigner.Assign(graph);
				tab.ClearSelection();
				for (let key in tab.ReselectKeys)
					for (let n in graph.Nodes)
						if (n.Key == key)
							tab.AddToSelection(n.Id);
				ClearAndDeleteItems!(tab.ReselectKeys);
			}
			for (int i = tab.SelectedNodes.Count - 1; i >= 0; i--)
				if (graph.FindNode(tab.SelectedNodes[i]) == null)
					tab.SelectedNodes.RemoveAt(i);
			for (int i = tab.SelectedLinks.Count - 1; i >= 0; i--)
				if (graph.FindLink(tab.SelectedLinks[i]) == null)
					tab.SelectedLinks.RemoveAt(i);

			// Comment boxes and reroute knots of this graph (layout only, owned by the document).
			GatherComments(tab);
			ResolveReroutes(tab, graph);
			for (int i = tab.SelectedComments.Count - 1; i >= 0; i--)
				if (FindComment(tab.SelectedComments[i]) == null)
					tab.SelectedComments.RemoveAt(i);
			if (tab.SelectedKnot.IsValid && FindKnot(tab.SelectedKnot) == null)
				tab.SelectedKnot = default;

			// The canvas item: gives ImGui an id, hover state and a drag-drop target. Widgets
			// drawn inside nodes later overlap it and win the hover.
			uint32 canvasId = Gui.igGetID_Str("##vbcanvas");
			Gui.igSetNextItemAllowOverlap();
			Gui.igInvisibleButton("##vbcanvas", avail, ButtonFlags.MouseButtonLeft | ButtonFlags.MouseButtonRight | ButtonFlags.MouseButtonMiddle);
			bool canvasHovered = Gui.igIsItemHovered(0);
			bool canvasActivated = Gui.igIsItemActivated();
			// Node hotkeys are plain letters: only while this Sheet has the keyboard (no text field active).
			mCanvasKeys = Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows) && (!Gui.igIsAnyItemActive() || Gui.igIsItemActive());
			if (canvasHovered)
				Gui.igSetItemKeyOwner_Nil(Key.MouseWheelY);
			HandleDragDrop(tab);
			// Keep keyboard navigation from also acting on the canvas shortcuts (Home would
			// otherwise move the nav cursor to the tab bar).
			if (Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows) && !Gui.igIsAnyItemActive())
			{
				Gui.igSetKeyOwner(Key.Home, canvasId, 0);
				Gui.igSetKeyOwner(Key.Delete, canvasId, 0);
				Gui.igSetKeyOwner(Key.Backspace, canvasId, 0);
			}

			bool mouseInCanvas = Canvas.RectContains(origin, origin + avail, mouse);
			bool windowHovered = Gui.igIsWindowHovered(HoveredFlags.ChildWindows | HoveredFlags.AllowWhenBlockedByActiveItem);

			// ---- Zoom (wheel, anchored on the cursor)
			if (mouseInCanvas && windowHovered)
			{
				let keyData = Gui.igGetKeyData_Key(Key.MouseWheelY);
				float wheel = (keyData != null) ? keyData.AnalogValue : 0;
				if (wheel > 0)
					tab.SetZoomLevel(tab.ZoomLevel + 1, mouse);
				else if (wheel < 0)
					tab.SetZoomLevel(tab.ZoomLevel - 1, mouse);
			}

			// ---- Continuous drags that move the view or nodes (before layout, so this frame shows them)
			UpdateDrag(tab, graph, mouse);
			tab.LastMouse = mouse;

			// ---- Layout
			for (let v in mNodeErrors.Values)
				delete v;
			mNodeErrors.Clear();
			for (let v in mNodeWarnings.Values)
				delete v;
			mNodeWarnings.Clear();
			// Graphs the code generator or GraphValidator refused (nothing was written): reasons on the nodes.
			for (let e in graph.Errors)
				if (!mNodeErrors.ContainsKey(e.NodeId))
					mNodeErrors[e.NodeId] = new String(e.Message);
			for (let e in graph.Warnings)
				if (!mNodeWarnings.ContainsKey(e.NodeId))
					mNodeWarnings[e.NodeId] = new String(e.Message);
			// Code the parser could not read (Node.Error): the same red border and banner.
			for (let n in graph.Nodes)
				if (n.Error != null && !mNodeErrors.ContainsKey(n.Id))
					mNodeErrors[n.Id] = new String(n.Error);
			mApp.GetNodeDiagnostics(mg, mNodeErrors, mNodeWarnings);
			// Math Expressions: pin types follow the wires, and what is wrong shows on the node
			// whether or not it is connected yet.
			for (let n in graph.Nodes)
			{
				if (n.Kind != .MathExpr)
					continue;
				let parsed = MathExpression.Parse(n.Text);
				defer delete parsed;
				MathExpression.UpdateTypes(graph, n, parsed.IsValid ? parsed : null);
				if (mNodeErrors.ContainsKey(n.Id))
					continue;
				String why = scope .();
				MathExpression.Problem(graph, n, why);
				if (!why.IsEmpty)
					mNodeErrors[n.Id] = new String(why);
			}
			mLayById.Clear();
			mPins.Clear();
			mPinIndex.Clear();
			for (let node in graph.Nodes)
				LayoutNode(tab, graph, node, @node.Index);

			// Auto-layout used estimated sizes; now that every node is measured, redo it with
			// real sizes so nothing overlaps.
			if (graph.AutoLaidOut)
			{
				AutoLayout.Measured.Clear();
				for (let n in graph.Nodes)
				{
					let L = mLayById[n.Id];
					AutoLayout.Measured[n.Id] = (L.W, L.H);
				}
				AutoLayout.LayoutAll(graph);
				AutoLayout.Measured.Clear();
				graph.AutoLaidOut = false;
				tab.NeedsFocus = true;
				// (Not a user layout change: merely viewing a file must not write a side file.)
			}

			// First frame for this tab (or Home): bring the entry node into view at 1:1.
			if (tab.NeedsFocus && graph.Entry != null)
			{
				tab.ZoomLevel = Canvas.DefaultZoomLevel;
				tab.Pan = .(-graph.Entry.X + 60, -graph.Entry.Y + avail.y * 0.25f);
				tab.NeedsFocus = false;
			}
			tab.ApplyPendingCenter();
			tab.StepViewAnim();

			// Draw order: selected nodes on top.
			mOrder.Clear();
			for (let node in graph.Nodes)
			{
				let L = mLayById[node.Id];
				if (!L.Selected)
					mOrder.Add(L);
			}
			for (let node in graph.Nodes)
			{
				let L = mLayById[node.Id];
				if (L.Selected)
					mOrder.Add(L);
			}
			float z = tab.Zoom;
			for (let L in mOrder)
			{
				let p0 = tab.GridToScreen(L.Node.X, L.Node.Y);
				var a = p0;
				var b = p0 + ImVec2(L.W, L.H) * z;
				if (L.Error != null || L.Warning != null)
				{
					PlaceBadge(tab, L, origin, origin + avail);
					a.y = Math.Min(a.y, L.BadgeY);
					b.x = Math.Max(b.x, p0.x + L.ErrorW * z);
					b.y = Math.Max(b.y, L.BadgeY + BadgeH(L, z));
				}
				L.Visible = Canvas.RectsOverlap(a - .(20, 20), b + .(20, 20), origin, origin + avail);
			}

			// ---- Hover
			ComputeHover(tab, graph, mouse, mouseInCanvas && (canvasHovered || tab.Mode != .None));

			// ---- Draw
			let dl = Gui.igGetWindowDrawList();
			Gui.igPushClipRect(origin, origin + avail, true);
			Canvas.Background(dl, origin, avail, tab.Pan, z);
			DrawWatermark(tab, mg, dl);
			DrawComments(tab, dl);
			DrawWires(tab, graph, dl, mouse);
			DrawKnots(tab, graph, dl);
			DrawNodes(tab, graph, dl);
			DrawBubbles(tab, mg, graph, dl, mouse);
			DrawOverlay(tab, graph, dl, mouse);
			DrawDebugOverlay(tab, mg, dl); // breakpoints, the stopped node, values (DebugCanvas.bf)
			Gui.igPopClipRect();
			DrawFindBox(tab, graph);
			DrawNavToast(tab, dl);
			DrawNavButtons(tab, mg, graph);
			// Minimap in a child window so it sits above the nodes' inline widgets.
			if (Prefs.ShowMinimap)
				DrawMinimapWindow(tab, graph, mouse, mouseInCanvas);
			else
				mMinimapDrag = false;

			if (mCommitted)
				return;

			// ---- Mouse buttons, keyboard, context popups (graph mutations happen here)
			if (!mMinimapDrag && !(mNavOver && tab.Mode == .None))
				HandleMouse(tab, mg, mouse, canvasActivated, mouseInCanvas);
			if (mCommitted)
				return;
			HandleKeyboard(tab, mg);
			if (mCommitted)
				return;
			DrawContextPopups(tab, mg);
			if (mCommitted)
				return;

			if (mPendingDrop >= 0)
			{
				mApp.DropMember(tab, mPendingDrop, mPendingDropPos);
				mPendingDrop = -1;
				return;
			}

			if (mPendingArgNode != 0)
			{
				let n = graph.FindNode(Math.Abs(mPendingArgNode));
				int32 pending = mPendingArgNode;
				mPendingArgNode = 0;
				if (n != null)
				{
					if (pending > 0)
						mApp.AddArgument(n);
					else
						mApp.RemoveArgument(n);
					return;
				}
			}
		}

		void UpdateDrag(GraphTab tab, Graph graph, ImVec2 mouse)
		{
			let delta = mouse - tab.LastMouse;
			switch (tab.Mode)
			{
			case .RightPending:
				let d = mouse - tab.PressPos;
				if (d.x * d.x + d.y * d.y > 16)
				{
					tab.Mode = .Pan;
					tab.Pan = tab.Pan + (mouse - tab.PressPos) * (1.0f / tab.Zoom);
				}
			case .Pan:
				tab.Pan = tab.Pan + delta * (1.0f / tab.Zoom);
				Gui.igSetMouseCursor(MouseCursor.ResizeAll);
			case .MoveNodes:
				let d = mouse - tab.PressPos;
				if (!tab.Moved && d.x * d.x + d.y * d.y < 9)
					break;
				if (!tab.Moved)
					mApp.BeginEdit(); // one undo step per drag
				tab.Moved = true;
				float dx = d.x / tab.Zoom;
				float dy = d.y / tab.Zoom;
				for (let kv in tab.DragStart)
				{
					let n = graph.FindNode(kv.key);
					if (n == null)
						continue;
					// Snap to UE's 16-unit grid while dragging.
					n.X = Canvas.SnapIf(kv.value.x + dx);
					n.Y = Canvas.SnapIf(kv.value.y + dy);
					n.HasPos = true;
				}
				for (let kv in tab.DragCommentStart)
				{
					let c = FindComment(kv.key);
					if (c == null)
						continue;
					c.X = Canvas.SnapIf(kv.value.x + dx);
					c.Y = Canvas.SnapIf(kv.value.y + dy);
				}
			case .ResizeComment:
				let c = FindComment(tab.DragComment);
				if (c != null)
				{
					let d = mouse - tab.PressPos;
					if (!tab.Moved && d.x * d.x + d.y * d.y >= 9)
					{
						tab.Moved = true;
						mApp.BeginEdit(); // one undo step per resize
					}
					c.W = Math.Max(Canvas.Snap(tab.DragVec.x + d.x / tab.Zoom), 96);
					c.H = Math.Max(Canvas.Snap(tab.DragVec.y + d.y / tab.Zoom), CommentTitleH + 32);
				}
				Gui.igSetMouseCursor(8 /* ResizeNWSE */);
			case .MoveKnot:
				let route = FindKnot(tab.DragKnot);
				if (route != null)
				{
					let d = mouse - tab.PressPos;
					if (tab.Moved || d.x * d.x + d.y * d.y >= 9)
					{
						if (!tab.Moved)
							mApp.BeginEdit(); // one undo step per knot drag
						tab.Moved = true;
						var pt = ref route.Points[tab.DragKnot.Index];
						pt.X = tab.DragVec.x + d.x / tab.Zoom;
						pt.Y = tab.DragVec.y + d.y / tab.Zoom;
					}
				}
			default:
			}
		}

		void ComputeHover(GraphTab tab, Graph graph, ImVec2 mouse, bool enabled)
		{
			mHoverPin = 0;
			mHoverNode = 0;
			mHoverLink = 0;
			mHoverLinkSegment = 0;
			mHoverKnot = default;
			mHoverComment = 0;
			mHoverCommentResize = 0;
			if (!enabled)
				return;
			float z = tab.Zoom;
			float pinRadius = Math.Max(8, 9 * z);
			// Topmost first.
			for (int oi = mOrder.Count - 1; oi >= 0; oi--)
			{
				let L = mOrder[oi];
				if (!L.Visible)
					continue;
				let p0 = tab.GridToScreen(L.Node.X, L.Node.Y);
				let p1 = p0 + ImVec2(L.W, L.H) * z;
				if (!Canvas.RectContains(p0 - .(pinRadius, 0), p1 + .(pinRadius, 0), mouse))
					continue;
				// Pins (the circle with a generous radius, or the pin's label row)
				for (let n in L.Node.Inputs)
					if (HitPin(tab, n, mouse, pinRadius, p0, z))
						return;
				for (let n in L.Node.Outputs)
					if (HitPin(tab, n, mouse, pinRadius, p0, z))
						return;
				if (Canvas.RectContains(p0, p1, mouse))
				{
					mHoverNode = L.Node.Id;
					return;
				}
			}
			// Reroute knots
			float knotR = Math.Max(7, 8 * z);
			for (let route in mRoutes.Values)
			{
				for (let pt in route.Points)
				{
					let c = tab.GridToScreen(pt.X, pt.Y);
					let d = mouse - c;
					if (d.x * d.x + d.y * d.y <= knotR * knotR)
					{
						mHoverKnot = .(route.FromPinId, route.ToPinId, (int32)@pt.Index);
						return;
					}
				}
			}
			// Comment resize corners (topmost comment first)
			for (int ci = mComments.Count - 1; ci >= 0; ci--)
			{
				let c = mComments[ci];
				let p1 = tab.GridToScreen(c.X + c.W, c.Y + c.H);
				float hs = Math.Max(10, 16 * z);
				if (Canvas.RectContains(p1 - .(hs, hs), p1, mouse))
				{
					mHoverComment = c.Id;
					mHoverCommentResize = c.Id;
					return;
				}
			}
			// Wires
			float best = 6;
			ImVec2[64] pts = ?;
			for (let link in graph.Links)
			{
				if (!TryGetPin(link.From.Id, var a))
					continue;
				if (!TryGetPin(link.To.Id, var b))
					continue;
				int count = WirePoints(tab, link, PinScreen(tab, a), PinScreen(tab, b), &pts[0], 64);
				for (int seg < count - 1)
				{
					float d = Canvas.DistToWire(mouse, pts[seg], pts[seg + 1], z);
					if (d < best)
					{
						best = d;
						mHoverLink = link.Id;
						mHoverLinkSegment = (int32)seg;
					}
				}
			}
			if (mHoverLink != 0)
				return;
			// Comment title bars
			for (int ci = mComments.Count - 1; ci >= 0; ci--)
			{
				let c = mComments[ci];
				let p0 = tab.GridToScreen(c.X, c.Y);
				let p1 = tab.GridToScreen(c.X + c.W, c.Y + CommentTitleH);
				if (Canvas.RectContains(p0, p1, mouse))
				{
					mHoverComment = c.Id;
					return;
				}
			}
		}

		bool HitPin(GraphTab tab, Pin p, ImVec2 mouse, float radius, ImVec2 nodePos, float z)
		{
			if (!TryGetPin(p.Id, let pl) || !pl.Visible)
				return false;
			let c = PinScreen(tab, pl);
			let d = mouse - c;
			if (d.x * d.x + d.y * d.y <= radius * radius)
			{
				mHoverPin = p.Id;
				return true;
			}
			if (pl.Node.Shape == .Getter)
				return false;
			float rowTop = nodePos.y + pl.RowY * z;
			float rowBot = rowTop + RowH * z;
			if (mouse.y < rowTop || mouse.y >= rowBot)
				return false;
			float x0;
			float x1;
			if (p.IsInput)
			{
				x0 = nodePos.x;
				x1 = nodePos.x + (pl.LabelX + pl.LabelW + 4) * z;
			}
			else
			{
				x0 = nodePos.x + (pl.LabelX - pl.LabelW - 4) * z;
				x1 = nodePos.x + pl.Node.W * z;
			}
			if (mouse.x >= x0 && mouse.x < x1)
			{
				mHoverPin = p.Id;
				return true;
			}
			return false;
		}

		void Text(ImDrawList* dl, ImVec2 pos, float size, uint32 col, StringView text, ImFont* font = null, float wrap = 0)
		{
			if (size < 3.5f || text.IsEmpty)
				return;
			Gui.ImDrawList_AddText_FontPtr(dl, (font != null) ? font : mFont, size, pos, col, text.Ptr, text.Ptr + text.Length, wrap, null);
		}

		uint32 WireColor(Pin from) => (from.Kind == .Exec) ? Theme.WireExec : Theme.PinColor(from);

		void DrawWires(GraphTab tab, Graph graph, ImDrawList* dl, ImVec2 mouse)
		{
			float z = tab.Zoom;
			for (let link in graph.Links)
			{
				if (!TryGetPin(link.From.Id, var a))
					continue;
				if (!TryGetPin(link.To.Id, var b))
					continue;
				// Links being moved with Ctrl+drag are drawn to the mouse instead.
				if (tab.Mode == .Relink && tab.DragLinks.Contains(link.Id))
					continue;
				let from = PinScreen(tab, a);
				let to = PinScreen(tab, b);
				uint32 col = WireColor(link.From);
				float th = ((link.From.Kind == .Exec) ? 3.0f : 2.0f) * z;
				th = Math.Max(th, 1.0f);
				bool hot = a.Node.Selected || b.Node.Selected;
				if (!hot)
					col = Theme.WithAlpha(Theme.Mix(col, Gui.Color(0, 0, 0), 0.12f), 220);
				else
				{
					col = Theme.Lighten(col, 1.25f);
					th *= 1.35f;
				}
				if (tab.SelectedLinks.Contains(link.Id))
				{
					col = Theme.Mix(col, Theme.NodeSelected, 0.65f);
					th *= 1.3f;
				}
				if (link.Id == mHoverLink)
				{
					col = Theme.Lighten(Theme.WithAlpha(col, 255), 1.5f);
					th *= 1.5f;
				}
				ImVec2[64] pts = ?;
				int count = WirePoints(tab, link, from, to, &pts[0], 64);
				for (int seg < count - 1)
					Canvas.Wire(dl, pts[seg], pts[seg + 1], z, col, th);
			}
		}

		static int64 RouteKey(int32 fromPin, int32 toPin) => ((int64)fromPin << 32) | (int64)(uint32)toPin;

		/// The screen points a link passes through: its pins with any reroute knots in between.
		int WirePoints(GraphTab tab, Link link, ImVec2 from, ImVec2 to, ImVec2* outPts, int max)
		{
			int count = 0;
			outPts[count++] = from;
			if (mRoutes.TryGetValue(RouteKey(link.From.Id, link.To.Id), let route))
			{
				for (let pt in route.Points)
				{
					if (count >= max - 1)
						break;
					outPts[count++] = tab.GridToScreen(pt.X, pt.Y);
				}
			}
			outPts[count++] = to;
			return count;
		}

		/// Screen height of a node's error / warning badge (banner + wrapped text).
		float BadgeH(NodeLay L, float z) => (mFontSize + 6 + ((L.Error != null) ? L.ErrorTextH : L.WarningTextH) + 12) * z;

		/// Where the badge goes this frame: under the node, unless that covers another node or runs
		/// past the bottom of the canvas and the space above the node is free; then kept inside the
		/// visible canvas while the node is on screen (a fault on a short canvas stays readable).
		void PlaceBadge(GraphTab tab, NodeLay L, ImVec2 canvasMin, ImVec2 canvasMax)
		{
			float z = tab.Zoom;
			let p0 = tab.GridToScreen(L.Node.X, L.Node.Y);
			let p1 = p0 + ImVec2(L.W, L.H) * z;
			float h = BadgeH(L, z);
			float w = L.ErrorW * z;
			float gap = 4 * z;
			float below = p1.y + gap;
			float above = p0.y - gap - h;
			bool belowHits = BadgeHitsNode(tab, L, .(p0.x, below), .(p0.x + w, below + h));
			bool belowCut = below + h > canvasMax.y;
			float y = below;
			if (belowHits || belowCut)
			{
				bool aboveHits = BadgeHitsNode(tab, L, .(p0.x, above), .(p0.x + w, above + h));
				bool aboveCut = above < canvasMin.y;
				// Above wins when it is free, or when it is at least better than below.
				if (!aboveHits && !aboveCut)
					y = above;
				else if (!belowHits && belowCut && !aboveHits)
					y = above;
				else if (belowHits && !belowCut && !aboveHits && aboveCut)
					y = above;
			}
			// Clamp into the canvas while the node is visible, never over the node's own header.
			if (Canvas.RectsOverlap(p0, p1, canvasMin, canvasMax))
			{
				if (y + h > canvasMax.y)
					y = Math.Max(canvasMax.y - h, Math.Min(y, p0.y + L.HeaderH * z));
				if (y < canvasMin.y)
					y = canvasMin.y;
			}
			L.BadgeY = y;
		}

		bool BadgeHitsNode(GraphTab tab, NodeLay self, ImVec2 a, ImVec2 b)
		{
			for (let o in mOrder)
			{
				if (o == self)
					continue;
				let q0 = tab.GridToScreen(o.Node.X, o.Node.Y);
				let q1 = q0 + ImVec2(o.W, o.H) * tab.Zoom;
				if (Canvas.RectsOverlap(a, b, q0, q1))
					return true;
			}
			return false;
		}

		void DrawNodes(GraphTab tab, Graph graph, ImDrawList* dl)
		{
			mHoverExprPin = 0;
			float z = tab.Zoom;
			bool widgets = z >= 0.45f;
			if (widgets)
			{
				// PushFont takes the size before the display scale (FontScaleDpi): without the division the
				// inline fields drew their text 125% too large at a 125% display and cut it off.
				Gui.igPushFont(mFont, MathFieldFont(z));
				Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(4 * z, 3 * z));
				Gui.igPushStyleVar_Vec2(StyleVar.ItemSpacing, .(4 * z, 2 * z));
				Gui.igPushStyleVar_Vec2(StyleVar.ItemInnerSpacing, .(4 * z, 4 * z));
				Gui.igPushStyleVar_Float(StyleVar.FrameRounding, 3 * z);
				Gui.igPushStyleColor_U32(Col.FrameBg, Theme.InlineFieldBg);
			}
			for (let L in mOrder)
			{
				if (!L.Visible)
					continue;
				Gui.PushID(L.Node.Id);
				DrawNode(tab, graph, dl, L, widgets);
				Gui.PopID();
			}
			if (widgets)
			{
				Gui.igPopStyleColor(1);
				Gui.igPopStyleVar(4);
				Gui.igPopFont();
			}
		}

		void DrawNode(GraphTab tab, Graph graph, ImDrawList* dl, NodeLay L, bool widgets)
		{
			let node = L.Node;
			float z = tab.Zoom;
			float fh = mFontSize;
			let p0 = tab.GridToScreen(node.X, node.Y);
			let p1 = p0 + ImVec2(L.W, L.H) * z;
			float r = ((L.Shape == .Getter) ? L.H * 0.5f : 6) * z;
			bool hovered = mHoverNode == node.Id;

			// Soft drop shadow + body
			Gui.ImDrawList_AddRectFilled(dl, p0 + .(1 * z, 2 * z), p1 + .(6 * z, 8 * z), Gui.Color(0, 0, 0, 35), r + 4 * z, 0);
			Gui.ImDrawList_AddRectFilled(dl, p0 + .(2 * z, 3 * z), p1 + .(3 * z, 4 * z), Theme.NodeShadow, r, 0);
			Gui.ImDrawList_AddRectFilled(dl, p0, p1, Theme.NodeBody, r, 0);

			uint32 header = (L.Error != null) ? Theme.ErrorHeader : L.Header;
			if (L.Shape == .Normal)
			{
				// UE header: solid on the left, fading to transparent on the right.
				float hh = L.HeaderH * z;
				Gui.ImDrawList_AddRectFilled(dl, p0, .(p0.x + r, p0.y + hh), header, r, DrawFlags.RoundCornersTopLeft);
				uint32 fade = Theme.WithAlpha(header, 20);
				Gui.ImDrawList_AddRectFilledMultiColor(dl, .(p0.x + r, p0.y), .(p1.x - r, p0.y + hh), header, fade, fade, header);
				Gui.ImDrawList_AddLine(dl, .(p0.x + 1, p0.y + hh), .(p1.x - 1, p0.y + hh), Gui.Color(0, 0, 0, 120), Math.Max(1, z));
				// UE: a small kind icon left of the title.
				float iconW = HeaderIconW(node);
				if (iconW > 0)
					Text(dl, .(p0.x + 8 * z, p0.y + 5 * z), fh * z, Theme.WithAlpha(Theme.NodeTitle, 225), PinStyle.HeaderIcon(node));
				Text(dl, .(p0.x + (10 + iconW) * z, p0.y + 5 * z), fh * z, Theme.NodeTitle, L.Title);
				if (!L.Subtitle.IsEmpty)
					Text(dl, .(p0.x + (10 + iconW) * z, p0.y + (5 + fh + 1) * z), fh * 0.85f * z, Theme.NodeSubtitle, L.Subtitle);
			}
			else if (L.Shape == .Getter)
			{
				uint32 pc = (node.Result != null) ? Theme.PinColor(node.Result) : Theme.WildPin;
				// Faint type-coloured tint from the left, like UE's variable nodes.
				uint32 tint = Theme.WithAlpha(pc, 55);
				Gui.ImDrawList_AddRectFilled(dl, p0, .(p0.x + r, p1.y), tint, r, DrawFlags.RoundCornersTopLeft | DrawFlags.RoundCornersBottomLeft);
				Gui.ImDrawList_AddRectFilledMultiColor(dl, .(p0.x + r, p0.y), .(p1.x - r, p1.y),
					tint, Theme.WithAlpha(pc, 0), Theme.WithAlpha(pc, 0), tint);
				Text(dl, .(p0.x + 14 * z, p0.y + (L.H - fh) * 0.5f * z), fh * z, Gui.Color(235, 235, 235), L.Title);
			}
			else if (L.Shape == .Operator)
			{
				float ss = L.SymbolSize * z;
				float tw = Gui.CalcTextSize(L.Title).x * L.SymbolScale * z;
				if (node.Kind != .Operator)
				{
					// Compact pure call: a faint green wash like UE's pure function colour.
					uint32 wash = Theme.WithAlpha(Theme.HeaderPure, 70);
					Gui.ImDrawList_AddRectFilledMultiColor(dl, .(p0.x + r, p0.y + 1), .(p1.x - r, p1.y - 1), wash, Theme.WithAlpha(wash, 0), Theme.WithAlpha(wash, 0), wash);
				}
				Text(dl, .((p0.x + p1.x) * 0.5f - tw * 0.5f, (p0.y + p1.y) * 0.5f - ss * 0.5f), ss, Gui.Color(215, 215, 215), L.Title);
			}

			// Outline
			if (L.Error != null)
				Gui.ImDrawList_AddRect(dl, p0, p1, Theme.NodeError, r, Math.Max(1.5f, 2 * z), 0);
			else if (L.Warning != null)
				Gui.ImDrawList_AddRect(dl, p0, p1, Theme.WithAlpha(Theme.Warning, 200), r, Math.Max(1.2f, 1.5f * z), 0);
			else
				Gui.ImDrawList_AddRect(dl, p0, p1, hovered ? Gui.Color(90, 90, 90, 220) : Theme.NodeOutline, r, 1, 0);
			if (L.Selected)
			{
				float o = 1.5f * z;
				Gui.ImDrawList_AddRect(dl, p0 - .(o, o), p1 + .(o, o), Theme.NodeSelected, r + o, Math.Max(1.5f, 2.5f * z), 0);
			}

			// Pins
			bool details = z >= 0.3f;
			for (let p in node.Inputs)
				DrawPin(tab, graph, dl, node, p, p0, details, widgets);
			for (let p in node.Outputs)
				DrawPin(tab, graph, dl, node, p, p0, details, widgets);

			// Code body
			if (!L.CodeLines.IsEmpty && details)
			{
				let b0 = ImVec2(p0.x + 6 * z, p0.y + L.CodeY * z);
				let b1 = ImVec2(p1.x - 6 * z, p0.y + (L.CodeY + L.CodeH) * z);
				Gui.ImDrawList_AddRectFilled(dl, b0, b1, Gui.Color(0, 0, 0, 90), 3 * z, 0);
				float y = L.CodeY + 4;
				for (let line in L.CodeLines)
				{
					Text(dl, .(p0.x + 12 * z, p0.y + y * z), fh * z, (@line.Index == 14) ? Theme.TextDim : Theme.TextCode, line, mMono);
					y += fh;
				}
			}

			if (L.MathField && details)
				DrawMathField(graph, dl, node, L, p0, z, widgets);

			// "+ arg" / "- arg"
			if (L.ShowArgs && widgets)
			{
				Gui.igSetCursorScreenPos(.(p0.x + 10 * z, p0.y + L.ArgsY * z));
				if (Gui.SmallButton("+ arg"))
					mPendingArgNode = node.Id;
				if (node.ArgCount > 0)
				{
					Gui.SameLine();
					if (Gui.SmallButton("- arg"))
						mPendingArgNode = -node.Id;
				}
			}

			if (L.Orphan && details)
				Text(dl, .(p0.x + 10 * z, p0.y + L.OrphanY * z), fh * 0.85f * z, Theme.Warning, "Not connected: no code yet");

			// Error / warning badge under the node.
			if (L.Error != null)
			{
				let e0 = ImVec2(p0.x, L.BadgeY);
				float bannerH = (fh + 6) * z;
				let e1 = ImVec2(p0.x + L.ErrorW * z, e0.y + bannerH + (L.ErrorTextH + 12) * z);
				Gui.ImDrawList_AddRectFilled(dl, e0, e1, Gui.Color(30, 5, 5, 235), 4 * z, 0);
				Gui.ImDrawList_AddRectFilled(dl, e0, .(e1.x, e0.y + bannerH), Gui.Color(200, 30, 30), 4 * z, DrawFlags.RoundCornersTop);
				Text(dl, .(e0.x + 8 * z, e0.y + 3 * z), fh * z, Gui.Color(255, 255, 255), "ERROR!");
				if (details)
					Text(dl, .(e0.x + 8 * z, e0.y + bannerH + 6 * z), fh * z, Gui.Color(255, 120, 120), L.Error, null, (L.ErrorW - 16) * z);
				Gui.ImDrawList_AddRect(dl, e0, e1, Theme.NodeError, 4 * z, 1, 0);
			}
			else if (L.Warning != null)
			{
				// UE's yellow warning badge: the code is written, but look at this.
				let e0 = ImVec2(p0.x, L.BadgeY);
				float bannerH = (fh + 6) * z;
				let e1 = ImVec2(p0.x + L.ErrorW * z, e0.y + bannerH + (L.WarningTextH + 12) * z);
				Gui.ImDrawList_AddRectFilled(dl, e0, e1, Gui.Color(30, 26, 5, 235), 4 * z, 0);
				Gui.ImDrawList_AddRectFilled(dl, e0, .(e1.x, e0.y + bannerH), Gui.Color(190, 150, 20), 4 * z, DrawFlags.RoundCornersTop);
				Text(dl, .(e0.x + 8 * z, e0.y + 3 * z), fh * z, Gui.Color(20, 20, 20), "WARNING");
				if (details)
					Text(dl, .(e0.x + 8 * z, e0.y + bannerH + 6 * z), fh * z, Gui.Color(240, 210, 120), L.Warning, null, (L.ErrorW - 16) * z);
				Gui.ImDrawList_AddRect(dl, e0, e1, Theme.Warning, 4 * z, 1, 0);
			}
		}

		void DrawPin(GraphTab tab, Graph graph, ImDrawList* dl, Node node, Pin p, ImVec2 nodePos, bool details, bool widgets)
		{
			if (!TryGetPin(p.Id, let pl) || !pl.Visible)
				return;
			float z = tab.Zoom;
			float fh = mFontSize;
			let c = PinScreen(tab, pl);
			bool linked = graph.IsLinked(p);
			bool hovered = mHoverPin == p.Id;
			uint32 col = Theme.PinColor(p);
			bool badTarget = pl.Node.TargetBad && p.Name == "target" && p.IsInput;
			if (badTarget)
				col = Theme.NodeError;
			if (hovered)
				col = Theme.Lighten(col, 1.35f);
			float th = Math.Max(1.0f, 1.6f * z);
			if (p.Kind == .Exec)
				Canvas.ExecPin(dl, c, 6 * z, col, linked, th);
			else
			{
				float rr = 5 * z;
				float arrowX = p.IsInput ? (c.x - rr - 4 * z) : (c.x + rr + 4 * z);
				PinStyle.DrawData(dl, PinStyle.ShapeFor(p), c, rr, col, linked, arrowX, th);
			}
			if (hovered)
				Gui.ImDrawList_AddCircle(dl, c, 9 * z, Theme.WithAlpha(col, 90), 0, Math.Max(1, z));

			if (!details || pl.Node.Shape == .Getter)
				return;
			float rowTop = nodePos.y + pl.RowY * z;
			uint32 labelCol = hovered ? Gui.Color(255, 255, 255) : (badTarget ? Gui.Color(255, 120, 120) : Theme.PinLabel);
			if (pl.LabelW > 0)
			{
				float ty = rowTop + (RowH - fh) * 0.5f * z;
				if (p.IsInput)
					Text(dl, .(nodePos.x + pl.LabelX * z, ty), fh * z, labelCol, pl.LabelText);
				else
					Text(dl, .(nodePos.x + (pl.LabelX - pl.LabelW) * z, ty), fh * z, labelCol, pl.LabelText);
			}
			if (pl.SelfHint)
			{
				float ty = rowTop + (RowH - fh) * 0.5f * z;
				Text(dl, .(nodePos.x + pl.FieldX * z, ty), fh * z, badTarget ? Gui.Color(255, 120, 120) : Theme.TextDim, "this");
			}
			if (pl.FieldW > 0)
			{
				let fpos = ImVec2(nodePos.x + pl.FieldX * z, rowTop + 2 * z);
				if (pl.VKind == .None)
					Text(dl, fpos + ImVec2(2 * z, 3 * z), fh * z, Theme.TextDim, p.Default);
				else if (pl.VKind == .Custom)
				{
					// Not a plain literal of the pin's type (an expression): read-only, edited in Properties.
					// Widths are measured at the size drawn (fh * z) whatever font size is pushed, so the
					// value never runs under the badge.
					let f1 = fpos + ImVec2(pl.FieldW * z, (fh + 6) * z);
					Gui.ImDrawList_AddRectFilled(dl, fpos, f1, Theme.InlineFieldBg, 3 * z, 0);
					float drawScale = (fh * z) / Math.Max(Gui.igGetFontSize(), 1.0f);
					float bw = Gui.CalcTextSize(cExpressionBadge).x * drawScale;
					float bx = f1.x - bw - 4 * z;
					String shown = scope .();
					Ellipsize(p.Default, bx - (fpos.x + 4 * z) - 6 * z, drawScale, shown);
					Text(dl, fpos + ImVec2(4 * z, 3 * z), fh * z, Gui.Color(200, 200, 200), shown);
					Text(dl, ImVec2(bx, fpos.y + 3 * z), fh * z, Theme.Warning, cExpressionBadge);
					ExpressionBadgeX = bx - nodePos.x;
					ExpressionValueRight = fpos.x + 4 * z + Gui.CalcTextSize(shown).x * drawScale - nodePos.x;
					let mouse = Gui.igGetMousePos();
					if (mouse.x >= fpos.x && mouse.x <= f1.x && mouse.y >= fpos.y && mouse.y <= f1.y)
						mHoverExprPin = p.Id;
				}
				else if (widgets && PinValueEditor.Handles(pl.VKind) && !pl.Check)
				{
					mPinEditor.ButtonColor = Theme.InlineFieldBg;
					Gui.igSetCursorScreenPos(fpos);
					if (mPinEditor.Draw(mApp, node, p, pl.VKind, pl.FieldW * z))
					{
						// A typed value can choose another overload (`$"..."` stays a text; a typed text
						// into an Object pin is shown by the text overload).
						mApp.RefitCall(graph, node);
						mApp.CommitCurrent();
						mCommitted = true;
					}
				}
				else if (widgets)
					DrawInlineValue(node, p, fpos, pl.FieldW * z, pl.Check);
				else
				{
					// Too small for live widgets: draw the value like UE's low-detail mode.
					let f1 = fpos + ImVec2(pl.FieldW * z, (fh + 6) * z);
					Gui.ImDrawList_AddRectFilled(dl, fpos, f1, Theme.InlineFieldBg, 3 * z, 0);
					Text(dl, fpos + ImVec2(4 * z, 3 * z), fh * z, Gui.Color(200, 200, 200), p.Default);
				}
			}
		}

		/// The badge of a pin value that is not a plain literal of the pin's type (PinValueKind.Custom).
		public const String cExpressionBadge = "Expression";
		public const String cExpressionTip = "Not a plain value of this pin's type (a name, a call, an interpolated or verbatim string, ...), so it is kept as written. Edit it in Properties > Inputs.";
		/// The longest an expression value is drawn on the node (grid units); longer ones end in "...".
		const float cExpressionValueMaxW = 220;
		/// Self test: where the last expression badge was drawn and where its value text ends (screen
		/// units from the node's left edge): the value must end before the badge.
		public float ExpressionBadgeX;
		public float ExpressionValueRight;
		/// The pin whose expression field the mouse is over this frame (its tooltip explains the badge).
		int32 mHoverExprPin;

		/// `text` (its first line) shortened with "..." to fit `maxW` screen units, measured with the
		/// current font scaled by `scale`.
		public static void Ellipsize(StringView text, float maxW, float scale, String outText)
		{
			var t = text;
			bool cut = false;
			let nl = t.IndexOf('\n');
			if (nl >= 0)
			{
				t = t.Substring(0, nl);
				cut = true;
			}
			if (t.Length > 240)
			{
				t = t.Substring(0, 240);
				cut = true;
			}
			if (!cut && Gui.CalcTextSize(t).x * scale <= maxW)
			{
				outText.Append(t);
				return;
			}
			const String cDots = "...";
			float dotsW = Gui.CalcTextSize(cDots).x * scale;
			int len = t.Length;
			while (len > 0 && Gui.CalcTextSize(t.Substring(0, len)).x * scale + dotsW > maxW)
			{
				len--;
				while (len > 0 && ((uint8)t[len] & 0xC0) == 0x80)
					len--;
			}
			outText.Append(t.Substring(0, len));
			outText.Append(cDots);
		}

		/// The Math Expression being typed on a node (0: none) and what is typed; a refused one
		/// keeps its frame red for a moment.
		int32 mMathEditNode;
		String mMathEditText = new .() ~ delete _;
		int32 mMathRejectNode;
		int32 mMathRejectFrames;
		/// Self test: the last expression refused on a node, and how many were.
		public String MathRefusal = new .() ~ delete _;
		public int MathRefusals;

		/// Self test: the node's field looks as if `text` were being typed into it.
		public void SelfTestMathType(int32 nodeId, StringView text)
		{
			mMathEditNode = nodeId;
			mMathEditText.Set(text);
		}

		/// The font size of the expression field at zoom `z`: the node's text size (widgets get the
		/// UI scale on top of the size they are given, the node's drawn text does not).
		float MathFieldFont(float z) => mFontSize * z / Math.Max(Look.Scale, 0.5f);

		/// The expression field in a Math Expression's body: typed here or in Properties. While
		/// what is typed is not a Beef expression the frame is red, and it is not taken.
		void DrawMathField(Graph graph, ImDrawList* dl, Node node, NodeLay L, ImVec2 p0, float z, bool widgets)
		{
			float fh = mFontSize;
			let f0 = ImVec2(p0.x + 8 * z, p0.y + L.CodeY * z);
			float w = (L.W - 16) * z;
			let f1 = ImVec2(f0.x + w, f0.y + (fh + 6) * z);
			bool mine = mMathEditNode == node.Id;
			bool bad = false;
			if (mine)
				bad = !MathExpression.Check(mMathEditText, scope String());
			if (widgets)
			{
				Gui.igSetCursorScreenPos(f0);
				Gui.PushID(node.Id);
				mScratch.Set(mine ? (StringView)mMathEditText : (StringView)node.Text);
				Gui.igSetNextItemWidth(w);
				if (mMono != null)
					Gui.igPushFont(mMono, MathFieldFont(z));
				bool changed = Gui.igInputTextWithHint("##mx", "a * b + 1", mScratch.Ptr, (.)mScratch.Capacity, 0, null, null);
				if (mMono != null)
					Gui.igPopFont();
				if (changed)
				{
					mMathEditNode = node.Id;
					mMathEditText.Set(mScratch.View);
				}
				if (Gui.igIsItemDeactivated() && mMathEditNode == node.Id)
				{
					var typed = StringView(mMathEditText);
					typed.Trim();
					if (typed != node.Text)
					{
						String why = scope .();
						if (MathExpression.Check(typed, why))
						{
							mApp.BeginEdit();
							node.Text.Set(typed);
							NodeFactory.SyncMath(graph, node);
							mApp.CommitCurrent();
							mCommitted = true;
						}
						else
						{
							mMathRejectNode = node.Id;
							mMathRejectFrames = 120;
							MathRefusal.Set(why);
							MathRefusals++;
							Notify.Warn(why);
						}
					}
					mMathEditNode = 0;
				}
				if (Gui.igIsItemHovered(0) && !Gui.igIsItemActive())
					Gui.Tooltip("The expression: every name in it is an input. Press Enter or click away to apply it.");
				Gui.PopID();
			}
			else
			{
				Gui.ImDrawList_AddRectFilled(dl, f0, f1, Theme.InlineFieldBg, 3 * z, 0);
				Text(dl, f0 + ImVec2(4 * z, 3 * z), fh * z, Theme.TextCode, node.Text, mMono);
			}
			if (bad || (mMathRejectNode == node.Id && mMathRejectFrames > 0))
			{
				if (!bad)
					mMathRejectFrames--;
				Gui.ImDrawList_AddRect(dl, f0 - .(1, 1), f1 + .(1, 1), Theme.NodeError, 3 * z, Math.Max(1.5f, 1.5f * z), 0);
			}
		}

		void DrawInlineValue(Node node, Pin p, ImVec2 pos, float width, bool check)
		{
			Gui.igSetCursorScreenPos(pos);
			Gui.PushID(p.Id);
			if (check)
			{
				bool v = p.Default == "true";
				if (Gui.Checkbox("##b", &v))
				{
					mApp.BeginEdit();
					p.Default.Set(v ? "true" : "false");
					node.Edited = true;
					mApp.CommitCurrent();
					mCommitted = true;
				}
			}
			else
			{
				mScratch.Set(p.Default);
				Gui.igSetNextItemWidth(width);
				StringView hint = (p.Name == "target") ? "this" : "";
				bool changed = Gui.igInputTextWithHint("##v", scope String(hint), mScratch.Ptr, (.)mScratch.Capacity, 0, null, null);
				if (changed)
				{
					if (!mInlineEditPushedUndo)
					{
						mApp.BeginEdit();
						mInlineEditPushedUndo = true;
					}
					p.Default.Set(mScratch.View);
					node.Edited = true;
				}
				if (Gui.igIsItemDeactivatedAfterEdit())
				{
					mInlineEditPushedUndo = false;
					mApp.CommitCurrent();
					mCommitted = true;
				}
				else if (Gui.igIsItemDeactivated())
					mInlineEditPushedUndo = false;
				if (Gui.igIsItemHovered(0) && !p.Default.IsEmpty && p.Default.Length > 30)
					Gui.Tooltip(p.Default);
			}
			Gui.PopID();
		}

		// ------------------------------------------------------------------ comment bubbles

		struct BubbleHit
		{
			public int32 Id;
			/// 0 = node bubble (edit), 1 = node "add comment" chip, 2 = node bubble pin toggle,
			/// 3 = comment box pin toggle.
			public int32 Kind;
			public ImVec2 Min;
			public ImVec2 Max;
		}

		List<BubbleHit> mBubbleHits = new .() ~ delete _;
		/// The node whose bubble is being edited in place (0 = none), its text and focus request.
		int32 mBubbleEdit;
		bool mBubbleFocus;
		bool mBubbleActive;
		TextBuffer mBubbleBuf = new .(1024) ~ delete _;

		/// The comment of a node without its `//` markers (what Properties > Comment shows).
		public static void CommentText(Node node, String outText)
		{
			if (node.LeadingComments == null)
				return;
			for (let line in node.LeadingComments.Split('\n'))
			{
				var l = line;
				l.Trim();
				if (l.StartsWith("//"))
					l = l.Substring(2);
				l.TrimStart();
				if (!outText.IsEmpty || !l.IsEmpty)
				{
					outText.Append(l);
					outText.Append('\n');
				}
			}
			while (outText.EndsWith('\n'))
				outText.RemoveFromEnd(1);
		}

		static void NormalizeComment(StringView text, String outText)
		{
			for (let line in text.Split('\n'))
			{
				var l = line;
				l.Trim();
				if (!l.IsEmpty)
				{
					outText.Append(l);
					outText.Append('\n');
				}
			}
			while (outText.EndsWith('\n'))
				outText.RemoveFromEnd(1);
		}

		/// Sets a node's comment from plain text, the same write as Properties > Comment (comment lines
		/// above the statement). One undo step. False when nothing changed.
		bool WriteComment(Node node, StringView text)
		{
			String before = scope .();
			CommentText(node, before);
			String beforeNorm = scope .();
			NormalizeComment(before, beforeNorm);
			String now = scope .();
			NormalizeComment(text, now);
			if (now == beforeNorm)
				return false;
			mApp.BeginEdit();
			if (node.LeadingComments == null)
				node.LeadingComments = new String();
			node.LeadingComments.Clear();
			for (let line in now.Split('\n'))
				if (!line.IsEmpty)
					node.LeadingComments.AppendF("// {}\n", line);
			if (node.LeadingComments.IsEmpty)
			{
				delete node.LeadingComments;
				node.LeadingComments = null;
			}
			node.Moved = true; // regenerate the comment lines
			mApp.CommitCurrent();
			mCommitted = true;
			return true;
		}

		/// Opens the in-place comment editor on a node (the node menu's Add / Edit Comment, a click on
		/// its bubble or chip).
		public void BeginBubbleEdit(int32 nodeId)
		{
			let tab = mApp.CurrentTab;
			let mg = mApp.CurrentMethod;
			let node = (mg != null) ? mg.Graph.FindNode(nodeId) : null;
			if (node == null || !node.IsExecNode)
				return;
			String t = scope .();
			CommentText(node, t);
			mBubbleBuf.Set(t);
			mBubbleEdit = nodeId;
			mBubbleFocus = true;
			mBubbleActive = false;
			if (tab != null)
				tab.SelectOnly(nodeId);
		}

		public bool BubbleEditing => mBubbleEdit != 0;
		public void CancelBubbleEdit() { mBubbleEdit = 0; }

		/// Self test: types `text` into the open editor and commits it (what Enter does).
		public bool SelfTestCommitBubble(StringView text)
		{
			let mg = mApp.CurrentMethod;
			let node = (mg != null && mBubbleEdit != 0) ? mg.Graph.FindNode(mBubbleEdit) : null;
			if (node == null)
				return false;
			WriteComment(node, text);
			mBubbleEdit = 0;
			return true;
		}

		/// Self test: the bubble hits of the last frame (count by kind).
		public int SelfTestBubbleHits(int32 kind)
		{
			int n = 0;
			for (let h in mBubbleHits)
				if (h.Kind == kind)
					n++;
			return n;
		}

		void DrawPinIcon(ImDrawList* dl, ImVec2 c, float s, uint32 col, bool filled)
		{
			let head = ImVec2(c.x, c.y - s * 0.2f);
			if (filled)
				Gui.ImDrawList_AddCircleFilled(dl, head, s * 0.3f, col, 12);
			else
				Gui.ImDrawList_AddCircle(dl, head, s * 0.3f, col, 12, Math.Max(1.2f, s * 0.12f));
			Gui.ImDrawList_AddLine(dl, .(c.x - s * 0.38f, c.y + s * 0.12f), .(c.x + s * 0.38f, c.y + s * 0.12f), col, Math.Max(1.2f, s * 0.14f));
			Gui.ImDrawList_AddLine(dl, .(c.x, c.y + s * 0.12f), .(c.x, c.y + s * 0.5f), col, Math.Max(1.2f, s * 0.12f));
		}

		ImVec2 MeasureText(StringView t, float fs, float wrap)
		{
			Gui.igPushFont(mFont, fs);
			let sz = Gui.igCalcTextSize(t.Ptr, t.Ptr + t.Length, false, wrap);
			Gui.igPopFont();
			return sz;
		}

		bool BubbleHitAt(ImVec2 mouse, out BubbleHit hit)
		{
			hit = default;
			for (var i = mBubbleHits.Count - 1; i >= 0; i--)
			{
				let h = mBubbleHits[i];
				if (mouse.x >= h.Min.x && mouse.x <= h.Max.x && mouse.y >= h.Min.y && mouse.y <= h.Max.y)
				{
					hit = h;
					return true;
				}
			}
			return false;
		}

		/// A click on a bubble, chip or pin toggle (before the canvas press). True when it was used.
		bool BubblePress(GraphTab tab, MethodGraph mg, ImVec2 mouse)
		{
			if (mBubbleEdit != 0)
				return false;
			if (!BubbleHitAt(mouse, let hit))
				return false;
			switch (hit.Kind)
			{
			case 0, 1:
				if (mg.Graph.ReadOnly)
					return false;
				BeginBubbleEdit(hit.Id);
			case 2:
				let n = mg.Graph.FindNode(hit.Id);
				if (n != null)
				{
					tab.Doc.SetBubblePinned(mg.Key, n.Key, !tab.Doc.IsBubblePinned(mg.Key, n.Key));
					mApp.LayoutChanged();
				}
			case 3:
				for (let c in mComments)
					if (c.Id == hit.Id)
					{
						c.Pinned = !c.Pinned;
						mApp.LayoutChanged();
					}
			default:
			}
			return true;
		}

		/// Node comment bubbles, the "add comment" chip on hover, the in-place editor, and the pinned
		/// labels of comment boxes. Canvas layer: bubbles scale with the graph unless pinned.
		void DrawBubbles(GraphTab tab, MethodGraph mg, Graph graph, ImDrawList* dl, ImVec2 mouse)
		{
			mBubbleHits.Clear();
			float z = tab.Zoom;
			let origin = tab.CanvasOrigin;
			let cmax = origin + tab.CanvasSize;
			bool wiring = tab.Mode == .Wire;
			bool idle = tab.Mode == .None;
			for (let L in mOrder)
			{
				let node = L.Node;
				if (!L.Visible || !node.IsExecNode || node == graph.Entry)
					continue;
				bool editing = mBubbleEdit == node.Id;
				String text = scope .();
				CommentText(node, text);
				bool has = !text.IsEmpty;
				bool pinned = tab.Doc.IsBubblePinned(mg.Key, node.Key);
				let p0 = tab.GridToScreen(node.X, node.Y);
				let p1 = p0 + ImVec2(L.W, L.H) * z;
				float s = pinned ? 1.0f : z;
				float fade = 1;
				if (!pinned)
				{
					if (z < 0.35f && !editing)
						continue;
					fade = Math.Clamp((z - 0.35f) / 0.25f, 0, 1);
				}
				if (editing)
					s = Math.Max(s, 0.8f);
				float sm = Math.Max(s, 0.8f);
				bool inRegion = idle && mouse.x >= p0.x && mouse.x <= p1.x && mouse.y >= p0.y - 34 * sm && mouse.y <= p1.y && (mHoverNode == 0 || mHoverNode == node.Id);
				if (!has && !editing)
				{
					// Hover affordance: a small chip above the title.
					if (!inRegion || graph.ReadOnly || mBubbleEdit != 0)
						continue;
					float fsC = mFontSize * 0.85f * sm;
					StringView label = "+ comment";
					let sz = MeasureText(label, fsC, 0);
					float cpad = 5 * sm;
					let cw = sz.x + 2 * cpad;
					let chh = sz.y + 2 * cpad * 0.6f;
					let cmn = ImVec2(p0.x, p0.y - chh - 4 * sm);
					let cmx = cmn + ImVec2(cw, chh);
					bool hot = mouse.x >= cmn.x && mouse.x <= cmx.x && mouse.y >= cmn.y && mouse.y <= cmx.y;
					Gui.ImDrawList_AddRectFilled(dl, cmn, cmx, hot ? Gui.Color(78, 84, 98, 240) : Gui.Color(52, 56, 66, 225), 5 * sm, 0);
					Gui.ImDrawList_AddRect(dl, cmn, cmx, Gui.Color(120, 128, 146, 200), 5 * sm, 1, 0);
					Text(dl, .(cmn.x + cpad, cmn.y + cpad * 0.6f), fsC, Gui.Color(215, 220, 230), label);
					BubbleHit ch = default;
					ch.Id = node.Id;
					ch.Kind = 1;
					ch.Min = cmn;
					ch.Max = cmx;
					mBubbleHits.Add(ch);
					continue;
				}
				float fs = mFontSize * 0.9f * s;
				float pad = 6 * s;
				float iconW = 16 * s;
				float wrapW = 240 * s;
				let tsz = MeasureText(text, fs, wrapW);
				float bw = Math.Min(tsz.x, wrapW) + 2 * pad + iconW;
				float bh = tsz.y + 2 * pad;
				if (editing)
				{
					bw = Math.Max(bw, 220 * s);
					bh = Math.Max(bh, 64 * s);
				}
				var bp = ImVec2(p0.x, p0.y - bh - 8 * s);
				if (pinned)
				{
					bp.x = Math.Clamp(bp.x, origin.x + 4, Math.Max(origin.x + 4, cmax.x - bw - 4));
					bp.y = Math.Max(bp.y, origin.y + 4);
					// Stay near the node: never farther than a bubble's height above it.
					bp.y = Math.Min(bp.y, p1.y - bh);
				}
				let bmax = bp + ImVec2(bw, bh);
				if (!Canvas.RectsOverlap(bp, bmax, origin, cmax))
					continue;
				if (wiring)
				{
					// Dragging a wire: a bubble over another node would hide its pins (the drop targets).
					bool over = false;
					for (let O in mOrder)
					{
						if (O == L || !O.Visible)
							continue;
						let o0 = tab.GridToScreen(O.Node.X, O.Node.Y);
						if (Canvas.RectsOverlap(bp, bmax, o0, o0 + ImVec2(O.W, O.H) * z))
						{
							over = true;
							break;
						}
					}
					if (over)
						continue;
				}
				uint8 a = (uint8)(fade * 255);
				bool hotB = idle && mouse.x >= bp.x && mouse.x <= bmax.x && mouse.y >= bp.y && mouse.y <= bmax.y;
				if (editing)
				{
					Gui.ImDrawList_AddRectFilled(dl, bp, bmax, Gui.Color(40, 44, 54, 250), 7 * s, 0);
					Gui.ImDrawList_AddRect(dl, bp, bmax, Theme.NodeSelected, 7 * s, Math.Max(1.5f, 1.5f * s), 0);
					Gui.igPushFont(mFont, fs);
					Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(pad, pad * 0.7f));
					Gui.igPushStyleColor_U32(Col.FrameBg, Gui.Color(0, 0, 0, 0));
					Gui.igSetCursorScreenPos(bp);
					if (mBubbleFocus)
					{
						Gui.igSetKeyboardFocusHere(0);
						mBubbleFocus = false;
					}
					bool esc = Gui.IsKeyPressed(Key.Escape, false);
					Gui.PushID(node.Id);
					bool entered = Gui.igInputTextMultiline("##vbbubble", mBubbleBuf.Ptr, (.)mBubbleBuf.Capacity, .(bw, bh), InputTextFlags.EnterReturnsTrue | InputTextFlags.CtrlEnterForNewLine, null, null);
					if (Gui.igIsItemActive())
						mBubbleActive = true;
					bool deact = Gui.igIsItemDeactivated();
					Gui.PopID();
					Gui.igPopStyleColor(1);
					Gui.igPopStyleVar(1);
					Gui.igPopFont();
					if (esc)
						mBubbleEdit = 0; // cancel
					else if ((entered || deact) && mBubbleActive)
					{
						WriteComment(node, mBubbleBuf.View);
						mBubbleEdit = 0;
					}
					continue;
				}
				Gui.ImDrawList_AddRectFilled(dl, bp + .(1, 2 * s), bmax + .(1, 2 * s), Gui.Color(0, 0, 0, (uint8)(40 * fade)), 7 * s, 0);
				Gui.ImDrawList_AddRectFilled(dl, bp, bmax, Theme.WithAlpha(hotB ? Gui.Color(70, 76, 90) : Gui.Color(56, 60, 72), (uint8)(238 * fade)), 7 * s, 0);
				Gui.ImDrawList_AddRect(dl, bp, bmax, Theme.WithAlpha(pinned ? Theme.NodeSelected : Gui.Color(112, 120, 138), a), 7 * s, 1, 0);
				// Pointer to the node.
				Gui.ImDrawList_AddTriangleFilled(dl, .(bp.x + 14 * s, bmax.y - 0.5f), .(bp.x + 24 * s, bmax.y - 0.5f), .(bp.x + 16 * s, bmax.y + 6 * s), Theme.WithAlpha(Gui.Color(56, 60, 72), (uint8)(238 * fade)));
				Gui.ImDrawList_PushClipRect(dl, bp, bmax, true);
				Text(dl, .(bp.x + pad, bp.y + pad), fs, Theme.WithAlpha(Gui.Color(230, 233, 240), a), text, null, wrapW);
				Gui.ImDrawList_PopClipRect(dl);
				BubbleHit h = default;
				h.Id = node.Id;
				h.Kind = 0;
				h.Min = bp;
				h.Max = bmax;
				mBubbleHits.Add(h);
				if (hotB || pinned)
				{
					let ic = ImVec2(bmax.x - iconW * 0.5f - 2 * s, bp.y + pad + fs * 0.5f);
					float isz = 13 * s;
					bool hotI = mouse.x >= ic.x - isz && mouse.x <= ic.x + isz && mouse.y >= ic.y - isz && mouse.y <= ic.y + isz;
					DrawPinIcon(dl, ic, isz, Theme.WithAlpha(pinned ? Theme.NodeSelected : (hotI ? Gui.Color(255, 255, 255) : Gui.Color(170, 178, 196)), a), pinned);
					BubbleHit ph = default;
					ph.Id = node.Id;
					ph.Kind = 2;
					ph.Min = ic - ImVec2(isz, isz);
					ph.Max = ic + ImVec2(isz, isz);
					mBubbleHits.Add(ph);
					if (hotI)
						Gui.Tooltip(pinned ? "Pinned: keeps a readable size when zoomed out. Click to unpin." : "Pin: keep this comment readable when zoomed out.");
				}
			}

			// Comment boxes: a pin toggle on the title bar, and for a pinned box zoomed out a readable label.
			for (let c in mComments)
			{
				let p0 = tab.GridToScreen(c.X, c.Y);
				let p1 = tab.GridToScreen(c.X + c.W, c.Y + c.H);
				if (!Canvas.RectsOverlap(p0, p1, origin, cmax) || tab.EditingComment == c.Id)
					continue;
				bool hotBox = idle && mHoverComment == c.Id;
				bool chip = c.Pinned && z < 1.0f;
				float isz = 11 * Math.Max(Math.Min(z, 1.0f), 0.8f);
				if (chip)
				{
					float fs = mFontSize * 1.25f;
					let sz = MeasureText(c.Text, fs, 0);
					float pad = 6;
					float cw = Math.Min(sz.x, 420) + 2 * pad + 22;
					float chh = sz.y + 8;
					var cp = ImVec2(p0.x, p0.y - chh);
					cp.x = Math.Clamp(cp.x, origin.x + 4, Math.Max(origin.x + 4, cmax.x - cw - 4));
					cp.y = Math.Max(cp.y, origin.y + 4);
					let cmx = cp + ImVec2(cw, chh);
					Gui.ImDrawList_AddRectFilled(dl, cp, cmx, Theme.WithAlpha(Theme.Mix(c.Color, Gui.Color(0, 0, 0), 0.5f), 245), 5, 0);
					Gui.ImDrawList_AddRect(dl, cp, cmx, Theme.WithAlpha(c.Color, 230), 5, 1, 0);
					Gui.ImDrawList_PushClipRect(dl, cp, .(cmx.x - 22, cmx.y), true);
					Text(dl, .(cp.x + pad, cp.y + 4), fs, Gui.Color(255, 255, 255), c.Text);
					Gui.ImDrawList_PopClipRect(dl);
					let ic = ImVec2(cmx.x - 13, cp.y + chh * 0.5f);
					DrawPinIcon(dl, ic, 12, Theme.NodeSelected, true);
					BubbleHit ph = default;
					ph.Id = c.Id;
					ph.Kind = 3;
					ph.Min = ic - ImVec2(isz, isz);
					ph.Max = ic + ImVec2(isz, isz);
					mBubbleHits.Add(ph);
				}
				else if ((hotBox || c.Pinned) && z >= 0.3f)
				{
					let ic = ImVec2(p1.x - 14 * Math.Min(z, 1.0f) - 6, p0.y + CommentTitleH * z * 0.5f);
					DrawPinIcon(dl, ic, isz, c.Pinned ? Theme.NodeSelected : Gui.Color(200, 205, 215), c.Pinned);
					BubbleHit ph = default;
					ph.Id = c.Id;
					ph.Kind = 3;
					ph.Min = ic - ImVec2(isz, isz);
					ph.Max = ic + ImVec2(isz, isz);
					mBubbleHits.Add(ph);
				}
			}
		}

		/// The pending wire of an open pin-opened Node menu: the source pin's layout and the screen end.
		public bool PendingWireEnds(GraphTab tab, Graph graph, out PinLay src, out ImVec2 end)
		{
			src = default;
			end = default;
			if (!mApp.PendingWire(tab, graph, let pinId, let grid) || !TryGetPin(pinId, out src))
				return false;
			end = tab.GridToScreen(grid.x, grid.y);
			return true;
		}

		/// Dragged wire, marquee, zoom label, pin tooltip.
		void DrawOverlay(GraphTab tab, Graph graph, ImDrawList* dl, ImVec2 mouse)
		{
			float z = tab.Zoom;
			if (tab.Mode == .Wire && TryGetPin(tab.DragPin, let src))
			{
				let sp = PinScreen(tab, src);
				uint32 col = WireColor(src.Pin);
				Pin target = DropTarget(graph, src.Pin);
				bool bad = mHoverPin != 0 && mHoverPin != src.Pin.Id && target == null;
				if (bad)
					col = Theme.Mix(col, Theme.WireBad, 0.75f);
				float th = Math.Max(1.0f, ((src.Pin.Kind == .Exec) ? 3.0f : 2.0f) * z);
				// Snap the loose end onto the target pin.
				ImVec2 end = mouse;
				if (target != null && TryGetPin(target.Id, let tpl))
					end = PinScreen(tab, tpl);
				if (src.Pin.IsInput)
					Canvas.Wire(dl, end, sp, z, col, th);
				else
					Canvas.Wire(dl, sp, end, z, col, th);
				if (bad)
				{
					// Say why, like UE: "float to int needs a cast: it can lose data".
					String why = scope .();
					Graph.CanConnectTyped(src.Pin, graph.FindPin(mHoverPin), why);
					Gui.Tooltip(why.IsEmpty ? "Incompatible pins" : why);
				}
				else if (target != null && target.IsInput && target.Kind == .Data && graph.IsLinked(target))
					Gui.Tooltip("Replace existing input connection");
			}
			else if (tab.Mode == .None && PendingWireEnds(tab, graph, let pw, let pwEnd))
			{
				// The Node menu is up for a wire dragged off a pin: keep that wire drawn, from the pin to
				// where the new node will go, until the menu closes.
				let sp = PinScreen(tab, pw);
				float th = Math.Max(1.0f, ((pw.Pin.Kind == .Exec) ? 3.0f : 2.0f) * z);
				if (pw.Pin.IsInput)
					Canvas.Wire(dl, pwEnd, sp, z, WireColor(pw.Pin), th);
				else
					Canvas.Wire(dl, sp, pwEnd, z, WireColor(pw.Pin), th);
			}
			else if (tab.Mode == .Relink)
			{
				Pin target = (mHoverPin != 0) ? graph.FindPin(mHoverPin) : null;
				for (let id in tab.DragLinks)
				{
					let link = graph.FindLink(id);
					if (link == null)
						continue;
					let other = (link.From.Id == tab.DragPin) ? link.To : link.From;
					if (!TryGetPin(other.Id, let opl))
						continue;
					let op = PinScreen(tab, opl);
					uint32 col = WireColor(link.From);
					if (target != null && !Graph.CanConnectTyped(other, target))
						col = Theme.Mix(col, Theme.WireBad, 0.75f);
					float th = Math.Max(1.0f, ((link.From.Kind == .Exec) ? 3.0f : 2.0f) * z);
					if (other.IsInput)
						Canvas.Wire(dl, mouse, op, z, col, th);
					else
						Canvas.Wire(dl, op, mouse, z, col, th);
				}
			}
			else if (tab.Mode == .Marquee)
			{
				let a = ImVec2(Math.Min(tab.PressPos.x, mouse.x), Math.Min(tab.PressPos.y, mouse.y));
				let b = ImVec2(Math.Max(tab.PressPos.x, mouse.x), Math.Max(tab.PressPos.y, mouse.y));
				Gui.ImDrawList_AddRectFilled(dl, a, b, Theme.MarqueeFill, 0, 0);
				Gui.ImDrawList_AddRect(dl, a, b, Theme.MarqueeBorder, 0, 1, 0);
			}
			else if (tab.Mode == .None && mHoverPin != 0)
			{
				let p = graph.FindPin(mHoverPin);
				if (p != null && p.Kind == .Data)
				{
					String tip = scope .();
					if (!p.Label.IsEmpty)
						tip.AppendF("{}\n", p.Label);
					tip.Append(p.TypeName.IsEmpty ? "(type unknown)" : p.TypeName);
					if (p.IsRefArg)
						tip.Append("\nref: passed by reference, wire a variable, field or element");
					else if (p.IsOutArg)
					{
						switch (p.Form)
						{
						case .Discard: tip.Append("\nout: discarded (`?`) until something reads it");
						case .Existing: tip.AppendF("\nout: writes {}", p.OutName);
						default: tip.AppendF("\nout: variable {}", (p.OutName != null) ? (StringView)p.OutName : "(named when written)");
						}
					}
					else if (IsSelfTarget(graph, p))
						tip.AppendF("\nNot connected: this{}", graph.StaticContext ? ", but this function is static" : "");
					Gui.Tooltip(tip);
				}
			}
			else if (tab.Mode == .None && mHoverExprPin != 0)
			{
				// The Expression badge: what it means, and the whole value when it is shortened.
				let p = graph.FindPin(mHoverExprPin);
				if (p != null)
					Gui.Tooltip(scope $"{cExpressionBadge}: {p.Default}\n{cExpressionTip}");
			}

			// Node tooltip after hovering ~0.6 s (UE).
			if (tab.Mode == .None && mHoverNode != 0 && mHoverPin == 0 && mHoverExprPin == 0 && !Gui.igIsPopupOpen_Str("", (1 << 10) | (1 << 11) /* AnyPopupId | AnyPopupLevel */))
			{
				if (mTipNode != mHoverNode)
				{
					mTipNode = mHoverNode;
					mTipSince = Gui.igGetTime();
				}
				else if (Gui.igGetTime() - mTipSince > 0.6)
				{
					let node = graph.FindNode(mHoverNode);
					if (node != null)
					{
						String tip = scope .();
						if (mNodeErrors.TryGetValue(node.Id, let err))
							tip.AppendF("ERROR: {}\n\n", err);
						else if (mNodeWarnings.TryGetValue(node.Id, let warn))
							tip.AppendF("Warning: {}\n\n", warn);
						NodeTooltip(tab, graph, node, tip);
						if (!tip.IsEmpty)
							Gui.Tooltip(tip);
					}
				}
			}
			else
				mTipNode = 0;

			// UE's faint zoom readout, brighter right after a change.
			String label = scope .();
			Canvas.ZoomLabel(tab.ZoomLevel, label);
			float age = (float)(Gui.igGetTime() - tab.ZoomChangedTime);
			uint8 alpha = (uint8)(70 + 150 * Math.Clamp(1.0f - (age - 1.0f) / 0.6f, 0, 1));
			float ls = mFontSize * 1.5f;
			float lw = Gui.CalcTextSize(label).x * 1.5f;
			Text(dl, .(tab.CanvasOrigin.x + tab.CanvasSize.x - lw - 16, tab.CanvasOrigin.y + 10 + NavButtonsHeight), ls, Gui.Color(255, 255, 255, alpha), label);
		}

		/// Where a dragged wire from `src` would connect: the hovered pin, or the first
		/// compatible pin of the hovered node. Null if nothing compatible.
		/// A wire the pin's own type refuses, but another overload of the call takes (an int dropped on
		/// WriteLine's text pin): allowed, and the call switches to that overload once wired.
		static bool OverloadTakes(Graph graph, Pin a, Pin b)
		{
			if (!Graph.CanConnect(a, b) || a.Kind != .Data)
				return false;
			let input = a.IsInput ? a : b;
			let output = a.IsInput ? b : a;
			return CallOverloads.CouldTake(graph, input, output.TypeName, TypeService.Current);
		}

		Pin DropTarget(Graph graph, Pin src)
		{
			if (src == null)
				return null;
			if (mHoverPin != 0)
			{
				let p = graph.FindPin(mHoverPin);
				return (Graph.CanConnectTyped(src, p) || OverloadTakes(graph, src, p)) ? p : null;
			}
			if (mHoverNode != 0)
			{
				let n = graph.FindNode(mHoverNode);
				if (n == null)
					return null;
				let list = src.IsInput ? n.Outputs : n.Inputs;
				// Prefer a free pin of the same type, then any free one, then anything compatible.
				for (int pass < 3)
				{
					for (let p in list)
					{
						if (!(Graph.CanConnectTyped(src, p) || (pass == 2 && OverloadTakes(graph, src, p))) || HidePin(graph, p))
							continue;
						if (!TryGetPin(p.Id, let pl) || !pl.Visible)
							continue;
						bool free = !graph.IsLinked(p) || p.Kind == .Exec;
						if (pass == 0 && (!free || (p.Kind == .Data && p.TypeName != src.TypeName)))
							continue;
						if (pass == 1 && !free)
							continue;
						return p;
					}
				}
			}
			return null;
		}

		// ------------------------------------------------------------------ comments & reroutes

		/// Comment title bar height in grid units.
		float CommentTitleH => mFontSize * 1.25f + 12;

		void GatherComments(GraphTab tab)
		{
			mComments.Clear();
			for (let c in tab.Doc.Comments)
				if (c.MethodKey == tab.MethodKey)
					mComments.Add(c);
			// Bigger boxes behind smaller ones, so nested comments stay clickable.
			mComments.Sort(scope (a, b) => (b.W * b.H <=> a.W * a.H));
		}

		GraphComment FindComment(int32 id)
		{
			for (let c in mComments)
				if (c.Id == id)
					return c;
			return null;
		}

		GraphReroute FindKnot(KnotRef k)
		{
			if (!k.IsValid)
				return null;
			if (mRoutes.TryGetValue(RouteKey(k.FromPin, k.ToPin), let route) && k.Index < route.Points.Count)
				return route;
			return null;
		}

		static Link FindLinkBetween(Graph graph, Pin from, Pin to)
		{
			for (let l in graph.Links)
				if (l.From == from && l.To == to)
					return l;
			return null;
		}

		/// Matches the document's reroute records to this graph's links (by pin id while editing,
		/// by node key + pin name after a reload/rebuild) and drops those whose link is gone.
		void ResolveReroutes(GraphTab tab, Graph graph)
		{
			mRoutes.Clear();
			let list = tab.Doc.Reroutes;
			for (int i = list.Count - 1; i >= 0; i--)
			{
				let r = list[i];
				if (r.MethodKey != tab.MethodKey)
					continue;
				Pin from = null;
				Pin to = null;
				if (r.FromPinId != 0 && r.GraphSerial == graph.Serial)
				{
					from = graph.FindPin(r.FromPinId);
					to = graph.FindPin(r.ToPinId);
				}
				else
				{
					for (let n in graph.Nodes)
					{
						if (n.Key == r.FromNode)
							from = n.FindOutput(r.FromPin);
						if (n.Key == r.ToNode)
							to = n.FindInput(r.ToPin);
					}
				}
				if (from == null || to == null || FindLinkBetween(graph, from, to) == null || r.Points.IsEmpty)
				{
					list.RemoveAt(i);
					delete r;
					mApp.LayoutChanged();
					continue;
				}
				r.FromPinId = from.Id;
				r.ToPinId = to.Id;
				r.GraphSerial = graph.Serial;
				mRoutes[RouteKey(from.Id, to.Id)] = r;
			}
		}

		/// Double-click on a wire: add a reroute knot there (UE). Layout only.
		void AddKnot(GraphTab tab, Graph graph, int32 linkId, int32 segment, ImVec2 mouse)
		{
			let link = graph.FindLink(linkId);
			if (link == null)
				return;
			mApp.BeginEdit();
			let g = tab.ScreenToGrid(mouse);
			NodePos pos;
			pos.X = g.x;
			pos.Y = g.y;
			if (mRoutes.TryGetValue(RouteKey(link.From.Id, link.To.Id), var route))
				route.Points.Insert(Math.Clamp(segment, 0, route.Points.Count), pos);
			else
			{
				route = new GraphReroute();
				route.MethodKey.Set(tab.MethodKey);
				route.FromNode.Set(link.From.Owner.Key);
				route.FromPin.Set(link.From.Name);
				route.ToNode.Set(link.To.Owner.Key);
				route.ToPin.Set(link.To.Name);
				route.FromPinId = link.From.Id;
				route.ToPinId = link.To.Id;
				route.GraphSerial = graph.Serial;
				route.Points.Add(pos);
				tab.Doc.Reroutes.Add(route);
				mRoutes[RouteKey(link.From.Id, link.To.Id)] = route;
			}
			tab.ClearSelection();
			tab.SelectedKnot = .(link.From.Id, link.To.Id, (int32)Math.Clamp(segment, 0, route.Points.Count - 1));
			mApp.LayoutChanged();
		}

		void RemoveKnot(GraphTab tab, KnotRef k, bool pushUndo)
		{
			let route = FindKnot(k);
			if (route == null)
				return;
			if (pushUndo)
				mApp.BeginEdit();
			route.Points.RemoveAt(k.Index);
			if (route.Points.IsEmpty)
			{
				tab.Doc.Reroutes.Remove(route);
				mRoutes.Remove(RouteKey(k.FromPin, k.ToPin));
				delete route;
			}
			if (tab.SelectedKnot.Equals(k))
				tab.SelectedKnot = default;
			mApp.LayoutChanged();
		}

		void DrawKnots(GraphTab tab, Graph graph, ImDrawList* dl)
		{
			float z = tab.Zoom;
			for (let route in mRoutes.Values)
			{
				let from = graph.FindPin(route.FromPinId);
				if (from == null)
					continue;
				uint32 col = WireColor(from);
				for (let pt in route.Points)
				{
					KnotRef k = .(route.FromPinId, route.ToPinId, (int32)@pt.Index);
					let c = tab.GridToScreen(pt.X, pt.Y);
					bool hot = mHoverKnot.Equals(k);
					bool sel = tab.SelectedKnot.Equals(k);
					float r = Math.Max(3.5f, 6 * z);
					// UE's reroute node: a small dark pill with the wire's colour in the middle.
					Gui.ImDrawList_AddCircleFilled(dl, c, r + 2 * z, Gui.Color(15, 15, 15, 235), 0);
					Gui.ImDrawList_AddCircleFilled(dl, c, r, hot ? Theme.Lighten(col, 1.3f) : col, 0);
					if (sel)
						Gui.ImDrawList_AddCircle(dl, c, r + 4 * z, Theme.NodeSelected, 0, Math.Max(1.5f, 2 * z));
				}
			}
		}

		void DrawComments(GraphTab tab, ImDrawList* dl)
		{
			float z = tab.Zoom;
			let origin = tab.CanvasOrigin;
			let cmax = origin + tab.CanvasSize;
			for (let c in mComments)
			{
				let p0 = tab.GridToScreen(c.X, c.Y);
				let p1 = tab.GridToScreen(c.X + c.W, c.Y + c.H);
				if (!Canvas.RectsOverlap(p0, p1, origin, cmax))
					continue;
				float th = CommentTitleH * z;
				float r = 4 * z;
				uint8 alpha = (uint8)((c.Color >> 24) & 0xFF);
				// Body: the colour, very faint. Title bar: the colour, darker and more opaque.
				Gui.ImDrawList_AddRectFilled(dl, p0, p1, Theme.WithAlpha(c.Color, (uint8)(alpha * 0.22f)), r, 0);
				uint32 bar = Theme.WithAlpha(Theme.Mix(c.Color, Gui.Color(0, 0, 0), 0.38f), (uint8)Math.Max(alpha * 0.9f, 90));
				Gui.ImDrawList_AddRectFilled(dl, p0, .(p1.x, p0.y + th), bar, r, DrawFlags.RoundCornersTop);
				bool sel = tab.IsCommentSelected(c.Id);
				bool hot = mHoverComment == c.Id;
				uint32 border = sel ? Theme.NodeSelected : Theme.WithAlpha(c.Color, hot ? (uint8)200 : (uint8)(alpha * 0.55f));
				Gui.ImDrawList_AddRect(dl, p0, p1, border, r, sel ? Math.Max(1.5f, 2 * z) : 1, 0);
				// Resize grip (bottom-right), like UE.
				float hs = Math.Max(8, 12 * z);
				uint32 grip = Theme.WithAlpha(Gui.Color(255, 255, 255), (mHoverCommentResize == c.Id) ? (uint8)200 : (uint8)70);
				Gui.ImDrawList_AddTriangleFilled(dl, .(p1.x - 2, p1.y - hs), .(p1.x - 2, p1.y - 2), .(p1.x - hs, p1.y - 2), grip);

				float fs = mFontSize * 1.25f * z;
				if (tab.EditingComment == c.Id && z >= 0.3f)
				{
					// Inline rename (double-click the title).
					Gui.igPushFont(mFont, fs);
					Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(4 * z, (th - fs) * 0.5f - 1));
					Gui.igSetCursorScreenPos(.(p0.x + 6 * z, p0.y + 1));
					Gui.igSetNextItemWidth(Math.Max(p1.x - p0.x - 12 * z, 40));
					Gui.PushID(c.Id);
					if (mFocusCommentEdit)
					{
						mCommentBuf.Set(c.Text);
						Gui.igSetKeyboardFocusHere(0);
						mFocusCommentEdit = false;
						mFocusedCommentEdit = c.Id;
					}
					if (Gui.igInputText("##ctitle", mCommentBuf.Ptr, (.)mCommentBuf.Capacity, InputTextFlags.AutoSelectAll | InputTextFlags.EnterReturnsTrue, null, null))
						tab.EditingComment = 0;
					if (Gui.igIsItemEdited())
					{
						c.Text.Set(mCommentBuf.View);
						mApp.LayoutChanged();
					}
					if (Gui.igIsItemDeactivated() && mFocusedCommentEdit == c.Id)
					{
						tab.EditingComment = 0;
						mFocusedCommentEdit = 0;
					}
					Gui.PopID();
					Gui.igPopStyleVar(1);
					Gui.igPopFont();
				}
				else if (!(c.Pinned && z < 1.0f))
				{
					let clipMin = ImVec2(p0.x, p0.y);
					let clipMax = ImVec2(p1.x - 4 * z, p0.y + th);
					Gui.ImDrawList_PushClipRect(dl, clipMin, clipMax, true);
					let tp = ImVec2(p0.x + 10 * z, p0.y + (th - fs) * 0.5f);
					Text(dl, tp + .(1, 1), fs, Gui.Color(0, 0, 0, 160), c.Text);
					Text(dl, tp, fs, Gui.Color(255, 255, 255), c.Text);
					Gui.ImDrawList_PopClipRect(dl);
				}
			}
		}

		/// Nodes whose whole rectangle lies inside the comment.
		void NodesInComment(GraphComment c, List<int32> outIds)
		{
			for (let L in mLayById.Values)
			{
				let n = L.Node;
				if (n.X >= c.X && n.Y >= c.Y && n.X + L.W <= c.X + c.W && n.Y + L.H <= c.Y + c.H)
					outIds.Add(n.Id);
			}
		}

		/// C: a comment around the selected nodes, or an empty one at the mouse (UE).
		public void CreateComment(GraphTab tab, Graph graph)
		{
			float minX = float.MaxValue;
			float minY = float.MaxValue;
			float maxX = float.MinValue;
			float maxY = float.MinValue;
			for (let id in tab.SelectedNodes)
			{
				let n = graph.FindNode(id);
				if (n == null)
					continue;
				NodeLay L;
				if (!mLayById.TryGetValue(id, out L))
					continue;
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
				maxX = Math.Max(maxX, n.X + L.W);
				maxY = Math.Max(maxY, n.Y + L.H);
			}
			for (let id in tab.SelectedComments)
			{
				let c = FindComment(id);
				if (c == null)
					continue;
				minX = Math.Min(minX, c.X);
				minY = Math.Min(minY, c.Y);
				maxX = Math.Max(maxX, c.X + c.W);
				maxY = Math.Max(maxY, c.Y + c.H);
			}
			mApp.BeginEdit();
			GraphComment c = new .();
			c.MethodKey.Set(tab.MethodKey);
			c.Text.Set("Comment");
			if (minX <= maxX)
			{
				const float Pad = 24;
				c.X = Canvas.Snap(minX - Pad);
				c.Y = Canvas.Snap(minY - Pad - CommentTitleH);
				c.W = Canvas.Snap(maxX - minX + Pad * 2 + 8);
				c.H = Canvas.Snap(maxY - minY + Pad * 2 + CommentTitleH + 8);
			}
			else
			{
				let m = MouseGridPos(tab);
				c.X = Canvas.Snap(m.x);
				c.Y = Canvas.Snap(m.y);
				c.W = 400;
				c.H = 200;
			}
			tab.Doc.Comments.Add(c);
			mComments.Add(c);
			tab.ClearSelection();
			tab.SelectedComments.Add(c.Id);
			// Start renaming it right away, like UE.
			tab.EditingComment = c.Id;
			mFocusCommentEdit = true;
			mApp.LayoutChanged();
		}

		void DeleteComments(GraphTab tab, List<int32> ids)
		{
			for (let id in ids)
			{
				let c = FindComment(id);
				if (c == null)
					continue;
				tab.Doc.Comments.Remove(c);
				mComments.Remove(c);
				delete c;
			}
			tab.SelectedComments.Clear();
			mApp.LayoutChanged();
		}

		/// Comment presets (UE's palette is similar: white, and a few muted colours).
		static uint32[8] sCommentColors = .(
			Gui.Color(255, 255, 255, 180), Gui.Color(255, 90, 90, 190), Gui.Color(255, 170, 60, 190), Gui.Color(250, 230, 80, 190),
			Gui.Color(110, 220, 110, 190), Gui.Color(80, 190, 255, 190), Gui.Color(170, 120, 255, 190), Gui.Color(120, 120, 120, 200));

		/// Colour swatches + a full RGBA picker. Returns true when the colour changed.
		bool CommentColorEditor(GraphComment c)
		{
			bool changed = false;
			for (int i < sCommentColors.Count)
			{
				if (i > 0)
					Gui.SameLine(0, 4);
				Gui.PushID((int32)i);
				if (Gui.igColorButton("##preset", Gui.igColorConvertU32ToFloat4(sCommentColors[i]), ColorEditFlags.AlphaPreviewHalf, .(20, 20)))
				{
					c.Color = sCommentColors[i];
					changed = true;
				}
				Gui.PopID();
			}
			let v = Gui.igColorConvertU32ToFloat4(c.Color);
			float[4] col = .(v.x, v.y, v.z, v.w);
			Gui.igSetNextItemWidth(-1);
			if (Gui.igColorEdit4("##ccolor", &col[0], ColorEditFlags.AlphaBar | ColorEditFlags.AlphaPreviewHalf))
			{
				c.Color = Gui.igColorConvertFloat4ToU32(.(col[0], col[1], col[2], col[3]));
				changed = true;
			}
			if (changed)
				mApp.LayoutChanged();
			return changed;
		}

		/// Properties panel content for a selected comment box. Returns false if no comment is the
		/// selection (then the caller shows something else).
		public bool DrawCommentDetails(GraphTab tab)
		{
			if (tab == null || tab.SelectedComments.Count != 1 || !tab.SelectedNodes.IsEmpty)
				return false;
			GraphComment c = null;
			for (let cc in tab.Doc.Comments)
				if (cc.Id == tab.SelectedComments[0])
					c = cc;
			if (c == null)
				return false;
			Gui.SeparatorText("Comment");
			Gui.TextColored(Theme.TextDim, "Text");
			mCommentBuf.Set(c.Text);
			Gui.PushID("##commentdetails");
			if (Gui.igInputTextMultiline("##ctext", mCommentBuf.Ptr, (.)mCommentBuf.Capacity, .(-1, 70 * Look.Scale), 0, null, null))
			{
				c.Text.Set(mCommentBuf.View);
				mApp.LayoutChanged();
			}
			Gui.TextColored(Theme.TextDim, "Comment Color");
			CommentColorEditor(c);
			Gui.PopID();
			Gui.igSpacing();
			Gui.TextWrappedDim("Comment boxes are layout only: they are saved in the .vblayout file next to the source, not in the Beef code. Drag the title to move it with the nodes inside; drag the corner to resize; double-click the title to rename.");
			return true;
		}

		// ------------------------------------------------------------------ find, watermark, tips

		void DrawWatermark(GraphTab tab, MethodGraph mg, ImDrawList* dl)
		{
			// UE's faint graph-type label in the bottom-right corner.
			String text = scope .("VISUALBEEF");
			if (mg.Owner != null)
				text.AppendF("  \u{00B7}  {}", mg.Owner.Name);
			float size = mFontSize * 2.6f;
			let tw = Gui.CalcTextSize(text).x * 2.6f;
			let pos = tab.CanvasOrigin + tab.CanvasSize - ImVec2(tw + 28, size + 22);
			Text(dl, pos, size, Gui.Color(255, 255, 255, 26), text);
		}

		void DrawFindBox(GraphTab tab, Graph graph)
		{
			if (!tab.FindOpen)
				return;
			let origin = tab.CanvasOrigin;
			Gui.igSetCursorScreenPos(origin + ImVec2(12, 12));
			Gui.igPushStyleColor_U32(Col.ChildBg, Gui.Color(24, 24, 24, 240));
			var findText = mFindBuf.View;
			findText.Trim();
			float boxH = findText.IsEmpty ? (Gui.igGetFrameHeight() * 2 + 24) : Math.Min(320, tab.CanvasSize.y - 24);
			if (Gui.igBeginChild_Str("##vbfind", .(400, boxH), ChildFlags.Borders, 0))
			{
				Gui.TextColored(Gui.Color(220, 220, 220), "Find in Sheets");
				Gui.SameLine(Gui.igGetWindowSize().x - 30, -1);
				if (Gui.SmallButton("x"))
					tab.FindOpen = false;
				if (tab.FindFocus)
				{
					Gui.igSetKeyboardFocusHere(0);
					tab.FindFocus = false;
				}
				Gui.igSetNextItemWidth(-1);
				bool enter = Gui.igInputTextWithHint("##find", "Search nodes, names, values...", mFindBuf.Ptr, (.)mFindBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				if (Gui.igIsItemActive() && Gui.IsKeyPressed(Key.Escape, false))
					tab.FindOpen = false;
				var search = mFindBuf.View;
				search.Trim();
				if (!search.IsEmpty && Gui.igBeginChild_Str("##results", .(0, 0), 0, 0))
				{
					int shown = 0;
					String hay = scope .();
					String title = scope .();
					for (let n in graph.Nodes)
					{
						hay.Clear();
						title.Clear();
						GetDisplayTitle(graph, n, title);
						hay.AppendF("{} {} {}", title, n.Text, n.Text2);
						for (let p in n.Inputs)
							hay.AppendF(" {} {}", p.Label, p.Default);
						for (let p in n.Outputs)
							hay.AppendF(" {}", p.Label);
						bool match = true;
						for (let word in search.Split(' '))
							if (!word.IsEmpty && hay.IndexOf(word, true) < 0)
								match = false;
						if (!match)
							continue;
						Gui.PushID(n.Id);
						String label = scope .();
						label.Append(title);
						let setTarget = (n.Kind == .Set) ? n.FindInput("target") : null;
						if (setTarget != null && !graph.IsLinked(setTarget))
							label.AppendF("  {}", setTarget.Default);
						else if (n.Kind == .Call)
							label.Append(n.IsPure ? "   (value call)" : "   (function call)");
						else if (n.Kind == .Get)
							label.Append("   (variable)");
						if (n.Kind == .Code || n.Kind == .Expr)
						{
							label.Append(":  ");
							var first = StringView(n.Text);
							int nl = first.IndexOf('\n');
							if (nl >= 0)
								first = first.Substring(0, nl);
							label.Append(first);
						}
						if (Gui.Selectable(label, tab.IsSelected(n.Id)) || (enter && shown == 0))
						{
							tab.SelectOnly(n.Id);
							float w = 160;
							float h = 60;
							if (mLayById.TryGetValue(n.Id, let L))
							{
								w = L.W;
								h = L.H;
							}
							tab.CenterOn(n.X + w * 0.5f, n.Y + h * 0.5f);
						}
						Gui.PopID();
						if (++shown >= 200)
							break;
					}
					if (shown == 0)
						Gui.TextDisabled("No matching nodes.");
					Gui.igEndChild();
				}
			}
			Gui.igEndChild();
			Gui.igPopStyleColor(1);
		}

		/// UE-style tooltip for a node after hovering it for a moment.
		void NodeTooltip(GraphTab tab, Graph graph, Node node, String tip)
		{
			switch (node.Kind)
			{
			case .Call:
				let target = node.FindInput("target");
				StringView typeName = default;
				if (target != null)
				{
					typeName = target.TypeName;
					if (typeName.IsEmpty && !graph.IsLinked(target) && !target.Default.IsEmpty && target.Default[0].IsUpper)
						typeName = target.Default;
				}
				SymbolMethod sm = null;
				SymbolType st = null;
				if (!typeName.IsEmpty)
				{
					st = mApp.Index.FindType(NodeMenu.BaseTypeName(typeName));
					sm = st?.FindMethod(node.Text);
				}
				let mg = tab.Doc.FindMethod(tab.MethodKey);
				if (sm == null && target == null && mg != null && mg.Owner != null)
				{
					st = mApp.Index.FindType(mg.Owner.Name);
					sm = st?.FindMethod(node.Text);
					typeName = mg.Owner.Name;
				}
				if (sm != null)
					tip.AppendF("{} {}({})", sm.ReturnType, node.Text, sm.ParamsText);
				else
				{
					let res = node.Result;
					tip.AppendF("{} {}(", (res != null && !res.TypeName.IsEmpty) ? StringView(res.TypeName) : (node.IsPure ? "var" : "void"), node.Text);
					int i = 0;
					for (let p in node.Inputs)
					{
						if (p.Kind != .Data || p.Name == "target")
							continue;
						if (i++ > 0)
							tip.Append(", ");
						tip.AppendF("{}{}{}", p.TypeName, p.TypeName.IsEmpty ? "" : " ", p.Label);
					}
					tip.Append(")");
				}
				if (node.Binding == .Static)
					tip.AppendF("\nStatic: Receiver is {}", (node.OwnerType != null) ? (StringView)node.OwnerType : (StringView)(node.Qualifier ?? "?"));
				else if (!typeName.IsEmpty)
					tip.AppendF("\nReceiver is {}{}", typeName, (target != null && IsSelfTarget(graph, target)) ? " (this)" : "");
				else if (target != null && graph.IsLinked(target))
					tip.Append("\nReceiver is the wired object");
				tip.Append(node.IsPure ? "\nValue call (evaluated where its value is used)" : "");
			case .Get:
				let r = node.Result;
				tip.AppendF("{}\nType: {}", node.Text, (r != null && !r.TypeName.IsEmpty) ? StringView(r.TypeName) : "(unknown)");
			case .Set:
				let t = node.FindInput("target");
				if (t != null)
					tip.AppendF("{} {} value\nType: {}", graph.IsLinked(t) ? "(Receiver)" : StringView(t.Default), node.Text, t.TypeName.IsEmpty ? "(unknown)" : StringView(t.TypeName));
			case .LocalVar:
				tip.AppendF("Local variable {}\nType: {}", node.Text, node.Text2);
			case .ForEach:
				tip.AppendF("for ({} {} in Collection)", node.Text2, node.Text);
			case .Branch:
				tip.Append("Branch: if (Condition) runs True, otherwise False");
			case .While:
				tip.Append("While Loop: runs Loop Body while Condition is true");
			case .DoWhile:
				tip.Append("Do While Loop: runs Loop Body, then repeats while Condition is true");
			case .Code:
				if (node.Reason != null)
					tip.Append(node.Reason);
			case .Switch:
				tip.Append("Switch: runs the output of the case that matches Value, or Default");
			case .Flow:
				FlowMacros.GetSummary(node, tip);
			case .Entry:
				let mg = tab.Doc.FindMethod(tab.MethodKey);
				if (mg != null)
				{
					tip.AppendF("{} {}(", (mg.Method.TypeText != null) ? mg.Method.TypeText : "void", mg.Method.Name);
					for (let p in mg.Method.Params)
					{
						if (@p.Index > 0)
							tip.Append(", ");
						tip.AppendF("{} {}", p.Type, p.Name);
					}
					tip.Append(")");
				}
			case .Cast:
				tip.AppendF("Cast To {}", node.Text);
			case .This:
				tip.AppendF("This: {}\nWire it into the Receiver to call a function on this object.", graph.SelfType);
			case .Base:
				tip.AppendF("Base: base ({})\nWire it into the Receiver to call the base version of a function, e.g. base.Tick(DeltaSeconds).", node.Result?.TypeName ?? "");
			case .Construct:
				String sub = scope .();
				LifetimeSubtitle(node, sub);
				tip.AppendF("{}\n{}", (node.Result != null && !node.Result.TypeName.IsEmpty) ? (StringView)node.Result.TypeName : "(type from where the value goes)", sub);
			case .Delete:
				tip.Append("Delete: frees the object made with new (delete obj;)");
			case .Defer:
				tip.Append("Defer: Deferred runs when the enclosing block ends; several Defers run last-first");
			case .Using:
				tip.Append("Using: Body runs, then Value is disposed (using (Value) { Body })");
			case .ResultMatch:
				tip.AppendF("Result match: if (Result case .{}) runs {}, otherwise {}\nThe {} pin is set in the {} arm only", node.Text, node.Text,
					(node.Text == "Ok") ? "Err" : "Ok", (node.Text == "Ok") ? "Value" : "Error", node.Text);
			case .Scope:
				tip.Append("Scope: a nested block { Body }. Locals declared in it, and values made with scope, end when it ends.");
			case .Lambda:
				if (node.Text.IsEmpty)
					tip.AppendF("Create Delegate: {} => {}\nA delegate bound to the function {}; wire it into an event's Add, a += or a parameter.", node.Alloc ?? "", node.Text2, node.Text2);
				else
				{
					String sub = scope .();
					sCaptureGraph = graph;
					LifetimeSubtitle(node, sub);
					tip.AppendF("Lambda {} => ...\nA function value. Its parameters are read by name inside it; the locals it reads from this function are its captures.\n{}", node.Text, sub);
				}
			case .LocalFunc:
				tip.AppendF("Local function: {}\nDeclared inside this function; call it by name after this node.", node.Text2);
			case .Format:
				tip.AppendF("Format Text: {}\nAn interpolated string: each {{hole}} is an input, the text and the :format parts are set in Properties.", node.Text);
			case .MathExpr:
				tip.AppendF("Math Expression: {}\nEvery name in it is an input; Result is its value. Edit it on the node or in Properties.", node.Text);
			default:
			}
			if (node.Original != null && !node.Original.IsEmpty && node.Kind != .Entry && node.Original.Length < 200 && !node.Edited)
				tip.AppendF("\n\n{}", node.Original);
		}

		// ------------------------------------------------------------------ variables

		/// A name for a new local that isn't used yet in this function.
		public static void UniqueLocalName(MethodGraph mg, StringView baseName, String outName)
		{
			HashSet<String> used = scope .();
			defer { for (let s in used) delete s; }
			if (mg != null)
			{
				for (let p in mg.Method.Params)
					used.Add(new String(p.Name));
				for (let n in mg.Graph.Locals)
					used.Add(new String(n.Text));
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .LocalVar || n.Kind == .ForEach)
						used.Add(new String(n.Text));
			}
			outName.Set(baseName);
			for (int i = 1; used.Contains(outName); i++)
			{
				outName.Set(baseName);
				outName.AppendF("{}", i);
			}
		}

		/// Called after a variable was dropped without Ctrl/Alt: offers Get / Set (UE).
		public void ShowVariableDropMenu(StringView name, StringView type, ImVec2 gridPos)
		{
			mVarDropOpen = true;
			mVarDropName.Set(name);
			mVarDropType.Set(type);
			mVarDropPos = gridPos;
		}

		/// Pin context menu: Make variable / Make local variable (an output: the variable and a Set
		/// fed by the pin) and Make variable (Get) (an input: the variable and a Get wired into it).
		/// One undo step; the Beef is the declaration plus the statement.
		public void MakeVariableFromPin(GraphTab tab, MethodGraph mgIn, Pin pinIn, bool member)
		{
			var mg = mgIn;
			String type = scope .();
			String why = scope .();
			if (!mApp.PinVariableType(mg, pinIn, member, type, why))
			{
				Notify.Warn(why);
				return;
			}
			String baseName = scope .();
			PinVariableBase(pinIn, baseName);
			String name = scope .();
			let pinId = pinIn.Id;
			let graph = mg.Graph;
			if (member)
			{
				// The member first (its own text edit), then the nodes, merged into one undo step.
				// The edit reads the file again: the MethodGraph wrapper is replaced, the graph kept.
				let key = scope String(mg.Key);
				let doc = mg.Doc;
				if (!mApp.MakeMemberForPin(mg, baseName, type, name))
					return;
				mg = doc.FindMethod(key);
				if (mg == null || mg.Graph != graph)
				{
					Notify.Warn("The variable was added; the Sheet was read again, so place its Get / Set from the Node menu.");
					return;
				}
				mApp.BeginEdit();
				mg.Doc.DropLastUndo(); // one undo step with the member
			}
			else
			{
				mApp.BeginEdit();
				EditorApp.UniqueLocalName(mg, baseName, name);
				String value = scope .();
				NodeFactory.ReturnDefault(type, value);
				NodeFactory.AddLocal(graph, name, type, value);
			}
			let pin = graph.FindPin(pinId);
			if (pin == null)
				return;
			if (!pin.IsInput)
			{
				PlaceSetFromPin(tab, mg, pin, name, type);
				return;
			}
			let get = NodeFactory.Get(graph, name, type);
			graph.Connect(get.Result, pin);
			get.X = Canvas.Snap(pin.Owner.X - 220);
			get.Y = Canvas.Snap(pin.Owner.Y + 20);
			get.HasPos = true;
			tab.SelectOnly(get.Id);
			mApp.CommitCurrent();
			mCommitted = true;
		}

		/// A variable name made from a pin's label (`Return Value` -> `returnValue`), or `value`.
		public static void PinVariableBase(Pin pin, String outName)
		{
			bool up = false;
			for (let c in pin.Label.RawChars)
			{
				if (c.IsLetterOrDigit || c == '_')
				{
					outName.Append((up && !outName.IsEmpty) ? c.ToUpper : c);
					up = false;
				}
				else
					up = true;
			}
			if (outName.IsEmpty || outName[0].IsDigit)
				outName.Set("value");
			else
				outName[0] = outName[0].ToLower;
			if (VisualBeef.Syntax.Parser.IsReservedWord(outName))
				outName.Append("Value");
		}

		/// The pin context menu's Make variable / Make local variable for a data output: a Set of
		/// `name` fed by the pin, inserted in the flow after the pin's node (or before the first
		/// statement that uses the value). The caller has taken the undo step and made the variable.
		void PlaceSetFromPin(GraphTab tab, MethodGraph mg, Pin pin, StringView name, StringView type)
		{
			let graph = mg.Graph;
			let owner = pin.Owner;
			// Where it runs: after an exec owner; for a pure owner, before the statement using it.
			Node before = null;
			if (!owner.IsExecNode)
			{
				List<Node> stack = scope .();
				HashSet<Node> seen = scope .();
				stack.Add(owner);
				while (!stack.IsEmpty && before == null)
				{
					let cur = stack.PopBack();
					if (!seen.Add(cur))
						continue;
					for (let l in graph.Links)
					{
						if (l.From.Owner != cur || l.From.Kind != .Data)
							continue;
						let user = l.To.Owner;
						if (user.IsExecNode && user != graph.Entry && user.ExecIn != null && graph.IsLinked(user.ExecIn))
						{
							before = user;
							break;
						}
						stack.Add(user);
					}
				}
			}

			let n = NodeFactory.Set(graph, name, type);
			let value = n.FindInput("value");
			if (value != null)
				graph.Connect(pin, value);
			float w = mLayById.TryGetValue(owner.Id, let L) ? L.W : 200;
			n.X = Canvas.Snap(owner.X + w + 60);
			n.Y = Canvas.Snap(owner.Y);
			n.HasPos = true;

			if (owner.IsExecNode && owner.Then != null)
			{
				let after = ((pin.Name == "element" || pin.Name == "counter") && owner.FindOutput("body") != null) ? owner.FindOutput("body") : owner.Then;
				let oldNext = graph.ExecTarget(after);
				graph.Connect(after, n.ExecIn);
				if (oldNext != null)
					graph.Connect(n.Then, oldNext.ExecIn);
			}
			else if (before != null)
			{
				let inLink = graph.FindLinkTo(before.ExecIn);
				let prev = inLink.From;
				graph.Connect(prev, n.ExecIn);
				graph.Connect(n.Then, before.ExecIn);
				n.X = Canvas.Snap(before.X - 40);
				n.Y = Canvas.Snap(before.Y - 140);
			}
			tab.SelectOnly(n.Id);
			mApp.CommitCurrent();
			mCommitted = true;
		}

		/// The value an input pin goes back to with "Reset to Default".
		static void PinDefaultValue(Pin p, String outValue)
		{
			String t = scope .();
			NodeMenu.NormalizeType(p.TypeName, t);
			if (p.Owner.Kind == .Branch || p.Owner.Kind == .While || p.Owner.Kind == .DoWhile)
				outValue.Set("true");
			else if (t == "bool")
				outValue.Set("false");
			else if (t == "float")
				outValue.Set("0.0f");
			else if (t == "double")
				outValue.Set("0.0");
			else if (NodeMenu.IsNumeric(t))
				outValue.Set("0");
			else if (t == "String" || t == "StringView")
				outValue.Set("\"\"");
			else if (p.Optional || p.Name == "target")
				outValue.Clear();
			else
				outValue.Set("default");
		}

		uint32 HeaderFor(Graph g, Node node)
		{
			// An override's entry reads like UE's red event node (Event Tick).
			if (node == g.Entry && node.Error == null && Mods.Has(g.DeclModifiers, "override"))
				return Gui.Color(140, 26, 26);
			switch (node.Kind)
			{
			case .Set:
				let t = node.FindInput("target");
				let v = node.FindInput("value");
				StringView type = (t != null && !t.TypeName.IsEmpty) ? t.TypeName : ((v != null) ? v.TypeName : "");
				return Theme.VariableHeader(type);
			case .LocalVar:
				StringView type = node.Text2;
				if (NodeMenu.IsWild(type))
				{
					let v = node.FindOutput("variable");
					let val = node.FindInput("value");
					if (v != null && !v.TypeName.IsEmpty)
						type = v.TypeName;
					else if (val != null && g.IsLinked(val))
					{
						let src = g.FindLinkTo(val)?.From;
						if (src != null)
							type = src.TypeName;
					}
				}
				return Theme.VariableHeader(type);
			default:
				return PinStyle.Header(node);
			}
		}

		/// Width taken by the header icon (grid units at zoom 1); 0 without the icon font.
		float HeaderIconW(Node node) => (Icon.Loaded && !PinStyle.HeaderIcon(node).IsEmpty) ? mFontSize * 1.25f : 0;

		// ------------------------------------------------------------------ input

		void HandleMouse(GraphTab tab, MethodGraph mg, ImVec2 mouse, bool activated, bool mouseInCanvas)
		{
			let graph = mg.Graph;

			// ---- Press
			if (activated && tab.Mode == .None)
			{
				bool dbl = Gui.igIsMouseDoubleClicked_Nil(0);
				if (dbl && mHoverNode != 0)
				{
					tab.CancelInteraction();
					mApp.NodeDoubleClicked(graph.FindNode(mHoverNode));
					return;
				}
				if (dbl && mHoverLink != 0)
				{
					// UE: double-click a wire to add a reroute knot.
					tab.CancelInteraction();
					AddKnot(tab, graph, mHoverLink, mHoverLinkSegment, mouse);
					return;
				}
				if (dbl && mHoverComment != 0 && mHoverCommentResize == 0)
				{
					tab.CancelInteraction();
					tab.EditingComment = mHoverComment;
					mFocusCommentEdit = true;
					return;
				}
				if (Gui.igIsMouseClicked_Bool(0, false))
				{
					if (!BubblePress(tab, mg, mouse))
						PressLeft(tab, mg, mouse);
				}
				else if (Gui.igIsMouseClicked_Bool(1, false))
				{
					tab.Mode = .RightPending;
					tab.ModeButton = 1;
					tab.PressPos = mouse;
				}
				else if (Gui.igIsMouseClicked_Bool(2, false))
				{
					tab.Mode = .Pan;
					tab.ModeButton = 2;
					tab.PressPos = mouse;
				}
				if (mCommitted)
					return;
			}

			// ---- Marquee selection follows the mouse
			if (tab.Mode == .Marquee)
			{
				let a = ImVec2(Math.Min(tab.PressPos.x, mouse.x), Math.Min(tab.PressPos.y, mouse.y));
				let b = ImVec2(Math.Max(tab.PressPos.x, mouse.x), Math.Max(tab.PressPos.y, mouse.y));
				tab.SelectedNodes.Clear();
				tab.SelectedNodes.AddRange(tab.MarqueeBase);
				for (let L in mOrder)
				{
					let p0 = tab.GridToScreen(L.Node.X, L.Node.Y);
					let p1 = p0 + ImVec2(L.W, L.H) * tab.Zoom;
					if (Canvas.RectsOverlap(a, b, p0, p1))
						tab.AddToSelection(L.Node.Id);
				}
				// Comments are selected when the marquee encloses them completely.
				tab.SelectedComments.Clear();
				tab.SelectedComments.AddRange(tab.MarqueeCommentBase);
				for (let c in mComments)
				{
					let p0 = tab.GridToScreen(c.X, c.Y);
					let p1 = tab.GridToScreen(c.X + c.W, c.Y + c.H);
					if (p0.x >= a.x && p0.y >= a.y && p1.x <= b.x && p1.y <= b.y && !tab.SelectedComments.Contains(c.Id))
						tab.SelectedComments.Add(c.Id);
				}
			}

			// ---- Node hotkeys while a wire is dragged: the node drops at the cursor, wired to the pin.
			if (tab.Mode == .Wire && mCanvasKeys && mouseInCanvas && WireHotkey(tab, mg, NodeHotkeyLetter(true), mouse))
				return;

			// ---- Release
			if (tab.Mode != .None && !Gui.igIsMouseDown_Nil(tab.ModeButton))
			{
				let mode = tab.Mode;
				let d = mouse - tab.PressPos;
				bool dragged = d.x * d.x + d.y * d.y > 16;
				switch (mode)
				{
				case .RightPending:
					tab.CancelInteraction();
					OpenContextMenu(tab, graph, mouse);
				case .MoveNodes:
					if (tab.Moved)
						mApp.LayoutChanged();
					else if (tab.PressNode != 0 && tab.PressNodeWasSelected && !Gui.IsCtrlDown && !Gui.IsShiftDown)
						tab.SelectOnly(tab.PressNode);
					else if (tab.PressComment != 0 && tab.PressCommentWasSelected && !Gui.IsCtrlDown && !Gui.IsShiftDown)
					{
						tab.ClearSelection();
						tab.SelectedComments.Add(tab.PressComment);
					}
					tab.CancelInteraction();
				case .ResizeComment, .MoveKnot:
					if (dragged)
						mApp.LayoutChanged();
					tab.CancelInteraction();
				case .Wire:
					let src = graph.FindPin(tab.DragPin);
					let target = DropTarget(graph, src);
					tab.CancelInteraction();
					if (src == null)
						break;
					if (target != null)
					{
						mApp.BeginEdit();
						if (src.IsInput)
							graph.Connect(target, src);
						else
							graph.Connect(src, target);
						// A call takes the overload that fits the value now wired into it.
						mApp.RefitCall(graph, (src.IsInput ? src : target).Owner);
						mApp.CommitCurrent();
						mCommitted = true;
					}
					else if (mHoverPin != 0 && mHoverPin != src.Id)
					{
						String why = scope .();
						Graph.CanConnectTyped(src, graph.FindPin(mHoverPin), why);
						mApp.SetStatus(why.IsEmpty ? "Those pins can't be connected." : scope $"Can't connect: {why}");
					}
					else if (dragged && mHoverNode == 0 && mHoverPin == 0 && mouseInCanvas)
						mApp.OpenNodeMenu(tab, tab.ScreenToGrid(mouse), src.Id);
				case .Relink:
					let target = (mHoverPin != 0) ? graph.FindPin(mHoverPin) : null;
					List<int32> ids = scope .();
					ids.AddRange(tab.DragLinks);
					int32 fromPin = tab.DragPin;
					tab.CancelInteraction();
					if (target == null || target.Id == fromPin)
						break;
					bool any = false;
					for (let id in ids)
					{
						let link = graph.FindLink(id);
						if (link == null)
							continue;
						let other = (link.From.Id == fromPin) ? link.To : link.From;
						if (!Graph.CanConnectTyped(other, target) && !OverloadTakes(graph, other, target))
							continue;
						if (!any)
							mApp.BeginEdit();
						any = true;
						graph.Disconnect(link);
						graph.Connect(other, target);
						mApp.RefitCall(graph, target.IsInput ? target.Owner : other.Owner);
					}
					if (any)
					{
						mApp.CommitCurrent();
						mCommitted = true;
					}
					else
						mApp.SetStatus("Those links can't be moved to that pin.");
				default:
					tab.CancelInteraction();
				}
			}
		}

		/// Starts a MoveNodes drag of the selection, plus everything inside selected comments.
		void BeginMoveSelection(GraphTab tab, Graph graph)
		{
			tab.Mode = .MoveNodes;
			tab.DragStart.Clear();
			tab.DragCommentStart.Clear();
			List<int32> ids = scope .();
			ids.AddRange(tab.SelectedNodes);
			List<int32> commentIds = scope .();
			commentIds.AddRange(tab.SelectedComments);
			// Comments carry their contents (nodes and smaller comments inside them).
			for (int i = 0; i < commentIds.Count; i++)
			{
				let c = FindComment(commentIds[i]);
				if (c == null)
					continue;
				NodesInComment(c, ids);
				for (let other in mComments)
				{
					if (other == c || commentIds.Contains(other.Id))
						continue;
					if (other.X >= c.X && other.Y >= c.Y && other.X + other.W <= c.X + c.W && other.Y + other.H <= c.Y + c.H)
						commentIds.Add(other.Id);
				}
			}
			for (let id in ids)
			{
				let n = graph.FindNode(id);
				if (n != null)
					tab.DragStart[id] = .(n.X, n.Y);
			}
			for (let id in commentIds)
			{
				let c = FindComment(id);
				if (c != null)
					tab.DragCommentStart[id] = .(c.X, c.Y);
			}
		}

		/// This Sheet has the keyboard this frame (its window focused, no other item active).
		bool mCanvasKeys;

		/// Node hotkeys (docs/Editor-UI.md, "Node hotkeys and favorites"): the letter of a node hotkey
		/// that is held (`pressed`: pressed this frame) with no modifier key, '\0' when none. Only
		/// letters bound to a node count, so the Sheet's own letters (C, F, M, Q) never match.
		public char8 NodeHotkeyLetter(bool pressed)
		{
			if (Gui.IsCtrlDown || Gui.IsAltDown || Gui.IsShiftDown)
				return '\0';
			let hotkeys = mApp.NodePrefs.Hotkeys;
			for (int i < 26)
			{
				let letter = (char8)('A' + i);
				if (hotkeys.NodeOf(letter).IsEmpty)
					continue;
				let key = NodeMenu.cKeyA + (int32)i;
				if (pressed ? Gui.IsKeyPressed(key, false) : Gui.IsKeyDown(key))
					return letter;
			}
			return '\0';
		}

		/// Node hotkeys: a letter held while clicking empty canvas places its node at the click
		/// (B + click = Branch with the default keys). True when the click was taken.
		public bool HotkeyClick(GraphTab tab, MethodGraph mg, char8 letter, ImVec2 mouse)
		{
			if (letter == '\0')
				return false;
			if (mApp.PlaceHotkeyNode(tab, letter, tab.ScreenToGrid(mouse), 0))
				mCommitted = true;
			return true;
		}

		/// Node hotkeys: a letter pressed while a wire is dragged from a pin drops its node at
		/// `mouse`, connected to that pin the way the Node menu connects a node chosen there. True
		/// when the key was taken (the wire drag ends either way).
		public bool WireHotkey(GraphTab tab, MethodGraph mg, char8 letter, ImVec2 mouse)
		{
			if (letter == '\0' || tab.Mode != .Wire)
				return false;
			let src = mg.Graph.FindPin(tab.DragPin);
			tab.CancelInteraction();
			if (src != null && mApp.PlaceHotkeyNode(tab, letter, tab.ScreenToGrid(mouse), src.Id))
				mCommitted = true;
			return true;
		}

		void PressLeft(GraphTab tab, MethodGraph mg, ImVec2 mouse)
		{
			let graph = mg.Graph;
			tab.PressPos = mouse;
			tab.ModeButton = 0;
			tab.Moved = false;
			bool ctrl = Gui.IsCtrlDown;
			bool shift = Gui.IsShiftDown;
			bool alt = Gui.IsAltDown;

			if (mHoverPin != 0)
			{
				let pin = graph.FindPin(mHoverPin);
				if (pin == null)
					return;
				if (alt)
				{
					// Alt+click: break all of the pin's links.
					if (graph.IsLinked(pin))
					{
						mApp.BeginEdit();
						graph.DisconnectPin(pin);
						mApp.CommitCurrent();
						mCommitted = true;
					}
					return;
				}
				if (ctrl && graph.IsLinked(pin))
				{
					// Ctrl+drag: pick up the existing links and move them.
					tab.Mode = .Relink;
					tab.DragPin = pin.Id;
					tab.DragLinks.Clear();
					for (let l in graph.Links)
						if (l.From == pin || l.To == pin)
							tab.DragLinks.Add(l.Id);
					return;
				}
				tab.Mode = .Wire;
				tab.DragPin = pin.Id;
				return;
			}

			if (mHoverNode != 0)
			{
				int32 id = mHoverNode;
				tab.SelectedLinks.Clear();
				tab.SelectedKnot = default;
				tab.PressNode = id;
				tab.PressNodeWasSelected = tab.IsSelected(id);
				if (ctrl)
				{
					tab.ToggleSelection(id);
					return;
				}
				if (shift)
					tab.AddToSelection(id);
				else if (!tab.IsSelected(id))
				{
					tab.SelectOnly(id);
				}
				BeginMoveSelection(tab, graph);
				return;
			}

			if (mHoverKnot.IsValid)
			{
				if (alt)
				{
					RemoveKnot(tab, mHoverKnot, true);
					return;
				}
				let route = FindKnot(mHoverKnot);
				if (route == null)
					return;
				tab.ClearSelection();
				tab.SelectedKnot = mHoverKnot;
				tab.Mode = .MoveKnot;
				tab.DragKnot = mHoverKnot;
				let pt = route.Points[mHoverKnot.Index];
				tab.DragVec = .(pt.X, pt.Y);
				return;
			}

			if (mHoverCommentResize != 0)
			{
				let c = FindComment(mHoverCommentResize);
				if (c == null)
					return;
				if (!tab.IsCommentSelected(c.Id))
				{
					tab.ClearSelection();
					tab.SelectedComments.Add(c.Id);
				}
				tab.Mode = .ResizeComment;
				tab.DragComment = c.Id;
				tab.DragVec = .(c.W, c.H);
				return;
			}

			if (mHoverLink != 0)
			{
				let link = graph.FindLink(mHoverLink);
				if (link == null)
					return;
				if (alt)
				{
					mApp.BeginEdit();
					graph.Disconnect(link);
					mApp.CommitCurrent();
					mCommitted = true;
					return;
				}
				// Select the wire (Delete removes it).
				if (!ctrl && !shift)
					tab.ClearSelection();
				if (!tab.SelectedLinks.Contains(link.Id))
					tab.SelectedLinks.Add(link.Id);
				return;
			}

			if (mHoverComment != 0)
			{
				// Comment title: select it; dragging moves it with everything inside.
				int32 id = mHoverComment;
				tab.SelectedLinks.Clear();
				tab.SelectedKnot = default;
				tab.PressComment = id;
				tab.PressCommentWasSelected = tab.IsCommentSelected(id);
				if (ctrl)
				{
					if (!tab.SelectedComments.Remove(id))
						tab.SelectedComments.Add(id);
					return;
				}
				if (!tab.IsCommentSelected(id))
				{
					if (!shift)
						tab.ClearSelection();
					tab.SelectedComments.Add(id);
				}
				BeginMoveSelection(tab, graph);
				return;
			}

			// Empty space: a node hotkey held while clicking places its node, else marquee.
			if (!ctrl && !shift && !alt && HotkeyClick(tab, mg, NodeHotkeyLetter(false), mouse))
				return;
			tab.Mode = .Marquee;
			tab.MarqueeBase.Clear();
			tab.MarqueeCommentBase.Clear();
			if (ctrl || shift)
			{
				tab.MarqueeBase.AddRange(tab.SelectedNodes);
				tab.MarqueeCommentBase.AddRange(tab.SelectedComments);
			}
			else
				tab.ClearSelection();
		}

		void OpenContextMenu(GraphTab tab, Graph graph, ImVec2 mouse)
		{
			if (mHoverPin != 0)
			{
				tab.CtxPin = mHoverPin;
				Gui.OpenPopup("##vbpinctx");
			}
			else if (mHoverNode != 0)
			{
				if (!tab.IsSelected(mHoverNode))
					tab.SelectOnly(mHoverNode);
				mApp.OpenNodeContext(mHoverNode);
			}
			else if (mHoverKnot.IsValid)
			{
				tab.ClearSelection();
				tab.SelectedKnot = mHoverKnot;
				Gui.OpenPopup("##vbknotctx");
			}
			else if (mHoverLink != 0)
			{
				tab.CtxLink = mHoverLink;
				mCtxLinkSegment = mHoverLinkSegment;
				mCtxMouse = mouse;
				Gui.OpenPopup("##vblinkctx");
			}
			else if (mHoverComment != 0)
			{
				mCtxComment = mHoverComment;
				if (!tab.IsCommentSelected(mHoverComment))
				{
					tab.ClearSelection();
					tab.SelectedComments.Add(mHoverComment);
				}
				Gui.OpenPopup("##vbcommentctx");
			}
			else
				mApp.OpenNodeMenu(tab, tab.ScreenToGrid(mouse), 0);
		}
		int32 mCtxLinkSegment;
		ImVec2 mCtxMouse;

		void DrawContextPopups(GraphTab tab, MethodGraph mg)
		{
			let graph = mg.Graph;
			if (Gui.BeginPopup("##vbpinctx"))
			{
				let pin = graph.FindPin(tab.CtxPin);
				if (pin == null)
					Gui.igCloseCurrentPopup();
				else
				{
					String head = scope .();
					head.Append(pin.Label.IsEmpty ? pin.Name : pin.Label);
					if (pin.Kind == .Data && !pin.TypeName.IsEmpty)
						head.AppendF("  ({})", pin.TypeName);
					Gui.TextDisabled(head);
					Gui.Separator();
					if (Gui.MenuItem("Break Link(s)", "Alt+Click", false, graph.IsLinked(pin)))
					{
						mApp.BeginEdit();
						graph.DisconnectPin(pin);
						mApp.CommitCurrent();
						mCommitted = true;
					}
					if (pin.Kind == .Data && pin.Owner != graph.Entry)
					{
						String type = scope .();
						String why = scope .();
						bool memberOk = mApp.PinVariableType(mg, pin, true, type, why);
						if (!pin.IsInput)
						{
							if (Gui.MenuItem("Make variable", "", false, memberOk))
								MakeVariableFromPin(tab, mg, pin, true);
							if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
								Gui.Tooltip(memberOk ? scope $"A new {type} variable of {mg.Owner?.Name} (Outline > Variables), set from this pin" : why);
							why.Clear();
							type.Clear();
							bool localOk = mApp.PinVariableType(mg, pin, false, type, why);
							if (Gui.MenuItem("Make local variable", "", false, localOk))
								MakeVariableFromPin(tab, mg, pin, false);
							if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
								Gui.Tooltip(localOk ? scope $"A new {type} Local of {mg.Method.Name} (Properties > Locals), set from this pin" : why);
						}
						else
						{
							if (Gui.MenuItem("Make variable (Get)", "", false, memberOk && !graph.IsLinked(pin)))
								MakeVariableFromPin(tab, mg, pin, true);
							if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
								Gui.Tooltip(!memberOk ? why : (graph.IsLinked(pin) ? "This pin is already wired" : scope $"A new {type} variable of {mg.Owner?.Name}, read into this pin (it starts at its default)"));
						}
					}
					if (pin.Kind == .Data && pin.IsInput)
					{
						String def = scope .();
						PinDefaultValue(pin, def);
						bool can = !graph.IsLinked(pin) && pin.Default != def;
						if (Gui.MenuItem("Reset to Default", def.IsEmpty ? "(empty)" : def, false, can))
						{
							mApp.BeginEdit();
							pin.Default.Set(def);
							pin.Owner.Edited = true;
							mApp.CommitCurrent();
							mCommitted = true;
						}
					}
				}
				Gui.EndPopup();
			}
			if (mCommitted)
				return;
			if (Gui.BeginPopup("##vblinkctx"))
			{
				let link = graph.FindLink(tab.CtxLink);
				if (link == null)
					Gui.igCloseCurrentPopup();
				else
				{
					Gui.TextDisabled("Wire");
					Gui.Separator();
					if (Gui.MenuItem("Break This Link", "Alt+Click"))
					{
						mApp.BeginEdit();
						graph.Disconnect(link);
						mApp.CommitCurrent();
						mCommitted = true;
					}
					else if (Gui.MenuItem("Add Reroute Node", "Double-Click"))
						AddKnot(tab, graph, link.Id, mCtxLinkSegment, mCtxMouse);
				}
				Gui.EndPopup();
			}
			if (mCommitted)
				return;
			if (Gui.BeginPopup("##vbknotctx"))
			{
				Gui.TextDisabled("Reroute Node");
				Gui.Separator();
				if (Gui.MenuItem("Remove Reroute Node", "Alt+Click", false, tab.SelectedKnot.IsValid))
					RemoveKnot(tab, tab.SelectedKnot, true);
				Gui.EndPopup();
			}
			if (Gui.BeginPopup("##vbcommentctx"))
			{
				let c = FindComment(mCtxComment);
				if (c == null)
					Gui.igCloseCurrentPopup();
				else
				{
					Gui.TextDisabled("Comment");
					Gui.Separator();
					if (Gui.MenuItem("Rename", "Double-Click"))
					{
						tab.EditingComment = c.Id;
						mFocusCommentEdit = true;
					}
					Gui.TextColored(Theme.TextDim, "Color");
					Gui.igSetNextItemWidth(220 * Look.Scale);
					CommentColorEditor(c);
					Gui.Separator();
					if (Gui.MenuItem("Delete Comment", "Del"))
					{
						mApp.BeginEdit();
						List<int32> ids = scope .();
						ids.Add(c.Id);
						DeleteComments(tab, ids);
					}
				}
				Gui.EndPopup();
			}

			// Variable dropped from Outline without Ctrl/Alt: Get or Set?
			if (mVarDropOpen)
			{
				Gui.OpenPopup("##vbvardrop");
				mVarDropOpen = false;
			}
			if (Gui.BeginPopup("##vbvardrop"))
			{
				int choice = 0;
				if (Gui.MenuItem(scope $"Get {mVarDropName}", "Ctrl+Drag"))
					choice = 1;
				if (Gui.MenuItem(scope $"Set {mVarDropName}", "Alt+Drag"))
					choice = 2;
				if (choice != 0)
				{
					mApp.BeginEdit();
					let n = (choice == 1) ? NodeFactory.Get(graph, mVarDropName, mVarDropType) : NodeFactory.Set(graph, mVarDropName, mVarDropType);
					n.X = Canvas.SnapIf(mVarDropPos.x);
					n.Y = Canvas.SnapIf(mVarDropPos.y);
					n.HasPos = true;
					tab.SelectOnly(n.Id);
					mApp.CommitCurrent();
					mCommitted = true;
					Gui.igCloseCurrentPopup();
				}
				Gui.EndPopup();
			}
		}

		void HandleKeyboard(GraphTab tab, MethodGraph mg)
		{
			bool windowFocused = Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows);
			if (!windowFocused || Gui.igIsAnyItemActive())
				return;
			if (Gui.IsKeyPressed(Key.Delete, false) || (Gui.IsKeyPressed(Key.Backspace, false) && !Gui.IsCtrlDown))
			{
				// Comments and knots are layout: removed here; nodes and wires by the app.
				List<int32> comments = scope .();
				comments.AddRange(tab.SelectedComments);
				let knot = tab.SelectedKnot;
				bool graphSel = !tab.SelectedNodes.IsEmpty || !tab.SelectedLinks.IsEmpty;
				if (!graphSel && (!comments.IsEmpty || knot.IsValid))
					mApp.BeginEdit();
				if (graphSel)
				{
					mApp.DeleteSelection(tab);
					mCommitted = true;
				}
				if (!comments.IsEmpty)
					DeleteComments(tab, comments);
				if (knot.IsValid)
					RemoveKnot(tab, knot, false);
				return;
			}
			if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.D, false))
			{
				mApp.DuplicateSelection(tab);
				mCommitted = true;
				return;
			}
			if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.C, false))
				mApp.CopySelection(tab);
			if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.V, false))
			{
				let mp = Gui.igGetMousePos();
				bool inCanvas = Canvas.RectContains(tab.CanvasOrigin, tab.CanvasOrigin + tab.CanvasSize, mp);
				mApp.Paste(tab, inCanvas ? MouseGridPos(tab) : mApp.ViewCentre(tab));
				mCommitted = true;
				return;
			}
			if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.A, false))
			{
				tab.ClearSelection();
				for (let n in mg.Graph.Nodes)
					tab.SelectedNodes.Add(n.Id);
				for (let c in mComments)
					tab.SelectedComments.Add(c.Id);
			}
			// UE: C wraps the selection in a comment box (or drops one at the mouse).
			if (!Gui.IsCtrlDown && !Gui.IsAltDown && Gui.IsKeyPressed(Key.C, false))
				CreateComment(tab, mg.Graph);
			// Ctrl+F (or Ctrl+Shift+F): Find in Sheets.
			if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.F, false))
			{
				tab.FindOpen = true;
				tab.FindFocus = true;
				return;
			}
			if (Gui.IsKeyPressed(Key.Home, false))
				GoHome(tab, mg.Graph);
			if (!Gui.IsAltDown && !Gui.IsShiftDown)
				for (int n = 1; n <= 9; n++)
					if (Gui.IsKeyPressed(KeyDigit0 + (int32)n, false))
					{
						if (Gui.IsCtrlDown)
							SaveView(tab, n);
						else
							JumpToView(tab, n);
					}
			// UE alignment shortcuts: Shift+W/S/A/D, Alt+Shift+W/S (middle / center),
			// Alt+Shift+H/V (distribute), Q (straighten). M toggles the minimap.
			bool sh = Gui.IsShiftDown;
			bool alt = Gui.IsAltDown;
			if (!Gui.IsCtrlDown)
			{
				if (sh && !alt && Gui.IsKeyPressed(KeyX.W, false)) mApp.AlignSelection(tab, .Top);
				if (sh && !alt && Gui.IsKeyPressed(Key.S, false)) mApp.AlignSelection(tab, .Bottom);
				if (sh && !alt && Gui.IsKeyPressed(Key.A, false)) mApp.AlignSelection(tab, .Left);
				if (sh && !alt && Gui.IsKeyPressed(Key.D, false)) mApp.AlignSelection(tab, .Right);
				if (sh && alt && Gui.IsKeyPressed(KeyX.W, false)) mApp.AlignSelection(tab, .Middle);
				if (sh && alt && Gui.IsKeyPressed(Key.S, false)) mApp.AlignSelection(tab, .Center);
				if (sh && alt && Gui.IsKeyPressed(KeyX.H, false)) mApp.AlignSelection(tab, .DistributeH);
				if (sh && alt && Gui.IsKeyPressed(Key.V, false)) mApp.AlignSelection(tab, .DistributeV);
				if (!sh && !alt && Gui.IsKeyPressed(KeyX.Q, false)) mApp.AlignSelection(tab, .Straighten);
				// L: a new Local of this function, its name focused in Properties > Locals.
				if (!sh && !alt && Gui.IsKeyPressed(KeyX.L, false))
					mApp.AddLocalFromKey(tab, mg);
				if (!sh && !alt && Gui.IsKeyPressed(KeyX.M, false))
				{
					Prefs.ShowMinimap = !Prefs.ShowMinimap;
					Prefs.Save();
				}
			}
			if (!Gui.IsCtrlDown && Gui.IsKeyPressed(Key.F, false))
				FrameNodes(tab, mg.Graph, !tab.SelectedNodes.IsEmpty);
		}

		/// Zooms (up to 1:1) and pans so the selection, or the whole graph, fits the canvas.
		void FrameNodes(GraphTab tab, Graph graph, bool selectedOnly)
		{
			float minX = float.MaxValue;
			float minY = float.MaxValue;
			float maxX = float.MinValue;
			float maxY = float.MinValue;
			for (let n in graph.Nodes)
			{
				if (selectedOnly && !tab.IsSelected(n.Id))
					continue;
				if (!mLayById.TryGetValue(n.Id, let L))
					continue;
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
				maxX = Math.Max(maxX, n.X + L.W);
				maxY = Math.Max(maxY, n.Y + L.H);
			}
			if (minX > maxX)
				return;
			const float Margin = 60;
			float w = (maxX - minX) + Margin * 2;
			float h = (maxY - minY) + Margin * 2;
			float fit = Math.Min(tab.CanvasSize.x / w, tab.CanvasSize.y / h);
			tab.ZoomLevel = Math.Min(Canvas.LevelAtOrBelow(fit), Canvas.DefaultZoomLevel);
			tab.ZoomChangedTime = Gui.igGetTime();
			tab.CenterOn((minX + maxX) * 0.5f, (minY + maxY) * 0.5f);
			tab.ApplyPendingCenter();
		}

		/// Grid-space position of the mouse in the current editor.
		public ImVec2 MouseGridPos(GraphTab tab)
		{
			return tab.ScreenToGrid(Gui.igGetMousePos());
		}

		/// Must be called right after the canvas item. The drop is applied after drawing.
		void HandleDragDrop(GraphTab tab)
		{
			if (Gui.igBeginDragDropTarget())
			{
				let payload = Gui.igAcceptDragDropPayload("VB_MEMBER", 0);
				if (payload != null)
				{
					mPendingDrop = *(int32*)payload.Data;
					mPendingDropPos = MouseGridPos(tab);
				}
				Gui.igEndDragDropTarget();
			}
		}
	}
}
