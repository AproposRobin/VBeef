using System;

// Hand-written bindings for the subset of Dear ImGui (via cimgui) that VisualBeef uses.
// The native code lives in vbhost (see Native/src/vbhost.cpp and the build scripts).
namespace ImGui
{
	[CRepr]
	struct ImVec2
	{
		public float x;
		public float y;

		public this(float x, float y)
		{
			this.x = x;
			this.y = y;
		}

		public static ImVec2 operator+(ImVec2 a, ImVec2 b) => .(a.x + b.x, a.y + b.y);
		public static ImVec2 operator-(ImVec2 a, ImVec2 b) => .(a.x - b.x, a.y - b.y);
		public static ImVec2 operator*(ImVec2 a, float s) => .(a.x * s, a.y * s);
	}

	[CRepr]
	struct ImVec4
	{
		public float x;
		public float y;
		public float z;
		public float w;

		public this(float x, float y, float z, float w)
		{
			this.x = x;
			this.y = y;
			this.z = z;
			this.w = w;
		}
	}

	struct ImDrawList;
	struct ImFont;
	[CRepr]
	struct ImGuiViewport
	{
		public uint32 ID;
		public int32 Flags;
		public ImVec2 Pos;
		public ImVec2 Size;
		public ImVec2 FramebufferScale;
		public ImVec2 WorkPos;
		public ImVec2 WorkSize;
	}

	[CRepr]
	struct ImGuiKeyData
	{
		public bool Down;
		public float DownDuration;
		public float DownDurationPrev;
		public float AnalogValue;
	}

	static class ButtonFlags
	{
		public const int32 MouseButtonLeft = 1 << 0;
		public const int32 MouseButtonRight = 1 << 1;
		public const int32 MouseButtonMiddle = 1 << 2;
		public const int32 AllowOverlap = 1 << 12;
	}

	static class DrawFlags
	{
		public const int32 None = 0;
		public const int32 Closed = 1 << 9;
		public const int32 RoundCornersTopLeft = 1 << 4;
		public const int32 RoundCornersTopRight = 1 << 5;
		public const int32 RoundCornersBottomLeft = 1 << 6;
		public const int32 RoundCornersBottomRight = 1 << 7;
		public const int32 RoundCornersNone = 1 << 8;
		public const int32 RoundCornersTop = RoundCornersTopLeft | RoundCornersTopRight;
		public const int32 RoundCornersBottom = RoundCornersBottomLeft | RoundCornersBottomRight;
	}

	static class MouseCursor
	{
		public const int32 Arrow = 0;
		public const int32 ResizeAll = 2;
		public const int32 Hand = 7;
		public const int32 NotAllowed = 10;
	}

	static class Dir
	{
		public const int32 Left = 0;
		public const int32 Right = 1;
		public const int32 Up = 2;
		public const int32 Down = 3;
	}

	[CRepr]
	struct ImGuiPayload
	{
		public void* Data;
		public int32 DataSize;
	}

	static class Col
	{
		public const int32 Text = 0;
		public const int32 TextDisabled = 1;
		public const int32 WindowBg = 2;
		public const int32 ChildBg = 3;
		public const int32 PopupBg = 4;
		public const int32 Border = 5;
		public const int32 FrameBg = 7;
		public const int32 FrameBgHovered = 8;
		public const int32 FrameBgActive = 9;
		public const int32 Button = 22;
		public const int32 ButtonHovered = 23;
		public const int32 ButtonActive = 24;
		public const int32 Header = 25;
		public const int32 HeaderHovered = 26;
		public const int32 HeaderActive = 27;
	}

	static class WindowFlags
	{
		public const int32 None = 0;
		public const int32 NoTitleBar = 1 << 0;
		public const int32 NoResize = 1 << 1;
		public const int32 NoMove = 1 << 2;
		public const int32 NoScrollbar = 1 << 3;
		public const int32 NoScrollWithMouse = 1 << 4;
		public const int32 NoCollapse = 1 << 5;
		public const int32 AlwaysAutoResize = 1 << 6;
		public const int32 NoBackground = 1 << 7;
		public const int32 NoSavedSettings = 1 << 8;
		public const int32 MenuBar = 1 << 10;
		public const int32 HorizontalScrollbar = 1 << 11;
		public const int32 NoDocking = 1 << 19;
	}

