using System;
using System.Collections;
using System.IO;
using System.Threading;
using System.Diagnostics;

namespace VisualBeef.Debug
{
	/// What a session is doing, as the editor shows it.
	enum DebugState
	{
		NotDebugging,
		/// Launched or attached; the program has not stopped yet.
		Running,
		/// Stopped at a breakpoint, after a step, a pause or a fault: frames, locals and values can be read.
		Stopped,
		/// Stop was asked; waiting for the process to end.
		Stopping
	}

	enum StopReason
	{
		None,
		Breakpoint,
		Step,
		Pause,
		/// An unhandled fault (access violation, a failed assert, ...): ExceptionText says which.
		Exception
	}

	enum DebugEventKind
	{
		Started,
		Stopped,
		Resumed,
		/// Text the program wrote to stdout / stderr.
		Output,
		/// A line from the debugger itself ("Process terminated. ExitCode: 0.").
		Message,
		Error,
		Exited
	}

	class DebugEvent
	{
		public DebugEventKind Kind;
		public String Text = new .() ~ delete _;
	}

	/// One frame of the call stack (frame 0 is where the program stopped).
	class DebugFrame
	{
		/// What the engine shows for the frame ("Greeter.Hello()", "Program.Main(...)").
		public String Name = new .() ~ delete _;
		/// Source file ("" when the code has no source: system DLLs, the runtime's startup code).
		public String File = new .() ~ delete _;
		/// 1-based; 0 = unknown.
		public int32 Line;
		public int Address;
		public bool HasSource => !File.IsEmpty && Line > 0;
	}

	/// A breakpoint by source line. The editor keeps the node it came from in Tag.
	class DebugBreakpoint
	{
		public String File = new .() ~ delete _;
		/// 1-based line asked for.
		public int32 Line;
		public Object Tag;
		/// Native breakpoint while a session runs.
		public void* Native;

		/// The engine found code for the line (only meaningful while a session runs).
		public bool Bound
		{
			get
			{
				if (Native == null)
					return false;
				void* sibling = null;
				return DebugEngine.Breakpoint_GetAddress(Native, &sibling) != 0;
			}
		}

		/// The 1-based line the engine bound to (the next line with code when the asked one has none).
		public int32 BoundLine => (Native != null) ? (int32)DebugEngine.Breakpoint_GetLineNum(Native) + 1 : 0;
	}

	/// The value of an expression in a frame, as the engine formats it.
	class EvalValue
	{
		/// The value text ("5", "\"Hello\"", "{ Greeter }"), or the reason when Failed.
		public String Value = new .() ~ delete _;
		public String Type = new .() ~ delete _;
		public bool Failed;
		/// Members that can be expanded: (name, expression to evaluate for it).
		public List<(String name, String expr)> Members = new .() ~ { for (let m in _) { delete m.name; delete m.expr; } delete _; };

		public void Clear()
		{
			Value.Clear();
			Type.Clear();
			Failed = false;
			for (let m in Members) { delete m.name; delete m.expr; }
			Members.Clear();
		}
	}

	/// One debugging session over Beef's debugger engine (DebugEngine): launch a program (or
	/// attach to a running one), breakpoints by (file, line), stepping, the call stack, locals and
	/// evaluation. Not thread-safe: every call comes from one thread (the editor's UI thread),
	/// which also calls Update() regularly; Update turns the engine's state into DebugEvents.
	class DebugSession
	{
		enum Command { None, Continue, StepOver, StepInto, StepOut, Pause }

		static DebugSession sActive;
		/// The session that owns the engine right now (there is one engine per process).
		public static DebugSession Active => sActive;

		public DebugState State { get; private set; }
		public StopReason Reason { get; private set; }
		/// Exit code of the last run; int32.MinValue while unknown.
		public int32 ExitCode = int32.MinValue;
		/// Bumped on every stop (keys caches of values read while stopped).
		public int32 StopCount;
		public String ExceptionText = new .() ~ delete _;
		public String LastError = new .() ~ delete _;
		/// Step Into stays inside this folder: a step that lands in a file outside it (a library,
		/// corlib) steps out again, so stepping walks your own code. Empty = no limit.
		public String SourceRoot = new .() ~ delete _;
		public List<DebugBreakpoint> Breakpoints = new .() ~ DeleteContainerAndItems!(_);
		/// The call stack at the last stop.
		public List<DebugFrame> Frames = new .() ~ DeleteContainerAndItems!(_);
		/// Process id of the program being debugged (0 when none).
		public int32 ProcessId { get; private set; }
		public bool Attached { get; private set; }

