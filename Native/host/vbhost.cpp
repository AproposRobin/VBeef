// VisualBeef native host.
// Owns the platform window (SDL2), the GL context, and the Dear ImGui + imnodes
// contexts. Everything else (all UI logic) lives in Beef and talks to ImGui and
// imnodes through cimgui / cimnodes, which are compiled into this same library.
//
// Exposed C API is intentionally tiny: init, begin/end frame, shutdown.

#include "imgui.h"
#include "imgui_impl_sdl2.h"
#include "imgui_impl_opengl3.h"
#include "imnodes.h"
namespace ImNodes = IMNODES_NAMESPACE;

#include <SDL.h>
#include <SDL_opengl.h>
#include <SDL_syswm.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <mutex>
#include <set>
#include <string>

#if defined(_WIN32)
#include <windows.h>
#include <shobjidl.h>
#else
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#if defined(_WIN32)
#define VBH_API extern "C" __declspec(dllexport)
#else
#define VBH_API extern "C" __attribute__((visibility("default")))
#endif

// Assert routing (docs/Architecture.md, "Host asserts"). IM_ASSERT (imconfig.h) and SDL's own
// assertions land in vbh_assert_failed, which never aborts and never shows a dialog: each distinct
// site (file and line) is reported once per run to the handler the editor registered with
// vbh_set_assert_handler, or to stderr when none is registered, and the call returns.
typedef void (*VbhAssertHandler)(const char* expr, const char* file, int line);
static VbhAssertHandler  gAssertHandler = nullptr;
static std::mutex        gAssertMutex;
static std::set<std::string> gAssertSites;

void vbh_assert_failed(const char* expr, const char* file, int line)
{
	if (file == nullptr)
		file = "?";
	if (expr == nullptr)
		expr = "?";
	{
		std::lock_guard<std::mutex> lock(gAssertMutex);
		if (!gAssertSites.insert(std::string(file) + ":" + std::to_string(line)).second)
			return; // this site already reported in this run
	}
	VbhAssertHandler handler = gAssertHandler;
	if (handler != nullptr)
		handler(expr, file, line);
	else
		fprintf(stderr, "vbhost: [ASSERT] %s at %s:%d\n", expr, file, line);
}

static SDL_AssertState VbhSdlAssert(const SDL_AssertData* data, void* userdata)
{
	(void)userdata;
	vbh_assert_failed(data->condition, data->filename, data->linenum);
	return SDL_ASSERTION_IGNORE;
}

static SDL_Window*   gWindow = nullptr;
static SDL_GLContext gGLContext = nullptr;
static bool          gQuitRequested = false;
static char          gDropPath[4096];
static bool          gHasDrop = false;
static float         gWindowScale = 1.0f; // UI scale (1.0 = 96 dpi) of the display the window is on

// The UI scale of one display. Windows reports the real per-monitor DPI (the process is
// per-monitor DPI aware). Elsewhere SDL only knows the *physical* DPI from the monitor's EDID,
// which says nothing about what the user chose (a 27" 4K panel reads 163 dpi, a bad EDID reads
// 25 or 400), so only VB_UI_SCALE / GDK_SCALE count there; the framebuffer scale of a Retina
// display is ImGui's DisplayFramebufferScale, not a font scale.
static float DisplayScale(int displayIndex)
{
	float scale = 1.0f;
#if defined(_WIN32)
	float ddpi = 0;
	if (displayIndex >= 0 && SDL_GetDisplayDPI(displayIndex, &ddpi, nullptr, nullptr) == 0 && ddpi > 0)
		scale = ddpi / 96.0f;
#else
	(void)displayIndex;
	const char* env = getenv("VB_UI_SCALE");
	if (env == nullptr || atof(env) <= 0)
		env = getenv("GDK_SCALE");
	if (env != nullptr && atof(env) > 0)
		scale = (float)atof(env);
#endif
	if (scale < 1.0f) scale = 1.0f;
	if (scale > 3.0f) scale = 3.0f;
	return scale;
}

