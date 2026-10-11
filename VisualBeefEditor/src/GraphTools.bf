using System;
using System.Collections;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// UE's node alignment commands (Graph > Alignment, toolbar "Align", Shift+W/S/A/D ...).
	enum AlignMode
	{
		Top,
		Middle,
		Bottom,
		Left,
		Center,
		Right,
		DistributeH,
		DistributeV,
		Straighten
	}

	/// Layered auto-arrange: the exec flow runs left to right, each extra exec output (False,
	/// Loop Body, Completed ...) stacks its chain below the previous one, and the pure nodes that
	/// feed a node sit in columns to its left, under the exec line. Positions are snapped.
	static class LayeredArrange
	{
		public const float GapX = 64;
		public const float GapY = 48;
		public const float PureGapX = 40;
		public const float PureGapY = 16;

		public delegate bool SizeFn(Node n, out float w, out float h);

		class Ctx
		{
			public Graph G;
			public SizeFn Size;
			public HashSet<Node> Placed = new .() ~ delete _;
		}

		static void NodeSize(Ctx c, Node n, out float w, out float h)
		{
			w = 0;
			h = 0;
			if (c.Size == null || !c.Size(n, out w, out h))
				Estimate(n, out w, out h);
		}

		/// Size guess for a node that has not been drawn yet (just spawned from a menu).
		public static void Estimate(Node n, out float w, out float h)
		{
			int rows = Math.Max(n.Inputs.Count, n.Outputs.Count);
			w = 240;
			h = 48 + 24 * Math.Max(1, rows);
		}

		/// Lays out the freshly spawned `anchor` and the exec chain hanging off it (the companions a
		/// menu entry creates, like the Branch and Break of "For Each Loop with Break") with the same
		/// spacing Arrange uses. `anchor` itself stays where it is; only the nodes in `fresh` move.
		public static void ArrangeFrom(Graph g, Node anchor, List<Node> fresh, SizeFn size)
		{
			Ctx c = scope .();
			c.G = g;
			c.Size = size;
			// Everything that is not new counts as already placed.
			for (let n in g.Nodes)
				if (!fresh.Contains(n))
					c.Placed.Add(n);
			PlaceExec(c, anchor, anchor.X, anchor.Y);
		}

		/// Moves the whole `fresh` group down until none of its nodes sits on top of an existing
		/// node (anything in the graph that is not in `fresh`). Sizes of existing nodes come from
		/// the last drawn frame.
		public static void AvoidOverlap(Graph g, List<Node> fresh, SizeFn size)
		{
			Ctx c = scope .();
			c.G = g;
			c.Size = size;
			for (int pass < 40)
			{
				float push = 0;
				for (let f in fresh)
				{
					NodeSize(c, f, let fw, let fh);
					for (let o in g.Nodes)
					{
						if (fresh.Contains(o) || !o.HasPos)
							continue;
						NodeSize(c, o, let ow, let oh);
						if (f.X < o.X + ow && o.X < f.X + fw && f.Y < o.Y + oh && o.Y < f.Y + fh)
							push = Math.Max(push, o.Y + oh + PureGapY - f.Y);
					}
				}
				if (push <= 0)
					return;
				push = Canvas.Snap(push);
				if (push <= 0)
					push = GapY;
				for (let f in fresh)
					f.Y += push;
			}
		}

		/// Pure nodes feeding `n`'s data inputs (recursively), not placed yet.
		static void PureSources(Ctx c, Node n, List<Node> outDirect)
		{
			for (let p in n.Inputs)
			{
				if (p.Kind != .Data)
					continue;
				let src = c.G.DataSource(p);
				if (src != null && src.IsPure && !c.Placed.Contains(src) && !outDirect.Contains(src))
					outDirect.Add(src);
			}
		}

		/// Width of the pure columns needed left of `n`.
		static float PureTreeWidth(Ctx c, Node n, HashSet<Node> seen)
		{
			List<Node> srcs = scope .();
			PureSources(c, n, srcs);
			float best = 0;
			for (let s in srcs)
			{
				if (!seen.Add(s))
					continue;
				NodeSize(c, s, let w, ?);
				best = Math.Max(best, w + PureGapX + PureTreeWidth(c, s, seen));
			}
			return best;
		}

		/// Places the pure nodes feeding `n` to its left, stacked from `top`; returns the bottom.
		static float PlacePure(Ctx c, Node n, float rightX, float top)
		{
			List<Node> srcs = scope .();
			PureSources(c, n, srcs);
			float y = top;
			for (let s in srcs)
			{
				if (c.Placed.Contains(s))
					continue;
				c.Placed.Add(s);
				NodeSize(c, s, let w, let h);
				s.X = Canvas.Snap(rightX - w);
				s.Y = Canvas.Snap(y);
				s.HasPos = true;
				// Its own inputs go further left, starting at its row.
				float subBottom = PlacePure(c, s, s.X - PureGapX, s.Y);
				y = Math.Max(s.Y + h, subBottom) + PureGapY;
			}
			return y - PureGapY;
		}

		/// Places `n` at (x, y) and everything after it; returns the bottom of the subtree.
		static float PlaceExec(Ctx c, Node n, float x, float y)
		{
			c.Placed.Add(n);
			NodeSize(c, n, let w, let h);
			HashSet<Node> seen = scope .();
			float pureW = PureTreeWidth(c, n, seen);
			n.X = Canvas.Snap(x + pureW);
			n.Y = Canvas.Snap(y);
			n.HasPos = true;
			float bottom = n.Y + h;
			// Pure inputs: left of the node, starting just under its header so wires stay short.
			if (pureW > 0)
				bottom = Math.Max(bottom, PlacePure(c, n, n.X - PureGapX, n.Y + 72)); // below the exec wire
			// Exec outputs: the first continues on this row, the others stack below.
			float childX = n.X + w + GapX;
			bool first = true;
			float rowY = n.Y;
			// "then" (the statement after) goes last so nested bodies sit right under their owner.
			List<Pin> outs = scope .();
			for (let p in n.Outputs)
				if (p.Kind == .Exec && p.Name != "then")
					outs.Add(p);
			let thenPin = n.Then;
			if (thenPin != null)
				outs.Add(thenPin);
			for (let p in outs)
			{
				let next = c.G.ExecTarget(p);
				if (next == null || c.Placed.Contains(next))
					continue;
				float childY = first ? rowY : (bottom + GapY);
				float childBottom = PlaceExec(c, next, childX, childY);
				bottom = Math.Max(bottom, childBottom);
				first = false;
			}
			return bottom;
		}

		public static void Arrange(Graph g, SizeFn size)
		{
			Ctx c = scope .();
			c.G = g;
			c.Size = size;
			float bottom = 0;
			float originX = (g.Entry != null) ? g.Entry.X : 0;
			float originY = (g.Entry != null) ? g.Entry.Y : 0;
			if (g.Entry != null)
				bottom = PlaceExec(c, g.Entry, originX, originY);
			// Disconnected exec chains (orphans): heads are exec nodes with no incoming exec wire.
			for (let n in g.Nodes)
			{
				if (c.Placed.Contains(n) || n.IsPure)
					continue;
				let execIn = n.ExecIn;
				if (execIn != null && g.IsLinked(execIn))
					continue;
				bottom = PlaceExec(c, n, originX, bottom + GapY * 2);
			}
			// Anything left (cycles, unused pure nodes): a row along the bottom.
			float x = originX;
			float rowTop = bottom + GapY * 2;
			for (let n in g.Nodes)
			{
				if (c.Placed.Contains(n))
					continue;
				c.Placed.Add(n);
				NodeSize(c, n, let w, ?);
				n.X = Canvas.Snap(x);
				n.Y = Canvas.Snap(rowTop);
				n.HasPos = true;
				x += w + PureGapX;
			}
		}
	}

	extension GraphPanel
	{
		/// Size of a node as drawn last frame (grid units). False if it wasn't laid out.
		public bool GetNodeSize(int32 nodeId, out float w, out float h)
		{
			if (mLayById.TryGetValue(nodeId, let L))
			{
				w = L.W;
				h = L.H;
				return true;
			}
			w = 0;
			h = 0;
			return false;
		}

		/// Pin centre relative to its node (grid units), as drawn last frame.
		public bool GetPinOffset(int32 pinId, out ImVec2 off)
		{
			if (TryGetPin(pinId, let pl))
			{
				off = pl.Off;
				return true;
			}
			off = default;
			return false;
		}
	}

	extension EditorApp
	{
		void ArrangeCurrentGraph()
		{
			let mg = CurrentMethod;
			if (mg == null)
				return;
			BeginEdit();
			LayeredArrange.Arrange(mg.Graph, scope (n, w, h) => mGraphPanel.GetNodeSize(n.Id, out w, out h));
			LayoutChanged();
			if (CurrentTab != null)
				CurrentTab.NeedsFocus = true;
			SetStatus("Graph arranged by execution flow");
		}

		public void AlignSelection(GraphTab tab, AlignMode mode)
		{
			let mg = CurrentMethod;
			if (tab == null || mg == null)
				return;
			let g = mg.Graph;
			List<Node> nodes = scope .();
			for (let id in tab.SelectedNodes)
			{
				let n = g.FindNode(id);
				if (n != null)
					nodes.Add(n);
			}
			if (nodes.Count < ((mode == .Straighten) ? 1 : 2))
				return;
			BeginEdit();
			float minX = float.MaxValue, minY = float.MaxValue, maxR = float.MinValue, maxB = float.MinValue;
			float sumCX = 0, sumCY = 0;
			for (let n in nodes)
			{
				mGraphPanel.GetNodeSize(n.Id, let w, let h);
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
				maxR = Math.Max(maxR, n.X + w);
				maxB = Math.Max(maxB, n.Y + h);
				sumCX += n.X + w * 0.5f;
				sumCY += n.Y + h * 0.5f;
			}
			float avgCX = sumCX / nodes.Count;
			float avgCY = sumCY / nodes.Count;
			switch (mode)
			{
			case .Top:
				for (let n in nodes) n.Y = minY;
			case .Bottom:
				for (let n in nodes) { mGraphPanel.GetNodeSize(n.Id, ?, let h); n.Y = maxB - h; }
			case .Middle:
				for (let n in nodes) { mGraphPanel.GetNodeSize(n.Id, ?, let h); n.Y = avgCY - h * 0.5f; }
			case .Left:
				for (let n in nodes) n.X = minX;
			case .Right:
				for (let n in nodes) { mGraphPanel.GetNodeSize(n.Id, let w, ?); n.X = maxR - w; }
			case .Center:
				for (let n in nodes) { mGraphPanel.GetNodeSize(n.Id, let w, ?); n.X = avgCX - w * 0.5f; }
			case .DistributeH, .DistributeV:
				bool horiz = mode == .DistributeH;
				nodes.Sort(scope (a, b) => horiz ? a.X.CompareTo(b.X) : a.Y.CompareTo(b.Y));
				float total = 0;
				for (let n in nodes)
				{
					mGraphPanel.GetNodeSize(n.Id, let w, let h);
					total += horiz ? w : h;
				}
				float span = horiz ? (maxR - minX) : (maxB - minY);
				float gap = Math.Max(16, (span - total) / (nodes.Count - 1));
				float cursor = horiz ? minX : minY;
				for (let n in nodes)
				{
					mGraphPanel.GetNodeSize(n.Id, let w, let h);
					if (horiz) n.X = cursor; else n.Y = cursor;
					cursor += (horiz ? w : h) + gap;
				}
			case .Straighten:
				// UE's Q: line each node's first linked input pin up with the pin feeding it.
				for (let n in nodes)
				{
					Pin best = null;
					for (let p in n.Inputs)
					{
						if (!g.IsLinked(p))
							continue;
						if (best == null || (p.Kind == .Exec && best.Kind != .Exec))
							best = p;
					}
					if (best == null)
						continue;
					let link = g.FindLinkTo(best);
					if (link == null)
						continue;
					ImVec2 inOff = default;
					ImVec2 outOff = default;
					if (!mGraphPanel.GetPinOffset(best.Id, out inOff) || !mGraphPanel.GetPinOffset(link.From.Id, out outOff))
						continue;
					let src = link.From.Owner;
					n.Y = src.Y + outOff.y - inOff.y;
				}
			}
			for (let n in nodes)
			{
				if (Prefs.GridSnap && mode != .Straighten)
				{
					n.X = Canvas.Snap(n.X);
					n.Y = Canvas.Snap(n.Y);
				}
				n.HasPos = true;
			}
			LayoutChanged();
		}

		void DrawAlignItems(GraphTab tab)
		{
			bool many = tab != null && tab.SelectedNodes.Count > 1;
			bool any = tab != null && tab.SelectedNodes.Count > 0;
			if (IconItem(Icon.AlignStartHorizontal, "Align Top", "Shift+W", false, many)) AlignSelection(tab, .Top);
			if (IconItem(Icon.AlignCenterHorizontal, "Align Middle", "Alt+Shift+W", false, many)) AlignSelection(tab, .Middle);
			if (IconItem(Icon.AlignEndHorizontal, "Align Bottom", "Shift+S", false, many)) AlignSelection(tab, .Bottom);
			Gui.Separator();
			if (IconItem(Icon.AlignStartVertical, "Align Left", "Shift+A", false, many)) AlignSelection(tab, .Left);
			if (IconItem(Icon.AlignCenterVertical, "Align Center", "Alt+Shift+S", false, many)) AlignSelection(tab, .Center);
			if (IconItem(Icon.AlignEndVertical, "Align Right", "Shift+D", false, many)) AlignSelection(tab, .Right);
			Gui.Separator();
			if (IconItem(Icon.StretchHorizontal, "Straighten Connection(s)", "Q", false, any)) AlignSelection(tab, .Straighten);
			Gui.Separator();
			if (IconItem(Icon.AlignHorizontalDistributeCenter, "Distribute Horizontally", "Alt+Shift+H", false, many)) AlignSelection(tab, .DistributeH);
			if (IconItem(Icon.AlignVerticalDistributeCenter, "Distribute Vertically", "Alt+Shift+V", false, many)) AlignSelection(tab, .DistributeV);
		}

		void DrawAlignMenu(GraphTab tab)
		{
			if (Gui.BeginPopup("##alignmenu"))
			{
				DrawAlignItems(tab);
				Gui.EndPopup();
			}
		}
	}
}
