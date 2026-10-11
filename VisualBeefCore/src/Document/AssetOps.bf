using System;
using System.IO;
using System.Collections;
using VisualBeef.Syntax;

namespace VisualBeef.Document
{
	/// Where a new source file goes relative to the Beef projects (BeefProj.toml) around it.
	enum SourcePlacement
	{
		/// The folder is already inside a project's `src` folder.
		InSource,
		/// The folder is a project folder (or a non-source subfolder of one): the file goes into
		/// the project's `src` instead, so it is actually compiled.
		Redirected,
		/// No BeefProj.toml above the folder: a file here is never compiled.
		NoProject
	}

	/// File-level operations behind the Project Browser (create, rename, delete), kept free of UI so
	/// they can be tested headless. Every one refuses in a read-only project, never overwrites,
	/// and reports why in `outError`.
	static class AssetOps
	{
		static bool SameSeg(StringView a, StringView b) => StringView.Compare(a, b, true) == 0;

		static void Normalize(StringView path, String outPath)
		{
			outPath.Set(path);
			outPath.Replace('\\', '/');
			while (outPath.Length > 1 && outPath.EndsWith('/') && !(outPath.Length == 3 && outPath[1] == ':'))
				outPath.RemoveFromEnd(1);
		}

		/// The parent of `path`, or false at a root / when there is none. `Path.GetDirectoryPath` returns .Err
		/// for a drive root, and Beef fatal-errors on a discarded .Err, so upward walks go through this.
		public static bool TryGetParent(StringView path, String outParent)
		{
			outParent.Clear();
			if (Path.GetDirectoryPath(path, outParent) case .Err)
			{
				outParent.Clear();
				return false;
			}
			return !outParent.IsEmpty && outParent != path;
		}

		/// The nearest directory at or above `folder` that holds a BeefProj.toml (empty: none).
		public static void FindProjectDir(StringView folder, String outDir)
		{
			String dir = scope .();
			Normalize(folder, dir);
			for (int depth = 0; depth < 32 && !dir.IsEmpty; depth++)
			{
				String toml = scope .(dir);
				toml.Append("/BeefProj.toml");
				if (File.Exists(toml))
				{
					outDir.Set(dir);
					return;
				}
				String parent = scope .();
				Path.GetDirectoryPath(dir, parent).IgnoreError(); // a root has no parent: the out string stays empty
				Normalize(parent, parent);
				if (parent == dir || parent.IsEmpty)
					break;
				dir.Set(parent);
			}
		}

		/// Decides where a new source file for `folder` should really be written. For Redirected,
		/// `outFolder` is the project's `src` folder (it may not exist yet). `outProjectDir` is
		/// the project folder when there is one.
		public static SourcePlacement ResolveSourceFolder(StringView folder, String outFolder, String outProjectDir)
		{
			String f = scope .();
			Normalize(folder, f);
			String proj = scope .();
			FindProjectDir(f, proj);
			if (proj.IsEmpty)
			{
				outFolder.Set(f);
				return .NoProject;
			}
			outProjectDir.Set(proj);
			// First path segment below the project folder.
			StringView rel = StringView(f, Math.Min(proj.Length, f.Length));
			while (rel.StartsWith('/'))
				rel.RemoveFromStart(1);
			int slash = rel.IndexOf('/');
			StringView first = (slash >= 0) ? rel.Substring(0, slash) : rel;
			if (!rel.IsEmpty && SameSeg(first, "src"))
			{
				outFolder.Set(f);
				return .InSource;
			}
			outFolder.Set(proj);
			outFolder.Append("/src");
			return .Redirected;
		}

		static void WalkNamespaces(List<Member> members, String prefix, StringView typeName, List<String> outNs)
		{
			if (members == null)
				return;
			for (let m in members)
			{
				if (m.Kind == .Namespace)
				{
					int mark = prefix.Length;
					if (!prefix.IsEmpty)
						prefix.Append('.');
					String n = scope .(m.Name);
					n.Trim();
					prefix.Append(n);
					WalkNamespaces(m.Members, prefix, typeName, outNs);
					prefix.RemoveToEnd(mark);
				}
				else if (m.Kind == .Type && m.Name == typeName)
				{
					bool have = false;
					for (let e in outNs)
						if (e == prefix)
							have = true;
					if (!have)
						outNs.Add(new String(prefix));
				}
			}
		}

