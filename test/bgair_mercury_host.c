// SPDX-License-Identifier: MIT
// Mac, softpipe (RWA_SOFTWARE=1): draw one Mercury vertex/fragment pair with chosen uniforms and report the pixels. Offline twin of
// bgmtl_mercury_probe, used to find out why fluidity::sdf drew nothing on the phone.
//   bgair_mercury_host mercury.metallib vertexName fragmentName out.ppm [flag]
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "air_metal.h"

static uint64_t rd64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return p[0] | p[1] << 8; }
static const uint8_t *
fn_of(const uint8_t *b, const char *want, size_t *out)
{
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

int
main(int argc, char **argv)
{
   size_t n1;
   uint8_t *lib = slurp(argv[1], &n1);
   const char *vn = argv[2], *fn = argv[3];
   int flag = argc > 5 ? atoi(argv[5]) : 0;
   char why[512] = { 0 };
   struct rwa_device *dev = rwa_device_open(why, sizeof(why));
   if (!dev) { printf("device: %s\n", why); return 3; }
   size_t vs, fs;
   const uint8_t *vb = fn_of(lib, vn, &vs), *fb = fn_of(lib, fn, &fs);
   if (!vb || !fb) { printf("functions not found\n"); return 3; }
   struct rwa_render_shape shape;
   memset(&shape, 0, sizeof(shape));
   shape.color_format[0] = 80; shape.color_count = 1; shape.sample_count = 1;
   for (int i = 0; i < 8; i++) shape.color_blend[i].write_mask = 0xf;
   shape.color_blend_count = 8;
   struct rwa_render_info info;
   memset(&info, 0, sizeof(info));
   struct rwa_render *r = rwa_render_create(dev, vb, vs, vn, fb, fs, fn, &shape, &info, why, sizeof(why));
   if (!r) { printf("rwa_render_create: %s\n", why); return 1; }
   printf("pipeline: vertex_buffers=%u fragment_buffers=%u streams=%u\n", info.vertex_buffers, info.fragment_buffers, info.vertex_streams);
   static const float quad[6 * 4] = { -1, -1, 0, 1,  1, -1, 1, 1,  -1, 1, 0, 0,  1, -1, 1, 1,  1, 1, 1, 0,  -1, 1, 0, 0 };
   struct rwa_buffer *v0 = rwa_buffer_create(dev, 65536, why, sizeof(why)), *v1 = rwa_buffer_create(dev, 65536, why, sizeof(why)),
                     *v2 = rwa_buffer_create(dev, 65536, why, sizeof(why)), *f0 = rwa_buffer_create(dev, 65536, why, sizeof(why));
   memset(rwa_buffer_map(v0), 0, 65536); memset(rwa_buffer_map(v1), 0, 65536); memset(rwa_buffer_map(v2), 0, 65536); memset(rwa_buffer_map(f0), 0, 65536);
   memcpy(rwa_buffer_map(v0), quad, sizeof(quad));
   float ident[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
   memcpy(rwa_buffer_map(v1), ident, sizeof(ident));
   float *u = rwa_buffer_map(v2);          // FluiditySDFUniforms { float, float, bool at 8, float x4 }
   u[0] = 0.5f; u[1] = 1.0f; ((uint8_t *)u)[8] = flag; u[3] = 0.1f; u[4] = 0.1f; u[5] = 0.2f; u[6] = 0.2f;
   memcpy(rwa_buffer_map(f0), u, 28);
   struct rwa_texture_shape ts = { .pixel_format = 80, .type = 2, .width = 128, .height = 128, .depth = 1, .array_length = 1, .mip_levels = 1, .sample_count = 1, .usage = 5 };
   struct rwa_texture *rt = rwa_texture_create(dev, &ts, why, sizeof(why));
   struct rwa_buffer *vbufs[4] = { v0, v1, v2, NULL };
   struct rwa_buffer *fbufs[1] = { f0 };
   struct rwa_buffer_bind vt[3] = { { v0, 0 }, { v1, 0 }, { v2, 0 } }, ft[1] = { { f0, 0 } };
   float clear[4] = { 0.75f, 0.5f, 0.25f, 1 };
   struct rwa_texture *colors[1] = { rt };
   struct rwa_draw dr;
   memset(&dr, 0, sizeof(dr));
   dr.color = colors; dr.color_count = 1; dr.clear_color = clear;
   dr.vertex = (struct rwa_bindings){ .buffers = vbufs, .buffer_count = info.vertex_buffers > 3 ? 3 : info.vertex_buffers };
   dr.fragment = (struct rwa_bindings){ .buffers = fbufs, .buffer_count = info.fragment_buffers };
   dr.primitive = 3; dr.vertex_count = 6;
   dr.vertex_buffer_table = vt; dr.vertex_buffer_table_count = 3;
   dr.fragment_buffer_table = ft; dr.fragment_buffer_table_count = 1;
   if (rwa_render_draw(r, &dr, why, sizeof(why)) != 0) { printf("draw: %s\n", why); return 1; }
   uint8_t px[128 * 128 * 4];
   unsigned o[3] = { 0, 0, 0 }, sz[3] = { 128, 128, 1 };
   rwa_texture_read(rt, 0, 0, o, sz, px, 128 * 4, why, sizeof(why));
   unsigned changed = 0;
   for (int i = 0; i < 128 * 128; i++) if (px[i*4] != 64 || px[i*4+1] != 128 || px[i*4+2] != 191) changed++;
   printf("%u of 16384 pixels differ from the clear colour; centre %u,%u,%u,%u corner %u,%u,%u,%u\n", changed, px[(64*128+64)*4+2], px[(64*128+64)*4+1], px[(64*128+64)*4], px[(64*128+64)*4+3], px[2], px[1], px[0], px[3]);
   if (argc > 4) { FILE *f = fopen(argv[4], "wb"); fprintf(f, "P6\n128 128\n255\n"); for (int i = 0; i < 128*128; i++) { fputc(px[i*4+2], f); fputc(px[i*4+1], f); fputc(px[i*4], f); } fclose(f); }
   return 0;
}
