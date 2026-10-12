using System;
using System.Collections;
using System.IO;
using ImGui;

namespace VisualBeef.Editor
{
	/// A picture of the documentation, uploaded as an OpenGL texture the first time a page shows it.
	class DocImage
	{
		public uint32 Tex;
		public int32 Width;
		public int32 Height;
		/// The file could not be loaded (missing, unreadable, or no decoder on this platform).
		public bool Failed;
	}

	/// Loads the PNG pictures of the documentation for the viewer. Windows decodes with GDI+ (gdiplus.dll) and uploads
	/// with the OpenGL 1.1 entry points of opengl32.dll, both found at run time so the editor links nothing new; the
	/// host's ImGui backend draws the texture. Elsewhere the pictures are not shown (the viewer draws a labelled box).
	/// Call from the frame loop only: the OpenGL context is current there.
	static class DocImages
	{
		[CRepr]
		struct TextureRef
		{
			public void* TexData;
			public uint64 TexId;
		}

		[CLink] static extern void ImDrawList_AddImage(ImDrawList* self, TextureRef tex_ref, ImVec2 p_min, ImVec2 p_max, ImVec2 uv_min, ImVec2 uv_max, uint32 col);

		static Dictionary<String, DocImage> sCache = new .() ~ { for (let kv in _) { delete kv.key; delete kv.value; } delete _; };

		/// The picture at `fullPath` (loaded on first use; a failure is remembered). Never null.
		public static DocImage Get(StringView fullPath)
		{
			String key = scope .(fullPath);
			key.ToLower();
			key.Replace('/', '\\');
			if (sCache.TryGetValue(key, let found))
				return found;
			let img = new DocImage();
			sCache[new String(key)] = img;
#if BF_PLATFORM_WINDOWS
			if (!Win.Load(fullPath, img))
				img.Failed = true;
#else
			img.Failed = true;
#endif
			return img;
		}

