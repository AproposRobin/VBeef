using System;
using System.Collections;
using VisualBeef.Catalog;

namespace VisualBeef.Syntax
{
	/// Every syntax node remembers the inclusive token range it was parsed from, so the exact
	/// original text of any node can be recovered from the CompilationUnit.
	abstract class SyntaxNode
	{
		public int32 FirstTok = -1;
		public int32 LastTok = -1;

		public bool HasSpan => FirstTok >= 0 && LastTok >= FirstTok;
	}

	enum ExprKind : uint8
	{
		Literal,     // numbers, strings, chars, true/false/null/this/base, `.EnumCase`
		Name,        // identifier, optionally with generic args: `Foo`, `List<int>`
		Member,      // A.Op (Op = member name). NullCond for `?.`
		Call,        // A(Args)
		Index,       // A[Args]
		Unary,       // Op A   (Postfix: A Op)
		Binary,      // A Op B
		Assign,      // A Op B  where Op is =, +=, ...
		Conditional, // A ? B : C
		Cast,        // (TypeText)A
		Paren,       // (A)
		Raw,         // anything else; text comes from the span
		/// An allocation `new T(Args)`, `scope T(Args)`, `scope:: .(Args)`, `new:alloc T[Args]`:
		/// Op is the allocation keyword as written without spaces (`new`, `scope`, `scope::`,
		/// `new:alloc`, `append`), TypeText the type (`.` when inferred, `$` for `scope $"..."`,
		/// whose only Arg is the string literal), Args the constructor arguments or (IsArray) the
		/// array sizes. Initialiser blocks stay Raw. Op is empty for `.(args)`, a value of the
		/// inferred type made without an allocation (a struct, `Result = .();`).
		New,
		/// A lambda or a delegate made from a method: `(a, b) => a + b`, `x => { ... }`,
		/// `scope [&] (Line) => { ... }`, `new => OnTick`. Op is the allocation as written
		/// without spaces (empty, `new`, `scope`, `scope::`, `new:alloc`), Captures the capture
		/// list (`[&]`, `[=]`) or null, Params the text between the parentheses (`a, b`, `int x`;
		/// a bare `x =>` sets ParamParens false) or null for a method reference, whose name chain
		/// is A. An expression body is A, a block body is Body.
		Lambda
	}

	/// What a Literal expression is. Beef rules: `1.0` and `1e3` are double, `1.0f` / `1f` are
	/// float, integers are int unless suffixed or too large, `$"..."` is an interpolated string.
	enum LiteralKind : uint8
	{
		None,        // not a literal (Kind != Literal)
		Int,
		UInt,        // `5u`, or a hex/binary value that only fits 32 unsigned bits
		Long,        // `5L`, or a decimal value beyond int
		ULong,       // `5UL`
		Float,       // `1.0f`, `1f`
		Double,      // `1.0`, `1e3`, `1.0d`
		Char8,       // 'a'
		Char32,      // '\u{1F600}' or a non-ASCII character
		String,      // "text"
		VerbatimString,      // @"text"
		InterpolatedString,  // $"text {x}"  (also $@"..." / @$"...")
		RawString,   // """ multi-line """
		Bool,
		Null,
		This,
		Base,
		EnumCase,    // .Name
		Default      // `default`
	}

	class Expr : SyntaxNode
	{
		public ExprKind Kind;
		/// Set for Literal expressions (see LiteralKind).
		public LiteralKind LitKind;
		public String Op = new .() ~ delete _;
		public Expr A ~ delete _;
		public Expr B ~ delete _;
		public Expr C ~ delete _;
		public List<Expr> Args ~ DeleteContainerAndItems!(_);
		public String TypeText ~ delete _;
		public bool Postfix;
		public bool NullCond;
		/// Beef's cascade operator: `a..Method()` calls Method on a and yields a.
		public bool Cascade;
		/// New expressions: `new T[n]` (Args are the sizes) rather than `new T(args)`.
		public bool IsArray;
		/// Lambdas (see ExprKind.Lambda).
		public String Captures ~ delete _;
		public String Params ~ delete _;
		public bool ParamParens;
		public Stmt Body ~ delete _;

		public this(ExprKind kind)
		{
			Kind = kind;
		}
	}

