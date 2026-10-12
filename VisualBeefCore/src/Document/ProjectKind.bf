using System;
using System.IO;
using System.Collections;
using VisualBeef.Update;

namespace VisualBeef.Document
{
	/// A project's `.vbproject` manifest (docs/Host-Integration.md > Project manifest): a small JSON file beside
	/// BeefSpace.toml that says "this project was made from a template, edit it in VisualBeef" and how. Every key is
	/// optional; keys VisualBeef does not know are left alone (a host may keep its own ids in the file).
	class ProjectManifest
	{
		public const String FileName = ".vbproject";

		/// The file exists and parsed.
		public bool Present;
		/// Free text the host chooses ("template" when VisualBeef wrote the file).
		public String Kind = new .() ~ delete _;
		/// The template's name, as its template.json gives it.
		public String Template = new .() ~ delete _;
		/// The host tool's display name, used in messages ("Start it from <host>").
		public String Host = new .() ~ delete _;
		/// The file to focus, project-relative with `/` ("" = none). Never rooted, never `..`.
		public String Main = new .() ~ delete _;
		/// "Debug" / "Release": the default compile configuration ("" = the editor's own default).
		public String Configuration = new .() ~ delete _;
		/// Debug > Attach to Process lists the processes that have this module loaded ("" = the project's own output).
		public String AttachModule = new .() ~ delete _;
		/// One sentence for the attach dialog when no process has the module loaded.
		public String AttachHint = new .() ~ delete _;
		/// Node libraries the project uses (absolute, or relative to the project folder), loaded even when the
		/// workspace does not list them.
		public List<String> Libraries = new .() ~ DeleteContainerAndItems!(_);

		public void Clear()
		{
			Present = false;
			Kind.Clear();
			Template.Clear();
			Host.Clear();
			Main.Clear();
			Configuration.Clear();
			AttachModule.Clear();
			AttachHint.Clear();
			ClearAndDeleteItems!(Libraries);
		}

		/// A project-relative path that stays inside the project: not rooted, no `..`, no drive.
		public static bool IsSafeRelative(StringView path)
		{
			if (path.IsEmpty || path.Contains("..") || path.Contains(':') || path.StartsWith('\\') || path.StartsWith('/'))
				return false;
			return true;
		}

		/// Parses the manifest text. False (with a reason) when it is not a JSON object.
		public bool Parse(StringView textIn, String outError)
		{
			Clear();
			var text = textIn;
			if (text.StartsWith("\xEF\xBB\xBF"))
				text.RemoveFromStart(3);
			let parsed = UpdateJson.Parse(text);
			if (parsed case .Err)
			{
				outError.Set("The .vbproject file is not valid JSON.");
				return false;
			}
			let root = parsed.Get();
			defer delete root;
			if (!root.IsObject)
			{
				outError.Set("The .vbproject file is not a JSON object.");
				return false;
			}
			Present = true;
			root.GetString("kind", Kind);
			root.GetString("template", Template);
			root.GetString("host", Host);
			root.GetString("configuration", Configuration);
			String main = scope .();
			if (root.GetString("main", main))
			{
				main.Replace('\\', '/');
				if (IsSafeRelative(main))
					Main.Set(main);
			}
			let attach = root.Get("attach");
			if (attach != null && attach.IsObject)
			{
				attach.GetString("module", AttachModule);
				attach.GetString("hint", AttachHint);
			}
			let libs = root.Get("libraries");
			if (libs != null && libs.IsArray)
				for (let l in libs.Items)
					if (l.Type == .String && !l.Text.IsEmpty)
						Libraries.Add(new String(l.Text));
			return true;
		}

		/// Reads `<root>/.vbproject`. False when there is none or it does not parse (`outError` says which).
		public bool Read(StringView root, String outError = null)
		{
			Clear();
			String path = scope .();
			Join(root, FileName, path);
			String text = scope .();
			if (File.ReadAllText(path, text) case .Err)
			{
				outError?.Set("There is no .vbproject file.");
				return false;
			}
			String err = scope .();
			if (!Parse(text, err))
			{
				outError?.Set(err);
				return false;
			}
			return true;
		}

