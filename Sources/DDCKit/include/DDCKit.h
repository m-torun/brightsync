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
#define DDCKIT_VCP_COLOR_PRESET 0x14

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

typedef enum {
    DDCKIT_OK = 0,
    DDCKIT_UNSUPPORTED,  // the display answered: it has no such feature
    DDCKIT_SEND_FAILED,  // the request could not be sent
    DDCKIT_READ_FAILED,  // the reply could not be read
    DDCKIT_BAD_REPLY,    // something came back, but not a valid answer
} DDCKitResult;

// Reads a VCP feature in a single attempt. There is deliberately no retry
// loop: every transaction goes through the display coprocessor, so a caller
// that wants another try should wait and come back later.
DDCKitResult ddckit_read(void *service, unsigned int chipAddress, unsigned char vcp,
                         unsigned short *current, unsigned short *max);

// Sets a VCP feature. The display does not acknowledge a write, so success
// only means the request went out.
DDCKitResult ddckit_write(void *service, unsigned int chipAddress, unsigned char vcp,
                          unsigned short value);

#endif
