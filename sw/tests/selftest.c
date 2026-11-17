/* C self-test: recursion (stack in PSRAM), initialised .data, .bss, rodata
 * in flash, byte/halfword accesses, shifts, and libgcc mul/div (RV32E has
 * no M extension). Results end up in `results` and on GPIO_OUT. */
#include <stdint.h>
#include "../tinyrv32e.h"

volatile uint32_t results[16];

static int8_t  sbytes[8] = {-1, 2, -3, 4, -5, 6, -7, 8};
static uint16_t halves[4] = {0xBEEF, 0x8001, 0x7FFF, 0x0102};
static const char msg[] = "tinyrv32e on gf180";
static uint8_t sieve[256];

__attribute__((noinline)) static uint32_t fib(uint32_t n)
{
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

static uint32_t crc32(const char *p)
{
    uint32_t crc = 0xFFFFFFFFu;
    while (*p) {
        crc ^= (uint8_t)*p++;
        for (int i = 0; i < 8; i++)
            crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1));
    }
    return ~crc;
}

static void sort(int8_t *a, int n)
{
    for (int i = 1; i < n; i++)
        for (int j = i; j > 0 && a[j - 1] > a[j]; j--) {
            int8_t t = a[j]; a[j] = a[j - 1]; a[j - 1] = t;
        }
}

int main(void)
{
    results[0] = fib(12);                         /* 144 */
    results[1] = crc32(msg);

    sort(sbytes, 8);
    int32_t s = 0;
    for (int i = 0; i < 8; i++) s = s * 3 + sbytes[i];
    results[2] = (uint32_t)s;

    uint32_t h = 0;
    for (int i = 0; i < 4; i++) h = (h << 5) ^ halves[i] ^ (uint32_t)(int16_t)halves[i];
    results[3] = h;

    int primes = 0;
    for (int i = 2; i < 256; i++) {
        if (!sieve[i]) {
            primes++;
            for (int j = i * i; j < 256; j += i) sieve[j] = 1;
        }
    }
    results[4] = primes;                          /* 54 */

    volatile int32_t a = -123457, b = 97;
    results[5] = (uint32_t)(a * b);
    results[6] = (uint32_t)(a / b);
    results[7] = (uint32_t)(a % b);
    results[8] = (uint32_t)a >> 7;
    results[9] = (uint32_t)(a >> 7);

    uint32_t sum = 0;
    for (int i = 0; i < 10; i++) sum = (sum << 1 | sum >> 31) ^ results[i];
    results[10] = sum;

    GPIO_OUT = sum ^ (sum >> 8) ^ (sum >> 16) ^ (sum >> 24);
    return 0;
}
