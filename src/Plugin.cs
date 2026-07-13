using System.Text.Json;
using System.Text.Json.Serialization;
using System.Security.Cryptography;
using BepInEx;
using BepInEx.Logging;
using BepInEx.Unity.IL2CPP;
using HarmonyLib;
using Spine.Unity;
using UnityEngine;

namespace TskSkinSwap;

[BepInPlugin(PluginGuid, PluginName, PluginVersion)]
public sealed class Plugin : BasePlugin
{
    public const string PluginGuid = "com.codex.tskskinswap";
    public const string PluginName = "TSK Skin Swap";
    public const string PluginVersion = "1.2.1";

    internal static ManualLogSource PluginLog { get; private set; } = null!;

    public override void Load()
    {
        PluginLog = Log;
        RuntimeFileLog.Write("Plugin load started.");
        if (!SkinSwapRuntime.LoadConfiguration())
        {
            Log.LogWarning("No usable mappings were loaded; the plugin will remain inactive.");
            RuntimeFileLog.Write("No usable mappings were loaded.");
            return;
        }

        try
        {
            Harmony.CreateAndPatchAll(typeof(NormalCutinRequestPatch), PluginGuid);
            Harmony.CreateAndPatchAll(typeof(SkeletonDataPatch), PluginGuid);
            Harmony.CreateAndPatchAll(typeof(AnimationStateDataPatch), PluginGuid);
            Harmony.CreateAndPatchAll(typeof(SkeletonGraphicInitializePatch), PluginGuid);
            Log.LogInfo($"Loaded {SkinSwapRuntime.MappingCount} enabled character mapping(s).");
            RuntimeFileLog.Write($"Harmony installed; mappings={SkinSwapRuntime.MappingCount}.");
            if (Environment.GetEnvironmentVariable("TSK_SKIN_SWAP_SELF_TEST") == "1")
            {
                SkinSwapRuntime.RunSelfTest();
            }
        }
        catch (Exception exception)
        {
            RuntimeFileLog.Write($"Plugin initialization failed: {exception}");
            throw;
        }
    }
}

[HarmonyPatch(
    typeof(EffectCutinManager),
    nameof(EffectCutinManager.SetNormalCutin),
    new[] { typeof(int), typeof(Transform), typeof(bool), typeof(bool), typeof(bool) })]
internal static class NormalCutinRequestPatch
{
    [HarmonyPrefix]
    private static void Prefix(EffectCutinManager __instance, int id)
    {
        SkinSwapRuntime.RegisterNormalCutin(__instance, id);
    }
}

[HarmonyPatch(typeof(SkeletonDataAsset), nameof(SkeletonDataAsset.GetSkeletonData), new[] { typeof(bool) })]
internal static class SkeletonDataPatch
{
    [HarmonyPrefix]
    private static bool Prefix(SkeletonDataAsset __instance, ref Spine.SkeletonData __result)
    {
        return !SkinSwapRuntime.TryGetSkeletonData(__instance, out __result);
    }
}

[HarmonyPatch(typeof(SkeletonDataAsset), nameof(SkeletonDataAsset.GetAnimationStateData))]
internal static class AnimationStateDataPatch
{
    [HarmonyPrefix]
    private static bool Prefix(SkeletonDataAsset __instance, ref Spine.AnimationStateData __result)
    {
        return !SkinSwapRuntime.TryGetAnimationStateData(__instance, out __result);
    }
}

[HarmonyPatch(typeof(SkeletonGraphic), nameof(SkeletonGraphic.Initialize), new[] { typeof(bool) })]
internal static class SkeletonGraphicInitializePatch
{
    [HarmonyPostfix]
    private static void Postfix(SkeletonGraphic __instance)
    {
        SkinSwapRuntime.CompleteNormalCutin(__instance.skeletonDataAsset);
    }

    [HarmonyFinalizer]
    private static Exception? Finalizer(Exception? __exception, SkeletonGraphic __instance)
    {
        if (__exception is not null)
        {
            SkinSwapRuntime.CompleteNormalCutin(__instance.skeletonDataAsset);
        }
        return __exception;
    }
}