		/// The manifest as VisualBeef writes it (keys it has no value for are left out).
		public void Write(String outText)
		{
			outText.Append("{\n  \"vbproject\": 1");
			void Key(StringView key, StringView value)
			{
				if (value.IsEmpty)
					return;
				outText.AppendF(",\n  \"{}\": ", key);
				UpdateJson.WriteString(value, outText);
			}
			Key("kind", Kind);
			Key("template", Template);
			Key("host", Host);
			Key("main", Main);
			Key("configuration", Configuration);
			if (!AttachModule.IsEmpty || !AttachHint.IsEmpty)
			{
				outText.Append(",\n  \"attach\": {");
				bool first = true;
				if (!AttachModule.IsEmpty)
				{
					outText.Append("\"module\": ");
					UpdateJson.WriteString(AttachModule, outText);
					first = false;
				}
				if (!AttachHint.IsEmpty)
				{
					if (!first)
						outText.Append(", ");
					outText.Append("\"hint\": ");
					UpdateJson.WriteString(AttachHint, outText);
				}
				outText.Append('}');
			}
			if (!Libraries.IsEmpty)
			{
				outText.Append(",\n  \"libraries\": [");
				for (let l in Libraries)
				{
					if (@l.Index > 0)
						outText.Append(", ");
					UpdateJson.WriteString(l, outText);
				}
				outText.Append(']');
			}
			outText.Append("\n}\n");
		}

		/// `main` of `<root>/.vbproject` with the platform's separators; false when there is none.
		public static bool ReadMain(StringView root, String outRelative)
		{
			ProjectManifest m = scope .();
			if (!m.Read(root) || m.Main.IsEmpty)
				return false;
			outRelative.Set(m.Main);
#if BF_PLATFORM_WINDOWS
			outRelative.Replace('/', '\\');
#endif
			return true;
		}

		/// Library folders the manifest names, made absolute against `root`.
		public void LibraryDirs(StringView root, List<String> outDirs)
		{
			for (let l in Libraries)
			{
				String dir = new .();
				if (Path.IsPathRooted(l))
					dir.Set(l);
				else
				{
					Path.GetAbsolutePath(l, root, dir);
					if (dir.IsEmpty)
						Join(root, l, dir);
				}
#if BF_PLATFORM_WINDOWS
				dir.Replace('/', '\\');
#endif
				outDirs.Add(dir);
			}
		}

		public static void Join(StringView a, StringView b, String outPath)
		{
			outPath.Append(a);
			if (!outPath.IsEmpty && !outPath.EndsWith('\\') && !outPath.EndsWith('/'))
				outPath.Append(Path.DirectorySeparatorChar);
			outPath.Append(b);
		}
	}

	/// A variable a template declares: `@@Key@@` in its files, asked for in File > New Project.
	class TemplateVariable
	{
		public String Key = new .() ~ delete _;
		public String Label = new .() ~ delete _;
		/// May use the built-in variables (`@@Slug@@`).
		public String Default = new .() ~ delete _;
	}

	/// One file a template copies: `From` in the template folder, `To` in the new project (both may use `@@Key@@`).
	class TemplateFile
	{
		public String From = new .() ~ delete _;
		public String To = new .() ~ delete _;
		/// Copied byte for byte, without substitutions (pictures, fonts).
		public bool Raw;
	}

	/// A library a template's projects reference: `@@Lib.<Name>@@` is its absolute folder (with `/`).
	class TemplateLibrary
	{
		public String Name = new .() ~ delete _;
		/// As written: absolute, or relative to the template folder.
		public String Path = new .() ~ delete _;
		/// Resolved absolute folder, with `/`.
		public String FullPath = new .() ~ delete _;
	}

	/// A template folder's `template.json` (docs/Host-Integration.md > Template manifest).
	class TemplateManifest
	{
		public const String FileName = "template.json";

