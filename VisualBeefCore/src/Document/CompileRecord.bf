using System;
using System.Collections;
using System.IO;

namespace VisualBeef.Document
{
	/// What the compile indicator shows for a workspace.
	enum CompileStatus
	{
		/// No record of a compile for this workspace (grey).
		NotCompiled,
		/// The sources match the last successful compile (green).
		UpToDate,
		/// Sources changed since the last compile, or there are unsaved edits (yellow).
		NeedsCompile,
		/// The last compile failed and the sources are unchanged since (red).
		Failed
	}

	/// The result of the last compile of a workspace and a content hash of its sources at that
	/// moment. The editor keeps one per workspace in settings.json (`projects.<folder>.compile`,
	/// as the text form below), so the indicator is right on the next start.
	class CompileRecord
	{
		public bool Ok;
		public String Config = new .() ~ delete _;
		/// DateTime ticks (UTC) when the compile finished.
		public int64 Time;
		public uint64 Hash;
		public int32 Errors;
		public int32 Warnings;

		/// `v1|ok|Debug|<ticks>|<hash hex>|errors|warnings`
		public void Encode(String outText)
		{
			outText.AppendF("v1|{}|{}|{}|{:x16}|{}|{}", Ok ? "ok" : "failed", Config, Time, Hash, Errors, Warnings);
		}

		public static CompileRecord Decode(StringView text)
		{
			List<StringView> parts = scope .();
			for (let p in text.Split('|'))
				parts.Add(p);
			if (parts.Count != 7 || parts[0] != "v1" || (parts[1] != "ok" && parts[1] != "failed"))
				return null;
			let rec = new CompileRecord();
			rec.Ok = parts[1] == "ok";
			rec.Config.Set(parts[2]);
			if (int64.Parse(parts[3]) case .Ok(let t))
				rec.Time = t;
			if (uint64.Parse(parts[4], .HexNumber) case .Ok(let h))
				rec.Hash = h;
			else
			{
				delete rec;
				return null;
			}
			if (int32.Parse(parts[5]) case .Ok(let e))
				rec.Errors = e;
			if (int32.Parse(parts[6]) case .Ok(let w))
				rec.Warnings = w;
			return rec;
		}

		/// The state transitions: no record -> grey; unsaved edits, changed sources or another
		/// configuration -> yellow; otherwise the recorded result (green / red).
		public static CompileStatus Decide(CompileRecord rec, uint64 currentHash, bool unsavedEdits, StringView currentConfig)
		{
			if (rec == null)
				return .NotCompiled;
			if (unsavedEdits || rec.Hash != currentHash)
				return .NeedsCompile;
			if (!currentConfig.IsEmpty && rec.Config != currentConfig)
				return .NeedsCompile;
			return rec.Ok ? .UpToDate : .Failed;
		}

		static void Collect(StringView dir, List<String> files, int depth)
		{
			if (depth > 24)
				return;
			for (let e in Directory.Enumerate(scope $"{dir}/*", .Files | .Directories))
			{
				String path = scope .();
				e.GetFilePath(path);
				String name = scope .();
				e.GetFileName(name);
				if (e.IsDirectory)
				{
					if (name == "build" || name == "recovery" || name.StartsWith('.'))
						continue;
					Collect(path, files, depth + 1);
				}
				else if (name.EndsWith(".bf", .OrdinalIgnoreCase) || name == "BeefSpace.toml" || name == "BeefProj.toml")
					files.Add(new String(path));
			}
		}

		/// A hash of the content of every source and project file under the workspace folder
		/// (names relative to it count, so a rename or a move changes it too).
		public static uint64 HashWorkspace(StringView root)
		{
			List<String> files = scope .();
			Collect(root, files, 0);
			defer { for (let f in files) delete f; }
			files.Sort(scope (a, b) => String.Compare(a, b, true));
			return HashFiles(root, files);
		}

		public static uint64 HashFiles(StringView root, List<String> files)
		{
			uint64 h = 14695981039346656037UL;
			String text = scope .();
			for (let f in files)
			{
				String rel = scope .(f);
				if (rel.StartsWith(root))
					rel.Remove(0, root.Length);
				rel.Replace('\\', '/');
				for (let c in rel.RawChars)
				{
					h ^= (uint8)c;
					h *= 1099511628211UL;
				}
				h ^= 0xFF;
				h *= 1099511628211UL;
				text.Clear();
				if (File.ReadAllText(f, text, false) case .Err)
					continue;
				for (let c in text.RawChars)
				{
					h ^= (uint8)c;
					h *= 1099511628211UL;
				}
				h ^= 0xFE;
				h *= 1099511628211UL;
			}
			return h;
		}
	}
}
