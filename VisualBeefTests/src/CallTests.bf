using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// The call model (docs/Calls-and-Receivers.md): Target / self / static, the Self node, out
	/// and ref arguments, and GraphValidator's errors. Runs as part of `flow` (and `edits`);
	/// `calls` runs it alone. Builds and runs of the same shapes are in `compile`.
	static class CallTests
	{
		static int sFailures;
		static int sChecks;

		public static int Checks => sChecks;

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

		const String cCalls =
			"""
			using System;

			namespace Demo
			{
				class Base
				{
					public int mHp = 10;
					public bool mFlag;
					public uint mCount;

					public void Hit(int amount)
					{
						mHp -= amount;
					}

					public static int Twice(int x)
					{
						return x * 2;
					}
				}

				class Player : Base
				{
					public void TakeDamage(int amount)
					{
						Hit(amount);
					}
				}

				class Enemy : Base
				{
					public Player mTarget;

					public void Attack()
					{
						Hit(1);
						this.Hit(2);
						mTarget.TakeDamage(3);
						Console.WriteLine("x");
						Base.Twice(4);
					}

					public static void Spawn()
					{
						Twice(5);
					}

					public bool TryGet(int key, out int value)
					{
						value = key;
						return true;
					}

					public void Fill(ref int total)
					{
						total++;
					}

					public void GetAll([Pin(Out=true)] ref int count)
					{
						count = 3;
					}

					public void Outs()
					{
						int v;
						TryGet(1, out v);
						Console.WriteLine(v);
						if (TryGet(2, var w))
						{
							Hit(w);
						}
						TryGet(3, ?);
						if (TryGet(4, out mHp))
						{
							Hit(mHp);
						}
						Fill(ref mHp);
						int count = default;
						GetAll(ref count);
						Hit(count);
					}

					public void Empty()
					{
					}
				}
			}

			""";

		/// A resolver over one source text (the project index holds just that file), installed
		/// like the editor installs it.
		class Resolver
		{
			ProjectIndex mIndex = new .();
			TypeService mService;
			ProjectIndex mOldIndex;

			public this(StringView text)
			{
				let unit = Parser.Parse(text);
				mIndex.AddFile("Calls.bf", unit);
				delete unit;
				mService = new .(mIndex);
				mService.AutoLoadLibraries = false;
				mService.Install();
				mOldIndex = GraphBuilder.Index;
				GraphBuilder.Index = mIndex;
			}

			/// (Lives for the scope that declares it.)
			public void Use()
			{
			}

			public ~this()
			{
				GraphBuilder.Index = mOldIndex;
				delete mService;
				TypeService.Current = null;
				TypeRules.Hierarchy = null;
				delete mIndex;
			}
		}

		// ------------------------------------------------------------------ helpers

		static Node FindCall(Graph g, StringView name, StringView arg0 = "")
		{
			for (let n in g.Nodes)
			{
				if (n.Kind != .Call || n.Text != name)
					continue;
				if (arg0.IsEmpty)
					return n;
				let p = n.FindInput("arg0");
				if (p != null && p.Default == arg0)
					return n;
			}
			return null;
		}

		static Node FindNode(Graph g, NodeKind kind, StringView text = "")
		{
			for (let n in g.Nodes)
				if (n.Kind == kind && (text.IsEmpty || n.Text == text))
					return n;
			return null;
		}

		static bool HasError(Graph g, StringView text, Node on = null)
		{
			for (let e in g.Errors)
				if (e.Message.Contains(text) && (on == null || e.NodeId == on.Id))
					return true;
			return false;
		}

		static bool HasWarning(Graph g, StringView text)
		{
			for (let e in g.Warnings)
				if (e.Message.Contains(text))
					return true;
			return false;
		}

		static void ShowErrors(Graph g)
		{
			for (let e in g.Errors)
				Console.WriteLine("       error: {}", e.Message);
		}

		/// Source of the source document's method `key` (signature to closing brace).
		static void MethodText(SourceDocument doc, StringView key, String o)
		{
			let mg = doc.FindMethod(key);
			if (mg == null || !mg.Method.HasSpan)
				return;
			let start = doc.Unit.Tokens[mg.Method.FirstTok].Start;
			let end = doc.Unit.Tokens[mg.Method.LastTok].End;
			o.Append(StringView(doc.Text, start, end - start));
		}

		/// Chains exec nodes after the entry of `g`.
		static void Chain(Graph g, params Node[] nodes)
		{
			Pin prev = g.Entry.Then;
			for (let n in nodes)
			{
				g.Connect(prev, n.ExecIn);
				prev = n.Then;
			}
		}

		static Node Hit(Graph g, StringView amount = "")
		{
			StringView[1] names = .("amount");
			StringView[1] types = .("int");
			let n = NodeFactory.MemberCall(g, "Hit", "Base", true, names, types, "void");
			n.FindInput("arg0").Default.Set(amount);
			return n;
		}

		static Node TryGet(Graph g, StringView key, bool exec = true, StringView outType = "int")
		{
			StringView[2] names = .("key", "value");
			StringView[2] types = .("int", outType);
			StringView[2] mods = .("", "out");
			let n = NodeFactory.MemberCall(g, "TryGet", "Enemy", exec, names, types, "bool", mods);
			n.FindInput("arg0").Default.Set(key);
			return n;
		}

		/// Loads `cCalls`, builds nodes into `key` with `make`, commits. Returns the commit result.
		static bool Edit(SourceDocument doc, StringView key, delegate void(Graph g) make, StringView source = cCalls)
		{
			doc.LoadFromText(source, "Calls.bf");
			let mg = doc.FindMethod(key);
			if (mg == null)
				return false;
			doc.PushUndo();
			make(mg.Graph);
			return doc.Commit(mg);
		}

		/// Identity commit and forced regeneration of every method reproduce the text.
		static void CheckByteExact(StringView source, StringView what)
		{
			SourceDocument doc = scope .();
			doc.LoadFromText(source, "Calls.bf");
			List<String> keys = scope .();
			defer { ClearAndDeleteItems!(keys); }
			for (let mg in doc.Methods)
				if (mg.Graphable)
					keys.Add(new String(mg.Key));
			bool identity = true;
			bool forced = true;
			for (let key in keys)
			{
				if (!doc.Commit(doc.FindMethod(key)) || doc.Text != source)
					identity = false;
			}
			for (let key in keys)
			{
				let mg = doc.FindMethod(key);
				let g = mg.Graph;
				for (let n in g.Nodes)
					n.Edited = true;
				if (!doc.Commit(mg))
				{
					ShowErrors(g);
					forced = false;
				}
			}
			if (doc.Text != source)
			{
				forced = false;
				Program.ShowDiff(source, doc.Text);
			}
			Check(identity, scope $"{what}: an identity commit of every method changes nothing");
			Check(forced, scope $"{what}: regenerating every statement reproduces the file byte for byte");
		}

		// ------------------------------------------------------------------ 1. shapes

		static void RunShapes()
		{
			Console.WriteLine("Calls 1: call shapes read from code, with the resolver");
			{
				Resolver r = scope .(cCalls);
				r.Use();
				SourceDocument doc = scope .();
				doc.LoadFromText(cCalls, "Calls.bf");
				let g = doc.FindMethod("Enemy.Attack()").Graph;
				let self = FindCall(g, "Hit", "1");
				Check(self != null && self.Binding == .Instance && self.OwnerType == "Base", "`Hit(1)` from a derived class: a member call of Base");
				let t = self?.FindInput("target");
				Check(t != null && g.FindLinkTo(t) == null && t.Default.IsEmpty, "`Hit(1)`: Target pin left unconnected (self)");
				let viaThis = FindCall(g, "Hit", "2");
				let thisSrc = (viaThis != null) ? g.DataSource(viaThis.FindInput("target")) : null;
				Check(thisSrc != null && thisSrc.Kind == .This, "`this.Hit(2)`: Target wired from a Self node");
				let take = FindCall(g, "TakeDamage");
				let takeSrc = (take != null) ? g.DataSource(take.FindInput("target")) : null;
				Check(take != null && take.Binding == .Instance && take.OwnerType == "Player", "`mTarget.TakeDamage(3)`: a member call of Player");
				Check(takeSrc != null && takeSrc.Kind == .Get && takeSrc.Text == "mTarget" && take.FindInput("target").Default.IsEmpty,
					"`mTarget.TakeDamage(3)`: Target wired from a Get of mTarget (not text in the pin)");
				let write = FindCall(g, "WriteLine");
				Check(write != null && write.Binding == .Static && write.Qualifier == "Console" && write.FindInput("target") == null,
					"`Console.WriteLine`: static, no Target pin, qualifier kept");
				let twice = FindCall(g, "Twice");
				Check(twice != null && twice.Binding == .Static && twice.Qualifier == "Base" && twice.FindInput("target") == null, "`Base.Twice(4)`: static with qualifier Base");
				Check(g.Errors.IsEmpty && g.Warnings.IsEmpty, "no errors or warnings on code that compiles");
				let spawn = doc.FindMethod("Enemy.Spawn()").Graph;
				let twice5 = FindCall(spawn, "Twice");
				Check(spawn.StaticContext && twice5 != null && twice5.Binding == .Static && twice5.Qualifier == null && twice5.FindInput("target") == null,
					"`Twice(5)` in a static method: static, no qualifier, no Target");
				let player = doc.FindMethod("Player.TakeDamage(int)").Graph;
				Check(player.SelfType == "Player" && !player.StaticContext, "graph knows self (Player) and that the method is not static");
				CheckByteExact(cCalls, "resolver installed");
			}

			Console.WriteLine("Calls 2: the same code without a resolver");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cCalls, "Calls.bf");
				let g = doc.FindMethod("Enemy.Attack()").Graph;
				let self = FindCall(g, "Hit", "1");
				Check(self != null && self.Binding == .Unresolved && self.FindInput("target") == null, "`Hit(1)` (declared in a base) stays an unresolved call without Target");
				let viaThis = FindCall(g, "Hit", "2");
				Check(viaThis != null && viaThis.Binding == .Instance && g.DataSource(viaThis.FindInput("target"))?.Kind == .This, "`this.Hit(2)` still wires a Self node");
				let take = FindCall(g, "TakeDamage");
				Check(take != null && g.DataSource(take.FindInput("target"))?.Text == "mTarget", "`mTarget.TakeDamage(3)`: a field is a value, wired");
				let write = FindCall(g, "WriteLine");
				Check(write != null && write.Binding == .Static && write.Qualifier == "Console", "`Console.WriteLine`: static (well-known type)");
				let twice = FindCall(g, "Twice");
				Check(twice != null && twice.Binding == .Unresolved && twice.FindInput("target")?.Default == "Base",
					"`Base.Twice(4)` with nothing indexed: unresolved, the text stays in the Target pin");
				let outs = doc.FindMethod("Enemy.Outs()").Graph;
				let own = FindCall(outs, "Fill");
				Check(own != null && own.Binding == .Instance && own.FindInput("target") != null, "own member function: Target pin from the type's own declarations");
				Check(g.Errors.IsEmpty, "no errors without a resolver");
				CheckByteExact(cCalls, "no resolver");
			}
		}

		// ------------------------------------------------------------------ 2. Target errors

		static void RunTargets()
		{
			Console.WriteLine("Calls 3: Target errors (GraphValidator)");
			Resolver r = new .(cCalls);
			{
				SourceDocument doc = scope .();
				Node call = null;
				bool ok = Edit(doc, "Enemy.Spawn()", scope [&] (g) =>
					{
						call = Hit(g, "1");
						g.Connect(call.Then, g.ExecTarget(g.Entry.Then).ExecIn);
						g.Connect(g.Entry.Then, call.ExecIn);
					});
				let g = doc.FindMethod("Enemy.Spawn()").Graph;
				Check(!ok && doc.Text == cCalls, "self in a static method: commit refused, file untouched");
				Check(HasError(g, "Receiver must be a Base: this function is static, so there is no this.", call), "error on the node: \"Receiver must be a Base: this function is static, so there is no self.\"");
			}
			{
				SourceDocument doc = scope .();
				Node call = null;
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						StringView[1] names = .("amount");
						StringView[1] types = .("int");
						call = NodeFactory.MemberCall(g, "TakeDamage", "Player", true, names, types, "void");
						call.FindInput("arg0").Default.Set("5");
						Chain(g, call);
					});
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(!ok && doc.Text == cCalls, "Player.TakeDamage with self while editing Enemy: refused");
				Check(HasError(g, "Receiver must be a Player; this is an Enemy.", call), "error on the node: \"Receiver must be a Player; this is an Enemy.\"");
			}
			{
				SourceDocument doc = scope .();
				Node call = null;
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						StringView[1] names = .("amount");
						StringView[1] types = .("int");
						call = NodeFactory.MemberCall(g, "TakeDamage", "Player", true, names, types, "void");
						call.FindInput("arg0").Default.Set("5");
						g.Connect(NodeFactory.This(g, "Enemy").Result, call.FindInput("target"));
						Chain(g, call);
					});
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(!ok && HasError(g, "Receiver must be a Player; the wire brings an Enemy.", call), "Self (an Enemy) wired into a Player Target: \"Receiver must be a Player; the wire brings an Enemy.\"");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						StringView[1] names = .("amount");
						StringView[1] types = .("int");
						let call = NodeFactory.MemberCall(g, "TakeDamage", "Player", true, names, types, "void");
						call.FindInput("arg0").Default.Set("5");
						g.Connect(NodeFactory.Get(g, "mTarget", "Player").Result, call.FindInput("target"));
						Chain(g, call);
					});
				Check(ok && doc.Text.Contains("\t\t\tmTarget.TakeDamage(5);\n"), "a Player wired into Target: `mTarget.TakeDamage(5);`");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let self = Hit(g, "1");
						let viaThis = Hit(g, "2");
						g.Connect(NodeFactory.This(g, "Enemy").Result, viaThis.FindInput("target"));
						StringView[1] xName = .("x");
						StringView[1] intType = .("int");
						let twice = NodeFactory.StaticCall(g, "Twice", "Base", "Base", true, xName, intType, "int");
						twice.FindInput("arg0").Default.Set("3");
						let own = NodeFactory.StaticCall(g, "Twice", "", "Base", true, xName, intType, "int");
						own.FindInput("arg0").Default.Set("4");
						Chain(g, self, viaThis, twice, own);
					});
				Check(ok && doc.Text.Contains("\t\t\tHit(1);\n\t\t\tthis.Hit(2);\n\t\t\tBase.Twice(3);\n\t\t\tTwice(4);\n"),
					"base member with self, Self wired, static with and without qualifier: `Hit(1); this.Hit(2); Base.Twice(3); Twice(4);`");
				SourceDocument back = scope .();
				back.LoadFromText(doc.Text, "Calls.bf");
				let g = back.FindMethod("Enemy.Empty()").Graph;
				let h1 = FindCall(g, "Hit", "1");
				let h2 = FindCall(g, "Hit", "2");
				let t3 = FindCall(g, "Twice", "3");
				let t4 = FindCall(g, "Twice", "4");
				Check(h1 != null && h1.Binding == .Instance && g.FindLinkTo(h1.FindInput("target")) == null, "reads back: Hit(1) with an unconnected Target");
				Check(h2 != null && g.DataSource(h2.FindInput("target"))?.Kind == .This, "reads back: this.Hit(2) with Self wired");
				Check(t3 != null && t3.Binding == .Static && t3.Qualifier == "Base" && t4 != null && t4.Binding == .Static && t4.Qualifier == null,
					"reads back: Base.Twice(3) and Twice(4) as static calls");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						StringView[0] none = .();
						Chain(g, NodeFactory.MemberCall(g, "Mystery", "Nowhere", true, none, none, "void"));
					});
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(ok && doc.Text.Contains("\t\t\tMystery();\n") && g.Errors.IsEmpty, "owner type unknown to the resolver: no error, `Mystery();` written");
			}
			delete r;
			r = null;
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						StringView[0] none = .();
						Chain(g, NodeFactory.MemberCall(g, "TakeDamage", "Player", true, none, none, "void"));
					});
				Check(ok, "without a resolver, a foreign owner can't be judged: no error (the compiler is the judge)");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Spawn()", scope [&] (g) =>
					{
						StringView[0] none = .();
						let call = NodeFactory.MemberCall(g, "Ping", "Enemy", true, none, none, "void");
						g.Connect(call.Then, g.ExecTarget(g.Entry.Then).ExecIn);
						g.Connect(g.Entry.Then, call.ExecIn);
					});
				let g = doc.FindMethod("Enemy.Spawn()").Graph;
				Check(!ok && HasError(g, "Receiver must be an Enemy: this function is static, so there is no this."), "the static rule needs no resolver: \"Receiver must be an Enemy: ...\"");
			}
		}

		// ------------------------------------------------------------------ 3. inputs

		static void RunInputs()
		{
			Console.WriteLine("Calls 4: required inputs, ref arguments, wire types");
			Resolver r = scope .(cCalls);
			r.Use();
			{
				SourceDocument doc = scope .();
				Node call = null;
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) => { call = Hit(g); Chain(g, call); });
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(!ok && HasError(g, "'amount' needs a value: connect a wire or type one in.", call), "an empty argument: \"'amount' needs a value: connect a wire or type one in.\"");
			}
			StringView[1] totalName = .("total");
			StringView[1] intType = .("int");
			StringView[1] refMod = .("ref");
			{
				SourceDocument doc = scope .();
				Node call = null;
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						call = NodeFactory.MemberCall(g, "Fill", "Enemy", true, totalName, intType, "void", refMod);
						call.FindInput("arg0").Default.Set("5");
						Chain(g, call);
					});
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(!ok && HasError(g, "ref needs a variable: 'total' is passed by reference", call), "a literal into a ref parameter: \"ref needs a variable: ...\"");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let call = NodeFactory.MemberCall(g, "Fill", "Enemy", true, totalName, intType, "void", refMod);
						g.Connect(NodeFactory.Get(g, "mHp", "int").Result, call.FindInput("arg0"));
						let byText = NodeFactory.MemberCall(g, "Fill", "Enemy", true, totalName, intType, "void", refMod);
						byText.FindInput("arg0").Default.Set("mHp");
						Chain(g, call, byText);
					});
				Check(ok && doc.Text.Contains("\t\t\tFill(ref mHp);\n\t\t\tFill(ref mHp);\n"), "a variable wired or typed into ref: `Fill(ref mHp);`");
				SourceDocument back = scope .();
				back.LoadFromText(doc.Text, "Calls.bf");
				let fill = FindCall(back.FindMethod("Enemy.Empty()").Graph, "Fill");
				Check(fill != null && fill.FindInput("arg0").IsRefArg, "reads back as a ref input");
			}
			{
				SourceDocument doc = scope .();
				Node call = null;
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						call = Hit(g);
						g.Connect(NodeFactory.Get(g, "mFlag", "bool").Result, call.FindInput("arg0"));
						Chain(g, call);
					});
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(!ok && HasError(g, "'amount' takes int, but the wire brings bool", call), "a bool wired into an int: refused, \"'amount' takes int, but the wire brings bool: ...\"");
			}
			{
				SourceDocument doc = scope .();
				Node call = null;
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) => { call = Hit(g, "true"); Chain(g, call); });
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(!ok && HasError(g, "'amount' takes int, but holds true", call), "`true` typed into an int: refused");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) => { Chain(g, Hit(g, "300")); });
				Check(ok, "an integer constant into an int: fine");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let call = Hit(g);
						g.Connect(NodeFactory.Get(g, "mCount", "uint").Result, call.FindInput("arg0"));
						Chain(g, call);
					});
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(ok && HasWarning(g, "'amount' takes int, but the wire brings uint"), "a uint wired into an int: written, with a warning (sign and width of inferred types may be guesses)");
			}
		}

		// ------------------------------------------------------------------ 4. out pins read

		const String cInlineOut =
			"""
			using System;

			namespace Demo
			{
				class Newer
				{
					bool Find(out int n)
					{
						n = 1;
						return true;
					}

					void Use()
					{
						Find(out let a);
						Console.WriteLine(a);
					}

					void Assigned()
					{
						int v;
						Find(out v);
						v = 5;
						Console.WriteLine(v);
					}
				}
			}

			""";

		static void RunOutsRead()
		{
			Console.WriteLine("Calls 5: out and ref arguments read from code");
			Resolver r = new .(cCalls);
			SourceDocument doc = scope .();
			doc.LoadFromText(cCalls, "Calls.bf");
			let g = doc.FindMethod("Enemy.Outs()").Graph;
			let get1 = FindCall(g, "TryGet", "1");
			let v = get1?.FindOutput("arg1");
			Check(v != null && v.IsOutArg && v.Form == .Declared && v.OutName == "v" && v.OutDecl == "int", "`int v; TryGet(1, out v);`: an out pin (declared form), no Local Variable node");
			Check(FindNode(g, .LocalVar, "v") == null, "the `int v;` line folded into the pin");
			let write = FindCall(g, "WriteLine");
			Check(write != null && v != null && g.FindLinkTo(write.FindInput("arg0"))?.From == v, "`Console.WriteLine(v)` reads v through a wire from the out pin");
			let get2 = FindCall(g, "TryGet", "2");
			let w = get2?.FindOutput("arg1");
			Check(w != null && w.Form == .Inline && w.OutDecl == "var" && w.OutName == "w", "`TryGet(2, var w)`: an out pin declared inline");
			let hitW = FindCall(g, "Hit");
			Check(hitW != null && w != null && g.FindLinkTo(hitW.FindInput("arg0"))?.From == w, "`Hit(w)` in the if body is wired from it");
			let get3 = FindCall(g, "TryGet", "3");
			Check(get3?.FindOutput("arg1")?.Form == .Discard, "`TryGet(3, ?)`: a discarded out pin");
			let get4 = FindCall(g, "TryGet", "4");
			let hp = get4?.FindOutput("arg1");
			Check(hp != null && hp.Form == .Existing && hp.OutName == "mHp", "`out mHp` into a field: an out pin that writes mHp");
			let fill = FindCall(g, "Fill");
			Check(fill != null && fill.FindInput("arg0").IsRefArg && g.DataSource(fill.FindInput("arg0"))?.Text == "mHp", "`Fill(ref mHp)`: a ref input wired from mHp");
			let all = FindCall(g, "GetAll");
			let count = all?.FindOutput("arg0");
			Check(count != null && count.Form == .DeclaredRef && count.OutName == "count" && FindNode(g, .LocalVar, "count") == null,
				"`int count = default; GetAll(ref count);` on a [Pin(Out=true)] parameter: an output pin");
			CheckByteExact(cCalls, "out / ref arguments");

			delete r;
			r = null;
			SourceDocument newer = scope .();
			newer.LoadFromText(cInlineOut, "Newer.bf");
			let ng = newer.FindMethod("Newer.Use()").Graph;
			let a = FindCall(ng, "Find")?.FindOutput("arg0");
			Check(a != null && a.Form == .Inline && a.OutKeyword && a.OutDecl == "let" && a.OutName == "a", "`out let a` (newer syntax): an out pin, kept as written");
			let wa = FindCall(ng, "WriteLine");
			Check(wa != null && a != null && ng.FindLinkTo(wa.FindInput("arg0"))?.From == a, "`a` gets a value pin for downstream wires");
			let assigned = newer.FindMethod("Newer.Assigned()").Graph;
			let av = FindCall(assigned, "Find")?.FindOutput("arg0");
			Check(av != null && av.Form == .Existing && assigned.FindLocal("v") != null,
				"`int v; Find(out v); v = 5;`: assigned elsewhere, so the line stays a declaration (one of the function's Locals) and `out v` writes it");
			CheckByteExact(cInlineOut, "out let / assigned out variable");
		}

		// ------------------------------------------------------------------ 5. out pins written

		static void RunOutsWritten()
		{
			Console.WriteLine("Calls 6: out pins written by the generator");
			Resolver r = scope .(cCalls);
			r.Use();
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let call = TryGet(g, "4");
						let hit = Hit(g);
						g.Connect(call.FindOutput("arg1"), hit.FindInput("arg0"));
						Chain(g, call, hit);
					});
				Check(ok && doc.Text.Contains("\t\t\tTryGet(4, var value);\n\t\t\tHit(value);\n"), "a read out pin: `TryGet(4, var value); Hit(value);`");
				SourceDocument back = scope .();
				back.LoadFromText(doc.Text, "Calls.bf");
				let g = back.FindMethod("Enemy.Empty()").Graph;
				let p = FindCall(g, "TryGet")?.FindOutput("arg1");
				Check(p != null && p.Form == .Inline && g.FindLinkTo(FindCall(g, "Hit").FindInput("arg0"))?.From == p, "reads back as the out pin, wired to Hit");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) => { Chain(g, TryGet(g, "1")); });
				Check(ok && doc.Text.Contains("\t\t\tTryGet(1, ?);\n"), "nothing reads it: `TryGet(1, ?);`");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let b = NodeFactory.Branch(g);
						b.FindInput("condition").Default.Set("mFlag");
						let call = TryGet(g, "1");
						g.Connect(b.FindOutput("true"), call.ExecIn);
						let hit = Hit(g);
						g.Connect(call.FindOutput("arg1"), hit.FindInput("arg0"));
						Chain(g, b, hit);
					});
				Check(ok && doc.Text.Contains("\t\t\tint value = default;\n\t\t\tif (mFlag)\n\t\t\t{\n\t\t\t\tTryGet(1, out value);\n\t\t\t}\n\t\t\tHit(value);\n"),
					"read after the block: `int value = default;` hoisted before the if, `out value` at the call");
			}
			{
				SourceDocument doc = scope .();
				Node hit = null;
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let b = NodeFactory.Branch(g);
						b.FindInput("condition").Default.Set("mFlag");
						let call = TryGet(g, "1");
						g.Connect(b.FindOutput("true"), call.ExecIn);
						hit = Hit(g);
						g.Connect(b.FindOutput("false"), hit.ExecIn);
						g.Connect(call.FindOutput("arg1"), hit.FindInput("arg0"));
						Chain(g, b);
					});
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(!ok && HasError(g, "which has not run on this path", hit), "read in the other branch: refused on the reader");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let b = NodeFactory.Branch(g);
						b.FindInput("condition").Default.Set("mFlag");
						let call = TryGet(g, "1", true, "");
						g.Connect(b.FindOutput("true"), call.ExecIn);
						let hit = Hit(g);
						g.Connect(call.FindOutput("arg1"), hit.FindInput("arg0"));
						Chain(g, b, hit);
					});
				let g = doc.FindMethod("Enemy.Empty()").Graph;
				Check(!ok && HasError(g, "its type is unknown"), "read after the block with an unknown type: refused");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let loop = NodeFactory.Loop(g, .While);
						let call = TryGet(g, "1", false);
						g.Connect(call.Result, loop.FindInput("condition"));
						let hit = Hit(g);
						g.Connect(call.FindOutput("arg1"), hit.FindInput("arg0"));
						Chain(g, loop, hit);
					});
				Check(ok && doc.Text.Contains("\t\t\tint value;\n\t\t\twhile (TryGet(1, out value))\n"),
					"read after a while loop whose condition sets it: `int value;` before the loop (a `var` there would live in the loop only)");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let c1 = TryGet(g, "1");
						let c2 = TryGet(g, "2");
						let h1 = Hit(g);
						let h2 = Hit(g);
						g.Connect(c1.FindOutput("arg1"), h1.FindInput("arg0"));
						g.Connect(c2.FindOutput("arg1"), h2.FindInput("arg0"));
						Chain(g, c1, c2, h1, h2);
					});
				Check(ok && doc.Text.Contains("TryGet(1, var value);\n\t\t\tTryGet(2, var value2);\n\t\t\tHit(value);\n\t\t\tHit(value2);"), "two out variables get distinct names (value, value2)");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let pure = TryGet(g, "7", false);
						let hit = Hit(g);
						g.Connect(pure.FindOutput("arg1"), hit.FindInput("arg0"));
						Chain(g, hit);
					});
				Check(ok && doc.Text.Contains("\t\t\tTryGet(7, var value);\n\t\t\tHit(value);\n"), "a pure call read only through its out pin runs once, as a statement before the reader");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						let b = NodeFactory.Branch(g);
						let call = TryGet(g, "2", false);
						g.Connect(call.Result, b.FindInput("condition"));
						let hit = Hit(g);
						g.Connect(call.FindOutput("arg1"), hit.FindInput("arg0"));
						g.Connect(b.FindOutput("true"), hit.ExecIn);
						Chain(g, b);
					});
				Check(ok && doc.Text.Contains("\t\t\tif (TryGet(2, var value))\n\t\t\t{\n\t\t\t\tHit(value);\n"), "a pure call in a condition, its out pin read in the body: `if (TryGet(2, var value))`");
			}

			Console.WriteLine("Calls 7: [Pin(Out=true)] ref parameters");
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Enemy.Empty()", scope [&] (g) =>
					{
						StringView[1] names = .("count");
						StringView[1] types = .("int");
						StringView[1] mods = .("ref");
						bool[1] outRef = .(true);
						let call = NodeFactory.MemberCall(g, "GetAll", "Enemy", true, names, types, "void", mods, outRef);
						let hit = Hit(g);
						g.Connect(call.FindOutput("arg0"), hit.FindInput("arg0"));
						Chain(g, call, hit);
					});
				Check(ok && doc.Text.Contains("\t\t\tint count = default;\n\t\t\tGetAll(ref count);\n\t\t\tHit(count);\n"), "written as `int count = default; GetAll(ref count);`");
				SourceDocument back = scope .();
				back.LoadFromText(doc.Text, "Calls.bf");
				let g = back.FindMethod("Enemy.Empty()").Graph;
				let p = FindCall(g, "GetAll")?.FindOutput("arg0");
				Check(p != null && p.Form == .DeclaredRef && FindNode(g, .LocalVar) == null, "reads back as the same output pin");
			}
		}

		const String cOverloads =
			"""
			namespace Demo
			{
				class Picker
				{
					void Pick(int a, float b)
					{
					}

					void Pick(float a, int b)
					{
					}

					void Pick(int a, int b, int c)
					{
					}

					void Use()
					{
						Pick(1, 2);
						Pick(1, 2, 3);
					}
				}
			}

			""";

		static void RunMisc()
		{
			Console.WriteLine("Calls 8: ambiguous overloads, layout keys");
			{
				Resolver r = scope .(cOverloads);
				r.Use();
				SourceDocument doc = scope .();
				doc.LoadFromText(cOverloads, "Picker.bf");
				let mg = doc.FindMethod("Picker.Use()");
				let g = mg.Graph;
				Node two = null;
				Node three = null;
				for (let n in g.Nodes)
					if (n.Kind == .Call && n.Text == "Pick")
					{
						if (n.ArgCount == 2)
							two = n;
						else
							three = n;
					}
				Check(two != null && two.Ambiguous && three != null && !three.Ambiguous, "`Pick(1, 2)` fits Pick(int, float) and Pick(float, int) equally: marked ambiguous; `Pick(1, 2, 3)` is not");
				Check(doc.Commit(mg) && g.Warnings.IsEmpty, "code as read: no warning");
				two.Edited = true;
				Check(doc.Commit(doc.FindMethod("Picker.Use()")) && HasWarning(g, "Several overloads of 'Pick' fit these arguments equally well"),
					"edited: a warning on the node, and the commit still goes through");
			}
			{
				Graph g = scope .();
				let entry = g.AddNode(.Entry);
				g.Entry = entry;
				g.AddExecOut(entry, "then");
				StringView[1] names = .("format");
				StringView[1] types = .("String");
				let oldShape = NodeFactory.Call(g, "WriteLine", true, true, "Console", names, types, "void");
				let newShape = NodeFactory.StaticCall(g, "WriteLine", "Console", "Console", true, names, types, "void");
				Check(LayoutKeys.ContentHash(g, oldShape) == LayoutKeys.ContentHash(g, newShape),
					"a static call hashes like the old \"Console\"-in-the-Target shape, so saved positions still match exactly");
				let wired = NodeFactory.MemberCall(g, "Hit", "Base", true, default, default, "void");
				let get = NodeFactory.Get(g, "obj", "Base");
				get.Original = new String("obj");
				g.Connect(get.Result, wired.FindInput("target"));
				let textual = NodeFactory.Call(g, "Hit", true, true, "obj", default, default, "void");
				Check(LayoutKeys.ContentHash(g, wired) == LayoutKeys.ContentHash(g, textual), "`obj.Hit()` wired from obj hashes like the old text target");
			}
		}

		const String cResultNotes =
			"""
			namespace Demo
			{
				class String
				{
					public Result<void> AppendF(StringView format, int value)
					{
						return .Ok;
					}

					public Result<void> Set(StringView value)
					{
						return .Ok;
					}
				}

				class Host
				{
					public void Run(String text)
					{
						text.AppendF("{}", 1);
						text.Set("x");
					}
				}
			}

			""";

		/// The note on a call whose Result nothing reads: kept for a real failure (Set), not given
		/// to String.AppendF, whose Err only means a format string that does not match.
		static void RunResultNotes()
		{
			Console.WriteLine("calls: unread Result notes");
			Resolver r = scope .(cResultNotes);
			SourceDocument doc = scope .();
			doc.LoadFromText(cResultNotes, "Calls.bf");
			let mg = doc.FindMethod("Host.Run(String)");
			let g = mg.Graph;
			GraphValidator.Validate(g);
			let format = FindCall(g, "AppendF");
			let set = FindCall(g, "Set");
			Check(format != null && set != null && format.Result != null && format.Result.TypeName.StartsWith("Result<") && set.Result != null && set.Result.TypeName.StartsWith("Result<"), "AppendF and Set both return a Result<void>");
			Check(HasWarning(g, "'Set' returns a Result<void> that nothing reads"), "an unread Result<void> of Set keeps its note");
			Check(!HasWarning(g, "'AppendF'"), "String.AppendF has no note");
		}

		public static int Run()
		{
			sFailures = 0;
			sChecks = 0;
			RunResultNotes();
			RunShapes();
			RunTargets();
			RunInputs();
			RunOutsRead();
			RunOutsWritten();
			RunMisc();
			Console.WriteLine("call checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}
	}
}
