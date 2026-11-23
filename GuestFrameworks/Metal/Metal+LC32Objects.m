#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <LC32/LC32.h>

#include <pthread.h>
#include <stdint.h>
#include <string.h>

#include <LC32MetalBridge.h>

/*
 * ARM32 side of the Metal bridge (host side: HostFrameworks/Metal/Metal.mm).
 *
 * Native Metal objects (devices, queues, buffers, encoders ...) belong to
 * private classes that implement public protocols, so no generated shim
 * exists for them. The host gives their guest proxies one of the
 * LC32MTL... classes below (LC32MetalGuestProxyClass). Rarely used methods
 * go through the generic selector bridge; render-encoder state and draws
 * use the host Metal dispatcher, which runs them without halting the JIT.
 *
 * The public descriptor classes do have generated shims, but their property
 * accessors live in private ...Internal subclasses on iOS, so the generated
 * classes lack them; the categories at the end add them.
 *
 * Integers that are NSUInteger in Metal are 32-bit here and 64-bit on the
 * host. The generic bridge widens each argument slot using the native method
 * encoding, which is why every argument below is passed as a 64-bit value.
 */

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
#pragma clang diagnostic ignored "-Wmismatched-return-types"
#pragma clang diagnostic ignored "-Wmismatched-parameter-types"
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"

#define LC32MTL_SEL(selectorName, returnsStruct) ({ \
    static uint64_t lc32SelectorCache __attribute__((aligned(8))); \
    LC32CachedHostSelector(&lc32SelectorCache, @selector(selectorName), \
        (returnsStruct)); })

