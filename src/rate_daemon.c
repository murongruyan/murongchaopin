#define _GNU_SOURCE

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <ctype.h>
#include <sys/inotify.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <linux/input.h>
#include "rmx5200_ltpo_drop_state.h"
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <limits.h>

#define MAX_MODES 50
#define MAX_APPS 200
#define MAX_PKG_LEN 128
#define MAX_EXTENSION_RATES 256
#define DISPLAY_HOOK_PORT 49721
#define NATIVE_RESOLUTION_PHYSICAL_FALLBACK_MS 250
#define RMX5200_IRIS_ESD_CTRL_PATH "/sys/kernel/iris/esd"
#define RMX5200_IRIS_DISPLAY_MODE_PATH "/sys/kernel/iris/display_mode"
#define RMX5200_VIDEO_IRIS_ESD_STATE ".video_iris_esd_ctrl"
#define RMX5200_VIDEO_IRIS_EXIT_STUCK_LOG_MS 15000
#define RMX5200_VIDEO_IRIS_EXIT_SETTLE_MS 5000
#define RMX5200_LTPO_APPLIED_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/applied"
#define RMX5200_LTPO_ACTIVITY_REGISTERED_PATH \
    "/sys/module/rmx5200_ltpo_activity/parameters/activity_probe_registered"
#define RMX5200_LTPO_GPU_COUNT_PATH \
    "/sys/module/rmx5200_ltpo_activity/parameters/app_gpu_submit_count"
#define RMX5200_LTPO_PHYSICAL_HOOK_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/physical_commit_hook_registered"
#define RMX5200_LTPO_PHYSICAL_COUNT_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/physical_commit_count"
#define RMX5200_LTPO_PHYSICAL_MODE_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/physical_commit_mode_id"
#define RMX5200_LTPO_PHYSICAL_WIDTH_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/physical_commit_width"
#define RMX5200_LTPO_PHYSICAL_HEIGHT_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/physical_commit_height"
#define RMX5200_LTPO_PHYSICAL_REFRESH_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/physical_commit_refresh"
#define RMX5200_LTPO_PHYSICAL_NS_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/physical_commit_ns"
#define RMX5200_LTPO_TOUCH_BOOST_READY_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/touch_boost_ready"
#define RMX5200_LTPO_TOUCH_BOOST_ENABLED_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/touch_boost_enabled"
#define RMX5200_LTPO_TOUCH_BOOST_ONE_SHOT_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/touch_boost_one_shot"
#define RMX5200_LTPO_TOUCH_BOOST_TRIGGER_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/touch_boost_trigger"
#define RMX5200_LTPO_TOUCH_BOOST_TARGET_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/touch_boost_target_refresh"
#define RMX5200_LTPO_TOUCH_BOOST_CHAIN_CEILING_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/touch_boost_chain_ceiling_refresh"
#define RMX5200_LTPO_TOUCH_BOOST_SUCCESSES_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/touch_boost_successes"
#define RMX5200_LTPO_TOUCH_BOOST_FAILURES_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/touch_boost_failures"
#define RMX5200_LTPO_TOUCH_BOOST_SKIPS_PATH \
    "/sys/module/rmx5200_ltpo_modes/parameters/touch_boost_skips"
#define RMX5200_LTPO_GPU_ACTIVITY_RATE 20
#define RMX5200_LTPO_GPU_HIGH_RATE 45
#define RMX5200_LTPO_GPU_MAX_RATE 100
#define RMX5200_LTPO_TOUCH_DEBOUNCE_MS 250
#define RMX5200_LTPO_IRIS_BOOST_TIMEOUT_US 50000
#define RMX5200_LTPO_PHYSICAL_ANCHOR_TIMEOUT_US 500000
#define RMX5200_LTPO_TOUCH_DIRECT_GRACE_MS 3200
#define RMX5200_LTPO_TOUCH_DIRECT_TIMEOUT_MS 4500
#define RMX5200_LTPO_PENDING_POLL_MS 20
#define RMX5200_LTPO_DROP_TIMEOUT_MS 1800
#define RMX5200_LTPO_SUPERSEDED_DROP_GUARD_MS 5000
#define RMX5200_LTPO_CEILING_DWELL_MS 3000
#define RMX5200_LTPO_INTERMEDIATE_HIGH_DWELL_MS 80
#define RMX5200_LTPO_RISE_REFINE_TIMEOUT_MS 500
#define RMX5200_LTPO_RISE_STEP_TIMEOUT_MS 4500
#define RMX5200_VIDEO_SURFACE_PROBE_INTERVAL_MS 500
#define RMX5200_VIDEO_SURFACE_EXIT_GRACE_MS 1800
#define RMX5200_VIDEO_SURFACE_MIN_REFRESH 60
#define DISPLAY_HOOK_TOKEN \
    "api102-6d85e308abce16567fdd668dcd12ebadf5f82bdaa78dc6023f04fcee9795f6c4"

typedef struct {
    int id;
    int fps;
    int width;
    int height;
    int group;
} DisplayMode;

typedef struct {
    char package[MAX_PKG_LEN];
    int mode_id;
} AppConfig;

typedef struct {
    int density;
    int density_valid;
    int size_width;
    int size_height;
    int size_valid;
} DisplayOverrideState;

typedef struct {
    int resolution_adjust;
    int resolution_adjust_valid;
    int screen_index;
    int screen_index_valid;
    int preferred_width;
    int preferred_height;
    int preferred_resolution_valid;
    int refresh_rate_mode;
    int refresh_rate_mode_valid;
} ColorOsSettingsState;

typedef struct {
    int valid;
    int target_width;
    int target_density;
    int previous_mode_id;
    int previous_width;
    long long expires_at_ms;
    DisplayOverrideState display_before;
    ColorOsSettingsState coloros_before;
} PreparedResolutionState;

typedef struct {
    int valid;
    int target_width;
    int source_width;
    int source_density;
    int target_density;
    long long generation;
    long long queued_at_ms;
    long long target_observed_at_ms;
    long long expires_at_ms;
    int physical_fallback_requested;
} NativeResolutionAdoption;

typedef struct {
    int active;
    int touch_fd;
    int touch_down;
    int ceiling_mode_id;
    int pending_ceiling_mode_id;
    int pending_drop_mode_id;
    int pending_drop_source_id;
    int superseded_drop_mode_id;
    int touch_boost_configured;
    int touch_direct_retries;
    long long last_activity_ms;
    long long last_transition_ms;
    long long last_touch_boost_ms;
    long long touch_direct_request_ms;
    unsigned long long touch_direct_commit_count;
    long long drop_request_ms;
    unsigned long long drop_commit_count;
    Rmx5200LtpoDropState drop_state;
    unsigned long long superseded_drop_commit_count;
    long long superseded_drop_expires_ms;
    long long last_gpu_sample_ms;
    unsigned long long last_gpu_submit_count;
    /* High-rate touch rises are advanced by the main loop after each physical
     * DSI receipt.  Keeping this state outside the input callback prevents a
     * slow 144->overclock commit from freezing touch dispatch. */
    int rise_queue_active;
    int rise_queue_target_id;
    int rise_queue_current_id;
    int rise_queue_pending_id;
    unsigned long long rise_queue_commit_count;
    long long rise_queue_request_ms;
    int rise_queue_steps;
} Rmx5200LtpoController;

DisplayMode modes[MAX_MODES];
int mode_count = 0;

AppConfig app_configs[MAX_APPS];
int app_config_count = 0;
int default_mode_id = 1;

int current_mode_id = -1;
int force_reapply = 0;  // 亮屏后强制重放目标模式（修复息屏后回 120Hz）
/* ColorOS can restore the stock 144Hz timing after the first visible ON
 * frame, even after the ordinary cache-based replay ran.  Keep this separate
 * from force_reapply: it is cleared only after the LTPO ladder and framework
 * settings mirror have both completed. */
static int screen_on_reapply_pending = 0;
static int screen_on_reapply_transaction_ok = 0;
static volatile sig_atomic_t reapply_requested = 0;
static int settings_uid = -1;
static int games_uid = -1;
static int scene_uid = -1;
static int bilibili_uid = -1;
static int system_uid = -1;
static char device_model[32] = "unknown";
static int pending_density_mode_id = -1;
static int pending_density = -1;
static PreparedResolutionState prepared_resolution;
static NativeResolutionAdoption native_resolution_adoption;
static int video_override_active = 0;
static int video_override_follow = 0;
static int video_override_fps = -1;
static int video_override_mode_id = -1;
static int video_override_vendor_owned = 0;
static int video_handoff_active = 0;
static int video_exit_pending = 0;
/* The vendor MEMC state machine can release its screen-rate vote on brief UI
 * events (danmaku toggles, comment panels, feed swipes) while the video
 * SurfaceView is still present. Restoring mode.txt on those events lets the
 * stock LTPS policy drop the display to 60 until the next VIDEOSTART. Defer
 * the exit while the video surface remains, bounded by this grace window. */
static int video_exit_defer_active = 0;
static long long video_exit_defer_until_ms = -1;
/* Hold the video mode while the video SurfaceView is present (restore happens
 * as soon as the surface disappears). The deadline is only a failsafe so a
 * stuck probe can never lock the display at the video rate forever. */
#define VIDEO_EXIT_DEFER_GRACE_MS 120000
static int video_iris_esd_saved_ctrl = -1;
static int video_iris_esd_restore_pending = 0;
static long long video_iris_esd_restore_requested_ms = 0;
static int video_iris_esd_exit_stuck_logged = 0;
static long long video_iris_memc_exit_observed_ms = 0;
/* A third-party player can render directly through SurfaceView without
 * entering ColorOS' Pixelworks MEMC state machine.  Keep this independent
 * from package-specific MEMC hooks so custom LTPO does not mistake a video
 * frame surface for an idle screen. */
static int video_surface_active = 0;
static long long video_surface_last_seen_ms = 0;
static long long video_surface_last_probe_ms = 0;
static char video_surface_package[MAX_PKG_LEN] = "";
static Rmx5200LtpoController rmx5200_ltpo = {
    .touch_fd = -1,
    .ceiling_mode_id = -1,
    .pending_ceiling_mode_id = -1,
    .pending_drop_mode_id = -1,
    .pending_drop_source_id = -1,
    .superseded_drop_mode_id = -1,
};
static int rmx5200_ltpo_runtime_transition = 0;
static int rmx5200_ltpo_runtime_target_id = -1;
static int rmx5200_ltpo_ordered_rise_active = 0;
static int rmx5200_ltpo_oti_pause_override = 0;
static int extension_rates[MAX_EXTENSION_RATES];
static int extension_rate_count = 0;

// Function Prototypes
void sync_android_settings(int id);
void smooth_switch(int target_id);
int get_mode_width(int id);
static int mode_height(int mode_id);
void get_sorted_fps_modes(int width, int *out_ids, int *out_count);
int is_valid_mode(int id);
int get_screen_state(void);
int get_current_system_mode(void);
static int get_current_applied_mode(void);

static int apply_mode_transaction(int target_id, int resolution_change,
                                  int target_density);
static void snapshot_display_overrides(DisplayOverrideState *state);
static void restore_size_override(const DisplayOverrideState *state);
static void snapshot_coloros_settings(ColorOsSettingsState *state);
static int request_coloros_resolution_change(int width, int density,
                                             ColorOsSettingsState *before);
static int finalize_coloros_resolution_settings(int width, int height);
static int coloros_refresh_mode_index(int fps);
static int clear_display_preference(void);
static int prepare_resolution_transaction(int width);
static int queue_native_resolution_adoption(int target_width, int source_width,
                                            int source_density,
                                            long long generation);
static void process_native_resolution_adoption(const char *base_path);
static int wait_for_active_width(int target_width, int timeout_ms);
static int wait_for_override_density(int target_density, int timeout_ms);
static void apply_density_override(int density);
static int ensure_density_override(int target_density, int timeout_ms);
static int mode_for_width_fps(int width, int fps);
static int mode_fps(int mode_id);
static void load_extension_rates(const char *base_path);
static int adfr_lock_test_bypassed(const char *base_path);
static int adfr_lock_requested(const char *base_path);
static int set_surfaceflinger_oti_pause(const char *base_path, int paused);
static void sync_oti_pause_policy(const char *base_path, int force);
#ifndef MURONG_FREE_BUILD
static void set_rmx5200_ltpo_oti_owner(const char *base_path, int owned);
#endif
static void sync_adfr_lock_floor(int mode_id);
static void maintain_adfr_lock(const char *base_path, int mode_id);
static int valid_package_name(const char *package_name);
static int set_surface_flinger_mode(int mode_id);
static int apply_refresh_ladder(int target_id);
static int next_refresh_ladder_step(int active_id, int target_id);
static int native_anchor_for_target(int target_id);
static int prepare_screen_on_reapply_anchor(int target_id);
static int complete_resolution_geometry(int target_id, int target_width);
static int create_display_hook_server(void);
static void handle_display_hook_client(int server_fd, const char *base_path);
void get_foreground_app(char *buffer, int size);
#ifndef MURONG_FREE_BUILD
static int rmx5200_video_surface_probe(const char *foreground_package);
static int start_video_vendor_hold(const char *base_path);
static int start_video_override(const char *base_path, int follow, int fps);
static int stop_video_override(const char *base_path, const char *reason);
static int prepare_video_iris_esd(const char *base_path);
static int restore_video_iris_esd(const char *base_path);
static void recover_video_iris_esd_on_startup(const char *base_path);
static void maybe_restore_video_iris_esd(const char *base_path);
static int open_rmx5200_touch_input(void);
static void handle_rmx5200_touch_input(void);
static void rmx5200_ltpo_touch_released(int was_down);
static int rmx5200_ltpo_process_rise_queue(void);
static int rmx5200_ltpo_switch_runtime_mode(int target_id,
                                            const char *reason);
static void update_rmx5200_ltpo_controller(const char *base_path,
                                           int ceiling_mode_id,
                                           int screen_state);
#endif

#define LOG_FILE "/data/adb/modules/murongchaopin/daemon.log"

void log_msg(const char *fmt, ...) {
    FILE *fp = fopen(LOG_FILE, "a");
    if (fp) {
        va_list args;
        va_start(args, fmt);
        
        // Add timestamp
        time_t now = time(NULL);
        struct tm *t = localtime(&now);
        fprintf(fp, "[%02d-%02d %02d:%02d:%02d] ", 
            t->tm_mon + 1, t->tm_mday, t->tm_hour, t->tm_min, t->tm_sec);
        
        vfprintf(fp, fmt, args);
        fprintf(fp, "\n");
        
        va_end(args);
        fclose(fp);
    }
    
    // Also print to stdout for debugging if running manually
    va_list args2;
    va_start(args2, fmt);
    vprintf(fmt, args2);
    printf("\n");
    va_end(args2);
}

// 工具函数：去除字符串两端空白
char* trim(char* str) {
    char* end;
    while(isspace((unsigned char)*str)) str++;
    if(*str == 0) return str;
    end = str + strlen(str) - 1;
    while(end > str && isspace((unsigned char)*end)) end--;
    *(end+1) = 0;
    return str;
}

static void init_device_model(void) {
    const char *properties[] = {
        "ro.product.vendor.model",
        "ro.product.model"
    };

    for (size_t i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
        char command[128];
        char line[64];
        FILE *fp;

        snprintf(command, sizeof(command), "getprop %s 2>/dev/null", properties[i]);
        fp = popen(command, "r");
        if (!fp) continue;
        if (fgets(line, sizeof(line), fp)) {
            char *value = trim(line);
            if (*value) {
                snprintf(device_model, sizeof(device_model), "%s", value);
                pclose(fp);
                log_msg("Display transition profile: model=%s", device_model);
                return;
            }
        }
        pclose(fp);
    }

    log_msg("Display transition profile: model=unknown (conservative ladder)");
}

/* The settings bridge uses SIGUSR1 after Game Assistant changes its VRR
 * filter.  Do not call logging or SurfaceFlinger from a signal handler. */
static void request_reapply(int signum) {
    (void)signum;
    reapply_requested = 1;
}

static long long monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

#ifndef MURONG_FREE_BUILD
/* Premium runtime bridge. The root-side boot script verifies the signed lease
 * and then writes two files (0644):
 *   <MODDIR>/runtime/premium_enabled   -> "1" or "0"
 *   <MODDIR>/runtime/premium_features  -> comma separated, e.g. custom_ltpo,video_memc
 * The paid build reads them at most once per second (on entry to a paid path)
 * and falls back to the free core whenever the lease is absent, the
 * <MODDIR>/premium directory is missing, or a specific feature is not granted.
 * The free build never compiles this gate nor the paid paths it protects. */
static int premium_global_enabled = 0;
static int premium_feature_custom_ltpo = 0;
static int premium_feature_video_memc = 0;
static int premium_disabled_logged = 0;
static long long premium_gate_refresh_ms = 0;
static const char *premium_base_path = NULL;

static void premium_gate_refresh(void) {
    long long now_ms = monotonic_ms();
    char path[PATH_MAX];
    char line[512];
    FILE *fp;
    struct stat st;

    if (now_ms - premium_gate_refresh_ms < 1000) return;
    premium_gate_refresh_ms = now_ms;

    premium_global_enabled = 0;
    premium_feature_custom_ltpo = 0;
    premium_feature_video_memc = 0;

    if (!premium_base_path || !*premium_base_path) return;

    /* The paid payload directory must exist; otherwise fall back to free. */
    snprintf(path, sizeof(path), "%s/premium", premium_base_path);
    if (stat(path, &st) != 0 || !S_ISDIR(st.st_mode)) return;

    snprintf(path, sizeof(path), "%s/runtime/premium_enabled",
             premium_base_path);
    fp = fopen(path, "r");
    if (fp) {
        if (fgets(line, sizeof(line), fp)) {
            premium_global_enabled = strcmp(trim(line), "1") == 0;
        }
        fclose(fp);
    }
    if (!premium_global_enabled) return;

    snprintf(path, sizeof(path), "%s/runtime/premium_features",
             premium_base_path);
    fp = fopen(path, "r");
    if (fp) {
        if (fgets(line, sizeof(line), fp)) {
            char *cursor = line;

            while (cursor && *cursor) {
                char *next = strpbrk(cursor, ",;\r\n");
                char *feature;

                if (next) *next = '\0';
                feature = trim(cursor);
                if (strcmp(feature, "custom_ltpo") == 0) {
                    premium_feature_custom_ltpo = 1;
                } else if (strcmp(feature, "video_memc") == 0) {
                    premium_feature_video_memc = 1;
                }
                cursor = next ? next + 1 : NULL;
            }
        }
        fclose(fp);
    }
}

static void premium_log_unavailable_once(void) {
    if (!premium_disabled_logged) {
        premium_disabled_logged = 1;
        log_msg("Premium runtime gate: paid feature path is not authorized; "
                "running free core behavior");
    }
}

static int premium_custom_ltpo_enabled(void) {
    premium_gate_refresh();
    if (premium_global_enabled && premium_feature_custom_ltpo) return 1;
    premium_log_unavailable_once();
    return 0;
}

static int premium_video_memc_enabled(void) {
    premium_gate_refresh();
    if (premium_global_enabled && premium_feature_video_memc) return 1;
    premium_log_unavailable_once();
    return 0;
}
#endif

static void add_extension_rate(int fps) {
    if (fps <= 0) return;
    for (int i = 0; i < extension_rate_count; i++) {
        if (extension_rates[i] == fps) return;
    }
    if (extension_rate_count < MAX_EXTENSION_RATES) {
        extension_rates[extension_rate_count++] = fps;
    }
}

static void parse_extension_rate_list(char *value) {
    char *cursor = value;

    while (cursor && *cursor) {
        char *next = strpbrk(cursor, ",;\r\n");
        char *at;
        int fps;

        if (next) *next = '\0';
        at = strrchr(cursor, '@');
        fps = atoi(at ? at + 1 : cursor);
        add_extension_rate(fps);
        cursor = next ? next + 1 : NULL;
    }
}

static void load_extension_rate_file(const char *path, const char *key) {
    FILE *fp = fopen(path, "r");
    char line[4096];

    if (!fp) return;
    while (fgets(line, sizeof(line), fp)) {
        char *value = trim(line);

        if (!*value || *value == '#') continue;
        if (key) {
            size_t key_length = strlen(key);

            if (strncmp(value, key, key_length) != 0 || value[key_length] != '=')
                continue;
            value += key_length + 1;
        }
        parse_extension_rate_list(value);
    }
    fclose(fp);
}

static void load_extension_rates(const char *base_path) {
    char path[PATH_MAX];
    const char *model_key = NULL;

    extension_rate_count = 0;
    if (!base_path || !*base_path) return;

    if (strcmp(device_model, "RMX5200") == 0) model_key = "rmx5200";
    else if (strcmp(device_model, "PLK110") == 0) model_key = "plk110";
    else if (strcmp(device_model, "PJD110") == 0) model_key = "pjd110";
    if (model_key) {
        char key[64];

        snprintf(path, sizeof(path), "%s/config/display_mode_manifest.txt",
                 base_path);
        snprintf(key, sizeof(key), "%s_dtbo_rates", model_key);
        load_extension_rate_file(path, key);
        snprintf(key, sizeof(key), "%s_drm_rates", model_key);
        load_extension_rate_file(path, key);
    }

    snprintf(path, sizeof(path), "%s/runtime/drm_modes.txt", base_path);
    load_extension_rate_file(path, NULL);
    snprintf(path, sizeof(path), "%s/config/custom_refresh_rates.txt", base_path);
    load_extension_rate_file(path, NULL);
    log_msg("Loaded %d dynamic extension refresh rates", extension_rate_count);
}

// 解析 dumpsys SurfaceFlinger 获取模式
void init_display_modes() {
    FILE *fp;
    char line[1024];
    
    // 直接读取 dumpsys SurfaceFlinger 输出，手动解析以提高兼容性
    fp = popen("timeout 4 dumpsys SurfaceFlinger", "r");
    if (fp == NULL) {
        log_msg("Failed to run dumpsys SurfaceFlinger / 执行 dumpsys SurfaceFlinger 失败");
        return;
    }

    mode_count = 0;
    while (fgets(line, sizeof(line), fp) != NULL && mode_count < MAX_MODES) {
        // 查找关键字段: id=, resolution=, vsyncRate=
        // 示例: 
        // Display 0 HWC layers:
        // ... id=0, ... resolution=1264x2780 ... vsyncRate=120.000000
        // 注意：不同设备输出格式可能略有不同，但这些关键字通常存在
        
        char *p_id = strstr(line, "id=");
        char *p_res = strstr(line, "resolution=");
        char *p_fps = strstr(line, "vsyncRate=");
        char *p_group = strstr(line, "group=");
        
        if (p_id && p_res && p_fps) {
            int id = atoi(p_id + 3);
            
            // 解析分辨率 resolution=WxH
            int w = 0, h = 0;
            sscanf(p_res + 11, "%dx%d", &w, &h);
            
            float fps_f = atof(p_fps + 10);
            
            if (w > 0 && h > 0 && fps_f > 0) {
                // 查重
                int exists = 0;
                for(int k=0; k<mode_count; k++) {
                    if(modes[k].id == id) { exists=1; break; }
                }
                if(!exists) {
                    modes[mode_count].id = id;
                    modes[mode_count].width = w;
                    modes[mode_count].height = h;
                    modes[mode_count].fps = (int)(fps_f + 0.5);
                    modes[mode_count].group = p_group ? atoi(p_group + 6) : -1;
                    mode_count++;
                }
            }
        }
    }
    pclose(fp);
    
    // 按 ID 排序 (冒泡排序)
    for (int i = 0; i < mode_count - 1; i++) {
        for (int j = 0; j < mode_count - i - 1; j++) {
            if (modes[j].id > modes[j+1].id) {
                DisplayMode temp = modes[j];
                modes[j] = modes[j+1];
                modes[j+1] = temp;
            }
        }
    }

    log_msg("Loaded %d display modes (HWC) / 已加载 %d 个显示模式 (HWC):", mode_count);
    for(int i=0; i<mode_count; i++) {
        log_msg("ID: %d, FPS: %d, Res: %dx%d, Group: %d", modes[i].id,
                modes[i].fps, modes[i].width, modes[i].height, modes[i].group);
    }
}

/* mode.txt stores durable, human-readable display choices. HWC IDs are runtime
 * details: the first data line is <FHD+|QHD+> <fps>; app lines are either
 * <package> <fps> (inherit the global resolution) or
 * <package> <FHD+|QHD+> <fps>. Existing numeric-ID files remain readable. */
static int minimum_mode_width(void) {
    int minimum = 0;
    for (int i = 0; i < mode_count; i++) {
        if (modes[i].width > 0 && (minimum == 0 || modes[i].width < minimum)) {
            minimum = modes[i].width;
        }
    }
    return minimum;
}

static int maximum_mode_width(void) {
    int maximum = 0;
    for (int i = 0; i < mode_count; i++) {
        if (modes[i].width > maximum) maximum = modes[i].width;
    }
    return maximum;
}

static int resolution_adjust_for_width(int width) {
    int minimum = minimum_mode_width();
    int maximum = maximum_mode_width();

    if (width <= 0 || maximum <= 0) return -1;
    if (width == maximum) return 3;
    if (minimum > 0 && minimum != maximum && width == minimum) return 2;
    return -1;
}

static int resolution_width_for_token(const char *token) {
    int width;
    int height;
    char trailing;

    if (!token) return -1;
    if (strcmp(token, "FHD+") == 0 || strcmp(token, "FHD") == 0 ||
            strcmp(token, "1080P") == 0 || strcmp(token, "1080p") == 0) {
        int minimum = minimum_mode_width();
        return minimum > 0 && minimum != maximum_mode_width() ? minimum : -1;
    }
    if (strcmp(token, "QHD+") == 0 || strcmp(token, "QHD") == 0 ||
            strcmp(token, "2K") == 0 || strcmp(token, "2k") == 0) {
        return maximum_mode_width();
    }
    if (sscanf(token, "%dx%d%c", &width, &height, &trailing) == 2 &&
            width > 0 && height > 0) {
        for (int i = 0; i < mode_count; i++) {
            if (modes[i].width == width && modes[i].height == height) return width;
        }
    }
    return -1;
}

static const char *resolution_token_for_width(int width) {
    static char token[32];
    int minimum = minimum_mode_width();
    int maximum = maximum_mode_width();

    if (width == maximum && maximum > 0) return "QHD+";
    if (width == minimum && minimum > 0 && minimum != maximum) return "FHD+";
    for (int i = 0; i < mode_count; i++) {
        if (modes[i].width == width) {
            snprintf(token, sizeof(token), "%dx%d", width, modes[i].height);
            return token;
        }
    }
    return NULL;
}

static int write_mode_spec_line(FILE *fp, int mode_id) {
    const char *token = resolution_token_for_width(get_mode_width(mode_id));
    int fps = mode_fps(mode_id);
    if (!fp || !token || fps < 30) return 0;
    return fprintf(fp, "%s %d\n", token, fps) > 0;
}

static int write_app_spec_line(FILE *fp, const char *package_name,
                               int mode_id, int global_mode_id) {
    const char *token;
    int fps;
    if (!fp || !valid_package_name(package_name)) return 0;
    token = resolution_token_for_width(get_mode_width(mode_id));
    fps = mode_fps(mode_id);
    if (!token || fps < 30) return 0;
    if (get_mode_width(mode_id) == get_mode_width(global_mode_id)) {
        return fprintf(fp, "%s %d\n", package_name, fps) > 0;
    }
    return fprintf(fp, "%s %s %d\n", package_name, token, fps) > 0;
}

// 读取配置文件
void load_config(const char* base_path) {
    char config_path[512];
    snprintf(config_path, sizeof(config_path), "%s/config/mode.txt", base_path);
    
    FILE *fp = fopen(config_path, "r");
    if (fp == NULL) return;

    char line[256];
    app_config_count = 0;
    int line_num = 0;

    while (fgets(line, sizeof(line), fp) != NULL) {
        char *trimmed = trim(line);
        if (strlen(trimmed) == 0 || trimmed[0] == '#') continue;

        line_num++;
        if (line_num == 1) {
            char resolution[32];
            char trailing[32];
            int fps;
            int width;
            int mode_id;

            if (sscanf(trimmed, "%31s %d %31s", resolution, &fps, trailing) == 2 &&
                    (width = resolution_width_for_token(resolution)) > 0 && fps >= 30 &&
                    (mode_id = mode_for_width_fps(width, fps)) >= 0) {
                default_mode_id = mode_id;
            } else if (sscanf(trimmed, "%d", &mode_id) == 1) {
                /* Legacy <HWC ID> format is rewritten on the next commit. */
                default_mode_id = mode_id;
            } else {
                log_msg("Ignoring invalid global mode.txt entry: %s", trimmed);
            }
        } else {
            // 后续行：包名 刷新率，或 包名 分辨率 刷新率。
            // 同时支持旧的 pkg=id 或 pkg id。
            char *eq = strchr(trimmed, '=');
            char pkg[MAX_PKG_LEN];
            char resolution[32];
            char trailing[32];
            int fps_or_id;
            int width;
            int mode_id = -1;

            if (eq) {
                *eq = ' ';
                if (sscanf(trimmed, "%127s %d", pkg, &fps_or_id) == 2) {
                    mode_id = fps_or_id;
                }
            } else if (sscanf(trimmed, "%127s %31s %d %31s", pkg, resolution,
                              &fps_or_id, trailing) == 3 &&
                    (width = resolution_width_for_token(resolution)) > 0 &&
                    fps_or_id >= 30) {
                mode_id = mode_for_width_fps(width, fps_or_id);
            } else if (sscanf(trimmed, "%127s %d", pkg, &fps_or_id) == 2) {
                if (fps_or_id >= 30) {
                    mode_id = mode_for_width_fps(get_mode_width(default_mode_id),
                                                  fps_or_id);
                } else {
                    mode_id = fps_or_id;
                }
            }
            if (mode_id >= 0 && valid_package_name(pkg) &&
                    app_config_count < MAX_APPS) {
                strncpy(app_configs[app_config_count].package, pkg, MAX_PKG_LEN);
                app_configs[app_config_count].package[MAX_PKG_LEN - 1] = '\0';
                app_configs[app_config_count].mode_id = mode_id;
                app_config_count++;
            }
        }
    }
    fclose(fp);
    log_msg("Config loaded / 配置已加载. Default: %d, Apps: %d", default_mode_id, app_config_count);
}

