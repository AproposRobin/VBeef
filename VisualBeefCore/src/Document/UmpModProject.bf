using System;
using System.IO;
using System.Collections;
using VisualBeef.Catalog;

namespace VisualBeef.Document
{
	/// A game SDK a new UMP mod is built against, and the UMP folder around it.
	class UmpSdkInfo
	{
		/// The SDK project folder (holds BeefProj.toml and the generated `*.g.bf`).
		public String SdkDir = new .() ~ delete _;
		/// Its `[Project] Name` ("HogwartsLegacySDK").
		public String ProjectName = new .() ~ delete _;
		/// "hogwarts-legacy": from the launcher's `sdk.json`, else from the project name.
		public String GameId = new .() ~ delete _;
		/// The folder holding UMPSDK, UnrealSDKCore, UMPDebug, WindowsUtils and the JSON library
		/// (UMPJson, or BJSON-1.3.0 in UMP folders before it was replaced).
		public String UmpRoot = new .() ~ delete _;
		/// The JSON library found there: project name and folder under UmpRoot.
		public String JsonName = new .() ~ delete _;
		public String JsonDir = new .() ~ delete _;
		/// The launcher folder when the SDK is the launcher's (`<Root>\sdk\<game>\<X>SDK` with
		/// `sdk.json`): a Release build then copies the mod into `<Root>\mods\<game>\<id>`.
		public String LauncherRoot = new .() ~ delete _;
		/// `UMPDebug.RuntimeAbi.Revision` read from the UMP source (0 = not found).
		public int RuntimeAbi;
	}

	/// File > New Project > UMP Mod: the same project UMP's launcher writes for a visual mod
	/// (docs/UMP-Integration.md, UMP docs/Mods.md "Quick start"): BeefSpace.toml with the game SDK and
	/// UMP's libraries, BeefProj.toml (a DLL), ModConfig.json, .vbproject, src\ModMain.bf
	/// (`TypeTemplates.MakeUMPMod`) and README.md. Only the SDK folder is chosen; everything else is
	/// found from it.
	static class UmpModProject
	{
		/// UMP's libraries a mod references: project name, folder under the UMP root.
		public static readonly (StringView name, StringView dir)[4] sLibraries = .(("UMPSDK", "UMPSDK"), ("UnrealSDKCore", "UnrealSDKCore"),
			("UMPDebug", "UMPDebug"), ("WindowsUtils", "WindowsUtils"));
		/// The JSON libraries UMP has used, newest first.
		static readonly (StringView name, StringView dir)[2] sJsonLibraries = .(("UMPJson", "UMPJson"), ("BJSON", "BJSON-1.3.0/BJSON"));

		/// UMP's rule (ModTemplate.BuildFolderName): the ASCII letters and digits of the name,
		/// `Mod` in front when it starts with a digit. "Hello Mod!" -> "HelloMod".
		public static void FolderName(StringView name, String outFolder)
		{
			for (let c in name.RawChars)
				if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
					outFolder.Append(c);
			if (!outFolder.IsEmpty && outFolder[0].IsDigit)
				outFolder.Insert(0, "Mod");
		}

		/// UMP's mod id rule (ModStore.Slugify): lower case, every run of other characters one `-`.
		/// "Hello Mod!" -> "hello-mod".
		public static void Slug(StringView name, String outId)
		{
			bool dash = false;
			for (let c in name.RawChars)
			{
				if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z'))
				{
					if (dash && !outId.IsEmpty)
						outId.Append('-');
					dash = false;
					outId.Append(c.ToLower);
				}
				else
					dash = true;
			}
		}

		/// "HogwartsLegacySDK" -> "hogwarts-legacy" (when there is no sdk.json to say it).
		public static void GameIdFromProject(StringView project, String outId)
		{
			var p = project;
			if (p.EndsWith("SDK") || p.EndsWith("Sdk"))
				p.RemoveFromEnd(3);
			for (int i < p.Length)
			{
				let c = p[i];
				if (c.IsUpper && i > 0 && !p[i - 1].IsUpper)
					outId.Append('-');
				if (c.IsLetterOrDigit)
					outId.Append(c.ToLower);
			}
		}

		static void Join(StringView a, StringView b, String outPath)
		{
			outPath.Append(a);
			if (!outPath.EndsWith('\\') && !outPath.EndsWith('/'))
				outPath.Append(Path.DirectorySeparatorChar);
			outPath.Append(b);
		}

