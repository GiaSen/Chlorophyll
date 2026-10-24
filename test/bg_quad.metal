// SPDX-License-Identifier: MIT
// Indexed-quad probe shaders: CoreAnimation's vertex layout (stride 48: float4 position, float2 a1, float2 a2, half4 colour),
// positions in pixels turned into NDC by a constant buffer, the fragment writes back what was interpolated.
#include <metal_stdlib>
using namespace metal;

struct In {
   float4 pos [[attribute(0)]];
   float2 a1  [[attribute(1)]];
   float2 a2  [[attribute(2)]];
   half4  col [[attribute(3)]];
};
struct V { float4 pos [[position]]; float2 a1; float2 a2; half4 col; half4 fcol [[flat]]; };
struct Xf { float2 scale; float2 offset; };

vertex V quad_vs(In in [[stage_in]], constant Xf &xf [[buffer(2)]])
{
   V v;
   v.pos = float4(in.pos.xy * xf.scale + xf.offset, 0, 1);
   v.a1 = in.a1;
   v.a2 = in.a2;
   v.col = in.col;
   v.fcol = in.col;
   return v;
}

// mode 0: the colour attribute; 1: a1 as (r, g); 2: a2 as (r, g); 3: the colour as a [[flat]] varying
struct M { uint mode; };
fragment float4 quad_fs(V in [[stage_in]], constant M &m [[buffer(0)]])
{
   if (m.mode == 1) return float4(in.a1, 0, 1);
   if (m.mode == 2) return float4(in.a2, 0, 1);
   if (m.mode == 3) return float4(in.fcol);   // [[flat]]: Metal takes the first vertex of each triangle
   return float4(in.col);
}
