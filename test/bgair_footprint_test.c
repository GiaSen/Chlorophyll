// SPDX-License-Identifier: MIT
// Memory footprint of a process using libbgair, at the steps an icon render goes through, as jetsam counts it
// (phys_footprint): iOS 26 kills iconservicesagent above 17 MB once it is idle. RWA trim (rwa_device_trim) is measured
// last when the library has it.
//   bgair_footprint_test bg_render.metallib
#include <mach/mach.h>
#include <unistd.h>
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

static double
footprint_mb(void)
{
   task_vm_info_data_t vi;
   mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
   if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) != KERN_SUCCESS) return -1;
   return vi.phys_footprint / 1048576.0;
}

#include <malloc/malloc.h>
static void
breakdown(const char *what)
{
   task_vm_info_data_t vi;
   mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
   task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n);
   malloc_statistics_t ms;
   malloc_zone_statistics(NULL, &ms);
   printf("  %s: footprint %.1f = internal %.1f + compressed %.1f; malloc in use %.1f (allocated %.1f); "
          "iokit-mapped ledger %.1f MB\n", what, vi.phys_footprint / 1048576.0, vi.internal / 1048576.0,
          vi.compressed / 1048576.0, ms.size_in_use / 1048576.0, ms.size_allocated / 1048576.0,
          vi.ledger_tag_graphics_footprint / 1048576.0);
}

int
main(int argc, char **argv)
{
   if (argc < 2) return 2;
   struct rwa_memory m;
   printf("start: %.1f MB\n", footprint_mb()); breakdown("start");
   size_t n;
   uint8_t *lib = slurp(argv[1], &n);
   char why[512] = { 0 };
   struct rwa_device *dev = rwa_device_open(why, sizeof(why));
   if (!dev) { printf("device: %s\n", why); return 3; }
   printf("device open: %.1f MB\n", footprint_mb()); breakdown("device open");
   { struct rwa_memory m0; rwa_device_memory(dev, &m0); printf("  GPU buffers: %u live %.1f MB (%.1f MB mapped), %u cached %.1f MB\n", m0.live_bos, m0.live_bytes / 1048576.0, m0.mapped_bytes / 1048576.0, m0.cached_bos, m0.cached_bytes / 1048576.0); }
   size_t vs, fs;
   const uint8_t *vb = fn_of(lib, "bg_vs", &vs), *fb = fn_of(lib, "bg_fs_tex_inline", &fs);
   if (!vb || !fb) { printf("functions not found\n"); return 3; }
   struct rwa_render_shape shape;
   memset(&shape, 0, sizeof(shape));
   shape.color_format[0] = 115; shape.color_count = 1; shape.sample_count = 1;   /* RGBA16Float, as the icons */
   for (int i = 0; i < 8; i++) shape.color_blend[i].write_mask = 0xf;
   shape.color_blend_count = 8;
   struct rwa_render_info info;
   memset(&info, 0, sizeof(info));
   struct rwa_render *r = rwa_render_create(dev, vb, vs, "bg_vs", fb, fs, "bg_fs_tex_inline", &shape, &info, why, sizeof(why));
   if (!r) { printf("pipeline: %s\n", why); return 1; }
   float verts[3 * 8] = { -1, -1, 0, 1, 1, 1, 1, 1,  3, -1, 0, 1, 1, 1, 1, 1,  -1, 3, 0, 1, 1, 1, 1, 1 };
   struct rwa_buffer *vbuf = rwa_buffer_create(dev, sizeof(verts), why, sizeof(why));
   memcpy(rwa_buffer_map(vbuf), verts, sizeof(verts));
   printf("pipeline built: %.1f MB\n", footprint_mb());
   /* 40 icons: a 256x256 RGBA16F target each, sampling a 256x256 RGBA8 source, drawn, read back, released */
   static uint8_t src[256 * 256 * 4], out[256 * 256 * 8];
   memset(src, 0x80, sizeof(src));
   unsigned o[3] = { 0, 0, 0 }, s0[3] = { 256, 256, 1 };
   for (int k = 0; k < 40; k++) {
      struct rwa_texture_shape ts = { .pixel_format = 70, .type = 2, .width = 256, .height = 256, .depth = 1, .array_length = 1, .mip_levels = 1, .sample_count = 1, .usage = 1 };
      struct rwa_texture *in = rwa_texture_create(dev, &ts, why, sizeof(why));
      ts.pixel_format = 115; ts.usage = 5;
      struct rwa_texture *t = rwa_texture_create(dev, &ts, why, sizeof(why));
      if (!in || !t || rwa_texture_write(in, 0, 0, o, s0, src, 0, why, sizeof(why))) { printf("textures: %s\n", why); return 3; }
      struct rwa_texture *colors[1] = { t }, *texs[1] = { in };
      struct rwa_buffer *vbufs[1] = { vbuf };
      struct rwa_buffer_bind vt[1] = { { vbuf, 0 } };
      struct rwa_draw dr;
      memset(&dr, 0, sizeof(dr));
      dr.color = colors; dr.color_count = 1;
      dr.vertex = (struct rwa_bindings){ .buffers = vbufs, .buffer_count = 1 };
      dr.fragment = (struct rwa_bindings){ .textures = texs, .texture_count = 1 };
      dr.primitive = 3; dr.vertex_count = 3;
      dr.vertex_buffer_table = vt; dr.vertex_buffer_table_count = 1;
      if (rwa_render_draw(r, &dr, why, sizeof(why)) != 0 || rwa_finish(dev, why, sizeof(why)) != 0) { printf("draw: %s\n", why); return 1; }
      rwa_texture_read(t, 0, 0, o, s0, out, 0, why, sizeof(why));
      rwa_texture_destroy(t);
      rwa_texture_destroy(in);
   }
   printf("40 icons drawn and released: %.1f MB\n", footprint_mb());
   sleep(2);
   printf("2 s idle: %.1f MB\n", footprint_mb()); breakdown("idle");
   rwa_device_trim(dev);
   printf("after rwa_device_trim: %.1f MB\n", footprint_mb());
   sleep(1);
   printf("1 s later: %.1f MB\n", footprint_mb());
   rwa_device_memory(dev, &m);
   printf("  GPU buffers: %u live %.1f MB (%.1f MB mapped), %u cached %.1f MB, texture pool %.1f MB\n", m.live_bos,
          m.live_bytes / 1048576.0, m.mapped_bytes / 1048576.0, m.cached_bos, m.cached_bytes / 1048576.0, m.tex_pool_bytes / 1048576.0);
   return 0;
}
