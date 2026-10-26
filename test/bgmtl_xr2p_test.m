// xr2ptest: a two-plane 'b3a8' IOSurface (XR10 RGB + A8, MTLPixelFormatRGB10A8_2P_XR10) wrapped by Chlorophyll's device
// must read back as BGRA8 with the decoded colour: R = 894 (1.0), G = 384 (0.0), B = 639 (0.5), A = 200 -> (127,0,255,200)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/message.h>
extern id bgmtl_create_device(void);
int
main(void)
{
   @autoreleasepool {
      id dev = bgmtl_create_device();
      if (!dev) { printf("no device\n"); return 1; }
      const int W = 64, H = 32;
      NSDictionary *p0 = @{ (id)kIOSurfacePlaneWidth: @(W), (id)kIOSurfacePlaneHeight: @(H), (id)kIOSurfacePlaneBytesPerElement: @4,
                            (id)kIOSurfacePlaneBytesPerRow: @(W * 4), (id)kIOSurfacePlaneOffset: @0, (id)kIOSurfacePlaneSize: @(W * 4 * H) };
      NSDictionary *p1 = @{ (id)kIOSurfacePlaneWidth: @(W), (id)kIOSurfacePlaneHeight: @(H), (id)kIOSurfacePlaneBytesPerElement: @1,
                            (id)kIOSurfacePlaneBytesPerRow: @(W), (id)kIOSurfacePlaneOffset: @(W * 4 * H), (id)kIOSurfacePlaneSize: @(W * H) };
      NSDictionary *props = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfacePixelFormat: @('b3a8'),
                               (id)kIOSurfaceAllocSize: @(W * 4 * H + W * H), (id)kIOSurfacePlaneInfo: @[ p0, p1 ] };
      IOSurfaceRef sf = IOSurfaceCreate((CFDictionaryRef)props);
      if (!sf) { printf("IOSurfaceCreate failed\n"); return 1; }
      printf("surface %u planes %zu\n", IOSurfaceGetID(sf), IOSurfaceGetPlaneCount(sf));
      IOSurfaceLock(sf, 0, NULL);
      uint32_t word = 639u | 384u << 10 | 894u << 20;
      uint8_t *b0 = IOSurfaceGetBaseAddressOfPlane(sf, 0), *b1 = IOSurfaceGetBaseAddressOfPlane(sf, 1);
      for (int y = 0; y < H; y++)
         for (int x = 0; x < W; x++) {
            memcpy(b0 + y * IOSurfaceGetBytesPerRowOfPlane(sf, 0) + 4 * x, &word, 4);
            b1[y * IOSurfaceGetBytesPerRowOfPlane(sf, 1) + x] = 200;
         }
      IOSurfaceUnlock(sf, 0, NULL);
      MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)550 width:W height:H mipmapped:NO];
      d.usage = MTLTextureUsageShaderRead;
      id<MTLTexture> t = [dev newTextureWithDescriptor:d iosurface:sf plane:0];
      if (!t) { printf("texture refused\n"); return 1; }
      ((void * (*)(id, SEL))objc_msgSend)(t, sel_getUid("rwaTexture"));   // the refresh a draw would do
      uint8_t px[16] = { 0 };
      [t getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(10, 10, 1, 1) mipmapLevel:0];
      printf("texel = %u %u %u %u (want about 127 0 255 200)\n", px[0], px[1], px[2], px[3]);
      return !(px[0] >= 126 && px[0] <= 128 && px[1] == 0 && px[2] == 255 && px[3] == 200);
   }
}
