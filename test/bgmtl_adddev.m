// SPDX-License-Identifier: MIT
// Throw-away measurement, test process only: what does iOS 18's MTLAddDevice do with BGMTLDevice? It registers in THIS process's device list
// (no IOKit service gets MetalPluginName, no other process can see it). Prints what MTLCreateSystemDefaultDevice / MTLCopyAllDevices answer
// afterwards and runs one compute dispatch through the device Metal hands back. An assertion inside Metal ends this process, which is the answer.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
extern id bgmtl_create_device(void);
int
main(int argc, char **argv)
{
   @autoreleasepool {
      setvbuf(stdout, NULL, _IONBF, 0);
      void (*add)(id) = dlsym(RTLD_DEFAULT, "MTLAddDevice");
      printf("MTLAddDevice symbol: %p\n", add);
      NSArray *before = ((NSArray * (*)(void))dlsym(RTLD_DEFAULT, "MTLCopyAllDevices"))();
      printf("devices before: %lu\n", (unsigned long)[before count]);
      id dev = bgmtl_create_device();
      printf("created %s\n", dev ? [[dev name] UTF8String] : "nil");
      if (!dev || !add) return 2;
      printf("calling MTLAddDevice ...\n");
      add(dev);
      printf("MTLAddDevice returned\n");
      NSArray *after = ((NSArray * (*)(void))dlsym(RTLD_DEFAULT, "MTLCopyAllDevices"))();
      printf("devices after: %lu\n", (unsigned long)[after count]);
      for (id d in after) printf("  %s (%s)\n", [[d name] UTF8String], class_getName([d class]));
      id def = ((id (*)(void))dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice"))();
      printf("MTLCreateSystemDefaultDevice: %s (%s)\n", def ? [[def name] UTF8String] : "nil", def ? class_getName([def class]) : "-");
      if (def) {
         printf("maxThreadsPerThreadgroup %lu x %lu, maxBufferLength %llu, hasUnifiedMemory %d, supportsFamily Apple2 %d Apple4 %d Common1 %d\n",
                (unsigned long)[def maxThreadsPerThreadgroup].width, (unsigned long)[def maxThreadsPerThreadgroup].height,
                (unsigned long long)[def maxBufferLength], (int)[def hasUnifiedMemory], (int)[def supportsFamily:MTLGPUFamilyApple2],
                (int)[def supportsFamily:MTLGPUFamilyApple4], (int)[def supportsFamily:MTLGPUFamilyCommon1]);
         id q = [def newCommandQueue];
         printf("queue via default device: %s\n", q ? class_getName([q class]) : "nil");
      }
      return 0;
   }
}
