/* tinyrv32e memory-mapped I/O */
#ifndef TINYRV32E_H
#define TINYRV32E_H
#include <stdint.h>

#define GPIO_OUT (*(volatile uint32_t *)0x80000000u)   /* uo_out, r/w */
#define GPIO_IN  (*(volatile uint32_t *)0x80000004u)   /* ui_in,  r/o */

#endif
