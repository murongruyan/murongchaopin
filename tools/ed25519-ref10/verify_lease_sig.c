/*
 * verify_lease_sig - minimal Ed25519 lease signature verifier.
 *
 * Usage: verify_lease_sig <public_key_hex> <payload_file> <signature_hex>
 *   public_key_hex : 64 lowercase/uppercase hex chars (32-byte Ed25519 key)
 *   payload_file   : path to the raw signed payload (lease claims JSON bytes),
 *                    or "-" to read the payload from stdin
 *   signature_hex  : 128 hex chars (64-byte Ed25519 signature)
 *
 * Exit codes:
 *   0  signature is valid for the payload under the given public key
 *   1  signature is invalid
 *   2  usage error / I/O error / malformed input
 *
 * The public key is passed as an argument, so the binary itself never embeds
 * secrets. The module ships the expected public key in config/auth/.
 *
 * Ed25519 implementation: public-domain ref10 port by Orson Peters (orlp),
 * https://github.com/orlp/ed25519 - dedicated to the public domain (CC0).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ed25519.h"

#define MAX_PAYLOAD_SIZE (256 * 1024)

static int hex_nibble(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int decode_hex(const char *hex, unsigned char *out, size_t expected_len)
{
    size_t i;
    if (strlen(hex) != expected_len * 2) {
        return -1;
    }
    for (i = 0; i < expected_len; i++) {
        int hi = hex_nibble(hex[i * 2]);
        int lo = hex_nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            return -1;
        }
        out[i] = (unsigned char)((hi << 4) | lo);
    }
    return 0;
}

static long read_all(const char *path, unsigned char *buffer, long capacity)
{
    FILE *file;
    int is_stdin;
    long total;
    is_stdin = (strcmp(path, "-") == 0);
    if (is_stdin) {
        file = stdin;
    } else {
        file = fopen(path, "rb");
        if (file == NULL) {
            return -1;
        }
    }
    total = 0;
    for (;;) {
        size_t chunk = fread(buffer + total, 1, (size_t)(capacity - total), file);
        if (chunk == 0) {
            if (ferror(file)) {
                if (!is_stdin) fclose(file);
                return -1;
            }
            break;
        }
        total += (long)chunk;
        if (total >= capacity) {
            if (!is_stdin) fclose(file);
            return -2; /* payload too large */
        }
    }
    if (!is_stdin) fclose(file);
    return total;
}

int main(int argc, char **argv)
{
    unsigned char public_key[32];
    unsigned char signature[64];
    unsigned char *payload;
    long payload_len;

    if (argc != 4) {
        fprintf(stderr, "usage: verify_lease_sig <public_key_hex> <payload_file|-> <signature_hex>\n");
        return 2;
    }
    if (decode_hex(argv[1], public_key, sizeof(public_key)) != 0) {
        fprintf(stderr, "verify_lease_sig: public key must be 64 hex chars\n");
        return 2;
    }
    if (decode_hex(argv[3], signature, sizeof(signature)) != 0) {
        fprintf(stderr, "verify_lease_sig: signature must be 128 hex chars\n");
        return 2;
    }
    payload = (unsigned char *)malloc(MAX_PAYLOAD_SIZE);
    if (payload == NULL) {
        fprintf(stderr, "verify_lease_sig: out of memory\n");
        return 2;
    }
    payload_len = read_all(argv[2], payload, MAX_PAYLOAD_SIZE);
    if (payload_len < 0) {
        fprintf(stderr, "verify_lease_sig: cannot read payload%s\n",
                payload_len == -2 ? " (too large)" : "");
        free(payload);
        return 2;
    }

    if (ed25519_verify(signature, payload, (size_t)payload_len, public_key)) {
        free(payload);
        return 0;
    }
    free(payload);
    return 1;
}
