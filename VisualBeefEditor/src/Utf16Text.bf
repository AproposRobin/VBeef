using System;
using System.Text;

namespace VisualBeef.Editor
{
	/// UTF-16 copies of strings for Win32Raw (CrashHandler.bf). `ToScopedNativeWChar!` gives
	/// UTF-16 on Windows but UTF-32 (wchar_t) on Linux, so Win32Raw callers use this instead.
	/// Same encoding as `ToScopedNativeWChar!` on Windows; the buffer is on the caller's stack.
	static class Utf16Text
	{
		public static mixin Scoped(StringView s)
		{
			int encodedLen = UTF16.GetEncodedLen(s);
			char16* buf = scope:mixin char16[encodedLen + 1]* (?);
			UTF16.Encode(s, buf, encodedLen);
			buf[encodedLen] = 0;
			buf
		}
	}
}
