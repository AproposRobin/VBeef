using System;
using System.Collections;
using VisualBeef.Catalog;

namespace VisualBeef.Graph
{
	enum PinKind : uint8
	{
		Exec,
		Data
	}

	/// How a call argument passes its value (see docs/Calls-and-Receivers.md).
	enum ArgMode : uint8
	{
		/// An ordinary value argument (an input pin).
		Value,
		/// `ref x`: an input pin whose source must be something assignable.
		Ref,
		/// `out x`: an *output* pin of the call (named `arg<i>` like the inputs), read like any value.
		Out
	}

	/// How an out pin's variable is spelled in the code (Beef 0.43.6 syntax; see
	/// docs/Calls-and-Receivers.md).
	enum OutForm : uint8
	{
		/// `var name` / `let name` declared in the argument itself (Beef's inline out variable;
		/// `out let name` when Pin.OutKeyword is set). What a new pin is written as when it is read.
		Inline,
		/// `?`: Beef's discard, for an out value nothing reads.
		Discard,
		/// `T name;` on the line before the statement, then `out name`: what the generator
		/// writes when the value is read after the block the call runs in (the declaration is
		/// hoisted), and what such a pair of lines reads back as.
		Declared,
		/// For a `ref` parameter marked `[Pin(Out=true)]` (Unreal out parameters the SDK passes by
		/// reference): `T name = default;` before the statement, then `ref name`.
		DeclaredRef,
		/// `out b` into a variable (or any assignable expression) that exists anyway: the pin is
		/// a "writes `b`" marker, readers of `b` read the variable itself.
		Existing
	}

	class Pin
	{
		public int32 Id;
		public Node Owner;
		public bool IsInput;
		public PinKind Kind;
		/// Stable identifier within the node ("exec", "then", "true", "condition", "target", "arg0", ...).
		public String Name = new .() ~ delete _;
		/// Display label (parameter name, "Condition", ...). Empty for unlabeled exec pins.
		public String Label = new .() ~ delete _;
		/// Beef type name if known; drives the pin color.
		public String TypeName = new .() ~ delete _;
		/// For unlinked data inputs: the literal / expression text to use.
		public String Default = new .() ~ delete _;
		/// Inputs such as Return's value or LocalVar's initializer may be left empty.
		public bool Optional;
		/// The source had explicit parentheses around this input's expression; keep them.
		public bool Parens;
		/// For exec outputs that own a body: comment/preprocessor lines before the body's '}'.
		public String EndComments ~ delete _;
		/// The declared generic type ("T", "List<T>") while TypeName holds what a connection
		/// unified it to; null when the pin was never unified.
		public String WildcardType ~ delete _;
		/// Switch case outputs: the exact text before the `case` keyword (comments, indentation)
		/// and from `case` through the end of the line holding the ':'. Reused while the clause
		/// reads back the same.
		public String RawLead ~ delete _;
		public String RawTail ~ delete _;

		/// Call arguments: value, `ref` (input) or `out` (output pin). Calls only.
		public ArgMode Mode;
		/// Out pins: how the variable is written, see OutForm.
		public OutForm Form;
		/// Out pins: the variable (`a`, or the text of the expression for OutForm.Existing).
		/// Chosen once and kept, like the `fooResult` names of call results.
		public String OutName ~ delete _;
		/// Out pins: the declared type / keyword as written (`var`, `let`, `int`); null = TypeName.
		public String OutDecl ~ delete _;
		/// Out pins (Inline): written `out let a` rather than Beef's `let a`.
		public bool OutKeyword;
		/// Out pins whose spelling the generator chooses (new pins): `?` while nothing reads
		/// them, `var name` once something does.
		public bool OutAuto;
		/// Out pins: the variable is also used where no wire shows it (in a Code node, a string),
		/// so its name must stay in the code even when nothing is wired to the pin.
		public bool OutKeepName;
		/// Out pins read from a `T name;` line in front of the statement: that line's exact text
		/// with its leading and trailing trivia, reused while the statement stays in place.
		public String OutDeclRaw ~ delete _;

		public bool IsOutArg => Mode == .Out && !IsInput;
		public bool IsRefArg => Mode == .Ref && IsInput;

		/// Argument index of an `arg<i>` pin, or -1.
		public int ArgIndex
		{
			get
			{
				if (Kind != .Data || Name.Length < 4 || !Name.StartsWith("arg"))
					return -1;
				int v = 0;
				for (int i = 3; i < Name.Length; i++)
				{
					let c = Name[i];
					if (c < '0' || c > '9')
						return -1;
					v = v * 10 + (c - '0');
				}
				return v;
			}
		}
	}

	/// How a call node binds to its function (see docs/Calls-and-Receivers.md).
	enum CallBinding : uint8
	{
		/// Not resolved (no index, unknown type): the shape the code had, never an error.
		Unresolved,
		/// A static function: no Target pin; Node.Qualifier is the type text written before it.
		Static,
		/// A member function: a Target pin of the owning type; unconnected means `this` (self).
		Instance
	}

