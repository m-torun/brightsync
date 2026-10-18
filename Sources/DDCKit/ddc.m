#import <Foundation/Foundation.h>

#include "DDCKit.h"
#include "i2c.h"
#include "ioregistry.h"

#define DATA_ADDRESS 0x51

// DDC/CI packets are checksummed by XOR over the frame, seeded differently for
// requests and replies.
static unsigned char checksum(unsigned char seed, const unsigned char *data, int first, int last) {
    unsigned char sum = seed;
    for (int i = first; i <= last; ++i) {
        sum ^= data[i];
    }
    return sum;
}

int ddckit_enumerate(DDCKitDisplay *out, int maxCount) {
    @autoreleasepool {
        DisplayInfos infos[MAX_DISPLAYS] = {};
        CGDisplayCount count = getOnlineDisplayInfos(infos);
        int found = 0;
        for (CGDisplayCount i = 0; i < count && found < maxCount; ++i) {
            DDCTransport transport = getDisplayDDCTransport(&infos[i]);
            if (transport.service == NULL) {
                continue; // built-in or otherwise not addressable over DDC
            }
            DDCKitDisplay display = {};
            display.displayID = infos[i].id;
            display.chipAddress = transport.chipAddress;
            display.service = (void *)transport.service;
            const char *name = infos[i].productName.UTF8String;
            const char *edid = infos[i].edid.UTF8String;
            strncpy(display.productName, name ? name : "Display", sizeof(display.productName) - 1);
            strncpy(display.edidUUID, edid ? edid : "", sizeof(display.edidUUID) - 1);
            out[found++] = display;
        }
        return found;
    }
}

void ddckit_release(void *service) {
    if (service != NULL) {
        CFRelease((IOAVServiceRef)service);
    }
}

bool ddckit_read(void *service, unsigned int chipAddress, unsigned char vcp,
                 unsigned short *current, unsigned short *max) {
    if (service == NULL) {
        return false;
    }
    unsigned char request[4] = { 0x82, 0x01, vcp, 0x00 };
    request[3] = checksum((unsigned char)(chipAddress << 1), request, 0, 2);
    unsigned char reply[11];

    for (int attempt = 0; attempt < 5; ++attempt) {
        bool wrote = true;
        for (int cycle = 0; cycle < 2; ++cycle) {
            usleep(10000);
            if (IOAVServiceWriteI2C((IOAVServiceRef)service, chipAddress, DATA_ADDRESS, request, sizeof(request)) != 0) {
                wrote = false;
                break;
            }
        }
        if (wrote) {
            memset(reply, 0, sizeof(reply));
            usleep(50000);
            if (IOAVServiceReadI2C((IOAVServiceRef)service, chipAddress, 0, reply, sizeof(reply)) == 0) {
                // 6e 88 02 <result> <vcp> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>
                bool framed = reply[0] == 0x6e && reply[1] == 0x88 && reply[2] == 0x02;
                bool answered = reply[3] == 0x00 && reply[4] == vcp; // result 0x01 means unsupported
                if (framed && answered && checksum(0x50, reply, 0, 9) == reply[10]) {
                    *max = (unsigned short)reply[6] * 256 + reply[7];
                    *current = (unsigned short)reply[8] * 256 + reply[9];
                    return true;
                }
            }
        }
        usleep(20000);
    }
    return false;
}

bool ddckit_write(void *service, unsigned int chipAddress, unsigned char vcp,
                  unsigned short value) {
    if (service == NULL) {
        return false;
    }
    unsigned char packet[6] = {
        0x84, 0x03, vcp, (unsigned char)(value >> 8), (unsigned char)(value & 0xff), 0x00
    };
    packet[5] = checksum((unsigned char)(chipAddress << 1) ^ DATA_ADDRESS, packet, 0, 4);

    bool ok = false;
    for (int cycle = 0; cycle < 2; ++cycle) {
        usleep(10000);
        ok = IOAVServiceWriteI2C((IOAVServiceRef)service, chipAddress, DATA_ADDRESS, packet, sizeof(packet)) == 0;
    }
    return ok;
}
