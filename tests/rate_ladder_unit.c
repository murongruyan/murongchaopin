#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define main rate_daemon_program_main
#include "../src/rate_daemon.c"
#undef main

typedef struct {
    int id;
    int fps;
    int extension;
} TestMode;

static void load_test_modes(const char *model, const TestMode *test_modes,
                            size_t count) {
    memset(modes, 0, sizeof(modes));
    memset(extension_rates, 0, sizeof(extension_rates));
    extension_rate_count = 0;
    mode_count = (int)count;
    snprintf(device_model, sizeof(device_model), "%s", model);
    for (size_t i = 0; i < count; i++) {
        modes[i].id = test_modes[i].id;
        modes[i].fps = test_modes[i].fps;
        modes[i].width = 1440;
        modes[i].height = 3136;
        modes[i].group = 0;
        if (test_modes[i].extension) add_extension_rate(test_modes[i].fps);
    }
}

static void expect_path(const char *name, int start_id, int target_id,
                        const int *expected, size_t expected_count) {
    int active_id = start_id;

    for (size_t i = 0; i < expected_count; i++) {
        int next_id = next_refresh_ladder_step(active_id, target_id);
        if (next_id != expected[i]) {
            fprintf(stderr, "FAIL: %s step %zu expected=%d actual=%d\n",
                    name, i, expected[i], next_id);
            exit(1);
        }
        active_id = next_id;
    }
    if (active_id != target_id) {
        fprintf(stderr, "FAIL: %s ended at %d instead of %d\n",
                name, active_id, target_id);
        exit(1);
    }
}

#ifndef MURONG_FREE_BUILD
static void expect_dwell(const char *name, int active_id, int ceiling_id,
                         int expected_ms) {
    int actual_ms = rmx5200_ltpo_dwell_ms(active_id, ceiling_id);

    if (actual_ms != expected_ms) {
        fprintf(stderr, "FAIL: %s expected=%dms actual=%dms\n",
                name, expected_ms, actual_ms);
        exit(1);
    }
}
#endif

