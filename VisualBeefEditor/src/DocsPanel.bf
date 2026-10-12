using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Docs;

namespace VisualBeef.Editor
{
	enum DocItemKind
	{
		Text,
		Rect,
		Line,
		Image
	}

	/// One drawn piece of a laid-out page, in page coordinates (pixels from the top-left of the text column).
	class DocItem
	{
		public DocItemKind Kind;
		public float X, Y, W, H;
		public uint32 Color;
		public String Text = new .() ~ delete _;
		public float Size;
		public bool Mono;
		public bool Bold;
		/// A link: where it leads (`LinkKind`; `Link` is the target as written).
		public String Link = new .() ~ delete _;
		public DocLinkKind LinkKind;
		public bool HasLink;
		public float Rounding;
		public DocImage Image;
		/// The image's path under the docs folder, as written in the page.
		public String ImagePath = new .() ~ delete _;
	}

	/// A page laid out for one column width and font size.
	class DocLayout
	{
		public DocPage Page;
		public float Width;
		public float BaseSize;
		public bool Darker;
		public float Height;
		public List<DocItem> Items = new .() ~ DeleteContainerAndItems!(_);
		/// Heading anchors and the y they start at.
		public Dictionary<String, float> Anchors = new .() ~ { for (let kv in _) delete kv.key; delete _; };
	}

	/// Lays a DocPage out: wraps the text of each block to the width, places the lists, quotes, code blocks, tables and
	/// pictures, and records where each heading starts. The result is a flat list of rectangles, lines, words and pictures
	/// for DocsPanel to draw, so scrolling and clicking cost nothing per frame beyond the visible items.
	class DocLayouter
	{
		DocLibrary mLib;
		DocPage mPage;
		DocLayout mOut;
		ImFont* mUi;
		ImFont* mMono;
		float mBase;
		float mScale;
		float mWidth;

		uint32 mText;
		uint32 mDim;
		uint32 mStrong;
		uint32 mLinkColor;
		uint32 mCodeText;
		uint32 mCodeBack;
		uint32 mItalic;
		uint32 mRule;
		uint32 mQuoteBar;
		uint32 mHeadBack;

		public static DocLayout Build(DocLibrary lib, DocPage page, float width, float baseSize, float scale, ImFont* ui, ImFont* mono)
		{
			let b = scope DocLayouter();
			b.mLib = lib;
			b.mPage = page;
			b.mUi = ui;
			b.mMono = mono;
			b.mBase = baseSize;
			b.mScale = scale;
			b.mWidth = Math.Max(width, 160 * scale);
			let o = new DocLayout();
			o.Page = page;
			o.Width = width;
			o.BaseSize = baseSize;
			o.Darker = Look.Darker;
			b.mOut = o;
			b.Run();
			return o;
		}

		[CLink] static extern ImVec2 ImFont_CalcTextSizeA(ImFont* self, float size, float max_width, float wrap_width, char8* text_begin, char8* text_end, char8** out_remaining);

		/// The width of `s` in pixels at exactly `size`: the same measure the drawing uses (ImDrawList_AddText with a size), so
		/// words, spaces and code boxes line up whatever the display scale.
		float TextW(StringView s, bool mono, float size)
		{
			if (s.IsEmpty)
				return 0;
			return ImFont_CalcTextSizeA(mono ? mMono : mUi, size, float.MaxValue, 0, s.Ptr, s.Ptr + s.Length, null).x;
		}

		DocItem AddText(StringView text, float x, float y, float w, float h, float size, uint32 color, bool mono, bool bold)
		{
			let it = new DocItem();
			it.Kind = .Text;
			it.Text.Set(text);
			it.X = x;
			it.Y = y;
			it.W = w;
			it.H = h;
			it.Size = size;
			it.Color = color;
			it.Mono = mono;
			it.Bold = bold;
			mOut.Items.Add(it);
			return it;
		}

		DocItem AddRect(float x, float y, float w, float h, uint32 color, float rounding)
		{
			let it = new DocItem();
			it.Kind = .Rect;
			it.X = x;
			it.Y = y;
			it.W = w;
			it.H = h;
			it.Color = color;
			it.Rounding = rounding;
			mOut.Items.Add(it);
			return it;
		}

		DocItem AddLine(float x, float y, float w, uint32 color)
		{
			let it = new DocItem();
			it.Kind = .Line;
			it.X = x;
			it.Y = y;
			it.W = w;
			it.H = 1;
			it.Color = color;
			mOut.Items.Add(it);
			return it;
		}

