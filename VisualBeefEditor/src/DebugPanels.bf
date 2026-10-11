using System;
using System.Collections;
using ImGui;
using VisualBeef.Debug;

namespace VisualBeef.Editor
{
	/// Locals, Call Stack and Debug Output (docs/Debugging.md). Values are read once per stop and
	/// frame; a member is read when its row is opened.
	extension EditorApp
	{
		Dictionary<String, EvalValue> mLocalValues = new .() ~ { for (let kv in _) { delete kv.key; delete kv.value; } delete _; };
		List<String> mLocalNames = new .() ~ DeleteContainerAndItems!(_);
		int32 mLocalsStop = -1;
		int32 mLocalsFrame = -1;
		int32 mLocalsCols = 3;
		int mDebugOutSeen;

		void DrawDebugPanels()
		{
			DrawLocalsPanel();
			DrawCallStackPanel();
			DrawDebugOutputPanel();
			DrawAttachPopup();
		}

		EvalValue LocalValue(StringView expr)
		{
			if (mLocalValues.TryGetValueAlt(expr, let cached))
				return cached;
			let v = new EvalValue();
			mDebug.Evaluate(expr, DebugFrame, v, 200);
			mLocalValues[new String(expr)] = v;
			return v;
		}

		void RefreshLocals()
		{
			if (mLocalsStop == mDebug.StopCount && mLocalsFrame == DebugFrame)
				return;
			mLocalsStop = mDebug.StopCount;
			mLocalsFrame = DebugFrame;
			for (let kv in mLocalValues)
			{
				delete kv.key;
				delete kv.value;
			}
			mLocalValues.Clear();
			ClearAndDeleteItems!(mLocalNames);
			mDebug.GetLocals(DebugFrame, mLocalNames);
		}

		void DrawLocalsPanel()
		{
			if (!ShowLocals)
				return;
			if (Gui.Begin(Panels.Locals, &ShowLocals))
			{
				if (!IsDebugStopped)
				{
					Gui.igPushTextWrapPos(0);
					Gui.TextDisabled(IsDebugging ? (mDebug.Attached ? "Attached: values show when the game stops at a breakpoint." : "Running: values show when the program stops.") : "Not debugging. Start Debugging (F5) and stop at a breakpoint.");
					Gui.igPopTextWrapPos();
				}
				else
				{
					RefreshLocals();
					if (mDebug.Frames.Count > DebugFrame)
					{
						Gui.igPushTextWrapPos(0);
						Gui.TextDisabled(mDebug.Frames[DebugFrame].Name);
						Gui.igPopTextWrapPos();
					}
					// In a narrow panel the Type column goes (the tooltip of the value has it).
					mLocalsCols = (Gui.igGetContentRegionAvail().x < 380 * Look.Scale) ? 2 : 3;
					if (Gui.igBeginTable("##locals", mLocalsCols, TableFlags.RowBg | TableFlags.SizingStretchProp | TableFlags.Resizable, .(0, 0), 0))
					{
						Gui.igTableSetupColumn("Name", TableColumnFlags.WidthStretch, 1.6f, 0);
						Gui.igTableSetupColumn("Value", TableColumnFlags.WidthStretch, 2, 0);
						if (mLocalsCols == 3)
							Gui.igTableSetupColumn("Type", TableColumnFlags.WidthStretch, 1, 0);
						for (let name in mLocalNames)
							DrawLocalRow(name, name, 0);
						Gui.igEndTable();
					}
					if (mLocalNames.IsEmpty)
						Gui.TextDisabled("No locals in this frame.");
				}
			}
			Gui.End();
		}

