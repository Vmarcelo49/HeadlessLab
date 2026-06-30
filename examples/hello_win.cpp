// hello_win.cpp — Minimal Windows console program that prints system info.
// Tests: stdout capture, environment variables, GetSystemInfo, GetVersionEx.
// Compile: x86_64-w64-mingw32-g++-win32 -O2 -o hello_win.exe hello_win.cpp \
//          -static-libgcc -static-libstdc++ -Wl,--subsystem,console
//
// This is a "real" Windows console program — no DX9, no GUI, just text output.
// Useful for testing the headless CLI's stdout capture and Wine's console subsystem.

#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char* argv[]) {
    printf("=== Hello from Windows console program (running under Wine) ===\n");
    printf("\n");

    // Print argv
    printf("argc = %d\n", argc);
    for (int i = 0; i < argc; i++) {
        printf("argv[%d] = \"%s\"\n", i, argv[i] ? argv[i] : "(null)");
    }
    printf("\n");

    // Print some environment variables
    printf("=== Environment ===\n");
    const char* env_vars[] = {"USERNAME", "USERPROFILE", "TEMP", "TMP",
                              "PATH", "SystemRoot", "COMSPEC", "WINDIR"};
    for (size_t i = 0; i < sizeof(env_vars)/sizeof(env_vars[0]); i++) {
        char value[32768];
        DWORD len = GetEnvironmentVariableA(env_vars[i], value, sizeof(value));
        if (len > 0 && len < sizeof(value)) {
            printf("  %s = %s\n", env_vars[i], value);
        } else {
            printf("  %s = (not set)\n", env_vars[i]);
        }
    }
    printf("\n");

    // Print system info
    printf("=== System Info ===\n");
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    printf("  Processor architecture: %u\n", si.wProcessorArchitecture);
    printf("  Number of processors: %u\n", si.dwNumberOfProcessors);
    printf("  Page size: %u bytes\n", si.dwPageSize);
    printf("  Active processor mask: 0x%x\n", (unsigned)si.dwActiveProcessorMask);

    MEMORYSTATUSEX ms;
    ms.dwLength = sizeof(ms);
    GlobalMemoryStatusEx(&ms);
    printf("  Memory load: %u%%\n", ms.dwMemoryLoad);
    printf("  Total physical memory: %.2f GB\n", (double)ms.ullTotalPhys / (1024*1024*1024));
    printf("  Available physical memory: %.2f GB\n", (double)ms.ullAvailPhys / (1024*1024*1024));
    printf("\n");

    // Print OS version
    printf("=== OS Version ===\n");
    OSVERSIONINFOA vi;
    vi.dwOSVersionInfoSize = sizeof(vi);
    // GetVersionEx is deprecated but works under Wine
    if (GetVersionExA(&vi)) {
        printf("  Windows version: %u.%u build %u\n",
               vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber);
        printf("  Service pack: %s\n", vi.szCSDVersion);
    }
    printf("\n");

    // Current directory
    char cwd[MAX_PATH];
    GetCurrentDirectoryA(sizeof(cwd), cwd);
    printf("Current directory: %s\n", cwd);

    // Computer name
    char computerName[MAX_COMPUTERNAME_LENGTH + 1];
    DWORD size = sizeof(computerName);
    GetComputerNameA(computerName, &size);
    printf("Computer name: %s\n", computerName);

    // User name
    char userName[256];
    size = sizeof(userName);
    GetUserNameA(userName, &size);
    printf("User name: %s\n", userName);

    printf("\n");
    printf("=== Done! Test successful. ===\n");
    return 0;
}
