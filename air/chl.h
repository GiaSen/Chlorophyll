/*
 * SPDX-License-Identifier: MIT
 *
 * Chlorophyll's GPU runtime on Turnip (Mesa's Vulkan driver for Adreno), linked into the same dylib as Turnip.
 *
 * The shape is Metal's, because Metal and Vulkan are the same kind of API: objects with their state baked in at creation
 * (pipelines, depth/stencil states, samplers), command buffers recorded by encoders, explicit passes with load and store
 * actions, and completion reported per command buffer. Every chl_* object is a Vulkan object or a thin wrapper around one:
 *
 *   chl_buffer            VkBuffer + host-visible memory, mapped for its life (Metal shared storage)
 *   chl_texture           VkImage (+ VkImageView), every image in VK_IMAGE_LAYOUT_GENERAL
 *   chl_sampler           VkSampler
 *   chl_compute_pipeline  AIR -> NIR (libair) -> VkPipeline per threadgroup size, through Turnip's ir3
 *   chl_render_pipeline   AIR -> NIR -> one VkPipeline for dynamic rendering; dynamic viewport, scissor, stencil reference,
 *                         cull mode, front face, depth bias and blend constants
 *   chl_depth_stencil     the depth/stencil part of a pipeline, applied with extended dynamic state
 *   chl_cmdbuf            one VkCommandBuffer; resources it uses are retained until it completes
 *   render encoder        vkCmdBeginRendering .. vkCmdEndRendering; set* records dirty state, a draw flushes it as one
 *                         push-descriptor update and one push-constant update, then vkCmdDraw*
 *   compute encoder       vkCmdDispatch with the same binding model
 *   blit encoder          vkCmdCopy* / vkCmdFillBuffer / vkCmdBlitImage
 *
 * Binding model (air_nir_vk.c): Metal's [[buffer(n)]], [[texture(n)]], [[sampler(n)]] of each stage are bindings of one
 * push-descriptor set; a buffer is bound at its offset rounded down to the device's alignment and the shader adds the rest
 * from a push-constant word, so any multiple-of-4 offset Metal allows works. A shader's constexpr samplers are immutable
 * samplers of the set layout. setVertexBytes: and friends go to a per-command-buffer upload ring.
 *
 * Every call that can fail returns NULL or -1 and writes a sentence into `why`.
 */
#ifndef CHL_H
#define CHL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma GCC visibility push(default)

struct chl_device;
struct chl_buffer;
struct chl_texture;
struct chl_sampler;
struct chl_compute_pipeline;
struct chl_render_pipeline;
struct chl_depth_stencil;
struct chl_cmdbuf;

/* ---- device ---- */
struct chl_device *chl_device_open(char *why, size_t why_size);
void chl_device_close(struct chl_device *dev);
const char *chl_device_name(const struct chl_device *dev);

/* ---- buffers: host-visible, coherent, mapped for their whole life ---- */
struct chl_buffer *chl_buffer_create(struct chl_device *dev, size_t size, char *why, size_t why_size);
void *chl_buffer_contents(struct chl_buffer *buf);
size_t chl_buffer_length(const struct chl_buffer *buf);
uint64_t chl_buffer_gpu_address(const struct chl_buffer *buf);
void chl_buffer_retain(struct chl_buffer *buf);
void chl_buffer_release(struct chl_buffer *buf);

/* ---- textures ---- */
enum chl_texture_type {   /* MTLTextureType */
   CHL_TEX_1D = 0, CHL_TEX_1D_ARRAY = 1, CHL_TEX_2D = 2, CHL_TEX_2D_ARRAY = 3, CHL_TEX_2D_MS = 4,
   CHL_TEX_CUBE = 5, CHL_TEX_CUBE_ARRAY = 6, CHL_TEX_3D = 7, CHL_TEX_2D_MS_ARRAY = 8, CHL_TEX_BUFFER = 9,
};
enum {                    /* MTLTextureUsage */
   CHL_USAGE_SHADER_READ = 0x1, CHL_USAGE_SHADER_WRITE = 0x2, CHL_USAGE_RENDER_TARGET = 0x4, CHL_USAGE_PIXEL_FORMAT_VIEW = 0x10,
};
struct chl_texture_desc {
   unsigned pixel_format;   /* MTLPixelFormat */
   unsigned type;           /* chl_texture_type */
   unsigned width, height, depth, array_length, mip_levels, sample_count;
   unsigned usage;          /* MTLTextureUsage; 0 is read via everything */
   unsigned char swizzle[4];/* MTLTextureSwizzle (0 zero, 1 one, 2 red .. 5 alpha); all zero = identity */
};
struct chl_texture *chl_texture_create(struct chl_device *dev, const struct chl_texture_desc *desc, char *why, size_t why_size);
/* -newTextureWithDescriptor:iosurface:plane: (plane 0): the texture IS the surface's memory, linear with the surface's pitch.
 * chl_texture_flush_surface makes what the GPU wrote visible to the processor and to the compositor (the kernel's cache clean). */
