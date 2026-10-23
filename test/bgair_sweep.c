// SPDX-License-Identifier: MIT
// Every fragment function of a .metallib drawn once through libbgair (no Metal objects): the C twin of bgmtl_ca_probe, so that the same
// sweep runs on the Mac (RWA_SOFTWARE=1, softpipe or the reference screen) and its output is comparable line for line with the phone's.
// Same inputs as bgmtl_ca_probe: 32x32 BGRA8 target cleared to (.25,.5,.75,1), 256 KB buffers, the declared textures as 8x8, a linear sampler.
//   bgair_sweep LIB.mtlb OUT.tsv [--only NAME] [--names LIST]
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "air_metal.h"

static uint64_t rd64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return p[0] | p[1] << 8; }

struct fn { char name[128]; int type; const uint8_t *bc; size_t size; };
static struct fn fns[1024];
static unsigned nfn;

static void
parse(const uint8_t *b, size_t size)
{
   uint64_t funcs = rd64(b + 0x18), bc_off = rd64(b + 0x48);
   const uint8_t *p = b + funcs;
   uint32_t count = rd32(p);
   p += 4;
   for (uint32_t i = 0; i < count && nfn < 1024; i++) {
      uint32_t len = rd32(p);
      const uint8_t *q = p + 4, *end = p + len;
      struct fn *f = &fns[nfn];
      memset(f, 0, sizeof(*f));
      f->type = -1;
      uint64_t off = 0, sz = 0;
      while (q + 6 <= end && memcmp(q, "ENDT", 4)) {
         uint16_t vlen = rd16(q + 4);
         const uint8_t *v = q + 6;
         if (!memcmp(q, "NAME", 4)) memcpy(f->name, v, vlen < 127 ? vlen : 127);
         else if (!memcmp(q, "TYPE", 4) && vlen >= 1) f->type = v[0];
         else if (!memcmp(q, "OFFT", 4) && vlen >= 24) off = rd64(v + 16);
         else if (!memcmp(q, "MDSZ", 4) && vlen >= 8) sz = rd64(v);
         q = v + vlen;
      }
      f->bc = b + bc_off + off; f->size = sz;
      nfn++;
      p = end;
   }
   (void)size;
}

static void
fill_pattern(void *dst, size_t bytes, int seed)
{
   float *f = dst;
   for (size_t w = 0; w < bytes / 4; w++) f[w] = (float)(((int)((w * 13 + seed) % 29)) - 14) / 4.0f;
}

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

