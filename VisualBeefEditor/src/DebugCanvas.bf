using System;
using System.Collections;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Editor
{
	/// The debugger on the canvas (docs/Debugging.md): a breakpoint circle on each node's top-left
	/// corner (red dot when set; a faint ring under the mouse to set one), the node the program
	/// stopped at (yellow outline and an arrow), the values of the stopped node's pins next to
	/// them, and the value of any pin under the mouse while stopped.
	extension GraphPanel
	{
		HashSet<int32> mBpNodes = new .() ~ delete _;

		const uint32 cBreakpointRed = 0xFF3838E0; // ABGR: (224, 56, 56)
		const uint32 cStopYellow = 0xFF28C8FF;    // (255, 200, 40)

		void DrawDebugOverlay(GraphTab tab, MethodGraph mg, ImDrawList* dl)
		{
			let graph = mg.Graph;
			float z = tab.Zoom;
			float ui = Look.Scale;
			mBpNodes.Clear();
			mApp.BreakpointNodes(mg, mBpNodes);
			bool stopped = mApp.IsDebugStopped;
			bool stopHere = stopped && mApp.DebugStopGraph == graph;
			let mouse = Gui.igGetMousePos();
			for (let L in mOrder)
			{
				if (!L.Visible)
					continue;
				let node = L.Node;
				let p0 = tab.GridToScreen(node.X, node.Y);
				let p1 = p0 + ImVec2(L.W, L.H) * z;

				if (stopHere && node.Id == mApp.DebugStopNode)
				{
					float o = 4 * z * ui;
					float r = ((L.Shape == .Getter) ? L.H * 0.5f : 6) * z;
					Gui.ImDrawList_AddRect(dl, p0 - .(o, o), p1 + .(o, o), cStopYellow, r + o, Math.Max(2, 3 * z), 0);
					// The arrow left of the node, at the header.
					float hy = p0.y + Math.Max(L.HeaderH * 0.5f, 10) * z;
					float ax = p0.x - 8 * z * ui;
					float s = Math.Max(6 * ui, 9 * z * ui);
					Gui.ImDrawList_AddTriangleFilled(dl, .(ax - s * 1.6f, hy - s), .(ax - s * 1.6f, hy + s), .(ax, hy), cStopYellow);
					if (z >= 0.45f)
						DrawStopValues(tab, mg, L, dl);
				}

				// Breakpoint circle on the top-left corner.
				bool hasBp = mBpNodes.Contains(node.Id);
				float rad = Math.Max(5 * ui, 7 * z * ui);
				let c = p0 + ImVec2(rad * 0.4f, rad * 0.4f);
				let d = mouse - c;
				bool near = (d.x * d.x + d.y * d.y) < (rad * 2.2f) * (rad * 2.2f);
				bool show = hasBp || ((mHoverNode == node.Id || near) && tab.Mode == .None);
				if (!show)
					continue;
				Gui.igSetCursorScreenPos(c - .(rad, rad));
				Gui.PushID(node.Id);
				Gui.igInvisibleButton("##bp", .(rad * 2, rad * 2), ButtonFlags.MouseButtonLeft);
				bool clicked = Gui.igIsItemClicked(0);
				bool hovered = Gui.igIsItemHovered(0);
				Gui.PopID();
				if (hasBp)
				{
					Gui.ImDrawList_AddCircleFilled(dl, c, rad, cBreakpointRed, 0);
					Gui.ImDrawList_AddCircle(dl, c, rad, Gui.Color(20, 20, 20, 220), 0, Math.Max(1, z));
				}
				else
					Gui.ImDrawList_AddCircle(dl, c, rad, hovered ? Theme.WithAlpha(cBreakpointRed, 230) : Gui.Color(150, 150, 150, 120), 0, Math.Max(1, 1.5f * z));
				if (hovered)
				{
					String why = scope .();
					if (hasBp)
						Gui.Tooltip("Breakpoint: the program stops here (click or F9 to remove)");
					else if (VisualBeef.Debug.DebugMap.LineOf(graph, node, why) > 0)
						Gui.Tooltip("Set a breakpoint: the program stops before this node runs (F9)");
					else
						Gui.Tooltip(scope $"No breakpoint here: {why}");
				}
				if (clicked)
					mApp.ToggleBreakpoint(mg, node);
			}

			// The value of the pin under the mouse (added to its tooltip).
			if (stopped && tab.Mode == .None && mHoverPin != 0)
			{
				let p = graph.FindPin(mHoverPin);
				if (p != null && p.Kind == .Data)
				{
					String v = scope .();
					if (mApp.DebugPinValue(mg, p, v))
						Gui.Tooltip(scope $"Value: {v}");
					else
						Gui.Tooltip(scope $"No value: {v}");
				}
			}
		}

		/// Values of the stopped node's data pins, in small labels beside the pins.
		void DrawStopValues(GraphTab tab, MethodGraph mg, NodeLay L, ImDrawList* dl)
		{
			float z = tab.Zoom;
			float ui = Look.Scale;
			float fs = mFontSize * 0.85f * z;
			let node = L.Node;
			for (int pass < 2)
			{
				let pins = (pass == 0) ? node.Inputs : node.Outputs;
				for (let p in pins)
				{
					if (p.Kind != .Data)
						continue;
					if (!TryGetPin(p.Id, let pl) || !pl.Visible)
						continue;
					String v = scope .();
					if (!mApp.DebugPinValue(mg, p, v))
						continue;
					if (v.Length > 40)
					{
						v.RemoveToEnd(37);
						v.Append("...");
					}
					let c = PinScreen(tab, pl);
					float tw = Gui.CalcTextSize(v).x * (fs / mFontSize);
					float padX = 4 * z * ui;
					float h = fs + 4 * z;
					ImVec2 a;
					if (p.IsInput)
						a = .(c.x - 12 * z * ui - tw - padX * 2, c.y - h * 0.5f);
					else
						a = .(c.x + 12 * z * ui, c.y - h * 0.5f);
					let b = a + ImVec2(tw + padX * 2, h);
					Gui.ImDrawList_AddRectFilled(dl, a, b, Gui.Color(40, 34, 10, 235), 3 * z, 0);
					Gui.ImDrawList_AddRect(dl, a, b, Theme.WithAlpha(cStopYellow, 200), 3 * z, 1, 0);
					Text(dl, .(a.x + padX, a.y + 2 * z), fs, Gui.Color(255, 230, 150), v);
				}
			}
		}
	}
}
