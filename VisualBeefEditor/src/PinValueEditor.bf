using System;
using System.Collections;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// The typed control of an unwired input pin (docs/Editor-UI.md > Pin values): a checkbox, a
	/// dropdown of an enum's members, a text / number / character field that writes the Beef literal
	/// (`"text"`, `1.5f`, `'x'`, `.Member`) and refuses what the type cannot hold. Used on the node
	/// canvas and in the Properties panel; the rules are `PinValue` in the core.
	class PinValueEditor
	{
		TextBuffer mBuf = new .(1024) ~ delete _;
		/// The pin being typed into and what is typed (the pin's Default changes only when it is accepted).
		int32 mEditPin;
		int32 mCurrentId;
		String mEditText = new .() ~ delete _;
		/// The pin whose last value was refused: its frame stays red for a moment.
		int32 mRejectPin;
		int32 mRejectFrames;
		/// The last refusal, for the self test.
		public String LastRefusal = new .() ~ delete _;
		public int32 RefusalCount;
		/// Self test: open this enum pin's dropdown on the next draw / keep this pin showing typed text.
		public int32 SelfTestOpenPin;
		public int32 SelfTestHold;
		public bool SelfTestClose;
		/// The dropdown button's colour (0: the Properties input colour); the canvas uses its inline field colour.
		public uint32 ButtonColor;

		/// Self test: the pin looks as if `text` were being typed into it (the frame turns red when the type cannot hold it).
		public void SelfTestType(int32 id, StringView text)
		{
			mEditPin = id;
			mEditText.Set(text);
			SelfTestHold = id;
		}

		public void SelfTestRelease()
		{
			SelfTestHold = 0;
			SelfTestOpenPin = 0;
			mEditPin = 0;
			mRejectFrames = 0;
		}

		/// True for the kinds this editor draws.
		public static bool Handles(PinValueKind k) => k == .Bool || k == .Enum || k == .Text || k == .Number || k == .Char;

		public static StringView Hint(PinValueKind k)
		{
			switch (k)
			{
			case .Text: return "text";
			case .Number: return "0";
			case .Char: return "a";
			default: return "";
			}
		}

		/// Width in grid units a field of this kind needs for the pin's current value.
		public static float Width(PinValueKind kind, Pin p, TypeService types)
		{
			switch (kind)
			{
			case .Char:
				return 44;
			case .Enum:
				List<String> members = scope .();
				defer { ClearAndDeleteItems!(members); }
				PinValue.Members(p.TypeName, types, members);
				float w = Gui.CalcTextSize("(choose)").x;
				for (let m in members)
					w = Math.Max(w, Gui.CalcTextSize(m).x);
				return Math.Clamp(w + 38, 70, 240);
			default:
				String s = scope .();
				PinValue.Display(kind, p.TypeName, p.Default, s);
				return Math.Clamp(Gui.CalcTextSize(s).x + 18, (kind == .Number) ? 56 : 64, 260);
			}
		}

		/// Draws the control at the cursor. True when the pin's value was changed: the edit has begun
		/// (`app.BeginEdit()`) and `node.Edited` is set; the caller commits it.
		public bool Draw(EditorApp app, Node node, Pin p, PinValueKind kind, float width)
		{
			return Draw(app, node, p.Id, p.TypeName, p.Default, p.Optional, kind, width);
		}

		/// The same for any value text (a pin's Default, a switch case's label): `id` keeps the
		/// fields apart, `value` is changed in place.
		public bool Draw(EditorApp app, Node node, int32 id, StringView typeName, String value, bool optional, PinValueKind kind, float width)
		{
			Gui.PushID(id);
			defer Gui.PopID();
			mCurrentId = id;
			let start = Gui.igGetCursorScreenPos();
			bool changedValue = false;
			switch (kind)
			{
			case .Bool:
				bool v = value == "true";
				if (Gui.Checkbox("##b", &v))
				{
					app.BeginEdit();
					value.Set(v ? "true" : "false");
					node.Edited = true;
					changedValue = true;
				}
			case .Enum:
				changedValue = DrawEnum(app, node, typeName, value, width);
			default:
				changedValue = DrawTyped(app, node, id, typeName, value, optional, kind, width);
			}
			if (mRejectPin == id && mRejectFrames > 0)
			{
				mRejectFrames--;
				let dl = Gui.igGetWindowDrawList();
				Gui.ImDrawList_AddRect(dl, start - .(1, 1), start + .(width + 1, Gui.igGetFrameHeight() + 1), Theme.NodeError, 3, 1.5f, 0);
			}
			return changedValue;
		}

		bool DrawEnum(EditorApp app, Node node, StringView typeName, String value, float width)
		{
			String shown = scope .();
			PinValue.Display(.Enum, typeName, value, shown);
			List<String> members = scope .();
			defer { ClearAndDeleteItems!(members); }
			PinValue.Members(typeName, TypeService.Current, members);
			bool changed = false;
			// A button that opens a list (not ImGui's combo: the self test has to be able to open it).
			let start = Gui.igGetCursorScreenPos();
			let h = Gui.igGetFrameHeight();
			Gui.igPushStyleColor_U32(Col.Button, (ButtonColor != 0) ? ButtonColor : Look.Input);
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(30, 30, 30));
			Gui.igPushStyleVar_Vec2(StyleVarX.ButtonTextAlign, .(0, 0.5f));
			bool open = Gui.Button(scope $"{(shown.IsEmpty ? StringView("(choose)") : StringView(shown))}##eb", .(width, h));
			Gui.igPopStyleVar(1);
			Gui.igPopStyleColor(2);
			Gui.DrawText(Gui.igGetWindowDrawList(), .(start.x + width - Gui.igGetFontSize() * 1.4f, start.y + (h - Gui.igGetFontSize()) * 0.5f), Look.ForegroundDim, Icon.ChevronDown);
			if (SelfTestOpenPin != 0 && mCurrentId == SelfTestOpenPin)
			{
				SelfTestOpenPin = 0;
				open = true;
			}
			if (open)
				Gui.OpenPopup("##em");
			// The list stays inside the window: pulled left when the node sits at the right edge, and opened
			// upwards when it would run off the bottom.
			let display = Gui.igGetIO_Nil().DisplaySize;
			float listW = Math.Max(width, 90 * Look.Scale);
			float listH = members.Count * (Gui.igGetFontSize() + 8 * Look.Scale) + 16 * Look.Scale;
			float listX = Math.Max(0, Math.Min(start.x, display.x - listW - 4 * Look.Scale));
			bool above = start.y + h + listH > display.y && start.y - listH > 0;
			Gui.igSetNextWindowPos(.(listX, above ? start.y : start.y + h), Cond.Always, .(0, above ? 1 : 0));
			Gui.igSetNextWindowSize(.(listW, 0), Cond.Always);
			if (Look.BeginPopupSpaced("##em"))
			{
				if (SelfTestClose)
				{
					SelfTestClose = false;
					Gui.igCloseCurrentPopup();
				}
				for (let m in members)
				{
					if (Gui.Selectable(m, m == shown))
					{
						if (m != shown)
						{
							app.BeginEdit();
							value.Set(".");
							value.Append(m);
							node.Edited = true;
							changed = true;
						}
						Gui.igCloseCurrentPopup();
					}
				}
				Look.EndPopupSpaced();
			}
			return changed;
		}

		bool DrawTyped(EditorApp app, Node node, int32 id, StringView typeName, String value, bool optional, PinValueKind kind, float width)
		{
			bool mine = mEditPin == id;
			String shown = scope .();
			if (mine)
				shown.Set(mEditText);
			else
				PinValue.Display(kind, typeName, value, shown);
			mBuf.Set(shown);
			Gui.igSetNextItemWidth(width);
			bool typed = Gui.igInputTextWithHint("##t", scope String(Hint(kind)), mBuf.Ptr, (.)mBuf.Capacity, 0, null, null);
			if (typed)
			{
				mEditPin = id;
				mEditText.Set(mBuf.View);
				mine = true;
			}
			if (!mine)
				return false;
			bool committed = false;
			String lit = scope .();
			String why = scope .();
			bool ok = PinValue.Write(kind, typeName, mEditText, optional, lit, why);
			if (Gui.igIsItemDeactivated())
			{
				String cur = scope .();
				PinValue.Display(kind, typeName, value, cur);
				if (mEditText != cur)
				{
					if (ok)
					{
						if (lit != value)
						{
							app.BeginEdit();
							value.Set(lit);
							node.Edited = true;
							committed = true;
						}
					}
					else
						Refuse(id, why);
				}
				mEditPin = 0;
			}
			else if (!Gui.igIsItemActive() && SelfTestHold != id)
				mEditPin = 0;
			else if (!ok)
			{
				// Typing something the type cannot hold: the frame turns red while it stays so.
				mRejectPin = id;
				mRejectFrames = 2;
			}
			return committed;
		}

		void Refuse(int32 id, StringView why)
		{
			mRejectPin = id;
			mRejectFrames = 120;
			LastRefusal.Set(why);
			RefusalCount++;
			Notify.Warn(why);
		}
	}
}
