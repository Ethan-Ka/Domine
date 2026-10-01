/*
 * Domine virtual output device (SPEC section 3.3).
 *
 * An AudioServerPlugIn that publishes one output-only device, "Domine",
 * with UID com.ethankawley.Domine.VirtualOutput. It discards all audio
 * (null sink) but runs a steady clock, and has a settable volume and mute
 * that Domine mirrors to the speakers. The layout follows Apple's NullAudio
 * sample: one plug-in object, one device, one output stream, and two
 * controls, all with fixed object IDs.
 *
 * Threading:
 * - Property and lifecycle calls (Initialize, Get/SetPropertyData,
 *   StartIO/StopIO, configuration changes) come from HAL worker threads.
 *   Their mutable state (volume, mute, stream active, IO client count)
 *   is guarded by gStateMutex, as in Apple's sample. These are not
 *   real-time paths.
 * - IO calls (GetZeroTimeStamp, WillDo/Begin/Do/EndIOOperation) run on the
 *   real-time IO thread. They take no locks and allocate nothing. The few
 *   values they need (clock anchor, period count, ticks per frame) are C11
 *   atomics written by StartIO or a configuration change while IO for
 *   this device is stopped.
 */

#include "include/DomineDriverMath.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

/* MARK: - Constants */

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream_Output = 3,
    kObjectID_Volume_Output_Main = 4,
    kObjectID_Mute_Output_Main = 5,
};

#define kDevice_Name CFSTR("Domine")
#define kManufacturer_Name CFSTR("Domine")
#define kDevice_UID CFSTR("com.ethankawley.Domine.VirtualOutput")
#define kDevice_ModelUID CFSTR("com.ethankawley.Domine.VirtualOutput.Model")
#define kStorageKey_Volume CFSTR("volume")
#define kStorageKey_Mute CFSTR("mute")
#define kStorageKey_SampleRate CFSTR("sample rate")

static const UInt32 kChannelCount = 2;
static const UInt32 kBitsPerChannel = 32;
static const UInt32 kBytesPerFrame = 8; /* 2 channels of Float32, interleaved */
/* Frames between zero timestamps; same as the NullAudio sample's ring buffer. */
static const UInt32 kZeroTimeStampPeriod = 16384;
static const Float64 kSupportedRates[] = {44100.0, 48000.0};
static const UInt32 kSupportedRateCount = sizeof(kSupportedRates) / sizeof(kSupportedRates[0]);
static const Float32 kDefaultVolume = 0.5f;

/* MARK: - State */

static AudioServerPlugInHostRef gHost = NULL;
static _Atomic UInt32 gRefCount = 0;

/* Guarded by gStateMutex. */
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static Float32 gVolumeScalar = kDefaultVolume;
static bool gMuted = false;
static bool gStreamActive = true;
static UInt32 gIOClientCount = 0;

/* Read on the IO thread; written only while IO is stopped (StartIO, configuration change). */
static _Atomic double gSampleRate = 44100.0; /* JBL Grip rate; Domine matches it (SPEC 4a) */
static _Atomic double gTicksPerFrame = 0.0;
static _Atomic uint64_t gAnchorHostTime = 0;
/* Written by the IO thread (GetZeroTimeStamp) and reset by StartIO. */
static _Atomic uint64_t gPeriodCount = 0;

/* MARK: - Interface declarations */

