// SPDX-License-Identifier: MIT
// the body bg_fs_linked links in (its own module, as a separate library function): red from the colour's blue, green
// from the texture it is handed, read through a sampler of its own (RenderBox's custom_fn has both), blue from red
#include <metal_stdlib>
using namespace metal;
[[visible]] float4 custom_fn(float4 c, texture2d<float> t)
{
   constexpr sampler s(filter::nearest, coord::normalized);
   return float4(c.b, t.sample(s, float2(0.5)).g, c.r, 1.0);
}