		void DrawLocalRow(StringView label, StringView expr, int depth)
		{
			let v = LocalValue(expr);
			Gui.igTableNextRow(0, 0);
			Gui.igTableSetColumnIndex(0);
			int32 flags = TreeNodeFlags.SpanFullWidth;
			bool expandable = !v.Failed && !v.Members.IsEmpty && depth < 8;
			if (mSelfTestLocalsOpen && expandable && depth == 0 && label == "this")
				Gui.igSetNextItemOpen(true, Cond.Always);
			if (!expandable)
				flags |= TreeNodeFlags.Leaf | TreeNodeFlags.NoTreePushOnOpen;
			String nameFit = scope .();
			FitText(label, Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x - (expandable ? 24 : 14) * Look.Scale), nameFit);
			bool open = Gui.TreeNode(scope $"{nameFit}##{expr}", flags);
			if (Gui.igIsItemHovered(0) && nameFit != label)
				Gui.Tooltip(label);
			Gui.igTableSetColumnIndex(1);
			String shown = scope .();
			ShortValue(v.Value, shown);
			CellText(shown, 0, v.Failed);
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip((mLocalsCols == 2 && !v.Type.IsEmpty) ? scope $"{v.Value}\n{v.Type}" : v.Value);
			if (mLocalsCols == 3)
			{
				Gui.igTableSetColumnIndex(2);
				CellText(v.Type, 0, true);
				if (Gui.igIsItemHovered(0) && !v.Type.IsEmpty)
					Gui.Tooltip(v.Type);
			}
			if (expandable && open)
			{
				for (let m in v.Members)
					DrawLocalRow(m.name, m.expr, depth + 1);
				Gui.TreePop();
			}
		}

