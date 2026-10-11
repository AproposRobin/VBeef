using System;
using System.Collections;
using System.IO;
using System.Diagnostics;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Tests
{
	/// File-safety scenarios on real files in a scratch folder: viewing writes nothing, atomic
	/// saves with a backup, disk-change conflicts, read-only projects, dirty/undo, sidecar hygiene,
	/// and the create / rename / delete rules of the Project Browser (document layer only).
	static class SafetyTests
	{
		static int sFailures;
		const String cDir = "vb_safety_tmp";

		static void Check(bool cond, StringView what)
		{
			if (cond)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		const String cPlayer =
			"""
			using System;

			namespace Demo
			{
				class Player
				{
					public int mHealth = 100;

					public void TakeDamage(int amount)
					{
						mHealth -= amount;
						if (mHealth <= 0)
						{
							Die();
						}
					}

					public void Die()
					{
						Console.WriteLine("Player died");
					}
				}
			}

			""";

		static void Reset()
		{
			FileSafety.ReadOnlyProject = false;
			FileSafety.KeepBackup = true;
			if (Directory.Exists(cDir))
				Directory.DelTree(cDir).IgnoreError();
			Directory.CreateDirectory(cDir).IgnoreError();
		}

		static void Write(StringView path, StringView text)
		{
			File.WriteAllText(path, text).IgnoreError();
		}

		static String Read(StringView path)
		{
			String s = new .();
			File.ReadAllText(path, s, true).IgnoreError();
			return s;
		}

		static MethodGraph Method(SourceDocument doc, StringView key) => doc.FindMethod(key);

		static Member TypeOf(SourceDocument doc, StringView name)
		{
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		public static int Run()
		{
			sFailures = 0;
			Reset();
			defer
			{
				FileSafety.ReadOnlyProject = false;
				Directory.DelTree(cDir).IgnoreError();
			}

			Console.WriteLine("Safety 1: viewing a file writes nothing");
			{
				String path = scope $"{cDir}/Player.bf";
				Write(path, cPlayer);
				SourceDocument doc = scope .();
				Check(doc.Load(path) case .Ok, "loaded");
				// Opening every graph (what viewing does) auto-lays them out.
				for (let mg in doc.Methods)
					if (mg.Graphable)
						Check(mg.Graph != null, "graph built");
				doc.CaptureAllLayouts();
				doc.SaveLayout();
				Check(!File.Exists(scope $"{path}.vblayout"), "no .vblayout after viewing + SaveLayout");
				Check(doc.TrySave() == .Saved && !File.Exists(scope $"{path}.vblayout"), "saving an unchanged file creates no .vblayout");
				Check(!File.Exists(scope $"{path}.bak") , "no backup when nothing was overwritten with new content");
			}

			Console.WriteLine("Safety 2: atomic save, backup, sidecar on edit");
			{
				String path = scope $"{cDir}/Player.bf";
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				for (let mg in doc.Methods)
					if (mg.Graphable)
						Check(mg.Graph != null, "graph built");
				String newKey = scope .();
				doc.AddMethod(TypeOf(doc, "Player"), "void", "Heal", "int amount", newKey);
				Check(doc.Modified, "edit marks the document modified");
				Check(doc.TrySave() == .Saved, "saved");
				Check(!doc.Modified, "clean after save");
				String disk = Read(path);
				Check(disk.Contains("Heal") && disk == doc.Text, "file holds the edited text");
				Check(!File.Exists(scope $"{path}.tmp"), "no .tmp left behind");
				String bak = Read(scope $"{path}.bak");
				Check(bak == cPlayer, ".bak holds the previous content");
				Check(File.Exists(scope $"{path}.vblayout"), "sidecar written because an edit was saved");
				String side = Read(scope $"{path}.vblayout");
				Check(side.StartsWith("#vblayout\t2\n"), "sidecar carries a version line");
				delete disk; delete bak; delete side;

				// Never rewrite an unchanged sidecar.
				String sidePath = scope $"{path}.vblayout";
				DateTime t0 = default;
				if (File.GetLastWriteTime(sidePath) case .Ok(let t))
					t0 = t;
				System.Threading.Thread.Sleep(80);
				doc.LayoutTouched = true;
				doc.SaveLayout();
				DateTime t1 = default;
				if (File.GetLastWriteTime(sidePath) case .Ok(let t2))
					t1 = t2;
				Check(t0 == t1, "unchanged sidecar is not rewritten");

				// Backup can be switched off.
				FileSafety.KeepBackup = false;
				File.Delete(scope $"{path}.bak").IgnoreError();
				doc.AddField(TypeOf(doc, "Player"), "int", "mMana");
				doc.TrySave();
				Check(!File.Exists(scope $"{path}.bak"), "no .bak when backups are off");
				FileSafety.KeepBackup = true;
			}

			Console.WriteLine("Safety 3: a failed write leaves the original alone");
			{
				String path = scope $"{cDir}/Locked.bf";
				Write(path, cPlayer);
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				Directory.CreateDirectory(scope $"{path}.tmp").IgnoreError(); // blocks the temp file
				doc.AddField(TypeOf(doc, "Player"), "int", "mMana");
				Check(doc.TrySave() == .Failed, "save reports failure");
				String disk = Read(path);
				Check(disk == cPlayer, "original untouched");
				Check(doc.Modified, "still modified after a failed save");
				delete disk;
				Directory.Delete(scope $"{path}.tmp").IgnoreError();
			}

			Console.WriteLine("Safety 4: disk change is a conflict, not a silent overwrite");
			{
				String path = scope $"{cDir}/Conflict.bf";
				Write(path, cPlayer);
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				doc.AddField(TypeOf(doc, "Player"), "int", "mMana");
				String external = scope .(cPlayer);
				external.Replace("100", "250");
				Write(path, external);
				Check(doc.DiskChanged(), "change detected");
				Check(doc.TrySave() == .Conflict, "save refused");
				String disk = Read(path);
				Check(disk == external, "external version still on disk");
				delete disk;
				Check(doc.Modified, "edits kept in memory");
				Check(doc.TrySave(true) == .Saved, "Overwrite saves");
				String bak = Read(scope $"{path}.bak");
				Check(bak == external, "the overwritten external version is in the .bak");
				delete bak;
				Check(!doc.DiskChanged(), "no conflict after the overwrite");

				// A touch with identical content is not a conflict.
				SourceDocument d2 = scope .();
				d2.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				String same = Read(path);
				Write(path, same);
				delete same;
				Check(!d2.DiskChanged(), "same content rewritten is not a conflict");
			}

			Console.WriteLine("Safety 5: read-only project refuses every write");
			{
				String path = scope $"{cDir}/Ro.bf";
				Write(path, cPlayer);
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				doc.AddField(TypeOf(doc, "Player"), "int", "mMana");
				FileSafety.ReadOnlyProject = true;
				Check(doc.TrySave() == .ReadOnly, "save refused");
				String disk = Read(path);
				Check(disk == cPlayer, "file untouched");
				delete disk;
				doc.LayoutTouched = true;
				doc.SaveLayout();
				Check(!File.Exists(scope $"{path}.vblayout"), "no sidecar");
				String err = scope .();
				Check(AssetOps.CreateTextFile(scope $"{cDir}/New.bf", "x", err) case .Err && !File.Exists(scope $"{cDir}/New.bf"), "create refused");
				Check(AssetOps.CreateFolder(scope $"{cDir}/NewDir", scope String()) case .Err && !Directory.Exists(scope $"{cDir}/NewDir"), "folder creation refused");
				Check(AssetOps.Delete(path, false, scope String()) case .Err && File.Exists(path), "delete refused");
				Check(AssetOps.MovePath(path, scope $"{cDir}/Ro2.bf", false, scope String()) case .Err && File.Exists(path), "rename refused");
				FileSafety.ReadOnlyProject = false;
				Check(doc.TrySave() == .Saved, "works again once editable");
			}

			Console.WriteLine("Safety 6: dirty tracking follows the saved text");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cPlayer, "Mem.bf");
				Check(!doc.Modified, "clean on load");
				doc.AddField(TypeOf(doc, "Player"), "int", "mMana");
				Check(doc.Modified, "dirty after an edit");
				doc.Undo();
				Check(!doc.Modified && doc.Text == cPlayer, "undo back to the saved text clears dirty");
				doc.Redo();
				Check(doc.Modified, "redo is dirty again");
				// Typing the same text again is not an edit.
				doc.ApplyText(doc.Text);
				doc.Undo();
				doc.ApplyText(cPlayer);
				Check(!doc.Modified, "applying identical text keeps it clean");
			}

			Console.WriteLine("Safety 7: node moves are undoable");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cPlayer, "Mem.bf");
				let g = Method(doc, "Player.TakeDamage(int)").Graph;
				let node = g.Entry;
				float x0 = node.X;
				float y0 = node.Y;
				doc.PushUndo(); // one step per drag
				node.X = x0 + 160;
				node.Y = y0 + 48;
				doc.Undo();
				let g2 = Method(doc, "Player.TakeDamage(int)").Graph;
				Check(g2.Entry.X == x0 && g2.Entry.Y == y0, "undo restores the node position");
				Check(!doc.Modified, "a move never marks the source dirty");
				doc.Redo();
				let g3 = Method(doc, "Player.TakeDamage(int)").Graph;
				Check(g3.Entry.X == x0 + 160, "redo re-applies the move");
			}

			Console.WriteLine("Safety 8: comment boxes are undoable");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cPlayer, "Mem.bf");
				let c = new GraphComment();
				c.MethodKey.Set("Player.Die()");
				c.W = 200; c.H = 100;
				c.Text.Set("before");
				doc.Comments.Add(c);
				doc.PushUndo();
				c.Text.Set("after");
				c.X = 64;
				doc.Undo();
				Check(doc.Comments.Count == 1 && doc.Comments[0].Text == "before" && doc.Comments[0].X == 0, "undo restores comment text and position");
				doc.Redo();
				Check(doc.Comments.Count == 1 && doc.Comments[0].Text == "after", "redo restores the edited comment");
			}

			Console.WriteLine("Safety 9: sidecar hygiene (version, prune, tolerance)");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cPlayer, "Mem.bf");
				Check(Method(doc, "Player.Die()").Graph != null, "graph built");
				doc.CaptureAllLayouts();
				NodePos p;
				p.X = 5; p.Y = 5;
				doc.Layout[new String("Player.Die()|ghostnode")] = p;
				doc.Layout[new String("Gone.Method()|n1")] = p;
				String text = scope .();
				doc.GetLayoutText(text);
				Check(!text.Contains("ghostnode"), "stale node of a built method is pruned");
				Check(text.Contains("Gone.Method()|n1"), "entries of unknown methods survive an autosave");
				Check(text.StartsWith("#vblayout\t2\n"), "version line first");

				// Method-level prune happens when an edit is saved.
				String path = scope $"{cDir}/Prune.bf";
				Write(path, cPlayer);
				SourceDocument d2 = scope .();
				d2.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				d2.Layout[new String("Gone.Method()|n1")] = p;
				d2.Methods[0].Graph.Entry.X = 48;
				d2.AddField(TypeOf(d2, "Player"), "int", "mMana");
				d2.TrySave();
				String side = Read(scope $"{path}.vblayout");
				Check(!side.Contains("Gone.Method()") && side.Contains("Player."), "saving an edit prunes methods that no longer exist");
				delete side;

				// Tolerance: no version / extra fields / newer version.
				SourceDocument d3 = scope .();
				d3.LoadFromText(cPlayer, "Mem.bf", "Player.Die()|entry\t10\t20\textra\thash123\n");
				Check(d3.LayoutFileVersion == 0 && d3.Layout.Count == 1, "unversioned file with extra fields loads");
				SourceDocument d4 = scope .();
				d4.LoadFromText(cPlayer, "Mem.bf", "#vblayout\t99\nPlayer.Die()|entry\t10\t20\n");
				Check(d4.LayoutFileVersion == 99 && d4.Layout.Count == 1, "newer version is read");
				String newer = scope $"{cDir}/Newer.bf";
				Write(newer, cPlayer);
				Write(scope $"{newer}.vblayout", "#vblayout\t99\nPlayer.Die()|entry\t10\t20\n");
				SourceDocument d5 = scope .();
				d5.Load(newer).IgnoreError(); // setup: the assertions below catch a failed load
				d5.LayoutTouched = true;
				d5.AddField(TypeOf(d5, "Player"), "int", "mMana");
				d5.TrySave();
				String kept = Read(scope $"{newer}.vblayout");
				Check(kept.StartsWith("#vblayout\t99"), "a newer-format sidecar is left alone");
				delete kept;
				// The same after an undo: the snapshot does not hold the file's version, so it must survive.
				Write(newer, cPlayer);
				Write(scope $"{newer}.vblayout", "#vblayout\t99\n#future\tkeep me\nPlayer.Die()|entry\t10\t20\n");
				SourceDocument d6 = scope .();
				d6.Load(newer).IgnoreError(); // setup: the assertions below catch a failed load
				d6.AddField(TypeOf(d6, "Player"), "int", "mMana");
				d6.Undo();
				Check(d6.LayoutFileVersion == 99 && d6.LayoutUnknown.Count == 1, "undo keeps the sidecar's version and unknown lines");
				d6.AddField(TypeOf(d6, "Player"), "int", "mMana");
				d6.Undo();
				d6.LayoutTouched = true;
				d6.TrySave(true);
				String kept2 = Read(scope $"{newer}.vblayout");
				Check(kept2.StartsWith("#vblayout\t99") && kept2.Contains("#future"), "a newer-format sidecar is left alone after an edit and its undo");
				delete kept2;
			}

			// A layout side file that cannot be written is reported, not dropped in silence.
			{
				String path = scope $"{cDir}/LayoutRo.bf";
				Write(path, cPlayer);
				String side = scope $"{path}.vblayout";
				Write(side, "#vblayout\t2\nPlayer.Die()|entry\t10\t20\n");
				SourceDocument d = scope .();
				d.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				File.SetAttributes(side, .ReadOnly).IgnoreError();
				d.Methods[0].Graph.Entry.X = 480;
				d.LayoutTouched = true;
				d.SaveLayout();
				Check(!d.LayoutError.IsEmpty, "a read-only layout side file: the failure is kept for the editor to report");
				File.SetAttributes(side, .Normal).IgnoreError();
				d.LayoutTouched = true;
				d.SaveLayout();
				Check(d.LayoutError.IsEmpty, "writable again: the error clears");
			}

			// Save As to a place that cannot be written: the document stays on its file.
			{
				String path = scope $"{cDir}/SaveAsFail.bf";
				Write(path, cPlayer);
				SourceDocument d = scope .();
				d.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				String bad = scope $"{cDir}/no such folder/deeper/X.bf";
				Check(d.SaveAs(bad) case .Err, "Save As into a missing folder fails");
				Check(d.FilePath == path && d.HasDiskStamp, "after a failed Save As the document is still on its own file, stamped");
			}

			Console.WriteLine("Safety 10: where new files go, and name uniqueness per namespace");
			{
				String root = scope $"{cDir}/ws";
				Directory.CreateDirectory(scope $"{root}/ProjA/src/Sub").IgnoreError();
				Directory.CreateDirectory(scope $"{root}/ProjA/assets").IgnoreError();
				Directory.CreateDirectory(scope $"{root}/Loose").IgnoreError();
				Write(scope $"{root}/ProjA/BeefProj.toml", "FileVersion = 1\n[Project]\nName = \"ProjA\"\n");
				String outF = scope .();
				String proj = scope .();
				Check(AssetOps.ResolveSourceFolder(scope $"{root}/ProjA/src/Sub", outF, proj) == .InSource, "folder inside src is used as is");
				outF.Clear();
				Check(AssetOps.ResolveSourceFolder(scope $"{root}/ProjA", outF, proj) == .Redirected && outF.EndsWith("ProjA/src"), "project root redirects to its src");
				outF.Clear();
				Check(AssetOps.ResolveSourceFolder(scope $"{root}/ProjA/assets", outF, proj) == .Redirected && outF.EndsWith("ProjA/src"), "non-source subfolder redirects to src");
				outF.Clear();
				Check(AssetOps.ResolveSourceFolder(scope $"{root}/Loose", outF, proj) == .NoProject, "folder outside any project is flagged");

				// Regression: walking a remembered folder upward hits a drive root, where Path.GetDirectoryPath is .Err.
				// Discarding that Result is a fatal error in Beef; the walk must stop instead.
				{
					String par = scope .();
					Check(AssetOps.TryGetParent(scope $"{root}/ProjA/src", par) && par.EndsWith("ProjA"), "a normal folder has a parent");
#if BF_PLATFORM_WINDOWS
					for (let rootPath in StringView[?]("C:/", "C:\\", "C:", "/", "", "Z:/", "//server"))
#else
					for (let rootPath in StringView[?]("/", ""))
#endif
					{
						par.Set("junk");
						Check(!AssetOps.TryGetParent(rootPath, par) && par.IsEmpty, scope $"no parent at root '{rootPath}'");
					}
					// A full upward walk from a deep folder terminates at the root without crashing.
					String walk = scope $"{root}/ProjA/src/Sub";
					int steps = 0;
					while (steps < 64 && AssetOps.TryGetParent(walk, par))
					{
						walk.Set(par);
						steps++;
					}
					Check(steps > 0 && steps < 64, "upward walk reaches a root and stops");
					String found = scope .();
					AssetOps.FindProjectDir("Z:/no/such/place", found);
					Check(found.IsEmpty, "project lookup under a missing drive returns empty");
				}

				Write(scope $"{root}/ProjA/src/A.bf", "namespace One\n{\n\tclass Player\n\t{\n\t}\n}\n");
				Write(scope $"{root}/ProjA/src/Sub/B.bf", "namespace Two.Inner\n{\n\tclass Enemy\n\t{\n\t}\n}\n");
				ProjectIndex index = scope .();
				index.Build(root);
				String declFile = scope .();
				Check(AssetOps.TypeNameTaken(index, "One", "Player", declFile), "Player is taken in namespace One");
				Check(!AssetOps.TypeNameTaken(index, "Two", "Player", declFile), "Player is free in namespace Two");
				Check(AssetOps.TypeNameTaken(index, "Two.Inner", "Enemy", declFile), "dotted namespaces compare whole");
				Check(!AssetOps.TypeNameTaken(index, "Two", "Enemy", declFile), "a parent namespace is a different namespace");

				String err = scope .();
				String file = scope $"{root}/ProjA/src/New.bf";
				Check(AssetOps.CreateTextFile(file, "namespace One\n{\n}\n", err) case .Ok && File.Exists(file), "new file created");
				err.Clear();
				Check(AssetOps.CreateTextFile(file, "other", err) case .Err && err.Contains("already exists"), "creating over an existing file is refused with a message");
				String disk = Read(file);
				Check(disk.StartsWith("namespace One"), "existing file untouched");
				delete disk;
				err.Clear();
				Check(AssetOps.CreateFolder(scope $"{root}/ProjA/src/Sub", err) case .Err && !err.IsEmpty, "existing folder is refused with a message");
				// A src folder that does not exist yet is created along with the file.
				err.Clear();
				Check(AssetOps.CreateTextFile(scope $"{root}/Loose/src/X.bf", "x", err) case .Ok && File.Exists(scope $"{root}/Loose/src/X.bf"), "missing parent folders are created");
			}

			Console.WriteLine("Safety 11: rename / delete write only their own change");
			{
				String path = scope $"{cDir}/Hero.bf";
				Write(path, cPlayer);
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				String err = scope .();
				doc.AddField(TypeOf(doc, "Player"), "int", "mMana"); // an unrelated unsaved edit
				Check(AssetOps.RenameTypeAndSave(doc, "Player", "Hero", err) case .Err && err.Contains("unsaved"), "rename refused while the file has other unsaved edits");
				String disk = Read(path);
				Check(disk == cPlayer, "nothing was written");
				delete disk;
				Check(AssetOps.DeleteTypeAndSave(doc, "Player", scope String()) case .Err, "delete of a type refused the same way");

				SourceDocument clean = scope .();
				clean.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				err.Clear();
				Check(AssetOps.RenameTypeAndSave(clean, "Player", "Hero", err) case .Ok, "rename of a clean file works");
				disk = Read(path);
				String expected = scope .(cPlayer);
				expected.Replace("class Player", "class Hero");
				Check(disk == expected, "the file differs from the original only by the rename");
				delete disk;
				Check(!clean.Modified, "document is clean after the rename");

				// A conflicting disk change rolls the rename back.
				SourceDocument stale = scope .();
				stale.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				String changed = scope .(expected);
				changed.Replace("100", "7");
				Write(path, changed);
				err.Clear();
				Check(AssetOps.RenameTypeAndSave(stale, "Hero", "Zed", err) case .Err, "rename refused when the file changed on disk");
				disk = Read(path);
				Check(disk == changed, "disk version preserved");
				delete disk;
				Check(stale.Text == expected, "document rolled back");
			}

			Console.WriteLine("Safety 12: delete goes to the Recycle Bin (the freedesktop Trash on Linux) or does nothing");
			{
#if !BF_PLATFORM_WINDOWS
				// The home trash moves into the scratch folder: the user's own Trash is not touched.
				String oldData = scope .();
				Environment.GetEnvironmentVariable("XDG_DATA_HOME", oldData).IgnoreError(); // unset: restored as empty, which counts as unset
				String dataHome = scope .();
				Path.GetFullPath(scope $"{cDir}/data", dataHome);
				Directory.CreateDirectory(dataHome).IgnoreError(); // checked through the trash checks below
				Environment.SetEnvironmentVariable("XDG_DATA_HOME", dataHome).IgnoreError(); // same
				String trash = scope $"{dataHome}/Trash";
				String homeTrash = scope .();
				FreedesktopTrash.HomeTrash(homeTrash);
				// Never the user's own Trash: stop here when the override did not take.
				let trashOverridden = homeTrash == trash;
				Check(trashOverridden, scope $"XDG_DATA_HOME moves the home trash: {homeTrash}");
				if (!trashOverridden)
				{
					Console.WriteLine("safety: failures={} (stopped before deleting anything)", sFailures);
					return sFailures;
				}
#endif
				String path = scope $"{cDir}/Trash.bf";
				Write(path, cPlayer);
				Write(scope $"{path}.vblayout", "#vblayout\t1\n");
				String err = scope .();
				Check(AssetOps.Delete(path, false, err) case .Ok, scope $"moved to the {FileSafety.TrashName}");
				Check(!File.Exists(path) && !File.Exists(scope $"{path}.vblayout"), "file and side file are gone from the folder");
#if !BF_PLATFORM_WINDOWS
				{
					String full = scope .();
					Path.GetFullPath(path, full);
					String moved = Read(scope $"{trash}/files/Trash.bf");
					Check(moved != null && moved == cPlayer, "the file is in Trash/files with its content");
					delete moved;
					Check(File.Exists(scope $"{trash}/files/Trash.bf.vblayout") && File.Exists(scope $"{trash}/info/Trash.bf.vblayout.trashinfo"), "the side file is trashed too");
					String info = Read(scope $"{trash}/info/Trash.bf.trashinfo");
					String encoded = scope .();
					FreedesktopTrash.EncodePath(full, encoded);
					Check(info != null && info.StartsWith("[Trash Info]\nPath=") && info.Contains(scope $"Path={encoded}\n") && info.Contains("\nDeletionDate=2"),
						scope $"Trash/info/Trash.bf.trashinfo: [Trash Info], the absolute Path, a DeletionDate");
					delete info;

					// The same name again gets Trash.bf.2; a name with a space and '%' is percent-encoded.
					Write(path, "second");
					String as2 = scope .();
					err.Clear();
					Check(FreedesktopTrash.Move(path, err, as2) case .Ok && as2.EndsWith("/files/Trash.bf.2") && File.Exists(scope $"{trash}/info/Trash.bf.2.trashinfo"), scope $"the same name again: {as2}");
					String odd = scope $"{cDir}/My 100% file.bf";
					Write(odd, "x");
					err.Clear();
					Check(FreedesktopTrash.Move(odd, err) case .Ok, "a name with a space and %");
					String oddInfo = Read(scope $"{trash}/info/My 100% file.bf.trashinfo");
					Check(oddInfo != null && oddInfo.Contains("/My%20100%25%20file.bf\n"), "Path= is percent-encoded");
					delete oddInfo;
				}
#endif
				err.Clear();
				Check(AssetOps.Delete(scope $"{cDir}/Missing.bf", false, err) case .Err && !err.IsEmpty, "a path that can't be recycled reports and deletes nothing");

				String folder = scope $"{cDir}/Dir";
				Directory.CreateDirectory(folder).IgnoreError();
				Write(scope $"{folder}/a.bf", "x");
				err.Clear();
				Check(AssetOps.Delete(folder, true, err) case .Ok && !Directory.Exists(folder), "folder recycled");
#if !BF_PLATFORM_WINDOWS
				Check(File.Exists(scope $"{trash}/files/Dir/a.bf") && File.Exists(scope $"{trash}/info/Dir.trashinfo"), "the folder is in Trash/files with its files");

				// No trash can be made: nothing is deleted.
				String keep = scope $"{cDir}/Keep.bf";
				Write(keep, "keep");
				Environment.SetEnvironmentVariable("XDG_DATA_HOME", "/proc/vb-no-trash").IgnoreError(); // checked by the result
				err.Clear();
				let refused = FreedesktopTrash.Move(keep, err) case .Err;
				Environment.SetEnvironmentVariable("XDG_DATA_HOME", dataHome).IgnoreError(); // same
				// /proc is another file system than the scratch folder, so this falls through to the
				// scratch folder's mount top, which a test may or may not be allowed to write.
				Check(refused ? (File.Exists(keep) && err.Contains("nothing was deleted")) : !File.Exists(keep), scope $"a home trash that can't be made: the mount's own trash or nothing ({(refused ? "refused" : "mount trash")})");

				// Another file system (tmpfs /dev/shm): the trash on that mount, Path relative to it.
				if (Directory.Exists("/dev/shm"))
				{
					String shm = scope $"/dev/shm/vb-trash-test-{getpid()}";
					Directory.CreateDirectory(shm).IgnoreError(); // checked by the Move result
					String f = scope $"{shm}/Other.bf";
					Write(f, "other");
					String asShm = scope .();
					err.Clear();
					let r = FreedesktopTrash.Move(f, err, asShm);
					let uid = scope $".Trash-{getuid()}";
					Check(r case .Ok && !File.Exists(f) && asShm.StartsWith(scope $"/dev/shm/{uid}/files/"), scope $"another file system: the mount's own trash ({asShm}{err})");
					String shmInfo = Read(scope $"/dev/shm/{uid}/info/Other.bf.trashinfo");
					Check(shmInfo != null && shmInfo.Contains(scope $"\nPath=vb-trash-test-{getpid()}/Other.bf\n"), "its Path= is relative to the mount top");
					delete shmInfo;
					File.Delete(scope $"/dev/shm/{uid}/files/Other.bf").IgnoreError(); // test cleanup (only what this test made)
					File.Delete(scope $"/dev/shm/{uid}/info/Other.bf.trashinfo").IgnoreError(); // test cleanup
					Directory.Delete(shm).IgnoreError(); // test cleanup
					for (let sub in StringView[2]("files", "info"))
						Directory.Delete(scope $"/dev/shm/{uid}/{sub}").IgnoreError(); // only when empty: another program's trashed files stay
					Directory.Delete(scope $"/dev/shm/{uid}").IgnoreError(); // same
				}
				Environment.SetEnvironmentVariable("XDG_DATA_HOME", oldData).IgnoreError(); // best effort: the process ends after the suites
#endif
			}

			Console.WriteLine("Safety 13: a graph with errors is not saved");
			{
				String path = scope $"{cDir}/Errors.bf";
				Write(path, cPlayer);
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				let mg = Method(doc, "Player.Die()");
				let g = mg.Graph;
				doc.PushUndo();
				StringView[1] names = .("amount");
				StringView[1] types = .("int");
				// TakeDamage(int) needs its argument: left empty, GraphValidator refuses it.
				let call = NodeFactory.MemberCall(g, "TakeDamage", "Player", true, names, types, "void");
				g.Connect(call.Then, g.ExecTarget(g.Entry.Then).ExecIn);
				g.Connect(g.Entry.Then, call.ExecIn);
				Check(!doc.Commit(mg) && !g.Errors.IsEmpty, "the commit is refused with an error on the node");
				String before = Read(path);
				Check(doc.TrySave() == .GraphErrors && doc.LastError.Contains("needs a value"), "saving is refused and says why");
				String after = Read(path);
				Check(before == after, "nothing was written");
				delete before;
				delete after;
				call.FindInput("arg0").Default.Set("1");
				Check(doc.Commit(Method(doc, "Player.Die()")), "fixing the node commits");
				Check(doc.TrySave() == .Saved, "then it saves");
				String saved = Read(path);
				Check(saved.Contains("\t\t\tTakeDamage(1);\n"), "with the call in the file");
				delete saved;
			}

			Console.WriteLine("Safety 14: a read-only file and a folder that refuses writes");
			{
				String path = scope $"{cDir}/ReadOnlyAttr.bf";
				Write(path, cPlayer);
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				File.SetAttributes(path, .ReadOnly).IgnoreError();
				doc.AddField(TypeOf(doc, "Player"), "int", "mMana");
				Check(doc.TrySave() == .Failed && !doc.LastError.IsEmpty, scope $"saving over a read-only file fails and says why ({doc.LastError})");
				String disk = Read(path);
				Check(disk == cPlayer && doc.Modified, "the file is untouched and the edit is kept, unsaved");
				delete disk;
				// The layout side file cannot be written next to it either way: no crash, no change.
				doc.LayoutTouched = true;
				doc.SaveLayout();
				File.SetAttributes(path, .Normal).IgnoreError();
				Check(doc.TrySave() == .Saved, "once writable again, it saves");

				// A folder whose ACL denies writing (icacls), like a protected install folder.
				String folder = scope $"{cDir}/denied";
				Directory.CreateDirectory(folder).IgnoreError();
				String inFolder = scope $"{folder}/Player.bf";
				Write(inFolder, cPlayer);
				SourceDocument doc2 = scope .();
				doc2.Load(inFolder).IgnoreError();
				String user = scope .();
				Environment.GetEnvironmentVariable("USERNAME", user).IgnoreError();
				String full = scope .();
				Path.GetFullPath(folder, full);
				bool denied = RunIcacls(scope $"\"{full}\" /deny \"{user}\":(OI)(CI)(W,D,DC)");
				doc2.AddField(TypeOf(doc2, "Player"), "int", "mMana");
				let outcome = doc2.TrySave();
				// (read after the ACL is lifted: the deny also blocks how the test reads it)
				RunIcacls(scope $"\"{full}\" /remove:d \"{user}\" /T");
				String disk2 = Read(inFolder);
				if (denied)
				{
					Check(outcome == .Failed && !doc2.LastError.IsEmpty, scope $"saving into a folder that denies writes fails and says why ({doc2.LastError})");
					Check(disk2 == cPlayer && doc2.Modified, scope $"the file in it is untouched and the edit is kept (read {disk2.Length} of {cPlayer.Length} chars, modified {doc2.Modified})");
				}
				else
					Console.WriteLine("  (icacls not available: the denied-folder check was skipped)");
				delete disk2;
				Check(doc2.TrySave() == .Saved, "after the ACL is removed, it saves");
			}

			Console.WriteLine("Safety 15: a file locked by another program");
			{
				String path = scope $"{cDir}/LockedOpen.bf";
				Write(path, cPlayer);
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				doc.AddField(TypeOf(doc, "Player"), "int", "mMana");
				{
					FileStream lockStream = scope .();
					bool locked = lockStream.Open(path, .Open, .ReadWrite, .None) case .Ok;
					Check(locked, "another handle holds the file with no sharing");
#if BF_PLATFORM_WINDOWS
					Check(doc.TrySave() == .Failed && !doc.LastError.IsEmpty, scope $"saving while it is locked fails and says why ({doc.LastError})");
					Check(doc.Modified, "the edit is kept, unsaved");
#endif
					doc.LayoutTouched = true;
					doc.SaveLayout(); // the side file is a different file: written or not, no crash
					lockStream.Close();
				}
#if BF_PLATFORM_WINDOWS
				String disk = Read(path);
				Check(disk == cPlayer, "the locked file was not changed");
				delete disk;
#endif
				Check(doc.TrySave() == .Saved, "after the lock is released, it saves");
				String saved = Read(path);
				Check(saved.Contains("mMana"), "with the edit");
				delete saved;
				String backup = scope $"{path}.bak";
				Check(!File.Exists(scope $"{path}.tmp"), "no temp file is left behind");
				Check(File.Exists(backup), "the backup was made by the successful save");
			}


			Console.WriteLine("Safety 16: layouts saved before the vocabulary pass still match");
			{
				// A saved position is keyed `path#hash`; the hash covers the node kind's number, the
				// text and the pin ids, never a title or label. These strings are the pre-rename
				// shapes, so a sidecar written then matches the same nodes now.
				Check((int)NodeKind.Call == 1 && (int)NodeKind.This == 21 && (int)NodeKind.Base == 22, "node kind numbers unchanged (This was Self at 21, Base 22)");
				const String text =
					"""
					using System;

					namespace Demo
					{
						class Player
						{
							public void Hit(int amount) { }
							public void Run()
							{
								this.Hit(2);
								Hit(3);
							}
						}
					}

					""";
				SourceDocument doc = scope .();
				doc.LoadFromText(text, "Player.bf");
				let mg = doc.FindMethod("Player.Run()");
				Graph g = mg.Graph;
				bool sawThis = false;
				bool sawPlain = false;
				for (let n in g.Nodes)
				{
					if (n.Kind != .Call || n.Text != "Hit")
						continue;
					let t = n.FindInput("target");
					let linked = g.FindLinkTo(t) != null;
					String legacy = scope $"1|Hit||0000|target={(linked ? "this" : "")};arg0={(linked ? "2" : "3")};";
					Check(LayoutKeys.ContentHash(g, n) == LayoutKeys.Fnv(legacy), scope $"`{(linked ? "this.Hit(2)" : "Hit(3)")}` keeps its pre-rename content hash");
					if (linked) sawThis = true; else sawPlain = true;
				}
				Check(sawThis && sawPlain, "both calls found");
				// The pin shows "Receiver", its id stays "target".
				for (let n in g.Nodes)
					if (n.Kind == .Call)
					{
						let t = n.FindInput("target");
						Check(t != null && t.Label == "Receiver", "the pin id is `target`, its label is `Receiver`");
						break;
					}
			}

			Console.WriteLine("Safety 17: compile status from the last compile record and a source hash");
			{
				String ws = scope $"{cDir}/Ws";
				Directory.CreateDirectory(scope $"{ws}/src").IgnoreError();
				Write(scope $"{ws}/BeefSpace.toml", "FileVersion = 1\n");
				Write(scope $"{ws}/src/A.bf", cPlayer);
				uint64 h0 = CompileRecord.HashWorkspace(ws);
				Check(h0 == CompileRecord.HashWorkspace(ws), "the hash is stable");
				Check(CompileRecord.Decide(null, h0, false, "Debug") == .NotCompiled, "no record: Not compiled (grey)");
				CompileRecord good = scope .();
				good.Ok = true;
				good.Config.Set("Debug");
				good.Hash = h0;
				good.Time = 123;
				Check(CompileRecord.Decide(good, h0, false, "Debug") == .UpToDate, "sources match the last good compile: Up to date (green)");
				Check(CompileRecord.Decide(good, h0, true, "Debug") == .NeedsCompile, "an unsaved edit: Needs compile (yellow)");
				Check(CompileRecord.Decide(good, h0, false, "Release") == .NeedsCompile, "another configuration: Needs compile");
				Write(scope $"{ws}/src/A.bf", scope $"{cPlayer}// edited\n");
				uint64 h1 = CompileRecord.HashWorkspace(ws);
				Check(h1 != h0 && CompileRecord.Decide(good, h1, false, "Debug") == .NeedsCompile, "a saved change: Needs compile (yellow)");
				Write(scope $"{ws}/src/A.bf", cPlayer);
				Check(CompileRecord.HashWorkspace(ws) == h0 && CompileRecord.Decide(good, h0, false, "Debug") == .UpToDate, "back to the compiled content: Up to date again");
				Write(scope $"{ws}/src/B.bf", "class B {}\n");
				Check(CompileRecord.HashWorkspace(ws) != h0, "a new file changes the hash");
				File.Delete(scope $"{ws}/src/B.bf").IgnoreError();
				CompileRecord bad = scope .();
				bad.Ok = false;
				bad.Config.Set("Debug");
				bad.Hash = h0;
				bad.Errors = 3;
				Check(CompileRecord.Decide(bad, h0, false, "Debug") == .Failed, "failed compile, sources unchanged: Compile failed (red)");
				Check(CompileRecord.Decide(bad, h1, false, "Debug") == .NeedsCompile, "failed compile, then an edit: Needs compile");
				String enc = scope .();
				bad.Encode(enc);
				let back = CompileRecord.Decode(enc);
				Check(back != null && !back.Ok && back.Hash == h0 && back.Errors == 3 && back.Config == "Debug", "the record survives its text form");
				delete back;
				Check(CompileRecord.Decode("garbage") == null, "a damaged record is ignored");
			}

			Console.WriteLine("Safety 18: unparsed members are kept (load + save, edits of other members)");
			{
				int craftedFailures = SaveCheckTests.RunCrafted(let files, let edits);
				Check(craftedFailures == 0 && files == 7, scope $"crafted files with an unreadable member: {files} files, {edits} edits saved, every member kept, unchanged saves byte for byte");
				Check(edits == 14, scope $"both edits (a graph edit, an added member variable) ran on every crafted file ({edits} of 14)");
			}

			Console.WriteLine("Safety 20: saved views (#view lines) of the layout file");
			{
				// Written and read back: a view is the middle of the canvas and the zoom, per function.
				SourceDocument doc = scope .();
				doc.LoadFromText(cPlayer, "Mem.bf");
				Check(Method(doc, "Player.Die()").Graph != null, "graph built");
				Check(!doc.LayoutTouched, "loading a document is not a layout change");
				doc.SetView("Player.Die()", 3, 120.4f, -40.9f, 0.5f);
				doc.SetView("Player.Die()", 3, 130, -50, 0.5f);
				doc.SetView("Player.Die()", 1, 0, 0, 1);
				doc.SetView("Player.TakeDamage(int)", 9, 7, 8, 1.5f);
				Check(doc.LayoutTouched && doc.Views.Count == 3, scope $"a view is replaced by its number ({doc.Views.Count} views)");
				String text = scope .();
				doc.GetLayoutText(text);
				Check(text.Contains("#view\tPlayer.Die()\t3\t130\t-50\t0.5\n"), "the line is #view, method key, number, x, y, zoom");
				Check(text.Contains("#view\tPlayer.TakeDamage(int)\t9\t7\t8\t1.5\n"), "each function has its own views");
				SourceDocument d2 = scope .();
				d2.LoadFromText(cPlayer, "Mem.bf", text);
				let v = d2.FindView("Player.Die()", 3);
				Check(v != null && v.X == 130 && v.Y == -50 && v.Zoom == 0.5f && d2.Views.Count == 3, "read back unchanged");
				String noViews = scope .();
				for (let line in text.Split((char8)10))
					if (!line.StartsWith("#view"))
						noViews.AppendF("{}{}", line, (char8)10);
				SourceDocument d2b = scope .();
				d2b.LoadFromText(cPlayer, "Mem.bf", noViews);
				Check(d2.LayoutTouched == d2b.LayoutTouched, "reading the views is not a layout change");
				String again = scope .();
				d2.GetLayoutText(again);
				Check(again == text, "written again byte for byte");
				// Old files load unchanged; bad lines are skipped.
				SourceDocument d3 = scope .();
				d3.LoadFromText(cPlayer, "Mem.bf", "#vblayout\t2\nPlayer.Die()|entry\t10\t20\n#view\tPlayer.Die()\t0\t1\t2\t1\n#view\tPlayer.Die()\t4\t1\t2\t0\n#view\tPlayer.Die()\t2\n");
				Check(d3.Views.IsEmpty && d3.Layout.Count == 1, "a file without views loads as before; views 0, zoom 0 and short lines are ignored");
				// Clear one, clear all.
				Check(doc.ClearViews("Player.Die()", 3) == 1 && doc.FindView("Player.Die()", 3) == null && doc.FindView("Player.Die()", 1) != null, "Clear removes one view");
				Check(doc.ClearViews("Player.Die()") == 1 && doc.Views.Count == 1, "Clear All of a function leaves the other functions' views");
				// Through the files: a view reaches the side file and an unknown future line stays.
				String path = scope $"{cDir}/Views.bf";
				Write(path, cPlayer);
				Write(scope $"{path}.vblayout", "#vblayout\t2\n#future\tx\n");
				SourceDocument d4 = scope .();
				d4.Load(path).IgnoreError(); // setup: the assertions below catch a failed load
				d4.SetView("Player.Die()", 2, 5, 6, 2);
				d4.SaveLayout();
				String side = Read(scope $"{path}.vblayout");
				Check(side.Contains("#view\tPlayer.Die()\t2\t5\t6\t2\n") && side.Contains("#future\tx\n"), "a saved view reaches the .vblayout and the unknown line stays");
				delete side;
				SourceDocument d5 = scope .();
				d5.Load(path).IgnoreError();
				Check(d5.FindView("Player.Die()", 2) != null, "and loads again from the file");
			}