internal static class SkinSwapRuntime
{
    private static readonly HashSet<string> ExcludedCharacterIds = new(StringComparer.Ordinal) { "1141001" };
    private static readonly HashSet<string> FailedCharacters = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, int> FailureCounts = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, CharacterMapping> Mappings = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, PreparedTransform> PreparedTransforms = new(StringComparer.Ordinal);
    private static readonly Dictionary<int, Queue<OverrideRequest>> ActiveOverrides = new();
    private static readonly object Gate = new();

    internal static int MappingCount => Mappings.Count;

    internal static bool LoadConfiguration()
    {
        Mappings.Clear();
        FailedCharacters.Clear();
        FailureCounts.Clear();
        var path = Path.Combine(Paths.ConfigPath, "TskSkinSwap", "mappings.json");
        if (!File.Exists(path))
        {
            Plugin.PluginLog.LogWarning($"Mapping file does not exist: {path}");
            return false;
        }

        try
        {
            var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
            var document = JsonSerializer.Deserialize<MappingDocument>(File.ReadAllText(path), options);
            if (document?.Characters is null || !ValidateMappingFingerprint(document))
            {
                return false;
            }

            foreach (var mapping in document.Characters.Where(item => item.Enabled))
            {
                if (ExcludedCharacterIds.Contains(mapping.CharacterId))
                {
                    RuntimeFileLog.Write($"MAPPING_EXCLUDED character={mapping.CharacterId} reason=knownRenderingIssue");
                    continue;
                }

                if (string.IsNullOrWhiteSpace(mapping.CharacterId)
                    || string.IsNullOrWhiteSpace(mapping.TransformBundle)
                    || string.IsNullOrWhiteSpace(mapping.TransformSkeletonAsset))
                {
                    Plugin.PluginLog.LogWarning("Skipped an incomplete character mapping.");
                    continue;
                }

                if (!File.Exists(mapping.TransformBundle))
                {
                    Plugin.PluginLog.LogWarning($"Skipped {mapping.CharacterId}: transform bundle is missing.");
                    continue;
                }
                if (mapping.TransformBundleSize > 0
                    && new FileInfo(mapping.TransformBundle).Length != mapping.TransformBundleSize)
                {
                    Plugin.PluginLog.LogWarning($"Skipped {mapping.CharacterId}: transform bundle size does not match the mapping.");
                    continue;
                }

                Mappings[mapping.CharacterId] = mapping;
            }

            return Mappings.Count > 0;
        }
        catch (Exception exception)
        {
            Plugin.PluginLog.LogError($"Unable to read mappings: {exception}");
            return false;
        }
    }