		List<DebugEvent> mEvents = new .() ~ DeleteContainerAndItems!(_);
		Command mLastCommand;
		bool mHadInitBreak;
		int mAutoStepOuts;
		Stopwatch mStopWatch ~ delete _;
		bool mHaveStdHandles;
		/// What the output reader threads share with the session. Held by pointer, not by the
		/// session's fields: a reader still blocked in ReadFile when the session is deleted (a
		/// child process kept the pipe open) must not touch freed memory, so then it is left to
		/// the reader (`Abandoned`) instead of being freed.
		class ReaderShared
		{
			public Monitor Lock = new .() ~ delete _;
			public String Pending = new .() ~ delete _;
			public bool Abandoned;
		}
		ReaderShared mOut = new .();
		Monitor mOutLock => mOut.Lock;
		String mOutPending => mOut.Pending;
		List<Thread> mReaders = new .() ~ delete _;

		public bool IsActive => State != .NotDebugging;
		public bool IsStopped => State == .Stopped;

		public ~this()
		{
			if (IsActive)
			{
				Stop();
				let sw = scope Stopwatch(true);
				while (IsActive && sw.ElapsedMilliseconds < 5000)
				{
					Update();
					Thread.Sleep(5);
				}
				if (IsActive)
					Finish();
			}
			bool allDone = true;
			for (let t in mReaders)
			{
				if (t.Join(500))
					delete t;
				else
					allDone = false; // still blocked on the pipe: the thread and mOut stay alive
			}
			if (allDone)
				delete mOut;
			else
			{
				using (mOut.Lock.Enter())
					mOut.Abandoned = true;
			}
			if (sActive == this)
				sActive = null;
		}

		// ---------------------------------------------------------------- start / stop

		bool Begin(String outError)
		{
			if (sActive != null && sActive != this && sActive.IsActive)
			{
				outError.Set("Another debugging session is running.");
				return false;
			}
			if (IsActive)
			{
				outError.Set("Already debugging.");
				return false;
			}
			if (!DebugEngine.EnsureCreated())
			{
				outError.AppendF("{} ({})", DebugEngine.NeedBeef, DebugEngine.LoadError);
				return false;
			}
			sActive = this;
			ExitCode = int32.MinValue;
			ExceptionText.Clear();
			LastError.Clear();
			Reason = .None;
			mHadInitBreak = false;
			mAutoStepOuts = 0;
			mLastCommand = .None;
			mHaveStdHandles = false;
			ClearAndDeleteItems!(Frames);
			return true;
		}

		/// Starts `exe` under the debugger (stdout and stderr come back as Output events). The
		/// breakpoints already added are set before the program runs.
		public bool Launch(StringView exe, StringView args, StringView workDir, String outError)
		{
			if (!Begin(outError))
				return false;
			if (!File.Exists(exe))
			{
				outError.AppendF("The program to debug was not found: {}", exe);
				if (sActive == this)
					sActive = null;
				return false;
			}
			String exeFull = scope .(exe);
			exeFull.Replace('/', '\\');
			String dir = scope .(workDir);
			dir.Replace('/', '\\');
			// RedirectStdOutput | RedirectStdError (DbgOpenFileFlags 2 | 4): the console output comes
			// back through pipes, and the program gets no console window.
			if (!DebugEngine.Debugger_OpenFile(exeFull, exeFull, scope String(args), dir, null, 0, false, 2 | 4))
			{
				DrainMessages();
				outError.Set(LastError.IsEmpty ? scope $"The debugger could not open {exe}" : LastError);
				sActive = null;
				return false;
			}
			Attached = false;
			Started();
			return true;
		}