		/// Draws `img` into the rectangle.
		public static void Draw(ImDrawList* dl, DocImage img, ImVec2 min, ImVec2 max, uint32 tint = 0xFFFFFFFF)
		{
			if (img.Failed || img.Tex == 0)
				return;
			TextureRef tex = .();
			tex.TexData = null;
			tex.TexId = img.Tex;
			ImDrawList_AddImage(dl, tex, min, max, .(0, 0), .(1, 1), tint);
		}

#if BF_PLATFORM_WINDOWS
		static class Win
		{
			[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
			static extern void* LoadLibraryA(char8* name);
			[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
			static extern void* GetProcAddress(void* module, char8* name);

			[CRepr]
			struct StartupInput
			{
				public uint32 Version;
				public void* DebugCallback;
				public int32 SuppressBackgroundThread;
				public int32 SuppressExternalCodecs;
			}

			[CRepr]
			struct GpRect
			{
				public int32 X, Y, Width, Height;
			}

			[CRepr]
			struct BitmapData
			{
				public uint32 Width;
				public uint32 Height;
				public int32 Stride;
				public int32 PixelFormat;
				public void* Scan0;
				public uint Reserved;
			}

			static bool sTried;
			static bool sOk;
			static uint sToken;
			static function int32(uint* token, StartupInput* input, void* output) sStartup;
			static function int32(uint16* file, void** bitmap) sFromFile;
			static function int32(void* image, uint32* v) sWidth;
			static function int32(void* image, uint32* v) sHeight;
			static function int32(void* bitmap, GpRect* rect, uint32 flags, int32 format, BitmapData* data) sLock;
			static function int32(void* bitmap, BitmapData* data) sUnlock;
			static function int32(void* image) sDispose;
			static function void(int32 n, uint32* tex) sGenTextures;
			static function void(uint32 target, uint32 tex) sBindTexture;
			static function void(uint32 target, uint32 name, int32 value) sTexParameteri;
			static function void(uint32 target, int32 level, int32 internalFormat, int32 w, int32 h, int32 border, uint32 format, uint32 type, void* data) sTexImage2D;
			static function void(uint32 name, int32* value) sGetIntegerv;
			static function void(uint32 name, int32 value) sPixelStorei;
			static function void(uint32 target) sGenerateMipmap;

			static bool Init()
			{
				if (sTried)
					return sOk;
				sTried = true;
				let gdi = LoadLibraryA("gdiplus.dll");
				let gl = LoadLibraryA("opengl32.dll");
				if (gdi == null || gl == null)
					return false;
				sStartup = (.)GetProcAddress(gdi, "GdiplusStartup");
				sFromFile = (.)GetProcAddress(gdi, "GdipCreateBitmapFromFile");
				sWidth = (.)GetProcAddress(gdi, "GdipGetImageWidth");
				sHeight = (.)GetProcAddress(gdi, "GdipGetImageHeight");
				sLock = (.)GetProcAddress(gdi, "GdipBitmapLockBits");
				sUnlock = (.)GetProcAddress(gdi, "GdipBitmapUnlockBits");
				sDispose = (.)GetProcAddress(gdi, "GdipDisposeImage");
				sGenTextures = (.)GetProcAddress(gl, "glGenTextures");
				sBindTexture = (.)GetProcAddress(gl, "glBindTexture");
				sTexParameteri = (.)GetProcAddress(gl, "glTexParameteri");
				sTexImage2D = (.)GetProcAddress(gl, "glTexImage2D");
				sGetIntegerv = (.)GetProcAddress(gl, "glGetIntegerv");
				sPixelStorei = (.)GetProcAddress(gl, "glPixelStorei");
				// glGenerateMipmap is a GL 3 function: found through wglGetProcAddress when the context has it.
				let wglGet = (function void*(char8*))GetProcAddress(gl, "wglGetProcAddress");
				if (wglGet != null)
					sGenerateMipmap = (.)wglGet("glGenerateMipmap");
				if (sStartup == null || sFromFile == null || sWidth == null || sHeight == null || sLock == null || sUnlock == null || sDispose == null ||
					sGenTextures == null || sBindTexture == null || sTexParameteri == null || sTexImage2D == null || sGetIntegerv == null || sPixelStorei == null)
					return false;
				StartupInput input = .();
				input.Version = 1;
				if (sStartup(&sToken, &input, null) != 0)
					return false;
				sOk = true;
				return true;
			}

			public static bool Load(StringView path, DocImage img)
			{
				if (!Init() || !File.Exists(path))
					return false;
				// UTF-16 file name.
				List<uint16> wide = scope .();
				for (let c in path.DecodedChars)
				{
					uint32 cp = (uint32)c;
					if (cp >= 0x10000)
					{
						cp -= 0x10000;
						wide.Add((uint16)(0xD800 + (cp >> 10)));
						wide.Add((uint16)(0xDC00 + (cp & 0x3FF)));
					}
					else
						wide.Add((uint16)cp);
				}
				wide.Add(0);
				void* bitmap = null;
				if (sFromFile(wide.Ptr, &bitmap) != 0 || bitmap == null)
					return false;
				defer sDispose(bitmap);
				uint32 w = 0;
				uint32 h = 0;
				sWidth(bitmap, &w);
				sHeight(bitmap, &h);
				if (w == 0 || h == 0 || w > 8192 || h > 8192)
					return false;
				GpRect rect = .();
				rect.Width = (int32)w;
				rect.Height = (int32)h;
				BitmapData data = .();
				// ImageLockModeRead = 1, PixelFormat32bppARGB = 0x26200A: bytes B, G, R, A in memory.
				if (sLock(bitmap, &rect, 1, 0x26200A, &data) != 0 || data.Scan0 == null)
					return false;
				defer sUnlock(bitmap, &data);
				uint8[] rgba = new uint8[(int)w * (int)h * 4];
				defer delete rgba;
				for (int y < (int)h)
				{
					uint8* src = (uint8*)data.Scan0 + (int)data.Stride * y;
					uint8* dst = &rgba[y * (int)w * 4];
					for (int x < (int)w)
					{
						dst[x * 4 + 0] = src[x * 4 + 2];
						dst[x * 4 + 1] = src[x * 4 + 1];
						dst[x * 4 + 2] = src[x * 4 + 0];
						dst[x * 4 + 3] = src[x * 4 + 3];
					}
				}
				int32 previous = 0;
				sGetIntegerv(0x8069 /* GL_TEXTURE_BINDING_2D */, &previous);
				uint32 tex = 0;
				sGenTextures(1, &tex);
				if (tex == 0)
					return false;
				sBindTexture(0x0DE1 /* GL_TEXTURE_2D */, tex);
				sPixelStorei(0x0CF5 /* GL_UNPACK_ALIGNMENT */, 4);
				sPixelStorei(0x0CF2 /* GL_UNPACK_ROW_LENGTH */, 0);
				sTexParameteri(0x0DE1, 0x2802 /* GL_TEXTURE_WRAP_S */, 0x812F /* GL_CLAMP_TO_EDGE */);
				sTexParameteri(0x0DE1, 0x2803 /* GL_TEXTURE_WRAP_T */, 0x812F);
				sTexParameteri(0x0DE1, 0x2800 /* GL_TEXTURE_MAG_FILTER */, 0x2601 /* GL_LINEAR */);
				sTexParameteri(0x0DE1, 0x2801 /* GL_TEXTURE_MIN_FILTER */, (sGenerateMipmap != null) ? 0x2703 /* GL_LINEAR_MIPMAP_LINEAR */ : 0x2601);
				sTexImage2D(0x0DE1, 0, 0x1908 /* GL_RGBA */, (int32)w, (int32)h, 0, 0x1908, 0x1401 /* GL_UNSIGNED_BYTE */, rgba.CArray());
				if (sGenerateMipmap != null)
					sGenerateMipmap(0x0DE1);
				sBindTexture(0x0DE1, (uint32)previous);
				img.Tex = tex;
				img.Width = (int32)w;
				img.Height = (int32)h;
				return true;
			}
		}
#endif
	}
}
