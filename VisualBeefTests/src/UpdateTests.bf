using System;
using System.Collections;
using System.IO;
using VisualBeef.Update;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests update`: the updater's trust rules and file steps, no network (docs/Testing.md, `update`).
	/// Descriptor parsing and refusals, the canonical text, Ed25519 (RFC 8032 vector, a key made at test time, and a
	/// descriptor signed by scripts/release.mjs with its fixed TEST seed), sequence / downgrade rules, version order,
	/// platform choice, the SHA-256 and size check of a download, the swap / restore of an install folder, the preview
	/// release list, the recorded sequence, the HTTP header reader.
	static class UpdateTests
	{
		static int sChecks;
		static int sFailures;

		static void Check(bool cond, StringView what)
		{
			sChecks++;
			if (cond)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		/// `node scripts/release.mjs vectors` (TEST seed 01..20; never a real key).
		const String cNodeKey = "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=";
		const String cNodeDescriptor = """
			{
			  "format": 1,
			  "product": "VisualBeef",
			  "version": "0.2.0-alpha",
			  "channel": "stable",
			  "sequence": 7,
			  "tag": "v0.2.0",
			  "publishedAt": "2026-10-12T10:00:00Z",
			  "assets": [
			    { "platform": "win64", "name": "VisualBeef-0.2.0-win64.zip", "size": 1234567, "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
			    { "platform": "linux-x86_64-appimage", "name": "VisualBeef-0.2.0-alpha-x86_64.AppImage", "size": 7654321, "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
			    { "platform": "win64-minimal", "name": "VisualBeef-0.2.0-alpha-win64.zip", "size": 1000, "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" }
			  ],
			  "notes": "Test notes",
			  "signature": "QcYzRMLl96Jzsj2MU0fWPo28Qmy6plBHrTD4+77OEEUCQBsHiNR/YyEBtMcWwRFhyxzQ5UrcdEXk3/6NLzYuCQ=="
			}
			""";

		public static int Run()
		{
			sChecks = 0;
			sFailures = 0;
			Encodings();
			Rfc8032();
			NodeVector();
			SignedAtTestTime();
			ParseRefusals();
			Sequences();
			Versions();
			Platforms();
			Downloads();
			SwapAndRestore();
			PreviewList();
			Recorded();
			Headers();
			Console.WriteLine("update checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}

		/// `VisualBeefTests update -net`: the network half, by hand (not in CI): a real check against the public
		/// repository through curl (GitHub's redirect, the 404 of a repository with no release yet or a release.json that
		/// must verify), the preview list from the GitHub API, the ETag cache, and a download with progress.
		public static int RunNet()
		{
			sChecks = 0;
			sFailures = 0;
			let dir = Scratch();
			defer { UpdateApply.DeletePath(dir); delete dir; }
			String curl = scope .();
			Check(UpdateHttp.FindCurl(curl), scope $"curl found ({curl})");
			StringView[2] channels = .("stable", "preview");
			for (let channel in channels)
			{
				UpdateService svc = scope .();
				svc.Init(dir);
				svc.Keys.Set(cNodeKey); // any key: the check must get as far as the descriptor
				svc.Channel.Set(channel);
				svc.OnLog = new (line) => Console.WriteLine("    log: {}", line);
				Check(svc.StartCheck(true), scope $"{channel}: check started");
				UpdateStatus st = scope .();
				for (int i < 600)
				{
					svc.GetStatus(st);
					if (st.State != .Checking)
						break;
					System.Threading.Thread.Sleep(100);
				}
				Console.WriteLine("    {} -> {}: {}", channel, st.State, st.Message);
				Check(st.State == .UpToDate || st.State == .Available || (st.State == .Error && st.Message.Contains("refused")), scope $"{channel}: the check got an answer from GitHub");
			}
			String etag = scope .();
			File.ReadAllText(scope $"{dir}{Path.DirectorySeparatorChar}cache{Path.DirectorySeparatorChar}releases-list.json.etag", etag).IgnoreError();
			Check(!etag.IsEmpty, "the releases list's ETag is cached");
			String zip = scope $"{dir}{Path.DirectorySeparatorChar}archive.zip";
			UpdateHttp.Response r = scope .();
			int calls = 0;
			UpdateHttp.Get("https://github.com/AproposRobin/VBeef/archive/refs/heads/master.zip", zip, "", 200 * 1024 * 1024, 10, 0, false, r, scope [&] (n) => { calls++; });
			Check(r.Outcome == .Ok && r.Status == 200 && calls > 0, scope $"a download through GitHub's redirect: {r.Outcome}, answer {r.Status}, {calls} progress calls");
			UpdateHttp.Response small = scope .();
			UpdateHttp.Get("https://github.com/AproposRobin/VBeef/archive/refs/heads/master.zip", zip, "", 1000, 10, 0, false, small);
			Check(small.Outcome == .TooLarge, "a download larger than the signed size is cut off");
			Console.WriteLine("update net checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}

		static void Hex(StringView hex, List<uint8> outBytes)
		{
			for (int i = 0; i + 1 < hex.Length; i += 2)
			{
				int Nib(char8 c) => (c >= 'a') ? (c - 'a' + 10) : (c >= 'A') ? (c - 'A' + 10) : (c - '0');
				outBytes.Add((uint8)((Nib(hex[i]) << 4) | Nib(hex[i + 1])));
			}
		}

		static void ToHex(Span<uint8> bytes, String outHex)
		{
			for (let b in bytes)
				outHex.AppendF("{:X2}", b);
			outHex.ToLower();
		}

		static void Encodings()
		{
			Console.WriteLine("encodings");
			List<uint8> bytes = scope .();
			Check(Base64.Decode("aGVsbG8=", bytes) case .Ok && bytes.Count == 5 && bytes[0] == 'h' && bytes[4] == 'o', "base64 decodes 'hello'");
			String enc = scope .();
			Base64.Encode(bytes, enc);
			Check(enc == "aGVsbG8=", "base64 encodes it back");
			bytes.Clear();
			Check(Base64.Decode("a*==", bytes) case .Err, "base64 refuses a character outside the alphabet");
			uint8[64] digest = ?;
			let abc = "abc";
			Sha512.Hash(.((uint8*)abc.Ptr, 3), &digest[0]);
			String hex = scope .();
			ToHex(.(&digest[0], 64), hex);
			Check(hex == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "SHA-512 of 'abc' (FIPS 180-4)");

			let dir = Scratch();
			defer delete dir;
			String f = scope $"{dir}{Path.DirectorySeparatorChar}abc.bin";
			File.WriteAllText(f, "abc").IgnoreError();
			String sha = scope .();
			Check(UpdateService.Sha256OfFile(f, sha) && sha == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of a file holding 'abc'");
			UpdateApply.DeletePath(dir);

			UpdateJson j = null;
			if (UpdateJson.Parse("{\"a\": \"\\u00e9\\ud83d\\ude00\", \"b\": [1, 2.5, -3e2, true, null]}") case .Ok(let parsed))
				j = parsed;
			Check(j != null && j.Get("a").Text == "\u{e9}\u{1F600}" && j.Get("b").Items.Count == 5, "JSON: escapes, surrogate pairs, numbers, literals");
			delete j;
			String deep = scope .();
			for (int i < 40)
				deep.Append('[');
			for (int i < 40)
				deep.Append(']');
			Check(UpdateJson.Parse(deep) case .Err, "JSON: nesting deeper than 32 is refused");
			Check(UpdateJson.Parse("{\"a\": 1,}") case .Err, "JSON: a trailing comma is refused");
			Check(UpdateJson.Parse("{\"a\": \"x\n\"}") case .Err, "JSON: a raw line break in a string is refused");
		}

		static void Rfc8032()
		{
			Console.WriteLine("Ed25519 (RFC 8032 test 1)");
			List<uint8> seed = scope .();
			Hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", seed);
			List<uint8> pub = scope .();
			Hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", pub);
			List<uint8> sig = scope .();
			Hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b", sig);
			uint8[32] derived = ?;
			Ed25519.PublicKeyFromSeed(seed, &derived[0]);
			bool same = true;
			for (int i < 32)
				same &= derived[i] == pub[i];
			Check(same, "public key from the seed");
			uint8[64] made = ?;
			Ed25519.Sign(seed, .(), &made[0]);
			bool sameSig = true;
			for (int i < 64)
				sameSig &= made[i] == sig[i];
			Check(sameSig, "signature of the empty message");
			Check(Ed25519.Verify(pub, .(), sig), "the signature verifies");
			sig[10] ^= 1;
			Check(!Ed25519.Verify(pub, .(), sig), "a changed signature does not verify");
			sig[10] ^= 1;
			uint8 m = 0x72;
			Check(!Ed25519.Verify(pub, .(&m, 1), sig), "another message does not verify");
		}

		static ReleaseDescriptor ParseOk(StringView text)
		{
			String why = scope .();
			if (ReleaseDescriptor.Parse(text, why) case .Ok(let d))
				return d;
			Console.WriteLine("    parse failed: {}", why);
			return null;
		}

		static void NodeVector()
		{
			Console.WriteLine("descriptor signed by scripts/release.mjs");
			let d = ParseOk(cNodeDescriptor);
			Check(d != null, "the descriptor parses");
			if (d == null)
				return;
			defer delete d;
			Check(d.Version == "0.2.0-alpha" && d.Sequence == 7 && d.Tag == "v0.2.0" && d.Assets.Count == 3 && d.Notes == "Test notes", "fields read");
			String text = scope .();
			d.CanonicalText(text);
			Check(text == "visualbeef-release-v1\nproduct=VisualBeef\nversion=0.2.0-alpha\nchannel=stable\nsequence=7\ntag=v0.2.0\npublishedAt=2026-10-12T10:00:00Z\n" +
				"asset=linux-x86_64-appimage VisualBeef-0.2.0-alpha-x86_64.AppImage 7654321 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" +
				"asset=win64 VisualBeef-0.2.0-win64.zip 1234567 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" +
				"asset=win64-minimal VisualBeef-0.2.0-alpha-win64.zip 1000 cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n", "canonical text, assets sorted by platform");
			String why = scope .();
			Check(d.Verify(why, cNodeKey), "Node's signature verifies in Beef");
			why.Clear();
			Check(!d.Verify(why, "") && why.Contains("not set up"), "no compiled-in key: every descriptor is refused (\"not set up\")");
			why.Clear();
			Check(!d.Verify(why, "11qYAYKxCrfVS/7TyWQHOg7hcvPaplMlrwIaaPcHURo=") && why.Contains("does not match"), "another key: refused");
			why.Clear();
			Check(d.Verify(why, scope $"11qYAYKxCrfVS/7TyWQHOg7hcvPaplMlrwIaaPcHURo=;{cNodeKey}"), "a key list (rotation) with the right key verifies");

			// Every signed field changed: refused. Notes are not signed.
			StringView[?] edits = .(
				"\"version\": \"0.2.0-alpha\"|\"version\": \"0.2.1-alpha\"",
				"\"sequence\": 7|\"sequence\": 8",
				"\"channel\": \"stable\"|\"channel\": \"preview\"",
				"\"tag\": \"v0.2.0\"|\"tag\": \"v0.2.1\"",
				"\"publishedAt\": \"2026-10-12T10:00:00Z\"|\"publishedAt\": \"2026-10-13T10:00:00Z\"",
				"\"size\": 1234567|\"size\": 1234568",
				"\"sha256\": \"aaaa|\"sha256\": \"aaab",
				"\"name\": \"VisualBeef-0.2.0-win64.zip\"|\"name\": \"VisualBeef-0.2.0-win64x.zip\"",
				"\"platform\": \"win64\"|\"platform\": \"win32\"");
			for (let e in edits)
			{
				int bar = e.IndexOf('|');
				String changed = scope .(cNodeDescriptor);
				changed.Replace(e.Substring(0, bar), e.Substring(bar + 1));
				let t = ParseOk(changed);
				why.Clear();
				Check(t != null && changed != cNodeDescriptor && !t.Verify(why, cNodeKey), scope $"changed {e.Substring(0, Math.Min(bar, 24))}...: refused");
				delete t;
			}
			{
				String changed = scope .(cNodeDescriptor);
				changed.Replace("Test notes", "Other notes");
				let t = ParseOk(changed);
				why.Clear();
				Check(t != null && t.Verify(why, cNodeKey), "changed notes: still verifies (notes are not signed)");
				delete t;
			}
			{
				String changed = scope .(cNodeDescriptor);
				changed.Replace("\"signature\": \"QcYz", "\"signature\": \"!cYz");
				let t = ParseOk(changed);
				why.Clear();
				Check(t != null && !t.Verify(why, cNodeKey) && why.Contains("malformed"), "malformed signature: refused");
				delete t;
				String unsigned = scope .(cNodeDescriptor);
				unsigned.Replace("\"signature\": \"QcYzRMLl96Jzsj2MU0fWPo28Qmy6plBHrTD4+77OEEUCQBsHiNR/YyEBtMcWwRFhyxzQ5UrcdEXk3/6NLzYuCQ==\"", "\"signature\": \"\"");
				let u = ParseOk(unsigned);
				why.Clear();
				Check(u != null && !u.Verify(why, cNodeKey) && why.Contains("not signed"), "unsigned: refused");
				delete u;
			}
		}

		static void SignedAtTestTime()
		{
			Console.WriteLine("descriptor signed with a key made now");
			uint8[32] seed = ?;
			let seedSrc = scope $"{Internal.GetTickCountMicro()}-visualbeef-test-seed";
			uint8[64] h = ?;
			Sha512.Hash(.((uint8*)seedSrc.Ptr, seedSrc.Length), &h[0]);
			for (int i < 32)
				seed[i] = h[i];
			uint8[32] pub = ?;
			Ed25519.PublicKeyFromSeed(.(&seed[0], 32), &pub[0]);
			String pubText = scope .();
			Base64.Encode(.(&pub[0], 32), pubText);
			let d = ParseOk(cNodeDescriptor);
			if (d == null)
			{
				Check(false, "parse");
				return;
			}
			defer delete d;
			d.Sequence = 12;
			String text = scope .();
			d.CanonicalText(text);
			uint8[64] sig = ?;
			Ed25519.Sign(.(&seed[0], 32), .((uint8*)text.Ptr, text.Length), &sig[0]);
			d.Signature.Clear();
			Base64.Encode(.(&sig[0], 64), d.Signature);
			String why = scope .();
			Check(d.Verify(why, pubText), "signed in Beef, verifies");
			why.Clear();
			Check(!d.Verify(why, cNodeKey), "the release.mjs TEST key does not verify it");
			d.Sequence = 13;
			why.Clear();
			Check(!d.Verify(why, pubText), "sequence raised after signing: refused");
		}

		static bool Refused(StringView text, StringView reasonPart, StringView what)
		{
			String why = scope .();
			if (ReleaseDescriptor.Parse(text, why) case .Ok(let d))
			{
				delete d;
				Check(false, what);
				return false;
			}
			Check(why.Contains(reasonPart), scope $"{what} ({why})");
			return true;
		}

		static void ParseRefusals()
		{
			Console.WriteLine("descriptor shape");
			Refused("not json", "not valid JSON", "not JSON");
			Refused("[1]", "not a JSON object", "an array");
			String t = scope .();
			void Edit(StringView from, StringView to)
			{
				t.Set(cNodeDescriptor);
				t.Replace(from, to);
			}
			Edit("\"format\": 1", "\"format\": 2");
			Refused(t, "unknown format", "format 2");
			Edit("\"product\": \"VisualBeef\"", "\"product\": \"Other\"");
			Refused(t, "not for VisualBeef", "another product");
			Edit("\"channel\": \"stable\"", "\"channel\": \"beta\"");
			Refused(t, "channel", "an unknown channel");
			Edit("\"sequence\": 7", "\"sequence\": 0");
			Refused(t, "sequence", "sequence 0");
			Edit("\"sequence\": 7", "\"sequence\": 7.5");
			Refused(t, "sequence", "a fractional sequence");
			Edit("\"tag\": \"v0.2.0\"", "\"tag\": \"../v0.2.0\"");
			Refused(t, "tag", "a tag with a path");
			Edit("\"name\": \"VisualBeef-0.2.0-win64.zip\"", "\"name\": \"../../evil.zip\"");
			Refused(t, "malformed", "an asset name with a path");
			Edit("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
			Refused(t, "malformed", "an upper-case sha256");
			Edit("\"size\": 1000", "\"size\": -1");
			Refused(t, "malformed", "a negative size");
			Edit("\"platform\": \"win64-minimal\"", "\"platform\": \"win64\"");
			Refused(t, "twice", "a platform listed twice");
			Edit("\"version\": \"0.2.0-alpha\"", "\"version\": \"0.2.0\\nsequence=99\"");
			Refused(t, "version", "a version with a line break");
			String big = scope .();
			big.Append(' ', ReleaseDescriptor.MaxBytes + 1);
			Refused(big, "too large", "a descriptor over 64 KiB");
		}

		static void Sequences()
		{
			Console.WriteLine("sequence and downgrade rules");
			let d = ParseOk(cNodeDescriptor);
			if (d == null)
				return;
			defer delete d;
			Check(UpdateRules.Decide("0.1.9-alpha", 6, d) == .Newer, "running sequence 6, release 7: offered");
			Check(UpdateRules.Decide("0.1.9-alpha", 7, d) == .NotNewer, "same sequence: not offered");
			Check(UpdateRules.Decide("0.3.0-alpha", 8, d) == .NotNewer, "running sequence 8, release 7: refused (no downgrade)");
			Check(UpdateRules.Decide("0.9.0-alpha", 6, d) == .Newer, "a known sequence decides, not the version text");
			Check(UpdateRules.Decide("0.1.9-alpha", -1, d) == .Newer, "unknown sequence, older running version: offered");
			Check(UpdateRules.Decide("0.2.0-alpha", -1, d) == .NotNewer, "unknown sequence, same version: not offered");
			Check(UpdateRules.Decide("0.3.0-alpha", -1, d) == .NotNewer, "unknown sequence, newer running version: not offered (no downgrade)");
			Check(UpdateRules.Decide("dev", -1, d) == .NotNewer, "an unreadable running version: not offered");
		}

		static void Versions()
		{
			Console.WriteLine("version order");
			Check(ReleaseVersion.Compare("0.2.0", "0.1.9") > 0, "0.2.0 > 0.1.9");
			Check(ReleaseVersion.Compare("0.10.0", "0.9.9") > 0, "0.10.0 > 0.9.9 (numbers, not text)");
			Check(ReleaseVersion.Compare("1.0.0", "1.0.0-alpha") > 0, "1.0.0 > 1.0.0-alpha");
			Check(ReleaseVersion.Compare("1.0.0-alpha", "1.0.0-beta") < 0, "alpha < beta");
			Check(ReleaseVersion.Compare("1.0.0-alpha.2", "1.0.0-alpha.10") < 0, "alpha.2 < alpha.10");
			Check(ReleaseVersion.Compare("1.0.0-alpha", "1.0.0-alpha.1") < 0, "alpha < alpha.1");
			Check(ReleaseVersion.Compare("0.1.9-alpha", "0.1.9-alpha") == 0, "equal");
			Check(ReleaseVersion.Compare("0.1", "0.0.1") == 0 && ReleaseVersion.Compare("x.y.z", "0.0.1") == 0, "malformed versions never compare as newer");
		}

		static void Platforms()
		{
			Console.WriteLine("platform files");
			let d = ParseOk(cNodeDescriptor);
			if (d == null)
				return;
			defer delete d;
			StringView[2] minimal = .("win64-minimal", "win64");
			Check(d.SelectAsset(minimal).Name == "VisualBeef-0.2.0-alpha-win64.zip", "minimal Windows copy: the minimal zip");
			StringView[1] full = .("win64");
			Check(d.SelectAsset(full).Name == "VisualBeef-0.2.0-win64.zip", "full Windows copy: the full zip");
			StringView[1] appimage = .("linux-x86_64-appimage");
			Check(d.SelectAsset(appimage).Name == "VisualBeef-0.2.0-alpha-x86_64.AppImage", "AppImage: the AppImage");
			StringView[1] tarball = .("linux-x86_64");
			Check(d.SelectAsset(tarball) == null, "a platform the release does not carry: none");
			List<StringView> keys = scope .();
			UpdateRules.PlatformKeys(true, false, keys);
#if BF_PLATFORM_WINDOWS
			Check(keys.Count == 2 && keys[0] == "win64-minimal" && keys[1] == "win64", "this system (Windows): minimal first, then full");
#else
			Check(keys.IsEmpty, "this system (Linux folder): no installable file");
			keys.Clear();
			UpdateRules.PlatformKeys(false, true, keys);
			Check(keys.Count == 1 && keys[0] == "linux-x86_64-appimage", "this system (Linux AppImage): the AppImage");
#endif
		}

		static String Scratch()
		{
			String tmp = new .();
#if BF_PLATFORM_WINDOWS
			Environment.GetEnvironmentVariable("TEMP", tmp).IgnoreError();
#else
			tmp.Set("/tmp");
#endif
			if (tmp.IsEmpty)
				tmp.Set(".");
			tmp.AppendF("{}vb-update-tests-{}-{}", Path.DirectorySeparatorChar, UpdateApply.CurrentPid(), Internal.GetTickCountMicro());
			UpdateApply.EnsureDir(tmp);
			return tmp;
		}

		static void Write(StringView dir, StringView rel, StringView text)
		{
			String p = scope .();
			UpdateApply.Join(p, dir, rel);
			String parent = scope .();
			Path.GetDirectoryPath(p, parent).IgnoreError();
			UpdateApply.EnsureDir(parent);
			File.WriteAllText(p, text).IgnoreError();
		}

		static bool Has(StringView dir, StringView rel, StringView text)
		{
			String p = scope .();
			UpdateApply.Join(p, dir, rel);
			String got = scope .();
			if (File.ReadAllText(p, got) case .Err)
				return false;
			return got == text;
		}

		static bool Exists(StringView dir, StringView rel)
		{
			String p = scope .();
			UpdateApply.Join(p, dir, rel);
			return File.Exists(p) || Directory.Exists(p);
		}

		static void Downloads()
		{
			Console.WriteLine("download checks");
			let dir = Scratch();
			defer { UpdateApply.DeletePath(dir); delete dir; }
			Write(dir, "pkg.zip", "abc");
			String file = scope .();
			UpdateApply.Join(file, dir, "pkg.zip");
			ReleaseAsset a = scope .();
			a.Platform.Set("win64");
			a.Name.Set("pkg.zip");
			a.Size = 3;
			a.Sha256.Set("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
			String why = scope .();
			Check(UpdateService.CheckFile(file, a, why), "size and SHA-256 match: accepted");
			a.Sha256.Set("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ae");
			why.Clear();
			Check(!UpdateService.CheckFile(file, a, why) && why.Contains("SHA-256"), "SHA-256 mismatch: refused");
			a.Size = 4;
			why.Clear();
			Check(!UpdateService.CheckFile(file, a, why) && why.Contains("bytes"), "size mismatch: refused");

			Write(dir, "pkg/VisualBeefEditor.exe", "x");
			Write(dir, "pkg/vbhost.dll", "x");
			Write(dir, "pkg/LICENSE", "x");
			Write(dir, "pkg/VERSION.txt", "0.2.0-alpha\r\n");
			String pkg = scope .();
			UpdateApply.Join(pkg, dir, "pkg");
			why.Clear();
			Check(UpdateService.CheckLayout(pkg, "0.2.0-alpha", why), "package layout and VERSION.txt: accepted");
			why.Clear();
			Check(!UpdateService.CheckLayout(pkg, "0.2.1-alpha", why) && why.Contains("says it is"), "VERSION.txt is another version: refused");
			String dll = scope .();
			UpdateApply.Join(dll, pkg, "vbhost.dll");
			File.Delete(dll).IgnoreError();
			why.Clear();
			Check(!UpdateService.CheckLayout(pkg, "0.2.0-alpha", why) && why.Contains("vbhost.dll"), "a package without vbhost.dll: refused");
		}

		static void SwapAndRestore()
		{
			Console.WriteLine("swap and restore");
			let root = Scratch();
			defer { UpdateApply.DeletePath(root); delete root; }
			String install = scope .();
			UpdateApply.Join(install, root, "install");
			String staged = scope .();
			UpdateApply.Join(staged, root, "staged");
			String previous = scope .();
			UpdateApply.Join(previous, root, "previous");
			Write(install, "VisualBeefEditor.exe", "old exe");
			Write(install, "VERSION.txt", "0.1.9-alpha");
			Write(install, "docs/Old.md", "old page");
			Write(install, "keep.txt", "user file");
			Write(staged, "VisualBeefEditor.exe", "new exe");
			Write(staged, "VERSION.txt", "0.2.0-alpha");
			Write(staged, "docs/New.md", "new page");
			Write(staged, "NEWFILE.txt", "added");
			String why = scope .();
			Check(UpdateApply.Swap(install, staged, previous, why, null), "swap succeeds");
			Check(Has(install, "VisualBeefEditor.exe", "new exe") && Has(install, "VERSION.txt", "0.2.0-alpha"), "files replaced");
			Check(Has(install, "docs/New.md", "new page") && !Exists(install, "docs/Old.md"), "a folder is replaced as a whole");
			Check(Has(install, "keep.txt", "user file") && Has(install, "NEWFILE.txt", "added"), "other files kept, new files added");
			Check(Has(previous, "VisualBeefEditor.exe", "old exe") && Has(previous, "docs/Old.md", "old page"), "previous copy kept");
			String v = scope .();
			UpdateApply.ReadVersionFile(install, v);
			Check(v == "0.2.0-alpha", "VERSION.txt first line read");
			why.Clear();
			Check(UpdateApply.Restore(install, previous, why, null), "restore succeeds");
			Check(Has(install, "VisualBeefEditor.exe", "old exe") && Has(install, "docs/Old.md", "old page") && !Exists(install, "docs/New.md"), "restored byte for byte");
			Check(!Exists(install, "NEWFILE.txt") && Has(install, "keep.txt", "user file"), "added files removed, user files untouched");
			String empty = scope .();
			UpdateApply.Join(empty, root, "empty");
			UpdateApply.EnsureDir(empty);
			why.Clear();
			Check(!UpdateApply.Swap(install, empty, previous, why, null) && why.Contains("empty") && Has(install, "VisualBeefEditor.exe", "old exe"), "an empty package is refused, nothing changed");
		}

		static void PreviewList()
		{
			Console.WriteLine("preview channel release list");
			const String list = """
				[
				  {"tag_name": "v0.3.0", "draft": true, "prerelease": true, "assets": [{"name": "release.json"}]},
				  {"tag_name": "v0.2.1", "draft": false, "prerelease": true, "assets": [{"name": "VisualBeef-0.2.1-win64.zip"}]},
				  {"tag_name": "v0.2.0", "draft": false, "prerelease": true, "assets": [{"name": "VisualBeef-0.2.0-win64.zip"}, {"name": "release.json"}]},
				  {"tag_name": "v0.1.9", "draft": false, "prerelease": false, "assets": [{"name": "release.json"}]}
				]
				""";
			String tag = scope .();
			Check(UpdateService.PickPreviewTag(list, tag) && tag == "v0.2.0", "drafts and releases without release.json are skipped");
			tag.Clear();
			Check(!UpdateService.PickPreviewTag("[]", tag), "an empty list: nothing");
			Check(!UpdateService.PickPreviewTag("{\"message\": \"rate limited\"}", tag), "an error object: nothing");
			Check(!UpdateService.PickPreviewTag("[{\"tag_name\": \"../x\", \"draft\": false, \"assets\": [{\"name\": \"release.json\"}]}]", tag), "an unsafe tag: skipped");
		}

		static void Recorded()
		{
			Console.WriteLine("recorded sequence");
			let dir = Scratch();
			defer { UpdateApply.DeletePath(dir); delete dir; }
			Check(UpdateApply.ReadInstalledSequence(dir, "0.2.0-alpha") == -1, "nothing recorded: unknown");
			UpdateApply.WriteInstalled(dir, "0.2.0-alpha", 7);
			Check(UpdateApply.ReadInstalledSequence(dir, "0.2.0-alpha") == 7, "recorded sequence read back");
			Check(UpdateApply.ReadInstalledSequence(dir, "0.1.9-alpha") == -1, "recorded for another version: unknown");
			UpdateApply.WriteResult(dir, false, "0.1.9-alpha", "0.2.0-alpha", "VisualBeef 0.2.0-alpha did not start correctly (\"x\"), so 0.1.9-alpha was restored.");
			UpdateService svc = scope .();
			svc.UpdateDir.Set(dir);
			String msg = scope .();
			Check(svc.TakeLastResult(let ok, msg) && !ok && msg.Contains("(\"x\")"), "last result read (quotes escaped)");
			msg.Clear();
			Check(!svc.TakeLastResult(let ok2, msg), "the last result is shown once");
		}

		static void Headers()
		{
			Console.WriteLine("HTTP headers");
			UpdateHttp.Response r = scope .();
			UpdateHttp.ParseHeaders("HTTP/1.1 302 Found\r\nLocation: https://example/x\r\nETag: \"redirect\"\r\n\r\nHTTP/2 200\r\ncontent-type: application/octet-stream\r\netag: \"0x8DC\"\r\n\r\n", r);
			Check(r.Status == 200 && r.ETag == "\"0x8DC\"", "status and ETag of the last hop");
			UpdateHttp.Response r2 = scope .();
			UpdateHttp.ParseHeaders("HTTP/2 304\r\n\r\n", r2);
			Check(r2.Status == 304 && r2.ETag.IsEmpty, "304 Not Modified read");
		}
	}
}
