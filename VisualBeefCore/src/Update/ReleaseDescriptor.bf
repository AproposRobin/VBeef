// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).
// The trust rules follow UniversalUMP's launcher updater (src/Update/ReleaseTrust.bf, same owner, same licence).

using System;
using System.Collections;

namespace VisualBeef.Update
{
	/// One downloadable file of a release.
	public class ReleaseAsset
	{
		/// `win64`, `win64-minimal`, `linux-x86_64-appimage`, `linux-x86_64` (tarball) ...
		public String Platform = new .() ~ delete _;
		/// The file name on the release (the asset name on GitHub).
		public String Name = new .() ~ delete _;
		public int64 Size;
		/// Lower-case hex SHA-256 of the file.
		public String Sha256 = new .() ~ delete _;
	}

	/// The signed release descriptor, `release.json` (docs/Releasing.md):
	///
	///     { "format": 1, "product": "VisualBeef", "version": "0.2.0-alpha", "channel": "stable", "sequence": 4,
	///       "tag": "v0.2.0", "publishedAt": "2026-10-12T10:00:00Z",
	///       "assets": [ { "platform": "win64", "name": "VisualBeef-0.2.0-win64.zip", "size": 123, "sha256": "..." }, ... ],
	///       "notes": "...", "signature": "<base64 Ed25519 over CanonicalText>" }
	///
	/// Everything that decides what is installed is signed (CanonicalText); `notes` is not, and is only shown as plain
	/// text. The download address is never read from the file: it is built from the configured repository, the signed
	/// tag and the signed asset name.
	public class ReleaseDescriptor
	{
		/// First line of the signed text, also the signing domain (a signature over anything else never matches).
		public const StringView Domain = "visualbeef-release-v1";
		public const StringView ProductName = "VisualBeef";
		public const int MaxBytes = 64 * 1024;

		public int64 Format;
		public String Product = new .() ~ delete _;
		public String Version = new .() ~ delete _;
		public String Channel = new .() ~ delete _;
		public int64 Sequence;
		public String Tag = new .() ~ delete _;
		public String PublishedAt = new .() ~ delete _;
		public List<ReleaseAsset> Assets = new .() ~ DeleteContainerAndItems!(_);
		public String Notes = new .() ~ delete _;
		public String Signature = new .() ~ delete _;

