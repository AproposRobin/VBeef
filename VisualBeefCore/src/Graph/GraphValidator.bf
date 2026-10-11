using System;
using System.Collections;
using VisualBeef.Catalog;
using VisualBeef.Syntax;
using VisualBeef.Document;

namespace VisualBeef.Graph
{
	/// Checks a graph the way Blueprint's compiler checks a Blueprint: it runs after every edit
	/// (as the first step of CodeGen.GenerateBody, so before any code is written) and reports
	/// problems on the node at fault. Errors (Graph.Errors) refuse the commit, exactly like the
	/// generator's own refusals; warnings (Graph.Warnings) are shown but never block.
	///
	/// What it checks (see docs/Calls-and-Receivers.md):
	///  - a member call whose Receiver is left unconnected means `this` ("self"): an error when
	///    there is no `this` (static method, no type) or `this` is not of the function's type;
	///  - a wired Target (wired after the code was read) whose value is of an unrelated type;
	///  - inputs that need a value and have neither a wire nor a typed value;
	///  - `ref` arguments whose source is not something assignable;
	///  - wires made in the editor and typed values on new nodes whose types are known not to
	///    convert.
	/// Anything the resolver could not resolve (unknown owner, unknown self type, unknown
	/// types) is never an error: the compiler stays the judge.
	static class GraphValidator
	{
		/// Validates `nodes` (the nodes that produce code; null = every node of the graph).
		public static void Validate(Graph g, HashSet<Node> nodes = null)
		{
			for (let n in g.Nodes)
			{
				if (nodes != null && !nodes.Contains(n))
					continue;
				if (n.Kind == .Call)
					CheckCall(g, n);
				else if (n.Kind == .Base)
					ClassModel.CheckBaseNode(g, n);
				if (n.Kind == .Construct || n.Kind == .Delete)
					CheckLifetime(g, n);
				CheckLibraryRules(g, n);
				CheckInputs(g, n);
				CheckNodeType(g, n);
				CheckWritable(g, n);
			}
			// The declaration itself: `override` needs something to override (ClassModel).
			ClassModel.CheckEntry(g);
		}

		/// A Node Library holds only static functions and variables: no `this` inside it, and the
		/// library itself is never constructed. An error on a node made in the editor, a note on
		/// one read from code (the code is kept as written).
		static void CheckLibraryRules(Graph g, Node n)
		{
			String msg = scope .();
			if (n.Kind == .This && g.InLibrary)
				msg.AppendF("There is no this in {}: a Node Library holds only static functions and variables, so there is no object to refer to.", g.SelfType);
			else if (n.Kind == .Construct && !n.IsArray && !n.Text.IsEmpty && n.Text != "$" && n.Text != ".")
			{
				let index = GraphBuilder.Index;
				let st = (index == null) ? null : index.FindType(n.Text);
				if (st != null && st.Kind == "class" && st.IsStaticType)
					msg.AppendF("{} is a Node Library: it cannot be constructed. Call its functions and read its variables directly.", n.Text);
			}
			if (msg.IsEmpty)
				return;
			if (n.Edited || n.Original == null)
				g.AddError(n, msg);
			else
				g.AddWarning(n, msg);
		}

		/// The type written on a node must fit its place (TypeSlotRules): a local variable is never
		/// `void`, a Cast never `var`. Typed in the editor it is an error (nothing is written); read
		/// from code as it is, a warning on the node.
		static void CheckNodeType(Graph g, Node n)
		{
			TypeSlot slot;
			StringView type;
			StringView what;
			switch (n.Kind)
			{
			case .LocalVar: slot = .Local; type = n.Text2; what = "Variable Type";
			case .ForEach: slot = .ForEach; type = n.Text2; what = "Element Type";
			case .For:
				if (!n.IsCountingLoop)
					return;
				slot = .Local; type = n.Text2; what = "Counter Type";
			case .Cast:
				slot = .Cast; type = n.Text; what = "Cast To";
				if (type == "." || type == "(.)")
					return;
			case .Construct:
				slot = .Construct; type = n.Text; what = "Construct Type";
				if (type == "$" || type == "." || type == "(.)")
					return;
			default: return;
			}
			type.Trim();
			if (type.IsEmpty)
				return;
			TypeScope sc = default;
			sc.InType = true;
			String why = scope .();
			if (TypeSlotRules.Check(type, slot, sc, why))
				return;
			if (n.Edited)
				g.AddError(n, scope $"{what} {why}");
			else
				g.AddWarning(n, scope $"{what} {why}");
		}

