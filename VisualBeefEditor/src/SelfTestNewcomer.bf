using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;
using VisualBeef.Graph;
using VisualBeef.Catalog;
using VisualBeef.Debug;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=newcomer`: a first-time user's path from an empty folder, through the calls the UI
	/// makes: New Project, New Struct, New Interface (a function added to it), New Class implementing
	/// it, two variables (an owned List made here, an int with an initial value), a constructor with a
	/// parameter, a For Loop that prints, a function with an out parameter used from another one, a
	/// Branch on its bool, a Defer, a Construct with Set on create in Main and a call on its Receiver,
	/// Save All, close and reopen, Reload node / Reload Sheet, undo / redo and a Release compile.
	/// Observations a newcomer would trip over are logged as `[NEWCOMER] ...` lines next to the
	/// `[SELFTEST] ok / FAIL` checks.
	extension EditorApp
	{
		int mNcStep;
		int mNcWait;
		String mNcSrc = new .() ~ delete _;
		String mNcCountUp = new .() ~ delete _;
		String mNcTryGet = new .() ~ delete _;
		String mNcRun = new .() ~ delete _;
		String mNcSaved = new .() ~ delete _;

		void NcNote(StringView text) => Notify.Log(.Info, "SelfTest", scope $"[NEWCOMER] {text}");

		SourceDocument NcDoc(StringView name)
		{
			return OpenFile(scope $"{mNcSrc}{Path.DirectorySeparatorChar}{name}.bf", false);
		}

		MethodGraph NcMethod(StringView file, StringView key)
		{
			let doc = NcDoc(file);
			let mg = (doc != null) ? doc.FindMethod(key) : null;
			if (mg != null)
				OpenTab(mg);
			return mg;
		}

		MethodGraph NcByName(StringView file, StringView name)
		{
			let doc = NcDoc(file);
			if (doc == null)
				return null;
			for (let mg in doc.Methods)
				if (mg.Graphable && mg.Method.Name == name)
				{
					OpenTab(mg);
					return mg;
				}
			return null;
		}

		/// The Node menu at a pin (null: empty canvas): every label containing `filter`.
		void NcLabels(Pin pin, StringView filter, String outLabels)
		{
			let tab = CurrentTab;
			if (tab == null)
				return;
			OpenNodeMenu(tab, .(0, 0), (pin != null) ? pin.Id : 0);
			mNodeMenu.OpenRequested = false;
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.SelfTestRows(filter, rows);
			for (let it in rows)
				outLabels.AppendF("{}{}", outLabels.IsEmpty ? "" : " | ", it.Label);
		}

		/// Picks the Node menu row whose label is exactly `label` (or starts with it when `prefix`).
		bool NcPick(Pin pin, StringView label, float x, float y, bool prefix = false)
		{
			let tab = CurrentTab;
			if (tab == null)
				return false;
			OpenNodeMenu(tab, .(x, y), (pin != null) ? pin.Id : 0);
			mNodeMenu.OpenRequested = false;
			NodeItem found = null;
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.SelfTestRows(label, rows);
			for (let it in rows)
				if (prefix ? it.Label.StartsWith(label) : it.Label == label)
				{
					found = it;
					break;
				}
			if (found == null)
			{
				SelfTestCheck(false, scope $"newcomer: the Node menu offers no '{label}'");
				return false;
			}
			NodeItem copy = scope .();
			copy.CopyFrom(found);
			ExecuteAction(copy);
			return true;
		}

		void NcErrors(MethodGraph mg, StringView what)
		{
			if (mg == null)
				return;
			for (let e in mg.Graph.Errors)
				NcNote(scope $"{what}: graph error on node {e.NodeId}: {e.Message}");
		}

		void NcDumpPins(Node n, StringView what)
		{
			if (n == null)
				return;
			String s = scope .();
			for (let p in n.Inputs)
				s.AppendF(" in:{}({}:{})", p.Name, p.Label, p.TypeName);
			for (let p in n.Outputs)
				s.AppendF(" out:{}({}:{})", p.Name, p.Label, p.TypeName);
			NcNote(scope $"{what}: {n.Kind} '{n.Text}'{s}");
		}

		bool SelfTestNewcomer()
		{
			if (mNcWait > 0)
			{
				mNcWait--;
				return false;
			}
			let step = mNcStep++;
			switch (step)
			{
			case 0:
				CreateProject("Mod", 0, mProjectRoot);
				mNcSrc.Clear();
				mNcSrc.AppendF("{}{}Mod{}src", mProjectRoot, Path.DirectorySeparatorChar, Path.DirectorySeparatorChar);
				SelfTestCheck(File.Exists(scope $"{mNcSrc}{Path.DirectorySeparatorChar}Program.bf"), "newcomer 1: File > New Project 'Mod' wrote Mod/src/Program.bf");
			case 1:
				ResetCreateTypeOptions();
				CreateAsset(.Struct, mNcSrc, "Point");
				ResetCreateTypeOptions();
				CreateAsset(.Interface, mNcSrc, "IGreeter");
				let p = NcDoc("Point");
				let i = NcDoc("IGreeter");
				SelfTestCheck(p != null && i != null, "newcomer 2: New Struct Point and New Interface IGreeter");
				if (p != null) NcNote(scope $"Point.bf:\n{p.Text}");
				if (i != null) NcNote(scope $"IGreeter.bf:\n{i.Text}");
			case 2:
				let doc = NcDoc("IGreeter");
				let type = FindTypeIn(doc, "IGreeter");
				String key = scope .();
				bool ok = doc.AddMethod(type, "void", "Greet", "String name", key);
				SelfTestCheck(ok, scope $"newcomer 3: FUNCTIONS + Greet(String name) on the interface {doc.LastError}");
				NcNote(scope $"IGreeter.bf after Add Function:\n{doc.Text}");
				let mg = doc.FindMethod(key);
				NcNote(scope $"interface function graphable={(mg != null && mg.Graphable)}");
				SaveAll();
			case 3:
				ResetCreateTypeOptions();
				mCBNewInterfaces.Add(new String("IGreeter"));
				mCBNewImplement = true;
				CreateAsset(.Class, mNcSrc, "Greeter");
				let doc = NcDoc("Greeter");
				SelfTestCheck(doc != null && doc.Text.Contains("IGreeter"), "newcomer 4: New Class Greeter with Interfaces > IGreeter and Implement missing members");
				if (doc != null)
					NcNote(scope $"Greeter.bf:\n{doc.Text}");
			case 4:
				let doc = NcDoc("Greeter");
				// Add Variable: List<int> mItems with the dialog's default ownership.
				for (let spec in StringView[2]("List<int>", "int"))
				{
					let t = MemberInit.TypeOf(spec, TypeService.Current);
					AddVarDefaults(t);
					MemberInit init = scope .();
					init.Retarget(mAddVarOwner, t);
					init.Owner = mAddVarOwner;
					init.ValueKind = .None;
					String name = scope .((spec == "int") ? "mCount" : "mItems");
					if (spec == "int")
					{
						init.ValueKind = .Literal;
						init.Value.Set("3");
					}
					NcNote(scope $"Add Variable {spec}: default ownership {mAddVarOwner}");
					bool ok = AddVariableChecked(doc, FindTypeIn(doc, "Greeter"), spec, name, init, false);
					SelfTestCheck(ok, scope $"newcomer 5: Add Variable {spec} {name} {doc.LastError}");
				}
				NcNote(scope $"Greeter.bf after variables:\n{doc.Text}");
			case 5:
				let doc = NcDoc("Greeter");
				String key = scope .();
				bool ok = doc.AddConstructor(FindTypeIn(doc, "Greeter"), "public", "int start", "", key);
				SelfTestCheck(ok, scope $"newcomer 6: Add Constructor (int start) {doc.LastError}");
				// Set on create on mCount: the create constructor asks for it.
				let type = FindTypeIn(doc, "Greeter");
				let field = FindField(type, "mCount");
				doc.LastError.Clear();
				bool soc = field != null && doc.SetFieldSetOnCreate(type, field, true);
				NcNote(scope $"Set on create mCount: {soc} '{doc.LastError}'");
				if (!soc)
				{
					// The newcomer's way out: a String variable set on create instead.
					let t = MemberInit.TypeOf("String", TypeService.Current);
					AddVarDefaults(t);
					MemberInit init = scope .();
					init.Retarget(.Reference, t);
					init.Owner = .Reference;
					bool ok2 = AddVariableChecked(doc, FindTypeIn(doc, "Greeter"), "String", "mName", init, true);
					SelfTestCheck(ok2, scope $"newcomer 6: Add Variable String mName (Reference) set on create {doc.LastError}");
				}
				NcNote(scope $"Greeter.bf after constructor + set on create:\n{doc.Text}");
			case 6:
				let doc = NcDoc("Greeter");
				doc.AddMethod(FindTypeIn(doc, "Greeter"), "void", "CountUp", "", mNcCountUp);
				{
					// TryGet through the Add Function dialog's controls: Return Type bool, one input
					// `value` whose Passing chooser is set to out (no typed parameter text).
					List<ParamRow> rows = scope .();
					defer { ClearAndDeleteItems!(rows); }
					ParamRow r = new .();
					r.Name.Set("value");
					r.Type.Set("int");
					rows.Add(r);
					List<StringView> passing = scope .();
					VisualBeef.Catalog.TypeSlotRules.PassingChoices(r.Type, false, r.Modifier, passing);
					String offered = scope .();
					for (let c in passing)
						offered.AppendF("{}{}", offered.IsEmpty ? "" : ", ", VisualBeef.Catalog.TypeSlotRules.PassingLabel(c));
					NcNote(scope $"Add Function > Inputs > Passing offers: {offered}");
					SelfTestCheck(offered == "value, out, ref, in", scope $"newcomer 9: the Passing chooser offers value, out, ref, in ({offered})");
					r.Modifier.Set("out");
					String pars = scope .();
					ParamRowsText(rows, pars);
					doc.AddMethod(FindTypeIn(doc, "Greeter"), "bool", "TryGet", pars, mNcTryGet);
					SelfTestCheck(doc.Text.Contains("public bool TryGet(out int value)"), "newcomer 9: Add Function with Passing out writes `bool TryGet(out int value)`");
				}
				doc.AddMethod(FindTypeIn(doc, "Greeter"), "void", "Run", "", mNcRun);
				SelfTestCheck(doc.FindMethod(mNcCountUp) != null && doc.FindMethod(mNcTryGet) != null && doc.FindMethod(mNcRun) != null,
					scope $"newcomer 7: functions CountUp, TryGet(out int value), Run ({mNcTryGet})");
				let mg = NcMethod("Greeter", mNcCountUp);
				String loops = scope .();
				NcLabels(mg.Graph.Entry.Then, "Loop", loops);
				NcNote(scope $"Node menu from the entry, 'Loop': {loops}");
				NcPick(mg.Graph.Entry.Then, "For Loop", 320, 0);
			case 7:
				let mg = NcMethod("Greeter", mNcCountUp);
				let loop = FindNodeOf(mg.Graph, .For);
				NcDumpPins(loop, "For Loop placed");
				if (loop == null)
					return true;
				NcPick(loop.FindOutput("body"), "Print", 640, 0, true);
			case 8:
				let mg = NcMethod("Greeter", mNcCountUp);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				NcDumpPins(print, "Print in the loop body");
				if (print == null)
					return true;
				let loop = FindNodeOf(mg.Graph, .For);
				// A newcomer wants the loop counter: the Counter pin (named i) is wired into the print.
				let index = loop.FindOutput("counter");
				SelfTestCheck(index != null && index.Label == "i" && index.TypeName == "int" && loop.FindInput("count") != null,
					"newcomer 8: the For Loop has a Counter output pin i (int) and a Count input pin");
				if (index != null)
				{
					BeginEdit();
					mg.Graph.Connect(index, FirstValueInput(print));
					CommitCurrent();
					NcNote("For Loop has a data output for its counter: wired into the print");
				}
				else
				{
					NcNote("For Loop has NO counter output: the newcomer must type the Beef loop variable 'i' into the print");
					SessionSetPin(print, FirstValueInput(print), "i");
				}
			case 9:
				let doc = NcDoc("Greeter");
				let mg = NcMethod("Greeter", mNcCountUp);
				NcErrors(mg, "CountUp");
				String body = scope .();
				doc.GenerateMethodBody(mg, body);
				NcNote(scope $"CountUp body:\n{body}");
				SelfTestCheck(body.Contains("for (int i = 0; i < 10; i++)") && body.Contains("Console.WriteLine(i);"), "newcomer 8: the wired counter is written as i");
				// TryGet: Set value = mCount, Return true.
				let tg = NcMethod("Greeter", mNcTryGet);
				NcDumpPins(tg.Graph.Entry, "TryGet entry");
				String sets = scope .();
				NcLabels(tg.Graph.Entry.Then, "value", sets);
				NcNote(scope $"Node menu in TryGet, 'value': {sets}");
				NcPick(tg.Graph.Entry.Then, "Set value", 320, 0);
			case 10:
				let tg = NcMethod("Greeter", mNcTryGet);
				let set = FindNodeOf(tg.Graph, .Set);
				NcDumpPins(set, "Set value");
				if (set == null)
					return true;
				SelfTestCheck(set.FindInput("target")?.Label == "Variable", "newcomer 9c: the Set of the parameter labels its pin Variable");
				SessionSetPin(set, FirstValueInput(set), "mCount");
			case 11:
				let tg = NcMethod("Greeter", mNcTryGet);
				let set = FindNodeOf(tg.Graph, .Set);
				NcPick(set?.Then, "Return", 640, 0);
			case 12:
				let tg = NcMethod("Greeter", mNcTryGet);
				let ret = FindNodeOf(tg.Graph, .Return);
				NcDumpPins(ret, "Return in TryGet");
				if (ret != null)
				{
					NcNote(scope $"Return value default '{ret.FindInput("value")?.Default}'");
					SelfTestCheck(ret.FindInput("value")?.Default == "false", "newcomer 9b: a Return placed in the bool TryGet starts with false");
					SessionSetPin(ret, ret.FindInput("value"), "true");
				}
			case 13:
				let doc = NcDoc("Greeter");
				let tg = NcMethod("Greeter", mNcTryGet);
				NcErrors(tg, "TryGet");
				String body = scope .();
				doc.GenerateMethodBody(tg, body);
				NcNote(scope $"TryGet body:\n{body}");
				// Properties > Inputs: the row reads back as out; Passing ref is written, then undone.
				{
					SyncParamRows(tg);
					bool outRow = mParamRows.Count == 1 && mParamRows[0].Modifier == "out";
					String before = scope .(doc.Text);
					bool applied = false;
					if (outRow)
					{
						mParamRows[0].Modifier.Set("ref");
						String pars = scope .();
						ParamsText(pars);
						applied = ApplySignature(doc, tg.Method, "bool", pars) && doc.Text.Contains("public bool TryGet(ref int value)");
						doc.Undo();
					}
					mParamRowsVersion = -1;
					SelfTestCheck(outRow && applied && doc.Text == before, scope $"newcomer 9: Properties > Inputs shows Passing out, ref is written and undone (out={outRow} ref={applied})");
				}
				// Run: Defer (print "Run done"), then CountUp(), then Branch on TryGet(out value).
				let run = NcMethod("Greeter", mNcRun);
				NcPick(run.Graph.Entry.Then, "Defer", 320, 0);
			case 14:
				let run = NcMethod("Greeter", mNcRun);
				let d = FindNodeOf(run.Graph, .Defer);
				NcDumpPins(d, "Defer");
				if (d == null)
					return true;
				NcPick(d.FindOutput("body"), "Print", 640, -100, true);
			case 15:
				let run = NcMethod("Greeter", mNcRun);
				let print = FindNodeOf(run.Graph, .Call, "WriteLine");
				if (print != null)
					SessionSetPin(print, FirstValueInput(print), "\"Run done\"");
			case 16:
				let run = NcMethod("Greeter", mNcRun);
				let d = FindNodeOf(run.Graph, .Defer);
				String calls = scope .();
				NcLabels(d.Then, "CountUp", calls);
				NcNote(scope $"Node menu after Defer, 'CountUp': {calls}");
				NcPick(d.Then, "CountUp", 640, 100, true);
			case 17:
				let run = NcMethod("Greeter", mNcRun);
				let c = FindNodeOf(run.Graph, .Call, "CountUp");
				NcDumpPins(c, "CountUp call");
				NcPick(c?.Then, "Branch", 960, 100);
			case 18:
				let run = NcMethod("Greeter", mNcRun);
				let br = FindNodeOf(run.Graph, .Branch);
				String tg = scope .();
				NcLabels(br?.FindInput("condition"), "TryGet", tg);
				NcNote(scope $"Node menu from the Branch condition, 'TryGet': {tg}");
				NcPick(br?.FindInput("condition"), "TryGet", 960, 300, true);
			case 19:
				let run = NcMethod("Greeter", mNcRun);
				let call = FindNodeOf(run.Graph, .Call, "TryGet");
				NcDumpPins(call, "TryGet call");
				let br = FindNodeOf(run.Graph, .Branch);
				NcPick(br?.FindOutput("true"), "Print", 1280, 100, true);
			case 20:
				let run = NcMethod("Greeter", mNcRun);
				let call = FindNodeOf(run.Graph, .Call, "TryGet");
				Node print = null;
				for (let n in run.Graph.Nodes)
					if (n.Kind == .Call && n.Text == "WriteLine" && FirstValueInput(n) != null && run.Graph.FindLinkTo(FirstValueInput(n)) == null && FirstValueInput(n).Default.IsEmpty)
						print = n;
				Pin outPin = null;
				if (call != null)
					for (let p in call.Outputs)
						if (p.Kind == .Data && p.Name != "result")
							outPin = p;
				if (print != null && outPin != null)
				{
					BeginEdit();
					let l = run.Graph.Connect(outPin, FirstValueInput(print));
					CommitCurrent();
					NcNote(scope $"out pin '{outPin.Label}' wired into the print: {l != null}");
				}
				else
					NcNote(scope $"no out pin on TryGet or no empty print ({outPin != null}, {print != null})");
			case 21:
				let doc = NcDoc("Greeter");
				let run = NcMethod("Greeter", mNcRun);
				NcErrors(run, "Run");
				String body = scope .();
				doc.GenerateMethodBody(run, body);
				NcNote(scope $"Run body:\n{body}");
				// Greet (the interface stub): print the name.
				let greet = NcByName("Greeter", "Greet");
				NcNote(scope $"Greet stub found: {greet != null}");
				if (greet != null)
					NcDumpPins(greet.Graph.Entry, "Greet entry");
				SaveAll();
				NcNote(scope $"Greeter.bf saved:\n{doc.Text}");
			case 22:
				// Main: Construct Greeter (with the Set on create input), Defer -> Delete, Run on its Receiver.
				let main = NcByName("Program", "Main");
				if (main == null)
				{
					SelfTestCheck(false, "newcomer: no Program.Main");
					return true;
				}
				{
					// The template's `Console.WriteLine("Hello from Mod")` read back takes any value,
					// like a placed Print: an int wired into it is not refused (checked, then unwired).
					let hello = FindNodeOf(main.Graph, .Call, "WriteLine");
					let pin = (hello != null) ? FirstValueInput(hello) : null;
					bool objectPin = pin != null && pin.TypeName == "Object";
					bool accepted = false;
					if (objectPin)
					{
						let g = main.Graph;
						String saved = scope .(pin.Default);
						let num = NodeFactory.Expr(g, "42");
						num.Result.TypeName.Set("int");
						g.Connect(num.Result, pin);
						g.ClearErrors();
						GraphValidator.Validate(g);
						accepted = true;
						for (let e in g.Errors)
							if (e.NodeId == hello.Id)
								accepted = false;
						g.RemoveNode(num);
						pin.Default.Set(saved);
						g.ClearErrors();
						GraphValidator.Validate(g);
					}
					NcNote(scope $"Main's template print: pin {(pin != null) ? pin.Label : "?"} typed {(pin != null) ? pin.TypeName : "?"}, an int accepted {accepted}");
					SelfTestCheck(objectPin && accepted, "newcomer 10c: the template's print read back takes Object; a wired int is accepted");
				}
				String cons = scope .();
				NcLabels(null, "Construct", cons);
				NcNote(scope $"Node menu on Main's canvas, 'Construct': {cons}");
				if (!NcPick(null, "Construct Greeter", 300, 300, true))
				{
					NcNote("Falling back to Construct (new .()) + type in Properties");
					NcPick(null, "Construct  (new .())", 300, 300);
				}
			case 23:
				let main = NcByName("Program", "Main");
				let make = FindNodeOf(main.Graph, .Construct);
				NcDumpPins(make, "Construct in Main");
				if (make == null)
					return true;
				{
					// A Construct of Greeter with no constructor chosen (all of Greeter's take inputs):
					// the node shows why before any compile; choosing one in Properties clears it.
					let g = main.Graph;
					StringView[0] none = .();
					let bare = NodeFactory.Construct(g, "Greeter", "scope", none, none);
					bare.Edited = true;
					g.ClearErrors();
					GraphValidator.Validate(g);
					bool shown = false;
					for (let e in g.Errors)
						if (e.NodeId == bare.Id && e.Message.Contains("Greeter needs a constructor: choose one in Properties > Constructor"))
							shown = true;
					let st = Index.FindType("Greeter");
					SymbolMethod ctor = null;
					if (st != null)
						for (let m in st.Methods)
							if (m.IsCtor && !m.IsStatic && ctor == null)
								ctor = m;
					if (ctor != null)
						ChooseConstructor(g, bare, ctor);
					g.ClearErrors();
					GraphValidator.Validate(g);
					bool cleared = true;
					for (let e in g.Errors)
						if (e.NodeId == bare.Id && e.Message.Contains("needs a constructor"))
							cleared = false;
					NcNote(scope $"Construct Greeter without a constructor: error shown {shown}, Constructor ({(ctor != null) ? ctor.ParamsText : "?"}) clears it {cleared}");
					SelfTestCheck(shown && ctor != null && cleared, "newcomer 10b: Construct Greeter with no constructor chosen shows the error on the node; choosing one clears it");
					g.RemoveNode(bare);
					g.ClearErrors();
					GraphValidator.Validate(g);
				}
				let print = FindNodeOf(main.Graph, .Call, "WriteLine");
				NcPick(print?.Then, "Defer", 600, 0);
			case 24:
				let main = NcByName("Program", "Main");
				let d = FindNodeOf(main.Graph, .Defer);
				NcPick(d?.FindOutput("body"), "Delete", 900, -100);
			case 25:
				let main = NcByName("Program", "Main");
				let make = FindNodeOf(main.Graph, .Construct);
				let del = FindNodeOf(main.Graph, .Delete);
				if (make != null && del != null)
				{
					BeginEdit();
					main.Graph.Connect(make.Result, del.FindInput("value"));
					CommitCurrent();
				}
			case 26:
				let main = NcByName("Program", "Main");
				let make = FindNodeOf(main.Graph, .Construct);
				let d = FindNodeOf(main.Graph, .Defer);
				String runs = scope .();
				NcLabels(make?.Result, "Run", runs);
				NcNote(scope $"Node menu from the Construct's output, 'Run': {runs}");
				NcPick(d?.Then, "Run", 900, 100, true);
			case 27:
				let main = NcByName("Program", "Main");
				let make = FindNodeOf(main.Graph, .Construct);
				let run = FindNodeOf(main.Graph, .Call, "Run");
				NcDumpPins(run, "Run call in Main");
				if (make != null && run != null)
				{
					BeginEdit();
					let l = main.Graph.Connect(make.Result, run.FindInput("target"));
					CommitCurrent();
					NcNote(scope $"Construct wired into Run's Receiver: {l != null}");
				}
			case 28:
				let main = NcByName("Program", "Main");
				NcErrors(main, "Main");
				let doc = NcDoc("Program");
				NcNote(scope $"Program.bf:\n{doc.Text}");
				SaveAll();
				Compile("Release");
			case 29:
				if (SessionBuildRunning)
				{
					mNcStep--;
					return false;
				}
				mNcWait = 5;
			case 30:
				let st = SessionState;
				SelfTestCheck(st == .Good || st == .Unknown, scope $"newcomer 10: Release compile ({st}; yellow when the toolbar's configuration is another one)");
				// Close and reopen Greeter.bf: text and positions.
				let doc = NcDoc("Greeter");
				mNcSaved.Set(doc.Text);
				CloseDoc(doc);
			case 31:
				let doc = NcDoc("Greeter");
				SelfTestCheck(doc != null && doc.Text == mNcSaved && !doc.Modified, "newcomer 11: Greeter.bf closed and reopened byte for byte");
				let run = NcMethod("Greeter", mNcRun);
				if (run == null)
				{
					SelfTestCheck(false, "newcomer 11: Run not found after reopen");
					return true;
				}
				NcErrors(run, "Run after reopen");
				let cu = NcMethod("Greeter", mNcCountUp);
				let cuLoop = (cu != null) ? FindNodeOf(cu.Graph, .For) : null;
				SelfTestCheck(cuLoop != null && cuLoop.IsCountingLoop && cuLoop.FindOutput("counter").Label == "i" && cuLoop.FindInput("count").Default == "10",
					"newcomer 11: CountUp's loop reads back with its Counter pin i and Count 10");
				NcMethod("Greeter", mNcRun);
				// Reload node on the Branch, then Reload Sheet.
				let br = FindNodeOf(run.Graph, .Branch);
				if (br != null)
					ReloadNode(run, br);
				NcNote(scope $"Reload node: status '{mStatus}'");
			case 32:
				let run = NcMethod("Greeter", mNcRun);
				if (run == null)
					return true;
				int before = run.Graph.Nodes.Count;
				ReloadSheet();
				let run2 = NcMethod("Greeter", mNcRun);
				NcNote(scope $"Reload Sheet: nodes {before} -> {run2.Graph.Nodes.Count}, status '{mStatus}'");
				NcErrors(run2, "Run after Reload Sheet");
				let doc = NcDoc("Greeter");
				SelfTestCheck(doc.Text == mNcSaved, "newcomer 12: Reload node / Reload Sheet leave the text alone");
			case 33:
				// Undo / redo: add a print after CountUp's loop, undo it, redo it, undo it.
				let mg = NcMethod("Greeter", mNcCountUp);
				if (mg == null)
					return true;
				let loop = FindNodeOf(mg.Graph, .For);
				NcPick(loop?.Then, "Print", 640, 200, true);
			case 34:
				let doc = NcDoc("Greeter");
				String after = scope .(doc.Text);
				bool u1 = doc.CanUndo;
				if (u1) doc.Undo();
				bool same = doc.Text == mNcSaved;
				if (doc.CanRedo) doc.Redo();
				bool back = doc.Text == after;
				if (doc.CanUndo) doc.Undo();
				SelfTestCheck(same && back && doc.Text == mNcSaved, scope $"newcomer 13: undo / redo / undo of a placed print (undo={same} redo={back})");
				let mg = NcMethod("Greeter", mNcCountUp);
				NcNote(scope $"CountUp nodes after undo: {mg.Graph.Nodes.Count}");
				NcErrors(mg, "CountUp after undo");
			case 35:
				// The debugger: a breakpoint on the print in CountUp's loop, Start Debugging.
				let mg = NcMethod("Greeter", mNcCountUp);
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				if (print == null)
				{
					SelfTestCheck(false, "newcomer 14: no print in CountUp");
					return true;
				}
				ToggleBreakpoint(mg, print);
				mDebugTestFrames = 0;
				StartDebugging();
			case 36:
				if (!DebugTestWait(let stopped))
				{
					mNcStep--;
					return false;
				}
				let mg = NcMethod("Greeter", mNcCountUp);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SelfTestCheck(stopped && DebugStopGraph == mg.Graph && DebugStopNode == print.Id, scope $"newcomer 14: the debugger stops on the print in the loop ({mDebugStopWhere})");
				if (!stopped)
					return true;
				EvalValue v = scope .();
				bool ok = mDebug.Evaluate("i", DebugFrame, v);
				NcNote(scope $"debugger: i = {v.Value} ({ok}), mCount evaluates: {mDebug.Evaluate("mCount", DebugFrame, scope EvalValue())}");
				ToggleBreakpoint(mg, print);
				mDebugTestFrames = 0;
				mDebug.Continue();
			case 37:
				if (!DebugTestWait(let stopped))
				{
					mNcStep--;
					return false;
				}
				if (stopped)
				{
					mDebugTestFrames = 0;
					mDebug.Continue();
					mNcStep--;
					return false;
				}
				SelfTestCheck(!IsDebugging && mDebug != null && mDebug.ExitCode == 0, scope $"newcomer 14: Continue runs to the end (exit code {(mDebug != null) ? mDebug.ExitCode : -1})");
			default:
				return true;
			}
			return false;
		}
	}
}
