using System;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// Unreal-Blueprint-inspired colors.
	static class Theme
	{
		public static uint32 ExecPin = Gui.Color(240, 240, 240);
		public static uint32 BoolPin = Gui.Color(146, 0, 0);
		public static uint32 IntPin = Gui.Color(31, 227, 175);
		public static uint32 FloatPin = Gui.Color(160, 250, 68);
		public static uint32 StringPin = Gui.Color(251, 0, 209);
		public static uint32 CharPin = Gui.Color(206, 120, 255);
		public static uint32 VectorPin = Gui.Color(253, 200, 35);
		public static uint32 ObjectPin = Gui.Color(0, 168, 242);
		public static uint32 EnumPin = Gui.Color(0, 109, 99);
		public static uint32 WildPin = Gui.Color(170, 170, 170);

		public static uint32 HeaderCall = Gui.Color(50, 90, 150);
		public static uint32 HeaderPure = Gui.Color(78, 117, 38);
		public static uint32 HeaderFlow = Gui.Color(90, 90, 90);
		/// UE's function-entry / event header: purple-red.
		public static uint32 HeaderEntry = Gui.Color(140, 30, 86);
		public static uint32 HeaderVar = Gui.Color(40, 110, 120);
		public static uint32 HeaderCode = Gui.Color(130, 80, 30);
		/// UE's Return: purple.
		public static uint32 HeaderReturn = Gui.Color(104, 52, 150);

		public static uint32 TextDim = Gui.Color(150, 150, 150);
		public static uint32 TextCode = Gui.Color(214, 197, 150);
		public static uint32 Warning = Gui.Color(255, 196, 0);
		public static uint32 Good = Gui.Color(110, 210, 90);

		// ---- Node-graph canvas (UE5 Blueprint look) -------------------------------------------
		public static uint32 CanvasBg = Gui.Color(38, 38, 38);
		public static uint32 GridMinor = Gui.Color(52, 52, 52);
		public static uint32 GridMajor = Gui.Color(20, 20, 20);
		public static uint32 NodeBody = Gui.Color(15, 15, 15, 230);
		public static uint32 NodeShadow = Gui.Color(0, 0, 0, 90);
		public static uint32 NodeOutline = Gui.Color(0, 0, 0, 200);
		public static uint32 NodeSelected = Gui.Color(255, 170, 0);
		public static uint32 NodeError = Gui.Color(255, 50, 50);
		public static uint32 ErrorHeader = Gui.Color(170, 30, 30);
		public static uint32 NodeTitle = Gui.Color(255, 255, 255);
		public static uint32 NodeSubtitle = Gui.Color(160, 160, 160);
		public static uint32 PinLabel = Gui.Color(205, 205, 205);
		public static uint32 WireExec = Gui.Color(235, 235, 235);
		public static uint32 WireBad = Gui.Color(255, 60, 60);
		public static uint32 MarqueeFill = Gui.Color(255, 170, 0, 30);
		public static uint32 MarqueeBorder = Gui.Color(255, 170, 0, 200);
		public static uint32 InlineFieldBg = Gui.Color(10, 10, 10, 220);

		/// Same color with a different alpha.
		public static uint32 WithAlpha(uint32 c, uint8 a) => (c & 0x00FFFFFF) | ((uint32)a << 24);

		/// Mixes `c` towards `to` by `t` (0..1), alpha included.
		public static uint32 Mix(uint32 c, uint32 to, float t)
		{
			uint32 result = 0;
			for (int32 shift = 0; shift < 32; shift += 8)
			{
				float a = (c >> shift) & 0xFF;
				float b = (to >> shift) & 0xFF;
				uint32 v = (uint32)Math.Clamp((int)(a + (b - a) * t + 0.5f), 0, 255);
				result |= v << shift;
			}
			return result;
		}

		public static uint32 Lighten(uint32 c, float f)
		{
			uint32 r = c & 0xFF;
			uint32 g = (c >> 8) & 0xFF;
			uint32 b = (c >> 16) & 0xFF;
			uint32 a = (c >> 24) & 0xFF;
			r = (uint32)Math.Min(255, (int)(r * f));
			g = (uint32)Math.Min(255, (int)(g * f));
			b = (uint32)Math.Min(255, (int)(b * f));
			return (a << 24) | (b << 16) | (g << 8) | r;
		}

		public static uint32 PinColor(Pin pin)
		{
			if (pin.Kind == .Exec)
				return ExecPin;
			return TypeColor(pin.TypeName);
		}

		/// Pin / variable colour for a type: the catalog's single mapping (TypeRules, see
		/// docs/Catalog-and-Types.md), which uses the project index when one is installed.
		public static uint32 TypeColor(StringView typeName) => TypeRules.PinColor(typeName);

		/// Header of variable nodes (SET, Local): the variable's type colour, darkened.
		public static uint32 VariableHeader(StringView typeName)
		{
			var t = typeName;
			t.Trim();
			if (t.IsEmpty || t == "var" || t == "let")
				return HeaderVar;
			return Mix(TypeColor(t), Gui.Color(0, 0, 0, 255), 0.45f);
		}

		public static uint32 HeaderColor(Node node)
		{
			if (node.Error != null)
				return ErrorHeader;
			switch (node.Kind)
			{
			case .Entry: return HeaderEntry;
			case .Return: return HeaderReturn;
			case .Call: return node.IsPure ? HeaderPure : HeaderCall;
			case .Branch, .While, .DoWhile, .For, .ForEach, .Break, .Continue, .Switch, .Flow, .Defer, .Using, .ResultMatch, .Scope: return HeaderFlow;
			case .LocalFunc: return HeaderCall;
			case .Delete: return HeaderCall;
			case .Set, .LocalVar: return HeaderVar;
			case .Code, .Expr: return HeaderCode;
			case .Cast: return Gui.Color(30, 110, 140);
			default: return HeaderPure;
			}
		}
	}
}
