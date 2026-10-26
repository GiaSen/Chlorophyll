// SPDX-License-Identifier: MIT
// Chlorophyll's Turnip runtime (air/chl.h) on the A630: the checks of test/bgair_test.c (compute kernels of bg_kernels.metallib,
// textures, samplers, views, resolves, clears) plus draws with bg_render.metallib, through command buffers and encoders.
//   chl_test bg_kernels.metallib bg_render.metallib
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "chl.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>

static int pass, fail;
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define CHECK(c, ...) do { if (c) pass++; else { fail++; printf("  FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static uint64_t rd64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return p[0] | p[1] << 8; }
static const uint8_t *
fn_of(const uint8_t *b, size_t size, const char *want, size_t *out)
{
   if (size < 0x58 || memcmp(b, "MTLB", 4)) return NULL;
   uint64_t funcs = rd64(b + 0x18), bc_off = rd64(b + 0x48);
   const uint8_t *p = b + funcs;
   uint32_t count = rd32(p); p += 4;
   for (uint32_t i = 0; i < count; i++) {
      uint32_t len = rd32(p); const uint8_t *q = p + 4, *end = p + len; char name[128] = { 0 }; uint64_t off = 0, sz = 0;
      while (q + 6 <= end && memcmp(q, "ENDT", 4)) {
         uint16_t vl = rd16(q + 4); const uint8_t *v = q + 6;
         if (!memcmp(q, "NAME", 4)) memcpy(name, v, vl < 127 ? vl : 127);
         else if (!memcmp(q, "OFFT", 4) && vl >= 24) off = rd64(v + 16);
         else if (!memcmp(q, "MDSZ", 4) && vl >= 8) sz = rd64(v);
         q = v + vl;
      }
      if (!strcmp(name, want)) { *out = sz; return b + bc_off + off; }
      p = end;
   }
   return NULL;
}
static uint8_t *slurp(const char *p, size_t *n) { FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(2); } fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET); uint8_t *d = malloc(*n); if (fread(d, 1, *n, f) != *n) exit(2); fclose(f); return d; }
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

static struct chl_device *dev;
static const uint8_t *klib, *rlib;
static size_t klib_size, rlib_size;
static char why[512];

static struct chl_compute_pipeline *
kernel(const char *name)
{
   size_t sz;
   const uint8_t *bc = fn_of(klib, klib_size, name, &sz);
   if (!bc) { printf("  no function %s\n", name); return NULL; }
   struct chl_function fn = { bc, sz, name, NULL, 0 };
   struct chl_pipeline_info info;
   double t0 = now_ms();
   struct chl_compute_pipeline *p = chl_compute_pipeline_create(dev, &fn, &info, why, sizeof(why));
   if (!p) printf("  %s: %s\n", name, why);
   else printf("  %s: pipeline in %.1f ms, buffers %#x textures %#x samplers %#x\n", name, now_ms() - t0, info.buffers_used[0],
               info.textures_used[0], info.samplers_used[0]);
   return p;
}

static struct chl_buffer *
buf(size_t size)
{
   struct chl_buffer *b = chl_buffer_create(dev, size, why, sizeof(why));
   if (!b) printf("  buffer(%zu): %s\n", size, why);
   return b;
}

static struct chl_texture *
tex(unsigned fmt, unsigned type, unsigned w, unsigned h, unsigned levels, unsigned samples, unsigned usage)
{
   struct chl_texture_desc d = { .pixel_format = fmt, .type = type, .width = w, .height = h, .depth = 1, .array_length = 1,
                                 .mip_levels = levels, .sample_count = samples, .usage = usage };
   struct chl_texture *t = chl_texture_create(dev, &d, why, sizeof(why));
   if (!t) printf("  texture(%u): %s\n", fmt, why);
   return t;
}

struct binding {
   struct chl_buffer *b[8]; size_t off[8]; unsigned nb;
   struct chl_texture *t[8]; unsigned nt;
   struct chl_sampler *s[8]; unsigned ns;
};

static bool
dispatch(struct chl_compute_pipeline *p, const struct binding *bd, unsigned gx, unsigned gy, unsigned lx, unsigned ly)
{
   struct chl_cmdbuf *cb = chl_cmdbuf_create(dev, why, sizeof(why));
   if (!cb) return false;
   chl_compute_begin(cb);
   chl_set_compute_pipeline(cb, p);
   for (unsigned i = 0; i < bd->nb; i++) chl_set_buffer(cb, CHL_STAGE_COMPUTE, i, bd->b[i], bd->off[i]);
   for (unsigned i = 0; i < bd->nt; i++) chl_set_texture(cb, CHL_STAGE_COMPUTE, i, bd->t[i]);
   for (unsigned i = 0; i < bd->ns; i++) chl_set_sampler(cb, CHL_STAGE_COMPUTE, i, bd->s[i]);
   unsigned g[3] = { gx, gy, 1 }, l[3] = { lx, ly, 1 };
   bool ok = chl_dispatch(cb, g, l, why, sizeof(why)) == 0;
   chl_compute_end(cb);
   if (ok) ok = chl_cmdbuf_commit(cb, NULL, NULL, why, sizeof(why)) == 0 && chl_cmdbuf_wait(cb, why, sizeof(why)) == 0;
   chl_cmdbuf_release(cb);
   return ok;
}

static void
test_compute(void)
{
   { // bg_add
      struct chl_compute_pipeline *c = kernel("bg_add");
      const unsigned n = 1024;
      if (c) {
         struct chl_buffer *a = buf(n * 4), *b = buf(n * 4), *o = buf(n * 4), *k = buf(16);
         float *fa = chl_buffer_contents(a), *fb = chl_buffer_contents(b), *fo = chl_buffer_contents(o);
         for (unsigned i = 0; i < n; i++) { fa[i] = i * 0.5f; fb[i] = (float)(n - i); fo[i] = -12345.0f; }
         *(uint32_t *)chl_buffer_contents(k) = n;
         struct binding bd = { .b = { a, b, o, k }, .nb = 4 };
         bool ok = dispatch(c, &bd, n / 64, 1, 64, 1);
         unsigned bad = 0;
         for (unsigned i = 0; ok && i < n; i++) if (fo[i] != fa[i] + 2.0f * fb[i]) { if (bad++ < 4) printf("    out[%u]=%g want %g\n", i, fo[i], fa[i] + 2.0f * fb[i]); }
         CHECK(ok && !bad, "bg_add %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why);
         printf("  bg_add: %u of %u correct\n", ok ? n - bad : 0, n);
      } else fail++;
   }
   for (unsigned run = 0; run < 2; run++) { // bg_copy, then at offsets the GPU cannot fetch from (32 and 36)
      struct chl_compute_pipeline *c = kernel("bg_copy");
      const unsigned n = 4096, so = run ? 32 : 0, dof = run ? 36 : 0;
      if (c) {
         struct chl_buffer *s = buf(n * 4 + 64), *d = buf(n * 4 + 64), *k = buf(16);
         uint32_t *ps = chl_buffer_contents(s), *pd = chl_buffer_contents(d);
         for (unsigned i = 0; i < n + 16; i++) { ps[i] = i * 2654435761u; pd[i] = 0xdeadbeef; }
         *(uint32_t *)chl_buffer_contents(k) = n;
         struct binding bd = { .b = { s, d, k }, .off = { so, dof, 0 }, .nb = 3 };
         bool ok = dispatch(c, &bd, n / 128, 1, 128, 1);
         unsigned bad = 0, clobbered = 0;
         for (unsigned i = 0; ok && i < n; i++) if (pd[dof / 4 + i] != ps[so / 4 + i]) bad++;
         for (unsigned i = 0; ok && i < dof / 4; i++) if (pd[i] != 0xdeadbeef) clobbered++;
         CHECK(ok && !bad && !clobbered, "bg_copy at %u/%u: %u wrong, %u clobbered%s%s", so, dof, bad, clobbered, ok ? "" : ": ", ok ? "" : why);
         printf("  bg_copy at offsets %u/%u: %u wrong, %u words before the offset written\n", so, dof, bad, clobbered);
      } else fail++;
   }
   { // bg_groupsum (threadgroup memory)
      struct chl_compute_pipeline *c = kernel("bg_groupsum");
      const unsigned groups = 32, per = 64;
      if (c) {
         struct chl_buffer *in = buf(groups * per * 4), *out = buf(groups * 4), *k = buf(16);
         uint32_t *pi = chl_buffer_contents(in), *po = chl_buffer_contents(out);
         for (unsigned i = 0; i < groups * per; i++) pi[i] = i % 17 + 1;
         for (unsigned i = 0; i < groups; i++) po[i] = 0xffffffffu;
         *(uint32_t *)chl_buffer_contents(k) = per;
         struct binding bd = { .b = { in, out, k }, .nb = 3 };
         bool ok = dispatch(c, &bd, groups, 1, 32, 1);
         unsigned bad = 0;
         for (unsigned g = 0; ok && g < groups; g++) {
            uint32_t want = 0;
            for (unsigned i = 0; i < per; i++) want += (g * per + i) % 17 + 1;
            if (po[g] != want) { if (bad++ < 3) printf("    out[%u]=%u want %u\n", g, po[g], want); }
         }
         CHECK(ok && !bad, "bg_groupsum %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why);
         printf("  bg_groupsum: %u of %u correct\n", ok ? groups - bad : 0, groups);
      } else fail++;
   }
   { // bg_scratch: a run-time-indexed thread array in private memory (scratch)
      struct chl_compute_pipeline *c = kernel("bg_scratch");
      const unsigned n = 4096, salt = 7;
      if (c) {
         struct chl_buffer *o = buf(n * 4), *k = buf(16);
         uint32_t *po = chl_buffer_contents(o);
         for (unsigned i = 0; i < n; i++) po[i] = 0xdeadbeef;
         *(uint32_t *)chl_buffer_contents(k) = salt;
         struct binding bd = { .b = { o, k }, .nb = 2 };
         bool ok = dispatch(c, &bd, n / 64, 1, 64, 1);
         unsigned bad = 0;
         for (unsigned g = 0; ok && g < n; g++) {
            uint32_t a[96], want = 0;
            for (unsigned i = 0; i < 96; i++) a[i] = g * 31u + i * salt;
            for (unsigned i = 0; i < 96; i++) want += a[(i * 37u + g) % 96u] ^ i;
            if (po[g] != want) { if (bad++ < 3) printf("    out[%u]=%u want %u\n", g, po[g], want); }
         }
         CHECK(ok && !bad, "bg_scratch %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why);
         printf("  bg_scratch: %u of %u correct\n", ok ? n - bad : 0, n);
      } else fail++;
   }
   { // bg_tex_write: an image store at level 0 into RGBA32Float
      struct chl_compute_pipeline *c = kernel("bg_tex_write");
      struct chl_texture *t = c ? tex(125, 2, 16, 8, 1, 1, 3) : NULL;
      float got[16 * 8 * 4] = { 0 };
      bool ok = t && chl_texture_replace(t, 0, 0, NULL, NULL, got, 0, 0, why, sizeof(why)) == 0;
      struct binding bd = { .t = { t }, .nt = 1 };
      ok = ok && dispatch(c, &bd, 1, 1, 16, 8) && chl_texture_get(t, 0, 0, NULL, NULL, got, 0, 0, why, sizeof(why)) == 0;
      unsigned bad = 0;
      for (unsigned y = 0; ok && y < 8; y++)
         for (unsigned x = 0; x < 16; x++) {
            const float *p = got + 4 * (y * 16 + x);
            if (p[0] != x / 16.0f || p[1] != y / 16.0f || p[2] != 0.5f || p[3] != 1.0f) { if (bad++ < 3) printf("    texel %u,%u = %g,%g,%g,%g\n", x, y, p[0], p[1], p[2], p[3]); }
         }
      CHECK(ok && !bad, "bg_tex_write %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why);
      printf("  bg_tex_write: %u texels wrong\n", bad);
   }
   for (unsigned run = 0; run < 2; run++) { // bg_mip_write: levels chosen at run time (Mercury's blur downsample); 1 and 3 stay zero
      struct chl_compute_pipeline *c = kernel("bg_mip_write");
      const unsigned W = 16, H = 8, LEVELS = run ? 5 : 1, written = run ? 1u << 0 | 1u << 2 | 1u << 4 : 1u;
      struct chl_texture *t = c ? tex(125, 2, W, H, LEVELS, 1, 3) : NULL;
      struct chl_buffer *k = t ? buf(16) : NULL, *sz = k ? buf(64) : NULL;
      static float zero[16 * 8 * 4], got[16 * 8 * 4];
      bool ok = sz != NULL;
      if (ok) memset(chl_buffer_contents(sz), 0xff, 64);
      for (unsigned l = 0; ok && l < LEVELS; l++) ok = chl_texture_replace(t, l, 0, NULL, NULL, zero, 0, 0, why, sizeof(why)) == 0;
      for (unsigned l = 0; ok && l < LEVELS; l++) {
         if (!(written & 1u << l)) continue;
         *(uint32_t *)chl_buffer_contents(k) = l;
         struct binding bd = { .b = { k, sz }, .nb = 2, .t = { t }, .nt = 1 };
         ok = dispatch(c, &bd, 1, 1, W, H);
      }
      unsigned bad = 0;
      const uint32_t *ps = ok ? chl_buffer_contents(sz) : NULL;
      for (unsigned l = 0; ok && l < LEVELS; l++) {
         unsigned w = MAX(W >> l, 1), h = MAX(H >> l, 1);
         if ((written & 1u << l) && (ps[2 * l] != w || ps[2 * l + 1] != h)) { bad++; printf("    level %u measured %ux%u\n", l, ps[2 * l], ps[2 * l + 1]); }
         if (chl_texture_get(t, l, 0, NULL, NULL, got, 0, 0, why, sizeof(why)) != 0) { bad++; continue; }
         float want[4] = { 0, 0, 0, 0 };
         if (written & 1u << l) { want[0] = w / 255.0f; want[1] = h / 255.0f; want[2] = l / 255.0f; want[3] = 1.0f; }
         for (unsigned i = 0; i < w * h; i++)
            if (memcmp(got + 4 * i, want, sizeof(want))) { if (bad++ < 4) printf("    level %u texel %u = %g,%g,%g,%g\n", l, i, got[4*i], got[4*i+1], got[4*i+2], got[4*i+3]); }
      }
      CHECK(ok && !bad, "bg_mip_write (%u levels): %u wrong%s%s", LEVELS, bad, ok ? "" : ": ", ok ? "" : why);
      printf("  bg_mip_write (%u level%s, level chosen at run time): %u wrong\n", LEVELS, LEVELS > 1 ? "s" : "", bad);
   }
   for (unsigned nt = 2; nt <= 3; nt++) { // bg_tex_choice / bg_tex_choice3: textures chosen at run time
      struct chl_compute_pipeline *c = kernel(nt == 2 ? "bg_tex_choice" : "bg_tex_choice3");
      struct chl_texture *tx[3] = { NULL };
      static float d[3][16 * 4];
      bool ok = c != NULL;
      for (unsigned t = 0; ok && t < nt; t++) {
         for (unsigned i = 0; i < 16 * 4; i++) d[t][i] = 1000.0f * t + i;
         ok = (tx[t] = tex(125, 2, 16, 1, 1, 1, 1)) && chl_texture_replace(tx[t], 0, 0, NULL, NULL, d[t], 0, 0, why, sizeof(why)) == 0;
      }
      struct chl_buffer *k = ok ? buf(16) : NULL, *o = k ? buf(32 * 16) : NULL;
      ok = ok && o;
      unsigned bad = 0;
      for (unsigned which = 0; ok && which < nt; which++) {
         *(uint32_t *)chl_buffer_contents(k) = which;
         memset(chl_buffer_contents(o), 0, 32 * 16);
         struct binding bd = { .b = { k, o }, .nb = 2, .t = { tx[0], tx[1], tx[2] }, .nt = nt };
         ok = dispatch(c, &bd, 1, 1, 16, 1);
         const float *po = chl_buffer_contents(o);
         for (unsigned i = 0; ok && i < 16 * 4; i++) if (po[i] != d[which][i]) { if (bad++ < 3) printf("    which=%u out[%u]=%g want %g\n", which, i, po[i], d[which][i]); }
      }
      CHECK(ok && !bad, "bg_tex_choice%s %u wrong%s%s", nt == 3 ? "3" : "", bad, ok ? "" : ": ", ok ? "" : why);
      printf("  bg_tex_choice%s: %u wrong\n", nt == 3 ? "3" : "", bad);
   }
   { // bg_math against libm
      struct chl_compute_pipeline *c = kernel("bg_math");
      const unsigned n = 64;
      if (c) {
         struct chl_buffer *in = buf(n * 4), *out = buf(n * 16 * 4);
         float *pi = chl_buffer_contents(in), *po = chl_buffer_contents(out);
         for (unsigned i = 0; i < n; i++) pi[i] = -0.97f + 1.94f * i / (n - 1);
         static const char *names[16] = { "acos", "asin", "atan", "atan2", "cos", "sqrt", "rsqrt", "saturate", "pow.f16", "pow",
                                          "saturate.f16", "clamp.f16", "mix.f16", "fast pow", "pow.v3f16", "fmax" };
         struct binding bd = { .b = { in, out }, .nb = 2 };
         bool ok = dispatch(c, &bd, n / 64, 1, 64, 1);
         unsigned total = 0;
         for (unsigned i = 0; ok && i < n; i++) {
            double x = pi[i], y = pi[i] * 0.5 + 0.7, hx = x, hy = y;
            double want[16] = { acos(x), asin(x), atan(x * 3.0), atan2(x, y), cos(x * 3.0), sqrt(y), 1.0 / sqrt(y),
                                fmin(fmax(x * 2.0, 0.0), 1.0), pow(hy, 2.2), pow(y, 2.2), fmin(fmax(hx * 2.0, 0.0), 1.0),
                                fmin(fmax(hx, -0.25), 0.25), hx + (hy - hx) * 0.25, pow(y, 0.4545), pow(hy, 1.5), fmax(x, y * 0.5) };
            for (unsigned k = 0; k < 16; k++) {
               double tol = (k >= 8 && k != 9 && k != 13 && k != 15) ? 0.01 + 0.004 * fabs(want[k]) : 0.002 + 0.002 * fabs(want[k]);
               if (!(fabs(po[16 * i + k] - want[k]) <= tol)) { if (total++ < 4) printf("    %s(x=%g): %g want %g\n", names[k], x, po[16 * i + k], want[k]); }
            }
         }
         CHECK(ok && !total, "bg_math: %u wrong%s%s", total, ok ? "" : ": ", ok ? "" : why);
         printf("  bg_math: %u of %u wrong\n", total, n * 16);
      } else fail++;
   }
   { // sampling: sRGB decode (BGRA8 sRGB, ASTC 4x4 sRGB, R8 sRGB), RGBA8Unorm, R16Float
      struct chl_compute_pipeline *c = kernel("bg_tex_sample");
      struct chl_sampler_desc sd = { .normalized_coordinates = true, .lod_max = 1000.0f };
      struct chl_sampler *smp = c ? chl_sampler_create(dev, &sd, why, sizeof(why)) : NULL;
      static const unsigned fmts[5] = { 81, 186, 70, 11, 25 };
      static const char *fname[5] = { "BGRA8Unorm_sRGB", "ASTC_4x4_sRGB", "RGBA8Unorm", "R8Unorm_sRGB", "R16Float" };
      for (unsigned f = 0; smp && f < 5; f++) {
         struct chl_texture *t = tex(fmts[f], 2, 16, 16, 1, 1, 1);
         if (!t) { fail++; continue; }
         uint8_t data[16 * 16 * 4];
         size_t stride = 16 * 4;
         if (fmts[f] == 186) {
            static const uint8_t blk[16] = { 0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0xFF, 0xFF };
            for (unsigned b = 0; b < 16; b++) memcpy(data + 16 * b, blk, 16);
            stride = 4 * 16;
         } else if (fmts[f] == 11) { for (unsigned i = 0; i < 256; i++) data[i] = 128; stride = 16; }
         else if (fmts[f] == 25) { for (unsigned i = 0; i < 256; i++) { data[2 * i] = 0x00; data[2 * i + 1] = 0x38; } stride = 32; }
         else for (unsigned i = 0; i < 16 * 16 * 4; i++) data[i] = (i % 4 == 3) ? 255 : 128;
         struct chl_buffer *o = buf(16 * 16 * 16);
         bool ok = chl_texture_replace(t, 0, 0, NULL, NULL, data, stride, 0, why, sizeof(why)) == 0;
         struct binding bd = { .b = { o }, .nb = 1, .t = { t }, .nt = 1, .s = { smp }, .ns = 1 };
         ok = ok && dispatch(c, &bd, 1, 1, 16, 16);
         const float *po = chl_buffer_contents(o);
         double want = fmts[f] == 70 ? 128 / 255.0 : fmts[f] == 25 ? 0.5 :
                       (fmts[f] == 186 ? pow((0.5 + 0.055) / 1.055, 2.4) : pow((128 / 255.0 + 0.055) / 1.055, 2.4));
         bool one = fmts[f] == 11 || fmts[f] == 25;
         bool good = ok && fabs(po[0] - want) < 0.01 && (one || (fabs(po[1] - want) < 0.01 && fabs(po[2] - want) < 0.01));
         CHECK(good, "sample %s: %g %g %g %g want %g%s%s", fname[f], po[0], po[1], po[2], po[3], want, ok ? "" : ": ", ok ? "" : why);
         printf("  sample %s: %.3f %.3f %.3f %.3f (want %.3f)\n", fname[f], po[0], po[1], po[2], po[3], want);
      }
      // a view: level 1 of a 3-level RGBA32Float texture, swizzled Blue, Green, Red, One
      struct chl_texture *t = smp ? tex(125, 2, 32, 32, 3, 1, 1) : NULL;
      static float lv[32 * 32 * 4];
      bool ok = t != NULL;
      for (unsigned l = 0; ok && l < 3; l++) {
         unsigned w = 32 >> l;
         for (unsigned i = 0; i < w * w; i++) { lv[4*i] = 0.1f + l; lv[4*i+1] = 0.2f + l; lv[4*i+2] = 0.3f + l; lv[4*i+3] = 0.5f; }
         ok = chl_texture_replace(t, l, 0, NULL, NULL, lv, 0, 0, why, sizeof(why)) == 0;
      }
      static const unsigned char swz[4] = { 4, 3, 2, 1 };
      struct chl_texture *v = ok ? chl_texture_view(t, 125, 2, 1, 1, 0, 1, swz, why, sizeof(why)) : NULL;
      struct chl_buffer *o = v ? buf(16 * 16 * 16) : NULL;
      ok = o != NULL;
      struct binding bd = { .b = { o }, .nb = 1, .t = { v }, .nt = 1, .s = { smp }, .ns = 1 };
      ok = ok && dispatch(c, &bd, 1, 1, 16, 16);
      const float *po = ok ? chl_buffer_contents(o) : NULL;
      bool good = ok && fabsf(po[0] - 1.3f) < 0.001f && fabsf(po[1] - 1.2f) < 0.001f && fabsf(po[2] - 1.1f) < 0.001f && po[3] == 1.0f;
      CHECK(good, "texture view: %g %g %g %g want 1.3 1.2 1.1 1%s%s", po ? po[0] : 0, po ? po[1] : 0, po ? po[2] : 0, po ? po[3] : 0,
            ok ? "" : ": ", ok ? "" : why);
      printf("  texture view (level 1, BGR1): %.2f %.2f %.2f %.2f\n", po ? po[0] : 0, po ? po[1] : 0, po ? po[2] : 0, po ? po[3] : 0);
   }
   { // bg_tex_write_half into RGBA16Float and RGBA8Unorm
      struct chl_compute_pipeline *c = kernel("bg_tex_write_half");
      static const unsigned fmts[2] = { 115, 70 };
      for (unsigned f = 0; c && f < 2; f++) {
         struct chl_texture *t = tex(fmts[f], 2, 16, 8, 1, 1, 3);
         uint8_t raw[16 * 8 * 8] = { 0 };
         bool ok = t && chl_texture_replace(t, 0, 0, NULL, NULL, raw, 0, 0, why, sizeof(why)) == 0;
         struct binding bd = { .t = { t }, .nt = 1 };
         ok = ok && dispatch(c, &bd, 1, 1, 16, 8) && chl_texture_get(t, 0, 0, NULL, NULL, raw, 0, 0, why, sizeof(why)) == 0;
         float got[4] = { 0 };
         if (ok && fmts[f] == 115) {
            const uint16_t *h = (const uint16_t *)raw;
            for (unsigned k = 0; k < 4; k++) { unsigned e = (h[k] >> 10) & 31, m = h[k] & 1023; got[k] = e ? ldexpf(1.0f + m / 1024.0f, (int)e - 15) : 0.0f; }
         } else if (ok) for (unsigned k = 0; k < 4; k++) got[k] = raw[k] / 255.0f;
         bool good = ok && fabsf(got[0] - 0.25f) < 0.01f && fabsf(got[1] - 0.5f) < 0.01f && fabsf(got[2] - 0.75f) < 0.01f && fabsf(got[3] - 1.0f) < 0.01f;
         CHECK(good, "bg_tex_write_half fmt %u: %g %g %g %g%s%s", fmts[f], got[0], got[1], got[2], got[3], ok ? "" : ": ", ok ? "" : why);
         printf("  bg_tex_write_half fmt %u: %.3f %.3f %.3f %.3f\n", fmts[f], got[0], got[1], got[2], got[3]);
      }
   }
   { // bg_is_null: slot 0 bound, slot 1 nothing: 0 then 1
      struct chl_compute_pipeline *c = kernel("bg_is_null");
      struct chl_texture *t = c ? tex(70, 2, 4, 4, 1, 1, 1) : NULL;
      struct chl_buffer *o = t ? buf(16) : NULL;
      bool ok = o != NULL;
      if (ok) {
         uint32_t *po = chl_buffer_contents(o); po[0] = po[1] = 7;
         struct binding bd = { .b = { o }, .nb = 1, .t = { t, NULL }, .nt = 2 };
         ok = dispatch(c, &bd, 1, 1, 1, 1);
      }
      const uint32_t *po = ok ? chl_buffer_contents(o) : NULL;
      CHECK(ok && po[0] == 0 && po[1] == 1, "bg_is_null: %u %u want 0 1%s%s", po ? po[0] : 9, po ? po[1] : 9, ok ? "" : ": ", ok ? "" : why);
      printf("  bg_is_null: bound %u unbound %u (want 0 1)\n", po ? po[0] : 9, po ? po[1] : 9);
   }
   { // one command buffer, five dispatches of bg_add with five threadgroup sizes, then three dependent bg_copy
      struct chl_compute_pipeline *add = kernel("bg_add"), *copy = kernel("bg_copy");
      enum { N = 4096 };
      struct chl_buffer *a = buf(N * 4), *b = buf(N * 4), *n = buf(16), *out[5], *v[4];
      for (unsigned k = 0; k < 5; k++) out[k] = buf(N * 4);
      for (unsigned k = 0; k < 4; k++) v[k] = buf(N * 4);
      float *pa = chl_buffer_contents(a), *pb = chl_buffer_contents(b);
      for (unsigned i = 0; i < N; i++) { pa[i] = (float)i; pb[i] = 1000.0f; }
      *(uint32_t *)chl_buffer_contents(n) = N;
      uint32_t *v0 = chl_buffer_contents(v[0]);
      for (unsigned i = 0; i < N; i++) v0[i] = 0x9e3779b9u * (i + 1);
      for (unsigned k = 1; k < 4; k++) memset(chl_buffer_contents(v[k]), 0, N * 4);
      struct chl_cmdbuf *cb = chl_cmdbuf_create(dev, why, sizeof(why));
      chl_compute_begin(cb);
      bool ok = add && copy;
      static const unsigned sizes[5] = { 64, 32, 128, 16, 256 };
      chl_set_compute_pipeline(cb, add);
      for (unsigned k = 0; ok && k < 5; k++) {
         chl_set_buffer(cb, 0, 0, a, 0); chl_set_buffer(cb, 0, 1, b, 0); chl_set_buffer(cb, 0, 2, out[k], 0); chl_set_buffer(cb, 0, 3, n, 0);
         unsigned g[3] = { N / sizes[k], 1, 1 }, l[3] = { sizes[k], 1, 1 };
         ok = chl_dispatch(cb, g, l, why, sizeof(why)) == 0;
      }
      chl_set_compute_pipeline(cb, copy);
      for (unsigned k = 0; ok && k < 3; k++) {
         chl_set_buffer(cb, 0, 0, v[k], 0); chl_set_buffer(cb, 0, 1, v[k + 1], 0); chl_set_buffer(cb, 0, 2, n, 0);
         unsigned g[3] = { N / 64, 1, 1 }, l[3] = { 64, 1, 1 };
         ok = chl_dispatch(cb, g, l, why, sizeof(why)) == 0;
      }
      chl_compute_end(cb);
      double t0 = now_ms();
      ok = ok && chl_cmdbuf_commit(cb, NULL, NULL, why, sizeof(why)) == 0 && chl_cmdbuf_wait(cb, why, sizeof(why)) == 0;
      double t1 = now_ms();
      chl_cmdbuf_release(cb);
      unsigned bad = 0;
      for (unsigned k = 0; ok && k < 5; k++) {
         const float *po = chl_buffer_contents(out[k]);
         for (unsigned i = 0; i < N; i++) if (po[i] != 2000.0f + (float)i) bad++;
      }
      const uint32_t *pd = chl_buffer_contents(v[3]);
      for (unsigned i = 0; ok && i < N; i++) if (pd[i] != v0[i]) bad++;
      CHECK(ok && !bad, "8 dispatches in one command buffer: %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why);
      printf("  8 dispatches in one command buffer (5 sizes, 3 dependent copies): %u wrong, GPU %.2f ms\n", bad, t1 - t0);
   }
   for (unsigned sel = 0; sel < 2; sel++) { // bg_ptr_walk / bg_ptr_select_walk
      struct chl_compute_pipeline *c = kernel(sel ? "bg_ptr_select_walk" : "bg_ptr_walk");
      enum { G = 64, T = 4 };
      struct chl_buffer *in = c ? buf((G + 1 + 8 * T) * 4) : NULL, *out = in ? buf(G * 4) : NULL, *n = out ? buf(16) : NULL;
      bool ok = n != NULL;
      unsigned bad = 0;
      if (ok) {
         float *pi = chl_buffer_contents(in);
         for (unsigned i = 0; i < G + 1 + 8 * T; i++) pi[i] = (float)i;
         memset(chl_buffer_contents(out), 0, G * 4);
         *(uint32_t *)chl_buffer_contents(n) = T;
         struct binding bd = { .b = { in, out, n }, .nb = 3 };
         ok = dispatch(c, &bd, G / 32, 1, 32, 1);
         const float *po = chl_buffer_contents(out);
         for (unsigned g = 0; ok && g < G; g++) if (po[g] != 4.0f * (g + (sel ? (g & 1) : 0)) + 48.0f) bad++;
      }
      CHECK(ok && !bad, "%s: %u wrong%s%s", sel ? "bg_ptr_select_walk" : "bg_ptr_walk", bad, ok ? "" : ": ", ok ? "" : why);
      printf("  %s: %u wrong of %u\n", sel ? "bg_ptr_select_walk" : "bg_ptr_walk", bad, (unsigned)G);
   }
}

/* ---- render ---- */
static bool
clear_pass(struct chl_texture *t, unsigned level, const float rgba[4], struct chl_texture *resolve)
{
   struct chl_cmdbuf *cb = chl_cmdbuf_create(dev, why, sizeof(why));
   if (!cb) return false;
   struct chl_render_pass rp = { 0 };
   rp.color[0] = (struct chl_attachment){ .texture = t, .level = level, .load_action = 2, .store_action = resolve ? 2 : 1,
                                          .resolve = resolve };
   memcpy(rp.color[0].clear, rgba, 16);
   bool ok = chl_render_begin(cb, &rp, why, sizeof(why)) == 0;
   chl_render_end(cb);
   ok = ok && chl_cmdbuf_commit(cb, NULL, NULL, why, sizeof(why)) == 0 && chl_cmdbuf_wait(cb, why, sizeof(why)) == 0;
   chl_cmdbuf_release(cb);
   return ok;
}

static struct chl_render_pipeline *
render_pipeline(const char *vs, const char *fs, unsigned fmt, bool blend)
{
   size_t vsz, fsz;
   const uint8_t *vb = fn_of(rlib, rlib_size, vs, &vsz), *fb = fn_of(rlib, rlib_size, fs, &fsz);
   if (!vb || !fb) { printf("  no %s / %s\n", vs, fs); return NULL; }
   struct chl_render_pipeline_desc d = { 0 };
   d.vertex = (struct chl_function){ vb, vsz, vs, NULL, 0 };
   d.fragment = (struct chl_function){ fb, fsz, fs, NULL, 0 };
   d.color_format[0] = fmt;
   d.blend[0] = (struct chl_blend){ blend, 0, 0, 1, 5, 1, 5, 0xf };
   d.sample_count = 1;
   double t0 = now_ms();
   struct chl_render_pipeline *p = chl_render_pipeline_create(dev, &d, NULL, why, sizeof(why));
   if (!p) printf("  pipeline %s + %s: %s\n", vs, fs, why);
   else printf("  pipeline %s + %s in %.1f ms\n", vs, fs, now_ms() - t0);
   return p;
}

static void
test_render(void)
{
   { // RGB10A2Unorm clears: red is bits 0-9
      struct chl_texture *t = tex(90, 2, 4, 4, 1, 1, 5);
      static const float vals[2][4] = { { 1, 0, 0, 1 }, { 0, 0, 1, 0 } };
      uint32_t px[16], got[2] = { 0 };
      bool ok = t != NULL;
      for (unsigned k = 0; ok && k < 2; k++) {
         ok = clear_pass(t, 0, vals[k], NULL) && chl_texture_get(t, 0, 0, NULL, NULL, px, 0, 0, why, sizeof(why)) == 0;
         got[k] = px[5];
      }
      CHECK(ok && got[0] == 0xC00003FFu && got[1] == 0x3FF00000u, "RGB10A2Unorm: 0x%08x 0x%08x%s%s", got[0], got[1], ok ? "" : ": ", ok ? "" : why);
      printf("  RGB10A2Unorm clear: red 0x%08x blue 0x%08x (want 0xC00003FF 0x3FF00000)\n", got[0], got[1]);
   }
   for (unsigned srgb = 0; srgb < 2; srgb++) { // 4x multisample clear resolved into a single-sample texture
      struct chl_texture *tm = tex(srgb ? 81 : 80, 4, 64, 32, 1, 4, 4), *ts = tm ? tex(srgb ? 81 : 80, 2, 64, 32, 1, 1, 5) : NULL;
      static const float c[2][4] = { { 1.0f, 0.5f, 0.25f, 1.0f }, { 0.5f, 0.5f, 0.5f, 1.0f } };
      static uint8_t got[64 * 32 * 4];
      bool ok = ts && clear_pass(tm, 0, c[srgb], ts) && chl_texture_get(ts, 0, 0, NULL, NULL, got, 0, 0, why, sizeof(why)) == 0;
      unsigned bad = 0;
      for (unsigned i = 0; ok && i < 64 * 32; i++) {
         const uint8_t *q = got + 4 * i;   /* BGRA */
         bool good = srgb ? (q[0] >= 186 && q[0] <= 190) : (q[2] == 255 && q[1] >= 126 && q[1] <= 129 && q[0] >= 62 && q[0] <= 65 && q[3] == 255);
         if (!good && bad++ < 2) printf("    texel %u = %u %u %u %u\n", i, q[0], q[1], q[2], q[3]);
      }
      CHECK(ok && !bad, "%smultisample resolve: %u wrong%s%s", srgb ? "sRGB " : "", bad, ok ? "" : ": ", ok ? "" : why);
      printf("  %smultisample resolve: texel 0 = %u %u %u %u, %u wrong\n", srgb ? "sRGB " : "", got[0], got[1], got[2], got[3], bad);
   }
   { // clear mip level 1 through a view; level 0 stays
      struct chl_texture *t = tex(80, 2, 32, 16, 3, 1, 5);
      static uint8_t b0[32 * 16 * 4], l0[32 * 16 * 4], l1[16 * 8 * 4];
      memset(b0, 0x11, sizeof(b0));
      bool ok = t && chl_texture_replace(t, 0, 0, NULL, NULL, b0, 0, 0, why, sizeof(why)) == 0 &&
                chl_texture_replace(t, 1, 0, NULL, NULL, b0, 0, 0, why, sizeof(why)) == 0;
      struct chl_texture *v = ok ? chl_texture_view(t, 80, 2, 1, 1, 0, 1, NULL, why, sizeof(why)) : NULL;
      static const float red[4] = { 1, 0, 0, 1 };
      ok = v && clear_pass(v, 0, red, NULL) && chl_texture_get(t, 0, 0, NULL, NULL, l0, 0, 0, why, sizeof(why)) == 0 &&
           chl_texture_get(t, 1, 0, NULL, NULL, l1, 0, 0, why, sizeof(why)) == 0;
      unsigned bad1 = 0, bad0 = 0;
      for (unsigned i = 0; ok && i < 16 * 8; i++) if (l1[4*i+2] != 255 || l1[4*i] != 0 || l1[4*i+3] != 255) bad1++;
      for (unsigned i = 0; ok && i < 32 * 16 * 4; i++) if (l0[i] != 0x11) bad0++;
      CHECK(ok && !bad1 && !bad0, "render into level 1: %u wrong, %u changed in level 0%s%s", bad1, bad0, ok ? "" : ": ", ok ? "" : why);
      printf("  render into level 1 via a view: %u wrong in level 1, %u changed in level 0\n", bad1, bad0);
   }
   { // a triangle: bg_vs (positions and colours from buffer 0) + bg_fs_color, cleared black first, then a blended textured quad
      struct chl_render_pipeline *p = render_pipeline("bg_vs", "bg_fs_color", 80, false);
      struct chl_texture *rt = p ? tex(80, 2, 64, 64, 1, 1, 5) : NULL;
      bool ok = rt != NULL;
      float verts[3 * 8] = { -1, -1, 0, 1,  1, 0, 0, 1,    1, -1, 0, 1,  0, 1, 0, 1,    -1, 1, 0, 1,  0, 0, 1, 1 };
      if (ok) {
         struct chl_cmdbuf *cb = chl_cmdbuf_create(dev, why, sizeof(why));
         struct chl_render_pass rp = { 0 };
         rp.color[0] = (struct chl_attachment){ .texture = rt, .load_action = 2, .store_action = 1, .clear = { 0, 0, 0, 1 } };
         ok = chl_render_begin(cb, &rp, why, sizeof(why)) == 0;
         chl_set_render_pipeline(cb, p);
         chl_set_bytes(cb, CHL_STAGE_VERTEX, 0, verts, sizeof(verts));
         ok = ok && chl_draw(cb, 3, 0, 3, 1, 0, why, sizeof(why)) == 0;
         chl_render_end(cb);
         ok = ok && chl_cmdbuf_commit(cb, NULL, NULL, why, sizeof(why)) == 0 && chl_cmdbuf_wait(cb, why, sizeof(why)) == 0;
         chl_cmdbuf_release(cb);
      }
      static uint8_t px[64 * 64 * 4];
      ok = ok && chl_texture_get(rt, 0, 0, NULL, NULL, px, 0, 0, why, sizeof(why)) == 0;
      unsigned bad = 0, checked = 0;
      for (int y = 0; ok && y < 64; y++) for (int x = 0; x < 64; x++) {
         /* Metal: NDC y up, row 0 at the top */
         float nx = (x + 0.5f) / 32 - 1, ny = 1 - (y + 0.5f) / 32;
         float wg = (nx + 1) / 2, wb = (ny + 1) / 2, wr = 1 - wg - wb;
         uint8_t *q = px + (y * 64 + x) * 4;   /* BGRA */
         if (wr > 0.03f && wg > 0.03f && wb > 0.03f) {
            checked++;
            if (fabsf(q[2] - wr * 255) > 3 || fabsf(q[1] - wg * 255) > 3 || fabsf(q[0] - wb * 255) > 3) { if (bad++ < 3) printf("    (%d,%d) got %u,%u,%u want %.0f,%.0f,%.0f\n", x, y, q[2], q[1], q[0], wr * 255, wg * 255, wb * 255); }
         } else if (wr < -0.03f || wg < -0.03f || wb < -0.03f) {
            checked++;
            if (q[0] || q[1] || q[2]) { if (bad++ < 3) printf("    outside (%d,%d) %u,%u,%u\n", x, y, q[2], q[1], q[0]); }
         }
      }
      CHECK(ok && !bad && checked > 3000, "triangle: %u of %u wrong%s%s", bad, checked, ok ? "" : ": ", ok ? "" : why);
      printf("  triangle (bg_vs + bg_fs_color): %u of %u checked pixels wrong\n", bad, checked);
   }
}

static void
cfset(CFMutableDictionaryRef d, CFStringRef k, int v)
{
   CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
   CFDictionarySetValue(d, k, n);
   CFRelease(n);
}

static void
test_iosurface(void)
{
   enum { W = 64, H = 32 };
   CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
   cfset(props, kIOSurfaceWidth, W);
   cfset(props, kIOSurfaceHeight, H);
   cfset(props, kIOSurfaceBytesPerElement, 4);
   cfset(props, kIOSurfaceBytesPerRow, W * 4);
   cfset(props, kIOSurfacePixelFormat, 0x42475241 /* 'BGRA' */);
   IOSurfaceRef sf = IOSurfaceCreate(props);
   CFRelease(props);
   if (!sf) { printf("  IOSurfaceCreate failed\n"); fail++; return; }
   size_t bpr = IOSurfaceGetBytesPerRow(sf);
   IOSurfaceLock(sf, 0, NULL);
   uint8_t *base = IOSurfaceGetBaseAddress(sf);
   for (unsigned y = 0; y < H; y++)
      for (unsigned x = 0; x < W; x++) {
         uint8_t *q = base + y * bpr + 4 * x;
         q[0] = (uint8_t)(x * 4); q[1] = (uint8_t)(y * 8); q[2] = 0x55; q[3] = 0xff;
      }
   IOSurfaceUnlock(sf, 0, NULL);
   struct chl_texture_desc d = { .pixel_format = 80, .type = 2, .width = W, .height = H, .depth = 1, .array_length = 1, .mip_levels = 1,
                                 .sample_count = 1, .usage = 5 };
   struct chl_texture *t = chl_texture_from_iosurface(dev, &d, (int)IOSurfaceGetID(sf), why, sizeof(why));
   if (!t) { printf("  IOSurface import: %s\n", why); fail++; CFRelease(sf); return; }
   /* read through a kernel: what the processor wrote */
   struct chl_compute_pipeline *c = kernel("bg_tex_read");
   struct chl_buffer *o = buf(W * H * 16);
   struct binding bd = { .b = { o }, .nb = 1, .t = { t }, .nt = 1 };
   bool ok = c && o && dispatch(c, &bd, W / 16, H / 8, 16, 8);
   unsigned bad = 0;
   const float *po = ok ? chl_buffer_contents(o) : NULL;
   for (unsigned y = 0; ok && y < H; y++)
      for (unsigned x = 0; x < W; x++) {
         const float *p = po + 4 * (y * W + x);   /* RGBA */
         if (fabsf(p[2] - (x * 4) / 255.0f) > 0.002f || fabsf(p[1] - (y * 8) / 255.0f) > 0.002f || fabsf(p[0] - 0x55 / 255.0f) > 0.002f) {
            if (bad++ < 3) printf("    (%u,%u) = %g %g %g %g\n", x, y, p[0], p[1], p[2], p[3]);
         }
      }
   CHECK(ok && !bad, "IOSurface read by a kernel: %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why);
   printf("  IOSurface (%zu bytes a row) read by a kernel: %u wrong\n", bpr, bad);
   /* render into it, flush, and read it as the processor */
   static const float green[4] = { 0, 1, 0, 1 };
   ok = clear_pass(t, 0, green, NULL) && chl_texture_flush_surface(t) == 0;
   bad = 0;
   IOSurfaceLock(sf, kIOSurfaceLockReadOnly, NULL);
   for (unsigned y = 0; ok && y < H; y++)
      for (unsigned x = 0; x < W; x++) {
         const uint8_t *q = base + y * bpr + 4 * x;
         if (q[0] != 0 || q[1] != 255 || q[2] != 0 || q[3] != 255) { if (bad++ < 3) printf("    (%u,%u) = B%u G%u R%u A%u\n", x, y, q[0], q[1], q[2], q[3]); }
      }
   IOSurfaceUnlock(sf, kIOSurfaceLockReadOnly, NULL);
   CHECK(ok && !bad, "render into an IOSurface: %u wrong%s%s", bad, ok ? "" : ": ", ok ? "" : why);
   printf("  render into an IOSurface, read by the processor: %u wrong\n", bad);
   chl_texture_release(t);
   CFRelease(sf);
}

static void
bench(unsigned draws, unsigned frames)
{
   struct chl_render_pipeline *pc = render_pipeline("bg_vs", "bg_fs_color", 70, false);
   struct chl_render_pipeline *pt = render_pipeline("bg_vs", "bg_fs_tex_linear", 70, true);
   struct chl_texture *rt = tex(70, 2, 256, 256, 1, 1, 5), *t = tex(70, 2, 4, 4, 1, 1, 1);
   struct chl_sampler_desc sd = { .min_filter = 1, .mag_filter = 1, .normalized_coordinates = true };
   struct chl_sampler *s = chl_sampler_create(dev, &sd, why, sizeof(why));
   if (!pc || !pt || !rt || !t || !s) { fail++; return; }
   uint32_t green[16];
   for (int i = 0; i < 16; i++) green[i] = 0xff00ff00u;
   chl_texture_replace(t, 0, 0, NULL, NULL, green, 0, 0, why, sizeof(why));
   double enc = 0, wait = 0, encmin = 1e30;
   for (unsigned f = 0; f < frames + 3; f++) {
      double a = now_ms();
      struct chl_cmdbuf *cb = chl_cmdbuf_create(dev, why, sizeof(why));
      struct chl_render_pass rp = { 0 };
      rp.color[0] = (struct chl_attachment){ .texture = rt, .load_action = 2, .store_action = 1, .clear = { 0, 0, 1, 1 } };
      chl_render_begin(cb, &rp, why, sizeof(why));
      for (unsigned i = 0; i < draws; i++) {
         float x = -1 + 2.0f * (i % 16) / 16, y = -1 + 2.0f * (i / 16 % 16) / 16;
         float v[24] = { x, y, 0, 1,  1, 1, 1, 0.5f,   x + 0.25f, y, 0, 1,  1, 1, 1, 0.5f,   x, y + 0.25f, 0, 1,  1, 1, 1, 0.5f };
         float off[4] = { 0.01f * (i % 7), 0, 0, 0 };
         chl_set_render_pipeline(cb, (i & 1) ? pt : pc);
         chl_set_bytes(cb, CHL_STAGE_VERTEX, 0, v, sizeof(v));
         if (i & 1) {
            chl_set_bytes(cb, CHL_STAGE_FRAGMENT, 1, off, sizeof(off));
            chl_set_texture(cb, CHL_STAGE_FRAGMENT, 0, t);
            chl_set_sampler(cb, CHL_STAGE_FRAGMENT, 0, s);
         }
         if (chl_draw(cb, 3, 0, 3, 1, 0, why, sizeof(why)) != 0) { printf("  draw: %s\n", why); fail++; return; }
      }
      chl_render_end(cb);
      double b = now_ms();
      chl_cmdbuf_commit(cb, NULL, NULL, why, sizeof(why));
      chl_cmdbuf_wait(cb, why, sizeof(why));
      chl_cmdbuf_release(cb);
      double c = now_ms();
      if (f >= 3) { enc += b - a; wait += c - b; if (b - a < encmin) encmin = b - a; }
   }
   printf("bench (chl, Metal-shaped encoder over Turnip): %u frames x %u draws: encode %.3f ms/frame (min %.3f) = %.2f us/draw, "
          "commit+wait %.3f ms\n", frames, draws, enc / frames, encmin, enc / frames / draws * 1000, wait / frames);
}

int
main(int argc, char **argv)
{
   setvbuf(stdout, NULL, _IOLBF, 0);
   klib = slurp(argc > 1 ? argv[1] : "bg_kernels.metallib", &klib_size);
   rlib = slurp(argc > 2 ? argv[2] : "bg_render.metallib", &rlib_size);
   double t0 = now_ms();
   dev = chl_device_open(why, sizeof(why));
   if (!dev) { printf("chl_device_open: %s\n", why); return 3; }
   printf("device: %s (%.1f ms)\n", chl_device_name(dev), now_ms() - t0);
   if (!getenv("CHL_NO_COMPUTE")) test_compute();
   if (!getenv("CHL_NO_RENDER")) test_render();
   if (!getenv("CHL_NO_SURFACE")) test_iosurface();
   if (getenv("CHL_BENCH")) bench(200, 100);
   printf("== result: %d checks passed, %d failed\n", pass, fail);
   chl_device_close(dev);
   return fail ? 1 : 0;
}
