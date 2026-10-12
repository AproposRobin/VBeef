using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests startpage`: the rules behind the start page and the New Project dialog that need no window:
	/// the folder name made from a typed project name, and the recent projects list (order, one entry per folder,
	/// the limit, removal, the stored form of a path and the "opened ..." wording).
	static class StartPageTests
	{
		static int sChecks;
		static int sFailures;

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

		static bool FolderIs(StringView typed, StringView expected)
		{
			String got = scope .();
			ProjectKind.FolderName(typed, got);
			return got == expected;
		}

		public static int Run()
		{
			sChecks = 0;
			sFailures = 0;
			FolderNames();
			Recents();
			StoredPaths();
			Wording();
			Console.WriteLine("startpage checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}

		static void FolderNames()
		{
			Console.WriteLine("folder names");
			Check(FolderIs("My Game", "My Game"), "the typed name is the folder: 'My Game'");
			Check(FolderIs("new project", "new project"), "'new project' stays 'new project'");
			Check(FolderIs("  Padded  ", "Padded"), "leading and trailing spaces are trimmed");
			Check(FolderIs("Game: Part 2?", "Game Part 2"), "characters Windows forbids are dropped ('Game: Part 2?')");
			Check(FolderIs("a/b\\c|d*e\"f<g>h", "abcdefgh"), "slashes, bar, star, quote and angle brackets are dropped");
			Check(FolderIs("Dots...", "Dots"), "trailing dots are dropped");
			Check(FolderIs("v1.2 Tool", "v1.2 Tool"), "dots inside a name stay");
			Check(FolderIs("Caf\u{E9} \u{65E5}\u{672C}", "Caf\u{E9} \u{65E5}\u{672C}"), "letters beyond ASCII stay");
			Check(FolderIs("CON", "CON_") && FolderIs("nul.txt", "nul.txt_") && FolderIs("com3", "com3_") && FolderIs("LPT9", "LPT9_"), "a name Windows reserves gets a '_' after it");
			Check(FolderIs("COM0", "COM0") && FolderIs("Console", "Console") && FolderIs("Auxiliary", "Auxiliary"), "names that only start like a reserved one are left alone");
			Check(FolderIs("", "") && FolderIs("  ", "") && FolderIs("???", "") && FolderIs("...", ""), "nothing usable left gives an empty name");
			String appended = scope .("D:\\Work\\");
			ProjectKind.FolderName("Tool", appended);
			Check(appended == "D:\\Work\\Tool", "the folder name is appended to the output");
		}

		static void Recents()
		{
			Console.WriteLine("recent projects");
			RecentProjects r = scope .();
			r.Touch("D:\\Work\\Alpha", 1000);
			r.Touch("D:\\Work\\Beta", 2000);
			r.Touch("D:\\Work\\Gamma\\", 3000);
			Check(r.Items.Count == 3 && r.Items[0].Name == "Gamma" && r.Items[1].Name == "Beta" && r.Items[2].Name == "Alpha", "newest first, the name is the last folder");
			Check(r.Items[0].Path == "D:\\Work\\Gamma", "a trailing separator is not kept");
			r.Touch("d:/work/alpha", 4000);
			Check(r.Items.Count == 3 && r.Items[0].Name == "Alpha" && r.Items[0].Opened == 4000, "opening a listed folder again (other case and slashes) moves it to the front, no duplicate");
			Check(r.Find("D:\\WORK\\BETA\\") != null && r.Find("D:\\Work\\Nope") == null, "Find ignores case and a trailing separator");
			Check(r.Remove("D:\\Work\\Beta") && !r.Remove("D:\\Work\\Beta") && r.Items.Count == 2, "Remove takes one entry out, once");
			for (int i < 20)
				r.Touch(scope $"D:\\Many\\P{i}", 5000 + i);
			Check(r.Items.Count == RecentProjects.cMax && r.Items[0].Name == "P19" && r.Items.Back.Name == "P8", scope $"the list keeps the newest {RecentProjects.cMax} ({r.Items.Count}, first {r.Items[0].Name}, last {r.Items.Back.Name})");
			RecentProjects stored = scope .();
			stored.AddStored("D:\\A", 10);
			stored.AddStored("D:\\B", 20);
			stored.AddStored("d:\\a", 30);
			stored.AddStored("", 40);
			Check(stored.Items.Count == 2 && stored.Items[0].Name == "A" && stored.Items[1].Opened == 20, "AddStored keeps the stored order and skips duplicates and empty paths");
			RecentProjects drive = scope .();
			drive.Touch("D:\\", 1);
			Check(drive.Items[0].Path == "D:\\" && drive.Items[0].Name == "D:\\", "a drive root keeps its separator");
		}

		static void StoredPaths()
		{
			Console.WriteLine("stored paths");
			String s = scope .();
			RecentProjects.ToStored("C:\\Data\\VisualBeef\\projects\\Game", "C:\\Data\\VisualBeef", s);
			Check(s == "projects/Game", scope $"a project under the data folder is stored relative ({s})");
			s.Clear();
			RecentProjects.ToStored("D:\\Elsewhere\\Game", "C:\\Data\\VisualBeef", s);
			Check(s == "D:\\Elsewhere\\Game", "a project the user put elsewhere keeps its absolute path");
			s.Clear();
			RecentProjects.ToStored("c:/data/visualbeef/Game", "C:\\Data\\VisualBeef\\", s);
			Check(s == "Game", scope $"case, slashes and a trailing separator do not matter ({s})");
			s.Clear();
			RecentProjects.ToStored("C:\\Data\\VisualBeef2\\Game", "C:\\Data\\VisualBeef", s);
			Check(s == "C:\\Data\\VisualBeef2\\Game", "a folder that only starts with the base name is not under it");
			s.Clear();
			RecentProjects.FromStored("projects/Game", "C:\\Data\\VisualBeef", s);
			Check(s == "C:\\Data\\VisualBeef\\projects\\Game", scope $"a stored relative path is joined to the base ({s})");
			s.Clear();
			RecentProjects.FromStored("D:\\Elsewhere\\Game", "C:\\Moved", s);
			Check(s == "D:\\Elsewhere\\Game", "an absolute stored path is returned as it is");
			s.Clear();
			RecentProjects.FromStored("projects/Game", "/home/me/.local/share/VisualBeef/", s);
			Check(s == "/home/me/.local/share/VisualBeef/projects/Game", scope $"the base's separator is used ({s})");
		}

		static void Wording()
		{
			Console.WriteLine("opened wording");
			int64 now = 1760000000; // 2025-10-09 08:53:20 UTC
			String s = scope .();
			void Say(int64 opened)
			{
				s.Clear();
				RecentProjects.OpenedText(opened, now, s);
			}
			Say(now - 10);
			Check(s == "just now", scope $"10 seconds: {s}");
			Say(now - 60);
			Check(s == "1 minute ago", scope $"1 minute: {s}");
			Say(now - 5 * 60);
			Check(s == "5 minutes ago", scope $"5 minutes: {s}");
			Say(now - 3 * 3600);
			Check(s == "3 hours ago", scope $"3 hours: {s}");
			Say(now - 30 * 3600);
			Check(s == "yesterday", scope $"30 hours: {s}");
			Say(now - 4 * 86400);
			Check(s == "4 days ago", scope $"4 days: {s}");
			Say(now - 40 * 86400);
			Check(s == "2025-08-30", scope $"40 days is a date: {s}");
			Say(0);
			Check(s == "never", scope $"no time stamp: {s}");
			Say(now + 500);
			Check(s == "just now", scope $"a time stamp in the future reads 'just now': {s}");
			s.Clear();
			RecentProjects.DateText(951782400, s); // 2000-02-29
			Check(s == "2000-02-29", scope $"a leap day: {s}");
			s.Clear();
			RecentProjects.DateText(0, s);
			Check(s == "1970-01-01", scope $"the epoch: {s}");
		}
	}
}