		/// Flows `spans` into the column [x0, x0 + maxW) from `y`; returns the y under the last line.
		float Flow(List<DocSpan> spans, float x0, float maxW, float yIn, float size, uint32 color)
		{
			float y = yIn;
			float lineH = size * 1.45f;
			float curX = x0;
			float right = x0 + maxW;
			bool lineUsed = false;
			for (let span in spans)
			{
				bool mono = (span.Style & DocSpan.cCode) != 0;
				bool bold = (span.Style & DocSpan.cBold) != 0;
				bool italic = (span.Style & DocSpan.cItalic) != 0;
				float sz = mono ? size * 0.92f : size;
				uint32 col = color;
				if (mono)
					col = mCodeText;
				else if (bold)
					col = mStrong;
				else if (italic)
					col = mItalic;
				bool hasLink = !span.Link.IsEmpty;
				DocLinkKind lk = .Missing;
				if (hasLink)
				{
					String slug = scope .();
					DocPage target = null;
					lk = mLib.Resolve(mPage, span.Link, out target, slug);
					col = (lk == .Missing) ? mDim : mLinkColor;
				}
				StringView text = span.Text;
				if (mono)
				{
					// A code span stays whole on a line when it fits one.
					float w = TextW(text, true, sz) + 8 * mScale;
					if (w <= maxW)
					{
						if (curX + w > right && curX > x0)
						{
							curX = x0;
							y += lineH;
						}
						AddRect(curX, y + lineH * 0.06f, w, lineH * 0.88f, mCodeBack, 3 * mScale);
						let it = AddText(text, curX + 4 * mScale, y + (lineH - sz) * 0.5f, w - 8 * mScale, lineH, sz, col, true, bold);
						SetLink(it, span, hasLink, lk);
						curX += w + 1 * mScale;
						lineUsed = true;
						continue;
					}
				}
				int i = 0;
				while (i < text.Length)
				{
					int j = i;
					bool space = text[i] == ' ';
					while (j < text.Length && (text[j] == ' ') == space)
						j++;
					var token = text.Substring(i, j - i);
					i = j;
					if (space)
					{
						if (curX <= x0)
							continue;
						float sw = TextW(" ", mono, sz) * token.Length;
						if (curX + sw > right)
						{
							curX = x0;
							y += lineH;
						}
						else
							curX += sw;
						continue;
					}
					float w = TextW(token, mono, sz);
					if (curX + w > right && curX > x0)
					{
						curX = x0;
						y += lineH;
					}
					if (w > maxW)
					{
						// A word wider than the column: break it between characters.
						int start = 0;
						while (start < token.Length)
						{
							int end = start;
							float pw = 0;
							while (end < token.Length)
							{
								int next = end + 1;
								while (next < token.Length && ((uint8)token[next] & 0xC0) == 0x80)
									next++;
								float cw = TextW(token.Substring(end, next - end), mono, sz);
								if (pw + cw > right - curX && end > start)
									break;
								pw += cw;
								end = next;
							}
							var piece = token.Substring(start, end - start);
							if (mono)
								AddRect(curX, y + lineH * 0.06f, pw, lineH * 0.88f, mCodeBack, 3 * mScale);
							let it = AddText(piece, curX, y + (lineH - sz) * 0.5f, pw, lineH, sz, col, mono, bold);
							SetLink(it, span, hasLink, lk);
							start = end;
							lineUsed = true;
							if (start < token.Length)
							{
								curX = x0;
								y += lineH;
							}
							else
								curX += pw;
						}
						continue;
					}
					if (mono)
						AddRect(curX - 1 * mScale, y + lineH * 0.06f, w + 2 * mScale, lineH * 0.88f, mCodeBack, 3 * mScale);
					let it = AddText(token, curX, y + (lineH - sz) * 0.5f, w, lineH, sz, col, mono, bold);
					SetLink(it, span, hasLink, lk);
					curX += w;
					lineUsed = true;
				}
			}
			return lineUsed ? y + lineH : y;
		}

		static void SetLink(DocItem it, DocSpan span, bool hasLink, DocLinkKind lk)
		{
			if (!hasLink)
				return;
			it.HasLink = true;
			it.Link.Set(span.Link);
			it.LinkKind = lk;
		}

		float SpansWidthEstimate(List<DocSpan> spans, float size)
		{
			float w = 0;
			for (let s in spans)
				w += TextW(s.Text, (s.Style & DocSpan.cCode) != 0, size);
			return w;
		}

