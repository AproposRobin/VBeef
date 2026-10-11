using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;

namespace VisualBeef.Catalog
{
	/// A slice of a SymbolStore's string pool.
	[CRepr]
	struct StrRef
	{
		public int32 Off;
		public int32 Len;

		public bool IsEmpty => Len == 0;
	}

	enum SymMemberKind : uint8
	{
		Method,
		Field,
		Property,
		Ctor
	}

	[CRepr]
	struct TypeRec
	{
		public StrRef Name;
		public StrRef Namespace;
		public StrRef Outer;
		public StrRef Kind;
		public StrRef GenericParams; // "TKey,TValue"
		public StrRef Attributes;
		public StrRef Doc;
		public StrRef BaseTypes;     // "Base;IFoo<int>"
		public StrRef EnumCases;     // "A;B;C"
		public int32 File;
		public int32 Line;
		public int32 FirstMember;
		public int32 MemberCount;
		public SymbolVisibility Visibility;
		/// cAbstract / cSealed / cStatic (was padding before format 4).
		public uint8 TypeFlags;
		public uint16 Pad1;

		public const uint8 cAbstract = 1;
		public const uint8 cSealed = 2;
		public const uint8 cStatic = 4;
	}

	[CRepr]
	struct MemberRec
	{
		public StrRef Name;
		public StrRef Type;          // return type / field type
		public StrRef Attributes;
		public StrRef Doc;
		public StrRef GenericParams;
		public int32 Owner;          // TypeRec index
		public int32 FirstParam;
		public int32 Line;
		public int16 ParamCount;
		public SymMemberKind Kind;
		public SymbolVisibility Visibility;
		public uint8 Flags;
		public uint8 Pad0;
		public uint16 Pad1;

		public const uint8 cStatic = 1;
		public const uint8 cHasBody = 2;
		public const uint8 cWritable = 4;
		public const uint8 cMixin = 8;
		/// Inheritance modifiers (format 4): `virtual`, `abstract` (or an interface member
		/// without a body), `override`, `sealed`.
		public const uint8 cVirtual = 16;
		public const uint8 cAbstract = 32;
		public const uint8 cOverride = 64;
		public const uint8 cSealed = 128;

		public bool IsVirtual => (Flags & cVirtual) != 0;
		public bool IsAbstract => (Flags & cAbstract) != 0;
		public bool IsOverride => (Flags & cOverride) != 0;

		public bool IsStatic => (Flags & cStatic) != 0;
		public bool Writable => (Flags & cWritable) != 0;
		public bool IsMixin => (Flags & cMixin) != 0;
		public bool IsMethod => Kind == .Method || Kind == .Ctor;
	}

	[CRepr]
	struct ParamRec
	{
		public StrRef Name;
		public StrRef Type;
		public StrRef Default;
		public StrRef Modifier;
		public StrRef Attributes;
	}

	[CRepr]
	struct FileRec
	{
		public StrRef Path;
		public StrRef Usings;        // "System;System.Collections"
	}

	/// A compact, allocation-free symbol table: every string lives in one pool and every record
	/// is a plain struct, so a library with 100k members loads from its cache with a few memcpys.
	/// Built from a ProjectIndex (the project, or a parse of a library), or read from disk.
	class SymbolStore
	{
		public const uint32 cMagic = 0x58494256; // "VBIX"
		public const uint32 cVersion = 4;

		/// "Project", "corlib", "ScreechSDK"...
		public String Name = new .() ~ delete _;
		/// Folder the store was built from.
		public String Root = new .() ~ delete _;
		public bool IsLibrary;
		/// Signature of the source files (paths, sizes, modification times) it was built from.
		public uint64 Signature;

		public String Pool = new .() ~ delete _;
		public List<TypeRec> Types = new .() ~ delete _;
		public List<MemberRec> Members = new .() ~ delete _;
		public List<ParamRec> Params = new .() ~ delete _;
		public List<FileRec> Files = new .() ~ delete _;

