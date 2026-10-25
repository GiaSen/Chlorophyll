// SPDX-License-Identifier: MIT
// libbgair without Metal: AIR function of a .metallib -> Mesa (AIR frontend, ir3) -> compute on freedreno, results checked on the CPU.
// Layer-isolating companion of bgmtl_probe: if this passes and the probe does not, the fault is in the _MTLDevice layer.
// The same source builds for the Mac (RWA_SOFTWARE=1 runs softpipe, a reference for the expected numbers) and for the phone.
//   bgair_test FILE.metallib
// The MTLB container reader is the format of the frontend's air_metallib.c (MIT, Copyright 2026 Darwin on redwood contributors).
#include <math.h>
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
   { // bg_tex_choice3: the nested form, a select between b and c merged with a by a phi (which: 0 a, 1 b, 2 c)
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_tex_choice3", &info);
      struct rwa_texture_shape shape = { .pixel_format = 125, .type = 2, .width = 16, .height = 1, .depth = 1, .array_length = 1,
                                         .mip_levels = 1, .sample_count = 1, .usage = 1 };
      char why2[512] = { 0 };
      struct rwa_texture *tx[3] = { NULL, NULL, NULL };
      float d[3][16 * 4];
      unsigned origin[3] = { 0, 0, 0 }, size[3] = { 16, 1, 1 };
      bool ok = c != NULL;
      for (unsigned t = 0; ok && t < 3; t++) {
         for (unsigned i = 0; i < 16 * 4; i++) d[t][i] = 1000.0f * t + i;
         ok = (tx[t] = rwa_texture_create(dev, &shape, why2, sizeof(why2))) &&
              rwa_texture_write(tx[t], 0, 0, origin, size, d[t], 0, why2, sizeof(why2)) == 0;
      }
      struct rwa_buffer *k = ok ? buf(16) : NULL, *o = k ? buf(32 * 16) : NULL;
      ok = ok && o;
      unsigned bad = 0;
      for (unsigned which = 0; ok && which < 3; which++) {
         *(uint32_t *)rwa_buffer_map(k) = which;
         memset(rwa_buffer_map(o), 0, 32 * 16);
         struct rwa_buffer *bufs[2] = { k, o };
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = 2, .textures = tx, .texture_count = 3 };
         unsigned groups[3] = { 1, 1, 1 }, gs[3] = { 16, 1, 1 };
         ok = rwa_dispatch(c, &b, groups, gs, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0;
         const float *po = rwa_buffer_map(o);
         for (unsigned i = 0; ok && i < 16 * 4; i++)
            if (po[i] != d[which][i]) { if (bad++ < 3) printf("    which=%u out[%u]=%g want %g\n", which, i, po[i], d[which][i]); }
      }
      CHECK(ok && bad == 0, "bg_tex_choice3 %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why2);
      printf("  bg_tex_choice3: %u wrong\n", bad);
   }
   { // multisample resolve (Mercury's wallpaper: a 4x pass resolved into its drawable): clear a 4x BGRA8 target, resolve, read back
      char why2[512] = { 0 };
      struct rwa_texture_shape ms = { .pixel_format = 80, .type = 4 /* 2DMultisample */, .width = 64, .height = 32, .depth = 1,
                                      .array_length = 1, .mip_levels = 1, .sample_count = 4, .usage = 4 /* RenderTarget */ };
      struct rwa_texture_shape ss = ms;
      ss.type = 2; ss.sample_count = 1; ss.usage = 5;
      struct rwa_texture *tm = rwa_texture_create(dev, &ms, why2, sizeof(why2));
      struct rwa_texture *ts = tm ? rwa_texture_create(dev, &ss, why2, sizeof(why2)) : NULL;
      bool ok = ts != NULL;
      if (ok) {
         struct rwa_texture *col[1] = { tm };
         struct rwa_clear cl = { .color = col, .color_count = 1, .color_mask = 1, .color_value = { { 1.0f, 0.5f, 0.25f, 1.0f } } };
         if (getenv("RESOLVE_CONTROL")) col[0] = ts;   /* control: clear the single-sample target itself, no resolve */
         ok = rwa_render_clear(dev, &cl, why2, sizeof(why2)) == 0 &&
              (getenv("RESOLVE_CONTROL") || rwa_texture_resolve(tm, ts, 0, 0) == 0) && rwa_finish(dev, why2, sizeof(why2)) == 0;
      }
      unsigned bad = 0;
      uint8_t got[64 * 32 * 4];
      unsigned origin[3] = { 0, 0, 0 }, size[3] = { 64, 32, 1 };
      ok = ok && rwa_texture_read(ts, 0, 0, origin, size, got, 0, why2, sizeof(why2)) == 0;
      for (unsigned i = 0; ok && i < 64 * 32; i++) {
         const uint8_t *q = got + 4 * i;   /* BGRA */
         if (q[2] != 255 || q[1] < 126 || q[1] > 129 || q[0] < 62 || q[0] > 65 || q[3] != 255) { if (bad++ < 3) printf("    texel %u = B%u G%u R%u A%u\n", i, q[0], q[1], q[2], q[3]); }
      }
      CHECK(ok && bad == 0, "multisample resolve: %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why2);
      printf("  multisample resolve: %u wrong%s%s\n", bad, ok ? "" : ": ", ok ? "" : why2);
   }
   { // the same resolve in BGRA8Unorm_sRGB (Mercury's format): 0.5 linear is 188 stored; a resolve that encodes twice gives ~225
      char why2[512] = { 0 };
      struct rwa_texture_shape ms = { .pixel_format = 81, .type = 4, .width = 64, .height = 32, .depth = 1,
                                      .array_length = 1, .mip_levels = 1, .sample_count = 4, .usage = 4 };
      struct rwa_texture_shape ss = ms;
      ss.type = 2; ss.sample_count = 1; ss.usage = 5;
      struct rwa_texture *tm = rwa_texture_create(dev, &ms, why2, sizeof(why2));
      struct rwa_texture *ts = tm ? rwa_texture_create(dev, &ss, why2, sizeof(why2)) : NULL;
      bool ok = ts != NULL;
      if (ok) {
         struct rwa_texture *col[1] = { tm };
         struct rwa_clear cl = { .color = col, .color_count = 1, .color_mask = 1, .color_value = { { 0.5f, 0.5f, 0.5f, 1.0f } } };
         ok = rwa_render_clear(dev, &cl, why2, sizeof(why2)) == 0 && rwa_texture_resolve(tm, ts, 0, 0) == 0 &&
              rwa_finish(dev, why2, sizeof(why2)) == 0;
      }
      uint8_t got[64 * 32 * 4];
      unsigned origin[3] = { 0, 0, 0 }, size[3] = { 64, 32, 1 };
      ok = ok && rwa_texture_read(ts, 0, 0, origin, size, got, 0, why2, sizeof(why2)) == 0;
      unsigned bad = 0;
      for (unsigned i = 0; ok && i < 64 * 32; i++)
         if (got[4 * i] < 186 || got[4 * i] > 190) { if (bad++ < 2) printf("    texel %u = %u %u %u %u\n", i, got[4 * i], got[4 * i + 1], got[4 * i + 2], got[4 * i + 3]); }
      CHECK(ok && bad == 0, "sRGB multisample resolve: %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why2);
      printf("  sRGB multisample resolve: texel 0 = %u, %u wrong\n", ok ? got[0] : 0, bad);
   }
   { // bg_math: Mercury's built-ins against libm (half results get a half's tolerance)
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_math", &info);
      const unsigned n = 64;
      if (c) {
         struct rwa_buffer *in = buf(n * 4), *out = buf(n * 16 * 4);
         float *pi = rwa_buffer_map(in), *po = rwa_buffer_map(out);
         for (unsigned i = 0; i < n; i++) pi[i] = -0.97f + 1.94f * i / (n - 1);
         struct rwa_buffer *bufs[2] = { in, out };
         static const char *names[16] = { "acos", "asin", "atan", "atan2", "cos", "sqrt", "rsqrt", "saturate", "pow.f16", "pow",
                                          "saturate.f16", "clamp.f16", "mix.f16", "fast pow", "pow.v3f16", "fmax" };
         if (dispatch(c, bufs, 2, n / 64, 64, "bg_math")) {
            unsigned bad[16] = { 0 };
            for (unsigned i = 0; i < n; i++) {
               double x = pi[i], y = pi[i] * 0.5 + 0.7, hx = x, hy = y;
               double want[16] = { acos(x), asin(x), atan(x * 3.0), atan2(x, y), cos(x * 3.0), sqrt(y), 1.0 / sqrt(y),
                                   fmin(fmax(x * 2.0, 0.0), 1.0), pow(hy, 2.2), pow(y, 2.2), fmin(fmax(hx * 2.0, 0.0), 1.0),
                                   fmin(fmax(hx, -0.25), 0.25), hx + (hy - hx) * 0.25, pow(y, 0.4545), pow(hy, 1.5), fmax(x, y * 0.5) };
               for (unsigned k = 0; k < 16; k++) {
                  double tol = (k >= 8 && k != 9 && k != 13 && k != 15) ? 0.01 + 0.004 * fabs(want[k]) : 0.002 + 0.002 * fabs(want[k]);
                  if (!(fabs(po[16 * i + k] - want[k]) <= tol)) { if (bad[k]++ < 2) printf("    %s(x=%g): %g want %g\n", names[k], x, po[16 * i + k], want[k]); }
               }
            }
            unsigned total = 0;
            for (unsigned k = 0; k < 16; k++) total += bad[k];
            CHECK(total == 0, "bg_math: %u wrong", total);
            printf("  bg_math: %u of %u wrong\n", total, n * 16);
         } else fail++;
      } else fail++;
   }
   { // sRGB textures sampled (Mercury's albedo is ASTC 6x6 sRGB): 0.5 stored must sample as ~0.214 linear, for BGRA8 sRGB and ASTC 4x4 sRGB
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_tex_sample", &info);
      char why2[512] = { 0 };
      struct rwa_sampler_state st = { .normalized_coordinates = 1, .lod_max = 1000.0f };
      struct rwa_sampler *smp = c ? rwa_sampler_create(dev, &st, why2, sizeof(why2)) : NULL;
      static const unsigned fmts[5] = { 81, 186, 70, 11, 25 };
      static const char *fname[5] = { "BGRA8Unorm_sRGB", "ASTC_4x4_sRGB", "RGBA8Unorm", "R8Unorm_sRGB", "R16Float" };
      for (unsigned f = 0; smp && f < 5; f++) {
         struct rwa_texture_shape sh = { .pixel_format = fmts[f], .type = 2, .width = 16, .height = 16, .depth = 1, .array_length = 1,
                                         .mip_levels = 1, .sample_count = 1, .usage = 1 };
         struct rwa_texture *t = rwa_texture_create(dev, &sh, why2, sizeof(why2));
         if (!t) { printf("  %s: %s\n", fname[f], why2); fail++; continue; }
         uint8_t data[16 * 16 * 4];
         unsigned origin[3] = { 0, 0, 0 }, size[3] = { 16, 16, 1 };
         size_t stride = 16 * 4;
         if (fmts[f] == 186) {   /* 16 void-extent blocks: a constant colour, UNORM16 0x8000 in each channel */
            for (unsigned b = 0; b < 16; b++) {
               uint8_t *q = data + 16 * b;
               static const uint8_t blk[16] = { 0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0xFF, 0xFF };
               memcpy(q, blk, 16);
            }
            stride = 4 * 16;   /* a row of 4 blocks */
         } else if (fmts[f] == 11) {   /* one byte a texel */
            for (unsigned i = 0; i < 16 * 16; i++) data[i] = 128;
            stride = 16;
         } else if (fmts[f] == 25) {   /* one half a texel: 0.5 */
            for (unsigned i = 0; i < 16 * 16; i++) { data[2 * i] = 0x00; data[2 * i + 1] = 0x38; }
            stride = 32;
         } else
            for (unsigned i = 0; i < 16 * 16 * 4; i++) data[i] = (i % 4 == 3) ? 255 : 128;
         if (rwa_texture_write(t, 0, 0, origin, size, data, stride, why2, sizeof(why2)) != 0) { printf("  %s write: %s\n", fname[f], why2); fail++; continue; }
         struct rwa_buffer *o = buf(16 * 16 * 16);
         struct rwa_buffer *bufs[1] = { o };
         struct rwa_texture *texs[1] = { t };
         struct rwa_sampler *smps[1] = { smp };
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = 1, .textures = texs, .texture_count = 1, .samplers = smps, .sampler_count = 1 };
         unsigned groups[3] = { 1, 1, 1 }, gs[3] = { 16, 16, 1 };
         bool ok = rwa_dispatch(c, &b, groups, gs, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0;
         const float *po = rwa_buffer_map(o);
         double want = fmts[f] == 70 ? 128 / 255.0 : fmts[f] == 25 ? 0.5 :
                       (fmts[f] == 186 ? pow((0.5 + 0.055) / 1.055, 2.4) : pow((128 / 255.0 + 0.055) / 1.055, 2.4));
         bool one = fmts[f] == 11 || fmts[f] == 25;   /* single channel: red only */
         bool good = ok && fabs(po[0] - want) < 0.01 && (one || (fabs(po[1] - want) < 0.01 && fabs(po[2] - want) < 0.01));
         CHECK(good, "sample %s: %g %g %g %g want %g%s%s", fname[f], po[0], po[1], po[2], po[3], want, ok ? "" : ": ", ok ? "" : why2);
         printf("  sample %s: %.3f %.3f %.3f %.3f (want %.3f)\n", fname[f], po[0], po[1], po[2], po[3], want);
      }
   }
   { // texture view: level 1 of a 3-level RGBA32Float texture, swizzled (Blue, Green, Red, One), sampled through the view
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_tex_sample", &info);
      char why2[512] = { 0 };
      struct rwa_sampler_state st = { .normalized_coordinates = 1, .lod_max = 1000.0f };
      struct rwa_sampler *smp = c ? rwa_sampler_create(dev, &st, why2, sizeof(why2)) : NULL;
      struct rwa_texture_shape sh = { .pixel_format = 125, .type = 2, .width = 32, .height = 32, .depth = 1, .array_length = 1,
                                      .mip_levels = 3, .sample_count = 1, .usage = 1 };
      struct rwa_texture *t = smp ? rwa_texture_create(dev, &sh, why2, sizeof(why2)) : NULL;
      static float lv[32 * 32 * 4];
      bool ok = t != NULL;
      for (unsigned l = 0; ok && l < 3; l++) {
         unsigned w = 32 >> l;
         for (unsigned i = 0; i < w * w; i++) { lv[4*i] = 0.1f + l; lv[4*i+1] = 0.2f + l; lv[4*i+2] = 0.3f + l; lv[4*i+3] = 0.5f; }
         unsigned o[3] = { 0, 0, 0 }, sz[3] = { w, w, 1 };
         ok = rwa_texture_write(t, l, 0, o, sz, lv, 0, why2, sizeof(why2)) == 0;
      }
      static const unsigned char swz[4] = { 4, 3, 2, 1 };   /* MTLTextureSwizzle Blue, Green, Red, One */
      struct rwa_texture *v = ok ? rwa_texture_view(t, 125, 2, 1, 1, 0, 1, swz, why2, sizeof(why2)) : NULL;
      ok = v != NULL;
      struct rwa_buffer *o = ok ? buf(16 * 16 * 16) : NULL;
      if (ok) {
         struct rwa_buffer *bufs[1] = { o };
         struct rwa_texture *texs[1] = { v };
         struct rwa_sampler *smps[1] = { smp };
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = 1, .textures = texs, .texture_count = 1, .samplers = smps, .sampler_count = 1 };
         unsigned groups[3] = { 1, 1, 1 }, gs[3] = { 16, 16, 1 };
         ok = rwa_dispatch(c, &b, groups, gs, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0;
      }
      const float *po = ok ? rwa_buffer_map(o) : NULL;
      bool good = ok && fabsf(po[0] - 1.3f) < 0.001f && fabsf(po[1] - 1.2f) < 0.001f && fabsf(po[2] - 1.1f) < 0.001f && po[3] == 1.0f;
      CHECK(good, "texture view: %g %g %g %g want 1.3 1.2 1.1 1%s%s", po ? po[0] : 0, po ? po[1] : 0, po ? po[2] : 0, po ? po[3] : 0,
            ok ? "" : ": ", ok ? "" : why2);
      printf("  texture view (level 1, BGR1): %.2f %.2f %.2f %.2f%s%s\n", po ? po[0] : 0, po ? po[1] : 0, po ? po[2] : 0, po ? po[3] : 0,
             ok ? "" : ": ", ok ? "" : why2);
   }
   { // bg_tex_write_half: half colours into RGBA16Float and RGBA8Unorm images (was stored as integers: huge, or zero)
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_tex_write_half", &info);
      static const unsigned fmts[2] = { 115, 70 };
      for (unsigned f = 0; c && f < 2; f++) {
         char why2[512] = { 0 };
         struct rwa_texture_shape sh = { .pixel_format = fmts[f], .type = 2, .width = 16, .height = 8, .depth = 1, .array_length = 1,
                                         .mip_levels = 1, .sample_count = 1, .usage = 3 };
         struct rwa_texture *t = rwa_texture_create(dev, &sh, why2, sizeof(why2));
         uint8_t raw[16 * 8 * 8] = { 0 };
         unsigned origin[3] = { 0, 0, 0 }, size[3] = { 16, 8, 1 };
         bool ok = t && rwa_texture_write(t, 0, 0, origin, size, raw, 0, why2, sizeof(why2)) == 0;
         struct rwa_texture *texs[1] = { t };
         struct rwa_bindings b = { .textures = texs, .texture_count = 1 };
         unsigned groups[3] = { 1, 1, 1 }, gs[3] = { 16, 8, 1 };
         ok = ok && rwa_dispatch(c, &b, groups, gs, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0 &&
              rwa_texture_read(t, 0, 0, origin, size, raw, 0, why2, sizeof(why2)) == 0;
         float got[4] = { 0 };
         if (ok && fmts[f] == 115) {
            const uint16_t *h = (const uint16_t *)raw;
            for (unsigned k = 0; k < 4; k++) {   /* half -> float, normal numbers only */
               unsigned e = (h[k] >> 10) & 31, m = h[k] & 1023;
               got[k] = e ? ldexpf(1.0f + m / 1024.0f, (int)e - 15) : 0.0f;
               if (h[k] & 0x8000) got[k] = -got[k];
            }
         } else if (ok)
            for (unsigned k = 0; k < 4; k++) got[k] = raw[k] / 255.0f;
         bool good = ok && fabsf(got[0] - 0.25f) < 0.01f && fabsf(got[1] - 0.5f) < 0.01f && fabsf(got[2] - 0.75f) < 0.01f &&
                     fabsf(got[3] - 1.0f) < 0.01f;
         CHECK(good, "bg_tex_write_half fmt %u: %g %g %g %g%s%s", fmts[f], got[0], got[1], got[2], got[3], ok ? "" : ": ", ok ? "" : why2);
         printf("  bg_tex_write_half fmt %u: %.3f %.3f %.3f %.3f (want 0.25 0.5 0.75 1)\n", fmts[f], got[0], got[1], got[2], got[3]);
      }
   }
   { // bg_is_null: slot 0 bound, slot 1 not: 0 then 1
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_is_null", &info);
      char why2[512] = { 0 };
      struct rwa_texture_shape sh = { .pixel_format = 70, .type = 2, .width = 4, .height = 4, .depth = 1, .array_length = 1,
                                      .mip_levels = 1, .sample_count = 1, .usage = 1 };
      struct rwa_texture *t = c ? rwa_texture_create(dev, &sh, why2, sizeof(why2)) : NULL;
      struct rwa_texture *stand_in = t ? rwa_texture_create(dev, &sh, why2, sizeof(why2)) : NULL;   /* what bgmtl binds for nothing */
      if (stand_in) rwa_texture_mark_null(stand_in);
      struct rwa_buffer *o = stand_in ? buf(16) : NULL;
      bool ok = o != NULL;
      if (ok) {
         uint32_t *po = rwa_buffer_map(o); po[0] = po[1] = 7;
         struct rwa_buffer *bufs[1] = { o };
         struct rwa_texture *texs[2] = { t, stand_in };
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = 1, .textures = texs, .texture_count = 2 };
         unsigned groups[3] = { 1, 1, 1 }, gs[3] = { 1, 1, 1 };
         ok = rwa_dispatch(c, &b, groups, gs, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0;
      }
      const uint32_t *po = ok ? rwa_buffer_map(o) : NULL;
      CHECK(ok && po[0] == 0 && po[1] == 1, "bg_is_null: %u %u want 0 1%s%s", po ? po[0] : 9, po ? po[1] : 9, ok ? "" : ": ", ok ? "" : why2);
      printf("  bg_is_null: bound %u unbound %u (want 0 1)%s%s\n", po ? po[0] : 9, po ? po[1] : 9, ok ? "" : ": ", ok ? "" : why2);
   }
   { // render into mip level 1 through a view (CoreAnimation's blur pyramid): level 1 gets the colour, level 0 stays as it was
      char why2[512] = { 0 };
      struct rwa_texture_shape sh = { .pixel_format = 80, .type = 2, .width = 32, .height = 16, .depth = 1, .array_length = 1,
                                      .mip_levels = 3, .sample_count = 1, .usage = 5 };
      struct rwa_texture *t = rwa_texture_create(dev, &sh, why2, sizeof(why2));
      static uint8_t buf0[32 * 16 * 4];
      memset(buf0, 0x11, sizeof(buf0));
      unsigned o[3] = { 0, 0, 0 }, s0[3] = { 32, 16, 1 }, s1[3] = { 16, 8, 1 };
      bool ok = t && rwa_texture_write(t, 0, 0, o, s0, buf0, 0, why2, sizeof(why2)) == 0 &&
                rwa_texture_write(t, 1, 0, o, s1, buf0, 0, why2, sizeof(why2)) == 0;
      struct rwa_texture *v = ok ? rwa_texture_view(t, 80, 2, 1, 1, 0, 1, NULL, why2, sizeof(why2)) : NULL;
      ok = v != NULL;
      if (ok) {
         struct rwa_texture *col[1] = { v };
         struct rwa_clear cl = { .color = col, .color_count = 1, .color_mask = 1, .color_value = { { 1.0f, 0.0f, 0.0f, 1.0f } } };
         ok = rwa_render_clear(dev, &cl, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0;
      }
      static uint8_t l0[32 * 16 * 4], l1[16 * 8 * 4];
      ok = ok && rwa_texture_read(t, 0, 0, o, s0, l0, 0, why2, sizeof(why2)) == 0 && rwa_texture_read(t, 1, 0, o, s1, l1, 0, why2, sizeof(why2)) == 0;
      unsigned bad1 = 0, bad0 = 0;
      for (unsigned i = 0; ok && i < 16 * 8; i++) if (l1[4*i+2] != 255 || l1[4*i] != 0 || l1[4*i+3] != 255) bad1++;   /* BGRA: red */
      for (unsigned i = 0; ok && i < 32 * 16 * 4; i++) if (l0[i] != 0x11) bad0++;
      CHECK(ok && !bad1 && !bad0, "render into level 1: %u wrong in level 1, %u changed in level 0%s%s", bad1, bad0, ok ? "" : ": ", ok ? "" : why2);
      printf("  render into level 1 via a view: %u wrong in level 1, %u changed in level 0%s%s\n", bad1, bad0, ok ? "" : ": ", ok ? "" : why2);
   }
   { // dispatches that do not wait (what the Metal driver does): bg_add three times with three threadgroup sizes into three
     // outputs, then one wait for all of them; then a fourth and fifth size, so the compute state cache evicts one in use
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_add", &info);
      enum { N = 256 };
      struct rwa_buffer *a = c ? buf(N * 4) : NULL, *b = a ? buf(N * 4) : NULL, *n = b ? buf(16) : NULL, *out[5] = { NULL };
      for (unsigned k = 0; n && k < 5; k++) out[k] = buf(N * 4);
      bool ok = out[4] != NULL;
      char why2[512] = { 0 };
      if (ok) {
         float *pa = rwa_buffer_map(a), *pb = rwa_buffer_map(b);
         for (unsigned i = 0; i < N; i++) { pa[i] = (float)i; pb[i] = 1000.0f; }
         *(uint32_t *)rwa_buffer_map(n) = N;
         for (unsigned k = 0; k < 5; k++) memset(rwa_buffer_map(out[k]), 0, N * 4);
         rwa_device_set_dispatch_wait(dev, false);
         static const unsigned sizes[5] = { 64, 32, 128, 16, 256 };
         for (unsigned k = 0; ok && k < 5; k++) {
            struct rwa_buffer *bufs[4] = { a, b, out[k], n };
            struct rwa_bindings bb = { .buffers = bufs, .buffer_count = 4 };
            unsigned groups[3] = { N / sizes[k], 1, 1 }, gs[3] = { sizes[k], 1, 1 };
            ok = rwa_dispatch(c, &bb, groups, gs, why2, sizeof(why2)) == 0;
         }
         ok = ok && rwa_finish(dev, why2, sizeof(why2)) == 0;
         rwa_device_set_dispatch_wait(dev, true);
      }
      unsigned bad = 0;
      for (unsigned k = 0; ok && k < 5; k++) {
         const float *po = rwa_buffer_map(out[k]);
         for (unsigned i = 0; i < N; i++) if (po[i] != 2000.0f + (float)i) bad++;
      }
      CHECK(ok && !bad, "dispatch without waiting: %u wrong of 5x%u%s%s", bad, (unsigned)N, ok ? "" : ": ", ok ? "" : why2);
      printf("  5 dispatches without waiting (sizes 64/32/128/16/256), one finish: %u wrong%s%s\n", bad, ok ? "" : ": ", ok ? "" : why2);
   }
   { // dependent dispatches without waiting: bg_copy a -> b, then b -> c, then c -> d, one finish; d must equal a
      struct rwa_compute_info info = { 0 };
      struct rwa_compute *c = pipeline("bg_copy", &info);
      enum { N = 4096 };
      struct rwa_buffer *v[4] = { NULL }, *n = c ? buf(16) : NULL;
      for (unsigned k = 0; n && k < 4; k++) v[k] = buf(N * 4);
      bool ok = v[3] != NULL;
      char why2[512] = { 0 };
      if (ok) {
         uint32_t *pa = rwa_buffer_map(v[0]);
         for (unsigned i = 0; i < N; i++) pa[i] = 0x9e3779b9u * (i + 1);
         for (unsigned k = 1; k < 4; k++) memset(rwa_buffer_map(v[k]), 0, N * 4);
         *(uint32_t *)rwa_buffer_map(n) = N;
         rwa_device_set_dispatch_wait(dev, false);
         for (unsigned k = 0; ok && k < 3; k++) {
            struct rwa_buffer *bufs[3] = { v[k], v[k + 1], n };
            struct rwa_bindings bb = { .buffers = bufs, .buffer_count = 3 };
            unsigned groups[3] = { N / 64, 1, 1 }, gs[3] = { 64, 1, 1 };
            ok = rwa_dispatch(c, &bb, groups, gs, why2, sizeof(why2)) == 0;
         }
         ok = ok && rwa_finish(dev, why2, sizeof(why2)) == 0;
         rwa_device_set_dispatch_wait(dev, true);
      }
      unsigned bad = 0;
      const uint32_t *pa = ok ? rwa_buffer_map(v[0]) : NULL, *pd = ok ? rwa_buffer_map(v[3]) : NULL;
      for (unsigned i = 0; ok && i < N; i++) if (pd[i] != pa[i]) bad++;
      CHECK(ok && !bad, "dependent dispatches without waiting: %u wrong of %u%s%s", bad, (unsigned)N, ok ? "" : ": ", ok ? "" : why2);
      printf("  3 dependent copies without waiting, one finish: %u wrong%s%s\n", bad, ok ? "" : ": ", ok ? "" : why2);
   }
   { // MTLPixelFormatRGB10A2Unorm (90): red is bits 0-9. Clear to pure red, then pure blue + alpha 0, and read the raw words.
      char why2[512] = { 0 };
      struct rwa_texture_shape sh = { .pixel_format = 90, .type = 2, .width = 4, .height = 4, .depth = 1, .array_length = 1,
                                      .mip_levels = 1, .sample_count = 1, .usage = 5 };
      struct rwa_texture *t = rwa_texture_create(dev, &sh, why2, sizeof(why2));
      uint32_t px[16] = { 0 }, got[2] = { 0 };
      static const float vals[2][4] = { { 1, 0, 0, 1 }, { 0, 0, 1, 0 } };
      bool ok = t != NULL;
      for (unsigned k = 0; ok && k < 2; k++) {
         struct rwa_texture *col[1] = { t };
         struct rwa_clear cl = { .color = col, .color_count = 1, .color_mask = 1 };
         memcpy(cl.color_value[0], vals[k], sizeof(vals[k]));
         unsigned o[3] = { 0, 0, 0 }, sz[3] = { 4, 4, 1 };
         ok = rwa_render_clear(dev, &cl, why2, sizeof(why2)) == 0 && rwa_finish(dev, why2, sizeof(why2)) == 0 &&
              rwa_texture_read(t, 0, 0, o, sz, px, 0, why2, sizeof(why2)) == 0;
         got[k] = px[5];
      }
      CHECK(ok && got[0] == 0xC00003FFu && got[1] == 0x3FF00000u, "RGB10A2Unorm: red 0x%08x (want 0xC00003FF), blue 0x%08x (want 0x3FF00000)%s%s",
            got[0], got[1], ok ? "" : ": ", ok ? "" : why2);
      printf("  RGB10A2Unorm clear: red 0x%08x blue 0x%08x (want 0xC00003FF 0x3FF00000)%s%s\n", got[0], got[1], ok ? "" : ": ", ok ? "" : why2);
   }
   printf("== result: %d checks passed, %d failed\n", pass, fail);
   rwa_device_close(dev);
   return fail ? 1 : 0;
}