		static bool HasProject(StringView dir) => File.Exists(scope String()..AppendF("{}{}BeefProj.toml", dir, Path.DirectorySeparatorChar));

		static void Parent(StringView dir, String outParent)
		{
			String t = scope .(dir);
			while (t.Length > 3 && (t.EndsWith('\\') || t.EndsWith('/')))
				t.RemoveFromEnd(1);
			if (Path.GetDirectoryPath(t, outParent) case .Err || outParent.Length >= t.Length)
				outParent.Clear();
		}

		/// The SDK a chosen folder stands for: the SDK project folder itself, or a folder with
		/// exactly one `sdk\<game>\<X>SDK` (a launcher folder) or one `Sdks\<X>SDK`. The UMP libraries
		/// are looked for in the folders above it. False with a reason that says what to choose.
		public static bool ResolveSdk(StringView folderIn, UmpSdkInfo outInfo, String outError)
		{
			String folder = scope .(folderIn);
			folder.Trim();
			while (folder.Length > 3 && (folder.EndsWith('\\') || folder.EndsWith('/')))
				folder.RemoveFromEnd(1);
			if (folder.IsEmpty || !Directory.Exists(folder))
			{
				outError.Set("Choose the game's SDK folder: the one UMP generated for the game (<UMP launcher folder>\\sdk\\<game>\\<Game>SDK).");
				return false;
			}
			String sdk = scope .();
			if (ProjectIndex.IsGeneratedLibrary(folder))
				sdk.Set(folder);
			else
			{
				// A folder of SDKs, a launcher folder (sdk\<game>\<X>SDK) or a checkout (Sdks\<X>SDK): one SDK below it.
				List<String> found = scope .();
				defer { ClearAndDeleteItems!(found); }
				for (let top in StringView[3]("", "sdk", "Sdks"))
				{
					String root = scope .();
					if (top.IsEmpty)
						root.Set(folder);
					else
						Join(folder, top, root);
					if (!Directory.Exists(root))
						continue;
					for (let e in Directory.EnumerateDirectories(root))
					{
						String d = scope .();
						e.GetFilePath(d);
						if (ProjectIndex.IsGeneratedLibrary(d))
							found.Add(new String(d));
						else
							for (let e2 in Directory.EnumerateDirectories(d))
							{
								String d2 = scope .();
								e2.GetFilePath(d2);
								if (ProjectIndex.IsGeneratedLibrary(d2))
									found.Add(new String(d2));
							}
					}
				}
				if (found.Count != 1)
				{
					outError.Set((found.Count == 0)
						? "There is no game SDK in that folder. Choose the SDK folder UMP generated for the game (<UMP launcher folder>\\sdk\\<game>\\<Game>SDK); generate it from the game's page in the UMP launcher first."
						: "That folder has several game SDKs: choose the one for your game (its folder ends in SDK).");
					return false;
				}
				sdk.Set(found[0]);
			}
			outInfo.SdkDir.Set(sdk);
			outInfo.ProjectName.Clear();
			LibraryIndex.ProjectName(sdk, outInfo.ProjectName);

			// Game id: the launcher's sdk.json next to the SDK, else from the project name.
			outInfo.GameId.Clear();
			outInfo.LauncherRoot.Clear();
			String gameDir = scope .();
			Parent(sdk, gameDir);
			String sdkJson = scope .();
			Join(gameDir, "sdk.json", sdkJson);
			String json = scope .();
			if (!gameDir.IsEmpty && File.ReadAllText(sdkJson, json) case .Ok)
			{
				int at = json.IndexOf("\"gameId\"");
				if (at >= 0)
				{
					int q1 = json.IndexOf('"', json.IndexOf(':', at) + 1);
					int q2 = (q1 >= 0) ? json.IndexOf('"', q1 + 1) : -1;
					if (q2 > q1)
						outInfo.GameId.Set(StringView(json, q1 + 1, q2 - q1 - 1));
				}
				// <Root>\sdk\<game>\<X>SDK: the launcher folder is two above the game folder.
				String sdkDir = scope .();
				Parent(gameDir, sdkDir);
				if (!sdkDir.IsEmpty)
					Parent(sdkDir, outInfo.LauncherRoot);
			}
			if (outInfo.GameId.IsEmpty)
				GameIdFromProject(outInfo.ProjectName, outInfo.GameId);

			// UMP's libraries: the first folder above the SDK that holds all of them.
			outInfo.UmpRoot.Clear();
			String dir = scope .(sdk);
			for (int guard < 12)
			{
				bool all = true;
				for (let lib in sLibraries)
				{
					String probe = scope .();
					Join(dir, lib.dir, probe);
					if (!HasProject(probe))
						all = false;
				}
				if (all)
				{
					for (let j in sJsonLibraries)
					{
						String probe = scope .();
						Join(dir, j.dir, probe);
						if (HasProject(probe))
						{
							outInfo.UmpRoot.Set(dir);
							outInfo.JsonName.Set(j.name);
							outInfo.JsonDir.Set(j.dir);
							break;
						}
					}
					if (!outInfo.UmpRoot.IsEmpty)
						break;
				}
				String up = scope .();
				Parent(dir, up);
				if (up.IsEmpty)
					break;
				dir.Set(up);
			}
			if (outInfo.UmpRoot.IsEmpty)
			{
				outError.Set("UMP's libraries (UMPSDK, UnrealSDKCore, UMPDebug, WindowsUtils, UMPJson) are not in a folder above that SDK. Choose the SDK inside your UMP folder.");
				return false;
			}
			outInfo.RuntimeAbi = 0;
			String abi = scope .();
			Join(outInfo.UmpRoot, "UMPDebug/src/Version/RuntimeAbi.bf", abi);
			String abiText = scope .();
			if (File.ReadAllText(abi, abiText) case .Ok)
			{
				int at = abiText.IndexOf("Revision =");
				if (at >= 0)
				{
					int s = at + 10;
					while (s < abiText.Length && abiText[s] == ' ')
						s++;
					int e = s;
					while (e < abiText.Length && abiText[e].IsDigit)
						e++;
					if (int.Parse(StringView(abiText, s, e - s)) case .Ok(let v))
						outInfo.RuntimeAbi = v;
				}
			}
			return true;
		}