    private static bool ValidateMappingFingerprint(MappingDocument document)
    {
        if (document.SchemaVersion != 2)
        {
            Plugin.PluginLog.LogWarning(
                $"Unsupported mapping schema {document.SchemaVersion}; run Apply-TskSkinSwap.bat again."
            );
            RuntimeFileLog.Write($"MAPPING_REJECTED reason=schema actual={document.SchemaVersion} expected=2");
            return false;
        }

        try
        {
            var gameAssembly = Path.Combine(Paths.GameRootPath, "GameAssembly.dll");
            var globalMetadata = Path.Combine(
                Paths.GameRootPath,
                "twinkle_starknightsX_Data",
                "il2cpp_data",
                "Metadata",
                "global-metadata.dat"
            );
            var catalog = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "AppData",
                "LocalLow",
                "FANZAGAMES",
                "twinkle_starknightsX",
                "com.unity.addressables",
                "catalog_0.0.0.json"
            );
            var checks = new[]
            {
                (Name: "GameAssembly", Path: gameAssembly, Expected: document.GameAssemblySha256),
                (Name: "GlobalMetadata", Path: globalMetadata, Expected: document.GlobalMetadataSha256),
                (Name: "Catalog", Path: catalog, Expected: document.CatalogSha256),
            };
            foreach (var check in checks)
            {
                if (string.IsNullOrWhiteSpace(check.Expected) || !File.Exists(check.Path))
                {
                    Plugin.PluginLog.LogWarning(
                        $"Mapping fingerprint input is missing for {check.Name}; run Apply-TskSkinSwap.bat again."
                    );
                    RuntimeFileLog.Write($"MAPPING_REJECTED reason=missingFingerprintInput name={check.Name}");
                    return false;
                }

                var actual = HashFile(check.Path);
                if (!string.Equals(actual, check.Expected, StringComparison.OrdinalIgnoreCase))
                {
                    Plugin.PluginLog.LogWarning(
                        $"The game or catalog changed ({check.Name}); TskSkinSwap is disabled until Apply-TskSkinSwap.bat is run again."
                    );
                    RuntimeFileLog.Write($"MAPPING_REJECTED reason=fingerprintMismatch name={check.Name}");
                    return false;
                }
            }
            return true;
        }
        catch (Exception exception)
        {
            Plugin.PluginLog.LogError($"Unable to validate the mapping fingerprint: {exception}");
            RuntimeFileLog.Write($"MAPPING_REJECTED reason=fingerprintError error={exception.GetType().Name}");
            return false;
        }
    }

    private static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha256 = SHA256.Create();
        return Convert.ToHexString(sha256.ComputeHash(stream));
    }

    internal static void RunSelfTest()
    {
        var passed = 0;
        var failed = 0;
        foreach (var mapping in Mappings.Values.OrderBy(item => item.CharacterId, StringComparer.Ordinal))
        {
            if (RunSelfTest(mapping))
            {
                passed++;
            }
            else
            {
                failed++;
            }
        }

        RuntimeFileLog.Write($"SELF_TEST_SUMMARY passed={passed} failed={failed}");
    }

    private static bool RunSelfTest(CharacterMapping mapping)
    {
        try
        {
            var prepared = PrepareTransform(mapping);
            var animations = prepared.Data.Animations;
            var animationNames = new List<string>();
            for (var index = 0; index < animations.Count; index++)
            {
                animationNames.Add(animations.Items[index].Name);
            }
            RuntimeFileLog.Write($"ANIMATIONS character={mapping.CharacterId} names={string.Join(",", animationNames)}");
            if (prepared.StateData is null)
            {
                throw new InvalidOperationException("Transform AnimationStateData is null.");
            }

            if (prepared.Asset.atlasAssets is null || prepared.Asset.atlasAssets.Length == 0)
            {
                throw new InvalidOperationException("Transform atlas assets are missing.");
            }

            RuntimeFileLog.Write($"SELF_TEST_OK character={mapping.CharacterId} asset={prepared.Asset.name}");
            return true;
        }
        catch (Exception exception)
        {
            RuntimeFileLog.Write($"SELF_TEST_FAILED character={mapping.CharacterId}: {exception}");
            return false;
        }
    }

    internal static void RegisterNormalCutin(EffectCutinManager manager, int id)
    {
        if (manager is null)
        {
            return;
        }

        var characterId = id.ToString();
        if (!Mappings.TryGetValue(characterId, out var mapping))
        {
            return;
        }

        lock (Gate)
        {
            if (FailedCharacters.Contains(characterId))
            {
                return;
            }
            try
            {
                RemoveExpiredOverrides();
                if (manager.cutinData is null || !manager.cutinData.ContainsKey(characterId))
                {
                    throw new InvalidOperationException($"Normal Cutin asset is not loaded for character {characterId}.");
                }

                var sourceAsset = manager.cutinData[characterId];
                var sourceAssetInstanceId = sourceAsset.GetInstanceID();
                var prepared = PrepareTransform(mapping, sourceAssetInstanceId);
                var request = new OverrideRequest(sourceAsset, prepared, DateTimeOffset.UtcNow.AddSeconds(30));
                var instanceId = sourceAssetInstanceId;
                if (!ActiveOverrides.TryGetValue(instanceId, out var requests))
                {
                    requests = new Queue<OverrideRequest>();
                    ActiveOverrides[instanceId] = requests;
                }

                requests.Enqueue(request);
                FailureCounts.Remove(characterId);
                RuntimeFileLog.Write(
                    $"OVERRIDE_REGISTERED character={characterId} asset={sourceAsset.name} "
                    + $"instance={sourceAsset.GetInstanceID()} queue={requests.Count}"
                );
            }
            catch (Exception exception)
            {
                var failureCount = FailureCounts.GetValueOrDefault(characterId) + 1;
                FailureCounts[characterId] = failureCount;
                var disabled = failureCount >= 3;
                if (disabled)
                {
                    FailedCharacters.Add(characterId);
                }
                Plugin.PluginLog.LogError($"Failed to register Cutin override for character {characterId}: {exception}");
                RuntimeFileLog.Write(
                    $"OVERRIDE_REGISTER_FAILED character={characterId} failures={failureCount} "
                    + $"disabledForSession={disabled}: {exception}"
                );
            }
        }
    }

    internal static bool TryGetSkeletonData(SkeletonDataAsset asset, out Spine.SkeletonData result)
    {
        result = null!;
        if (asset is null)
        {
            return false;
        }

        lock (Gate)
        {
            RemoveExpiredOverrides();
            if (!TryGetActiveRequest(asset.GetInstanceID(), out var request))
            {
                return false;
            }

            request.ApplyTemporaryFields(asset);
            request.SkeletonDataServed = true;
            result = request.Prepared.Data;
            RuntimeFileLog.Write($"OVERRIDE_SKELETON character={request.CharacterId} asset={asset.name}");
            return true;
        }
    }

    internal static bool TryGetAnimationStateData(SkeletonDataAsset asset, out Spine.AnimationStateData result)
    {
        result = null!;
        if (asset is null)
        {
            return false;
        }

        lock (Gate)
        {
            RemoveExpiredOverrides();
            if (!TryGetActiveRequest(asset.GetInstanceID(), out var request))
            {
                return false;
            }

            request.AnimationStateServed = true;
            result = request.Prepared.StateData;
            RuntimeFileLog.Write($"OVERRIDE_STATE character={request.CharacterId} asset={asset.name}");
            return true;
        }
    }

    internal static void CompleteNormalCutin(SkeletonDataAsset asset)
    {
        if (asset is null)
        {
            return;
        }

        lock (Gate)
        {
            RemoveExpiredOverrides();
            var instanceId = asset.GetInstanceID();
            if (!ActiveOverrides.TryGetValue(instanceId, out var requests) || requests.Count == 0)
            {
                return;
            }

            var request = requests.Dequeue();
            request.RestoreTemporaryFields(asset);
            if (requests.Count == 0)
            {
                ActiveOverrides.Remove(instanceId);
            }
            RuntimeFileLog.Write($"OVERRIDE_COMPLETED character={request.CharacterId} skeleton={request.SkeletonDataServed} state={request.AnimationStateServed}");
        }
    }

    private static bool TryGetActiveRequest(int instanceId, out OverrideRequest request)
    {
        request = null!;
        if (!ActiveOverrides.TryGetValue(instanceId, out var requests) || requests.Count == 0)
        {
            return false;
        }
        request = requests.Peek();
        return true;
    }

    private static List<Spine.Animation> EnsureCutAnimationAliases(Spine.SkeletonData skeletonData, string characterId)
    {
        var animations = skeletonData.Animations;
        var aliases = new List<Spine.Animation>();
        Spine.Animation? source = null;
        for (var index = 0; index < animations.Count; index++)
        {
            var animation = animations.Items[index];
            if (animation.Name.StartsWith("cut_", StringComparison.Ordinal))
            {
                source = animation;
                break;
            }
        }

        if (source is null)
        {
            throw new InvalidOperationException($"No cut animation exists in tf_m0 for character {characterId}.");
        }

        foreach (var aliasName in new[] { "cut_1", "cut_2", "cut_3" })
        {
            if (skeletonData.FindAnimation(aliasName) is not null)
            {
                continue;
            }

            var alias = new Spine.Animation(aliasName, source.Timelines, source.Duration);
            animations.Add(alias);
            aliases.Add(alias);
            RuntimeFileLog.Write($"Added animation alias character={characterId} {aliasName}->{source.Name}");
        }
        return aliases;
    }

    private static PreparedTransform PrepareTransform(CharacterMapping mapping, int sourceAssetInstanceId = 0)
    {
        if (PreparedTransforms.TryGetValue(mapping.CharacterId, out var existing))
        {
            if (sourceAssetInstanceId == 0 || existing.SourceAssetInstanceId == sourceAssetInstanceId)
            {
                return existing;
            }

            PreparedTransforms.Remove(mapping.CharacterId);
            RuntimeFileLog.Write(
                $"TRANSFORM_INVALIDATED character={mapping.CharacterId} "
                + $"oldSourceInstance={existing.SourceAssetInstanceId} newSourceInstance={sourceAssetInstanceId}"
            );
        }

        var (bundle, owned) = OpenTransformBundle(mapping);
        try
        {
            var skeletonObject = bundle.LoadAsset(mapping.TransformSkeletonAsset);
            if (skeletonObject is null)
            {
                throw new InvalidOperationException($"Transform skeleton was not found: {mapping.TransformSkeletonAsset}");
            }

            var transformAsset = new SkeletonDataAsset(skeletonObject.Pointer);
            var transformData = transformAsset.GetSkeletonData(false);
            if (transformData is null)
            {
                throw new InvalidOperationException($"Transform SkeletonData could not be parsed: {mapping.TransformSkeletonAsset}");
            }

            var aliases = EnsureCutAnimationAliases(transformData, mapping.CharacterId);
            var stateData = transformAsset.GetAnimationStateData();
            if (stateData is null)
            {
                throw new InvalidOperationException($"Transform AnimationStateData could not be created: {mapping.TransformSkeletonAsset}");
            }

            var prepared = new PreparedTransform(
                mapping.CharacterId,
                sourceAssetInstanceId,
                transformAsset,
                transformData,
                stateData,
                aliases
            );
            if (owned)
            {
                PreparedTransforms[mapping.CharacterId] = prepared;
            }
            RuntimeFileLog.Write(
                $"TRANSFORM_PREPARED character={mapping.CharacterId} source={(owned ? "mod" : "game")} "
                + $"sourceInstance={sourceAssetInstanceId} transformInstance={transformAsset.GetInstanceID()}"
            );
            return prepared;
        }
        finally
        {
            if (owned)
            {
                bundle.Unload(false);
                RuntimeFileLog.Write($"TRANSFORM_BUNDLE_RELEASED character={mapping.CharacterId}");
            }
        }
    }

    private static (AssetBundle Bundle, bool Owned) OpenTransformBundle(CharacterMapping mapping)
    {
        var loaded = FindLoadedBundle(mapping.TransformSkeletonAsset);
        if (loaded is not null)
        {
            return (loaded, false);
        }

        var bundle = AssetBundle.LoadFromFile(mapping.TransformBundle);
        if (bundle is not null)
        {
            return (bundle, true);
        }

        loaded = FindLoadedBundle(mapping.TransformSkeletonAsset);
        if (loaded is not null)
        {
            return (loaded, false);
        }

        throw new InvalidOperationException($"Unable to open transform bundle: {mapping.TransformBundle}");
    }

    private static AssetBundle? FindLoadedBundle(string assetPath)
    {
        var bundles = AssetBundle.GetAllLoadedAssetBundles_Native();
        for (var index = 0; index < bundles.Length; index++)
        {
            var bundle = bundles[index];
            if (bundle is null)
            {
                continue;
            }

            try
            {
                if (bundle.Contains(assetPath))
                {
                    return bundle;
                }
            }
            catch
            {
                // A bundle can disappear while Unity is changing scenes.
            }
        }

        return null;
    }

    private static void RemoveExpiredOverrides()
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var instanceId in ActiveOverrides.Keys.ToArray())
        {
            var requests = ActiveOverrides[instanceId];
            while (requests.Count > 0 && requests.Peek().ExpiresAt <= now)
            {
                var request = requests.Dequeue();
                request.RestoreTemporaryFields(request.SourceAsset);
                RuntimeFileLog.Write($"OVERRIDE_EXPIRED character={request.CharacterId} skeleton={request.SkeletonDataServed} state={request.AnimationStateServed}");
            }
            if (requests.Count == 0)
            {
                ActiveOverrides.Remove(instanceId);
            }
        }
    }

    private sealed record PreparedTransform(
        string CharacterId,
        int SourceAssetInstanceId,
        SkeletonDataAsset Asset,
        Spine.SkeletonData Data,
        Spine.AnimationStateData StateData,
        List<Spine.Animation> Aliases);

    private sealed class OverrideRequest
    {
        internal OverrideRequest(SkeletonDataAsset sourceAsset, PreparedTransform prepared, DateTimeOffset expiresAt)
        {
            SourceAsset = sourceAsset;
            Prepared = prepared;
            ExpiresAt = expiresAt;
        }

        internal string CharacterId => Prepared.CharacterId;
        internal SkeletonDataAsset SourceAsset { get; }
        internal PreparedTransform Prepared { get; }
        internal DateTimeOffset ExpiresAt { get; }
        internal bool SkeletonDataServed { get; set; }
        internal bool AnimationStateServed { get; set; }

        private Spine.SkeletonData? OriginalSkeletonData { get; set; }
        private Spine.AnimationStateData? OriginalStateData { get; set; }
        private bool TemporaryFieldsApplied { get; set; }

        internal void ApplyTemporaryFields(SkeletonDataAsset asset)
        {
            if (TemporaryFieldsApplied)
            {
                return;
            }

            OriginalSkeletonData = asset.skeletonData;
            OriginalStateData = asset.stateData;
            asset.skeletonData = Prepared.Data;
            asset.stateData = Prepared.StateData;
            TemporaryFieldsApplied = true;
        }

        internal void RestoreTemporaryFields(SkeletonDataAsset asset)
        {
            if (!TemporaryFieldsApplied)
            {
                return;
            }

            asset.skeletonData = OriginalSkeletonData;
            asset.stateData = OriginalStateData;
            TemporaryFieldsApplied = false;
        }
    }
}

