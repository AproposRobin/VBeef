using System;
using System.Collections;
using System.IO;
using VisualBeef.Docs;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests docs [folder]`: the documentation viewer's model (VisualBeef.Docs): front matter, the Markdown
	/// subset, headings and anchors, link resolution, search, and the real `audience: user` pages of the repository's
	/// docs folder (every page parses, the order is the front matter's, no developer page is in the set, and the
	/// internal links of the shipped pages resolve). `folder` defaults to the docs folder of this checkout.
	static class DocsTests
	{
		static int sChecks;
		static int sFailures;

		static void Check(bool cond, StringView what)
		{
			sChecks++;
			if (cond)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		public static int Run(String[] args)
		{
			sChecks = 0;
			sFailures = 0;
			FrontMatter();
			Blocks();
			Inline();
			Tables();
			Links();
			Search();
			String dir = scope .();
			if (args.Count > 1)
				dir.Set(args[1]);
			else
			{
				String exePath = scope .();
				String exeDir = scope .();
				Environment.GetExecutableFilePath(exePath);
				Path.GetDirectoryPath(exePath, exeDir).IgnoreError();
				DocLibrary.FindDir(exeDir, dir);
			}
			RealPages(dir);
			Console.WriteLine("docs checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}

		static DocPage Page(StringView text)
		{
			let p = new DocPage();
			p.FileName.Set("Test.md");
			p.Parse(text);
			return p;
		}

		static void FrontMatter()
		{
			Console.WriteLine("front matter");
			let p = scope:: DocPage();
			bool ok = p.Parse("---\r\naudience: user\r\ntitle: Getting started\r\nsummary: Install and go.\r\norder: 3\r\n---\r\n\r\n# Hello\r\n\r\nText.\r\n");
			Check(ok && p.IsUser && p.Title == "Getting started" && p.Summary == "Install and go." && p.Order == 3, "audience, title, summary and order are read (CRLF file)");
			Check(p.Blocks.Count == 2 && p.Blocks[0].Kind == .Heading && p.Blocks[1].Kind == .Paragraph, "the body starts after the closing ---");
			let dev = scope:: DocPage();
			Check(dev.Parse("---\naudience: developer\ntitle: Internals\n---\nBody\n") && !dev.IsUser, "a developer page parses but is not a user page");
			let none = scope:: DocPage();
			Check(!none.Parse("# No front matter\n"), "a page without front matter is refused");
			let open = scope:: DocPage();
			Check(!open.Parse("---\ntitle: x\n# never closed\n"), "front matter that is not closed is refused");
			let noTitle = scope:: DocPage();
			noTitle.FileName.Set("Some-Page.md");
			noTitle.Parse("---\naudience: user\n---\ntext\n");
			Check(noTitle.Title == "Some-Page" && noTitle.Order == 1000, "no title: the file name; no order: last");
		}

		static void Blocks()
		{
			Console.WriteLine("blocks");
			let p = Page("---\naudience: user\ntitle: T\n---\n# Top\n\nFirst line\nsecond line.\n\n## A *big* heading!\n\n* one\n  continued\n  * nested\n* two\n\n1. first\n2. second\n\n> quoted\n> text\n\n```\ncode line 1\n  code line 2\n```\n\n---\n\n![A shot](images/shot.png)\n\nafter\n");
			defer delete p;
			String seq = scope .();
			for (let b in p.Blocks)
				seq.AppendF("{}{}", b.Kind, (@b.Index + 1 < p.Blocks.Count) ? "," : "");
			Check(seq == "Heading,Paragraph,Heading,ListItem,ListItem,ListItem,ListItem,ListItem,Quote,Code,Rule,Image,Paragraph", scope $"block sequence: {seq}");
			String para = scope .();
			p.Blocks[1].PlainText(para);
			Check(para == "First line second line.", scope $"lines of a paragraph join with a space ('{para}')");
			Check(p.Blocks[2].Level == 2 && p.Blocks[2].Slug == "a-big-heading", scope $"heading level and anchor ({p.Blocks[2].Level}, {p.Blocks[2].Slug})");
			String item = scope .();
			p.Blocks[3].PlainText(item);
			Check(item == "one continued" && p.Blocks[3].Level == 0 && p.Blocks[3].Number == 0, "an indented continuation line joins its list item");
			Check(p.Blocks[4].Level == 1, "an item indented by two spaces is nested");
			Check(p.Blocks[6].Number == 1 && p.Blocks[7].Number == 2, "numbered items carry their numbers");
			Check(p.Blocks[9].Text == "code line 1\n  code line 2", "a fenced block keeps its lines and indentation");
			Check(p.Blocks[11].Target == "images/shot.png" && p.Blocks[11].Text == "A shot", "an image line gives its path and description");
			let dup = Page("---\naudience: user\ntitle: T\n---\n# Same\n\n## Same\n\n## Same\n");
			defer delete dup;
			Check(dup.Blocks[0].Slug == "same" && dup.Blocks[1].Slug == "same-1" && dup.Blocks[2].Slug == "same-2", "equal headings get -1, -2 anchors");
			String slug = scope .();
			Markdown.Slug("What's new? (v2) in C_3", slug);
			Check(slug == "whats-new-v2-in-c_3", scope $"anchor of punctuation ({slug})");
			let rule = Page("---\naudience: user\ntitle: T\n---\n- a\n- b\n\n---\ntext\n");
			defer delete rule;
			Check(rule.Blocks.Count == 4 && rule.Blocks[2].Kind == .Rule, "'- a' is a list, '---' alone is a rule");
		}

		static void Inline()
		{
			Console.WriteLine("inline");
			let p = Page("---\naudience: user\ntitle: T\n---\nUse **bold**, *italic*, `code with *stars*` and [a link](Other.md#part) or <https://example.org/x>. 1 &lt; 2 &amp; \\*not italic\\*.\n");
			defer delete p;
			let spans = p.Blocks[0].Spans;
			String all = scope .();
			p.Blocks[0].PlainText(all);
			Check(all == "Use bold, italic, code with *stars* and a link or https://example.org/x. 1 < 2 & *not italic*.", scope $"plain text ({all})");
			DocSpan Find(StringView text)
			{
				for (let s in spans)
					if (s.Text == text)
						return s;
				return null;
			}
			Check(Find("bold") != null && Find("bold").Style == DocSpan.cBold, "**bold**");
			Check(Find("italic") != null && Find("italic").Style == DocSpan.cItalic, "*italic*");
			Check(Find("code with *stars*") != null && Find("code with *stars*").Style == DocSpan.cCode, "`code` keeps its stars");
			Check(Find("a link") != null && Find("a link").Link == "Other.md#part", "[text](target)");
			Check(Find("https://example.org/x") != null && Find("https://example.org/x").Link == "https://example.org/x", "<https://...> is a link to itself");
			let nest = Page("---\naudience: user\ntitle: T\n---\n[**bold link** and `code`](A.md)\n");
			defer delete nest;
			bool allLinked = true;
			for (let s in nest.Blocks[0].Spans)
				if (s.Link != "A.md")
					allLinked = false;
			Check(nest.Blocks[0].Spans.Count == 3 && allLinked && nest.Blocks[0].Spans[0].Style == DocSpan.cBold && nest.Blocks[0].Spans[2].Style == DocSpan.cCode, "styles inside a link keep the link");
			let lead = Page("---\naudience: user\ntitle: T\n---\n`ClassModel.Analyze(unit, type)` reads a declaration:\n");
			defer delete lead;
			Check(lead.Blocks[0].Spans.Count == 2 && lead.Blocks[0].Spans[0].Style == DocSpan.cCode && lead.Blocks[0].Spans[1].Text == " reads a declaration:", scope $"a paragraph that starts with code keeps the space after it ('{lead.Blocks[0].Spans[1].Text}')");
			let star = Page("---\naudience: user\ntitle: T\n---\nA * alone, 2 * 3 * 4 and snake_case_name stay text.\n");
			defer delete star;
			String t = scope .();
			star.Blocks[0].PlainText(t);
			Check(t == "A * alone, 2 * 3 * 4 and snake_case_name stay text." && star.Blocks[0].Spans.Count == 1, "lone stars and underscores are text");
		}

		static void Tables()
		{
			Console.WriteLine("tables");
			let p = Page("---\naudience: user\ntitle: T\n---\n| Key | What |\n|---|:--|\n| `a \\| b` | uses a bar |\n| **x** | `p || q` |\n\nafter\n");
			defer delete p;
			Check(p.Blocks.Count == 2 && p.Blocks[0].Kind == .Table && p.Blocks[0].Rows.Count == 3, "a table: header and two rows");
			let t = p.Blocks[0];
			String c = scope .();
			for (let s in t.Rows[1].Cells[0].Spans)
				c.Append(s.Text);
			Check(t.Rows[0].Cells.Count == 2 && c == "a | b", scope $"cells split on bars outside code; an escaped bar is a bar ('{c}')");
			String d = scope .();
			for (let s in t.Rows[2].Cells[1].Spans)
				d.Append(s.Text);
			Check(d == "p || q", scope $"a bar inside code does not split ('{d}')");
		}

		static void Links()
		{
			Console.WriteLine("links");
			let lib = scope DocLibrary();
			let a = new DocPage();
			a.FileName.Set("Getting-Started.md");
			a.Parse("---\naudience: user\ntitle: Getting started\norder: 1\n---\n# Getting started\n\n## Install\n");
			let b = new DocPage();
			b.FileName.Set("Editor-UI.md");
			b.Parse("---\naudience: user\ntitle: Editor interface\norder: 2\n---\n# Editor\n\n## Start page\n\n## Menus\n");
			lib.Pages.Add(a);
			lib.Pages.Add(b);
			String slug = scope .();
			DocPage page = null;
			slug.Clear();
			var kind = lib.Resolve(a, "Editor-UI.md", out page, slug);
			Check(kind == .Page && page == b && slug.IsEmpty, "File.md opens that page at its top");
			slug.Clear();
			kind = lib.Resolve(a, "editor-ui.md#start-page", out page, slug);
			Check(kind == .Page && page == b && slug == "start-page", "File.md#heading opens it at the heading (file name case ignored)");
			slug.Clear();
			kind = lib.Resolve(b, "#menus", out page, slug);
			Check(kind == .Page && page == b && slug == "menus", "#heading stays on the page");
			slug.Clear();
			kind = lib.Resolve(a, "./Editor-UI.md", out page, slug);
			Check(kind == .Page && page == b, "./File.md");
			slug.Clear();
			kind = lib.Resolve(a, "docs/Editor-UI.md", out page, slug);
			Check(kind == .Page && page == b, "docs/File.md");
			slug.Clear();
			kind = lib.Resolve(a, "Architecture.md", out page, slug);
			Check(kind == .Missing && page == null, "a page that is not in the library is missing");
			slug.Clear();
			kind = lib.Resolve(a, "images/shot.png", out page, slug);
			Check(kind == .Image && slug == "images/shot.png", "images/name.png is a picture");
			slug.Clear();
			kind = lib.Resolve(a, "../README.md", out page, slug);
			Check(kind == .Missing, "a path out of the folder is missing");
			slug.Clear();
			kind = lib.Resolve(a, "Editor-UI.md#nothing-here", out page, slug);
			Check(kind == .Missing && page == b && slug.IsEmpty, "a heading that does not exist is missing, but the page is known");
			slug.Clear();
			kind = lib.Resolve(a, "https://example.org/", out page, slug);
			Check(kind == .External && page == null, "https:// is external");
		}

		static void Search()
		{
			Console.WriteLine("search");
			let lib = scope DocLibrary();
			let a = new DocPage();
			a.FileName.Set("Getting-Started.md");
			a.Parse("---\naudience: user\ntitle: Getting started\nsummary: Install the editor, open a project.\norder: 1\n---\n# Getting started\n\n## Install\n\n## Open a project\n\n### Recent projects\n");
			let b = new DocPage();
			b.FileName.Set("Debugging.md");
			b.Parse("---\naudience: user\ntitle: Debugging\nsummary: Stop on a node.\norder: 2\n---\n# Debugging\n\n## Breakpoints\n\n## Open a project to debug\n");
			lib.Pages.Add(a);
			lib.Pages.Add(b);
			List<DocHit> hits = scope .();
			defer { ClearAndDeleteItems!(hits); }
			lib.Search("debug", hits);
			Check(hits.Count >= 2 && hits[0].Page == b && hits[0].Heading == null, "a title match comes first");
			ClearAndDeleteItems!(hits);
			lib.Search("PROJECT open", hits);
			bool openHeading = false;
			bool recent = false;
			for (let h in hits)
			{
				if (h.Heading != null && h.Heading.Slug == "open-a-project")
					openHeading = true;
				if (h.Heading != null && h.Heading.Slug == "recent-projects")
					recent = true;
			}
			Check(openHeading && !recent, "every word must match, any order, any case ('PROJECT open' finds 'Open a project', not 'Recent projects')");
			ClearAndDeleteItems!(hits);
			lib.Search("recent", hits);
			Check(hits.Count == 1 && hits[0].Heading != null && hits[0].Heading.Slug == "recent-projects", "a heading match names the heading");
			ClearAndDeleteItems!(hits);
			lib.Search("install editor", hits);
			Check(hits.Count >= 1 && hits[0].Page == a, "the summary is searched too");
			ClearAndDeleteItems!(hits);
			lib.Search("   ", hits);
			Check(hits.IsEmpty, "an empty query finds nothing");
			lib.Search("zzzzqq", hits);
			Check(hits.IsEmpty, "no match, no hits");
		}

		static void RealPages(StringView dir)
		{
			Console.WriteLine("the shipped pages");
			if (dir.IsEmpty || !Directory.Exists(dir))
			{
				Check(false, "the repository docs folder was found");
				return;
			}
			let lib = scope DocLibrary();
			let n = lib.Load(dir);
			Check(n >= 8, scope $"{n} user pages load from {dir}");
			Check(lib.Skipped > 0, scope $"developer pages are left out ({lib.Skipped} skipped)");
			bool sorted = true;
			for (int i = 1; i < lib.Pages.Count; i++)
				if (lib.Pages[i - 1].Order > lib.Pages[i].Order)
					sorted = false;
			Check(sorted && lib.Pages.Count > 0 && lib.Pages[0].FileName == "Getting-Started.md", "pages are in front matter order, Getting started first");
			bool allUser = true;
			for (let p in lib.Pages)
				if (!p.IsUser || p.Title.IsEmpty || p.Summary.IsEmpty || p.Blocks.IsEmpty)
					allUser = false;
			Check(allUser, "every page is audience: user with a title, a summary and a body");
			// Cross check with the files: the pages scripts/package.ps1 ships are the ones with audience: user.
			int userFiles = 0;
			for (let e in Directory.EnumerateFiles(dir, "*.md"))
			{
				String text = scope .();
				String path = scope .();
				e.GetFilePath(path);
				if (File.ReadAllText(path, text, true) case .Ok)
				{
					var head = StringView(text, 0, Math.Min(text.Length, 400));
					if (head.Contains("\naudience: user"))
						userFiles++;
				}
			}
			Check(userFiles == lib.Pages.Count, scope $"the library holds the {userFiles} pages marked audience: user");
			int unresolved = 0;
			int notShipped = 0;
			int links = 0;
			int imagesMissing = 0;
			int images = 0;
			int headings = 0;
			String slug = scope .();
			for (let p in lib.Pages)
			{
				for (let b in p.Blocks)
				{
					if (b.Kind == .Heading)
						headings++;
					if (b.Kind == .Image)
					{
						images++;
						String img = scope .();
						img.AppendF("{}{}{}", dir, Path.DirectorySeparatorChar, b.Target);
						img.Replace('/', Path.DirectorySeparatorChar);
						if (!File.Exists(img))
						{
							imagesMissing++;
							Console.WriteLine("    missing image {} in {}", b.Target, p.FileName);
						}
					}
					void CheckSpans(List<DocSpan> spans)
					{
						for (let s in spans)
						{
							if (s.Link.IsEmpty)
								continue;
							links++;
							slug.Clear();
							DocPage target = null;
							let kind = lib.Resolve(p, s.Link, out target, slug);
							if (kind == .Image)
							{
								String img = scope .();
								img.AppendF("{}{}{}", dir, Path.DirectorySeparatorChar, slug);
								img.Replace('/', Path.DirectorySeparatorChar);
								if (!File.Exists(img))
								{
									unresolved++;
									Console.WriteLine("    missing image {} linked from {}", s.Link, p.FileName);
								}
							}
							else if (kind == .Missing)
							{
								// A link to a developer page is dead in a package (the page is not shipped): counted, not a failure.
								// A link to nothing at all is a failure.
								var file = StringView(s.Link);
								int hash = file.IndexOf('#');
								if (hash >= 0)
									file = file.Substring(0, hash);
								String onDisk = scope .();
								onDisk.AppendF("{}{}{}", dir, Path.DirectorySeparatorChar, file);
								if (!file.IsEmpty && File.Exists(onDisk))
								{
									notShipped++;
									Console.WriteLine("    note: {} links to {}, a developer page that is not shipped", p.FileName, s.Link);
								}
								else
								{
									unresolved++;
									Console.WriteLine("    unresolved link {} in {}", s.Link, p.FileName);
								}
							}
						}
					}
					CheckSpans(b.Spans);
					for (let r in b.Rows)
						for (let c in r.Cells)
							CheckSpans(c.Spans);
				}
			}
			Check(headings > 50 && links > 20, scope $"{headings} headings and {links} links in the shipped pages");
			Check(imagesMissing == 0, scope $"all {images} images of the shipped pages exist in docs/images");
			Check(unresolved == 0, scope $"every internal link of a shipped page leads somewhere ({unresolved} do not; {notShipped} lead to developer pages that are not shipped)");
			List<DocHit> hits = scope .();
			defer { ClearAndDeleteItems!(hits); }
			lib.Search("getting started", hits);
			Check(!hits.IsEmpty && hits[0].Page.FileName == "Getting-Started.md", "searching 'getting started' finds that page first");
		}
	}
}