		/// Node settings the writer cannot turn into code. Each one is an error on the node (the
		/// commit is refused and the Problems list has a row): nothing is ever left out silently.
		static bool Blank(StringView text)
		{
			var t = text;
			t.Trim();
			return t.IsEmpty;
		}

		/// A class of the project whose constructors all need inputs: `new T()` does not compile.
		/// Null when the type has a constructor without inputs (or none at all, or is not known).
		public static SymbolType NeedsConstructorChoice(StringView typeText)
		{
			let index = GraphBuilder.Index;
			if (index == null || typeText.IsEmpty || typeText.Contains('<') || typeText.Contains('['))
				return null;
			let st = index.FindType(typeText);
			if (st == null || st.Kind != "class")
				return null;
			bool any = false;
			for (let m in st.Methods)
			{
				if (!m.IsCtor || m.IsStatic)
					continue;
				any = true;
				bool none = true;
				for (int i < m.ParamNames.Count)
				{
					bool optional = (i < m.ParamDefaults.Count && !m.ParamDefaults[i].IsEmpty) || (i < m.ParamModifiers.Count && m.ParamModifiers[i] == "params");
					if (!optional)
						none = false;
				}
				if (none)
					return null;
			}
			return any ? st : null;
		}

		static void CheckWritable(Graph g, Node n)
		{
			switch (n.Kind)
			{
			case .Construct:
				if (!n.IsArray && n.ArgCount == 0 && n.Text != "$")
				{
					let st = NeedsConstructorChoice(n.Text);
					if (st != null)
					{
						let msg = scope $"{st.Name} needs a constructor: choose one in Properties > Constructor (every constructor of {st.Name} takes inputs, so `{n.Text}()` does not compile).";
						if (n.Edited)
							g.AddError(n, msg);
						else
							g.AddWarning(n, msg);
					}
				}
				// `new .(1)` / `scope .()` take their type from where the value goes: a Receiver
				// has none, so the text would not compile.
				if (n.Text == "." || n.Text == "(.)" || n.Text.IsEmpty)
				{
					if (n.Result != null)
						for (let l in g.Links)
						{
							if (l.From != n.Result || l.To.Name != "target")
								continue;
							if (l.To.Owner.Kind == .Call || l.To.Owner.Kind == .Get || l.To.Owner.Kind == .Index || l.To.Owner.Kind == .Set)
							{
								g.AddError(n, "A Construct without a Type cannot be used as a Receiver: the type is taken from where the value goes, and a Receiver has none. Give it a Type, or wire it through a Local Variable.");
								break;
							}
						}
				}
			case .LocalVar, .ForEach:
				if (Blank(n.Text))
					g.AddError(n, "This node has no name: type one in Properties.");
			case .For:
				if (n.IsCountingLoop && Blank(n.Text))
					g.AddError(n, "This loop's counter has no name: type one in Properties.");
			case .Call, .Get:
				// An empty-named call is an Invoke (`mDelegate()`): it needs something to invoke.
				if (Blank(n.Text) && (n.Kind == .Get || n.FindInput("target") == null || (g.FindLinkTo(n.FindInput("target")) == null && n.FindInput("target").Default.IsEmpty)))
					g.AddError(n, (n.Kind == .Call) ? "This call has no function name: type one in Properties." : "This Get has no name: type the variable or field it reads.");
			case .Cast:
				if (Blank(n.Text))
					g.AddError(n, "This Cast has no type: type one in Properties.");
			case .Code:
				if (Blank(n.Text))
					g.AddWarning(n, "This Code node is empty: nothing is written for it.");
			default:
			}
		}

