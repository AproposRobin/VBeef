using System;
using System.Collections;
using ImGui;

namespace VisualBeef.Editor
{
	/// UE-style two-column property grid (name | value) with collapsible category bars, used by
	/// Details and Editor Preferences:
	///
	///     if (PropertyGrid.Begin("##node")) {
	///         if (PropertyGrid.Category("Default")) {
	///             PropertyGrid.Row("Name", "tooltip");  Gui.igInputText(...);   // value column
	///         }
	///         PropertyGrid.End();
	///     }
	///
	/// The value widget after `Row` spans the value column (SetNextItemWidth is set for it).
	static class PropertyGrid
	{
		static bool sCategoryOpen = true;
		static TextBuffer sText = new .(4096) ~ delete _;

		static String sId = new .() ~ delete _;
		static float sNameWeight;
		/// The table is ended while a full-width row draws (see WideRow); the next row resumes it.
		static bool sSuspended;

		static bool BeginTable()
		{
			int32 flags = TableFlags.Resizable | TableFlags.BordersInnerV | TableFlags.BordersInnerH | TableFlags.SizingStretchProp | TableFlags.NoPadOuterX;
			// Same id on every resume: ImGui keeps the column widths of all instances in sync.
			if (!Gui.igBeginTable(sId, 2, flags, .(0, 0), 0))
				return false;
			Gui.igTableSetupColumn("Name", TableColumnFlags.WidthStretch, sNameWeight, 0);
			Gui.igTableSetupColumn("Value", TableColumnFlags.WidthStretch, 1 - sNameWeight, 0);
			return true;
		}

		static void Resume()
		{
			if (!sSuspended)
				return;
			sSuspended = false;
			BeginTable();
		}

		public static bool Begin(StringView id, float nameWeight = 0.42f)
		{
			Gui.igPushStyleVar_Vec2(StyleVar.ItemSpacing, .(6 * Look.Scale, 2 * Look.Scale));
			Gui.igPushStyleColor_U32(ColX.TableBorderLight, Gui.Color(20, 20, 20));
			sId.Set(id);
			sNameWeight = nameWeight;
			sSuspended = false;
			if (!BeginTable())
			{
				Gui.igPopStyleColor(1);
				Gui.igPopStyleVar(1);
				return false;
			}
			sCategoryOpen = true;
			return true;
		}

		public static void End()
		{
			if (!sSuspended)
				Gui.igEndTable();
			sSuspended = false;
			Gui.igPopStyleColor(1);
			Gui.igPopStyleVar(1);
		}

		/// A collapsible category bar across both columns. Returns whether it is open; rows of a
		/// closed category must be skipped by the caller.
		/// Self-test captures: the category with this name is drawn open.
		public static String ForceOpen = new .() ~ delete _;

		public static bool Category(StringView name, bool defaultOpen = true, StringView icon = default)
		{
			Resume();
			Gui.igTableNextRow(0, Gui.igGetFrameHeight() + 2 * Look.Scale);
			Gui.igTableSetBgColor(TableBgTarget.RowBg0, Look.Header, -1);
			Gui.igTableSetColumnIndex(0);
			Gui.igPushStyleColor_U32(Col.Header, Gui.Color(0, 0, 0, 0));
			Gui.igPushStyleColor_U32(Col.HeaderHovered, Gui.Color(255, 255, 255, 10));
			Gui.igPushStyleColor_U32(Col.HeaderActive, Gui.Color(255, 255, 255, 18));
			Gui.igPushStyleColor_U32(Col.Text, Gui.Color(220, 220, 220));
			String label = scope .();
			if (!icon.IsEmpty)
				label.AppendF("{}  ", icon);
			label.Append(name);
			int32 flags = TreeNodeFlagsX.SpanAllColumns | TreeNodeFlagsX.LabelSpanAllColumns | TreeNodeFlags.NoTreePushOnOpen | TreeNodeFlagsX.FramePadding;
			if (defaultOpen)
				flags |= TreeNodeFlags.DefaultOpen;
			if (!ForceOpen.IsEmpty && ForceOpen == name)
				Gui.igSetNextItemOpen(true, Cond.Always);
			sCategoryOpen = Gui.TreeNode(label, flags);
			Gui.igPopStyleColor(4);
			return sCategoryOpen;
		}

		/// Starts a property row: draws the name in the left column and moves to the value column
		/// with the next item sized to fill it.
		public static void Row(StringView name, StringView tooltip = default, uint32 swatch = 0)
		{
			Resume();
			Gui.igTableNextRow(0, 0);
			Gui.igTableSetColumnIndex(0);
			Gui.igAlignTextToFramePadding();
			Gui.igIndent(14 * Look.Scale);
			if (swatch != 0)
			{
				// Type colour pill in front of the name (pins, variables).
				let p = Gui.igGetCursorScreenPos();
				float h = Gui.igGetFrameHeight();
				Gui.ImDrawList_AddRectFilled(Gui.igGetWindowDrawList(), .(p.x, p.y + h * 0.32f), .(p.x + 12 * Look.Scale, p.y + h * 0.68f), swatch, 4 * Look.Scale, 0);
				Gui.igSetCursorScreenPos(.(p.x + 18 * Look.Scale, p.y));
				Gui.igAlignTextToFramePadding();
			}
			Gui.Text(name);
			if (!tooltip.IsEmpty && Gui.igIsItemHovered(0))
				Gui.Tooltip(tooltip);
			Gui.igUnindent(14 * Look.Scale);
			Gui.igTableSetColumnIndex(1);
			Gui.igSetNextItemWidth(-1);
		}

