// SPDX-License-Identifier: MIT
// The Gallium half of the Turnip comparison: the frame turnip/test/tu_smoke.c times, through libbgair's rwa_* API (what bgmtl.m
// calls per Metal draw): N draws into one RGBA8 target, alternating a flat-colour pipeline and a blended texture tap, per-draw
// vertex bytes and constants at offsets into one buffer, then one flush and fence wait per frame.
//   bgair_drawbench bg_render.metallib [draws=200] [frames=60]
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
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
static double now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e6 + t.tv_nsec / 1e3; }

int
main(int argc, char **argv)
{
   if (argc < 2) { printf("usage: bgair_drawbench bg_render.metallib [draws] [frames]\n"); return 2; }
   int draws = argc > 2 ? atoi(argv[2]) : 200, frames = argc > 3 ? atoi(argv[3]) : 60;
   setvbuf(stdout, NULL, _IOLBF, 0);
   size_t n;
   uint8_t *lib = slurp(argv[1], &n);
   char why[512] = { 0 };
   struct rwa_device *dev = rwa_device_open(why, sizeof(why));
   if (!dev) { printf("device: %s\n", why); return 3; }
   size_t vs, fc, ft;
   const uint8_t *vb = fn_of(lib, "bg_vs", &vs), *fcb = fn_of(lib, "bg_fs_color", &fc), *ftb = fn_of(lib, "bg_fs_tex_linear", &ft);
   if (!vb || !fcb || !ftb) { printf("functions not found\n"); return 3; }
   struct rwa_render_shape shape;
   memset(&shape, 0, sizeof(shape));
   shape.color_format[0] = 70; shape.color_count = 1; shape.sample_count = 1;   /* MTLPixelFormatRGBA8Unorm */
   for (int i = 0; i < 8; i++) shape.color_blend[i].write_mask = 0xf;
   shape.color_blend_count = 8;
   struct rwa_render_info info[2];
   memset(info, 0, sizeof(info));
   double tp = now_us();
   struct rwa_render *r[2];
   r[0] = rwa_render_create(dev, vb, vs, "bg_vs", fcb, fc, "bg_fs_color", &shape, &info[0], why, sizeof(why));
   if (!r[0]) { printf("pipeline 0: %s\n", why); return 1; }
   shape.color_blend[0] = (struct rwa_color_blend){ 1, 0, 0, 1, 5, 1, 5, 0xf };   /* One, OneMinusSourceAlpha */
   r[1] = rwa_render_create(dev, vb, vs, "bg_vs", ftb, ft, "bg_fs_tex_linear", &shape, &info[1], why, sizeof(why));
   if (!r[1]) { printf("pipeline 1: %s\n", why); return 1; }
   printf("2 pipelines in %.1f ms\n", (now_us() - tp) / 1e3);

   struct rwa_texture_shape ts = { .pixel_format = 70, .type = 2, .width = 256, .height = 256, .depth = 1, .array_length = 1, .mip_levels = 1,
                                   .sample_count = 1, .usage = 5 };
   struct rwa_texture *rt = rwa_texture_create(dev, &ts, why, sizeof(why));
   struct rwa_texture_shape tts = { .pixel_format = 70, .type = 2, .width = 4, .height = 4, .depth = 1, .array_length = 1, .mip_levels = 1,
                                    .sample_count = 1, .usage = 1 };
   struct rwa_texture *tex = rwa_texture_create(dev, &tts, why, sizeof(why));
   if (!rt || !tex) { printf("texture: %s\n", why); return 1; }
   uint32_t green[16];
   for (int i = 0; i < 16; i++) green[i] = 0xff00ff00u;
   unsigned o3[3] = { 0, 0, 0 }, s3[3] = { 4, 4, 1 };
   rwa_texture_write(tex, 0, 0, o3, s3, green, 16, why, sizeof(why));
   struct rwa_sampler_state ss = { .address = { 0, 0, 0 }, .min_filter = 1, .mag_filter = 1, .normalized_coordinates = 1, .lod_max = 0 };
   struct rwa_sampler *smp = rwa_sampler_create(dev, &ss, why, sizeof(why));
   if (!smp) { printf("sampler: %s\n", why); return 1; }

   const size_t stride = 256;
   struct rwa_buffer *vbuf = rwa_buffer_create(dev, stride * (draws + 1), why, sizeof(why));
   struct rwa_buffer *cbuf = rwa_buffer_create(dev, stride * (draws + 1), why, sizeof(why));
   for (int i = 0; i < draws; i++) {
      float x = -1 + 2.0f * (i % 16) / 16, y = -1 + 2.0f * (i / 16 % 16) / 16;
      float t[24] = { x, y, 0, 1,  1, 1, 1, 0.5f,   x + 0.25f, y, 0, 1,  1, 1, 1, 0.5f,   x, y + 0.25f, 0, 1,  1, 1, 1, 0.5f };
      memcpy((char *)rwa_buffer_map(vbuf) + stride * i, t, sizeof(t));
      float *c = (float *)((char *)rwa_buffer_map(cbuf) + stride * i);
      c[0] = 0.01f * (i % 7); c[1] = 0;
   }
   float clear[4] = { 0, 0, 1, 1 };
   struct rwa_texture *colors[1] = { rt };
   struct rwa_buffer *vbufs[1] = { vbuf }, *fbufs[2] = { NULL, cbuf };
   struct rwa_texture *ftex[1] = { tex };
   struct rwa_sampler *fsmp[1] = { smp };
   double enc = 0, wait = 0, encmin = 1e30;
   for (int f = 0; f < frames + 3; f++) {
      double a = now_us();
      for (int i = 0; i < draws; i++) {
         struct rwa_buffer_bind vt[1] = { { vbuf, stride * i } }, ft2[2] = { { NULL, 0 }, { cbuf, stride * i } };
         struct rwa_draw dr;
         memset(&dr, 0, sizeof(dr));
         dr.color = colors; dr.color_count = 1; dr.clear_color = i == 0 ? clear : NULL;
         dr.vertex = (struct rwa_bindings){ .buffers = vbufs, .buffer_count = 1 };
         if (i & 1) {
            dr.fragment = (struct rwa_bindings){ .buffers = fbufs, .buffer_count = 2, .textures = ftex, .texture_count = 1, .samplers = fsmp, .sampler_count = 1 };
            dr.fragment_buffer_table = ft2; dr.fragment_buffer_table_count = 2;
         }
         dr.primitive = 3; dr.vertex_count = 3;
         dr.vertex_buffer_table = vt; dr.vertex_buffer_table_count = 1;
         if (rwa_render_draw(r[i & 1], &dr, why, sizeof(why)) != 0) { printf("draw %d: %s\n", i, why); return 1; }
      }
      double b = now_us();
      struct rwa_fence *fe = rwa_flush(dev);
      if (fe) { if (rwa_fence_wait(dev, fe, why, sizeof(why)) != 0) { printf("wait: %s\n", why); return 1; } rwa_fence_release(dev, fe); }
      double c = now_us();
      if (f >= 3) { enc += b - a; wait += c - b; if (b - a < encmin) encmin = b - a; }
   }
   printf("bench: %d frames x %d draws: encode %.3f ms/frame (min %.3f) = %.2f us/draw, flush+wait %.3f ms\n", frames, draws,
          enc / frames / 1e3, encmin / 1e3, enc / frames / draws, wait / frames / 1e3);
   uint32_t px[256 * 256];
   unsigned rs[3] = { 256, 256, 1 };
   rwa_texture_read(rt, 0, 0, o3, rs, px, 256 * 4, why, sizeof(why));
   printf("pixel (8,8) = %08x, (255,255) = %08x\n", px[8 * 256 + 8], px[255 * 256 + 255]);
   return 0;
}