internal sealed class MappingDocument
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; init; }

    [JsonPropertyName("gameAssemblySha256")]
    public string GameAssemblySha256 { get; init; } = string.Empty;

    [JsonPropertyName("globalMetadataSha256")]
    public string GlobalMetadataSha256 { get; init; } = string.Empty;

    [JsonPropertyName("catalogSha256")]
    public string CatalogSha256 { get; init; } = string.Empty;

    [JsonPropertyName("characters")]
    public List<CharacterMapping>? Characters { get; init; }
}

internal sealed class CharacterMapping
{
    [JsonPropertyName("characterId")]
    public string CharacterId { get; init; } = string.Empty;

    [JsonPropertyName("enabled")]
    public bool Enabled { get; init; }

    [JsonPropertyName("transformBundle")]
    public string TransformBundle { get; init; } = string.Empty;

    [JsonPropertyName("transformSkeletonAsset")]
    public string TransformSkeletonAsset { get; init; } = string.Empty;

    [JsonPropertyName("transformBundleSize")]
    public long TransformBundleSize { get; init; }

    [JsonPropertyName("transformBundleCatalogHash")]
    public string TransformBundleCatalogHash { get; init; } = string.Empty;
}

internal static class RuntimeFileLog
{
    private static readonly object Gate = new();
    private const long MaxLogBytes = 2 * 1024 * 1024;

    internal static void Write(string message)
    {
        try
        {
            var directory = Path.Combine(Paths.ConfigPath, "TskSkinSwap");
            Directory.CreateDirectory(directory);
            var line = $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}";
            lock (Gate)
            {
                var path = Path.Combine(directory, "runtime.log");
                if (File.Exists(path) && new FileInfo(path).Length >= MaxLogBytes)
                {
                    var previous = Path.Combine(directory, "runtime.previous.log");
                    File.Delete(previous);
                    File.Move(path, previous);
                }
                File.AppendAllText(path, line);
            }
        }
        catch
        {
            // Diagnostics must never prevent the game from starting.
        }
    }
}