// 获取当前系统模式ID
int get_current_system_mode() {
    /*
     * Qualcomm Android 16 reports the live HWC mode as
     *   activeMode={id=5, hwcId=5, ...}
     * Older builds used activeConfig=5. Reading only activeConfig made the
     * daemon trust a stale cached target after LTPS/ADFR or a resolution
     * change had moved the panel elsewhere.
     */
    FILE *fp = popen("timeout 4 dumpsys SurfaceFlinger 2>/dev/null", "r");
    if (fp) {
        char line[1024];
        int fallback = -1;
        while (fgets(line, sizeof(line), fp)) {
            int id;
            if (sscanf(line, " activeMode={id=%d", &id) == 1 ||
                sscanf(line, "activeMode={id=%d", &id) == 1) {
                pclose(fp);
                return id;
            }
            if (strstr(line, "mDisplayModePtr={id=") != NULL) {
                const char *p = strstr(line, "mDisplayModePtr={id=") + 20;
                if (sscanf(p, "%d", &id) == 1) fallback = id;
            }
            if (strstr(line, "activeConfig=") != NULL) {
                const char *p = strstr(line, "activeConfig=") + 13;
                if (sscanf(p, "%d", &id) == 1) fallback = id;
            }
        }
        pclose(fp);
        if (fallback >= 0) return fallback;
    }

    // Do not use DisplayManager's mActiveModeId as a numeric fallback here:
    // on RMX5200 it is a framework ID (for example HWC 13 == framework 14),
    // not the SurfaceFlinger/HWC ID accepted by transaction 1035. Returning
    // unknown is safer than accidentally selecting the adjacent overclock.
    return -1;
}

/* SurfaceFlinger's activeMode changes as soon as a mode request becomes the
 * desired policy.  At 1Hz that can be roughly two seconds before HWC applies
 * the new config.  DisplayManager updates mActiveSfDisplayMode only after the
 * composer configChanged callback, so use it for touch-rise completion and
 * never fall back to the pending SurfaceFlinger value here. */
static int get_current_applied_mode(void) {
    FILE *fp = popen("timeout 4 dumpsys display 2>/dev/null", "r");

    if (fp) {
        char line[1024];

        while (fgets(line, sizeof(line), fp)) {
            const char *marker = strstr(
                    line, "mActiveSfDisplayMode=DisplayMode{id=");
            int id;

            if (marker && sscanf(marker +
                    strlen("mActiveSfDisplayMode=DisplayMode{id="),
                    "%d", &id) == 1) {
                pclose(fp);
                return id;
            }
        }
        pclose(fp);
    }
    return -1;
}

// 获取屏幕状态
// 返回: 1=ON(亮屏), 0=OFF/DOZE(息屏/待机), -1=未知(解析失败)
int get_screen_state() {
    FILE *fp = popen("timeout 4 dumpsys display 2>/dev/null", "r");
    if (!fp) return -1;

    char line[256];
    int result = -1;
    while (fgets(line, sizeof(line), fp)) {
        char *p = strstr(line, "mScreenState=");
        const char *val = NULL;
        if (p) {
            val = p + 13; // strlen("mScreenState=")
        } else {
            p = strstr(line, "mGlobalDisplayState=");
            if (p) val = p + 20; // strlen("mGlobalDisplayState=")
        }
        if (!val) continue;

        // 跳过空白
        while (*val == ' ' || *val == '\t') val++;

        if (strncmp(val, "ON", 2) == 0) {
            result = 1;
            break; // 首个 ON 即视为亮屏
        }
        if (strncmp(val, "OFF", 3) == 0 || strncmp(val, "DOZE", 4) == 0) {
            result = 0;
            // 继续扫描，后面的 mScreenState= 可能更准确
        }
    }
    pclose(fp);
    return result;
}

// Read user overrides before a resolution transaction. Refresh-only changes
// deliberately skip this path so they cannot disturb density or app layout.
static void snapshot_display_overrides(DisplayOverrideState *state) {
    memset(state, 0, sizeof(*state));

    FILE *fp = popen("wm density 2>/dev/null", "r");
    if (fp) {
        char line[128];
        while (fgets(line, sizeof(line), fp)) {
            int value;
            if (sscanf(line, "Override density: %d", &value) == 1 && value > 0) {
                state->density = value;
                state->density_valid = 1;
                break;
            }
        }
        pclose(fp);
    }

    fp = popen("wm size 2>/dev/null", "r");
    if (fp) {
        char line[128];
        while (fgets(line, sizeof(line), fp)) {
            int width, height;
            if (sscanf(line, "Override size: %dx%d", &width, &height) == 2 &&
                width > 0 && height > 0) {
                state->size_width = width;
                state->size_height = height;
                state->size_valid = 1;
                break;
            }
        }
        pclose(fp);
    }

    log_msg("Display overrides before resolution switch: density=%s%d size=%s%dx%d",
            state->density_valid ? "" : "none/", state->density,
            state->size_valid ? "" : "none/", state->size_width, state->size_height);
}

static int read_override_density(void) {
    FILE *fp = popen("wm density 2>/dev/null", "r");
    int density = -1;

    if (!fp) return -1;
    char line[128];
    while (fgets(line, sizeof(line), fp)) {
        if (sscanf(line, "Override density: %d", &density) == 1 && density > 0) {
            break;
        }
        density = -1;
    }
    pclose(fp);
    return density;
}

static int read_effective_density(void) {
    FILE *fp = popen("wm density 2>/dev/null", "r");
    int physical = -1;
    int override = -1;

    if (!fp) return -1;
    char line[128];
    while (fgets(line, sizeof(line), fp)) {
        int value;
        if (sscanf(line, "Physical density: %d", &value) == 1 && value > 0) {
            physical = value;
        } else if (sscanf(line, "Override density: %d", &value) == 1 && value > 0) {
            override = value;
        }
    }
    pclose(fp);
    return override > 0 ? override : physical;
}

static int read_density_scale(const char *property, int *values, int capacity) {
    char command[160];
    char line[256];
    char *cursor;
    FILE *fp;
    int count = 0;

    if (!property || !values || capacity <= 0) return 0;
    snprintf(command, sizeof(command), "getprop %s 2>/dev/null", property);
    fp = popen(command, "r");
    if (!fp) return 0;
    if (!fgets(line, sizeof(line), fp)) {
        pclose(fp);
        return 0;
    }
    pclose(fp);

    cursor = line;
    while (*cursor && count < capacity) {
        char *end;
        long value;

        while (*cursor == ',' || isspace((unsigned char)*cursor)) cursor++;
        if (!*cursor) break;
        value = strtol(cursor, &end, 10);
        if (end == cursor || value <= 0 || value > 2000) return 0;
        values[count++] = (int)value;
        cursor = end;
        while (isspace((unsigned char)*cursor)) cursor++;
        if (*cursor && *cursor != ',') return 0;
    }
    return count;
}

static int density_for_resolution(int current_width, int target_width,
                                  int current_density) {
    const char *current_property = NULL;
    const char *target_property = NULL;
    int current_values[16];
    int target_values[16];
    int current_count;
    int target_count;

    int minimum_width = minimum_mode_width();
    int maximum_width = maximum_mode_width();

    if (current_width == maximum_width && target_width == minimum_width &&
            minimum_width != maximum_width) {
        current_property = "ro.density.screenzoom.qdh";
        target_property = "ro.density.screenzoom.fdh";
    } else if (current_width == minimum_width && target_width == maximum_width &&
            minimum_width != maximum_width) {
        current_property = "ro.density.screenzoom.fdh";
        target_property = "ro.density.screenzoom.qdh";
    }

    if (current_property) {
        current_count = read_density_scale(current_property, current_values, 16);
        target_count = read_density_scale(target_property, target_values, 16);
        if (current_count > 0 && current_count == target_count) {
            for (int i = 0; i < current_count; i++) {
                if (current_values[i] == current_density) {
                    log_msg("Mapped ColorOS display-size slot: width=%d->%d "
                            "density=%d->%d index=%d",
                            current_width, target_width, current_density,
                            target_values[i], i);
                    return target_values[i];
                }
            }

            /* A vendor/native transition can update geometry and density in
             * separate callbacks. If the destination density is already
             * active, scaling it again would turn RMX5200's FHD 420 into 315
             * (or QHD 560 into 747) and visibly enlarge/shrink the UI. */
            for (int i = 0; i < target_count; i++) {
                if (target_values[i] == current_density) {
                    log_msg("Destination ColorOS display-size density already active: "
                            "width=%d->%d density=%d index=%d",
                            current_width, target_width, current_density, i);
                    return current_density;
                }
            }
        }
    }

    if (current_width <= 0 || target_width <= 0 || current_density <= 0) {
        return -1;
    }
    return (current_density * target_width + current_width / 2) / current_width;
}

static void restore_size_override(const DisplayOverrideState *state) {
    char cmd[128];

    if (state->size_valid) {
        snprintf(cmd, sizeof(cmd), "wm size %dx%d >/dev/null 2>&1",
                 state->size_width, state->size_height);
        system(cmd);
        log_msg("Display size override restored after resolution switch: %dx%d",
                state->size_width, state->size_height);
    }
}

static int read_setting_int(const char *table, const char *key, int *value) {
    char cmd[256];
    char line[128];
    char *end = NULL;
    long parsed;
    FILE *fp;

    if (!table || !key || !value) return 0;
    snprintf(cmd, sizeof(cmd), "settings get %s %s 2>/dev/null", table, key);
    fp = popen(cmd, "r");
    if (!fp) return 0;
    if (!fgets(line, sizeof(line), fp)) {
        pclose(fp);
        return 0;
    }
    pclose(fp);

    parsed = strtol(trim(line), &end, 10);
    if (end == trim(line) || (*end && !isspace((unsigned char)*end))) return 0;
    if (parsed < -2147483647L || parsed > 2147483647L) return 0;
    *value = (int)parsed;
    return 1;
}

static int write_setting_int(const char *table, const char *key, int value) {
    char cmd[256];
    int rc;

    if (!table || !key) return 0;
    snprintf(cmd, sizeof(cmd), "settings put %s %s %d >/dev/null 2>&1",
             table, key, value);
    rc = system(cmd);
    log_msg("settings put %s/%s=%d rc=%d", table, key, value, rc);
    return rc == 0;
}

static int delete_setting(const char *table, const char *key) {
    char cmd[256];
    int rc;

    if (!table || !key) return 0;
    snprintf(cmd, sizeof(cmd), "settings delete %s %s >/dev/null 2>&1",
             table, key);
    rc = system(cmd);
    log_msg("settings delete %s/%s rc=%d", table, key, rc);
    return rc == 0;
}

static void snapshot_coloros_settings(ColorOsSettingsState *state) {
    memset(state, 0, sizeof(*state));
    state->resolution_adjust_valid = read_setting_int(
        "secure", "oplus_customize_screen_resolution_adjust",
        &state->resolution_adjust);
    state->screen_index_valid = read_setting_int(
        "secure", "user_preferred_screen_index", &state->screen_index);
    state->preferred_resolution_valid =
        read_setting_int("global", "user_preferred_resolution_width",
                         &state->preferred_width) &&
        read_setting_int("global", "user_preferred_resolution_height",
                         &state->preferred_height);
    state->refresh_rate_mode_valid = read_setting_int(
        "secure", "oplus_customize_screen_refresh_rate",
        &state->refresh_rate_mode);

    log_msg("ColorOS settings before switch: resolution_adjust=%s%d screen_index=%s%d "
            "preferred_resolution=%s%dx%d refresh_mode=%s%d",
            state->resolution_adjust_valid ? "" : "none/",
            state->resolution_adjust,
            state->screen_index_valid ? "" : "none/", state->screen_index,
            state->preferred_resolution_valid ? "" : "none/",
            state->preferred_width, state->preferred_height,
            state->refresh_rate_mode_valid ? "" : "none/",
            state->refresh_rate_mode);
}

static void restore_coloros_settings(const ColorOsSettingsState *state) {
    if (state->resolution_adjust_valid) {
        write_setting_int("secure", "oplus_customize_screen_resolution_adjust",
                          state->resolution_adjust);
    } else {
        delete_setting("secure", "oplus_customize_screen_resolution_adjust");
    }

    if (state->screen_index_valid) {
        write_setting_int("secure", "user_preferred_screen_index",
                          state->screen_index);
    } else {
        delete_setting("secure", "user_preferred_screen_index");
    }

    if (state->preferred_resolution_valid) {
        write_setting_int("global", "user_preferred_resolution_width",
                          state->preferred_width);
        write_setting_int("global", "user_preferred_resolution_height",
                          state->preferred_height);
    } else {
        delete_setting("global", "user_preferred_resolution_width");
        delete_setting("global", "user_preferred_resolution_height");
    }

    /* Never touch the resolution backup key. It is ColorOS recovery state. */
    log_msg("Restored ColorOS resolution settings after failed verification");
}

static int request_coloros_resolution_change(int width, int density,
                                             ColorOsSettingsState *before) {
    int adjust;
    int verify_adjust;
    int current_adjust;
    char property_cmd[128];

    adjust = resolution_adjust_for_width(width);
    if (adjust < 0) {
        log_msg("ColorOS resolution sync skipped: unsupported width=%d", width);
        return 0;
    }

    /* Match RMX5200's stock ScreenResolutionFragment. The secure enum is the
     * only cross-resolution trigger: OplusDisplayModeService coordinates WMS,
     * the freeze animation and the physical display as one native operation. */
    if (density > 0) {
        snprintf(property_cmd, sizeof(property_cmd),
                 "setprop persist.sys.display.user_density %d", density);
        if (system(property_cmd) != 0) {
            log_msg("ColorOS density property write failed: density=%d", density);
            return 0;
        }
        /* ColorOS reads user_density while publishing the resolution enum. Set
         * the matching override first so its relayout never uses the default
         * density for the destination geometry. */
        if (!ensure_density_override(density, 1000)) {
            log_msg("ColorOS pre-resolution density failed: density=%d", density);
            return 0;
        }
    }
    snprintf(property_cmd, sizeof(property_cmd),
             "setprop persist.sys.display.screen_resolution %d", adjust);
    if (system(property_cmd) != 0) {
        log_msg("ColorOS resolution property write failed: adjust=%d", adjust);
        return 0;
    }

    if (!read_setting_int("secure", "oplus_customize_screen_resolution_adjust",
                          &current_adjust)) {
        current_adjust = -1;
    }
    if ((current_adjust != adjust &&
         !write_setting_int("secure", "oplus_customize_screen_resolution_adjust",
                            adjust)) ||
        !read_setting_int("secure", "oplus_customize_screen_resolution_adjust",
                          &verify_adjust) ||
        verify_adjust != adjust) {
        log_msg("ColorOS native resolution request failed for width=%d; rolling back",
                width);
        restore_coloros_settings(before);
        return 0;
    }

    log_msg("ColorOS native resolution transition requested: adjust=%d "
            "target_width=%d density=%d already_published=%d",
            adjust, width, density, current_adjust == adjust);
    return 1;
}

static int finalize_coloros_resolution_settings(int width, int height) {
    int adjust;
    int verify_index;
    int verify_width;
    int verify_height;

    adjust = resolution_adjust_for_width(width);
    if (adjust < 0) return 0;

    if (!write_setting_int("secure", "user_preferred_screen_index", adjust) ||
        !read_setting_int("secure", "user_preferred_screen_index",
                          &verify_index) ||
        verify_index != adjust ||
        !write_setting_int("global", "user_preferred_resolution_width", width) ||
        !write_setting_int("global", "user_preferred_resolution_height", height) ||
        !read_setting_int("global", "user_preferred_resolution_width",
                          &verify_width) ||
        !read_setting_int("global", "user_preferred_resolution_height",
                          &verify_height) ||
        verify_width != width || verify_height != height) {
        log_msg("ColorOS preferred resolution finalize failed: target=%dx%d",
                width, height);
        return 0;
    }
    log_msg("ColorOS preferred resolution finalized: %dx%d", width, height);
    return 1;
}

static int coloros_refresh_mode_index(int fps) {
    /* Custom tiers are represented by ColorOS' coarse high-refresh enum; the
     * exact HWC mode remains authoritative in mode.txt. */
    if (fps == 60) return 2;
    if (fps == 90) return 1;
    if (fps == 120) return 3;
    if (fps == 144) return 4;
    if (fps >= 120) return 7;
    return -1;
}

static int set_display_preference(int id) {
    int fps = 0;
    int width = 0;
    int height = 0;
    for (int i = 0; i < mode_count; i++) {
        if (modes[i].id == id) {
            fps = modes[i].fps;
            width = modes[i].width;
            height = modes[i].height;
            break;
        }
    }
    if (fps <= 0 || width <= 0 || height <= 0) return 0;

    char cmd[160];
    snprintf(cmd, sizeof(cmd),
             "cmd display set-user-preferred-display-mode %d %d %d >/dev/null 2>&1",
             width, height, fps);
    int rc = system(cmd);
    log_msg("Framework preferred mode %dx%d@%d requested, rc=%d",
            width, height, fps, rc);
    return rc == 0;
}

static int clear_display_preference(void) {
    int rc = system("cmd display clear-user-preferred-display-mode "
                    ">/dev/null 2>&1");
    log_msg("Framework preferred mode cleared before native resolution, rc=%d",
            rc);
    return rc == 0;
}

static int prepared_resolution_matches(int width, int density) {
    if (!prepared_resolution.valid) return 0;
    if (monotonic_ms() > prepared_resolution.expires_at_ms) {
        log_msg("Prepared resolution expired: target=%d density=%d",
                prepared_resolution.target_width,
                prepared_resolution.target_density);
        prepared_resolution.valid = 0;
        return 0;
    }
    return prepared_resolution.target_width == width &&
           prepared_resolution.target_density == density;
}

static int prepare_resolution_transaction(int width) {
    PreparedResolutionState next;
    int active_id = get_current_system_mode();
    int active_width = get_mode_width(active_id);
    int active_density;
    int target_density;

    memset(&next, 0, sizeof(next));
    if (active_id < 0 || active_width <= 0 || active_width == width) {
        log_msg("Resolution prepare rejected: active=%d/%d target=%d",
                active_id, active_width, width);
        return 0;
    }

    snapshot_display_overrides(&next.display_before);
    snapshot_coloros_settings(&next.coloros_before);
    active_density = read_effective_density();
    if (active_density <= 0) {
        log_msg("Resolution prepare rejected: effective density unavailable");
        return 0;
    }
    target_density = density_for_resolution(active_width, width, active_density);
    if (target_density < 72 || target_density > 2000) {
        log_msg("Resolution prepare rejected: scaled density=%d", target_density);
        return 0;
    }
    if (!clear_display_preference()) return 0;

    next.valid = 1;
    next.target_width = width;
    next.target_density = target_density;
    next.previous_mode_id = active_id;
    next.previous_width = active_width;
    next.expires_at_ms = monotonic_ms() + 10000;
    prepared_resolution = next;
    log_msg("Resolution prepared before Settings native path: target=%d/%ddpi "
            "previous=%d/%dpx",
            width, target_density, active_id, active_width);
    return 1;
}

static void apply_density_override(int density) {
    char cmd[128];

    if (density <= 0) return;
    snprintf(cmd, sizeof(cmd), "wm density %d >/dev/null 2>&1", density);
    int rc = system(cmd);
    log_msg("Display density override requested: %d rc=%d", density, rc);
}

static int ensure_density_override(int target_density, int timeout_ms) {
    int current_density;

    if (target_density <= 0) return 1;
    current_density = read_override_density();
    if (current_density == target_density) {
        log_msg("Display density already correct: %d", target_density);
        return 1;
    }
    apply_density_override(target_density);
    return wait_for_override_density(target_density, timeout_ms);
}

static void restore_density_override(const DisplayOverrideState *state) {
    int rc;

    if (state->density_valid) {
        apply_density_override(state->density);
        return;
    }
    rc = system("wm density reset >/dev/null 2>&1");
    log_msg("Display density override reset after failed resolution, rc=%d", rc);
}

static int wait_for_active_width(int target_width, int timeout_ms) {
    long long started_ms = monotonic_ms();
    long long deadline_ms = started_ms + timeout_ms;

    do {
        int active_id = get_current_system_mode();
        int active_width = get_mode_width(active_id);
        if (active_width == target_width) {
            log_msg("Active display width verified: mode=%d width=%d after=%dms",
                    active_id, active_width,
                    (int)(monotonic_ms() - started_ms));
            return 1;
        }
        usleep(25000);
    } while (monotonic_ms() <= deadline_ms);

    log_msg("Active display width verification timed out: target=%d timeout=%dms",
            target_width, timeout_ms);
    return 0;
}

static int wait_for_active_mode(int target_id, int timeout_ms) {
    long long started_ms = monotonic_ms();
    long long deadline_ms = started_ms + timeout_ms;
    int consecutive_matches = 0;
    int required_matches = rmx5200_ltpo_ordered_rise_active ? 1 : 3;

    do {
#ifndef MURONG_FREE_BUILD
        /* A mode verification may span multiple low-refresh vblanks. Keep
         * draining the nonblocking touch fd so a finger-down is never held
         * behind a 1-2.5 second HWC wait. */
        if (rmx5200_ltpo.active && rmx5200_ltpo.touch_fd >= 0)
            handle_rmx5200_touch_input();
        if (rmx5200_ltpo.active &&
                is_valid_mode(rmx5200_ltpo.pending_ceiling_mode_id) &&
                rmx5200_ltpo.pending_ceiling_mode_id !=
                    rmx5200_ltpo_runtime_target_id) {
            log_msg("Active mode verification interrupted by touch: "
                    "target=%d ceiling=%d", target_id,
                    rmx5200_ltpo.pending_ceiling_mode_id);
            return 0;
        }
#endif
        int active_id = get_current_system_mode();
        if (active_id == target_id) {
            consecutive_matches++;
            if (consecutive_matches >= required_matches) {
                log_msg("Active display mode verified: mode=%d after=%dms",
                        active_id, (int)(monotonic_ms() - started_ms));
                return 1;
            }
        } else {
            consecutive_matches = 0;
        }
        usleep(rmx5200_ltpo_ordered_rise_active ? 25000 : 50000);
    } while (monotonic_ms() <= deadline_ms);

    log_msg("Active display mode verification timed out: target=%d active=%d "
            "timeout=%dms", target_id, get_current_system_mode(), timeout_ms);
    return 0;
}

static int set_surface_flinger_mode(int mode_id) {
    char command[160];
    int rc;

    if (!is_valid_mode(mode_id)) return 0;
    snprintf(command, sizeof(command),
             "service call SurfaceFlinger 1035 i32 %d >/dev/null 2>&1",
             mode_id);
    rc = system(command);
    log_msg("SurfaceFlinger physical mode requested: mode=%d width=%d rc=%d",
            mode_id, get_mode_width(mode_id), rc);
    return rc == 0;
}

/* Extension identity comes from the shared backend manifest and from WebUI's
 * runtime/custom files. Frequency alone cannot identify an extension: WebUI
 * may add any integer timing, while PLK110 165Hz is a stock mode. */
static int is_overclock_mode(int mode_id) {
    int fps = mode_fps(mode_id);

    for (int i = 0; i < extension_rate_count; i++) {
        if (extension_rates[i] == fps) return 1;
    }
    return 0;
}

static int same_mode_geometry(int first_id, int second_id) {
    return get_mode_width(first_id) == get_mode_width(second_id) &&
            mode_height(first_id) == mode_height(second_id);
}

static int commit_refresh_step(int mode_id) {
    int active_id;

    /* SurfaceFlinger's legacy transaction keeps a desired-mode policy in
     * addition to the live HWC mode. Re-issue the live mode first so a stale
     * previous request cannot make the adjacent transaction a no-op. */
    active_id = get_current_system_mode();
    if (is_valid_mode(active_id) && active_id != mode_id) {
        log_msg("Refresh ladder aligns stale policy: active=%d/%dHz",
                active_id, mode_fps(active_id));
        if (!set_surface_flinger_mode(active_id)) return 0;
        usleep(50000);
    }
    if (!set_surface_flinger_mode(mode_id) ||
        !wait_for_active_mode(mode_id, 1500)) {
        log_msg("Refresh ladder step failed: mode=%d fps=%d", mode_id,
                mode_fps(mode_id));
        active_id = get_current_system_mode();
        if (is_valid_mode(active_id) &&
                !rmx5200_ltpo_runtime_transition) {
            sync_android_settings(active_id);
        }
        return 0;
    }
    /* Give the panel one vblank interval beyond verification before issuing an
     * adjacent custom timing. This is deliberately not a cosmetic delay. */
    usleep(20000);
    return 1;
}

static int highest_native_between(int current_id, int target_id) {
    int current_fps = mode_fps(current_id);
    int target_fps = mode_fps(target_id);
    int candidate = -1;
    if (current_fps <= 0 || target_fps <= current_fps) return -1;
    for (int i = 0; i < mode_count; i++) {
        int fps = modes[i].fps;
        if (!same_mode_geometry(current_id, modes[i].id) || is_overclock_mode(modes[i].id) ||
                fps <= current_fps || fps > target_fps) {
            continue;
        }
        if (candidate < 0 || fps > mode_fps(candidate)) candidate = modes[i].id;
    }
    return candidate;
}

static int highest_reachable_overclock(int current_id, int target_id) {
    int current_fps = mode_fps(current_id);
    int target_fps = mode_fps(target_id);
    int limit;
    int candidate = -1;
    if (current_fps <= 0 || target_fps <= current_fps) return -1;
    limit = (current_fps * 110 - 1) / 100;
    for (int i = 0; i < mode_count; i++) {
        int fps = modes[i].fps;
        if (!same_mode_geometry(current_id, modes[i].id) || !is_overclock_mode(modes[i].id) ||
                fps <= current_fps || fps > target_fps || fps > limit) {
            continue;
        }
        if (candidate < 0 || fps > mode_fps(candidate)) candidate = modes[i].id;
    }
    return candidate;
}

/* A panel may accept a sub-10-percent custom jump during an explicit global
 * switch but reject the same edge immediately after the native LTPO boost.
 * On a missing physical receipt, refine only that failed edge through the
 * nearest published custom tier.  This stays dynamic for WebUI-created modes
 * and never changes the fast path when the direct edge succeeds. */
static int nearest_overclock_between(int current_id, int failed_id) {
    int current_fps = mode_fps(current_id);
    int failed_fps = mode_fps(failed_id);
    int candidate = -1;

    if (current_fps <= 0 || failed_fps <= current_fps) return -1;
    for (int i = 0; i < mode_count; i++) {
        int mode_id = modes[i].id;
        int fps = modes[i].fps;

        if (!same_mode_geometry(current_id, mode_id) ||
                !is_overclock_mode(mode_id) || fps <= current_fps ||
                fps >= failed_fps || fps * 100 >= current_fps * 110) {
            continue;
        }
        if (candidate < 0 || fps < mode_fps(candidate)) candidate = mode_id;
    }
    return candidate;
}

static int native_anchor_for_target(int target_id) {
    int target_fps = mode_fps(target_id);
    int candidate = -1;

    if (target_fps <= 0) return -1;
    for (int i = 0; i < mode_count; i++) {
        int fps = modes[i].fps;
        if (!same_mode_geometry(target_id, modes[i].id) ||
                is_overclock_mode(modes[i].id) || fps > target_fps) {
            continue;
        }
        if (candidate < 0 || fps > mode_fps(candidate)) candidate = modes[i].id;
    }
    return candidate;
}

static int immediate_lower_mode(int current_id) {
    int current_fps = mode_fps(current_id);
    int candidate = -1;
    if (current_fps <= 0) return -1;
    for (int i = 0; i < mode_count; i++) {
        int fps = modes[i].fps;
        if (!same_mode_geometry(current_id, modes[i].id) || fps >= current_fps) {
            continue;
        }
        if (candidate < 0 || fps > mode_fps(candidate)) candidate = modes[i].id;
    }
    return candidate;
}

/* Pure transition planner. It deliberately performs no SurfaceFlinger call so
 * the exact path can be unit-tested without a device. */