	static class PopupFlags
	{
		public const int32 None = 0;
		public const int32 MouseButtonLeft = 1 << 2;
		public const int32 MouseButtonRight = 2 << 2;
		public const int32 NoOpenOverItems = 1 << 8;
		public const int32 AnyPopupId = 1 << 10;
		public const int32 AnyPopupLevel = 1 << 11;
		public const int32 AnyPopup = AnyPopupId | AnyPopupLevel;
	}

	static class ChildFlags
	{
		public const int32 None = 0;
		public const int32 Borders = 1 << 0;
		public const int32 ResizeX = 1 << 2;
		public const int32 ResizeY = 1 << 3;
	}

	static class InputTextFlags
	{
		public const int32 None = 0;
		public const int32 AllowTabInput = 1 << 5;
		public const int32 EnterReturnsTrue = 1 << 6;
		public const int32 CtrlEnterForNewLine = 1 << 8;
		public const int32 ReadOnly = 1 << 9;
		public const int32 AutoSelectAll = 1 << 12;
	}

	static class TreeNodeFlags
	{
		public const int32 None = 0;
		public const int32 Selected = 1 << 0;
		public const int32 Framed = 1 << 1;
		public const int32 NoTreePushOnOpen = 1 << 3;
		public const int32 DefaultOpen = 1 << 5;
		public const int32 OpenOnArrow = 1 << 7;
		public const int32 Leaf = 1 << 8;
		public const int32 SpanAvailWidth = 1 << 11;
		public const int32 SpanFullWidth = 1 << 12;
	}

	static class SelectableFlags
	{
		public const int32 None = 0;
		public const int32 NoAutoClosePopups = 1 << 0;
		public const int32 AllowDoubleClick = 1 << 2;
	}

	static class ColorEditFlags
	{
		public const int32 None = 0;
		public const int32 NoAlpha = 1 << 1;
		public const int32 NoInputs = 1 << 5;
		public const int32 NoTooltip = 1 << 6;
		public const int32 NoLabel = 1 << 7;
		public const int32 AlphaPreviewHalf = 1 << 14;
		public const int32 AlphaBar = 1 << 18;
	}

	static class Cond
	{
		public const int32 Always = 1 << 0;
		public const int32 Once = 1 << 1;
		public const int32 FirstUseEver = 1 << 2;
		public const int32 Appearing = 1 << 3;
	}

	static class HoveredFlags
	{
		public const int32 None = 0;
		public const int32 ChildWindows = 1 << 0;
		public const int32 RootWindow = 1 << 1;
		public const int32 AllowWhenBlockedByPopup = 1 << 5;
		public const int32 AllowWhenBlockedByActiveItem = 1 << 7;
		public const int32 RootAndChildWindows = RootWindow | ChildWindows;
	}

	static class FocusedFlags
	{
		public const int32 ChildWindows = 1 << 0;
		public const int32 RootWindow = 1 << 1;
		public const int32 RootAndChildWindows = RootWindow | ChildWindows;
	}

	static class StyleVar
	{
		public const int32 WindowPadding = 2;
		public const int32 FramePadding = 11;
		public const int32 FrameRounding = 12;
		public const int32 FrameBorderSize = 13;
		public const int32 ItemSpacing = 14;
		public const int32 ItemInnerSpacing = 15;
	}

	static class DockNodeFlags
	{
		public const int32 None = 0;
		public const int32 PassthruCentralNode = 1 << 3;
	}

	static class TabItemFlags
	{
		public const int32 None = 0;
		public const int32 UnsavedDocument = 1 << 0;
		public const int32 SetSelected = 1 << 1;
	}

