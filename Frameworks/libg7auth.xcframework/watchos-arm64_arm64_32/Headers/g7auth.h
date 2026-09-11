/* g7auth.h — C bridge to the ported Juggluco/OpenSSL Dexcom G7 J-PAKE crypto (libg7auth.dylib).
   All buffers are caller-allocated. Return 1 = success/valid, 0 = failure, unless noted. */
#ifndef G7AUTH_H
#define G7AUTH_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Initialize with the 4-digit pairing code as ASCII bytes (e.g. {'3','1','0','2'}).
   Loads the embedded partner certs. Returns 1 if keys + pin are valid. Call once. */
int g7_init(const uint8_t* pin4);

/* J-PAKE round 1/2 (which = 0 or 1): write our 160-byte payload into out160. Returns 1. */
int g7_round12(int which, uint8_t* out160);

/* Feed the sensor's 160-byte round payload (which = 0,1) or round-3 material (which = 2).
   For which<2 returns 1 if the sensor's ZKP validates; for which==2 derives the shared key. */
int g7_put_pubkey(int which, const uint8_t* in160);

/* J-PAKE round 3: write our 160-byte payload into out160. Returns 1 on success. */
int g7_round3(uint8_t* out160);

/* ECDSA-P256 proof-of-possession: sign `data` (len bytes; the sensor's 0x0C challenge body),
   write the 64-byte r||s signature into out64. Returns 1. */
int g7_challenge(const uint8_t* data, int len, uint8_t* out64);

/* AES-8: encrypt `data` (8 bytes) under the derived J-PAKE shared key, write 8 bytes to out8.
   Used for the AES challenge/response after the shared key is established. Returns 1. */
int g7_aes8(const uint8_t* data, uint8_t* out8);

#ifdef __cplusplus
}
#endif
#endif
