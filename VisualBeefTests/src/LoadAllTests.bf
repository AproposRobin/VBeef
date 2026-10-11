using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests loadall [-v] <folder>...`: opens every project file of a folder the way
	/// the editor does and checks every graph. The editor's setup (ProjectIndex.Build of the
	/// folder, so generated SDK folders are libraries, and the TypeService with corlib and the
	/// libraries), then for each project file: SourceDocument.Load (the text and its
	/// `.vblayout` side file, orphans included), every function's graph built and laid out
	/// (saved positions applied, the rest auto-laid out), structural keys, a dry generation (the
	/// editor's first check: what code as read would refuse), the layout text a save would
	/// write, and invariants a view relies on (links between pins of nodes in the graph, one
	/// node per id, finite positions). Nothing is written. A failure is a refusal of code as
	/// read or a broken invariant; a crash is a crash.
	static class LoadAllTests
	{
		static int sFiles;
		static int sMethods;
		static int sNodes;
		static int sFailures;
		static int sWarnings;
		static int sOrphans;
		static int sSidecars;
		static bool sVerbose;
		/// `-savelayout`: write every file's side file after laying it out (only on a scratch
		/// copy: a second run then loads them back).
		static bool sSaveLayout;

		static void Fail(StringView path, StringView what)
		{
			sFailures++;
			Console.WriteLine("FAIL {}: {}", path, what);
		}

		public static int Run(String[] args)
		{
			List<String> roots = scope .();
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-v")
					sVerbose = true;
				else if (args[i] == "-savelayout")
					sSaveLayout = true;
				else
					roots.Add(args[i]);
			}
			let total = scope Stopwatch(true);
			for (let root in roots)
			{
				let sw = scope Stopwatch(true);
				ProjectIndex index = scope .();
				index.Build(root);
				GraphBuilder.Index = index;
				TypeService types = scope .(index);
				types.Install();
				types.Sync();
				Console.WriteLine("{}: {} project files ({} generated SDK folders as libraries), {} libraries, index {:0} ms",
					root, index.Files.Count, index.GeneratedLibraries.Count, types.Libraries.Count, sw.Elapsed.TotalMilliseconds);
				for (let f in index.Files)
					if (f.Path.EndsWith(".bf", .OrdinalIgnoreCase))
						LoadFile(f.Path);
				GraphBuilder.Index = null;
				TypeService.Current = null;
				TypeRules.Hierarchy = null;
			}
			Console.WriteLine("loadall: files={} methods={} nodes={} sidecars={} orphans={} warnings={} failures={} ({:0} ms)",
				sFiles, sMethods, sNodes, sSidecars, sOrphans, sWarnings, sFailures, total.Elapsed.TotalMilliseconds);
			return (sFailures == 0) ? 0 : 1;
		}

		static void LoadFile(StringView path)
		{
			SourceDocument doc = scope .();
			if (doc.Load(path) case .Err)
			{
				Fail(path, "could not be read");
				return;
			}
			sFiles++;
			String sidecar = scope .();
			SourceDocument.GetLayoutPath(path, sidecar);
			if (File.Exists(sidecar))
				sSidecars++;
			for (let mg in doc.Methods)
			{
				if (!mg.Graphable && !mg.IsBroken)
					continue;
				sMethods++;
				let g = mg.Graph;
				CheckGraph(path, mg.Key, g);
				if (mg.IsBroken)
					continue;
				// The editor's first check: code as read is never refused.
				CodeGen gen = scope .(g, "\t", true);
				String scratch = scope .();
				gen.GenerateBody("", scratch);
				for (let e in g.Errors)
				{
					let n = g.FindNode(e.NodeId);
					Fail(path, scope $"{mg.Key}: line {n?.Line ?? 0}: refused as read: {e.Message}");
				}
				sWarnings += g.Warnings.Count;
				if (sVerbose)
					for (let w in g.Warnings)
						Console.WriteLine("  warning {}: {}: {}", path, mg.Key, w.Message);
				g.ClearErrors();
			}
			// What saving the layout would write (nothing is written).
			doc.CaptureAllLayouts();
			String layout = scope .();
			doc.GetLayoutText(layout);
			if (sSaveLayout)
			{
				doc.LayoutTouched = true;
				doc.SaveLayout();
			}
			sOrphans += doc.Orphans.Count;
		}

		static void CheckGraph(StringView path, StringView key, Graph g)
		{
			KeyAssigner.Assign(g);
			HashSet<int32> ids = scope .();
			HashSet<Pin> pins = scope .();
			for (let n in g.Nodes)
			{
				sNodes++;
				if (!ids.Add(n.Id))
					Fail(path, scope $"{key}: two nodes have id {n.Id}");
				if (!n.HasPos || n.X.IsNaN || n.Y.IsNaN || Math.Abs(n.X) > 1e7f || Math.Abs(n.Y) > 1e7f)
					Fail(path, scope $"{key}: node {n.Key} has no usable position ({n.X}, {n.Y})");
				if (n.Key.IsEmpty)
					Fail(path, scope $"{key}: a node has no key");
				for (let p in n.Inputs)
				{
					pins.Add(p);
					if (p.Owner != n)
						Fail(path, scope $"{key}: pin {p.Name} of {n.Key} belongs to another node");
				}
				for (let p in n.Outputs)
				{
					pins.Add(p);
					if (p.Owner != n)
						Fail(path, scope $"{key}: pin {p.Name} of {n.Key} belongs to another node");
				}
			}
			for (let l in g.Links)
			{
				if (!pins.Contains(l.From) || !pins.Contains(l.To))
					Fail(path, scope $"{key}: a link points at a pin outside the graph");
				else if (l.From.IsInput || !l.To.IsInput || l.From.Kind != l.To.Kind)
					Fail(path, scope $"{key}: a link {l.From.Owner.Key}.{l.From.Name} -> {l.To.Owner.Key}.{l.To.Name} joins the wrong pin kinds");
			}
		}
	}
}
