// SPDX-License-Identifier: MIT
// libbgair without Metal: AIR function of a .metallib -> Mesa (AIR frontend, ir3) -> compute on freedreno, results checked on the CPU.
// Layer-isolating companion of bgmtl_probe: if this passes and the probe does not, the fault is in the _MTLDevice layer.
// The same source builds for the Mac (RWA_SOFTWARE=1 runs softpipe, a reference for the expected numbers) and for the phone.
//   bgair_test FILE.metallib
// The MTLB container reader is the format of the frontend's air_metallib.c (MIT, Copyright 2026 Darwin on redwood contributors).
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "air_metal.h"

static int pass, fail;
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define CHECK(c, ...) do { if (c) pass++; else { fail++; printf("  FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static uint64_t rd64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return p[0] | p[1] << 8; }

static const uint8_t *
metallib_function(const uint8_t *b, size_t size, const char *want, size_t *out_size)
{
   if (size < 0x58 || memcmp(b, "MTLB", 4)) return NULL;
   uint64_t funcs = rd64(b + 0x18), bc_off = rd64(b + 0x48), bc_len = rd64(b + 0x50);
   const uint8_t *p = b + funcs;
   uint32_t count = rd32(p);
   p += 4;
   for (uint32_t i = 0; i < count; i++) {
      uint32_t len = rd32(p);
      const uint8_t *q = p + 4, *end = p + len;
      char name[128] = { 0 };
      uint64_t off = 0, sz = 0;
      while (q + 6 <= end && memcmp(q, "ENDT", 4)) {
         uint16_t vlen = rd16(q + 4);
         const uint8_t *v = q + 6;
         if (!memcmp(q, "NAME", 4)) memcpy(name, v, vlen < 127 ? vlen : 127);
         else if (!memcmp(q, "OFFT", 4) && vlen >= 24) off = rd64(v + 16);
         else if (!memcmp(q, "MDSZ", 4) && vlen >= 8) sz = rd64(v);
         q = v + vlen;
      }
      if (!strcmp(name, want) && off + sz <= bc_len) { *out_size = sz; return b + bc_off + off; }
      p = end;
   }
   return NULL;
}

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

static struct rwa_device *dev;
static const uint8_t *lib;
static size_t libsize;

static struct rwa_compute *
pipeline(const char *fn, struct rwa_compute_info *info)
{
   size_t sz;
   const uint8_t *bc = metallib_function(lib, libsize, fn, &sz);
   char why[512] = { 0 };
   if (!bc) { printf("  no function %s\n", fn); return NULL; }
   struct rwa_compute *c = rwa_compute_create(dev, bc, sz, fn, info, why, sizeof(why));
   if (!c) printf("  rwa_compute_create(%s): %s\n", fn, why);
   else printf("  %s: %zu bytes of AIR, max_threads=%u exec_width=%u buffers=%u\n", fn, sz, info->max_threads_per_group, info->thread_execution_width, info->buffers);
   return c;
}

static struct rwa_buffer *
buf(size_t size)
{
   char why[256] = { 0 };
   struct rwa_buffer *b = rwa_buffer_create(dev, size, why, sizeof(why));
   if (!b) printf("  rwa_buffer_create(%zu): %s\n", size, why);
   return b;
}

static int
dispatch(struct rwa_compute *c, struct rwa_buffer **bufs, unsigned nb, unsigned gx, unsigned lx, const char *what)
{
   char why[512] = { 0 };
   struct rwa_bindings b = { .buffers = bufs, .buffer_count = nb };
   unsigned groups[3] = { gx, 1, 1 }, size[3] = { lx, 1, 1 };
   double t0 = now_ms();
   int r = rwa_dispatch(c, &b, groups, size, why, sizeof(why));
   if (r == 0) r = rwa_finish(dev, why, sizeof(why));
   printf("  %s: %s in %.2f ms%s%s\n", what, r == 0 ? "done" : "FAILED", now_ms() - t0, r ? ": " : "", r ? why : "");
   return r == 0;
}

int
main(int argc, char **argv)
{
   const char *path = argc > 1 ? argv[1] : "bg_kernels.metallib";
   FILE *f = fopen(path, "rb");
   if (!f) { perror(path); return 2; }
   fseek(f, 0, SEEK_END); libsize = ftell(f); fseek(f, 0, SEEK_SET);
   uint8_t *data = malloc(libsize);
   if (fread(data, 1, libsize, f) != libsize) return 2;
   fclose(f);
   lib = data;

   char why[512] = { 0 };
   dev = rwa_device_open(why, sizeof(why));
   if (!dev) { printf("rwa_device_open: %s\n", why); return 3; }
   printf("device: %s (RWA_SOFTWARE=%s)\n", rwa_device_name(dev), getenv("RWA_SOFTWARE") ? getenv("RWA_SOFTWARE") : "unset");

   { // bg_add
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_add", &info);
      const unsigned n = 1024;
      if (c) {
         struct rwa_buffer *a = buf(n * 4), *b = buf(n * 4), *o = buf(n * 4), *k = buf(16);
         float *fa = rwa_buffer_map(a), *fb = rwa_buffer_map(b), *fo = rwa_buffer_map(o);
         uint32_t *pk = rwa_buffer_map(k);
         for (unsigned i = 0; i < n; i++) { fa[i] = i * 0.5f; fb[i] = (float)(n - i); fo[i] = -12345.0f; }
         pk[0] = n;
         struct rwa_buffer *bufs[4] = { a, b, o, k };
         if (dispatch(c, bufs, 4, n / 64, 64, "bg_add")) {
            unsigned bad = 0;
            for (unsigned i = 0; i < n; i++) if (fo[i] != fa[i] + 2.0f * fb[i]) { if (bad++ < 4) printf("    out[%u]=%g want %g\n", i, fo[i], fa[i] + 2.0f * fb[i]); }
            CHECK(bad == 0, "bg_add %u wrong", bad);
            printf("  bg_add: %u of %u correct\n", n - bad, n);
         } else fail++;
      } else fail++;
   }
   { // bg_copy
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_copy", &info);
      const unsigned n = 4096;
      if (c) {
         struct rwa_buffer *s = buf(n * 4), *d = buf(n * 4), *k = buf(16);
         uint32_t *ps = rwa_buffer_map(s), *pd = rwa_buffer_map(d), *pk = rwa_buffer_map(k);
         for (unsigned i = 0; i < n; i++) { ps[i] = i * 2654435761u; pd[i] = 0xdeadbeef; }
         pk[0] = n;
         struct rwa_buffer *bufs[3] = { s, d, k };
         if (dispatch(c, bufs, 3, n / 128, 128, "bg_copy")) {
            unsigned bad = 0;
            for (unsigned i = 0; i < n; i++) if (pd[i] != ps[i]) bad++;
            CHECK(bad == 0, "bg_copy %u wrong", bad);
            printf("  bg_copy: %u of %u correct\n", n - bad, n);
         } else fail++;
      } else fail++;
   }
   { // bg_copy with `device` buffers at offsets the GPU cannot fetch from (a6xx: 64; iOS 26's compute_sum_luma binds one at 32)
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_copy", &info);
      const unsigned n = 4096, so = 32, dof = 36;
      if (c) {
         struct rwa_buffer *s = buf(n * 4 + 64), *d = buf(n * 4 + 64), *k = buf(16);
         uint32_t *ps = rwa_buffer_map(s), *pd = rwa_buffer_map(d), *pk = rwa_buffer_map(k);
         for (unsigned i = 0; i < n + 16; i++) { ps[i] = i * 2654435761u; pd[i] = 0xdeadbeef; }
         pk[0] = n;
         struct rwa_buffer *bufs[3] = { s, d, k };
         struct rwa_buffer_bind table[3] = { { s, so }, { d, dof }, { k, 0 } };
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = 3 };
         unsigned groups[3] = { n / 128, 1, 1 }, size[3] = { 128, 1, 1 };
         char why2[512] = { 0 };
         int r = rwa_dispatch_buffers(c, &b, table, 3, groups, size, why2, sizeof(why2));
         if (r == 0) r = rwa_finish(dev, why2, sizeof(why2));
         printf("  bg_copy at offsets %u/%u: %s%s%s\n", so, dof, r == 0 ? "done" : "FAILED", r ? ": " : "", r ? why2 : "");
         if (r == 0) {
            unsigned bad = 0, clobbered = 0;
            for (unsigned i = 0; i < n; i++) if (pd[dof / 4 + i] != ps[so / 4 + i]) { if (bad++ < 4) printf("    dst[%u]=%08x want %08x\n", i, pd[dof / 4 + i], ps[so / 4 + i]); }
            for (unsigned i = 0; i < dof / 4; i++) if (pd[i] != 0xdeadbeef) clobbered++;
            CHECK(bad == 0, "bg_copy at offsets: %u wrong", bad);
            CHECK(clobbered == 0, "bg_copy at offsets: %u words before the destination offset written", clobbered);
            printf("  bg_copy at offsets: %u of %u correct, %u words before the offset written\n", n - bad, n, clobbered);
         } else fail++;
      } else fail++;
   }
   { // bg_groupsum
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_groupsum", &info);
      const unsigned groups = 32, per = 64;
      if (c) {
         struct rwa_buffer *in = buf(groups * per * 4), *out = buf(groups * 4), *k = buf(16);
         uint32_t *pi = rwa_buffer_map(in), *po = rwa_buffer_map(out), *pk = rwa_buffer_map(k);
         for (unsigned i = 0; i < groups * per; i++) pi[i] = i % 17 + 1;
         for (unsigned i = 0; i < groups; i++) po[i] = 0xffffffffu;
         pk[0] = per;
         struct rwa_buffer *bufs[3] = { in, out, k };
         if (dispatch(c, bufs, 3, groups, 32, "bg_groupsum")) {
            unsigned bad = 0;
            for (unsigned g = 0; g < groups; g++) {
               uint32_t want = 0;
               for (unsigned i = 0; i < per; i++) want += (g * per + i) % 17 + 1;
               if (po[g] != want) { if (bad++ < 3) printf("    out[%u]=%u want %u\n", g, po[g], want); }
            }
            CHECK(bad == 0, "bg_groupsum %u wrong", bad);
            printf("  bg_groupsum: %u of %u correct\n", groups - bad, groups);
         } else fail++;
      } else fail++;
   }
   { // bg_tex_write: a constant level 0 (the control for bg_mip_write). RGBA32Float as bgmtl_render_probe's P3: an RGBA8Unorm image
     // written by a kernel reads back zeros through this path (2026-10-25, not chased yet)
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_tex_write", &info);
      struct rwa_texture_shape shape = { .pixel_format = 125 /* RGBA32Float */, .type = 2, .width = 16, .height = 8, .depth = 1, .array_length = 1,
                                         .mip_levels = 1, .sample_count = 1, .usage = 3 };
      char why2[512] = { 0 };
      struct rwa_texture *t = c ? rwa_texture_create(dev, &shape, why2, sizeof(why2)) : NULL;
      float got[16 * 8 * 4] = { 0 };
      unsigned origin[3] = { 0, 0, 0 }, size[3] = { 16, 8, 1 };
      bool ok = t && rwa_texture_write(t, 0, 0, origin, size, got, 0, why2, sizeof(why2)) == 0;
      struct rwa_texture *texs[1] = { t };
      struct rwa_bindings b = { .textures = texs, .texture_count = 1 };
      unsigned groups[3] = { 1, 1, 1 }, gs[3] = { 16, 8, 1 };
      ok = ok && rwa_dispatch(c, &b, groups, gs, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0 &&
           rwa_texture_read(t, 0, 0, origin, size, got, 0, why2, sizeof(why2)) == 0;
      unsigned bad = 0;
      for (unsigned y = 0; ok && y < 8; y++)
         for (unsigned x = 0; x < 16; x++) {
            const float *p = got + 4 * (y * 16 + x);
            if (p[0] != x / 16.0f || p[1] != y / 16.0f || p[2] != 0.5f || p[3] != 1.0f) { if (bad++ < 3) printf("    texel %u,%u = %g,%g,%g,%g\n", x, y, p[0], p[1], p[2], p[3]); }
         }
      CHECK(ok && bad == 0, "bg_tex_write %u texels wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why2);
      printf("  bg_tex_write: %u texels wrong\n", bad);
   }
   for (unsigned run = 0; run < 2; run++) { // bg_mip_write: level 0 of one level, then levels 0, 2 and 4 of a 16x8 RGBA32Float chain of 5, the level a buffer value; 1 and 3 must stay zero
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_mip_write", &info);
      const unsigned W = 16, H = 8, LEVELS = run ? 5 : 1, written = run ? 1u << 0 | 1u << 2 | 1u << 4 : 1u;
      struct rwa_texture_shape shape = { .pixel_format = 125 /* RGBA32Float */, .type = 2 /* 2D */, .width = W, .height = H,
                                         .depth = 1, .array_length = 1, .mip_levels = LEVELS, .sample_count = 1,
                                         .usage = 3 /* ShaderRead | ShaderWrite */ };
      char why2[512] = { 0 };
      struct rwa_texture *t = c ? rwa_texture_create(dev, &shape, why2, sizeof(why2)) : NULL;
      if (c && !t) printf("  rwa_texture_create: %s\n", why2);
      struct rwa_buffer *k = t ? buf(16) : NULL, *sz = t ? buf(64) : NULL;
      float zero[16 * 8 * 4] = { 0 }, got[16 * 8 * 4];
      bool ok = k && sz;
      if (ok) memset(rwa_buffer_map(sz), 0xff, 64);
      for (unsigned l = 0; ok && l < LEVELS; l++) {
         unsigned origin[3] = { 0, 0, 0 }, size[3] = { MAX(W >> l, 1), MAX(H >> l, 1), 1 };
         ok = rwa_texture_write(t, l, 0, origin, size, zero, 0, why2, sizeof(why2)) == 0;
      }
      for (unsigned l = 0; ok && l < LEVELS; l++) {
         if (!(written & 1u << l))
            continue;
         *(uint32_t *)rwa_buffer_map(k) = l;
         struct rwa_buffer *bufs[2] = { k, sz };
         struct rwa_texture *texs[1] = { t };
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = 2, .textures = texs, .texture_count = 1 };
         unsigned groups[3] = { 1, 1, 1 }, size[3] = { W, H, 1 };
         ok = rwa_dispatch(c, &b, groups, size, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0;
      }
      if (ok) {
         unsigned bad = 0;
         const uint32_t *ps = rwa_buffer_map(sz);
         for (unsigned l = 0; l < LEVELS; l++)
            if (written & 1u << l) {
               CHECK(ps[2 * l] == MAX(W >> l, 1) && ps[2 * l + 1] == MAX(H >> l, 1), "bg_mip_write: level %u measured %ux%u", l, ps[2 * l], ps[2 * l + 1]);
            }
         for (unsigned l = 0; l < LEVELS; l++) {
            unsigned w = MAX(W >> l, 1), h = MAX(H >> l, 1), origin[3] = { 0, 0, 0 }, size[3] = { w, h, 1 };
            if (rwa_texture_read(t, l, 0, origin, size, got, 0, why2, sizeof(why2)) != 0) { bad++; printf("    read level %u: %s\n", l, why2); continue; }
            float want[4] = { 0, 0, 0, 0 };
            if (written & 1u << l) { want[0] = w / 255.0f; want[1] = h / 255.0f; want[2] = l / 255.0f; want[3] = 1.0f; }
            for (unsigned i = 0; i < w * h; i++)
               if (memcmp(got + 4 * i, want, sizeof(want))) { if (bad++ < 4) printf("    level %u texel %u = %g,%g,%g,%g want %g,%g,%g,%g\n", l, i, got[4 * i], got[4 * i + 1], got[4 * i + 2], got[4 * i + 3], want[0], want[1], want[2], want[3]); }
         }
         CHECK(bad == 0, "bg_mip_write %u texels wrong", bad);
         printf("  bg_mip_write (%u level%s): written at a level from a buffer, %u texels wrong\n", LEVELS, LEVELS > 1 ? "s" : "", bad);
      } else { fail++; printf("  bg_mip_write FAILED: %s\n", why2); }
   }
   { // bg_tex_choice: a phi between two textures, which one a buffer value (0: a, 1: b)
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_tex_choice", &info);
      struct rwa_texture_shape shape = { .pixel_format = 125, .type = 2, .width = 16, .height = 1, .depth = 1, .array_length = 1,
                                         .mip_levels = 1, .sample_count = 1, .usage = 1 };
      char why2[512] = { 0 };
      struct rwa_texture *ta = c ? rwa_texture_create(dev, &shape, why2, sizeof(why2)) : NULL;
      struct rwa_texture *tb = ta ? rwa_texture_create(dev, &shape, why2, sizeof(why2)) : NULL;
      struct rwa_buffer *k = tb ? buf(16) : NULL, *o = k ? buf(32 * 16) : NULL;
      float da[16 * 4], db[16 * 4];
      for (unsigned i = 0; i < 16 * 4; i++) { da[i] = (float)i; db[i] = 1000.0f + i; }
      unsigned origin[3] = { 0, 0, 0 }, size[3] = { 16, 1, 1 };
      bool ok = o && rwa_texture_write(ta, 0, 0, origin, size, da, 0, why2, sizeof(why2)) == 0 &&
                rwa_texture_write(tb, 0, 0, origin, size, db, 0, why2, sizeof(why2)) == 0;
      unsigned bad = 0;
      for (unsigned which = 0; ok && which < 2; which++) {
         *(uint32_t *)rwa_buffer_map(k) = which;
         memset(rwa_buffer_map(o), 0, 32 * 16);
         struct rwa_buffer *bufs[2] = { k, o };
         struct rwa_texture *texs[2] = { ta, tb };
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = 2, .textures = texs, .texture_count = 2 };
         unsigned groups[3] = { 1, 1, 1 }, gs[3] = { 16, 1, 1 };
         ok = rwa_dispatch(c, &b, groups, gs, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0;
         const float *po = rwa_buffer_map(o), *want = which ? db : da;
         for (unsigned i = 0; ok && i < 16 * 4; i++)
            if (po[i] != want[i]) { if (bad++ < 3) printf("    which=%u out[%u]=%g want %g\n", which, i, po[i], want[i]); }
         for (unsigned i = 16 * 4; ok && i < 32 * 4; i++)
            if (po[i] != (which ? 0.0f : 1.0f)) { if (bad++ < 3) printf("    which=%u marker[%u]=%g\n", which, i - 64, po[i]); }
      }
      CHECK(ok && bad == 0, "bg_tex_choice %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why2);
      printf("  bg_tex_choice: %u wrong\n", bad);
   }
   printf("== result: %d checks passed, %d failed\n", pass, fail);
   rwa_device_close(dev);
   return fail ? 1 : 0;
}