#define LC32MTL_INVOKE(selectorName, ...) \
    LC32InvokeHostSelector(self.host_self, LC32MTL_SEL(selectorName, NO), \
        ##__VA_ARGS__, (uint64_t)0)

#define LC32MTL_INVOKE_OBJECT(selectorName, ...) \
    LC32InvokeHostObjectSelector(self.host_self, \
        LC32MTL_SEL(selectorName, NO), ##__VA_ARGS__, (uint64_t)0)

#define LC32MTL_HOST(object) ((uint64_t)[(id)(object) host_self])

/* Property accessor generators. Getter and setter are separate macro
 * arguments because Metal uses is... getters for its BOOL properties.
 * They go through the host Metal dispatcher's inline accessor calls (no JIT
 * halt); the object forms fall back to the generic bridge when the host
 * asks for it (LC32MetalInlineFallback). */
#define LC32MTL_GET_INTEGER(getter) \
    LC32MTL_CALL(LC32MetalOpGetInteger, LC32MTL_OBJ(self), \
        LC32MTL_SEL(getter, NO))

#define LC32MTL_SET_INTEGER(setter, value) \
    LC32MTL_CALL(LC32MetalOpSetInteger, LC32MTL_OBJ(self), \
        LC32MTL_SEL(setter, NO), (uint64_t)(value))

#define LC32MTL_UINT_PROPERTY(getter, setter) \
- (NSUInteger)getter { \
    return (NSUInteger)LC32MTL_GET_INTEGER(getter); \
} \
- (void)setter(NSUInteger)value { \
    LC32MTL_SET_INTEGER(setter, value); \
}

#define LC32MTL_UINT32_PROPERTY(getter, setter) \
- (uint32_t)getter { \
    return (uint32_t)LC32MTL_GET_INTEGER(getter); \
} \
- (void)setter(uint32_t)value { \
    LC32MTL_SET_INTEGER(setter, value); \
}

#define LC32MTL_BOOL_PROPERTY(getter, setter) \
- (BOOL)getter { \
    return (LC32MTL_GET_INTEGER(getter) & 0xff) != 0; \
} \
- (void)setter(BOOL)value { \
    LC32MTL_SET_INTEGER(setter, value ? 1 : 0); \
}

#define LC32MTL_FLOAT_PROPERTY(getter, setter) \
- (float)getter { \
    return (float)LC32HostFloatingResult(LC32MTL_INVOKE(getter)); \
} \
- (void)setter(float)value { \
    (void)LC32MTL_INVOKE(setter, (double)value); \
}

#define LC32MTL_DOUBLE_PROPERTY(getter, setter) \
- (double)getter { \
    return LC32HostFloatingResult(LC32MTL_INVOKE(getter)); \
} \
- (void)setter(double)value { \
    (void)LC32MTL_INVOKE(setter, (double)value); \
}

/* Only for side-effect-free getters: a fallback sends the selector again. */
#define LC32MTL_OBJECT_GETTER(getter) \
- (id)getter { \
    const uint32_t inlineResult = LC32MTL_CALL(LC32MetalOpGetObject, \
        LC32MTL_OBJ(self), LC32MTL_SEL(getter, NO)); \
    if(inlineResult != LC32MetalInlineFallback) \
        return (id)(uintptr_t)inlineResult; \
    return LC32ReturnBorrowedGuestObject(LC32MTL_INVOKE_OBJECT(getter)); \
}

/* Getters that make a new object each time (command buffers, encoders). */
#define LC32MTL_OBJECT_FACTORY(getter) \
- (id)getter { \
    return LC32ReturnBorrowedGuestObject(LC32MTL_INVOKE_OBJECT(getter)); \
}

#define LC32MTL_OBJECT_PROPERTY(getter, setter) \
LC32MTL_OBJECT_GETTER(getter) \
- (void)setter(id)value { \
    if(LC32MTL_CALL(LC32MetalOpSetObject, LC32MTL_OBJ(self), \
            LC32MTL_SEL(setter, NO), LC32MTL_OBJ(value)) == \
            LC32MetalInlineFallback) \
        (void)LC32MTL_INVOKE(setter, LC32MTL_HOST(value)); \
}

/* The descriptor classes' -init lives in their private subclasses too; the
 * guest NSObject -init would leave the native object uninitialized. */
#define LC32MTL_INIT \
- (id)init { \
    const uint64_t hostResult = LC32InvokeHostSelector(self.host_self, \
        LC32MTL_SEL(init, NO), (uint64_t)0); \
    return LC32AdoptHostInitializerResult(self, hostResult); \
}

/* ---- Host Metal dispatcher ---------------------------------------------- */

static uint64_t LC32MetalDispatchAddress;
static uint64_t LC32MetalInlineDispatchAddress;
static pthread_once_t LC32MetalDispatchOnce = PTHREAD_ONCE_INIT;

static void LC32MetalResolveDispatch(void) {
    LC32MetalDispatchAddress = LC32Dlsym("LC32_Metal_Dispatch", YES);
    LC32MetalInlineDispatchAddress =
        LC32Dlsym("LC32_Metal_DispatchInline", YES);
}

static uint32_t LC32MetalCallSlots(LC32MetalOpcode opcode,
                                   const uint64_t *slots, uint32_t count) {
    pthread_once(&LC32MetalDispatchOnce, LC32MetalResolveDispatch);
    const uint64_t target = opcode >= LC32MetalOpFirstInline
        ? LC32MetalInlineDispatchAddress : LC32MetalDispatchAddress;
    if(!target || count > LC32MetalMaxSlots) return 0;
    LC32MetalCall call;
    call.version = LC32MetalABIVersion;
    call.slotCount = count;
    memcpy(call.slots, slots, count * sizeof(*slots));
    return LC32InvokeHostCRet32(target, (uint32_t)opcode,
        (uint32_t)(uintptr_t)&call);
}

#define LC32MTL_CALL(opcode, ...) \
    LC32MetalCallSlots((opcode), (const uint64_t[]){__VA_ARGS__}, \
        (uint32_t)(sizeof((const uint64_t[]){__VA_ARGS__}) / \
            sizeof(uint64_t)))

/* Guest object pointer, resolved on the host. */
#define LC32MTL_OBJ(object) ((uint64_t)(uint32_t)(uintptr_t)(object))
#define LC32MTL_U(value) ((uint64_t)(value))

static inline uint64_t LC32MetalFloatBits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline uint64_t LC32MetalDoubleBits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

#define LC32MTL_REGION(region) \
    LC32MTL_U((region).origin.x), LC32MTL_U((region).origin.y), \
    LC32MTL_U((region).origin.z), LC32MTL_U((region).size.width), \
    LC32MTL_U((region).size.height), LC32MTL_U((region).size.depth)

#define LC32MTL_ORIGIN(origin) \
    LC32MTL_U((origin).x), LC32MTL_U((origin).y), LC32MTL_U((origin).z)

#define LC32MTL_SIZE(size) \
    LC32MTL_U((size).width), LC32MTL_U((size).height), \
    LC32MTL_U((size).depth)

/* ---- Protocol proxies ----------------------------------------------------- */

@interface LC32MTLObject : NSObject
@end

@implementation LC32MTLObject
LC32MTL_OBJECT_PROPERTY(label, setLabel:)
LC32MTL_OBJECT_GETTER(device)
@end

@interface LC32MTLDevice : LC32MTLObject <MTLDevice>
@end

@implementation LC32MTLDevice
LC32MTL_OBJECT_GETTER(name)

- (BOOL)supportsFeatureSet:(MTLFeatureSet)featureSet {
    static int hostResponds = -1;
    if(hostResponds < 0) {
        hostResponds = (LC32MTL_INVOKE(respondsToSelector:,
            LC32GetHostSelector(@selector(supportsFeatureSet:))) & 0xff)
            ? 1 : 0;
    }
    /* Every device that runs this host has at least the iOS 8/9 GPU
     * families (A8 and later). */
    if(!hostResponds) return featureSet <= MTLFeatureSet_iOS_GPUFamily2_v2;
    return (LC32MTL_INVOKE(supportsFeatureSet:, (uint64_t)featureSet) &
        0xff) != 0;
}

- (BOOL)supportsTextureSampleCount:(NSUInteger)sampleCount {
    return (LC32MTL_INVOKE(supportsTextureSampleCount:,
        (uint64_t)sampleCount) & 0xff) != 0;
}

- (id)newCommandQueue {
    return LC32HostToGuestOwnedObject(LC32MTL_INVOKE(newCommandQueue));
}

- (id)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count {
    return LC32HostToGuestOwnedObject(LC32MTL_INVOKE(
        newCommandQueueWithMaxCommandBufferCount:, (uint64_t)count));
}

- (id)newBufferWithLength:(NSUInteger)length
                  options:(MTLResourceOptions)options {
    return LC32HostToGuestOwnedObject(LC32MTL_INVOKE(
        newBufferWithLength:options:, (uint64_t)length, (uint64_t)options));
}

- (id)newBufferWithBytes:(const void *)pointer
                  length:(NSUInteger)length
                 options:(MTLResourceOptions)options {
    /* The halting dispatcher returns the +1 guest proxy itself. */
    return (id)(uintptr_t)LC32MTL_CALL(LC32MetalOpDeviceNewBufferWithBytes,
        LC32MTL_OBJ(self), LC32MTL_OBJ(pointer), LC32MTL_U(length),
        LC32MTL_U(options));
}

- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor {
    /* The host adapts the descriptor to current Metal (storage, usage);
     * the halting dispatcher returns the +1 guest proxy itself. */
    if(!descriptor) return nil;
    (void)[descriptor host_self];
    return (id)(uintptr_t)LC32MTL_CALL(LC32MetalOpDeviceNewTexture,
        LC32MTL_OBJ(self), LC32MTL_OBJ(descriptor));
}

- (id)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)descriptor {
    return LC32HostToGuestOwnedObject(LC32MTL_INVOKE(
        newSamplerStateWithDescriptor:, LC32MTL_HOST(descriptor)));
}

- (id)newDepthStencilStateWithDescriptor:
        (MTLDepthStencilDescriptor *)descriptor {
    return LC32HostToGuestOwnedObject(LC32MTL_INVOKE(
        newDepthStencilStateWithDescriptor:, LC32MTL_HOST(descriptor)));
}

- (id)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    if(error) *error = nil;
    if(!data) return nil;
    /* dispatch_data_t is a guest libdispatch object. Flatten it and let the
     * host build a native dispatch_data_t from the bytes. */
    const void *bytes = NULL;
    size_t length = 0;
    dispatch_data_t map = dispatch_data_create_map(data, &bytes, &length);
    if(!map) return nil;
    NSError *guestError = nil;
    id library = (id)(uintptr_t)LC32MTL_CALL(
        LC32MetalOpDeviceNewLibraryWithData, LC32MTL_OBJ(self),
        LC32MTL_OBJ(bytes), LC32MTL_U(length), LC32MTL_OBJ(&guestError));
    dispatch_release(map);
    if(error) *error = guestError;
    return library;
}