static bool FileExists(const char* path)
{
	FILE* f = fopen(path, "rb");
	if (f == nullptr)
		return false;
	fclose(f);
	return true;
}

static void LoadFonts(float scale)
{
	ImGuiIO& io = ImGui::GetIO();
	const char* candidates[] = {
		"C:\\Windows\\Fonts\\segoeui.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"/usr/share/fonts/TTF/DejaVuSans.ttf",
		"/System/Library/Fonts/SFNS.ttf",
	};
	for (const char* path : candidates)
	{
		if (FileExists(path))
		{
			if (io.Fonts->AddFontFromFileTTF(path, 16.0f * scale) != nullptr)
				break;
		}
	}
	if (io.Fonts->Fonts.Size == 0)
		io.Fonts->AddFontDefault();

	// Monospace font (index 1) for code panels.
	const char* monoCandidates[] = {
		"C:\\Windows\\Fonts\\consola.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	};
	bool monoLoaded = false;
	for (const char* path : monoCandidates)
	{
		if (FileExists(path) && io.Fonts->AddFontFromFileTTF(path, 15.0f * scale) != nullptr)
		{
			monoLoaded = true;
			break;
		}
	}
	if (!monoLoaded)
		io.Fonts->AddFontDefault();
}

// Unreal-editor-like dark theme.
static void ApplyStyle()
{
	ImGuiStyle& s = ImGui::GetStyle();
	ImGui::StyleColorsDark(&s);
	s.WindowRounding = 2.0f;
	s.FrameRounding = 3.0f;
	s.TabRounding = 3.0f;
	s.GrabRounding = 3.0f;
	s.PopupRounding = 3.0f;
	s.ScrollbarRounding = 3.0f;
	s.FramePadding = ImVec2(6, 4);
	s.ItemSpacing = ImVec2(6, 5);
	s.WindowBorderSize = 1.0f;

	ImVec4* c = s.Colors;
	c[ImGuiCol_WindowBg]           = ImVec4(0.086f, 0.086f, 0.086f, 1.00f);
	c[ImGuiCol_ChildBg]            = ImVec4(0.086f, 0.086f, 0.086f, 1.00f);
	c[ImGuiCol_PopupBg]            = ImVec4(0.10f, 0.10f, 0.10f, 0.98f);
	c[ImGuiCol_Border]             = ImVec4(0.02f, 0.02f, 0.02f, 1.00f);
	c[ImGuiCol_FrameBg]            = ImVec4(0.06f, 0.06f, 0.06f, 1.00f);
	c[ImGuiCol_FrameBgHovered]     = ImVec4(0.16f, 0.16f, 0.16f, 1.00f);
	c[ImGuiCol_FrameBgActive]      = ImVec4(0.20f, 0.20f, 0.20f, 1.00f);
	c[ImGuiCol_TitleBg]            = ImVec4(0.05f, 0.05f, 0.05f, 1.00f);
	c[ImGuiCol_TitleBgActive]      = ImVec4(0.05f, 0.05f, 0.05f, 1.00f);
	c[ImGuiCol_MenuBarBg]          = ImVec4(0.08f, 0.08f, 0.08f, 1.00f);
	c[ImGuiCol_Header]             = ImVec4(0.18f, 0.18f, 0.18f, 1.00f);
	c[ImGuiCol_HeaderHovered]      = ImVec4(0.25f, 0.25f, 0.25f, 1.00f);
	c[ImGuiCol_HeaderActive]       = ImVec4(0.05f, 0.44f, 0.86f, 1.00f);
	c[ImGuiCol_Button]             = ImVec4(0.20f, 0.20f, 0.20f, 1.00f);
	c[ImGuiCol_ButtonHovered]      = ImVec4(0.28f, 0.28f, 0.28f, 1.00f);
	c[ImGuiCol_ButtonActive]       = ImVec4(0.05f, 0.44f, 0.86f, 1.00f);
	c[ImGuiCol_Tab]                = ImVec4(0.08f, 0.08f, 0.08f, 1.00f);
	c[ImGuiCol_TabHovered]         = ImVec4(0.22f, 0.22f, 0.22f, 1.00f);
	c[ImGuiCol_TabSelected]        = ImVec4(0.14f, 0.14f, 0.14f, 1.00f);
	c[ImGuiCol_TabSelectedOverline]= ImVec4(0.05f, 0.44f, 0.86f, 1.00f);
	c[ImGuiCol_TabDimmed]          = ImVec4(0.06f, 0.06f, 0.06f, 1.00f);
	c[ImGuiCol_TabDimmedSelected]  = ImVec4(0.12f, 0.12f, 0.12f, 1.00f);
	c[ImGuiCol_CheckMark]          = ImVec4(0.05f, 0.55f, 0.95f, 1.00f);
	c[ImGuiCol_SliderGrab]         = ImVec4(0.05f, 0.44f, 0.86f, 1.00f);
	c[ImGuiCol_Separator]          = ImVec4(0.03f, 0.03f, 0.03f, 1.00f);
	c[ImGuiCol_DockingPreview]     = ImVec4(0.05f, 0.44f, 0.86f, 0.70f);
	c[ImGuiCol_TextSelectedBg]     = ImVec4(0.05f, 0.44f, 0.86f, 0.45f);

	ImNodesStyle& ns = ImNodes::GetStyle();
	ImNodes::StyleColorsDark(&ns);
	ns.NodeCornerRounding = 6.0f;
	ns.NodePadding = ImVec2(10, 6);
	ns.NodeBorderThickness = 1.5f;
	ns.LinkThickness = 2.6f;
	ns.LinkLineSegmentsPerLength = 0.12f;
	ns.PinCircleRadius = 5.0f;
	ns.PinTriangleSideLength = 11.0f;
	ns.PinQuadSideLength = 9.0f;
	ns.PinOffset = 0.0f;
	ns.GridSpacing = 16.0f;
	ns.Flags |= ImNodesStyleFlags_GridLinesPrimary | ImNodesStyleFlags_GridSnapping;
	ns.Colors[ImNodesCol_GridBackground]          = IM_COL32(38, 38, 38, 255);
	ns.Colors[ImNodesCol_GridLine]                = IM_COL32(52, 52, 52, 255);
	ns.Colors[ImNodesCol_GridLinePrimary]         = IM_COL32(20, 20, 20, 255);
	ns.Colors[ImNodesCol_NodeBackground]          = IM_COL32(24, 24, 24, 235);
	ns.Colors[ImNodesCol_NodeBackgroundHovered]   = IM_COL32(30, 30, 30, 240);
	ns.Colors[ImNodesCol_NodeBackgroundSelected]  = IM_COL32(30, 30, 30, 245);
	ns.Colors[ImNodesCol_NodeOutline]             = IM_COL32(10, 10, 10, 255);
	ns.Colors[ImNodesCol_Link]                    = IM_COL32(230, 230, 230, 255);
	ns.Colors[ImNodesCol_LinkHovered]             = IM_COL32(255, 255, 255, 255);
	ns.Colors[ImNodesCol_LinkSelected]            = IM_COL32(255, 196, 0, 255);
	ns.Colors[ImNodesCol_BoxSelector]             = IM_COL32(255, 196, 0, 40);
	ns.Colors[ImNodesCol_BoxSelectorOutline]      = IM_COL32(255, 196, 0, 180);
	ns.Colors[ImNodesCol_MiniMapBackground]       = IM_COL32(20, 20, 20, 200);
}

// The editor's handler for host asserts (Beef: VbhAssertHandler). Registered before vbh_init, so
// asserts raised while the window is created are reported too. NULL restores the stderr line.
VBH_API void vbh_set_assert_handler(VbhAssertHandler handler)
{
	gAssertHandler = handler;
}

VBH_API int vbh_init(const char* title, int width, int height)
{
	SDL_SetAssertionHandler(VbhSdlAssert, nullptr);
	// Let Windows tell us the real DPI instead of bitmap-scaling a blurry window.
#ifdef SDL_HINT_WINDOWS_DPI_AWARENESS
	SDL_SetHint(SDL_HINT_WINDOWS_DPI_AWARENESS, "permonitorv2");
#endif
	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0)
	{
		fprintf(stderr, "vbhost: SDL_Init failed: %s\n", SDL_GetError());
		return 0;
	}

#if defined(__APPLE__)
	const char* glslVersion = "#version 150";
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
#else
	const char* glslVersion = "#version 130";
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, 0);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
#endif
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
	SDL_SetHint(SDL_HINT_IME_SHOW_UI, "1");

	// Open on the display the mouse is on (the user's current monitor), sized for that display.
	int startDisplay = 0;
	{
		int mx = 0, my = 0;
		SDL_GetGlobalMouseState(&mx, &my);
		int count = SDL_GetNumVideoDisplays();
		for (int d = 0; d < count; d++)
		{
			SDL_Rect r;
			if (SDL_GetDisplayBounds(d, &r) == 0 && mx >= r.x && mx < r.x + r.w && my >= r.y && my < r.y + r.h)
			{
				startDisplay = d;
				break;
			}
		}
	}
	float dpiScale = DisplayScale(startDisplay);

	SDL_WindowFlags flags = (SDL_WindowFlags)(SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
	gWindow = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED_DISPLAY(startDisplay), SDL_WINDOWPOS_CENTERED_DISPLAY(startDisplay),
		(int)(width * dpiScale), (int)(height * dpiScale), flags);
	if (gWindow == nullptr)
	{
		fprintf(stderr, "vbhost: SDL_CreateWindow failed: %s\n", SDL_GetError());
		return 0;
	}
	{
		// The window's own display (the platform may have placed it elsewhere): its scale is the one that counts.
		int actual = SDL_GetWindowDisplayIndex(gWindow);
		if (actual >= 0 && actual != startDisplay)
			dpiScale = DisplayScale(actual);
		gWindowScale = dpiScale;
	}
	gGLContext = SDL_GL_CreateContext(gWindow);
	if (gGLContext == nullptr)
	{
		fprintf(stderr, "vbhost: SDL_GL_CreateContext failed: %s\n", SDL_GetError());
		return 0;
	}
	SDL_GL_MakeCurrent(gWindow, gGLContext);
	SDL_GL_SetSwapInterval(1);
	SDL_EventState(SDL_DROPFILE, SDL_ENABLE);

	IMGUI_CHECKVERSION();
	ImGui::CreateContext();
	ImNodes::CreateContext();
	ImGuiIO& io = ImGui::GetIO();
	io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
	io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
	io.IniFilename = "VisualBeef_layout.ini";

	// Ctrl + left drag pans the graph too (middle/right mouse are the defaults in imnodes).
	ImNodesIO& nio = ImNodes::GetIO();
	nio.LinkDetachWithModifierClick.Modifier = &ImGui::GetIO().KeyAlt;
	nio.MultipleSelectModifier.Modifier = &ImGui::GetIO().KeyCtrl;

	LoadFonts(dpiScale);
	ApplyStyle();
	ImGui::GetStyle().ScaleAllSizes(dpiScale);

	ImGui_ImplSDL2_InitForOpenGL(gWindow, gGLContext);
	ImGui_ImplOpenGL3_Init(glslVersion);
	return 1;
}

