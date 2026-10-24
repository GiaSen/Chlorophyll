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
#include <libkern/OSByteOrder.h>
#include <os/lock.h>
#include <pthread.h>
#include <Block.h>
#include <sys/stat.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <time.h>
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
@interface _MTLDepthStencilState : NSObject
- (instancetype)initWithDevice:(id)device depthStencilDescriptor:(id)descriptor;
@end

#define BG_LOG(...) bg_log(__VA_ARGS__)
static void
bg_log(const char *fmt, ...)
{
   static FILE *tf;
   static int tf_tried;
   va_list ap;
   va_start(ap, fmt);
   fprintf(stderr, "bgmtl[%d]: ", getpid());
   vfprintf(stderr, fmt, ap);
   va_end(ap);
   // /private/var/tmp/bgmtl.trace: the log also goes to bgmtl-trace-<pid>.txt there (daemons and extensions whose stderr
   // nobody reads and whose environment launchd sets, such as the wallpaper poster)
   if (!tf_tried) {
      tf_tried = 1;
      if (access("/private/var/tmp/bgmtl.trace", F_OK) == 0) {
         char path[96];
         snprintf(path, sizeof(path), "/private/var/tmp/bgmtl-trace-%d.txt", getpid());
         tf = fopen(path, "a");
      }
   }
   if (tf) {
      va_start(ap, fmt);
      vfprintf(tf, fmt, ap);
      va_end(ap);
      fflush(tf);
   }
}

// BGMTL_TRACE=1 or /private/var/tmp/bgmtl.trace: one line per command buffer, render pass, pipeline build and commit
// (what a client such as CoreAnimation sends)
static int
bg_trace(void)
{
   static int t = -1;
   if (t < 0) t = getenv("BGMTL_TRACE") != NULL || access("/private/var/tmp/bgmtl.trace", F_OK) == 0;
   return t;
}
#define BG_TRACE(...) do { if (bg_trace()) bg_log(__VA_ARGS__); } while (0)

// One Gallium context serves every thread of the process, and QuartzCore commits from several (the render thread and
// com.apple.coreanimation.asynchronous at once crashed in fd6_draw_vbos). Every call that reaches the context runs under this
// recursive lock; only the fence wait of the completion queue stays outside (it uses the screen).
static pthread_mutex_t bg_ctx_mutex;
static void
bg_ctx_init(void)
{
   pthread_mutexattr_t a;
   pthread_mutexattr_init(&a);
   pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
   pthread_mutex_init(&bg_ctx_mutex, &a);
   pthread_mutexattr_destroy(&a);
}
static void bg_lock(void) { static pthread_once_t once = PTHREAD_ONCE_INIT; pthread_once(&once, bg_ctx_init); pthread_mutex_lock(&bg_ctx_mutex); }
static void bg_unlock(void) { pthread_mutex_unlock(&bg_ctx_mutex); }

#define BG_MAX_BINDINGS 16

// provided by the injection dylib (gpu/metal/inject), absent in the test tools
__attribute__((weak)) void bgmtl_note_failure(const char *why) { (void)why; }   // overridden by the injection dylib
__attribute__((weak)) void bgmtl_note_unimplemented(const char *sel) { (void)sel; }
__attribute__((weak)) void bgmtl_note_completed(void) {}   // a command buffer finished without error (the injection's dead-man reset)
__attribute__((weak)) void bgmtl_note_committed(void) {}   // a command buffer was committed (starts the injection's dead-man clock)
__attribute__((weak)) void bgmtl_note_line(const char *line) { (void)line; }   // one diagnostic line, logged by the injection dylib
__attribute__((weak)) void bgmtl_note_present(const char *line) { (void)line; }   // per-present diagnostics, logged (rate-limited) by the injection dylib   // likewise: logged by the injection dylib

@class BGMTLDevice;
@class BGMTLComputePipeline;

// ---- recorded work ---------------------------------------------------------------------------------------------------
enum { BG_WORK_DISPATCH, BG_WORK_COPY, BG_WORK_FILL, BG_WORK_DRAW, BG_WORK_TEXCOPY, BG_WORK_BUF2TEX, BG_WORK_TEX2BUF, BG_WORK_CLEAR, BG_WORK_MIPMAPS };
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
   id depth, depth_state;          // depth/stencil attachment texture and state object
   BOOL clear_depth_set, clear_stencil_set;
   float clear_depth;
   unsigned clear_stencil, stencil_ref[2];
   BOOL have_range;
   float depth_range[2];
   BOOL have_scissor;
   unsigned scissor[4];
   // texture blits: source/destination slice+level, origins and the size of the region, buffer layout
   unsigned clear_mask;            // BG_WORK_CLEAR: bit i = colour attachment i is MTLLoadActionClear to clear_vals[i]
   float clear_vals[8][4];
   NSUInteger t_sslice, t_slevel, t_dslice, t_dlevel, t_sorg[3], t_dorg[3], t_size[3], t_bpr, t_bpi;
}
@end
// Unknown selectors on the queue, command buffers, encoders and resources: logged once each and answered with zero / a no-op,
// as the device does, so a client (CoreAnimation) shows every gap in one run instead of dying on the first. The signature comes
// from Metal's protocols (MTL*), where every such selector is declared.
static NSMethodSignature *
bg_proto_signature(SEL sel)
{
   unsigned n = 0;
   Protocol *__unsafe_unretained *all = objc_copyProtocolList(&n);
   NSMethodSignature *sig = nil;
   for (unsigned i = 0; i < n && !sig; i++) {
      if (strncmp(protocol_getName(all[i]), "MTL", 3) != 0) continue;
      for (int req = 0; req < 2 && !sig; req++) {
         struct objc_method_description d = protocol_getMethodDescription(all[i], sel, req, YES);
         if (d.name && d.types) sig = [NSMethodSignature signatureWithObjCTypes:d.types];
      }
   }
   free(all);
   if (!sig) {     // SPI declared nowhere at run time (setResponsibleTaskIDs:count:): void, one pointer-sized argument per colon
      char types[64] = "v@:";
      for (const char *c = sel_getName(sel); *c && strlen(types) < sizeof(types) - 1; c++)
         if (*c == ':') strcat(types, "Q");
      sig = [NSMethodSignature signatureWithObjCTypes:types];
   }
   return sig;
}

static NSMethodSignature *
bg_fwd_sig(id self, SEL _cmd, SEL sel)
{
   (void)_cmd;
   Method m = class_getInstanceMethod(object_getClass(self), sel);     // implemented somewhere up the chain
   if (m) return [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
   return bg_proto_signature(sel);   // the base classes' own -methodSignatureForSelector: is not asked: it may throw
}

static void
bg_fwd_inv(id self, SEL _cmd, NSInvocation *inv)
{
   (void)_cmd;
   static NSMutableSet *seen;
   static os_unfair_lock lk = OS_UNFAIR_LOCK_INIT;
   NSString *key = [NSString stringWithFormat:@"%s %s", class_getName(object_getClass(self)), sel_getName([inv selector])];
   os_unfair_lock_lock(&lk);
   if (!seen) seen = [[NSMutableSet alloc] init];
   BOOL fresh = ![seen containsObject:key];
   if (fresh) [seen addObject:key];
   os_unfair_lock_unlock(&lk);
   if (fresh) {
      BG_LOG("%s: unimplemented, answered with zero\n", key.UTF8String);
      bgmtl_note_unimplemented(sel_getName([inv selector]));
   }
   NSUInteger len = [[inv methodSignature] methodReturnLength];
   if (len) {
      void *z = calloc(1, len);
      [inv setReturnValue:z];
      free(z);
   }
}

static void
bg_install_fallback(Class c)
{
   class_addMethod(c, @selector(methodSignatureForSelector:), (IMP)bg_fwd_sig, "@@::");
   class_addMethod(c, @selector(forwardInvocation:), (IMP)bg_fwd_inv, "v@:@");
}

@implementation BGWork
- (void)dealloc
{
   [pipeline release];
   for (unsigned i = 0; i < BG_MAX_BINDINGS; i++) [buffers[i] release];
   [src release]; [dst release]; [render release]; [index_buffer release]; [depth release]; [depth_state release];
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
   NSMutableDictionary *_nulls;    // zero textures for unbound slots, by type and element
}
- (struct rwa_device *)rwa;
- (id)bgNullTextureForType:(unsigned)type element:(unsigned)element;
- (NSString *)bgWhy;
- (id)bgFail:(NSError **)error with:(NSString *)reason;
@end

@interface BGMTLBuffer : _MTLResource {
   BGMTLDevice *_owner;
   struct rwa_buffer *_buf;
   void *_contents;
   NSUInteger _length;
   void *_mapped;                               // the GPU memory when _contents is a caller's (newBufferWithBytesNoCopy)
   void (^_deallocator)(void *, NSUInteger);
}
- (instancetype)initWithBGDevice:(BGMTLDevice *)device length:(NSUInteger)length;
- (instancetype)initWithBGDevice:(BGMTLDevice *)device bytesNoCopy:(void *)p length:(NSUInteger)length deallocator:(void (^)(void *, NSUInteger))dealloc;
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
   dispatch_group_t _done;                                 // left when the completion (fence) has run: waitUntilCompleted
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
   @public
   id _linSrc;           // newLinearTextureWithDescriptor: the buffer whose bytes this texture shows (retained)
   NSUInteger _linOff, _linBpr;
   const void *_ncBytes; // newTextureWithBytesNoCopy: the caller's memory, refreshed from at each use like _linSrc
   NSUInteger _ncLength;
   void (^_ncDealloc)(void *, NSUInteger);
}
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLTextureDescriptor *)d;
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLTextureDescriptor *)d iosurface:(void *)surface plane:(NSUInteger)plane;
- (struct rwa_texture *)rwaTexture;
- (struct rwa_texture *)rwaTextureSampled;   // also cleans the CPU cache of a surface another process wrote since
@end

@interface BGMTLSampler : _MTLSamplerState {
   BGMTLDevice *_owner;
   struct rwa_sampler *_smp;
}
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLSamplerDescriptor *)d;
- (struct rwa_sampler *)rwaSampler;
@end

@interface BGMTLDepthStencil : _MTLDepthStencilState {
   BGMTLDevice *_owner;
   struct rwa_depth_stencil *_ds;
   BOOL _readsDepth, _writesDepth, _readsStencil, _writesStencil;
}
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLDepthStencilDescriptor *)d;
- (struct rwa_depth_stencil *)rwaState;
@end