struct chl_texture *chl_texture_from_iosurface(struct chl_device *dev, const struct chl_texture_desc *desc, int surface_id,
                                               char *why, size_t why_size);
int chl_texture_flush_surface(struct chl_texture *tex);
/* -[MTLTexture newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:] */
struct chl_texture *chl_texture_view(struct chl_texture *parent, unsigned pixel_format, unsigned type, unsigned base_level,
                                     unsigned level_count, unsigned base_slice, unsigned slice_count,
                                     const unsigned char swizzle[4], char *why, size_t why_size);
/* -replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage: (synchronous: visible to all later GPU work) */
/* rows of blocks an image of this height has in this pixel format (the height, unless block compressed) */
unsigned chl_format_block_rows(unsigned pixel_format, unsigned height);
/* bytes of one such row with no padding */
size_t chl_format_tight_row(unsigned pixel_format, unsigned width);
int chl_texture_replace(struct chl_texture *tex, unsigned level, unsigned slice, const unsigned origin[3], const unsigned size[3],
                        const void *bytes, size_t bytes_per_row, size_t bytes_per_image, char *why, size_t why_size);
/* -getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice: (waits for the GPU work submitted before it) */
int chl_texture_get(struct chl_texture *tex, unsigned level, unsigned slice, const unsigned origin[3], const unsigned size[3],
                    void *bytes, size_t bytes_per_row, size_t bytes_per_image, char *why, size_t why_size);
void chl_texture_size(const struct chl_texture *tex, unsigned *w, unsigned *h, unsigned *d, unsigned *levels, unsigned *slices,
                      unsigned *samples);
void chl_texture_retain(struct chl_texture *tex);
void chl_texture_release(struct chl_texture *tex);

/* ---- samplers: MTLSamplerDescriptor ---- */
struct chl_sampler_desc {
   unsigned address[3];       /* MTLSamplerAddressMode s, t, r */
   unsigned min_filter, mag_filter, mip_filter;
   unsigned compare_function; /* MTLCompareFunction */
   unsigned max_anisotropy;
   bool normalized_coordinates;
   float lod_min, lod_max;
   unsigned border_color;     /* MTLSamplerBorderColor */
};
struct chl_sampler *chl_sampler_create(struct chl_device *dev, const struct chl_sampler_desc *desc, char *why, size_t why_size);
void chl_sampler_retain(struct chl_sampler *s);
void chl_sampler_release(struct chl_sampler *s);

/* ---- functions and pipelines ---- */
struct chl_linked_function { const void *bitcode; size_t size; const char *name; };   /* MTLLinkedFunctions, as AIR */
struct chl_function {
   const void *bitcode;       /* the AIR module of the function, as a .metallib stores it */
   size_t size;
   const char *entry;
   const void *constants;     /* MTLFunctionConstantValues, as air_constant_value[]; NULL for the module's defaults */
   unsigned num_constants;
   const struct chl_linked_function *linked;   /* the functions the stage's declared calls resolve against */
   unsigned num_linked;
};

/* What a pipeline tells its caller (MTLComputePipelineReflection's useful part). */
struct chl_pipeline_info {
   unsigned max_threads_per_group;
   unsigned thread_execution_width;
   unsigned static_threadgroup_bytes;
   uint32_t buffers_used[2];    /* per stage (vertex/compute, fragment): bit n = [[buffer(n)]] */
   uint32_t textures_used[2];
   uint32_t samplers_used[2];
   uint32_t argbufs[2];         /* [[buffer(n)]] that are argument buffers */
};

struct chl_compute_pipeline *chl_compute_pipeline_create(struct chl_device *dev, const struct chl_function *fn,
                                                         struct chl_pipeline_info *info, char *why, size_t why_size);
void chl_compute_pipeline_release(struct chl_compute_pipeline *p);

