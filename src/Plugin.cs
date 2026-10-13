using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using BepInEx;
using BepInEx.Unity.IL2CPP;
using HarmonyLib;

namespace Private.StructuredKoreanBridge;

[BepInPlugin("private.structured.korean.bridge", "Private Structured Korean Bridge", "0.1.1")]
public sealed class Plugin : BasePlugin
{
    private const BindingFlags Instance = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    private static readonly Dictionary<string, List<Row>> Tables = new(StringComparer.Ordinal);
    private static readonly HashSet<(IntPtr, int)> Applied = new();
    private static Plugin? _plugin;
    private static Harmony? _harmony;
    [ThreadStatic] private static bool _busy;
    private static int _failureCount;

    public override void Load()
    {
        _plugin = this;
        try
        {
            if (!Config.Bind("General", "Enabled", true, "Apply the private overlay to existing Korean locale tables.").Value)
                return;
            var app = FindType("UnityEngine.Application");
            if ((string?)app.GetProperty("unityVersion", BindingFlags.Static | BindingFlags.Public)?.GetValue(null) != "2021.3.45f2")
                throw new InvalidOperationException("E_ENGINE_VERSION_MISMATCH");
            var directory = Path.GetDirectoryName(typeof(Plugin).Assembly.Location)!;
            LoadPayload(directory);
            ValidateBinding(directory);
            var table = FindType("UnityEngine.Localization.Tables.StringTable");
            var entry = FindType("UnityEngine.Localization.Tables.StringTableEntry");
            ValidateSurface(table, entry);
            _harmony = new Harmony("private.structured.korean.bridge");
            var tablePrefix = new HarmonyMethod(typeof(Plugin).GetMethod(nameof(TablePrefix), BindingFlags.Static | BindingFlags.NonPublic));
            var entryPrefix = new HarmonyMethod(typeof(Plugin).GetMethod(nameof(EntryPrefix), BindingFlags.Static | BindingFlags.NonPublic));
            var tableMethods = table.GetMethods(Instance).Where(m =>
                (m.Name == "GetEntry" || m.Name == "GetEntryFromReference" || m.Name == "get_Item") &&
                m.GetParameters().Length == 1 && !m.IsGenericMethod).Distinct().ToArray();
            if (tableMethods.Length == 0) throw new InvalidOperationException("E_TABLE_LOOKUP_SURFACE_MISSING");
            foreach (var method in tableMethods) _harmony.Patch(method, prefix: tablePrefix);
            // All overloads run their original formatter after the raw value and format cache are updated.
            var entryMethods = entry.GetMethods(Instance).Where(m =>
                m.Name == "GetLocalizedString" || m.Name == "GetOrCreateFormatCache" ||
                m.Name == "get_Value" || m.Name == "get_LocalizedValue").Distinct().ToArray();
            if (entryMethods.Length == 0) throw new InvalidOperationException("E_ENTRY_FORMAT_SURFACE_MISSING");
            foreach (var method in entryMethods) _harmony.Patch(method, prefix: entryPrefix);
            Log.LogInfo($"I_BRIDGE_READY tables={Tables.Count} rows={Tables.Values.Sum(x => x.Count)} hooks={tableMethods.Length + entryMethods.Length}");
        }
        catch (Exception ex)
        {
            _harmony?.UnpatchSelf();
            Tables.Clear();
            Log.LogError(ex is InvalidOperationException && ex.Message.StartsWith("E_", StringComparison.Ordinal)
                ? ex.Message : "E_BRIDGE_LOAD_FAILED");
        }
    }

    private static void ValidateBinding(string directory)
    {
        var bindings = JsonSerializer.Deserialize<List<Binding>>(File.ReadAllBytes(Path.Combine(directory, "source-binding.json")))
            ?? throw new InvalidOperationException("E_SOURCE_BINDING_INVALID");
        var root = Path.GetFullPath(Paths.GameRootPath) + Path.DirectorySeparatorChar;
        if (bindings.Count != 3) throw new InvalidOperationException("E_SOURCE_BINDING_INVALID");
        foreach (var binding in bindings)
        {
            var path = Path.GetFullPath(Path.Combine(root, binding.relative_path));
            if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase) || !File.Exists(path))
                throw new InvalidOperationException("E_SOURCE_BINDING_INVALID");
            using var stream = File.OpenRead(path);
            using var digest = SHA256.Create();
            if (!string.Equals(Convert.ToHexString(digest.ComputeHash(stream)), binding.sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("E_GAME_DATA_VERSION_MISMATCH");
        }
    }

    public override bool Unload()
    {
        // Memory changes are intentionally not reversed while components may retain formatted caches.
        // Disable by removing the additive package and restarting the process.
        return false;
    }

