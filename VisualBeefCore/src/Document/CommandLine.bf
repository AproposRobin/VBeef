using System;
using System.IO;
using System.Collections;
using VisualBeef.Catalog;

namespace VisualBeef.Document
{
	/// VisualBeef's own version and the version of the contract hosts such as UnrealUMP launch it with
	/// (docs/UMP-Integration.md). Bump `UmpContract` when the command line or the project files change shape.
	static class VisualBeefInfo
	{
		public const String Version = "0.2.1";
		/// Release channel of this build ("alpha"); shown by --version, the window title and VERSION.txt.
		public const String Channel = "alpha";
		public const int UmpContract = 1;
		public const String Name = "VisualBeef";
	}

	/// The editor's command line (docs/UMP-Integration.md > Command line):
	///
	///   VisualBeefEditor.exe [<folder-or-file>] [--file <bf>] [--view]
	///                        [--new-ump-mod --mod-id <id> [--namespace <ns>] [--class <name>] [--mod-name <name>] [--version <v>] [--game <gameId>]]
	///   VisualBeefEditor.exe --version | --help
	///
	/// Parsing is separate from acting on it so the rules are testable (`VisualBeefTests cli`).
	class EditorArgs
	{
		public enum Kind
		{
			/// Open the editor (with or without a project).
			Open,
			PrintVersion,
			PrintHelp,
			/// Bad command line: `Error` says why; the process exits with ExitUsage.
			Usage
		}

		public const int ExitOk = 0;
		/// The editor could not start or a file could not be written (`--new-ump-mod`).
		public const int ExitFailed = 1;
		/// Unknown option, missing value, a path that does not exist, `--new-ump-mod` without `--mod-id`.
		public const int ExitUsage = 2;

		public Kind Action = .Open;
		public String Error = new .() ~ delete _;
		/// The positional `<folder-or-file>` as given ("" when none).
		public String Path = new .() ~ delete _;
		/// `--file <bf>` as given (absolute, or relative to the project folder).
		public String File = new .() ~ delete _;
		public bool View;

		public bool NewUmpMod;
		public String Namespace = new .() ~ delete _;
		public String ClassName = new .("ModMain") ~ delete _;
		public String ModId = new .() ~ delete _;
		public String ModName = new .() ~ delete _;
		public String ModVersion = new .("0.1.0") ~ delete _;
		public String GameId = new .() ~ delete _;

		public bool IsEmpty => Action == .Open && Path.IsEmpty && File.IsEmpty && !NewUmpMod && !View;

		public const String Usage = """
			Usage: VisualBeefEditor.exe [<folder-or-file>] [--file <bf>] [--view]
			                            [--new-ump-mod --mod-id <id> [--namespace <ns>] [--class <name>] [--mod-name <name>] [--version <v>] [--game <gameId>]]
			       VisualBeefEditor.exe --version | --help

			  <folder-or-file>   a project folder (BeefSpace.toml / BeefProj.toml), a .vbproject / BeefSpace.toml / BeefProj.toml file
			                     (opens its folder), or a .bf file (opens the folder of its project and that file)
			  --file <bf>        the file to focus (absolute, or relative to the project folder); default: "main" of .vbproject
			  --view             read-only: nothing is ever written to the project
			  --new-ump-mod      write the UMP mod entry class (Initialize / Tick / Shutdown graphs) into the --file
			                     (default src\\ModMain.bf) if that file does not exist yet, and .vbproject if missing
			  --version          print the VisualBeef version and exit (after --new-ump-mod: the mod's version)

			Exit codes: 0 ok, 1 failed (window or file could not be created), 2 bad command line.
			""";

		static bool TakeValue(Span<String> args, ref int i, StringView name, String outValue, EditorArgs result)
		{
			if (i + 1 >= args.Length || args[i + 1].StartsWith("--"))
			{
				result.Action = .Usage;
				result.Error.Set(scope $"{name} needs a value.");
				return false;
			}
			i++;
			outValue.Set(args[i]);
			return true;
		}

