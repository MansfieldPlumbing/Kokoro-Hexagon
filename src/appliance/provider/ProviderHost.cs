using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace MansfieldPlumbing.Kokoro;

public static class ProviderHost
{
    public const int Ready = 0x4B4F4B4F; // KOKO
    private const int MaximumTextBytes = 262_144;
    private static readonly object Gate = new();
    private static Runspace? s_runspace;
    private static ScriptBlock? s_handler;
    private static string? s_dataRoot;
    private static string s_lastError = "";

    public static int Initialize(string dataRoot)
    {
        lock (Gate)
        {
            try
            {
                if (s_runspace is not null) return Ready;
                if (string.IsNullOrWhiteSpace(dataRoot)) throw new ArgumentException("Data root is required.", nameof(dataRoot));
                string root = Path.GetFullPath(dataRoot);
                if (!Directory.Exists(root)) throw new DirectoryNotFoundException(root);

                InitialSessionState state = InitialSessionState.Create();
                state.LanguageMode = PSLanguageMode.FullLanguage;
                state.ThreadOptions = PSThreadOptions.ReuseThread;
                Runspace runspace = RunspaceFactory.CreateRunspace(state);
                runspace.Open();
                s_dataRoot = root;
                s_runspace = runspace;
                s_lastError = "";
                return Ready;
            }
            catch (Exception error) { return Fail(error); }
        }
    }

    public static int LoadProfile(string relativePath, string expectedSha256)
    {
        lock (Gate)
        {
            try
            {
                Runspace runspace = RequireRunspace();
                string profile = ResolveInsideDataRoot(relativePath);
                byte[] profileBytes = File.ReadAllBytes(profile);
                string actualSha256 = Convert.ToHexString(SHA256.HashData(profileBytes));
                if (!actualSha256.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Provider profile SHA-256 does not match its admission pin.");
                string source = new UTF8Encoding(false, true).GetString(profileBytes);
                _ = System.Management.Automation.Language.Parser.ParseInput(source, out _, out var parseErrors);
                if (parseErrors.Length != 0) throw new InvalidDataException($"Provider profile has {parseErrors.Length} PowerShell parse error(s).");
                using PowerShell shell = PowerShell.Create();
                shell.Runspace = runspace;
                shell.AddScript(source, useLocalScope: false);
                _ = shell.Invoke();
                if (shell.HadErrors) throw new InvalidOperationException(shell.Streams.Error[0].ToString());
                object? handler = runspace.SessionStateProxy.GetVariable("KokoroProviderHandle");
                if (handler is not ScriptBlock scriptBlock) throw new InvalidOperationException("Profile did not define $global:KokoroProviderHandle as a script block.");
                s_handler = scriptBlock;
                s_lastError = "";
                return Ready;
            }
            catch (Exception error) { return Fail(error); }
        }
    }

    public static byte[] InvokeText(string text)
    {
        lock (Gate)
        {
            _ = RequireRunspace();
            if (Encoding.UTF8.GetByteCount(text) > MaximumTextBytes) throw new ArgumentOutOfRangeException(nameof(text));
            ScriptBlock handler = s_handler ?? throw new InvalidOperationException("Provider profile is not loaded.");
            object? value = handler.InvokeReturnAsIs(text);
            if (value is PSObject wrapped) value = wrapped.BaseObject;
            if (value is not byte[] bytes) throw new InvalidOperationException("Kokoro provider handler must return one byte array.");
            s_lastError = "";
            return bytes;
        }
    }

    public static int InitializeUtf8(IntPtr dataRoot, int dataRootLength)
    {
        try { return Initialize(ReadUtf8(dataRoot, dataRootLength)); }
        catch (Exception error) { return Fail(error); }
    }

    public static int LoadProfileUtf8(IntPtr relativePath, int relativePathLength, IntPtr expectedSha256, int expectedSha256Length)
    {
        try { return LoadProfile(ReadUtf8(relativePath, relativePathLength), ReadUtf8(expectedSha256, expectedSha256Length)); }
        catch (Exception error) { return Fail(error); }
    }

    public static int InvokeTextUtf8(IntPtr text, int textLength, IntPtr destination, int destinationCapacity)
    {
        try
        {
            byte[] result = InvokeText(ReadUtf8(text, textLength));
            if (destinationCapacity < result.Length) return -result.Length;
            if (result.Length > 0) Marshal.Copy(result, 0, destination, result.Length);
            return result.Length;
        }
        catch (Exception error) { return Fail(error); }
    }

    public static int GetLastErrorUtf8(IntPtr destination, int destinationCapacity)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(s_lastError);
        if (destinationCapacity < bytes.Length) return -bytes.Length;
        if (bytes.Length > 0) Marshal.Copy(bytes, 0, destination, bytes.Length);
        return bytes.Length;
    }

    public static void Shutdown()
    {
        lock (Gate)
        {
            s_handler = null;
            s_runspace?.Dispose();
            s_runspace = null;
            s_dataRoot = null;
        }
    }

    private static string ReadUtf8(IntPtr address, int length)
    {
        if (length < 0 || length > MaximumTextBytes) throw new ArgumentOutOfRangeException(nameof(length));
        if (length == 0) return "";
        if (address == IntPtr.Zero) throw new ArgumentNullException(nameof(address));
        byte[] bytes = new byte[length];
        Marshal.Copy(address, bytes, 0, length);
        return new UTF8Encoding(false, true).GetString(bytes);
    }

    private static string ResolveInsideDataRoot(string relativePath)
    {
        if (s_dataRoot is null) throw new InvalidOperationException("Provider is not initialized.");
        if (Path.IsPathRooted(relativePath)) throw new ArgumentException("Profile path must be relative.", nameof(relativePath));
        string path = Path.GetFullPath(Path.Combine(s_dataRoot, relativePath));
        string prefix = s_dataRoot.EndsWith(Path.DirectorySeparatorChar) ? s_dataRoot : s_dataRoot + Path.DirectorySeparatorChar;
        if (!path.StartsWith(prefix, StringComparison.Ordinal)) throw new UnauthorizedAccessException("Profile path escapes the data root.");
        return path;
    }

    private static Runspace RequireRunspace() => s_runspace ?? throw new InvalidOperationException("Provider is not initialized.");

    private static int Fail(Exception error)
    {
        s_lastError = $"{error.GetType().FullName}: {error.Message}";
        return error.HResult != 0 ? error.HResult : -1;
    }
}
