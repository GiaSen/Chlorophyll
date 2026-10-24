// SPDX-License-Identifier: MIT
// Indexed-quad probe: does an indexed quad come out whole? Control Center's composites drew only one of a quad's two
// triangles correctly (indices 0 1 3 3 2 0, CoreAnimation's vertex layout, buffers at large offsets inside one ring buffer).
//   bgmtl_quad_probe QUAD.metallib
// Each case clears a 64x64 BGRA8 target to black, draws one full-target quad (vertices TL TR BL BR) and reads one pixel inside
// each triangle: the upper-right triangle (v0 v1 v3) and the lower-left one (v3 v2 v0). The colour attribute is white with a
// different alpha per vertex, a1 = (u, v) of the corner, so the fragment's output says which vertex data each triangle got.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

extern id bgmtl_create_device(void);
static id g_dev, g_queue, g_pso[2];
static int g_fail;

struct Vtx { float pos[4]; float a1[2]; float a2[2]; uint16_t col[4]; uint8_t pad[8]; };   // stride 48, as CoreAnimation
_Static_assert(sizeof(struct Vtx) == 48, "stride");

static uint16_t
half1(float f)
{
   __fp16 h = (__fp16)f;
   uint16_t u;
   memcpy(&u, &h, 2);
   return u;
}

static void
put(struct Vtx *v, float x, float y, float u, float w, float a)
{
   memset(v, 0, sizeof(*v));
   v->pos[0] = x; v->pos[1] = y; v->pos[3] = 1;
   v->a1[0] = u; v->a1[1] = w;
   v->a2[0] = u * 3; v->a2[1] = w * 36;
   v->col[0] = half1(1); v->col[1] = half1(a); v->col[2] = half1(1 - a); v->col[3] = half1(1);
}

