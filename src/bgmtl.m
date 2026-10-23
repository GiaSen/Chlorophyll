// SPDX-License-Identifier: MIT
//
// BGMTLDevice: the Bergamota Metal device, spike 2 (test processes only).
//
// Design after hackios's `_MTLDevice` subclass (hackios-xnu-userland userland/src/hkmetal.m, MIT; read and re-written
// here, nothing copied wholesale): a subclass of Metal's private `_MTLDevice`, `MTLDeviceSPI` added to it with
// class_addProtocol, buffers = msm GEM objects of our SweetAdreno630 client, compute pipelines = one function's AIR run through
// the AIR -> NIR frontend and Mesa freedreno (a6xx) via libbgair (gpu/metal/air/air_metal.c), dispatch = a Gallium grid.
//
// THIS FILE NEVER REGISTERS THE DEVICE. It does not call MTLAddDevice, does not touch the device array that
// MTLCreateSystemDefaultDevice / MTLCopyAllDevices read, and does not publish MetalPluginName on any IOKit service. A test
// process makes the object itself with bgmtl_create_device() and uses it directly. A half-working device must never be
// visible to backboardd/CoreAnimation (docs/METAL_ADRENO630.md, nil-or-complete rule).
//
// Scope: command queue, command buffer, compute encoder (setBuffer/setBytes/dispatch), a CPU blit encoder (copy/fill on shared
// buffers), buffers, libraries/functions through Metal's own _MTLLibrary, compute pipelines. No textures, render, heaps, events.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <IOSurface/IOSurfaceRef.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "air_metal.h"

// ---- the private bases (names only; their layouts are Metal's) -----------------------------------------------------
@interface _MTLDevice : NSObject
- (instancetype)init;
@end
@interface _MTLObjectWithLabel : NSObject
- (instancetype)init;
@end
@interface _MTLResource : _MTLObjectWithLabel
@end
@interface _MTLCommandQueue : _MTLObjectWithLabel
- (instancetype)initWithDevice:(id)device descriptor:(id)descriptor;
@end
@interface _MTLCommandBuffer : _MTLObjectWithLabel
- (instancetype)initWithQueue:(id)queue retainedReferences:(BOOL)retained synchronousDebugMode:(BOOL)synchronous;
@end
@interface _MTLCommandEncoder : _MTLObjectWithLabel
- (instancetype)initWithCommandBuffer:(id)commandBuffer;
- (void)endEncoding;
@end
@interface _MTLComputePipelineState : NSObject
- (instancetype)initWithDevice:(id)device pipelineStateDescriptor:(id)descriptor;
@end
@interface _MTLRenderPipelineState : NSObject
- (instancetype)initWithDevice:(id)device pipelineStateDescriptor:(id)descriptor;
@end
@interface _MTLSamplerState : NSObject
- (instancetype)initWithDevice:(id)device samplerDescriptor:(id)descriptor;
@end

#define BG_LOG(...) bg_log(__VA_ARGS__)
static void
bg_log(const char *fmt, ...)
{
   va_list ap;
   va_start(ap, fmt);
   fprintf(stderr, "bgmtl[%d]: ", getpid());
   vfprintf(stderr, fmt, ap);
   va_end(ap);
}

#define BG_MAX_BINDINGS 16

@class BGMTLDevice;
@class BGMTLComputePipeline;

// ---- recorded work ---------------------------------------------------------------------------------------------------
enum { BG_WORK_DISPATCH, BG_WORK_COPY, BG_WORK_FILL, BG_WORK_DRAW };
#define BG_MAX_TEX 16
@interface BGWork : NSObject {
 @public
   int kind;
   BGMTLComputePipeline *pipeline;
   id buffers[BG_MAX_BINDINGS];
   NSUInteger offsets[BG_MAX_BINDINGS];
   unsigned count;
   unsigned groups[3], group_size[3];
   id src, dst;                    // blit
   NSUInteger src_off, dst_off, size;
   uint8_t fill;
   // textures and samplers of a dispatch, and of a draw's fragment stage
   id textures[BG_MAX_TEX];
   id samplers[BG_MAX_TEX];
   unsigned texture_count, sampler_count;
   // a draw
   id render;                      // BGMTLRenderPipeline
   id vbuffers[BG_MAX_BINDINGS];   // vertex stage buffers (streams and arguments share Metal's one table)
   NSUInteger voffsets[BG_MAX_BINDINGS];
   unsigned vcount;
   id color[8];
   unsigned color_count;
   BOOL clear;
   float clear_color[4];
   NSUInteger primitive, vstart, vcount_verts;
   NSUInteger instances, base_instance;
   id index_buffer;
   NSUInteger index_type, index_offset;
   NSInteger base_vertex;
}
@end
@implementation BGWork
- (void)dealloc
{
   [pipeline release];
   for (unsigned i = 0; i < BG_MAX_BINDINGS; i++) [buffers[i] release];
   [src release]; [dst release]; [render release]; [index_buffer release];
   for (unsigned i = 0; i < BG_MAX_TEX; i++) { [textures[i] release]; [samplers[i] release]; }
   for (unsigned i = 0; i < BG_MAX_BINDINGS; i++) [vbuffers[i] release];
   for (unsigned i = 0; i < 8; i++) [color[i] release];
   [super dealloc];
}
@end

// ---- device ----------------------------------------------------------------------------------------------------------
@interface BGMTLDevice : _MTLDevice {
   struct rwa_device *_rwa;
   char _why[512];
   BOOL _assertions;
}
- (struct rwa_device *)rwa;
- (NSString *)bgWhy;
- (id)bgFail:(NSError **)error with:(NSString *)reason;
@end

@interface BGMTLBuffer : _MTLResource {
   BGMTLDevice *_owner;
   struct rwa_buffer *_buf;
   void *_contents;
   NSUInteger _length;
}
- (instancetype)initWithBGDevice:(BGMTLDevice *)device length:(NSUInteger)length;
- (struct rwa_buffer *)rwaBuffer;
- (void *)contents;
@end

@interface BGMTLComputePipeline : _MTLComputePipelineState {
 @public
   BGMTLDevice *_owner;
   struct rwa_compute *_compute;
   struct rwa_compute_info _info;
}
@end

@interface BGMTLCommandQueue : _MTLCommandQueue {
   BGMTLDevice *_owner;
}
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(id)descriptor;
@end

@interface BGMTLCommandBuffer : _MTLCommandBuffer {
   BGMTLCommandQueue *_queue;
   NSMutableArray *_work;
   NSError *_error;
   NSInteger _status;
   NSMutableArray *_completed, *_scheduled, *_presents;   // handlers; drawables to present once the work has completed
}
- (instancetype)initWithBGQueue:(BGMTLCommandQueue *)queue;
- (void)bgRecord:(BGWork *)work;
@end

