/*
 * SPDX-License-Identifier: MIT
 *
 * chl_vk.c, continued: render pipelines, depth/stencil states and the render encoder.
 */

static VkFormat
vertex_format(unsigned mtl)
{
   static const VkFormat map[56] = {
      [1] = VK_FORMAT_R8G8_UINT, [2] = VK_FORMAT_R8G8B8_UINT, [3] = VK_FORMAT_R8G8B8A8_UINT,
      [4] = VK_FORMAT_R8G8_SINT, [5] = VK_FORMAT_R8G8B8_SINT, [6] = VK_FORMAT_R8G8B8A8_SINT,
      [7] = VK_FORMAT_R8G8_UNORM, [8] = VK_FORMAT_R8G8B8_UNORM, [9] = VK_FORMAT_R8G8B8A8_UNORM,
      [10] = VK_FORMAT_R8G8_SNORM, [11] = VK_FORMAT_R8G8B8_SNORM, [12] = VK_FORMAT_R8G8B8A8_SNORM,
      [13] = VK_FORMAT_R16G16_UINT, [14] = VK_FORMAT_R16G16B16_UINT, [15] = VK_FORMAT_R16G16B16A16_UINT,
      [16] = VK_FORMAT_R16G16_SINT, [17] = VK_FORMAT_R16G16B16_SINT, [18] = VK_FORMAT_R16G16B16A16_SINT,
      [19] = VK_FORMAT_R16G16_UNORM, [20] = VK_FORMAT_R16G16B16_UNORM, [21] = VK_FORMAT_R16G16B16A16_UNORM,
      [22] = VK_FORMAT_R16G16_SNORM, [23] = VK_FORMAT_R16G16B16_SNORM, [24] = VK_FORMAT_R16G16B16A16_SNORM,
      [25] = VK_FORMAT_R16G16_SFLOAT, [26] = VK_FORMAT_R16G16B16_SFLOAT, [27] = VK_FORMAT_R16G16B16A16_SFLOAT,
      [28] = VK_FORMAT_R32_SFLOAT, [29] = VK_FORMAT_R32G32_SFLOAT, [30] = VK_FORMAT_R32G32B32_SFLOAT,
      [31] = VK_FORMAT_R32G32B32A32_SFLOAT,
      [32] = VK_FORMAT_R32_SINT, [33] = VK_FORMAT_R32G32_SINT, [34] = VK_FORMAT_R32G32B32_SINT, [35] = VK_FORMAT_R32G32B32A32_SINT,
      [36] = VK_FORMAT_R32_UINT, [37] = VK_FORMAT_R32G32_UINT, [38] = VK_FORMAT_R32G32B32_UINT, [39] = VK_FORMAT_R32G32B32A32_UINT,
      [40] = VK_FORMAT_A2B10G10R10_SNORM_PACK32, [41] = VK_FORMAT_A2B10G10R10_UNORM_PACK32,
      [42] = VK_FORMAT_B8G8R8A8_UNORM,
      [45] = VK_FORMAT_R8_UINT, [46] = VK_FORMAT_R8_SINT, [47] = VK_FORMAT_R8_UNORM, [48] = VK_FORMAT_R8_SNORM,
      [49] = VK_FORMAT_R16_UINT, [50] = VK_FORMAT_R16_SINT, [51] = VK_FORMAT_R16_UNORM, [52] = VK_FORMAT_R16_SNORM,
      [53] = VK_FORMAT_R16_SFLOAT, [54] = VK_FORMAT_B10G11R11_UFLOAT_PACK32, [55] = VK_FORMAT_E5B9G9R9_UFLOAT_PACK32,
   };
   return mtl < 56 ? map[mtl] : VK_FORMAT_UNDEFINED;
}

