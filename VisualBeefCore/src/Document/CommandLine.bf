using System;
using System.IO;
using System.Collections;
using VisualBeef.Catalog;

namespace VisualBeef.Document
{
	/// VisualBeef's own version and the version of the contract host tools start it with (docs/Host-Integration.md).
	/// Bump `HostContract` when the command line, the template manifest or the project manifest change shape.
	static class VisualBeefInfo
	{
		public const String Version = "0.2.3";
		/// Release channel of this build ("alpha"); shown by --version, the window title and VERSION.txt.
		public const String Channel = "alpha";
		public const int HostContract = 1;
		public const String Name = "VisualBeef";

		/// The `--version` line: "VisualBeef 0.2.2-alpha (host contract 1)".
		public static void VersionLine(String outText)
		{
			outText.AppendF("{} {}-{} (host contract {})", Name, Version, Channel, HostContract);
		}
	}

	/// The editor's command line (docs/Host-Integration.md > Command line):
	///
	///   VisualBeefEditor.exe [<folder-or-file>] [--file <bf>] [--view]
	///   VisualBeefEditor.exe --new-from-template <template folder> <destination> [--name <n>] [--var KEY=VALUE]... [--file <bf>] [--no-open]
	///   VisualBeefEditor.exe --version | --help
	///
	/// Parsing is separate from acting on it so the rules are testable (`VisualBeefTests host`).
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
		/// The editor could not start, or a project could not be written from a template.
		public const int ExitFailed = 1;
		/// Unknown option, missing value, a path that does not exist.
		public const int ExitUsage = 2;

		/// The option an older host may still pass. It is mapped onto `--new-from-template` (or onto a plain open when
		/// no template folder is given) for one release, with `Deprecation` printed to stderr.
		public const String DeprecatedNewOption = "--new-ump-mod";

		public Kind Action = .Open;
		public String Error = new .() ~ delete _;
		/// The positional `<folder-or-file>` as given ("" when none).
		public String Path = new .() ~ delete _;
		/// `--file <bf>` as given (absolute, or relative to the project folder).
		public String File = new .() ~ delete _;
		public bool View;

		/// `--new-from-template`: write a project from `TemplateDir` into `Destination`, then open it.
		public bool NewFromTemplate;
		public String TemplateDir = new .() ~ delete _;
		public String Destination = new .() ~ delete _;
		/// `--name`: the project's name (`@@Name@@`); default the destination folder's name.
		public String Name = new .() ~ delete _;
		/// `--var KEY=VALUE`, in order.
		public List<(String key, String value)> Vars = new .() ~ { for (let v in _) { delete v.key; delete v.value; } delete _; };
		/// `--no-open`: exit after writing the project.
		public bool NoOpen;
		/// Existing files are kept instead of refusing the whole project (the deprecated option's rule).
		public bool KeepExisting;
		/// A line for stderr when a deprecated option was used ("" otherwise).
		public String Deprecation = new .() ~ delete _;

		public bool IsEmpty => Action == .Open && Path.IsEmpty && File.IsEmpty && !NewFromTemplate && !View;

