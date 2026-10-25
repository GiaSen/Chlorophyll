# Chlorophyll on iOS 26 (branch `ios26`)

Bergamota's iOS 26 image is iOS 26.6.2 (23G90) for iPhone12,1 (Bergamota `docs/IOS26_PORT.md`). It was built without the Chlorophyll
payload, so its first boot uses the CPU renderer. This note covers what Chlorophyll needs on 26, read statically from the shared caches
(2026-10-24, nothing run on 26 yet).

## How it was read

The 23G90 (iPhone12,1) and 22H352 (iPhone11,8) SystemOS cryptexes were streamed from Apple's CDN and decrypted on the fly
(`remotezip` range reads piped into `aea decrypt -key-value`, the key from `ipsw fw aea -k` on the first MiB), mounted read-only,
class-dumped (`ipsw class-dump`, `--refs` for QuartzCore's selector references), then deleted. `tools/dsc-objc-gap.py OLD NEW -v`
compares the dumps with `src/bgmtl.m`. Its output is `results/ios26-23G90-vs-22H352-objc-gap.txt`.

## What changed between 18.7.8 and 26.6.2

* **Base classes** (what BGMTL* subclass): `_MTLDevice` 598 -> 672 methods, 50 -> 56 ivars; `_MTLCommandBuffer` +10 methods, +4 ivars;
  `_MTLCommandEncoder` +15; `_MTLResource` +5. `_MTLComputePipelineState` and `_MTLRenderPipelineState` now derive from `_MTLAllocation`
  instead of `NSObject` (our local `@interface` stubs still say NSObject; that only matters to the compiler, the runtime takes the
  real superclass). No method was removed from any of them. Ivars are non-fragile, so the subclasses' layout follows.
* **Required protocol methods added in 26** (`MTLDevice` 109 -> 129, `MTLDeviceSPI` 471 -> 528, pipeline states, depth-stencil,
  encoders): every one is answered by Apple's base class. The exception is `-[MTLTextureSPI writeAccessPattern]`, which the
  zero-forwarder answers with 0; that is the default access pattern.
* **QuartzCore** references 329 new selectors. The Metal ones are:
  * **Residency sets:** `newResidencySetWithDescriptor:error:` on the device, answered by `_MTLDevice`, which already had it on 18;
    `addAllocation:` and `removeAllocation:` go to the set it returns.
  * **Metal 4 queues:** `signalEvent:value:` and `waitForEvent:value:`.
  * **Shared events:** `newSharedEventWithMachPort:`.
  * **Lossy compression:** `supportsLossyCompression`, answered by `_MTLDevice`.
  * **Drawable:** `signalOnCommandQueue:` and `waitOnCommandQueue:` (the drawable is QuartzCore's own object).
* **Metal 4**: `_MTLDevice` gained `newMTL4CommandQueue[WithDescriptor:error:]`, `newCommandAllocator*`, `newCompilerWithDescriptor:error:`,
  `newArgumentTableWithDescriptor:error:`, `newCounterHeapWithDescriptor:error:`, `newTensorWithDescriptor:error:`,
  `newTextureViewPoolWithDescriptor:error:` and the `supportsMTL4*` / `supportsTensors` / `supportsMachineLearningCommandEncoders` /
  `supportsPlacementSparse` / `supportsTextureAccessPatterns` queries, plus `_MTL4CommandQueue` and IOGPU's `IOGPUMetal4*` classes.
  Their answers come from the feature tables an Apple GPU driver fills, which BGMTLDevice does not fill, and a base-class Metal 4 queue
  would not submit to our GPU. **Change on this branch:** BGMTLDevice says NO to each query (and to `supportsFamily:` MTLGPUFamilyMetal4,
  5002) and returns nil (NSError where there is one) from each factory. iOS 18 never sends these selectors, so the change is
  harmless there and can go to `main`.
* **Plugin lookup** (Chlorophyll.bundle): unchanged. Metal 26 still has `MetalPluginName`, `MetalPluginClassName`, `IOAcceleratorES`,
  `/System/Library/Extensions` and `.bundle`; `MTLIOAccelServiceGlobalContext` and `MTLIOAccelServiceDescriptor` have the same method
  sets as on 18, and `-[_MTLDevice initWithAcceleratorPort:]` is still the constructor. Kernel patch 0232's registry properties
  carry over as they are.
* **IOGPU**: 39 -> 46 classes (the seven new ones are Metal 4 and tensors). Chlorophyll does not use IOGPU.
* **IOSurface** (kernel side, also for the CPU renderer): QuartzCore 26 newly uses IOSurface shared events and transactions
  (`initWithSharedEvent:waitValue:isWrite:`, `eventPort`, `eventPortAtIndex:`, `transactionAtIndex:`; new classes
  `IOSurfaceTransaction`, `IOSurfaceTransactionListImpl`). Those reach Heartwood's IOSurface user client (0046 and later), not
  Chlorophyll: watch for failed IOSurface selectors on the first boot.

## Build

Nothing changes. Everything already builds with `-miphoneos-version-min=18.0` against the installed SDK (Xcode 27.1, iOS 27.1 SDK),
and an 18.0 deployment target loads on 26. arm64e is PAC-stripped by `freedreno-sweet/build.sh` like the rest of Renegade's root.
`src/bgmtl.m` compiles with the same 29 warnings as `main`.

## Still to check on the phone (needs a 26 boot)

1. **Residency sets.** QuartzCore 26 calls `newResidencySetWithDescriptor:error:`, which `_MTLDevice`'s default answers. Whether it
   returns a usable set or nil, and what QuartzCore does with nil, shows in `bgmtl.log` ("unimplemented") and in the render server's log.
2. **Metal 4 gating.** Whether QuartzCore takes the Metal 4 path only on `supportsMTL4CommandQueue` / Metal 4 family.
   Both now say NO, so `newMTL4CommandQueue` returning nil must leave it on the classic queue.
3. **Renegade's `bgmtl` feature** (Bergamota `tools/renegade/root_tweaks18.py`). Its paths exist in the 23G90 root, checked against
   the root image's mtree manifest in the IPSW:
   * `System/Library/ExtensionKit/Extensions/MercuryPosterExtension.appex/MercuryPosterExtension`
   * `Applications/PosterBoard.app/PosterBoard`
   * `usr/libexec/backboardd` and `System/Library/LaunchDaemons/com.apple.backboardd.plist`

   The default poster descriptor `com.apple.MercuryPoster:fluidity.two` was read back from PosterBoard on 18. Read it back again on
   26 (`sweetposterset --descriptors`) before the image makes it the default.