		static void Slashes(StringView path, String outText)
		{
			outText.Append(path);
			outText.Replace('\\', '/');
		}

		static void JsonStr(StringView s, String o)
		{
			o.Append('"');
			for (let c in s.RawChars)
			{
				if (c == '"' || c == '\\')
					o.Append('\\');
				o.Append(c);
			}
			o.Append('"');
		}

		/// The project's files as text (path relative to the project folder -> content), in the
		/// order they are written. `minLauncher` may be empty (= none).
		public static void MakeFiles(StringView name, StringView version, StringView author, StringView minLauncher, UmpSdkInfo sdk, List<(String path, String text)> outFiles)
		{
			String folder = scope .();
			FolderName(name, folder);
			String id = scope .();
			Slug(name, id);
			String repo = scope .();
			Slashes(sdk.UmpRoot, repo);
			String sdkPath = scope .();
			Slashes(sdk.SdkDir, sdkPath);

			String space = new .();
			space.AppendF("FileVersion = 1\n\n[Workspace]\nStartupProject = \"{}\"\n\n[Projects]\n{} = {{Path = \".\"}}\ncorlib = \"*\"\n", folder, folder);
			space.AppendF("{} = {{Path = \"{}\"}}\n", sdk.ProjectName, sdkPath);
			for (let lib in sLibraries)
				space.AppendF("{} = {{Path = \"{}/{}\"}}\n", lib.name, repo, lib.dir);
			space.AppendF("{} = {{Path = \"{}/{}\"}}\n", sdk.JsonName, repo, sdk.JsonDir);
			outFiles.Add((new .("BeefSpace.toml"), space));

			String proj = new .();
			proj.AppendF("FileVersion = 1\n\n[Project]\nName = \"{}\"\nTargetType = \"BeefLib\"\n\n[Dependencies]\ncorlib = \"*\"\n", folder);
			proj.AppendF("{} = \"*\"\n", sdk.ProjectName);
			for (let lib in sLibraries)
				proj.AppendF("{} = \"*\"\n", lib.name);
			proj.AppendF("{} = \"*\"\n", sdk.JsonName);
			proj.Append("\n[Configs.Debug.Win64]\nBuildKind = \"DynamicLib\"\n\n[Configs.Release.Win64]\nBuildKind = \"DynamicLib\"\n");
			if (!sdk.LauncherRoot.IsEmpty)
			{
				// As the launcher's template: a Release build installs the DLL and ModConfig.json.
				String mods = scope .();
				Slashes(sdk.LauncherRoot, mods);
				mods.AppendF("/mods/{}/{}", sdk.GameId, id);
				proj.AppendF("PostBuildCmds = [\"CopyFilesIfNewer(\\\"$(TargetDir)/{}.dll\\\", \\\"{}\\\")\", \"CopyFilesIfNewer(\\\"$(ProjectDir)/ModConfig.json\\\", \\\"{}\\\")\"]\n", folder, mods, mods);
			}
			outFiles.Add((new .("BeefProj.toml"), proj));

			String cfg = new .();
			cfg.Append("{\n  \"Id\": ");
			JsonStr(id, cfg);
			cfg.Append(",\n  \"Mod Name\": ");
			JsonStr(name, cfg);
			cfg.Append(",\n  \"Author\": ");
			JsonStr(author, cfg);
			cfg.Append(",\n  \"Mod Description\": \"\",\n  \"Version\": ");
			JsonStr(version, cfg);
			cfg.Append(",\n  \"Game Id\": ");
			JsonStr(sdk.GameId, cfg);
			cfg.AppendF(",\n  \"Entry\": \"{}.dll\",\n  \"Api Version\": 1,\n  \"Dependencies\": [],\n  \"Load After\": [],\n  \"Phase\": \"EngineReady\",\n  \"Kind\": \"native\",\n", folder);
			cfg.AppendF("  \"MinRuntimeAbi\": {},\n  \"MinLauncher\": ", sdk.RuntimeAbi);
			JsonStr(minLauncher, cfg);
			cfg.Append("\n}\n");
			outFiles.Add((new .("ModConfig.json"), cfg));

			String marker = new .();
			marker.AppendF("{{\n  \"vbproject\": 1,\n  \"kind\": \"ump-mod\",\n  \"main\": \"src/ModMain.bf\",\n  \"gameId\": \"{}\",\n  \"modId\": \"{}\"\n}}\n", sdk.GameId, id);
			outFiles.Add((new .(".vbproject"), marker));

			String main = new .();
			TypeTemplates.MakeUMPMod(folder, "ModMain", id, name, version, main);
			outFiles.Add((new .("src/ModMain.bf"), main));

			String readme = new .();
			readme.AppendF("# {}\n\nA UMP mod for {} made in VisualBeef. `src/ModMain.bf` holds `ModMain` with the `Initialize`, `Tick` and\n`Shutdown` graphs; Type Settings > Overrides adds `OnEngineReady` and `OnWorldReady`.\n\n", name, sdk.GameId);
			readme.AppendF("Compile **Release** (a Debug DLL cannot load in the game). {}\n\n", sdk.LauncherRoot.IsEmpty
				? "Install it from the UMP launcher (Installed > My projects > Build) or copy the DLL and `ModConfig.json` into `<UMP launcher folder>/mods/<game>/<id>/`."
				: "The build copies the DLL and `ModConfig.json` into the launcher's `mods` folder.");
			readme.Append("`ModConfig.json` is the manifest UMP reads (its `Id`, `Mod Name` and `Version` must match `Info()` in `ModMain.bf`).\n");
			outFiles.Add((new .("README.md"), readme));
		}