int
main(int argc, char **argv)
{
   if (argc < 3) { fprintf(stderr, "usage: bgair_sweep lib.mtlb out.tsv [--only NAME]\n"); return 2; }
   const char *only = NULL;
   for (int i = 3; i < argc; i++) if (!strcmp(argv[i], "--only") && i + 1 < argc) only = argv[++i];
   FILE *f = fopen(argv[1], "rb");
   if (!f) { perror(argv[1]); return 2; }
   fseek(f, 0, SEEK_END); size_t n = ftell(f); fseek(f, 0, SEEK_SET);
   uint8_t *data = malloc(n);
   if (fread(data, 1, n, f) != n) return 2;
   fclose(f);
   parse(data, n);
   char why[512] = { 0 };
   struct rwa_device *dev = rwa_device_open(why, sizeof(why));
   if (!dev) { fprintf(stderr, "device: %s\n", why); return 3; }
   FILE *out = fopen(argv[2], only ? "a" : "w");
   enum { W = 32 };
   struct rwa_texture_shape rs = { .pixel_format = getenv("BGCA_FLOAT") ? 125 : 80, .type = 2, .width = W, .height = W, .depth = 1, .array_length = 1, .mip_levels = 1, .sample_count = 1, .usage = 5 };
   struct rwa_texture *rt = rwa_texture_create(dev, &rs, why, sizeof(why));
   struct rwa_sampler_state ss = { .address = { 0, 0, 0 }, .min_filter = 1, .mag_filter = 1, .normalized_coordinates = 1, .lod_max = 1000 };
   struct rwa_sampler *smp = rwa_sampler_create(dev, &ss, why, sizeof(why));
   if (!rt || !smp) { fprintf(stderr, "setup: %s\n", why); return 3; }
   for (unsigned fi = 0; fi < nfn; fi++) {
      struct fn *fn = &fns[fi];
      if (fn->type != 1) continue;
      if (only && strcmp(only, fn->name)) continue;
      struct rwa_render_shape shape;
      memset(&shape, 0, sizeof(shape));
      shape.color_format[0] = getenv("BGCA_FLOAT") ? 125 : 80; shape.color_count = 1; shape.sample_count = 1;
      for (int i = 0; i < 8; i++) shape.color_blend[i].write_mask = 0xf;
      shape.color_blend_count = 8;
      struct rwa_render_info info;
      memset(&info, 0, sizeof(info));
      struct rwa_render *r = rwa_render_create(dev, NULL, 0, NULL, fn->bc, fn->size, fn->name, &shape, &info, why, sizeof(why));
      if (!r) {
         for (char *c = why; *c; c++) if (*c == '\n' || *c == '\t') *c = ' ';
         fprintf(out, "%s\trefused\t%s\t0\n", fn->name, why);
         continue;
      }
      struct rwa_buffer *bufs[32] = { NULL };
      for (unsigned i = 0; i < info.fragment_buffers && i < 32; i++) {
         bufs[i] = rwa_buffer_create(dev, 262144, why, sizeof(why));
         fill_pattern(rwa_buffer_map(bufs[i]), 262144, 5 + i);
      }
      struct rwa_texture_decl decls[16];
      unsigned nd = 0;
      struct rwa_texture *texs[16] = { NULL };
      const char *skip = NULL;
      if (info.fragment_textures && rwa_module_textures(dev, fn->bc, fn->size, fn->name, decls, 16, &nd, why, sizeof(why)) != 0) skip = "textures";
      for (unsigned i = 0; !skip && i < nd; i++) {
         struct rwa_texture_decl *t = &decls[i];
         if (t->index >= 16) { skip = "slot"; break; }
         unsigned pf = t->element == RWA_ELEMENT_INT ? 124 : t->element == RWA_ELEMENT_UINT ? 123 : 70, bpt = pf == 70 ? 4 : 16;
         struct rwa_texture_shape ts = { .pixel_format = pf, .type = 2, .width = 8, .height = 8, .depth = 1, .array_length = 1, .mip_levels = 1, .sample_count = 1,
                                         .usage = 1 | (t->usage & 2) };
         unsigned slices = 1, depth = 1;
         switch (t->type_known ? t->type : 2) {
         case 2: break;
         case 3: ts.type = 3; ts.array_length = 2; slices = 2; break;
         case 5: ts.type = 5; slices = 6; break;
         case 7: ts.type = 7; ts.depth = 4; depth = 4; break;
         default: skip = "texture type"; break;
         }
         if (skip) break;
         texs[t->index] = rwa_texture_create(dev, &ts, why, sizeof(why));
         if (!texs[t->index]) { skip = "texture creation"; break; }
         size_t bytes = 8 * 8 * depth * bpt;
         uint8_t *px = malloc(bytes);
         fill_pattern(px, bytes, 3 + t->index);
         if (pf == 70) for (size_t k = 0; k < bytes; k++) px[k] = (uint8_t)(px[k] * 3 + k);
         else { uint32_t *u = (uint32_t *)px; for (size_t k = 0; k < 8 * 8 * depth * 4; k++) u[k] = (uint32_t)(k % 7) + 1; }
         unsigned o[3] = { 0, 0, 0 }, sz[3] = { 8, 8, depth };
         for (unsigned sl = 0; sl < slices; sl++) rwa_texture_write(texs[t->index], 0, sl, o, sz, px, 8 * bpt, why, sizeof(why));
         free(px);
      }
      if (skip) { fprintf(out, "%s\tskipped\t%s\t0\n", fn->name, skip); rwa_render_destroy(r); continue; }
      struct rwa_sampler *smps[16];
      unsigned nsmp = info.fragment_samplers;
      for (unsigned i = 0; i < 16; i++) if (texs[i] && i + 1 > nsmp) nsmp = i + 1;
      for (unsigned i = 0; i < 16; i++) smps[i] = smp;
      struct rwa_buffer_bind ft[32] = { { NULL, 0 } };
      for (unsigned i = 0; i < info.fragment_buffers && i < 32; i++) ft[i].buffer = bufs[i];
      unsigned ntex = 0;
      for (unsigned i = 0; i < 16; i++) if (texs[i]) ntex = i + 1;
      float clear[4] = { 0.25f, 0.5f, 0.75f, 1.0f };
      struct rwa_texture *colors[1] = { rt };
      struct rwa_draw dr;
      memset(&dr, 0, sizeof(dr));
      dr.color = colors; dr.color_count = 1; dr.clear_color = clear;
      dr.fragment = (struct rwa_bindings){ .buffers = bufs, .buffer_count = info.fragment_buffers, .textures = texs, .texture_count = ntex, .samplers = smps, .sampler_count = nsmp };
      dr.primitive = 4; dr.vertex_count = 4;
      dr.fragment_buffer_table = ft; dr.fragment_buffer_table_count = info.fragment_buffers;
      double t0 = now_ms();
      int rc = rwa_render_draw(r, &dr, why, sizeof(why));
      double ms = now_ms() - t0;
      if (rc != 0) {
         for (char *c = why; *c; c++) if (*c == '\n' || *c == '\t') *c = ' ';
         fprintf(out, "%s\tfailed\t%s\t%.1f\n", fn->name, why, ms);
      } else {
         if (getenv("BGCA_FLOAT")) {
            float fp[W * W * 4];
            unsigned fo[3] = { 0, 0, 0 }, fsz[3] = { W, W, 1 };
            rwa_texture_read(rt, 0, 0, fo, fsz, fp, W * 16, why, sizeof(why));
            fprintf(out, "%s\tdrawn\t%.6g,%.6g,%.6g,%.6g\t%.1f\n", fn->name, fp[0], fp[1], fp[2], fp[3], ms);
            goto next;
         }
         uint8_t px[W * W * 4];
         unsigned o[3] = { 0, 0, 0 }, sz[3] = { W, W, 1 };
         rwa_texture_read(rt, 0, 0, o, sz, px, W * 4, why, sizeof(why));
         fprintf(out, "%s\tdrawn\t", fn->name);
         for (size_t i = 0; i < sizeof(px); i++) fprintf(out, "%02x", px[i]);
         fprintf(out, "\t%.1f\n", ms);
      }
next:
      fflush(out);
      for (unsigned i = 0; i < 16; i++) if (texs[i]) rwa_texture_destroy(texs[i]);
      for (unsigned i = 0; i < 32; i++) if (bufs[i]) rwa_buffer_destroy(bufs[i]);
      rwa_render_destroy(r);
   }
   fclose(out);
   return 0;
}
