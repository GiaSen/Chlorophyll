// srctest: -newLibraryWithSource: on this device (Apple's MSL front end through MTLCompilerService, then the AIR path): a compute kernel
// that writes 2*i+1 into a buffer. Pass: the values come back.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
extern id bgmtl_create_device(void);

int
main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   @autoreleasepool {
      id<MTLDevice> dev = bgmtl_create_device();
      NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                       "kernel void k(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = 2 * i + 1; }\n";
      NSError *e = nil;
      id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
      printf("library %p error %s\n", (void *)lib, e ? [[e description] UTF8String] : "none");
      if (!lib) return 1;
      id<MTLFunction> f = [lib newFunctionWithName:@"k"];
      id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&e];
      printf("function %p pipeline %p error %s\n", (void *)f, (void *)ps, e ? [[e description] UTF8String] : "none");
      if (!ps) return 1;
      id<MTLBuffer> b = [dev newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared];
      memset(b.contents, 0, 64 * 4);
      id<MTLCommandQueue> q = [dev newCommandQueue];
      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
      [ce setComputePipelineState:ps];
      [ce setBuffer:b offset:0 atIndex:0];
      [ce dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
      [ce endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      uint32_t *o = b.contents;
      int ok = 1;
      for (int i = 0; i < 64; i++) ok &= o[i] == 2u * i + 1;
      printf("o[0..3] %u %u %u %u o[63] %u -> %s\n", o[0], o[1], o[2], o[3], o[63], ok ? "PASS" : "FAIL");
      return ok ? 0 : 1;
   }
}
