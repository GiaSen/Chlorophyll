// SPDX-License-Identifier: MIT
// bgmtl-inject.dylib: puts BGMTLDevice into ONE process, MercuryPosterExtension, and nowhere else.
//
// Linked into the extension's executable as an extra LC_LOAD_DYLIB (like sweetfp.dylib into PosterBoard: Renegade's `bgmtl` feature, OFF by
// default). The constructor does nothing unless every gate is open:
//   1. the process is on the allow-list by bundle identifier (compiled in: com.apple.MercuryPoster);
//   2. /private/var/tmp/bgmtl.arm exists (the dylib is inert until a person arms it) and /private/var/tmp/bgmtl.off does not (kill switch);
//   3. the in-process dead-man has not tripped: two unclean launches in a row (state file) write bgmtl.off and the process runs as stock;
//   4. the kernel reports the GPU ready and not lost (SWEET_GPU_SEL_INFO, flags & 3);
//   5. the device can actually be made (the sandbox may refuse the GPU user client): otherwise the process stays device-less, never half-registered.
// Registration is MTLAddDevice(device) in THIS process: MTLCreateSystemDefaultDevice and MTLCopyAllDevices answer ours here, no IOKit service
// gets MetalPluginName, no other process sees anything.
// While registered a watchdog thread polls the kernel GPU state once a second: LOST, or 3 failed command buffers, writes bgmtl.off and
// _exit(0)s; the extension then relaunches as stock Metal-less. After 15 s alive the dead-man counter resets.
// Everything it does is logged to /private/var/tmp/bgmtl.log.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

extern id bgmtl_create_device(void);
extern int bgmtl_gpu_state(unsigned *abi_minor);

#define F_OFF "/private/var/tmp/bgmtl.off"
#define F_ARM "/private/var/tmp/bgmtl.arm"
#define F_STATE "/private/var/tmp/bgmtl.state"
#define F_LOG "/private/var/tmp/bgmtl.log"

static const char *const kAllow[] = { "com.apple.MercuryPoster", NULL };
static volatile int g_failures, g_registered;

static void
ilog(const char *fmt, ...)
{
   FILE *f = fopen(F_LOG, "a");
   if (!f) return;
   va_list ap;
   va_start(ap, fmt);
   fprintf(f, "[%d] ", getpid());
   vfprintf(f, fmt, ap);
   fputc('\n', f);
   va_end(ap);
   fclose(f);
}

static int
exists(const char *p)
{
   struct stat st;
   return stat(p, &st) == 0;
}

// The boot the state was written in (kern.bootsessionuuid; kern.boottime moves when the RTC is set, bgl-launch found): a launch that
// never reached "alive" in an EARLIER boot was ended by the reboot (or by RunningBoard suspending the extension, which stops the
// watchdog's clock), not by a crash, and does not count.
static const char *
boot_id(void)
{
   static char u[64];
   size_t len = sizeof u - 1;
   if (!u[0] && sysctlbyname("kern.bootsessionuuid", u, &len, NULL, 0) != 0) u[0] = 0;
   u[sizeof u - 1] = 0;
   return u[0] ? u : "-";
}

static void
write_state(int unclean, int alive)
{
   FILE *f = fopen(F_STATE, "w");
   if (!f) return;
   fprintf(f, "unclean=%d alive=%d boot=%s\n", unclean, alive, boot_id());
   fclose(f);
}

static void
trip(const char *why)
{
   ilog("DEAD-MAN: %s: writing %s and exiting", why, F_OFF);
   FILE *f = fopen(F_OFF, "w");
   if (f) { fprintf(f, "%s\n", why); fclose(f); }
   _exit(0);
}

// Per-present lines from bgmtl.m: the first 120 are logged, then every 30th, and every one whose picture reads black or whose gap to the
// previous present is over 150 ms (the flicker investigation: a black frame between draws, or a stalled frame loop).
void
bgmtl_note_present(const char *line)
{
   static volatile unsigned n;
   unsigned k = __sync_add_and_fetch(&n, 1);
   int black = strstr(line, "mean texel value 0.0") != NULL;
   if (k <= 120 || k % 30 == 0 || black)
      ilog("#%u %s%s", k, line, black ? "  <-- BLACK" : "");
}

// A command buffer finished without error: this launch draws, whatever the watchdog's clock says (RunningBoard suspends the
// extension while the wallpaper is hidden, so a suspended watchdog never reaches its 15 s, and a static wallpaper draws once).
void
bgmtl_note_completed(void)
{
   static volatile unsigned n;
   if (__sync_add_and_fetch(&n, 1) == 1) {
      write_state(0, 1);
      ilog("first command buffer completed: dead-man counter reset");
   }
}