		// ------------------------------------------------------------------ messages

		/// "a Player" / "an Enemy".
		public static void Article(StringView typeName, String o)
		{
			bool vowel = !typeName.IsEmpty && "AEIOUaeiou".Contains(typeName[0]);
			o.Append(vowel ? "an " : "a ");
			o.Append(typeName);
		}

		/// The function is called with self, but the method is static (or there is no type).
		public static void TargetStaticMessage(StringView owner, String o)
		{
			o.Append("Receiver must be ");
			Article(owner, o);
			o.Append(": this function is static, so there is no this.");
		}

		/// The function is called with self, but self is of another type.
		public static void TargetSelfMessage(StringView owner, StringView selfType, String o)
		{
			o.Append("Receiver must be ");
			Article(owner, o);
			o.Append("; this is ");
			Article(selfType, o);
			o.Append(".");
		}

		/// The wire into Target brings a value of another type.
		public static void TargetWireMessage(StringView owner, StringView wired, String o)
		{
			o.Append("Receiver must be ");
			Article(owner, o);
			o.Append("; the wire brings ");
			Article(wired, o);
			o.Append(".");
		}

		// ------------------------------------------------------------------ calls

		static StringView Display(StringView typeName) => TypeRules.BaseName(typeName);

		/// `String.AppendF`: it returns a Result<void> only to report a format string that does not
		/// match its arguments, a mistake in the text itself that is found the first time the line
		/// runs, not a failure to react to at run time. Nobody wires it, so it carries no note
		/// (every other Result keeps its note).
		static bool IsFormatCall(Node n)
		{
			return n.Text == "AppendF" && n.OwnerType != null && TypeRules.BaseName(n.OwnerType) == "String";
		}

		static void CheckCall(Graph g, Node n)
		{
			// A call that returns a Result (Ok / Err) whose return pin nothing reads: a failure
			// goes by unseen. Nothing is wrong with the text, so this is a note, not an error.
			if (n.Result != null && n.Result.TypeName.StartsWith("Result<") && g.FindLinkFrom(n.Result) == null && !IsFormatCall(n))
				g.AddWarning(n, scope $"'{n.Text}' returns a {n.Result.TypeName} that nothing reads, so a failure goes unnoticed. Wire its return pin into a Result: match node to react to Ok and Err, or use the Try version of the function (it returns a bool and logs the failure).");
			if (n.Ambiguous && n.Edited)
			{
				String list = scope .();
				if (n.Overloads != null)
					for (let s in n.Overloads)
						list.AppendF("\n  {}", s);
				g.AddWarning(n, scope $"Several overloads of '{n.Text}' fit these arguments equally well. Pick one in Properties (a Cast is added on the argument that tells them apart), or add a Cast yourself.{list}");
			}
			if (n.Binding == .Unresolved && n.Original == null && n.Edited && n.FindInput("target") == null)
				g.AddWarning(n, scope $"'{n.Text}' is not a known function here. It is written as typed; the compiler will check it.");

			if (n.Binding != .Instance || n.OwnerType == null || n.OwnerType.IsEmpty)
				return;
			let target = n.FindInput("target");
			if (target == null)
				return;
			let owner = Display(n.OwnerType);
			let link = g.FindLinkTo(target);
			if (link == null)
			{
				if (!target.Default.IsEmpty)
					return; // written target text (`base`, an unresolved name): the compiler checks it
				String msg = scope .();
				if (g.StaticContext)
					TargetStaticMessage(owner, msg);
				else if (!SelfIs(g.SelfType, n.OwnerType))
					TargetSelfMessage(owner, Display(g.SelfType), msg);
				if (!msg.IsEmpty)
					g.AddError(n, msg);
				return;
			}
			if (link.Parsed)
				return;
			// A wire made in the editor: the value must be an owner (pointers and nullables
			// reach their members directly).
			String from = scope .();
			StripIndirection(link.From.TypeName, from);
			if (from.IsEmpty || TypeRules.IsWildcard(from) || !IsKnownType(from) || !IsKnownType(n.OwnerType))
				return;
			if (TypeRules.BaseName(from) == TypeRules.BaseName(n.OwnerType))
				return;
			if (TypeRules.CanConvert(from, n.OwnerType) == .Refused)
			{
				String msg = scope .();
				TargetWireMessage(owner, Display(from), msg);
				g.AddError(n, msg);
			}
		}

