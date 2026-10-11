using System;
using System.Collections;
using System.IO;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// Ownership and initial values (docs/Classes-and-Members.md > Ownership and initial values):
	/// MemberInit read / write of every form (part of `classes`), and `inits <paths>`: every member
	/// variable of a corpus read, written back byte for byte, flipped to another choice and back.
	static class InitTests
	{
		public static int sFailures;
		public static int sChecks;

		static void Check(bool cond, StringView what)
		{
			sChecks++;
			if (cond)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		const String cSample = """
			namespace Game
			{
				enum Color { Red, Green, Blue }
				struct Point { public int X; public int Y; }
				interface IThing { }
				class Application { }
				class Holder
				{
					public Application mOwned = new .() ~ delete _;
					public Application mLater ~ delete _;
					public Application mRef;
					public Application* mPtr;
					public Application mInside = append .();
					public Point mPoint = .();
					public Point mPoint2 = .(1, 2);
					public Point mPoint3 = default;
					public int mCount = 5;
					public float mSpeed = 1.5f;
					public bool mOn = true;
					public char8 mC = 'a';
					public String mName = new .("hi") ~ delete _;
					public StringView mView = "x";
					public Color mColor = .Red;
					public IThing mThing;
					public List<String> mList = new .() ~ DeleteContainerAndItems!(_);
					public int[] mArr = new int[4] ~ delete _;
					public Application mOdd = new .()~delete _;
					public Application mMade = Make();
					public int a, b;
					public int mNeg = -3;
					public int mBits = ~0;
					public static Application sShared = new .() ~ delete _;
					public Application mNullOwned = null ~ delete _;
					public List<int> mParen = new .() ~ delete(_);
					public int mAligned     = 1 ;
					public int Auto { get; set; } = 3;
					public int Bare { get; set; }
					public const int cMax = 10;

					static Application Make() => null;
				}
				struct Box
				{
					public int mV;
					public Application mApp;
				}
			}

			""";

		static Member FindType(SourceDocument doc, StringView name)
		{
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		static Member FindMember(SourceDocument doc, StringView type, StringView name)
		{
			let t = FindType(doc, type);
			if (t?.Members == null)
				return null;
			for (let m in t.Members)
				if (m.Name == name)
					return m;
			return null;
		}

		static bool HasLine(SourceDocument doc, StringView line)
		{
			return doc.Text.Contains(scope $"\t\t{line}\n");
		}

		/// Reads a member and checks its choice, value kind and that it writes back unchanged.
		static void Expect(SourceDocument doc, TypeService ts, StringView name, InitOwnership owner, InitValueKind value, StringView what, StringView typeName = "Holder")
		{
			let m = FindMember(doc, typeName, name);
			MemberInit init = scope .();
			bool read = m != null && doc.ReadMemberInit(m, MemberInit.TypeOf(m.TypeText, ts), init);
			Check(read && init.Owner == owner && init.ValueKind == value, scope $"{what}: {name} is {owner} / {value} (got {init.Owner} / {init.ValueKind})");
			if (!read)
				return;
			doc.InitRange(m, let s, let e, let isProp);
			var tail = StringView(doc.Text, s, e - s);
			if (isProp && tail.EndsWith(';'))
				tail.RemoveFromEnd(1);
			String emitted = scope .();
			init.Emit(emitted);
			Check(emitted == tail, scope $"{name} writes back byte for byte");
		}

		static bool Set(SourceDocument doc, TypeService ts, StringView type, StringView name, delegate void(MemberInit init, InitType t) change, bool withType = true)
		{
			let m = FindMember(doc, type, name);
			if (m == null)
				return false;
			let t = MemberInit.TypeOf(m.TypeText, ts);
			MemberInit init = scope .();
			if (!doc.ReadMemberInit(m, t, init))
				return false;
			change(init, t);
			String newType = scope .();
			if (withType)
				MemberInit.TypeFor(init.Owner, m.TypeText, newType);
			return doc.SetMemberInit(m, init, newType, FindType(doc, type));
		}

		public static int RunChecks()
		{
			Console.WriteLine("ownership and initial values");
			ProjectIndex index = scope .();
			TypeService ts = new .(index);
			ts.AutoLoadLibraries = false;
			ts.Install();
			let oldIndex = GraphBuilder.Index;
			GraphBuilder.Index = index;
			defer
			{
				GraphBuilder.Index = oldIndex;
				delete ts;
				TypeService.Current = null;
				TypeRules.Hierarchy = null;
			}
			{
				let unit = Parser.Parse(cSample);
				index.Update("Holder.bf", unit);
				delete unit;
			}
			ts.Sync();

			SourceDocument doc = scope .();
			doc.LoadFromText(cSample, "Holder.bf");
			String before = scope .(doc.Text);

			// Parsing: `~` after the name is a member variable, `~0` is a value.
			let later = FindMember(doc, "Holder", "mLater");
			Check(later != null && later.Kind == .Field && later.DtorTok > 0 && doc.Unit.TokenText(later.DtorTok) == "~", "`T x ~ delete _;` is a member variable with a destructor clause");
			let bits = FindMember(doc, "Holder", "mBits");
			Check(bits != null && bits.Kind == .Field && bits.DtorTok < 0, "`int x = ~0;` has no destructor clause");
			let owned = FindMember(doc, "Holder", "mOwned");
			Check(owned != null && owned.InitTok > 0 && owned.DtorTok > owned.InitTok, "`= new .() ~ delete _`: initializer, then destructor clause");

			// Type kinds.
			Check(MemberInit.TypeOf("Application", ts).Kind == .Class, "type kind: class from the index");
			Check(MemberInit.TypeOf("IThing", ts).Kind == .Interface, "type kind: interface");
			Check(MemberInit.TypeOf("Point", ts).Kind == .Struct, "type kind: struct");
			Check(MemberInit.TypeOf("Color", ts).Kind == .Enum, "type kind: enum");
			let ptr = MemberInit.TypeOf("Application*", ts);
			Check(ptr.IsPointer && ptr.Kind == .Class && ptr.BaseText == "Application", "type kind: pointer to a class");
			Check(MemberInit.TypeOf("int").Kind == .Integer && MemberInit.TypeOf("float").Kind == .Float && MemberInit.TypeOf("bool").Kind == .Bool &&
				MemberInit.TypeOf("char8").Kind == .Char && MemberInit.TypeOf("String").Kind == .String && MemberInit.TypeOf("StringView").Kind == .StringView, "type kind: built-in types");
			Check(MemberInit.TypeOf("int[]").Kind == .Class && MemberInit.TypeOf("int[4]").Kind == .Struct && MemberInit.TypeOf("int?").Kind == .Struct, "type kind: arrays, fixed arrays, nullable");
			Check(MemberInit.TypeOf("List<String>").Kind == .Class, "type kind: corlib containers without an index");

			// Choices.
			{
				List<InitOwnership> c = scope .();
				MemberInit.Choices(MemberInit.TypeOf("IThing", ts), true, false, c);
				Check(c.Count == 2 && c[0] == .Reference && c[1] == .Pointer, "interface: Reference and Pointer only");
				c.Clear();
				MemberInit.Choices(MemberInit.TypeOf("Application", ts), true, false, c);
				Check(c.Count == 6 && c[0] == .OwnedCreatedHere && c.Contains(.Appended) && c.Contains(.DisposedWith) && !c.Contains(.OwnedForRun), "class in a class: owned (here / later), reference, appended, disposed with it, pointer");
				c.Clear();
				MemberInit.Choices(MemberInit.TypeOf("Application", ts), false, false, c);
				Check(!c.Contains(.Appended), "class in a struct: no appended");
				c.Clear();
				MemberInit.Choices(MemberInit.TypeOf("Application", ts), true, true, c);
				Check(!c.Contains(.Appended), "static member: no appended");
				c.Clear();
				MemberInit.Choices(MemberInit.TypeOf("Point", ts), true, false, c);
				Check(c.Count == 3 && c[0] == .ValueDefault && c[1] == .DisposedWith, "struct: value, disposed with it, or pointer");
				c.Clear();
				MemberInit.Choices(MemberInit.TypeOf("Application", ts), true, true, c);
				Check(c.Contains(.OwnedForRun) && !c.Contains(.Appended), "static class member: owned for the run");
				c.Clear();
				MemberInit.Choices(MemberInit.TypeOf("Nowhere.Thing", ts), true, true, c);
				Check(MemberInit.TypeOf("Nowhere.Thing", ts).Kind == .Unknown && c.Count == 7 && c.Contains(.OwnedForRun) && c.Contains(.DisposedWith) && c.Contains(.OwnedCreatedHere), "type not indexed: every choice is kept");
				c.Clear();
				MemberInit.Choices(MemberInit.TypeOf("int"), true, false, c);
				Check(c.Count == 2 && c[0] == .None, "int: value or pointer");
			}

			// Reading every form.
			Expect(doc, ts, "mOwned", .OwnedCreatedHere, .None, "owned, created here");
			Expect(doc, ts, "mLater", .OwnedCreatedLater, .None, "owned, created later");
			Expect(doc, ts, "mRef", .Reference, .None, "reference");
			Expect(doc, ts, "mPtr", .Pointer, .None, "pointer");
			Expect(doc, ts, "mInside", .Appended, .None, "appended");
			Expect(doc, ts, "mPoint", .ValueDefault, .Construct, "struct `.()`");
			Expect(doc, ts, "mPoint2", .ValueDefault, .Construct, "struct `.(1, 2)`");
			Expect(doc, ts, "mPoint3", .ValueDefault, .Default, "struct `default`");
			Expect(doc, ts, "mCount", .None, .Literal, "int literal");
			Expect(doc, ts, "mSpeed", .None, .Literal, "float literal");
			Expect(doc, ts, "mOn", .None, .Literal, "bool literal");
			Expect(doc, ts, "mC", .None, .Literal, "char literal");
			Expect(doc, ts, "mName", .OwnedCreatedHere, .None, "owned String with its text");
			Expect(doc, ts, "mView", .None, .Literal, "StringView literal");
			Expect(doc, ts, "mColor", .None, .EnumCase, "enum member");
			Expect(doc, ts, "mThing", .Reference, .None, "interface reference");
			Expect(doc, ts, "mList", .OwnedCreatedHere, .None, "container deleted with its items");
			Expect(doc, ts, "mArr", .OwnedCreatedHere, .None, "owned array");
			Expect(doc, ts, "mOdd", .Custom, .None, "spacing differs");
			Expect(doc, ts, "mMade", .Reference, .Custom, "reference to what a call returns");
			Expect(doc, ts, "mNeg", .None, .Literal, "negative literal");
			Expect(doc, ts, "mBits", .None, .Custom, "expression `~0`");
			Expect(doc, ts, "mNullOwned", .OwnedCreatedLater, .Null, "owned, created later, with `= null`");
			Expect(doc, ts, "mParen", .OwnedCreatedHere, .None, "deleter written `delete(_)`");
			Expect(doc, ts, "mAligned", .None, .Literal, "aligned declaration keeps its spacing");
			Expect(doc, ts, "Auto", .None, .Literal, "auto-property initial value");
			Expect(doc, ts, "Bare", .None, .None, "auto-property without a value");
			Expect(doc, ts, "cMax", .None, .Literal, "const");
			{
				MemberInit init = scope .();
				doc.ReadMemberInit(FindMember(doc, "Holder", "mList"), MemberInit.TypeOf("List<String>"), init);
				Check(init.Deleter == "DeleteContainerAndItems!(_)", "deleter read: DeleteContainerAndItems!(_)");
				doc.ReadMemberInit(FindMember(doc, "Holder", "mArr"), MemberInit.TypeOf("int[]"), init);
				Check(init.ArrayAlloc && init.AllocType == "int" && init.Args == "4", "array allocation read: int[4]");
				doc.ReadMemberInit(FindMember(doc, "Holder", "mOdd"), MemberInit.TypeOf("Application", ts), init);
				Check(init.CanConvert && init.Raw == " = new .()~delete _", "custom keeps the raw text and can be converted");
				Check(!FindMember(doc, "Holder", "a").IsBroken && !doc.InitRange(FindMember(doc, "Holder", "a"), ?, ?, ?) && doc.LastError.Contains("several"), "`int a, b;` is refused with a reason");
			}
			{
				MemberInit init = scope .();
				init.Classify(" = new  .()", MemberInit.TypeOf("Application", ts));
				Check(init.Owner == .Custom && !init.CanConvert, "`new` without a destructor clause stays custom (not convertible)");
				init.Classify(" ~ { delete _; }", MemberInit.TypeOf("Application", ts));
				Check(init.Owner == .Custom && init.Raw == " ~ { delete _; }", "a destructor block stays custom");
				init.Classify(" = new .(1)", MemberInit.TypeOf("Application", ts), true);
				String em = scope .();
				init.Emit(em);
				Check(init.Owner == .OwnedForRun && init.Args == "1" && em == " = new .(1)", "static `= new .(1)` without a destructor is Owned for the run");
				init.Classify(" = new Application(2)", MemberInit.TypeOf("Application", ts), true);
				Check(init.Owner == .OwnedForRun && init.AllocType == "Application" && init.Args == "2", "Owned for the run keeps a named type");
				init.Classify(" ~ _.Dispose()", MemberInit.TypeOf("Point", ts));
				em.Clear();
				init.Emit(em);
				Check(init.Owner == .DisposedWith && init.ValueKind == .None && em == " ~ _.Dispose()", "`~ _.Dispose()` is Disposed with it");
				init.Classify(" = .(2) ~ _.Dispose()", MemberInit.TypeOf("Point", ts));
				em.Clear();
				init.Emit(em);
				Check(init.Owner == .DisposedWith && init.ValueKind == .Construct && init.Args == "2" && em == " = .(2) ~ _.Dispose()", "`= .(2) ~ _.Dispose()` is Disposed with it, made with 2");
				init.Classify(" =.(2)~_.Dispose()", MemberInit.TypeOf("Point", ts));
				Check(init.Owner == .Custom && init.CanConvert && init.ConvertOwner == .DisposedWith, "Dispose written with other spacing converts");
				init.Convert();
				em.Clear();
				init.Emit(em);
				Check(init.Owner == .DisposedWith && em == " = .(2) ~ _.Dispose()", "converted to the usual spacing");
				init.Classify(" = 5 ~ _.Dispose()", MemberInit.TypeOf("int"));
				Check(init.Owner == .DisposedWith && init.ValueKind == .Literal, "a value before Dispose is read too");
				init.Classify(" = 1 // one", MemberInit.TypeOf("int"));
				Check(init.Owner == .Custom && !init.CanConvert, "a comment inside the clause stays custom");
				init.Classify(" = $\"a{1}\"", MemberInit.TypeOf("String"));
				Check(init.Owner == .Reference && init.ValueKind == .Custom, "an interpolated string is an expression");
			}

			// Edits: only the edited member changes, one undo step each.
			{
				int depth = doc.UndoDepth;
				Check(Set(doc, ts, "Holder", "mRef", scope (i, t) => i.Retarget(.OwnedCreatedHere, t)) && HasLine(doc, "public Application mRef = new .() ~ delete _;"), "reference -> owned, created here");
				Check(doc.UndoDepth == depth + 1, "one undo step");
				Check(Set(doc, ts, "Holder", "mRef", scope (i, t) => i.Retarget(.Reference, t)) && HasLine(doc, "public Application mRef;"), "owned -> reference");
				Check(Set(doc, ts, "Holder", "mRef", scope (i, t) => i.Retarget(.OwnedCreatedLater, t)) && HasLine(doc, "public Application mRef ~ delete _;"), "reference -> owned, created later");
				Check(Set(doc, ts, "Holder", "mRef", scope (i, t) => i.Retarget(.Pointer, t)) && HasLine(doc, "public Application* mRef;"), "-> pointer adds the `*`");
				Check(Set(doc, ts, "Holder", "mRef", scope (i, t) => i.Retarget(.Appended, t)) && HasLine(doc, "public Application mRef = append .();"), "pointer -> appended removes the `*`");
				Check(Set(doc, ts, "Holder", "mRef", scope (i, t) => { i.Retarget(.OwnedCreatedHere, t); i.Args.Set("1, 2"); }) && HasLine(doc, "public Application mRef = new .(1, 2) ~ delete _;"), "owned with constructor arguments");
				Check(Set(doc, ts, "Holder", "mList", scope (i, t) => i.Deleter.Set("delete _")) && HasLine(doc, "public List<String> mList = new .() ~ delete _;"), "deleter changed");
				Check(Set(doc, ts, "Holder", "mCount", scope (i, t) => { i.ValueKind = .Literal; MemberInit.FormatNumber("42", "int", i.Value..Clear()); }) && HasLine(doc, "public int mCount = 42;"), "int initial value");
				Check(Set(doc, ts, "Holder", "mCount", scope (i, t) => i.ValueKind = .Default) && HasLine(doc, "public int mCount = default;"), "int -> default");
				Check(Set(doc, ts, "Holder", "mCount", scope (i, t) => i.ValueKind = .None) && HasLine(doc, "public int mCount;"), "int -> no initial value");
				Check(Set(doc, ts, "Holder", "mSpeed", scope (i, t) => { i.ValueKind = .Literal; MemberInit.FormatNumber("2", "float", i.Value..Clear()); }) && HasLine(doc, "public float mSpeed = 2.0f;"), "float initial value gets its suffix");
				Check(Set(doc, ts, "Holder", "mOn", scope (i, t) => i.Value.Set("false")) && HasLine(doc, "public bool mOn = false;"), "bool initial value");
				Check(Set(doc, ts, "Holder", "mC", scope (i, t) => MemberInit.QuoteChar('\'', i.Value..Clear())) && HasLine(doc, "public char8 mC = '\\'';"), "char initial value escaped");
				{
					// Code points, not bytes: 'é' is two UTF-8 bytes, '😀' four. Beef 0.43.6: char8 holds up to U+00FF,
					// char16 up to U+FFFF, char32 any (checked with BeefBuild).
					String lit = scope .();
					String why = scope .();
					Check(MemberInit.QuoteCharFor("é", "char8", lit..Clear(), why) && lit == "'é'", "char8 'é' accepted (one code point, two bytes)");
					Check(MemberInit.QuoteCharFor("é", "char16", lit..Clear(), why) && lit == "'é'" && MemberInit.QuoteCharFor("é", "char32", lit..Clear(), why) && lit == "'é'", "char16 / char32 'é' accepted");
					Check(!MemberInit.QuoteCharFor("😀", "char8", lit..Clear(), why..Clear()) && why.Contains("char32"), "char8 '😀' refused, pointing at char32");
					Check(!MemberInit.QuoteCharFor("😀", "char16", lit..Clear(), why..Clear()) && why.Contains("U+1F600"), "char16 '😀' refused (outside U+FFFF)");
					Check(MemberInit.QuoteCharFor("😀", "char32", lit..Clear(), why) && lit == "'😀'", "char32 '😀' accepted");
					Check(!MemberInit.QuoteCharFor("ā", "char8", lit..Clear(), why..Clear()) && MemberInit.QuoteCharFor("ā", "char16", lit..Clear(), why), "'ā' (U+0101): char8 refused, char16 accepted");
					Check(!MemberInit.QuoteCharFor("ab", "char32", lit..Clear(), why..Clear()) && why.Contains("one character") && !MemberInit.QuoteCharFor("", "char8", lit..Clear(), why..Clear()), "two characters and none refused");
					Check(MemberInit.QuoteCharFor("'", "char8", lit..Clear(), why) && lit == "'\\''" && MemberInit.QuoteCharFor("\n", "char8", lit..Clear(), why) && lit == "'\\n'", "ASCII still escaped");
					String back = scope .();
					Check(MemberInit.QuoteCharFor("😀", "char32", lit..Clear(), why) && MemberInit.UnquoteLiteral(lit, back) && back == "😀", "the literal reads back as the same character");
				}
				Check(Set(doc, ts, "Holder", "mView", scope (i, t) => MemberInit.QuoteString("say \"hi\"\n", i.Value..Clear())) && HasLine(doc, "public StringView mView = \"say \\\"hi\\\"\\n\";"), "string initial value escaped");
				Check(Set(doc, ts, "Holder", "mColor", scope (i, t) => i.Value.Set(".Blue")) && HasLine(doc, "public Color mColor = .Blue;"), "enum member picked");
				Check(Set(doc, ts, "Holder", "mPoint", scope (i, t) => i.ValueKind = .Default) && HasLine(doc, "public Point mPoint = default;"), "struct -> default");
				Check(Set(doc, ts, "Holder", "mPoint3", scope (i, t) => { i.ValueKind = .Construct; i.AllocType.Set("."); i.Args.Set("3, 4"); }) && HasLine(doc, "public Point mPoint3 = .(3, 4);"), "struct -> .(3, 4)");
				Check(Set(doc, ts, "Holder", "mOdd", scope (i, t) => i.Convert()) && HasLine(doc, "public Application mOdd = new .() ~ delete _;"), "custom converted");
				Check(Set(doc, ts, "Holder", "mName", scope (i, t) => i.Retarget(.Reference, t)) && HasLine(doc, "public String mName = \"hi\";"), "owned String -> reference keeps the text as a literal");
				Check(Set(doc, ts, "Holder", "mName", scope (i, t) => i.Retarget(.OwnedCreatedHere, t)) && HasLine(doc, "public String mName = new .(\"hi\") ~ delete _;"), "String literal -> owned String with that text");
				Check(Set(doc, ts, "Holder", "mMade", scope (i, t) => { i.ValueKind = .Custom; i.Value.Set("Make() ?? null"); }) && HasLine(doc, "public Application mMade = Make() ?? null;"), "custom value written as typed");
				Check(Set(doc, ts, "Holder", "Auto", scope (i, t) => i.Value.Set("4")) && HasLine(doc, "public int Auto { get; set; } = 4;"), "auto-property value changed");
				Check(Set(doc, ts, "Holder", "Auto", scope (i, t) => i.ValueKind = .None) && HasLine(doc, "public int Auto { get; set; }"), "auto-property value removed (with its `;`)");
				Check(Set(doc, ts, "Holder", "Bare", scope (i, t) => { i.ValueKind = .Literal; i.Value.Set("7"); }) && HasLine(doc, "public int Bare { get; set; } = 7;"), "auto-property value added");
				Check(!Set(doc, ts, "Holder", "Bare", scope (i, t) => i.Retarget(.OwnedCreatedHere, t)) && doc.LastError.Contains("property"), "owned on a property refused");
				Check(!Set(doc, ts, "Holder", "sShared", scope (i, t) => i.Retarget(.Appended, t)) && doc.LastError.Contains("static"), "appended on a static member refused");
				Check(!Set(doc, ts, "Box", "mApp", scope (i, t) => i.Retarget(.Appended, t)) && doc.LastError.Contains("struct"), "appended in a struct refused");
				Check(!Set(doc, ts, "Holder", "cMax", scope (i, t) => i.Retarget(.OwnedCreatedHere, t), false) && doc.LastError.Contains("const"), "owned on a const refused");
				int d2 = doc.UndoDepth;
				Check(Set(doc, ts, "Holder", "mOwned", scope (i, t) => { }) && doc.UndoDepth == d2, "writing the same choice is no edit");
				while (doc.UndoDepth > depth)
					doc.Undo();
				Check(doc.Text == before, "undo restores every edit");
			}
			// SetFieldInitializer on `T x ~ delete _;` puts the value before the clause.
			{
				doc.SetFieldInitializer(FindMember(doc, "Holder", "mLater"), "new .()");
				Check(HasLine(doc, "public Application mLater = new .() ~ delete _;"), "Default Value on an owned-later member goes before `~`");
				doc.Undo();
			}

			// Literals.
			{
				String o = scope .();
				Check(MemberInit.FormatNumber("1.5", "float", o) && o == "1.5f", "float 1.5 -> 1.5f");
				o.Clear();
				Check(MemberInit.FormatNumber("3", "double", o) && o == "3.0", "double 3 -> 3.0");
				o.Clear();
				Check(MemberInit.FormatNumber("-7", "int", o) && o == "-7", "int -7");
				o.Clear();
				Check(!MemberInit.FormatNumber("-7", "uint8", o), "negative refused for an unsigned type");
				Check(!MemberInit.FormatNumber("abc", "int", o), "not a number refused");
				// Ranges: a value that does not fit the type is refused, the whole uint64 range is accepted.
				Check(!MemberInit.FormatNumber("300", "uint8", o) && !MemberInit.FormatNumber("128", "int8", o) && !MemberInit.FormatNumber("99999999999999999999", "int64", o), "out of range refused (uint8 300, int8 128, above 2^64)");
				o.Clear();
				Check(MemberInit.FormatNumber("-128", "int8", o) && o == "-128", "int8 -128 fits");
				o.Clear();
				Check(MemberInit.FormatNumber("18446744073709551615", "uint64", o) && o == "18446744073709551615", "uint64 max fits and is written as typed");
				o.Clear();
				int64 h = 0, u = 0, n = 0;
				bool okInts = MemberInit.ParseInt("0xFF", out h);
				okInts &= MemberInit.ParseInt("5u", out u);
				okInts &= MemberInit.ParseInt("-3", out n);
				Check(okInts && h == 255 && u == 5 && n == -3, "integer literals read (hex, suffix, sign)");
				double f = 0, g = 0;
				bool okFloats = MemberInit.ParseFloat("1.5f", out f);
				okFloats &= MemberInit.ParseFloat("2", out g);
				Check(okFloats && f == 1.5 && g == 2, "float literals read");
				String q = scope .();
				MemberInit.QuoteString("a\\b\t\"c\"", q);
				Check(q == "\"a\\\\b\\t\\\"c\\\"\"", "string escaping");
				String back = scope .();
				Check(MemberInit.UnquoteLiteral(q, back) && back == "a\\b\t\"c\"", "string unescaping gives the text back");
				back.Clear();
				Check(MemberInit.UnquoteLiteral("@\"x\"\"y\"", back) && back == "x\"y", "verbatim string unescaped");
				back.Clear();
				Check(MemberInit.UnquoteLiteral("'\\x41'", back) && back == "A", "char escape \\x41");
				back.Clear();
				Check(MemberInit.UnquoteLiteral("\"a\\u{E9}b\"", back) && back == "a\u{E9}b", "unicode escape \\u{E9} unescaped");
				String q2 = scope .();
				MemberInit.QuoteString(back, q2);
				back.Clear();
				Check(MemberInit.UnquoteLiteral(q2, back) && back == "a\u{E9}b", "unicode text round-trips through the value box");
				back.Clear();
				Check(!MemberInit.UnquoteLiteral("\"\\u{zz}\"", back), "a bad unicode escape is not read as text");
				List<String> cases = scope .();
				defer { ClearAndDeleteItems!(cases); }
				MemberInit.EnumMembers("Color", ts, cases);
				Check(cases.Count == 3 && cases[2] == ".Blue", "enum members from the index");
				String prev = scope .();
				MemberInit pi = scope .();
				pi.Retarget(.OwnedCreatedHere, MemberInit.TypeOf("Application", ts));
				pi.Preview("Application", "mApp", prev);
				Check(prev == "Application mApp = new .() ~ delete _;", "preview line");
			}
			return sFailures;
		}

		// ------------------------------------------------------------------ corpus

		/// A short shape of a custom clause: names become X, numbers N, strings S, bracket contents `..`.
		static void Pattern(StringView raw, String outPat)
		{
			List<Token> toks = scope .();
			Lexer.Tokenize(raw, toks);
			int depth = 0;
			for (let t in toks)
			{
				if (t.Kind == .EOF)
					break;
				let tx = StringView(raw, t.Start, t.End - t.Start);
				bool open = tx == "(" || tx == "[" || tx == "{";
				bool close = tx == ")" || tx == "]" || tx == "}";
				if (close)
					depth--;
				if (depth > 0)
				{
					if (open)
						depth++;
					continue;
				}
				if (!outPat.IsEmpty && !open && !close && tx != "." && tx != "!" && !outPat.EndsWith('.'))
					outPat.Append(' ');
				switch (t.Kind)
				{
				case .Identifier:
					if (tx == "new" || tx == "append" || tx == "delete" || tx == "null" || tx == "default" || tx == "scope" || tx == "this" ||
						tx.StartsWith("Delete") || tx.StartsWith("Clear") || tx == "_" || tx == "typeof" || tx == "sizeof")
						outPat.Append(tx);
					else
						outPat.Append('X');
				case .Number: outPat.Append('N');
				case .String: outPat.Append('S');
				case .Char: outPat.Append('C');
				default:
					outPat.Append(tx);
				}
				if (open)
				{
					outPat.Append("..");
					depth++;
				}
			}
		}

		static void CollectFields(List<Member> members, Member owner, List<(Member m, Member owner)> outFields)
		{
			for (let m in members)
			{
				if ((m.Kind == .Namespace || m.Kind == .Type) && m.Members != null)
					CollectFields(m.Members, (m.Kind == .Type) ? m : owner, outFields);
				else if (m.Kind == .Field || (m.Kind == .Property && m.Members != null && !m.IsIndexer))
					outFields.Add((m, owner));
			}
		}

		/// `inits [-v] [-noflip] <paths>...`: each path is reported on its own.
		public static int RunCorpus(String[] args)
		{
			bool verbose = false;
			bool flip = true;
			int failures = 0;
			List<String> paths = scope .();
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-v") verbose = true;
				else if (args[i] == "-noflip") flip = false;
				else paths.Add(args[i]);
			}
			for (let path in paths)
			{
				List<String> files = scope .();
				defer { ClearAndDeleteItems!(files); }
				SaveCheckTests.[Friend]CollectFiles(path, files);
				int members = 0, custom = 0, convertible = 0, refused = 0, flips = 0, pathFailures = 0;
				int[(int)InitOwnership.Custom + 1] byOwner = default;
				Dictionary<String, int> pats = scope .();
				defer { for (let kv in pats) delete kv.key; }
				for (let f in files)
				{
					String text = scope .();
					if (File.ReadAllText(f, text, true) case .Err)
						continue;
					SourceDocument doc = scope .();
					doc.LoadFromText(text, f);
					List<(Member m, Member owner)> fields = scope .();
					CollectFields(doc.Unit.Members, null, fields);
					for (int fi < fields.Count)
					{
						var (m, owner) = fields[fi];
						if (!doc.InitRange(m, let s, let e, let isProp))
						{
							if (m.Kind == .Field)
								refused++;
							continue;
						}
						if (isProp && m.InitTok < 0)
							continue; // properties with accessor bodies are refused above; a bare auto-property has nothing to read
						members++;
						let type = MemberInit.TypeOf(m.TypeText);
						MemberInit init = scope .();
						doc.ReadMemberInit(m, type, init);
						byOwner[(int)init.Owner]++;
						var tail = StringView(doc.Text, s, e - s);
						if (isProp && tail.EndsWith(';'))
							tail.RemoveFromEnd(1);
						String emitted = scope .();
						init.Emit(emitted);
						if (emitted != tail)
						{
							pathFailures++;
							Console.WriteLine("  FAIL {}:{} {}: `{}` wrote `{}`", f, doc.Unit.LineOf(doc.Unit.Tokens[m.NameTok].Start), m.Name, tail, emitted);
						}
						if (init.Owner == .Custom)
						{
							custom++;
							if (init.CanConvert)
								convertible++;
							String pat = scope .();
							Pattern(init.Raw, pat);
							if (pats.TryGetValue(pat, var count))
								pats[pat] = count + 1;
							else
								pats[new String(pat)] = 1;
							if (verbose)
								Console.WriteLine("  custom {}:{} {}`{}`", f, doc.Unit.LineOf(doc.Unit.Tokens[m.NameTok].Start), m.Name, init.Raw);
							continue;
						}
						// Identity: writing the same choice changes nothing.
						String original = scope .(doc.Text);
						if (!doc.SetMemberInit(m, init, m.TypeText, owner) || doc.Text != original)
						{
							pathFailures++;
							Console.WriteLine("  FAIL {} {}: identity write changed the file ({})", f, m.Name, doc.LastError);
							continue;
						}
						if (!flip)
							continue;
						// Flip to another legal choice and back: the file is byte for byte what it was.
						List<InitOwnership> choices = scope .();
						bool inClass = owner == null || owner.TypeKind == "class";
						MemberInit.Choices(type, inClass, m.IsStatic || Mods.Has(m.Modifiers, "static"), choices);
						InitOwnership other = .Custom;
						for (let c in choices)
							if (c != init.Owner && !(isProp && (c == .OwnedCreatedHere || c == .OwnedCreatedLater || c == .Appended || c == .DisposedWith)) &&
								!(Mods.Has(m.Modifiers, "const") && (c == .OwnedCreatedHere || c == .OwnedCreatedLater || c == .Appended || c == .OwnedForRun || c == .DisposedWith)))
							{
								other = c;
								break;
							}
						// `T *name`: a pointer written C style comes back as `T* name` (Beef style).
						if (other == .Custom || (type.IsPointer && m.TypeText.Contains(" *")))
							continue;
						String name = scope .(m.Name);
						MemberInit flipped = scope .();
						flipped.Set(init);
						flipped.Retarget(other, type);
						String typeText = scope .(m.TypeText);
						String flippedType = scope .();
						MemberInit.TypeFor(other, typeText, flippedType);
						if (!doc.SetMemberInit(m, flipped, flippedType, owner))
						{
							pathFailures++;
							Console.WriteLine("  FAIL {} {}: flip to {} refused: {}", f, m.Name, other, doc.LastError);
							continue;
						}
						// The member objects were re-parsed: find it again by position in the list.
						List<(Member m, Member owner)> again = scope .();
						CollectFields(doc.Unit.Members, null, again);
						if (again.Count != fields.Count)
						{
							pathFailures++;
							Console.WriteLine("  FAIL {} {}: member count changed after a flip to {}: {} -> {}", f, name, other, fields.Count, again.Count);
							doc.LoadFromText(original, f);
							fields.Clear();
							CollectFields(doc.Unit.Members, null, fields);
							continue;
						}
						let m2 = again[fi].m;
						if (!doc.SetMemberInit(m2, init, typeText, again[fi].owner) || doc.Text != original)
						{
							pathFailures++;
							Console.WriteLine("  FAIL {} {}: flip to {} and back is not the original text ({})", f, name, other, doc.LastError);
							doc.LoadFromText(original, f);
						}
						else
							flips++;
						fields.Clear();
						CollectFields(doc.Unit.Members, null, fields);
					}
				}
				Console.WriteLine("inits {}: files={} members={} custom={} convertible={} multi={} flips={} failures={}", path, files.Count, members, custom, convertible, refused, flips, pathFailures);
				String line = scope .("  by choice:");
				for (int o < byOwner.Count)
					if (byOwner[o] > 0)
						line.AppendF(" {}={}", (InitOwnership)o, byOwner[o]);
				Console.WriteLine(line);
				List<(String pat, int count)> sorted = scope .();
				for (let kv in pats)
					sorted.Add((kv.key, kv.value));
				sorted.Sort(scope (a, b) => (a.count != b.count) ? b.count <=> a.count : a.pat <=> b.pat);
				for (int i < Math.Min(10, sorted.Count))
					Console.WriteLine("  custom {,4}  `{}`", sorted[i].count, sorted[i].pat);
				failures += pathFailures;
			}
			Console.WriteLine("inits: failures={}", failures);
			return (failures == 0) ? 0 : 1;
		}
	}
}