	static class Key
	{
		public const int32 Tab = 512;
		public const int32 LeftArrow = 513;
		public const int32 RightArrow = 514;
		public const int32 UpArrow = 515;
		public const int32 DownArrow = 516;
		public const int32 PageUp = 517;
		public const int32 PageDown = 518;
		public const int32 Home = 519;
		public const int32 Delete = 522;
		public const int32 Backspace = 523;
		public const int32 Space = 524;
		public const int32 Enter = 525;
		public const int32 Escape = 526;
		public const int32 A = 546;
		public const int32 B = 547;
		public const int32 C = 548;
		public const int32 D = 549;
		public const int32 F = 551;
		public const int32 N = 559;
		public const int32 O = 560;
		public const int32 R = 563;
		public const int32 S = 564;
		public const int32 V = 567;
		public const int32 X = 569;
		public const int32 Y = 570;
		public const int32 Z = 571;
		public const int32 F5 = 576;
		public const int32 F12 = 583;
		public const int32 MouseWheelY = 662;
		public const int32 ModCtrl = 1 << 12;
		public const int32 ModShift = 1 << 13;
		public const int32 ModAlt = 1 << 14;
	}

	static class Gui
	{
		public static uint32 Color(uint8 r, uint8 g, uint8 b, uint8 a = 255) => ((uint32)a << 24) | ((uint32)b << 16) | ((uint32)g << 8) | (uint32)r;

