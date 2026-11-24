#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <sys/mman.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

#include "bridge.h"
#include "lc32_profile.h"
#include "../../include/LC32MetalBridge.h"

/*
 * Host half of the ARM32 Metal bridge (guest half: GuestFrameworks/Metal).
 *
 * Metal's API is almost entirely protocols implemented by private classes,
 * which the generated guest shims never see. The guest gets one proxy class
 * per protocol (LC32MetalGuestProxyClass) whose ordinary methods use the
 * generic selector bridge; this file handles what that bridge cannot do:
 * buffer contents shared with guest memory, raw byte pointers, dispatch_data
 * and the hot render-encoder calls that must not halt the JIT.
 */

extern "C" uint32_t LC32GetGuestExecutableSDKVersion(void);
extern "C" void LC32EnterInlineHostCall(void);
extern "C" void LC32LeaveInlineHostCall(void);

namespace {

std::atomic<bool> loggedFailure[256];

/* No guest code may run while an inline call is on the stack; releases that
 * would drop guest references are queued instead (bridge.mm). Covers the
 * autorelease pool drain too. */
struct InlineHostCallScope {
    InlineHostCallScope() { LC32EnterInlineHostCall(); }
    ~InlineHostCallScope() { LC32LeaveInlineHostCall(); }
};

void LogOnce(uint32_t opcode, const char *what) {
    if(opcode < 256 && loggedFailure[opcode].exchange(true)) return;
    fprintf(stderr, "LC32 Metal: opcode %u: %s\n", opcode, what);
}

bool ReadCall(uint32_t guestAddress, LC32MetalCall &call) {
    struct {
        uint32_t version;
        uint32_t slotCount;
    } header = {};
    if(!guestAddress ||
       Dynarmic_mem_1read(guestAddress, sizeof(header),
                          reinterpret_cast<char *>(&header)) != 0 ||
       header.version != LC32MetalABIVersion ||
       header.slotCount > LC32MetalMaxSlots) {
        return false;
    }
    call.version = header.version;
    call.slotCount = header.slotCount;
    const size_t bytes = header.slotCount * sizeof(call.slots[0]);
    return !bytes || Dynarmic_mem_1read(
        guestAddress + offsetof(LC32MetalCall, slots), bytes,
        reinterpret_cast<char *>(call.slots)) == 0;
}

id HostObject(uint64_t guestObject) {
    if(!guestObject) return nil;
    const u64 address = LC32LookupHostMapping((u32)guestObject);
    if(!address || address == LC32_HOST_MAPPING_DEAD) return nil;
    return (__bridge id)(void *)address;
}

double SlotDouble(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

float SlotFloat(uint64_t bits) {
    const uint32_t low = (uint32_t)bits;
    float value;
    memcpy(&value, &low, sizeof(value));
    return value;
}

/* A guest allocation made by one guest mmap is one host mapping, so its 4K
 * guest pages are adjacent in host memory too. Return the host address of
 * [guest, guest + length) when that holds, nullptr otherwise. */
char *ContiguousHostRange(uint32_t guest, size_t length) {
    if(!guest || !length || (uint64_t)guest + length > (UINT64_C(1) << 32))
        return nullptr;
    char *start = static_cast<char *>(get_memory(guest));
    if(!start) return nullptr;
    const uint64_t firstPage = guest & ~DYN_PAGE_MASK;
    char *firstPageHost = start - (guest & DYN_PAGE_MASK);
    const uint64_t end = (uint64_t)guest + length;
    for(uint64_t page = firstPage + DYN_PAGE_SIZE; page < end;
            page += DYN_PAGE_SIZE) {
        if(get_memory_page(page) != firstPageHost + (page - firstPage))
            return nullptr;
    }
    return start;
}

/* Copy what is mapped; unmapped tail pages (a size estimate that runs past
 * the end of the guest allocation) read as zero. */
void ReadGuestTolerant(uint32_t guest, size_t length, uint8_t *out) {
    size_t done = 0;
    while(done < length) {
        const uint64_t address = (uint64_t)guest + done;
        const size_t chunk = std::min<size_t>(length - done,
            DYN_PAGE_SIZE - (address & DYN_PAGE_MASK));
        if(address >= (UINT64_C(1) << 32) ||
           Dynarmic_mem_1read(address, chunk,
                              reinterpret_cast<char *>(out + done)) != 0)
            memset(out + done, 0, chunk);
        done += chunk;
    }
}

bool IsPVRTC(MTLPixelFormat format) {
    return format >= 160 && format <= 167;
}

size_t PVRTCBytes(MTLPixelFormat format, NSUInteger width, NSUInteger height) {
    /* 2bpp: 8x4 blocks, minimum 2x2 blocks; 4bpp: 4x4 blocks, minimum 2x2. */
    const bool twoBit = format == 160 || format == 161 || format == 164 ||
        format == 165;
    const NSUInteger blockWidth = twoBit ? 8 : 4;
    const NSUInteger blocksWide = std::max<NSUInteger>(
        (width + blockWidth - 1) / blockWidth, 2);
    const NSUInteger blocksHigh = std::max<NSUInteger>((height + 3) / 4, 2);
    return blocksWide * blocksHigh * 8;
}

/* Pixel rows per row of blocks: 4 for BC/ETC2/EAC, the block height for
 * ASTC, 1 for uncompressed formats. */
NSUInteger BlockHeight(MTLPixelFormat format) {
    const NSUInteger value = (NSUInteger)format;
    if((value >= 130 && value <= 143) || (value >= 170 && value <= 183))
        return 4;
    static const uint8_t astcHeights[15] = {
        4, 4, 5, 5, 6, 0, 5, 6, 8, 5, 6, 8, 10, 10, 12,
    };
    for(const NSUInteger first : {186u, 204u, 222u}) {
        if(value >= first && value < first + 15 && astcHeights[value - first])
            return astcHeights[value - first];
    }
    return 1;
}

/* Bytes Metal reads (or writes) for one region of a texture upload or
 * readback with these strides. bytesPerRow 0 (1D textures, single rows) is
 * sized for the widest pixel. */
size_t RegionBytes(id<MTLTexture> texture, MTLRegion region,
                   NSUInteger bytesPerRow, NSUInteger bytesPerImage) {
    const MTLPixelFormat format = texture.pixelFormat;
    const NSUInteger depth = std::max<NSUInteger>(region.size.depth, 1);
    if(IsPVRTC(format) && bytesPerRow == 0)
        return PVRTCBytes(format, region.size.width, region.size.height) *
            depth;
    const NSUInteger blockHeight = BlockHeight(format);
    const NSUInteger rows = std::max<NSUInteger>(
        (region.size.height + blockHeight - 1) / blockHeight, 1);
    const size_t rowBytes = bytesPerRow ? bytesPerRow
        : (size_t)std::max<NSUInteger>(region.size.width, 1) * 16;
    if(bytesPerImage && depth > 1) return (size_t)bytesPerImage * depth;
    return rowBytes * rows * depth;
}

MTLRegion SlotRegion(const LC32MetalCall &call, size_t index) {
    return MTLRegionMake3D(call.slots[index], call.slots[index + 1],
        call.slots[index + 2], call.slots[index + 3], call.slots[index + 4],
        call.slots[index + 5]);
}

constexpr size_t kMaximumTransfer = 512u * 1024u * 1024u;

/* Releases the guest view of a Metal buffer's storage with the buffer. */
const void *kGuestMappingKey = &kGuestMappingKey;

}  // namespace

@interface LC32MetalGuestMapping : NSObject {
@public
    uint32_t guestBase;
    uint64_t size;
    const void *hostBase;
}
@end

@implementation LC32MetalGuestMapping
- (void)dealloc {
    /* Metal may release the buffer after the guest VM is gone. */
    if(guestBase) (void)Dynarmic_munmap_direct(guestBase, size, hostBase);
}
@end

namespace {

/*
 * -[MTLBuffer contents] is a host pointer. Map the pages holding it into the
 * guest address space (Dynarmic_direct_mmap leaves host ownership alone), so
 * the game writes vertex and uniform data straight into the buffer the GPU
 * reads. The mapping is created once per buffer and removed when it dies.
 */
uint32_t GuestContents(id<MTLBuffer> buffer) {
    @synchronized(buffer) {
        LC32MetalGuestMapping *mapping =
            objc_getAssociatedObject(buffer, kGuestMappingKey);
        const uint64_t host = (uint64_t)(uintptr_t)buffer.contents;
        if(!host) return 0;
        const uint64_t base = host & ~DYN_PAGE_MASK;
        if(mapping) return mapping->guestBase + (uint32_t)(host - base);

        const uint64_t length = std::max<NSUInteger>(buffer.length, 1);
        const uint64_t end = (host + length + DYN_PAGE_MASK) & ~DYN_PAGE_MASK;
        const uint32_t guest = Dynarmic_direct_mmap(0, end - base,
            PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS,
            reinterpret_cast<void *>(base), 0,
            /*volatileExternal=*/true);
        if(guest == UINT32_MAX || guest == 0) {
            fprintf(stderr, "LC32 Metal: could not map %llu-byte buffer "
                "contents into the guest\n", (unsigned long long)length);
            return 0;
        }
        mapping = [LC32MetalGuestMapping new];
        mapping->guestBase = guest;
        mapping->size = end - base;
        mapping->hostBase = reinterpret_cast<const void *>(base);
        objc_setAssociatedObject(buffer, kGuestMappingKey, mapping,
            OBJC_ASSOCIATION_RETAIN);
        return guest + (uint32_t)(host - base);
    }
}

uint32_t WriteGuestError(uint32_t guestErrorOut, NSError *error) {
    if(!guestErrorOut) return 0;
    const u32 guestError = error ? [error guest_self] : 0;
    return Dynarmic_mem_1write(guestErrorOut, sizeof(guestError),
        reinterpret_cast<char *>(const_cast<u32 *>(&guestError)));
}

bool IsDepthOrStencilFormat(MTLPixelFormat format) {
    switch(format) {
        case MTLPixelFormatDepth16Unorm:
        case MTLPixelFormatDepth32Float:
        case MTLPixelFormatStencil8:
        case MTLPixelFormatDepth32Float_Stencil8:
        case MTLPixelFormatX32_Stencil8:
            return true;
        default:
            /* Depth24Unorm_Stencil8 (255) / X24_Stencil8 (262) are macOS
             * only names in the iOS SDK. */
            return format == 255 || format == 262;
    }
}

/*
 * iOS 8 Metal had no storage modes or usage flags. Current Metal defaults
 * textures to shared storage and shader-read-only usage, and rejects shared
 * multisample (and, on some GPUs, depth/stencil) textures. A guest built
 * before those existed cannot express what it needs, so give render-only
 * textures private storage and leave the usage open.
 */
id<MTLTexture> NewGuestTexture(id<MTLDevice> device,
                               MTLTextureDescriptor *guestDescriptor) {
    MTLTextureDescriptor *descriptor = [guestDescriptor copy];
    /* Usage flags and storage modes arrived with the iOS 9 SDK. */
    const bool legacyGuest = LC32GetGuestExecutableSDKVersion() < 0x90000;
    if(legacyGuest && descriptor.usage == MTLTextureUsageShaderRead)
        descriptor.usage = MTLTextureUsageUnknown;
    const bool multisample = descriptor.sampleCount > 1 ||
        descriptor.textureType == MTLTextureType2DMultisample;
    if((multisample || (legacyGuest &&
            IsDepthOrStencilFormat(descriptor.pixelFormat))) &&
            descriptor.storageMode == MTLStorageModeShared)
        descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if(!texture) {
        fprintf(stderr, "LC32 Metal: newTextureWithDescriptor failed: "
            "type %lu format %lu %lux%lux%lu mips %lu samples %lu\n",
            (unsigned long)descriptor.textureType,
            (unsigned long)descriptor.pixelFormat,
            (unsigned long)descriptor.width, (unsigned long)descriptor.height,
            (unsigned long)descriptor.depth,
            (unsigned long)descriptor.mipmapLevelCount,
            (unsigned long)descriptor.sampleCount);
    }
    return texture;
}

uint32_t DispatchHalting(uint32_t opcode, const LC32MetalCall &call) {
#define REQUIRE(count) \
    do { if(call.slotCount != (count)) { LogOnce(opcode, "bad slot count"); \
        return 0; } } while(0)
#define S(index) call.slots[index]
#define RECEIVER(type, name) \
    type name = HostObject(call.slots[0]); \
    if(!name) { LogOnce(opcode, "receiver has no host object"); return 0; }
    switch(opcode) {
        case LC32MetalOpTextureReplaceRegion: {
            REQUIRE(12);
            RECEIVER(id<MTLTexture>, texture);
            const MTLRegion region = SlotRegion(call, 1);
            const NSUInteger level = S(7), slice = S(8);
            const uint32_t bytes = (uint32_t)S(9);
            const NSUInteger bytesPerRow = S(10), bytesPerImage = S(11);
            const size_t length = RegionBytes(texture, region, bytesPerRow,
                bytesPerImage);
            if(!bytes || !length || length > kMaximumTransfer) {
                LogOnce(opcode, "texture upload without data");
                return 0;
            }
            std::vector<uint8_t> scratch;
            const void *source = ContiguousHostRange(bytes, length);
            if(!source) {
                scratch.resize(length);
                ReadGuestTolerant(bytes, length, scratch.data());
                source = scratch.data();
            }
            [texture replaceRegion:region mipmapLevel:level slice:slice
                         withBytes:source bytesPerRow:bytesPerRow
                     bytesPerImage:bytesPerImage];
            return 0;
        }
        case LC32MetalOpTextureGetBytes: {
            REQUIRE(12);
            RECEIVER(id<MTLTexture>, texture);
            const uint32_t bytes = (uint32_t)S(1);
            const NSUInteger bytesPerRow = S(2), bytesPerImage = S(3);
            const MTLRegion region = SlotRegion(call, 4);
            const NSUInteger level = S(10), slice = S(11);
            const size_t length = RegionBytes(texture, region, bytesPerRow,
                bytesPerImage);
            if(!bytes || !length || length > kMaximumTransfer) return 0;
            char *direct = ContiguousHostRange(bytes, length);
            std::vector<uint8_t> scratch;
            if(!direct) {
                /* Keep bytes Metal does not write (row padding). */
                scratch.resize(length);
                ReadGuestTolerant(bytes, length, scratch.data());
            }
            [texture getBytes:direct ? (void *)direct : scratch.data()
                  bytesPerRow:bytesPerRow bytesPerImage:bytesPerImage
                   fromRegion:region mipmapLevel:level slice:slice];
            if(!direct)
                (void)Dynarmic_mem_1write(bytes, length,
                    reinterpret_cast<char *>(scratch.data()));
            return 0;
        }
        case LC32MetalOpDeviceNewTexture: {
            if(call.slotCount != 2) break;
            id<MTLDevice> device = HostObject(call.slots[0]);
            MTLTextureDescriptor *descriptor = HostObject(call.slots[1]);
            if(!device || !descriptor) return 0;
            id<MTLTexture> texture = NewGuestTexture(device, descriptor);
            return texture ? LC32GuestObjectForOwnedHostObject(
                (__bridge_retained CFTypeRef)texture) : 0;
        }
        case LC32MetalOpBufferContents: {
            if(call.slotCount != 1) break;
            id<MTLBuffer> buffer = HostObject(call.slots[0]);
            if(!buffer) { LogOnce(opcode, "no host buffer"); return 0; }
            return GuestContents(buffer);
        }
        case LC32MetalOpDeviceNewLibraryWithData: {
            if(call.slotCount != 4) break;
            id<MTLDevice> device = HostObject(call.slots[0]);
            const uint32_t bytes = (uint32_t)call.slots[1];
            const size_t length = (size_t)call.slots[2];
            const uint32_t errorOut = (uint32_t)call.slots[3];
            if(!device || !bytes || !length || length > kMaximumTransfer) {
                /* Autoreleased, so it outlives this call like a native
                 * error out-parameter. */
                __autoreleasing NSError *error = [NSError
                    errorWithDomain:@"MTLLibraryErrorDomain" code:1
                    userInfo:nil];
                WriteGuestError(errorOut, error);
                return 0;
            }
            std::vector<uint8_t> scratch;
            const void *source = ContiguousHostRange(bytes, length);
            if(!source) {
                scratch.resize(length);
                ReadGuestTolerant(bytes, length, scratch.data());
                source = scratch.data();
            }
            dispatch_data_t data = dispatch_data_create(source, length,
                nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            NSError *error = nil;
            id<MTLLibrary> library = [device newLibraryWithData:data
                                                          error:&error];
            if(!library) {
                fprintf(stderr, "LC32 Metal: newLibraryWithData (%zu bytes) "
                    "failed: %s\n", length,
                    error.description.UTF8String ?: "(no error)");
                WriteGuestError(errorOut, error);
                return 0;
            }
            if(errorOut) WriteGuestError(errorOut, nil);
            return LC32GuestObjectForOwnedHostObject(
                (__bridge_retained CFTypeRef)library);
        }
        case LC32MetalOpDeviceNewBufferWithBytes: {
            if(call.slotCount != 4) break;
            id<MTLDevice> device = HostObject(call.slots[0]);
            const uint32_t bytes = (uint32_t)call.slots[1];
            const size_t length = (size_t)call.slots[2];
            const MTLResourceOptions options =
                (MTLResourceOptions)call.slots[3];
            if(!device || !bytes || !length || length > kMaximumTransfer)
                return 0;
            std::vector<uint8_t> scratch;
            const void *source = ContiguousHostRange(bytes, length);
            if(!source) {
                scratch.resize(length);
                ReadGuestTolerant(bytes, length, scratch.data());
                source = scratch.data();
            }
            id<MTLBuffer> buffer = [device newBufferWithBytes:source
                                                       length:length
                                                      options:options];
            return buffer ? LC32GuestObjectForOwnedHostObject(
                (__bridge_retained CFTypeRef)buffer) : 0;
        }
    }
#undef REQUIRE
#undef S
#undef RECEIVER
    LogOnce(opcode, "bad halting call");
    return 0;
}

uint32_t DispatchInline(uint32_t opcode, const LC32MetalCall &call) {
#define REQUIRE(count) \
    do { if(call.slotCount != (count)) { LogOnce(opcode, "bad slot count"); \
        return 0; } } while(0)
#define S(index) call.slots[index]
#define OBJ(index) HostObject(call.slots[index])
#define RECEIVER(type, name) \
    type name = OBJ(0); \
    if(!name) { LogOnce(opcode, "receiver has no host object"); return 0; }

    switch(opcode) {
        case LC32MetalOpEncoderEndEncoding: {
            REQUIRE(1);
            RECEIVER(id<MTLCommandEncoder>, encoder);
            [encoder endEncoding];
            return 0;
        }
        case LC32MetalOpRenderSetPipelineState: {
            REQUIRE(2);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setRenderPipelineState:OBJ(1)];
            return 0;
        }
        case LC32MetalOpRenderSetDepthStencilState: {
            REQUIRE(2);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setDepthStencilState:OBJ(1)];
            return 0;
        }
        case LC32MetalOpRenderSetVertexBuffer: {
            REQUIRE(4);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setVertexBuffer:OBJ(1) offset:S(2) atIndex:S(3)];
            return 0;
        }
        case LC32MetalOpRenderSetFragmentBuffer: {
            REQUIRE(4);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setFragmentBuffer:OBJ(1) offset:S(2) atIndex:S(3)];
            return 0;
        }
        case LC32MetalOpRenderSetVertexBufferOffset: {
            REQUIRE(3);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setVertexBufferOffset:S(1) atIndex:S(2)];
            return 0;
        }
        case LC32MetalOpRenderSetFragmentBufferOffset: {
            REQUIRE(3);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setFragmentBufferOffset:S(1) atIndex:S(2)];
            return 0;
        }
        case LC32MetalOpRenderSetVertexTexture: {
            REQUIRE(3);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setVertexTexture:OBJ(1) atIndex:S(2)];
            return 0;
        }
        case LC32MetalOpRenderSetFragmentTexture: {
            REQUIRE(3);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setFragmentTexture:OBJ(1) atIndex:S(2)];
            return 0;
        }
        case LC32MetalOpRenderSetVertexSamplerState: {
            REQUIRE(3);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setVertexSamplerState:OBJ(1) atIndex:S(2)];
            return 0;
        }
        case LC32MetalOpRenderSetFragmentSamplerState: {
            REQUIRE(3);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setFragmentSamplerState:OBJ(1) atIndex:S(2)];
            return 0;
        }
        case LC32MetalOpRenderSetViewport: {
            REQUIRE(7);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            const MTLViewport viewport = {
                SlotDouble(S(1)), SlotDouble(S(2)), SlotDouble(S(3)),
                SlotDouble(S(4)), SlotDouble(S(5)), SlotDouble(S(6)),
            };
            [encoder setViewport:viewport];
            return 0;
        }
        case LC32MetalOpRenderSetScissorRect: {
            REQUIRE(5);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            const MTLScissorRect rect = { S(1), S(2), S(3), S(4) };
            [encoder setScissorRect:rect];
            return 0;
        }
        case LC32MetalOpRenderSetFrontFacingWinding: {
            REQUIRE(2);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setFrontFacingWinding:(MTLWinding)S(1)];
            return 0;
        }
        case LC32MetalOpRenderSetCullMode: {
            REQUIRE(2);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setCullMode:(MTLCullMode)S(1)];
            return 0;
        }
        case LC32MetalOpRenderSetDepthBias: {
            REQUIRE(4);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setDepthBias:SlotFloat(S(1)) slopeScale:SlotFloat(S(2))
                            clamp:SlotFloat(S(3))];
            return 0;
        }
        case LC32MetalOpRenderSetVisibilityResultMode: {
            REQUIRE(3);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setVisibilityResultMode:(MTLVisibilityResultMode)S(1)
                                      offset:S(2)];
            return 0;
        }
        case LC32MetalOpRenderSetStencilReferenceValue: {
            REQUIRE(2);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setStencilReferenceValue:(uint32_t)S(1)];
            return 0;
        }
        case LC32MetalOpRenderSetStencilFrontBackReferenceValue: {
            REQUIRE(3);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setStencilFrontReferenceValue:(uint32_t)S(1)
                                backReferenceValue:(uint32_t)S(2)];
            return 0;
        }
        case LC32MetalOpRenderSetBlendColor: {
            REQUIRE(5);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setBlendColorRed:SlotFloat(S(1)) green:SlotFloat(S(2))
                                 blue:SlotFloat(S(3))
                                alpha:SlotFloat(S(4))];
            return 0;
        }
        case LC32MetalOpRenderSetTriangleFillMode: {
            REQUIRE(2);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setTriangleFillMode:(MTLTriangleFillMode)S(1)];
            return 0;
        }
        case LC32MetalOpRenderSetDepthClipMode: {
            REQUIRE(2);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder setDepthClipMode:(MTLDepthClipMode)S(1)];
            return 0;
        }
        case LC32MetalOpRenderDrawPrimitives: {
            REQUIRE(5);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            [encoder drawPrimitives:(MTLPrimitiveType)S(1) vertexStart:S(2)
                        vertexCount:S(3) instanceCount:S(4)];
            return 0;
        }
        case LC32MetalOpRenderDrawIndexedPrimitives: {
            REQUIRE(7);
            RECEIVER(id<MTLRenderCommandEncoder>, encoder);
            id<MTLBuffer> indexBuffer = OBJ(4);
            if(!indexBuffer) {
                LogOnce(opcode, "indexed draw without index buffer");
                return 0;
            }
            [encoder drawIndexedPrimitives:(MTLPrimitiveType)S(1)
                                indexCount:S(2)
                                 indexType:(MTLIndexType)S(3)
                               indexBuffer:indexBuffer
                         indexBufferOffset:S(5)
                             instanceCount:S(6)];
            return 0;
        }
        case LC32MetalOpBlitCopyTextureToTexture: {
            REQUIRE(16);
            RECEIVER(id<MTLBlitCommandEncoder>, encoder);
            [encoder copyFromTexture:OBJ(1) sourceSlice:S(2)
                         sourceLevel:S(3)
                        sourceOrigin:MTLOriginMake(S(4), S(5), S(6))
                          sourceSize:MTLSizeMake(S(7), S(8), S(9))
                           toTexture:OBJ(10) destinationSlice:S(11)
                    destinationLevel:S(12)
                   destinationOrigin:MTLOriginMake(S(13), S(14), S(15))];
            return 0;
        }
        case LC32MetalOpBlitCopyBufferToBuffer: {
            REQUIRE(6);
            RECEIVER(id<MTLBlitCommandEncoder>, encoder);
            [encoder copyFromBuffer:OBJ(1) sourceOffset:S(2) toBuffer:OBJ(3)
                  destinationOffset:S(4) size:S(5)];
            return 0;
        }
        case LC32MetalOpBlitCopyBufferToTexture: {
            REQUIRE(15);
            RECEIVER(id<MTLBlitCommandEncoder>, encoder);
            [encoder copyFromBuffer:OBJ(1) sourceOffset:S(2)
                  sourceBytesPerRow:S(3) sourceBytesPerImage:S(4)
                         sourceSize:MTLSizeMake(S(5), S(6), S(7))
                          toTexture:OBJ(8) destinationSlice:S(9)
                   destinationLevel:S(10)
                  destinationOrigin:MTLOriginMake(S(11), S(12), S(13))
                            options:(MTLBlitOption)S(14)];
            return 0;
        }
        case LC32MetalOpBlitCopyTextureToBuffer: {
            REQUIRE(15);
            RECEIVER(id<MTLBlitCommandEncoder>, encoder);
            [encoder copyFromTexture:OBJ(1) sourceSlice:S(2)
                         sourceLevel:S(3)
                        sourceOrigin:MTLOriginMake(S(4), S(5), S(6))
                          sourceSize:MTLSizeMake(S(7), S(8), S(9))
                            toBuffer:OBJ(10) destinationOffset:S(11)
              destinationBytesPerRow:S(12) destinationBytesPerImage:S(13)
                             options:(MTLBlitOption)S(14)];
            return 0;
        }
        case LC32MetalOpSetInteger: {
            REQUIRE(3);
            RECEIVER(id, object);
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(object,
                (SEL)(uintptr_t)S(1), (NSUInteger)S(2));
            return 0;
        }
        case LC32MetalOpGetInteger: {
            REQUIRE(2);
            RECEIVER(id, object);
            return (uint32_t)((NSUInteger (*)(id, SEL))objc_msgSend)(object,
                (SEL)(uintptr_t)S(1));
        }
        case LC32MetalOpGetObject:
        case LC32MetalOpGetObjectAtIndex: {
            const bool indexed = opcode == LC32MetalOpGetObjectAtIndex;
            REQUIRE(indexed ? 3 : 2);
            RECEIVER(id, object);
            const SEL selector = (SEL)(uintptr_t)S(1);
            id result = indexed
                ? ((id (*)(id, SEL, NSUInteger))objc_msgSend)(object,
                    selector, (NSUInteger)S(2))
                : ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if(!result) return 0;
            /* An existing proxy is returned as -guest_self would; making a
             * new one runs guest code. */
            const u32 guestObject = [result guest_selfOrNull];
            return guestObject && guestObject != LC32MetalInlineFallback
                ? guestObject : LC32MetalInlineFallback;
        }
        case LC32MetalOpSetObject: {
            REQUIRE(3);
            RECEIVER(id, object);
            id value = OBJ(2);
            if(S(2) && !value) return LC32MetalInlineFallback;
            ((void (*)(id, SEL, id))objc_msgSend)(object,
                (SEL)(uintptr_t)S(1), value);
            return 0;
        }
        case LC32MetalOpBlitGenerateMipmaps: {
            REQUIRE(2);
            RECEIVER(id<MTLBlitCommandEncoder>, encoder);
            [encoder generateMipmapsForTexture:OBJ(1)];
            return 0;
        }
    }
