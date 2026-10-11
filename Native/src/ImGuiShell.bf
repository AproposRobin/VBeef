using System;

// Bindings used by the editor shell (theme, icon font, toolbar, property grid, DPI).
// Kept in their own file so they merge cleanly with additions to ImGui.bf. All of these are
// exported by the prebuilt vbhost.dll (cimgui 1.92.9 docking); no native rebuild is needed.
namespace ImGui
{
	/// Mirror of ImGuiStyle (cimgui 1.92.9). Field order and types must match exactly.
	[CRepr]
	struct ImGuiStyle
	{
		public float FontSizeBase;
		public float FontScaleMain;
		public float FontScaleDpi;
		public float Alpha;
		public float DisabledAlpha;
		public ImVec2 WindowPadding;
		public float WindowRounding;
		public float WindowBorderSize;
		public float WindowBorderHoverPadding;
		public ImVec2 WindowMinSize;
		public ImVec2 WindowTitleAlign;
		public int32 WindowMenuButtonPosition;
		public float ChildRounding;
		public float ChildBorderSize;
		public float PopupRounding;
		public float PopupBorderSize;
		public ImVec2 FramePadding;
		public float FrameRounding;
		public float FrameBorderSize;
		public ImVec2 ItemSpacing;
		public ImVec2 ItemInnerSpacing;
		public ImVec2 CellPadding;
		public ImVec2 TouchExtraPadding;
		public float IndentSpacing;
		public float ColumnsMinSpacing;
		public float ScrollbarSize;
		public float ScrollbarRounding;
		public float ScrollbarPadding;
		public float GrabMinSize;
		public float GrabRounding;
		public float LogSliderDeadzone;
		public float ImageRounding;
		public float ImageBorderSize;
		public float TabRounding;
		public float TabBorderSize;
		public float TabMinWidthBase;
		public float TabMinWidthShrink;
		public float TabCloseButtonMinWidthSelected;
		public float TabCloseButtonMinWidthUnselected;
		public float TabBarBorderSize;
		public float TabBarOverlineSize;
		public float TableAngledHeadersAngle;
		public ImVec2 TableAngledHeadersTextAlign;
		public int32 TreeLinesFlags;
		public float TreeLinesSize;
		public float TreeLinesRounding;
		public float MenuItemRounding;
		public float SelectableRounding;
		public float DragDropTargetRounding;
		public float DragDropTargetBorderSize;
		public float DragDropTargetPadding;
		public float ColorMarkerSize;
		public int32 ColorButtonPosition;
		public ImVec2 ButtonTextAlign;
		public ImVec2 SelectableTextAlign;
		public float InputTextCursorSize;
		public float SeparatorSize;
		public float SeparatorTextBorderSize;
		public ImVec2 SeparatorTextAlign;
		public ImVec2 SeparatorTextPadding;
		public ImVec2 DisplayWindowPadding;
		public ImVec2 DisplaySafeAreaPadding;
		public bool DockingNodeHasCloseButton;
		public float DockingSeparatorSize;
		public float MouseCursorScale;
		public bool AntiAliasedLines;
		public bool AntiAliasedLinesUseTex;
		public bool AntiAliasedFill;
		public float CurveTessellationTol;
		public float CircleTessellationMaxError;
		public ImVec4[ColX.COUNT] Colors;
		public float HoverStationaryDelay;
		public float HoverDelayShort;
		public float HoverDelayNormal;
		public int32 HoverFlagsForTooltipMouse;
		public int32 HoverFlagsForTooltipNav;
		public float _MainScale;
		public float _NextFrameFontSizeBase;
	}

	struct ImFontAtlas;

	/// Mirror of ImGuiWindowClass (docking: per-window dock-node flag overrides).
	[CRepr]
	struct ImGuiWindowClass
	{
		public uint32 ClassId;
		public uint32 ParentViewportId = 0xFFFFFFFF;
		public uint32 FocusRouteParentWindowId;
		public int32 ViewportFlagsOverrideSet;
		public int32 ViewportFlagsOverrideClear;
		public int32 TabItemFlagsOverrideSet;
		public int32 DockNodeFlagsOverrideSet;
		public bool DockingAlwaysTabBar;
		public bool DockingAllowUnclassed = true;
		public void* PlatformIconData;
	}

