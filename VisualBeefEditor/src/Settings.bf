using System;
using System.Collections;
using System.IO;

namespace VisualBeef.Editor
{
	/// A minimal JSON value (objects keep their key order) with a reader and a pretty writer;
	/// enough for the settings file.
	class Json
	{
		public enum Kind { Null, Bool, Number, String, Array, Object }

		public Kind Type;
		public bool BoolValue;
		public double Number;
		public String Str ~ delete _;
		public List<Json> Items ~ DeleteContainerAndItems!(_);
		public List<String> Keys ~ DeleteContainerAndItems!(_);

		public static Json NewObject() { let j = new Json(); j.Type = .Object; j.Items = new .(); j.Keys = new .(); return j; }
		public static Json NewArray() { let j = new Json(); j.Type = .Array; j.Items = new .(); return j; }
		public static Json NewString(StringView s) { let j = new Json(); j.Type = .String; j.Str = new .(s); return j; }
		public static Json NewNumber(double v) { let j = new Json(); j.Type = .Number; j.Number = v; return j; }
		public static Json NewBool(bool v) { let j = new Json(); j.Type = .Bool; j.BoolValue = v; return j; }

		public Json Get(StringView key)
		{
			if (Type != .Object)
				return null;
			for (int i < Keys.Count)
				if (Keys[i] == key)
					return Items[i];
			return null;
		}

		/// Sets (replacing) a member of an object; takes ownership of `value`.
		public Json Set(StringView key, Json value)
		{
			for (int i < Keys.Count)
			{
				if (Keys[i] == key)
				{
					delete Items[i];
					Items[i] = value;
					return value;
				}
			}
			Keys.Add(new String(key));
			Items.Add(value);
			return value;
		}

		public void Remove(StringView key)
		{
			for (int i < Keys.Count)
			{
				if (Keys[i] == key)
				{
					delete Keys[i];
					delete Items[i];
					Keys.RemoveAt(i);
					Items.RemoveAt(i);
					return;
				}
			}
		}

		/// The object member `key`, created empty when missing (or not an object).
		public Json Obj(StringView key)
		{
			let j = Get(key);
			if (j != null && j.Type == .Object)
				return j;
			return Set(key, NewObject());
		}

		public StringView GetString(StringView key, StringView def = "")
		{
			let j = Get(key);
			return (j != null && j.Type == .String) ? j.Str : def;
		}

		public double GetNumber(StringView key, double def)
		{
			let j = Get(key);
			return (j != null && j.Type == .Number) ? j.Number : def;
		}

		public bool GetBool(StringView key, bool def)
		{
			let j = Get(key);
			return (j != null && j.Type == .Bool) ? j.BoolValue : def;
		}

		// ------------------------------------------------------------------ reading

		public static Result<Json> Parse(StringView text)
		{
			int i = 0;
			let v = ParseValue(text, ref i);
			if (v == null)
				return .Err;
			SkipWs(text, ref i);
			if (i != text.Length)
			{
				delete v;
				return .Err;
			}
			return .Ok(v);
		}

		static void SkipWs(StringView s, ref int i)
		{
			while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
				i++;
		}

		static Json ParseValue(StringView s, ref int i)
		{
			SkipWs(s, ref i);
			if (i >= s.Length)
				return null;
			char8 c = s[i];
			if (c == '{')
			{
				i++;
				let obj = NewObject();
				SkipWs(s, ref i);
				if (i < s.Length && s[i] == '}')
				{
					i++;
					return obj;
				}
				while (true)
				{
					SkipWs(s, ref i);
					String key = scope .();
					if (i >= s.Length || s[i] != '"' || !ParseString(s, ref i, key))
					{
						delete obj;
						return null;
					}
					SkipWs(s, ref i);
					if (i >= s.Length || s[i] != ':')
					{
						delete obj;
						return null;
					}
					i++;
					let v = ParseValue(s, ref i);
					if (v == null)
					{
						delete obj;
						return null;
					}
					obj.Set(key, v);
					SkipWs(s, ref i);
					if (i < s.Length && s[i] == ',')
					{
						i++;
						continue;
					}
					if (i < s.Length && s[i] == '}')
					{
						i++;
						return obj;
					}
					delete obj;
					return null;
				}
			}
			if (c == '[')
			{
				i++;
				let arr = NewArray();
				SkipWs(s, ref i);
				if (i < s.Length && s[i] == ']')
				{
					i++;
					return arr;
				}
				while (true)
				{
					let v = ParseValue(s, ref i);
					if (v == null)
					{
						delete arr;
						return null;
					}
					arr.Items.Add(v);
					SkipWs(s, ref i);
					if (i < s.Length && s[i] == ',')
					{
						i++;
						continue;
					}
					if (i < s.Length && s[i] == ']')
					{
						i++;
						return arr;
					}
					delete arr;
					return null;
				}
			}
			if (c == '"')
			{
				String str = scope .();
				if (!ParseString(s, ref i, str))
					return null;
				return NewString(str);
			}
			if (s.Substring(i).StartsWith("true"))
			{
				i += 4;
				return NewBool(true);
			}
			if (s.Substring(i).StartsWith("false"))
			{
				i += 5;
				return NewBool(false);
			}
			if (s.Substring(i).StartsWith("null"))
			{
				i += 4;
				return new Json();
			}
			int start = i;
			while (i < s.Length && (s[i].IsDigit || s[i] == '-' || s[i] == '+' || s[i] == '.' || s[i] == 'e' || s[i] == 'E'))
				i++;
			if (i == start)
				return null;
			if (double.Parse(s.Substring(start, i - start)) case .Ok(let d))
				return NewNumber(d);
			return null;
		}

