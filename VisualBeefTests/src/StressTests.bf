using System;
using System.Collections;
using System.IO;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;

namespace VisualBeef.Tests
{
	/// Undo / redo stress: random edits of every kind the Outline, Properties and the Sheet make
	/// (member variables, functions, properties, constructors, renames, signatures, types, initial
	/// values, Set on Create, deletes, a statement committed into a function graph), then undo all
	/// (the text is byte for byte the original, each step the text before that edit), redo all (the
	/// text after the last edit) and, after every step, the document's functions and graphs match a
	/// fresh read of its text (no desync). Run on crafted files (CRLF + tabs + Allman, K&R spaces,
	/// K&R CRLF, nested and generic types) and on any files given.
	///   stress [-seed N] [-edits N] [-v] [files or folders]...
	static class StressTests
	{
		static int sFailures;
		static int sChecks;
		static bool sVerbose;

		static void Check(bool ok, StringView name, StringView what)
		{
			sChecks++;
			if (ok)
			{
				if (sVerbose)
					Console.WriteLine("  ok   {}: {}", name, what);
				return;
			}
			sFailures++;
			Console.WriteLine("  FAIL {}: {}", name, what);
		}

		const String cAllmanTabs =
			"""
			using System;

			namespace Stress
			{
				class Player
				{
					int mHp = 10;
					String mName = new .("a") ~ delete _;
					public float Speed { get; set; } = 2.5f;

					public this()
					{
					}

					public void Hit(int damage)
					{
						if (damage > 0)
						{
							mHp -= damage;
						}
						else
						{
							Console.WriteLine("none");
						}
					}

					public int Get()
					{
						return mHp;
					}

					public void Shout()
					{
						mName.Append("!");
						Console.WriteLine(mName.Length);
					}

					class Inner
					{
						int mDepth = 1;

						public int Deeper()
						{
							return mDepth + 1;
						}
					}
				}

				class Box<T> where T : class
				{
					List<T> mItems = new .() ~ delete _;

					public int Count()
					{
						return mItems.Count;
					}
				}
			}
			""";

		const String cKandR =
			"""
			using System;

			namespace Stress {
			    class Enemy {
			        int mHp = 10;
			        bool mAlive = true;

			        public void Hit(int damage) {
			            if (damage > 0) {
			                mHp -= damage;
			            } else {
			                Console.WriteLine("none");
			            }
			        }

			        public int Get() {
			            for (int i = 0; i < 3; i++) {
			                mHp++;
			            }
			            return mHp;
			        }
			    }
			}
			""";

		static void Types(List<Member> members, List<Member> outTypes)
		{
			for (let m in members)
			{
				if (m.Kind == .Type && m.TypeKind != null && (m.TypeKind == "class" || m.TypeKind == "struct") && m.OpenBrace >= 0 && m.CloseBrace >= 0)
					outTypes.Add(m);
				if ((m.Kind == .Namespace || m.Kind == .Type) && m.Members != null)
					Types(m.Members, outTypes);
			}
		}

		static void MembersOf(Member type, MemberKind kind, List<Member> outMembers)
		{
			if (type.Members == null)
				return;
			for (let m in type.Members)
				if (m.Kind == kind && m.HasSpan && !m.IsCtor && !m.IsDtor)
					outMembers.Add(m);
		}

