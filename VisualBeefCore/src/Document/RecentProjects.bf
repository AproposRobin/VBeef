using System;
using System.Collections;
using System.IO;

namespace VisualBeef.Document
{
	/// A project the editor opened before: shown on the start page, newest first.
	class RecentProject
	{
		/// The project folder, absolute.
		public String Path = new .() ~ delete _;
		/// The folder's name (what the start page lists).
		public String Name = new .() ~ delete _;
		/// When it was opened last, seconds since 1970-01-01 (UTC).
		public int64 Opened;
	}

	/// The start page's "Recent projects": the list with its rules (newest first, one entry per folder, at most
	/// `cMax`), the "opened ..." wording and the stored form of a path (relative to a base folder when the project
	/// lives under it, so a moved data folder keeps its entries). The editor persists it in the preferences
	/// (`Prefs`); nothing here touches the disk.
	class RecentProjects
	{
		public const int cMax = 12;

		public List<RecentProject> Items = new .() ~ DeleteContainerAndItems!(_);

		/// The last folder name of `path` ("D:\Work\My Game\" -> "My Game"; a drive root keeps the root).
		public static void NameOf(StringView path, String outName)
		{
			var p = path;
			if (p.Length == 3 && p[1] == ':')
			{
				outName.Append(p); // a drive root is its own name
				return;
			}
			while (p.Length > 1 && (p.EndsWith('/') || p.EndsWith('\\')))
				p.RemoveFromEnd(1);
			int cut = Math.Max(p.LastIndexOf('/'), p.LastIndexOf('\\'));
			outName.Append((cut >= 0 && cut + 1 < p.Length) ? p.Substring(cut + 1) : p);
		}

		static bool SameFolder(StringView a, StringView b)
		{
			var x = a;
			var y = b;
			while (x.Length > 1 && (x.EndsWith('/') || x.EndsWith('\\')))
				x.RemoveFromEnd(1);
			while (y.Length > 1 && (y.EndsWith('/') || y.EndsWith('\\')))
				y.RemoveFromEnd(1);
			return VisualBeef.Document.ProjectIndex.SamePath(x, y);
		}

		public RecentProject Find(StringView path)
		{
			for (let r in Items)
				if (SameFolder(r.Path, path))
					return r;
			return null;
		}

		/// The folder was just opened: it moves to the front (or is added there); the oldest entries beyond `cMax` go.
		public RecentProject Touch(StringView path, int64 now)
		{
			var folder = path;
			while (folder.Length > 1 && (folder.EndsWith('/') || folder.EndsWith('\\')) && !(folder.Length == 3 && folder[1] == ':'))
				folder.RemoveFromEnd(1);
			RecentProject r = Find(folder);
			if (r != null)
				Items.Remove(r);
			else
			{
				r = new RecentProject();
				r.Path.Set(folder);
				NameOf(folder, r.Name);
			}
			r.Opened = now;
			Items.Insert(0, r);
			while (Items.Count > cMax)
			{
				delete Items.Back;
				Items.PopBack();
			}
			return r;
		}

		/// Adds an entry read from the preferences, keeping the stored order (use `Touch` for a project just opened).
		public void AddStored(StringView path, int64 opened)
		{
			if (path.IsEmpty || Find(path) != null || Items.Count >= cMax)
				return;
			let r = new RecentProject();
			r.Path.Set(path);
			NameOf(path, r.Name);
			r.Opened = opened;
			Items.Add(r);
		}

		public bool Remove(StringView path)
		{
			let r = Find(path);
			if (r == null)
				return false;
			Items.Remove(r);
			delete r;
			return true;
		}

		// ------------------------------------------------------------------ stored paths

		static bool IsRooted(StringView p) => p.StartsWith('/') || p.StartsWith('\\') || (p.Length >= 2 && p[1] == ':');

		/// The form kept in the preferences: `path` relative to `baseDir` (forward slashes) when it lies under it,
		/// otherwise the absolute path as chosen.
		public static void ToStored(StringView path, StringView baseDir, String outStored)
		{
			var b = baseDir;
			while (b.Length > 1 && (b.EndsWith('/') || b.EndsWith('\\')))
				b.RemoveFromEnd(1);
			if (!b.IsEmpty && path.Length > b.Length + 1 && VisualBeef.Document.ProjectIndex.SamePath(path.Substring(0, b.Length), b) &&
				(path[b.Length] == '/' || path[b.Length] == '\\'))
			{
				var rel = path.Substring(b.Length + 1);
				int start = outStored.Length;
				outStored.Append(rel);
				for (int i = start; i < outStored.Length; i++)
					if (outStored[i] == '\\')
						outStored[i] = '/';
				return;
			}
			outStored.Append(path);
		}

		/// The absolute path of a stored one: a relative path is joined to `baseDir`.
		public static void FromStored(StringView stored, StringView baseDir, String outPath)
		{
			if (IsRooted(stored) || baseDir.IsEmpty)
			{
				outPath.Append(stored);
				return;
			}
			var b = baseDir;
			while (b.Length > 1 && (b.EndsWith('/') || b.EndsWith('\\')))
				b.RemoveFromEnd(1);
			char8 sep = b.Contains('\\') ? '\\' : '/';
			outPath.Append(b);
			outPath.Append(sep);
			int start = outPath.Length;
			outPath.Append(stored);
			for (int i = start; i < outPath.Length; i++)
				if (outPath[i] == '/' || outPath[i] == '\\')
					outPath[i] = sep;
		}

		// ------------------------------------------------------------------ wording

		/// Days since 1970-01-01 -> year, month, day (proleptic Gregorian).
		static void CivilFromDays(int64 zIn, out int64 year, out int month, out int day)
		{
			int64 z = zIn + 719468;
			int64 era = (z >= 0 ? z : z - 146096) / 146097;
			int64 doe = z - era * 146097;
			int64 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
			year = yoe + era * 400;
			int64 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
			int64 mp = (5 * doy + 2) / 153;
			day = (int)(doy - (153 * mp + 2) / 5 + 1);
			month = (int)(mp < 10 ? mp + 3 : mp - 9);
			if (month <= 2)
				year++;
		}

		/// "2026-10-12" for a time stamp.
		public static void DateText(int64 opened, String outText)
		{
			int64 days = (opened >= 0 ? opened : opened - 86399) / 86400;
			CivilFromDays(days, let y, let m, let d);
			outText.AppendF("{}-{:D2}-{:D2}", y, m, d);
		}

		/// "just now", "5 minutes ago", "3 hours ago", "yesterday", "4 days ago", else the date. A time stamp of 0 reads "never".
		public static void OpenedText(int64 opened, int64 now, String outText)
		{
			if (opened <= 0)
			{
				outText.Append("never");
				return;
			}
			int64 s = now - opened;
			if (s < 0)
				s = 0;
			if (s < 60)
				outText.Append("just now");
			else if (s < 3600)
				outText.AppendF("{} minute{} ago", s / 60, (s / 60 == 1) ? "" : "s");
			else if (s < 86400)
				outText.AppendF("{} hour{} ago", s / 3600, (s / 3600 == 1) ? "" : "s");
			else if (s < 2 * 86400)
				outText.Append("yesterday");
			else if (s < 14 * 86400)
				outText.AppendF("{} days ago", s / 86400);
			else
				DateText(opened, outText);
		}
	}
}