		void Run()
		{
			mText = Look.Foreground;
			mDim = Look.ForegroundDim;
			mStrong = Look.ForegroundHover;
			mLinkColor = Look.AccentBlue;
			mCodeText = Gui.Color(226, 190, 128);
			mCodeBack = Look.Darker ? Gui.Color(34, 34, 34) : Gui.Color(20, 20, 20);
			mItalic = Theme.Mix(Look.Foreground, Gui.Color(150, 190, 235), 0.45f);
			mRule = Look.DropdownOutline;
			mQuoteBar = Theme.Mix(Look.AccentBlue, Gui.Color(0, 0, 0), 0.35f);
			mHeadBack = Look.Header;

			float y = 0;
			float u = mBase;
			float W = mWidth;
			bool first = true;
			DocBlockKind prev = .Paragraph;
			for (let b in mPage.Blocks)
			{
				// Space between blocks: lists keep their items close, headings open up above.
				if (!first)
				{
					if (b.Kind == .Heading)
						y += u * ((b.Level <= 2) ? 1.4f : 0.9f);
					else if (b.Kind == .ListItem && prev == .ListItem)
						y += u * 0.18f;
					else
						y += u * 0.65f;
				}
				first = false;
				prev = b.Kind;
				switch (b.Kind)
				{
				case .Heading:
					float[6] sizes = .(1.75f, 1.42f, 1.2f, 1.08f, 1.0f, 1.0f);
					float hs = u * sizes[Math.Clamp(b.Level - 1, 0, 5)];
					if (!b.Slug.IsEmpty && !mOut.Anchors.ContainsKey(b.Slug))
						mOut.Anchors[new String(b.Slug)] = y;
					// A heading's spans are drawn bold.
					List<DocSpan> bold = scope .();
					for (let s in b.Spans)
					{
						let c = new DocSpan();
						c.Text.Set(s.Text);
						c.Style = s.Style | DocSpan.cBold;
						c.Link.Set(s.Link);
						bold.Add(c);
					}
					defer { for (let c in bold) delete c; }
					y = Flow(bold, 0, W, y, hs, mStrong);
					if (b.Level <= 2)
					{
						y += u * 0.25f;
						AddLine(0, y, W, mRule);
						y += 1;
					}
				case .Paragraph:
					y = Flow(b.Spans, 0, W, y, u, mText);
				case .ListItem:
					float indent = u * 1.7f * (b.Level + 1);
					float markX = indent - u * 1.25f;
					if (b.Number > 0)
					{
						String n = scope $"{b.Number}.";
						float nw = TextW(n, false, u);
						AddText(n, indent - u * 0.4f - nw, y + (u * 1.45f - u) * 0.5f, nw, u * 1.45f, u, mDim, false, false);
					}
					else
					{
						StringView mark = (b.Level == 0) ? "\u{2022}" : "\u{2013}";
						AddText(mark, markX + u * 0.45f, y + (u * 1.45f - u) * 0.5f, u * 0.6f, u * 1.45f, u, mDim, false, false);
					}
					y = Flow(b.Spans, indent, W - indent, y, u, mText);
				case .Quote:
					float pad = u * 0.9f;
					let bar = AddRect(0, y, 3 * mScale, 0, mQuoteBar, 1);
					float end = Flow(b.Spans, pad, W - pad, y + u * 0.2f, u, mDim);
					bar.H = end - y + u * 0.2f;
					y = end + u * 0.2f;
				case .Code:
					float cs = u * 0.92f;
					float lh = cs * 1.4f;
					float padc = u * 0.7f;
					let back = AddRect(0, y, W, 0, mCodeBack, 4 * mScale);
					float cy = y + padc;
					for (var line in b.Text.Split('\n'))
					{
						// Long lines break between characters at the column's edge.
						if (line.IsEmpty)
						{
							cy += lh;
							continue;
						}
						int start = 0;
						float availW = W - 2 * padc;
						while (start < line.Length)
						{
							int endc = start;
							float pw = 0;
							while (endc < line.Length)
							{
								int next = endc + 1;
								while (next < line.Length && ((uint8)line[next] & 0xC0) == 0x80)
									next++;
								float cw = TextW(line.Substring(endc, next - endc), true, cs);
								if (pw + cw > availW && endc > start)
									break;
								pw += cw;
								endc = next;
							}
							AddText(line.Substring(start, endc - start), padc, cy + (lh - cs) * 0.5f, pw, lh, cs, mText, true, false);
							cy += lh;
							start = endc;
						}
					}
					back.H = cy - y + padc;
					y = cy + padc;
				case .Rule:
					y += u * 0.3f;
					AddLine(0, y, W, mRule);
					y += u * 0.3f;
				case .Table:
					y = LayoutTable(b, y);
				case .Image:
					y = LayoutImage(b, y);
				}
			}
			mOut.Height = y + u * 2;
		}