void
bgmtl_note_unimplemented(const char *sel)
{
   ilog("UNIMPLEMENTED (answered zero): %s", sel);
}

void
bgmtl_note_failure(const char *why)
{
   int n = __sync_add_and_fetch(&g_failures, 1);
   ilog("command buffer failure %d: %s", n, why ? why : "?");
   if (n >= 3)
      trip("3 failed command buffers");
}

static void *
watchdog(void *arg)
{
   (void)arg;
   for (unsigned t = 0;; t++) {
      sleep(1);
      unsigned minor = 0;
      if (bgmtl_gpu_state(&minor) == 2)
         trip("the kernel reports the GPU lost");
      if (t == 15) {
         write_state(0, 1);
         ilog("alive for 15 s: dead-man counter reset");
      }
   }
   return NULL;
}

static void
clean_exit(void)
{
   if (g_registered && g_failures == 0)
      write_state(0, 1);
}


// Diagnostics for the first live run: an unrecognised selector sent to one of OUR objects is logged (class, selector) before the stock
// handler aborts. Only objects whose class name starts with BGMTL are logged; everything else goes straight to the original.
static IMP g_orig_dnrs;
static void
bgmtl_dnrs(id self, SEL _cmd, SEL sel)
{
   const char *cn = class_getName(object_getClass(self));
   if (cn && !strncmp(cn, "BGMTL", 5))
      ilog("UNRECOGNISED SELECTOR %s sent to %s", sel_getName(sel), cn);
   ((void (*)(id, SEL, SEL))g_orig_dnrs)(self, _cmd, sel);
}

static void
install_diag(void)
{
   Method m = class_getInstanceMethod([NSObject class], @selector(doesNotRecognizeSelector:));
   if (!m) return;
   g_orig_dnrs = method_getImplementation(m);
   method_setImplementation(m, (IMP)bgmtl_dnrs);
}

__attribute__((constructor)) static void
bgmtl_inject_init(void)
{
   @autoreleasepool {
      NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
      int allowed = 0;
      for (const char *const *a = kAllow; *a; a++)
         if (bid && !strcmp([bid UTF8String], *a)) allowed = 1;
      if (!allowed) return;                                   // gate 1: silent in every other process
      if (exists(F_OFF)) { ilog("%s: kill switch present, stock", [bid UTF8String]); return; }
      if (!exists(F_ARM)) { ilog("%s: not armed, stock", [bid UTF8String]); return; }
      // gate 3: the dead-man
      int unclean = 0, alive = 1;
      char boot[64] = "";
      FILE *f = fopen(F_STATE, "r");
      if (f) { if (fscanf(f, "unclean=%d alive=%d boot=%63s", &unclean, &alive, boot) < 2) { unclean = 0; alive = 1; } fclose(f); }
      if (!alive && strcmp(boot, boot_id()) != 0) { ilog("last launch was in an earlier boot: not counted as unclean"); alive = 1; }
      if (!alive) unclean++;
      if (unclean >= 2) trip("two unclean launches in a row");
      write_state(unclean, 0);
      // gate 4
      unsigned minor = 0;
      int st = bgmtl_gpu_state(&minor);
      if (st != 1) { ilog("GPU state %d (1 = ready): staying stock", st); write_state(unclean, 1); return; }
      // gate 5
      id dev = bgmtl_create_device();
      if (!dev) { ilog("no device could be made (sandbox? GPU?): staying stock"); write_state(unclean, 1); return; }
      void (*add)(id) = (void (*)(id))dlsym(RTLD_DEFAULT, "MTLAddDevice");
      if (!add) { ilog("MTLAddDevice not found: staying stock"); write_state(unclean, 1); return; }
      // MTLAddDevice asserts `_deviceArray != NULL` until Metal has enumerated once (found in the first live run: abort in the
      // constructor, before main). MTLCopyAllDevices builds that array; in this process it answers without a GPU service.
      NSArray *(*all)(void) = (NSArray * (*)(void))dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
      if (!all) { ilog("MTLCopyAllDevices not found: staying stock"); write_state(unclean, 1); return; }
      NSArray *pre = all();
      ilog("devices before registration: %lu", (unsigned long)[pre count]);
      install_diag();
      add(dev);
      g_registered = 1;
      ilog("%s: BGMTLDevice registered in this process (kernel ABI minor %u)", [bid UTF8String], minor);
      atexit(clean_exit);
      pthread_t th;
      pthread_create(&th, NULL, watchdog, NULL);
      pthread_detach(th);
   }
}