- (id)newLibraryWithFile:(NSString *)path error:(NSError **)error {
    uint64_t hostError = 0;
    const uint64_t result = LC32MTL_INVOKE(newLibraryWithFile:error:,
        LC32MTL_HOST(path), LC32HostIndirectArgument(error ? &hostError : NULL));
    if(error) *error = hostError ? LC32HostToGuestObject(hostError) : nil;
    return LC32HostToGuestOwnedObject(result);
}

- (id)newLibraryWithSource:(NSString *)source
                   options:(MTLCompileOptions *)options
                     error:(NSError **)error {
    uint64_t hostError = 0;
    const uint64_t result = LC32MTL_INVOKE(
        newLibraryWithSource:options:error:, LC32MTL_HOST(source),
        LC32MTL_HOST(options),
        LC32HostIndirectArgument(error ? &hostError : NULL));
    if(error) *error = hostError ? LC32HostToGuestObject(hostError) : nil;
    return LC32HostToGuestOwnedObject(result);
}

- (id)newRenderPipelineStateWithDescriptor:
        (MTLRenderPipelineDescriptor *)descriptor error:(NSError **)error {
    uint64_t hostError = 0;
    const uint64_t result = LC32MTL_INVOKE(
        newRenderPipelineStateWithDescriptor:error:,
        LC32MTL_HOST(descriptor),
        LC32HostIndirectArgument(error ? &hostError : NULL));
    if(error) *error = hostError ? LC32HostToGuestObject(hostError) : nil;
    return LC32HostToGuestOwnedObject(result);
}

- (id)newComputePipelineStateWithFunction:(id)function
                                    error:(NSError **)error {
    uint64_t hostError = 0;
    const uint64_t result = LC32MTL_INVOKE(
        newComputePipelineStateWithFunction:error:, LC32MTL_HOST(function),
        LC32HostIndirectArgument(error ? &hostError : NULL));
    if(error) *error = hostError ? LC32HostToGuestObject(hostError) : nil;
    return LC32HostToGuestOwnedObject(result);
}
@end

@interface LC32MTLCommandQueue : LC32MTLObject <MTLCommandQueue>
@end

@implementation LC32MTLCommandQueue
LC32MTL_OBJECT_FACTORY(commandBuffer)
LC32MTL_OBJECT_FACTORY(commandBufferWithUnretainedReferences)

- (void)insertDebugCaptureBoundary {
    /* Removed from current Metal; it only marks frames for the debugger. */
}
@end

@interface LC32MTLCommandBuffer : LC32MTLObject <MTLCommandBuffer>
@end

@implementation LC32MTLCommandBuffer
LC32MTL_OBJECT_GETTER(commandQueue)
LC32MTL_OBJECT_GETTER(error)
LC32MTL_OBJECT_FACTORY(blitCommandEncoder)
LC32MTL_OBJECT_FACTORY(computeCommandEncoder)

- (BOOL)retainedReferences {
    return (LC32MTL_INVOKE(retainedReferences) & 0xff) != 0;
}

- (MTLCommandBufferStatus)status {
    return (MTLCommandBufferStatus)LC32MTL_GET_INTEGER(status);
}

- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)pass {
    return LC32ReturnBorrowedGuestObject(LC32MTL_INVOKE_OBJECT(
        renderCommandEncoderWithDescriptor:, LC32MTL_HOST(pass)));
}

- (void)enqueue {
    (void)LC32MTL_INVOKE(enqueue);
}

- (void)commit {
    (void)LC32MTL_INVOKE(commit);
}

- (void)waitUntilScheduled {
    (void)LC32MTL_INVOKE(waitUntilScheduled);
}

- (void)waitUntilCompleted {
    (void)LC32MTL_INVOKE(waitUntilCompleted);
}

- (void)addScheduledHandler:(MTLCommandBufferHandler)block {
    (void)LC32MTL_INVOKE(addScheduledHandler:, LC32MTL_HOST(block));
}

- (void)addCompletedHandler:(MTLCommandBufferHandler)block {
    (void)LC32MTL_INVOKE(addCompletedHandler:, LC32MTL_HOST(block));
}

- (void)presentDrawable:(id)drawable {
    (void)LC32MTL_INVOKE(presentDrawable:, LC32MTL_HOST(drawable));
}

- (void)presentDrawable:(id)drawable atTime:(CFTimeInterval)time {
    (void)LC32MTL_INVOKE(presentDrawable:atTime:, LC32MTL_HOST(drawable),
        (double)time);
}
@end

/* Every encoder kind (compute and parallel ones included). */
@interface LC32MTLCommandEncoder : LC32MTLObject <MTLCommandEncoder>
@end

@implementation LC32MTLCommandEncoder
- (void)endEncoding {
    LC32MTL_CALL(LC32MetalOpEncoderEndEncoding, LC32MTL_OBJ(self));
}

- (void)insertDebugSignpost:(NSString *)string {
    (void)LC32MTL_INVOKE(insertDebugSignpost:, LC32MTL_HOST(string));
}

- (void)pushDebugGroup:(NSString *)string {
    (void)LC32MTL_INVOKE(pushDebugGroup:, LC32MTL_HOST(string));
}