@interface BGMTLRenderPipeline : _MTLRenderPipelineState {
 @public
   BGMTLDevice *_owner;
   struct rwa_render *_render;
   struct rwa_render_info _info;
   struct rwa_texture_decl _decls[16];   // the fragment stage's texture slots, for filling the ones nothing was bound to
   unsigned _ndecls;
   char _names[96];
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
   unsigned _clear_mask;           // colour attachments cleared at the start of the pass
   float _clear_vals[8][4];
   NSMutableArray *_scratch;
   id _depth, _depth_state;
   BOOL _clear_depth_pending, _clear_stencil_pending;
   float _clear_depth_v;
   unsigned _clear_stencil_v, _stencil_ref[2];
   BOOL _have_range;
   float _range[2];
   BOOL _have_scissor;
   unsigned _scissor[4];
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
   // by class object, not by name: Chlorophyll.bundle builds this file with every class renamed (CHL_...), and a name
   // lookup there would patch the inject's copy instead of its own
   Class fb[] = { [BGMTLCommandQueue class], [BGMTLCommandBuffer class], [BGMTLRenderEncoder class], [BGMTLComputeEncoder class],
                  [BGMTLBlitEncoder class], [BGMTLBuffer class], [BGMTLTexture class], [BGMTLRenderPipeline class],
                  [BGMTLComputePipeline class], [BGMTLSampler class], [BGMTLDepthStencil class] };
   for (unsigned i = 0; i < sizeof(fb) / sizeof(fb[0]); i++) {
      if (fb[i]) bg_install_fallback(fb[i]);
   }
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

// Metal's private -targetDeviceInfo: a pointer to {u64, u32, const char *name at +0x10}, read when a library is loaded or
// compiled (Metal+0x24888, iOS 18.7.8: it dereferences +0x10 without a check). The fallback forwarding answered NULL and
// SpringBoard's Siri orb (SiriUICore) crashed there. The values are what Metal builds itself for a device that does not
// answer: zeros and the device name.
- (const void *)targetDeviceInfo
{
   static const struct { uint64_t a; uint32_t b; const char *name; } info = { 0, 0, "Chlorophyll" };
   return &info;
}
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

// The device is a stand-in for a Metal device in a process that has none, so a client may ask it something nobody has implemented yet.
// Metal's stock behaviour for an unknown selector is to abort the process; for a selector that IS in the MTLDevice / MTLDeviceSPI
// protocols we answer zero (nil / NO / 0) and tell the injection dylib, which logs it. Anything outside the protocols still aborts.
- (id)bgNullTextureForType:(unsigned)type element:(unsigned)element
{
   if (!_nulls) _nulls = [[NSMutableDictionary alloc] init];
   NSNumber *key = @(type * 8 + element);
   id t = _nulls[key];
   if (t) return t;
   MTLTextureDescriptor *d = [[[MTLTextureDescriptor alloc] init] autorelease];
   d.textureType = (MTLTextureType)type;
   d.pixelFormat = element == RWA_ELEMENT_UINT ? MTLPixelFormatRGBA8Uint : element == RWA_ELEMENT_INT ? MTLPixelFormatRGBA8Sint : MTLPixelFormatRGBA8Unorm;
   d.width = 1; d.height = 1; d.depth = 1; d.arrayLength = 1; d.mipmapLevelCount = 1; d.sampleCount = 1;
   d.usage = MTLTextureUsageShaderRead;
   t = [[self newTextureWithDescriptor:d] autorelease];
   if (!t) return nil;
   uint8_t zero[16] = { 0 };
   unsigned slices = type == MTLTextureTypeCube ? 6 : 1;
   for (unsigned sl = 0; sl < slices; sl++)
      [t replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:sl withBytes:zero bytesPerRow:16 bytesPerImage:0];
   _nulls[key] = t;
   return t;
}
- (uint64_t)registryID { return 0x10000b630ULL; }
- (BOOL)supportsSampleCount:(NSUInteger)count { return count == 1 || count == 4; }
- (BOOL)isDepth24Stencil8PixelFormatSupported { return NO; }
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(NSUInteger)format { (void)format; return 64; }
// Linear textures (and the buffers clients size for them, CoreGraphics' CGImageTextureData among them) have rows
// aligned to 64 bytes here (freedreno a6xx pitch alignment). The fallback answered 0 and SpringBoard's image upload
// wrote past an ImageIO buffer into its guard page (KERN_PROTECTION_FAILURE in CGImageTextureDataGetOffsetWithBlock).
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(NSUInteger)format { (void)format; return 64; }
// Heap sizing queries: page-aligned, and for textures an upper bound (16 bytes a texel, every mip level), never zero.
- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
   (void)options;
   return (MTLSizeAndAlign){ (length + 0x3fff) & ~(NSUInteger)0x3fff, 0x4000 };
}
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)d
{
   NSUInteger w = d.width ? d.width : 1, h = d.height ? d.height : 1, z = d.depth ? d.depth : 1;
   NSUInteger layers = (d.arrayLength ? d.arrayLength : 1) * (d.textureType == MTLTextureTypeCube || d.textureType == MTLTextureTypeCubeArray ? 6 : 1);
   NSUInteger total = 0;
   for (NSUInteger l = 0; l < (d.mipmapLevelCount ? d.mipmapLevelCount : 1); l++) {
      NSUInteger lw = w >> l ? w >> l : 1, lh = h >> l ? h >> l : 1, lz = z >> l ? z >> l : 1;
      total += ((lw * 16 + 63) & ~(NSUInteger)63) * lh * lz * layers * (d.sampleCount ? d.sampleCount : 1);
   }
   return (MTLSizeAndAlign){ (total + 0x3fff) & ~(NSUInteger)0x3fff, 0x4000 };
}
- (uint64_t)sharedMemorySize { return 2048ULL << 20; }
- (uint64_t)dedicatedMemorySize { return 0; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
   NSMethodSignature *sig = [super methodSignatureForSelector:sel];
   if (sig) return sig;
   const char *names[] = { "MTLDevice", "MTLDeviceSPI" };
   for (unsigned i = 0; i < 2; i++) {
      Protocol *pr = objc_getProtocol(names[i]);
      if (!pr) continue;
      for (int req = 0; req < 2; req++) {
         struct objc_method_description d = protocol_getMethodDescription(pr, sel, req, YES);
         if (d.name && d.types) return [NSMethodSignature signatureWithObjCTypes:d.types];
      }
   }
   return nil;
}

- (void)forwardInvocation:(NSInvocation *)inv
{
   SEL sel = [inv selector];
   BG_LOG("device: unimplemented %s answered with zero\n", sel_getName(sel));
   bgmtl_note_unimplemented(sel_getName(sel));
   NSUInteger len = [[inv methodSignature] methodReturnLength];
   if (len) {
      void *z = calloc(1, len);
      [inv setReturnValue:z];
      free(z);
   }
}

// traced pass-throughs of the capability queries CoreAnimation makes (what it chooses its renderer conventions from)
- (BOOL)supportsFamily:(NSInteger)family
{
   // Apple1..Apple3 and Common1..Common2, as UniXNU's native device answers (Apple4+ promise tile shaders and imageblocks,
   // which Chlorophyll does not run yet); everything else as _MTLDevice's tables say. BGMTL_FAMILY=N overrides the Apple ceiling.
   static long apple_max = -1;
   if (apple_max < 0) apple_max = getenv("BGMTL_FAMILY") ? atol(getenv("BGMTL_FAMILY")) : 3;
   BOOL r;
   if (family >= 1001 && family <= 1009) r = family - 1000 <= apple_max;          // MTLGPUFamilyApple1..9
   else if (family == 3001 || family == 3002) r = YES;                            // MTLGPUFamilyCommon1, Common2
   else r = ((BOOL (*)(struct objc_super *, SEL, NSInteger))objc_msgSendSuper)(&(struct objc_super){ self, [_MTLDevice class] }, _cmd, family);
   BG_TRACE("supportsFamily %ld -> %d\n", (long)family, r);
   return r;
}
- (BOOL)supportsFeatureSet:(NSUInteger)set
{
   BOOL r = ((BOOL (*)(struct objc_super *, SEL, NSUInteger))objc_msgSendSuper)(&(struct objc_super){ self, [_MTLDevice class] }, _cmd, set);
   BG_TRACE("supportsFeatureSet %lu -> %d\n", (unsigned long)set, r);
   return r;
}

// No extended-range (XR) formats: the Adreno renders BGRA8, R8 and RGBA16Float natively and no 10-bit XR layout. With YES (the
// default tables of the profile) QuartzCore's render server built its deep-colour pipelines in RGB10A8_2P_XR10 (550), which
// Chlorophyll refuses, and aborted "Metal failed to build render pipeline" (first backboardd run). With NO it renders the SDR
// path only (air2ir3's FORMATS.md: WindowServer decides the same way).
- (BOOL)supportsExtendedXR10Formats { BG_TRACE("supportsExtendedXR10Formats -> NO\n"); return NO; }
- (BOOL)supportsExtendedColors { BG_TRACE("supportsExtendedColors -> NO\n"); return NO; }

- (BOOL)metalAssertionsEnabled { return _assertions; }
- (void)setMetalAssertionsEnabled:(BOOL)enabled { _assertions = enabled; }

- (id)newCommandQueueWithDescriptor:(id)descriptor
{
   id use = descriptor ? [[descriptor retain] autorelease] : [[[MTLCommandQueueDescriptor alloc] init] autorelease];
   return [[BGMTLCommandQueue alloc] initWithBGDevice:self descriptor:use];
}

// -- libraries from files: system metallibs (QuartzCore's default.metallib) are fat wrappers, slice 0 the AIR container
// ("MTLB"), slice 1 precompiled Apple GPU code. _MTLDevice's own URL/bundle loaders pick the slice through MTLLoader by the
// device's target architecture, which this device does not have (assertion "Target device architecture is nil"), so the
// AIR slice is taken here and loaded with -newLibraryWithData:, the path every other library of this device takes --
static NSData *
bg_air_slice(NSData *d)
{
   const uint8_t *b = d.bytes;
   NSUInteger n = d.length;
   if (n >= 4 && memcmp(b, "MTLB", 4) == 0) return d;
   if (n < 8 || OSReadBigInt32(b, 0) != 0xcafebabeu) return nil;
   uint32_t count = OSReadBigInt32(b, 4);
   for (uint32_t i = 0; i < count && 8 + 20 * (NSUInteger)(i + 1) <= n; i++) {
      uint32_t off = OSReadBigInt32(b, 8 + 20 * i + 8), size = OSReadBigInt32(b, 8 + 20 * i + 12);
      if ((NSUInteger)off + size <= n && size >= 4 && memcmp(b + off, "MTLB", 4) == 0)
         return [d subdataWithRange:NSMakeRange(off, size)];
   }
   return nil;
}

