// SPDX-License-Identifier: MIT
// Spike 3: textures, samplers and a render pass on BGMTLDevice (test process only, nothing registered).
//   bgmtl_render_probe KERNELS.metallib RENDER.metallib
// P1-P3 compute with textures (read, sample through a sampler, write), P4 a coloured triangle with analytic pixel checks,
// P5 a textured quad (nearest sampler) against the texture magnified and flipped by Metal's rules.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern id bgmtl_create_device(void);

static int g_pass, g_fail;
#define CHECK(cond, ...) do { if (cond) { g_pass++; } else { g_fail++; printf("  FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static id g_dev, g_queue;

static id
load_lib(const char *path)
{
   NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
   if (!d) { printf("cannot read %s\n", path); return nil; }
   dispatch_data_t dd = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
   NSError *e = nil;
   id lib = [g_dev newLibraryWithData:dd error:&e];
   if (!lib) printf("newLibraryWithData(%s): %s\n", path, e ? [[e localizedDescription] UTF8String] : "?");
   return lib;
}

static id
compute_pso(id lib, const char *fn)
{
   id f = [lib newFunctionWithName:[NSString stringWithUTF8String:fn]];
   NSError *e = nil;
   id p = f ? [g_dev newComputePipelineStateWithFunction:f error:&e] : nil;
   if (!p) printf("  compute pipeline %s: %s\n", fn, e ? [[e localizedDescription] UTF8String] : "no function");
   return p;
}

static id
tex2d(NSUInteger fmt, NSUInteger w, NSUInteger h, NSUInteger usage)
{
   MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)fmt width:w height:h mipmapped:NO];
   d.usage = usage;
   d.storageMode = MTLStorageModeShared;
   return [g_dev newTextureWithDescriptor:d];
}

static BOOL
run(id cb, const char *what)
{
   [cb commit];
   [cb waitUntilCompleted];
   printf("  %s: status=%ld%s%s\n", what, (long)[cb status], [cb error] ? " error=" : "", [cb error] ? [[[cb error] localizedDescription] UTF8String] : "");
   return [cb status] == 4;
}

