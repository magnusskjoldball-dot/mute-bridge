#include "Gate.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { capacity = 32768 };
struct AudioGate {
    _Atomic uint64_t written, read;
    _Atomic bool muted;
    _Atomic float peak;
    _Atomic uint64_t rpos;
    float recent[2048];
    uint32_t delay;
    float samples[capacity];
};

AudioGate *gateCreate(uint32_t delay) {
    AudioGate *gate = calloc(1, sizeof(*gate));
    if (gate) {
        atomic_init(&gate->written, 0);
        atomic_init(&gate->read, 0);
        atomic_init(&gate->muted, true);
        gate->delay = delay;
    }
    return gate;
}

void gateDestroy(AudioGate *gate) { free(gate); }
float gateLevel(AudioGate *gate) { return atomic_exchange(&gate->peak, 0.0f); }
void gateMute(AudioGate *gate, bool muted) { atomic_store(&gate->muted, muted); }

void gatePush(AudioGate *gate, const float *samples, uint32_t count) {
    uint64_t written = atomic_load_explicit(&gate->written, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&gate->read, memory_order_acquire);
    if (count > capacity - (written - read)) return;
    bool muted = atomic_load(&gate->muted);
    float p = 0;
    { uint64_t rp = atomic_load(&gate->rpos); for (uint32_t i = 0; i < count; i++) gate->recent[(rp + i) & 2047] = samples[i]; atomic_store(&gate->rpos, rp + count); }
    for (uint32_t i = 0; i < count; i++) { float a = samples[i] < 0 ? -samples[i] : samples[i]; if (a > p) p = a; }
    if (p > atomic_load(&gate->peak)) atomic_store(&gate->peak, p);
    for (uint32_t i = 0; i < count; i++)
        gate->samples[(written + i) % capacity] = muted ? 0 : samples[i];
    atomic_store_explicit(&gate->written, written + count, memory_order_release);
}

void gateRender(AudioGate *gate, float *left, float *right, uint32_t count) {
    uint64_t written = atomic_load_explicit(&gate->written, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&gate->read, memory_order_relaxed);
    if (atomic_load(&gate->muted)) {
        memset(left, 0, count * sizeof(float));
        memset(right, 0, count * sizeof(float));
        read = written;
    } else if (written - read >= (uint64_t)gate->delay + count) {
        // Cap queue growth when the physical and virtual device clocks drift.
        if (written - read > (uint64_t)gate->delay + 3 * count)
            read = written - gate->delay - count;
        for (uint32_t i = 0; i < count; i++)
            left[i] = right[i] = gate->samples[(read + i) % capacity];
        read += count;
    } else {
        memset(left, 0, count * sizeof(float));
        memset(right, 0, count * sizeof(float));
    }
    atomic_store_explicit(&gate->read, read, memory_order_release);
}

void gateRecent(AudioGate *gate, float *out, uint32_t count) {
    uint64_t w = atomic_load(&gate->rpos);
    for (uint32_t i = 0; i < count; i++) out[i] = gate->recent[(w - count + i) & 2047];
}