		[CLink] public static extern bool igBegin(char8* name, bool* p_open, int32 flags);
		[CLink] public static extern void igEnd();
		[CLink] public static extern bool igBeginChild_Str(char8* str_id, ImVec2 size, int32 child_flags, int32 window_flags);
		[CLink] public static extern void igEndChild();
		[CLink] public static extern void igTextUnformatted(char8* text, char8* text_end);
		[CLink] public static extern bool igButton(char8* label, ImVec2 size);
		[CLink] public static extern bool igSmallButton(char8* label);
		[CLink] public static extern bool igInputText(char8* label, char8* buf, uint buf_size, int32 flags, void* callback, void* user_data);
		[CLink] public static extern bool igInputTextMultiline(char8* label, char8* buf, uint buf_size, ImVec2 size, int32 flags, void* callback, void* user_data);
		[CLink] public static extern bool igInputTextWithHint(char8* label, char8* hint, char8* buf, uint buf_size, int32 flags, void* callback, void* user_data);
		[CLink] public static extern bool igSelectable_Bool(char8* label, bool selected, int32 flags, ImVec2 size);
		[CLink] public static extern bool igTreeNodeEx_Str(char8* label, int32 flags);
		[CLink] public static extern void igTreePop();
		[CLink] public static extern bool igBeginMainMenuBar();
		[CLink] public static extern void igEndMainMenuBar();
		[CLink] public static extern bool igBeginMenuBar();
		[CLink] public static extern void igEndMenuBar();
		[CLink] public static extern bool igBeginMenu(char8* label, bool enabled);
		[CLink] public static extern void igEndMenu();
		[CLink] public static extern bool igMenuItem_Bool(char8* label, char8* shortcut, bool selected, bool enabled);
		[CLink] public static extern void igSeparator();
		[CLink] public static extern void igSeparatorText(char8* label);
		[CLink] public static extern void igSameLine(float offset_from_start_x, float spacing);
		[CLink] public static extern void igPushID_Str(char8* str_id);
		[CLink] public static extern void igPushID_Int(int32 int_id);
		[CLink] public static extern void igPopID();
		[CLink] public static extern void igOpenPopup_Str(char8* str_id, int32 popup_flags);
		[CLink] public static extern bool igBeginPopup(char8* str_id, int32 flags);
		[CLink] public static extern bool igBeginPopupModal(char8* name, bool* p_open, int32 flags);
		[CLink] public static extern void igEndPopup();
		[CLink] public static extern void igCloseCurrentPopup();
		[CLink] public static extern bool igIsPopupOpen_Str(char8* str_id, int32 flags);
		[CLink] public static extern bool igIsWindowHovered(int32 flags);
		[CLink] public static extern bool igIsWindowFocused(int32 flags);
		[CLink] public static extern bool igIsMouseClicked_Bool(int32 button, bool rep);
		[CLink] public static extern bool igIsMouseReleased_Nil(int32 button);
		[CLink] public static extern bool igIsMouseDown_Nil(int32 button);
		[CLink] public static extern bool igIsAnyMouseDown();
		[CLink] public static extern bool igIsKeyReleased_Nil(int32 key);
		[CLink] public static extern bool igIsMouseDoubleClicked_Nil(int32 button);
		[CLink] public static extern ImVec2 igGetMousePos();
		[CLink] public static extern uint32 igDockSpaceOverViewport(uint32 dockspace_id, ImGuiViewport* viewport, int32 flags, void* window_class);
		[CLink] public static extern ImGuiViewport* igGetMainViewport();
		[CLink] public static extern void igSetNextWindowPos(ImVec2 pos, int32 cond, ImVec2 pivot);
		[CLink] public static extern void igSetNextWindowSize(ImVec2 size, int32 cond);
		[CLink] public static extern void igPushStyleColor_U32(int32 idx, uint32 col);
		[CLink] public static extern void igPopStyleColor(int32 count);
		[CLink] public static extern void igPushStyleVar_Vec2(int32 idx, ImVec2 val);
		[CLink] public static extern void igPushStyleVar_Float(int32 idx, float val);
		[CLink] public static extern void igPopStyleVar(int32 count);
		[CLink] public static extern void igPushFont(ImFont* font, float size);
		[CLink] public static extern void igPopFont();
		[CLink] public static extern ImDrawList* igGetWindowDrawList();
		[CLink] public static extern bool igBeginDragDropSource(int32 flags);
		[CLink] public static extern bool igSetDragDropPayload(char8* type, void* data, uint sz, int32 cond);
		[CLink] public static extern void igEndDragDropSource();
		[CLink] public static extern bool igBeginDragDropTarget();
		[CLink] public static extern ImGuiPayload* igAcceptDragDropPayload(char8* type, int32 flags);
		[CLink] public static extern void igEndDragDropTarget();
		[CLink] public static extern bool igIsKeyPressed_Bool(int32 key, bool rep);
		[CLink] public static extern bool igIsKeyDown_Nil(int32 key);
		[CLink] public static extern void igSetKeyboardFocusHere(int32 offset);
		[CLink] public static extern bool igIsItemHovered(int32 flags);
		[CLink] public static extern bool igIsItemActive();
		[CLink] public static extern bool igIsItemClicked(int32 button);
		[CLink] public static extern bool igIsItemDeactivatedAfterEdit();
		[CLink] public static extern bool igIsAnyItemActive();
		[CLink] public static extern bool igBeginTooltip();
		[CLink] public static extern void igEndTooltip();
		[CLink] public static extern bool igCheckbox(char8* label, bool* v);
		[CLink] public static extern void igSetNextItemWidth(float item_width);
		[CLink] public static extern ImVec2 igGetContentRegionAvail();
		[CLink] public static extern ImVec2 igCalcTextSize(char8* text, char8* text_end, bool hide_after_hash, float wrap_width);
		[CLink] public static extern void igSetItemDefaultFocus();
		[CLink] public static extern bool igCollapsingHeader_TreeNodeFlags(char8* label, int32 flags);
		[CLink] public static extern void igDummy(ImVec2 size);
		[CLink] public static extern float igGetFrameHeight();
		[CLink] public static extern void igSetScrollHereY(float ratio);
		[CLink] public static extern bool igBeginTabBar(char8* str_id, int32 flags);
		[CLink] public static extern void igEndTabBar();
		[CLink] public static extern bool igBeginTabItem(char8* label, bool* p_open, int32 flags);
		[CLink] public static extern void igEndTabItem();
		[CLink] public static extern ImVec2 igGetCursorScreenPos();
		[CLink] public static extern ImVec2 igGetWindowPos();
		[CLink] public static extern ImVec2 igGetWindowSize();
		[CLink] public static extern void igSetWindowFocus_Str(char8* name);
		[CLink] public static extern void igIndent(float w);
		[CLink] public static extern void igUnindent(float w);
		[CLink] public static extern void igSpacing();
		[CLink] public static extern double igGetTime();
		[CLink] public static extern float igGetFontSize();
		[CLink] public static extern void igShowDemoWindow(bool* p_open);
		[CLink] public static extern bool igIsItemActivated();
		[CLink] public static extern bool igIsItemToggledOpen();
		[CLink] public static extern void igSetNextItemOpen(bool is_open, int32 cond);
		[CLink] public static extern bool igBeginPopupContextItem(char8* str_id = null, int32 popup_flags = 1);
		[CLink] public static extern uint32 igGetID_Str(char8* str_id);
		[CLink] public static extern uint32 igGetItemID();
		[CLink] public static extern void igDockBuilderDockWindow(char8* window_name, uint32 node_id);
		[CLink] public static extern void* igDockBuilderGetNode(uint32 node_id);
		[CLink] public static extern uint32 igDockBuilderAddNode(uint32 node_id, int32 flags);
		[CLink] public static extern void igDockBuilderRemoveNode(uint32 node_id);
		[CLink] public static extern void igDockBuilderSetNodeSize(uint32 node_id, ImVec2 size);
		[CLink] public static extern uint32 igDockBuilderSplitNode(uint32 node_id, int32 split_dir, float ratio, uint32* out_at_dir, uint32* out_opposite);
		[CLink] public static extern void igDockBuilderFinish(uint32 node_id);
		[CLink] public static extern bool igIsItemEdited();
		[CLink] public static extern bool igIsItemFocused();
		[CLink] public static extern bool igIsWindowAppearing();
		[CLink] public static extern void igSetNextWindowFocus();
		[CLink] public static extern ImVec2 igGetCursorPos();
		[CLink] public static extern void igSetCursorPos(ImVec2 local_pos);
		[CLink] public static extern void igBeginGroup();
		[CLink] public static extern void igEndGroup();
		[CLink] public static extern void igBeginDisabled(bool disabled);
		[CLink] public static extern void igEndDisabled();
		[CLink] public static extern ImVec2 igGetItemRectMin();
		[CLink] public static extern ImVec2 igGetItemRectMax();
		[CLink] public static extern bool igIsMouseDragging(int32 button, float lock_threshold);
		[CLink] public static extern char8* igGetClipboardText();
		[CLink] public static extern void igSetClipboardText(char8* text);
		[CLink] public static extern void igPushTextWrapPos(float wrap_local_pos_x);
		[CLink] public static extern void igPopTextWrapPos();

