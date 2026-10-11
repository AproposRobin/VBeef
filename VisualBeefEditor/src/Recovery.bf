using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// A document text found in the journal of a session that did not exit cleanly.
	class RecoveredFile
	{
		public String SourcePath = new .() ~ delete _;
		public String JournalPath = new .() ~ delete _;
		public String Text = new .() ~ delete _;
		public DateTime Time;
	}

	/// Recovery journal of unsaved documents.
	///
	/// Each session journals into %LOCALAPPDATA%\VisualBeef\recovery\<pid>-<start time>\, never
	/// into the project. A modified document's text is copied there every
	/// Prefs.RecoverySeconds (atomically, only when it changed), and once more by the crash
	/// handler (CrashFlush, raw writes). A clean exit deletes the session folder; saving or
	/// reverting a document deletes its entry. The session holds `session.lock` open without
	/// sharing, so another running editor never treats a live session as crashed. On the next
	/// start, entries of dead sessions are offered back ("Recover unsaved changes?").
	static class Recovery
	{
		class Slot
		{
			public SourceDocument Doc;
			public String SourcePath = new .() ~ delete _;
			public String JournalPath = new .() ~ delete _;
			/// UTF-16 copy of JournalPath for the crash path.
			public char16* JournalPathW ~ delete _;
			/// "#vbrecovery\t1\npath\t...\n\n": everything before the text.
			public String Header = new .() ~ delete _;
			public int32 WrittenVersion = -1;
		}

		static List<Slot> sSlots = new .() ~ DeleteContainerAndItems!(_);
		static String sRoot = new .() ~ delete _;
		static String sSessionDir = new .() ~ delete _;
		static int sLock;
		static double sLastWrite;
		public const String cMagic = "#vbrecovery";

		public static void GetRoot(String outDir)
		{
			AppPaths.Root(outDir);
			outDir.AppendF("{}recovery", Path.DirectorySeparatorChar);
		}

		/// Creates this session's journal folder and takes its lock.
		public static void Start()
		{
			GetRoot(sRoot);
			AppPaths.EnsureDir(sRoot);
			Win32Raw.SystemTime t = default;
			Win32Raw.GetLocalTime(&t);
			sSessionDir.AppendF("{}{}{}-{:D4}{:D2}{:D2}-{:D2}{:D2}{:D2}", sRoot, Path.DirectorySeparatorChar, Win32Raw.GetCurrentProcessId(),
				t.Year, t.Month, t.Day, t.Hour, t.Minute, t.Second);
			AppPaths.EnsureDir(sSessionDir);
			String lockPath = scope .();
			lockPath.AppendF("{}{}session.lock", sSessionDir, Path.DirectorySeparatorChar);
			// No sharing + delete-on-close: gone when this process ends, however it ends.
			sLock = Win32Raw.CreateFileW(Utf16Text.Scoped!(lockPath), Win32Raw.GENERIC_WRITE, 0, null, Win32Raw.CREATE_ALWAYS, 0x04000000 /* FILE_FLAG_DELETE_ON_CLOSE */, 0);
		}

		/// Clean exit: the journal is no longer needed.
		public static void EndSession()
		{
			ClearAndDeleteItems!(sSlots);
			if (sLock != 0 && sLock != Win32Raw.INVALID_HANDLE)
				Win32Raw.CloseHandle(sLock);
			sLock = 0;
			if (!sSessionDir.IsEmpty && Directory.Exists(sSessionDir))
				Directory.DelTree(sSessionDir).IgnoreError(); // a file still open elsewhere: the folder is cleaned up as a dead session next time
		}

		static Slot FindSlot(SourceDocument doc)
		{
			for (let s in sSlots)
				if (s.Doc == doc)
					return s;
			return null;
		}

		static void RemoveSlot(Slot s)
		{
			File.Delete(s.JournalPath).IgnoreError(); // already gone: fine
			sSlots.Remove(s);
			delete s;
		}

		static void FillSlot(Slot s, SourceDocument doc)
		{
			s.Doc = doc;
			s.SourcePath.Set(doc.FilePath);
			s.JournalPath.Clear();
			s.JournalPath.AppendF("{}{}{:X16}.vbrec", sSessionDir, Path.DirectorySeparatorChar, LibraryIndex.Hash(doc.FilePath));
			delete s.JournalPathW;
			let w = Utf16Text.Scoped!(s.JournalPath);
			int n = 0;
			while (w[n] != 0)
				n++;
			s.JournalPathW = new char16[n + 1]*;
			Internal.MemCpy(s.JournalPathW, w, (n + 1) * 2);
			s.Header.Clear();
			s.Header.AppendF("{}\t1\npath\t{}\n\n", cMagic, doc.FilePath);
			s.WrittenVersion = -1;
		}

		/// Call every frame: keeps a slot for each modified document (cheap), and every
		/// Prefs.RecoverySeconds writes the ones whose text changed. `docs` = every open document.
		public static void Tick(List<SourceDocument> docs, double now)
		{
			if (sSessionDir.IsEmpty)
				return;
			// Drop slots of closed, saved or reverted documents.
			for (int i = sSlots.Count - 1; i >= 0; i--)
			{
				let s = sSlots[i];
				if (!docs.Contains(s.Doc) || !s.Doc.Modified || s.Doc.FilePath.IsEmpty)
					RemoveSlot(s);
				else if (s.SourcePath != s.Doc.FilePath)
				{
					File.Delete(s.JournalPath).IgnoreError(); // renamed: the entry moves to the new name
					FillSlot(s, s.Doc);
				}
			}
			if (Prefs.RecoverySeconds <= 0)
				return;
			for (let d in docs)
			{
				if (!d.Modified || d.FilePath.IsEmpty || d.Unit == null)
					continue;
				if (FindSlot(d) == null)
				{
					Slot s = new .();
					FillSlot(s, d);
					sSlots.Add(s);
				}
			}
			if (now - sLastWrite < Prefs.RecoverySeconds)
				return;
			sLastWrite = now;
			for (let s in sSlots)
			{
				if (s.WrittenVersion == s.Doc.Version)
					continue;
				String content = scope .(s.Header.Length + s.Doc.Unit.Text.Length);
				content.Append(s.Header);
				content.Append(s.Doc.Unit.Text);
				if (AppPaths.WriteAtomic(s.JournalPath, content) case .Ok)
					s.WrittenVersion = s.Doc.Version;
			}
		}

		/// Crash path (any thread, no allocation): writes every journaled document's current text.
		public static bool CrashFlush()
		{
			bool any = false;
			for (int i < sSlots.Count)
			{
				let s = sSlots[i];
				if (s == null || s.Doc == null || s.Doc.Unit == null || s.JournalPathW == null)
					continue;
				let text = s.Doc.Unit.Text;
				if (text == null)
					continue;
				let file = Win32Raw.Create(s.JournalPathW);
				if (file == Win32Raw.INVALID_HANDLE)
					continue;
				Win32Raw.Write(file, s.Header);
				Win32Raw.Write(file, text);
				Win32Raw.FlushFileBuffers(file);
				Win32Raw.CloseHandle(file);
				any = true;
			}
			return any;
		}

		/// True when no running editor owns the session folder.
		static bool IsDead(StringView sessionDir)
		{
			String lockPath = scope .();
			lockPath.AppendF("{}{}session.lock", sessionDir, Path.DirectorySeparatorChar);
			if (!File.Exists(lockPath))
				return true;
			// A live session holds it open without sharing: the delete fails.
			return File.Delete(lockPath) case .Ok;
		}

		/// Journal entries left by sessions that crashed or were killed.
		public static void FindOrphans(List<RecoveredFile> outFiles)
		{
			if (sRoot.IsEmpty)
				GetRoot(sRoot);
			if (!Directory.Exists(sRoot))
				return;
			for (let dirEntry in Directory.EnumerateDirectories(sRoot))
			{
				String dir = scope .();
				dirEntry.GetFilePath(dir);
				if (ProjectIndex.SamePath(dir, sSessionDir) || !IsDead(dir))
					continue;
				for (let fileEntry in Directory.EnumerateFiles(dir))
				{
					String path = scope .();
					fileEntry.GetFilePath(path);
					if (!path.EndsWith(".vbrec"))
						continue;
					String content = scope .();
					if (File.ReadAllText(path, content, true) case .Err)
						continue;
					if (!content.StartsWith(cMagic))
						continue;
					int end = content.IndexOf("\n\n");
					if (end < 0)
						continue;
					RecoveredFile rf = new .();
					for (var line in StringView(content, 0, end).Split('\n'))
						if (line.StartsWith("path\t"))
							rf.SourcePath.Set(line.Substring(5));
					rf.JournalPath.Set(path);
					rf.Text.Set(StringView(content, end + 2));
					rf.Time = fileEntry.GetLastWriteTime();
					if (rf.SourcePath.IsEmpty)
					{
						delete rf;
						continue;
					}
					// Several dead sessions may hold the same file: keep the newest.
					bool replaced = false;
					for (int i < outFiles.Count)
					{
						if (ProjectIndex.SamePath(outFiles[i].SourcePath, rf.SourcePath))
						{
							if (rf.Time > outFiles[i].Time)
							{
								delete outFiles[i];
								outFiles[i] = rf;
							}
							else
								delete rf;
							replaced = true;
							break;
						}
					}
					if (!replaced)
						outFiles.Add(rf);
				}
			}
		}

		/// Deletes every dead session folder (after recovering or discarding).
		public static void DeleteOrphans()
		{
			if (!Directory.Exists(sRoot))
				return;
			List<String> dead = scope .();
			defer { ClearAndDeleteItems!(dead); }
			for (let dirEntry in Directory.EnumerateDirectories(sRoot))
			{
				String dir = new .();
				dirEntry.GetFilePath(dir);
				if (!ProjectIndex.SamePath(dir, sSessionDir) && IsDead(dir))
					dead.Add(dir);
				else
					delete dir;
			}
			for (let d in dead)
				Directory.DelTree(d).IgnoreError(); // in use: retried on the next start
		}
	}
}
