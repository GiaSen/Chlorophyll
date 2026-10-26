/*
 * SPDX-License-Identifier: MIT
 *
 * Chlorophyll on Turnip: the AIR frontend's NIR onto chl's Vulkan binding model (chl.h).
 *
 * air_to_nir names resources by Metal's own numbers, one flat index per kind:
 *   load_ubo / load_ssbo / store_ssbo / ssbo_atomic* / get_ssbo_size   src = imm [[buffer(n)]]
 *   image_load / image_store / image_size / ...                          src = imm [[texture(n)]]
 *   tex                                                                  texture_index = [[texture(n)]], sampler_index = [[sampler(n)]]
 *   load_push_constant(base = 4 * AIR_PUSH_NULL_MASK_WORD)               the stage's null-texture mask
 * Turnip's pipeline code takes what spirv_to_nir would produce, so this pass rewrites the indices into descriptors of one
 * push-descriptor set, each stage in a range of its own:
 *   binding stage_base + n                    [[buffer(n)]]   UNIFORM_BUFFER (constant) or STORAGE_BUFFER (device)
 *   binding stage_base + 32 + n               [[texture(n)]]  SAMPLED_IMAGE, or STORAGE_IMAGE when the shader stores to it
 *   binding stage_base + 64 + n               [[sampler(n)]]  SAMPLER (immutable when it is the shader's constexpr sampler)
 * and gives every stage 32 push-constant words at byte stage_base_push: word n (n < 31) is the part of [[buffer(n)]]'s offset
 * below the descriptor alignment, added to every access of that buffer (Metal allows any multiple of 4, Vulkan wants 64 on
 * Turnip), and word 31 is the null-texture mask.
 */

#include "air_nir_vk.h"
#include "air_private.h"

#include "nir.h"
#include "nir_builder.h"
#include "vulkan/vulkan_core.h"

struct bridge {
   struct air_vk_layout *layout;
   unsigned bind_base, push_base;
   nir_variable *tex_var[AIR_VK_TEXTURE_SLOTS];
   nir_variable *img_var[AIR_VK_TEXTURE_SLOTS];
   nir_variable *smp_var[AIR_VK_SAMPLER_SLOTS];
   char *why;
   size_t why_size;
   bool failed;
};

static void
fail(struct bridge *br, const char *fmt, unsigned a, unsigned b)
{
   if (!br->failed)
      snprintf(br->why, br->why_size, fmt, a, b);
   br->failed = true;
}

static bool
declare(struct bridge *br, unsigned binding, VkDescriptorType type)
{
   if (binding >= AIR_VK_MAX_BINDINGS) {
      fail(br, "binding %u is past the %u of this layout", binding, AIR_VK_MAX_BINDINGS);
      return false;
   }
   int t = (int)type + 1;
   /* a texture both sampled and stored (Metal access::read_write read through a texture fetch): storage wins, and the
    * fetch becomes an image load below */
   if (br->layout->type[binding] && br->layout->type[binding] != t &&
       !(br->layout->type[binding] == VK_DESCRIPTOR_TYPE_STORAGE_IMAGE + 1 && type == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE) &&
       !(br->layout->type[binding] == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE + 1 && type == VK_DESCRIPTOR_TYPE_STORAGE_IMAGE)) {
      fail(br, "binding %u is used as two kinds of descriptor (Vulkan type %u)", binding, type);
      return false;
   }
   if (!br->layout->type[binding] || type == VK_DESCRIPTOR_TYPE_STORAGE_IMAGE)
      br->layout->type[binding] = t;
   return true;
}

static nir_def *
buffer_index(nir_builder *b, unsigned binding, VkDescriptorType type)
{
   nir_def *res = nir_vulkan_resource_index(b, 3, 32, nir_imm_int(b, 0), .desc_set = 0, .binding = binding, .desc_type = type);
   nir_def *desc = nir_load_vulkan_descriptor(b, 3, 32, res, .desc_type = type);
   return nir_trim_vector(b, desc, 2);
}

static nir_deref_instr *
texture_deref(nir_builder *b, struct bridge *br, unsigned slot, enum glsl_sampler_dim dim, bool is_array, nir_alu_type type)
{
   if (slot >= AIR_VK_TEXTURE_SLOTS) {
      fail(br, "texture slot %u is past the %u this layout has", slot, AIR_VK_TEXTURE_SLOTS);
      return NULL;
   }
   if (!br->tex_var[slot]) {
      const struct glsl_type *t = glsl_texture_type(dim, is_array, nir_get_glsl_base_type_for_nir_type(type));
      nir_variable *v = nir_variable_create(b->shader, nir_var_uniform, t, "air_texture");
      v->data.descriptor_set = 0;
      v->data.binding = br->bind_base + AIR_VK_TEXTURE_BINDING + slot;
      br->tex_var[slot] = v;
      if (!declare(br, v->data.binding, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE))
         return NULL;
   }
   return nir_build_deref_var(b, br->tex_var[slot]);
}

