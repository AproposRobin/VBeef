using System;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// Drag-and-drop calls the binding does not declare (the host exports them).
	static class DragNative
	{
		[CLink] public static extern ImGuiPayload* igGetDragDropPayload();
		[CLink] public static extern bool ImGuiPayload_IsDataType(ImGuiPayload* self, char8* type);
		// Self test (dragvars-live): mouse events into ImGui's input queue, as the platform layer adds them.
		[CLink] public static extern void* igGetIO_Nil();
		[CLink] public static extern void ImGuiIO_AddMousePosEvent(void* io, float x, float y);
		[CLink] public static extern void ImGuiIO_AddMouseButtonEvent(void* io, int32 button, bool down);
		/// ImGuiDragDropFlags_SourceNoPreviewTooltip: the editor draws its own ghost.
		public const int32 SourceNoPreviewTooltip = 1 << 0;

		/// The payload being dragged when it is of `type`, else null.
		public static ImGuiPayload* Active(char8* type)
		{
			let p = igGetDragDropPayload();
			if (p == null || !ImGuiPayload_IsDataType(p, type))
				return null;
			return p;
		}
	}

	/// What is being dragged and the ghost that follows the cursor (docs/Editor-UI.md#dragging-onto-pins).
	/// Every drag source (Outline rows, LOCAL VARIABLES rows, Node menu variable rows, Project Browser
	/// tiles) turns ImGui's own preview off and this one ghost is drawn instead: the pin-colour dot,
	/// the name, the type dimmed and, over a pin, what a drop there does (or why it is refused).
	extension EditorApp
	{
		/// The `VB_MEMBER` payload of a variable dragged out of the Node menu (the Outline's are
		/// indexes into mMembers).
		public const int32 cMenuDragIndex = -2;
		MemberRef mMenuDrag = new .() ~ delete _;
		/// The Node menu row dragged is a Set row: a plain drop on the Sheet places a Set.
		bool mMenuDragIsSet;
		/// The line under the ghost while it is over a pin (GraphPanel fills it each frame).
		String mGhostHint = new .() ~ delete _;
		bool mGhostHintRefused;
		int mGhostHintFrame = -1;

		/// Self test (`dragvars`): a drag shown without the mouse. The ghost is drawn at
		/// `mSelfTestDragAt` (screen), and `SelfTestDragPin` is the pin under it.
		MemberRef mSelfTestDrag ~ delete _;
		public int32 SelfTestDragPin;
		ImVec2 mSelfTestDragAt;
		/// Ghost frames drawn (the self test checks the ghost was drawn).
		public int GhostFrames;
		/// The last hint drawn under the ghost and whether it was a refusal (self test).
		public String GhostLastHint = new .() ~ delete _;
		public bool GhostLastRefused;

		/// The entry a `VB_MEMBER` payload names: an Outline row, or the Node menu's variable.
		public MemberRef DraggedRef(int32 index)
		{
			if (index == cMenuDragIndex)
				return mMenuDrag;
			if (index < 0 || index >= mMembers.Count)
				return null;
			return mMembers[index];
		}

		/// The variable or function being dragged right now, or null.
		public MemberRef ActiveDrag()
		{
			if (mSelfTestDrag != null)
				return mSelfTestDrag;
			let p = DragNative.Active("VB_MEMBER");
			if (p == null || p.Data == null || p.DataSize < sizeof(int32))
				return null;
			return DraggedRef(*(int32*)p.Data);
		}

		/// A Node menu variable row starts a drag: the menu closes and the variable follows the cursor.
		public void BeginMenuDrag(StringView name, StringView type, bool isSet)
		{
			mMenuDrag.MemberKind = .Variable;
			mMenuDrag.Name.Set(name);
			mMenuDrag.Type.Set(type);
			mMenuDrag.Params.Clear();
			mMenuDrag.Owner.Clear();
			mMenuDrag.IsStatic = false;
			mMenuDragIsSet = isSet;
		}

		/// Called by the Sheet each frame the ghost is over a pin.
		public void SetGhostHint(StringView text, bool refused)
		{
			mGhostHint.Set(text);
			mGhostHintRefused = refused;
			mGhostHintFrame = mFrame;
		}

		/// Self test: shows the ghost of `name : type` over pin `pinId` (0: over the Sheet at `at`).
		public void SelfTestShowDrag(StringView name, StringView type, int32 pinId, ImVec2 at, MemberRef.Kind kind = .Variable)
		{
			if (mSelfTestDrag == null)
				mSelfTestDrag = new .();
			mSelfTestDrag.MemberKind = kind;
			mSelfTestDrag.Name.Set(name);
			mSelfTestDrag.Type.Set(type);
			SelfTestDragPin = pinId;
			mSelfTestDragAt = at;
		}

		public void SelfTestEndDrag()
		{
			DeleteAndNullify!(mSelfTestDrag);
			SelfTestDragPin = 0;
			mSelfTestAssetGhost = false;
		}

		/// Self test: the ghost of a Project Browser tile (`item`) at `at`.
		bool mSelfTestAssetGhost;
		public void SelfTestShowAssetDrag(CBItem item, ImVec2 at)
		{
			delete mCBDragItem;
			mCBDragItem = item.Clone();
			mSelfTestAssetGhost = true;
			mSelfTestDragAt = at;
		}

		/// The Sheet puts the self test's ghost on the pin it shows (screen position).
		public void SelfTestDragOver(ImVec2 at) => mSelfTestDragAt = at;

		/// A variable dropped on a pin: a Get wired into an input, a Set fed by an output (in the flow
		/// after the pin's node). One undo step. A drop the types refuse changes nothing and says why
		/// in the status bar, like a refused wire. True when the node was placed.
		public bool DropVariableOnPin(GraphTab tab, MethodGraph mg, StringView name, StringView type, int32 pinId)
		{
			if (tab == null || mg == null || mg.Graph == null)
				return false;
			let graph = mg.Graph;
			let pin = graph.FindPin(pinId);
			if (pin == null)
				return false;
			String why = scope .();
			if (!VariableDrop.Fits(graph, pin, type, TypeService.Current, why))
			{
				SetStatus(why.IsEmpty ? "Those pins can't be connected." : scope $"Can't connect: {why}");
				return false;
			}
			if (!CheckWritable())
				return false;
			BeginEdit();
			let n = VariableDrop.Place(graph, pin, name, type, TypeService.Current, why);
			if (n == null)
			{
				SetStatus(why.IsEmpty ? "Those pins can't be connected." : scope $"Can't connect: {why}");
				return false;
			}
			mGraphPanel.PlaceBesidePin(tab, graph, n, pin);
			if (pin.IsInput)
				RefitCall(graph, pin.Owner);
			tab.SelectOnly(n.Id);
			CommitCurrent();
			return true;
		}

		/// Draws the ghost of what is being dragged at the cursor, on the foreground draw list.
		void DrawDragGhost()
		{
			StringView name = default;
			StringView type = default;
			uint32 dot = 0;
			bool isFunction = false;
			let m = ActiveDrag();
			if (m != null)
			{
				name = m.Name;
				type = m.Type;
				isFunction = m.MemberKind == .Function;
				dot = isFunction ? Theme.HeaderCall : Theme.TypeColor(m.Type);
			}
			else if ((DragNative.Active("VB_CBITEM") != null || mSelfTestAssetGhost) && mCBDragItem != null)
			{
				name = mCBDragItem.Name;
				type = AssetStyle.KindLabel(mCBDragItem.Kind);
				dot = AssetStyle.KindColor(mCBDragItem.Kind);
			}
			else
				return;
			GhostFrames++;
			let dl = Gui.igGetForegroundDrawList_ViewportPtr(Gui.igGetMainViewport());
			float s = Look.Scale;
			float fh = Gui.igGetFontSize();
			ImVec2 at = (mSelfTestDrag != null || mSelfTestAssetGhost) ? mSelfTestDragAt : Gui.igGetMousePos();
			ImVec2 p = at + ImVec2(16 * s, 12 * s);

			String title = scope .();
			if (isFunction)
				title.AppendF("{}()", name);
			else
				title.Append(name);
			StringView typeShown = (isFunction && type.IsEmpty) ? "void" : type;
			bool hint = mGhostHintFrame >= mFrame - 1 && !mGhostHint.IsEmpty && m != null;
			if (hint)
			{
				GhostLastHint.Set(mGhostHint);
				GhostLastRefused = mGhostHintRefused;
			}
			else
				GhostLastHint.Clear();
			// A tile: where it can go, as a dim note (it is not a drop that is being taken).
			bool note = m == null && mCBDragItem != null;
			if (note)
			{
				hint = true;
				GhostLastRefused = false;
			}
			StringView hintText = (m != null) ? StringView(mGhostHint) : "Drop on a folder (tile or tree) to move it";

			float padX = 8 * s;
			float padY = 5 * s;
			float dotR = 4.5f * s;
			float gap = 8 * s;
			float nameW = Gui.CalcTextSize(title).x;
			float typeW = typeShown.IsEmpty ? 0 : Gui.CalcTextSize(typeShown).x;
			float line1W = dotR * 2 + gap + nameW + (typeShown.IsEmpty ? 0 : gap + typeW);
			// The hint is cut to a sensible width: a long refusal reason ends in "...".
			String hintFit = scope .();
			if (hint)
				Look.EllipsizeEnd(hintText, 420 * s, hintFit);
			float hintW = hint ? Gui.CalcTextSize(hintFit).x : 0;
			float w = Math.Max(line1W, hintW) + padX * 2;
			float lineH = fh + 3 * s;
			float h = padY * 2 + lineH + (hint ? lineH : 0);
			// Kept inside the window.
			let vp = Gui.igGetMainViewport();
			let vpMax = vp.Pos + vp.Size;
			if (p.x + w > vpMax.x - 4 * s)
				p.x = Math.Max(vp.Pos.x + 4 * s, at.x - w - 8 * s);
			if (p.y + h > vpMax.y - 4 * s)
				p.y = Math.Max(vp.Pos.y + 4 * s, at.y - h - 8 * s);

			uint32 border = (!hint || note) ? Look.DropdownOutline : (GhostLastRefused ? Theme.WireBad : Theme.Good);
			Gui.ImDrawList_AddRectFilled(dl, p + ImVec2(2 * s, 3 * s), p + ImVec2(w + 2 * s, h + 3 * s), Gui.Color(0, 0, 0, 90), 5 * s, 0);
			Gui.ImDrawList_AddRectFilled(dl, p, p + ImVec2(w, h), Theme.WithAlpha(Look.Header, 238), 5 * s, 0);
			Gui.ImDrawList_AddRect(dl, p, p + ImVec2(w, h), border, 5 * s, Math.Max(1.0f, s), 0);
			float y = p.y + padY;
			float cx = p.x + padX + dotR;
			Gui.ImDrawList_AddCircleFilled(dl, .(cx, y + fh * 0.5f + 1), dotR, dot, 0);
			float x = cx + dotR + gap;
			Gui.DrawText(dl, .(x, y), Look.Foreground, title);
			if (!typeShown.IsEmpty)
				Gui.DrawText(dl, .(x + nameW + gap, y), Look.ForegroundDim, typeShown);
			if (hint)
				Gui.DrawText(dl, .(p.x + padX, y + lineH), note ? Look.ForegroundDim : (GhostLastRefused ? Theme.WireBad : Theme.Good), hintFit);
		}
	}
}