#undef REQUIRE
#undef S
#undef OBJ
#undef RECEIVER
    LogOnce(opcode, "unknown inline call");
    return 0;
}

}  // namespace

extern "C" uint32_t LC32_Metal_Dispatch(uint32_t opcode, uint32_t guestCall,
                                        uint32_t) {
    LC32MetalCall call = {};
    if(!ReadCall(guestCall, call)) {
        LogOnce(opcode, "unreadable call");
        return 0;
    }
    if(opcode >= LC32MetalOpFirstInline) {
        InlineHostCallScope scope;
        @autoreleasepool {
            return DispatchInline(opcode, call);
        }
    }
    /* Object results stay in the caller's autorelease pool, like every
     * other bridged Objective-C result. */
    return DispatchHalting(opcode, call);
}

/* LC32_PROFILE: name inline calls by the selector they send (property
 * accessors) or by opcode ("-LC32MetalInline54"). */
static void ProfileInlineCall(uint32_t opcode, const LC32MetalCall &call,
                              uint64_t start) {
    const uint64_t ticks = mach_absolute_time() - start;
    const bool bySelector = opcode >= LC32MetalOpSetInteger &&
        opcode <= LC32MetalOpSetObject && call.slotCount >= 2;
    if(bySelector) {
        LC32ProfileAddHostCall((const void *)(uintptr_t)call.slots[1], 1,
            ticks);
        return;
    }
    static SEL names[128];
    if(opcode >= 128) return;
    SEL name = __atomic_load_n(&names[opcode], __ATOMIC_ACQUIRE);
    if(!name) {
        char text[40];
        snprintf(text, sizeof(text), "LC32MetalInline%u", opcode);
        name = sel_registerName(text);
        __atomic_store_n(&names[opcode], name, __ATOMIC_RELEASE);
    }
    LC32ProfileAddHostCall((const void *)name, 1, ticks);
}