static int next_refresh_ladder_step(int active_id, int target_id) {
    int active_fps = mode_fps(active_id);
    int target_fps = mode_fps(target_id);
    int next_id;

    if (!is_valid_mode(active_id) || !is_valid_mode(target_id) ||
            !same_mode_geometry(active_id, target_id) || active_id == target_id) {
        return -1;
    }

    if (target_fps > active_fps) {
        next_id = highest_native_between(active_id, target_id);
        if (next_id >= 0) return next_id;
        return highest_reachable_overclock(active_id, target_id);
    }

    if (!is_overclock_mode(active_id)) return target_id;
    return immediate_lower_mode(active_id);
}

/* After DOZE, SurfaceFlinger can report the requested extension mode even
 * though the panel is still running at its stock fallback timing. Re-issuing
 * the extension directly then leaves the panel at that fallback rate. Seed a
 * known native mode first; the normal refresh ladder will perform the
 * adjacent 144 -> 155 -> 165 (or equivalent) steps from there. */
static int prepare_screen_on_reapply_anchor(int target_id) {
    int anchor_id;

    if (!is_valid_mode(target_id)) return 0;
    anchor_id = native_anchor_for_target(target_id);
    if (!is_valid_mode(anchor_id) || anchor_id == target_id) return 1;

    log_msg("Screen ON reapply seeded native anchor: target=%d/%dHz "
            "anchor=%d/%dHz", target_id, mode_fps(target_id),
            anchor_id, mode_fps(anchor_id));
    if (!set_surface_flinger_mode(anchor_id) ||
            !wait_for_active_mode(anchor_id, 1500)) {
        log_msg("Screen ON reapply anchor failed: target=%d/%dHz "
                "anchor=%d/%dHz", target_id, mode_fps(target_id),
                anchor_id, mode_fps(anchor_id));
        return 0;
    }
    current_mode_id = anchor_id;
    return 1;
}

static int apply_refresh_ladder(int target_id) {
    int active_id = current_mode_id;
    int target_fps = mode_fps(target_id);

    if (!is_valid_mode(target_id) || target_fps <= 0) return 0;
    if (!is_valid_mode(active_id) || !same_mode_geometry(active_id, target_id)) {
        log_msg("Refresh ladder has no same-geometry origin: current=%d target=%d; direct",
                active_id, target_id);
        return commit_refresh_step(target_id);
    }
    if (active_id == target_id) return 1;

    if (target_fps > mode_fps(active_id)) {
        while (mode_fps(active_id) < target_fps) {
            int next_id = next_refresh_ladder_step(active_id, target_id);
            if (next_id >= 0 && !is_overclock_mode(next_id)) {
                log_msg("Refresh ladder up stock: %d/%dHz -> %d/%dHz",
                        active_id, mode_fps(active_id), next_id, mode_fps(next_id));
                if (!commit_refresh_step(next_id)) return 0;
                active_id = next_id;
                continue;
            }
            if (next_id < 0) {
                log_msg("Refresh ladder up blocked: current=%d/%dHz target=%d/%dHz limit=%dHz",
                        active_id, mode_fps(active_id), target_id, target_fps,
                        (mode_fps(active_id) * 110 - 1) / 100);
                return 0;
            }
            log_msg("Refresh ladder up custom: %d/%dHz -> %d/%dHz",
                    active_id, mode_fps(active_id), next_id, mode_fps(next_id));
            if (!commit_refresh_step(next_id)) return 0;
            active_id = next_id;
        }
        return 1;
    }

    while (active_id != target_id) {
        int next_id = next_refresh_ladder_step(active_id, target_id);
        if (!is_overclock_mode(active_id) && next_id == target_id) {
            log_msg("Refresh ladder down stock direct: %d/%dHz -> %d/%dHz",
                    active_id, mode_fps(active_id), target_id, target_fps);
            return commit_refresh_step(target_id);
        }
        if (next_id < 0) {
            log_msg("Refresh ladder down blocked: current=%d/%dHz target=%d/%dHz",
                    active_id, mode_fps(active_id), target_id, target_fps);
            return 0;
        }
        log_msg("Refresh ladder down custom: %d/%dHz -> %d/%dHz",
                active_id, mode_fps(active_id), next_id, mode_fps(next_id));
        if (!commit_refresh_step(next_id)) return 0;
        active_id = next_id;
    }
    return 1;
}

static int complete_resolution_geometry(int target_id, int target_width) {
    int geometry_id = target_id;
    /* RMX5200's Android 16 LocalDisplayAdapter ignores the false return from
     * setDesiredDisplayModeSpecs when the requested mode is in another
     * resolution group. Give ColorOS its native transition window first, then
     * select the exact HWC mode and verify the resulting physical width. */
    if (wait_for_active_width(target_width,
                              NATIVE_RESOLUTION_PHYSICAL_FALLBACK_MS)) {
        return 1;
    }
    if (is_overclock_mode(target_id)) {
        int stock_id = native_anchor_for_target(target_id);
        if (stock_id >= 0) geometry_id = stock_id;
    }
    log_msg("ColorOS geometry did not settle; applying stock HWC fallback: "
            "mode=%d target=%d width=%d", geometry_id, target_id, target_width);
    return set_surface_flinger_mode(geometry_id)
            && wait_for_active_width(target_width, 1500);
}

static int wait_for_override_density(int target_density, int timeout_ms) {
    long long started_ms = monotonic_ms();
    long long deadline_ms = started_ms + timeout_ms;

    if (target_density <= 0) return 1;
    do {
        int density = read_override_density();
        if (density == target_density) {
            log_msg("Display density verified: %d after=%dms",
                    density, (int)(monotonic_ms() - started_ms));
            return 1;
        }
        usleep(50000);
    } while (monotonic_ms() <= deadline_ms);
    log_msg("Display density verification timed out: target=%d timeout=%dms",
            target_density, timeout_ms);
    return 0;
}

static void rollback_resolution_transaction(
        int previous_mode_id, int previous_width,
        const DisplayOverrideState *display_before,
        const ColorOsSettingsState *coloros_before) {
    char property_cmd[128];

    prepared_resolution.valid = 0;
    restore_coloros_settings(coloros_before);
    if (coloros_before->resolution_adjust_valid) {
        snprintf(property_cmd, sizeof(property_cmd),
                 "setprop persist.sys.display.screen_resolution %d",
                 coloros_before->resolution_adjust);
        system(property_cmd);
    }
    if (display_before->density_valid) {
        snprintf(property_cmd, sizeof(property_cmd),
                 "setprop persist.sys.display.user_density %d",
                 display_before->density);
        system(property_cmd);
    }

    if (previous_width > 0 &&
        complete_resolution_geometry(previous_mode_id, previous_width)) {
        restore_density_override(display_before);
        if (is_valid_mode(previous_mode_id)) {
            set_display_preference(previous_mode_id);
            wait_for_active_width(previous_width, 500);
        }
    } else {
        log_msg("Resolution rollback could not verify previous physical width=%d; "
                "density left unchanged", previous_width);
    }
    if (is_valid_mode(previous_mode_id)) {
        set_display_preference(previous_mode_id);
    }
    restore_size_override(display_before);
    log_msg("Resolution transaction rolled back to actual pre-switch mode=%d width=%d",
            previous_mode_id, previous_width);
}

static int apply_mode_transaction(int target_id, int resolution_change,
                                  int target_density) {
    DisplayOverrideState before;
    ColorOsSettingsState coloros_before;
    int target_width = 0;
    int target_height = 0;
    int current_width = get_mode_width(current_mode_id);
    int previous_mode_id = current_mode_id;
    int density = target_density;
    int used_prepared_state = 0;

    for (int i = 0; i < mode_count; i++) {
        if (modes[i].id == target_id) {
            target_width = modes[i].width;
            target_height = modes[i].height;
            break;
        }
    }

    if (resolution_change) {
        if (prepared_resolution_matches(target_width, target_density)) {
            before = prepared_resolution.display_before;
            coloros_before = prepared_resolution.coloros_before;
            previous_mode_id = prepared_resolution.previous_mode_id;
            current_width = prepared_resolution.previous_width;
            used_prepared_state = 1;
            prepared_resolution.valid = 0;
        } else {
            snapshot_display_overrides(&before);
            snapshot_coloros_settings(&coloros_before);
        }
        if (density <= 0 && before.density_valid && current_width > 0 &&
            target_width > 0) {
            density = density_for_resolution(current_width, target_width,
                                             before.density);
            log_msg("Resolved density for resolution switch: width=%d->%d density=%d",
                    current_width, target_width, density);
        }
    }

    if (resolution_change) {
        /* Never use SurfaceFlinger transaction 1035 across resolutions. It
         * bypasses ColorOS/WMS' freeze transaction and exposes recursively
         * scaled old/new surfaces. Publish the vendor enum first and wait for
         * OplusDisplayModeService to complete the geometry change. */
        if ((!used_prepared_state && !clear_display_preference()) ||
            !request_coloros_resolution_change(target_width, density,
                                               &coloros_before) ||
            !complete_resolution_geometry(target_id, target_width)) {
            rollback_resolution_transaction(previous_mode_id, current_width,
                                            &before, &coloros_before);
            return 0;
        }

        /* Apply the matching user density as soon as the native geometry is
         * active, before publishing the remaining framework preferences. */
        if (!ensure_density_override(density, 1500)) {
            rollback_resolution_transaction(previous_mode_id, current_width,
                                            &before, &coloros_before);
            return 0;
        }

        /* The native transition chooses a valid rate for the new resolution.
         * Publish a native anchor through DisplayManager so subsequent ColorOS
         * requests remain authoritative; the ladder selects the extension. */
        int preference_id = target_id;
        if (is_overclock_mode(target_id)) {
            int stock_id = native_anchor_for_target(target_id);
            if (stock_id >= 0) preference_id = stock_id;
        }
        if (!set_display_preference(preference_id) ||
            !wait_for_active_width(target_width, 500)) {
            log_msg("Native resolution completed but native anchor failed: "
                    "anchor=%d target=%d", preference_id, target_id);
            rollback_resolution_transaction(previous_mode_id, current_width,
                                             &before, &coloros_before);
            return 0;
        }
        if (!finalize_coloros_resolution_settings(target_width, target_height)) {
            rollback_resolution_transaction(previous_mode_id, current_width,
                                             &before, &coloros_before);
            return 0;
        }
        restore_size_override(&before);
        current_mode_id = get_current_system_mode();
        if (!apply_refresh_ladder(target_id)) {
            log_msg("Native resolution completed but refresh ladder failed: target=%d",
                    target_id);
            rollback_resolution_transaction(previous_mode_id, current_width,
                                             &before, &coloros_before);
            return 0;
        }
        sync_android_settings(target_id);
        return 1;
    }

    /* Each physical step aligns the live HWC policy and publishes only its
     * adjacent mode; the final v2.2 Settings state is written once below. */
    if (!apply_refresh_ladder(target_id)) {
        log_msg("Refresh ladder request failed: target=%d", target_id);
        return 0;
    }
    sync_android_settings(target_id);
    return 1;
}

static int apply_hook_mode_request(const char *base_path, int mode_id,
                                   int width, int density) {
    int active_id;
    int active_density;

    if (prepared_resolution_matches(width, density)) {
        current_mode_id = prepared_resolution.previous_mode_id;
    } else {
        active_id = get_current_system_mode();
        if (is_valid_mode(active_id)) current_mode_id = active_id;
    }
    pending_density_mode_id = mode_id;
    pending_density = density;
    load_config(base_path);

    /* Bridge callers must receive OK only after the physical transaction is
     * complete. Otherwise Settings publishes its selection while HWC still
     * uses the old geometry and ColorOS creates a stale snapshot layer. */
    force_reapply = 0;
    smooth_switch(mode_id);

    active_id = get_current_system_mode();
    active_density = read_override_density();
    if (active_id != mode_id || get_mode_width(active_id) != width ||
        (density > 0 && active_density != density)) {
        log_msg("Display hook mode transaction failed: target=%d/%dpx/%ddpi "
                "active=%d/%dpx/%ddpi",
                mode_id, width, density, active_id,
                get_mode_width(active_id), active_density);
        return 0;
    }

    log_msg("Display hook mode transaction completed: mode=%d width=%d density=%d",
            mode_id, width, density);
    return 1;
}

#ifndef MURONG_FREE_BUILD
static void video_iris_esd_state_path(char *path, size_t size,
                                      const char *base_path) {
    if (!base_path || !*base_path) {
        base_path = "/data/adb/modules/murongchaopin";
    }
    snprintf(path, size, "%s/%s", base_path,
             RMX5200_VIDEO_IRIS_ESD_STATE);
}

static int read_video_iris_esd_ctrl(unsigned int *value) {
    char line[128];
    char *marker;
    char *end;
    unsigned long parsed;
    FILE *fp;

    if (!value) return 0;
    fp = fopen(RMX5200_IRIS_ESD_CTRL_PATH, "r");
    if (!fp) return 0;
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return 0;
    }
    fclose(fp);

    marker = strstr(line, "ctrl:");
    if (!marker) return 0;
    marker += strlen("ctrl:");
    errno = 0;
    parsed = strtoul(marker, &end, 0);
    if (errno || end == marker || parsed > 128UL) return 0;
    *value = (unsigned int)parsed;
    return 1;
}

static int write_video_iris_esd_ctrl(unsigned int value) {
    unsigned int observed;
    FILE *fp;
    int failed;

    if (value > 128U || access(RMX5200_IRIS_ESD_CTRL_PATH, W_OK) != 0)
        return 0;
    fp = fopen(RMX5200_IRIS_ESD_CTRL_PATH, "w");
    if (!fp) return 0;
    failed = fprintf(fp, "%u\n", value) < 0;
    if (fclose(fp) != 0) failed = 1;
    return !failed && read_video_iris_esd_ctrl(&observed) &&
           observed == value;
}

static int video_iris_memc_active(void) {
    char line[64];
    FILE *fp;

    fp = fopen(RMX5200_IRIS_DISPLAY_MODE_PATH, "r");
    if (!fp) return 0;
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return 0;
    }
    fclose(fp);
    return strstr(trim(line), "MEMC") != NULL;
}

static int read_video_iris_esd_saved(const char *base_path,
                                     unsigned int *value) {
    char path[512];
    char line[64];
    char *start;
    char *end;
    unsigned long parsed;
    FILE *fp;

    if (!value) return 0;
    video_iris_esd_state_path(path, sizeof(path), base_path);
    fp = fopen(path, "r");
    if (!fp) return 0;
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return 0;
    }
    fclose(fp);
    errno = 0;
    start = trim(line);
    parsed = strtoul(start, &end, 0);
    if (errno || end == start || parsed > 128UL) return 0;
    *value = (unsigned int)parsed;
    return 1;
}

static int persist_video_iris_esd_saved(const char *base_path,
                                        unsigned int value) {
    char path[512];
    char temporary[560];
    FILE *fp;
    int failed;

    video_iris_esd_state_path(path, sizeof(path), base_path);
    snprintf(temporary, sizeof(temporary), "%s.tmp.%ld", path,
             (long)getpid());
    fp = fopen(temporary, "w");
    if (!fp) return 0;
    failed = fprintf(fp, "%u\n", value) < 0;
    if (!failed && fflush(fp) != 0) failed = 1;
    if (!failed && fsync(fileno(fp)) != 0) failed = 1;
    if (fclose(fp) != 0) failed = 1;
    if (!failed && rename(temporary, path) != 0) failed = 1;
    if (failed) unlink(temporary);
    return !failed;
}

static void remove_video_iris_esd_saved(const char *base_path) {
    char path[512];

    video_iris_esd_state_path(path, sizeof(path), base_path);
    if (unlink(path) != 0 && errno != ENOENT) {
        log_msg("RMX5200 MEMC Iris ESD state cleanup failed: %s",
                strerror(errno));
    }
}

static int prepare_video_iris_esd(const char *base_path) {
    unsigned int current_ctrl;
    unsigned int saved_ctrl;
    unsigned int session_ctrl;

    if (strcmp(device_model, "RMX5200") != 0) return 1;
    video_exit_pending = 0;
    video_iris_esd_restore_pending = 0;
    video_iris_esd_restore_requested_ms = 0;
    video_iris_esd_exit_stuck_logged = 0;
    video_iris_memc_exit_observed_ms = 0;
    if (!read_video_iris_esd_ctrl(&current_ctrl)) {
        log_msg("RMX5200 MEMC Iris ESD control unavailable");
        return 0;
    }

    if (video_iris_esd_saved_ctrl < 0) {
        if (read_video_iris_esd_saved(base_path, &saved_ctrl)) {
            video_iris_esd_saved_ctrl = (int)saved_ctrl;
        } else {
            video_iris_esd_saved_ctrl = (int)current_ctrl;
            if (!persist_video_iris_esd_saved(
                        base_path, (unsigned int)video_iris_esd_saved_ctrl)) {
                video_iris_esd_saved_ctrl = -1;
                log_msg("RMX5200 MEMC Iris ESD state persistence failed");
                return 0;
            }
        }
    }

    /* Bit 0 runs the Iris internal status check. In SINGLE-MEMC the i7p
     * firmware legitimately reports run_status 0x6, which the stock checker
     * mistakes for ESD and converts into a full DPMS recovery. Clear only
     * that bit; bit 2 and the panel's own ESD path remain available. */
    session_ctrl = current_ctrl & ~0x1U;
    if (session_ctrl != current_ctrl) {
        if (!write_video_iris_esd_ctrl(session_ctrl)) {
            log_msg("RMX5200 MEMC Iris ESD self-check pause failed: ctrl=%u",
                    current_ctrl);
            return 0;
        }
        log_msg("RMX5200 MEMC Iris ESD policy: ctrl=%u -> %u "
                "(chip self-check paused, recovery retained)",
                current_ctrl, session_ctrl);
    }
    return 1;
}

static int restore_video_iris_esd(const char *base_path) {
    unsigned int current_ctrl;
    unsigned int saved_ctrl;

    if (strcmp(device_model, "RMX5200") != 0) return 1;
    if (video_iris_esd_saved_ctrl >= 0) {
        saved_ctrl = (unsigned int)video_iris_esd_saved_ctrl;
    } else if (read_video_iris_esd_saved(base_path, &saved_ctrl)) {
        video_iris_esd_saved_ctrl = (int)saved_ctrl;
    } else {
        return 1;
    }

    if (!read_video_iris_esd_ctrl(&current_ctrl) ||
            (current_ctrl != saved_ctrl &&
             !write_video_iris_esd_ctrl(saved_ctrl))) {
        log_msg("RMX5200 MEMC Iris ESD restore failed: wanted=%u",
                saved_ctrl);
        return 0;
    }
    remove_video_iris_esd_saved(base_path);
    video_iris_esd_saved_ctrl = -1;
    video_exit_pending = 0;
    video_iris_esd_restore_pending = 0;
    video_iris_esd_restore_requested_ms = 0;
    video_iris_esd_exit_stuck_logged = 0;
    video_iris_memc_exit_observed_ms = 0;
    if (current_ctrl != saved_ctrl) {
        log_msg("RMX5200 MEMC Iris ESD policy restored: ctrl=%u -> %u",
                current_ctrl, saved_ctrl);
    }
    return 1;
}

static void recover_video_iris_esd_on_startup(const char *base_path) {
    unsigned int saved_ctrl;
    int observed_id;

    if (!premium_video_memc_enabled()) return;
    if (strcmp(device_model, "RMX5200") != 0) return;
    if (!read_video_iris_esd_saved(base_path, &saved_ctrl)) return;
    video_iris_esd_saved_ctrl = (int)saved_ctrl;

    if (!video_iris_memc_active()) {
        restore_video_iris_esd(base_path);
        return;
    }

    /* A daemon update or crash must not turn an active FRC session into an
     * ESD recovery. Reconstruct enough temporary ownership to let the normal
     * VIDEOEND handshake complete against the replacement daemon. */
    observed_id = get_current_system_mode();
    if (is_valid_mode(observed_id)) {
        video_override_active = 1;
        video_override_follow = 0;
        video_override_fps = mode_fps(observed_id);
        video_override_mode_id = observed_id;
        video_override_vendor_owned = 1;
        current_mode_id = observed_id;
        log_msg("Recovered active RMX5200 MEMC session after daemon restart: "
                "holding_mode=%d/%dHz ESD=%u", observed_id,
                mode_fps(observed_id), saved_ctrl);
        return;
    }

    video_exit_pending = 1;
    video_iris_esd_restore_pending = 1;
    video_iris_esd_restore_requested_ms = monotonic_ms();
    log_msg("Recovered RMX5200 MEMC ESD state without a valid display mode; "
            "restore held until Iris exits");
}

static void queue_video_iris_esd_restore(void) {
    if (strcmp(device_model, "RMX5200") != 0 ||
            video_iris_esd_saved_ctrl < 0) return;
    if (!video_iris_esd_restore_pending) {
        video_iris_esd_restore_pending = 1;
        video_iris_esd_restore_requested_ms = monotonic_ms();
        log_msg("RMX5200 MEMC Iris ESD restore deferred until MEMC exit");
    }
}

static void maybe_restore_video_iris_esd(const char *base_path) {
    long long elapsed_ms;
    int observed_id;

    if (!video_iris_esd_restore_pending) return;
    elapsed_ms = monotonic_ms() - video_iris_esd_restore_requested_ms;
    if (video_iris_memc_active()) {
        /* Restoring bit 0 while Iris still reports SINGLE-MEMC makes the
         * stock checker interpret the legitimate FRC run_status 0x6 as ESD.
         * That path performs a DPMS recovery and corrupts the visible frame.
         * Keep the known-good session policy indefinitely; a stuck exit is
         * diagnosable, but must never be converted into a destructive reset. */
        if (elapsed_ms >= RMX5200_VIDEO_IRIS_EXIT_STUCK_LOG_MS &&
                !video_iris_esd_exit_stuck_logged) {
            video_iris_esd_exit_stuck_logged = 1;
            log_msg("RMX5200 MEMC Iris exit still active after %lldms; "
                    "ESD restore held to prevent DPMS recovery", elapsed_ms);
        }
        video_iris_memc_exit_observed_ms = 0;
        return;
    }
    if (video_iris_memc_exit_observed_ms == 0) {
        video_iris_memc_exit_observed_ms = monotonic_ms();
        log_msg("RMX5200 MEMC Iris reached bypass; keeping display ownership "
                "released for "
                "%dms settle window", RMX5200_VIDEO_IRIS_EXIT_SETTLE_MS);
        return;
    }
    if (monotonic_ms() - video_iris_memc_exit_observed_ms <
            RMX5200_VIDEO_IRIS_EXIT_SETTLE_MS) {
        return;
    }
    if (!restore_video_iris_esd(base_path)) return;

    observed_id = get_current_applied_mode();
    if (is_valid_mode(observed_id) && is_valid_mode(default_mode_id) &&
            same_mode_geometry(observed_id, default_mode_id) &&
            observed_id != default_mode_id) {
        current_mode_id = observed_id;
        force_reapply = 1;
        log_msg("Video exit mode drift detected: target=%d/%dHz "
                "applied=%d/%dHz; queued safe reapply",
                default_mode_id, mode_fps(default_mode_id), observed_id,
                mode_fps(observed_id));
    }
    video_override_mode_id = -1;
}

static int resolve_video_override_mode(void) {
    int width;

    if (!video_override_active) return -1;
    if (video_override_vendor_owned) return -1;
    if (video_override_follow) return default_mode_id;
    width = get_mode_width(default_mode_id);
    if (width <= 0 || video_override_fps < 30) return -1;
    return mode_for_width_fps(width, video_override_fps);
}

static int clear_video_override(const char *base_path) {
    (void)base_path;
    queue_video_iris_esd_restore();
    video_exit_pending = video_iris_esd_restore_pending;
    video_override_active = 0;
    video_override_follow = 0;
    video_override_fps = -1;
    video_override_vendor_owned = 0;
    video_exit_defer_active = 0;
    video_exit_defer_until_ms = -1;
    if (!video_exit_pending) video_override_mode_id = -1;
    return 1;
}

static int start_video_vendor_hold(const char *base_path) {
    int observed_id;

    if (!premium_video_memc_enabled()) {
        log_msg("Video temporary mode rejected: premium video_memc not enabled");
        return 0;
    }
    if (video_override_active) {
        log_msg("Vendor MEMC display hold reused: vendor_owned=%c mode=%d/%dHz",
                video_override_vendor_owned ? 'Y' : 'N',
                video_override_mode_id, mode_fps(video_override_mode_id));
        return 1;
    }

    load_config(base_path);
    if (!prepare_video_iris_esd(base_path)) {
        log_msg("Vendor MEMC display hold rejected: Iris ESD session setup failed");
        return 0;
    }
    observed_id = get_current_system_mode();
    if (!is_valid_mode(observed_id) || !is_valid_mode(default_mode_id) ||
            !same_mode_geometry(observed_id, default_mode_id)) {
        restore_video_iris_esd(base_path);
        log_msg("Vendor MEMC display hold rejected: observed=%d default=%d",
                observed_id, default_mode_id);
        return 0;
    }

    /* The vendor owns its 60/90/120 input vote. This owner only suspends the
     * custom LTPO/OTI paths before requestScreenRate() proceeds, preventing a
     * touch boost from replacing that vote with the user's custom ceiling. */
    video_override_active = 1;
    video_override_follow = 0;
    video_override_fps = -1;
    video_override_mode_id = observed_id;
    video_override_vendor_owned = 1;
    video_handoff_active = 0;
    current_mode_id = observed_id;
    sync_oti_pause_policy(base_path, 1);
    update_rmx5200_ltpo_controller(base_path, default_mode_id,
                                   get_screen_state());
    log_msg("Vendor MEMC display hold started: source=%d/%dHz ceiling=%d/%dHz "
            "physical_mode_unchanged=Y",
            observed_id, mode_fps(observed_id), default_mode_id,
            mode_fps(default_mode_id));
    return 1;
}

static int start_video_override(const char *base_path, int follow, int fps) {
    int previous_active = video_override_active;
    int previous_follow = video_override_follow;
    int previous_fps = video_override_fps;
    int previous_mode_id = video_override_mode_id;
    int previous_vendor_owned = video_override_vendor_owned;
    int target_id;
    int width;
    int density;
    int screen_state;

    if (!premium_video_memc_enabled()) {
        log_msg("Video temporary mode rejected: premium video_memc not enabled");
        return 0;
    }
    /* The first mode.txt line is authoritative for both FOLLOW and the
     * resolution used by a fixed output rate. This read never rewrites it. */
    load_config(base_path);
    width = get_mode_width(default_mode_id);
    target_id = follow ? default_mode_id : mode_for_width_fps(width, fps);
    density = read_override_density();
    if (!is_valid_mode(target_id) || width <= 0) {
        log_msg("Video temporary mode rejected: follow=%d fps=%d default=%d",
                follow, fps, default_mode_id);
        return 0;
    }
    if (!prepare_video_iris_esd(base_path)) {
        log_msg("Video temporary mode rejected: Iris ESD session setup failed");
        return 0;
    }
    if (previous_active && !previous_vendor_owned &&
            previous_follow == (follow ? 1 : 0) &&
            previous_fps == (follow ? -1 : fps) &&
            previous_mode_id == target_id) {
        log_msg("Video temporary mode unchanged: policy=%s fps=%d mode=%d",
                follow ? "follow-user-selection" : "fixed",
                mode_fps(target_id), target_id);
        return 1;
    }

    /* RMX5200's low-rate policy may leave the physical mode below the durable
     * user ceiling. A video session is a policy change, not an LTPO activity
     * event, so acquire a separate handoff owner before changing modes. Keep
     * the observed physical mode as the transaction origin: climbing to the
     * durable ceiling first races the vendor's MEMC 60Hz vote and can make Iris
     * see 120 -> 144 -> custom timings while it is entering PT2MEMC. The normal
     * ladder below already handles custom origins and native direct edges. */
    if (!previous_active && strcmp(device_model, "RMX5200") == 0 &&
            is_valid_mode(default_mode_id) &&
            same_mode_geometry(default_mode_id, target_id) &&
            mode_fps(target_id) < mode_fps(default_mode_id)) {
        int observed_id = get_current_system_mode();

        if (!is_valid_mode(observed_id) ||
                !same_mode_geometry(observed_id, default_mode_id)) {
            restore_video_iris_esd(base_path);
            return 0;
        }
        video_handoff_active = 1;
        sync_oti_pause_policy(base_path, 1);
        update_rmx5200_ltpo_controller(base_path, default_mode_id,
                                       get_screen_state());
        current_mode_id = observed_id;
        log_msg("Video refresh handoff acquired physical source: "
                "source=%d/%dHz ceiling=%d/%dHz target=%d/%dHz",
                observed_id, mode_fps(observed_id),
                default_mode_id, mode_fps(default_mode_id), target_id,
                mode_fps(target_id));
    }

    /* Claim the display before submitting the target.  The old ordering set
     * this flag only after the transaction completed, so disabling the LTPO
     * controller subsequently dropped its OTI owner and resumed the vendor
     * 120/60Hz director underneath an otherwise successful 144Hz session. */
    video_override_active = 1;
    video_override_follow = follow ? 1 : 0;
    video_override_fps = follow ? -1 : fps;
    video_override_mode_id = target_id;
    video_override_vendor_owned = 0;
    video_handoff_active = 0;
    video_exit_defer_active = 0;
    video_exit_defer_until_ms = -1;
    screen_state = get_screen_state();
    sync_oti_pause_policy(base_path, 1);
    update_rmx5200_ltpo_controller(base_path, target_id, screen_state);

    if (!apply_hook_mode_request(base_path, target_id, width, density)) {
        log_msg("Video temporary mode failed: follow=%d fps=%d target=%d",
                follow, fps, target_id);
        video_override_active = previous_active;
        video_override_follow = previous_follow;
        video_override_fps = previous_fps;
        video_override_mode_id = previous_mode_id;
        video_override_vendor_owned = previous_vendor_owned;
        if (!previous_active) {
            update_rmx5200_ltpo_controller(base_path, default_mode_id,
                                             screen_state);
            restore_video_iris_esd(base_path);
        }
        sync_oti_pause_policy(base_path, 1);
        return 0;
    }

    log_msg("Video temporary mode started: policy=%s fps=%d mode=%d width=%d "
            "ltpo_suspended=Y oti_paused=Y mode_txt_unchanged=Y",
            follow ? "follow-user-selection" : "fixed", mode_fps(target_id),
             target_id, width);
    return 1;
}

