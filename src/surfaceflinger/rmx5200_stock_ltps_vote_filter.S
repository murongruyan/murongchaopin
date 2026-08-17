/*
 * RMX5200 stock-LTPS SurfaceFlinger vote filter.
 *
 * This replaces the logging/trace-only block used when
 * OplusRefreshRateDirector::requestRefreshRate inserts a new positive vote.
 * The surrounding function has already saved its arguments as follows:
 *
 *   x20 = const std::string *requestName
 *   w22 = requested refresh rate
 *
 * Positive requests whose name contains the exact ASCII substring
 * "object-animation" return success through the function's existing
 * epilogue without entering the request map. Zero-rate removals never reach
 * this block and therefore retain the vendor implementation unchanged.
 *
 * The snippet is exactly 0x98 bytes. It is assembled at the replacement
 * address 0x4fa838; filter_end is the first untouched instruction at
 * 0x4fa8d0, while request_success is the existing `mov w0, #1` epilogue at
 * 0x4fab38.
 */

    .text
    .p2align 2
    .global rmx5200_stock_ltps_vote_filter
    .type rmx5200_stock_ltps_vote_filter, %function

rmx5200_stock_ltps_vote_filter:
    cmp     w22, #0
    b.le    filter_end

    /* libc++ std::string: short data at +1; long size/pointer at +8/+16. */
    ldrb    w8, [x20]
    tst     w8, #1
    b.ne    long_string
    lsr     x12, x8, #1
    add     x9, x20, #1
    b       have_string

long_string:
    ldr     x12, [x20, #8]
    ldr     x9, [x20, #16]

have_string:
    cmp     x12, #16
    b.lo    filter_end
    sub     x12, x12, #15

    /* Little-endian constants for "object-a" and "nimation". */
    movz    x11, #0x626f
    movk    x11, #0x656a, lsl #16
    movk    x11, #0x7463, lsl #32
    movk    x11, #0x612d, lsl #48
    movz    x13, #0x696e
    movk    x13, #0x616d, lsl #16
    movk    x13, #0x6974, lsl #32
    movk    x13, #0x6e6f, lsl #48

search_loop:
    ldr     x10, [x9]
    cmp     x10, x11
    b.ne    next_byte
    ldr     x10, [x9, #8]
    cmp     x10, x13
    b.eq    request_success

next_byte:
    add     x9, x9, #1
    subs    x12, x12, #1
    b.ne    search_loop
    b       filter_end

request_success:
    /* Existing requestRefreshRate epilogue at replacement_start + 0x300. */
    b       rmx5200_stock_ltps_vote_filter + 0x300

    .fill   (0x98 - (. - rmx5200_stock_ltps_vote_filter)) / 4, 4, 0xd503201f

filter_end:
    .size rmx5200_stock_ltps_vote_filter, . - rmx5200_stock_ltps_vote_filter