		/// Writes the project into `<location>\<FolderName(name)>`; refuses an existing folder.
		public static bool Write(StringView location, StringView name, StringView version, StringView author, StringView minLauncher, UmpSdkInfo sdk, String outProjDir, String outError)
		{
			String folder = scope .();
			FolderName(name, folder);
			if (folder.IsEmpty)
			{
				outError.Set("Give the mod a name with letters or digits.");
				return false;
			}
			outProjDir.Clear();
			Join(location, folder, outProjDir);
			if (Directory.Exists(outProjDir) || File.Exists(outProjDir))
			{
				outError.Set(scope $"A folder named {folder} already exists there.");
				return false;
			}
			List<(String path, String text)> files = scope .();
			defer { for (let f in files) { delete f.path; delete f.text; } }
			MakeFiles(name, version, author, minLauncher, sdk, files);
			for (let f in files)
			{
				String full = scope .();
				Join(outProjDir, f.path, full);
				full.Replace('/', Path.DirectorySeparatorChar);
				String dir = scope .();
				Path.GetDirectoryPath(full, dir).IgnoreError();
				if (!dir.IsEmpty && Directory.CreateDirectory(dir) case .Err)
				{
					outError.Set(scope $"Could not create {dir}.");
					return false;
				}
				if (File.WriteAllText(full, f.text) case .Err)
				{
					outError.Set(scope $"Could not write {full}.");
					return false;
				}
			}
			return true;
		}
	}
}