		/// The namespaces a (top-level) type called `typeName` is declared in, within one parsed file.
		public static void NamespacesOf(CompilationUnit unit, StringView typeName, List<String> outNs)
		{
			String prefix = scope .();
			WalkNamespaces(unit.Members, prefix, typeName, outNs);
		}

		/// Is a type called `name` already declared in namespace `ns`? Beef allows the same name in
		/// different namespaces, so only a clash within one namespace is refused. `outWhere` gets
		/// the file that declares it. Files open in the editor use their live text (`liveText`
		/// may be null).
		public static bool TypeNameTaken(ProjectIndex index, StringView ns, StringView name, String outWhere, delegate bool(StringView path, String outText) liveText = null)
		{
			for (let f in index.Files)
			{
				bool has = false;
				for (let t in f.Types)
					if (t.Name == name && t.Outer.IsEmpty)
						has = true;
				if (!has)
					continue;
				String text = scope .();
				if (liveText == null || !liveText(f.Path, text))
				{
					if (File.ReadAllText(f.Path, text, true) case .Err)
						continue;
				}
				let unit = Parser.Parse(text);
				defer delete unit;
				List<String> nss = scope .();
				defer { ClearAndDeleteItems!(nss); }
				NamespacesOf(unit, name, nss);
				for (let n in nss)
				{
					if (n == ns)
					{
						outWhere.Set(f.Path);
						return true;
					}
				}
			}
			return false;
		}

		/// Creates a new text file. Fails (rather than overwrites) when the path exists.
		public static Result<void> CreateTextFile(StringView path, StringView text, String outError)
		{
			if (FileSafety.ReadOnlyProject)
			{
				outError.Append(FileSafety.ReadOnlyMessage);
				return .Err;
			}
			if (File.Exists(path) || Directory.Exists(path))
			{
				outError.AppendF("{} already exists.", path);
				return .Err;
			}
			String dir = scope .();
			Path.GetDirectoryPath(path, dir).IgnoreError(); // a root has no parent: the out string stays empty
			if (!dir.IsEmpty && !Directory.Exists(dir))
			{
				if (Directory.CreateDirectory(dir) case .Err)
				{
					outError.AppendF("Could not create the folder {}.", dir);
					return .Err;
				}
			}
			return FileSafety.AtomicWrite(path, text, false, outError);
		}

		public static Result<void> CreateFolder(StringView path, String outError)
		{
			if (FileSafety.ReadOnlyProject)
			{
				outError.Append(FileSafety.ReadOnlyMessage);
				return .Err;
			}
			if (Directory.Exists(path) || File.Exists(path))
			{
				outError.AppendF("{} already exists.", path);
				return .Err;
			}
			if (Directory.CreateDirectory(path) case .Err)
			{
				outError.AppendF("Could not create the folder {}.", path);
				return .Err;
			}
			return .Ok;
		}

		/// Applies a rename of a type declaration to the file on disk and nothing else: refuses when
		/// the document holds other unsaved edits (they would be written too). On a conflict or a
		/// write failure the document is rolled back with Undo and the file is untouched.
		public static Result<void> RenameTypeAndSave(SourceDocument doc, StringView oldName, StringView newName, String outError)
		{
			if (FileSafety.ReadOnlyProject)
			{
				outError.Append(FileSafety.ReadOnlyMessage);
				return .Err;
			}
			if (doc.Modified)
			{
				outError.AppendF("{} has unsaved edits. Save or reload it first; renaming would otherwise save them too.", doc.FilePath);
				return .Err;
			}
			let type = FindType(doc, oldName);
			if (type == null)
			{
				outError.AppendF("Could not find {} in {}.", oldName, doc.FilePath);
				return .Err;
			}
			doc.RenameType(type, newName);
			return SaveOrRollback(doc, outError);
		}

