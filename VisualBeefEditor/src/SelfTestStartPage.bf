using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Docs;

namespace VisualBeef.Editor
{
	/// Self tests of the start page, the project switch and the documentation panel (docs/Testing.md):
	///
	/// * `startpage` (VB_SELFTEST=startpage, started with no project and a fresh VB_HOME): the start page shows; File >
	///   New Project makes `Alpha One` (the folder, project and workspace files carry the typed name) and it becomes the
	///   open project; a second project is made while the first has unsaved changes (the question comes first, Don't Save
	///   drops them) and the workspace root, Project Browser, Sheets, index, title and recent list all move to it; Save All
	///   keeps the edit; Close Project returns to the start page; the recent list persists, reloads, dims a folder that is
	///   gone and removes it; the New Project dialog's path line; a compile of the project with a space in its name.
	/// * `docs` (VB_SELFTEST=docs): Help > Documentation loads the shipped pages, lays a page out, decodes its pictures,
	///   follows an internal link, scrolls to a heading, goes Back and searches titles and headings.
	///
	/// Capture steps: `sp-seed` (recent projects, one of them gone), `sp-close`, `sp-open:<dir>`, `newproject:<name>`,
	/// `docs-open:<File.md>[#heading]`, `docs-search:<text>`, `docs-scroll:<pixels>`, `docs-image:<images/name.png>`,
	/// `docs-image-close`, `docs-close`.
	extension EditorApp
	{
		int mSpStep;
		int mSpWait;
		int mSpFrames;
		String mSpScratch = new .() ~ delete _;
		String mSpAlpha = new .() ~ delete _;
		String mSpBeta = new .() ~ delete _;
		bool mSpDocImageClose;
		bool mSpFileMenu;
		/// `sp-cancel`: the unsaved-changes question is answered Cancel on its next frame.
		bool mSpSwitchClose;
		DocItem mSpLink;

		void SpScratch()
		{
			if (!mSpScratch.IsEmpty)
				return;
			AppPaths.Root(mSpScratch);
			mSpScratch.AppendF("{}sp-scratch", Path.DirectorySeparatorChar);
			AppPaths.EnsureDir(mSpScratch);
		}

		static bool SpUnder(StringView path, StringView dir) => IsUnder(path, dir) || ProjectIndex.SamePath(path, dir);

		bool SpAllDocsUnder(StringView dir)
		{
			for (let d in mDocs)
				if (!SpUnder(d.FilePath, dir))
					return false;
			for (let t in Tabs)
				if (!SpUnder(t.Doc.FilePath, dir))
					return false;
			return true;
		}

		static bool SpFileHas(StringView path, StringView needle)
		{
			String text = scope .();
			return File.ReadAllText(path, text, true) case .Ok && text.Contains(needle);
		}

		/// True when `n` frames have passed since the last call that returned false with a new count.
		bool SpWaitFrames(int n)
		{
			if (mSpFrames < n)
			{
				mSpFrames++;
				return false;
			}
			mSpFrames = 0;
			return true;
		}