		static bool ParseString(StringView s, ref int i, String outStr)
		{
			i++; // opening quote
			while (i < s.Length)
			{
				char8 c = s[i++];
				if (c == '"')
					return true;
				if (c != '\\')
				{
					outStr.Append(c);
					continue;
				}
				if (i >= s.Length)
					return false;
				char8 e = s[i++];
				switch (e)
				{
				case '"': outStr.Append('"');
				case '\\': outStr.Append('\\');
				case '/': outStr.Append('/');
				case 'b': outStr.Append('\b');
				case 'f': outStr.Append('\f');
				case 'n': outStr.Append('\n');
				case 'r': outStr.Append('\r');
				case 't': outStr.Append('\t');
				case 'u':
					if (i + 4 > s.Length)
						return false;
					if (uint32.Parse(s.Substring(i, 4), .HexNumber) case .Ok(let cp))
						outStr.Append((char32)cp);
					else
						return false;
					i += 4;
				default:
					return false;
				}
			}
			return false;
		}

		// ------------------------------------------------------------------ writing

		public void Write(String outText, int indent = 0)
		{
			switch (Type)
			{
			case .Null: outText.Append("null");
			case .Bool: outText.Append(BoolValue ? "true" : "false");
			case .Number:
				if (Number == Math.Round(Number) && Math.Abs(Number) < 1e15)
					((int64)Number).ToString(outText);
				else
					Number.ToString(outText);
			case .String: WriteString(Str, outText);
			case .Array:
				if (Items.IsEmpty)
				{
					outText.Append("[]");
					return;
				}
				outText.Append("[\n");
				for (let item in Items)
				{
					outText.Append('\t', indent + 1);
					item.Write(outText, indent + 1);
					if (@item.Index < Items.Count - 1)
						outText.Append(',');
					outText.Append('\n');
				}
				outText.Append('\t', indent);
				outText.Append(']');
			case .Object:
				if (Items.IsEmpty)
				{
					outText.Append("{}");
					return;
				}
				outText.Append("{\n");
				for (int k < Keys.Count)
				{
					outText.Append('\t', indent + 1);
					WriteString(Keys[k], outText);
					outText.Append(": ");
					Items[k].Write(outText, indent + 1);
					if (k < Keys.Count - 1)
						outText.Append(',');
					outText.Append('\n');
				}
				outText.Append('\t', indent);
				outText.Append('}');
			}
		}

		public static void WriteString(StringView s, String outText)
		{
			outText.Append('"');
			for (let c in s.RawChars)
			{
				switch (c)
				{
				case '"': outText.Append("\\\"");
				case '\\': outText.Append("\\\\");
				case '\n': outText.Append("\\n");
				case '\r': outText.Append("\\r");
				case '\t': outText.Append("\\t");
				default:
					if ((uint8)c < 0x20)
						outText.AppendF("\\u{:X4}", (int)(uint8)c);
					else
						outText.Append(c);
				}
			}
			outText.Append('"');
		}
	}

	/// Where VisualBeef keeps per-user files. Nothing is written to the working directory or the
	/// project: everything lives under %LOCALAPPDATA%\VisualBeef (~/.local/share/VisualBeef
	/// elsewhere), or under %VB_HOME% when that is set.
	static class AppPaths
	{
		static String sRoot = new .() ~ delete _;

		public static void Root(String outDir)
		{
			if (sRoot.IsEmpty)
			{
				// VB_HOME overrides the whole per-user folder (tests, portable installs).
				String home = scope .();
				if (Environment.GetEnvironmentVariable("VB_HOME", home) case .Ok && !home.IsEmpty)
				{
					while (home.EndsWith('\\') || home.EndsWith('/'))
						home.RemoveFromEnd(1);
					sRoot.Set(home);
					outDir.Append(sRoot);
					return;
				}
				String dir = scope .();
#if BF_PLATFORM_WINDOWS
				if (Environment.GetEnvironmentVariable("LOCALAPPDATA", dir) case .Err || dir.IsEmpty)
					Environment.GetEnvironmentVariable("TEMP", dir).IgnoreError(); // TEMP unset too: dir stays empty, "." below
#else
				Environment.GetEnvironmentVariable("HOME", dir).IgnoreError(); // HOME unset: dir stays empty, "." below
				if (!dir.IsEmpty)
					dir.Append("/.local/share");
#endif
				if (dir.IsEmpty)
					dir.Set(".");
				sRoot.AppendF("{}{}VisualBeef", dir, Path.DirectorySeparatorChar);
			}
			outDir.Append(sRoot);
		}