@interface BGMTLComputeEncoder : _MTLCommandEncoder {
   BGMTLCommandBuffer *_cb;
   BGMTLComputePipeline *_pipeline;
   id _buffers[BG_MAX_BINDINGS];
   NSUInteger _offsets[BG_MAX_BINDINGS];
   NSMutableArray *_scratch;       // setBytes copies, kept alive until commit
   unsigned _highest;
   id _textures[BG_MAX_TEX], _samplers[BG_MAX_TEX];
   unsigned _thigh, _shigh;
}
- (instancetype)initWithBGCommandBuffer:(BGMTLCommandBuffer *)cb;
@end

@interface BGMTLBlitEncoder : _MTLCommandEncoder {
   BGMTLCommandBuffer *_cb;
}
- (instancetype)initWithBGCommandBuffer:(BGMTLCommandBuffer *)cb;
@end

@interface BGMTLTexture : _MTLResource {
   BGMTLDevice *_owner;
   struct rwa_texture *_tex;
   struct rwa_texture_shape _shape;
   CFTypeRef _surface;   // retained IOSurface, when the memory is one
   NSUInteger _plane;
}
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLTextureDescriptor *)d;
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLTextureDescriptor *)d iosurface:(void *)surface plane:(NSUInteger)plane;
- (struct rwa_texture *)rwaTexture;
@end

@interface BGMTLSampler : _MTLSamplerState {
   BGMTLDevice *_owner;
   struct rwa_sampler *_smp;
}
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLSamplerDescriptor *)d;
- (struct rwa_sampler *)rwaSampler;
@end

@interface BGMTLRenderPipeline : _MTLRenderPipelineState {
 @public
   BGMTLDevice *_owner;
   struct rwa_render *_render;
   struct rwa_render_info _info;
}
@end

@interface BGMTLRenderEncoder : _MTLCommandEncoder {
   BGMTLCommandBuffer *_cb;
   BGMTLRenderPipeline *_pipeline;
   id _vbuf[BG_MAX_BINDINGS], _fbuf[BG_MAX_BINDINGS];
   NSUInteger _voff[BG_MAX_BINDINGS], _foff[BG_MAX_BINDINGS];
   unsigned _vhigh, _fhigh;
   id _tex[BG_MAX_TEX], _smp[BG_MAX_TEX];
   unsigned _thigh, _shigh;
   id _color[8];
   unsigned _ncolor;
   BOOL _clear_pending;
   float _clear[4];
   NSMutableArray *_scratch;
}
- (instancetype)initWithBGCommandBuffer:(BGMTLCommandBuffer *)cb descriptor:(MTLRenderPassDescriptor *)d;
@end

static void
ensure_protocol(Class cls, const char *proto)
{
   Protocol *p = objc_getProtocol(proto);
   if (!p) {
      BG_LOG("protocol %s is not in this process\n", proto);
      return;
   }
   if (!class_conformsToProtocol(cls, p) && !class_addProtocol(cls, p))
      BG_LOG("class_addProtocol(%s) refused for %s\n", proto, class_getName(cls));
}

@implementation BGMTLDevice

+ (void)load
{
   // MTLDeviceSPI is the private protocol Metal's registration asserts on; we never register, but a subclass that claims
   // to be a device has to conform, and the whole SPI surface is answered by _MTLDevice's own defaults or by methods below.
   ensure_protocol(self, "MTLDeviceSPI");
   ensure_protocol(self, "MTLDevice");
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
   (void)port;
   self = [super init];
   if (!self) return nil;
   _rwa = rwa_device_open(_why, sizeof(_why));
   BG_LOG("rwa_device_open: %s\n", _rwa ? rwa_device_name(_rwa) : _why);
   return self;
}

- (void)dealloc
{
   if (_rwa) rwa_device_close(_rwa);
   [super dealloc];
}

- (struct rwa_device *)rwa { return _rwa; }
- (NSString *)bgWhy { return [NSString stringWithUTF8String:_why]; }
- (id)bgFail:(NSError **)error with:(NSString *)reason
{
   BG_LOG("refusing: %s\n", [reason UTF8String]);
   if (error) *error = [NSError errorWithDomain:@"BGMTL" code:1 userInfo:@{ NSLocalizedDescriptionKey : reason }];
   return nil;
}

// the registration trio of the hackios measurements (iOS 16.5); here they are what _MTLDevice's own tables read
- (NSUInteger)featureProfile { return 1; }
- (uint64_t)maxBufferLength { return 256ULL << 20; }
- (BOOL)supportsVertexAmplificationCount:(NSUInteger)count { return count <= 1; }

- (NSString *)name { return _rwa ? [NSString stringWithFormat:@"%s (Bergamota)", rwa_device_name(_rwa)] : @"Adreno (Bergamota, no GPU)"; }
- (BOOL)hasUnifiedMemory { return YES; }
- (BOOL)isLowPower { return NO; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }
- (uint64_t)recommendedMaxWorkingSetSize { return 512ULL << 20; }
- (uint64_t)currentAllocatedSize { return 0; }
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(1024, 1024, 64); }
- (NSUInteger)maxThreadgroupMemoryLength { return 16384; }
- (BOOL)metalAssertionsEnabled { return _assertions; }
- (void)setMetalAssertionsEnabled:(BOOL)enabled { _assertions = enabled; }

- (id)newCommandQueueWithDescriptor:(id)descriptor
{
   id use = descriptor ? [[descriptor retain] autorelease] : [[[MTLCommandQueueDescriptor alloc] init] autorelease];
   return [[BGMTLCommandQueue alloc] initWithBGDevice:self descriptor:use];
}

- (id)newBufferWithLength:(NSUInteger)length options:(NSUInteger)options
{
   (void)options;
   return [[BGMTLBuffer alloc] initWithBGDevice:self length:length];
}

- (id)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(NSUInteger)options
{
   BGMTLBuffer *b = [self newBufferWithLength:length options:options];
   if (b && bytes && [b contents]) memcpy([b contents], bytes, length);
   return b;
}

- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d
{
   return [[BGMTLTexture alloc] initWithBGDevice:self descriptor:d];
}

- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(void *)surface plane:(NSUInteger)plane
{
   return [[BGMTLTexture alloc] initWithBGDevice:self descriptor:d iosurface:surface plane:plane];
}

- (id)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d
{
   return [[BGMTLSampler alloc] initWithBGDevice:self descriptor:d];
}

- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor error:(NSError **)error
{
   static SEL bitcode;
   if (!bitcode) bitcode = sel_getUid("bitcodeData");
   if (!_rwa) return [self bgFail:error with:[NSString stringWithFormat:@"no GPU: %s", _why]];
   id vertex = [descriptor vertexFunction], fragment = [descriptor fragmentFunction];
   if (!fragment) return [self bgFail:error with:@"a render pipeline needs a fragment function"];
   /* no vertex function: libbgair supplies a pass-through stage over the whole attachment (a quad, 4 vertices as a strip) --
    * the road the fragment shaders of a library are exercised by, as air_run did */
   NSData *vair = vertex ? ((NSData * (*)(id, SEL))objc_msgSend)(vertex, bitcode) : nil;
   NSData *fair = ((NSData * (*)(id, SEL))objc_msgSend)(fragment, bitcode);
   if (!fair.length || (vertex && !vair.length)) return [self bgFail:error with:@"a function has no bitcode"];
   struct rwa_render_shape shape;
   memset(&shape, 0, sizeof(shape));
   shape.sample_count = (unsigned)[descriptor sampleCount];
   for (unsigned i = 0; i < 8; i++) {
      MTLRenderPipelineColorAttachmentDescriptor *a = [[descriptor colorAttachments] objectAtIndexedSubscript:i];
      shape.color_format[i] = a ? (unsigned)[a pixelFormat] : 0;
      if (shape.color_format[i]) shape.color_count = i + 1;
      if (!a) { shape.color_blend[i].write_mask = 0xf; continue; }
      shape.color_blend[i].blending_enabled = [a isBlendingEnabled];
      shape.color_blend[i].rgb_blend_operation = (unsigned)[a rgbBlendOperation];
      shape.color_blend[i].alpha_blend_operation = (unsigned)[a alphaBlendOperation];
      shape.color_blend[i].source_rgb_blend_factor = (unsigned)[a sourceRGBBlendFactor];
      shape.color_blend[i].destination_rgb_blend_factor = (unsigned)[a destinationRGBBlendFactor];
      shape.color_blend[i].source_alpha_blend_factor = (unsigned)[a sourceAlphaBlendFactor];
      shape.color_blend[i].destination_alpha_blend_factor = (unsigned)[a destinationAlphaBlendFactor];
      shape.color_blend[i].write_mask = (unsigned)[a writeMask];
   }
   shape.color_blend_count = 8;
   shape.depth_format = (unsigned)[descriptor depthAttachmentPixelFormat];
   shape.stencil_format = (unsigned)[descriptor stencilAttachmentPixelFormat];
   MTLVertexDescriptor *vd = [descriptor vertexDescriptor];
   if (vd) {
      for (unsigned i = 0; i < RWA_MAX_VERTEX_ATTRIBUTES; i++) {
         MTLVertexAttributeDescriptor *a = [[vd attributes] objectAtIndexedSubscript:i];
         if (!a || ![a format]) continue;
         shape.vertex_attribute[i].format = (unsigned)[a format];
         shape.vertex_attribute[i].offset = (unsigned)[a offset];
         shape.vertex_attribute[i].buffer_index = (unsigned)[a bufferIndex];
      }
      for (unsigned k = 0; k < RWA_MAX_VERTEX_BUFFERS; k++) {
         MTLVertexBufferLayoutDescriptor *l = [[vd layouts] objectAtIndexedSubscript:k];
         if (!l) continue;
         shape.vertex_layout[k].stride = (unsigned)[l stride];
         shape.vertex_layout[k].step_function = (unsigned)[l stepFunction];
         shape.vertex_layout[k].step_rate = (unsigned)[l stepRate];
      }
   }
   char why[512] = { 0 };
   struct rwa_render_info info;
   memset(&info, 0, sizeof(info));
   struct rwa_render *r = rwa_render_create(_rwa, vair ? vair.bytes : NULL, vair ? vair.length : 0, vertex ? [[vertex name] UTF8String] : NULL, fair.bytes, fair.length,
                                            [[fragment name] UTF8String], &shape, &info, why, sizeof(why));
   if (!r) return [self bgFail:error with:[NSString stringWithUTF8String:why]];
   BGMTLRenderPipeline *p = [[BGMTLRenderPipeline alloc] initWithDevice:self pipelineStateDescriptor:descriptor];
   if (!p) { rwa_render_destroy(r); return [self bgFail:error with:@"_MTLRenderPipelineState refused to initialise"]; }
   p->_owner = self; p->_render = r; p->_info = info;
   BG_LOG("render pipeline %s + %s: vertex_buffers=%u fragment_buffers=%u fragment_textures=%u samplers=%u streams=%u\n",
          vertex ? [[vertex name] UTF8String] : "(generated)", [[fragment name] UTF8String], info.vertex_buffers, info.fragment_buffers,
          info.fragment_textures, info.fragment_samplers, info.vertex_streams);
   return p;
}

// -- compute pipelines: both of _MTLDevice's entry points go through its (nil) -compiler, so they are ours --
- (id)bgPipelineForFunction:(id)function descriptor:(id)descriptor error:(NSError **)error
{
   static SEL bitcode;
   if (!bitcode) bitcode = sel_getUid("bitcodeData");
   if (!function) return [self bgFail:error with:@"no compute function"];
   if (!_rwa) return [self bgFail:error with:[NSString stringWithFormat:@"no GPU: %s", _why]];
   if (![function respondsToSelector:bitcode]) return [self bgFail:error with:@"function has no bitcodeData selector"];
   NSData *air = ((NSData * (*)(id, SEL))objc_msgSend)(function, bitcode);
   if (!air.length) return [self bgFail:error with:@"function has no bitcode"];
   char why[512] = { 0 };
   struct rwa_compute_info info = { 0 };
   struct rwa_compute *c = rwa_compute_create(_rwa, air.bytes, air.length, [[function name] UTF8String], &info, why, sizeof(why));
   if (!c) return [self bgFail:error with:[NSString stringWithUTF8String:why]];
   BGMTLComputePipeline *p = [[BGMTLComputePipeline alloc] initWithDevice:self pipelineStateDescriptor:descriptor];
   if (!p) { rwa_compute_destroy(c); return [self bgFail:error with:@"_MTLComputePipelineState refused to initialise"]; }
   p->_owner = self;
   p->_compute = c;
   p->_info = info;
   BG_LOG("pipeline %s: max_threads=%u exec_width=%u buffers=%u textures=%u\n", [[function name] UTF8String],
          info.max_threads_per_group, info.thread_execution_width, info.buffers, info.textures);
   return p;
}