// Pumps events and starts an ImGui frame. Returns 0 once the user closed the window.
VBH_API int vbh_begin_frame()
{
	SDL_Event event;
	while (SDL_PollEvent(&event))
	{
		ImGui_ImplSDL2_ProcessEvent(&event);
		if (event.type == SDL_QUIT)
			gQuitRequested = true;
		if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_CLOSE &&
			event.window.windowID == SDL_GetWindowID(gWindow))
			gQuitRequested = true;
		if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_DISPLAY_CHANGED &&
			event.window.windowID == SDL_GetWindowID(gWindow))
			gWindowScale = DisplayScale(event.window.data1); // data1 = the new display index
		if (event.type == SDL_DROPFILE)
		{
			snprintf(gDropPath, sizeof(gDropPath), "%s", event.drop.file);
			gHasDrop = true;
			SDL_free(event.drop.file);
		}
	}
	if (SDL_GetWindowFlags(gWindow) & SDL_WINDOW_MINIMIZED)
		SDL_Delay(10);

	ImGui_ImplOpenGL3_NewFrame();
	ImGui_ImplSDL2_NewFrame();
	ImGui::NewFrame();
	return gQuitRequested ? 0 : 1;
}

VBH_API void vbh_end_frame()
{
	ImGui::Render();
	ImGuiIO& io = ImGui::GetIO();
	glViewport(0, 0, (int)(io.DisplaySize.x * io.DisplayFramebufferScale.x), (int)(io.DisplaySize.y * io.DisplayFramebufferScale.y));
	glClearColor(0.08f, 0.08f, 0.08f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
	SDL_GL_SwapWindow(gWindow);
}

// Cancels a pending quit (e.g. "unsaved changes" prompt).
VBH_API void vbh_cancel_quit() { gQuitRequested = false; }

VBH_API void vbh_set_title(const char* title)
{
	if (gWindow != nullptr)
		SDL_SetWindowTitle(gWindow, title);
}

// Returns the path of a file dropped onto the window since the last call, or null.
VBH_API const char* vbh_poll_drop()
{
	if (!gHasDrop)
		return nullptr;
	gHasDrop = false;
	return gDropPath;
}

// The UI scale (1.0 = 96 dpi) of the display the window is on now; follows the window across
// monitors (SDL_WINDOWEVENT_DISPLAY_CHANGED). The editor reads it where the platform has no
// per-window DPI call of its own.
VBH_API float vbh_get_window_scale() { return gWindowScale; }

// Brings the window to the front and gives it the keyboard (restored first when minimized).
// Windows: the editor calls SetForegroundWindow on its HWND first, because SDL_RaiseWindow alone
// does not take focus for a background process. Linux: this is the only raise. A window manager
// may still only flag the window as wanting attention (focus-stealing prevention), which is the
// platform's call.
VBH_API void vbh_raise_window()
{
	if (gWindow == nullptr)
		return;
	if (SDL_GetWindowFlags(gWindow) & SDL_WINDOW_MINIMIZED)
		SDL_RestoreWindow(gWindow);
	SDL_RaiseWindow(gWindow);
}

// SDL_WindowFlags of the editor window (0 before vbh_init): minimized, input focus, ...
VBH_API unsigned int vbh_window_flags() { return gWindow != nullptr ? (unsigned int)SDL_GetWindowFlags(gWindow) : 0u; }

VBH_API ImFont* vbh_get_mono_font()
{
	ImGuiIO& io = ImGui::GetIO();
	return io.Fonts->Fonts.Size > 1 ? io.Fonts->Fonts[1] : nullptr;
}

VBH_API void vbh_shutdown()
{
	ImGui_ImplOpenGL3_Shutdown();
	ImGui_ImplSDL2_Shutdown();
	ImNodes::DestroyContext();
	ImGui::DestroyContext();
	if (gGLContext != nullptr)
		SDL_GL_DeleteContext(gGLContext);
	if (gWindow != nullptr)
		SDL_DestroyWindow(gWindow);
	SDL_Quit();
}

// Native file / folder picker.
//   pickFolder: 0 = pick a .bf file, 1 = pick a folder
// Returns 1 when something was chosen (UTF-8 path in outPath), 0 when cancelled,
// -1 when no native dialog is available (callers fall back to the ImGui browser).
VBH_API int vbh_native_dialog(int pickFolder, const char* initialDir, char* outPath, int outCap)
{
	if (outPath == nullptr || outCap <= 0)
		return -1;
	outPath[0] = 0;
#if defined(_WIN32)
	HRESULT initHr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
	IFileOpenDialog* dlg = nullptr;
	HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_IFileOpenDialog, (void**)&dlg);
	if (FAILED(hr) || dlg == nullptr)
	{
		if (SUCCEEDED(initHr))
			CoUninitialize();
		return -1;
	}
	DWORD opts = 0;
	dlg->GetOptions(&opts);
	opts |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
	if (pickFolder)
		opts |= FOS_PICKFOLDERS;
	else
		opts |= FOS_FILEMUSTEXIST;
	dlg->SetOptions(opts);
	if (pickFolder)
		dlg->SetTitle(L"Open Beef Project Folder");
	else
	{
		COMDLG_FILTERSPEC filters[] = { { L"Beef Source (*.bf)", L"*.bf" }, { L"All Files", L"*.*" } };
		dlg->SetFileTypes(2, filters);
		dlg->SetTitle(L"Open Beef File");
	}
	if (initialDir != nullptr && initialDir[0] != 0)
	{
		wchar_t wdir[4096];
		if (MultiByteToWideChar(CP_UTF8, 0, initialDir, -1, wdir, 4096) > 0)
		{
			for (wchar_t* c = wdir; *c; c++)
				if (*c == L'/')
					*c = L'\\';
			IShellItem* folder = nullptr;
			if (SUCCEEDED(SHCreateItemFromParsingName(wdir, nullptr, IID_PPV_ARGS(&folder))) && folder != nullptr)
			{
				dlg->SetFolder(folder);
				folder->Release();
			}
		}
	}
	HWND owner = nullptr;
	if (gWindow != nullptr)
	{
		SDL_SysWMinfo info;
		SDL_VERSION(&info.version);
		if (SDL_GetWindowWMInfo(gWindow, &info))
			owner = info.info.win.window;
	}
	int result = 0;
	hr = dlg->Show(owner);
	if (SUCCEEDED(hr))
	{
		IShellItem* item = nullptr;
		if (SUCCEEDED(dlg->GetResult(&item)) && item != nullptr)
		{
			PWSTR wpath = nullptr;
			if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &wpath)) && wpath != nullptr)
			{
				if (WideCharToMultiByte(CP_UTF8, 0, wpath, -1, outPath, outCap, nullptr, nullptr) > 0)
					result = 1;
				CoTaskMemFree(wpath);
			}
			item->Release();
		}
	}
	dlg->Release();
	if (SUCCEEDED(initHr))
		CoUninitialize();
	return result;