static VkBlendFactor
blend_factor(unsigned f)
{
   static const VkBlendFactor map[19] = {
      VK_BLEND_FACTOR_ZERO, VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_SRC_COLOR, VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
      VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, VK_BLEND_FACTOR_DST_COLOR,
      VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR, VK_BLEND_FACTOR_DST_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
      VK_BLEND_FACTOR_SRC_ALPHA_SATURATE, VK_BLEND_FACTOR_CONSTANT_COLOR, VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR,
      VK_BLEND_FACTOR_CONSTANT_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA, VK_BLEND_FACTOR_SRC1_COLOR,
      VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR, VK_BLEND_FACTOR_SRC1_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA,
   };
   return f < 19 ? map[f] : VK_BLEND_FACTOR_ONE;
}

static VkBlendOp
blend_op(unsigned op)
{
   static const VkBlendOp map[5] = { VK_BLEND_OP_ADD, VK_BLEND_OP_SUBTRACT, VK_BLEND_OP_REVERSE_SUBTRACT, VK_BLEND_OP_MIN,
                                     VK_BLEND_OP_MAX };
   return op < 5 ? map[op] : VK_BLEND_OP_ADD;
}

/* MTLColorWriteMask is red 8, green 4, blue 2, alpha 1 */
static VkColorComponentFlags
write_mask(unsigned m)
{
   return (m & 8 ? VK_COLOR_COMPONENT_R_BIT : 0) | (m & 4 ? VK_COLOR_COMPONENT_G_BIT : 0) | (m & 2 ? VK_COLOR_COMPONENT_B_BIT : 0) |
          (m & 1 ? VK_COLOR_COMPONENT_A_BIT : 0);
}

static VkStencilOp
stencil_op(unsigned op)
{
   static const VkStencilOp map[8] = { VK_STENCIL_OP_KEEP, VK_STENCIL_OP_ZERO, VK_STENCIL_OP_REPLACE,
                                       VK_STENCIL_OP_INCREMENT_AND_CLAMP, VK_STENCIL_OP_DECREMENT_AND_CLAMP, VK_STENCIL_OP_INVERT,
                                       VK_STENCIL_OP_INCREMENT_AND_WRAP, VK_STENCIL_OP_DECREMENT_AND_WRAP };
   return op < 8 ? map[op] : VK_STENCIL_OP_KEEP;
}

/* Metal links a fragment function's inputs to the vertex function's outputs by name; each stage numbered its own. */
static bool
link_varyings(struct chl_render_pipeline *p, char *why, size_t why_size)
{
   nir_foreach_shader_in_variable(var, p->fs.nir) {
      if (var->data.location < VARYING_SLOT_VAR0)
         continue;
      const struct air_varying *in = NULL, *out = NULL;
      for (unsigned i = 0; i < p->fs.info.num_varyings && !in; i++)
         if (p->fs.info.varyings[i].slot == (unsigned)var->data.location &&
             p->fs.info.varyings[i].component == var->data.location_frac)
            in = &p->fs.info.varyings[i];
      if (!in || !in->name)
         continue;
      for (unsigned i = 0; i < p->vs.info.num_varyings && !out; i++)
         if (p->vs.info.varyings[i].name && !strcmp(p->vs.info.varyings[i].name, in->name))
            out = &p->vs.info.varyings[i];
      if (!out) {
         say(why, why_size, "%s reads the varying %s, which %s does not output: Metal refuses a pipeline whose stages do not link",
             p->fs.info.entry_point ? p->fs.info.entry_point : "the fragment function", in->name,
             p->vs.info.entry_point ? p->vs.info.entry_point : "the vertex function");
         return false;
      }
      var->data.location = out->slot;
      var->data.location_frac = out->component;
   }
   return true;
}