		float LayoutImage(DocBlock b, float y)
		{
			String full = scope .();
			full.AppendF("{}{}{}", mLib.Dir, Path.DirectorySeparatorChar, b.Target);
			full.Replace('/', Path.DirectorySeparatorChar);
			let img = DocImages.Get(full);
			let it = new DocItem();
			it.Kind = .Image;
			it.Text.Set(b.Text);
			it.ImagePath.Set(b.Target);
			it.Image = img;
			it.X = 0;
			it.Y = y;
			if (img.Failed)
			{
				it.W = mWidth;
				it.H = mBase * 3.2f;
			}
			else
			{
				float w = Math.Min((float)img.Width, mWidth);
				it.W = w;
				it.H = w * img.Height / img.Width;
			}
			mOut.Items.Add(it);
			return y + it.H;
		}

		float LayoutTable(DocBlock b, float yIn)
		{
			float u = mBase;
			float padX = u * 0.6f;
			float padY = u * 0.35f;
			int cols = 0;
			for (let r in b.Rows)
				cols = Math.Max(cols, r.Cells.Count);
			if (cols == 0)
				return yIn;
			float[] natural = scope float[cols];
			for (let r in b.Rows)
				for (int c < r.Cells.Count)
					natural[c] = Math.Max(natural[c], SpansWidthEstimate(r.Cells[c].Spans, u) + 2 * padX);
			float total = 0;
			for (let n in natural)
				total += n;
			float[] widths = scope float[cols];
			if (total <= mWidth)
			{
				// Spare width goes to the widest column.
				int widest = 0;
				for (int c < cols)
					if (natural[c] > natural[widest])
						widest = c;
				for (int c < cols)
					widths[c] = natural[c];
				widths[widest] += mWidth - total;
			}
			else
			{
				// Wider than the column: each column keeps what its narrowest word needs, the rest is shared by need.
				float minW = u * 6;
				float spare = mWidth - minW * cols;
				float over = 0;
				for (let n in natural)
					over += Math.Max(n - minW, 0);
				for (int c < cols)
					widths[c] = minW + ((over > 0) ? spare * Math.Max(natural[c] - minW, 0) / over : spare / cols);
			}
			float y = yIn;
			float tableTop = y;
			for (let r in b.Rows)
			{
				bool header = @r.Index == 0;
				let back = AddRect(0, y, mWidth, 0, header ? mHeadBack : 0, 0);
				float rowEnd = y;
				float x = 0;
				for (int c < cols)
				{
					if (c < r.Cells.Count)
					{
						float end = Flow(r.Cells[c].Spans, x + padX, widths[c] - 2 * padX, y + padY, u, header ? mStrong : mText);
						rowEnd = Math.Max(rowEnd, end);
					}
					x += widths[c];
				}
				rowEnd = Math.Max(rowEnd, y + u * 1.45f + padY) + padY;
				back.H = rowEnd - y;
				if (!header && (@r.Index & 1) == 0)
					back.Color = Look.Darker ? Gui.Color(30, 30, 30) : Gui.Color(32, 32, 32);
				else if (!header)
					back.Color = 0;
				y = rowEnd;
				AddLine(0, y, mWidth, mRule);
			}
			// Column rules.
			float cx = 0;
			for (int c < cols - 1)
			{
				cx += widths[c];
				let l = new DocItem();
				l.Kind = .Rect;
				l.X = cx;
				l.Y = tableTop;
				l.W = 1;
				l.H = y - tableTop;
				l.Color = mRule;
				mOut.Items.Add(l);
			}
			AddLine(0, tableTop, mWidth, mRule);
			return y;
		}
	}

	/// A remembered place for Back: the page and how far it was scrolled.
	class DocNav
	{
		public String File = new .() ~ delete _;
		public float Scroll;
	}

