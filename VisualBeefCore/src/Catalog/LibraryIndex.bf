using System;
using System.Collections;
using System.IO;
using System.Diagnostics;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Catalog
{
	/// Just enough TOML for BeefSpace.toml / BeefProj.toml: `[Table]` headers, `key = "string"`,
	/// and inline tables `key = {A = "*", B = {Path = "x"}}`. Values are flattened to dotted keys:
	/// "Projects.GameKit.Path" = "GameKit", "Dependencies.corlib" = "*".
	class MiniToml
	{
		public List<(String key, String value)> Entries = new .() ~ { for (let e in _) { delete e.key; delete e.value; } delete _; };

		public static bool Load(StringView path, MiniToml outToml)
		{
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
				return false;
			outToml.Parse(text);
			return true;
		}

		public void Parse(StringView text)
		{
			String table = scope .();
			for (var line in text.Split('\n'))
			{
				line.Trim();
				if (line.IsEmpty || line.StartsWith('#'))
					continue;
				if (line.StartsWith('[') && !line.StartsWith("[["))
				{
					int close = line.IndexOf(']');
					table.Set((close > 0) ? line.Substring(1, close - 1) : line.Substring(1));
					table.Trim();
					continue;
				}
				int eq = line.IndexOf('=');
				if (eq <= 0)
					continue;
				var key = line.Substring(0, eq);
				key.Trim();
				key = Unquote(key);
				var value = line.Substring(eq + 1);
				value.Trim();
				String prefix = scope .(table);
				if (!prefix.IsEmpty)
					prefix.Append('.');
				prefix.Append(key);
				ParseValue(prefix, value);
			}
		}

		static StringView Unquote(StringView s)
		{
			var s;
			s.Trim();
			if (s.Length >= 2 && (s[0] == '"' || s[0] == '\'') && s[s.Length - 1] == s[0])
				return s.Substring(1, s.Length - 2);
			return s;
		}

		void ParseValue(StringView key, StringView value)
		{
			var value;
			value.Trim();
			if (value.StartsWith('{'))
			{
				// Inline table: split on top-level commas.
				int end = value.LastIndexOf('}');
				var inner = (end > 0) ? value.Substring(1, end - 1) : value.Substring(1);
				int depth = 0;
				bool inStr = false;
				int segStart = 0;
				for (int i = 0; i <= inner.Length; i++)
				{
					bool atEnd = i == inner.Length;
					char8 c = atEnd ? ',' : inner[i];
					if (c == '"' && !atEnd)
						inStr = !inStr;
					if (inStr)
						continue;
					if (c == '{' || c == '[')
						depth++;
					else if (c == '}' || c == ']')
						depth--;
					else if (c == ',' && depth == 0)
					{
						var part = inner.Substring(segStart, i - segStart);
						segStart = i + 1;
						int eq = part.IndexOf('=');
						if (eq <= 0)
							continue;
						var k = Unquote(part.Substring(0, eq));
						String sub = scope .(key);
						sub.AppendF(".{}", k);
						ParseValue(sub, part.Substring(eq + 1));
					}
				}
				return;
			}
			if (value.StartsWith('"'))
			{
				int close = value.Substring(1).IndexOf('"');
				value = (close >= 0) ? value.Substring(1, close) : value.Substring(1);
			}
			else
			{
				int hash = value.IndexOf('#');
				if (hash >= 0)
					value = value.Substring(0, hash);
				value.Trim();
			}
			Entries.Add((new String(key), new String(value)));
		}

		public StringView Get(StringView key)
		{
			for (let e in Entries)
				if (e.key == key)
					return e.value;
			return default;
		}

		/// Names directly under a table: Children("Projects") -> ["GameKit", "JsonKit", ...].
		public void Children(StringView table, List<StringView> outNames)
		{
			for (let e in Entries)
			{
				if (e.key.Length <= table.Length + 1 || !e.key.StartsWith(table) || e.key[table.Length] != '.')
					continue;
				var rest = e.key.Substring(table.Length + 1);
				int dot = rest.IndexOf('.');
				if (dot >= 0)
					rest = rest.Substring(0, dot);
				if (!outNames.Contains(rest))
					outNames.Add(rest);
			}
		}
	}

	/// One library to index: a Beef project outside the open folder (corlib, BeefLibs, workspace
	/// projects elsewhere on disk, generated SDKs).
	class LibraryRef
	{
		public String Name = new .() ~ delete _;
		/// The project folder (holds BeefProj.toml and src/).
		public String Dir = new .() ~ delete _;
	}

	/// Finds the libraries a project folder depends on and loads their symbol stores, parsing
	/// each library once and caching the result under %LOCALAPPDATA%\VisualBeef\index.
	static class LibraryIndex
	{
		public static String sBeefLibsDir = new .() ~ delete _;
		/// Overrides the cache folder (tests); empty = %LOCALAPPDATA%\VisualBeef\index.
		public static String sCacheDirOverride = new .() ~ delete _;

		/// Statistics of the last Load call, for tests and the status line.
		public static bool LastWasCacheHit;
		public static double LastMs;

		public static void BeefLibsDir(String outDir)
		{
			if (!sBeefLibsDir.IsEmpty)
			{
				outDir.Set(sBeefLibsDir);
				return;
			}
#if BF_PLATFORM_WINDOWS
			outDir.Set(@"C:\Program Files\BeefLang\BeefLibs");
#else
			// No standard install path on Linux: VB_BEEF_LIBS, else the BeefLibs of the source
			// tree that holds the BeefBuild on PATH (<beef>/IDE/dist/BeefBuild -> <beef>/BeefLibs).
			if (Environment.GetEnvironmentVariable("VB_BEEF_LIBS", outDir) case .Ok && !outDir.IsEmpty)
				return;
			outDir.Clear();
			String pathVar = scope .();
			Environment.GetEnvironmentVariable("PATH", pathVar).IgnoreError(); // PATH unset: no search
			for (let dir in pathVar.Split(':'))
			{
				if (dir.IsEmpty || !File.Exists(scope $"{dir}/BeefBuild"))
					continue;
				String libs = scope $"{dir}/../../BeefLibs";
				if (Directory.Exists(libs))
				{
					Path.GetFullPath(libs, outDir);
					if (!outDir.IsEmpty)
						return;
				}
			}
			outDir.Set("/usr/share/beef/BeefLibs");
#endif
		}

		public static void CacheDir(String outDir)
		{
			if (!sCacheDirOverride.IsEmpty)
			{
				outDir.Set(sCacheDirOverride);
				return;
			}
#if !BF_PLATFORM_WINDOWS
			// $XDG_CACHE_HOME/VisualBeef/index, else ~/.cache/VisualBeef/index.
			if (Environment.GetEnvironmentVariable("XDG_CACHE_HOME", outDir) case .Err || outDir.IsEmpty)
			{
				outDir.Clear();
				Environment.GetEnvironmentVariable("HOME", outDir).IgnoreError(); // HOME unset: relative ".cache"
				outDir.Append(outDir.IsEmpty ? ".cache" : "/.cache");
			}
			outDir.Append("/VisualBeef/index");
#else
			String local = scope .();
			if (Environment.GetEnvironmentVariable("LOCALAPPDATA", local) case .Err || local.IsEmpty)
			{
				Environment.GetEnvironmentVariable("TEMP", local).IgnoreError();
			}
			outDir.Set(local);
			outDir.Append(@"\VisualBeef\index");
#endif
		}

		static void Join(StringView dir, StringView rel, String outPath)
		{
			var rel;
			if (rel.Length >= 2 && (rel[1] == ':' || rel.StartsWith('/') || rel.StartsWith('\\')))
			{
				// Absolute (a host may write `D:/.../libs/<Project>`): one spelling for paths and cache keys.
				outPath.Set(rel);
				outPath.Replace('/', '\\');
#if !BF_PLATFORM_WINDOWS
				outPath.Replace('\\', '/');
#endif
				return;
			}
			outPath.Set(dir);
			while (rel.StartsWith("./") || rel.StartsWith(".\\"))
				rel = rel.Substring(2);
			if (rel == ".")
				return;
			if (!outPath.EndsWith('\\') && !outPath.EndsWith('/'))
				outPath.Append('\\');
			outPath.Append(rel);
			outPath.Replace('/', '\\');
			// Fold "a\b\..\c" -> "a\c"
			while (true)
			{
				int at = outPath.IndexOf("\\..\\");
				if (at <= 0)
					break;
				int prev = outPath.Substring(0, at).LastIndexOf('\\');
				if (prev < 0)
					break;
				outPath.Remove(prev, at + 3 - prev);
			}
#if !BF_PLATFORM_WINDOWS
			// The fold above works on '\\'; Linux paths use '/'.
			outPath.Replace('\\', '/');
#endif
		}

		/// The nearest BeefSpace.toml at or above `folder` (empty when none).
		public static void FindWorkspace(StringView folder, String outPath)
		{
			String dir = scope .(folder);
			for (int guard < 8)
			{
				String probe = scope .();
				Join(dir, "BeefSpace.toml", probe);
				if (File.Exists(probe))
				{
					outPath.Set(probe);
					return;
				}
				String parent = scope .();
				if (Path.GetDirectoryPath(dir, parent) case .Err || parent.IsEmpty || parent.Length >= dir.Length)
					return;
				dir.Set(parent);
			}
		}

		static bool IsUnder(StringView path, StringView folder)
		{
			if (folder.IsEmpty || path.Length < folder.Length)
				return false;
			if (!ProjectIndex.SamePath(path.Substring(0, folder.Length), folder))
				return false;
			return path.Length == folder.Length || path[folder.Length] == '\\' || path[folder.Length] == '/' ||
				folder.EndsWith('\\') || folder.EndsWith('/');
		}

		/// The project name in a folder's BeefProj.toml (`[Project] Name`), else the folder name.
		public static void ProjectName(StringView dir, String outName)
		{
			String projToml = scope .();
			Join(dir, "BeefProj.toml", projToml);
			MiniToml t = scope .();
			if (MiniToml.Load(projToml, t))
			{
				let name = t.Get("Project.Name");
				if (name.Ptr != null && !name.IsEmpty)
				{
					outName.Set(name);
					return;
				}
			}
			String trimmed = scope .(dir);
			while (trimmed.EndsWith('\\') || trimmed.EndsWith('/'))
				trimmed.RemoveFromEnd(1);
			Path.GetFileName(trimmed, outName);
		}

		/// Libraries the folder's projects use: corlib always, the dependencies named in every
		/// BeefProj.toml of the workspace (transitively), resolved to workspace projects outside the
		/// folder or to BeefLibs. Projects inside `folder` are skipped (the project index has them),
		/// except `generatedDirs`: generated library projects under the folder (see
		/// ProjectIndex.IsGeneratedLibrary), which are loaded as libraries first, and generated
		/// libraries a dependency path points at inside the folder that the scan did not reach.
		/// The libraries the folder's `.vbproject` names (docs/Host-Integration.md) are added too.
		public static void Discover(StringView folder, List<LibraryRef> outLibs, List<String> generatedDirs = null)
		{
			String libsDir = scope .();
			BeefLibsDir(libsDir);
			String wsPath = scope .();
			FindWorkspace(folder, wsPath);
			Dictionary<String, String> wsProjects = scope .(); // name -> dir
			defer { for (let kv in wsProjects) { delete kv.key; delete kv.value; } }
			List<String> pending = scope .();
			defer { ClearAndDeleteItems!(pending); }
			HashSet<String> seen = scope .();
			defer { for (let s in seen) delete s; }

			void AddDepsOf(StringView projDir)
			{
				String projToml = scope .();
				Join(projDir, "BeefProj.toml", projToml);
				MiniToml t = scope .();
				if (!MiniToml.Load(projToml, t))
					return;
				List<StringView> deps = scope .();
				t.Children("Dependencies", deps);
				for (let d in deps)
					pending.Add(new String(d));
			}

			if (!wsPath.IsEmpty)
			{
				String wsDir = scope .();
				Path.GetDirectoryPath(wsPath, wsDir).IgnoreError();
				MiniToml ws = scope .();
				if (MiniToml.Load(wsPath, ws))
				{
					List<StringView> names = scope .();
					ws.Children("Projects", names);
					for (let n in names)
					{
						String key = scope $"Projects.{n}.Path";
						let rel = ws.Get(key);
						if (rel.Ptr == null)
							continue;
						// A workspace that lists the same project name twice keeps the first entry; the indexer would
						// replace the value and leak both the old key and the old value.
						String nKey = scope .(n);
						if (wsProjects.ContainsKey(nKey))
							continue;
						String dir = new .();
						Join(wsDir, rel, dir);
						wsProjects[new String(n)] = dir;
						if (IsUnder(dir, folder) || IsUnder(folder, dir))
							AddDepsOf(dir);
					}
				}
			}
			else
			{
				// No workspace: projects found directly under the folder.
				AddDepsOf(folder);
				for (let entry in Directory.EnumerateDirectories(folder))
				{
					String sub = scope .();
					entry.GetFilePath(sub);
					AddDepsOf(sub);
				}
			}
			pending.Add(new String("corlib"));

			if (generatedDirs != null)
			{
				for (let gen in generatedDirs)
				{
					LibraryRef lib = new .();
					ProjectName(gen, lib.Name);
					lib.Dir.Set(gen);
					outLibs.Add(lib);
					{ String seenName = new String(lib.Name); if (!seen.Add(seenName)) delete seenName; }
					AddDepsOf(gen);
				}
			}

			while (!pending.IsEmpty)
			{
				let name = pending.PopBack();
				defer delete name;
				if (seen.Contains(name))
					continue;
				seen.Add(new String(name));
				String dir = scope .();
				bool generatedInside = false;
				if (wsProjects.TryGetValue(name, let wsDir))
				{
					if (IsUnder(wsDir, folder))
					{
						// Part of the project index already, unless it is a generated library the
						// project scan did not reach (under `build`, a dot folder, deeper than the scan): a
						// dependency path pointing at it still loads it as a cached library.
						if (!ProjectIndex.IsGeneratedLibrary(wsDir))
							continue;
						generatedInside = true;
					}
					dir.Set(wsDir);
				}
				else
				{
					Join(libsDir, name, dir);
					if (!Directory.Exists(dir))
						continue;
				}
				// The open folder is (inside) this library: the project index already has it.
				if (IsUnder(folder, dir) || (IsUnder(dir, folder) && !generatedInside))
					continue;
				LibraryRef lib = new .();
				lib.Name.Set(name);
				lib.Dir.Set(dir);
				outLibs.Add(lib);
				AddDepsOf(dir);
			}

			// Libraries the project manifest names that the workspace does not list.
			VisualBeef.Document.ProjectManifest manifest = scope .();
			if (manifest.Read(folder) && !manifest.Libraries.IsEmpty)
			{
				List<String> dirs = scope .();
				defer { ClearAndDeleteItems!(dirs); }
				manifest.LibraryDirs(folder, dirs);
				for (let d in dirs)
				{
					if (!Directory.Exists(d))
						continue;
					bool known = false;
					for (let l in outLibs)
						if (ProjectIndex.SamePath(l.Dir, d))
							known = true;
					String name = scope .();
					ProjectName(d, name);
					if (known || seen.Contains(name) || IsUnder(folder, d))
						continue;
					seen.Add(new String(name));
					LibraryRef lib = new .();
					lib.Name.Set(name);
					lib.Dir.Set(d);
					outLibs.Add(lib);
				}
			}
		}

		/// FNV-1a 64.
		public static uint64 Hash(StringView s, uint64 seed = 0xcbf29ce484222325)
		{
			uint64 h = seed;
			for (let c in s.RawChars)
			{
				h ^= (uint8)c.ToLower;
				h *= 0x100000001b3;
			}
			return h;
		}

		static uint64 HashInt(uint64 h, int64 v)
		{
			var h;
			var v;
			for (int i < 8)
			{
				h ^= (uint8)(v & 0xFF);
				h *= 0x100000001b3;
				v >>= 8;
			}
			return h;
		}

		/// Source files of a library: `src/` when it exists, else the folder.
		public static void LibraryFiles(StringView dir, List<String> outPaths)
		{
			String src = scope .();
			Join(dir, "src", src);
			ProjectIndex.CollectFiles(Directory.Exists(src) ? src : dir, 0, outPaths);
			outPaths.Sort(scope (a, b) => String.Compare(a, b, true));
		}

		/// Path + size + modification time of every file: changes whenever any file does.
		public static uint64 Signature(List<String> paths)
		{
			uint64 h = Hash("vbix");
			h = HashInt(h, SymbolStore.cVersion);
			for (let p in paths)
			{
				h = Hash(p, h);
				if (File.GetLastWriteTimeUtc(p) case .Ok(let dt))
					h = HashInt(h, dt.Ticks);
			}
			return h;
		}

		public static void CachePath(StringView libDir, String outPath)
		{
			String dir = scope .();
			CacheDir(dir);
			outPath.AppendF("{}{}{:X16}.bin", dir, Path.DirectorySeparatorChar, Hash(libDir));
		}

		/// The content-keyed cache file: `sdk-<content hash>.bin`, shared by every copy of a
		/// library with the same files (a regenerated SDK with identical output, the same SDK
		/// checked out twice, a launcher that pre-built the index).
		public static void ContentCachePath(uint64 contentHash, String outPath)
		{
			String dir = scope .();
			CacheDir(dir);
			outPath.AppendF("{}{}sdk-{:X16}.bin", dir, Path.DirectorySeparatorChar, contentHash);
		}

		/// Hash of every file's path relative to `libDir` and its bytes (FNV-1a 64, case-sensitive
		/// over the bytes). Reads the whole library, so it is used only when the cheap path +
		/// time signature missed. 0 when a file could not be read or the run was cancelled.
		public static uint64 ContentHash(StringView libDir, List<String> paths, IndexProgress progress = null)
		{
			uint64 h = Hash("vbcontent");
			h = HashInt(h, SymbolStore.cVersion);
			List<uint8> bytes = scope .();
			for (let p in paths)
			{
				if (progress != null && progress.Cancelled)
					return 0;
				StringView rel = p;
				if (p.Length > libDir.Length && ProjectIndex.SamePath(p.Substring(0, libDir.Length), libDir))
					rel = p.Substring(libDir.Length);
				while (rel.StartsWith('\\') || rel.StartsWith('/'))
					rel = rel.Substring(1);
				h = Hash(rel, h);
				bytes.Clear();
				if (File.ReadAll(p, bytes) case .Err)
					return 0;
				h = HashInt(h, bytes.Count);
				for (let b in bytes)
				{
					h ^= b;
					h *= 0x100000001b3;
				}
			}
			return (h == 0) ? 1 : h;
		}

		static void EnsureCacheDir()
		{
			String dir = scope .();
			CacheDir(dir);
			String parent = scope .();
			Path.GetDirectoryPath(dir, parent).IgnoreError();
			if (!parent.IsEmpty && !Directory.Exists(parent))
				Directory.CreateDirectory(parent).IgnoreError();
			if (!Directory.Exists(dir))
				Directory.CreateDirectory(dir).IgnoreError();
		}

		/// A store read from the content cache was built from a copy of the library elsewhere:
		/// point its file records at this copy's files. False when the files do not line up (the
		/// cache is then ignored).
		static bool RebaseFiles(SymbolStore store, StringView libDir, List<String> paths)
		{
			if (store.Files.Count != paths.Count)
				return false;
			for (int i < paths.Count)
			{
				let stored = store.Str(store.Files[i].Path);
				StringView rel = paths[i];
				if (rel.Length > libDir.Length)
					rel = rel.Substring(libDir.Length);
				while (rel.StartsWith('\\') || rel.StartsWith('/'))
					rel = rel.Substring(1);
				if (stored.Length < rel.Length || !ProjectIndex.SamePath(stored.Substring(stored.Length - rel.Length), rel))
					return false;
			}
			for (int i < paths.Count)
			{
				let p = paths[i];
				if (store.Str(store.Files[i].Path) == p)
					continue;
				store.Files[i].Path = .() { Off = (int32)store.Pool.Length, Len = (int32)p.Length };
				store.Pool.Append(p);
			}
			return true;
		}

		/// Loads one library: from its cache when every file is unchanged, else by parsing it
		/// (and writing the cache). Returns null when the folder has no sources.
		public static SymbolStore Load(LibraryRef lib, bool useCache = true)
		{
			let sw = scope Stopwatch(true);
			let store = Load(lib, useCache, null, let hit);
			LastWasCacheHit = hit;
			LastMs = sw.Elapsed.TotalMilliseconds;
			return store;
		}

		/// Loads one library, reporting progress and honouring cancellation (null when cancelled
		/// or when the folder has no sources). Three steps, cheapest first:
		///  1. the path-keyed cache, checked against a signature of every file's path, size and
		///     modification time (no file is read);
		///  2. the content-keyed cache (`sdk-<hash>.bin`), checked against a hash of every file's
		///     bytes: a regenerated or copied SDK with the same content loads without parsing;
		///  3. a full parse, which writes both caches.
		public static SymbolStore Load(LibraryRef lib, bool useCache, IndexProgress progress, out bool cacheHit)
		{
			cacheHit = false;
			List<String> paths = scope .();
			defer { ClearAndDeleteItems!(paths); }
			LibraryFiles(lib.Dir, paths);
			if (paths.IsEmpty)
				return null;
			let sig = Signature(paths);
			String cachePath = scope .();
			CachePath(lib.Dir, cachePath);
			SymbolStore store = new .();
			if (useCache && store.Load(cachePath, sig) case .Ok)
			{
				store.Name.Set(lib.Name);
				store.Root.Set(lib.Dir);
				store.IsLibrary = true;
				cacheHit = true;
				return store;
			}
			uint64 content = 0;
			String contentPath = scope .();
			if (useCache)
			{
				progress?.SetPhase(scope $"Checking library {lib.Name}", 0);
				content = ContentHash(lib.Dir, paths, progress);
				if (content != 0)
				{
					ContentCachePath(content, contentPath);
					if (store.Load(contentPath, content) case .Ok)
					{
						if (RebaseFiles(store, lib.Dir, paths))
						{
							store.Name.Set(lib.Name);
							store.Root.Set(lib.Dir);
							store.IsLibrary = true;
							// Re-key the path cache so the next start is a stat-only hit.
							store.Signature = sig;
							EnsureCacheDir();
							store.Save(cachePath).IgnoreError();
							cacheHit = true;
							return store;
						}
					}
				}
			}
			if (progress != null && progress.Cancelled)
			{
				delete store;
				return null;
			}
			progress?.SetPhase(scope $"Indexing library {lib.Name}", (.)paths.Count);
			ProjectIndex index = scope .();
			index.Root.Set(lib.Dir);
			for (let path in paths)
			{
				if (progress != null && progress.Cancelled)
				{
					delete store;
					return null;
				}
				String text = scope .();
				if (File.ReadAllText(path, text, true) case .Err)
				{
					progress?.Step();
					continue;
				}
				let unit = Parser.Parse(text);
				index.AddFile(path, unit);
				delete unit;
				progress?.Step();
			}
			store.BuildFrom(index);
			store.Name.Set(lib.Name);
			store.Root.Set(lib.Dir);
			store.IsLibrary = true;
			if (useCache)
			{
				EnsureCacheDir();
				if (content != 0)
				{
					store.Signature = content;
					store.Save(contentPath).IgnoreError();
				}
				store.Signature = sig;
				store.Save(cachePath).IgnoreError();
			}
			store.Signature = sig;
			return store;
		}
	}
}
