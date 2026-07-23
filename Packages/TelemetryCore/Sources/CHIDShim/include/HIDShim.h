#ifndef HIDSHIM_H
#define HIDSHIM_H

#include <CoreFoundation/CoreFoundation.h>

// Hand-declared prototypes for the private IOHIDEventSystemClient API used to
// read Apple Silicon temperature sensors with human-readable names, exactly as
// exelban/stats (Modules/Sensors/bridge.h) and fermion-star/apple_sensors
// (temp_sensor.m) do. Private API: fine for a direct-distributed app,
// disqualifying for the Mac App Store (which is off the table anyway).

typedef struct CF_BRIDGED_TYPE(id) __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef _Nonnull client, CFDictionaryRef _Nonnull match);
CFArrayRef _Nullable IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef _Nonnull client) CF_RETURNS_RETAINED;
CFTypeRef _Nullable IOHIDServiceClientCopyProperty(IOHIDServiceClientRef _Nonnull service, CFStringRef _Nonnull property) CF_RETURNS_RETAINED;
IOHIDEventRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef _Nonnull service, int64_t type, int32_t options, int64_t timestamp) CF_RETURNS_RETAINED;
double IOHIDEventGetFloatValue(IOHIDEventRef _Nonnull event, int32_t field);

// kHIDPage_AppleVendor / kHIDUsage_AppleVendor_TemperatureSensor
#define HIDSHIM_USAGE_PAGE_APPLE_VENDOR 0xff00
#define HIDSHIM_USAGE_TEMPERATURE_SENSOR 5
// kIOHIDEventTypeTemperature; field base = type << 16
#define HIDSHIM_EVENT_TYPE_TEMPERATURE 15

#endif
