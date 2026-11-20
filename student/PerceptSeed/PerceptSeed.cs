using System;
using System.IO;
using System.Text.Json;

namespace Kokoro.Student;

public sealed record PerceptDefinition(string Identity, string Kind, float[] Key, string? Parent);

public sealed record Observation(
    string Identity, string Percept, string Occurrence, string Provenance, string Condition, JsonElement Measured);

public sealed record PerceptSeed(int SchemaVersion, PerceptDefinition[] Percepts, Observation[] Evidence)
{
    public static PerceptSeed Read()
    {
        using Stream resource = typeof(PerceptSeed).Assembly.GetManifestResourceStream("Kokoro.Student.PerceptSeed.v1.json")
            ?? throw new InvalidDataException("The assembly does not contain a percept seed.");
        PerceptSeed seed = JsonSerializer.Deserialize<PerceptSeed>(resource)
            ?? throw new InvalidDataException("The percept seed is empty.");
        if (seed.SchemaVersion != 1 || seed.Percepts is null || seed.Evidence is null)
            throw new InvalidDataException("Unsupported percept seed schema.");
        return seed;
    }
}