		public String Dir = new .() ~ delete _;
		public String Name = new .() ~ delete _;
		public String Description = new .() ~ delete _;
		public String Host = new .() ~ delete _;
		public String Main = new .() ~ delete _;
		public String Configuration = new .() ~ delete _;
		public String AttachModule = new .() ~ delete _;
		public String AttachHint = new .() ~ delete _;
		public List<TemplateVariable> Variables = new .() ~ DeleteContainerAndItems!(_);
		public List<TemplateFile> Files = new .() ~ DeleteContainerAndItems!(_);
		public List<TemplateLibrary> Libraries = new .() ~ DeleteContainerAndItems!(_);

		/// The template writes its own `.vbproject` (then VisualBeef does not write one).
		public bool WritesManifest
		{
			get
			{
				for (let f in Files)
					if (f.To == ProjectManifest.FileName)
						return true;
				return false;
			}
		}

		public static bool IsTemplateFolder(StringView dir)
		{
			String path = scope .();
			ProjectManifest.Join(dir, FileName, path);
			return File.Exists(path);
		}

		/// Reads `<dir>/template.json`. False with a reason a person can act on.
		public bool Load(StringView dirIn, String outError)
		{
			String dir = scope .(dirIn);
			dir.Trim();
			while (dir.Length > 3 && (dir.EndsWith('\\') || dir.EndsWith('/')))
				dir.RemoveFromEnd(1);
			Dir.Set(dir);
			String path = scope .();
			ProjectManifest.Join(dir, FileName, path);
			String text = scope .();
			if (dir.IsEmpty || File.ReadAllText(path, text) case .Err)
			{
				outError.Set(scope $"'{dirIn}' is not a template folder: it has no {FileName}.");
				return false;
			}
			StringView body = text;
			if (body.StartsWith("\xEF\xBB\xBF"))
				body.RemoveFromStart(3);
			let parsed = UpdateJson.Parse(body);
			if (parsed case .Err)
			{
				outError.Set(scope $"{path} is not valid JSON.");
				return false;
			}
			let root = parsed.Get();
			defer delete root;
			if (!root.IsObject)
			{
				outError.Set(scope $"{path} is not a JSON object.");
				return false;
			}
			if (root.GetInt("template", let version) && version > 1)
			{
				outError.Set(scope $"{path} is template format {version}; this VisualBeef reads format 1. Update VisualBeef.");
				return false;
			}
			root.GetString("name", Name);
			root.GetString("description", Description);
			root.GetString("host", Host);
			root.GetString("main", Main);
			Main.Replace('\\', '/');
			root.GetString("configuration", Configuration);
			let attach = root.Get("attach");
			if (attach != null && attach.IsObject)
			{
				attach.GetString("module", AttachModule);
				attach.GetString("hint", AttachHint);
			}
			if (Name.IsEmpty)
				System.IO.Path.GetFileName(dir, Name);

			let vars = root.Get("variables");
			if (vars != null && vars.IsArray)
				for (let v in vars.Items)
				{
					if (!v.IsObject)
						continue;
					TemplateVariable tv = new .();
					Variables.Add(tv);
					v.GetString("key", tv.Key);
					v.GetString("label", tv.Label);
					v.GetString("default", tv.Default);
					if (tv.Key.IsEmpty || !IsKey(tv.Key))
					{
						outError.Set(scope $"{path}: a variable key must be letters, digits, '_' or '.' ('{tv.Key}').");
						return false;
					}
					if (tv.Label.IsEmpty)
						tv.Label.Set(tv.Key);
				}

			let files = root.Get("files");
			if (files == null || !files.IsArray || files.Items.IsEmpty)
			{
				outError.Set(scope $"{path} lists no files.");
				return false;
			}
			for (let f in files.Items)
			{
				TemplateFile tf = new .();
				Files.Add(tf);
				if (f.Type == .String)
				{
					tf.From.Set(f.Text);
					tf.To.Set(f.Text);
				}
				else if (f.IsObject)
				{
					f.GetString("from", tf.From);
					if (!f.GetString("to", tf.To))
						tf.To.Set(tf.From);
					tf.Raw = f.GetBool("raw", false);
				}
				tf.From.Replace('\\', '/');
				tf.To.Replace('\\', '/');
				if (!ProjectManifest.IsSafeRelative(tf.From) || !ProjectManifest.IsSafeRelative(tf.To))
				{
					outError.Set(scope $"{path}: file paths must stay inside the folders ('{tf.From}' -> '{tf.To}').");
					return false;
				}
				String src = scope .();
				ProjectManifest.Join(dir, tf.From, src);
				if (!File.Exists(src))
				{
					outError.Set(scope $"{path} lists '{tf.From}', which is not in the template folder.");
					return false;
				}
			}

			let libs = root.Get("libraries");
			if (libs != null && libs.IsArray)
				for (let l in libs.Items)
				{
					if (!l.IsObject)
						continue;
					TemplateLibrary tl = new .();
					Libraries.Add(tl);
					l.GetString("name", tl.Name);
					l.GetString("path", tl.Path);
					if (tl.Name.IsEmpty || !IsKey(tl.Name) || tl.Path.IsEmpty)
					{
						outError.Set(scope $"{path}: every library needs a name (letters, digits, '_') and a path.");
						return false;
					}
					if (System.IO.Path.IsPathRooted(tl.Path))
						tl.FullPath.Set(tl.Path);
					else
					{
						System.IO.Path.GetAbsolutePath(tl.Path, dir, tl.FullPath);
						if (tl.FullPath.IsEmpty)
							ProjectManifest.Join(dir, tl.Path, tl.FullPath);
					}
					tl.FullPath.Replace('\\', '/');
					if (!Directory.Exists(tl.FullPath))
					{
						outError.Set(scope $"{path}: the library {tl.Name} is not at {tl.FullPath}.");
						return false;
					}
				}
			return true;
		}

