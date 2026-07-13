import "frida-il2cpp-bridge";

declare const console: { log(message: string): void };

interface CharacterMapping {
  characterId: string;
  enabled: boolean;
  transformBundle: string;
  transformSkeletonAsset: string;
}

interface MappingDocument {
  schemaVersion: number;
  packageName: string;
  packageVersionName: string;
  catalogSha256: string;
  catalogPath: string;
  characters: CharacterMapping[];
}

interface PendingAsset {
  mapping: CharacterMapping;
  request: Il2Cpp.Object;
  generation: number;
}

const fallbackRoot =
  "/sdcard/Android/data/jp.co.fanzagames.twinklestarknightsx_a_mod/files/tskskinswap";

const mappings = new Map<string, CharacterMapping>();
const loadedBundles = new Map<string, Il2Cpp.Object>();
const transformAssets = new Map<string, Il2Cpp.Object>();
const transformDataByCharacter = new Map<string, Il2Cpp.Object>();
const pendingAssets = new Map<string, PendingAsset>();
const completionScheduled = new Set<string>();
const cutinAssetClones = new Map<string, Il2Cpp.Object>();
const retainedObjects: Il2Cpp.Object[] = [];
const excludedCharacterIds = new Set(["1141001"]);

let root = fallbackRoot;
let activeManagerHandle = "";
let assetGeneration = 0;

function appendLog(message: string): void {
  const line = `${new Date().toISOString()} ${message}\n`;
  try {
    const output = new File(`${root}/runtime.log`, "a");
    output.write(line);
    output.flush();
    output.close();
  } catch {
    console.log(`[TskSkinSwap] ${message}`);
  }
}

function hashFile(path: string): string {
  const input = new File(path, "rb");
  const checksum = new Checksum("sha256");
  try {
    while (true) {
      const chunk = input.readBytes(1024 * 1024);
      if (chunk.byteLength === 0) {
        break;
      }
      checksum.update(chunk);
    }
    return checksum.getString();
  } finally {
    input.close();
  }
}

function readMappings(packageVersionName: string): void {
  const document = JSON.parse(File.readAllText(`${root}/mappings.json`)) as MappingDocument;
  if (document.schemaVersion !== 2 || !Array.isArray(document.characters)) {
    throw new Error("Unsupported mappings.json schema");
  }
  const expectedPackage = "jp.co.fanzagames.twinklestarknightsx_a_mod";
  const expectedCatalog = `${root.substring(0, root.lastIndexOf("/"))}/com.unity.addressables/catalog_0.0.0.json`;
  if (document.packageName !== expectedPackage) {
    throw new Error("Mapping package does not match the installed game");
  }
  if (document.packageVersionName !== packageVersionName) {
    throw new Error("Game version changed; run Apply-TskSkinSwap-Android.bat again");
  }
  if (document.catalogPath !== expectedCatalog) {
    throw new Error("Mapping catalog path is invalid");
  }
  const currentCatalogHash = hashFile(expectedCatalog);
  if (currentCatalogHash !== document.catalogSha256.toLowerCase()) {
    throw new Error("Game catalog changed; run Apply-TskSkinSwap-Android.bat again");
  }
  appendLog(`Mapping fingerprint verified for version ${packageVersionName}.`);

  for (const mapping of document.characters) {
    if (mapping.enabled && !excludedCharacterIds.has(mapping.characterId)) {
      mappings.set(mapping.characterId, mapping);
    }
  }
  appendLog(`Loaded ${mappings.size} character mapping(s).`);
}

function stringValue(value: unknown): string {
  if (value instanceof Il2Cpp.String) {
    return value.content ?? "";
  }
  return String(value ?? "");
}

function loadBundle(path: string): Il2Cpp.Object {
  const existing = loadedBundles.get(path);
  if (existing !== undefined && !existing.isNull()) {
    return existing;
  }

  const assetBundleClass = Il2Cpp.domain
    .assembly("UnityEngine.AssetBundleModule")
    .image.class("UnityEngine.AssetBundle");
  const bundle = assetBundleClass
    .method("LoadFromFile", 1)
    .invoke(Il2Cpp.string(path)) as Il2Cpp.Object;
  if (bundle.isNull()) {
    throw new Error(`Unable to load bundle: ${path}`);
  }
  loadedBundles.set(path, bundle);
  retainedObjects.push(bundle);
  return bundle;
}