		[CLink] public static extern void ImDrawList_AddLine(ImDrawList* self, ImVec2 p1, ImVec2 p2, uint32 col, float thickness);
		[CLink] public static extern void ImDrawList_AddRect(ImDrawList* self, ImVec2 p_min, ImVec2 p_max, uint32 col, float rounding, float thickness, int32 flags);
		[CLink] public static extern void ImDrawList_AddRectFilled(ImDrawList* self, ImVec2 p_min, ImVec2 p_max, uint32 col, float rounding, int32 flags);
		[CLink] public static extern void ImDrawList_AddTriangleFilled(ImDrawList* self, ImVec2 p1, ImVec2 p2, ImVec2 p3, uint32 col);
		[CLink] public static extern void ImDrawList_AddCircleFilled(ImDrawList* self, ImVec2 center, float radius, uint32 col, int32 num_segments);
		[CLink] public static extern void ImDrawList_AddText_Vec2(ImDrawList* self, ImVec2 pos, uint32 col, char8* text_begin, char8* text_end);

		// ---- Used by the node-graph canvas (VisualBeefEditor/src/Canvas.bf, GraphPanel.bf) ----
		[CLink] public static extern bool igInvisibleButton(char8* str_id, ImVec2 size, int32 flags);
		[CLink] public static extern void igSetNextItemAllowOverlap();
		[CLink] public static extern void igSetCursorScreenPos(ImVec2 pos);
		[CLink] public static extern ImFont* igGetFont();
		[CLink] public static extern float igGetTextLineHeight();
		[CLink] public static extern bool igIsItemDeactivated();
		[CLink] public static extern bool igIsAnyItemHovered();
		[CLink] public static extern ImVec2 igGetMouseDragDelta(int32 button, float lock_threshold);
		[CLink] public static extern ImGuiKeyData* igGetKeyData_Key(int32 key);
		[CLink] public static extern bool igSetItemKeyOwner_Nil(int32 key);
		[CLink] public static extern void igSetKeyOwner(int32 key, uint32 owner_id, int32 flags);
		[CLink] public static extern void igSetMouseCursor(int32 cursor_type);
		[CLink] public static extern void igPushClipRect(ImVec2 clip_rect_min, ImVec2 clip_rect_max, bool intersect_with_current_clip_rect);
		[CLink] public static extern void igPopClipRect();
		[CLink] public static extern void ImDrawList_AddRectFilledMultiColor(ImDrawList* self, ImVec2 p_min, ImVec2 p_max, uint32 col_upr_left, uint32 col_upr_right, uint32 col_bot_right, uint32 col_bot_left);
		[CLink] public static extern void ImDrawList_AddCircle(ImDrawList* self, ImVec2 center, float radius, uint32 col, int32 num_segments, float thickness);
		[CLink] public static extern void ImDrawList_AddBezierCubic(ImDrawList* self, ImVec2 p1, ImVec2 p2, ImVec2 p3, ImVec2 p4, uint32 col, float thickness, int32 num_segments);
		[CLink] public static extern void ImDrawList_AddPolyline(ImDrawList* self, ImVec2* points, int32 num_points, uint32 col, float thickness, int32 flags);
		[CLink] public static extern void ImDrawList_AddConvexPolyFilled(ImDrawList* self, ImVec2* points, int32 num_points, uint32 col);
		[CLink] public static extern void ImDrawList_AddText_FontPtr(ImDrawList* self, ImFont* font, float font_size, ImVec2 pos, uint32 col, char8* text_begin, char8* text_end, float wrap_width, ImVec4* cpu_fine_clip_rect);
		[CLink] public static extern void ImDrawList_PushClipRect(ImDrawList* self, ImVec2 clip_rect_min, ImVec2 clip_rect_max, bool intersect_with_current_clip_rect);
		[CLink] public static extern void ImDrawList_PopClipRect(ImDrawList* self);

