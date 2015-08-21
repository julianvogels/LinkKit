// Copyright: 2015, Ableton AG, Berlin. All rights reserved.

#include "AudioEngine.h"
#include <AudioToolbox/AudioToolbox.h>
#include <AVFoundation/AVAudioSession.h>
#include <mach/mach_time.h>

/*
 * Create an audible click in the given audio buffers for every half beat on
 * the song timeline.
 */
static void clickInBuffer(
    const Float64 positionAtBufferBegin,
    const Float64 positionAtBufferEnd,
    const UInt32 numSamples,
    AudioBufferList *buffers) {

    static const Float64 beatsPerClick = 0.5;

    const Float64 beatsInBuffer = positionAtBufferEnd - positionAtBufferBegin;
    const Float64 samplesPerBeat = numSamples / beatsInBuffer;

    Float64 clickAtPosition = positionAtBufferBegin - fmod(positionAtBufferBegin, beatsPerClick);

    while (clickAtPosition < positionAtBufferEnd) {
        const long offset = lround(samplesPerBeat * (clickAtPosition - positionAtBufferBegin));
        if (offset >= 0 && offset < (long)(numSamples)) {
            for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i) {
                SInt16 *bufData = buffers->mBuffers[i].mData;
                if (fmod(clickAtPosition, 4) == 0) {
                  bufData[offset] = 16384; // Click! Emphasize first Beat of 4/4 Bar
                }
                else {
                  bufData[offset] = 8192; // Click!
                }
            }
        }
        clickAtPosition += beatsPerClick;
    }
}

#define INVALID_BEAT_TIME DBL_MIN
#define INVALID_BPM DBL_MIN

/*
 * Structure that stores the data needed by the audio callback.
 */
typedef struct {
    ABLSyncRef ablSync;
    Float64 sampleRate;
    Float64 secondsToHostTime;
    UInt64 outputLatency; // hardware output latency in HostTime
    Float64 lastBeatTime;
    Float64 resetToBeatTime;
    Float64 proposeBpm;
    BOOL isPlaying;
} SyncData;

/*
 * The audio callback. Query or reset the beat time and generate audible clicks
 * corresponding to beat time of the current buffer.
 */
static OSStatus audioCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData) {
#pragma unused(inBusNumber, flags)
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        memset(ioData->mBuffers[i].mData, 0, inNumberFrames * sizeof(SInt16));
    }

    SyncData *syncData = (SyncData *)inRefCon;

    Float64 beatTimeAtBufferBegin = syncData->lastBeatTime;

    // The mHostTime member of the timestamp represents the time at which the buffer is
    // delivered to the audio hardware. The output latency is the time from when the
    // buffer is delivered to the audio hardware to when the beginning of the buffer
    // starts reaching the output. We add those values to get the host time at which
    // the first sample of this buffer will be reaching the output.
    const UInt64 hostTimeAtBufferBegin = inTimeStamp->mHostTime + syncData->outputLatency;

    // Handle a timeline reset
    const Float64 resetToBeatTime = syncData->resetToBeatTime;
    syncData->resetToBeatTime = INVALID_BEAT_TIME;
    if (resetToBeatTime != INVALID_BEAT_TIME) {
        // Reset the beat timeline so that the requested beat time
        // occurs near the beginning of this buffer. The requested beat
        // time may not occur exactly at the beginning of this buffer
        // due to quantization, but it is guaranteed to occur within a
        // quantum after the beginning of this buffer. The returned beat
        // time is the actual beat time mapped to the beginning of this
        // buffer, which therefore may be less than the requested beat
        // time by up to a quantum.
        beatTimeAtBufferBegin =
            ABLSyncResetBeatTime(syncData->ablSync, resetToBeatTime, hostTimeAtBufferBegin);
    }

    // Handle a tempo proposal
    const Float64 proposeBpm = syncData->proposeBpm;
    syncData->proposeBpm = INVALID_BPM;
    if (proposeBpm != INVALID_BPM)
    {
        // Propose that the new tempo takes effect at the beginning of
        // this buffer.
        ABLSyncProposeTempo(syncData->ablSync, proposeBpm, hostTimeAtBufferBegin);
    }

    // Fill the buffer
    if (syncData->isPlaying) {
        // To calculate the host time at buffer end we add the buffer duration to the host
        // time at buffer begin. We use ABLSyncBeatTimeAtHostTime to query the according
        // beat time.
        const UInt64 bufferDurationHostTime =
            (UInt64)(syncData->secondsToHostTime * inNumberFrames / syncData->sampleRate);

        const Float64 beatTimeAtBufferEnd = ABLSyncBeatTimeAtHostTime(
            syncData->ablSync,
            inTimeStamp->mHostTime + bufferDurationHostTime + syncData->outputLatency);

        // Add audible clicks to the buffer according to the portion of the song
        // timeline represented by this buffer.
        clickInBuffer(beatTimeAtBufferBegin, beatTimeAtBufferEnd, inNumberFrames, ioData);

        syncData->lastBeatTime = beatTimeAtBufferEnd;
    }

    return noErr;
}

# pragma mark - AudioEngine

@interface AudioEngine () {
    AudioUnit _ioUnit;
    SyncData _syncData;
}
@end

@implementation AudioEngine

# pragma mark - Transport
- (BOOL)isPlaying {
    return _syncData.isPlaying;
}

