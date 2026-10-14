// Private macOS interfaces used read-only for sensors. Declarations follow exelban/stats
// (MIT, Modules/CPU/bridge.h and SMC/smc.swift); see THIRD_PARTY_NOTICES.md.
#ifndef CSYSTEMPRIVATE_H
#define CSYSTEMPRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// AppleSMC user-client structure (IOConnectCallStructMethod selector 2).
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;
_Static_assert(sizeof(SMCKeyData) == 80, "AppleSMC expects an 80-byte structure");

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

CFDictionaryRef _Nullable IOReportCopyChannelsInGroup(CFStringRef _Nullable group, CFStringRef _Nullable subgroup,
                                                      uint64_t a, uint64_t b, uint64_t c) CF_RETURNS_RETAINED;
IOReportSubscriptionRef _Nullable IOReportCreateSubscription(void *_Nullable a, CFMutableDictionaryRef _Nonnull channels,
                                                             CFMutableDictionaryRef _Nullable *_Nonnull subscribed,
                                                             uint64_t b, CFTypeRef _Nullable c);
CFDictionaryRef _Nullable IOReportCreateSamples(IOReportSubscriptionRef _Nonnull subscription,
                                                CFMutableDictionaryRef _Nonnull channels, CFTypeRef _Nullable a) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamplesDelta(CFDictionaryRef _Nonnull previous, CFDictionaryRef _Nonnull current,
                                                     CFTypeRef _Nullable a) CF_RETURNS_RETAINED;
CFStringRef _Nullable IOReportChannelGetSubGroup(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetChannelName(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
int32_t IOReportStateGetCount(CFDictionaryRef _Nonnull channel);
CFStringRef _Nullable IOReportStateGetNameForIndex(CFDictionaryRef _Nonnull channel, int32_t index) CF_RETURNS_NOT_RETAINED;
int64_t IOReportStateGetResidency(CFDictionaryRef _Nonnull channel, int32_t index);

#endif
