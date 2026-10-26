// SPDX-License-Identifier: MIT
// Primitive restart: Metal's drawIndexedPrimitives always ends a strip at the largest index of the index type (0xFFFF for
// UInt16) and starts a new one. iOS 26's RenderBox (icons) draws its quads as one triangle strip split that way.
// Two red quads, left and right, as `0 1 2 3 0xFFFF 4 5 6 7`; vertex 65535 exists and sits in the gap between them, so a
// draw that takes 0xFFFF as a vertex fills the gap with the stray triangles. The gap must keep the target's fill.
//   bgair_restart_test bg_render.metallib
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

static void
vert(float *v, unsigned i, float x, float y)
{
   float *p = v + (size_t)i * 8;
   p[0] = x; p[1] = y; p[2] = 0; p[3] = 1;
   p[4] = 1; p[5] = 0; p[6] = 0; p[7] = 1;   /* red */
}

int
main(int argc, char **argv)
{
   if (argc < 2) return 2;
   size_t n;
   uint8_t *lib = slurp(argv[1], &n);
   char why[512] = { 0 };
   struct rwa_device *dev = rwa_device_open(why, sizeof(why));
   if (!dev) { printf("device: %s\n", why); return 3; }
   size_t vs, fs;
   const uint8_t *vb = fn_of(lib, "bg_vs", &vs), *fb = fn_of(lib, "bg_fs_color", &fs);
   if (!vb || !fb) { printf("functions not found\n"); return 3; }
   struct rwa_render_shape shape;
   memset(&shape, 0, sizeof(shape));
   shape.color_format[0] = 80; shape.color_count = 1; shape.sample_count = 1;
   for (int i = 0; i < 8; i++) shape.color_blend[i].write_mask = 0xf;
   shape.color_blend_count = 8;
   struct rwa_render_info info;
   memset(&info, 0, sizeof(info));
   struct rwa_render *r = rwa_render_create(dev, vb, vs, "bg_vs", fb, fs, "bg_fs_color", &shape, &info, why, sizeof(why));
   if (!r) { printf("rwa_render_create: %s\n", why); return 1; }

   /* 65536 vertices, so index 65535 is a real one: in the middle of the gap */
   size_t vbytes = 65536 * 8 * sizeof(float);
   struct rwa_buffer *vbuf = rwa_buffer_create(dev, vbytes, why, sizeof(why));
   if (!vbuf) { printf("buffer: %s\n", why); return 3; }
   float *v = rwa_buffer_map(vbuf);
   memset(v, 0, vbytes);
   vert(v, 0, -1.0f, -1.0f); vert(v, 1, -1.0f, 1.0f); vert(v, 2, -0.5f, -1.0f); vert(v, 3, -0.5f, 1.0f);
   vert(v, 4, 0.5f, -1.0f);  vert(v, 5, 0.5f, 1.0f);  vert(v, 6, 1.0f, -1.0f);  vert(v, 7, 1.0f, 1.0f);
   vert(v, 65535, 0.0f, 0.0f);
   static const uint16_t idx[9] = { 0, 1, 2, 3, 0xffff, 4, 5, 6, 7 };
   struct rwa_buffer *ib = rwa_buffer_create(dev, sizeof(idx), why, sizeof(why));
   memcpy(rwa_buffer_map(ib), idx, sizeof(idx));

   struct rwa_texture_shape ts = { .pixel_format = 80, .type = 2, .width = 32, .height = 16, .depth = 1, .array_length = 1, .mip_levels = 1, .sample_count = 1, .usage = 5 };
   struct rwa_texture *t = rwa_texture_create(dev, &ts, why, sizeof(why));
   static uint8_t fill[32 * 16 * 4];
   memset(fill, 0x11, sizeof(fill));
   unsigned o[3] = { 0, 0, 0 }, s0[3] = { 32, 16, 1 };
   if (!t || rwa_texture_write(t, 0, 0, o, s0, fill, 0, why, sizeof(why))) { printf("texture: %s\n", why); return 3; }
   struct rwa_texture *colors[1] = { t };
   struct rwa_buffer *vbufs[1] = { vbuf };
   struct rwa_buffer_bind vt[1] = { { vbuf, 0 } };
   struct rwa_draw dr;
   memset(&dr, 0, sizeof(dr));
   dr.color = colors; dr.color_count = 1;
   dr.vertex = (struct rwa_bindings){ .buffers = vbufs, .buffer_count = 1 };
   dr.primitive = 4;   /* MTLPrimitiveTypeTriangleStrip */
   dr.vertex_count = 9;
   dr.index_buffer = ib; dr.index_type = 0;   /* UInt16 */
   dr.vertex_buffer_table = vt; dr.vertex_buffer_table_count = 1;
   if (rwa_render_draw(r, &dr, why, sizeof(why)) != 0 || rwa_finish(dev, why, sizeof(why)) != 0) { printf("draw: %s\n", why); return 1; }
   static uint8_t px[32 * 16 * 4];
   rwa_texture_read(t, 0, 0, o, s0, px, 0, why, sizeof(why));
   const uint8_t *left = px + (8 * 32 + 2) * 4, *gap = px + (8 * 32 + 16) * 4, *right = px + (8 * 32 + 29) * 4;
   printf("restart: left %u %u %u, gap %u %u %u, right %u %u %u (want red, 17 17 17, red)\n", left[0], left[1], left[2],
          gap[0], gap[1], gap[2], right[0], right[1], right[2]);
   return !(left[2] == 255 && right[2] == 255 && gap[2] == 0x11 && gap[0] == 0x11);
}
