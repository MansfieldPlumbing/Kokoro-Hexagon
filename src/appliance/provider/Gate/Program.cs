using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using MansfieldPlumbing.Kokoro;

string root = Path.GetFullPath(args[0]);
Stopwatch clock = Stopwatch.StartNew();
if (ProviderHost.Initialize(root) != ProviderHost.Ready) throw new InvalidOperationException("Initialize failed.");
double initializeMs = clock.Elapsed.TotalMilliseconds;
string profileHash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.Combine(root, "gate-profile.ps1"))));
clock.Restart();
if (ProviderHost.LoadProfile("gate-profile.ps1", profileHash) != ProviderHost.Ready) throw new InvalidOperationException("Profile failed.");
double profileMs = clock.Elapsed.TotalMilliseconds;
byte[] input = Encoding.UTF8.GetBytes("Kokoro stays resident.");
byte[] output = new byte[256];
GCHandle inputPin = GCHandle.Alloc(input, GCHandleType.Pinned);
GCHandle outputPin = GCHandle.Alloc(output, GCHandleType.Pinned);
try
{
    clock.Restart();
    int count = ProviderHost.InvokeTextUtf8(inputPin.AddrOfPinnedObject(), input.Length, outputPin.AddrOfPinnedObject(), output.Length);
    double firstInvokeMs = clock.Elapsed.TotalMilliseconds;
    if (count < 0)
    {
        byte[] error = new byte[2048];
        GCHandle errorPin = GCHandle.Alloc(error, GCHandleType.Pinned);
        try
        {
            int errorLength = ProviderHost.GetLastErrorUtf8(errorPin.AddrOfPinnedObject(), error.Length);
            string message = errorLength >= 0 ? Encoding.UTF8.GetString(error, 0, errorLength) : "error buffer too small";
            throw new InvalidOperationException($"Invoke failed: {count}: {message}");
        }
        finally { errorPin.Free(); }
    }
    string actual = Encoding.UTF8.GetString(output, 0, count);
    if (actual != "KOKORO STAYS RESIDENT.") throw new InvalidOperationException(actual);
    const int iterations = 1_000;
    clock.Restart();
    for (int index = 0; index < iterations; index++)
    {
        int warmCount = ProviderHost.InvokeTextUtf8(inputPin.AddrOfPinnedObject(), input.Length, outputPin.AddrOfPinnedObject(), output.Length);
        if (warmCount != count) throw new InvalidOperationException("Warm invoke changed the output length.");
    }
    double warmMeanUs = clock.Elapsed.TotalMilliseconds * 1_000 / iterations;
    Console.WriteLine($"ProviderReady=True InputBytes={input.Length} OutputBytes={count} InitializeMs={initializeMs:F3} ProfileMs={profileMs:F3} FirstInvokeMs={firstInvokeMs:F3} WarmMeanUs={warmMeanUs:F3} Result={actual}");
}
finally
{
    outputPin.Free();
    inputPin.Free();
    ProviderHost.Shutdown();
}