- (id)newComputePipelineStateWithDescriptor:(id)descriptor options:(NSUInteger)options reflection:(id *)reflection error:(NSError **)error
{
   (void)options;
   if (reflection) *reflection = nil;
   return [self bgPipelineForFunction:[descriptor computeFunction] descriptor:descriptor error:error];
}

- (id)newComputePipelineStateWithDescriptor:(id)descriptor error:(NSError **)error
{
   return [self bgPipelineForFunction:[descriptor computeFunction] descriptor:descriptor error:error];
}

- (id)newComputePipelineStateWithFunction:(id)function error:(NSError **)error
{
   MTLComputePipelineDescriptor *d = [[MTLComputePipelineDescriptor alloc] init];
   [d setComputeFunction:function];
   id s = [self bgPipelineForFunction:function descriptor:d error:error];
   [d release];
   return s;
}

@end

// ---- buffer ----------------------------------------------------------------------------------------------------------
@implementation BGMTLBuffer
+ (void)load { ensure_protocol(self, "MTLBuffer"); }

- (instancetype)initWithBGDevice:(BGMTLDevice *)device length:(NSUInteger)length
{
   self = [super init];
   if (!self) return nil;
   char why[256] = { 0 };
   if (![device rwa] || !length) { BG_LOG("buffer of %lu bytes: no GPU device\n", (unsigned long)length); [self release]; return nil; }
   _buf = rwa_buffer_create([device rwa], length, why, sizeof(why));
   if (!_buf) { BG_LOG("rwa_buffer_create(%lu): %s\n", (unsigned long)length, why); [self release]; return nil; }
   _owner = device;
   _length = length;
   _contents = rwa_buffer_map(_buf);
   return self;
}
- (void)dealloc { if (_buf) rwa_buffer_destroy(_buf); [super dealloc]; }
- (struct rwa_buffer *)rwaBuffer { return _buf; }
- (void *)contents { return _contents; }
- (NSUInteger)length { return _length; }
- (id)device { return _owner; }
- (NSUInteger)allocatedSize { return _length; }
- (void)didModifyRange:(NSRange)range { (void)range; }
- (NSUInteger)storageMode { return 0; }
- (NSUInteger)cpuCacheMode { return 1; }
- (NSUInteger)resourceOptions { return 0; }
- (NSUInteger)hazardTrackingMode { return 0; }
- (NSUInteger)setPurgeableState:(NSUInteger)state { (void)state; return 2; }
- (id)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable {}
- (BOOL)doesAliasResource:(id)r { (void)r; return NO; }
- (BOOL)isComplete { return YES; }
- (void)waitUntilComplete {}
- (BOOL)isPurgeable { return NO; }
- (NSUInteger)protectionOptions { return 0; }
@end

// ---- pipeline --------------------------------------------------------------------------------------------------------
@implementation BGMTLComputePipeline
+ (void)load { ensure_protocol(self, "MTLComputePipelineState"); }
- (void)dealloc { if (_compute) rwa_compute_destroy(_compute); [super dealloc]; }
- (id)device { return _owner; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _info.max_threads_per_group; }
- (NSUInteger)threadExecutionWidth { return _info.thread_execution_width; }
- (NSUInteger)staticThreadgroupMemoryLength { return _info.static_shared_bytes; }
@end

// ---- command queue / buffer / encoders -------------------------------------------------------------------------------
@implementation BGMTLCommandQueue
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(id)descriptor
{
   self = [super initWithDevice:device descriptor:descriptor];
   if (!self) return nil;
   _owner = device;
   return self;
}
- (id)device { return _owner; }
- (id)commandBuffer { return [[[BGMTLCommandBuffer alloc] initWithBGQueue:self] autorelease]; }
- (id)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (void)insertDebugCaptureBoundary {}
@end

@implementation BGMTLCommandBuffer
- (instancetype)initWithBGQueue:(BGMTLCommandQueue *)queue
{
   self = [super initWithQueue:queue retainedReferences:YES synchronousDebugMode:NO];
   if (!self) return nil;
   _queue = [queue retain];
   _work = [[NSMutableArray alloc] init];
   _completed = [[NSMutableArray alloc] init];
   _scheduled = [[NSMutableArray alloc] init];
   _presents = [[NSMutableArray alloc] init];
   _status = 1;   // MTLCommandBufferStatusEnqueued
   return self;
}
- (void)dealloc
{
   [_queue release]; [_work release]; [_error release]; [_completed release]; [_scheduled release]; [_presents release];
   [super dealloc];
}
- (id)device { return [_queue device]; }
- (void)bgRecord:(BGWork *)w { [_work addObject:w]; }
- (NSInteger)status { return _status; }
- (NSError *)error { return _error; }
- (void)enqueue {}
- (void)addScheduledHandler:(void (^)(id))block
{
   if (!block) return;
   if (_status >= 3) block(self); else [_scheduled addObject:[[block copy] autorelease]];   // delivered when the work has been submitted, not before
}
- (void)presentDrawable:(id)drawable { if (drawable) [_presents addObject:@[ drawable, @0.0, @0.0 ]]; }
- (void)presentDrawable:(id)drawable atTime:(CFTimeInterval)t { if (drawable) [_presents addObject:@[ drawable, @(t), @0.0 ]]; }
- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)d { if (drawable) [_presents addObject:@[ drawable, @0.0, @(d) ]]; }
- (void)addCompletedHandler:(void (^)(id))block
{
   if (!block) return;
   if (_status >= 4) block(self); else [_completed addObject:[[block copy] autorelease]];
}
- (void)waitUntilScheduled {}

- (void)bgFailWith:(NSString *)why code:(NSInteger)code
{
   BG_LOG("command buffer failed: %s\n", [why UTF8String]);
   _error = [[NSError errorWithDomain:@"BGMTL" code:code userInfo:@{ NSLocalizedDescriptionKey : why }] retain];
   _status = 5;   // MTLCommandBufferStatusError
}