- (void)popDebugGroup {
    (void)LC32MTL_INVOKE(popDebugGroup);
}
@end

@interface LC32MTLRenderCommandEncoder : LC32MTLCommandEncoder
    <MTLRenderCommandEncoder>
@end

@implementation LC32MTLRenderCommandEncoder

- (void)setRenderPipelineState:(id)state {
    LC32MTL_CALL(LC32MetalOpRenderSetPipelineState, LC32MTL_OBJ(self),
        LC32MTL_OBJ(state));
}

- (void)setDepthStencilState:(id)state {
    LC32MTL_CALL(LC32MetalOpRenderSetDepthStencilState, LC32MTL_OBJ(self),
        LC32MTL_OBJ(state));
}

- (void)setVertexBuffer:(id)buffer offset:(NSUInteger)offset
                atIndex:(NSUInteger)index {
    LC32MTL_CALL(LC32MetalOpRenderSetVertexBuffer, LC32MTL_OBJ(self),
        LC32MTL_OBJ(buffer), LC32MTL_U(offset), LC32MTL_U(index));
}

- (void)setFragmentBuffer:(id)buffer offset:(NSUInteger)offset
                  atIndex:(NSUInteger)index {
    LC32MTL_CALL(LC32MetalOpRenderSetFragmentBuffer, LC32MTL_OBJ(self),
        LC32MTL_OBJ(buffer), LC32MTL_U(offset), LC32MTL_U(index));
}

- (void)setVertexBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index {
    LC32MTL_CALL(LC32MetalOpRenderSetVertexBufferOffset, LC32MTL_OBJ(self),
        LC32MTL_U(offset), LC32MTL_U(index));
}

- (void)setFragmentBufferOffset:(NSUInteger)offset
                        atIndex:(NSUInteger)index {
    LC32MTL_CALL(LC32MetalOpRenderSetFragmentBufferOffset, LC32MTL_OBJ(self),
        LC32MTL_U(offset), LC32MTL_U(index));
}

- (void)setVertexBuffers:(const id *)buffers
                 offsets:(const NSUInteger *)offsets
               withRange:(NSRange)range {
    for(NSUInteger i = 0; i < range.length; i++)
        [self setVertexBuffer:buffers[i] offset:offsets[i]
                      atIndex:range.location + i];
}

- (void)setFragmentBuffers:(const id *)buffers
                   offsets:(const NSUInteger *)offsets
                 withRange:(NSRange)range {
    for(NSUInteger i = 0; i < range.length; i++)
        [self setFragmentBuffer:buffers[i] offset:offsets[i]
                        atIndex:range.location + i];
}

- (void)setVertexTexture:(id)texture atIndex:(NSUInteger)index {
    LC32MTL_CALL(LC32MetalOpRenderSetVertexTexture, LC32MTL_OBJ(self),
        LC32MTL_OBJ(texture), LC32MTL_U(index));
}

- (void)setFragmentTexture:(id)texture atIndex:(NSUInteger)index {
    LC32MTL_CALL(LC32MetalOpRenderSetFragmentTexture, LC32MTL_OBJ(self),
        LC32MTL_OBJ(texture), LC32MTL_U(index));
}

- (void)setVertexTextures:(const id *)textures withRange:(NSRange)range {
    for(NSUInteger i = 0; i < range.length; i++)
        [self setVertexTexture:textures[i] atIndex:range.location + i];
}

- (void)setFragmentTextures:(const id *)textures withRange:(NSRange)range {
    for(NSUInteger i = 0; i < range.length; i++)
        [self setFragmentTexture:textures[i] atIndex:range.location + i];
}

- (void)setVertexSamplerState:(id)sampler atIndex:(NSUInteger)index {
    LC32MTL_CALL(LC32MetalOpRenderSetVertexSamplerState, LC32MTL_OBJ(self),
        LC32MTL_OBJ(sampler), LC32MTL_U(index));
}

- (void)setFragmentSamplerState:(id)sampler atIndex:(NSUInteger)index {
    LC32MTL_CALL(LC32MetalOpRenderSetFragmentSamplerState,
        LC32MTL_OBJ(self), LC32MTL_OBJ(sampler), LC32MTL_U(index));
}

- (void)setVertexSamplerStates:(const id *)samplers
                     withRange:(NSRange)range {
    for(NSUInteger i = 0; i < range.length; i++)
        [self setVertexSamplerState:samplers[i] atIndex:range.location + i];
}

- (void)setFragmentSamplerStates:(const id *)samplers
                       withRange:(NSRange)range {
    for(NSUInteger i = 0; i < range.length; i++)
        [self setFragmentSamplerState:samplers[i]
                              atIndex:range.location + i];
}

- (void)setViewport:(MTLViewport)viewport {
    LC32MTL_CALL(LC32MetalOpRenderSetViewport, LC32MTL_OBJ(self),
        LC32MetalDoubleBits(viewport.originX),
        LC32MetalDoubleBits(viewport.originY),
        LC32MetalDoubleBits(viewport.width),
        LC32MetalDoubleBits(viewport.height),
        LC32MetalDoubleBits(viewport.znear),
        LC32MetalDoubleBits(viewport.zfar));
}

- (void)setScissorRect:(MTLScissorRect)rect {
    LC32MTL_CALL(LC32MetalOpRenderSetScissorRect, LC32MTL_OBJ(self),
        LC32MTL_U(rect.x), LC32MTL_U(rect.y), LC32MTL_U(rect.width),
        LC32MTL_U(rect.height));
}

- (void)setFrontFacingWinding:(MTLWinding)winding {
    LC32MTL_CALL(LC32MetalOpRenderSetFrontFacingWinding, LC32MTL_OBJ(self),
        LC32MTL_U(winding));
}

- (void)setCullMode:(MTLCullMode)mode {
    LC32MTL_CALL(LC32MetalOpRenderSetCullMode, LC32MTL_OBJ(self),
        LC32MTL_U(mode));
}

