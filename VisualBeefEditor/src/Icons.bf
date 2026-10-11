using System;
using System.IO;
using System.Collections;
using ImGui;

namespace VisualBeef.Editor
{
	/// Icon font: a subset of Lucide (ISC licence, see assets/fonts/LICENSE-lucide.txt) merged
	/// into the UI font, so icons can be used inside any label: `scope $"{Icon.Save} Save"`.
	/// Codepoints are Lucide 0.460.0's (private-use area U+E000-U+E700).
	static class Icon
	{
		public const String File = "\u{E0C4}";
		public const String Folder = "\u{E0DC}";
		public const String FolderOpen = "\u{E247}";
		public const String Save = "\u{E151}";
		public const String SaveAll = "\u{E414}";
		public const String Hammer = "\u{E0EF}";
		public const String CircleCheck = "\u{E226}";
		public const String TriangleAlert = "\u{E193}";
		public const String CircleX = "\u{E088}";
		public const String LoaderCircle = "\u{E10E}";
		public const String RefreshCw = "\u{E149}";
		public const String Search = "\u{E155}";
		public const String Binoculars = "\u{E626}";
		public const String Settings = "\u{E158}";
		public const String Play = "\u{E140}";
		public const String SquareFunction = "\u{E22D}";
		public const String Variable = "\u{E478}";
		public const String Box = "\u{E065}";
		public const String Boxes = "\u{E2D0}";
		public const String Braces = "\u{E36E}";
		public const String ListOrdered = "\u{E1D1}";
		public const String Puzzle = "\u{E29C}";
		public const String Code = "\u{E097}";
		public const String FileCode = "\u{E0C7}";
		public const String LayoutGrid = "\u{E105}";
		public const String Map = "\u{E114}";
		public const String AlignStartVertical = "\u{E271}";
		public const String AlignEndVertical = "\u{E26F}";
		public const String AlignStartHorizontal = "\u{E270}";
		public const String AlignEndHorizontal = "\u{E26E}";
		public const String AlignCenterVertical = "\u{E26D}";
		public const String AlignCenterHorizontal = "\u{E26C}";
		public const String AlignHorizontalDistributeCenter = "\u{E03D}";
		public const String AlignVerticalDistributeCenter = "\u{E27E}";
		public const String Workflow = "\u{E42A}";
		public const String Network = "\u{E129}";
		public const String Plus = "\u{E141}";
		public const String Minus = "\u{E120}";
		public const String X = "\u{E1B2}";
		public const String ChevronRight = "\u{E073}";
		public const String ChevronDown = "\u{E071}";
		public const String ChevronLeft = "\u{E072}";
		public const String ChevronUp = "\u{E074}";
		public const String ArrowLeft = "\u{E04C}";
		public const String ArrowRight = "\u{E04D}";
		public const String ArrowUp = "\u{E04E}";
		public const String Info = "\u{E0FE}";
		public const String Bell = "\u{E05D}";
		public const String Terminal = "\u{E185}";
		public const String MessageSquare = "\u{E11B}";
		public const String GitBranch = "\u{E0E5}";
		public const String Repeat = "\u{E14A}";
		public const String CornerDownLeft = "\u{E0A5}";
		public const String Eye = "\u{E0BE}";
		public const String EyeOff = "\u{E0BF}";
		public const String Filter = "\u{E0D5}";
		public const String Copy = "\u{E0A2}";
		public const String Trash2 = "\u{E18E}";
		public const String Pencil = "\u{E1F9}";
		public const String Star = "\u{E17A}";
		public const String House = "\u{E0F8}";
		public const String Maximize2 = "\u{E117}";
		public const String Minimize = "\u{E11E}";
		public const String Square = "\u{E16B}";
		public const String Sun = "\u{E17C}";
		public const String Moon = "\u{E122}";
		public const String Type = "\u{E198}";
		public const String Hash = "\u{E0F2}";
		public const String ToggleLeft = "\u{E18B}";
		public const String Sigma = "\u{E201}";
		public const String Circle = "\u{E07A}";
		public const String CircleDot = "\u{E349}";
		public const String Grid2x2 = "\u{E504}";
		public const String Grid3x3 = "\u{E0EC}";
		public const String List = "\u{E10C}";
		public const String BookOpen = "\u{E063}";
		public const String Keyboard = "\u{E284}";
		public const String Monitor = "\u{E121}";
		public const String ZoomIn = "\u{E1B6}";
		public const String Undo2 = "\u{E2A1}";
		public const String Redo2 = "\u{E2A0}";
		public const String Scissors = "\u{E152}";
		public const String Clipboard = "\u{E089}";
		public const String ExternalLink = "\u{E0BD}";
		public const String FilePlus = "\u{E0CD}";
		public const String FolderPlus = "\u{E0DE}";
		public const String Package = "\u{E12D}";
		public const String CircleHelp = "\u{E082}";
		public const String LogOut = "\u{E112}";
		public const String PanelBottom = "\u{E431}";
		public const String Pin = "\u{E259}";
		public const String SquareTerminal = "\u{E20A}";
		public const String ScrollText = "\u{E464}";
		public const String SlidersHorizontal = "\u{E29A}";
		public const String Palette = "\u{E1DD}";
		public const String Magnet = "\u{E2B5}";
		public const String Locate = "\u{E1DA}";
		public const String Move = "\u{E125}";
		public const String Cog = "\u{E30B}";
		public const String Wrench = "\u{E1B1}";
		public const String Bug = "\u{E20C}";
		public const String Pause = "\u{E132}";
		public const String RedoDot = "\u{E455}";
		public const String ArrowDownToLine = "\u{E45A}";
		public const String ArrowUpFromLine = "\u{E45F}";
		public const String Plug = "\u{E383}";
		public const String FileText = "\u{E0D0}";
		public const String FolderTree = "\u{E340}";
		public const String Layers = "\u{E104}";
		public const String Shapes = "\u{E4B8}";
		public const String ListTree = "\u{E40D}";
		public const String Component = "\u{E2AD}";
		public const String Blocks = "\u{E4FF}";
		public const String TextCursorInput = "\u{E265}";
		public const String ArrowDownUp = "\u{E04A}";
		public const String StretchHorizontal = "\u{E27C}";
		public const String SquareMinus = "\u{E175}";
		public const String CopyPlus = "\u{E402}";
		public const String Maximize = "\u{E116}";
		public const String Minimize2 = "\u{E11F}";
		public const String AppWindow = "\u{E42B}";
		public const String Ellipsis = "\u{E0BA}";
		public const String EllipsisVertical = "\u{E0BB}";
		public const String CirclePlus = "\u{E086}";
		public const String Link = "\u{E108}";
		public const String Unlink = "\u{E19C}";
		public const String Equal = "\u{E1BD}";
		public const String Clock = "\u{E08B}";
		public const String History = "\u{E1F5}";
		public const String FolderInput = "\u{E338}";
		public const String FolderOutput = "\u{E33B}";
		public const String ArrowRightLeft = "\u{E41C}";
		public const String Diamond = "\u{E2D2}";
		public const String Ruler = "\u{E14F}";
		public const String GripVertical = "\u{E0EE}";
		public const String RotateCcw = "\u{E14C}";
		public const String Lock = "\u{E10F}";
		public const String FolderLock = "\u{E33A}";