struct chl_render_pipeline *
chl_render_pipeline_create(struct chl_device *d, const struct chl_render_pipeline_desc *desc, struct chl_pipeline_info *info,
                           char *why, size_t why_size)
{
   if (!desc || !desc->vertex.bitcode) {
      say(why, why_size, "a render pipeline needs a vertex function");
      return NULL;
   }
   struct chl_render_pipeline *p = calloc(1, sizeof(*p));
   if (!p) {
      say(why, why_size, "out of memory making a render pipeline");
      return NULL;
   }
   memset(build_ns, 0, sizeof(build_ns));
   build_misses = 0;
   obj_init(&p->o, d, K_RENDER);
   p->mem_ctx = ralloc_context(NULL);
   if (!translate(d, p->mem_ctx, &desc->vertex, MESA_SHADER_VERTEX, 0, &p->vs, &p->layout.bindings, why, why_size))
      goto fail;
   if (desc->fragment.bitcode &&
       !translate(d, p->mem_ctx, &desc->fragment, MESA_SHADER_FRAGMENT, 1, &p->fs, &p->layout.bindings, why, why_size))
      goto fail;
   if (p->fs.nir && !link_varyings(p, why, why_size))
      goto fail;
   struct chl_stage_info *st[2] = { &p->vs, &p->fs };
   if (!make_layout(d, &p->layout, st, p->fs.nir ? 2 : 1, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, why,
                    why_size))
      goto fail;

   /* attachments */
   VkPipelineColorBlendAttachmentState blend[8];
   for (unsigned i = 0; i < 8; i++) {
      const struct chl_format *f = desc->color_format[i] ? chl_format(desc->color_format[i]) : NULL;
      if (desc->color_format[i] && !f) {
         say(why, why_size, "colour attachment %u is pixel format %u, which Chlorophyll has no Vulkan format for", i,
             desc->color_format[i]);
         goto fail;
      }
      p->color_format[i] = f ? f->vk : VK_FORMAT_UNDEFINED;
      if (f)
         p->color_count = i + 1;
      const struct chl_blend *b = &desc->blend[i];
      blend[i] = (VkPipelineColorBlendAttachmentState){ b->enabled, blend_factor(b->src_rgb), blend_factor(b->dst_rgb),
                                                        blend_op(b->rgb_op), blend_factor(b->src_alpha), blend_factor(b->dst_alpha),
                                                        blend_op(b->alpha_op), write_mask(b->write_mask) };
   }
   const struct chl_format *df = desc->depth_format ? chl_format(desc->depth_format) : NULL;
   const struct chl_format *sf = desc->stencil_format ? chl_format(desc->stencil_format) : NULL;
   p->depth_format = df ? df->vk : VK_FORMAT_UNDEFINED;
   p->stencil_format = sf ? sf->vk : VK_FORMAT_UNDEFINED;
   p->samples = desc->sample_count ? desc->sample_count : 1;

   /* vertex input: Metal's descriptor, matched to the attributes the vertex function reads */
   VkVertexInputAttributeDescription va[CHL_MAX_ATTRIBUTES];
   unsigned nva = 0;
   bool used_binding[CHL_MAX_BUFFERS] = { false };
   for (unsigned i = 0; i < p->vs.info.num_vertex_attributes; i++) {
      const struct air_vertex_attribute *a = &p->vs.info.vertex_attributes[i];
      if (a->index >= CHL_MAX_ATTRIBUTES)
         continue;
      const struct chl_vertex_attribute *da = &desc->attribute[a->index];
      if (!da->format) {
         say(why, why_size, "%s reads [[attribute(%u)]] and the vertex descriptor configures none",
             p->vs.info.entry_point ? p->vs.info.entry_point : "the vertex function", a->index);
         goto fail;
      }
      VkFormat vf = vertex_format(da->format);
      if (!vf || da->buffer_index >= CHL_MAX_BUFFERS) {
         say(why, why_size, "vertex format %u (attribute %u, buffer %u) is not served", da->format, a->index, da->buffer_index);
         goto fail;
      }
      va[nva++] = (VkVertexInputAttributeDescription){ a->index, da->buffer_index, vf, da->offset };
      used_binding[da->buffer_index] = true;
   }
   for (unsigned b = 0; b < CHL_MAX_BUFFERS; b++) {
      if (!used_binding[b])
         continue;
      const struct chl_vertex_layout *l = &desc->layout[b];
      if (l->step_function == 2 && l->step_rate > 1) {
         say(why, why_size, "a per-instance step rate of %u (buffer %u) is not served yet", l->step_rate, b);
         goto fail;
      }
      p->vbind[p->n_vbind++] = (VkVertexInputBindingDescription){
         b, l->step_function == 0 ? 0 : l->stride,
         l->step_function == 2 ? VK_VERTEX_INPUT_RATE_INSTANCE : VK_VERTEX_INPUT_RATE_VERTEX };
      p->vertex_stream_mask |= 1u << b;
   }

   VkPipelineShaderStageNirCreateInfoMESA nci[2] = {
      { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_NIR_CREATE_INFO_MESA, NULL, p->vs.nir },
      { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_NIR_CREATE_INFO_MESA, NULL, p->fs.nir },
   };
   VkPipelineShaderStageCreateInfo stages[2] = {
      { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, &nci[0], 0, VK_SHADER_STAGE_VERTEX_BIT, VK_NULL_HANDLE, "main", NULL },
      { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, &nci[1], 0, VK_SHADER_STAGE_FRAGMENT_BIT, VK_NULL_HANDLE, "main", NULL },
   };
   VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, NULL, 0, p->n_vbind,
                                               p->vbind, nva, va };
   VkPrimitiveTopology topo = desc->topology_class == 1 ? VK_PRIMITIVE_TOPOLOGY_POINT_LIST
                            : desc->topology_class == 2 ? VK_PRIMITIVE_TOPOLOGY_LINE_LIST : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
   VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, NULL, 0, topo, 0 };
   VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, NULL, 0, 1, NULL, 1, NULL };
   VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
   rs.polygonMode = VK_POLYGON_MODE_FILL;
   rs.lineWidth = 1.0f;
   rs.rasterizerDiscardEnable = VK_FALSE;
   VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
   ms.rasterizationSamples = (VkSampleCountFlagBits)p->samples;
   ms.alphaToCoverageEnable = desc->alpha_to_coverage;
   VkPipelineDepthStencilStateCreateInfo dss = { VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
   dss.minDepthBounds = 0, dss.maxDepthBounds = 1;
   /* a framebuffer fetch sees what the earlier primitives left, as on Apple's tile memory: rasterization-order access */
   VkPipelineColorBlendStateCreateInfo cbs = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, NULL,
                                               p->fs.nir && p->fs.info.fbfetch_targets
                                                  ? VK_PIPELINE_COLOR_BLEND_STATE_CREATE_RASTERIZATION_ORDER_ATTACHMENT_ACCESS_BIT_EXT : 0,
                                               VK_FALSE, VK_LOGIC_OP_COPY, p->color_count, blend, { 0, 0, 0, 0 } };
   static const VkDynamicState dyn[] = {
      VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_STENCIL_REFERENCE, VK_DYNAMIC_STATE_BLEND_CONSTANTS,
      VK_DYNAMIC_STATE_DEPTH_BIAS, VK_DYNAMIC_STATE_CULL_MODE, VK_DYNAMIC_STATE_FRONT_FACE, VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY,
      VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE, VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE, VK_DYNAMIC_STATE_DEPTH_COMPARE_OP,
      VK_DYNAMIC_STATE_STENCIL_TEST_ENABLE, VK_DYNAMIC_STATE_STENCIL_OP, VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK,
      VK_DYNAMIC_STATE_STENCIL_WRITE_MASK, VK_DYNAMIC_STATE_DEPTH_BIAS_ENABLE, VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE,
   };
   VkPipelineDynamicStateCreateInfo ds = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, NULL, 0,
                                           sizeof(dyn) / sizeof(dyn[0]), dyn };
   VkPipelineRenderingCreateInfo ri = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, NULL, 0, p->color_count, p->color_format,
                                        p->depth_format, p->stencil_format };
   VkGraphicsPipelineCreateInfo gci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &ri, 0, p->fs.nir ? 2u : 1u, stages, &vi, &ia,
                                        NULL, &vp, &rs, &ms, &dss, &cbs, &ds, p->layout.layout, VK_NULL_HANDLE, 0,
                                        VK_NULL_HANDLE, -1 };
   uint64_t t0 = build_now();
   VkResult r = d->vk.vkCreateGraphicsPipelines(d->dev, VK_NULL_HANDLE, 1, &gci, NULL, &p->vk);
   build_ns[2] = build_now() - t0;
   if (r != VK_SUCCESS) {
      say(why, why_size, "Turnip would not compile the render pipeline %s + %s (VkResult %d)",
          p->vs.info.entry_point ? p->vs.info.entry_point : "vertex",
          p->fs.nir && p->fs.info.entry_point ? p->fs.info.entry_point : "no fragment", r);
      goto fail;
   }
   fill_info(d, info, &p->vs, p->fs.nir ? &p->fs : NULL);
   return p;