static HRESULT Domine_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG Domine_AddRef(void *inDriver);
static ULONG Domine_Release(void *inDriver);
static OSStatus Domine_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Domine_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                    const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus Domine_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Domine_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Domine_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Domine_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                        UInt64 inChangeAction, void *inChangeInfo);
static OSStatus Domine_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                      UInt64 inChangeAction, void *inChangeInfo);
static Boolean Domine_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                  const AudioObjectPropertyAddress *inAddress);
static OSStatus Domine_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus Domine_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                           const void *inQualifierData, UInt32 *outDataSize);
static OSStatus Domine_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                       const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus Domine_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                       const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus Domine_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Domine_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Domine_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus Domine_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                         UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus Domine_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus Domine_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                     UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus Domine_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Domine_QueryInterface,
    Domine_AddRef,
    Domine_Release,
    Domine_Initialize,
    Domine_CreateDevice,
    Domine_DestroyDevice,
    Domine_AddDeviceClient,
    Domine_RemoveDeviceClient,
    Domine_PerformDeviceConfigurationChange,
    Domine_AbortDeviceConfigurationChange,
    Domine_HasProperty,
    Domine_IsPropertySettable,
    Domine_GetPropertyDataSize,
    Domine_GetPropertyData,
    Domine_SetPropertyData,
    Domine_StartIO,
    Domine_StopIO,
    Domine_GetZeroTimeStamp,
    Domine_WillDoIOOperation,
    Domine_BeginIOOperation,
    Domine_DoIOOperation,
    Domine_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

/* MARK: - Factory */

/* Named in Info.plist under CFPlugInFactories. */
__attribute__((visibility("default")))
void *DomineDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void *DomineDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

/* MARK: - Helpers */

static bool is_driver(const void *inDriver) { return inDriver == gDriverRef; }

static void lock_state(void) { pthread_mutex_lock(&gStateMutex); }
static void unlock_state(void) { pthread_mutex_unlock(&gStateMutex); }

static void update_ticks_per_frame(double rate) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    atomic_store(&gTicksPerFrame, domine_driver_ticks_per_frame(rate, timebase.numer, timebase.denom));
}

static AudioStreamBasicDescription stream_format(Float64 rate) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannelCount;
    f.mBitsPerChannel = kBitsPerChannel;
    return f;
}

/* Copies one value. With outData NULL, only reports the size. */
static OSStatus put(const void *src, UInt32 size, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (outData == NULL) {
        *outDataSize = size;
        return kAudioHardwareNoError;
    }
    if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
    memcpy(outData, src, size);
    *outDataSize = size;
    return kAudioHardwareNoError;
}

/* Copies as many items of an array as fit, like the NullAudio sample. */
static OSStatus put_array(const void *src, UInt32 itemSize, UInt32 count, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (outData == NULL) {
        *outDataSize = itemSize * count;
        return kAudioHardwareNoError;
    }
    UInt32 n = inDataSize / itemSize;
    if (n > count) n = count;
    if (n > 0) memcpy(outData, src, (size_t)n * itemSize);
    *outDataSize = n * itemSize;
    return kAudioHardwareNoError;
}

#define PUT(value) put(&(value), (UInt32)sizeof(value), inDataSize, outDataSize, outData)

static void notify(AudioObjectID objectID, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    if (gHost != NULL && count > 0) gHost->PropertiesChanged(gHost, objectID, count, addresses);
}

static void store_float(CFStringRef key, Float32 value) {
    if (gHost == NULL) return;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberFloat32Type, &value);
    if (number == NULL) return;
    gHost->WriteToStorage(gHost, key, number);
    CFRelease(number);
}

static void store_double(CFStringRef key, Float64 value) {
    if (gHost == NULL) return;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberFloat64Type, &value);
    if (number == NULL) return;
    gHost->WriteToStorage(gHost, key, number);
    CFRelease(number);
}

static void store_bool(CFStringRef key, bool value) {
    if (gHost == NULL) return;
    gHost->WriteToStorage(gHost, key, value ? kCFBooleanTrue : kCFBooleanFalse);
}

/* Reads a stored number or boolean. Returns false if missing or the wrong type. */
static bool load_double(CFStringRef key, double *outValue) {
    CFPropertyListRef data = NULL;
    if (gHost == NULL || gHost->CopyFromStorage(gHost, key, &data) != kAudioHardwareNoError || data == NULL) return false;
    bool ok = false;
    if (CFGetTypeID(data) == CFNumberGetTypeID()) {
        ok = CFNumberGetValue((CFNumberRef)data, kCFNumberFloat64Type, outValue);
    } else if (CFGetTypeID(data) == CFBooleanGetTypeID()) {
        *outValue = CFBooleanGetValue((CFBooleanRef)data) ? 1.0 : 0.0;
        ok = true;
    }
    CFRelease(data);
    return ok;
}

