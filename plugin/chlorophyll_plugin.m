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

@implementation CHLDevice
- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
   const char *name = getprogname() ? getprogname() : "?";
   const char *why = NULL;
   unsigned minor = 0;

   if (chl_exists("/System/Library/Extensions/Chlorophyll.bundle/chlorophyll.off")) why = "chlorophyll.off exists";
   else if (chl_listed("/System/Library/Extensions/Chlorophyll.bundle/chlorophyll.deny", name) == 1) why = "listed in chlorophyll.deny";
   else if (chl_listed("/System/Library/Extensions/Chlorophyll.bundle/chlorophyll.allow", name) == 0) why = "chlorophyll.allow exists and does not list it";
   else if (chl_inject_loaded()) why = "the bgmtl inject owns this process's device";
   else if (bgmtl_gpu_state(&minor) != 1) why = "the kernel reports the GPU not ready";
   if (why) {
      os_log(chl_log(), "%{public}s[%d]: no device: %{public}s", name, getpid(), why);
      [self release];
      return nil;
   }
   self = [super initWithAcceleratorPort:port];
   if (self && ![self rwa]) {
      os_log(chl_log(), "%{public}s[%d]: no device: the GPU user client could not be opened (sandbox?)", name, getpid());
      [self release];
      return nil;
   }
   if (self) os_log(chl_log(), "%{public}s[%d]: Chlorophyll device made (kernel ABI minor %u)", name, getpid(), minor);
   return self;
}
@end