- (void)commit
{
   BGMTLDevice *dev = (BGMTLDevice *)[_queue device];
   _status = 2;   // Committed
   char why[512] = { 0 };
   for (BGWork *w in _work) {
      if (w->kind == BG_WORK_DISPATCH) {
         struct rwa_buffer *bufs[BG_MAX_BINDINGS] = { NULL };
         struct rwa_buffer_bind table[BG_MAX_BINDINGS] = { { NULL, 0 } };
         for (unsigned i = 0; i < w->count; i++) {
            bufs[i] = [(BGMTLBuffer *)w->buffers[i] rwaBuffer];
            table[i].buffer = bufs[i];
            table[i].offset = w->offsets[i];
         }
         struct rwa_texture *texs[BG_MAX_TEX] = { NULL };
         struct rwa_sampler *smps[BG_MAX_TEX] = { NULL };
         for (unsigned i = 0; i < w->texture_count; i++) texs[i] = [(BGMTLTexture *)w->textures[i] rwaTexture];
         for (unsigned i = 0; i < w->sampler_count; i++) smps[i] = [(BGMTLSampler *)w->samplers[i] rwaSampler];
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = w->count, .textures = texs, .texture_count = w->texture_count,
                                   .samplers = smps, .sampler_count = w->sampler_count };
         if (rwa_dispatch_buffers(w->pipeline->_compute, &b, table, w->count, w->groups, w->group_size, why, sizeof(why)) != 0) {
            [self bgFailWith:[NSString stringWithUTF8String:why] code:2];
            break;
         }
      } else if (w->kind == BG_WORK_DRAW) {
         BGMTLRenderPipeline *rp = (BGMTLRenderPipeline *)w->render;
         struct rwa_buffer *vb[BG_MAX_BINDINGS] = { NULL }, *fb[BG_MAX_BINDINGS] = { NULL };
         struct rwa_buffer_bind vt[BG_MAX_BINDINGS] = { { NULL, 0 } }, ft[BG_MAX_BINDINGS] = { { NULL, 0 } };
         struct rwa_vertex_stream streams[BG_MAX_BINDINGS] = { { NULL, 0 } };
         for (unsigned i = 0; i < w->vcount; i++) {
            vb[i] = [(BGMTLBuffer *)w->vbuffers[i] rwaBuffer];
            vt[i].buffer = vb[i]; vt[i].offset = w->voffsets[i];
            streams[i].buffer = vb[i]; streams[i].offset = w->voffsets[i];
         }
         for (unsigned i = 0; i < w->count; i++) {
            fb[i] = [(BGMTLBuffer *)w->buffers[i] rwaBuffer];
            ft[i].buffer = fb[i]; ft[i].offset = w->offsets[i];
         }
         struct rwa_texture *texs[BG_MAX_TEX] = { NULL }, *colors[8] = { NULL };
         struct rwa_sampler *smps[BG_MAX_TEX] = { NULL };
         for (unsigned i = 0; i < w->texture_count; i++) texs[i] = [(BGMTLTexture *)w->textures[i] rwaTexture];
         for (unsigned i = 0; i < w->sampler_count; i++) smps[i] = [(BGMTLSampler *)w->samplers[i] rwaSampler];
         for (unsigned i = 0; i < w->color_count; i++) colors[i] = [(BGMTLTexture *)w->color[i] rwaTexture];
         struct rwa_draw dr;
         memset(&dr, 0, sizeof(dr));
         dr.color = colors; dr.color_count = w->color_count;
         dr.clear_color = w->clear ? w->clear_color : NULL;
         dr.vertex = (struct rwa_bindings){ .buffers = vb, .buffer_count = w->vcount };
         dr.fragment = (struct rwa_bindings){ .buffers = fb, .buffer_count = w->count, .textures = texs, .texture_count = w->texture_count,
                                              .samplers = smps, .sampler_count = w->sampler_count };
         dr.primitive = (unsigned)w->primitive; dr.vertex_start = (unsigned)w->vstart; dr.vertex_count = (unsigned)w->vcount_verts;
         dr.index_buffer = w->index_buffer ? [(BGMTLBuffer *)w->index_buffer rwaBuffer] : NULL;
         dr.index_type = (unsigned)w->index_type; dr.index_buffer_offset = w->index_offset;
         dr.base_vertex = (int)w->base_vertex; dr.instance_count = (unsigned)w->instances; dr.base_instance = (unsigned)w->base_instance;
         dr.vertex_streams = streams; dr.vertex_stream_count = rp->_info.vertex_streams;
         dr.vertex_buffer_table = vt; dr.vertex_buffer_table_count = w->vcount;
         dr.fragment_buffer_table = ft; dr.fragment_buffer_table_count = w->count;
         if (rwa_render_draw(rp->_render, &dr, why, sizeof(why)) != 0) {
            [self bgFailWith:[NSString stringWithUTF8String:why] code:4];
            break;
         }
      } else {
         // CPU blit on shared memory: everything dispatched so far must be done first
         if (rwa_finish([dev rwa], why, sizeof(why)) != 0) { [self bgFailWith:[NSString stringWithUTF8String:why] code:3]; break; }
         if (w->kind == BG_WORK_COPY)
            memmove((uint8_t *)[(BGMTLBuffer *)w->dst contents] + w->dst_off, (uint8_t *)[(BGMTLBuffer *)w->src contents] + w->src_off, w->size);
         else
            memset((uint8_t *)[(BGMTLBuffer *)w->dst contents] + w->dst_off, w->fill, w->size);
      }
   }
   if (_status != 5) {
      _status = 3;   // Scheduled
   }
   if (_status != 5 && rwa_finish([dev rwa], why, sizeof(why)) != 0)
      [self bgFailWith:[NSString stringWithUTF8String:why] code:3];
   else if (_status != 5)
      _status = 4;   // Completed: the fence has been paid
   // what the GPU wrote into an IOSurface becomes visible to the compositor before the drawable is presented
   if (_status == 4)
      for (BGWork *w in _work)
         if (w->kind == BG_WORK_DRAW)
            for (unsigned i = 0; i < w->color_count; i++)
               rwa_texture_flush_surface([(BGMTLTexture *)w->color[i] rwaTexture]);
   for (void (^h)(id) in _scheduled) h(self);
   [_scheduled removeAllObjects];
   if (_status == 4) {
      for (NSArray *p in _presents) {
         id dr = p[0];
         double at = [p[1] doubleValue], after = [p[2] doubleValue];
         if (at > 0 && [dr respondsToSelector:@selector(presentAtTime:)]) [dr presentAtTime:at];
         else if (after > 0 && [dr respondsToSelector:@selector(presentAfterMinimumDuration:)]) [dr presentAfterMinimumDuration:after];
         else [dr present];
      }
   }
   [_presents removeAllObjects];
   for (void (^h)(id) in _completed) h(self);
   [_completed removeAllObjects];
}

- (void)waitUntilCompleted {}   // commit is synchronous in this spike: it returns after the fence

