// SPDX-License-Identifier: MIT
// Spike 3: CoreAnimation's own fragment shaders (iOS 18.7.8 QuartzCore default.metallib, AIR container slice) through BGMTLDevice in a
// test process, differential against softpipe: the same process is run twice (RWA_SOFTWARE=1, and on the Adreno), each run draws every
// fragment function of the library once over a 32x32 BGRA8 target with a generated vertex stage and deterministic inputs, and writes one
// line per function. tools/ca-compare.py diffs the two files.
//   bgmtl_ca_probe QUARTZCORE.mtlb OUT.tsv [--safe LIST] [--only NAME]
//     --safe LIST  draw only the functions named in LIST (one per line): the GPU run is limited to the ones softpipe finished quickly
// Nothing is registered. A function that cannot be built or drawn is a line saying why, not an abort.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "air_metal.h"

extern id bgmtl_create_device(void);
extern void bgmtl_render_info(id pipeline, unsigned *vb, unsigned *fb, unsigned *ft, unsigned *fs);
extern struct rwa_device *bgmtl_rwa(id device);

static double
now_ms(void)
{
   static mach_timebase_info_data_t tb;
   if (!tb.denom) mach_timebase_info(&tb);
   return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static id g_dev, g_queue;
#define W 32
static BOOL g_float;   /* BGCA_FLOAT=1: an RGBA32Float target, and the first pixel is printed as floats */

static NSString *
hexof(const uint8_t *p, size_t n)
{
   NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
   for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", p[i]];
   return s;
}

static void
fill_pattern(void *dst, size_t bytes, int seed)
{
   // finite, small floats: ((w*13 + seed) % 29 - 14) / 4, as 32-bit words
   float *f = dst;
   for (size_t w = 0; w < bytes / 4; w++) f[w] = (float)(((int)((w * 13 + seed) % 29)) - 14) / 4.0f;
}

int
main(int argc, char **argv)
{
   @autoreleasepool {
      if (argc < 3) { printf("usage: bgmtl_ca_probe lib.mtlb out.tsv [--safe list] [--only name]\n"); return 2; }
      NSSet *safe = nil;
      const char *only = NULL;
      for (int i = 3; i < argc; i++) {
         if (!strcmp(argv[i], "--safe") && i + 1 < argc) {
            NSString *t = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[++i]] encoding:NSUTF8StringEncoding error:nil];
            safe = [NSSet setWithArray:[t componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
         } else if (!strcmp(argv[i], "--only") && i + 1 < argc) only = argv[++i];
      }
      g_float = getenv("BGCA_FLOAT") != NULL;
      g_dev = bgmtl_create_device();
      g_queue = [g_dev newCommandQueue];
      NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
      dispatch_data_t dd = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
      NSError *e = nil;
      id lib = [g_dev newLibraryWithData:dd error:&e];
      if (!lib) { printf("library: %s\n", e ? [[e localizedDescription] UTF8String] : "?"); return 3; }
      NSArray *names = [[lib functionNames] sortedArrayUsingSelector:@selector(compare:)];
      FILE *out = fopen(argv[2], only ? "a" : "w");   /* --only appends: ca-sweep.sh runs one function per process, so that an abort is one line, not the run */
      unsigned total = 0, built = 0, drawn = 0, skipped = 0;
      id rt = nil;
      {
         MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:g_float ? MTLPixelFormatRGBA32Float : MTLPixelFormatBGRA8Unorm width:W height:W mipmapped:NO];
         td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
         rt = [g_dev newTextureWithDescriptor:td];
      }
      MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
      sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
      sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
      id smp = [g_dev newSamplerStateWithDescriptor:sd];
      for (NSString *name in names) {
         id fn = [lib newFunctionWithName:name];
         if ([fn functionType] != MTLFunctionTypeFragment) continue;
         if (only && strcmp(only, [name UTF8String])) continue;
         total++;
         const char *cn = [name UTF8String];
         if (safe && ![safe containsObject:name]) { fprintf(out, "%s\tskipped\t\t0\n", cn); skipped++; continue; }
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.fragmentFunction = fn;
         pd.colorAttachments[0].pixelFormat = g_float ? MTLPixelFormatRGBA32Float : MTLPixelFormatBGRA8Unorm;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         if (!pso) {
            NSString *why = err ? [[err localizedDescription] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"nil";
            fprintf(out, "%s\trefused\t%s\t0\n", cn, [why UTF8String]);
            continue;
         }
         built++;
         unsigned vb, fb, ft, fs;
         bgmtl_render_info(pso, &vb, &fb, &ft, &fs);
         // textures as the module declares them
         NSData *bc = ((NSData * (*)(id, SEL))objc_msgSend)(fn, sel_getUid("bitcodeData"));
         struct rwa_texture_decl decls[16];
         unsigned ndecl = 0;
         char why[512] = { 0 };
         id texs[16] = { nil };
         BOOL ok = YES;
         NSString *skipwhy = nil;
         if (ft) {
            if (rwa_module_textures(bgmtl_rwa(g_dev), bc.bytes, bc.length, cn, decls, 16, &ndecl, why, sizeof(why)) != 0) {
               ok = NO; skipwhy = [NSString stringWithFormat:@"textures: %s", why];
            }
         }
         for (unsigned i = 0; ok && i < ndecl; i++) {
            struct rwa_texture_decl *t = &decls[i];
            if (t->index >= 16) { ok = NO; skipwhy = @"texture slot past 16"; break; }
            MTLPixelFormat pf = t->element == RWA_ELEMENT_INT ? MTLPixelFormatRGBA32Sint : t->element == RWA_ELEMENT_UINT ? MTLPixelFormatRGBA32Uint : MTLPixelFormatRGBA8Unorm;
            unsigned bpt = (pf == MTLPixelFormatRGBA8Unorm) ? 4 : 16;
            MTLTextureDescriptor *td = [[MTLTextureDescriptor alloc] init];
            td.pixelFormat = pf;
            td.usage = MTLTextureUsageShaderRead | (t->usage & MTLTextureUsageShaderWrite);
            unsigned slices = 1, depth = 1;
            switch (t->type_known ? t->type : MTLTextureType2D) {
            case MTLTextureType2D: td.textureType = MTLTextureType2D; td.width = 8; td.height = 8; break;
            case MTLTextureType2DArray: td.textureType = MTLTextureType2DArray; td.width = 8; td.height = 8; td.arrayLength = 2; slices = 2; break;
            case MTLTextureTypeCube: td.textureType = MTLTextureTypeCube; td.width = 8; td.height = 8; slices = 6; break;
            case MTLTextureType3D: td.textureType = MTLTextureType3D; td.width = 8; td.height = 8; td.depth = 4; depth = 4; break;
            default: ok = NO; skipwhy = [NSString stringWithFormat:@"texture type %u", t->type]; break;
            }
            if (!ok) break;
            id tex = [g_dev newTextureWithDescriptor:td];
            if (!tex) { ok = NO; skipwhy = @"texture creation refused"; break; }
            uint8_t *px = malloc(8 * 8 * depth * bpt);
            fill_pattern(px, 8 * 8 * depth * bpt, 3 + t->index);
            if (pf == MTLPixelFormatRGBA8Unorm) for (unsigned k = 0; k < 8 * 8 * depth * bpt; k++) px[k] = (uint8_t)(px[k] * 3 + k);
            else { uint32_t *u = (uint32_t *)px; for (unsigned k = 0; k < 8 * 8 * depth * 4; k++) u[k] = (uint32_t)(k % 7) + 1; }
            for (unsigned sl = 0; sl < slices; sl++)
               [tex replaceRegion:MTLRegionMake3D(0, 0, 0, 8, 8, depth) mipmapLevel:0 slice:sl withBytes:px bytesPerRow:8 * bpt bytesPerImage:8 * 8 * bpt];
            free(px);
            texs[t->index] = tex;
         }
         if (!ok) { fprintf(out, "%s\tskipped\t%s\t0\n", cn, [skipwhy UTF8String]); skipped++; continue; }
         MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
         rp.colorAttachments[0].texture = rt;
         rp.colorAttachments[0].loadAction = MTLLoadActionClear;
         rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
         id cb = [g_queue commandBuffer];
         id enc = [cb renderCommandEncoderWithDescriptor:rp];
         [enc setRenderPipelineState:pso];
         for (unsigned i = 0; i < fb; i++) {
            id b = [[g_dev newBufferWithLength:262144 options:0] autorelease];
            fill_pattern([b contents], 262144, 5 + i);
            [enc setFragmentBuffer:b offset:0 atIndex:i];
         }
         for (unsigned i = 0; i < 16; i++) if (texs[i]) [enc setFragmentTexture:texs[i] atIndex:i];
         /* softpipe pairs a sampler with the texture of the same index, so the one sampler is bound at every index up to the highest texture
          * (the Adreno does not care): without it a shader with texture(3), sampler(0) samples nothing on softpipe */
         unsigned nsmp = fs;
         for (unsigned i = 0; i < 16; i++) if (texs[i] && i + 1 > nsmp) nsmp = i + 1;
         for (unsigned i = 0; i < nsmp; i++) [enc setFragmentSamplerState:smp atIndex:i];
         [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
         [enc endEncoding];
         double t0 = now_ms();
         [cb commit];
         double ms = now_ms() - t0;
         if ([cb status] != 4) {
            NSString *why2 = [cb error] ? [[[cb error] localizedDescription] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"?";
            fprintf(out, "%s\tfailed\t%s\t%.1f\n", cn, [why2 UTF8String], ms);
            continue;
         }
         if (g_float) {
            float fp[W * W * 4];
            [rt getBytes:fp bytesPerRow:W * 16 fromRegion:MTLRegionMake2D(0, 0, W, W) mipmapLevel:0];
            fprintf(out, "%s\tdrawn\t%.6g,%.6g,%.6g,%.6g\t%.1f\n", cn, fp[0], fp[1], fp[2], fp[3], ms);
            fflush(out);
            continue;
         }
         uint8_t px[W * W * 4];
         [rt getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, W) mipmapLevel:0];
         fprintf(out, "%s\tdrawn\t%s\t%.1f\n", cn, [hexof(px, sizeof(px)) UTF8String], ms);
         drawn++;
         fflush(out);
         for (unsigned i = 0; i < 16; i++) [texs[i] release];
      }
      fclose(out);
      printf("fragment functions: %u, pipelines built: %u, drawn: %u, skipped: %u\n", total, built, drawn, skipped);
      return 0;
   }
}