/* Called from inside the guest JIT (SVC 1002 fast path): no guest code may
 * run here, so only the inline opcodes are accepted. */
extern "C" uint32_t LC32_Metal_DispatchInline(uint32_t opcode,
                                              uint32_t guestCall, uint32_t) {
    if(opcode < LC32MetalOpFirstInline) {
        LogOnce(opcode, "halting opcode sent inline");
        return 0;
    }
    const uint64_t start = LC32ProfileNow();
    LC32MetalCall call = {};
    if(!ReadCall(guestCall, call)) {
        LogOnce(opcode, "unreadable call");
        return 0;
    }
    uint32_t result;
    {
        InlineHostCallScope scope;
        @autoreleasepool {
            result = DispatchInline(opcode, call);
        }
    }
    if(start) ProfileInlineCall(opcode, call, start);
    return result;
}

/*
 * Guest class for a native Metal object. Their classes are private
 * (AGX..., MTLSim..., MTLDebug... wrappers), so the class-name walk in
 * -guest_self ends at NSObject. Pick the guest proxy class for the protocol
 * the object implements instead. Returns 0 when this is no Metal object or
 * the guest Metal framework is not loaded.
 */
extern "C" u32 LC32MetalGuestProxyClass(id object) {
    static const struct {
        const char *protocol;
        const char *guestClass;
    } candidates[] = {
        /* Most specific first: drawables, buffers and textures are also
         * MTLResource/MTLDrawable; encoders are also MTLCommandEncoder. */
        { "CAMetalDrawable", "LC32CAMetalDrawable" },
        { "MTLBuffer", "LC32MTLBuffer" },
        { "MTLTexture", "LC32MTLTexture" },
        { "MTLRenderCommandEncoder", "LC32MTLRenderCommandEncoder" },
        { "MTLBlitCommandEncoder", "LC32MTLBlitCommandEncoder" },
        { "MTLCommandEncoder", "LC32MTLCommandEncoder" },
        { "MTLCommandBuffer", "LC32MTLCommandBuffer" },
        { "MTLCommandQueue", "LC32MTLCommandQueue" },
        { "MTLDevice", "LC32MTLDevice" },
        { "MTLLibrary", "LC32MTLLibrary" },
        { "MTLFunction", "LC32MTLFunction" },
        { "MTLRenderPipelineState", "LC32MTLObject" },
        { "MTLDepthStencilState", "LC32MTLObject" },
        { "MTLSamplerState", "LC32MTLObject" },
        { "MTLComputePipelineState", "LC32MTLObject" },
        { "MTLResource", "LC32MTLObject" },
    };
    if(!object || !objc_getProtocol("MTLDevice")) return 0;

    static std::mutex cacheMutex;
    static std::unordered_map<Class, const char *> cache;
    Class cls = object_getClass(object);
    const char *guestClassName = nullptr;
    bool cached = false;
    {
        std::lock_guard<std::mutex> lock(cacheMutex);
        auto found = cache.find(cls);
        if(found != cache.end()) {
            guestClassName = found->second;
            cached = true;
        }
    }
    if(!cached) {
        for(const auto &candidate : candidates) {
            Protocol *protocol = objc_getProtocol(candidate.protocol);
            if(protocol && [object conformsToProtocol:protocol]) {
                guestClassName = candidate.guestClass;
                break;
            }
        }
        std::lock_guard<std::mutex> lock(cacheMutex);
        cache[cls] = guestClassName;
    }
    return guestClassName ? guest_objc_getClass(guestClassName) : 0;
}