static int stop_video_override(const char *base_path, const char *reason) {
    int target_id;
    int width;
    int density;
    int screen_state;
    int esd_restored;

    if (!video_override_active) {
        maybe_restore_video_iris_esd(base_path);
        return 1;
    }
    if (strcmp(device_model, "RMX5200") == 0 && !video_override_vendor_owned) {
        char defer_pkg[MAX_PKG_LEN] = "";
        get_foreground_app(defer_pkg, sizeof(defer_pkg));
        if (rmx5200_video_surface_probe(defer_pkg)) {
            video_exit_defer_active = 1;
            video_exit_defer_until_ms = monotonic_ms()
                    + VIDEO_EXIT_DEFER_GRACE_MS;
            log_msg("Video temporary mode exit deferred: surface active "
                    "package=%s grace=%dms mode=%d/%dHz",
                    defer_pkg, VIDEO_EXIT_DEFER_GRACE_MS,
                    video_override_mode_id, mode_fps(video_override_mode_id));
            return 1;
        }
    }
    load_config(base_path);
    if (strcmp(device_model, "RMX5200") == 0 &&
            video_iris_esd_saved_ctrl >= 0) {
        /* updateStateMachine(false) has already queued the vendor's MEMC OFF
         * messages when VIDEOEND arrives. The vendor needs OTI and its normal
         * framework floor back to complete that transition. Release both now,
         * but submit no display mode until Iris has reached SLEEP-ABYPASS and
         * completed the settle window. */
        target_id = video_override_mode_id;
        clear_video_override(base_path);
        video_exit_pending = 1;
        update_rmx5200_ltpo_controller(base_path, default_mode_id,
                                       get_screen_state());
        sync_oti_pause_policy(base_path, 1);
        write_setting_int("system", "min_refresh_rate", 60);
        log_msg("Video temporary mode exit requested: reason=%s "
                "released_mode=%d/%dHz waiting_for_iris_bypass=Y "
                "mode_txt_unchanged=Y",
                reason ? reason : "unknown", target_id,
                mode_fps(target_id));
        return 1;
    }
    /* OplusFeatureMEMC releases its screen-rate vote before mIrisMemc=false is
     * observed. That release also resumes OTI, so fixed-rate policy must be
     * reasserted before restoring mode.txt or id0/120 will fall back to
     * id1/60 a few seconds after the video session ends. */
    sync_oti_pause_policy(base_path, 1);
    target_id = default_mode_id;
    width = get_mode_width(target_id);
    density = read_override_density();
    if (!is_valid_mode(target_id) || width <= 0 ||
            !apply_hook_mode_request(base_path, target_id, width, density)) {
        log_msg("Video temporary mode restore failed: reason=%s target=%d",
                reason ? reason : "unknown", target_id);
        return 0;
    }

    esd_restored = clear_video_override(base_path);
    screen_state = get_screen_state();
    update_rmx5200_ltpo_controller(base_path, target_id, screen_state);
    sync_oti_pause_policy(base_path, 1);
    log_msg("Video temporary mode ended: reason=%s restored_mode=%d "
            "mode_txt_unchanged=Y",
            reason ? reason : "unknown", target_id);
    return esd_restored;
}
#endif

// Serialize each requested mode as one transaction. Custom refresh changes
// stay inside apply_refresh_ladder so no caller can bypass the ordered path.
void smooth_switch(int target_id) {
    int observed_id;
    int target_density = -1;
    int screen_on_attempt = screen_on_reapply_pending;

    if (screen_on_attempt) screen_on_reapply_transaction_ok = 0;
    if (pending_density_mode_id == target_id) {
        target_density = pending_density;
        pending_density_mode_id = -1;
        pending_density = -1;
    }

    /* The RMX5200 ADFR property stores its minimum in seven bits. Keep 60/90
     * fixed at their selected rate and clamp every 120+ tier to the hardware
     * maximum floor of 120 before ColorOS observes the mode transaction. */
    sync_adfr_lock_floor(target_id);

    /* SurfaceFlinger's live ID is allowed to move within one geometry as LTPO
     * policy changes the physical rate. Normally keep the requested tier as
     * the origin. A forced replay (screen-on/Game Assistant) must start from
     * the observed mode so it cannot jump directly back into an extension. */
    observed_id = get_current_system_mode();
    if (is_valid_mode(observed_id)) {
        if (!is_valid_mode(current_mode_id) ||
            get_mode_width(current_mode_id) != get_mode_width(observed_id) ||
            force_reapply) {
            log_msg("Refreshed current mode before switch: cached=%d observed=%d",
                    current_mode_id, observed_id);
            current_mode_id = observed_id;
        }
    }

    if (force_reapply) {
        force_reapply = 0;
        if (current_mode_id == target_id || current_mode_id == -1) {
            /* SurfaceFlinger may expose the desired target while the panel
             * is still at its post-DOZE stock fallback. Never submit the
             * extension directly here; seed a native anchor and let the
             * normal ladder restore every intermediate timing. */
            if (!prepare_screen_on_reapply_anchor(target_id)) {
                force_reapply = 1;
                return;
            }
        }
        log_msg("Forced reapply after screen-on, switching to target / 亮屏后强制重放，切换到目标");
    }

    if (current_mode_id == -1) {
        // 首次启动，尝试获取当前系统状态
        int actual = get_current_system_mode();
        if (actual != -1) {
            current_mode_id = actual;
            log_msg("Initialized current mode from system / 从系统初始化当前模式: %d", current_mode_id);
        } else {
            // 获取失败，直接设置并假设成功
            log_msg("First switch (unknown current) / 首次切换 (当前未知): -> %d", target_id);
            if (apply_mode_transaction(target_id, 0, target_density)) {
                current_mode_id = target_id;
            }
            return;
        }
    }

    if (current_mode_id == target_id) {
        if (target_density > 0) {
            apply_density_override(target_density);
        }
        if (screen_on_attempt) screen_on_reapply_transaction_ok = 1;
        return;
    }

    int current_width = get_mode_width(current_mode_id);
    int target_width = get_mode_width(target_id);

    // 如果无法获取宽度（无效ID），直接切换
    if (current_width == 0 || target_width == 0) {
        log_msg("Invalid width / 无效宽度 (curr=%d, target=%d). Direct switch / 直接切换.", current_width, target_width);
        if (apply_mode_transaction(target_id, 0, target_density)) {
            current_mode_id = target_id;
            if (screen_on_attempt) screen_on_reapply_transaction_ok = 1;
        }
        return;
    }

    if (current_width != target_width) {
        log_msg("Resolution change / 分辨率变更: %d -> %d. Direct switch / 直接切换.", current_mode_id, target_id);
        if (apply_mode_transaction(target_id, 1, target_density)) {
            current_mode_id = target_id;
            if (screen_on_attempt) screen_on_reapply_transaction_ok = 1;
        }
        return;
    }

    log_msg("Ordered refresh switch / 阶梯刷新率切换: %d -> %d", current_mode_id, target_id);
    if (apply_mode_transaction(target_id, 0, target_density)) {
        current_mode_id = target_id;
        if (screen_on_attempt) screen_on_reapply_transaction_ok = 1;
    }
}

// 获取前台应用 (使用用户提供的优化逻辑)
void get_foreground_app(char *buffer, int size) {
    // 优先尝试 dumpsys window | grep mCurrentFocus
    FILE* fp = popen("timeout 4 dumpsys window | grep mCurrentFocus", "r");
    if (!fp) {
        log_msg("get_foreground_app: popen failed / popen 失败");
        strncpy(buffer, "unknown", size);
        return;
    }

    char line[1024];
    char* last_valid = NULL;

    while (fgets(line, sizeof(line), fp)) {
        // 确保字符串以null结尾
        line[sizeof(line) - 1] = '\0';

        char* start = strchr(line, '{');
        char* end = strrchr(line, '}');  // 使用最后一个 } 作为结束点

        if (start && end && end > start) {
            // 提取 {} 之间的内容
            size_t len = end - start - 1;
            char inner[256];
            if (len > 0 && len < sizeof(inner) - 1) {  // 预留null终止符空间
                strncpy(inner, start + 1, len);
                inner[len] = '\0';

                // 提取最后一个空格后的内容
                char* last_space = strrchr(inner, ' ');
                char* candidate = last_space ? last_space + 1 : inner;

                // 处理 PopupWindow: 前缀
                char* popup_prefix = strstr(candidate, "PopupWindow:");
                if (popup_prefix) {
                    candidate = popup_prefix + 12;  // 跳过 "PopupWindow:"
                }

                // 处理斜杠后的 activity 名
                char* slash = strchr(candidate, '/');
                if (slash) *slash = '\0';

                // 验证包名格式 - 必须包含点号且长度合理
                size_t candidate_len = strlen(candidate);
                if (candidate_len > 0 && candidate_len < MAX_PKG_LEN) {
                    // 检查是否包含点号（有效包名特征）
                    int has_dot = 0;
                    int has_valid_chars = 1;

                    for (char* p = candidate; *p; p++) {
                        if (*p == '.') has_dot = 1;
                        // 检查是否只包含合法字符（字母、数字、点、下划线）
                        if (!isalnum((unsigned char)*p) && *p != '.' && *p != '_') {
                            has_valid_chars = 0;
                            break;
                        }
                    }

                    // 有效包名必须包含点号，长度至少为3，且包含合法字符
                    if (has_dot && has_valid_chars && candidate_len >= 3) {
                        // 安全地分配新内存
                        char* new_valid = strdup(candidate);
                        if (new_valid) {
                            // 释放之前的内存
                            if (last_valid) free(last_valid);
                            last_valid = new_valid;
                        }
                    }
                }
            }
        }
    }
    pclose(fp);

    // 返回最后一个有效包名或 unknown
    if (last_valid) {
        strncpy(buffer, last_valid, size);
        buffer[size - 1] = '\0';
        free(last_valid);
    } else {
        strncpy(buffer, "unknown", size);
        buffer[size - 1] = '\0';
    }
}

#ifndef MURONG_FREE_BUILD
/* SurfaceView is the common path for hardware-decoded video in Telegram,
 * short-video clients, browsers and standalone players.  The Pixelworks
 * observer is not guaranteed to see those apps, so use SurfaceFlinger's
 * compact layer listing as a package-neutral playback hint.  The probe is
 * intentionally rate-limited and only scans the foreground package. */
static int rmx5200_video_surface_probe(const char *foreground_package) {
    long long now_ms = monotonic_ms();
    int found = 0;

    if (now_ms - video_surface_last_probe_ms <
            RMX5200_VIDEO_SURFACE_PROBE_INTERVAL_MS) {
        return video_surface_active;
    }
    video_surface_last_probe_ms = now_ms;

    if (foreground_package && *foreground_package &&
            strcmp(foreground_package, "unknown") != 0 &&
            strcmp(foreground_package, "android") != 0) {
        char needle[MAX_PKG_LEN + 16];
        FILE *fp;

        snprintf(needle, sizeof(needle), "SurfaceView[%s/",
                 foreground_package);
        fp = popen("timeout 4 dumpsys SurfaceFlinger --list 2>/dev/null", "r");
        if (fp) {
            char line[1024];
            while (fgets(line, sizeof(line), fp)) {
                if (strstr(line, needle) != NULL) {
                    found = 1;
                    break;
                }
            }
            pclose(fp);
        }
    }

    if (found) {
        if (!video_surface_active ||
                strcmp(video_surface_package, foreground_package) != 0) {
            log_msg("RMX5200 video SurfaceView detected: package=%s",
                    foreground_package);
        }
        video_surface_active = 1;
        video_surface_last_seen_ms = now_ms;
        strncpy(video_surface_package, foreground_package,
                sizeof(video_surface_package));
        video_surface_package[sizeof(video_surface_package) - 1] = '\0';
    } else if (video_surface_active &&
            now_ms - video_surface_last_seen_ms >=
                RMX5200_VIDEO_SURFACE_EXIT_GRACE_MS) {
        log_msg("RMX5200 video SurfaceView ended: package=%s age=%lldms",
                video_surface_package,
                now_ms - video_surface_last_seen_ms);
        /* The hold branch refreshes last_activity_ms on every policy tick.
         * Re-anchor it when the surface disappears so the normal ceiling
         * dwell starts at playback end instead of inheriting the stale start
         * timestamp (or remaining pinned by a late video frame). */
        if (rmx5200_ltpo.active) {
            rmx5200_ltpo.last_activity_ms = now_ms;
        }
        video_surface_active = 0;
        video_surface_last_seen_ms = 0;
        video_surface_package[0] = '\0';
    }

    return video_surface_active;
}
#endif

// 检查模式是否有效
int is_valid_mode(int id) {
    for (int i=0; i<mode_count; i++) {
        if (modes[i].id == id) return 1;
    }
    return 0;
}

// 获取模式的宽度
int get_mode_width(int id) {
    for (int i=0; i<mode_count; i++) {
        if (modes[i].id == id) return modes[i].width;
    }
    return 0;
}

static int framework_min_refresh_floor_for_state(int fps, int ltps_enabled,
                                                  int video_session) {
    if (ltps_enabled && !video_session && fps > 60) return 60;
    return fps;
}

static int framework_min_refresh_floor(int fps) {
    int ltps_enabled = strcmp(device_model, "RMX5200") == 0 &&
            !adfr_lock_requested(NULL);
    int video_session = video_override_active || video_handoff_active;

    return framework_min_refresh_floor_for_state(fps, ltps_enabled,
                                                  video_session);
}

// 同步 Android 系统设置 (User Request)
void sync_android_settings(int id) {
    int fps = 0;
    for(int i=0; i<mode_count; i++) {
        if(modes[i].id == id) {
            fps = modes[i].fps;
            break;
        }
    }

    if(fps > 0) {
        char cmd[1024];
        int coloros_mode = coloros_refresh_mode_index(fps);
        int min_fps = framework_min_refresh_floor(fps);
        snprintf(cmd, sizeof(cmd),
            "settings put secure support_highfps 1;"
            "settings put system peak_refresh_rate %d;"
            "settings put system user_refresh_rate %d;"
            "settings put system min_refresh_rate %d;"
            "settings put system default_refresh_rate %d;"
            "settings put global debug.cpurend.vsync true;"
            "settings put global hwui.disable_vsync false",
            fps, fps, min_fps, fps);
        system(cmd);

        if (coloros_mode >= 0) {
            write_setting_int("secure", "oplus_customize_screen_refresh_rate",
                              coloros_mode);
            log_msg("ColorOS refresh setting synchronized: %dHz -> mode=%d",
                    fps, coloros_mode);
        } else {
            /* 170/175/180 are not represented by the stock Settings enum. */
            log_msg("ColorOS refresh setting left unchanged for unsupported "
                    "Settings enum value: %dHz", fps);
        }
        /* The exact HWC mode remains in mode.txt.  These keys are only the
         * ColorOS/Framework display mirror, so keep geometry and screen index
         * aligned after Web or daemon changes as well. */
        int width = get_mode_width(id);
        int height = mode_height(id);
        int adjust = resolution_adjust_for_width(width);
        if (width > 0 && height > 0 && adjust > 0) {
            write_setting_int("secure", "user_preferred_screen_index", adjust);
            write_setting_int("secure", "oplus_customize_screen_resolution_adjust",
                              adjust);
            write_setting_int("global", "user_preferred_resolution_width", width);
            write_setting_int("global", "user_preferred_resolution_height", height);
        }
        if (coloros_mode >= 0) {
            /* The ColorOS observer applies its enum asynchronously and may
             * reset the framework ceiling and floor several hundred
             * milliseconds later. */
            usleep(350000);
        }
        /* Reassert the exact user ceiling after ColorOS has translated its
         * stock enum. In high-refresh mode that observer writes 120 Hz even
         * when mode.txt and user_refresh_rate select an extension such as
         * 165 Hz, which otherwise leaks the MEMC ceiling after video exit. */
        write_setting_int("system", "peak_refresh_rate", fps);
        write_setting_int("system", "user_refresh_rate", fps);
        write_setting_int("system", "default_refresh_rate", fps);
        /* Keep the native RMX5200 LTPS 60 Hz vote reachable while ADFR is
         * enabled; fixed-rate and video sessions retain their target floor. */
        write_setting_int("system", "min_refresh_rate", min_fps);
        sync_adfr_lock_floor(id);
        log_msg("Synced system settings to %dHz with framework floor %dHz / "
                "已同步系统设置到 %dHz，最低刷新率 %dHz",
                fps, min_fps, fps, min_fps);
    }
}

static void sync_adfr_lock_floor(int mode_id) {
    static const char *const paths[] = {
        "/sys/module/rmx5200_adfr_lock/parameters/fixed_min_fps",
        "/sys/kernel/oplus_display/min_fps",
    };
    int fps;
    int floor;
    size_t i;

    if (strcmp(device_model, "RMX5200") != 0 ||
            !adfr_lock_requested(NULL)) return;
    fps = mode_fps(mode_id);
    if (fps <= 0) return;
    floor = fps > 120 ? 120 : fps;

    /* The standalone KO is optional on other backends/builds. If it is not
     * loaded, leave the vendor min_fps node untouched as well. */
    if (access(paths[0], W_OK) != 0) return;
    for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        FILE *fp;
        int write_failed;

        if (access(paths[i], W_OK) != 0) continue;
        fp = fopen(paths[i], "w");
        if (!fp) {
            log_msg("ADFR floor open failed: path=%s errno=%d", paths[i], errno);
            continue;
        }
        write_failed = fprintf(fp, "%d\n", floor) < 0;
        if (fclose(fp) != 0) write_failed = 1;
        if (write_failed) {
            log_msg("ADFR floor write failed: path=%s floor=%d errno=%d",
                    paths[i], floor, errno);
        }
    }
    log_msg("RMX5200 ADFR floor synchronized: target=%dHz floor=%dHz",
            fps, floor);
}

static int adfr_lock_test_bypassed(const char *base_path) {
    char path[512];

    if (base_path && *base_path) {
        snprintf(path, sizeof(path),
                 "%s/config/adfr_lock_test_disabled", base_path);
    } else {
        snprintf(path, sizeof(path),
                 "/data/adb/modules/murongchaopin/config/"
                 "adfr_lock_test_disabled");
    }
    return access(path, F_OK) == 0;
}

static int read_unsigned_file(const char *path, unsigned int *value) {
    char line[64];
    char *end;
    unsigned long parsed;
    FILE *fp;

    if (!path || !value) return 0;
    fp = fopen(path, "r");
    if (!fp) return 0;
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return 0;
    }
    fclose(fp);
    errno = 0;
    parsed = strtoul(trim(line), &end, 0);
    if (errno || end == trim(line) ||
            (*end && !isspace((unsigned char)*end)) || parsed > 0xffffffffUL) {
        return 0;
    }
    *value = (unsigned int)parsed;
    return 1;
}

static int write_unsigned_file(const char *path, unsigned int value, int hex) {
    FILE *fp;
    int failed;

    if (!path || access(path, W_OK) != 0) return 0;
    fp = fopen(path, "w");
    if (!fp) return 0;
    failed = (hex ? fprintf(fp, "0x%x\n", value)
                  : fprintf(fp, "%u\n", value)) < 0;
    if (fclose(fp) != 0) failed = 1;
    return !failed;
}

static int adfr_lock_requested(const char *base_path) {
    char path[512];
    char line[32];
    FILE *fp;

    if (!base_path || !*base_path) {
        base_path = "/data/adb/modules/murongchaopin";
    }
    if (adfr_lock_test_bypassed(base_path)) return 0;
    snprintf(path, sizeof(path), "%s/config/rmx5200_adfr_mode.txt", base_path);
    fp = fopen(path, "r");
    if (!fp) return 0;
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return 0;
    }
    fclose(fp);
    return strcmp(trim(line), "off") == 0;
}

static void rmx5200_oti_state_path(char *path, size_t size,
                                  const char *base_path,
                                  const char *name) {
    if (!base_path || !*base_path)
        base_path = "/data/adb/modules/murongchaopin";
    snprintf(path, size, "%s/config/adfr_lock/%s", base_path, name);
}

static int read_surfaceflinger_oti_pause_state(const char *base_path) {
    char path[512];
    char line[32];
    FILE *fp;

    rmx5200_oti_state_path(path, sizeof(path), base_path, "oti_pause_last");
    fp = fopen(path, "r");
    if (!fp) return -1;
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return -1;
    }
    fclose(fp);
    if (strcmp(trim(line), "paused") == 0) return 1;
    if (strcmp(trim(line), "running") == 0) return 0;
    return -1;
}

static void write_surfaceflinger_oti_pause_state(const char *base_path,
                                                 int paused) {
    char path[512];
    FILE *fp;

    rmx5200_oti_state_path(path, sizeof(path), base_path, "oti_pause_last");
    fp = fopen(path, "w");
    if (!fp) {
        log_msg("RMX5200 OTI shared state write failed: %s", strerror(errno));
        return;
    }
    fprintf(fp, "%s\n", paused ? "paused" : "running");
    fclose(fp);
}

#ifndef MURONG_FREE_BUILD
static void set_rmx5200_ltpo_oti_owner(const char *base_path, int owned) {
    char path[512];
    FILE *fp;

    if (strcmp(device_model, "RMX5200") != 0) return;
    rmx5200_oti_state_path(path, sizeof(path), base_path, "oti_pause_owner");
    if (!owned) {
        unlink(path);
        return;
    }
    fp = fopen(path, "w");
    if (!fp) {
        log_msg("RMX5200 OTI owner write failed: %s", strerror(errno));
        return;
    }
    fprintf(fp, "custom_ltpo\n");
    fclose(fp);
}
#endif

static int set_surfaceflinger_oti_pause(const char *base_path, int paused) {
    const char *command = paused
        ? "service call SurfaceFlinger 22015 i32 1 i32 1 >/dev/null 2>&1"
        : "service call SurfaceFlinger 22015 i32 1 i32 0 >/dev/null 2>&1";
    int rc;

    if (strcmp(device_model, "RMX5200") != 0) return 1;
    rc = system(command);
    if (rc != 0) {
        log_msg("RMX5200 OTI pause transaction failed: paused=%d rc=%d",
                paused, rc);
        return 0;
    }
    write_surfaceflinger_oti_pause_state(base_path, paused);
    log_msg("RMX5200 OTI policy synchronized: %s",
            paused ? "paused for fixed refresh" : "running for LTPO");
    return 1;
}

static void sync_oti_pause_policy(const char *base_path, int force) {
    static int last_pause = -1;
    int pause;
    int recorded_pause;

    if (strcmp(device_model, "RMX5200") != 0) return;
    pause = video_override_active || video_handoff_active ||
            adfr_lock_requested(base_path) ||
            rmx5200_ltpo_oti_pause_override;
    recorded_pause = read_surfaceflinger_oti_pause_state(base_path);
    if (!force && pause == last_pause && pause == recorded_pause) return;
    if (!force && last_pause == pause && recorded_pause != pause) {
        log_msg("RMX5200 OTI shared state drift detected: wanted=%s recorded=%s",
                pause ? "paused" : "running",
                recorded_pause < 0 ? "unknown" :
                    (recorded_pause ? "paused" : "running"));
    }
    if (set_surfaceflinger_oti_pause(base_path, pause)) last_pause = pause;
}

/* ColorOS can write min_fps after service.sh has applied the default-off
 * policy, and that direct sysfs path does not pass through the optional KO
 * hook. Repair only drifted values so normal mode transactions stay quiet. */
static void maintain_adfr_lock(const char *base_path, int mode_id) {
    static const char *const fixed_path =
        "/sys/module/rmx5200_adfr_lock/parameters/fixed_min_fps";
    static const char *const enable_path =
        "/sys/module/rmx5200_adfr_lock/parameters/lock_enable";
    static const char *const active_path =
        "/sys/module/rmx5200_adfr_lock/parameters/lock_active";
    static const char *const config_path =
        "/sys/kernel/oplus_display/adfr_config";
    static const char *const min_fps_path =
        "/sys/kernel/oplus_display/min_fps";
    static long long last_check_ms = 0;
    const unsigned int required_config = 0x101U;
    long long now_ms;
    unsigned int current;
    int fps;
    unsigned int floor;
    int repaired = 0;
    FILE *active;
    int active_value;

    if (strcmp(device_model, "RMX5200") != 0 ||
            !adfr_lock_requested(base_path)) return;
    now_ms = monotonic_ms();
    if (now_ms - last_check_ms < 750) return;
    last_check_ms = now_ms;

    fps = mode_fps(mode_id);
    if (fps <= 0) fps = mode_fps(default_mode_id);
    if (fps <= 0) return;
    floor = (unsigned int)(fps > 120 ? 120 : fps);

    /* Do not touch the vendor nodes unless the matching RMX5200 KO is loaded. */
    if (access(fixed_path, W_OK) != 0 || access(enable_path, W_OK) != 0) return;
    active = fopen(active_path, "r");
    active_value = active ? fgetc(active) : EOF;
    if (active) fclose(active);
    if (active_value != 'Y') {
        if (!write_unsigned_file(enable_path, 1U, 0)) {
            log_msg("ADFR keepalive could not activate the RMX5200 lock KO");
            return;
        }
        repaired = 1;
    }
    if (!read_unsigned_file(fixed_path, &current) || current != floor) {
        if (write_unsigned_file(fixed_path, floor, 0)) repaired = 1;
    }
    if (!read_unsigned_file(config_path, &current) || current != required_config) {
        if (write_unsigned_file(config_path, required_config, 1)) repaired = 1;
    }
    if (!read_unsigned_file(min_fps_path, &current) || current != floor) {
        if (write_unsigned_file(min_fps_path, floor, 0)) repaired = 1;
    }
    if (repaired) {
        log_msg("RMX5200 ADFR keepalive repaired: target=%dHz floor=%uHz "
                "adfr_config=0x101", fps, floor);
    }
}

#ifndef MURONG_FREE_BUILD
static int read_ull_file(const char *path, unsigned long long *value) {
    FILE *fp;
    unsigned long long parsed;

    if (!path || !value) return 0;
    fp = fopen(path, "r");
    if (!fp) return 0;
    if (fscanf(fp, "%llu", &parsed) != 1) {
        fclose(fp);
        return 0;
    }
    fclose(fp);
    *value = parsed;
    return 1;
}

static int read_enabled_file(const char *path) {
    FILE *fp = fopen(path, "r");
    int value;

    if (!fp) return 0;
    value = fgetc(fp);
    fclose(fp);
    return value == 'Y' || value == 'y' || value == '1';
}

static int rmx5200_ltpo_read_physical_commit(
        unsigned long long *count, int *mode_id, int *width, int *height,
        int *refresh, unsigned long long *commit_ns) {
    unsigned long long before;
    unsigned long long after;
    unsigned long long mode;
    unsigned long long physical_width;
    unsigned long long physical_height;
    unsigned long long physical_refresh;
    unsigned long long physical_ns;

    if (!count || !mode_id || !width || !height || !refresh || !commit_ns)
        return 0;
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH, &before) ||
                !read_ull_file(RMX5200_LTPO_PHYSICAL_MODE_PATH, &mode) ||
                !read_ull_file(RMX5200_LTPO_PHYSICAL_WIDTH_PATH,
                               &physical_width) ||
                !read_ull_file(RMX5200_LTPO_PHYSICAL_HEIGHT_PATH,
                               &physical_height) ||
                !read_ull_file(RMX5200_LTPO_PHYSICAL_REFRESH_PATH,
                               &physical_refresh) ||
                !read_ull_file(RMX5200_LTPO_PHYSICAL_NS_PATH, &physical_ns) ||
                !read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH, &after)) {
            return 0;
        }
        if (before == after && mode <= INT_MAX &&
                physical_width <= INT_MAX && physical_height <= INT_MAX &&
                physical_refresh <= INT_MAX) {
            *count = after;
            *mode_id = (int)mode;
            *width = (int)physical_width;
            *height = (int)physical_height;
            *refresh = (int)physical_refresh;
            *commit_ns = physical_ns;
            return 1;
        }
    }
    return 0;
}

static int rmx5200_ltpo_configure_touch_boost(void) {
    if (!read_enabled_file(RMX5200_LTPO_TOUCH_BOOST_READY_PATH)) return 0;
    if (!write_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_ONE_SHOT_PATH, 0U, 0) ||
            !write_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_ENABLED_PATH, 1U, 0)) {
        return 0;
    }
    rmx5200_ltpo.touch_boost_configured = 1;
    return 1;
}

