// SPDX-License-Identifier: MIT
// CoreAnimation 26 packs every draw's constants into one buffer at 16-byte steps, so a fragment stage's constant buffer is
// usually bound at an offset the GPU's alignment does not allow and goes through the offset-delta path (air_metal.c
// bind_stage, constant buffer slot 15). This draws QuartzCore's own Liquid Glass stage (sdf_filter_vert_lph +
// glass_background_sdf_no_bleed_lph) with the same constants bound at several offsets: every image must equal the one with
// the constants at offset 0, up to the run-to-run noise of a second draw at offset 0 (the stage hands an `undef` half to its
// SDF helper, and a few pixels at the shape's corner change between identical draws on the A630).
//   bgair_cboffset_test QuartzCore.metallib
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

#define W 64
#define H 64
#define U_SIZE 272

int
main(int argc, char **argv)
{
   if (argc < 2) return 2;
   size_t n;
   uint8_t *lib = slurp(argv[1], &n);
   char why[512] = { 0 };
   struct rwa_device *dev = rwa_device_open(why, sizeof(why));
   if (!dev) { printf("device: %s\n", why); return 3; }
   const char *vname = "sdf_filter_vert_lph", *fname = "glass_background_sdf_no_bleed_lph";
   size_t vs, fs;
   const uint8_t *vb = fn_of(lib, vname, &vs), *fb = fn_of(lib, fname, &fs);
   if (!vb || !fb) { printf("functions not found\n"); return 3; }
   struct rwa_render_shape shape;
   memset(&shape, 0, sizeof(shape));
   shape.color_format[0] = 80; shape.color_count = 1; shape.sample_count = 1;
   for (int i = 0; i < 8; i++) shape.color_blend[i].write_mask = 0xf;
   shape.color_blend_count = 8;
   /* position float4 at 0, sdf_uv float2 at 16, src_uv float2 at 24, from buffer 0, stride 32 (MTLVertexFormatFloat4 31, Float2 29) */
   shape.vertex_attribute[0].format = 31; shape.vertex_attribute[0].offset = 0;
   shape.vertex_attribute[1].format = 29; shape.vertex_attribute[1].offset = 16;
   shape.vertex_attribute[2].format = 29; shape.vertex_attribute[2].offset = 24;
   shape.vertex_layout[0].stride = 32; shape.vertex_layout[0].step_function = 1; shape.vertex_layout[0].step_rate = 1;
   struct rwa_render_info info;
   memset(&info, 0, sizeof(info));
   struct rwa_render *r = rwa_render_create(dev, vb, vs, vname, fb, fs, fname, &shape, &info, why, sizeof(why));
   if (!r) { printf("rwa_render_create: %s\n", why); return 1; }

   /* a full-target quad as two triangles: sdf_uv over [-1, 1], src_uv over [0, 1] */
   float quad[6][8] = {
      { -1, -1, 0, 1, -1, -1, 0, 1 }, { 1, -1, 0, 1, 1, -1, 1, 1 }, { 1, 1, 0, 1, 1, 1, 1, 0 },
      { -1, -1, 0, 1, -1, -1, 0, 1 }, { 1, 1, 0, 1, 1, 1, 1, 0 }, { -1, 1, 0, 1, -1, 1, 0, 0 },
   };
   struct rwa_buffer *vbuf = rwa_buffer_create(dev, sizeof(quad), why, sizeof(why));
   memcpy(rwa_buffer_map(vbuf), quad, sizeof(quad));
   float ident[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
   struct rwa_buffer *mvp = rwa_buffer_create(dev, 256, why, sizeof(why)), *tm = rwa_buffer_create(dev, 256, why, sizeof(why));
   memset(rwa_buffer_map(mvp), 0, 256); memset(rwa_buffer_map(tm), 0, 256);
   memcpy(rwa_buffer_map(mvp), ident, sizeof(ident)); memcpy(rwa_buffer_map(tm), ident, sizeof(ident));

   /* the backdrop: a 3-level BGRA8 texture, a different colour pattern in each level */
   struct rwa_texture_shape ts = { .pixel_format = 80, .type = 2, .width = W, .height = H, .depth = 1, .array_length = 1, .mip_levels = 3,
                                   .sample_count = 1, .usage = 5 };
   struct rwa_texture *src = rwa_texture_create(dev, &ts, why, sizeof(why));
   static uint8_t img[W * H * 4];
   for (unsigned l = 0; l < 3; l++) {
      unsigned w = W >> l, h = H >> l;
      for (unsigned y = 0; y < h; y++) for (unsigned x = 0; x < w; x++) {
         uint8_t *p = img + (y * w + x) * 4;
         p[0] = (uint8_t)(x * 255 / w); p[1] = (uint8_t)(((x / 4 + y / 4) & 1) ? 200 : 40); p[2] = (uint8_t)(80 * l + 40); p[3] = 255;
      }
      unsigned o[3] = { 0, 0, 0 }, s[3] = { w, h, 1 };
      if (!src || rwa_texture_write(src, l, 0, o, s, img, 0, why, sizeof(why))) { printf("backdrop: %s\n", why); return 3; }
   }
   ts.mip_levels = 1;
   struct rwa_texture *rt = rwa_texture_create(dev, &ts, why, sizeof(why));

   /* the constants: increasing floats, so a misplaced read sees a different value */
   uint8_t u[U_SIZE];
   for (unsigned k = 0; k < U_SIZE / 4; k++) { float f = 0.25f + 0.0625f * (float)k; memcpy(u + 4 * k, &f, 4); }
   { int32_t m = 0; float f = (float)m; memcpy(u + 8, &f, 4); }                  /* SdfFragmentUniforms .x.z: sdf mode 0 */
   static const unsigned offsets[] = { 0, 0, 64, 256, 16, 48, 1040 };
   const unsigned noff = sizeof(offsets) / sizeof(offsets[0]);
   struct rwa_buffer *ubuf = rwa_buffer_create(dev, 4096, why, sizeof(why)), *ebuf = rwa_buffer_create(dev, 4096, why, sizeof(why));
   __fp16 edr = 1.0;
   static uint8_t out[8][W * H * 4];
   int fails = 0;
   unsigned noise = 0;
   for (unsigned t = 0; t < noff; t++) {
      memset(rwa_buffer_map(ubuf), 0xa5, 4096);
      memcpy((uint8_t *)rwa_buffer_map(ubuf) + offsets[t], u, U_SIZE);
      memset(rwa_buffer_map(ebuf), 0, 4096);
      memcpy((uint8_t *)rwa_buffer_map(ebuf) + offsets[t], &edr, 2);
      struct rwa_buffer *vbufs[4] = { vbuf, NULL, mvp, tm };
      struct rwa_buffer_bind vt[4] = { { vbuf, 0 }, { NULL, 0 }, { mvp, 0 }, { tm, 0 } };
      struct rwa_vertex_stream streams[1] = { { vbuf, 0 } };
      struct rwa_buffer *fbufs[7] = { NULL, ubuf, NULL, NULL, NULL, NULL, ebuf };
      struct rwa_buffer_bind ft[7] = { { NULL, 0 }, { ubuf, offsets[t] }, { NULL, 0 }, { NULL, 0 }, { NULL, 0 }, { NULL, 0 }, { ebuf, offsets[t] } };
      struct rwa_texture *texs[4] = { NULL, NULL, NULL, src };
      struct rwa_texture *colors[1] = { rt };
      float clear[4] = { 0, 0, 0, 0 };
      struct rwa_draw dr;
      memset(&dr, 0, sizeof(dr));
      dr.color = colors; dr.color_count = 1; dr.clear_color = clear;
      dr.vertex = (struct rwa_bindings){ .buffers = vbufs, .buffer_count = 4 };
      dr.fragment = (struct rwa_bindings){ .buffers = fbufs, .buffer_count = 7, .textures = texs, .texture_count = 4 };
      dr.primitive = 3; dr.vertex_count = 6;
      dr.vertex_streams = streams; dr.vertex_stream_count = info.vertex_streams;
      dr.vertex_buffer_table = vt; dr.vertex_buffer_table_count = 4;
      dr.fragment_buffer_table = ft; dr.fragment_buffer_table_count = 7;
      if (rwa_render_draw(r, &dr, why, sizeof(why)) != 0 || rwa_finish(dev, why, sizeof(why)) != 0) { printf("offset %u: draw: %s\n", offsets[t], why); return 1; }
      unsigned o[3] = { 0, 0, 0 }, s[3] = { W, H, 1 };
      rwa_texture_read(rt, 0, 0, o, s, out[t], 0, why, sizeof(why));
      unsigned diff = 0, maxd = 0, first = ~0u;
      for (unsigned i = 0; i < W * H * 4; i++) {
         unsigned d = abs((int)out[t][i] - (int)out[0][i]);
         if (d) { diff++; if (d > maxd) maxd = d; if (first == ~0u) first = i / 4; }
      }
      const uint8_t *c = out[t] + ((H / 2) * W + W / 2) * 4, *e = out[t] + ((H / 2) * W + 2) * 4;
      printf("u at offset %4u: centre BGRA %3u %3u %3u %3u, edge %3u %3u %3u %3u; %u bytes differ from offset 0 (max %u", offsets[t],
             c[0], c[1], c[2], c[3], e[0], e[1], e[2], e[3], diff, maxd);
      if (diff) printf(", first at pixel %u,%u", first % W, first / W);
      printf(")\n");
      if (t == 1) noise = diff;                                   /* offsets[1] repeats offset 0 */
      else if (t > 1 && diff > 2 * noise + 64) fails++;
   }
   printf("%s\n", fails ? "FAIL: the glass stage reads its constants differently at an unaligned offset" : "ok: every offset matches offset 0 within the run-to-run noise");
   return fails != 0;
}