		/// The document's functions and their graphs are what a fresh read of its text gives.
		static bool InSync(SourceDocument doc, String outWhy)
		{
			SourceDocument fresh = scope .();
			fresh.LoadFromText(doc.Unit.Text);
			if (fresh.Methods.Count != doc.Methods.Count)
			{
				outWhy.AppendF("{} functions, a fresh read has {}", doc.Methods.Count, fresh.Methods.Count);
				return false;
			}
			for (int i < doc.Methods.Count)
			{
				let a = doc.Methods[i];
				let b = fresh.Methods[i];
				if (a.Key != b.Key)
				{
					outWhy.AppendF("function {} is {}, a fresh read says {}", i, a.Key, b.Key);
					return false;
				}
				if (a.Doc != doc)
				{
					outWhy.AppendF("{} belongs to another document", a.Key);
					return false;
				}
				if (!a.Graphable || !b.Graphable)
					continue;
				let ga = a.Graph;
				let gb = b.Graph;
				if ((ga == null) != (gb == null))
				{
					outWhy.AppendF("{}: graph {} vs {}", a.Key, ga != null, gb != null);
					return false;
				}
				if (ga != null && ga.Nodes.Count != gb.Nodes.Count)
				{
					outWhy.AppendF("{}: {} nodes, a fresh read has {}", a.Key, ga.Nodes.Count, gb.Nodes.Count);
					return false;
				}
			}
			return true;
		}

		/// One random edit. Returns a label of what it tried.
		static void Edit(SourceDocument doc, Random rnd, int step, String outLabel)
		{
			List<Member> types = scope .();
			Types(doc.Unit.Members, types);
			if (types.IsEmpty)
			{
				outLabel.Set("no type");
				return;
			}
			let type = types[rnd.Next((int32)types.Count)];
			List<Member> fields = scope .();
			MembersOf(type, .Field, fields);
			List<Member> methods = scope .();
			MembersOf(type, .Method, methods);
			String key = scope .();
			int op = rnd.Next(13);
			switch (op)
			{
			case 0:
				outLabel.AppendF("AddField {}.vbF{}", type.Name, step);
				doc.AddField(type, "int", scope $"vbF{step}");
			case 1:
				outLabel.AppendF("AddMethod {}.VbM{}", type.Name, step);
				doc.AddMethod(type, "void", scope $"VbM{step}", "", key);
			case 2, 3:
				// A statement committed into a function graph, the way the Sheet does it.
				List<String> keys = scope .();
				defer { ClearAndDeleteItems!(keys); }
				for (let mg in doc.Methods)
					if (mg.Graphable && !mg.IsBroken)
						keys.Add(new String(mg.Key));
				if (keys.IsEmpty)
				{
					outLabel.Set("no function");
					return;
				}
				let k = keys[rnd.Next((int32)keys.Count)];
				outLabel.AppendF("graph edit {}", k);
				let mg = doc.FindMethod(k);
				if (mg == null || mg.Graph == null || mg.Graph.ReadOnly || mg.Graph.Entry == null || mg.Graph.Entry.Then == null)
					return;
				doc.PushUndo();
				let g = mg.Graph;
				let first = g.ExecTarget(g.Entry.Then);
				let probe = NodeFactory.Code(g, scope $"int vbProbe{step} = {step};");
				g.Connect(g.Entry.Then, probe.ExecIn);
				if (first != null)
					g.Connect(probe.Then, first.ExecIn);
				if (!doc.Commit(mg))
					doc.Undo();
			case 4:
				if (fields.IsEmpty && methods.IsEmpty)
					return;
				let m = (methods.IsEmpty || (!fields.IsEmpty && rnd.Next(2) == 0)) ? fields[rnd.Next((int32)fields.Count)] : methods[rnd.Next((int32)methods.Count)];
				let newName = scope String();
				newName.AppendF("{}{}", (m.Kind == .Field) ? "mRen" : "Ren", step);
				outLabel.AppendF("RenameMember {} -> {}", m.Name, newName);
				doc.RenameMember(m, newName);
			case 5:
				if (methods.IsEmpty)
					return;
				let m = methods[rnd.Next((int32)methods.Count)];
				outLabel.AppendF("SetSignature {}", m.Name);
				String ret = scope .(m.TypeText ?? "void");
				doc.SetSignature(m, ret, scope $"int a{step}, float b{step}");
			case 6:
				if (fields.IsEmpty)
					return;
				let m = fields[rnd.Next((int32)fields.Count)];
				outLabel.AppendF("SetMemberType {}", m.Name);
				doc.SetMemberType(m, (rnd.Next(2) == 0) ? "float" : "int64");
			case 7:
				if (fields.IsEmpty && methods.IsEmpty)
					return;
				let m = (methods.IsEmpty || (!fields.IsEmpty && rnd.Next(2) == 0)) ? fields[rnd.Next((int32)fields.Count)] : methods[rnd.Next((int32)methods.Count)];
				outLabel.AppendF("DeleteMember {}", m.Name);
				doc.DeleteMember(m);
			case 8:
				if (fields.IsEmpty && methods.IsEmpty)
					return;
				let m = (methods.IsEmpty || (!fields.IsEmpty && rnd.Next(2) == 0)) ? fields[rnd.Next((int32)fields.Count)] : methods[rnd.Next((int32)methods.Count)];
				outLabel.AppendF("SetModifiers {}", m.Name);
				doc.SetModifiers(m, (rnd.Next(2) == 0) ? "public static" : "private");
			case 9:
				outLabel.AppendF("AddProperty {}.VbP{}", type.Name, step);
				doc.AddProperty(type, "int", scope $"VbP{step}", true, true, key);
			case 10:
				outLabel.AppendF("AddConstructor {}", type.Name);
				doc.AddConstructor(type, "public", scope $"int c{step}", "", key);
			case 11:
				if (fields.IsEmpty)
					return;
				let m = fields[rnd.Next((int32)fields.Count)];
				outLabel.AppendF("SetFieldInitializer {}", m.Name);
				doc.SetFieldInitializer(m, scope $"{step}");
			case 12:
				if (fields.IsEmpty)
					return;
				let m = fields[rnd.Next((int32)fields.Count)];
				outLabel.AppendF("SetFieldSetOnCreate {}", m.Name);
				doc.SetFieldSetOnCreate(type, m, rnd.Next(2) == 0);
			}
		}