static int rmx5200_ltpo_run_iris_touch_boost(int target_refresh,
                                             int chain_ceiling_refresh) {
    unsigned int successes_before;
    unsigned int failures_before;
    unsigned int skips_before;
    unsigned int successes;
    unsigned int failures;
    unsigned int skips;

    if ((target_refresh != 120 && target_refresh != 144) ||
            chain_ceiling_refresh < target_refresh ||
            chain_ceiling_refresh > 300) return 0;
    if (!rmx5200_ltpo.touch_boost_configured &&
            !rmx5200_ltpo_configure_touch_boost()) {
        log_msg("RMX5200 LTPO Iris pre-boost unavailable");
        return 0;
    }
    if (!read_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_SUCCESSES_PATH,
                            &successes_before) ||
            !read_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_FAILURES_PATH,
                                &failures_before) ||
            !read_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_SKIPS_PATH,
                                &skips_before) ||
            !write_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_TARGET_PATH,
                                 (unsigned int)target_refresh, 0) ||
            !write_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_CHAIN_CEILING_PATH,
                                 (unsigned int)chain_ceiling_refresh, 0) ||
            !write_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_TRIGGER_PATH, 1U, 0)) {
        log_msg("RMX5200 LTPO Iris pre-boost trigger failed");
        return 0;
    }

    for (int waited_us = 0; waited_us <= RMX5200_LTPO_IRIS_BOOST_TIMEOUT_US;
            waited_us += 1000) {
        if (read_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_SUCCESSES_PATH,
                               &successes) && successes > successes_before) {
            log_msg("RMX5200 LTPO Iris pre-boost verified: target=%dHz "
                    "after=%dus", target_refresh, waited_us);
            return target_refresh;
        }
        if ((read_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_FAILURES_PATH,
                                &failures) && failures > failures_before) ||
                (read_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_SKIPS_PATH,
                                    &skips) && skips > skips_before)) {
            log_msg("RMX5200 LTPO Iris pre-boost rejected after=%dus", waited_us);
            return 0;
        }
        usleep(1000);
    }
    log_msg("RMX5200 LTPO Iris pre-boost timed out after=%dus",
            RMX5200_LTPO_IRIS_BOOST_TIMEOUT_US);
    return 0;
}

static void rmx5200_ltpo_clear_pending_drop(const char *reason) {
    if (is_valid_mode(rmx5200_ltpo.pending_drop_mode_id)) {
        log_msg("RMX5200 LTPO pending drop cancelled: reason=%s source=%d/%dHz "
                "target=%d/%dHz", reason,
                rmx5200_ltpo.pending_drop_source_id,
                mode_fps(rmx5200_ltpo.pending_drop_source_id),
                rmx5200_ltpo.pending_drop_mode_id,
                mode_fps(rmx5200_ltpo.pending_drop_mode_id));
    }
    rmx5200_ltpo.pending_drop_mode_id = -1;
    rmx5200_ltpo.pending_drop_source_id = -1;
    rmx5200_ltpo.drop_request_ms = 0;
    rmx5200_ltpo.drop_commit_count = 0;
    rmx5200_drop_clear_pending(&rmx5200_ltpo.drop_state);
}

static void rmx5200_ltpo_supersede_pending_drop(const char *reason) {
    if (!is_valid_mode(rmx5200_ltpo.pending_drop_mode_id)) return;

    rmx5200_ltpo.superseded_drop_mode_id =
            rmx5200_ltpo.pending_drop_mode_id;
    rmx5200_ltpo.superseded_drop_commit_count =
            rmx5200_ltpo.drop_commit_count;
    rmx5200_ltpo.superseded_drop_expires_ms = monotonic_ms() +
            RMX5200_LTPO_SUPERSEDED_DROP_GUARD_MS;
    log_msg("RMX5200 LTPO idle drop superseded: reason=%s generation=%llu "
            "target=%d/%dHz commit=%llu", reason,
            rmx5200_ltpo.drop_state.superseded_drop_generation,
            rmx5200_ltpo.superseded_drop_mode_id,
            mode_fps(rmx5200_ltpo.superseded_drop_mode_id),
            rmx5200_ltpo.superseded_drop_commit_count);
    rmx5200_ltpo_clear_pending_drop(reason);
}

static int rmx5200_ltpo_invalidate_drop_for_activity(const char *reason,
                                                      long long now_ms) {
    int superseded_mode_id = rmx5200_ltpo.pending_drop_mode_id;

    rmx5200_ltpo.last_activity_ms = now_ms;
    rmx5200_drop_supersede_for_activity(&rmx5200_ltpo.drop_state);
    rmx5200_ltpo_supersede_pending_drop(reason);
    return superseded_mode_id;
}

static void rmx5200_ltpo_clear_superseded_drop(void) {
    rmx5200_ltpo.superseded_drop_mode_id = -1;
    rmx5200_ltpo.superseded_drop_commit_count = 0;
    rmx5200_ltpo.superseded_drop_expires_ms = 0;
    rmx5200_drop_clear_superseded(&rmx5200_ltpo.drop_state);
}

static int rmx5200_ltpo_has_required_modes(int ceiling_mode_id) {
    static const int required_fps[] = { 1, 10, 30, 60 };
    int width = get_mode_width(ceiling_mode_id);

    if (width <= 0) return 0;
    for (size_t i = 0; i < sizeof(required_fps) / sizeof(required_fps[0]); i++) {
        if (mode_for_width_fps(width, required_fps[i]) < 0) return 0;
    }
    return 1;
}

static int rmx5200_ltpo_runtime_enabled(const char *base_path,
                                        int ceiling_mode_id,
                                        int screen_state) {
    return strcmp(device_model, "RMX5200") == 0 && screen_state == 1 &&
            !video_override_active && !video_handoff_active &&
            !video_exit_pending &&
            !adfr_lock_requested(base_path) &&
            is_valid_mode(ceiling_mode_id) &&
            read_enabled_file(RMX5200_LTPO_APPLIED_PATH) &&
            read_enabled_file(RMX5200_LTPO_ACTIVITY_REGISTERED_PATH) &&
            read_enabled_file(RMX5200_LTPO_PHYSICAL_HOOK_PATH) &&
            rmx5200_ltpo_has_required_modes(ceiling_mode_id);
}

static int rmx5200_ltpo_allowed_tier(int mode_id, int ceiling_mode_id) {
    int fps = mode_fps(mode_id);
    int ceiling_fps = mode_fps(ceiling_mode_id);

    if (!is_valid_mode(mode_id) || !is_valid_mode(ceiling_mode_id) ||
            !same_mode_geometry(mode_id, ceiling_mode_id) || fps <= 0 ||
            fps > ceiling_fps) {
        return 0;
    }
    if (mode_id == ceiling_mode_id) return 1;
    if (fps == 1 || fps == 10 || fps == 30 || fps == 60 ||
            fps == 120 || fps == 144) {
        return 1;
    }
    return fps > 144 && is_overclock_mode(mode_id);
}

static int rmx5200_ltpo_next_lower_mode(int active_id, int ceiling_mode_id) {
    int active_fps = mode_fps(active_id);
    int candidate = -1;

    if (active_fps <= 1) return -1;
    for (int i = 0; i < mode_count; i++) {
        int mode_id = modes[i].id;
        int fps = modes[i].fps;

        if (fps >= active_fps ||
                !rmx5200_ltpo_allowed_tier(mode_id, ceiling_mode_id)) {
            continue;
        }
        if (candidate < 0 || fps > mode_fps(candidate)) candidate = mode_id;
    }
    return candidate;
}

static int rmx5200_ltpo_next_higher_mode(int active_id,
                                         int ceiling_mode_id) {
    int active_fps = mode_fps(active_id);
    int candidate = -1;

    if (active_fps <= 0 || active_fps >= mode_fps(ceiling_mode_id)) return -1;
    for (int i = 0; i < mode_count; i++) {
        int mode_id = modes[i].id;
        int fps = modes[i].fps;

        if (fps <= active_fps ||
                !rmx5200_ltpo_allowed_tier(mode_id, ceiling_mode_id)) {
            continue;
        }
        if (candidate < 0 || fps < mode_fps(candidate)) candidate = mode_id;
    }
    return candidate;
}

static int rmx5200_ltpo_dwell_ms(int active_id, int ceiling_mode_id) {
    int fps = mode_fps(active_id);

    if (active_id == ceiling_mode_id) return RMX5200_LTPO_CEILING_DWELL_MS;
    if (fps > 60) return RMX5200_LTPO_INTERMEDIATE_HIGH_DWELL_MS;
    if (fps >= 60) return 350;
    if (fps >= 30) return 400;
    if (fps >= 10) return 250;
    return -1;
}

static int rmx5200_ltpo_mode_at_most(int ceiling_mode_id, int requested_fps) {
    int width = get_mode_width(ceiling_mode_id);
    int ceiling_fps = mode_fps(ceiling_mode_id);
    int target_fps = requested_fps < ceiling_fps ? requested_fps : ceiling_fps;
    int candidate = mode_for_width_fps(width, target_fps);

    return candidate >= 0 ? candidate : ceiling_mode_id;
}

static int rmx5200_ltpo_apply_ordered_rise(int target_id) {
    int active_id = current_mode_id;
    int stage_target_id = target_id;
    int success = 0;

    if (mode_fps(target_id) > 144) {
        int native_id = mode_for_width_fps(get_mode_width(target_id), 144);

        if (is_valid_mode(native_id)) stage_target_id = native_id;
    }
    rmx5200_ltpo_ordered_rise_active = 1;
    while (mode_fps(active_id) < mode_fps(stage_target_id)) {
        int next_id = rmx5200_ltpo_next_higher_mode(active_id,
                                                    stage_target_id);

        if (!is_valid_mode(next_id)) goto out;
        log_msg("RMX5200 LTPO rise request: %d/%dHz -> %d/%dHz",
                active_id, mode_fps(active_id), next_id, mode_fps(next_id));
        if (!set_surface_flinger_mode(next_id)) goto out;
        active_id = next_id;
        current_mode_id = next_id;
        if (active_id != stage_target_id) usleep(100000);
    }
    if (!wait_for_active_mode(stage_target_id, 2500)) goto out;
    current_mode_id = stage_target_id;
    rmx5200_ltpo_ordered_rise_active = 0;
    if (stage_target_id != target_id)
        return apply_refresh_ladder(target_id);
    success = 1;
out:
    rmx5200_ltpo_ordered_rise_active = 0;
    return success;
}

static int rmx5200_ltpo_switch_runtime_mode(int target_id,
                                            const char *reason) {
    int switched;
    int source_id;

    if (!is_valid_mode(target_id) || !rmx5200_ltpo.active) return 0;
    if (current_mode_id == target_id) {
        if (rmx5200_ltpo.pending_ceiling_mode_id == target_id)
            rmx5200_ltpo.pending_ceiling_mode_id = -1;
        return 1;
    }
    if (!is_valid_mode(current_mode_id) ||
            !same_mode_geometry(current_mode_id, target_id)) {
        current_mode_id = get_current_system_mode();
    }
    if (!is_valid_mode(current_mode_id) ||
            !same_mode_geometry(current_mode_id, target_id)) {
        log_msg("RMX5200 LTPO transition failed: reason=%s current=%d target=%d",
                reason, current_mode_id, target_id);
        return 0;
    }
    source_id = current_mode_id;

    rmx5200_ltpo_runtime_transition = 1;
    rmx5200_ltpo_runtime_target_id = target_id;
    if (mode_fps(target_id) > mode_fps(current_mode_id)) {
        switched = rmx5200_ltpo_apply_ordered_rise(target_id);
    } else {
        switched = apply_refresh_ladder(target_id);
    }
    rmx5200_ltpo_runtime_transition = 0;
    rmx5200_ltpo_runtime_target_id = -1;
    if (!switched) {
        int observed_id = get_current_system_mode();

        if (is_valid_mode(observed_id) &&
                same_mode_geometry(observed_id, target_id)) {
            current_mode_id = observed_id;
        }
        log_msg("RMX5200 LTPO transition failed: reason=%s current=%d target=%d",
                reason, current_mode_id, target_id);
        return 0;
    }
    log_msg("RMX5200 LTPO transition: reason=%s mode=%d/%dHz -> %d/%dHz",
            reason, source_id, mode_fps(source_id),
            target_id, mode_fps(target_id));
    current_mode_id = target_id;
    if (rmx5200_ltpo.pending_ceiling_mode_id == target_id)
        rmx5200_ltpo.pending_ceiling_mode_id = -1;
    rmx5200_ltpo.last_transition_ms = monotonic_ms();
    return 1;
}

static int rmx5200_ltpo_request_receipted_mode(int source_id, int target_id,
                                               const char *stage) {
    unsigned long long count_before = 0;
    unsigned long long physical_count = 0;
    unsigned long long physical_ns = 0;
    int physical_mode_id = -1;
    int physical_width = 0;
    int physical_height = 0;
    int physical_refresh = 0;
    int waited_us = 0;

    if (!is_valid_mode(source_id) || !is_valid_mode(target_id) ||
            !same_mode_geometry(source_id, target_id) ||
            !read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH, &count_before)) {
        return 0;
    }
    log_msg("RMX5200 LTPO touch rise %s request: %d/%dHz -> %d/%dHz",
            stage, source_id, mode_fps(source_id), target_id,
            mode_fps(target_id));
    if (!set_surface_flinger_mode(target_id)) return 0;
    while (waited_us <= RMX5200_LTPO_PHYSICAL_ANCHOR_TIMEOUT_US) {
        if (rmx5200_ltpo_read_physical_commit(
                    &physical_count, &physical_mode_id, &physical_width,
                    &physical_height, &physical_refresh, &physical_ns) &&
                physical_count > count_before &&
                physical_width == get_mode_width(target_id) &&
                physical_height == mode_height(target_id) &&
                physical_refresh == mode_fps(target_id)) {
            current_mode_id = target_id;
            log_msg("RMX5200 LTPO touch rise %s verified: waited=%dus "
                    "commit=%llu kernel_mode=%d timing=%dx%d@%d",
                    stage, waited_us, physical_count, physical_mode_id,
                    physical_width, physical_height, physical_refresh);
            return 1;
        }
        usleep(1000);
        waited_us += 1000;
    }
    log_msg("RMX5200 LTPO touch rise %s timed out: waited=%dus "
            "count=%llu refresh=%d", stage, waited_us, physical_count,
            physical_refresh);
    return 0;
}

/* Start an asynchronous high-rate rise.  The old implementation waited for
 * every overclock DSI receipt in the input callback; a delayed first custom
 * timing therefore froze touch dispatch for the full 500ms timeout.  Keep the
 * same ordered ladder, but let the 100ms controller tick advance one receipt
 * at a time. */
static int rmx5200_ltpo_start_rise_queue(int target_id,
                                         int native_anchor_refresh) {
    int active_id = current_mode_id;
    int anchor_id = -1;
    int next_id;
    unsigned long long commit_count = 0;

    if (!is_valid_mode(active_id) || !is_valid_mode(target_id) ||
            !same_mode_geometry(active_id, target_id) ||
            mode_fps(target_id) <= 144) {
        return 0;
    }
    if (rmx5200_ltpo.rise_queue_active) return 1;

    rmx5200_ltpo_runtime_transition = 1;
    rmx5200_ltpo_runtime_target_id = target_id;
    rmx5200_ltpo_ordered_rise_active = 1;

    if ((native_anchor_refresh == 120 || native_anchor_refresh == 144) &&
            mode_fps(active_id) < native_anchor_refresh) {
        anchor_id = mode_for_width_fps(get_mode_width(target_id),
                                       native_anchor_refresh);
        if (!is_valid_mode(anchor_id) ||
                !same_mode_geometry(anchor_id, target_id)) {
            goto failed;
        }
        /* A successful synchronous KO pre-boost means AE084 is already at the
         * native anchor. Adopt that physical state and immediately submit the
         * first strictly-under-10-percent custom step. Re-submitting 144Hz here
         * adds an old-1Hz logical receipt wait before the custom ladder and is
         * visible as a separate 144Hz dwell. */
        active_id = anchor_id;
        current_mode_id = anchor_id;
        log_msg("RMX5200 LTPO async rise adopted physical native anchor: "
                "%d/%dHz target=%d/%dHz", anchor_id, mode_fps(anchor_id),
                target_id, mode_fps(target_id));
    }

    if (mode_fps(active_id) >= mode_fps(target_id)) goto failed;
    next_id = next_refresh_ladder_step(active_id, target_id);
    if (!is_valid_mode(next_id) || !is_overclock_mode(next_id) ||
            !read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH, &commit_count) ||
            !set_surface_flinger_mode(next_id)) {
        goto failed;
    }

    rmx5200_ltpo.rise_queue_active = 1;
    rmx5200_ltpo.rise_queue_target_id = target_id;
    rmx5200_ltpo.rise_queue_current_id = active_id;
    rmx5200_ltpo.rise_queue_pending_id = next_id;
    rmx5200_ltpo.rise_queue_commit_count = commit_count;
    rmx5200_ltpo.rise_queue_request_ms = monotonic_ms();
    rmx5200_ltpo.rise_queue_steps = 1;
    current_mode_id = active_id;
    log_msg("RMX5200 LTPO async rise queued: %d/%dHz -> %d/%dHz "
            "target=%d/%dHz", active_id, mode_fps(active_id), next_id,
            mode_fps(next_id), target_id, mode_fps(target_id));
    rmx5200_ltpo_ordered_rise_active = 0;
    return 1;

failed:
    rmx5200_ltpo_ordered_rise_active = 0;
    rmx5200_ltpo_runtime_transition = 0;
    rmx5200_ltpo_runtime_target_id = -1;
    return 0;
}

static int rmx5200_ltpo_process_rise_queue(void) {
    unsigned long long physical_count = 0;
    unsigned long long physical_ns = 0;
    int physical_mode_id = -1;
    int physical_width = 0;
    int physical_height = 0;
    int physical_refresh = 0;
    long long now_ms;
    int pending_id;
    int target_id;
    int next_id;
    unsigned long long commit_count = 0;

    if (!rmx5200_ltpo.rise_queue_active) return 0;
    pending_id = rmx5200_ltpo.rise_queue_pending_id;
    target_id = rmx5200_ltpo.rise_queue_target_id;
    now_ms = monotonic_ms();

    if (is_valid_mode(pending_id) && rmx5200_ltpo_read_physical_commit(
                &physical_count, &physical_mode_id, &physical_width,
                &physical_height, &physical_refresh, &physical_ns) &&
            physical_count > rmx5200_ltpo.rise_queue_commit_count &&
            physical_width == get_mode_width(pending_id) &&
            physical_height == mode_height(pending_id) &&
            physical_refresh == mode_fps(pending_id)) {
        rmx5200_ltpo.rise_queue_current_id = pending_id;
        current_mode_id = pending_id;
        log_msg("RMX5200 LTPO async rise receipt: mode=%d/%dHz "
                "after=%lldms commit=%llu", pending_id, mode_fps(pending_id),
                now_ms - rmx5200_ltpo.rise_queue_request_ms, physical_count);
        if (pending_id == target_id) {
            rmx5200_ltpo.rise_queue_active = 0;
            rmx5200_ltpo.rise_queue_pending_id = -1;
            rmx5200_ltpo.pending_ceiling_mode_id = -1;
            rmx5200_ltpo.touch_direct_request_ms = 0;
            rmx5200_ltpo.touch_direct_commit_count = 0;
            rmx5200_ltpo.touch_direct_retries = 0;
            rmx5200_ltpo.last_transition_ms = physical_ns
                    ? (long long)(physical_ns / 1000000ULL) : now_ms;
            rmx5200_ltpo_runtime_transition = 0;
            rmx5200_ltpo_runtime_target_id = -1;
            log_msg("RMX5200 LTPO async rise complete: target=%d/%dHz "
                    "steps=%d", target_id, mode_fps(target_id),
                    rmx5200_ltpo.rise_queue_steps);
            return 0;
        }

        next_id = next_refresh_ladder_step(pending_id, target_id);
        if (!is_valid_mode(next_id) || !is_overclock_mode(next_id) ||
                !read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH,
                               &commit_count) ||
                !set_surface_flinger_mode(next_id)) {
            log_msg("RMX5200 LTPO async rise stopped: next step unavailable "
                    "current=%d target=%d", pending_id, target_id);
            rmx5200_ltpo.rise_queue_active = 0;
            rmx5200_ltpo.rise_queue_pending_id = -1;
            rmx5200_ltpo_runtime_transition = 0;
            rmx5200_ltpo_runtime_target_id = -1;
            return 0;
        }
        rmx5200_ltpo.rise_queue_current_id = pending_id;
        rmx5200_ltpo.rise_queue_pending_id = next_id;
        rmx5200_ltpo.rise_queue_commit_count = commit_count;
        rmx5200_ltpo.rise_queue_request_ms = now_ms;
        rmx5200_ltpo.rise_queue_steps++;
        log_msg("RMX5200 LTPO async rise queued: %d/%dHz -> %d/%dHz "
                "target=%d/%dHz", pending_id, mode_fps(pending_id), next_id,
                mode_fps(next_id), target_id, mode_fps(target_id));
        return 1;
    }

    next_id = nearest_overclock_between(
            rmx5200_ltpo.rise_queue_current_id, pending_id);
    if (is_valid_mode(next_id) &&
            now_ms - rmx5200_ltpo.rise_queue_request_ms >=
                RMX5200_LTPO_RISE_REFINE_TIMEOUT_MS &&
            read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH,
                          &commit_count) &&
            set_surface_flinger_mode(next_id)) {
        log_msg("RMX5200 LTPO async rise refines timed-out edge: "
                "%d/%dHz -> %d/%dHz instead of %d/%dHz target=%d/%dHz",
                rmx5200_ltpo.rise_queue_current_id,
                mode_fps(rmx5200_ltpo.rise_queue_current_id), next_id,
                mode_fps(next_id), pending_id, mode_fps(pending_id),
                target_id, mode_fps(target_id));
        rmx5200_ltpo.rise_queue_pending_id = next_id;
        rmx5200_ltpo.rise_queue_commit_count = commit_count;
        rmx5200_ltpo.rise_queue_request_ms = now_ms;
        rmx5200_ltpo.rise_queue_steps++;
        return 1;
    }
    if (now_ms - rmx5200_ltpo.rise_queue_request_ms <
            RMX5200_LTPO_RISE_STEP_TIMEOUT_MS) {
        return 1;
    }
    log_msg("RMX5200 LTPO async rise step timed out: current=%d/%dHz "
            "pending=%d/%dHz target=%d/%dHz", current_mode_id,
            mode_fps(current_mode_id), pending_id, mode_fps(pending_id),
            target_id, mode_fps(target_id));
    rmx5200_ltpo.rise_queue_active = 0;
    rmx5200_ltpo.rise_queue_pending_id = -1;
    rmx5200_ltpo.pending_ceiling_mode_id = -1;
    rmx5200_ltpo.touch_direct_request_ms = 0;
    rmx5200_ltpo.touch_direct_commit_count = 0;
    rmx5200_ltpo_runtime_transition = 0;
    rmx5200_ltpo_runtime_target_id = -1;
    rmx5200_ltpo.last_activity_ms = now_ms;
    return 0;
}

static int rmx5200_ltpo_submit_touch_rise(int target_id,
                                          int native_anchor_refresh) {
    int active_id = current_mode_id;
    int submitted = 0;
    int submitted_steps = 0;
    long long started_ms = monotonic_ms();

    if (!is_valid_mode(active_id) || !is_valid_mode(target_id) ||
            !same_mode_geometry(active_id, target_id)) {
        return 0;
    }
    if (mode_fps(target_id) > 144) {
        return rmx5200_ltpo_start_rise_queue(target_id, native_anchor_refresh);
    }
    rmx5200_ltpo_runtime_transition = 1;
    rmx5200_ltpo_runtime_target_id = target_id;
    rmx5200_ltpo_ordered_rise_active = 1;

    /* A successful KO pre-boost means the selected native 120/144 timing has
     * already reached AE084 directly. Adopt that physical anchor immediately,
     * then queue the same mode once so SurfaceFlinger catches up without a
     * lower intermediate timing. Never wait for a second anchor receipt: the
     * final pending-ceiling verifier owns that asynchronous logical sync. */
    if ((native_anchor_refresh == 120 || native_anchor_refresh == 144) &&
            mode_fps(active_id) < native_anchor_refresh &&
            mode_fps(target_id) >= native_anchor_refresh) {
        int anchor_id = mode_for_width_fps(get_mode_width(target_id),
                                           native_anchor_refresh);

        if (!is_valid_mode(anchor_id) ||
                !same_mode_geometry(anchor_id, target_id)) {
            log_msg("RMX5200 LTPO native pre-boost anchor unavailable: "
                    "current=%d/%dHz target=%d/%dHz", active_id,
                    mode_fps(active_id), target_id, mode_fps(target_id));
            goto out;
        }
        log_msg("RMX5200 LTPO native pre-boost adopted: %d/%dHz -> %d/%dHz "
                "target=%d/%dHz", active_id, mode_fps(active_id), anchor_id,
                mode_fps(anchor_id), target_id, mode_fps(target_id));
        active_id = anchor_id;
        current_mode_id = anchor_id;
        submitted = 1;
        submitted_steps++;
        if (!set_surface_flinger_mode(anchor_id)) goto out;
    }

    /* The KO pre-boost can itself be the user's selected native ceiling. */
    if (active_id == target_id) goto out;

    /* QHD144 is both a native ceiling and the stock bridge into the
     * 150-180Hz extension ladder. A 144Hz ceiling therefore rises straight
     * from the low timing to 144Hz; only a higher custom ceiling continues
     * from that anchor through strictly-under-10-percent steps. The KO-owned
     * native 120/144Hz anchor above is never submitted a second time. */
    if (mode_fps(target_id) >= 144) {
        int anchor_id;

        if (mode_fps(active_id) <= 30 && !native_anchor_refresh) {
            log_msg("RMX5200 LTPO touch rise high-rate anchor unavailable: "
                    "current=%d/%dHz target=%d/%dHz", active_id,
                    mode_fps(active_id), target_id, mode_fps(target_id));
            goto out;
        }
        if (mode_fps(active_id) < 144) {
            anchor_id = mode_for_width_fps(get_mode_width(target_id), 144);
            submitted = 1;
            if (!is_valid_mode(anchor_id)) {
                goto out;
            }

            /* When 144Hz is the selected native ceiling, submit it once and
             * leave the matching DSI receipt to pending-ceiling settlement.
             * Blocking this touch handler for 500ms used to turn a delayed
             * (but valid) 144Hz commit into failure, clear rise ownership and
             * start the 120->60 descent while the finger was still active. */
            if (anchor_id == target_id) {
                log_msg("RMX5200 LTPO touch rise native ceiling queued: "
                        "%d/%dHz -> %d/%dHz", active_id,
                        mode_fps(active_id), anchor_id,
                        mode_fps(anchor_id));
                if (!set_surface_flinger_mode(anchor_id)) goto out;
                active_id = anchor_id;
                current_mode_id = anchor_id;
                submitted_steps++;
                goto out;
            }

            if (!rmx5200_ltpo_request_receipted_mode(
                        active_id, anchor_id, "native-144-anchor")) {
                goto out;
            }
            active_id = anchor_id;
            submitted_steps++;
        }
        while (mode_fps(active_id) < mode_fps(target_id)) {
            int next_id = next_refresh_ladder_step(active_id, target_id);

            if (!is_valid_mode(next_id) || !is_overclock_mode(next_id))
                goto out;
            submitted = 1;
            if (!rmx5200_ltpo_request_receipted_mode(
                        active_id, next_id, "custom-step")) {
                goto out;
            }
            active_id = next_id;
            submitted_steps++;
        }
        goto out;
    }

    /* Stock timings may be selected directly. Added timings still need the
     * ordered logical ladder, but the AE084 pre-boost has already submitted
     * the native 120Hz panel payload. Queue every logical step without an
     * artificial dwell, then let the physical DSI receipt verify only the
     * user's final ceiling. */
    if (!is_overclock_mode(target_id)) {
        log_msg("RMX5200 LTPO touch rise direct native: %d/%dHz -> %d/%dHz",
                active_id, mode_fps(active_id), target_id,
                mode_fps(target_id));
        if (!set_surface_flinger_mode(target_id)) goto out;
        active_id = target_id;
        current_mode_id = target_id;
        submitted = 1;
        submitted_steps = 1;
        goto out;
    }

    while (mode_fps(active_id) < mode_fps(target_id)) {
        int next_id = next_refresh_ladder_step(active_id, target_id);

        if (!is_valid_mode(next_id)) goto out;
        if (is_overclock_mode(next_id) &&
                mode_fps(next_id) * 100 >= mode_fps(active_id) * 110) {
            log_msg("RMX5200 LTPO touch rise blocked by strict 10%% limit: "
                    "%d/%dHz -> %d/%dHz", active_id, mode_fps(active_id),
                    next_id, mode_fps(next_id));
            goto out;
        }
        log_msg("RMX5200 LTPO touch rise burst: %d/%dHz -> %d/%dHz",
                active_id, mode_fps(active_id), next_id, mode_fps(next_id));
        if (!set_surface_flinger_mode(next_id)) goto out;
        active_id = next_id;
        current_mode_id = next_id;
        submitted = 1;
        submitted_steps++;
    }
out:
    rmx5200_ltpo_ordered_rise_active = 0;
    rmx5200_ltpo_runtime_transition = 0;
    rmx5200_ltpo_runtime_target_id = -1;
    if (submitted) {
        log_msg("RMX5200 LTPO touch rise queue complete: target=%d/%dHz "
                "steps=%d elapsed=%lldms success=%d", target_id,
                mode_fps(target_id), submitted_steps,
                monotonic_ms() - started_ms, active_id == target_id);
    }
    return submitted && active_id == target_id;
}

