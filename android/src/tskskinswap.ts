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
  characters: CharacterMapping[];
}

interface PendingAsset {
  mapping: CharacterMapping;
  request: Il2Cpp.Object;
}

const fallbackRoot =
  "/sdcard/Android/data/jp.co.fanzagames.twinklestarknightsx_a_mod/files/tskskinswap";

const mappings = new Map<string, CharacterMapping>();
const loadedBundles = new Map<string, Il2Cpp.Object>();
const transformAssets = new Map<string, Il2Cpp.Object>();
const transformDataByCharacter = new Map<string, Il2Cpp.Object>();
const transformCharacterByData = new Map<string, string>();
const pendingAssets = new Map<string, PendingAsset>();
const completionScheduled = new Set<string>();
const cutinAssetClones = new Map<string, Il2Cpp.Object>();
const backgroundBones = new Map<string, { bg: Il2Cpp.Object; chara: Il2Cpp.Object }>();
const retainedObjects: Il2Cpp.Object[] = [];

const referenceAndroidAspect = 20 / 9;
const referenceBackgroundWorldScale = 2.08;

let root = fallbackRoot;

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

function readMappings(): void {
  const document = JSON.parse(File.readAllText(`${root}/mappings.json`)) as MappingDocument;
  if (document.schemaVersion !== 1 || !Array.isArray(document.characters)) {
    throw new Error("Unsupported mappings.json schema");
  }

  for (const mapping of document.characters) {
    if (mapping.enabled) {
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
  const request = bundle
    .method("LoadAssetAsync", 2)
    .invoke(Il2Cpp.string(mapping.transformSkeletonAsset), objectType) as Il2Cpp.Object;
  if (request.isNull()) {
    throw new Error(`Unable to start transform asset load for ${mapping.characterId}`);
  }
  pendingAssets.set(mapping.characterId, { mapping, request });
  retainedObjects.push(request);
  appendLog(`Started transform asset load for character ${mapping.characterId}.`);
}

function finalizeTransformLoad(mapping: CharacterMapping): boolean {
  const existing = transformAssets.get(mapping.characterId);
  if (existing !== undefined && !existing.isNull()) {
    return true;
  }

  const pending = pendingAssets.get(mapping.characterId);
  if (pending === undefined) {
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
  transformCharacterByData.set(transformData.handle.toString(), mapping.characterId);
  pendingAssets.delete(mapping.characterId);
  retainedObjects.push(transformAsset, transformData);
  const bundle = loadedBundles.get(mapping.transformBundle);
  if (bundle !== undefined && !bundle.isNull()) {
    bundle.method("Unload", 1).invoke(false);
    loadedBundles.delete(mapping.transformBundle);
    appendLog(`Released transform bundle container for character ${mapping.characterId}.`);
  }
  appendLog(`Transform asset ready for character ${mapping.characterId}.`);
  return true;
}

function scheduleTransformCompletion(mapping: CharacterMapping, attempt = 0): void {
  if (completionScheduled.has(mapping.characterId)) {
    return;
  }
  completionScheduled.add(mapping.characterId);

  const poll = (currentAttempt: number): void => {
    setTimeout(() => {
      void Il2Cpp.perform(() => finalizeTransformLoad(mapping), "main")
        .then((ready) => {
          if (ready) {
            completionScheduled.delete(mapping.characterId);
          } else if (currentAttempt < 60) {
            poll(currentAttempt + 1);
          } else {
            completionScheduled.delete(mapping.characterId);
            appendLog(`Timed out loading transform asset for ${mapping.characterId}.`);
          }
        })
        .catch((error) => {
          completionScheduled.delete(mapping.characterId);
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
    readMappings();

    const screen = Il2Cpp.domain
      .assembly("UnityEngine.CoreModule")
      .image.class("UnityEngine.Screen");
    const screenWidth = Number(screen.method("get_width").invoke());
    const screenHeight = Number(screen.method("get_height").invoke());
    const screenAspect = Math.max(screenWidth, screenHeight) / Math.min(screenWidth, screenHeight);
    const backgroundWorldScale =
      referenceBackgroundWorldScale * Math.max(1, screenAspect / referenceAndroidAspect);

    const skeletonClass = Il2Cpp.domain
      .assembly("spine-unity")
      .image.class("Spine.Skeleton");
    const compensateBackground = (pointer: NativePointer): void => {
      try {
        const skeleton = new Il2Cpp.Object(pointer);
        const skeletonData = skeleton.method("get_Data").invoke() as Il2Cpp.Object;
        const characterId = transformCharacterByData.get(skeletonData.handle.toString());
        if (characterId === undefined) {
          return;
        }

        const skeletonKey = skeleton.handle.toString();
        let bones = backgroundBones.get(skeletonKey);
        if (bones === undefined) {
          const bg = skeleton.method("FindBone", 1).invoke(Il2Cpp.string("bg")) as Il2Cpp.Object;
          const chara = skeleton.method("FindBone", 1).invoke(Il2Cpp.string("chara")) as Il2Cpp.Object;
          if (bg.isNull() || chara.isNull()) {
            return;
          }
          bones = { bg, chara };
          backgroundBones.set(skeletonKey, bones);
          appendLog(
            `Background scale compensation active for ${characterId}; aspect=${screenAspect} target=${backgroundWorldScale}.`,
          );
        }

        const charaScaleX = Math.abs(Number(bones.chara.method("get_ScaleX").invoke()));
        const charaScaleY = Math.abs(Number(bones.chara.method("get_ScaleY").invoke()));
        if (charaScaleX > 0.001 && charaScaleY > 0.001) {
          bones.bg.method("set_ScaleX").invoke(backgroundWorldScale / charaScaleX);
          bones.bg.method("set_ScaleY").invoke(backgroundWorldScale / charaScaleY);
        }
      } catch (error) {
        appendLog(`Failed to compensate Cutin background scale: ${String(error)}`);
      }
    };
    const hookedWorldTransforms = new Set<string>();
    for (const parameterCount of [0, 1]) {
      try {
        const method = skeletonClass.method("UpdateWorldTransform", parameterCount);
        const address = method.virtualAddress.toString();
        if (hookedWorldTransforms.has(address)) {
          continue;
        }
        hookedWorldTransforms.add(address);
        Interceptor.attach(method.virtualAddress, {
          onEnter(args): void {
            compensateBackground(args[0]);
          },
        });
        appendLog(`Installed background compensation hook for UpdateWorldTransform/${parameterCount}.`);
      } catch {
        // Spine runtime versions expose either the zero- or one-argument overload.
      }
    }

    const setNormalCutin = Il2Cpp.domain
      .assembly("Assembly-CSharp")
      .image.class("EffectCutinManager")
      .method("SetNormalCutin", 5);
    const loadCutin = setNormalCutin.class.method("LoadCutin", 1);

    Interceptor.attach(loadCutin.virtualAddress, {
      onEnter(args): void {
        try {
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
            const cloneData = cutinClone
              .method("GetSkeletonData", 1)
              .invoke(false) as Il2Cpp.Object;
            if (!cloneData.isNull()) {
              transformCharacterByData.set(cloneData.handle.toString(), characterId);
            }
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
