// DDCKit - a minimal DDC/CI layer for external displays on Apple Silicon.
//
// Display enumeration reuses ioregistry.m from m1ddc (MIT, (c) waydabber);
// see LICENSE-m1ddc. The DDC read/write framing here follows the approach
// used by MonitorControl's Arm64DDC (MIT): the reply is read at I2C offset 0
// as 11 bytes and validated by header and checksum, which is what works on
// displays whose replies are otherwise unreadable.

#ifndef DDCKIT_H
#define DDCKIT_H

#include <stdbool.h>

#define DDCKIT_MAX_DISPLAYS 8
#define DDCKIT_VCP_BRIGHTNESS 0x10
#define DDCKIT_VCP_CONTRAST 0x12

typedef struct {
    unsigned int displayID;
    char productName[96];
    char edidUUID[48];
    unsigned int chipAddress;
    void *service; // owned by the caller; free with ddckit_release
} DDCKitDisplay;

// Fills `out` with the DDC-capable online displays, returning how many.
int ddckit_enumerate(DDCKitDisplay *out, int maxCount);

void ddckit_release(void *service);

// Reads a VCP feature. Returns false if the display did not answer with a
// valid, checksum-correct reply for this feature.
bool ddckit_read(void *service, unsigned int chipAddress, unsigned char vcp,
                 unsigned short *current, unsigned short *max);

bool ddckit_write(void *service, unsigned int chipAddress, unsigned char vcp,
                  unsigned short value);

#endif
