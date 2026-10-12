using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// UE's Output Log (every editor / build message, filters, search, clear, copy) and the
	/// Problems panel (errors and warnings of the last compile, mapped to graph nodes; click to
	/// jump to the node).
	extension EditorApp
	{
		TextBuffer mLogSearch = new .(256) ~ delete _;
		bool mLogShowVerbose = true;
		bool mLogShowInfo = true;
		bool mLogShowWarnings = true;
		bool mLogShowErrors = true;
		String mLogCategory = new .() ~ delete _;
		int32 mLogSeenVersion = -1;
		bool mLogAutoScroll = true;
		bool mResultsShowErrors = true;
		bool mResultsShowWarnings = true;

		static bool FilterToggle(StringView label, ref bool value, uint32 activeColor)
		{
			Gui.igPushStyleColor_U32(Col.Button, value ? Theme.Mix(Look.Dropdown, activeColor, 0.25f) : Look.Recessed);
			Gui.igPushStyleColor_U32(Col.Text, value ? Look.ForegroundHover : Look.ForegroundDim);
			bool clicked = Gui.Button(label);
			Gui.igPopStyleColor(2);
			if (clicked)
				value = !value;
			return clicked;
		}

		bool LogEntryVisible(LogEntry e, StringView search)
		{
			switch (e.Level)
			{
			case .Verbose: if (!mLogShowVerbose) return false;
			case .Info, .Success: if (!mLogShowInfo) return false;
			case .Warning: if (!mLogShowWarnings) return false;
			case .Error: if (!mLogShowErrors) return false;
			}
			if (!mLogCategory.IsEmpty && e.Category != mLogCategory)
				return false;
			if (!search.IsEmpty)
			{
				for (let word in search.Split(' '))
					if (!word.IsEmpty && e.Text.IndexOf(word, true) < 0 && e.Category.IndexOf(word, true) < 0)
						return false;
			}
			return true;
		}

		void DrawOutputLog()
		{
			if (!ShowOutputLog)
				return;
			if (mFocusOutputLog)
			{
				mFocusOutputLog = false;
				Gui.igSetNextWindowFocus();
			}
			if (Gui.Begin(Panels.OutputLog, &ShowOutputLog))
			{
				var search = mLogSearch.View;
				search.Trim();
				// Toolbar: search, severity filters, category, clear / copy.
				Gui.igSetNextItemWidth(Math.Min(320 * Look.Scale, Gui.igGetContentRegionAvail().x * 0.35f));
				Gui.igInputTextWithHint("##logsearch", scope $"{Icon.Search}  Search Log", mLogSearch.Ptr, (.)mLogSearch.Capacity, 0, null, null);
				Gui.SameLine();
				FilterToggle(scope $"{Icon.Info} Messages##lf1", ref mLogShowInfo, Look.Foreground);
				Gui.SameLine(0, 2);
				FilterToggle(scope $"{Icon.Warning} Warnings##lf2", ref mLogShowWarnings, Look.Warning);
				Gui.SameLine(0, 2);
				FilterToggle(scope $"{Icon.Error} Errors##lf3", ref mLogShowErrors, Look.Error);
				Gui.SameLine(0, 2);
				FilterToggle(scope $"{Icon.ScrollText} Verbose##lf4", ref mLogShowVerbose, Look.ForegroundDim);
				Gui.SameLine();
				Gui.igSetNextItemWidth(120 * Look.Scale);
				if (Gui.igBeginCombo("##logcat", mLogCategory.IsEmpty ? "All categories" : scope String(mLogCategory), 0))
				{
					if (Gui.Selectable("All categories", mLogCategory.IsEmpty))
						mLogCategory.Clear();
					List<String> cats = scope .();
					Notify.WithEntries(scope [&] (entries) =>
					{
						for (let e in entries)
						{
							bool known = false;
							for (let c in cats)
								if (c == e.Category)
									known = true;
							if (!known)
								cats.Add(scope:: String(e.Category));
						}
					});
					for (let c in cats)
						if (Gui.Selectable(c, mLogCategory == c))
							mLogCategory.Set(c);
					Gui.igEndCombo();
				}
				float right = Gui.CalcTextSize("Clear").x + Gui.CalcTextSize("Copy").x + 70 * Look.Scale;
				Gui.SameLine(Math.Max(Gui.igGetCursorPos().x + 4, Gui.igGetWindowWidth() - right));
				if (Gui.Button(scope $"{Icon.Copy} Copy"))
				{
					String all = scope .();
					Notify.WithEntries(scope [&] (entries) =>
					{
						for (let e in entries)
							if (LogEntryVisible(e, search))
								all.AppendF("[{}] {}: {}\n", e.Stamp, e.Category, e.Text);
					});
					Gui.igSetClipboardText(all);
					Notify.Info("Output Log copied to the clipboard");
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Copy the visible lines");
				Gui.SameLine(0, 4);
				if (Gui.Button(scope $"{Icon.Trash2} Clear"))
					Notify.Clear();

				Gui.igPushStyleColor_U32(Col.ChildBg, Look.Recessed);
				if (Gui.igBeginChild_Str("##logbody", .(0, 0), ChildFlags.Borders, WindowFlags.HorizontalScrollbar))
				{
					if (mMono != null)
						Gui.igPushFont(mMono, 0);
					bool atBottom = Gui.igGetScrollY() >= Gui.igGetScrollMaxY() - 4;
					String jumpPath = scope .();
					int32 jumpLine = 0;
					Notify.WithEntries(scope [&] (entries) =>
					{
						String line = scope .();
						for (let e in entries)
						{
							if (!LogEntryVisible(e, search))
								continue;
							line.Clear();
							line.AppendF("[{}] {}: {}", e.Stamp, e.Category, e.Text);
							if (e.Repeat > 1)
								line.AppendF("  (x{})", e.Repeat);
							Gui.PushID((int32)@e.Index);
							Gui.igPushStyleColor_U32(Col.Text, Notify.LevelColor(e.Level));
							if (e.Path != null)
							{
								if (Gui.Selectable(line, false, SelectableFlags.AllowDoubleClick) && Gui.igIsMouseDoubleClicked_Nil(0))
								{
									jumpPath.Set(e.Path);
									jumpLine = e.Line;
								}
								if (Gui.igIsItemHovered(0))
									Gui.Tooltip("Double-click to open the node at this line");
							}
							else
								Gui.Text(line);
							Gui.igPopStyleColor(1);
							Gui.PopID();
						}
					});
					if (mLogSeenVersion != Notify.Version)
					{
						mLogSeenVersion = Notify.Version;
						if (atBottom || mLogAutoScroll)
							Gui.igSetScrollHereY(1.0f);
						mLogAutoScroll = false;
					}
					if (mMono != null)
						Gui.igPopFont();
					if (!jumpPath.IsEmpty && File.Exists(jumpPath))
						JumpToLine(jumpPath, jumpLine);
				}
				Gui.igEndChild();
				Gui.igPopStyleColor(1);
			}
			Gui.End();
		}

		/// Any indexed project file has a member the editor cannot read (or a declaration error).
		bool HasUnreadable()
		{
			if (Index == null)
				return false;
			for (let f in Index.Files)
				if (!f.Unreadable.IsEmpty)
					return true;
			return false;
		}

		/// The node a compiler message was about has been deleted from its (open) graph since the
		/// compile. Graphs not built yet are not built for this.
		bool DiagnosticNodeGone(Diagnostic d)
		{
			if (!d.OnNode)
				return false;
			let doc = FindDoc(d.Path);
			let mg = doc?.FindMethod(d.MethodKey);
			if (mg == null)
				return false;
			if (!mg.IsBuilt)
				return d.NodeGone;
			return DiagnosticMap.Resolve(mg, d) == null;
		}

		void DrawCompilerResultsPanel()
		{
			if (!ShowCompilerResults)
				return;
			if (mFocusCompilerResults || mSelectResultsTab)
			{
				mFocusCompilerResults = false;
				mSelectResultsTab = false;
				Gui.igSetNextWindowFocus();
			}
			if (Gui.Begin(Panels.CompilerResults, &ShowCompilerResults))
			{
				let state = GetCompileState();
				int errors = 0;
				int warnings = 0;
				if (mBuild != null)
					for (let m in mBuild.Messages)
					{
						if (m.IsError)
							errors++;
						else
							warnings++;
					}
				// Summary line with the compile state icon.
				Gui.TextColored(CompileColor(state), CompileBadge(state));
				Gui.SameLine();
				if (mBuild == null)
				{
					String last = scope .();
					CompileText(state, last);
					if (mCompRec != null)
						Gui.TextDisabled(scope $"Last compile ({mCompRec.Config}): {(mCompRec.Ok ? "succeeded" : "failed")}. {last}. Press Compile (F7) to run it again.");
					else
						Gui.TextDisabled("Not compiled yet. Press Compile (F7).");
				}
				else if (mBuild.Running)
				{
					String took = scope .();
					FormatSeconds(mBuild.ElapsedMs, took);
					Gui.TextColored(Look.AccentBlue, scope $"Compiling ({mBuild.Config})...  {took}");
				}
				else
				{
					String took = scope .();
					FormatSeconds(mBuild.BuildMs, took);
					if (mBuild.UpToDate)
						Gui.Text(scope $"Up to date ({mBuild.Config}): nothing changed since the last compile");
					else
						Gui.Text(mBuild.Succeeded ? scope $"Compile complete ({mBuild.Config}, {took})" : scope $"Compile failed ({mBuild.Config}, {took})");
					Gui.SameLine();
					Gui.TextDisabled(scope $"   {errors} error{(errors == 1) ? "" : "s"}, {warnings} warning{(warnings == 1) ? "" : "s"}");
					if (state == .Unknown)
					{
						Gui.SameLine();
						Gui.TextColored(Look.AccentYellow, "   (files changed since this compile)");
					}
				}
				if (mBuild != null && !mBuild.Messages.IsEmpty)
				{
					float right = 230 * Look.Scale;
					Gui.SameLine(Math.Max(Gui.igGetCursorPos().x + 8, Gui.igGetWindowWidth() - right));
					FilterToggle(scope $"{Icon.Error} {errors}##rf1", ref mResultsShowErrors, Look.Error);
					Gui.SameLine(0, 2);
					FilterToggle(scope $"{Icon.Warning} {warnings}##rf2", ref mResultsShowWarnings, Look.Warning);
					Gui.SameLine(0, 2);
					if (Gui.Button(scope $"{Icon.Log} Log"))
					{
						ShowOutputLog = true;
						mFocusOutputLog = true;
					}
				}

				Gui.igPushStyleColor_U32(Col.ChildBg, Look.Recessed);
				if (Gui.igBeginChild_Str("##results", .(0, 0), ChildFlags.Borders, 0) && (mBuild != null || HasUnreadable()))
				{
					Diagnostic jump = null;
					String jumpPath = scope .();
					int32 jumpLine = 0;
					if (Gui.igBeginTable("##restable", 4, TableFlags.RowBg | TableFlags.SizingStretchProp | TableFlags.Resizable, .(0, 0), 0))
					{
						Gui.igTableSetupColumn("##sev", TableColumnFlags.WidthFixed, 26 * Look.Scale, 0);
						Gui.igTableSetupColumn("Message", TableColumnFlags.WidthStretch, 4, 0);
						Gui.igTableSetupColumn("Where", TableColumnFlags.WidthStretch, 1.4f, 0);
						Gui.igTableSetupColumn("Location", TableColumnFlags.WidthStretch, 1.2f, 0);
						// Code the editor cannot use as written (docs/Files-and-Safety.md > Unparsed
						// members are kept), from every indexed project file, compiled or not.
						if (mResultsShowErrors && Index != null)
						{
							int32 row = 0;
							for (let f in Index.Files)
							{
								for (let u in f.Unreadable)
								{
									Gui.PushID(100000 + row++);
									Gui.igTableNextRow(0, 0);
									Gui.igTableSetColumnIndex(0);
									Gui.TextColored(Look.Error, Icon.Error);
									Gui.igTableSetColumnIndex(1);
									String text = scope .();
									text.AppendF("{}{}", u.Broken ? "Not readable by the editor: " : "", u.Message);
									bool clicked = CellSelectable(text, SelectableFlags.AllowDoubleClick | (1 << 1) /* SpanAllColumns */, "msg");
									if (Gui.igIsItemHovered(0))
										Gui.Tooltip(scope $"{text}\n{f.Path}:{u.Line}\nThe text is kept in the file as it is. Click to open it.");
									Gui.igTableSetColumnIndex(2);
									CellText(scope $"{Icon.Error} {u.Name}", Look.Error);
									Gui.igTableSetColumnIndex(3);
									String loc = scope .();
									Path.GetFileName(f.Path, loc);
									loc.AppendF(":{}", u.Line);
									CellText(loc, Look.AccentBlue);
									if (clicked)
									{
										jumpPath.Set(f.Path);
										jumpLine = u.Line;
									}
									Gui.PopID();
								}
							}
						}
						if (mBuild != null)
						for (let m in mBuild.Messages)
						{
							if ((m.IsError && !mResultsShowErrors) || (!m.IsError && !mResultsShowWarnings))
								continue;
							Gui.PushID((int32)@m.Index);
							Gui.igTableNextRow(0, 0);
							Gui.igTableSetColumnIndex(0);
							Gui.TextColored(m.IsError ? Look.Error : Look.Warning, m.IsError ? Icon.Error : Icon.Warning);
							Gui.igTableSetColumnIndex(1);
							bool clicked = CellSelectable(m.Text, SelectableFlags.AllowDoubleClick | (1 << 1) /* SpanAllColumns */, "msg");
							bool nodeGone = m.OnNode && DiagnosticNodeGone(m);
							if (Gui.igIsItemHovered(0))
							{
								if (nodeGone)
									Gui.Tooltip(scope $"{m.Text}\n{m.Path}:{m.Line}:{m.Column}\nThe node this was about has been deleted since the compile; compile again to refresh");
								else if (m.OnNode)
									Gui.Tooltip(scope $"{m.Text}\n{m.Path}:{m.Line}:{m.Column}\nClick to open {m.Where} with the node selected");
								else if (m.HasLocation)
									Gui.Tooltip(scope $"{m.Text}\n{m.Path}:{m.Line}:{m.Column}\nOutside every function graph (a field, a declaration): shown at document level");
								else
									Gui.Tooltip(m.Text);
							}
							Gui.igTableSetColumnIndex(2);
							if (nodeGone)
								CellText(scope $"{Icon.Trash2} {m.Where}", 0, true); // the node is gone: dimmed, a bin instead of the Sheet icon (tooltip says why)
							else if (m.OnNode)
								CellText(scope $"{Icon.Workflow} {m.Where}");
							else if (m.HasLocation)
								CellText(m.Where.IsEmpty ? "(document)" : scope $"(document) {m.Where}", 0, true);
							Gui.igTableSetColumnIndex(3);
							String loc = scope .();
							Path.GetFileName(m.Path, loc);
							if (m.Line > 0)
								loc.AppendF(":{}", m.Line);
							if (m.Column > 0)
								loc.AppendF(":{}", m.Column);
							CellText(loc, Look.AccentBlue);
							if (clicked)
								jump = m;
							Gui.PopID();
						}
						Gui.igEndTable();
					}
					if (mBuild != null && mBuild.Messages.IsEmpty && !mBuild.Running && !mBuild.Succeeded)
					{
						// No parsed messages: show BeefBuild's raw output.
						for (let line in mBuild.Output)
							Gui.TextDisabled(line);
					}
					if (jump != null)
						JumpToDiagnostic(jump);
					else if (!jumpPath.IsEmpty && File.Exists(jumpPath))
						JumpToLine(jumpPath, jumpLine);
				}
				Gui.igEndChild();
				Gui.igPopStyleColor(1);
			}
			Gui.End();
		}
	}
}
