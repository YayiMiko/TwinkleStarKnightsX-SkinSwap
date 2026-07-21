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
  generation: number;
}

interface OverrideRequest {
  characterId: string;
  sourceAsset: Il2Cpp.Object;
  transformData: Il2Cpp.Object;
  transformStateData: Il2Cpp.Object;
  expiresAt: number;
  originalSkeletonData?: Il2Cpp.Object;
  originalStateData?: Il2Cpp.Object;
  temporaryFieldsApplied: boolean;
  skeletonDataServed: boolean;
  stateDataServed: boolean;
}

const fallbackRoot =
  "/sdcard/Android/data/jp.co.fanzagames.twinklestarknightsx_a_mod/files/tskskinswap";

const mappings = new Map<string, CharacterMapping>();
const transformAssets = new Map<string, Il2Cpp.Object>();
const transformDataByCharacter = new Map<string, Il2Cpp.Object>();
const transformStateByCharacter = new Map<string, Il2Cpp.Object>();
const pendingAssets = new Map<string, PendingAsset>();
const completionScheduled = new Set<string>();
const activeOverrides = new Map<string, OverrideRequest[]>();
const skeletonOverrideContexts = new WeakMap<object, OverrideRequest>();
const stateOverrideContexts = new WeakMap<object, OverrideRequest>();
const completionContexts = new WeakMap<object, Il2Cpp.Object>();
const retainedObjects: Il2Cpp.Object[] = [];
const excludedCharacterIds = new Set(["1141001"]);

let root = fallbackRoot;
let activeManagerHandle = "";
let assetGeneration = 0;
let skeletonAddressables: Il2Cpp.Class | null = null;
let cancellationTokenNone: Il2Cpp.ValueType | null = null;

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

function getSkeletonAddressables(): Il2Cpp.Class {
  if (skeletonAddressables === null) {
    throw new Error("Skeleton Addressables wrapper is not initialized");
  }
  return skeletonAddressables;
}