	/// The first fields of ImGuiIO (cimgui 1.92.9); only ever used through a pointer.
	[CRepr]
	struct ImGuiIOHead
	{
		public int32 ConfigFlags;
		public int32 BackendFlags;
		public ImVec2 DisplaySize;
		public ImVec2 DisplayFramebufferScale;
		public float DeltaTime;
		public float IniSavingRate;
		public char8* IniFilename;
		public char8* LogFilename;
		public void* UserData;
		public ImFontAtlas* Fonts;
		public ImFont* FontDefault;
		public bool FontAllowUserScaling;
	}

	/// Mirror of ImFontConfig (cimgui 1.92.9, ImWchar = 16 bit).
	[CRepr]
	struct ImFontConfig
	{
		public char8[40] Name;
		public void* FontData;
		public int32 FontDataSize;
		public bool FontDataOwnedByAtlas;
		public bool MergeMode;
		public bool PixelSnapH;
		public int8 OversampleH;
		public int8 OversampleV;
		public uint16 EllipsisChar;
		public float SizePixels;
		public uint16* GlyphRanges;
		public uint16* GlyphExcludeRanges;
		public ImVec2 GlyphOffset;
		public float GlyphMinAdvanceX;
		public float GlyphMaxAdvanceX;
		public float GlyphExtraAdvanceX;
		public uint32 FontNo;
		public uint32 FontLoaderFlags;
		public float RasterizerMultiply;
		public float RasterizerDensity;
		public float ExtraSizeScale;
		public int32 Flags;
		public ImFont* DstFont;
		public void* FontLoader;
		public void* FontLoaderData;
	}

	/// Every ImGuiCol_ value (1.92.9 order); `Col` in ImGui.bf only lists the common ones.
	static class ColX
	{
		public const int32 Text = 0;
		public const int32 TextDisabled = 1;
		public const int32 WindowBg = 2;
		public const int32 ChildBg = 3;
		public const int32 PopupBg = 4;
		public const int32 Border = 5;
		public const int32 BorderShadow = 6;
		public const int32 FrameBg = 7;
		public const int32 FrameBgHovered = 8;
		public const int32 FrameBgActive = 9;
		public const int32 TitleBg = 10;
		public const int32 TitleBgActive = 11;
		public const int32 TitleBgCollapsed = 12;
		public const int32 MenuBarBg = 13;
		public const int32 ScrollbarBg = 14;
		public const int32 ScrollbarGrab = 15;
		public const int32 ScrollbarGrabHovered = 16;
		public const int32 ScrollbarGrabActive = 17;
		public const int32 CheckMark = 18;
		public const int32 CheckboxSelectedBg = 19;
		public const int32 SliderGrab = 20;
		public const int32 SliderGrabActive = 21;
		public const int32 Button = 22;
		public const int32 ButtonHovered = 23;
		public const int32 ButtonActive = 24;
		public const int32 Header = 25;
		public const int32 HeaderHovered = 26;
		public const int32 HeaderActive = 27;
		public const int32 Separator = 28;
		public const int32 SeparatorHovered = 29;
		public const int32 SeparatorActive = 30;
		public const int32 ResizeGrip = 31;
		public const int32 ResizeGripHovered = 32;
		public const int32 ResizeGripActive = 33;
		public const int32 InputTextCursor = 34;
		public const int32 TabHovered = 35;
		public const int32 Tab = 36;
		public const int32 TabSelected = 37;
		public const int32 TabSelectedOverline = 38;
		public const int32 TabDimmed = 39;
		public const int32 TabDimmedSelected = 40;
		public const int32 TabDimmedSelectedOverline = 41;
		public const int32 DockingPreview = 42;
		public const int32 DockingEmptyBg = 43;
		public const int32 PlotLines = 44;
		public const int32 PlotLinesHovered = 45;
		public const int32 PlotHistogram = 46;
		public const int32 PlotHistogramHovered = 47;
		public const int32 TableHeaderBg = 48;
		public const int32 TableBorderStrong = 49;
		public const int32 TableBorderLight = 50;
		public const int32 TableRowBg = 51;
		public const int32 TableRowBgAlt = 52;
		public const int32 TextLink = 53;
		public const int32 TextSelectedBg = 54;
		public const int32 TreeLines = 55;
		public const int32 DragDropTarget = 56;
		public const int32 DragDropTargetBg = 57;
		public const int32 UnsavedMarker = 58;
		public const int32 NavCursor = 59;
		public const int32 NavWindowingHighlight = 60;
		public const int32 NavWindowingDimBg = 61;
		public const int32 ModalWindowDimBg = 62;
		public const int32 COUNT = 63;
	}