		static bool IsKey(StringView s)
		{
			for (let c in s.RawChars)
				if (!(c.IsLetterOrDigit || c == '_' || c == '.') || c >= (char8)128)
					return false;
			return true;
		}
	}

	/// Projects made from a template folder (`--new-from-template`, File > New Project > From template folder...):
	/// the variables, the `@@Key@@` substitutions and the files written (docs/Host-Integration.md).
	static class ProjectKind
	{
		/// What to do with a file that already exists in the destination.
		public enum Existing
		{
			/// Nothing is written when any file exists.
			Refuse,
			/// Existing files are kept; the others are written.
			Skip
		}

		/// The ASCII letters, digits and `_` of a name, `_` in front when it starts with a digit: a Beef identifier
		/// and a folder name. "Hello Tool!" -> "HelloTool", "3D Kit" -> "_3DKit".
		public static void Identifier(StringView name, String outText)
		{
			for (let c in name.RawChars)
				if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')
					outText.Append(c);
			if (!outText.IsEmpty && outText[0].IsDigit)
				outText.Insert(0, '_');
		}

		/// Lower case, every run of other characters one `-`. "Hello Tool!" -> "hello-tool".
		public static void Slug(StringView name, String outText)
		{
			bool dash = false;
			for (let c in name.RawChars)
			{
				if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z'))
				{
					if (dash && !outText.IsEmpty)
						outText.Append('-');
					dash = false;
					outText.Append(c.ToLower);
				}
				else
					dash = true;
			}
		}

		static void SetVar(Dictionary<String, String> vars, StringView key, StringView value)
		{
			String k = scope .(key);
			if (vars.TryGetValue(k, let existing))
				existing.Set(value);
			else
				vars[new String(key)] = new String(value);
		}

		/// Frees the keys and values `MakeVariables` added.
		public static void FreeVariables(Dictionary<String, String> vars)
		{
			for (let kv in vars)
			{
				delete kv.key;
				delete kv.value;
			}
			vars.Clear();
		}

