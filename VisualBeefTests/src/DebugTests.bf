using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;
using VisualBeef.Debug;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Tests
{
	/// The debugger (docs/Debugging.md):
	///   `debugmap <files or folders>...`: on every function graph of a corpus, every node with a
	///   line maps to a line inside its function, and that line maps back to a statement with the
	///   same line (the node <-> line map breakpoints and stops use);
	///   `debug [-out <dir>] [-v]`: builds the `Debuggee` fixture (Debug) in a scratch folder and
	///   runs it under Beef's debugger engine: breakpoints set from nodes (the entry of Main, the
	///   print in Greeter.Hello), stop, the stopped node, locals, values of pins, Step Over / Into /
	///   Out, Continue to the exit code and the program's output; then a run that faults (the
	///   stop at the faulting node, the fault text) and Stop.
	static class DebugTests
	{
		static int sChecks;
		static int sFailures;
		static bool sVerbose;

		static void Check(bool ok, StringView what)
		{
			sChecks++;
			if (!ok)
			{
				sFailures++;
				Console.WriteLine("FAIL {}", what);
			}
			else if (sVerbose)
				Console.WriteLine("ok   {}", what);
		}

		// ---------------------------------------------------------------- debugmap

		public static int RunMap(String[] args)
		{
			List<String> paths = scope .();
			defer { ClearAndDeleteItems!(paths); }
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-v")
					sVerbose = true;
				else
					paths.Add(new String(args[i]));
			}
			int files = 0, methods = 0, statements = 0, values = 0, noLine = 0, failures = 0;
			List<String> all = scope .();
			defer { ClearAndDeleteItems!(all); }
			for (let p in paths)
			{
				if (File.Exists(p))
					all.Add(new String(p));
				else
					Collect(p, all);
			}
			for (let path in all)
			{
				SourceDocument doc = scope .();
				if (doc.Load(path) case .Err)
					continue;
				files++;
				for (let mg in doc.Methods)
				{
					if (!mg.Graphable || !mg.Method.HasSpan || mg.IsBroken)
						continue;
					methods++;
					let g = mg.Graph;
					let first = doc.Unit.LineOf(doc.Unit.Tokens[mg.Method.FirstTok].Start);
					let last = doc.Unit.LineOf(doc.Unit.Tokens[mg.Method.LastTok].End);
					for (let n in g.Nodes)
					{
						let line = DebugMap.LineOf(g, n);
						if (line <= 0)
						{
							noLine++;
							continue;
						}
						if (n.IsPure)
							values++;
						else
							statements++;
						bool inside = line >= first && line <= last;
						let back = DebugMap.NodeAt(doc, line, let backMg);
						bool same = back != null && backMg == mg && DebugMap.LineOf(g, back) == line;
						if (!inside || !same)
						{
							failures++;
							if (failures <= 25)
							{
								String title = scope .();
								n.GetTitle(title);
								String backTitle = scope .();
								back?.GetTitle(backTitle);
								Console.WriteLine("FAIL {}:{} {} '{}' ({}): inside={} maps back to {} '{}' (line {})", path, line, mg.Key, title, n.Kind,
									inside, (back != null) ? back.Kind.ToString(.. scope .()) : "nothing", backTitle,
									(back != null) ? DebugMap.LineOf((backMg != null) ? backMg.Graph : g, back) : 0);
							}
						}
					}
				}
			}
			Console.WriteLine("debugmap: files={} methods={} statements={} values={} without-line={} failures={}", files, methods, statements, values, noLine, failures);
			return failures == 0 ? 0 : 1;
		}

		static void Collect(StringView dir, List<String> outFiles)
		{
			if (!Directory.Exists(dir))
				return;
			for (let entry in Directory.EnumerateFiles(dir))
			{
				String path = scope .();
				entry.GetFilePath(path);
				if (path.EndsWith(".bf"))
					outFiles.Add(new String(path));
			}
			for (let entry in Directory.EnumerateDirectories(dir))
			{
				String path = scope .();
				entry.GetFilePath(path);
				String name = scope .();
				entry.GetFileName(name);
				if (name == "build" || name == "recovery" || name.StartsWith('.'))
					continue;
				Collect(path, outFiles);
			}
		}

		// ---------------------------------------------------------------- debug session

		static void FixtureDir(String outDir, String path = Compiler.CallerFilePath)
		{
			String src = scope .();
			Path.GetDirectoryPath(path, src).IgnoreError(); // ...\VisualBeefTests\src
			Path.GetDirectoryPath(src, outDir).IgnoreError(); // ...\VisualBeefTests
			outDir.Append("\\fixtures\\Debuggee");
		}

		static void CopyTree(StringView from, StringView to)
		{
			Directory.CreateDirectory(to).IgnoreError();
			for (let entry in Directory.EnumerateFiles(from))
			{
				String name = scope .();
				entry.GetFileName(name);
				String src = scope .();
				entry.GetFilePath(src);
				File.Copy(src, scope $"{to}\\{name}", true).IgnoreError();
			}
			for (let entry in Directory.EnumerateDirectories(from))
			{
				String name = scope .();
				entry.GetFileName(name);
				String src = scope .();
				entry.GetFilePath(src);
				CopyTree(src, scope $"{to}\\{name}");
			}
		}

		/// BeefBuild at BelowNormal; returns the exit code.
		static int Build(StringView ws, String outText)
		{
			ProcessStartInfo psi = scope .();
			psi.SetFileName(@"C:\Program Files\BeefLang\bin\BeefBuild.exe");
			psi.SetArguments(scope $"\"-workspace={ws}\" -config=Debug -platform=Win64");
			psi.SetWorkingDirectory(ws);
			psi.UseShellExecute = false;
			psi.RedirectStandardOutput = true;
			psi.CreateNoWindow = true;
			SpawnedProcess process = scope .();
			if (process.Start(psi) case .Err)
				return -1;
			LowPriority.Apply(process.ProcessId);
			FileStream stream = scope .();
			if (process.AttachStandardOutput(stream) case .Ok)
			{
				StreamReader reader = scope .(stream, null, false, 4096);
				reader.ReadToEnd(outText).IgnoreError();
			}
			process.WaitFor();
			return process.ExitCode;
		}

		/// Updates the session until it stops or ends (or `ms` pass); collects the program's output.
		static bool WaitStop(DebugSession s, String output, int ms = 30000)
		{
			let sw = scope Stopwatch(true);
			List<DebugEvent> events = scope .();
			while (sw.ElapsedMilliseconds < ms)
			{
				s.Update();
				s.TakeEvents(events);
				for (let e in events)
				{
					if (e.Kind == .Output)
						output.Append(e.Text);
					else if (sVerbose && (e.Kind == .Message || e.Kind == .Error))
						Console.WriteLine("    [{}] {}", e.Kind, e.Text);
				}
				ClearAndDeleteItems!(events);
				if (s.State == .Stopped || s.State == .NotDebugging)
					return true;
				Thread.Sleep(5);
			}
			return false;
		}

		static MethodGraph Method(SourceDocument doc, StringView name)
		{
			for (let mg in doc.Methods)
				if (mg.Graphable && mg.Method.Name == name)
					return mg;
			return null;
		}

		static Node FindCall(Graph g, StringView text, int nth = 0)
		{
			int seen = 0;
			for (let n in g.Nodes)
				if (n.Kind == .Call && n.Text == text && seen++ == nth)
					return n;
			return null;
		}

		static void Where(DebugSession s, String outText)
		{
			if (s.Frames.IsEmpty)
				outText.Append("(no frames)");
			else
				outText.AppendF("{} {}:{}", s.Frames[0].Name, s.Frames[0].File, s.Frames[0].Line);
		}

		public static int RunSession(String[] args)
		{
			String outDir = scope .();
			Path.GetTempPath(outDir).IgnoreError(); // a failed temp lookup leaves a relative scratch folder
			outDir.Append("vb-debug");
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-out" && i + 1 < args.Count)
					outDir.Set(args[++i]);
				else if (args[i] == "-v")
					sVerbose = true;
			}
			outDir.Replace('/', '\\');
			while (outDir.EndsWith('\\'))
				outDir.RemoveFromEnd(1);
			String fixture = scope .();
			FixtureDir(fixture);
			CopyTree(fixture, outDir);
			String buildOut = scope .();
			let code = Build(outDir, buildOut);
			Check(code == 0, scope $"the Debuggee fixture builds in Debug (exit {code})");
			if (code != 0)
			{
				Console.WriteLine(buildOut);
				return 1;
			}

			let file = scope $"{outDir}\\src\\Program.bf";
			SourceDocument doc = scope .();
			Check(doc.Load(file) case .Ok, "Program.bf loads");
			let hello = Method(doc, "Hello");
			let add = Method(doc, "Add");
			let main = Method(doc, "Main");
			Check(hello != null && add != null && main != null, "Hello, Add and Main have graphs");
			if (hello == null || add == null || main == null)
				return 1;
			let print = FindCall(hello.Graph, "WriteLine");
			let print2 = FindCall(hello.Graph, "WriteLine", 1);
			Node total = null;
			for (let n in hello.Graph.Nodes)
				if (n.Kind == .LocalVar && n.Text == "total")
					total = n;
			let printLine = DebugMap.LineOf(hello.Graph, print);
			let mainEntryLine = DebugMap.LineOf(main.Graph, main.Graph.Entry);
			Check(printLine > 0 && doc.Unit.Text.Contains("Console.WriteLine(\"Hello {}\", name);"), scope $"the print node has a line ({printLine})");
			Check(mainEntryLine > 0, scope $"Main's entry node has a line: the body's brace ({mainEntryLine})");
			String why = scope .();
			Check(DebugMap.LineOf(hello.Graph, hello.Graph.Entry) > 0 && total != null && DebugMap.LineOf(hello.Graph, total, why) > 0, "Local total (with a value) has a line");

			DebugTarget target = scope .();
			String err = scope .();
			Check(target.Resolve(outDir, "Debug", err), scope $"the target resolves from BeefSpace / BeefProj: {target.Exe} {err}");
			Check(target.Exe.EndsWith("\\build\\Debug_Win64\\Debuggee\\Debuggee.exe") && DebugSession.SamePath(target.WorkDir, outDir), scope $"exe and working folder as the Beef IDE ({target.Exe}, {target.WorkDir})");

			String output = scope .();
			{
				DebugSession s = scope .();
				s.SourceRoot.Set(outDir);
				let bpEntry = s.AddBreakpoint(file, mainEntryLine, main.Graph.Entry);
				// A second breakpoint on the statement the entry's one binds to: two nodes, one bound line.
				// The stop must name the statement's own breakpoint (the entry one was added first).
				Node firstStmt = null;
				for (let n in main.Graph.Nodes)
					if (n.Kind == .LocalVar && (firstStmt == null || DebugMap.LineOf(main.Graph, n) < DebugMap.LineOf(main.Graph, firstStmt)))
						firstStmt = n;
				Check(firstStmt != null, "Main has a first statement node");
				let bpFirst = s.AddBreakpoint(file, DebugMap.LineOf(main.Graph, firstStmt), firstStmt);
				let bpPrint = s.AddBreakpoint(file, printLine);
				err.Clear();
				let launched = s.Launch(target.Exe, "", target.WorkDir, err);
				Check(launched, scope $"Launch: {err}");
				if (!launched)
				{
					Console.WriteLine("  engine: {} {}", DebugEngine.DllPath, DebugEngine.LoadError);
					return 1;
				}
				String at = scope .();

				// 1. The entry breakpoint of Main.
				Check(WaitStop(s, output) && s.State == .Stopped, "stops (Main's entry breakpoint)");
				Where(s, at);
				MethodGraph stopMg = null;
				Node stopNode = s.Frames.IsEmpty ? null : DebugMap.NodeAt(doc, s.Frames[0].Line, out stopMg);
				// The `{` line has no code of its own: the engine binds the breakpoint to the first
				// statement, and the stop is shown on the node the breakpoint was set on (its Tag).
				let hit = s.HitBreakpoint();
				Check(s.Reason == .Breakpoint && stopMg == main && hit == bpFirst && hit.Tag == firstStmt, scope $"two breakpoints share the bound line: the stop names the statement's own, not the entry's added first ({at}, reason {s.Reason}, bound line {bpEntry.BoundLine})");
				Check(bpEntry.BoundLine == bpFirst.BoundLine && bpEntry.Line != bpFirst.Line, "the entry breakpoint and the statement's one bind to the same line");
				Check(stopNode != null && stopNode.Kind == .LocalVar && bpEntry.BoundLine == DebugMap.LineOf(main.Graph, stopNode), scope $"the entry breakpoint is bound to Main's first statement ({(stopNode != null) ? stopNode.Kind.ToString(.. scope .()) : "none"})");
				Check(bpPrint.Bound && bpPrint.BoundLine == printLine, scope $"the print breakpoint is bound at its line ({bpPrint.BoundLine})");

				// 2. Continue to the print in Hello.
				s.Continue();
				Check(WaitStop(s, output) && s.State == .Stopped, "Continue: stops again");
				at.Clear();
				Where(s, at);
				stopNode = s.Frames.IsEmpty ? null : DebugMap.NodeAt(doc, s.Frames[0].Line, out stopMg);
				Check(stopNode == print && stopMg == hello && DebugSession.SamePath(s.Frames[0].File, file), scope $"stopped at the print node in Hello ({at})");
				Check(s.Frames.Count >= 2 && s.Frames[1].Name.Contains("Main"), scope $"the call stack has Main under Hello ({s.Frames.Count} frames)");

				// Locals and values.
				List<String> locals = scope .();
				defer { ClearAndDeleteItems!(locals); }
				s.GetLocals(0, locals);
				String names = scope .();
				names.Join(", ", locals.GetEnumerator());
				Check(locals.Contains("name") && locals.Contains("this"), scope $"locals of Hello: {names}");
				EvalValue v = scope .();
				Check(s.Evaluate("name", 0, v) && v.Value.Contains("Beef"), scope $"name = {v.Value} ({v.Type})");
				// The print's second input pin is wired from the entry's `name`: its expression is `name`.
				String expr = scope .();
				let namePin = print.FindInput("arg1");
				Check(namePin != null && DebugMap.PinExpr(hello.Graph, namePin, expr) && expr == "name", scope $"pin expression of the print's name input: '{expr}'");
				Check(s.Evaluate("this", 0, v) && !v.Members.IsEmpty, scope $"this = {v.Value}, {v.Members.Count} members");
				String countExpr = scope .();
				for (let m in v.Members)
					if (m.name == "mCount")
						countExpr.Set(m.expr);
				EvalValue mv = scope .();
				Check(!countExpr.IsEmpty && s.Evaluate(countExpr, 0, mv) && mv.Value == "3", scope $"this.mCount via its member expression '{countExpr}' = {mv.Value}");
				Check(!s.Evaluate("Add(1, 2)", 0, mv) || !mv.Value.Contains("3"), scope $"a call is not run by Evaluate ({mv.Value})");
				Check(!s.Evaluate("noSuchName", 0, mv) && !mv.Value.IsEmpty, scope $"an unknown name fails with a reason: {mv.Value}");

				// 3. Step Over: the next node (Local total).
				s.StepOver();
				Check(WaitStop(s, output) && s.State == .Stopped && s.Reason == .Step, "Step Over stops");
				at.Clear();
				Where(s, at);
				stopNode = s.Frames.IsEmpty ? null : DebugMap.NodeAt(doc, s.Frames[0].Line, out stopMg);
				Check(stopNode == total, scope $"Step Over: at Local total ({at})");
				Check(output.Contains("Hello Beef"), scope $"the print ran: program output '{output}'");

				// 4. Step Into Add.
				s.StepInto();
				Check(WaitStop(s, output) && s.State == .Stopped, "Step Into stops");
				at.Clear();
				Where(s, at);
				stopNode = s.Frames.IsEmpty ? null : DebugMap.NodeAt(doc, s.Frames[0].Line, out stopMg);
				Check(stopMg == add, scope $"Step Into: inside Add ({at})");
				Check(s.Evaluate("a", 0, v) && v.Value == "2", scope $"a = {v.Value}");

				// 5. Step Out: back in Hello.
				s.StepOut();
				Check(WaitStop(s, output) && s.State == .Stopped, "Step Out stops");
				at.Clear();
				Where(s, at);
				stopNode = s.Frames.IsEmpty ? null : DebugMap.NodeAt(doc, s.Frames[0].Line, out stopMg);
				Check(stopMg == hello, scope $"Step Out: back in Hello ({at})");
				Check(s.Evaluate("mCount", 0, v) && v.Value == "10", scope $"mCount after Add = {v.Value}");

				// 6. Continue to the end.
				s.Continue();
				Check(WaitStop(s, output) && s.State == .NotDebugging, "Continue: the program runs to its end");
				Check(s.ExitCode == 7, scope $"exit code 7 ({s.ExitCode})");
				Check(output.Contains("Total 7") && output.Contains("Done"), scope $"the program's output came through: '{output}'");
				Check(print2 != null, "the second print exists");
			}

			// A fault: stop at the node, the fault's text, then Stop.
			{
				output.Clear();
				DebugSession s = scope .();
				s.SourceRoot.Set(outDir);
				err.Clear();
				Check(s.Launch(target.Exe, "crash", target.WorkDir, err), scope $"Launch with 'crash': {err}");
				Check(WaitStop(s, output) && s.State == .Stopped, scope $"the fault stops the program ({s.State})");
				String at = scope .();
				Where(s, at);
				MethodGraph stopMg = null;
				let node = s.Frames.IsEmpty ? null : DebugMap.NodeAt(doc, s.Frames[0].Line, out stopMg);
				bool onSet = false;
				// The fault may be reported in the runtime's null check (frame 0 in corlib): the first frame in the Sheet counts.
				for (let f in s.Frames)
				{
					if (!DebugSession.SamePath(f.File, file))
						continue;
					let n = DebugMap.NodeAt(doc, f.Line, out stopMg);
					onSet = n != null && n.Kind == .Set && stopMg == main;
					break;
				}
				Check(s.Reason == .Exception || s.Reason == .Breakpoint, scope $"stopped by the fault (reason {s.Reason}: {s.ExceptionText})");
				Check(onSet, scope $"the faulting node is the Set of missing.mCount ({at}; frame-0 node {(node != null) ? node.Kind.ToString(.. scope .()) : "none"})");
				s.Stop();
				Check(WaitStop(s, output, 10000) && s.State == .NotDebugging, "Stop ends the session");
			}

			// Pause a running program: the main thread is shown (its frames reach Main), then Stop.
			{
				output.Clear();
				DebugSession s = scope .();
				s.SourceRoot.Set(outDir);
				err.Clear();
				Check(s.Launch(target.Exe, "loop", target.WorkDir, err), scope $"Launch with 'loop': {err}");
				WaitStop(s, output, 1500); // runs; nothing stops it
				Check(s.State == .Running, scope $"the looping program runs ({s.State})");
				s.Pause();
				Check(WaitStop(s, output, 10000) && s.State == .Stopped && s.Reason == .Pause, scope $"Pause stops it (reason {s.Reason})");
				bool inMain = false;
				for (let f in s.Frames)
					if (f.Name.Contains("Program.Main") && DebugSession.SamePath(f.File, file))
						inMain = true;
				String at = scope .();
				Where(s, at);
				Check(inMain, scope $"after Pause the call stack is the main thread's, down to Main ({s.Frames.Count} frames, top {at})");
				s.Continue();
				WaitStop(s, output, 300);
				Check(s.State == .Running, "Continue after Pause runs again");
				s.Stop();
				Check(WaitStop(s, output, 10000) && s.State == .NotDebugging && s.ProcessId != 0, "Stop ends the looping program");
			}
			Console.WriteLine("debug checks: {}  failures: {}", sChecks, sFailures);
			return sFailures == 0 ? 0 : 1;
		}
	}
}
