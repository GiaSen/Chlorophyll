// SPDX-License-Identifier: MIT
// Spike 2, step 0: what does iOS 18.7.8's Metal.framework look like from user space? Read-only introspection of the objc
// runtime. It creates no device, calls no MTLCreateSystemDefaultDevice / MTLCopyAllDevices / MTLAddDevice and opens no IOKit service.
//   mtl_introspect                  summary of the classes a Metal device driver subclasses
//   mtl_introspect -m CLASS         every instance method of CLASS (and its superclasses' names)
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>

static void
dump_class(const char *name, int methods)
{
   Class c = objc_getClass(name);
   if (!c) { printf("%-34s MISSING\n", name); return; }
   unsigned n = 0, ni = 0, np = 0;
   Method *m = class_copyMethodList(c, &n);
   Ivar *iv = class_copyIvarList(c, &ni);
   Protocol *__unsafe_unretained *pl = class_copyProtocolList(c, &np);
   printf("%-34s super=%-24s inst_methods=%u ivars=%u size=%zu protocols=", name,
          class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "-", n, ni, class_getInstanceSize(c));
   for (unsigned i = 0; i < np; i++) printf("%s%s", i ? "," : "", protocol_getName(pl[i]));
   printf("\n");
   if (methods) {
      for (unsigned i = 0; i < n; i++) printf("  - %s  %s\n", sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i]));
      for (unsigned i = 0; i < ni; i++) printf("  ivar %s %s +%td\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]), ivar_getOffset(iv[i]));
   }
   free(m); free(iv); free(pl);
}

static void
dump_protocol(const char *name)
{
   Protocol *p = objc_getProtocol(name);
   if (!p) { printf("protocol %-30s MISSING\n", name); return; }
   unsigned req = 0, opt = 0;
   free(protocol_copyMethodDescriptionList(p, YES, YES, &req));
   free(protocol_copyMethodDescriptionList(p, NO, YES, &opt));
   printf("protocol %-30s required_inst=%u optional_inst=%u\n", name, req, opt);
}

int
main(int argc, char **argv)
{
   @autoreleasepool {
      void *h = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_NOW);
      printf("Metal.framework dlopen: %s\n", h ? "ok" : dlerror());
      if (argc == 3 && !strcmp(argv[1], "-m")) { dump_class(argv[2], 1); return 0; }
      const char *classes[] = { "_MTLDevice", "_MTLObjectWithLabel", "_MTLResource", "_MTLCommandQueue", "_MTLCommandBuffer",
         "_MTLCommandEncoder", "_MTLComputeCommandEncoder", "_MTLComputePipelineState", "_MTLRenderPipelineState", "_MTLFunction",
         "_MTLLibrary", "_MTLBuffer", "_MTLTexture", "_MTLSamplerState", "_MTLDepthStencilState", "_MTLHeap", "_MTLEvent",
         "_MTLFence", "MTLIOAccelDevice", "MTLIOAccelCommandQueue", "MTLIOAccelCommandBuffer", "MTLIOAccelBuffer",
         "MTLIOAccelCommandEncoder", "MTLIOAccelComputeCommandEncoder", "IOGPUMetalDevice", "IOGPUMetalCommandQueue",
         "IOGPUMetalBuffer", "MTLComputePipelineDescriptorInternal", "MTLCompilerService", "_MTLCompiler", "MTLCompiler",
         "MTLCommandQueueDescriptor", "MTLLibrarySPI", NULL };
      for (const char **c = classes; *c; c++) dump_class(*c, 0);
      const char *protos[] = { "MTLDevice", "MTLDeviceSPI", "MTLCommandQueue", "MTLCommandBuffer", "MTLCommandBufferSPI",
         "MTLComputeCommandEncoder", "MTLBuffer", "MTLResource", "MTLComputePipelineState", "MTLComputePipelineStateSPI",
         "MTLLibrary", "MTLFunction", "MTLFunctionSPI", "MTLBlitCommandEncoder", NULL };
      for (const char **p = protos; *p; p++) dump_protocol(*p);
      // init-family selectors of the bases (what a subclass must call)
      const char *bases[] = { "_MTLDevice", "_MTLCommandQueue", "_MTLCommandBuffer", "_MTLCommandEncoder", "_MTLComputePipelineState",
                              "_MTLResource", "_MTLObjectWithLabel", NULL };
      for (const char **b = bases; *b; b++) {
         Class c = objc_getClass(*b);
         if (!c) continue;
         unsigned n = 0; Method *m = class_copyMethodList(c, &n);
         printf("%s init-family:", *b);
         for (unsigned i = 0; i < n; i++) { const char *s = sel_getName(method_getName(m[i])); if (!strncmp(s, "init", 4)) printf(" %s", s); }
         printf("\n"); free(m);
      }
      // the discovery switches, as names only
      printf("MTLCreateSystemDefaultDevice symbol: %p, MTLCopyAllDevices: %p, MTLAddDevice: %p (not called)\n",
             dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice"), dlsym(RTLD_DEFAULT, "MTLCopyAllDevices"), dlsym(RTLD_DEFAULT, "MTLAddDevice"));
   }
   return 0;
}