	/// Help > Documentation: the user pages shipped with the editor (the `docs` folder next to the program, or the
	/// checkout's in a development build), listed on the left with a search over titles and headings, the page on the
	/// right with working links, anchors and pictures.
	extension EditorApp
	{
		bool mShowDocs;
		bool mDocBringFront;
		DocLibrary mDocLib ~ delete _;
		bool mDocLoaded;
		DocPage mDocPage;
		String mDocAnchor = new .() ~ delete _;
		float mDocScrollTo = -1;
		float mDocScrollNow;
		List<DocNav> mDocBack = new .() ~ DeleteContainerAndItems!(_);
		TextBuffer mDocSearch = new .(128) ~ delete _;
		String mDocQuerySeen = new .() ~ delete _;
		List<DocHit> mDocHits = new .() ~ DeleteContainerAndItems!(_);
		DocLayout mDocLayout ~ delete _;
		bool mDocFocusSearch;
		String mDocImageView = new .() ~ delete _;
		bool mDocImageOpen;
		/// Last frame's numbers, for the self tests.
		int mDocLinkClicks;

		public DocLibrary DocLib
		{
			get
			{
				LoadDocs();
				return mDocLib;
			}
		}

		/// The folder the documentation is read from ("" = none).
		void LoadDocs()
		{
			if (mDocLoaded)
				return;
			mDocLoaded = true;
			mDocLib = new DocLibrary();
			String exePath = scope .();
			String exeDir = scope .();
			Environment.GetExecutableFilePath(exePath);
			Path.GetDirectoryPath(exePath, exeDir).IgnoreError(); // a file always has a folder part
			String dir = scope .();
			DocLibrary.FindDir(exeDir, dir);
			int n = mDocLib.Load(dir);
			Notify.Log(.Info, "Docs", dir.IsEmpty ? "No documentation folder next to the editor" : scope $"Documentation: {n} pages from {dir}");
			if (mDocPage == null && n > 0)
				mDocPage = mDocLib.Pages[0];
		}

		/// Help > Documentation (F1, the start page's link): shows the panel, on `file` (a page's file name) when given.
		public void OpenDocumentation(StringView file = "", StringView anchor = "")
		{
			LoadDocs();
			mShowDocs = true;
			mDocBringFront = true;
			if (!file.IsEmpty)
			{
				let page = mDocLib.FindByFile(file);
				if (page != null)
					ShowDocPage(page, anchor, true);
			}
			else if (mDocPage == null && !mDocLib.Pages.IsEmpty)
				ShowDocPage(mDocLib.Pages[0], "", false);
		}

		/// Shows a page (and scrolls to a heading of it). `remember` keeps where the reader was for Back.
		void ShowDocPage(DocPage page, StringView anchor, bool remember)
		{
			if (remember && mDocPage != null && (page != mDocPage || !anchor.IsEmpty))
			{
				let nav = new DocNav();
				nav.File.Set(mDocPage.FileName);
				nav.Scroll = mDocScrollNow;
				mDocBack.Add(nav);
				while (mDocBack.Count > 50)
				{
					delete mDocBack[0];
					mDocBack.RemoveAt(0);
				}
			}
			if (page != mDocPage)
			{
				mDocPage = page;
				DeleteAndNullify!(mDocLayout);
				mDocScrollTo = 0;
			}
			mDocAnchor.Set(anchor);
			if (!anchor.IsEmpty)
				mDocScrollTo = -2; // resolved once the layout has the anchor
		}

		void DocGoBack()
		{
			if (mDocBack.IsEmpty)
				return;
			let nav = mDocBack.PopBack();
			defer delete nav;
			let page = mDocLib.FindByFile(nav.File);
			if (page == null)
				return;
			if (page != mDocPage)
			{
				mDocPage = page;
				DeleteAndNullify!(mDocLayout);
			}
			mDocAnchor.Clear();
			mDocScrollTo = nav.Scroll;
		}

		/// A click on a link of a page.
		void DocFollow(DocItem it)
		{
			mDocLinkClicks++;
			String slug = scope .();
			DocPage target = null;
			let kind = mDocLib.Resolve(mDocPage, it.Link, out target, slug);
			switch (kind)
			{
			case .Page:
				ShowDocPage(target, slug, true);
			case .External:
				OpenUrl(it.Link);
			case .Image:
				mDocImageView.Set(slug);
				mDocImageOpen = true;
			case .Missing:
				SetStatus(scope $"{it.Link} is not part of the documentation shipped with the editor", .Info, false);
			}
		}

		void DocSearchUpdate()
		{
			String q = scope .(mDocSearch.View);
			q.Trim();
			if (q == mDocQuerySeen)
				return;
			mDocQuerySeen.Set(q);
			ClearAndDeleteItems!(mDocHits);
			if (!q.IsEmpty)
				mDocLib.Search(q, mDocHits);
		}