- (id)newLibraryWithURL:(NSURL *)url error:(NSError **)error
{
   NSData *d = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
   NSData *air = d ? bg_air_slice(d) : nil;
   if (!air) {
      BG_LOG("library %s: %s\n", url.path.UTF8String, d ? "no AIR (MTLB) slice" : "unreadable");
      if (error && d)
         *error = [NSError errorWithDomain:@"MTLLibraryErrorDomain" code:1
                                  userInfo:@{ NSLocalizedDescriptionKey : @"no AIR slice in the metallib" }];
      return nil;
   }
   [air retain];
   dispatch_data_t dd = dispatch_data_create(air.bytes, air.length, NULL, ^{ [air release]; });
   id lib = ((id (*)(id, SEL, dispatch_data_t, NSError **))objc_msgSend)(self, @selector(newLibraryWithData:error:), dd, error);
   dispatch_release(dd);
   BG_LOG("library %s: AIR slice %lu bytes -> %s\n", url.path.UTF8String, (unsigned long)air.length, lib ? "loaded" : "refused");
   return lib;
}

- (id)newLibraryWithFile:(NSString *)path error:(NSError **)error
{
   return [self newLibraryWithURL:[NSURL fileURLWithPath:path] error:error];
}

- (id)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error
{
   NSURL *url = [bundle URLForResource:@"default" withExtension:@"metallib"];
   if (!url) {
      if (error)
         *error = [NSError errorWithDomain:@"MTLLibraryErrorDomain" code:1
                                  userInfo:@{ NSLocalizedDescriptionKey : @"no default.metallib in the bundle" }];
      return nil;
   }
   return [self newLibraryWithURL:url error:error];
}

// Binary archives (QuartzCore opens one with a URL: pipelines precompiled for Apple GPUs). Reading it asserts in MTLLoader for
// want of a target architecture, and nothing in it runs on an Adreno: the archive is created empty (no URL), so it only
// serves as the cache object the caller expects; pipelines are built from AIR as always.
- (id)newBinaryArchiveWithDescriptor:(MTLBinaryArchiveDescriptor *)descriptor error:(NSError **)error
{
   MTLBinaryArchiveDescriptor *d = [[descriptor copy] autorelease];
   if (d.url)
      BG_LOG("binary archive %s: opened empty (precompiled Apple GPU code)\n", d.url.path.UTF8String);
   d.url = nil;
   return [super newBinaryArchiveWithDescriptor:d error:error];
}

- (id)newDefaultLibrary
{
   return [self newDefaultLibraryWithBundle:[NSBundle mainBundle] error:NULL];
}

- (id)newBufferWithLength:(NSUInteger)length options:(NSUInteger)options
{
   (void)options;
   return [[BGMTLBuffer alloc] initWithBGDevice:self length:length];
}

- (id)newBufferWithBytesNoCopy:(void *)p length:(NSUInteger)length options:(NSUInteger)options deallocator:(void (^)(void *, NSUInteger))dealloc
{
   (void)options;
   return [[BGMTLBuffer alloc] initWithBGDevice:self bytesNoCopy:p length:length deallocator:dealloc];
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

// A texture over the caller's memory (QuartzCore's CPU-drawn images): a texture of our own, refreshed from those bytes at each use
// (rows of length / height bytes), and the deallocator called when it is freed.
- (id)newTextureWithBytesNoCopy:(void *)p length:(NSUInteger)length descriptor:(MTLTextureDescriptor *)d deallocator:(void (^)(void *, NSUInteger))dealloc
{
   BGMTLTexture *t = [[BGMTLTexture alloc] initWithBGDevice:self descriptor:d];
   if (!t) return nil;
   t->_ncBytes = p;
   t->_ncLength = length;
   t->_ncDealloc = dealloc ? Block_copy(dealloc) : NULL;
   return t;
}

- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(void *)surface plane:(NSUInteger)plane
{
   return [[BGMTLTexture alloc] initWithBGDevice:self descriptor:d iosurface:surface plane:plane];
}

- (id)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)d
{
   return [[BGMTLDepthStencil alloc] initWithBGDevice:self descriptor:d];
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
   BG_TRACE("render pipeline: vertex %s fragment %s\n", vertex ? [[vertex name] UTF8String] : "-", fragment ? [[fragment name] UTF8String] : "-");
   if (bg_trace()) {
      for (unsigned i = 0; i < 8; i++) {
         MTLRenderPipelineColorAttachmentDescriptor *ca = descriptor.colorAttachments[i];
         if (ca.pixelFormat)
            BG_LOG("  pipe color%u fmt %lu blend %d src %lu/%lu dst %lu/%lu mask %lu\n", i, (unsigned long)ca.pixelFormat, ca.blendingEnabled,
                   (unsigned long)ca.sourceRGBBlendFactor, (unsigned long)ca.sourceAlphaBlendFactor, (unsigned long)ca.destinationRGBBlendFactor,
                   (unsigned long)ca.destinationAlphaBlendFactor, (unsigned long)ca.writeMask);
      }
      BG_LOG("  pipe depth fmt %lu stencil fmt %lu\n", (unsigned long)descriptor.depthAttachmentPixelFormat, (unsigned long)descriptor.stencilAttachmentPixelFormat);
   }
   if (!fragment) return [self bgFail:error with:@"a render pipeline needs a fragment function"];
   /* no vertex function: libbgair supplies a pass-through stage over the whole attachment (a quad, 4 vertices as a strip) --
    * the road the fragment shaders of a library are exercised by, as air_run did */
   NSData *vair = vertex ? ((NSData * (*)(id, SEL))objc_msgSend)(vertex, bitcode) : nil;
   NSData *fair = ((NSData * (*)(id, SEL))objc_msgSend)(fragment, bitcode);
   if (!fair.length || (vertex && !vair.length)) return [self bgFail:error with:@"a function has no bitcode"];
   if (bg_trace() && getenv("BGMTL_DUMP")) {   // the exact modules this pipeline is built from, for air2nir on the Mac
      mkdir(getenv("BGMTL_DUMP"), 0755);
      NSString *d = [NSString stringWithUTF8String:getenv("BGMTL_DUMP")];
      if (vair) [vair writeToFile:[d stringByAppendingFormat:@"/%@.v.bc", [vertex name]] atomically:NO];
      [fair writeToFile:[d stringByAppendingFormat:@"/%@.f.bc", [fragment name]] atomically:NO];
   }
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
         BG_TRACE("  attribute %u: format %lu offset %lu buffer %lu\n", i, (unsigned long)[a format], (unsigned long)[a offset],
                  (unsigned long)[a bufferIndex]);
      }
      for (unsigned k = 0; k < RWA_MAX_VERTEX_BUFFERS; k++) {
         MTLVertexBufferLayoutDescriptor *l = [[vd layouts] objectAtIndexedSubscript:k];
         if (!l) continue;
         shape.vertex_layout[k].stride = (unsigned)[l stride];
         shape.vertex_layout[k].step_function = (unsigned)[l stepFunction];
         shape.vertex_layout[k].step_rate = (unsigned)[l stepRate];
         if ([l stride]) BG_TRACE("  layout %u: stride %lu step %lu rate %lu\n", k, (unsigned long)[l stride], (unsigned long)[l stepFunction], (unsigned long)[l stepRate]);
      }
   }
   char why[512] = { 0 };
   struct rwa_render_info info;
   memset(&info, 0, sizeof(info));
   bg_lock();
   struct rwa_render *r = rwa_render_create(_rwa, vair ? vair.bytes : NULL, vair ? vair.length : 0, vertex ? [[vertex name] UTF8String] : NULL, fair.bytes, fair.length,
                                            [[fragment name] UTF8String], &shape, &info, why, sizeof(why));
   bg_unlock();
   if (!r) return [self bgFail:error with:[NSString stringWithUTF8String:why]];
   BGMTLRenderPipeline *p = [[BGMTLRenderPipeline alloc] initWithDevice:self pipelineStateDescriptor:descriptor];
   if (!p) { bg_lock(); rwa_render_destroy(r); bg_unlock(); return [self bgFail:error with:@"_MTLRenderPipelineState refused to initialise"]; }
   p->_owner = self; p->_render = r; p->_info = info;
   {
      char dwhy[128] = { 0 };
      unsigned nd = 0;
      if (rwa_module_textures(_rwa, fair.bytes, fair.length, [[fragment name] UTF8String], p->_decls, 16, &nd, dwhy, sizeof(dwhy)) == 0) p->_ndecls = nd;
   }
   snprintf(p->_names, sizeof(p->_names), "%s+%s", vertex ? [[vertex name] UTF8String] : "gen", [[fragment name] UTF8String]);
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
   bg_lock();
   struct rwa_compute *c = rwa_compute_create(_rwa, air.bytes, air.length, [[function name] UTF8String], &info, why, sizeof(why));
   bg_unlock();
   if (!c) return [self bgFail:error with:[NSString stringWithUTF8String:why]];
   BGMTLComputePipeline *p = [[BGMTLComputePipeline alloc] initWithDevice:self pipelineStateDescriptor:descriptor];
   if (!p) { bg_lock(); rwa_compute_destroy(c); bg_unlock(); return [self bgFail:error with:@"_MTLComputePipelineState refused to initialise"]; }
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
   bg_lock();
   _buf = rwa_buffer_create([device rwa], length, why, sizeof(why));
   bg_unlock();
   if (!_buf) { BG_LOG("rwa_buffer_create(%lu): %s\n", (unsigned long)length, why); [self release]; return nil; }
   _owner = device;
   _length = length;
   _contents = rwa_buffer_map(_buf);
   return self;
}
// newBufferWithBytesNoCopy: contents is the caller's memory, as Metal promises; the GPU reads its own copy, refreshed from
// the caller's bytes each time the buffer is handed to the GPU (rwaBuffer is asked for every binding at commit). A GPU write
// into such a buffer does not reach the caller's memory; CoreAnimation's are vertex and glyph data it writes on the CPU.
- (instancetype)initWithBGDevice:(BGMTLDevice *)device bytesNoCopy:(void *)p length:(NSUInteger)length deallocator:(void (^)(void *, NSUInteger))dealloc
{
   self = [self initWithBGDevice:device length:length];
   if (!self) return nil;
   _mapped = _contents;
   _contents = p;
   _deallocator = dealloc ? Block_copy(dealloc) : NULL;
   memcpy(_mapped, p, length);
   return self;
}
- (void)dealloc
{
   if (_buf) { bg_lock(); rwa_buffer_destroy(_buf); bg_unlock(); }
   if (_deallocator) { _deallocator(_contents, _length); Block_release(_deallocator); }
   [super dealloc];
}
- (struct rwa_buffer *)rwaBuffer { if (_mapped && _contents) memcpy(_mapped, _contents, _length); return _buf; }
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
- (id)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi
{
   (void)bpi;
   BGMTLTexture *t = [[BGMTLTexture alloc] initWithBGDevice:_owner descriptor:d];
   if (!t) return nil;
   t->_linSrc = [self retain];
   t->_linOff = offset;
   t->_linBpr = bpr;
   return t;
}
@end