		/// Attaches to a running process (phase 2: a game started by the UMP launcher). Stop then
		/// detaches and leaves the process running.
		public bool Attach(int32 processId, String outError)
		{
			if (!Begin(outError))
				return false;
			if (!DebugEngine.Debugger_Attach(processId, 0))
			{
				DrainMessages();
				outError.Set(LastError.IsEmpty ? scope $"Could not attach to process {processId}" : LastError);
				sActive = null;
				return false;
			}
			Attached = true;
			Started();
			return true;
		}

		void Started()
		{
			for (let bp in Breakpoints)
				CreateNative(bp);
			DebugEngine.Debugger_Run();
			State = .Running;
			ProcessId = 0;
			Post(.Started, "");
		}

		void CreateNative(DebugBreakpoint bp)
		{
			if (bp.Native != null)
				return;
			String file = scope .(bp.File);
			file.Replace('/', '\\');
			// The engine counts lines from 0.
			bp.Native = DebugEngine.Debugger_CreateBreakpoint(file, bp.Line - 1, 0, -1);
			if (bp.Native != null)
				DebugEngine.Breakpoint_Check(bp.Native);
		}

		/// Ends the session: kills a launched program, detaches from an attached one. The
		/// Exited event follows from Update.
		public void Stop()
		{
			if (State == .NotDebugging || State == .Stopping)
				return;
			State = .Stopping;
			delete mStopWatch;
			mStopWatch = new Stopwatch(true);
			DebugEngine.Debugger_StopDebugging();
		}

		/// Back to "not debugging": native breakpoints deleted, the engine detached.
		void Finish()
		{
			for (let bp in Breakpoints)
			{
				if (bp.Native != null)
				{
					DebugEngine.Breakpoint_Delete(bp.Native);
					bp.Native = null;
				}
			}
			DebugEngine.Debugger_Detach();
			DrainOutput();
			State = .NotDebugging;
			ClearAndDeleteItems!(Frames);
			String text = scope .();
			if (ExitCode != int32.MinValue)
				text.AppendF("{}", ExitCode);
			Post(.Exited, text);
			if (sActive == this)
				sActive = null;
		}

		// ---------------------------------------------------------------- breakpoints

		public DebugBreakpoint AddBreakpoint(StringView file, int32 line, Object tag = null)
		{
			let bp = new DebugBreakpoint();
			bp.File.Set(file);
			bp.Line = line;
			bp.Tag = tag;
			Breakpoints.Add(bp);
			if (IsActive && State != .Stopping)
				CreateNative(bp);
			return bp;
		}

		public void RemoveBreakpoint(DebugBreakpoint bp)
		{
			if (bp.Native != null && IsActive)
				DebugEngine.Breakpoint_Delete(bp.Native);
			bp.Native = null;
			Breakpoints.Remove(bp);
			delete bp;
		}

		public void ClearBreakpoints()
		{
			while (!Breakpoints.IsEmpty)
				RemoveBreakpoint(Breakpoints.Back);
		}

		public DebugBreakpoint FindBreakpoint(StringView file, int32 line)
		{
			for (let bp in Breakpoints)
				if (bp.Line == line && SamePath(bp.File, file))
					return bp;
			return null;
		}

		/// The breakpoint the program stopped at (bound to frame 0's line), or null. The engine may
		/// bind a breakpoint to a later line than the one asked for (a line with no code of its
		/// own, like a function's `{`); its Tag still names what it was set on.
		public DebugBreakpoint HitBreakpoint()
		{
			if (State != .Stopped || Reason != .Breakpoint || Frames.IsEmpty || !Frames[0].HasSource)
				return null;
			let f = Frames[0];
			// Several breakpoints can share a bound line (a function's `{` and its first statement
			// both bind to that statement). The best candidate: the one bound at the stop's address,
			// then the one asked for on exactly the stopped line, then the nearest one asked for
			// above it (a bind moves to a later line, never an earlier one).
			DebugBreakpoint best = null;
			int bestScore = int.MinValue;
			for (let bp in Breakpoints)
			{
				if (bp.Native == null || !SamePath(bp.File, f.File) || !(bp.BoundLine == f.Line || bp.Line == f.Line))
					continue;
				int score = 0;
				void* sibling = null;
				if (f.Address != 0 && DebugEngine.Breakpoint_GetAddress(bp.Native, &sibling) == f.Address)
					score += 1000000;
				if (bp.Line == f.Line)
					score += 500000;
				score -= Math.Abs(f.Line - bp.Line);
				if (score > bestScore)
				{
					best = bp;
					bestScore = score;
				}
			}
			return best;
		}

