using System;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// Moving around a Sheet: saved views 1-9 (Ctrl+digit saves, digit jumps, kept per function in the
	/// layout file as `#view` lines), Home (the entry node at 1:1, or the whole graph when there is
	/// none), Fit all, the small Home / Fit buttons in the upper right of the canvas, and the
	/// one-second toast that confirms a view.
	extension GraphPanel
	{
		/// ImGui's key code of the digit 0; the digit n is KeyDigit0 + n.
		const int32 KeyDigit0 = 536;

		/// Self-test captures: where the pointer is taken to be (x < -1e30 = the real pointer).
		public ImVec2 SelfTestMouse = .(-3e38f, -3e38f);

		String mNavToast = new .() ~ delete _;
		double mNavToastUntil;
		/// How long a toast stays (seconds); a self-test capture raises it.
		public double NavToastHold = 1.0;

		/// Room the Home / Fit buttons take at the top of the canvas (the zoom label sits below them).
		float NavButtonsHeight => 34 * Look.Scale;

		void NavToast(StringView text)
		{
			mNavToast.Set(text);
			mNavToastUntil = Gui.igGetTime() + NavToastHold;
			GraphTab.sAnimUntil = Math.Max(GraphTab.sAnimUntil, mNavToastUntil + 0.1);
			Desktop.Wake();
		}

		/// The toast currently shown (empty when none): for the self-test.
		public StringView NavToastText => (Gui.igGetTime() < mNavToastUntil) ? mNavToast : "";

		void DrawNavToast(GraphTab tab, ImDrawList* dl)
		{
			double left = mNavToastUntil - Gui.igGetTime();
			if (left <= 0 || mNavToast.IsEmpty)
				return;
			float s = Look.Scale;
			float fa = (float)Math.Clamp(left / 0.25, 0, 1);
			float fs = Gui.igGetFontSize() * 1.15f;
			let tw = Gui.CalcTextSize(mNavToast).x * 1.15f;
			float padX = 14 * s;
			float padY = 8 * s;
			let p0 = ImVec2(tab.CanvasOrigin.x + (tab.CanvasSize.x - tw) * 0.5f - padX, tab.CanvasOrigin.y + tab.CanvasSize.y - fs - padY * 2 - 36 * s);
			let p1 = ImVec2(p0.x + tw + padX * 2, p0.y + fs + padY * 2);
			Gui.ImDrawList_AddRectFilled(dl, p0, p1, Gui.Color(18, 18, 22, (uint8)(225 * fa)), 8 * s, 0);
			Gui.ImDrawList_AddRect(dl, p0, p1, Gui.Color(120, 126, 140, (uint8)(200 * fa)), 8 * s, 1, 0);
			Gui.DrawText(dl, .(p0.x + padX, p0.y + padY), Gui.Color(240, 242, 248, (uint8)(255 * fa)), mNavToast, fs);
		}

		static int32 NearestZoomLevel(float zoom)
		{
			int32 best = 0;
			float bestD = float.MaxValue;
			for (int32 i < Canvas.ZoomLevels.Count)
			{
				float d = Math.Abs(Canvas.ZoomLevels[i] - zoom);
				if (d < bestD)
				{
					bestD = d;
					best = i;
				}
			}
			return best;
		}

		/// Ctrl+digit: remembers the current pan and zoom as view `n` of this function.
		public void SaveView(GraphTab tab, int n)
		{
			if (n < 1 || n > 9 || tab.CanvasSize.x <= 0)
				return;
			let c = tab.ViewCenter;
			tab.Doc.SetView(tab.MethodKey, n, c.x, c.y, tab.Zoom);
			mApp.LayoutChanged();
			NavToast(scope $"View {n} saved");
		}

		/// digit: eases to view `n` (about 150 ms), or says it is not set.
		public bool JumpToView(GraphTab tab, int n)
		{
			let v = (n >= 1 && n <= 9) ? tab.Doc.FindView(tab.MethodKey, n) : null;
			if (v == null)
			{
				NavToast(scope $"View {n} is not set (Ctrl+{n} saves it)");
				return false;
			}
			tab.AnimateTo(v.X, v.Y, NearestZoomLevel(v.Zoom));
			NavToast(scope $"View {n}");
			return true;
		}

		/// Clears one saved view (n = 0: all of this function's views).
		public int ClearSavedViews(GraphTab tab, int n)
		{
			int removed = tab.Doc.ClearViews(tab.MethodKey, n);
			if (removed > 0)
				mApp.LayoutChanged();
			return removed;
		}

		/// Home: the entry node at zoom 1 (eased), or the whole graph when the Sheet has no entry node.
		public void GoHome(GraphTab tab, Graph graph)
		{
			if (graph.Entry == null)
			{
				FrameNodes(tab, graph, false);
				return;
			}
			let level = Canvas.DefaultZoomLevel;
			float z = Canvas.ZoomLevels[level];
			// The same placement as the first view of a Sheet: the entry node near the left, a quarter down.
			tab.AnimateTo(CanvasHalf(tab).x / z + graph.Entry.X - 60, CanvasHalf(tab).y / z + graph.Entry.Y - tab.CanvasSize.y * 0.25f, level);
		}

		static ImVec2 CanvasHalf(GraphTab tab) => .(tab.CanvasSize.x * 0.5f, tab.CanvasSize.y * 0.5f);

		/// Fit all: zoom and pan so the whole graph is in view.
		public void FitAll(GraphTab tab, Graph graph)
		{
			FrameNodes(tab, graph, false);
		}

		bool NavButton(ImDrawList* dl, StringView id, StringView icon, StringView tip, float size)
		{
			float s = Look.Scale;
			let pos = Gui.igGetCursorScreenPos();
			Gui.PushID(id);
			bool clicked = Gui.igInvisibleButton("##nb", .(size, size), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			bool held = Gui.igIsItemActive();
			Gui.PopID();
			uint32 bg = held ? Look.PrimaryPress : (hovered ? Look.Dropdown : Gui.Color(24, 25, 30, 190));
			Gui.ImDrawList_AddRectFilled(dl, pos, pos + ImVec2(size, size), bg, 5 * s, 0);
			Gui.ImDrawList_AddRect(dl, pos, pos + ImVec2(size, size), Gui.Color(110, 114, 124, hovered ? (uint8)230 : (uint8)130), 5 * s, 1, 0);
			float isz = size * 0.62f;
			Gui.DrawText(dl, .(pos.x + (size - isz) * 0.5f, pos.y + (size - isz) * 0.5f), hovered ? Look.ForegroundHover : Look.Foreground, icon, isz);
			if (hovered)
			{
				mNavOver = true;
				Gui.Tooltip(tip);
			}
			return clicked;
		}

		/// The Home and Fit all buttons in the upper right of the canvas.
		void DrawNavButtons(GraphTab tab, MethodGraph mg, Graph graph)
		{
			mNavOver = false;
			float s = Look.Scale;
			float bs = 26 * s;
			float gap = 4 * s;
			if (tab.CanvasSize.x < 260 * s || tab.CanvasSize.y < 120 * s)
				return;
			let p = ImVec2(tab.CanvasOrigin.x + tab.CanvasSize.x - 8 * s - (bs * 2 + gap), tab.CanvasOrigin.y + 8 * s);
			Gui.igSetCursorScreenPos(p);
			Gui.igPushStyleColor_U32(Col.ChildBg, Gui.Color(0, 0, 0, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(0, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.ItemSpacing, .(gap, 0));
			if (Gui.igBeginChild_Str("##vbnavbtns", .(bs * 2 + gap, bs), 0, WindowFlags.NoScrollbar | WindowFlags.NoScrollWithMouse))
			{
				let dl = Gui.igGetWindowDrawList();
				bool popup = Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup);
				if (NavButton(dl, "home", Icon.House, "Go to the entry node (Home)", bs) && !popup)
					GoHome(tab, graph);
				Gui.SameLine();
				if (NavButton(dl, "fit", Icon.Maximize, "Fit the whole graph", bs) && !popup)
					FitAll(tab, graph);
			}
			Gui.igEndChild();
			Gui.igPopStyleVar(2);
			Gui.igPopStyleColor(1);
		}

		/// Window > Saved Views: this Sheet's views (go to one, clear one) and Clear All.
		public void DrawViewsMenu(GraphTab tab)
		{
			if (!Gui.BeginMenu("Saved Views", tab != null))
				return;
			int count = 0;
			for (int n = 1; n <= 9; n++)
			{
				let v = tab.Doc.FindView(tab.MethodKey, n);
				String label = scope .();
				if (v != null)
				{
					count++;
					label.AppendF("View {}  (x {}, y {}, zoom {})", n, (int)v.X, (int)v.Y, v.Zoom);
				}
				else
					label.AppendF("View {}  (not set)", n);
				if (Gui.BeginMenu(label, true))
				{
					if (Gui.MenuItem("Go to", scope $"{n}", false, v != null))
						JumpToView(tab, n);
					if (Gui.MenuItem("Save here", scope $"Ctrl+{n}"))
						SaveView(tab, n);
					if (Gui.MenuItem("Clear", "", false, v != null))
						ClearSavedViews(tab, n);
					Gui.EndMenu();
				}
			}
			Gui.Separator();
			if (Gui.MenuItem("Clear All Views", "", false, count > 0))
				ClearSavedViews(tab, 0);
			Gui.EndMenu();
		}
	}
}