	enum NodeKind : uint8
	{
		// Exec (statement) nodes
		Entry,
		Call,     // impure call when it has exec pins; pure call otherwise
		Set,
		LocalVar,
		Branch,
		While,
		DoWhile,
		For,
		ForEach,
		Return,
		Break,
		Continue,
		Code,
		/// `switch (value) { case ...: ... default: ... }` - see docs/Flow-Nodes.md.
		Switch,
		/// Blueprint flow macros (Sequence, DoOnce, DoN, FlipFlop, Gate, MultiGate and the nodes
		/// that reset / open / close them). Node.Text names the macro; see FlowMacros.
		Flow,
		// Pure (data) nodes
		Get,
		Operator,
		Select,
		Cast,
		Index,
		Expr,
		/// `this` as a value (Blueprint's "Get a reference to this"). Wired into a call's
		/// Target it writes `this.Foo()`; an unconnected Target writes `Foo()`.
		This,
		/// `base` (the parent class): wired into a call's Target it writes `base.Foo()`, the
		/// parent's version of an overridden function (UE's "Parent: Foo").
		Base,
		// Lifetime nodes (docs/Lifetime-Nodes.md). Graph.IsPureKind says which kinds are
		// statements.
		/// `new T(args)` / `scope T(args)` / `scope:: .()` / `new:alloc T[n]` (pure). Text = the
		/// type (`.` when inferred), Node.Alloc = the allocation keyword, Node.IsArray = `[n]`.
		Construct,
		/// `delete x;` / `delete:alloc x;` (exec). Node.Alloc = the keyword as written.
		Delete,
		/// `defer <statement>` / `defer { ... }` (exec): the *Deferred* body runs at the end of
		/// the enclosing block. Node.Alloc = `defer`, `defer::`, `defer:label`.
		Defer,
		/// `using (value) { body }` / `using (let x = value) { body }` (exec). Text / Text2 = the
		/// declared name and type when there is one.
		Using,
		/// `if (value case .Ok(let v)) { Ok } else { Err }` (exec): Text = the case tested (`Ok`
		/// or `Err`), the `payload` output is the bound value (an out-style pin).
		ResultMatch,
		// Nodes for the last text forms (docs/Flow-Nodes.md, docs/Lifetime-Nodes.md).
		/// A nested block `{ ... }` (exec): its own scope, the statements hang off Body.
		Scope,
		/// A lambda or a delegate bound to a method (pure, output `delegate`): Alloc = `new` /
		/// `scope` / ... or empty, Text = the parameters as written (`(a, b)`, `()`, `x`), or
		/// empty for `=> Method` with Text2 = the method; the capture list (`[&]`) is in
		/// Node.Attributes. An expression body is the `result` input, a block body hangs off the
		/// `body` exec output; parameters are `param<i>` outputs, read by name inside the body.
		Lambda,
		/// A local function `T Name(params) { ... }` (exec): Text = name, Text2 = the declaration
		/// up to the body; the body hangs off Body (or the `result` input for `=> expr;`).
		LocalFunc,
		/// An interpolated string `$"x = {x}"` (pure): Text = the literal with each hole's
		/// expression taken out (`$"x = {}"`), one `arg<i>` input per hole.
		Format
	}

	class Node
	{
		public int32 Id;
		public NodeKind Kind;
		/// Kind-specific primary text: callee / variable name / operator / raw code / cast type.
		public String Text = new .() ~ delete _;
		/// Kind-specific secondary text: declared type of a local or foreach variable; for an
		/// impure Call whose result is used, the name of the `let` temp holding that result.
		public String Text2 = new .() ~ delete _;
		public bool NullCond;
		/// Member access / call through Beef's cascade operator `a..B()`.
		public bool Cascade;
		public bool Postfix;
		public bool IsPure;
		/// Set on the node that stands for code the parser could not read (a Broken member);
		/// shown as "Broken: <error>" in red.
		public String Error ~ delete _;
		/// Code nodes: why this statement has no visual form ("switch: uses fallthrough").
		public String Reason ~ delete _;

		/// Call nodes: static, member (Target pin) or unresolved.
		public CallBinding Binding;
		/// Call nodes: the type that declares the function ("Player"); null when unknown.
		public String OwnerType ~ delete _;
		/// Static calls: the qualifier exactly as written (`Console`, `System.Math`); null or
		/// empty for a call written without one (`Foo()` inside the owning type).
		public String Qualifier ~ delete _;
		/// Call nodes: several overloads fit the arguments equally well; the node shows a warning.
		public bool Ambiguous;
		/// Ambiguous calls: the overloads that fit equally well, as `Name(int a, float b)` (the
		/// one the builder assumed first); the Properties panel offers them (NodeFactory.PickOverload).
		public List<String> Overloads ~ DeleteContainerAndItems!(_);
		/// Construct / Delete / Defer: the keyword with its scope or allocator exactly as written
		/// (`new`, `scope`, `scope::`, `new:alloc`, `append`, `delete:alloc`, `defer::`).
		public String Alloc ~ delete _;
		/// Construct: an array allocation `new T[n]` (the argument pins are the sizes).
		public bool IsArray;
		/// Attribute text written in front of the statement, with the gap that followed it
		/// (`[ConstSkip]` + line break + indent, before a Scope block); Lambda: the capture list
		/// (`[&]`). Null when there is none.
		public String Attributes ~ delete _;

		public List<Pin> Inputs = new .() ~ DeleteContainerAndItems!(_);
		public List<Pin> Outputs = new .() ~ DeleteContainerAndItems!(_);

		public float X;
		public float Y;
		public bool HasPos;

		/// Structural path used to persist layout across regenerations ("s2/true/s0/arg1").
		public String Key = new .() ~ delete _;
		/// Content hash used with Key to build the layout key (see LayoutKeys); set by KeyAssigner.
		public uint32 KeyHash;

		/// Original source text this node came from (statement or expression), for verbatim reuse.
		public String Original ~ delete _;
		/// Comment / blank lines that preceded the statement, one per line ("" = blank line).
		public String LeadingComments ~ delete _;
		/// Comment on the same line after the statement.
		public String TrailingComment ~ delete _;
		/// Exact trivia before / after the statement, reused while the node stays in place.
		public String RawLead ~ delete _;
		public String RawTrail ~ delete _;
		/// Source lines (1-based) this node came from; 0 for new nodes.
		public int32 Line;
		public int32 LineEnd;
		/// Set by any edit; cleared by rebuilding from source, or when a commit's re-parse shows
		/// the node (and everything its text covers) reads back unchanged.
		public bool Edited;
		/// Set when the node's incoming execution link changes (it moved in the flow).
		public bool Moved;

		public bool IsExecNode => !IsPure;

		public Pin FindInput(StringView name)
		{
			for (let p in Inputs)
				if (p.Name == name)
					return p;
			return null;
		}

		public Pin FindOutput(StringView name)
		{
			for (let p in Outputs)
				if (p.Name == name)
					return p;
			return null;
		}

		public Pin ExecIn => FindInput("exec");
		/// A For Loop read from (or made as) a counting header `T i = start; i < count; i++`:
		/// Text is the counter's name, Text2 its written type, the counter an output pin.
		public bool IsCountingLoop => Kind == .For && FindOutput("counter") != null;
		public Pin Then => FindOutput("then");
		public Pin Result => FindOutput("result");

		/// Number of argument pins on a Call / Index node (out pins included: they are outputs
		/// named `arg<i>` in the argument order).
		public int ArgCount
		{
			get
			{
				int count = 0;
				for (let p in Inputs)
					if (p.ArgIndex >= 0)
						count++;
				for (let p in Outputs)
					if (p.ArgIndex >= 0)
						count++;
				return count;
			}
		}

