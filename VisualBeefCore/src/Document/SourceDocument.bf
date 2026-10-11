using System;
using System.Collections;
using System.IO;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Document
{
	struct NodePos
	{
		public float X;
		public float Y;
	}

	/// One method's graph plus the syntax it came from. The graph is built on first use, so
	/// large files with hundreds of methods stay fast to edit.
	class MethodGraph
	{
		public Member Method;     // owned by the CompilationUnit
		public Member Owner;      // containing type (may be null)
		public String Key = new .() ~ delete _;
		public SourceDocument Doc;
		Graph mGraph ~ delete _;

		public bool Graphable => Method.Body != null;
		/// Code the parser could not read: viewable as a read-only error graph, never written.
		public bool IsBroken => Method.Kind == .Broken;
		public bool IsBuilt => mGraph != null;

		public Graph Graph
		{
			get
			{
				if (mGraph == null)
					mGraph = Doc.[Friend]BuildGraph(this);
				return mGraph;
			}
		}

		/// Takes the built graph out (caller owns it). Used to carry graphs across a re-parse.
		public Graph DetachGraph()
		{
			let g = mGraph;
			mGraph = null;
			return g;
		}

		/// Installs an existing graph (takes ownership).
		public void AttachGraph(Graph graph)
		{
			if (mGraph == graph)
				return;
			delete mGraph;
			mGraph = graph;
		}
	}

	/// A built graph carried across a re-parse, with the body text it was consistent with.
	class KeptGraph
	{
		public String Key = new .() ~ delete _;
		public String Body = new .() ~ delete _;
		/// What the graph was built against besides its body (`ContextKey`).
		public String Context = new .() ~ delete _;
		public int Index;
		public Graph Graph ~ delete _;
	}

	/// Nodes not connected to a method's execution flow. They produce no code, so they are kept
	/// aside across regenerations and re-attached afterwards.
	class OrphanSet
	{
		public String MethodKey = new .() ~ delete _;
		public List<Node> Nodes = new .() ~ DeleteContainerAndItems!(_);

		public struct InternalLink
		{
			public int FromNode;
			public String FromPin;
			public int ToNode;
			public String ToPin;
		}

		public struct ExternalLink
		{
			public int OrphanNode;
			public String OrphanPin;
			public bool OrphanIsFrom;
			public String OtherKey;
			public String OtherPin;
		}

		public List<InternalLink> Internal = new .() ~ { for (let l in _) { delete l.FromPin; delete l.ToPin; } delete _; };
		public List<ExternalLink> External = new .() ~ { for (let l in _) { delete l.OrphanPin; delete l.OtherKey; delete l.OtherPin; } delete _; };

		public OrphanSet Clone()
		{
			OrphanSet copy = new .();
			copy.MethodKey.Set(MethodKey);
			for (let n in Nodes)
				copy.Nodes.Add(CloneNode(n));
			for (let il in Internal)
			{
				var c = il;
				c.FromPin = new .(il.FromPin);
				c.ToPin = new .(il.ToPin);
				copy.Internal.Add(c);
			}
			for (let el in External)
			{
				var c = el;
				c.OrphanPin = new .(el.OrphanPin);
				c.OtherKey = new .(el.OtherKey);
				c.OtherPin = new .(el.OtherPin);
				copy.External.Add(c);
			}
			return copy;
		}

		/// Copies (does not move) the orphans out of a graph whose keys are assigned.
		public static OrphanSet Capture(Graph graph)
		{
			HashSet<Node> reachable = scope .();
			graph.GetReachable(reachable);
			List<Node> orphans = scope .();
			for (let n in graph.Nodes)
				if (!reachable.Contains(n))
					orphans.Add(n);
			if (orphans.IsEmpty)
				return null;
			return CaptureNodes(graph, orphans);
		}

		/// Copies an arbitrary set of nodes plus the links between them (used for copy/paste too).
		public static OrphanSet CaptureNodes(Graph graph, List<Node> orphans)
		{
			OrphanSet set = new .();
			set.MethodKey.Set(graph.MethodKey);
			Dictionary<Node, int> index = scope .();
			for (let n in orphans)
			{
				index[n] = set.Nodes.Count;
				set.Nodes.Add(CloneNode(n));
			}
			for (let l in graph.Links)
			{
				bool fromOrphan = index.TryGetValue(l.From.Owner, let fromIdx);
				bool toOrphan = index.TryGetValue(l.To.Owner, let toIdx);
				if (fromOrphan && toOrphan)
				{
					InternalLink il;
					il.FromNode = fromIdx;
					il.FromPin = new .(l.From.Name);
					il.ToNode = toIdx;
					il.ToPin = new .(l.To.Name);
					set.Internal.Add(il);
				}
				else if (fromOrphan || toOrphan)
				{
					ExternalLink el;
					el.OrphanIsFrom = fromOrphan;
					el.OrphanNode = fromOrphan ? fromIdx : toIdx;
					el.OrphanPin = new .(fromOrphan ? l.From.Name : l.To.Name);
					let other = fromOrphan ? l.To : l.From;
					el.OtherKey = new .(other.Owner.Key);
					el.OtherPin = new .(other.Name);
					set.External.Add(el);
				}
			}
			return set;
		}

		public static Node CloneNode(Node src)
		{
			Node n = new .();
			n.Kind = src.Kind;
			n.Text.Set(src.Text);
			n.Text2.Set(src.Text2);
			n.NullCond = src.NullCond;
			n.Cascade = src.Cascade;
			n.Postfix = src.Postfix;
			n.IsPure = src.IsPure;
			n.Binding = src.Binding;
			Graph.CopyStr(ref n.OwnerType, src.OwnerType);
			Graph.CopyStr(ref n.Qualifier, src.Qualifier);
			n.Ambiguous = src.Ambiguous;
			if (src.Overloads != null)
			{
				n.Overloads = new .();
				for (let s in src.Overloads)
					n.Overloads.Add(new String(s));
			}
			Graph.CopyStr(ref n.Alloc, src.Alloc);
			n.IsArray = src.IsArray;
			Graph.CopyStr(ref n.Attributes, src.Attributes);
			n.X = src.X;
			n.Y = src.Y;
			n.HasPos = src.HasPos;
			n.Edited = true;
			n.Key.Set(src.Key);
			// A copy of a stateful macro must not share the original's state field.
			if (n.Kind == .Flow && FlowMacros.IsStateful(n.Text))
				n.Text2.Clear();
			for (let p in src.Inputs)
				n.Inputs.Add(ClonePin(p, n));
			for (let p in src.Outputs)
				n.Outputs.Add(ClonePin(p, n));
			return n;
		}

		static Pin ClonePin(Pin src, Node owner)
		{
			Pin p = new .();
			p.Owner = owner;
			p.IsInput = src.IsInput;
			p.Kind = src.Kind;
			p.Name.Set(src.Name);
			p.Label.Set(src.Label);
			p.TypeName.Set(src.TypeName);
			p.Default.Set(src.Default);
			p.Optional = src.Optional;
			p.Parens = src.Parens;
			if (src.EndComments != null)
				p.EndComments = new String(src.EndComments);
			p.Mode = src.Mode;
			p.Form = src.Form;
			Graph.CopyStr(ref p.OutName, src.OutName);
			Graph.CopyStr(ref p.OutDecl, src.OutDecl);
			Graph.CopyStr(ref p.OutDeclRaw, src.OutDeclRaw);
			p.OutKeyword = src.OutKeyword;
			p.OutAuto = src.OutAuto;
			p.OutKeepName = src.OutKeepName;
			return p;
		}

		/// Adds copies of the orphans into a freshly built graph.
		public void InjectInto(Graph graph)
		{
			List<Node> added = scope .();
			InjectInto(graph, 0, 0, true, added);
		}

		/// Adds copies of the captured nodes, offset by dx/dy. Returns the new nodes in outAdded.
		public void InjectInto(Graph graph, float dx, float dy, bool relinkExternal, List<Node> added)
		{
			for (let src in Nodes)
			{
				if (src.Kind == .Entry)
					continue;
				Node n = CloneNode(src);
				n.X += dx;
				n.Y += dy;
				n.Moved = true;
				n.Id = graph.NewId();
				for (let p in n.Inputs)
					p.Id = graph.NewId();
				for (let p in n.Outputs)
					p.Id = graph.NewId();
				graph.Nodes.Add(n);
				added.Add(n);
			}
			// Map captured indices to added nodes (Entry nodes are skipped).
			List<Node> byIndex = scope .();
			{
				int ai = 0;
				for (let src in Nodes)
				{
					if (src.Kind == .Entry)
						byIndex.Add(null);
					else
						byIndex.Add(added[ai++]);
				}
			}
			for (let il in Internal)
			{
				let fromNode = byIndex[il.FromNode];
				let toNode = byIndex[il.ToNode];
				if (fromNode == null || toNode == null)
					continue;
				let from = fromNode.FindOutput(il.FromPin);
				let to = toNode.FindInput(il.ToPin);
				if (from != null && to != null)
					graph.Connect(from, to);
			}
			if (!relinkExternal)
				return;
			for (let el in External)
			{
				Node other = null;
				for (let n in graph.Nodes)
				{
					if (n.Key == el.OtherKey && !added.Contains(n))
					{
						other = n;
						break;
					}
				}
				if (other == null)
					continue;
				let orphan = byIndex[el.OrphanNode];
				if (orphan == null)
					continue;
				if (el.OrphanIsFrom)
				{
					let from = orphan.FindOutput(el.OrphanPin);
					let to = other.FindInput(el.OtherPin);
					// Only re-link if it doesn't steal an input the code already fills (exec
					// inputs take any number of links).
					if (from != null && to != null && (to.Kind == .Exec || graph.FindLinkTo(to) == null))
						graph.Connect(from, to);
				}
				else
				{
					let from = other.FindOutput(el.OtherPin);
					let to = orphan.FindInput(el.OrphanPin);
					if (from != null && to != null && (from.Kind == .Data || graph.FindLinkFrom(from) == null))
						graph.Connect(from, to);
				}
			}
			for (let n in added)
				n.Edited = true;
		}
	}

	class Snapshot
	{
		public String Text = new .() ~ delete _;
		public Dictionary<String, NodePos> Layout = new .() ~ DeleteDictionaryAndKeys!(_);
		/// Comment boxes and reroute knots (layout only).
		public List<GraphComment> Comments = new .() ~ DeleteContainerAndItems!(_);
		public List<GraphReroute> Reroutes = new .() ~ DeleteContainerAndItems!(_);
		/// Pending orphans of graphs that were not built.
		public List<OrphanSet> Orphans = new .() ~ DeleteContainerAndItems!(_);
		/// Saved orphans (from the layout file) of graphs that were not built.
		public List<OrphanRecord> OrphanRecords = new .() ~ DeleteContainerAndItems!(_);
		/// Exact copies of every built graph (Graph.MethodKey identifies the method).
		public List<Graph> Graphs = new .() ~ DeleteContainerAndItems!(_);
	}

	/// A Beef source file opened in the visual editor. The source text is the single source of
	/// truth for what the code means; graphs are views of it. A graph is built from the text the
	/// first time it is needed and then kept: graph edits are written back as text, and the
	/// same graph object (same nodes, same kinds) stays live across commits and undo/redo. Only
	/// changes that come from the text (the File tab, reload from disk) rebuild graphs, and only
	/// for methods whose body text actually changed.
	class SourceDocument
	{
		public String FilePath = new .() ~ delete _;
		public CompilationUnit Unit ~ delete _;
		public List<MethodGraph> Methods = new .() ~ DeleteContainerAndItems!(_);
		/// "MethodKey|NodeKey" -> position
		public Dictionary<String, NodePos> Layout = new .() ~ DeleteDictionaryAndKeys!(_);
		/// UE-style comment boxes of every function graph (layout only: never part of the code;
		/// saved in the .vblayout side file).
		public List<GraphComment> Comments = new .() ~ DeleteContainerAndItems!(_);
		/// Reroute knots on links (layout only; saved in the .vblayout side file).
		public List<GraphReroute> Reroutes = new .() ~ DeleteContainerAndItems!(_);
		/// Node comment bubbles pinned to a readable size (layout only; not part of undo states).
		public List<BubblePin> BubblePins = new .() ~ DeleteContainerAndItems!(_);
		/// Saved views 1-9 of the graph canvas (layout only; not part of undo states).
		public List<SavedView> Views = new .() ~ DeleteContainerAndItems!(_);

		public SavedView FindView(StringView methodKey, int n)
		{
			for (let v in Views)
				if (v.N == n && v.MethodKey == methodKey)
					return v;
			return null;
		}

		/// Saves view `n` (1-9) of a method: the grid point in the middle of the canvas and the zoom.
		public void SetView(StringView methodKey, int n, float x, float y, float zoom)
		{
			var v = FindView(methodKey, n);
			if (v == null)
			{
				v = new SavedView();
				v.MethodKey.Set(methodKey);
				v.N = n;
				Views.Add(v);
			}
			v.X = x;
			v.Y = y;
			v.Zoom = zoom;
			LayoutTouched = true;
		}

		/// Clears view `n` of a method (n = 0: all of them). Returns how many were removed.
		public int ClearViews(StringView methodKey, int n = 0)
		{
			int removed = 0;
			for (var i = Views.Count - 1; i >= 0; i--)
			{
				let v = Views[i];
				if (v.MethodKey == methodKey && (n == 0 || v.N == n))
				{
					Views.RemoveAt(i);
					delete v;
					removed++;
				}
			}
			if (removed > 0)
				LayoutTouched = true;
			return removed;
		}

		public bool IsBubblePinned(StringView methodKey, StringView nodeKey)
		{
			for (let b in BubblePins)
				if (b.MethodKey == methodKey && b.NodeKey == nodeKey)
					return true;
			return false;
		}

		public void SetBubblePinned(StringView methodKey, StringView nodeKey, bool pinned)
		{
			for (let b in BubblePins)
				if (b.MethodKey == methodKey && b.NodeKey == nodeKey)
				{
					if (!pinned)
					{
						BubblePins.Remove(b);
						delete b;
					}
					return;
				}
			if (pinned)
			{
				let b = new BubblePin();
				b.MethodKey.Set(methodKey);
				b.NodeKey.Set(nodeKey);
				BubblePins.Add(b);
			}
		}
		public List<OrphanSet> Orphans = new .() ~ DeleteContainerAndItems!(_);
		/// Unconnected nodes read from the layout file for methods whose graph is not built yet.
		/// BuildGraph turns a record back into nodes (and drops it); saving the layout writes
		/// built graphs' orphans afresh and keeps these as they are.
		public List<OrphanRecord> OrphanRecords = new .() ~ DeleteContainerAndItems!(_);
		/// Saved positions dropped because they matched no node, and old positional entries
		/// rewritten in the content-keyed form, since this document was loaded.
		public int32 LayoutPruned;
		public int32 LayoutMigrated;
		/// `#name` lines of the layout file this version doesn't know; written back unchanged.
		public List<String> LayoutUnknown = new .() ~ DeleteContainerAndItems!(_);
		public String IndentUnit = new .() ~ delete _;
		public bool Allman = true;
		/// The file uses Windows line endings; generated text is converted to match.
		public bool CRLF;
		/// Dirty = the current text differs from the last saved (or loaded) text. Kept in step by
		/// RefreshModified(); undoing back to the saved text clears it.
		public bool Modified;
		/// Text as last loaded / saved.
		public String SavedText = new .() ~ delete _;
		/// Fingerprint of the file as last loaded / saved (conflict check before the next save).
		public bool HasDiskStamp;
		public uint64 DiskHash;
		public int DiskLen;
		/// The user changed layout (moved, created or edited nodes / comments / knots) since the
		/// side file was last read or written. Only then is a `.vblayout` written.
		public bool LayoutTouched;
		/// The side file content as read from / written to disk (null: no side file).
		String mLayoutBaseline ~ delete _;
		/// Version of the side file format found on disk (0: none / unversioned).
		public int LayoutFileVersion;
		/// Why the last write of the layout side file failed (empty when it worked): node
		/// positions, comments and reroutes were not saved. The editor reports it once.
		public String LayoutError = new .() ~ delete _;
		public bool LayoutErrorReported;
		public const int LayoutFormatVersion = 2;
		/// Why the last save or layout write failed.
		public String LastError = new .() ~ delete _;
		public int32 Version;
		/// Editor bookkeeping: last write time seen on disk, a pending external change, the
		/// version last indexed, and the version last sent to the compiler.
		public DateTime DiskTime;
		public bool ExternalChange;
		public int32 IndexedVersion = -1;
		public int32 BuildVersion = -1;
		public List<String> Messages = new .() ~ DeleteContainerAndItems!(_);

		List<Snapshot> mUndo = new .() ~ DeleteContainerAndItems!(_);
		List<Snapshot> mRedo = new .() ~ DeleteContainerAndItems!(_);
		const int MaxUndo = 200;

		public StringView Text => (Unit != null) ? Unit.Text : "";

		// ------------------------------------------------------------------ load / save

		public static void GetLayoutPath(StringView sourcePath, String outPath)
		{
			outPath.Append(sourcePath);
			outPath.Append(".vblayout");
		}

		public Result<void> Load(StringView path)
		{
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
				return .Err;
			FilePath.Set(path);
			LoadLayoutFile();
			ClearAndDeleteItems!(Orphans);
			SetTextInternal(text);
			Modified = false;
			SavedText.Set(text);
			DiskHash = FileSafety.Hash(text);
			DiskLen = text.Length;
			HasDiskStamp = true;
			LayoutTouched = false;
			ClearHistory();
			return .Ok;
		}

		public void LoadFromText(StringView text, StringView virtualPath = "")
		{
			FilePath.Set(virtualPath);
			ClearAndDeleteItems!(Orphans);
			ClearAndDeleteItems!(OrphanRecords);
			SetTextInternal(text);
			Modified = false;
			SavedText.Set(text);
			HasDiskStamp = false;
			LayoutTouched = false;
			ClearHistory();
		}

		/// Loads text plus the content of its `.vblayout` side file (as Load does from disk).
		public void LoadFromText(StringView text, StringView virtualPath, StringView layoutText)
		{
			FilePath.Set(virtualPath);
			ClearLayout();
			ParseLayoutText(layoutText);
			ClearAndDeleteItems!(Orphans);
			SetTextInternal(text);
			Modified = false;
			SavedText.Set(text);
			HasDiskStamp = false;
			// The layout did not come from this path's side file, so it still has to be written.
			LayoutTouched = !layoutText.IsEmpty;
			ClearHistory();
		}

		/// Recomputes the dirty flag from the text (dirty = differs from the saved text).
		public void RefreshModified()
		{
			Modified = Unit != null && Unit.Text != SavedText;
		}

		/// True when the file on disk no longer matches what this document loaded or last saved.
		public bool DiskChanged()
		{
			if (FilePath.IsEmpty || !HasDiskStamp || !File.Exists(FilePath))
				return false;
			if (!FileSafety.ReadStamp(FilePath, let hash, let len))
				return false;
			return hash != DiskHash || len != DiskLen;
		}

		public Result<void> Save()
		{
			return (TrySave() == .Saved) ? .Ok : .Err;
		}

		/// True when a built graph of this document has errors (from GraphValidator or the code
		/// generator); its edits are then not in the text. `outMessage` gets the first one.
		public bool FindGraphError(String outMessage = null)
		{
			for (let mg in Methods)
			{
				if (!mg.IsBuilt || mg.Graph.Errors.IsEmpty)
					continue;
				if (outMessage != null)
				{
					let e = mg.Graph.Errors[0];
					let node = mg.Graph.FindNode(e.NodeId);
					String title = scope .();
					node?.GetTitle(title);
					outMessage.AppendF("{} has errors ({}: {}); fix them first, the graph's latest edits are not in the code yet", mg.Key, title, e.Message);
				}
				return true;
			}
			return false;
		}

		/// Writes the source atomically (temp file, flush, replace; the previous content stays in
		/// `File.bf.bak`). Refuses in a read-only project, and refuses when the file changed on
		/// disk since it was loaded unless `force`. The layout side file is written only when the
		/// user touched the layout or this save carries an edit.
		public SaveOutcome TrySave(bool force = false)
		{
			LastError.Clear();
			if (FilePath.IsEmpty)
				return .NoPath;
			if (FileSafety.ReadOnlyProject)
			{
				LastError.Set(FileSafety.ReadOnlyMessage);
				return .ReadOnly;
			}
			// A graph with errors was not written into the text: saving now would store the text
			// without the user's latest edits as if they were saved.
			if (FindGraphError(LastError))
				return .GraphErrors;
			if (!force && DiskChanged())
			{
				LastError.AppendF("{} changed on disk since it was loaded", FilePath);
				return .Conflict;
			}
			// Nothing changed since the last load / save and the disk still matches: no rewrite
			// (and no pointless backup).
			bool skipWrite = !force && HasDiskStamp && Unit.Text == SavedText && File.Exists(FilePath);
			if (!skipWrite && FileSafety.AtomicWrite(FilePath, Unit.Text, FileSafety.KeepBackup, LastError) case .Err)
				return .Failed;
			SavedText.Set(Unit.Text);
			DiskHash = FileSafety.Hash(Unit.Text);
			DiskLen = Unit.Text.Length;
			HasDiskStamp = true;
			bool carriedEdit = Modified || !mUndo.IsEmpty;
			Modified = false;
			CaptureAllLayouts();
			if (LayoutTouched || carriedEdit)
				SaveLayoutFile(true);
			return .Saved;
		}

		/// "Save As": writes to a new path (no conflict check against the old one).
		public Result<void> SaveAs(StringView path)
		{
			// A failed write (read-only folder, missing path) leaves the document on its old file
			// with its disk stamp: the next Save must still check that file for changes.
			String oldPath = scope .(FilePath);
			bool oldStamp = HasDiskStamp;
			let oldHash = DiskHash;
			let oldLen = DiskLen;
			let oldBaseline = mLayoutBaseline;
			bool oldTouched = LayoutTouched;
			FilePath.Set(path);
			HasDiskStamp = false;
			mLayoutBaseline = null;
			LayoutTouched = true;
			if (Save() case .Ok)
			{
				delete oldBaseline;
				return .Ok;
			}
			FilePath.Set(oldPath);
			HasDiskStamp = oldStamp;
			DiskHash = oldHash;
			DiskLen = oldLen;
			delete mLayoutBaseline;
			mLayoutBaseline = oldBaseline;
			LayoutTouched = oldTouched;
			return .Err;
		}

		void LoadLayoutFile()
		{
			ClearLayout();
			if (FilePath.IsEmpty)
				return;
			String layoutPath = scope .();
			GetLayoutPath(FilePath, layoutPath);
			String content = scope .();
			delete mLayoutBaseline;
			mLayoutBaseline = null;
			LayoutFileVersion = 0;
			if (File.ReadAllText(layoutPath, content) case .Err)
				return;
			mLayoutBaseline = new String(content);
			ParseLayoutText(content);
		}

		void ParseLayoutText(StringView content)
		{
			for (let line in content.Split('\n'))
			{
				if (line.StartsWith("#vblayout\t"))
				{
					var v = line.Substring(10);
					v.Trim();
					LayoutFileVersion = (int)int32.Parse(v).GetValueOrDefault();
					continue;
				}
				if (line.StartsWith("#version\t"))
				{
					var vs = line.Substring(9);
					vs.Trim();
					if (int32.Parse(vs) case .Ok(let v))
						LayoutFileVersion = (int)v; // legacy spelling of the header
					continue;
				}
				if (line.StartsWith("#") && !line.StartsWith("# ") && !line.StartsWith("#vblayout	") && !line.StartsWith("#orphan") && !line.StartsWith("#comment\t") &&
					!line.StartsWith("#reroute\t") && !line.StartsWith("#bubble\t") && !line.StartsWith("#view\t") && !line.IsEmpty)
				{
					var l = line;
					l.TrimEnd();
					LayoutUnknown.Add(new String(l));
					continue;
				}
				if (line.StartsWith("#orphan"))
				{
					LoadOrphanLine(line);
					continue;
				}
				if (line.StartsWith("#comment\t") || line.StartsWith("#reroute\t") || line.StartsWith("#bubble\t") || line.StartsWith("#view\t"))
				{
					LoadLayoutExtra(line);
					continue;
				}
				var parts = line.Split('\t');
				StringView key = default;
				StringView xs = default;
				StringView ys = default;
				if (!(parts.GetNext() case .Ok(out key))) continue;
				if (!(parts.GetNext() case .Ok(out xs))) continue;
				if (!(parts.GetNext() case .Ok(out ys))) continue;
				var ys2 = ys;
				ys2.Trim();
				if (float.Parse(xs) case .Ok(let x))
				{
					if (float.Parse(ys2) case .Ok(let y))
					{
						NodePos pos;
						pos.X = x;
						pos.Y = y;
						SetLayout(key, pos);
					}
				}
			}
		}

		/// Parses a `#comment` or `#reroute` line of the layout file:
		///   #comment <tab> methodKey <tab> x <tab> y <tab> w <tab> h <tab> RRGGBBAA <tab> text (escaped)
		///   #reroute <tab> methodKey <tab> fromNodeKey <tab> fromPin <tab> toNodeKey <tab> toPin <tab> x,y;x,y;...
		void LoadLayoutExtra(StringView line)
		{
			var l = line;
			l.TrimEnd();
			List<StringView> f = scope .();
			for (let part in l.Split('\t'))
				f.Add(part);
			if (f[0] == "#comment" && f.Count >= 8)
			{
				GraphComment c = new .();
				c.MethodKey.Set(f[1]);
				c.X = float.Parse(f[2]).GetValueOrDefault();
				c.Y = float.Parse(f[3]).GetValueOrDefault();
				c.W = Math.Max(float.Parse(f[4]).GetValueOrDefault(), 32);
				c.H = Math.Max(float.Parse(f[5]).GetValueOrDefault(), 32);
				if (LayoutText.HexToColor(f[6], let col))
					c.Color = col;
				LayoutText.Unescape(f[7], c.Text);
				c.Pinned = f.Count >= 9 && f[8] == "1";
				Comments.Add(c);
			}
			else if (f[0] == "#bubble" && f.Count >= 3)
				SetBubblePinned(f[1], f[2], true);
			else if (f[0] == "#view" && f.Count >= 6)
			{
				int n = (int)int32.Parse(f[2]).GetValueOrDefault();
				float zoom = float.Parse(f[5]).GetValueOrDefault();
				bool touched = LayoutTouched; // reading the file is not a change
				if (n >= 1 && n <= 9 && zoom > 0)
					SetView(f[1], n, float.Parse(f[3]).GetValueOrDefault(), float.Parse(f[4]).GetValueOrDefault(), zoom);
				LayoutTouched = touched;
			}
			else if (f[0] == "#reroute" && f.Count >= 7)
			{
				GraphReroute r = new .();
				r.MethodKey.Set(f[1]);
				r.FromNode.Set(f[2]);
				r.FromPin.Set(f[3]);
				r.ToNode.Set(f[4]);
				r.ToPin.Set(f[5]);
				for (let pt in f[6].Split(';'))
				{
					int comma = pt.IndexOf(',');
					if (comma <= 0)
						continue;
					NodePos pos;
					pos.X = float.Parse(pt.Substring(0, comma)).GetValueOrDefault();
					pos.Y = float.Parse(pt.Substring(comma + 1)).GetValueOrDefault();
					r.Points.Add(pos);
				}
				if (r.Points.IsEmpty)
					delete r;
				else
					Reroutes.Add(r);
			}
		}

		OrphanRecord GetOrphanRecord(StringView methodKey, bool create)
		{
			for (let r in OrphanRecords)
				if (r.MethodKey == methodKey)
					return r;
			if (!create)
				return null;
			OrphanRecord r = new .();
			r.MethodKey.Set(methodKey);
			OrphanRecords.Add(r);
			return r;
		}

		/// Parses an `#orphans`, `#orphanpos`, `#orphanlink` or `#orphandefault` line (format: see OrphanCodec).
		void LoadOrphanLine(StringView line)
		{
			var l = line;
			while (l.EndsWith('\r') || l.EndsWith('\n'))
				l.RemoveFromEnd(1);
			List<StringView> f = scope .();
			for (let part in l.Split('\t'))
				f.Add(part);
			if (f.Count < 3 || f[1].IsEmpty)
				return;
			if (f[0] == "#orphans")
			{
				let r = GetOrphanRecord(f[1], true);
				r.Code.Clear();
				LayoutText.Unescape(f[2], r.Code);
			}
			else if (f[0] == "#orphanpos" && f.Count >= 5)
			{
				NodePos pos;
				pos.X = float.Parse(f[3]).GetValueOrDefault();
				pos.Y = float.Parse(f[4]).GetValueOrDefault();
				GetOrphanRecord(f[1], true).SetPosition(f[2], pos);
			}
			else if (f[0] == "#orphanlink" && f.Count >= 8)
			{
				OrphanLinkRec r = new .();
				r.External = f[2] == "graph";
				r.NodeKey.Set(f[3]);
				r.Pin.Set(f[4]);
				r.NodeIsFrom = f[5] == "out";
				r.OtherKey.Set(f[6]);
				r.OtherPin.Set(f[7]);
				if (f.Count >= 9)
					LayoutText.Unescape(f[8], r.Default);
				GetOrphanRecord(f[1], true).Links.Add(r);
			}
			else if (f[0] == "#orphandefault" && f.Count >= 5)
			{
				OrphanLinkRec r = new .();
				r.NodeKey.Set(f[2]);
				r.Pin.Set(f[3]);
				LayoutText.Unescape(f[4], r.Default);
				GetOrphanRecord(f[1], true).Defaults.Add(r);
			}
		}

		/// Saves only the node layout side file; does nothing unless the user touched the layout
		/// (so just viewing a file never creates a `.vblayout`), and never rewrites unchanged
		/// content.
		public void SaveLayout()
		{
			if (!LayoutTouched || FileSafety.ReadOnlyProject)
				return;
			CaptureAllLayouts();
			SaveLayoutFile();
		}

		void SaveLayoutFile(bool pruneMissingMethods = false)
		{
			if (FilePath.IsEmpty || FileSafety.ReadOnlyProject)
				return;
			// A side file written by a newer VisualBeef is left alone.
			if (LayoutFileVersion > LayoutFormatVersion)
				return;
			String layoutPath = scope .();
			GetLayoutPath(FilePath, layoutPath);
			String content = scope .();
			BuildLayoutText(content, pruneMissingMethods);
			if (mLayoutBaseline == null)
			{
				// Nothing on disk yet: a file with no positions at all isn't worth creating.
				if (!HasLayoutPayload(content))
					return;
			}
			else if (content == mLayoutBaseline)
			{
				LayoutTouched = false;
				return;
			}
			String err = scope .();
			if (FileSafety.AtomicWrite(layoutPath, content, false, err) case .Ok)
			{
				delete mLayoutBaseline;
				mLayoutBaseline = new String(content);
				LayoutFileVersion = LayoutFormatVersion;
				LayoutTouched = false;
				LayoutError.Clear();
			}
			else
				LayoutError.Set(err.IsEmpty ? "the file could not be written" : err);
		}

		static bool HasLayoutPayload(StringView content)
		{
			for (let line in content.Split('\n'))
				if (!line.IsEmpty && !line.StartsWith('#'))
					return true;
				else if (line.StartsWith("#comment") || line.StartsWith("#reroute") || line.StartsWith("#bubble") || line.StartsWith("#view") || line.StartsWith("#orphan"))
					return true;
			return false;
		}

		/// The side file content for the current state (what Save / SaveLayout write).
		public void GetLayoutText(String outText)
		{
			CaptureAllLayouts();
			BuildLayoutText(outText);
		}

		/// True when a layout entry should be written: nodes of built methods must still exist;
		/// entries of methods that are gone are dropped only when `pruneMissingMethods`.
		bool KeepLayoutKey(StringView key, HashSet<String> liveKeys, List<String> builtPrefixes, bool pruneMissingMethods)
		{
			for (let prefix in builtPrefixes)
				if (key.StartsWith(prefix))
					return liveKeys.Contains(scope String(key));
			if (!pruneMissingMethods || Methods.IsEmpty)
				return true;
			for (let mg in Methods)
			{
				if (key.Length > mg.Key.Length && key.StartsWith(mg.Key) && key[mg.Key.Length] == '|')
					return true;
			}
			return false;
		}

		void BuildLayoutText(String content, bool pruneMissingMethods = false)
		{
			// Nodes that exist now, per built method (stale entries are not written).
			HashSet<String> liveKeys = scope .();
			List<String> builtPrefixes = scope .();
			defer { for (let k in liveKeys) delete k; ClearAndDeleteItems!(builtPrefixes); }
			for (let mg in Methods)
			{
				if (!mg.IsBuilt)
					continue;
				builtPrefixes.Add(new String()..AppendF("{}|", mg.Key));
				for (let n in mg.Graph.Nodes)
				{
					if (!n.HasPos || n.Key.StartsWith("orphan"))
						continue;
					let lk = new String()..AppendF("{}|", mg.Key);
					LayoutKeys.Compose(n, lk);
					liveKeys.Add(lk);
				}
			}
			List<String> keys = scope .();
			for (let key in Layout.Keys)
				if (KeepLayoutKey(key, liveKeys, builtPrefixes, pruneMissingMethods))
					keys.Add(key);
			keys.Sort(scope (a, b) => String.Compare(a, b, false));
			content.AppendF("#vblayout\t{}\n", LayoutFormatVersion);
			content.Append("# VisualBeef node layout (safe to delete; positions are regenerated, comment boxes and reroutes are lost)\n");
			content.Append("#version\t2\n");
			for (let u in LayoutUnknown)
			{
				content.Append(u);
				content.Append('\n');
			}
			for (let key in keys)
			{
				let pos = Layout[key];
				content.AppendF("{}\t{}\t{}\n", key, (int)pos.X, (int)pos.Y);
			}
			// Comment boxes and reroute knots: layout only, they are not code.
			for (let c in Comments)
			{
				content.AppendF("#comment\t{}\t{}\t{}\t{}\t{}\t", c.MethodKey, (int)c.X, (int)c.Y, (int)c.W, (int)c.H);
				LayoutText.ColorToHex(c.Color, content);
				content.Append('\t');
				LayoutText.Escape(c.Text, content);
				if (c.Pinned)
					content.Append("\t1");
				content.Append('\n');
			}
			for (let b in BubblePins)
				content.AppendF("#bubble\t{}\t{}\n", b.MethodKey, b.NodeKey);
			for (let v in Views)
				content.AppendF("#view\t{}\t{}\t{}\t{}\t{}\n", v.MethodKey, v.N, (int)v.X, (int)v.Y, v.Zoom);
			for (let r in Reroutes)
			{
				if (r.Points.IsEmpty || r.FromNode.IsEmpty || r.ToNode.IsEmpty || r.FromNode.StartsWith("orphan") || r.ToNode.StartsWith("orphan"))
					continue;
				content.AppendF("#reroute\t{}\t{}\t{}\t{}\t{}\t", r.MethodKey, r.FromNode, r.FromPin, r.ToNode, r.ToPin);
				for (let pt in r.Points)
				{
					if (@pt.Index > 0)
						content.Append(';');
					content.AppendF("{},{}", (int)pt.X, (int)pt.Y);
				}
				content.Append('\n');
			}
			AppendOrphanRecords(content);
		}

		/// Unconnected nodes of every method: built graphs are written from their live nodes,
		/// orphans kept aside for unbuilt graphs from their copies, and records read from the
		/// layout file for graphs never built are written back unchanged. A method without
		/// orphans gets no record.
		void AppendOrphanRecords(String content)
		{
			HashSet<String> written = scope .();
			String braceIndent = scope .();
			for (let mg in Methods)
			{
				if (!mg.Graphable || written.Contains(mg.Key))
					continue;
				braceIndent.Clear();
				if (mg.Method.Body.HasSpan)
					Unit.GetLineIndent(mg.Method.Body.FirstTok, braceIndent);
				OrphanRecord rec = null;
				bool owned = true;
				if (mg.IsBuilt)
					rec = OrphanCodec.FromGraph(mg.Graph, braceIndent, IndentUnit, Allman);
				else
				{
					for (let set in Orphans)
					{
						if (set.MethodKey == mg.Key)
						{
							rec = OrphanCodec.FromSet(set, braceIndent, IndentUnit, Allman);
							break;
						}
					}
					if (rec == null)
					{
						rec = GetOrphanRecord(mg.Key, false);
						owned = false;
					}
				}
				if (rec == null)
					continue;
				written.Add(mg.Key);
				rec.Write(content);
				if (owned)
					delete rec;
			}
			// Orphans of methods missing from this parse (e.g. while the file doesn't parse) are kept.
			for (let set in Orphans)
			{
				if (written.Contains(set.MethodKey))
					continue;
				let rec = OrphanCodec.FromSet(set, "", IndentUnit, Allman);
				if (rec == null)
					continue;
				written.Add(set.MethodKey);
				rec.Write(content);
				delete rec;
			}
			for (let rec in OrphanRecords)
			{
				if (written.Contains(rec.MethodKey))
					continue;
				written.Add(rec.MethodKey);
				rec.Write(content);
			}
		}

		void ClearLayout()
		{
			for (let key in Layout.Keys)
				delete key;
			Layout.Clear();
			ClearAndDeleteItems!(Comments);
			ClearAndDeleteItems!(Reroutes);
			ClearAndDeleteItems!(BubblePins);
			ClearAndDeleteItems!(Views);
			ClearAndDeleteItems!(OrphanRecords);
			ClearAndDeleteItems!(LayoutUnknown);
			LayoutFileVersion = 0;
		}

		/// Removes every saved position of one method (keys "methodKey|...").
		void RemoveMethodLayout(StringView methodKey, List<(String key, NodePos pos)> outRemoved = null)
		{
			String prefix = scope $"{methodKey}|";
			List<String> keys = scope .();
			for (let k in Layout.Keys)
				if (k.StartsWith(prefix) && k.IndexOf('|', prefix.Length) < 0)
					keys.Add(k);
			for (let k in keys)
			{
				if (Layout.GetAndRemove(k) case .Ok(let kv))
				{
					if (outRemoved != null)
						outRemoved.Add((kv.key, kv.value));
					else
						delete kv.key;
				}
			}
		}

		void SetLayout(StringView key, NodePos pos)
		{
			String k = scope .(key);
			if (Layout.ContainsKey(k))
			{
				Layout[k] = pos;
				return;
			}
			Layout[new String(key)] = pos;
		}

		// ------------------------------------------------------------------ parsing & graphs

		/// Parses the text and recreates every MethodGraph with no graph built (graphs are built
		/// lazily). Callers that want to keep live graphs go through ReparseKeeping.
		void SetTextInternal(StringView text)
		{
			delete Unit;
			Unit = Parser.Parse(text);
			IndentUnit.Clear();
			CodeStyle.Detect(Unit, IndentUnit, out Allman);
			int crlf = 0;
			int lf = 0;
			for (int i < Unit.Text.Length)
			{
				if (Unit.Text[i] == '\n')
				{
					if (i > 0 && Unit.Text[i - 1] == '\r')
						crlf++;
					else
						lf++;
				}
			}
			CRLF = crlf > lf;
			RebuildGraphs();
			Version++;
		}

		void RebuildGraphs()
		{
			ClearAndDeleteItems!(Methods);
			List<Member> methods = scope .();
			List<Member> owners = scope .();
			Unit.CollectMethods(methods, owners);
			for (int i < methods.Count)
			{
				MethodGraph mg = new .();
				mg.Method = methods[i];
				mg.Owner = owners[i];
				mg.Doc = this;
				GraphBuilder.MakeMethodKey(mg.Method, mg.Owner, mg.Key);
				Methods.Add(mg);
			}
		}

		Graph BuildGraph(MethodGraph mg)
		{
			let graph = GraphBuilder.Build(Unit, mg.Method, mg.Owner);
			KeyAssigner.Assign(graph);
			// Re-attach unconnected nodes kept from the previous version of this graph.
			for (int i = Orphans.Count - 1; i >= 0; i--)
			{
				let orphans = Orphans[i];
				if (orphans.MethodKey == mg.Key)
				{
					orphans.InjectInto(graph);
					Orphans.RemoveAt(i);
					delete orphans;
				}
			}
			// Unconnected nodes saved in the layout file.
			for (int i = OrphanRecords.Count - 1; i >= 0; i--)
			{
				let rec = OrphanRecords[i];
				if (rec.MethodKey != mg.Key)
					continue;
				KeyAssigner.Assign(graph);
				OrphanCodec.Restore(graph, rec, Unit, mg.Method);
				OrphanRecords.RemoveAt(i);
				delete rec;
				// The restored nodes carry their snippet keys; give them orphan keys.
				KeyAssigner.Assign(graph);
			}
			ApplyLayout(graph);
			return graph;
		}

		void ApplyLayout(Graph graph)
		{
			bool anyKnown = false;
			String key = scope .();
			for (let n in graph.Nodes)
				if (n.HasPos)
					anyKnown = true;

			// Match the saved positions of this method to its nodes (see LayoutKeys): same
			// content and path, then moved statements, then edited ones. Whatever matches
			// nothing is pruned; the matched entries are rewritten in the content-keyed form.
			List<(String key, NodePos pos)> removed = scope .();
			defer { for (let r in removed) delete r.key; }
			RemoveMethodLayout(graph.MethodKey, removed);
			if (!removed.IsEmpty)
			{
				List<Node> nodes = scope .();
				for (let n in graph.Nodes)
					if (!n.HasPos && !n.Key.StartsWith("orphan"))
						nodes.Add(n);
				List<StringView> saved = scope .();
				int prefixLen = graph.MethodKey.Length + 1;
				for (let r in removed)
					saved.Add(StringView(r.key, prefixLen));
				List<int> match = scope .();
				LayoutKeys.Reconcile(saved, nodes, match);
				for (int i < removed.Count)
				{
					if (match[i] < 0)
					{
						LayoutPruned++;
						LayoutTouched = true; // the stale entry has to leave the side file
						continue;
					}
					let n = nodes[match[i]];
					LayoutKeys.Split(saved[i], ?, ?, let hasHash);
					if (!hasHash)
					{
						LayoutMigrated++;
						LayoutTouched = true; // rewrite the old positional entry in content-keyed form
					}
					key.Clear();
					key.AppendF("{}|", graph.MethodKey);
					LayoutKeys.Compose(n, key);
					SetLayout(key, removed[i].pos);
					n.X = removed[i].pos.X;
					n.Y = removed[i].pos.Y;
					n.HasPos = true;
					anyKnown = true;
				}
			}
			if (!anyKnown)
				AutoLayout.LayoutAll(graph);
			else
				AutoLayout.PlaceUnpositioned(graph);
		}

		/// Records current node positions under their layout keys (path + content hash). Entries
		/// of this method that no longer belong to any node are dropped.
		public void CaptureLayout(Graph graph)
		{
			KeyAssigner.Assign(graph);
			RemoveMethodLayout(graph.MethodKey);
			String key = scope .();
			for (let n in graph.Nodes)
			{
				if (!n.HasPos || n.Key.StartsWith("orphan"))
					continue;
				key.Clear();
				key.AppendF("{}|", graph.MethodKey);
				LayoutKeys.Compose(n, key);
				NodePos pos;
				pos.X = n.X;
				pos.Y = n.Y;
				SetLayout(key, pos);
			}
			// Reroute knots follow their link by pin id while editing; store the link's current
			// structural keys so they can be found again after a reload.
			for (let r in Reroutes)
			{
				if (r.MethodKey != graph.MethodKey || r.FromPinId == 0 || r.GraphSerial != graph.Serial)
					continue;
				let from = graph.FindPin(r.FromPinId);
				let to = graph.FindPin(r.ToPinId);
				if (from == null || to == null)
					continue;
				r.FromNode.Set(from.Owner.Key);
				r.FromPin.Set(from.Name);
				r.ToNode.Set(to.Owner.Key);
				r.ToPin.Set(to.Name);
			}
		}

		public void CaptureAllLayouts()
		{
			for (let mg in Methods)
				if (mg.IsBuilt)
					CaptureLayout(mg.Graph);
		}

		public MethodGraph FindMethod(StringView methodKey)
		{
			for (let mg in Methods)
				if (mg.Key == methodKey)
					return mg;
			return null;
		}

		// ------------------------------------------------------------------ keeping graphs

		/// Text of a method body from '{' to '}' inclusive (empty when there is none).
		void GetBodyText(Member method, String outText)
		{
			let body = method.Body;
			if (body == null || !body.HasSpan)
				return;
			int last = (body.CloseTok >= 0) ? body.CloseTok : body.LastTok;
			let first = Unit.Tokens[body.FirstTok];
			outText.Append(StringView(Unit.Text, first.Start, Unit.Tokens[last].End - first.Start));
		}

		/// Re-parses `newText` while keeping the built graphs:
		///  - the graph of method `editedIndex` (the one just committed) is kept and refreshed
		///    from the new parse (lines, original text, trivia; see RefreshFromCode);
		///  - every other built graph is kept when its body text is unchanged (lines shifted);
		///  - method `rekeyIndex` was renamed / re-signed: its graph is matched by position and
		///    re-keyed instead of by key.
		///  - method `sameMeaningIndex` is kept when only its context changed (the state fields
		///    its own commit just added).
		/// Graphs that can't be kept are dropped (their unconnected nodes go to Orphans) and get
		/// rebuilt from the text on next use. Indices refer to Methods before the call.
		void ReparseKeeping(StringView newText, int editedIndex = -1, int rekeyIndex = -1, int sameMeaningIndex = -1)
		{
			List<KeptGraph> kept = scope .();
			defer { ClearAndDeleteItems!(kept); }
			for (let mg in Methods)
			{
				if (!mg.IsBuilt)
					continue;
				KeptGraph k = new .();
				k.Key.Set(mg.Key);
				k.Index = @mg.Index;
				GetBodyText(mg.Method, k.Body);
				ContextKey(mg, k.Context);
				k.Graph = mg.DetachGraph();
				kept.Add(k);
			}

			int oldCount = Methods.Count;
			SetTextInternal(newText);
			bool rekeyValid = rekeyIndex >= 0 && rekeyIndex < Methods.Count && Methods.Count == oldCount;

			String body = scope .();
			for (let mg in Methods)
			{
				if (!mg.Graphable)
					continue;
				bool rekey = rekeyValid && @mg.Index == rekeyIndex;
				KeptGraph k = null;
				for (let c in kept)
				{
					if (c.Graph == null)
						continue;
					bool match = rekey ? (c.Index == rekeyIndex) : (c.Key == mg.Key && !(rekeyValid && c.Index == rekeyIndex));
					if (match)
					{
						k = c;
						break;
					}
				}
				if (k == null)
					continue;

				if (k.Index == editedIndex)
				{
					let g = k.Graph;
					k.Graph = null;
					mg.AttachGraph(g);
					if (rekey)
						Rekey(mg, g);
					RefreshFromCode(mg, g);
					continue;
				}

				body.Clear();
				GetBodyText(mg.Method, body);
				if (body != k.Body)
					continue; // the text changed under it: rebuild from code
				// Same body, but what its names mean may have changed (a member variable of the
				// type renamed, deleted or added, a parameter renamed, a function's static-ness).
				// When the graph read from the text now has another shape, the kept one is stale:
				// rebuild, unless it holds edits the text does not have (a refused commit). Same
				// shape: keep the object (open Sheets, selections and node ids stay valid).
				body.Clear();
				ContextKey(mg, body);
				if (body != k.Context && k.Graph.Errors.IsEmpty && k.Index != sameMeaningIndex && !SameShapeAsCode(mg, k.Graph))
					continue;
				let g = k.Graph;
				k.Graph = null;
				mg.AttachGraph(g);
				if (rekey)
					Rekey(mg, g);
				ShiftLines(mg, g);
				// The body is unchanged but the header may not be (a return type typed in the
				// source): the entry's return type and its declaration error follow the text.
				if (g.Entry != null)
				{
					g.Entry.Text2.Set((mg.Method.TypeText != null) ? mg.Method.TypeText : "");
					GraphBuilder.SetEntryDeclError(g.Entry, mg.Method);
				}
				// Not a graph commit (a signature, a type, a text edit elsewhere): types this body
				// reads from the rest of the file may have changed under it.
				if (editedIndex < 0)
					RefreshPinTypes(mg, g);
			}

			// Graphs that could not be kept: hold on to their unconnected nodes.
			for (let k in kept)
			{
				if (k.Graph == null)
					continue;
				KeyAssigner.Assign(k.Graph);
				let set = OrphanSet.Capture(k.Graph);
				if (set == null)
					continue;
				if (rekeyValid && k.Index == rekeyIndex)
					set.MethodKey.Set(Methods[rekeyIndex].Key);
				Orphans.Add(set);
			}
		}

		/// Everything outside the body that GraphBuilder reads to decide what a name is: the
		/// function's parameters and static-ness, and the owner type's member variables,
		/// properties and functions (name, type, static, parameter count).
		void ContextKey(MethodGraph mg, String o)
		{
			let m = mg.Method;
			o.AppendF("{}|", m.IsStatic);
			if (m.Params != null)
				for (let p in m.Params)
					o.AppendF("{} {} {},", p.Modifier, p.Type, p.Name);
			let owner = mg.Owner;
			if (owner == null || owner.Members == null)
				return;
			o.AppendF("|{}|", owner.Name);
			for (let mm in owner.Members)
			{
				switch (mm.Kind)
				{
				case .Field, .Property:
					o.AppendF("{}:{}:{};", mm.Name, mm.TypeText, mm.IsStatic);
				case .Method:
					o.AppendF("{}({}):{};", mm.Name, (mm.Params != null) ? mm.Params.Count : -1, mm.IsStatic);
				default:
				}
			}
		}

		/// The nodes read from code (Line > 0) of `g` have the kinds and texts a fresh read of the
		/// function gives (the entry follows the header through Rekey / ShiftLines).
		bool SameShapeAsCode(MethodGraph mg, Graph g)
		{
			let fresh = GraphBuilder.Build(Unit, mg.Method, mg.Owner);
			defer delete fresh;
			List<String> a = scope .();
			List<String> b = scope .();
			defer { ClearAndDeleteItems!(a); ClearAndDeleteItems!(b); }
			for (let n in g.Nodes)
				if (n.Line > 0 && n.Kind != .Entry)
					a.Add(new $"{(int)n.Kind}:{n.Text}");
			for (let n in fresh.Nodes)
				if (n.Line > 0 && n.Kind != .Entry)
					b.Add(new $"{(int)n.Kind}:{n.Text}");
			if (a.Count != b.Count)
				return false;
			// Order-free: a graph edited and committed earlier lists its nodes in another order.
			a.Sort(scope (x, y) => String.Compare(x, y, false));
			b.Sort(scope (x, y) => String.Compare(x, y, false));
			for (int i < a.Count)
				if (a[i] != b[i])
					return false;
			return true;
		}

		/// A kept graph whose body text is unchanged: only line numbers move.
		void ShiftLines(MethodGraph mg, Graph g)
		{
			let m = mg.Method;
			let entry = g.Entry;
			if (entry == null || !m.HasSpan)
				return;
			int32 entryLine = Unit.LineOf(Unit.Tokens[m.FirstTok].Start);
			int32 bodyLine = (m.Body != null && m.Body.HasSpan) ? Unit.LineOf(Unit.Tokens[m.Body.FirstTok].Start) : entryLine;
			int32 delta = bodyLine - entry.LineEnd;
			if (delta != 0)
			{
				for (let n in g.Nodes)
				{
					if (n == entry || n.Line <= 0)
						continue;
					n.Line += delta;
					n.LineEnd += delta;
				}
			}
			entry.Line = entryLine;
			entry.LineEnd = bodyLine;
		}

		/// Updates a kept graph after its method was renamed or its signature changed.
		void Rekey(MethodGraph mg, Graph g)
		{
			let m = mg.Method;
			g.MethodKey.Set(mg.Key);
			g.MethodName.Set(m.Name);
			let entry = g.Entry;
			if (entry == null)
				return;
			entry.Text.Set(m.Name);
			entry.Text2.Set((m.TypeText != null) ? m.TypeText : "");
			GraphBuilder.SetEntryDeclError(entry, m);
			int count = (m.Params != null) ? m.Params.Count : 0;
			String pinName = scope .();
			for (int i < count)
			{
				let param = m.Params[i];
				pinName.Clear();
				pinName.AppendF("param{}", i);
				var pin = entry.FindOutput(pinName);
				if (pin == null)
					pin = g.AddDataOut(entry, pinName, param.Name);
				else if (pin.Label != param.Name)
				{
					// Nodes reading the parameter through this pin write its name.
					for (let l in g.Links)
						if (l.From == pin)
							l.To.Owner.Edited = true;
					pin.Label.Set(param.Name);
				}
				pin.TypeName.Set(param.Type);
			}
			for (int i = entry.Outputs.Count - 1; i >= 0; i--)
			{
				let p = entry.Outputs[i];
				if (p.Kind == .Data && p.Name.StartsWith("param") && (int.Parse(StringView(p.Name, 5)) case .Ok(let idx)) && idx >= count)
					g.RemovePin(p);
			}
			for (let n in g.Nodes)
			{
				if (n.Kind != .Return)
					continue;
				let v = n.FindInput("value");
				if (v != null)
					v.TypeName.Set((m.TypeText != null) ? m.TypeText : "");
			}
			g.Version++;
		}

		static int OrdinalCompare(StringView a, StringView b)
		{
			int n = Math.Min(a.Length, b.Length);
			for (int i < n)
			{
				if (a[i] != b[i])
					return (int)(uint8)a[i] - (int)(uint8)b[i];
			}
			return a.Length - b.Length;
		}

		/// Everything about a node that determines its code, except its trivia. Data inputs are
		/// described by their source's key, exec outputs by their target's key.
		static void LocalSignature(Node n, Dictionary<Pin, Link> linkTo, Dictionary<Pin, Link> linkFrom, String o)
		{
			o.Clear();
			o.AppendF("{}|{}|{}|{}{}{}{}", (int)n.Kind, n.Text, n.Text2, n.NullCond ? 1 : 0, n.Cascade ? 1 : 0, n.Postfix ? 1 : 0, n.IsPure ? 1 : 0);
			if (n.Alloc != null || n.IsArray)
				o.AppendF("|alloc={}{}", n.Alloc, n.IsArray ? "[]" : "");
			if (n.Attributes != null)
				o.AppendF("|attr={}", n.Attributes);
			for (let p in n.Inputs)
			{
				o.Append('|');
				o.Append(p.Name);
				if (p.Kind == .Exec)
				{
					o.Append(":x");
					continue;
				}
				if (linkTo.TryGetValue(p, let l))
					o.AppendF("<{}.{}", l.From.Owner.Key, l.From.Name);
				else
					o.AppendF("={}", p.Default);
			}
			for (let p in n.Outputs)
			{
				o.Append('|');
				o.Append(p.Name);
				if (p.Kind == .Exec)
				{
					o.Append('>');
					if (linkFrom.TryGetValue(p, let l))
						o.Append(l.To.Owner.Key);
				}
			}
		}

		static void IndexLinks(Graph g, Dictionary<Pin, Link> linkTo, Dictionary<Pin, Link> execFrom)
		{
			for (let l in g.Links)
			{
				linkTo[l.To] = l;
				if (l.From.Kind == .Exec)
					execFrom[l.From] = l;
			}
		}

		/// After a commit, the edited graph stays as it is (no node changes kind or pins), and
		/// the parse of the code just written refreshes what depends on the text: every node gets
		/// the source lines of the code at its structural key (for mapping compiler errors), and
		/// a node whose code reads back identically - itself plus everything its text covers
		/// (data inputs, nested bodies) - takes the new original text and trivia and is clean
		/// again. Any other node stays marked edited, so stale original text is never reused.
		void RefreshFromCode(MethodGraph mg, Graph kept)
		{
			let fresh = GraphBuilder.Build(Unit, mg.Method, mg.Owner);
			defer delete fresh;
			KeyAssigner.Assign(fresh);
			KeyAssigner.Assign(kept);

			kept.MethodKey.Set(mg.Key);
			Graph.CopyStr(ref kept.EndComments, fresh.EndComments);
			Graph.CopyStr(ref kept.RawOpenTrail, fresh.RawOpenTrail);
			Graph.CopyStr(ref kept.RawCloseLead, fresh.RawCloseLead);
			kept.CloseAtLineStart = fresh.CloseAtLineStart;

			Dictionary<StringView, Node> freshByKey = scope .();
			Dictionary<StringView, Node> keptByKey = scope .();
			for (let n in fresh.Nodes)
				if (!n.Key.StartsWith("orphan"))
					freshByKey.TryAdd(n.Key, n);
			for (let n in kept.Nodes)
				if (!n.Key.StartsWith("orphan"))
					keptByKey.TryAdd(n.Key, n);

			Dictionary<Pin, Link> keptTo = scope .();
			Dictionary<Pin, Link> keptFrom = scope .();
			Dictionary<Pin, Link> freshTo = scope .();
			Dictionary<Pin, Link> freshFrom = scope .();
			IndexLinks(kept, keptTo, keptFrom);
			IndexLinks(fresh, freshTo, freshFrom);

			// Keys whose node differs between the live graph and the code (or exists in one only).
			List<StringView> keys = scope .();
			HashSet<StringView> bad = scope .();
			String sa = scope .();
			String sb = scope .();
			for (let kv in keptByKey)
			{
				keys.Add(kv.key);
				if (!freshByKey.TryGetValue(kv.key, let f))
				{
					bad.Add(kv.key);
					continue;
				}
				LocalSignature(kv.value, keptTo, keptFrom, sa);
				LocalSignature(f, freshTo, freshFrom, sb);
				if (sa != sb)
					bad.Add(kv.key);
			}
			for (let kv in freshByKey)
			{
				if (!keptByKey.ContainsKey(kv.key))
				{
					keys.Add(kv.key);
					bad.Add(kv.key);
				}
			}
			keys.Sort(scope (a, b) => OrdinalCompare(a, b));
			Dictionary<StringView, int> keyIndex = scope .();
			for (let k in keys)
				keyIndex.TryAdd(k, @k.Index);

			String prefix = scope .();
			for (let n in kept.Nodes)
			{
				Node f = null;
				if (!n.Key.StartsWith("orphan"))
					freshByKey.TryGetValue(n.Key, out f);
				if (f == null)
				{
					// Not part of the code (unconnected) or nothing at its place in the code.
					n.Line = 0;
					n.LineEnd = 0;
					if (n != kept.Entry)
						n.Edited = true;
					continue;
				}
				n.Line = f.Line;
				n.LineEnd = f.LineEnd;

				// Same code: this key and every key below it ("s2/true/s0", "s2/condition"...)
				// match. Keys sharing a prefix are contiguous in sorted order.
				bool same = !bad.Contains(n.Key);
				if (same)
				{
					prefix.Set(n.Key);
					prefix.Append('/');
					for (int j = keyIndex[n.Key] + 1; j < keys.Count && keys[j].StartsWith(prefix); j++)
					{
						if (bad.Contains(keys[j]))
						{
							same = false;
							break;
						}
					}
				}
				if (!same)
				{
					if (n != kept.Entry)
						n.Edited = true;
					continue;
				}

				CopyPinTypes(n, f);
				Graph.CopyStr(ref n.Original, f.Original);
				Graph.CopyStr(ref n.LeadingComments, f.LeadingComments);
				Graph.CopyStr(ref n.TrailingComment, f.TrailingComment);
				Graph.CopyStr(ref n.RawLead, f.RawLead);
				Graph.CopyStr(ref n.RawTrail, f.RawTrail);
				n.Edited = false;
				n.Moved = false;
				for (let p in n.Inputs)
				{
					let fp = f.FindInput(p.Name);
					if (fp != null)
						p.Parens = fp.Parens;
				}
				for (let p in n.Outputs)
				{
					let fp = f.FindOutput(p.Name);
					if (fp != null)
					{
						Graph.CopyStr(ref p.EndComments, fp.EndComments);
						Graph.CopyStr(ref p.RawLead, fp.RawLead);
						Graph.CopyStr(ref p.RawTail, fp.RawTail);
					}
				}
			}
			kept.Version++;
		}

		/// Pin types are worked out when a graph is built (a local's declared or inferred type,
		/// a construct's result, a call's return type, a read of a local). A kept graph does not
		/// go through the builder again, so after a commit or an edit elsewhere in the file the
		/// pins of a node that the new text confirms take the types the text now gives them.
		/// Pins unified with a wire (WildcardType) and types the builder can't work out (empty)
		/// keep what they have. Returns true when a type changed.
		static bool CopyPinTypes(Node n, Node f)
		{
			bool changed = false;
			for (int side < 2)
			{
				for (let p in (side == 0) ? n.Inputs : n.Outputs)
				{
					if (p.Kind != .Data || p.WildcardType != null)
						continue;
					let fp = (side == 0) ? f.FindInput(p.Name) : f.FindOutput(p.Name);
					if (fp == null || fp.TypeName.IsEmpty || fp.TypeName == p.TypeName)
						continue;
					p.TypeName.Set(fp.TypeName);
					changed = true;
				}
			}
			return changed;
		}

		/// A kept graph whose body text is unchanged while something it depends on changed (a
		/// signature in the same file: a call's return type, a parameter type): the pin types of
		/// the nodes the text still confirms follow the new parse. Nodes are matched by key and
		/// by what they say (LocalSignature), so an edited node in the graph is left alone.
		void RefreshPinTypes(MethodGraph mg, Graph kept)
		{
			let fresh = GraphBuilder.Build(Unit, mg.Method, mg.Owner);
			defer delete fresh;
			KeyAssigner.Assign(fresh);
			KeyAssigner.Assign(kept);
			Dictionary<StringView, Node> freshByKey = scope .();
			for (let n in fresh.Nodes)
				if (!n.Key.StartsWith("orphan"))
					freshByKey.TryAdd(n.Key, n);
			Dictionary<Pin, Link> keptTo = scope .();
			Dictionary<Pin, Link> keptFrom = scope .();
			Dictionary<Pin, Link> freshTo = scope .();
			Dictionary<Pin, Link> freshFrom = scope .();
			IndexLinks(kept, keptTo, keptFrom);
			IndexLinks(fresh, freshTo, freshFrom);
			String sa = scope .();
			String sb = scope .();
			bool changed = false;
			for (let n in kept.Nodes)
			{
				if (n.Key.StartsWith("orphan"))
					continue;
				if (!freshByKey.TryGetValue(n.Key, let f))
					continue;
				LocalSignature(n, keptTo, keptFrom, sa);
				LocalSignature(f, freshTo, freshFrom, sb);
				if (sa == sb && CopyPinTypes(n, f))
					changed = true;
			}
			if (changed)
				kept.Version++;
		}

		// ------------------------------------------------------------------ reload (safety valve)

		/// "Reload Node": the node takes its pins' types, its unreadable-code message and its
		/// bookkeeping from the document as it is now. Only for a node the document still holds
		/// as it is (same place, same content); returns false otherwise (an unconnected node, or
		/// one with changes not written yet), and then Reload Sheet is the way. Not an undo step:
		/// nothing the document says changes.
		public bool ReloadNode(MethodGraph mg, Node n)
		{
			if (mg == null || n == null || !mg.Graphable || !mg.IsBuilt)
				return false;
			let kept = mg.Graph;
			if (kept.ReadOnly || n.Key.StartsWith("orphan"))
				return false;
			let fresh = GraphBuilder.Build(Unit, mg.Method, mg.Owner);
			defer delete fresh;
			KeyAssigner.Assign(fresh);
			KeyAssigner.Assign(kept);
			Node f = null;
			for (let c in fresh.Nodes)
			{
				if (c.Key == n.Key)
				{
					f = c;
					break;
				}
			}
			if (f == null)
				return false;
			Dictionary<Pin, Link> keptTo = scope .();
			Dictionary<Pin, Link> keptFrom = scope .();
			Dictionary<Pin, Link> freshTo = scope .();
			Dictionary<Pin, Link> freshFrom = scope .();
			IndexLinks(kept, keptTo, keptFrom);
			IndexLinks(fresh, freshTo, freshFrom);
			String sa = scope .();
			String sb = scope .();
			LocalSignature(n, keptTo, keptFrom, sa);
			LocalSignature(f, freshTo, freshFrom, sb);
			if (sa != sb)
				return false;
			// Every pin type, including the ones unified with a wire: the document's word wins.
			for (int side < 2)
			{
				for (let p in (side == 0) ? n.Inputs : n.Outputs)
				{
					if (p.Kind != .Data)
						continue;
					let fp = (side == 0) ? f.FindInput(p.Name) : f.FindOutput(p.Name);
					if (fp == null)
						continue;
					DeleteAndNullify!(p.WildcardType);
					p.TypeName.Set(fp.TypeName);
				}
			}
			Graph.CopyStr(ref n.Error, f.Error);
			Graph.CopyStr(ref n.Original, f.Original);
			n.Line = f.Line;
			n.LineEnd = f.LineEnd;
			n.Edited = false;
			for (int i = kept.Errors.Count - 1; i >= 0; i--)
				if (kept.Errors[i].NodeId == n.Id)
				{
					delete kept.Errors[i];
					kept.Errors.RemoveAt(i);
				}
			for (int i = kept.Warnings.Count - 1; i >= 0; i--)
				if (kept.Warnings[i].NodeId == n.Id)
				{
					delete kept.Warnings[i];
					kept.Warnings.RemoveAt(i);
				}
			kept.Version++;
			return true;
		}

		/// "Reload Sheet": throws the live graph of a function away and builds it again from the
		/// document (positions kept, unconnected nodes carried over like after an outside edit).
		/// An undo step. The graph is a new object: views must not hold its nodes across the call.
		public void ReloadGraph(MethodGraph mg)
		{
			if (mg == null || !mg.Graphable || !mg.IsBuilt)
				return;
			PushUndo();
			let old = mg.DetachGraph();
			CaptureLayout(old);
			KeyAssigner.Assign(old);
			let set = OrphanSet.Capture(old);
			if (set != null)
				Orphans.Add(set);
			delete old;
			mg.AttachGraph(BuildGraph(mg));
		}

		// ------------------------------------------------------------------ undo

		Snapshot MakeSnapshot()
		{
			Snapshot s = new .();
			s.Text.Set(Unit.Text);
			for (let kv in Layout)
				s.Layout[new String(kv.key)] = kv.value;
			for (let c in Comments)
				s.Comments.Add(c.Clone());
			for (let r in Reroutes)
				s.Reroutes.Add(r.Clone());
			// Exact copies of the live graphs: undo/redo brings back these very nodes rather
			// than whatever the text would build.
			for (let mg in Methods)
			{
				if (!mg.IsBuilt)
					continue;
				let g = mg.Graph.Clone();
				g.MethodKey.Set(mg.Key);
				s.Graphs.Add(g);
			}
			for (let pending in Orphans)
				s.Orphans.Add(pending.Clone());
			for (let rec in OrphanRecords)
				s.OrphanRecords.Add(rec.Clone());
			return s;
		}

		/// Restores text, layout and graphs. Takes the graphs out of `s`.
		void RestoreSnapshot(Snapshot s)
		{
			// The sidecar's version and the lines this version does not know describe the file
			// on disk, not an undo state: keep them (a newer sidecar must not be overwritten).
			int fileVersion = LayoutFileVersion;
			List<String> unknown = scope .();
			unknown.AddRange(LayoutUnknown);
			LayoutUnknown.Clear();
			List<BubblePin> pins = scope .();
			pins.AddRange(BubblePins);
			BubblePins.Clear();
			List<SavedView> views = scope .();
			views.AddRange(Views);
			Views.Clear();
			ClearLayout();
			BubblePins.AddRange(pins);
			Views.AddRange(views);
			LayoutFileVersion = fileVersion;
			LayoutUnknown.AddRange(unknown);
			for (let kv in s.Layout)
				Layout[new String(kv.key)] = kv.value;
			for (let c in s.Comments)
				Comments.Add(c.Clone());
			for (let r in s.Reroutes)
				Reroutes.Add(r.Clone());
			ClearAndDeleteItems!(Orphans);
			for (let o in s.Orphans)
				Orphans.Add(o.Clone());
			for (let rec in s.OrphanRecords)
				OrphanRecords.Add(rec.Clone());
			SetTextInternal(s.Text);
			for (let g in s.Graphs)
			{
				MethodGraph target = null;
				for (let mg in Methods)
				{
					if (!mg.IsBuilt && mg.Key == g.MethodKey)
					{
						target = mg;
						break;
					}
				}
				if (target != null)
				{
					g.Version++;
					target.AttachGraph(g);
				}
				else
					delete g;
			}
			s.Graphs.Clear();
			LayoutTouched = true;
			RefreshModified();
		}

		public void PushUndo()
		{
			LayoutTouched = true;
			CaptureAllLayouts();
			mUndo.Add(MakeSnapshot());
			if (mUndo.Count > MaxUndo)
			{
				delete mUndo[0];
				mUndo.RemoveAt(0);
			}
			ClearAndDeleteItems!(mRedo);
		}

		public bool CanUndo => !mUndo.IsEmpty;
		public bool CanRedo => !mRedo.IsEmpty;

		public void Undo()
		{
			if (mUndo.IsEmpty)
				return;
			CaptureAllLayouts();
			mRedo.Add(MakeSnapshot());
			let s = mUndo.PopBack();
			RestoreSnapshot(s);
			delete s;
		}

		public void Redo()
		{
			if (mRedo.IsEmpty)
				return;
			CaptureAllLayouts();
			mUndo.Add(MakeSnapshot());
			let s = mRedo.PopBack();
			RestoreSnapshot(s);
			delete s;
		}

		/// The text was just (re)read from disk: it is now the saved state.
		public void MarkSavedFromDisk(StringView diskText)
		{
			SavedText.Set(diskText);
			DiskHash = FileSafety.Hash(diskText);
			DiskLen = diskText.Length;
			HasDiskStamp = true;
			RefreshModified();
		}

		void ClearHistory()
		{
			ClearAndDeleteItems!(mUndo);
			ClearAndDeleteItems!(mRedo);
		}

		// ------------------------------------------------------------------ edits

		/// Replaces the whole source text (text editor -> graph direction).
		public void ApplyText(StringView newText)
		{
			if (newText == Unit.Text)
				return;
			PushUndo();
			CaptureAllLayouts();
			// Methods whose body text changed are rebuilt from the text; the others keep their
			// graphs.
			ReparseKeeping(newText);
			RefreshModified();
		}

		/// Generates the method body text for a graph (without applying it). Returns false when
		/// the generator refused the graph: the reasons are in mg.Graph.Errors (per node).
		public bool GenerateMethodBody(MethodGraph mg, String outBody, List<String> outWarnings = null, List<String> outNewFields = null)
		{
			let body = mg.Method.Body;
			String braceIndent = scope .();
			Unit.GetLineIndent(body.FirstTok, braceIndent);
			mg.Graph.DeclModifiers.Set(mg.Method.Modifiers);
			mg.Graph.InLibrary = mg.Owner != null && mg.Owner.IsNodeLibrary;
			CodeGen gen = scope .(mg.Graph, IndentUnit, Allman);
			gen.SetFileStyle(Unit);
			HashSet<String> ownerFields = scope .();
			defer { for (let f in ownerFields) delete f; }
			GetFieldNames(mg.Owner, ownerFields);
			gen.SetOwnerFields(ownerFields);
			gen.GenerateBody(braceIndent, outBody);
			FixLineEndings(outBody);
			if (outWarnings != null)
				for (let w in gen.Warnings)
					outWarnings.Add(new String(w));
			if (outNewFields != null)
			{
				// Alternating name, type for the state fields flow macros need.
				for (let f in gen.FieldNeeds)
				{
					if (ownerFields.ContainsAlt(StringView(f.Name)))
						continue;
					outNewFields.Add(new String(f.Name));
					outNewFields.Add(new String(f.Type));
				}
			}
			return !gen.HasErrors;
		}

		/// Names of the fields declared directly in a type (new strings; the caller deletes them).
		public static void GetFieldNames(Member type, HashSet<String> outNames)
		{
			if (type == null || type.Members == null)
				return;
			for (let m in type.Members)
				if ((m.Kind == .Field || m.Kind == .Property) && !m.Name.IsEmpty && !outNames.ContainsAlt(StringView(m.Name)))
					outNames.Add(new String(m.Name));
		}

		/// Field names of the type that owns a method, for choosing free macro state names.
		public void GetOwnerFieldNames(MethodGraph mg, HashSet<String> outNames)
		{
			GetFieldNames(mg.Owner, outNames);
		}

		/// Adds the state fields flow macros need (`private [static] bool __doOnce_1;`) to the
		/// type that owns the method. `fields` alternates name, type.
		void AddMacroFields(StringView methodKey, bool isStatic, List<String> fields)
		{
			let mg = FindMethod(methodKey);
			if (mg == null || mg.Owner == null || mg.Owner.CloseBrace < 0)
				return;
			let type = mg.Owner;
			HashSet<String> have = scope .();
			defer { for (let f in have) delete f; }
			GetFieldNames(type, have);
			String indent = scope .();
			MemberIndent(type, indent);
			String text = scope .();
			for (int i = 0; i + 1 < fields.Count; i += 2)
			{
				if (have.ContainsAlt(StringView(fields[i])))
					continue;
				text.AppendF("{}private {}{} {};\n", indent, isStatic ? "static " : "", fields[i + 1], fields[i]);
			}
			if (text.IsEmpty)
				return;
			int insertAt = -1;
			if (type.Members != null)
			{
				for (let m in type.Members)
					if (m.Kind == .Field)
						insertAt = Unit.Tokens[m.LastTok].TrailEnd;
			}
			if (insertAt < 0)
				insertAt = Unit.Tokens[type.OpenBrace].TrailEnd;
			if (insertAt > 0 && Unit.Text[insertAt - 1] != '\n')
				text.Insert(0, "\n");
			// The graph that asked for the fields was just committed and must stay the same object.
			ReplaceRange(insertAt, insertAt, text, -1, Methods.IndexOf(mg));
		}

		///Writes a graph back into the source (graph -> text direction). Call after any graph
		/// edit; the caller should have called PushUndo() before editing.
		///
		/// The edited graph object and every other built graph stay live: afterwards
		/// FindMethod(key).Graph returns the same Graph with the same nodes (ids, kinds, pins,
		/// links, orphans). The MethodGraph objects themselves are recreated (they point into the
		/// new parse), so look them up again by key; `mg` must not be used after this call.
		///
		/// A graph the generator cannot express safely is not written: Commit returns false, the
		/// text stays as it was, the graph keeps its edits, and the reasons are on the nodes
		/// (Graph.Errors) and in Messages.
		public bool Commit(MethodGraph mg)
		{
			let body = mg.Method.Body;
			if (body == null)
				return false;
			ClearAndDeleteItems!(Messages);
			String newBody = scope .();
			List<String> newFields = scope .();
			defer { ClearAndDeleteItems!(newFields); }
			if (!GenerateMethodBody(mg, newBody, Messages, newFields))
			{
				for (let e in mg.Graph.Errors)
				{
					let node = mg.Graph.FindNode(e.NodeId);
					String title = scope .();
					node?.GetTitle(title);
					Messages.Insert(@e.Index, new String(scope $"Not written - {title}: {e.Message}"));
				}
				return false;
			}

			let open = Unit.Tokens[body.FirstTok];
			let close = Unit.Tokens[body.CloseTok];
			String newText = scope .();
			newText.Append(StringView(Unit.Text, 0, open.End));
			newText.Append(newBody);
			newText.Append(StringView(Unit.Text, close.Start));

			bool changed = newText != Unit.Text;
			String methodKey = scope .(mg.Key);
			bool isStatic = mg.Method.IsStatic;
			// Static calls placed from the Node menu name their type by its simple name
			// (`File.ReadAllText`): the file gets the `using` that type needs (System.IO), in the
			// same undo step. Calls read from the code are left as written.
			String qualifiers = scope .();
			String ownerName = scope .();
			if (changed)
			{
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .Call && n.Original == null && !String.IsNullOrEmpty(n.Qualifier) && !n.Qualifier.Contains('.'))
						qualifiers.AppendF("{} ", n.Qualifier);
				if (mg.Owner != null)
					ownerName.Set(mg.Owner.Name);
			}
			CaptureAllLayouts();
			ReparseKeeping(newText, Methods.IndexOf(mg));
			if (changed)
				RefreshModified();
			if (!newFields.IsEmpty)
				AddMacroFields(methodKey, isStatic, newFields);
			if (!qualifiers.IsEmpty)
				AddUsingsFor(qualifiers, ownerName);
			return true;
		}

		/// Converts generated text to the file's line-ending convention.
		public void FixLineEndings(String text)
		{
			text.Replace("\r\n", "\n");
			if (CRLF)
				text.Replace("\n", "\r\n");
		}

		/// Generic text splice used by class-level operations. Graphs of methods whose body text
		/// is unchanged are kept; `rekeyIndex` names a method whose name or signature changed.
		void ReplaceRange(int start, int end, StringView replacement, int rekeyIndex = -1, int sameMeaningIndex = -1)
		{
			String fixedText = scope .(replacement);
			FixLineEndings(fixedText);
			String newText = scope .();
			newText.Append(StringView(Unit.Text, 0, start));
			newText.Append(fixedText);
			newText.Append(StringView(Unit.Text, end));
			CaptureAllLayouts();
			ReparseKeeping(newText, -1, rekeyIndex, sameMeaningIndex);
			RefreshModified();
		}

		void MemberIndent(Member type, String outIndent)
		{
			// Use the indentation of the first member, or the type's indentation + one unit.
			if (type.Members != null)
			{
				for (let m in type.Members)
				{
					if (m.HasSpan)
					{
						Unit.GetLineIndent(m.FirstTok, outIndent);
						return;
					}
				}
			}
			Unit.GetLineIndent(type.FirstTok, outIndent);
			outIndent.Append(IndentUnit);
		}

		/// The namespaces a type text names that this file cannot see yet: `List<int>` in a file
		/// with only `using System;` needs `System.Collections`. Each word is looked up as the
		/// file sees it (its usings, its namespace); a word found only in a namespace the file does
		/// not use adds that namespace. Qualified words (`System.Collections.List`) need nothing.
		public void MissingUsingsFor(StringView typeText, Member owner, List<String> outNamespaces)
		{
			let svc = TypeService.Current;
			if (svc == null || Unit == null)
				return;
			let ctx = ResolveContext.Make(Unit, owner);
			defer delete ctx;
			int i = 0;
			while (i < typeText.Length)
			{
				let c = typeText[i];
				if (!c.IsLetter && c != '_')
				{
					i++;
					continue;
				}
				int start = i;
				while (i < typeText.Length && (typeText[i].IsLetterOrDigit || typeText[i] == '_'))
					i++;
				let word = StringView(typeText, start, i - start);
				// Part of a qualified name (`A.B`): written in full, nothing to add.
				if ((start > 0 && typeText[start - 1] == '.') || (i < typeText.Length && typeText[i] == '.'))
					continue;
				if (TypeRules.PrimitiveStruct(word) != word || word == "out" || word == "ref" || word == "in" || word == "params" || word == "var" || word == "let" || word == "mut")
					continue;
				let h = svc.FindType(word, ctx);
				if (!h.IsValid)
					continue;
				let ns = h.Store.Str(h.Rec.Namespace);
				let outer = h.Store.Str(h.Rec.Outer);
				if (ns.IsEmpty || !outer.IsEmpty || ns == ctx.Namespace)
					continue;
				if (ctx.Namespace.StartsWith(ns) && ctx.Namespace.Length > ns.Length && ctx.Namespace[ns.Length] == '.')
					continue;
				if (ctx.Usings.ContainsAlt(ns) || outNamespaces.ContainsAlt(ns))
					continue;
				outNamespaces.Add(new String(ns));
			}
		}

		/// Writes `using N;` for every namespace MissingUsingsFor finds (part of the caller's undo
		/// step: no PushUndo here), after the file's last top-level `using`, or at the top.
		public void AddUsingsFor(StringView typeText, StringView typeName)
		{
			if (Unit == null)
				return;
			Member owner = null;
			List<Member> types = scope .();
			Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == typeName)
					owner = t;
			List<String> missing = scope .();
			defer { ClearAndDeleteItems!(missing); }
			MissingUsingsFor(typeText, owner, missing);
			if (missing.IsEmpty)
				return;
			int insertAt = 0;
			for (let m in Unit.Members)
				if (m.Kind == .Using && m.LastTok >= 0)
					insertAt = Unit.Tokens[m.LastTok].TrailEnd;
			String text = scope .();
			if (insertAt > 0 && Unit.Text[insertAt - 1] != '\n')
				text.Append('\n');
			for (let ns in missing)
				text.AppendF("using {};\n", ns);
			if (insertAt == 0)
				text.Append('\n');
			ReplaceRange(insertAt, insertAt, text);
		}

		/// Adds an empty method to a type. Returns the new method's key.
		public bool AddMethod(Member type, StringView returnType, StringView name, StringView paramsText, String outMethodKey)
		{
			if (type.CloseBrace < 0)
				return false;
			if (RefuseType(returnType, .Return, type, "Return Type") || RefuseParams(paramsText, type))
				return false;
			PushUndo();
			// `type` belongs to the current parse and is freed by ReplaceRange; keep its name.
			String typeName = scope .(type.Name);
			String indent = scope .();
			MemberIndent(type, indent);
			String text = scope .();
			let closeTok = Unit.Tokens[type.CloseBrace];
			// Insert before the closing brace's leading trivia so the brace keeps its indentation.
			bool needsBlank = type.Members != null && !type.Members.IsEmpty;
			if (needsBlank)
				text.Append("\n");
			if (type.TypeKind == "interface")
			{
				// An interface lists what an implementing type must provide: a declaration with no
				// body (a body would be a default implementation, and no class would be asked for
				// it). Interface members are public without saying so.
				text.AppendF("{}{} {}({});\n", indent, returnType, name, paramsText);
			}
			else
			{
				text.AppendF("{}public {}{} {}({})", indent, type.IsNodeLibrary ? "static " : "", returnType, name, paramsText);
				if (Allman)
					text.AppendF("\n{0}{{\n{0}}}\n", indent);
				else
					text.AppendF(" {{\n{0}}}\n", indent);
			}
			int insertAt = closeTok.LeadStart;
			// Keep the newline that ends the previous line.
			if (insertAt > 0 && Unit.Text[insertAt - 1] != '\n')
				text.Insert(0, "\n");
			ReplaceRange(insertAt, insertAt, text);
			AddUsingsFor(scope $"{returnType} ({paramsText})", typeName);
			outMethodKey.Clear();
			for (let mg in Methods)
			{
				if (mg.Owner != null && mg.Owner.Name == typeName && mg.Method.Name == name)
				{
					outMethodKey.Set(mg.Key);
					break;
				}
			}
			return true;
		}

		/// Adds a field to a type.
		public bool AddField(Member type, StringView fieldType, StringView name, StringView initializer = "", bool isStatic = false)
		{
			String tail = scope .();
			if (!initializer.IsEmpty)
				tail.AppendF(" = {}", initializer);
			return AddFieldWithTail(type, fieldType, name, tail, isStatic);
		}

		/// Adds a member variable with its Ownership / Initial value (`= new .() ~ delete _`).
		public bool AddField(Member type, StringView fieldType, StringView name, MemberInit init, bool isStatic = false)
		{
			String tail = scope .();
			init.Emit(tail);
			return AddFieldWithTail(type, fieldType, name, tail, isStatic);
		}

		bool AddFieldWithTail(Member type, StringView fieldType, StringView name, StringView tail, bool isStaticIn = false)
		{
			if (type.CloseBrace < 0)
				return false;
			if (RefuseType(fieldType, .Member, type, "Variable Type"))
				return false;
			PushUndo();
			String indent = scope .();
			MemberIndent(type, indent);
			String text = scope .();
			text.AppendF("{}public {}{} {}", indent, (isStaticIn || type.IsNodeLibrary) ? "static " : "", fieldType, name);
			text.Append(tail);
			text.Append(";\n");

			// Insert after the last field, or at the top of the type body.
			int insertAt = -1;
			if (type.Members != null)
			{
				for (let m in type.Members)
					if (m.Kind == .Field)
						insertAt = Unit.Tokens[m.LastTok].TrailEnd;
			}
			if (insertAt < 0)
				insertAt = Unit.Tokens[type.OpenBrace].TrailEnd;
			if (insertAt > 0 && Unit.Text[insertAt - 1] != '\n')
				text.Insert(0, "\n");
			String typeName = scope .(type.Name);
			ReplaceRange(insertAt, insertAt, text);
			AddUsingsFor(fieldType, typeName);
			return true;
		}

		/// Renames a method or field declaration (references are not updated).
		public void RenameMember(Member member, StringView newName)
		{
			if (member.NameTok < 0 || member.IsCtor || member.IsDtor)
				return;
			PushUndo();
			let tok = Unit.Tokens[member.NameTok];
			String oldKey = scope .();
			int index = -1;
			for (let mg in Methods)
			{
				if (mg.Method == member)
				{
					oldKey.Set(mg.Key);
					index = @mg.Index;
					break;
				}
			}
			// The method's graph (if built) is kept and re-keyed; layout entries move with it.
			ReplaceRange(tok.Start, tok.End, newName, index);
			if (index >= 0 && index < Methods.Count && Methods[index].Method.Name == newName)
				RemapMethodKey(oldKey, Methods[index].Key);
		}

		/// Rewrites a method's return type and parameter list.
		public bool SetSignature(Member method, StringView returnType, StringView paramsText)
		{
			if (method.ParamsOpenTok < 0)
				return false;
			if ((!method.IsCtor && !method.IsDtor && !method.IsMixin && !returnType.IsEmpty && RefuseType(returnType, .Return, method, "Return Type")) || RefuseParams(paramsText, method))
				return false;
			if (method.IsDtor && !paramsText.IsEmpty)
				return Refuse("A destructor has no parameters.");
			if (method.IsCtor && !method.IsStatic)
			{
				Member sigOwner = null;
				for (let mg in Methods)
					if (mg.Method == method)
						sigOwner = mg.Owner;
				if (sigOwner != null)
				{
					String sk = scope .();
					ParamTypesKey(paramsText, sk);
					let other = FindConstructor(sigOwner, sk, method);
					if (other != null)
					{
						String types = scope .();
						CtorTypesText(other, types);
						return Refuse(scope $"{sigOwner.Name} already has a constructor with these parameters: Constructor ({types}).");
					}
				}
			}
			PushUndo();
			String oldKey = scope .();
			int index = -1;
			for (let mg in Methods)
			{
				if (mg.Method == method)
				{
					oldKey.Set(mg.Key);
					index = @mg.Index;
				}
			}
			let name = scope String(method.Name);

			// Parameters first (later in the text), then return type.
			let open = Unit.Tokens[method.ParamsOpenTok];
			let close = Unit.Tokens[method.ParamsCloseTok];
			String newText = scope .();
			newText.Append(StringView(Unit.Text, 0, open.End));
			newText.Append(paramsText);
			newText.Append(StringView(Unit.Text, close.Start));

			// Return type: the text between modifiers and the name.
			if (!method.IsCtor && !method.IsDtor && !method.IsMixin && method.TypeText != null && !method.TypeText.IsEmpty)
			{
				let nameTok = Unit.Tokens[method.NameTok];
				// Find the return type's span by searching backwards from the name for TypeText.
				int typeEnd = nameTok.Start;
				while (typeEnd > 0 && CharUtil.IsSpace(Unit.Text[typeEnd - 1]))
					typeEnd--;
				int typeStart = typeEnd - method.TypeText.Length;
				if (typeStart >= 0 && StringView(Unit.Text, typeStart, method.TypeText.Length) == method.TypeText)
				{
					newText.Remove(typeStart, method.TypeText.Length);
					newText.Insert(typeStart, returnType);
				}
			}

			CaptureAllLayouts();
			ReparseKeeping(newText, -1, index);
			RefreshModified();

			if (index >= 0 && index < Methods.Count && Methods[index].Method.Name == name && Methods[index].Key != oldKey)
				RemapMethodKey(oldKey, Methods[index].Key);
			return true;
		}

		/// Moves layout entries and pending orphans (live copies and saved records) from one method key to another.
		void RemapMethodKey(StringView oldMethodKey, StringView newMethodKey)
		{
			if (oldMethodKey == newMethodKey)
				return;
			RemapLayout(oldMethodKey, newMethodKey);
			for (let o in Orphans)
				if (o.MethodKey == oldMethodKey)
					o.MethodKey.Set(newMethodKey);
			for (let rec in OrphanRecords)
				if (rec.MethodKey == oldMethodKey)
					rec.MethodKey.Set(newMethodKey);
		}

		void RemapLayout(StringView oldMethodKey, StringView newMethodKey)
		{
			List<String> keys = scope .();
			for (let k in Layout.Keys)
				if (k.StartsWith(oldMethodKey) && k.Length > oldMethodKey.Length && k[oldMethodKey.Length] == '|')
					keys.Add(k);
			for (let k in keys)
			{
				let pos = Layout[k];
				String newKey = new .();
				newKey.Append(newMethodKey);
				newKey.Append(StringView(k, oldMethodKey.Length));
				Layout.Remove(k);
				delete k;
				if (Layout.ContainsKey(newKey))
					delete newKey;
				else
					Layout[newKey] = pos;
			}
			for (let c in Comments)
				if (c.MethodKey == oldMethodKey)
					c.MethodKey.Set(newMethodKey);
			for (let r in Reroutes)
				if (r.MethodKey == oldMethodKey)
					r.MethodKey.Set(newMethodKey);
			for (let b in BubblePins)
				if (b.MethodKey == oldMethodKey)
					b.MethodKey.Set(newMethodKey);
			for (let v in Views)
				if (v.MethodKey == oldMethodKey)
					v.MethodKey.Set(newMethodKey);
		}

		/// Deletes a member declaration (including its leading comments).
		public void DeleteMember(Member member)
		{
			if (!member.HasSpan)
				return;
			// A variable the create constructor sets leaves the constructor with it.
			String createType = scope .();
			List<String> createNames = scope .();
			defer { ClearAndDeleteItems!(createNames); }
			bool marked = CreateNamesBefore(member, createType, createNames);
			if (marked)
			{
				for (int i < createNames.Count)
					if (createNames[i] == member.Name)
					{
						delete createNames[i];
						createNames.RemoveAt(i);
						break;
					}
			}
			PushUndo();
			String key = scope .();
			for (let mg in Methods)
				if (mg.Method == member)
					key.Set(mg.Key);
			let first = Unit.Tokens[member.FirstTok];
			let last = Unit.Tokens[member.LastTok];
			ReplaceRange(first.LeadStart, last.TrailEnd, "");
			if (marked)
				RewriteCreate(createType, createNames); // none left: the constructor and its marker go
			// Unconnected nodes of a deleted method go with it (undo brings them back).
			if (!key.IsEmpty && FindMethod(key) == null)
			{
				for (int i = OrphanRecords.Count - 1; i >= 0; i--)
				{
					if (OrphanRecords[i].MethodKey == key)
					{
						delete OrphanRecords[i];
						OrphanRecords.RemoveAt(i);
					}
				}
				for (int i = Orphans.Count - 1; i >= 0; i--)
				{
					if (Orphans[i].MethodKey == key)
					{
						delete Orphans[i];
						Orphans.RemoveAt(i);
					}
				}
			}
		}

		// ------------------------------------------------------------------ asset edits (Project Browser)

		/// Renames a type declaration (references are not updated). Layout and pending orphans of
		/// the type's methods follow the methods' new keys ("Old.Update()" -> "New.Update()").
		public void RenameType(Member type, StringView newName)
		{
			if (type == null || type.Kind != .Type || type.NameTok < 0 || type.Name == newName)
				return;
			PushUndo();
			List<int> indices = scope .();
			List<String> oldKeys = scope .();
			defer { ClearAndDeleteItems!(oldKeys); }
			for (let mg in Methods)
			{
				if (mg.Owner == type)
				{
					indices.Add(@mg.Index);
					oldKeys.Add(new String(mg.Key));
				}
			}
			int oldCount = Methods.Count;
			let tok = Unit.Tokens[type.NameTok];
			ReplaceRange(tok.Start, tok.End, newName);
			if (Methods.Count != oldCount)
				return;
			for (int i < indices.Count)
				RemapMethodKey(oldKeys[i], Methods[indices[i]].Key);
		}

		/// Changes the declared type of a field or property ("int" -> "float").
		public bool SetMemberType(Member member, StringView newType)
		{
			if (member == null || (member.Kind != .Field && member.Kind != .Property) || member.NameTok < 0 ||
				member.TypeText == null || member.TypeText.IsEmpty || newType.IsEmpty)
				return false;
			if (RefuseType(newType, .Member, member, "Variable Type"))
				return false;
			let nameTok = Unit.Tokens[member.NameTok];
			int typeEnd = nameTok.Start;
			while (typeEnd > 0 && CharUtil.IsSpace(Unit.Text[typeEnd - 1]))
				typeEnd--;
			int typeStart = typeEnd - member.TypeText.Length;
			if (typeStart < 0 || StringView(Unit.Text, typeStart, member.TypeText.Length) != member.TypeText)
				return false;
			if (member.TypeText == newType)
				return true;
			// A variable the create constructor sets: its parameter follows the new type.
			String createType = scope .();
			List<String> createNames = scope .();
			defer { ClearAndDeleteItems!(createNames); }
			bool marked = CreateNamesBefore(member, createType, createNames);
			PushUndo();
			ReplaceRange(typeStart, typeEnd, newType);
			if (marked)
				RewriteCreate(createType, createNames);
			return true;
		}

		/// Rewrites the case list of a simple enum (see EnumCases). Everything outside the case
		/// list - the declaration, members after a `;`, the rest of the file - is preserved.
		public bool SetEnumCases(Member type, List<EnumCase> cases)
		{
			let region = EnumCases.GetRegion(Unit, type);
			if (!region.Valid)
				return false;
			String typeIndent = scope .();
			Unit.GetLineIndent(type.OpenBrace, typeIndent);
			String caseIndent = scope .(typeIndent);
			caseIndent.Append(IndentUnit.IsEmpty ? "\t" : IndentUnit);
			bool semi = region.SemiTok >= 0;
			int end;
			String closeIndent = scope .();
			if (semi)
				end = Unit.Tokens[region.SemiTok].TrailEnd;
			else
			{
				end = region.End;
				Unit.GetLineIndent(type.CloseBrace, closeIndent);
			}
			String text = scope .();
			EnumCases.Generate(cases, caseIndent, closeIndent, semi, text);
			if (StringView(Unit.Text, region.Start, end - region.Start) == text)
				return true;
			PushUndo();
			ReplaceRange(region.Start, end, text);
			return true;
		}
	}
}
