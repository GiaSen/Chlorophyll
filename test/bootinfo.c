// SPDX-License-Identifier: MIT
// Kernel boot args, uptime, which GPU-related IOKit services exist, and whether SweetAdreno630 can be opened (open, then close at once).
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
int main(void)
{
   char args[1024] = "";
   size_t n = sizeof(args) - 1;
   sysctlbyname("kern.bootargs", args, &n, NULL, 0);
   printf("bootargs: %s\n", args);
   struct timeval bt; n = sizeof(bt);
   if (sysctlbyname("kern.boottime", &bt, &n, NULL, 0) == 0) printf("uptime: %ld s\n", (long)(time(NULL) - bt.tv_sec));
   char g[2048] = ""; n = sizeof(g) - 1;
   if (sysctlbyname("kern.sweet_gpu", g, &n, NULL, 0) == 0) printf("kern.sweet_gpu: %s\n", g); else printf("kern.sweet_gpu: absent\n");
   const char *names[] = { "SweetAdreno630", "IOAcceleratorES", "AGXAccelerator", "IOGPU", "IOSurfaceRoot", "SweetFramebuffer", NULL };
   for (const char **p = names; *p; p++) {
      io_iterator_t it = 0;
      int count = 0;
      if (IOServiceGetMatchingServices(0, IOServiceMatching(*p), &it) == KERN_SUCCESS) {
         io_object_t o;
         while ((o = IOIteratorNext(it))) { count++; IOObjectRelease(o); }
         IOObjectRelease(it);
      }
      printf("service %-18s %d\n", *p, count);
   }
   io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("SweetAdreno630"));
   if (svc) {
      io_connect_t c = 0;
      kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c);
      printf("IOServiceOpen(SweetAdreno630, type 0) = %#x%s\n", kr, kr == KERN_SUCCESS ? " (ok)" : "");
      if (c) IOServiceClose(c);
      IOObjectRelease(svc);
   }
   return 0;
}
