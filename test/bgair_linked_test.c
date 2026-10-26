// SPDX-License-Identifier: MIT
// A linked [[visible]] function (bg_linked_caller.metal calls custom_fn, which only bg_linked_callee.metal defines):
// without the linked function the pipeline is refused; with it, a red triangle over a green texture comes out cyan
// (custom_fn moves red to blue and reads green from the texture through its own constexpr sampler). iOS 26's RenderBox
// builds its icon pipelines this way.
//   bgair_linked_test bg_linked.metallib bg_render.metallib
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
   if (argc < 3) return 2;
   size_t n, n2;
   uint8_t *lib = slurp(argv[1], &n), *rlib = slurp(argv[2], &n2);
   char why[512] = { 0 };
   struct rwa_device *dev = rwa_device_open(why, sizeof(why));
   if (!dev) { printf("device: %s\n", why); return 3; }
   size_t vs, fs, ls;
   const uint8_t *vb = fn_of(rlib, "bg_vs", &vs), *fb = fn_of(lib, "bg_fs_linked", &fs), *lb = fn_of(lib, "custom_fn", &ls);
   if (!vb || !fb || !lb) { printf("functions not found\n"); return 3; }
   struct rwa_render_shape shape;
   memset(&shape, 0, sizeof(shape));
   shape.color_format[0] = 80; shape.color_count = 1; shape.sample_count = 1;
   for (int i = 0; i < 8; i++) shape.color_blend[i].write_mask = 0xf;
   shape.color_blend_count = 8;
   struct rwa_render_info info;
   memset(&info, 0, sizeof(info));
   struct rwa_render *r = rwa_render_create(dev, vb, vs, "bg_vs", fb, fs, "bg_fs_linked", &shape, &info, why, sizeof(why));
   if (r) { printf("created without the linked function\n"); return 1; }
   printf("refused without it: %s\n", why);
   const struct rwa_linked_function lk = { lb, ls, "custom_fn" };
   rwa_device_set_linked_functions(dev, NULL, 0, &lk, 1);
   r = rwa_render_create(dev, vb, vs, "bg_vs", fb, fs, "bg_fs_linked", &shape, &info, why, sizeof(why));
   if (!r) { printf("rwa_render_create: %s\n", why); return 1; }
   /* a full-screen triangle in red (BGRA8: colour 0 gets red, colour 1 the swizzled .bgra, blue) */
   float verts[3 * 8] = { -1, -1, 0, 1,  1, 0, 0, 1,   3, -1, 0, 1,  1, 0, 0, 1,   -1, 3, 0, 1,  1, 0, 0, 1 };
   struct rwa_buffer *vbuf = rwa_buffer_create(dev, sizeof(verts), why, sizeof(why));
   memcpy(rwa_buffer_map(vbuf), verts, sizeof(verts));
   struct rwa_texture_shape ts = { .pixel_format = 80, .type = 2, .width = 32, .height = 16, .depth = 1, .array_length = 1, .mip_levels = 2, .sample_count = 1, .usage = 5 };
   struct rwa_texture *pyr = rwa_texture_create(dev, &ts, why, sizeof(why));
   ts.mip_levels = 1;
   struct rwa_texture *full = rwa_texture_create(dev, &ts, why, sizeof(why));
   static uint8_t fill[32 * 16 * 4];
   memset(fill, 0x11, sizeof(fill));
   unsigned o[3] = { 0, 0, 0 }, s0[3] = { 32, 16, 1 }, s1[3] = { 16, 8, 1 };
   if (!pyr || !full || rwa_texture_write(pyr, 0, 0, o, s0, fill, 0, why, sizeof(why)) || rwa_texture_write(pyr, 1, 0, o, s1, fill, 0, why, sizeof(why)) ||
       rwa_texture_write(full, 0, 0, o, s0, fill, 0, why, sizeof(why))) { printf("textures: %s\n", why); return 3; }
   static uint8_t green[32 * 16 * 4];
   for (unsigned i = 0; i < 32 * 16; i++) { green[4 * i + 1] = 255; green[4 * i + 3] = 255; }
   if (rwa_texture_write(pyr, 0, 0, o, s0, green, 0, why, sizeof(why))) { printf("textures: %s\n", why); return 3; }
   struct rwa_texture *colors[1] = { full }, *srcs[1] = { pyr };
   struct rwa_buffer *vbufs[1] = { vbuf };
   struct rwa_buffer_bind vt[1] = { { vbuf, 0 } };
   struct rwa_draw dr;
   memset(&dr, 0, sizeof(dr));
   dr.color = colors; dr.color_count = 1;
   dr.vertex = (struct rwa_bindings){ .buffers = vbufs, .buffer_count = 1 };
   dr.fragment = (struct rwa_bindings){ .textures = srcs, .texture_count = 1 };
   dr.primitive = 3; dr.vertex_count = 3;
   dr.vertex_buffer_table = vt; dr.vertex_buffer_table_count = 1;
   if (rwa_render_draw(r, &dr, why, sizeof(why)) != 0 || rwa_finish(dev, why, sizeof(why)) != 0) { printf("draw: %s\n", why); return 1; }
   static uint8_t f0[32 * 16 * 4];
   rwa_texture_read(full, 0, 0, o, s0, f0, 0, why, sizeof(why));
   printf("linked function drawn: pixel 0 = %u %u %u %u (want cyan: 255 255 0 255)\n", f0[0], f0[1], f0[2], f0[3]);
   return !(f0[0] == 255 && f0[1] == 255 && f0[2] == 0);
}