- (void)setDepthClipMode:(MTLDepthClipMode)mode {
    LC32MTL_CALL(LC32MetalOpRenderSetDepthClipMode, LC32MTL_OBJ(self),
        LC32MTL_U(mode));
}

- (void)setTriangleFillMode:(MTLTriangleFillMode)mode {
    LC32MTL_CALL(LC32MetalOpRenderSetTriangleFillMode, LC32MTL_OBJ(self),
        LC32MTL_U(mode));
}

- (void)setDepthBias:(float)depthBias slopeScale:(float)slopeScale
               clamp:(float)clamp {
    LC32MTL_CALL(LC32MetalOpRenderSetDepthBias, LC32MTL_OBJ(self),
        LC32MetalFloatBits(depthBias), LC32MetalFloatBits(slopeScale),
        LC32MetalFloatBits(clamp));
}

- (void)setBlendColorRed:(float)red green:(float)green blue:(float)blue
                   alpha:(float)alpha {
    LC32MTL_CALL(LC32MetalOpRenderSetBlendColor, LC32MTL_OBJ(self),
        LC32MetalFloatBits(red), LC32MetalFloatBits(green),
        LC32MetalFloatBits(blue), LC32MetalFloatBits(alpha));
}

- (void)setStencilReferenceValue:(uint32_t)value {
    LC32MTL_CALL(LC32MetalOpRenderSetStencilReferenceValue,
        LC32MTL_OBJ(self), LC32MTL_U(value));
}

- (void)setStencilFrontReferenceValue:(uint32_t)front
                   backReferenceValue:(uint32_t)back {
    LC32MTL_CALL(LC32MetalOpRenderSetStencilFrontBackReferenceValue,
        LC32MTL_OBJ(self), LC32MTL_U(front), LC32MTL_U(back));
}

- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode
                         offset:(NSUInteger)offset {
    LC32MTL_CALL(LC32MetalOpRenderSetVisibilityResultMode,
        LC32MTL_OBJ(self), LC32MTL_U(mode), LC32MTL_U(offset));
}

- (void)drawPrimitives:(MTLPrimitiveType)type
           vertexStart:(NSUInteger)start
           vertexCount:(NSUInteger)count
         instanceCount:(NSUInteger)instances {
    LC32MTL_CALL(LC32MetalOpRenderDrawPrimitives, LC32MTL_OBJ(self),
        LC32MTL_U(type), LC32MTL_U(start), LC32MTL_U(count),
        LC32MTL_U(instances));
}

- (void)drawPrimitives:(MTLPrimitiveType)type
           vertexStart:(NSUInteger)start
           vertexCount:(NSUInteger)count {
    [self drawPrimitives:type vertexStart:start vertexCount:count
           instanceCount:1];
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)type
                   indexCount:(NSUInteger)count
                    indexType:(MTLIndexType)indexType
                  indexBuffer:(id)indexBuffer
            indexBufferOffset:(NSUInteger)offset
                instanceCount:(NSUInteger)instances {
    LC32MTL_CALL(LC32MetalOpRenderDrawIndexedPrimitives, LC32MTL_OBJ(self),
        LC32MTL_U(type), LC32MTL_U(count), LC32MTL_U(indexType),
        LC32MTL_OBJ(indexBuffer), LC32MTL_U(offset), LC32MTL_U(instances));
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)type
                   indexCount:(NSUInteger)count
                    indexType:(MTLIndexType)indexType
                  indexBuffer:(id)indexBuffer
            indexBufferOffset:(NSUInteger)offset {
    [self drawIndexedPrimitives:type indexCount:count indexType:indexType
                    indexBuffer:indexBuffer indexBufferOffset:offset
                  instanceCount:1];
}
@end

@interface LC32MTLBlitCommandEncoder : LC32MTLCommandEncoder
    <MTLBlitCommandEncoder>
@end

@implementation LC32MTLBlitCommandEncoder

- (void)copyFromTexture:(id)source
            sourceSlice:(NSUInteger)sourceSlice
            sourceLevel:(NSUInteger)sourceLevel
           sourceOrigin:(MTLOrigin)sourceOrigin
             sourceSize:(MTLSize)sourceSize
              toTexture:(id)destination
       destinationSlice:(NSUInteger)destinationSlice
       destinationLevel:(NSUInteger)destinationLevel
      destinationOrigin:(MTLOrigin)destinationOrigin {
    LC32MTL_CALL(LC32MetalOpBlitCopyTextureToTexture, LC32MTL_OBJ(self),
        LC32MTL_OBJ(source), LC32MTL_U(sourceSlice), LC32MTL_U(sourceLevel),
        LC32MTL_ORIGIN(sourceOrigin), LC32MTL_SIZE(sourceSize),
        LC32MTL_OBJ(destination), LC32MTL_U(destinationSlice),
        LC32MTL_U(destinationLevel), LC32MTL_ORIGIN(destinationOrigin));
}

- (void)copyFromBuffer:(id)source sourceOffset:(NSUInteger)sourceOffset
              toBuffer:(id)destination
     destinationOffset:(NSUInteger)destinationOffset
                  size:(NSUInteger)size {
    LC32MTL_CALL(LC32MetalOpBlitCopyBufferToBuffer, LC32MTL_OBJ(self),
        LC32MTL_OBJ(source), LC32MTL_U(sourceOffset),
        LC32MTL_OBJ(destination), LC32MTL_U(destinationOffset),
        LC32MTL_U(size));
}

