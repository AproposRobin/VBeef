using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// The start page: what the editor shows when it was started without a project (nothing is reopened on its own).
	/// Recent projects on the left (a click opens one; a folder that is gone is dimmed with a Remove button), the ways
	/// to start on the right: New project, Open project, Documentation. It covers the work area while no project is
	/// open; opening or creating a project closes it.
	extension EditorApp
	{
		bool mStartPageWasVisible;
		/// The page itself has the focus (a click on it): the documentation window then asks for the front again.
		bool mStartPageFocused;
		/// Last frame's numbers, for the self tests: rows drawn, rows dimmed as missing.
		int mStartRows;
		int mStartMissingRows;

		/// Called every frame after the panels: the start page while no project is open, then the unsaved-changes
		/// question of a project switch and the documentation window.
		void DrawStartPageAndDocs()
		{
			bool visible = StartPageVisible;
			if (visible)
			{
				DrawStartPage(!mStartPageWasVisible);
				if (!mStartPageWasVisible && mShowDocs)
					mDocBringFront = true; // the page just came up over it
			}
			mStartPageWasVisible = visible;
			DrawSwitchModal();
			DrawDocsWindow();
		}

		static void StartText(StringView text, float size, uint32 color, ImFont* font)
		{
			Gui.igPushFont(font, size / Math.Max(Look.Scale, 0.5f)); // PushFont takes the size before the display scale
			Gui.TextColored(color, text);
			Gui.igPopFont();
		}

		void DrawStartPage(bool justShown)
		{
			LoadRecentProjects();
			let vp = Gui.igGetMainViewport();
			Gui.igSetNextWindowPos(vp.WorkPos, Cond.Always, .(0, 0));
			Gui.igSetNextWindowSize(vp.WorkSize, Cond.Always);
			// The page sits over every panel. Panels that something raises (the first-start focus of the Project Browser, a
			// menu) must not cover it, so it asks for the front each frame, except while the documentation, the preferences or a
			// popup is up: those stay over it.
			bool other = mShowDocs || mShowPrefs || Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup);
			if (justShown || !other)
				Gui.igSetNextWindowFocus();
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(0, 0));
			int32 flags = WindowFlags.NoTitleBar | WindowFlags.NoResize | WindowFlags.NoMove | WindowFlags.NoCollapse | WindowFlags.NoDocking |
				WindowFlags.NoSavedSettings | WindowFlags.NoScrollbar | WindowFlags.NoScrollWithMouse;
			bool open = Gui.Begin("##startpage", null, flags);
			Gui.igPopStyleVar(1);
			mStartPageFocused = Gui.igIsWindowFocused(0);
			if (open)
				DrawStartPageContent();
			Gui.End();
		}

		void DrawStartPageContent()
		{
			float scale = Look.Scale;
			float fs = Gui.igGetFontSize();
			let font = (UiFont != null) ? UiFont : Gui.igGetFont();
			let size = Gui.igGetWindowSize();
			float contentW = Math.Min(size.x - 96 * scale, 1180 * scale);
			float x0 = (size.x - contentW) * 0.5f;
			float gap = 32 * scale;
			float leftW = Math.Floor(contentW * 0.58f);
			float rightW = contentW - leftW - gap;
			float y = Math.Max(28 * scale, Math.Min(size.y * 0.07f, 64 * scale));

			// Title.
			Gui.igSetCursorPos(.(x0, y));
			Gui.igPushFont(font, fs * 2.2f / Math.Max(Look.Scale, 0.5f));
			Gui.TextColored(Look.AccentBlue, Icon.Workflow);
			Gui.SameLine(0, 12 * scale);
			Gui.TextColored(Look.ForegroundHover, VisualBeefInfo.Name);
			Gui.igPopFont();
			Gui.igSetCursorPos(.(x0, Gui.igGetCursorPos().y + 2 * scale));
			Gui.TextDisabled("Build Beef programs as graphs. Every graph is plain Beef code.");
			y = Gui.igGetCursorPos().y + 26 * scale;

			float bottom = 40 * scale;
			float listH = Math.Max(size.y - y - bottom - fs * 2.2f, 140 * scale);

			// Left: Recent projects.
			Gui.igSetCursorPos(.(x0, y));
			StartText("Recent projects", fs * 1.2f, Look.ForegroundHover, font);
			let headEnd = Gui.igGetCursorPos().y;
			Gui.igSetCursorPos(.(x0, headEnd + 6 * scale));
			Gui.igPushStyleColor_U32(Col.ChildBg, Look.Recessed);
			if (Gui.igBeginChild_Str("##startrecent", .(leftW, listH), ChildFlags.Borders, 0))
				DrawRecentList(fs, font);
			Gui.igEndChild();
			Gui.igPopStyleColor(1);

			// Right: the ways to start.
			Gui.igSetCursorPos(.(x0 + leftW + gap, y));
			StartText("Start", fs * 1.2f, Look.ForegroundHover, font);
			float cardY = headEnd + 6 * scale;
			float cardH = fs * 3.7f;
			float cardGap = 8 * scale;
			if (StartCard(0, Icon.FolderPlus, "New project...", "Make a Beef project in a folder named after it.", x0 + leftW + gap, cardY, rightW, cardH, fs, font))
				StartNewProject();
			cardY += cardH + cardGap;
			if (StartCard(1, Icon.FolderOpen, "Open project...", "Choose the folder of a project you already have.", x0 + leftW + gap, cardY, rightW, cardH, fs, font))
			{
				FileSafety.ReadOnlyProject = false;
				OpenFolderPicker();
			}
			cardY += cardH + cardGap;
			if (StartCard(2, Icon.BookOpen, "Documentation", "Getting started, the editor, nodes and the debugger.", x0 + leftW + gap, cardY, rightW, cardH, fs, font))
				OpenDocumentation();
			cardY += cardH + cardGap * 2;
			Gui.igSetCursorPos(.(x0 + leftW + gap, cardY));
			Gui.igPushTextWrapPos(x0 + leftW + gap + rightW);
			Gui.TextDisabled("You can also drop a project folder or a .bf file on the window.");
			Gui.igPopTextWrapPos();

			// Footer.
			Gui.igSetCursorPos(.(x0, headEnd + 6 * scale + listH + 10 * scale));
			Gui.TextDisabled(scope $"{VisualBeefInfo.Name} {VisualBeefInfo.Version}-{VisualBeefInfo.Channel}");
		}

		/// One action of the right column: icon, title and a line under it. True when clicked.
		bool StartCard(int32 id, StringView icon, StringView title, StringView text, float x, float y, float w, float h, float fs, ImFont* font)
		{
			Gui.igSetCursorPos(.(x, y));
			Gui.PushID(id);
			let p = Gui.igGetCursorScreenPos();
			bool clicked = Gui.Selectable("##card", false, 0, .(w, h));
			bool hovered = Gui.igIsItemHovered(0);
			Gui.PopID();
			let dl = Gui.igGetWindowDrawList();
			float pad = 14 * Look.Scale;
			Gui.ImDrawList_AddRect(dl, p, .(p.x + w, p.y + h), hovered ? Look.AccentBlue : Look.DropdownOutline, 3 * Look.Scale, 1, 0);
			Gui.DrawText(dl, .(p.x + pad, p.y + (h - fs * 1.7f) * 0.5f), Look.AccentBlue, icon, fs * 1.7f, font);
			float tx = p.x + pad + fs * 2.4f;
			Gui.DrawText(dl, .(tx, p.y + h * 0.16f), hovered ? Look.ForegroundHover : Look.Foreground, title, fs * 1.1f, font);
			String shown = scope .();
			Look.EllipsizeEnd(text, w - (tx - p.x) - pad, shown);
			Gui.DrawText(dl, .(tx, p.y + h * 0.52f), Look.ForegroundDim, shown, fs * 0.92f, font);
			if (hovered && shown.Length != text.Length)
				Gui.Tooltip(text);
			return clicked;
		}

		void DrawRecentList(float fs, ImFont* font)
		{
			float scale = Look.Scale;
			mStartRows = 0;
			mStartMissingRows = 0;
			if (mRecent.Items.IsEmpty)
			{
				Gui.igSetCursorPos(.(16 * scale, 16 * scale));
				Gui.igPushTextWrapPos(Gui.igGetWindowWidth() - 16 * scale);
				Gui.TextDisabled("No projects yet. Make a new one or open a folder; it is listed here the next time.");
				Gui.igPopTextWrapPos();
				return;
			}
			float rowH = fs * 3.2f;
			float pad = 14 * scale;
			String removePath = null;
			String openPath = null;
			for (let r in mRecent.Items)
			{
				Gui.PushID((int32)@r.Index);
				bool exists = Directory.Exists(r.Path);
				mStartRows++;
				if (!exists)
					mStartMissingRows++;
				let p = Gui.igGetCursorScreenPos();
				float w = Gui.igGetContentRegionAvail().x;
				float removeW = rowH * 0.9f;
				bool clicked = Gui.Selectable("##row", false, 0, .(w - removeW, rowH));
				bool rowHover = Gui.igIsItemHovered(0);
				Gui.SameLine(0, 0);
				bool removeClicked = Gui.igInvisibleButton("##remove", .(removeW, rowH), ButtonFlags.MouseButtonLeft);
				bool removeHover = Gui.igIsItemHovered(0);
				let dl = Gui.igGetWindowDrawList();
				uint32 nameColor = !exists ? Look.ForegroundDim : (rowHover ? Look.ForegroundHover : Look.Foreground);
				uint32 pathColor = !exists ? Theme.Mix(Look.ForegroundDim, Gui.Color(0, 0, 0), 0.25f) : Look.ForegroundDim;
				// The "last opened" text (or Missing) sits at the right end of the first line.
				String openedText = scope .();
				if (exists)
					RecentProjects.OpenedText(r.Opened, UnixNow(), openedText);
				else
					openedText.Set("Missing");
				float whenW = Gui.CalcTextSize(openedText).x;
				float rightEdge = p.x + w - removeW;
				Gui.DrawText(dl, .(rightEdge - whenW - pad * 0.5f, p.y + rowH * 0.16f), exists ? Look.ForegroundDim : Look.Warning, openedText);
				String name = scope .();
				Look.EllipsizeEnd(r.Name, rightEdge - whenW - pad * 2.5f - p.x, name);
				Gui.DrawText(dl, .(p.x + pad, p.y + rowH * 0.14f), nameColor, name, fs * 1.08f, font);
				String path = scope .();
				Look.EllipsizeMiddle(r.Path, rightEdge - p.x - pad * 1.5f, path);
				Gui.DrawText(dl, .(p.x + pad, p.y + rowH * 0.56f), pathColor, path);
				// The Remove button shows on a hovered row, and always for a folder that is gone.
				if (!exists || rowHover || removeHover)
				{
					let cx = p.x + w - removeW * 0.5f;
					let cy = p.y + rowH * 0.5f;
					let ts = Gui.CalcTextSize(Icon.X);
					Gui.DrawText(dl, .(cx - ts.x * 0.5f, cy - ts.y * 0.5f), removeHover ? Look.Error : Look.ForegroundDim, Icon.X);
				}
				Gui.ImDrawList_AddLine(dl, .(p.x, p.y + rowH), .(p.x + w, p.y + rowH), Look.Header, 1);
				if (removeHover)
					Gui.Tooltip("Remove from the list (the folder is not deleted)");
				else if (rowHover)
					Gui.Tooltip(exists ? scope $"{r.Path}\nOpen this project" : scope $"{r.Path}\nThis folder is not there any more. Remove it from the list.");
				if (clicked && exists)
					openPath = scope:: String(r.Path);
				else if (clicked)
					SetStatus(scope $"{r.Path} is not there any more", .Warning, false);
				if (removeClicked)
					removePath = scope:: String(r.Path);
				Gui.PopID();
			}
			if (removePath != null)
				ForgetRecentProject(removePath);
			else if (openPath != null)
			{
				FileSafety.ReadOnlyProject = false;
				RequestOpenProject(openPath);
			}
		}
	}
}