- (id)computeCommandEncoder { return [[[BGMTLComputeEncoder alloc] initWithBGCommandBuffer:self] autorelease]; }
- (id)computeCommandEncoderWithDescriptor:(id)d { (void)d; return [self computeCommandEncoder]; }
- (id)computeCommandEncoderWithDispatchType:(NSUInteger)t { (void)t; return [self computeCommandEncoder]; }
- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d
{ return [[[BGMTLRenderEncoder alloc] initWithBGCommandBuffer:self descriptor:d] autorelease]; }
- (id)blitCommandEncoder { return [[[BGMTLBlitEncoder alloc] initWithBGCommandBuffer:self] autorelease]; }
- (id)blitCommandEncoderWithDescriptor:(id)d { (void)d; return [self blitCommandEncoder]; }
@end

@implementation BGMTLComputeEncoder
- (instancetype)initWithBGCommandBuffer:(BGMTLCommandBuffer *)cb
{
   self = [super initWithCommandBuffer:cb];
   if (!self) return nil;
   _cb = cb;
   _scratch = [[NSMutableArray alloc] init];
   return self;
}
- (void)dealloc { [_scratch release]; [super dealloc]; }
- (id)device { return [_cb device]; }
- (void)setComputePipelineState:(id)state { _pipeline = state; }
- (void)setBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
   if (index >= BG_MAX_BINDINGS) { BG_LOG("buffer index %lu out of range\n", (unsigned long)index); return; }
   _buffers[index] = buffer;
   _offsets[index] = offset;
   if (index + 1 > _highest) _highest = (unsigned)index + 1;
}
- (void)setTexture:(id)t atIndex:(NSUInteger)i { if (i < BG_MAX_TEX) { _textures[i] = t; if (i + 1 > _thigh) _thigh = (unsigned)i + 1; } }
- (void)setSamplerState:(id)s atIndex:(NSUInteger)i { if (i < BG_MAX_TEX) { _samplers[i] = s; if (i + 1 > _shigh) _shigh = (unsigned)i + 1; } }
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
   id b = [[(BGMTLDevice *)[self device] newBufferWithBytes:bytes length:length < 16 ? 16 : length options:0] autorelease];
   if (!b) { BG_LOG("setBytes: no buffer\n"); return; }
   [_scratch addObject:b];
   [self setBuffer:b offset:0 atIndex:index];
}
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)size
{
   if (!_pipeline) { BG_LOG("dispatch with no pipeline\n"); return; }
   BGWork *w = [[[BGWork alloc] init] autorelease];
   w->kind = BG_WORK_DISPATCH;
   w->pipeline = [_pipeline retain];
   w->count = _highest;
   for (unsigned i = 0; i < _highest; i++) { w->buffers[i] = [_buffers[i] retain]; w->offsets[i] = _offsets[i]; }
   for (unsigned i = 0; i < BG_MAX_TEX; i++) { w->textures[i] = [_textures[i] retain]; w->samplers[i] = [_samplers[i] retain]; }
   w->texture_count = _thigh; w->sampler_count = _shigh;
   w->groups[0] = (unsigned)groups.width; w->groups[1] = (unsigned)groups.height; w->groups[2] = (unsigned)groups.depth;
   w->group_size[0] = (unsigned)size.width; w->group_size[1] = (unsigned)size.height; w->group_size[2] = (unsigned)size.depth;
   [_cb bgRecord:w];
}
- (void)dispatchThreads:(MTLSize)threads threadsPerThreadgroup:(MTLSize)size
{
   MTLSize g = MTLSizeMake((threads.width + size.width - 1) / size.width, (threads.height + size.height - 1) / size.height,
                           (threads.depth + size.depth - 1) / size.depth);
   [self dispatchThreadgroups:g threadsPerThreadgroup:size];   // non-uniform tail threads run too; kernels guard with gid < n
}
- (void)endEncoding { [super endEncoding]; }
@end

@implementation BGMTLBlitEncoder
- (instancetype)initWithBGCommandBuffer:(BGMTLCommandBuffer *)cb
{
   self = [super initWithCommandBuffer:cb];
   if (!self) return nil;
   _cb = cb;
   return self;
}
- (id)device { return [_cb device]; }
- (void)copyFromBuffer:(id)src sourceOffset:(NSUInteger)so toBuffer:(id)dst destinationOffset:(NSUInteger)doff size:(NSUInteger)size
{
   BGWork *w = [[[BGWork alloc] init] autorelease];
   w->kind = BG_WORK_COPY; w->src = [src retain]; w->dst = [dst retain]; w->src_off = so; w->dst_off = doff; w->size = size;
   [_cb bgRecord:w];
}
- (void)fillBuffer:(id)buffer range:(NSRange)range value:(uint8_t)value
{
   BGWork *w = [[[BGWork alloc] init] autorelease];
   w->kind = BG_WORK_FILL; w->dst = [buffer retain]; w->dst_off = range.location; w->size = range.length; w->fill = value;
   [_cb bgRecord:w];
}
- (void)endEncoding { [super endEncoding]; }
@end