static nir_deref_instr *
sampler_deref(nir_builder *b, struct bridge *br, unsigned slot)
{
   if (slot >= AIR_VK_SAMPLER_SLOTS) {
      fail(br, "sampler slot %u is past the %u this layout has", slot, AIR_VK_SAMPLER_SLOTS);
      return NULL;
   }
   if (!br->smp_var[slot]) {
      nir_variable *v = nir_variable_create(b->shader, nir_var_uniform, glsl_bare_sampler_type(), "air_sampler");
      v->data.descriptor_set = 0;
      v->data.binding = br->bind_base + AIR_VK_SAMPLER_BINDING + slot;
      br->smp_var[slot] = v;
      if (!declare(br, v->data.binding, VK_DESCRIPTOR_TYPE_SAMPLER))
         return NULL;
   }
   return nir_build_deref_var(b, br->smp_var[slot]);
}

static nir_deref_instr *
image_deref(nir_builder *b, struct bridge *br, unsigned slot, enum glsl_sampler_dim dim, bool is_array, nir_alu_type type,
            enum pipe_format format)
{
   if (slot >= AIR_VK_TEXTURE_SLOTS) {
      fail(br, "image slot %u is past the %u this layout has", slot, AIR_VK_TEXTURE_SLOTS);
      return NULL;
   }
   if (!br->img_var[slot]) {
      const struct glsl_type *t = glsl_image_type(dim, is_array, nir_get_glsl_base_type_for_nir_type(type));
      nir_variable *v = nir_variable_create(b->shader, nir_var_image, t, "air_image");
      v->data.descriptor_set = 0;
      v->data.binding = br->bind_base + AIR_VK_TEXTURE_BINDING + slot;
      v->data.image.format = format;
      br->img_var[slot] = v;
      if (!declare(br, v->data.binding, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE))
         return NULL;
   }
   return nir_build_deref_var(b, br->img_var[slot]);
}

static bool
is_image_index_op(nir_intrinsic_op op)
{
   switch (op) {
   case nir_intrinsic_image_load:
   case nir_intrinsic_image_sparse_load:
   case nir_intrinsic_image_store:
   case nir_intrinsic_image_atomic:
   case nir_intrinsic_image_atomic_swap:
   case nir_intrinsic_image_size:
   case nir_intrinsic_image_levels:
   case nir_intrinsic_image_samples:
      return true;
   default:
      return false;
   }
}

static bool
bridge_image(nir_builder *b, nir_intrinsic_instr *in, struct bridge *br)
{
   if (!nir_src_is_const(in->src[0])) {
      /* Mercury's level slots: a run-time choice among slot images. Not served yet. */
      fail(br, "an image chosen at run time (intrinsic %u%c) is not served on Turnip yet", in->intrinsic, ' ');
      return false;
   }
   unsigned slot = nir_src_as_uint(in->src[0]);
   nir_alu_type t = nir_type_float32;
   if (nir_intrinsic_has_dest_type(in))
      t = nir_intrinsic_dest_type(in);
   else if (nir_intrinsic_has_src_type(in))
      t = nir_intrinsic_src_type(in);
   else if (nir_intrinsic_has_atomic_op(in))
      t = nir_atomic_op_type(nir_intrinsic_atomic_op(in)) == nir_type_float ? nir_type_float32 : nir_type_uint32;
   nir_deref_instr *d = image_deref(b, br, slot, nir_intrinsic_image_dim(in), nir_intrinsic_image_array(in), t,
                                    nir_intrinsic_format(in));
   if (!d)
      return false;
   nir_rewrite_image_intrinsic(in, &d->def, nir_image_intrinsic_type_deref);
   return true;
}

