using System;
using System.Collections;
using System.IO;

namespace VisualBeef.Docs
{
	/// A search result: a page, and the heading of it that matched (null = the page's title or summary matched).
	class DocHit
	{
		public DocPage Page;
		public DocBlock Heading;
		public int Score;
		/// Order of discovery (pages in library order, headings in page order): the tie-break of equal scores.
		public int Seq;
	}

	/// What a link in a page points at.
	enum DocLinkKind
	{
		/// A page of the library (and perhaps a heading of it).
		Page,
		/// A web address (opened in the browser).
		External,
		/// A picture of the documentation (`images/name.png`); `outSlug` receives the path as written.
		Image,
		/// Nothing in this library: a page that is not part of the documentation, or a heading that does not exist.
		Missing
	}

	/// The documentation shipped with the editor: the pages of a `docs` folder whose front matter says `audience: user`,
	/// in the order the front matter gives (the same set `scripts/package.ps1` puts in the package).
	class DocLibrary
	{
		public String Dir = new .() ~ delete _;
		public List<DocPage> Pages = new .() ~ DeleteContainerAndItems!(_);
		/// Pages that were skipped: no front matter or not meant for users.
		public int Skipped;

		/// Finds the documentation folder for a program in `exeDir`: `<exeDir>\docs` (the package), else the `docs` folder of
		/// the checkout the program was built in (`<repo>\build\<config>\<project>\` up to six levels above). `VB_DOCS`
		/// overrides both. Empty when there is none (a blank build carries no documentation).
		public static void FindDir(StringView exeDir, String outDir)
		{
			String env = scope .();
			if (Environment.GetEnvironmentVariable("VB_DOCS", env) case .Ok && !env.IsEmpty && Directory.Exists(env))
			{
				outDir.Append(env);
				return;
			}
			String dir = scope .(exeDir);
			for (int depth = 0; depth < 7 && !dir.IsEmpty; depth++)
			{
				String docs = scope .(dir);
				if (!docs.EndsWith('\\') && !docs.EndsWith('/'))
					docs.Append(Path.DirectorySeparatorChar);
				docs.Append("docs");
				String probe = scope .(docs);
				probe.Append(Path.DirectorySeparatorChar);
				probe.Append("Getting-Started.md");
				if (File.Exists(probe))
				{
					outDir.Append(docs);
					return;
				}
				String parent = scope .();
				if (Path.GetDirectoryPath(dir, parent) case .Err || parent.IsEmpty || parent == dir)
					return;
				dir.Set(parent);
			}
		}

		/// Loads every `*.md` of `dir`. With `userOnly` (the editor) only `audience: user` pages stay. Returns the page count.
		public int Load(StringView folder, bool userOnly = true)
		{
			ClearAndDeleteItems!(Pages);
			Skipped = 0;
			Dir.Set(folder);
			if (folder.IsEmpty || !Directory.Exists(folder))
				return 0;
			List<String> files = scope .();
			defer { ClearAndDeleteItems!(files); }
			for (let e in Directory.EnumerateFiles(folder, "*.md"))
			{
				String p = new .();
				e.GetFilePath(p);
				files.Add(p);
			}
			files.Sort(scope (a, b) => String.Compare(a, b, true));
			for (let f in files)
			{
				let page = new DocPage();
				if (!page.Load(f) || (userOnly && !page.IsUser))
				{
					delete page;
					Skipped++;
					continue;
				}
				Pages.Add(page);
			}
			Pages.Sort(scope (a, b) =>
			{
				if (a.Order != b.Order)
					return (a.Order < b.Order) ? -1 : 1;
				return String.Compare(a.Title, b.Title, true);
			});
			return Pages.Count;
		}

		public DocPage FindByFile(StringView fileName)
		{
			for (let p in Pages)
				if (StringView.Compare(p.FileName, fileName, true) == 0)
					return p;
			return null;
		}