function animationName(animation: Il2Cpp.Object): string {
  return stringValue(animation.method("get_Name").invoke());
}

function ensureAnimationAliases(skeletonData: Il2Cpp.Object, characterId: string): void {
  const animations = skeletonData.method("get_Animations").invoke() as Il2Cpp.Object;
  const items = animations.field("Items").value as Il2Cpp.Array<Il2Cpp.Object>;
  const count = animations.field<number>("Count").value;
  let source: Il2Cpp.Object | null = null;

  for (let index = 0; index < count; index += 1) {
    const animation = items.get(index);
    if (animationName(animation).startsWith("cut_")) {
      source = animation;
      break;
    }
  }
  if (source === null) {
    throw new Error(`No cut animation in transform skeleton for ${characterId}`);
  }

  const animationClass = Il2Cpp.domain.assembly("spine-unity").image.class("Spine.Animation");
  for (const aliasName of ["cut_1", "cut_2", "cut_3"]) {
    const found = skeletonData
      .method("FindAnimation", 1)
      .invoke(Il2Cpp.string(aliasName)) as Il2Cpp.Object;
    if (!found.isNull()) {
      continue;
    }

    const alias = animationClass.alloc();
    const timelines = source.method("get_Timelines").invoke() as Il2Cpp.Object;
    const duration = source.method("get_Duration").invoke() as number;
    alias.method(".ctor", 3).invoke(Il2Cpp.string(aliasName), timelines, duration);
    animations.method("Add", 1).invoke(alias);
    retainedObjects.push(alias);
    appendLog(`Added animation alias ${characterId} ${aliasName}->${animationName(source)}`);
  }
}

function releaseBundle(path: string, unloadAll: boolean): void {
  const bundle = loadedBundles.get(path);
  if (bundle === undefined || bundle.isNull()) {
    return;
  }
  try {
    bundle.method("Unload", 1).invoke(unloadAll);
  } catch (error) {
    appendLog(`Failed to unload bundle ${path}: ${String(error)}`);
  }
  loadedBundles.delete(path);
}

function abandonPending(mapping: CharacterMapping, generation: number): void {
  const pending = pendingAssets.get(mapping.characterId);
  if (pending !== undefined && pending.generation === generation) {
    pendingAssets.delete(mapping.characterId);
    releaseBundle(mapping.transformBundle, true);
  }
}

function activateManager(handle: string): void {
  if (activeManagerHandle === handle) {
    return;
  }
  assetGeneration += 1;
  activeManagerHandle = handle;

  const unityObject = Il2Cpp.domain
    .assembly("UnityEngine.CoreModule")
    .image.class("UnityEngine.Object");
  for (const clone of cutinAssetClones.values()) {
    if (!clone.isNull()) {
      try {
        unityObject.method("Destroy", 1).invoke(clone);
      } catch (error) {
        appendLog(`Failed to destroy stale Cutin clone: ${String(error)}`);
      }
    }
  }
  cutinAssetClones.clear();

  const resources = Il2Cpp.domain
    .assembly("UnityEngine.CoreModule")
    .image.class("UnityEngine.Resources");
  for (const asset of transformAssets.values()) {
    if (!asset.isNull()) {
      try {
        resources.method("UnloadAsset", 1).invoke(asset);
      } catch (error) {
        appendLog(`Failed to unload stale transform asset: ${String(error)}`);
      }
    }
  }
  transformAssets.clear();
  transformDataByCharacter.clear();
  pendingAssets.clear();
  completionScheduled.clear();
  for (const path of Array.from(loadedBundles.keys())) {
    releaseBundle(path, true);
  }
  retainedObjects.length = 0;
  appendLog(`Activated Cutin manager ${handle}; generation=${assetGeneration}.`);
}