fail:
   free_layout(d, &p->layout);
   ralloc_free(p->mem_ctx);
   free(p);
   return NULL;
}

struct chl_depth_stencil *
chl_depth_stencil_create(struct chl_device *d, const struct chl_depth_stencil_desc *desc, char *why, size_t why_size)
{
   struct chl_depth_stencil *s = calloc(1, sizeof(*s));
   if (!s || !desc) {
      say(why, why_size, "out of memory making a depth/stencil state");
      free(s);
      return NULL;
   }
   obj_init(&s->o, d, K_DEPTH_STENCIL);
   s->d = *desc;
   return s;
}

/* ---- render encoder ---- */
static void
apply_depth_stencil(struct chl_cmdbuf *cb)
{
   struct chl_device *d = cb->dev;
   const struct chl_depth_stencil_desc *ds = cb->ds ? &cb->ds->d : NULL;
   /* no state set is Metal's default: always passes, writes nothing */
   bool test = ds && (ds->depth_compare != 7 || ds->depth_write);
   d->vk.vkCmdSetDepthTestEnable(cb->cb, test);
   d->vk.vkCmdSetDepthWriteEnable(cb->cb, ds && ds->depth_write);
   d->vk.vkCmdSetDepthCompareOp(cb->cb, ds ? compare_op(ds->depth_compare) : VK_COMPARE_OP_ALWAYS);
   d->vk.vkCmdSetStencilTestEnable(cb->cb, ds && ds->stencil_enabled);
   const struct chl_stencil_face none = { 7, 0, 0, 0, 0xff, 0xff };
   const struct chl_stencil_face *f[2] = { ds ? &ds->front : &none, ds ? &ds->back : &none };
   for (int i = 0; i < 2; i++) {
      VkStencilFaceFlags face = i ? VK_STENCIL_FACE_BACK_BIT : VK_STENCIL_FACE_FRONT_BIT;
      d->vk.vkCmdSetStencilOp(cb->cb, face, stencil_op(f[i]->fail), stencil_op(f[i]->pass), stencil_op(f[i]->depth_fail),
                              compare_op(f[i]->compare));
      d->vk.vkCmdSetStencilCompareMask(cb->cb, face, f[i]->read_mask);
      d->vk.vkCmdSetStencilWriteMask(cb->cb, face, f[i]->write_mask);
   }
}

