// Stand-in for Steam's steamwebhelper.exe under Wine.
//
// Chromium (CEF 126) paints Steam's windows black under Wine 11, and its separate network-service process
// can't use Wine's winsock. Running it with software rendering in a single process avoids both.
//
// The original executable is kept next to this one as steamwebhelper_real.exe. Chromium re-launches itself for
// its helper processes (--type=...); those, if any, are passed through untouched.

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

// Lets Mythic tell this file apart from Steam's own steamwebhelper.exe, which Steam may put back on an update.
__attribute__((used)) static const char MYTHIC_MARKER[] = "MYTHIC-STEAM-WRAPPER-1";

static void log_line(const wchar_t *directory, const wchar_t *text) {
    wchar_t path[MAX_PATH * 2];
    _snwprintf(path, sizeof(path) / sizeof(path[0]), L"%lswrapper.log", directory);

    FILE *file = _wfopen(path, L"a, ccs=UTF-8");
    if (!file) return;
    fwprintf(file, L"%ls\n", text);
    fclose(file);
}

// Extra arguments for the browser process come from steamwebhelper_args.txt next to the wrapper, so they can
// be changed without rebuilding. Without that file, the defaults below apply.
static const wchar_t *DEFAULT_ARGUMENTS = L" --disable-gpu --single-process";

static wchar_t *extra_arguments(const wchar_t *directory) {
    wchar_t path[MAX_PATH * 2];
    _snwprintf(path, sizeof(path) / sizeof(path[0]), L"%lssteamwebhelper_args.txt", directory);

    FILE *file = _wfopen(path, L"rb");
    if (!file) return _wcsdup(DEFAULT_ARGUMENTS);

    char text[1024] = { 0 };
    size_t count = fread(text, 1, sizeof(text) - 1, file);
    fclose(file);
    text[count] = 0;

    while (count > 0 && (text[count - 1] == '\n' || text[count - 1] == '\r' || text[count - 1] == ' ')) text[--count] = 0;

    wchar_t *wide = malloc((count + 2) * sizeof(wchar_t));
    wide[0] = L' ';
    MultiByteToWideChar(CP_UTF8, 0, text, -1, wide + 1, (int)count + 1);
    return wide;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, LPWSTR unused, int show) {
    volatile char keep = MYTHIC_MARKER[0]; (void)keep;
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(NULL, self, MAX_PATH);

    wchar_t *slash = wcsrchr(self, L'\\');
    if (slash) *(slash + 1) = 0;

    wchar_t real[MAX_PATH * 2];
    _snwprintf(real, sizeof(real) / sizeof(real[0]), L"%lssteamwebhelper_real.exe", self);

    // Everything after the program name in the original command line.
    wchar_t *arguments = GetCommandLineW();
    if (*arguments == L'"') {
        arguments++;
        while (*arguments && *arguments != L'"') arguments++;
        if (*arguments) arguments++;
    } else {
        while (*arguments && *arguments != L' ' && *arguments != L'\t') arguments++;
    }
    while (*arguments == L' ' || *arguments == L'\t') arguments++;

    BOOL isHelperProcess = wcsstr(arguments, L"--type=") != NULL;

    wchar_t *extra = isHelperProcess ? NULL : extra_arguments(self);
    size_t length = wcslen(arguments) + wcslen(real) + (extra ? wcslen(extra) : 0) + 128;
    wchar_t *commandLine = malloc(length * sizeof(wchar_t));
    if (!commandLine) return 1;

    _snwprintf(commandLine, length, L"\"%ls\" %ls%ls", real, arguments, extra ? extra : L"");

    log_line(self, commandLine);

    STARTUPINFOW startup = { sizeof(startup) };
    PROCESS_INFORMATION process;

    if (!CreateProcessW(real, commandLine, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) {
        wchar_t message[64];
        _snwprintf(message, 64, L"CreateProcess failed: %lu", GetLastError());
        log_line(self, message);
        return 1;
    }

    DWORD started = GetTickCount();
    WaitForSingleObject(process.hProcess, INFINITE);

    DWORD code = 0;
    GetExitCodeProcess(process.hProcess, &code);

    wchar_t message[128];
    _snwprintf(message, 128, L"  -> %ls exited with 0x%08lx after %lu ms", isHelperProcess ? L"helper" : L"browser",
               code, GetTickCount() - started);
    log_line(self, message);

    return (int)code;
}