		/// Removes a type declaration from its file, saving only that change (same rules as rename).
		public static Result<void> DeleteTypeAndSave(SourceDocument doc, StringView typeName, String outError)
		{
			if (FileSafety.ReadOnlyProject)
			{
				outError.Append(FileSafety.ReadOnlyMessage);
				return .Err;
			}
			if (doc.Modified)
			{
				outError.AppendF("{} has unsaved edits. Save or reload it first; deleting would otherwise save them too.", doc.FilePath);
				return .Err;
			}
			let type = FindType(doc, typeName);
			if (type == null)
			{
				outError.AppendF("Could not find {} in {}.", typeName, doc.FilePath);
				return .Err;
			}
			doc.DeleteMember(type);
			return SaveOrRollback(doc, outError);
		}

		static Result<void> SaveOrRollback(SourceDocument doc, String outError)
		{
			let r = doc.TrySave();
			if (r == .Saved)
				return .Ok;
			doc.Undo();
			doc.RefreshModified();
			if (r == .Conflict)
				outError.AppendF("{} changed on disk; nothing was written.", doc.FilePath);
			else
				outError.Append(doc.LastError);
			return .Err;
		}

		static Member FindType(SourceDocument doc, StringView name)
		{
			if (doc == null || doc.Unit == null)
				return null;
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		/// Renames/moves a file (or folder), taking the `.vblayout` side file along; a case-only
		/// change goes through a temporary name. Refuses to overwrite.
		public static Result<void> MovePath(StringView from, StringView to, bool isFolder, String outError)
		{
			if (FileSafety.ReadOnlyProject)
			{
				outError.Append(FileSafety.ReadOnlyMessage);
				return .Err;
			}
			bool caseOnly = StringView.Compare(from, to, true) == 0 && from != to;
			if (!caseOnly && (File.Exists(to) || Directory.Exists(to)))
			{
				outError.AppendF("{} already exists.", to);
				return .Err;
			}
			if (caseOnly)
			{
				String tmp = scope .(from);
				tmp.Append(".vbrename");
				if ((isFolder ? Directory.Move(from, tmp) : File.Move(from, tmp)) case .Err)
				{
					outError.AppendF("Could not rename {} (is something in it open elsewhere?).", from);
					return .Err;
				}
				if ((isFolder ? Directory.Move(tmp, to) : File.Move(tmp, to)) case .Err)
				{
					(isFolder ? Directory.Move(tmp, from) : File.Move(tmp, from)).IgnoreError();
					outError.AppendF("Could not rename {}.", from);
					return .Err;
				}
			}
			else if ((isFolder ? Directory.Move(from, to) : File.Move(from, to)) case .Err)
			{
				outError.AppendF("Could not rename {} (is something in it open elsewhere?).", from);
				return .Err;
			}
			if (!isFolder)
			{
				String oldLayout = scope .();
				String newLayout = scope .();
				SourceDocument.GetLayoutPath(from, oldLayout);
				SourceDocument.GetLayoutPath(to, newLayout);
				if (File.Exists(oldLayout))
					File.Move(oldLayout, newLayout).IgnoreError();
			}
			return .Ok;
		}

		/// Deletes a file or folder into the Recycle Bin. If that is not possible nothing is
		/// deleted and the reason is reported: there is no permanent-delete fallback.
		public static Result<void> Delete(StringView path, bool isFolder, String outError)
		{
			if (FileSafety.ReadOnlyProject)
			{
				outError.Append(FileSafety.ReadOnlyMessage);
				return .Err;
			}
			if (FileSafety.MoveToRecycleBin(path, outError) case .Err)
				return .Err;
			if (!isFolder)
			{
				// The side file is only a cache of node positions; it goes to the bin too.
				String layout = scope .();
				SourceDocument.GetLayoutPath(path, layout);
				if (File.Exists(layout))
					FileSafety.MoveToRecycleBin(layout, scope String()).IgnoreError();
			}
			return .Ok;
		}
	}
}
