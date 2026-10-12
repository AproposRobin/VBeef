using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=host`: a project made from a host tool's template, through the calls the UI makes
	/// (docs/Host-Integration.md). From an empty folder: File > New Project > From template folder...
	/// with the fixture template (`VB_HOST_TEMPLATE`, default VisualBeefTests/fixtures/Host/Template of
	/// this checkout), the node library it references (Fixture Kit: a `[NodeLibrary]` class with
	/// `[CallbackNode]` functions) in the Node menu, a callback node placed in Main with the static
	/// function of the callback's shape picked for its pin, the compile configuration the manifest
	/// names, Save All, a compile, and close / reopen byte for byte. `[HOST]` lines log what was seen.
	extension EditorApp
	{
		int mHoStep;
		int mHoWait;
		String mHoFile = new .() ~ delete _;
		String mHoSaved = new .() ~ delete _;
		String mHoConfig = new .() ~ delete _;

		void HoNote(StringView text) => Notify.Log(.Info, "SelfTest", scope $"[HOST] {text}");

		SourceDocument HoDoc() => OpenFile(mHoFile, false);

		MethodGraph HoByName(StringView name)
		{
			let doc = HoDoc();
			if (doc == null)
				return null;
			for (let mg in doc.Methods)
				if (mg.Graphable && mg.Method.Name == name)
				{
					OpenTab(mg);
					return mg;
				}
			return null;
		}

		/// The Node menu at `pin` filtered by `filter`: its rows, logged.
		void HoRows(Pin pin, StringView filter, List<NodeItem> outRows)
		{
			let tab = CurrentTab;
			if (tab == null)
				return;
			OpenNodeMenu(tab, .(0, 0), (pin != null) ? pin.Id : 0);
			mNodeMenu.OpenRequested = false;
			mNodeMenu.SelfTestRows(filter, outRows);
			String s = scope .();
			for (let it in outRows)
			{
				if (@it.Index >= 12)
					break;
				s.AppendF("{}{} [{}]", s.IsEmpty ? "" : " | ", it.Label, it.Category);
			}
			HoNote(scope $"Node menu '{filter}': {outRows.Count} rows: {s}");
		}

		bool HoPick(Pin pin, StringView label, float x, float y, bool prefix = false)
		{
			let tab = CurrentTab;
			if (tab == null)
				return false;
			OpenNodeMenu(tab, .(x, y), (pin != null) ? pin.Id : 0);
			mNodeMenu.OpenRequested = false;
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.SelfTestRows(label, rows);
			NodeItem found = null;
			for (let it in rows)
				if (prefix ? it.Label.StartsWith(label) : it.Label == label)
				{
					found = it;
					break;
				}
			if (found == null)
			{
				HoNote(scope $"the Node menu offers no '{label}'");
				return false;
			}
			HoNote(scope $"picked '{found.Label}' in {found.Category}: {found.Tooltip}");
			NodeItem copy = scope .();
			copy.CopyFrom(found);
			ExecuteAction(copy);
			return true;
		}

		static void HoTemplateDir(String outDir, String here = Compiler.CallerFilePath)
		{
			if (Environment.GetEnvironmentVariable("VB_HOST_TEMPLATE", outDir) case .Ok && !outDir.IsEmpty)
				return;
			outDir.Clear();
			String src = scope .();
			Path.GetDirectoryPath(here, src).IgnoreError(); // ...\VisualBeefEditor\src
			String editor = scope .();
			Path.GetDirectoryPath(src, editor).IgnoreError();
			String root = scope .();
			Path.GetDirectoryPath(editor, root).IgnoreError();
			outDir.AppendF("{0}{1}VisualBeefTests{1}fixtures{1}Host{1}Template", root, Path.DirectorySeparatorChar);
		}

		bool SelfTestHost()
		{
			if (mHoWait > 0)
			{
				mHoWait--;
				return false;
			}
			let step = mHoStep++;
			switch (step)
			{
			case 0:
				// A blank folder: File > New Project > From template folder..., the fixture template chosen in the dialog.
				SelfTestCheck(sProjectTypes[cTemplateType].StartsWith("From template"), scope $"host 1: File > New Project offers '{sProjectTypes[cTemplateType]}'");
				String tpl = scope .();
				HoTemplateDir(tpl);
				mNPName.Set("Hello Tool");
				mNPTemplate.Set(mProjectRoot);
				ResolveNewTemplate();
				SelfTestCheck(mNPTemplateInfo == null && mNPTemplateError.Contains("template.json"), scope $"host 1: a folder without template.json says so: {mNPTemplateError}");
				mNPTemplate.Set(tpl);
				ResolveNewTemplate();
				SelfTestCheck(mNPTemplateInfo != null && mNPTemplateInfo.Name == "Fixture tool" && mNPTemplateInfo.Variables.Count == 2 && mNPVarBufs.Count == 2,
					scope $"host 1: the Template folder row reads {tpl} ({mNPTemplateInfo?.Name}, {mNPVarBufs.Count} variables) {mNPTemplateError}");
				if (mNPVarBufs.Count == 2)
					HoNote(scope $"variable fields: Id='{mNPVarBufs[0].View}' Version='{mNPVarBufs[1].View}'");
				String location = scope .(mProjectRoot);
				bool made = CreateTemplateProject("Hello Tool", location);
				mHoFile.Clear();
				mHoFile.AppendF("{0}{1}src{1}Program.bf", mProjectRoot, Path.DirectorySeparatorChar);
				SelfTestCheck(made && mProjectRoot.EndsWith("Hello Tool") && File.Exists(mHoFile), scope $"host 1: 'Hello Tool' from the template wrote and opened {mProjectRoot} (the folder is named as typed)");
				if (!made)
					return true;
				String manifest = scope .();
				File.ReadAllText(scope $"{mProjectRoot}{Path.DirectorySeparatorChar}.vbproject", manifest).IgnoreError();
				String tool = scope .();
				File.ReadAllText(scope $"{mProjectRoot}{Path.DirectorySeparatorChar}tool.json", tool).IgnoreError();
				HoNote(scope $".vbproject:\n{manifest}\ntool.json:\n{tool}");
				SelfTestCheck(manifest.Contains("\"configuration\": \"Release\"") && manifest.Contains("\"main\": \"src/Program.bf\"") && tool.Contains("\"id\": \"hello-tool\""),
					"host 2: .vbproject names main and configuration; the template's variables are filled in (id hello-tool)");
			case 1:
				let doc = HoDoc();
				SelfTestCheck(doc != null, "host 3: src/Program.bf opens");
				if (doc == null)
					return true;
				String libs = scope .();
				for (let l in mNodeMenu.Types.Libraries)
					libs.AppendF(" {}", l.Name);
				HoNote(scope $"libraries:{libs}");
				SelfTestCheck(libs.Contains(" FixtureKit"), "host 3: the template's library is indexed as a node library");
				let main = HoByName("Main");
				if (main == null)
					return true;
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				HoRows(null, "Days In Year", rows);
				bool pure = false;
				bool register = false;
				bool tryRegister = false;
				bool remove = false;
				bool original = false;
				bool hidden = false;
				for (let it in rows)
				{
					if (it.Label == "Days In Year" && it.Category.Contains("Fixture Kit"))
						pure = true;
					if (it.Label == "Register Days In Year" && it.Category.Contains("Callbacks"))
						register = true;
					if (it.Label == "Try register Days In Year" && it.Category.Contains("Callbacks"))
						tryRegister = true;
					if (it.Label == "Remove Days In Year" && it.Category.Contains("Callbacks"))
						remove = true;
					if (it.Label == "Call original Days In Year" && it.Category.Contains("Callbacks"))
						original = true;
				}
				ClearAndDeleteItems!(rows);
				HoRows(null, "Slot Table", rows);
				for (let it in rows)
					if (it.Label.Contains("Slot Table"))
						hidden = true;
				SelfTestCheck(pure && register && tryRegister && remove && original, scope $"host 4: the Node menu has the library's function under Fixture Kit and its four callback nodes under Callbacks ({pure} {register} {tryRegister} {remove} {original})");
				SelfTestCheck(!hidden, "host 4: a [NodeHidden] function is not offered");
				HoPick(main.Graph.Entry.Then, "Try register Days In Year", 480, 0);
			case 2:
				let main = HoByName("Main");
				let reg = (main != null) ? FindNodeOf(main.Graph, .Call, "TryRegisterDaysInYear") : null;
				SelfTestCheck(reg != null, "host 5: Try register Days In Year is placed in Main");
				if (reg == null)
					return true;
				let cb = FirstValueInput(reg);
				HoNote(scope $"callback pin {cb?.Label}:{cb?.TypeName}");
				bool picked = HoPick(cb, "OnDaysInYear", 480, 200, true);
				SelfTestCheck(picked, "host 5: the callback pin offers OnDaysInYear (the static function of that shape)");
				if (!picked)
					SessionSetPin(reg, cb, "=> OnDaysInYear");
			case 3:
				let main = HoByName("Main");
				String body = scope .();
				HoDoc().GenerateMethodBody(main, body);
				HoNote(scope $"Main body:\n{body}");
				SelfTestCheck(body.Contains("Clock.TryRegisterDaysInYear(=> OnDaysInYear);"), "host 6: written Clock.TryRegisterDaysInYear(=> OnDaysInYear)");
				String reason = scope .();
				mHoConfig.Clear();
				ResolveCompileConfig(mProjectRoot, mHoConfig, reason);
				SelfTestCheck(mHoConfig == "Release" && reason.Contains(".vbproject"), scope $"host 7: the compile configuration comes from .vbproject: {mHoConfig} ({reason})");
				SaveAll();
				Compile();
			case 4:
				if (SessionBuildRunning)
				{
					mHoStep--;
					return false;
				}
				mHoWait = 5;
			case 5:
				let st = SessionState;
				String exe = scope $"{mProjectRoot}{Path.DirectorySeparatorChar}build{Path.DirectorySeparatorChar}{mHoConfig}_Win64{Path.DirectorySeparatorChar}HelloTool{Path.DirectorySeparatorChar}HelloTool";
#if BF_PLATFORM_WINDOWS
				exe.Append(".exe");
#endif
				HoNote(scope $"compile: {st}, {exe} exists {File.Exists(exe)}");
				SelfTestCheck(st == .Good, scope $"host 8: the project compiles with the node library ({st})");
				let doc = HoDoc();
				mHoSaved.Set(doc.Text);
				CloseDoc(doc);
			case 6:
				let doc = HoDoc();
				SelfTestCheck(doc != null && doc.Text == mHoSaved && !doc.Modified, "host 9: Program.bf closed and reopened byte for byte");
				ReloadSheet();
				SelfTestCheck(HoDoc().Text == mHoSaved, "host 9: Reload Sheet leaves the text alone");
				String before = scope .(HoDoc().Text);
				for (let mg in HoDoc().Methods)
					if (mg.Graphable)
						HoDoc().Commit(mg);
				SelfTestCheck(HoDoc().Text == before, "host 10: every graph committed unchanged gives the file byte for byte");
				HoByName("Main"); // leave Main open (captures that follow open the Node menu on it)
			default:
				return true;
			}
			return false;
		}
	}
}
