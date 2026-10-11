using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=modauthor`: a first-time UMP mod author's path, through the calls the UI makes,
	/// from an empty folder: File > New Project > UMP Mod with the game SDK chosen (`VB_MODAUTHOR_SDK`,
	/// default the Hogwarts Legacy SDK of a UMP checkout at D:\UnrealUMP\UnrealUMP). Initialize logs a
	/// line, hooks an SDK function (a static callback picked for the Callback pin), reads the mod's own
	/// ModConfig.json and logs it; OnWorldReady keeps the world; Tick reads the level name once;
	/// Shutdown removes the hooks. Then Save All, a Release compile to the DLL, ModConfig.json checked
	/// against UMP's rules, close / reopen, Reload Sheet / Reload node byte for byte. `[MODAUTHOR]`
	/// lines log what the choosers offered and the code written.
	extension EditorApp
	{
		int mMaStep;
		int mMaWait;
		String mMaFile = new .() ~ delete _;
		String mMaSaved = new .() ~ delete _;
		String mMaHookKey = new .() ~ delete _;

		void MaNote(StringView text) => Notify.Log(.Info, "SelfTest", scope $"[MODAUTHOR] {text}");

		SourceDocument MaDoc() => OpenFile(mMaFile, false);

		MethodGraph MaByName(StringView name)
		{
			let doc = MaDoc();
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

		/// The Node menu at `pin` filtered by `filter`: logs the time and the first labels.
		int MaMenu(Pin pin, StringView filter, int max = 12)
		{
			let tab = CurrentTab;
			if (tab == null)
				return 0;
			double t0 = Desktop.Now;
			OpenNodeMenu(tab, .(0, 0), (pin != null) ? pin.Id : 0);
			mNodeMenu.OpenRequested = false;
			double t1 = Desktop.Now;
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.SelfTestRows(filter, rows);
			double t2 = Desktop.Now;
			String s = scope .();
			for (let it in rows)
			{
				if (@it.Index >= max)
				{
					s.AppendF(" | ... ({} more)", rows.Count - max);
					break;
				}
				s.AppendF("{}{}", s.IsEmpty ? "" : " | ", it.Label);
			}
			String at = scope .();
			if (pin != null)
				at.AppendF(" from pin {}:{}", pin.Label, pin.TypeName);
			MaNote(scope $"Node menu{at} '{filter}': open {(t1 - t0) * 1000:F1} ms, search {(t2 - t1) * 1000:F1} ms, {rows.Count} rows: {s}");
			return rows.Count;
		}

		bool MaPick(Pin pin, StringView label, float x, float y, bool prefix = false, StringView category = "")
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
				if ((prefix ? it.Label.StartsWith(label) : it.Label == label) && (category.IsEmpty || it.Category.Contains(category) || it.Tooltip.Contains(category)))
				{
					found = it;
					break;
				}
			if (found != null)
				MaNote(scope $"picked '{found.Label}' in {found.Category}: {found.Tooltip}");
			if (found == null)
			{
				MaNote(scope $"the Node menu offers no '{label}'");
				return false;
			}
			NodeItem copy = scope .();
			copy.CopyFrom(found);
			ExecuteAction(copy);
			return true;
		}

		void MaErrors(MethodGraph mg, StringView what)
		{
			if (mg == null)
				return;
			for (let e in mg.Graph.Errors)
				MaNote(scope $"{what}: graph error on node {e.NodeId}: {e.Message}");
		}

		void MaPins(Node n, StringView what)
		{
			if (n == null)
			{
				MaNote(scope $"{what}: no node");
				return;
			}
			String s = scope .();
			for (let p in n.Inputs)
				s.AppendF(" in:{}({}:{}='{}')", p.Name, p.Label, p.TypeName, p.Default);
			for (let p in n.Outputs)
				s.AppendF(" out:{}({}:{})", p.Name, p.Label, p.TypeName);
			MaNote(scope $"{what}: {n.Kind} '{n.Text}'{s}");
		}

		void MaBody(MethodGraph mg, StringView what)
		{
			if (mg == null)
				return;
			String body = scope .();
			MaDoc().GenerateMethodBody(mg, body);
			MaNote(scope $"{what} body:\n{body}");
			MaErrors(mg, what);
		}

		void MaTypeCheck(StringView type, TypeSlot slot)
		{
			String why = scope .();
			bool ok = TypeSlotRules.Check(type, slot, TypeScope(), why);
			MaNote(scope $"type rules: '{type}' as {slot}: {ok} {why}");
		}

		/// A key's value in ModConfig.json text as written ("hello-mod", 20, ""): enough for the checks.
		static void MaJsonValue(StringView json, StringView key, String outValue)
		{
			int at = json.IndexOf(scope $"\"{key}\"");
			if (at < 0)
				return;
			int colon = json.IndexOf(':', at);
			int s = colon + 1;
			while (s < json.Length && json[s] == ' ')
				s++;
			if (s < json.Length && json[s] == '"')
			{
				int e = json.IndexOf('"', s + 1);
				outValue.Set(StringView(json, s + 1, e - s - 1));
				return;
			}
			int e = s;
			while (e < json.Length && json[e] != ',' && json[e] != '\n' && json[e] != '}')
				e++;
			outValue.Set(StringView(json, s, e - s));
			outValue.Trim();
		}

		/// ModConfig.json checked against UMP's docs/Mods.md (the "ModConfig.json" table) and the
		/// mod's Info(): the problems, one per line (empty: valid).
		void MaValidateModConfig(StringView json, StringView mainText, String outProblems)
		{
			String v = scope .();
			MaJsonValue(json, "Id", v);
			String id = scope .(v);
			if (id.IsEmpty)
				outProblems.Append("Id is empty\n");
			if (!mainText.Contains(scope $"Info() => .(\"{id}\""))
				outProblems.AppendF("Info() does not return the id {}\n", id);
			v.Clear(); MaJsonValue(json, "Version", v);
			if (v.IsEmpty || !mainText.Contains(scope $", \"{v}\"); // must match ModConfig.json"))
				outProblems.AppendF("Version '{}' is not Info()'s\n", v);
			v.Clear(); MaJsonValue(json, "Game Id", v);
			if (v.IsEmpty)
				outProblems.Append("Game Id is empty\n");
			v.Clear(); MaJsonValue(json, "Entry", v);
			if (!v.EndsWith(".dll"))
				outProblems.AppendF("Entry '{}' is not a DLL name\n", v);
			v.Clear(); MaJsonValue(json, "Api Version", v);
			if (v != "1")
				outProblems.AppendF("Api Version {} is not 1\n", v);
			v.Clear(); MaJsonValue(json, "Phase", v);
			if (!(v == "PreInit" || v == "PostGlobals" || v == "EngineReady" || v == "WorldReady"))
				outProblems.AppendF("Phase '{}' is not a UMP phase\n", v);
			v.Clear(); MaJsonValue(json, "Kind", v);
			if (!(v.IsEmpty || v == "native" || v == "both"))
				outProblems.AppendF("Kind '{}' is not native\n", v);
			v.Clear(); MaJsonValue(json, "MinRuntimeAbi", v);
			int abi = -1;
			if (int.Parse(v) case .Ok(let a))
				abi = a;
			if (abi < 0)
				outProblems.AppendF("MinRuntimeAbi '{}' is not a non-negative integer\n", v);
			v.Clear(); MaJsonValue(json, "MinLauncher", v);
			int parts = 0;
			bool okL = true;
			if (!v.IsEmpty)
				for (let part in v.Split('.'))
				{
					parts++;
					if (!(int.Parse(part) case .Ok(let n)) || n < 0 || n > 65535)
						okL = false;
				}
			if (!okL || parts > 4)
				outProblems.AppendF("MinLauncher '{}' is not 1 to 4 numeric parts\n", v);
			for (let key in StringView[6]("Mod Name", "Author", "Mod Description", "Dependencies", "Load After", "MinLauncher"))
				if (!json.Contains(scope $"\"{key}\""))
					outProblems.AppendF("{} is missing\n", key);
		}

		/// The n-th data input of a node, not counting its Receiver.
		static Pin MaInput(Node n, int index)
		{
			int i = 0;
			for (let p in n.Inputs)
				if (p.Kind == .Data && p.Name != "target")
				{
					if (i++ == index)
						return p;
				}
			return null;
		}

		/// The Log call of the graph whose message pin is still empty and unwired.
		Node MaOpenLog(MethodGraph mg)
		{
			Node found = null;
			for (let n in mg.Graph.Nodes)
				if (n.Kind == .Call && n.Text == "Log" && n.FindInput("arg1") != null && mg.Graph.FindLinkTo(n.FindInput("arg1")) == null && n.FindInput("arg1").Default.IsEmpty)
					found = n;
			return found;
		}

		/// The catalog rows of a search that carry the hook / PE slots UMP generates for its own use.
		/// `max` rows of the search are looked at; typed-text rows ("Call x()", "Expression:") are not catalog rows.
		int MaCatalogRows(StringView filter, String outNoise, ref int total)
		{
			let tab = CurrentTab;
			if (tab == null)
				return 0;
			OpenNodeMenu(tab, .(0, 0), 0);
			mNodeMenu.OpenRequested = false;
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.SelfTestRows(filter, rows);
			int named = 0;
			for (let it in rows)
			{
				if (it.Kind == .CallCustom || it.Kind == .CallMember || it.Kind == .Expr)
					continue;
				total++;
				bool noise = it.Label.EndsWith(" PE") || it.Label.Contains("_PE") || it.Label.Contains("Original_") || it.Label.Contains("SdkHooks") || it.Category.Contains("SdkHooks") || it.Tooltip.Contains("SdkHooks");
				if (noise)
					outNoise.AppendF("{}{} [{}]", outNoise.IsEmpty ? "" : " | ", it.Label, it.Category);
				if (it.Label.Contains(filter))
					named++;
			}
			return named;
		}

		bool SelfTestModAuthor()
		{
			if (mMaWait > 0)
			{
				mMaWait--;
				return false;
			}
			let step = mMaStep++;
			switch (step)
			{
			case 0:
				// A blank folder: File > New Project > UMP Mod, the Game SDK chosen in the dialog.
				String projectTypes = scope .();
				for (let t in sProjectTypes)
					projectTypes.AppendF("{}{}", projectTypes.IsEmpty ? "" : ", ", t);
				MaNote(scope $"File > New Project types: {projectTypes}");
				String sdkDir = scope .();
				if (Environment.GetEnvironmentVariable("VB_MODAUTHOR_SDK", sdkDir) case .Err || sdkDir.IsEmpty)
					sdkDir.Set(@"D:\UnrealUMP\UnrealUMP\Sdks\HogwartsLegacySDK");
				// What the Game SDK row says for a wrong folder, for the UMP folder (two SDKs) and the right one.
				for (let probe in StringView[3](mProjectRoot, @"D:\UnrealUMP\UnrealUMP", sdkDir))
				{
					UmpSdkInfo info = scope .();
					String err = scope .();
					bool ok = UmpModProject.ResolveSdk(probe, info, err);
					MaNote(scope $"Game SDK '{probe}': {ok} {err} {info.ProjectName} game={info.GameId} ump={info.UmpRoot} abi={info.RuntimeAbi} launcher='{info.LauncherRoot}'");
				}
				mNPSdk.Set(sdkDir);
				ResolveNewModSdk();
				SelfTestCheck(mNPSdkOk && mNPSdkInfo.GameId == "hogwarts-legacy" && mNPSdkInfo.RuntimeAbi > 0,
					scope $"modauthor 1: the Game SDK row resolves {sdkDir} (game {mNPSdkInfo.GameId}, runtime ABI {mNPSdkInfo.RuntimeAbi}) {mNPSdkError}");
				String location = scope .(mProjectRoot);
				bool made = CreateModProject("Hello Mod", location, mNPSdkInfo);
				mMaFile.Clear();
				mMaFile.AppendF("{}{}src{}ModMain.bf", mProjectRoot, Path.DirectorySeparatorChar, Path.DirectorySeparatorChar);
				SelfTestCheck(made && mProjectRoot.EndsWith("HelloMod") && File.Exists(mMaFile), scope $"modauthor 1: New Project > UMP Mod 'Hello Mod' wrote and opened {mProjectRoot}");
				if (!made)
					return true;
			case 1:
				let doc = MaDoc();
				SelfTestCheck(doc != null, "modauthor 2: src/ModMain.bf opens");
				if (doc == null)
					return true;
				String fns = scope .();
				for (let mg in doc.Methods)
					fns.AppendF(" {}{}", mg.Method.Name, mg.Graphable ? "" : "(no graph)");
				MaNote(scope $"functions:{fns}");
				String cfg = scope .();
				File.ReadAllText(scope $"{mProjectRoot}{Path.DirectorySeparatorChar}ModConfig.json", cfg).IgnoreError();
				MaNote(scope $"ModConfig.json as created:\n{cfg}");
				let init = MaByName("Initialize");
				if (init == null)
					return true;
				MaMenu(null, "", 6);
				MaMenu(null, "Log");
				MaMenu(null, "Days In Year", 40);
				for (let probe in StringView[?]("Days In Year", "Original Days In Year", "Original_DaysInYear", "DaysInYear_PE", "SdkHooks"))
				{
					String noise = scope .();
					int total = 0;
					int named = MaCatalogRows(probe, noise, ref total);
					MaNote(scope $"catalog rows for '{probe}': {total} listed, {named} with the words in their label, {noise.Length == 0 ? 0 : 1} noise: {noise}");
					SelfTestCheck(noise.IsEmpty, scope $"modauthor 15: the catalog lists no _PE / SdkHooks / raw Original_ row for '{probe}' ({noise})");
				}
				{
					String noise = scope .();
					int total = 0;
					int named = MaCatalogRows("Days In Year", noise, ref total);
					SelfTestCheck(named >= 6, scope $"modauthor 15: 'Days In Year' finds the function and its hook family ({named} rows with the words)");
				}
				// A member by its raw name, underscores as written (finding: a C++ field name found nothing).
				{
					(StringView, StringView)[8] probes = .(("m_LoopStart", "Get m Loop Start"), ("bOverride_bCastCapsuleDirectShadow", "Get Override b Cast Capsule Direct Shadow"),
						("m_Loop_Start", "Get m Loop Start"), ("Loop_Start", "Get m Loop Start"), ("TryHook_DaysInYear", "Try hook Days In Year"),
						("CallOriginal_DaysInYear", "Call original Days In Year"), ("Hook_DaysInYear", "Hook Days In Year"), ("DaysInYear", "Days In Year"));
					for (let probe in probes)
					{
						let tab = CurrentTab;
						OpenNodeMenu(tab, .(0, 0), 0);
						mNodeMenu.OpenRequested = false;
						List<NodeItem> rows = scope .();
						defer { ClearAndDeleteItems!(rows); }
						mNodeMenu.SelfTestRows(probe.0, rows);
						int at = -1;
						String top = scope .();
						for (let it in rows)
						{
							if (@it.Index < 3)
								top.AppendF("{}{}", top.IsEmpty ? "" : " | ", it.Label);
							if (at < 0 && it.Label == probe.1)
								at = @it.Index;
						}
						MaNote(scope $"search '{probe.0}': '{probe.1}' at row {at} of {rows.Count}: {top}");
						SelfTestCheck(at >= 0 && at < 3, scope $"modauthor 16: searching '{probe.0}' lists '{probe.1}' among the first rows (row {at})");
					}
				}
				MaMenu(null, "Try hook Days In Year");
				MaMenu(null, "Call original Days In Year");
				MaMenu(null, "Read Mod File");
				MaMenu(null, "Mod Directory Path");
				MaMenu(null, "To Owned String");
				MaMenu(null, "Get Current Level Name");
				MaMenu(null, "Read All Text");
				MaMenu(null, "Remove All");
			case 2:
				let doc = MaDoc();
				let type = FindTypeIn(doc, "ModMain");
				String ov = scope .();
				for (let m in ClassInfoFor(doc, type).Overridable)
					ov.AppendF("{}{}", ov.IsEmpty ? "" : ", ", m.Name);
				MaNote(scope $"Overrides offered: {ov}");
				MaTypeCheck("UWorld*", .Member);
				MaTypeCheck("UObject*", .Param);
				MaTypeCheck("function uint64(uint64)", .Member);
				MaTypeCheck("TArray<AActor*>", .Member);
				SelfTestOverride("ModMain:OnWorldReady");
			case 3:
				let doc = MaDoc();
				for (let spec in StringView[3]("UWorld*", "bool", "String"))
				{
					let type = FindTypeIn(doc, "ModMain");
					let t = MemberInit.TypeOf(spec, TypeService.Current);
					AddVarDefaults(t);
					MemberInit init = scope .();
					init.Retarget(mAddVarOwner, t);
					init.Owner = mAddVarOwner;
					init.ValueKind = .None;
					MaNote(scope $"Add Variable {spec}: default ownership {mAddVarOwner}");
					bool ok = AddVariableChecked(doc, type, spec, (spec == "bool") ? "mLevelLogged" : (spec == "String") ? "mConfigText" : "mWorld", init, false);
					SelfTestCheck(ok, scope $"modauthor 3: Add Variable {spec} {doc.LastError}");
				}
			case 4:
				let ow = MaByName("OnWorldReady");
				if (ow == null)
				{
					SelfTestCheck(false, "modauthor 4: no OnWorldReady graph");
					return true;
				}
				MaPick(ow.Graph.Entry.Then, "Set mWorld", 320, 0);
			case 5:
				let ow = MaByName("OnWorldReady");
				let set = FindNodeOf(ow.Graph, .Set);
				Pin world = null;
				for (let p in ow.Graph.Entry.Outputs)
					if (p.Kind == .Data)
						world = p;
				if (set != null && world != null)
				{
					BeginEdit();
					ow.Graph.Connect(world, FirstValueInput(set));
					CommitCurrent();
				}
			case 6:
				let ow = MaByName("OnWorldReady");
				MaBody(ow, "OnWorldReady");
				String body = scope .();
				MaDoc().GenerateMethodBody(ow, body);
				SelfTestCheck(body.Contains("mWorld = World;"), "modauthor 4: OnWorldReady keeps the world (mWorld = World)");
				// The hook callback: a static function with the native shape uint64(uint64).
				let doc = MaDoc();
				bool ok = doc.AddMethod(FindTypeIn(doc, "ModMain"), "uint64", "OnDaysInYear", "uint64 year", mMaHookKey);
				let mg = doc.FindMethod(mMaHookKey);
				bool st = mg != null && doc.SetModifierWord(mg.Method, "static", true);
				SelfTestCheck(ok && st, scope $"modauthor 5: Add Function uint64 OnDaysInYear(uint64 year), Static {doc.LastError}");
			case 7:
				let mg = MaByName("OnDaysInYear");
				if (mg == null)
					return true;
				MaPick(mg.Graph.Entry.Then, "Return", 320, 0);
			case 8:
				// The unhooked code, as nodes. The callback takes the native shape (uint64); the typed twin takes an
				// int32 and gives one back, so a Cast goes on each side. "Call original Days In Year" from the
				// Return's value pin is only offered through the Cast (the pin wants a uint64, the call gives an int32).
				let mg = MaByName("OnDaysInYear");
				let ret = FindNodeOf(mg.Graph, .Return);
				if (ret == null)
					return true;
				let v = ret.FindInput("value");
				int direct = MaMenu(v, "Call original Days In Year", 4);
				MaNote(scope $"Call original Days In Year straight from the uint64 pin: {direct} rows");
				bool picked = MaPick(v, "Cast", 640, 0, true);
				SelfTestCheck(picked, "modauthor 8: the Return's value pin offers a Cast");
			case 9:
				let mg = MaByName("OnDaysInYear");
				let cast = FindNodeOf(mg.Graph, .Cast);
				MaPins(cast, "Cast on Return");
				if (cast == null)
					return true;
				bool picked = MaPick(FirstValueInput(cast), "Call original Days In Year", 960, 0, false, "Hooks");
				SelfTestCheck(picked, "modauthor 8: the Cast's input pin offers 'Call original Days In Year' (Hooks|KismetMathLibrary), no typed Original_ call");
			case 10:
				let mg = MaByName("OnDaysInYear");
				let co = FindNodeOf(mg.Graph, .Call, "CallOriginal_DaysInYear");
				MaPins(co, "CallOriginal_DaysInYear");
				if (co == null)
					return true;
				MaPick(FirstValueInput(co), "Cast", 1280, 0, true);
			case 11:
				let mg = MaByName("OnDaysInYear");
				let co = FindNodeOf(mg.Graph, .Call, "CallOriginal_DaysInYear");
				Node cast2 = null;
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .Cast && co != null && mg.Graph.FindLinkTo(FirstValueInput(co))?.From.Owner == n)
						cast2 = n;
				MaPins(cast2, "Cast on the call's input");
				Pin year = null;
				for (let p in mg.Graph.Entry.Outputs)
					if (p.Kind == .Data)
						year = p;
				if (year != null && cast2 != null)
				{
					BeginEdit();
					mg.Graph.Connect(year, FirstValueInput(cast2));
					CommitCurrent();
				}
				else
					SelfTestCheck(false, "modauthor 8: the year parameter and the second Cast exist");
			case 12:
				let mg = MaByName("OnDaysInYear");
				MaBody(mg, "OnDaysInYear");
				String body = scope .();
				MaDoc().GenerateMethodBody(mg, body);
				SelfTestCheck(body.Contains("UKismetMathLibrary.CallOriginal_DaysInYear("), scope $"modauthor 8: OnDaysInYear calls UKismetMathLibrary.CallOriginal_DaysInYear");
				// Initialize: after the template's Log, Try hook Days In Year (a bool) with OnDaysInYear as its callback.
				let init = MaByName("Initialize");
				let log = FindNodeOf(init.Graph, .Call, "Log");
				if (log == null)
					return true;
				MaPick(log.Then, "Try hook Days In Year", 640, 0, false, "Hooks");
			case 13:
				let init = MaByName("Initialize");
				let hook = FindNodeOf(init.Graph, .Call, "TryHook_DaysInYear");
				MaPins(hook, "TryHook_DaysInYear");
				if (hook == null)
				{
					SelfTestCheck(false, "modauthor 6: Try hook Days In Year is placed");
					return true;
				}
				let cb = FirstValueInput(hook);
				MaMenu(cb, "");
				bool picked = MaPick(cb, "OnDaysInYear", 640, 200, true);
				SelfTestCheck(picked, "modauthor 6: the Node menu from the hook's Callback pin offers OnDaysInYear (the static function of that shape)");
				if (!picked)
					SessionSetPin(hook, cb, "=> OnDaysInYear");
			case 14:
				// The hook's bool result goes into a Branch: the false arm stays empty.
				let init = MaByName("Initialize");
				let hook = FindNodeOf(init.Graph, .Call, "TryHook_DaysInYear");
				MaPick(hook?.Then, "Branch", 960, 0);
			case 15:
				let init = MaByName("Initialize");
				let hook = FindNodeOf(init.Graph, .Call, "TryHook_DaysInYear");
				let br = FindNodeOf(init.Graph, .Branch);
				if (hook != null && br != null && hook.Result != null)
				{
					BeginEdit();
					init.Graph.Connect(hook.Result, br.FindInput("condition"));
					CommitCurrent();
				}
				else
					SelfTestCheck(false, "modauthor 6: the hook's result pin and a Branch exist");
			case 16:
				let init = MaByName("Initialize");
				String body = scope .();
				MaDoc().GenerateMethodBody(init, body);
				MaBody(init, "Initialize with the hook");
				SelfTestCheck(body.Contains("UKismetMathLibrary.TryHook_DaysInYear(=> OnDaysInYear);") && body.Contains("if (tryHook_DaysInYearResult)"), "modauthor 6: written UKismetMathLibrary.TryHook_DaysInYear(=> OnDaysInYear) with its bool result in an if");
				// The config value: ReadModFile("ModConfig.json", mConfigText), a node of the mod's own base.
				let br = FindNodeOf(init.Graph, .Branch);
				bool picked = MaPick(br?.FindOutput("true"), "ReadModFile", 1280, 0, true);
				SelfTestCheck(picked, "modauthor 9: the Branch's true arm offers ReadModFile (UMPMod), no File.ReadAllText with a typed path");
			case 17:
				let init = MaByName("Initialize");
				let read = FindNodeOf(init.Graph, .Call, "ReadModFile");
				MaPins(read, "ReadModFile");
				if (read == null)
					return true;
				SessionSetPin(read, MaInput(read, 0), "\"ModConfig.json\"");
				let outText = MaInput(read, 1);
				MaMenu(outText, "mConfigText");
				MaPick(outText, "Get mConfigText", 1100, 200);
			case 18:
				let init = MaByName("Initialize");
				let read = FindNodeOf(init.Graph, .Call, "ReadModFile");
				// Log the text read: a second Log after it, mConfigText wired into its message.
				MaPick(read?.Then, "Log", 1600, 0, false, "UMPDebug");
			case 19:
				let init = MaByName("Initialize");
				let log2 = MaOpenLog(init);
				MaPins(log2, "second Log");
				if (log2 != null)
				{
					MaNote(scope $"the placed Log's LogType pin starts '{log2.FindInput("arg0").Default}'");
					SessionSetPin(log2, log2.FindInput("arg0"), ".Info");
					MaPick(log2.FindInput("arg1"), "Get mConfigText", 1400, 200);
				}
			case 20:
				// The mod's folder as a node: a third Log of Get Mod Directory Path.
				let init = MaByName("Initialize");
				Node last = null;
				for (let n in init.Graph.Nodes)
					if (n.Kind == .Call && n.Text == "Log" && n.Then != null && init.Graph.FindLinkFrom(n.Then) == null)
						last = n;
				MaPick(last?.Then, "Log", 1920, 0, false, "UMPDebug");
			case 21:
				let init = MaByName("Initialize");
				let log3 = MaOpenLog(init);
				MaPins(log3, "third Log");
				if (log3 != null)
				{
					SessionSetPin(log3, log3.FindInput("arg0"), ".Info");
					MaMenu(log3.FindInput("arg1"), "ModDirectoryPath", 6);
					bool picked = MaPick(log3.FindInput("arg1"), "Get ModDirectoryPath", 1700, 200);
					SelfTestCheck(picked, "modauthor 10: the Log message pin offers Get ModDirectoryPath (the inherited UMPMod property), no Context.ModDirectory typed");
				}
			case 22:
				let init = MaByName("Initialize");
				MaBody(init, "Initialize");
				String body = scope .();
				MaDoc().GenerateMethodBody(init, body);
				SelfTestCheck(body.Contains("ReadModFile(\"ModConfig.json\", mConfigText);") && body.Contains("Log(.Info, mConfigText);") && body.Contains("ModDirectoryPath"), "modauthor 7: Initialize reads ModConfig.json with ReadModFile, logs it and the mod folder");
				// Tick: once, read the level name of the kept world.
				let tick = MaByName("Tick");
				MaPick(tick.Graph.Entry.Then, "Branch", 320, 0);
			case 23:
				let tick = MaByName("Tick");
				let br = FindNodeOf(tick.Graph, .Branch);
				MaPick(br?.FindInput("condition"), "Get mLevelLogged", 160, 200);
			case 24:
				let tick = MaByName("Tick");
				let br = FindNodeOf(tick.Graph, .Branch);
				MaPick(br?.FindOutput("false"), "Get Current Level Name", 640, 100);
			case 25:
				let tick = MaByName("Tick");
				let call = FindNodeOf(tick.Graph, .Call, "GetCurrentLevelName");
				MaPins(call, "GetCurrentLevelName");
				if (call == null)
					return true;
				SelfTestCheck(call.FindInput("arg1")?.Default == "false", "modauthor 8: a bool input of a placed SDK call starts with false");
				MaPick(FirstValueInput(call), "Get mWorld", 400, 300);
			case 26:
				// The FString it returns is owned by the caller: To Owned String copies and frees it.
				let tick = MaByName("Tick");
				let call = FindNodeOf(tick.Graph, .Call, "GetCurrentLevelName");
				MaMenu(call?.Result, "To Owned String", 4);
				bool picked = MaPick(call?.Result, "To Owned String", 960, 300);
				SelfTestCheck(picked, "modauthor 12: the FString result offers To Owned String");
				let owned = FindNodeOf(tick.Graph, .Call, "ToOwnedString");
				if (call != null && owned != null && owned.FindInput("exec") != null)
				{
					BeginEdit();
					tick.Graph.Connect(call.Then, owned.FindInput("exec"));
					CommitCurrent();
				}
			case 27:
				let tick = MaByName("Tick");
				let owned = FindNodeOf(tick.Graph, .Call, "ToOwnedString");
				MaPick(owned?.Then, "Log", 1280, 100, false, "UMPDebug");
			case 28:
				let tick = MaByName("Tick");
				let log = MaOpenLog(tick);
				let owned = FindNodeOf(tick.Graph, .Call, "ToOwnedString");
				MaPins(owned, "ToOwnedString");
				MaPins(log, "Tick Log");
				if (log != null && owned != null && owned.Result != null)
				{
					SessionSetPin(log, log.FindInput("arg0"), ".Info");
					BeginEdit();
					tick.Graph.Connect(owned.Result, log.FindInput("arg1"));
					CommitCurrent();
					MaPick(log.Then, "Set mLevelLogged", 1600, 100);
				}
				else
					SelfTestCheck(false, "modauthor 12: Tick has a Log and a To Owned String");
			case 29:
				let tick = MaByName("Tick");
				let set = FindNodeOf(tick.Graph, .Set);
				if (set != null)
					SessionSetPin(set, FirstValueInput(set), "true");
			case 30:
				let tick = MaByName("Tick");
				MaBody(tick, "Tick");
				String body = scope .();
				MaDoc().GenerateMethodBody(tick, body);
				SelfTestCheck(body.Contains("UGameplayStatics.GetCurrentLevelName(mWorld, false)") && body.Contains(".ToOwnedString()") && body.Contains("mLevelLogged = true;"), "modauthor 8: Tick reads the level name once and logs the owned string");
				// The Shutdown tab is opened a frame before the pick (the commit writes the tab in front).
				MaByName("Shutdown");
			case 31:
				// Unhook Days In Year returns a Result nothing reads: the node says so.
				let sd = MaByName("Shutdown");
				MaPick(sd.Graph.Entry.Then, "Unhook Days In Year", 320, 0, false, "Hooks");
			case 32:
				let sd = MaByName("Shutdown");
				let un = FindNodeOf(sd.Graph, .Call, "Unhook_DaysInYear");
				MaPins(un, "Unhook_DaysInYear");
				String note = scope .();
				if (un != null)
					note.Set(sd.Graph.FindWarning(un.Id));
				MaNote(scope $"Unhook Days In Year node note: '{note}'");
				SelfTestCheck(note.Contains("returns a Result") && note.Contains("nothing reads"), "modauthor 13: an unread Result<void> return shows a note on the node");
				MaPick(un?.Then, "Remove All", 640, 0, false, "NativeHooks");
			case 33:
				let sd = MaByName("Shutdown");
				MaBody(sd, "Shutdown");
				let doc = MaDoc();
				SelfTestCheck(doc.Text.Contains("FNativeHooks.RemoveAll();") && doc.Text.Contains("UKismetMathLibrary.Unhook_DaysInYear();"), "modauthor 9: Shutdown unhooks and removes the hooks (FNativeHooks.RemoveAll written)");
				SelfTestCheck(!doc.Text.Contains("File.ReadAllText") && !doc.Text.Contains("Context.ModDirectory") && !doc.Text.Contains(" Original_") && !doc.Text.Contains(".Original_"), "modauthor 14: no typed Beef: no File.ReadAllText, Context.ModDirectory or Original_ in the mod");
				SaveAll();
				MaNote(scope $"ModMain.bf saved:\n{doc.Text}");
				Compile("Release");
			case 34:
				if (SessionBuildRunning)
				{
					mMaStep--;
					return false;
				}
				mMaWait = 5;
			case 35:
				let st = SessionState;
				String dll = scope $"{mProjectRoot}{Path.DirectorySeparatorChar}build{Path.DirectorySeparatorChar}Release_Win64{Path.DirectorySeparatorChar}HelloMod{Path.DirectorySeparatorChar}HelloMod.dll";
				int64 size = -1;
				{
					FileStream fs = scope .();
					if (fs.Open(dll, .Read, .ReadWrite) case .Ok)
						size = fs.Length;
				}
				MaNote(scope $"Release compile: {st}, {dll} {size} bytes");
				SelfTestCheck(st == .Good && size > 0, scope $"modauthor 10: Release compile of the mod to HelloMod.dll ({st}, {size} bytes)");
				let doc = MaDoc();
				mMaSaved.Set(doc.Text);
				String cfg = scope .();
				File.ReadAllText(scope $"{mProjectRoot}{Path.DirectorySeparatorChar}ModConfig.json", cfg).IgnoreError();
				String problems = scope .();
				MaValidateModConfig(cfg, doc.Text, problems);
				SelfTestCheck(problems.IsEmpty, scope $"modauthor 11: ModConfig.json is valid for UMP (docs/Mods.md) and matches Info() {problems}");
				CloseDoc(doc);
			case 36:
				let doc = MaDoc();
				SelfTestCheck(doc != null && doc.Text == mMaSaved && !doc.Modified, "modauthor 12: ModMain.bf closed and reopened byte for byte");
				let init = MaByName("Initialize");
				let hook = (init != null) ? FindNodeOf(init.Graph, .Call, "TryHook_DaysInYear") : null;
				if (hook != null)
				{
					bool linked = init.Graph.FindLinkTo(FirstValueInput(hook)) != null;
					MaNote(scope $"reopened: the hook's callback is {(linked ? "a wired node" : "pin text")}: '{FirstValueInput(hook).Default}'");
				}
				MaErrors(init, "Initialize after reopen");
				ReloadSheet();
				SelfTestCheck(MaDoc().Text == mMaSaved, "modauthor 13: Reload Sheet leaves the text alone");
			case 37:
				let tick = MaByName("Tick");
				let br = (tick != null) ? FindNodeOf(tick.Graph, .Branch) : null;
				if (br != null)
					ReloadNode(tick, br);
				SelfTestCheck(MaDoc().Text == mMaSaved, scope $"modauthor 13: Reload node leaves the text alone ({mStatus})");
				// Every graph of the file: an identity commit gives the same text.
				let doc = MaDoc();
				String before = scope .(doc.Text);
				for (let mg in doc.Methods)
					if (mg.Graphable)
						doc.Commit(mg);
				SelfTestCheck(doc.Text == before, "modauthor 14: every graph committed unchanged gives the file byte for byte");
			default:
				return true;
			}
			return false;
		}
	}
}
