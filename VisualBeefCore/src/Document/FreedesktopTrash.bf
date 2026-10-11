#if !BF_PLATFORM_WINDOWS
using System;
using System.IO;

namespace VisualBeef.Document
{
	/// The freedesktop.org Trash (Trash specification 1.0), the Linux counterpart of the Windows
	/// Recycle Bin delete in FileSafety.MoveToRecycleBin: a file or folder is renamed into
	/// `files/` of a trash folder with an `info/<name>.trashinfo` next to it (original path and
	/// deletion date), so the desktop's file manager lists it and can restore it.
	///
	/// * A path on the same file system as the home trash (`$XDG_DATA_HOME/Trash`, else
	///   `~/.local/share/Trash`) goes there, with an absolute `Path=`.
	/// * A path on another file system goes to that file system's top folder: `$top/.Trash/$uid`
	///   when the administrator made `$top/.Trash` (a sticky folder, not a link), else
	///   `$top/.Trash-$uid`, with `Path=` relative to `$top`.
	/// * Anything else (no trash can be made, the rename fails) deletes nothing.
	///
	/// The trash name is unique by creating the `.trashinfo` with O_EXCL first (`name`, `name.2`,
	/// `name.3`, ...), as the specification asks. `directorysizes` is not written (optional).
	static class FreedesktopTrash
	{
		[CLink] static extern int32 lstat(char8* path, uint8* buf);
		[CLink] static extern int32 stat(char8* path, uint8* buf);
		[CLink] static extern int32 open(char8* path, int32 flags, int32 mode);
		[CLink] static extern int write(int32 fd, void* data, int count);
		[CLink] static extern int32 fsync(int32 fd);
		[CLink] static extern int32 close(int32 fd);
		[CLink] static extern int32 unlink(char8* path);
		[CLink] static extern int32 rename(char8* from, char8* to);
		[CLink] static extern int32 mkdir(char8* path, uint32 mode);
		[CLink] static extern uint32 getuid();
		[CLink] static extern int32* __errno_location();
		[CLink] static extern int time(int* t);
		[CLink] static extern Tm* localtime_r(int* time, Tm* result);

		[CRepr]
		struct Tm
		{
			public int32 tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst;
			public int tm_gmtoff;
			public char8* tm_zone;
		}

		const int32 EEXIST = 17;
		const uint32 S_IFMT = 0xF000;
		const uint32 S_IFDIR = 0x4000;
		const uint32 S_IFLNK = 0xA000;
		const uint32 S_ISVTX = 0x200;

		/// x86-64 `struct stat` (144 bytes): st_dev at 0, st_mode at 24.
		struct StatBuf
		{
			public uint8[144] Raw;
			public uint64 Dev() mut => *(uint64*)&Raw[0];
			public uint32 Mode() mut => *(uint32*)&Raw[24];
		}

		static bool Stat(StringView path, out StatBuf st, bool follow = true)
		{
			st = default;
			let c = path.ToScopeCStr!();
			return (follow ? stat(c, &st.Raw[0]) : lstat(c, &st.Raw[0])) == 0;
		}

		/// `$XDG_DATA_HOME/Trash` (an absolute XDG_DATA_HOME only), else `~/.local/share/Trash`.
		public static void HomeTrash(String outDir)
		{
			String v = scope .();
			if (Environment.GetEnvironmentVariable("XDG_DATA_HOME", v) case .Ok && v.StartsWith('/'))
			{
				while (v.Length > 1 && v.EndsWith('/'))
					v.RemoveFromEnd(1);
				outDir.AppendF("{}/Trash", v);
				return;
			}
			v.Clear();
			Environment.GetEnvironmentVariable("HOME", v).IgnoreError(); // no HOME: no home trash (checked by the caller)
			while (v.Length > 1 && v.EndsWith('/'))
				v.RemoveFromEnd(1);
			if (!v.IsEmpty)
				outDir.AppendF("{}/.local/share/Trash", v);
		}

		/// mkdir -p with mode 0700 for what it creates.
		static bool MakeDirs(StringView dir)
		{
			if (Directory.Exists(dir))
				return true;
			String parent = scope .();
			if (Path.GetDirectoryPath(dir, parent) case .Ok && !parent.IsEmpty && parent != dir && !MakeDirs(parent))
				return false;
			return mkdir(dir.ToScopeCStr!(), 0x1C0 /* 0700 */) == 0 || Directory.Exists(dir);
		}

		/// Percent-encodes a path for `Path=` (RFC 2396 as the spec asks; '/' kept).
		public static void EncodePath(StringView path, String outText)
		{
			for (let c in path.RawChars)
			{
				let b = (uint8)c;
				if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '-' || c == '_' || c == '.' || c == '~')
					outText.Append(c);
				else
					outText.AppendF("%{:X2}", b);
			}
		}

		/// The top folder of the mount holding `path`: walk up while the device stays the same.
		static void MountTop(StringView path, uint64 dev, String outTop)
		{
			String cur = scope .(path);
			while (true)
			{
				String parent = scope .();
				if (Path.GetDirectoryPath(cur, parent) case .Err || parent.IsEmpty || parent == cur)
					break;
				if (!Stat(parent, var st) || st.Dev() != dev)
					break;
				cur.Set(parent);
			}
			outTop.Set(cur);
		}