		void DrawDocIndex()
		{
			Gui.igSetNextItemWidth(-1);
			if (mDocFocusSearch)
			{
				Gui.igSetKeyboardFocusHere(0);
				mDocFocusSearch = false;
			}
			Gui.igInputText("##docsearch", mDocSearch.Ptr, (.)mDocSearch.Capacity, 0, null, null);
			if (mDocSearch.View.IsEmpty && !Gui.igIsItemActive())
			{
				let min = Gui.igGetItemRectMin();
				Gui.DrawText(Gui.igGetWindowDrawList(), .(min.x + 8 * Look.Scale, min.y + 4 * Look.Scale), Look.ForegroundDim, scope $"{Icon.Search}  Search titles and headings");
			}
			DocSearchUpdate();
			Gui.igSpacing();
			if (mDocSearchActive)
			{
				if (mDocHits.IsEmpty)
				{
					Gui.TextDisabled("Nothing found.");
					return;
				}
				Gui.TextDisabled(scope $"{mDocHits.Count} result{(mDocHits.Count == 1 ? "" : "s")}");
				for (let h in mDocHits)
				{
					Gui.PushID((int32)@h.Index);
					String title = scope .();
					if (h.Heading != null)
						h.Heading.PlainText(title);
					else
						title.Set(h.Page.Title);
					float lh = Gui.igGetFontSize() * 2.6f;
					let p = Gui.igGetCursorScreenPos();
					float w = Gui.igGetContentRegionAvail().x;
					if (Gui.Selectable("##hit", false, 0, .(w, lh)))
					{
						ShowDocPage(h.Page, (h.Heading != null) ? (StringView)h.Heading.Slug : "", true);
					}
					let dl = Gui.igGetWindowDrawList();
					String shown = scope .();
					Look.EllipsizeEnd(title, w - 12 * Look.Scale, shown);
					Gui.DrawText(dl, .(p.x + 6 * Look.Scale, p.y + lh * 0.12f), Look.Foreground, shown);
					String sub = scope .();
					Look.EllipsizeEnd(h.Heading != null ? scope $"in {h.Page.Title}" : h.Page.Summary, w - 12 * Look.Scale, sub);
					Gui.DrawText(dl, .(p.x + 6 * Look.Scale, p.y + lh * 0.52f), Look.ForegroundDim, sub);
					Gui.PopID();
				}
				return;
			}
			for (let page in mDocLib.Pages)
			{
				bool selected = page == mDocPage;
				Gui.PushID(page.FileName);
				if (Gui.Selectable(page.Title, selected))
					ShowDocPage(page, "", true);
				if (Gui.igIsItemHovered(0) && !page.Summary.IsEmpty)
					Gui.Tooltip(page.Summary);
				Gui.PopID();
				if (selected)
				{
					for (let b in page.Blocks)
					{
						if (b.Kind != .Heading || b.Level != 2)
							continue;
						String title = scope .();
						b.PlainText(title);
						Gui.PushID(b.Slug);
						Gui.igIndent(14 * Look.Scale);
						Gui.igPushStyleColor_U32(Col.Text, Look.ForegroundDim);
						if (Gui.Selectable(title, !mDocAnchor.IsEmpty && mDocAnchor == b.Slug))
							ShowDocPage(page, b.Slug, true);
						Gui.igPopStyleColor(1);
						Gui.igUnindent(14 * Look.Scale);
						Gui.PopID();
					}
				}
			}
		}

		bool mDocSearchActive => !mDocQuerySeen.IsEmpty;

