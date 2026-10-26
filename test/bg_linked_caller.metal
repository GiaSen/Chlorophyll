// SPDX-License-Identifier: MIT
// a fragment stage that calls a function it only declares [[visible]]: the pipeline links the body in
// (MTLRenderPipelineDescriptor.fragmentLinkedFunctions), as iOS 26's RenderBox does with its effect functions
#include <metal_stdlib>
using namespace metal;
struct VP { float4 pos [[position]]; float4 color; float2 uv; };
[[visible]] float4 custom_fn(float4 c, texture2d<float> t);
fragment float4 bg_fs_linked(VP in [[stage_in]], texture2d<float> t [[texture(0)]]) { return custom_fn(in.color, t); }