		// ---------------------------------------------------------------- run control

		void Resume(Command cmd)
		{
			mLastCommand = cmd;
			State = .Running;
			Reason = .None;
			ClearAndDeleteItems!(Frames);
			Post(.Resumed, "");
		}

		public void Continue()
		{
			if (State != .Stopped)
				return;
			Resume(.Continue);
			DebugEngine.Debugger_Continue();
		}

		public void StepOver()
		{
			if (State != .Stopped)
				return;
			Resume(.StepOver);
			DebugEngine.Debugger_StepOver(false);
		}

		public void StepInto()
		{
			if (State != .Stopped)
				return;
			Resume(.StepInto);
			mAutoStepOuts = 0;
			DebugEngine.Debugger_StepInto(false);
		}

		public void StepOut()
		{
			if (State != .Stopped)
				return;
			Resume(.StepOut);
			DebugEngine.Debugger_StepOut(false);
		}

		/// Breaks into the running program (Break All).
		public void Pause()
		{
			if (State != .Running)
				return;
			mLastCommand = .Pause;
			DebugEngine.Debugger_BreakAll();
		}

		// ---------------------------------------------------------------- update

		/// Call regularly (every frame). Reads the engine's messages and the program's output and
		/// turns state changes into events (TakeEvents).
		public void Update()
		{
			if (State == .NotDebugging)
				return;
			DebugEngine.Debugger_Update();
			if (!mHaveStdHandles)
				GrabStdHandles();
			DrainMessages();
			DrainOutput();
			if (ProcessId == 0)
				ProcessId = DebugEngine.Debugger_GetProcessId();

			let rs = (EngineRunState)DebugEngine.Debugger_GetRunState();
			if (rs == .Terminated)
			{
				Finish();
				return;
			}
			if (State == .Stopping)
			{
				// A launched program is killed; give it a moment, then force it.
				if (mStopWatch != null && mStopWatch.ElapsedMilliseconds > 3000 && rs != .Terminating)
				{
					mStopWatch.Restart();
					DebugEngine.Debugger_Terminate();
				}
				return;
			}
			bool paused = rs == .Paused || rs == .Breakpoint || rs == .Exception;
			if (!paused || DebugEngine.Debugger_HasPendingDebugLoads() || State == .Stopped)
				return;

			if (!mHadInitBreak)
			{
				// The loader's first break (or the attach break): not a stop the user asked for.
				mHadInitBreak = true;
				if (rs != .Exception)
				{
					DebugEngine.Debugger_Continue();
					return;
				}
			}

			if (mLastCommand == .Pause)
				SelectMainThread();
			ReadFrames();

			// Step Into landed outside your code (a library, corlib): step back out.
			if (mLastCommand == .StepInto && rs != .Exception && rs != .Breakpoint && !SourceRoot.IsEmpty && mAutoStepOuts < 8)
			{
				if (Frames.IsEmpty || !Frames[0].HasSource || !IsUnder(Frames[0].File, SourceRoot))
				{
					mAutoStepOuts++;
					ClearAndDeleteItems!(Frames);
					DebugEngine.Debugger_StepOut(false);
					return;
				}
			}

			State = .Stopped;
			StopCount++;
			switch (rs)
			{
			case .Breakpoint: Reason = .Breakpoint;
			case .Exception: Reason = .Exception;
			default: Reason = (mLastCommand == .Pause) ? .Pause : (mLastCommand == .Continue || mLastCommand == .None) ? .Breakpoint : .Step;
			}
			ExceptionText.Clear();
			if (Reason == .Exception)
				ReadException(ExceptionText);
			mLastCommand = .None;
			Post(.Stopped, ExceptionText);
		}

