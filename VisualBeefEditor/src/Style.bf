using System;
using ImGui;

namespace VisualBeef.Editor
{
	/// Editor chrome theme, tuned to Unreal Engine 5's "Starship" dark style (FStyleColors):
	/// Title #151515, Recessed #1A1A1A, Panel #242424, Header #2F2F2F, Dropdown #383838,
	/// Hover #575757, Input #0F0F0F, Foreground #C0C0C0, Primary/Select #0070E0.
	/// Node-graph colours stay in Theme.bf.
	static class Look
	{
		/// A popup opened from inside a PropertyGrid would draw with the grid's tight item spacing (the
		/// style stack is global, popups included): its rows and the search box sat 2 px apart. These two
		/// give the popup the normal spacing at any scale; draw the popup with them instead of Gui.BeginPopup.
		public static bool BeginPopupSpaced(StringView id)
		{
			Gui.igPushStyleVar_Vec2(StyleVar.ItemSpacing, .(6 * Scale, 4 * Scale));
			if (Gui.BeginPopup(id))
				return true;
			Gui.igPopStyleVar(1);
			return false;
		}

		public static void EndPopupSpaced()
		{
			Gui.igPopStyleVar(1);
			Gui.EndPopup();
		}

		public static uint32 Black = Gui.Color(0, 0, 0);
		public static uint32 Title = Gui.Color(21, 21, 21);
		public static uint32 WindowBorder = Gui.Color(15, 15, 15);
		public static uint32 Recessed = Gui.Color(26, 26, 26);
		public static uint32 Panel = Gui.Color(36, 36, 36);
		public static uint32 Header = Gui.Color(47, 47, 47);
		public static uint32 Dropdown = Gui.Color(56, 56, 56);
		public static uint32 DropdownOutline = Gui.Color(76, 76, 76);
		public static uint32 Hover = Gui.Color(87, 87, 87);
		public static uint32 Hover2 = Gui.Color(128, 128, 128);
		public static uint32 Input = Gui.Color(15, 15, 15);
		public static uint32 InputOutline = Gui.Color(56, 56, 56);
		public static uint32 Foreground = Gui.Color(192, 192, 192);
		public static uint32 ForegroundHover = Gui.Color(255, 255, 255);
		public static uint32 ForegroundDim = Gui.Color(128, 128, 128);
		public static uint32 Primary = Gui.Color(0, 112, 224);
		public static uint32 PrimaryHover = Gui.Color(14, 134, 255);
		public static uint32 PrimaryPress = Gui.Color(0, 80, 160);
		public static uint32 SelectInactive = Gui.Color(0, 57, 110);
		public static uint32 AccentBlue = Gui.Color(38, 187, 255);
		public static uint32 AccentGreen = Gui.Color(139, 194, 74);
		public static uint32 AccentOrange = Gui.Color(254, 155, 7);
		public static uint32 AccentYellow = Gui.Color(255, 220, 26);
		public static uint32 AccentFolder = Gui.Color(182, 143, 85);
		public static uint32 Warning = Gui.Color(255, 184, 0);
		public static uint32 Error = Gui.Color(239, 53, 53);
		public static uint32 Success = Gui.Color(31, 228, 75);

		static ImGuiStyle sBase;
		static bool sHaveBase;
		public static float Scale = 1;
		/// Base UI font size in pixels at 96 dpi (Preferences).
		public static float FontSize = 16;
		/// "Darker" theme (Preferences): panels one step darker.
		public static bool Darker;
		/// The scale the native host loaded fonts and sized the style with at start-up.
		public static float HostScale = 1;

		static ImVec4 V(uint32 c) => Gui.igColorConvertU32ToFloat4(c);