		void DrawDocBody()
		{
			if (mDocPage == null)
				return;
			// The text column: readable width, left aligned.
			let avail = Gui.igGetContentRegionAvail();
			float colW = Math.Min(avail.x - 28 * Look.Scale, 900 * Look.Scale);
			float baseSize = Gui.igGetFontSize();
			if (mDocLayout == null || mDocLayout.Page != mDocPage || Math.Abs(mDocLayout.Width - colW) > 0.5f ||
				Math.Abs(mDocLayout.BaseSize - baseSize) > 0.01f || mDocLayout.Darker != Look.Darker)
			{
				delete mDocLayout;
				mDocLayout = DocLayouter.Build(mDocLib, mDocPage, colW, baseSize, Look.Scale, UiFont != null ? UiFont : Gui.igGetFont(), mMono);
			}
			let lay = mDocLayout;
			// A requested scroll position (a heading, Back, a new page).
			if (mDocScrollTo == -2)
			{
				if (lay.Anchors.TryGetValue(mDocAnchor, let ay))
					mDocScrollTo = Math.Max(ay - baseSize * 0.4f, 0);
				else
					mDocScrollTo = 0;
			}
			if (mDocScrollTo >= 0)
			{
				Gui.igSetScrollY_Float(mDocScrollTo);
				mDocScrollTo = -1;
			}
			mDocScrollNow = Gui.igGetScrollY();
			float pad = 14 * Look.Scale;
			Gui.igSetCursorPosX(Gui.igGetCursorPosX() + pad);
			let origin = Gui.igGetCursorScreenPos();
			Gui.igDummy(.(colW, lay.Height));
			let dl = Gui.igGetWindowDrawList();
			let mouse = Gui.igGetMousePos();
			bool hovered = Gui.igIsWindowHovered(0);
			bool click = hovered && Gui.igIsMouseClicked_Bool(0, false);
			float viewTop = mDocScrollNow - 40;
			float viewBottom = mDocScrollNow + avail.y + 40;
			DocItem clicked = null;
			for (let it in lay.Items)
			{
				if (it.Y + it.H < viewTop || it.Y > viewBottom)
					continue;
				let min = ImVec2(origin.x + it.X, origin.y + it.Y);
				switch (it.Kind)
				{
				case .Rect:
					if ((it.Color >> 24) != 0)
						Gui.ImDrawList_AddRectFilled(dl, min, .(min.x + it.W, min.y + it.H), it.Color, it.Rounding, 0);
				case .Line:
					Gui.ImDrawList_AddLine(dl, min, .(min.x + it.W, min.y), it.Color, 1);
				case .Text:
					uint32 color = it.Color;
					bool over = false;
					if (it.HasLink && hovered && mouse.x >= min.x && mouse.x < min.x + it.W && mouse.y >= min.y && mouse.y < min.y + it.H)
					{
						over = true;
						if (it.LinkKind != .Missing)
						{
							color = Look.PrimaryHover;
							Gui.igSetMouseCursor(7);
						}
						if (click)
							clicked = it;
					}
					Gui.DrawText(dl, min, color, it.Text, it.Size, it.Mono ? mMono : null);
					if (it.Bold)
						Gui.DrawText(dl, .(min.x + 0.7f * Look.Scale, min.y), color, it.Text, it.Size, it.Mono ? mMono : null);
					if (it.HasLink && it.LinkKind != .Missing)
					{
						float ly = min.y + it.H - it.Size * 0.12f - 2;
						Gui.ImDrawList_AddLine(dl, .(min.x, ly), .(min.x + it.W, ly), over ? color : (color & 0x00FFFFFF) | 0x99000000, 1);
					}
				case .Image:
					DrawDocImage(dl, it, min, mouse, hovered, click);
				}
			}
			if (clicked != null)
				DocFollow(clicked);
		}

		void DrawDocImage(ImDrawList* dl, DocItem it, ImVec2 min, ImVec2 mouse, bool hovered, bool click)
		{
			let max = ImVec2(min.x + it.W, min.y + it.H);
			bool over = hovered && mouse.x >= min.x && mouse.x < max.x && mouse.y >= min.y && mouse.y < max.y;
			if (it.Image == null || it.Image.Failed)
			{
				Gui.ImDrawList_AddRectFilled(dl, min, max, Look.Recessed, 4 * Look.Scale, 0);
				Gui.ImDrawList_AddRect(dl, min, max, Look.DropdownOutline, 4 * Look.Scale, 1, 0);
				String label = scope $"{Icon.FileText}  {it.Text.IsEmpty ? it.ImagePath : it.Text}";
				String shown = scope .();
				Look.EllipsizeEnd(label, it.W - 24 * Look.Scale, shown);
				let ts = Gui.CalcTextSize(shown);
				Gui.DrawText(dl, .(min.x + (it.W - ts.x) * 0.5f, min.y + (it.H - ts.y) * 0.5f), Look.ForegroundDim, shown);
				return;
			}
			DocImages.Draw(dl, it.Image, min, max);
			Gui.ImDrawList_AddRect(dl, min, max, over ? Look.AccentBlue : Look.DropdownOutline, 2 * Look.Scale, 1, 0);
			if (over)
			{
				Gui.igSetMouseCursor(7);
				if (click)
				{
					mDocImageView.Set(it.ImagePath);
					mDocImageOpen = true;
				}
			}
		}