		// ---- Used by the Project Browser / asset editors (VisualBeefEditor/src/ProjectBrowser.bf) ----
		[CLink] public static extern bool igBeginPopupContextWindow(char8* str_id, int32 popup_flags);
		[CLink] public static extern bool igSliderFloat(char8* label, float* v, float v_min, float v_max, char8* format, int32 flags);
		[CLink] public static extern bool igBeginCombo(char8* label, char8* preview_value, int32 flags);
		[CLink] public static extern void igEndCombo();
		[CLink] public static extern bool igArrowButton(char8* str_id, int32 dir);
		[CLink] public static extern float igGetScrollY();
		[CLink] public static extern void igSetScrollY_Float(float scroll_y);
		[CLink] public static extern void igSetNextWindowScroll(ImVec2 scroll); // < 0 on an axis: leave it
		[CLink] public static extern void igAlignTextToFramePadding();
		[CLink] public static extern void ImDrawList_AddQuadFilled(ImDrawList* self, ImVec2 p1, ImVec2 p2, ImVec2 p3, ImVec2 p4, uint32 col);

		// ---- Graph UX (comment colours, action menu)
		[CLink] public static extern bool igColorEdit4(char8* label, float* col, int32 flags);
		[CLink] public static extern bool igColorButton(char8* desc_id, ImVec4 col, int32 flags, ImVec2 size);
		[CLink] public static extern ImVec4 igColorConvertU32ToFloat4(uint32 col);
		[CLink] public static extern uint32 igColorConvertFloat4ToU32(ImVec4 col);
		[CLink] public static extern bool igIsItemVisible();

		// ---- Friendly wrappers ---------------------------------------------------------------

		public static bool Begin(StringView name, bool* open = null, int32 flags = 0) => igBegin(scope String(name), open, flags);
		public static void End() => igEnd();

		public static void Text(StringView text)
		{
			igTextUnformatted(text.Ptr, text.Ptr + text.Length);
		}