		/// The argument pins in argument order: inputs, and out pins (outputs) where they sit.
		public void GetArgPins(List<Pin> outPins)
		{
			for (let p in Inputs)
				if (p.ArgIndex >= 0)
					outPins.Add(p);
			bool anyOut = false;
			for (let p in Outputs)
			{
				if (p.ArgIndex >= 0)
				{
					outPins.Add(p);
					anyOut = true;
				}
			}
			if (anyOut)
				outPins.Sort(scope (a, b) => a.ArgIndex <=> b.ArgIndex);
		}

		/// The argument pin `arg<i>` (input or out pin), or null.
		public Pin FindArg(int index)
		{
			String name = scope $"arg{index}";
			let p = FindInput(name);
			return (p != null) ? p : FindOutput(name);
		}

		/// True when the node has an out pin.
		public bool HasOutArgs
		{
			get
			{
				for (let p in Outputs)
					if (p.IsOutArg)
						return true;
				return false;
			}
		}

		public void GetTitle(String outTitle)
		{
			switch (Kind)
			{
			case .Entry:
				outTitle.Append(Text);
				if (Text == "this")
				{
					// A constructor: its parameter types tell the overloads apart (Greeter.this(float)).
					outTitle.Append("(");
					bool first = true;
					for (let o in Outputs)
						if (o.Kind == .Data)
						{
							if (!first)
								outTitle.Append(", ");
							first = false;
							outTitle.Append(o.TypeName);
						}
					outTitle.Append(")");
				}
			case .Call:
				if (Text.IsEmpty)
					outTitle.Append("Invoke");
				else
					outTitle.Append(Text);
			case .Set:
				outTitle.Append("Set");
				if (Text != "=")
				{
					outTitle.Append(" (");
					outTitle.Append(Text);
					outTitle.Append(")");
				}
			case .LocalVar:
				outTitle.Append("Local ");
				outTitle.Append(Text);
			case .Branch: outTitle.Append("Branch");
			case .While: outTitle.Append("While Loop");
			case .DoWhile: outTitle.Append("Do While Loop");
			case .For: outTitle.Append("For Loop");
			case .ForEach: outTitle.Append("For Each Loop");
			case .Return: outTitle.Append("Return");
			case .Break: outTitle.Append("Break");
			case .Continue: outTitle.Append("Continue");
			case .Code:
				if (Error != null)
					outTitle.AppendF("Broken: {}", Error);
				else
					outTitle.Append("Code");
			case .Switch: outTitle.Append("Switch");
			case .Flow: FlowMacros.GetTitle(this, outTitle);
			case .Get: outTitle.Append(Text);
			case .Operator: outTitle.Append(Text);
			case .Select: outTitle.Append("Select");
			case .Cast: outTitle.Append("Cast To ");
				outTitle.Append(Text);
			case .Index: outTitle.Append("Get [ ]");
			case .Expr: outTitle.Append("Expression");
			case .This: outTitle.Append("This");
			case .Base: outTitle.Append("Base");
			case .Construct:
				outTitle.Append("Construct ");
				outTitle.Append((Text == ".") ? "(inferred)" : ((Text == "$") ? "String" : (StringView)Text));
				if (IsArray)
					outTitle.Append("[]");
			case .Delete: outTitle.Append("Delete");
			case .Defer: outTitle.Append("Defer");
			case .Using: outTitle.Append("Using");
			case .ResultMatch: outTitle.Append("Result: match");
			case .Scope: outTitle.Append("Scope");
			case .Lambda:
				if (!Text2.IsEmpty)
				{
					outTitle.Append("Create Delegate: ");
					outTitle.Append(Text2);
				}
				else
					outTitle.Append("Lambda");
			case .LocalFunc:
				outTitle.Append("Local Function ");
				outTitle.Append(Text);
			case .Format: outTitle.Append("Format Text");
			}
		}
	}

	class Link
	{
		public int32 Id;
		public Pin From; // output
		public Pin To;   // input
		/// The wire was read from the code (GraphBuilder); GraphValidator only re-checks the
		/// types of wires made afterwards, since the compiler already accepted these.
		public bool Parsed;
	}

	/// Why the code generator refused a graph, attached to the node at fault. Commit writes
	/// nothing while a graph has errors; the editor shows them on the nodes. The same record is
	/// used for warnings (Graph.Warnings), which never block a commit.
	class GraphError
	{
		public int32 NodeId;
		public String Message = new .() ~ delete _;
	}

	/// A visual graph for one method body.
	class Graph
	{
		/// Problems found by the last code generation (empty when the graph was written).
		public List<GraphError> Errors = new .() ~ DeleteContainerAndItems!(_);

		public void AddError(Node node, StringView message)
		{
			int32 id = (node != null) ? node.Id : 0;
			for (let e in Errors)
				if (e.NodeId == id && e.Message == message)
					return;
			GraphError e = new .();
			e.NodeId = id;
			e.Message.Set(message);
			Errors.Add(e);
		}

		public void ClearErrors()
		{
			ClearAndDeleteItems!(Errors);
			ClearAndDeleteItems!(Warnings);
		}

		/// Node-anchored warnings (GraphValidator, CodeGen): a yellow badge in the editor. They
		/// never stop a commit.
		public List<GraphError> Warnings = new .() ~ DeleteContainerAndItems!(_);

		public void AddWarning(Node node, StringView message)
		{
			int32 id = (node != null) ? node.Id : 0;
			for (let e in Warnings)
				if (e.NodeId == id && e.Message == message)
					return;
			GraphError e = new .();
			e.NodeId = id;
			e.Message.Set(message);
			Warnings.Add(e);
		}

		/// The first warning reported on a node, or null.
		public String FindWarning(int32 nodeId)
		{
			for (let e in Warnings)
				if (e.NodeId == nodeId)
					return e.Message;
			return null;
		}

		/// The first error reported on a node, or null.
		public String FindError(int32 nodeId)
		{
			for (let e in Errors)
				if (e.NodeId == nodeId)
					return e.Message;
			return null;
		}