		public static void Parse(Span<String> args, EditorArgs result)
		{
			bool newMod = false;
			for (let a in args)
				if (a == "--new-ump-mod")
					newMod = true;

			for (int i = 0; i < args.Length; i++)
			{
				let a = args[i];
				switch (a)
				{
				case "--help", "-h", "/?":
					result.Action = .PrintHelp;
					return;
				case "--version", "-v":
					// After --new-ump-mod, `--version <v>` is the mod's version.
					if (newMod && i + 1 < args.Length && !args[i + 1].StartsWith("--"))
					{
						i++;
						result.ModVersion.Set(args[i]);
						continue;
					}
					result.Action = .PrintVersion;
					return;
				case "--view", "-view":
					result.View = true;
				case "--file":
					if (!TakeValue(args, ref i, a, result.File, result)) return;
				case "--new-ump-mod":
					result.NewUmpMod = true;
				case "--namespace":
					if (!TakeValue(args, ref i, a, result.Namespace, result)) return;
				case "--class":
					if (!TakeValue(args, ref i, a, result.ClassName, result)) return;
				case "--mod-id":
					if (!TakeValue(args, ref i, a, result.ModId, result)) return;
				case "--mod-name":
					if (!TakeValue(args, ref i, a, result.ModName, result)) return;
				case "--game":
					if (!TakeValue(args, ref i, a, result.GameId, result)) return;
				default:
					if (a.StartsWith("--"))
					{
						result.Action = .Usage;
						result.Error.Set(scope $"Unknown option '{a}'.");
						return;
					}
					if (!result.Path.IsEmpty)
					{
						result.Action = .Usage;
						result.Error.Set(scope $"Only one <folder-or-file> can be given ('{result.Path}', then '{a}').");
						return;
					}
					result.Path.Set(a);
				}
			}

			if (result.NewUmpMod)
			{
				if (result.ModId.IsEmpty)
				{
					result.Action = .Usage;
					result.Error.Set("--new-ump-mod needs --mod-id <id>.");
					return;
				}
				if (result.Path.IsEmpty && !System.IO.Path.IsPathRooted(result.File))
				{
					result.Action = .Usage;
					result.Error.Set("--new-ump-mod needs the project folder (or an absolute --file).");
					return;
				}
				if (!IsIdentifierPath(result.ClassName, false) || (!result.Namespace.IsEmpty && !IsIdentifierPath(result.Namespace, true)))
				{
					result.Action = .Usage;
					result.Error.Set("--namespace and --class must be Beef identifiers.");
					return;
				}
			}
		}

		/// `A`, `A_b2` (and `A.B` when dots are allowed); no leading digit.
		public static bool IsIdentifierPath(StringView s, bool allowDots)
		{
			if (s.IsEmpty)
				return false;
			bool start = true;
			for (let c in s.RawChars)
			{
				if (c == '.' && allowDots && !start)
				{
					start = true;
					continue;
				}
				if (!(c.IsLetterOrDigit || c == '_') || c >= (char8)128 || (start && c.IsDigit))
					return false;
				start = false;
			}
			return !start;
		}
	}

	/// What a host's project looks like to VisualBeef: a folder with BeefSpace.toml / BeefProj.toml, optionally a
	/// `.vbproject` marker whose `main` is the file to focus (UnrealUMP's visual mods write one).
	static class ProjectContract
	{
		public const String MarkerName = ".vbproject";
#if BF_PLATFORM_WINDOWS
		public const String DefaultMain = "src\\ModMain.bf";
#else
		public const String DefaultMain = "src/ModMain.bf";
#endif

		static bool IsProjectFolder(StringView dir)
		{
			return System.IO.File.Exists(scope $"{dir}{System.IO.Path.DirectorySeparatorChar}BeefSpace.toml") || System.IO.File.Exists(scope $"{dir}{System.IO.Path.DirectorySeparatorChar}BeefProj.toml") ||
				System.IO.File.Exists(scope $"{dir}{System.IO.Path.DirectorySeparatorChar}{MarkerName}");
		}

