using System;
using ImGui;
using VisualBeef.Graph;

namespace VisualBeef.Editor
{
	/// How pins and node headers look, in one place. The node catalog / type system can swap the
	/// colour mapping here (PinStyle.Color, PinStyle.Header) without touching the canvas code.
	static class PinStyle
	{
		public enum Shape
		{
			Exec,
			Single,
			/// T[], List<T>, Span<T>: UE's 3x3 grid pin.
			Array,
			/// Dictionary<K, V>: UE's map pin (two squares).
			Map,
			/// HashSet<T>: UE's set pin (braces).
			Set
		}

		public static uint32 Color(Pin p) => Theme.PinColor(p);

		public static Shape ShapeFor(Pin p)
		{
			if (p.Kind == .Exec)
				return .Exec;
			StringView t = p.TypeName;
			t.Trim();
			if (t.EndsWith("[]") || t.StartsWith("List<") || t.StartsWith("Span<") || t.StartsWith("Array<"))
				return .Array;
			if (t.StartsWith("Dictionary<"))
				return .Map;
			if (t.StartsWith("HashSet<"))
				return .Set;
			return .Single;
		}

		/// Header colour by node kind (UE: function call blue, pure green, flow grey, entry
		/// purple-red, return purple, code orange).
		public static uint32 Header(Node node) => Theme.HeaderColor(node);

		/// The small icon UE draws at the left of a node's title.
		public static StringView HeaderIcon(Node node)
		{
			switch (node.Kind)
			{
			case .Entry: return Icon.SquareFunction;
			case .Call: return Icon.SquareFunction;
			case .Branch: return Icon.GitBranch;
			case .Switch: return Icon.Workflow;
			case .Flow: return Icon.Blocks;
			case .While, .DoWhile, .For, .ForEach: return Icon.Repeat;
			case .Return: return Icon.CornerDownLeft;
			case .Break, .Continue: return Icon.ArrowRight;
			case .Set, .LocalVar: return Icon.Variable;
			case .Code, .Expr: return Icon.Braces;
			case .Cast: return Icon.ArrowRightLeft;
			case .Construct: return Icon.Box;
			case .Delete: return Icon.Trash2;
			case .Defer: return Icon.Undo2;
			case .Using: return Icon.Square;
			case .ResultMatch: return Icon.GitBranch;
			case .Scope: return Icon.Braces;
			case .Lambda, .LocalFunc: return Icon.SquareFunction;
			case .Format: return Icon.Type;
			case .MathExpr: return Icon.Sigma;
			default: return "";
			}
		}

		/// Draws a data pin of the given shape: ring / disc for single values, a grid for arrays,
		/// two squares for maps, braces for sets (filled when linked).
		public static void DrawData(ImDrawList* dl, Shape shape, ImVec2 c, float r, uint32 col, bool linked, float arrowX, float thickness)
		{
			switch (shape)
			{
			case .Array:
				float cell = r * 0.62f;
				for (int iy < 3)
					for (int ix < 3)
					{
						let p = ImVec2(c.x + (ix - 1) * cell * 1.15f, c.y + (iy - 1) * cell * 1.15f);
						bool hollow = !linked && ix == 1 && iy == 1;
						if (hollow)
							Gui.ImDrawList_AddRect(dl, p - .(cell * 0.45f, cell * 0.45f), p + .(cell * 0.45f, cell * 0.45f), col, 0, Math.Max(1, thickness * 0.6f), 0);
						else
							Gui.ImDrawList_AddRectFilled(dl, p - .(cell * 0.45f, cell * 0.45f), p + .(cell * 0.45f, cell * 0.45f), col, 0, 0);
					}
			case .Map:
				float s = r * 0.62f;
				let a = ImVec2(c.x - s * 0.7f, c.y - s * 0.7f);
				let b = ImVec2(c.x + s * 0.7f, c.y + s * 0.7f);
				Gui.ImDrawList_AddRectFilled(dl, a - .(s * 0.6f, s * 0.6f), a + .(s * 0.6f, s * 0.6f), col, 1, 0);
				if (linked)
					Gui.ImDrawList_AddRectFilled(dl, b - .(s * 0.6f, s * 0.6f), b + .(s * 0.6f, s * 0.6f), col, 1, 0);
				else
					Gui.ImDrawList_AddRect(dl, b - .(s * 0.6f, s * 0.6f), b + .(s * 0.6f, s * 0.6f), col, 1, thickness, 0);
			case .Set:
				Gui.DrawText(dl, .(c.x - r * 1.1f, c.y - r * 1.25f), col, "{}", r * 2.5f);
			default:
				Canvas.DataPin(dl, c, r, col, linked, arrowX, thickness);
			}
		}
	}
}