		public List<Node> Nodes = new .() ~ DeleteContainerAndItems!(_);
		public List<Link> Links = new .() ~ DeleteContainerAndItems!(_);
		/// The function's Locals (docs/Classes-and-Members.md#locals): the declarations at the top
		/// of the body, in order. Each is a LocalVar node that is not on the Sheet: no wires, its
		/// value is typed text (a literal, a name, `.()`, `scope .()`, ...). CodeGen writes them
		/// first, then the flow from Entry.
		public List<Node> Locals = new .() ~ DeleteContainerAndItems!(_);
		public Node Entry;
		/// "Type.Method(int,float)" - identifies the method across regenerations.
		public String MethodKey = new .() ~ delete _;
		public String MethodName = new .() ~ delete _;
		/// Comments before the closing brace of the method body (normalized lines).
		public String EndComments ~ delete _;
		/// Exact trivia after '{' and before '}' of the method body.
		public String RawOpenTrail ~ delete _;
		public String RawCloseLead ~ delete _;
		/// The closing '}' started its own line in the original source.
		public bool CloseAtLineStart;
		/// Bumped on every structural change so views can refresh.
		public int32 Version;
		/// Positions came from AutoLayout estimates; the UI may re-run it with measured sizes.
		public bool AutoLaidOut;
		/// The graph stands for a Broken member: it can be looked at and moved around but never
		/// written back to the source (fix the text first).
		public bool ReadOnly;
		/// The `#if` arms the method is declared in (Member.CondPath), or null.
		public String CondPath ~ delete _;
		/// The type whose method this is (what `this`, "self", is); empty for none.
		public String SelfType = new .() ~ delete _;
		/// The function's modifier words as declared (`public override`), refreshed before every
		/// generation (SourceDocument.GenerateMethodBody); ClassModel.CheckEntry reads it.
		public String DeclModifiers = new .() ~ delete _;
		/// The method is static (or in a static type): there is no `this`, so a member call
		/// needs its Target wired.
		public bool StaticContext;
		/// The function belongs to a Node Library (`static class`): no this, and the library itself is never constructed.
		public bool InLibrary;

		int32 mNextId = 1;

		static int32 sNextSerial = 1;
		/// Unique per Graph object (a clone gets a new one). Views can compare this rather than
		/// the object's address, which the allocator may reuse after a graph is deleted.
		public readonly int32 Serial = sNextSerial++;

		public int32 NewId() => mNextId++;

		public static void CopyStr(ref String dst, String src)
		{
			delete dst;
			dst = (src != null) ? new String(src) : null;
		}

		/// Deep copy: nodes, pins and links keep their ids, keys, positions, flags and source
		/// bookkeeping, so the copy is indistinguishable from the original.
		public Graph Clone()
		{
			Graph g = new .();
			g.MethodKey.Set(MethodKey);
			g.MethodName.Set(MethodName);
			CopyStr(ref g.EndComments, EndComments);
			CopyStr(ref g.RawOpenTrail, RawOpenTrail);
			CopyStr(ref g.RawCloseLead, RawCloseLead);
			g.CloseAtLineStart = CloseAtLineStart;
			g.Version = Version;
			g.AutoLaidOut = AutoLaidOut;
			g.ReadOnly = ReadOnly;
			CopyStr(ref g.CondPath, CondPath);
			g.SelfType.Set(SelfType);
			g.StaticContext = StaticContext;
			g.InLibrary = InLibrary;
			g.mNextId = mNextId;

			Dictionary<Pin, Pin> pinMap = scope .();
			for (let src in Nodes)
			{
				let n = CloneNodeExact(src, pinMap);
				g.Nodes.Add(n);
				if (src == Entry)
					g.Entry = n;
			}
			for (let src in Locals)
				g.Locals.Add(CloneNodeExact(src));
			for (let l in Links)
			{
				Link c = new .();
				c.Id = l.Id;
				c.From = pinMap[l.From];
				c.To = pinMap[l.To];
				c.Parsed = l.Parsed;
				g.Links.Add(c);
			}
			return g;
		}

		/// Copies a node with its pins (ids included). Links are not copied.
		public static Node CloneNodeExact(Node src, Dictionary<Pin, Pin> pinMap = null)
		{
			Node n = new .();
			n.Id = src.Id;
			n.Kind = src.Kind;
			n.Text.Set(src.Text);
			n.Text2.Set(src.Text2);
			n.NullCond = src.NullCond;
			n.Cascade = src.Cascade;
			n.Postfix = src.Postfix;
			n.IsPure = src.IsPure;
			n.X = src.X;
			n.Y = src.Y;
			n.HasPos = src.HasPos;
			n.Key.Set(src.Key);
			n.KeyHash = src.KeyHash;
			CopyStr(ref n.Error, src.Error);
			CopyStr(ref n.Reason, src.Reason);
			n.Binding = src.Binding;
			CopyStr(ref n.OwnerType, src.OwnerType);
			CopyStr(ref n.Qualifier, src.Qualifier);
			n.Ambiguous = src.Ambiguous;
			if (src.Overloads != null)
			{
				n.Overloads = new .();
				for (let s in src.Overloads)
					n.Overloads.Add(new String(s));
			}
			CopyStr(ref n.Alloc, src.Alloc);
			n.IsArray = src.IsArray;
			CopyStr(ref n.Attributes, src.Attributes);
			CopyStr(ref n.Original, src.Original);
			CopyStr(ref n.LeadingComments, src.LeadingComments);
			CopyStr(ref n.TrailingComment, src.TrailingComment);
			CopyStr(ref n.RawLead, src.RawLead);
			CopyStr(ref n.RawTrail, src.RawTrail);
			n.Line = src.Line;
			n.LineEnd = src.LineEnd;
			n.Edited = src.Edited;
			n.Moved = src.Moved;
			for (let p in src.Inputs)
			{
				let c = ClonePinExact(p, n);
				n.Inputs.Add(c);
				pinMap?.Add(p, c);
			}
			for (let p in src.Outputs)
			{
				let c = ClonePinExact(p, n);
				n.Outputs.Add(c);
				pinMap?.Add(p, c);
			}
			return n;
		}