		static void StripIndirection(StringView type, String outType)
		{
			outType.Append(type);
			outType.Trim();
			while (outType.EndsWith('*') || outType.EndsWith('?'))
			{
				outType.RemoveFromEnd(1);
				outType.Trim();
			}
		}

		/// A type the resolver knows (a declaration was found).
		static bool IsKnownType(StringView type)
		{
			let h = TypeRules.Hierarchy;
			if (h == null)
				return false;
			String kind = scope .();
			h.KindOf(type, kind);
			return !kind.IsEmpty;
		}

		/// Self (the type the graph's method belongs to) is the owner or derives from it. True
		/// when it can't be told (unresolved types are never an error).
		static bool SelfIs(StringView selfType, StringView owner)
		{
			if (selfType.IsEmpty)
				return false;
			if (TypeRules.BaseName(selfType) == TypeRules.BaseName(owner))
				return true;
			let h = TypeRules.Hierarchy;
			if (h == null || !IsKnownType(selfType) || !IsKnownType(owner))
				return true;
			return h.IsSubtype(selfType, owner);
		}

		// ------------------------------------------------------------------ lifetime
		// The graph-only lifetime rules (docs/Lifetime-Nodes.md); the ones that need to know which
		// block a statement is written in run in CodeGen's planning pass (AnalyzeLifetimes).

		static bool IsScopeAlloc(Node n) => n != null && n.Kind == .Construct && n.Alloc != null && n.Alloc.StartsWith("scope");

		/// The root name a Get node reads (`a` for `a` and `a.b`), when it reads a plain name.
		static StringView RootName(Node get)
		{
			if (get.Kind != .Get || get.FindInput("target") != null)
				return default;
			StringView t = get.Text;
			int dot = t.IndexOf('.');
			if (dot >= 0)
				t = t.Substring(0, dot);
			t.Trim();
			return t;
		}

		/// The Local Variable `name` is initialised from `src` (a Construct), or null.
		static Node LocalOf(Graph g, StringView name)
		{
			let local = g.FindLocal(name);
			if (local != null)
				return local;
			for (let n in g.Nodes)
				if (n.Kind == .LocalVar && n.Text == name)
					return n;
			return null;
		}

		static void CheckLifetime(Graph g, Node n)
		{
			if (n.Kind == .Delete)
			{
				// Deleting a `scope` value frees it twice.
				let src = g.DataSource(n.FindInput("value"));
				Node alloc = IsScopeAlloc(src) ? src : null;
				if (alloc == null && src != null)
				{
					StringView name = (src.Kind == .LocalVar) ? (StringView)src.Text : RootName(src);
					let local = name.IsEmpty ? null : LocalOf(g, name);
					if (local != null)
					{
						let init = g.DataSource(local.FindInput("value"));
						if (IsScopeAlloc(init))
							alloc = init;
					}
				}
				if (alloc != null)
					g.AddWarning(n, "Deletes a value allocated with `scope`: it is freed when its block ends anyway, so this frees it twice.");
				return;
			}
			// Construct: `new` with nothing that deletes it or takes it over is a warning (never an
			// error: Beef has many legitimate ownership patterns the graph can't see, such as a
			// thread started with auto-delete). Only for nodes made in the editor: code as read is
			// the author's decision.
			if (n.Alloc != "new" || n.Result == null || n.Original != null)
				return;
			List<Link> outs = scope .();
			g.FindLinksFrom(n.Result, outs);
			if (outs.IsEmpty)
				return;
			bool leak = true;
			for (let l in outs)
			{
				let to = l.To;
				let owner = to.Owner;
				if (IsMemberUse(owner, to))
					continue;
				if (owner.Kind == .LocalVar && to.Name == "value")
				{
					if (!LocalOwned(g, owner))
						continue;
				}
				leak = false;
			}
			if (leak)
				g.AddWarning(n, "Nothing deletes this object: it is allocated with `new` and only used here. Add a Delete (or Defer -> Delete), allocate it with `scope`, or hand it to an owner.");
		}