static void
attachment_info(struct chl_cmdbuf *cb, const struct chl_attachment *a, VkRenderingAttachmentInfo *out, bool depth, bool stencil)
{
   memset(out, 0, sizeof(*out));
   out->sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
   if (!a->texture)
      return;
   out->imageView = attachment_view(a->texture, a->level, a->slice);
   out->imageLayout = VK_IMAGE_LAYOUT_GENERAL;
   /* MTLLoadActionDontCare reads as zero: CoreAnimation relies on it */
   out->loadOp = a->load_action == 1 ? VK_ATTACHMENT_LOAD_OP_LOAD : VK_ATTACHMENT_LOAD_OP_CLEAR;
   out->storeOp = (a->store_action == 1 || a->store_action == 3) ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE;
   if (depth || stencil) {
      out->clearValue.depthStencil.depth = depth ? (a->load_action == 2 ? a->clear[0] : 0.0f) : 0.0f;
      out->clearValue.depthStencil.stencil = a->load_action == 2 ? a->clear_stencil : 0;
   } else if (a->load_action == 2) {
      memcpy(out->clearValue.color.float32, a->clear, sizeof(a->clear));
   }
   if ((a->store_action == 2 || a->store_action == 3) && a->resolve) {
      out->resolveMode = (depth || stencil) ? VK_RESOLVE_MODE_SAMPLE_ZERO_BIT : VK_RESOLVE_MODE_AVERAGE_BIT;
      out->resolveImageView = attachment_view(a->resolve, a->resolve_level, a->resolve_slice);
      out->resolveImageLayout = VK_IMAGE_LAYOUT_GENERAL;
      cb_hold(cb, &a->resolve->o);
   }
   cb_hold(cb, &a->texture->o);
}

