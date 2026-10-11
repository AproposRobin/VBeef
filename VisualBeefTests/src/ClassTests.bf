using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// The type-level model (docs/Classes-and-Members.md): declaration spans and Type Settings
	/// edits (minimal diffs, one undo step each), inheritance and interfaces (Override list,
	/// missing members, stubs, override signatures), the Parent (`base`) node, the override
	/// check on the Entry node, property / indexer accessor graphs, project-wide renames and the
	/// new-type templates. `VisualBeefTests classes`.
	static class ClassTests
	{
		static int sFailures;
		static int sChecks;

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

		static void CheckText(StringView got, StringView want, StringView what)
		{
			Check(got == want, what);
			if (got != want)
				Program.ShowDiff(want, got);
		}

		/// A project index + TypeService over some files, installed like the editor does.
		class Project
		{
			public ProjectIndex Index = new .() ~ delete _;
			TypeService mService;
			ProjectIndex mOldIndex;

			public this()
			{
				mService = new .(Index);
				mService.AutoLoadLibraries = false;
				mService.Install();
				mOldIndex = GraphBuilder.Index;
				GraphBuilder.Index = Index;
			}

			public TypeService Service => mService;

			public void Add(StringView path, StringView text)
			{
				let unit = Parser.Parse(text);
				Index.Update(path, unit);
				delete unit;
			}

			public void Update(SourceDocument doc)
			{
				Index.Update(doc.FilePath, doc.Unit);
			}

			public ~this()
			{
				GraphBuilder.Index = mOldIndex;
				delete mService;
				TypeService.Current = null;
				TypeRules.Hierarchy = null;
			}
		}

		static Member FindType(SourceDocument doc, StringView name)
		{
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		static Member FindMember(Member type, StringView name)
		{
			if (type?.Members == null)
				return null;
			for (let m in type.Members)
				if (m.Name == name)
					return m;
			return null;
		}

		static bool HasNames(List<InheritedMember> list, StringView names)
		{
			int count = 0;
			for (var n in names.Split(','))
			{
				n.Trim();
				bool found = false;
				for (let m in list)
					if (m.Name == n)
						found = true;
				if (!found)
					return false;
				count++;
			}
			return count == list.Count;
		}

		// ------------------------------------------------------------------ sources

		const String cGame =
			"""
			using System;

			namespace Game
			{
				interface IDamageable
				{
					void TakeDamage(int amount);
					int Health { get; }
					bool IsAlive() => Health > 0;
				}

				abstract class Actor
				{
					public int mHp = 10;

					public abstract void Tick(float dt);

					public virtual void Spawn()
					{
						mHp = 10;
					}

					public virtual int Score { get { return 0; } }

					protected virtual bool TryGet(int key, out int value)
					{
						value = key;
						return true;
					}

					public void Plain()
					{
					}
				}

				[Reflect]
				public class Enemy : Actor, IDamageable
				{
					public override void Tick(float dt)
					{
						base.Spawn();
					}
				}

				class Holder<T>
				{
					public virtual T Get()
					{
						return default;
					}
				}

				class IntHolder : Holder<int>
				{
				}

				class Lone : Actor
				{
					public override void Tick(float dt)
					{
					}

					public override void Missing()
					{
					}
				}

				class Odd : Unknown
				{
					public override void Whatever()
					{
					}
				}

				struct Point
				{
					public int X;
					public int Y = 2;
				}
			}

			""";

		// ------------------------------------------------------------------ declarations

		const String cDecls =
			"""
			namespace A.B
			{
				[AlwaysInclude, Reflect(.All)]
				public sealed class Box<T, U> : Base<T>, IFoo where T : class where U : struct
				{
					public const int cMax = 4;
					static readonly String sName = "x";
					[Expose] public int mValue = 1;
					public int Auto { get; private set; } = 3;
					public int Calc => mValue * 2;
					public int this[int i] { get { return i; } set { mValue = value; } }
					public this() { }
					static this() { }
					public ~this() { }
					public static T Max<V>(V a) where V : IComparable { return default; }
					public abstract void NoBody();
					public extern void Native();
					public mixin Twice(var x) { x * 2 }
					public static Box<T, U> operator+(Box<T, U> a, Box<T, U> b) => a;
				}

				enum Flags : uint8 { A, B = 4 }
				struct S : SBase { }
				interface IBar : IFoo { void Do(); }
				extension Box<T, U> { }
				static class Util { }
				partial class Part { }
			}

			""";

		static void TestDeclarations()
		{
			Console.WriteLine("declaration spans (parser)");
			let unit = Parser.Parse(cDecls);
			defer delete unit;
			List<Member> types = scope .();
			unit.CollectTypes(types);
			Member boxT = null;
			for (let t in types)
				if (t.Name == "Box" && t.TypeKind == "class")
					boxT = t;
			Check(boxT != null, "class Box parsed");
			if (boxT == null)
				return;
			Check(unit.SpanText(boxT.AttrFirstTok, boxT.AttrLastTok) == "[AlwaysInclude, Reflect(.All)]", "attribute span");
			Check(unit.SpanText(boxT.ModFirstTok, boxT.ModLastTok) == "public sealed", "modifier span");
			Check(unit.TokenText(boxT.KindTok) == "class", "kind token");
			Check(unit.SpanText(boxT.GenericOpenTok, boxT.GenericCloseTok) == "<T, U>", "generic parameter span");
			Check(unit.SpanText(boxT.BaseColonTok, boxT.BaseLastTok) == ": Base<T>, IFoo", "base list span");
			Check(unit.SpanText(boxT.WhereFirstTok, boxT.WhereLastTok) == "where T : class where U : struct", "constraint span");

			TypeDeclInfo info = scope .();
			info.Read(unit, boxT);
			Check(info.Kind == "class" && info.Name == "Box" && info.Modifiers == "public sealed", "TypeDeclInfo: kind, name, modifiers");
			Check(info.Attributes.Count == 2 && info.Attributes[0] == "AlwaysInclude" && info.Attributes[1] == "Reflect(.All)", "TypeDeclInfo: attributes");
			Check(info.GenericParams == "T, U", "TypeDeclInfo: generic parameters");
			Check(info.Bases.Count == 2 && info.Bases[0] == "Base<T>" && info.Bases[1] == "IFoo", "TypeDeclInfo: base list");
			Check(info.Namespace == "A.B", "TypeDeclInfo: namespace");

			let cMax = FindMember(boxT, "cMax");
			Check(cMax != null && cMax.Kind == .Field && cMax.Modifiers == "public const" && cMax.InitTok >= 0, "const field: modifiers, initializer");
			let sName = FindMember(boxT, "sName");
			Check(sName != null && sName.IsStatic && sName.Modifiers == "static readonly" && sName.ModFirstTok >= 0, "static readonly field");
			let mValue = FindMember(boxT, "mValue");
			Check(mValue != null && mValue.Attributes == "[Expose]" && unit.SpanText(mValue.ModFirstTok, mValue.ModLastTok) == "public", "field attribute and modifier spans");
			let auto = FindMember(boxT, "Auto");
			Check(auto != null && auto.Kind == .Property && auto.Members != null && auto.Members.Count == 2 && auto.InitTok >= 0, "auto-property: two accessors, initializer");
			Check(auto != null && auto.Members != null && auto.Members.Count == 2 && auto.Members[1].Modifiers == "private" && auto.Members[1].Body == null, "auto-property: `private set;`");
			let calc = FindMember(boxT, "Calc");
			Check(calc != null && calc.Kind == .Property && calc.Members == null, "expression-bodied property (no accessors)");
			Member indexer = null;
			for (let m in boxT.Members)
				if (m.IsIndexer)
					indexer = m;
			Check(indexer != null && indexer.Kind == .Property && indexer.Params.Count == 1 && indexer.TypeText == "int", "indexer: a property with index parameters");
			Check(indexer != null && indexer.Members != null && indexer.Members.Count == 2 && indexer.Members[0].Name == "this[].get" && indexer.Members[1].Params.Count == 2, "indexer accessors: get(i), set(i, value)");
			int ctors = 0;
			bool staticCtor = false;
			bool dtor = false;
			for (let m in boxT.Members)
			{
				if (m.IsCtor)
				{
					ctors++;
					if (m.IsStatic)
						staticCtor = true;
				}
				if (m.IsDtor)
					dtor = true;
			}
			Check(ctors == 2 && staticCtor && dtor, "this(), static this(), ~this()");
			let max = FindMember(boxT, "Max");
			Check(max != null && unit.SpanText(max.GenericOpenTok, max.GenericCloseTok) == "<V>" && max.IsStatic, "generic method: span of <V>");
			let noBody = FindMember(boxT, "NoBody");
			Check(noBody != null && noBody.Body == null && noBody.Modifiers == "public abstract", "abstract method without body");
			let native = FindMember(boxT, "Native");
			Check(native != null && native.Modifiers == "public extern", "extern method");
			let twice = FindMember(boxT, "Twice");
			Check(twice != null && twice.IsMixin, "mixin");

			for (let t in types)
			{
				switch (t.Name)
				{
				case "Flags":
					Check(t.TypeKind == "enum" && unit.SpanText(t.BaseColonTok + 1, t.BaseLastTok) == "uint8", "enum: underlying type as the base list");
				case "S":
					Check(t.TypeKind == "struct" && unit.SpanText(t.BaseColonTok + 1, t.BaseLastTok) == "SBase", "struct with a base struct");
				case "IBar":
					Check(t.TypeKind == "interface" && t.BaseColonTok >= 0, "interface extending an interface");
				case "Util":
					Check(t.Modifiers == "static", "static class");
				case "Part":
					Check(t.Modifiers == "partial", "partial class");
				default:
					if (t.TypeKind == "extension")
						Check(unit.SpanText(t.GenericOpenTok, t.GenericCloseTok) == "<T, U>", "extension with generic parameters");
				}
			}

			// Every declaration form keeps its exact text (byte-exact round trip).
			SourceDocument doc = scope .();
			doc.LoadFromText(cDecls, "Decls.bf");
			bool allOk = true;
			for (let mg in doc.Methods)
			{
				if (!mg.Graphable)
					continue;
				for (let n in mg.Graph.Nodes)
					n.Edited = true;
				doc.PushUndo();
				if (!doc.Commit(doc.FindMethod(mg.Key)))
					allOk = false;
				break;
			}
			Check(allOk && doc.Text == cDecls, "declarations round-trip byte for byte");
		}

		// ------------------------------------------------------------------ edits

		static void TestEdits()
		{
			Console.WriteLine("Type Settings edits (minimal diffs, one undo step)");
			SourceDocument doc = scope .();
			doc.LoadFromText(cGame, "Game.bf");
			String before = scope .(doc.Text);

			// Base list: add an interface, then remove the whole list.
			{
				let enemy = FindType(doc, "Enemy");
				List<String> bases = scope .() { "Actor", "IDamageable", "IDisposable" };
				Check(doc.SetBaseList(enemy, bases), "SetBaseList accepted");
				Check(doc.Text.Contains("public class Enemy : Actor, IDamageable, IDisposable\n"), "interface added to the base list");
				doc.Undo();
				CheckText(doc.Text, before, "undo restores the text exactly");
				let holder = FindType(doc, "IntHolder");
				List<String> none = scope .();
				doc.SetBaseList(holder, none);
				Check(doc.Text.Contains("\tclass IntHolder\n\t{"), "base list removed with its ':'");
				doc.Undo();
				let point = FindType(doc, "Point");
				List<String> one = scope .() { "IHashable" };
				doc.SetBaseList(point, one);
				Check(doc.Text.Contains("\tstruct Point : IHashable\n"), "base list added after the name");
				doc.Undo();
				CheckText(doc.Text, before, "undo again");
				// A type cannot be its own parent, and a base listed twice is a mistake.
				List<String> self = scope .() { "Enemy" };
				Check(!doc.SetBaseList(FindType(doc, "Enemy"), self) && doc.LastError.Contains("own parent"), "a type as its own parent is refused");
				List<String> twice = scope .() { "Actor", "IDamageable", "IDamageable" };
				Check(!doc.SetBaseList(FindType(doc, "Enemy"), twice) && doc.LastError.Contains("twice"), "a base listed twice is refused");
				CheckText(doc.Text, before, "refusals leave the text");
				// Typed primitives (corlib's `struct Int64 : int64`, `struct HSocket : uint`) are legal Beef.
				List<String> typed = scope .() { "int" };
				Check(doc.SetBaseList(FindType(doc, "Point"), typed) && doc.Text.Contains("\tstruct Point : int\n"), "a struct with a basic base (typed primitive) is accepted");
				doc.Undo();
				List<String> typedI = scope .() { "int64", "IHashable" };
				Check(doc.SetBaseList(FindType(doc, "Point"), typedI) && doc.Text.Contains("\tstruct Point : int64, IHashable\n"), "a typed primitive then an interface is accepted");
				doc.Undo();
				List<String> late = scope .() { "IHashable", "int" };
				Check(!doc.SetBaseList(FindType(doc, "Point"), late) && doc.LastError.Contains("first base"), "a basic type after an interface is refused");
				List<String> twoPrim = scope .() { "int", "uint" };
				Check(!doc.SetBaseList(FindType(doc, "Point"), twoPrim), "two basic bases are refused");
				List<String> voidBase = scope .() { "void" };
				Check(!doc.SetBaseList(FindType(doc, "Point"), voidBase), "void as a struct base is refused");
				Check(!doc.SetBaseList(FindType(doc, "Enemy"), typed) && doc.LastError.Contains("only an enum or a struct"), "a class with a basic base is still refused");
				CheckText(doc.Text, before, "typed primitive checks leave the text");
			}
			// Modifiers on the type and on members.
			{
				let enemy = FindType(doc, "Enemy");
				doc.SetModifierWord(enemy, "sealed", true);
				Check(doc.Text.Contains("[Reflect]\n\tpublic sealed class Enemy"), "`sealed` inserted after `public`");
				doc.Undo();
				let holder = FindType(doc, "IntHolder");
				doc.SetVisibility(holder, "public");
				Check(doc.Text.Contains("\tpublic class IntHolder : Holder<int>"), "visibility added where there was none");
				doc.Undo();
				let actor = FindType(doc, "Actor");
				let spawn = FindMember(actor, "Spawn");
				doc.SetInheritance(spawn, "");
				Check(doc.Text.Contains("\t\tpublic void Spawn()\n"), "`virtual` removed");
				doc.Undo();
				let plain = FindMember(FindType(doc, "Actor"), "Plain");
				doc.SetInheritance(plain, "virtual");
				Check(doc.Text.Contains("\t\tpublic virtual void Plain()\n"), "`virtual` added");
				doc.Undo();
				let tick = FindMember(FindType(doc, "Actor"), "Tick");
				Check(!doc.SetInheritance(FindMember(FindType(doc, "Actor"), "Spawn"), "abstract"), "abstract refused on a function with a body");
				doc.SetVisibility(tick, "protected");
				Check(doc.Text.Contains("\t\tprotected abstract void Tick(float dt);"), "visibility replaced in place");
				doc.Undo();
				let hp = FindMember(FindType(doc, "Actor"), "mHp");
				doc.SetModifierWord(hp, "static", true);
				Check(doc.Text.Contains("\t\tpublic static int mHp = 10;"), "field made static");
				doc.Undo();
				doc.SetModifiers(FindMember(FindType(doc, "Actor"), "mHp"), "");
				Check(doc.Text.Contains("\t\tint mHp = 10;"), "modifiers removed with their space");
				doc.Undo();
				CheckText(doc.Text, before, "undo restores modifiers");
			}
			// Attributes.
			{
				let enemy = FindType(doc, "Enemy");
				List<String> attrs = scope .() { "Reflect", "AlwaysInclude" };
				doc.SetAttributes(enemy, attrs);
				Check(doc.Text.Contains("\t[Reflect, AlwaysInclude]\n\tpublic class Enemy"), "attribute added to the list");
				doc.Undo();
				List<String> none = scope .();
				doc.SetAttributes(FindType(doc, "Enemy"), none);
				Check(doc.Text.Contains("\tpublic class Enemy : Actor") && !doc.Text.Contains("[Reflect]"), "attributes removed with their line");
				doc.Undo();
				List<String> one = scope .() { "CRepr" };
				doc.SetAttributes(FindType(doc, "Point"), one);
				Check(doc.Text.Contains("\t[CRepr]\n\tstruct Point"), "attribute line added above the declaration");
				doc.Undo();
				List<String> fa = scope .() { "Expose" };
				doc.SetAttributes(FindMember(FindType(doc, "Point"), "X"), fa);
				Check(doc.Text.Contains("\t\t[Expose]\n\t\tpublic int X;"), "attribute on a field");
				doc.Undo();
				CheckText(doc.Text, before, "undo restores attributes");
			}
			// Kind, generics, constraints, namespace, field values.
			{
				doc.SetTypeKind(FindType(doc, "Point"), "class");
				Check(doc.Text.Contains("\tclass Point\n"), "struct -> class");
				doc.Undo();
				Check(!doc.SetTypeKind(FindType(doc, "Point"), "enum"), "a type cannot become an enum");
				doc.SetGenericParams(FindType(doc, "Point"), "T");
				Check(doc.Text.Contains("\tstruct Point<T>\n"), "generic parameter added");
				doc.Undo();
				doc.SetGenericParams(FindType(doc, "Holder"), "T, U");
				Check(doc.Text.Contains("\tclass Holder<T, U>\n"), "generic parameters changed");
				doc.Undo();
				doc.SetConstraints(FindType(doc, "Holder"), "where T : struct");
				Check(doc.Text.Contains("\tclass Holder<T> where T : struct\n"), "constraint added");
				let holder = FindType(doc, "Holder");
				doc.SetConstraints(holder, "");
				Check(doc.Text.Contains("\tclass Holder<T>\n"), "constraint removed");
				doc.Undo();
				doc.Undo();
				Check(doc.SetNamespace(FindType(doc, "Enemy"), "Other") == false, "namespace change refused when the namespace holds other types");
				doc.SetFieldInitializer(FindMember(FindType(doc, "Point"), "X"), "5");
				Check(doc.Text.Contains("\t\tpublic int X = 5;"), "initial value added");
				doc.Undo();
				doc.SetFieldInitializer(FindMember(FindType(doc, "Point"), "Y"), "");
				Check(doc.Text.Contains("\t\tpublic int Y;"), "initial value removed");
				doc.Undo();
				doc.SetFieldInitializer(FindMember(FindType(doc, "Actor"), "mHp"), "25");
				Check(doc.Text.Contains("\t\tpublic int mHp = 25;"), "initial value changed");
				doc.Undo();
				CheckText(doc.Text, before, "undo restores kind, generics, values");
			}
			// A graph that was built survives a header edit (its body is untouched).
			{
				let mg = doc.FindMethod("Enemy.Tick(float)");
				let g = mg.Graph;
				doc.SetModifierWord(FindType(doc, "Enemy"), "sealed", true);
				Check(doc.FindMethod("Enemy.Tick(float)").Graph == g, "the built graph of a member is kept across a type header edit");
				doc.Undo();
			}
			{
				SourceDocument one = scope .();
				one.LoadFromText("namespace Solo\n{\n\tclass Only\n\t{\n\t}\n}\n", "Only.bf");
				Check(one.SetNamespace(FindType(one, "Only"), "Solo.Inner") && one.Text.StartsWith("namespace Solo.Inner\n"), "namespace renamed when it holds only this type");
				// A file-scoped dotted namespace: every segment is replaced.
				SourceDocument fs = scope .();
				fs.LoadFromText("namespace Game.Core;\n\nclass Only\n{\n}\n", "Fs.bf");
				Check(fs.SetNamespace(FindType(fs, "Only"), "Game.UI") && fs.Text.StartsWith("namespace Game.UI;\n"), "file-scoped dotted namespace replaced whole");
				// Nested declarations: Properties shows the full path; only the inner name is the inner declaration's.
				SourceDocument nest = scope .();
				nest.LoadFromText("namespace Outer\n{\n\tnamespace Inner\n\t{\n\t\tclass A\n\t\t{\n\t\t}\n\t}\n}\n", "Nest.bf");
				Check(nest.SetNamespace(FindType(nest, "A"), "Outer.X") && nest.Text.Contains("\tnamespace X\n") && nest.Text.StartsWith("namespace Outer\n"), "nested: Outer.X renames the inner declaration to X");
				Check(!nest.SetNamespace(FindType(nest, "A"), "Elsewhere.Y") && nest.Text.Contains("\tnamespace X\n"), "nested: a path outside the outer declaration is refused");
				// A value change keeps the destructor clause; removing the value keeps it too.
				SourceDocument own = scope .();
				own.LoadFromText("class Bag\n{\n\tList<int> mItems = new .() ~ delete _;\n}\n", "Bag.bf");
				Check(own.SetFieldInitializer(FindMember(FindType(own, "Bag"), "mItems"), "new .(5)") && own.Text.Contains("List<int> mItems = new .(5) ~ delete _;"), "a new value keeps ~ delete _");
				Check(own.SetFieldInitializer(FindMember(FindType(own, "Bag"), "mItems"), "") && own.Text.Contains("List<int> mItems ~ delete _;"), "no value keeps ~ delete _");
			}
		}

		// ------------------------------------------------------------------ inheritance

		static void TestInheritance()
		{
			Console.WriteLine("inheritance, interfaces, stubs, overrides");
			Project p = scope .();
			SourceDocument doc = scope .();
			doc.LoadFromText(cGame, "Game.bf");
			p.Update(doc);

			{
				ClassInfo info = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "Enemy"), p.Service, info);
				Check(info.BaseClass == "Actor" && info.Interfaces.Count == 1 && info.Interfaces[0] == "IDamageable", "base class and interfaces split");
				Check(info.Complete, "everything resolved");
				Check(HasNames(info.Overridable, "Spawn, Score, TryGet, TakeDamage, Health, IsAlive"), "Override list: virtuals of the chain + interface members (not Tick: declared, not Plain: not virtual)");
				Check(HasNames(info.Missing, "TakeDamage, Health"), "missing: the interface members without a default body");
				Check(info.Problems.Count == 2 && info.Problems[0].Contains("does not implement IDamageable.TakeDamage"), "document errors name the missing members");
				let tryGet = info.FindOverridable("TryGet(int,out int)");
				Check(tryGet != null && tryGet.Visibility == .Protected, "TryGet keeps its protected visibility");

				// Implement the missing members: stubs as new graphs, one undo step.
				let enemy = FindType(doc, "Enemy");
				int added = doc.AddStubs(enemy, info.Missing);
				Check(added == 2, "two stubs added");
				Check(doc.Text.Contains("\t\t\tbase.Spawn();\n\t\t}\n\n\t\tpublic void TakeDamage(int amount)\n\t\t{\n\t\t}\n\n\t\tpublic int Health\n\t\t{\n\t\t\tget\n\t\t\t{\n\t\t\t\treturn default;\n\t\t\t}\n\t\t}\n\t}\n"), "stub text: method and get-only property, after a blank line");
				Check(doc.FindMethod("Enemy.TakeDamage(int)") != null && doc.FindMethod("Enemy.Health.get()") != null && doc.FindMethod("Enemy.Health.get()").Graphable, "stubs are graphs (the getter too)");
				p.Update(doc);
				ClassInfo after = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "Enemy"), p.Service, after);
				Check(after.Missing.IsEmpty && after.Problems.IsEmpty, "nothing missing after the stubs");
				Check(HasNames(after.Overridable, "Spawn, Score, TryGet, IsAlive"), "implemented members leave the Override list");
				doc.Undo();
				Check(doc.FindMethod("Enemy.TakeDamage(int)") == null, "undo removes the stubs in one step");
			}
			{
				// Override from the dropdown: signature, `override`, call to the parent function.
				ClassInfo info = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "Enemy"), p.Service, info);
				String key = scope .();
				doc.AddOverride(FindType(doc, "Enemy"), info.FindOverridable("Spawn()"), true, key);
				Check(key == "Enemy.Spawn()", "AddOverride returns the new graph's key");
				Check(doc.Text.Contains("\t\tpublic override void Spawn()\n\t\t{\n\t\t\tbase.Spawn();\n\t\t}\n"), "override with the parent call");
				let g = doc.FindMethod(key).Graph;
				Node call = null;
				for (let n in g.Nodes)
					if (n.Kind == .Call && n.Text == "Spawn")
						call = n;
				Check(call != null && g.DataSource(call.FindInput("target"))?.Kind == .Base && call.Binding == .Instance, "base.Spawn() reads as a call with Target wired from a Base node");
				Check(call != null && call.OwnerType != null && call.OwnerType == "Actor", "the parent call is owned by Actor");
				doc.Undo();
				ClassInfo info2 = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "Enemy"), p.Service, info2);
				doc.AddOverride(FindType(doc, "Enemy"), info2.FindOverridable("TryGet(int,out int)"), true, key);
				Check(doc.Text.Contains("\t\tprotected override bool TryGet(int key, out int value)\n\t\t{\n\t\t\treturn base.TryGet(key, out value);\n\t\t}\n"), "protected override with out parameter passes it on");
				doc.Undo();
				ClassInfo info3 = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "Enemy"), p.Service, info3);
				doc.AddOverride(FindType(doc, "Enemy"), info3.FindOverridable("Score"), true, key);
				Check(doc.Text.Contains("\t\tpublic override int Score\n\t\t{\n\t\t\tget\n\t\t\t{\n\t\t\t\treturn base.Score;\n\t\t\t}\n\t\t}\n") && key == "Enemy.Score.get()", "property override reads the parent's value");
				doc.Undo();
				ClassInfo info4 = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "Enemy"), p.Service, info4);
				doc.AddOverride(FindType(doc, "Enemy"), info4.FindOverridable("TryGet(int,out int)"), false, key);
				Check(doc.Text.Contains("\t\t\tvalue = default;\n\t\t\treturn default;\n"), "without the parent call: out parameters and the result get default");
				doc.Undo();
			}
			{
				// Generic base: T is substituted.
				ClassInfo info = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "IntHolder"), p.Service, info);
				let get = info.FindOverridable("Get()");
				Check(get != null && get.ReturnType == "int", "Holder<int>.Get() returns int");
				String key = scope .();
				doc.AddOverride(FindType(doc, "IntHolder"), get, true, key);
				Check(doc.Text.Contains("\t\tpublic override int Get()\n\t\t{\n\t\t\treturn base.Get();\n\t\t}\n"), "override signature with the generic argument");
				doc.Undo();
			}
			{
				// Abstract members of the base and overrides without a base.
				ClassInfo lone = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "Lone"), p.Service, lone);
				Check(lone.Missing.IsEmpty, "Lone implements Actor.Tick");
				Check(lone.OverridesWithoutBase.Count == 1 && lone.OverridesWithoutBase[0] == "Missing()", "override without a base member is a document error");
				ClassInfo odd = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "Odd"), p.Service, odd);
				Check(!odd.Complete && odd.Problems.IsEmpty && odd.OverridesWithoutBase.IsEmpty, "unknown base: nothing is reported");
				SourceDocument d2 = scope .();
				d2.LoadFromText("namespace Game\n{\n\tclass Bare : Actor\n\t{\n\t}\n}\n", "Bare.bf");
				p.Add("Bare.bf", d2.Text);
				ClassInfo bare = scope .();
				ClassModel.Analyze(d2.Unit, FindType(d2, "Bare"), p.Service, bare);
				Check(bare.Missing.Count == 1 && bare.Missing[0].Name == "Tick" && !bare.Missing[0].FromInterface, "abstract base member missing in a class");
				Check(bare.Problems.Count == 1 && bare.Problems[0].Contains("abstract Actor.Tick"), "abstract member: clear document error");
				d2.SetModifierWord(FindType(d2, "Bare"), "abstract", true);
				ClassInfo bareAbs = scope .();
				ClassModel.Analyze(d2.Unit, FindType(d2, "Bare"), p.Service, bareAbs);
				Check(bareAbs.Missing.IsEmpty, "an abstract class may leave it abstract");
			}
			{
				// Invalid parents.
				SourceDocument d3 = scope .();
				d3.LoadFromText("namespace Game\n{\n\tsealed class Final\n\t{\n\t}\n\tclass Sub : Final\n\t{\n\t}\n\tstruct SP : Actor\n\t{\n\t}\n}\n", "Bad.bf");
				p.Add("Bad.bf", d3.Text);
				ClassInfo sub = scope .();
				ClassModel.Analyze(d3.Unit, FindType(d3, "Sub"), p.Service, sub);
				Check(sub.Problems.Count == 1 && sub.Problems[0].Contains("sealed"), "deriving from a sealed class is reported");
				ClassInfo sp = scope .();
				ClassModel.Analyze(d3.Unit, FindType(d3, "SP"), p.Service, sp);
				Check(sp.Problems.Count >= 1 && sp.Problems[0].Contains("struct"), "a struct deriving from a class is reported");
				// A static class may derive from a static class (UMP's OS resolvers); a plain class may not.
				SourceDocument d4 = scope .();
				d4.LoadFromText("namespace Game\n{\n\tstatic class Resolver\n\t{\n\t}\n\tstatic class TickResolver : Resolver\n\t{\n\t}\n\tclass Plain : Resolver\n\t{\n\t}\n}\n", "Static.bf");
				p.Add("Static.bf", d4.Text);
				ClassInfo st = scope .();
				ClassModel.Analyze(d4.Unit, FindType(d4, "TickResolver"), p.Service, st);
				Check(st.Problems.IsEmpty, "a static class deriving from a static class is fine");
				ClassInfo pl = scope .();
				ClassModel.Analyze(d4.Unit, FindType(d4, "Plain"), p.Service, pl);
				Check(pl.Problems.Count == 1 && pl.Problems[0].Contains("static class"), "a plain class deriving from a static class is reported");
				List<TypeChoice> parents = scope .();
				ClassModel.ListTypes(p.Service, "class", "", true, 100, parents);
				bool hasFinal = false;
				bool hasActor = false;
				for (let c in parents)
				{
					if (c.Name == "Final") hasFinal = true;
					if (c.Name == "Actor") hasActor = true;
				}
				Check(hasActor && !hasFinal, "parent picker: classes, without sealed ones");
				List<TypeChoice> ifaces = scope .();
				ClassModel.ListTypes(p.Service, "interface", "dam", false, 100, ifaces);
				Check(ifaces.Count == 1 && ifaces[0].Name == "IDamageable", "interface picker with search");
			}
		}

		// ------------------------------------------------------------------ graph checks

		static void TestGraphChecks()
		{
			Console.WriteLine("Base node, override check on the entry, accessor graphs");
			Project p = scope .();
			SourceDocument doc = scope .();
			doc.LoadFromText(cGame, "Game.bf");
			p.Update(doc);
			{
				let mg = doc.FindMethod("Lone.Missing()");
				String body = scope .();
				Check(!doc.GenerateMethodBody(mg, body), "an override with nothing to override is refused");
				bool onEntry = false;
				for (let e in mg.Graph.Errors)
					if (e.NodeId == mg.Graph.Entry.Id && e.Message.Contains("marked override"))
						onEntry = true;
				Check(onEntry, "the error is on the Entry node (the function's header)");
				let ok = doc.FindMethod("Lone.Tick(float)");
				String b2 = scope .();
				Check(doc.GenerateMethodBody(ok, b2) && ok.Graph.Errors.IsEmpty, "a real override is fine");
				let odd = doc.FindMethod("Odd.Whatever()");
				String b3 = scope .();
				Check(doc.GenerateMethodBody(odd, b3), "unknown base: never an error");
			}
			{
				// base.Spawn() round trip, byte for byte and regenerated.
				let mg = doc.FindMethod("Enemy.Tick(float)");
				let g = mg.Graph;
				Node baseNode = null;
				for (let n in g.Nodes)
					if (n.Kind == .Base)
						baseNode = n;
				Check(baseNode != null && baseNode.Result.TypeName == "Actor", "Base node typed with the base class");
				String title = scope .();
				baseNode?.GetTitle(title);
				Check(title == "Base", "titled Base");
				for (let n in g.Nodes)
					n.Edited = true;
				doc.PushUndo();
				Check(doc.Commit(mg) && doc.Text == cGame, "base.Spawn() regenerates exactly");
				// A Base node in a static function.
				SourceDocument s = scope .();
				s.LoadFromText("class St : Actor\n{\n\tpublic static void S()\n\t{\n\t}\n}\n", "St.bf");
				let sg = s.FindMethod("St.S()");
				let bn = NodeFactory.Base(sg.Graph, "Actor");
				StringView[0] none = .();
				let call = NodeFactory.MemberCall(sg.Graph, "Spawn", "Actor", true, none, none, "void");
				sg.Graph.Connect(bn.Result, call.FindInput("target"));
				sg.Graph.Connect(sg.Graph.Entry.Then, call.ExecIn);
				s.PushUndo();
				Check(!s.Commit(sg), "a Base node in a static function is refused");
				bool msg = false;
				for (let e in sg.Graph.Errors)
					if (e.Message.Contains("no base"))
						msg = true;
				Check(msg, "with a clear message");
				// The factory makes what the code reads back as.
				SourceDocument f = scope .();
				f.LoadFromText("class Kid : Actor\n{\n\tpublic override void Spawn()\n\t{\n\t}\n}\n", "Kid.bf");
				let fg = f.FindMethod("Kid.Spawn()");
				let fb = NodeFactory.Base(fg.Graph, "Actor");
				let fc = NodeFactory.MemberCall(fg.Graph, "Spawn", "Actor", true, none, none, "void");
				fg.Graph.Connect(fb.Result, fc.FindInput("target"));
				fg.Graph.Connect(fg.Graph.Entry.Then, fc.ExecIn);
				f.PushUndo();
				Check(f.Commit(fg) && f.Text.Contains("\t\tbase.Spawn();\n"), "factory Parent + call writes base.Spawn()");
			}
			{
				// Property accessors and indexers are graphs.
				const String src =
					"""
					class Bag
					{
						int mScore;
						int[4] mItems;

						public int Score
						{
							get { return mScore; }
							set { mScore = value; }
						}

						public int this[int i]
						{
							get
							{
								return mItems[i];
							}
						}
					}

					""";
				SourceDocument d = scope .();
				d.LoadFromText(src, "Bag.bf");
				let get = d.FindMethod("Bag.Score.get()");
				let set = d.FindMethod("Bag.Score.set(int)");
				let idx = d.FindMethod("Bag.this[].get(int)");
				Check(get != null && set != null && idx != null && get.Graphable && set.Graphable && idx.Graphable, "get / set / indexer get are graphs");
				Check(set != null && set.Graph.Entry.FindOutput("param0")?.Label == "value", "the setter's `value` is an Entry output");
				Check(idx != null && idx.Graph.Entry.FindOutput("param0")?.Label == "i", "the indexer's parameter is an Entry output");
				for (let mg in d.Methods)
				{
					if (!mg.Graphable)
						continue;
					for (let n in mg.Graph.Nodes)
						n.Edited = true;
					d.PushUndo();
					d.Commit(d.FindMethod(mg.Key));
				}
				CheckText(d.Text, src, "accessor bodies regenerate exactly");
			}
		}

		// ------------------------------------------------------------------ renames

		const String cRenA =
			"""
			namespace Game
			{
				class Player
				{
					public int mHealth = 10;
					public static Player Create() { return new Player(); }

					public void Hurt(int amount)
					{
						mHealth -= amount;
						this.mHealth -= 0;
					}
				}

				class Hero : Player
				{
					public void Heal()
					{
						mHealth += 5;
					}
				}
			}

			""";

		const String cRenB =
			"""
			using System;
			using System.Collections;

			namespace Game
			{
				class Other
				{
					public int mHealth;
				}

				class World
				{
					List<Player> mPlayers = new .();

					public void Damage(Player p, Other o)
					{
						p.mHealth -= 1;
						o.mHealth -= 1;
						Player made = Player.Create();
						made.mHealth = 3;
						let hero = new Hero();
						hero.mHealth = 4;
						delete hero;
						delete made;
					}

					public int Sum(int count)
					{
						int total = 0;
						for (int i = 0; i < count; i++)
							total += i;
						Console.WriteLine($"total {total} of {count}");
						return total;
					}
				}
			}

			""";

		static void TestRenames()
		{
			Console.WriteLine("renames across files");
			Project p = scope .();
			p.Add("A.bf", cRenA);
			p.Add("B.bf", cRenB);
			List<RenameService.Source> sources = scope .();
			RenameService.Source sa;
			sa.Path = "A.bf";
			sa.Text = cRenA;
			RenameService.Source sb;
			sb.Path = "B.bf";
			sb.Text = cRenB;
			sources.Add(sa);
			sources.Add(sb);

			{
				// A field used bare, through this, in a subclass, through a parameter, a local of the
				// type, a `new` local; the same-named field of an unrelated type is left alone.
				RenameTarget t = scope .();
				t.Kind = .Member;
				t.OldName.Set("mHealth");
				t.NewName.Set("mHp");
				t.TypeName.Set("Player");
				t.FilePath.Set("A.bf");
				RenamePlan plan = scope .();
				RenameService.Plan(t, sources, p.Service, plan);
				for (let pr in plan.Problems)
					Console.WriteLine("    problem: {}", pr);
				Check(plan.CanApply, "field rename: no problems");
				Check(plan.Count == 7 && plan.Files.Count == 2, scope $"field rename: 7 references in 2 files (got {plan.Count} in {plan.Files.Count})");
				SourceDocument da = scope .();
				da.LoadFromText(cRenA, "A.bf");
				SourceDocument db = scope .();
				db.LoadFromText(cRenB, "B.bf");
				for (let f in plan.Files)
				{
					let d = (f.Path == "A.bf") ? da : db;
					Check(d.ApplyRenameEdits(f.Text, f.Edits, t.NewName), scope $"applied to {f.Path}");
				}
				Check(da.Text.Contains("public int mHp = 10;") && da.Text.Contains("this.mHp -= 0;") && da.Text.Contains("\t\t\tmHp += 5;"), "declaration, this., subclass bare use");
				Check(db.Text.Contains("p.mHp -= 1;") && db.Text.Contains("o.mHealth -= 1;") && db.Text.Contains("made.mHp = 3;") && db.Text.Contains("hero.mHp = 4;"), "parameter, local, `new` local renamed; Other.mHealth kept");
				da.Undo();
				db.Undo();
				Check(da.Text == cRenA && db.Text == cRenB, "undo per file restores both");

				// A graph holding a refused commit: a rename that rewrites its body is refused by name
				// (nothing silently dropped); one that does not touch it goes through.
				{
					SourceDocument dc = scope .();
					dc.LoadFromText(cRenB, "B.bf");
					MethodGraph mgd = null;
					for (let m in dc.Methods)
						if (m.Method.Name == "Damage")
							mgd = m;
					let g = mgd.Graph;
					StringView[1] names = .("amount");
					StringView[1] types = .("int");
					let call = NodeFactory.MemberCall(g, "TakeDamage", "Player", true, names, types, "void");
					g.Connect(g.Entry.Then, call.ExecIn);
					Check(!dc.Commit(mgd) && !g.Errors.IsEmpty, "setup: a commit refused for a missing argument");
					String beforeText = scope .(dc.Text);
					RenameFile fb = null;
					for (let f in plan.Files)
						if (f.Path == "B.bf")
							fb = f;
					Check(!dc.ApplyRenameEdits(fb.Text, fb.Edits, t.NewName) && dc.LastError.Contains("Damage") && dc.Text == beforeText, "rename touching the function with a refused commit: refused, naming it, text unchanged");
					Check(mgd.IsBuilt && !mgd.Graph.Errors.IsEmpty && mgd.Graph.FindNode(call.Id) != null, "the graph and its edit are still there");
				}
			}
			{
				// The type: declarations, `List<Player>`, parameters, locals, static calls, `new`, base list.
				RenameTarget t = scope .();
				t.Kind = .Type;
				t.OldName.Set("Player");
				t.NewName.Set("Pawn");
				t.TypeName.Set("Player");
				t.FilePath.Set("A.bf");
				RenamePlan plan = scope .();
				RenameService.Plan(t, sources, p.Service, plan);
				for (let pr in plan.Problems)
					Console.WriteLine("    problem: {}", pr);
				Check(plan.CanApply && plan.Count == 8, scope $"type rename: 8 references, no problems (got {plan.Count})");
				SourceDocument db = scope .();
				db.LoadFromText(cRenB, "B.bf");
				for (let f in plan.Files)
					if (f.Path == "B.bf")
						db.ApplyRenameEdits(f.Text, f.Edits, t.NewName);
				Check(db.Text.Contains("List<Pawn> mPlayers") && db.Text.Contains("Damage(Pawn p, Other o)") && db.Text.Contains("Pawn made = Pawn.Create();"), "type references in the other file");
				Check(db.FindMethod("World.Damage(Pawn,Other)") != null, "the function key follows the parameter type");
			}
			{
				// Refused: an unknown-type local reading a name other types have too.
				const String cVar =
					"""
					namespace Game
					{
						class Use
						{
							public void Go()
							{
								var x = Make();
								x.mHealth = 2;
							}

							Player Make() { return null; }
						}
					}

					""";
				List<RenameService.Source> s3 = scope .();
				s3.AddRange(sources);
				RenameService.Source sc;
				sc.Path = "C.bf";
				sc.Text = cVar;
				s3.Add(sc);
				RenameTarget t = scope .();
				t.Kind = .Member;
				t.OldName.Set("mHealth");
				t.NewName.Set("mHp");
				t.TypeName.Set("Player");
				RenamePlan plan = scope .();
				RenameService.Plan(t, s3, p.Service, plan);
				Check(!plan.CanApply && plan.Problems.Count == 1 && plan.Problems[0].Contains("C.bf(8)"), "a `var` of unknown type reading a shared name is refused, with file and line");
				RenameTarget clash = scope .();
				clash.Kind = .Member;
				clash.OldName.Set("mHealth");
				clash.NewName.Set("Hurt");
				clash.TypeName.Set("Player");
				RenamePlan cp = scope .();
				RenameService.Plan(clash, sources, p.Service, cp);
				Check(!cp.Refusal.IsEmpty && cp.Refusal.Contains("already has a member"), "renaming onto an existing member is refused");
			}
			{
				// Parameter and local: inside the function only, interpolated strings included.
				RenameTarget t = scope .();
				t.Kind = .Parameter;
				t.OldName.Set("count");
				t.NewName.Set("n");
				t.TypeName.Set("World");
				t.MethodKey.Set("World.Sum(int)");
				t.FilePath.Set("B.bf");
				RenamePlan plan = scope .();
				RenameService.Plan(t, sources, p.Service, plan);
				Check(plan.CanApply && plan.Count == 3, scope $"parameter rename: declaration, loop and string hole (got {plan.Count})");
				SourceDocument db = scope .();
				db.LoadFromText(cRenB, "B.bf");
				db.ApplyRenameEdits(plan.Files[0].Text, plan.Files[0].Edits, "n");
				Check(db.Text.Contains("public int Sum(int n)") && db.Text.Contains("i < n;") && db.Text.Contains("$\"total {total} of {n}\""), "parameter renamed everywhere in its function");
				RenameTarget l = scope .();
				l.Kind = .Local;
				l.OldName.Set("total");
				l.NewName.Set("i");
				l.MethodKey.Set("World.Sum(int)");
				l.FilePath.Set("B.bf");
				RenamePlan lp = scope .();
				RenameService.Plan(l, sources, p.Service, lp);
				Check(!lp.Refusal.IsEmpty && lp.Refusal.Contains("already used"), "a local renamed onto a name in use is refused");
				l.NewName.Set("sum");
				RenamePlan lp2 = scope .();
				RenameService.Plan(l, sources, p.Service, lp2);
				Check(lp2.CanApply && lp2.Count == 4, scope $"local rename: 4 occurrences (got {lp2.Count})");
			}
		}

		// ------------------------------------------------------------------ templates

		const String cUMPBase =
			"""
			using System;

			namespace UMPSDK
			{
				public struct FUMPModIdentity
				{
				}

				public abstract class UMPMod
				{
					public abstract FUMPModIdentity Info();
					public virtual Result<void> Initialize() => .Ok;
					public virtual void OnEngineReady() {}
					public virtual void OnWorldReady(UWorld* World) {}
					public virtual void Tick(float DeltaSeconds) {}
					public virtual void Shutdown() {}
				}
			}

			""";

		/// The 2026-10-11 newcomer pass: what a first-time user's Add Function / Add Variable write.
		/// Properties > Inputs and the Add Function dialog: the Passing chooser offers what Beef takes.
		static void TestPassing()
		{
			Console.WriteLine("passing: value / out / ref / in");
			List<StringView> c = scope .();
			VisualBeef.Catalog.TypeSlotRules.PassingChoices("int", false, "", c);
			Check(c.Count == 4 && c[0] == "" && c[1] == "out" && c[2] == "ref" && c[3] == "in", "an int parameter: value, out, ref, in");
			c.Clear();
			VisualBeef.Catalog.TypeSlotRules.PassingChoices("String", true, "", c);
			Check(c.Count == 1 && c[0] == "", "a parameter with a default value: value only");
			c.Clear();
			VisualBeef.Catalog.TypeSlotRules.PassingChoices("var", false, "", c);
			Check(c.Count == 1, "an untyped mixin parameter: value only");
			c.Clear();
			VisualBeef.Catalog.TypeSlotRules.PassingChoices("int[]", false, "params", c);
			Check(c.Count == 5 && c[4] == "params", "a params row keeps params as its choice");
			Check(VisualBeef.Catalog.TypeSlotRules.PassingLabel("") == "value" && VisualBeef.Catalog.TypeSlotRules.PassingLabel("out") == "out", "labels: value for none");

			SourceDocument doc = scope .();
			doc.LoadFromText("namespace Mod\n{\n\tstruct Point\n\t{\n\t}\n\n\tclass Greeter\n\t{\n\t\tpublic bool TryGet(int value)\n\t\t{\n\t\t\treturn false;\n\t\t}\n\t}\n}\n", "Pass.bf");
			let m = FindMember(FindType(doc, "Greeter"), "TryGet");
			Check(doc.SetSignature(m, "bool", "out int value") && doc.Text.Contains("public bool TryGet(out int value)"), "value -> out writes `out int value`");
			let m2 = FindMember(FindType(doc, "Greeter"), "TryGet");
			Check(m2 != null && m2.Params.Count == 1 && m2.Params[0].Modifier == "out", "reads back with the out modifier");
			Check(doc.SetSignature(m2, "bool", "ref int value, in Point at") && doc.Text.Contains("TryGet(ref int value, in Point at)"), "ref and in written");
			let m3 = FindMember(FindType(doc, "Greeter"), "TryGet");
			Check(doc.SetSignature(m3, "bool", "int value, in Point at") && doc.Text.Contains("TryGet(int value, in Point at)"), "back to value");
			String key = scope .();
			Check(doc.AddMethod(FindType(doc, "Greeter"), "int", "Find", "in String name, out int index", key) && doc.Text.Contains("public int Find(in String name, out int index)"), "Add Function with in / out parameters");
		}

		/// A Return placed in a value function starts with the type's default value.
		static void TestReturnDefaults()
		{
			Console.WriteLine("return defaults: a fresh function compiles");
			Project p = scope .();
			p.Add("Types.bf", "namespace Mod\n{\n\tclass Greeter\n\t{\n\t}\n\tstruct Point\n\t{\n\t}\n\tenum Mood\n\t{\n\t\tHappy\n\t}\n\tinterface IGreeter\n\t{\n\t}\n}\n");
			String v = scope .();
			void Expect(StringView type, StringView want)
			{
				v.Clear();
				NodeFactory.ReturnDefault(type, v);
				Check(v == want, scope $"Return in a {type} function starts with '{want}' ('{v}')");
			}
			Expect("bool", "false");
			Expect("int", "0");
			Expect("double", "0");
			Expect("String", "null");
			Expect("int[]", "null");
			Expect("int?", "null");
			Expect("Greeter", "null");
			Expect("IGreeter", "null");
			Expect("Point", "default");
			Expect("Mood", "default");
			Expect("char8", "default");
			Expect("void", "");
			Expect("ref int", "");

			// The node: a TryGet-like bool function with a Return placed from the Node menu.
			SourceDocument doc = scope .();
			doc.LoadFromText("namespace Mod\n{\n\tclass Box\n\t{\n\t\tpublic bool Ready()\n\t\t{\n\t\t}\n\t}\n}\n", "Box.bf");
			let mg = doc.FindMethod("Box.Ready()");
			let g = mg.Graph;
			doc.PushUndo();
			let ret = NodeFactory.Return(g, "bool");
			g.Connect(g.Entry.Then, ret.ExecIn);
			// The Set of a parameter or local: its pin is the Variable being set, not a Receiver.
			let set = NodeFactory.Set(g, "value", "int");
			Check(set.FindInput("target").Label == "Variable", "a placed Set labels its pin Variable");
			g.RemoveNode(set);
			Check(ret.FindInput("value").Default == "false" && doc.Commit(mg) && doc.Text.Contains("\t\tpublic bool Ready()\n\t\t{\n\t\t\treturn false;\n\t\t}"), "the bool function is written with `return false;`");
		}

		static void TestSetLabels()
		{
			Console.WriteLine("set labels: Variable on Set, Receiver on calls");
			SourceDocument doc = scope .();
			doc.LoadFromText("namespace Mod\n{\n\tclass Box\n\t{\n\t\tint mCount;\n\t\tvoid Ping() { }\n\t\tpublic bool TryGet(out int value, int start)\n\t\t{\n\t\t\tvalue = mCount;\n\t\t\tstart++;\n\t\t\tint local = 0;\n\t\t\tlocal += start;\n\t\t\tthis.mCount = local;\n\t\t\tthis.Ping();\n\t\t\treturn true;\n\t\t}\n\t}\n}\n", "Box.bf");
			Graph g = null;
			for (let mg in doc.Methods)
				if (mg.Method.Name == "TryGet")
					g = mg.Graph;
			int sets = 0, labelled = 0;
			bool callReceiver = false;
			if (g != null)
			{
				for (let n in g.Nodes)
				{
					if (n.Kind == .Set)
					{
						sets++;
						if (n.FindInput("target")?.Label == "Variable")
							labelled++;
					}
					if (n.Kind == .Call && n.FindInput("target") != null)
						callReceiver = n.FindInput("target").Label == "Receiver";
				}
			}
			Check(sets == 4 && labelled == 4, scope $"Set of a parameter, ++, +=, a field: the pin is Variable ({labelled} of {sets})");
			Check(callReceiver, "a call's pin stays Receiver");
		}

		/// A Construct of a class whose constructors all take inputs, with none chosen: an error on
		/// the node before anything is compiled.
		static void TestConstructChoice()
		{
			Console.WriteLine("construct: a constructor must be chosen");
			Project p = scope .();
			p.Add("Greeter.bf", "namespace Mod\n{\n\tclass Greeter\n\t{\n\t\tpublic this(int start) { }\n\t\tpublic this(String name, int start) { }\n\t}\n\tclass Plain\n\t{\n\t\tpublic this() { }\n\t\tpublic this(int a) { }\n\t}\n\tclass Optional\n\t{\n\t\tpublic this(int a = 1) { }\n\t}\n\tclass Bare\n\t{\n\t}\n}\n");
			SourceDocument doc = scope .();
			doc.LoadFromText("namespace Mod\n{\n\tclass Program\n\t{\n\t\tpublic static void Main()\n\t\t{\n\t\t}\n\t}\n}\n", "Program.bf");
			p.Update(doc);
			let mg = doc.FindMethod("Program.Main()");
			let g = mg.Graph;
			StringView[0] none = .();
			bool ErrorOn(Node n, StringView text)
			{
				g.ClearErrors();
				GraphValidator.Validate(g);
				for (let e in g.Errors)
					if (e.NodeId == n.Id && e.Message.Contains(text))
						return true;
				return false;
			}
			let greeter = NodeFactory.Construct(g, "Greeter", "scope", none, none);
			greeter.Edited = true;
			Check(ErrorOn(greeter, "Greeter needs a constructor: choose one in Properties > Constructor"), "Construct Greeter with no constructor chosen: an error on the node");
			Check(GraphValidator.NeedsConstructorChoice("Plain") == null && GraphValidator.NeedsConstructorChoice("Optional") == null && GraphValidator.NeedsConstructorChoice("Bare") == null,
				"a class with this(), with this(int a = 1) or with no constructor needs no choice");
			NodeFactory.AddArgument(g, greeter).Default.Set("3");
			Check(!ErrorOn(greeter, "needs a constructor"), "with the constructor's input the error is gone");
			let plain = NodeFactory.Construct(g, "Plain", "scope", none, none);
			plain.Edited = true;
			Check(!ErrorOn(plain, "needs a constructor"), "Construct Plain with no inputs: no error");
			SourceDocument fromCode = scope .();
			fromCode.LoadFromText("namespace Mod\n{\n\tclass Main2\n\t{\n\t\tpublic static void Run()\n\t\t{\n\t\t\tlet g = scope Greeter();\n\t\t}\n\t}\n}\n", "Main2.bf");
			let rg = fromCode.FindMethod("Main2.Run()").Graph;
			rg.ClearErrors();
			GraphValidator.Validate(rg);
			bool warned = false;
			for (let e in rg.Warnings)
				if (e.Message.Contains("Greeter needs a constructor"))
					warned = true;
			Check(warned, "read from code: a warning, not an error");
		}

		static void TestNewcomer()
		{
			Console.WriteLine("newcomer: interface functions, usings, overload ties");
			Project p = scope .();
			p.Add("Lib.bf", "namespace Lib.Things\n{\n\tclass Box<T>\n\t{\n\t}\n}\n");
			p.Add("Sys.bf", "namespace System\n{\n\tclass Object\n\t{\n\t}\n\tclass String : Object\n\t{\n\t}\n\tstruct StringView\n\t{\n\t}\n\tclass Console\n\t{\n\t\tpublic static void WriteLine(StringView line) {}\n\t\tpublic static void WriteLine(Object obj) {}\n\t}\n}\n");
			SourceDocument doc = scope .();
			doc.LoadFromText("using System;\n\nnamespace Mod\n{\n\tinterface IGreeter\n\t{\n\t}\n\n\tclass Greeter\n\t{\n\t}\n}\n", "Greeter.bf");
			p.Update(doc);
			String key = scope .();

			// An interface function is a declaration: no body, no access word.
			Check(doc.AddMethod(FindType(doc, "IGreeter"), "void", "Greet", "String name", key), "Add Function on an interface");
			Check(doc.Text.Contains("\tinterface IGreeter\n\t{\n\t\tvoid Greet(String name);\n\t}\n"), "written `void Greet(String name);` (a body would be a default implementation no class is asked for)");
			let greet = FindMember(FindType(doc, "IGreeter"), "Greet");
			Check(greet != null && greet.Kind == .Method, "it reads back as the interface's function");

			// A type from a namespace the file does not use: `using` added in the same undo step.
			int depth = doc.UndoDepth;
			Check(doc.AddField(FindType(doc, "Greeter"), "Box<int>", "mBox"), "Add Variable Box<int> mBox");
			Check(doc.Text.StartsWith("using System;\nusing Lib.Things;\n\nnamespace Mod"), "`using Lib.Things;` added after `using System;`");
			Check(doc.UndoDepth == depth + 1, "one undo step for the variable and its using");
			p.Update(doc);
			Check(doc.AddField(FindType(doc, "Greeter"), "Box<float>", "mOther") && doc.Text.IndexOf("using Lib.Things;", doc.Text.IndexOf("using Lib.Things;") + 1) < 0, "a second Box adds no second using");
			doc.Undo();
			doc.Undo();
			Check(!doc.Text.Contains("using Lib.Things;") && !doc.Text.Contains("mBox"), "undo removes the variable and its using together");
			Check(doc.AddField(FindType(doc, "Greeter"), "Lib.Things.Box<int>", "mFull") && !doc.Text.Contains("using Lib.Things;"), "a qualified type adds no using");
			Check(doc.AddMethod(FindType(doc, "Greeter"), "Box<int>", "Make", "int count", key) && doc.Text.Contains("using Lib.Things;"), "Add Function with a Return Type from another namespace adds the using");

			// Overload ties: a value taken as Object fits less well than any other conversion.
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			args.Add(new String("String"));
			let r1 = p.Service.ResolveCall("Console", "", "WriteLine", 1, args, null);
			Check(r1 != null && !r1.Ambiguous && r1.ParamTypes.Count == 1 && r1.ParamTypes[0] == "StringView", scope $"WriteLine(String) picks WriteLine(StringView), not a tie with WriteLine(Object) ({(r1 != null) ? r1.ParamTypes[0] : "none"})");
			args[0].Set("int");
			let r2 = p.Service.ResolveCall("Console", "", "WriteLine", 1, args, null);
			Check(r2 != null && !r2.Ambiguous && r2.ParamTypes[0] == "Object", "WriteLine(int) picks WriteLine(Object)");

			// A print read back from `Console.WriteLine("text")` takes any value like a placed Print.
			SourceDocument pd = scope .();
			let printText = "using System;\n\nnamespace Mod\n{\n\tclass Printer\n\t{\n\t\tpublic void Show(int n)\n\t\t{\n\t\t\tConsole.WriteLine(\"text\");\n\t\t}\n\t}\n}\n";
			pd.LoadFromText(printText, "Printer.bf");
			p.Update(pd);
			let pmg = pd.FindMethod("Printer.Show(int)");
			Node print = null;
			for (let n in pmg.Graph.Nodes)
				if (n.Kind == .Call && n.Text == "WriteLine")
					print = n;
			let pin = print?.FindInput("arg0");
			Check(pin != null && pin.TypeName == "Object" && pin.Label == "obj" && pin.Default == "\"text\"", scope $"Console.WriteLine(\"text\") read back: the pin takes Object like a placed Print ({(pin != null) ? pin.TypeName : "none"})");
			ForceEdited(pmg.Graph);
			pd.PushUndo();
			Check(pd.Commit(pmg) && pd.Text == printText, "its text is written back byte for byte");
			let pmg2 = pd.FindMethod("Printer.Show(int)");
			Node print2 = null;
			for (let n in pmg2.Graph.Nodes)
				if (n.Kind == .Call && n.Text == "WriteLine")
					print2 = n;
			pd.PushUndo();
			pmg2.Graph.Connect(FindDataOut(pmg2.Graph.Entry, "n"), print2.FindInput("arg0"));
			print2.Edited = true;
			GraphValidator.Validate(pmg2.Graph);
			bool typeErr = false;
			for (let e in pmg2.Graph.Errors)
				if (e.NodeId == print2.Id)
					typeErr = true;
			Check(!typeErr && pd.Commit(pmg2) && pd.Text.Contains("\t\t\tConsole.WriteLine(n);"), "an int wired into it is accepted and written as Console.WriteLine(n)");
		}

		static Pin FindDataOut(Node n, StringView label)
		{
			for (let p in n.Outputs)
				if (p.Kind == .Data && p.Label == label)
					return p;
			return null;
		}

		static void ForceEdited(Graph g)
		{
			for (let n in g.Nodes)
				n.Edited = true;
		}

		static void TestTemplates()
		{
			Console.WriteLine("new-type templates and the UMP mod");
			Project p = scope .();
			p.Add("UMPMod.bf", cUMPBase);
			String text = scope .();
			TypeTemplates.MakeUMPMod("MyMod", "ModMain", "my.mod", "My Mod", "1.0.0", text);
			SourceDocument doc = scope .();
			doc.LoadFromText(text, "MyMod.bf");
			p.Update(doc);
			Check(doc.FindMethod("ModMain.Tick(float)") != null && doc.FindMethod("ModMain.Initialize()") != null && doc.FindMethod("ModMain.Shutdown()") != null, "UMP mod: Initialize / Tick / Shutdown graphs");
			Check(doc.FindMethod("ModMain.Tick(float)").Graphable, "Tick is a graph (the visual Event Tick)");
			ClassInfo info = scope .();
			ClassModel.Analyze(doc.Unit, FindType(doc, "ModMain"), p.Service, info);
			Check(info.BaseClass == "UMPMod" && info.Missing.IsEmpty && info.Problems.IsEmpty, "UMP mod: nothing missing (Info implemented)");
			Check(HasNames(info.Overridable, "OnEngineReady, OnWorldReady"), "Override dropdown offers OnEngineReady / OnWorldReady");
			String key = scope .();
			doc.AddOverride(FindType(doc, "ModMain"), info.FindOverridable("OnWorldReady(UWorld*)"), true, key);
			Check(key == "ModMain.OnWorldReady(UWorld*)" && doc.Text.Contains("\t\tpublic override void OnWorldReady(UWorld* World)\n\t\t{\n\t\t\tbase.OnWorldReady(World);\n\t\t}\n"), "OnWorldReady override with its parent call");

			String cls = scope .();
			TypeTemplates.Make("class", "Game", "Turret", "", "Actor, IDamageable", "", cls);
			Check(cls == "using System;\n\nnamespace Game\n{\n\tclass Turret : Actor, IDamageable\n\t{\n\t}\n}\n", "class with parent and interface");
			String plain = scope .();
			TypeTemplates.Make("class", "Game", "Thing", "", "", "", plain);
			Check(plain == "using System;\n\nnamespace Game\n{\n\tclass Thing\n\t{\n\t}\n}\n", "a plain class is empty (no Update, no written constructor)");
			String en = scope .();
			TypeTemplates.Make("enum", "Game", "Mode", "", "uint8", "", en);
			Check(en.Contains("\tenum Mode : uint8\n"), "enum with an underlying type");
		}

		// ------------------------------------------------------------------ modifiers helper

		static void TestMods()
		{
			Console.WriteLine("modifier words");
			String o = scope .();
			Mods.SetWord("public", "static", true, o);
			Check(o == "public static", "static after public");
			o.Clear();
			Mods.SetWord("static", "public", true, o);
			Check(o == "public static", "public before static");
			o.Clear();
			Mods.SetVisibility("private static", "protected", o);
			Check(o == "protected static", "visibility replaced in place");
			o.Clear();
			Mods.SetExclusive("public virtual", "virtual,override,abstract,new", "override", o);
			Check(o == "public override", "virtual -> override");
			o.Clear();
			Mods.SetExclusive("public", "virtual,override,abstract,new", "abstract", o);
			Check(o == "public abstract", "abstract added");
			o.Clear();
			Mods.SetWord("public static readonly", "readonly", false, o);
			Check(o == "public static", "readonly removed");
			List<String> attrs = scope .();
			defer { ClearAndDeleteItems!(attrs); }
			AttrList.Parse("[A, B(\"x, y\")][C]", attrs);
			Check(attrs.Count == 3 && attrs[1] == "B(\"x, y\")" && attrs[2] == "C", "attribute text split (strings, two groups)");
		}

		const String cCtorSrc =
			"""
			namespace A
			{
				class Base
				{
					public this(int x) { }
					public this(int x, String s) { }
				}

				class Foo : Base
				{
					public int mA;
					public int mB;

					public void Run()
					{
					}
				}

				interface IShape
				{
					void Draw();
				}
			}

			""";

		static void TestConstructors()
		{
			Console.WriteLine("constructors: several per class, chaining, defaults");
			Project p = scope .();
			SourceDocument doc = scope .();
			doc.LoadFromText(cCtorSrc, "Foo.bf");
			p.Update(doc);
			String key = scope .();
			var foo = FindType(doc, "Foo");

			Check(SourceDocument.HasDefaultMembers(foo) && SourceDocument.HasDefaultMembers(FindType(doc, "Base")), "classes get the default rows");
			Check(!SourceDocument.HasDefaultMembers(FindType(doc, "IShape")), "interfaces do not");
			Check(SourceDocument.FindDefaultCtor(foo) == null && SourceDocument.FindDtor(foo) == null, "Foo has neither written yet");

			int depth = doc.UndoDepth;
			Check(doc.AddConstructor(foo, "public", "int a, String b", "base(a)", key), "add Constructor (int, String) : base(a)");
			Check(doc.UndoDepth == depth + 1, "one undo step");
			Check(doc.Text.Contains("\t\tpublic this(int a, String b) : base(a)\n\t\t{\n\t\t}\n"), "chaining text written");
			Check(key == "Foo.this(int,String)" || key.StartsWith("Foo.this"), "key returned");
			Check(doc.Text.IndexOf("public this(int a") < doc.Text.IndexOf("public void Run"), "constructor goes before the functions");
			Check(doc.Text.IndexOf("public int mB;") < doc.Text.IndexOf("public this(int a"), "constructor goes after the fields");
			Check(doc.FindMethod(key) != null, "the constructor has a graph");
			{
				String t = scope .();
				doc.FindMethod(key)?.Graph.Entry.GetTitle(t);
				Check(t == "this(int, String)", scope $"the entry node is titled with the signature ({t})");
			}

			Check(doc.AddConstructor(foo = FindType(doc, "Foo"), "protected", "int a", "", key), "second constructor, different signature");
			Check(doc.Text.Contains("protected this(int a)\n"), "access written");
			let before = scope String(doc.Text);
			Check(!doc.AddConstructor(foo = FindType(doc, "Foo"), "public", "int other", "", key) && doc.LastError.Contains("Constructor (int)") && doc.Text == before, "same signature refused with the existing one named");
			Check(!doc.AddConstructor(foo, "public", "ref int a", "", key) == false, "ref changes the signature");
			Check(!doc.AddConstructor(foo = FindType(doc, "Foo"), "public", "void v", "", key), "bad parameter type refused");
			// A chain may only use the new constructor's own parameters and literals.
			let before2 = scope String(doc.Text);
			Check(!doc.AddConstructor(foo = FindType(doc, "Foo"), "public", "float f", "base(x)", key) && doc.LastError.Contains("x is not a parameter") && doc.Text == before2, "chain naming a missing parameter refused, naming it");
			Check(!doc.AddConstructor(foo, "public", "", "base(f)", key) && doc.Text == before2, "chain argument with no parameters at all refused");
			Check(!doc.AddConstructor(foo, "public", "float f", "base(f", key) && !doc.AddConstructor(foo, "public", "float f", "foo(f)", key) && doc.Text == before2, "a malformed chain is refused");
			Check(!doc.AddConstructor(foo, "public", "float f", "base(f + 1)", key) && doc.Text == before2, "an expression is not a parameter or a literal");
			Check(doc.AddConstructor(foo, "public", "float f", "this(f, 3.5f, \"s,t\", -1, true, null, 'c')", key) && doc.Text.Contains("this(float f) : this(f, 3.5f, \"s,t\", -1, true, null, 'c')"), "parameters and literals fit a chain");
			doc.Undo();
			Check(doc.AddConstructor(foo = FindType(doc, "Foo"), "public", "ref float f", "base(ref f)", key), "a ref argument naming a ref parameter fits");
			doc.Undo();
			CheckText(doc.Text, before2, "chain checks leave the text");

			// Parameter edits.
			{
				foo = FindType(doc, "Foo");
				Member c = null;
				for (let m in foo.Members)
					if (m.IsCtor && m.Params != null && m.Params.Count == 2 && m.Params[0].Name == "a")
						c = m;
				Check(c != null, "find (int, String)");
				Check(doc.SetSignature(c, "", "int a, String b, float c") && doc.Text.Contains("public this(int a, String b, float c) : base(a)"), "SetSignature on a constructor keeps the chaining");
				foo = FindType(doc, "Foo");
				for (let m in foo.Members)
					if (m.IsCtor && m.Params != null && m.Params.Count == 3)
						c = m;
				let b2 = scope String(doc.Text);
				Check(!doc.SetSignature(c, "", "int z") && doc.LastError.Contains("already has") && doc.Text == b2, "editing into an existing signature is refused");
				Check(doc.SetSignature(c, "", "params int[] rest") && doc.Text.Contains("this(params int[] rest) : base(a)"), "params allowed");
			}

			// Static constructor and destructor stay single.
			Check(doc.AddConstructor(foo = FindType(doc, "Foo"), true, key), "static constructor");
			Check(!doc.AddConstructor(foo = FindType(doc, "Foo"), true, key) && doc.LastError.Contains("static this()"), "second static constructor refused, names the existing one");
			Check(doc.AddDestructor(foo = FindType(doc, "Foo"), key), "destructor");
			Check(!doc.AddDestructor(foo = FindType(doc, "Foo"), key) && doc.LastError.Contains("~this()"), "second destructor refused, names the existing one");
			while (doc.UndoDepth > 0)
				doc.Undo();

			// The dimmed defaults materialise and un-materialise.
			{
				foo = FindType(doc, "Foo");
				depth = doc.UndoDepth;
				Check(doc.EnsureDefaultConstructor(foo, key), "materialise Constructor ()");
				Check(doc.UndoDepth == depth + 1, "one undo step");
				Check(doc.Text.Contains("\t\tpublic this()\n\t\t{\n\t\t}\n\n\t\tpublic void Run()"), "written after the fields, before the functions, spaced");
				Check(key == "Foo.this()" && doc.FindMethod(key) != null, "key and graph");
				foo = FindType(doc, "Foo");
				Check(SourceDocument.FindDefaultCtor(foo) != null, "the row is no longer dimmed");
				Check(doc.EnsureDefaultDestructor(foo, key), "materialise Destructor");
				Check(doc.Text.IndexOf("public this()") < doc.Text.IndexOf("public ~this()") && doc.Text.IndexOf("public ~this()") < doc.Text.IndexOf("public void Run"), "destructor after the constructor");
				foo = FindType(doc, "Foo");
				doc.DeleteMember(SourceDocument.FindDefaultCtor(foo));
				doc.DeleteMember(SourceDocument.FindDtor(FindType(doc, "Foo")));
				foo = FindType(doc, "Foo");
				Check(SourceDocument.FindDefaultCtor(foo) == null && SourceDocument.FindDtor(foo) == null, "deleting them puts the rows back to dimmed");
				Check(!doc.Text.Contains("this()") && !doc.Text.Contains("~this"), "removed from the file");
			}
			// Allman and an empty class.
			{
				SourceDocument d2 = scope .();
				d2.LoadFromText("namespace A\n{\n\tclass Empty\n\t{\n\t}\n}\n", "E.bf");
				Check(d2.EnsureDefaultConstructor(FindType(d2, "Empty"), key), "constructor in an empty class");
				Check(d2.Text.Contains("\tclass Empty\n\t{\n\t\tpublic this()\n\t\t{\n\t\t}\n\t}"), "Allman body, no stray blank lines");
			}
			// Parent constructors for the chaining picker.
			{
				ClassInfo info = scope .();
				ClassModel.Analyze(doc.Unit, FindType(doc, "Foo"), p.Service, info);
				Check(info.BaseCtors.Count == 2 && info.BaseCtors[0] == "int x" && info.BaseCtors[1] == "int x, String s", "parent constructors offered by signature");
			}
		}

		static void TestSetOnCreate()
		{
			SourceDocument doc = scope .();
			doc.LoadFromText("namespace G\n{\n\tpublic class Ship\n\t{\n\t\tpublic float mSpeed;\n\t\tpublic String mName;\n\t\tpublic int Hull;\n\t\tpublic static int sCount;\n\n\t\tpublic void Run()\n\t\t{\n\t\t}\n\t}\n}\n", "Ship.bf");
			Member Ty() => FindType(doc, "Ship");
			Member Fld(StringView n) => FindMember(Ty(), n);
			Member nomember = null;
			// Mark one: the constructor is created.
			int depth = doc.UndoDepth;
			Check(doc.SetFieldSetOnCreate(Ty(), Fld("mSpeed"), true), "mark mSpeed");
			Check(doc.UndoDepth == depth + 1, "one undo step");
			Check(doc.Text.Contains("\t\t// VisualBeef: set on create\n\t\tpublic this(float speed)\n\t\t{\n\t\t\tmSpeed = speed;\n\t\t}\n"), "exact text for one variable");
			Check(doc.Text.IndexOf("public this(float speed)") < doc.Text.IndexOf("public void Run") && doc.Text.IndexOf("sCount;") < doc.Text.IndexOf("// VisualBeef"), "after the fields, before the functions");
			{
				List<Member> l = scope .();
				Check(doc.GetCreateState(Ty(), l, out nomember) == .Marked && l.Count == 1 && l[0].Name == "mSpeed", "read back: Marked, mSpeed");
				Check(doc.IsSetOnCreate(Ty(), Fld("mSpeed")) && !doc.IsSetOnCreate(Ty(), Fld("mName")), "checkbox state per variable");
				String pt = scope .();
				doc.GetCreateParamsText(Ty(), pt);
				Check(pt == "float speed", "params text");
			}
			Check(doc.FindMethod("Ship.this(float)") != null, "the constructor has a graph");
			// Mark a second one: regenerated in variable order.
			depth = doc.UndoDepth;
			Check(doc.SetFieldSetOnCreate(Ty(), Fld("mName"), true), "mark mName");
			Check(doc.UndoDepth == depth + 1, "one undo step (second)");
			Check(doc.Text.Contains("\t\t// VisualBeef: set on create\n\t\tpublic this(float speed, String name)\n\t\t{\n\t\t\tmSpeed = speed;\n\t\t\tmName = name;\n\t\t}\n"), "exact text for two variables");
			Check(doc.Text.IndexOf("// VisualBeef: set on create", doc.Text.IndexOf("// VisualBeef: set on create") + 1) < 0, "one marker line");
			Check(doc.Text.Contains("public int Hull;\n") && doc.Text.Contains("public void Run()"), "the rest of the file is untouched");
			{
				let b = scope String(doc.Text);
				Check(doc.SetFieldSetOnCreate(Ty(), Fld("Hull"), true) && doc.Text.Contains("public this(float speed, String name, int hull)") && doc.Text.Contains("Hull = hull;"), "Hull -> hull");
				Check(doc.SetFieldSetOnCreate(Ty(), Fld("Hull"), false) && doc.Text == b, "unmark restores the text exactly");
			}
			Check(!doc.SetFieldSetOnCreate(Ty(), Fld("sCount"), true) && doc.LastError.Contains("instance"), "a static variable is refused");
			// The constructor follows a marked variable's type change and its deletion, in the same undo step.
			{
				let b = scope String(doc.Text);
				int d0 = doc.UndoDepth;
				Check(doc.SetMemberType(Fld("mSpeed"), "double") && doc.Text.Contains("public this(double speed, String name)") && doc.IsSetOnCreate(Ty(), Fld("mSpeed")), "retyping a marked variable retypes its parameter; still marked");
				Check(doc.UndoDepth == d0 + 1, "one undo step for the retype");
				doc.DeleteMember(Fld("mName"));
				Check(doc.Text.Contains("public this(double speed)") && !doc.Text.Contains("mName = name;") && doc.IsSetOnCreate(Ty(), Fld("mSpeed")), "deleting a marked variable takes it out of the constructor");
				Check(doc.UndoDepth == d0 + 2, "one undo step for the delete");
				doc.Undo();
				doc.Undo();
				Check(doc.Text == b, "both undone: the text is back");
			}
			// Unmark both: the constructor goes, marker included.
			Check(doc.SetFieldSetOnCreate(Ty(), Fld("mSpeed"), false) && doc.Text.Contains("public this(String name)") && !doc.Text.Contains("mSpeed = "), "unmark one");
			Check(doc.SetFieldSetOnCreate(Ty(), Fld("mName"), false) && !doc.Text.Contains("this(") && !doc.Text.Contains("VisualBeef"), "unmark the last: constructor and marker removed");
			Check(doc.GetCreateState(Ty(), null, out nomember) == .None, "state None");
			doc.Undo();
			Check(doc.IsSetOnCreate(Ty(), Fld("mName")), "undo brings it back");
			while (doc.UndoDepth > 0)
				doc.Undo();
			Check(doc.Text.Contains("sCount;\n\n\t\tpublic void Run") && !doc.Text.Contains("VisualBeef"), "all undone");
			// The Construct node's pin defaults are the variables' Initial values (MemberInit), not the destructor clause.
			{
				SourceDocument d3 = scope .();
				d3.LoadFromText("class Ship2\n{\n\tpublic float mSpeed = 2.5f;\n\tpublic Other mO = new .(3) ~ delete _;\n\tpublic int mN;\n\tpublic String mS ~ delete _;\n}\n", "Ship2.bf");
				Member Ty3() => FindType(d3, "Ship2");
				for (let n in StringView[?]("mSpeed", "mO", "mN", "mS"))
					d3.SetFieldSetOnCreate(Ty3(), FindMember(Ty3(), n), true);
				List<String> defs = scope .();
				defer { ClearAndDeleteItems!(defs); }
				d3.GetCreateDefaults(Ty3(), defs);
				Check(defs.Count == 4 && defs[0] == "2.5f" && defs[1] == "new .(3)" && defs[2] == "default" && defs[3] == "default",
					scope $"Construct defaults read the Initial value: 2.5f, new .(3), default, default ({defs.Count}: {defs[1]})");
			}
			// Clash: mSpeed and Speed would both become speed.
			{
				SourceDocument d2 = scope .();
				d2.LoadFromText("class Clash\n{\n\tpublic float mSpeed;\n\tpublic float Speed;\n\tpublic int mNew;\n\tpublic int mBase;\n}\n", "Clash.bf");
				Member Ty2() => FindType(d2, "Clash");
				Check(d2.SetFieldSetOnCreate(Ty2(), FindMember(Ty2(), "mSpeed"), true), "mark mSpeed (clash file)");
				let b = scope String(d2.Text);
				Check(!d2.SetFieldSetOnCreate(Ty2(), FindMember(Ty2(), "Speed"), true) && d2.LastError.Contains("both become the parameter 'speed'") && d2.Text == b, "clash refused with a message, text unchanged");
				Check(!d2.SetFieldSetOnCreate(Ty2(), FindMember(Ty2(), "mBase"), true) && d2.LastError.Contains("reserved word") && d2.Text == b, "a reserved parameter name is refused");
			}
			// A constructor written by hand with the same signature.
			{
				SourceDocument d3 = scope .();
				d3.LoadFromText("class Hand\n{\n\tpublic float mSpeed;\n\n\tpublic this(float s)\n\t{\n\t\tmSpeed = s * 2;\n\t}\n}\n", "Hand.bf");
				Member Ty3() => FindType(d3, "Hand");
				let b = scope String(d3.Text);
				Check(!d3.SetFieldSetOnCreate(Ty3(), FindMember(Ty3(), "mSpeed"), true) && d3.LastError.Contains("already has a constructor with these parameters: Constructor (float)") && d3.Text == b, "same signature as a hand-written constructor refused");
				d3.LoadFromText("class Hand\n{\n\tpublic float mSpeed;\n\tpublic int mN;\n\n\tpublic this(float s)\n\t{\n\t\tmSpeed = s * 2;\n\t}\n}\n", "Hand.bf");
				Check(d3.SetFieldSetOnCreate(Ty3(), FindMember(Ty3(), "mN"), true) && d3.Text.Contains("mSpeed = s * 2;") && d3.Text.Contains("public this(int n)"), "other constructors are left alone");
			}
			// Hand-edited: read-back says Custom, edits are refused.
			{
				SourceDocument d4 = scope .();
				d4.LoadFromText("class Edited\n{\n\tpublic float mSpeed;\n\tpublic String mName;\n\n\t// VisualBeef: set on create\n\tpublic this(float speed, String name)\n\t{\n\t\tmSpeed = speed * 2;\n\t\tmName = name;\n\t}\n}\n", "Edited.bf");
				Member Ty4() => FindType(d4, "Edited");
				List<Member> l = scope .();
				Check(d4.GetCreateState(Ty4(), l, out nomember) == .Custom && l.Count == 0, "a changed body reads back as Custom");
				let b = scope String(d4.Text);
				Check(!d4.SetFieldSetOnCreate(Ty4(), FindMember(Ty4(), "mName"), false) && d4.LastError.Contains("edited by hand") && d4.Text == b, "Custom: unmark refused");
				Check(!d4.IsSetOnCreate(Ty4(), FindMember(Ty4(), "mSpeed")), "Custom: no checkbox ticked");
				d4.LoadFromText("class Edited\n{\n\tpublic float mSpeed;\n\tpublic String mName;\n\n\t// VisualBeef: set on create\n\tpublic this(float s, String n) {\n\t\tthis.mSpeed = s; mName = n;\n\t}\n}\n", "Edited.bf");
				l.Clear();
				Check(d4.GetCreateState(Ty4(), l, out nomember) == .Marked && l.Count == 2, "other parameter names and spacing still read as Marked");
				Check(d4.SetFieldSetOnCreate(Ty4(), FindMember(Ty4(), "mName"), false) && d4.Text.Contains("// VisualBeef: set on create\n\tpublic this(float speed)\n\t{\n\t\tmSpeed = speed;\n\t}"), "regenerated in the file's brace style, parameter names re-derived");
				d4.LoadFromText("class Plain\n{\n\tpublic float mSpeed;\n\n\tpublic this(float speed)\n\t{\n\t\tmSpeed = speed;\n\t}\n}\n", "Plain.bf");
				Check(d4.GetCreateState(FindType(d4, "Plain"), null, out nomember) == .None, "no marker: not the create constructor");
			}
			// A struct, and the Add Variable path (one undo step).
			{
				SourceDocument d5 = scope .();
				d5.LoadFromText("struct Pt\n{\n\tpublic int X;\n}\n", "Pt.bf");
				Member Ty5() => FindType(d5, "Pt");
				Check(d5.SetFieldSetOnCreate(Ty5(), FindMember(Ty5(), "X"), true) && d5.Text.Contains("public this(int x)\n\t{\n\t\tX = x;\n\t}"), "struct: Pt(int x)");
				int depth5 = d5.UndoDepth;
				Check(d5.AddFieldSetOnCreate(Ty5(), "int", "Y", "", true) && d5.UndoDepth == depth5 + 1, "Add Variable with Set on create is one undo step");
				Check(d5.Text.Contains("public this(int x, int y)") && d5.Text.Contains("Y = y;"), "the new variable is a parameter");
				Check(d5.Text.IndexOf("public int Y;") < d5.Text.IndexOf("// VisualBeef"), "variable above the constructor");
				d5.Undo();
				Check(!d5.Text.Contains("Y") && d5.Text.Contains("public this(int x)"), "one undo removes both");
			}
			// K&R style file.
			{
				SourceDocument d6 = scope .();
				d6.LoadFromText("class Kr {\n    public int mA;\n    public void F() {\n    }\n}\n", "Kr.bf");
				Member Ty6() => FindType(d6, "Kr");
				Check(d6.SetFieldSetOnCreate(Ty6(), FindMember(Ty6(), "mA"), true) && d6.Text.Contains("    // VisualBeef: set on create\n    public this(int a) {\n        mA = a;\n    }\n"), "K&R file: same style");
			}
		}


		static void TestNodeLibrary()
		{
			Console.WriteLine("node library: static class as a type kind");
			const String libText = "namespace Mod\n{\n\tstatic class Tools\n\t{\n\t\tpublic static int sCount = 3;\n\t\tpublic static int Twice(int x)\n\t\t{\n\t\t\treturn x * 2;\n\t\t}\n\t}\n}\n";
			// Reading: `static class` is a Node Library; `class` with only static members stays a Class.
			{
				SourceDocument d = scope .();
				d.LoadFromText(libText, "Tools.bf");
				let lib = FindType(d, "Tools");
				Check(lib != null && lib.IsNodeLibrary && lib.TypeKind == "class", "`static class` reads back as a Node Library");
				Check(d.Text == libText, "the file round-trips byte for byte");
				Check(FindMember(lib, "Twice").IsStatic && FindMember(lib, "sCount").IsStatic, "its members are static");
				SourceDocument c = scope .();
				c.LoadFromText("namespace Mod\n{\n\tclass Plain\n\t{\n\t\tpublic static int sCount;\n\t}\n\tstatic\n\t{\n\t\tpublic static int G;\n\t}\n}\n", "Plain.bf");
				Check(!FindType(c, "Plain").IsNodeLibrary, "`class` with only static members stays a Class");
				bool anyLib = false;
				List<Member> types = scope .();
				c.Unit.CollectTypes(types);
				for (let t in types)
					if (t.IsNodeLibrary)
						anyLib = true;
				Check(!anyLib, "a `static { }` block of globals is not a Node Library");
				SourceDocument h = scope .();
				h.LoadFromText("static class Hand\n{\n\tpublic int mNoWord;\n\tpublic void Fn() {}\n}\n", "Hand.bf");
				Check(FindMember(FindType(h, "Hand"), "mNoWord").IsStatic && FindMember(FindType(h, "Hand"), "Fn").IsStatic, "a member written without `static` is static in a Node Library");
			}
			// The kind chooser: Class <-> Node Library.
			{
				SourceDocument d = scope .();
				d.LoadFromText("namespace Mod\n{\n\tclass Tools\n\t{\n\t\tpublic static int sCount = 3;\n\t}\n}\n", "Tools.bf");
				int depth = d.UndoDepth;
				Check(d.SetTypeKind(FindType(d, "Tools"), "library") && d.Text.Contains("\tstatic class Tools\n") && d.UndoDepth == depth + 1, "Class -> Node Library writes `static class` (one undo step)");
				Check(FindType(d, "Tools").IsNodeLibrary, "and it reads back as one");
				Check(d.SetTypeKind(FindType(d, "Tools"), "class") && d.Text.Contains("\tclass Tools\n") && !d.Text.Contains("static class"), "Node Library -> Class removes `static`");
				Check(FindMember(FindType(d, "Tools"), "sCount").Modifiers.Contains("static"), "the members stay static");
				d.SetTypeKind(FindType(d, "Tools"), "library");
				Check(!d.SetTypeKind(FindType(d, "Tools"), "struct") && d.LastError.Contains("Class"), "a Node Library cannot jump to a struct");
				SourceDocument inst = scope .();
				inst.LoadFromText("class Obj : Base\n{\n\tpublic static int mA;\n}\n", "Obj.bf");
				Check(!inst.SetTypeKind(FindType(inst, "Obj"), "library") && inst.LastError.Contains("parent"), "a class with a parent cannot become a Node Library");
				SourceDocument inst2 = scope .();
				inst2.LoadFromText("class Obj\n{\n\tpublic int mA;\n}\n", "Obj.bf");
				Check(!inst2.SetTypeKind(FindType(inst2, "Obj"), "library") && inst2.LastError.Contains("mA") && inst2.Text == "class Obj\n{\n\tpublic int mA;\n}\n", "an instance variable is named and nothing is written");
				SourceDocument inst3 = scope .();
				inst3.LoadFromText("class Obj\n{\n\tpublic this() {}\n}\n", "Obj.bf");
				Check(!inst3.SetTypeKind(FindType(inst3, "Obj"), "library") && inst3.LastError.Contains("constructor"), "a constructor is named");
			}
			// Members written into a library are static; the Static word is locked.
			{
				SourceDocument d = scope .();
				d.LoadFromText("namespace Mod\n{\n\tstatic class Tools\n\t{\n\t}\n}\n", "Tools.bf");
				String key = scope .();
				Check(d.AddMethod(FindType(d, "Tools"), "int", "Count", "", key) && d.Text.Contains("\t\tpublic static int Count()"), "Add Function writes `public static`");
				let mg = d.FindMethod(key);
				Check(mg != null && mg.Graph.StaticContext && mg.Graph.InLibrary, "its sheet has no this");
				Check(d.AddField(FindType(d, "Tools"), "int", "sTotal", "5") && d.Text.Contains("\t\tpublic static int sTotal = 5;"), "Add Variable writes `public static`");
				Check(d.AddFunction(FindType(d, "Tools"), "public", "void", "Reset", "", key) && d.Text.Contains("public static void Reset()"), "AddFunction adds `static` to the modifiers");
				Check(!d.SetModifierWord(FindMember(FindType(d, "Tools"), "sTotal"), "static", false) && d.LastError.Contains("Node Library"), "Static cannot be turned off on a variable");
				Check(!d.SetModifierWord(FindMember(FindType(d, "Tools"), "Reset"), "static", false), "nor on a function");
				SourceDocument c = scope .();
				c.LoadFromText("namespace Mod\n{\n\tclass Holder\n\t{\n\t}\n}\n", "Holder.bf");
				Check(c.AddField(FindType(c, "Holder"), "int", "sGlobal", "7", true) && c.Text.Contains("public static int sGlobal = 7;"), "a Class variable can be added as static");
				Check(c.SetModifierWord(FindMember(FindType(c, "Holder"), "sGlobal"), "static", false) && c.Text.Contains("public int sGlobal = 7;"), "and static can be turned off on a class variable");
			}
			// Owned objects in a static variable (the static-init rule).
			{
				SourceDocument d = scope .();
				d.LoadFromText("using System;\nnamespace Mod\n{\n\tstatic class Tools\n\t{\n\t}\n}\n", "Tools.bf");
				MemberInit init = scope .();
				init.Owner = .OwnedCreatedHere;
				Check(d.AddField(FindType(d, "Tools"), "String", "sName", init) && d.Text.Contains("public static String sName = new .() ~ delete _;"), "an owned String global: `static String sName = new .() ~ delete _;`");
			}
			// The validator: no this, no Construct.
			{
				Project p = scope .();
				p.Add("Tools.bf", libText);
				SourceDocument doc = scope .();
				doc.LoadFromText("namespace Mod\n{\n\tclass Program\n\t{\n\t\tpublic static void Main()\n\t\t{\n\t\t\tlet a = Tools.Twice(3);\n\t\t\tlet t = new Tools();\n\t\t}\n\t}\n}\n", "Program.bf");
				p.Update(doc);
				let rg = doc.FindMethod("Program.Main()").Graph;
				rg.ClearErrors();
				GraphValidator.Validate(rg);
				bool warned = false;
				for (let e in rg.Warnings)
					if (e.Message.Contains("Tools is a Node Library: it cannot be constructed"))
						warned = true;
				Check(warned, "`new Tools()` read from code: a warning that a Node Library is never constructed");
				Node call = null;
				for (let n in rg.Nodes)
					if (n.Kind == .Call && n.Text.Contains("Twice"))
						call = n;
				Check(call != null && call.FindInput("target") == null, "Tools.Twice(3) has no Receiver pin");
				StringView[0] none = .();
				let made = NodeFactory.Construct(rg, "Tools", "new", none, none);
				made.Edited = true;
				rg.ClearErrors();
				GraphValidator.Validate(rg);
				bool err = false;
				for (let e in rg.Errors)
					if (e.NodeId == made.Id && e.Message.Contains("cannot be constructed"))
						err = true;
				Check(err, "Construct Tools made in the editor: an error on the node");
				SourceDocument lib = scope .();
				lib.LoadFromText(libText, "Tools.bf");
				p.Update(lib);
				let tg = lib.FindMethod("Tools.Twice(int)").Graph;
				let thisNode = NodeFactory.This(tg, "Tools");
				thisNode.Edited = true;
				tg.ClearErrors();
				GraphValidator.Validate(tg);
				err = false;
				for (let e in tg.Errors)
					if (e.NodeId == thisNode.Id && e.Message.Contains("There is no this in Tools"))
						err = true;
				Check(err, "a This node inside a library function: an error that says there is no this");
			}
			// The Node menu categories.
			{
				Project p = scope .();
				p.Add("Tools.bf", libText);
				p.Add("Holder.bf", "namespace Mod\n{\n\tclass Holder\n\t{\n\t\tpublic static int sGlobal;\n\t\tpublic int mLocal;\n\t\tpublic static void Make() {}\n\t}\n}\n");
				let cat = p.Service.Catalog;
				cat.Refresh();
				String twice = scope .();
				String sGet = scope .();
				String sSet = scope .();
				String libGet = scope .();
				String make = scope .();
				String local = scope .();
				for (int si < cat.Stores.Count)
				{
					let sc = cat.Stores[si];
					for (int ei < sc.Entries.Count)
					{
						NodeSpec spec = scope .();
						cat.GetSpec(NodeCatalog.MakeId(si, ei), spec);
						if (spec.OwnerType == "Tools" && spec.MemberName == "Twice") twice.Set(spec.Category);
						else if (spec.OwnerType == "Tools" && spec.MemberName == "sCount" && spec.Kind == .Get) libGet.Set(spec.Category);
						else if (spec.OwnerType == "Holder" && spec.MemberName == "sGlobal" && spec.Kind == .Get) sGet.Set(spec.Category);
						else if (spec.OwnerType == "Holder" && spec.MemberName == "sGlobal" && spec.Kind == .Set) sSet.Set(spec.Category);
						else if (spec.OwnerType == "Holder" && spec.MemberName == "Make") make.Set(spec.Category);
						else if (spec.OwnerType == "Holder" && spec.MemberName == "mLocal" && spec.Kind == .Get) local.Set(spec.Category);
					}
				}
				Check(twice == "Libraries|Mod.Tools", scope $"a library function is under Libraries > Mod.Tools (got '{twice}')");
				Check(libGet == "Globals|Tools", scope $"a library variable is under Globals > Tools (got '{libGet}')");
				Check(sGet == "Globals|Holder" && sSet == "Globals|Holder", scope $"a static variable of a class: Get and Set under Globals > Holder (got '{sGet}', '{sSet}')");
				Check(make == "Mod|Holder" && local == "Mod|Holder", "a class's static function and instance variable keep their class category");
			}
		}

		public static int Run()
		{
			TestMods();
			TestDeclarations();
			TestEdits();
			TestInheritance();
			TestGraphChecks();
			TestRenames();
			TestTemplates();
			TestConstructors();
			TestNewcomer();
			TestPassing();
			TestReturnDefaults();
			TestSetLabels();
			TestConstructChoice();
			TestNodeLibrary();
			InitTests.sChecks = 0;
			InitTests.sFailures = 0;
			InitTests.RunChecks();
			sChecks += InitTests.sChecks;
			sFailures += InitTests.sFailures;
			TestSetOnCreate();
			LocalsTests.Checks = 0;
			LocalsTests.Failures = 0;
			LocalsTests.RunClasses();
			sChecks += LocalsTests.Checks;
			sFailures += LocalsTests.Failures;
			Console.WriteLine("class checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}

		/// The declaration-form cases, also run by `parser`.
		public static int RunParser()
		{
			int before = sFailures;
			TestDeclarations();
			return sFailures - before;
		}
	}
}
