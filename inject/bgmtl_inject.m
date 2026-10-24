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
//
// backboardd (Chlorophyll as the system compositor): only when bgl-launch chose Metal for this launch and says so with BGMTL_BB=1
// (bgl-launch has already checked bgmtl-bb.arm, bgmtl-bb.off and that the previous Metal launch became healthy). Here: the device is
// registered before QuartzCore creates its render server (which then builds CA::OGL::MetalContext itself), framebuffer and IOSurface
// compression and deep framebuffers are turned off (Apple GPU layouts this GPU does not write), and a stricter watchdog runs: GPU
// lost, 3 failed command buffers, or no completed command buffer within 60 s of the first commit write bgmtl-bb.off and _exit(0); launchd
// relaunches backboardd and bgl-launch starts it on the ES path. 10 s after the first completed command buffer with no failure the
// launch is marked healthy in bgmtl-bb.state. "crashtest" in bgmtl-bb.arm crashes on purpose 5 s after registration (guard test).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
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

#define F_BB_OFF "/private/var/tmp/bgmtl-bb.off"
#define F_BB_ARM "/private/var/tmp/bgmtl-bb.arm"
#define F_BB_STATE "/private/var/tmp/bgmtl-bb.state"

static const char *const kAllow[] = { "com.apple.MercuryPoster", NULL };
static volatile int g_failures, g_registered, g_bb;
static volatile unsigned g_completed;

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
bb_state(int alive)
{
   FILE *f = fopen(F_BB_STATE, "w");
   if (!f) return;
   fprintf(f, "alive=%d boot=%s\n", alive, boot_id());
   fclose(f);
}

static void
trip(const char *why)
{
   const char *off = g_bb ? F_BB_OFF : F_OFF;
   ilog("DEAD-MAN%s: %s: writing %s and exiting", g_bb ? " (backboardd)" : "", why, off);
   FILE *f = fopen(off, "w");
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
   if (__sync_add_and_fetch(&g_completed, 1) == 1) {
      if (g_bb) { ilog("backboardd: first command buffer completed"); return; }
      write_state(0, 1);
      ilog("first command buffer completed: dead-man counter reset");
   }
}

// The first commit starts the backboardd watchdog's 60 s: a backboardd started while the display is off or idle has nothing
// to draw, and counting from launch switched Metal off for good (bgmtl-bb.off) on every such restart.
static volatile unsigned g_first_commit_t;
static volatile unsigned g_watch_t;
void
bgmtl_note_committed(void)
{
   if (!g_first_commit_t) g_first_commit_t = g_watch_t ? g_watch_t : 1;
}

void
bgmtl_note_line(const char *line)
{
   ilog("%s", line);
}

// How backboardd ends (it restarted after one failed command buffer and left no crash report): exit() runs the atexit
// line, a fatal signal writes its name and a backtrace (async-signal-safe: write and backtrace_symbols_fd to an fd opened
// up front) and is re-raised with the default action. A restart with neither line was a SIGKILL from outside.
static int g_exit_fd = -1;
static void
bb_atexit(void)
{
   char m[96];
   int n = snprintf(m, sizeof(m), "[%d] backboardd: exit() called\n", getpid());
   if (g_exit_fd >= 0) {
      write(g_exit_fd, m, n);
      void *bt[32];
      backtrace_symbols_fd(bt, backtrace(bt, 32), g_exit_fd);
   }
}
static void
bb_fatal(int sig)
{
   if (g_exit_fd >= 0) {
      char m[64] = "[";
      char num[16];
      int p = getpid(), k = 0;
      do { num[k++] = '0' + p % 10; p /= 10; } while (p);
      size_t n = 1;
      while (k) m[n++] = num[--k];
      const char *s = "] backboardd: fatal signal ";
      while (*s) m[n++] = *s++;
      const char *name = sys_signame[sig];
      while (*name && n < sizeof(m) - 2) m[n++] = *name++;
      m[n++] = '\n';
      write(g_exit_fd, m, n);
      void *bt[32];
      backtrace_symbols_fd(bt, backtrace(bt, 32), g_exit_fd);
   }
   signal(sig, SIG_DFL);
   raise(sig);
}
static void
bb_watch_exit(void)
{
   g_exit_fd = open(F_LOG, O_WRONLY | O_APPEND | O_CREAT, 0644);
   atexit(bb_atexit);
   const int sigs[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGTERM, SIGFPE };
   for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++)
      signal(sigs[i], bb_fatal);
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

