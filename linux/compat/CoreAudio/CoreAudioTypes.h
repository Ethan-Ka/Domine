// Minimal stand-ins for the Core Audio types the DomineDSP sources use, so
// the same C files build on Linux. Layouts match Apple's headers for the
// fields the kernels read. Nothing here calls into an audio API.
#ifndef DOMINE_COMPAT_COREAUDIOTYPES_H
#define DOMINE_COMPAT_COREAUDIOTYPES_H

#include <stdint.h>

#ifndef __clang__
#define _Nullable
#define _Nonnull
#endif

typedef int32_t OSStatus;
typedef uint32_t UInt32;
typedef double Float64;
typedef uint64_t UInt64;
typedef int16_t SInt16;

typedef struct AudioBuffer {
    UInt32 mNumberChannels;
    UInt32 mDataByteSize;
    void *mData;
} AudioBuffer;

typedef struct AudioBufferList {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[1]; // variable length
} AudioBufferList;

typedef struct SMPTETime {
    SInt16 mSubframes, mSubframeDivisor;
    UInt32 mCounter, mType, mFlags;
    SInt16 mHours, mMinutes, mSeconds, mFrames;
} SMPTETime;

enum {
    kAudioTimeStampSampleTimeValid = 1u << 0,
    kAudioTimeStampHostTimeValid = 1u << 1,
};

typedef struct AudioTimeStamp {
    Float64 mSampleTime;
    UInt64 mHostTime;
    Float64 mRateScalar;
    UInt64 mWordClockTime;
    SMPTETime mSMPTETime;
    UInt32 mFlags;
    UInt32 mReserved;
} AudioTimeStamp;

#endif