// ---- pipeline --------------------------------------------------------------------------------------------------------
@implementation BGMTLComputePipeline
+ (void)load { ensure_protocol(self, "MTLComputePipelineState"); }
- (void)dealloc { bg_lock(); if (_compute) rwa_compute_destroy(_compute); bg_unlock(); [super dealloc]; }
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
// CoreAnimation asks with a descriptor; _MTLCommandQueue's default would hand back a generic command buffer that never reaches the GPU
- (id)commandBufferWithDescriptor:(id)d { (void)d; return [self commandBuffer]; }
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
   _done = dispatch_group_create();
   _status = 1;   // MTLCommandBufferStatusEnqueued
   return self;
}
- (void)dealloc
{
   [_queue release]; [_work release]; [_error release]; [_completed release]; [_scheduled release]; [_presents release];
   if (_done) dispatch_release(_done);
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
   if (_status >= 3) block(self); else [_scheduled addObject:[[block copy] autorelease]];   // delivered when submitted (compositor: when finished)
}
- (void)presentDrawable:(id)drawable { if (drawable) [_presents addObject:@[ drawable, @0.0, @0.0 ]]; }
- (void)presentDrawable:(id)drawable atTime:(CFTimeInterval)t { if (drawable) [_presents addObject:@[ drawable, @(t), @0.0 ]]; }
- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)d { if (drawable) [_presents addObject:@[ drawable, @0.0, @(d) ]]; }
- (void)addCompletedHandler:(void (^)(id))block
{
   if (!block) return;
   if (_status >= 4) block(self); else [_completed addObject:[[block copy] autorelease]];
}
- (void)waitUntilScheduled { if (_status >= 2 && getenv("BGMTL_BB")) dispatch_group_wait(_done, DISPATCH_TIME_FOREVER); }

// The fence wait of a commit. A failed wait is not yet a failed command buffer: backboardd's CoreAnimation exits on the
// first failed one (one "fence timeout" and the compositor restarted, while the kernel counted every submission completed
// and no hang), so the wait is repeated twice, each failure logged with what the kernel answered (sweet_drm's WAIT_FENCE
// record: a fence it refuses as never submitted, a GPU not ready, or a real timeout), before the command buffer fails.
extern void sweet_drm_take_wait_error(char *buf, size_t size) __attribute__((weak_import));
static int
bg_fence_wait(BGMTLDevice *dev, struct rwa_fence *fence, char *why, size_t why_size)
{
   int rc = rwa_fence_wait([dev rwa], fence, why, why_size);
   for (int again = 1; rc != 0 && again <= 2; again++) {
      char k[192] = "", line[512];
      if (sweet_drm_take_wait_error)
         sweet_drm_take_wait_error(k, sizeof(k));
      snprintf(line, sizeof(line), "fence wait failed (%s) [%s]: waiting again (%d of 2)", why, k[0] ? k : "no WAIT_FENCE failed", again);
      BG_LOG("%s\n", line);
      bgmtl_note_line(line);
      rc = rwa_fence_wait([dev rwa], fence, why, why_size);
      if (rc == 0) {
         snprintf(line, sizeof(line), "fence wait succeeded on try %d", again + 1);
         bgmtl_note_line(line);
      }
   }
   return rc;
}

- (void)bgFailWith:(NSString *)why code:(NSInteger)code
{
   BG_LOG("command buffer failed: %s\n", [why UTF8String]);
   bgmtl_note_failure([why UTF8String]);   // the injection dylib counts these (its dead-man)
   _error = [[NSError errorWithDomain:@"BGMTL" code:code userInfo:@{ NSLocalizedDescriptionKey : why }] retain];
   _status = 5;   // MTLCommandBufferStatusError
}

// texture blits run on the CPU through the textures' own read/write paths (shared memory; everything before it is finished).
- (void)bgApplyTextureBlit:(BGWork *)w
{
   NSUInteger bpr = w->t_size[0] * 16, bpi = bpr * w->t_size[1];
   if (w->kind == BG_WORK_TEXCOPY) {
      void *tmp = malloc(bpi * w->t_size[2]);
      if (!tmp) return;
      MTLRegion sr = { { w->t_sorg[0], w->t_sorg[1], w->t_sorg[2] }, { w->t_size[0], w->t_size[1], w->t_size[2] } };
      MTLRegion dr = { { w->t_dorg[0], w->t_dorg[1], w->t_dorg[2] }, { w->t_size[0], w->t_size[1], w->t_size[2] } };
      [(BGMTLTexture *)w->src getBytes:tmp bytesPerRow:bpr bytesPerImage:bpi fromRegion:sr mipmapLevel:w->t_slevel slice:w->t_sslice];
      [(BGMTLTexture *)w->dst replaceRegion:dr mipmapLevel:w->t_dlevel slice:w->t_dslice withBytes:tmp bytesPerRow:bpr bytesPerImage:bpi];
      free(tmp);
   } else if (w->kind == BG_WORK_BUF2TEX) {
      MTLRegion dr = { { w->t_dorg[0], w->t_dorg[1], w->t_dorg[2] }, { w->t_size[0], w->t_size[1], w->t_size[2] } };
      [(BGMTLTexture *)w->dst replaceRegion:dr mipmapLevel:w->t_dlevel slice:w->t_dslice
                                  withBytes:(uint8_t *)[(BGMTLBuffer *)w->src contents] + w->src_off bytesPerRow:w->t_bpr bytesPerImage:w->t_bpi];
   } else {
      MTLRegion sr = { { w->t_sorg[0], w->t_sorg[1], w->t_sorg[2] }, { w->t_size[0], w->t_size[1], w->t_size[2] } };
      [(BGMTLTexture *)w->src getBytes:(uint8_t *)[(BGMTLBuffer *)w->dst contents] + w->dst_off bytesPerRow:w->t_bpr bytesPerImage:w->t_bpi
                            fromRegion:sr mipmapLevel:w->t_slevel slice:w->t_sslice];
   }
}

// Per-second timing of synchronous commits (the compositor): how a frame's time splits into CoreAnimation's own work between
// commits, our encode (command translation, Mesa batch build, kernel submit) and the wait for the GPU. One line a second in
// bgmtl.log while committing; off unless /private/var/tmp/bgmtl.perf exists when the process starts.
static void
bg_perf_note(uint64_t t_begin, uint64_t t_flushed, uint64_t t_waited, unsigned ndraw)
{
   static int on = -1;
   static uint64_t win_start, last_end, n, draws, enc, wait, gap, enc_max, wait_max;
   if (on < 0) on = access("/private/var/tmp/bgmtl.perf", F_OK) == 0;
   if (!on) return;
   if (win_start == 0) win_start = t_begin;
   uint64_t e = t_flushed - t_begin, w = t_waited - t_flushed;
   if (last_end && t_begin > last_end) gap += t_begin - last_end;
   last_end = t_waited;
   n++; draws += ndraw; enc += e; wait += w;
   if (e > enc_max) enc_max = e;
   if (w > wait_max) wait_max = w;
   if (t_waited - win_start >= 1000000000ull) {
      char line[256];
      double sec = (t_waited - win_start) / 1e9;
      snprintf(line, sizeof(line), "perf: %.1f cbuf/s, %.1f draws/cbuf; per second: encode %.0f ms, gpu wait %.0f ms, between commits %.0f ms; "
               "max encode %.1f ms, max wait %.1f ms", n / sec, n ? (double)draws / n : 0, enc / 1e6 / sec, wait / 1e6 / sec, gap / 1e6 / sec,
               enc_max / 1e6, wait_max / 1e6);
      bgmtl_note_line(line);
      win_start = t_waited; n = draws = enc = wait = gap = enc_max = wait_max = 0;
   }
}