	static class DockNodeFlagsX
	{
		public const int32 AutoHideTabBar = 1 << 6;
		public const int32 NoWindowMenuButton = 1 << 14;
		public const int32 NoCloseButton = 1 << 15;
	}

	static class TableFlags
	{
		public const int32 None = 0;
		public const int32 Resizable = 1 << 0;
		public const int32 RowBg = 1 << 6;
		public const int32 BordersInnerH = 1 << 7;
		public const int32 BordersOuterH = 1 << 8;
		public const int32 BordersInnerV = 1 << 9;
		public const int32 BordersOuterV = 1 << 10;
		public const int32 SizingFixedFit = 1 << 13;
		public const int32 SizingStretchProp = 3 << 13;
		public const int32 NoPadOuterX = 1 << 22;
		public const int32 ScrollY = 1 << 25;
	}

	static class TableColumnFlags
	{
		public const int32 None = 0;
		public const int32 WidthStretch = 1 << 3;
		public const int32 WidthFixed = 1 << 4;
		public const int32 NoResize = 1 << 5;
	}

	static class TableBgTarget
	{
		public const int32 RowBg0 = 1;
		public const int32 RowBg1 = 2;
		public const int32 CellBg = 3;
	}

	static class WindowFlagsX
	{
		public const int32 NoFocusOnAppearing = 1 << 12;
		public const int32 NoBringToFrontOnFocus = 1 << 13;
		public const int32 NoNavInputs = 1 << 16;
		public const int32 NoNavFocus = 1 << 17;
		public const int32 NoNav = NoNavInputs | NoNavFocus;
		public const int32 NoInputs = (1 << 9) | NoNavInputs | NoNavFocus;
	}

	static class TreeNodeFlagsX
	{
		public const int32 AllowOverlap = 1 << 2;
		public const int32 FramePadding = 1 << 10;
		public const int32 SpanAllColumns = 1 << 14;
		/// The label is drawn across all columns of the table (not cut at the first column).
		public const int32 LabelSpanAllColumns = 1 << 15;
	}

	/// ImGuiStyleVar_ values missing from `StyleVar` in ImGui.bf (1.92.9 order).
	static class StyleVarX
	{
		public const int32 Alpha = 0;
		public const int32 WindowRounding = 3;
		public const int32 WindowBorderSize = 4;
		public const int32 ChildRounding = 7;
		public const int32 PopupRounding = 9;
		public const int32 IndentSpacing = 16;
		public const int32 CellPadding = 17;
		public const int32 ScrollbarSize = 18;
		public const int32 TabRounding = 25;
		public const int32 SelectableRounding = 36;
		public const int32 ButtonTextAlign = 38;
		public const int32 SelectableTextAlign = 39;
	}

	static class SliderFlags
	{
		public const int32 None = 0;
		public const int32 AlwaysClamp = (1 << 4) | (1 << 9);
	}

	/// Keys missing from `Key` in ImGui.bf (ImGuiKey_A = 546, consecutive letters; F1 = 572).
	static class KeyX
	{
		public const int32 E = 550;
		public const int32 G = 552;
		public const int32 H = 553;
		public const int32 L = 557;
		public const int32 M = 558;
		public const int32 P = 561;
		public const int32 Q = 562;
		public const int32 W = 568;
		public const int32 F1 = 572;
		public const int32 F2 = 573;
		public const int32 F7 = 578;
		public const int32 Insert = 521;
		public const int32 End = 520;
	}