int main(void) {
    if (framework_min_refresh_floor_for_state(165, 1, 0) != 60 ||
            framework_min_refresh_floor_for_state(120, 1, 0) != 60 ||
            framework_min_refresh_floor_for_state(60, 1, 0) != 60 ||
            framework_min_refresh_floor_for_state(165, 0, 0) != 165 ||
            framework_min_refresh_floor_for_state(165, 1, 1) != 165) {
        fputs("FAIL: RMX5200 framework LTPS floor policy is inconsistent\n",
              stderr);
        return 1;
    }

    static const TestMode rmx_modes[] = {
        {0, 120, 0}, {1, 123, 1}, {4, 144, 0}, {5, 150, 1},
        {6, 155, 1}, {7, 160, 1}, {8, 165, 1}, {9, 170, 1},
        {10, 1, 0}, {11, 10, 0}, {12, 30, 0}, {13, 60, 0},
        {14, 175, 1}, {15, 180, 1}
    };
    static const int rmx_up[] = {4, 6, 8};
    static const int rmx_144_up[] = {4};
    static const int rmx_150_up[] = {4, 5};
    static const int rmx_155_up[] = {4, 6};
    static const int rmx_160_up[] = {4, 6, 7};
    static const int rmx_170_up[] = {4, 6, 9};
    static const int rmx_175_up[] = {4, 6, 9, 14};
    static const int rmx_180_up[] = {4, 6, 9, 15};
    static const int rmx_down[] = {7, 6, 5, 4, 0};
    static const int rmx_video_165_to_144[] = {7, 6, 5, 4};
    static const int rmx_155_down[] = {5, 4};
    static const int strict_ten_percent[] = {7, 8};

    load_test_modes("RMX5200", rmx_modes,
                    sizeof(rmx_modes) / sizeof(rmx_modes[0]));
    if (mode_for_resolution_fps(1440, 3136, 165) != 8 ||
            mode_for_resolution_fps(1440, 2352, 165) != -1 ||
            mode_for_resolution_fps(1440, 3136, 121) != -1) {
        fputs("FAIL: mode lookup does not require resolution and FPS together\n",
              stderr);
        return 1;
    }
    expect_path("RMX5200 120->165", 0, 8, rmx_up,
                sizeof(rmx_up) / sizeof(rmx_up[0]));
    expect_path("RMX5200 120->144", 0, 4, rmx_144_up,
                sizeof(rmx_144_up) / sizeof(rmx_144_up[0]));
    expect_path("RMX5200 120->150", 0, 5, rmx_150_up,
                sizeof(rmx_150_up) / sizeof(rmx_150_up[0]));
    expect_path("RMX5200 120->155", 0, 6, rmx_155_up,
                sizeof(rmx_155_up) / sizeof(rmx_155_up[0]));
    expect_path("RMX5200 120->160", 0, 7, rmx_160_up,
                sizeof(rmx_160_up) / sizeof(rmx_160_up[0]));
    expect_path("RMX5200 120->170", 0, 9, rmx_170_up,
                sizeof(rmx_170_up) / sizeof(rmx_170_up[0]));
    expect_path("RMX5200 120->175", 0, 14, rmx_175_up,
                sizeof(rmx_175_up) / sizeof(rmx_175_up[0]));
    expect_path("RMX5200 120->180", 0, 15, rmx_180_up,
                sizeof(rmx_180_up) / sizeof(rmx_180_up[0]));
    expect_path("RMX5200 165->120", 8, 0, rmx_down,
                sizeof(rmx_down) / sizeof(rmx_down[0]));
    expect_path("RMX5200 video 165->144", 8, 4,
                rmx_video_165_to_144,
                sizeof(rmx_video_165_to_144) /
                    sizeof(rmx_video_165_to_144[0]));
    expect_path("RMX5200 155->144", 6, 4, rmx_155_down,
                sizeof(rmx_155_down) / sizeof(rmx_155_down[0]));
    expect_path("RMX5200 strict 150->165", 5, 8, strict_ten_percent,
                sizeof(strict_ten_percent) / sizeof(strict_ten_percent[0]));
    if (native_anchor_for_target(8) != 4) {
        fputs("FAIL: RMX5200 165Hz native anchor is not 144Hz\n", stderr);
        return 1;
    }
#ifndef MURONG_FREE_BUILD
    static const int rmx_ceiling_ids[] = {0, 1, 4, 5, 6, 7, 8, 9, 14, 15};
    for (size_t i = 0;
            i < sizeof(rmx_ceiling_ids) / sizeof(rmx_ceiling_ids[0]); i++) {
        int ceiling_id = rmx_ceiling_ids[i];
        char name[64];

        snprintf(name, sizeof(name), "%dHz selected ceiling",
                 mode_fps(ceiling_id));
        expect_dwell(name, ceiling_id, ceiling_id, 3000);
    }
    expect_dwell("165Hz intermediate below 170Hz", 8, 9, 80);
    expect_dwell("120Hz intermediate below 170Hz", 0, 9, 80);
    expect_dwell("60Hz low tier", 13, 9, 350);
    expect_dwell("30Hz low tier", 12, 9, 400);
    expect_dwell("10Hz low tier", 11, 9, 250);
#endif

    static const TestMode plk_modes[] = {
        {0, 120, 0}, {4, 144, 0}, {5, 165, 0}, {6, 170, 1},
        {7, 175, 1}, {8, 180, 1}
    };
    static const int plk_native_up[] = {5};
    static const int plk_custom_up[] = {8};
    static const int plk_down[] = {7, 6, 5};

    load_test_modes("PLK110", plk_modes,
                    sizeof(plk_modes) / sizeof(plk_modes[0]));
    expect_path("PLK110 120->165 native", 0, 5, plk_native_up,
                sizeof(plk_native_up) / sizeof(plk_native_up[0]));
    expect_path("PLK110 165->180", 5, 8, plk_custom_up,
                sizeof(plk_custom_up) / sizeof(plk_custom_up[0]));
    expect_path("PLK110 180->165", 8, 5, plk_down,
                sizeof(plk_down) / sizeof(plk_down[0]));
    if (native_anchor_for_target(6) != 5) {
        fputs("FAIL: PLK110 170Hz native anchor is not stock 165Hz\n", stderr);
        return 1;
    }

    static const TestMode pjd_modes[] = {
        {0, 120, 0}, {4, 144, 0}, {5, 165, 0}
    };
    static const int pjd_native_up[] = {5};
    load_test_modes("PJD110", pjd_modes,
                    sizeof(pjd_modes) / sizeof(pjd_modes[0]));
    expect_path("PJD110 native direct", 0, 5, pjd_native_up,
                sizeof(pjd_native_up) / sizeof(pjd_native_up[0]));

    /* Every arbitrary Web target is metadata-driven. A path may be blocked
     * when the user did not add a safe intermediate, but no extension step
     * may ever be equal to or greater than a ten-percent increase. */
    for (int target_fps = 121; target_fps <= 300; target_fps++) {
        TestMode dynamic_modes[] = {
            {0, 120, 0}, {1, 123, 1}, {2, 144, 0}, {3, 150, 1},
            {4, 155, 1}, {5, 160, 1}, {6, 165, 1}, {7, 170, 1},
            {8, 175, 1}, {9, 180, 1}, {10, target_fps, 1}
        };
        int active_id = 0;
        int target_id = 10;

        load_test_modes("RMX5200", dynamic_modes,
                sizeof(dynamic_modes) / sizeof(dynamic_modes[0]));
        if (!is_overclock_mode(target_id)) {
            fprintf(stderr, "FAIL: dynamic Web target %dHz is not extension\n",
                    target_fps);
            return 1;
        }
        for (int guard = 0; guard < 32 && active_id != target_id; guard++) {
            int next_id = next_refresh_ladder_step(active_id, target_id);

            if (next_id < 0) break;
            if (is_overclock_mode(next_id)
                    && mode_fps(next_id) * 100 >= mode_fps(active_id) * 110) {
                fprintf(stderr, "FAIL: dynamic %dHz path violates strict limit "
                        "%d->%d\n", target_fps, mode_fps(active_id),
                        mode_fps(next_id));
                return 1;
            }
            active_id = next_id;
        }
    }

    {
        static const TestMode exact_ten[] = {
            {0, 130, 1}, {1, 143, 1}
        };
        load_test_modes("RMX5200", exact_ten,
                        sizeof(exact_ten) / sizeof(exact_ten[0]));
        if (next_refresh_ladder_step(0, 1) >= 0) {
            fputs("FAIL: exact ten-percent extension increase was accepted\n", stderr);
            return 1;
        }
    }

    puts("PASS: dynamic model-aware refresh ladders stay strictly below ten percent");
    return 0;
}