    private static void LoadPayload(string directory)
    {
        var path = Path.Combine(directory, "ko-structured.json");
        var bytes = File.ReadAllBytes(path);
        var expected = File.ReadAllText(Path.Combine(directory, "ko-structured.sha256")).Trim();
        if (!string.Equals(Convert.ToHexString(SHA256.HashData(bytes)), expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("E_PAYLOAD_HASH_MISMATCH");
        var payload = JsonSerializer.Deserialize<Payload>(bytes) ?? throw new InvalidOperationException("E_PAYLOAD_INVALID");
        if (payload.schema_version != 1 || payload.locale != "ko" || payload.unity_version != "2021.3.45f2")
            throw new InvalidOperationException("E_PAYLOAD_HEADER_INVALID");
        var keys = new HashSet<(string, long)>();
        foreach (var row in payload.rows)
        {
            var guid = Guid.Parse(row.collection_guid).ToString("N");
            row.id = long.Parse(row.entry_id, CultureInfo.InvariantCulture);
            if (row.id <= 0 || row.text == null || !keys.Add((guid, row.id)))
                throw new InvalidOperationException("E_PAYLOAD_KEY_INVALID");
            if (!Tables.TryGetValue(guid, out var rows)) Tables.Add(guid, rows = new List<Row>());
            rows.Add(row);
        }
        if (keys.Count == 0) throw new InvalidOperationException("E_PAYLOAD_EMPTY");
    }

    private static void ValidateSurface(Type table, Type entry)
    {
        if (table.GetProperty("SharedData", Instance) == null || table.GetProperty("LocaleIdentifier", Instance) == null ||
            table.GetMethod("GetEntry", Instance, null, new[] { typeof(long) }, null) == null ||
            table.GetMethod("AddEntry", Instance, null, new[] { typeof(long), typeof(string) }, null) == null ||
            entry.GetProperty("Table", Instance) == null || entry.GetProperty("Value", Instance)?.CanWrite != true ||
            entry.GetProperty("IsSmart", Instance)?.CanWrite != true)
            throw new InvalidOperationException("E_RUNTIME_API_INCOMPATIBLE");
    }

    private static Type FindType(string name) => AppDomain.CurrentDomain.GetAssemblies()
        .Select(a => a.GetType(name, false)).FirstOrDefault(t => t != null)
        ?? throw new InvalidOperationException("E_RUNTIME_TYPE_MISSING");

    private static object? Get(object? obj, string name) => obj?.GetType().GetProperty(name, Instance)?.GetValue(obj);
    private static void TablePrefix(object __instance) => Apply(__instance);
    private static void EntryPrefix(object __instance) => Apply(Get(__instance, "Table"));

    private static void Apply(object? table)
    {
        if (_busy || table == null || Tables.Count == 0) return;
        try
        {
            _busy = true;
            var locale = Get(Get(table, "LocaleIdentifier"), "Code") as string;
            if (!string.Equals(locale, "ko", StringComparison.OrdinalIgnoreCase)) return;
            var pointer = Get(table, "Pointer");
            if (pointer is not IntPtr identity || identity == IntPtr.Zero) throw new InvalidOperationException("E_TABLE_IDENTITY_UNAVAILABLE");
            var instance = table.GetType().GetMethod("GetInstanceID", Instance, null, Type.EmptyTypes, null);
            if (instance == null) throw new InvalidOperationException("E_TABLE_IDENTITY_UNAVAILABLE");
            var identityKey = (identity, Convert.ToInt32(instance.Invoke(table, null), CultureInfo.InvariantCulture));
            lock (Applied)
            {
                if (Applied.Contains(identityKey)) return;
                var guidText = Get(Get(table, "SharedData"), "TableCollectionNameGuid")?.ToString();
                if (!Guid.TryParse(guidText, out var guid) || !Tables.TryGetValue(guid.ToString("N"), out var rows)) return;
                var get = table.GetType().GetMethod("GetEntry", Instance, null, new[] { typeof(long) }, null)!;
                var add = table.GetType().GetMethod("AddEntry", Instance, null, new[] { typeof(long), typeof(string) }, null)!;
                foreach (var row in rows)
                {
                    if (row.source_orphan) continue; // No valid shared key exists; preserve the underlying orphan.
                    var entry = get.Invoke(table, new object[] { row.id });
                    if (entry == null) entry = add.Invoke(table, new object[] { row.id, row.text });
                    if (entry == null) throw new InvalidOperationException("E_RUNTIME_ENTRY_CREATE_FAILED");
                    entry.GetType().GetProperty("Value", Instance)!.SetValue(entry, row.text);
                    entry.GetType().GetProperty("IsSmart", Instance)!.SetValue(entry, row.is_smart);
                }
                Applied.Add(identityKey);
                _plugin?.Log.LogInfo($"I_TABLE_OVERLAY_APPLIED rows={rows.Count}");
            }
        }
        catch
        {
            if (Interlocked.Increment(ref _failureCount) <= 5) _plugin?.Log.LogWarning("E_TABLE_OVERLAY_FAILED");
        }
        finally { _busy = false; }
    }

    private sealed class Payload
    {
        public int schema_version { get; set; }
        public string locale { get; set; } = "";
        public string unity_version { get; set; } = "";
        public List<Row> rows { get; set; } = new();
    }
    private sealed class Row
    {
        public string collection_guid { get; set; } = "";
        public string entry_id { get; set; } = "";
        public string text { get; set; } = "";
        public bool is_smart { get; set; }
        public bool source_orphan { get; set; }
        [System.Text.Json.Serialization.JsonIgnore] public long id { get; set; }
    }
    private sealed class Binding
    {
        public string relative_path { get; set; } = "";
        public string sha256 { get; set; } = "";
    }
}
