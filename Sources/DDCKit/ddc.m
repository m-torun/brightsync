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

// The request goes out twice before the reply is read, as in m1ddc and
// MonitorControl; some displays miss the first one. That is part of the
// framing, not a retry.
#define SEND_CYCLES 2

static DDCKitResult send(void *service, unsigned int chipAddress, unsigned char *packet, int length) {
    for (int cycle = 0; cycle < SEND_CYCLES; ++cycle) {
        usleep(10000);
        if (IOAVServiceWriteI2C((IOAVServiceRef)service, chipAddress, DATA_ADDRESS, packet, length) != 0) {
            return DDCKIT_SEND_FAILED;
        }
    }
    return DDCKIT_OK;
}

DDCKitResult ddckit_read(void *service, unsigned int chipAddress, unsigned char vcp,
                         unsigned short *current, unsigned short *max) {
    if (service == NULL) {
        return DDCKIT_SEND_FAILED;
    }
    unsigned char request[4] = { 0x82, 0x01, vcp, 0x00 };
    request[3] = checksum((unsigned char)(chipAddress << 1), request, 0, 2);
    DDCKitResult sent = send(service, chipAddress, request, sizeof(request));
    if (sent != DDCKIT_OK) {
        return sent;
    }

    // DDC/CI asks the host to give the display 40 ms to prepare its reply.
    unsigned char reply[11] = {};
    usleep(50000);
    if (IOAVServiceReadI2C((IOAVServiceRef)service, chipAddress, 0, reply, sizeof(reply)) != 0) {
        return DDCKIT_READ_FAILED;
    }
    // 6e 88 02 <result> <vcp> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>
    bool framed = reply[0] == 0x6e && reply[1] == 0x88 && reply[2] == 0x02 && reply[4] == vcp;
    if (!framed || checksum(0x50, reply, 0, 9) != reply[10]) {
        return DDCKIT_BAD_REPLY;
    }
    if (reply[3] != 0x00) {
        return DDCKIT_UNSUPPORTED;
    }
    *max = (unsigned short)reply[6] * 256 + reply[7];
    *current = (unsigned short)reply[8] * 256 + reply[9];
    return DDCKIT_OK;
}

DDCKitResult ddckit_write(void *service, unsigned int chipAddress, unsigned char vcp,
                          unsigned short value) {
    if (service == NULL) {
        return DDCKIT_SEND_FAILED;
    }
    unsigned char packet[6] = {
        0x84, 0x03, vcp, (unsigned char)(value >> 8), (unsigned char)(value & 0xff), 0x00
    };
    packet[5] = checksum((unsigned char)(chipAddress << 1) ^ DATA_ADDRESS, packet, 0, 4);
    return send(service, chipAddress, packet, sizeof(packet));
}
