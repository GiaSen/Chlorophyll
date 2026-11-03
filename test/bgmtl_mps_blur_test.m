// mpsblurtest: MPSImageGaussianBlur on this device through bgmtl_mps_blur_install() (src/bgmtl.m: the driver's own two-pass kernel), both
// encode methods, after a blit copy as the control of the readback. Source 64x64 BGRA: top half red, bottom half blue. Pass: the top rows stay red, the bottom rows blue (no vertical flip), the
// rows at the edge are mixed (it blurred), and nothing crashes in MPSAutoCache.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <stdio.h>
#include <stdlib.h>
extern id bgmtl_create_device(void);
extern int bgmtl_mps_blur_install(void);

enum { W = 64, H = 64 };

static id<MTLTexture>
tex(id<MTLDevice> dev)
{
   MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
   d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
   d.storageMode = MTLStorageModeShared;
   return [dev newTextureWithDescriptor:d];
}

static void
fill(id<MTLTexture> t)
{
   static uint8_t px[W * H * 4];
   for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) {
         uint8_t *p = px + (y * W + x) * 4;   // B G R A
         p[0] = y < H / 2 ? 0 : 255; p[1] = 0; p[2] = y < H / 2 ? 255 : 0; p[3] = 255;
      }
   [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
}

static int
check(const char *what, id<MTLTexture> t)
{
   static uint8_t px[W * H * 4];
   [t getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
   const uint8_t *top = px + (2 * W + 32) * 4, *bot = px + ((H - 3) * W + 32) * 4, *e0 = px + ((H / 2 - 1) * W + 32) * 4;
   int ok = top[2] > 200 && top[0] < 50 && bot[0] > 200 && bot[2] < 50 && e0[0] > 30 && e0[2] > 30;
   printf("%s: row 2 BGRA %u,%u,%u,%u  row %d %u,%u,%u,%u  row %d %u,%u,%u,%u -> %s\n", what, top[0], top[1], top[2], top[3], H / 2 - 1,
          e0[0], e0[1], e0[2], e0[3], H - 3, bot[0], bot[1], bot[2], bot[3], ok ? "PASS" : "FAIL");
   return ok;
}

int
main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);   // in order with the driver's trace on stderr
   setenv("CI_ENABLE_MPS", "0", 0);
   setenv("CI_USE_MTL_DAG_FOR_CIKL_SRC", "0", 0);
   @autoreleasepool {
      id<MTLDevice> dev = bgmtl_create_device();
      if (!dev) { printf("no device\n"); return 2; }
      printf("install: %d\n", bgmtl_mps_blur_install());
      id<MTLCommandQueue> q = [dev newCommandQueue];
      MPSImageGaussianBlur *k = [[MPSImageGaussianBlur alloc] initWithDevice:dev sigma:4];
      printf("kernel %p sigma %.1f\n", (void *)k, k.sigma);
      id<MTLTexture> src = tex(dev), dst = tex(dev);
      fill(src);
      check("source as filled", src);
      id<MTLTexture> cp = tex(dev);
      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
      [be copyFromTexture:src toTexture:cp];
      [be endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      check("blit copy (control, no blur)", cp);
      cb = [q commandBuffer];
      [k encodeToCommandBuffer:cb sourceTexture:src destinationTexture:dst];
      [cb commit];
      [cb waitUntilCompleted];
      int ok = check("encode", dst);
      id<MTLTexture> t = tex(dev);
      fill(t);
      cb = [q commandBuffer];
      BOOL r = [k encodeToCommandBuffer:cb inPlaceTexture:&t fallbackCopyAllocator:^id<MTLTexture>(MPSKernel *kk, id<MTLCommandBuffer> c, id<MTLTexture> s) {
         (void)kk; (void)c; (void)s;
         return tex(dev);
      }];
      [cb commit];
      [cb waitUntilCompleted];
      printf("in place returned %d\n", r);
      ok &= r && check("in place", t);
      printf("%s\n", ok ? "ALL PASS" : "FAILED");
      return ok ? 0 : 1;
   }
}
