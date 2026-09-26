using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Top-level launcher for audio.cpp Desk.
// Sets the app root to this executable's directory, then starts the real
// Flutter app from bin\audio_cpp_desk.exe (which keeps its DLLs and data/).
//
// Single-instance: a named mutex gates the launcher. When an instance is
// already running, the existing app window is brought to the foreground
// instead of starting another copy.
class Launcher
{
    private const string MutexName = @"Local\audio_cpp_desk_single_instance_v1";
    private const string AppProcessName = "audio_cpp_desk";

    private const int SW_RESTORE = 9;
    private const int SW_SHOW = 5;

    private const uint MB_YESNO = 0x00000004;
    private const uint MB_ICONERROR = 0x00000010;
    private const int IDYES = 6;
    private const uint LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryW(string fileName);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryExW(string fileName, IntPtr file, uint flags);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    private static IntPtr FindAppWindow()
    {
        try
        {
            foreach (var p in Process.GetProcessesByName(AppProcessName))
            {
                try
                {
                    if (p.MainWindowHandle != IntPtr.Zero) return p.MainWindowHandle;
                }
                catch { }
            }
        }
        catch { }
        return IntPtr.Zero;
    }

    private static void ActivateExisting()
    {
        // The window may not exist yet if it was just started; poll briefly.
        IntPtr h = IntPtr.Zero;
        for (int i = 0; i < 50 && h == IntPtr.Zero; i++)
        {
            h = FindAppWindow();
            if (h == IntPtr.Zero) Thread.Sleep(100);
        }
        if (h == IntPtr.Zero) return;
        ShowWindow(h, IsIconic(h) ? SW_RESTORE : SW_SHOW);
        SetForegroundWindow(h);
    }

    private static bool VcRuntimeAvailable(string binDir)
    {
        // Prefer the app-local copy that ships with the package.
        string local = Path.Combine(binDir, "vcruntime140.dll");
        if (File.Exists(local)
            && LoadLibraryExW(local, IntPtr.Zero, LOAD_WITH_ALTERED_SEARCH_PATH) != IntPtr.Zero)
        {
            return true;
        }
        // Fall back to a system-wide VC++ Redistributable installation.
        return LoadLibraryW("vcruntime140.dll") != IntPtr.Zero
            && LoadLibraryW("msvcp140.dll") != IntPtr.Zero;
    }

    private static void ShowVcRuntimeError()
    {
        const string url = "https://aka.ms/vs/17/release/vc_redist.x64.exe";
        bool zh = System.Globalization.CultureInfo.CurrentUICulture
            .TwoLetterISOLanguageName == "zh";
        string text = zh
            ? "缺少 Microsoft Visual C++ 运行库，无法启动。\n\n请安装 “Microsoft Visual C++ 2015–2022 Redistributable (x64)” 后重试。\n\n是否现在打开下载页面？"
            : "The Microsoft Visual C++ runtime is missing, so the app cannot start.\n\nPlease install “Microsoft Visual C++ 2015–2022 Redistributable (x64)” and try again.\n\nOpen the download page now?";
        int r = MessageBoxW(IntPtr.Zero, text, "audio.cpp Desk", MB_YESNO | MB_ICONERROR);
        if (r == IDYES)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
        }
    }

    [STAThread]
    static int Main(string[] args)
    {
        bool createdNew;
        using (var mutex = new Mutex(true, MutexName, out createdNew))
        {
            if (!createdNew)
            {
                // Already running: bring the existing window to the front.
                ActivateExisting();
                return 0;
            }

            try
            {
                string root = AppDomain.CurrentDomain.BaseDirectory;
                string bin = Path.Combine(root, "bin");
                string exe = Path.Combine(bin, "audio_cpp_desk.exe");
                Environment.SetEnvironmentVariable("AUDIOCPP_DESK_ROOT", root);

                if (!VcRuntimeAvailable(bin))
                {
                    ShowVcRuntimeError();
                    return 2;
                }

                var psi = new ProcessStartInfo();
                psi.FileName = exe;
                psi.WorkingDirectory = root;
                psi.UseShellExecute = false;

                var sb = new StringBuilder();
                foreach (var a in args)
                {
                    if (sb.Length > 0) sb.Append(' ');
                    sb.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
                }
                psi.Arguments = sb.ToString();

                var p = Process.Start(psi);
                p.WaitForExit();
                return p.ExitCode;
            }
            catch
            {
                return 1;
            }
            finally
            {
                mutex.ReleaseMutex();
            }
        }
    }
}
