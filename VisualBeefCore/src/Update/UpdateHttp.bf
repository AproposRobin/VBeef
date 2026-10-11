// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).

using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace VisualBeef.Update
{
	/// HTTPS GETs for the updater through the system's curl (Windows 10 and later ship %SystemRoot%\System32\curl.exe;
	/// Linux desktops ship /usr/bin/curl), so no TLS code is linked into the editor. Runs on the updater's worker thread
	/// only. HTTPS only, redirects followed (GitHub's release downloads redirect to its file host), a size cap, timeouts.
	public static class UpdateHttp
	{
		public enum Outcome
		{
			/// Got an answer (see Status).
			Ok,
			/// No curl on this system.
			NoClient,
			/// Could not reach the server (offline, DNS, TLS, proxy, timeout).
			Unreachable,
			/// The answer was larger than allowed.
			TooLarge,
			/// Cancelled by the caller.
			Cancelled,
			/// curl failed in another way, or wrote no headers.
			Failed
		}

		public class Response
		{
			public Outcome Outcome;
			public int32 Status;
			public int32 CurlExit;
			public String ETag = new .() ~ delete _;
		}

		/// The curl to use: VB_UPDATE_CURL (tests), else the system's own.
		public static bool FindCurl(String outPath)
		{
			String env = scope .();
			if (Environment.GetEnvironmentVariable("VB_UPDATE_CURL", env) case .Ok && !env.IsEmpty && File.Exists(env))
			{
				outPath.Set(env);
				return true;
			}
#if BF_PLATFORM_WINDOWS
			String root = scope .();
			if (Environment.GetEnvironmentVariable("SystemRoot", root) case .Err || root.IsEmpty)
				root.Set("C:\\Windows");
			let p = scope String()..AppendF("{}\\System32\\curl.exe", root);
			if (File.Exists(p))
			{
				outPath.Set(p);
				return true;
			}
#else
			StringView[3] candidates = .("/usr/bin/curl", "/bin/curl", "/usr/local/bin/curl");
			for (let p in candidates)
			{
				if (File.Exists(p))
				{
					outPath.Set(p);
					return true;
				}
			}
#endif
			return false;
		}

		static void Quote(String args, StringView value)
		{
			args.Append(" \"");
			for (let c in value.RawChars)
			{
				if (c == '"')
					args.Append("\\\"");
				else
					args.Append(c);
			}
			args.Append('"');
		}

		/// Reads the status and ETag of the last response in a curl -D file (one block per redirect hop).
		public static void ParseHeaders(StringView text, Response response)
		{
			for (var line in text.Split('\n'))
			{
				line.Trim();
				if (line.StartsWith("HTTP/"))
				{
					response.Status = 0;
					response.ETag.Clear();
					int sp = line.IndexOf(' ');
					if (sp > 0)
					{
						var rest = line.Substring(sp + 1);
						int sp2 = rest.IndexOf(' ');
						if (sp2 > 0)
							rest = rest.Substring(0, sp2);
						if (int32.Parse(rest) case .Ok(let code))
							response.Status = code;
					}
					continue;
				}
				int colon = line.IndexOf(':');
				if (colon <= 0)
					continue;
				var name = line.Substring(0, colon);
				name.Trim();
				if (name.Equals("etag", true))
				{
					var v = line.Substring(colon + 1);
					v.Trim();
					if (v.Length <= 200)
						response.ETag.Set(v);
				}
			}
		}

		static int64 FileLength(StringView path)
		{
			FileStream fs = scope .();
			if (fs.Open(path, .Read, .ReadWrite) case .Err)
				return 0;
			return fs.Length;
		}

		/// GET `url` into `outFile`. `etag` (may be empty) is sent as If-None-Match; a 304 leaves `outFile` alone.
		/// `onProgress(received)` is called about four times a second while the body arrives; `cancel` set to true stops it.
		public static void Get(StringView url, StringView outFile, StringView etag, int64 maxBytes, int32 connectSeconds, int32 maxSeconds,
			bool githubApi, Response response, delegate void(int64 received) onProgress = null, bool* cancel = null)
		{
			String curl = scope .();
			if (!FindCurl(curl))
			{
				response.Outcome = .NoClient;
				return;
			}
			String headerFile = scope .(outFile);
			headerFile.Append(".headers");
			File.Delete(headerFile).IgnoreError(); // absent is fine
			String args = scope .();
			args.Append("-sS -L --max-redirs 5 --proto =https --proto-redir =https");
			args.AppendF(" --connect-timeout {}", connectSeconds);
			if (maxSeconds > 0)
				args.AppendF(" --max-time {}", maxSeconds);
			else
				args.Append(" --speed-limit 1024 --speed-time 60");
			if (maxBytes > 0)
				args.AppendF(" --max-filesize {}", maxBytes);
			args.Append(" -A");
			Quote(args, scope $"VisualBeef/{VisualBeef.Document.VisualBeefInfo.Version}");
			if (githubApi)
			{
				args.Append(" -H");
				Quote(args, "Accept: application/vnd.github+json");
			}
			if (!etag.IsEmpty)
			{
				args.Append(" -H");
				Quote(args, scope $"If-None-Match: {etag}");
			}
			args.Append(" -D");
			Quote(args, headerFile);
			args.Append(" -o");
			Quote(args, outFile);
			Quote(args, url);

			ProcessStartInfo psi = scope .();
			psi.SetFileName(curl);
			psi.SetArguments(args);
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
			{
				response.Outcome = .NoClient;
				return;
			}
			int64 lastReported = -1;
			while (!proc.WaitFor(250))
			{
				if (cancel != null && *cancel)
				{
					proc.Kill();
					proc.WaitFor(5000);
					response.Outcome = .Cancelled;
					File.Delete(headerFile).IgnoreError(); // scratch file
					return;
				}
				if (onProgress != null)
				{
					let n = FileLength(outFile);
					if (n != lastReported)
					{
						lastReported = n;
						onProgress(n);
					}
				}
			}
			response.CurlExit = (int32)proc.ExitCode;
			String headers = scope .();
			File.ReadAllText(headerFile, headers).IgnoreError(); // empty when curl got no answer
			File.Delete(headerFile).IgnoreError(); // scratch file
			ParseHeaders(headers, response);
			switch (response.CurlExit)
			{
			case 0:
				response.Outcome = response.Status > 0 ? .Ok : .Failed;
			case 63:
				response.Outcome = .TooLarge;
			case 5, 6, 7, 28, 35, 51, 52, 55, 56, 58, 59, 60, 77, 92, 97:
				// proxy / host not resolved, could not connect, timeout, TLS, connection reset ...
				response.Outcome = .Unreachable;
			default:
				response.Outcome = .Failed;
			}
			if (onProgress != null && response.Outcome == .Ok)
				onProgress(FileLength(outFile));
		}
	}
}