		void DrawCallStackPanel()
		{
			if (!ShowCallStack)
				return;
			if (Gui.Begin(Panels.CallStack, &ShowCallStack))
			{
				if (!IsDebugStopped)
					Gui.TextDisabled(IsDebugging ? (mDebug.Attached ? "Attached: the game is running." : "Running.") : "Not debugging.");
				else if (mDebug.Attached)
				{
					bool anyGame = false;
					for (let f in mDebug.Frames)
						if (!f.HasSource)
							anyGame = true;
					if (anyGame)
						Gui.Checkbox("Show game code frames", &mExpandGameFrames);
				}
				if (IsDebugStopped && Gui.igBeginTable("##callstack", 2, TableFlags.RowBg | TableFlags.SizingStretchProp | TableFlags.Resizable, .(0, 0), 0))
				{
					// The Location column is as wide as its longest text (at most 45% of the panel), the
					// function takes the rest.
					float widest = 0;
					for (let f in mDebug.Frames)
					{
						if (!f.HasSource)
							continue;
						String probe = scope .();
						System.IO.Path.GetFileName(f.File, probe);
						probe.AppendF(":{}", f.Line);
						widest = Math.Max(widest, Gui.CalcTextSize(probe).x);
					}
					float locW = Math.Min(widest + 16 * Look.Scale, Gui.igGetContentRegionAvail().x * 0.45f);
					Gui.igTableSetupColumn("Function", TableColumnFlags.WidthStretch, 1, 0);
					Gui.igTableSetupColumn("Location", TableColumnFlags.WidthFixed, Math.Max(locW, 40 * Look.Scale), 0);
					int32 show = -1;
					// Attached to a game: each run of frames without source (the game's own code, the
					// engine, system DLLs) is one dimmed "game code" row unless expanded.
					bool collapse = mDebug.Attached && !mExpandGameFrames;
					for (int fi = 0; fi < mDebug.Frames.Count; fi++)
					{
						let f = mDebug.Frames[fi];
						int32 i = (int32)fi;
						if (collapse && !f.HasSource)
						{
							int run = 1;
							while (fi + run < mDebug.Frames.Count && !mDebug.Frames[fi + run].HasSource)
								run++;
							Gui.PushID(i);
							Gui.igTableNextRow(0, 0);
							Gui.igTableSetColumnIndex(0);
							Gui.igPushStyleColor_U32(Col.Text, Look.ForegroundDim);
							String row = scope .();
							FitText(scope $"   {Icon.ChevronRight} game code ({run} frame{(run == 1) ? "" : "s"})", Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x), row);
							row.Append("###gamecode");
							if (Gui.Selectable(row, false, (1 << 1) /* SpanAllColumns */))
								mExpandGameFrames = true;
							Gui.igPopStyleColor(1);
							if (Gui.igIsItemHovered(0))
							{
								String tip = scope .("Code of the game, not of your mod (no source). Click to show each frame:");
								for (int k < Math.Min(run, 8))
									tip.AppendF("\n{}", mDebug.Frames[fi + k].Name);
								if (run > 8)
									tip.AppendF("\n... {} more", run - 8);
								Gui.Tooltip(tip);
							}
							Gui.PopID();
							fi += run - 1;
							continue;
						}
						Gui.PushID(i);
						Gui.igTableNextRow(0, 0);
						Gui.igTableSetColumnIndex(0);
						bool mine = f.HasSource && DebugSession.IsUnder(f.File, mDebug.SourceRoot);
						String label = scope .();
						// "Module.exe!Type.Function()": the module name is in the tooltip, not the row.
						StringView shownName = f.Name;
						int bang = shownName.IndexOf('!');
						if (bang >= 0 && bang + 1 < shownName.Length)
							shownName = shownName.Substring(bang + 1);
						label.AppendF("{} {}", (i == DebugFrame) ? Icon.ArrowRight : "  ", shownName);
						String fitLabel = scope .();
						FitText(label, Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x), fitLabel);
						fitLabel.Append("###frame");
						if (!mine)
							Gui.igPushStyleColor_U32(Col.Text, Look.ForegroundDim);
						if (Gui.Selectable(fitLabel, i == DebugFrame, SelectableFlags.AllowDoubleClick | (1 << 1) /* SpanAllColumns */) && Gui.igIsMouseDoubleClicked_Nil(0))
							show = i;
						if (!mine)
							Gui.igPopStyleColor(1);
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip(f.HasSource ? scope $"{f.Name}\n{f.File}:{f.Line}\nDouble-click to open it" : scope $"{f.Name}\n(no source)");
						Gui.igTableSetColumnIndex(1);
						if (f.HasSource)
						{
							String loc = scope .();
							System.IO.Path.GetFileName(f.File, loc);
							loc.AppendF(":{}", f.Line);
							CellText(loc, Look.AccentBlue);
						}
						Gui.PopID();
					}
					// The engine's walk ends where the game's own code starts when the game has no symbol
					// file here (its executable is not read): say so instead of ending silently.
					if (mDebug.Attached && !mDebug.SkippedImage.IsEmpty && !mDebug.Frames.IsEmpty && mDebug.Frames.Back.HasSource)
					{
						Gui.igTableNextRow(0, 0);
						Gui.igTableSetColumnIndex(0);
						String row = scope .();
						FitText(scope $"   {Icon.ChevronRight} game code (callers not shown: no symbols)", Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x), row);
						Gui.TextDisabled(row);
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip(scope $"The rest of the stack is the game's own code. {System.IO.Path.GetFileName(mDebug.SkippedImage, .. scope .())} has no symbol file on this PC, so the debugger does not read it.");
					}
					Gui.igEndTable();
					if (show >= 0)
						ShowDebugFrame(show);
				}
			}
			Gui.End();
		}

		void DrawDebugOutputPanel()
		{
			if (!ShowDebugOutput)
				return;
			if (mFocusDebugOutput)
			{
				mFocusDebugOutput = false;
				Gui.igSetNextWindowFocus();
			}
			if (Gui.Begin(Panels.DebugOutput, &ShowDebugOutput))
			{
				if (Gui.Button(scope $"{Icon.Trash2} Clear"))
					DebugOutput.Clear();
				Gui.SameLine();
				if (Gui.Button(scope $"{Icon.Copy} Copy"))
					Gui.igSetClipboardText(DebugOutput);
				Gui.SameLine();
				{
					bool att = mDebug != null && mDebug.Attached;
					StringView hint = att ? "Debugger messages for the attached game." : "What the program writes to its console (stdout and stderr).";
					String fit = scope .();
					FitText(hint, Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x), fit);
					Gui.TextDisabled(fit);
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(att ? "Attach, detach and the debugger's messages. What the game and its mods log is in the UMP runtime log." : hint);
				}
				Gui.igPushStyleColor_U32(Col.ChildBg, Look.Recessed);
				if (Gui.igBeginChild_Str("##debugout", .(0, 0), ChildFlags.Borders, 0))
				{
					if (mMono != null)
						Gui.igPushFont(mMono, 0);
					bool atBottom = Gui.igGetScrollY() >= Gui.igGetScrollMaxY() - 4;
					Gui.Text(DebugOutput);
					if (mDebugOutSeen != DebugOutput.Length)
					{
						mDebugOutSeen = DebugOutput.Length;
						if (atBottom)
							Gui.igSetScrollHereY(1.0f);
					}
					if (mMono != null)
						Gui.igPopFont();
				}
				Gui.igEndChild();
				Gui.igPopStyleColor(1);
			}
			Gui.End();
		}
	}
}
