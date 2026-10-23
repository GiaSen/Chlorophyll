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
enum { BG_WORK_DISPATCH, BG_WORK_COPY, BG_WORK_FILL };
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
}
@end
@implementation BGWork
- (void)dealloc
{
   [pipeline release];
   for (unsigned i = 0; i < BG_MAX_BINDINGS; i++) [buffers[i] release];
   [src release]; [dst release];
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
   NSMutableArray *_completed;
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
}
- (instancetype)initWithBGCommandBuffer:(BGMTLCommandBuffer *)cb;
@end

@interface BGMTLBlitEncoder : _MTLCommandEncoder {
   BGMTLCommandBuffer *_cb;
}
- (instancetype)initWithBGCommandBuffer:(BGMTLCommandBuffer *)cb;
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
   _status = 1;   // MTLCommandBufferStatusEnqueued
   return self;
}
- (void)dealloc
{
   [_queue release]; [_work release]; [_error release]; [_completed release];
   [super dealloc];
}
- (id)device { return [_queue device]; }
- (void)bgRecord:(BGWork *)w { [_work addObject:w]; }
- (NSInteger)status { return _status; }
- (NSError *)error { return _error; }
- (void)enqueue {}
- (void)addScheduledHandler:(void (^)(id))block { if (block) block(self); }
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
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = w->count };
         if (rwa_dispatch_buffers(w->pipeline->_compute, &b, table, w->count, w->groups, w->group_size, why, sizeof(why)) != 0) {
            [self bgFailWith:[NSString stringWithUTF8String:why] code:2];
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
   for (void (^h)(id) in _completed) h(self);
   [_completed removeAllObjects];
}

- (void)waitUntilCompleted {}   // commit is synchronous in this spike: it returns after the fence

- (id)computeCommandEncoder { return [[[BGMTLComputeEncoder alloc] initWithBGCommandBuffer:self] autorelease]; }
- (id)computeCommandEncoderWithDescriptor:(id)d { (void)d; return [self computeCommandEncoder]; }
- (id)computeCommandEncoderWithDispatchType:(NSUInteger)t { (void)t; return [self computeCommandEncoder]; }
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

// ---- entry point for test processes ----------------------------------------------------------------------------------
id
bgmtl_create_device(void)
{
   return [[BGMTLDevice alloc] initWithAcceleratorPort:0];
}