int
chl_render_begin(struct chl_cmdbuf *cb, const struct chl_render_pass *pass, char *why, size_t why_size)
{
   P_START(pt);
   struct chl_device *d = cb->dev;
   if (cb->enc == ENC_RENDER)
      chl_render_end(cb);
   unsigned w = pass->width, h = pass->height, ncolor = 0;
   const struct chl_attachment *first = NULL;
   for (unsigned i = 0; i < 8; i++)
      if (pass->color[i].texture) {
         ncolor = i + 1;
         if (!first)
            first = &pass->color[i];
      }
   if (!first)
      first = pass->depth.texture ? &pass->depth : pass->stencil.texture ? &pass->stencil : NULL;
   if (!first) {
      say(why, why_size, "a render pass with no attachment");
      return -1;
   }
   if (!w || !h) {
      unsigned lw = first->texture->width >> first->level, lh = first->texture->height >> first->level;
      w = lw ? lw : 1;
      h = lh ? lh : 1;
   }
   VkRenderingAttachmentInfo col[8], dep, sten;
   memset(cb->pass_color, 0, sizeof(cb->pass_color));
   for (unsigned i = 0; i < ncolor; i++) {
      attachment_info(cb, &pass->color[i], &col[i], false, false);
      cb->pass_color[i] = col[i].imageView;
   }
   attachment_info(cb, &pass->depth, &dep, true, false);
   attachment_info(cb, &pass->stencil, &sten, false, true);
   /* a combined depth/stencil texture bound to both is one attachment in two roles */
   full_barrier(d, cb->cb);
   if (cb->qp && cb->n_pass < CHL_PASS_MAX) {
      struct chl_pass_note *n = &cb->pass_notes[cb->n_pass];
      memset(n, 0, sizeof(*n));
      n->w = w;
      n->h = h;
      n->colors = ncolor;
      d->vk.vkCmdWriteTimestamp(cb->cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, cb->qp, 1 + 2 * cb->n_pass);
   }
   VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, { { 0, 0 }, { w, h } }, 1, 0, ncolor, col,
                          pass->depth.texture ? &dep : NULL, pass->stencil.texture ? &sten : NULL };
   d->vk.vkCmdBeginRendering(cb->cb, &ri);
   cb->enc = ENC_RENDER;
   cb->pass_width = w;
   cb->pass_height = h;
   cb->rp = NULL;
   cb->ds = NULL;
   cb->topology_set = false;
   /* Metal's defaults for a new encoder */
   chl_set_viewport(cb, 0, 0, w, h, 0, 1);
   chl_set_scissor(cb, 0, 0, w, h);
   chl_set_cull(cb, 0, 0);
   chl_set_depth_bias(cb, 0, 0, 0);
   chl_set_stencil_reference(cb, 0, 0);
   static const float zero[4] = { 0, 0, 0, 0 };
   chl_set_blend_color(cb, zero);
   apply_depth_stencil(cb);
   d->vk.vkCmdSetDepthBiasEnable(cb->cb, VK_FALSE);
   d->vk.vkCmdSetPrimitiveRestartEnable(cb->cb, VK_FALSE);
   P_MARK(pt, CHL_P_BEGIN);
   return 0;
}

void
chl_set_render_pipeline(struct chl_cmdbuf *cb, struct chl_render_pipeline *p)
{
   if (cb->rp == p)
      return;
   P_START(pt);
   cb->rp = p;
   cb_hold(cb, &p->o);
   if (cb->qp && cb->n_pass < CHL_PASS_MAX && cb->enc == ENC_RENDER && p->fs.info.entry_point) {
      struct chl_pass_note *n = &cb->pass_notes[cb->n_pass];
      bool seen = false;
      for (unsigned i = 0; i < n->nfs && !seen; i++)
         seen = !strncmp(n->fs[i], p->fs.info.entry_point, sizeof(n->fs[i]) - 1);
      if (!seen && n->nfs < 4)
         snprintf(n->fs[n->nfs++], sizeof(n->fs[0]), "%s", p->fs.info.entry_point);
   }
   cb->dev->vk.vkCmdBindPipeline(cb->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, p->vk);
   P_MARK(pt, CHL_P_PIPE);
}