static int rmx5200_ltpo_touch_boost(void) {
    long long now_ms = monotonic_ms();
    unsigned long long commit_count = 0;
    int ceiling_id;
    int observed_id;
    int native_anchor_refresh = 0;
    int superseded_mode_id;

    if (!premium_custom_ltpo_enabled()) return 0;
    if (!rmx5200_ltpo.active) {
        rmx5200_ltpo.last_activity_ms = now_ms;
        return 0;
    }
    superseded_mode_id = rmx5200_ltpo_invalidate_drop_for_activity(
            "touch-down", now_ms);
    if (now_ms - rmx5200_ltpo.last_touch_boost_ms <
            RMX5200_LTPO_TOUCH_DEBOUNCE_MS) {
        return 1;
    }
    rmx5200_ltpo.last_touch_boost_ms = now_ms;
    ceiling_id = rmx5200_ltpo.ceiling_mode_id;
    rmx5200_ltpo.pending_ceiling_mode_id = ceiling_id;
    if (is_valid_mode(superseded_mode_id) &&
            same_mode_geometry(superseded_mode_id, ceiling_id) &&
            mode_fps(superseded_mode_id) < mode_fps(ceiling_id)) {
        current_mode_id = superseded_mode_id;
        log_msg("RMX5200 LTPO touch rise conservatively replays from "
                "superseded drop: source=%d/%dHz ceiling=%d/%dHz",
                superseded_mode_id, mode_fps(superseded_mode_id), ceiling_id,
                mode_fps(ceiling_id));
    }
    if (rmx5200_ltpo_runtime_transition &&
            rmx5200_ltpo_runtime_target_id == ceiling_id) {
        return 1;
    }
    if (!is_valid_mode(current_mode_id) ||
            !same_mode_geometry(current_mode_id, ceiling_id)) {
        observed_id = get_current_system_mode();
        if (is_valid_mode(observed_id) &&
                same_mode_geometry(observed_id, ceiling_id)) {
            current_mode_id = observed_id;
        }
    }
    if (mode_fps(current_mode_id) < mode_fps(ceiling_id) &&
            read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH,
                          &commit_count)) {
        rmx5200_ltpo.touch_direct_request_ms = now_ms;
        if (mode_fps(current_mode_id) <= 30) {
            int target_fps = mode_fps(ceiling_id);

            native_anchor_refresh = rmx5200_ltpo_run_iris_touch_boost(
                    target_fps >= 144 ? 144 : 120, target_fps);
        }
        if (!rmx5200_ltpo_submit_touch_rise(ceiling_id,
                                             native_anchor_refresh)) {
            rmx5200_ltpo.pending_ceiling_mode_id = -1;
            rmx5200_ltpo.touch_direct_request_ms = 0;
            return 0;
        }
        rmx5200_ltpo.touch_direct_commit_count = commit_count;
        log_msg("RMX5200 LTPO touch rise burst submitted: target=%d/%dHz",
                ceiling_id, mode_fps(ceiling_id));
        /* Verification is measured from the activity event. The ceiling dwell
         * still starts only from the matching DSI return timestamp. */
        rmx5200_ltpo.touch_direct_retries = 0;
    } else if (mode_fps(current_mode_id) >= mode_fps(ceiling_id)) {
        rmx5200_ltpo.pending_ceiling_mode_id = -1;
        rmx5200_ltpo.touch_direct_request_ms = 0;
        rmx5200_ltpo.touch_direct_commit_count = 0;
        rmx5200_ltpo.touch_direct_retries = 0;
    } else {
        rmx5200_ltpo.pending_ceiling_mode_id = -1;
        log_msg("RMX5200 LTPO boost could not snapshot physical commit count");
        return 0;
    }
    /* The KO raises AE084/R1 directly. These logical requests only satisfy
     * the vendor mode-order contract and never wait for intermediate modes. */
    return 1;
}

static int open_rmx5200_touch_input(void) {
    char path[64];
    char name[128];

    if (strcmp(device_model, "RMX5200") != 0) return -1;
    for (int i = 0; i < 32; i++) {
        int fd;

        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        memset(name, 0, sizeof(name));
        if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
                strcmp(name, "touchpanel") == 0) {
            log_msg("RMX5200 LTPO touch fast path: %s (%s)", path, name);
            return fd;
        }
        close(fd);
    }
    log_msg("RMX5200 LTPO touch fast path unavailable");
    return -1;
}

static void rmx5200_ltpo_touch_released(int was_down) {
    if (!was_down || rmx5200_ltpo.touch_down) return;
    rmx5200_ltpo.last_activity_ms = monotonic_ms();
    /* A complete swipe can re-arm OplusTouchIdle even while the controller's
     * shared owner state still says paused. Reassert the vendor pause on the
     * real down -> up edge so OTI cannot cast its 60 Hz vote one second later.
     * The controller's own three-second dwell remains authoritative. */
    if (rmx5200_ltpo.active && rmx5200_ltpo_oti_pause_override)
        set_surfaceflinger_oti_pause(NULL, 1);
}

static void handle_rmx5200_touch_input(void) {
    struct input_event events[32];
    ssize_t length;

    if (rmx5200_ltpo.touch_fd < 0) return;
    while ((length = read(rmx5200_ltpo.touch_fd, events,
                          sizeof(events))) > 0) {
        size_t count = (size_t)length / sizeof(events[0]);

        for (size_t i = 0; i < count; i++) {
            const struct input_event *event = &events[i];

            if (event->type == EV_KEY && event->code == BTN_TOUCH) {
                int was_down = rmx5200_ltpo.touch_down;

                rmx5200_ltpo.touch_down = event->value > 0;
                if (!was_down && rmx5200_ltpo.touch_down)
                    rmx5200_ltpo_touch_boost();
                else
                    rmx5200_ltpo_touch_released(was_down);
            } else if (event->type == EV_ABS &&
                       event->code == ABS_MT_TRACKING_ID) {
                if (event->value >= 0) {
                    int was_down = rmx5200_ltpo.touch_down;

                    rmx5200_ltpo.touch_down = 1;
                    if (!was_down) rmx5200_ltpo_touch_boost();
                } else {
                    int was_down = rmx5200_ltpo.touch_down;

                    rmx5200_ltpo.touch_down = 0;
                    rmx5200_ltpo_touch_released(was_down);
                }
            } else if (event->type == EV_ABS &&
                       rmx5200_ltpo.touch_down) {
                long long now_ms = monotonic_ms();

                if (is_valid_mode(rmx5200_ltpo.pending_drop_mode_id))
                    rmx5200_ltpo_invalidate_drop_for_activity(
                            "touch-motion", now_ms);
                else
                    rmx5200_ltpo.last_activity_ms = now_ms;
            }
        }
    }
}

/* Returns non-zero while a touch-rise transaction still owns the controller.
 * The fast count check keeps this path cheap enough to run during a 120Hz
 * type-B input stream; the coherent timing snapshot is read only after DSI
 * publishes a new completion. */
static int rmx5200_ltpo_settle_pending_ceiling(void) {
    int target_id;
    long long observed_at_ms;
    long long direct_elapsed_ms;
    unsigned long long latest_count = 0;
    unsigned long long physical_count = 0;
    unsigned long long physical_ns = 0;
    int physical_mode_id = -1;
    int physical_width = 0;
    int physical_height = 0;
    int physical_refresh = 0;
    int physical_verified = 0;
    int observed_id = -1;

    if (!is_valid_mode(rmx5200_ltpo.pending_ceiling_mode_id)) return 0;

    target_id = rmx5200_ltpo.pending_ceiling_mode_id;
    observed_at_ms = monotonic_ms();
    direct_elapsed_ms = rmx5200_ltpo.touch_direct_request_ms > 0
            ? observed_at_ms - rmx5200_ltpo.touch_direct_request_ms : -1;

    if (read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH, &latest_count) &&
            latest_count > rmx5200_ltpo.touch_direct_commit_count) {
        physical_verified = rmx5200_ltpo_read_physical_commit(
                    &physical_count, &physical_mode_id, &physical_width,
                    &physical_height, &physical_refresh, &physical_ns) &&
                physical_count > rmx5200_ltpo.touch_direct_commit_count &&
                physical_width == get_mode_width(target_id) &&
                physical_height == mode_height(target_id) &&
                physical_refresh == mode_fps(target_id);
    }
    if (physical_verified) observed_id = target_id;

    /* DSI return is authoritative. DisplayManager can trail a transition out
     * of 1Hz by a full old vblank, so it is only a late diagnostic fallback. */
    if (!physical_verified && direct_elapsed_ms >=
            RMX5200_LTPO_TOUCH_DIRECT_GRACE_MS) {
        observed_id = get_current_applied_mode();
    }
    if (is_valid_mode(observed_id) &&
            same_mode_geometry(observed_id, target_id)) {
        current_mode_id = observed_id;
    }
    if (observed_id == target_id) {
        log_msg("RMX5200 LTPO touch rise burst verified: mode=%d/%dHz "
                "after=%lldms source=%s commit=%llu kernel_mode=%d "
                "timing=%dx%d@%d",
                target_id, mode_fps(target_id), direct_elapsed_ms,
                physical_verified ? "dsi" : "framework",
                physical_count, physical_mode_id, physical_width,
                physical_height, physical_refresh);
        rmx5200_ltpo.pending_ceiling_mode_id = -1;
        rmx5200_ltpo.touch_direct_request_ms = 0;
        rmx5200_ltpo.touch_direct_commit_count = 0;
        rmx5200_ltpo.touch_direct_retries = 0;
        rmx5200_ltpo.last_transition_ms = physical_verified && physical_ns
                ? (long long)(physical_ns / 1000000ULL) : observed_at_ms;
        return 0;
    }
    if (direct_elapsed_ms >= 0 &&
            direct_elapsed_ms < RMX5200_LTPO_TOUCH_DIRECT_GRACE_MS) {
        return 1;
    }
    if (direct_elapsed_ms >= 0 &&
            rmx5200_ltpo.touch_direct_retries == 0) {
        read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH,
                      &rmx5200_ltpo.touch_direct_commit_count);
        if (rmx5200_ltpo_submit_touch_rise(target_id, 0)) {
            rmx5200_ltpo.touch_direct_retries = 1;
            rmx5200_ltpo.touch_direct_request_ms = observed_at_ms;
            log_msg("RMX5200 LTPO touch rise burst retry: mode=%d/%dHz",
                    target_id, mode_fps(target_id));
        }
        return 1;
    }
    if (direct_elapsed_ms >= RMX5200_LTPO_TOUCH_DIRECT_TIMEOUT_MS) {
        log_msg("RMX5200 LTPO touch rise burst timed out: current=%d target=%d",
                current_mode_id, target_id);
        rmx5200_ltpo.pending_ceiling_mode_id = -1;
        rmx5200_ltpo.touch_direct_request_ms = 0;
        rmx5200_ltpo.touch_direct_commit_count = 0;
        rmx5200_ltpo.touch_direct_retries = 0;
        return 0;
    }
    return 1;
}

static int rmx5200_ltpo_quarantine_superseded_drop(int ceiling_mode_id,
                                                   long long now_ms) {
    unsigned long long physical_count = 0;
    unsigned long long physical_ns = 0;
    int physical_mode_id = -1;
    int physical_width = 0;
    int physical_height = 0;
    int physical_refresh = 0;
    int superseded_id = rmx5200_ltpo.superseded_drop_mode_id;
    int native_anchor_refresh = 0;

    if (!is_valid_mode(superseded_id)) return 0;
    if (now_ms >= rmx5200_ltpo.superseded_drop_expires_ms) {
        log_msg("RMX5200 LTPO superseded drop guard expired: generation=%llu "
                "target=%d/%dHz",
                rmx5200_ltpo.drop_state.superseded_drop_generation,
                superseded_id, mode_fps(superseded_id));
        rmx5200_ltpo_clear_superseded_drop();
        return 0;
    }
    if (!rmx5200_ltpo_read_physical_commit(
                &physical_count, &physical_mode_id, &physical_width,
                &physical_height, &physical_refresh, &physical_ns) ||
            physical_count <= rmx5200_ltpo.superseded_drop_commit_count ||
            physical_width != get_mode_width(superseded_id) ||
            physical_height != mode_height(superseded_id) ||
            physical_refresh != mode_fps(superseded_id)) {
        return 0;
    }

    log_msg("RMX5200 LTPO late idle-drop receipt quarantined: "
            "generation=%llu target=%d/%dHz commit=%llu kernel_mode=%d "
            "timing=%dx%d@%d ceiling=%d/%dHz",
            rmx5200_ltpo.drop_state.superseded_drop_generation,
            superseded_id, mode_fps(superseded_id), physical_count,
            physical_mode_id, physical_width, physical_height,
            physical_refresh, ceiling_mode_id, mode_fps(ceiling_mode_id));
    rmx5200_ltpo_clear_superseded_drop();

    if (!is_valid_mode(ceiling_mode_id) ||
            !same_mode_geometry(superseded_id, ceiling_mode_id)) {
        return 1;
    }

    /* The late receipt is not accepted as controller state. It is used only
     * as the physical source for replaying the user's current ceiling. */
    current_mode_id = superseded_id;
    rmx5200_ltpo.pending_ceiling_mode_id = ceiling_mode_id;
    rmx5200_ltpo.touch_direct_request_ms = now_ms;
    rmx5200_ltpo.touch_direct_commit_count = physical_count;
    rmx5200_ltpo.touch_direct_retries = 0;
    if (mode_fps(superseded_id) <= 30) {
        int ceiling_fps = mode_fps(ceiling_mode_id);

        native_anchor_refresh = rmx5200_ltpo_run_iris_touch_boost(
                ceiling_fps >= 144 ? 144 : 120, ceiling_fps);
    }
    if (!rmx5200_ltpo_submit_touch_rise(ceiling_mode_id,
                                         native_anchor_refresh)) {
        log_msg("RMX5200 LTPO superseded drop recovery submission failed: "
                "source=%d/%dHz ceiling=%d/%dHz", superseded_id,
                mode_fps(superseded_id), ceiling_mode_id,
                mode_fps(ceiling_mode_id));
    } else {
        log_msg("RMX5200 LTPO superseded drop recovery submitted: "
                "source=%d/%dHz ceiling=%d/%dHz", superseded_id,
                mode_fps(superseded_id), ceiling_mode_id,
                mode_fps(ceiling_mode_id));
    }
    return 1;
}

static void update_rmx5200_ltpo_controller(const char *base_path,
                                           int ceiling_mode_id,
                                           int screen_state) {
    unsigned long long gpu_count;
    long long now_ms = monotonic_ms();
    int enabled = premium_custom_ltpo_enabled() &&
            rmx5200_ltpo_runtime_enabled(base_path,
                                         ceiling_mode_id,
                                         screen_state);

    /* Full-timing 30/10/1 modes are controlled by this state machine. The
     * vendor OTI director otherwise casts its own 60Hz vote about 1.5s after
     * touch-up and cuts short the requested three-second ceiling dwell. Keep
     * the user's Web LTPO setting intact and pause OTI only for the lifetime
     * of the custom controller. */
    if (enabled && !rmx5200_ltpo_oti_pause_override) {
        rmx5200_ltpo_oti_pause_override = 1;
        set_rmx5200_ltpo_oti_owner(base_path, 1);
        sync_oti_pause_policy(base_path, 1);
    } else if (!enabled && rmx5200_ltpo_oti_pause_override) {
        rmx5200_ltpo_oti_pause_override = 0;
        set_rmx5200_ltpo_oti_owner(base_path, 0);
        sync_oti_pause_policy(base_path, 1);
    }

    if (!enabled) {
        if (rmx5200_ltpo.active) {
            log_msg("RMX5200 custom LTPO controller disabled");
            rmx5200_ltpo.active = 0;
            rmx5200_ltpo.pending_ceiling_mode_id = -1;
            rmx5200_ltpo_clear_pending_drop("controller-disabled");
            rmx5200_ltpo.touch_direct_request_ms = 0;
            rmx5200_ltpo.touch_direct_commit_count = 0;
            rmx5200_ltpo.touch_direct_retries = 0;
            if (rmx5200_ltpo.touch_boost_configured)
                write_unsigned_file(RMX5200_LTPO_TOUCH_BOOST_ENABLED_PATH,
                                    0U, 0);
            rmx5200_ltpo.touch_boost_configured = 0;
        }
        rmx5200_ltpo.rise_queue_active = 0;
        rmx5200_ltpo.rise_queue_target_id = -1;
        rmx5200_ltpo.rise_queue_current_id = -1;
        rmx5200_ltpo.rise_queue_pending_id = -1;
        rmx5200_ltpo.rise_queue_commit_count = 0;
        rmx5200_ltpo.rise_queue_request_ms = 0;
        rmx5200_ltpo.rise_queue_steps = 0;
        return;
    }

    if (!rmx5200_ltpo.active) {
        current_mode_id = get_current_system_mode();
        if (!is_valid_mode(current_mode_id)) current_mode_id = ceiling_mode_id;
        rmx5200_ltpo.active = 1;
        rmx5200_ltpo.ceiling_mode_id = ceiling_mode_id;
        rmx5200_ltpo.pending_ceiling_mode_id = -1;
        rmx5200_ltpo.pending_drop_mode_id = -1;
        rmx5200_ltpo.pending_drop_source_id = -1;
        rmx5200_ltpo.superseded_drop_mode_id = -1;
        rmx5200_ltpo.drop_request_ms = 0;
        rmx5200_ltpo.drop_commit_count = 0;
        rmx5200_drop_state_init(&rmx5200_ltpo.drop_state);
        rmx5200_ltpo_clear_superseded_drop();
        rmx5200_ltpo.touch_direct_request_ms = 0;
        rmx5200_ltpo.touch_direct_commit_count = 0;
        rmx5200_ltpo.touch_direct_retries = 0;
        rmx5200_ltpo.rise_queue_active = 0;
        rmx5200_ltpo.rise_queue_target_id = -1;
        rmx5200_ltpo.rise_queue_current_id = -1;
        rmx5200_ltpo.rise_queue_pending_id = -1;
        rmx5200_ltpo.rise_queue_commit_count = 0;
        rmx5200_ltpo.rise_queue_request_ms = 0;
        rmx5200_ltpo.rise_queue_steps = 0;
        rmx5200_ltpo.last_activity_ms = now_ms;
        rmx5200_ltpo.last_transition_ms = now_ms;
        rmx5200_ltpo.last_gpu_sample_ms = now_ms;
        read_ull_file(RMX5200_LTPO_GPU_COUNT_PATH,
                      &rmx5200_ltpo.last_gpu_submit_count);
        if (!rmx5200_ltpo_configure_touch_boost())
            log_msg("RMX5200 LTPO controller started without Iris pre-boost");
        log_msg("RMX5200 custom LTPO controller enabled: ceiling=%d/%dHz",
                ceiling_mode_id, mode_fps(ceiling_mode_id));
    } else if (rmx5200_ltpo.ceiling_mode_id != ceiling_mode_id) {
        rmx5200_ltpo.ceiling_mode_id = ceiling_mode_id;
        rmx5200_ltpo.last_activity_ms = now_ms;
        rmx5200_ltpo_touch_boost();
    }

    /* Hardware-decoded third-party video may never reach OplusFeatureMEMC
     * (Telegram is one example).  A visible foreground SurfaceView is still
     * real display activity, so suspend the idle ladder and keep at least the
     * native 60Hz tier.  Existing MEMC/video overrides remain authoritative;
     * this guard only fills the gap when no vendor session is active. */
    if (video_surface_active && !video_override_active &&
            !video_handoff_active && !video_exit_pending) {
        int floor_id;

        now_ms = monotonic_ms();
        if (is_valid_mode(rmx5200_ltpo.pending_drop_mode_id)) {
            rmx5200_ltpo_invalidate_drop_for_activity(
                    "video-surface", now_ms);
        } else {
            rmx5200_ltpo.last_activity_ms = now_ms;
        }
        floor_id = rmx5200_ltpo_mode_at_most(
                ceiling_mode_id, RMX5200_VIDEO_SURFACE_MIN_REFRESH);
        if (!rmx5200_ltpo.touch_down && is_valid_mode(floor_id) &&
                (!is_valid_mode(current_mode_id) ||
                 mode_fps(current_mode_id) < mode_fps(floor_id))) {
            rmx5200_ltpo_switch_runtime_mode(floor_id, "video-surface");
        }
        return;
    }

    now_ms = monotonic_ms();
    if (rmx5200_ltpo_quarantine_superseded_drop(ceiling_mode_id, now_ms))
        return;
    if (rmx5200_ltpo.rise_queue_active) {
        rmx5200_ltpo_process_rise_queue();
        if (rmx5200_ltpo.rise_queue_active) return;
    }
    if (rmx5200_ltpo_settle_pending_ceiling()) return;

    if (is_valid_mode(rmx5200_ltpo.pending_drop_mode_id)) {
        int target_id = rmx5200_ltpo.pending_drop_mode_id;
        unsigned long long physical_count = 0;
        unsigned long long physical_ns = 0;
        int physical_mode_id = -1;
        int physical_width = 0;
        int physical_height = 0;
        int physical_refresh = 0;
        long long observed_at_ms = monotonic_ms();
        long long elapsed_ms = observed_at_ms - rmx5200_ltpo.drop_request_ms;
        int physical_verified = rmx5200_ltpo_read_physical_commit(
                    &physical_count, &physical_mode_id, &physical_width,
                    &physical_height, &physical_refresh, &physical_ns) &&
                physical_count > rmx5200_ltpo.drop_commit_count &&
                physical_width == get_mode_width(target_id) &&
                physical_height == mode_height(target_id) &&
                physical_refresh == mode_fps(target_id);

        if (physical_verified &&
                rmx5200_drop_receipt_is_owned(
                    &rmx5200_ltpo.drop_state,
                    rmx5200_ltpo.touch_down)) {
            log_msg("RMX5200 LTPO idle drop verified: source=%d/%dHz "
                    "target=%d/%dHz after=%lldms commit=%llu kernel_mode=%d "
                    "timing=%dx%d@%d", rmx5200_ltpo.pending_drop_source_id,
                    mode_fps(rmx5200_ltpo.pending_drop_source_id), target_id,
                    mode_fps(target_id), elapsed_ms, physical_count,
                    physical_mode_id, physical_width, physical_height,
                    physical_refresh);
            current_mode_id = target_id;
            rmx5200_ltpo.last_transition_ms = physical_ns
                    ? (long long)(physical_ns / 1000000ULL) : observed_at_ms;
            rmx5200_ltpo.pending_drop_mode_id = -1;
            rmx5200_ltpo.pending_drop_source_id = -1;
            rmx5200_ltpo.drop_request_ms = 0;
            rmx5200_ltpo.drop_commit_count = 0;
            rmx5200_drop_clear_pending(&rmx5200_ltpo.drop_state);
        } else if (elapsed_ms >= RMX5200_LTPO_DROP_TIMEOUT_MS) {
            int observed_id = get_current_applied_mode();

            if (observed_id == target_id &&
                    rmx5200_drop_receipt_is_owned(
                        &rmx5200_ltpo.drop_state,
                        rmx5200_ltpo.touch_down)) {
                current_mode_id = target_id;
                rmx5200_ltpo.last_transition_ms = monotonic_ms();
                log_msg("RMX5200 LTPO idle drop fallback verified: target=%d/%dHz "
                        "after=%lldms", target_id, mode_fps(target_id),
                        elapsed_ms);
            } else {
                rmx5200_ltpo.last_transition_ms = monotonic_ms();
                log_msg("RMX5200 LTPO idle drop timed out: source=%d/%dHz "
                        "target=%d/%dHz observed=%d",
                        rmx5200_ltpo.pending_drop_source_id,
                        mode_fps(rmx5200_ltpo.pending_drop_source_id), target_id,
                        mode_fps(target_id), observed_id);
            }
            rmx5200_ltpo.pending_drop_mode_id = -1;
            rmx5200_ltpo.pending_drop_source_id = -1;
            rmx5200_ltpo.drop_request_ms = 0;
            rmx5200_ltpo.drop_commit_count = 0;
            rmx5200_drop_clear_pending(&rmx5200_ltpo.drop_state);
        }
    }

    if (read_ull_file(RMX5200_LTPO_GPU_COUNT_PATH, &gpu_count) &&
            now_ms > rmx5200_ltpo.last_gpu_sample_ms) {
        unsigned long long delta = gpu_count >= rmx5200_ltpo.last_gpu_submit_count
                ? gpu_count - rmx5200_ltpo.last_gpu_submit_count : 0;
        long long elapsed_ms = now_ms - rmx5200_ltpo.last_gpu_sample_ms;
        unsigned long long rate = elapsed_ms > 0
                ? delta * 1000ULL / (unsigned long long)elapsed_ms : 0;
        int desired_id = -1;

        rmx5200_ltpo.last_gpu_submit_count = gpu_count;
        rmx5200_ltpo.last_gpu_sample_ms = now_ms;
        if (rate >= RMX5200_LTPO_GPU_ACTIVITY_RATE) {
            int requested = rate >= RMX5200_LTPO_GPU_MAX_RATE
                    ? mode_fps(ceiling_mode_id)
                    : (rate >= RMX5200_LTPO_GPU_HIGH_RATE ? 60 : 10);

            desired_id = rmx5200_ltpo_mode_at_most(ceiling_mode_id,
                                                   requested);
            if (is_valid_mode(desired_id) &&
                    mode_fps(current_mode_id) <= mode_fps(desired_id)) {
                rmx5200_ltpo.last_activity_ms = now_ms;
            }
        }
        if (is_valid_mode(desired_id) &&
                mode_fps(desired_id) > mode_fps(current_mode_id)) {
            int superseded_id = rmx5200_ltpo_invalidate_drop_for_activity(
                    "application-animation", now_ms);

            if (is_valid_mode(superseded_id) &&
                    same_mode_geometry(superseded_id, desired_id) &&
                    mode_fps(superseded_id) < mode_fps(desired_id)) {
                current_mode_id = superseded_id;
            }
            rmx5200_ltpo_switch_runtime_mode(desired_id, "application-animation");
        }
    }

    now_ms = monotonic_ms();
    if (!rmx5200_ltpo.touch_down &&
            !is_valid_mode(rmx5200_ltpo.pending_drop_mode_id)) {
        int dwell_ms = rmx5200_ltpo_dwell_ms(current_mode_id,
                                             ceiling_mode_id);
        long long idle_from_ms = rmx5200_ltpo.last_activity_ms >
                rmx5200_ltpo.last_transition_ms
                ? rmx5200_ltpo.last_activity_ms
                : rmx5200_ltpo.last_transition_ms;

        if (dwell_ms >= 0 && now_ms - idle_from_ms >= dwell_ms) {
            int next_id = rmx5200_ltpo_next_lower_mode(
                    current_mode_id, ceiling_mode_id);
            unsigned long long commit_count = 0;
            long long request_ms = monotonic_ms();

            /* A new, post-dwell descent owns the display now. If the old
             * transaction arrives after this point with the same timing, it
             * is already the timing requested by the current generation. */
            rmx5200_ltpo_clear_superseded_drop();
            if (is_valid_mode(next_id) &&
                    read_ull_file(RMX5200_LTPO_PHYSICAL_COUNT_PATH,
                                  &commit_count) &&
                    set_surface_flinger_mode(next_id)) {
                log_msg("RMX5200 LTPO idle drop submitted: %d/%dHz -> "
                        "%d/%dHz dwell=%dms", current_mode_id,
                        mode_fps(current_mode_id), next_id,
                        mode_fps(next_id), dwell_ms);
                rmx5200_ltpo.pending_drop_source_id = current_mode_id;
                rmx5200_ltpo.pending_drop_mode_id = next_id;
                rmx5200_ltpo.drop_request_ms = request_ms;
                rmx5200_ltpo.drop_commit_count = commit_count;
                rmx5200_drop_begin(&rmx5200_ltpo.drop_state);
            }
        }
    }
}
#endif