/* MARK: - IUnknown */

static HRESULT Domine_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (!is_driver(inDriver) || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG Domine_AddRef(void *inDriver) {
    if (!is_driver(inDriver)) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG Domine_Release(void *inDriver) {
    if (!is_driver(inDriver)) return 0;
    UInt32 current = atomic_load(&gRefCount);
    while (current > 0 && !atomic_compare_exchange_weak(&gRefCount, &current, current - 1)) {
    }
    return current > 0 ? current - 1 : 0;
}

/* MARK: - Lifecycle */

static OSStatus Domine_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (!is_driver(inDriver)) return kAudioHardwareBadObjectError;
    gHost = inHost;

    double value = 0.0;
    lock_state();
    if (load_double(kStorageKey_Volume, &value)) gVolumeScalar = domine_driver_clamp_scalar((float)value);
    if (load_double(kStorageKey_Mute, &value)) gMuted = value != 0.0;
    unlock_state();

    double rate = 44100.0;
    if (load_double(kStorageKey_SampleRate, &value) && domine_driver_is_supported_rate(value)) rate = value;
    atomic_store(&gSampleRate, rate);
    update_ticks_per_frame(rate);
    return kAudioHardwareNoError;
}

static OSStatus Domine_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                    const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return is_driver(inDriver) ? kAudioHardwareUnsupportedOperationError : kAudioHardwareBadObjectError;
}

static OSStatus Domine_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDeviceObjectID;
    return is_driver(inDriver) ? kAudioHardwareUnsupportedOperationError : kAudioHardwareBadObjectError;
}

static OSStatus Domine_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    if (!is_driver(inDriver)) return kAudioHardwareBadObjectError;
    return inDeviceObjectID == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus Domine_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    if (!is_driver(inDriver)) return kAudioHardwareBadObjectError;
    return inDeviceObjectID == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

/* The only configuration change is the nominal sample rate. The change
   action carries the new rate in Hz. The host has stopped IO while this runs. */
static OSStatus Domine_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                        UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeInfo;
    if (!is_driver(inDriver) || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    double rate = (double)inChangeAction;
    if (!domine_driver_is_supported_rate(rate)) return kAudioHardwareBadObjectError;
    atomic_store(&gSampleRate, rate);
    update_ticks_per_frame(rate);
    store_double(kStorageKey_SampleRate, rate);
    return kAudioHardwareNoError;
}

static OSStatus Domine_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                      UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (!is_driver(inDriver) || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

/* Asks the host to switch rates later, off the property thread, as the NullAudio sample does. */
static void request_rate_change(double rate) {
    if (gHost == NULL) return;
    UInt64 action = (UInt64)rate;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, action, NULL);
    });
}

/* MARK: - Property access */

static OSStatus get_plugin_property(const AudioObjectPropertyAddress *a, UInt32 qualSize, const void *qual,
                                    UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: { AudioClassID v = kAudioObjectClassID; return PUT(v); }
    case kAudioObjectPropertyClass: { AudioClassID v = kAudioPlugInClassID; return PUT(v); }
    case kAudioObjectPropertyOwner: { AudioObjectID v = kAudioObjectUnknown; return PUT(v); }
    case kAudioObjectPropertyManufacturer: { CFStringRef v = kManufacturer_Name; return PUT(v); }
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID v = kObjectID_Device;
        return put_array(&v, sizeof(v), 1, inDataSize, outDataSize, outData);
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID v = kAudioObjectUnknown;
        if (outData != NULL) {
            if (qualSize < sizeof(CFStringRef) || qual == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)qual;
            if (uid != NULL && CFStringCompare(uid, kDevice_UID, 0) == kCFCompareEqualTo) v = kObjectID_Device;
        }
        return PUT(v);
    }
    case kAudioPlugInPropertyResourceBundle: { CFStringRef v = CFSTR(""); return PUT(v); }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static bool scope_has_output(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput;
}

