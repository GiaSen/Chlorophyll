// SPDX-License-Identifier: MIT
// What is still missing for a device CoreAnimation could use? For each of our Metal classes and each Metal protocol it is meant to
// implement, count the REQUIRED instance methods that nothing in the class chain answers (class_respondsToSelector == NO), and the
// ones answered only by Apple's own base class (inherited from _MTL*: real code or an abstract stub, see mtl_gap -s).
// Creates the objects directly (no registration, no IOKit). Software backend unless the GPU is healthy (RWA_SOFTWARE=1).
//   mtl_gap            counts
//   mtl_gap -v         every unanswered selector
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>

extern id bgmtl_create_device(void);

static void
report(const char *label, Class cls, const char *proto_name, int verbose)
{
   Protocol *p = objc_getProtocol(proto_name);
   if (!p) { printf("%-26s %-28s protocol not found in this process\n", label, proto_name); return; }
   unsigned n = 0, own = 0, inherited = 0, missing = 0;
   struct objc_method_description *d = protocol_copyMethodDescriptionList(p, YES, YES, &n);
   for (unsigned i = 0; i < n; i++) {
      if (!class_respondsToSelector(cls, d[i].name)) {
         missing++;
         if (verbose) printf("    missing: %s\n", sel_getName(d[i].name));
         continue;
      }
      Method m = class_getInstanceMethod(cls, d[i].name);
      BOOL declared_here = NO;
      unsigned mn = 0;
      Method *ml = class_copyMethodList(cls, &mn);
      for (unsigned k = 0; k < mn; k++) if (method_getName(ml[k]) == d[i].name) declared_here = YES;
      free(ml);
      (void)m;
      if (declared_here) own++; else inherited++;
   }
   free(d);
   printf("%-26s %-28s required=%-4u answered_by_us=%-3u inherited_from_Metal_base=%-4u UNANSWERED=%u\n", label, proto_name, n, own, inherited, missing);
}

int
main(int argc, char **argv)
{
   @autoreleasepool {
      int v = argc > 1 && !strcmp(argv[1], "-v");
      id dev = bgmtl_create_device();
      id q = [dev newCommandQueue];
      id cb = [q commandBuffer];
      id ce = [cb computeCommandEncoder];
      id be = [cb blitCommandEncoder];
      id buf = [dev newBufferWithLength:64 options:0];
      printf("== completeness of the BGMTL classes against the protocols of iOS 18.7.8's Metal (%s)\n", getenv("RWA_SOFTWARE") ? "software backend" : "GPU backend");
      report("BGMTLDevice", [dev class], "MTLDevice", v);
      report("BGMTLDevice", [dev class], "MTLDeviceSPI", v);
      report("BGMTLCommandQueue", [q class], "MTLCommandQueue", v);
      report("BGMTLCommandBuffer", [cb class], "MTLCommandBuffer", v);
      report("BGMTLComputeEncoder", [ce class], "MTLComputeCommandEncoder", v);
      report("BGMTLComputeEncoder", [ce class], "MTLCommandEncoder", v);
      report("BGMTLBlitEncoder", [be class], "MTLBlitCommandEncoder", v);
      report("BGMTLBuffer", [buf class], "MTLBuffer", v);
      report("BGMTLBuffer", [buf class], "MTLResource", v);
      [ce endEncoding];
      [be endEncoding];
      // every MTL protocol of this process, for the record
      unsigned np = 0;
      Protocol *__unsafe_unretained *all = objc_copyProtocolList(&np);
      unsigned mtl = 0;
      for (unsigned i = 0; i < np; i++) if (!strncmp(protocol_getName(all[i]), "MTL", 3)) mtl++;
      printf("MTL* protocols registered in this process: %u of %u\n", mtl, np);
      free(all);
   }
   return 0;
}
