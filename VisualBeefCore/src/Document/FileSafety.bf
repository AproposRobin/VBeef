using System;
using System.IO;
using System.Collections;

namespace VisualBeef.Document
{
	/// What a save attempt did.
	enum SaveOutcome
	{
		Saved,
		/// The document has no file path.
		NoPath,
		/// Read-only project: nothing was written.
		ReadOnly,
		/// The file changed on disk since it was loaded (or last saved); nothing was written.
		Conflict,
		/// The write itself failed; the original file is untouched.
		Failed,
		/// A graph of the document has errors (GraphValidator / CodeGen): its edits are not in
		/// the text, so saving would quietly drop them; nothing was written.
		GraphErrors
	}

	/// All disk writes of the document layer go through here: the read-only (viewer) switch,
	/// atomic replace with a backup, and the content fingerprint used for conflict checks.
	static class FileSafety
	{
		/// Viewer mode: every write (sources, sidecars, asset creation, rename, delete) is refused.
		public static bool ReadOnlyProject;
		/// Keep one `File.bf.bak` of the previous content when saving over an existing file.
		public static bool KeepBackup = true;

		public static StringView ReadOnlyMessage => "Read-only project: nothing was written. (File > Open Project reopens it editable.)";

		/// FNV-1a over the text bytes.
		public static uint64 Hash(StringView text)
		{
			uint64 h = 14695981039346656037UL;
			for (let c in text.RawChars)
			{
				h ^= (uint8)c;
				h *= 1099511628211UL;
			}
			return h;
		}

		/// Writes `content` to `path` so a crash or full disk never leaves a half-written file:
		/// the text goes to `path.tmp`, is flushed to the disk, and then replaces `path` in one
		/// step. With `backup` the previous content stays in `path.bak`.
		public static Result<void> AtomicWrite(StringView path, StringView content, bool backup, String outError = null)
		{
			if (ReadOnlyProject)
			{
				outError?.Append(ReadOnlyMessage);
				return .Err;
			}
#if BF_PLATFORM_WINDOWS
			String tmp = scope .(path);
			tmp.Append(".tmp");
			if (WriteFlushed(tmp, content) case .Err)
			{
				outError?.AppendF("Could not write {}", tmp);
				File.Delete(tmp).IgnoreError();
				return .Err;
			}
			bool exists = File.Exists(path);
			bool ok;
			if (exists && backup)
			{
				String bak = scope .(path);
				bak.Append(".bak");
				ok = ReplaceWith(path, tmp, bak);
				if (!ok)
				{
					// Could not use ReplaceFile (e.g. a file system without it): copy then move.
					File.Copy(path, bak, true).IgnoreError();
					ok = MoveOver(tmp, path);
				}
			}
			else
				ok = MoveOver(tmp, path);
			if (!ok)
			{
				outError?.AppendF("Could not replace {}", path);
				File.Delete(tmp).IgnoreError();
				return .Err;
			}
			return .Ok;
#else
			// POSIX: the same steps with rename(2), which replaces `path` in one step on one file system.
			// rename(2) would replace a read-only file (it needs only the folder): refuse like Windows does.
			if (File.Exists(path) && access(path.ToScopeCStr!(), 2 /* W_OK */) != 0)
			{
				outError?.AppendF("{} is read-only", path);
				return .Err;
			}
			String tmp = scope .(path);
			tmp.Append(".tmp");
			bool written = false;
			{
				FileStream fs = scope .();
				if (fs.Create(tmp, .Write) case .Ok)
				{
					written = fs.TryWrite(.((uint8*)content.Ptr, content.Length)) case .Ok(let n) && n == content.Length;
					if (fs.Flush() case .Err) // fsync
						written = false;
					fs.Close().IgnoreError(); // a failed close after a good flush loses nothing
				}
			}
			if (!written)
			{
				outError?.AppendF("Could not write {}", tmp);
				File.Delete(tmp).IgnoreError(); // a directory or nothing there: nothing to clean
				return .Err;
			}
			if (backup && File.Exists(path))
			{
				String bak = scope .(path);
				bak.Append(".bak");
				File.Copy(path, bak, true).IgnoreError(); // no backup is not a reason to refuse the save
			}
			if (File.Move(tmp, path) case .Err)
			{
				outError?.AppendF("Could not replace {}", path);
				File.Delete(tmp).IgnoreError(); // the original is untouched
				return .Err;
			}
			return .Ok;
#endif
		}

		/// What the platform calls the place deleted files go ("Recycle Bin" / "Trash").
#if BF_PLATFORM_WINDOWS
		public const String TrashName = "Recycle Bin";
#else
		public const String TrashName = "Trash";
#endif