		bool SelfTestStartPage()
		{
			SpScratch();
			String p = scope .();
			switch (mSpStep)
			{
			case 0:
				// A start without a project shows the start page and reopens nothing.
				if (!SpWaitFrames(4))
					return false;
				SelfTestCheck(StartPageVisible && mProjectRoot.IsEmpty && Doc == mEmptyDoc && Tabs.IsEmpty && mDocs.IsEmpty, "startpage 1: started without a project: the start page shows, nothing is reopened");
				SelfTestCheck(mStartPageWasVisible && mWindowTitle == scope $"{VisualBeefInfo.Name} {VisualBeefInfo.Channel}", scope $"startpage 2: the start page was drawn and the window title is the product name ('{mWindowTitle}')");
				SelfTestCheck(Recent.Items.IsEmpty && mStartRows == 0, "startpage 3: a fresh data folder has no recent projects");
				// File > New Project: the typed name is the folder.
				CreateProject("Alpha One", 0, mSpScratch, false);
				mSpAlpha.Set(mSpScratch);
				mSpAlpha.AppendF("{}Alpha One", Path.DirectorySeparatorChar);
				SelfTestCheck(Directory.Exists(mSpAlpha), scope $"startpage 4: the folder is named as typed: {mSpAlpha}");
				String toml = scope .();
				String ws = scope .();
				String program = scope .();
				File.ReadAllText(scope $"{mSpAlpha}{Path.DirectorySeparatorChar}BeefProj.toml", toml, true).IgnoreError(); // a missing file fails the checks below
				File.ReadAllText(scope $"{mSpAlpha}{Path.DirectorySeparatorChar}BeefSpace.toml", ws, true).IgnoreError();
				File.ReadAllText(scope $"{mSpAlpha}{Path.DirectorySeparatorChar}src{Path.DirectorySeparatorChar}Program.bf", program, true).IgnoreError();
				SelfTestCheck(toml.Contains("Name = \"Alpha One\"") && toml.Contains("StartupObject = \"AlphaOne.Program\""), "startpage 5: BeefProj.toml names the project 'Alpha One' (its namespace AlphaOne)");
				SelfTestCheck(ws.Contains("\"Alpha One\" = {Path = \".\"}") && ws.Contains("StartupProject = \"Alpha One\""), "startpage 6: BeefSpace.toml uses the same name, in the folder of the project");
				SelfTestCheck(program.Contains("namespace AlphaOne") && program.Contains("Hello from Alpha One"), "startpage 7: Program.bf is in namespace AlphaOne and greets 'Alpha One'");
				SelfTestCheck(mProjectRoot == mSpAlpha && !StartPageVisible, "startpage 8: the new project is the open project (the start page is gone)");
				SelfTestCheck(Recent.Items.Count == 1 && Recent.Items[0].Name == "Alpha One" && Recent.Items[0].Path == mSpAlpha, "startpage 9: it heads the recent list");
				SelfTestCheck(mDocs.Count == 1 && Tabs.Count == 1 && SpAllDocsUnder(mSpAlpha), "startpage 10: Program.Main is open in a Sheet");
				mSpStep = 1;
				mSpFrames = 0;
			case 1:
				if (!SpWaitFrames(4))
					return false;
				// The index of the new project has arrived (the editor waits for it before this step).
				SelfTestCheck(ProjectIndex.SamePath(Index.Root, mSpAlpha) && Index.Files.Count == 1 && SpUnder(Index.Files[0].Path, mSpAlpha), scope $"startpage 11: the index holds only the new project ({Index.Files.Count} file)");
				SelfTestCheck(mCBTree != null && ProjectIndex.SamePath(mCBTree.Path, mSpAlpha) && SpUnder(mCBFolder, mSpAlpha), "startpage 12: the Project Browser shows the new project's folder");
				SelfTestCheck(mWindowTitle.Contains("Alpha One"), scope $"startpage 13: the window title names the project ('{mWindowTitle}')");
				// Unsaved changes in Alpha One, then File > New Project 'Beta'.
				String text = scope .(Doc.Text);
				text.Append("// edited in Alpha One\n");
				Doc.ApplyText(text);
				SelfTestCheck(Doc.Modified && ModifiedCount == 1, "startpage 14: the open file has an unsaved change");
				CreateProject("Beta", 0, mSpScratch, false);
				mSpBeta.Set(mSpScratch);
				mSpBeta.AppendF("{}Beta", Path.DirectorySeparatorChar);
				SelfTestCheck(Directory.Exists(mSpBeta) && mProjectRoot == mSpAlpha && mShowSwitchModal, "startpage 15: with unsaved changes the project is made but the switch waits for the answer");
				SelfTestCheck(Recent.Items.Count == 2 && Recent.Items[0].Name == "Beta", "startpage 16: the new project is already in the recent list, ahead of the open one");
				mSpStep = 2;
				mSpFrames = 0;
			case 2:
				// Let the question draw (two frames), then answer Don't Save.
				if (!SpWaitFrames(3))
					return false;
				SelfTestCheck(FinishSwitch(false), "startpage 17: Don't Save closes Alpha One and opens Beta");
				SelfTestCheck(mProjectRoot == mSpBeta && !mShowSwitchModal, "startpage 18: the workspace root is the new project's folder");
				SelfTestCheck(mDocs.Count == 1 && Tabs.Count == 1 && SpAllDocsUnder(mSpBeta) && !Doc.Modified, scope $"startpage 19: the old project's file and Sheet are closed; only Beta's Program.Main is open ({mDocs.Count} file)");
				SelfTestCheck(!SpFileHas(scope $"{mSpAlpha}{Path.DirectorySeparatorChar}src{Path.DirectorySeparatorChar}Program.bf", "edited in Alpha One"), "startpage 20: Don't Save left Alpha One's file as it was");
				SelfTestCheck(mCBTree != null && ProjectIndex.SamePath(mCBTree.Path, mSpBeta) && SpUnder(mCBFolder, mSpBeta), "startpage 21: the Project Browser's folder tree follows to Beta");
				SelfTestCheck(mWindowTitle.Contains("Beta") && !mWindowTitle.Contains("Alpha"), scope $"startpage 22: the window title follows ('{mWindowTitle}')");
				SelfTestCheck(Recent.Items.Count == 2 && Recent.Items[0].Name == "Beta" && Recent.Items[1].Name == "Alpha One", "startpage 23: the recent list is Beta, Alpha One");
				mSpStep = 3;
				mSpFrames = 0;
			case 3:
				if (!SpWaitFrames(4))
					return false;
				SelfTestCheck(ProjectIndex.SamePath(Index.Root, mSpBeta) && Index.Files.Count == 1 && SpUnder(Index.Files[0].Path, mSpBeta), "startpage 24: the Outline's index holds Beta only");
				// Unsaved change in Beta, open Alpha One from the list, Save All.
				String text = scope .(Doc.Text);
				text.Append("// edited in Beta\n");
				Doc.ApplyText(text);
				SelfTestCheck(RequestOpenProject(mSpAlpha) && mShowSwitchModal && mProjectRoot == mSpBeta, "startpage 25: opening a project from the list with unsaved changes asks first");
				mSpStep = 4;
				mSpFrames = 0;
			case 4:
				if (!SpWaitFrames(3))
					return false;
				SelfTestCheck(FinishSwitch(true) && mProjectRoot == mSpAlpha, "startpage 26: Save All writes Beta's change and opens Alpha One");
				SelfTestCheck(SpFileHas(scope $"{mSpBeta}{Path.DirectorySeparatorChar}src{Path.DirectorySeparatorChar}Program.bf", "edited in Beta"), "startpage 27: Beta's file kept the edit");
				SelfTestCheck(Recent.Items[0].Name == "Alpha One" && Recent.Items[1].Name == "Beta", "startpage 28: opened from the list, it moves to the top");
				// Close Project.
				SelfTestCheck(mDocs.IsEmpty || SpAllDocsUnder(mSpAlpha), "startpage 29: nothing of Beta stays open");
				RequestCloseProject();
				SelfTestCheck(StartPageVisible && mProjectRoot.IsEmpty && mDocs.IsEmpty && Tabs.IsEmpty && Doc == mEmptyDoc && mCBTree == null, "startpage 30: Close Project returns to the start page with nothing open");
				mSpStep = 5;
				mSpFrames = 0;
			case 5:
				if (!SpWaitFrames(4))
					return false;
				SelfTestCheck(Index.Files.IsEmpty && mWindowTitle == scope $"{VisualBeefInfo.Name} {VisualBeefInfo.Channel}", scope $"startpage 31: the index is empty and the title is the product name again ('{mWindowTitle}')");
				// The list is in settings.json, and loads back in the same order.
				String settings = scope .();
				Settings.GetPath(p);
				File.ReadAllText(p, settings, true).IgnoreError(); // a missing file fails the check below
				SelfTestCheck(settings.Contains("\"recentProjects\"") && settings.Contains("Alpha One") && settings.Contains("Beta"), "startpage 32: the recent list is saved in the preferences (settings.json)");
				ClearAndDeleteItems!(mRecent.Items);
				mRecentLoaded = false;
				SelfTestCheck(Recent.Items.Count == 2 && Recent.Items[0].Name == "Alpha One" && Recent.Items[1].Name == "Beta", "startpage 33: it loads back as it was");
				// A folder that is gone.
				String gone = scope $"{mSpScratch}{Path.DirectorySeparatorChar}Old Prototype";
				Directory.CreateDirectory(gone).IgnoreError(); // exists already on a rerun
				RememberProject(gone);
				Directory.DelTree(gone).IgnoreError(); // best effort; the check below says whether it is gone
				SelfTestCheck(!Directory.Exists(gone) && Recent.Items.Count == 3, "startpage 34: a listed folder that was deleted afterwards");
				mSpStep = 6;
				mSpFrames = 0;
			case 6:
				if (!SpWaitFrames(4))
					return false;
				SelfTestCheck(mStartRows == 3 && mStartMissingRows == 1, scope $"startpage 35: the start page lists 3 rows, 1 of them dimmed as missing ({mStartRows}, {mStartMissingRows})");
				String gone = scope $"{mSpScratch}{Path.DirectorySeparatorChar}Old Prototype";
				SelfTestCheck(!RequestOpenProject(gone) && StartPageVisible, "startpage 36: a missing folder does not open");
				ForgetRecentProject(gone);
				SelfTestCheck(Recent.Items.Count == 2 && Recent.Find(gone) == null, "startpage 37: Remove takes it off the list");
				// The New Project dialog: the line that says where it goes.
				StartNewProject();
				mNPName.Set("My Game");
				mNPLocation.Set(mSpScratch);
				mSpStep = 7;
				mSpFrames = 0;
			case 7:
				if (!SpWaitFrames(4))
					return false;
				String dir = scope .();
				NewProjectDirFor("My Game", mSpScratch, dir);
				SelfTestCheck(dir == scope $"{mSpScratch}{Path.DirectorySeparatorChar}My Game", scope $"startpage 38: 'My Game' creates {dir}");
				dir.Clear();
				NewProjectDirFor("  Q: Z? /a  ", mSpScratch, dir);
				SelfTestCheck(dir == scope $"{mSpScratch}{Path.DirectorySeparatorChar}Q Z a", scope $"startpage 39: only what the file system forbids is dropped ('  Q: Z? /a  ' -> {dir})");
				SelfTestCheck(mNPName.View == "My Game" && !mOpenNewProject, "startpage 40: the dialog started with the name typed and nothing before it");
				mSelfTestClosePopups = true;
				mSpStep = 8;
				mSpFrames = 0;
			case 8:
				if (!SpWaitFrames(3))
					return false;
				// A project with a space in its name compiles (BeefBuild is given the workspace as ".").
				SelfTestCheck(RequestOpenProject(mSpAlpha) && mProjectRoot == mSpAlpha, "startpage 41: Alpha One opened from the list");
				mSpStep = 9;
				mSpFrames = 0;
			case 9:
				if (!SpWaitFrames(2))
					return false;
				Compile();
				StringView command = (mBuild != null) ? (StringView)mBuild.CommandLine : "none";
				SelfTestCheck(mBuild != null && mBuild.CommandLine.Contains("-workspace=."), scope $"startpage 42: the compile of a folder with a space starts (BeefBuild command: {command})");
				mSpStep = 10;
				mSpFrames = 0;
			case 10:
				if (mBuild != null && (mBuild.Running || mSpFrames++ < 30))
					return false;
				StringView outcome = (mBuild == null) ? "no build" : (mBuild.Succeeded ? "succeeded" : "failed");
				SelfTestCheck(mBuild != null && !mBuild.Running && mBuild.Succeeded, scope $"startpage 43: the project 'Alpha One' compiles ({outcome})");
				mSpStep = 0;
				return true;
			default:
				mSpStep = 0;
				return true;
			}
			return false;
		}