- (void)setIsPlaying:(BOOL)isPlaying {
    _syncData.resetToBeatTime = 0;
    _syncData.isPlaying = isPlaying;
}

- (Float64)bpm {
    return ABLSyncGetSessionTempo(_syncData.ablSync);
}

- (void)setBpm:(Float64)bpm {
  _syncData.proposeBpm = bpm;
}

- (Float64)beatTime {
    return _syncData.lastBeatTime;
}

- (Float64)quantum {
    return ABLSyncGetQuantum(_syncData.ablSync);
}

- (void)setQuantum:(Float64)quantum {
    ABLSyncSetQuantum(_syncData.ablSync, quantum);
}

- (BOOL)isSyncEnabled {
    return ABLSyncIsEnabled(_syncData.ablSync);
}

- (ABLSyncRef)syncRef {
    return _syncData.ablSync;
}

# pragma mark - create and delete engine
- (id)init {
    if ([super init]) {
        [self initSyncData];
        [self setupAudioEngine];
    }
    return self;
}

- (void)dealloc {
    if (_ioUnit) {
        OSStatus result = AudioComponentInstanceDispose(_ioUnit);
        NSCAssert2(
            result == noErr,
            @"Could not dispose Audio Unit. Error code: %d '%.4s'",
            (int)result,
            (const char *)(&result));
    }
    ABLSyncDelete(_syncData.ablSync);
}

# pragma mark - start and stop engine
- (void)start {
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setActive:YES error:&error]) {
        NSLog(@"Couldn't activate audio session: %@", error);
    }

    OSStatus result = AudioOutputUnitStart(_ioUnit);
    NSCAssert2(
        result == noErr,
        @"Could not start Audio Unit. Error code: %d '%.4s'",
        (int)result,
        (const char *)(&result));
}

- (void)stop {
    OSStatus result = AudioOutputUnitStop(_ioUnit);
    NSCAssert2(
        result == noErr,
        @"Could not stop Audio Unit. Error code: %d '%.4s'",
        (int)result,
        (const char *)(&result));

    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setActive:NO error:NULL]) {
        NSLog(@"Couldn't deactivate audio session: %@", error);
    }
}

- (void)initSyncData {
    mach_timebase_info_data_t timeInfo;
    mach_timebase_info(&timeInfo);

    _syncData.ablSync = ABLSyncNew(120, 4); // quantize to 4 beats
    _syncData.sampleRate = [[AVAudioSession sharedInstance] sampleRate];
    _syncData.secondsToHostTime = (1.0e9 * timeInfo.denom) / (Float64)timeInfo.numer;
    _syncData.outputLatency = (UInt64)(_syncData.secondsToHostTime * [AVAudioSession sharedInstance].outputLatency);
    _syncData.lastBeatTime = 0;
    _syncData.resetToBeatTime = INVALID_BEAT_TIME;
    _syncData.proposeBpm = INVALID_BPM;
    _syncData.isPlaying = false;
}

- (void)setupAudioEngine {
    // Start a playback audio session
    NSError *sessionError = NULL;
    BOOL success = [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                          error:&sessionError];
    if(!success) {
        NSLog(@"Error setting category Audio Session: %@", [sessionError localizedDescription]);
    }

    // Create Audio Unit
    AudioComponentDescription cd = {
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };

    AudioComponent component = AudioComponentFindNext(NULL, &cd);
    OSStatus result = AudioComponentInstanceNew(component, &_ioUnit);
    NSCAssert2(
        result == noErr,
        @"AudioComponentInstanceNew failed. Error code: %d '%.4s'",
        (int)result,
        (const char *)(&result));

    AudioStreamBasicDescription asbd = {
        .mFormatID          = kAudioFormatLinearPCM,
        .mFormatFlags       =
            kAudioFormatFlagIsSignedInteger |
            kAudioFormatFlagIsPacked |
            kAudioFormatFlagsNativeEndian |
            kAudioFormatFlagIsNonInterleaved,
        .mChannelsPerFrame  = 2,
        .mBytesPerPacket    = sizeof(SInt16),
        .mFramesPerPacket   = 1,
        .mBytesPerFrame     = sizeof(SInt16),
        .mBitsPerChannel    = 8 * sizeof(SInt16),
        .mSampleRate        = _syncData.sampleRate
    };

    result = AudioUnitSetProperty(
        _ioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input,
        0,
        &asbd,
        sizeof(asbd));
    NSCAssert2(
        result == noErr,
        @"Set Stream Format failed. Error code: %d '%.4s'",
        (int)result,
        (const char *)(&result));

    // Set Audio Callback
    AURenderCallbackStruct ioRemoteInput;
    ioRemoteInput.inputProc = audioCallback;
    ioRemoteInput.inputProcRefCon = &_syncData;

    result = AudioUnitSetProperty(
        _ioUnit,
        kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input,
        0,
        &ioRemoteInput,
        sizeof(ioRemoteInput));
    NSCAssert2(
        result == noErr,
        @"Could not set Render Callback. Error code: %d '%.4s'",
        (int)result,
        (const char *)(&result));

    // Initialize Audio Unit
    result = AudioUnitInitialize(_ioUnit);
    NSCAssert2(
        result == noErr,
        @"Initializing Audio Unit failed. Error code: %d '%.4s'",
        (int)result,
        (const char *)(&result));
}

@end