- (void)copyFromBuffer:(id)source sourceOffset:(NSUInteger)sourceOffset
     sourceBytesPerRow:(NSUInteger)bytesPerRow
   sourceBytesPerImage:(NSUInteger)bytesPerImage
            sourceSize:(MTLSize)sourceSize
             toTexture:(id)destination
      destinationSlice:(NSUInteger)destinationSlice
      destinationLevel:(NSUInteger)destinationLevel
     destinationOrigin:(MTLOrigin)destinationOrigin {
    LC32MTL_CALL(LC32MetalOpBlitCopyBufferToTexture, LC32MTL_OBJ(self),
        LC32MTL_OBJ(source), LC32MTL_U(sourceOffset), LC32MTL_U(bytesPerRow),
        LC32MTL_U(bytesPerImage), LC32MTL_SIZE(sourceSize),
        LC32MTL_OBJ(destination), LC32MTL_U(destinationSlice),
        LC32MTL_U(destinationLevel), LC32MTL_ORIGIN(destinationOrigin),
        LC32MTL_U(0));
}

- (void)copyFromTexture:(id)source
            sourceSlice:(NSUInteger)sourceSlice
            sourceLevel:(NSUInteger)sourceLevel
           sourceOrigin:(MTLOrigin)sourceOrigin
             sourceSize:(MTLSize)sourceSize
               toBuffer:(id)destination
      destinationOffset:(NSUInteger)destinationOffset
 destinationBytesPerRow:(NSUInteger)bytesPerRow
destinationBytesPerImage:(NSUInteger)bytesPerImage {
    LC32MTL_CALL(LC32MetalOpBlitCopyTextureToBuffer, LC32MTL_OBJ(self),
        LC32MTL_OBJ(source), LC32MTL_U(sourceSlice), LC32MTL_U(sourceLevel),
        LC32MTL_ORIGIN(sourceOrigin), LC32MTL_SIZE(sourceSize),
        LC32MTL_OBJ(destination), LC32MTL_U(destinationOffset),
        LC32MTL_U(bytesPerRow), LC32MTL_U(bytesPerImage), LC32MTL_U(0));
}

- (void)generateMipmapsForTexture:(id)texture {
    LC32MTL_CALL(LC32MetalOpBlitGenerateMipmaps, LC32MTL_OBJ(self),
        LC32MTL_OBJ(texture));
}
@end

@interface LC32MTLBuffer : LC32MTLObject <MTLBuffer> {
    uint32_t _lc32GuestContents;
}
@end

@implementation LC32MTLBuffer
- (void *)contents {
    /* The host maps the buffer's storage into guest memory once. */
    uint32_t contents = __atomic_load_n(&_lc32GuestContents,
        __ATOMIC_ACQUIRE);
    if(!contents) {
        contents = LC32MTL_CALL(LC32MetalOpBufferContents, LC32MTL_OBJ(self));
        __atomic_store_n(&_lc32GuestContents, contents, __ATOMIC_RELEASE);
    }
    return (void *)(uintptr_t)contents;
}

- (NSUInteger)length {
    return (NSUInteger)LC32MTL_GET_INTEGER(length);
}

- (void)didModifyRange:(NSRange)range {
    /* Shared storage only on iOS: nothing to flush. */
}
@end

@interface LC32MTLTexture : LC32MTLObject <MTLTexture>
@end

@implementation LC32MTLTexture
- (MTLTextureType)textureType {
    return (MTLTextureType)LC32MTL_GET_INTEGER(textureType);
}

- (MTLPixelFormat)pixelFormat {
    return (MTLPixelFormat)LC32MTL_GET_INTEGER(pixelFormat);
}

- (NSUInteger)width { return (NSUInteger)LC32MTL_GET_INTEGER(width); }
- (NSUInteger)height { return (NSUInteger)LC32MTL_GET_INTEGER(height); }
- (NSUInteger)depth { return (NSUInteger)LC32MTL_GET_INTEGER(depth); }
- (NSUInteger)mipmapLevelCount {
    return (NSUInteger)LC32MTL_GET_INTEGER(mipmapLevelCount);
}
- (NSUInteger)sampleCount {
    return (NSUInteger)LC32MTL_GET_INTEGER(sampleCount);
}
- (NSUInteger)arrayLength {
    return (NSUInteger)LC32MTL_GET_INTEGER(arrayLength);
}
- (BOOL)isFramebufferOnly {
    return (LC32MTL_GET_INTEGER(isFramebufferOnly) & 0xff) != 0;
}
- (MTLTextureUsage)usage {
    return (MTLTextureUsage)LC32MTL_GET_INTEGER(usage);
}
LC32MTL_OBJECT_GETTER(rootResource)
LC32MTL_OBJECT_GETTER(parentTexture)

- (id)newTextureViewWithPixelFormat:(MTLPixelFormat)format {
    return LC32HostToGuestOwnedObject(LC32MTL_INVOKE(
        newTextureViewWithPixelFormat:, (uint64_t)format));
}

- (void)replaceRegion:(MTLRegion)region
          mipmapLevel:(NSUInteger)level
                slice:(NSUInteger)slice
            withBytes:(const void *)bytes
          bytesPerRow:(NSUInteger)bytesPerRow
        bytesPerImage:(NSUInteger)bytesPerImage {
    LC32MTL_CALL(LC32MetalOpTextureReplaceRegion, LC32MTL_OBJ(self),
        LC32MTL_REGION(region), LC32MTL_U(level), LC32MTL_U(slice),
        LC32MTL_OBJ(bytes), LC32MTL_U(bytesPerRow), LC32MTL_U(bytesPerImage));
}

- (void)replaceRegion:(MTLRegion)region
          mipmapLevel:(NSUInteger)level
            withBytes:(const void *)bytes
          bytesPerRow:(NSUInteger)bytesPerRow {
    [self replaceRegion:region mipmapLevel:level slice:0 withBytes:bytes
            bytesPerRow:bytesPerRow bytesPerImage:0];
}

- (void)getBytes:(void *)bytes
     bytesPerRow:(NSUInteger)bytesPerRow
   bytesPerImage:(NSUInteger)bytesPerImage
      fromRegion:(MTLRegion)region
     mipmapLevel:(NSUInteger)level
           slice:(NSUInteger)slice {
    LC32MTL_CALL(LC32MetalOpTextureGetBytes, LC32MTL_OBJ(self),
        LC32MTL_OBJ(bytes), LC32MTL_U(bytesPerRow), LC32MTL_U(bytesPerImage),
        LC32MTL_REGION(region), LC32MTL_U(level), LC32MTL_U(slice));
}