void
chl_set_depth_stencil(struct chl_cmdbuf *cb, struct chl_depth_stencil *ds)
{
   if (cb->ds == ds)
      return;
   cb->ds = ds;
   if (ds)
      cb_hold(cb, &ds->o);
   apply_depth_stencil(cb);
}

void
chl_set_viewport(struct chl_cmdbuf *cb, double x, double y, double w, double h, double znear, double zfar)
{
   /* Metal's clip space has y up and its window origin top-left; a negative height gives the same mapping in Vulkan */
   VkViewport v = { (float)x, (float)(y + h), (float)w, (float)-h, (float)znear, (float)zfar };
   cb->dev->vk.vkCmdSetViewport(cb->cb, 0, 1, &v);
}

void
chl_set_scissor(struct chl_cmdbuf *cb, unsigned x, unsigned y, unsigned w, unsigned h)
{
   unsigned x1 = x + w > cb->pass_width ? cb->pass_width : x + w, y1 = y + h > cb->pass_height ? cb->pass_height : y + h;
   x = x > cb->pass_width ? cb->pass_width : x;
   y = y > cb->pass_height ? cb->pass_height : y;
   VkRect2D r = { { (int32_t)x, (int32_t)y }, { x1 - x, y1 - y } };
   cb->dev->vk.vkCmdSetScissor(cb->cb, 0, 1, &r);
}

void
chl_set_cull(struct chl_cmdbuf *cb, unsigned mtl_cull_mode, unsigned mtl_winding)
{
   /* MTLCullMode none 0, front 1, back 2; MTLWinding clockwise 0, counter-clockwise 1 (front-facing) */
   cb->dev->vk.vkCmdSetCullMode(cb->cb, mtl_cull_mode == 1 ? VK_CULL_MODE_FRONT_BIT : mtl_cull_mode == 2 ? VK_CULL_MODE_BACK_BIT
                                                                                                          : VK_CULL_MODE_NONE);
   cb->dev->vk.vkCmdSetFrontFace(cb->cb, mtl_winding ? VK_FRONT_FACE_COUNTER_CLOCKWISE : VK_FRONT_FACE_CLOCKWISE);
}

void
chl_set_depth_bias(struct chl_cmdbuf *cb, float bias, float slope, float clamp)
{
   cb->dev->vk.vkCmdSetDepthBiasEnable(cb->cb, bias != 0 || slope != 0);
   cb->dev->vk.vkCmdSetDepthBias(cb->cb, bias, clamp, slope);
}

void
chl_set_stencil_reference(struct chl_cmdbuf *cb, unsigned front, unsigned back)
{
   cb->dev->vk.vkCmdSetStencilReference(cb->cb, VK_STENCIL_FACE_FRONT_BIT, front);
   cb->dev->vk.vkCmdSetStencilReference(cb->cb, VK_STENCIL_FACE_BACK_BIT, back);
}

void
chl_set_blend_color(struct chl_cmdbuf *cb, const float rgba[4])
{
   cb->dev->vk.vkCmdSetBlendConstants(cb->cb, rgba);
}