	enum StmtKind : uint8
	{
		Block,
		Expr,      // Expr ;
		LocalVar,  // VarType VarName (= Expr)? ;
		If,        // if (Expr) Then else Else
		While,     // while (Expr) Then
		DoWhile,   // do Then while (Expr);
		For,       // for (ForHeader) Then          (C-style or Beef shorthand)
		ForEach,   // for (VarType VarName in Expr) Then
		Return,    // return Expr? ;
		Break,
		Continue,
		Switch,    // switch (Expr) { Cases }  (only when every case can be modelled; see Parser.ParseSwitch)
		Raw,       // anything else
		Delete,    // delete Expr ;  /  delete:alloc Expr ;           (Alloc = "delete", "delete:alloc")
		Defer,     // defer Then  /  defer:: Then  /  defer:label Then (Alloc = "defer", "defer::", ...)
		Using,     // using (Expr) Then  /  using (VarType VarName = Expr) Then
		/// A local function `T Name(params) { ... }` / `T Name(params) => expr;`: ForHeader is the
		/// declaration up to the body (`void Rebase()`), VarName the name, VarType the return
		/// type, Then the block body or Expr the expression body.
		LocalFunc
	}

	/// One `case A, B:` / `default:` clause of a switch with its statements.
	class SwitchCase : SyntaxNode
	{
		/// Text between `case` and `:` ("1", "2, 3", ".Name"); empty for default.
		public String Label = new .() ~ delete _;
		public bool IsDefault;
		public int32 ColonTok = -1;
		/// A payload pattern `case .Ok(let v):`: the case name (`Ok`), `let` / `var` and the bound
		/// name; null when the label binds nothing.
		public String BindCase ~ delete _;
		public String BindDecl ~ delete _;
		public String BindName ~ delete _;
		public List<Stmt> Body = new .() ~ DeleteContainerAndItems!(_);
	}

	class Stmt : SyntaxNode
	{
		public StmtKind Kind;
		public Expr Expr ~ delete _;
		/// For: the count of a counting header (`i < count`); see Parser.ParseCountedHeader.
		public Expr Expr2 ~ delete _;
		public List<Stmt> Body ~ DeleteContainerAndItems!(_); // Block statements
		public Stmt Then ~ delete _;
		public Stmt Else ~ delete _;
		public String VarType ~ delete _;
		public String VarName ~ delete _;
		public String ForHeader ~ delete _;
		/// Switch statements: the clauses, and the '{' / '}' tokens (CloseTok is the '}').
		public List<SwitchCase> Cases ~ DeleteContainerAndItems!(_);
		public int32 OpenTok = -1;
		/// Raw statements: why a construct that has a visual form stayed raw code ("switch: fallthrough").
		public String RawReason ~ delete _;
		/// Index of the closing '}' token for blocks.
		public int32 CloseTok = -1;
		/// Delete / Defer: the keyword with its scope or allocator as written, without spaces
		/// (`delete`, `delete:alloc`, `defer`, `defer::`, `defer:mixin`). LocalVar: `const` or
		/// `ref` when the declaration has that modifier. DoWhile: `repeat` for Beef's
		/// `repeat { } while (x);` (null = `do`).
		public String Alloc ~ delete _;
		/// Attribute text in front of a simple statement (`[ConstSkip]`), or null.
		public String Attributes ~ delete _;

		public this(StmtKind kind)
		{
			Kind = kind;
		}
	}

	enum MemberKind : uint8
	{
		Using,
		Namespace,
		Type,
		Method,
		Field,
		Property,
		Raw,
		/// A member the parser could not make sense of (unbalanced brackets and the like). Its
		/// exact text is kept; see Member.Error.
		Broken
	}

	class Param
	{
		public String Modifier = new .() ~ delete _; // ref, out, params, ...
		public String Type = new .() ~ delete _;
		public String Name = new .() ~ delete _;
		public String Default ~ delete _;
		/// Attribute source text before the parameter (`[Pin(Name="Alpha")]`), or null.
		public String Attributes ~ delete _;
	}

	class Member : SyntaxNode
	{
		public MemberKind Kind;
		public String Name = new .() ~ delete _;
		public String Modifiers = new .() ~ delete _;
		/// Broken members only: what is wrong ("line 12: missing ')'").
		public String Error ~ delete _;
		public bool IsBroken => Kind == .Broken;
		/// Attribute source text before the declaration (`[Node(Category="Math"), Pure]`), or null.
		public String Attributes ~ delete _;

