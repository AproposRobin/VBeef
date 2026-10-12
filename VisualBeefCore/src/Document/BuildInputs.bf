using System;
using System.Collections;
using System.IO;

namespace VisualBeef.Document
{
	/// Everything a BeefBuild run of a workspace reads, as one number, so Compile can tell that
	/// nothing changed since the last successful compile and skip the run (BeefBuild keeps no
	/// state between runs: even with nothing changed it checks every type again, which takes
	/// seconds on a project with a large library).
	///
	/// Taken from folder listings only (no file is read): the name, size and write time of every
	/// file under the workspace folder and under each project folder outside it, of the Beef
	/// libraries the projects use by version (corlib, `BeefLibs/<name>`), of BeefBuild and its
	/// compiler, plus the configuration and platform. `build`, `recovery` and dot folders are
	/// skipped (BeefBuild writes into `build`), and `BeefSpace_Lock.toml`, which BeefBuild
	/// rewrites on every run, counts by its content. A file touched without a change only costs
	/// a real compile; a change is never missed.
	static class BuildInputs
	{
		/// More files than this: no fingerprint (0), every compile runs BeefBuild.
		public const int MaxFiles = 200000;

		const uint64 cPrime = 1099511628211UL;

		static void Mix(ref uint64 h, StringView s)
		{
			for (let c in s.RawChars)
			{
				h ^= (uint8)c.ToLower;
				h *= cPrime;
			}
			h ^= 0xFF;
			h *= cPrime;
		}

		static void Mix(ref uint64 h, uint64 v)
		{
			h ^= v;
			h *= cPrime;
		}

		/// One folder, recursively: the entries sorted by name so the order never depends on
		/// the file system. False when the file budget ran out.
		static bool AddFolder(StringView dir, int depth, ref uint64 h, ref int files)
		{
			if (depth > 32)
				return true;
			List<(String name, bool isDir, int64 size, int64 time)> entries = scope .();
			defer { for (let e in entries) delete e.name; }
			for (let e in Directory.Enumerate(scope $"{dir}/*", .Files | .Directories))
			{
				String name = new .();
				e.GetFileName(name);
				if (e.IsDirectory && (name == "build" || name == "recovery" || name.StartsWith('.')))
				{
					delete name;
					continue;
				}
				int64 size = 0;
				int64 time = 0;
				if (!e.IsDirectory)
				{
					size = e.GetFileSize();
					time = e.GetLastWriteTimeUtc().Ticks;
				}
				entries.Add((name, e.IsDirectory, size, time));
			}
			entries.Sort(scope (a, b) => String.Compare(a.name, b.name, true));
			for (let e in entries)
			{
				Mix(ref h, e.name);
				if (e.isDir)
				{
					Mix(ref h, 0x44);
					if (!AddFolder(scope $"{dir}/{e.name}", depth + 1, ref h, ref files))
						return false;
					Mix(ref h, 0x45);
				}
				else
				{
					if (++files > MaxFiles)
						return false;
					if (e.name == "BeefSpace_Lock.toml")
					{
						// BeefBuild writes the lock file of git dependencies on every run: its
						// content counts, not its write time.
						String text = scope .();
						if (File.ReadAllText(scope $"{dir}/{e.name}", text, true) case .Ok)
							Mix(ref h, text);
						continue;
					}
					Mix(ref h, (uint64)e.size);
					Mix(ref h, (uint64)e.time);
				}
			}
			return true;
		}

		static void AddFile(StringView path, ref uint64 h)
		{
			Mix(ref h, path);
			if (File.GetLastWriteTime(path) case .Ok(let t))
				Mix(ref h, (uint64)t.Ticks);
			else
				Mix(ref h, 0x4D);
		}

		/// The folders BeefBuild reads for this workspace: the workspace folder, project folders
		/// outside it, and the Beef libraries named by version (corlib always). Absolute paths.
		public static void Folders(StringView wsDir, StringView beefBuildExe, List<String> outFolders)
		{
			outFolders.Add(new String(wsDir));
			BeefWorkspace space = scope .();
			String wsFile = scope .();
			WorkspaceFiles.Join(wsDir, "BeefSpace.toml", wsFile);
			if (!space.Load(wsFile))
				return;
			List<String> libraries = scope .();
			defer { for (let l in libraries) delete l; }
			void AddLibrary(StringView name)
			{
				let inSpace = space.Find(name);
				if (inSpace != null && inSpace.HasPath)
					return;
				for (let l in libraries)
					if (StringView.Compare(l, name, true) == 0)
						return;
				libraries.Add(new String(name));
			}
			AddLibrary("corlib");
			for (let p in space.Projects)
			{
				if (!p.HasPath)
				{
					AddLibrary(p.Name);
					continue;
				}
				if (!ProjectIndex.SamePath(p.Dir, wsDir) && !WorkspaceFiles.IsUnder(p.Dir, wsDir))
				{
					bool dup = false;
					for (let f in outFolders)
						if (ProjectIndex.SamePath(f, p.Dir) || WorkspaceFiles.IsUnder(p.Dir, f))
							dup = true;
					if (!dup)
						outFolders.Add(new String(p.Dir));
				}
				// Dependencies named in the project but not in the workspace come from BeefLibs.
				String projText = scope .();
				String projFile = scope .();
				WorkspaceFiles.Join(p.Dir, "BeefProj.toml", projFile);
				if (File.ReadAllText(projFile, projText, true) case .Ok)
				{
					TomlText t = scope .();
					t.Set(projText);
					List<(String key, String raw)> deps = scope .();
					defer { for (let d in deps) { delete d.key; delete d.raw; } }
					t.MapEntries("Dependencies", deps);
					for (let d in deps)
						AddLibrary(d.key);
				}
			}
			String beefLibs = scope .();
			if (BeefLibsDir(beefBuildExe, beefLibs))
			{
				libraries.Sort(scope (a, b) => String.Compare(a, b, true));
				for (let name in libraries)
				{
					String dir = scope .();
					WorkspaceFiles.Join(beefLibs, name, dir);
					if (Directory.Exists(dir))
						outFolders.Add(new String(dir));
				}
			}
		}