int
main(int argc, char **argv)
{
   @autoreleasepool {
      if (argc < 3) { printf("usage: bgmtl_render_probe kernels.metallib render.metallib\n"); return 2; }
      printf("== BGMTLDevice textures/render probe (iOS %s)\n", [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);
      g_dev = bgmtl_create_device();
      g_queue = [g_dev newCommandQueue];
      id klib = load_lib(argv[1]), rlib = load_lib(argv[2]);
      if (!g_dev || !g_queue || !klib || !rlib) return 3;

      // ---- P1: texture read in a kernel (RGBA32Float 8x8) ----
      printf("== P1 bg_tex_read\n");
      {
         id pso = compute_pso(klib, "bg_tex_read");
         id t = tex2d(MTLPixelFormatRGBA32Float, 8, 8, MTLTextureUsageShaderRead);
         id out = [g_dev newBufferWithLength:8 * 8 * 16 options:0];
         if (pso && t && out) {
            float px[8 * 8 * 4];
            for (int i = 0; i < 64; i++) { px[i * 4] = i; px[i * 4 + 1] = 100 + i; px[i * 4 + 2] = -i; px[i * 4 + 3] = 0.25f; }
            [t replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:px bytesPerRow:8 * 16];
            memset([out contents], 0xff, 8 * 8 * 16);
            id cb = [g_queue commandBuffer];
            id e = [cb computeCommandEncoder];
            [e setComputePipelineState:pso];
            [e setTexture:t atIndex:0];
            [e setBuffer:out offset:0 atIndex:0];
            [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [e endEncoding];
            CHECK(run(cb, "bg_tex_read"), "did not complete");
            unsigned bad = 0;
            float *o = [out contents];
            for (int i = 0; i < 64 * 4; i++) if (o[i] != px[i]) bad++;
            CHECK(bad == 0, "bg_tex_read: %u of 256 floats wrong", bad);
            printf("  %u of 256 floats correct\n", 256 - bad);
         } else { g_fail++; printf("  setup failed\n"); }
      }

      // ---- P2: sample through a sampler (RGBA8Unorm 4x4, nearest) ----
      printf("== P2 bg_tex_sample (nearest sampler)\n");
      {
         id pso = compute_pso(klib, "bg_tex_sample");
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = MTLSamplerMinMagFilterNearest; sd.magFilter = MTLSamplerMinMagFilterNearest;
         sd.sAddressMode = MTLSamplerAddressModeClampToEdge; sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
         id smp = [g_dev newSamplerStateWithDescriptor:sd];
         id out = [g_dev newBufferWithLength:4 * 4 * 16 options:0];
         if (pso && t && smp && out) {
            uint8_t px[4 * 4 * 4];
            for (int i = 0; i < 16; i++) { px[i * 4] = i * 16; px[i * 4 + 1] = 255 - i * 16; px[i * 4 + 2] = i; px[i * 4 + 3] = 255; }
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
            id cb = [g_queue commandBuffer];
            id e = [cb computeCommandEncoder];
            [e setComputePipelineState:pso];
            [e setTexture:t atIndex:0]; [e setSamplerState:smp atIndex:0]; [e setBuffer:out offset:0 atIndex:0];
            [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(4, 4, 1)];
            [e endEncoding];
            CHECK(run(cb, "bg_tex_sample"), "did not complete");
            unsigned bad = 0;
            float *o = [out contents];
            for (int i = 0; i < 16; i++)
               for (int c = 0; c < 4; c++) if (fabsf(o[i * 4 + c] - px[i * 4 + c] / 255.0f) > 1e-3f) bad++;
            CHECK(bad == 0, "bg_tex_sample: %u of 64 wrong", bad);
            printf("  %u of 64 floats correct\n", 64 - bad);
         } else { g_fail++; printf("  setup failed (pso=%d t=%d smp=%d)\n", pso != nil, t != nil, smp != nil); }
      }

      // ---- P3: write a texture from a kernel, read it back ----
      printf("== P3 bg_tex_write\n");
      {
         id pso = compute_pso(klib, "bg_tex_write");
         id t = tex2d(MTLPixelFormatRGBA32Float, 16, 16, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
         if (pso && t) {
            id cb = [g_queue commandBuffer];
            id e = [cb computeCommandEncoder];
            [e setComputePipelineState:pso];
            [e setTexture:t atIndex:0];
            [e dispatchThreadgroups:MTLSizeMake(2, 2, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [e endEncoding];
            CHECK(run(cb, "bg_tex_write"), "did not complete");
            float back[16 * 16 * 4];
            [t getBytes:back bytesPerRow:16 * 16 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
            unsigned bad = 0;
            for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
               float *p = back + (y * 16 + x) * 4;
               if (fabsf(p[0] - x / 16.0f) > 1e-6f || fabsf(p[1] - y / 16.0f) > 1e-6f || p[2] != 0.5f || p[3] != 1.0f) bad++;
            }
            CHECK(bad == 0, "bg_tex_write: %u of 256 texels wrong", bad);
            printf("  %u of 256 texels correct\n", 256 - bad);
         } else { g_fail++; printf("  setup failed\n"); }
      }

      // ---- P4: coloured triangle ----
      printf("== P4 render pass: coloured triangle into BGRA8 64x64\n");
      id rt = tex2d(MTLPixelFormatBGRA8Unorm, 64, 64, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_color"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         static const float tri[3 * 8] = {
            -1, -1, 0, 1,   1, 0, 0, 1,     // bottom-left red
             1, -1, 0, 1,   0, 1, 0, 1,     // bottom-right green
            -1,  1, 0, 1,   0, 0, 1, 1 };   // top-left blue
         id vb = [g_dev newBufferWithBytes:tri length:sizeof(tri) options:0];
         if (pso && rt && vb) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            CHECK(run(cb, "triangle"), "render pass did not complete");
            uint8_t px[64 * 64 * 4];
            [rt getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
            unsigned bad = 0, inside = 0, checked = 0;
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
               // pixel centre in NDC (y up, row 0 at the top)
               float nx = (x + 0.5f) / 32.0f - 1.0f, ny = 1.0f - (y + 0.5f) / 32.0f;
               // barycentric weights: red at (-1,-1), green at (1,-1), blue at (-1,1)
               float wg = (nx + 1) / 2, wb = (ny + 1) / 2, wr = 1 - wg - wb;
               uint8_t *p = px + (y * 64 + x) * 4;       // B G R A
               float margin = 0.03f;
               if (wr > margin && wg > margin && wb > margin) {
                  checked++; inside++;
                  float er = wr * 255, eg = wg * 255, eb = wb * 255;
                  if (fabsf(p[2] - er) > 3 || fabsf(p[1] - eg) > 3 || fabsf(p[0] - eb) > 3 || p[3] != 255) { if (bad++ < 3) printf("    (%d,%d) got %u,%u,%u want %.0f,%.0f,%.0f\n", x, y, p[2], p[1], p[0], er, eg, eb); }
               } else if (wr < -margin || wg < -margin || wb < -margin) {
                  checked++;
                  if (p[0] || p[1] || p[2] || p[3] != 255) { if (bad++ < 3) printf("    outside (%d,%d) not the clear colour: %u,%u,%u,%u\n", x, y, p[2], p[1], p[0], p[3]); }
               }
            }
            CHECK(bad == 0 && inside > 1500, "triangle: %u wrong of %u checked pixels (%u inside)", bad, checked, inside);
            printf("  %u of %u checked pixels correct (%u inside the triangle)\n", checked - bad, checked, inside);
         } else { g_fail++; printf("  setup failed\n"); }
      }

      // ---- P5: textured quad ----
      printf("== P5 textured quad (4x4 checker, nearest sampler)\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         static const float quad[6 * 8] = {
            -1, -1, 0, 1, 1,1,1,1,   1, -1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1,
             1, -1, 0, 1, 1,1,1,1,   1,  1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1 };
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
         sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
         id smp = [g_dev newSamplerStateWithDescriptor:sd];
         id rt2 = tex2d(MTLPixelFormatBGRA8Unorm, 64, 64, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         if (pso && vb && t && smp && rt2) {
            uint8_t tx[4 * 4 * 4];
            for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
               uint8_t *p = tx + (y * 4 + x) * 4;
               p[0] = x * 80; p[1] = y * 80; p[2] = ((x + y) & 1) ? 255 : 0; p[3] = 255;
            }
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:tx bytesPerRow:16];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt2;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setFragmentTexture:t atIndex:0];
            [e setFragmentSamplerState:smp atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            CHECK(run(cb, "textured quad"), "render pass did not complete");
            uint8_t px[64 * 64 * 4];
            [rt2 getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
            unsigned bad = 0;
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
               // uv.y = 1 - (y+.5)/64 (pos.y up), so texel row = 3 - y/16; uv.x = (x+.5)/64 -> texel col x/16
               int tcol = x / 16, trow = 3 - y / 16;
               uint8_t *want = tx + (trow * 4 + tcol) * 4, *p = px + (y * 64 + x) * 4;   // want is RGBA, p is BGRA
               if (p[2] != want[0] || p[1] != want[1] || p[0] != want[2] || p[3] != 255) { if (bad++ < 3) printf("    (%d,%d) got %u,%u,%u want %u,%u,%u\n", x, y, p[2], p[1], p[0], want[0], want[1], want[2]); }
            }
            CHECK(bad == 0, "textured quad: %u of 4096 pixels wrong", bad);
            printf("  %u of 4096 pixels correct\n", 4096 - bad);
         } else { g_fail++; printf("  setup failed (pso=%d vb=%d t=%d smp=%d rt=%d)\n", pso != nil, vb != nil, t != nil, smp != nil, rt2 != nil); }
      }
      // ---- P6: the same quad with a constexpr (inline) sampler ----
      printf("== P6 textured quad with an inline sampler\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex_inline"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         static const float quad[6 * 8] = {
            -1, -1, 0, 1, 1,1,1,1,   1, -1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1,
             1, -1, 0, 1, 1,1,1,1,   1,  1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1 };
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         id rt3 = tex2d(MTLPixelFormatBGRA8Unorm, 64, 64, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         if (pso && vb && t && rt3) {
            uint8_t tx[4 * 4 * 4];
            for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) { uint8_t *p = tx + (y * 4 + x) * 4; p[0] = x * 80; p[1] = y * 80; p[2] = ((x + y) & 1) ? 255 : 0; p[3] = 255; }
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:tx bytesPerRow:16];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt3;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setFragmentTexture:t atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            CHECK(run(cb, "inline-sampler quad"), "render pass did not complete");
            uint8_t px[64 * 64 * 4];
            [rt3 getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
            unsigned bad = 0;
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
               int tcol = x / 16, trow = 3 - y / 16;
               uint8_t *want = tx + (trow * 4 + tcol) * 4, *p = px + (y * 64 + x) * 4;
               if (p[2] != want[0] || p[1] != want[1] || p[0] != want[2] || p[3] != 255) { if (bad++ < 3) printf("    (%d,%d) got %u,%u,%u want %u,%u,%u\n", x, y, p[2], p[1], p[0], want[0], want[1], want[2]); }
            }
            CHECK(bad == 0, "inline-sampler quad: %u of 4096 pixels wrong", bad);
            printf("  %u of 4096 pixels correct\n", 4096 - bad);
         } else { g_fail++; printf("  setup failed\n"); }
      }
      // ---- P7: linear filter, level(0), clamp, constant-buffer offset, into RGBA32Float (compared with a CPU bilinear) ----
      printf("== P7 linear sample + constant buffer offset, RGBA32Float target\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex_linear"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         static const float quad[6 * 8] = {
            -1, -1, 0, 1, 1,1,1,1,   1, -1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1,
             1, -1, 0, 1, 1,1,1,1,   1,  1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1 };
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         float off[4] = { 0.3f, -0.2f, 0, 0 };
         id ub = [g_dev newBufferWithBytes:off length:16 options:0];
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
         sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
         id smp = [g_dev newSamplerStateWithDescriptor:sd];
         id rt4 = tex2d(MTLPixelFormatRGBA32Float, 32, 32, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         if (pso && vb && ub && t && smp && rt4) {
            uint8_t tx[4 * 4 * 4];
            for (int i = 0; i < 64; i++) tx[i] = (uint8_t)(i * 37 + 11);
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:tx bytesPerRow:16];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt4;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(9, 9, 9, 9);
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setFragmentBuffer:ub offset:0 atIndex:1];
            [e setFragmentTexture:t atIndex:0];
            [e setFragmentSamplerState:smp atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            CHECK(run(cb, "linear quad"), "render pass did not complete");
            float px[32 * 32 * 4];
            [rt4 getBytes:px bytesPerRow:32 * 16 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
            unsigned bad = 0;
            double worst = 0;
            for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
               double uvx = (x + 0.5) / 32.0 + off[0], uvy = 1.0 - (y + 0.5) / 32.0 + off[1];
               double ux = uvx * 4 - 0.5, uy = uvy * 4 - 0.5;
               int ix = (int)floor(ux), iy = (int)floor(uy);
               double fx = ux - ix, fy = uy - iy;
               for (int c = 0; c < 4; c++) {
                  double v = 0;
                  for (int dy = 0; dy < 2; dy++) for (int dx = 0; dx < 2; dx++) {
                     int cx = ix + dx < 0 ? 0 : ix + dx > 3 ? 3 : ix + dx, cy = iy + dy < 0 ? 0 : iy + dy > 3 ? 3 : iy + dy;
                     v += (dx ? fx : 1 - fx) * (dy ? fy : 1 - fy) * (tx[(cy * 4 + cx) * 4 + c] / 255.0);
                  }
                  double d = fabs(px[(y * 32 + x) * 4 + c] - v);
                  if (d > worst) worst = d;
                  if (d > 0.01) { if (bad++ < 3) printf("    (%d,%d,c%d) got %g want %g\n", x, y, c, px[(y * 32 + x) * 4 + c], v); }
               }
            }
            CHECK(bad == 0, "linear sample: %u of 4096 values off by more than 0.01 (worst %g)", bad, worst);
            printf("  %u of 4096 values within 0.01 of the CPU bilinear (worst error %g)\n", 4096 - bad, worst);
         } else { g_fail++; printf("  setup failed\n"); }
      }
      // ---- P8: texture at slot 3 ----
      printf("== P8 texture at slot 3, nearest, RGBA32Float target\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex3"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         static const float quad[6 * 8] = {
            -1, -1, 0, 1, 1,1,1,1,   1, -1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1,
             1, -1, 0, 1, 1,1,1,1,   1,  1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1 };
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
         id smp = [g_dev newSamplerStateWithDescriptor:sd];
         id rt5 = tex2d(MTLPixelFormatRGBA32Float, 32, 32, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         if (pso && vb && t && smp && rt5) {
            uint8_t tx[64];
            for (int i = 0; i < 64; i++) tx[i] = (uint8_t)(i * 37 + 11);
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:tx bytesPerRow:16];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt5;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(9, 9, 9, 9);
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setFragmentTexture:t atIndex:3];
            [e setFragmentSamplerState:smp atIndex:0];
            if (getenv("P8_SAMPLERS")) for (int i = 1; i < 4; i++) [e setFragmentSamplerState:smp atIndex:i];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            CHECK(run(cb, "slot-3 quad"), "render pass did not complete");
            float px[32 * 32 * 4];
            [rt5 getBytes:px bytesPerRow:32 * 16 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
            unsigned bad = 0;
            for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
               int tcol = x / 8, trow = 3 - y / 8;
               for (int c = 0; c < 4; c++) if (fabsf(px[(y * 32 + x) * 4 + c] - tx[(trow * 4 + tcol) * 4 + c] / 255.0f) > 1e-3f) bad++;
            }
            CHECK(bad == 0, "slot 3: %u of 4096 values wrong", bad);
            printf("  %u of 4096 values correct\n", 4096 - bad);
         } else { g_fail++; printf("  setup failed (pso=%d)\n", pso != nil); }
      }
      // ---- P9: depth test (Depth32Float, compare Less): the nearer triangle drawn FIRST must win over the farther one drawn second ----
      printf("== P9 depth/stencil state: near red triangle then far green triangle, depth Less\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_color"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
         dd.depthCompareFunction = MTLCompareFunctionLess;
         dd.depthWriteEnabled = YES;
         id dss = [g_dev newDepthStencilStateWithDescriptor:dd];
         static const float near_[3 * 8] = { -1, -1, 0.25f, 1, 1, 0, 0, 1,   3, -1, 0.25f, 1, 1, 0, 0, 1,   -1, 3, 0.25f, 1, 1, 0, 0, 1 };
         static const float far_[3 * 8] = { -1, -1, 0.75f, 1, 0, 1, 0, 1,   3, -1, 0.75f, 1, 0, 1, 0, 1,   -1, 3, 0.75f, 1, 0, 1, 0, 1 };
         id vb1 = [g_dev newBufferWithBytes:near_ length:sizeof(near_) options:0], vb2 = [g_dev newBufferWithBytes:far_ length:sizeof(far_) options:0];
         id rt6 = tex2d(MTLPixelFormatBGRA8Unorm, 32, 32, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         id dt = tex2d(MTLPixelFormatDepth32Float, 32, 32, MTLTextureUsageRenderTarget);
         if (pso && dss && vb1 && vb2 && rt6 && dt) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt6;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.depthAttachment.texture = dt;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.clearDepth = 1.0;
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setDepthStencilState:dss];
            [e setVertexBuffer:vb1 offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e setVertexBuffer:vb2 offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            CHECK(run(cb, "depth test"), "render pass did not complete");
            uint8_t px[32 * 32 * 4];
            [rt6 getBytes:px bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
            unsigned red = 0, green = 0;
            for (int i = 0; i < 32 * 32; i++) { uint8_t *p = px + i * 4; if (p[2] > 200 && p[1] < 50) red++; else if (p[1] > 200 && p[2] < 50) green++; }
            CHECK(red == 1024 && green == 0, "depth test: %u red, %u green pixels (want 1024 red)", red, green);
            printf("  %u red (near), %u green (far) of 1024\n", red, green);
         } else { g_fail++; printf("  setup failed (pso=%d dss=%d dt=%d)\n", pso != nil, dss != nil, dt != nil); }
      }
      printf("== result: %d checks passed, %d failed\n", g_pass, g_fail);
      return g_fail ? 1 : 0;
   }
}