- (void)commit
{
   bgmtl_note_committed();
   BG_TRACE("commit: %lu recorded commands\n", (unsigned long)[_work count]);
   uint64_t t_begin = clock_gettime_nsec_np(CLOCK_MONOTONIC);
   BGMTLDevice *dev = (BGMTLDevice *)[_queue device];
   _status = 2;   // Committed
   char why[512] = { 0 };
   bg_lock();
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
         for (unsigned i = 0; i < w->texture_count; i++) texs[i] = [(BGMTLTexture *)w->textures[i] rwaTextureSampled];
         for (unsigned i = 0; i < w->sampler_count; i++) smps[i] = [(BGMTLSampler *)w->samplers[i] rwaSampler];
         struct rwa_bindings b = { .buffers = bufs, .buffer_count = w->count, .textures = texs, .texture_count = w->texture_count,
                                   .samplers = smps, .sampler_count = w->sampler_count };
         if (rwa_dispatch_buffers(w->pipeline->_compute, &b, table, w->count, w->groups, w->group_size, why, sizeof(why)) != 0) {
            [self bgFailWith:[NSString stringWithUTF8String:why] code:2];
            break;
         }
      } else if (w->kind == BG_WORK_CLEAR) {
         struct rwa_texture *colors[8] = { NULL };
         for (unsigned i = 0; i < w->color_count; i++) colors[i] = [(BGMTLTexture *)w->color[i] rwaTexture];
         struct rwa_clear cl;
         memset(&cl, 0, sizeof(cl));
         cl.color = colors; cl.color_count = w->color_count; cl.color_mask = w->clear_mask;
         memcpy(cl.color_value, w->clear_vals, sizeof(cl.color_value));
         if (w->depth) cl.depth = [(BGMTLTexture *)w->depth rwaTexture];
         if (w->clear_depth_set) cl.clear_depth = &w->clear_depth;
         if (w->clear_stencil_set) cl.clear_stencil = &w->clear_stencil;
         if (rwa_render_clear([dev rwa], &cl, why, sizeof(why)) != 0)
            BG_LOG("clear skipped: %s\n", why);   // one bad clear no longer drops the rest of the frame (see the draw below)
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
         for (unsigned i = 0; i < w->texture_count; i++) texs[i] = [(BGMTLTexture *)w->textures[i] rwaTextureSampled];
         for (unsigned i = 0; i < w->sampler_count; i++) smps[i] = [(BGMTLSampler *)w->samplers[i] rwaSampler];
         for (unsigned i = 0; i < w->color_count; i++) colors[i] = [(BGMTLTexture *)w->color[i] rwaTexture];
         struct rwa_draw dr;
         memset(&dr, 0, sizeof(dr));
         dr.color = colors; dr.color_count = w->color_count;
         dr.clear_color = w->clear ? w->clear_color : NULL;
         if (w->depth) dr.depth = [(BGMTLTexture *)w->depth rwaTexture];
         if (w->clear_depth_set) dr.clear_depth = &w->clear_depth;
         if (w->clear_stencil_set) dr.clear_stencil = &w->clear_stencil;
         if (w->depth_state) dr.depth_stencil = [(BGMTLDepthStencil *)w->depth_state rwaState];
         dr.stencil_reference[0] = w->stencil_ref[0]; dr.stencil_reference[1] = w->stencil_ref[1];
         if (w->have_range) dr.depth_range = w->depth_range;
         if (w->have_scissor) dr.scissor = w->scissor;
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
         /* A draw the runtime refuses is skipped and logged, and the rest of the command buffer still runs. Failing the
          * whole command buffer left the frame's later passes undrawn (the wallpaper area black or grey, stale wedges in
          * the poster editor) and counted towards the watchdog that switches Metal off. */
         if (rwa_render_draw(rp->_render, &dr, why, sizeof(why)) != 0)
            BG_LOG("draw skipped: %s\n", why);
         // debugging (/private/var/tmp/bgmtl.dumpatt with the trace): colour 0 right after each blur-chain draw, before any
         // later draw of the pass touches it
         if (bg_trace() && w->color_count && w->color[0] && access("/private/var/tmp/bgmtl.dumpatt", F_OK) == 0 &&
             (strstr(rp->_names, "downsample") || strstr(rp->_names, "_Idst"))) {
            static unsigned pseq;
            BGMTLTexture *t = (BGMTLTexture *)w->color[0];
            unsigned wd = MIN((unsigned)[t width], 256u), ht = MIN((unsigned)[t height], 256u);   // the top-left corner of big targets
            if (pseq < 80 && [t width] >= 1000 && rwa_finish([dev rwa], why, sizeof(why)) == 0) {
               uint8_t *buf = malloc((size_t)wd * ht * 4);
               if (buf) {
                  [t getBytes:buf bytesPerRow:wd * 4 fromRegion:MTLRegionMake2D(0, 0, wd, ht) mipmapLevel:0];
                  char path[128];
                  snprintf(path, sizeof(path), "/private/var/tmp/att/post-%04u-%s-%ux%u.raw", pseq++,
                           strstr(rp->_names, "_Idst") ? "fetch" : "ds", wd, ht);
                  FILE *f = fopen(path, "wb");
                  if (f) { fwrite(buf, 1, (size_t)wd * ht * 4, f); fclose(f); BG_LOG("  after-draw dump %s\n", path); }
                  free(buf);
               }
            }
         }
      } else if (w->kind == BG_WORK_MIPMAPS) {
         if (rwa_texture_generate_mipmaps([(BGMTLTexture *)w->dst rwaTexture]) != 0)
            BG_LOG("blit: generateMipmapsForTexture: no mip chain made\n");
      } else if (w->kind == BG_WORK_TEXCOPY &&
                 rwa_texture_copy([(BGMTLTexture *)w->src rwaTexture], (unsigned)w->t_slevel, (unsigned)w->t_sslice,
                                  (const unsigned[3]){ (unsigned)w->t_sorg[0], (unsigned)w->t_sorg[1], (unsigned)w->t_sorg[2] },
                                  [(BGMTLTexture *)w->dst rwaTexture], (unsigned)w->t_dlevel, (unsigned)w->t_dslice,
                                  (const unsigned[3]){ (unsigned)w->t_dorg[0], (unsigned)w->t_dorg[1], (unsigned)w->t_dorg[2] },
                                  (const unsigned[3]){ (unsigned)w->t_size[0], (unsigned)w->t_size[1], (unsigned)w->t_size[2] }) == 0) {
         // copied on the GPU, in order with the draws
      } else {
         // CPU blit on shared memory: everything dispatched so far must be done first
         if (rwa_finish([dev rwa], why, sizeof(why)) != 0) { [self bgFailWith:[NSString stringWithUTF8String:why] code:3]; break; }
         if (w->kind == BG_WORK_TEXCOPY || w->kind == BG_WORK_BUF2TEX || w->kind == BG_WORK_TEX2BUF) {
            [self bgApplyTextureBlit:w];
         } else if (w->kind == BG_WORK_COPY)
            memmove((uint8_t *)[(BGMTLBuffer *)w->dst contents] + w->dst_off, (uint8_t *)[(BGMTLBuffer *)w->src contents] + w->src_off, w->size);
         else
            memset((uint8_t *)[(BGMTLBuffer *)w->dst contents] + w->dst_off, w->fill, w->size);
      }
   }
   // Asynchronous completion (Chlorophyll: CPU and GPU overlap, as Metal's own do): the work is submitted and its fence handed to
   // a serial completion queue, which waits for it and then runs what follows a completed command buffer (surface sync, presents,
   // completed handlers), in submission order. BGMTL_TRACE keeps it synchronous: the trace reads attachments back through the
   // drawing context, which belongs to the encoding thread.
   dispatch_group_enter(_done);
   // In the compositor "scheduled" is reported only when the GPU has FINISHED: the render server hands a framebuffer to the
   // display from the scheduled notification / waitUntilScheduled, and this display path has no GPU write fence on the surface,
   // so an earlier notice let the panel scan a half-drawn buffer (its previous frame showed: motion stepping back and forth).
   // The encoding of the next frame still overlaps the GPU; only the hand-off waits.
   // Now opt-in (BGMTL_DEFER_SCHEDULED=1, set by the inject when /private/var/tmp/bgmtl-bb.defersched exists): the kernel
   // holds a swap until the GPU work before it completed (0229), and with its GPU scan-out copy (0240) the copy runs after
   // that work on the same ring anyway. Deferring here made the render server wait for the GPU before every swap, so the
   // next frame's encoding could not overlap the GPU at all.
   static int defer_scheduled = -1;
   if (defer_scheduled < 0) defer_scheduled = getenv("BGMTL_DEFER_SCHEDULED") && getenv("BGMTL_DEFER_SCHEDULED")[0] == '1';
   if (_status != 5 && !defer_scheduled)
      _status = 3;   // Scheduled
   struct rwa_fence *fence = _status != 5 ? rwa_flush([dev rwa]) : NULL;
   uint64_t t_flushed = clock_gettime_nsec_np(CLOCK_MONOTONIC);
   bg_unlock();
   if (!defer_scheduled) {
      for (void (^h)(id) in _scheduled) h(self);
      [_scheduled removeAllObjects];
   }
   static int sync_commit = -1;     // BGMTL_SYNC=1 (the inject sets it when /private/var/tmp/bgmtl-bb.sync exists): wait inline, as before
   if (sync_commit < 0)   // or /private/var/tmp/bgmtl.sync for every process (posters, plugin clients) launchd starts
      sync_commit = (getenv("BGMTL_SYNC") && getenv("BGMTL_SYNC")[0] == '1') || access("/private/var/tmp/bgmtl.sync", F_OK) == 0;
   if (bg_trace() || sync_commit || _status == 5) {
      if (_status != 5 && bg_fence_wait(dev, fence, why, sizeof(why)) != 0)
         [self bgFailWith:[NSString stringWithUTF8String:why] code:3];
      else if (_status != 5)
         _status = 4;
      {
         unsigned nd = 0;
         for (BGWork *w in _work)
            if (w->kind == BG_WORK_DRAW) nd++;
         bg_perf_note(t_begin, t_flushed, clock_gettime_nsec_np(CLOCK_MONOTONIC), nd);
      }
      rwa_fence_release([dev rwa], fence);
      [self bgCompleteFrom:t_begin];
      dispatch_group_leave(_done);
      return;
   }
   static dispatch_queue_t completion;
   static dispatch_once_t once;
   dispatch_once(&once, ^{ completion = dispatch_queue_create("chlorophyll.completion", DISPATCH_QUEUE_SERIAL); });
   [self retain];
   dispatch_async(completion, ^{
      char w2[512] = { 0 };
      if (bg_fence_wait(dev, fence, w2, sizeof(w2)) != 0)
         [self bgFailWith:[NSString stringWithUTF8String:w2] code:3];
      else
         _status = 4;   // Completed: the fence has been paid
      rwa_fence_release([dev rwa], fence);
      [self bgCompleteFrom:t_begin];
      dispatch_group_leave(_done);
      [self release];
   });
}

