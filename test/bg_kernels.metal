// SPDX-License-Identifier: MIT
// Test kernels for the BGMTLDevice probe (gpu/metal/test/bgmtl_probe.m). Compiled on the Mac to AIR:
//   xcrun -sdk iphoneos metal -mios-version-min=18.0 -c bg_kernels.metal -o bg_kernels.air && xcrun -sdk iphoneos metallib bg_kernels.air -o bg_kernels.metallib
#include <metal_stdlib>
using namespace metal;

// out[i] = a[i] + 2*b[i] for i < n
kernel void bg_add(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]],
                   device float *out [[buffer(2)]], constant uint &n [[buffer(3)]],
                   uint gid [[thread_position_in_grid]])
{
   if (gid < n)
      out[gid] = a[gid] + 2.0f * b[gid];
}

// the blit: dst[i] = src[i] (the "copy" half of a blit encoder, as a kernel the GPU runs)
kernel void bg_copy(device const uint *src [[buffer(0)]], device uint *dst [[buffer(1)]],
                    constant uint &n [[buffer(2)]], uint gid [[thread_position_in_grid]])
{
   if (gid < n)
      dst[gid] = src[gid];
}

// integer-only kernel with a threadgroup reduction pattern kept simple: out[g] = sum of the group's inputs (one thread per group sums)
kernel void bg_groupsum(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],
                        constant uint &per_group [[buffer(2)]], uint tg [[threadgroup_position_in_grid]],
                        uint lid [[thread_position_in_threadgroup]])
{
   if (lid == 0) {
      uint s = 0;
      for (uint i = 0; i < per_group; i++)
         s += in[tg * per_group + i];
      out[tg] = s;
   }
}

// texture read in a kernel: out[y*w+x] = t.read(gid)
kernel void bg_tex_read(texture2d<float, access::read> t [[texture(0)]], device float4 *out [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
   if (gid.x < t.get_width() && gid.y < t.get_height())
      out[gid.y * t.get_width() + gid.x] = t.read(gid);
}

// texture sample through a sampler: nearest, normalised coordinates
kernel void bg_tex_sample(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float4 *out [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
   float2 uv = (float2(gid) + 0.5) / float2(t.get_width(), t.get_height());
   out[gid.y * t.get_width() + gid.x] = t.sample(s, uv);
}

// write a texture from a kernel
kernel void bg_tex_write(texture2d<float, access::write> t [[texture(0)]], uint2 gid [[thread_position_in_grid]])
{
   if (gid.x < t.get_width() && gid.y < t.get_height())
      t.write(float4(float(gid.x) / 16.0, float(gid.y) / 16.0, 0.5, 1.0), gid);
}

// write the mip level `lod`, known only at run time (Mercury's VariableBlurrer::downsample does): every texel of that level
// gets the level's own size as the shader measured it, so a wrong view shows as a wrong size or a texel in the wrong level
kernel void bg_mip_write(texture2d<float, access::write> t [[texture(0)]], constant uint &lod [[buffer(0)]],
                         device uint *sizes [[buffer(1)]], uint2 gid [[thread_position_in_grid]])
{
   uint w = t.get_width(lod), h = t.get_height(lod);
   if (gid.x == 0 && gid.y == 0) { sizes[2 * lod] = w; sizes[2 * lod + 1] = h; }
   if (gid.x < w && gid.y < h)
      t.write(float4(float(w) / 255.0, float(h) / 255.0, float(lod) / 255.0, 1.0), gid, lod);
}

// read one of two textures chosen at run time, through a phi (Mercury's space::rasterizeBackgroundFragment samples goboTexture or
// secondaryGoboTexture that way): which == 0 reads a, else b; the branch has a store of its own so that the choice stays a phi
kernel void bg_tex_choice(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                          constant uint &which [[buffer(0)]], device float4 *out [[buffer(1)]], uint gid [[thread_position_in_grid]])
{
   texture2d<float, access::read> t = b;
   if (which == 0) {
      t = a;
      out[16 + gid] = float4(1.0);
   }
   out[gid] = t.read(uint2(gid, 0));
}

// the nested form (Mercury's other variant): a select between b and c, merged with a by a phi; which picks a, b or c
kernel void bg_tex_choice3(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                           texture2d<float, access::read> c [[texture(2)]], constant uint &which [[buffer(0)]],
                           device float4 *out [[buffer(1)]], uint gid [[thread_position_in_grid]])
{
   texture2d<float, access::read> t = which == 2 ? c : b;
   if (which == 0) {
      t = a;
      out[16 + gid] = float4(1.0);
   }
   out[gid] = t.read(uint2(gid, 0));
}

// the math Mercury's space shaders use, in fast and half forms: out[16 * gid + k] for input in[gid] (checked against libm)
kernel void bg_math(device const float *in [[buffer(0)]], device float *out [[buffer(1)]], uint gid [[thread_position_in_grid]])
{
   float x = in[gid];               // in (-1, 1)
   float y = in[gid] * 0.5 + 0.7;   // in (0.2, 1.2)
   half hx = half(x), hy = half(y);
   device float *o = out + 16 * gid;
   o[0] = fast::acos(x);
   o[1] = fast::asin(x);
   o[2] = fast::atan(x * 3.0);
   o[3] = fast::atan2(x, y);
   o[4] = fast::cos(x * 3.0);
   o[5] = fast::sqrt(y);
   o[6] = fast::rsqrt(y);
   o[7] = fast::saturate(x * 2.0);
   o[8] = float(pow(hy, half(2.2)));
   o[9] = pow(y, 2.2);
   o[10] = float(saturate(hx * half(2.0)));
   o[11] = float(clamp(hx, half(-0.25), half(0.25)));
   o[12] = float(mix(hx, hy, half(0.25)));
   o[13] = fast::pow(y, 0.4545);
   o[14] = float(pow(half3(hy), half3(1.5)).y);
   o[15] = fast::fmax(x, y * 0.5);
}