		/// Moves a file or folder to the Recycle Bin (the freedesktop Trash on Linux). When that can't be done (no bin on the
		/// volume, the user declined Windows' permanent-delete warning, any error) nothing is
		/// deleted and `outError` says so. There is deliberately no permanent-delete fallback.
		public static Result<void> MoveToRecycleBin(StringView path, String outError)
		{
			if (ReadOnlyProject)
			{
				outError.Append(ReadOnlyMessage);
				return .Err;
			}
#if BF_PLATFORM_WINDOWS
			if (!File.Exists(path) && !Directory.Exists(path))
			{
				outError.AppendF("{} no longer exists.", path);
				return .Err;
			}
			List<char16> w = scope .();
			ToWide(path, w);
			w.Add(0); // pFrom is double-null terminated
			SHFILEOPSTRUCTW op = default;
			op.wFunc = 3; // FO_DELETE
			op.pFrom = w.Ptr;
			// ALLOWUNDO | WANTNUKEWARNING (Windows asks before anything would be destroyed
			// instead of recycled) | NOERRORUI | SILENT
			op.fFlags = 0x0040 | 0x4000 | 0x0400 | 0x0004;
			int32 r = SHFileOperationW(&op);
			if (r != 0 || op.fAnyOperationsAborted != 0 || File.Exists(path) || Directory.Exists(path))
			{
				outError.AppendF("Could not move {} to the Recycle Bin; nothing was deleted.", path);
				return .Err;
			}
			return .Ok;
#else
			// Linux: the freedesktop.org Trash, with the same rule (FreedesktopTrash.bf).
			return FreedesktopTrash.Move(path, outError);
#endif
		}

#if !BF_PLATFORM_WINDOWS
		[CLink] static extern int32 access(char8* path, int32 mode);
#endif

#if BF_PLATFORM_WINDOWS
		[CRepr]
		struct SHFILEOPSTRUCTW
		{
			public void* hwnd;
			public uint32 wFunc;
			public char16* pFrom;
			public char16* pTo;
			public uint16 fFlags;
			public int32 fAnyOperationsAborted;
			public void* hNameMappings;
			public char16* lpszProgressTitle;
		}

		[Import("shell32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 SHFileOperationW(SHFILEOPSTRUCTW* op);
#endif

		/// Reads the file and fingerprints it. False when it can't be read.
		public static bool ReadStamp(StringView path, out uint64 hash, out int len)
		{
			hash = 0;
			len = 0;
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
				return false;
			hash = Hash(text);
			len = text.Length;
			return true;
		}

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* CreateFileW(char16* name, uint32 access, uint32 share, void* sec, uint32 disposition, uint32 flags, void* templ);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 WriteFile(void* h, void* buf, uint32 n, uint32* written, void* overlapped);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 FlushFileBuffers(void* h);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CloseHandle(void* h);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 MoveFileExW(char16* from, char16* to, uint32 flags);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 ReplaceFileW(char16* replaced, char16* replacement, char16* backup, uint32 flags, void* a, void* b);

		static char16* ToWide(StringView s, List<char16> storage)
		{
			String full = scope .(s);
			full.Replace('/', '\\');
			int len = System.Text.UTF16.GetEncodedLen(full);
			storage.Resize(len + 2);
			if (System.Text.UTF16.Encode(full, storage.Ptr, len + 2) case .Err)
			{
				storage[0] = 0;
				return storage.Ptr;
			}
			storage[len] = 0;
			return storage.Ptr;
		}

		static Result<void> WriteFlushed(StringView path, StringView content)
		{
			List<char16> w = scope .();
			// GENERIC_WRITE, no sharing, CREATE_ALWAYS, NORMAL
			void* h = CreateFileW(ToWide(path, w), 0x40000000, 0, null, 2, 0x80, null);
			if ((int)h == -1 || h == null)
				return .Err;
			bool ok = true;
			int pos = 0;
			while (pos < content.Length)
			{
				uint32 chunk = (uint32)Math.Min(content.Length - pos, 1 << 24);
				uint32 written = 0;
				if (WriteFile(h, content.Ptr + pos, chunk, &written, null) == 0 || written == 0)
				{
					ok = false;
					break;
				}
				pos += written;
			}
			if (ok && FlushFileBuffers(h) == 0)
				ok = false;
			CloseHandle(h);
			return ok ? .Ok : .Err;
		}

		static bool MoveOver(StringView from, StringView to)
		{
			List<char16> a = scope .();
			List<char16> b = scope .();
			// MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
			return MoveFileExW(ToWide(from, a), ToWide(to, b), 0x1 | 0x8) != 0;
		}

		static bool ReplaceWith(StringView target, StringView replacement, StringView backup)
		{
			List<char16> a = scope .();
			List<char16> b = scope .();
			List<char16> c = scope .();
			return ReplaceFileW(ToWide(target, a), ToWide(replacement, b), ToWide(backup, c), 0, null, null) != 0;
		}
#endif
	}
}