		public static void Normalize(StringView path, String outPath)
		{
			String full = scope .();
			if (Path.IsPathRooted(path))
				full.Set(path);
			else
			{
				String cwd = scope .();
				Directory.GetCurrentDirectory(cwd);
				Path.GetAbsolutePath(path, cwd, full);
			}
#if BF_PLATFORM_WINDOWS
			full.Replace('/', '\\');
			while (full.Length > 3 && full.EndsWith('\\'))
				full.RemoveFromEnd(1);
#else
			full.Replace('\\', '/');
			while (full.Length > 1 && full.EndsWith('/'))
				full.RemoveFromEnd(1);
#endif
			outPath.Set(full);
		}

		/// From `<folder-or-file>` (and `--file`): the folder to open and the file to focus ("" = none). A .bf file
		/// opens the nearest folder above it that has BeefSpace.toml / BeefProj.toml / .vbproject (else its own
		/// folder). False with `outError` when the path does not exist.
		public static bool ResolveTarget(StringView pathArg, StringView fileArg, String outRoot, String outFile, String outError)
		{
			outRoot.Clear();
			outFile.Clear();
			if (!pathArg.IsEmpty)
			{
				String path = scope .();
				Normalize(pathArg, path);
				if (Directory.Exists(path))
					outRoot.Set(path);
				else if (System.IO.File.Exists(path))
				{
					String dir = scope .();
					Path.GetDirectoryPath(path, dir).IgnoreError(); // a root has no parent: dir stays empty
					String name = scope .();
					Path.GetFileName(path, name);
					if (name.EndsWith(".bf", .OrdinalIgnoreCase))
					{
						outFile.Set(path);
						// Walk up to the project folder.
						String probe = scope .(dir);
						for (int guard < 16)
						{
							if (IsProjectFolder(probe))
							{
								outRoot.Set(probe);
								break;
							}
							String parent = scope .();
							if (Path.GetDirectoryPath(probe, parent) case .Err || parent.IsEmpty || parent.Length >= probe.Length)
								break;
							probe.Set(parent);
						}
						if (outRoot.IsEmpty)
							outRoot.Set(dir);
					}
					else
						outRoot.Set(dir); // .vbproject, BeefSpace.toml, BeefProj.toml (or any other file): its folder
				}
				else
				{
					outError.Set(scope $"'{pathArg}' does not exist.");
					return false;
				}
			}

			if (!fileArg.IsEmpty)
			{
				if (Path.IsPathRooted(fileArg) || outRoot.IsEmpty)
					Normalize(fileArg, outFile);
				else
				{
					String joined = scope $"{outRoot}{System.IO.Path.DirectorySeparatorChar}{fileArg}";
					Normalize(joined, outFile);
				}
				if (outRoot.IsEmpty)
				{
					String dir = scope .();
					Path.GetDirectoryPath(outFile, dir).IgnoreError(); // see above
					outRoot.Set(dir);
				}
			}
			else if (outFile.IsEmpty && !outRoot.IsEmpty)
			{
				String main = scope .();
				if (ReadMarkerMain(outRoot, main))
				{
					String joined = scope $"{outRoot}{System.IO.Path.DirectorySeparatorChar}{main}";
					Normalize(joined, outFile);
				}
			}
			return true;
		}

		/// `main` of `<root>\.vbproject` (project-relative, backslashes). False when there is no marker or no usable
		/// `main` (rooted paths and `..` are refused: the file must be inside the project).
		public static bool ReadMarkerMain(StringView root, String outRelative)
		{
			String text = scope .();
			if (System.IO.File.ReadAllText(scope $"{root}{System.IO.Path.DirectorySeparatorChar}{MarkerName}", text, true) case .Err)
				return false;
			int at = text.IndexOf("\"main\"");
			if (at < 0)
				return false;
			int colon = text.IndexOf(':', at + 6);
			if (colon < 0)
				return false;
			int open = text.IndexOf('"', colon);
			if (open < 0)
				return false;
			int close = text.IndexOf('"', open + 1);
			if (close < 0)
				return false;
			String value = scope .(text, open + 1, close - open - 1);
			value.Replace('/', '\\');
			if (value.IsEmpty || value.Contains("..") || value.Contains(':') || value.StartsWith('\\'))
				return false;
#if !BF_PLATFORM_WINDOWS
			value.Replace('\\', '/');
#endif
			outRelative.Set(value);
			return true;
		}