static void apply_startup_default_mode(int target_id) {
#ifndef MURONG_FREE_BUILD
    int observed_id;
#endif

    /* The framework owns panel timing while Dozing. Deferring this replay is
     * also important when the daemon is manually restarted during a 1Hz
     * settle: do not inject an artificial 1 -> ceiling transition before the
     * normal OFF/DOZE -> ON replay path has initialized the display. */
    if (strcmp(device_model, "RMX5200") == 0 && get_screen_state() == 0) {
        current_mode_id = get_current_system_mode();
        log_msg("RMX5200 startup mode replay deferred while Dozing");
        return;
    }

#ifndef MURONG_FREE_BUILD
    observed_id = get_current_system_mode();

    if (premium_custom_ltpo_enabled() &&
            strcmp(device_model, "RMX5200") == 0 &&
            is_valid_mode(observed_id) && is_valid_mode(target_id) &&
            same_mode_geometry(observed_id, target_id) &&
            mode_fps(observed_id) < mode_fps(target_id) &&
            rmx5200_ltpo_has_required_modes(target_id)) {
        int switched = 0;

        current_mode_id = observed_id;
        rmx5200_ltpo.active = 1;
        rmx5200_ltpo.ceiling_mode_id = target_id;
        rmx5200_ltpo.pending_ceiling_mode_id = -1;
        for (int attempt = 0; attempt < 2 && !switched; attempt++) {
            switched = rmx5200_ltpo_switch_runtime_mode(
                    target_id, "daemon-startup-ordered-rise");
            if (!switched) {
                observed_id = get_current_system_mode();
                if (is_valid_mode(observed_id) &&
                        same_mode_geometry(observed_id, target_id)) {
                    current_mode_id = observed_id;
                }
            }
        }
        rmx5200_ltpo.active = 0;
        rmx5200_ltpo.pending_ceiling_mode_id = -1;
        if (switched) {
            sync_android_settings(target_id);
        } else {
            log_msg("RMX5200 startup ordered rise failed without changing "
                    "durable settings: active=%d target=%d",
                    current_mode_id, target_id);
        }
        return;
    }
#endif
    smooth_switch(target_id);
}

// 获取指定分辨率下按FPS排序的模式列表
void get_sorted_fps_modes(int width, int *out_ids, int *out_count) {
    typedef struct {
        int id;
        int fps;
    } ModeInfo;

    ModeInfo temp_modes[MAX_MODES];
    int count = 0;

    // 1. 筛选符合分辨率的模式
    for (int i=0; i<mode_count; i++) {
        if (modes[i].width == width) {
            temp_modes[count].id = modes[i].id;
            temp_modes[count].fps = modes[i].fps;
            count++;
        }
    }

    // 2. 按 FPS 升序排序
    for (int i = 0; i < count - 1; i++) {
        for (int j = 0; j < count - i - 1; j++) {
            if (temp_modes[j].fps > temp_modes[j+1].fps) {
                ModeInfo temp = temp_modes[j];
                temp_modes[j] = temp_modes[j+1];
                temp_modes[j+1] = temp;
            }
        }
    }

    // 3. 输出 ID
    *out_count = count;
    for (int i=0; i<count; i++) {
        out_ids[i] = temp_modes[i].id;
    }
}

static int package_uid(const char *package_name) {
    char command[256];
    char line[256];
    FILE *fp;
    int uid = -1;

    snprintf(command, sizeof(command),
             "cmd package list packages -U %s 2>/dev/null", package_name);
    fp = popen(command, "r");
    if (!fp) return -1;
    while (fgets(line, sizeof(line), fp)) {
        char *marker = strstr(line, " uid:");
        if (marker) {
            uid = atoi(marker + 5);
            break;
        }
    }
    pclose(fp);
    return uid;
}

static int valid_package_name(const char *package_name) {
    int saw_dot = 0;
    size_t length;

    if (!package_name) return 0;
    length = strlen(package_name);
    if (length < 3 || length >= MAX_PKG_LEN) return 0;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)package_name[i];
        if (c == '.') {
            saw_dot = 1;
        } else if (!isalnum(c) && c != '_') {
            return 0;
        }
    }
    return saw_dot;
}

static int mode_fps(int mode_id) {
    for (int i = 0; i < mode_count; i++) {
        if (modes[i].id == mode_id) return modes[i].fps;
    }
    return -1;
}

static int mode_height(int mode_id) {
    for (int i = 0; i < mode_count; i++) {
        if (modes[i].id == mode_id) return modes[i].height;
    }
    return -1;
}

static int group_has_extended_rate(int width, int group) {
    if (width <= 0 || group < 0) return 0;
    for (int i = 0; i < mode_count; i++) {
        if (modes[i].width == width && modes[i].group == group
                && modes[i].fps > 144) {
            return 1;
        }
    }
    return 0;
}

static int mode_for_width_fps(int width, int fps) {
    int fallback = -1;
    int extended = -1;
    if (width <= 0 || fps <= 0) return -1;
    for (int i = 0; i < mode_count; i++) {
        if (modes[i].width == width && modes[i].fps == fps) {
            if (fallback < 0 || modes[i].id < fallback) {
                fallback = modes[i].id;
            }
            if (group_has_extended_rate(width, modes[i].group)
                    && (extended < 0 || modes[i].id < extended)) {
                extended = modes[i].id;
            }
        }
    }
    if (extended >= 0 && extended != fallback) {
        log_msg("Duplicate mode resolved through extended group: %dx%dHz "
                "fallback=%d selected=%d", width, fps, fallback, extended);
    }
    return extended >= 0 ? extended : fallback;
}

static int mode_for_app_fps(int fps) {
    int reference_id = is_valid_mode(default_mode_id) ? default_mode_id : current_mode_id;
    int width = 0;
    int height = 0;

    for (int i = 0; i < mode_count; i++) {
        if (modes[i].id == reference_id) {
            width = modes[i].width;
            height = modes[i].height;
            break;
        }
    }
    if (width <= 0 || height <= 0) return -1;
    (void)height;
    return mode_for_width_fps(width, fps);
}

static int write_app_config(const char *base_path, const char *package_name,
                            int mode_id) {
    char config_path[512];
    char temporary_path[560];
    FILE *fp;
    int failed = 0;

    snprintf(config_path, sizeof(config_path), "%s/config/mode.txt", base_path);
    snprintf(temporary_path, sizeof(temporary_path), "%s.hook.%d",
             config_path, getpid());
    fp = fopen(temporary_path, "w");
    if (!fp) return 0;
    if (!write_mode_spec_line(fp, default_mode_id)) failed = 1;
    for (int i = 0; i < app_config_count; i++) {
        if (strcmp(app_configs[i].package, package_name) != 0) {
            if (!write_app_spec_line(fp, app_configs[i].package,
                                     app_configs[i].mode_id, default_mode_id)) {
                failed = 1;
            }
        }
    }
    if (!write_app_spec_line(fp, package_name, mode_id, default_mode_id)) {
        failed = 1;
    }
    if (fflush(fp) != 0 || fsync(fileno(fp)) != 0) failed = 1;
    if (fclose(fp) != 0) failed = 1;
    if (failed) {
        unlink(temporary_path);
        return 0;
    }
    if (rename(temporary_path, config_path) != 0) {
        unlink(temporary_path);
        return 0;
    }
    chmod(config_path, 0666);
    return 1;
}

static int write_global_config(const char *base_path, int mode_id) {
    char config_path[512];
    char temporary_path[560];
    FILE *fp;
    int failed = 0;

    snprintf(config_path, sizeof(config_path), "%s/config/mode.txt", base_path);
    snprintf(temporary_path, sizeof(temporary_path), "%s.hook.%d",
             config_path, getpid());
    fp = fopen(temporary_path, "w");
    if (!fp) return 0;
    if (!write_mode_spec_line(fp, mode_id)) failed = 1;
    for (int i = 0; i < app_config_count; i++) {
        if (!write_app_spec_line(fp, app_configs[i].package,
                                 app_configs[i].mode_id, mode_id)) {
            failed = 1;
        }
    }
    if (fflush(fp) != 0 || fsync(fileno(fp)) != 0) failed = 1;
    if (fclose(fp) != 0) failed = 1;
    if (failed) {
        unlink(temporary_path);
        return 0;
    }
    if (rename(temporary_path, config_path) != 0) {
        unlink(temporary_path);
        return 0;
    }
    chmod(config_path, 0666);
    return 1;
}

static int write_resolution_config(const char *base_path, int mode_id,
                                   int target_width) {
    char config_path[512];
    char temporary_path[560];
    FILE *fp;
    int failed = 0;

    snprintf(config_path, sizeof(config_path), "%s/config/mode.txt", base_path);
    snprintf(temporary_path, sizeof(temporary_path), "%s.hook.%d",
             config_path, getpid());
    fp = fopen(temporary_path, "w");
    if (!fp) return 0;
    if (!write_mode_spec_line(fp, mode_id)) failed = 1;
    for (int i = 0; i < app_config_count; i++) {
        int fps = mode_fps(app_configs[i].mode_id);
        int remapped = mode_for_width_fps(target_width, fps);
        if (remapped >= 0) {
            if (!write_app_spec_line(fp, app_configs[i].package, remapped,
                                     mode_id)) {
                failed = 1;
            }
        } else {
            log_msg("Dropping unavailable app mode during resolution switch: %s fps=%d",
                    app_configs[i].package, fps);
        }
    }
    if (fflush(fp) != 0 || fsync(fileno(fp)) != 0) failed = 1;
    if (fclose(fp) != 0) failed = 1;
    if (failed) {
        unlink(temporary_path);
        return 0;
    }
    if (rename(temporary_path, config_path) != 0) {
        unlink(temporary_path);
        return 0;
    }
    chmod(config_path, 0666);
    return 1;
}

static void reconcile_boot_resolution(const char *base_path) {
    int adjust = -1;
    int active_id = get_current_system_mode();
    int active_width = get_mode_width(active_id);
    int configured_id = default_mode_id;
    int configured_fps = mode_fps(configured_id);
    int target_width = active_width;
    int target_id;
    int persisted = 0;

    if (read_setting_int("secure",
                         "oplus_customize_screen_resolution_adjust",
                         &adjust)) {
        if (adjust == 2) {
            target_width = 1080;
        } else if (adjust == 3) {
            target_width = 1440;
        }
    }
    if (active_width <= 0) {
        log_msg("Boot resolution reconciliation skipped: active mode unavailable");
        return;
    }
    if (target_width != active_width) {
        /* The configured mode.txt is authoritative. Never overwrite it with
         * the active geometry just because the boot transition is incomplete;
         * that would silently downgrade the user's chosen resolution (and
         * leave the density mismatched) on every restart. */
        log_msg("Boot resolution restore is unsettled: adjust=%d wants=%d "
                "active=%d/%d; keeping configured geometry",
                adjust, target_width, active_id, active_width);
        /* target_width = active_width is intentionally not used here: a
         * transient boot geometry must not overwrite the configured mode. */
        target_width = get_mode_width(configured_id);
    }
    if (configured_fps <= 0) configured_fps = mode_fps(active_id);
    target_id = mode_for_width_fps(target_width, configured_fps);
    if (!is_valid_mode(target_id)) target_id = active_id;
    if (!is_valid_mode(target_id)) return;

    if (target_id != configured_id && active_width == target_width) {
        /* Only adopt a settled ColorOS-side change (active geometry already
         * matches the requested width); otherwise the transition is still in
         * flight and persisting would clobber the configured mode. */
        persisted = write_resolution_config(base_path, target_id, target_width);
        default_mode_id = target_id;
        if (persisted) load_config(base_path);
    }
    log_msg("Boot resolution reconciled: adjust=%d active=%d/%d configured=%d "
            "fps=%d target=%d persisted=%d",
            adjust, active_id, active_width, configured_id, configured_fps,
            target_id, persisted);
}

static int queue_native_resolution_adoption(int target_width, int source_width,
                                            int source_density,
                                            long long generation) {
    NativeResolutionAdoption next;
    int stable_source_width = source_width;
    int stable_source_density = source_density;
    int target_density;

    if (native_resolution_adoption.valid) {
        stable_source_width = native_resolution_adoption.source_width;
        stable_source_density = native_resolution_adoption.source_density;
    }
    if (target_width == stable_source_width) {
        target_density = stable_source_density;
    } else {
        target_density = density_for_resolution(stable_source_width, target_width,
                                                stable_source_density);
    }
    if (target_density < 72 || target_density > 2000) {
        log_msg("Native Settings adoption rejected: target=%d source=%d/%ddpi "
                "resolved_density=%d generation=%lld",
                target_width, source_width, source_density, target_density,
                generation);
        return 0;
    }
    if (!clear_display_preference()) {
        log_msg("Native Settings adoption could not clear the source display "
                "preference: generation=%lld target=%d",
                generation, target_width);
        return 0;
    }

    /* The daemon finalizes successful changes into these AOSP user settings.
     * Clear a stale source-size vote while ColorOS publishes the new size;
     * otherwise the old QHD vote wins and ColorOS changes density only. */
    if (!delete_setting("global", "user_preferred_resolution_width") ||
        !delete_setting("global", "user_preferred_resolution_height")) {
        log_msg("Native Settings adoption could not fully clear the stale "
                "framework size vote: generation=%lld target=%d",
                generation, target_width);
    }

    memset(&next, 0, sizeof(next));
    next.valid = 1;
    next.target_width = target_width;
    next.source_width = stable_source_width;
    next.source_density = stable_source_density;
    next.target_density = target_density;
    next.generation = generation;
    next.queued_at_ms = monotonic_ms();
    next.expires_at_ms = next.queued_at_ms + 8000;

    if (native_resolution_adoption.valid) {
        log_msg("Native Settings adoption superseded: generation=%lld target=%d "
                "-> generation=%lld target=%d",
                native_resolution_adoption.generation,
                native_resolution_adoption.target_width,
                generation, target_width);
    }
    native_resolution_adoption = next;
    log_msg("Native Settings adoption queued: generation=%lld target=%d/%ddpi "
            "source=%d/%ddpi",
            generation, target_width, target_density,
            stable_source_width, stable_source_density);
    return 1;
}

static void recover_native_resolution_adoption(void) {
    int active_id = get_current_system_mode();
    int active_width = get_mode_width(active_id);
    int active_height = 0;
    int adjust;
    char property_cmd[128];

    if (!is_valid_mode(active_id)
            || active_width != native_resolution_adoption.source_width) {
        log_msg("Native Settings adoption recovery skipped: generation=%lld "
                "active=%d/%d source_width=%d",
                native_resolution_adoption.generation, active_id, active_width,
                native_resolution_adoption.source_width);
        return;
    }
    for (int i = 0; i < mode_count; i++) {
        if (modes[i].id == active_id) {
            active_height = modes[i].height;
            break;
        }
    }
    adjust = resolution_adjust_for_width(active_width);
    if (adjust < 0 || active_height <= 0) {
        log_msg("Native Settings adoption recovery unsupported: width=%d height=%d",
                active_width, active_height);
        return;
    }

    snprintf(property_cmd, sizeof(property_cmd),
             "setprop persist.sys.display.user_density %d",
             native_resolution_adoption.source_density);
    system(property_cmd);
    snprintf(property_cmd, sizeof(property_cmd),
             "setprop persist.sys.display.screen_resolution %d", adjust);
    system(property_cmd);
    ensure_density_override(native_resolution_adoption.source_density, 1500);
    write_setting_int("secure", "oplus_customize_screen_resolution_adjust",
                      adjust);
    finalize_coloros_resolution_settings(active_width, active_height);
    current_mode_id = active_id;
    log_msg("Native Settings adoption timed out and source state was restored: "
            "generation=%lld mode=%d width=%d density=%d",
            native_resolution_adoption.generation, active_id, active_width,
            native_resolution_adoption.source_density);
}

static void process_native_resolution_adoption(const char *base_path) {
    int active_id;
    int active_width;
    int target_id;
    int preference_id;
    int target_height = 0;
    int desired_fps;
    long long now_ms;
    char property_cmd[128];

    if (!native_resolution_adoption.valid) return;

    now_ms = monotonic_ms();
    active_id = get_current_system_mode();
    active_width = get_mode_width(active_id);
    if (active_width != native_resolution_adoption.target_width) {
        native_resolution_adoption.target_observed_at_ms = 0;
        if (!native_resolution_adoption.physical_fallback_requested &&
            now_ms >= native_resolution_adoption.queued_at_ms +
                    NATIVE_RESOLUTION_PHYSICAL_FALLBACK_MS) {
            desired_fps = mode_fps(default_mode_id);
            target_id = mode_for_width_fps(
                    native_resolution_adoption.target_width, desired_fps);
            preference_id = target_id;
            if (is_valid_mode(target_id) && is_overclock_mode(target_id)) {
                int stock_id = native_anchor_for_target(target_id);
                if (stock_id >= 0) preference_id = stock_id;
            }
            native_resolution_adoption.physical_fallback_requested = 1;
            if (is_valid_mode(preference_id)
                    && set_surface_flinger_mode(preference_id)
                    && wait_for_active_width(
                            native_resolution_adoption.target_width, 1500)) {
                log_msg("Native Settings physical fallback completed: "
                        "generation=%lld mode=%d target=%d width=%d fps=%d",
                        native_resolution_adoption.generation, preference_id,
                        target_id,
                        native_resolution_adoption.target_width,
                        desired_fps);
            } else {
                log_msg("Native Settings physical fallback unavailable: "
                        "generation=%lld target=%d fps=%d mode=%d",
                        native_resolution_adoption.generation,
                        native_resolution_adoption.target_width, desired_fps,
                        target_id);
            }
        }
        if (now_ms <= native_resolution_adoption.expires_at_ms) return;
        log_msg("Native Settings resolution was not observed: generation=%lld "
                "target=%d active=%d/%d",
                native_resolution_adoption.generation,
                native_resolution_adoption.target_width,
                active_id, active_width);
        recover_native_resolution_adoption();
        native_resolution_adoption.valid = 0;
        force_reapply = 1;
        return;
    }

    if (native_resolution_adoption.target_observed_at_ms == 0) {
        native_resolution_adoption.target_observed_at_ms = now_ms;
        log_msg("Native Settings target geometry observed: generation=%lld "
                "mode=%d width=%d; waiting for settle",
                native_resolution_adoption.generation, active_id, active_width);
        return;
    }
    if (now_ms - native_resolution_adoption.target_observed_at_ms < 250) return;

    desired_fps = mode_fps(default_mode_id);
    target_id = mode_for_width_fps(native_resolution_adoption.target_width,
                                   desired_fps);
    if (!is_valid_mode(target_id)) target_id = active_id;
    preference_id = target_id;
    if (is_overclock_mode(target_id)) {
        int stock_id = native_anchor_for_target(target_id);
        if (stock_id >= 0) preference_id = stock_id;
    }
    /* ADOPTRES clears the stale source-size vote before ColorOS starts. Always
     * rebuild a native user preference after the physical mode is correct.
     * The exact extension is selected only by the ordered ladder below. */
    if (!set_display_preference(preference_id)
        || !wait_for_active_width(native_resolution_adoption.target_width, 500)) {
        log_msg("Native Settings refresh remap retry: generation=%lld active=%d "
                "target=%d",
                native_resolution_adoption.generation, active_id, target_id);
        native_resolution_adoption.target_observed_at_ms = now_ms;
        return;
    }

    for (int i = 0; i < mode_count; i++) {
        if (modes[i].id == target_id) {
            target_height = modes[i].height;
            break;
        }
    }
    if (target_height <= 0) {
        native_resolution_adoption.target_observed_at_ms = now_ms;
        return;
    }

    snprintf(property_cmd, sizeof(property_cmd),
             "setprop persist.sys.display.user_density %d",
             native_resolution_adoption.target_density);
    if (system(property_cmd) != 0
            || !ensure_density_override(native_resolution_adoption.target_density,
                                        1500)
            || !finalize_coloros_resolution_settings(
                    native_resolution_adoption.target_width, target_height)) {
        log_msg("Native Settings adoption finalization retry: generation=%lld "
                "mode=%d density=%d",
                native_resolution_adoption.generation, target_id,
                native_resolution_adoption.target_density);
        native_resolution_adoption.target_observed_at_ms = now_ms;
        return;
    }

    current_mode_id = get_current_system_mode();
    if (!is_valid_mode(current_mode_id) ||
            !same_mode_geometry(current_mode_id, target_id) ||
            !apply_refresh_ladder(target_id) ||
            !write_resolution_config(base_path, target_id,
                                     native_resolution_adoption.target_width)) {
        log_msg("Native Settings ordered refresh retry: generation=%lld "
                "active=%d target=%d",
                native_resolution_adoption.generation, current_mode_id, target_id);
        native_resolution_adoption.target_observed_at_ms = now_ms;
        return;
    }

    current_mode_id = target_id;
    sync_android_settings(target_id);
    load_config(base_path);
    log_msg("Native Settings resolution adopted: generation=%lld mode=%d "
            "width=%d density=%d fps=%d",
            native_resolution_adoption.generation, target_id,
            native_resolution_adoption.target_width,
            native_resolution_adoption.target_density, mode_fps(target_id));
    native_resolution_adoption.valid = 0;
}

static int write_app_config_without(const char *base_path,
                                    const char *package_name) {
    char config_path[512];
    char temporary_path[560];
    FILE *fp;
    int failed = 0;

    snprintf(config_path, sizeof(config_path), "%s/config/mode.txt", base_path);
    snprintf(temporary_path, sizeof(temporary_path), "%s.hook.%d",
             config_path, getpid());
    fp = fopen(temporary_path, "w");
    if (!fp) return 0;
    if (!write_mode_spec_line(fp, default_mode_id)) failed = 1;
    for (int i = 0; i < app_config_count; i++) {
        if (package_name && strcmp(app_configs[i].package, package_name) != 0) {
            if (!write_app_spec_line(fp, app_configs[i].package,
                                     app_configs[i].mode_id, default_mode_id)) {
                failed = 1;
            }
        }
    }
    if (fflush(fp) != 0 || fsync(fileno(fp)) != 0) failed = 1;
    if (fclose(fp) != 0) failed = 1;
    if (failed) {
        unlink(temporary_path);
        return 0;
    }
    if (rename(temporary_path, config_path) != 0) {
        unlink(temporary_path);
        return 0;
    }
    chmod(config_path, 0666);
    return 1;
}

static void sync_global_settings_async(const char *base_path) {
    char helper_path[512];
    pid_t pid;

    snprintf(helper_path, sizeof(helper_path),
             "%s/scripts/display_settings_bridge.sh", base_path);
    if (access(helper_path, R_OK) != 0) return;
    pid = fork();
    if (pid == 0) {
        execl("/system/bin/sh", "sh", helper_path, "sync-global",
              (char *)NULL);
        _exit(127);
    }
}

static int tcp_peer_uid(int client_fd) {
    struct ucred credentials;
    socklen_t length = sizeof(credentials);
    struct sockaddr_in peer_address;
    struct sockaddr_in local_address;
    FILE *tcp_table;
    char line[512];

    if (getsockopt(client_fd, SOL_SOCKET, SO_PEERCRED,
                   &credentials, &length) == 0
            && credentials.uid != (uid_t)-1) {
        return (int)credentials.uid;
    }

    length = sizeof(peer_address);
    if (getpeername(client_fd, (struct sockaddr *)&peer_address, &length) != 0
            || peer_address.sin_family != AF_INET) {
        return -1;
    }
    length = sizeof(local_address);
    if (getsockname(client_fd, (struct sockaddr *)&local_address, &length) != 0
            || local_address.sin_family != AF_INET) {
        return -1;
    }

    // Android's TCP SO_PEERCRED reports uid -1. Root can recover the client
    // uid from the kernel's matching loopback connection while it is open.
    for (int attempt = 0; attempt < 5; attempt++) {
        tcp_table = fopen("/proc/net/tcp", "r");
        if (!tcp_table) return -1;
        while (fgets(line, sizeof(line), tcp_table)) {
            unsigned int source_address;
            unsigned int source_port;
            unsigned int destination_address;
            unsigned int destination_port;
            unsigned int state;
            unsigned int uid;
            int parsed = sscanf(line,
                    " %*d: %8x:%4x %8x:%4x %2x %*s %*s %*s %u",
                    &source_address, &source_port,
                    &destination_address, &destination_port, &state, &uid);
            if (parsed == 6
                    && source_address == peer_address.sin_addr.s_addr
                    && source_port == ntohs(peer_address.sin_port)
                    && destination_address == local_address.sin_addr.s_addr
                    && destination_port == ntohs(local_address.sin_port)
                    && state != 0x0A) {
                fclose(tcp_table);
                return (int)uid;
            }
        }
        fclose(tcp_table);
        if (attempt < 4) usleep(5000);
    }
    return -1;
}

static int allowed_hook_peer(int client_fd, int authenticated) {
    int uid = tcp_peer_uid(client_fd);
    int allowed = uid == 0
            || (system_uid >= 0 && uid == system_uid)
            || (settings_uid >= 0 && uid == settings_uid)
            || (games_uid >= 0 && uid == games_uid)
            || (scene_uid >= 0 && uid == scene_uid)
            || (bilibili_uid >= 0 && uid == bilibili_uid)
            || (uid == -1 && authenticated);
    if (!allowed) {
        log_msg("Rejected display hook bridge client uid=%d", uid);
    }
    return allowed;
}

static int create_display_hook_server(void) {
    int fd;
    int reuse = 1;
    int flags;
    struct sockaddr_in address;

    system_uid = 1000;
    settings_uid = package_uid("com.android.settings");
    games_uid = package_uid("com.oplus.games");
    scene_uid = package_uid("com.omarea.vtools");
    bilibili_uid = package_uid("tv.danmaku.bili");
    fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(DISPLAY_HOOK_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0
            || listen(fd, 4) != 0) {
        close(fd);
        return -1;
    }
    flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    log_msg("Display hook bridge listening on 127.0.0.1:%d "
            "system_uid=%d settings_uid=%d games_uid=%d scene_uid=%d bilibili_uid=%d",
            DISPLAY_HOOK_PORT, system_uid, settings_uid, games_uid, scene_uid,
            bilibili_uid);
    return fd;
}