#if !BF_PLATFORM_WINDOWS
			Console.WriteLine("Safety 19: Linux crash report writer (the report, not the signal)");
			CrashReportChecks();
#endif

			Console.WriteLine("safety: failures={}", sFailures);
			return sFailures;
		}

#if !BF_PLATFORM_WINDOWS
		[CLink] static extern int write(int32 fd, void* data, int count);
		[CLink] static extern int32 getpid();
		[CLink] static extern uint32 getuid();

		static void SetEnv(StringView name, StringView value) => Environment.SetEnvironmentVariable(name, value).IgnoreError(); // checked by the ResolveDir results

		static void CrashReportChecks()
		{
			// Folder: VB_HOME, then XDG_STATE_HOME (absolute only), then ~/.local/state.
			String oldVb = scope .(), oldXdg = scope .();
			Environment.GetEnvironmentVariable("VB_HOME", oldVb).IgnoreError(); // unset: restored as empty, which counts as unset
			Environment.GetEnvironmentVariable("XDG_STATE_HOME", oldXdg).IgnoreError(); // same
			SetEnv("VB_HOME", "");
			SetEnv("XDG_STATE_HOME", "/xdg/state/");
			String d = scope .();
			PosixCrashReport.ResolveDir(d);
			Check(d == "/xdg/state/visualbeef/crashes", scope $"XDG_STATE_HOME: {d}");
			SetEnv("XDG_STATE_HOME", "relative/state");
			d.Clear();
			PosixCrashReport.ResolveDir(d);
			Check(d.EndsWith("/.local/state/visualbeef/crashes") && !d.Contains("relative"), scope $"a relative XDG_STATE_HOME is ignored (spec): {d}");
			SetEnv("VB_HOME", "/vbhome");
			d.Clear();
			PosixCrashReport.ResolveDir(d);
			Check(d == "/vbhome/crashes", scope $"VB_HOME wins: {d}");
			SetEnv("VB_HOME", oldVb);
			SetEnv("XDG_STATE_HOME", oldXdg);

			String dir = scope .();
			Path.GetFullPath(scope $"{cDir}/state/crashes", dir);
			PosixCrashReport.SetDir(dir);
			Check(Directory.Exists(dir), "the report folder is created with its parents");
			PosixCrashReport.SetProject("/home/someone/Projects/Demo");

			// A SIGSEGV with a fake ucontext (gregs at byte 40, RIP is gregs[16]).
			uint64[128] ctx = default;
			ctx[5 + 16] = 0x1234ABCD;
			ctx[5 + 15] = 0x7FFC0000;
			char8[1100] path = ?;
			let len = PosixCrashReport.Write(11, 1, (void*)(int)0xDEAD0, &ctx, "0.1.7-alpha", default, &path[0], 1100,
				(fd) => { StringView extra = "extra    from the caller\n"; write(fd, extra.Ptr, extra.Length); });
			StringView reportPath = .(&path[0], len);
			Check(len > 0 && reportPath.StartsWith(dir) && File.Exists(reportPath), scope $"report written: {reportPath}");
			String report = scope .();
			File.ReadAllText(reportPath, report).IgnoreError(); // checked below
			Check(report.StartsWith("VisualBeef crash report\n") && report.Contains("version  VisualBeef 0.1.7-alpha (Linux x86-64)"), "header and version");
			Check(report.Contains("signal   11 SIGSEGV (invalid memory access)  code 1") && report.Contains("address  0x00000000000dead0"), "signal, code and fault address");
			Check(report.Contains("RIP 0x000000001234abcd") && report.Contains("RSP 0x000000007ffc0000"), "registers from the ucontext");
			Check(report.Contains("project  /home/someone/Projects/Demo\n"), "the open project");
			int stack = report.IndexOf("\nstack (backtrace(3)");
			// glibc's backtrace_symbols_fd writes "path(sym+0xoff) [0xaddr]", "path(+0xoff) [0xaddr]", "path() [0xaddr]"
			// or, for a stripped binary with no dynamic symbol near the address, plain "path[0xaddr]". The path depends
			// on how the runner invokes the binary, so each line after the stack header is checked for its shape: a
			// non-empty prefix (a balanced "(...)" group if it has one) followed by "[0x<hex digits>]". At least two frames.
			int frameCount = 0;
			bool allFramesOk = stack > 0;
			if (stack > 0)
			{
				int hdrEnd = report.IndexOf('\n', stack + 1);
				for (let line in StringView(report, hdrEnd + 1).Split('\n'))
				{
					if (line.IsEmpty || line.StartsWith("stack:") || line.Contains("    ")) continue; // other sections / the caller's lines
					int br = -1;
					for (int i = line.Length - 3; i > 0; i--)
						if (line[i] == '[' && line[i + 1] == '0' && line[i + 2] == 'x') { br = i; break; }
					bool ok = br > 0 && line.EndsWith("]") && br + 3 < line.Length - 1;
					if (ok)
					{
						for (int i = br + 3; i < line.Length - 1; i++)
							if (!((line[i] >= '0' && line[i] <= '9') || (line[i] >= 'a' && line[i] <= 'f') || (line[i] >= 'A' && line[i] <= 'F'))) { ok = false; break; }
						StringView prefix = StringView(line, 0, br);
						prefix.Trim();
						if (prefix.IsEmpty) ok = false;
						else if (prefix.Contains('(') && !prefix.EndsWith(")")) ok = false;
					}
					if (ok) frameCount++; else allFramesOk = false;
				}
			}
			bool frameLines = allFramesOk && frameCount >= 2;
			bool noFrames = report.Contains("stack: no frames available (backtrace returned ");
			// The failure text is one line (the CI log greps FAIL lines only), so the stack is shown with its newlines as " | ".
			String shown = scope .();
			if (stack >= 0)
				shown.Append(StringView(report, stack));
			else
				shown.Append(report);
			shown.Replace("\n", " | ");
			Check(stack > 0 && (frameLines || noFrames), scope $"a backtrace(3) stack of frame lines or the no-frames line ({report.Length} bytes read): {shown}");
			Check(report.EndsWith("extra    from the caller\n"), "the caller's lines (recovery flush) come last");
			let name = StringView(reportPath, dir.Length + 1);
			Check(name.StartsWith("visualbeef-crash-") && name.EndsWith(".log") && name.Length == "visualbeef-crash-2026-10-11-120000-".Length + 4 + scope $"{getpid()}".Length,
				scope $"file name visualbeef-crash-<date>-<time>-<pid>.log: {name}");

			// The next start announces it once.
			String newest = scope .();
			Check(PosixCrashReport.FindNewer(dir, newest) && newest == reportPath, "next start: the newest report is found");
			newest.Clear();
			Check(!PosixCrashReport.FindNewer(dir, newest), "and announced only once");

			// A Beef runtime error (no signal) with no project open.
			PosixCrashReport.SetProject("");
			File.Delete(reportPath).IgnoreError(); // the same second and pid reuse the name
			let len2 = PosixCrashReport.Write(0, 0, null, null, "0.1.7-alpha", "Index out of range", &path[0], 1100);
			report.Clear();
			File.ReadAllText(StringView(&path[0], len2), report).IgnoreError(); // checked below
			Check(len2 > 0 && report.Contains("fatal    Beef runtime error: Index out of range") && report.Contains("project  (none open)") && !report.Contains("registers"),
				"a runtime error: message, no project, no registers");

			// A folder that can't be written: nothing, and no crash.
			PosixCrashReport.SetDir("/proc/vb-no-such-folder");
			Check(PosixCrashReport.Write(11, 0, null, null, "x", default, &path[0], 1100) == 0 && path[0] == 0, "an unwritable folder: no report, path empty");
			PosixCrashReport.SetDir(dir);

			// Pruning keeps the newest.
			for (int i < 4)
				File.WriteAllText(scope $"{dir}/visualbeef-crash-2020-01-0{i + 1}-000000-1.log", "x").IgnoreError(); // checked by the count
			PosixCrashReport.Prune(dir, 2);
			int left = 0;
			for (let e in Directory.EnumerateFiles(dir))
			{
				String n = scope .();
				e.GetFileName(n);
				if (n.StartsWith("visualbeef-crash-"))
					left++;
			}
			Check(left == 2 && !File.Exists(scope $"{dir}/visualbeef-crash-2020-01-01-000000-1.log"), scope $"prune keeps the 2 newest ({left} left)");
		}
#endif

		/// Runs icacls with the arguments; true when it exited with 0.
		static bool RunIcacls(StringView args)
		{
			ProcessStartInfo psi = scope .();
			psi.SetFileName("icacls");
			psi.SetArguments(args);
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
				return false;
			proc.WaitFor();
			return proc.ExitCode == 0;
		}
	}
}
