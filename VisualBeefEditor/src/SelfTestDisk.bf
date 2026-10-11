using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=session,debug,disk` (or after any run that leaves `Greeter.bf` open): the disk
	/// going wrong under the open editor, through the calls the UI makes (Save All, Reload From Disk).
	/// Every failure must be reported and must lose nothing:
	///  - a read-only source file: Save All is refused with a message, the file is untouched, the edit stays
	///    in memory, and it saves once the file is writable again;
	///  - the source folder deleted while the document is open (set `VB_SELFTEST_DELETE_OK=1`, the step
	///    deletes the scratch project's `src`): the external-change check does not crash, Save All fails with
	///    a message and keeps the edit, Reload From Disk says it could not read the file and keeps the text,
	///    and once the folder is back the edit saves.
	/// See docs/Testing.md.
	extension EditorApp
	{
		static bool ReadDisk(StringView path, String outText)
		{
			outText.Clear();
			return File.ReadAllText(path, outText, true) case .Ok;
		}

		static Member SelfTestFindTypeIn(SourceDocument doc, StringView name)
		{
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		bool SelfTestDisk()
		{
			let doc = SelfTestDocWithType("Greeter");
			let greeter = (doc != null) ? SelfTestFindTypeIn(doc, "Greeter") : null;
			SelfTestCheck(greeter != null, "disk: the project has Greeter");
			if (greeter == null)
				return true;
			String path = scope .(doc.FilePath);
			String original = scope .();
			SelfTestCheck(ReadDisk(path, original) && !doc.Modified && doc.Text == original, "disk: Greeter.bf is saved, memory equals disk");
			String now = scope .();

			// 1. A read-only source file.
			File.SetAttributes(path, .ReadOnly).IgnoreError(); // a failed attribute change shows as the save succeeding, checked below
			SelfTestCheck(doc.AddField(SelfTestFindTypeIn(doc, "Greeter"), "int", "mDiskTest") && doc.Modified, "disk 1: an edit to the file");
			ClearAndDeleteItems!(mErrors);
			mStatus.Clear();
			bool saved = SaveAll();
			SelfTestCheck(!saved, "disk 1: Save All on a read-only source file is refused");
			SelfTestCheck(ReadDisk(path, now) && now == original, "disk 1: the read-only file is untouched byte for byte");
			SelfTestCheck(doc.Modified && doc.Text.Contains("mDiskTest"), "disk 1: the edit is still in memory, still unsaved");
			SelfTestCheck(!mErrors.IsEmpty && mErrors[0].Contains("Save failed"), scope $"disk 1: the failure is reported ({(mErrors.IsEmpty ? mStatus : mErrors[0])})");
			ClearAndDeleteItems!(mErrors);
			File.SetAttributes(path, .Normal).IgnoreError(); // cleanup; a failure shows in the next check
			saved = SaveAll();
			SelfTestCheck(saved && !doc.Modified && ReadDisk(path, now) && now.Contains("mDiskTest"), "disk 1: once writable, the same edit saves");
			doc.Undo();
			SelfTestCheck(SaveAll() && ReadDisk(path, now) && now == original, "disk 1: undo and save restore the file");
			ClearAndDeleteItems!(mErrors);

			// 2. The source folder deleted while the document is open.
			String flag = scope .();
			if (!(Environment.GetEnvironmentVariable("VB_SELFTEST_DELETE_OK", flag) case .Ok) || flag != "1")
			{
				Notify.Log(.Info, "SelfTest", "[SELFTEST] disk 2 skipped: set VB_SELFTEST_DELETE_OK=1 to let it delete the scratch project's source folder");
				return true;
			}
			String dir = scope .();
			Path.GetDirectoryPath(path, dir);
			SelfTestCheck(doc.AddField(SelfTestFindTypeIn(doc, "Greeter"), "int", "mGone") && doc.Modified, "disk 2: an edit, then the folder is deleted");
			Directory.DelTree(dir).IgnoreError(); // the test's own scratch folder; a failure shows below
			SelfTestCheck(!Directory.Exists(dir), "disk 2: the source folder is gone");
			CheckExternalChange(); // the per-frame check: must neither crash nor reload over the edit
			SelfTestCheck(doc.Modified && doc.Text.Contains("mGone"), "disk 2: the external-change check leaves the edit alone");
			ClearAndDeleteItems!(mErrors);
			mStatus.Clear();
			saved = SaveAll();
			SelfTestCheck(!saved && !mErrors.IsEmpty, scope $"disk 2: Save All into a missing folder fails with a message ({(mErrors.IsEmpty ? mStatus : mErrors[0])})");
			SelfTestCheck(doc.Modified && doc.Text.Contains("mGone"), "disk 2: the edit is still in memory after the failed save");
			ClearAndDeleteItems!(mErrors);
			mStatus.Clear();
			ReloadFromDisk(doc);
			SelfTestCheck(mStatus.Contains("Could not reload") && doc.Text.Contains("mGone"), scope $"disk 2: Reload From Disk says it could not read the file and keeps the text ({mStatus})");
			// The folder comes back (restored from the text it had): the kept edit saves.
			Directory.CreateDirectory(dir).IgnoreError();
			File.WriteAllText(path, original).IgnoreError();
			saved = SaveAll();
			SelfTestCheck(saved && ReadDisk(path, now) && now.Contains("mGone") && !doc.Modified, "disk 2: with the folder back, the kept edit saves");
			doc.Undo();
			SelfTestCheck(SaveAll() && ReadDisk(path, now) && now == original, "disk 2: undo and save leave the file as it was");
			ClearAndDeleteItems!(mErrors);
			return true;
		}
	}
}
