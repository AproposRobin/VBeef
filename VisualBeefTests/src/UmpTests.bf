using System;
using System.IO;
using System.Collections;
using System.Diagnostics;
using VisualBeef.Catalog;
using VisualBeef.Document;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests ump [-sdk <dir>]`: the UnrealUMP integration contract (docs/UMP-Integration.md): the
	/// command line (EditorArgs), project resolution and `.vbproject` (ProjectContract), `--new-ump-mod` output
	/// (TypeTemplates.MakeUMPMod, byte for byte what UMP's launcher writes), generated SDKs reached through a
	/// dependency path, and with `-sdk` a UMP-generated game SDK as a node library (categories, pure nodes,
	/// `[Pin(Out=true)]` output pins, hidden `_PE` twins).
	static class UmpTests
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

		/// UMP's `--selftest-template` pins the same text (src/Mods/ModSelfTest.bf, ExpectedVisualSource).
		const String cExpectedMod = "using System;\nusing UMPDebug;\nusing UMPSDK;\nusing UnrealUMP.Unreal;\n\nnamespace VisualTestMod\n{\n" +
			"\t[AlwaysInclude, StaticInitAfter(typeof(UMPModHost))]\n\tstatic class ModMainEntry\n\t{\n" +
			"\t\tstatic this() => UMPModHost.Register(new ModMain());\n\t}\n\n\tclass ModMain : UMPMod\n\t{\n" +
			"\t\tpublic override FUMPModIdentity Info() => .(\"visual-test-mod\", \"Visual \\\"Test\\\" Mod\", \"0.1.0\"); // must match ModConfig.json\n\n" +
			"\t\t/// Once, at the phase in ModConfig.json, on the runtime worker thread. Return .Err to refuse loading.\n" +
			"\t\tpublic override Result<void> Initialize()\n\t\t{\n\t\t\tLog(.Info, \"Visual \\\"Test\\\" Mod loaded\");\n\t\t\treturn .Ok;\n\t\t}\n\n" +
			"\t\t/// Every frame on the game thread, after the engine's tick; engine calls are safe here.\n" +
			"\t\tpublic override void Tick(float DeltaSeconds)\n\t\t{\n\t\t}\n\n" +
			"\t\t/// Once at process teardown; remove hooks here.\n" +
			"\t\tpublic override void Shutdown()\n\t\t{\n\t\t}\n\t}\n}\n";

		/// The `.vbproject` UMP writes for that mod (ModTemplate.VisualMarkerTemplate).
		const String cExpectedMarker = "{\n  \"vbproject\": 1,\n  \"kind\": \"ump-mod\",\n  \"main\": \"src/ModMain.bf\",\n  \"gameId\": \"hogwarts-legacy\",\n  \"modId\": \"visual-test-mod\"\n}\n";

		static void ParseArgs(EditorArgs a, params String[] args)
		{
			EditorArgs.Parse(args, a);
		}

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
				Check(a.Action == .PrintVersion, "--version alone prints the version");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--help");
				Check(a.Action == .PrintHelp, "--help");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Mods\\MyMod", "--file", "src\\ModMain.bf", "--view");
				Check(a.Action == .Open && a.Path == "D:\\Mods\\MyMod" && a.File == "src\\ModMain.bf" && a.View, "folder, --file, --view");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Mods\\MyMod", "--new-ump-mod", "--namespace", "MyMod", "--class", "ModMain", "--mod-id", "my-mod", "--mod-name", "My Mod", "--version", "1.2.3", "--game", "hogwarts-legacy");
				Check(a.Action == .Open && a.NewUmpMod && a.Namespace == "MyMod" && a.ClassName == "ModMain" && a.ModId == "my-mod" && a.ModName == "My Mod" &&
					a.ModVersion == "1.2.3" && a.GameId == "hogwarts-legacy", "--new-ump-mod with every field (--version is the mod's version)");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Mods\\MyMod", "--new-ump-mod", "--mod-id", "my-mod");
				Check(a.Action == .Open && a.ClassName == "ModMain" && a.ModVersion == "0.1.0" && a.Namespace.IsEmpty, "--new-ump-mod defaults: ModMain, 0.1.0, namespace from the project");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Mods\\MyMod", "--new-ump-mod", "--version");
				Check(a.Action == .PrintVersion, "--version with no value prints the version even after --new-ump-mod");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\Mods\\MyMod", "--new-ump-mod");
				Check(a.Action == .Usage && a.Error.Contains("--mod-id"), "--new-ump-mod without --mod-id is a usage error");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "--new-ump-mod", "--mod-id", "x");
				Check(a.Action == .Usage, "--new-ump-mod without a project folder is a usage error");
			}
			{
				EditorArgs a = scope .();
				ParseArgs(a, "D:\\x", "--new-ump-mod", "--mod-id", "x", "--class", "1Bad");
				Check(a.Action == .Usage, "a class name that is not an identifier is refused");
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

		static void ScratchDir(StringView name, String outDir)
		{
			String tmp = scope .();
			Path.GetTempPath(tmp).IgnoreError(); // falls back to a relative folder
			outDir.AppendF("{}VisualBeefUmpTests{}{}", tmp, Path.DirectorySeparatorChar, name);
#if BF_PLATFORM_WINDOWS
			outDir.Replace('/', '\\');
#endif
			if (Directory.Exists(outDir))
				Directory.DelTree(outDir).IgnoreError();
			Directory.CreateDirectory(outDir).IgnoreError();
		}

		static void ProjectTests()
		{
			Console.WriteLine("project contract");
			String root = scope .();
			ScratchDir("VisualTestMod", root);
			Directory.CreateDirectory(scope $"{root}/src").IgnoreError();
			File.WriteAllText(scope $"{root}/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"VisualTestMod\"\nTargetType = \"BeefLib\"\n").IgnoreError();

			// --new-ump-mod writes MakeUMPMod and the marker; the bytes equal UMP's launcher template.
			EditorArgs a = scope .();
			ParseArgs(a, root, "--new-ump-mod", "--mod-id", "visual-test-mod", "--mod-name", "Visual \"Test\" Mod", "--game", "hogwarts-legacy");
			Check(a.Action == .Open, "parse --new-ump-mod");
			String r = scope .();
			String f = scope .();
			String err = scope .();
			Check(ProjectContract.ResolveTarget(a.Path, a.File, r, f, err) && ProjectIndex.SamePath(r, root) && f.IsEmpty, "a folder without a marker: root, no file");
			String file = scope $"{root}/{ProjectContract.DefaultMain}";
			List<String> created = scope .();
			defer { ClearAndDeleteItems!(created); }
			Check(ProjectContract.WriteUmpMod(a, r, file, created, err) case .Ok && created.Count == 2, "WriteUmpMod creates the file and .vbproject");
			String text = scope .();
			File.ReadAllText(file, text).IgnoreError();
			Check(text == cExpectedMod, "src\\ModMain.bf is MakeUMPMod (namespace from BeefProj.toml, escaped name) = UMP's launcher output");
			if (text != cExpectedMod)
				Console.WriteLine(text);
			String marker = scope .();
			File.ReadAllText(scope $"{root}/.vbproject", marker).IgnoreError();
			Check(marker == cExpectedMarker, ".vbproject has UMP's layout");

			// Never overwritten.
			File.WriteAllText(file, "// edited\n").IgnoreError();
			ClearAndDeleteItems!(created);
			Check(ProjectContract.WriteUmpMod(a, r, file, created, err) case .Ok && created.IsEmpty, "a second --new-ump-mod writes nothing");
			text.Clear();
			File.ReadAllText(file, text).IgnoreError();
			Check(text == "// edited\n", "an existing file is never overwritten");
			File.WriteAllText(file, cExpectedMod).IgnoreError();

			// Resolution: the marker's main, a .bf file, the .vbproject file, --file relative to the project.
			Check(ProjectContract.ResolveTarget(root, "", r, f, err) && ProjectIndex.SamePath(f, file), "folder with .vbproject: focus its main");
			Check(ProjectContract.ResolveTarget(file, "", r, f, err) && ProjectIndex.SamePath(r, root) && ProjectIndex.SamePath(f, file), ".bf file: the project folder above it, that file");
			Check(ProjectContract.ResolveTarget(scope $"{root}/.vbproject", "", r, f, err) && ProjectIndex.SamePath(r, root) && ProjectIndex.SamePath(f, file), ".vbproject file: its folder");
			Check(ProjectContract.ResolveTarget(scope $"{root}/BeefProj.toml", "", r, f, err) && ProjectIndex.SamePath(r, root), "BeefProj.toml: its folder");
			Check(ProjectContract.ResolveTarget(root, "src/Other.bf", r, f, err) && ProjectIndex.SamePath(f, scope $"{root}/src/Other.bf"), "--file is relative to the project");
			Check(!ProjectContract.ResolveTarget(scope $"{root}/missing", "", r, f, err) && err.Contains("does not exist"), "a missing path is an error");
			File.WriteAllText(scope $"{root}/.vbproject", "{\"main\": \"..\\\\..\\\\evil.bf\"}").IgnoreError();
			String main = scope .();
			Check(!ProjectContract.ReadMarkerMain(root, main), "a marker main outside the project is ignored");
			Directory.DelTree(root).IgnoreError();
		}

		static void DependencyLibraryTests()
		{
			Console.WriteLine("generated libraries through dependency paths");
			String root = scope .();
			ScratchDir("DepRoot", root);
			// A mod workspace whose SDK lives under build\ (the project scan skips it) and is reached only
			// through the workspace path, the way UMP's launcher data folder holds sdk\<game>\<Project>.
			String sdk = scope $"{root}/build/sdk/game/GameSDK";
			Directory.CreateDirectory(scope $"{sdk}/src/Generated").IgnoreError();
			File.WriteAllText(scope $"{sdk}/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"GameSDK\"\nTargetType = \"BeefLib\"\n\n[Dependencies]\ncorlib = \"*\"\n").IgnoreError();
			File.WriteAllText(scope $"{sdk}/src/Generated/Engine.g.bf", "namespace Game { public struct AActor { [Node(Category=\"Actor\")] public void Jump() mut {} } }\n").IgnoreError();
			File.WriteAllText(scope $"{root}/BeefSpace.toml", "FileVersion = 1\n\n[Projects]\nMyMod = {Path = \".\"}\nGameSDK = {Path = \"build/sdk/game/GameSDK\"}\n").IgnoreError();
			File.WriteAllText(scope $"{root}/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"MyMod\"\nTargetType = \"BeefLib\"\n\n[Dependencies]\ncorlib = \"*\"\nGameSDK = \"*\"\n").IgnoreError();

			ProjectIndex index = scope .();
			index.Build(root);
			Check(index.GeneratedLibraries.IsEmpty, "the scan does not reach build\\");
			List<LibraryRef> libs = scope .();
			defer { ClearAndDeleteItems!(libs); }
			LibraryIndex.Discover(root, libs, index.GeneratedLibraries);
			bool found = false;
			for (let l in libs)
				if (l.Name == "GameSDK" && ProjectIndex.SamePath(l.Dir, sdk))
					found = true;
			Check(found, "a generated SDK inside the folder, reached through a workspace dependency, loads as a library");

			// The same folder without the generated shape (no *.g.bf, no .vblibrary): it is project code, not a library.
			File.Delete(scope $"{sdk}/src/Generated/Engine.g.bf").IgnoreError();
			File.WriteAllText(scope $"{sdk}/src/Generated/Engine.bf", "namespace Game { }\n").IgnoreError();
			ClearAndDeleteItems!(libs);
			LibraryIndex.Discover(root, libs, null);
			found = false;
			for (let l in libs)
				if (l.Name == "GameSDK")
					found = true;
			Check(!found, "an ordinary project inside the folder is not loaded as a library");
			File.WriteAllText(scope $"{sdk}/.vblibrary", "").IgnoreError();
			ClearAndDeleteItems!(libs);
			LibraryIndex.Discover(root, libs, null);
			found = false;
			for (let l in libs)
				if (l.Name == "GameSDK")
					found = true;
			Check(found, "a .vblibrary marker makes it a library");

			// Two generated folders with the same project name (a copy under dist\ next to the original): both are
			// listed, and the repeated name must not leak its String (the debug runtime reports it as an object leak at exit).
			String copyDir = scope $"{root}/dist/GameSDK";
			Directory.CreateDirectory(scope $"{copyDir}/src").IgnoreError();
			File.WriteAllText(scope $"{copyDir}/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"GameSDK\"\nTargetType = \"BeefLib\"\n").IgnoreError();
			List<String> gens = scope .();
			defer { ClearAndDeleteItems!(gens); }
			gens.Add(new String(sdk));
			gens.Add(new String(copyDir));
			ClearAndDeleteItems!(libs);
			LibraryIndex.Discover(root, libs, gens);
			int named = 0;
			for (let l in libs)
				if (l.Name == "GameSDK")
					named++;
			Check(named == 2, "two generated folders with one project name are both listed (and nothing leaks)");
			Directory.DelTree(root).IgnoreError();
		}

		/// The Hogwarts (or any UMP-generated) SDK, emitted with node metadata (UnrealSDKEmitter v5).
		static void SdkTests(StringView sdkDir)
		{
			Console.WriteLine(scope $"generated SDK as a node library: {sdkDir}");
			LibraryRef lib = scope .();
			LibraryIndex.ProjectName(sdkDir, lib.Name);
			lib.Dir.Set(sdkDir);
			let store = LibraryIndex.Load(lib);
			if (store == null)
			{
				Check(false, "SDK loads");
				return;
			}
			Console.WriteLine("  load: {:0} ms ({})", LibraryIndex.LastMs, LibraryIndex.LastWasCacheHit ? "cache hit" : "parsed, cache written");
			Check(store.UsesNodeAttributes, "the SDK is an attributed library (only tagged members are offered)");

			ProjectIndex empty = scope .();
			TypeService svc = scope .(empty);
			svc.AutoLoadLibraries = false;
			svc.AddLibrary(store);
			let sw = scope Stopwatch(true);
			svc.Catalog.Refresh();
			Console.WriteLine("  catalog: {:0} ms, {} entries, {} categories", sw.Elapsed.TotalMilliseconds, svc.Catalog.TotalEntries, svc.Catalog.Categories.Count);
			Check(svc.Catalog.TotalEntries > 10000 && svc.Catalog.TotalEntries < 60000, "the catalog holds the tagged API, not every member");

			NodeSpec breakVector = null;
			NodeSpec location = null;
			NodeSpec setLocation = null;
			int peEntries = 0;
			int hookEntries = 0;
			int outPins = 0;
			int exposed = 0;
			let cat = svc.Catalog;
			for (int si < cat.Stores.Count)
			{
				let sc = cat.Stores[si];
				for (int ei < sc.Entries.Count)
				{
					let e = ref sc.Entries[ei];
					NodeSpec spec = new .();
					cat.GetSpec(NodeCatalog.MakeId(si, ei), spec);
					if (spec.MemberName.EndsWith("_PE"))
						peEntries++;
					if (spec.MemberName.StartsWith("Hook_") || spec.MemberName.StartsWith("Original_"))
						hookEntries++;
					if (e.Kind == .Get)
						exposed++;
					for (let p in spec.Pins)
						if (p.OutRef)
							outPins++;
					if (breakVector == null && spec.MemberName == "BreakVector" && spec.OwnerType.Contains("KismetMathLibrary"))
						breakVector = spec;
					else if (location == null && spec.MemberName == "K2_GetActorLocation" && spec.OwnerType == "AActor")
						location = spec;
					else if (setLocation == null && spec.MemberName == "K2_SetActorLocation" && spec.OwnerType == "AActor")
						setLocation = spec;
					else
						delete spec;
				}
			}
			defer { delete breakVector; delete location; delete setLocation; }
			Check(peEntries == 0 && hookEntries == 0, scope $"_PE twins and hooks are not offered ({peEntries}, {hookEntries})");
			Check(outPins > 1000, scope $"[Pin(Out=true)] output pins in the catalog: {outPins}");
			Check(exposed > 1000, scope $"[Expose] properties offered as Get nodes: {exposed}");

			Check(breakVector != null, "Break Vector is in the catalog");
			if (breakVector != null)
			{
				int outs = 0;
				for (let p in breakVector.Pins)
					if (p.IsOutput && (p.Label == "X" || p.Label == "Y" || p.Label == "Z"))
						outs++;
				Check(breakVector.Category == "KismetMathLibrary" && breakVector.IsPure && breakVector.IsStatic, scope $"Break Vector: category {breakVector.Category}, pure, static");
				Check(outs == 3, "Break Vector has three output pins labelled X, Y, Z ([Pin(Out=true)] ref float @X)");
				for (let p in breakVector.Pins)
					Console.WriteLine("       pin {} label {} type {} {}{}", p.Name, p.Label, p.Type, p.Modifier, p.IsOutput ? " (output)" : "");
			}
			Check(location != null, "Get Actor Location is in the catalog");
			if (location != null)
			{
				Check(location.DisplayName == "Get Actor Location" && location.Category == "Actor" && location.IsPure && !location.IsStatic,
					scope $"K2_GetActorLocation: \"{location.DisplayName}\" in {location.Category}, pure member (receiver `this`)");
				Check(location.Tooltip.Contains("/Script/Engine.Actor:K2_GetActorLocation"), scope $"tooltip from the dump: {location.Tooltip}");
			}
			Check(setLocation != null, "Set Actor Location is in the catalog");
			if (setLocation != null)
			{
				bool sweepOut = false;
				for (let p in setLocation.Pins)
					if ((p.Name == "@SweepHitResult" || p.Label == "SweepHitResult") && p.IsOutput)
						sweepOut = true;
				Check(sweepOut && !setLocation.IsPure, "Set Actor Location: flow node, SweepHitResult is an output pin");
			}

			List<SearchHit> hits = scope .();
			cat.Search("get actor location", hits, 20);
			bool top = false;
			for (int i < Math.Min(hits.Count, 3))
			{
				NodeSpec spec = scope .();
				cat.GetSpec(hits[i].Id, spec);
				if (spec.MemberName == "K2_GetActorLocation")
					top = true;
			}
			Check(top, "search \"get actor location\" finds it in the top 3");
		}

		static void Touch(StringView path, StringView text)
		{
			String dir = scope .();
			Path.GetDirectoryPath(path, dir).IgnoreError();
			Directory.CreateDirectory(dir).IgnoreError();
			File.WriteAllText(path, text).IgnoreError();
		}

		static void FakeLib(StringView dir, StringView name) => Touch(scope $"{dir}/BeefProj.toml", scope $"FileVersion = 1\n\n[Project]\nName = \"{name}\"\nTargetType = \"BeefLib\"\n");

		static void FakeSdk(StringView dir, StringView name)
		{
			FakeLib(dir, name);
			Touch(scope $"{dir}/src/Generated/Engine.g.bf", "namespace UnrealUMP.Unreal\n{\n}\n");
		}

		static String ReadText(StringView path, String outText)
		{
			File.ReadAllText(path, outText).IgnoreError();
			return outText;
		}

		/// File > New Project > UMP Mod (UmpModProject): names, the SDK chosen by its folder (a checkout's
		/// Sdks, a launcher folder with sdk.json), UMP's libraries found above it, the files written.
		static void ModProjectTests()
		{
			Console.WriteLine("New Project > UMP Mod:");
			String folder = scope .();
			UmpModProject.FolderName("Hello Mod!", folder);
			String digits = scope .();
			UmpModProject.FolderName("3D Mod", digits);
			String slug = scope .();
			UmpModProject.Slug("Cool Multiplayer Mod!", slug);
			String game = scope .();
			UmpModProject.GameIdFromProject("HogwartsLegacySDK", game);
			Check(folder == "HelloMod" && digits == "Mod3DMod" && slug == "cool-multiplayer-mod" && game == "hogwarts-legacy",
				scope $"names as UMP's launcher makes them: {folder}, {digits}, {slug}, {game}");

			String root = scope .();
			ScratchDir("ModProject", root);
			String ump = scope $"{root}/UMP";
			for (let lib in UmpModProject.sLibraries)
				FakeLib(scope $"{ump}/{lib.dir}", lib.name);
			FakeLib(scope $"{ump}/UMPJson", "UMPJson");
			Touch(scope $"{ump}/UMPDebug/src/Version/RuntimeAbi.bf", "namespace UMPDebug\n{\n\tstatic class RuntimeAbi\n\t{\n\t\tpublic const uint32 Revision = 20;\n\t}\n}\n");
			FakeSdk(scope $"{ump}/Sdks/HogwartsLegacySDK", "HogwartsLegacySDK");
			FakeSdk(scope $"{ump}/Sdks/ScreechSDK", "ScreechSDK");
			String launcher = scope $"{ump}/build/Release_Win64/UnrealUMP";
			FakeSdk(scope $"{launcher}/sdk/hogwarts-legacy/HogwartsLegacySDK", "HogwartsLegacySDK");
			Touch(scope $"{launcher}/sdk/hogwarts-legacy/sdk.json", "{\n  \"schema\": 1,\n  \"gameId\": \"hogwarts-legacy\",\n  \"project\": \"HogwartsLegacySDK\"\n}\n");
			FakeSdk(scope $"{root}/Lone/LoneSDK", "LoneSDK");

			UmpSdkInfo repo = scope .();
			String err = scope .();
			bool ok = UmpModProject.ResolveSdk(scope $"{ump}/Sdks/HogwartsLegacySDK", repo, err);
			Check(ok && repo.ProjectName == "HogwartsLegacySDK" && repo.GameId == "hogwarts-legacy" && repo.RuntimeAbi == 20 && repo.LauncherRoot.IsEmpty
				&& ProjectIndex.SamePath(repo.UmpRoot, ump), scope $"a checkout's SDK folder: game {repo.GameId}, UMP root found above it, runtime ABI {repo.RuntimeAbi} {err}");

			// An older UMP folder (BJSON-1.3.0/BJSON instead of UMPJson) still resolves, with that library.
			{
				String oldUmp = scope $"{root}/OldUMP";
				for (let lib in UmpModProject.sLibraries)
					FakeLib(scope $"{oldUmp}/{lib.dir}", lib.name);
				FakeLib(scope $"{oldUmp}/BJSON-1.3.0/BJSON", "BJSON");
				FakeSdk(scope $"{oldUmp}/Sdks/HogwartsLegacySDK", "HogwartsLegacySDK");
				UmpSdkInfo old = scope .();
				String oldErr = scope .();
				Check(UmpModProject.ResolveSdk(scope $"{oldUmp}/Sdks/HogwartsLegacySDK", old, oldErr) && old.JsonName == "BJSON" && old.JsonDir == "BJSON-1.3.0/BJSON", scope $"an older UMP folder resolves with BJSON {oldErr}");
			}

			UmpSdkInfo fromLauncher = scope .();
			err.Clear();
			ok = UmpModProject.ResolveSdk(launcher, fromLauncher, err);
			Check(ok && fromLauncher.GameId == "hogwarts-legacy" && ProjectIndex.SamePath(fromLauncher.LauncherRoot, launcher) && fromLauncher.SdkDir.Contains("hogwarts-legacy"),
				scope $"the launcher folder: its one sdk/<game>/<X>SDK, the game from sdk.json, the launcher folder kept {err}");

			UmpSdkInfo other = scope .();
			err.Clear();
			Check(!UmpModProject.ResolveSdk(scope $"{ump}/Sdks", other, err) && err.Contains("several game SDKs"), scope $"a folder with two SDKs asks for one: {err}");
			err.Clear();
			Check(!UmpModProject.ResolveSdk(scope $"{root}/Lone/LoneSDK", other, err) && err.Contains("UMP's libraries"), scope $"an SDK with no UMP libraries above it says so: {err}");
			err.Clear();
			Check(!UmpModProject.ResolveSdk(ump, other, err) && err.Contains("several game SDKs"), scope $"the UMP folder itself (a Beef project, not an SDK) is not taken for one: {err}");
			err.Clear();
			String empty = scope $"{root}/Empty";
			Directory.CreateDirectory(empty).IgnoreError();
			Check(!UmpModProject.ResolveSdk(empty, other, err) && err.Contains("generate it"), scope $"a folder with no SDK says where SDKs come from: {err}");

			// The project written with the launcher's SDK: a Release build installs into its mods folder.
			String loc = scope $"{root}/Projects";
			Directory.CreateDirectory(loc).IgnoreError();
			String projDir = scope .();
			err.Clear();
			ok = UmpModProject.Write(loc, "Hello Mod", "0.1.0", "", "", fromLauncher, projDir, err);
			Check(ok && projDir.EndsWith("HelloMod"), scope $"Write: the project folder is HelloMod {err}");
			String space = scope .();
			ReadText(scope $"{projDir}/BeefSpace.toml", space);
			String launcherSlashes = scope .(launcher);
			launcherSlashes.Replace('\\', '/');
			String umpSlashes = scope .(ump);
			umpSlashes.Replace('\\', '/');
			Check(space.Contains("StartupProject = \"HelloMod\"") && space.Contains("HelloMod = {Path = \".\"}") && space.Contains(scope $"HogwartsLegacySDK = {{Path = \"{launcherSlashes}/sdk/hogwarts-legacy/HogwartsLegacySDK\"}}")
				&& space.Contains(scope $"UMPJson = {{Path = \"{umpSlashes}/UMPJson\"}}") && space.Contains(scope $"UMPSDK = {{Path = \"{umpSlashes}/UMPSDK\"}}") && !space.Contains("\\"),
				"BeefSpace.toml: the mod, the SDK and UMP's five libraries by absolute path with /");
			String proj = scope .();
			ReadText(scope $"{projDir}/BeefProj.toml", proj);
			Check(proj.Contains("TargetType = \"BeefLib\"") && proj.Contains("[Configs.Release.Win64]\nBuildKind = \"DynamicLib\"") && proj.Contains("HogwartsLegacySDK = \"*\"")
				&& proj.Contains(scope $"{launcherSlashes}/mods/hogwarts-legacy/hello-mod") && proj.Contains("$(TargetDir)/HelloMod.dll"),
				"BeefProj.toml: a DLL; Release copies HelloMod.dll and ModConfig.json into the launcher's mods/hogwarts-legacy/hello-mod");
			String cfg = scope .();
			ReadText(scope $"{projDir}/ModConfig.json", cfg);
			Check(cfg.Contains("\"Id\": \"hello-mod\"") && cfg.Contains("\"Mod Name\": \"Hello Mod\"") && cfg.Contains("\"Version\": \"0.1.0\"") && cfg.Contains("\"Game Id\": \"hogwarts-legacy\"")
				&& cfg.Contains("\"Entry\": \"HelloMod.dll\"") && cfg.Contains("\"Api Version\": 1") && cfg.Contains("\"Phase\": \"EngineReady\"") && cfg.Contains("\"Kind\": \"native\"")
				&& cfg.Contains("\"MinRuntimeAbi\": 20") && cfg.Contains("\"MinLauncher\": \"\"") && cfg.Contains("\"Dependencies\": []") && cfg.Contains("\"Load After\": []"),
				"ModConfig.json: the keys of UMP's docs/Mods.md, MinRuntimeAbi from the UMP source (20), MinLauncher empty (none)");
			String main = scope .();
			ReadText(scope $"{projDir}/src/ModMain.bf", main);
			String expected = scope .();
			TypeTemplates.MakeUMPMod("HelloMod", "ModMain", "hello-mod", "Hello Mod", "0.1.0", expected);
			Check(main == expected, "src/ModMain.bf is TypeTemplates.MakeUMPMod's text (the launcher's visual mod) with the same id, name and version");
			String marker = scope .();
			ReadText(scope $"{projDir}/.vbproject", marker);
			Check(marker.Contains("\"kind\": \"ump-mod\"") && marker.Contains("\"main\": \"src/ModMain.bf\"") && marker.Contains("\"modId\": \"hello-mod\"") && File.Exists(scope $"{projDir}/README.md"),
				".vbproject (ump-mod, main src/ModMain.bf) and README.md");
			String again = scope .();
			err.Clear();
			Check(!UmpModProject.Write(loc, "Hello Mod", "0.1.0", "", "", fromLauncher, again, err) && err.Contains("already exists") && ReadText(scope $"{projDir}/ModConfig.json", scope .()) == cfg,
				scope $"a second Write into the same folder is refused and changes nothing: {err}");

			// The checkout's SDK: no launcher folder, so no copy step.
			String projRepo = scope .();
			err.Clear();
			ok = UmpModProject.Write(loc, "Repo Mod", "1.2.3", "Me", "0.1.0.310", repo, projRepo, err);
			String projText = scope .();
			ReadText(scope $"{projRepo}/BeefProj.toml", projText);
			String cfgRepo = scope .();
			ReadText(scope $"{projRepo}/ModConfig.json", cfgRepo);
			Check(ok && !projText.Contains("PostBuildCmds") && cfgRepo.Contains("\"MinLauncher\": \"0.1.0.310\"") && cfgRepo.Contains("\"Author\": \"Me\"") && cfgRepo.Contains("\"Version\": \"1.2.3\""),
				"a checkout's SDK: no copy step; Author, Version and MinLauncher written as given");
			Directory.DelTree(root).IgnoreError();
		}

		public static int Run(Span<String> args)
		{
			String sdk = scope .();
			for (int i < args.Length)
				if (args[i] == "-sdk" && i + 1 < args.Length)
					sdk.Set(args[i + 1]);

			ArgTests();
			ProjectTests();
			DependencyLibraryTests();
			ModProjectTests();
			if (!sdk.IsEmpty)
				SdkTests(sdk);
			Console.WriteLine("ump checks: {}  failures: {}", sChecks, sFailures);
			return sFailures == 0 ? 0 : 1;
		}
	}
}
