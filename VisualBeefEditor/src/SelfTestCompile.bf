using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=compiletime`: four compiles of the open project through the calls F7 and Ctrl+F7 make,
	/// timed: the first (the caller removes the project's build folder before the run), one with nothing
	/// changed (up to date: BeefBuild is not run, no project file is written), Force Compile (BeefBuild runs)
	/// and one after a one-line change saved by Compile's Save All (a line added at the end of the file
	/// in `VB_CTIME_FILE`, else the first project file; taken out again at the end). For each it logs a
	/// `[CTIME]` line (the whole compile as the user waits for it, BeefBuild alone, the time inside
	/// Compile() and in the frame that took the result, the longest frame) and checks that the compile
	/// succeeded and that no frame took longer than the UI budget (50 ms) while it ran (Compile()'s own
	/// Save All of the changed file, flushed to disk, is reported apart as `call`).
	/// A no-change compile must not write any file of the project. See docs/Testing.md.
	extension EditorApp
	{
		int mCtStep;
		int mCtWait;
		double mCtStart;
		String mCtFile = new .() ~ delete _;
		String mCtOriginal = new .() ~ delete _;
		Dictionary<String, DateTime> mCtTimes = new .() ~ DeleteDictionaryAndKeys!(_);

		const double cCtFrameBudgetMs = 50;

		/// Write times of the project's sources and project files (a no-change compile must keep them).
		void CtSnapshot(Dictionary<String, DateTime> outTimes)
		{
			for (let kv in outTimes)
				delete kv.key;
			outTimes.Clear();
			for (let f in Index.Files)
				if (File.GetLastWriteTime(f.Path) case .Ok(let t))
					outTimes[new String(f.Path)] = t;
			String ws = scope .();
			CurrentWorkspace(ws);
			for (let name in StringView[2]("BeefSpace.toml", "BeefProj.toml"))
			{
				String p = scope .();
				p.AppendF("{}{}{}", ws, Path.DirectorySeparatorChar, name);
				if (File.GetLastWriteTime(p) case .Ok(let t))
					outTimes[new String(p)] = t;
			}
		}

		bool CtWaitBuild()
		{
			if (mBuild != null && mBuild.Running)
				return false;
			// a few more frames: the result frame and the ones after it (state, toasts) count too
			if (mCompileTailFrames >= 0)
				return false;
			return true;
		}

		void CtReport(StringView name)
		{
			let total = (Desktop.Now - mCtStart) * 1000.0;
			bool ok = mBuild != null && mBuild.Succeeded;
			Notify.Log(.Info, "SelfTest", scope $"[CTIME] {name}: total={total:0} ms beefbuild={(mBuild != null ? mBuild.BuildMs : 0):0} ms call={CompileCallMs:0.0} ms finish={CompileFinishMs:0.0} ms maxframe={CompileMaxFrameMs:0.0} ms (frame {CompileMaxFrameAt} of {CompileFrames}, {(CompileMaxFrameRunning ? "while running" : "after")}) ok={ok}");
			SelfTestCheck(ok, scope $"compiletime: the {name} compile succeeded");
			SelfTestCheck(CompileMaxFrameMs < cCtFrameBudgetMs, scope $"compiletime: no frame over {cCtFrameBudgetMs} ms during the {name} compile (longest {CompileMaxFrameMs:0.0} ms)");
			// Compile() itself: Save All (flushed to disk) when files changed, else nothing to wait for.
			if (name != "one-line")
				SelfTestCheck(CompileCallMs < cCtFrameBudgetMs, scope $"compiletime: pressing Compile takes {CompileCallMs:0.0} ms in its frame ({name})");
		}

		bool SelfTestCompileTime()
		{
			if (mCtWait > 0)
			{
				mCtWait--;
				return false;
			}
			let step = mCtStep++;
			switch (step)
			{
			case 0:
				String ws = scope .();
				CurrentWorkspace(ws);
				SelfTestCheck(!ws.IsEmpty, scope $"compiletime: the project has a workspace ({ws})");
				if (ws.IsEmpty)
					return true;
				{
					// The indicator's source hash: read once, then only the folder listing while nothing changes.
					let sw = scope System.Diagnostics.Stopwatch(true);
					let reads = CompileRecord.ContentReads;
					let h1 = CompileRecord.HashWorkspace(ws);
					let firstMs = sw.Elapsed.TotalMilliseconds;
					sw.Restart();
					let h2 = CompileRecord.HashWorkspace(ws);
					let againMs = sw.Elapsed.TotalMilliseconds;
					sw.Restart();
					let inputs = BuildInputs.Fingerprint(ws, mBeefBuildPath, "Debug", BuildRunner.Platform);
					let inputsMs = sw.Elapsed.TotalMilliseconds;
					Notify.Log(.Info, "SelfTest", scope $"[CTIME] source hash {firstMs:0.0} ms, again {againMs:0.0} ms; inputs fingerprint {inputsMs:0.0} ms");
					SelfTestCheck(h1 == h2 && CompileRecord.ContentReads - reads <= 1, scope $"compiletime: an unchanged workspace is not read again for its hash ({CompileRecord.ContentReads - reads} reads)");
					SelfTestCheck(inputs != 0, "compiletime: the inputs fingerprint is taken");
				}
				// Let the editor settle after opening the project (first draws of the panels) before timing.
				mCtStart = Desktop.Now;
			case 1:
				if (Desktop.Now - mCtStart < 1.5)
				{
					mCtStep--;
					return false;
				}
				mCtStart = Desktop.Now;
				Compile();
			case 2:
				if (!CtWaitBuild())
				{
					mCtStep--;
					return false;
				}
				CtReport("first");
				SelfTestCheck(mBuild != null && !mBuild.UpToDate, "compiletime: the first compile ran BeefBuild");
				mCtWait = 10;
			case 3:
				CtSnapshot(mCtTimes);
				mCtStart = Desktop.Now;
				Compile();
			case 4:
				if (!CtWaitBuild())
				{
					mCtStep--;
					return false;
				}
				CtReport("no-change");
				Dictionary<String, DateTime> after = scope .();
				defer { for (let kv in after) delete kv.key; }
				CtSnapshot(after);
				int touched = 0;
				for (let kv in after)
					if (!mCtTimes.TryGetValue(kv.key, let before) || before != kv.value)
					{
						touched++;
						Notify.Log(.Info, "SelfTest", scope $"[CTIME] written by a no-change compile: {kv.key}");
					}
				SelfTestCheck(touched == 0 && after.Count == mCtTimes.Count, scope $"compiletime: a no-change compile writes no project file ({touched} of {after.Count} written)");
				SelfTestCheck(mBuild != null && mBuild.UpToDate && mBuild.BuildMs < 1000, scope $"compiletime: nothing changed, so BeefBuild was not run (up to date in {(mBuild != null ? mBuild.BuildMs : -1):0} ms)");
				SelfTestCheck(GetCompileState() == .Good || GetCompileState() == .Warnings, "compiletime: the indicator is green after an up-to-date compile");
				mCtWait = 10;
			case 5:
				// Force Compile runs BeefBuild although nothing changed.
				mCtStart = Desktop.Now;
				Compile(default, true);
			case 6:
				if (!CtWaitBuild())
				{
					mCtStep--;
					return false;
				}
				CtReport("forced");
				SelfTestCheck(mBuild != null && !mBuild.UpToDate, "compiletime: Force Compile ran BeefBuild");
				mCtWait = 10;
			case 7:
				// The one-line change: a line added at the end of a project file, saved by Compile.
				String env = scope .();
				Environment.GetEnvironmentVariable("VB_CTIME_FILE", env).IgnoreError();
				if (!env.IsEmpty)
					mCtFile.Set(env);
				else if (!Index.Files.IsEmpty)
					mCtFile.Set(Index.Files[0].Path);
				let doc = mCtFile.IsEmpty ? null : OpenFile(mCtFile, false);
				SelfTestCheck(doc != null, scope $"compiletime: {mCtFile} opens for the one-line change");
				if (doc == null)
					return true;
				mCtOriginal.Set(doc.Unit.Text);
				String text = scope .(mCtOriginal);
				text.Append("static class VbTimingProbe { public static int Value = 1; }\n");
				doc.ApplyText(text);
				mCtStart = Desktop.Now;
				Compile();
			case 8:
				if (!CtWaitBuild())
				{
					mCtStep--;
					return false;
				}
				CtReport("one-line");
				SelfTestCheck(mBuild != null && !mBuild.UpToDate, "compiletime: a changed file runs BeefBuild");
				mCtWait = 10;
			case 9:
				let doc = OpenFile(mCtFile, false);
				if (doc != null)
				{
					doc.ApplyText(mCtOriginal);
					SaveDoc(doc);
					// After a save the indicator's hash is read on a worker, not in this frame.
					let sw = scope System.Diagnostics.Stopwatch(true);
					let state = GetCompileState();
					let ms = sw.Elapsed.TotalMilliseconds;
					SelfTestCheck(state == .Unknown && ms < 20, scope $"compiletime: after a save the indicator says Needs compile at once ({state}, {ms:0.0} ms in this frame)");
				}
				String back = scope .();
				File.ReadAllText(mCtFile, back, true).IgnoreError(); // unreadable: stays empty, the check fails
				SelfTestCheck(doc != null && back == mCtOriginal, "compiletime: the file is back as it was");
				return true;
			}
			return false;
		}

		int mCsStep;
		double mCsAt;

		/// `VB_SELFTEST=compileshots` (after `theme:<n>` and `size:<w>x<h>`; may run again after another
		/// `size:`): captures of what a compile shows, for the UI rule (docs/Testing.md): `ct-compiling`
		/// (Problems and the status bar with the elapsed time while BeefBuild runs, Force Compile so it
		/// runs), `ct-done` (the result line with its time), `ct-uptodate` (a compile with nothing
		/// changed), `ct-log` (the Output Log lines) and `ct-buildmenu` (Build > Force Compile).
		bool SelfTestCompileShots()
		{
			switch (mCsStep)
			{
			case 0:
				Panels.Focus(Panels.CompilerResultsId);
				Compile(default, true);
				mCsAt = Desktop.Now;
				mCsStep++;
			case 1:
				if (mBuild != null && mBuild.Running && Desktop.Now - mCsAt < 1.2)
					return false;
				SelfTestCheck(mBuild != null && mBuild.Running, "compileshots: BeefBuild is still running for the capture");
				mCsStep++;
			case 2:
				if (!SelfTestShot("ct-compiling"))
					return false;
				mCsStep++;
			case 3:
				if (mBuild != null && mBuild.Running)
					return false;
				mCsAt = Desktop.Now;
				mCsStep++;
			case 4:
				if (Desktop.Now - mCsAt < 0.5)
					return false;
				if (!SelfTestShot("ct-done"))
					return false;
				Compile();
				mCsAt = Desktop.Now;
				mCsStep++;
			case 5:
				if ((mBuild != null && mBuild.Running) || Desktop.Now - mCsAt < 0.5)
					return false;
				SelfTestCheck(mBuild != null && mBuild.UpToDate, "compileshots: the second compile is up to date");
				mCsStep++;
			case 6:
				if (!SelfTestShot("ct-uptodate"))
					return false;
				Panels.Focus(Panels.OutputLogId);
				mCsAt = Desktop.Now;
				mCsStep++;
			case 7:
				if (Desktop.Now - mCsAt < 0.3)
					return false;
				if (!SelfTestShot("ct-log"))
					return false;
				Panels.Focus(Panels.CompilerResultsId);
				mSelfTestBuildMenu = true;
				mCsAt = Desktop.Now;
				mCsStep++;
			case 8:
				if (Desktop.Now - mCsAt < 0.3)
					return false;
				if (!SelfTestShot("ct-buildmenu"))
					return false;
				mSelfTestCloseBuildMenu = true;
				mCsStep = 0;
				return true;
			}
			return false;
		}
	}
}