		/// Type name -> type indices (several: same name in two namespaces, extensions, partials).
		Dictionary<StringView, List<int32>> mTypesByName ~ DeleteDictionaryAndValues!(_);
		/// True when any declaration uses a VisualBeef attribute (the store is "attributed").
		public bool UsesNodeAttributes;

		public StringView Str(StrRef r) => (r.Len == 0) ? "" : StringView(Pool, r.Off, r.Len);

		public StringView TypeName(int t) => Str(Types[t].Name);
		public StringView MemberName(int m) => Str(Members[m].Name);

		// ------------------------------------------------------------------ build

		Dictionary<String, StrRef> mIntern;

		StrRef Intern(StringView s)
		{
			if (s.IsEmpty)
				return default;
			if (mIntern.TryGetAlt(s, var key, var r))
				return r;
			StrRef nr = .() { Off = (int32)Pool.Length, Len = (int32)s.Length };
			Pool.Append(s);
			mIntern[new String(s)] = nr;
			return nr;
		}

		static void Join(List<String> items, char8 sep, String outText)
		{
			for (let s in items)
			{
				if (@s.Index > 0)
					outText.Append(sep);
				outText.Append(s);
			}
		}

		/// Converts an index (everything in it) into a compact store.
		public void BuildFrom(ProjectIndex index)
		{
			Clear();
			Root.Set(index.Root);
			mIntern = new .();
			defer { DeleteDictionaryAndKeys!(mIntern); mIntern = null; }
			String tmp = scope .();
			for (let file in index.Files)
			{
				FileRec fr = default;
				fr.Path = Intern(file.Path);
				tmp.Clear();
				Join(file.Usings, ';', tmp);
				fr.Usings = Intern(tmp);
				int32 fileIdx = (int32)Files.Count;
				Files.Add(fr);
				for (let t in file.Types)
				{
					TypeRec tr = default;
					tr.Name = Intern(t.Name);
					tr.Namespace = Intern(t.Namespace);
					tr.Outer = Intern(t.Outer);
					tr.Kind = Intern(t.Kind);
					tr.GenericParams = Intern(t.GenericParams);
					tr.Attributes = Intern(t.Attributes);
					tr.Doc = Intern(t.Doc);
					tmp.Clear();
					Join(t.BaseTypes, ';', tmp);
					tr.BaseTypes = Intern(tmp);
					tmp.Clear();
					Join(t.EnumCases, ';', tmp);
					tr.EnumCases = Intern(tmp);
					tr.File = fileIdx;
					tr.Line = t.Line;
					tr.Visibility = t.Visibility;
					if (t.IsAbstract) tr.TypeFlags |= TypeRec.cAbstract;
					if (t.IsSealed) tr.TypeFlags |= TypeRec.cSealed;
					if (t.IsStaticType) tr.TypeFlags |= TypeRec.cStatic;
					tr.FirstMember = (int32)Members.Count;
					int32 typeIdx = (int32)Types.Count;
					if (!t.Attributes.IsEmpty)
						NoteAttributes(t.Attributes);
					for (let m in t.Methods)
					{
						MemberRec mr = default;
						mr.Name = Intern(m.Name);
						mr.Type = Intern(m.ReturnType);
						mr.Attributes = Intern(m.Attributes);
						mr.Doc = Intern(m.Doc);
						mr.GenericParams = Intern(m.GenericParams);
						mr.Owner = typeIdx;
						mr.Line = m.Line;
						mr.Kind = m.IsCtor ? .Ctor : .Method;
						mr.Visibility = m.Visibility;
						if (m.IsStatic) mr.Flags |= MemberRec.cStatic;
						if (m.HasBody) mr.Flags |= MemberRec.cHasBody;
						if (m.IsMixin) mr.Flags |= MemberRec.cMixin;
						if (m.IsVirtual) mr.Flags |= MemberRec.cVirtual;
						if (m.IsAbstract) mr.Flags |= MemberRec.cAbstract;
						if (m.IsOverride) mr.Flags |= MemberRec.cOverride;
						if (m.IsSealed) mr.Flags |= MemberRec.cSealed;
						mr.FirstParam = (int32)Params.Count;
						mr.ParamCount = (int16)m.ParamNames.Count;
						for (int i < m.ParamNames.Count)
						{
							ParamRec pr = default;
							pr.Name = Intern(m.ParamNames[i]);
							pr.Type = Intern(m.ParamTypes[i]);
							if (i < m.ParamDefaults.Count) pr.Default = Intern(m.ParamDefaults[i]);
							if (i < m.ParamModifiers.Count) pr.Modifier = Intern(m.ParamModifiers[i]);
							if (i < m.ParamAttributes.Count) pr.Attributes = Intern(m.ParamAttributes[i]);
							Params.Add(pr);
						}
						if (!m.Attributes.IsEmpty)
							NoteAttributes(m.Attributes);
						Members.Add(mr);
					}
					for (let f in t.Fields)
					{
						MemberRec mr = default;
						mr.Name = Intern(f.Name);
						mr.Type = Intern(f.Type);
						mr.Attributes = Intern(f.Attributes);
						mr.Doc = Intern(f.Doc);
						mr.Owner = typeIdx;
						mr.Line = f.Line;
						mr.Kind = f.IsProperty ? .Property : .Field;
						mr.Visibility = f.Visibility;
						if (f.IsStatic) mr.Flags |= MemberRec.cStatic;
						if (f.Writable) mr.Flags |= MemberRec.cWritable;
						if (f.IsVirtual) mr.Flags |= MemberRec.cVirtual;
						if (f.IsAbstract) mr.Flags |= MemberRec.cAbstract;
						if (f.IsOverride) mr.Flags |= MemberRec.cOverride;
						mr.FirstParam = (int32)Params.Count;
						if (!f.Attributes.IsEmpty)
							NoteAttributes(f.Attributes);
						Members.Add(mr);
					}
					tr.MemberCount = (int32)(Members.Count - tr.FirstMember);
					Types.Add(tr);
				}
			}
		}