// ---- texture / sampler / render pipeline ----------------------------------------------------------------------------
@implementation BGMTLTexture
+ (void)load { ensure_protocol(self, "MTLTexture"); ensure_protocol(self, "MTLTextureImplementation"); }
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLTextureDescriptor *)d
{
   return [self initWithBGDevice:device descriptor:d iosurface:NULL plane:0];
}
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLTextureDescriptor *)d iosurface:(void *)surface plane:(NSUInteger)plane
{
   self = [super init];
   if (!self) return nil;
   if (![device rwa] || !d) { [self release]; return nil; }
   _shape.pixel_format = (unsigned)[d pixelFormat];
   _shape.type = (unsigned)[d textureType];
   _shape.width = (unsigned)[d width];
   _shape.height = (unsigned)[d height];
   _shape.depth = (unsigned)[d depth];
   _shape.array_length = (unsigned)[d arrayLength];
   _shape.mip_levels = (unsigned)[d mipmapLevelCount];
   _shape.sample_count = (unsigned)[d sampleCount];
   _shape.usage = (unsigned)[d usage];
   char why[512] = { 0 };
   if (surface) {
      _shape.usage |= 5;   /* a drawable is rendered into and may be sampled whatever CA asked for (MTLTextureUsageRenderTarget | ShaderRead) */
      /* a CAMetalLayer drawable: CoreAnimation made the IOSurface and sends the device this one message; the texture IS that memory */
      _tex = rwa_texture_from_surface([device rwa], &_shape, (int)IOSurfaceGetID((IOSurfaceRef)surface), 0, 0, why, sizeof(why));
      _surface = CFRetain(surface);
      _plane = plane;
   } else {
      _tex = rwa_texture_create([device rwa], &_shape, why, sizeof(why));
   }
   if (!_tex) { BG_LOG("texture refused: %s\n", why); [self release]; return nil; }
   _owner = device;
   return self;
}
- (void)dealloc { if (_tex) rwa_texture_destroy(_tex); if (_surface) CFRelease(_surface); [super dealloc]; }
- (void *)iosurface { return (void *)_surface; }
- (NSUInteger)iosurfacePlane { return _plane; }
- (BOOL)isDrawable { return _surface != NULL; }
- (struct rwa_texture *)rwaTexture { return _tex; }
- (id)device { return _owner; }
- (NSUInteger)width { return _shape.width; }
- (NSUInteger)height { return _shape.height; }
- (NSUInteger)depth { return _shape.depth; }
- (NSUInteger)mipmapLevelCount { return _shape.mip_levels; }
- (NSUInteger)arrayLength { return _shape.array_length; }
- (NSUInteger)sampleCount { return _shape.sample_count; }
- (NSUInteger)pixelFormat { return _shape.pixel_format; }
- (NSUInteger)textureType { return _shape.type; }
- (NSUInteger)usage { return _shape.usage; }
- (BOOL)isFramebufferOnly { return NO; }
- (id)parentTexture { return nil; }
- (id)buffer { return nil; }
- (NSUInteger)storageMode { return 0; }
- (NSUInteger)cpuCacheMode { return 0; }
- (NSUInteger)resourceOptions { return 0; }
- (NSUInteger)hazardTrackingMode { return 0; }
- (NSUInteger)allocatedSize { return 0; }
- (NSUInteger)setPurgeableState:(NSUInteger)state { (void)state; return 2; }
- (id)heap { return nil; }
- (BOOL)isAliasable { return NO; }
- (BOOL)isComplete { return YES; }
- (void)waitUntilComplete {}
- (NSUInteger)protectionOptions { return 0; }
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)bytes
          bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi
{
   (void)bpi;
   unsigned o[3] = { (unsigned)r.origin.x, (unsigned)r.origin.y, (unsigned)r.origin.z };
   unsigned sz[3] = { (unsigned)r.size.width, (unsigned)r.size.height, (unsigned)r.size.depth };
   char why[256] = { 0 };
   if (rwa_texture_write(_tex, (unsigned)level, (unsigned)slice, o, sz, bytes, bpr, why, sizeof(why)) != 0) BG_LOG("replaceRegion: %s\n", why);
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)bpr
{
   [self replaceRegion:r mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:bpr bytesPerImage:0];
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi fromRegion:(MTLRegion)r
     mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
{
   (void)bpi;
   unsigned o[3] = { (unsigned)r.origin.x, (unsigned)r.origin.y, (unsigned)r.origin.z };
   unsigned sz[3] = { (unsigned)r.size.width, (unsigned)r.size.height, (unsigned)r.size.depth };
   char why[256] = { 0 };
   if (rwa_texture_read(_tex, (unsigned)level, (unsigned)slice, o, sz, bytes, bpr, why, sizeof(why)) != 0) BG_LOG("getBytes: %s\n", why);
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level
{
   [self getBytes:bytes bytesPerRow:bpr bytesPerImage:0 fromRegion:r mipmapLevel:level slice:0];
}
@end

@implementation BGMTLSampler
+ (void)load { ensure_protocol(self, "MTLSamplerState"); }
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLSamplerDescriptor *)d
{
   self = [super initWithDevice:device samplerDescriptor:d];
   if (!self) return nil;
   struct rwa_sampler_state st;
   memset(&st, 0, sizeof(st));
   st.address[0] = (unsigned)[d sAddressMode]; st.address[1] = (unsigned)[d tAddressMode]; st.address[2] = (unsigned)[d rAddressMode];
   st.min_filter = (unsigned)[d minFilter]; st.mag_filter = (unsigned)[d magFilter]; st.mip_filter = (unsigned)[d mipFilter];
   st.compare_function = (unsigned)[d compareFunction];
   st.max_anisotropy = (unsigned)[d maxAnisotropy];
   st.normalized_coordinates = [d normalizedCoordinates];
   st.lod_min = [d lodMinClamp]; st.lod_max = [d lodMaxClamp];
   char why[256] = { 0 };
   _smp = rwa_sampler_create([device rwa], &st, why, sizeof(why));
   if (!_smp) { BG_LOG("sampler refused: %s\n", why); [self release]; return nil; }
   _owner = device;
   return self;
}
- (void)dealloc { if (_smp) rwa_sampler_destroy(_smp); [super dealloc]; }
- (struct rwa_sampler *)rwaSampler { return _smp; }
- (id)device { return _owner; }
@end

@implementation BGMTLRenderPipeline
+ (void)load { ensure_protocol(self, "MTLRenderPipelineState"); }
- (void)dealloc { if (_render) rwa_render_destroy(_render); [super dealloc]; }
- (id)device { return _owner; }
@end

@implementation BGMTLRenderEncoder
- (instancetype)initWithBGCommandBuffer:(BGMTLCommandBuffer *)cb descriptor:(MTLRenderPassDescriptor *)d
{
   self = [super initWithCommandBuffer:cb];
   if (!self) return nil;
   _cb = cb;
   _scratch = [[NSMutableArray alloc] init];
   for (unsigned i = 0; i < 8; i++) {
      MTLRenderPassColorAttachmentDescriptor *a = [[d colorAttachments] objectAtIndexedSubscript:i];
      if (!a || ![a texture]) continue;
      _color[i] = [[a texture] retain];
      _ncolor = i + 1;
      if (i == 0 && [a loadAction] == MTLLoadActionClear) {
         MTLClearColor c = [a clearColor];
         _clear[0] = (float)c.red; _clear[1] = (float)c.green; _clear[2] = (float)c.blue; _clear[3] = (float)c.alpha;
         _clear_pending = YES;
      }
   }
   return self;
}
- (void)dealloc { for (unsigned i = 0; i < 8; i++) [_color[i] release]; [_scratch release]; [super dealloc]; }
- (id)device { return [_cb device]; }
- (void)setRenderPipelineState:(id)s { _pipeline = s; }
- (void)setVertexBuffer:(id)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{ if (i < BG_MAX_BINDINGS) { _vbuf[i] = b; _voff[i] = o; if (i + 1 > _vhigh) _vhigh = (unsigned)i + 1; } }
- (void)setFragmentBuffer:(id)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{ if (i < BG_MAX_BINDINGS) { _fbuf[i] = b; _foff[i] = o; if (i + 1 > _fhigh) _fhigh = (unsigned)i + 1; } }
- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)l atIndex:(NSUInteger)i
{
   id b = [[(BGMTLDevice *)[self device] newBufferWithBytes:bytes length:l < 16 ? 16 : l options:0] autorelease];
   if (b) { [_scratch addObject:b]; [self setVertexBuffer:b offset:0 atIndex:i]; }
}
- (void)setFragmentBytes:(const void *)bytes length:(NSUInteger)l atIndex:(NSUInteger)i
{
   id b = [[(BGMTLDevice *)[self device] newBufferWithBytes:bytes length:l < 16 ? 16 : l options:0] autorelease];
   if (b) { [_scratch addObject:b]; [self setFragmentBuffer:b offset:0 atIndex:i]; }
}
- (void)setFragmentTexture:(id)t atIndex:(NSUInteger)i { if (i < BG_MAX_TEX) { _tex[i] = t; if (i + 1 > _thigh) _thigh = (unsigned)i + 1; } }
- (void)setFragmentSamplerState:(id)s atIndex:(NSUInteger)i { if (i < BG_MAX_TEX) { _smp[i] = s; if (i + 1 > _shigh) _shigh = (unsigned)i + 1; } }
- (void)setViewport:(MTLViewport)v { (void)v; }
- (void)setScissorRect:(MTLScissorRect)r { (void)r; }
- (void)setCullMode:(NSUInteger)m { (void)m; }
- (void)setFrontFacingWinding:(NSUInteger)w { (void)w; }
- (void)setTriangleFillMode:(NSUInteger)m { (void)m; }

