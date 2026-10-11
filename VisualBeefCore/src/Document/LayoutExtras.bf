using System;
using System.Collections;

namespace VisualBeef.Document
{
	/// A UE-style comment box on a function graph. Layout only: comment boxes are never written
	/// to the Beef source; they live in the `.vblayout` side file next to node positions.
	class GraphComment
	{
		static int32 sNextId = 1;

		/// Runtime identity (for selection); not saved.
		public int32 Id = sNextId++;
		public String MethodKey = new .() ~ delete _;
		public float X;
		public float Y;
		public float W = 400;
		public float H = 200;
		/// ImGui packed colour (0xAABBGGRR).
		public uint32 Color = 0xB4FFFFFF;
		public String Text = new .() ~ delete _;
		/// Keeps a readable on-screen size when zoomed out (saved as a ninth field of the line).
		public bool Pinned;

		public GraphComment Clone()
		{
			GraphComment c = new .();
			c.Id = Id;
			c.MethodKey.Set(MethodKey);
			c.X = X;
			c.Y = Y;
			c.W = W;
			c.H = H;
			c.Color = Color;
			c.Text.Set(Text);
			c.Pinned = Pinned;
			return c;
		}
	}

	/// A node's comment bubble pinned to a readable on-screen size (`#bubble` line of the layout file:
	/// method key, node key). Layout only.
	class BubblePin
	{
		public String MethodKey = new .() ~ delete _;
		public String NodeKey = new .() ~ delete _;
	}

	/// A saved canvas view 1-9 of a method (`#view` line of the layout file: method key, number, x, y,
	/// zoom). X / Y is the grid point in the middle of the canvas. Layout only.
	class SavedView
	{
		public String MethodKey = new .() ~ delete _;
		public int N;
		public float X;
		public float Y;
		public float Zoom = 1;
	}

	/// Reroute knots (UE "reroute nodes") on one link. Layout only: a link's code is the same
	/// with or without them. Saved by the structural keys of the link's end nodes and the pin
	/// names; while the editor runs, the pin ids (stable across commits) are used instead.
	class GraphReroute
	{
		public String MethodKey = new .() ~ delete _;
		public String FromNode = new .() ~ delete _;
		public String FromPin = new .() ~ delete _;
		public String ToNode = new .() ~ delete _;
		public String ToPin = new .() ~ delete _;
		/// Knots in order from the output pin to the input pin (grid units).
		public List<NodePos> Points = new .() ~ delete _;
		/// Runtime: the link's pins once resolved (0 = not resolved yet).
		public int32 FromPinId;
		public int32 ToPinId;
		/// Runtime: Graph.Serial the pin ids belong to (a rebuilt or restored graph re-resolves by key).
		public int32 GraphSerial;

		public GraphReroute Clone()
		{
			GraphReroute r = new .();
			r.MethodKey.Set(MethodKey);
			r.FromNode.Set(FromNode);
			r.FromPin.Set(FromPin);
			r.ToNode.Set(ToNode);
			r.ToPin.Set(ToPin);
			r.Points.AddRange(Points);
			r.FromPinId = FromPinId;
			r.ToPinId = ToPinId;
			r.GraphSerial = GraphSerial;
			return r;
		}
	}

	/// Helpers for the tab-separated `.vblayout` lines.
	static class LayoutText
	{
		/// Escapes tabs, newlines and backslashes so text fits in one field. Carriage returns are
		/// dropped unless `keepCR` (then written as `\r`).
		public static void Escape(StringView text, String outText, bool keepCR = false)
		{
			for (let c in text.RawChars)
			{
				switch (c)
				{
				case '\\': outText.Append("\\\\");
				case '\t': outText.Append("\\t");
				case '\n': outText.Append("\\n");
				case '\r':
					if (keepCR)
						outText.Append("\\r");
				default: outText.Append(c);
				}
			}
		}

		public static void Unescape(StringView text, String outText)
		{
			for (int i = 0; i < text.Length; i++)
			{
				let c = text[i];
				if (c == '\\' && i + 1 < text.Length)
				{
					let n = text[++i];
					switch (n)
					{
					case 't': outText.Append('\t');
					case 'n': outText.Append('\n');
					case 'r': outText.Append('\r');
					default: outText.Append(n);
					}
				}
				else if (c != '\r')
					outText.Append(c);
			}
		}

		/// "RRGGBBAA" from an ImGui packed colour.
		public static void ColorToHex(uint32 col, String outText)
		{
			outText.AppendF("{0:X2}{1:X2}{2:X2}{3:X2}", col & 0xFF, (col >> 8) & 0xFF, (col >> 16) & 0xFF, (col >> 24) & 0xFF);
		}

		public static bool HexToColor(StringView hex, out uint32 col)
		{
			col = 0;
			var hex;
			hex.Trim();
			if (hex.Length != 8)
				return false;
			uint32 v = 0;
			for (let c in hex.RawChars)
			{
				uint32 d;
				if (c >= '0' && c <= '9') d = (uint32)(c - '0');
				else if (c >= 'a' && c <= 'f') d = (uint32)(c - 'a' + 10);
				else if (c >= 'A' && c <= 'F') d = (uint32)(c - 'A' + 10);
				else return false;
				v = (v << 4) | d;
			}
			// v = RRGGBBAA
			uint32 r = (v >> 24) & 0xFF;
			uint32 g = (v >> 16) & 0xFF;
			uint32 b = (v >> 8) & 0xFF;
			uint32 a = v & 0xFF;
			col = (a << 24) | (b << 16) | (g << 8) | r;
			return true;
		}
	}
}