#else
	// Linux: zenity when it is installed, started without a shell (fork + execvp), so the
	// folder name is one argument and never shell text. Exit 127 = zenity is missing.
	char filenameArg[4200];
	filenameArg[0] = 0;
	if (initialDir != nullptr && initialDir[0] != 0)
		snprintf(filenameArg, sizeof(filenameArg), "--filename=%s/", initialDir);
	const char* argv[8];
	int argc = 0;
	argv[argc++] = "zenity";
	argv[argc++] = "--file-selection";
	if (pickFolder)
		argv[argc++] = "--directory";
	else
	{
		argv[argc++] = "--file-filter=Beef source | *.bf";
		argv[argc++] = "--file-filter=All files | *";
	}
	if (filenameArg[0] != 0)
		argv[argc++] = filenameArg;
	argv[argc] = nullptr;
	int fds[2];
	if (pipe(fds) != 0)
		return -1;
	pid_t pid = fork();
	if (pid < 0)
	{
		close(fds[0]);
		close(fds[1]);
		return -1;
	}
	if (pid == 0)
	{
		dup2(fds[1], 1);
		close(fds[0]);
		close(fds[1]);
		int devNull = open("/dev/null", O_WRONLY);
		if (devNull >= 0)
			dup2(devNull, 2);
		execvp("zenity", (char* const*)argv);
		_exit(127);
	}
	close(fds[1]);
	int len = 0;
	while (len < outCap - 1)
	{
		ssize_t n = read(fds[0], outPath + len, (size_t)(outCap - 1 - len));
		if (n <= 0)
			break;
		len += (int)n;
	}
	outPath[len] = 0;
	close(fds[0]);
	int status = 0;
	waitpid(pid, &status, 0);
	if (WIFEXITED(status) && WEXITSTATUS(status) == 127)
		return -1;
	while (len > 0 && (outPath[len - 1] == '\n' || outPath[len - 1] == '\r'))
		outPath[--len] = 0;
	return len > 0 ? 1 : 0;
#endif
}
