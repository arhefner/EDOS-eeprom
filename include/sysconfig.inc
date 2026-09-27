;  Copyright 2024, David S. Madole <david@madole.net>
;
;  This program is free software: you can redistribute it and/or modify
;  it under the terms of the GNU General Public License as published by
;  the Free Software Foundation, either version 3 of the License, or
;  (at your option) any later version.
;
;  This program is distributed in the hope that it will be useful,
;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;  GNU General Public License for more details.
;
;  You should have received a copy of the GNU General Public License
;  along with this program.  If not, see <https://www.gnu.org/licenses/>.


          ; Hardware configuration for each supported machine. Select one by
          ; defining its name when assembling mbios.asm, e.g. -D1802MAX.

#ifdef 1802MINI
  #define BRMK         bn2              ; branch on serial mark
  #define BRSP         b2               ; branch on serial space
  #define SEMK         seq              ; set serial mark
  #define SESP         req              ; set serial space
  #define EXP_PORT     5                ; group i/o expander port
  #define EXP_MEMORY                    ; enable expansion memory
  #define IDE_GROUP    0                ; ide interface group
  #define IDE_SECOND   4                ; ide second interface group
  #define IDE_SELECT   2                ; ide interface address port
  #define IDE_DATA     3                ; ide interface data port
  #define RTC_GROUP    1                ; real time clock group
  #define RTC_PORT     3                ; real time clock port
  #define UART_GROUP   0                ; uart port group
  #define UART_DATA    6                ; uart data port
  #define UART_STATUS  7                ; uart status/command port
  #define SPI_GROUP    2
  #define SPI_CTRL     2
  #define SPI_DATA     3
  #define SD_SECOND                     ; probe second sd card (spi cs0)
  #define SET_BAUD     19200            ; bit-bang serial fixed baud rate
  #define FREQ_KHZ     4000             ; default processor clock frequency
#endif

#ifdef SUPERELF
  #define BRMK         bn2              ; branch on serial mark
  #define BRSP         b2               ; branch on serial space
  #define SEMK         seq              ; set serial mark
  #define SESP         req              ; set serial space
  #define EXP_PORT     5                ; group i/o expander port
  #define EXP_MEMORY                    ; enable expansion memory
  #define IDE_GROUP    0                ; ide interface group
  #define IDE_SECOND   4                ; ide second interface group
  #define IDE_SELECT   2                ; ide interface address port
  #define IDE_DATA     3                ; ide interface data port
  #define RTC_GROUP    1                ; real time clock group
  #define RTC_PORT     3                ; real time clock port
  #define UART_GROUP   0                ; uart port group
  #define UART_DATA    6                ; uart data port
  #define UART_STATUS  7                ; uart status/command port
  #define SPI_GROUP    2
  #define SPI_CTRL     2
  #define SPI_DATA     3
  #define SD_SECOND                     ; probe second sd card (spi cs0)
  #define SET_BAUD     9600             ; bit-bang serial fixed baud rate
  #define FREQ_KHZ     1790             ; default processor clock frequency
#endif

#ifdef RC1802
  #define BRMK         bn3              ; branch on serial mark
  #define BRSP         b3               ; branch on serial space
  #define SEMK         seq              ; set serial mark
  #define SESP         req              ; set serial space
  #define EXP_PORT     1                ; group i/o expander port
  #define IDE_GROUP    0                ; ide interface group
  #define IDE_SELECT   2                ; ide interface address port
  #define IDE_DATA     3                ; ide interface data port
  #define UART_GROUP   1                ; uart port group
  #define UART_DATA    2                ; uart data port
  #define UART_STATUS  3                ; uart status/command port
  #define RTC_GROUP    2                ; real time clock group
  #define RTC_PORT     3                ; real time clock port
  #define SET_BAUD     9600             ; bit-bang serial fixed baud rate
  #define FREQ_KHZ     2000             ; default processor clock frequency
#endif

