#import <CoreMotion/CoreMotion.h>
#import <LC32/LC32.h>

/*
 * The shim generator cannot express CoreMotion's anonymous double structs, so
 * the generated getters are compiled out and clang synthesizes plain readers
 * of the guest object's own (never written) ivars: every reading was zero.
 * Nuts! steers with -[CMAccelerometerData acceleration] and never moved.
 *
 * These are all double-only HFAs (3 or 4 members), identical on ARMv7 and
 * ARM64, which the host bridge returns from d0-d3. Selectors are fixed rather
 * than taken from _cmd so a guest swizzle cannot change what is forwarded.
 */

typedef struct { double a, b, c; } LC32CMThreeDoubles;
typedef struct { double a, b, c, d; } LC32CMFourDoubles;

#define LC32_CM_STRUCT_GETTER(CLASS, TYPE, NAME, STORAGE)                   \
    @implementation CLASS (LC32Struct_##NAME)                                \
    - (TYPE)NAME {                                                           \
        static uint64_t hostSelector __attribute__((aligned(8)));            \
        const uint64_t selector = LC32CachedHostSelector(                    \
            &hostSelector, @selector(NAME), YES);                            \
        STORAGE value = {0};                                                 \
        LC32InvokeHostSelector(self.host_self, selector, &value,            \
                               sizeof(value), (uint64_t)0);                  \
        TYPE result;                                                         \
        _Static_assert(sizeof(result) == sizeof(value), #TYPE " layout");    \
        memcpy(&result, &value, sizeof(result));                             \
        return result;                                                       \
    }                                                                        \
    @end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"

LC32_CM_STRUCT_GETTER(CMAccelerometerData, CMAcceleration, acceleration,
                      LC32CMThreeDoubles)
LC32_CM_STRUCT_GETTER(CMGyroData, CMRotationRate, rotationRate,
                      LC32CMThreeDoubles)
LC32_CM_STRUCT_GETTER(CMMagnetometerData, CMMagneticField, magneticField,
                      LC32CMThreeDoubles)
LC32_CM_STRUCT_GETTER(CMDeviceMotion, CMAcceleration, gravity,
                      LC32CMThreeDoubles)
LC32_CM_STRUCT_GETTER(CMDeviceMotion, CMAcceleration, userAcceleration,
                      LC32CMThreeDoubles)
LC32_CM_STRUCT_GETTER(CMDeviceMotion, CMRotationRate, rotationRate,
                      LC32CMThreeDoubles)
LC32_CM_STRUCT_GETTER(CMAttitude, CMQuaternion, quaternion,
                      LC32CMFourDoubles)

#pragma clang diagnostic pop