// one case: index pattern, vertex/index offsets inside one 256 KiB ring buffer (or separate buffers), fragment mode
static float g_xf[4] = { 2.0f / 64, -2.0f / 64, -1, 1 };
static void
run_case(const char *name, const uint16_t idx[6], NSUInteger voff, NSUInteger ioff, BOOL shared, unsigned mode)
{
   id ring = [g_dev newBufferWithLength:262144 options:0];
   id ibuf = shared ? ring : [g_dev newBufferWithLength:4096 options:0];
   struct Vtx q[4];
   put(&q[0], 0, 0, 0, 0, 0.0f);       // TL
   put(&q[1], 64, 0, 1, 0, 0.25f);     // TR
   put(&q[2], 0, 64, 0, 1, 0.5f);      // BL
   put(&q[3], 64, 64, 1, 1, 0.75f);    // BR
   memcpy((uint8_t *)[ring contents] + voff, q, sizeof(q));
   memcpy((uint8_t *)[ibuf contents] + ioff, idx, 12);
   float xf[4] = { g_xf[0], g_xf[1], g_xf[2], g_xf[3] };      // pixels -> NDC, y down
   unsigned m = mode;

   MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
   td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
   td.storageMode = MTLStorageModeShared;
   id rt = [g_dev newTextureWithDescriptor:td];
   MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
   rp.colorAttachments[0].texture = rt;
   rp.colorAttachments[0].loadAction = MTLLoadActionClear;
   rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
   rp.colorAttachments[0].storeAction = MTLStoreActionStore;
   id cb = [g_queue commandBuffer];
   id e = [cb renderCommandEncoderWithDescriptor:rp];
   [e setRenderPipelineState:g_pso[0]];
   [e setVertexBuffer:ring offset:voff atIndex:1];
   [e setVertexBytes:xf length:sizeof(xf) atIndex:2];
   [e setFragmentBytes:&m length:sizeof(m) atIndex:0];
   [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ibuf indexBufferOffset:ioff];
   [e endEncoding];
   [cb commit];
   [cb waitUntilCompleted];
   uint8_t px[64 * 64 * 4];
   [rt getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
   const uint8_t *ur = px + (12 * 64 + 52) * 4, *ll = px + (52 * 64 + 12) * 4;     // BGRA
   BOOL ok_ur = ur[2] || ur[1] || ur[0], ok_ll = ll[2] || ll[1] || ll[0];
   printf("%-40s status %ld  upper-right rgb %3u %3u %3u   lower-left rgb %3u %3u %3u  %s\n", name, (long)[cb status],
          ur[2], ur[1], ur[0], ll[2], ll[1], ll[0], ok_ur && ok_ll ? "both drawn" : "MISSING TRIANGLE");
   if (!(ok_ur && ok_ll)) g_fail++;
}

// CoreAnimation's downsample pass exactly: 101x67 colour 0 (cleared white) plus colour 1 (load DontCare, write mask 0), its
// four vertices, matrix and indices 0 1 2 2 3 0. The first triangle (0 1 2) is the upper-right half.
static void
run_mrt(void)
{
   id ring = [g_dev newBufferWithLength:262144 options:0];
   struct Vtx q[4];
   put(&q[0], 7, 24, 0, 0, 0.0f); put(&q[1], 106, 24, 1, 0, 0.25f); put(&q[2], 106, 89, 1, 1, 0.5f); put(&q[3], 7, 89, 0, 1, 0.75f);
   memcpy((uint8_t *)[ring contents] + 14224, q, sizeof(q));
   static const uint16_t idx[6] = { 0, 1, 2, 2, 3, 0 };
   memcpy((uint8_t *)[ring contents] + 15952, idx, 12);
   float xf[4] = { 0.019802f, -0.0298507f, -1.11881f, 1.68657f };
   unsigned m = 0;
   for (int att = 1; att <= 2; att++) {
      MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:101 height:67 mipmapped:NO];
      td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      td.storageMode = MTLStorageModeShared;
      id rt0 = [g_dev newTextureWithDescriptor:td], rt1 = [g_dev newTextureWithDescriptor:td];
      MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
      rp.colorAttachments[0].texture = rt0;
      rp.colorAttachments[0].loadAction = MTLLoadActionClear;
      rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
      rp.colorAttachments[0].storeAction = MTLStoreActionStore;
      if (att == 2) {
         rp.colorAttachments[1].texture = rt1;
         rp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
         rp.colorAttachments[1].storeAction = MTLStoreActionStore;
      }
      id cb = [g_queue commandBuffer];
      id e = [cb renderCommandEncoderWithDescriptor:rp];
      [e setRenderPipelineState:g_pso[att - 1]];
      [e setViewport:(MTLViewport){ 0, 0, 101, 67, 0, 1 }];
      [e setScissorRect:(MTLScissorRect){ 0, 0, 101, 67 }];
      [e setVertexBuffer:ring offset:14224 atIndex:1];
      [e setVertexBytes:xf length:sizeof(xf) atIndex:2];
      [e setFragmentBytes:&m length:sizeof(m) atIndex:0];
      [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ring indexBufferOffset:15952];
      [e endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      uint8_t px[101 * 67 * 4];
      [rt0 getBytes:px bytesPerRow:101 * 4 fromRegion:MTLRegionMake2D(0, 0, 101, 67) mipmapLevel:0];
      const uint8_t *ur = px + (15 * 101 + 80) * 4, *ll = px + (55 * 101 + 20) * 4;
      BOOL white_ur = ur[0] == 255 && ur[1] == 255 && ur[2] == 255, white_ll = ll[0] == 255 && ll[1] == 255 && ll[2] == 255;
      printf("%-40s status %ld  upper-right rgb %3u %3u %3u   lower-left rgb %3u %3u %3u  %s\n",
             att == 2 ? "CA downsample pass, 2 attachments" : "CA downsample pass, 1 attachment", (long)[cb status],
             ur[2], ur[1], ur[0], ll[2], ll[1], ll[0], (white_ur || white_ll) ? "MISSING TRIANGLE" : "both drawn");
      if (white_ur || white_ll) g_fail++;
   }
}

// CoreAnimation's ring buffer: the SAME buffer and offsets rewritten every frame with different geometry. Frame k draws a quad
// whose upper-left corner moves; if the GPU keeps last frame's vertex or index lines cached, part of the new quad uses stale data.
static void
run_reuse(void)
{
   id ring = [g_dev newBufferWithLength:262144 options:0];
   static const uint16_t idx0[6] = { 0, 1, 2, 2, 3, 0 }, idx1[6] = { 0, 1, 3, 3, 2, 0 };
   int bad = 0;
   for (int k = 0; k < 8; k++) {
      struct Vtx q[4];
      float o = (k & 1) ? 16 : 0;      // odd frames: a smaller quad (corner at 16,16): stale data would leave a different shape
      if (k & 2) {   // indices 0 1 3 3 2 0, vertices TL TR BL BR
         put(&q[0], o, o, 0, 0, 0); put(&q[1], 64, o, 1, 0, 0.25f); put(&q[2], o, 64, 0, 1, 0.5f); put(&q[3], 64, 64, 1, 1, 0.75f);
      } else {       // indices 0 1 2 2 3 0, vertices TL TR BR BL
         put(&q[0], o, o, 0, 0, 0); put(&q[1], 64, o, 1, 0, 0.25f); put(&q[2], 64, 64, 1, 1, 0.5f); put(&q[3], o, 64, 0, 1, 0.75f);
      }
      memcpy((uint8_t *)[ring contents] + 14224, q, sizeof(q));
      memcpy((uint8_t *)[ring contents] + 15952, (k & 2) ? idx1 : idx0, 12);
      float xf[4] = { 2.0f / 64, -2.0f / 64, -1, 1 };
      unsigned m = 0;
      MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
      td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      td.storageMode = MTLStorageModeShared;
      id rt = [g_dev newTextureWithDescriptor:td];
      MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
      rp.colorAttachments[0].texture = rt;
      rp.colorAttachments[0].loadAction = MTLLoadActionClear;
      rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
      rp.colorAttachments[0].storeAction = MTLStoreActionStore;
      id cb = [g_queue commandBuffer];
      id e = [cb renderCommandEncoderWithDescriptor:rp];
      [e setRenderPipelineState:g_pso[0]];
      [e setVertexBuffer:ring offset:14224 atIndex:1];
      [e setVertexBytes:xf length:sizeof(xf) atIndex:2];
      [e setFragmentBytes:&m length:sizeof(m) atIndex:0];
      [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ring indexBufferOffset:15952];
      [e endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      uint8_t px[64 * 64 * 4];
      [rt getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
      // inside the quad: upper-right (52,20) and lower-left (20,52) must be drawn; outside on odd frames: (4,4) must stay black
      const uint8_t *ur = px + (20 * 64 + 52) * 4, *ll = px + (52 * 64 + 20) * 4, *tl = px + (4 * 64 + 4) * 4;
      BOOL d_ur = ur[0] || ur[1] || ur[2], d_ll = ll[0] || ll[1] || ll[2], d_tl = tl[0] || tl[1] || tl[2];
      BOOL ok = d_ur && d_ll && ((k & 1) ? !d_tl : d_tl);
      printf("reuse frame %d (%s, corner %2.0f)  UR %s  LL %s  TL %s  %s\n", k, (k & 2) ? "0 1 3 3 2 0" : "0 1 2 2 3 0", o,
             d_ur ? "drawn" : "EMPTY", d_ll ? "drawn" : "EMPTY", d_tl ? "drawn" : "empty", ok ? "ok" : "WRONG");
      if (!ok) bad++;
   }
   if (bad) g_fail++;
}

// generateMipmapsForTexture: level 0 filled with one colour by the CPU, the chain generated by the blit encoder, level 2 read back
static void
run_mips(void)
{
   MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:128 height:96 mipmapped:YES];
   td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
   td.storageMode = MTLStorageModeShared;
   id t = [g_dev newTextureWithDescriptor:td];
   static uint32_t lvl0[128 * 96];
   for (int i = 0; i < 128 * 96; i++) lvl0[i] = 0xff40c0ffu;     // BGRA bytes ff c0 40 ff
   [t replaceRegion:MTLRegionMake2D(0, 0, 128, 96) mipmapLevel:0 withBytes:lvl0 bytesPerRow:128 * 4];
   id cb = [g_queue commandBuffer];
   id b = [cb blitCommandEncoder];
   [b generateMipmapsForTexture:t];
   [b endEncoding];
   [cb commit];
   [cb waitUntilCompleted];
   for (unsigned lv = 1; lv <= 3; lv++) {
      unsigned w = 128 >> lv, h = 96 >> lv;
      uint8_t px[64 * 48 * 4];
      [t getBytes:px bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:lv];
      const uint8_t *ur = px + ((h / 4) * w + 3 * w / 4) * 4, *ll = px + ((3 * h / 4) * w + w / 4) * 4;
      BOOL ok = ur[0] == 0xff && ur[2] == 0x40 && ll[0] == 0xff && ll[2] == 0x40;
      printf("mipmaps level %u (%ux%u): upper-right bgr %3u %3u %3u   lower-left bgr %3u %3u %3u  %s\n", lv, w, h,
             ur[0], ur[1], ur[2], ll[0], ll[1], ll[2], ok ? "ok" : "WRONG");
      if (!ok) g_fail++;
   }
}

int
main(int argc, char **argv)
{
   @autoreleasepool {
      if (argc < 2) { printf("usage: bgmtl_quad_probe quad.metallib\n"); return 2; }
      g_dev = bgmtl_create_device();
      g_queue = [g_dev newCommandQueue];
      NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
      dispatch_data_t dd = d ? dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT) : NULL;
      NSError *err = nil;
      id lib = dd ? [g_dev newLibraryWithData:dd error:&err] : nil;
      if (!g_dev || !lib) { printf("no device or library: %s\n", err ? [[err localizedDescription] UTF8String] : "?"); return 3; }

      MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
      vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 1;
      vd.attributes[1].format = MTLVertexFormatFloat2; vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 1;
      vd.attributes[2].format = MTLVertexFormatFloat2; vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 1;
      vd.attributes[3].format = MTLVertexFormatHalf4;  vd.attributes[3].offset = 32; vd.attributes[3].bufferIndex = 1;
      vd.layouts[1].stride = 48;
      MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
      pd.vertexFunction = [lib newFunctionWithName:@"quad_vs"];
      pd.fragmentFunction = [lib newFunctionWithName:@"quad_fs"];
      pd.vertexDescriptor = vd;
      pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      g_pso[0] = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
      if (!g_pso[0]) { printf("pipeline: %s\n", err ? [[err localizedDescription] UTF8String] : "nil"); return 4; }
      pd.colorAttachments[1].pixelFormat = MTLPixelFormatBGRA8Unorm;
      pd.colorAttachments[1].writeMask = MTLColorWriteMaskNone;
      g_pso[1] = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
      if (!g_pso[1]) { printf("MRT pipeline: %s\n", err ? [[err localizedDescription] UTF8String] : "nil"); return 4; }

      static const uint16_t ca[6] = { 0, 1, 3, 3, 2, 0 }, alt[6] = { 0, 1, 2, 2, 1, 3 }, rev[6] = { 3, 2, 0, 0, 1, 3 };
      run_case("0 1 3 3 2 0, offsets 0, separate ib", ca, 0, 0, NO, 0);
      run_case("0 1 3 3 2 0, CA offsets, shared ring", ca, 13680, 13888, YES, 0);
      run_case("3 2 0 0 1 3 (halves swapped), CA offsets", rev, 13680, 13888, YES, 0);
      run_case("0 1 2 2 1 3, CA offsets", alt, 13680, 13888, YES, 0);
      run_case("0 1 3 3 2 0, CA offsets, a1 as colour", ca, 13680, 13888, YES, 1);
      run_case("0 1 3 3 2 0, CA offsets, a2 as colour", ca, 13680, 13888, YES, 2);
      run_case("0 1 3 3 2 0, vertex off 13680, ib off 6", ca, 13680, 6, NO, 0);
      // [[flat]]: the upper-right triangle (0 1 3) must show v0's colour (alpha 0: rgb 255 0 255), the lower-left (3 2 0) v3's
      // (alpha 0.75: rgb 255 191 64). The last vertex instead (OpenGL's rule) swaps them.
      run_case("0 1 3 3 2 0, [[flat]] colour", ca, 13680, 13888, YES, 3);
      // Control Center's blur passes: the quad overhangs the target (CoreAnimation sizes it for a larger area), so part of each
      // triangle is outside the viewport and gets clipped
      static const uint16_t blur[6] = { 0, 1, 3, 3, 2, 0 };
      g_xf[0] = 2.0f / 56; g_xf[1] = -2.0f / 56; g_xf[2] = -1.05f; g_xf[3] = 1.05f;     // ~14% past the right and bottom edges
      run_case("overhang right/bottom 14%", blur, 13680, 13888, YES, 0);
      g_xf[0] = 2.0f / 32; g_xf[1] = -2.0f / 32; g_xf[2] = -1.5f; g_xf[3] = 1.5f;       // far past all edges
      run_case("overhang everywhere (4x)", blur, 13680, 13888, YES, 0);
      g_xf[0] = 2.0f / 64 * 1.04f; g_xf[1] = -2.0f / 64 * 1.06f; g_xf[2] = -1.1f; g_xf[3] = 1.17f;   // CA-like: shifted up/left
      run_case("CA-like shift and scale", blur, 13680, 13888, YES, 0);
      run_mrt();
      run_reuse();
      run_mips();
      printf("%s\n", g_fail ? "SOME QUADS LOST A TRIANGLE" : "all quads whole");
   }
   return g_fail ? 1 : 0;
}