		// Namespace / Type
		public String TypeKind ~ delete _;             // class, struct, interface, enum, extension
		public List<Member> Members ~ DeleteContainerAndItems!(_);
		public int32 OpenBrace = -1;
		public int32 CloseBrace = -1;

		// Method / Field / Property
		public String TypeText ~ delete _;             // return type or field type
		public List<Param> Params ~ DeleteContainerAndItems!(_);
		public int32 ParamsOpenTok = -1;               // '(' of the parameter list
		public int32 ParamsCloseTok = -1;              // ')' of the parameter list
		public int32 NameTok = -1;
		public bool IsCtor;
		public bool IsDtor;
		public bool IsMixin;
		public bool IsStatic;
		/// A Node Library: `static class Name` (a class whose members are all static).
		public bool IsNodeLibrary
		{
			get
			{
				if (Kind != .Type || TypeKind != "class")
					return false;
				for (let w in Modifiers.Split(' ', '\t', '\r', '\n'))
					if (w == "static")
						return true;
				return false;
			}
		}
		public Stmt Body ~ delete _;                   // Block, when the method has one

		// Declaration spans (token indices, -1 = absent), used by the class-level edits
		// (docs/Classes-and-Members.md): every part of a declaration can be replaced on its own.
		public int32 AttrFirstTok = -1;                // first '[' of the attributes
		public int32 AttrLastTok = -1;                 // last ']' of the attributes
		public int32 ModFirstTok = -1;                 // first modifier word
		public int32 ModLastTok = -1;                  // last modifier word
		public int32 KindTok = -1;                     // types: `class` / `struct` / ...
		public int32 GenericOpenTok = -1;              // '<' after the name (types and methods)
		public int32 GenericCloseTok = -1;             // its '>' (or the '>>' that closes it)
		public int32 BaseColonTok = -1;                // types: ':' of the base list
		public int32 BaseLastTok = -1;                 // types: last token of the base list
		public int32 WhereFirstTok = -1;               // first `where` of the constraints
		public int32 WhereLastTok = -1;                // last token of the constraints
		public int32 InitTok = -1;                     // fields: '=' of the initializer
		/// Fields: the `~` of the destructor clause (`~ delete _`), -1 when there is none.
		public int32 DtorTok = -1;
		/// Property accessors: `get` / `set` (`Name` is "Prop.get"); they are methods in the
		/// property's `Members`, so they get graphs like any method.
		public bool IsAccessor;
		/// `int this[int i] { get ... }` (Name "this", Params = the index parameters).
		public bool IsIndexer;
		/// Accessors: the property they belong to (owned by the parent list, not by this member).
		public Member AccessorOf;
		/// The preprocessor arms the member is declared in (`if BF_X`, `else BF_X`, nested ones
		/// joined by `; `), or null outside every `#if`.
		public String CondPath ~ delete _;
		/// Added to the method key when another member of the same type has the same name and
		/// parameters in another `#if` / `#else` arm (` [else BF_X]`); null otherwise, so the keys
		/// of every other method are unchanged.
		public String KeySuffix ~ delete _;

		public this(MemberKind kind)
		{
			Kind = kind;
		}

		/// What is wrong with a member the editor cannot use as written: the parser's message
		/// for a Broken member (without its "line N: " prefix), or a declaration error the
		/// compiler would report on a function that did parse (`var F()` outside a [Comptime]
		/// function, `let F()`). False when there is none.
		public bool GetDeclError(String outMessage)
		{
			if (Kind == .Broken)
			{
				StringView msg = (Error != null && !Error.IsEmpty) ? (StringView)Error : "the parser could not read this member";
				if (msg.StartsWith("line "))
				{
					int colon = msg.IndexOf(": ");
					if (colon > 0)
						msg = msg.Substring(colon + 2);
				}
				outMessage.Append(msg);
				return true;
			}
			String scopeGenerics = scope .();
			String why = scope .();
			if (Kind == .Field || Kind == .Property)
			{
				if (TypeText == null || TypeText.IsEmpty)
					return false;
				if (!TypeSlotRules.Check(TypeText, .Member, GetTypeScope(scopeGenerics), why))
				{
					outMessage.AppendF("Variable Type {}", why);
					return true;
				}
				return false;
			}
			if (Kind != .Method || TypeText == null)
				return false;
			let sc = GetTypeScope(scopeGenerics);
			if (!IsCtor && !IsDtor && !IsMixin && !IsAccessor && !TypeText.IsEmpty)
			{
				if (!TypeSlotRules.Check(TypeText, .Return, sc, why))
				{
					outMessage.AppendF("Return Type {} Pick one in Properties > Outputs > Return Type.", why);
					return true;
				}
			}
			if (Params != null)
			{
				for (int pi < Params.Count)
				{
					let p = Params[pi];
					if (!TypeSlotRules.CheckParamModifier(p.Modifier, why))
					{
						outMessage.AppendF("Parameter '{}': {}", p.Name, why);
						return true;
					}
					if (p.Type.IsEmpty)
						continue;
					if (p.Modifier == "params" && pi != Params.Count - 1)
					{
						outMessage.AppendF("Parameter '{}': 'params' is not allowed here: only the last parameter can be params.", p.Name);
						return true;
					}
					if (!TypeSlotRules.Check(p.Type, .Param, sc, why))
					{
						outMessage.AppendF("Parameter '{}': Type {}", p.Name, why);
						return true;
					}
				}
			}
			return false;
		}

