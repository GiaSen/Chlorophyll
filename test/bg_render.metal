// SPDX-License-Identifier: MIT
// Render test shaders for the BGMTLDevice probe: a coloured triangle and a textured quad.
#include <metal_stdlib>
using namespace metal;

struct V { float4 pos [[position]]; float4 color; float2 uv; };

// positions and colours from buffer(0): float4 pos, float4 color per vertex (stride 32)
vertex V bg_vs(uint vid [[vertex_id]], device const float4 *data [[buffer(0)]])
{
   V v;
   v.pos = data[vid * 2];
   v.color = data[vid * 2 + 1];
   v.uv = v.pos.xy * 0.5 + 0.5;
   return v;
}

fragment float4 bg_fs_color(V in [[stage_in]]) { return in.color; }

fragment float4 bg_fs_tex(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
   return t.sample(s, in.uv);
}

// the same, with the sampler written into the shader (a constexpr sampler: AIR's inline sampler state), as CoreAnimation does
fragment float4 bg_fs_tex_inline(V in [[stage_in]], texture2d<float> t [[texture(0)]])
{
   constexpr sampler s(filter::nearest, address::clamp_to_edge);
   return t.sample(s, in.uv);
}

// linear filtering, an explicit lod and a constant-buffer offset: the shape of most of CoreAnimation's taps
struct U { float2 off; };
fragment float4 bg_fs_tex_linear(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant U &u [[buffer(1)]])
{
   return t.sample(s, in.uv + u.off, level(0));
}

// the same texture at a high slot, as CoreAnimation's shaders have it ([[texture(3)]])
fragment float4 bg_fs_tex3(V in [[stage_in]], texture2d<float> t [[texture(3)]], sampler s [[sampler(0)]])
{
   return t.sample(s, in.uv, level(0));
}

// a fragment stage with the varyings of CoreAnimation's std_vert0_*: color (float4) and texcoord0_0 (float2)
struct CAV { float4 pos [[position]]; float4 color; float2 texcoord0_0; };
fragment float4 bg_fs_ca_color(CAV in [[stage_in]]) { return in.color; }
