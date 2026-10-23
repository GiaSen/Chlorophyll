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