struct chl_blend {              /* MTLRenderPipelineColorAttachmentDescriptor */
   bool enabled;
   unsigned rgb_op, alpha_op;                       /* MTLBlendOperation */
   unsigned src_rgb, dst_rgb, src_alpha, dst_alpha; /* MTLBlendFactor */
   unsigned write_mask;                             /* MTLColorWriteMask */
};
struct chl_vertex_attribute { unsigned format, offset, buffer_index; };      /* MTLVertexAttributeDescriptor; format 0 = none */
struct chl_vertex_layout { unsigned stride, step_function, step_rate; };     /* MTLVertexBufferLayoutDescriptor */
#define CHL_MAX_ATTRIBUTES 31
#define CHL_MAX_BUFFERS 31
struct chl_render_pipeline_desc {
   struct chl_function vertex, fragment;            /* fragment.bitcode NULL: depth/stencil only */
   unsigned color_format[8];                        /* MTLPixelFormat; 0 = no attachment */
   struct chl_blend blend[8];
   unsigned depth_format, stencil_format;           /* MTLPixelFormat or 0 */
   unsigned sample_count;
   bool alpha_to_coverage;
   unsigned topology_class;                         /* MTLPrimitiveTopologyClass; 0 = unspecified (triangles) */
   struct chl_vertex_attribute attribute[CHL_MAX_ATTRIBUTES];
   struct chl_vertex_layout layout[CHL_MAX_BUFFERS];
   bool has_vertex_descriptor;
};
struct chl_render_pipeline *chl_render_pipeline_create(struct chl_device *dev, const struct chl_render_pipeline_desc *desc,
                                                       struct chl_pipeline_info *info, char *why, size_t why_size);
void chl_render_pipeline_release(struct chl_render_pipeline *p);

struct chl_stencil_face { unsigned compare, fail, depth_fail, pass, read_mask, write_mask; };
struct chl_depth_stencil_desc {                     /* MTLDepthStencilDescriptor */
   unsigned depth_compare;                          /* MTLCompareFunction */
   bool depth_write;
   bool stencil_enabled;
   struct chl_stencil_face front, back;
};
struct chl_depth_stencil *chl_depth_stencil_create(struct chl_device *dev, const struct chl_depth_stencil_desc *desc,
                                                   char *why, size_t why_size);
void chl_depth_stencil_release(struct chl_depth_stencil *ds);

/* ---- command buffers ---- */
struct chl_cmdbuf *chl_cmdbuf_create(struct chl_device *dev, char *why, size_t why_size);
/* Submit. `done` runs on the device's completion thread when the GPU has finished (status 0) or failed (-1). */
typedef void (*chl_done_fn)(void *ctx, int status, const char *why);
int chl_cmdbuf_commit(struct chl_cmdbuf *cb, chl_done_fn done, void *ctx, char *why, size_t why_size);
int chl_cmdbuf_wait(struct chl_cmdbuf *cb, char *why, size_t why_size);   /* after commit */
void chl_cmdbuf_release(struct chl_cmdbuf *cb);   /* before commit: discards; after: when complete */

enum chl_stage { CHL_STAGE_VERTEX = 0, CHL_STAGE_FRAGMENT = 1, CHL_STAGE_COMPUTE = 0 };

/* Binding (any encoder): Metal's per-stage tables. */
void chl_set_buffer(struct chl_cmdbuf *cb, unsigned stage, unsigned index, struct chl_buffer *buf, size_t offset);
void chl_set_bytes(struct chl_cmdbuf *cb, unsigned stage, unsigned index, const void *bytes, size_t length);
void chl_set_texture(struct chl_cmdbuf *cb, unsigned stage, unsigned index, struct chl_texture *tex);
void chl_set_sampler(struct chl_cmdbuf *cb, unsigned stage, unsigned index, struct chl_sampler *s);

/* Render encoder: MTLRenderPassDescriptor */
struct chl_attachment {
   struct chl_texture *texture;
   unsigned level, slice;
   unsigned load_action;     /* MTLLoadAction: 0 DontCare, 1 Load, 2 Clear */
   unsigned store_action;    /* MTLStoreAction: 0 DontCare, 1 Store, 2 MultisampleResolve, 3 StoreAndMultisampleResolve */
   struct chl_texture *resolve;
   unsigned resolve_level, resolve_slice;
   float clear[4];           /* colour; [0] is depth for the depth attachment */
   unsigned clear_stencil;
};
struct chl_render_pass {
   struct chl_attachment color[8];
   struct chl_attachment depth, stencil;
   unsigned width, height;   /* 0: from the first attachment */
};
int chl_render_begin(struct chl_cmdbuf *cb, const struct chl_render_pass *pass, char *why, size_t why_size);
void chl_set_render_pipeline(struct chl_cmdbuf *cb, struct chl_render_pipeline *p);
void chl_set_depth_stencil(struct chl_cmdbuf *cb, struct chl_depth_stencil *ds);
void chl_set_viewport(struct chl_cmdbuf *cb, double x, double y, double w, double h, double znear, double zfar);
void chl_set_scissor(struct chl_cmdbuf *cb, unsigned x, unsigned y, unsigned w, unsigned h);
void chl_set_cull(struct chl_cmdbuf *cb, unsigned mtl_cull_mode, unsigned mtl_winding);
void chl_set_depth_bias(struct chl_cmdbuf *cb, float bias, float slope, float clamp);
void chl_set_stencil_reference(struct chl_cmdbuf *cb, unsigned front, unsigned back);
void chl_set_blend_color(struct chl_cmdbuf *cb, const float rgba[4]);
int chl_draw(struct chl_cmdbuf *cb, unsigned mtl_primitive, unsigned vertex_start, unsigned vertex_count, unsigned instances,
             unsigned base_instance, char *why, size_t why_size);
