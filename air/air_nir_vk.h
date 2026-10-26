/*
 * SPDX-License-Identifier: MIT
 * Chlorophyll on Turnip: the AIR frontend's Metal-numbered resources onto chl's push-descriptor layout (air_nir_vk.c).
 */
#ifndef AIR_NIR_VK_H
#define AIR_NIR_VK_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nir_shader nir_shader;
struct air_shader_info;

#define AIR_VK_BUFFER_BINDING   0     /* [[buffer(n)]] at stage base + n */
#define AIR_VK_BUFFER_SLOTS     31
#define AIR_VK_TEXTURE_BINDING  32    /* [[texture(n)]] at stage base + 32 + n */
#define AIR_VK_TEXTURE_SLOTS    32
#define AIR_VK_SAMPLER_BINDING  64    /* [[sampler(n)]] at stage base + 64 + n */
#define AIR_VK_SAMPLER_SLOTS    16
#define AIR_VK_STAGE_BINDINGS   80    /* stage 0 (vertex or compute) 0..79, stage 1 (fragment) 80..159 */
#define AIR_VK_MAX_BINDINGS     160
#define AIR_VK_PUSH_STAGE_BYTES 128   /* 32 words a stage: buffer offset remainders 0..30, null-texture mask 31 */

struct air_vk_layout {
   int type[AIR_VK_MAX_BINDINGS];   /* VkDescriptorType + 1 of each binding a stage uses, 0 for none */
   unsigned push_bytes;             /* bytes of push constants the stages read, from 0 */
};

/* Rewrites `nir` (stage 0: vertex or compute, 1: fragment; `info` is its air_shader_info) in place and accumulates its bindings into `layout`. false with a
 * sentence in `why` for what this layout cannot serve yet. */
bool air_nir_to_vulkan(nir_shader *nir, const struct air_shader_info *info, unsigned stage, struct air_vk_layout *layout,
                       char *why, size_t why_size);

#ifdef __cplusplus
}
#endif

#endif
