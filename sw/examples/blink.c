/* Real-hardware demo: a Knight Rider scanner on uo_out.
 * ui_in sets the speed (0 = slowest). One loop iteration is a few hundred
 * clocks because every instruction is fetched over SPI. */
#include <stdint.h>
#include "../tinyrv32e.h"

static void delay(uint32_t n)
{
    while (n--) __asm__ volatile("");
}

int main(void)
{
    uint32_t pos = 0, dir = 1;
    for (;;) {
        GPIO_OUT = 1u << pos;
        delay(64 + (255 - (GPIO_IN & 0xFF)) * 4);
        if (pos == 7) dir = -1u;
        if (pos == 0) dir = 1;
        pos += dir;
    }
}
