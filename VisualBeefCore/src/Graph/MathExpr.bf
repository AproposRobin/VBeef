using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Graph
{
	/// One Math Expression node remembered in the `.vblayout` side file: the generated code is the
	/// plain expression, so the side file keeps what turns it back into the node (docs/Math-Expression.md).
	///   #math <tab> methodKey <tab> nodeKey <tab> chosen result type <tab> expression (escaped)
	/// NodeKey is the node's structural path (KeyAssigner) without the content hash.
	class MathRecord
	{
		public String MethodKey = new .() ~ delete _;
		public String NodeKey = new .() ~ delete _;
		/// The result type chosen in Properties ("" = inferred).
		public String ResultType = new .() ~ delete _;
		public String Expression = new .() ~ delete _;

		public MathRecord Clone()
		{
			MathRecord r = new .();
			r.MethodKey.Set(MethodKey);
			r.NodeKey.Set(NodeKey);
			r.ResultType.Set(ResultType);
			r.Expression.Set(Expression);
			return r;
		}
	}

	/// Math Expression nodes (docs/Math-Expression.md): an expression typed on the node; every free
	/// name in it is an input pin named after it, the value is the one `result` output. This class
	/// reads and checks the text, finds the pins, writes the code with the pin values put in,
	/// matches such code against the expression (to read it back as the node) and works out the
	/// result type where Beef's rules make it certain.
	static class MathExpression
	{
		/// Type names an expression may use before a `.` without an index (`Math.Sqrt`, `Math.PI_f`).
		static String[?] sKnownTypes = .("Math", "System", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
			"Float", "Double", "Bool", "Char8", "Char16", "Char32");

		/// Math functions with a float and a double version: the result follows the arguments.
		static String[?] sFloatFunctions = .("Sqrt", "Sin", "Cos", "Tan", "Asin", "Acos", "Atan", "Atan2", "Sinh", "Cosh", "Tanh", "Pow", "Exp",
			"Log", "Log10", "Floor", "Ceiling", "Round", "Truncate", "Cbrt", "Lerp", "RadiansToDegrees", "DegreesToRadians", "IEEERemainder");

		/// Math functions whose result is the type of their arguments.
		static String[?] sSameTypeFunctions = .("Abs", "Min", "Max", "Clamp");

		/// The result types Properties offers when the expression does not say what it gives.
		public static String[?] ResultTypeChoices = .("int", "int64", "uint", "float", "double", "bool");

		/// A parsed expression with its pins.
		public class Parsed
		{
			public CompilationUnit Unit ~ delete _;
			public Expr Root ~ delete _;
			/// Every name in the expression that reads a pin, in source order.
			public List<Expr> PinUses = new .() ~ delete _;
			/// The pin names in the order they first appear (each once).
			public List<String> Pins = new .() ~ DeleteContainerAndItems!(_);
			/// Why the text is refused ("" when it is a Math Expression).
			public String Error = new .() ~ delete _;

			public bool IsValid => Root != null && Error.IsEmpty;

			public bool IsPinUse(Expr e)
			{
				for (let u in PinUses)
					if (u == e)
						return true;
				return false;
			}

			public bool HasPin(StringView name)
			{
				for (let p in Pins)
					if (p == name)
						return true;
				return false;
			}
		}

		enum Role
		{
			Value,
			Callee,
			MemberRoot
		}

		/// Reads `text`. Always returns an object: `Error` says why the text is refused.
		public static Parsed Parse(StringView textIn)
		{
			Parsed p = new .();
			var text = textIn;
			text.Trim();
			if (text.IsEmpty)
			{
				p.Error.Set("Type an expression, for example a * b + 1.");
				return p;
			}
			if (text.Contains(';'))
			{
				p.Error.Set("One expression only: a Math Expression has no ';'.");
				return p;
			}
			let root = Parser.ParseExpression(text, let unit);
			if (root == null)
			{
				p.Error.AppendF("'{}' is not a Beef expression: check the brackets, operators and names.", text);
				return p;
			}
			p.Unit = unit;
			p.Root = root;
			Walk(p, root, .Value);
			return p;
		}

		/// True when `text` is a valid Math Expression; `outWhy` says why not.
		public static bool Check(StringView text, String outWhy)
		{
			let p = Parse(text);
			defer delete p;
			if (!p.IsValid)
				outWhy.Set(p.Error);
			return p.IsValid;
		}

		/// The pin names of `text` in the order they first appear; false (and no names) when the
		/// text is refused.
		public static bool PinNames(StringView text, List<String> outNames, String outWhy = null)
		{
			let p = Parse(text);
			defer delete p;
			if (!p.IsValid)
			{
				outWhy?.Set(p.Error);
				return false;
			}
			for (let n in p.Pins)
				outNames.Add(new String(n));
			return true;
		}

		/// How many times `pin` appears in `text` as a pin (0 when the text is refused).
		public static int UseCount(StringView text, StringView pin)
		{
			let p = Parse(text);
			defer delete p;
			int count = 0;
			for (let u in p.PinUses)
				if (u.Op == pin)
					count++;
			return p.IsValid ? count : 0;
		}

		static bool IsTypeName(StringView name)
		{
			for (let t in sKnownTypes)
				if (t == name)
					return true;
			if (TypeRules.IsPrimitive(name) || name == "String" || name == "StringView" || name == "Object")
				return true;
			let ts = TypeService.Current;
			if (ts != null && ts.FindType(name).IsValid)
				return true;
			let index = GraphBuilder.Index;
			return index != null && index.FindType(name) != null;
		}

		static void Walk(Parsed p, Expr e, Role role)
		{
			if (e == null || !p.Error.IsEmpty)
				return;
			switch (e.Kind)
			{
			case .Literal:
				if (e.LitKind == .This || e.LitKind == .Base)
					p.Error.Set("A Math Expression reads only its inputs: wire this into a pin instead.");
			case .Name:
				StringView name = e.Op;
				if (name.Contains('<') || name.Contains('!'))
				{
					p.Error.AppendF("'{}' cannot be used in a Math Expression.", p.Unit.NodeText(e));
					return;
				}
				if (role == .Callee)
					return; // a function of this type: `Twice(x)`
				if (role == .MemberRoot && IsTypeName(name))
					return; // `Math.Sqrt`, `int.MaxValue`
				if (TypeRules.IsPrimitive(name) || Parser.IsReservedWord(name))
				{
					p.Error.AppendF("'{}' is a Beef keyword or type, not a value.", name);
					return;
				}
				p.PinUses.Add(e);
				if (!p.HasPin(name))
					p.Pins.Add(new String(name));
			case .Member:
				Walk(p, e.A, .MemberRoot);
			case .Call:
				if (e.A != null && e.A.Kind != .Name && e.A.Kind != .Member)
				{
					p.Error.AppendF("'{}' cannot be called in a Math Expression.", p.Unit.NodeText(e.A));
					return;
				}
				Walk(p, e.A, .Callee);
				if (e.Args != null)
					for (let a in e.Args)
						Walk(p, a, .Value);
			case .Index:
				Walk(p, e.A, .Value);
				if (e.Args != null)
					for (let a in e.Args)
						Walk(p, a, .Value);
			case .Unary:
				if (e.Op == "++" || e.Op == "--")
				{
					p.Error.AppendF("A Math Expression gives a value: {} changes a variable.", e.Op);
					return;
				}
				if (e.Op == "&" || e.Op == "*")
				{
					p.Error.AppendF("A Math Expression works with values: '{}' (address or dereference) cannot be used.", e.Op);
					return;
				}
				Walk(p, e.A, .Value);
			case .Binary:
				Walk(p, e.A, .Value);
				Walk(p, e.B, .Value);
			case .Conditional:
				Walk(p, e.A, .Value);
				Walk(p, e.B, .Value);
				Walk(p, e.C, .Value);
			case .Cast:
				if (e.TypeText == null || e.TypeText == ".")
				{
					p.Error.Set("A cast in a Math Expression names its type: (float)x, not (.)x.");
					return;
				}
				Walk(p, e.A, .Value);
			case .Paren:
				Walk(p, e.A, .Value);
			case .Assign:
				p.Error.AppendF("A Math Expression gives a value: it cannot assign with {}.", e.Op);
			case .New:
				p.Error.Set("A Math Expression cannot make objects (new, scope, .()).");
			case .Lambda:
				p.Error.Set("A Math Expression cannot hold a lambda.");
			case .Raw:
				p.Error.AppendF("'{}' cannot be read in a Math Expression.", p.Unit.NodeText(e));
			}
		}

		// ------------------------------------------------------------------ code

		/// The code of the expression with every pin name replaced by `valueOf(pin)` (the caller
		/// parenthesises values that need it). False when the text is refused.
		public static bool Substitute(Parsed p, delegate void(StringView pin, String outValue) valueOf, String outCode)
		{
			if (!p.IsValid)
				return false;
			let text = p.Unit.Text;
			let first = p.Unit.Tokens[p.Root.FirstTok];
			let last = p.Unit.Tokens[p.Root.LastTok];
			int pos = first.Start;
			List<Expr> uses = scope .();
			uses.AddRange(p.PinUses);
			uses.Sort(scope (a, b) => a.FirstTok <=> b.FirstTok);
			String value = scope .();
			for (let u in uses)
			{
				let s = p.Unit.Tokens[u.FirstTok].Start;
				let e = p.Unit.Tokens[u.LastTok].End;
				outCode.Append(StringView(text, pos, s - pos));
				value.Clear();
				valueOf(u.Op, value);
				outCode.Append(value);
				pos = e;
			}
			outCode.Append(StringView(text, pos, last.End - pos));
			return true;
		}

		static Expr Unparen(Expr e)
		{
			var e;
			while (e != null && e.Kind == .Paren && e.A != null)
				e = e.A;
			return e;
		}

		static bool SameText(StringView a, StringView b)
		{
			if (a == b)
				return true;
			String na = scope .();
			String nb = scope .();
			LayoutKeys.Normalize(a, na);
			LayoutKeys.Normalize(b, nb);
			return na == nb;
		}

		/// Matches `code` (an expression read from a file) against the expression: true when it is
		/// the expression with something in place of each pin. `outBindings` gets, per pin name,
		/// the text in its place (without the parentheses put around it). A pin used twice must
		/// hold the same text both times.
		public static bool Match(Parsed p, StringView code, Dictionary<String, String> outBindings)
		{
			if (!p.IsValid)
				return false;
			let c = Parser.ParseExpression(code, let unit);
			if (c == null)
				return false;
			defer { delete c; delete unit; }
			if (!Unify(p, p.Root, unit, c, outBindings))
				return false;
			for (let name in p.Pins)
				if (!outBindings.ContainsKeyAlt(name))
					return false;
			return true;
		}

		static bool Unify(Parsed p, Expr t, CompilationUnit cu, Expr c, Dictionary<String, String> bindings)
		{
			if (t == null || c == null)
				return t == c;
			if (t.Kind == .Name && p.IsPinUse(t))
			{
				let inner = Unparen(c);
				let text = cu.NodeText(inner);
				if (bindings.TryGetValueAlt(t.Op, let have))
					return SameText(have, text);
				bindings[new String(t.Op)] = new String(text);
				return true;
			}
			if (t.Kind != c.Kind)
				return false;
			switch (t.Kind)
			{
			case .Literal, .Name:
				return t.Op == c.Op;
			case .Member:
				return t.Op == c.Op && t.NullCond == c.NullCond && t.Cascade == c.Cascade && Unify(p, t.A, cu, c.A, bindings);
			case .Call, .Index:
				if (!Unify(p, t.A, cu, c.A, bindings))
					return false;
				let tc = (t.Args != null) ? t.Args.Count : 0;
				let cc = (c.Args != null) ? c.Args.Count : 0;
				if (tc != cc)
					return false;
				for (int i < tc)
					if (!Unify(p, t.Args[i], cu, c.Args[i], bindings))
						return false;
				return true;
			case .Unary:
				return t.Op == c.Op && t.Postfix == c.Postfix && Unify(p, t.A, cu, c.A, bindings);
			case .Binary:
				return t.Op == c.Op && Unify(p, t.A, cu, c.A, bindings) && Unify(p, t.B, cu, c.B, bindings);
			case .Conditional:
				return Unify(p, t.A, cu, c.A, bindings) && Unify(p, t.B, cu, c.B, bindings) && Unify(p, t.C, cu, c.C, bindings);
			case .Cast:
				return t.TypeText != null && c.TypeText != null && SameText(t.TypeText, c.TypeText) && Unify(p, t.A, cu, c.A, bindings);
			case .Paren:
				return Unify(p, t.A, cu, c.A, bindings);
			default:
				return false;
			}
		}

		// ------------------------------------------------------------------ types

		/// The type of the expression when Beef's rules make it certain: int / float / double / bool
		/// arithmetic and comparisons, casts, literals and the Math functions. `typeOfPin` gives
		/// a pin's type ("" or false when unknown). False when the type can't be told.
		public static bool InferType(Parsed p, delegate bool(StringView pin, String outType) typeOfPin, String outType)
		{
			if (!p.IsValid)
				return false;
			return TypeOf(p, p.Root, typeOfPin, outType) && !outType.IsEmpty;
		}

		static bool TypeOf(Parsed p, Expr e, delegate bool(StringView pin, String outType) typeOfPin, String outType)
		{
			outType.Clear();
			if (e == null)
				return false;
			switch (e.Kind)
			{
			case .Literal:
				switch (e.LitKind)
				{
				case .Int: outType.Set("int");
				case .UInt: outType.Set("uint");
				case .Long: outType.Set("int64");
				case .ULong: outType.Set("uint64");
				case .Float: outType.Set("float");
				case .Double: outType.Set("double");
				case .Bool: outType.Set("bool");
				case .Char8: outType.Set("char8");
				case .Char32: outType.Set("char32");
				default: return false;
				}
				return true;
			case .Name:
				if (!p.IsPinUse(e))
					return false;
				return typeOfPin(e.Op, outType) && !outType.IsEmpty;
			case .Paren:
				return TypeOf(p, e.A, typeOfPin, outType);
			case .Cast:
				if (e.TypeText == null || e.TypeText == ".")
					return false;
				outType.Set(e.TypeText);
				return true;
			case .Unary:
				String a = scope .();
				if (e.Op != "!" && !TypeOf(p, e.A, typeOfPin, a))
					return false;
				return UnaryType(e.Op, a, outType);
			case .Binary:
				String a = scope .();
				String b = scope .();
				TypeOf(p, e.A, typeOfPin, a);
				TypeOf(p, e.B, typeOfPin, b);
				return BinaryType(e.Op, a, b, outType);
			case .Conditional:
				String a = scope .();
				String b = scope .();
				if (!TypeOf(p, e.B, typeOfPin, a) || !TypeOf(p, e.C, typeOfPin, b))
					return false;
				if (a == b)
				{
					outType.Set(a);
					return true;
				}
				return Promote(a, b, outType);
			case .Member:
				let root = Unparen(e.A);
				if (root != null && root.Kind == .Name && root.Op == "Math")
				{
					if (e.Op == "PI_f" || e.Op == "E_f")
						outType.Set("float");
					else if (e.Op == "PI_d" || e.Op == "E_d")
						outType.Set("double");
					return !outType.IsEmpty;
				}
				let ts = TypeService.Current;
				if (ts == null)
					return false;
				String owner = scope .();
				if (root != null && root.Kind == .Name && !p.IsPinUse(root))
					owner.Set(root.Op); // a static member: `int.MaxValue`
				else if (!TypeOf(p, e.A, typeOfPin, owner))
					return false;
				String t = scope .();
				if (!ts.FindMemberType(owner, e.Op, null, t) || t.IsEmpty || TypeRules.IsWildcard(t))
					return false;
				outType.Set(t);
				return true;
			case .Call:
				let callee = e.A;
				if (callee == null || callee.Kind != .Member)
					return false;
				let qual = Unparen(callee.A);
				if (qual == null || qual.Kind != .Name || p.IsPinUse(qual))
					return false;
				List<String> argTypes = scope .();
				defer { ClearAndDeleteItems!(argTypes); }
				if (e.Args != null)
				{
					for (let arg in e.Args)
					{
						String at = new .();
						argTypes.Add(at);
						if (!TypeOf(p, arg, typeOfPin, at))
							at.Clear();
					}
				}
				if (qual.Op == "Math")
				{
					let fn = StringView(callee.Op);
					if (fn == "Sign")
					{
						outType.Set("int");
						return true;
					}
					bool floatFn = false;
					for (let f in sFloatFunctions)
						if (f == fn)
							floatFn = true;
					bool sameFn = false;
					for (let f in sSameTypeFunctions)
						if (f == fn)
							sameFn = true;
					if (floatFn || sameFn)
					{
						if (argTypes.IsEmpty)
							return false;
						for (let at in argTypes)
							if (!TypeRules.IsNumeric(at))
								return false;
						String acc = scope .(argTypes[0]);
						for (int i = 1; i < argTypes.Count; i++)
						{
							String next = scope .();
							if (!Promote(acc, argTypes[i], next))
								return false;
							acc.Set(next);
						}
						if (floatFn && !TypeRules.IsFloat(acc))
							return false; // a whole number fits the float and the double version alike
						outType.Set(acc);
						return true;
					}
				}
				let ts = TypeService.Current;
				if (ts == null)
					return false;
				for (let at in argTypes)
					if (at.IsEmpty)
						return false;
				let m = ts.ResolveCall(qual.Op, "", callee.Op, argTypes.Count, argTypes, null);
				if (m == null || m.ReturnType.IsEmpty || m.ReturnType == "void" || TypeRules.IsWildcard(m.ReturnType, m.GenericParams))
					return false;
				outType.Set(m.ReturnType);
				return true;
			default:
				return false;
			}
		}

		/// `op a` for a value of type `a`: `!` is bool, `-` / `+` / `~` keep a wide number type.
		static bool UnaryType(StringView op, StringView a, String outType)
		{
			outType.Clear();
			if (op == "!")
			{
				outType.Set("bool");
				return true;
			}
			if (op == "~" ? !TypeRules.IsInt(a) : !TypeRules.IsNumeric(a))
				return false;
			outType.Set(a);
			return Wide(outType);
		}

		/// `a op b`: comparisons and && / || are bool; arithmetic follows Promote; shifts keep the
		/// left type; & | ^ on two bools is bool. False when it can't be told ("" types unknown).
		static bool BinaryType(StringView op, StringView a, StringView b, String outType)
		{
			outType.Clear();
			if (op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=" || op == "&&" || op == "||")
			{
				outType.Set("bool");
				return true;
			}
			if (op == "<<" || op == ">>")
			{
				if (!TypeRules.IsInt(a))
					return false;
				outType.Set(a);
				return Wide(outType);
			}
			if (op == "&" || op == "|" || op == "^")
			{
				if (a == "bool" && b == "bool")
				{
					outType.Set("bool");
					return true;
				}
				if (!TypeRules.IsInt(a) || !TypeRules.IsInt(b))
					return false;
			}
			else if (op != "+" && op != "-" && op != "*" && op != "/" && op != "%")
				return false;
			return Promote(a, b, outType);
		}

		/// The integer types that keep their type in arithmetic; smaller ones are left to the
		/// explicit choice (the expression does not say).
		static bool Wide(String type)
		{
			return type == "int" || type == "int32" || type == "int64" || type == "uint" || type == "uint32" || type == "uint64" ||
				type == "float" || type == "double";
		}

		/// The type of `a op b` for numbers: the same type stays, an integer with a float gives
		/// the float, float with double gives double, a narrower signed integer with a wider one
		/// gives the wider one. False when Beef's choice is not certain.
		static bool Promote(StringView a, StringView b, String outType)
		{
			if (!TypeRules.IsNumeric(a) || !TypeRules.IsNumeric(b))
				return false;
			if (a == b)
			{
				outType.Set(a);
				return Wide(outType);
			}
			if (a == "double" || b == "double")
			{
				outType.Set("double");
				return true;
			}
			if (a == "float" || b == "float")
			{
				outType.Set("float");
				return true;
			}
			int sa = 0, sb = 0;
			bool signedA = false, signedB = false;
			if (!TypeRules.IntInfo(a, out sa, out signedA) || !TypeRules.IntInfo(b, out sb, out signedB) || signedA != signedB || sa == sb)
				return false;
			outType.Set((sa > sb) ? a : b);
			return Wide(outType);
		}

		// ------------------------------------------------------------------ graph

		/// The type a pin of a Math Expression node has now: the wire's, or the typed value's.
		public static void PinType(Graph g, Pin pin, String outType) => PinType(g, pin, outType, 0);

		static void PinType(Graph g, Pin pin, String outType, int depth)
		{
			let link = g.FindLinkTo(pin);
			if (link != null)
			{
				outType.Set(link.From.TypeName);
				if (TypeRules.IsUnknown(outType))
					outType.Clear();
				// An operator node made in the editor has no result type yet: its inputs tell it.
				let src = link.From.Owner;
				if (outType.IsEmpty && depth < 16 && src.IsPure && src.Kind == .Operator && link.From == src.Result)
				{
					let pa = src.FindInput("a");
					let pb = src.FindInput("b");
					String a = scope .();
					String b = scope .();
					if (pa != null)
						PinType(g, pa, a, depth + 1);
					if (pb != null)
						PinType(g, pb, b, depth + 1);
					if (pb != null)
						BinaryType(src.Text, a, b, outType);
					else
						UnaryType(src.Text, a, outType);
				}
				return;
			}
			var d = StringView(pin.Default);
			d.Trim();
			if (d.IsEmpty)
				return;
			TypeRules.LiteralType(d, outType);
			if (TypeRules.IsUnknown(outType))
				outType.Clear();
		}

		/// After the expression or a wire changed: one input per name (kept pins keep their
		/// wires and values, in the order the names appear), the pin types from the wires and the
		/// result type. A refused expression leaves the pins as they are (nothing is lost while
		/// the text is being typed). Returns the parse error ("" when valid) in `outError`.
		public static void Sync(Graph g, Node n, String outError = null)
		{
			let p = Parse(n.Text);
			defer delete p;
			if (!p.IsValid)
			{
				outError?.Set(p.Error);
				UpdateTypes(g, n, null);
				return;
			}
			for (int i = n.Inputs.Count - 1; i >= 0; i--)
			{
				let pin = n.Inputs[i];
				if (pin.Kind == .Data && !p.HasPin(pin.Name))
					g.RemovePin(pin);
			}
			for (let name in p.Pins)
				if (n.FindInput(name) == null)
					g.AddDataIn(n, name, name);
			// The order the names appear in.
			n.Inputs.Sort(scope (a, b) => p.Pins.IndexOf(a.Name) <=> p.Pins.IndexOf(b.Name));
			UpdateTypes(g, n, p);
		}

		/// Pin types from the wires, and the result type (inferred, else the one chosen).
		public static void UpdateTypes(Graph g, Node n, Parsed parsed)
		{
			for (let pin in n.Inputs)
			{
				if (pin.Kind != .Data)
					continue;
				String t = scope .();
				PinType(g, pin, t);
				if (pin.TypeName != t)
					pin.TypeName.Set(t);
			}
			let result = n.Result;
			if (result == null)
				return;
			String type = scope .();
			if (parsed != null)
				InferType(parsed, scope (pin, outType) =>
					{
						let input = n.FindInput(pin);
						if (input == null)
							return false;
						outType.Set(input.TypeName);
						return !outType.IsEmpty;
					}, type);
			if (type.IsEmpty && n.MathType != null)
				type.Set(n.MathType);
			if (result.TypeName != type)
				result.TypeName.Set(type);
		}

		/// True when the result type follows from the expression and its inputs (`outType`).
		public static bool Inferred(Graph g, Node n, String outType)
		{
			let p = Parse(n.Text);
			defer delete p;
			return InferType(p, scope (pin, t) =>
				{
					let input = n.FindInput(pin);
					if (input == null)
						return false;
					PinType(g, input, t);
					return !t.IsEmpty;
				}, outType);
		}

		/// What is wrong with a Math Expression node ("" when nothing): a refused expression, an
		/// input without a wire or a value, a result type that is neither inferred nor chosen.
		public static void Problem(Graph g, Node n, String outWhy)
		{
			let p = Parse(n.Text);
			defer delete p;
			if (!p.IsValid)
			{
				outWhy.Set(p.Error);
				return;
			}
			for (let name in p.Pins)
			{
				let pin = n.FindInput(name);
				if (pin == null)
				{
					outWhy.AppendF("'{}' has no input pin: edit the expression again to make it.", name);
					return;
				}
				if (g.FindLinkTo(pin) == null && pin.Default.IsEmpty)
				{
					outWhy.AppendF("'{}' needs a value: connect a wire to it or type one in.", name);
					return;
				}
			}
			String t = scope .();
			if (!Inferred(g, n, t) && (n.MathType == null || n.MathType.IsEmpty))
				outWhy.Set("What this gives can't be told from the expression and its inputs: choose the Result Type in Properties.");
		}

		// ------------------------------------------------------------------ side file

		/// Records for the Math Expression nodes of a graph whose keys are assigned (orphans,
		/// keyed `orphan<id>`, are left to the orphan record).
		public static void Capture(Graph g, List<MathRecord> outRecords)
		{
			for (let n in g.Nodes)
			{
				if (n.Kind != .MathExpr || n.Key.IsEmpty || n.Key.StartsWith("orphan"))
					continue;
				MathRecord r = new .();
				r.MethodKey.Set(g.MethodKey);
				r.NodeKey.Set(n.Key);
				if (n.MathType != null)
					r.ResultType.Set(n.MathType);
				r.Expression.Set(n.Text);
				outRecords.Add(r);
			}
		}

		/// The name the code reads a value from an exec node's output by (a local, a loop
		/// variable, a parameter, an out variable, a kept value), or "" when it has none.
		static void ReadName(Pin from, String outName)
		{
			let src = from.Owner;
			if (from.IsOutArg)
			{
				if (from.OutName != null)
					outName.Set(from.OutName);
				return;
			}
			switch (src.Kind)
			{
			case .LocalVar, .ForEach:
				outName.Set(src.Text);
			case .For:
				if (src.IsCountingLoop && from.Name == "counter")
					outName.Set(src.Text);
			case .Entry:
				outName.Set(from.Label);
			case .Call:
				if (!src.IsPure)
					outName.Set(src.Text2);
			default:
				if (src.IsPure && src.Text2.StartsWith("__v"))
					outName.Set(src.Text2);
			}
		}

		/// Turns the value at `nodeKey` back into a Math Expression node when its code is the
		/// expression with values in place of the pins: the nodes that made each value are wired
		/// into the pins (a value no node made becomes the pin's typed value), the rest of the
		/// expression's nodes go. Keys must be assigned; the caller re-assigns them. False (graph
		/// unchanged) when the code is not the expression any more.
		public static bool Restore(Graph g, MathRecord rec)
		{
			Node root = null;
			for (let n in g.Nodes)
			{
				if (n.Key == rec.NodeKey)
				{
					root = n;
					break;
				}
			}
			if (root == null || !root.IsPure || root.Kind == .MathExpr || root.Original == null)
				return false;
			Pin rootOut = root.Result;
			if (rootOut == null)
			{
				for (let o in root.Outputs)
				{
					if (o.Kind == .Data)
					{
						rootOut = o;
						break;
					}
				}
			}
			if (rootOut == null)
				return false;
			let p = Parse(rec.Expression);
			defer delete p;
			Dictionary<String, String> bindings = scope .();
			defer { for (let kv in bindings) { delete kv.key; delete kv.value; } }
			if (!Match(p, root.Original, bindings))
				return false;

			// Reading the code back is not an edit: the flags of the nodes that stay are restored.
			Dictionary<Node, (bool edited, bool moved)> flags = scope .();
			for (let n in g.Nodes)
				flags[n] = (n.Edited, n.Moved);

			// The nodes of the expression: the pure nodes feeding the root (breadth first, so the
			// outermost node that made a value is found first).
			List<Node> sub = scope .();
			HashSet<Node> inSub = scope .();
			sub.Add(root);
			inSub.Add(root);
			for (int i = 0; i < sub.Count; i++)
			{
				for (let input in sub[i].Inputs)
				{
					if (input.Kind != .Data)
						continue;
					let src = g.DataSource(input);
					if (src != null && src.IsPure && src.Kind != .Lambda && inSub.Add(src))
						sub.Add(src);
				}
			}

			Node m = g.AddNode(.MathExpr);
			m.IsPure = true;
			m.Text.Set(rec.Expression);
			if (!rec.ResultType.IsEmpty)
				Graph.CopyStr(ref m.MathType, rec.ResultType);
			m.Key.Set(root.Key);
			Graph.CopyStr(ref m.Original, root.Original);
			m.Line = root.Line;
			m.LineEnd = root.LineEnd;
			m.X = root.X;
			m.Y = root.Y;
			m.HasPos = root.HasPos;
			let result = g.AddDataOut(m, "result", "");

			HashSet<Node> keep = scope .();
			List<(Pin to, Pin from)> wires = scope .();
			String norm = scope .();
			String have = scope .();
			String name = scope .();
			for (let pinName in p.Pins)
			{
				let input = g.AddDataIn(m, pinName, pinName);
				let text = bindings[scope String(pinName)];
				norm.Clear();
				LayoutKeys.Normalize(text, norm);
				Pin from = null;
				// A node of the expression that made this value.
				for (let n in sub)
				{
					if (n.Original == null || keep.Contains(n))
						continue;
					have.Clear();
					LayoutKeys.Normalize(n.Original, have);
					if (have != norm)
						continue;
					from = n.Result;
					if (from == null)
						for (let o in n.Outputs)
							if (o.Kind == .Data && from == null)
								from = o;
					if (from != null)
						keep.Add(n);
					break;
				}
				// A value read from a local, a loop variable, a parameter, an out variable.
				if (from == null)
				{
					for (let n in sub)
					{
						for (let inPin in n.Inputs)
						{
							let link = g.FindLinkTo(inPin);
							if (link == null || link.From.Kind != .Data || inSub.Contains(link.From.Owner))
								continue;
							name.Clear();
							ReadName(link.From, name);
							if (!name.IsEmpty && name == norm)
							{
								from = link.From;
								break;
							}
						}
						if (from != null)
							break;
					}
				}
				if (from != null)
					wires.Add((input, from));
				else
					input.Default.Set(text);
			}

			// Whatever read the root now reads the node; the expression's other nodes go.
			List<Link> outs = scope .();
			g.FindLinksFrom(rootOut, outs);
			List<Pin> readers = scope .();
			for (let l in outs)
				readers.Add(l.To);
			// Nodes kept for a pin keep their own inputs: everything feeding them stays too.
			for (int i = 0; i < sub.Count; i++)
			{
				if (!keep.Contains(sub[i]))
					continue;
				for (let input in sub[i].Inputs)
				{
					let src = g.DataSource(input);
					if (src != null && inSub.Contains(src))
						keep.Add(src);
				}
			}
			for (let n in sub)
				if (!keep.Contains(n))
					g.RemoveNode(n);
			for (let w in wires)
			{
				let l = g.Connect(w.from, w.to);
				if (l != null)
					l.Parsed = true;
			}
			for (let r in readers)
			{
				let l = g.Connect(result, r);
				if (l != null)
					l.Parsed = true;
			}
			Sync(g, m);
			for (let n in g.Nodes)
			{
				if (flags.TryGetValue(n, let f))
				{
					n.Edited = f.edited;
					n.Moved = f.moved;
				}
			}
			m.Edited = false;
			m.Moved = false;
			return true;
		}
	}
}