#ifdef 1802MAX
  #define BRMK         bn2              ; branch on serial mark
  #define BRSP         b2               ; branch on serial space
  #define SEMK         req              ; set serial mark
  #define SESP         seq              ; set serial space
  #define EXP_PORT     5                ; group i/o expander port
  #define EXP_MEMORY                    ; enable expansion memory
; No CF interface is currently installed; to enable the CF driver, define
; these with the correct ports for the interface:
;  #define IDE_GROUP    0                ; ide interface group
;  #define IDE_SECOND   4                ; ide second interface group
;  #define IDE_SELECT   4                ; ide interface address port
;  #define IDE_DATA     5                ; ide interface data port
  #define SPI_GROUP    0                ; spi interface group
  #define SPI_CTRL     2                ; spi interface control port
  #define SPI_DATA     3                ; spi interface data port
  #define SD_ASK                        ; ask whether to probe sd slot 2
  #define RTC_GROUP    0                ; real time clock group
  #define RTC_PORT     1                ; real time clock port
  #define UART_GROUP   0                ; uart port group
  #define UART_DATA    6                ; uart data port
  #define UART_STATUS  7                ; uart status/command port
  #define FAST_UART
  #define HI_BAUD
  #define SET_BAUD     38400            ; bit-bang serial fixed baud rate
  #define FREQ_KHZ     4000             ; default processor clock frequency
#endif

#ifdef ELF2
  #define BRMK         bn2              ; branch on serial mark
  #define BRSP         b2               ; branch on serial space
  #define SEMK         req              ; set serial mark
  #define SESP         seq              ; set serial space
  #define EXP_PORT     1                ; group i/o expander port
  #define EXP_MEMORY                    ; enable expansion memory
  #define SPI_GROUP    0                ; spi interface group
  #define SPI_CTRL     2                ; spi interface control port
  #define SPI_DATA     3                ; spi interface data port
  #define RTC_GROUP    0                ; real time clock group
  #define RTC_PORT     5                ; real time clock port
  #define UART_GROUP   0                ; uart port group
  #define UART_DATA    6                ; uart data port
  #define UART_STATUS  7                ; uart status/command port
  #define FAST_UART
  #define HI_BAUD
  #define SET_BAUD     19200            ; bit-bang serial fixed baud rate
  #define FREQ_KHZ     1790             ; default processor clock frequency
#endif

#ifdef 1802MC
  #define BRMK         bn3              ; branch on serial mark
  #define BRSP         b3               ; branch on serial space
  #define SEMK         req              ; set serial mark
  #define SESP         seq              ; set serial space
  #define EXP_PORT     1                ; group i/o expander port
  #define IDE_GROUP    1                ; ide interface group
  #define IDE_SELECT   2                ; ide interface address port
  #define IDE_DATA     3                ; ide interface data port
  #define RTC_GROUP    0                ; real time clock group
  #define RTC_PORT     5                ; real time clock port
  #define UART_GROUP   0                ; uart port group
  #define UART_DATA    6                ; uart data port
  #define UART_STATUS  7                ; uart status/command port
  #define FAST_UART
  #define HI_BAUD
  #define SET_BAUD     19200            ; bit-bang serial fixed baud rate
  #define FREQ_KHZ     1790             ; default processor clock frequency
#endif

#ifdef TEST
  #define BRMK         bn2              ; branch on serial mark
  #define BRSP         b2               ; branch on serial space
  #define SEMK         seq              ; set serial mark
  #define SESP         req              ; set serial space
  #define EXP_PORT     5                ; group i/o expander port
  #define IDE_GROUP    1                ; ide interface group
  #define IDE_SELECT   2                ; ide interface address port
  #define IDE_DATA     3                ; ide interface data port
  #define UART_GROUP   4                ; uart port group
  #define UART_DATA    6                ; uart data port
  #define UART_STATUS  7                ; uart status/command port
  #define RTC_GROUP    2                ; real time clock group
  #define RTC_PORT     3                ; real time clock port
  #define FREQ_KHZ     4000             ; default processor clock frequency
#endif