		/// The variables of a new project: the built-ins (`Name`, `Identifier`, `Slug`, `Folder`, `Lib.<Name>`), the
		/// template's own with their defaults, then `overrides` (`--var KEY=VALUE`, the dialog's fields). The caller
		/// frees them with `FreeVariables`.
		public static bool MakeVariables(TemplateManifest t, StringView destination, StringView nameIn, List<(String key, String value)> overrides,
			Dictionary<String, String> outVars, String outError)
		{
			String dest = scope .(destination);
			while (dest.Length > 3 && (dest.EndsWith('\\') || dest.EndsWith('/')))
				dest.RemoveFromEnd(1);
			String folder = scope .();
			Path.GetFileName(dest, folder);
			String name = scope .(nameIn);
			name.Trim();
			if (name.IsEmpty)
				name.Set(folder);
			String ident = scope .();
			Identifier(name, ident);
			if (ident.IsEmpty)
			{
				outError.Set(scope $"'{name}' has no letters or digits to make a name from.");
				return false;
			}
			String slug = scope .();
			Slug(name, slug);
			SetVar(outVars, "Name", name);
			SetVar(outVars, "Identifier", ident);
			SetVar(outVars, "Slug", slug);
			SetVar(outVars, "Folder", folder);
			for (let lib in t.Libraries)
				SetVar(outVars, scope $"Lib.{lib.Name}", lib.FullPath);
			for (let v in t.Variables)
			{
				String value = scope .();
				if (Substitute(v.Default, outVars, value, outError) case .Err)
					return false;
				SetVar(outVars, v.Key, value);
			}
			if (overrides != null)
				for (let o in overrides)
					SetVar(outVars, o.key, o.value);
			return true;
		}

		/// Replaces every `@@Key@@` (and `@@Key:str@@`: the value escaped for a quoted string, `\` and `"` get a
		/// backslash, as JSON, TOML and Beef strings want). An unknown key is an error; `@@` that does not enclose a
		/// key (letters, digits, `_`, `.`) is ordinary text.
		public static Result<void> Substitute(StringView text, Dictionary<String, String> vars, String outText, String outError)
		{
			int i = 0;
			while (i < text.Length)
			{
				int at = text.IndexOf("@@", i);
				int end = (at < 0) ? -1 : text.IndexOf("@@", at + 2);
				if (at < 0 || end < 0)
				{
					outText.Append(text.Substring(i));
					break;
				}
				var key = StringView(text, at + 2, end - at - 2);
				bool escape = false;
				if (key.EndsWith(":str"))
				{
					key.RemoveFromEnd(4);
					escape = true;
				}
				bool plausible = !key.IsEmpty;
				for (let c in key.RawChars)
					if (!(c.IsLetterOrDigit || c == '_' || c == '.'))
						plausible = false;
				if (!plausible)
				{
					outText.Append(StringView(text, i, at + 2 - i));
					i = at + 2;
					continue;
				}
				String k = scope .(key);
				if (!vars.TryGetValue(k, let value))
				{
					outError.Set(scope $"The template uses @@{key}@@, which is not defined.");
					return .Err;
				}
				outText.Append(StringView(text, i, at - i));
				if (escape)
				{
					for (let c in value.RawChars)
					{
						if (c == '"' || c == '\\')
							outText.Append('\\');
						outText.Append(c);
					}
				}
				else
					outText.Append(value);
				i = end + 2;
			}
			return .Ok;
		}