		/// `projectarg` (VB_SELFTEST=projectarg, started with a project folder on the command line): the project opens directly, the
		/// start page never shows, and the project heads the recent list.
		bool SelfTestProjectArg()
		{
			if (!SpWaitFrames(4))
				return false;
			SelfTestCheck(!mProjectRoot.IsEmpty && !StartPageVisible && !mStartPageWasVisible, scope $"projectarg 1: the project on the command line opened directly, the start page never showed ({mProjectRoot})");
			SelfTestCheck(Recent.Items.Count >= 1 && ProjectIndex.SamePath(Recent.Items[0].Path, mProjectRoot), "projectarg 2: it heads the recent list");
			SelfTestCheck(mWindowTitle.Contains("Program") || mWindowTitle.Contains(Path.GetFileName(mProjectRoot, .. scope String())), scope $"projectarg 3: the window title follows ('{mWindowTitle}')");
			return true;
		}

		bool SelfTestDocs()
		{
			switch (mSpStep)
			{
			case 0:
				LoadDocs();
				let lib = mDocLib;
				SelfTestCheck(lib.Pages.Count >= 8 && !lib.Dir.IsEmpty, scope $"docs 1: {lib.Pages.Count} user pages loaded from {lib.Dir}");
				SelfTestCheck(lib.FindByFile("Getting-Started.md") != null && lib.FindByFile("Architecture.md") == null && lib.FindByFile("Testing.md") == null, "docs 2: the guide is there, the developer pages are not");
				OpenDocumentation();
				SelfTestCheck(mShowDocs && mDocPage != null && mDocPage.FileName == "Getting-Started.md", "docs 3: Help > Documentation opens on Getting started");
				mSpStep = 1;
				mSpFrames = 0;
			case 1:
				if (!SpWaitFrames(4))
					return false;
				SelfTestCheck(mDocLayout != null && mDocLayout.Page == mDocPage && mDocLayout.Height > 800 && mDocLayout.Items.Count > 200, scope $"docs 4: the page is laid out ({(mDocLayout != null ? mDocLayout.Items.Count : 0)} pieces, {(mDocLayout != null ? (int)mDocLayout.Height : 0)} px)");
				// A page with pictures.
				ShowDocPage(mDocLib.FindByFile("Classes-and-Members.md"), "", true);
				mSpStep = 2;
				mSpFrames = 0;
			case 2:
				if (!SpWaitFrames(4))
					return false;
				int images = 0;
				int decoded = 0;
				if (mDocLayout != null)
					for (let it in mDocLayout.Items)
						if (it.Kind == .Image)
						{
							images++;
							if (it.Image != null && !it.Image.Failed && it.Image.Tex != 0 && it.Image.Width > 100)
								decoded++;
						}
#if BF_PLATFORM_WINDOWS
				SelfTestCheck(images >= 3 && decoded == images, scope $"docs 5: the page's {images} pictures were decoded and uploaded ({decoded})");
#else
				SelfTestCheck(images >= 3, scope $"docs 5: the page has {images} pictures (shown as labelled boxes on this platform)");
#endif
				// Back to Getting started and an internal link.
				ShowDocPage(mDocLib.FindByFile("Getting-Started.md"), "", false);
				mDocBack.Clear();
				mSpLink = null;
				mSpStep = 3;
				mSpFrames = 0;
			case 3:
				if (!SpWaitFrames(4))
					return false;
				DocItem pageLink = null;
				String missingText = scope .();
				if (mDocLayout != null)
					for (let it in mDocLayout.Items)
					{
						if (!it.HasLink)
							continue;
						if (it.LinkKind == .Page && pageLink == null && it.Link.EndsWith(".md"))
							pageLink = it;
						if (it.LinkKind == .Missing && missingText.IsEmpty)
							missingText.Set(it.Link);
					}
				SelfTestCheck(pageLink != null, "docs 6: Getting started has a link to another page");
				SelfTestCheck(!missingText.IsEmpty, "docs 7: a link to a page that is not shipped is marked (dimmed, nothing happens on a click)");
				if (pageLink != null)
				{
					String linkText = scope .(pageLink.Link);
					String slug = scope .();
					DocPage expected = null;
					mDocLib.Resolve(mDocPage, linkText, out expected, slug);
					DocFollow(pageLink);
					StringView shownFile = (mDocPage != null) ? (StringView)mDocPage.FileName : "";
					SelfTestCheck(expected != null && mDocPage == expected, scope $"docs 8: following '{linkText}' shows {shownFile}");
					SelfTestCheck(mDocBack.Count == 1, "docs 9: Back remembers the page left");
					DocGoBack();
					SelfTestCheck(mDocPage.FileName == "Getting-Started.md" && mDocBack.IsEmpty, "docs 10: Back returns to Getting started");
				}
				if (!missingText.IsEmpty)
				{
					let before = mDocPage;
					DocItem missing = scope .(); // the layout was rebuilt by Back: a stand-in for the click
					missing.Link.Set(missingText);
					DocFollow(missing);
					SelfTestCheck(mDocPage == before, "docs 11: a link to a page that is not shipped changes nothing");
				}
				mSpStep = 4;
				mSpFrames = 0;
			case 4:
				// A heading far down a page: the scroll follows it.
				let page = mDocLib.FindByFile("Editor-UI.md");
				DocBlock target = null;
				int seen = 0;
				for (let b in page.Blocks)
					if (b.Kind == .Heading && b.Level == 2 && ++seen == 6)
						target = b;
				SelfTestCheck(target != null, "docs 12: Editor interface has headings to jump to");
				if (target != null)
					ShowDocPage(page, target.Slug, true);
				mSpStep = 5;
				mSpFrames = 0;
			case 5:
				if (!SpWaitFrames(6))
					return false;
				SelfTestCheck(mDocScrollNow > 200, scope $"docs 13: the page scrolled to the heading ({(int)mDocScrollNow} px)");
				mDocSearch.Set("install");
				mSpStep = 6;
				mSpFrames = 0;
			case 6:
				if (!SpWaitFrames(3))
					return false;
				SelfTestCheck(!mDocHits.IsEmpty && mDocHits[0].Page != null, scope $"docs 14: searching 'install' finds {mDocHits.Count} places");
				bool headingHit = false;
				for (let h in mDocHits)
					if (h.Heading != null)
						headingHit = true;
				SelfTestCheck(headingHit, "docs 15: the results include headings");
				mDocSearch.Set("zzzzqq");
				mSpStep = 7;
				mSpFrames = 0;
			case 7:
				if (!SpWaitFrames(3))
					return false;
				SelfTestCheck(mDocHits.IsEmpty && mDocSearchActive, "docs 16: a search with no match shows nothing");
				mDocSearch.Set("");
				mSpStep = 8;
				mSpFrames = 0;
			case 8:
				if (!SpWaitFrames(3))
					return false;
				SelfTestCheck(!mDocSearchActive && mDocHits.IsEmpty, "docs 17: clearing the search brings back the page list");
				mShowDocs = false;
				mSpStep = 0;
				return true;
			default:
				mSpStep = 0;
				return true;
			}
			return false;
		}

