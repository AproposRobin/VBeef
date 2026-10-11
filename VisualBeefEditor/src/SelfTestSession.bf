using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// The end-to-end self test (`VB_SELFTEST=session`): the user path through the same calls the
	/// UI makes, on a scratch project with a `GameBase` class (a virtual `Tick(float)`) and an `Other`
	/// class: a new class `Greeter : GameBase` from the Project Browser, a member, functions, nodes
	/// placed from the Node menu (a call with its Receiver left as `this`, a Value call, a Branch, a
	/// Return, the print call), the Tick override from the Override list, Save, Compile (the
	/// indicator green / yellow / red), undo / redo, delete, the Receiver error and a compile error
	/// on a node (then that node deleted and a new one placed: the error stays with the deleted node),
	/// a close / reopen of the file, and a Local whose Construct type and Variable Type change. `reload-check` is the second run (a new process):
	/// the file opens unchanged, its graphs build, and the indicator is green.
	///
	/// Captures (docs/Testing.md > Verifying the UI): `shot:<name>` logs `[SELFTEST] shot <name>` and
	/// waits until `<VB_SHOTS>\<name>.done` exists (an outside script takes the picture), at most
	/// 20 s; without `VB_SHOTS` it does nothing. `size:WxH` does the same for a window resize.
	extension EditorApp
	{
		int mSessionStep;
		String mSessionLibPath = new .() ~ delete _;
		int mSessionLibDepth;
		bool mSessionLibSel;
		String mSessionLibFn = new .() ~ delete _;
		ImVec2 mNavSavedCenter;
		int32 mNavSavedLevel;
		int mNavRebuilds;
		int mSessionWait;
		double mShotStart = -1;
		String mSessionPath = new .() ~ delete _;
		String mSessionSaved = new .() ~ delete _;
		String mSessionHello = new .() ~ delete _;
		String mSessionTick = new .() ~ delete _;
		String mSessionReady = new .() ~ delete _;
		Dictionary<String, (float x, float y)> mSessionPositions = new .() ~ { for (let k in _.Keys) delete k; delete _; };

		/// Waits for an outside capture: true when it is done (or was skipped / timed out).
		bool SelfTestShot(StringView name)
		{
			String dir = scope .();
			if (Environment.GetEnvironmentVariable("VB_SHOTS", dir) case .Err || dir.IsEmpty)
				return true;
			let marker = scope $"{dir}{Path.DirectorySeparatorChar}{name}.done";
			let now = Desktop.Now;
			if (mShotStart < 0)
			{
				if (File.Exists(marker))
					File.Delete(marker).IgnoreError();
				mShotStart = now;
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] shot {name}");
				return false;
			}
			if (File.Exists(marker))
			{
				mShotStart = -1;
				return true;
			}
			if (now - mShotStart > 20)
			{
				mShotStart = -1;
				SelfTestCheck(false, scope $"shot {name}: no capture within 20 s");
				return true;
			}
			return false;
		}

		SourceDocument SessionDoc => FindDoc(mSessionPath);

		MethodGraph SessionMethod(StringView key)
		{
			let doc = SessionDoc;
			return (doc != null) ? doc.FindMethod(key) : null;
		}

		/// Opens the tab of a function and returns its graph.
		MethodGraph SessionOpen(StringView key)
		{
			let mg = SessionMethod(key);
			if (mg != null)
				OpenTab(mg);
			return CurrentMethod;
		}

		Node FindNodeOf(Graph g, NodeKind kind, StringView text = "")
		{
			for (let n in g.Nodes)
				if (n.Kind == kind && (text.IsEmpty || n.Text == text))
					return n;
			return null;
		}

		/// The Node menu at `pin` (0: empty canvas): picks the first item whose label starts with
		/// `label`, exactly like a click on it. False when it is not offered.
		bool SessionPick(Pin pin, StringView label, float x, float y)
		{
			let tab = CurrentTab;
			if (tab == null)
				return false;
			OpenNodeMenu(tab, .(x, y), (pin != null) ? pin.Id : 0);
			mNodeMenu.OpenRequested = false; // no popup: the pick below is what its click does
			NodeItem found = null;
			NodeItem switchOn = (label.StartsWith("Switch on ")) ? mNodeMenu.MakeSwitchOn() : null;
			defer { delete switchOn; }
			if (switchOn != null && switchOn.Label.StartsWith(label))
				found = switchOn;
			for (let it in mNodeMenu.Items)
				if (it.Label.StartsWith(label))
				{
					found = it;
					break;
				}
			if (found == null)
			{
				SelfTestCheck(false, scope $"session: the Node menu offers no '{label}'");
				return false;
			}
			NodeItem copy = scope .();
			copy.CopyFrom(found);
			ExecuteAction(copy);
			return true;
		}

		/// What the Properties panel does when a pin value is typed.
		void SessionSetPin(Node n, Pin p, StringView value)
		{
			BeginEdit();
			p.Default.Set(value);
			n.Edited = true;
			CommitCurrent();
		}

		static Pin FirstValueInput(Node n)
		{
			for (let p in n.Inputs)
				if (p.Kind == .Data && p.Name != "target")
					return p;
			return null;
		}

		CompileState SessionState => GetCompileState();

		/// Ctrl+Z / Ctrl+Y on the class file (what HandleShortcuts does).
		bool SessionUndo(bool redo)
		{
			let doc = SessionDoc;
			if (doc == null || (redo ? !doc.CanRedo : !doc.CanUndo))
				return false;
			if (!GroupUndo(doc, redo))
			{
				if (redo)
					doc.Redo();
				else
					doc.Undo();
			}
			UpdateTitle();
			return true;
		}

		bool SessionBuildRunning => mBuild != null && mBuild.Running;

		/// One action per frame; returns true when the whole session is finished.
		bool SelfTestSession()
		{
			if (mSessionWait > 0)
			{
				mSessionWait--;
				return false;
			}
			let step = mSessionStep++;
			switch (step)
			{
			case 0:
				String src = scope .();
				src.AppendF("{}{}src", mProjectRoot, Path.DirectorySeparatorChar);
				ResetCreateTypeOptions();
				mCBNewParent.Set("GameBase");
				mCBNewImplement = false;
				CreateAsset(.Class, src, "Greeter");
				mSessionPath.Clear();
				mSessionPath.AppendF("{}{}Greeter.bf", src, Path.DirectorySeparatorChar);
				let doc = OpenFile(mSessionPath, false);
				SelfTestCheck(doc != null && File.Exists(mSessionPath) && doc.Text.Contains("class Greeter : GameBase"),
					"session 1 new class: Project Browser > New Class 'Greeter' derived from GameBase wrote Greeter.bf");
				if (doc == null)
					return true;
			case 1:
				let doc = SessionDoc;
				let type = FindTypeIn(doc, "Greeter");
				doc.AddField(type, "int", "mCount", "1");
				let type2 = FindTypeIn(doc, "Greeter");
				doc.AddField(type2, "Other", "mOther", "null");
				SelfTestCheck(doc.Text.Contains("int mCount = 1;") && doc.Text.Contains("Other mOther = null;"), "session 2 members: VARIABLES + added mCount and mOther");
			case 2:
				let doc = SessionDoc;
				doc.AddMethod(FindTypeIn(doc, "Greeter"), "bool", "IsReady", "", mSessionReady);
				doc.AddMethod(FindTypeIn(doc, "Greeter"), "void", "Ping", "", scope String());
				doc.AddMethod(FindTypeIn(doc, "Greeter"), "void", "Hello", "", mSessionHello);
				let mg = SessionOpen(mSessionReady);
				SelfTestCheck(mg != null && SessionMethod(mSessionHello) != null && doc.Text.Contains("void Ping()"),
					scope $"session 3 functions: FUNCTIONS + added IsReady, Ping, Hello ({mSessionReady}, {mSessionHello})");
				if (mg == null)
					return true;
			case 3:
				let mg = SessionOpen(mSessionReady);
				SessionPick(mg.Graph.Entry.Then, "Return", 320, 0);
			case 4:
				let mg = SessionOpen(mSessionReady);
				let ret = FindNodeOf(mg.Graph, .Return);
				if (ret == null)
				{
					SelfTestCheck(false, "session 4 Return: the pick placed no Return");
					return true;
				}
				SessionSetPin(ret, ret.FindInput("value"), "mCount > 0");
			case 5:
				let doc = SessionDoc;
				SelfTestCheck(doc.Text.Contains("return mCount > 0;"), "session 4 Return: Node menu > Return wired to the entry, value typed: `return mCount > 0;`");
				let mg = SessionOpen(mSessionHello);
				SessionPick(mg.Graph.Entry.Then, "Print", 320, 0);
			case 6:
				let mg = SessionOpen(mSessionHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				if (print == null)
				{
					SelfTestCheck(false, "session 5 print: no WriteLine node");
					return true;
				}
				SessionSetPin(print, FirstValueInput(print), "\"Hello\"");
			case 7:
				let mg = SessionOpen(mSessionHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SelfTestCheck(print != null && SessionDoc.Text.Contains("Console.WriteLine(\"Hello\");"), "session 5 call: Print placed from the Node menu, wired, string typed");
				SessionPick(print.Then, "Branch", 640, 0);
			case 8:
				let mg = SessionOpen(mSessionHello);
				let br = FindNodeOf(mg.Graph, .Branch);
				if (br == null)
				{
					SelfTestCheck(false, "session 6 flow node: no Branch");
					return true;
				}
				SessionPick(br.FindInput("condition"), "IsReady(", 640, 200);
			case 9:
				let mg = SessionOpen(mSessionHello);
				let call = FindNodeOf(mg.Graph, .Call, "IsReady");
				SelfTestCheck(call != null && call.IsPure && SessionDoc.Text.Contains("if (IsReady())"),
					"session 6 Value call + flow node: Branch, IsReady() as a Value call into its Condition: `if (IsReady())`");
				let br = FindNodeOf(mg.Graph, .Branch);
				SessionPick(br.FindOutput("true"), "Ping(", 960, -80);
			case 10:
				let mg = SessionOpen(mSessionHello);
				let ping = FindNodeOf(mg.Graph, .Call, "Ping");
				let recv = ping?.FindInput("target");
				SelfTestCheck(ping != null && !ping.IsPure && recv != null && mg.Graph.FindLinkTo(recv) == null && SessionDoc.Text.Contains("\t\t\t\tPing();"),
					"session 7 call with Receiver: Ping() on the True arm, Receiver unconnected = this, written `Ping();`");
				let br = FindNodeOf(mg.Graph, .Branch);
				SessionPick(br.FindOutput("false"), "Return", 960, 120);
			case 11:
				let mg = SessionOpen(mSessionHello);
				let ret = FindNodeOf(mg.Graph, .Return);
				SelfTestCheck(ret != null && SessionDoc.Text.Contains("else") && SessionDoc.Text.Contains("return;"), "session 8 Return on the False arm: `else { return; }`");
				SelfTestCheck(mg.Graph.Errors.IsEmpty, scope $"session 8 the Hello Sheet has no graph errors ({mg.Graph.Errors.Count})");
				SelfTestFit();
			case 12:
				mSessionStep--;
				if (SelfTestShot("sheet-populated"))
					mSessionStep++;
			case 13:
				let doc = SessionDoc;
				let type = FindTypeIn(doc, "Greeter");
				let info = ClassInfoFor(doc, type);
				InheritedMember tick = null;
				for (let m in info.Overridable)
					if (m.Name == "Tick")
						tick = m;
				if (tick == null)
				{
					SelfTestCheck(false, "session 9 Tick override: the Override list has no Tick");
					return true;
				}
				InheritedMember copy = scope .();
				copy.Kind = tick.Kind;
				copy.Name.Set(tick.Name);
				copy.OwnerType.Set(tick.OwnerType);
				copy.ReturnType.Set(tick.ReturnType);
				for (let s in tick.ParamTypes) copy.ParamTypes.Add(new String(s));
				for (let s in tick.ParamNames) copy.ParamNames.Add(new String(s));
				for (let s in tick.ParamModifiers) copy.ParamModifiers.Add(new String(s));
				copy.IsAbstract = tick.IsAbstract;
				copy.IsVirtual = tick.IsVirtual;
				copy.FromInterface = tick.FromInterface;
				copy.HasSetter = tick.HasSetter;
				copy.Visibility = tick.Visibility;
				AddOverrideNow(doc, "Greeter", copy);
				let mg = CurrentMethod;
				if (mg != null)
					mSessionTick.Set(mg.Key);
				SelfTestCheck(doc.Text.Contains("override void Tick(float dt)") && doc.Text.Contains("base.Tick(dt);") && mg != null && mg.Method.Name == "Tick",
					"session 9 Tick override: FUNCTIONS > Override > Tick wrote `override void Tick(float dt)` with `base.Tick(dt);` and opened it");
			case 14:
				let mg = SessionOpen(mSessionTick);
				let parent = FindNodeOf(mg.Graph, .Call, "Tick");
				if (parent == null)
				{
					SelfTestCheck(false, "session 10 Tick graph: no parent call node");
					return true;
				}
				SessionPick(parent.Then, "Hello(", 640, 0);
			case 15:
				SelfTestCheck(SessionDoc.Text.Contains("base.Tick(dt);") && SessionDoc.Text.Contains("\t\t\tHello();"), "session 10 Tick graph: Hello() added after the parent call");
				let ok = SaveAll();
				mSessionSaved.Set(SessionDoc.Text);
				SelfTestCheck(ok && !SessionDoc.Modified, "session 11 save: Save All wrote Greeter.bf, nothing unsaved");
				String disk = scope .();
				File.ReadAllText(mSessionPath, disk, true).IgnoreError();
				SelfTestCheck(disk == mSessionSaved, "session 11 save: the file on disk is the document text");
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] text after save:\n{mSessionSaved}");
			case 16:
				Compile();
				SelfTestCheck(SessionBuildRunning || SessionState == .Compiling, "session 12 compile: F7 started BeefBuild");
			case 17:
				if (SessionBuildRunning)
				{
					mSessionStep--;
					return false;
				}
				mSessionWait = 5;
			case 18:
				let st = SessionState;
				SelfTestCheck(st == .Good, scope $"session 12 compile: succeeded, indicator green ({st})");
				OpenTab(SessionMethod(mSessionHello));
			case 19:
				mSessionStep--;
				if (SelfTestShot("compile-green"))
					mSessionStep++;
			case 20:
				let mg = SessionOpen(mSessionHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SessionSetPin(print, FirstValueInput(print), "\"Hello again\"");
			case 21:
				SelfTestCheck(SessionDoc.Modified && SessionState == .Unknown, scope $"session 13 edit: an unsaved edit turns the indicator yellow ({SessionState})");
				let undone = SessionUndo(false);
				SelfTestCheck(undone && SessionDoc.Text == mSessionSaved && !SessionDoc.Modified, "session 14 undo: Ctrl+Z restores the saved text, not dirty");
			case 22:
				SelfTestCheck(SessionState == .Good, scope $"session 14 undo: back at the compiled text the indicator is green again ({SessionState})");
				let redone = SessionUndo(true);
				SelfTestCheck(redone && SessionDoc.Text.Contains("\"Hello again\"") && SessionDoc.Modified, "session 14 redo: Ctrl+Y re-applies the edit");
			case 23:
				let undone = SessionUndo(false);
				SelfTestCheck(undone && SessionDoc.Text == mSessionSaved, "session 14 undo again: saved text");
				let mg = SessionOpen(mSessionHello);
				let ping = FindNodeOf(mg.Graph, .Call, "Ping");
				CurrentTab.SelectOnly(ping.Id);
				DeleteSelection(CurrentTab);
			case 24:
				let mg = SessionOpen(mSessionHello);
				SelfTestCheck(FindNodeOf(mg.Graph, .Call, "Ping") == null && !SessionDoc.Text.Contains("Ping();"), "session 15 delete: Del on the Ping node removes it and its statement");
				let undone = SessionUndo(false);
				SelfTestCheck(undone && SessionDoc.Text == mSessionSaved, "session 15 delete undone: the statement is back");
			case 25:
				// The error path: an Other wired into the Receiver of Ping (a Greeter function).
				SessionOpen(mSessionHello);
				SessionPick(null, "Get mOther", 640, -240);
			case 26:
				let mg = SessionOpen(mSessionHello);
				let get = FindNodeOf(mg.Graph, .Get, "mOther");
				let ping = FindNodeOf(mg.Graph, .Call, "Ping");
				if (get == null || ping == null)
				{
					SelfTestCheck(false, "session 16 Receiver error: Get mOther or Ping missing");
					return true;
				}
				BeginEdit();
				let link = mg.Graph.Connect(get.Result, ping.FindInput("target"));
				SelfTestCheck(link != null, "session 16 Receiver error: the wire Other -> Receiver can be drawn");
				CommitCurrent();
			case 27:
				let mg = SessionOpen(mSessionHello);
				let ping = FindNodeOf(mg.Graph, .Call, "Ping");
				String msg = scope .();
				for (let e in mg.Graph.Errors)
					if (ping != null && e.NodeId == ping.Id)
						msg.Set(e.Message);
				SelfTestCheck(msg.Contains("Receiver must be a Greeter") && msg.Contains("Other"), scope $"session 16 Receiver error: on the Ping node: \"{msg}\"");
				SelfTestCheck(!SessionDoc.Text.Contains("mOther.Ping()"), "session 16 Receiver error: nothing written for the bad graph");
				if (ping != null)
					CurrentTab.SelectOnly(ping.Id);
			case 28:
				mSessionStep--;
				if (SelfTestShot("receiver-error"))
					mSessionStep++;
			case 29:
				let saved = SaveAll();
				String disk = scope .();
				File.ReadAllText(mSessionPath, disk, true).IgnoreError();
				SelfTestCheck(disk == mSessionSaved, scope $"session 16 Receiver error: Save keeps the file on disk unchanged (save {(saved ? "reported ok" : "refused")})");
				// Back to the good graph: undo the wire and the Get.
				SessionUndo(false);
			case 30:
				SessionUndo(false);
			case 31:
				let mg = SessionOpen(mSessionHello);
				SelfTestCheck(FindNodeOf(mg.Graph, .Get, "mOther") == null && mg.Graph.Errors.IsEmpty, scope $"session 16 two undos remove the wire and the Get, no errors left ({mg.Graph.Errors.Count})");
				// A compile error on a node: a name that does not exist typed into the print.
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SessionSetPin(print, FirstValueInput(print), "undefinedThing");
			case 32:
				SelfTestCheck(SessionDoc.Text.Contains("Console.WriteLine(undefinedThing);"), "session 17 compile error: an unknown name typed into the print pin");
				Compile();
			case 33:
				if (SessionBuildRunning)
				{
					mSessionStep--;
					return false;
				}
				mSessionWait = 5;
			case 34:
				let st = SessionState;
				SelfTestCheck(st == .Error, scope $"session 17 compile error: indicator red ({st})");
				let mg = SessionOpen(mSessionHello);
				Dictionary<int32, String> errs = scope .();
				Dictionary<int32, String> warns = scope .();
				defer { for (let v in errs.Values) delete v; for (let v in warns.Values) delete v; }
				GetNodeDiagnostics(mg, errs, warns);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				StringView onPrint = "";
				if (print != null && errs.TryGetValue(print.Id, let text))
					onPrint = text;
				SelfTestCheck(!onPrint.IsEmpty, scope $"session 17 compile error: the error is on the print node ({errs.Count} node error(s): {onPrint})");
				if (print != null)
					CurrentTab.SelectOnly(print.Id);
			case 35:
				mSessionStep--;
				if (SelfTestShot("compile-red"))
					mSessionStep++;
			case 36:
				// The 0.1.3 report: delete the node with the compile error and place a new one.
				if (!SessionNodeErrorSteps())
				{
					mSessionStep--;
					return false;
				}
				let mg = SessionOpen(mSessionHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SessionSetPin(print, FirstValueInput(print), "\"Hello\"");
			case 37:
				SelfTestCheck(SessionDoc.Text == mSessionSaved, "session 18 fixed: the print text is back");
				SaveAll();
				Compile();
			case 38:
				if (SessionBuildRunning)
				{
					mSessionStep--;
					return false;
				}
				mSessionWait = 5;
			case 39:
				let st = SessionState;
				SelfTestCheck(st == .Good, scope $"session 18 fixed: compile succeeded, indicator green ({st})");
				// Remember where every node is, then close and reopen the file.
				for (let k in mSessionPositions.Keys)
					delete k;
				mSessionPositions.Clear();
				let doc = SessionDoc;
				for (let mg in doc.Methods)
					if (mg.Graphable)
						for (let n in mg.Graph.Nodes)
							if (n.HasPos)
								mSessionPositions[new String(scope $"{mg.Key}|{n.Key}")] = (n.X, n.Y);
				SaveAll();
				CloseDoc(doc);
			case 40:
				let doc = OpenFile(mSessionPath, false);
				SelfTestCheck(doc != null && doc.Text == mSessionSaved && !doc.Modified, "session 19 reload: closed and reopened, the text round-trips byte for byte");
				int moved = 0;
				int found = 0;
				for (let mg in doc.Methods)
					if (mg.Graphable)
						for (let n in mg.Graph.Nodes)
							if (mSessionPositions.TryGetValueAlt(scope $"{mg.Key}|{n.Key}", let pos))
							{
								found++;
								// The side file stores whole units: a node placed at x.75 comes back at x.
								if (Math.Abs(pos.x - n.X) >= 1 || Math.Abs(pos.y - n.Y) >= 1)
								{
									moved++;
									Notify.Log(.Warning, "SelfTest", scope $"[SELFTEST] moved {mg.Key}|{n.Key} ({n.Kind} {n.Text}): ({pos.x}, {pos.y}) -> ({n.X}, {n.Y}) hasPos={n.HasPos}");
								}
							}
				SelfTestCheck(found >= mSessionPositions.Count && moved == 0, scope $"session 19 reload: {found} of {mSessionPositions.Count} node positions found, {moved} moved by a unit or more");
				let mg = SessionOpen(mSessionHello);
				SelfTestCheck(mg != null && FindNodeOf(mg.Graph, .Branch) != null && FindNodeOf(mg.Graph, .Call, "Ping") != null &&
					FindNodeOf(mg.Graph, .Call, "IsReady") != null && FindNodeOf(mg.Graph, .Return) != null && FindNodeOf(mg.Graph, .Call, "WriteLine") != null,
					"session 19 reload: Hello's graph has the print, Branch, IsReady, Ping and Return nodes");
				String body = scope .();
				doc.GenerateMethodBody(mg, body);
				SelfTestCheck(mg.Graph.Errors.IsEmpty, "session 19 reload: the reopened graph checks clean");
			case 41:
				let st = SessionState;
				SelfTestCheck(st == .Good, scope $"session 19 reload: indicator green on the reopened, unchanged file ({st})");
			case 42:
				// Type fields: an illegal type typed into the Properties panel or the Add dialogs is
				// refused with the reason, and the file is left exactly as it was.
				let doc = SessionDoc;
				let before = scope String(doc.Text);
				let mg = SessionMethod(mSessionHello);
				SelfTestCheck(mg != null, "session 20 type fields: the Hello function is there");
				if (mg == null)
					return true;
				String pars = scope .();
				bool retOk = ApplySignature(doc, mg.Method, "var", pars);
				SelfTestCheck(!retOk && doc.LastError.Contains("Return Type 'var' is not allowed here") && doc.Text == before && !doc.Modified,
					scope $"session 20 type fields: Return Type 'var' is refused with its reason and the file is unchanged (\"{doc.LastError}\")");
				let type = FindTypeIn(doc, "Greeter");
				bool varOk = AddVariableChecked(doc, type, "void", "mBad", "");
				SelfTestCheck(!varOk && doc.LastError.Contains("Variable Type 'void' is not allowed here") && doc.Text == before && !doc.Modified,
					scope $"session 20 type fields: a variable of type 'void' is refused with its reason and the file is unchanged (\"{doc.LastError}\")");
				let field = FindField(type, "mCount");
				bool setOk = field != null && ApplyVariableType(doc, field, "var");
				SelfTestCheck(!setOk && field != null && doc.Text == before && !doc.Modified, "session 20 type fields: changing a variable to 'var' is refused, file unchanged");
			case 43:
				// The 0.1.3 report: a Local Variable whose type is changed in Properties.
				if (!SessionLocalTypeSteps())
				{
					mSessionStep--;
					return false;
				}
				return false;
			case 44:
				// Constructors: the dimmed default rows, several constructors with parameters, the
				// duplicate refusal, and back to dimmed. Everything is undone at the end.
				let doc = SessionDoc;
				let before = scope String(doc.Text);
				let depth = doc.UndoDepth;
				var type = FindTypeIn(doc, "Greeter");
				SelfTestCheck(SourceDocument.HasDefaultMembers(type) && SourceDocument.FindDefaultCtor(type) == null && SourceDocument.FindDtor(type) == null,
					"session 22 constructors: Greeter lists a dimmed Constructor () and Destructor (nothing written yet)");
				bool ok = MaterializeDefaultMember(doc, type, false);
				type = FindTypeIn(doc, "Greeter");
				SelfTestCheck(ok && SourceDocument.FindDefaultCtor(type) != null && doc.UndoDepth == depth + 1 && doc.Text.Contains("public this()"),
					"session 22 constructors: opening the dimmed Constructor () writes `public this()` as one undo step");
				String key = scope .();
				ok = doc.AddConstructor(type, "public", "int a, String b", "", key);
				type = FindTypeIn(doc, "Greeter");
				SelfTestCheck(ok && doc.Text.Contains("public this(int a, String b)") && doc.FindMethod(key) != null,
					scope $"session 22 constructors: a second constructor with parameters is added ({key})");
				bool dup = doc.AddConstructor(type, "public", "int x, String y", "", key);
				SelfTestCheck(!dup && doc.LastError.Contains("Constructor (int, String)"), scope $"session 22 constructors: the same signature is refused (\"{doc.LastError}\")");
				ok = MaterializeDefaultMember(doc, type, true);
				type = FindTypeIn(doc, "Greeter");
				SelfTestCheck(ok && SourceDocument.FindDtor(type) != null, "session 22 constructors: opening the dimmed Destructor writes `public ~this()`");
				doc.DeleteMember(SourceDocument.FindDtor(type));
				doc.DeleteMember(SourceDocument.FindDefaultCtor(FindTypeIn(doc, "Greeter")));
				type = FindTypeIn(doc, "Greeter");
				SelfTestCheck(SourceDocument.FindDefaultCtor(type) == null && SourceDocument.FindDtor(type) == null && CtorCount(type) == 1,
					"session 22 constructors: deleting the written defaults puts the rows back to dimmed, the (int, String) one stays");
				while (doc.UndoDepth > depth)
					doc.Undo();
				SelfTestCheck(doc.Text == before, "session 22 constructors: undone, the file is as it was");
				return false;
			case 45:
				// Context Sensitive: a pin drag opens the menu with a pin context, the filter narrows the
				// list, unticking it shows everything; a menu from the empty canvas has no context.
				let tab = CurrentTab;
				let mg = SessionMethod(mSessionHello);
				Pin pin = null;
				if (mg != null)
					for (let n in mg.Graph.Nodes)
						for (let p in n.Outputs)
							if (pin == null && p.Kind == .Data)
								pin = p;
				SelfTestCheck(tab != null && pin != null, "session 23 context: a data output pin to drag from");
				if (tab == null || pin == null)
					return true;
				bool saved = mNodeMenu.ContextSensitive;
				OpenNodeMenu(tab, .(220, 220), pin.Id);
				{
					// The pending wire: from the dragged pin to where the node will go, while the menu is up.
					let g = mg.Graph;
					bool pend = PendingWire(tab, g, let pid, let at);
					SelfTestCheck(pend && pid == pin.Id && at.x == 220 && at.y == 220, "session 23 pending wire: a pin-opened menu keeps the wire from the pin to the release point");
					bool ends = false;
					if (mGraphPanel.PendingWireEnds(tab, g, let src, let end))
					{
						let want = tab.GridToScreen(220, 220);
						ends = end.x == want.x && end.y == want.y && src.Pin == pin;
					}
					SelfTestCheck(ends, "session 23 pending wire: the line's endpoints are the pin and the release point");
				}
				mNodeMenu.OpenRequested = false;
				SelfTestCheck(!PendingWire(tab, mg.Graph, ?, ?), "session 23 pending wire: gone once the menu is not showing");
				SelfTestCheck(mNodeMenu.SelfTestHasContext && mNodeMenu.ContextSensitive, "session 23 context: a pin drag opens the menu with a pin context and Context Sensitive ticked");
				int filtered = mNodeMenu.SelfTestVisibleCount(true);
				int all = mNodeMenu.SelfTestVisibleCount(false);
				SelfTestCheck(filtered > 0 && filtered < all, scope $"session 23 context: filtered {filtered} rows < unfiltered {all} rows for a pin drag");
				mNodeMenu.CloseRequested = true;
				OpenNodeMenu(tab, .(220, 220), 0);
				SelfTestCheck(!PendingWire(tab, mg.Graph, ?, ?), "session 23 pending wire: a menu from the empty canvas draws no wire");
				mNodeMenu.OpenRequested = false;
				int plain = mNodeMenu.SelfTestVisibleCount(true);
				SelfTestCheck(!mNodeMenu.SelfTestHasContext && plain == all, scope $"session 23 context: no pin, no context: the checkbox is disabled and nothing is filtered ({plain} rows = {all})");
				mNodeMenu.ContextSensitive = saved;
				return false;
			case 46:
				// No silent writes: the Construct wired into Ping's Receiver, set to scope, then type-less.
				if (!SessionScopeSteps())
				{
					mSessionStep--;
					return false;
				}
				return false;
			case 47:
				// Ownership and initial values: the Add Variable defaults, then the Properties rows'
				// edits (the same calls), each checked in the file text, then undone.
				let doc = SessionDoc;
				let before = scope String(doc.Text);
				int depth = doc.UndoDepth;
				let types = TypeService.Current;
				MemberInit init = scope .();
				let otherType = MemberInit.TypeOf("Other", types);
				init.Retarget(.OwnedCreatedHere, otherType);
				bool added = doc.AddField(FindTypeIn(doc, "Greeter"), "Other", "mApp", init);
				SelfTestCheck(added && doc.Text.Contains("public Other mApp = new .() ~ delete _;"), "session 25 ownership: Add Variable 'Other mApp', Owned, made here: `= new .() ~ delete _`");
				MemberInit read = scope .();
				let type = FindTypeIn(doc, "Greeter");
				let app = FindField(type, "mApp");
				bool readOk = app != null && doc.ReadMemberInit(app, otherType, read) && read.Owner == .OwnedCreatedHere;
				SelfTestCheck(readOk, "session 25 ownership: Properties reads it back as Owned, made here");
				if (!readOk)
					return true;
				read.Retarget(.Reference, otherType);
				ApplyMemberInit(doc, type, app, read);
				SelfTestCheck(doc.Text.Contains("public Other mApp;") && !doc.Text.Contains("mApp = new"), "session 25 ownership: Ownership > Reference leaves `public Other mApp;`");
				let type2 = FindTypeIn(doc, "Greeter");
				let count = FindField(type2, "mCount");
				let intType = MemberInit.TypeOf("int", types);
				MemberInit ci = scope .();
				bool countOk = count != null && doc.ReadMemberInit(count, intType, ci) && ci.ValueKind == .Literal && ci.Value == "1";
				SelfTestCheck(countOk, "session 25 ownership: mCount reads as a number, 1");
				if (!countOk)
					return true;
				ci.Value.Clear();
				MemberInit.FormatNumber("42", "int", ci.Value);
				ApplyMemberInit(doc, type2, count, ci);
				SelfTestCheck(doc.Text.Contains("public int mCount = 42;"), "session 25 ownership: Initial Value 42 writes `mCount = 42`");
				MemberInit day = scope .();
				let dayType = MemberInit.TypeOf("DayOfWeek", types);
				day.Retarget(.None, dayType);
				StartValue(.EnumCase, dayType, day, types);
				List<String> cases = scope .();
				defer { ClearAndDeleteItems!(cases); }
				MemberInit.EnumMembers("DayOfWeek", types, cases);
				SelfTestCheck(dayType.Kind == .Enum && cases.Contains(".Friday"), scope $"session 25 ownership: DayOfWeek is an enum with its members from the index ({cases.Count})");
				day.Value.Set(".Friday");
				doc.AddField(FindTypeIn(doc, "Greeter"), "DayOfWeek", "mDay", day);
				SelfTestCheck(doc.Text.Contains("public DayOfWeek mDay = .Friday;"), "session 25 ownership: an enum member picked writes `mDay = .Friday`");
				while (doc.UndoDepth > depth)
					doc.Undo();
				SelfTestCheck(doc.Text == before, "session 25 ownership: undo restores the file text");
				return false;
			case 48:
				// Set on create: two variables become the parameters of the create constructor, the
				// Outline row and the Construct node follow, and the project still compiles.
				let doc = SessionDoc;
				mSessionSaved.Set(doc.Text);
				let depth = doc.UndoDepth;
				var type = FindTypeIn(doc, "Greeter");
				bool ok = doc.SetFieldSetOnCreate(type, FindField(type, "mCount"), true);
				type = FindTypeIn(doc, "Greeter");
				ok = ok && doc.SetFieldSetOnCreate(type, FindField(type, "mOther"), true);
				type = FindTypeIn(doc, "Greeter");
				String pars = scope .();
				doc.GetCreateParamsText(type, pars);
				SelfTestCheck(ok && pars == "int count, Other other" && doc.Text.Contains("// VisualBeef: set on create\n\t\tpublic this(int count, Other other)") && doc.IsSetOnCreate(type, FindField(type, "mOther")),
					scope $"session 26 set on create: marking mCount and mOther writes the create constructor ({pars})");
				SelfTestCheck(CtorCount(type) == 1 && doc.UndoDepth == depth + 2, "session 26 set on create: one constructor row, Constructor (int, Other), one undo step per change");
				let mg = SessionOpen(mSessionHello);
				var ping = (mg != null) ? FindNodeOf(mg.Graph, .Call, "Ping") : null;
				bool picked = mg != null && ping != null && ping.FindInput("target") != null && SessionPick(ping.FindInput("target"), "Construct Greeter  (new)", 400, 200);
				var make = (mg != null) ? FindNodeOf(mg.Graph, .Construct, "Greeter") : null;
				String wiredTo = scope .();
				WiredTo(mg, make, wiredTo);
				SelfTestCheck(picked && make != null && make.ArgCount == 2 && make.Inputs[0].Label == "count" && make.Inputs[1].Label == "other",
					scope $"session 26 set on create: the Construct node has one input per parameter ({(make != null) ? make.ArgCount : -1} pins, wired to {wiredTo}, graph errors {(mg != null) ? mg.Graph.Errors.Count : -1})");
				mSessionWait = 3; // the graph commit lands first
			case 49:
				{
					// A scratch Main may call `scope Greeter()` (the debug step): give the class its plain
					// constructor next to the create constructor so the project still compiles.
					let ctorDoc = SessionDoc;
					let greeter = FindTypeIn(ctorDoc, "Greeter");
					if (greeter != null && SourceDocument.FindDefaultCtor(greeter) == null)
						MaterializeDefaultMember(ctorDoc, greeter, false);
				}
				SaveAll();
				Compile();
			case 50:
				if (SessionBuildRunning)
				{
					mSessionStep--;
					return false;
				}
				mSessionWait = 5;
			case 51:
				let st = SessionState;
				SelfTestCheck(st == .Good, scope $"session 26 set on create: compile succeeded, indicator green ({st})");
				{
					let text = SessionDoc.Text;
					String line = scope .();
					int at = text.IndexOf("new Greeter(");
					if (at >= 0)
					{
						int end = text.IndexOf(')', at);
						line.Set(StringView(text, at, (end > at) ? end - at + 1 : 12));
					}
					else
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] text:\n{text}");
					SelfTestCheck(at >= 0, scope $"session 26 set on create: the compiled file calls the constructor ({line})");
				}
			case 52:
				mSessionStep--;
				if (SelfTestShot("setoncreate"))
					mSessionStep++;
			case 53:
				let doc = SessionDoc;
				while (doc.UndoDepth > 0 && doc.Text != mSessionSaved)
					doc.Undo();
				SelfTestCheck(doc.Text == mSessionSaved, "session 26 set on create: undone, the file is as it was");
				SaveAll();
				return false;
			case 54:
				// Node hotkeys and favorites (docs/Editor-UI.md): the defaults are seeded in settings.json
				// and every default node is offered in the Hello Sheet.
				let mg = SessionOpen(mSessionHello);
				let prefs = NodePrefs;
				String settings = scope .();
				String settingsPath = scope .();
				Settings.GetPath(settingsPath);
				File.ReadAllText(settingsPath, settings, true).IgnoreError();
				SelfTestCheck(settings.Contains("\"nodeHotkeys\"") && settings.Contains("\"B\": \"Flow Control\\tBranch\"") && settings.Contains("\"favorites\""),
					"session 27 node hotkeys: the defaults are in settings.json (editor.nodeHotkeys B = Branch, editor.favorites)");
				int offered = 0;
				int bound = 0;
				String missing = scope .();
				for (let d in NodeHotkeys.Defaults)
				{
					let item = mNodeMenu.ItemForKey(mg, .(0, 0), 0, d.NodeKey);
					if (item != null)
						offered++;
					else
						missing.AppendF(" {}", d.Key);
					delete item;
					if (prefs.Hotkeys.NodeOf(d.Key) == d.NodeKey)
						bound++;
				}
				SelfTestCheck(offered == NodeHotkeys.Defaults.Count && bound == NodeHotkeys.Defaults.Count,
					scope $"session 27 node hotkeys: all {NodeHotkeys.Defaults.Count} default keys name a node of the Node menu ({offered} offered, {bound} bound as the defaults, missing:{missing})");
				SelfTestKey('B', true);
			case 55:
				// B held + a click on empty canvas: a Branch at the click.
				let mg = SessionOpen(mSessionHello);
				let tab = CurrentTab;
				let held = mGraphPanel.NodeHotkeyLetter(false);
				SelfTestCheck(held == 'B', scope $"session 28 B + click: the Sheet reads B as a held node hotkey ('{held}')");
				mSessionHotkeyBefore.Set(SessionDoc.Text);
				mSessionHotkeyDepth = SessionDoc.UndoDepth;
				mSessionHotkeyNodes = mg.Graph.Nodes.Count;
				float maxX = 0;
				for (let n in mg.Graph.Nodes)
					maxX = Math.Max(maxX, n.X);
				mSessionHotkeyAt = .(maxX + 480, 480);
				let screen = tab.GridToScreen(mSessionHotkeyAt.x, mSessionHotkeyAt.y);
				bool took = mGraphPanel.HotkeyClick(tab, mg, held, screen);
				SelfTestKey('B', false);
				SelfTestCheck(took, "session 28 B + click: the click is taken by the hotkey");
			case 56:
				let mg = SessionOpen(mSessionHello);
				int branches = 0;
				Node placed = null;
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .Branch)
					{
						branches++;
						if (Math.Abs(n.X - Canvas.SnapIf(mSessionHotkeyAt.x)) < 1 && Math.Abs(n.Y - Canvas.SnapIf(mSessionHotkeyAt.y)) < 1)
							placed = n;
					}
				SelfTestCheck(branches == 2 && placed != null && !mg.Graph.IsLinked(placed.ExecIn) && SessionDoc.Text == mSessionHotkeyBefore,
					scope $"session 28 B + click: a second Branch at the click ({branches} Branch nodes), unconnected, the code unchanged");
				SelfTestKey('P', true);
			case 57:
				// P pressed while a wire is dragged from Ping's flow output: a print connected after Ping.
				let mg = SessionOpen(mSessionHello);
				let tab = CurrentTab;
				let ping = FindNodeOf(mg.Graph, .Call, "Ping");
				let held = mGraphPanel.NodeHotkeyLetter(false);
				SelfTestCheck(held == 'P', scope $"session 29 P while dragging: the Sheet reads P ('{held}')");
				if (ping == null || ping.Then == null)
				{
					SelfTestCheck(false, "session 29 P while dragging: no Ping node");
					SelfTestKey('P', false);
					return true;
				}
				// What a press on the pin starts (GraphPanel.PressLeft), then the key during the drag.
				tab.Mode = .Wire;
				tab.ModeButton = 0;
				tab.DragPin = ping.Then.Id;
				let screen = tab.GridToScreen(ping.X + 320, ping.Y);
				bool took = mGraphPanel.WireHotkey(tab, mg, held, screen);
				SelfTestKey('P', false);
				SelfTestCheck(took && tab.Mode == .None, "session 29 P while dragging: the key is taken and the wire drag ends");
			case 58:
				let mg = SessionOpen(mSessionHello);
				let ping = FindNodeOf(mg.Graph, .Call, "Ping");
				let next = (ping != null && ping.Then != null) ? mg.Graph.ExecTarget(ping.Then) : null;
				SelfTestCheck(next != null && next.Kind == .Call && next.Text == "WriteLine",
					"session 29 P while dragging: a print node wired after Ping (Ping's Then -> the print)");
				if (next == null)
					return true;
				// Like a print chosen in the Node menu, it needs its text before it is written.
				SessionSetPin(next, FirstValueInput(next), "\"from P\"");
			case 59:
				let text = SessionDoc.Text;
				int pingAt = text.IndexOf("Ping();");
				int printAt = (pingAt >= 0) ? text.IndexOf("Console.WriteLine(\"from P\");", pingAt) : -1;
				int elseAt = (pingAt >= 0) ? text.IndexOf("else", pingAt) : -1;
				SelfTestCheck(printAt > pingAt && printAt < elseAt, "session 29 P while dragging: written `Console.WriteLine(\"from P\");` after `Ping();` on the True arm");
				// Favorites: a star on Console.Write, then a key from the key-capture control.
				let key = "Utilities | Print\tConsole.Write";
				let prefs = NodePrefs;
				if (prefs.IsFavorite(key))
					prefs.ToggleFavorite(key);
				bool fav = prefs.ToggleFavorite(key);
				SelfTestCheck(fav && prefs.IsFavorite(key), "session 30 favorites: the star makes Console.Write a favorite");
				mNodeMenu.StartCapture(key);
				bool okB = mNodeMenu.CaptureKey('B');
				let msgB = scope String(mNodeMenu.HotkeyMessage);
				SelfTestCheck(!okB && msgB == "B is already the hotkey of Branch." && mNodeMenu.IsCapturing,
					scope $"session 30 key capture: B refused with the owner named (\"{msgB}\"), still waiting for a key");
				bool okC = mNodeMenu.CaptureKey('C');
				let msgC = scope String(mNodeMenu.HotkeyMessage);
				SelfTestCheck(!okC && msgC.Contains("C is taken by the Sheet"), scope $"session 30 key capture: C refused (\"{msgC}\")");
				bool okK = mNodeMenu.CaptureKey('K');
				SelfTestCheck(okK && !mNodeMenu.IsCapturing && prefs.Hotkeys.KeyOf(key) == 'K', scope $"session 30 key capture: K assigned (\"{mNodeMenu.HotkeyMessage}\")");
				mNodeMenu.StartCapture(key);
				mNodeMenu.CaptureEscape();
				bool cleared = prefs.Hotkeys.KeyOf(key) == '\0' && prefs.IsFavorite(key);
				mNodeMenu.StartCapture(key);
				bool again = mNodeMenu.CaptureKey('K');
				SelfTestCheck(cleared && again, "session 30 key capture: Esc clears K (the favorite stays), then K is assigned again");
				String settings = scope .();
				String settingsPath = scope .();
				Settings.GetPath(settingsPath);
				File.ReadAllText(settingsPath, settings, true).IgnoreError();
				SelfTestCheck(settings.Contains("\"K\": \"Utilities | Print\\tConsole.Write\"") && settings.Contains("\t\t\t\"Utilities | Print\\tConsole.Write\""),
					"session 30 settings.json: editor.nodeHotkeys has K = Console.Write and editor.favorites lists it");
				SelfTestKey('K', true);
			case 60:
				// K, the new key, while dragging from the new print: Console.Write after it.
				let mg = SessionOpen(mSessionHello);
				let tab = CurrentTab;
				let ping = FindNodeOf(mg.Graph, .Call, "Ping");
				let print = (ping != null && ping.Then != null) ? mg.Graph.ExecTarget(ping.Then) : null;
				let held = mGraphPanel.NodeHotkeyLetter(false);
				if (print == null || print.Then == null)
				{
					SelfTestCheck(false, "session 31 new key: the print after Ping is missing");
					SelfTestKey('K', false);
					return true;
				}
				tab.Mode = .Wire;
				tab.ModeButton = 0;
				tab.DragPin = print.Then.Id;
				bool took = mGraphPanel.WireHotkey(tab, mg, held, tab.GridToScreen(print.X + 320, print.Y));
				SelfTestKey('K', false);
				SelfTestCheck(held == 'K' && took, scope $"session 31 new key: K is read and taken while dragging ('{held}')");
			case 61:
				let mg = SessionOpen(mSessionHello);
				let write = FindNodeOf(mg.Graph, .Call, "Write");
				let ping = FindNodeOf(mg.Graph, .Call, "Ping");
				let print = (ping != null && ping.Then != null) ? mg.Graph.ExecTarget(ping.Then) : null;
				let after = (print != null && print.Then != null) ? mg.Graph.ExecTarget(print.Then) : null;
				SelfTestCheck(write != null && after == write, "session 31 new key: K placed Console.Write wired after the print");
				if (write == null)
					return true;
				SessionSetPin(write, FirstValueInput(write), "\"from K\"");
			case 62:
				let mg = SessionOpen(mSessionHello);
				let text = SessionDoc.Text;
				int printAt = text.IndexOf("Console.WriteLine(\"from P\");");
				int writeAt = (printAt >= 0) ? text.IndexOf("Console.Write(\"from K\");", printAt) : -1;
				SelfTestCheck(writeAt > printAt && printAt > 0 && mg.Graph.Errors.IsEmpty,
					"session 31 new key: written `Console.Write(\"from K\");` after the print, no graph errors");
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] text with the hotkey nodes:\n{text}");
				mSessionUndos = 0;
			case 63:
				// Back to the first hotkey placement: undo by depth, not by text. The Branch and the
				// print placed without a value wrote no text, so the text equals the saved file long
				// before their steps are undone; each placement is an undo step of its own.
				if (SessionDoc.UndoDepth > mSessionHotkeyDepth && mSessionUndos < 20 && SessionUndo(false))
				{
					mSessionUndos++;
					mSessionStep--;
					return false;
				}
				{
					let mg = SessionOpen(mSessionHello);
					SelfTestCheck(SessionDoc.Text == mSessionSaved && !SessionDoc.Modified, scope $"session 32 {mSessionUndos} undos: the saved text is back");
					SelfTestCheck(mg.Graph.Nodes.Count == mSessionHotkeyNodes && mg.Graph.Errors.IsEmpty && SessionDoc.UndoDepth == mSessionHotkeyDepth,
						scope $"session 32 {mSessionUndos} undos: the hotkey nodes are gone from the graph too ({mg.Graph.Nodes.Count} nodes, was {mSessionHotkeyNodes}; {mg.Graph.Errors.Count} errors)");
				}
				mSessionRedos = 0;
			case 64:
				// And forward again: every placement comes back (the graph, not only the text).
				if (SessionDoc.CanRedo && mSessionRedos < mSessionUndos && SessionUndo(true))
				{
					mSessionRedos++;
					mSessionStep--;
					return false;
				}
				{
					let mg = SessionOpen(mSessionHello);
					SelfTestCheck(mSessionRedos == mSessionUndos && mg.Graph.Nodes.Count > mSessionHotkeyNodes && SessionDoc.Text.Contains("Console.Write(\"from K\");"),
						scope $"session 32 redo: {mSessionRedos} redos bring the hotkey nodes back ({mg.Graph.Nodes.Count} nodes)");
				}
				mSessionUndos = 0;
			case 65:
				if (SessionDoc.UndoDepth > mSessionHotkeyDepth && mSessionUndos < 20 && SessionUndo(false))
				{
					mSessionUndos++;
					mSessionStep--;
					return false;
				}
				{
					let mg = SessionOpen(mSessionHello);
					SelfTestCheck(SessionDoc.Text == mSessionSaved && !SessionDoc.Modified && mg.Graph.Nodes.Count == mSessionHotkeyNodes && mg.Graph.Errors.IsEmpty,
						scope $"session 32 undo again: back at the saved text and {mg.Graph.Nodes.Count} nodes");
				}
				SelfTestFit();
			case 66:
				// Comment bubble: a comment added through the bubble editor lands in the Beef as comment
				// lines above the statement and in Properties > Comment (one undo step).
				let mg = SessionOpen(mSessionHello);
				let tab = CurrentTab;
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				SelfTestCheck(print != null && tab != null, "session 33 bubble: the print node to comment");
				if (print == null || tab == null)
					return true;
				mSessionPreBubble.Set(SessionDoc.Text);
				mSessionBubbleDepth = SessionDoc.UndoDepth;
				mGraphPanel.BeginBubbleEdit(print.Id);
				SelfTestCheck(mGraphPanel.BubbleEditing, "session 33 bubble: the in-place editor opens on the node");
				mGraphPanel.CancelBubbleEdit();
				SelfTestCheck(!mGraphPanel.BubbleEditing && SessionDoc.Text == mSessionPreBubble, "session 33 bubble: Escape cancels, nothing written");
				mGraphPanel.BeginBubbleEdit(print.Id);
				SelfTestCheck(mGraphPanel.SelfTestCommitBubble("note from bubble"), "session 33 bubble: Enter commits the text");
				mSessionWait = 4;
			case 67:
				let mg = SessionOpen(mSessionHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				String field = scope .();
				if (print != null)
					GraphPanel.CommentText(print, field);
				SelfTestCheck(field == "note from bubble", scope $"session 33 bubble: Properties > Comment shows the bubble's text ('{field}')");
				let text = SessionDoc.Text;
				int cAt = text.IndexOf("// note from bubble");
				int wAt = (cAt >= 0) ? text.IndexOf("Console.WriteLine", cAt) : -1;
				SelfTestCheck(cAt >= 0 && wAt > cAt && text.IndexOf('\n', cAt) < wAt, "session 33 bubble: written as a comment line above the statement");
				SelfTestCheck(SessionDoc.UndoDepth == mSessionBubbleDepth + 1, scope $"session 33 bubble: one undo step ({SessionDoc.UndoDepth - mSessionBubbleDepth})");
				if (print != null)
				{
					CurrentTab.ZoomLevel = Canvas.DefaultZoomLevel;
					CurrentTab.CenterOn(print.X + 120, print.Y + 20);
					CurrentTab.SelectOnly(print.Id);
				}
				mSessionWait = 4;
			case 68:
				mSessionStep--;
				if (SelfTestShot("bubble-unpinned-z1"))
				{
					mSessionStep++;
					let print = FindNodeOf(SessionOpen(mSessionHello).Graph, .Call, "WriteLine");
					mGraphPanel.BeginBubbleEdit(print.Id);
					mSessionWait = 4;
				}
			case 69:
				mSessionStep--;
				if (SelfTestShot("bubble-edit"))
				{
					mSessionStep++;
					mGraphPanel.CancelBubbleEdit();
					CurrentTab.ZoomLevel = Math.Max(0, Canvas.DefaultZoomLevel - 4);
					mSessionWait = 4;
				}
			case 70:
				mSessionStep--;
				if (SelfTestShot("bubble-unpinned-far"))
				{
					mSessionStep++;
					let mg = SessionOpen(mSessionHello);
					let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
					CurrentTab.Doc.SetBubblePinned(mg.Key, print.Key, true);
					// A pinned comment box beside it (layout only; removed below).
					let cbox = new GraphComment();
					cbox.MethodKey.Set(mg.Key);
					cbox.X = print.X - 40;
					cbox.Y = print.Y - 160;
					cbox.W = 420;
					cbox.H = 120;
					cbox.Color = 0xB4D2A050;
					cbox.Text.Set("Group: greeting");
					cbox.Pinned = true;
					CurrentTab.Doc.Comments.Add(cbox);
					LayoutChanged();
					mSessionWait = 4;
				}
			case 71:
				mSessionStep--;
				if (SelfTestShot("bubble-pinned-far"))
				{
					mSessionStep++;
					CurrentTab.ZoomLevel = Canvas.DefaultZoomLevel;
					mSessionWait = 4;
				}
			case 72:
				mSessionStep--;
				if (SelfTestShot("bubble-pinned-z1"))
				{
					mSessionStep++;
					// Save, close, reopen: the comment, the pin and the box's pin come back.
					SaveAll();
					String layout = scope .();
					SessionDoc.GetLayoutText(layout);
					SelfTestCheck(layout.Contains("#bubble\t") && layout.Contains("Group: greeting\t1"), "session 33 pin: the layout file lists the pinned bubble and the pinned box");
					CloseDoc(SessionDoc);
				}
			case 73:
				let doc = OpenFile(mSessionPath, false);
				let mg = SessionOpen(mSessionHello);
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				String field = scope .();
				if (print != null)
					GraphPanel.CommentText(print, field);
				SelfTestCheck(doc != null && print != null && field == "note from bubble" && doc.Text.Contains("// note from bubble"), "session 33 reload: the comment is in Properties > Comment and in the Beef");
				SelfTestCheck(print != null && doc.IsBubblePinned(mg.Key, print.Key), "session 33 reload: the bubble is still pinned");
				bool boxPinned = false;
				for (let c in doc.Comments)
					if (c.Text == "Group: greeting" && c.Pinned)
						boxPinned = true;
				SelfTestCheck(boxPinned, "session 33 reload: the comment box is still pinned");
				// Remove the test box and the pin, then the comment through the editor.
				for (var i = doc.Comments.Count - 1; i >= 0; i--)
					if (doc.Comments[i].Text == "Group: greeting")
					{
						delete doc.Comments[i];
						doc.Comments.RemoveAt(i);
					}
				if (print != null)
				{
					doc.SetBubblePinned(mg.Key, print.Key, false);
					mGraphPanel.BeginBubbleEdit(print.Id);
					mGraphPanel.SelfTestCommitBubble("");
				}
				LayoutChanged();
				mSessionWait = 4;
			case 74:
				bool hasNote = SessionDoc.Text.Contains("note from bubble");
				SelfTestCheck(SessionDoc.Text == mSessionPreBubble, scope $"session 33 bubble: clearing the text removes the comment line, the file is as before (now {SessionDoc.Text.Length} chars, was {mSessionPreBubble.Length}, comment present {hasNote})");
				// Paste: the pasted nodes become the selection (two nodes pasted, both selected, none of the old).
				let mg = SessionOpen(mSessionHello);
				let tab = CurrentTab;
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				let branch = FindNodeOf(mg.Graph, .Branch);
				SelfTestCheck(print != null && branch != null, "session 34 paste: two nodes to copy");
				if (print == null || branch == null)
					return true;
				mSessionOldIds.Clear();
				for (let n in mg.Graph.Nodes)
					mSessionOldIds.Add(n.Id);
				mSessionHotkeyNodes = mg.Graph.Nodes.Count;
				mSessionBubbleDepth = SessionDoc.UndoDepth;
				tab.SelectOnly(print.Id);
				tab.AddToSelection(branch.Id);
				CopySelection(tab);
				Paste(tab, .(print.X + 600, print.Y + 300));
				mSessionWait = 4;
			case 75:
				let mg = SessionOpen(mSessionHello);
				let tab = CurrentTab;
				bool allNew = true;
				for (let id in tab.SelectedNodes)
					if (mSessionOldIds.Contains(id) || mg.Graph.FindNode(id) == null)
						allNew = false;
				SelfTestCheck(mg.Graph.Nodes.Count == mSessionHotkeyNodes + 2, scope $"session 34 paste: two nodes added ({mg.Graph.Nodes.Count} from {mSessionHotkeyNodes})");
				SelfTestCheck(tab.SelectedNodes.Count == 2 && allNew, scope $"session 34 paste: the selection is the two pasted nodes ({tab.SelectedNodes.Count} selected, all new: {allNew})");
				if (!tab.SelectedNodes.IsEmpty)
				{
					let n = mg.Graph.FindNode(tab.SelectedNodes[0]);
					if (n != null)
						tab.CenterOn(n.X + 100, n.Y + 60);
				}
				mSessionWait = 4;
			case 76:
				mSessionStep--;
				if (SelfTestShot("paste-selected"))
				{
					mSessionStep++;
					while (SessionDoc.UndoDepth > mSessionBubbleDepth && SessionUndo(false)) {}
					mSessionWait = 3;
				}
			case 77:
				let mg = SessionOpen(mSessionHello);
				SelfTestCheck(mg.Graph.Nodes.Count == mSessionHotkeyNodes, scope $"session 34 paste: undone ({mg.Graph.Nodes.Count} nodes)");
				SaveAll();
				SelfTestFit();
			case 78:
				// Capture `undo-placed-after`: Hello's graph with the hotkey nodes undone.
				mSessionStep--;
				if (SelfTestShot("undo-placed-after"))
				{
					mSessionStep++;
					mSessionWait = 3;
				}
			case 79:
				// Session 35: saved views 1-9 (Ctrl+digit saves, digit jumps), Home, Fit, the minimap.
				let mg = SessionOpen(mSessionHello);
				let tab = CurrentTab;
				SelfTestCheck(mg != null && tab != null && tab.CanvasSize.x > 0, "session 35 views: the Sheet is open and has been drawn");
				if (mg == null || tab == null || tab.CanvasSize.x <= 0)
					return true;
				mNavSavedCenter = tab.ViewCenter;
				mNavSavedLevel = tab.ZoomLevel;
				mGraphPanel.SaveView(tab, 3);
				let v = tab.Doc.FindView(tab.MethodKey, 3);
				SelfTestCheck(v != null && Math.Abs(v.X - mNavSavedCenter.x) < 0.01f && Math.Abs(v.Zoom - tab.Zoom) < 0.0001f, "session 35 views: Ctrl+3 stores the middle of the canvas and the zoom");
				SelfTestCheck(mGraphPanel.NavToastText == "View 3 saved", scope $"session 35 views: toast View 3 saved (is {mGraphPanel.NavToastText})");
				String layout = scope .();
				tab.Doc.GetLayoutText(layout);
				SelfTestCheck(layout.Contains(scope $"#view\t{tab.MethodKey}\t3\t"), "session 35 views: the layout file has the #view line");
				// Move away: pan and zoom change.
				tab.Pan = .(tab.Pan.x - 900, tab.Pan.y - 500);
				tab.ZoomLevel = (tab.ZoomLevel > 3) ? tab.ZoomLevel - 2 : tab.ZoomLevel + 2;
				SelfTestCheck(mGraphPanel.JumpToView(tab, 3), "session 35 views: digit 3 jumps to a saved view");
				SelfTestCheck(mGraphPanel.NavToastText == "View 3", scope $"session 35 views: toast View 3 (is {mGraphPanel.NavToastText})");
				SelfTestCheck(!mGraphPanel.JumpToView(tab, 5), "session 35 views: an unset digit does not move");
				SelfTestCheck(mGraphPanel.NavToastText == "View 5 is not set (Ctrl+5 saves it)", scope $"session 35 views: unset toast (is {mGraphPanel.NavToastText})");
				mGraphPanel.JumpToView(tab, 3);
				SelfTestCheck(tab.ViewAnim, "session 35 views: the jump is eased (still moving right after the key)");
			case 80:
				let tab = CurrentTab;
				if (tab.ViewAnim)
				{
					mSessionStep--; // wait for the ease to end (about 150 ms)
					return false;
				}
				let c = tab.ViewCenter;
				SelfTestCheck(Math.Abs(c.x - mNavSavedCenter.x) < 1 && Math.Abs(c.y - mNavSavedCenter.y) < 1 && tab.ZoomLevel == mNavSavedLevel, scope $"session 35 views: the jump lands on the saved view (centre {c.x},{c.y} want {mNavSavedCenter.x},{mNavSavedCenter.y})");
				// Not in the Beef text, kept with the file: save, close, reopen.
				SaveAll();
				String layout = scope .();
				SessionDoc.GetLayoutText(layout);
				SelfTestCheck(layout.Contains("#view\t"), "session 35 views: saved with the layout");
				CloseDoc(SessionDoc);
			case 81:
				let doc = OpenFile(mSessionPath, false);
				let mg = SessionOpen(mSessionHello);
				let v = (doc != null && mg != null) ? doc.FindView(mg.Key, 3) : null;
				SelfTestCheck(v != null && Math.Abs(v.X - mNavSavedCenter.x) < 1 && Math.Abs(v.Y - mNavSavedCenter.y) < 1, "session 35 views: view 3 is still there after a reopen");
				mSessionWait = 3; // the tab of the reopened file is selected on the next frames
			case 82:
				let doc = SessionDoc;
				let mg = SessionOpen(mSessionHello);
				let tab = CurrentTab;
				SelfTestCheck(tab != null && tab.Doc == doc && tab.MethodKey == mg.Key, "session 35 views: the reopened Sheet is the current tab");
				mGraphPanel.SaveView(tab, 1);
				mGraphPanel.SaveView(tab, 2);
				SelfTestCheck(mGraphPanel.ClearSavedViews(tab, 3) == 1 && doc.FindView(mg.Key, 3) == null && doc.FindView(mg.Key, 1) != null, "session 35 views: Clear removes just that view");
				SelfTestCheck(mGraphPanel.ClearSavedViews(tab, 0) == 2 && doc.Views.IsEmpty, "session 35 views: Clear All removes the rest");
				String text = scope .();
				doc.GetLayoutText(text);
				SelfTestCheck(!text.Contains("#view"), "session 35 views: no views, no #view lines");
				// Home: the entry node at zoom 1; Fit all: everything in view.
				tab.Pan = .(tab.Pan.x - 1500, tab.Pan.y - 900);
				tab.ZoomLevel = (tab.ZoomLevel > 3) ? tab.ZoomLevel - 2 : tab.ZoomLevel + 2;
				mGraphPanel.GoHome(tab, mg.Graph);
			case 83:
				let tab = CurrentTab;
				let mg = SessionOpen(mSessionHello);
				if (tab.ViewAnim)
				{
					mSessionStep--;
					return false;
				}
				let e = mg.Graph.Entry;
				let sp = tab.GridToScreen(e.X, e.Y);
				SelfTestCheck(tab.ZoomLevel == Canvas.DefaultZoomLevel && Math.Abs(sp.x - tab.CanvasOrigin.x - 60) < 1.5f, scope $"session 35 home: the entry node at zoom 1, 60 px from the left (zoom level {tab.ZoomLevel}, x {sp.x - tab.CanvasOrigin.x})");
				tab.Pan = .(tab.Pan.x - 2500, tab.Pan.y - 1500);
				mGraphPanel.FitAll(tab, mg.Graph);
				tab.ApplyPendingCenter();
				let v0 = tab.ScreenToGrid(tab.CanvasOrigin);
				let v1 = tab.ScreenToGrid(tab.CanvasOrigin + tab.CanvasSize);
				bool all = true;
				for (let n in mg.Graph.Nodes)
					if (n.X < v0.x || n.Y < v0.y || n.X > v1.x || n.Y > v1.y)
						all = false;
				SelfTestCheck(all, "session 35 fit: every node is in view after Fit all");
				// Minimap: the toggle is remembered in the settings file; the block cache is not rebuilt per frame.
				Prefs.ShowMinimap = true;
				Prefs.Save();
				mNavRebuilds = mGraphPanel.MmRebuilds;
				mSessionWait = 12;
			case 84:
				{
					// Dragging in the minimap: the middle of the view follows the mouse, clamped to the graph.
					let tab = CurrentTab;
					mGraphPanel.MinimapBounds(let bx0, let by0, let bx1, let by1);
					let midPt = mGraphPanel.MinimapPointOf(tab, (bx0 + bx1) * 0.5f, (by0 + by1) * 0.5f);
					mGraphPanel.MinimapDragTo(tab, midPt);
					var c = tab.ViewCenter;
					SelfTestCheck(Math.Abs(c.x - (bx0 + bx1) * 0.5f) < 2 && Math.Abs(c.y - (by0 + by1) * 0.5f) < 2, scope $"session 35 minimap: dragging to the middle of the map centres the view ({c.x},{c.y})");
					mGraphPanel.MinimapDragTo(tab, .(midPt.x + 5000, midPt.y - 5000));
					c = tab.ViewCenter;
					SelfTestCheck(Math.Abs(c.x - bx1) < 2 && Math.Abs(c.y - by0) < 2, scope $"session 35 minimap: dragging far outside is clamped to the graph ({c.x},{c.y} want {bx1},{by0})");
				}
				SelfTestCheck(mGraphPanel.MmRebuilds - mNavRebuilds <= 1, scope $"session 35 minimap: the block cache is not rebuilt per frame ({mGraphPanel.MmRebuilds - mNavRebuilds} rebuilds in 12 frames)");
				Prefs.ShowMinimap = false;
				Prefs.Save();
				Prefs.ShowMinimap = true;
				Prefs.Load();
				SelfTestCheck(!Prefs.ShowMinimap, "session 35 minimap: switched off, it is still off after the settings are read again");
				Prefs.ShowMinimap = true;
				Prefs.Save();
				Prefs.ShowMinimap = false;
				Prefs.Load();
				SelfTestCheck(Prefs.ShowMinimap, "session 35 minimap: switched on, it is still on after the settings are read again");
				Prefs.ShowMinimap = false;
				Prefs.Save();
				mSessionWait = 2;
			case 85:
				// Node Library (docs/Classes-and-Members.md): New Node Library, a function and a variable,
				// called from another sheet, the global read.
				String src = scope .();
				src.AppendF("{}{}src", mProjectRoot, Path.DirectorySeparatorChar);
				ResetCreateTypeOptions();
				mCBNewTemplate = 2;
				CreateAsset(.Library, src, "Tools");
				mSessionLibPath.Clear();
				mSessionLibPath.AppendF("{}{}Tools.bf", src, Path.DirectorySeparatorChar);
				let ldoc = OpenFile(mSessionLibPath, false);
				SelfTestCheck(ldoc != null && File.Exists(mSessionLibPath) && ldoc.Text.Contains("static class Tools") && FindTypeIn(ldoc, "Tools").IsNodeLibrary,
					"session 36 node library: Project Browser > New Node Library 'Tools' wrote `static class Tools`");
				if (ldoc == null)
					return true;
			case 86:
				let ldoc = FindDoc(mSessionLibPath);
				String key = scope .();
				ldoc.AddMethod(FindTypeIn(ldoc, "Tools"), "int", "Twice", "int x", key);
				mSessionLibFn.Set(key);
				let sv = AddVariableChecked(ldoc, FindTypeIn(ldoc, "Tools"), "int", "sCount", "3");
				SelfTestCheck(sv && ldoc.Text.Contains("public static int Twice(int x)") && ldoc.Text.Contains("public static int sCount = 3;"),
					"session 36 node library: the function and the variable are written static");
				let tmg = ldoc.FindMethod(key);
				SelfTestCheck(tmg != null && tmg.Graph.StaticContext && tmg.Graph.InLibrary, "session 36 node library: its sheet has no this");
				if (tmg != null)
				{
					// Twice returns a value, so the project still compiles for the debug step after it.
					let ret = NodeFactory.Return(tmg.Graph, "int");
					ret.FindInput("value").Default.Set("x * 2");
					tmg.Graph.Connect(tmg.Graph.Entry.Then, ret.ExecIn);
					ldoc.Commit(tmg);
				}
				mSessionLibDepth = SessionDoc.UndoDepth;
				SaveAll();
				mSessionWait = 30;
			case 87:
				let mg = SessionOpen(mSessionHello);
				bool picked = mg != null && SessionPickIn(mg.Graph.Entry.Then, "Libraries", "Twice", 520, 320);
				SelfTestCheck(picked, "session 36 node library: the Node menu offers Twice under Libraries");
				mSessionWait = 3;
			case 88:
				let mg = SessionOpen(mSessionHello);
				Node call = null;
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .Call && n.Text.Contains("Twice"))
						call = n;
				if (call != null)
					SessionSetPin(call, FirstValueInput(call), "4");
				mSessionWait = 3;
			case 89:
				let mg = SessionOpen(mSessionHello);
				Node call = null;
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .Call && n.Text.Contains("Twice"))
						call = n;
				SelfTestCheck(call != null && call.FindInput("target") == null && SessionDoc.Text.Contains("Tools.Twice("),
					scope $"session 36 node library: the call has no Receiver pin and is written Tools.Twice(...) (node {(call != null) ? call.Text : "none"}, receiver pin {(call != null) ? call.FindInput("target") != null : false}, written {SessionDoc.Text.Contains("Tools.Twice(")}, errors {mg.Graph.Errors.Count} {(mg.Graph.Errors.Count > 0) ? mg.Graph.Errors[0].Message : ""})");
				bool picked = SessionPickIn(null, "Globals", "Count", 520, 460);
				SelfTestCheck(picked, "session 36 node library: the Node menu offers the global under Globals");
				mSessionWait = 3;
			case 90:
				let mg = SessionOpen(mSessionHello);
				Node get = null;
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .Get && n.Text.Contains("sCount"))
						get = n;
				SelfTestCheck(get != null && get.Text == "Tools.sCount", scope $"session 36 node library: Get writes Tools.sCount ({(get != null) ? get.Text : "no Get node"})");
				SessionFrameSelection();
				mSessionWait = 3;
			case 91:
				mSessionStep--;
				if (SelfTestShot("library-sheet"))
					mSessionStep++;
			case 92:
				// Captures: the New dialog on Node Library, then the library's Outline, Type Settings and a function's Properties.
				String src = scope .();
				src.AppendF("{}{}src", mProjectRoot, Path.DirectorySeparatorChar);
				StartNewAsset(.Library, src);
				mSessionWait = 4;
			case 93:
				mSessionStep--;
				if (SelfTestShot("library-newdialog"))
				{
					mSessionStep++;
					mSelfTestCloseDialog = true;
					mSessionWait = 3;
				}
			case 94:
				let ldoc = FindDoc(mSessionLibPath);
				let tmg = ldoc.FindMethod(mSessionLibFn);
				OpenTab(tmg);
				SelectTypeSettings("Tools");
				mSessionWait = 4;
			case 95:
				mSessionStep--;
				if (!mSessionLibSel)
				{
					mSessionLibSel = true;
					SelectTypeSettings("Tools");
					mSessionWait = 4;
				}
				else if (SelfTestShot("library-typesettings"))
					mSessionStep++;
			case 96:
				let ldoc = FindDoc(mSessionLibPath);
				let tmg = SessionOpen2(ldoc, mSessionLibFn);
				mSelClassActive = false;
				if (tmg != null && tmg.Graph.Entry != null && CurrentTab != null)
					CurrentTab.SelectOnly(tmg.Graph.Entry.Id);
				mSessionWait = 4;
			case 97:
				mSessionStep--;
				if (SelfTestShot("library-function"))
					mSessionStep++;
			case 98:
				// Back to the saved Greeter; the library stays (saved) in the project.
				while (SessionDoc.UndoDepth > mSessionLibDepth && SessionUndo(false)) {}
				SelfTestCheck(SessionDoc.Text == mSessionSaved, "session 36 node library: the Greeter sheet is back as saved");

				SaveAll();
			default:
				return SessionPinSteps(step - 99);
			}
			return false;
		}

		int mSessionPinDepth;
		bool mSessionPinPanned;
		String mSessionPinBefore = new .() ~ delete _;
		String mSessionPlan = new .() ~ delete _;
		String mSessionShow = new .() ~ delete _;

		static Pin FirstPinOf(Node n)
		{
			for (let p in n.Inputs)
				if (p.Kind == .Data && p.Name != "target")
					return p;
			return null;
		}

		/// Typed pin values and the one Switch node (docs/Editor-UI.md > Pin values): the controls are
		/// ImGui widgets, so this drives the rules (PinValue) they call, then places a
		/// `Switch on DayOfWeek` from a drag off an enum output and checks the Beef.
		bool SessionPinSteps(int sub)
		{
			let doc = SessionDoc;
			switch (sub)
			{
			case 0:
				mSessionPinBefore.Set(doc.Text);
				mSessionPinDepth = doc.UndoDepth;
				doc.AddField(FindTypeIn(doc, "Greeter"), "DayOfWeek", "mDay", ".Friday");
				doc.AddMethod(FindTypeIn(doc, "Greeter"), "void", "Plan", "", mSessionPlan);
				doc.AddMethod(FindTypeIn(doc, "Greeter"), "void", "Show", "DayOfWeek d, bool loud, int times, uint8 level, float scale, char8 mark, String name", mSessionShow);
				let mg = SessionOpen(mSessionPlan);
				SelfTestCheck(mg != null && SessionMethod(mSessionShow) != null, scope $"session 37 pins: Plan and Show added ({mSessionPlan}, {mSessionShow})");
				if (mg != null)
					SessionPick(mg.Graph.Entry.Then, "Show(", 320, 0);
				mSessionWait = 3;
			case 1:
				let mg = SessionOpen(mSessionPlan);
				let show = FindNodeOf(mg.Graph, .Call, "Show");
				if (show == null)
				{
					SelfTestCheck(false, "session 37 pins: no Show node");
					return true;
				}
				let ts = TypeService.Current;
				int matched = 0;
				for (let p in show.Inputs)
				{
					if (p.Kind != .Data || p.Name == "target")
						continue;
					let kind = PinValue.KindOf(p.TypeName, p.Default, p.Name, ts);
					PinValueKind want = .Expr;
					switch (p.TypeName)
					{
					case "DayOfWeek": want = .Enum;
					case "bool": want = .Bool;
					case "int", "uint8", "float": want = .Number;
					case "char8": want = .Char;
					case "String": want = .Text;
					}
					if (kind == want)
						matched++;
				}
				SelfTestCheck(matched == 7, scope $"session 37 pins: each unwired pin of Show has the control for its type ({matched} of 7)");
				BeginEdit();
				for (let p in show.Inputs)
				{
					if (p.Kind != .Data || p.Name == "target")
						continue;
					StringView typed = "";
					switch (p.TypeName)
					{
					case "DayOfWeek": typed = "Friday";
					case "bool": typed = "true";
					case "int": typed = "3";
					case "uint8": typed = "7";
					case "float": typed = "1.5";
					case "char8": typed = "x";
					case "String": typed = "say hi";
					}
					PinValueKind kind = PinValue.KindOf(p.TypeName, "", p.Name, ts);
					String lit = scope .();
					String why = scope .();
					if (PinValue.Write(kind, p.TypeName, typed, false, lit, why))
						p.Default.Set(lit);
					else
						SelfTestCheck(false, scope $"session 37 pins: {p.TypeName} refused '{typed}': {why}");
				}
				show.Edited = true;
				CommitCurrent();
				mSessionWait = 3;
			case 2:
				const String want = "Show(.Friday, true, 3, 7, 1.5f, 'x', \"say hi\");";
				SelfTestCheck(doc.Text.Contains(want), "session 37 pins: the enum is `.Friday`, the string is quoted, the float has its `f`, the character `'x'`");
				if (!doc.Text.Contains(want))
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] text: {doc.Text}");
				// A value the type cannot hold is refused with the reason, and nothing changes.
				String lit = scope .();
				String why = scope .();
				bool refused = !PinValue.Write(.Number, "uint8", "300", false, lit, why) && why.Contains("does not fit uint8") && lit.IsEmpty;
				SelfTestCheck(refused, scope $"session 37 pins: uint8 refuses 300 ({why})");
				let mg = SessionOpen(mSessionPlan);
				SessionPick(null, "Get mDay", 640, 320);
				mSessionWait = 3;
			case 3:
				let mg = SessionOpen(mSessionPlan);
				let get = FindNodeOf(mg.Graph, .Get, "mDay");
				if (get == null)
				{
					SelfTestCheck(false, "session 37 pins: no Get mDay");
					return true;
				}
				bool picked = SessionPick(get.Result, "Switch on DayOfWeek", 960, 0);
				SelfTestCheck(picked, "session 37 switch: dragging off an enum output offers `Switch on DayOfWeek` first");
				mSessionWait = 3;
			case 4:
				let mg = SessionOpen(mSessionPlan);
				let get = FindNodeOf(mg.Graph, .Get, "mDay");
				let sw = FindNodeOf(mg.Graph, .Switch);
				let show = FindNodeOf(mg.Graph, .Call, "Show");
				if (sw == null || get == null || show == null)
				{
					SelfTestCheck(false, "session 37 switch: no Switch placed");
					return true;
				}
				List<String> members = scope .();
				defer { ClearAndDeleteItems!(members); }
				PinValue.Members("DayOfWeek", TypeService.Current, members);
				int caseCount = 0;
				for (let p in sw.Outputs)
					if (p.Kind == .Exec && p.Name != "default" && p.Name != "then")
						caseCount++;
				let valueLink = mg.Graph.FindLinkTo(sw.FindInput("value"));
				SelfTestCheck(NodeFactory.SwitchType(sw) == "DayOfWeek" && caseCount == members.Count && members.Count > 0 && sw.FindOutput("default") != null,
					scope $"session 37 switch: a Switch on DayOfWeek with one output per member ({caseCount} of {members.Count}) and Default");
				SelfTestCheck(valueLink != null && valueLink.From == get.Result, "session 37 switch: the dragged output is wired to the Switch's Value");
				BeginEdit();
				mg.Graph.Connect(show.Then, sw.ExecIn);
				CommitCurrent();
				mSessionWait = 3;
			case 5:
				SelfTestCheck(doc.Text.Contains("switch (mDay)") && doc.Text.Contains("case .Friday:"), "session 37 switch: the Beef is `switch (mDay) { case .Sunday: ... }`");
				if (!doc.Text.Contains("case .Friday:"))
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] text: {doc.Text}");
				let mg = SessionOpen(mSessionPlan);
				let show = FindNodeOf(mg.Graph, .Call, "Show");
				if (show != null)
					CurrentTab.SelectOnly(show.Id);
				SessionFrameSelection();
				mSessionPinPanned = false;
			case 6:
				mSessionStep--;
				if (!mSessionPinPanned)
				{
					// The frame lands a frame later; then the node moves up so all of it is above the bottom panel.
					mSessionPinPanned = true;
					CurrentTab.ZoomLevel -= 2;
					mSessionWait = 3;
					return false;
				}
				if (SelfTestShot("pins-values"))
					mSessionStep++;
			case 7:
				// The dropdown, open on its first frame.
				let mg = SessionOpen(mSessionPlan);
				let show = FindNodeOf(mg.Graph, .Call, "Show");
				mGraphPanel.mPinEditor.SelfTestOpenPin = FirstPinOf(show).Id;
			case 8:
				mSessionStep--;
				if (SelfTestShot("pins-enum-open"))
					mSessionStep++;
			case 9:
				// A number the type cannot hold typed into `level` (uint8): the frame turns red.
				mGraphPanel.mPinEditor.SelfTestOpenPin = 0;
				mGraphPanel.mPinEditor.SelfTestClose = true;
				let mg = SessionOpen(mSessionPlan);
				let show = FindNodeOf(mg.Graph, .Call, "Show");
				for (let p in show.Inputs)
					if (p.Name != "target" && p.TypeName == "uint8")
						mGraphPanel.mPinEditor.SelfTestType(p.Id, "300");
			case 10:
				mSessionStep--;
				if (SelfTestShot("pins-refuse"))
					mSessionStep++;
			case 11:
				mGraphPanel.mPinEditor.SelfTestRelease();
				let mg = SessionOpen(mSessionPlan);
				let sw = FindNodeOf(mg.Graph, .Switch);
				if (sw != null)
					CurrentTab.SelectOnly(sw.Id);
				SessionFrameSelection();
			case 12:
				mSessionStep--;
				if (SelfTestShot("pins-switch"))
					mSessionStep++;
			default:
				mGraphPanel.mPinEditor.SelfTestRelease();
				while (doc.UndoDepth > mSessionPinDepth)
					doc.Undo();
				SelfTestCheck(doc.Text == mSessionPinBefore, "session 37 pins: undone, the file is as before");
				SaveAll();
				return true;
			}
			return false;
		}

		MethodGraph SessionOpen2(SourceDocument doc, StringView key)
		{
			let mg = (doc != null) ? doc.FindMethod(key) : null;
			if (mg != null)
				OpenTab(mg);
			return CurrentMethod;
		}

		/// Like SessionPick, but by category part and label part (a catalog row's label is not known).
		bool SessionPickIn(Pin pin, StringView category, StringView labelPart, float x, float y)
		{
			let tab = CurrentTab;
			if (tab == null)
				return false;
			OpenNodeMenu(tab, .(x, y), (pin != null) ? pin.Id : 0);
			mNodeMenu.OpenRequested = false;
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.SelfTestRows(labelPart, rows);
			NodeItem found = null;
			for (let it in rows)
				if (it.Category.Contains(category) && it.Label.Contains(labelPart))
				{
					// Get and Set rows tie on score: the order between them is not defined, Get is the one wanted.
					if (found == null || (!found.Label.StartsWith("Get") && it.Label.StartsWith("Get")))
						found = it;
				}
			if (found == null)
			{
				String seen = scope .();
				for (let it in rows)
					seen.AppendF(" [{} / {}]", it.Category, it.Label);
				SelfTestCheck(false, scope $"session: the Node menu offers no '{labelPart}' under '{category}' (search rows:{seen})");
				return false;
			}
			NodeItem copy = scope .();
			copy.CopyFrom(found);
			ExecuteAction(copy);
			return true;
		}

		/// Session 24: a Construct is picked onto Ping's Receiver, set to `scope`: the file gets
		/// `scope Greeter(...)` and compiles; with its Type cleared (`.`) nothing can be written, so
		/// the Construct shows an error and the file keeps its text.
		bool SessionScopeSteps()
		{
			let sub = mSessionSub++;
			let doc = SessionDoc;
			switch (sub)
			{
			case 0:
				let mg = SessionOpen(mSessionHello);
				let ping = (mg != null) ? FindNodeOf(mg.Graph, .Call, "Ping") : null;
				bool picked = ping != null && ping.FindInput("target") != null && SessionPick(ping.FindInput("target"), "Construct Greeter  (new)", 400, 200);
				SelfTestCheck(picked, "session 24 no silent writes: Construct Greeter (new) picked onto Ping's Receiver");
				if (!picked)
					break;
				mSessionWait = 3;
				return false;
			case 1:
				let mg = SessionOpen(mSessionHello);
				let con = FindNodeOf(mg.Graph, .Construct, "Greeter");
				if (con == null)
				{
					SelfTestCheck(false, "session 24 no silent writes: no Construct Greeter in the Hello Sheet");
					break;
				}
				BeginEdit();
				con.Alloc.Set("scope");
				con.Edited = true;
				CommitCurrent();
				mSessionWait = 3;
				return false;
			case 2:
				SelfTestCheck(doc.Text.Contains("scope Greeter(") && !doc.Text.Contains("new Greeter("), "session 24 no silent writes: the Construct set to scope is written (`scope Greeter(...)`)");
				SaveAll();
				Compile();
				return false;
			case 3:
				if (SessionBuildRunning)
				{
					mSessionSub--;
					return false;
				}
				mSessionWait = 5;
				return false;
			case 4:
				let st = SessionState;
				SelfTestCheck(st == .Good, scope $"session 24 no silent writes: `scope Greeter(...)` into the Receiver compiles, indicator green ({st})");
				let mg = SessionOpen(mSessionHello);
				let con = FindNodeOf(mg.Graph, .Construct, "Greeter");
				if (con == null)
					break;
				BeginEdit();
				con.Text.Set(".");
				con.Result.TypeName.Clear();
				NodeFactory.ConstructResultType(con.Text, con.IsArray, con.Result.TypeName);
				con.Edited = true;
				CommitCurrent();
				mSessionWait = 3;
				return false;
			case 5:
				let mg = SessionOpen(mSessionHello);
				let con = FindNodeOf(mg.Graph, .Construct, ".");
				SelfTestCheck(con != null && mg.Graph.Errors.Count == 1 && mg.Graph.Errors[0].NodeId == con.Id && doc.Text.Contains("scope Greeter("),
					scope $"session 24 no silent writes: a type-less Construct as a Receiver shows an error on the node and the file keeps its text (node {con != null}, errors {mg.Graph.Errors.Count}, on node {(con != null) ? SessionNodeErrorCount(mg, con.Id) : -1}, wired text {doc.Text.Contains("scope Greeter(")}; first error on node {(mg.Graph.Errors.Count > 0) ? mg.Graph.Errors[0].NodeId : -1} (con {(con != null) ? con.Id : -1}): {(mg.Graph.Errors.Count > 0) ? mg.Graph.Errors[0].Message : ""})");
				if (con != null)
					CurrentTab.SelectOnly(con.Id);
				return false;
			case 6:
				if (mShotStart < 0)
					SessionFrameSelection();
				if (!SelfTestShot("scope-error"))
				{
					mSessionSub--;
					return false;
				}
				while (doc.UndoDepth > 0 && doc.Text != mSessionSaved)
					doc.Undo();
				SaveAll();
			}
			mSessionSub = 0;
			return true;
		}

		static int CtorCount(VisualBeef.Syntax.Member type)
		{
			int n = 0;
			if (type.Members != null)
				for (let m in type.Members)
					if (m.Kind == .Method && m.IsCtor && !m.IsStatic)
						n++;
			return n;
		}

		/// Before a capture: the selected node in the middle of the canvas at the normal zoom, no
		/// toasts from earlier steps over it, no scratch path in the status bar.
		void SessionFrameSelection()
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			Notify.DismissToasts();
			mStatus.Clear();
			if (tab == null || mg == null || tab.SelectedNodes.IsEmpty)
				return;
			let n = mg.Graph.FindNode(tab.SelectedNodes[0]);
			if (n == null)
				return;
			tab.ZoomLevel = Canvas.DefaultZoomLevel;
			tab.CenterOn(n.X + 100, n.Y + 40);
			tab.NeedsFocus = false;
		}

		int mSessionSub;
		String mSessionLocals = new .() ~ delete _;

		/// Node errors as the canvas draws them (GetNodeDiagnostics): all of them, or 1 / 0 for one node.
		int SessionNodeErrorCount(MethodGraph mg, int32 nodeId = -1)
		{
			Dictionary<int32, String> errs = scope .();
			Dictionary<int32, String> warns = scope .();
			defer { for (let v in errs.Values) delete v; for (let v in warns.Values) delete v; }
			GetNodeDiagnostics(mg, errs, warns);
			if (nodeId >= 0)
				return errs.ContainsKey(nodeId) ? 1 : 0;
			return errs.Count;
		}

		/// Session 17b (between the compile error and its fix): the print with the compile error is
		/// deleted, no node shows its error, Problems says the node is gone, a new print placed at
		/// the same place shows no error once its value is typed; three undos bring the old print back
		/// with its error.
		/// One action per call; true when done.
		bool SessionNodeErrorSteps()
		{
			let sub = mSessionSub++;
			let mg = SessionOpen(mSessionHello);
			switch (sub)
			{
			case 0:
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SelfTestCheck(print != null && SessionNodeErrorCount(mg, print.Id) == 1, scope $"session 17b node errors: before, the error is on the print ({SessionNodeErrorCount(mg)} node error(s))");
				SelfTestFit();
				if (print != null)
					CurrentTab.SelectOnly(print.Id);
				return false;
			case 1:
				if (mShotStart < 0)
					SessionFrameSelection();
				if (!SelfTestShot("nodeerr-before"))
				{
					mSessionSub--;
					return false;
				}
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				CurrentTab.SelectOnly(print.Id);
				DeleteSelection(CurrentTab);
				return false;
			case 2:
				SelfTestCheck(FindNodeOf(mg.Graph, .Call, "WriteLine") == null && !SessionDoc.Text.Contains("undefinedThing"), "session 17b node errors: Del removed the print with the error");
				SelfTestCheck(SessionNodeErrorCount(mg) == 0, scope $"session 17b node errors: after the delete no node shows its error ({SessionNodeErrorCount(mg)} node error(s))");
				int gone = 0;
				if (mBuild != null)
					for (let m in mBuild.Messages)
						if (m.IsError && DiagnosticNodeGone(m))
							gone++;
				SelfTestCheck(gone >= 1, scope $"session 17b node errors: Problems marks the message as about a deleted node ({gone})");
				SessionPick(mg.Graph.Entry.Then, "Print", 320, 0);
				return false;
			case 3:
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SelfTestCheck(print != null, "session 17b node errors: a new print placed from the Node menu where the old one was");
				// Its empty pin is its own (checker) error, not the compile error: type a value.
				if (print != null)
					SessionSetPin(print, FirstValueInput(print), "\"Hi\"");
				return false;
			case 4:
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SelfTestCheck(SessionDoc.Text.Contains("Console.WriteLine(\"Hi\");") && mg.Graph.Errors.IsEmpty, "session 17b node errors: the new print is written with its value");
				SelfTestCheck(SessionNodeErrorCount(mg) == 0 && (print == null || SessionNodeErrorCount(mg, print.Id) == 0),
					scope $"session 17b node errors: the new print shows no error, nor does any other node ({SessionNodeErrorCount(mg)})");
				SelfTestFit();
				if (print != null)
					CurrentTab.SelectOnly(print.Id);
				return false;
			case 5:
				if (mShotStart < 0)
					SessionFrameSelection();
				if (!SelfTestShot("nodeerr-after-add"))
				{
					mSessionSub--;
					return false;
				}
				SessionUndo(false);
				return false;
			case 6, 7:
				SessionUndo(false);
				return false;
			case 8:
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SelfTestCheck(SessionDoc.Text.Contains("Console.WriteLine(undefinedThing);") && print != null && SessionNodeErrorCount(mg, print.Id) == 1,
					"session 17b node errors: three undos bring the deleted print back with its own error (until the next compile)");
			}
			mSessionSub = 0;
			return true;
		}

		/// Session 21: `let a = scope Other();` and `Other b = .();` in a new function; the
		/// Construct's type and b's Variable Type are changed the way Properties does it; the
		/// nodes' pins and colours follow at once; undo restores; the file is left as saved.
		bool SessionLocalTypeSteps()
		{
			let sub = mSessionSub++;
			let doc = SessionDoc;
			switch (sub)
			{
			case 0:
				int at = doc.Text.IndexOf("void Ping()");
				if (at < 0)
				{
					SelfTestCheck(false, "session 21 local types: no Ping() to insert before");
					break;
				}
				int lineStart = StringView(doc.Text, 0, at).LastIndexOf('\n') + 1;
				String text = scope .(doc.Text);
				text.Insert(lineStart, "\t\tpublic void MakeLocals()\n\t\t{\n\t\t\tlet a = scope Other();\n\t\t\tOther b = .();\n\t\t\tConsole.WriteLine(a.mValue + b.mValue);\n\t\t}\n\n");
				doc.ApplyText(text);
				let mg = doc.FindMethod("Greeter.MakeLocals()");
				SelfTestCheck(mg != null, "session 21 local types: MakeLocals() with two locals");
				if (mg == null)
					break;
				mSessionLocals.Set(mg.Key);
				SessionOpen(mSessionLocals);
				return false;
			case 1:
				let mg = SessionOpen(mSessionLocals);
				let a = FindNodeOf(mg.Graph, .LocalVar, "a");
				SelfTestCheck(a != null && a.FindOutput("variable").TypeName == "Other", "session 21 local types: Local a is an Other");
				{
					let plainCon = FindNodeOf(mg.Graph, .Construct, ".");
					String conSub = scope .();
					if (plainCon != null)
						GraphPanel.LifetimeSubtitle(plainCon, conSub);
					SelfTestCheck(plainCon != null && conSub == "value", scope $"session 21 local types: a plain `.()` Construct says \"{conSub}\", not a custom allocator");
				}
				SelfTestFit();
				if (a != null)
					CurrentTab.SelectOnly(a.Id);
				return false;
			case 2:
				if (mShotStart < 0)
					SessionFrameSelection();
				if (!SelfTestShot("local-before"))
				{
					mSessionSub--;
					return false;
				}
				// Properties > Lifetime > Type on the Construct node (what its type picker does).
				let mg = SessionOpen(mSessionLocals);
				let con = FindNodeOf(mg.Graph, .Construct, "Other");
				if (con == null)
				{
					SelfTestCheck(false, "session 21 local types: no Construct node");
					break;
				}
				BeginEdit();
				con.Text.Set("GameBase");
				con.Result.TypeName.Clear();
				NodeFactory.ConstructResultType(con.Text, con.IsArray, con.Result.TypeName);
				con.Edited = true;
				CommitCurrent();
				return false;
			case 3:
				let mg = SessionOpen(mSessionLocals);
				let a = FindNodeOf(mg.Graph, .LocalVar, "a");
				StringView aType = (a != null) ? a.FindOutput("variable").TypeName : "";
				SelfTestCheck(doc.Text.Contains("let a = scope GameBase();") && aType == "GameBase", scope $"session 21 local types: the Construct type changed to GameBase; Local a's pin follows ({aType})");
				SelfTestCheck(a != null && mGraphPanel.[Friend]HeaderFor(mg.Graph, a) == Theme.VariableHeader("GameBase"), "session 21 local types: Local a's header has the GameBase colour");
				if (a != null)
					CurrentTab.SelectOnly(a.Id);
				return false;
			case 4:
				if (mShotStart < 0)
					SessionFrameSelection();
				if (!SelfTestShot("local-after"))
				{
					mSessionSub--;
					return false;
				}
				// Properties > Variable Type on b.
				let mg = SessionOpen(mSessionLocals);
				let b = FindNodeOf(mg.Graph, .LocalVar, "b");
				if (b == null)
				{
					SelfTestCheck(false, "session 21 local types: no Local b");
					break;
				}
				BeginEdit();
				b.Text2.Set("GameBase");
				b.Edited = true;
				CommitCurrent();
				return false;
			case 5:
				let mg = SessionOpen(mSessionLocals);
				let b = FindNodeOf(mg.Graph, .LocalVar, "b");
				StringView bType = (b != null) ? b.FindOutput("variable").TypeName : "";
				SelfTestCheck(doc.Text.Contains("GameBase b = .();") && bType == "GameBase", scope $"session 21 local types: b's Variable Type changed to GameBase; its pin follows ({bType})");
				SessionUndo(false);
				return false;
			case 6:
				SessionUndo(false);
				return false;
			case 7:
				let mg = SessionOpen(mSessionLocals);
				let a = FindNodeOf(mg.Graph, .LocalVar, "a");
				let b = FindNodeOf(mg.Graph, .LocalVar, "b");
				SelfTestCheck(doc.Text.Contains("let a = scope Other();") && doc.Text.Contains("Other b = .();") && a != null && b != null &&
					a.FindOutput("variable").TypeName == "Other" && b.FindOutput("variable").TypeName == "Other", "session 21 local types: two undos restore Other on both locals");
				SessionUndo(false);
				return false;
			case 8:
				SelfTestCheck(doc.Text == mSessionSaved, "session 21 local types: one more undo leaves the file as saved");
				SaveAll();
			}
			mSessionSub = 0;
			return true;
		}

		String mSessionHotkeyBefore = new .() ~ delete _;
		String mSessionPreBubble = new .() ~ delete _;
		int mSessionBubbleDepth;
		List<int32> mSessionOldIds = new .() ~ delete _;
		ImVec2 mSessionHotkeyAt;
		int mSessionUndos;
		int mSessionRedos;
		int mSessionHotkeyDepth;
		int mSessionHotkeyNodes;

		[CLink] static extern void ImGuiIO_AddKeyEvent(void* io, int32 key, bool down);

		/// A letter key down / up as the platform layer reports it (the Sheet reads it on the next frame).
		void SelfTestKey(char8 letter, bool down)
		{
			ImGuiIO_AddKeyEvent(Gui.igGetIO_Nil(), NodeMenu.cKeyA + (int32)(letter - 'A'), down);
		}

		/// `hotkey-menu`: the Node menu on the open Sheet, its popup at the canvas's top-left corner (captures:
		/// the Favorites group with the key hints).
		void SelfTestHotkeyMenu()
		{
			let tab = CurrentTab;
			if (tab == null)
			{
				SelfTestCheck(false, "hotkey-menu: no Sheet open");
				return;
			}
			OpenNodeMenu(tab, .(200, 200), 0);
			mNodeMenu.SelfTestPopupPos = .(tab.CanvasOrigin.x + 60 * Look.Scale, tab.CanvasOrigin.y + 12 * Look.Scale);
			mNodeMenu.SelfTestPlace = true;
			SelfTestCheck(true, "Node menu opened for the hotkey captures");
		}

		/// `hotkey-capture:<label>`: the key-capture control of the open Node menu waits on the
		/// favorite with that label (captures).
		void SelfTestHotkeyCapture(StringView label)
		{
			for (let f in NodePrefs.Favorites)
			{
				if (NodeHotkeys.LabelOf(f) == label)
				{
					mNodeMenu.StartCapture(f);
					SelfTestCheck(true, scope $"key capture on {label}");
					return;
				}
			}
			SelfTestCheck(false, scope $"hotkey-capture: no favorite '{label}'");
		}

		/// Second process: the class made by `session` opens unchanged and the indicator is green.
		bool SelfTestReloadCheck()
		{
			if (mSessionWait > 0)
			{
				mSessionWait--;
				return false;
			}
			let step = mSessionStep++;
			switch (step)
			{
			case 0:
				mSessionPath.Clear();
				mSessionPath.AppendF("{}{1}src{1}Greeter.bf", mProjectRoot, Path.DirectorySeparatorChar);
				String disk = scope .();
				File.ReadAllText(mSessionPath, disk, true).IgnoreError();
				let doc = OpenFile(mSessionPath, false);
				SelfTestCheck(doc != null && doc.Text == disk && !doc.Modified, "reload-check: Greeter.bf opens in a new editor process, text as on disk, not dirty");
				if (doc == null)
					return true;
				int graphs = 0;
				int errors = 0;
				for (let mg in doc.Methods)
					if (mg.Graphable)
					{
						graphs++;
						String body = scope .();
						doc.GenerateMethodBody(mg, body);
						errors += mg.Graph.Errors.Count;
						if (mg.Method.Name == "Hello")
							OpenTab(mg);
					}
				SelfTestCheck(graphs >= 4 && errors == 0, scope $"reload-check: {graphs} function graphs, {errors} errors");
				mSessionWait = 30; // let the compile-status hash be taken
			case 1:
				let st = SessionState;
				SelfTestCheck(st == .Good, scope $"reload-check: indicator green after restart, nothing changed ({st})");
				SelfTestFit();
			case 2:
				mSessionStep--;
				if (SelfTestShot("reload-green"))
					mSessionStep++;
			case 3:
				return true;
			}
			return false;
		}

		/// `override:<Type>:<Member>`: FUNCTIONS > Override > that member on a type of the current file.
		void SelfTestOverride(StringView spec)
		{
			int colon = spec.IndexOf(':');
			let doc = Doc;
			let typeName = (colon > 0) ? spec.Substring(0, colon) : spec;
			let member = (colon > 0) ? spec.Substring(colon + 1) : "";
			let type = (doc != null) ? FindTypeIn(doc, typeName) : null;
			if (type == null)
			{
				SelfTestCheck(false, scope $"override {spec}: no such type in the current file");
				return;
			}
			for (let m in ClassInfoFor(doc, type).Overridable)
			{
				if (m.Name != member)
					continue;
				InheritedMember copy = scope .();
				copy.Kind = m.Kind;
				copy.Name.Set(m.Name);
				copy.OwnerType.Set(m.OwnerType);
				copy.ReturnType.Set(m.ReturnType);
				for (let s in m.ParamTypes) copy.ParamTypes.Add(new String(s));
				for (let s in m.ParamNames) copy.ParamNames.Add(new String(s));
				for (let s in m.ParamModifiers) copy.ParamModifiers.Add(new String(s));
				copy.IsAbstract = m.IsAbstract;
				copy.IsVirtual = m.IsVirtual;
				copy.FromInterface = m.FromInterface;
				copy.HasSetter = m.HasSetter;
				copy.Visibility = m.Visibility;
				AddOverrideNow(doc, typeName, copy);
				SelfTestCheck(true, scope $"override {spec} added");
				return;
			}
			SelfTestCheck(false, scope $"override {spec}: not in the Override list");
		}

		/// `newclass:<Parent>:<Interface>`: the Project Browser's + Add > New Class dialog, open, with
		/// a parent and an interface picked (for captures; the dialog stays open).
		void SelfTestNewClass(StringView spec)
		{
			int colon = spec.IndexOf(':');
			String src = scope .();
			src.AppendF("{}{}src", mProjectRoot, Path.DirectorySeparatorChar);
			StartNewAsset(.Class, src);
			mCBNewParent.Set((colon >= 0) ? spec.Substring(0, colon) : spec);
			if (colon >= 0 && colon + 1 < spec.Length)
				mCBNewInterfaces.Add(new String(spec.Substring(colon + 1)));
			SelfTestCheck(true, scope $"New Class dialog: {spec}");
		}

		static void WiredTo(MethodGraph mg, Node make, String res)
		{
			if (mg == null || make == null || make.Result == null)
				return;
			let link = mg.Graph.FindLinkFrom(make.Result);
			if (link != null)
				res.AppendF("{}.{}", link.To.Owner.Text, link.To.Name);
		}
		/// `setoncreate:<Type>:<var>;<var>` marks variables of a type of the current file "Set on create".
		void SelfTestSetOnCreate(StringView spec)
		{
			int colon = spec.IndexOf(':');
			let doc = Doc;
			if (colon < 0 || doc == null)
			{
				SelfTestCheck(false, scope $"setoncreate {spec}: needs <Type>:<var>;<var>");
				return;
			}
			let typeName = spec.Substring(0, colon);
			bool all = true;
			for (let v in spec.Substring(colon + 1).Split(';'))
			{
				let type = FindTypeIn(doc, typeName);
				let field = (type != null) ? FindField(type, v) : null;
				all = all && field != null && doc.SetFieldSetOnCreate(type, field, true);
			}
			SelfTestCheck(all, scope $"setoncreate {spec} {doc.LastError}");
		}

		/// `construct:<Type>` places "Construct <Type>" from the Node menu on the current graph.
		void SelfTestConstruct(StringView typeName)
		{
			bool ok = SessionPick(null, scope $"Construct {typeName}", 300, 200);
			SelfTestCheck(ok, scope $"construct {typeName}");
		}

		/// `addctor:<Type>:<params>` adds a constructor to a type of the current file;
		/// `addctor-dialog:<Type>:<params>` opens the Add Constructor dialog with those parameters
		/// (the first chaining choice picked), left open for a capture.
		void SelfTestAddCtor(StringView spec, bool dialog)
		{
			int colon = spec.IndexOf(':');
			let typeName = (colon > 0) ? spec.Substring(0, colon) : spec;
			// ';' stands for ", " (the check list is comma separated).
			String pars = scope .((colon > 0) ? spec.Substring(colon + 1) : "");
			pars.Replace(";", ",");
			let doc = Doc;
			let type = (doc != null) ? FindTypeIn(doc, typeName) : null;
			if (type == null)
			{
				SelfTestCheck(false, scope $"addctor {spec}: no such type in the current file");
				return;
			}
			if (dialog)
			{
				OpenAddConstructor(typeName);
				mParamsBuf.Set(pars);
				mCtorChain = 1;
				SelfTestCheck(true, scope $"Add Constructor dialog: {typeName} ({pars})");
				return;
			}
			String key = scope .();
			bool ok = doc.AddConstructor(type, "public", pars, "", key);
			if (ok)
			{
				let mg = doc.FindMethod(key);
				if (mg != null)
					OpenTab(mg);
			}
			SelfTestCheck(ok, scope $"addctor {typeName} ({pars}) {doc.LastError}");
		}

		/// `theme:0` / `theme:1`: Dark / Darker (Preferences > Appearance).
		void SelfTestTheme(StringView v)
		{
			Prefs.Theme = (v == "1") ? 1 : 0;
			Look.Darker = Prefs.Theme == 1;
			Look.Apply(Look.Scale);
			SelfTestCheck(true, scope $"theme {Prefs.Theme}");
		}

		/// `panel:<id>`: focuses a dock panel (browser, properties, outline, log, problems, source, find).
		void SelfTestPanel(StringView v)
		{
			switch (v)
			{
			case "browser": Panels.Focus(Panels.ProjectBrowserId);
			case "properties": Panels.Focus(Panels.PropertiesId);
			case "outline": Panels.Focus(Panels.OutlineId);
			case "log": Panels.Focus(Panels.OutputLogId);
			case "problems": Panels.Focus(Panels.CompilerResultsId);
			case "source": Panels.Focus(Panels.BeefSourceId);
			case "find": Panels.Focus(Panels.FindResultsId);
			default: SelfTestCheck(false, scope $"panel {v}: unknown");
			}
		}

		int mIdsPhase;
		static readonly StringView[?] sIdsSearches = .("", "", "IO", "System", "File", "e", "Get", "Math");

		/// `ids`: opens the Node menu on the open graph and walks searches that produce repeated
		/// category names; every row's ImGui ID must be distinct in its frame (0 duplicates).
		bool SelfTestIds()
		{
			if (mIdsPhase == 0)
			{
				if (CurrentTab == null)
				{
					let player = SelfTestDocWithType("Player");
					if (player != null)
						for (let m in player.Methods)
							if (m.Graphable && mIdsPhase == 0)
							{
								OpenTab(m);
								mIdsPhase = 1;
							}
					if (mIdsPhase == 0 && CurrentTab == null)
					{
						SelfTestCheck(false, "ids: no graph to open the Node menu on");
						return true;
					}
				}
				mIdsPhase = 1;
				OpenNodeMenu(CurrentTab, .(200, 200), 0);
				mNodeMenu.AuditIds = true;
				mSelfTestWait = 6;
				return false;
			}
			int idx = mIdsPhase - 1;
			if (idx > 0)
			{
				SelfTestCheck(mNodeMenu.IdDuplicates == 0, scope $"ids: Node menu search '{sIdsSearches[idx - 1]}' {mNodeMenu.IdsSeen} rows, {mNodeMenu.IdDuplicates} conflicting IDs");
				mNodeMenu.IdDuplicates = 0;
				mNodeMenu.IdsSeen = 0;
			}
			if (idx >= sIdsSearches.Count)
			{
				mNodeMenu.AuditIds = false;
				mNodeMenu.CloseRequested = true;
				mIdsPhase = 0;
				return true;
			}
			mNodeMenu.AuditOpenDepth = (idx == 1) ? 6 : 0; // the second "" search draws the Library tree open
			mNodeMenu.SelfTestSetSearch(sIdsSearches[idx]);
			mIdsPhase++;
			mSelfTestWait = 4;
			return false;
		}

		/// `menu-pin`: opens the Node menu as a drag off the first value output pin of the open graph
		/// does (a pin context), for a capture of the Context Sensitive checkbox enabled.
		void SelfTestMenuPin()
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			Pin pin = null;
			if (mg != null)
				for (let n in mg.Graph.Nodes)
					for (let p in n.Outputs)
						if (pin == null && p.Kind == .Data)
							pin = p;
			if (tab == null || pin == null)
			{
				SelfTestCheck(false, "menu-pin: no graph or no value output pin");
				return;
			}
			let spawn = ImVec2(pin.Owner.X + 300, pin.Owner.Y - 40);
			OpenNodeMenu(tab, spawn, pin.Id);
			String shots = scope .();
			if (Environment.GetEnvironmentVariable("VB_SHOTS", shots) case .Ok && !shots.IsEmpty)
			{
				// Captures: the release point in the middle of the canvas, the menu just beside it.
				tab.CenterOn(spawn.x, spawn.y);
				mNodeMenu.SelfTestPos = .(tab.CanvasOrigin.x + tab.CanvasSize.x * 0.5f + 30 * Look.Scale, tab.CanvasOrigin.y + tab.CanvasSize.y * 0.5f - 20 * Look.Scale);
			}
			SelfTestCheck(true, "node menu opened from a pin");
		}

		/// `menu:<pin>`: opens the Node menu on the canvas (`menu:` empty canvas) for a capture;
		/// `menu-close` closes it.
		void SelfTestMenu(bool open)
		{
			let tab = CurrentTab;
			if (!open)
			{
				mNodeMenu.CloseRequested = true;
				return;
			}
			if (tab == null)
			{
				SelfTestCheck(false, "menu: no graph open");
				return;
			}
			OpenNodeMenu(tab, .(200, 200), 0);
			String shots = scope .();
			if (Environment.GetEnvironmentVariable("VB_SHOTS", shots) case .Ok && !shots.IsEmpty)
				mNodeMenu.SelfTestPos = .(300 * Look.Scale, 130 * Look.Scale); // captures: a fixed place
			SelfTestCheck(true, "node menu opened");
		}
	}
}
