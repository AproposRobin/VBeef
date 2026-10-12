using System;
using System.Collections;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// Properties of a Math Expression node (docs/Math-Expression.md): the expression (the same text
	/// as the field on the node), its inputs and what it gives. A text that is not a Beef
	/// expression turns the field red and is not taken; a result type that the expression does not
	/// tell is chosen here, from the types Beef arithmetic gives.
	extension EditorApp
	{
		/// What the Expression row shows while it is typed (refreshed when the node or its text changes).
		String mMathBuf = new .() ~ delete _;
		int32 mMathBufNode;
		String mMathBufSeen = new .() ~ delete _;
		/// Self test: the last expression refused in Properties.
		public String MathPropsRefusal = new .() ~ delete _;

		/// The Node category: what the expression gives (inferred, or chosen when it can't be told)
		/// and what is wrong with the node.
		void DrawMathDetails(MethodGraph mg, Node node, ref bool commit)
		{
			let g = mg.Graph;
			String inferred = scope .();
			let known = MathExpression.Inferred(g, node, inferred);
			StringView shownType = known ? (StringView)inferred : ((node.MathType != null) ? (StringView)node.MathType : "");
			PropertyGrid.Row("Result Type", "What the expression gives. Worked out from the expression and its inputs when Beef's rules make it certain; otherwise choose it.",
				shownType.IsEmpty ? 0 : Theme.TypeColor(shownType));
			if (known)
				PropertyGrid.Value(scope $"{inferred}  (inferred)");
			else
			{
				StringView preview = (node.MathType != null && !node.MathType.IsEmpty) ? (StringView)node.MathType : "(choose)";
				if (Gui.igBeginCombo("##mathtype", scope String(preview), 0))
				{
					for (let choice in MathExpression.ResultTypeChoices)
					{
						bool sel = node.MathType != null && node.MathType == choice;
						if (Gui.Selectable(choice, sel) && !sel)
						{
							BeginEdit();
							Graph.CopyStr(ref node.MathType, choice);
							MathExpression.Sync(g, node);
							node.Edited = true;
							commit = true;
						}
					}
					Gui.igEndCombo();
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("The expression and its inputs do not tell what it gives: choose the type it gives.");
			}
			String problem = scope .();
			MathExpression.Problem(g, node, problem);
			if (!problem.IsEmpty)
			{
				PropertyGrid.WideRow();
				Gui.igSetCursorPosX(Gui.igGetCursorPosX() + 8 * Look.Scale);
				ErrorText(problem);
			}
		}

		/// The Expression category: the expression in a full-width field (the same text as the field
		/// on the node). A text that is not a Beef expression turns the frame red and is not taken.
		void DrawMathExpression(MethodGraph mg, Node node, ref bool commit)
		{
			let g = mg.Graph;
			if (mMathBufNode != node.Id || (mMathBufSeen != node.Text && !Gui.igIsAnyItemActive()))
			{
				mMathBufNode = node.Id;
				mMathBufSeen.Set(node.Text);
				mMathBuf.Set(node.Text);
			}
			PropertyGrid.WideRow();
			Gui.igPushItemWidth(-6 * Look.Scale);
			String text = scope .(mMathBuf);
			bool done = PropertyGrid.Text("##mathx", text, let changed, true, mMono, "a * b + 1");
			Gui.igPopItemWidth();
			if (Gui.igIsItemHovered(0) && !Gui.igIsItemActive())
				Gui.Tooltip("Every name in it becomes an input; the value is the Result. Math functions (Math.Sqrt, Math.Min) and casts can be used.");
			if (changed)
				mMathBuf.Set(text);
			String why = scope .();
			bool ok = MathExpression.Check(mMathBuf, why);
			if (!ok)
			{
				let dl = Gui.igGetWindowDrawList();
				Gui.ImDrawList_AddRect(dl, Gui.igGetItemRectMin() - .(1, 1), Gui.igGetItemRectMax() + .(1, 1), Theme.NodeError, 3, 1.5f, 0);
				PropertyGrid.WideRow();
				Gui.igSetCursorPosX(Gui.igGetCursorPosX() + 8 * Look.Scale);
				ErrorText(why);
			}
			if (done)
			{
				var typed = StringView(mMathBuf);
				typed.Trim();
				if (typed != node.Text)
				{
					if (ok)
					{
						BeginEdit();
						node.Text.Set(typed);
						NodeFactory.SyncMath(g, node);
						mMathBufSeen.Set(node.Text);
						commit = true;
					}
					else
					{
						MathPropsRefusal.Set(why);
						Notify.Warn(why);
					}
				}
			}
		}
	}
}