		/// Events since the last call, oldest first; the caller deletes them.
		public void TakeEvents(List<DebugEvent> outEvents)
		{
			outEvents.AddRange(mEvents);
			mEvents.Clear();
		}

		void Post(DebugEventKind kind, StringView text)
		{
			let e = new DebugEvent();
			e.Kind = kind;
			e.Text.Set(text);
			mEvents.Add(e);
		}

		void DrainMessages()
		{
			while (true)
			{
				let p = DebugEngine.Debugger_PopMessage();
				if (p == null)
					break;
				StringView msg = .(p);
				int sp = msg.IndexOf(' ');
				StringView cmd = (sp > 0) ? msg.Substring(0, sp) : msg;
				StringView param = (sp > 0) ? msg.Substring(sp + 1) : "";
				if (cmd == "msg" || cmd == "dbgEvalMsg" || cmd == "log")
				{
					var line = param;
					line.Trim();
					// "Process terminated. ExitCode: 0." (or "0x... (STATUS_DLL_NOT_FOUND)").
					int ec = line.IndexOf("ExitCode: ");
					if (line.StartsWith("Process terminated") && ec >= 0)
						ParseExitCode(line.Substring(ec + "ExitCode: ".Length));
					if (!line.IsEmpty)
						Post(.Message, line);
				}
				else if (cmd == "error" || cmd == "errorsoft")
				{
					String text = scope .(param);
					// Leak reports and other rich errors carry \x01 records; keep the readable part.
					int info = text.IndexOf('\x01');
					if (info >= 0)
						text.RemoveToEnd(info);
					text.Trim();
					if (!text.IsEmpty)
					{
						LastError.Set(text);
						Post(.Error, text);
					}
				}
				// "modulesChanged", "rehupLoc", "dbgInfoLoaded", "symsrv", ...: nothing to show.
			}
		}

		void ParseExitCode(StringView textIn)
		{
			var text = textIn;
			int end = 0;
			while (end < text.Length && (text[end].IsLetterOrDigit))
				end++;
			text = text.Substring(0, end);
			if (text.StartsWith("0x"))
			{
				if (uint32.Parse(text.Substring(2), .HexNumber) case .Ok(let v))
					ExitCode = (int32)v;
			}
			else if (int32.Parse(text) case .Ok(let v))
				ExitCode = v;
		}

		// ---------------------------------------------------------------- program output

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 ReadFile(void* h, void* buf, uint32 n, uint32* read, void* overlapped);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CloseHandle(void* h);
#endif

		/// The engine hands the pipe ends over once the process exists. Each comes as the
		/// engine's BfpFile object, whose first field is the Windows handle (BeefySysLib,
		/// platform/win/Platform.cpp); the handle is read here and closed at end of file.
		void GrabStdHandles()
		{
			void* outFile = null;
			void* errFile = null;
			DebugEngine.Debugger_GetStdHandles(null, &outFile, &errFile);
			if (outFile == null && errFile == null)
				return;
			mHaveStdHandles = true;
			for (let f in void*[2](outFile, errFile))
			{
				if (f == null)
					continue;
				void* handle = *(void**)f;
				let shared = mOut;
				let t = new Thread(new () => ReadPipe(handle, shared));
				t.SetName("VisualBeef debug output");
				t.Start(false);
				mReaders.Add(t);
			}
		}

		static void ReadPipe(void* handle, ReaderShared shared)
		{
#if BF_PLATFORM_WINDOWS
			uint8[4096] buf = ?;
			while (true)
			{
				uint32 read = 0;
				if (ReadFile(handle, &buf, 4096, &read, null) == 0 || read == 0)
					break;
				using (shared.Lock.Enter())
				{
					if (shared.Abandoned)
						continue; // the session is gone: drain the pipe, keep nothing
					for (int i < read)
					{
						let c = (char8)buf[i];
						if (c != '\r')
							shared.Pending.Append(c);
					}
				}
			}
			CloseHandle(handle);
#endif
		}

		void DrainOutput()
		{
			String text = scope .();
			using (mOutLock.Enter())
			{
				text.Set(mOutPending);
				mOutPending.Clear();
			}
			if (!text.IsEmpty)
				Post(.Output, text);
		}