		public static void RunText(StringView name, StringView text, int seed, int edits)
		{
			SourceDocument doc = scope .();
			doc.LoadFromText(text);
			for (let mg in doc.Methods)
				if (mg.Graphable && mg.Graph == null)
					Check(false, name, scope $"no graph for {mg.Key}");
			String why = scope .();
			Check(InSync(doc, why), name, scope $"loaded in sync {why}");

			Random rnd = scope .(seed);
			// texts[i] = the text before edit i; the last entry is the text after all edits.
			List<String> texts = scope .();
			List<String> labels = scope .();
			defer { ClearAndDeleteItems!(texts); ClearAndDeleteItems!(labels); }
			for (int step < edits)
			{
				String before = new .(doc.Unit.Text);
				String label = new .();
				Edit(doc, rnd, step, label);
				if (doc.Unit.Text == before)
				{
					delete before;
					delete label;
					continue;
				}
				texts.Add(before);
				labels.Add(label);
				why.Clear();
				if (!InSync(doc, why))
				{
					// One desync is enough to report: the rest of the run would repeat it.
					Check(false, name, scope $"after {label}: {why}");
					if (sVerbose)
						Console.WriteLine("--- before\n{}\n--- after\n{}", before, doc.Unit.Text);
					return;
				}
			}
			texts.Add(new String(doc.Unit.Text));
			String after = scope .(doc.Unit.Text);

			// Undo all: each step must land on the text before an edit, in reverse order.
			int expect = texts.Count - 2;
			int undos = 0;
			bool orderOk = true;
			while (doc.CanUndo && undos < 10000)
			{
				doc.Undo();
				undos++;
				if (expect >= 0 && doc.Unit.Text == texts[expect])
					expect--;
				else if (expect + 1 < texts.Count && doc.Unit.Text == texts[expect + 1])
				{
					// An edit that recorded two steps (no text change in one of them).
				}
				else if (orderOk)
				{
					orderOk = false;
					Check(false, name, scope $"undo {undos} gave a text that is not the one before {(expect >= 0 ? labels[expect] : "the first edit")}");
				}
				why.Clear();
				if (!InSync(doc, why))
				{
					Check(false, name, scope $"after undo {undos}: {why}");
					break;
				}
			}
			Check(doc.Unit.Text == text, name, scope $"{labels.Count} edits then {undos} undos: byte for byte the original");
			Check(orderOk && expect == -1, name, "every undo step is the text before its edit");

			int redos = 0;
			while (doc.CanRedo && redos < 10000)
			{
				doc.Redo();
				redos++;
				why.Clear();
				if (!InSync(doc, why))
				{
					Check(false, name, scope $"after redo {redos}: {why}");
					break;
				}
			}
			Check(doc.Unit.Text == after, name, scope $"{redos} redos: the text after the last edit");
		}