		/// Applies the theme at `scale` (monitor DPI / 96). Safe to call again on DPI or font
		/// size changes: sizes are always derived from the unscaled base.
		public static void Apply(float scale)
		{
			let s = Gui.igGetStyle();
			if (!sHaveBase)
			{
				// The host scaled the style for display 0 at start-up; keep an unscaled copy.
				sBase = *s;
				float hostScale = Math.Max(0.5f, s.FramePadding.x / 6.0f);
				HostScale = hostScale;
				if (Math.Abs(hostScale - 1) > 0.01f)
					Gui.ImGuiStyle_ScaleAllSizes(&sBase, 1.0f / hostScale);
				sHaveBase = true;
			}
			Scale = scale;
			*s = sBase;

			s.WindowPadding = .(8, 8);
			s.WindowRounding = 0;
			s.WindowBorderSize = 1;
			s.WindowMenuButtonPosition = -1; // ImGuiDir_None: no "v" button in title/tab bars
			s.ChildRounding = 0;
			s.ChildBorderSize = 1;
			s.PopupRounding = 4;
			s.PopupBorderSize = 1;
			s.FramePadding = .(8, 4);
			s.FrameRounding = 3;
			s.FrameBorderSize = 1;
			s.ItemSpacing = .(6, 4);
			s.ItemInnerSpacing = .(6, 4);
			s.CellPadding = .(6, 3);
			s.IndentSpacing = 16;
			s.ScrollbarSize = 12;
			s.ScrollbarRounding = 6;
			s.ScrollbarPadding = 2;
			s.GrabMinSize = 10;
			s.GrabRounding = 3;
			s.TabRounding = 4;
			s.TabBorderSize = 0;
			s.TabBarBorderSize = 1;
			s.TabBarOverlineSize = 2;
			s.TabCloseButtonMinWidthUnselected = 0; // UE: the x shows on hover / the active tab only (-1 showed it on every tab)
			s.MenuItemRounding = 3;
			s.SelectableRounding = 2;
			s.SeparatorTextBorderSize = 1;
			s.SeparatorTextPadding = .(4, 4);
			s.DockingNodeHasCloseButton = false;
			s.DockingSeparatorSize = 2;
			s.WindowTitleAlign = .(0, 0.5f);
			s.ButtonTextAlign = .(0.5f, 0.5f);
			s.HoverDelayShort = 0.25f;
			s.HoverDelayNormal = 0.5f;

			var c = ref s.Colors;
			uint32 panel = Darker ? Gui.Color(26, 26, 26) : Panel;
			// Lists and consoles sit one step below their panel: in Darker the panel is already #1A1A1A.
			Recessed = Darker ? Gui.Color(18, 18, 18) : Gui.Color(26, 26, 26);
			c[ColX.Text] = V(Foreground);
			c[ColX.TextDisabled] = V(ForegroundDim);
			c[ColX.WindowBg] = V(panel);
			c[ColX.ChildBg] = V(Gui.Color(0, 0, 0, 0));
			c[ColX.PopupBg] = V(Gui.Color(36, 36, 36, 250));
			c[ColX.Border] = V(WindowBorder);
			c[ColX.BorderShadow] = V(Gui.Color(0, 0, 0, 0));
			c[ColX.FrameBg] = V(Input);
			c[ColX.FrameBgHovered] = V(Gui.Color(20, 20, 20));
			c[ColX.FrameBgActive] = V(Gui.Color(10, 10, 10));
			c[ColX.TitleBg] = V(Title);
			c[ColX.TitleBgActive] = V(Title);
			c[ColX.TitleBgCollapsed] = V(Title);
			c[ColX.MenuBarBg] = V(Title);
			c[ColX.ScrollbarBg] = V(Gui.Color(0, 0, 0, 0));
			c[ColX.ScrollbarGrab] = V(Dropdown);
			c[ColX.ScrollbarGrabHovered] = V(Hover);
			c[ColX.ScrollbarGrabActive] = V(Hover2);
			c[ColX.CheckMark] = V(ForegroundHover);
			c[ColX.CheckboxSelectedBg] = V(Primary);
			c[ColX.SliderGrab] = V(Primary);
			c[ColX.SliderGrabActive] = V(PrimaryHover);
			c[ColX.Button] = V(Dropdown);
			c[ColX.ButtonHovered] = V(Hover);
			c[ColX.ButtonActive] = V(PrimaryPress);
			c[ColX.Header] = V(Header);
			c[ColX.HeaderHovered] = V(Gui.Color(64, 64, 64));
			c[ColX.HeaderActive] = V(Primary);
			c[ColX.Separator] = V(WindowBorder);
			c[ColX.SeparatorHovered] = V(Primary);
			c[ColX.SeparatorActive] = V(PrimaryHover);
			c[ColX.ResizeGrip] = V(Gui.Color(0, 0, 0, 0));
			c[ColX.ResizeGripHovered] = V(Primary);
			c[ColX.ResizeGripActive] = V(PrimaryHover);
			c[ColX.InputTextCursor] = V(ForegroundHover);
			c[ColX.TabHovered] = V(Dropdown);
			c[ColX.Tab] = V(Title);
			c[ColX.TabSelected] = V(panel);
			c[ColX.TabSelectedOverline] = V(Primary);
			c[ColX.TabDimmed] = V(Title);
			c[ColX.TabDimmedSelected] = V(panel);
			c[ColX.TabDimmedSelectedOverline] = V(Gui.Color(0, 0, 0, 0));
			c[ColX.DockingPreview] = V(Gui.Color(0, 112, 224, 140));
			c[ColX.DockingEmptyBg] = V(Title);
			c[ColX.TableHeaderBg] = V(Header);
			c[ColX.TableBorderStrong] = V(WindowBorder);
			c[ColX.TableBorderLight] = V(Gui.Color(30, 30, 30));
			c[ColX.TableRowBg] = V(Gui.Color(0, 0, 0, 0));
			c[ColX.TableRowBgAlt] = V(Gui.Color(255, 255, 255, 6));
			c[ColX.TextLink] = V(AccentBlue);
			c[ColX.TextSelectedBg] = V(Gui.Color(0, 112, 224, 110));
			c[ColX.TreeLines] = V(Dropdown);
			c[ColX.DragDropTarget] = V(AccentYellow);
			c[ColX.NavCursor] = V(Primary);
			c[ColX.ModalWindowDimBg] = V(Gui.Color(0, 0, 0, 120));

			Gui.ImGuiStyle_ScaleAllSizes(s, scale);
			s.FontSizeBase = FontSize;
			s._NextFrameFontSizeBase = FontSize; // 1.92: FontSizeBase is re-read from here at NewFrame
			s.FontScaleMain = 1;
			s.FontScaleDpi = scale;
		}
	}
}
