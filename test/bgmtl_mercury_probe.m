// SPDX-License-Identifier: MIT
// Mercury's (iOS 18 stock wallpaper poster) pipelines through BGMTLDevice on the Adreno 630, in a test process. Draws the vertex+fragment pairs
// whose shaders have NO data-dependent loop (fluidity sdf and plain, pro24Main, post) once each into a 128x128 BGRA8 target and dumps PPMs.
// The pairs with loops whose bound comes from data (tori fragments: light counts and fract loops; shippou kernels: ray marching) are NOT run:
// a runaway loop is the one way to lose the GPU (one ring, no recovery).
//   bgmtl_mercury_probe MERCURY.metallib OUTDIR
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include "air_metal.h"

extern id bgmtl_create_device(void);
extern void bgmtl_render_info(id pipeline, unsigned *vb, unsigned *fb, unsigned *ft, unsigned *fs);
extern struct rwa_device *bgmtl_rwa(id device);

static void
fill_pattern(void *dst, size_t bytes, int seed)
{
   float *f = dst;
   for (size_t w = 0; w < bytes / 4; w++) f[w] = (float)(((int)((w * 13 + seed) % 29)) - 14) / 4.0f;
}

int
main(int argc, char **argv)
{
   @autoreleasepool {
      if (argc < 3) { printf("usage: bgmtl_mercury_probe lib out\n"); return 2; }
      id dev = bgmtl_create_device();
      id queue = [dev newCommandQueue];
      NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
      dispatch_data_t dd = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
      id lib = [dev newLibraryWithData:dd error:nil];
      if (!dev || !queue || !lib) { printf("setup failed\n"); return 3; }
      const char *pairs[][2] = { { "fluidity::vertexShader", "fluidity::fragmentShader" }, { "fluidity::sdfVertexShader", "fluidity::sdfFragmentShader" },
                                 { "pro24MainVertex", "pro24MainFragment" }, { "postVertex", "postFragment" } };
      MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
      sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
      sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
      id smp = [dev newSamplerStateWithDescriptor:sd];
      int ok = 0;
      for (unsigned p = 0; p < 4; p++) {
         const char *vn = pairs[p][0], *fn = pairs[p][1];
         id vf = [lib newFunctionWithName:[NSString stringWithUTF8String:vn]], ff = [lib newFunctionWithName:[NSString stringWithUTF8String:fn]];
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = vf; pd.fragmentFunction = ff;
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         pd.colorAttachments[1].pixelFormat = MTLPixelFormatBGRA8Unorm;   // fluidity writes [[color(1)]] too (sdf only that)
         int wantdepth = !strcmp(fn, "pro24MainFragment");
         if (wantdepth) pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
         NSError *err = nil;
         id pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
         if (!pso) { printf("%s + %s: pipeline refused: %s\n", vn, fn, err ? [[err localizedDescription] UTF8String] : "?"); continue; }
         unsigned vb, fb, ft, fs;
         bgmtl_render_info(pso, &vb, &fb, &ft, &fs);
         MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:128 height:128 mipmapped:NO];
         td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
         id rt = [dev newTextureWithDescriptor:td];
         id rt1 = [dev newTextureWithDescriptor:td];
         MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
         rp.colorAttachments[1].texture = rt1;
         rp.colorAttachments[1].loadAction = MTLLoadActionClear;
         rp.colorAttachments[1].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1);
         rp.colorAttachments[0].texture = rt;
         rp.colorAttachments[0].loadAction = MTLLoadActionClear;
         rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1);
         if (wantdepth) {
            MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:128 height:128 mipmapped:NO];
            dd.usage = MTLTextureUsageRenderTarget;
            rp.depthAttachment.texture = [dev newTextureWithDescriptor:dd];
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.clearDepth = 1.0;
         }
         id cb = [queue commandBuffer];
         id enc = [cb renderCommandEncoderWithDescriptor:rp];
         [enc setRenderPipelineState:pso];
         // vertex buffers: a screen quad (pos float2, uv float2) at 0 for the sdf stage, patterned uniforms elsewhere; identity at 1 when 64 bytes
         static const float quad[6 * 4] = { -1, -1, 0, 1,  1, -1, 1, 1,  -1, 1, 0, 0,  1, -1, 1, 1,  1, 1, 1, 0,  -1, 1, 0, 0 };
         for (unsigned i = 0; i < vb && i < 4; i++) {
            id b = [[dev newBufferWithLength:65536 options:0] autorelease];
            fill_pattern([b contents], 65536, 5 + i);
            if ((!strcmp(vn, "fluidity::sdfVertexShader") || !strcmp(vn, "fluidity::vertexShader") || !strcmp(vn, "postVertex")) && i == 0) memcpy([b contents], quad, sizeof(quad));
            if (!strcmp(vn, "fluidity::sdfVertexShader") && i == 1) { float id4[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 }; memcpy([b contents], id4, sizeof(id4)); }
            if (!strcmp(vn, "fluidity::sdfVertexShader") && i == 2) { memset([b contents], 0, 64); ((float *)[b contents])[1] = 1.0f; ((float *)[b contents])[0] = 0.5f; }
            [enc setVertexBuffer:b offset:0 atIndex:i];
         }
         for (unsigned i = 0; i < fb && i < 4; i++) {
            id b = [[dev newBufferWithLength:65536 options:0] autorelease];
            fill_pattern([b contents], 65536, 9 + i);
            [enc setFragmentBuffer:b offset:0 atIndex:i];
         }
         NSData *bc = ((NSData * (*)(id, SEL))objc_msgSend)(ff, sel_getUid("bitcodeData"));
         struct rwa_texture_decl decls[16];
         unsigned nd = 0;
         char why[256] = { 0 };
         if (ft) rwa_module_textures(bgmtl_rwa(dev), bc.bytes, bc.length, fn, decls, 16, &nd, why, sizeof(why));
         unsigned nsmp = fs;
         for (unsigned i = 0; i < nd; i++) {
            MTLTextureDescriptor *t2 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
            if (decls[i].type_known && decls[i].type == MTLTextureType3D) { t2.textureType = MTLTextureType3D; t2.depth = 4; }
            t2.usage = MTLTextureUsageShaderRead;
            id tex = [[dev newTextureWithDescriptor:t2] autorelease];
            uint8_t px[64 * 64 * 4];
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) { uint8_t *q = px + (y * 64 + x) * 4; q[0] = x * 4; q[1] = y * 4; q[2] = 128 + decls[i].index * 8; q[3] = 255; }
            if (t2.textureType == MTLTextureType3D) { for (int z = 0; z < 4; z++) [tex replaceRegion:(MTLRegion){{0, 0, (NSUInteger)z}, {64, 64, 1}} mipmapLevel:0 slice:0 withBytes:px bytesPerRow:256 bytesPerImage:0]; }
            else [tex replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:px bytesPerRow:256];
            [enc setFragmentTexture:tex atIndex:decls[i].index];
            if (decls[i].index + 1 > nsmp) nsmp = decls[i].index + 1;
         }
         for (unsigned i = 0; i < nsmp; i++) [enc setFragmentSamplerState:smp atIndex:i];
         [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
         [enc endEncoding];
         [cb commit];
         [cb waitUntilCompleted];
         uint8_t out[128 * 128 * 4];
         if (!strcmp(fn, "fluidity::sdfFragmentShader")) rt = rt1;   // this one writes only [[color(1)]]
         [rt getBytes:out bytesPerRow:512 fromRegion:MTLRegionMake2D(0, 0, 128, 128) mipmapLevel:0];
         unsigned changed = 0, distinct = 0;
         uint32_t first = 0;
         for (int i = 0; i < 128 * 128; i++) {
            uint32_t v; memcpy(&v, out + i * 4, 4);
            if (!(out[i*4] == 191 && out[i*4+1] == 128 && out[i*4+2] == 64 && out[i*4+3] == 255)) changed++;
            if (i == 0) first = v;
            if (v != first) distinct++;
         }
         printf("  pixel0 bgra=%02x%02x%02x%02x centre=%08x\n", out[0], out[1], out[2], out[3], *(uint32_t *)(out + (64*128+64)*4));
         printf("%s + %s: status %ld, vb=%u fb=%u tex=%u, %u of 16384 pixels differ from the clear colour, %u differ from pixel 0\n", vn, fn, (long)[cb status], vb, fb, ft, changed, distinct);
         char path[512];
         snprintf(path, sizeof(path), "%s/merc%u.ppm", argv[2], p);
         FILE *f = fopen(path, "wb");
         if (f) { fprintf(f, "P6\n128 128\n255\n"); for (int i = 0; i < 128 * 128; i++) { fputc(out[i * 4 + 2], f); fputc(out[i * 4 + 1], f); fputc(out[i * 4], f); } fclose(f); }
         if ([cb status] == 4) ok++;
      }
      printf("== %d of 4 pairs completed\n", ok);
      return ok != 4;
   }
}
