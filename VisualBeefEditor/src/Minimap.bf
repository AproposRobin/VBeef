using System;
using System.Collections;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// One cached block of the minimap, in pixels relative to the minimap's top-left corner.
	struct MmRect
	{
		public float X0;
		public float Y0;
		public float X1;
		public float Y1;
		public uint32 Col;
	}

	/// Graph minimap (toolbar / Window menu / M): a fixed-size overview (180 x 120 px at 100 %,
	/// scaled by the display scale, never by the zoom) in the bottom-right corner of the canvas.
	/// Nodes are small rounded blocks in their header colour, comment boxes a faint wash, wires
	/// are left out. The scale comes from the graph's own extent, so panning and zooming move the
	/// view rectangle but never rescale the map. Click or drag inside it to move the view (the
	/// rectangle follows the mouse, clamped to the graph); the numbered markers are the saved views.
	/// The block layout is cached and rebuilt only when a node, a box, the selection or the
	/// minimap's size changes.
	extension GraphPanel
	{
		bool mMinimapDrag;
		/// Where inside the view rectangle the drag grabbed it (grid units); zero = centre.
		ImVec2 mMmGrab;
		/// The mouse is over the minimap or the Home / Fit buttons with no canvas drag going on:
		/// the canvas ignores the click.
		bool mNavOver;

		List<MmRect> mMmNodes = new .() ~ delete _;
		List<MmRect> mMmBoxes = new .() ~ delete _;
		uint64 mMmSig;
		bool mMmValid;
		/// How many times the cache was rebuilt (self-test: it must not rebuild every frame).
		public int MmRebuilds;
		float mMmMinX;
		float mMmMinY;
		float mMmMaxX;
		float mMmMaxY;
		float mMmK;
		float mMmOx;
		float mMmOy;

		const float MmWidth = 180;
		const float MmHeight = 120;
		const float MmMargin = 12;

		void MinimapRect(GraphTab tab, out ImVec2 m0, out ImVec2 m1)
		{
			float s = Look.Scale;
			m1 = tab.CanvasOrigin + tab.CanvasSize - ImVec2(MmMargin * s, MmMargin * s);
			m0 = m1 - ImVec2(MmWidth * s, MmHeight * s);
		}

		static uint64 Mix(uint64 h, float f)
		{
			var ff = f;
			int32 bits = *(int32*)&ff;
			return (h ^ (uint64)(uint32)bits) * 1099511628211UL;
		}

		static uint64 MixI(uint64 h, uint64 v) => (h ^ v) * 1099511628211UL;

		ImVec2 MmToScreen(ImVec2 m0, float gx, float gy) => .(m0.x + mMmOx + (gx - mMmMinX) * mMmK, m0.y + mMmOy + (gy - mMmMinY) * mMmK);

		/// Rebuilds the cached blocks when something they show has changed.
		void RefreshMinimapCache(GraphTab tab, Graph graph, float mw, float mh)
		{
			uint64 sig = 14695981039346656037UL;
			sig = MixI(sig, (uint64)(uint32)graph.Serial);
			sig = Mix(sig, mw);
			sig = Mix(sig, mh);
			for (let L in mOrder)
			{
				sig = Mix(sig, L.Node.X);
				sig = Mix(sig, L.Node.Y);
				sig = Mix(sig, L.W);
				sig = Mix(sig, L.H);
				sig = MixI(sig, (uint64)(L.Selected ? 1 : 0) + ((uint64)L.Header << 1) + ((uint64)L.Shape << 40));
			}
			for (let c in mComments)
			{
				sig = Mix(sig, c.X);
				sig = Mix(sig, c.Y);
				sig = Mix(sig, c.W);
				sig = Mix(sig, c.H);
			}
			if (mMmValid && sig == mMmSig)
				return;
			mMmValid = true;
			mMmSig = sig;
			MmRebuilds++;
			mMmNodes.Clear();
			mMmBoxes.Clear();

			float s = Look.Scale;
			float minX = float.MaxValue, minY = float.MaxValue, maxX = float.MinValue, maxY = float.MinValue;
			for (let L in mOrder)
			{
				minX = Math.Min(minX, L.Node.X);
				minY = Math.Min(minY, L.Node.Y);
				maxX = Math.Max(maxX, L.Node.X + L.W);
				maxY = Math.Max(maxY, L.Node.Y + L.H);
			}
			for (let c in mComments)
			{
				minX = Math.Min(minX, c.X);
				minY = Math.Min(minY, c.Y);
				maxX = Math.Max(maxX, c.X + c.W);
				maxY = Math.Max(maxY, c.Y + c.H);
			}
			if (minX > maxX)
			{
				minX = 0; minY = 0; maxX = 1; maxY = 1;
			}
			mMmMinX = minX;
			mMmMinY = minY;
			mMmMaxX = maxX;
			mMmMaxY = maxY;
			float pad = 8 * s;
			float k = Math.Min((mw - pad * 2) / Math.Max(1, maxX - minX), (mh - pad * 2) / Math.Max(1, maxY - minY));
			// A small graph stays small instead of filling the box with giant blocks.
			k = Math.Min(k, 0.12f * s);
			mMmK = k;
			mMmOx = (mw - (maxX - minX) * k) * 0.5f;
			mMmOy = (mh - (maxY - minY) * k) * 0.5f;

			for (let c in mComments)
			{
				MmRect r;
				r.X0 = mMmOx + (c.X - minX) * k;
				r.Y0 = mMmOy + (c.Y - minY) * k;
				r.X1 = r.X0 + Math.Max(2, c.W * k);
				r.Y1 = r.Y0 + Math.Max(2, c.H * k);
				r.Col = 0;
				mMmBoxes.Add(r);
			}
			for (let L in mOrder)
			{
				MmRect r;
				r.X0 = mMmOx + (L.Node.X - minX) * k;
				r.Y0 = mMmOy + (L.Node.Y - minY) * k;
				r.X1 = r.X0 + Math.Max(3 * s, L.W * k);
				r.Y1 = r.Y0 + Math.Max(3 * s, L.H * k);
				r.Col = L.Selected ? Theme.NodeSelected : ((L.Shape == .Normal) ? L.Header : Gui.Color(150, 150, 150));
				mMmNodes.Add(r);
			}
		}

		/// Moves the view so its middle follows `mouse` over the minimap (plus the grab offset), clamped to the graph.
		public void MinimapDragTo(GraphTab tab, ImVec2 mouse)
		{
			MinimapRect(tab, let m0, let m1);
			float gx = mMmMinX + (mouse.x - m0.x - mMmOx) / mMmK + mMmGrab.x;
			float gy = mMmMinY + (mouse.y - m0.y - mMmOy) / mMmK + mMmGrab.y;
			gx = Math.Clamp(gx, mMmMinX, mMmMaxX);
			gy = Math.Clamp(gy, mMmMinY, mMmMaxY);
			tab.CenterOn(gx, gy);
			tab.ApplyPendingCenter();
		}

		/// The middle of the minimap on screen (self-test captures hold the pointer there).
		public ImVec2 MinimapCenter(GraphTab tab)
		{
			MinimapRect(tab, let m0, let m1);
			return (m0 + m1) * 0.5f;
		}

		/// The graph's extent the minimap shows (self-test).
		public void MinimapBounds(out float minX, out float minY, out float maxX, out float maxY)
		{
			minX = mMmMinX;
			minY = mMmMinY;
			maxX = mMmMaxX;
			maxY = mMmMaxY;
		}

		/// Where `mouse` would have to be to put the middle of the view on grid point (gx, gy) (self-test).
		public ImVec2 MinimapPointOf(GraphTab tab, float gx, float gy)
		{
			MinimapRect(tab, let m0, let m1);
			return MmToScreen(m0, gx, gy);
		}

		void DrawMinimapWindow(GraphTab tab, Graph graph, ImVec2 mouse, bool mouseInCanvas)
		{
			float s = Look.Scale;
			if (graph.Nodes.IsEmpty || tab.CanvasSize.x < MmWidth * s * 1.8f || tab.CanvasSize.y < MmHeight * s * 1.8f)
			{
				mMinimapDrag = false;
				return;
			}
			MinimapRect(tab, let m0, let m1);
			Gui.igSetCursorScreenPos(m0);
			Gui.igPushStyleColor_U32(Col.ChildBg, Gui.Color(0, 0, 0, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(0, 0));
			if (Gui.igBeginChild_Str("##vbminimap", m1 - m0, 0, WindowFlags.NoScrollbar | WindowFlags.NoScrollWithMouse))
				DrawMinimap(tab, graph, Gui.igGetWindowDrawList(), mouse, mouseInCanvas || mMinimapDrag);
			Gui.igEndChild();
			Gui.igPopStyleVar(1);
			Gui.igPopStyleColor(1);
		}

		void DrawMinimap(GraphTab tab, Graph graph, ImDrawList* dl, ImVec2 mouse, bool canInteract)
		{
			float s = Look.Scale;
			MinimapRect(tab, let m0, let m1);
			float mw = m1.x - m0.x;
			float mh = m1.y - m0.y;
			RefreshMinimapCache(tab, graph, mw, mh);

			bool popup = Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup);
			bool hovered = canInteract && !popup && Canvas.RectContains(m0, m1, mouse);
			if (hovered && tab.Mode == .None)
				mNavOver = true;
			uint8 bgA = (uint8)((hovered || mMinimapDrag) ? 255 : 150);
			uint8 nodeA = (uint8)((hovered || mMinimapDrag) ? 255 : 185);
			float round = 5 * s;
			Gui.ImDrawList_AddRectFilled(dl, m0, m1, Gui.Color(14, 14, 18, bgA), round, 0);
			for (let r in mMmBoxes)
				Gui.ImDrawList_AddRectFilled(dl, m0 + ImVec2(r.X0, r.Y0), m0 + ImVec2(r.X1, r.Y1), Gui.Color(255, 255, 255, 22), 2 * s, 0);
			for (let r in mMmNodes)
				Gui.ImDrawList_AddRectFilled(dl, m0 + ImVec2(r.X0, r.Y0), m0 + ImVec2(r.X1, r.Y1), Theme.WithAlpha(r.Col, nodeA), 1.5f * s, 0);

			// The view: a clear rectangle, kept inside the box.
			let v0 = tab.ScreenToGrid(tab.CanvasOrigin);
			let v1 = tab.ScreenToGrid(tab.CanvasOrigin + tab.CanvasSize);
			var a = MmToScreen(m0, v0.x, v0.y);
			var b = MmToScreen(m0, v1.x, v1.y);
			let inner0 = m0 + ImVec2(1, 1);
			let inner1 = m1 - ImVec2(1, 1);
			a.x = Math.Clamp(a.x, inner0.x, inner1.x - 3);
			a.y = Math.Clamp(a.y, inner0.y, inner1.y - 3);
			b.x = Math.Clamp(b.x, a.x + 3, inner1.x);
			b.y = Math.Clamp(b.y, a.y + 3, inner1.y);
			Gui.ImDrawList_AddRectFilled(dl, a, b, Gui.Color(255, 255, 255, 26), 1.5f * s, 0);
			Gui.ImDrawList_AddRect(dl, a, b, Gui.Color(255, 255, 255, 240), 1.5f * s, 1.5f * s, 0);

			// Saved views: small numbered markers at the middle of each saved view.
			int hoverMarker = 0;
			float mr = 7 * s;
			for (let v in tab.Doc.Views)
			{
				if (v.MethodKey != tab.MethodKey)
					continue;
				var p = MmToScreen(m0, v.X, v.Y);
				p.x = Math.Clamp(p.x, m0.x + mr + 1, m1.x - mr - 1);
				p.y = Math.Clamp(p.y, m0.y + mr + 1, m1.y - mr - 1);
				bool hot = hovered && (mouse.x - p.x) * (mouse.x - p.x) + (mouse.y - p.y) * (mouse.y - p.y) <= mr * mr;
				if (hot)
					hoverMarker = v.N;
				Gui.ImDrawList_AddCircleFilled(dl, p, mr, hot ? Look.PrimaryHover : Look.Primary, 0);
				Gui.ImDrawList_AddCircle(dl, p, mr, Gui.Color(255, 255, 255, 200), 0, 1);
				String num = scope .();
				num.AppendF("{}", v.N);
				float ts = 10 * s;
				let tw = Gui.CalcTextSize(num).x * (ts / Gui.igGetFontSize());
				Gui.DrawText(dl, .(p.x - tw * 0.5f, p.y - ts * 0.5f), Gui.Color(255, 255, 255), num, ts);
			}

			// The little close mark in the top-right corner (hides the minimap; M or the Window menu brings it back).
			float cs = 14 * s;
			let c0 = ImVec2(m1.x - cs - 2 * s, m0.y + 2 * s);
			bool hotClose = hovered && Canvas.RectContains(c0, c0 + ImVec2(cs, cs), mouse);
			if (hovered)
			{
				if (hotClose)
					Gui.ImDrawList_AddRectFilled(dl, c0, c0 + ImVec2(cs, cs), Gui.Color(255, 255, 255, 40), 3 * s, 0);
				float q = 4 * s;
				let cc = c0 + ImVec2(cs * 0.5f, cs * 0.5f);
				uint32 xc = Gui.Color(220, 224, 232, (uint8)(hotClose ? 255 : 170));
				Gui.ImDrawList_AddLine(dl, cc - ImVec2(q, q), cc + ImVec2(q, q), xc, 1.5f);
				Gui.ImDrawList_AddLine(dl, cc - ImVec2(q, -q), cc + ImVec2(q, -q), xc, 1.5f);
				if (hotClose)
					Gui.Tooltip("Hide the minimap (M, or Window > Graph Minimap)");
				else if (hoverMarker != 0)
					Gui.Tooltip(scope $"View {hoverMarker}: click to go there");
			}
			Gui.ImDrawList_AddRect(dl, m0, m1, (hovered || mMinimapDrag) ? Gui.Color(200, 205, 215, 235) : Gui.Color(110, 114, 124, 150), round, 1, 0);

			// Press: close mark, a marker, or take hold of the view rectangle (outside it: centre it on the point).
			if (hovered && tab.Mode == .None && Gui.igIsMouseClicked_Bool(0, false))
			{
				if (hotClose)
				{
					Prefs.ShowMinimap = false;
					Prefs.Save();
					mMinimapDrag = false;
					return;
				}
				if (hoverMarker != 0)
					JumpToView(tab, hoverMarker);
				else
				{
					mMinimapDrag = true;
					tab.CancelViewAnim();
					bool inside = mouse.x >= a.x && mouse.x <= b.x && mouse.y >= a.y && mouse.y <= b.y;
					mMmGrab = .(0, 0);
					if (inside)
					{
						let c = tab.ViewCenter;
						mMmGrab = .(c.x - (mMmMinX + (mouse.x - m0.x - mMmOx) / mMmK), c.y - (mMmMinY + (mouse.y - m0.y - mMmOy) / mMmK));
					}
				}
			}
			if (mMinimapDrag)
			{
				if (!Gui.igIsMouseDown_Nil(0))
					mMinimapDrag = false;
				else
					MinimapDragTo(tab, mouse);
			}
			if (hovered && !mMinimapDrag)
				Gui.igSetMouseCursor(MouseCursor.Hand);
		}
	}
}