		/// A tag, version or file name: [A-Za-z0-9._+-], 1..128 characters, not "." or "..".
		public static bool IsSafeSegment(StringView text)
		{
			if (text.IsEmpty || text.Length > 128 || text == "." || text == "..")
				return false;
			for (let c in text.RawChars)
			{
				if (!(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '.' && c != '_' && c != '-' && c != '+')
					return false;
			}
			return true;
		}

		public static bool IsSha256Hex(StringView text)
		{
			if (text.Length != 64)
				return false;
			for (let c in text.RawChars)
				if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f'))
					return false;
			return true;
		}

		static bool IsSingleLine(StringView text)
		{
			for (let c in text.RawChars)
				if (c == '\n' || c == '\r' || c == '\0')
					return false;
			return true;
		}

		/// Parses and checks the shape of a descriptor (not its signature: see Verify). `outReason` says what is wrong.
		public static Result<ReleaseDescriptor> Parse(StringView text, String outReason)
		{
			if (text.Length > MaxBytes)
			{
				outReason.Set("the release description is too large");
				return .Err;
			}
			UpdateJson root;
			switch (UpdateJson.Parse(text))
			{
			case .Ok(let v): root = v;
			case .Err:
				outReason.Set("the release description is not valid JSON");
				return .Err;
			}
			defer delete root;
			if (!root.IsObject)
			{
				outReason.Set("the release description is not a JSON object");
				return .Err;
			}
			let d = new ReleaseDescriptor();
			if (!d.ReadFrom(root, outReason))
			{
				delete d;
				return .Err;
			}
			return d;
		}

		bool ReadFrom(UpdateJson root, String outReason)
		{
			if (!root.GetInt("format", out Format) || Format != 1)
			{
				outReason.Set("the release description has an unknown format");
				return false;
			}
			if (!root.GetString("product", Product) || Product != ProductName)
			{
				outReason.Set("the release description is not for VisualBeef");
				return false;
			}
			if (!root.GetString("version", Version) || !IsSafeSegment(Version))
			{
				outReason.Set("the release description has no valid version");
				return false;
			}
			if (!root.GetString("channel", Channel) || (Channel != "stable" && Channel != "preview"))
			{
				outReason.Set("the release description has no valid channel (stable or preview)");
				return false;
			}
			if (!root.GetInt("sequence", out Sequence) || Sequence < 1)
			{
				outReason.Set("the release description has no sequence number");
				return false;
			}
			if (!root.GetString("tag", Tag) || !IsSafeSegment(Tag))
			{
				outReason.Set("the release description has no valid tag");
				return false;
			}
			if (!root.GetString("publishedAt", PublishedAt) || !IsSingleLine(PublishedAt) || PublishedAt.Length > 64)
			{
				outReason.Set("the release description has no valid publish date");
				return false;
			}
			root.GetString("notes", Notes);
			if (Notes.Length > 16 * 1024)
				Notes.RemoveToEnd(16 * 1024);
			root.GetString("signature", Signature);
			let assets = root.Get("assets");
			if (assets == null || !assets.IsArray || assets.Items.IsEmpty || assets.Items.Count > 32)
			{
				outReason.Set("the release description lists no files");
				return false;
			}
			for (let item in assets.Items)
			{
				let a = new ReleaseAsset();
				Assets.Add(a);
				if (!item.IsObject || !item.GetString("platform", a.Platform) || !IsSafeSegment(a.Platform) ||
					!item.GetString("name", a.Name) || !IsSafeSegment(a.Name) ||
					!item.GetInt("size", out a.Size) || a.Size < 1 ||
					!item.GetString("sha256", a.Sha256) || !IsSha256Hex(a.Sha256))
				{
					outReason.Set("a file in the release description is malformed");
					return false;
				}
				for (int k < Assets.Count - 1)
				{
					if (Assets[k].Platform == a.Platform)
					{
						outReason.Set(scope $"the release description lists the platform {a.Platform} twice");
						return false;
					}
				}
			}
			return true;
		}

		/// Ordinal byte comparison (the order release.mjs sorts the assets in).
		public static int CompareOrdinal(StringView a, StringView b)
		{
			int n = Math.Min(a.Length, b.Length);
			for (int i < n)
			{
				if (a[i] != b[i])
					return (uint8)a[i] < (uint8)b[i] ? -1 : 1;
			}
			return a.Length <=> b.Length;
		}

		/// The exact bytes `scripts/release.mjs sign` signs:
		///   visualbeef-release-v1\nproduct=VisualBeef\nversion=..\nchannel=..\nsequence=..\ntag=..\npublishedAt=..\n
		///   asset=<platform> <name> <size> <sha256>\n   (one line per asset, sorted by platform, ordinal)
		public void CanonicalText(String outText)
		{
			outText.Append(Domain, "\n");
			outText.AppendF("product={}\n", Product);
			outText.AppendF("version={}\n", Version);
			outText.AppendF("channel={}\n", Channel);
			outText.AppendF("sequence={}\n", Sequence);
			outText.AppendF("tag={}\n", Tag);
			outText.AppendF("publishedAt={}\n", PublishedAt);
			List<ReleaseAsset> sorted = scope .();
			sorted.AddRange(Assets);
			sorted.Sort(scope (x, y) => CompareOrdinal(x.Platform, y.Platform));
			for (let a in sorted)
				outText.AppendF("asset={} {} {} {}\n", a.Platform, a.Name, a.Size, a.Sha256);
		}

		/// Parses base64 Ed25519 public keys separated by ';', ',' or white space. Malformed entries are skipped.
		public static void ParseKeys(StringView keys, List<uint8[32]> outKeys)
		{
			for (var part in keys.Split(';', ',', ' ', '\n', '\r', '\t'))
			{
				part.Trim();
				if (part.IsEmpty)
					continue;
				List<uint8> bytes = scope .();
				if (Base64.Decode(part, bytes) case .Err || bytes.Count != Ed25519.PublicKeySize)
					continue;
				uint8[32] key = ?;
				for (int i < 32)
					key[i] = bytes[i];
				outKeys.Add(key);
			}
		}

		public static bool HasKeys(StringView keys)
		{
			List<uint8[32]> list = scope .();
			ParseKeys(keys, list);
			return !list.IsEmpty;
		}

		/// True when the descriptor is signed by one of `keys` (default: the keys compiled into this build).
		public bool Verify(String outReason, StringView keys = ReleaseKeys.Keys)
		{
			List<uint8[32]> keyList = scope .();
			ParseKeys(keys, keyList);
			if (keyList.IsEmpty)
			{
				outReason.Set("updates are not set up in this build (it trusts no release key)");
				return false;
			}
			if (Signature.IsEmpty)
			{
				outReason.Set("the release is not signed");
				return false;
			}
			List<uint8> sig = scope .();
			if (Base64.Decode(Signature, sig) case .Err || sig.Count != Ed25519.SignatureSize)
			{
				outReason.Set("the release signature is malformed");
				return false;
			}
			String text = scope .();
			CanonicalText(text);
			Span<uint8> message = .((uint8*)text.Ptr, text.Length);
			for (var key in ref keyList)
			{
				if (Ed25519.Verify(.(&key[0], 32), message, sig))
					return true;
			}
			outReason.Set("the release signature does not match the VisualBeef release key (the file was altered, or signed with another key)");
			return false;
		}

		public ReleaseAsset FindAsset(StringView platform)
		{
			for (let a in Assets)
				if (a.Platform == platform)
					return a;
			return null;
		}

		/// The first asset whose platform is in `preferred` (in that order), or null.
		public ReleaseAsset SelectAsset(Span<StringView> preferred)
		{
			for (let p in preferred)
			{
				let a = FindAsset(p);
				if (a != null)
					return a;
			}
			return null;
		}
	}