		// ---------------------------------------------------------------- frames

		/// After a pause the stop is in the thread Windows made for the break; show the main thread.
		void SelectMainThread()
		{
			let info = DebugEngine.Debugger_GetThreadInfo();
			if (info == null)
				return;
			int32 firstId = 0;
			int32 mainId = 0;
			int lineNo = 0;
			for (let line in StringView(info).Split('\n'))
			{
				if (lineNo++ == 0)
					continue; // the active thread's id
				let parts = line.Split('\t');
				StringView idText = default;
				StringView name = default;
				int idx = 0;
				for (let p in parts)
				{
					if (idx == 0) idText = p;
					else if (idx == 1) name = p;
					idx++;
				}
				if (int32.Parse(idText) case .Ok(let id))
				{
					if (firstId == 0)
						firstId = id;
					if (name == "Main Thread" && mainId == 0)
						mainId = id;
				}
			}
			let pick = (mainId != 0) ? mainId : firstId;
			if (pick != 0)
				DebugEngine.Debugger_SetActiveThread(pick);
		}

		void ReadFrames()
		{
			ClearAndDeleteItems!(Frames);
			DebugEngine.CallStack_Update();
			int count = Math.Min(DebugEngine.CallStack_GetCount(), 256);
			for (int32 i < (int32)count)
			{
				int addr = 0;
				char8* file = null;
				int32 hotIdx = 0, defStart = 0, defEnd = 0, line = 0, column = 0, language = 0, stackSize = 0;
				int8 flags = 0;
				let name = DebugEngine.CallStack_GetStackFrameInfo(i, &addr, &file, &hotIdx, &defStart, &defEnd, &line, &column, &language, &stackSize, &flags);
				let f = new DebugFrame();
				if (name != null)
					f.Name.Append(name);
				if (file != null)
					f.File.Append(file);
				// The engine appends the source's hash ("...\Program.bf#B1609AA5...") to Beef files.
				int hash = f.File.LastIndexOf('#');
				if (hash > 0 && f.File.Length - hash - 1 >= 32 && IsHex(f.File.Substring(hash + 1)))
					f.File.RemoveToEnd(hash);
				f.Line = (line >= 0 && !f.File.IsEmpty) ? line + 1 : 0;
				f.Address = addr;
				Frames.Add(f);
			}
		}

		void ReadException(String outText)
		{
			let p = DebugEngine.Debugger_GetCurrentException();
			if (p == null)
				return;
			// "<address>\n<code>[\n<description>]"
			List<StringView> parts = scope .();
			for (let s in StringView(p).Split('\n'))
				parts.Add(s);
			if (parts.Count >= 3 && !parts[2].IsEmpty)
				outText.Append(parts[2]);
			else if (parts.Count >= 2)
				outText.AppendF("Exception {}", parts[1]);
			if (parts.Count >= 1 && !parts[0].IsEmpty)
				outText.AppendF(" at {}", parts[0]);
		}

		// ---------------------------------------------------------------- values

		/// Names of the variables in scope in a frame (the engine's auto locals).
		public void GetLocals(int32 frame, List<String> outNames)
		{
			if (State != .Stopped)
				return;
			let p = DebugEngine.Debugger_GetAutoLocals(frame, false);
			if (p == null)
				return;
			for (let s in StringView(p).Split('\n'))
				if (!s.IsEmpty)
					outNames.Add(new String(s));
		}