function getCancellationTokenNone(): Il2Cpp.ValueType {
  if (cancellationTokenNone === null) {
    throw new Error("Cancellation token is not initialized");
  }
  return cancellationTokenNone;
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
  for (const aliasName of ["cut_2"]) {
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

function releaseAddressable(path: string): void {
  try {
    getSkeletonAddressables()
      .method("ReleaseCache", 1)
      .overload("System.String")
      .invoke(Il2Cpp.string(path));
  } catch (error) {
    appendLog(`Failed to release Addressable ${path}: ${String(error)}`);
  }
}

function abandonPending(mapping: CharacterMapping, generation: number): void {
  const pending = pendingAssets.get(mapping.characterId);
  if (pending !== undefined && pending.generation === generation) {
    pendingAssets.delete(mapping.characterId);
    releaseAddressable(mapping.transformSkeletonAsset);
  }
}

function activateManager(handle: string): void {
  if (activeManagerHandle === handle) {
    return;
  }
  activeManagerHandle = handle;
  appendLog(`Activated Cutin manager ${handle}; generation=${assetGeneration}.`);
}

function restoreTemporaryFields(request: OverrideRequest): void {
  if (!request.temporaryFieldsApplied || request.sourceAsset.isNull()) {
    return;
  }
  if (request.originalSkeletonData !== undefined) {
    request.sourceAsset.field<Il2Cpp.Object>("skeletonData").value = request.originalSkeletonData;
  }
  if (request.originalStateData !== undefined) {
    request.sourceAsset.field<Il2Cpp.Object>("stateData").value = request.originalStateData;
  }
  request.temporaryFieldsApplied = false;
}

function removeExpiredOverrides(): void {
  const now = Date.now();
  for (const [assetHandle, requests] of activeOverrides) {
    while (requests.length > 0 && requests[0].expiresAt <= now) {
      const expired = requests.shift()!;
      try {
        restoreTemporaryFields(expired);
      } catch (error) {
        appendLog(`Failed to restore expired override for ${expired.characterId}: ${String(error)}`);
      }
      appendLog(`Expired Cutin override for character ${expired.characterId}.`);
    }
    if (requests.length === 0) {
      activeOverrides.delete(assetHandle);
    }
  }
}

function getActiveOverride(asset: Il2Cpp.Object): OverrideRequest | undefined {
  removeExpiredOverrides();
  const requests = activeOverrides.get(asset.handle.toString());
  return requests !== undefined && requests.length > 0 ? requests[0] : undefined;
}

function applyTemporaryFields(request: OverrideRequest): void {
  if (request.temporaryFieldsApplied) {
    return;
  }
  request.originalSkeletonData = request.sourceAsset.field<Il2Cpp.Object>("skeletonData").value;
  request.originalStateData = request.sourceAsset.field<Il2Cpp.Object>("stateData").value;
  request.sourceAsset.field<Il2Cpp.Object>("skeletonData").value = request.transformData;
  request.sourceAsset.field<Il2Cpp.Object>("stateData").value = request.transformStateData;
  request.temporaryFieldsApplied = true;
}

function releasePreparedTransforms(reason: string): void {
  removeExpiredOverrides();
  for (const requests of activeOverrides.values()) {
    for (const request of requests) {
      try {
        restoreTemporaryFields(request);
      } catch (error) {
        appendLog(`Failed to restore Cutin override during ${reason}: ${String(error)}`);
      }
    }
  }
  activeOverrides.clear();

  let released = 0;
  for (const characterId of transformAssets.keys()) {
    const mapping = mappings.get(characterId);
    if (mapping !== undefined) {
      releaseAddressable(mapping.transformSkeletonAsset);
      released += 1;
    }
  }
  transformAssets.clear();
  transformDataByCharacter.clear();
  transformStateByCharacter.clear();
  retainedObjects.length = 0;
  appendLog(`Released ${released} prepared transform asset(s) during ${reason}.`);
}

function completeOverride(asset: Il2Cpp.Object): void {
  removeExpiredOverrides();
  const assetHandle = asset.handle.toString();
  const requests = activeOverrides.get(assetHandle);
  if (requests === undefined || requests.length === 0) {
    return;
  }
  const request = requests.shift()!;
  restoreTemporaryFields(request);
  if (requests.length === 0) {
    activeOverrides.delete(assetHandle);
  }
  appendLog(
    `Completed Cutin override for character ${request.characterId}; skeleton=${request.skeletonDataServed} state=${request.stateDataServed}.`,
  );
}

function beginTransformLoad(mapping: CharacterMapping): void {
  if (
    transformAssets.has(mapping.characterId) ||
    pendingAssets.has(mapping.characterId)
  ) {
    return;
  }

  getSkeletonAddressables()
    .method("Load", 2)
    .invoke(Il2Cpp.string(mapping.transformSkeletonAsset), getCancellationTokenNone());
  pendingAssets.set(mapping.characterId, { mapping, generation: assetGeneration });
  appendLog(`Requested transform Addressable for character ${mapping.characterId}.`);
}

function findAddressableAsset(path: string): Il2Cpp.Object | null {
  const cache = getSkeletonAddressables().method("GetCache", 0).invoke() as Il2Cpp.Object;
  const count = cache.method("get_Count").invoke() as number;
  for (let index = 0; index < count; index += 1) {
    const entry = cache.method("get_Item", 1).invoke(index) as Il2Cpp.Object;
    if (entry.isNull()) {
      continue;
    }
    const entryPath = stringValue(entry.method("get_Path").invoke());
    if (entryPath !== path) {
      continue;
    }
    const asset = entry.method("get_Value").invoke() as Il2Cpp.Object;
    return asset.isNull() ? null : asset;
  }
  return null;
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
  const transformAsset = findAddressableAsset(mapping.transformSkeletonAsset);
  if (transformAsset === null) {
    return false;
  }

  const transformData = transformAsset.method("GetSkeletonData", 1).invoke(false) as Il2Cpp.Object;
  if (transformData.isNull()) {
    throw new Error(`Unable to parse transform skeleton for ${mapping.characterId}`);
  }

  ensureAnimationAliases(transformData, mapping.characterId);
  const transformStateData = transformAsset.method("GetAnimationStateData").invoke() as Il2Cpp.Object;
  if (transformStateData.isNull()) {
    throw new Error(`Unable to prepare transform animation state for ${mapping.characterId}`);
  }
  transformAssets.set(mapping.characterId, transformAsset);
  transformDataByCharacter.set(mapping.characterId, transformData);
  transformStateByCharacter.set(mapping.characterId, transformStateData);
  retainedObjects.push(transformAsset, transformData, transformStateData);
  pendingAssets.delete(mapping.characterId);
  appendLog(`Transform Addressable ready for character ${mapping.characterId}.`);
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
    const spineUnity = Il2Cpp.domain.assembly("spine-unity").image;
    const skeletonDataAsset = spineUnity.class("Spine.Unity.SkeletonDataAsset");
    const skeletonGraphic = spineUnity.class("Spine.Unity.SkeletonGraphic");
    skeletonAddressables = Il2Cpp.domain
      .assembly("Assembly-CSharp")
      .image.class("AddressableWrapper`1")
      .inflate(skeletonDataAsset);
    cancellationTokenNone = Il2Cpp.corlib
      .class("System.Threading.CancellationToken")
      .alloc()
      .unbox();
    const pictureBookView = Il2Cpp.domain
      .assembly("Assembly-CSharp")
      .image.class("PictureBookUnitProfileRootView");
    const pictureBookTransformAnimation = pictureBookView
      .method("CharaAnimPlay")
      .overload("TKS.Network.Domain.PictureBookUnitEntity");
    const pictureBookCharacterUnload = pictureBookView.method("CharaUnload", 0);

    Interceptor.attach(pictureBookTransformAnimation.virtualAddress, {
      onEnter(): void {
        try {
          releasePreparedTransforms("picture-book transform playback");
        } catch (error) {
          appendLog(`Failed to prepare native transform playback: ${String(error)}`);
        }
      },
    });

    Interceptor.attach(pictureBookCharacterUnload.virtualAddress, {
      onLeave(_retval): void {
        try {
          releasePreparedTransforms("picture-book character unload");
        } catch (error) {
          appendLog(`Failed to clean up unloaded picture-book character: ${String(error)}`);
        }
      },
    });

    Interceptor.attach(skeletonDataAsset.method("GetSkeletonData", 1).virtualAddress, {
      onEnter(args): void {
        try {
          const asset = new Il2Cpp.Object(args[0]);
          const request = getActiveOverride(asset);
          if (request === undefined) {
            return;
          }
          applyTemporaryFields(request);
          request.skeletonDataServed = true;
          skeletonOverrideContexts.set(this, request);
        } catch (error) {
          appendLog(`Failed to serve temporary Cutin skeleton: ${String(error)}`);
        }
      },
      onLeave(retval): void {
        const request = skeletonOverrideContexts.get(this);
        if (request !== undefined) {
          retval.replace(request.transformData.handle);
          skeletonOverrideContexts.delete(this);
        }
      },
    });

    Interceptor.attach(skeletonDataAsset.method("GetAnimationStateData").virtualAddress, {
      onEnter(args): void {
        try {
          const asset = new Il2Cpp.Object(args[0]);
          const request = getActiveOverride(asset);
          if (request === undefined) {
            return;
          }
          applyTemporaryFields(request);
          request.stateDataServed = true;
          stateOverrideContexts.set(this, request);
        } catch (error) {
          appendLog(`Failed to serve temporary Cutin animation state: ${String(error)}`);
        }
      },
      onLeave(retval): void {
        const request = stateOverrideContexts.get(this);
        if (request !== undefined) {
          retval.replace(request.transformStateData.handle);
          stateOverrideContexts.delete(this);
        }
      },
    });

    Interceptor.attach(skeletonGraphic.method("Initialize", 1).virtualAddress, {
      onEnter(args): void {
        try {
          const graphic = new Il2Cpp.Object(args[0]);
          const asset = graphic.field<Il2Cpp.Object>("skeletonDataAsset").value;
          if (!asset.isNull() && getActiveOverride(asset) !== undefined) {
            completionContexts.set(this, asset);
          }
        } catch (error) {
          appendLog(`Failed to observe Cutin completion: ${String(error)}`);
        }
      },
      onLeave(_retval): void {
        const sourceAsset = completionContexts.get(this);
        if (sourceAsset !== undefined) {
          try {
            completeOverride(sourceAsset);
          } catch (error) {
            appendLog(`Failed to complete Cutin override: ${String(error)}`);
          }
          completionContexts.delete(this);
        }
      },
    });

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
        // Frida includes `this` at args[0]; args[3] is the `ex` flag selecting cut_2.
        const isNormalAttack2 = args[3].toInt32() !== 0;
        if (mapping === undefined || !isNormalAttack2) {
          return;
        }

        try {
          activateManager(args[0].toString());
          const manager = new Il2Cpp.Object(args[0]);
          const cutinData = manager.field<Il2Cpp.Object>("cutinData").value;
          const transformAsset = transformAssets.get(characterId);
          const transformData = transformDataByCharacter.get(characterId);
          const transformStateData = transformStateByCharacter.get(characterId);
          if (
            transformAsset === undefined ||
            transformAsset.isNull() ||
            transformData === undefined ||
            transformData.isNull() ||
            transformStateData === undefined ||
            transformStateData.isNull()
          ) {
            appendLog(`Transform asset not ready for character ${characterId}; using original Cutin.`);
            return;
          }

          const dictionaryKey = Il2Cpp.string(characterId);
          const sourceAsset = cutinData
            .method("get_Item", 1)
            .invoke(dictionaryKey) as Il2Cpp.Object;
          if (sourceAsset.isNull()) {
            throw new Error(`Original Cutin asset not found for ${characterId}`);
          }
          removeExpiredOverrides();
          const assetHandle = sourceAsset.handle.toString();
          const requests = activeOverrides.get(assetHandle) ?? [];
          requests.push({
            characterId,
            sourceAsset,
            transformData,
            transformStateData,
            expiresAt: Date.now() + 30_000,
            temporaryFieldsApplied: false,
            skeletonDataServed: false,
            stateDataServed: false,
          });
          activeOverrides.set(assetHandle, requests);
          appendLog(
            `Registered temporary Cutin override for character ${characterId}; asset=${assetHandle} queue=${requests.length}.`,
          );
        } catch (error) {
          appendLog(`Failed to register battle Cutin override for ${characterId}: ${String(error)}`);
        }
      },
    });

    appendLog("Temporary battle Cutin interceptors installed.");
  } catch (error) {
    appendLog(`Initialization failed: ${String(error)}`);
  }
});