- (void)getBytes:(void *)bytes
     bytesPerRow:(NSUInteger)bytesPerRow
      fromRegion:(MTLRegion)region
     mipmapLevel:(NSUInteger)level {
    [self getBytes:bytes bytesPerRow:bytesPerRow bytesPerImage:0
        fromRegion:region mipmapLevel:level slice:0];
}
@end

@interface LC32MTLLibrary : LC32MTLObject <MTLLibrary>
@end

@implementation LC32MTLLibrary
LC32MTL_OBJECT_GETTER(functionNames)

- (id)newFunctionWithName:(NSString *)name {
    return LC32HostToGuestOwnedObject(LC32MTL_INVOKE(newFunctionWithName:,
        LC32MTL_HOST(name)));
}
@end

@interface LC32MTLFunction : LC32MTLObject <MTLFunction>
@end

@implementation LC32MTLFunction
LC32MTL_OBJECT_GETTER(name)
LC32MTL_OBJECT_GETTER(vertexAttributes)

- (MTLFunctionType)functionType {
    return (MTLFunctionType)LC32MTL_INVOKE(functionType);
}
@end

@interface LC32CAMetalDrawable : NSObject <CAMetalDrawable>
@end

@implementation LC32CAMetalDrawable
LC32MTL_OBJECT_GETTER(texture)
LC32MTL_OBJECT_GETTER(layer)

- (void)present {
    (void)LC32MTL_INVOKE(present);
}

- (void)presentAtTime:(CFTimeInterval)time {
    (void)LC32MTL_INVOKE(presentAtTime:, (double)time);
}
@end

/* ---- Descriptor property accessors --------------------------------------- */

@implementation MTLTextureDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_UINT_PROPERTY(textureType, setTextureType:)
LC32MTL_UINT_PROPERTY(pixelFormat, setPixelFormat:)
LC32MTL_UINT_PROPERTY(width, setWidth:)
LC32MTL_UINT_PROPERTY(height, setHeight:)
LC32MTL_UINT_PROPERTY(depth, setDepth:)
LC32MTL_UINT_PROPERTY(mipmapLevelCount, setMipmapLevelCount:)
LC32MTL_UINT_PROPERTY(sampleCount, setSampleCount:)
LC32MTL_UINT_PROPERTY(arrayLength, setArrayLength:)
LC32MTL_UINT_PROPERTY(resourceOptions, setResourceOptions:)
LC32MTL_UINT_PROPERTY(cpuCacheMode, setCpuCacheMode:)
LC32MTL_UINT_PROPERTY(storageMode, setStorageMode:)
LC32MTL_UINT_PROPERTY(usage, setUsage:)
@end

@implementation MTLSamplerDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_UINT_PROPERTY(minFilter, setMinFilter:)
LC32MTL_UINT_PROPERTY(magFilter, setMagFilter:)
LC32MTL_UINT_PROPERTY(mipFilter, setMipFilter:)
LC32MTL_UINT_PROPERTY(maxAnisotropy, setMaxAnisotropy:)
LC32MTL_UINT_PROPERTY(sAddressMode, setSAddressMode:)
LC32MTL_UINT_PROPERTY(tAddressMode, setTAddressMode:)
LC32MTL_UINT_PROPERTY(rAddressMode, setRAddressMode:)
LC32MTL_BOOL_PROPERTY(normalizedCoordinates, setNormalizedCoordinates:)
LC32MTL_FLOAT_PROPERTY(lodMinClamp, setLodMinClamp:)
LC32MTL_FLOAT_PROPERTY(lodMaxClamp, setLodMaxClamp:)
LC32MTL_UINT_PROPERTY(compareFunction, setCompareFunction:)
LC32MTL_OBJECT_PROPERTY(label, setLabel:)
@end

@implementation MTLStencilDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_UINT_PROPERTY(stencilCompareFunction, setStencilCompareFunction:)
LC32MTL_UINT_PROPERTY(stencilFailureOperation, setStencilFailureOperation:)
LC32MTL_UINT_PROPERTY(depthFailureOperation, setDepthFailureOperation:)
LC32MTL_UINT_PROPERTY(depthStencilPassOperation,
    setDepthStencilPassOperation:)
LC32MTL_UINT32_PROPERTY(readMask, setReadMask:)
LC32MTL_UINT32_PROPERTY(writeMask, setWriteMask:)
@end

@implementation MTLDepthStencilDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_UINT_PROPERTY(depthCompareFunction, setDepthCompareFunction:)
LC32MTL_BOOL_PROPERTY(isDepthWriteEnabled, setDepthWriteEnabled:)
LC32MTL_OBJECT_PROPERTY(frontFaceStencil, setFrontFaceStencil:)
LC32MTL_OBJECT_PROPERTY(backFaceStencil, setBackFaceStencil:)
LC32MTL_OBJECT_PROPERTY(label, setLabel:)
@end

@implementation MTLRenderPipelineColorAttachmentDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_UINT_PROPERTY(pixelFormat, setPixelFormat:)
LC32MTL_BOOL_PROPERTY(isBlendingEnabled, setBlendingEnabled:)
LC32MTL_UINT_PROPERTY(sourceRGBBlendFactor, setSourceRGBBlendFactor:)
LC32MTL_UINT_PROPERTY(destinationRGBBlendFactor, setDestinationRGBBlendFactor:)
LC32MTL_UINT_PROPERTY(rgbBlendOperation, setRgbBlendOperation:)
LC32MTL_UINT_PROPERTY(sourceAlphaBlendFactor, setSourceAlphaBlendFactor:)
LC32MTL_UINT_PROPERTY(destinationAlphaBlendFactor,
    setDestinationAlphaBlendFactor:)