		/// The input only reads a member of the value (a call's Target, a Get's target).
		static bool IsMemberUse(Node owner, Pin to)
		{
			return to.Name == "target" && (owner.Kind == .Call || owner.Kind == .Get || owner.Kind == .Index);
		}

		/// Something takes over or deletes the object a Local Variable holds: a Delete, or any use
		/// other than reading its members (passed on, stored, returned).
		static bool LocalOwned(Graph g, Node local)
		{
			let name = local.Text;
			for (let l in g.Links)
			{
				let src = l.From.Owner;
				bool readsLocal = (src == local && l.From.Name == "variable") || (src.Kind == .Get && RootName(src) == name && src.Text == name);
				if (!readsLocal)
					continue;
				if (!IsMemberUse(l.To.Owner, l.To))
					return true;
			}
			// A read the graph shows as text (a Code node, a pin's text) may hand it over too.
			for (let n in g.Nodes)
			{
				if ((n.Kind == .Code || n.Kind == .Expr) && n.Text.Contains(name))
					return true;
				for (let p in n.Inputs)
					if (p.Kind == .Data && !p.Default.IsEmpty && p.Default.Contains(name) && p.Name != "target")
						return true;
			}
			return false;
		}

		// ------------------------------------------------------------------ inputs

		/// Inputs that must hold something for the code to be valid.
		static bool NeedsValue(Node n, Pin p)
		{
			switch (n.Kind)
			{
			case .Call:
				return p.ArgIndex >= 0;
			case .Set, .Branch, .While, .DoWhile, .Switch, .ForEach, .Operator, .Select, .Cast, .Index, .Get:
				return true;
			case .For:
				return true; // a counting loop's Start and Count
			case .Construct:
				return p.ArgIndex >= 0;
			case .Delete, .Using, .ResultMatch:
				return true;
			default:
				return false;
			}
		}

		static void CheckInputs(Graph g, Node n)
		{
			for (let p in n.Inputs)
			{
				if (p.Kind != .Data || p.Optional)
					continue;
				if (n.Kind == .Call && p.Name == "target")
					continue; // the Target rules above
				let link = g.FindLinkTo(p);
				if (link == null && p.Default.IsEmpty)
				{
					if (NeedsValue(n, p))
						g.AddError(n, scope $"'{Label(p)}' needs a value: connect a wire or type one in.");
					continue;
				}
				if (p.IsRefArg && (link != null ? !link.Parsed : n.Original == null) && !IsAssignable(g, p, link))
				{
					g.AddError(n, scope $"ref needs a variable: '{Label(p)}' is passed by reference, so connect a variable, field or array element to it.");
					continue;
				}
				if (link != null)
				{
					if (!link.Parsed && link.From.Kind == .Data)
					{
						String reason = scope .();
						let severity = Mismatch(link.From.TypeName, p.TypeName, reason);
						if (severity != .None)
							Report(g, n, severity, scope $"'{Label(p)}' takes {p.TypeName}, but the wire brings {link.From.TypeName}: {reason}");
					}
				}
				else if (n.Original == null && !p.TypeName.IsEmpty)
				{
					// A value typed into a new node.
					String lit = scope .();
					TypeRules.LiteralType(p.Default, lit);
					String reason = scope .();
					let severity = LiteralMismatch(lit, p.TypeName, reason);
					if (severity != .None)
						Report(g, n, severity, scope $"'{Label(p)}' takes {p.TypeName}, but holds {p.Default}: {reason}");
				}
			}
		}

		static StringView Label(Pin p) => p.Label.IsEmpty ? (StringView)p.Name : (StringView)p.Label;