		public static void TextColored(uint32 color, StringView text)
		{
			igPushStyleColor_U32(Col.Text, color);
			Text(text);
			igPopStyleColor(1);
		}

		public static void TextDisabled(StringView text)
		{
			igPushStyleColor_U32(Col.Text, Color(128, 128, 128));
			Text(text);
			igPopStyleColor(1);
		}

		public static bool Button(StringView label, ImVec2 size = default) => igButton(scope String(label), size);
		public static bool SmallButton(StringView label) => igSmallButton(scope String(label));
		public static void SameLine(float offset = 0, float spacing = -1) => igSameLine(offset, spacing);
		public static void Separator() => igSeparator();
		public static void SeparatorText(StringView label) => igSeparatorText(scope String(label));
		public static bool Selectable(StringView label, bool selected = false, int32 flags = 0, ImVec2 size = default) => igSelectable_Bool(scope String(label), selected, flags, size);
		public static bool MenuItem(StringView label, StringView shortcut = "", bool selected = false, bool enabled = true)
		{
			return igMenuItem_Bool(scope String(label), shortcut.IsEmpty ? null : scope:: String(shortcut), selected, enabled);
		}
		public static bool BeginMenu(StringView label, bool enabled = true) => igBeginMenu(scope String(label), enabled);
		public static void EndMenu() => igEndMenu();
		public static void PushID(StringView id) => igPushID_Str(scope String(id));
		public static void PushID(int32 id) => igPushID_Int(id);
		public static void PopID() => igPopID();
		public static void OpenPopup(StringView id) => igOpenPopup_Str(scope String(id), 0);
		public static bool BeginPopup(StringView id, int32 flags = 0) => igBeginPopup(scope String(id), flags);
		public static void EndPopup() => igEndPopup();
		public static bool IsKeyPressed(int32 key, bool rep = true) => igIsKeyPressed_Bool(key, rep);
		public static bool IsKeyDown(int32 key) => igIsKeyDown_Nil(key);
		public static bool IsCtrlDown => igIsKeyDown_Nil(Key.ModCtrl);
		public static bool IsShiftDown => igIsKeyDown_Nil(Key.ModShift);
		public static bool IsAltDown => igIsKeyDown_Nil(Key.ModAlt);
		public static bool Checkbox(StringView label, bool* v) => igCheckbox(scope String(label), v);
		public static bool TreeNode(StringView label, int32 flags = 0) => igTreeNodeEx_Str(scope String(label), flags);
		public static void TreePop() => igTreePop();
		public static bool CollapsingHeader(StringView label, int32 flags = 0) => igCollapsingHeader_TreeNodeFlags(scope String(label), flags);

		public static void Tooltip(StringView text)
		{
			if (igBeginTooltip())
			{
				Text(text);
				igEndTooltip();
			}
		}

		public static void TextWrappedDim(StringView text)
		{
			igPushTextWrapPos(0);
			TextDisabled(text);
			igPopTextWrapPos();
		}

		public static ImVec2 CalcTextSize(StringView text) => igCalcTextSize(text.Ptr, text.Ptr + text.Length, false, -1);
	}

	/// A fixed-capacity, null-terminated text buffer for ImGui input widgets, kept in sync with
	/// a Beef string.
	class TextBuffer
	{
		public char8* Ptr;
		public int Capacity;

		public this(int capacity = 256)
		{
			Capacity = capacity;
			Ptr = new char8[capacity]*;
			Ptr[0] = 0;
		}

		public ~this()
		{
			delete Ptr;
		}

		public void Set(StringView text)
		{
			var text;
			if (text.Length >= Capacity)
			{
				// Grow to fit (keep some headroom for typing).
				int newCap = text.Length * 2 + 1024;
				char8* newPtr = new char8[newCap]*;
				delete Ptr;
				Ptr = newPtr;
				Capacity = newCap;
			}
			Internal.MemCpy(Ptr, text.Ptr, text.Length);
			Ptr[text.Length] = 0;
		}

		public StringView View => StringView(Ptr);

		public bool Equals(StringView text) => View == text;
	}
}