		/// The type this member is declared in (null for a namespace member), set after a parse.
		public Member Owner;
		/// Generic parameters this declaration itself declares, comma separated (null for none).
		public String OwnGenerics ~ delete _;

		/// What is in scope for the types written in this member: the generic parameters of the
		/// member and of every enclosing type, whether it is inside a type, whether it is [Comptime].
		public TypeScope GetTypeScope(String outGenerics)
		{
			Member m = this;
			while (m != null)
			{
				if (m.OwnGenerics != null && !m.OwnGenerics.IsEmpty)
				{
					if (!outGenerics.IsEmpty)
						outGenerics.Append(',');
					outGenerics.Append(m.OwnGenerics);
				}
				m = m.Owner;
			}
			TypeScope sc = default;
			sc.Generics = outGenerics;
			sc.GenericsKnown = true;
			sc.InType = (Kind == .Type) || Owner != null;
			sc.Comptime = Attributes != null && Attributes.Contains("Comptime");
			sc.Mixin = IsMixin;
			return sc;
		}
	}

	/// A parsed source file. Owns its text and tokens; all nodes refer into them.
	class CompilationUnit
	{
		public String Text = new .() ~ delete _;
		public List<Token> Tokens = new .() ~ delete _;
		public List<Member> Members = new .() ~ DeleteContainerAndItems!(_);

		List<int32> mLineStarts ~ delete _;
		/// Where the preprocessor arm path changes: (token index, path from that token on).
		List<(int32 tok, String path)> mCondPoints ~ { if (_ != null) for (let p in _) delete p.path; delete _; };

		/// The `#if` / `#elif` / `#else` arms in force at a token (directives in the leading
		/// trivia of that token count), as `if A`, `else A`, `elif B`, nested ones joined by
		/// `; `. Empty outside every conditional.
		public StringView CondPathAt(int tokIdx)
		{
			if (mCondPoints == null)
				BuildCondPoints();
			StringView path = "";
			for (let p in mCondPoints)
			{
				if (p.tok > tokIdx)
					break;
				path = p.path;
			}
			return path;
		}

		void BuildCondPoints()
		{
			mCondPoints = new .();
			List<(String kind, String cond)> stack = scope .();
			defer { for (let e in stack) { delete e.kind; delete e.cond; } }
			String current = scope .();
			for (int i < Tokens.Count)
			{
				let trivia = LeadingTrivia(i);
				if (!trivia.Contains('#'))
					continue;
				bool changed = false;
				for (var line in trivia.Split('\n'))
				{
					line.Trim();
					if (!line.StartsWith('#'))
						continue;
					var rest = line.Substring(1);
					rest.TrimStart();
					int sp = 0;
					while (sp < rest.Length && rest[sp].IsLetter)
						sp++;
					let word = rest.Substring(0, sp);
					var cond = rest.Substring(sp);
					int comment = cond.IndexOf("//");
					if (comment >= 0)
						cond = cond.Substring(0, comment);
					cond.Trim();
					if (word == "if")
					{
						stack.Add((new String("if"), new String(cond)));
						changed = true;
					}
					else if ((word == "elif" || word == "else") && !stack.IsEmpty)
					{
						let top = stack.Back;
						top.kind.Set(word);
						if (word == "elif")
							top.cond.Set(cond);
						changed = true;
					}
					else if (word == "endif" && !stack.IsEmpty)
					{
						let e = stack.PopBack();
						delete e.kind;
						delete e.cond;
						changed = true;
					}
				}
				if (!changed)
					continue;
				current.Clear();
				for (let e in stack)
				{
					if (@e.Index > 0)
						current.Append("; ");
					current.AppendF("{} {}", e.kind, e.cond);
				}
				mCondPoints.Add(((int32)i, new String(current)));
			}
		}