		// ------------------------------------------------------------------ types

		enum Severity
		{
			None,
			Warning,
			Error
		}

		static void Report(Graph g, Node n, Severity severity, StringView message)
		{
			if (severity == .Error)
				g.AddError(n, message);
			else if (severity == .Warning)
				g.AddWarning(n, message);
		}

		/// A type the validator is sure about: a primitive, or a declaration the resolver found.
		static bool IsSolid(StringView type)
		{
			String t = scope .();
			TypeRules.Normalize(type, t);
			if (t.IsEmpty || TypeRules.IsWildcard(t) || t.EndsWith('*') || t.EndsWith('?') || t.EndsWith(']'))
				return false;
			return TypeRules.IsPrimitive(t) || IsKnownType(t);
		}

		/// How sure a refused conversion is. Types read from code are partly inferred (overloads
		/// picked by score, `var` locals, a few built-in signatures), so only a change of kind
		/// between two solid types is an error (bool <-> number, number <-> text, class <->
		/// unrelated known class); narrowing, sign, pointer level and copies are warnings.
		static Severity Mismatch(StringView from, StringView to, String outReason)
		{
			if (TypeRules.CanConvert(from, to, outReason, TypeRules.Hierarchy) != .Refused)
				return .None;
			if (!IsSolid(from) || !IsSolid(to))
				return .Warning;
			let h = TypeRules.Hierarchy;
			let ff = TypeRules.Family(from, h);
			let tf = TypeRules.Family(to, h);
			if (ff != tf)
				return .Error;
			if ((ff == .Object || ff == .Interface) && !TypeRules.IsPrimitive(from) && !TypeRules.IsPrimitive(to))
				return .Error;
			return .Warning;
		}

		/// A literal typed into a pin: integer constants fit any number type (Beef converts
		/// constants that are in range), so only kind changes are reported.
		static Severity LiteralMismatch(StringView literalType, StringView to, String outReason)
		{
			if (literalType.IsEmpty)
				return .None;
			String t = scope .();
			TypeRules.Normalize(to, t);
			if (TypeRules.IsNumeric(literalType) && (TypeRules.IsNumeric(t) || TypeRules.IsChar(t)))
				return .None;
			if (literalType == "null")
			{
				// Only a declared struct / enum (or a primitive) can't be null.
				if (TypeRules.IsPrimitive(t))
				{
					outReason.AppendF("null can't be a {}", t);
					return .Error;
				}
				String kind = scope .();
				TypeRules.Hierarchy?.KindOf(t, kind);
				if (kind == "struct" || kind == "enum")
				{
					outReason.AppendF("null can't be a {}: it's a value type", t);
					return .Error;
				}
				return .None;
			}
			return Mismatch(literalType, to, outReason);
		}

		/// What `ref` can take: a variable, field, element, out variable or dereference.
		static bool IsAssignable(Graph g, Pin p, Link link)
		{
			if (link == null)
			{
				var t = StringView(p.Default);
				t.Trim();
				if (t.IsEmpty || !(CharUtil.IsIdentStart(t[0]) || t[0] == '@'))
					return false;
				if (t == "true" || t == "false" || t == "null" || t == "default")
					return false;
				return CodeGen.IsAtomic(t) && !t.Contains('(');
			}
			let from = link.From;
			if (from.IsOutArg)
				return true;
			let src = from.Owner;
			switch (src.Kind)
			{
			case .LocalVar, .ForEach, .Entry, .Flow, .Get, .Index, .This:
				return true;
			case .For:
				return src.IsCountingLoop;
			case .Operator:
				return src.Text == "*" && src.FindInput("b") == null;
			case .Expr:
				var t = StringView(src.Text);
				t.Trim();
				return !t.IsEmpty && (CharUtil.IsIdentStart(t[0]) || t[0] == '@') && CodeGen.IsAtomic(t) && !t.Contains('(');
			case .Call:
				// A function returning by reference.
				return from.TypeName.StartsWith("ref ");
			default:
				return false;
			}
		}
	}
}