// backboardd: the stricter watchdog (see the header)
static void *
watchdog_bb(void *arg)
{
   int crashtest = (int)(intptr_t)arg;
   unsigned healthy_at = 0;
   for (unsigned t = 1;; t++) {
      sleep(1);
      unsigned minor = 0;
      if (bgmtl_gpu_state(&minor) == 2)
         trip("the kernel reports the GPU lost");
      if (crashtest && t == 5) {
         ilog("backboardd: crashtest armed: crashing on purpose");
         abort();
      }
      g_watch_t = t;
      if (!g_completed && g_first_commit_t && t >= g_first_commit_t + 60)
         trip("no command buffer completed within 60 s of the first commit");
      if (g_completed && !healthy_at)
         healthy_at = t + 10;
      if (healthy_at && t == healthy_at && g_failures == 0) {
         bb_state(1);
         ilog("backboardd: healthy (10 s after the first completed command buffer, no failure)");
      }
   }
   return NULL;
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

static void
bb_init(void)
{
   g_bb = 1;
   if (exists(F_BB_OFF)) { ilog("backboardd: %s present, stock", F_BB_OFF); return; }
   int crashtest = 0;
   FILE *a = fopen(F_BB_ARM, "r");
   if (!a) { ilog("backboardd: not armed, stock"); return; }
   char word[32] = "";
   if (fscanf(a, "%31s", word) == 1 && !strcmp(word, "crashtest")) crashtest = 1;
   fclose(a);
   unsigned minor = 0;
   int st = bgmtl_gpu_state(&minor);
   if (st != 1) { ilog("backboardd: GPU state %d (1 = ready): stock", st); return; }
   // A/B switch: freedreno without batch reordering (FD_MESA_DEBUG=inorder)
   if (exists("/private/var/tmp/bgmtl-bb.inorder")) { setenv("FD_MESA_DEBUG", "inorder", 1); ilog("backboardd: FD_MESA_DEBUG=inorder"); }
   // A/B switch: any FD_MESA_DEBUG flags (e.g. "sysmem", "nobin", "nolrz"), one word per line or comma-separated
   FILE *fd = fopen("/private/var/tmp/bgmtl-bb.fddebug", "r");
   if (fd) {
      char flags[128] = "";
      if (fgets(flags, sizeof(flags), fd)) {
         flags[strcspn(flags, "\r\n")] = 0;
         if (flags[0]) { setenv("FD_MESA_DEBUG", flags, 1); ilog("backboardd: FD_MESA_DEBUG=%s", flags); }
      }
      fclose(fd);
   }
   // Apple GPU layouts this GPU does not write: compressed framebuffers and IOSurfaces, deep (10-bit) framebuffers
   setenv("CA_DISABLE_FRAMEBUFFER_COMPRESSION", "1", 1);
   // A/B switch: "scheduled" only once the GPU finished, as before 0229/0240 (see -commit in src/bgmtl.m)
   if (exists("/private/var/tmp/bgmtl-bb.defersched")) { setenv("BGMTL_DEFER_SCHEDULED", "1", 1); ilog("backboardd: BGMTL_DEFER_SCHEDULED=1"); }
   if (exists("/private/var/tmp/bgmtl-bb.sync")) {     // A/B: synchronous commits (the frame-order glitches after the async change)
      setenv("BGMTL_SYNC", "1", 1);
      ilog("backboardd: BGMTL_SYNC=1 (synchronous commits)");
   }
   if (exists("/private/var/tmp/bgmtl-bb.triple")) {   // three framebuffers: with sweetfb_swapdepth=2 CoreAnimation draws N+1 while N
      setenv("CA_FORCE_TRIPLE_BUFFERING", "1", 1);     // is queued and N-1 is on the panel; with two buffers N+1 lands in the scanned one
      ilog("backboardd: CA_FORCE_TRIPLE_BUFFERING=1");
   }
   if (exists("/private/var/tmp/bgmtl-bb.full")) {     // experiment: full redraws (the first live run showed stale regions)
      setenv("CA_DISABLE_DIRTY_REGIONS", "1", 1);
      ilog("backboardd: CA_DISABLE_DIRTY_REGIONS=1");
   }
   CFPreferencesSetAppValue(CFSTR("CAEnableFramebufferCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
   CFPreferencesSetAppValue(CFSTR("CAEnableIOSurfaceCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
   CFPreferencesSetAppValue(CFSTR("CAEnableDeepFramebuffer"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
   id dev = bgmtl_create_device();
   if (!dev) { ilog("backboardd: no device could be made: stock"); return; }
   void (*add)(id) = (void (*)(id))dlsym(RTLD_DEFAULT, "MTLAddDevice");
   NSArray *(*all)(void) = (NSArray * (*)(void))dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
   if (!add || !all) { ilog("backboardd: Metal registration entry points missing: stock"); return; }
   ilog("backboardd: devices before registration: %lu", (unsigned long)[all() count]);
   install_diag();
   bb_watch_exit();
   add(dev);
   g_registered = 1;
   ilog("backboardd: Chlorophyll device registered (kernel ABI minor %u)%s", minor, crashtest ? ", CRASHTEST armed" : "");
   pthread_t th;
   pthread_create(&th, NULL, watchdog_bb, (void *)(intptr_t)crashtest);
   pthread_detach(th);
}

__attribute__((constructor)) static void
bgmtl_inject_init(void)
{
   @autoreleasepool {
      if (getenv("BGMTL_BB") && !strcmp(getprogname(), "backboardd")) {   // bgl-launch chose Metal for this launch
         bb_init();
         return;
      }
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
