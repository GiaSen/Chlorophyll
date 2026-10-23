// SPDX-License-Identifier: MIT
// Spike 2: BGMTLDevice probe. A standalone test process (never a daemon, never the render server):
//   creates our `_MTLDevice` subclass directly, makes a queue, buffers and compute pipelines from an AIR function compiled on the Mac,
//   runs small kernels and a blit on the Adreno 630 through Mesa freedreno and our msm client, and checks every result.
// The device is NOT registered with MTLAddDevice and no IOKit service gets MetalPluginName. At the very end the probe asks Metal
// for its device list (MTLCopyAllDevices, in this process only) to show that ours is not in it.
//   bgmtl_probe [FILE.metallib]       default: ./bg_kernels.metallib
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern id bgmtl_create_device(void);

static int g_pass, g_fail;
#define CHECK(cond, ...) do { if (cond) { g_pass++; } else { g_fail++; printf("  FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static double
now_ms(void)
{
   static mach_timebase_info_data_t tb;
   if (!tb.denom) mach_timebase_info(&tb);
   return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

// A function object for the fallback path: just what the device reads out of Metal's own _MTLFunction (-name, -bitcodeData).
@interface BGFuncShim : NSObject
@property(copy) NSString *name;
@property(retain) NSData *bitcodeData;
@end
@implementation BGFuncShim
@end

static uint64_t rd64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return p[0] | p[1] << 8; }

// The MTLB container: header, function list of tagged fields, one LLVM module per function (same layout as the frontend's
// air_metallib.c, MIT, Copyright 2026 Darwin on redwood contributors). Returns the bitcode of function `want`.
static NSData *
metallib_function(NSData *lib, const char *want)
{
   const uint8_t *b = lib.bytes;
   if (lib.length < 0x58 || memcmp(b, "MTLB", 4)) return nil;
   uint64_t funcs = rd64(b + 0x18), bc_off = rd64(b + 0x48), bc_len = rd64(b + 0x50);
   const uint8_t *p = b + funcs;
   uint32_t count = rd32(p);
   p += 4;
   for (uint32_t i = 0; i < count; i++) {
      uint32_t len = rd32(p);
      const uint8_t *q = p + 4, *end = p + len;
      char name[128] = { 0 };
      uint64_t off = 0, size = 0;
      while (q + 6 <= end && memcmp(q, "ENDT", 4)) {
         uint16_t vlen = rd16(q + 4);
         const uint8_t *v = q + 6;
         if (!memcmp(q, "NAME", 4)) memcpy(name, v, vlen < 127 ? vlen : 127);
         else if (!memcmp(q, "OFFT", 4) && vlen >= 24) off = rd64(v + 16);
         else if (!memcmp(q, "MDSZ", 4) && vlen >= 8) size = rd64(v);
         q = v + vlen;
      }
      if (!strcmp(name, want) && off + size <= bc_len) return [NSData dataWithBytes:b + bc_off + off length:size];
      p = end;
   }
   return nil;
}

static id g_dev, g_queue, g_lib;
static NSData *g_libdata;
static BOOL g_via_metal_library;

static id
make_pipeline(const char *fn)
{
   NSError *err = nil;
   id function = nil;
   if (g_lib) {
      function = [g_lib newFunctionWithName:[NSString stringWithUTF8String:fn]];
      if (function && ![function respondsToSelector:sel_getUid("bitcodeData")]) function = nil;
      if (function && ![(NSData *)((id (*)(id, SEL))objc_msgSend)(function, sel_getUid("bitcodeData")) length]) function = nil;
   }
   if (function) g_via_metal_library = YES;
   if (!function) {
      NSData *bc = metallib_function(g_libdata, fn);
      if (!bc) { printf("  no function %s in the metallib\n", fn); return nil; }
      BGFuncShim *s = [[BGFuncShim alloc] init];
      s.name = [NSString stringWithUTF8String:fn];
      s.bitcodeData = bc;
      function = s;
      printf("  (%s: Metal's own function object was not usable; using the container's bitcode through a shim)\n", fn);
   } else {
      printf("  (%s: function from Metal's own _MTLLibrary, bitcodeData %lu bytes)\n", fn,
             (unsigned long)[(NSData *)((id (*)(id, SEL))objc_msgSend)(function, sel_getUid("bitcodeData")) length]);
   }
   id p = [g_dev newComputePipelineStateWithFunction:function error:&err];
   if (!p) printf("  pipeline %s failed: %s\n", fn, err ? [[err localizedDescription] UTF8String] : "(no error)");
   return p;
}