int chl_draw_indexed(struct chl_cmdbuf *cb, unsigned mtl_primitive, unsigned index_count, unsigned mtl_index_type,
                     struct chl_buffer *index_buffer, size_t index_offset, unsigned instances, int base_vertex,
                     unsigned base_instance, char *why, size_t why_size);
void chl_render_end(struct chl_cmdbuf *cb);

/* Compute encoder */
void chl_compute_begin(struct chl_cmdbuf *cb);
void chl_set_compute_pipeline(struct chl_cmdbuf *cb, struct chl_compute_pipeline *p);
void chl_set_threadgroup_memory(struct chl_cmdbuf *cb, unsigned index, size_t length);
int chl_dispatch(struct chl_cmdbuf *cb, const unsigned groups[3], const unsigned threads[3], char *why, size_t why_size);
void chl_compute_end(struct chl_cmdbuf *cb);

/* Blit encoder (outside render passes) */
void chl_copy_buffer(struct chl_cmdbuf *cb, struct chl_buffer *src, size_t src_off, struct chl_buffer *dst, size_t dst_off,
                     size_t size);
void chl_fill_buffer(struct chl_cmdbuf *cb, struct chl_buffer *dst, size_t off, size_t size, uint8_t value);
int chl_copy_texture(struct chl_cmdbuf *cb, struct chl_texture *src, unsigned slice, unsigned level, const unsigned origin[3],
                     const unsigned size[3], struct chl_texture *dst, unsigned dslice, unsigned dlevel, const unsigned dorigin[3]);
int chl_copy_buffer_to_texture(struct chl_cmdbuf *cb, struct chl_buffer *src, size_t off, size_t bytes_per_row,
                               size_t bytes_per_image, const unsigned size[3], struct chl_texture *dst, unsigned slice,
                               unsigned level, const unsigned origin[3]);
int chl_copy_texture_to_buffer(struct chl_cmdbuf *cb, struct chl_texture *src, unsigned slice, unsigned level,
                               const unsigned origin[3], const unsigned size[3], struct chl_buffer *dst, size_t off,
                               size_t bytes_per_row, size_t bytes_per_image);
int chl_generate_mipmaps(struct chl_cmdbuf *cb, struct chl_texture *tex);

/* Encode profile (bgmtl.encprof): where encoding goes, mach_absolute_time ticks and calls, all threads; zeros unless `on`. */
enum { CHL_P_BEGIN, CHL_P_END, CHL_P_PIPE, CHL_P_STATE, CHL_P_VB, CHL_P_FLUSH, CHL_P_PUSHD, CHL_P_PUSHC, CHL_P_DRAW, CHL_P_BYTES,
       CHL_P_CMDBUF, CHL_P_N };
struct chl_prof { bool on; uint64_t t[CHL_P_N], n[CHL_P_N]; };
extern struct chl_prof chl_prof;
/* the memory cache of released textures, since the last call */
void chl_memcache_stats(struct chl_device *d, unsigned long *hits, unsigned long *misses, double *mb);
/* where the last render pipeline built on this thread went: ms[0] translating AIR, ms[1] lowering for Vulkan, ms[2] Turnip;
 * how many of its functions were not in the translation cache */
void chl_pipeline_build_stats(double ms[3], unsigned *not_cached);
/* the last commit on this thread: ms[0] held back by the frame limit, ms[1] waiting for the locks, ms[2] the prologue work, ms[3] vkQueueSubmit */
void chl_commit_stats(double ms[4]);
/* /private/var/tmp/chl.passprof, render server only: pass i of a finished command buffer as a line (gap before it, its GPU time, size,
 * draws, fragment functions), empty when both are under min_ms; returns 0 when there is no such pass */
int chl_cmdbuf_pass_line(struct chl_cmdbuf *cb, unsigned i, double min_ms, char *out, size_t size);

#pragma GCC visibility pop

#ifdef __cplusplus
}
#endif

#endif