LC32MTL_UINT_PROPERTY(alphaBlendOperation, setAlphaBlendOperation:)
LC32MTL_UINT_PROPERTY(writeMask, setWriteMask:)
@end

@implementation MTLRenderPipelineDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_OBJECT_PROPERTY(label, setLabel:)
LC32MTL_OBJECT_PROPERTY(vertexFunction, setVertexFunction:)
LC32MTL_OBJECT_PROPERTY(fragmentFunction, setFragmentFunction:)
LC32MTL_OBJECT_PROPERTY(vertexDescriptor, setVertexDescriptor:)
LC32MTL_UINT_PROPERTY(sampleCount, setSampleCount:)
LC32MTL_BOOL_PROPERTY(isAlphaToCoverageEnabled, setAlphaToCoverageEnabled:)
LC32MTL_BOOL_PROPERTY(isAlphaToOneEnabled, setAlphaToOneEnabled:)
LC32MTL_BOOL_PROPERTY(isRasterizationEnabled, setRasterizationEnabled:)
LC32MTL_OBJECT_GETTER(colorAttachments)
LC32MTL_UINT_PROPERTY(depthAttachmentPixelFormat,
    setDepthAttachmentPixelFormat:)
LC32MTL_UINT_PROPERTY(stencilAttachmentPixelFormat,
    setStencilAttachmentPixelFormat:)
@end

@implementation MTLRenderPassAttachmentDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_OBJECT_PROPERTY(texture, setTexture:)
LC32MTL_UINT_PROPERTY(level, setLevel:)
LC32MTL_UINT_PROPERTY(slice, setSlice:)
LC32MTL_UINT_PROPERTY(depthPlane, setDepthPlane:)
LC32MTL_OBJECT_PROPERTY(resolveTexture, setResolveTexture:)
LC32MTL_UINT_PROPERTY(resolveLevel, setResolveLevel:)
LC32MTL_UINT_PROPERTY(resolveSlice, setResolveSlice:)
LC32MTL_UINT_PROPERTY(resolveDepthPlane, setResolveDepthPlane:)
LC32MTL_UINT_PROPERTY(loadAction, setLoadAction:)
LC32MTL_UINT_PROPERTY(storeAction, setStoreAction:)
@end

@implementation MTLRenderPassColorAttachmentDescriptor (LC32Properties)
- (MTLClearColor)clearColor {
    MTLClearColor color;
    LC32InvokeHostSelector(self.host_self, LC32MTL_SEL(clearColor, YES),
        &color, sizeof(color), (uint64_t)0);
    return color;
}

- (void)setClearColor:(MTLClearColor)color {
    /* Four doubles in both ABIs. */
    MTLClearColor hostColor = color;
    (void)LC32MTL_INVOKE(setClearColor:,
        LC32HostAggregateArgument(&hostColor));
}
@end

@implementation MTLRenderPassDepthAttachmentDescriptor (LC32Properties)
LC32MTL_DOUBLE_PROPERTY(clearDepth, setClearDepth:)
@end

@implementation MTLRenderPassStencilAttachmentDescriptor (LC32Properties)
LC32MTL_UINT32_PROPERTY(clearStencil, setClearStencil:)
@end

@implementation MTLRenderPassDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_OBJECT_GETTER(colorAttachments)
LC32MTL_OBJECT_PROPERTY(depthAttachment, setDepthAttachment:)
LC32MTL_OBJECT_PROPERTY(stencilAttachment, setStencilAttachment:)
LC32MTL_OBJECT_PROPERTY(visibilityResultBuffer, setVisibilityResultBuffer:)
@end

@implementation MTLVertexDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_OBJECT_GETTER(layouts)
LC32MTL_OBJECT_GETTER(attributes)
@end

@implementation MTLVertexAttributeDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_UINT_PROPERTY(format, setFormat:)
LC32MTL_UINT_PROPERTY(offset, setOffset:)
LC32MTL_UINT_PROPERTY(bufferIndex, setBufferIndex:)
@end

@implementation MTLVertexBufferLayoutDescriptor (LC32Properties)
LC32MTL_INIT
LC32MTL_UINT_PROPERTY(stride, setStride:)
LC32MTL_UINT_PROPERTY(stepFunction, setStepFunction:)
LC32MTL_UINT_PROPERTY(stepRate, setStepRate:)
@end

@implementation MTLCompileOptions (LC32Properties)
LC32MTL_INIT
LC32MTL_OBJECT_PROPERTY(preprocessorMacros, setPreprocessorMacros:)
LC32MTL_BOOL_PROPERTY(fastMathEnabled, setFastMathEnabled:)
LC32MTL_UINT_PROPERTY(languageVersion, setLanguageVersion:)
@end


/* Descriptor arrays are indexed before most draws too. */
#define LC32MTL_INDEXED_GETTER \
- (id)objectAtIndexedSubscript:(NSUInteger)index { \
    const uint32_t inlineResult = LC32MTL_CALL(LC32MetalOpGetObjectAtIndex, \
        LC32MTL_OBJ(self), LC32MTL_SEL(objectAtIndexedSubscript:, NO), \
        LC32MTL_U(index)); \
    if(inlineResult != LC32MetalInlineFallback) \
        return (id)(uintptr_t)inlineResult; \
    return LC32ReturnBorrowedGuestObject(LC32MTL_INVOKE_OBJECT( \
        objectAtIndexedSubscript:, (uint64_t)index)); \
}

@implementation MTLRenderPipelineColorAttachmentDescriptorArray (LC32Inline)
LC32MTL_INDEXED_GETTER
@end

@implementation MTLRenderPassColorAttachmentDescriptorArray (LC32Inline)
LC32MTL_INDEXED_GETTER
@end

@implementation MTLVertexAttributeDescriptorArray (LC32Inline)
LC32MTL_INDEXED_GETTER
@end

@implementation MTLVertexBufferLayoutDescriptorArray (LC32Inline)
LC32MTL_INDEXED_GETTER
@end

#pragma clang diagnostic pop