static BOOL
run_cb(id cb, const char *what)
{
   double t0 = now_ms();
   [cb commit];
   [cb waitUntilCompleted];
   NSInteger st = [cb status];
   printf("  %s: status=%ld (4=completed) in %.2f ms%s%s\n", what, (long)st, now_ms() - t0, [cb error] ? " error=" : "",
          [cb error] ? [[[cb error] localizedDescription] UTF8String] : "");
   return st == 4;
}

int
main(int argc, char **argv)
{
   @autoreleasepool {
      const char *path = argc > 1 ? argv[1] : "bg_kernels.metallib";
      printf("== BGMTLDevice probe (iOS %s)\n", [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);
      g_libdata = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
      if (!g_libdata) { printf("cannot read %s\n", path); return 2; }

      g_dev = bgmtl_create_device();
      if (!g_dev) { printf("device creation failed\n"); return 3; }
      printf("device: %s  class=%s  super=%s  conformsToMTLDevice=%d MTLDeviceSPI=%d\n", [[g_dev name] UTF8String],
             class_getName([g_dev class]), class_getName(class_getSuperclass([g_dev class])),
             (int)[g_dev conformsToProtocol:objc_getProtocol("MTLDevice")], (int)[g_dev conformsToProtocol:objc_getProtocol("MTLDeviceSPI")]);

      g_queue = [g_dev newCommandQueue];
      printf("queue: %s\n", g_queue ? class_getName([g_queue class]) : "(nil)");
      if (!g_queue) return 4;

      // the library through Metal's own machinery (works only if _MTLDevice can make a library without a compiler)
      NSError *err = nil;
      dispatch_data_t dd = dispatch_data_create(g_libdata.bytes, g_libdata.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
      @try { g_lib = [g_dev newLibraryWithData:dd error:&err]; }
      @catch (NSException *e) { printf("newLibraryWithData raised %s: %s\n", [[e name] UTF8String], [[e reason] UTF8String]); }
      printf("library via Metal: %s%s\n", g_lib ? class_getName([g_lib class]) : "(nil)", err ? [[err localizedDescription] UTF8String] : "");

      // ---- T1: bg_add, 1024 floats, exact comparison ----
      printf("== T1 bg_add (compute, 4 buffers, setBytes)\n");
      {
         id pso = make_pipeline("bg_add");
         if (pso) {
            const unsigned n = 1024;
            id a = [g_dev newBufferWithLength:n * 4 options:0], b = [g_dev newBufferWithLength:n * 4 options:0],
               o = [g_dev newBufferWithLength:n * 4 options:0];
            CHECK(a && b && o, "buffers");
            float *fa = [a contents], *fb = [b contents], *fo = [o contents];
            for (unsigned i = 0; i < n; i++) { fa[i] = (float)i * 0.5f; fb[i] = (float)(n - i); fo[i] = -12345.0f; }
            id cb = [g_queue commandBuffer];
            id enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:a offset:0 atIndex:0]; [enc setBuffer:b offset:0 atIndex:1]; [enc setBuffer:o offset:0 atIndex:2];
            uint32_t nn = n;
            [enc setBytes:&nn length:4 atIndex:3];
            [enc dispatchThreadgroups:MTLSizeMake(n / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [enc endEncoding];
            CHECK(run_cb(cb, "bg_add"), "command buffer did not complete");
            unsigned bad = 0;
            for (unsigned i = 0; i < n; i++) if (fo[i] != fa[i] + 2.0f * fb[i]) { if (bad++ < 4) printf("    out[%u]=%g want %g\n", i, fo[i], fa[i] + 2.0f * fb[i]); }
            CHECK(bad == 0, "bg_add: %u of %u elements wrong", bad, n);
            printf("  bg_add: %u of %u elements correct\n", n - bad, n);
         }
      }

      // ---- T2: blit: GPU copy kernel + CPU blit encoder (copy, fill) ----
      printf("== T2 blit (GPU copy kernel; CPU blit encoder copy/fill on shared buffers)\n");
      {
         const unsigned n = 4096;
         id src = [g_dev newBufferWithLength:n * 4 options:0], dst = [g_dev newBufferWithLength:n * 4 options:0],
            dst2 = [g_dev newBufferWithLength:n * 4 options:0];
         uint32_t *s = [src contents], *d = [dst contents], *d2 = [dst2 contents];
         for (unsigned i = 0; i < n; i++) { s[i] = i * 2654435761u; d[i] = 0xdeadbeef; d2[i] = 0xdeadbeef; }
         id pso = make_pipeline("bg_copy");
         if (pso) {
            id cb = [g_queue commandBuffer];
            id enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:src offset:0 atIndex:0]; [enc setBuffer:dst offset:0 atIndex:1];
            uint32_t nn = n;
            [enc setBytes:&nn length:4 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
            [enc endEncoding];
            CHECK(run_cb(cb, "bg_copy"), "bg_copy did not complete");
            unsigned bad = 0;
            for (unsigned i = 0; i < n; i++) if (d[i] != s[i]) bad++;
            CHECK(bad == 0, "bg_copy: %u of %u wrong", bad, n);
            printf("  GPU copy: %u of %u words correct\n", n - bad, n);
         }
         id cb = [g_queue commandBuffer];
         id blit = [cb blitCommandEncoder];
         [blit copyFromBuffer:src sourceOffset:0 toBuffer:dst2 destinationOffset:0 size:n * 4];
         [blit fillBuffer:dst2 range:NSMakeRange(0, 64) value:0xAB];
         [blit endEncoding];
         CHECK(run_cb(cb, "blit"), "blit did not complete");
         unsigned bad = 0;
         for (unsigned i = 16; i < n; i++) if (d2[i] != s[i]) bad++;
         for (unsigned i = 0; i < 16; i++) if (d2[i] != 0xABABABABu) bad++;
         CHECK(bad == 0, "blit: %u wrong", bad);
         printf("  CPU blit (copy + fill): %u wrong\n", bad);
      }

      // ---- T3: per-threadgroup sum ----
      printf("== T3 bg_groupsum (threadgroup ids)\n");
      {
         id pso = make_pipeline("bg_groupsum");
         if (pso) {
            const unsigned groups = 32, per = 64;
            id in = [g_dev newBufferWithLength:groups * per * 4 options:0], out = [g_dev newBufferWithLength:groups * 4 options:0];
            uint32_t *pi = [in contents], *po = [out contents];
            for (unsigned i = 0; i < groups * per; i++) pi[i] = i % 17 + 1;
            for (unsigned i = 0; i < groups; i++) po[i] = 0xffffffffu;
            id cb = [g_queue commandBuffer];
            id enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:in offset:0 atIndex:0]; [enc setBuffer:out offset:0 atIndex:1];
            uint32_t pg = per;
            [enc setBytes:&pg length:4 atIndex:2];
            [enc dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
            [enc endEncoding];
            CHECK(run_cb(cb, "bg_groupsum"), "bg_groupsum did not complete");
            unsigned bad = 0;
            for (unsigned g = 0; g < groups; g++) {
               uint32_t want = 0;
               for (unsigned i = 0; i < per; i++) want += (g * per + i) % 17 + 1;
               if (po[g] != want) { if (bad++ < 3) printf("    out[%u]=%u want %u\n", g, po[g], want); }
            }
            CHECK(bad == 0, "bg_groupsum: %u of %u wrong", bad, groups);
            printf("  bg_groupsum: %u of %u groups correct\n", groups - bad, groups);
         }
      }

      // ---- T4: 64K elements, 20 submissions in a row (still small: one dispatch of 1024 groups each) ----
      printf("== T4 bg_add x20, 65536 elements\n");
      {
         id pso = make_pipeline("bg_add");
         if (pso) {
            const unsigned n = 65536;
            id a = [g_dev newBufferWithLength:n * 4 options:0], b = [g_dev newBufferWithLength:n * 4 options:0],
               o = [g_dev newBufferWithLength:n * 4 options:0];
            float *fa = [a contents], *fb = [b contents], *fo = [o contents];
            for (unsigned i = 0; i < n; i++) { fa[i] = (float)(i % 1000); fb[i] = (float)(i % 7); }
            unsigned total_bad = 0, done = 0;
            double t0 = now_ms();
            for (unsigned r = 0; r < 20; r++) {
               for (unsigned i = 0; i < n; i++) fo[i] = -1.0f;
               id cb = [g_queue commandBuffer];
               id enc = [cb computeCommandEncoder];
               [enc setComputePipelineState:pso];
               [enc setBuffer:a offset:0 atIndex:0]; [enc setBuffer:b offset:0 atIndex:1]; [enc setBuffer:o offset:0 atIndex:2];
               uint32_t nn = n;
               [enc setBytes:&nn length:4 atIndex:3];
               [enc dispatchThreadgroups:MTLSizeMake(n / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
               [enc endEncoding];
               [cb commit];
               if ([cb status] != 4) { printf("  round %u: status %ld\n", r, (long)[cb status]); break; }
               done++;
               for (unsigned i = 0; i < n; i++) if (fo[i] != fa[i] + 2.0f * fb[i]) total_bad++;
            }
            printf("  %u rounds completed, %u wrong elements in total, %.1f ms per round (incl. CPU fill and verify)\n", done, total_bad, (now_ms() - t0) / (done ? done : 1));
            CHECK(done == 20 && total_bad == 0, "T4: %u rounds, %u wrong", done, total_bad);
         }
      }
      // an unknown function must be refused with an error, not a crash
      {
         NSError *e = nil;
         BGFuncShim *s = [[BGFuncShim alloc] init];
         s.name = @"no_such"; s.bitcodeData = [NSData dataWithBytes:"garbage" length:7];
         id p = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(g_dev, sel_getUid("bgPipelineForFunction:descriptor:error:"), s, nil, &e);
         printf("  garbage bitcode: pipeline=%s error=%s\n", p ? "created (BUG)" : "refused", e ? [[e localizedDescription] UTF8String] : "(none)");
         CHECK(!p && e, "garbage bitcode must be refused with an NSError");
      }

      // ---- the device is not registered anywhere ----
      printf("== registration check (this process only)\n");
      {
         void *cad = dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
         if (cad) {
            NSArray *all = ((NSArray * (*)(void))cad)();
            BOOL leaked = NO;
            for (id d in all) if ([d isKindOfClass:objc_getClass("BGMTLDevice")]) leaked = YES;
            printf("  MTLCopyAllDevices: %lu device(s), BGMTLDevice among them: %s\n", (unsigned long)[all count], leaked ? "YES (BUG)" : "no");
            CHECK(!leaked, "BGMTLDevice leaked into Metal's device list");
         }
      }
      printf("== result: %d checks passed, %d failed, via Metal _MTLLibrary: %s\n", g_pass, g_fail, g_via_metal_library ? "yes" : "no (shim)");
      return g_fail ? 1 : 0;
   }
}
