using System;
using ImGui;

namespace VisualBeef.Editor
{
	/// Drawing primitives and maths for the node-graph canvas (UE5 Blueprint look).
	/// Everything here works in screen pixels; callers convert from grid units with the zoom.
	static class Canvas
	{
		/// Unreal's graph zoom steps. Index `DefaultZoomLevel` is 1:1.
		public static float[20] ZoomLevels = .(0.1f, 0.125f, 0.15f, 0.175f, 0.2f, 0.225f, 0.25f, 0.375f, 0.5f, 0.675f,
			0.75f, 0.875f, 1.0f, 1.25f, 1.375f, 1.5f, 1.675f, 1.75f, 1.875f, 2.0f);
		public const int32 DefaultZoomLevel = 12;
		public const float MinorGrid = 16;
		public const float MajorGrid = 128;
		public const float SnapGrid = 16;

		/// "Zoom 1:1", "Zoom -3", "Zoom +2" like UE.
		public static void ZoomLabel(int32 level, String outText)
		{
			int32 d = level - DefaultZoomLevel;
			if (d == 0)
				outText.Append("Zoom 1:1");
			else if (d > 0)
				outText.AppendF("Zoom +{}", d);
			else
				outText.AppendF("Zoom {}", d);
		}

		/// The largest zoom level not above `zoom`.
		public static int32 LevelAtOrBelow(float zoom)
		{
			int32 best = 0;
			for (int32 i < ZoomLevels.Count)
				if (ZoomLevels[i] <= zoom + 0.0001f)
					best = i;
			return best;
		}

		public static float Snap(float v) => (float)Math.Round(v / SnapGrid) * SnapGrid;
		/// Snaps when "Snap to Grid" is on (Editor Preferences / toolbar).
		public static float SnapIf(float v) => Prefs.GridSnap ? Snap(v) : v;

		public static void Background(ImDrawList* dl, ImVec2 origin, ImVec2 size, ImVec2 pan, float zoom)
		{
			let max = origin + size;
			Gui.ImDrawList_AddRectFilled(dl, origin, max, Theme.CanvasBg, 0, 0);

			// Minor lines fade out as they get too dense, like UE when zoomed far out.
			float minorPx = MinorGrid * zoom;
			float minorAlpha = Math.Clamp((minorPx - 4.0f) / 8.0f, 0, 1);
			if (minorAlpha > 0)
				GridLines(dl, origin, size, pan, zoom, MinorGrid, Theme.WithAlpha(Theme.GridMinor, (uint8)(255 * minorAlpha)), MajorGrid);
			float majorPx = MajorGrid * zoom;
			float majorAlpha = Math.Clamp((majorPx - 6.0f) / 20.0f, 0, 1);
			if (majorAlpha > 0)
				GridLines(dl, origin, size, pan, zoom, MajorGrid, Theme.WithAlpha(Theme.GridMajor, (uint8)(255 * majorAlpha)), 0);
		}

		/// Grid lines every `step` grid units, skipping multiples of `skipEvery` (drawn by another pass).
		static void GridLines(ImDrawList* dl, ImVec2 origin, ImVec2 size, ImVec2 pan, float zoom, float step, uint32 col, float skipEvery)
		{
			let max = origin + size;
			// First grid line at or left of the visible area: grid x = -pan.x
			float gx0 = (float)Math.Floor(-pan.x / step) * step;
			float gy0 = (float)Math.Floor(-pan.y / step) * step;
			for (float gx = gx0; ; gx += step)
			{
				float sx = origin.x + (gx + pan.x) * zoom;
				if (sx > max.x)
					break;
				if (skipEvery > 0 && Math.Abs(gx - (float)Math.Round(gx / skipEvery) * skipEvery) < 0.01f)
					continue;
				if (sx >= origin.x)
					Gui.ImDrawList_AddLine(dl, .(sx, origin.y), .(sx, max.y), col, 1);
			}
			for (float gy = gy0; ; gy += step)
			{
				float sy = origin.y + (gy + pan.y) * zoom;
				if (sy > max.y)
					break;
				if (skipEvery > 0 && Math.Abs(gy - (float)Math.Round(gy / skipEvery) * skipEvery) < 0.01f)
					continue;
				if (sy >= origin.y)
					Gui.ImDrawList_AddLine(dl, .(origin.x, sy), .(max.x, sy), col, 1);
			}
		}

		/// UE's exec pin: a pentagon "arrow house" pointing right. `s` is the half size.
		public static void ExecPin(ImDrawList* dl, ImVec2 c, float s, uint32 col, bool filled, float thickness)
		{
			ImVec2[5] pts = .(
				.(c.x - s * 0.9f, c.y - s),
				.(c.x + s * 0.15f, c.y - s),
				.(c.x + s, c.y),
				.(c.x + s * 0.15f, c.y + s),
				.(c.x - s * 0.9f, c.y + s));
			if (filled)
				Gui.ImDrawList_AddConvexPolyFilled(dl, &pts[0], 5, col);
			else
				Gui.ImDrawList_AddPolyline(dl, &pts[0], 5, col, thickness, DrawFlags.Closed);
		}