		/// Where a link written in `from` leads. `outSlug` receives the heading anchor of a `Page` result ("" = the top).
		public DocLinkKind Resolve(DocPage from, StringView target, out DocPage outPage, String outSlug)
		{
			outPage = null;
			var t = target;
			t.Trim();
			if (t.StartsWith("https://") || t.StartsWith("http://"))
				return .External;
			String file = scope .();
			String slug = scope .();
			int hash = t.IndexOf('#');
			if (hash >= 0)
			{
				file.Append(t.Substring(0, hash));
				slug.Append(t.Substring(hash + 1));
			}
			else
				file.Append(t);
			DocPage page = from;
			if (file.StartsWith("images/") && slug.IsEmpty)
			{
				outSlug.Append(file);
				return .Image;
			}
			if (!file.IsEmpty)
			{
				// "Foo.md", "./Foo.md" and "docs/Foo.md" name a page by its file; anything else (../README.md) is not one.
				var name = StringView(file);
				while (name.StartsWith("./"))
					name.RemoveFromStart(2);
				if (name.StartsWith("docs/"))
					name.RemoveFromStart(5);
				if (name.Contains('/') || name.Contains('\\'))
					return .Missing;
				page = FindByFile(name);
				if (page == null)
					return .Missing;
			}
			if (page == null)
				return .Missing;
			if (!slug.IsEmpty && page.FindHeading(slug) == null)
			{
				outPage = page; // the page exists; the heading does not: land on the top
				return .Missing;
			}
			outPage = page;
			outSlug.Append(slug);
			return .Page;
		}

		static bool HasAll(StringView text, List<StringView> words)
		{
			for (let w in words)
				if (!text.Contains(w, true))
					return false;
			return true;
		}

		/// Searches titles, summaries and headings for every word of `query` (any order, case does not matter). Best
		/// first: a title that has them all, then headings, then summaries; at most `cMaxHits` results, 8 per page.
		public void Search(StringView query, List<DocHit> outHits)
		{
			const int cMaxHits = 60;
			List<StringView> words = scope .();
			for (var w in query.Split(' '))
			{
				w.Trim();
				if (!w.IsEmpty)
					words.Add(w);
			}
			if (words.IsEmpty)
				return;
			int start = outHits.Count;
			for (let page in Pages)
			{
				int perPage = 0;
				if (HasAll(page.Title, words))
				{
					let h = new DocHit();
					h.Page = page;
					h.Score = 100 + ((page.Title.StartsWith(words[0], .OrdinalIgnoreCase)) ? 20 : 0);
					outHits.Add(h);
					perPage++;
				}
				else if (HasAll(page.Summary, words))
				{
					let h = new DocHit();
					h.Page = page;
					h.Score = 20;
					outHits.Add(h);
					perPage++;
				}
				for (let b in page.Blocks)
				{
					if (b.Kind != .Heading || perPage >= 8)
						continue;
					String plain = scope .();
					b.PlainText(plain);
					if (!HasAll(plain, words))
						continue;
					let h = new DocHit();
					h.Page = page;
					h.Heading = b;
					h.Score = 60 - b.Level * 3 + ((plain.StartsWith(words[0], .OrdinalIgnoreCase)) ? 10 : 0);
					outHits.Add(h);
					perPage++;
				}
			}
			// Best first; equal scores keep the order they were found in.
			List<DocHit> sorted = scope .();
			for (int k = start; k < outHits.Count; k++)
			{
				outHits[k].Seq = k;
				sorted.Add(outHits[k]);
			}
			sorted.Sort(scope (a, b) => (a.Score != b.Score) ? ((a.Score > b.Score) ? -1 : 1) : ((a.Seq < b.Seq) ? -1 : 1));
			if (sorted.IsEmpty)
				return;
			outHits.RemoveRange(start, outHits.Count - start);
			for (let h in sorted)
			{
				if (outHits.Count - start >= cMaxHits)
					delete h;
				else
					outHits.Add(h);
			}
		}
	}
}