		// ---- Shell aliases (what the editor uses them for)
		public const String Compile = Hammer;
		public const String Class = Box;
		public const String Struct = Boxes;
		public const String Enum = ListOrdered;
		public const String Interface = Puzzle;
		public const String Function = SquareFunction;
		public const String Find = Binoculars;
		public const String Browse = FolderOpen;
		public const String Log = SquareTerminal;
		public const String Comment = MessageSquare;
		public const String Warning = TriangleAlert;
		public const String Error = CircleX;
		public const String Ok = CircleCheck;
		public const String Unknown = CircleHelp;
		public const String Minimap = Map;
		public const String Arrange = Workflow;

		public static bool Loaded;
		static uint16[3] sRanges = .(0xE000, 0xE700, 0);
		static uint8[] sFontData ~ delete _;

		/// Finds assets/fonts/lucide.ttf next to the executable (copied there by the build), or
		/// in the source tree when running from a fresh checkout.
		static bool FindFont(String outPath)
		{
			String exe = scope .();
			Environment.GetExecutableFilePath(exe);
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir).IgnoreError(); // no parent: dir stays empty and the walk below is skipped
			for (int depth = 0; depth < 6 && !dir.IsEmpty; depth++)
			{
				for (let rel in StringView[2]("assets/fonts/lucide.ttf", "VisualBeefEditor/assets/fonts/lucide.ttf"))
				{
					outPath.Clear();
					outPath.AppendF("{}/{}", dir, rel);
					if (System.IO.File.Exists(outPath))
						return true;
				}
				String parent = scope .();
				// At a root there is no parent (.Err); stop walking.
				if (Path.GetDirectoryPath(dir, parent) case .Err || parent == dir)
					break;
				dir.Set(parent);
			}
			return false;
		}

		/// Merges the icon glyphs into `uiFont` (and `monoFont` when given). Call between frames.
		public static void Load(ImFont* uiFont, ImFont* monoFont, float glyphSize)
		{
			if (Loaded || uiFont == null)
				return;
			String path = scope .();
			if (!FindFont(path))
			{
				Notify.Warn("Icon font not found (assets/fonts/lucide.ttf): menus and toolbars show text only.");
				return;
			}
			List<uint8> bytes = scope .();
			if (System.IO.File.ReadAll(path, bytes) case .Err)
				return;
			sFontData = new uint8[bytes.Count];
			bytes.CopyTo(sFontData);
			let io = Gui.igGetIO_Nil();
			for (int i < 2)
			{
				ImFont* dst = (i == 0) ? uiFont : monoFont;
				if (dst == null)
					continue;
				let cfg = Gui.ImFontConfig_ImFontConfig();
				cfg.MergeMode = true;
				cfg.DstFont = dst;
				cfg.FontDataOwnedByAtlas = false;
				cfg.PixelSnapH = true;
				cfg.GlyphMinAdvanceX = glyphSize;
				cfg.GlyphOffset = .(0, glyphSize * 0.12f);
				cfg.GlyphRanges = &sRanges;
				let name = "Lucide";
				Internal.MemCpy(&cfg.Name, name.Ptr, name.Length);
				Gui.ImFontAtlas_AddFontFromMemoryTTF(io.Fonts, sFontData.Ptr, (int32)sFontData.Count, glyphSize, cfg, &sRanges);
				Gui.ImFontConfig_destroy(cfg);
			}
			Loaded = true;
		}

		/// "<icon>  label" when the font is loaded, else just the label.
		public static void Label(String outText, StringView icon, StringView label)
		{
			if (Loaded && !icon.IsEmpty)
				outText.AppendF("{}  {}", icon, label);
			else
				outText.Append(label);
		}
	}
}