		/// A picture opened from a link, scaled to the window.
		void DrawDocImagePopup()
		{
			if (mDocImageOpen)
			{
				Gui.OpenPopup("##docimage");
				mDocImageOpen = false;
			}
			let vp = Gui.igGetMainViewport();
			Gui.igSetNextWindowPos(.(vp.WorkPos.x + vp.WorkSize.x * 0.5f, vp.WorkPos.y + vp.WorkSize.y * 0.5f), Cond.Always, .(0.5f, 0.5f));
			if (!Gui.igBeginPopupModal("##docimage", null, WindowFlags.AlwaysAutoResize | WindowFlags.NoTitleBar))
				return;
			String full = scope .();
			full.AppendF("{}{}{}", mDocLib.Dir, Path.DirectorySeparatorChar, mDocImageView);
			full.Replace('/', Path.DirectorySeparatorChar);
			let img = DocImages.Get(full);
			if (img.Failed)
				Gui.TextDisabled(scope $"{mDocImageView} could not be shown here.");
			else
			{
				// The window less the popup's padding, the spacing and the Close button under the picture.
				float maxW = vp.WorkSize.x * 0.9f - 32 * Look.Scale;
				float maxH = vp.WorkSize.y * 0.94f - 110 * Look.Scale;
				float s = Math.Min(Math.Min(maxW / img.Width, maxH / img.Height), 1.0f);
				let p = Gui.igGetCursorScreenPos();
				Gui.igDummy(.(img.Width * s, img.Height * s));
				DocImages.Draw(Gui.igGetWindowDrawList(), img, p, .(p.x + img.Width * s, p.y + img.Height * s));
			}
			Gui.igSpacing();
			if (Gui.Button("Close", .(100 * Look.Scale, 0)) || Gui.IsKeyPressed(Key.Escape, false) || mSpDocImageClose)
			{
				mSpDocImageClose = false;
				Gui.igCloseCurrentPopup();
			}
			Gui.EndPopup();
		}

		void DrawDocsWindow()
		{
			if (!mShowDocs)
				return;
			LoadDocs();
			let vp = Gui.igGetMainViewport();
			Gui.igSetNextWindowSize(.(Math.Min(vp.WorkSize.x * 0.82f, 1360 * Look.Scale), Math.Min(vp.WorkSize.y * 0.86f, 880 * Look.Scale)), Cond.Appearing);
			Gui.igSetNextWindowPos(.(vp.WorkPos.x + vp.WorkSize.x * 0.5f, vp.WorkPos.y + vp.WorkSize.y * 0.5f), Cond.Appearing, .(0.5f, 0.5f));
			if (mDocBringFront || (StartPageVisible && mStartPageFocused))
			{
				Gui.igSetNextWindowFocus();
				mDocBringFront = false;
			}
			if (Gui.Begin(scope $"{Icon.BookOpen}  Documentation###Documentation", &mShowDocs, WindowFlags.NoCollapse))
			{
				if (mDocLib.Pages.IsEmpty)
				{
					Gui.igSetCursorPos(.(20 * Look.Scale, Gui.igGetCursorPos().y + 16 * Look.Scale));
					Gui.igPushTextWrapPos(Gui.igGetWindowWidth() - 24 * Look.Scale);
					Gui.TextDisabled("The documentation is not installed with this build. It is the docs folder next to the editor program.");
					Gui.igPopTextWrapPos();
				}
				else
				{
					if (Gui.IsKeyPressed(Key.F, false) && Gui.IsCtrlDown && Gui.igIsWindowFocused(1 << 0 | 1 << 1))
						mDocFocusSearch = true;
					// Pages on the left, the page on the right.
					Gui.igPushStyleColor_U32(Col.ChildBg, Look.Recessed);
					if (Gui.igBeginChild_Str("##docindex", .(270 * Look.Scale, 0), ChildFlags.Borders, 0))
						DrawDocIndex();
					Gui.igEndChild();
					Gui.igPopStyleColor(1);
					Gui.SameLine();
					if (Gui.igBeginChild_Str("##docbody", .(0, 0), 0, 0))
					{
						Gui.igBeginDisabled(mDocBack.IsEmpty);
						if (Gui.Button(scope $"{Icon.ArrowLeft}  Back"))
							DocGoBack();
						Gui.igEndDisabled();
						Gui.SameLine();
						Gui.igAlignTextToFramePadding();
						StringView pageTitle = (mDocPage != null) ? (StringView)mDocPage.Title : "";
						Gui.TextDisabled(scope $"Documentation  /  {pageTitle}");
						Gui.igSpacing();
						if (Gui.igBeginChild_Str("##docscroll", .(0, 0), 0, 0))
							DrawDocBody();
						Gui.igEndChild();
					}
					Gui.igEndChild();
				}
			}
			Gui.End();
			DrawDocImagePopup();
		}
	}
}