	/// Versions as the package carries them (VERSION.txt): MAJOR.MINOR.PATCH with an optional -prerelease part
	/// (`0.1.9-alpha`). Compared like semantic versions: numbers first, then a version without a suffix is above one with
	/// a suffix, then the dot-separated suffix parts (numeric parts as numbers, numbers below words).
	public static class ReleaseVersion
	{
		public static bool TryParse(StringView text, out int64[3] core, out StringView pre)
		{
			core = default;
			pre = default;
			var main = text;
			int dash = text.IndexOf('-');
			if (dash >= 0)
			{
				main = text.Substring(0, dash);
				pre = text.Substring(dash + 1);
				if (pre.IsEmpty)
					return false;
			}
			int n = 0;
			for (let part in main.Split('.'))
			{
				if (n >= 3 || part.IsEmpty || part.Length > 9)
					return false;
				for (let c in part.RawChars)
					if (!c.IsDigit)
						return false;
				core[n++] = int64.Parse(part).GetValueOrDefault();
			}
			return n == 3;
		}

		static bool IsNumeric(StringView s)
		{
			if (s.IsEmpty || s.Length > 9)
				return false;
			for (let c in s.RawChars)
				if (!c.IsDigit)
					return false;
			return true;
		}

		/// <0 when a is older than b, 0 equal, >0 newer. Unparsable versions compare as equal (never "newer").
		public static int Compare(StringView a, StringView b)
		{
			if (!TryParse(a, let ca, let pa))
				return 0;
			if (!TryParse(b, let cb, let pb))
				return 0;
			for (int i < 3)
				if (ca[i] != cb[i])
					return ca[i] < cb[i] ? -1 : 1;
			if (pa.IsEmpty != pb.IsEmpty)
				return pa.IsEmpty ? 1 : -1;
			if (pa.IsEmpty)
				return 0;
			var ea = pa.Split('.');
			var eb = pb.Split('.');
			while (true)
			{
				let ha = ea.GetNext();
				let hb = eb.GetNext();
				if (ha case .Err)
					return (hb case .Err) ? 0 : -1;
				if (hb case .Err)
					return 1;
				let xa = ha.Value;
				let xb = hb.Value;
				bool na = IsNumeric(xa);
				bool nb = IsNumeric(xb);
				if (na && nb)
				{
					let va = int64.Parse(xa).GetValueOrDefault();
					let vb = int64.Parse(xb).GetValueOrDefault();
					if (va != vb)
						return va < vb ? -1 : 1;
				}
				else if (na != nb)
					return na ? -1 : 1;
				else
				{
					let c = ReleaseDescriptor.CompareOrdinal(xa, xb);
					if (c != 0)
						return c;
				}
			}
		}
	}

