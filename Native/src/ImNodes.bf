using System;

namespace ImGui
{
	struct ImNodesEditorContext;

	static class NodesCol
	{
		public const int32 NodeBackground = 0;
		public const int32 NodeBackgroundHovered = 1;
		public const int32 NodeBackgroundSelected = 2;
		public const int32 NodeOutline = 3;
		public const int32 TitleBar = 4;
		public const int32 TitleBarHovered = 5;
		public const int32 TitleBarSelected = 6;
		public const int32 Link = 7;
		public const int32 LinkHovered = 8;
		public const int32 LinkSelected = 9;
		public const int32 Pin = 10;
		public const int32 PinHovered = 11;
	}

	static class PinShape
	{
		public const int32 Circle = 0;
		public const int32 CircleFilled = 1;
		public const int32 Triangle = 2;
		public const int32 TriangleFilled = 3;
		public const int32 Quad = 4;
		public const int32 QuadFilled = 5;
	}

	static class NodesStyleVar
	{
		public const int32 NodePadding = 2;
		public const int32 NodeBorderThickness = 3;
	}

	static class MiniMapLocation
	{
		public const int32 BottomLeft = 0;
		public const int32 BottomRight = 1;
		public const int32 TopLeft = 2;
		public const int32 TopRight = 3;
	}

	static class AttributeFlags
	{
		public const int32 None = 0;
		public const int32 EnableLinkDetachWithDragClick = 1 << 0;
		public const int32 EnableLinkCreationOnSnap = 1 << 1;
	}

	/// Bindings for imnodes (via cimnodes).
	static class ImNodes
	{
		[CLink] public static extern ImNodesEditorContext* imnodes_EditorContextCreate();
		[CLink] public static extern void imnodes_EditorContextFree(ImNodesEditorContext* ctx);
		[CLink] public static extern void imnodes_EditorContextSet(ImNodesEditorContext* ctx);
		[CLink] public static extern ImVec2 imnodes_EditorContextGetPanning();
		[CLink] public static extern void imnodes_EditorContextResetPanning(ImVec2 pos);
		[CLink] public static extern void imnodes_EditorContextMoveToNode(int32 node_id);
		[CLink] public static extern void imnodes_BeginNodeEditor();
		[CLink] public static extern void imnodes_EndNodeEditor();
		[CLink] public static extern void imnodes_MiniMap(float fraction, int32 location, void* callback, void* data);
		[CLink] public static extern void imnodes_PushColorStyle(int32 item, uint32 color);
		[CLink] public static extern void imnodes_PopColorStyle();
		[CLink] public static extern void imnodes_PushStyleVar_Float(int32 item, float value);
		[CLink] public static extern void imnodes_PushStyleVar_Vec2(int32 item, ImVec2 value);
		[CLink] public static extern void imnodes_PopStyleVar(int32 count);
		[CLink] public static extern void imnodes_BeginNode(int32 id);
		[CLink] public static extern void imnodes_EndNode();
		[CLink] public static extern ImVec2 imnodes_GetNodeDimensions(int32 id);
		[CLink] public static extern void imnodes_BeginNodeTitleBar();
		[CLink] public static extern void imnodes_EndNodeTitleBar();
		[CLink] public static extern void imnodes_BeginInputAttribute(int32 id, int32 shape);
		[CLink] public static extern void imnodes_EndInputAttribute();
		[CLink] public static extern void imnodes_BeginOutputAttribute(int32 id, int32 shape);
		[CLink] public static extern void imnodes_EndOutputAttribute();
		[CLink] public static extern void imnodes_BeginStaticAttribute(int32 id);
		[CLink] public static extern void imnodes_EndStaticAttribute();
		[CLink] public static extern void imnodes_PushAttributeFlag(int32 flag);
		[CLink] public static extern void imnodes_PopAttributeFlag();
		[CLink] public static extern void imnodes_Link(int32 id, int32 start_attr, int32 end_attr);
		[CLink] public static extern void imnodes_SetNodeGridSpacePos(int32 node_id, ImVec2 pos);
		[CLink] public static extern ImVec2 imnodes_GetNodeGridSpacePos(int32 node_id);
		[CLink] public static extern ImVec2 imnodes_GetNodeScreenSpacePos(int32 node_id);
		[CLink] public static extern bool imnodes_IsEditorHovered();
		[CLink] public static extern bool imnodes_IsNodeHovered(int32* node_id);
		[CLink] public static extern bool imnodes_IsLinkHovered(int32* link_id);
		[CLink] public static extern bool imnodes_IsPinHovered(int32* attr_id);
		[CLink] public static extern int32 imnodes_NumSelectedNodes();
		[CLink] public static extern int32 imnodes_NumSelectedLinks();
		[CLink] public static extern void imnodes_GetSelectedNodes(int32* node_ids);
		[CLink] public static extern void imnodes_GetSelectedLinks(int32* link_ids);
		[CLink] public static extern void imnodes_ClearNodeSelection_Nil();
		[CLink] public static extern void imnodes_ClearLinkSelection_Nil();
		[CLink] public static extern void imnodes_SelectNode(int32 node_id);
		[CLink] public static extern bool imnodes_IsNodeSelected(int32 node_id);
		[CLink] public static extern bool imnodes_IsAnyAttributeActive(int32* attr_id);
		[CLink] public static extern bool imnodes_IsLinkStarted(int32* started_at);
		[CLink] public static extern bool imnodes_IsLinkDropped(int32* started_at, bool including_detached);
		[CLink] public static extern bool imnodes_IsLinkCreated_BoolPtr(int32* start_attr, int32* end_attr, bool* from_snap);
		[CLink] public static extern bool imnodes_IsLinkDestroyed(int32* link_id);
	}

	/// The native host: window, GL context and ImGui/imnodes contexts.
	static class Host
	{
		[CLink] public static extern int32 vbh_init(char8* title, int32 width, int32 height);
		[CLink] public static extern int32 vbh_begin_frame();
		[CLink] public static extern void vbh_end_frame();
		[CLink] public static extern void vbh_cancel_quit();
		[CLink] public static extern void vbh_set_title(char8* title);
		[CLink] public static extern char8* vbh_poll_drop();
		[CLink] public static extern ImFont* vbh_get_mono_font();
		[CLink] public static extern void vbh_shutdown();
		/// 1 = chosen, 0 = cancelled, -1 = no native dialog available
		[CLink] public static extern int32 vbh_native_dialog(int32 pickFolder, char8* initialDir, char8* outPath, int32 outCap);
		/// UI scale of the window's display (VB_UI_SCALE / GDK_SCALE off Windows; 1.0 = 96 dpi).
		[CLink] public static extern float vbh_get_window_scale();
		[CLink] public static extern void vbh_raise_window();
		/// SDL_WindowFlags of the window (0x40 minimized, 0x200 input focus).
		[CLink] public static extern uint32 vbh_window_flags();
		/// Handler for host asserts (IM_ASSERT, SDL's). Pass a `function void(char8* expr, char8* file, int32 line)`
		/// cast to void*; it must not block (no dialog). NULL restores the stderr line. Export count +1 (vbhost.dll).
		[CLink] public static extern void vbh_set_assert_handler(void* handler);
	}
}