		/// A full-width row for content such as a code block or buttons: the grid is paused (the
		/// content spans the whole panel, indented) and resumes at the next Row / Category.
		public static void WideRow()
		{
			Resume();
			Gui.igEndTable();
			sSuspended = true;
			Gui.igDummy(.(0, 1));
			Gui.igSetCursorPosX(Gui.igGetCursorPosX() + 6 * Look.Scale);
		}

		/// Plain row helper for custom two-column content: starts a row in column 0.
		public static void BeginRow()
		{
			Resume();
			Gui.igTableNextRow(0, 0);
			Gui.igTableSetColumnIndex(0);
		}

		// ---- Value widgets (call after Row). Each returns true when the value was committed.

		/// Text field bound to `value`; `changed` reports live edits, the result the commit.
		public static bool Text(StringView id, String value, out bool changed, bool mono = false, ImFont* monoFont = null, StringView hint = default)
		{
			sText.Set(value);
			if (mono && monoFont != null)
				Gui.igPushFont(monoFont, 0);
			if (hint.IsEmpty)
				changed = Gui.igInputText(scope String(id), sText.Ptr, (.)sText.Capacity, 0, null, null);
			else
				changed = Gui.igInputTextWithHint(scope String(id), scope String(hint), sText.Ptr, (.)sText.Capacity, 0, null, null);
			if (mono && monoFont != null)
				Gui.igPopFont();
			if (changed)
				value.Set(sText.View);
			return Gui.igIsItemDeactivatedAfterEdit();
		}

		public static bool Multiline(StringView id, String value, float height, out bool changed, ImFont* monoFont = null)
		{
			sText.Set(value);
			if (monoFont != null)
				Gui.igPushFont(monoFont, 0);
			changed = Gui.igInputTextMultiline(scope String(id), sText.Ptr, (.)sText.Capacity, .(Gui.igGetContentRegionAvail().x - 6 * Look.Scale, height), InputTextFlags.AllowTabInput, null, null);
			if (monoFont != null)
				Gui.igPopFont();
			if (changed)
				value.Set(sText.View);
			return Gui.igIsItemDeactivatedAfterEdit();
		}

		public static bool Bool(StringView id, ref bool value)
		{
			return Gui.igCheckbox(scope String(id), &value);
		}

		/// Numeric drag with a unit suffix ("%.0f px"); commits on release.
		public static bool Float(StringView id, ref float value, float speed, float min, float max, StringView format = "%.2f")
		{
			Gui.igDragFloat(scope String(id), &value, speed, min, max, scope String(format), SliderFlags.AlwaysClamp);
			return Gui.igIsItemDeactivatedAfterEdit();
		}

		public static bool Int(StringView id, ref int32 value, float speed, int32 min, int32 max, StringView format = "%d")
		{
			Gui.igDragInt(scope String(id), &value, speed, min, max, scope String(format), SliderFlags.AlwaysClamp);
			return Gui.igIsItemDeactivatedAfterEdit();
		}

		/// Combo over `items`; returns true when the selection changed.
		public static bool Combo(StringView id, ref int32 index, Span<StringView> items)
		{
			bool changed = false;
			StringView preview = (index >= 0 && index < items.Length) ? items[index] : "";
			if (Gui.igBeginCombo(scope String(id), scope String(preview), 0))
			{
				for (int i < items.Length)
				{
					Gui.PushID((int32)i); // two entries may read the same
					if (Gui.Selectable(items[i], i == index))
					{
						index = (int32)i;
						changed = true;
					}
					Gui.PopID();
				}
				Gui.igEndCombo();
			}
			return changed;
		}

		/// Read-only explanatory text (dimmed) that wraps inside its column instead of being cut.
		public static void WrappedValue(StringView text)
		{
			Gui.igPushTextWrapPos(0);
			Gui.TextColored(Look.ForegroundDim, text);
			Gui.igPopTextWrapPos();
		}

		/// Read-only value text (dimmed).
		public static void Value(StringView text, uint32 color = 0)
		{
			Gui.igAlignTextToFramePadding();
			// A value wider than its column is cut by the column: the whole text is the tooltip.
			// A path is cut in the middle with "..." (its start and its last part stay readable).
			String shown = scope .();
			bool cut = Look.EllipsizeMiddle(text, Gui.igGetContentRegionAvail().x, shown);
			Gui.TextColored(color != 0 ? color : Look.ForegroundDim, shown);
			if (cut && Gui.igIsItemHovered(0))
				Gui.Tooltip(text);
		}
	}
}