// What follows a completed (or failed) command buffer; run by the completion queue, or inline when tracing.
- (void)bgCompleteFrom:(uint64_t)t_begin
{
   BGMTLDevice *dev = (BGMTLDevice *)[_queue device];
   (void)dev;
   for (void (^h)(id) in _scheduled) h(self);    // left here by the compositor's deferral (see commit)
   [_scheduled removeAllObjects];
   // what the GPU wrote into an IOSurface becomes visible to the compositor before the drawable is presented
   // In the compositor (backboardd, BGMTL_BB) the IOSurfaces drawn into are its own framebuffers: the GPU writes DRAM, the display
   // reads DRAM, the CPU never touches them, so neither the cache clean nor the seed bump below is needed -- and each was a kernel
   // round trip per attachment per commit over 10 MB surfaces (the largest cost in the first Metal-compositor profiles).
   static int in_compositor = -1;
   if (in_compositor < 0) in_compositor = getenv("BGMTL_BB") != NULL;
   if (_status == 4 && !in_compositor) {
      NSMutableSet *written = nil;
      for (BGWork *w in _work)
         if (w->kind == BG_WORK_DRAW || w->kind == BG_WORK_CLEAR)
            for (unsigned i = 0; i < w->color_count; i++) {
               BGMTLTexture *t = (BGMTLTexture *)w->color[i];
               rwa_texture_flush_surface([t rwaTexture]);
               if ([t iosurface]) {
                  if (!written) written = [NSMutableSet set];
                  [written addObject:(id)[t iosurface]];
               }
            }
      // A GPU write does not change an IOSurface's seed, but consumers cache by it: the ES compositor re-uploads a surface it
      // copied only when the seed moved, so a CAMetalLayer drawable (Mercury: three of them in turn) kept showing the frame it
      // held one cycle earlier and animations stepped back and forth. A write lock/unlock is the defined way to bump the seed.
      for (id surf in written) {
         IOSurfaceLock((IOSurfaceRef)surf, 0, NULL);
         IOSurfaceUnlock((IOSurfaceRef)surf, 0, NULL);
      }
   }
   // Chlorophyll debugging (/private/var/tmp/bgmtl.dumpatt with the trace): the textures that "downsample" draws sample, read
   // sparsely (every Nth row and column, so the long side is ~256) into /private/var/tmp/att/src-SEQ-WxH-fmt.raw (BGRA).
   if (bg_trace() && _status == 4 && access("/private/var/tmp/bgmtl.dumpatt", F_OK) == 0) {
      static unsigned sseq;
      NSMutableArray *srcs = [NSMutableArray array];
      for (BGWork *w in _work) {
         if (w->kind != BG_WORK_DRAW || !w->render || !strstr(((BGMTLRenderPipeline *)w->render)->_names, "downsample")) continue;
         for (unsigned i = 0; i < w->texture_count; i++)
            if (w->textures[i] && ![srcs containsObject:w->textures[i]]) [srcs addObject:w->textures[i]];
      }
      for (BGMTLTexture *t in srcs) {
         unsigned wd = (unsigned)[t width], ht = (unsigned)[t height];
         NSUInteger pf = [t pixelFormat];
         if (sseq >= 60 || wd == 0 || ht == 0 || (pf != MTLPixelFormatBGRA8Unorm && pf != MTLPixelFormatBGRA8Unorm_sRGB && pf != MTLPixelFormatRGBA8Unorm)) {
            BG_LOG("  source %p %ux%u fmt %lu not dumped\n", t, wd, ht, (unsigned long)pf);
            continue;
         }
         unsigned step = (wd > ht ? wd : ht) / 256 + 1, ow = (wd + step - 1) / step, oh = (ht + step - 1) / step;
         uint32_t *row = malloc((size_t)wd * 4), *out = malloc((size_t)ow * oh * 4);
         if (row && out) {
            for (unsigned y = 0; y < oh; y++) {
               [t getBytes:row bytesPerRow:wd * 4 fromRegion:MTLRegionMake2D(0, y * step, wd, 1) mipmapLevel:0];
               for (unsigned x = 0; x < ow; x++) out[y * ow + x] = row[x * step];
            }
            char path[128];
            snprintf(path, sizeof(path), "/private/var/tmp/att/src-%04u-%ux%u-of-%ux%u.raw", sseq++, ow, oh, wd, ht);
            FILE *f = fopen(path, "wb");
            if (f) { fwrite(out, 4, (size_t)ow * oh, f); fclose(f); BG_LOG("  source %p %ux%u dumped %s\n", t, wd, ht, path); }
         }
         free(row); free(out);
      }
   }
   if (bg_trace() && _status == 4) {   // what each colour attachment holds now: five texels, centre and quarter points
      NSMutableArray *seen = [NSMutableArray array];
      for (BGWork *w in _work)
         if (w->kind == BG_WORK_DRAW || w->kind == BG_WORK_CLEAR)
            for (unsigned i = 0; i < w->color_count; i++)
               if (w->color[i] && ![seen containsObject:w->color[i]]) [seen addObject:w->color[i]];
      for (BGMTLTexture *t in seen) {
         unsigned wd = (unsigned)[t width], ht = (unsigned)[t height];
         const unsigned pts[5][2] = { { wd / 2, ht / 2 }, { wd / 4, ht / 4 }, { 3 * wd / 4, ht / 4 }, { wd / 4, 3 * ht / 4 }, { 3 * wd / 4, 3 * ht / 4 } };
         char line[256]; size_t n = 0;
         for (unsigned k = 0; k < 5; k++) {
            uint8_t px[4] = { 0 };
            [t getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(pts[k][0], pts[k][1], 1, 1) mipmapLevel:0];
            n += snprintf(line + n, sizeof(line) - n, " (%u,%u,%u,%u)", px[0], px[1], px[2], px[3]);
         }
         BG_LOG("  attachment %p %ux%u:%s\n", t, wd, ht, line);
         // small attachments in full, as raw BGRA files, when /private/var/tmp/bgmtl.dumpatt exists (blur chain debugging; the
         // full-screen ones are skipped: reading 11 MB per pass back through this path rebooted the phone)
         static int dump = -1;
         static unsigned seq;
         if (dump < 0) dump = access("/private/var/tmp/bgmtl.dumpatt", F_OK) == 0;
         if (dump && wd * ht <= 256 * 256 && ([t pixelFormat] == MTLPixelFormatBGRA8Unorm || [t pixelFormat] == MTLPixelFormatBGRA8Unorm_sRGB) && seq < 400) {
            uint8_t *buf = malloc((size_t)wd * ht * 4);
            if (buf) {
               [t getBytes:buf bytesPerRow:wd * 4 fromRegion:MTLRegionMake2D(0, 0, wd, ht) mipmapLevel:0];
               char path[128];
               snprintf(path, sizeof(path), "/private/var/tmp/att/%04u-%ux%u.raw", seq++, wd, ht);
               FILE *f = fopen(path, "wb");
               if (f) { fwrite(buf, 1, (size_t)wd * ht * 4, f); fclose(f); BG_LOG("  dumped %s\n", path); }
               free(buf);
            }
         }
      }
   }
   if (_status == 4 && [_presents count]) {
      // per-present diagnostics: what this command buffer drew, how long it took, and whether the picture it presents is black. Five texels of
      // the last colour attachment (linear 8-bit formats only) are read back; this costs five tiny CPU reads of memory the fence already paid for.
      unsigned ndraw = 0, nclear = 0, npass_att = 0;
      BGMTLTexture *last = nil;
      for (BGWork *w in _work) {
         if (w->kind == BG_WORK_DRAW) { ndraw++; if (w->color_count) last = (BGMTLTexture *)w->color[0]; }
         else if (w->kind == BG_WORK_CLEAR) { nclear++; if (w->color_count) last = (BGMTLTexture *)w->color[0]; }
         npass_att = w->color_count > npass_att ? w->color_count : npass_att;
      }
      double luma = -1;
      unsigned wd = 0, ht = 0;
      if (bg_trace() && last && ([last pixelFormat] == MTLPixelFormatBGRA8Unorm || [last pixelFormat] == MTLPixelFormatRGBA8Unorm ||
                   [last pixelFormat] == MTLPixelFormatBGRA8Unorm_sRGB)) {
         wd = (unsigned)[last width]; ht = (unsigned)[last height];
         const unsigned pts[5][2] = { { wd / 2, ht / 2 }, { wd / 4, ht / 4 }, { 3 * wd / 4, ht / 4 }, { wd / 4, 3 * ht / 4 }, { 3 * wd / 4, 3 * ht / 4 } };
         double sum = 0;
         for (unsigned k = 0; k < 5; k++) {
            uint8_t px[4] = { 0 };
            [last getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(pts[k][0], pts[k][1], 1, 1) mipmapLevel:0];
            sum += (px[0] + px[1] + px[2]) / 3.0;
         }
         luma = sum / 5;
      }
      uint64_t t_end = clock_gettime_nsec_np(CLOCK_MONOTONIC);
      char line[200];
      snprintf(line, sizeof(line), "present: %u presents, %u draws, %u clears, up to %u attachments, %ux%u, mean texel value %.1f, commit %.1f ms, at %.3f s",
               (unsigned)[_presents count], ndraw, nclear, npass_att, wd, ht, luma, (t_end - t_begin) / 1e6, t_end / 1e9);
      bgmtl_note_present(line);
   }
   if (_status == 4)
      bgmtl_note_completed();
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

- (void)waitUntilCompleted { if (_status >= 2) dispatch_group_wait(_done, DISPATCH_TIME_FOREVER); }

- (id)computeCommandEncoder { return [[[BGMTLComputeEncoder alloc] initWithBGCommandBuffer:self] autorelease]; }
- (id)computeCommandEncoderWithDescriptor:(id)d { (void)d; return [self computeCommandEncoder]; }
- (id)computeCommandEncoderWithDispatchType:(NSUInteger)t { (void)t; return [self computeCommandEncoder]; }
// SPI hints CoreAnimation sets on every command buffer (QuartzCore checks for them and raises if absent): which tasks the work is
// accounted to, and the protection class of the content. Neither changes what this GPU does.
- (void)setResponsibleTaskIDs:(const int *)ids count:(NSUInteger)count { (void)ids; (void)count; }
- (void)setProtectionOptions:(uint64_t)options { (void)options; }
- (uint64_t)protectionOptions { return 0; }

- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d
{
   id<MTLTexture> t = d.colorAttachments[0].texture;
   BG_TRACE("render pass: color0 %lux%lu fmt %lu load %lu store %lu\n", (unsigned long)t.width, (unsigned long)t.height,
            (unsigned long)t.pixelFormat, (unsigned long)d.colorAttachments[0].loadAction, (unsigned long)d.colorAttachments[0].storeAction);
   if (bg_trace()) {
      for (unsigned i = 1; i < 8; i++)
         if (d.colorAttachments[i].texture)
            BG_LOG("  color%u %lux%lu fmt %lu load %lu store %lu\n", i, (unsigned long)d.colorAttachments[i].texture.width,
                   (unsigned long)d.colorAttachments[i].texture.height, (unsigned long)d.colorAttachments[i].texture.pixelFormat,
                   (unsigned long)d.colorAttachments[i].loadAction, (unsigned long)d.colorAttachments[i].storeAction);
      if (d.depthAttachment.texture) BG_LOG("  depth fmt %lu load %lu\n", (unsigned long)d.depthAttachment.texture.pixelFormat, (unsigned long)d.depthAttachment.loadAction);
      if (d.stencilAttachment.texture) BG_LOG("  stencil fmt %lu load %lu clear %u\n", (unsigned long)d.stencilAttachment.texture.pixelFormat,
                                             (unsigned long)d.stencilAttachment.loadAction, d.stencilAttachment.clearStencil);
   }
   return [[[BGMTLRenderEncoder alloc] initWithBGCommandBuffer:self descriptor:d] autorelease];
}
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
- (void)copyFromTexture:(id)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size
             toTexture:(id)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg
{
   BGWork *w = [[[BGWork alloc] init] autorelease];
   w->kind = BG_WORK_TEXCOPY; w->src = [src retain]; w->dst = [dst retain];
   w->t_sslice = ss; w->t_slevel = sl; w->t_dslice = ds; w->t_dlevel = dl;
   w->t_sorg[0] = so.x; w->t_sorg[1] = so.y; w->t_sorg[2] = so.z; w->t_dorg[0] = dorg.x; w->t_dorg[1] = dorg.y; w->t_dorg[2] = dorg.z;
   w->t_size[0] = size.width; w->t_size[1] = size.height; w->t_size[2] = size.depth;
   [_cb bgRecord:w];
}
- (void)copyFromTexture:(id)src toTexture:(id)dst
{
   NSUInteger levels = [(id<MTLTexture>)src mipmapLevelCount], slices = [(id<MTLTexture>)src arrayLength];
   if (slices < 1) slices = 1;
   for (NSUInteger l = 0; l < levels; l++) {
      MTLSize sz = MTLSizeMake(MAX(1, [(id<MTLTexture>)src width] >> l), MAX(1, [(id<MTLTexture>)src height] >> l), MAX(1, [(id<MTLTexture>)src depth] >> l));
      for (NSUInteger s = 0; s < slices; s++)
         [self copyFromTexture:src sourceSlice:s sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:sz
                     toTexture:dst destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
   }
}
- (void)copyFromBuffer:(id)buf sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)bpr sourceBytesPerImage:(NSUInteger)bpi sourceSize:(MTLSize)size
             toTexture:(id)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg
{
   BGWork *w = [[[BGWork alloc] init] autorelease];
   w->kind = BG_WORK_BUF2TEX; w->src = [buf retain]; w->dst = [dst retain]; w->src_off = so; w->t_bpr = bpr; w->t_bpi = bpi;
   w->t_dslice = ds; w->t_dlevel = dl; w->t_dorg[0] = dorg.x; w->t_dorg[1] = dorg.y; w->t_dorg[2] = dorg.z;
   w->t_size[0] = size.width; w->t_size[1] = size.height; w->t_size[2] = size.depth;
   [_cb bgRecord:w];
}
- (void)copyFromBuffer:(id)buf sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)bpr sourceBytesPerImage:(NSUInteger)bpi sourceSize:(MTLSize)size
             toTexture:(id)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg options:(NSUInteger)opt
{
   (void)opt;
   [self copyFromBuffer:buf sourceOffset:so sourceBytesPerRow:bpr sourceBytesPerImage:bpi sourceSize:size toTexture:dst destinationSlice:ds destinationLevel:dl destinationOrigin:dorg];
}
- (void)copyFromTexture:(id)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size
               toBuffer:(id)buf destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)bpr destinationBytesPerImage:(NSUInteger)bpi
{
   BGWork *w = [[[BGWork alloc] init] autorelease];
   w->kind = BG_WORK_TEX2BUF; w->src = [src retain]; w->dst = [buf retain]; w->dst_off = doff; w->t_bpr = bpr; w->t_bpi = bpi;
   w->t_sslice = ss; w->t_slevel = sl; w->t_sorg[0] = so.x; w->t_sorg[1] = so.y; w->t_sorg[2] = so.z;
   w->t_size[0] = size.width; w->t_size[1] = size.height; w->t_size[2] = size.depth;
   [_cb bgRecord:w];
}
- (void)copyFromTexture:(id)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size
               toBuffer:(id)buf destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)bpr destinationBytesPerImage:(NSUInteger)bpi options:(NSUInteger)opt
{
   (void)opt;
   [self copyFromTexture:src sourceSlice:ss sourceLevel:sl sourceOrigin:so sourceSize:size toBuffer:buf destinationOffset:doff destinationBytesPerRow:bpr destinationBytesPerImage:bpi];
}
// shared memory: nothing to flush
- (void)synchronizeResource:(id)r { (void)r; }
- (void)synchronizeTexture:(id)t slice:(NSUInteger)s level:(NSUInteger)l { (void)t; (void)s; (void)l; }
- (void)generateMipmapsForTexture:(id)t
{
   BGWork *w = [[[BGWork alloc] init] autorelease];
   w->kind = BG_WORK_MIPMAPS; w->dst = [t retain];
   [_cb bgRecord:w];
}
- (void)optimizeContentsForGPUAccess:(id)t { (void)t; }
- (void)optimizeContentsForCPUAccess:(id)t { (void)t; }
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
   BG_TRACE("texture %lux%lu fmt %lu type %lu usage %lu storage %lu %s\n", (unsigned long)d.width, (unsigned long)d.height,
            (unsigned long)d.pixelFormat, (unsigned long)d.textureType, (unsigned long)d.usage, (unsigned long)d.storageMode,
            surface ? "iosurface" : "own memory");
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
      bg_lock();
      _tex = rwa_texture_from_surface([device rwa], &_shape, (int)IOSurfaceGetID((IOSurfaceRef)surface), 0, 0, why, sizeof(why));
      bg_unlock();
      _surface = CFRetain(surface);
      _plane = plane;
   } else {
      bg_lock();
      _tex = rwa_texture_create([device rwa], &_shape, why, sizeof(why));
      bg_unlock();
   }
   if (!_tex) { BG_LOG("texture refused: %s\n", why); [self release]; return nil; }
   _owner = device;
   return self;
}
- (void)dealloc
{
   bg_lock(); if (_tex) rwa_texture_destroy(_tex); bg_unlock();
   if (_surface) CFRelease(_surface);
   [_linSrc release];
   if (_ncDealloc) { _ncDealloc((void *)_ncBytes, _ncLength); Block_release(_ncDealloc); }
   [super dealloc];
}
- (void *)iosurface { return (void *)_surface; }
- (NSUInteger)iosurfacePlane { return _plane; }
- (BOOL)isDrawable { return _surface != NULL; }
// A linear texture over a buffer reads the buffer's current bytes each time it is handed to the GPU (at commit), so CPU
// writes into the buffer after the texture was made still show, as with Apple's aliasing.
- (struct rwa_texture *)rwaTextureSampled
{
   bg_lock();
   struct rwa_texture *t = [self rwaTextureSampledLocked];
   bg_unlock();
   return t;
}

