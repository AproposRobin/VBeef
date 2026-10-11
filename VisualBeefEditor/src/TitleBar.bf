using System;
using System.IO;
using ImGui;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// The right end of the menu row: the project name, like UE5's title row.
	extension EditorApp
	{
		void DrawTitleBarExtras()
		{
			if (mProjectRoot.IsEmpty)
				return;
			String name = scope .();
			Path.GetFileName(mProjectRoot, name);
			float fs = Gui.igGetFontSize();
			float w = Gui.CalcTextSize(name).x + fs * 1.8f;
			float avail = Gui.igGetContentRegionAvail().x;
			if (avail < w + 20)
				return;
			Gui.SameLine(Gui.igGetCursorPos().x + avail - w - 8 * Look.Scale);
			let pos = Gui.igGetCursorScreenPos();
			let dl = Gui.igGetWindowDrawList();
			float h = Gui.igGetFrameHeight();
			// A subtle pill like UE's project badge.
			Gui.ImDrawList_AddRectFilled(dl, .(pos.x - 6 * Look.Scale, pos.y + 3 * Look.Scale), .(pos.x + w + 2 * Look.Scale, pos.y + h - 3 * Look.Scale), Look.Recessed, 4 * Look.Scale, 0);
			// Read-only (viewer) mode swaps the project icon for a lock.
			bool locked = FileSafety.ReadOnlyProject;
			Gui.DrawText(dl, .(pos.x, pos.y + (h - fs) * 0.5f), locked ? Look.Warning : Look.AccentFolder, locked ? Icon.Lock : Icon.Package);
			Gui.DrawText(dl, .(pos.x + fs * 1.5f, pos.y + (h - fs) * 0.5f), Look.Foreground, name);
			Gui.igDummy(.(w, 1));
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip(locked ? scope $"{mProjectRoot}\n(read-only: nothing is written to the project)" : mProjectRoot);
		}
	}
}