		/// `<Beef>/BeefLibs` beside the folder of BeefBuild (`<Beef>/bin/BeefBuild.exe`).
		public static bool BeefLibsDir(StringView beefBuildExe, String outDir)
		{
			String bin = scope .();
			if (Path.GetDirectoryPath(beefBuildExe, bin) case .Err || bin.IsEmpty)
				return false;
			String root = scope .();
			if (Path.GetDirectoryPath(bin, root) case .Err || root.IsEmpty)
				return false;
			WorkspaceFiles.Join(root, "BeefLibs", outDir);
			return Directory.Exists(outDir);
		}

		/// The fingerprint of a compile's inputs; 0 when it cannot be taken (no workspace, too
		/// many files), and then the compile always runs.
		public static uint64 Fingerprint(StringView wsDir, StringView beefBuildExe, StringView config, StringView platform)
		{
			String wsFile = scope .();
			WorkspaceFiles.Join(wsDir, "BeefSpace.toml", wsFile);
			if (!File.Exists(wsFile))
				return 0;
			uint64 h = 14695981039346656037UL;
			Mix(ref h, config);
			Mix(ref h, platform);
			Mix(ref h, beefBuildExe);
			AddFile(beefBuildExe, ref h);
			String bin = scope .();
			if (Path.GetDirectoryPath(beefBuildExe, bin) case .Ok)
			{
				// The compiler lives in IDEHelper; BeefConfig.toml names the library registry.
				for (let name in StringView[3]("IDEHelper64.dll", "libIDEHelper.so", "BeefConfig.toml"))
				{
					String p = scope .();
					WorkspaceFiles.Join(bin, name, p);
					if (File.Exists(p))
						AddFile(p, ref h);
				}
			}
			List<String> folders = scope .();
			defer { for (let f in folders) delete f; }
			Folders(wsDir, beefBuildExe, folders);
			int files = 0;
			for (let dir in folders)
			{
				Mix(ref h, dir);
				if (!AddFolder(dir, 0, ref h, ref files))
					return 0;
			}
			return (h == 0) ? 1 : h;
		}

		/// Size and write time of a file as one number (0: missing).
		public static uint64 FileStamp(StringView path)
		{
			String dir = scope .();
			String name = scope .();
			if (Path.GetDirectoryPath(path, dir) case .Err || dir.IsEmpty)
				return 0;
			Path.GetFileName(path, name);
			for (let e in Directory.EnumerateFiles(dir, name))
			{
				uint64 h = 14695981039346656037UL;
				Mix(ref h, (uint64)e.GetFileSize());
				Mix(ref h, (uint64)e.GetLastWriteTimeUtc().Ticks);
				return (h == 0) ? 1 : h;
			}
			return 0;
		}
	}

	/// What the last successful compile of a workspace was built from (BuildInputs) and the file
	/// it produced, kept per workspace in settings.json (`projects.<folder>.compileInputs`):
	/// `v1|<config>|<inputs hex>|<output path>|<output stamp hex>`.
	class CompileInputs
	{
		public String Config = new .() ~ delete _;
		public uint64 Inputs;
		public String OutputPath = new .() ~ delete _;
		public uint64 OutputStamp;

		public void Encode(String outText)
		{
			outText.AppendF("v1|{}|{:x16}|{}|{:x16}", Config, Inputs, OutputPath, OutputStamp);
		}

		public static CompileInputs Decode(StringView text)
		{
			List<StringView> parts = scope .();
			for (let p in text.Split('|'))
				parts.Add(p);
			if (parts.Count != 5 || parts[0] != "v1")
				return null;
			let rec = new CompileInputs();
			rec.Config.Set(parts[1]);
			rec.OutputPath.Set(parts[3]);
			if (uint64.Parse(parts[2], .HexNumber) case .Ok(let i))
				rec.Inputs = i;
			if (uint64.Parse(parts[4], .HexNumber) case .Ok(let o))
				rec.OutputStamp = o;
			if (rec.Inputs == 0 || rec.OutputStamp == 0)
			{
				delete rec;
				return null;
			}
			return rec;
		}

		/// True when a compile with these inputs would build what is already there: the same
		/// configuration and inputs as the last successful compile, and its output unchanged.
		public bool Covers(StringView config, uint64 inputs)
		{
			if (inputs == 0 || Inputs != inputs || Config != config || OutputPath.IsEmpty)
				return false;
			return BuildInputs.FileStamp(OutputPath) == OutputStamp;
		}
	}
}