static int
draw_prologue(struct chl_cmdbuf *cb, unsigned mtl_primitive, bool indexed, char *why, size_t why_size)
{
   P_START(pt);
   struct chl_device *d = cb->dev;
   struct chl_render_pipeline *p = cb->rp;
   if (cb->enc != ENC_RENDER || !p) {
      say(why, why_size, cb->enc != ENC_RENDER ? "a draw outside a render pass" : "a draw with no render pipeline set");
      return -1;
   }
   static const VkPrimitiveTopology topo[5] = { VK_PRIMITIVE_TOPOLOGY_POINT_LIST, VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
                                                VK_PRIMITIVE_TOPOLOGY_LINE_STRIP, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                                                VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP };
   if (mtl_primitive > 4) {
      say(why, why_size, "primitive type %u is not one of MTLPrimitiveType's five", mtl_primitive);
      return -1;
   }
   if (!cb->topology_set || cb->topology != topo[mtl_primitive]) {
      d->vk.vkCmdSetPrimitiveTopology(cb->cb, topo[mtl_primitive]);
      cb->topology = topo[mtl_primitive];
      cb->topology_set = true;
   }
   /* Metal restarts strips at the type's largest index, always */
   d->vk.vkCmdSetPrimitiveRestartEnable(cb->cb, indexed && (mtl_primitive == 2 || mtl_primitive == 4));
   /* vertex streams, from Metal's vertex buffer table */
   for (unsigned i = 0; i < p->n_vbind; i++) {
      unsigned b = p->vbind[i].binding;
      struct chl_buffer *buf = cb->bind[0].buf[b];
      if (!buf) {
         say(why, why_size, "the vertex descriptor reads buffer %u and nothing is bound there", b);
         return -1;
      }
      VkDeviceSize off = cb->bind[0].off[b];
      d->vk.vkCmdBindVertexBuffers(cb->cb, b, 1, &buf->vk, &off);
   }
   P_MARK(pt, CHL_P_VB);
   return flush_bindings(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, &p->layout, why, why_size);
}

int
chl_draw(struct chl_cmdbuf *cb, unsigned mtl_primitive, unsigned vertex_start, unsigned vertex_count, unsigned instances,
         unsigned base_instance, char *why, size_t why_size)
{
   if (!vertex_count)
      return 0;
   if (cb->qp && cb->n_pass < CHL_PASS_MAX)
      cb->pass_notes[cb->n_pass].draws++;
   if (draw_prologue(cb, mtl_primitive, false, why, why_size) != 0)
      return -1;
   P_START(pt);
   cb->dev->vk.vkCmdDraw(cb->cb, vertex_count, instances ? instances : 1, vertex_start, base_instance);
   P_MARK(pt, CHL_P_DRAW);
   return 0;
}

int
chl_draw_indexed(struct chl_cmdbuf *cb, unsigned mtl_primitive, unsigned index_count, unsigned mtl_index_type,
                 struct chl_buffer *index_buffer, size_t index_offset, unsigned instances, int base_vertex, unsigned base_instance,
                 char *why, size_t why_size)
{
   if (!index_count)
      return 0;
   if (cb->qp && cb->n_pass < CHL_PASS_MAX)
      cb->pass_notes[cb->n_pass].draws++;
   if (!index_buffer || mtl_index_type > 1) {
      say(why, why_size, "an indexed draw with %s", index_buffer ? "an index type that is not MTLIndexType's" : "no index buffer");
      return -1;
   }
   if (draw_prologue(cb, mtl_primitive, true, why, why_size) != 0)
      return -1;
   P_START(pt);
   cb_hold(cb, &index_buffer->o);
   cb->dev->vk.vkCmdBindIndexBuffer(cb->cb, index_buffer->vk, index_offset, mtl_index_type ? VK_INDEX_TYPE_UINT32 : VK_INDEX_TYPE_UINT16);
   cb->dev->vk.vkCmdDrawIndexed(cb->cb, index_count, instances ? instances : 1, 0, base_vertex, base_instance);
   P_MARK(pt, CHL_P_DRAW);
   return 0;
}

void
chl_render_end(struct chl_cmdbuf *cb)
{
   if (cb->enc != ENC_RENDER)
      return;
   P_START(pt);
   cb->dev->vk.vkCmdEndRendering(cb->cb);
   full_barrier(cb->dev, cb->cb);
   if (cb->qp && cb->n_pass < CHL_PASS_MAX) {
      cb->dev->vk.vkCmdWriteTimestamp(cb->cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, cb->qp, 2 + 2 * cb->n_pass);
      cb->n_pass++;
   }
   cb->enc = ENC_NONE;
   cb->rp = NULL;
   P_MARK(pt, CHL_P_END);
}