- (struct rwa_texture *)rwaTextureSampledLocked
{
   // An IOSurface another process draws with the CPU (SpringBoard's status bar, the volume HUD): its new pixels may still sit in
   // CPU caches. The surface's seed moves at every write unlock, so the cache is cleaned whenever the seed differs from the one
   // last cleaned at (per surface ID: QuartzCore makes new texture objects for the same surface all the time). The import cache
   // (one kernel clean per surface, ever) left those layers stale or missing until this.
   if (_surface && _tex) {
      static NSMutableDictionary *seeds;
      static os_unfair_lock lk = OS_UNFAIR_LOCK_INIT;
      NSNumber *key = @(IOSurfaceGetID((IOSurfaceRef)_surface));
      uint32_t seed = IOSurfaceGetSeed((IOSurfaceRef)_surface);
      os_unfair_lock_lock(&lk);
      if (!seeds) seeds = [[NSMutableDictionary alloc] init];
      NSNumber *was = seeds[key];
      BOOL changed = !was || [was unsignedIntValue] != seed;
      if (changed) seeds[key] = @(seed);
      if ([seeds count] > 4096) [seeds removeAllObjects];
      os_unfair_lock_unlock(&lk);
      if (changed) rwa_texture_flush_surface(_tex);
   }
   return [self rwaTexture];
}

- (struct rwa_texture *)rwaTexture
{
   if (_ncBytes && _tex) {
      bg_lock();
      char why[256] = { 0 };
      const unsigned o[3] = { 0, 0, 0 }, sz[3] = { _shape.width, _shape.height, 1 };
      if (rwa_texture_write(_tex, 0, 0, o, sz, (const uint8_t *)_ncBytes, (unsigned)(_ncLength / (_shape.height ? _shape.height : 1)),
                            why, sizeof(why)) != 0)
         BG_LOG("no-copy texture refresh: %s\n", why);
      bg_unlock();
   }
   if (_linSrc && _tex) {
      bg_lock();
      char why[256] = { 0 };
      const unsigned o[3] = { 0, 0, 0 }, sz[3] = { _shape.width, _shape.height, 1 };
      if (rwa_texture_write(_tex, 0, 0, o, sz, (const uint8_t *)[(BGMTLBuffer *)_linSrc contents] + _linOff, (unsigned)_linBpr,
                            why, sizeof(why)) != 0)
         BG_LOG("linear texture refresh: %s\n", why);
      bg_unlock();
   }
   return _tex;
}
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
   BG_TRACE("replaceRegion %lu,%lu %lux%lu level %lu bpr %lu\n", (unsigned long)r.origin.x, (unsigned long)r.origin.y,
            (unsigned long)r.size.width, (unsigned long)r.size.height, (unsigned long)level, (unsigned long)bpr);
   if (bg_trace() && bytes && r.size.height > 1) {
      const uint8_t *a = (const uint8_t *)bytes, *z = a + bpr * (r.size.height - 1);
      BG_LOG("  first row px0 %u %u %u %u, last row px0 %u %u %u %u\n", a[0], a[1], a[2], a[3], z[0], z[1], z[2], z[3]);
   }
   (void)bpi;
   unsigned o[3] = { (unsigned)r.origin.x, (unsigned)r.origin.y, (unsigned)r.origin.z };
   unsigned sz[3] = { (unsigned)r.size.width, (unsigned)r.size.height, (unsigned)r.size.depth };
   char why[256] = { 0 };
   bg_lock();
   if (rwa_texture_write(_tex, (unsigned)level, (unsigned)slice, o, sz, bytes, bpr, why, sizeof(why)) != 0) BG_LOG("replaceRegion: %s\n", why);
   bg_unlock();
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
   bg_lock();
   if (rwa_texture_read(_tex, (unsigned)level, (unsigned)slice, o, sz, bytes, bpr, why, sizeof(why)) != 0) BG_LOG("getBytes: %s\n", why);
   bg_unlock();
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
   bg_lock();
   _smp = rwa_sampler_create([device rwa], &st, why, sizeof(why));
   bg_unlock();
   if (!_smp) { BG_LOG("sampler refused: %s\n", why); [self release]; return nil; }
   _owner = device;
   return self;
}
- (void)dealloc { bg_lock(); if (_smp) rwa_sampler_destroy(_smp); bg_unlock(); [super dealloc]; }
- (struct rwa_sampler *)rwaSampler { return _smp; }
- (id)device { return _owner; }
@end


@implementation BGMTLDepthStencil
+ (void)load { ensure_protocol(self, "MTLDepthStencilState"); }
- (instancetype)initWithBGDevice:(BGMTLDevice *)device descriptor:(MTLDepthStencilDescriptor *)d
{
   self = [super initWithDevice:device depthStencilDescriptor:d];
   if (!self) return nil;
   struct rwa_depth_stencil_state st;
   memset(&st, 0, sizeof(st));
   st.depth_compare_function = (unsigned)[d depthCompareFunction];
   st.depth_write_enabled = [d isDepthWriteEnabled];
   MTLStencilDescriptor *f = [d frontFaceStencil], *b = [d backFaceStencil];
   st.front = (struct rwa_stencil_face){ (unsigned)[f stencilCompareFunction], (unsigned)[f stencilFailureOperation], (unsigned)[f depthFailureOperation],
                                         (unsigned)[f depthStencilPassOperation], (unsigned)[f readMask], (unsigned)[f writeMask] };
   st.back = (struct rwa_stencil_face){ (unsigned)[b stencilCompareFunction], (unsigned)[b stencilFailureOperation], (unsigned)[b depthFailureOperation],
                                        (unsigned)[b depthStencilPassOperation], (unsigned)[b readMask], (unsigned)[b writeMask] };
   char why[256] = { 0 };
   bg_lock();
   _ds = rwa_depth_stencil_create([device rwa], &st, why, sizeof(why));
   bg_unlock();
   if (!_ds) { BG_LOG("depth/stencil state refused: %s\n", why); [self release]; return nil; }
   _owner = device;
   _readsDepth = st.depth_compare_function != MTLCompareFunctionAlways;
   _writesDepth = st.depth_write_enabled;
   _readsStencil = f.stencilCompareFunction != MTLCompareFunctionAlways || b.stencilCompareFunction != MTLCompareFunctionAlways;
   _writesStencil = f.writeMask || b.writeMask;
   return self;
}
- (void)dealloc { bg_lock(); if (_ds) rwa_depth_stencil_destroy(_ds); bg_unlock(); [super dealloc]; }
- (struct rwa_depth_stencil *)rwaState { return _ds; }
- (id)device { return _owner; }
- (BOOL)readsDepth { return _readsDepth; }
- (BOOL)writesDepth { return _writesDepth; }
- (BOOL)readsStencil { return _readsStencil; }
- (BOOL)writesStencil { return _writesStencil; }
@end