		/// UE's data pin: ring when unlinked, filled disc when linked, with a small arrow.
		/// `arrowX` is the x of the arrow's centre (left of inputs, right of outputs).
		public static void DataPin(ImDrawList* dl, ImVec2 c, float r, uint32 col, bool filled, float arrowX, float thickness)
		{
			if (filled)
				Gui.ImDrawList_AddCircleFilled(dl, c, r, col, 0);
			else
				Gui.ImDrawList_AddCircle(dl, c, r - thickness * 0.5f, col, 0, thickness);
			float a = r * 0.55f;
			Gui.ImDrawList_AddTriangleFilled(dl, .(arrowX - a * 0.6f, c.y - a), .(arrowX + a * 0.6f, c.y), .(arrowX - a * 0.6f, c.y + a), col);
		}

		/// Control points of a UE-style wire. Mirrors Unreal's ComputeSplineTangent defaults
		/// (forward: 1x dx + 1x dy clamped to 1000; backward: 3x dx + 1.5x dy clamped to 200),
		/// converted from a Hermite tangent to Bezier control points (tangent / 3).
		public static void WireControls(ImVec2 from, ImVec2 to, float zoom, out ImVec2 c1, out ImVec2 c2)
		{
			float dx = to.x - from.x;
			float dy = Math.Abs(to.y - from.y);
			float t;
			if (dx >= 0)
				t = Math.Min(dx, 1000 * zoom) + Math.Min(dy, 1000 * zoom);
			else
				t = Math.Min(-dx, 200 * zoom) * 3 + Math.Min(dy, 200 * zoom) * 1.5f;
			t = Math.Max(t / 3, 4 * zoom);
			c1 = .(from.x + t, from.y);
			c2 = .(to.x - t, to.y);
		}

		public static void Wire(ImDrawList* dl, ImVec2 from, ImVec2 to, float zoom, uint32 col, float thickness)
		{
			WireControls(from, to, zoom, let c1, let c2);
			Gui.ImDrawList_AddBezierCubic(dl, from, c1, c2, to, col, thickness, 0);
		}

		static ImVec2 Bezier(ImVec2 p0, ImVec2 p1, ImVec2 p2, ImVec2 p3, float t)
		{
			float u = 1 - t;
			float w0 = u * u * u;
			float w1 = 3 * u * u * t;
			float w2 = 3 * u * t * t;
			float w3 = t * t * t;
			return .(p0.x * w0 + p1.x * w1 + p2.x * w2 + p3.x * w3, p0.y * w0 + p1.y * w1 + p2.y * w2 + p3.y * w3);
		}

		static float DistToSegment(ImVec2 p, ImVec2 a, ImVec2 b)
		{
			let ab = b - a;
			let ap = p - a;
			float len2 = ab.x * ab.x + ab.y * ab.y;
			float t = (len2 > 0.0001f) ? Math.Clamp((ap.x * ab.x + ap.y * ab.y) / len2, 0, 1) : 0;
			let q = a + ab * t;
			let d = p - q;
			return Math.Sqrt(d.x * d.x + d.y * d.y);
		}

		/// Screen-space distance from `p` to the wire between two pins.
		public static float DistToWire(ImVec2 p, ImVec2 from, ImVec2 to, float zoom)
		{
			// Cheap reject with the curve's bounding box.
			WireControls(from, to, zoom, let c1, let c2);
			float minX = Math.Min(Math.Min(from.x, to.x), Math.Min(c1.x, c2.x)) - 10;
			float maxX = Math.Max(Math.Max(from.x, to.x), Math.Max(c1.x, c2.x)) + 10;
			float minY = Math.Min(from.y, to.y) - 10;
			float maxY = Math.Max(from.y, to.y) + 10;
			if (p.x < minX || p.x > maxX || p.y < minY || p.y > maxY)
				return float.MaxValue;
			float best = float.MaxValue;
			ImVec2 prev = from;
			const int32 Steps = 24;
			for (int32 i = 1; i <= Steps; i++)
			{
				let cur = Bezier(from, c1, c2, to, i / (float)Steps);
				best = Math.Min(best, DistToSegment(p, prev, cur));
				prev = cur;
			}
			return best;
		}

		public static bool RectContains(ImVec2 min, ImVec2 max, ImVec2 p) => p.x >= min.x && p.y >= min.y && p.x < max.x && p.y < max.y;

		public static bool RectsOverlap(ImVec2 aMin, ImVec2 aMax, ImVec2 bMin, ImVec2 bMax) =>
			aMin.x < bMax.x && bMin.x < aMax.x && aMin.y < bMax.y && bMin.y < aMax.y;
	}
}