		/// Root\<sub>, created when missing.
		public static void Sub(StringView sub, String outDir)
		{
			Root(outDir);
			if (!sub.IsEmpty)
				outDir.AppendF("{}{}", Path.DirectorySeparatorChar, sub);
			EnsureDir(outDir);
		}

		public static void EnsureDir(StringView dir)
		{
			if (Directory.Exists(dir))
				return;
			String parent = scope .();
			if (Path.GetDirectoryPath(dir, parent) case .Ok && !parent.IsEmpty && parent != dir)
				EnsureDir(parent);
			Directory.CreateDirectory(dir).IgnoreError(); // best effort: callers check for the files they need
		}

		/// Writes a text file through a temp file + move, so a crash never leaves half a file.
		public static Result<void> WriteAtomic(StringView path, StringView text)
		{
			String tmp = scope .(path);
			tmp.Append(".tmp");
			if (File.WriteAllText(tmp, text) case .Err)
				return .Err;
			if (File.Exists(path) && (File.Delete(path) case .Err))
			{
				File.Delete(tmp).IgnoreError(); // the original stays; drop the temp copy
				return .Err;
			}
			if (File.Move(tmp, path) case .Err)
				return .Err;
			return .Ok;
		}
	}

	/// Per-user settings in %LOCALAPPDATA%\VisualBeef\settings.json: Editor Preferences, the
	/// last session (project, open tabs, Project Browser state), the BeefBuild path and
	/// per-project choices (compile configuration). Everyone reads and writes through `Root`;
	/// `Save()` writes the whole file atomically.
	///
	/// On first start the old files are migrated: %APPDATA%\VisualBeef\EditorPreferences.ini and
	/// VisualBeef_settings.txt in the working directory (which is no longer written).
	static class Settings
	{
		public static Json Root ~ delete _;
		public static bool Migrated;
		public const int32 cVersion = 1;

		public static void GetPath(String outPath)
		{
			AppPaths.Root(outPath);
			outPath.AppendF("{}settings.json", Path.DirectorySeparatorChar);
		}

		public static void Load()
		{
			if (Root != null)
				return;
			String path = scope .();
			GetPath(path);
			String text = scope .();
			if (File.ReadAllText(path, text) case .Ok)
			{
				if (Json.Parse(text) case .Ok(let j))
				{
					if (j.Type == .Object)
					{
						Root = j;
						return;
					}
					delete j;
				}
				// A broken file is kept aside rather than silently overwritten.
				String bad = scope .(path);
				bad.Append(".broken");
				File.Delete(bad).IgnoreError(); // no previous copy: nothing to remove
				File.Move(path, bad).IgnoreError(); // if the move fails the file is overwritten on the next save
			}
			Root = Json.NewObject();
			Root.Set("version", Json.NewNumber(cVersion));
			Migrated = true;
		}

		public static Json Preferences => Root.Obj("preferences");
		public static Json Session => Root.Obj("session");

		static void ProjectKey(StringView root, String outKey)
		{
			outKey.Set(root);
			outKey.Replace('/', '\\');
			while (outKey.EndsWith('\\'))
				outKey.RemoveFromEnd(1);
			outKey.ToLower();
		}

		/// The per-project object (keyed by the project folder, case-insensitive), created
		/// when missing.
		public static Json Project(StringView root)
		{
			String key = scope .();
			ProjectKey(root, key);
			return Root.Obj("projects").Obj(key);
		}

		/// A string value of a project's settings without creating anything ("" when unset).
		public static StringView ProjectValue(StringView root, StringView name)
		{
			let projects = Root.Get("projects");
			if (projects == null)
				return "";
			String key = scope .();
			ProjectKey(root, key);
			let proj = projects.Get(key);
			return (proj != null) ? proj.GetString(name) : "";
		}

		public static void Save()
		{
			if (Root == null)
				return;
			Root.Set("version", Json.NewNumber(cVersion));
			String text = scope .();
			Root.Write(text);
			text.Append('\n');
			String path = scope .();
			GetPath(path);
			String dir = scope .();
			AppPaths.Root(dir);
			AppPaths.EnsureDir(dir);
			if (AppPaths.WriteAtomic(path, text) case .Err)
				Notify.Log(.Warning, "Editor", scope $"Could not save settings to {path}");
		}
	}
}
