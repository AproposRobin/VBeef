using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Graph
{
	/// Creates new nodes for the editor palette. Pin names match what GraphBuilder produces, so
	/// a node created here round-trips through code exactly like one parsed from code.
	static class NodeFactory
	{
		static Node NewExec(Graph g, NodeKind kind)
		{
			Node n = g.AddNode(kind);
			n.Edited = true;
			n.Moved = true;
			g.AddExecIn(n);
			return n;
		}

		static Node NewPure(Graph g, NodeKind kind)
		{
			Node n = g.AddNode(kind);
			n.IsPure = true;
			n.Edited = true;
			n.Moved = true;
			return n;
		}

		/// A function call by name (the older entry point, kept for the editor's typed-name
		/// entries and tests). `hasFlow` = statement call with hasFlow pins; otherwise a pure call.
		///  - "Console.WriteLine" (a dotted name, no target): a static call, qualifier "Console";
		///  - `hasTarget`: a member call with a Target pin holding `targetDefault` (empty = self);
		///  - otherwise an unresolved call without Target (`Foo()`).
		/// Prefer StaticCall / MemberCall when the binding is known, so the node is exactly the
		/// one the code reads back as.
		public static Node Call(Graph g, StringView name, bool hasFlow, bool hasTarget, StringView targetDefault,
			Span<StringView> paramNames, Span<StringView> paramTypes, StringView returnType)
		{
			if (!hasTarget)
			{
				int dot = LastTopLevelDot(name);
				if (dot > 0 && dot < name.Length - 1)
				{
					let qualifier = name.Substring(0, dot);
					String owner = scope .();
					OwnerOfQualifier(qualifier, owner);
					return StaticCall(g, name.Substring(dot + 1), qualifier, owner, hasFlow, paramNames, paramTypes, returnType);
				}
			}
			Node n = NewCall(g, name, hasFlow);
			if (hasTarget)
			{
				n.Binding = .Instance;
				let t = g.AddDataIn(n, "target", "Receiver");
				t.Default.Set(targetDefault);
			}
			AddArgs(g, n, paramNames, paramTypes, default, default);
			AddResult(g, n, hasFlow, returnType);
			return n;
		}

		/// A static function call: no Target pin; written `<qualifier>.<name>(...)`, or `name(...)`
		/// when the qualifier is empty (a static function of the type whose graph this is).
		/// `modifiers` holds each parameter's `ref` / `out` / `params` (may be empty), `outRef`
		/// marks `ref` parameters tagged `[Pin(Out=true)]`.
		public static Node StaticCall(Graph g, StringView name, StringView qualifier, StringView ownerType, bool hasFlow,
			Span<StringView> paramNames, Span<StringView> paramTypes, StringView returnType,
			Span<StringView> modifiers = default, Span<bool> outRef = default)
		{
			Node n = NewCall(g, name, hasFlow);
			n.Binding = .Static;
			if (!qualifier.IsEmpty)
				n.Qualifier = new String(qualifier);
			if (!ownerType.IsEmpty)
				n.OwnerType = new String(ownerType);
			AddArgs(g, n, paramNames, paramTypes, modifiers, outRef);
			AddResult(g, n, hasFlow, returnType);
			return n;
		}

		/// A member function call: a Target pin typed with the owning type. Left unconnected it
		/// means `this` ("self"); GraphValidator reports it when self is not an `ownerType`.
		public static Node MemberCall(Graph g, StringView name, StringView ownerType, bool hasFlow,
			Span<StringView> paramNames, Span<StringView> paramTypes, StringView returnType,
			Span<StringView> modifiers = default, Span<bool> outRef = default)
		{
			Node n = NewCall(g, name, hasFlow);
			n.Binding = .Instance;
			if (!ownerType.IsEmpty)
				n.OwnerType = new String(ownerType);
			let t = g.AddDataIn(n, "target", "Receiver");
			t.TypeName.Set(ownerType);
			AddArgs(g, n, paramNames, paramTypes, modifiers, outRef);
			AddResult(g, n, hasFlow, returnType);
			return n;
		}

		/// `this` as a value ("Get a reference to this").
		public static Node This(Graph g, StringView selfType)
		{
			Node n = NewPure(g, .This);
			n.Text.Set("this");
			let r = g.AddDataOut(n, "result", "This");
			r.TypeName.Set(selfType);
			return n;
		}

		/// `base` as a value (the parent class): wire it into the Receiver to call the parent's
		/// version of a function (`base.Tick(DeltaSeconds)`).
		public static Node Base(Graph g, StringView baseType)
		{
			Node n = NewPure(g, .Base);
			n.Text.Set("base");
			let r = g.AddDataOut(n, "result", "Base");
			r.TypeName.Set(baseType);
			return n;
		}

		static Node NewCall(Graph g, StringView name, bool hasFlow)
		{
			Node n = hasFlow ? NewExec(g, .Call) : NewPure(g, .Call);
			n.Text.Set(name);
			if (hasFlow)
				g.AddExecOut(n, "then");
			return n;
		}

		/// A pure call always has a value (GraphBuilder gives every expression call one).
		static void AddResult(Graph g, Node n, bool hasFlow, StringView returnType)
		{
			if (returnType != "void" || !hasFlow)
			{
				let r = g.AddDataOut(n, "result", "Return Value");
				if (returnType != "void")
					r.TypeName.Set(returnType);
			}
		}

		/// Splits a leading `ref ` / `out ` / `params ` off a type written with its modifier.
		public static void SplitModifier(StringView typeText, out StringView modifier, out StringView type)
		{
			var t = typeText;
			t.Trim();
			modifier = default;
			for (let m in StringView[?]("ref ", "out ", "params ", "in ", "mut "))
			{
				if (t.StartsWith(m))
				{
					modifier = t.Substring(0, m.Length - 1);
					t = t.Substring(m.Length);
					t.Trim();
					break;
				}
			}
			type = t;
		}

		/// The argument pins: inputs `arg<i>`, `ref` inputs marked Mode.Ref, and `out`
		/// parameters (and `ref` ones marked Out) as output pins `arg<i>` whose variable the
		/// generator declares.
		static void AddArgs(Graph g, Node n, Span<StringView> paramNames, Span<StringView> paramTypes, Span<StringView> modifiers, Span<bool> outRef)
		{
			for (int i < paramNames.Length)
			{
				StringView modifier = (i < modifiers.Length) ? modifiers[i] : default;
				StringView type = (i < paramTypes.Length) ? paramTypes[i] : default;
				if (modifier.IsEmpty)
					SplitModifier(type, out modifier, out type);
				bool isOutRef = i < outRef.Length && outRef[i];
				if (modifier == "out" || (modifier == "ref" && isOutRef))
				{
					let p = g.AddDataOut(n, scope $"arg{i}", paramNames[i]);
					p.Mode = .Out;
					if (modifier == "out")
					{
						// `?` until something reads it, then `var name` (CodeGen picks).
						p.Form = .Inline;
						p.OutDecl = new String("var");
						p.OutAuto = true;
					}
					else
						p.Form = .DeclaredRef;
					p.TypeName.Set(type);
					String name = scope .();
					FreshOutName(g, paramNames[i], p, name);
					p.OutName = new String(name);
					continue;
				}
				let p = g.AddDataIn(n, scope $"arg{i}", paramNames[i]);
				p.TypeName.Set(type);
				if (modifier == "ref")
					p.Mode = .Ref;
			}
		}

		/// A variable name for a new out pin: the parameter name (lower-case first letter), made
		/// unique among the method's locals, parameters, temps and other out variables. CodeGen
		/// checks it again against the type's fields when the graph is written.
		public static void FreshOutName(Graph g, StringView label, Pin except, String outName)
		{
			String baseName = scope .();
			for (let c in label.RawChars)
				if (c.IsLetterOrDigit || c == '_')
					baseName.Append(c);
			if (baseName.IsEmpty || baseName[0].IsDigit)
				baseName.Set("value");
			baseName[0] = baseName[0].ToLower;
			if (VisualBeef.Syntax.Parser.IsReservedWord(baseName))
				baseName.Append("Value");
			bool Taken(StringView name)
			{
				if (g.FindLocal(name) != null)
					return true;
				for (let n in g.Nodes)
				{
					if ((n.Kind == .LocalVar || n.Kind == .ForEach || n.IsCountingLoop) && n.Text == name)
						return true;
					if (n.Kind == .Get && n.Text == name && n.FindInput("target") == null)
						return true;
					if (n.Kind == .Call && n.Text2 == name)
						return true;
					for (let p in n.Outputs)
						if (p != except && p.IsOutArg && p.OutName == name)
							return true;
				}
				if (g.Entry != null)
					for (let p in g.Entry.Outputs)
						if (p.Kind == .Data && p.Label == name)
							return true;
				return false;
			}
			outName.Set(baseName);
			for (int suffix = 2; Taken(outName); suffix++)
			{
				outName.Set(baseName);
				outName.AppendF("{}", suffix);
			}
		}

		/// "Console" -> "Console", "System.Console" -> "Console", "List<int>" -> "List".
		public static void OwnerOfQualifier(StringView qualifier, String outOwner)
		{
			int dot = LastTopLevelDot(qualifier);
			var last = (dot >= 0) ? qualifier.Substring(dot + 1) : qualifier;
			int lt = last.IndexOf('<');
			if (lt > 0)
				last = last.Substring(0, lt);
			last.Trim();
			outOwner.Append(last);
		}

		/// A node for a catalog entry: a call with typed, labelled pins and the declared default
		/// values in the unconnected inputs ([Pure] entries have no hasFlow pins), or a Get / Set.
		/// Pin names match GraphBuilder's, so the node reads back from code unchanged. Static
		/// entries are static calls (no Target); member entries have a Target pin of the owning
		/// type (unconnected = self); `out` parameters are output pins.
		public static Node FromSpec(Graph g, VisualBeef.Catalog.NodeSpec spec, bool hasFlow)
		{
			switch (spec.Kind)
			{
			case .Get, .Event:
				if (spec.IsStatic)
					return Get(g, spec.CallName, spec.ReturnType);
				Node n = GetMember(g, spec.MemberName);
				n.FindInput("target").TypeName.Set(spec.OwnerType);
				n.Result.TypeName.Set(spec.ReturnType);
				return n;
			case .Set:
				// Only static members get Set entries (a Set node's target is the variable text).
				return Set(g, spec.CallName, spec.ReturnType);
			default:
			}
			bool wantExec = hasFlow && !spec.IsPure;
			List<StringView> names = scope .();
			List<StringView> types = scope .();
			List<StringView> mods = scope .();
			List<bool> outRef = scope .();
			for (let pin in spec.Pins)
			{
				// `params Object[] args`: the node starts with the fixed arguments only.
				if (pin.Modifier.Contains("params"))
					break;
				names.Add(pin.Label);
				types.Add(pin.Type);
				mods.Add(pin.IsOutput ? (pin.OutRef ? "ref" : "out") : (pin.IsRef ? "ref" : ""));
				outRef.Add(pin.OutRef);
			}
			StringView ret = spec.ReturnType.IsEmpty ? "void" : spec.ReturnType;
			Node n;
			String owner = scope .();
			OwnerOfQualifier(spec.OwnerType, owner);
			if (spec.IsStatic)
			{
				int dot = LastTopLevelDot(spec.CallName);
				StringView qualifier = (dot > 0) ? spec.CallName.Substring(0, dot) : "";
				StringView name = (dot > 0) ? spec.CallName.Substring(dot + 1) : spec.CallName;
				n = StaticCall(g, name, qualifier, owner, wantExec, names, types, ret, mods, outRef);
			}
			else
			{
				n = MemberCall(g, spec.CallName, owner, wantExec, names, types, ret, mods, outRef);
				n.FindInput("target").TypeName.Set(spec.OwnerType);
			}
			for (int i < names.Count)
			{
				let p = n.FindInput(scope $"arg{i}");
				if (p == null)
					continue;
				let pin = spec.Pins[i];
				if (!pin.Default.IsEmpty)
					p.Default.Set(pin.Default);
				else if (p.TypeName == "bool" && (i >= mods.Count || mods[i].IsEmpty))
					p.Default.Set("false"); // a bool input starts unticked, as its checkbox shows (not "needs a value")
			}
			return n;
		}

		/// Index of the last '.' outside generic brackets / parentheses, or -1.
		public static int LastTopLevelDot(StringView name)
		{
			int depth = 0;
			int dot = -1;
			for (int i < name.Length)
			{
				let c = name[i];
				if (c == '<' || c == '(' || c == '[')
					depth++;
				else if (c == '>' || c == ')' || c == ']')
					depth--;
				else if (c == '.' && depth == 0)
					dot = i;
			}
			return dot;
		}

		/// Adds one more argument pin to a Call or Index node.
		public static Pin AddArgument(Graph g, Node n)
		{
			int count = n.ArgCount;
			let p = g.AddDataIn(n, scope $"arg{count}", (n.Kind == .Index) ? "Index" : scope $"Arg {count}");
			n.Edited = true;
			return p;
		}

		public static void RemoveLastArgument(Graph g, Node n)
		{
			int count = n.ArgCount;
			if (count == 0)
				return;
			let p = n.FindArg(count - 1);
			if (p != null)
				g.RemovePin(p);
		}

		public static Node Branch(Graph g)
		{
			Node n = NewExec(g, .Branch);
			let c = g.AddDataIn(n, "condition", "Condition");
			c.TypeName.Set("bool");
			c.Default.Set("true");
			g.AddExecOut(n, "true", "True");
			g.AddExecOut(n, "false", "False");
			g.AddExecOut(n, "then", "Completed");
			return n;
		}

		public static Node Loop(Graph g, NodeKind kind)
		{
			Node n = NewExec(g, kind);
			switch (kind)
			{
			case .While, .DoWhile:
				let c = g.AddDataIn(n, "condition", "Condition");
				c.TypeName.Set("bool");
				c.Default.Set("true");
			case .For:
				// `for (int i = 0; i < 10; i++)`: the counter is an output pin.
				n.Text.Set("i");
				n.Text2.Set("int");
				let first = g.AddDataIn(n, "start", "Start");
				first.TypeName.Set("int");
				first.Default.Set("0");
				let count = g.AddDataIn(n, "count", "Count");
				count.TypeName.Set("int");
				count.Default.Set("10");
			case .ForEach:
				n.Text.Set("item");
				n.Text2.Set("let");
				g.AddDataIn(n, "collection", "Collection");
			default:
			}
			g.AddExecOut(n, "body", "Loop Body");
			g.AddExecOut(n, "then", "Completed");
			if (kind == .ForEach)
				g.AddDataOut(n, "element", n.Text);
			else if (kind == .For)
				g.AddDataOut(n, "counter", n.Text).TypeName.Set("int");
			return n;
		}

		/// `switch (value) { case A: ... default: ... }` with the given case labels. `valueType`
		/// is the type shown on the value pin ("int", "String" or an enum name).
		public static Node Switch(Graph g, StringView valueType, Span<StringView> labels)
		{
			Node n = NewExec(g, .Switch);
			let v = g.AddDataIn(n, "value", "Value");
			v.TypeName.Set(valueType);
			for (let label in labels)
				g.AddExecOut(n, scope $"case{@label.Index}", label);
			g.AddExecOut(n, "default", "Default");
			g.AddExecOut(n, "then", "Completed");
			return n;
		}

		/// Names the case outputs `case0..` in order (what a parse of the code would give them).
		public static void RenumberCases(Node n)
		{
			int i = 0;
			for (let p in n.Outputs)
			{
				if (p.Kind != .Exec || p.Name == "default" || p.Name == "then")
					continue;
				p.Name.Clear();
				p.Name.AppendF("case{}", i++);
			}
		}

		/// Adds a case before Default (or Completed).
		public static Pin AddCase(Graph g, Node n, StringView label)
		{
			let p = g.AddExecOut(n, "case", label);
			Pin before = n.FindOutput("default");
			if (before == null)
				before = n.FindOutput("then");
			if (before != null)
			{
				n.Outputs.Remove(p);
				n.Outputs.Insert(n.Outputs.IndexOf(before), p);
			}
			RenumberCases(n);
			n.Edited = true;
			g.Version++;
			return p;
		}

		public static void RemoveCase(Graph g, Node n, Pin p)
		{
			if (p.Owner != n || p.Name == "default" || p.Name == "then" || p.Kind != .Exec)
				return;
			g.RemovePin(p);
			RenumberCases(n);
		}

		/// The case label a new case of a switch on this kind starts with.
		public static void DefaultCaseLabel(PinValueKind kind, String outLabel)
		{
			switch (kind)
			{
			case .Text: outLabel.Append("\"\"");
			case .Char: outLabel.Append("'a'");
			default: outLabel.Append('0');
			}
		}

		/// The switched type of a Switch node (its Value pin's type), "" when not known.
		public static StringView SwitchType(Node n)
		{
			let v = n.FindInput("value");
			return (v == null) ? default : StringView(v.TypeName);
		}

		/// The kinds a switch can be on: whole numbers, characters, text and enums.
		public static bool CanSwitchOn(PinValueKind kind) => kind == .Enum || kind == .Text || kind == .Number || kind == .Char;

		/// Does a case label (`1`, `2, 3`, `"a"`, `.Idle`, `Mode.Idle`) belong to a switch on `type`?
		public static bool CaseFits(PinValueKind kind, StringView type, StringView label, List<String> members)
		{
			bool any = false;
			for (var part in label.Split(','))
			{
				part.Trim();
				if (part.IsEmpty)
					return false;
				any = true;
				if (kind == .Enum)
				{
					if (!PinValue.EnumMemberOf(part, type, let m))
						return false;
					bool found = members == null || members.IsEmpty;
					if (!found)
						for (let x in members)
							if (x == m)
								found = true;
					if (!found)
						return false;
				}
				else if (PinValue.KindOf(type, part, "", null) != kind)
					return false;
			}
			return any;
		}

		/// Does an enum Switch miss a member of its enum, or has a case for one it no longer has?
		public static bool SwitchMembersStale(Node n, TypeService types)
		{
			let type = SwitchType(n);
			if (PinValue.KindOf(type, "", "", types) != .Enum)
				return false;
			List<String> members = scope .();
			defer { ClearAndDeleteItems!(members); }
			PinValue.Members(type, types, members);
			if (members.IsEmpty)
				return false;
			List<String> present = scope .();
			defer { ClearAndDeleteItems!(present); }
			for (let p in n.Outputs)
			{
				if (p.Kind != .Exec || p.Name == "default" || p.Name == "then")
					continue;
				if (!CaseFits(.Enum, type, p.Label, members))
					return true;
				for (var part in p.Label.Split(','))
				{
					part.Trim();
					if (PinValue.EnumMemberOf(part, type, let m))
						present.Add(new String(m));
				}
			}
			for (let m in members)
			{
				bool has = false;
				for (let x in present)
					if (x == m)
						has = true;
				if (!has)
					return true;
			}
			return false;
		}

		/// Makes a Switch node switch on `type`: an enum gets one case per member, other types keep
		/// the cases that fit (case outputs and their wires stay) and get one starter case when none
		/// is left. Also what Reload node does for an enum switch whose members changed: new members
		/// are added, members that no longer exist are removed. False (with `why`) for a type a
		/// switch cannot be on.
		public static bool SetSwitchType(Graph g, Node n, StringView type, TypeService types, String why)
		{
			let kind = PinValue.KindOf(type, "", "", types);
			if (!CanSwitchOn(kind) || TypeRules.IsFloat(type))
			{
				why.Set("A switch works on whole numbers, characters, text and enums.");
				return false;
			}
			let value = n.FindInput("value");
			if (value == null)
				return false;
			if (value.TypeName != type)
			{
				DeleteAndNullify!(value.WildcardType);
				value.TypeName.Set(type);
			}
			List<String> members = scope .();
			defer { ClearAndDeleteItems!(members); }
			if (kind == .Enum)
				PinValue.Members(type, types, members);
			List<Pin> cases = scope .();
			for (let p in n.Outputs)
				if (p.Kind == .Exec && p.Name != "default" && p.Name != "then")
					cases.Add(p);
			List<String> present = scope .();
			defer { ClearAndDeleteItems!(present); }
			for (let p in cases)
			{
				if (!CaseFits(kind, type, p.Label, members))
					RemoveCase(g, n, p);
				else if (kind == .Enum)
					for (var part in p.Label.Split(','))
					{
						part.Trim();
						if (PinValue.EnumMemberOf(part, type, let m))
							present.Add(new String(m));
					}
			}
			if (kind == .Enum)
			{
				for (let m in members)
				{
					bool has = false;
					for (let x in present)
						if (x == m)
							has = true;
					if (!has)
						AddCase(g, n, scope $".{m}");
				}
			}
			else
			{
				bool anyLeft = false;
				for (let p in n.Outputs)
					if (p.Kind == .Exec && p.Name != "default" && p.Name != "then")
						anyLeft = true;
				if (!anyLeft)
				{
					String label = scope .();
					DefaultCaseLabel(kind, label);
					AddCase(g, n, label);
				}
			}
			n.Edited = true;
			g.Version++;
			return true;
		}

		/// Moves a case up (-1) or down (+1) among the cases; Default and Completed stay put.
		public static bool MoveCase(Graph g, Node n, Pin p, int delta)
		{
			let at = n.Outputs.IndexOf(p);
			if (at < 0)
				return false;
			int to = at + delta;
			if (to < 0 || to >= n.Outputs.Count)
				return false;
			let other = n.Outputs[to];
			if (other.Kind != .Exec || other.Name == "default" || other.Name == "then" || p.Name == "default" || p.Name == "then")
				return false;
			n.Outputs[at] = other;
			n.Outputs[to] = p;
			RenumberCases(n);
			n.Edited = true;
			g.Version++;
			return true;
		}

		/// A flow macro node (see FlowMacros). `ownerFields` are the state fields the enclosing
		/// type already has, so a new Do Once / Gate... gets a free name.
		public static Node Flow(Graph g, StringView macro, HashSet<String> ownerFields = null, int arms = 2)
		{
			Node n = NewExec(g, .Flow);
			FlowMacros.Setup(g, n, macro, arms);
			if (FlowMacros.IsStateful(macro))
			{
				String name = scope .();
				FlowMacros.FreshFieldName(g, FlowMacros.DefaultPrefix(macro), ownerFields, name);
				n.Text2.Set(name);
			}
			else if (FlowMacros.IsAction(macro))
			{
				// Aim at the first matching macro in the graph.
				let target = FlowMacros.TargetMacro(macro);
				for (let o in g.Nodes)
				{
					if (o != n && o.Kind == .Flow && o.Text == target)
					{
						n.Text2.Set(o.Text2);
						break;
					}
				}
			}
			return n;
		}

		// ------------------------------------------------------------------ lifetime nodes
		// docs/Lifetime-Nodes.md. Pins match GraphBuilder's, so each reads back as itself.

		/// The output type of a Construct: `T`, `T[]`, `String` for `scope $"..."`, empty for `.()`.
		public static void ConstructResultType(StringView typeText, bool isArray, String outType)
		{
			if (typeText.IsEmpty || typeText == ".")
				return;
			if (typeText == "$")
			{
				outType.Set("String");
				return;
			}
			outType.Set(typeText);
			if (isArray)
				outType.Append("[]");
		}

		/// `new T(args)` / `scope T(args)` / `scope:: T(args)` / `new:alloc T(args)` (`alloc` is the
		/// keyword as written), `alloc .(args)` for an empty or `.` type, `alloc T[n]` with
		/// `isArray` (one Count input), `alloc $"..."` for the type `$` (one Text input).
		public static Node Construct(Graph g, StringView typeText, StringView alloc, Span<StringView> paramNames, Span<StringView> paramTypes,
			bool isArray = false)
		{
			Node n = NewPure(g, .Construct);
			n.Text.Set(typeText.IsEmpty ? "." : typeText);
			n.Alloc = new String(alloc.IsEmpty ? "new" : alloc);
			n.IsArray = isArray;
			let r = g.AddDataOut(n, "result", "");
			ConstructResultType(n.Text, isArray, r.TypeName);
			if (isArray)
			{
				let p = g.AddDataIn(n, "arg0", "Count");
				p.TypeName.Set("int");
				p.Default.Set("1");
			}
			else if (n.Text == "$")
			{
				let p = g.AddDataIn(n, "arg0", "Text");
				p.TypeName.Set("String");
				p.Default.Set("$\"\"");
			}
			else
			{
				for (int i < paramNames.Length)
				{
					let p = g.AddDataIn(n, scope $"arg{i}", paramNames[i]);
					if (i < paramTypes.Length)
						p.TypeName.Set(paramTypes[i]);
				}
			}
			return n;
		}

		/// `delete x;` (`alloc` = `delete` or `delete:alloc`).
		public static Node Delete(Graph g, StringView alloc = "delete")
		{
			Node n = NewExec(g, .Delete);
			n.Alloc = new String(alloc.IsEmpty ? "delete" : alloc);
			g.AddDataIn(n, "value", "Object");
			g.AddExecOut(n, "then");
			return n;
		}

		/// `defer { ... }` (`alloc` = `defer`, `defer::`, `defer:label`).
		public static Node Defer(Graph g, StringView alloc = "defer")
		{
			Node n = NewExec(g, .Defer);
			n.Alloc = new String(alloc.IsEmpty ? "defer" : alloc);
			g.AddExecOut(n, "body", "Deferred");
			g.AddExecOut(n, "then", "Completed");
			return n;
		}

		/// `using (value) { ... }`, or `using (let name = value) { ... }` when `name` is given.
		public static Node Using(Graph g, StringView name = "", StringView type = "let")
		{
			Node n = NewExec(g, .Using);
			g.AddDataIn(n, "value", "Value");
			g.AddExecOut(n, "body", "Body");
			g.AddExecOut(n, "then", "Completed");
			if (!name.IsEmpty)
			{
				n.Text.Set(name);
				n.Text2.Set(type.IsEmpty ? "let" : type);
				let v = g.AddDataOut(n, "variable", name);
				if (type != "let" && type != "var")
				{
					v.TypeName.Set(type);
					n.FindInput("value").TypeName.Set(type);
				}
			}
			return n;
		}

		/// `if (value case .Ok(let v)) { Ok } else { Err }` (`okTest` false: `.Err` is tested).
		/// The payload pin is spelled by the generator: no binding while nothing reads it.
		public static Node ResultMatch(Graph g, bool okTest = true, StringView resultType = "")
		{
			Node n = NewExec(g, .ResultMatch);
			n.Text.Set(okTest ? "Ok" : "Err");
			let v = g.AddDataIn(n, "value", "Result");
			v.TypeName.Set(resultType);
			g.AddExecOut(n, "ok", "Ok");
			g.AddExecOut(n, "err", "Err");
			g.AddExecOut(n, "then", "Completed");
			let p = g.AddDataOut(n, "payload", okTest ? "Value" : "Error");
			p.Mode = .Out;
			p.Form = .Discard;
			p.OutAuto = true;
			SetResultPayloadType(n);
			return n;
		}

		/// The payload pin's type from the value pin's `Result<T>` / `Result<T, E>`.
		public static void SetResultPayloadType(Node n)
		{
			let v = n.FindInput("value");
			let p = n.FindOutput("payload");
			if (v == null || p == null)
				return;
			p.TypeName.Clear();
			if (VisualBeef.Catalog.TypeRules.BaseName(v.TypeName) != "Result")
				return;
			List<StringView> args = scope .();
			VisualBeef.Catalog.TypeRules.GenericArgs(v.TypeName, args);
			int i = (n.Text == "Err") ? 1 : 0;
			if (i < args.Count)
				p.TypeName.Set(args[i]);
		}

		/// Switches which case a Result node tests (`Ok` <-> `Err`): the arms keep their wires, the
		/// payload pin becomes the other case's value (its wires are dropped).
		public static void SetResultCase(Graph g, Node n, bool okTest)
		{
			if (n.Kind != .ResultMatch || (n.Text != "Err") == okTest)
				return;
			n.Text.Set(okTest ? "Ok" : "Err");
			let p = n.FindOutput("payload");
			if (p != null)
			{
				g.DisconnectPin(p);
				p.Label.Set(okTest ? "Value" : "Error");
				p.Form = .Discard;
				p.OutAuto = true;
				DeleteAndNullify!(p.OutName);
			}
			SetResultPayloadType(n);
			n.Edited = true;
			g.Version++;
		}

		/// A Return placed in a function that returns `returnType` starts with that type's default
		/// value (ReturnDefault), so a fresh function compiles.
		public static Node Return(Graph g, StringView returnType)
		{
			Node n = NewExec(g, .Return);
			let v = g.AddDataIn(n, "value", "Return Value");
			v.Optional = true;
			v.TypeName.Set(returnType);
			ReturnDefault(returnType, v.Default);
			g.AddExecOut(n, "then");
			return n;
		}

		/// The Return node's output pins, one per `out` parameter of `method` (`out:<name>`, labelled
		/// with the name): a Return writes `name = value;` for each pin that has a value, then
		/// `return`. `withDefaults`: a placed Return starts each with its type's default.
		public static void AddReturnOutPins(Graph g, Node n, Member method, bool withDefaults)
		{
			if (method == null || method.Params == null)
				return;
			for (let p in method.Params)
			{
				if (p.Modifier != "out" || p.Name.IsEmpty)
					continue;
				let pin = g.AddDataIn(n, scope $"out:{p.Name}", p.Name);
				pin.Optional = true;
				pin.TypeName.Set(p.Type);
				if (withDefaults)
					ReturnDefault(p.Type, pin.Default);
			}
		}

		/// After the function's outputs changed (Properties > Outputs): every Return of the function
		/// (not those inside a lambda or local function) has one input per `out` parameter, in
		/// order; a new one starts with its type's default so the function still compiles, one
		/// that is gone is removed. True when a Return changed.
		public static bool SyncReturnOutPins(Graph g, Member method)
		{
			if (g == null || method == null)
				return false;
			HashSet<Node> nested = scope .();
			for (let n in g.Nodes)
				if (n.Kind == .Lambda || n.Kind == .LocalFunc)
					g.GetInside(n, nested);
			bool any = false;
			for (let n in g.Nodes)
			{
				if (n.Kind != .Return || nested.Contains(n))
					continue;
				List<Pin> old = scope .();
				for (let p in n.Inputs)
					if (p.Name.StartsWith("out:"))
						old.Add(p);
				List<Pin> ordered = scope .();
				bool changed = false;
				if (method.Params != null)
				{
					for (let prm in method.Params)
					{
						if (prm.Modifier != "out" || prm.Name.IsEmpty)
							continue;
						Pin found = null;
						for (let p in old)
							if (StringView(p.Name, 4) == prm.Name)
								found = p;
						if (found == null)
						{
							found = g.AddDataIn(n, scope $"out:{prm.Name}", prm.Name);
							found.Optional = true;
							ReturnDefault(prm.Type, found.Default);
							n.Inputs.Remove(found);
							changed = true;
						}
						else if (found.TypeName != prm.Type)
							changed = true;
						found.TypeName.Set(prm.Type);
						ordered.Add(found);
					}
				}
				for (let p in old)
				{
					if (ordered.Contains(p))
						continue;
					g.RemovePin(p);
					changed = true;
				}
				for (let p in ordered)
					n.Inputs.Remove(p);
				for (let p in ordered)
					n.Inputs.Add(p);
				if (!changed)
				{
					// Same pins: only their order may have changed.
					for (int i < Math.Min(old.Count, ordered.Count))
						if (old[i] != ordered[i])
							changed = true;
				}
				if (changed)
				{
					n.Edited = true;
					any = true;
				}
			}
			if (any)
				g.Version++;
			return any;
		}

		/// The value a new Return starts with: `false` for bool, `0` for numbers, `null` for classes,
		/// interfaces, delegates, arrays, pointers and nullables, `default` for structs, enums,
		/// characters and types not known; nothing for `void`, `var` and `ref` returns (a `ref`
		/// return needs a variable).
		public static void ReturnDefault(StringView returnType, String outValue)
		{
			var t = returnType;
			t.Trim();
			if (t.IsEmpty || t == "void" || t == "var" || t == "let" || t.StartsWith("ref ") || t.StartsWith("mut "))
				return;
			switch (t)
			{
			case "bool":
				outValue.Append("false");
				return;
			case "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "intptr", "uintptr", "float", "double":
				outValue.Append("0");
				return;
			case "String", "Object", "System.String", "System.Object", "StringView", "System.StringView":
				outValue.Append((t.EndsWith("StringView")) ? "default" : "null");
				return;
			default:
			}
			if (t.EndsWith("]") || t.EndsWith("*") || t.EndsWith("?"))
			{
				outValue.Append("null");
				return;
			}
			String kind = scope .();
			if (VisualBeef.Catalog.TypeService.Current != null)
				VisualBeef.Catalog.TypeService.Current.KindOf(t, kind);
			if (kind == "class" || kind == "interface" || kind == "delegate" || kind == "function")
				outValue.Append("null");
			else
				outValue.Append("default");
		}

		public static Node Jump(Graph g, NodeKind kind)
		{
			Node n = NewExec(g, kind);
			g.AddExecOut(n, "then");
			return n;
		}

		public static Node Code(Graph g, StringView code)
		{
			Node n = NewExec(g, .Code);
			n.Text.Set(code);
			g.AddExecOut(n, "then");
			return n;
		}

		/// A new Local of the function (Graph.Locals, written at the top of the body after the
		/// others): `type name = value;`, or `type name;` with no value. Not a node on the Sheet.
		public static Node AddLocal(Graph g, StringView name, StringView type, StringView value = "", int index = -1)
		{
			let n = LocalVar(g, name, type);
			n.FindInput("value").Default.Set(value);
			g.Nodes.Remove(n);
			n.Edited = true;
			n.Moved = true;
			if (index >= 0 && index <= g.Locals.Count)
				g.Locals.Insert(index, n);
			else
				g.Locals.Add(n);
			g.Version++;
			return n;
		}

		/// `type name = value;`; `modifier` = `const` or `ref` puts that word in front.
		public static Node LocalVar(Graph g, StringView name, StringView type, StringView modifier = "")
		{
			Node n = NewExec(g, .LocalVar);
			n.Text.Set(name);
			n.Text2.Set(type);
			if (!modifier.IsEmpty)
				n.Alloc = new String(modifier);
			g.AddExecOut(n, "then");
			let varOut = g.AddDataOut(n, "variable", name);
			if (type != "let" && type != "var")
				varOut.TypeName.Set(type);
			let v = g.AddDataIn(n, "value", "Value");
			v.Optional = true;
			if (type != "let" && type != "var")
				v.TypeName.Set(type);
			return n;
		}

		public static Node Set(Graph g, StringView target, StringView typeName, StringView op = "=")
		{
			Node n = NewExec(g, .Set);
			n.Text.Set(op);
			g.AddExecOut(n, "then");
			let t = g.AddDataIn(n, "target", "Variable"); // what is set, not a call's Receiver
			t.Default.Set(target);
			t.TypeName.Set(typeName);
			if (op != "++" && op != "--")
			{
				let v = g.AddDataIn(n, "value", "Value");
				v.TypeName.Set(typeName);
			}
			else
				n.Postfix = true;
			return n;
		}

		public static Node Get(Graph g, StringView name, StringView typeName)
		{
			Node n = NewPure(g, .Get);
			n.Text.Set(name);
			let r = g.AddDataOut(n, "result", "");
			r.TypeName.Set(typeName);
			return n;
		}

		/// Member access on an arbitrary target: `<target>.name`
		public static Node GetMember(Graph g, StringView name)
		{
			Node n = NewPure(g, .Get);
			n.Text.Set(name);
			g.AddDataIn(n, "target", "Receiver");
			g.AddDataOut(n, "result", "");
			return n;
		}

		public static Node Operator(Graph g, StringView op, bool binary)
		{
			Node n = NewPure(g, .Operator);
			n.Text.Set(op);
			g.AddDataIn(n, "a", "");
			if (binary)
				g.AddDataIn(n, "b", "");
			let r = g.AddDataOut(n, "result", "");
			if (op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=" || op == "&&" || op == "||" || op == "!")
				r.TypeName.Set("bool");
			return n;
		}

		public static Node Select(Graph g)
		{
			Node n = NewPure(g, .Select);
			let c = g.AddDataIn(n, "condition", "Condition");
			c.TypeName.Set("bool");
			g.AddDataIn(n, "a", "True");
			g.AddDataIn(n, "b", "False");
			g.AddDataOut(n, "result", "");
			return n;
		}

		public static Node Cast(Graph g, StringView type)
		{
			Node n = NewPure(g, .Cast);
			n.Text.Set(type);
			g.AddDataIn(n, "value", "Value");
			let r = g.AddDataOut(n, "result", "");
			if (type != ".")
				r.TypeName.Set(type); // `(.)x` takes the type of where the value goes
			return n;
		}

		/// A nested block `{ ... }` with its own scope (statements hang off Body).
		public static Node Scope(Graph g)
		{
			Node n = NewExec(g, .Scope);
			g.AddExecOut(n, "body", "Body");
			g.AddExecOut(n, "then", "Completed");
			return n;
		}

		/// A lambda `alloc captures (params) => ...`: `block` gives it a Body (statements), else a
		/// Returns input (an expression). `paramText` is the list as written, `(a, b)` or `x`.
		public static Node Lambda(Graph g, StringView paramText, bool block, StringView alloc = "", StringView captures = "")
		{
			Node n = NewPure(g, .Lambda);
			n.Alloc = new String(alloc);
			if (!captures.IsEmpty)
				n.Attributes = new String(captures);
			n.Text.Set(paramText.IsEmpty ? "()" : paramText);
			g.AddDataOut(n, "result", "");
			var inner = n.Text.Substring(0);
			if (inner.StartsWith('(') && inner.EndsWith(')'))
				inner = inner.Substring(1, inner.Length - 2);
			List<(StringView name, StringView type)> ps = scope .();
			GraphBuilder.SplitParams(inner, ps);
			for (let p in ps)
			{
				let pin = g.AddDataOut(n, scope $"param{@p.Index}", p.name);
				pin.TypeName.Set(p.type);
			}
			if (block)
				g.AddExecOut(n, "body", "Body");
			else
				g.AddDataIn(n, "expr", "Returns");
			return n;
		}

		/// `alloc => Method`: a delegate bound to a method (UE's Create Event).
		public static Node DelegateOf(Graph g, StringView method, StringView alloc = "")
		{
			Node n = NewPure(g, .Lambda);
			n.Alloc = new String(alloc);
			n.Text2.Set(method);
			g.AddDataOut(n, "result", "");
			return n;
		}

		/// A local function `header { ... }` (`void Log(String s)`), or `header => expr;` when
		/// `block` is false. Its parameters are outputs for reference, read by name inside.
		public static Node LocalFunc(Graph g, StringView header, bool block = true)
		{
			Node n = NewExec(g, .LocalFunc);
			n.Text2.Set(header);
			g.AddExecOut(n, "then");
			int open = header.IndexOf('(');
			if (open > 0)
			{
				var before = header.Substring(0, open);
				before.Trim();
				int s = before.Length;
				while (s > 0 && CharUtil.IsIdentChar(before[s - 1]))
					s--;
				n.Text.Set(before.Substring(s));
				if (header.EndsWith(')'))
				{
					List<(StringView name, StringView type)> ps = scope .();
					GraphBuilder.SplitParams(header.Substring(open + 1, header.Length - open - 2), ps);
					for (let p in ps)
					{
						let pin = g.AddDataOut(n, scope $"param{@p.Index}", p.name);
						pin.TypeName.Set(p.type);
					}
				}
			}
			if (block)
				g.AddExecOut(n, "body", "Body");
			else
				g.AddDataIn(n, "expr", "Returns");
			return n;
		}

		/// The parameter types of an overload signature `Name(int a, ref float b)`, modifiers
		/// kept apart (`ref`, `out`, `params`).
		public static void OverloadParams(StringView signature, List<(StringView type, StringView modifier, StringView name)> outParams)
		{
			int open = signature.IndexOf('(');
			if (open < 0 || !signature.EndsWith(')'))
				return;
			let inner = signature.Substring(open + 1, signature.Length - open - 2);
			List<(StringView name, StringView type)> ps = scope .();
			GraphBuilder.SplitParams(inner, ps);
			// SplitParams drops the modifiers from the type; find them again in the text.
			int partStart = 0;
			int depth = 0;
			int pi = 0;
			for (int i <= inner.Length)
			{
				char8 c = (i < inner.Length) ? inner[i] : ',';
				if (c == '(' || c == '<' || c == '[')
					depth++;
				else if (c == ')' || c == '>' || c == ']')
					depth--;
				else if (c == ',' && depth <= 0)
				{
					var part = inner.Substring(partStart, i - partStart);
					part.Trim();
					partStart = i + 1;
					if (part.IsEmpty || pi >= ps.Count)
						continue;
					StringView modifier = "";
					for (let mod in StringView[?]("ref ", "out ", "in ", "params "))
						if (part.StartsWith(mod))
							modifier = mod.Substring(0, mod.Length - 1);
					outParams.Add((ps[pi].type, modifier, ps[pi].name));
					pi++;
				}
			}
		}

		/// Makes an ambiguous call choose `signature`: a Cast to that overload's parameter type is
		/// put on every argument where the tied overloads differ (Beef has no syntax to name an
		/// overload, so a cast on the argument is how the choice is written). The argument pins
		/// take the overload's names and types. False (with the reason) when no argument tells
		/// the overloads apart (they differ by out / ref, or the argument is an out pin): the
		/// call then keeps its warning with the candidates listed.
		public static bool PickOverload(Graph g, Node call, StringView signature, String outWhy)
		{
			if (call.Overloads == null || call.Overloads.Count < 2)
			{
				outWhy.Set("This call has no other overload to choose.");
				return false;
			}
			List<(StringView type, StringView modifier, StringView name)> chosen = scope .();
			OverloadParams(signature, chosen);
			List<List<(StringView type, StringView modifier, StringView name)>> others = scope .();
			List<StringView> otherSigs = scope .();
			defer { for (let o in others) delete o; }
			for (let s in call.Overloads)
			{
				if (s == signature)
					continue;
				otherSigs.Add(s);
				let l = new List<(StringView type, StringView modifier, StringView name)>();
				OverloadParams(s, l);
				others.Add(l);
			}
			List<Pin> args = scope .();
			call.GetArgPins(args);
			// Which arguments tell the chosen overload apart from each other one.
			List<int> castAt = scope .();
			for (let o in others)
			{
				bool told = false;
				for (int i < Math.Min(args.Count, chosen.Count))
				{
					if (i >= o.Count || o[i].type == chosen[i].type)
						continue;
					if (args[i].IsOutArg || chosen[i].modifier == "out" || chosen[i].modifier == "ref")
						continue; // `out` / `ref` arguments cannot be cast
					if (!castAt.Contains(i))
						castAt.Add(i);
					told = true;
				}
				if (!told)
				{
					outWhy.AppendF("No argument tells {} from {}: they differ by out / ref or not by type. Edit the call in the text.", signature, otherSigs[@o.Index]);
					return false;
				}
			}
			for (let i in castAt)
			{
				let pin = args[i];
				let src = g.DataSource(pin);
				if (src != null && src.Kind == .Cast && src.Text == chosen[i].type)
					continue;
				let cast = Cast(g, chosen[i].type);
				cast.X = call.X - 180;
				cast.Y = call.Y + 60 + 50 * i;
				cast.HasPos = call.HasPos;
				let value = cast.FindInput("value");
				if (src != null)
				{
					let link = g.FindLinkTo(pin);
					let from = link.From;
					g.Disconnect(link);
					g.Connect(from, value);
				}
				else
				{
					value.Default.Set(pin.Default);
					pin.Default.Clear();
				}
				g.Connect(cast.Result, pin);
			}
			for (int i < Math.Min(args.Count, chosen.Count))
			{
				args[i].Label.Set(chosen[i].name);
				args[i].TypeName.Set(chosen[i].type);
			}
			// The pick goes first: it is what the node now calls.
			for (let s in call.Overloads)
			{
				if (s == signature)
				{
					let keep = new String(s);
					call.Overloads.Remove(s);
					delete s;
					call.Overloads.Insert(0, keep);
					break;
				}
			}
			call.Ambiguous = false;
			call.Edited = true;
			return true;
		}

		/// After the parameter text of a Lambda or the header of a Local Function changed: one
		/// `param<i>` output per parameter (wires from a parameter that is still there are kept).
		public static void SyncParams(Graph g, Node n)
		{
			StringView text = (n.Kind == .LocalFunc) ? (StringView)n.Text2 : (StringView)n.Text;
			int open = text.IndexOf('(');
			StringView inner = text;
			if (open >= 0 && text.EndsWith(')'))
				inner = text.Substring(open + 1, text.Length - open - 2);
			else if (n.Kind == .LocalFunc)
				inner = "";
			List<(StringView name, StringView type)> ps = scope .();
			GraphBuilder.SplitParams(inner, ps);
			for (int i = n.Outputs.Count - 1; i >= 0; i--)
			{
				let p = n.Outputs[i];
				if (p.Kind != .Data || !p.Name.StartsWith("param"))
					continue;
				int idx = -1;
				if (int.Parse(p.Name.Substring(5)) case .Ok(let v))
					idx = v;
				if (idx < 0 || idx >= ps.Count)
					g.RemovePin(p);
			}
			for (let p in ps)
			{
				var pin = n.FindOutput(scope $"param{@p.Index}");
				if (pin == null)
					pin = g.AddDataOut(n, scope $"param{@p.Index}", p.name);
				pin.Label.Set(p.name);
				pin.TypeName.Set(p.type);
			}
			if (n.Kind == .LocalFunc)
			{
				var before = text.Substring(0, Math.Max(open, 0));
				before.Trim();
				int s = before.Length;
				while (s > 0 && CharUtil.IsIdentChar(before[s - 1]))
					s--;
				n.Text.Set(before.Substring(s));
			}
		}

		/// After a Format node's text changed: one `arg<i>` input per hole.
		public static void SyncHoles(Graph g, Node n)
		{
			List<(int exprStart, int exprEnd, int holeStart, int holeEnd)> holes = scope .();
			CodeGen.SplitInterpolatedTemplate(n.Text, holes);
			for (int i = n.Inputs.Count - 1; i >= 0; i--)
			{
				let p = n.Inputs[i];
				if (p.ArgIndex >= holes.Count)
					g.RemovePin(p);
			}
			for (int i < holes.Count)
				if (n.FindInput(scope $"arg{i}") == null)
					g.AddDataIn(n, scope $"arg{i}", scope $"{{{i}}}");
		}

		/// An interpolated string from a template with empty holes (`$"x = {}, hex {:X2}"`): one
		/// input per hole.
		public static Node Format(Graph g, StringView template)
		{
			Node n = NewPure(g, .Format);
			n.Text.Set(template);
			List<(int exprStart, int exprEnd, int holeStart, int holeEnd)> holes = scope .();
			CodeGen.SplitInterpolatedTemplate(n.Text, holes);
			for (int i < holes.Count)
				g.AddDataIn(n, scope $"arg{i}", scope $"{{{i}}}");
			let r = g.AddDataOut(n, "result", "");
			r.TypeName.Set("String");
			return n;
		}

		/// A Math Expression (docs/Math-Expression.md): one input per free name of `expression`, the
		/// `result` output typed from the expression where it can be told. A refused expression
		/// still makes the node (no pins; it shows the error until the text is fixed).
		public static Node MathExpr(Graph g, StringView expression)
		{
			Node n = NewPure(g, .MathExpr);
			var text = expression;
			text.Trim();
			n.Text.Set(text);
			g.AddDataOut(n, "result", "");
			MathExpression.Sync(g, n);
			return n;
		}

		/// After a Math Expression's text or result type changed: pins and types follow it.
		/// False (with the reason) when the new text is refused; the pins are then left as they were.
		public static bool SyncMath(Graph g, Node n, String outWhy = null)
		{
			String why = scope .();
			MathExpression.Sync(g, n, why);
			n.Edited = true;
			outWhy?.Set(why);
			return why.IsEmpty;
		}

		public static Node Index(Graph g)
		{
			Node n = NewPure(g, .Index);
			g.AddDataIn(n, "target", "Receiver");
			g.AddDataIn(n, "arg0", "Index");
			g.AddDataOut(n, "result", "");
			return n;
		}

		public static Node Expr(Graph g, StringView code)
		{
			Node n = NewPure(g, .Expr);
			n.Text.Set(code);
			g.AddDataOut(n, "result", "");
			return n;
		}
	}
}