		/// The folder a New Project dialog entry creates: `<location>\<name as the file system allows it>`.
		static void NewProjectDirFor(StringView typed, StringView location, String outDir)
		{
			String loc = scope .(location);
			loc.Trim();
			TrimSeparators(loc);
			String folder = scope .();
			ProjectFolderName(typed, folder);
			JoinPath(loc, folder, outDir);
		}

		/// The `sp-*`, `newproject:` and `docs-*` steps of capture runs. True when `test` was one of them.
		bool SelfTestStartPageStep(StringView test)
		{
			if (test == "sp-seed")
			{
				// Recent projects for a capture: two folders that exist, a few that were opened a while ago, one that is gone.
				SpScratch();
				LoadRecentProjects();
				ClearAndDeleteItems!(mRecent.Items);
				StringView[4] names = .("Space Shooter", "Alpha One", "Level Tools", "Old Prototype");
				int64[4] ages = .(25 * 60, 3 * 3600, 3 * 86400, 40 * 86400);
				for (int i = names.Count - 1; i >= 0; i--)
				{
					String dir = scope $"{mSpScratch}{Path.DirectorySeparatorChar}{names[i]}";
					if (i != 3)
						Directory.CreateDirectory(dir).IgnoreError(); // exists on a rerun
					mRecent.Touch(dir, UnixNow() - ages[i]);
				}
				SaveRecentProjects();
				SelfTestCheck(mRecent.Items.Count == 4, "sp-seed: 4 recent projects, the last one's folder is not there");
				return true;
			}
			if (test == "sp-cancel")
			{
				mSpSwitchClose = true;
				return true;
			}
			if (test == "filemenu") // the File menu open (captures)
			{
				mSpFileMenu = true;
				return true;
			}
			if (test == "sp-close")
			{
				RequestCloseProject();
				return true;
			}
			if (test == "sp-dirty") // an unsaved change in the open file (captures of the unsaved-changes question)
			{
				String text = scope .(Doc.Text);
				text.Append("// edited");
				text.Append((char8)10);
				Doc.ApplyText(text);
				return true;
			}
			if (test.StartsWith("sp-switch:")) // open the seeded project of that name
			{
				SpScratch();
				RequestOpenProject(scope $"{mSpScratch}{Path.DirectorySeparatorChar}{test.Substring(10)}");
				return true;
			}
			if (test.StartsWith("sp-open:"))
			{
				RequestOpenProject(test.Substring(8));
				return true;
			}
			if (test.StartsWith("newproject:"))
			{
				SpScratch();
				StartNewProject();
				mNPName.Set(test.Substring(11));
				mNPLocation.Set(mSpScratch);
				return true;
			}
			if (test.StartsWith("docs-open:"))
			{
				var spec = test.Substring(10);
				int hash = spec.IndexOf('#');
				if (hash >= 0)
					OpenDocumentation(spec.Substring(0, hash), spec.Substring(hash + 1));
				else
					OpenDocumentation(spec);
				return true;
			}
			if (test.StartsWith("docs-search:"))
			{
				LoadDocs();
				mShowDocs = true;
				mDocSearch.Set(test.Substring(12));
				return true;
			}
			if (test.StartsWith("docs-scroll:"))
			{
				mDocScrollTo = (float)float.Parse(test.Substring(12)).GetValueOrDefault();
				return true;
			}
			if (test.StartsWith("docs-image:"))
			{
				mDocImageView.Set(test.Substring(11));
				mDocImageOpen = true;
				return true;
			}
			if (test == "docs-image-close")
			{
				mSpDocImageClose = true;
				return true;
			}
			if (test == "docs-close")
			{
				mShowDocs = false;
				return true;
			}
			return false;
		}
	}
}
