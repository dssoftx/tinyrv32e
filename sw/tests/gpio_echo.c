/* Reads ui_in a few times and echoes a transformed value to uo_out. */
#include <stdint.h>
#include "../tinyrv32e.h"

int main(void)
{
    uint32_t acc = 0;
    for (int i = 0; i < 4; i++) {
        uint32_t v = GPIO_IN;
        acc = acc * 5 + v;
        GPIO_OUT = v ^ 0xA5;
    }
    GPIO_OUT = (GPIO_OUT + acc) & 0xFF;
    return 0;
}