	extension Gui
	{
		[CLink] public static extern ImGuiStyle* igGetStyle();
		[CLink] public static extern void igSetNextWindowClass(ImGuiWindowClass* window_class);
		[CLink] public static extern ImGuiIOHead* igGetIO_Nil();
		[CLink] public static extern void ImGuiStyle_ScaleAllSizes(ImGuiStyle* self, float scale_factor);
		[CLink] public static extern ImFontConfig* ImFontConfig_ImFontConfig();
		[CLink] public static extern void ImFontConfig_destroy(ImFontConfig* self);
		[CLink] public static extern ImFont* ImFontAtlas_AddFontFromMemoryTTF(ImFontAtlas* self, void* font_data, int32 font_data_size, float size_pixels, ImFontConfig* font_cfg, uint16* glyph_ranges);
		[CLink] public static extern ImFont* ImFontAtlas_AddFontFromFileTTF(ImFontAtlas* self, char8* filename, float size_pixels, ImFontConfig* font_cfg, uint16* glyph_ranges);
		[CLink] public static extern bool igBeginViewportSideBar(char8* name, ImGuiViewport* viewport, int32 dir, float size, int32 window_flags);
		[CLink] public static extern bool igBeginTable(char8* str_id, int32 columns, int32 flags, ImVec2 outer_size, float inner_width);
		[CLink] public static extern void igEndTable();
		[CLink] public static extern void igTableNextRow(int32 row_flags, float min_row_height);
		[CLink] public static extern bool igTableNextColumn();
		[CLink] public static extern bool igTableSetColumnIndex(int32 column_n);
		[CLink] public static extern void igTableSetupColumn(char8* label, int32 flags, float init_width_or_weight, uint32 user_data);
		[CLink] public static extern void igTableSetBgColor(int32 target, uint32 color, int32 column_n);
		[CLink] public static extern bool igDragFloat(char8* label, float* v, float v_speed, float v_min, float v_max, char8* format, int32 flags);
		[CLink] public static extern bool igDragInt(char8* label, int32* v, float v_speed, int32 v_min, int32 v_max, char8* format, int32 flags);
		[CLink] public static extern ImDrawList* igGetForegroundDrawList_ViewportPtr(ImGuiViewport* viewport);
		[CLink] public static extern void igProgressBar(float fraction, ImVec2 size_arg, char8* overlay);
		[CLink] public static extern int32 igGetFrameCount();
		[CLink] public static extern void igSetNextWindowBgAlpha(float alpha);
		[CLink] public static extern bool igIsMouseHoveringRect(ImVec2 r_min, ImVec2 r_max, bool clip);
		[CLink] public static extern uint32 igGetColorU32_Col(int32 idx, float alpha_mul);
		[CLink] public static extern void igSetNextWindowViewport(uint32 viewport_id);
		[CLink] public static extern bool igIsWindowDocked();
		[CLink] public static extern float igGetWindowWidth();
		[CLink] public static extern float igGetWindowHeight();
		[CLink] public static extern void igSetNextWindowSizeConstraints(ImVec2 size_min, ImVec2 size_max, void* custom_callback, void* custom_callback_data);
		[CLink] public static extern float igGetScrollMaxY();
		[CLink] public static extern void igPushItemWidth(float item_width);
		[CLink] public static extern void igPopItemWidth();
		[CLink] public static extern float igGetCursorPosX();
		[CLink] public static extern float igGetCursorPosY();
		[CLink] public static extern void igSetCursorPosX(float local_x);
		[CLink] public static extern void igSetCursorPosY(float local_y);
		[CLink] public static extern float igGetTextLineHeightWithSpacing();
		[CLink] public static extern bool igRadioButton_Bool(char8* label, bool active);
		[CLink] public static extern bool igBeginItemTooltip();
		[CLink] public static extern void igLogToClipboard(int32 auto_open_depth);
		[CLink] public static extern bool igBeginChild_ID(uint32 id, ImVec2 size, int32 child_flags, int32 window_flags);
		[CLink] public static extern void ImDrawList_PathLineTo(ImDrawList* self, ImVec2 pos);
		[CLink] public static extern void ImDrawList_PathStroke(ImDrawList* self, uint32 col, int32 flags, float thickness);
		[CLink] public static extern void ImDrawList_AddTriangle(ImDrawList* self, ImVec2 p1, ImVec2 p2, ImVec2 p3, uint32 col, float thickness);

		/// Text drawn with a colour, a font size and an optional font, without ImGui layout.
		public static void DrawText(ImDrawList* dl, ImVec2 pos, uint32 col, StringView text, float size = 0, ImFont* font = null)
		{
			if (size <= 0)
				ImDrawList_AddText_Vec2(dl, pos, col, text.Ptr, text.Ptr + text.Length);
			else
				ImDrawList_AddText_FontPtr(dl, font != null ? font : igGetFont(), size, pos, col, text.Ptr, text.Ptr + text.Length, 0, null);
		}
	}
}