static void handle_display_hook_client(int server_fd, const char *base_path) {
    struct sockaddr_in address;
    socklen_t address_length = sizeof(address);
    struct timeval timeout = {0, 500000};
    char request[256];
    char *request_text;
    char package_name[MAX_PKG_LEN];
    char story_phase[16];
    int fps;
    int width;
    int source_width;
    int density;
    long long generation;
    long long story_uptime;
    int client_fd = accept4(server_fd, (struct sockaddr *)&address,
                            &address_length, SOCK_CLOEXEC);
    ssize_t length;

    if (client_fd < 0) return;
    setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    length = recv(client_fd, request, sizeof(request) - 1, 0);
    if (length <= 0) {
        close(client_fd);
        return;
    }
    request[length] = '\0';
    request_text = trim(request);
    if (strncmp(request_text, "AUTH " DISPLAY_HOOK_TOKEN " ",
                strlen("AUTH " DISPLAY_HOOK_TOKEN " ")) != 0) {
        dprintf(client_fd, "ERR auth\n");
        close(client_fd);
        return;
    }
    request_text += strlen("AUTH " DISPLAY_HOOK_TOKEN " ");
    memmove(request, request_text, strlen(request_text) + 1);
    if (!allowed_hook_peer(client_fd, 1)) {
        dprintf(client_fd, "ERR permission\n");
        close(client_fd);
        return;
    }

    if (strcmp(trim(request), "PING") == 0) {
        dprintf(client_fd, "OK API 4\n");
    } else if (strcmp(trim(request), "LISTRATES") == 0) {
        int active_width = get_mode_width(default_mode_id);
        int active_height = mode_height(default_mode_id);
        int emitted[MAX_MODES];
        int emitted_count = 0;
        dprintf(client_fd, "RATES");
        for (int i = 0; i < mode_count; i++) {
            int fps = modes[i].fps;
            int duplicate = 0;
            if (modes[i].width != active_width || modes[i].height != active_height
                    || fps < 30 || fps > 1000) {
                continue;
            }
            for (int j = 0; j < emitted_count; j++) {
                if (emitted[j] == fps) {
                    duplicate = 1;
                    break;
                }
            }
            if (duplicate || emitted_count >= MAX_MODES) continue;
            emitted[emitted_count++] = fps;
            dprintf(client_fd, " %d", fps);
        }
        dprintf(client_fd, "\n");
        log_msg("Display hook listed %d rates for %dx%d", emitted_count,
                active_width, active_height);
    } else if (strcmp(trim(request), "LTPOBOOST") == 0) {
#ifndef MURONG_FREE_BUILD
        if (rmx5200_ltpo_touch_boost()) {
            dprintf(client_fd, "OK boost\n");
            log_msg("RMX5200 LTPO notification boost accepted");
        } else {
            dprintf(client_fd, "ERR inactive\n");
        }
#else
        dprintf(client_fd, "ERR inactive\n");
#endif
    } else if (sscanf(request, "STORYPAGE %15s %lld", story_phase,
                      &story_uptime) == 2
            && (strcmp(story_phase, "PREPARE") == 0
                || strcmp(story_phase, "FIRST_FRAME") == 0)
            && story_uptime > 0) {
        char command[256];
        snprintf(command, sizeof(command),
                 "settings put global murong_bilibili_story_memc_event "
                 "'%s:%lld' >/dev/null 2>&1",
                 story_phase, story_uptime);
        if (system(command) == 0) {
            dprintf(client_fd, "OK story\n");
            log_msg("Bilibili Story event phase=%s uptime=%lld uid=%d",
                    story_phase, story_uptime, bilibili_uid);
        } else {
            dprintf(client_fd, "ERR story\n");
        }
    } else if (strcmp(trim(request), "GETGLOBAL") == 0) {
        int global_fps = mode_fps(default_mode_id);
        if (global_fps > 0) {
            dprintf(client_fd, "FPS %d\n", global_fps);
        } else {
            dprintf(client_fd, "ERR mode\n");
        }
    } else if (strcmp(trim(request), "GETGLOBALID") == 0) {
        if (is_valid_mode(default_mode_id)) {
            dprintf(client_fd, "MODE %d\n", default_mode_id);
        } else {
            dprintf(client_fd, "ERR mode\n");
        }
    } else if (strcmp(trim(request), "GETGLOBALSTATE") == 0) {
        int width = get_mode_width(default_mode_id);
        int height = mode_height(default_mode_id);
        int global_fps = mode_fps(default_mode_id);
        if (is_valid_mode(default_mode_id) && width > 0 && height > 0
                && global_fps > 0) {
            dprintf(client_fd, "MODE %d %d %d %d\n", default_mode_id,
                    width, height, global_fps);
        } else {
            dprintf(client_fd, "ERR mode\n");
        }
    } else if (strcmp(trim(request), "VIDEOSTART VENDOR") == 0) {
#ifndef MURONG_FREE_BUILD
        if (start_video_vendor_hold(base_path)) {
            dprintf(client_fd, "OK %d\n", video_override_mode_id);
        } else {
            dprintf(client_fd, "ERR hold\n");
        }
#else
        dprintf(client_fd, "ERR hold\n");
#endif
    } else if (strcmp(trim(request), "VIDEOSTART FOLLOW") == 0) {
#ifndef MURONG_FREE_BUILD
        if (start_video_override(base_path, 1, -1)) {
            dprintf(client_fd, "OK %d\n", video_override_mode_id);
        } else {
            dprintf(client_fd, "ERR apply\n");
        }
#else
        dprintf(client_fd, "ERR apply\n");
#endif
    } else if (sscanf(request, "VIDEOSTART %d", &fps) == 1
            && fps >= 30 && fps <= 1000) {
#ifndef MURONG_FREE_BUILD
        if (start_video_override(base_path, 0, fps)) {
            dprintf(client_fd, "OK %d\n", video_override_mode_id);
        } else {
            dprintf(client_fd, "ERR apply\n");
        }
#else
        dprintf(client_fd, "ERR apply\n");
#endif
    } else if (strcmp(trim(request), "VIDEOEND") == 0) {
#ifndef MURONG_FREE_BUILD
        if (stop_video_override(base_path, "memc-exit")) {
            dprintf(client_fd, "OK %d\n", default_mode_id);
        } else {
            dprintf(client_fd, "ERR restore\n");
        }
#else
        dprintf(client_fd, "ERR restore\n");
#endif
    } else if (sscanf(request, "PREPRES %d", &width) == 1
            && width >= 480 && width <= 10000) {
        if (prepare_resolution_transaction(width)) {
            dprintf(client_fd, "OK %d\n", prepared_resolution.target_density);
        } else {
            dprintf(client_fd, "ERR prepare\n");
        }
    } else if (sscanf(request, "ADOPTRES %d %d %d %lld",
                      &width, &source_width, &density, &generation) == 4
            && width >= 480 && width <= 10000
            && source_width >= 480 && source_width <= 10000
            && density >= 72 && density <= 2000
            && generation > 0) {
        if (queue_native_resolution_adoption(width, source_width, density,
                                             generation)) {
            dprintf(client_fd, "OK %d\n", default_mode_id);
        } else {
            dprintf(client_fd, "ERR adopt\n");
        }
    } else if (sscanf(request, "SETRES %d %d", &width, &density) == 2
            && width >= 480 && width <= 10000
            && density >= 72 && density <= 2000) {
        fps = mode_fps(default_mode_id);
        int mode_id = mode_for_width_fps(width, fps);
        if (mode_id < 0) {
            dprintf(client_fd, "ERR mode\n");
        } else if (!apply_hook_mode_request(base_path, mode_id, width, density)) {
            dprintf(client_fd, "ERR apply\n");
        } else if (!write_resolution_config(base_path, mode_id, width)) {
            dprintf(client_fd, "ERR write\n");
        } else {
            load_config(base_path);
            dprintf(client_fd, "OK %d\n", mode_id);
            log_msg("Display hook set resolution width=%d density=%d fps=%d mode=%d",
                    width, density, fps, mode_id);
        }
    } else if (sscanf(request, "SETMODE %d %d %d", &width, &fps, &density) == 3
            && width >= 480 && width <= 10000
            && fps >= 30 && fps <= 1000
            && density >= 72 && density <= 2000) {
        int mode_id = mode_for_width_fps(width, fps);
        if (mode_id < 0) {
            dprintf(client_fd, "ERR mode\n");
        } else if (!apply_hook_mode_request(base_path, mode_id, width, density)) {
            dprintf(client_fd, "ERR apply\n");
        } else if (!write_resolution_config(base_path, mode_id, width)) {
            dprintf(client_fd, "ERR write\n");
        } else {
            load_config(base_path);
            dprintf(client_fd, "OK %d\n", mode_id);
            log_msg("Display hook set exact mode width=%d fps=%d density=%d mode=%d",
                    width, fps, density, mode_id);
        }
    } else if (sscanf(request, "SETGLOBAL %d", &fps) == 1
            && fps >= 30 && fps <= 1000) {
        int mode_id = mode_for_app_fps(fps);
        int width = get_mode_width(mode_id);
        int density = read_override_density();
        if (mode_id < 0) {
            dprintf(client_fd, "ERR mode\n");
        } else if (!apply_hook_mode_request(base_path, mode_id, width, density)) {
            dprintf(client_fd, "ERR apply\n");
        } else if (!write_global_config(base_path, mode_id)) {
            dprintf(client_fd, "ERR write\n");
        } else {
            load_config(base_path);
            sync_global_settings_async(base_path);
            dprintf(client_fd, "OK %d\n", mode_id);
            log_msg("Display hook set global=%dHz mode=%d", fps, mode_id);
        }
    } else if (strcmp(trim(request), "SETAUTO") == 0) {
        int mode_id = mode_for_app_fps(120);
        if (mode_id < 0) {
            dprintf(client_fd, "ERR mode\n");
        } else if (!write_global_config(base_path, mode_id)) {
            dprintf(client_fd, "ERR write\n");
        } else {
            load_config(base_path);
            force_reapply = 1;
            dprintf(client_fd, "OK %d\n", mode_id);
            log_msg("Display hook set automatic base=120Hz mode=%d", mode_id);
        }
    } else if (sscanf(request, "GET %127s", package_name) == 1
            && valid_package_name(package_name)) {
        for (int i = 0; i < app_config_count; i++) {
            if (strcmp(app_configs[i].package, package_name) == 0) {
                dprintf(client_fd, "FPS %d\n", mode_fps(app_configs[i].mode_id));
                close(client_fd);
                return;
            }
        }
        dprintf(client_fd, "ERR unset\n");
    } else if (sscanf(request, "GETID %127s", package_name) == 1
            && valid_package_name(package_name)) {
        for (int i = 0; i < app_config_count; i++) {
            if (strcmp(app_configs[i].package, package_name) == 0) {
                dprintf(client_fd, "MODE %d\n", app_configs[i].mode_id);
                close(client_fd);
                return;
            }
        }
        dprintf(client_fd, "ERR unset\n");
    } else if (sscanf(request, "SET %127s %d", package_name, &fps) == 2
            && valid_package_name(package_name) && fps >= 30 && fps <= 1000) {
        int mode_id = mode_for_app_fps(fps);
        if (mode_id < 0) {
            dprintf(client_fd, "ERR mode\n");
        } else if (!write_app_config(base_path, package_name, mode_id)) {
            dprintf(client_fd, "ERR write\n");
        } else {
            load_config(base_path);
            force_reapply = 1;
            dprintf(client_fd, "OK %d\n", mode_id);
            log_msg("Display hook set %s=%dHz mode=%d", package_name, fps, mode_id);
        }
    } else if (sscanf(request, "UNSET %127s", package_name) == 1
            && valid_package_name(package_name)) {
        if (!write_app_config_without(base_path, package_name)) {
            dprintf(client_fd, "ERR write\n");
        } else {
            load_config(base_path);
            force_reapply = 1;
            dprintf(client_fd, "OK unset\n");
            log_msg("Display hook removed %s override", package_name);
        }
    } else if (strcmp(trim(request), "CLEARAPPS") == 0) {
        if (!write_app_config_without(base_path, NULL)) {
            dprintf(client_fd, "ERR write\n");
        } else {
            load_config(base_path);
            force_reapply = 1;
            dprintf(client_fd, "OK clear\n");
            log_msg("Display hook removed all app overrides");
        }
    } else {
        dprintf(client_fd, "ERR request\n");
    }
    close(client_fd);
}



int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s <module_path>\n", argv[0]);
        return 1;
    }
    
    char *base_path = argv[1];
#ifndef MURONG_FREE_BUILD
    premium_base_path = base_path;
#endif
    printf("Rate Daemon started. Path: %s\n", base_path);

    if (signal(SIGUSR1, request_reapply) == SIG_ERR) {
        log_msg("Unable to install settings bridge reapply signal handler: %s",
                strerror(errno));
    }

    // 1. 初始化
    init_device_model();
    load_extension_rates(base_path);
    init_display_modes();
    if (mode_count == 0) {
        printf("Error: No display modes found.\n");
        // 如果失败，尝试稍后重试或退出
        return 1;
    }

    // 2. 初始加载配置
    load_config(base_path);
#ifndef MURONG_FREE_BUILD
    recover_video_iris_esd_on_startup(base_path);
#endif
    sync_oti_pause_policy(base_path, 1);
    int hook_server_fd = create_display_hook_server();
    reconcile_boot_resolution(base_path);
#ifndef MURONG_FREE_BUILD
    rmx5200_ltpo.touch_fd = open_rmx5200_touch_input();
#endif

    // 3. 初始设置
    int startup_mode_id = video_override_active
            ? video_override_mode_id : default_mode_id;
    if (is_valid_mode(startup_mode_id)) {
        apply_startup_default_mode(startup_mode_id);
    } else {
        if (mode_count > 0) {
            default_mode_id = modes[0].id;
            apply_startup_default_mode(default_mode_id);
        }
    }

    char last_pkg[MAX_PKG_LEN] = "";
    int last_screen_state = -1;
    long long last_policy_poll_ms = 0;
    long long last_touch_receipt_poll_ms = 0;
    
    // 初始化 inotify
    int inotify_fd = inotify_init();
    if (inotify_fd < 0) {
        log_msg("Error initializing inotify / 初始化 inotify 失败: %s", strerror(errno));
        // 降级为纯轮询模式，不退出
    }

    // 监听 config 目录 (监听目录可以捕获文件被重命名/移动覆盖的情况)
    // 很多编辑器保存文件时是 "写新文件 -> 移动覆盖"，这会改变 inode
    // 监听目录的 MOVED_TO 和 CREATE 事件能更好处理这种情况
    // 同时也监听 MODIFY 以防直接写入
    int wd = -1;
    int config_dirty = 0;
    long long config_reload_due_ms = 0;
    char config_dir[512];
    snprintf(config_dir, sizeof(config_dir), "%s/config", base_path);
    
    if (inotify_fd >= 0) {
        wd = inotify_add_watch(inotify_fd, config_dir, IN_MODIFY | IN_MOVED_TO | IN_CREATE);
        if (wd < 0) {
            log_msg("Error adding watch for / 添加监听失败 %s: %s", config_dir, strerror(errno));
            close(inotify_fd);
            inotify_fd = -1;
        } else {
            log_msg("Inotify watching directory / Inotify 正在监听目录: %s", config_dir);
        }
    }

    // 4. 主循环
    while (1) {
        while (waitpid(-1, NULL, WNOHANG) > 0) {
            // Reap completed bridge helpers without breaking synchronous system().
        }
        // 使用 select 实现 "等待事件 或 超时"
        if (inotify_fd >= 0 || hook_server_fd >= 0 ||
                rmx5200_ltpo.touch_fd >= 0) {
            fd_set fds;
            FD_ZERO(&fds);
            int max_fd = -1;
            if (inotify_fd >= 0) {
                FD_SET(inotify_fd, &fds);
                max_fd = inotify_fd;
            }
            if (hook_server_fd >= 0) {
                FD_SET(hook_server_fd, &fds);
                if (hook_server_fd > max_fd) max_fd = hook_server_fd;
            }
            if (rmx5200_ltpo.touch_fd >= 0) {
                FD_SET(rmx5200_ltpo.touch_fd, &fds);
                if (rmx5200_ltpo.touch_fd > max_fd)
                    max_fd = rmx5200_ltpo.touch_fd;
            }

            struct timeval timeout;
            if (rmx5200_ltpo.rise_queue_active) {
                /* Physical receipts are asynchronous.  Poll the queue at
                 * 10ms while it owns a rise so the next ladder node is not
                 * delayed by the normal 100ms LTPO policy tick. */
                timeout.tv_sec = 0;
                timeout.tv_usec = 10000;
            } else if (native_resolution_adoption.valid || rmx5200_ltpo.active) {
                timeout.tv_sec = 0;
                timeout.tv_usec = 100000;
            } else {
                timeout.tv_sec = 1;  // 1秒超时，用于检查前台应用
                timeout.tv_usec = 0;
            }

            int ret = select(max_fd + 1, &fds, NULL, NULL, &timeout);

            if (ret > 0 && inotify_fd >= 0 && FD_ISSET(inotify_fd, &fds)) {
                // 有文件变化事件。只关心 mode.txt，并等待写入者停止产生
                // 事件，避免半写入配置触发多次连续切换。
                char buffer[1024];
                int len = read(inotify_fd, buffer, sizeof(buffer));
                if (len > 0) {
                    int offset = 0;
                    while (offset < len) {
                        struct inotify_event *event =
                            (struct inotify_event *)(buffer + offset);
                        if (event->len == 0 || strcmp(event->name, "mode.txt") == 0) {
                            config_dirty = 1;
                            config_reload_due_ms = monotonic_ms() + 200;
                        }
                        offset += (int)sizeof(struct inotify_event) + event->len;
                    }
                }
            }
            if (ret > 0 && hook_server_fd >= 0 && FD_ISSET(hook_server_fd, &fds)) {
                handle_display_hook_client(hook_server_fd, base_path);
            }
#ifndef MURONG_FREE_BUILD
            if (ret > 0 && rmx5200_ltpo.touch_fd >= 0 &&
                    FD_ISSET(rmx5200_ltpo.touch_fd, &fds)) {
                handle_rmx5200_touch_input();
                /* Touch motion can produce hundreds of events per second.
                 * Settle a pending DSI receipt at a bounded cadence without
                 * entering the dumpsys-heavy foreground policy path. */
                if (ret == 1 && rmx5200_ltpo.active) {
                    long long now_ms = monotonic_ms();

                    if (rmx5200_ltpo.rise_queue_active) {
                        rmx5200_ltpo_process_rise_queue();
                        last_touch_receipt_poll_ms = now_ms;
                        continue;
                    }
                    if (is_valid_mode(
                                rmx5200_ltpo.pending_ceiling_mode_id) &&
                            now_ms - last_touch_receipt_poll_ms >=
                                RMX5200_LTPO_PENDING_POLL_MS) {
                        rmx5200_ltpo_quarantine_superseded_drop(
                                rmx5200_ltpo.ceiling_mode_id, now_ms);
                        rmx5200_ltpo_settle_pending_ceiling();
                        last_touch_receipt_poll_ms = now_ms;
                    }
                    continue;
                }
            }
            if (ret == 0 && rmx5200_ltpo.active) {
                long long now_ms = monotonic_ms();

                update_rmx5200_ltpo_controller(
                        base_path, rmx5200_ltpo.ceiling_mode_id,
                        last_screen_state);
                if (now_ms - last_policy_poll_ms < 1000) continue;
                last_policy_poll_ms = now_ms;
            }
#endif
            // 如果 ret == 0 (超时)，则继续执行下方的应用检查
        } else {
            // 降级模式：简单的 sleep
            sleep(1);
        }

        // If inotify is unavailable but the hook socket is alive, select()
        // still supplies the one-second cadence for this polling fallback.
        if (inotify_fd < 0) {
            static time_t last_config_check = 0;
            time_t now = time(NULL);
            if (now - last_config_check > 5) {
                load_config(base_path);
                last_config_check = now;
            }
        }

        if (config_dirty && monotonic_ms() >= config_reload_due_ms) {
            log_msg("Config change settled / 配置写入完成，重新加载");
            load_extension_rates(base_path);
            load_config(base_path);
            config_dirty = 0;
        }

        if (reapply_requested) {
            reapply_requested = 0;
            force_reapply = 1;
            log_msg("Settings/Game Assistant requested a mode reapply");
        }

        process_native_resolution_adoption(base_path);
        if (native_resolution_adoption.valid) {
            /* ColorOS owns the geometry transition. Replaying the old global
             * mode here would race it and can pin the display at the source
             * resolution before the Settings transaction reaches HWC. */
            continue;
        }

        /* WebUI persists the ADFR policy independently of mode.txt. Reading it
         * here lets the daemon complete a toggle even if the helper process was
         * interrupted between writing the file and issuing the Binder call. */
        sync_oti_pause_policy(base_path, 0);
#ifndef MURONG_FREE_BUILD
        maybe_restore_video_iris_esd(base_path);
#endif

        // 屏幕状态监测：息屏时面板被框架重置为 120Hz，但缓存未失效，
        // 亮屏后检测不到差异就不会重新下发，导致一直停在 120Hz。
        // 这里检测 OFF/DOZE -> ON 的跳变，强制重放一次目标模式。
        int screen_state = get_screen_state();
        if (screen_state != last_screen_state) {
            if (screen_state == 1) {
                log_msg("Screen state -> ON / 屏幕状态 -> 亮屏");
                if (last_screen_state == 0) {
                    log_msg("Screen ON after OFF/DOZE / 息屏后亮屏: 稍后强制重放刷新率");
                    // 等 SurfaceFlinger 完成亮屏初始化后再重放
                    usleep(300000);
                    sync_oti_pause_policy(base_path, 1);
                    force_reapply = 1;
                    screen_on_reapply_pending = 1;
                    log_msg("Screen ON reapply queued: physical mode and "
                            "framework mirror will be restored together");
                }
            } else if (screen_state == 0) {
                log_msg("Screen state -> OFF/DOZE / 屏幕状态 -> 息屏/待机");
#ifndef MURONG_FREE_BUILD
                if (video_override_active) {
                    clear_video_override(base_path);
                    force_reapply = 1;
                    log_msg("Video temporary mode cleared on screen off; "
                            "mode.txt will be restored on screen on");
                }
#endif
            }
            last_screen_state = screen_state;
        }

        // 获取前台应用
        char current_pkg[MAX_PKG_LEN] = "";
        get_foreground_app(current_pkg, sizeof(current_pkg));
#ifndef MURONG_FREE_BUILD
        /* Probe before the next LTPO policy tick.  This is deliberately
         * package-neutral: the foreground package is only used to scope the
         * SurfaceFlinger layer match, not as an allowlist. */
        rmx5200_video_surface_probe(current_pkg);
#endif

        if (strlen(current_pkg) > 0) {
            // 记录应用切换
            if (strcmp(current_pkg, last_pkg) != 0) {
                 log_msg("Detected App Change / 检测到应用切换: %s", current_pkg);
                 strncpy(last_pkg, current_pkg, MAX_PKG_LEN);
            }

            // 总是检查是否需要切换，因为可能配置变了但应用没变
            int target_id;
#ifndef MURONG_FREE_BUILD
            if (video_exit_pending) {
                /* VIDEOEND has handed display policy back to ColorOS. While
                 * Iris is leaving SINGLE-MEMC, any mode transaction can wedge
                 * FRC or provoke a DPMS recovery. maybe_restore_video_iris_esd()
                 * clears this state only after bypass has been stable for 5s. */
                target_id = -1;
            } else if (video_override_active && video_override_vendor_owned) {
                /* ColorOS owns the MEMC input vote. Keep custom LTPO and the
                 * generic mode loop idle until VIDEOEND releases this hold. */
                target_id = -1;
            } else if (video_override_active) {
                int applied_id;

                if (video_exit_defer_active) {
                    char defer_pkg[MAX_PKG_LEN] = "";
                    get_foreground_app(defer_pkg, sizeof(defer_pkg));
                    if (!rmx5200_video_surface_probe(defer_pkg) ||
                            monotonic_ms() >= video_exit_defer_until_ms) {
                        video_exit_defer_active = 0;
                        video_exit_defer_until_ms = -1;
                        log_msg("Video temporary mode defer expired; "
                                "restoring mode.txt");
                        clear_video_override(base_path);
                        target_id = default_mode_id;
                        force_reapply = 1;
                    }
                }
                if (video_override_active) {
                    target_id = resolve_video_override_mode();
                    if (is_valid_mode(target_id)) {
                        video_override_mode_id = target_id;
                        applied_id = get_current_applied_mode();
                        if (is_valid_mode(applied_id) &&
                                same_mode_geometry(applied_id, target_id) &&
                                applied_id != target_id) {
                            log_msg("Video temporary mode drift detected: "
                                    "target=%d/%dHz applied=%d/%dHz; reasserting",
                                    target_id, mode_fps(target_id), applied_id,
                                    mode_fps(applied_id));
                            current_mode_id = applied_id;
                            force_reapply = 1;
                        }
                    } else {
                        log_msg("Video temporary mode became invalid; restoring mode.txt");
                        clear_video_override(base_path);
                        target_id = default_mode_id;
                        force_reapply = 1;
                    }
                }
            } else
#endif
            {
                target_id = default_mode_id;
                for (int i=0; i<app_config_count; i++) {
                    if (strcmp(app_configs[i].package, current_pkg) == 0) {
                        target_id = app_configs[i].mode_id;
                        break;
                    }
                }
            }
            
#ifndef MURONG_FREE_BUILD
                if (video_exit_pending ||
                        (video_override_active && video_override_vendor_owned)) {
                    /* Deliberately idle during Iris exit or a vendor-owned
                     * MEMC input-timing session. */
                } else {
                    update_rmx5200_ltpo_controller(base_path, target_id,
                                                    screen_state);
                    if (rmx5200_ltpo.active) {
                        /* LTPO owns refresh-rate steps, but it must not mask
                         * a ColorOS app/scene resolution vote.  Games and
                         * video apps can move HWC to the FHD group while the
                         * durable policy remains QHD; leaving the controller
                         * idle here also leaves Android with a stale 560-dpi
                         * layout.  Let the normal transaction restore the
                         * configured geometry, then resume LTPO ownership. */
                        int applied_id = get_current_applied_mode();
                        int geometry_id = applied_id;
                        int geometry_drift;

                        /* DisplayManager can trail the physical mode while a
                         * ColorOS app vote is settling. Prefer its coherent
                         * applied snapshot, then confirm a mismatch against
                         * SurfaceFlinger's live HWC mode before deciding that
                         * the app changed resolution. */
                        if (!is_valid_mode(geometry_id)
                                || (is_valid_mode(target_id)
                                && get_mode_width(geometry_id)
                                != get_mode_width(target_id))) {
                            int physical_id = get_current_system_mode();
                            if (is_valid_mode(physical_id)) geometry_id = physical_id;
                        }
                        geometry_drift = is_valid_mode(geometry_id)
                                && is_valid_mode(target_id)
                                && get_mode_width(geometry_id)
                                != get_mode_width(target_id);
                        if (geometry_drift) {
                            log_msg("LTPO geometry drift detected: applied=%d/%dpx "
                                    "target=%d/%dpx; restoring resolution",
                                    geometry_id, get_mode_width(geometry_id),
                                    target_id, get_mode_width(target_id));
                            /* A pending old-geometry drop/rise cannot be
                             * replayed after the ColorOS resolution switch.
                             * Clear only controller bookkeeping; the vendor
                             * OTI pause remains owned by the active LTPO
                             * session and is released normally if the new
                             * geometry is not eligible. */
                            rmx5200_ltpo.pending_ceiling_mode_id = -1;
                            rmx5200_ltpo.touch_direct_request_ms = 0;
                            rmx5200_ltpo.touch_direct_commit_count = 0;
                            rmx5200_ltpo.touch_direct_retries = 0;
                            rmx5200_ltpo_clear_pending_drop("geometry-drift");
                            rmx5200_ltpo_clear_superseded_drop();
                            current_mode_id = geometry_id;
                            force_reapply = 1;
                            smooth_switch(target_id);
                        } else if (screen_on_reapply_pending &&
                                   is_valid_mode(target_id)) {
                            /* Refresh current_mode_id from DisplayManager's
                             * applied snapshot before the LTPO ladder. The
                             * cached ceiling can still be 165 while ColorOS
                             * has physically fallen back to 144 after DOZE. */
                            int observed_id = get_current_applied_mode();

                            if (!is_valid_mode(observed_id) ||
                                    !same_mode_geometry(observed_id, target_id)) {
                                observed_id = get_current_system_mode();
                            }
                            int screen_on_anchor_ready = 1;
                            if (is_valid_mode(observed_id) &&
                                    same_mode_geometry(observed_id, target_id)) {
                                current_mode_id = observed_id;
                                if (!is_valid_mode(current_mode_id) ||
                                        current_mode_id == target_id) {
                                    screen_on_anchor_ready =
                                        prepare_screen_on_reapply_anchor(
                                            target_id);
                                }
                            }
                            if (screen_on_anchor_ready &&
                                    is_valid_mode(observed_id) &&
                                    same_mode_geometry(observed_id, target_id) &&
                                    rmx5200_ltpo_switch_runtime_mode(
                                        target_id, "screen-on-reapply")) {
                                /* ColorOS may have reset its stock enum and
                                 * peak-rate settings alongside the physical
                                 * fallback. Publish them only after the exact
                                 * target timing has been restored. */
                                sync_android_settings(target_id);
                                screen_on_reapply_pending = 0;
                                force_reapply = 0;
                                log_msg("Screen ON LTPO reapply completed: "
                                        "mode=%d/%dHz", target_id,
                                        mode_fps(target_id));
                            } else {
                                /* An unknown current mode must not be treated
                                 * as a successful no-op at the cached ceiling.
                                 * Preserve both flags for the next main-loop
                                 * tick. Clearing either one reintroduces the
                                 * 165Hz -> 144Hz-after-screen-off regression. */
                                force_reapply = 1;
                                log_msg("Screen ON LTPO reapply retry pending: "
                                        "target=%d/%dHz observed=%d", target_id,
                                        mode_fps(target_id), observed_id);
                            }
                        } else {
                            /* The normal LTPO policy owns its own steps. Do
                             * not consume a screen-on recovery transaction
                             * until it has restored both timing and settings. */
                            if (!screen_on_reapply_pending) force_reapply = 0;
                        }
                    } else if (strcmp(device_model, "RMX5200") == 0 &&
                               screen_state == 0) {
                    /* Doze owns panel timing. Do not feed the generic
                     * refresh ladder while the custom LTPO controller is
                     * intentionally inactive; the OFF/DOZE -> ON path
                     * already sets force_reapply after display init. */
                    } else if (is_valid_mode(target_id) &&
                               (target_id != current_mode_id || force_reapply)) {
                        int completing_screen_on = screen_on_reapply_pending;

                        smooth_switch(target_id);
                        if (completing_screen_on) {
                            int observed_id = get_current_applied_mode();

                            if (screen_on_reapply_transaction_ok &&
                                    observed_id == target_id) {
                                screen_on_reapply_pending = 0;
                                force_reapply = 0;
                                log_msg("Screen ON generic reapply completed: "
                                        "mode=%d/%dHz", target_id,
                                        mode_fps(target_id));
                            } else {
                                force_reapply = 1;
                                log_msg("Screen ON generic reapply retry pending: "
                                        "target=%d/%dHz observed=%d", target_id,
                                        mode_fps(target_id), observed_id);
                            }
                        }
                    }
                }
#else
                if (strcmp(device_model, "RMX5200") == 0 &&
                        screen_state == 0) {
                    /* Doze owns panel timing. The OFF/DOZE -> ON path already
                     * sets force_reapply after display init. */
                    } else if (is_valid_mode(target_id) &&
                           (target_id != current_mode_id || force_reapply)) {
                    int completing_screen_on = screen_on_reapply_pending;

                    smooth_switch(target_id);
                    if (completing_screen_on) {
                        int observed_id = get_current_applied_mode();

                        if (screen_on_reapply_transaction_ok &&
                                observed_id == target_id) {
                            screen_on_reapply_pending = 0;
                            force_reapply = 0;
                            log_msg("Screen ON generic reapply completed: "
                                    "mode=%d/%dHz", target_id,
                                    mode_fps(target_id));
                        } else {
                            force_reapply = 1;
                            log_msg("Screen ON generic reapply retry pending: "
                                    "target=%d/%dHz observed=%d", target_id,
                                    mode_fps(target_id), observed_id);
                        }
                    }
                }
#endif
            
        }
        maintain_adfr_lock(base_path,
                           is_valid_mode(current_mode_id)
                               ? current_mode_id : default_mode_id);
    }
    // while loop end
    
    // Cleanup (unreachable usually)
    if (inotify_fd >= 0) close(inotify_fd);
    if (hook_server_fd >= 0) close(hook_server_fd);
    if (rmx5200_ltpo.touch_fd >= 0) close(rmx5200_ltpo.touch_fd);
    
    return 0;
}