		void NoteAttributes(StringView attrs)
		{
			if (UsesNodeAttributes)
				return;
			List<AttrInfo> list = scope .();
			defer { ClearAndDeleteItems!(list); }
			AttributeParser.Parse(attrs, list);
			for (let a in list)
				if (AttributeParser.IsNodeAttribute(a.Name))
					UsesNodeAttributes = true;
		}

		public void Clear()
		{
			Pool.Clear();
			Types.Clear();
			Members.Clear();
			Params.Clear();
			Files.Clear();
			UsesNodeAttributes = false;
			if (mTypesByName != null)
			{
				DeleteDictionaryAndValues!(mTypesByName);
				mTypesByName = null;
			}
		}

		// ------------------------------------------------------------------ lookup

		/// Every type declared with this simple name (no namespace, no generic arguments).
		public Span<int32> TypesNamed(StringView name)
		{
			if (mTypesByName == null)
			{
				mTypesByName = new .();
				for (int i < Types.Count)
				{
					let n = Str(Types[i].Name);
					if (!mTypesByName.TryGetValue(n, var list))
					{
						list = new List<int32>();
						mTypesByName[n] = list;
					}
					list.Add((int32)i);
				}
			}
			if (mTypesByName.TryGetValue(name, let found))
				return found;
			return .();
		}

		public void Usings(int file, List<StringView> outUsings)
		{
			if (file < 0 || file >= Files.Count)
				return;
			for (var u in Str(Files[file].Usings).Split(';'))
				if (!u.IsEmpty)
					outUsings.Add(u);
		}