static bool
bridge_intrinsic(nir_builder *b, nir_intrinsic_instr *in, struct bridge *br)
{
   b->cursor = nir_before_instr(&in->instr);
   int isrc = -1, osrc = -1;
   VkDescriptorType type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
   switch (in->intrinsic) {
   case nir_intrinsic_load_push_constant:
      /* the frontend's push constants (the null mask) are the stage's: rebase them */
      nir_intrinsic_set_base(in, nir_intrinsic_base(in) + br->push_base);
      br->layout->push_bytes = MAX2(br->layout->push_bytes, br->push_base + AIR_VK_PUSH_STAGE_BYTES);
      return true;
   case nir_intrinsic_load_ubo:
      isrc = 0, osrc = 1, type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
      break;
   case nir_intrinsic_load_ssbo:
   case nir_intrinsic_ssbo_atomic:
   case nir_intrinsic_ssbo_atomic_swap:
      isrc = 0, osrc = 1;
      break;
   case nir_intrinsic_get_ssbo_size:
      isrc = 0;
      break;
   case nir_intrinsic_store_ssbo:
      isrc = 1, osrc = 2;
      break;
   default:
      return is_image_index_op(in->intrinsic) ? bridge_image(b, in, br) : false;
   }

   if (!nir_src_is_const(in->src[isrc])) {
      fail(br, "a buffer chosen at run time (intrinsic %u%c) is not served on Turnip yet", in->intrinsic, ' ');
      return false;
   }
   unsigned n = nir_src_as_uint(in->src[isrc]);
   if (n >= AIR_VK_BUFFER_SLOTS) {
      fail(br, "buffer slot %u is past the %u this layout has", n, AIR_VK_BUFFER_SLOTS);
      return false;
   }
   unsigned binding = br->bind_base + AIR_VK_BUFFER_BINDING + n;
   if (!declare(br, binding, type))
      return false;
   nir_src_rewrite(&in->src[isrc], buffer_index(b, binding, type));

   if (osrc >= 0) {
      /* the part of Metal's offset below the descriptor alignment */
      nir_def *delta = nir_load_push_constant(b, 1, 32, nir_imm_int(b, 0), .base = br->push_base + 4 * n, .range = 4);
      nir_src_rewrite(&in->src[osrc], nir_iadd(b, in->src[osrc].ssa, delta));
      if (nir_intrinsic_has_align_mul(in) && nir_intrinsic_align_mul(in) > 4) {
         nir_intrinsic_set_align_mul(in, 4);
         nir_intrinsic_set_align_offset(in, nir_intrinsic_align_offset(in) % 4);
      }
      if (nir_intrinsic_has_range(in)) {
         nir_intrinsic_set_range_base(in, 0);
         nir_intrinsic_set_range(in, ~0);
      }
      br->layout->push_bytes = MAX2(br->layout->push_bytes, br->push_base + AIR_VK_PUSH_STAGE_BYTES);
   }
   return true;
}

static bool
bridge_tex(nir_builder *b, nir_tex_instr *tex, struct bridge *br)
{
   b->cursor = nir_before_instr(&tex->instr);
   if (nir_tex_instr_src_index(tex, nir_tex_src_texture_offset) >= 0 ||
       nir_tex_instr_src_index(tex, nir_tex_src_sampler_offset) >= 0) {
      fail(br, "a texture or sampler chosen at run time (texture %u, sampler %u) is not served on Turnip yet",
           tex->texture_index, tex->sampler_index);
      return false;
   }
   nir_deref_instr *t = texture_deref(b, br, tex->texture_index, tex->sampler_dim, tex->is_array, tex->dest_type);
   if (!t)
      return false;
   nir_tex_instr_add_src(tex, nir_tex_src_texture_deref, &t->def);
   if (nir_tex_instr_need_sampler(tex)) {
      nir_deref_instr *s = sampler_deref(b, br, tex->sampler_index);
      if (!s)
         return false;
      nir_tex_instr_add_src(tex, nir_tex_src_sampler_deref, &s->def);
   }
   tex->texture_index = 0;
   tex->sampler_index = 0;
   return true;
}

static bool
bridge_instr(nir_builder *b, nir_instr *instr, void *data)
{
   struct bridge *br = data;
   if (br->failed)
      return false;
   if (instr->type == nir_instr_type_intrinsic)
      return bridge_intrinsic(b, nir_instr_as_intrinsic(instr), br);
   if (instr->type == nir_instr_type_tex)
      return bridge_tex(b, nir_instr_as_tex(instr), br);
   return false;
}

bool
air_nir_to_vulkan(nir_shader *nir, unsigned stage, struct air_vk_layout *layout, char *why, size_t why_size)
{
   struct bridge br = {
      .layout = layout,
      .bind_base = stage * AIR_VK_STAGE_BINDINGS,
      .push_base = stage * AIR_VK_PUSH_STAGE_BYTES,
      .why = why,
      .why_size = why_size,
   };
   nir_shader_instructions_pass(nir, bridge_instr, nir_metadata_none, &br);
   if (br.failed)
      return false;
   nir->info.num_ubos = 0;
   nir->info.num_ssbos = 0;
   nir->info.num_textures = 0;
   nir->info.num_images = 0;
   return true;
}