		public const String Usage = """
			Usage: VisualBeefEditor.exe [<folder-or-file>] [--file <bf>] [--view]
			       VisualBeefEditor.exe --new-from-template <template folder> <destination> [--name <name>] [--var KEY=VALUE]...
			                            [--file <bf>] [--no-open]
			       VisualBeefEditor.exe --version | --help

			  <folder-or-file>     a project folder (BeefSpace.toml / BeefProj.toml / .vbproject), one of those files
			                       (opens its folder), or a .bf file (opens the folder of its project and that file)
			  --file <bf>          the file to focus (absolute, or relative to the project folder); default: "main" of .vbproject
			  --view               read-only: nothing is ever written to the project
			  --new-from-template  write a new project from a template folder (its template.json) into <destination>,
			                       then open it; existing files are never overwritten (nothing is written then)
			  --name <name>        the project's name (@@Name@@ in the template); default: the destination folder's name
			  --var KEY=VALUE      a template variable (@@KEY@@); may be repeated
			  --no-open            exit after writing the project
			  --version            print the VisualBeef version and the host contract number, and exit

			Exit codes: 0 ok, 1 failed (window or project could not be created), 2 bad command line.
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

		/// `KEY=VALUE` with a key of letters, digits, `_` and `.`.
		static bool SplitVar(StringView text, String outKey, String outValue)
		{
			int eq = text.IndexOf('=');
			if (eq <= 0)
				return false;
			let key = text.Substring(0, eq);
			for (let c in key.RawChars)
				if (!(c.IsLetterOrDigit || c == '_' || c == '.') || c >= (char8)128)
					return false;
			outKey.Set(key);
			outValue.Set(text.Substring(eq + 1));
			return true;
		}

		void AddVar(StringView key, StringView value)
		{
			for (let v in Vars)
				if (v.key == key)
				{
					v.value.Set(value);
					return;
				}
			Vars.Add((new String(key), new String(value)));
		}

		public static void Parse(Span<String> args, EditorArgs result)
		{
			bool old = false;
			for (let a in args)
				if (a == DeprecatedNewOption)
					old = true;
			// The deprecated option's values, mapped onto template variables below.
			String modId = scope .();
			String modName = scope .();
			String ns = scope .();
			String className = scope .();
			String modVersion = scope .();
			String gameId = scope .();

			for (int i = 0; i < args.Length; i++)
			{
				let a = args[i];
				switch (a)
				{
				case "--help", "-h", "/?":
					result.Action = .PrintHelp;
					return;
				case "--version", "-v":
					// After the deprecated option, `--version <v>` was the project's version.
					if (old && i + 1 < args.Length && !args[i + 1].StartsWith("--"))
					{
						i++;
						modVersion.Set(args[i]);
						continue;
					}
					result.Action = .PrintVersion;
					return;
				case "--view", "-view":
					result.View = true;
				case "--file":
					if (!TakeValue(args, ref i, a, result.File, result)) return;
				case "--new-from-template":
					result.NewFromTemplate = true;
					if (!TakeValue(args, ref i, a, result.TemplateDir, result) || !TakeValue(args, ref i, a, result.Destination, result))
					{
						result.Error.Set("--new-from-template needs a template folder and a destination folder.");
						return;
					}
				case "--name":
					if (!TakeValue(args, ref i, a, result.Name, result)) return;
				case "--var":
					String text = scope .();
					if (!TakeValue(args, ref i, a, text, result)) return;
					String key = scope .();
					String value = scope .();
					if (!SplitVar(text, key, value))
					{
						result.Action = .Usage;
						result.Error.Set(scope $"--var needs KEY=VALUE with a key of letters, digits, '_' or '.' ('{text}').");
						return;
					}
					result.AddVar(key, value);
				case "--no-open":
					result.NoOpen = true;
				case DeprecatedNewOption:
					// mapped below
				case "--template":
					if (!TakeValue(args, ref i, a, result.TemplateDir, result)) return;
				case "--mod-id":
					if (!TakeValue(args, ref i, a, modId, result)) return;
				case "--mod-name":
					if (!TakeValue(args, ref i, a, modName, result)) return;
				case "--namespace":
					if (!TakeValue(args, ref i, a, ns, result)) return;
				case "--class":
					if (!TakeValue(args, ref i, a, className, result)) return;
				case "--game":
					if (!TakeValue(args, ref i, a, gameId, result)) return;
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

			if (old)
			{
				result.Deprecation.AppendF("VisualBeef: {} is deprecated and will be removed in the next release; use --new-from-template <template folder> <destination> (docs/Host-Integration.md).", DeprecatedNewOption);
				if (modId.IsEmpty)
				{
					result.Action = .Usage;
					result.Error.AppendF("{} needs --mod-id <id>.", DeprecatedNewOption);
					return;
				}
				if (result.Path.IsEmpty && !System.IO.Path.IsPathRooted(result.File))
				{
					result.Action = .Usage;
					result.Error.AppendF("{} needs the project folder (or an absolute --file).", DeprecatedNewOption);
					return;
				}
				if ((!className.IsEmpty && !IsIdentifierPath(className, false)) || (!ns.IsEmpty && !IsIdentifierPath(ns, true)))
				{
					result.Action = .Usage;
					result.Error.Set("--namespace and --class must be Beef identifiers.");
					return;
				}
				// The old call filled in an existing project folder: with a template folder (`--template`) it is
				// --new-from-template into that folder, keeping every file that exists; without one nothing is written
				// and the project opens (the host writes its own files).
				result.AddVar("Id", modId);
				result.AddVar("ModId", modId);
				result.AddVar("ModName", modName.IsEmpty ? modId : modName);
				if (!ns.IsEmpty) result.AddVar("Namespace", ns);
				if (!className.IsEmpty) result.AddVar("Class", className);
				result.AddVar("Version", modVersion.IsEmpty ? "0.1.0" : modVersion);
				if (!gameId.IsEmpty) result.AddVar("GameId", gameId);
				if (!result.TemplateDir.IsEmpty)
				{
					result.NewFromTemplate = true;
					result.KeepExisting = true;
					result.Name.Set(modName.IsEmpty ? modId : modName);
					if (!result.Path.IsEmpty)
						result.Destination.Set(result.Path);
					else
						System.IO.Path.GetDirectoryPath(result.File, result.Destination).IgnoreError(); // rooted: it has a folder
					result.Path.Clear();
				}
				return;
			}

			if (!result.TemplateDir.IsEmpty && !result.NewFromTemplate)
			{
				result.Action = .Usage;
				result.Error.Set("--template is only read with --new-from-template.");
				return;
			}
			if (result.NewFromTemplate && !result.Path.IsEmpty)
			{
				result.Action = .Usage;
				result.Error.Set(scope $"--new-from-template opens the destination folder; '{result.Path}' cannot be opened as well.");
				return;
			}
			if (!result.NewFromTemplate && (!result.Name.IsEmpty || !result.Vars.IsEmpty || result.NoOpen))
			{
				result.Action = .Usage;
				result.Error.Set("--name, --var and --no-open are only read with --new-from-template.");
				return;
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

	/// What a project looks like to VisualBeef on the command line: a folder with BeefSpace.toml / BeefProj.toml,
	/// optionally a `.vbproject` manifest (ProjectManifest) whose `main` is the file to focus.
	static class ProjectContract
	{
		public const String MarkerName = ProjectManifest.FileName;

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

		/// `main` of `<root>\.vbproject` (project-relative, platform separators). False when there is no manifest or no
		/// usable `main` (rooted paths and `..` are refused: the file must be inside the project).
		public static bool ReadMarkerMain(StringView root, String outRelative) => ProjectManifest.ReadMain(root, outRelative);

		/// `--new-from-template`: writes the project. `outRoot` / `outFile` are the folder and file to open. Returns the
		/// exit code to stop with (ExitUsage, ExitFailed), or -1 to carry on; `outLines` are for stdout.
		public static int WriteFromTemplate(EditorArgs args, String outRoot, String outFile, List<String> outLines, String outError)
		{
			String tpl = scope .();
			Normalize(args.TemplateDir, tpl);
			if (!Directory.Exists(tpl))
			{
				outError.Set(scope $"The template folder '{args.TemplateDir}' does not exist.");
				return EditorArgs.ExitUsage;
			}
			String dest = scope .();
			Normalize(args.Destination, dest);
			List<String> created = scope .();
			defer { ClearAndDeleteItems!(created); }
			String main = scope .();
			if (!ProjectKind.CreateFromTemplate(tpl, dest, args.Name, args.Vars, args.KeepExisting ? .Skip : .Refuse, created, main, outError))
				return EditorArgs.ExitFailed;
			for (let c in created)
				outLines.Add(new String(scope $"Created {c}"));
			if (created.IsEmpty)
				outLines.Add(new String("Every file of the template exists already; nothing was written."));
			outRoot.Set(dest);
			if (!args.File.IsEmpty)
			{
				if (Path.IsPathRooted(args.File))
					Normalize(args.File, outFile);
				else
					Normalize(scope $"{dest}{System.IO.Path.DirectorySeparatorChar}{args.File}", outFile);
			}
			else
				outFile.Set(main);
			return -1;
		}
	}
}
