// SPDX-License-Identifier: MIT
// Stencil, then cover -- how iOS 26's RenderBox fills an icon glyph's path: a pipeline with NO fragment function writes only
// stencil (Invert) for a triangle into a Depth32Float_Stencil8 attachment, then a colour pipeline draws a full-screen red
// triangle where the stencil is not zero. The lower-left half must come out red, the upper-right keep the target's fill.
//   bgair_stencil_test bg_render.metallib
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
   shape.depth_format = 260; shape.stencil_format = 260;   /* Depth32Float_Stencil8 */
   for (int i = 0; i < 8; i++) shape.color_blend[i].write_mask = 0xf;
   shape.color_blend_count = 8;
   struct rwa_render_info info;
   memset(&info, 0, sizeof(info));
   struct rwa_render *mark = rwa_render_create(dev, vb, vs, "bg_vs", NULL, 0, NULL, &shape, &info, why, sizeof(why));
   if (!mark) { printf("stencil-only pipeline: %s\n", why); return 1; }
   struct rwa_render *cover = rwa_render_create(dev, vb, vs, "bg_vs", fb, fs, "bg_fs_color", &shape, &info, why, sizeof(why));
   if (!cover) { printf("cover pipeline: %s\n", why); return 1; }

   /* Always/Invert writing every bit, then NotEqual 0 reading it; depth Always, not written */
   struct rwa_depth_stencil_state st;
   memset(&st, 0, sizeof(st));
   st.depth_compare_function = 7;
   st.front = st.back = (struct rwa_stencil_face){ 7, 0, 0, 5, 0xff, 0xff };
   struct rwa_depth_stencil *inv = rwa_depth_stencil_create(dev, &st, why, sizeof(why));
   st.front = st.back = (struct rwa_stencil_face){ 5, 0, 0, 0, 0xff, 0 };
   struct rwa_depth_stencil *test = rwa_depth_stencil_create(dev, &st, why, sizeof(why));
   if (!inv || !test) { printf("depth/stencil state: %s\n", why); return 1; }

   float verts[6 * 8];
   vert(verts, 0, -1, -1); vert(verts, 1, 1, -1); vert(verts, 2, -1, 1);    /* the lower-left half */
   vert(verts, 3, -1, -1); vert(verts, 4, 3, -1); vert(verts, 5, -1, 3);    /* everything */
   struct rwa_buffer *vbuf = rwa_buffer_create(dev, sizeof(verts), why, sizeof(why));
   memcpy(rwa_buffer_map(vbuf), verts, sizeof(verts));

   struct rwa_texture_shape ts = { .pixel_format = 80, .type = 2, .width = 32, .height = 16, .depth = 1, .array_length = 1, .mip_levels = 1, .sample_count = 1, .usage = 5 };
   struct rwa_texture *t = rwa_texture_create(dev, &ts, why, sizeof(why));
   ts.pixel_format = 260; ts.usage = 4;
   struct rwa_texture *ds = rwa_texture_create(dev, &ts, why, sizeof(why));
   if (!t || !ds) { printf("textures: %s\n", why); return 3; }
   static uint8_t fill[32 * 16 * 4];
   memset(fill, 0x11, sizeof(fill));
   unsigned o[3] = { 0, 0, 0 }, s0[3] = { 32, 16, 1 };
   if (rwa_texture_write(t, 0, 0, o, s0, fill, 0, why, sizeof(why))) { printf("texture: %s\n", why); return 3; }

   struct rwa_texture *colors[1] = { t };
   struct rwa_buffer *vbufs[1] = { vbuf };
   struct rwa_buffer_bind vt[1] = { { vbuf, 0 } };
   static const unsigned zero = 0;
   static const float one = 1.0f;
   struct rwa_draw dr;
   memset(&dr, 0, sizeof(dr));
   dr.color = colors; dr.color_count = 1;
   dr.depth = ds; dr.clear_stencil = &zero; dr.clear_depth = &one;
   dr.depth_stencil = inv;
   dr.vertex = (struct rwa_bindings){ .buffers = vbufs, .buffer_count = 1 };
   dr.primitive = 3; dr.vertex_start = 0; dr.vertex_count = 3;
   dr.vertex_buffer_table = vt; dr.vertex_buffer_table_count = 1;
   if (rwa_render_draw(mark, &dr, why, sizeof(why)) != 0) { printf("stencil draw: %s\n", why); return 1; }
   dr.clear_stencil = NULL; dr.clear_depth = NULL;
   dr.depth_stencil = test;
   dr.vertex_start = 3;
   if (rwa_render_draw(cover, &dr, why, sizeof(why)) != 0 || rwa_finish(dev, why, sizeof(why)) != 0) { printf("cover draw: %s\n", why); return 1; }
   static uint8_t px[32 * 16 * 4];
   rwa_texture_read(t, 0, 0, o, s0, px, 0, why, sizeof(why));
   const uint8_t *ll = px + (14 * 32 + 2) * 4, *ur = px + (1 * 32 + 29) * 4;
   printf("stencil then cover: lower left %u %u %u %u, upper right %u %u %u %u (want 0 0 255 255, 17 17 17 17)\n",
          ll[0], ll[1], ll[2], ll[3], ur[0], ur[1], ur[2], ur[3]);
   return !(ll[2] == 255 && ll[0] == 0 && ur[2] == 0x11 && ur[0] == 0x11);
}
