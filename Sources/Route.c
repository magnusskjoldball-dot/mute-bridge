#include "Gate.h"
#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
#include <string.h>

enum { maxFrames = 8192 };
struct AudioRoute {
    AudioUnit input, output;
    AudioGate *gate;
    double rate;
    float mic[maxFrames], left[maxFrames], right[maxFrames];
};

static OSStatus capture(void *context, AudioUnitRenderActionFlags *flags,
                        const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                        AudioBufferList *unused) {
    AudioRoute *route = context;
    if (frames > maxFrames) return kAudioUnitErr_TooManyFramesToProcess;
    AudioBufferList buffer = {1, {{1, frames * sizeof(float), route->mic}}};
    OSStatus status = AudioUnitRender(route->input, flags, time, 1, frames, &buffer);
    if (!status) gatePush(route->gate, buffer.mBuffers[0].mData, frames);
    return status;
}

static OSStatus playback(void *context, AudioUnitRenderActionFlags *flags,
                         const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                         AudioBufferList *buffers) {
    AudioRoute *route = context;
    if (frames > maxFrames || buffers->mNumberBuffers != 2 ||
        !buffers->mBuffers[0].mData || !buffers->mBuffers[1].mData ||
        buffers->mBuffers[0].mDataByteSize < frames * sizeof(float) ||
        buffers->mBuffers[1].mDataByteSize < frames * sizeof(float)) {
        for (UInt32 i = 0; i < buffers->mNumberBuffers; i++)
            if (buffers->mBuffers[i].mData)
                memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
        return noErr;
    }
    gateRender(route->gate, buffers->mBuffers[0].mData, buffers->mBuffers[1].mData, frames);
    return noErr;
}

static OSStatus configure(AudioUnit unit, UInt32 device, bool input, double *rate) {
    UInt32 enable = 1, disable = 0;
    OSStatus status;
    if (input) {
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1, &enable, sizeof(enable));
        if (status) return status;
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &disable, sizeof(disable));
        if (status) return status;
    }
    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0, &device, sizeof(device));
    if (status) return status;

    UInt32 bus = input ? 1 : 0;
    AudioStreamBasicDescription hardware = {0};
    UInt32 size = sizeof(hardware);
    status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                  input ? kAudioUnitScope_Input : kAudioUnitScope_Output,
                                  bus, &hardware, &size);
    if (status) return status;
    if (hardware.mSampleRate <= 0) return kAudioUnitErr_FormatNotSupported;
    *rate = hardware.mSampleRate;
    AudioStreamBasicDescription client = {
        .mSampleRate = *rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = sizeof(float),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(float),
        .mChannelsPerFrame = input ? 1 : 2,
        .mBitsPerChannel = 32
    };
    return AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                input ? kAudioUnitScope_Output : kAudioUnitScope_Input,
                                bus, &client, sizeof(client));
}

void routeDestroy(AudioRoute *route) {
    if (!route) return;
    if (route->input) AudioOutputUnitStop(route->input);
    if (route->output) AudioOutputUnitStop(route->output);
    if (route->input) AudioComponentInstanceDispose(route->input);
    if (route->output) AudioComponentInstanceDispose(route->output);
    gateDestroy(route->gate);
    free(route);
}

AudioRoute *routeStart(uint32_t inputDevice, uint32_t outputDevice, int32_t *status) {
    AudioComponentDescription description = {
        kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    AudioRoute *route = calloc(1, sizeof(*route));
    if (!route || !component) {
        free(route);
        *status = kAudioUnitErr_FailedInitialization;
        return NULL;
    }

    double inputRate = 0, outputRate = 0;
    AURenderCallbackStruct inCallback = {capture, route};
    AURenderCallbackStruct outCallback = {playback, route};
    if ((*status = AudioComponentInstanceNew(component, &route->input)) ||
        (*status = AudioComponentInstanceNew(component, &route->output)) ||
        (*status = configure(route->input, inputDevice, true, &inputRate)) ||
        (*status = configure(route->output, outputDevice, false, &outputRate))) goto fail;

    if (inputRate != outputRate) {
        *status = kAudioUnitErr_FormatNotSupported;
        goto fail;
    }
    route->rate = inputRate;
    route->gate = gateCreate((uint32_t)(inputRate * 0.035));
    if (!route->gate) {
        *status = kAudioUnitErr_FailedInitialization;
        goto fail;
    }

    if ((*status = AudioUnitSetProperty(route->input, kAudioOutputUnitProperty_SetInputCallback,
                                        kAudioUnitScope_Global, 0, &inCallback, sizeof(inCallback))) ||
        (*status = AudioUnitSetProperty(route->output, kAudioUnitProperty_SetRenderCallback,
                                        kAudioUnitScope_Input, 0, &outCallback, sizeof(outCallback))) ||
        (*status = AudioUnitInitialize(route->input)) ||
        (*status = AudioUnitInitialize(route->output)) ||
        (*status = AudioOutputUnitStart(route->output)) ||
        (*status = AudioOutputUnitStart(route->input))) goto fail;
    return route;

fail:
    routeDestroy(route);
    return NULL;
}

void routeMute(AudioRoute *route, bool muted) { gateMute(route->gate, muted); }

float routeLevel(AudioRoute *route) { return gateLevel(route->gate); }
void routeRecent(AudioRoute *route, float *out, uint32_t count) { gateRecent(route->gate, out, count); }
double routeRate(AudioRoute *route) { return route->rate; }