		static Pin ClonePinExact(Pin src, Node owner)
		{
			Pin p = new .();
			p.Id = src.Id;
			p.Owner = owner;
			p.IsInput = src.IsInput;
			p.Kind = src.Kind;
			p.Name.Set(src.Name);
			p.Label.Set(src.Label);
			p.TypeName.Set(src.TypeName);
			p.Default.Set(src.Default);
			p.Optional = src.Optional;
			p.Parens = src.Parens;
			CopyStr(ref p.EndComments, src.EndComments);
			CopyStr(ref p.WildcardType, src.WildcardType);
			CopyStr(ref p.RawLead, src.RawLead);
			CopyStr(ref p.RawTail, src.RawTail);
			p.Mode = src.Mode;
			p.Form = src.Form;
			CopyStr(ref p.OutName, src.OutName);
			CopyStr(ref p.OutDecl, src.OutDecl);
			CopyStr(ref p.OutDeclRaw, src.OutDeclRaw);
			p.OutKeyword = src.OutKeyword;
			p.OutAuto = src.OutAuto;
			p.OutKeepName = src.OutKeepName;
			return p;
		}

		public Node AddNode(NodeKind kind)
		{
			Node n = new .();
			n.Id = NewId();
			n.Kind = kind;
			n.IsPure = IsPureKind(kind);
			Nodes.Add(n);
			Version++;
			return n;
		}

		/// Data nodes (no exec pins); the lifetime statements were added after the pure kinds.
		public static bool IsPureKind(NodeKind kind)
		{
			switch (kind)
			{
			case .Delete, .Defer, .Using, .ResultMatch, .Scope, .LocalFunc: return false;
			default: return kind >= .Get;
			}
		}

		public Pin AddPin(Node node, bool isInput, PinKind kind, StringView name, StringView label = "")
		{
			Pin p = new .();
			p.Id = NewId();
			p.Owner = node;
			p.IsInput = isInput;
			p.Kind = kind;
			p.Name.Set(name);
			p.Label.Set(label);
			if (isInput)
				node.Inputs.Add(p);
			else
				node.Outputs.Add(p);
			return p;
		}

		public Pin AddExecIn(Node node) => AddPin(node, true, .Exec, "exec");
		public Pin AddExecOut(Node node, StringView name, StringView label = "") => AddPin(node, false, .Exec, name, label);
		public Pin AddDataIn(Node node, StringView name, StringView label) => AddPin(node, true, .Data, name, label);
		public Pin AddDataOut(Node node, StringView name, StringView label) => AddPin(node, false, .Data, name, label);

		/// The Local named `name`, or null.
		public Node FindLocal(StringView name)
		{
			for (let n in Locals)
				if (n.Text == name)
					return n;
			return null;
		}

		/// Whether a Local Variable node can be one of the function's Locals: a declared type (not
		/// `let` / `var`), no `const` / `ref`, no attributes, nothing wired except its flow, and a
		/// value that is typed text or a `new` / `scope` of a type whose arguments are typed text.
		/// `construct` is that Construct node when there is one.
		public bool CanBeLocal(Node n, out Node construct)
		{
			construct = null;
			if (n == null || n.Kind != .LocalVar || (n.Alloc != null && !n.Alloc.IsEmpty) || n.Attributes != null)
				return false;
			if (n.Text.IsEmpty || n.Text2.IsEmpty || n.Text2 == "var" || n.Text2 == "let")
				return false;
			let value = n.FindInput("value");
			let varOut = n.FindOutput("variable");
			if (value == null || (varOut != null && IsLinked(varOut)))
				return false;
			int execIn = 0;
			for (let l in Links)
			{
				if (l.To == n.ExecIn)
					execIn++;
				else if (l.To.Owner == n && l.To != value)
					return false;
			}
			if (execIn > 1)
				return false;
			let src = DataSource(value);
			if (src == null)
				return true;
			if (!IsTextValue(src, true))
				return false;
			construct = src;
			return true;
		}

		/// A value read from code that a Local can hold as its text: pure nodes that are not calls
		/// (a `new` / `scope` of a type, an operator, a member, a cast, ...), unchanged since they
		/// were read, feeding only the node above them.
		bool IsTextValue(Node src, bool top)
		{
			if (!src.IsPure || src.Original == null || src.Edited || src.Kind == .Call || src.Kind == .Lambda || src.Kind == .Format)
				return false;
			if (src.Kind == .Construct && (src.IsArray || (src.Alloc != "scope" && src.Alloc != "new")))
				return false;
			int outs = 0;
			for (let l in Links)
			{
				if (l.From.Owner == src)
					outs++;
				else if (l.To.Owner == src && (l.From.Kind != .Data || !IsTextValue(l.From.Owner, false)))
					return false;
			}
			return outs == 1;
		}

		/// The value text of a Local made from `src` (the expression as written).
		static void TextValueOf(Pin value, Node src, String outText)
		{
			if (value.Parens)
				outText.AppendF("({})", src.Original);
			else
				outText.Append(src.Original);
		}

		/// Moves the Local Variable nodes at the top of the flow (right after Entry, each one a
		/// CanBeLocal) into Locals. The next statement keeps its place (not Moved), so the text is
		/// written byte for byte. A `scope .()` value becomes the value's text.
		public void ExtractLocals(int max = -1)
		{
			if (Entry == null || Entry.Then == null)
				return;
			let entryThen = Entry.Then;
			while (max < 0 || Locals.Count < max)
			{
				let link = FindLinkFrom(entryThen);
				if (link == null)
					break;
				let n = link.To.Owner;
				if (!CanBeLocal(n, let construct))
					break;
				if (construct != null)
				{
					let value = n.FindInput("value");
					value.Default.Clear();
					TextValueOf(value, construct, value.Default);
					value.Parens = false;
					DeleteLink(FindLinkTo(value));
					RemoveTreeQuiet(construct);
				}
				let next = (n.Then != null) ? FindLinkFrom(n.Then) : null;
				Links.Remove(link);
				delete link;
				if (next != null)
					next.From = entryThen;
				Nodes.Remove(n);
				Locals.Add(n);
			}
		}

