using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Editor
{
	/// What a Project Browser tile stands for. Every class / struct / enum / interface is its own
	/// asset (like a UE asset), even when one .bf file holds several.
	enum AssetKind
	{
		Folder,
		Class,
		Struct,
		Enum,
		Interface,
		Globals,
		File,
		/// A Node Library: `static class`, global functions and variables.
		Library
	}

	/// One tile of the asset grid. Built fresh each frame from the project index; every string
	/// is a copy, so the index can be rebuilt while these are alive.
	class CBItem
	{
		public AssetKind Kind;
		public String Name = new .() ~ delete _;
		/// Folder path, or the .bf file that declares the type.
		public String Path = new .() ~ delete _;
		/// Declared type name (types only).
		public String TypeName = new .() ~ delete _;
		/// Selection key: "D|path", "F|path" or "T|path|Type".
		public String Key = new .() ~ delete _;
		/// Search hit shown in the tooltip ("function Update").
		public String Match = new .() ~ delete _;
		public int32 Methods;
		public int32 Fields;
		public int32 Line;
		public bool Modified;

		public bool IsType => Kind != .Folder && Kind != .File;

		public CBItem Clone()
		{
			CBItem c = new .();
			c.Kind = Kind;
			c.Name.Set(Name);
			c.Path.Set(Path);
			c.TypeName.Set(TypeName);
			c.Key.Set(Key);
			c.Match.Set(Match);
			c.Methods = Methods;
			c.Fields = Fields;
			c.Line = Line;
			c.Modified = Modified;
			return c;
		}

		public static void MakeKey(AssetKind kind, StringView path, StringView typeName, String outKey)
		{
			outKey.Clear();
			switch (kind)
			{
			case .Folder: outKey.AppendF("D|{}", path);
			case .File: outKey.AppendF("F|{}", path);
			default: outKey.AppendF("T|{}|{}", path, typeName);
			}
		}
	}

	/// A folder of the project on disk (build output, recovery and dot folders skipped).
	class CBDir
	{
		public String Name = new .() ~ delete _;
		public String Path = new .() ~ delete _;
		public CBDir Parent;
		public List<CBDir> Dirs = new .() ~ DeleteContainerAndItems!(_);
		/// .bf files directly in this folder.
		public List<String> Files = new .() ~ DeleteContainerAndItems!(_);
		/// The workspace project this folder is (BeefSpace.toml lists it), or null.
		public String ProjectName ~ delete _;
		/// The workspace's startup project.
		public bool Startup;
		/// A BeefProj.toml the workspace does not list.
		public bool LooseProject;
		/// A workspace project outside the open folder (a leaf row; Path is its folder).
		public bool Outside;

		public int CountFilesRecursive()
		{
			int n = Files.Count;
			for (let d in Dirs)
				n += d.CountFilesRecursive();
			return n;
		}
	}

	/// Colors, labels and draw-list icons of the asset kinds (UE asset-type colors).
	static class AssetStyle
	{
		public static uint32 KindColor(AssetKind k)
		{
			switch (k)
			{
			case .Class: return Gui.Color(45, 115, 225);      // Blueprint blue
			case .Struct: return Gui.Color(92, 70, 196);      // dark blue-violet
			case .Enum: return Gui.Color(128, 148, 36);       // olive green
			case .Interface: return Gui.Color(22, 160, 150);  // teal
			case .Globals: return Gui.Color(135, 135, 135);   // grey
			case .File: return Gui.Color(175, 175, 175);
			case .Folder: return Gui.Color(196, 166, 108);
			case .Library: return Gui.Color(222, 142, 38);    // amber
			}
		}

		public static StringView KindLabel(AssetKind k)
		{
			switch (k)
			{
			case .Class: return "Class";
			case .Struct: return "Struct";
			case .Enum: return "Enum";
			case .Interface: return "Interface";
			case .Globals: return "Global Functions";
			case .File: return "Beef File";
			case .Folder: return "Folder";
			case .Library: return "Node Library";
			}
		}

		/// The kind of a type: a `static class` is a Node Library, not a Class.
		public static bool FromType(StringView kind, bool isLibrary, out AssetKind outKind)
		{
			let ok = FromSymbolKind(kind, out outKind);
			if (ok && outKind == .Class && isLibrary)
				outKind = .Library;
			return ok;
		}

		public static bool FromSymbolKind(StringView kind, out AssetKind outKind)
		{
			outKind = .Class;
			switch (kind)
			{
			case "class": outKind = .Class;
			case "struct": outKind = .Struct;
			case "enum": outKind = .Enum;
			case "interface": outKind = .Interface;
			case "static": outKind = .Globals;
			default: return false;
			}
			return true;
		}

		public static void Text(ImDrawList* dl, StringView text, ImVec2 pos, float size, uint32 col)
		{
			Gui.ImDrawList_AddText_FontPtr(dl, Gui.igGetFont(), size, pos, col, text.Ptr, text.Ptr + text.Length, 0, null);
		}

		public static ImVec2 TextSize(StringView text, float size)
		{
			let s = Gui.CalcTextSize(text);
			let f = size / Math.Max(1.0f, Gui.igGetFontSize());
			return .(s.x * f, s.y * f);
		}

		/// Draws the kind's glyph centered on `c`, about `s` pixels across.
		public static void DrawIcon(ImDrawList* dl, AssetKind kind, ImVec2 c, float s, uint32 col)
		{
			float u = s / 100.0f;
			uint32 light = Theme.Mix(col, Gui.Color(255, 255, 255), 0.45f);
			uint32 dark = Gui.Color(14, 14, 14, 240);
			switch (kind)
			{
			case .Class:
				// A little Blueprint node: colored header, exec + data pins.
				ImVec2 a = .(c.x - 40 * u, c.y - 30 * u);
				ImVec2 b = .(c.x + 40 * u, c.y + 32 * u);
				Gui.ImDrawList_AddRectFilled(dl, a, b, dark, 7 * u, 0);
				Gui.ImDrawList_AddRectFilled(dl, a, .(b.x, a.y + 18 * u), col, 7 * u, DrawFlags.RoundCornersTop);
				Gui.ImDrawList_AddRect(dl, a, b, Gui.Color(0, 0, 0, 255), 7 * u, 1.5f * u, 0);
				// exec in / out
				float ey = c.y + 2 * u;
				Gui.ImDrawList_AddTriangleFilled(dl, .(c.x - 32 * u, ey - 6 * u), .(c.x - 32 * u, ey + 6 * u), .(c.x - 22 * u, ey), Gui.Color(235, 235, 235));
				Gui.ImDrawList_AddTriangleFilled(dl, .(c.x + 22 * u, ey - 6 * u), .(c.x + 22 * u, ey + 6 * u), .(c.x + 32 * u, ey), Gui.Color(235, 235, 235));
				// data pins
				Gui.ImDrawList_AddCircleFilled(dl, .(c.x - 27 * u, c.y + 20 * u), 5 * u, Gui.Color(31, 227, 175), 12);
				Gui.ImDrawList_AddCircleFilled(dl, .(c.x + 27 * u, c.y + 20 * u), 5 * u, Gui.Color(160, 250, 68), 12);
				Gui.ImDrawList_AddLine(dl, .(c.x - 14 * u, ey), .(c.x + 14 * u, ey), Gui.Color(90, 90, 90), 2 * u);
			case .Struct:
				// A record: header band plus field rows.
				ImVec2 a = .(c.x - 36 * u, c.y - 34 * u);
				ImVec2 b = .(c.x + 36 * u, c.y + 34 * u);
				Gui.ImDrawList_AddRectFilled(dl, a, b, dark, 5 * u, 0);
				Gui.ImDrawList_AddRectFilled(dl, a, .(b.x, a.y + 16 * u), col, 5 * u, DrawFlags.RoundCornersTop);
				for (int i < 3)
				{
					float y = a.y + 26 * u + i * 14 * u;
					Gui.ImDrawList_AddRectFilled(dl, .(a.x + 8 * u, y), .(a.x + 18 * u, y + 8 * u), light, 1.5f * u, 0);
					Gui.ImDrawList_AddRectFilled(dl, .(a.x + 24 * u, y + 2 * u), .(b.x - 8 * u - (i == 1 ? 14 * u : 0), y + 6 * u), Gui.Color(170, 170, 170), 2 * u, 0);
				}
				Gui.ImDrawList_AddRect(dl, a, b, col, 5 * u, 2 * u, 0);
			case .Enum:
				// A list of named values.
				for (int i < 3)
				{
					float y = c.y - 24 * u + i * 24 * u;
					Gui.ImDrawList_AddCircleFilled(dl, .(c.x - 26 * u, y), 7 * u, (i == 0) ? light : col, 16);
					Gui.ImDrawList_AddRectFilled(dl, .(c.x - 12 * u, y - 4 * u), .(c.x + 34 * u - (i == 2 ? 14 * u : 0), y + 4 * u), Gui.Color(190, 190, 190), 3 * u, 0);
				}
				Gui.ImDrawList_AddLine(dl, .(c.x - 40 * u, c.y - 36 * u), .(c.x - 40 * u, c.y + 36 * u), col, 3 * u);
			case .Interface:
				// A "lollipop" (provided interface).
				Gui.ImDrawList_AddCircle(dl, .(c.x - 14 * u, c.y), 20 * u, light, 32, 6 * u);
				Gui.ImDrawList_AddLine(dl, .(c.x + 6 * u, c.y), .(c.x + 36 * u, c.y), light, 6 * u);
				Gui.ImDrawList_AddCircleFilled(dl, .(c.x + 38 * u, c.y), 7 * u, col, 16);
			case .Globals:
				let size = 44 * u;
				let ts = TextSize("f(x)", size);
				Text(dl, "f(x)", .(c.x - ts.x / 2, c.y - ts.y / 2), size, light);
			case .File:
				// A page with a folded corner.
				float x0 = c.x - 28 * u;
				float x1 = c.x + 28 * u;
				float y0 = c.y - 38 * u;
				float y1 = c.y + 38 * u;
				float f = 18 * u;
				ImVec2[5] pts = .(.(x0, y0), .(x1 - f, y0), .(x1, y0 + f), .(x1, y1), .(x0, y1));
				Gui.ImDrawList_AddConvexPolyFilled(dl, &pts, 5, Gui.Color(205, 205, 205));
				Gui.ImDrawList_AddTriangleFilled(dl, .(x1 - f, y0), .(x1 - f, y0 + f), .(x1, y0 + f), Gui.Color(140, 140, 140));
				for (int i < 4)
				{
					float y = y0 + 32 * u + i * 10 * u;
					Gui.ImDrawList_AddLine(dl, .(x0 + 10 * u, y), .(x1 - 10 * u - (i == 3 ? 16 * u : 0), y), Gui.Color(120, 120, 120), 2.5f * u);
				}
			case .Library:
			{
				// Books on a shelf: a library of functions.
				float[3] hs = .(58, 70, 50);
				for (int i < 3)
				{
					float x = c.x - 34 * u + i * 24 * u;
					float top = c.y + 30 * u - hs[i] * u;
					Gui.ImDrawList_AddRectFilled(dl, .(x, top), .(x + 20 * u, c.y + 30 * u), (i == 1) ? light : col, 3 * u, 0);
					Gui.ImDrawList_AddLine(dl, .(x + 4 * u, top + 10 * u), .(x + 16 * u, top + 10 * u), dark, 2 * u);
				}
				Gui.ImDrawList_AddLine(dl, .(c.x - 42 * u, c.y + 33 * u), .(c.x + 42 * u, c.y + 33 * u), Gui.Color(190, 190, 190), 3 * u);
			}
			case .Folder:
				float x0 = c.x - 40 * u;
				float x1 = c.x + 40 * u;
				uint32 back = Theme.Mix(col, Gui.Color(0, 0, 0), 0.25f);
				Gui.ImDrawList_AddRectFilled(dl, .(x0, c.y - 32 * u), .(x0 + 32 * u, c.y - 18 * u), back, 4 * u, DrawFlags.RoundCornersTop);
				Gui.ImDrawList_AddRectFilled(dl, .(x0, c.y - 22 * u), .(x1, c.y + 30 * u), back, 4 * u, 0);
				Gui.ImDrawList_AddRectFilled(dl, .(x0, c.y - 12 * u), .(x1, c.y + 30 * u), col, 4 * u, 0);
				Gui.ImDrawList_AddLine(dl, .(x0 + 2 * u, c.y - 12 * u), .(x1 - 2 * u, c.y - 12 * u), Theme.Mix(col, Gui.Color(255, 255, 255), 0.4f), 1.5f * u);
			}
		}
	}

	extension EditorApp
	{
		// ------------------------------------------------------------------ state

		String mCBFolder = new .() ~ delete _;
		CBDir mCBTree ~ delete _;
		List<String> mCBSelected = new .() ~ DeleteContainerAndItems!(_);
		String mCBAnchor = new .() ~ delete _;
		String mCBScrollTo = new .() ~ delete _;
		TextBuffer mCBSearch = new .(256) ~ delete _;
		float mCBTileSize = 92;
		bool mCBDrawerOpen;
		int32 mCBDrawerFrames;
		bool mCBReveal = true;
		bool mCBItemCtxRequest;
		bool mCBRefocus;
		int64 mCBSignature;
		CBItem mCBOpenRequest ~ delete _;
		String mCBNavigateRequest = new .() ~ delete _;

		// Create / rename / delete modals
		bool mOpenCBNew;
		/// "Not inside a Beef project" prompt (create anyway / create a project / cancel).
		bool mOpenCBNoProject;
		AssetKind mCBPendKind;
		String mCBPendFolder = new .() ~ delete _;
		String mCBPendName = new .() ~ delete _;
		/// The create dialog is open (keeps the Project Drawer from closing under it).
		bool mCBModalOpen;
		AssetKind mCBNewKind;
		String mCBNewFolder = new .() ~ delete _;
		TextBuffer mCBNameBuf = new .(256) ~ delete _;
		bool mOpenCBRename;
		CBItem mCBRenameItem ~ delete _;
		/// The rename dialog renames a project (not just its folder): the project's current name, "Rename folder too".
		bool mCBRenameProject;
		bool mCBRenameProjectFolder;
		String mCBRenameProjectOld = new .() ~ delete _;
		bool mOpenCBDelete;
		List<CBItem> mCBDeleteItems = new .() ~ DeleteContainerAndItems!(_);

		// New Project modal
		bool mOpenNewProject;
		/// The dialog adds a project to the workspace of a folder of the open project (the Project Browser's folder menu)
		/// instead of making a project of its own that becomes the open one.
		bool mNPAddHere;
		TextBuffer mNPName = new .(256) ~ delete _;
		TextBuffer mNPLocation = new .(2048) ~ delete _;
		int32 mNPType;
		/// New Project > From template folder...: the folder, its template.json and the values of its variables.
		TextBuffer mNPTemplate = new .(2048) ~ delete _;
		String mNPTemplateSeen = new .() ~ delete _;
		TemplateManifest mNPTemplateInfo ~ delete _;
		String mNPTemplateError = new .() ~ delete _;
		List<TextBuffer> mNPVarBufs = new .() ~ DeleteContainerAndItems!(_);
		String mNPError = new .() ~ delete _;

		const float cTreeWidth = 210;

		// ------------------------------------------------------------------ paths

		static char8 PreferredSep(StringView path)
		{
			if (path.Contains('\\'))
				return '\\';
			if (path.Contains('/'))
				return '/';
			return Path.DirectorySeparatorChar;
		}

		public static void JoinPath(StringView dir, StringView name, String outPath)
		{
			outPath.Append(dir);
			if (!outPath.IsEmpty && !outPath.EndsWith('/') && !outPath.EndsWith('\\'))
				outPath.Append(PreferredSep(dir));
			outPath.Append(name);
		}

		/// True when `path` is inside `dir` (not equal to it).
		public static bool IsUnder(StringView path, StringView dir)
		{
			if (dir.IsEmpty || path.Length <= dir.Length)
				return false;
			if (!ProjectIndex.SamePath(path.Substring(0, dir.Length), dir))
				return false;
			let c = path[dir.Length];
			return c == '/' || c == '\\' || dir.EndsWith('/') || dir.EndsWith('\\');
		}

		static void TrimSeparators(String path)
		{
			while (path.Length > 1 && (path.EndsWith('/') || path.EndsWith('\\')) && !(path.Length == 3 && path[1] == ':'))
				path.RemoveFromEnd(1);
		}

		void RelativeToRoot(StringView path, String outRel)
		{
			if (IsUnder(path, mProjectRoot))
			{
				var rel = path.Substring(mProjectRoot.Length);
				while (rel.StartsWith('/') || rel.StartsWith('\\'))
					rel.RemoveFromStart(1);
				outRel.Append(rel);
			}
			else if (ProjectIndex.SamePath(path, mProjectRoot))
				Path.GetFileName(mProjectRoot, outRel);
			else
				outRel.Append(path);
		}

		/// Case-insensitive "does a file or folder with this name exist in `folder`" (so a project
		/// made on Linux still works on Windows).
		static bool EntryExists(StringView folder, StringView name)
		{
			if (!Directory.Exists(folder))
				return false;
			String n = scope .();
			for (let e in Directory.EnumerateFiles(folder))
			{
				n.Clear();
				e.GetFileName(n);
				if (StringView.Compare(n, name, true) == 0)
					return true;
			}
			for (let e in Directory.EnumerateDirectories(folder))
			{
				n.Clear();
				e.GetFileName(n);
				if (StringView.Compare(n, name, true) == 0)
					return true;
			}
			return false;
		}

		static bool SkipFolder(StringView name) => name.StartsWith(".") || name == "build" || name == "recovery";

		// ------------------------------------------------------------------ name validation

		static String[?] sKeywords = .("abstract", "alignof", "alloctype", "append", "as", "asm", "base", "bool", "break", "case", "catch",
			"char16", "char32", "char8", "checked", "class", "comptype", "concrete", "const", "continue", "decltype", "default", "defer",
			"delegate", "delete", "do", "double", "else", "enum", "explicit", "extension", "extern", "false", "finally", "fixed", "float",
			"for", "function", "if", "implicit", "in", "int", "int16", "int32", "int64", "int8", "interface", "internal", "is", "let",
			"mixin", "mut", "namespace", "new", "null", "nullable", "offsetof", "operator", "out", "override", "params", "private",
			"protected", "public", "readonly", "ref", "rettype", "return", "scope", "sealed", "sizeof", "static", "strideof", "struct",
			"switch", "this", "throw", "true", "try", "typealias", "typeof", "uint", "uint16", "uint32", "uint64", "uint8", "unchecked",
			"unsafe", "using", "var", "virtual", "void", "volatile", "where", "while");

		public static bool ValidateIdentifier(StringView name, String outError)
		{
			if (name.IsEmpty)
			{
				outError.Set("Enter a name.");
				return false;
			}
			if (!EnumCases.IsIdentifier(name))
			{
				outError.Set("Use letters, digits and _ only, not starting with a digit.");
				return false;
			}
			for (let k in sKeywords)
			{
				if (k == name)
				{
					outError.Set(scope $"'{name}' is a Beef keyword.");
					return false;
				}
			}
			return true;
		}

		/// File / folder names that are valid on Windows as well as Linux.
		public static bool ValidateFileName(StringView name, String outError)
		{
			if (name.IsEmpty)
			{
				outError.Set("Enter a name.");
				return false;
			}
			for (let c in name)
			{
				if ((uint8)c < 32 || "<>:\"/\\|?*".Contains(c))
				{
					outError.Set(scope $"'{c}' can't be used in a file name.");
					return false;
				}
			}
			if (name == "." || name == ".." || name.EndsWith('.') || name.EndsWith(' ') || name.StartsWith(' '))
			{
				outError.Set("The name can't start with a space or end with a dot or space.");
				return false;
			}
			String upper = scope .(name);
			int dot = upper.IndexOf('.');
			if (dot >= 0)
				upper.RemoveToEnd(dot);
			upper.ToUpper();
			if (upper == "CON" || upper == "PRN" || upper == "AUX" || upper == "NUL" ||
				((upper.StartsWith("COM") || upper.StartsWith("LPT")) && upper.Length == 4 && upper[3].IsDigit))
			{
				outError.Set("That name is reserved on Windows.");
				return false;
			}
			return true;
		}

		/// Is `name` already declared in namespace `ns`? (Beef allows the same name in different
		/// namespaces.) Cached while the same query is repeated, as the dialog asks every frame.
		bool TypeNameTaken(StringView name, StringView ns, String outWhere)
		{
			String key = scope .();
			key.AppendF("{}|{}|{}", name, ns, Index.Files.Count);
			if (mTakenKey != key)
			{
				mTakenKey.Set(key);
				mTakenWhere.Clear();
				mTakenResult = AssetOps.TypeNameTaken(Index, ns, name, mTakenWhere);
			}
			if (mTakenResult)
				outWhere.Set(mTakenWhere);
			return mTakenResult;
		}

		String mTakenKey = new .() ~ delete _;
		String mTakenWhere = new .() ~ delete _;
		bool mTakenResult;

		/// The namespace a type is declared in (first one), "" if none.
		void TypeNamespaceOf(StringView path, StringView typeName, String outNs)
		{
			String text = scope .();
			let doc = FindDoc(path);
			if (doc != null && doc.Unit != null)
				text.Set(doc.Text);
			else if (File.ReadAllText(path, text, true) case .Err)
				return;
			let unit = Parser.Parse(text);
			defer delete unit;
			List<String> nss = scope .();
			defer { ClearAndDeleteItems!(nss); }
			AssetOps.NamespacesOf(unit, typeName, nss);
			if (!nss.IsEmpty)
				outNs.Set(nss[0]);
		}

		/// Where a new asset of `kind` really goes: files and types belong in the `src` folder of
		/// the enclosing Beef project (a folder outside any project is reported as NoProject).
		SourcePlacement ResolveTarget(AssetKind kind, StringView folder, String outFolder)
		{
			if (kind == .Folder)
			{
				outFolder.Set(folder);
				return .InSource;
			}
			String proj = scope .();
			return AssetOps.ResolveSourceFolder(folder, outFolder, proj);
		}

		/// Validation for the "New ..." modal.
		bool ValidateNewAsset(AssetKind kind, StringView folder, StringView name, StringView ns, String outError)
		{
			if (!Directory.Exists(folder))
			{
				outError.Set("The destination folder no longer exists.");
				return false;
			}
			switch (kind)
			{
			case .Folder:
				if (!ValidateFileName(name, outError))
					return false;
				if (EntryExists(folder, name))
				{
					outError.Set("A file or folder with that name already exists here.");
					return false;
				}
			case .File:
				var n = name;
				if (n.EndsWith(".bf", .OrdinalIgnoreCase))
					n.RemoveFromEnd(3);
				if (!ValidateFileName(n, outError))
					return false;
				if (EntryExists(folder, scope String()..AppendF("{}.bf", n)))
				{
					outError.Set("A file with that name already exists here.");
					return false;
				}
			default:
				if (!ValidateIdentifier(name, outError))
					return false;
				String declFile = scope .();
				if (TypeNameTaken(name, ns, declFile))
				{
					String rel = scope .();
					RelativeToRoot(declFile, rel);
					outError.Set(scope $"A type named '{name}' already exists in namespace {ns.IsEmpty ? "(global)" : ns} ({rel}). Pick another name.");
					return false;
				}
				if (EntryExists(folder, scope String()..AppendF("{}.bf", name)))
				{
					outError.Set(scope $"{name}.bf already exists in this folder.");
					return false;
				}
			}
			return true;
		}

		// ------------------------------------------------------------------ folder tree

		void BuildContentTree()
		{
			delete mCBTree;
			mCBTree = null;
			if (mProjectRoot.IsEmpty || !Directory.Exists(mProjectRoot))
				return;
			mCBTree = new .();
			mCBTree.Path.Set(mProjectRoot);
			Path.GetFileName(mProjectRoot, mCBTree.Name);
			if (mCBTree.Name.IsEmpty)
				mCBTree.Name.Set(mProjectRoot);
			ScanContentDir(mCBTree, 0);
			MarkProjects();
			// Keep the current folder (or its nearest surviving parent).
			String folder = scope .(mCBFolder);
			while (!folder.IsEmpty && FindCBDir(folder) == null)
			{
				String parent = scope .();
				// A remembered folder from another project can walk up to a drive root, where there is no parent.
				if (!AssetOps.TryGetParent(folder, parent))
					break;
				folder.Set(parent);
			}
			if (folder.IsEmpty || FindCBDir(folder) == null)
				folder.Set(mProjectRoot);
			mCBFolder.Set(FindCBDir(folder).Path);
		}

		void ScanContentDir(CBDir dir, int depth)
		{
			if (depth > 12)
				return;
			for (let e in Directory.EnumerateFiles(dir.Path))
			{
				String path = new .();
				e.GetFilePath(path);
				if (path.EndsWith(".bf", .OrdinalIgnoreCase))
					dir.Files.Add(path);
				else
					delete path;
			}
			for (let e in Directory.EnumerateDirectories(dir.Path))
			{
				String name = scope .();
				e.GetFileName(name);
				if (SkipFolder(name))
					continue;
				CBDir sub = new .();
				sub.Name.Set(name);
				e.GetFilePath(sub.Path);
				sub.Parent = dir;
				dir.Dirs.Add(sub);
				ScanContentDir(sub, depth + 1);
			}
			dir.Files.Sort(scope (a, b) => StringView.Compare(a, b, true));
			dir.Dirs.Sort(scope (a, b) => StringView.Compare(a.Name, b.Name, true));
		}

		CBDir FindCBDir(StringView path) => (mCBTree != null) ? FindCBDir(mCBTree, path) : null;

		static CBDir FindCBDir(CBDir dir, StringView path)
		{
			if (ProjectIndex.SamePath(dir.Path, path))
				return dir;
			if (!IsUnder(path, dir.Path))
				return null;
			for (let d in dir.Dirs)
			{
				let found = FindCBDir(d, path);
				if (found != null)
					return found;
			}
			return null;
		}

		/// Cheap fingerprint of the folders and .bf files (names + write times) to notice
		/// changes made outside VisualBeef.
		int64 ComputeCBSignature()
		{
			if (mProjectRoot.IsEmpty || !Directory.Exists(mProjectRoot))
				return 0;
			int64 h = (int64)0xCBF29CE484222325;
			HashDir(mProjectRoot, 0, ref h);
			return h;
		}

		static void HashStr(StringView s, ref int64 h)
		{
			for (let c in s)
			{
				h ^= (uint8)c;
				h = (int64)((uint64)h * 0x100000001B3UL);
			}
			h ^= 0x7F;
		}

		static void HashDir(StringView dir, int depth, ref int64 h)
		{
			if (depth > 12)
				return;
			String name = scope .();
			for (let e in Directory.EnumerateFiles(dir))
			{
				name.Clear();
				e.GetFileName(name);
				// Project files too: a project added or renamed outside VisualBeef shows in the tree.
				if (!name.EndsWith(".bf", .OrdinalIgnoreCase) && name != "BeefSpace.toml" && name != "BeefProj.toml")
					continue;
				HashStr(name, ref h);
				h ^= e.GetLastWriteTimeUtc().Ticks;
				h = (int64)((uint64)h * 0x100000001B3UL);
			}
			for (let e in Directory.EnumerateDirectories(dir))
			{
				name.Clear();
				e.GetFileName(name);
				if (SkipFolder(name))
					continue;
				HashStr(name, ref h);
				String path = scope .();
				e.GetFilePath(path);
				HashDir(path, depth + 1, ref h);
			}
		}

		/// Called at the start of every frame: picks up files created, deleted or edited outside
		/// VisualBeef (polled about every 1.5 s).
		void UpdateProjectBrowser()
		{
			if (mProjectRoot.IsEmpty || mFrame % 90 != 45 || IsIndexing)
				return;
			if (Gui.igIsAnyItemActive() || Gui.igIsMouseDown_Nil(0))
				return;
			let sig = ComputeCBSignature();
			if (sig != mCBSignature)
				ScanProject();
		}

		// ------------------------------------------------------------------ items

		void AddTypeItems(IndexedFile file, StringView search, List<CBItem> outItems)
		{
			let doc = FindDoc(file.Path);
			bool modified = doc != null && doc.Modified;
			int shown = 0;
			String fileName = scope .();
			Path.GetFileName(file.Path, fileName);
			for (let t in file.Types)
			{
				if (!AssetStyle.FromType(t.Kind, t.IsStaticType, let kind))
					continue;
				if (!t.Outer.IsEmpty)
					continue; // nested types live inside their outer type's asset
				shown++;
				String match = scope .();
				if (!search.IsEmpty)
				{
					if (t.Name.IndexOf(search, true) < 0 && fileName.IndexOf(search, true) < 0)
					{
						for (let m in t.Methods)
						{
							if (m.Name.IndexOf(search, true) >= 0)
							{
								match.AppendF("function {}", m.Name);
								break;
							}
						}
						if (match.IsEmpty)
						{
							for (let fld in t.Fields)
							{
								if (fld.Name.IndexOf(search, true) >= 0)
								{
									match.AppendF("variable {}", fld.Name);
									break;
								}
							}
						}
						if (match.IsEmpty)
							continue;
					}
				}
				bool dup = false;
				for (let existing in outItems)
					if (existing.IsType && existing.TypeName == t.Name && ProjectIndex.SamePath(existing.Path, file.Path))
						dup = true;
				if (dup)
					continue;
				CBItem item = new .();
				item.Kind = kind;
				item.Name.Set((kind == .Globals) ? "Global functions" : t.Name);
				item.TypeName.Set(t.Name);
				item.Path.Set(file.Path);
				item.Methods = (.)t.Methods.Count;
				item.Fields = (.)t.Fields.Count;
				item.Line = t.Line;
				item.Modified = modified;
				item.Match.Set(match);
				CBItem.MakeKey(kind, file.Path, t.Name, item.Key);
				outItems.Add(item);
			}
			if (shown == 0 && (search.IsEmpty || fileName.IndexOf(search, true) >= 0))
			{
				CBItem item = new .();
				item.Kind = .File;
				item.Name.Set(fileName);
				item.Path.Set(file.Path);
				item.Modified = modified;
				CBItem.MakeKey(.File, file.Path, "", item.Key);
				outItems.Add(item);
			}
		}

		void AddFolderMatches(CBDir dir, StringView search, List<CBItem> outItems)
		{
			for (let d in dir.Dirs)
			{
				if (d.Name.IndexOf(search, true) >= 0)
				{
					CBItem item = new .();
					item.Kind = .Folder;
					item.Name.Set(d.Name);
					item.Path.Set(d.Path);
					CBItem.MakeKey(.Folder, d.Path, "", item.Key);
					outItems.Add(item);
				}
				AddFolderMatches(d, search, outItems);
			}
		}

		void CollectCBItems(StringView search, List<CBItem> outItems)
		{
			if (mCBTree == null)
				return;
			if (!search.IsEmpty)
			{
				AddFolderMatches(mCBTree, search, outItems);
				for (let file in Index.Files)
					AddTypeItems(file, search, outItems);
				outItems.Sort(scope (a, b) =>
					{
						if ((a.Kind == .Folder) != (b.Kind == .Folder))
							return (a.Kind == .Folder) ? -1 : 1;
						return StringView.Compare(a.Name, b.Name, true);
					});
				return;
			}
			let dir = FindCBDir(mCBFolder);
			if (dir == null)
				return;
			for (let d in dir.Dirs)
			{
				CBItem item = new .();
				item.Kind = .Folder;
				item.Name.Set(d.Name);
				item.Path.Set(d.Path);
				CBItem.MakeKey(.Folder, d.Path, "", item.Key);
				outItems.Add(item);
			}
			int typeStart = outItems.Count;
			for (let path in dir.Files)
			{
				let file = Index.FindFile(path);
				if (file != null)
					AddTypeItems(file, "", outItems);
				else
				{
					CBItem item = new .();
					item.Kind = .File;
					Path.GetFileName(path, item.Name);
					item.Path.Set(path);
					CBItem.MakeKey(.File, path, "", item.Key);
					outItems.Add(item);
				}
			}
			// Assets sorted by name, like UE (folders stay first).
			List<CBItem> assets = scope .();
			for (int i = typeStart; i < outItems.Count; i++)
				assets.Add(outItems[i]);
			assets.Sort(scope (a, b) => StringView.Compare(a.Name, b.Name, true));
			for (int i < assets.Count)
				outItems[typeStart + i] = assets[i];
		}

		bool IsCBSelected(StringView key)
		{
			for (let s in mCBSelected)
				if (s == key)
					return true;
			return false;
		}

		void CBSelectOnly(StringView key)
		{
			ClearAndDeleteItems!(mCBSelected);
			if (!key.IsEmpty)
				mCBSelected.Add(new String(key));
			mCBAnchor.Set(key);
		}

		void CBToggle(StringView key)
		{
			for (int i < mCBSelected.Count)
			{
				if (mCBSelected[i] == key)
				{
					delete mCBSelected[i];
					mCBSelected.RemoveAt(i);
					return;
				}
			}
			mCBSelected.Add(new String(key));
			mCBAnchor.Set(key);
		}

		void NavigateCB(StringView path)
		{
			String p = scope .(path);
			let dir = FindCBDir(p);
			if (dir == null)
				return;
			mCBFolder.Set(dir.Path);
			mCBReveal = true;
			CBSelectOnly("");
			SaveSettings();
		}

		// ------------------------------------------------------------------ drawing

		void DrawProjectBrowserWindows()
		{
			if (Gui.Begin(Panels.ProjectBrowser))
				DrawCBBody(false);
			Gui.End();

			if (mCBDrawerOpen)
			{
				let vp = Gui.igGetMainViewport();
				float h = Math.Max(220, vp.WorkSize.y * 0.42f);
				Gui.igSetNextWindowPos(.(vp.WorkPos.x, vp.WorkPos.y + vp.WorkSize.y - h), Cond.Always, .(0, 0));
				Gui.igSetNextWindowSize(.(vp.WorkSize.x, h), Cond.Always);
				if (mCBDrawerFrames == 0)
					Gui.igSetNextWindowFocus();
				bool open = true;
				if (Gui.Begin("Project Drawer", &open, WindowFlags.NoDocking | WindowFlags.NoCollapse | WindowFlags.NoSavedSettings | WindowFlags.NoMove | WindowFlags.NoResize))
				{
					DrawCBBody(true);
					// Closes like UE's drawer when you click elsewhere.
					bool focused = Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows);
					bool anyPopup = Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup);
					// (Not while a create / rename / delete dialog is pending or open: it would take
					// the drawer down with it, which looked like "+ Add does nothing".)
					bool dialogBusy = mCBModalOpen || mOpenCBNew || mOpenCBRename || mOpenCBDelete || mOpenNewProject || mOpenCBNoProject || mOpenWsNew || mOpenWsExisting || mWsNewOpen;
					if (mCBDrawerFrames > 2 && !focused && !anyPopup && !dialogBusy)
						open = false;
					if (Gui.IsKeyPressed(Key.Escape, false) && !anyPopup && !Gui.igIsAnyItemActive() && !dialogBusy)
						open = false;
				}
				Gui.End();
				mCBDrawerFrames++;
				if (!open)
					mCBDrawerOpen = false;
			}
			ProcessCBRequests();
			ProcessWorkspaceRequest();
		}

		public void ToggleProjectDrawer()
		{
			mCBDrawerOpen = !mCBDrawerOpen;
			mCBDrawerFrames = 0;
		}

		void ProcessCBRequests()
		{
			if (!mCBNavigateRequest.IsEmpty)
			{
				String path = scope .(mCBNavigateRequest);
				mCBNavigateRequest.Clear();
				NavigateCB(path);
			}
			if (mCBOpenRequest != null)
			{
				let item = mCBOpenRequest;
				mCBOpenRequest = null;
				OpenAsset(item);
				delete item;
			}
		}

		static bool GreenButton(StringView label)
		{
			Gui.igPushStyleColor_U32(Col.Button, Gui.Color(36, 120, 40));
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(52, 150, 56));
			Gui.igPushStyleColor_U32(Col.ButtonActive, Gui.Color(30, 100, 34));
			bool r = Gui.Button(label);
			Gui.igPopStyleColor(3);
			return r;
		}

		void DrawCBBody(bool drawer)
		{
			if (mProjectRoot.IsEmpty || mCBTree == null)
			{
				Gui.TextDisabled("No project folder open.");
				if (Gui.Button("Open Project Folder..."))
					OpenFolderPicker();
				Gui.SameLine();
				if (Gui.Button("New Project..."))
					StartNewProject();
				return;
			}

			// ---- toolbar: + Add, Save All | up, breadcrumb ............ search
			if (GreenButton("+ Add") || mSelfTestAddMenu)
				Gui.OpenPopup("##cbadd");
			mSelfTestAddMenu = false;
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Create a folder, class, struct, enum, interface or file; add a project to the workspace");
			if (Gui.BeginPopup("##cbadd"))
			{
				DrawAddMenu(mCBFolder);
				Gui.EndPopup();
			}
			Gui.SameLine();
			if (Gui.Button(scope $"{Icon.SaveAll}  Save All"))
				SaveAll();
			Gui.SameLine();
			DrawCBFilterBar();
			Gui.SameLine(0, 16);
			let dir = FindCBDir(mCBFolder);
			Gui.igBeginDisabled(dir == null || dir.Parent == null);
			if (Gui.igArrowButton("##cbup", Dir.Up) && dir?.Parent != null)
				mCBNavigateRequest.Set(dir.Parent.Path);
			Gui.igEndDisabled();
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Up one folder");
			Gui.SameLine();
			DrawBreadcrumb(dir);

			// Right-aligned search box; on a narrow panel it shrinks rather than covering the
			// breadcrumb (its last button ends at the last item's right edge).
			float afterCrumb = Gui.igGetItemRectMax().x - Gui.igGetWindowPos().x + 12 * Look.Scale;
			float rightPad = 40 * Look.Scale;
			float searchW = Math.Min(260 * Look.Scale, Gui.igGetWindowSize().x * 0.3f);
			searchW = Math.Max(Math.Min(searchW, Gui.igGetWindowSize().x - afterCrumb - rightPad), 90 * Look.Scale);
			Gui.SameLine(Math.Max(afterCrumb, Gui.igGetWindowSize().x - searchW - rightPad));
			Gui.igSetNextItemWidth(searchW);
			Gui.igInputTextWithHint("##cbsearch", scope $"{Icon.Search}  Search assets", mCBSearch.Ptr, (.)mCBSearch.Capacity, 0, null, null);
			Gui.SameLine();
			if (Gui.SmallButton("...##cbopts"))
				Gui.OpenPopup("##cbopts");
			if (Gui.BeginPopup("##cbopts"))
			{
				Gui.Text("Tile size");
				Gui.igSetNextItemWidth(180 * Look.Scale);
				Gui.igSliderFloat("##tilesize", &mCBTileSize, 56, 160, "%.0f", 0);
				if (Gui.MenuItem("Refresh", "F5"))
					ScanProject();
				Gui.EndPopup();
			}
			Gui.Separator();

			// ---- folder tree | asset grid
			if (Gui.igBeginChild_Str("##cbtree", .(cTreeWidth, 0), ChildFlags.ResizeX, 0))
			{
				DrawCBTree(mCBTree, true);
				mCBReveal = false;
			}
			Gui.igEndChild();
			Gui.SameLine();
			Gui.igBeginGroup();
			float footer = Gui.igGetFrameHeight();
			List<CBItem> items = scope .();
			defer { ClearAndDeleteItems!(items); }
			CollectCBItems(mCBSearch.View, items);
			FilterCBItems(items);
			Gui.igPushStyleColor_U32(Col.ChildBg, Gui.Color(21, 21, 21));
			if (Gui.igBeginChild_Str("##cbgrid", .(0, -footer), 0, 0))
				DrawCBGrid(items, drawer);
			Gui.igEndChild();
			Gui.igPopStyleColor(1);
			int selectedCount = 0;
			for (let it in items)
				if (IsCBSelected(it.Key))
					selectedCount++;
			String foot = scope .();
			foot.AppendF("{} item{}", items.Count, (items.Count == 1) ? "" : "s");
			if (selectedCount > 0)
				foot.AppendF(" ({} selected)", selectedCount);
			if (CBFilterActive)
				foot.Append("   - filtered");
			if (!mCBSearch.View.IsEmpty)
				foot.Append("   - searching the whole project");
			Gui.TextDisabled(foot);
			Gui.igEndGroup();
			ProcessCBDrop();
		}

		void DrawBreadcrumb(CBDir dir)
		{
			List<CBDir> chain = scope .();
			for (var d = dir; d != null; d = d.Parent)
				chain.Insert(0, d);
			Gui.igPushStyleColor_U32(Col.Button, 0);
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(255, 255, 255, 30));
			for (let d in chain)
			{
				if (@d.Index > 0)
				{
					Gui.SameLine(0, 2);
					Gui.TextDisabled(">");
					Gui.SameLine(0, 2);
				}
				Gui.PushID((int32)@d.Index);
				bool last = @d.Index == chain.Count - 1;
				if (last)
					Gui.igPushStyleColor_U32(Col.Text, Gui.Color(255, 255, 255));
				else
					Gui.igPushStyleColor_U32(Col.Text, Gui.Color(170, 170, 170));
				if (Gui.Button(d.Name) && !last)
					mCBNavigateRequest.Set(d.Path);
				Gui.igPopStyleColor(1);
				if (@d.Index == 0 && Gui.igIsItemHovered(0))
					Gui.Tooltip(mProjectRoot);
				Gui.PopID();
			}
			Gui.igPopStyleColor(2);
		}

		void DrawCBTree(CBDir dir, bool isRoot) => DrawCBTreeRow(dir, isRoot ? 1 : 0);

		/// One row of the folder tree and its children. `mode` 0: a folder or a project; 1: the root (the
		/// workspace); 2: the project whose folder is the root itself (`Path = "."`), drawn under the root with
		/// the root's own folders, the other projects beside it. Projects are their own kind of row (icon, name,
		/// startup mark) and are never folded into a "parent/child" chain.
		void DrawCBTreeRow(CBDir dir, int mode)
		{
			var d = dir;
			bool isRoot = mode == 1;
			bool asProject = (mode == 0 && d.ProjectName != null) || mode == 2;
			bool rootIsProject = isRoot && d.ProjectName != null;
			String name = scope .(d.Name);
			bool chainSelected = ProjectIndex.SamePath(d.Path, mCBFolder);
			if (mode == 0 && !asProject)
			{
				// Collapse single-folder chains ("Engine/src") like an IDE does, never into a project.
				while (d.Files.IsEmpty && d.Dirs.Count == 1 && d.Dirs[0].ProjectName == null)
				{
					d = d.Dirs[0];
					name.AppendF("/{}", d.Name);
					if (ProjectIndex.SamePath(d.Path, mCBFolder))
						chainSelected = true;
				}
			}
			bool hasKids = rootIsProject || (isRoot && !mCBOutsideProjects.IsEmpty);
			for (let sub in d.Dirs)
				if (mode != 2 || sub.ProjectName == null)
					hasKids = true;
			int32 flags = TreeNodeFlags.OpenOnArrow | TreeNodeFlags.SpanAvailWidth | (1 << 6) /* OpenOnDoubleClick */;
			if (!hasKids)
				flags |= TreeNodeFlags.Leaf;
			if (chainSelected && !rootIsProject)
				flags |= TreeNodeFlags.Selected;
			if (isRoot || asProject)
				flags |= TreeNodeFlags.DefaultOpen;
			if (mCBReveal && IsUnder(mCBFolder, d.Path))
				Gui.igSetNextItemOpen(true, Cond.Always);
			String label = scope .();
			let color = TreeRowLabel(d, name, isRoot, asProject, label);
			label.AppendF("##{}{}", mode, d.Path);
			Gui.igPushStyleColor_U32(Col.Text, color);
			bool open = Gui.TreeNode(label, flags);
			Gui.igPopStyleColor(1);
			TreeRowTooltip(d, isRoot, asProject);
			CBFolderDropTarget(d.Path);
			if (Gui.igIsItemClicked(0) && !Gui.igIsItemToggledOpen())
				mCBNavigateRequest.Set(d.Path);
			String ctxId = scope $"##ctx{mode}{d.Path}";
			if (!mSelfTestTreeMenu.IsEmpty && ProjectIndex.SamePath(mSelfTestTreeMenu, d.Path) && (mode != 1 || !rootIsProject))
			{
				mSelfTestTreeMenu.Clear();
				Gui.OpenPopup(ctxId);
				// Captures: where a right-click on the row would put it.
				let rowMin = Gui.igGetItemRectMin();
				Gui.igSetNextWindowPos(.(rowMin.x + 60 * Look.Scale, rowMin.y + Gui.igGetFrameHeight()), Cond.Always, .(0, 0));
			}
			if (Gui.igBeginPopupContextItem(ctxId, PopupFlags.MouseButtonRight))
			{
				DrawTreeRowMenu(d, isRoot || mode == 2, asProject);
				Gui.EndPopup();
			}
			TreeRowMarks(d, asProject);
			if (open)
			{
				if (rootIsProject)
				{
					DrawCBTreeRow(d, 2);
					for (let sub in d.Dirs)
						if (sub.ProjectName != null)
							DrawCBTreeRow(sub, 0);
				}
				else
				{
					for (let sub in d.Dirs)
						if (mode != 2 || sub.ProjectName == null)
							DrawCBTreeRow(sub, 0);
				}
				if (isRoot)
					for (let o in mCBOutsideProjects)
						DrawOutsideProjectRow(o);
				Gui.TreePop();
			}
		}

		/// A workspace project outside the open folder: a leaf with its menu; a click shows its settings.
		void DrawOutsideProjectRow(CBDir d)
		{
			String label = scope .();
			let color = TreeRowLabel(d, d.Name, false, true, label);
			label.AppendF("##out{}", d.Path);
			Gui.igPushStyleColor_U32(Col.Text, color);
			Gui.TreeNode(label, TreeNodeFlags.Leaf | TreeNodeFlags.SpanAvailWidth | TreeNodeFlags.NoTreePushOnOpen);
			Gui.igPopStyleColor(1);
			TreeRowTooltip(d, false, true);
			if (Gui.igIsItemClicked(0))
				QueueWsAction(.Settings, d.Path, d.ProjectName);
			String ctxId = scope $"##ctxout{d.Path}";
			if (Gui.igBeginPopupContextItem(ctxId, PopupFlags.MouseButtonRight))
			{
				DrawTreeRowMenu(d, false, true);
				Gui.EndPopup();
			}
			TreeRowMarks(d, true);
		}

		/// Text in a table cell: cut to the cell with "..." (a tooltip carries the whole text).
		/// `color` 0 draws it in the normal text colour; `dim` in the disabled one.
		static void CellText(StringView text, uint32 color = 0, bool dim = false)
		{
			String fit = scope .();
			FitText(text, Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x), fit);
			if (color != 0)
				Gui.TextColored(color, fit);
			else if (dim)
				Gui.TextDisabled(fit);
			else
				Gui.Text(fit);
		}

		/// A full-row Selectable whose text is cut to the cell with "..." (the id stays the same as
		/// the text changes with the width).
		static bool CellSelectable(StringView text, int32 flags, StringView id)
		{
			String fit = scope .();
			FitText(text, Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x), fit);
			fit.AppendF("###{}", id);
			return Gui.Selectable(fit, false, flags);
		}

		static void FitText(StringView text, float maxW, String outText)
		{
			outText.Set(text);
			if (Gui.CalcTextSize(outText).x <= maxW)
				return;
			while (outText.Length > 1)
			{
				outText.RemoveFromEnd(1);
				String probe = scope .(outText);
				probe.Append("...");
				if (Gui.CalcTextSize(probe).x <= maxW)
				{
					outText.Set(probe);
					return;
				}
			}
		}

		/// Splits a name over at most two lines (breaking at a word / camel-case boundary when
		/// possible); the second line gets "..." when it still doesn't fit.
		static void WrapName(StringView text, float maxW, String line1, String line2)
		{
			if (Gui.CalcTextSize(text).x <= maxW)
			{
				line1.Set(text);
				return;
			}
			int fit = 1;
			while (fit < text.Length && Gui.CalcTextSize(text.Substring(0, fit + 1)).x <= maxW)
				fit++;
			int brk = -1;
			for (int i = fit; i > fit / 2; i--)
			{
				let c = text[i];
				let prev = text[i - 1];
				if ((c.IsUpper && !prev.IsUpper) || prev == '_' || prev == '-' || prev == '.' || prev == ' ')
				{
					brk = i;
					break;
				}
			}
			// No word boundary: never split mid-word ("CApplicatio / n"); shorten with "..." instead.
			if (brk < 0)
			{
				FitText(text, maxW, line1);
				return;
			}
			line1.Set(text.Substring(0, brk));
			FitText(text.Substring(brk), maxW, line2);
		}

		void DrawCBGrid(List<CBItem> items, bool drawer)
		{
			let search = mCBSearch.View;
			float tile = Math.Clamp(mCBTileSize, 56, 160);
			float fontH = Gui.igGetFontSize();
			float labelH = fontH * 3 + 8;
			float spacing = 10;
			Gui.igSetCursorPos(.(Gui.igGetCursorPos().x + 6, Gui.igGetCursorPos().y + 6));
			float availW = Gui.igGetContentRegionAvail().x - 6;
			int cols = Math.Max(1, (int)((availW + spacing) / (tile + spacing)));
			let dl = Gui.igGetWindowDrawList();
			float startX = Gui.igGetCursorPos().x;

			if (items.IsEmpty)
			{
				Gui.igSetCursorPos(.(startX + 8, Gui.igGetCursorPos().y + 8));
				if (!search.IsEmpty)
					Gui.TextDisabled("No assets match the search.");
				else
				{
					Gui.TextDisabled("This folder is empty.");
					Gui.igSetCursorPos(.(startX + 8, Gui.igGetCursorPos().y));
					Gui.TextDisabled("Right-click or use + Add to create a class, struct, enum, interface or folder.");
				}
			}

			for (let item in items)
			{
				int i = @item.Index;
				if (i % cols != 0)
					Gui.SameLine(0, spacing);
				else if (i > 0)
				{
					Gui.igSetCursorPos(.(startX, Gui.igGetCursorPos().y + 4));
				}
				Gui.PushID(item.Key);
				Gui.igInvisibleButton("##tile", .(tile, tile + labelH), ButtonFlags.MouseButtonLeft | ButtonFlags.MouseButtonRight);
				CBTileDragDrop(item);
				bool hovered = Gui.igIsItemHovered(0);
				bool selected = IsCBSelected(item.Key);
				if (mCBScrollTo == item.Key)
				{
					Gui.igSetScrollHereY(0.5f);
					mCBScrollTo.Clear();
				}
				if (Gui.igIsItemClicked(0))
				{
					if (Gui.IsCtrlDown)
						CBToggle(item.Key);
					else if (Gui.IsShiftDown && !mCBAnchor.IsEmpty)
					{
						int anchor = -1;
						for (let other in items)
							if (other.Key == mCBAnchor)
								anchor = @other.Index;
						if (anchor < 0)
							CBSelectOnly(item.Key);
						else
						{
							ClearAndDeleteItems!(mCBSelected);
							for (int k = Math.Min(anchor, i); k <= Math.Max(anchor, i); k++)
								mCBSelected.Add(new String(items[k].Key));
						}
					}
					else
						CBSelectOnly(item.Key);
				}
				if (hovered && Gui.igIsMouseDoubleClicked_Nil(0))
				{
					delete mCBOpenRequest;
					mCBOpenRequest = item.Clone();
				}
				if (Gui.igIsItemClicked(1))
				{
					if (!selected)
						CBSelectOnly(item.Key);
					mCBItemCtxRequest = true;
				}
				// Drag a folder or file to the OS? Not supported; drag-to-graph is not either.
				selected = IsCBSelected(item.Key);
				DrawTile(dl, item, Gui.igGetItemRectMin(), tile, labelH, hovered, selected);
				if (Gui.igIsItemHovered(1 << 12 /* ForTooltip */))
					DrawTileTooltip(item);
				Gui.PopID();
			}
			Gui.igDummy(.(0, 8));

			// Click on empty space clears the selection.
			if (Gui.igIsWindowHovered(0) && !Gui.igIsAnyItemHovered() && Gui.igIsMouseClicked_Bool(0, false))
				CBSelectOnly("");

			// Keyboard: F2 rename, Del delete, Enter open.
			if (Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows) && !Gui.igIsAnyItemActive())
			{
				List<CBItem> sel = scope .();
				for (let it in items)
					if (IsCBSelected(it.Key))
						sel.Add(it);
				if (Gui.IsKeyPressed(573 /* F2 */, false) && sel.Count == 1)
					StartRename(sel[0]);
				if (Gui.IsKeyPressed(Key.Delete, false) && !sel.IsEmpty)
				{
					ClearAndDeleteItems!(mCBDeleteItems);
					for (let it in sel)
						mCBDeleteItems.Add(it.Clone());
					mOpenCBDelete = true;
				}
				if (Gui.IsKeyPressed(Key.Enter, false) && sel.Count == 1)
				{
					delete mCBOpenRequest;
					mCBOpenRequest = sel[0].Clone();
				}
				if (Gui.IsKeyPressed(Key.F5, false))
				{
					ScanProject();
					mCBTookF5 = true; // a refresh, not Start Debugging
				}
				if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.A, false))
				{
					ClearAndDeleteItems!(mCBSelected);
					for (let it in items)
						mCBSelected.Add(new String(it.Key));
				}
			}

			// Item context menu (opened from a tile right-click).
			if (mCBItemCtxRequest)
			{
				mCBItemCtxRequest = false;
				Gui.OpenPopup("##cbitemctx");
			}
			if (Gui.BeginPopup("##cbitemctx"))
			{
				List<CBItem> sel = scope .();
				for (let it in items)
					if (IsCBSelected(it.Key))
						sel.Add(it);
				if (sel.IsEmpty)
					Gui.igCloseCurrentPopup();
				else
					DrawItemMenu(sel);
				Gui.EndPopup();
			}
			// Empty-space context menu: the + Add menu.
			if (Gui.igBeginPopupContextWindow("##cbvoidctx", PopupFlags.MouseButtonRight | PopupFlags.NoOpenOverItems))
			{
				DrawAddMenu(mCBFolder);
				Gui.EndPopup();
			}
		}

		void DrawTile(ImDrawList* dl, CBItem item, ImVec2 p0, float tile, float labelH, bool hovered, bool selected)
		{
			ImVec2 p1 = .(p0.x + tile, p0.y + tile + labelH);
			let kc = AssetStyle.KindColor(item.Kind);
			float fontH = Gui.igGetFontSize();
			String name = scope .(item.Name);
			if (item.Modified)
				name.Append('*');
			String line1 = scope .();
			String line2 = scope .();
			if (item.Kind == .Folder)
			{
				if (selected)
					Gui.ImDrawList_AddRectFilled(dl, p0, .(p1.x, p1.y - fontH + 4), Theme.WithAlpha(Look.Primary, 120), 5, 0);
				else if (hovered)
					Gui.ImDrawList_AddRectFilled(dl, p0, .(p1.x, p1.y - fontH + 4), Gui.Color(255, 255, 255, 20), 5, 0);
				AssetStyle.DrawIcon(dl, .Folder, .(p0.x + tile / 2, p0.y + tile * 0.52f), tile * 0.82f, kc);
				DrawProjectTileMark(dl, item, p0, tile);
				WrapName(name, tile - 4, line1, line2);
				float w1 = Gui.CalcTextSize(line1).x;
				AssetStyle.Text(dl, line1, .(p0.x + (tile - w1) / 2, p0.y + tile + 2), fontH, Gui.Color(225, 225, 225));
				if (!line2.IsEmpty)
				{
					float w2 = Gui.CalcTextSize(line2).x;
					AssetStyle.Text(dl, line2, .(p0.x + (tile - w2) / 2, p0.y + tile + 2 + fontH), fontH, Gui.Color(225, 225, 225));
				}
				return;
			}
			uint32 card = selected ? Theme.Mix(Look.Header, Look.Primary, 0.35f) : (hovered ? Gui.Color(56, 56, 56) : Gui.Color(40, 40, 40));
			Gui.ImDrawList_AddRectFilled(dl, .(p0.x + 3, p0.y + 4), .(p1.x + 3, p1.y + 4), Gui.Color(0, 0, 0, 90), 6, 0);
			Gui.ImDrawList_AddRectFilled(dl, p0, p1, card, 6, 0);
			// Thumbnail: dark gradient tinted with the kind's color, icon in the middle.
			ImVec2 t0 = .(p0.x + 1, p0.y + 1);
			ImVec2 t1 = .(p1.x - 1, p0.y + tile - 3);
			uint32 top = Theme.Mix(Gui.Color(26, 26, 26), kc, hovered ? 0.36f : 0.26f);
			uint32 bottom = Gui.Color(14, 14, 14);
			Gui.ImDrawList_AddRectFilled(dl, t0, t1, top, 6, DrawFlags.RoundCornersTop);
			Gui.ImDrawList_AddRectFilledMultiColor(dl, .(t0.x, t0.y + 6), t1, top, top, bottom, bottom);
			AssetStyle.DrawIcon(dl, item.Kind, .(p0.x + tile / 2, p0.y + (tile - 3) / 2), tile * 0.7f, kc);
			// Kind strip.
			Gui.ImDrawList_AddRectFilled(dl, .(p0.x, p0.y + tile - 3), .(p1.x, p0.y + tile), kc, 0, 0);
			// Name (up to two lines) and kind at the bottom, like UE.
			WrapName(name, tile - 10, line1, line2);
			uint32 nameCol = item.Modified ? Theme.Warning : Gui.Color(235, 235, 235);
			AssetStyle.Text(dl, line1, .(p0.x + 5, p0.y + tile + 3), fontH, nameCol);
			if (!line2.IsEmpty)
				AssetStyle.Text(dl, line2, .(p0.x + 5, p0.y + tile + 3 + fontH), fontH, nameCol);
			String kindText = scope .();
			FitText(AssetStyle.KindLabel(item.Kind), tile - 10, kindText);
			AssetStyle.Text(dl, kindText, .(p0.x + 5, p1.y - fontH * 0.86f - 4), fontH * 0.86f, Gui.Color(140, 140, 140));
			if (selected)
				Gui.ImDrawList_AddRect(dl, p0, p1, Look.Primary, 6, 2, 0);
			else if (hovered)
				Gui.ImDrawList_AddRect(dl, p0, p1, Look.Hover2, 6, 1, 0);
		}

		void DrawTileTooltip(CBItem item)
		{
			if (!Gui.igBeginTooltip())
				return;
			Gui.Text(item.Name);
			Gui.TextColored(AssetStyle.KindColor(item.Kind), AssetStyle.KindLabel(item.Kind));
			String rel = scope .();
			RelativeToRoot(item.Path, rel);
			if (item.IsType)
			{
				Gui.TextDisabled(scope $"{rel}  (line {item.Line})");
				if (item.Kind == .Enum)
					Gui.TextDisabled("Double-click to edit the enumerators");
				else
					Gui.TextDisabled(scope $"{item.Methods} function{(item.Methods == 1) ? "" : "s"}, {item.Fields} variable{(item.Fields == 1) ? "" : "s"}");
				if (!item.Match.IsEmpty)
					Gui.TextColored(Theme.Warning, scope $"matches {item.Match}");
			}
			else
				Gui.TextDisabled(rel);
			if (item.Modified)
				Gui.TextColored(Theme.Warning, "Unsaved changes");
			Gui.igEndTooltip();
		}

		void MenuIcon(AssetKind kind)
		{
			let min = Gui.igGetItemRectMin();
			let max = Gui.igGetItemRectMax();
			float h = max.y - min.y;
			AssetStyle.DrawIcon(Gui.igGetWindowDrawList(), kind, .(min.x + h * 0.5f, min.y + h * 0.5f), h * 0.85f, AssetStyle.KindColor(kind));
		}

		bool IconMenuItem(AssetKind kind, StringView label, StringView shortcut = "")
		{
			String l = scope .();
			l.AppendF("      {}", label);
			bool r = Gui.MenuItem(l, shortcut);
			MenuIcon(kind);
			return r;
		}

		/// The "+ Add" / right-click menu, acting on `folder` (`withFolder`: the New Folder item, which the tree's
		/// folder menus show at the top instead).
		void DrawAddMenu(StringView folderIn, bool withFolder = true)
		{
			if (mSelfTestCloseMenus)
				Gui.igCloseCurrentPopup();
			String folder = scope .(folderIn);
			if (withFolder)
			{
				Gui.TextDisabled("CREATE");
				if (IconMenuItem(.Folder, "New Folder"))
					StartNewAsset(.Folder, folder);
				Gui.Separator();
			}
			Gui.TextDisabled("BEEF TYPES");
			if (IconMenuItem(.Class, "New Class..."))
				StartNewAsset(.Class, folder);
			if (IconMenuItem(.Struct, "New Struct..."))
				StartNewAsset(.Struct, folder);
			if (IconMenuItem(.Enum, "New Enum..."))
				StartNewAsset(.Enum, folder);
			if (IconMenuItem(.Interface, "New Interface..."))
				StartNewAsset(.Interface, folder);
			if (IconMenuItem(.Library, "New Node Library..."))
				StartNewAsset(.Library, folder);
			Gui.Separator();
			if (IconMenuItem(.File, "New Beef File (empty)..."))
				StartNewAsset(.File, folder);
			Gui.Separator();
			DrawProjectAddItems();
			Gui.Separator();
			if (Gui.MenuItem("Show in Explorer"))
				ShowInExplorer(folder, false);
			if (Gui.MenuItem("Copy Path"))
				Gui.igSetClipboardText(folder);
			if (Gui.MenuItem("Refresh", "F5"))
				ScanProject();
		}

		/// Right-click menu of the selected tiles.
		void DrawItemMenu(List<CBItem> sel)
		{
			let first = sel[0];
			if (sel.Count == 1)
			{
				Gui.TextColored(AssetStyle.KindColor(first.Kind), AssetStyle.KindLabel(first.Kind));
				Gui.SameLine();
				Gui.Text(first.Name);
			}
			else
				Gui.Text(scope $"{sel.Count} items");
			Gui.Separator();
			// A project's folder: the project's own entries first.
			let projectDir = (sel.Count == 1 && first.Kind == .Folder) ? ProjectDirOf(first.Path) : null;
			if (projectDir != null)
			{
				DrawProjectMenu(projectDir);
				Gui.Separator();
			}
			if (sel.Count == 1 && Gui.MenuItem("Open", "Enter"))
			{
				delete mCBOpenRequest;
				mCBOpenRequest = first.Clone();
			}
			if (sel.Count == 1 && first.Kind != .Globals && Gui.MenuItem("Rename", "F2"))
				StartRename(first);
			if (Gui.MenuItem("Delete", "Del"))
			{
				ClearAndDeleteItems!(mCBDeleteItems);
				for (let it in sel)
					mCBDeleteItems.Add(it.Clone());
				mOpenCBDelete = true;
			}
			Gui.Separator();
			if (Gui.MenuItem("Copy Path"))
			{
				String paths = scope .();
				for (let it in sel)
				{
					if (@it.Index > 0)
						paths.Append('\n');
					paths.Append(it.Path);
				}
				Gui.igSetClipboardText(paths);
			}
			if (sel.Count == 1 && first.IsType && Gui.MenuItem("Copy Type Name"))
				Gui.igSetClipboardText(scope String(first.TypeName));
			if (sel.Count == 1 && Gui.MenuItem("Show in Explorer"))
				ShowInExplorer(first.Path, first.Kind != .Folder);
		}

		void ShowInExplorer(StringView path, bool isFile)
		{
			ProcessStartInfo psi = scope .();
			String args = scope .();
#if BF_PLATFORM_WINDOWS
			psi.SetFileName("explorer.exe");
			String winPath = scope .(path);
			winPath.Replace('/', '\\');
			if (isFile)
				args.AppendF("/select,\"{}\"", winPath);
			else
				args.AppendF("\"{}\"", winPath);
#else
			psi.SetFileName("xdg-open");
			String dir = scope .(path);
			if (isFile)
			{
				dir.Clear();
				Path.GetDirectoryPath(path, dir).IgnoreError(); // a root has no parent: dir stays empty
			}
			args.AppendF("\"{}\"", dir);
#endif
			psi.SetArguments(args);
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
				SetStatus("Could not open the file browser");
		}

		// ------------------------------------------------------------------ opening assets

		/// Loads a file into the session without making it the current document.
		SourceDocument LoadDocQuiet(StringView path)
		{
			var doc = FindDoc(path);
			if (doc != null)
				return doc;
			doc = new SourceDocument();
			if (doc.Load(path) case .Err)
			{
				delete doc;
				SetStatus(scope $"Could not open {path}");
				return null;
			}
			if (File.GetLastWriteTime(path) case .Ok(let t))
				doc.DiskTime = t;
			mDocs.Add(doc);
			Index.Update(doc.FilePath, doc.Unit);
			doc.IndexedVersion = doc.Version;
			return doc;
		}

		void OpenAsset(CBItem item)
		{
			switch (item.Kind)
			{
			case .Folder:
				NavigateCB(item.Path);
			case .File:
				if (OpenFile(item.Path, false) != null)
				{
					mSelectSourceFileTab = true;
					Panels.Focus(Panels.BeefSourceId);
				}
			case .Enum:
				OpenEnumEditor(item.Path, item.TypeName);
			default:
				OpenTypeEditor(item.Path, item.TypeName);
			}
		}

		// ------------------------------------------------------------------ create

		void StartNewAsset(AssetKind kind, StringView folder)
		{
			ResetCreateTypeOptions();
			mCBNewKind = kind;
			if (kind == .Library)
				mCBNewTemplate = 1;
			mCBNewFolder.Set(folder);
			StringView baseName;
			switch (kind)
			{
			case .Folder: baseName = "NewFolder";
			case .Class: baseName = "NewClass";
			case .Struct: baseName = "NewStruct";
			case .Enum: baseName = "NewEnum";
			case .Interface: baseName = "INewInterface";
			case .Library: baseName = "NewLibrary";
			case .File: baseName = "NewFile";
			default: baseName = "NewAsset";
			}
			if (!CheckWritable())
				return;
			String target = scope .();
			ResolveTarget(kind, folder, target);
			String ns = scope .();
			if (kind != .Folder)
				InferNamespace(target, ns);
			String name = scope .(baseName);
			String err = scope .();
			for (int n = 1; n < 100 && !ValidateNewAsset(kind, target, name, ns, err); n++)
			{
				name.Set(baseName);
				name.AppendF("{}", n);
				err.Clear();
			}
			mCBNameBuf.Set(name);
			mNsCacheFolder.Clear();
			mOpenCBNew = true;
		}

		/// Namespace for a new file: the most common one in the folder's .bf files (then its
		/// parents'), else the project name.
		void InferNamespace(StringView folder, String outNs)
		{
			String dirPath = scope .(folder);
			for (int depth = 0; depth < 8 && !dirPath.IsEmpty; depth++)
			{
				Dictionary<String, int> counts = scope .();
				defer { for (let k in counts.Keys) delete k; }
				let dir = FindCBDir(dirPath);
				if (dir != null)
				{
					for (let path in dir.Files)
					{
						String text = scope .();
						let doc = FindDoc(path);
						if (doc != null && doc.Unit != null)
							text.Set(doc.Text);
						else if (File.ReadAllText(path, text, true) case .Err)
							continue;
						let unit = Parser.Parse(text);
						defer delete unit;
						for (let m in unit.Members)
						{
							if (m.Kind != .Namespace || m.Name.IsEmpty)
								continue;
							String ns = scope .(m.Name);
							ns.Trim();
							if (counts.TryGetValue(ns, let c))
								counts[ns] = c + 1;
							else
								counts[new String(ns)] = 1;
						}
					}
				}
				String best = null;
				int bestCount = 0;
				for (let kv in counts)
				{
					if (kv.value > bestCount || (kv.value == bestCount && best != null && StringView.Compare(kv.key, best, false) < 0))
					{
						best = kv.key;
						bestCount = kv.value;
					}
				}
				if (best != null)
				{
					outNs.Set(best);
					return;
				}
				if (dir == null || dir.Parent == null)
					break;
				dirPath.Set(dir.Parent.Path);
			}
			// The project name: BeefProj.toml above the folder, else the root folder's name.
			String probe = scope .(folder);
			for (int depth = 0; depth < 16 && !probe.IsEmpty; depth++)
			{
				String toml = scope .();
				JoinPath(probe, "BeefProj.toml", toml);
				String content = scope .();
				if (File.ReadAllText(toml, content) case .Ok)
				{
					for (var line in content.Split('\n'))
					{
						line.Trim();
						if (line.StartsWith("Name") && line.Contains('"'))
						{
							int q0 = line.IndexOf('"');
							int q1 = line.LastIndexOf('"');
							if (q1 > q0)
							{
								SanitizeIdentifier(line.Substring(q0 + 1, q1 - q0 - 1), outNs);
								return;
							}
						}
					}
				}
				if (ProjectIndex.SamePath(probe, mProjectRoot))
					break;
				String parent = scope .();
				// At a root there is no parent (.Err); stop walking.
				if (Path.GetDirectoryPath(probe, parent) case .Err || parent == probe)
					break;
				probe.Set(parent);
			}
			String rootName = scope .();
			Path.GetFileName(mProjectRoot, rootName);
			SanitizeIdentifier(rootName, outNs);
		}

		static void SanitizeIdentifier(StringView text, String outId)
		{
			outId.Clear();
			for (let c in text)
				outId.Append((c.IsLetterOrDigit || c == '_') ? c : '_');
			if (outId.IsEmpty || outId[0].IsDigit)
				outId.Insert(0, "_");
		}

		static void MakeTypeTemplate(AssetKind kind, StringView ns, StringView name, String outText)
		{
			outText.Append("using System;\n\n");
			outText.AppendF("namespace {}\n{{\n", ns);
			switch (kind)
			{
			case .Class:
				outText.AppendF("\tclass {}\n\t{{\n", name);
				outText.Append("\t\tpublic this()\n\t\t{\n\t\t}\n\n");
				outText.Append("\t\tpublic void Update()\n\t\t{\n\t\t}\n");
				outText.Append("\t}\n");
			case .Struct:
				outText.AppendF("\tstruct {}\n\t{{\n", name);
				outText.Append("\t\tpublic int Value;\n");
				outText.Append("\t}\n");
			case .Enum:
				outText.AppendF("\tenum {}\n\t{{\n", name);
				outText.Append("\t\tNewEnumerator0,\n\t\tNewEnumerator1\n");
				outText.Append("\t}\n");
			case .Interface:
				outText.AppendF("\tinterface {}\n\t{{\n", name);
				outText.Append("\t}\n");
			default:
			}
			outText.Append("}\n");
		}

		void CreateAsset(AssetKind kind, StringView folderIn, StringView nameIn, bool allowOutsideProject = false)
		{
			if (!CheckWritable())
				return;
			String folder = scope .(folderIn);
			String name = scope .(nameIn);
			name.Trim();
			String target = scope .();
			let placement = ResolveTarget(kind, folder, target);
			if (placement == .NoProject && !allowOutsideProject)
			{
				// Not compiled anywhere: let the user decide instead of silently creating a dead file.
				mCBPendKind = kind;
				mCBPendFolder.Set(folder);
				mCBPendName.Set(name);
				mOpenCBNoProject = true;
				return;
			}
			if (placement == .Redirected)
				SetStatus(scope $"{folder} is not a source folder: creating in the project's src folder.");
			String ns = scope .();
			if (kind != .Folder)
				InferNamespace(target, ns);
			String err = scope .();
			if (!Directory.Exists(target) && placement == .Redirected)
			{
				if (Directory.CreateDirectory(target) case .Err)
				{
					ReportError(scope $"Could not create {target}.");
					return;
				}
			}
			if (!ValidateNewAsset(kind, target, name, ns, err))
			{
				ReportError(err);
				return;
			}
			String path = scope .();
			switch (kind)
			{
			case .Folder:
				JoinPath(target, name, path);
				if (AssetOps.CreateFolder(path, err) case .Err)
				{
					ReportError(err);
					return;
				}
				ScanProject();
				String key = scope .();
				CBItem.MakeKey(.Folder, FindCBDir(path)?.Path ?? path, "", key);
				CBSelectOnly(key);
				mCBScrollTo.Set(key);
				SetStatus(scope $"Created folder {name}");
				return;
			case .File:
				if (name.EndsWith(".bf", .OrdinalIgnoreCase))
					name.RemoveFromEnd(3);
				JoinPath(target, scope String()..AppendF("{}.bf", name), path);
				String text = scope .();
				text.AppendF("using System;\n\nnamespace {}\n{{\n}}\n", ns);
				if (AssetOps.CreateTextFile(path, text, err) case .Err)
				{
					ReportError(err);
					return;
				}
				ScanProject();
				String key = scope .();
				CBItem.MakeKey(.File, path, "", key);
				CBSelectOnly(key);
				mCBScrollTo.Set(key);
				if (OpenFile(path, false) != null)
					mSelectSourceFileTab = true;
				SetStatus(scope $"Created {name}.bf");
				return;
			default:
			}
			JoinPath(target, scope String()..AppendF("{}.bf", name), path);
			String text = scope .();
			MakeNewTypeText(kind, ns, name, text);
			if (AssetOps.CreateTextFile(path, text, err) case .Err)
			{
				ReportError(err);
				return;
			}
			ScanProject();
			CBItem item = scope .();
			item.Kind = kind;
			item.Name.Set(name);
			item.TypeName.Set(name);
			item.Path.Set(path);
			CBItem.MakeKey(kind, path, name, item.Key);
			CBSelectOnly(item.Key);
			mCBScrollTo.Set(item.Key);
			OpenAsset(item);
			SetStatus(scope $"Created {AssetStyle.KindLabel(kind)} {name} in {name}.bf (namespace {ns})");
		}

		// ------------------------------------------------------------------ rename

		void StartRename(CBItem item)
		{
			delete mCBRenameItem;
			mCBRenameItem = item.Clone();
			mCBRenameProject = false;
			if (item.Kind == .File)
			{
				String n = scope .(item.Name);
				if (n.EndsWith(".bf", .OrdinalIgnoreCase))
					n.RemoveFromEnd(3);
				mCBNameBuf.Set(n);
			}
			else if (item.IsType)
				mCBNameBuf.Set(item.TypeName);
			else
				mCBNameBuf.Set(item.Name);
			mOpenCBRename = true;
		}

		bool ValidateRename(CBItem item, StringView newName, String outError)
		{
			switch (item.Kind)
			{
			case .Folder, .File:
				var n = newName;
				if (item.Kind == .File && n.EndsWith(".bf", .OrdinalIgnoreCase))
					n.RemoveFromEnd(3);
				if (!ValidateFileName(n, outError))
					return false;
				String parent = scope .();
				Path.GetDirectoryPath(item.Path, parent).IgnoreError(); // a root has no parent: parent stays empty
				String full = scope .(n);
				if (item.Kind == .File)
					full.Append(".bf");
				String oldName = scope .();
				Path.GetFileName(item.Path, oldName);
				if (StringView.Compare(full, oldName, true) != 0 && EntryExists(parent, full))
				{
					outError.Set("Something with that name already exists here.");
					return false;
				}
			default:
				if (!ValidateIdentifier(newName, outError))
					return false;
				if (newName != item.TypeName)
				{
					String ns = scope .();
					TypeNamespaceOf(item.Path, item.TypeName, ns);
					String declFile = scope .();
					if (TypeNameTaken(newName, ns, declFile))
					{
						outError.Set(scope $"A type named '{newName}' already exists in namespace {ns.IsEmpty ? "(global)" : ns}.");
						return false;
					}
				}
			}
			return true;
		}

		/// Points open documents at their new paths after a file or folder moved.
		void RemapDocPaths(StringView oldPath, StringView newPath, bool isFolder)
		{
			for (let d in mDocs)
			{
				if (ProjectIndex.SamePath(d.FilePath, oldPath))
					d.FilePath.Set(newPath);
				else if (isFolder && IsUnder(d.FilePath, oldPath))
				{
					String p = scope .(newPath);
					p.Append(StringView(d.FilePath, oldPath.Length));
					d.FilePath.Set(p);
				}
			}
			for (let tab in mAssetTabs)
			{
				if (ProjectIndex.SamePath(tab.FilePath, oldPath))
					tab.FilePath.Set(newPath);
				else if (isFolder && IsUnder(tab.FilePath, oldPath))
				{
					String p = scope .(newPath);
					p.Append(StringView(tab.FilePath, oldPath.Length));
					tab.FilePath.Set(p);
				}
			}
			if (isFolder && (ProjectIndex.SamePath(mCBFolder, oldPath) || IsUnder(mCBFolder, oldPath)))
			{
				String p = scope .(newPath);
				p.Append(StringView(mCBFolder, oldPath.Length));
				mCBFolder.Set(p);
			}
		}

		void RenameAsset(CBItem item, StringView newNameIn)
		{
			if (!CheckWritable())
				return;
			String newName = scope .(newNameIn);
			newName.Trim();
			String err = scope .();
			if (!ValidateRename(item, newName, err))
			{
				ReportError(err);
				return;
			}
			String parent = scope .();
			Path.GetDirectoryPath(item.Path, parent).IgnoreError(); // a root has no parent: parent stays empty
			switch (item.Kind)
			{
			case .Folder:
				String newPath = scope .();
				JoinPath(parent, newName, newPath);
				if (ProjectIndex.SamePath(newPath, item.Path) && newPath == item.Path)
					return;
				if (AssetOps.MovePath(item.Path, newPath, true, err) case .Err)
				{
					ReportError(err);
					return;
				}
				RemapDocPaths(item.Path, newPath, true);
				// A project's folder (or one holding projects): BeefSpace.toml, BeefProj.toml and .vbproject follow.
				if (!WorkspaceAfterFolderMove(item.Path, newPath))
				{
					String back = scope .();
					if (AssetOps.MovePath(newPath, item.Path, true, back) case .Ok)
						RemapDocPaths(newPath, item.Path, true);
					ScanProject();
					return;
				}
				ScanProject();
				String key = scope .();
				CBItem.MakeKey(.Folder, newPath, "", key);
				CBSelectOnly(key);
				SetStatus(scope $"Renamed folder to {newName}");
			case .File:
				if (newName.EndsWith(".bf", .OrdinalIgnoreCase))
					newName.RemoveFromEnd(3);
				String newPath = scope .();
				JoinPath(parent, scope String()..AppendF("{}.bf", newName), newPath);
				if (newPath == item.Path)
					return;
				if (AssetOps.MovePath(item.Path, newPath, false, err) case .Err)
				{
					ReportError(err);
					return;
				}
				RemapDocPaths(item.Path, newPath, false);
				ScanProject();
				String key = scope .();
				CBItem.MakeKey(.File, newPath, "", key);
				CBSelectOnly(key);
				SetStatus(scope $"Renamed to {newName}.bf");
			default:
				RenameTypeAsset(item, newName);
			}
			SaveSettings();
		}

		/// Top-level types (not nested in another type) of a parsed file.
		static void GetTopLevelTypes(CompilationUnit unit, List<Member> outTypes)
		{
			List<Member> all = scope .();
			unit.CollectTypes(all);
			for (let t in all)
			{
				bool nested = false;
				for (let o in all)
					if (o != t && o.HasSpan && t.HasSpan && t.FirstTok > o.FirstTok && t.LastTok <= o.LastTok)
						nested = true;
				if (!nested)
					outTypes.Add(t);
			}
		}

		static Member FindTypeMember(SourceDocument doc, StringView name)
		{
			if (doc == null || doc.Unit == null)
				return null;
			List<Member> types = scope .();
			GetTopLevelTypes(doc.Unit, types);
			for (let t in types)
				if (t.Name == name)
					return t;
			// Nested types as a fallback.
			types.Clear();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		void RenameTypeAsset(CBItem item, StringView newName)
		{
			String oldName = scope .(item.TypeName);
			String path = scope .(item.Path);
			let doc = LoadDocQuiet(path);
			let type = FindTypeMember(doc, oldName);
			if (type == null || type.NameTok < 0)
			{
				SetStatus(scope $"Could not find {oldName} in {path}");
				return;
			}
			List<Member> top = scope .();
			GetTopLevelTypes(doc.Unit, top);
			bool onlyType = top.Count == 1 && top[0] == type;
			// Every reference in the project is renamed with it (preview first, see
			// docs/Classes-and-Members.md); a file named after its only type follows the type once
			// the rename is applied (Player.bf -> Hero.bf).
			String fileName = scope .();
			Path.GetFileNameWithoutExtension(path, fileName);
			mPendingTypeFile.Set((onlyType && fileName == oldName) ? path : "");
			StartProjectRename(.Type, oldName, newName, oldName, "", path);
		}

		/// After a type rename was applied: moves `path` (named after the old type) to the new
		/// name, and asset tabs follow the type.
		void MoveTypeFileAfterRename(StringView pathIn, StringView oldName, StringView newName)
		{
			String path = scope .(pathIn);
			for (let tab in mAssetTabs)
			{
				if (tab.TypeName == oldName && ProjectIndex.SamePath(tab.FilePath, path))
				{
					tab.TypeName.Set(newName);
					tab.SyncedVersion = -1;
				}
			}
			String finalPath = scope .(path);
			String parent = scope .();
			Path.GetDirectoryPath(path, parent).IgnoreError(); // a root has no parent: parent stays empty
			String newPath = scope .();
			JoinPath(parent, scope String()..AppendF("{}.bf", newName), newPath);
			bool caseOnly = StringView.Compare(newPath, path, true) == 0;
			if (caseOnly || !EntryExists(parent, scope String()..AppendF("{}.bf", newName)))
			{
				String moveErr = scope .();
				if (AssetOps.MovePath(path, newPath, false, moveErr) case .Ok)
				{
					RemapDocPaths(path, newPath, false);
					finalPath.Set(newPath);
					let doc = FindDoc(newPath);
					if (doc != null && File.GetLastWriteTime(newPath) case .Ok(let t))
						doc.DiskTime = t;
				}
				else
					Notify.Log(.Warning, "Rename", scope $"{path} keeps its name: {moveErr}");
			}
			ScanProject();
			String key = scope .();
			CBItem.MakeKey(.Class, finalPath, newName, key);
			CBSelectOnly(key);
		}

		// ------------------------------------------------------------------ delete

		/// Removes every tab of a document and unloads it (no save).
		void CloseDoc(SourceDocument doc)
		{
			for (int i = Tabs.Count - 1; i >= 0; i--)
			{
				let tab = Tabs[i];
				if (tab.Doc != doc)
					continue;
				if (mSelectTab == tab)
					mSelectTab = null;
				if (mLastActiveTab == tab)
					mLastActiveTab = null;
				if (mActionTab == tab)
					mActionTab = null;
				Tabs.RemoveAt(i);
				delete tab;
			}
			if (ActiveTab >= Tabs.Count)
				ActiveTab = Tabs.Count - 1;
			CloseAssetTabs(doc.FilePath, "");
			mDocs.Remove(doc);
			if (mSourceDoc == doc)
				mSourceDoc = null;
			if (mRenameTarget != null)
				mRenameTarget = null;
			if (Doc == doc)
			{
				Doc = (CurrentTab != null) ? CurrentTab.Doc : mEmptyDoc;
				mSourceVersion = -1;
			}
			delete doc;
		}

		void CloseDocsUnder(StringView path, bool isFolder)
		{
			for (int i = mDocs.Count - 1; i >= 0; i--)
			{
				let d = mDocs[i];
				if (ProjectIndex.SamePath(d.FilePath, path) || (isFolder && IsUnder(d.FilePath, path)))
					CloseDoc(d);
			}
			if (isFolder)
			{
				for (int i = mAssetTabs.Count - 1; i >= 0; i--)
				{
					if (IsUnder(mAssetTabs[i].FilePath, path))
						RemoveAssetTab(i);
				}
			}
		}

		static bool UsesTrash
		{
			get
			{
				return true; // the Recycle Bin on Windows, the freedesktop Trash on Linux
			}
		}

		bool DeleteFileAsset(StringView pathIn)
		{
			String path = scope .(pathIn);
			// Recycle Bin / Trash or nothing: if it can't be moved there, the file stays and the editor
			// keeps its open copy.
			String err = scope .();
			if (AssetOps.Delete(path, false, err) case .Err)
			{
				ReportError(err);
				return false;
			}
			let doc = FindDoc(path);
			if (doc != null)
				CloseDoc(doc);
			return true;
		}

		bool DeleteFolderAsset(StringView pathIn)
		{
			String path = scope .(pathIn);
			String err = scope .();
			if (AssetOps.Delete(path, true, err) case .Err)
			{
				ReportError(err);
				return false;
			}
			CloseDocsUnder(path, true);
			WorkspaceAfterFolderDelete(path);
			return true;
		}

		/// True when deleting the type deletes its whole file (it's the file's only top-level type).
		bool TypeOwnsFile(CBItem item)
		{
			let file = Index.FindFile(item.Path);
			if (file == null)
				return false;
			int top = 0;
			bool found = false;
			for (let t in file.Types)
			{
				if (!t.Outer.IsEmpty)
					continue;
				top++;
				if (t.Name == item.TypeName)
					found = true;
			}
			return found && top == 1;
		}

		bool DeleteTypeAsset(CBItem item)
		{
			String path = scope .(item.Path);
			String typeName = scope .(item.TypeName);
			let doc = LoadDocQuiet(path);
			if (doc == null)
				return false;
			let type = FindTypeMember(doc, typeName);
			if (type == null)
				return false;
			List<Member> top = scope .();
			GetTopLevelTypes(doc.Unit, top);
			if (top.Count == 1 && top[0] == type)
				return DeleteFileAsset(path);
			// Only the declaration goes; refuses if the file holds other unsaved edits.
			String err = scope .();
			if (AssetOps.DeleteTypeAndSave(doc, typeName, err) case .Err)
			{
				ReportError(err);
				return false;
			}
			CloseAssetTabs(path, typeName);
			if (File.GetLastWriteTime(path) case .Ok(let wt))
				doc.DiskTime = wt;
			return true;
		}

		void DeleteAssets(List<CBItem> items)
		{
			if (!CheckWritable())
				return;
			int count = 0;
			// Types first (several may share a file), then files, then folders.
			for (let it in items)
			{
				if (!it.IsType || !File.Exists(it.Path))
					continue;
				if (DeleteTypeAsset(it))
					count++;
			}
			for (let it in items)
			{
				if (it.Kind == .File && File.Exists(it.Path) && DeleteFileAsset(it.Path))
					count++;
			}
			for (let it in items)
			{
				if (it.Kind == .Folder && Directory.Exists(it.Path) && DeleteFolderAsset(it.Path))
					count++;
			}
			ScanProject();
			CBSelectOnly("");
			UpdateTitle();
			SaveSettings();
			SetStatus(scope $"Deleted {count} item{(count == 1) ? "" : "s"} (moved to the {FileSafety.TrashName})");
		}

		// ------------------------------------------------------------------ modals

		void DrawProjectBrowserPopups()
		{
			DrawNewAssetPopup();
			DrawNoProjectPopup();
			DrawRenameAssetPopup();
			DrawDeleteAssetsPopup();
			DrawNewProjectPopup();
			DrawWorkspacePopups();
		}

		static void ErrorLine(StringView err)
		{
			if (err.IsEmpty)
				Gui.TextDisabled(" ");
			else
				Gui.TextColored(Gui.Color(255, 110, 100), err);
		}

		void DrawNewAssetPopup()
		{
			if (mOpenCBNew)
			{
				Gui.OpenPopup("Create Asset");
				mOpenCBNew = false;
			}
			if (!Gui.igBeginPopupModal("Create Asset", null, WindowFlags.AlwaysAutoResize))
			{
				mCBModalOpen = false;
				return;
			}
			mCBModalOpen = true;
			if (Gui.IsKeyPressed(Key.Escape, false) || mSelfTestCloseDialog)
			{
				mSelfTestCloseDialog = false;
				Gui.igCloseCurrentPopup();
			}
			// Header: icon + "New Class"
			{
				let p = Gui.igGetCursorScreenPos();
				float s = Gui.igGetFrameHeight() * 1.6f;
				Gui.igDummy(.(s, s));
				AssetStyle.DrawIcon(Gui.igGetWindowDrawList(), mCBNewKind, .(p.x + s / 2, p.y + s / 2), s, AssetStyle.KindColor(mCBNewKind));
				Gui.SameLine();
				Gui.igBeginGroup();
				Gui.Text(scope $"New {AssetStyle.KindLabel(mCBNewKind)}");
				String rel = scope .();
				RelativeToRoot(mCBNewFolder, rel);
				Gui.TextDisabled(scope $"in {rel}");
				Gui.igEndGroup();
			}
			Gui.igSpacing();
			Gui.Text((mCBNewKind == .Folder || mCBNewKind == .File) ? "Name" : "Type name (also the file name)");
			if (Gui.igIsWindowAppearing() || mCBRefocus)
				Gui.igSetKeyboardFocusHere(0);
			mCBRefocus = false;
			Gui.igSetNextItemWidth(380 * Look.Scale);
			bool enter = Gui.igInputText("##assetname", mCBNameBuf.Ptr, (.)mCBNameBuf.Capacity, InputTextFlags.EnterReturnsTrue | InputTextFlags.AutoSelectAll, null, null);
			String name = scope .(mCBNameBuf.View);
			name.Trim();
			String err = scope .();
			String ns = scope .();
			InferNamespaceCached(ns);
			bool valid = ValidateNewAsset(mCBNewKind, mNsTarget, name, ns, err);
			ErrorLine(err);
			if (mCBNewKind != .Folder && mNsPlacement == .Redirected)
			{
				String rel = scope .();
				RelativeToRoot(mNsTarget, rel);
				Gui.TextColored(Theme.Warning, scope $"This folder isn't a source folder; the file goes to {rel}.");
			}
			else if (mCBNewKind != .Folder && mNsPlacement == .NoProject)
				Gui.TextColored(Theme.Warning, "This folder isn't inside a Beef project (no BeefProj.toml): the file would not be compiled.");
			if (valid && mCBNewKind != .Folder)
			{
				String fileName = scope .(name);
				if (!fileName.EndsWith(".bf", .OrdinalIgnoreCase))
					fileName.Append(".bf");
				Gui.TextDisabled(scope $"Creates {fileName}  (namespace {ns})");
			}
			DrawCreateTypeOptions(mCBNewKind);
			Gui.igBeginDisabled(!valid);
			bool create = Gui.Button("Create", .(120 * Look.Scale, 0)) || (enter && valid);
			if (enter && !valid)
				mCBRefocus = true; // keep typing after Enter on a bad name
			Gui.igEndDisabled();
			Gui.SameLine();
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			if (create && valid)
			{
				Gui.igCloseCurrentPopup();
				CreateAsset(mCBNewKind, mCBNewFolder, name);
			}
			Gui.EndPopup();
		}

		String mNsCacheFolder = new .() ~ delete _;
		String mNsCache = new .() ~ delete _;
		/// Where the new file really goes (the project's src folder) and how that was decided.
		String mNsTarget = new .() ~ delete _;
		SourcePlacement mNsPlacement;

		/// The namespace preview in the modal; parsing sibling files every frame would be wasteful.
		void InferNamespaceCached(String outNs)
		{
			if (mNsCacheFolder != mCBNewFolder || mNsCacheFolder.IsEmpty)
			{
				mNsCacheFolder.Set(mCBNewFolder);
				mNsCache.Clear();
				mNsTarget.Clear();
				mNsPlacement = ResolveTarget(mCBNewKind, mCBNewFolder, mNsTarget);
				if (mCBNewKind != .Folder)
					InferNamespace(mNsTarget, mNsCache);
			}
			outNs.Set(mNsCache);
		}

		/// "Not inside a Beef project": a file here would never be compiled.
		void DrawNoProjectPopup()
		{
			if (mOpenCBNoProject)
			{
				Gui.OpenPopup("Not in a Project");
				mOpenCBNoProject = false;
			}
			if (!Gui.igBeginPopupModal("Not in a Project", null, WindowFlags.AlwaysAutoResize))
				return;
			mCBModalOpen = true;
			String rel = scope .();
			RelativeToRoot(mCBPendFolder, rel);
			Gui.Text(scope $"{rel} isn't inside a Beef project (no BeefProj.toml above it).");
			Gui.Text("A file created here would never be compiled.");
			Gui.igSpacing();
			if (Gui.Button("Create a project here...", .(190 * Look.Scale, 0)))
			{
				Gui.igCloseCurrentPopup();
				StartNewProject(mCBPendFolder);
			}
			Gui.SameLine();
			if (Gui.Button("Create file anyway", .(150 * Look.Scale, 0)))
			{
				Gui.igCloseCurrentPopup();
				CreateAsset(mCBPendKind, mCBPendFolder, mCBPendName, true);
			}
			Gui.SameLine();
			if (Gui.Button("Cancel", .(90 * Look.Scale, 0)) || Gui.IsKeyPressed(Key.Escape, false))
				Gui.igCloseCurrentPopup();
			Gui.EndPopup();
		}

		void DrawRenameAssetPopup()
		{
			if (mOpenCBRename)
			{
				Gui.OpenPopup("Rename Asset");
				mOpenCBRename = false;
			}
			if (!Gui.igBeginPopupModal("Rename Asset", null, WindowFlags.AlwaysAutoResize))
				return;
			if (Gui.IsKeyPressed(Key.Escape, false) || mCBRenameItem == null)
			{
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return;
			}
			let item = mCBRenameItem;
			if (mCBRenameProject)
			{
				Gui.TextColored(ProjectColor, scope $"{Icon.Package}  Rename project '{mCBRenameProjectOld}'");
				Gui.TextDisabled("BeefProj.toml, BeefSpace.toml (startup project, Locked / Unlocked) and the");
				Gui.TextDisabled("dependencies of the other projects follow.");
			}
			else
				Gui.Text(scope $"Rename {AssetStyle.KindLabel(item.Kind)} '{item.IsType ? item.TypeName : item.Name}'");
			if (item.IsType)
				Gui.TextDisabled("The declaration is renamed; references in other code are not.");
			if (item.Kind == .Folder && !mCBRenameProject)
				DrawRenameProjectNote(item.Path);
			if (Gui.igIsWindowAppearing() || mCBRefocus)
				Gui.igSetKeyboardFocusHere(0);
			mCBRefocus = false;
			Gui.igSetNextItemWidth(380 * Look.Scale);
			bool enter = Gui.igInputText("##newname", mCBNameBuf.Ptr, (.)mCBNameBuf.Capacity, InputTextFlags.EnterReturnsTrue | InputTextFlags.AutoSelectAll, null, null);
			String name = scope .(mCBNameBuf.View);
			name.Trim();
			String err = scope .();
			if (mCBRenameProject)
				Gui.Checkbox("Rename folder too", &mCBRenameProjectFolder);
			bool valid = mCBRenameProject ? ValidateProjectRename(item.Path, mCBRenameProjectOld, name, mCBRenameProjectFolder, err) : ValidateRename(item, name, err);
			ErrorLine(err);
			Gui.igBeginDisabled(!valid);
			bool go = Gui.Button("Rename", .(120 * Look.Scale, 0)) || (enter && valid);
			if (enter && !valid)
				mCBRefocus = true; // keep typing after Enter on a bad name
			Gui.igEndDisabled();
			Gui.SameLine();
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			if (go && valid)
			{
				Gui.igCloseCurrentPopup();
				let it = mCBRenameItem;
				mCBRenameItem = null;
				if (mCBRenameProject)
				{
					mCBRenameProject = false;
					QueueWsAction(.RenameProject, it.Path, mCBRenameProjectOld, name, mCBRenameProjectFolder);
				}
				else
					RenameAsset(it, name);
				delete it;
			}
			Gui.EndPopup();
		}

		void DrawDeleteAssetsPopup()
		{
			if (mOpenCBDelete)
			{
				Gui.OpenPopup("Delete Assets");
				mOpenCBDelete = false;
			}
			if (!Gui.igBeginPopupModal("Delete Assets", null, WindowFlags.AlwaysAutoResize))
				return;
			if (Gui.IsKeyPressed(Key.Escape, false) || mCBDeleteItems.IsEmpty)
			{
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return;
			}
			Gui.Text(scope $"Delete {mCBDeleteItems.Count} item{(mCBDeleteItems.Count == 1) ? "" : "s"}?");
			Gui.igSpacing();
			for (let it in mCBDeleteItems)
			{
				Gui.TextColored(AssetStyle.KindColor(it.Kind), scope $"  {AssetStyle.KindLabel(it.Kind)}");
				Gui.SameLine(130);
				String rel = scope .();
				RelativeToRoot(it.Path, rel);
				switch (it.Kind)
				{
				case .Folder:
					let dir = FindCBDir(it.Path);
					int files = (dir != null) ? dir.CountFilesRecursive() : 0;
					Gui.Text(scope $"{rel}/  - the folder and everything in it ({files} .bf file{(files == 1) ? "" : "s"})");
					DrawDeleteProjectNote(it.Path);
				case .File:
					Gui.Text(rel);
				default:
					if (TypeOwnsFile(it))
						Gui.Text(scope $"{it.TypeName}  - deletes {rel} (its only type)");
					else
						Gui.Text(scope $"{it.TypeName}  - removes its declaration from {rel}");
				}
				let doc = FindDoc(it.Path);
				if (doc != null && doc.Modified)
				{
					Gui.SameLine();
					Gui.TextColored(Theme.Warning, "(unsaved changes)");
				}
			}
			Gui.igSpacing();
			if (UsesTrash)
				Gui.TextDisabled(scope $"Files and folders go to the {FileSafety.TrashName}.");
			else
				Gui.TextColored(Theme.Warning, "This can't be undone: files and folders are deleted permanently.");
			Gui.igSpacing();
			Gui.igPushStyleColor_U32(Col.Button, Gui.Color(150, 40, 40));
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(185, 55, 55));
			bool go = Gui.Button("Delete", .(120 * Look.Scale, 0));
			Gui.igPopStyleColor(2);
			Gui.SameLine();
			if (Gui.igIsWindowAppearing())
				Gui.igSetKeyboardFocusHere(0);
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			if (go)
			{
				Gui.igCloseCurrentPopup();
				List<CBItem> items = scope .();
				for (let it in mCBDeleteItems)
					items.Add(it);
				mCBDeleteItems.Clear();
				DeleteAssets(items);
				ClearAndDeleteItems!(items);
			}
			Gui.EndPopup();
		}

		// ------------------------------------------------------------------ new project

		/// File > New Project / the start page (no `location`): a project of its own in a folder named after it, which
		/// then becomes the open project. With a `location` (the Project Browser's folder menu): a project added in that
		/// folder of the open one, registered in its workspace, the open project unchanged.
		public void StartNewProject(StringView location = "")
		{
			mNPName.Set("");
			mNPAddHere = !location.IsEmpty;
			if (!location.IsEmpty)
				mNPLocation.Set(location);
			else
				mNPLocation.Set(NewProjectLocation());
			mNPType = 0;
			mNPError.Clear();
			mOpenNewProject = true;
		}

		static StringView[4] sProjectTypes = .("Console Application", "Library", "Windows Application", "From template folder...");
		/// The New Project type that creates the project from a template folder (docs/Host-Integration.md).
		const int32 cTemplateType = 3;
		static StringView[3] sTargetTypes = .("BeefConsoleApplication", "BeefLib", "BeefGUIApplication");

		/// The BeefSpace.toml a project at `location` belongs to (nearest at or above it, not
		/// above the open project root), or empty.
		void FindWorkspaceFor(StringView location, String outWsFile)
		{
			String dir = scope .(location);
			TrimSeparators(dir);
			bool insideRoot = !mProjectRoot.IsEmpty && (ProjectIndex.SamePath(dir, mProjectRoot) || IsUnder(dir, mProjectRoot));
			for (int depth = 0; depth < 24 && !dir.IsEmpty; depth++)
			{
				String probe = scope .();
				JoinPath(dir, "BeefSpace.toml", probe);
				if (File.Exists(probe))
				{
					outWsFile.Set(probe);
					return;
				}
				if (insideRoot && ProjectIndex.SamePath(dir, mProjectRoot))
					return;
				String parent = scope .();
				Path.GetDirectoryPath(dir, parent).IgnoreError(); // a root has no parent: parent is empty and checked below
				if (parent.IsEmpty || parent == dir)
					return;
				dir.Set(parent);
			}
		}

		/// True when the workspace's Projects table already has `name` (`Projects = {...}` or `[Projects]`).
		static bool WorkspaceHasProject(StringView text, StringView name)
		{
			TomlText t = scope .();
			t.Set(text);
			List<(String key, String raw)> entries = scope .();
			defer { for (let e in entries) { delete e.key; delete e.raw; } }
			t.MapEntries("Projects", entries);
			for (let e in entries)
				if (StringView.Compare(e.key, name, true) == 0)
					return true;
			return false;
		}

		/// Lists the project in the workspace (WorkspaceFiles.AddProject: both forms of the Projects table, a
		/// path relative to the workspace folder, atomic). Before 2026-10-12 a workspace written by the Beef IDE
		/// (`[Projects]` table) got a second `Projects = {...}` line, and BeefBuild then skipped the table's projects.
		static Result<void> RegisterProject(StringView wsFile, StringView name, StringView relPath, bool create)
		{
			if (create)
			{
				String entry = scope .();
				String key = scope .();
				TomlKey(name, key);
				entry.AppendF("{} = {{Path = \"{}\"}}", key, relPath);
				String text = scope .();
				text.AppendF("FileVersion = 1\nProjects = {{{}}}\n\n[Workspace]\nStartupProject = \"{}\"\n", entry, name);
				return File.WriteAllText(wsFile, text);
			}
			String wsDir = scope .();
			WorkspaceFiles.ParentDir(wsFile, wsDir);
			String projDir = scope .();
			WorkspaceFiles.Resolve(wsDir, relPath, projDir);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			let result = WorkspaceFiles.AddProject(wsFile, name, projDir, changes, scope String());
			for (let c in changes)
				Notify.Log(.Info, "Project", c);
			return result;
		}

		static void RelativePath(StringView fromDir, StringView toPath, String outRel)
		{
			if (IsUnder(toPath, fromDir))
			{
				var rel = toPath.Substring(fromDir.Length);
				while (rel.StartsWith('/') || rel.StartsWith('\\'))
					rel.RemoveFromStart(1);
				outRel.Append(rel);
			}
			else
				outRel.Append(toPath);
			outRel.Replace('\\', '/');
		}

		/// The project's name and its folder's: the typed name as the file system allows it (ProjectKind.FolderName).
		static void ProjectFolderName(StringView typed, String outFolder)
		{
			var t = typed;
			t.Trim();
			ProjectKind.FolderName(t, outFolder);
		}

		/// The Beef namespace of a project's Program.bf: the letters, digits and `_` of its name ("My Game" -> "MyGame"),
		/// `_` in front of a keyword or an empty result ("App").
		static void ProjectNamespace(StringView name, String outNs)
		{
			String ident = scope .();
			ProjectKind.Identifier(name, ident);
			if (ident.IsEmpty)
				ident.Set("App");
			for (let k in sKeywords)
				if (k == ident)
				{
					ident.Insert(0, '_');
					break;
				}
			outNs.Append(ident);
		}

		/// A BeefSpace.toml key: bare when it only has letters, digits, `_` and `-`, else quoted.
		static void TomlKey(StringView name, String outKey)
		{
			bool bare = !name.IsEmpty;
			for (let c in name.RawChars)
				if (!(c.IsLetterOrDigit || c == '_' || c == '-') || c >= (char8)128)
					bare = false;
			if (bare)
				outKey.Append(name);
			else
				outKey.AppendF("\"{}\"", name);
		}

		/// `name` is what was typed. `addHere`: the project is added to the workspace around `location`; otherwise it is a
		/// project of its own and may live anywhere.
		bool ValidateNewProject(StringView name, StringView location, String outError, bool addHere = true)
		{
			String folder = scope .();
			ProjectFolderName(name, folder);
			if (name.IsEmpty)
			{
				outError.Set("Enter a name.");
				return false;
			}
			if (folder.IsEmpty)
			{
				outError.Set("Give the project a name with letters or digits.");
				return false;
			}
			if (location.IsEmpty)
			{
				outError.Set("Choose a location.");
				return false;
			}
			if (!Directory.Exists(location))
			{
				outError.Set("The location folder doesn't exist.");
				return false;
			}
			if (EntryExists(location, folder))
			{
				outError.Set(scope $"'{folder}' already exists in that folder.");
				return false;
			}
			String ws = scope .();
			if (addHere)
				FindWorkspaceFor(location, ws);
			if (!ws.IsEmpty)
			{
				String text = scope .();
				if (File.ReadAllText(ws, text, true) case .Ok)
				{
					if (WorkspaceHasProject(text, folder))
					{
						outError.Set(scope $"The workspace already has a project named '{folder}'.");
						return false;
					}
				}
			}
			return true;
		}

		/// Writes a new project named after `nameIn` (the folder is the typed name, as the file system allows it; the
		/// project and workspace files use the same name). `addHere`: it goes into `locationIn` and is registered in the
		/// workspace around it, the open project stays. Otherwise it gets a workspace of its own and becomes the open
		/// project (the previous one is closed after the unsaved-changes question).
		void CreateProject(StringView nameIn, int32 type, StringView locationIn, bool addHere = true)
		{
			String typed = scope .(nameIn);
			typed.Trim();
			String location = scope .(locationIn);
			TrimSeparators(location);
			String err = scope .();
			if (!ValidateNewProject(typed, location, err, addHere))
			{
				SetStatus(err);
				return;
			}
			String name = scope .();
			ProjectFolderName(typed, name);
			String ns = scope .();
			ProjectNamespace(name, ns);
			String projDir = scope .();
			JoinPath(location, name, projDir);
			String srcDir = scope .();
			JoinPath(projDir, "src", srcDir);
			if (Directory.CreateDirectory(srcDir) case .Err)
			{
				SetStatus(scope $"Could not create {srcDir}");
				return;
			}
			String toml = scope .();
			toml.Append("FileVersion = 1\n");
			toml.Append("Dependencies = {corlib = \"*\"}\n\n");
			toml.AppendF("[Project]\nName = \"{}\"\n", name);
			toml.AppendF("TargetType = \"{}\"\n", sTargetTypes[Math.Clamp(type, 0, 2)]);
			if (type != 1)
				toml.AppendF("StartupObject = \"{}.Program\"\n", ns);
			String tomlPath = scope .();
			JoinPath(projDir, "BeefProj.toml", tomlPath);
			String program = scope .();
			program.AppendF(
				"""
				using System;

				namespace {0}
				{{
					class Program
					{{
						public static int Main(String[] args)
						{{
							Console.WriteLine("Hello from {1}");
							return 0;
						}}
					}}
				}}

				""", ns, name);
			String programPath = scope .();
			JoinPath(srcDir, "Program.bf", programPath);
			if ((File.WriteAllText(tomlPath, toml) case .Err) || (File.WriteAllText(programPath, program) case .Err))
			{
				SetStatus(scope $"Could not write the project files in {projDir}");
				return;
			}

			if (!addHere)
			{
				// A project of its own: its folder holds its workspace, then it becomes the open project.
				String wsOwn = scope .();
				JoinPath(projDir, "BeefSpace.toml", wsOwn);
				bool wrote = RegisterProject(wsOwn, name, ".", true) case .Ok;
				SaveNewProjectLocation(location);
				RememberProject(projDir);
				FileSafety.ReadOnlyProject = false; // a project of your own is not the viewer-mode one that may have been open
				if (!wrote)
					SetStatus(scope $"Created {name}, but could not write {wsOwn}");
				RequestOpenProject(projDir, programPath);
				if (wrote && mProjectRoot == projDir)
					SetStatus(scope $"Created project {name} in {projDir}");
				return;
			}

			// No project open yet: the location becomes the project root.
			if (mProjectRoot.IsEmpty)
				mProjectRoot.Set(location);

			// Register in the workspace (or make one at the project root).
			String ws = scope .();
			FindWorkspaceFor(location, ws);
			bool created = ws.IsEmpty;
			if (created)
			{
				bool inRoot = ProjectIndex.SamePath(location, mProjectRoot) || IsUnder(location, mProjectRoot);
				JoinPath(inRoot ? mProjectRoot : location, "BeefSpace.toml", ws);
			}
			String wsDir = scope .();
			Path.GetDirectoryPath(ws, wsDir).IgnoreError(); // a root has no parent: parent stays empty
			String rel = scope .();
			RelativePath(wsDir, projDir, rel);
			bool registered = RegisterProject(ws, name, rel, created) case .Ok;

			ScanProject();
			SaveSettings();
			UpdateTitle();
			if (FindCBDir(srcDir) != null)
			{
				mCBFolder.Set(FindCBDir(srcDir).Path);
				mCBReveal = true;
				CBSelectOnly("");
			}
			OpenFunction(programPath, "Program", "Main");
			if (!registered)
				SetStatus(scope $"Created {name}, but could not update {ws}");
			else
				SetStatus(scope $"Created project {name} and {(created ? "created" : "registered it in")} {ws}");
		}

		/// New Project > From template folder...: the Template folder row (a folder chooser), what the
		/// template is, and one row per variable it declares.
		void DrawNewTemplateRows()
		{
			Gui.Text("Template folder");
			Gui.igSetNextItemWidth(370 * Look.Scale);
			Gui.igInputText("##nptemplate", mNPTemplate.Ptr, (.)mNPTemplate.Capacity, 0, null, null);
			Gui.SameLine();
			if (Gui.Button("Browse...##template", .(82 * Look.Scale, 0)))
			{
				char8[4096] buf = default;
				int32 r = Host.vbh_native_dialog(1, scope String(mNPTemplate.View), &buf, 4096);
				if (r == 1)
					mNPTemplate.Set(StringView(&buf));
				else if (r < 0)
					SetStatus("No native folder picker here: type the template folder path");
			}
			ResolveNewTemplate();
			float wrap = 460 * Look.Scale;
			Gui.igPushTextWrapPos(Gui.igGetCursorPosX() + wrap);
			if (mNPTemplateInfo == null)
				Gui.TextDisabled("A folder with a template.json, from the tool or library that provides project templates.");
			else
			{
				Gui.TextDisabled(mNPTemplateInfo.Description.IsEmpty ? scope $"{mNPTemplateInfo.Name}" : scope $"{mNPTemplateInfo.Name}: {mNPTemplateInfo.Description}");
				for (let v in mNPTemplateInfo.Variables)
				{
					if (@v.Index >= mNPVarBufs.Count)
						break;
					Gui.Text(v.Label);
					Gui.igSetNextItemWidth(460 * Look.Scale);
					let buf = mNPVarBufs[@v.Index];
					Gui.igInputText(scope $"##npvar{@v.Index}", buf.Ptr, (.)buf.Capacity, 0, null, null);
				}
			}
			Gui.igPopTextWrapPos();
		}

		/// Loads the Template folder's template.json when the field changed.
		void ResolveNewTemplate()
		{
			if (mNPTemplate.View == mNPTemplateSeen)
				return;
			mNPTemplateSeen.Set(mNPTemplate.View);
			mNPTemplateError.Clear();
			DeleteAndNullify!(mNPTemplateInfo);
			ClearAndDeleteItems!(mNPVarBufs);
			String dir = scope .(mNPTemplateSeen);
			dir.Trim();
			if (dir.IsEmpty)
			{
				mNPTemplateError.Set("Choose a template folder (it holds a template.json).");
				return;
			}
			let t = new TemplateManifest();
			if (!t.Load(dir, mNPTemplateError))
			{
				delete t;
				return;
			}
			mNPTemplateInfo = t;
			// The fields start with the defaults, built-ins (@@Slug@@ ...) resolved for the name typed so far.
			Dictionary<String, String> vars = scope .();
			defer ProjectKind.FreeVariables(vars);
			String err = scope .();
			String name = scope .(mNPName.View);
			if (name.IsEmpty)
				name.Set("NewProject");
			ProjectKind.MakeVariables(t, name, name, null, vars, err);
			for (let v in t.Variables)
			{
				TextBuffer buf = new .(512);
				if (vars.TryGetValue(v.Key, let value))
					buf.Set(value);
				else
					buf.Set(v.Default);
				mNPVarBufs.Add(buf);
			}
		}

		/// File > New Project > From template folder...: writes the project (ProjectKind) into
		/// `<location>\<Identifier(name)>` and opens that folder as the project.
		public bool CreateTemplateProject(StringView nameIn, StringView locationIn)
		{
			ResolveNewTemplate();
			if (mNPTemplateInfo == null)
			{
				SetStatus(mNPTemplateError);
				return false;
			}
			String name = scope .(nameIn);
			name.Trim();
			String location = scope .(locationIn);
			TrimSeparators(location);
			String folder = scope .();
			ProjectFolderName(name, folder);
			String projDir = scope .();
			JoinPath(location, folder, projDir);
			List<(String key, String value)> overrides = scope .();
			defer { for (let o in overrides) { delete o.key; delete o.value; } }
			for (let v in mNPTemplateInfo.Variables)
				if (@v.Index < mNPVarBufs.Count)
					overrides.Add((new String(v.Key), new String(mNPVarBufs[@v.Index].View)));
			List<String> created = scope .();
			defer { ClearAndDeleteItems!(created); }
			String main = scope .();
			String err = scope .();
			if (!ProjectKind.CreateFromTemplate(mNPTemplateInfo.Dir, projDir, name, overrides, .Refuse, created, main, err))
			{
				SetStatus(err);
				return false;
			}
			SaveNewProjectLocation(location);
			RememberProject(projDir);
			FileSafety.ReadOnlyProject = false;
			RequestOpenProject(projDir, (!main.IsEmpty && File.Exists(main)) ? (StringView)main : "", false);
			SetStatus(scope $"Created {name} from the template {mNPTemplateInfo.Name} in {projDir} ({created.Count} files)");
			return true;
		}

		/// "Creates <path>" in grey, the path cut at its start ("...\proj\HelloTool") so a long location
		/// keeps the new folder's name and does not widen the dialog past the window; the whole path is
		/// the tooltip.
		void CreatesLine(StringView path)
		{
			String line = scope $"Creates {path}";
			float maxW = 460 * Look.Scale;
			if (Gui.CalcTextSize(line).x > maxW)
			{
				var tail = path;
				while (tail.Length > 1)
				{
					tail.RemoveFromStart(1);
					line.Set(scope $"Creates ...{tail}");
					if (Gui.CalcTextSize(line).x <= maxW)
						break;
				}
			}
			Gui.TextDisabled(line);
			if (line.Length != path.Length + 8 && Gui.igIsItemHovered(0))
				Gui.Tooltip(path);
		}

		void DrawNewProjectPopup()
		{
			if (mOpenNewProject)
			{
				Gui.OpenPopup("New Beef Project");
				mOpenNewProject = false;
			}
			if (!Gui.igBeginPopupModal("New Beef Project", null, WindowFlags.AlwaysAutoResize))
				return;
			if (Gui.IsKeyPressed(Key.Escape, false) || mSelfTestClosePopups)
			{
				mSelfTestClosePopups = false;
				Gui.igCloseCurrentPopup();
			}
			Gui.Text("Project name");
			if (Gui.igIsWindowAppearing() || mCBRefocus)
				Gui.igSetKeyboardFocusHere(0);
			mCBRefocus = false;
			Gui.igSetNextItemWidth(460 * Look.Scale);
			bool enter = Gui.igInputText("##npname", mNPName.Ptr, (.)mNPName.Capacity, InputTextFlags.EnterReturnsTrue | InputTextFlags.AutoSelectAll, null, null);
			Gui.Text("Type");
			Gui.igSetNextItemWidth(460 * Look.Scale);
			if (Gui.igBeginCombo("##nptype", scope String(sProjectTypes[mNPType]), 0))
			{
				for (int32 i < 4)
					if (Gui.Selectable(sProjectTypes[i], i == mNPType))
						mNPType = i;
				Gui.igEndCombo();
			}
			Gui.Text("Location");
			Gui.igSetNextItemWidth(370 * Look.Scale);
			Gui.igInputText("##nploc", mNPLocation.Ptr, (.)mNPLocation.Capacity, 0, null, null);
			Gui.SameLine();
			if (Gui.Button("Browse...", .(82 * Look.Scale, 0)))
			{
				char8[4096] buf = default;
				int32 r = Host.vbh_native_dialog(1, scope String(mNPLocation.View), &buf, 4096);
				if (r == 1)
					mNPLocation.Set(StringView(&buf));
				else if (r < 0)
					SetStatus("No native folder picker here: type the location path");
			}
			if (mNPType == cTemplateType)
				DrawNewTemplateRows();
			String name = scope .(mNPName.View);
			name.Trim();
			String location = scope .(mNPLocation.View);
			location.Trim();
			TrimSeparators(location);
			String err = scope .();
			// From a template the name is a display name ("Hello Tool"): the folder is made from it.
			bool valid = (mNPType == cTemplateType) ? Directory.Exists(location) : ValidateNewProject(name, location, err, mNPAddHere);
			if (!valid && mNPType == cTemplateType)
				err.Set("The location folder doesn't exist.");
			// Nothing typed yet is a prompt, not an error.
			bool nameEmpty = name.IsEmpty;
			if (nameEmpty)
			{
				valid = false;
				err.Clear();
				Gui.TextDisabled("Type a name: the project's folder is named after it.");
			}
			if (valid && mNPType == cTemplateType)
			{
				String folder = scope .();
				ProjectFolderName(name, folder);
				if (mNPTemplateInfo == null)
				{
					valid = false;
					err.Set(mNPTemplateError.IsEmpty ? "Choose a template folder." : mNPTemplateError);
				}
				else if (folder.IsEmpty)
				{
					valid = false;
					err.Set("Give the project a name with letters or digits.");
				}
				else
				{
					String projDir = scope .();
					JoinPath(location, folder, projDir);
					if (Directory.Exists(projDir))
					{
						valid = false;
						err.Set(scope $"A folder named {folder} already exists there.");
					}
					else
					{
						CreatesLine(projDir);
						String files = scope .();
						for (let f in mNPTemplateInfo.Files)
						{
							if (@f.Index >= 5)
							{
								files.AppendF(" and {} more", mNPTemplateInfo.Files.Count - 5);
								break;
							}
							files.AppendF("{}{}", files.IsEmpty ? "" : ", ", f.To);
						}
						Gui.TextDisabled(scope $"    {files}");
						Gui.TextDisabled("The new folder is opened as the project.");
					}
				}
			}
			else if (valid)
			{
				String ws = scope .();
				if (mNPAddHere)
					FindWorkspaceFor(location, ws);
				String folder = scope .();
				ProjectFolderName(name, folder);
				String projDir = scope .();
				JoinPath(location, folder, projDir);
				CreatesLine(projDir);
				if (!mNPAddHere)
				{
					Gui.TextDisabled("    BeefProj.toml, BeefSpace.toml and src/Program.bf");
					Gui.TextDisabled(mProjectRoot.IsEmpty ? "The new folder is opened as the project." : "The new folder becomes the open project; the current one is closed.");
				}
				else
				{
					Gui.TextDisabled("    BeefProj.toml and src/Program.bf");
					if (ws.IsEmpty)
					{
						String wsAt = scope .();
						JoinPath((mProjectRoot.IsEmpty || !(ProjectIndex.SamePath(location, mProjectRoot) || IsUnder(location, mProjectRoot))) ? location : mProjectRoot, "BeefSpace.toml", wsAt);
						Gui.TextDisabled(scope $"and a new workspace {wsAt}");
					}
					else
						Gui.TextDisabled(scope $"and adds it to {ws}");
					if (mProjectRoot.IsEmpty)
						Gui.TextDisabled("The location is opened as the project folder.");
				}
				if (folder != name)
					Gui.TextDisabled("Characters a folder name cannot have are left out.");
			}
			ErrorLine(err);
			Gui.igBeginDisabled(!valid);
			bool go = Gui.Button("Create Project", .(140 * Look.Scale, 0)) || (enter && valid);
			if (enter && !valid)
				mCBRefocus = true; // keep typing after Enter on a bad name
			Gui.igEndDisabled();
			Gui.SameLine();
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			if (go && valid)
			{
				Gui.igCloseCurrentPopup();
				if (mNPType == cTemplateType)
					CreateTemplateProject(name, location);
				else
					CreateProject(name, mNPType, location, mNPAddHere);
			}
			Gui.EndPopup();
		}
	}
}
