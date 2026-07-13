using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace GitLabDuoSwitcher.Recorder
{
    internal static class NativeMethods
    {
        internal const int STD_INPUT_HANDLE = -10;
        internal const int STD_OUTPUT_HANDLE = -11;
        internal const uint ENABLE_PROCESSED_INPUT = 0x0001;
        internal const uint ENABLE_LINE_INPUT = 0x0002;
        internal const uint ENABLE_ECHO_INPUT = 0x0004;
        internal const uint ENABLE_WINDOW_INPUT = 0x0008;
        internal const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
        internal const uint ENABLE_EXTENDED_FLAGS = 0x0080;
        internal const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
        internal const uint ENABLE_PROCESSED_OUTPUT = 0x0001;
        internal const uint ENABLE_WRAP_AT_EOL_OUTPUT = 0x0002;
        internal const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
        internal const uint DISABLE_NEWLINE_AUTO_RETURN = 0x0008;
        internal const uint HANDLE_FLAG_INHERIT = 0x00000001;
        internal const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        internal const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        internal const uint INFINITE = 0xFFFFFFFF;
        internal const uint WAIT_OBJECT_0 = 0x00000000;
        internal const uint WAIT_FAILED = 0xFFFFFFFF;
        internal const uint PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;

        [StructLayout(LayoutKind.Sequential)]
        internal struct COORD
        {
            internal short X;
            internal short Y;

            internal COORD(short x, short y)
            {
                X = x;
                Y = y;
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct STARTUPINFO
        {
            internal int cb;
            internal string lpReserved;
            internal string lpDesktop;
            internal string lpTitle;
            internal int dwX;
            internal int dwY;
            internal int dwXSize;
            internal int dwYSize;
            internal int dwXCountChars;
            internal int dwYCountChars;
            internal int dwFillAttribute;
            internal int dwFlags;
            internal short wShowWindow;
            internal short cbReserved2;
            internal IntPtr lpReserved2;
            internal IntPtr hStdInput;
            internal IntPtr hStdOutput;
            internal IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct STARTUPINFOEX
        {
            internal STARTUPINFO StartupInfo;
            internal IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct PROCESS_INFORMATION
        {
            internal IntPtr hProcess;
            internal IntPtr hThread;
            internal uint dwProcessId;
            internal uint dwThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool SetConsoleCP(uint wCodePageID);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool SetConsoleOutputCP(uint wCodePageID);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, IntPtr lpPipeAttributes, int nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, int nNumberOfBytesToRead, out int lpNumberOfBytesRead, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, int nNumberOfBytesToWrite, out int lpNumberOfBytesWritten, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint dwFlags, out IntPtr phPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

        [DllImport("kernel32.dll")]
        internal static extern void ClosePseudoConsole(IntPtr hPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

        [DllImport("kernel32.dll")]
        internal static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool CreateProcessW(
            string lpApplicationName,
            StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            bool bInheritHandles,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            string lpCurrentDirectory,
            ref STARTUPINFOEX lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);
    }

    internal sealed class Options
    {
        internal string LogRoot;
        internal string BridgePath;
        internal string WorkingDirectory;
        internal string Profile;
        internal string Username;
        internal string Model;
        internal string ProjectName;
        internal string RunStatusPath;
        internal bool RawLogs;
        internal bool PresentOutput = true;
        internal bool ForwardInput = true;
        internal int MaximumSessions = 25;
        internal long MaximumStorageBytes = 300L * 1024L * 1024L;
        internal List<string> Command = new List<string>();

        internal static Options Parse(string[] args)
        {
            Options options = new Options();
            int i = 0;

            while (i < args.Length)
            {
                string arg = args[i];
                if (arg == "--")
                {
                    i++;
                    while (i < args.Length)
                    {
                        options.Command.Add(args[i]);
                        i++;
                    }
                    break;
                }

                if (i + 1 >= args.Length)
                {
                    throw new ArgumentException("Missing value for " + arg);
                }

                string value = args[i + 1];
                if (arg == "--log-root") options.LogRoot = value;
                else if (arg == "--bridge") options.BridgePath = value;
                else if (arg == "--working-dir") options.WorkingDirectory = value;
                else if (arg == "--profile") options.Profile = value;
                else if (arg == "--username") options.Username = value;
                else if (arg == "--model") options.Model = value;
                else if (arg == "--project-name") options.ProjectName = value;
                else if (arg == "--run-status") options.RunStatusPath = value;
                else if (arg == "--raw-logs") options.RawLogs = ParseBoolean(value, arg);
                else if (arg == "--present-output") options.PresentOutput = ParseBoolean(value, arg);
                else if (arg == "--forward-input") options.ForwardInput = ParseBoolean(value, arg);
                else if (arg == "--max-sessions") options.MaximumSessions = ParseInteger(value, arg, 1, 200);
                else if (arg == "--max-storage-mb")
                {
                    int megabytes = ParseInteger(value, arg, 25, 4096);
                    options.MaximumStorageBytes = (long)megabytes * 1024L * 1024L;
                }
                else throw new ArgumentException("Unknown option: " + arg);

                i += 2;
            }

            if (string.IsNullOrWhiteSpace(options.LogRoot)) throw new ArgumentException("--log-root is required");
            if (string.IsNullOrWhiteSpace(options.BridgePath)) throw new ArgumentException("--bridge is required");
            if (string.IsNullOrWhiteSpace(options.WorkingDirectory)) throw new ArgumentException("--working-dir is required");
            if (!Directory.Exists(options.WorkingDirectory)) throw new DirectoryNotFoundException(options.WorkingDirectory);
            if (options.Command.Count == 0) throw new ArgumentException("Child command is required after --");

            if (options.Profile == null) options.Profile = "profile";
            if (options.Username == null) options.Username = "";
            if (options.Model == null) options.Model = "";
            if (options.ProjectName == null) options.ProjectName = Path.GetFileName(options.WorkingDirectory.TrimEnd('\\'));

            return options;
        }

        private static bool ParseBoolean(string value, string option)
        {
            bool result;
            if (!bool.TryParse(value, out result))
            {
                throw new ArgumentException(option + " must be true or false");
            }
            return result;
        }

        private static int ParseInteger(string value, string option, int minimum, int maximum)
        {
            int result;
            if (!int.TryParse(value, out result) || result < minimum || result > maximum)
            {
                throw new ArgumentException(option + " must be between " + minimum.ToString() + " and " + maximum.ToString());
            }
            return result;
        }
    }

    internal static class RecorderStatus
    {
        internal static void Write(
            Options options,
            string state,
            bool childStarted,
            bool completed,
            int childExitCode,
            bool transcriptUpdated,
            string sessionDirectory,
            string error)
        {
            if (options == null || string.IsNullOrWhiteSpace(options.RunStatusPath)) return;

            StringBuilder content = new StringBuilder();
            content.AppendLine("version=2");
            content.AppendLine("timeUtc=" + DateTime.UtcNow.ToString("o"));
            content.AppendLine("state=" + SafeValue(state));
            content.AppendLine("childStarted=" + childStarted.ToString().ToLowerInvariant());
            content.AppendLine("completed=" + completed.ToString().ToLowerInvariant());
            content.AppendLine("childExitCode=" + childExitCode.ToString());
            content.AppendLine("transcriptUpdated=" + transcriptUpdated.ToString().ToLowerInvariant());
            content.AppendLine("sessionDirectory=" + SafeValue(sessionDirectory));
            content.AppendLine("error=" + SafeValue(error));

            AtomicFile.Write(options.RunStatusPath, content.ToString());
        }

        private static string SafeValue(string value)
        {
            if (string.IsNullOrEmpty(value)) return "";
            return value.Replace("\r", " ").Replace("\n", " ");
        }
    }

    internal static class AtomicFile
    {
        internal static void Write(string path, string content)
        {
            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

            Exception lastError = null;
            for (int attempt = 0; attempt < 4; attempt++)
            {
                string temporary = path + ".tmp-" + Process.GetCurrentProcess().Id.ToString() + "-" + Guid.NewGuid().ToString("N");
                string backup = path + ".bak";

                try
                {
                    File.WriteAllText(temporary, content, new UTF8Encoding(false));

                    if (File.Exists(path))
                    {
                        try
                        {
                            try { if (File.Exists(backup)) File.Delete(backup); } catch { }
                            File.Replace(temporary, path, backup, true);
                            try { if (File.Exists(backup)) File.Delete(backup); } catch { }
                        }
                        catch
                        {
                            File.Copy(temporary, path, true);
                            File.Delete(temporary);
                        }
                    }
                    else
                    {
                        File.Move(temporary, path);
                    }

                    return;
                }
                catch (Exception ex)
                {
                    lastError = ex;
                    try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
                    Thread.Sleep(75 * (attempt + 1));
                }
            }

            throw new IOException("Could not write file atomically: " + path, lastError);
        }
    }

    internal sealed class InputEntry
    {
        internal DateTime TimeUtc;
        internal string Text;
    }

    internal sealed class ScreenBlock
    {
        internal DateTime TimeUtc;
        internal string Text;
        internal string Normalized;
    }

    internal sealed class CaptureEvent
    {
        internal DateTime TimeUtc;
        internal string Kind;
        internal string Text;
    }

    internal sealed class InputTracker
    {
        private enum ParseState { Normal, Escape, Csi, Osc, OscEscape }

        private readonly Decoder decoder = new UTF8Encoding(false, false).GetDecoder();
        private readonly StringBuilder current = new StringBuilder();
        private readonly StringBuilder sequence = new StringBuilder();
        private readonly Action<string> onSubmit;
        private ParseState state = ParseState.Normal;
        private int cursor;
        private bool previousWasCr;
        private bool bracketedPaste;
        private bool pastePreviousWasCr;

        internal InputTracker(Action<string> submitCallback)
        {
            onSubmit = submitCallback;
        }

        internal void Feed(byte[] data, int count)
        {
            int charCount = decoder.GetCharCount(data, 0, count, false);
            char[] chars = new char[Math.Max(charCount, 1)];
            int written = decoder.GetChars(data, 0, count, chars, 0, false);

            for (int i = 0; i < written; i++)
            {
                FeedChar(chars[i]);
            }
        }

        private void FeedChar(char ch)
        {
            if (state == ParseState.Osc)
            {
                if (ch == '\a') state = ParseState.Normal;
                else if (ch == '\x1b') state = ParseState.OscEscape;
                return;
            }

            if (state == ParseState.OscEscape)
            {
                state = ch == '\\' ? ParseState.Normal : ParseState.Osc;
                return;
            }

            if (state == ParseState.Escape)
            {
                if (ch == '[')
                {
                    sequence.Length = 0;
                    state = ParseState.Csi;
                }
                else if (ch == ']')
                {
                    state = ParseState.Osc;
                }
                else
                {
                    state = ParseState.Normal;
                }
                return;
            }

            if (state == ParseState.Csi)
            {
                if (ch >= '@' && ch <= '~')
                {
                    HandleCsi(sequence.ToString(), ch);
                    sequence.Length = 0;
                    state = ParseState.Normal;
                }
                else if (sequence.Length < 64)
                {
                    sequence.Append(ch);
                }
                return;
            }

            if (ch == '\x1b')
            {
                state = ParseState.Escape;
                return;
            }

            if (bracketedPaste)
            {
                if (ch == '\r' || ch == '\n')
                {
                    if (ch == '\n' && pastePreviousWasCr)
                    {
                        pastePreviousWasCr = false;
                        return;
                    }

                    pastePreviousWasCr = ch == '\r';
                    Insert('\n');
                    return;
                }

                pastePreviousWasCr = false;
                if (ch == '\t') Insert('\t');
                else if (!char.IsControl(ch)) Insert(ch);
                return;
            }

            if (ch == '\r' || ch == '\n')
            {
                if (ch == '\n' && previousWasCr)
                {
                    previousWasCr = false;
                    return;
                }

                previousWasCr = ch == '\r';
                Submit();
                return;
            }

            previousWasCr = false;

            if (ch == '\b' || ch == '\x7f')
            {
                if (cursor > 0 && current.Length > 0)
                {
                    current.Remove(cursor - 1, 1);
                    cursor--;
                }
                return;
            }

            if (ch == '\x01') { cursor = 0; return; }
            if (ch == '\x05') { cursor = current.Length; return; }
            if (ch == '\x15') { current.Length = 0; cursor = 0; return; }
            if (ch == '\x0b')
            {
                if (cursor < current.Length) current.Remove(cursor, current.Length - cursor);
                return;
            }
            if (ch == '\x17')
            {
                while (cursor > 0 && char.IsWhiteSpace(current[cursor - 1]))
                {
                    current.Remove(cursor - 1, 1);
                    cursor--;
                }
                while (cursor > 0 && !char.IsWhiteSpace(current[cursor - 1]))
                {
                    current.Remove(cursor - 1, 1);
                    cursor--;
                }
                return;
            }

            if (ch == '\t')
            {
                Insert(' ');
                return;
            }

            if (!char.IsControl(ch)) Insert(ch);
        }

        private void Insert(char ch)
        {
            if (current.Length >= 131072) return;
            current.Insert(cursor, ch);
            cursor++;
        }

        private void HandleCsi(string parameters, char finalChar)
        {
            if (finalChar == 'D')
            {
                cursor = Math.Max(0, cursor - GetFirstParameter(parameters, 1));
            }
            else if (finalChar == 'C')
            {
                cursor = Math.Min(current.Length, cursor + GetFirstParameter(parameters, 1));
            }
            else if (finalChar == 'H')
            {
                cursor = 0;
            }
            else if (finalChar == 'F')
            {
                cursor = current.Length;
            }
            else if (finalChar == '~')
            {
                int code = GetFirstParameter(parameters, 0);
                if (code == 200)
                {
                    bracketedPaste = true;
                    pastePreviousWasCr = false;
                }
                else if (code == 201)
                {
                    bracketedPaste = false;
                    pastePreviousWasCr = false;
                }
                else if (code == 1 || code == 7) cursor = 0;
                else if (code == 4 || code == 8) cursor = current.Length;
                else if (code == 3 && cursor < current.Length) current.Remove(cursor, 1);
            }
        }

        private static int GetFirstParameter(string value, int defaultValue)
        {
            if (string.IsNullOrEmpty(value)) return defaultValue;
            string first = value.Split(';')[0].TrimStart('?', '>');
            int parsed;
            return int.TryParse(first, out parsed) && parsed >= 0 ? parsed : defaultValue;
        }

        private void Submit()
        {
            string value = current.ToString().Trim();
            current.Length = 0;
            cursor = 0;

            if (value.Length > 0 && onSubmit != null) onSubmit(value);
        }
    }

    internal sealed class VtScreen
    {
        private enum ParseState { Normal, Escape, Csi, Osc, OscEscape }

        private readonly object sync = new object();
        private char[,] cells;
        private int width;
        private int height;
        private int cursorX;
        private int cursorY;
        private int savedX;
        private int savedY;
        private int scrollTop;
        private int scrollBottom;
        private ParseState state = ParseState.Normal;
        private readonly StringBuilder sequence = new StringBuilder();
        private char lastPrinted;

        internal VtScreen(int initialWidth, int initialHeight)
        {
            width = Clamp(initialWidth, 20, 500);
            height = Clamp(initialHeight, 10, 200);
            cells = new char[height, width];
            scrollTop = 0;
            scrollBottom = height - 1;
        }

        internal void Resize(int newWidth, int newHeight)
        {
            lock (sync)
            {
                newWidth = Clamp(newWidth, 20, 500);
                newHeight = Clamp(newHeight, 10, 200);
                if (newWidth == width && newHeight == height) return;

                char[,] replacement = new char[newHeight, newWidth];
                int copyHeight = Math.Min(height, newHeight);
                int copyWidth = Math.Min(width, newWidth);
                for (int y = 0; y < copyHeight; y++)
                {
                    for (int x = 0; x < copyWidth; x++) replacement[y, x] = cells[y, x];
                }

                cells = replacement;
                width = newWidth;
                height = newHeight;
                cursorX = Clamp(cursorX, 0, width - 1);
                cursorY = Clamp(cursorY, 0, height - 1);
                scrollTop = 0;
                scrollBottom = height - 1;
            }
        }

        internal void Feed(string text)
        {
            lock (sync)
            {
                for (int i = 0; i < text.Length; i++) FeedChar(text[i]);
            }
        }

        internal string Render()
        {
            lock (sync)
            {
                StringBuilder result = new StringBuilder(height * (width + 1));
                int first = 0;
                int last = height - 1;

                while (first <= last && IsRowEmpty(first)) first++;
                while (last >= first && IsRowEmpty(last)) last--;

                for (int y = first; y <= last; y++)
                {
                    int end = width - 1;
                    while (end >= 0 && cells[y, end] == '\0') end--;
                    while (end >= 0 && cells[y, end] == ' ') end--;

                    for (int x = 0; x <= end; x++)
                    {
                        char ch = cells[y, x];
                        result.Append(ch == '\0' ? ' ' : ch);
                    }

                    if (y < last) result.AppendLine();
                }

                return result.ToString();
            }
        }

        private void FeedChar(char ch)
        {
            if (state == ParseState.Osc)
            {
                if (ch == '\a') state = ParseState.Normal;
                else if (ch == '\x1b') state = ParseState.OscEscape;
                return;
            }

            if (state == ParseState.OscEscape)
            {
                state = ch == '\\' ? ParseState.Normal : ParseState.Osc;
                return;
            }

            if (state == ParseState.Escape)
            {
                if (ch == '[')
                {
                    sequence.Length = 0;
                    state = ParseState.Csi;
                }
                else if (ch == ']')
                {
                    state = ParseState.Osc;
                }
                else if (ch == '7')
                {
                    savedX = cursorX;
                    savedY = cursorY;
                    state = ParseState.Normal;
                }
                else if (ch == '8')
                {
                    cursorX = savedX;
                    cursorY = savedY;
                    state = ParseState.Normal;
                }
                else if (ch == 'c')
                {
                    ClearAll();
                    state = ParseState.Normal;
                }
                else
                {
                    state = ParseState.Normal;
                }
                return;
            }

            if (state == ParseState.Csi)
            {
                if (ch >= '@' && ch <= '~')
                {
                    HandleCsi(sequence.ToString(), ch);
                    sequence.Length = 0;
                    state = ParseState.Normal;
                }
                else if (sequence.Length < 128)
                {
                    sequence.Append(ch);
                }
                return;
            }

            if (ch == '\x1b') { state = ParseState.Escape; return; }
            if (ch == '\r') { cursorX = 0; return; }
            if (ch == '\n') { LineFeed(); return; }
            if (ch == '\b') { cursorX = Math.Max(0, cursorX - 1); return; }
            if (ch == '\t') { cursorX = Math.Min(width - 1, ((cursorX / 8) + 1) * 8); return; }
            if (char.IsControl(ch)) return;

            Put(ch);
        }

        private void HandleCsi(string raw, char finalChar)
        {
            bool privateMode = raw.StartsWith("?");
            string clean = raw.TrimStart('?', '>');
            int[] p = ParseParameters(clean);
            int first = p.Length > 0 && p[0] != 0 ? p[0] : 1;

            switch (finalChar)
            {
                case 'A': cursorY = Math.Max(scrollTop, cursorY - first); break;
                case 'B': cursorY = Math.Min(scrollBottom, cursorY + first); break;
                case 'C': cursorX = Math.Min(width - 1, cursorX + first); break;
                case 'D': cursorX = Math.Max(0, cursorX - first); break;
                case 'E': cursorY = Math.Min(scrollBottom, cursorY + first); cursorX = 0; break;
                case 'F': cursorY = Math.Max(scrollTop, cursorY - first); cursorX = 0; break;
                case 'G': cursorX = Clamp(first - 1, 0, width - 1); break;
                case 'H':
                case 'f':
                    cursorY = Clamp((p.Length > 0 && p[0] > 0 ? p[0] : 1) - 1, 0, height - 1);
                    cursorX = Clamp((p.Length > 1 && p[1] > 0 ? p[1] : 1) - 1, 0, width - 1);
                    break;
                case 'd': cursorY = Clamp(first - 1, 0, height - 1); break;
                case 'a': cursorX = Math.Min(width - 1, cursorX + first); break;
                case 'e': cursorY = Math.Min(height - 1, cursorY + first); break;
                case 'J': EraseDisplay(p.Length > 0 ? p[0] : 0); break;
                case 'K': EraseLine(p.Length > 0 ? p[0] : 0); break;
                case 'L': InsertLines(first); break;
                case 'M': DeleteLines(first); break;
                case 'P': DeleteChars(first); break;
                case '@': InsertChars(first); break;
                case 'X': EraseChars(first); break;
                case 'S': ScrollUp(first); break;
                case 'T': ScrollDown(first); break;
                case 's': savedX = cursorX; savedY = cursorY; break;
                case 'u': cursorX = savedX; cursorY = savedY; break;
                case 'r':
                    scrollTop = Clamp((p.Length > 0 && p[0] > 0 ? p[0] : 1) - 1, 0, height - 1);
                    scrollBottom = Clamp((p.Length > 1 && p[1] > 0 ? p[1] : height) - 1, scrollTop, height - 1);
                    cursorX = 0;
                    cursorY = scrollTop;
                    break;
                case 'b':
                    for (int i = 0; i < first; i++) Put(lastPrinted == '\0' ? ' ' : lastPrinted);
                    break;
                case 'h':
                    if (privateMode && ContainsParameter(p, 1049)) ClearAll();
                    break;
                case 'l':
                case 'm':
                case 'n':
                case 't':
                    break;
            }
        }

        private void Put(char ch)
        {
            if (cursorX >= width)
            {
                cursorX = 0;
                LineFeed();
            }

            cells[cursorY, cursorX] = ch;
            lastPrinted = ch;
            cursorX++;

            if (cursorX >= width)
            {
                cursorX = 0;
                LineFeed();
            }
        }

        private void LineFeed()
        {
            if (cursorY == scrollBottom) ScrollUp(1);
            else cursorY = Math.Min(height - 1, cursorY + 1);
        }

        private void ClearAll()
        {
            cells = new char[height, width];
            cursorX = 0;
            cursorY = 0;
            scrollTop = 0;
            scrollBottom = height - 1;
        }

        private void EraseDisplay(int mode)
        {
            if (mode == 2 || mode == 3)
            {
                ClearAll();
                return;
            }

            if (mode == 0)
            {
                for (int x = cursorX; x < width; x++) cells[cursorY, x] = '\0';
                for (int y = cursorY + 1; y < height; y++) ClearRow(y);
            }
            else if (mode == 1)
            {
                for (int y = 0; y < cursorY; y++) ClearRow(y);
                for (int x = 0; x <= cursorX; x++) cells[cursorY, x] = '\0';
            }
        }

        private void EraseLine(int mode)
        {
            if (mode == 2) ClearRow(cursorY);
            else if (mode == 1)
            {
                for (int x = 0; x <= cursorX; x++) cells[cursorY, x] = '\0';
            }
            else
            {
                for (int x = cursorX; x < width; x++) cells[cursorY, x] = '\0';
            }
        }

        private void InsertLines(int count)
        {
            count = Math.Min(count, scrollBottom - cursorY + 1);
            for (int y = scrollBottom; y >= cursorY + count; y--) CopyRow(y - count, y);
            for (int y = cursorY; y < cursorY + count; y++) ClearRow(y);
        }

        private void DeleteLines(int count)
        {
            count = Math.Min(count, scrollBottom - cursorY + 1);
            for (int y = cursorY; y <= scrollBottom - count; y++) CopyRow(y + count, y);
            for (int y = scrollBottom - count + 1; y <= scrollBottom; y++) ClearRow(y);
        }

        private void InsertChars(int count)
        {
            count = Math.Min(count, width - cursorX);
            for (int x = width - 1; x >= cursorX + count; x--) cells[cursorY, x] = cells[cursorY, x - count];
            for (int x = cursorX; x < cursorX + count; x++) cells[cursorY, x] = '\0';
        }

        private void DeleteChars(int count)
        {
            count = Math.Min(count, width - cursorX);
            for (int x = cursorX; x < width - count; x++) cells[cursorY, x] = cells[cursorY, x + count];
            for (int x = width - count; x < width; x++) cells[cursorY, x] = '\0';
        }

        private void EraseChars(int count)
        {
            int end = Math.Min(width, cursorX + count);
            for (int x = cursorX; x < end; x++) cells[cursorY, x] = '\0';
        }

        private void ScrollUp(int count)
        {
            count = Math.Min(count, scrollBottom - scrollTop + 1);
            for (int y = scrollTop; y <= scrollBottom - count; y++) CopyRow(y + count, y);
            for (int y = scrollBottom - count + 1; y <= scrollBottom; y++) ClearRow(y);
        }

        private void ScrollDown(int count)
        {
            count = Math.Min(count, scrollBottom - scrollTop + 1);
            for (int y = scrollBottom; y >= scrollTop + count; y--) CopyRow(y - count, y);
            for (int y = scrollTop; y < scrollTop + count; y++) ClearRow(y);
        }

        private void CopyRow(int source, int destination)
        {
            for (int x = 0; x < width; x++) cells[destination, x] = cells[source, x];
        }

        private void ClearRow(int row)
        {
            for (int x = 0; x < width; x++) cells[row, x] = '\0';
        }

        private bool IsRowEmpty(int row)
        {
            for (int x = 0; x < width; x++)
            {
                if (cells[row, x] != '\0' && cells[row, x] != ' ') return false;
            }
            return true;
        }

        private static int[] ParseParameters(string value)
        {
            if (string.IsNullOrEmpty(value)) return new int[0];
            string[] parts = value.Split(';');
            int[] result = new int[parts.Length];
            for (int i = 0; i < parts.Length; i++)
            {
                int parsed;
                result[i] = int.TryParse(parts[i], out parsed) ? parsed : 0;
            }
            return result;
        }

        private static bool ContainsParameter(int[] values, int expected)
        {
            for (int i = 0; i < values.Length; i++) if (values[i] == expected) return true;
            return false;
        }

        private static int Clamp(int value, int minimum, int maximum)
        {
            if (value < minimum) return minimum;
            if (value > maximum) return maximum;
            return value;
        }
    }

    internal sealed class SessionCapture : IDisposable
    {
        private const long MaximumRawBytes = 32L * 1024L * 1024L;
        private const int MaximumHistoryCharacters = 360000;
        private const int MaximumBridgeCharacters = 65000;
        private const int MaximumBlockCharacters = 24000;
        private const int MaximumTurnCharacters = 24000;
        private const int MaximumBridgeSessions = 14;
        private const int MaximumHistorySessions = 50;

        private readonly object sync = new object();
        private readonly Options options;
        private readonly string sessionDirectory;
        private readonly string rawOutputPath;
        private readonly string rawInputPath;
        private readonly string inputLogPath;
        private readonly string snapshotLogPath;
        private readonly string transcriptPath;
        private readonly string historyPath;
        private readonly string statusPath;
        private FileStream rawOutput;
        private FileStream rawInput;
        private readonly VtScreen screen;
        private readonly InputTracker inputTracker;
        private readonly Decoder outputDecoder = new UTF8Encoding(false, false).GetDecoder();
        private readonly List<InputEntry> inputs = new List<InputEntry>();
        private readonly List<ScreenBlock> blocks = new List<ScreenBlock>();
        private readonly HashSet<string> blockHashes = new HashSet<string>(StringComparer.Ordinal);
        private readonly Thread snapshotThread;
        private volatile bool stopping;
        private volatile bool screenDirty;
        private DateTime lastOutputUtc = DateTime.MinValue;
        private DateTime lastSnapshotUtc = DateTime.MinValue;
        private long rawOutputBytes;
        private long rawInputBytes;
        private string lastSnapshotHash = "";

        internal SessionCapture(Options recorderOptions, int width, int height)
        {
            options = recorderOptions;
            Directory.CreateDirectory(options.LogRoot);
            Directory.CreateDirectory(Path.GetDirectoryName(options.BridgePath));

            string safeProfile = SafeSegment(options.Profile);
            string stamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fff");
            sessionDirectory = Path.Combine(
                options.LogRoot,
                stamp + "-" + safeProfile + "-" + Process.GetCurrentProcess().Id.ToString()
            );
            Directory.CreateDirectory(sessionDirectory);

            rawOutputPath = Path.Combine(sessionDirectory, "terminal-output.vt");
            rawInputPath = Path.Combine(sessionDirectory, "terminal-input.vt");
            inputLogPath = Path.Combine(sessionDirectory, "user-input.txt");
            snapshotLogPath = Path.Combine(sessionDirectory, "screen-snapshots.txt");
            transcriptPath = Path.Combine(sessionDirectory, "TRANSCRIPT.md");
            historyPath = Path.Combine(options.LogRoot, "conversation-memory-v3.md");
            statusPath = Path.Combine(sessionDirectory, "status.txt");

            if (options.RawLogs)
            {
                rawOutput = new FileStream(rawOutputPath, FileMode.Create, FileAccess.Write, FileShare.Read);
                rawInput = new FileStream(rawInputPath, FileMode.Create, FileAccess.Write, FileShare.Read);
            }

            screen = new VtScreen(width, height);
            inputTracker = new InputTracker(OnInputSubmitted);

            snapshotThread = new Thread(SnapshotLoop);
            snapshotThread.Name = "DuoRecorder-Snapshots";
            snapshotThread.IsBackground = true;
            snapshotThread.Start();
        }

        internal string SessionDirectory { get { return sessionDirectory; } }
        internal bool TranscriptUpdated { get; private set; }
        internal string CaptureError { get; private set; }

        internal void Resize(int width, int height)
        {
            screen.Resize(width, height);
            screenDirty = true;
        }

        internal void ProcessOutput(byte[] data, int count)
        {
            if (options.RawLogs && rawOutput != null)
            {
                lock (sync)
                {
                    if (rawOutputBytes < MaximumRawBytes)
                    {
                        int allowed = (int)Math.Min((long)count, MaximumRawBytes - rawOutputBytes);
                        rawOutput.Write(data, 0, allowed);
                        rawOutputBytes += allowed;
                    }
                }
            }

            int charCount = outputDecoder.GetCharCount(data, 0, count, false);
            char[] chars = new char[Math.Max(charCount, 1)];
            int written = outputDecoder.GetChars(data, 0, count, chars, 0, false);
            if (written > 0)
            {
                screen.Feed(new string(chars, 0, written));
                lastOutputUtc = DateTime.UtcNow;
                screenDirty = true;
            }
        }

        internal void ProcessInput(byte[] data, int count)
        {
            if (options.RawLogs && rawInput != null)
            {
                lock (sync)
                {
                    if (rawInputBytes < MaximumRawBytes)
                    {
                        int allowed = (int)Math.Min((long)count, MaximumRawBytes - rawInputBytes);
                        rawInput.Write(data, 0, allowed);
                        rawInputBytes += allowed;
                    }
                }
            }

            inputTracker.Feed(data, count);
        }

        internal void Complete(int exitCode)
        {
            stopping = true;
            try { snapshotThread.Join(1800); } catch { }

            try
            {
                FlushOutputDecoder();
                CaptureSnapshot(true);

                lock (sync)
                {
                    if (rawOutput != null)
                    {
                        rawOutput.Flush();
                        rawOutput.Dispose();
                        rawOutput = null;
                    }
                    if (rawInput != null)
                    {
                        rawInput.Flush();
                        rawInput.Dispose();
                        rawInput = null;
                    }
                }

                string sessionTranscript = BuildSessionTranscript(exitCode);
                AtomicFile.Write(transcriptPath, sessionTranscript);
                UpdateHistoryAndBridge(sessionTranscript);
                TranscriptUpdated = true;
            }
            catch (Exception ex)
            {
                CaptureError = ex.ToString();
                try
                {
                    File.AppendAllText(
                        Path.Combine(sessionDirectory, "capture-error.log"),
                        DateTime.UtcNow.ToString("o") + Environment.NewLine + ex.ToString() + Environment.NewLine,
                        new UTF8Encoding(false)
                    );
                }
                catch { }
            }

            try
            {
                StringBuilder status = new StringBuilder();
                status.AppendLine("version=2");
                status.AppendLine("exitCode=" + exitCode.ToString());
                status.AppendLine("inputs=" + inputs.Count.ToString());
                status.AppendLine("blocks=" + blocks.Count.ToString());
                status.AppendLine("bridge=" + options.BridgePath);
                status.AppendLine("session=" + sessionDirectory);
                status.AppendLine("rawLogs=" + options.RawLogs.ToString().ToLowerInvariant());
                status.AppendLine("transcriptUpdated=" + TranscriptUpdated.ToString().ToLowerInvariant());
                status.AppendLine("error=" + (CaptureError ?? "").Replace("\r", " ").Replace("\n", " "));
                AtomicFile.Write(statusPath, status.ToString());
            }
            catch { }

            try { CleanupRetention(); } catch { }
        }

        private void FlushOutputDecoder()
        {
            char[] chars = new char[8];
            int written = outputDecoder.GetChars(new byte[0], 0, 0, chars, 0, true);
            if (written > 0)
            {
                screen.Feed(new string(chars, 0, written));
                screenDirty = true;
            }
        }

        private void SnapshotLoop()
        {
            while (!stopping)
            {
                Thread.Sleep(250);

                try
                {
                    if (!screenDirty) continue;

                    DateTime now = DateTime.UtcNow;
                    bool quietLongEnough = (now - lastOutputUtc).TotalMilliseconds >= 750;
                    bool periodicCapture = (now - lastSnapshotUtc).TotalMilliseconds >= 1250;

                    if (quietLongEnough || periodicCapture)
                    {
                        CaptureSnapshot(false);
                    }
                }
                catch (Exception ex)
                {
                    CaptureError = ex.ToString();
                }
            }
        }

        private void CaptureSnapshot(bool force)
        {
            if (!force && !screenDirty) return;

            string rendered = screen.Render();
            string filtered = FilterScreen(rendered);
            screenDirty = false;

            if (string.IsNullOrWhiteSpace(filtered)) return;
            string hash = Hash(filtered);
            if (hash == lastSnapshotHash) return;
            lastSnapshotHash = hash;
            lastSnapshotUtc = DateTime.UtcNow;

            string redacted = Redact(filtered);
            lock (sync)
            {
                File.AppendAllText(
                    snapshotLogPath,
                    "\r\n===== " + lastSnapshotUtc.ToString("o") + " =====\r\n" + redacted + "\r\n",
                    new UTF8Encoding(false)
                );
            }

            AddBlocks(redacted, lastSnapshotUtc);
        }

        private void AddBlocks(string screenText, DateTime timeUtc)
        {
            string[] paragraphs = Regex.Split(screenText, "(?:\\r?\\n){2,}");
            for (int i = 0; i < paragraphs.Length; i++)
            {
                string normalizedParagraph = NormalizeBlock(paragraphs[i]);
                if (normalizedParagraph.Length < 3) continue;

                RecoverInputsFromBlock(normalizedParagraph, timeUtc);

                string block = CleanOutputBlock(normalizedParagraph);
                if (block.Length < 3 || IsNoiseBlock(block)) continue;
                if (IsEchoOfRecentInput(block, timeUtc)) continue;

                if (block.Length > MaximumBlockCharacters)
                {
                    block = block.Substring(0, MaximumBlockCharacters) + "\n[обрезано]";
                }

                string normalized = NormalizeForComparison(block);
                string hash = Hash(normalized);

                lock (sync)
                {
                    if (blockHashes.Contains(hash)) continue;

                    int replacementIndex = FindExpandableBlock(normalized);
                    if (replacementIndex >= 0)
                    {
                        blockHashes.Remove(Hash(blocks[replacementIndex].Normalized));

                        if (block.Length >= blocks[replacementIndex].Text.Length)
                        {
                            blocks[replacementIndex].Text = block;
                            blocks[replacementIndex].Normalized = normalized;
                        }

                        blocks[replacementIndex].TimeUtc = timeUtc;
                        blockHashes.Add(Hash(blocks[replacementIndex].Normalized));
                    }
                    else
                    {
                        ScreenBlock item = new ScreenBlock();
                        item.TimeUtc = timeUtc;
                        item.Text = block;
                        item.Normalized = normalized;
                        blocks.Add(item);
                        blockHashes.Add(hash);
                    }

                    while (blocks.Count > 160)
                    {
                        blockHashes.Remove(Hash(blocks[0].Normalized));
                        blocks.RemoveAt(0);
                    }
                }
            }
        }

        private bool IsEchoOfRecentInput(string block, DateTime timeUtc)
        {
            string normalizedBlock = NormalizeForComparison(block);
            lock (sync)
            {
                int start = Math.Max(0, inputs.Count - 5);
                for (int i = inputs.Count - 1; i >= start; i--)
                {
                    if ((timeUtc - inputs[i].TimeUtc).TotalMinutes > 3) continue;
                    string normalizedInput = NormalizeForComparison(inputs[i].Text);
                    if (normalizedInput.Length < 3) continue;
                    if (normalizedBlock == normalizedInput) return true;
                    if (normalizedBlock.StartsWith(normalizedInput, StringComparison.Ordinal) &&
                        normalizedBlock.Length <= normalizedInput.Length + 24)
                    {
                        return true;
                    }
                }
            }
            return false;
        }

        private int FindExpandableBlock(string candidate)
        {
            int start = Math.Max(0, blocks.Count - 16);
            for (int i = blocks.Count - 1; i >= start; i--)
            {
                string existing = blocks[i].Normalized;
                if (existing.Length < 8 || candidate.Length < 8) continue;

                if (
                    candidate.StartsWith(existing, StringComparison.Ordinal) ||
                    existing.StartsWith(candidate, StringComparison.Ordinal)
                )
                {
                    return i;
                }

                int smallerLength = Math.Min(existing.Length, candidate.Length);
                int commonPrefix = CommonPrefixLength(existing, candidate);
                int requiredPrefix = Math.Max(8, (int)Math.Floor(smallerLength * 0.72));

                if (commonPrefix >= requiredPrefix)
                {
                    return i;
                }
            }

            return -1;
        }

        private static int CommonPrefixLength(string left, string right)
        {
            int length = Math.Min(left.Length, right.Length);
            int index = 0;

            while (index < length && left[index] == right[index])
            {
                index++;
            }

            return index;
        }

        private void OnInputSubmitted(string value)
        {
            AddInputEntry(value, DateTime.UtcNow);
        }

        private void RecoverInputsFromBlock(string block, DateTime timeUtc)
        {
            string[] lines = block.Replace("\r", "").Split('\n');

            for (int i = 0; i < lines.Length; i++)
            {
                string trimmed = lines[i].Trim();

                if (!trimmed.StartsWith("> ", StringComparison.Ordinal)) continue;

                string candidate = trimmed.Substring(2).Trim();

                if (candidate.Length == 0) continue;
                if (candidate.StartsWith("█", StringComparison.Ordinal)) continue;
                if (candidate.IndexOf("Type your message here", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                if (IsKnownUiCommand(candidate)) continue;

                AddInputEntry(candidate, timeUtc);
            }
        }

        private void AddInputEntry(string value, DateTime timeUtc)
        {
            string cleaned = Redact((value ?? "").Trim());
            if (cleaned.Length == 0) return;
            if (IsKnownUiCommand(cleaned)) return;

            if (cleaned.Length > 131072)
            {
                cleaned = cleaned.Substring(0, 131072) + " [обрезано]";
            }

            string normalized = NormalizeForComparison(cleaned);

            lock (sync)
            {
                int start = Math.Max(0, inputs.Count - 10);

                for (int i = inputs.Count - 1; i >= start; i--)
                {
                    if ((timeUtc - inputs[i].TimeUtc).TotalMinutes > 5) continue;

                    string existing = NormalizeForComparison(inputs[i].Text);
                    if (string.Equals(existing, normalized, StringComparison.Ordinal))
                    {
                        return;
                    }
                }

                InputEntry entry = new InputEntry();
                entry.TimeUtc = timeUtc;
                entry.Text = cleaned;
                inputs.Add(entry);

                File.AppendAllText(
                    inputLogPath,
                    "[" + entry.TimeUtc.ToString("o") + "] " + cleaned + Environment.NewLine,
                    new UTF8Encoding(false)
                );
            }
        }

        private string BuildSessionTranscript(int exitCode)
        {
            List<InputEntry> inputCopy = new List<InputEntry>();
            List<ScreenBlock> blockCopy = new List<ScreenBlock>();

            lock (sync)
            {
                for (int i = 0; i < inputs.Count; i++)
                {
                    InputEntry input = new InputEntry();
                    input.TimeUtc = inputs[i].TimeUtc;
                    input.Text = inputs[i].Text;
                    inputCopy.Add(input);
                }

                for (int i = 0; i < blocks.Count; i++)
                {
                    ScreenBlock block = new ScreenBlock();
                    block.TimeUtc = blocks[i].TimeUtc;
                    block.Text = blocks[i].Text;
                    block.Normalized = blocks[i].Normalized;
                    blockCopy.Add(block);
                }
            }

            inputCopy.Sort(delegate(InputEntry left, InputEntry right)
            {
                return left.TimeUtc.CompareTo(right.TimeUtc);
            });

            blockCopy.Sort(delegate(ScreenBlock left, ScreenBlock right)
            {
                return left.TimeUtc.CompareTo(right.TimeUtc);
            });

            StringBuilder result = new StringBuilder();
            result.AppendLine("## SESSION " + DateTime.UtcNow.ToString("o"));
            result.AppendLine();
            result.AppendLine("- Profile: " + Redact(options.Profile));
            result.AppendLine("- GitLab user: " + Redact(options.Username));
            result.AppendLine("- Model: " + Redact(options.Model));
            result.AppendLine("- Project: " + Redact(options.ProjectName));
            result.AppendLine("- Exit code: " + exitCode.ToString());
            result.AppendLine("- Format: optimized visible conversation v3");
            result.AppendLine("- Capture: local ConPTY transcript, not a GitLab server chat import");
            result.AppendLine();

            List<InputEntry> meaningfulInputs = new List<InputEntry>();
            for (int i = 0; i < inputCopy.Count; i++)
            {
                if (!IsKnownUiCommand(inputCopy[i].Text))
                {
                    meaningfulInputs.Add(inputCopy[i]);
                }
            }

            if (meaningfulInputs.Count == 0)
            {
                List<ScreenBlock> fallback = SelectStableBlocks(
                    blockCopy,
                    DateTime.MinValue,
                    DateTime.MaxValue,
                    ""
                );

                result.AppendLine("### Relevant visible output");
                result.AppendLine();

                if (fallback.Count == 0)
                {
                    result.AppendLine("_Nothing reconstructable was captured._");
                }
                else
                {
                    AppendBlocksWithLimit(result, fallback, MaximumTurnCharacters);
                }

                return result.ToString();
            }

            result.AppendLine("### Conversation");
            result.AppendLine();

            for (int i = 0; i < meaningfulInputs.Count; i++)
            {
                InputEntry input = meaningfulInputs[i];
                DateTime windowStart = input.TimeUtc.AddSeconds(-2);
                DateTime windowEnd = i + 1 < meaningfulInputs.Count
                    ? meaningfulInputs[i + 1].TimeUtc.AddMilliseconds(-1)
                    : DateTime.MaxValue;

                List<ScreenBlock> candidates = SelectStableBlocks(
                    blockCopy,
                    windowStart,
                    windowEnd,
                    input.Text
                );

                result.AppendLine("#### USER " + input.TimeUtc.ToString("HH:mm:ss") + " UTC");
                result.AppendLine();
                result.AppendLine(input.Text);
                result.AppendLine();

                if (candidates.Count > 0)
                {
                    result.AppendLine("#### RESPONSE / RELEVANT OUTPUT");
                    result.AppendLine();
                    AppendBlocksWithLimit(result, candidates, MaximumTurnCharacters);
                    result.AppendLine();
                }
                else
                {
                    result.AppendLine("#### RESPONSE / RELEVANT OUTPUT");
                    result.AppendLine();
                    result.AppendLine("_No stable visible response was reconstructed._");
                    result.AppendLine();
                }
            }

            List<ScreenBlock> diagnostics = SelectImportantDiagnostics(
                blockCopy,
                meaningfulInputs
            );

            if (diagnostics.Count > 0)
            {
                result.AppendLine("### Important terminal diagnostics");
                result.AppendLine();
                AppendBlocksWithLimit(result, diagnostics, 12000);
            }

            return result.ToString();
        }

        private static List<ScreenBlock> SelectStableBlocks(
            List<ScreenBlock> source,
            DateTime startUtc,
            DateTime endUtc,
            string userText)
        {
            List<ScreenBlock> selected = new List<ScreenBlock>();
            string normalizedInput = NormalizeForComparison(userText ?? "");

            for (int i = 0; i < source.Count; i++)
            {
                ScreenBlock item = source[i];

                if (item.TimeUtc < startUtc || item.TimeUtc > endUtc) continue;

                string cleaned = CleanOutputBlock(item.Text);
                if (cleaned.Length < 3) continue;

                string normalized = NormalizeForComparison(cleaned);

                if (
                    normalizedInput.Length >= 3 &&
                    (
                        string.Equals(normalized, normalizedInput, StringComparison.Ordinal) ||
                        (
                            normalized.StartsWith(normalizedInput, StringComparison.Ordinal) &&
                            normalized.Length <= normalizedInput.Length + 32
                        )
                    )
                )
                {
                    continue;
                }

                if (!LooksLikeResponse(cleaned) && !LooksImportantTerminal(cleaned))
                {
                    continue;
                }

                ScreenBlock candidate = new ScreenBlock();
                candidate.TimeUtc = item.TimeUtc;
                candidate.Text = cleaned;
                candidate.Normalized = normalized;

                AddOrMergeCandidate(selected, candidate);
            }

            while (selected.Count > 10)
            {
                selected.RemoveAt(0);
            }

            return selected;
        }

        private static List<ScreenBlock> SelectImportantDiagnostics(
            List<ScreenBlock> blocks,
            List<InputEntry> inputs)
        {
            List<ScreenBlock> result = new List<ScreenBlock>();

            for (int i = 0; i < blocks.Count; i++)
            {
                string cleaned = CleanOutputBlock(blocks[i].Text);
                if (!LooksImportantTerminal(cleaned)) continue;

                bool alreadyInsideTurn = false;

                for (int j = 0; j < inputs.Count; j++)
                {
                    DateTime end = j + 1 < inputs.Count
                        ? inputs[j + 1].TimeUtc
                        : DateTime.MaxValue;

                    if (
                        blocks[i].TimeUtc >= inputs[j].TimeUtc.AddSeconds(-2) &&
                        blocks[i].TimeUtc < end
                    )
                    {
                        alreadyInsideTurn = true;
                        break;
                    }
                }

                if (alreadyInsideTurn) continue;

                ScreenBlock item = new ScreenBlock();
                item.TimeUtc = blocks[i].TimeUtc;
                item.Text = cleaned;
                item.Normalized = NormalizeForComparison(cleaned);
                AddOrMergeCandidate(result, item);
            }

            while (result.Count > 6)
            {
                result.RemoveAt(0);
            }

            return result;
        }

        private static void AddOrMergeCandidate(
            List<ScreenBlock> selected,
            ScreenBlock candidate)
        {
            int start = Math.Max(0, selected.Count - 8);

            for (int i = selected.Count - 1; i >= start; i--)
            {
                string existing = selected[i].Normalized;
                string current = candidate.Normalized;

                if (string.Equals(existing, current, StringComparison.Ordinal))
                {
                    if (candidate.TimeUtc > selected[i].TimeUtc)
                    {
                        selected[i].TimeUtc = candidate.TimeUtc;
                    }
                    return;
                }

                int smaller = Math.Min(existing.Length, current.Length);
                int common = CommonPrefixLength(existing, current);
                bool progressive =
                    current.StartsWith(existing, StringComparison.Ordinal) ||
                    existing.StartsWith(current, StringComparison.Ordinal) ||
                    (
                        smaller >= 10 &&
                        common >= Math.Max(8, (int)Math.Floor(smaller * 0.72))
                    );

                if (progressive)
                {
                    if (candidate.Text.Length >= selected[i].Text.Length)
                    {
                        selected[i] = candidate;
                    }
                    else if (candidate.TimeUtc > selected[i].TimeUtc)
                    {
                        selected[i].TimeUtc = candidate.TimeUtc;
                    }
                    return;
                }
            }

            selected.Add(candidate);
        }

        private static void AppendBlocksWithLimit(
            StringBuilder result,
            List<ScreenBlock> blocks,
            int maximumCharacters)
        {
            List<string> kept = new List<string>();
            int total = 0;

            for (int i = blocks.Count - 1; i >= 0; i--)
            {
                string text = blocks[i].Text.Trim();
                if (text.Length == 0) continue;

                int projected = total + text.Length + 2;
                if (projected > maximumCharacters && kept.Count > 0) break;

                if (text.Length > maximumCharacters)
                {
                    text = text.Substring(
                        text.Length - maximumCharacters
                    );
                }

                kept.Insert(0, text);
                total += text.Length + 2;
            }

            if (kept.Count < blocks.Count)
            {
                result.AppendLine("[Earlier progressive terminal output omitted.]");
                result.AppendLine();
            }

            for (int i = 0; i < kept.Count; i++)
            {
                result.AppendLine(kept[i]);
                if (i + 1 < kept.Count) result.AppendLine();
            }
        }

        private void UpdateHistoryAndBridge(string sessionTranscript)
        {
            string mutexName = "Local\\GitLabDuoSwitcher-" + Hash(options.BridgePath).Substring(0, 24);

            using (Mutex mutex = new Mutex(false, mutexName))
            {
                bool acquired = false;

                try
                {
                    try
                    {
                        acquired = mutex.WaitOne(TimeSpan.FromSeconds(15));
                    }
                    catch (AbandonedMutexException)
                    {
                        acquired = true;
                    }

                    if (!acquired)
                    {
                        throw new TimeoutException("Timed out waiting for transcript lock.");
                    }

                    string existing = File.Exists(historyPath)
                        ? File.ReadAllText(historyPath, Encoding.UTF8)
                        : "";

                    string combined = existing.Trim();

                    if (combined.Length > 0)
                    {
                        combined += Environment.NewLine + Environment.NewLine;
                    }

                    combined += sessionTranscript.Trim() + Environment.NewLine;

                    combined = KeepRecentSessions(
                        combined,
                        MaximumHistorySessions,
                        MaximumHistoryCharacters
                    );

                    AtomicFile.Write(historyPath, combined);

                    string bridgeBody = KeepRecentSessions(
                        combined,
                        MaximumBridgeSessions,
                        MaximumBridgeCharacters
                    );

                    StringBuilder bridge = new StringBuilder();
                    bridge.AppendLine("# LOCAL CROSS-ACCOUNT TERMINAL MEMORY");
                    bridge.AppendLine();
                    bridge.AppendLine("Schema: optimized-visible-conversation-v3");
                    bridge.AppendLine("Generated automatically by GitLab Duo CLI Switcher.");
                    bridge.AppendLine("This is deterministic local memory, not an imported GitLab server conversation.");
                    bridge.AppendLine("Intermediate TUI redraws, spinners, menus and progressive duplicates are removed.");
                    bridge.AppendLine("Use the newest relevant user request and response.");
                    bridge.AppendLine("Do not expose private chain-of-thought.");
                    bridge.AppendLine();
                    bridge.AppendLine("<!-- CHAT_BRIDGE_BEGIN -->");
                    bridge.AppendLine(bridgeBody.Trim());
                    bridge.AppendLine("<!-- CHAT_BRIDGE_END -->");

                    AtomicFile.Write(options.BridgePath, bridge.ToString());
                }
                finally
                {
                    if (acquired) mutex.ReleaseMutex();
                }
            }
        }

        private void CleanupRetention()
        {
            DirectoryInfo root = new DirectoryInfo(options.LogRoot);
            DirectoryInfo[] directories = root.GetDirectories();
            Array.Sort(directories, delegate(DirectoryInfo left, DirectoryInfo right)
            {
                return right.CreationTimeUtc.CompareTo(left.CreationTimeUtc);
            });

            long totalBytes = 0;
            for (int i = 0; i < directories.Length; i++)
            {
                totalBytes += GetDirectorySize(directories[i]);
            }

            for (int i = directories.Length - 1; i >= 0; i--)
            {
                DirectoryInfo directory = directories[i];
                if (string.Equals(directory.FullName, sessionDirectory, StringComparison.OrdinalIgnoreCase)) continue;

                bool tooMany = i >= options.MaximumSessions;
                bool tooLarge = totalBytes > options.MaximumStorageBytes;
                if (!tooMany && !tooLarge) continue;

                long size = GetDirectorySize(directory);
                try
                {
                    directory.Delete(true);
                    totalBytes = Math.Max(0, totalBytes - size);
                }
                catch { }
            }
        }

        private static long GetDirectorySize(DirectoryInfo directory)
        {
            long total = 0;
            try
            {
                FileInfo[] files = directory.GetFiles("*", SearchOption.AllDirectories);
                for (int i = 0; i < files.Length; i++)
                {
                    try { total += files[i].Length; } catch { }
                }
            }
            catch { }
            return total;
        }

        private static string FilterScreen(string value)
        {
            string[] lines = value.Replace("\r", "").Split('\n');
            List<string> kept = new List<string>();

            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i].TrimEnd();
                string trimmed = line.Trim();

                if (trimmed.Length == 0)
                {
                    if (kept.Count > 0 && kept[kept.Count - 1].Length != 0)
                    {
                        kept.Add("");
                    }
                    continue;
                }

                if (IsNoiseLine(trimmed)) continue;
                kept.Add(line);
            }

            while (kept.Count > 0 && kept[0].Length == 0)
            {
                kept.RemoveAt(0);
            }

            while (kept.Count > 0 && kept[kept.Count - 1].Length == 0)
            {
                kept.RemoveAt(kept.Count - 1);
            }

            return string.Join(Environment.NewLine, kept.ToArray());
        }

        private static string CleanOutputBlock(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return "";

            string[] lines = value.Replace("\r", "").Split('\n');
            List<string> kept = new List<string>();

            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i].TrimEnd();
                string trimmed = line.Trim();

                if (trimmed.Length == 0)
                {
                    if (kept.Count > 0 && kept[kept.Count - 1].Length != 0)
                    {
                        kept.Add("");
                    }
                    continue;
                }

                if (trimmed.StartsWith("> ", StringComparison.Ordinal)) continue;
                if (IsNoiseLine(trimmed)) continue;
                if (IsKnownUiCommand(trimmed)) continue;

                if (
                    kept.Count > 0 &&
                    string.Equals(
                        NormalizeForComparison(kept[kept.Count - 1]),
                        NormalizeForComparison(line),
                        StringComparison.Ordinal
                    )
                )
                {
                    continue;
                }

                kept.Add(line);
            }

            while (kept.Count > 0 && kept[0].Length == 0)
            {
                kept.RemoveAt(0);
            }

            while (kept.Count > 0 && kept[kept.Count - 1].Length == 0)
            {
                kept.RemoveAt(kept.Count - 1);
            }

            return NormalizeBlock(string.Join(Environment.NewLine, kept.ToArray()));
        }

        private static bool IsNoiseLine(string line)
        {
            string semantic = Regex.Replace(
                line,
                "^[\\s⠀-⣿│┃┆┊┋]+",
                ""
            ).Trim();

            string lower = semantic.ToLowerInvariant();
            string originalLower = line.ToLowerInvariant();

            if (lower.Length == 0) return true;
            if (lower.StartsWith("gitlab duo cli v")) return true;
            if (lower.StartsWith("user: @")) return true;
            if (lower.StartsWith("gitlab duo access:")) return true;
            if (lower.StartsWith("could not find gitlab remote info")) return true;
            if (lower.StartsWith("cwd:")) return true;
            if (lower.StartsWith("initializing")) return true;
            if (originalLower.Contains("gitlab duo is thinking")) return true;
            if (originalLower.Contains("type your message here")) return true;
            if (originalLower.Contains("type to search sessions")) return true;
            if (originalLower.Contains("enter to load session")) return true;
            if (originalLower.Contains("tab to switch") && originalLower.Contains("gpt-")) return true;
            if (originalLower.Contains("esc to cancel") && originalLower.Contains("gpt-")) return true;
            if (lower.StartsWith("to resume, run:")) return true;
            if (originalLower.Contains("to select") && originalLower.Contains("esc to")) return true;
            if (IsKnownUiCommand(semantic)) return true;
            if (lower == ">" || lower == "›" || lower == "❯") return true;
            if (Regex.IsMatch(line, "^[─━═_\\-]{8,}$")) return true;
            if (Regex.IsMatch(line, "^[\\s⠀-⣿│┃┆┊┋]+$")) return true;

            int decorative = 0;
            for (int i = 0; i < line.Length; i++)
            {
                char ch = line[i];
                if (
                    ch == '─' || ch == '━' || ch == '═' ||
                    ch == '│' || ch == '┃' || ch == '┆' ||
                    ch == '┊' || ch == '┋'
                )
                {
                    decorative++;
                }
            }

            if (
                line.Length >= 20 &&
                decorative >= Math.Max(10, (int)Math.Floor(line.Length * 0.35))
            )
            {
                return true;
            }

            return false;
        }

        private static bool IsKnownUiCommand(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return false;

            return Regex.IsMatch(
                value.Trim(),
                "^/(?:exit|sessions|model|mcp|new|copy|feedback|settings|help|compact|doctor)(?:\\s|$)",
                RegexOptions.IgnoreCase
            );
        }

        private static bool IsNoiseBlock(string block)
        {
            string cleaned = CleanOutputBlock(block);
            if (cleaned.Length < 3) return true;

            string lower = cleaned.ToLowerInvariant();
            if (lower.Contains("type to search sessions") && lower.Contains("enter to load session"))
            {
                return true;
            }

            return false;
        }

        private static bool LooksLikeResponse(string block)
        {
            if (string.IsNullOrWhiteSpace(block)) return false;

            string trimmed = block.Trim();

            if (
                trimmed.StartsWith("●", StringComparison.Ordinal) ||
                trimmed.StartsWith("•", StringComparison.Ordinal) ||
                trimmed.StartsWith("✓", StringComparison.Ordinal) ||
                trimmed.StartsWith("✦", StringComparison.Ordinal) ||
                trimmed.StartsWith("○", StringComparison.Ordinal) ||
                trimmed.StartsWith("◉", StringComparison.Ordinal)
            )
            {
                return true;
            }

            if (trimmed.Length >= 18 && !IsKnownUiCommand(trimmed))
            {
                return true;
            }

            return false;
        }

        private static bool LooksImportantTerminal(string block)
        {
            if (string.IsNullOrWhiteSpace(block)) return false;

            return Regex.IsMatch(
                block,
                "(?i)(error|exception|failed|failure|warning|warn|ошибк|исключен|сбой|предупреж|"
                + "build|compile|compilation|test|tests|тест|gradle|forge|minecraft|stack trace|traceback|"
                + "created|updated|modified|deleted|wrote|saved|создан|обновлен|изменен|удален|сохранен|"
                + "exit code|код завершения|passed|success|успеш)"
            );
        }

        private static string NormalizeBlock(string value)
        {
            string[] lines = value.Replace("\r", "").Split('\n');
            List<string> normalized = new List<string>();

            for (int i = 0; i < lines.Length; i++)
            {
                string line = Regex.Replace(lines[i].TrimEnd(), "[ \\t]{2,}", " ");
                if (line.Trim().Length == 0) continue;

                if (
                    normalized.Count > 0 &&
                    string.Equals(
                        NormalizeForComparison(normalized[normalized.Count - 1]),
                        NormalizeForComparison(line),
                        StringComparison.Ordinal
                    )
                )
                {
                    continue;
                }

                normalized.Add(line);
            }

            return string.Join(Environment.NewLine, normalized.ToArray()).Trim();
        }

        private static string NormalizeForComparison(string value)
        {
            return Regex.Replace(value ?? "", "\\s+", " ").Trim().ToLowerInvariant();
        }

        private static string Redact(string value)
        {
            if (string.IsNullOrEmpty(value)) return value;
            string result = value;

            result = Regex.Replace(result, "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----", "[REDACTED_PRIVATE_KEY]");
            result = Regex.Replace(result, "(?i)glpat-[A-Za-z0-9_-]{12,}", "[REDACTED_GITLAB_TOKEN]");
            result = Regex.Replace(result, "\\bgh[pousr]_[A-Za-z0-9]{20,}\\b", "[REDACTED_GITHUB_TOKEN]");

            // Anthropic keys must be checked before the generic sk-* rule.
            result = Regex.Replace(result, "\\bsk-ant-[A-Za-z0-9_-]{16,}\\b", "[REDACTED_ANTHROPIC_KEY]");
            result = Regex.Replace(result, "\\bsk-[A-Za-z0-9_-]{16,}\\b", "[REDACTED_API_KEY]");

            result = Regex.Replace(result, "\\bAKIA[0-9A-Z]{16}\\b", "[REDACTED_AWS_ACCESS_KEY]");
            result = Regex.Replace(result, "(?i)(authorization\\s*[:=]\\s*(?:bearer|basic)\\s+)[A-Za-z0-9._~+\\-/=]{8,}", "$1[REDACTED]");

            // Do not replace a value that was already redacted by a more
            // specific rule. This makes redaction idempotent:
            // Redact(Redact(text)) == Redact(text).
            result = Regex.Replace(
                result,
                "(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|secret|client[_-]?secret)\\s*[:=]\\s*)(?!\\[REDACTED(?:_[A-Z0-9_]+)?\\])[^\\s'\";]{6,}",
                "$1[REDACTED]"
            );

            result = Regex.Replace(result, "\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b", "[REDACTED_JWT]");
            result = Regex.Replace(
                result,
                "(?i)(https?://[^\\s?]+\\?[^\\s]*(?:token|key|secret|signature|sig)=)(?!\\[REDACTED(?:_[A-Z0-9_]+)?\\])[^\\s&]+",
                "$1[REDACTED]"
            );

            return result;
        }

        internal static string RedactForSelfTest(string value)
        {
            return Redact(value);
        }

        private static string KeepRecentSessions(
            string value,
            int maximumSessions,
            int maximumCharacters)
        {
            if (string.IsNullOrWhiteSpace(value)) return "";

            List<int> starts = new List<int>();
            int search = 0;

            while (search < value.Length)
            {
                int index = value.IndexOf("## SESSION ", search, StringComparison.Ordinal);
                if (index < 0) break;

                starts.Add(index);
                search = index + 11;
            }

            if (starts.Count == 0)
            {
                return KeepTail(value, maximumCharacters, "### ");
            }

            int firstSession = Math.Max(0, starts.Count - maximumSessions);
            int startIndex = starts[firstSession];

            while (
                value.Length - startIndex > maximumCharacters &&
                firstSession + 1 < starts.Count
            )
            {
                firstSession++;
                startIndex = starts[firstSession];
            }

            string result = value.Substring(startIndex);

            if (result.Length <= maximumCharacters)
            {
                return result;
            }

            string notice =
                "[Earlier content from the oldest retained session was omitted.]" +
                Environment.NewLine +
                Environment.NewLine;

            int tailLength = Math.Max(1000, maximumCharacters - notice.Length);
            return notice + result.Substring(result.Length - tailLength);
        }

        private static string KeepTail(string value, int maximumCharacters, string boundary)
        {
            if (value.Length <= maximumCharacters) return value;

            int start = value.Length - maximumCharacters;
            int boundaryIndex = value.IndexOf(boundary, start, StringComparison.Ordinal);

            if (boundaryIndex >= 0)
            {
                start = boundaryIndex;
            }

            return value.Substring(start);
        }

        private static string Hash(string value)
        {
            using (SHA256 sha = SHA256.Create())
            {
                byte[] bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(value));
                StringBuilder result = new StringBuilder(bytes.Length * 2);
                for (int i = 0; i < bytes.Length; i++) result.Append(bytes[i].ToString("x2"));
                return result.ToString();
            }
        }

        private static string SafeSegment(string value)
        {
            string safe = Regex.Replace(value ?? "profile", "[^A-Za-z0-9_.-]", "_");
            return safe.Length == 0 ? "profile" : safe;
        }

        public void Dispose()
        {
            try { if (rawOutput != null) rawOutput.Dispose(); } catch { }
            try { if (rawInput != null) rawInput.Dispose(); } catch { }
        }
    }

    internal sealed class PseudoConsoleHost : IDisposable
    {
        private readonly Options options;
        private IntPtr pseudoConsole = IntPtr.Zero;
        private IntPtr inputWrite = IntPtr.Zero;
        private IntPtr outputRead = IntPtr.Zero;
        private IntPtr attributeList = IntPtr.Zero;
        private NativeMethods.PROCESS_INFORMATION processInfo;
        private uint originalInputMode;
        private uint originalOutputMode;
        private bool hasInputMode;
        private bool hasOutputMode;
        private volatile bool stopping;
        private SessionCapture capture;
        private Thread inputThread;
        private Thread outputThread;
        private Thread resizeThread;
        private int lastWidth;
        private int lastHeight;
        private string threadError = "";
        private bool childCreated;

        internal PseudoConsoleHost(Options hostOptions)
        {
            options = hostOptions;
        }

        internal int Run()
        {
            RecorderStatus.Write(options, "starting", false, false, -1, false, "", "");

            ConfigureParentConsole();
            int width = GetConsoleWidth();
            int height = GetConsoleHeight();
            lastWidth = width;
            lastHeight = height;
            capture = new SessionCapture(options, width, height);

            try
            {
                CreatePseudoConsoleAndProcess(width, height);
                childCreated = true;
                RecorderStatus.Write(options, "child-started", true, false, -1, false, capture.SessionDirectory, "");

                outputThread = new Thread(OutputLoop);
                outputThread.Name = "DuoRecorder-Output";
                outputThread.IsBackground = true;
                outputThread.Start();

                if (options.ForwardInput)
                {
                    inputThread = new Thread(InputLoop);
                    inputThread.Name = "DuoRecorder-Input";
                    inputThread.IsBackground = true;
                    inputThread.Start();
                }

                resizeThread = new Thread(ResizeLoop);
                resizeThread.Name = "DuoRecorder-Resize";
                resizeThread.IsBackground = true;
                resizeThread.Start();

                uint wait = NativeMethods.WaitForSingleObject(processInfo.hProcess, NativeMethods.INFINITE);
                if (wait == NativeMethods.WAIT_FAILED) ThrowLastError("WaitForSingleObject");
                stopping = true;

                try
                {
                    if (inputWrite != IntPtr.Zero)
                    {
                        NativeMethods.CloseHandle(inputWrite);
                        inputWrite = IntPtr.Zero;
                    }
                }
                catch { }

                try
                {
                    if (pseudoConsole != IntPtr.Zero)
                    {
                        NativeMethods.ClosePseudoConsole(pseudoConsole);
                        pseudoConsole = IntPtr.Zero;
                    }
                }
                catch { }

                try { if (outputThread != null) outputThread.Join(3500); } catch { }
                try { if (resizeThread != null) resizeThread.Join(800); } catch { }

                uint childExitCode;
                if (!NativeMethods.GetExitCodeProcess(processInfo.hProcess, out childExitCode)) childExitCode = 255;

                capture.Complete(unchecked((int)childExitCode));

                string error = threadError;
                if (!string.IsNullOrWhiteSpace(capture.CaptureError))
                {
                    if (error.Length > 0) error += " | ";
                    error += capture.CaptureError;
                }

                RecorderStatus.Write(
                    options,
                    "completed",
                    true,
                    true,
                    unchecked((int)childExitCode),
                    capture.TranscriptUpdated,
                    capture.SessionDirectory,
                    error
                );

                return unchecked((int)childExitCode);
            }
            catch (Exception ex)
            {
                stopping = true;

                RecorderStatus.Write(
                    options,
                    "failed",
                    childCreated,
                    false,
                    -1,
                    false,
                    capture != null ? capture.SessionDirectory : "",
                    ex.ToString()
                );

                throw;
            }
        }

        private void ConfigureParentConsole()
        {
            NativeMethods.SetConsoleCP(65001);
            NativeMethods.SetConsoleOutputCP(65001);
            try
            {
                Console.InputEncoding = new UTF8Encoding(false);
                Console.OutputEncoding = new UTF8Encoding(false);
            }
            catch { }

            IntPtr stdIn = NativeMethods.GetStdHandle(NativeMethods.STD_INPUT_HANDLE);
            if (options.ForwardInput)
            {
                if (!NativeMethods.GetConsoleMode(stdIn, out originalInputMode))
                    ThrowLastError("GetConsoleMode(input)");

                hasInputMode = true;
                uint mode = originalInputMode;
                mode |= NativeMethods.ENABLE_VIRTUAL_TERMINAL_INPUT | NativeMethods.ENABLE_EXTENDED_FLAGS;
                mode &= ~(
                    NativeMethods.ENABLE_PROCESSED_INPUT |
                    NativeMethods.ENABLE_LINE_INPUT |
                    NativeMethods.ENABLE_ECHO_INPUT |
                    NativeMethods.ENABLE_QUICK_EDIT_MODE
                );

                if (!NativeMethods.SetConsoleMode(stdIn, mode))
                    ThrowLastError("SetConsoleMode(input)");
            }

            IntPtr stdOut = NativeMethods.GetStdHandle(NativeMethods.STD_OUTPUT_HANDLE);
            if (options.PresentOutput)
            {
                if (!NativeMethods.GetConsoleMode(stdOut, out originalOutputMode))
                    ThrowLastError("GetConsoleMode(output)");

                hasOutputMode = true;
                uint mode = originalOutputMode |
                    NativeMethods.ENABLE_PROCESSED_OUTPUT |
                    NativeMethods.ENABLE_WRAP_AT_EOL_OUTPUT |
                    NativeMethods.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
                    NativeMethods.DISABLE_NEWLINE_AUTO_RETURN;

                if (!NativeMethods.SetConsoleMode(stdOut, mode))
                    ThrowLastError("SetConsoleMode(output)");
            }
        }

        private void CreatePseudoConsoleAndProcess(int width, int height)
        {
            IntPtr inputRead = IntPtr.Zero;
            IntPtr outputWrite = IntPtr.Zero;

            try
            {
                if (!NativeMethods.CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0))
                    ThrowLastError("CreatePipe(input)");

                if (!NativeMethods.CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0))
                    ThrowLastError("CreatePipe(output)");

                if (!NativeMethods.SetHandleInformation(inputWrite, NativeMethods.HANDLE_FLAG_INHERIT, 0))
                    ThrowLastError("SetHandleInformation(input)");

                if (!NativeMethods.SetHandleInformation(outputRead, NativeMethods.HANDLE_FLAG_INHERIT, 0))
                    ThrowLastError("SetHandleInformation(output)");

                int hr = NativeMethods.CreatePseudoConsole(
                    new NativeMethods.COORD((short)width, (short)height),
                    inputRead,
                    outputWrite,
                    0,
                    out pseudoConsole
                );
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);

                NativeMethods.CloseHandle(inputRead);
                inputRead = IntPtr.Zero;
                NativeMethods.CloseHandle(outputWrite);
                outputWrite = IntPtr.Zero;

                IntPtr attributeSize = IntPtr.Zero;
                NativeMethods.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeSize);
                if (attributeSize == IntPtr.Zero)
                    ThrowLastError("InitializeProcThreadAttributeList(size)");

                attributeList = Marshal.AllocHGlobal(attributeSize);
                if (!NativeMethods.InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeSize))
                    ThrowLastError("InitializeProcThreadAttributeList");

                // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE expects the HPCON
                // handle itself as lpValue. Passing a pointer that contains
                // the handle makes the child fail during console startup
                // with STATUS_DLL_INIT_FAILED (0xC0000142).
                if (!NativeMethods.UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    new IntPtr((long)NativeMethods.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE),
                    pseudoConsole,
                    new IntPtr(IntPtr.Size),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    ThrowLastError("UpdateProcThreadAttribute");
                }

                NativeMethods.STARTUPINFOEX startup = new NativeMethods.STARTUPINFOEX();
                startup.StartupInfo.cb = Marshal.SizeOf(typeof(NativeMethods.STARTUPINFOEX));
                startup.lpAttributeList = attributeList;

                string executable = options.Command[0];
                StringBuilder commandLine = new StringBuilder(BuildCommandLine(options.Command));

                bool created = NativeMethods.CreateProcessW(
                    executable,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    false,
                    NativeMethods.EXTENDED_STARTUPINFO_PRESENT | NativeMethods.CREATE_UNICODE_ENVIRONMENT,
                    IntPtr.Zero,
                    options.WorkingDirectory,
                    ref startup,
                    out processInfo
                );

                if (!created) ThrowLastError("CreateProcessW");

                if (processInfo.hThread != IntPtr.Zero)
                {
                    NativeMethods.CloseHandle(processInfo.hThread);
                    processInfo.hThread = IntPtr.Zero;
                }
            }
            finally
            {
                if (inputRead != IntPtr.Zero) NativeMethods.CloseHandle(inputRead);
                if (outputWrite != IntPtr.Zero) NativeMethods.CloseHandle(outputWrite);
            }
        }

        private void InputLoop()
        {
            try
            {
                IntPtr stdIn = NativeMethods.GetStdHandle(NativeMethods.STD_INPUT_HANDLE);
                byte[] buffer = new byte[4096];

                while (!stopping)
                {
                    int read;
                    bool ok = NativeMethods.ReadFile(stdIn, buffer, buffer.Length, out read, IntPtr.Zero);
                    if (!ok || read <= 0)
                    {
                        if (stopping) break;
                        Thread.Sleep(20);
                        continue;
                    }

                    if (stopping) break;

                    try { capture.ProcessInput(buffer, read); }
                    catch (Exception ex) { RecordThreadError("input-capture", ex); }

                    if (!WriteAll(inputWrite, buffer, read)) break;
                }
            }
            catch (Exception ex)
            {
                RecordThreadError("input-loop", ex);
            }
        }

        private void OutputLoop()
        {
            try
            {
                IntPtr stdOut = NativeMethods.GetStdHandle(NativeMethods.STD_OUTPUT_HANDLE);
                byte[] buffer = new byte[8192];
                bool presentationAvailable = options.PresentOutput;

                while (true)
                {
                    int read;
                    bool ok = NativeMethods.ReadFile(outputRead, buffer, buffer.Length, out read, IntPtr.Zero);
                    if (!ok || read <= 0) break;

                    try { capture.ProcessOutput(buffer, read); }
                    catch (Exception ex) { RecordThreadError("output-capture", ex); }

                    if (presentationAvailable && !WriteAll(stdOut, buffer, read))
                    {
                        presentationAvailable = false;
                        RecordThreadError("output-presentation", new IOException("Parent console output is unavailable."));
                    }
                }
            }
            catch (Exception ex)
            {
                RecordThreadError("output-loop", ex);
            }
        }

        private void ResizeLoop()
        {
            while (!stopping)
            {
                Thread.Sleep(300);

                try
                {
                    int width = GetConsoleWidth();
                    int height = GetConsoleHeight();
                    if (width == lastWidth && height == lastHeight) continue;

                    lastWidth = width;
                    lastHeight = height;
                    capture.Resize(width, height);

                    if (pseudoConsole != IntPtr.Zero)
                    {
                        int hr = NativeMethods.ResizePseudoConsole(
                            pseudoConsole,
                            new NativeMethods.COORD((short)width, (short)height)
                        );
                        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
                    }
                }
                catch (Exception ex)
                {
                    RecordThreadError("resize-loop", ex);
                }
            }
        }

        private void RecordThreadError(string source, Exception exception)
        {
            string message = source + ": " + exception.Message;
            if (threadError.Length == 0) threadError = message;
            else if (threadError.IndexOf(message, StringComparison.Ordinal) < 0) threadError += " | " + message;

            try
            {
                File.AppendAllText(
                    Path.Combine(options.LogRoot, "recorder-thread-errors.log"),
                    DateTime.UtcNow.ToString("o") + " " + message + Environment.NewLine,
                    new UTF8Encoding(false)
                );
            }
            catch { }
        }

        private static bool WriteAll(IntPtr handle, byte[] buffer, int count)
        {
            int offset = 0;
            while (offset < count)
            {
                int remaining = count - offset;
                byte[] chunk;

                if (offset == 0 && remaining == buffer.Length)
                {
                    chunk = buffer;
                }
                else
                {
                    chunk = new byte[remaining];
                    Buffer.BlockCopy(buffer, offset, chunk, 0, remaining);
                }

                int written;
                if (!NativeMethods.WriteFile(handle, chunk, remaining, out written, IntPtr.Zero) || written <= 0)
                    return false;

                offset += written;
            }
            return true;
        }

        private static int GetConsoleWidth()
        {
            try { return Math.Max(40, Math.Min(300, Console.WindowWidth)); }
            catch { return 120; }
        }

        private static int GetConsoleHeight()
        {
            try { return Math.Max(20, Math.Min(120, Console.WindowHeight)); }
            catch { return 40; }
        }

        private static string BuildCommandLine(List<string> arguments)
        {
            StringBuilder result = new StringBuilder();
            for (int i = 0; i < arguments.Count; i++)
            {
                if (i > 0) result.Append(' ');
                result.Append(QuoteArgument(arguments[i]));
            }
            return result.ToString();
        }

        private static string QuoteArgument(string value)
        {
            if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
                return value;

            StringBuilder result = new StringBuilder();
            result.Append('"');
            int backslashes = 0;

            for (int i = 0; i < value.Length; i++)
            {
                char ch = value[i];
                if (ch == '\\')
                {
                    backslashes++;
                    continue;
                }

                if (ch == '"')
                {
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('"');
                    backslashes = 0;
                    continue;
                }

                if (backslashes > 0)
                {
                    result.Append('\\', backslashes);
                    backslashes = 0;
                }

                result.Append(ch);
            }

            if (backslashes > 0) result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private static void ThrowLastError(string operation)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed");
        }

        public void Dispose()
        {
            stopping = true;
            RestoreParentConsole();

            if (processInfo.hProcess != IntPtr.Zero)
            {
                NativeMethods.CloseHandle(processInfo.hProcess);
                processInfo.hProcess = IntPtr.Zero;
            }

            if (inputWrite != IntPtr.Zero)
            {
                NativeMethods.CloseHandle(inputWrite);
                inputWrite = IntPtr.Zero;
            }

            if (outputRead != IntPtr.Zero)
            {
                NativeMethods.CloseHandle(outputRead);
                outputRead = IntPtr.Zero;
            }

            if (attributeList != IntPtr.Zero)
            {
                NativeMethods.DeleteProcThreadAttributeList(attributeList);
                Marshal.FreeHGlobal(attributeList);
                attributeList = IntPtr.Zero;
            }

            if (pseudoConsole != IntPtr.Zero)
            {
                NativeMethods.ClosePseudoConsole(pseudoConsole);
                pseudoConsole = IntPtr.Zero;
            }

            if (capture != null)
            {
                capture.Dispose();
                capture = null;
            }
        }

        private void RestoreParentConsole()
        {
            if (hasInputMode)
            {
                IntPtr stdIn = NativeMethods.GetStdHandle(NativeMethods.STD_INPUT_HANDLE);
                NativeMethods.SetConsoleMode(stdIn, originalInputMode);
            }

            if (hasOutputMode)
            {
                IntPtr stdOut = NativeMethods.GetStdHandle(NativeMethods.STD_OUTPUT_HANDLE);
                NativeMethods.SetConsoleMode(stdOut, originalOutputMode);
            }
        }
    }

    internal static class RecorderSelfTest
    {
        internal static int Run()
        {
            string root = Path.Combine(Path.GetTempPath(), "DuoRecorderSelfTest-" + Guid.NewGuid().ToString("N"));

            try
            {
                Directory.CreateDirectory(root);
                string bridge = Path.Combine(root, "CHAT_BRIDGE.md");

                Options options = new Options();
                options.LogRoot = Path.Combine(root, "sessions");
                options.BridgePath = bridge;
                options.WorkingDirectory = root;
                options.Profile = "self-test";
                options.Username = "tester";
                options.Model = "test-model";
                options.ProjectName = "test-project";
                options.RawLogs = false;
                options.MaximumSessions = 3;
                options.MaximumStorageBytes = 50L * 1024L * 1024L;

                string redactionInput =
                    "SECRET=sk-abcdefghijklmnop " +
                    "api_key=plainsecret123 " +
                    "anthropic=sk-ant-abcdefghijklmnop " +
                    "gitlab=glpat-abcdefghijkl " +
                    "authorization: Bearer abcdefghijklmnop";

                string redactionOnce = SessionCapture.RedactForSelfTest(redactionInput);
                string redactionTwice = SessionCapture.RedactForSelfTest(redactionOnce);

                if (redactionOnce.IndexOf("sk-abcdefghijklmnop", StringComparison.Ordinal) >= 0)
                    throw new Exception("SECRET_REDACTION: API key remained visible.");

                if (redactionOnce.IndexOf("plainsecret123", StringComparison.Ordinal) >= 0)
                    throw new Exception("SECRET_REDACTION: generic secret remained visible.");

                if (redactionOnce.IndexOf("sk-ant-abcdefghijklmnop", StringComparison.Ordinal) >= 0)
                    throw new Exception("SECRET_REDACTION: Anthropic key remained visible.");

                if (redactionOnce.IndexOf("glpat-abcdefghijkl", StringComparison.Ordinal) >= 0)
                    throw new Exception("SECRET_REDACTION: GitLab token remained visible.");

                if (redactionOnce.IndexOf("abcdefghijklmnop", StringComparison.Ordinal) >= 0)
                    throw new Exception("SECRET_REDACTION: bearer token remained visible.");

                if (redactionOnce.IndexOf("[REDACTED_API_KEY]", StringComparison.Ordinal) < 0)
                    throw new Exception("SECRET_REDACTION: API marker is missing.");

                if (redactionOnce.IndexOf("[REDACTED_ANTHROPIC_KEY]", StringComparison.Ordinal) < 0)
                    throw new Exception("SECRET_REDACTION: Anthropic marker is missing.");

                if (redactionOnce.IndexOf("[REDACTED_GITLAB_TOKEN]", StringComparison.Ordinal) < 0)
                    throw new Exception("SECRET_REDACTION: GitLab marker is missing.");

                if (!string.Equals(redactionOnce, redactionTwice, StringComparison.Ordinal))
                    throw new Exception("SECRET_REDACTION: redaction is not idempotent.");

                Console.WriteLine("SELF_TEST SECRET_REDACTION: OK");

                SessionCapture capture = new SessionCapture(options, 100, 30);

                byte[] input = Encoding.UTF8.GetBytes("\x1b[200~строка 1\nстрока 2\x1b[201~\r");
                capture.ProcessInput(input, input.Length);

                string outputText =
                    "\x1b[2J\x1b[H" +
                    "GitLab Duo CLI v9.3.0\r\n" +
                    "User: @tester\r\n" +
                    "GitLab Duo access: available\r\n" +
                    "Initializing -\r\n" +
                    "GitLab Duo is thinking...\r\n" +
                    "> строка 1\r\n" +
                    "● Ответ self-test SECRET=sk-abcdefghijklmnop\r\n" +
                    "/sessions Browse and switch between chat sessions\r\n" +
                    "build (tab to switch) GPT-5.6 Sol - OpenAI\r\n";

                byte[] output = Encoding.UTF8.GetBytes(outputText);
                capture.ProcessOutput(output, output.Length);
                Thread.Sleep(80);
                capture.Complete(0);
                capture.Dispose();

                if (!File.Exists(bridge))
                    throw new Exception("BRIDGE_CREATION: bridge was not created.");
                Console.WriteLine("SELF_TEST BRIDGE_CREATION: OK");

                string content = File.ReadAllText(bridge, Encoding.UTF8);

                if (content.IndexOf("строка 1", StringComparison.Ordinal) < 0)
                    throw new Exception("INPUT_PARSER: first pasted line was not reconstructed.");

                if (content.IndexOf("строка 2", StringComparison.Ordinal) < 0)
                    throw new Exception("INPUT_PARSER: second pasted line was not reconstructed.");

                Console.WriteLine("SELF_TEST MULTILINE_PASTE: OK");

                if (content.IndexOf("Ответ self-test", StringComparison.Ordinal) < 0)
                    throw new Exception("SCREEN_CAPTURE: visible output was not captured.");

                Console.WriteLine("SELF_TEST SCREEN_CAPTURE: OK");

                if (content.IndexOf("sk-abcdefghijklmnop", StringComparison.Ordinal) >= 0)
                    throw new Exception("TRANSCRIPT_REDACTION: secret remained visible.");

                if (content.IndexOf("[REDACTED_API_KEY]", StringComparison.Ordinal) < 0)
                    throw new Exception("TRANSCRIPT_REDACTION: API marker is missing.");

                Console.WriteLine("SELF_TEST TRANSCRIPT_REDACTION: OK");

                if (content.IndexOf("GitLab Duo is thinking", StringComparison.OrdinalIgnoreCase) >= 0)
                    throw new Exception("TRANSCRIPT_OPTIMIZER: thinking spinner remained.");

                if (content.IndexOf("/sessions Browse", StringComparison.OrdinalIgnoreCase) >= 0)
                    throw new Exception("TRANSCRIPT_OPTIMIZER: command menu remained.");

                if (content.IndexOf("build (tab to switch)", StringComparison.OrdinalIgnoreCase) >= 0)
                    throw new Exception("TRANSCRIPT_OPTIMIZER: status bar remained.");

                if (content.IndexOf("### Conversation", StringComparison.Ordinal) < 0)
                    throw new Exception("TRANSCRIPT_OPTIMIZER: conversation section is missing.");

                if (content.IndexOf("#### USER", StringComparison.Ordinal) < 0)
                    throw new Exception("TRANSCRIPT_OPTIMIZER: user turn is missing.");

                if (content.IndexOf("#### RESPONSE / RELEVANT OUTPUT", StringComparison.Ordinal) < 0)
                    throw new Exception("TRANSCRIPT_OPTIMIZER: response turn is missing.");

                if (content.IndexOf("optimized-visible-conversation-v3", StringComparison.Ordinal) < 0)
                    throw new Exception("TRANSCRIPT_OPTIMIZER: bridge schema is missing.");

                Console.WriteLine("SELF_TEST TRANSCRIPT_OPTIMIZER: OK");
                Console.WriteLine("DuoTerminalRecorder 1.2.0 self-test OK");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Self-test failed: " + ex.Message);
                return 212;
            }
            finally
            {
                try { if (Directory.Exists(root)) Directory.Delete(root, true); } catch { }
            }
        }
    }

    internal static class Program
    {
        private const int ExitUnsupported = 210;
        private const int ExitRecorderFailure = 211;

        public static int Main(string[] args)
        {
            Options options = null;

            try
            {
                if (args.Length == 1 && args[0] == "--self-test")
                {
                    return RecorderSelfTest.Run();
                }

                if (args.Length == 1 && args[0] == "--version")
                {
                    Console.WriteLine("DuoTerminalRecorder 1.2.0");
                    return 0;
                }

                if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                {
                    Console.Error.WriteLine("DuoTerminalRecorder supports Windows only.");
                    return ExitUnsupported;
                }

                options = Options.Parse(args);

                using (PseudoConsoleHost host = new PseudoConsoleHost(options))
                {
                    return host.Run();
                }
            }
            catch (EntryPointNotFoundException ex)
            {
                RecorderStatus.Write(options, "unsupported", false, false, ExitUnsupported, false, "", ex.Message);
                Console.Error.WriteLine("ConPTY is unavailable: " + ex.Message);
                return ExitUnsupported;
            }
            catch (Exception ex)
            {
                try
                {
                    if (
                        options != null &&
                        (
                            string.IsNullOrWhiteSpace(options.RunStatusPath) ||
                            !File.Exists(options.RunStatusPath)
                        )
                    )
                    {
                        RecorderStatus.Write(options, "failed", false, false, ExitRecorderFailure, false, "", ex.ToString());
                    }

                    string root = options != null ? options.LogRoot : null;
                    if (string.IsNullOrWhiteSpace(root))
                    {
                        for (int i = 0; i + 1 < args.Length; i++)
                        {
                            if (args[i] == "--log-root") root = args[i + 1];
                        }
                    }

                    if (!string.IsNullOrWhiteSpace(root))
                    {
                        Directory.CreateDirectory(root);
                        File.AppendAllText(
                            Path.Combine(root, "recorder-error.log"),
                            DateTime.UtcNow.ToString("o") + Environment.NewLine + ex.ToString() + Environment.NewLine + Environment.NewLine,
                            new UTF8Encoding(false)
                        );
                    }
                }
                catch { }

                Console.Error.WriteLine("DuoTerminalRecorder error: " + ex.Message);
                return ExitRecorderFailure;
            }
        }
    }

}