static OSStatus get_device_property(const AudioObjectPropertyAddress *a, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: { AudioClassID v = kAudioObjectClassID; return PUT(v); }
    case kAudioObjectPropertyClass: { AudioClassID v = kAudioDeviceClassID; return PUT(v); }
    case kAudioObjectPropertyOwner: { AudioObjectID v = kObjectID_PlugIn; return PUT(v); }
    case kAudioObjectPropertyName: { CFStringRef v = kDevice_Name; return PUT(v); }
    case kAudioObjectPropertyManufacturer: { CFStringRef v = kManufacturer_Name; return PUT(v); }
    case kAudioObjectPropertyOwnedObjects: {
        static const AudioObjectID all[] = {kObjectID_Stream_Output, kObjectID_Volume_Output_Main, kObjectID_Mute_Output_Main};
        UInt32 count = scope_has_output(a->mScope) ? 3 : 0;
        return put_array(all, sizeof(AudioObjectID), count, inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyDeviceUID: { CFStringRef v = kDevice_UID; return PUT(v); }
    case kAudioDevicePropertyModelUID: { CFStringRef v = kDevice_ModelUID; return PUT(v); }
    case kAudioDevicePropertyTransportType: { UInt32 v = kAudioDeviceTransportTypeVirtual; return PUT(v); }
    case kAudioDevicePropertyRelatedDevices: {
        AudioObjectID v = kObjectID_Device;
        return put_array(&v, sizeof(v), 1, inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyClockDomain: { UInt32 v = 0; return PUT(v); }
    case kAudioDevicePropertyDeviceIsAlive: { UInt32 v = 1; return PUT(v); }
    case kAudioDevicePropertyDeviceIsRunning: {
        lock_state();
        UInt32 v = gIOClientCount > 0 ? 1 : 0;
        unlock_state();
        return PUT(v);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: {
        UInt32 v = a->mScope == kAudioObjectPropertyScopeInput ? 0 : 1;
        return PUT(v);
    }
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset: { UInt32 v = 0; return PUT(v); }
    case kAudioDevicePropertyStreams: {
        AudioObjectID v = kObjectID_Stream_Output;
        return put_array(&v, sizeof(v), scope_has_output(a->mScope) ? 1 : 0, inDataSize, outDataSize, outData);
    }
    case kAudioObjectPropertyControlList: {
        static const AudioObjectID controls[] = {kObjectID_Volume_Output_Main, kObjectID_Mute_Output_Main};
        return put_array(controls, sizeof(AudioObjectID), 2, inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyNominalSampleRate: { Float64 v = atomic_load(&gSampleRate); return PUT(v); }
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange ranges[sizeof(kSupportedRates) / sizeof(kSupportedRates[0])];
        for (UInt32 i = 0; i < kSupportedRateCount; i++) {
            ranges[i].mMinimum = kSupportedRates[i];
            ranges[i].mMaximum = kSupportedRates[i];
        }
        return put_array(ranges, sizeof(AudioValueRange), kSupportedRateCount, inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyIsHidden: { UInt32 v = 0; return PUT(v); }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        UInt32 v[2] = {1, 2};
        return put(v, sizeof(v), inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription));
        if (outData == NULL) {
            *outDataSize = size;
            return kAudioHardwareNoError;
        }
        if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
        AudioChannelLayout *layout = (AudioChannelLayout *)outData;
        memset(layout, 0, size);
        layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        layout->mNumberChannelDescriptions = kChannelCount;
        layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
        layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
        *outDataSize = size;
        return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyZeroTimeStampPeriod: { UInt32 v = kZeroTimeStampPeriod; return PUT(v); }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus get_stream_property(const AudioObjectPropertyAddress *a, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: { AudioClassID v = kAudioObjectClassID; return PUT(v); }
    case kAudioObjectPropertyClass: { AudioClassID v = kAudioStreamClassID; return PUT(v); }
    case kAudioObjectPropertyOwner: { AudioObjectID v = kObjectID_Device; return PUT(v); }
    case kAudioObjectPropertyOwnedObjects: return put_array(NULL, sizeof(AudioObjectID), 0, inDataSize, outDataSize, outData);
    case kAudioStreamPropertyIsActive: {
        lock_state();
        UInt32 v = gStreamActive ? 1 : 0;
        unlock_state();
        return PUT(v);
    }
    case kAudioStreamPropertyDirection: { UInt32 v = 0; return PUT(v); } /* 0 = output */
    case kAudioStreamPropertyTerminalType: { UInt32 v = kAudioStreamTerminalTypeLine; return PUT(v); }
    case kAudioStreamPropertyStartingChannel: { UInt32 v = 1; return PUT(v); }
    case kAudioStreamPropertyLatency: { UInt32 v = 0; return PUT(v); }
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        AudioStreamBasicDescription v = stream_format(atomic_load(&gSampleRate));
        return PUT(v);
    }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription formats[sizeof(kSupportedRates) / sizeof(kSupportedRates[0])];
        for (UInt32 i = 0; i < kSupportedRateCount; i++) {
            formats[i].mFormat = stream_format(kSupportedRates[i]);
            formats[i].mSampleRateRange.mMinimum = kSupportedRates[i];
            formats[i].mSampleRateRange.mMaximum = kSupportedRates[i];
        }
        return put_array(formats, sizeof(AudioStreamRangedDescription), kSupportedRateCount, inDataSize, outDataSize, outData);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus get_control_common(AudioObjectID objectID, const AudioObjectPropertyAddress *a,
                                   UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    bool volume = objectID == kObjectID_Volume_Output_Main;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: {
        AudioClassID v = volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID;
        return PUT(v);
    }
    case kAudioObjectPropertyClass: {
        AudioClassID v = volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID;
        return PUT(v);
    }
    case kAudioObjectPropertyOwner: { AudioObjectID v = kObjectID_Device; return PUT(v); }
    case kAudioObjectPropertyOwnedObjects: return put_array(NULL, sizeof(AudioObjectID), 0, inDataSize, outDataSize, outData);
    case kAudioControlPropertyScope: { AudioObjectPropertyScope v = kAudioObjectPropertyScopeOutput; return PUT(v); }
    case kAudioControlPropertyElement: { AudioObjectPropertyElement v = kAudioObjectPropertyElementMain; return PUT(v); }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus get_volume_property(const AudioObjectPropertyAddress *a, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (a->mSelector) {
    case kAudioLevelControlPropertyScalarValue: {
        lock_state();
        Float32 v = gVolumeScalar;
        unlock_state();
        return PUT(v);
    }
    case kAudioLevelControlPropertyDecibelValue: {
        lock_state();
        Float32 v = domine_driver_scalar_to_db(gVolumeScalar);
        unlock_state();
        return PUT(v);
    }
    case kAudioLevelControlPropertyDecibelRange: {
        AudioValueRange v = {DOMINE_DRIVER_MIN_DB, DOMINE_DRIVER_MAX_DB};
        return PUT(v);
    }
    /* Both conversions read the value to convert from outData and write the result in place. */
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar: {
        Float32 v = 0;
        if (outData != NULL) {
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            memcpy(&v, outData, sizeof(v));
            v = a->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels
                ? domine_driver_scalar_to_db(v) : domine_driver_db_to_scalar(v);
        }
        return PUT(v);
    }
    default: return get_control_common(kObjectID_Volume_Output_Main, a, inDataSize, outDataSize, outData);
    }
}

static OSStatus get_mute_property(const AudioObjectPropertyAddress *a, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (a->mSelector) {
    case kAudioBooleanControlPropertyValue: {
        lock_state();
        UInt32 v = gMuted ? 1 : 0;
        unlock_state();
        return PUT(v);
    }
    default: return get_control_common(kObjectID_Mute_Output_Main, a, inDataSize, outDataSize, outData);
    }
}

/* Shared by HasProperty, GetPropertyDataSize (outData NULL), and GetPropertyData. */
static OSStatus get_property(AudioObjectID objectID, const AudioObjectPropertyAddress *a, UInt32 qualSize, const void *qual,
                             UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (a == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    switch (objectID) {
    case kObjectID_PlugIn: return get_plugin_property(a, qualSize, qual, inDataSize, outDataSize, outData);
    case kObjectID_Device: return get_device_property(a, inDataSize, outDataSize, outData);
    case kObjectID_Stream_Output: return get_stream_property(a, inDataSize, outDataSize, outData);
    case kObjectID_Volume_Output_Main: return get_volume_property(a, inDataSize, outDataSize, outData);
    case kObjectID_Mute_Output_Main: return get_mute_property(a, inDataSize, outDataSize, outData);
    default: return kAudioHardwareBadObjectError;
    }
}

static Boolean Domine_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                  const AudioObjectPropertyAddress *inAddress) {
    (void)inClientProcessID;
    if (!is_driver(inDriver)) return false;
    UInt32 size = 0;
    return get_property(inObjectID, inAddress, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus Domine_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inClientProcessID;
    if (!is_driver(inDriver)) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus status = get_property(inObjectID, inAddress, 0, NULL, 0, &size, NULL);
    if (status != kAudioHardwareNoError) return status;

    AudioObjectPropertySelector s = inAddress->mSelector;
    switch (inObjectID) {
    case kObjectID_Device: *outIsSettable = s == kAudioDevicePropertyNominalSampleRate; break;
    case kObjectID_Stream_Output:
        *outIsSettable = s == kAudioStreamPropertyIsActive || s == kAudioStreamPropertyVirtualFormat
            || s == kAudioStreamPropertyPhysicalFormat;
        break;
    case kObjectID_Volume_Output_Main:
        *outIsSettable = s == kAudioLevelControlPropertyScalarValue || s == kAudioLevelControlPropertyDecibelValue;
        break;
    case kObjectID_Mute_Output_Main: *outIsSettable = s == kAudioBooleanControlPropertyValue; break;
    default: *outIsSettable = false; break;
    }
    return kAudioHardwareNoError;
}

static OSStatus Domine_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                           const void *inQualifierData, UInt32 *outDataSize) {
    (void)inClientProcessID;
    if (!is_driver(inDriver)) return kAudioHardwareBadObjectError;
    return get_property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL);
}

static OSStatus Domine_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                       const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientProcessID;
    if (!is_driver(inDriver)) return kAudioHardwareBadObjectError;
    if (outData == NULL) return kAudioHardwareIllegalOperationError;
    return get_property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
}

/* MARK: - Property setters */

static OSStatus set_volume(Float32 scalar) {
    scalar = domine_driver_clamp_scalar(scalar);
    lock_state();
    bool changed = scalar != gVolumeScalar;
    gVolumeScalar = scalar;
    unlock_state();
    if (!changed) return kAudioHardwareNoError;

    store_float(kStorageKey_Volume, scalar);
    AudioObjectPropertyAddress changes[] = {
        {kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    notify(kObjectID_Volume_Output_Main, 2, changes);
    return kAudioHardwareNoError;
}

static OSStatus set_mute(bool muted) {
    lock_state();
    bool changed = muted != gMuted;
    gMuted = muted;
    unlock_state();
    if (!changed) return kAudioHardwareNoError;

    store_bool(kStorageKey_Mute, muted);
    AudioObjectPropertyAddress change = {kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    notify(kObjectID_Mute_Output_Main, 1, &change);
    return kAudioHardwareNoError;
}

static OSStatus set_rate(Float64 rate) {
    if (!domine_driver_is_supported_rate(rate)) return kAudioHardwareIllegalOperationError;
    if (rate != atomic_load(&gSampleRate)) request_rate_change(rate);
    return kAudioHardwareNoError;
}

static OSStatus Domine_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                       const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (!is_driver(inDriver)) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    AudioObjectPropertySelector s = inAddress->mSelector;

    switch (inObjectID) {
    case kObjectID_Device:
        if (s != kAudioDevicePropertyNominalSampleRate) return kAudioHardwareUnknownPropertyError;
        if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return set_rate(*(const Float64 *)inData);

    case kObjectID_Stream_Output:
        if (s == kAudioStreamPropertyIsActive) {
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            lock_state();
            gStreamActive = *(const UInt32 *)inData != 0;
            unlock_state();
            return kAudioHardwareNoError;
        }
        if (s == kAudioStreamPropertyVirtualFormat || s == kAudioStreamPropertyPhysicalFormat) {
            if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)inData;
            AudioStreamBasicDescription ours = stream_format(f->mSampleRate);
            if (f->mFormatID != ours.mFormatID || f->mChannelsPerFrame != ours.mChannelsPerFrame
                || f->mBitsPerChannel != ours.mBitsPerChannel || f->mBytesPerFrame != ours.mBytesPerFrame
                || (f->mFormatFlags & kAudioFormatFlagIsFloat) == 0) {
                return kAudioDeviceUnsupportedFormatError;
            }
            if (!domine_driver_is_supported_rate(f->mSampleRate)) return kAudioDeviceUnsupportedFormatError;
            return set_rate(f->mSampleRate);
        }
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Volume_Output_Main:
        if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        if (s == kAudioLevelControlPropertyScalarValue) return set_volume(*(const Float32 *)inData);
        if (s == kAudioLevelControlPropertyDecibelValue) return set_volume(domine_driver_db_to_scalar(*(const Float32 *)inData));
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Mute_Output_Main:
        if (s != kAudioBooleanControlPropertyValue) return kAudioHardwareUnknownPropertyError;
        if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        return set_mute(*(const UInt32 *)inData != 0);

    case kObjectID_PlugIn: return kAudioHardwareUnknownPropertyError;
    default: return kAudioHardwareBadObjectError;
    }
}

/* MARK: - IO */

static OSStatus Domine_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (!is_driver(inDriver) || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    lock_state();
    if (gIOClientCount == UINT32_MAX) {
        unlock_state();
        return kAudioHardwareIllegalOperationError;
    }
    if (gIOClientCount == 0) {
        /* First client: start the clock. The IO thread is not running yet. */
        atomic_store(&gPeriodCount, 0);
        atomic_store(&gAnchorHostTime, mach_absolute_time());
    }
    gIOClientCount += 1;
    unlock_state();
    return kAudioHardwareNoError;
}

static OSStatus Domine_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (!is_driver(inDriver) || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    lock_state();
    OSStatus status = kAudioHardwareNoError;
    if (gIOClientCount == 0) status = kAudioHardwareIllegalOperationError;
    else gIOClientCount -= 1;
    unlock_state();
    return status;
}

/* Real-time: atomics only. */
static OSStatus Domine_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inClientID;
    if (!is_driver(inDriver) || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    DomineZeroTimestamp ts = domine_driver_zero_timestamp(atomic_load_explicit(&gAnchorHostTime, memory_order_acquire),
                                                          atomic_load_explicit(&gTicksPerFrame, memory_order_relaxed),
                                                          kZeroTimeStampPeriod,
                                                          atomic_load_explicit(&gPeriodCount, memory_order_relaxed),
                                                          mach_absolute_time());
    atomic_store_explicit(&gPeriodCount, ts.period_count, memory_order_relaxed);
    *outSampleTime = ts.sample_time;
    *outHostTime = ts.host_time;
    *outSeed = 1;
    return kAudioHardwareNoError;
}

/* Real-time. The device only takes output mixes, and discards them. */
static OSStatus Domine_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                         UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inClientID;
    if (!is_driver(inDriver) || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    bool willDo = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo != NULL) *outWillDo = willDo;
    if (outWillDoInPlace != NULL) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Domine_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (!is_driver(inDriver) || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

/* Real-time. Null sink: the mixed output is dropped. */
static OSStatus Domine_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                     UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    (void)ioMainBuffer; (void)ioSecondaryBuffer;
    if (!is_driver(inDriver) || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (inStreamObjectID != kObjectID_Stream_Output) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus Domine_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (!is_driver(inDriver) || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}