		/// Evaluates `expr` in `frame` (0 = where it stopped). Never calls functions in the
		/// program (no side effects): an expression that needs a call reports why it cannot be
		/// shown. A result the engine only has later (`!pending`) is waited for up to `timeoutMs`.
		public bool Evaluate(StringView expr, int32 frame, EvalValue outValue, int timeoutMs = 500)
		{
			outValue.Clear();
			if (State != .Stopped)
			{
				outValue.Failed = true;
				outValue.Value.Set("not stopped");
				return false;
			}
			String result = scope .();
			DebugEngine.EvalResult r = default;
			DebugEngine.Debugger_Evaluate(&r, scope String(expr), frame, -1, -1, 0);
			if (r.Ptr != null && r.Length > 0)
				result.Append(r.Ptr, r.Length);
			if (result.StartsWith("!pending"))
			{
				let sw = scope Stopwatch(true);
				while (sw.ElapsedMilliseconds < timeoutMs)
				{
					DebugEngine.Debugger_Update();
					Thread.Sleep(2);
					let p = DebugEngine.Debugger_EvaluateContinue();
					result.Clear();
					if (p != null)
						result.Append(p);
					if (!result.StartsWith("!pending"))
						break;
				}
				if (result.StartsWith("!pending"))
				{
					outValue.Failed = true;
					outValue.Value.Set("timed out");
					return false;
				}
			}
			ParseEval(result, expr, outValue);
			return !outValue.Failed;
		}

		/// The engine's result text: line 1 the value (or "!<start>\t<len>\t<error>"), line 2 the
		/// type, then ":command" lines and member lines "name\t<expression with {0} = parent>".
		public static void ParseEval(StringView result, StringView parentExpr, EvalValue outValue)
		{
			int lineNo = 0;
			for (let line in result.Split('\n'))
			{
				if (lineNo == 0)
				{
					if (line.StartsWith('!'))
					{
						outValue.Failed = true;
						var err = line.Substring(1);
						// "start\tlength\tmessage" or just the message.
						int t1 = err.IndexOf('\t');
						int t2 = (t1 >= 0) ? err.Substring(t1 + 1).IndexOf('\t') : -1;
						if (t1 >= 0 && t2 >= 0)
							err = err.Substring(t1 + 1 + t2 + 1);
						outValue.Value.Set(err);
					}
					else
						outValue.Value.Set(line);
				}
				else if (lineNo == 1)
					outValue.Type.Set(line);
				else if (!line.IsEmpty && !line.StartsWith(':'))
				{
					int tab = line.IndexOf('\t');
					if (tab > 0)
					{
						String name = new .(line.Substring(0, tab));
						String expr = new .();
						var fmt = line.Substring(tab + 1);
						int t2 = fmt.IndexOf('\t');
						if (t2 >= 0)
							fmt = fmt.Substring(0, t2);
						ExpandFormat(fmt, parentExpr, expr);
						outValue.Members.Add((name, expr));
					}
				}
				lineNo++;
			}
		}

		/// `{0}` = the parent expression; `{{` / `}}` are literal braces.
		static void ExpandFormat(StringView fmt, StringView parent, String outText)
		{
			for (int i = 0; i < fmt.Length; i++)
			{
				let c = fmt[i];
				if (c == '{' && i + 1 < fmt.Length && fmt[i + 1] == '{')
				{
					outText.Append('{');
					i++;
				}
				else if (c == '}' && i + 1 < fmt.Length && fmt[i + 1] == '}')
				{
					outText.Append('}');
					i++;
				}
				else if (c == '{' && i + 2 < fmt.Length && fmt[i + 1] == '0' && fmt[i + 2] == '}')
				{
					outText.Append(parent);
					i += 2;
				}
				else
					outText.Append(c);
			}
		}

		// ---------------------------------------------------------------- paths

		static bool IsHex(StringView s)
		{
			for (let c in s.RawChars)
				if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f')))
					return false;
			return true;
		}

		public static bool SamePath(StringView a, StringView b)
		{
			if (a.Length != b.Length)
				return false;
			for (int i < a.Length)
			{
				char8 ca = a[i];
				char8 cb = b[i];
				if (ca == '/') ca = '\\';
				if (cb == '/') cb = '\\';
				if (ca.ToLower != cb.ToLower)
					return false;
			}
			return true;
		}

		/// True when `path` is inside `dir` (case-insensitive, either slash).
		public static bool IsUnder(StringView path, StringView dir)
		{
			var dir;
			while (dir.EndsWith('\\') || dir.EndsWith('/'))
				dir.RemoveFromEnd(1);
			if (path.Length <= dir.Length)
				return false;
			if (!SamePath(path.Substring(0, dir.Length), dir))
				return false;
			let sep = path[dir.Length];
			return sep == '\\' || sep == '/';
		}
	}
}
