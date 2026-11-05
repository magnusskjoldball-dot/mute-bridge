#include <stdbool.h>
#include <stdint.h>
typedef struct AudioGate AudioGate;
AudioGate *gateCreate(uint32_t delay);
void gateDestroy(AudioGate *gate);
void gateMute(AudioGate *gate, bool muted);
float gateLevel(AudioGate *gate);
void gateRecent(AudioGate *gate, float *out, uint32_t count);
void gatePush(AudioGate *gate, const float *samples, uint32_t count);
void gateRender(AudioGate *gate, float *left, float *right, uint32_t count);

typedef struct AudioRoute AudioRoute;
AudioRoute *routeStart(uint32_t inputDevice, uint32_t outputDevice, int32_t *status);
void routeMute(AudioRoute *route, bool muted);
void routeDestroy(AudioRoute *route);
float routeLevel(AudioRoute *route);
void routeRecent(AudioRoute *route, float *out, uint32_t count);
double routeRate(AudioRoute *route);
