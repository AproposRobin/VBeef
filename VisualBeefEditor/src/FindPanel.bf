using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// One "Find in Sheets" result.
	class FindHit
	{
		public enum HitKind { Type, Function, Variable, Node, Reference, Maybe }
		public HitKind Kind;
		public String Path = new .() ~ delete _;
		public String TypeName = new .() ~ delete _;
		public String Method = new .() ~ delete _;
		public String Text = new .() ~ delete _;
		public int32 Line;
	}

	/// UE's Find in Sheets: project-wide search over type, function and variable names and
	/// over every statement inside function graphs (node titles, pin values, literals). Results
	/// are grouped by file and class; clicking one opens the graph with that node selected.
	extension EditorApp
	{
		TextBuffer mFindAllBuf = new .(256) ~ delete _;
		String mFindAllQuery = new .() ~ delete _;
		List<FindHit> mFindHits = new .() ~ DeleteContainerAndItems!(_);
		double mFindTypedTime;
		bool mFindFocusInput;
		bool mFindFocusWindow;
		bool mFindTruncated;
		int mFindFiles;
		const int cMaxFindHits = 2000;
		/// The panel lists the references of one symbol (Find References) instead of a search.
		String mRefsTitle = new .() ~ delete _;

		/// Find References (Shift+F12): every place in the project that uses the symbol under the
		/// cursor (the selected node, or the variable / type selected in the Outline), with the
		/// rename resolution (docs/Editor-UI.md). Libraries are not searched.
		public void FindReferencesOfSelection()
		{
			RenameTarget t = scope .();
			String what = scope .();
			if (!SymbolUnderCursor(t, what))
			{
				SetStatus("Find References: select a node, a variable or a type first", .Warning);
				return;
			}
			FindReferences(t, what);
		}

		public void FindReferences(RenameTarget t, StringView what)
		{
			List<RenameService.Source> sources = scope .();
			List<String> texts = scope .();
			defer { ClearAndDeleteItems!(texts); }
			CollectProjectSources(sources, texts);
			RenamePlan plan = scope .();
			RenameService.FindReferences(t, sources, TypeService.Current, plan);
			ClearAndDeleteItems!(mFindHits);
			mFindTruncated = false;
			mFindFiles = plan.Files.Count;
			mFindAllBuf.Set("");
			mFindAllQuery.Clear();
			for (let f in plan.Files)
			{
				for (let e in f.Edits)
				{
					// The whole line holding the reference.
					int s = e.Start;
					while (s > 0 && f.Text[s - 1] != '\n')
						s--;
					int end = e.Start;
					while (end < f.Text.Length && f.Text[end] != '\n' && f.Text[end] != '\r')
						end++;
					var line = StringView(f.Text, s, end - s);
					line.Trim();
					AddHit(.Reference, f.Path, "", "", line, e.Line);
				}
			}
			for (let p in plan.Problems)
				AddHit(.Maybe, "", "", "", p, 0);
			mRefsTitle.Clear();
			if (!plan.Refusal.IsEmpty)
				mRefsTitle.AppendF("References to {}: {}", what, plan.Refusal);
			else
				mRefsTitle.AppendF("References to {}: {} in {} file{}{}", what, plan.Count, plan.Files.Count, (plan.Files.Count == 1) ? "" : "s",
					plan.Problems.IsEmpty ? "" : scope:: $", {plan.Problems.Count} that may be it");
			ShowFindResults = true;
			mFindFocusWindow = true;
			Notify.Log(.Info, "Find", mRefsTitle);
		}

		/// The symbol the user points at, as a rename target (kind, name, declaring type, method).
		bool SymbolUnderCursor(RenameTarget t, String what)
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			if (tab != null && mg != null && tab.SelectedNodes.Count == 1)
			{
				let g = mg.Graph;
				let n = g.FindNode(tab.SelectedNodes[0]);
				if (n != null)
				{
					t.FilePath.Set(mg.Doc.FilePath);
					t.MethodKey.Set(mg.Key);
					StringView ownerName = (mg.Owner != null) ? (StringView)mg.Owner.Name : "";
					// A name read or written without a receiver: a parameter, a local, or a member.
					bool ByName(StringView chain)
					{
						var root = chain;
						int dot = root.IndexOf('.');
						if (dot > 0)
							root = root.Substring(0, dot);
						root.Trim();
						if (root.IsEmpty || root == "this" || root == "base")
							return false;
						t.OldName.Set(root);
						for (let p in mg.Method.Params)
						{
							if (p.Name == root)
							{
								t.Kind = .Parameter;
								t.TypeName.Set(ownerName);
								what.AppendF("parameter {}", root);
								return true;
							}
						}
						for (let o in g.Nodes)
						{
							if ((o.Kind == .LocalVar || o.Kind == .ForEach || o.Kind == .Using) && o.Text == root)
							{
								t.Kind = .Local;
								t.TypeName.Set(ownerName);
								what.AppendF("local {}", root);
								return true;
							}
						}
						t.Kind = .Member;
						t.TypeName.Set(ownerName);
						what.AppendF("{}.{}", ownerName, root);
						return true;
					}
					void MemberOf(StringView typeText, StringView name)
					{
						t.Kind = .Member;
						t.OldName.Set(name);
						String bare = scope .(typeText);
						bare.Replace("*", "");
						int lt = bare.IndexOf('<');
						if (lt > 0)
							bare.RemoveToEnd(lt);
						bare.Trim();
						t.TypeName.Set(bare.IsEmpty ? ownerName : bare);
						what.AppendF("{}.{}", t.TypeName, name);
					}
					switch (n.Kind)
					{
					case .Get:
						let target = n.FindInput("target");
						if (target == null)
							return ByName(n.Text);
						let src = g.DataSource(target);
						MemberOf((src != null && src.Result != null) ? (StringView)src.Result.TypeName : (StringView)target.TypeName, n.Text);
						return true;
					case .Set:
						let target = n.FindInput("target");
						if (target != null && g.DataSource(target) == null)
							return ByName(target.Default);
					case .Call:
						var name = StringView(n.Text);
						if (name.EndsWith('!'))
							return false; // a mixin
						MemberOf((n.OwnerType != null) ? (StringView)n.OwnerType : ownerName, name);
						return true;
					case .Construct:
						if (n.Text == "." || n.Text == "$")
							return false;
						t.Kind = .Type;
						String bare = scope .(n.Text);
						int lt = bare.IndexOf('<');
						if (lt > 0)
							bare.RemoveToEnd(lt);
						t.OldName.Set(bare);
						what.AppendF("type {}", bare);
						return true;
					case .LocalVar, .ForEach, .Using:
						if (n.Text.IsEmpty)
							return false;
						t.Kind = .Local;
						t.OldName.Set(n.Text);
						t.TypeName.Set(ownerName);
						what.AppendF("local {}", n.Text);
						return true;
					case .Entry:
						MemberOf(ownerName, mg.Method.Name);
						return true;
					default:
					}
				}
			}
			if (mSelVarActive && !mSelVarName.IsEmpty)
			{
				t.Kind = .Member;
				t.OldName.Set(mSelVarName);
				t.TypeName.Set(mSelVarType);
				what.AppendF("{}.{}", mSelVarType, mSelVarName);
				return true;
			}
			if (mSelClassActive && !mSelClassName.IsEmpty)
			{
				t.Kind = .Type;
				t.OldName.Set(mSelClassName);
				what.AppendF("type {}", mSelClassName);
				return true;
			}
			return false;
		}

		public void OpenFindResults()
		{
			ShowFindResults = true;
			mFindFocusInput = true;
			mFindFocusWindow = true;
			// Seed with the selected node's title or the word under the Ctrl+F box, like UE.
			if (mFindAllBuf.View.IsEmpty && CurrentTab != null && CurrentMethod != null && CurrentTab.SelectedNodes.Count == 1)
			{
				let n = CurrentMethod.Graph.FindNode(CurrentTab.SelectedNodes[0]);
				if (n != null && (n.Kind == .Call || n.Kind == .Get || n.Kind == .Set))
				{
					String t = scope .();
					if (n.Kind == .Set)
					{
						let target = n.FindInput("target");
						if (target != null)
							t.Set(target.Default);
					}
					else
						t.Set(n.Text);
					mFindAllBuf.Set(t);
				}
			}
		}

		static bool MatchesAll(StringView hay, StringView query)
		{
			for (let word in query.Split(' '))
				if (!word.IsEmpty && hay.IndexOf(word, true) < 0)
					return false;
			return true;
		}

		void RunFind(StringView queryIn)
		{
			mRefsTitle.Clear();
			ClearAndDeleteItems!(mFindHits);
			mFindTruncated = false;
			mFindFiles = 0;
			String query = scope .(queryIn);
			query.Trim();
			mFindAllQuery.Set(query);
			if (query.Length < 2)
				return;
			String text = scope .();
			for (let file in Index.Files)
			{
				bool fileHit = false;
				// Symbols first (types, functions, variables).
				for (let t in file.Types)
				{
					if (MatchesAll(t.Name, query))
						AddHit(.Type, file.Path, t.Name, "", scope $"{t.Kind} {t.Name}", t.Line);
					for (let m in t.Methods)
						if (MatchesAll(m.Name, query))
							AddHit(.Function, file.Path, t.Name, m.Name, scope $"{m.Name}({m.ParamsText})", m.Line);
					for (let f in t.Fields)
						if (MatchesAll(f.Name, query))
							AddHit(.Variable, file.Path, t.Name, "", scope $"{f.Name} : {f.Type}", 0);
				}
				// Statements inside function bodies (live text for open files).
				text.Clear();
				let doc = FindDoc(file.Path);
				if (doc != null)
					text.Set(doc.Text);
				else if (File.ReadAllText(file.Path, text) case .Err)
					continue;
				int32 lineNo = 0;
				for (let lineRaw in text.Split('\n'))
				{
					lineNo++;
					var line = lineRaw;
					line.Trim();
					if (line.IsEmpty || line.StartsWith("//") || line.StartsWith("using ") || !MatchesAll(line, query))
						continue;
					// The function this line belongs to (closest declaration above it).
					SymbolType owner = null;
					SymbolMethod best = null;
					bool isDecl = false;
					for (let t in file.Types)
						for (let m in t.Methods)
						{
							if (m.Line == lineNo)
								isDecl = true; // a declaration line: already listed as a function
							if (m.HasBody && m.Line < lineNo && (best == null || m.Line > best.Line))
							{
								best = m;
								owner = t;
							}
						}
					if (best == null || isDecl)
						continue;
					AddHit(.Node, file.Path, owner.Name, best.Name, line, lineNo);
					fileHit = true;
					if (mFindHits.Count >= cMaxFindHits)
						break;
				}
				if (fileHit)
					mFindFiles++;
				if (mFindHits.Count >= cMaxFindHits)
				{
					mFindTruncated = true;
					break;
				}
			}
			Notify.Log(.Verbose, "Find", scope $"Find in Sheets \"{query}\": {mFindHits.Count} result(s)");
		}

		void AddHit(FindHit.HitKind kind, StringView path, StringView typeName, StringView method, StringView text, int32 line)
		{
			FindHit h = new .();
			h.Kind = kind;
			h.Path.Set(path);
			h.TypeName.Set(typeName);
			h.Method.Set(method);
			h.Text.Set(text);
			if (h.Text.Length > 160)
			{
				h.Text.RemoveToEnd(157);
				h.Text.Append("...");
			}
			h.Line = line;
			mFindHits.Add(h);
		}

		void ActivateHit(FindHit h)
		{
			String path = scope .(h.Path);
			String typeName = scope .(h.TypeName);
			String method = scope .(h.Method);
			int32 line = h.Line;
			switch (h.Kind)
			{
			case .Node, .Reference:
				JumpToLine(path, line);
			case .Maybe:
			case .Function:
				if (!OpenFunction(path, typeName, method, line))
					SetStatus(scope $"{method} has no graph (no body)");
			case .Type:
				let doc = OpenFile(path, true);
				if (doc != null)
					OpenTypeEditor(path, typeName);
			case .Variable:
				if (OpenFile(path, false) != null)
				{
					// Show it in Properties, like clicking it in Outline.
					mSelVarType.Set(typeName);
					String name = scope .(h.Text);
					int colon = name.IndexOf(" : ");
					if (colon > 0)
						name.RemoveToEnd(colon);
					mSelVarName.Set(name);
					mSelVarActive = true;
					mSelLocalActive = false;
					mSelVarSigPending = true;
					Panels.Focus(Panels.PropertiesId);
				}
			}
		}

		static StringView HitIcon(FindHit.HitKind k)
		{
			switch (k)
			{
			case .Type: return Icon.Class;
			case .Function: return Icon.Function;
			case .Variable: return Icon.Variable;
			case .Node: return Icon.Box;
			case .Reference: return Icon.ArrowRight;
			case .Maybe: return Icon.Warning;
			}
		}

		static uint32 HitColor(FindHit.HitKind k)
		{
			switch (k)
			{
			case .Type: return AssetStyle.KindColor(.Class);
			case .Function: return Gui.Color(90, 150, 230);
			case .Variable: return Gui.Color(120, 200, 120);
			case .Node, .Reference: return Look.Foreground;
			case .Maybe: return Theme.Warning;
			}
		}

		void DrawFindResults()
		{
			if (!ShowFindResults)
				return;
			if (mFindFocusWindow)
			{
				mFindFocusWindow = false;
				Gui.igSetNextWindowFocus();
			}
			if (Gui.Begin(Panels.FindResults, &ShowFindResults))
			{
				if (mFindFocusInput)
				{
					Gui.igSetKeyboardFocusHere(0);
					mFindFocusInput = false;
				}
				Gui.igSetNextItemWidth(-1);
				bool enter = Gui.igInputTextWithHint("##findall", scope $"{Icon.Search}  Find in Sheets: functions, variables, nodes, pin values...", mFindAllBuf.Ptr, (.)mFindAllBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				if (Gui.igIsItemEdited())
					mFindTypedTime = Desktop.Now;
				var q = mFindAllBuf.View;
				q.Trim();
				// Search as you type (after a short pause) or on Enter.
				if (enter || (q != mFindAllQuery && Desktop.Now - mFindTypedTime > 0.25))
					RunFind(q);

				if (!mRefsTitle.IsEmpty)
					Gui.TextColored(Look.AccentBlue, mRefsTitle);
				else if (mFindAllQuery.Length >= 2)
				{
					Gui.TextDisabled(scope $"{mFindHits.Count}{mFindTruncated ? "+" : ""} result{(mFindHits.Count == 1) ? "" : "s"} for \"{mFindAllQuery}\"");
				}
				else
					Gui.TextDisabled("Type at least 2 characters. Words are matched in any order, case-insensitive.");

				Gui.igPushStyleColor_U32(Col.ChildBg, Look.Recessed);
				if (Gui.igBeginChild_Str("##findres", .(0, 0), ChildFlags.Borders, 0))
				{
					FindHit activate = null;
					int i = 0;
					while (i < mFindHits.Count)
					{
						// One tree node per file, then per class.
						let first = mFindHits[i];
						int end = i;
						while (end < mFindHits.Count && mFindHits[end].Path == first.Path)
							end++;
						String fileName = scope .();
						Path.GetFileName(first.Path, fileName);
						Gui.PushID((int32)i);
						bool open = Gui.TreeNode(scope $"{Icon.FileCode}  {fileName}  ({end - i})###f", TreeNodeFlags.DefaultOpen | TreeNodeFlags.SpanAvailWidth);
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip(first.Path);
						if (open)
						{
							for (int j = i; j < end; j++)
							{
								let h = mFindHits[j];
								Gui.PushID((int32)j);
								String label = scope .();
								label.AppendF("{}  ", HitIcon(h.Kind));
								if (h.Kind == .Node)
									label.AppendF("{}.{}:  {}", h.TypeName, h.Method, h.Text);
								else if (h.Kind == .Reference)
									label.AppendF("{}:  {}", h.Line, h.Text);
								else if (h.Kind == .Maybe)
									label.AppendF("maybe: {}", h.Text);
								else if (h.Kind == .Type)
									label.Append(h.Text);
								else
									label.AppendF("{}.{}", h.TypeName, h.Text);
								Gui.igPushStyleColor_U32(Col.Text, HitColor(h.Kind));
								if (Gui.Selectable(label, false, SelectableFlags.AllowDoubleClick))
									activate = h;
								Gui.igPopStyleColor(1);
								if (Gui.igIsItemHovered(0) && h.Line > 0)
									Gui.Tooltip(scope $"{h.Path}:{h.Line}\nClick to open");
								Gui.PopID();
							}
							Gui.TreePop();
						}
						Gui.PopID();
						i = end;
					}
					if (activate != null)
						ActivateHit(activate);
				}
				Gui.igEndChild();
				Gui.igPopStyleColor(1);
			}
			Gui.End();
		}
	}
}
