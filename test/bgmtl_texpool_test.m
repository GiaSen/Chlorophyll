// texpooltest: with BGMTL_TEXPOOL_MB set, a released render target comes back for a texture of the same shape (and works:
// cleared and read back), and a texture of another shape does not take it
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdlib.h>
#import <objc/message.h>
extern id bgmtl_create_device(void);

static id<MTLTexture>
make(id<MTLDevice> dev, unsigned w, unsigned h)
{
   MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
   d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
   d.storageMode = MTLStorageModePrivate;
   return [dev newTextureWithDescriptor:d];
}

static void *
rwa_of(id t)
{
   return ((void * (*)(id, SEL))objc_msgSend)(t, sel_getUid("chlTexture"));
}

static int
clear_and_check(id<MTLCommandQueue> q, id<MTLTexture> t, double r, double g, double b)
{
   MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
   rp.colorAttachments[0].texture = t;
   rp.colorAttachments[0].loadAction = MTLLoadActionClear;
   rp.colorAttachments[0].storeAction = MTLStoreActionStore;
   rp.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1.0);
   id<MTLCommandBuffer> cb = [q commandBuffer];
   [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
   [cb commit];
   [cb waitUntilCompleted];
   uint8_t px[16] = { 0 };
   [t getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(5, 5, 1, 1) mipmapLevel:0];
   int ok = abs(px[2] - (int)(r * 255)) <= 1 && abs(px[1] - (int)(g * 255)) <= 1 && abs(px[0] - (int)(b * 255)) <= 1;
   printf("  texel BGRA %u %u %u %u -> %s\n", px[0], px[1], px[2], px[3], ok ? "ok" : "WRONG");
   return ok;
}

int
main(void)
{
   setenv("BGMTL_TEXPOOL_MB", "64", 1);
   @autoreleasepool {
      id<MTLDevice> dev = bgmtl_create_device();
      if (!dev) { printf("no device\n"); return 1; }
      id<MTLCommandQueue> q = [dev newCommandQueue];
      int ok = 1;
      void *ra;
      @autoreleasepool {   // the command buffer (autoreleased) retains A until its pool drains
         id<MTLTexture> a = make(dev, 256, 128);
         ra = rwa_of(a);
         ok &= clear_and_check(q, a, 1, 0, 0);
         [a release];
      }
      id<MTLTexture> b = make(dev, 256, 128);   // same shape: the pool's
      ok &= clear_and_check(q, b, 0, 0, 1);
      id<MTLTexture> c = make(dev, 200, 128);   // another shape: a new one
      ok &= clear_and_check(q, c, 0, 1, 0);
      void *rb = rwa_of(b), *rc = rwa_of(c);
      printf("GPU texture A %p, B %p (%s), C %p (%s)\n", ra, rb, rb == ra ? "reused" : "NOT reused", rc, rc == ra ? "WRONGLY reused" : "new");
      ok &= rb == ra && rc != ra;
      [b release]; [c release];
      printf("%s\n", ok ? "PASS" : "FAIL");
      return !ok;
   }
}