		static void CollectFiles(StringView path, List<String> outFiles)
		{
			if (File.Exists(path))
			{
				outFiles.Add(new String(path));
				return;
			}
			if (!Directory.Exists(path))
				return;
			for (let entry in Directory.EnumerateFiles(path))
			{
				String f = scope .();
				entry.GetFilePath(f);
				if (f.EndsWith(".bf", .OrdinalIgnoreCase))
					outFiles.Add(new String(f));
			}
			for (let entry in Directory.EnumerateDirectories(path))
			{
				String d = scope .();
				entry.GetFilePath(d);
				CollectFiles(d, outFiles);
			}
		}

		/// A function graph built before a member variable it reads is renamed or deleted (its
		/// body text unchanged) must be what a fresh read gives, not the stale kept graph.
		static void RunContext()
		{
			for (int pass < 2)
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cAllmanTabs);
				for (let mg in doc.Methods)
					if (mg.Graphable && mg.Graph == null)
						Check(false, "context", scope $"no graph for {mg.Key}");
				List<Member> types = scope .();
				Types(doc.Unit.Members, types);
				Member field = null;
				for (let m in types[0].Members)
					if (m.Kind == .Field && m.Name == "mName")
						field = m;
				if (pass == 0)
					doc.RenameMember(field, "mTitle");
				else
					doc.DeleteMember(field);
				String why = scope .();
				Check(InSync(doc, why), "context", scope $"{(pass == 0) ? "renaming" : "deleting"} mName leaves every graph (Player.Shout reads it) as a fresh read gives it {why}");
				doc.Undo();
				why.Clear();
				Check(InSync(doc, why) && doc.Unit.Text == cAllmanTabs, "context", scope $"undo: the original text and graphs {why}");
			}
		}

		public static int Run(String[] args)
		{
			sFailures = 0;
			sChecks = 0;
			sVerbose = false;
			int seed = 20261011;
			int edits = 50;
			List<String> files = scope .();
			defer { ClearAndDeleteItems!(files); }
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-v")
					sVerbose = true;
				else if (args[i] == "-seed" && i + 1 < args.Count)
				{
					if (int.Parse(args[++i]) case .Ok(let v))
						seed = v;
				}
				else if (args[i] == "-edits" && i + 1 < args.Count)
				{
					if (int.Parse(args[++i]) case .Ok(let n))
						edits = n;
				}
				else
					CollectFiles(args[i], files);
			}
			String crlf = scope .(cAllmanTabs);
			crlf.Replace("\n", "\r\n");
			String krCrlf = scope .(cKandR);
			krCrlf.Replace("\n", "\r\n");
			RunContext();
			for (int s < 4)
			{
				RunText("allman-tabs-lf", cAllmanTabs, seed + s, edits);
				RunText("allman-tabs-crlf", crlf, seed + 100 + s, edits);
				RunText("kandr-spaces-lf", cKandR, seed + 200 + s, edits);
				RunText("kandr-spaces-crlf", krCrlf, seed + 300 + s, edits);
			}
			for (let f in files)
			{
				String text = scope .();
				if (File.ReadAllText(f, text, true) case .Err)
				{
					Check(false, f, "cannot read");
					continue;
				}
				RunText(f, text, seed, edits);
			}
			Console.WriteLine("stress checks: {}  failures: {}", sChecks, sFailures);
			return (sFailures == 0) ? 0 : 1;
		}
	}
}