function beginTransformLoad(mapping: CharacterMapping): void {
  if (
    transformAssets.has(mapping.characterId) ||
    pendingAssets.has(mapping.characterId)
  ) {
    return;
  }

  const bundle = loadBundle(mapping.transformBundle);
  const objectType = Il2Cpp.domain
    .assembly("UnityEngine.CoreModule")
    .image.class("UnityEngine.Object").type.object;
  let request: Il2Cpp.Object;
  try {
    request = bundle
      .method("LoadAssetAsync", 2)
      .invoke(Il2Cpp.string(mapping.transformSkeletonAsset), objectType) as Il2Cpp.Object;
    if (request.isNull()) {
      throw new Error(`Unable to start transform asset load for ${mapping.characterId}`);
    }
  } catch (error) {
    releaseBundle(mapping.transformBundle, true);
    throw error;
  }
  pendingAssets.set(mapping.characterId, { mapping, request, generation: assetGeneration });
  retainedObjects.push(request);
  appendLog(`Started transform asset load for character ${mapping.characterId}.`);
}

function finalizeTransformLoad(mapping: CharacterMapping, generation: number): boolean {
  if (generation !== assetGeneration) {
    return true;
  }
  const existing = transformAssets.get(mapping.characterId);
  if (existing !== undefined && !existing.isNull()) {
    return true;
  }

  const pending = pendingAssets.get(mapping.characterId);
  if (pending === undefined || pending.generation !== generation) {
    return false;
  }
  const isDone = Boolean(pending.request.method("get_isDone").invoke());
  if (!isDone) {
    return false;
  }
  const transformAsset = pending.request.method("get_asset").invoke() as Il2Cpp.Object;
  if (transformAsset.isNull()) {
    throw new Error(`Transform SkeletonDataAsset not found: ${mapping.transformSkeletonAsset}`);
  }

  const transformData = transformAsset.method("GetSkeletonData", 1).invoke(false) as Il2Cpp.Object;
  if (transformData.isNull()) {
    throw new Error(`Unable to parse transform skeleton for ${mapping.characterId}`);
  }

  ensureAnimationAliases(transformData, mapping.characterId);
  transformAssets.set(mapping.characterId, transformAsset);
  transformDataByCharacter.set(mapping.characterId, transformData);
  retainedObjects.push(transformAsset, transformData);
  pendingAssets.delete(mapping.characterId);
  releaseBundle(mapping.transformBundle, false);
  appendLog(`Released transform bundle container for character ${mapping.characterId}.`);
  appendLog(`Transform asset ready for character ${mapping.characterId}.`);
  return true;
}

function scheduleTransformCompletion(mapping: CharacterMapping, attempt = 0): void {
  const generation = assetGeneration;
  const taskKey = `${generation}:${mapping.characterId}`;
  if (completionScheduled.has(taskKey)) {
    return;
  }
  completionScheduled.add(taskKey);

  const poll = (currentAttempt: number): void => {
    setTimeout(() => {
      if (generation !== assetGeneration) {
        completionScheduled.delete(taskKey);
        return;
      }
      void Il2Cpp.perform(() => finalizeTransformLoad(mapping, generation), "main")
        .then((ready) => {
          if (ready) {
            completionScheduled.delete(taskKey);
          } else if (currentAttempt < 60) {
            poll(currentAttempt + 1);
          } else {
            completionScheduled.delete(taskKey);
            abandonPending(mapping, generation);
            appendLog(`Timed out loading transform asset for ${mapping.characterId}.`);
          }
        })
        .catch((error) => {
          completionScheduled.delete(taskKey);
          abandonPending(mapping, generation);
          appendLog(`Failed to finalize transform asset for ${mapping.characterId}: ${String(error)}`);
        });
    }, 500);
  };

  poll(attempt);
}

