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
   const struct air_shader_info *info;
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
      /* a void result type: one slot is read by fetches of its element type and by size queries (int), and a void type
       * is the one NIR accepts with both; Turnip's descriptors do not depend on it */
      const struct glsl_type *t = glsl_texture_type(dim, is_array, GLSL_TYPE_VOID);
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
      const struct glsl_type *t = glsl_image_type(dim, is_array, GLSL_TYPE_VOID);
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

/* image_<op>(index, ...) as image_deref_<op>(deref, ...) at the cursor, `in` left in place; returns its def (NULL for a store).
 * nir_rewrite_image_intrinsic has no deref direction. */
static nir_def *
emit_image_deref(nir_builder *b, nir_intrinsic_instr *in, nir_deref_instr *d)
{
   nir_intrinsic_op op;
   switch (in->intrinsic) {
   case nir_intrinsic_image_load: op = nir_intrinsic_image_deref_load; break;
   case nir_intrinsic_image_sparse_load: op = nir_intrinsic_image_deref_sparse_load; break;
   case nir_intrinsic_image_store: op = nir_intrinsic_image_deref_store; break;
   case nir_intrinsic_image_atomic: op = nir_intrinsic_image_deref_atomic; break;
   case nir_intrinsic_image_atomic_swap: op = nir_intrinsic_image_deref_atomic_swap; break;
   case nir_intrinsic_image_size: op = nir_intrinsic_image_deref_size; break;
   case nir_intrinsic_image_levels: op = nir_intrinsic_image_deref_levels; break;
   default: op = nir_intrinsic_image_deref_samples; break;
   }
   const nir_intrinsic_info *info = &nir_intrinsic_infos[op];
   nir_intrinsic_instr *n = nir_intrinsic_instr_create(b->shader, op);
   n->num_components = in->num_components;
   n->src[0] = nir_src_for_ssa(&d->def);
   for (unsigned i = 1; i < info->num_srcs; i++)
      n->src[i] = nir_src_for_ssa(in->src[i].ssa);
   nir_intrinsic_set_image_dim(n, nir_intrinsic_image_dim(in));
   nir_intrinsic_set_image_array(n, nir_intrinsic_image_array(in));
   nir_intrinsic_set_format(n, nir_intrinsic_format(in));
   nir_intrinsic_set_access(n, nir_intrinsic_access(in));
   if (nir_intrinsic_has_dest_type(in))
      nir_intrinsic_set_dest_type(n, nir_intrinsic_dest_type(in));
   if (nir_intrinsic_has_src_type(in))
      nir_intrinsic_set_src_type(n, nir_intrinsic_src_type(in));
   if (nir_intrinsic_has_atomic_op(in))
      nir_intrinsic_set_atomic_op(n, nir_intrinsic_atomic_op(in));
   if (info->has_dest)
      nir_def_init(&n->instr, &n->def, in->def.num_components, in->def.bit_size);
   nir_builder_instr_insert(b, &n->instr);
   return info->has_dest ? &n->def : NULL;
}

static nir_alu_type
image_type(nir_intrinsic_instr *in)
{
   if (nir_intrinsic_has_dest_type(in))
      return nir_intrinsic_dest_type(in);
   if (nir_intrinsic_has_src_type(in))
      return nir_intrinsic_src_type(in);
   if (nir_intrinsic_has_atomic_op(in))
      return nir_atomic_op_type(nir_intrinsic_atomic_op(in)) == nir_type_float ? nir_type_float32 : nir_type_uint32;
   return nir_type_float32;
}