		/// 1-based line number of a character offset.
		public int32 LineOf(int charPos)
		{
			if (mLineStarts == null)
			{
				mLineStarts = new .();
				mLineStarts.Add(0);
				for (int i < Text.Length)
					if (Text[i] == '\n')
						mLineStarts.Add((int32)(i + 1));
			}
			// Binary search for the last line start <= charPos
			int lo = 0;
			int hi = mLineStarts.Count - 1;
			while (lo < hi)
			{
				int mid = (lo + hi + 1) / 2;
				if (mLineStarts[mid] <= charPos)
					lo = mid;
				else
					hi = mid - 1;
			}
			return (int32)(lo + 1);
		}

		public StringView TokenText(int idx)
		{
			let tok = Tokens[idx];
			return StringView(Text, tok.Start, tok.End - tok.Start);
		}

		/// Exact source text of a node (no leading trivia, no trailing trivia).
		public StringView NodeText(SyntaxNode node)
		{
			if (!node.HasSpan)
				return "";
			let first = Tokens[node.FirstTok];
			let last = Tokens[node.LastTok];
			return StringView(Text, first.Start, last.End - first.Start);
		}

		public StringView SpanText(int firstTok, int lastTok)
		{
			if (firstTok < 0 || lastTok < firstTok)
				return "";
			let first = Tokens[firstTok];
			let last = Tokens[lastTok];
			return StringView(Text, first.Start, last.End - first.Start);
		}

		/// Leading trivia (comments, blank lines, indentation) before a token.
		public StringView LeadingTrivia(int tokIdx)
		{
			let tok = Tokens[tokIdx];
			return StringView(Text, tok.LeadStart, tok.Start - tok.LeadStart);
		}

		/// Trailing trivia after a token, up to and including the line break.
		public StringView TrailingTrivia(int tokIdx)
		{
			let tok = Tokens[tokIdx];
			return StringView(Text, tok.End, tok.TrailEnd - tok.End);
		}

		/// Whitespace at the start of the line that contains the given token.
		public void GetLineIndent(int tokIdx, String outIndent)
		{
			int p = Tokens[tokIdx].Start;
			int lineStart = p;
			while (lineStart > 0 && Text[lineStart - 1] != '\n')
				lineStart--;
			int i = lineStart;
			while (i < Text.Length && (Text[i] == ' ' || Text[i] == '\t'))
				i++;
			outIndent.Append(StringView(Text, lineStart, i - lineStart));
		}

		/// Visits every method in the file (including nested types), depth-first in source order.
		public void CollectMethods(List<Member> outMethods, List<Member> outOwners)
		{
			CollectMethods(Members, null, outMethods, outOwners);
		}

		void CollectMethods(List<Member> members, Member owner, List<Member> outMethods, List<Member> outOwners)
		{
			for (let m in members)
			{
				// Broken members are listed with the methods (they have no Body, so they are not
				// graphable) so that every consumer shows them instead of silently dropping them.
				if (m.Kind == .Method || m.Kind == .Broken)
				{
					outMethods.Add(m);
					outOwners?.Add(owner);
				}
				else if (m.Kind == .Property && m.Members != null)
				{
					// Accessors belong to the property's type.
					for (let a in m.Members)
					{
						if (a.Kind != .Method)
							continue;
						outMethods.Add(a);
						outOwners?.Add(owner);
					}
				}
				else if (m.Members != null)
					CollectMethods(m.Members, (m.Kind == .Type) ? m : owner, outMethods, outOwners);
			}
		}

		public void CollectTypes(List<Member> outTypes)
		{
			CollectTypes(Members, outTypes);
		}

		void CollectTypes(List<Member> members, List<Member> outTypes)
		{
			for (let m in members)
			{
				if (m.Kind == .Type)
					outTypes.Add(m);
				if (m.Members != null)
					CollectTypes(m.Members, outTypes);
			}
		}
	}
}