@implementation BGMTLRenderPipeline
+ (void)load { ensure_protocol(self, "MTLRenderPipelineState"); }
- (void)dealloc { bg_lock(); if (_render) rwa_render_destroy(_render); bg_unlock(); [super dealloc]; }
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
      if ([a loadAction] == MTLLoadActionClear) {
         MTLClearColor c = [a clearColor];
         _clear_mask |= 1u << i;
         _clear_vals[i][0] = (float)c.red; _clear_vals[i][1] = (float)c.green; _clear_vals[i][2] = (float)c.blue; _clear_vals[i][3] = (float)c.alpha;
      } else if ([a loadAction] == MTLLoadActionDontCare && ![(BGMTLTexture *)[a texture] iosurface]) {
         // DontCare promises undefined contents, and CoreAnimation then blends into them: its rounded-corner masks are built in
         // a DontCare attachment whose untouched texels are meant to be zero (Apple GPUs start tiles cleared). Here they kept
         // whatever the memory held: dark wedges and specks at widget and dock corners. Private textures only (masks,
         // intermediates); IOSurface framebuffers are fully redrawn and a full-screen clear would cost every frame.
         _clear_mask |= 1u << i;
         _clear_vals[i][0] = _clear_vals[i][1] = _clear_vals[i][2] = _clear_vals[i][3] = 0.0f;
      }
   }
   MTLRenderPassDepthAttachmentDescriptor *da = [d depthAttachment];
   if (da && [da texture]) {
      _depth = [[da texture] retain];
      if ([da loadAction] == MTLLoadActionClear) { _clear_depth_v = (float)[da clearDepth]; _clear_depth_pending = YES; }
   }
   MTLRenderPassStencilAttachmentDescriptor *sa = [d stencilAttachment];
   if (sa && [sa texture]) {
      if (!_depth) _depth = [[sa texture] retain];
      if ([sa loadAction] == MTLLoadActionClear) { _clear_stencil_v = (unsigned)[sa clearStencil]; _clear_stencil_pending = YES; }
   }
   // The pass's clears happen HERE, at the start of the pass, as one piece of work of their own -- not inside the first draw. A pass that
   // draws nothing still clears; attachments clear to their own colours; and an attachment that is loaded is never touched by another's clear.
   if (_clear_mask || _clear_depth_pending || _clear_stencil_pending) {
      BGWork *w = [[[BGWork alloc] init] autorelease];
      w->kind = BG_WORK_CLEAR;
      w->color_count = _ncolor;
      for (unsigned i = 0; i < _ncolor; i++) w->color[i] = [_color[i] retain];
      w->clear_mask = _clear_mask;
      memcpy(w->clear_vals, _clear_vals, sizeof(_clear_vals));
      w->depth = [_depth retain];
      if (_clear_depth_pending) { w->clear_depth_set = YES; w->clear_depth = _clear_depth_v; }
      if (_clear_stencil_pending) { w->clear_stencil_set = YES; w->clear_stencil = _clear_stencil_v; }
      _clear_depth_pending = _clear_stencil_pending = NO;
      _clear_mask = 0;
      [_cb bgRecord:w];
   }
   return self;
}
- (void)dealloc { for (unsigned i = 0; i < 8; i++) [_color[i] release]; [_scratch release]; [_depth release]; [_depth_state release]; [super dealloc]; }
- (id)device { return [_cb device]; }
- (void)setRenderPipelineState:(id)s { _pipeline = s; BG_TRACE("setPipeline %s\n", ((BGMTLRenderPipeline *)s)->_names); }
- (void)setVertexBuffer:(id)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{ BG_TRACE("setVertexBuffer %p offset %lu index %lu\n", b, (unsigned long)o, (unsigned long)i); if (i < BG_MAX_BINDINGS) { _vbuf[i] = b; _voff[i] = o; if (i + 1 > _vhigh) _vhigh = (unsigned)i + 1; } }
- (void)setFragmentBuffer:(id)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{ if (i < BG_MAX_BINDINGS) { _fbuf[i] = b; _foff[i] = o; if (i + 1 > _fhigh) _fhigh = (unsigned)i + 1; } }
// CoreAnimation binds a buffer once per pass and then only moves the offset between draws
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { if (i < BG_MAX_BINDINGS) _voff[i] = o; }
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { if (i < BG_MAX_BINDINGS) _foff[i] = o; }
- (void)setVertexBuffers:(const id *)b offsets:(const NSUInteger *)o withRange:(NSRange)r
{ for (NSUInteger k = 0; k < r.length; k++) [self setVertexBuffer:b[k] offset:o[k] atIndex:r.location + k]; }
- (void)setFragmentBuffers:(const id *)b offsets:(const NSUInteger *)o withRange:(NSRange)r
{ for (NSUInteger k = 0; k < r.length; k++) [self setFragmentBuffer:b[k] offset:o[k] atIndex:r.location + k]; }
- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)l atIndex:(NSUInteger)i
{
   BG_TRACE("setVertexBytes length %lu index %lu\n", (unsigned long)l, (unsigned long)i);
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
- (void)setViewport:(MTLViewport)v
{
   BG_TRACE("setViewport %g %g %g %g z %g..%g\n", v.originX, v.originY, v.width, v.height, v.znear, v.zfar);
   _range[0] = (float)v.znear; _range[1] = (float)v.zfar; _have_range = YES;
}
- (void)setDepthStencilState:(id)state { BG_TRACE("setDepthStencilState %p\n", state); [_depth_state release]; _depth_state = [state retain]; }
- (void)setStencilReferenceValue:(uint32_t)v { BG_TRACE("setStencilReference %u\n", v); _stencil_ref[0] = _stencil_ref[1] = v; }
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b { _stencil_ref[0] = f; _stencil_ref[1] = b; }
- (void)setDepthBias:(float)bias slopeScale:(float)slope clamp:(float)clamp { (void)bias; (void)slope; (void)clamp; }
- (void)setDepthClipMode:(NSUInteger)m { (void)m; }
- (void)setScissorRect:(MTLScissorRect)r { _scissor[0] = (unsigned)r.x; _scissor[1] = (unsigned)r.y; _scissor[2] = (unsigned)r.width; _scissor[3] = (unsigned)r.height; _have_scissor = YES; BG_TRACE("setScissor %lu %lu %lu %lu\n", (unsigned long)r.x, (unsigned long)r.y, (unsigned long)r.width, (unsigned long)r.height); }
- (void)setCullMode:(NSUInteger)m { BG_TRACE("setCullMode %lu\n", (unsigned long)m); }
- (void)setFrontFacingWinding:(NSUInteger)w { (void)w; }
- (void)setTriangleFillMode:(NSUInteger)m { (void)m; }

- (void)bgRecordDraw:(NSUInteger)prim start:(NSUInteger)start count:(NSUInteger)count instances:(NSUInteger)inst
        indexBuffer:(id)ib indexType:(NSUInteger)it indexOffset:(NSUInteger)io baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi
{
   if (!_pipeline) { BG_LOG("draw with no pipeline\n"); return; }
   if (bg_trace()) {
      BG_LOG("draw: prim %lu start %lu count %lu inst %lu index %s type %lu off %lu\n", (unsigned long)prim, (unsigned long)start,
             (unsigned long)count, (unsigned long)inst, ib ? "yes" : "no", (unsigned long)it, (unsigned long)io);
      if (ib && count <= 64 && _vbuf[1]) {      // the vertices an indexed draw uses, slot 1 as CoreAnimation lays them out
         const uint8_t *base = (const uint8_t *)[(BGMTLBuffer *)_vbuf[1] contents] + _voff[1];
         const uint16_t *ix = (const uint16_t *)((const uint8_t *)[(BGMTLBuffer *)ib contents] + io);
         unsigned maxi = 0;
         char line[512]; size_t n = 0;
         for (unsigned k = 0; k < count && n < sizeof(line) - 8; k++) { n += snprintf(line + n, sizeof(line) - n, "%u ", ix[k]); if (ix[k] > maxi) maxi = ix[k]; }
         BG_LOG("  indices: %s\n", line);
         for (unsigned v = 0; v <= maxi && v < 16; v++) {
            const float *f = (const float *)(base + 48 * v);
            const __fp16 *h = (const __fp16 *)(base + 48 * v + 32);
            BG_LOG("  v%u: pos %g %g %g %g  a1 %g %g  a2 %g %g  col %g %g %g %g\n", v, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7],
                   (float)h[0], (float)h[1], (float)h[2], (float)h[3]);
         }
      }
      for (unsigned i = 0; i < _vhigh; i++) {
         if (!_vbuf[i]) continue;
         const float *f = (const float *)((const uint8_t *)[(BGMTLBuffer *)_vbuf[i] contents] + _voff[i]);
         BG_LOG("  vbuf[%u] len %lu off %lu: %g %g %g %g | %g %g %g %g | %g %g %g %g | %g %g %g %g\n", i,
                (unsigned long)[(BGMTLBuffer *)_vbuf[i] length], (unsigned long)_voff[i], f[0], f[1], f[2], f[3], f[4], f[5],
                f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15]);
      }
   }
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
   // Metal reads zeros from a texture slot nothing was bound to; this library asks for a texture, so give it one that is zero
   for (unsigned i = 0; i < _pipeline->_ndecls; i++) {
      unsigned idx = _pipeline->_decls[i].index;
      if (idx >= BG_MAX_TEX || w->textures[idx]) continue;
      w->textures[idx] = [[(BGMTLDevice *)[_cb device] bgNullTextureForType:_pipeline->_decls[i].type_known ? _pipeline->_decls[i].type : 2
                                                                    element:_pipeline->_decls[i].element] retain];
      if (idx + 1 > w->texture_count) w->texture_count = idx + 1;
      BG_LOG("draw: texture slot %u was not bound; a zero texture stands in\n", idx);
   }
   w->color_count = _ncolor;
   for (unsigned i = 0; i < _ncolor; i++) w->color[i] = [_color[i] retain];
   w->depth = [_depth retain]; w->depth_state = [_depth_state retain];
   if (_clear_depth_pending) { w->clear_depth_set = YES; w->clear_depth = _clear_depth_v; _clear_depth_pending = NO; }
   if (_clear_stencil_pending) { w->clear_stencil_set = YES; w->clear_stencil = _clear_stencil_v; _clear_stencil_pending = NO; }
   w->stencil_ref[0] = _stencil_ref[0]; w->stencil_ref[1] = _stencil_ref[1];
   if (_have_scissor) { w->have_scissor = YES; memcpy(w->scissor, _scissor, sizeof(_scissor)); }
   if (_have_range) { w->have_range = YES; w->depth_range[0] = _range[0]; w->depth_range[1] = _range[1]; }
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
   BGMTLDevice *d = [[BGMTLDevice alloc] initWithAcceleratorPort:0];
   if (d && !getenv("RWA_SOFTWARE") && ![d rwa]) {   // a device that cannot reach the GPU (sandbox, no service) is not a device
      BG_LOG("no GPU behind the device: none is made\n");
      [d release];
      return nil;
   }
   return d;
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