		/// After a commit: the Locals become what a fresh read of the written text has. Local
		/// Variable nodes at the top of the flow that the text now declares as Locals leave the
		/// Sheet, with the pure nodes only they read; a wire from one becomes the name as text.
		public void AdoptLocals(Graph fresh)
		{
			ExtractLocals();
			// The fresh Locals this graph has: its own, and declarations at the top of its flow that
			// the text now declares as Locals. A fresh Local the graph writes some other way (a
			// declaration the generator hoists for a call result) stays the generator's.
			HashSet<String> have = scope .();
			defer { for (let s in have) delete s; }
			for (let l in Locals)
				have.Add(new String(l.Text));
			while (Entry?.Then != null)
			{
				let link = FindLinkFrom(Entry.Then);
				if (link == null)
					break;
				let n = link.To.Owner;
				Node match = null;
				for (let f in fresh.Locals)
				{
					if (have.ContainsAlt(StringView(f.Text)))
						continue;
					if (n.Kind == .LocalVar && n.Text == f.Text)
						match = f;
					else if (n.Kind == .Code && f.Original != null)
					{
						// A Code node whose text is the declaration (`int x = 1;` typed as code).
						String a = scope .();
						String b = scope .();
						LayoutKeys.Normalize(n.Text, a);
						LayoutKeys.Normalize(f.Original, b);
						if (a == b)
							match = f;
					}
					if (match != null)
						break;
				}
				if (match == null)
					break;
				have.Add(new String(match.Text));
				let next = (n.Then != null) ? FindLinkFrom(n.Then) : null;
				Links.Remove(link);
				delete link;
				if (next != null)
					next.From = Entry.Then;
				let varOut = n.FindOutput("variable");
				for (int i = Links.Count - 1; i >= 0; i--)
				{
					let l = Links[i];
					if (varOut == null || l.From != varOut)
						continue;
					l.To.Default.Set(n.Text);
					Links.RemoveAt(i);
					delete l;
				}
				RemoveWithValueTree(n);
			}
			ClearAndDeleteItems!(Locals);
			for (let l in fresh.Locals)
			{
				if (!have.ContainsAlt(StringView(l.Text)))
					continue;
				let c = CloneNodeExact(l);
				c.Id = NewId();
				for (let p in c.Inputs)
					p.Id = NewId();
				for (let p in c.Outputs)
					p.Id = NewId();
				Locals.Add(c);
			}
			Version++;
		}

		/// Removes a node, then each pure node that fed it and now feeds nothing.
		void RemoveWithValueTree(Node n)
		{
			List<Node> sources = scope .();
			for (let p in n.Inputs)
			{
				let s = (p.Kind == .Data) ? DataSource(p) : null;
				if (s != null && s.IsPure && !sources.Contains(s))
					sources.Add(s);
			}
			RemoveNodeQuiet(n);
			for (let s in sources)
			{
				bool used = false;
				for (let l in Links)
					if (l.From.Owner == s)
						used = true;
				if (!used && Nodes.Contains(s))
					RemoveWithValueTree(s);
			}
		}

		void DeleteLink(Link l)
		{
			if (l == null)
				return;
			Links.Remove(l);
			delete l;
		}

		/// Removes a pure value node and the nodes that feed it (quietly).
		void RemoveTreeQuiet(Node n)
		{
			List<Node> sources = scope .();
			for (let p in n.Inputs)
			{
				let s = (p.Kind == .Data) ? DataSource(p) : null;
				if (s != null && !sources.Contains(s))
					sources.Add(s);
			}
			RemoveNodeQuiet(n);
			for (let s in sources)
				if (Nodes.Contains(s))
					RemoveTreeQuiet(s);
		}

		/// Removes a node and its links without marking anything edited or moved.
		void RemoveNodeQuiet(Node node)
		{
			for (int i = Links.Count - 1; i >= 0; i--)
			{
				let l = Links[i];
				if (l.From.Owner == node || l.To.Owner == node)
				{
					Links.RemoveAt(i);
					delete l;
				}
			}
			Nodes.Remove(node);
			delete node;
		}

		/// A Local Variable node in the flow becomes the last of the Locals ("Move to Locals"): the
		/// statements around it are joined, the declaration is written at the top of the body.
		public bool MoveToLocals(Node n)
		{
			if (!Nodes.Contains(n))
				return false;
			if (!CanBeLocal(n, let construct))
				return false;
			if (construct != null)
			{
				let value = n.FindInput("value");
				value.Default.Clear();
				TextValueOf(value, construct, value.Default);
				value.Parens = false;
				DeleteLink(FindLinkTo(value));
				RemoveTreeQuiet(construct);
			}
			let execIn = n.ExecIn;
			let inLink = (execIn != null) ? FindLinkTo(execIn) : null;
			let outLink = (n.Then != null) ? FindLinkFrom(n.Then) : null;
			Pin from = inLink?.From;
			Pin to = outLink?.To;
			if (inLink != null)
				Disconnect(inLink);
			if (outLink != null)
				Disconnect(outLink);
			if (from != null && to != null)
				Connect(from, to);
			for (int i = Links.Count - 1; i >= 0; i--)
				if (Links[i].From.Owner == n || Links[i].To.Owner == n)
				{
					delete Links[i];
					Links.RemoveAt(i);
				}
			Nodes.Remove(n);
			n.Edited = true;
			n.Moved = true;
			Locals.Add(n);
			Version++;
			return true;
		}

		public Node FindNode(int id)
		{
			for (let n in Nodes)
				if (n.Id == id)
					return n;
			return null;
		}

		public Pin FindPin(int id)
		{
			for (let n in Nodes)
			{
				for (let p in n.Inputs)
					if (p.Id == id)
						return p;
				for (let p in n.Outputs)
					if (p.Id == id)
						return p;
			}
			return null;
		}

		public Link FindLink(int id)
		{
			for (let l in Links)
				if (l.Id == id)
					return l;
			return null;
		}

		public Link FindLinkTo(Pin input)
		{
			for (let l in Links)
				if (l.To == input)
					return l;
			return null;
		}

		public Link FindLinkFrom(Pin output)
		{
			for (let l in Links)
				if (l.From == output)
					return l;
			return null;
		}

		public void FindLinksFrom(Pin output, List<Link> outLinks)
		{
			for (let l in Links)
				if (l.From == output)
					outLinks.Add(l);
		}

		public bool IsLinked(Pin pin)
		{
			for (let l in Links)
				if (l.From == pin || l.To == pin)
					return true;
			return false;
		}

		/// The node an exec output leads to, if any.
		public Node ExecTarget(Pin execOut)
		{
			if (execOut == null)
				return null;
			let link = FindLinkFrom(execOut);
			return link?.To.Owner;
		}

