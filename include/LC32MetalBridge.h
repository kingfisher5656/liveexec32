#ifndef LC32_METAL_BRIDGE_H
#define LC32_METAL_BRIDGE_H

#include <stdint.h>

/*
 * ARM32 Metal calls that cannot go through the generic Objective-C bridge
 * (pointer arguments, NSUInteger structs, dispatch_data_t) or that run too
 * often to halt the JIT for every call (render encoder state and draws).
 *
 * The guest packs every argument into 64-bit slots. Objects are passed as
 * guest object pointers and resolved on the host through the guest-to-host
 * mapping registry; doubles are passed as their IEEE-754 bits, floats as
 * float bits in the low word.
 */
enum {
    LC32MetalABIVersion = 1,
    LC32MetalMaxSlots = 20,
};

typedef struct {
    uint32_t version;
    uint32_t slotCount;
    uint64_t slots[LC32MetalMaxSlots];
} LC32MetalCall;

/*
 * Opcodes below LC32MetalOpFirstInline go through LC32_Metal_Dispatch, which
 * halts the JIT and may run guest code (object results). The others go
 * through LC32_Metal_DispatchInline: they return no object, never call
 * guest code and never block for long, so the host runs them from inside
 * the JIT callback like the OpenGL ES bridge. Keep the values explicit.
 */
typedef enum : uint32_t {
    LC32MetalOpBufferContents = 1,
    LC32MetalOpDeviceNewLibraryWithData = 2,
    LC32MetalOpDeviceNewBufferWithBytes = 3,
    LC32MetalOpDeviceNewTexture = 4,
    /* Bulk copies: halting, so they never stall inside the JIT. */
    LC32MetalOpTextureReplaceRegion = 5,
    LC32MetalOpTextureGetBytes = 6,

    LC32MetalOpFirstInline = 32,
    LC32MetalOpEncoderEndEncoding = 34,
    LC32MetalOpRenderSetPipelineState = 35,
    LC32MetalOpRenderSetDepthStencilState = 36,
    LC32MetalOpRenderSetVertexBuffer = 37,
    LC32MetalOpRenderSetFragmentBuffer = 38,
    LC32MetalOpRenderSetVertexTexture = 39,
    LC32MetalOpRenderSetFragmentTexture = 40,
    LC32MetalOpRenderSetVertexSamplerState = 41,
    LC32MetalOpRenderSetFragmentSamplerState = 42,
    LC32MetalOpRenderSetViewport = 43,
    LC32MetalOpRenderSetScissorRect = 44,
    LC32MetalOpRenderSetFrontFacingWinding = 45,
    LC32MetalOpRenderSetCullMode = 46,
    LC32MetalOpRenderSetDepthBias = 47,
    LC32MetalOpRenderSetVisibilityResultMode = 48,
    LC32MetalOpRenderSetStencilReferenceValue = 49,
    LC32MetalOpRenderSetBlendColor = 50,
    LC32MetalOpRenderSetTriangleFillMode = 51,
    LC32MetalOpRenderSetVertexBufferOffset = 52,
    LC32MetalOpRenderSetFragmentBufferOffset = 53,
    LC32MetalOpRenderDrawPrimitives = 54,
    LC32MetalOpRenderDrawIndexedPrimitives = 55,
    LC32MetalOpBlitCopyTextureToTexture = 56,
    LC32MetalOpBlitCopyBufferToBuffer = 57,
    LC32MetalOpBlitCopyBufferToTexture = 58,
    LC32MetalOpBlitCopyTextureToBuffer = 59,
    LC32MetalOpBlitGenerateMipmaps = 60,
    LC32MetalOpRenderSetStencilFrontBackReferenceValue = 61,
    LC32MetalOpRenderSetDepthClipMode = 62,
    /* Property accessors of any bridged Metal object, by host selector:
     * (object, selector[, value or index]). Descriptors are reconfigured
     * before most draws (UE4 sets every blend factor per draw). The object
     * forms return LC32MetalInlineFallback when the call needs guest code
     * (a result with no guest proxy yet, an argument with no host peer);
     * the guest then makes the call the ordinary way. */
    LC32MetalOpSetInteger = 63,
    LC32MetalOpGetInteger = 64,
    LC32MetalOpGetObject = 65,
    LC32MetalOpGetObjectAtIndex = 66,
    LC32MetalOpSetObject = 67,
} LC32MetalOpcode;

enum { LC32MetalInlineFallback = 1 };

#endif
