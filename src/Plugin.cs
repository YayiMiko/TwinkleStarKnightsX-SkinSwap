using System.Text.Json;
using System.Text.Json.Serialization;
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
    public const string PluginVersion = "0.5.0";

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
            Harmony.CreateAndPatchAll(typeof(SkeletonDataPatch), PluginGuid);
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

[HarmonyPatch(typeof(SkeletonDataAsset), nameof(SkeletonDataAsset.GetSkeletonData))]
internal static class SkeletonDataPatch
{
    [HarmonyPrefix]
    private static void Prefix(SkeletonDataAsset __instance)
    {
        SkinSwapRuntime.TryApply(__instance);
    }
}

internal static class SkinSwapRuntime
{
    private static readonly Dictionary<string, CharacterMapping> Mappings = new(StringComparer.Ordinal);
    private static readonly HashSet<int> AppliedAssets = new();
    private static readonly Dictionary<string, AssetBundle> LoadedBundles = new(StringComparer.OrdinalIgnoreCase);
    private static readonly List<UnityEngine.Object> RuntimeObjects = new();
    private static readonly List<Spine.Animation> RuntimeAnimations = new();
    private static readonly object Gate = new();

    internal static int MappingCount => Mappings.Count;

    internal static bool LoadConfiguration()
    {
        Mappings.Clear();
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
            if (document?.Characters is null)
            {
                return false;
            }

            foreach (var mapping in document.Characters.Where(item => item.Enabled))
            {
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
        AssetBundle? cutinBundle = null;
        try
        {
            cutinBundle = AssetBundle.LoadFromFile(mapping.CutinBundle);
            if (cutinBundle is null)
            {
                throw new InvalidOperationException($"Unable to load cutin bundle: {mapping.CutinBundle}");
            }

            var skeletonPath = mapping.CutinAtlasAsset.Replace(".atlas.txt", "_SkeletonData.asset", StringComparison.Ordinal);
            var skeletonObject = cutinBundle.LoadAsset(skeletonPath);
            if (skeletonObject is null)
            {
                throw new InvalidOperationException($"Unable to load cutin skeleton: {skeletonPath}");
            }

            var skeletonAsset = new SkeletonDataAsset(skeletonObject.Pointer);
            var skeletonData = skeletonAsset.GetSkeletonData(false);
            if (skeletonData is null)
            {
                throw new InvalidOperationException("Patched skeleton data is null.");
            }

            var animations = skeletonData.Animations;
            var animationNames = new List<string>();
            for (var index = 0; index < animations.Count; index++)
            {
                animationNames.Add(animations.Items[index].Name);
            }
            RuntimeFileLog.Write($"ANIMATIONS character={mapping.CharacterId} names={string.Join(",", animationNames)}");
            RuntimeFileLog.Write($"SELF_TEST_OK character={mapping.CharacterId} asset={skeletonAsset.name}");
            return true;
        }
        catch (Exception exception)
        {
            RuntimeFileLog.Write($"SELF_TEST_FAILED character={mapping.CharacterId}: {exception}");
            return false;
        }
        finally
        {
            cutinBundle?.Unload(false);
        }
    }

    internal static void TryApply(SkeletonDataAsset asset)
    {
        if (asset is null)
        {
            return;
        }

        var assetName = asset.name;
        if (!TryGetCharacterId(assetName, out var characterId)
            || !Mappings.TryGetValue(characterId, out var mapping))
        {
            return;
        }

        var instanceId = asset.GetInstanceID();
        lock (Gate)
        {
            if (AppliedAssets.Contains(instanceId))
            {
                return;
            }

            try
            {
                ApplyMapping(asset, mapping);
                AppliedAssets.Add(instanceId);
                Plugin.PluginLog.LogInfo($"Applied full tf_m0 skeleton to {assetName}.");
                RuntimeFileLog.Write($"Applied full tf_m0 skeleton to {assetName}.");
            }
            catch (Exception exception)
            {
                AppliedAssets.Add(instanceId);
                Plugin.PluginLog.LogError($"Failed to patch {assetName}: {exception}");
                RuntimeFileLog.Write($"Failed to patch {assetName}: {exception}");
            }
        }
    }

    private static bool TryGetCharacterId(string? assetName, out string characterId)
    {
        characterId = string.Empty;
        if (string.IsNullOrEmpty(assetName)
            || !assetName.StartsWith("bc_", StringComparison.Ordinal)
            || !assetName.EndsWith("_SkeletonData", StringComparison.Ordinal))
        {
            return false;
        }

        var start = 3;
        var length = assetName.Length - start - "_SkeletonData".Length;
        if (length <= 0)
        {
            return false;
        }

        characterId = assetName.Substring(start, length);
        return characterId.All(char.IsDigit);
    }

    private static void ApplyMapping(SkeletonDataAsset asset, CharacterMapping mapping)
    {
        var bundle = LoadBundle(mapping.TransformBundle);
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

        EnsureCutAnimationAliases(transformData, mapping.CharacterId);
        asset.InitializeWithData(transformData);
        RuntimeObjects.Add(transformAsset);
    }

    private static void EnsureCutAnimationAliases(Spine.SkeletonData skeletonData, string characterId)
    {
        var animations = skeletonData.Animations;
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
            RuntimeAnimations.Add(alias);
            RuntimeFileLog.Write($"Added animation alias character={characterId} {aliasName}->{source.Name}");
        }
    }

    private static AssetBundle LoadBundle(string path)
    {
        if (LoadedBundles.TryGetValue(path, out var existing) && existing is not null)
        {
            return existing;
        }

        var bundle = AssetBundle.LoadFromFile(path);
        if (bundle is null)
        {
            throw new InvalidOperationException($"Unable to load transform bundle: {path}");
        }

        LoadedBundles[path] = bundle;
        return bundle;
    }

}

internal sealed class MappingDocument
{
    [JsonPropertyName("characters")]
    public List<CharacterMapping>? Characters { get; init; }
}

internal sealed class CharacterMapping
{
    [JsonPropertyName("characterId")]
    public string CharacterId { get; init; } = string.Empty;

    [JsonPropertyName("enabled")]
    public bool Enabled { get; init; }

    [JsonPropertyName("cutinBundle")]
    public string CutinBundle { get; init; } = string.Empty;

    [JsonPropertyName("cutinAtlasAsset")]
    public string CutinAtlasAsset { get; init; } = string.Empty;

    [JsonPropertyName("transformBundle")]
    public string TransformBundle { get; init; } = string.Empty;

    [JsonPropertyName("transformMaterialAsset")]
    public string TransformMaterialAsset { get; init; } = string.Empty;

    [JsonPropertyName("transformSkeletonAsset")]
    public string TransformSkeletonAsset { get; init; } = string.Empty;

    [JsonPropertyName("syntheticAtlasFile")]
    public string SyntheticAtlasFile { get; init; } = string.Empty;
}

internal static class RuntimeFileLog
{
    private static readonly object Gate = new();

    internal static void Write(string message)
    {
        try
        {
            var directory = Path.Combine(Paths.ConfigPath, "TskSkinSwap");
            Directory.CreateDirectory(directory);
            var line = $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}";
            lock (Gate)
            {
                File.AppendAllText(Path.Combine(directory, "runtime.log"), line);
            }
        }
        catch
        {
            // Diagnostics must never prevent the game from starting.
        }
    }
}