		/// The node feeding a data input, if any.
		public Node DataSource(Pin input)
		{
			let link = FindLinkTo(input);
			return link?.From.Owner;
		}

		public static bool CanConnect(Pin a, Pin b)
		{
			if (a == null || b == null || a.Owner == b.Owner)
				return false;
			if (a.IsInput == b.IsInput)
				return false;
			return a.Kind == b.Kind;
		}

		/// The wire type check: false (with a reason for the tooltip) when both pin types are
		/// known and the value can't flow without a cast. Unknown and generic types always pass,
		/// so graphs from code are never refused. Graph building itself never calls this.
		public static bool TypesCompatible(Pin a, Pin b, String outReason = null)
		{
			if (a == null || b == null || a.Kind == .Exec || b.Kind == .Exec)
				return true;
			Pin from = a.IsInput ? b : a;
			Pin to = a.IsInput ? a : b;
			return TypeRules.CanConvert(from.TypeName, to.TypeName, outReason) != .Refused;
		}

		/// CanConnect plus the type check: what the editor uses for wires the user drags.
		public static bool CanConnectTyped(Pin a, Pin b, String outReason = null)
		{
			if (!CanConnect(a, b))
			{
				if (outReason != null && a != null && b != null && a.Kind != b.Kind)
					outReason.Set("Flow pins connect to flow pins, data pins to data pins");
				return false;
			}
			return TypesCompatible(a, b, outReason);
		}

		/// Generic pins take the type of what they're wired to: connecting an int to `T` turns
		/// every `T` on that node into int (List<T> into List<int>), like UE's wildcard pins.
		public static void UnifyWildcards(Pin from, Pin to)
		{
			if (from.Kind != .Data || to.Kind != .Data)
				return;
			let fromWild = TypeRules.IsGenericParam(from.TypeName);
			let toWild = TypeRules.IsGenericParam(to.TypeName);
			if (toWild && !fromWild && !TypeRules.IsWildcard(from.TypeName))
				Bind(to.Owner, to.TypeName, from.TypeName);
			else if (fromWild && !toWild && !TypeRules.IsWildcard(to.TypeName))
				Bind(from.Owner, from.TypeName, to.TypeName);
		}

		static void Bind(Node node, StringView param, StringView concreteType)
		{
			String p = scope .(param);
			p.Trim();
			String c = scope .(concreteType);
			Dictionary<String, String> map = scope .();
			map[p] = c;
			void Apply(Pin pin)
			{
				if (pin.Kind != .Data || pin.TypeName.IsEmpty)
					return;
				String sub = scope .();
				TypeRules.Substitute(pin.TypeName, map, sub);
				if (sub == pin.TypeName)
					return;
				if (pin.WildcardType == null)
					pin.WildcardType = new String(pin.TypeName);
				pin.TypeName.Set(sub);
			}
			for (let pin in node.Inputs)
				Apply(pin);
			for (let pin in node.Outputs)
				Apply(pin);
		}

		/// After a disconnect: a node with no wires left on its unified pins gets its generic
		/// types back.
		public void RestoreWildcards(Node node)
		{
			bool any = false;
			for (int side < 2)
				for (let pin in (side == 0) ? node.Inputs : node.Outputs)
					if (pin.WildcardType != null)
					{
						any = true;
						if (IsLinked(pin))
							return;
					}
			if (!any)
				return;
			for (int side < 2)
				for (let pin in (side == 0) ? node.Inputs : node.Outputs)
					if (pin.WildcardType != null)
					{
						pin.TypeName.Set(pin.WildcardType);
						DeleteAndNullify!(pin.WildcardType);
					}
		}

		/// Connects two pins (in either order). Exec outputs and data inputs accept a single link,
		/// so an existing link there is replaced. Returns null if the pins are incompatible.
		public Link Connect(Pin a, Pin b)
		{
			if (!CanConnect(a, b))
				return null;
			Pin from = a.IsInput ? b : a;
			Pin to = a.IsInput ? a : b;

			for (int i = Links.Count - 1; i >= 0; i--)
			{
				let l = Links[i];
				bool replace = (from.Kind == .Exec && l.From == from) || (to.Kind == .Data && l.To == to);
				if (l.From == from && l.To == to)
					return l;
				if (replace)
				{
					l.From.Owner.Edited = true;
					l.To.Owner.Edited = true;
					if (l.To.Kind == .Exec)
						l.To.Owner.Moved = true;
					Links.RemoveAt(i);
					delete l;
				}
			}

			Link link = new .();
			link.Id = NewId();
			link.From = from;
			link.To = to;
			Links.Add(link);
			from.Owner.Edited = true;
			to.Owner.Edited = true;
			if (to.Kind == .Exec)
				to.Owner.Moved = true;
			UnifyWildcards(from, to);
			Version++;
			return link;
		}

		public void Disconnect(Link link)
		{
			link.From.Owner.Edited = true;
			link.To.Owner.Edited = true;
			if (link.To.Kind == .Exec)
				link.To.Owner.Moved = true;
			let a = link.From.Owner;
			let b = link.To.Owner;
			Links.Remove(link);
			delete link;
			RestoreWildcards(a);
			RestoreWildcards(b);
			Version++;
		}

		public void DisconnectPin(Pin pin)
		{
			for (int i = Links.Count - 1; i >= 0; i--)
			{
				let l = Links[i];
				if (l.From == pin || l.To == pin)
				{
					l.From.Owner.Edited = true;
					l.To.Owner.Edited = true;
					if (l.To.Kind == .Exec)
						l.To.Owner.Moved = true;
					Links.RemoveAt(i);
					delete l;
				}
			}
			Version++;
		}

		public void RemoveNode(Node node)
		{
			if (node == Entry)
				return;
			for (int i = Links.Count - 1; i >= 0; i--)
			{
				let l = Links[i];
				if (l.From.Owner == node || l.To.Owner == node)
				{
					l.From.Owner.Edited = true;
					l.To.Owner.Edited = true;
					if (l.To.Kind == .Exec)
						l.To.Owner.Moved = true;
					Links.RemoveAt(i);
					delete l;
				}
			}
			Nodes.Remove(node);
			delete node;
			Version++;
		}

		/// Removes a pin (e.g. a call argument) along with its links.
		public void RemovePin(Pin pin)
		{
			DisconnectPin(pin);
			let node = pin.Owner;
			node.Inputs.Remove(pin);
			node.Outputs.Remove(pin);
			node.Edited = true;
			delete pin;
			Version++;
		}

