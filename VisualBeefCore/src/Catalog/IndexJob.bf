using System;
using System.Collections;
using System.Diagnostics;
using System.Threading;
using VisualBeef.Document;

namespace VisualBeef.Catalog
{
	/// Progress and cancellation shared between an indexing worker and the UI thread. The worker
	/// calls SetPhase / Step; the UI reads GetPhase / Fraction and may set Cancelled.
	class IndexProgress
	{
		Monitor mLock = new .() ~ delete _;
		String mPhase = new .() ~ delete _;
		int32 mDone;
		int32 mTotal;
		bool mCancelled;
		/// A child progress (one library loaded on its own thread) is also cancelled with its parent.
		public IndexProgress Parent;

		/// Set by the owner to stop the worker at the next file.
		public bool Cancelled
		{
			get => mCancelled || (Parent != null && Parent.Cancelled);
			set => mCancelled = value;
		}

		public void SetPhase(StringView phase, int32 total)
		{
			using (mLock.Enter())
			{
				mPhase.Set(phase);
				mDone = 0;
				mTotal = total;
			}
		}

		public void Step(int32 count = 1)
		{
			using (mLock.Enter())
				mDone += count;
		}

		/// "Indexing project (120/284)".
		public void GetPhase(String outText)
		{
			using (mLock.Enter())
			{
				outText.Append(mPhase);
				if (mTotal > 0)
					outText.AppendF(" ({}/{})", Math.Min(mDone, mTotal), mTotal);
			}
		}

		/// 0..1 within the current phase; -1 when the phase has no known size.
		public float Fraction
		{
			get
			{
				using (mLock.Enter())
					return (mTotal <= 0) ? -1 : Math.Clamp(mDone / (float)mTotal, 0, 1);
			}
		}
	}

	/// Indexes a project folder and loads every library it needs (corlib, BeefLibs, workspace
	/// projects elsewhere, generated SDKs under the folder) on a worker thread, so the editor stays
	/// responsive. The UI polls IsDone, then moves Project into its own ProjectIndex
	/// (ProjectIndex.TakeFrom) and hands Libraries to TypeService.SetLibraries.
	///
	/// Thread safety: the worker only touches its own objects (a fresh ProjectIndex, new stores,
	/// the cache files); the parser and LibraryIndex keep no shared mutable state.
	class IndexJob
	{
		public String Root = new .() ~ delete _;
		public ProjectIndex Project = new .() ~ delete _;
		public List<SymbolStore> Libraries = new .() ~ DeleteContainerAndItems!(_);
		public IndexProgress Progress = new .() ~ delete _;
		/// Timings and counts for the Output Log.
		public double ProjectMs;
		public double LibraryMs;
		/// The libraries' node catalogs, built here so the first node menu does not build them on
		/// the UI thread (NodeCatalog.Adopt).
		public PrebuiltCatalogs Catalogs ~ delete _;
		public int CacheHits;
		public int LibrariesParsed;
		Thread mThread;
		Monitor mLock = new .() ~ delete _;
		bool mDone;

		public this(StringView root)
		{
			Root.Set(root);
		}

		public ~this()
		{
			Cancel();
			Wait();
		}

		public bool IsDone
		{
			get
			{
				using (mLock.Enter())
					return mDone;
			}
		}

		public bool Cancelled => Progress.Cancelled;

		/// Runs on a new background thread.
		public void Start()
		{
			mThread = new Thread(new => Run);
			mThread.SetName("VisualBeef indexer");
			mThread.Start(false);
		}

		public void Cancel()
		{
			Progress.Cancelled = true;
		}

		public void Wait()
		{
			if (mThread != null)
			{
				mThread.Join();
				delete mThread;
				mThread = null;
			}
		}

		/// The work itself (also callable directly, e.g. from tests).
		public void Run()
		{
			let sw = scope Stopwatch(true);
			Project.Build(Root, Progress);
			ProjectMs = sw.Elapsed.TotalMilliseconds;
			if (!Progress.Cancelled)
			{
				sw.Restart();
				List<LibraryRef> libs = scope .();
				defer { ClearAndDeleteItems!(libs); }
				Progress.SetPhase("Finding libraries", 0);
				LibraryIndex.Discover(Root, libs, Project.GeneratedLibraries);
				LoadLibraries(libs);
				LibraryMs = sw.Elapsed.TotalMilliseconds;
				if (!Progress.Cancelled)
				{
					Progress.SetPhase("Building the node catalog", 0);
					Catalogs = NodeCatalog.Prebuild(Libraries);
				}
			}
			using (mLock.Enter())
				mDone = true;
		}

		/// Loads the libraries, up to four at a time (each on its own thread: a cold start parses
		/// two big generated libraries side by side instead of one after the other). Order is kept.
		void LoadLibraries(List<LibraryRef> libs)
		{
			SymbolStore[] stores = scope .[libs.Count];
			bool[] hits = scope .[libs.Count];
			Progress.SetPhase("Loading libraries", (.)libs.Count);
			int next = 0;
			Monitor nextLock = scope .();
			void Worker()
			{
				IndexProgress mine = scope .();
				mine.Parent = Progress;
				while (true)
				{
					int i;
					using (nextLock.Enter())
						i = next++;
					if (i >= libs.Count || Progress.Cancelled)
						return;
					stores[i] = LibraryIndex.Load(libs[i], true, mine, out hits[i]);
					Progress.Step();
				}
			}
			int threads = Math.Min(4, libs.Count);
			List<Thread> started = scope .();
			for (int t < threads - 1)
			{
				let th = new Thread(new [&] () => Worker());
				th.SetName("VisualBeef library loader");
				th.Start(false);
				started.Add(th);
			}
			Worker(); // this thread works too
			for (let th in started)
			{
				th.Join();
				delete th;
			}
			for (int i < libs.Count)
			{
				if (stores[i] == null)
					continue;
				if (Progress.Cancelled)
				{
					delete stores[i];
					continue;
				}
				if (hits[i])
					CacheHits++;
				else
					LibrariesParsed++;
				Libraries.Add(stores[i]);
			}
		}
	}
}