		public void FullTypeName(int t, String outName)
		{
			let ns = Str(Types[t].Namespace);
			if (!ns.IsEmpty)
				outName.AppendF("{}.", ns);
			let outer = Str(Types[t].Outer);
			if (!outer.IsEmpty)
				outName.AppendF("{}.", outer);
			outName.Append(Str(Types[t].Name));
		}

		// ------------------------------------------------------------------ cache I/O

		[CRepr]
		struct Header
		{
			public uint32 Magic;
			public uint32 Version;
			public uint64 Signature;
			public int32 PoolLen;
			public int32 TypeCount;
			public int32 MemberCount;
			public int32 ParamCount;
			public int32 FileCount;
			public int32 Flags;
		}

		static void Put<T>(List<uint8> buf, Span<T> items)
		{
			let bytes = items.Length * strideof(T);
			if (bytes == 0)
				return;
			let dst = buf.GrowUninitialized(bytes);
			Internal.MemCpy(dst, items.Ptr, bytes);
		}

		public Result<void> Save(StringView path)
		{
			List<uint8> buf = scope .();
			Header h = default;
			h.Magic = cMagic;
			h.Version = cVersion;
			h.Signature = Signature;
			h.PoolLen = (int32)Pool.Length;
			h.TypeCount = (int32)Types.Count;
			h.MemberCount = (int32)Members.Count;
			h.ParamCount = (int32)Params.Count;
			h.FileCount = (int32)Files.Count;
			h.Flags = UsesNodeAttributes ? 1 : 0;
			Put(buf, Span<Header>(&h, 1));
			Put(buf, Span<char8>(Pool.Ptr, Pool.Length));
			Put(buf, Span<TypeRec>(Types.Ptr, Types.Count));
			Put(buf, Span<MemberRec>(Members.Ptr, Members.Count));
			Put(buf, Span<ParamRec>(Params.Ptr, Params.Count));
			Put(buf, Span<FileRec>(Files.Ptr, Files.Count));
			// Write to a temp file and move it into place, so a crash never leaves half a cache.
			String tmp = scope .(path);
			tmp.Append(".tmp");
			if (File.WriteAll(tmp, buf) case .Err)
				return .Err;
			if (File.Exists(path))
				File.Delete(path).IgnoreError();
			if (File.Move(tmp, path) case .Err)
				return .Err;
			return .Ok;
		}

		/// Reads a cache file. Fails (and leaves the store empty) when the file is missing, from
		/// another format version, or does not match `expectSignature` (0 = don't check).
		public Result<void> Load(StringView path, uint64 expectSignature)
		{
			Clear();
			List<uint8> buf = scope .();
			if (File.ReadAll(path, buf) case .Err)
				return .Err;
			if (buf.Count < sizeof(Header))
				return .Err;
			Header h = *(Header*)buf.Ptr;
			if (h.Magic != cMagic || h.Version != cVersion)
				return .Err;
			if (expectSignature != 0 && h.Signature != expectSignature)
				return .Err;
			int need = sizeof(Header) + h.PoolLen + h.TypeCount * strideof(TypeRec) + h.MemberCount * strideof(MemberRec) +
				h.ParamCount * strideof(ParamRec) + h.FileCount * strideof(FileRec);
			if (buf.Count != need)
				return .Err;
			uint8* p = buf.Ptr + sizeof(Header);
			Pool.Append((char8*)p, h.PoolLen);
			p += h.PoolLen;
			void Take<T>(List<T> list, int count) where T : struct
			{
				if (count == 0)
					return;
				let dst = list.GrowUninitialized(count);
				Internal.MemCpy(dst, p, count * strideof(T));
				p += count * strideof(T);
			}
			Take(Types, h.TypeCount);
			Take(Members, h.MemberCount);
			Take(Params, h.ParamCount);
			Take(Files, h.FileCount);
			Signature = h.Signature;
			UsesNodeAttributes = (h.Flags & 1) != 0;
			return .Ok;
		}
	}
}
