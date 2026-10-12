using System;
using System.IO;
using System.Collections;
using System.Diagnostics;
using VisualBeef.Catalog;
using VisualBeef.Document;
using VisualBeef.Update;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests host [-lib <dir>]`: the host contract (docs/Host-Integration.md): the command line
	/// (EditorArgs, the deprecated option mapped for one release), the project manifest (`.vbproject`,
	/// ProjectManifest) and target resolution (ProjectContract), templates (`template.json`, ProjectKind) with the
	/// fixture in VisualBeefTests/fixtures/Host/Template, attribute-declared node libraries (the Fixture Kit
	/// fixture: `[NodeLibrary]`, `[CallbackNode]`, `[NodeHidden]` declared by the library itself), generated
	/// libraries reached through dependency paths, the manifest's own libraries, a copy installed by a host
	/// (`host-install.json`), and with `-lib` any large generated library as a node library (timings, counts).
	static class HostTests
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

		static void FixtureDir(StringView name, String outDir, String here = Compiler.CallerFilePath)
		{
			String src = scope .();
			Path.GetDirectoryPath(here, src).IgnoreError(); // ...\VisualBeefTests\src
			String tests = scope .();
			Path.GetDirectoryPath(src, tests).IgnoreError();
			outDir.AppendF("{0}{1}fixtures{1}Host{1}{2}", tests, Path.DirectorySeparatorChar, name);
		}

		static void ScratchDir(StringView name, String outDir)
		{
			String tmp = scope .();
			Path.GetTempPath(tmp).IgnoreError(); // falls back to a relative folder
			outDir.AppendF("{}VisualBeefHostTests{}{}", tmp, Path.DirectorySeparatorChar, name);
#if BF_PLATFORM_WINDOWS
			outDir.Replace('/', '\\');
#endif
			if (Directory.Exists(outDir))
				Directory.DelTree(outDir).IgnoreError();
			Directory.CreateDirectory(outDir).IgnoreError();
		}

		static void Touch(StringView path, StringView text)
		{
			String dir = scope .();
			Path.GetDirectoryPath(path, dir).IgnoreError();
			Directory.CreateDirectory(dir).IgnoreError();
			File.WriteAllText(path, text).IgnoreError();
		}

		static String ReadText(StringView path, String outText)
		{
			File.ReadAllText(path, outText).IgnoreError();
			return outText;
		}

		static void ParseArgs(EditorArgs a, params String[] args)
		{
			EditorArgs.Parse(args, a);
		}

		static StringView VarOf(EditorArgs a, StringView key)
		{
			for (let v in a.Vars)
				if (v.key == key)
					return v.value;
			return default;
		}

		// ------------------------------------------------------------------ command line

		static void ArgTests()
		{
			Console.WriteLine("command line");
			{
				EditorArgs a = scope .();
				ParseArgs(a);
				Check(a.Action == .Open && a.IsEmpty, "no arguments: open, restore the last session");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--version");
				String line = scope .();
				VisualBeefInfo.VersionLine(line);
				Check(a.Action == .PrintVersion && line.EndsWith(scope $"(host contract {VisualBeefInfo.HostContract})") && VisualBeefInfo.HostContract == 1,
					scope $"--version prints '{line}'");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--help");
				Check(a.Action == .PrintHelp && EditorArgs.Usage.Contains("--new-from-template") && !EditorArgs.Usage.Contains(EditorArgs.DeprecatedNewOption),
					"--help lists --new-from-template, not the deprecated option");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Work\\Tool", "--file", "src\\Program.bf", "--view");
				Check(a.Action == .Open && a.Path == "D:\\Work\\Tool" && a.File == "src\\Program.bf" && a.View, "folder, --file, --view");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--new-from-template", "D:\\T", "D:\\Out\\Tool", "--name", "Hello Tool", "--var", "Id=hello", "--var", "Version=1.2.3", "--var", "Id=again", "--no-open");
				Check(a.Action == .Open && a.NewFromTemplate && a.TemplateDir == "D:\\T" && a.Destination == "D:\\Out\\Tool" && a.Name == "Hello Tool" && a.NoOpen && !a.KeepExisting &&
					a.Vars.Count == 2 && VarOf(a, "Id") == "again" && VarOf(a, "Version") == "1.2.3", "--new-from-template with --name, --var (the last value wins) and --no-open");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--new-from-template", "D:\\T");
				Check(a.Action == .Usage && a.Error.Contains("destination"), "--new-from-template needs two folders");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--new-from-template", "D:\\T", "D:\\Out", "--var", "no-equals");
				Check(a.Action == .Usage && a.Error.Contains("KEY=VALUE"), "--var without KEY=VALUE is a usage error");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\x", "--new-from-template", "D:\\T", "D:\\Out");
				Check(a.Action == .Usage, "--new-from-template with another folder to open is a usage error");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\x", "--var", "A=1");
				Check(a.Action == .Usage && a.Error.Contains("--new-from-template"), "--var without --new-from-template is a usage error");
			}
			{
				// The deprecated option of contract 1, kept for one release: without a template folder it writes nothing and opens.
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Work\\Tool", EditorArgs.DeprecatedNewOption, "--namespace", "MyTool", "--class", "ToolMain", "--mod-id", "my-tool", "--mod-name", "My Tool", "--version", "1.2.3", "--game", "some-host");
				Check(a.Action == .Open && !a.NewFromTemplate && a.Path == "D:\\Work\\Tool" && a.Deprecation.Contains("deprecated") && a.Deprecation.Contains("--new-from-template") &&
					VarOf(a, "ModId") == "my-tool" && VarOf(a, "ModName") == "My Tool" && VarOf(a, "Version") == "1.2.3" && VarOf(a, "Namespace") == "MyTool" && VarOf(a, "Class") == "ToolMain" && VarOf(a, "GameId") == "some-host",
					"the deprecated option: a deprecation line, its values as template variables, the folder opened");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Work\\Tool", EditorArgs.DeprecatedNewOption, "--mod-id", "my-tool", "--template", "D:\\T");
				Check(a.Action == .Open && a.NewFromTemplate && a.KeepExisting && a.TemplateDir == "D:\\T" && a.Destination == "D:\\Work\\Tool" && a.Path.IsEmpty && a.Name == "my-tool",
					"the deprecated option with --template: --new-from-template into the folder, existing files kept");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Work\\Tool", EditorArgs.DeprecatedNewOption, "--version");
				Check(a.Action == .PrintVersion, "--version with no value prints the version even after the deprecated option");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Work\\Tool", EditorArgs.DeprecatedNewOption);
				Check(a.Action == .Usage && a.Error.Contains("--mod-id"), "the deprecated option keeps its usage errors (no --mod-id: exit 2)");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--bogus");
				Check(a.Action == .Usage && a.Error.Contains("--bogus"), "unknown option");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\a", "D:\\b");
				Check(a.Action == .Usage, "two paths");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\a", "--file");
				Check(a.Action == .Usage && a.Error.Contains("--file"), "--file without a value");
			}
			Check(EditorArgs.ExitOk == 0 && EditorArgs.ExitFailed == 1 && EditorArgs.ExitUsage == 2, "exit codes 0 / 1 / 2");
		}

		// ------------------------------------------------------------------ project manifest

		static void ManifestTests()
		{
			Console.WriteLine("project manifest (.vbproject)");
			ProjectManifest m = scope .();
			String err = scope .();
			// A host's own keys (ids it keeps for itself) are ignored; a BOM is fine.
			Check(m.Parse("\xEF\xBB\xBF{\"vbproject\": 1, \"kind\": \"tool\", \"main\": \"src\\\\Main.bf\", \"configuration\": \"Release\", \"host\": \"Some Host\", \"hostId\": 7, " +
				"\"attach\": {\"module\": \"Runtime.dll\", \"hint\": \"Start it.\"}, \"libraries\": [\"../Kit\", \"D:/Abs/Lib\"]}", err) && m.Present,
				scope $"parses, unknown keys ignored {err}");
			Check(m.Kind == "tool" && m.Main == "src/Main.bf" && m.Configuration == "Release" && m.Host == "Some Host" && m.AttachModule == "Runtime.dll" && m.AttachHint == "Start it." &&
				m.Libraries.Count == 2, "every key read (main with /)");
			String text = scope .();
			m.Write(text);
			ProjectManifest back = scope .();
			Check(back.Parse(text, err) && back.Main == m.Main && back.AttachModule == m.AttachModule && back.Libraries.Count == 2 && back.Libraries[1] == "D:/Abs/Lib" && text.StartsWith("{\n  \"vbproject\": 1"),
				"written and read back the same");
			Check(!m.Parse("[1, 2]", err) && err.Contains("object"), "an array is refused");
			Check(!m.Parse("{\"main\": ", err) && err.Contains("JSON"), "broken JSON is refused");
			m.Parse("{\"main\": \"../../evil.bf\"}", err);
			Check(m.Main.IsEmpty, "a main outside the project is ignored");
			m.Parse("{\"main\": \"C:/evil.bf\"}", err);
			Check(m.Main.IsEmpty, "a rooted main is ignored");

			// Library folders are written relative to the project (the relative-paths rule).
			String rel = scope .();
#if BF_PLATFORM_WINDOWS
			Check(ProjectManifest.MakeRelative("D:\\Work\\Tool", "D:/Work/Kits/Lib", rel) && rel == "../Kits/Lib", scope $"a library beside the project: ../Kits/Lib ({rel})");
			Check(ProjectManifest.MakeRelative("D:\\Work\\Tool\\", "d:\\work\\tool\\libs\\Kit", rel) && rel == "libs/Kit", scope $"inside the project, another case: libs/Kit ({rel})");
			Check(!ProjectManifest.MakeRelative("D:\\Work\\Tool", "E:/Kits/Lib", rel), "another drive has no relative form (kept absolute)");
			Check(!ProjectManifest.MakeRelative("\\\\server\\share\\Tool", "\\\\other\\share\\Lib", rel), "another network share has no relative form");
#else
			Check(ProjectManifest.MakeRelative("/home/a/Tool", "/home/a/Kits/Lib", rel) && rel == "../Kits/Lib", scope $"a library beside the project: ../Kits/Lib ({rel})");
			Check(ProjectManifest.MakeRelative("/home/a/Tool/", "/home/a/Tool/libs/Kit", rel) && rel == "libs/Kit", scope $"inside the project: libs/Kit ({rel})");
#endif
			Check(!ProjectManifest.MakeRelative("Tool", "Kits/Lib", rel), "paths that are not rooted are not made relative");
		}

		static void ProjectTests()
		{
			Console.WriteLine("project resolution");
			String root = scope .();
			ScratchDir("Resolve", root);
			Touch(scope $"{root}/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"Resolve\"\n");
			Touch(scope $"{root}/src/Main.bf", "namespace Resolve { class Program { } }\n");
			Touch(scope $"{root}/src/Other.bf", "\n");
			String r = scope .();
			String f = scope .();
			String err = scope .();
			Check(ProjectContract.ResolveTarget(root, "", r, f, err) && ProjectIndex.SamePath(r, root) && f.IsEmpty, "a folder without a manifest: root, no file");
			Touch(scope $"{root}/.vbproject", "{\n  \"vbproject\": 1,\n  \"main\": \"src/Main.bf\"\n}\n");
			String file = scope $"{root}/src/Main.bf";
			Check(ProjectContract.ResolveTarget(root, "", r, f, err) && ProjectIndex.SamePath(f, file), "folder with .vbproject: focus its main");
			Check(ProjectContract.ResolveTarget(file, "", r, f, err) && ProjectIndex.SamePath(r, root) && ProjectIndex.SamePath(f, file), ".bf file: the project folder above it, that file");
			Check(ProjectContract.ResolveTarget(scope $"{root}/.vbproject", "", r, f, err) && ProjectIndex.SamePath(r, root) && ProjectIndex.SamePath(f, file), ".vbproject file: its folder");
			Check(ProjectContract.ResolveTarget(scope $"{root}/BeefProj.toml", "", r, f, err) && ProjectIndex.SamePath(r, root), "BeefProj.toml: its folder");
			Check(ProjectContract.ResolveTarget(root, "src/Other.bf", r, f, err) && ProjectIndex.SamePath(f, scope $"{root}/src/Other.bf"), "--file is relative to the project");
			Check(!ProjectContract.ResolveTarget(scope $"{root}/missing", "", r, f, err) && err.Contains("does not exist"), "a missing path is an error");
			File.WriteAllText(scope $"{root}/.vbproject", "{\"main\": \"..\\\\..\\\\evil.bf\"}").IgnoreError();
			String main = scope .();
			Check(!ProjectContract.ReadMarkerMain(root, main), "a manifest main outside the project is ignored");
			Directory.DelTree(root).IgnoreError();
		}

		// ------------------------------------------------------------------ templates

		static void TemplateTests()
		{
			Console.WriteLine("templates (template.json)");
			String tplDir = scope .();
			FixtureDir("Template", tplDir);
			String kitDir = scope .();
			FixtureDir("FixtureKit", kitDir);
			String kitSlashes = scope .(kitDir);
			kitSlashes.Replace('\\', '/');

			TemplateManifest t = scope .();
			String err = scope .();
			Check(t.Load(tplDir, err) && t.Name == "Fixture tool" && t.Host == "Fixture Host" && t.Variables.Count == 2 && t.Files.Count == 4 && t.Main == "src/Program.bf" &&
				t.Configuration == "Release" && t.AttachModule == "FixtureHost.dll" && t.Libraries.Count == 1, scope $"the fixture template loads {err}");
			if (t.Libraries.Count == 1)
				Check(t.Libraries[0].Name == "FixtureKit" && t.Libraries[0].FullPath.Equals(kitSlashes, .OrdinalIgnoreCase), scope $"its library resolves against the template folder: {t.Libraries[0].FullPath}");

			// Names and substitutions.
			String ident = scope .();
			ProjectKind.Identifier("Hello Tool!", ident);
			String digits = scope .();
			ProjectKind.Identifier("3D Kit", digits);
			String slug = scope .();
			ProjectKind.Slug("Cool  Multi-Tool!", slug);
			Check(ident == "HelloTool" && digits == "_3DKit" && slug == "cool-multi-tool", scope $"built-in names: {ident}, {digits}, {slug}");
			Dictionary<String, String> vars = scope .();
			defer ProjectKind.FreeVariables(vars);
			List<(String key, String value)> overrides = scope .();
			defer { for (let o in overrides) { delete o.key; delete o.value; } }
			overrides.Add((new String("Version"), new String("2.0.0")));
			Check(ProjectKind.MakeVariables(t, "D:/Out/HelloTool", "Say \"Hi\" Tool", overrides, vars, err), scope $"variables {err}");
			String outText = scope .();
			Check(ProjectKind.Substitute("@@Name@@|@@Name:str@@|@@Identifier@@|@@Slug@@|@@Folder@@|@@Id@@|@@Version@@|a@@b|mail@@ x", vars, outText, err) case .Ok &&
				outText == "Say \"Hi\" Tool|Say \\\"Hi\\\" Tool|SayHiTool|say-hi-tool|HelloTool|say-hi-tool|2.0.0|a@@b|mail@@ x", scope $"substitutions, :str escaping, a default from a built-in, an override, plain @@ kept: {outText}");
			outText.Clear();
			err.Clear();
			Check(ProjectKind.Substitute("x @@Nope@@ y", vars, outText, err) case .Err && err.Contains("@@Nope@@"), scope $"an unknown key is an error: {err}");

			// Bad template folders say what is wrong.
			String bad = scope .();
			ScratchDir("BadTemplate", bad);
			TemplateManifest tb = scope .();
			err.Clear();
			Check(!tb.Load(bad, err) && err.Contains("template.json"), scope $"no template.json: {err}");
			Touch(scope $"{bad}/template.json", "{\"name\": \"Bad\", \"files\": [\"missing.txt\"]}");
			TemplateManifest tb2 = scope .();
			err.Clear();
			Check(!tb2.Load(bad, err) && err.Contains("missing.txt"), scope $"a listed file that is not there: {err}");
			Touch(scope $"{bad}/template.json", "{\"files\": [{\"from\": \"../escape.txt\", \"to\": \"x\"}]}");
			TemplateManifest tb3 = scope .();
			err.Clear();
			Check(!tb3.Load(bad, err) && err.Contains("inside"), scope $"a path leaving the folder: {err}");
			Touch(scope $"{bad}/template.json", "{\"template\": 2, \"files\": [\"a\"]}");
			TemplateManifest tb4 = scope .();
			err.Clear();
			Check(!tb4.Load(bad, err) && err.Contains("format 2"), scope $"a newer template format: {err}");
			Directory.DelTree(bad).IgnoreError();

			// A project from the fixture.
			String outRoot = scope .();
			ScratchDir("FromTemplate", outRoot);
			String dest = scope $"{outRoot}{Path.DirectorySeparatorChar}HelloTool";
			List<String> created = scope .();
			defer { ClearAndDeleteItems!(created); }
			String main = scope .();
			err.Clear();
			Check(ProjectKind.CreateFromTemplate(tplDir, dest, "Hello Tool", null, .Refuse, created, main, err) && created.Count == 5, scope $"created: {created.Count} files (4 + .vbproject) {err}");
			Check(ProjectIndex.SamePath(main, scope $"{dest}/src/Program.bf") && File.Exists(main), "the main file is the template's main");
			String space = scope .();
			ReadText(scope $"{dest}/BeefSpace.toml", space);
			Check(space.Contains("HelloTool = {Path = \".\"}") && space.Contains(scope $"FixtureKit = {{Path = \"{kitSlashes}\"}}"), "BeefSpace.toml: the project and the library by absolute path with /");
			String program = scope .();
			ReadText(main, program);
			Check(program.Contains("namespace HelloTool") && program.Contains("Console.WriteLine(\"Hello Tool 0.1.0\");") && !program.Contains("@@"), "src/Program.bf: every variable filled in");
			String tool = scope .();
			ReadText(scope $"{dest}/tool.json", tool);
			Check(tool.Contains("\"id\": \"hello-tool\"") && tool.Contains("\"version\": \"0.1.0\""), "tool.json: Id defaults to the slug, Version to 0.1.0");
			ProjectManifest pm = scope .();
			Check(pm.Read(dest) && pm.Kind == "template" && pm.Template == "Fixture tool" && pm.Main == "src/Program.bf" && pm.Configuration == "Release" && pm.Host == "Fixture Host" &&
				pm.AttachModule == "FixtureHost.dll" && pm.Libraries.Count == 1, ".vbproject written from template.json");
			{
				// Relative when the library is on the project's drive, absolute otherwise; either way it resolves to the kit.
				List<String> dirs = scope .();
				defer { ClearAndDeleteItems!(dirs); }
				pm.LibraryDirs(dest, dirs);
				String expect = scope .();
				bool relative = ProjectManifest.MakeRelative(dest, kitSlashes, expect);
				Check(dirs.Count == 1 && ProjectIndex.SamePath(dirs[0], kitDir) && (relative ? pm.Libraries[0] == expect : pm.Libraries[0].Equals(kitSlashes, .OrdinalIgnoreCase)),
					scope $".vbproject names the library {(relative ? "relative to the project" : "by absolute path (another drive)")}: {pm.Libraries[0]}");
			}

			// Never overwritten: .Refuse writes nothing, .Skip keeps the existing files.
			File.WriteAllText(main, "// edited\n").IgnoreError();
			ClearAndDeleteItems!(created);
			main.Clear();
			err.Clear();
			Check(!ProjectKind.CreateFromTemplate(tplDir, dest, "Hello Tool", null, .Refuse, created, main, err) && err.Contains("already exists") && created.IsEmpty &&
				ReadText(scope $"{dest}/src/Program.bf", scope .()) == "// edited\n", scope $"a second project into the folder is refused and changes nothing: {err}");
			File.Delete(scope $"{dest}/tool.json").IgnoreError();
			ClearAndDeleteItems!(created);
			main.Clear();
			Check(ProjectKind.CreateFromTemplate(tplDir, dest, "Hello Tool", null, .Skip, created, main, err) && created.Count == 1 && created[0].EndsWith("tool.json") &&
				ReadText(main, scope .()) == "// edited\n", "keeping existing files: only the missing one is written");

			// A library on the project's drive is written relative and follows a move of both (2026-10-12 audit).
			{
				String top = scope .();
				ScratchDir("RelTpl", top);
				String tpl = scope $"{top}{Path.DirectorySeparatorChar}Template";
				Touch(scope $"{tpl}/files/a.txt", "a\n");
				Touch(scope $"{tpl}/template.json", "{\"template\": 1, \"name\": \"Rel\", \"files\": [\"files/a.txt\"], \"libraries\": [{\"name\": \"Kit\", \"path\": \"../Kit\"}]}");
				Directory.CreateDirectory(scope $"{top}/Kit").IgnoreError();
				String proj = scope $"{top}{Path.DirectorySeparatorChar}Out{Path.DirectorySeparatorChar}Proj";
				List<String> made = scope .();
				defer { ClearAndDeleteItems!(made); }
				String m2 = scope .();
				err.Clear();
				Check(ProjectKind.CreateFromTemplate(tpl, proj, "Proj", null, .Refuse, made, m2, err), scope $"a project from a template whose library is beside it {err}");
				ProjectManifest rm = scope .();
				Check(rm.Read(proj) && rm.Libraries.Count == 1 && rm.Libraries[0] == "../../Kit", scope $".vbproject: the library relative to the project ({(rm.Libraries.Count > 0 ? rm.Libraries[0] : "")})");
				String moved = scope .();
				ScratchDir("RelTplMoved", moved);
				Directory.Delete(moved).IgnoreError();
				Check(Directory.Move(top, moved) case .Ok, "the project and the library move together");
				List<String> dirs = scope .();
				defer { ClearAndDeleteItems!(dirs); }
				ProjectManifest mm = scope .();
				mm.Read(scope $"{moved}/Out/Proj");
				mm.LibraryDirs(scope $"{moved}/Out/Proj", dirs);
				Check(dirs.Count == 1 && Directory.Exists(dirs[0]) && ProjectIndex.SamePath(dirs[0], scope $"{moved}/Kit"), "after the move the library is found where it now is");
				Directory.DelTree(moved).IgnoreError();
			}

			// Creation is all or nothing: a failure removes what the call wrote, so a retry works (2026-10-12 audit).
			{
				String top = scope .();
				ScratchDir("AtomicTpl", top);
				String tpl = scope $"{top}{Path.DirectorySeparatorChar}Template";
				Touch(scope $"{tpl}/files/a.txt", "a\n");
				Touch(scope $"{tpl}/files/b.txt", "b\n");
				Touch(scope $"{tpl}/template.json", "{\"template\": 1, \"name\": \"Atomic\", \"files\": [{\"from\": \"files/a.txt\", \"to\": \"a.txt\"}, {\"from\": \"files/b.txt\", \"to\": \"sub/b.txt\"}]}");
				String proj = scope $"{top}{Path.DirectorySeparatorChar}Proj";
				Touch(scope $"{proj}/sub", "a file where the template needs a folder\n");
				List<String> made = scope .();
				defer { ClearAndDeleteItems!(made); }
				String m2 = scope .();
				err.Clear();
				Check(!ProjectKind.CreateFromTemplate(tpl, proj, "Atomic", null, .Refuse, made, m2, err) && made.IsEmpty && err.Contains("sub"),
					scope $"the second file cannot be written: refused ({err})");
				Check(!File.Exists(scope $"{proj}/a.txt") && !File.Exists(scope $"{proj}/.vbproject"), "the first file it wrote is gone again");
				File.Delete(scope $"{proj}/sub").IgnoreError();
				err.Clear();
				Check(ProjectKind.CreateFromTemplate(tpl, proj, "Atomic", null, .Refuse, made, m2, err) && made.Count == 3, scope $"once the obstacle is gone the same call works ({made.Count} files) {err}");
				// Folders the call made go too: a file named like a folder another file of the template needs.
				String tpl2 = scope $"{top}{Path.DirectorySeparatorChar}Template2";
				Touch(scope $"{tpl2}/files/a.txt", "a\n");
				Touch(scope $"{tpl2}/template.json", "{\"template\": 1, \"name\": \"Clash\", \"files\": [{\"from\": \"files/a.txt\", \"to\": \"x/a.txt\"}, {\"from\": \"files/a.txt\", \"to\": \"x\"}]}");
				String fresh = scope $"{top}{Path.DirectorySeparatorChar}New{Path.DirectorySeparatorChar}Proj";
				ClearAndDeleteItems!(made);
				err.Clear();
				Check(!ProjectKind.CreateFromTemplate(tpl2, fresh, "Clash", null, .Refuse, made, m2, err) && made.IsEmpty, scope $"a template whose files clash is refused ({err})");
				Check(!Directory.Exists(scope $"{top}/New"), "and the folders it made are removed");
				Directory.DelTree(top).IgnoreError();
			}

			// The command line end to end (ProjectContract.WriteFromTemplate).
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--new-from-template", tplDir, scope $"{outRoot}{Path.DirectorySeparatorChar}CliTool", "--name", "Cli Tool", "--var", "Version=9.9.9", "--no-open");
				String r = scope .();
				String f = scope .();
				List<String> lines = scope .();
				defer { ClearAndDeleteItems!(lines); }
				err.Clear();
				let code = ProjectContract.WriteFromTemplate(a, r, f, lines, err);
				String tj = scope .();
				ReadText(scope $"{r}/tool.json", tj);
				Check(code == -1 && lines.Count == 5 && f.EndsWith("Program.bf") && tj.Contains("\"version\": \"9.9.9\"") && tj.Contains("\"id\": \"cli-tool\""), scope $"--new-from-template writes the project ({lines.Count} lines) {err}");
				ClearAndDeleteItems!(lines);
				err.Clear();
				Check(ProjectContract.WriteFromTemplate(a, r, f, lines, err) == EditorArgs.ExitFailed && err.Contains("already exists"), "the same call again: exit 1, nothing written");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--new-from-template", scope $"{outRoot}{Path.DirectorySeparatorChar}NoSuchTemplate", scope $"{outRoot}{Path.DirectorySeparatorChar}X");
				String r = scope .();
				String f = scope .();
				List<String> lines = scope .();
				defer { ClearAndDeleteItems!(lines); }
				err.Clear();
				Check(ProjectContract.WriteFromTemplate(a, r, f, lines, err) == EditorArgs.ExitUsage && err.Contains("does not exist"), "a template folder that does not exist: exit 2");
			}
			{
				// The deprecated option with a template fills an existing folder, keeping its files.
				String old = scope $"{outRoot}{Path.DirectorySeparatorChar}OldTool";
				Touch(scope $"{old}/src/Program.bf", "// the host's own file\n");
				EditorArgs a = scope .();
				ParseArgs(a, old, EditorArgs.DeprecatedNewOption, "--mod-id", "old-tool", "--template", tplDir);
				String r = scope .();
				String f = scope .();
				List<String> lines = scope .();
				defer { ClearAndDeleteItems!(lines); }
				err.Clear();
				let code = ProjectContract.WriteFromTemplate(a, r, f, lines, err);
				Check(code == -1 && ReadText(scope $"{old}/src/Program.bf", scope .()) == "// the host's own file\n" && File.Exists(scope $"{old}/.vbproject") && lines.Count == 4,
					scope $"the deprecated option maps onto the template: the existing file kept, the rest written {err}");
			}
			Directory.DelTree(outRoot).IgnoreError();
		}

		// ------------------------------------------------------------------ libraries

		static void DependencyLibraryTests()
		{
			Console.WriteLine("generated libraries through dependency paths");
			String root = scope .();
			ScratchDir("DepRoot", root);
			// A workspace whose generated library lives under build\ (the project scan skips it) and is reached only
			// through the workspace path, as a host's data folder may hold one.
			String gen = scope $"{root}/build/libs/GenLib";
			Directory.CreateDirectory(scope $"{gen}/src/Generated").IgnoreError();
			File.WriteAllText(scope $"{gen}/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"GenLib\"\nTargetType = \"BeefLib\"\n\n[Dependencies]\ncorlib = \"*\"\n").IgnoreError();
			File.WriteAllText(scope $"{gen}/src/Generated/Engine.g.bf", "namespace Gen { public struct Actor { [Node(Category=\"Actor\")] public void Jump() mut {} } }\n").IgnoreError();
			File.WriteAllText(scope $"{root}/BeefSpace.toml", "FileVersion = 1\n\n[Projects]\nMyTool = {Path = \".\"}\nGenLib = {Path = \"build/libs/GenLib\"}\n").IgnoreError();
			File.WriteAllText(scope $"{root}/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"MyTool\"\nTargetType = \"BeefLib\"\n\n[Dependencies]\ncorlib = \"*\"\nGenLib = \"*\"\n").IgnoreError();

			ProjectIndex index = scope .();
			index.Build(root);
			Check(index.GeneratedLibraries.IsEmpty, "the scan does not reach build\\");
			List<LibraryRef> libs = scope .();
			defer { ClearAndDeleteItems!(libs); }
			LibraryIndex.Discover(root, libs, index.GeneratedLibraries);
			bool found = false;
			for (let l in libs)
				if (l.Name == "GenLib" && ProjectIndex.SamePath(l.Dir, gen))
					found = true;
			Check(found, "a generated library inside the folder, reached through a workspace dependency, loads as a library");

			File.Delete(scope $"{gen}/src/Generated/Engine.g.bf").IgnoreError();
			File.WriteAllText(scope $"{gen}/src/Generated/Engine.bf", "namespace Gen { }\n").IgnoreError();
			ClearAndDeleteItems!(libs);
			LibraryIndex.Discover(root, libs, null);
			found = false;
			for (let l in libs)
				if (l.Name == "GenLib")
					found = true;
			Check(!found, "an ordinary project inside the folder is not loaded as a library");
			File.WriteAllText(scope $"{gen}/.vblibrary", "").IgnoreError();
			ClearAndDeleteItems!(libs);
			LibraryIndex.Discover(root, libs, null);
			found = false;
			for (let l in libs)
				if (l.Name == "GenLib")
					found = true;
			Check(found, "a .vblibrary marker makes it a library");

			String copyDir = scope $"{root}/dist/GenLib";
			Directory.CreateDirectory(scope $"{copyDir}/src").IgnoreError();
			File.WriteAllText(scope $"{copyDir}/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"GenLib\"\nTargetType = \"BeefLib\"\n").IgnoreError();
			List<String> gens = scope .();
			defer { ClearAndDeleteItems!(gens); }
			gens.Add(new String(gen));
			gens.Add(new String(copyDir));
			ClearAndDeleteItems!(libs);
			LibraryIndex.Discover(root, libs, gens);
			int named = 0;
			for (let l in libs)
				if (l.Name == "GenLib")
					named++;
			Check(named == 2, "two generated folders with one project name are both listed (and nothing leaks)");

			// A library only the manifest names (outside the folder, not in the workspace).
			String outside = scope .();
			ScratchDir("ManifestLib", outside);
			File.WriteAllText(scope $"{outside}/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"SideKit\"\nTargetType = \"BeefLib\"\n").IgnoreError();
			String outsideSlashes = scope .(outside);
			outsideSlashes.Replace('\\', '/');
			File.WriteAllText(scope $"{root}/.vbproject", scope $"{{\"vbproject\": 1, \"libraries\": [\"{outsideSlashes}\"]}}").IgnoreError();
			ClearAndDeleteItems!(libs);
			LibraryIndex.Discover(root, libs, null);
			found = false;
			for (let l in libs)
				if (l.Name == "SideKit")
					found = true;
			Check(found, "a library the .vbproject names is loaded although the workspace does not list it");
			// A named folder that does not exist is said, not skipped in silence.
			File.WriteAllText(scope $"{root}/.vbproject", "{\"vbproject\": 1, \"libraries\": [\"../NoSuchKit\"]}").IgnoreError();
			ClearAndDeleteItems!(libs);
			List<String> warnings = scope .();
			defer { ClearAndDeleteItems!(warnings); }
			LibraryIndex.Discover(root, libs, null, warnings);
			Check(warnings.Count == 1 && warnings[0].Contains("NoSuchKit") && warnings[0].Contains("does not exist"), "a library folder the .vbproject names that is missing is reported for the Output Log");
			Directory.DelTree(outside).IgnoreError();
			Directory.DelTree(root).IgnoreError();
		}

		/// The Fixture Kit: a library that declares its own node attributes (no VisualBeefMeta) with
		/// `[NodeLibrary("Fixture Kit")]`, `[CallbackNode]` functions, `[NodeHidden]` and an attributed struct.
		static void NodeLibraryTests()
		{
			Console.WriteLine("attribute-declared node library (Fixture Kit)");
			String kitDir = scope .();
			FixtureDir("FixtureKit", kitDir);
			LibraryRef lib = scope .();
			LibraryIndex.ProjectName(kitDir, lib.Name);
			lib.Dir.Set(kitDir);
			let store = LibraryIndex.Load(lib, false);
			if (store == null)
			{
				Check(false, "Fixture Kit loads");
				return;
			}
			Check(lib.Name == "FixtureKit" && store.UsesNodeAttributes, "the library is attributed (its own attribute types count by name)");
			ProjectIndex empty = scope .();
			TypeService svc = scope .(empty);
			svc.AutoLoadLibraries = false;
			svc.AddLibrary(store);
			svc.Catalog.Refresh();
			let cat = svc.Catalog;
			Dictionary<String, NodeSpec> byMember = scope .();
			defer { for (let kv in byMember) { delete kv.key; delete kv.value; } }
			int callbackFlags = 0;
			for (int si < cat.Stores.Count)
			{
				let sc = cat.Stores[si];
				for (int ei < sc.Entries.Count)
				{
					NodeSpec spec = new .();
					cat.GetSpec(NodeCatalog.MakeId(si, ei), spec);
					if ((sc.Entries[ei].Flags & CatalogEntry.cCallback) != 0)
						callbackFlags++;
					String key = new .(scope $"{spec.OwnerType}.{spec.MemberName}");
					if (byMember.ContainsKey(key))
					{
						delete key;
						delete spec;
					}
					else
						byMember[key] = spec;
				}
			}
			String all = scope .();
			for (let kv in byMember)
				all.AppendF(" {}[{}]", kv.key, kv.value.Category);
			Console.WriteLine("       offered:{}", all);
			let days = Spec(byMember, "Clock.DaysInYear");
			Check(days != null && days.Category == "Fixture Kit" && days.IsPure && days.IsStatic && !days.IsCallback, "[NodeLibrary(\"Fixture Kit\")]: a public static function is a pure node under the library's name");
			let reg = Spec(byMember, "Clock.RegisterDaysInYear");
			Check(reg != null && reg.IsCallback && reg.CallbackRole == "Register" && reg.Category == "Callbacks|Clock" && reg.DisplayName == "Register Days In Year" && !reg.IsPure,
				"[CallbackNode(\"Register Days In Year\", Role=\"Register\")]: a flow node under Callbacks|Clock");
			if (reg != null)
			{
				bool pin = false;
				for (let p in reg.Pins)
					if (p.IsCallback && p.Name == "Callback" && p.Type == "function int32(int32)")
						pin = true;
				Check(pin && reg.CallbackParam == "Callback" && reg.Tooltip.Contains("Registers a callback"), "its function-typed parameter is the callback pin");
			}
			let tryReg = Spec(byMember, "Clock.TryRegisterDaysInYear");
			Check(tryReg != null && tryReg.IsCallback && tryReg.CallbackRole == "Register" && tryReg.Tooltip.StartsWith("Registers the callback; false"), "no Role: Register when there is a callback parameter; the attribute's tooltip first");
			let remove = Spec(byMember, "Clock.RemoveDaysInYear");
			Check(remove != null && remove.IsCallback && remove.CallbackRole == "Remove" && remove.CallbackParam.IsEmpty && remove.Tooltip.Contains("Removes a callback"), "Role=\"Remove\": no callback pin");
			let original = Spec(byMember, "Clock.CallOriginalDaysInYear");
			Check(original != null && original.IsCallback && original.CallbackRole == "Original" && original.Tooltip.Contains("inside the callback"), "Role=\"Original\": the replaced code, used inside the callback");
			Check(callbackFlags == 4, scope $"four catalog rows carry the callback flag ({callbackFlags})");
			Check(Spec(byMember, "Clock.SlotTable") == null, "[NodeHidden] keeps a function out");
			let now = Spec(byMember, "Stamp.Now");
			Check(now != null && now.Category == "Fixture Kit|Time" && now.DisplayName == "Stamp Now" && now.IsPure, "[Node] on a struct of the same library");
			Check(Spec(byMember, "Stamp.Untagged") == null, "an attributed library offers only tagged members");
			List<SearchHit> hits = scope .();
			cat.Search("callback days", hits, 10);
			int cb = 0;
			for (let h in hits)
			{
				NodeSpec spec = scope .();
				cat.GetSpec(h.Id, spec);
				if (spec.IsCallback)
					cb++;
			}
			Check(cb >= 3, scope $"searching 'callback days' finds the callback nodes ({cb})");
		}

		static NodeSpec Spec(Dictionary<String, NodeSpec> specs, StringView key)
		{
			for (let kv in specs)
				if (kv.key == key)
					return kv.value;
			return null;
		}

		/// `-lib <dir>`: any large generated library as a node library: load time, catalog size, output pins.
		static void LargeLibraryTests(StringView libDir)
		{
			Console.WriteLine(scope $"large generated library as a node library: {libDir}");
			LibraryRef lib = scope .();
			LibraryIndex.ProjectName(libDir, lib.Name);
			lib.Dir.Set(libDir);
			let store = LibraryIndex.Load(lib);
			if (store == null)
			{
				Check(false, "the library loads");
				return;
			}
			Console.WriteLine("  load: {:0} ms ({})", LibraryIndex.LastMs, LibraryIndex.LastWasCacheHit ? "cache hit" : "parsed, cache written");
			ProjectIndex empty = scope .();
			TypeService svc = scope .(empty);
			svc.AutoLoadLibraries = false;
			svc.AddLibrary(store);
			let sw = scope Stopwatch(true);
			svc.Catalog.Refresh();
			Console.WriteLine("  catalog: {:0} ms, {} entries, {} categories", sw.Elapsed.TotalMilliseconds, svc.Catalog.TotalEntries, svc.Catalog.Categories.Count);
			Check(svc.Catalog.TotalEntries > 0, "the catalog has entries");
			int outPins = 0;
			int callbacks = 0;
			let cat = svc.Catalog;
			for (int si < cat.Stores.Count)
				for (int ei < cat.Stores[si].Entries.Count)
				{
					if ((cat.Stores[si].Entries[ei].Flags & CatalogEntry.cCallback) != 0)
						callbacks++;
					NodeSpec spec = scope .();
					cat.GetSpec(NodeCatalog.MakeId(si, ei), spec);
					for (let p in spec.Pins)
						if (p.OutRef)
							outPins++;
				}
			Console.WriteLine("  [Pin(Out=true)] output pins: {}, callback nodes: {}", outPins, callbacks);
		}

		// ------------------------------------------------------------------ installed by a host

		static void HostInstallTests()
		{
			Console.WriteLine("installed by a host tool (host-install.json)");
			String dir = scope .();
			ScratchDir("HostInstall", dir);
			String host = scope .();
			Check(!InstallInfo.IsHostManaged(dir, host), "no host-install.json: VisualBeef updates itself");
			Touch(scope $"{dir}/{InstallInfo.HostInstallFile}", "{\"host\": \"Example Host\", \"updates\": \"host\"}");
			host.Clear();
			Check(InstallInfo.IsHostManaged(dir, host) && host == "Example Host", "\"updates\": \"host\": the host keeps it up to date");
			Touch(scope $"{dir}/{InstallInfo.HostInstallFile}", "{}");
			host.Clear();
			Check(InstallInfo.IsHostManaged(dir, host) && host == "a host tool", "an empty file: host-managed, named generically");
			Touch(scope $"{dir}/{InstallInfo.HostInstallFile}", "{\"host\": \"Example Host\", \"updates\": \"visualbeef\"}");
			Check(!InstallInfo.IsHostManaged(dir, host), "\"updates\": \"visualbeef\": installed by a host, updated by VisualBeef");
			Directory.DelTree(dir).IgnoreError();
		}

		public static int Run(Span<String> args)
		{
			String large = scope .();
			for (int i < args.Length)
				if (args[i] == "-lib" && i + 1 < args.Length)
					large.Set(args[i + 1]);

			ArgTests();
			ManifestTests();
			ProjectTests();
			TemplateTests();
			DependencyLibraryTests();
			NodeLibraryTests();
			HostInstallTests();
			if (!large.IsEmpty)
				LargeLibraryTests(large);
			Console.WriteLine("host checks: {}  failures: {}", sChecks, sFailures);
			return sFailures == 0 ? 0 : 1;
		}
	}
}