	/// Whether a verified release is offered (docs/Releasing.md, "What the editor accepts").
	public enum UpdateDecision
	{
		/// Offered: newer than the running build.
		Newer,
		/// Not offered: the same build or an older one (a lower or equal sequence is never installed).
		NotNewer
	}

	public static class UpdateRules
	{
		/// `runningSequence` is the signed sequence of the running build when known (installed by the updater), else -1.
		/// With a known sequence only a higher sequence is offered (no downgrade, no replay of an older signed release).
		/// Without one, the release is offered when its version is above the running version.
		public static UpdateDecision Decide(StringView runningVersion, int64 runningSequence, ReleaseDescriptor latest)
		{
			if (runningSequence >= 1)
				return latest.Sequence > runningSequence ? .Newer : .NotNewer;
			return ReleaseVersion.Compare(latest.Version, runningVersion) > 0 ? .Newer : .NotNewer;
		}

		/// The platform keys this build installs, most specific first. `minimal` = the install has no docs folder.
		public static void PlatformKeys(bool minimal, bool appImage, List<StringView> outKeys)
		{
#if BF_PLATFORM_WINDOWS
			if (minimal)
				outKeys.Add("win64-minimal");
			outKeys.Add("win64");
#else
			if (appImage)
				outKeys.Add("linux-x86_64-appimage");
#endif
		}
	}

	/// Base64 (RFC 4648, standard alphabet, padding optional on decode).
	public static class Base64
	{
		const String cAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

		static int Value(char8 c)
		{
			if (c >= 'A' && c <= 'Z')
				return c - 'A';
			if (c >= 'a' && c <= 'z')
				return c - 'a' + 26;
			if (c >= '0' && c <= '9')
				return c - '0' + 52;
			if (c == '+')
				return 62;
			if (c == '/')
				return 63;
			return -1;
		}

		public static Result<void> Decode(StringView text, List<uint8> outBytes)
		{
			var t = text;
			while (t.EndsWith('='))
				t.RemoveFromEnd(1);
			if (text.Length - t.Length > 2 || t.Length % 4 == 1)
				return .Err;
			uint32 acc = 0;
			int bits = 0;
			for (let c in t.RawChars)
			{
				let v = Value(c);
				if (v < 0)
					return .Err;
				acc = (acc << 6) | (uint32)v;
				bits += 6;
				if (bits >= 8)
				{
					bits -= 8;
					outBytes.Add((uint8)(acc >> bits));
				}
			}
			return .Ok;
		}

		public static void Encode(Span<uint8> data, String outText)
		{
			int i = 0;
			while (i + 3 <= data.Length)
			{
				uint32 v = ((uint32)data[i] << 16) | ((uint32)data[i + 1] << 8) | data[i + 2];
				outText.Append(cAlphabet[(v >> 18) & 63]);
				outText.Append(cAlphabet[(v >> 12) & 63]);
				outText.Append(cAlphabet[(v >> 6) & 63]);
				outText.Append(cAlphabet[v & 63]);
				i += 3;
			}
			let rest = data.Length - i;
			if (rest == 1)
			{
				uint32 v = (uint32)data[i] << 16;
				outText.Append(cAlphabet[(v >> 18) & 63]);
				outText.Append(cAlphabet[(v >> 12) & 63]);
				outText.Append("==");
			}
			else if (rest == 2)
			{
				uint32 v = ((uint32)data[i] << 16) | ((uint32)data[i + 1] << 8);
				outText.Append(cAlphabet[(v >> 18) & 63]);
				outText.Append(cAlphabet[(v >> 12) & 63]);
				outText.Append(cAlphabet[(v >> 6) & 63]);
				outText.Append('=');
			}
		}
	}
}
