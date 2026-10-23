// SPDX-License-Identifier: MIT
// libbgair without Metal: AIR function of a .metallib -> Mesa (AIR frontend, ir3) -> compute on freedreno, results checked on the CPU.
// Layer-isolating companion of bgmtl_probe: if this passes and the probe does not, the fault is in the _MTLDevice layer.
// The same source builds for the Mac (RWA_SOFTWARE=1 runs softpipe, a reference for the expected numbers) and for the phone.
//   bgair_test FILE.metallib
// The MTLB container reader is the format of the frontend's air_metallib.c (MIT, Copyright 2026 Darwin on redwood contributors).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "air_metal.h"

static int pass, fail;
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
   printf("== result: %d checks passed, %d failed\n", pass, fail);
   rwa_device_close(dev);
   return fail ? 1 : 0;
}