- (void)bgRecordDraw:(NSUInteger)prim start:(NSUInteger)start count:(NSUInteger)count instances:(NSUInteger)inst
        indexBuffer:(id)ib indexType:(NSUInteger)it indexOffset:(NSUInteger)io baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi
{
   if (!_pipeline) { BG_LOG("draw with no pipeline\n"); return; }
   BGWork *w = [[[BGWork alloc] init] autorelease];
   w->kind = BG_WORK_DRAW;
   w->render = [_pipeline retain];
   w->vcount = _vhigh > _fhigh ? _vhigh : _fhigh;
   w->count = _fhigh;
   for (unsigned i = 0; i < BG_MAX_BINDINGS; i++) {
      w->vbuffers[i] = [_vbuf[i] retain]; w->voffsets[i] = _voff[i];
      w->buffers[i] = [_fbuf[i] retain]; w->offsets[i] = _foff[i];
   }
   w->vcount = _vhigh;
   for (unsigned i = 0; i < BG_MAX_TEX; i++) { w->textures[i] = [_tex[i] retain]; w->samplers[i] = [_smp[i] retain]; }
   w->texture_count = _thigh; w->sampler_count = _shigh;
   w->color_count = _ncolor;
   for (unsigned i = 0; i < _ncolor; i++) w->color[i] = [_color[i] retain];
   if (_clear_pending) { w->clear = YES; memcpy(w->clear_color, _clear, sizeof(_clear)); _clear_pending = NO; }
   w->primitive = prim; w->vstart = start; w->vcount_verts = count; w->instances = inst; w->base_instance = bi;
   w->index_buffer = [ib retain]; w->index_type = it; w->index_offset = io; w->base_vertex = bv;
   [_cb bgRecord:w];
}
- (void)drawPrimitives:(NSUInteger)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c
{ [self bgRecordDraw:p start:s count:c instances:1 indexBuffer:nil indexType:0 indexOffset:0 baseVertex:0 baseInstance:0]; }
- (void)drawPrimitives:(NSUInteger)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c instanceCount:(NSUInteger)n
{ [self bgRecordDraw:p start:s count:c instances:n indexBuffer:nil indexType:0 indexOffset:0 baseVertex:0 baseInstance:0]; }
- (void)drawIndexedPrimitives:(NSUInteger)p indexCount:(NSUInteger)c indexType:(NSUInteger)t indexBuffer:(id)b indexBufferOffset:(NSUInteger)o
{ [self bgRecordDraw:p start:0 count:c instances:1 indexBuffer:b indexType:t indexOffset:o baseVertex:0 baseInstance:0]; }
- (void)drawIndexedPrimitives:(NSUInteger)p indexCount:(NSUInteger)c indexType:(NSUInteger)t indexBuffer:(id)b indexBufferOffset:(NSUInteger)o
                instanceCount:(NSUInteger)n
{ [self bgRecordDraw:p start:0 count:c instances:n indexBuffer:b indexType:t indexOffset:o baseVertex:0 baseInstance:0]; }
- (void)endEncoding { [super endEncoding]; }
@end

// ---- GPU state, as the kernel reports it (SWEET_GPU_SEL_INFO). ABI minor 1 and 2 are both served: only flags & 3 is read (bit0 ready,
// bit1 lost); abi_minor is informational and every field beyond the first 40 bytes is ignored. -1: no answer, 0: not ready, 1: ready, 2: LOST.
struct bg_gpu_info { uint32_t abi_version, flags, gpu_id, chip_id; uint64_t va_start, va_size; uint32_t last_fence, abi_minor; };
extern int sweet_drm_info(int fd, struct bg_gpu_info *out);

int
bgmtl_gpu_state(unsigned *abi_minor)
{
   struct bg_gpu_info in;
   memset(&in, 0, sizeof(in));
   if (sweet_drm_info(-1, &in) != 0)
      return -1;
   if (abi_minor) *abi_minor = in.abi_minor;
   uint32_t f = in.flags & 3;
   return (f & 2) ? 2 : (f & 1) ? 1 : 0;
}

// ---- entry point for test processes ----------------------------------------------------------------------------------
id
bgmtl_create_device(void)
{
   unsigned minor = 0;
   int st = getenv("RWA_SOFTWARE") ? 1 : bgmtl_gpu_state(&minor);
   if (st == 2) { BG_LOG("the kernel reports the GPU LOST: no device is made\n"); return nil; }
   if (st == 1 && !getenv("RWA_SOFTWARE")) BG_LOG("GPU ready (kernel ABI minor %u)\n", minor);
   return [[BGMTLDevice alloc] initWithAcceleratorPort:0];
}

// for tests: what the library made of a render pipeline
void
bgmtl_render_info(id pipeline, unsigned *vertex_buffers, unsigned *fragment_buffers, unsigned *fragment_textures, unsigned *fragment_samplers)
{
   BGMTLRenderPipeline *p = (BGMTLRenderPipeline *)pipeline;
   *vertex_buffers = p->_info.vertex_buffers; *fragment_buffers = p->_info.fragment_buffers;
   *fragment_textures = p->_info.fragment_textures; *fragment_samplers = p->_info.fragment_samplers;
}
struct rwa_device *
bgmtl_rwa(id device)
{
   return [(BGMTLDevice *)device rwa];
}