Il2Cpp.perform(() => {
  try {
    const application = Il2Cpp.domain
      .assembly("UnityEngine.CoreModule")
      .image.class("UnityEngine.Application");
    const persistentDataPath = application.method("get_persistentDataPath").invoke();
    root = `${stringValue(persistentDataPath)}/tskskinswap`;
    try {
      const currentLog = new File(`${root}/runtime.log`, "w");
      currentLog.close();
    } catch {
      // Logging remains best-effort.
    }
    const packageVersionName = stringValue(application.method("get_version").invoke());
    readMappings(packageVersionName);

    const setNormalCutin = Il2Cpp.domain
      .assembly("Assembly-CSharp")
      .image.class("EffectCutinManager")
      .method("SetNormalCutin", 5);
    const loadCutin = setNormalCutin.class.method("LoadCutin", 1);

    Interceptor.attach(loadCutin.virtualAddress, {
      onEnter(args): void {
        try {
          activateManager(args[0].toString());
          const ids = new Il2Cpp.Array<number>(args[1]);
          for (let index = 0; index < ids.length; index += 1) {
            const mapping = mappings.get(ids.get(index).toString());
            if (mapping !== undefined) {
              beginTransformLoad(mapping);
              scheduleTransformCompletion(mapping);
            }
          }
        } catch (error) {
          appendLog(`Failed to preload battle transform assets: ${String(error)}`);
        }
      },
    });

    Interceptor.attach(setNormalCutin.virtualAddress, {
      onEnter(args): void {
        const characterId = args[1].toInt32().toString();
        const mapping = mappings.get(characterId);
        if (mapping === undefined) {
          return;
        }

        try {
          activateManager(args[0].toString());
          const manager = new Il2Cpp.Object(args[0]);
          const cutinData = manager.field<Il2Cpp.Object>("cutinData").value;
          const transformAsset = transformAssets.get(characterId);
          const transformData = transformDataByCharacter.get(characterId);
          if (
            transformAsset === undefined ||
            transformAsset.isNull() ||
            transformData === undefined ||
            transformData.isNull()
          ) {
            appendLog(`Transform asset not ready for character ${characterId}; using original Cutin.`);
            return;
          }

          const dictionaryKey = Il2Cpp.string(characterId);
          const cloneKey = `${manager.handle}:${characterId}`;
          let cutinClone = cutinAssetClones.get(cloneKey);
          if (cutinClone === undefined || cutinClone.isNull()) {
            const originalCutin = cutinData
              .method("get_Item", 1)
              .invoke(dictionaryKey) as Il2Cpp.Object;
            if (originalCutin.isNull()) {
              throw new Error(`Original Cutin asset not found for ${characterId}`);
            }
            const originalData = originalCutin
              .method("GetSkeletonData", 1)
              .invoke(false) as Il2Cpp.Object;
            if (originalData.isNull()) {
              throw new Error(`Original Cutin SkeletonData not found for ${characterId}`);
            }
            const unityObject = Il2Cpp.domain
              .assembly("UnityEngine.CoreModule")
              .image.class("UnityEngine.Object");
            cutinClone = unityObject
              .method("Instantiate", 1)
              .invoke(originalCutin) as Il2Cpp.Object;
            if (cutinClone.isNull()) {
              throw new Error(`Unable to clone original Cutin asset for ${characterId}`);
            }
            cutinClone.method("InitializeWithData", 1).invoke(transformData);
            cutinAssetClones.set(cloneKey, cutinClone);
            retainedObjects.push(cutinClone);
            appendLog(
              `Prepared Cutin clone for ${characterId}; originalScale=${originalCutin.field<number>("scale").value} transformScale=${transformAsset.field<number>("scale").value} originalSize=${originalData.method("get_Width").invoke()}x${originalData.method("get_Height").invoke()} transformSize=${transformData.method("get_Width").invoke()}x${transformData.method("get_Height").invoke()}.`,
            );
          }
          cutinData
            .method("set_Item", 2)
            .invoke(dictionaryKey, cutinClone);
          appendLog(`Replaced battle Cutin entry for character ${characterId}.`);
        } catch (error) {
          appendLog(`Failed to replace battle Cutin for ${characterId}: ${String(error)}`);
        }
      },
    });

    appendLog("Battle-only Cutin interceptors installed.");
  } catch (error) {
    appendLog(`Initialization failed: ${String(error)}`);
  }
});