		/// `--new-ump-mod`: writes `TypeTemplates.MakeUMPMod` into `file` when it does not exist (never overwrites),
		/// and `<root>\.vbproject` when missing. `outCreated` lists what was written. Err with `outError` on I/O failure.
		public static Result<void> WriteUmpMod(EditorArgs args, StringView root, StringView file, List<String> outCreated, String outError)
		{
			String ns = scope .(args.Namespace);
			if (ns.IsEmpty)
			{
				// The project's name (BeefProj.toml [Project] Name), else the folder name, as an identifier.
				String name = scope .();
				LibraryIndex.ProjectName(root, name);
				for (let c in name.RawChars)
					if ((c.IsLetterOrDigit || c == '_') && c < (char8)128)
						ns.Append(c);
				if (ns.IsEmpty || ns[0].IsDigit)
					ns.Insert(0, "Mod");
			}
			String modName = scope .(args.ModName.IsEmpty ? args.ModId : args.ModName);

			if (!System.IO.File.Exists(file))
			{
				String text = scope .();
				TypeTemplates.MakeUMPMod(ns, args.ClassName, args.ModId, modName, args.ModVersion, text);
				String dir = scope .();
				Path.GetDirectoryPath(file, dir).IgnoreError(); // a rooted file always has a directory part
				if (!dir.IsEmpty && !Directory.Exists(dir) && Directory.CreateDirectory(dir) case .Err)
				{
					outError.Set(scope $"Could not create the folder {dir}.");
					return .Err;
				}
				if (System.IO.File.WriteAllText(file, text) case .Err)
				{
					outError.Set(scope $"Could not write {file}.");
					return .Err;
				}
				outCreated.Add(new String(file));
			}

			String marker = scope $"{root}{System.IO.Path.DirectorySeparatorChar}{MarkerName}";
			if (!System.IO.File.Exists(marker))
			{
				String rel = scope .();
				if (file.Length > root.Length + 1 && ProjectIndex.SamePath(file.Substring(0, root.Length), root))
					rel.Set(file.Substring(root.Length + 1));
				else
					rel.Set(file);
				rel.Replace('\\', '/');
				String text = scope .();
				MakeMarker(rel, args.GameId, args.ModId, text);
				if (System.IO.File.WriteAllText(marker, text) case .Err)
				{
					outError.Set(scope $"Could not write {marker}.");
					return .Err;
				}
				outCreated.Add(new String(marker));
			}
			return .Ok;
		}

		/// The `.vbproject` text: the same layout UnrealUMP's visual mod template writes (gameId only when known).
		public static void MakeMarker(StringView mainRelative, StringView gameId, StringView modId, String outText)
		{
			outText.Append("{\n  \"vbproject\": 1,\n  \"kind\": \"ump-mod\",\n  \"main\": ");
			AppendJsonString(outText, mainRelative);
			if (!gameId.IsEmpty)
			{
				outText.Append(",\n  \"gameId\": ");
				AppendJsonString(outText, gameId);
			}
			outText.Append(",\n  \"modId\": ");
			AppendJsonString(outText, modId);
			outText.Append("\n}\n");
		}

		static void AppendJsonString(String outText, StringView s)
		{
			outText.Append('"');
			for (let c in s.RawChars)
			{
				if (c == '"' || c == '\\')
					outText.Append('\\');
				outText.Append(c);
			}
			outText.Append('"');
		}
	}
}