static bool
bridge_image(nir_builder *b, nir_intrinsic_instr *in, struct bridge *br)
{
   bool has_dest = nir_intrinsic_infos[in->intrinsic].has_dest;
   nir_def *result = NULL;
   if (nir_src_is_const(in->src[0])) {
      nir_deref_instr *d = image_deref(b, br, nir_src_as_uint(in->src[0]), nir_intrinsic_image_dim(in),
                                       nir_intrinsic_image_array(in), image_type(in), nir_intrinsic_format(in));
      if (!d)
         return false;
      result = emit_image_deref(b, in, d);
   } else {
      /* An image chosen at run time. Mercury's VariableBlurrer::downsample writes the level `lods.y`: the frontend gives
       * each level L >= 1 an image slot of its own (level_base + L - 1) and indexes them. One copy of the access per slot
       * the index can be, under an if-chain, each on a constant slot (Turnip's own pattern for a run-time set index). */
      unsigned cand[AIR_VK_TEXTURE_SLOTS], nc = 0;
      for (unsigned i = 0; br->info && i < br->info->num_resources; i++) {
         const struct air_resource *r = &br->info->resources[i];
         if (r->kind != AIR_RESOURCE_IMAGE)
            continue;
         if (r->index < AIR_VK_TEXTURE_SLOTS && nc < AIR_VK_TEXTURE_SLOTS)
            cand[nc++] = r->index;
         for (unsigned l = 0; l < r->level_slots && nc < AIR_VK_TEXTURE_SLOTS; l++)
            if (r->level_base + l < AIR_VK_TEXTURE_SLOTS)
               cand[nc++] = r->level_base + l;
      }
      if (!nc) {
         fail(br, "an image chosen at run time and no image it can be (intrinsic %u%c)", in->intrinsic, ' ');
         return false;
      }
      nir_def *index = in->src[0].ssa;
      nir_def *v[AIR_VK_TEXTURE_SLOTS];
      for (unsigned k = 0; k < nc; k++) {
         nir_push_if(b, nir_ieq_imm(b, index, cand[k]));
         nir_deref_instr *d = image_deref(b, br, cand[k], nir_intrinsic_image_dim(in), nir_intrinsic_image_array(in),
                                          image_type(in), nir_intrinsic_format(in));
         if (!d)
            return false;
         v[k] = emit_image_deref(b, in, d);
         nir_push_else(b, NULL);
      }
      if (has_dest)
         result = nir_undef(b, in->def.num_components, in->def.bit_size);
      for (int k = (int)nc - 1; k >= 0; k--) {
         nir_pop_if(b, NULL);
         if (has_dest)
            result = nir_if_phi(b, v[k], result);
      }
   }
   if (has_dest)
      nir_def_rewrite_uses(&in->def, result);
   nir_instr_remove(&in->instr);
   return true;
}

static bool
bridge_intrinsic(nir_builder *b, nir_intrinsic_instr *in, struct bridge *br)
{
   b->cursor = nir_before_instr(&in->instr);
   int isrc = -1, osrc = -1;
   VkDescriptorType type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
   switch (in->intrinsic) {
   case nir_intrinsic_load_push_constant: {
      /* the frontend's push constants (the null mask) are the stage's: rebase them. The byte offset goes into the source
       * with base 0: Turnip's lower_load_push_constant reads `base` as dwords where gather_push_constants reads it as bytes,
       * and its own SPIR-V path always has base 0. */
      nir_def *off = nir_iadd_imm(b, in->src[0].ssa, nir_intrinsic_base(in) + br->push_base);
      nir_src_rewrite(&in->src[0], off);
      nir_intrinsic_set_base(in, 0);
      nir_intrinsic_set_range(in, br->push_base + AIR_VK_PUSH_STAGE_BYTES);
      br->layout->push_bytes = MAX2(br->layout->push_bytes, br->push_base + AIR_VK_PUSH_STAGE_BYTES);
      return true;
   }
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
      nir_def *delta = nir_load_push_constant(b, 1, 32, nir_imm_int(b, br->push_base + 4 * n), .base = 0,
                                              .range = br->push_base + AIR_VK_PUSH_STAGE_BYTES);
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
air_nir_to_vulkan(nir_shader *nir, const struct air_shader_info *info, unsigned stage, struct air_vk_layout *layout, char *why,
                  size_t why_size)
{
   struct bridge br = {
      .layout = layout,
      .info = info,
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
