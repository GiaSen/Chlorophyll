// SPDX-License-Identifier: MIT
// A real CoreAnimation vertex stage (QuartzCore std_vert0_lpf: [[stage_in]] position and color, mvp_matrix at buffer 2, texmat at buffer 3)
// paired with a fragment stage of ours, through libbgair on the Mac (RWA_SOFTWARE=1). Analytic pixel checks of the interpolated colour.
//   bgair_vertex_test QuartzCore.mtlb bg_render.metallib
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
   size_t n1, n2;
   uint8_t *qc = slurp(argv[1], &n1), *rl = slurp(argv[2], &n2);
   char why[512] = { 0 };
   struct rwa_device *dev = rwa_device_open(why, sizeof(why));
   if (!dev) { printf("device: %s\n", why); return 3; }
   size_t vs, fs;
   const uint8_t *vb = fn_of(qc, "std_vert0_lpf", &vs), *fb = fn_of(rl, "bg_fs_ca_color", &fs);
   if (!vb || !fb) { printf("functions not found\n"); return 3; }
   struct rwa_render_shape shape;
   memset(&shape, 0, sizeof(shape));
   shape.color_format[0] = 80; shape.color_count = 1; shape.sample_count = 1;
   for (int i = 0; i < 8; i++) shape.color_blend[i].write_mask = 0xf;
   shape.color_blend_count = 8;
   // MTLVertexFormatFloat4 = 31: attribute 0 (position) at offset 0 and attribute 3 (color) at offset 16, both from buffer 0, stride 32
   shape.vertex_attribute[0].format = 31; shape.vertex_attribute[0].offset = 0; shape.vertex_attribute[0].buffer_index = 0;
   shape.vertex_attribute[3].format = 31; shape.vertex_attribute[3].offset = 16; shape.vertex_attribute[3].buffer_index = 0;
   shape.vertex_layout[0].stride = 32; shape.vertex_layout[0].step_function = 1; shape.vertex_layout[0].step_rate = 1;
   struct rwa_render_info info;
   memset(&info, 0, sizeof(info));
   struct rwa_render *r = rwa_render_create(dev, vb, vs, "std_vert0_lpf", fb, fs, "bg_fs_ca_color", &shape, &info, why, sizeof(why));
   if (!r) { printf("rwa_render_create: %s\n", why); return 1; }
   printf("pipeline: vertex_buffers=%u fragment_buffers=%u streams=%u stream_mask=%#x attributes=%u\n", info.vertex_buffers, info.fragment_buffers,
          info.vertex_streams, info.vertex_stream_mask, info.vertex_attribute_count);
   float verts[3 * 8] = { -1, -1, 0, 1,  1, 0, 0, 1,    1, -1, 0, 1,  0, 1, 0, 1,    -1, 1, 0, 1,  0, 0, 1, 1 };
   struct rwa_buffer *vbuf = rwa_buffer_create(dev, sizeof(verts), why, sizeof(why));
   memcpy(rwa_buffer_map(vbuf), verts, sizeof(verts));
   float ident[16] = { 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1 };
   struct rwa_buffer *mvp = rwa_buffer_create(dev, 256, why, sizeof(why)), *tm = rwa_buffer_create(dev, 256, why, sizeof(why));
   memset(rwa_buffer_map(mvp), 0, 256); memset(rwa_buffer_map(tm), 0, 256);
   memcpy(rwa_buffer_map(mvp), ident, sizeof(ident)); memcpy(rwa_buffer_map(tm), ident, sizeof(ident));
   struct rwa_texture_shape ts = { .pixel_format = 80, .type = 2, .width = 64, .height = 64, .depth = 1, .array_length = 1, .mip_levels = 1, .sample_count = 1, .usage = 5 };
   struct rwa_texture *rt = rwa_texture_create(dev, &ts, why, sizeof(why));
   struct rwa_buffer *vbufs[4] = { vbuf, NULL, mvp, tm };
   struct rwa_buffer_bind vt[4] = { { vbuf, 0 }, { NULL, 0 }, { mvp, 0 }, { tm, 0 } };
   struct rwa_vertex_stream streams[1] = { { vbuf, 0 } };
   float clear[4] = { 0, 0, 0, 1 };
   struct rwa_texture *colors[1] = { rt };
   struct rwa_draw dr;
   memset(&dr, 0, sizeof(dr));
   dr.color = colors; dr.color_count = 1; dr.clear_color = clear;
   dr.vertex = (struct rwa_bindings){ .buffers = vbufs, .buffer_count = 4 };
   dr.primitive = 3; dr.vertex_count = 3;
   dr.vertex_streams = streams; dr.vertex_stream_count = info.vertex_streams;
   dr.vertex_buffer_table = vt; dr.vertex_buffer_table_count = 4;
   if (rwa_render_draw(r, &dr, why, sizeof(why)) != 0) { printf("draw: %s\n", why); return 1; }
   uint8_t px[64 * 64 * 4];
   unsigned o[3] = { 0, 0, 0 }, sz[3] = { 64, 64, 1 };
   rwa_texture_read(rt, 0, 0, o, sz, px, 64 * 4, why, sizeof(why));
   unsigned bad = 0, checked = 0;
   for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
      float nx = (x + 0.5f) / 32 - 1, ny = 1 - (y + 0.5f) / 32;
      float wg = (nx + 1) / 2, wb = (ny + 1) / 2, wr = 1 - wg - wb;
      uint8_t *p = px + (y * 64 + x) * 4;
      if (wr > 0.03f && wg > 0.03f && wb > 0.03f) {
         checked++;
         if (fabsf(p[2] - wr * 255) > 3 || fabsf(p[1] - wg * 255) > 3 || fabsf(p[0] - wb * 255) > 3) { if (bad++ < 3) printf("  (%d,%d) got %u,%u,%u want %.0f,%.0f,%.0f\n", x, y, p[2], p[1], p[0], wr * 255, wg * 255, wb * 255); }
      } else if (wr < -0.03f || wg < -0.03f || wb < -0.03f) {
         checked++;
         if (p[0] || p[1] || p[2]) { if (bad++ < 3) printf("  outside (%d,%d) %u,%u,%u\n", x, y, p[2], p[1], p[0]); }
      }
   }
   printf("std_vert0_lpf (QuartzCore) + own fragment: %u of %u checked pixels correct\n", checked - bad, checked);
   return bad ? 1 : 0;
}