		/// Writes the template's files into `destination` (created when missing), then `.vbproject` unless the
		/// template writes its own. `outCreated` lists the files written. With `.Refuse` nothing is written when any
		/// file already exists; with `.Skip` existing files are kept.
		public static bool Create(TemplateManifest t, StringView destination, Dictionary<String, String> vars, Existing existing,
			List<String> outCreated, String outError)
		{
			List<(String path, String text, bool raw, String src)> plan = scope .();
			defer { for (let p in plan) { delete p.path; delete p.text; delete p.src; } }
			for (let f in t.Files)
			{
				String to = scope .();
				if (Substitute(f.To, vars, to, outError) case .Err)
					return false;
				if (!ProjectManifest.IsSafeRelative(to))
				{
					outError.Set(scope $"The file name '{to}' would leave the project folder.");
					return false;
				}
				String full = new .();
				ProjectManifest.Join(destination, to, full);
#if BF_PLATFORM_WINDOWS
				full.Replace('/', '\\');
#endif
				String src = new .();
				ProjectManifest.Join(t.Dir, f.From, src);
				String text = new .();
				plan.Add((full, text, f.Raw, src));
				if (!f.Raw)
				{
					String raw = scope .();
					if (File.ReadAllText(src, raw, true) case .Err)
					{
						outError.Set(scope $"Could not read {src}.");
						return false;
					}
					if (Substitute(raw, vars, text, outError) case .Err)
					{
						outError.Append(scope $" ({f.From})");
						return false;
					}
				}
			}
			String manifestPath = scope .();
			ProjectManifest.Join(destination, ProjectManifest.FileName, manifestPath);
			String manifestText = scope .();
			bool writeManifest = !t.WritesManifest;
			if (writeManifest)
			{
				ProjectManifest m = scope .();
				m.Kind.Set("template");
				m.Template.Set(t.Name);
				m.Host.Set(t.Host);
				if (Substitute(t.Main, vars, m.Main, outError) case .Err)
					return false;
				m.Configuration.Set(t.Configuration);
				m.AttachModule.Set(t.AttachModule);
				m.AttachHint.Set(t.AttachHint);
				for (let lib in t.Libraries)
					m.Libraries.Add(new String(lib.FullPath));
				m.Write(manifestText);
			}

			if (existing == .Refuse)
			{
				for (let p in plan)
					if (File.Exists(p.path))
					{
						outError.Set(scope $"{p.path} already exists; nothing was written.");
						return false;
					}
			}

			for (let p in plan)
			{
				if (File.Exists(p.path))
					continue; // .Skip keeps it
				String dir = scope .();
				Path.GetDirectoryPath(p.path, dir).IgnoreError(); // a joined path always has a folder part
				if (!dir.IsEmpty && !Directory.Exists(dir) && Directory.CreateDirectory(dir) case .Err)
				{
					outError.Set(scope $"Could not create the folder {dir}.");
					return false;
				}
				if (p.raw)
				{
					if (File.Copy(p.src, p.path) case .Err)
					{
						outError.Set(scope $"Could not copy {p.src} to {p.path}.");
						return false;
					}
				}
				else if (File.WriteAllText(p.path, p.text) case .Err)
				{
					outError.Set(scope $"Could not write {p.path}.");
					return false;
				}
				outCreated.Add(new String(p.path));
			}
			if (writeManifest && !File.Exists(manifestPath))
			{
				if (!Directory.Exists(destination) && Directory.CreateDirectory(destination) case .Err)
				{
					outError.Set(scope $"Could not create the folder {destination}.");
					return false;
				}
				if (File.WriteAllText(manifestPath, manifestText) case .Err)
				{
					outError.Set(scope $"Could not write {manifestPath}.");
					return false;
				}
				outCreated.Add(new String(manifestPath));
			}
			return true;
		}

		/// The file a new project from `t` focuses (absolute; "" when the template names none).
		public static void MainFile(TemplateManifest t, StringView destination, Dictionary<String, String> vars, String outPath)
		{
			String rel = scope .();
			String err = scope .();
			if (t.Main.IsEmpty || Substitute(t.Main, vars, rel, err) case .Err || !ProjectManifest.IsSafeRelative(rel))
				return;
			ProjectManifest.Join(destination, rel, outPath);
#if BF_PLATFORM_WINDOWS
			outPath.Replace('/', '\\');
#endif
		}

		/// Writes a new project from `templateDir` into `destination`: load, variables, files. The one entry point of
		/// `--new-from-template` and File > New Project > From template folder... `outMain` is the file to focus.
		public static bool CreateFromTemplate(StringView templateDir, StringView destination, StringView name, List<(String key, String value)> overrides,
			Existing existing, List<String> outCreated, String outMain, String outError)
		{
			TemplateManifest t = scope .();
			if (!t.Load(templateDir, outError))
				return false;
			Dictionary<String, String> vars = scope .();
			defer FreeVariables(vars);
			if (!MakeVariables(t, destination, name, overrides, vars, outError))
				return false;
			if (!Create(t, destination, vars, existing, outCreated, outError))
				return false;
			MainFile(t, destination, vars, outMain);
			return true;
		}
	}
}