		/// The trash folder for `full` (absolute): its `files`/`info` exist when this returns true.
		/// `outTop` is empty for the home trash, else the mount top the `Path=` is relative to.
		static bool PickTrash(StringView full, uint64 dev, String outTrash, String outTop)
		{
			String home = scope .();
			HomeTrash(home);
			if (!home.IsEmpty)
			{
				// The home trash's device: the trash itself, else the nearest existing parent.
				String probe = scope .(home);
				StatBuf hs = default;
				while (!Stat(probe, out hs))
				{
					String parent = scope .();
					if (Path.GetDirectoryPath(probe, parent) case .Err || parent.IsEmpty || parent == probe)
						break;
					probe.Set(parent);
				}
				if (hs.Dev() == dev && MakeDirs(scope $"{home}/files") && MakeDirs(scope $"{home}/info"))
				{
					outTrash.Set(home);
					return true;
				}
			}
			String top = scope .();
			MountTop(full, dev, top);
			if (top == "/")
				top.Clear();
			let uid = getuid();
			// $top/.Trash/$uid: only when $top/.Trash is a real sticky folder (spec, "(1)").
			String admin = scope $"{top}/.Trash";
			if (Stat(admin, var ast, false) && (ast.Mode() & S_IFMT) == S_IFDIR && (ast.Mode() & S_ISVTX) != 0)
			{
				String t = scope $"{admin}/{uid}";
				if (MakeDirs(scope $"{t}/files") && MakeDirs(scope $"{t}/info"))
				{
					outTrash.Set(t);
					outTop.Set(top.IsEmpty ? "/" : top);
					return true;
				}
			}
			String own = scope $"{top}/.Trash-{uid}";
			if (MakeDirs(scope $"{own}/files") && MakeDirs(scope $"{own}/info"))
			{
				outTrash.Set(own);
				outTop.Set(top.IsEmpty ? "/" : top);
				return true;
			}
			return false;
		}

		/// Moves `path` into the trash. Nothing is deleted when that fails. `outTrashedAs` gets the
		/// path inside `files/` (tests, the status line).
		public static Result<void> Move(StringView pathIn, String outError, String outTrashedAs = null)
		{
			String full = scope .();
			Path.GetFullPath(pathIn, full);
			while (full.Length > 1 && full.EndsWith('/'))
				full.RemoveFromEnd(1);
			if (!Stat(full, var st, false))
			{
				outError.AppendF("{} no longer exists.", pathIn);
				return .Err;
			}
			// The device of what is moved (a link is moved itself, so lstat).
			String trash = scope .();
			String top = scope .();
			if (!PickTrash(full, st.Dev(), trash, top))
			{
				outError.AppendF("Could not move {} to the Trash (no trash folder could be made on its file system); nothing was deleted.", pathIn);
				return .Err;
			}

			String pathField = scope .();
			if (top.IsEmpty)
				EncodePath(full, pathField);
			else
			{
				StringView rel = full;
				if (top != "/" && full.StartsWith(top) && full.Length > top.Length && full[top.Length] == '/')
					rel = StringView(full, top.Length + 1);
				else if (top == "/")
					rel = StringView(full, 1);
				EncodePath(rel, pathField);
			}
			// DeletionDate is local time (the spec); DateTime.Now is UTC on Linux, so localtime_r.
			int t = time(null);
			Tm tm = default;
			localtime_r(&t, &tm);
			String info = scope .();
			info.AppendF("[Trash Info]\nPath={}\nDeletionDate={:D4}-{:D2}-{:D2}T{:D2}:{:D2}:{:D2}\n", pathField, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);

			String name = scope .();
			Path.GetFileName(full, name);
			String target = scope .();
			String infoPath = scope .();
			for (int n = 1; n < 10000; n++)
			{
				String cand = scope .(name);
				if (n > 1)
					cand.AppendF(".{}", n);
				infoPath.Clear();
				infoPath.AppendF("{}/info/{}.trashinfo", trash, cand);
				target.Clear();
				target.AppendF("{}/files/{}", trash, cand);
				if (Stat(target, var existing, false))
					continue;
				// O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600: the name is ours once this succeeds.
				let fd = open(infoPath.CStr(), 0x1 | 0x40 | 0x80 | 0x80000, 0x180);
				if (fd < 0)
				{
					if (*__errno_location() == EEXIST)
						continue;
					outError.AppendF("Could not write {}; nothing was deleted.", infoPath);
					return .Err;
				}
				let ok = write(fd, info.Ptr, info.Length) == info.Length;
				fsync(fd);
				close(fd);
				if (!ok)
				{
					unlink(infoPath.CStr());
					outError.AppendF("Could not write {}; nothing was deleted.", infoPath);
					return .Err;
				}
				if (rename(full.CStr(), target.CStr()) != 0)
				{
					unlink(infoPath.CStr());
					outError.AppendF("Could not move {} to the Trash; nothing was deleted.", pathIn);
					return .Err;
				}
				outTrashedAs?.Set(target);
				return .Ok;
			}
			outError.AppendF("Could not find a free name for {} in the Trash; nothing was deleted.", pathIn);
			return .Err;
		}
	}
}
#endif
