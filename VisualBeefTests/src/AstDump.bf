using System;
using System.Collections;
using VisualBeef.Syntax;

namespace VisualBeef.Tests
{
	static class AstDump
	{
		public static void DumpExpr(CompilationUnit u, Expr e, String o)
		{
			if (e == null) { o.Append("<null>"); return; }
			switch (e.Kind)
			{
			case .Literal: o.AppendF("Lit({})", e.Op);
			case .Name: o.AppendF("Name({})", e.Op);
			case .Member: o.Append("Mem("); DumpExpr(u, e.A, o); o.AppendF(" {} {})", e.NullCond ? "?." : ".", e.Op);
			case .Call, .Index:
				o.Append(e.Kind == .Call ? "Call(" : "Idx("); DumpExpr(u, e.A, o);
				for (let a in e.Args) { o.Append(", "); DumpExpr(u, a, o); }
				o.Append(")");
			case .Unary: o.AppendF("Un{}({} ", e.Postfix ? "Post" : "", e.Op); DumpExpr(u, e.A, o); o.Append(")");
			case .Binary, .Assign: o.AppendF("{}({} ", e.Kind == .Binary ? "Bin" : "Asg", e.Op); DumpExpr(u, e.A, o); o.Append(", "); DumpExpr(u, e.B, o); o.Append(")");
			case .Conditional: o.Append("Cond("); DumpExpr(u, e.A, o); o.Append(", "); DumpExpr(u, e.B, o); o.Append(", "); DumpExpr(u, e.C, o); o.Append(")");
			case .Cast: o.AppendF("Cast({}, ", e.TypeText); DumpExpr(u, e.A, o); o.Append(")");
			case .Paren: o.Append("Par("); DumpExpr(u, e.A, o); o.Append(")");
			case .Raw: o.AppendF("RAW[{}]", u.NodeText(e));
			case .New:
				o.AppendF("New({} {}{}", e.Op, e.TypeText, e.IsArray ? "[" : "(");
				for (let a in e.Args) { if (@a.Index > 0) o.Append(", "); DumpExpr(u, a, o); }
				o.Append(e.IsArray ? "])" : "))");
			case .Lambda:
				o.AppendF("Lambda({}{}{} => ", e.Op, (e.Captures != null) ? e.Captures : "", (e.Params != null) ? e.Params : "<method>");
				if (e.Body != null)
					o.AppendF("{{{} stmts}}", e.Body.Body.Count);
				else
					DumpExpr(u, e.A, o);
				o.Append(")");
			}
		}

		public static void DumpStmt(CompilationUnit u, Stmt s, int depth, String o)
		{
			o.Append(' ', depth * 2);
			o.AppendF("{} ", s.Kind);
			switch (s.Kind)
			{
			case .Block:
				o.Append("\n");
				for (let c in s.Body) DumpStmt(u, c, depth + 1, o);
				return;
			case .Raw: o.AppendF("[{}]", u.NodeText(s));
			case .LocalVar: o.AppendF("{} {} = ", s.VarType, s.VarName); if (s.Expr != null) DumpExpr(u, s.Expr, o);
			case .ForEach: o.AppendF("{} {} in ", s.VarType, s.VarName); DumpExpr(u, s.Expr, o);
			case .For: o.AppendF("({})", s.ForHeader);
			case .Delete: o.AppendF("{} ", s.Alloc); DumpExpr(u, s.Expr, o);
			case .Defer: o.AppendF("{}", s.Alloc);
			case .Using: if (s.VarName != null) o.AppendF("{} {} = ", s.VarType, s.VarName); DumpExpr(u, s.Expr, o);
			default: if (s.Expr != null) DumpExpr(u, s.Expr, o);
			}
			o.Append("\n");
			if (s.Then != null) DumpStmt(u, s.Then, depth + 1, o);
			if (s.Else != null) { o.Append(' ', depth * 2); o.Append("else\n"); DumpStmt(u, s.Else, depth + 1, o); }
		}

		public static void DumpMembers(CompilationUnit u, List<Member> members, int depth, String o)
		{
			for (let m in members)
			{
				o.Append(' ', depth * 2);
				o.AppendF("{} {}", m.Kind, m.Name);
				if (m.Kind == .Raw) o.AppendF(" [{}]", u.NodeText(m));
				if (m.Kind == .Broken) o.AppendF(" ERROR({}) [{}]", m.Error, u.NodeText(m));
				if (m.Kind == .Method)
				{
					o.AppendF(" ret={} params=", m.TypeText);
					for (let p in m.Params) o.AppendF("<{}|{}|{}> ", p.Modifier, p.Type, p.Name);
				}
				o.Append("\n");
				if (m.Members != null) DumpMembers(u, m.Members, depth + 1, o);
				if (m.Body != null) DumpStmt(u, m.Body, depth + 1, o);
			}
		}
	}
}