		/// Marks every node reachable from the entry (exec flow plus the data feeding it).
		public void GetReachable(HashSet<Node> outReachable)
		{
			List<Node> stack = scope .();
			if (Entry != null)
				stack.Add(Entry);
			while (!stack.IsEmpty)
			{
				let n = stack.PopBack();
				if (!outReachable.Add(n))
					continue;
				for (let p in n.Outputs)
				{
					if (p.Kind == .Exec)
					{
						let next = ExecTarget(p);
						if (next != null)
							stack.Add(next);
					}
				}
				for (let p in n.Inputs)
				{
					if (p.Kind == .Data)
					{
						let src = DataSource(p);
						if (src != null)
							stack.Add(src);
					}
				}
			}
		}

		/// Every node that belongs to a lambda or local function: the data feeding its Returns
		/// input and the statements of its Body (with their data and nested bodies).
		public void GetInside(Node owner, HashSet<Node> outInside)
		{
			List<Node> stack = scope .();
			void Feed(Node n)
			{
				for (let p in n.Inputs)
				{
					if (p.Kind != .Data)
						continue;
					let src = DataSource(p);
					if (src != null && src != owner)
						stack.Add(src);
				}
				for (let p in n.Outputs)
				{
					if (p.Kind != .Exec || (p.Name == "then" && n == owner))
						continue;
					let next = ExecTarget(p);
					if (next != null)
						stack.Add(next);
				}
			}
			Feed(owner);
			while (!stack.IsEmpty)
			{
				let n = stack.PopBack();
				if (n == owner || !outInside.Add(n))
					continue;
				Feed(n);
			}
		}

		/// The names a lambda (or local function) reads from the function around it: its
		/// captures. Reads by name (Get nodes) of the function's parameters and locals, and wires
		/// from variables and out values outside it; its own parameters and locals are not
		/// captures. Fields are reached through `this` and are not listed.
		public void GetCaptures(Node lambda, List<String> outNames)
		{
			HashSet<Node> inside = scope .();
			GetInside(lambda, inside);
			HashSet<String> own = scope .();
			HashSet<String> outer = scope .();
			defer
			{
				for (let s in own)
					delete s;
				for (let s in outer)
					delete s;
			}
			void AddName(HashSet<String> set, StringView name)
			{
				if (!name.IsEmpty && !set.ContainsAlt(name))
					set.Add(new String(name));
			}
			void Declared(Node n, HashSet<String> set)
			{
				switch (n.Kind)
				{
				case .LocalVar, .ForEach, .Using:
					AddName(set, n.Text);
				case .For:
					if (n.IsCountingLoop)
						AddName(set, n.Text);
				case .Lambda, .LocalFunc:
					for (let p in n.Outputs)
						if (p.Kind == .Data && p.Name.StartsWith("param"))
							AddName(set, p.Label);
				default:
				}
				for (let p in n.Outputs)
					if (p.IsOutArg && p.OutName != null && (p.Form == .Inline || p.Form == .Declared || p.Form == .DeclaredRef))
						AddName(set, p.OutName);
			}
			Declared(lambda, own);
			for (let n in inside)
				Declared(n, own);
			if (Entry != null)
				for (let p in Entry.Outputs)
					if (p.Kind == .Data)
						AddName(outer, p.Label);
			for (let n in Nodes)
				if (n != lambda && !inside.Contains(n))
					Declared(n, outer);
			for (let n in Locals)
				AddName(outer, n.Text);
			void Capture(StringView name)
			{
				if (name.IsEmpty || own.ContainsAlt(name) || !outer.ContainsAlt(name))
					return;
				for (let s in outNames)
					if (s == name)
						return;
				outNames.Add(new String(name));
			}
			for (let n in inside)
			{
				if (n.Kind == .Get && n.FindInput("target") == null)
				{
					var name = StringView(n.Text);
					int dot = name.IndexOf('.');
					if (dot > 0)
						name = name.Substring(0, dot);
					Capture(name);
				}
				// Inputs written as text that are a plain name (`total`, a Set's target).
				for (let p in n.Inputs)
				{
					if (p.Kind != .Data || DataSource(p) != null || p.Default.IsEmpty)
						continue;
					var t = StringView(p.Default);
					int dot = t.IndexOf('.');
					if (dot > 0)
						t = t.Substring(0, dot);
					bool plain = !t.IsEmpty && (t[0].IsLetter || t[0] == '_');
					for (let c in t.RawChars)
						if (!(c.IsLetterOrDigit || c == '_'))
							plain = false;
					if (plain)
						Capture(t);
				}
				for (let p in n.Inputs)
				{
					if (p.Kind != .Data)
						continue;
					let link = FindLinkTo(p);
					if (link == null)
						continue;
					let src = link.From.Owner;
					if (src == lambda || inside.Contains(src))
						continue;
					if (link.From.IsOutArg && link.From.OutName != null)
						Capture(link.From.OutName);
					else if ((src.Kind == .LocalVar || src.Kind == .ForEach || src.Kind == .Using || src.IsCountingLoop) && link.From.Kind == .Data)
						Capture(src.Text);
					else if (src == Entry)
						Capture(link.From.Label);
				}
			}
		}

		/// True when this node and everything it depends on are unedited, so its original text
		/// can be reused as-is.
		public bool IsClean(Node node)
		{
			HashSet<Node> visiting = scope .();
			return IsCleanRec(node, visiting);
		}

		bool IsCleanRec(Node node, HashSet<Node> visiting)
		{
			if (node.Edited || node.Original == null)
				return false;
			if (!visiting.Add(node))
				return true;
			for (let p in node.Inputs)
			{
				if (p.Kind != .Data)
					continue;
				let src = DataSource(p);
				if (src != null && !IsCleanRec(src, visiting))
					return false;
			}
			// Nested exec chains (bodies) are part of the statement's text.
			for (let p in node.Outputs)
			{
				if (p.Kind != .Exec || p.Name == "then")
					continue;
				var next = ExecTarget(p);
				int guard = 0;
				while (next != null && guard++ < 100000)
				{
					if (!IsCleanRec(next, visiting))
						return false;
					next = ExecTarget(next.Then);
				}
			}
			return true;
		}
	}
}
