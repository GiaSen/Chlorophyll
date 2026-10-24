// SPDX-License-Identifier: MIT
// Chlorophyll.bundle: Chlorophyll as the system's Metal driver, loaded by Metal.framework itself in every process that asks
// for a device, the way an iPhone loads AGXMetal<GPU>.bundle.
//
// iOS 18 Metal (MTLIOAccelServiceGlobalContext -init, read from the 22H352 shared cache): for every IOService of class
// "IOAcceleratorES" it reads the registry property MetalPluginName, loads /System/Library/Extensions/<name>.bundle, takes
// the class named by MetalPluginClassName (else the bundle's principal class), which must be a subclass of _MTLDevice,
// and later (processPendingCreateIOAccelServiceRequests) does [[class alloc] initWithAcceleratorPort:service] and
// MTLAddDevice() with what comes back. Heartwood publishes those two properties on its IOAcceleratorES only with the
// boot-arg chlorophyll=1 (xnu patch 0232); without it Metal finds the service and passes it over, as before.
//
// CHLDevice is BGMTLDevice (src/bgmtl.m, compiled into this bundle) behind gates. Returning nil leaves the process with no
// Metal device, which is how every process ran before, so each gate fails closed:
//   1. /System/Library/Extensions/Chlorophyll.bundle/chlorophyll.off exists: nil everywhere (kill switch; a person or a watchdog writes it);
//   2. the process is listed in /System/Library/Extensions/Chlorophyll.bundle/chlorophyll.deny (one process name per line): nil there; and when
//      /System/Library/Extensions/Chlorophyll.bundle/chlorophyll.allow exists, only the processes listed in it get a device (staged roll-out);
//   3. the bgmtl inject is loaded in the process (backboardd in Metal mode, the Mercury poster): it registers its own device
//      and stays the owner there, so the plugin adds no second one ("MTLCreateSystemDefaultDevice doesn't know what to do
//      with more than one device");
//   4. the kernel reports the GPU not ready or lost, or the GPU user client cannot be opened (sandbox): nil.
// The control files live in the bundle (root-owned, readable by every process that can load it; sandboxed apps cannot
// read /private/var/tmp, and an unreadable kill switch would fail open).
// Every decision is one os_log line (subsystem com.bergamota.chlorophyll, readable with sweetlog).
#include "../src/bgmtl.m"
#include <mach-o/dyld.h>
#include <os/log.h>

static os_log_t
chl_log(void)
{
   static os_log_t log;
   static dispatch_once_t once;
   dispatch_once(&once, ^{ log = os_log_create("com.bergamota.chlorophyll", "plugin"); });
   return log;
}

static int
chl_exists(const char *path)
{
   struct stat st;
   return stat(path, &st) == 0;
}

/* 1 when NAME is a line of PATH, 0 when not, -1 when PATH cannot be read */
static int
chl_listed(const char *path, const char *name)
{
   FILE *f = fopen(path, "r");
   if (!f) return -1;
   char line[256];
   int hit = 0;
   while (!hit && fgets(line, sizeof(line), f)) {
      line[strcspn(line, "\r\n")] = 0;
      hit = line[0] && strcmp(line, name) == 0;
   }
   fclose(f);
   return hit;
}

static int
chl_inject_loaded(void)
{
   uint32_t n = _dyld_image_count();
   for (uint32_t i = 0; i < n; i++) {
      const char *p = _dyld_get_image_name(i);
      if (p && strstr(p, "bgmtl-inject.dylib")) return 1;
   }
   return 0;
}

@interface CHLDevice : BGMTLDevice
@end

/* NULL when this process may have a device, else why not (logged once per process) */
static const char *
chl_refusal(unsigned *minor)
{
   const char *name = getprogname() ? getprogname() : "?";
   if (chl_exists("/System/Library/Extensions/Chlorophyll.bundle/chlorophyll.off")) return "chlorophyll.off exists";
   if (chl_listed("/System/Library/Extensions/Chlorophyll.bundle/chlorophyll.deny", name) == 1) return "listed in chlorophyll.deny";
   if (chl_listed("/System/Library/Extensions/Chlorophyll.bundle/chlorophyll.allow", name) == 0) return "chlorophyll.allow exists and does not list it";
   if (chl_inject_loaded()) return "the bgmtl inject owns this process's device";
   /* backboardd's Metal mode belongs to bgl-launch and the inject (compositor profile, readback, watchdog); when they chose
    * the CPU renderer (bgmtl-bb.off) that is the fallback, and a plugin device there composited without the compositor
    * profile (static areas showed the zoomed wallpaper) */
   if (!strcmp(name, "backboardd")) return "backboardd: Metal only through the inject, else the CPU renderer";
   if (bgmtl_gpu_state(minor) != 1) return "the kernel reports the GPU not ready";
   return NULL;
}

@implementation CHLDevice
/*
 * Refused here, before an object exists: Metal does [[class alloc] initWithAcceleratorPort:], and an object released
 * before _MTLDevice's -init ran crashes in its -dealloc (dispatch_release(NULL); backboardd crash-looped, 2026-10-24).
 * nil from +alloc makes the init a message to nil, and Metal skips a nil device.
 */
+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
   unsigned minor = 0;
   const char *why = chl_refusal(&minor);
   if (why) {
      os_log(chl_log(), "%{public}s[%d]: no device: %{public}s", getprogname() ? getprogname() : "?", getpid(), why);
      return nil;
   }
   return [super allocWithZone:zone];
}

+ (instancetype)alloc
{
   return [self allocWithZone:NULL];
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
   const char *name = getprogname() ? getprogname() : "?";
   self = [super initWithAcceleratorPort:port];
   if (self && ![self rwa]) {
      os_log(chl_log(), "%{public}s[%d]: no device: the GPU user client could not be opened (sandbox?)", name, getpid());
      [self release];   /* fully initialized here: BGMTLDevice's own teardown, as bgmtl_create_device does */
      return nil;
   }
   if (self) {
      /*
       * CoreImage, given a Metal device, translates CIKernel Language source into its Metal kernel graph
       * (CI_USE_MTL_DAG_FOR_CIKL_SRC, read after it asked for the device) and merges that kernel's argument list
       * with the CIKL parse; with Chlorophyll the translated list comes back empty and the merge writes through NULL
       * (SBRendererService / PhotoImaging crashed in +[CIKernel kernelsWithString:]). Without the graph CoreImage
       * builds those kernels as before and still renders on this device (its stitchable metallibs load and run).
       */
      setenv("CI_USE_MTL_DAG_FOR_CIKL_SRC", "0", 0);
      /*
       * QuartzCore uploads asset-catalog images straight from CGImageTextureData, asking CoreGraphics for Apple's GPU
       * tiled layout of the compressed data; that layout is padded and CoreGraphics read past the mapped file
       * (SpringBoard crash-looped in CGImageTextureDataGetOffsetWithBlock), and an Adreno could not sample it anyway.
       * Off: those images are decoded and uploaded as ordinary textures.
       */
      setenv("CA_USE_CGTEXTUREDATA", "0", 0);
      os_log(chl_log(), "%{public}s[%d]: Chlorophyll device made", name, getpid());
   }
   return self;
}
@end
