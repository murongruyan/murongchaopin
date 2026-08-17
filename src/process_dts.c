/*
 * Process DTS Tool
 * 
 * Modifications for 1080p DPI Flickering Fix & LTPO Stability:
 * 1. Automatic Clock Calculation:
 *    - Formula: New_Clock = Base_Clock * (Target_FPS / Base_FPS)
 *    - Applied to 123Hz and 150-180Hz modes.
 * 
 * 2. Preserve stock low-refresh timings by default. An explicit
 *    --rmx5200-ltpo-template A/B flag restores the historical GT8 workaround:
 *    copy the native WQHD 144Hz timing to WQHD 60Hz, restore the 60Hz
 *    cell-index, and retain the 144Hz clock/transfer envelope.
 * 
 * 3. Dynamic Node Generation:
 *    - Generates 123Hz from 120Hz.
 *    - Generates 150Hz-180Hz from 144Hz.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <ctype.h>
#include <stdint.h>
#ifndef PROCESS_DTS_TEST_MODEL
#include <sys/system_properties.h>
#endif

#define MODEL_UNKNOWN 0
#define MODEL_RMX5200 1 // Realme GT8 Pro
#define MODEL_PLK110  2 // OnePlus 15 (PLK110)
#define MODEL_PJD110  3 // OnePlus 12 (PJD110)

int g_current_model = MODEL_UNKNOWN;
unsigned long long g_target_project_id = 0;
int g_has_project_id = 0;
int g_rmx5200_adfr_dry_run = 0;
int g_rmx5200_adfr_ltpo = 0;
int g_rmx5200_drop_stock_fhd = 0;
int g_rmx5200_drop_stock_wqhd = 0;
int g_rmx5200_keep_stock_fhd60 = 0;
int g_rmx5200_ltpo_template = 0;
int g_hmbird_only = 0;
char g_hmbird_only_type[32] = {0};
int g_hmbird_patch_count = 0;
int g_pjd110_ko_support = 0;
int g_pjd110_batt_capacity_count = 0;
int g_pjd110_vbat_threshold_count = 0;
int g_pjd110_reserve_soc_count = 0;
int g_processing_error = 0;

#define RMX5200_ADFR_PROFILE_DEFAULT "../config/rmx5200_adfr_profile.txt"
#define RMX5200_ADFR_PROFILE_FALLBACK "config/rmx5200_adfr_profile.txt"
#define RMX5200_ADFR_COMMANDS_DEFAULT "../config/rmx5200_adfr_commands.dtsi"
#define RMX5200_ADFR_COMMANDS_FALLBACK "config/rmx5200_adfr_commands.dtsi"
#define RMX5200_ADFR_COMMANDS_SHA256 \
    "dbe4e9149fc260415bff8aa64894feb95d294870a03172256455a3cb9be5cd8a"
#define DISPLAY_MODE_MANIFEST_DEFAULT "../config/display_mode_manifest.txt"
#define DISPLAY_MODE_MANIFEST_FALLBACK "config/display_mode_manifest.txt"
#define RMX5200_ADFR_PROFILE_ID "ae084-dvt02-ltpo1hz-dry-run-v1"
#define RMX5200_ADFR_PANEL_TOKEN "AE084_P_3_A0033"
#define RMX5200_ADFR_PANEL_NAME \
    "qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02"
#define RMX5200_ADFR_COMMAND_FAMILY "F0_55_AA_52"

typedef struct {
    char profile_version[16];
    char profile_id[96];
    char state[32];
    char panel_token[64];
    char panel_name[160];
    char command_family[48];
    char command_set_count[16];
    char command_payload_sha256[80];
    char mapping_low[128];
    char mapping_high_suffix[128];
    char adfr_config[32];
    char physical_1hz_verified[16];
} Rmx5200AdfrProfile;

static Rmx5200AdfrProfile g_rmx5200_adfr_profile;
static char g_rmx5200_adfr_commands[16384];
static size_t g_rmx5200_adfr_commands_length;

typedef struct {
    unsigned int rmx5200_dtbo_rates[16];
    size_t rmx5200_dtbo_count;
    unsigned int plk110_dtbo_rates[16];
    size_t plk110_dtbo_count;
} DisplayModeManifest;

static DisplayModeManifest g_display_mode_manifest;

#define RMX5200_PROFILE_VERSION_BIT       (1U << 0)
#define RMX5200_PROFILE_ID_BIT            (1U << 1)
#define RMX5200_PROFILE_STATE_BIT         (1U << 2)
#define RMX5200_PROFILE_PANEL_TOKEN_BIT   (1U << 3)
#define RMX5200_PROFILE_PANEL_NAME_BIT    (1U << 4)
#define RMX5200_PROFILE_COMMAND_FAMILY_BIT (1U << 5)
#define RMX5200_PROFILE_COMMAND_COUNT_BIT (1U << 6)
#define RMX5200_PROFILE_PAYLOAD_HASH_BIT  (1U << 7)
#define RMX5200_PROFILE_LOW_MAP_BIT       (1U << 8)
#define RMX5200_PROFILE_HIGH_MAP_BIT      (1U << 9)
#define RMX5200_PROFILE_CONFIG_BIT        (1U << 10)
#define RMX5200_PROFILE_PHYSICAL_BIT      (1U << 11)
#define RMX5200_PROFILE_REQUIRED_BITS     ((1U << 12) - 1U)

static int profile_copy_value(char *dst, size_t dst_size,
                              const char *key, const char *line) {
    size_t key_len = strlen(key);
    const char *value;
    size_t value_len;

    if (strncmp(line, key, key_len) != 0 || line[key_len] != '=') return 0;
    value = line + key_len + 1;
    while (*value == ' ' || *value == '\t') value++;
    value_len = strlen(value);
    while (value_len &&
           (value[value_len - 1] == ' ' || value[value_len - 1] == '\t' ||
            value[value_len - 1] == '\r' || value[value_len - 1] == '\n')) {
        value_len--;
    }
    if (value_len >= dst_size) return -1;
    memcpy(dst, value, value_len);
    dst[value_len] = '\0';
    return 1;
}

static int load_rmx5200_adfr_profile(void) {
    const char *env_path = getenv("MURONGCHAOPIN_ADFR_PROFILE");
    const char *paths[3];
    FILE *in = NULL;
    char line[512];
    int i;
    unsigned long command_count;
    unsigned int seen = 0;

    memset(&g_rmx5200_adfr_profile, 0, sizeof(g_rmx5200_adfr_profile));
    paths[0] = env_path && *env_path ? env_path : RMX5200_ADFR_PROFILE_DEFAULT;
    paths[1] = env_path && *env_path ? NULL : RMX5200_ADFR_PROFILE_FALLBACK;
    paths[2] = NULL;
    for (i = 0; paths[i]; i++) {
        in = fopen(paths[i], "r");
        if (in) break;
    }
    if (!in) {
        printf("ERROR: RMX5200 ADFR profile is missing (set MURONGCHAOPIN_ADFR_PROFILE or install config/rmx5200_adfr_profile.txt).\n");
        return 0;
    }
    while (fgets(line, sizeof(line), in)) {
        char *p = line;
        int rc;
        while (*p == ' ' || *p == '\t') p++;
        if (!*p || *p == '#') continue;
#define LOAD_RMX5200_PROFILE_VALUE(field, key, bit) \
        rc = profile_copy_value(g_rmx5200_adfr_profile.field, \
                                sizeof(g_rmx5200_adfr_profile.field), \
                                key, p); \
        if (rc != 0) { \
            if (rc < 0 || (seen & bit)) goto malformed; \
            seen |= bit; \
            continue; \
        }
        LOAD_RMX5200_PROFILE_VALUE(profile_version, "profile_version",
                                   RMX5200_PROFILE_VERSION_BIT);
        LOAD_RMX5200_PROFILE_VALUE(profile_id, "profile_id",
                                   RMX5200_PROFILE_ID_BIT);
        LOAD_RMX5200_PROFILE_VALUE(state, "state",
                                   RMX5200_PROFILE_STATE_BIT);
        LOAD_RMX5200_PROFILE_VALUE(panel_token, "panel_token",
                                   RMX5200_PROFILE_PANEL_TOKEN_BIT);
        LOAD_RMX5200_PROFILE_VALUE(panel_name, "panel_name",
                                   RMX5200_PROFILE_PANEL_NAME_BIT);
        LOAD_RMX5200_PROFILE_VALUE(command_family, "command_family",
                                   RMX5200_PROFILE_COMMAND_FAMILY_BIT);
        LOAD_RMX5200_PROFILE_VALUE(command_set_count, "command_set_count",
                                   RMX5200_PROFILE_COMMAND_COUNT_BIT);
        LOAD_RMX5200_PROFILE_VALUE(command_payload_sha256,
                                   "command_payload_sha256",
                                   RMX5200_PROFILE_PAYLOAD_HASH_BIT);
        LOAD_RMX5200_PROFILE_VALUE(mapping_low, "mapping_low",
                                   RMX5200_PROFILE_LOW_MAP_BIT);
        LOAD_RMX5200_PROFILE_VALUE(mapping_high_suffix,
                                   "mapping_high_suffix",
                                   RMX5200_PROFILE_HIGH_MAP_BIT);
        LOAD_RMX5200_PROFILE_VALUE(adfr_config, "adfr_config",
                                   RMX5200_PROFILE_CONFIG_BIT);
        LOAD_RMX5200_PROFILE_VALUE(physical_1hz_verified,
                                   "physical_1hz_verified",
                                   RMX5200_PROFILE_PHYSICAL_BIT);
#undef LOAD_RMX5200_PROFILE_VALUE
    }
    fclose(in);

    command_count = strtoul(g_rmx5200_adfr_profile.command_set_count, NULL, 10);
    if (seen != RMX5200_PROFILE_REQUIRED_BITS ||
        strcmp(g_rmx5200_adfr_profile.profile_version, "1") ||
        strcmp(g_rmx5200_adfr_profile.profile_id, RMX5200_ADFR_PROFILE_ID) ||
        strcmp(g_rmx5200_adfr_profile.state, "dry-run") ||
        strcmp(g_rmx5200_adfr_profile.panel_token, RMX5200_ADFR_PANEL_TOKEN) ||
        strcmp(g_rmx5200_adfr_profile.panel_name, RMX5200_ADFR_PANEL_NAME) ||
        strcmp(g_rmx5200_adfr_profile.command_family, RMX5200_ADFR_COMMAND_FAMILY) ||
        command_count != 0 ||
        strcmp(g_rmx5200_adfr_profile.command_payload_sha256, "none") ||
        strcmp(g_rmx5200_adfr_profile.mapping_low, "60 40 30 20 10 1") ||
        strcmp(g_rmx5200_adfr_profile.mapping_high_suffix, "60 30 20 10 1") ||
        strcmp(g_rmx5200_adfr_profile.adfr_config, "0x101") ||
        strcmp(g_rmx5200_adfr_profile.physical_1hz_verified, "0")) {
        printf("ERROR: RMX5200 ADFR profile is not the supported AE084 parser-only profile.\n");
        return 0;
    }
    printf("Verified RMX5200 ADFR profile %s: AE084 command family %s, command sets=%lu, physical_1hz_verified=0.\n",
           g_rmx5200_adfr_profile.profile_id,
           g_rmx5200_adfr_profile.command_family, command_count);
    return 1;

malformed:
    if (in) fclose(in);
    printf("ERROR: RMX5200 ADFR profile is malformed, duplicate, or contains an overlong value.\n");
    return 0;
}

static int count_text_occurrences(const char *text, const char *needle) {
    int count = 0;
    size_t needle_len = strlen(needle);

    if (!text || !needle_len) return 0;
    while ((text = strstr(text, needle))) {
        count++;
        text += needle_len;
    }
    return count;
}

typedef struct {
    uint8_t data[64];
    uint32_t state[8];
    uint64_t bit_length;
    size_t data_length;
} Sha256Context;

static const uint32_t sha256_constants[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
    0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
    0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
    0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
};

static uint32_t sha256_rotate_right(uint32_t value, unsigned int bits) {
    return (value >> bits) | (value << (32U - bits));
}

static void sha256_transform(Sha256Context *context,
                             const uint8_t data[64]) {
    uint32_t words[64];
    uint32_t a, b, c, d, e, f, g, h;
    unsigned int i;

    for (i = 0; i < 16; i++) {
        words[i] = ((uint32_t)data[i * 4] << 24) |
                   ((uint32_t)data[i * 4 + 1] << 16) |
                   ((uint32_t)data[i * 4 + 2] << 8) |
                   (uint32_t)data[i * 4 + 3];
    }
    for (; i < 64; i++) {
        uint32_t s0 = sha256_rotate_right(words[i - 15], 7) ^
                      sha256_rotate_right(words[i - 15], 18) ^
                      (words[i - 15] >> 3);
        uint32_t s1 = sha256_rotate_right(words[i - 2], 17) ^
                      sha256_rotate_right(words[i - 2], 19) ^
                      (words[i - 2] >> 10);
        words[i] = words[i - 16] + s0 + words[i - 7] + s1;
    }

    a = context->state[0];
    b = context->state[1];
    c = context->state[2];
    d = context->state[3];
    e = context->state[4];
    f = context->state[5];
    g = context->state[6];
    h = context->state[7];
    for (i = 0; i < 64; i++) {
        uint32_t sum1 = sha256_rotate_right(e, 6) ^
                        sha256_rotate_right(e, 11) ^
                        sha256_rotate_right(e, 25);
        uint32_t choice = (e & f) ^ ((~e) & g);
        uint32_t temp1 = h + sum1 + choice + sha256_constants[i] + words[i];
        uint32_t sum0 = sha256_rotate_right(a, 2) ^
                        sha256_rotate_right(a, 13) ^
                        sha256_rotate_right(a, 22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = sum0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }
    context->state[0] += a;
    context->state[1] += b;
    context->state[2] += c;
    context->state[3] += d;
    context->state[4] += e;
    context->state[5] += f;
    context->state[6] += g;
    context->state[7] += h;
}

static void sha256_init(Sha256Context *context) {
    context->data_length = 0;
    context->bit_length = 0;
    context->state[0] = 0x6a09e667U;
    context->state[1] = 0xbb67ae85U;
    context->state[2] = 0x3c6ef372U;
    context->state[3] = 0xa54ff53aU;
    context->state[4] = 0x510e527fU;
    context->state[5] = 0x9b05688cU;
    context->state[6] = 0x1f83d9abU;
    context->state[7] = 0x5be0cd19U;
}

static void sha256_update(Sha256Context *context, const uint8_t *data,
                          size_t length) {
    size_t i;
    for (i = 0; i < length; i++) {
        context->data[context->data_length++] = data[i];
        if (context->data_length == sizeof(context->data)) {
            sha256_transform(context, context->data);
            context->bit_length += 512;
            context->data_length = 0;
        }
    }
}

static void sha256_final(Sha256Context *context, uint8_t hash[32]) {
    size_t i = context->data_length;
    uint64_t bit_length;

    context->data[i++] = 0x80;
    if (i > 56) {
        while (i < 64) context->data[i++] = 0;
        sha256_transform(context, context->data);
        i = 0;
    }
    while (i < 56) context->data[i++] = 0;
    bit_length = context->bit_length + context->data_length * 8U;
    for (i = 0; i < 8; i++) {
        context->data[63 - i] = (uint8_t)(bit_length >> (i * 8));
    }
    sha256_transform(context, context->data);
    for (i = 0; i < 32; i++) {
        hash[i] = (uint8_t)(context->state[i / 4] >> (24 - (i % 4) * 8));
    }
}

static void sha256_hex(const void *data, size_t length, char hex[65]) {
    static const char digits[] = "0123456789abcdef";
    Sha256Context context;
    uint8_t hash[32];
    size_t i;

    sha256_init(&context);
    sha256_update(&context, data, length);
    sha256_final(&context, hash);
    for (i = 0; i < sizeof(hash); i++) {
        hex[i * 2] = digits[hash[i] >> 4];
        hex[i * 2 + 1] = digits[hash[i] & 0x0f];
    }
    hex[64] = '\0';
}

static int validate_rmx5200_adfr_commands(const char *text) {
    static const char *families[] = {
        "qcom,mdss-dsi-bigdc-adfr-min-fps-",
        "qcom,mdss-dsi-hpwm-adfr-min-fps-",
        "qcom,mdss-dsi-adfr-min-fps-"
    };
    char property[160];
    size_t family;
    int index;

    if (!text || strchr(text, '{') || strchr(text, '}') ||
        strstr(text, "oplus,adfr-config") ||
        strstr(text, "oplus,adfr-min-fps-mapping-table")) {
        return 0;
    }
    for (family = 0; family < sizeof(families) / sizeof(families[0]); family++) {
        for (index = 0; index < 6; index++) {
            snprintf(property, sizeof(property), "%s%d-command-state",
                     families[family], index);
            if (count_text_occurrences(text, property) != 1) return 0;
            snprintf(property, sizeof(property), "%s%d-command =",
                     families[family], index);
            if (count_text_occurrences(text, property) != 1) return 0;
        }
    }
    return count_text_occurrences(text, "5aa52d39") == 18;
}

static int load_rmx5200_adfr_commands(void) {
    const char *env_path = getenv("MURONGCHAOPIN_ADFR_COMMANDS");
    const char *paths[3];
    FILE *in = NULL;
    long length;
    char payload_hash[65];
    int i;

    paths[0] = env_path && *env_path ? env_path : RMX5200_ADFR_COMMANDS_DEFAULT;
    paths[1] = env_path && *env_path ? NULL : RMX5200_ADFR_COMMANDS_FALLBACK;
    paths[2] = NULL;
    for (i = 0; paths[i]; i++) {
        in = fopen(paths[i], "rb");
        if (in) break;
    }
    if (!in || fseek(in, 0, SEEK_END) != 0 || (length = ftell(in)) <= 0 ||
        length >= (long)sizeof(g_rmx5200_adfr_commands) ||
        fseek(in, 0, SEEK_SET) != 0 ||
        fread(g_rmx5200_adfr_commands, 1, (size_t)length, in) !=
            (size_t)length) {
        if (in) fclose(in);
        printf("ERROR: RMX5200 ADFR command payload is missing or unreadable.\n");
        return 0;
    }
    fclose(in);
    g_rmx5200_adfr_commands[length] = '\0';
    g_rmx5200_adfr_commands_length = (size_t)length;
    if (!validate_rmx5200_adfr_commands(g_rmx5200_adfr_commands)) {
        printf("ERROR: RMX5200 ADFR command payload is incomplete or malformed.\n");
        return 0;
    }
    sha256_hex(g_rmx5200_adfr_commands, g_rmx5200_adfr_commands_length,
               payload_hash);
    if (strcmp(payload_hash, RMX5200_ADFR_COMMANDS_SHA256)) {
        printf("ERROR: RMX5200 ADFR command payload hash mismatch: %s.\n",
               payload_hash);
        return 0;
    }
    printf("Verified RMX5200 WQHD ADFR command payload: 18 command sets, "
           "sha256=%s.\n", payload_hash);
    return 1;
}

static int parse_manifest_rates(const char *text, unsigned int *rates,
                                size_t capacity, size_t *count_out) {
    char buffer[256];
    char *item;
    size_t count = 0;

    if (!text || !rates || !count_out || strlen(text) >= sizeof(buffer)) {
        return 0;
    }
    strcpy(buffer, text);
    item = buffer;
    while (item && *item) {
        char *comma = strchr(item, ',');
        char *end = NULL;
        unsigned long value;
        if (comma) *comma = '\0';
        value = strtoul(item, &end, 10);
        if (end == item || *end != '\0' || value < 20 || value > 300 ||
            count >= capacity) {
            return 0;
        }
        rates[count++] = (unsigned int)value;
        item = comma ? comma + 1 : NULL;
    }
    *count_out = count;
    return 1;
}

static int load_display_mode_manifest(void) {
    const char *env_path = getenv("MURONGCHAOPIN_MODE_MANIFEST");
    const char *paths[3];
    FILE *in = NULL;
    char line[512];
    char value[256];
    int i;
    int version = 0;
    int seen_rmx = 0;
    int seen_plk = 0;

    memset(&g_display_mode_manifest, 0, sizeof(g_display_mode_manifest));
    paths[0] = env_path && *env_path ? env_path : DISPLAY_MODE_MANIFEST_DEFAULT;
    paths[1] = env_path && *env_path ? NULL : DISPLAY_MODE_MANIFEST_FALLBACK;
    paths[2] = NULL;
    for (i = 0; paths[i]; i++) {
        in = fopen(paths[i], "r");
        if (in) break;
    }
    if (!in) {
        printf("ERROR: display mode manifest is missing (set MURONGCHAOPIN_MODE_MANIFEST or install config/display_mode_manifest.txt).\n");
        return 0;
    }
    while (fgets(line, sizeof(line), in)) {
        char *p = line;
        int rc;
        while (*p == ' ' || *p == '\t') p++;
        if (!*p || *p == '#') continue;
        rc = profile_copy_value(value, sizeof(value), "manifest_version", p);
        if (rc < 0) goto malformed;
        if (rc > 0) {
            char *end = NULL;
            unsigned long parsed = strtoul(value, &end, 10);
            if (end == value || *end != '\0' || parsed != 1) goto malformed;
            version = 1;
            continue;
        }
        rc = profile_copy_value(value, sizeof(value), "rmx5200_dtbo_rates", p);
        if (rc < 0 || (rc > 0 && (!parse_manifest_rates(
                value, g_display_mode_manifest.rmx5200_dtbo_rates,
                sizeof(g_display_mode_manifest.rmx5200_dtbo_rates) /
                    sizeof(g_display_mode_manifest.rmx5200_dtbo_rates[0]),
                &g_display_mode_manifest.rmx5200_dtbo_count)))) goto malformed;
        if (rc > 0) { seen_rmx = 1; continue; }
        rc = profile_copy_value(value, sizeof(value), "plk110_dtbo_rates", p);
        if (rc < 0 || (rc > 0 && (!parse_manifest_rates(
                value, g_display_mode_manifest.plk110_dtbo_rates,
                sizeof(g_display_mode_manifest.plk110_dtbo_rates) /
                    sizeof(g_display_mode_manifest.plk110_dtbo_rates[0]),
                &g_display_mode_manifest.plk110_dtbo_count)))) goto malformed;
        if (rc > 0) { seen_plk = 1; continue; }
    }
    fclose(in);
    if (version != 1 || !seen_rmx || !seen_plk ||
        g_display_mode_manifest.rmx5200_dtbo_count != 8 ||
        g_display_mode_manifest.plk110_dtbo_count != 8) {
        printf("ERROR: display mode manifest is incomplete; RMX5200/PLK110 DTBO entries must contain 8 rates.\n");
        return 0;
    }
    printf("Verified display mode manifest: RMX5200=%zu rates, PLK110=%zu rates.\n",
           g_display_mode_manifest.rmx5200_dtbo_count,
           g_display_mode_manifest.plk110_dtbo_count);
    return 1;

malformed:
    if (in) fclose(in);
    printf("ERROR: display mode manifest is malformed or contains invalid rates.\n");
    return 0;
}

void detect_device_model() {
#ifdef PROCESS_DTS_TEST_MODEL
    g_current_model = PROCESS_DTS_TEST_MODEL;
#ifdef PROCESS_DTS_TEST_PROJECT_ID
    g_target_project_id = PROCESS_DTS_TEST_PROJECT_ID;
#else
    g_target_project_id = 1;
#endif
    g_has_project_id = 1;
    printf("TEST BUILD: forced model id %d, project id 0x%llx\n",
           g_current_model, g_target_project_id);
    return;
#else
    char model[PROP_VALUE_MAX] = {0};

    __system_property_get("ro.product.vendor.model", model);

    printf("Detected Device Model: %s\n", model);
    
    if (strstr(model, "RMX5200")) {
        g_current_model = MODEL_RMX5200;
        printf("Identified as Realme GT8 Pro (RMX5200)\n");
    } else if (strstr(model, "PLK110")) {
        g_current_model = MODEL_PLK110;
        printf("Identified as OnePlus 15 (PLK110)\n");
    } else if (strstr(model, "PJD110")) {
        g_current_model = MODEL_PJD110;
        printf("Identified as OnePlus 12 (PJD110)\n");
    } else {
        g_current_model = MODEL_UNKNOWN;
        printf("Error: Unknown Model (%s) - Aborting to prevent potential damage.\n", model);
        exit(1);
    }

    // Get Project ID
    char prj_prop[PROP_VALUE_MAX] = {0};
    __system_property_get("ro.boot.prjname", prj_prop);
    
    if (strlen(prj_prop) > 0) {
        // Auto-detect base (0x for hex, others for decimal)
        g_target_project_id = strtoull(prj_prop, NULL, 0);
        g_has_project_id = 1;
        printf("Target Project ID: 0x%llx (from %s)\n", g_target_project_id, prj_prop);
    } else {
        printf("CRITICAL ERROR: Failed to get Project ID from ro.boot.prjname.\n");
        printf("This check is mandatory to prevent flashing wrong files.\n");
        exit(1);
    }
#endif
}


#define MAX_LINE 4096
#define MAX_BLOCK 131072 // 128KB buffer for blocks
#define DIR_NAME "dtbo_dts"
#define MAX_RMX5200_PANEL_COPIES 8
#define MAX_RMX5200_EXTENSION_NODES 64

// Structure to hold timing node info
typedef struct {
    char name[128];
    char content[MAX_BLOCK];
    unsigned long long clock;
    unsigned int fps;
    unsigned int transfer_time;
    unsigned int cell_index;
    int valid;
} TimingNode;

typedef struct {
    char name[128];
    char *content;
    int emitted;
} Rmx5200ExtensionNode;

typedef struct {
    const char *panel_start;
    size_t count;
    Rmx5200ExtensionNode nodes[MAX_RMX5200_EXTENSION_NODES];
} Rmx5200PanelExtensions;

unsigned long long get_prop_u64(const char *content, const char *prop_name);

static int is_rmx5200_stock_timing(const char *name) {
    static const char *stock_names[] = {
        "timing@wqhd_sdc_120", "timing@wqhd_sdc_90",
        "timing@wqhd_sdc_60", "timing@wqhd_sdc_144",
        "timing@fhd_sdc_120", "timing@fhd_sdc_90",
        "timing@fhd_sdc_60", "timing@fhd_sdc_144"
    };
    size_t i;

    for (i = 0; i < sizeof(stock_names) / sizeof(stock_names[0]); i++) {
        if (strcmp(name, stock_names[i]) == 0) return 1;
    }
    return 0;
}

static int is_rmx5200_stock_fhd_timing(const char *name) {
    return strcmp(name, "timing@fhd_sdc_120") == 0 ||
           strcmp(name, "timing@fhd_sdc_90") == 0 ||
           strcmp(name, "timing@fhd_sdc_60") == 0 ||
           strcmp(name, "timing@fhd_sdc_144") == 0;
}

static int is_rmx5200_stock_wqhd_timing(const char *name) {
    return strcmp(name, "timing@wqhd_sdc_120") == 0 ||
           strcmp(name, "timing@wqhd_sdc_90") == 0 ||
           strcmp(name, "timing@wqhd_sdc_60") == 0 ||
           strcmp(name, "timing@wqhd_sdc_144") == 0;
}

static Rmx5200PanelExtensions *rmx5200_panel_extensions(
        Rmx5200PanelExtensions *panels, size_t *panel_count,
        const char *panel_start, int create) {
    size_t i;

    for (i = 0; i < *panel_count; i++) {
        if (panels[i].panel_start == panel_start) return &panels[i];
    }
    if (!create || *panel_count >= MAX_RMX5200_PANEL_COPIES) return NULL;
    panels[*panel_count].panel_start = panel_start;
    panels[*panel_count].count = 0;
    return &panels[(*panel_count)++];
}

static int is_rmx5200_manifest_extension(const char *name) {
    size_t i;

    for (i = 0; i < g_display_mode_manifest.rmx5200_dtbo_count; i++) {
        char expected[128];

        snprintf(expected, sizeof(expected), "timing@wqhd_sdc_%u",
                 g_display_mode_manifest.rmx5200_dtbo_rates[i]);
        if (strcmp(name, expected) == 0) return 1;
    }
    return 0;
}

static int rmx5200_same_timing(const char *left, const char *right) {
    unsigned long long left_rate = get_prop_u64(
        left, "qcom,mdss-dsi-panel-framerate");
    unsigned long long right_rate = get_prop_u64(
        right, "qcom,mdss-dsi-panel-framerate");
    unsigned long long left_width;
    unsigned long long right_width;
    unsigned long long left_height;
    unsigned long long right_height;

    if (left_rate == 0 || left_rate != right_rate) return 0;

    left_width = get_prop_u64(left, "qcom,mdss-dsi-panel-width");
    right_width = get_prop_u64(right, "qcom,mdss-dsi-panel-width");
    left_height = get_prop_u64(left, "qcom,mdss-dsi-panel-height");
    right_height = get_prop_u64(right, "qcom,mdss-dsi-panel-height");

    /* Old generated tables and the compact regression fixture can omit the
     * explicit size. RMX5200 extensions are WQHD-only, so rate is the stable
     * fallback key until process_dts writes the canonical block again. */
    if (left_width == 0 || right_width == 0 ||
        left_height == 0 || right_height == 0) {
        return 1;
    }
    return left_width == right_width && left_height == right_height;
}

static int rmx5200_assign_extension(Rmx5200ExtensionNode *node,
                                    const char *name,
                                    const char *content, size_t length) {
    char *copy;

    if (length >= MAX_BLOCK) return 0;
    copy = malloc(length + 1);
    if (!copy) return 0;
    memcpy(copy, content, length);
    copy[length] = '\0';
    free(node->content);
    snprintf(node->name, sizeof(node->name), "%s", name);
    node->content = copy;
    node->emitted = 0;
    return 1;
}

static int rmx5200_store_extension(Rmx5200PanelExtensions *panel,
                                   const char *name,
                                   const char *content, size_t length) {
    Rmx5200ExtensionNode *node;
    size_t i;

    if (!panel || !name || !content || length >= MAX_BLOCK ||
        panel->count >= MAX_RMX5200_EXTENSION_NODES) {
        return 0;
    }

    for (i = 0; i < panel->count; i++) {
        Rmx5200ExtensionNode *existing = &panel->nodes[i];

        if (strcmp(existing->name, name) == 0) {
            printf("Deduplicating repeated RMX5200 extension %s.\n", name);
            return 1;
        }
        if (!rmx5200_same_timing(existing->content, content)) continue;

        if (is_rmx5200_manifest_extension(name) &&
            !is_rmx5200_manifest_extension(existing->name)) {
            printf("Replacing duplicate RMX5200 extension %s with canonical %s.\n",
                   existing->name, name);
            return rmx5200_assign_extension(existing, name, content, length);
        }
        printf("Deduplicating RMX5200 timing %s against %s by width/height/rate.\n",
               name, existing->name);
        return 1;
    }

    node = &panel->nodes[panel->count];
    if (!rmx5200_assign_extension(node, name, content, length)) return 0;
    panel->count++;
    return 1;
}

static Rmx5200ExtensionNode *rmx5200_find_extension(
        Rmx5200PanelExtensions *panel, const char *name) {
    size_t i;

    if (!panel) return NULL;
    for (i = 0; i < panel->count; i++) {
        if (!panel->nodes[i].emitted && strcmp(panel->nodes[i].name, name) == 0) {
            return &panel->nodes[i];
        }
    }
    return NULL;
}

static void rmx5200_free_extensions(Rmx5200PanelExtensions *panels,
                                    size_t panel_count) {
    size_t i;
    size_t j;

    for (i = 0; i < panel_count; i++) {
        for (j = 0; j < panels[i].count; j++) {
            free(panels[i].nodes[j].content);
            panels[i].nodes[j].content = NULL;
        }
    }
}

// Check if regular file
int is_regular_file(const char *path) {
    struct stat path_stat;
    stat(path, &path_stat);
    return S_ISREG(path_stat.st_mode);
}

// Robust property finder
// Finds "prop_name =" or "prop_name=" handling whitespace
// Returns pointer to the start of prop_name
char *find_prop(const char *content, const char *prop_name) {
    const char *p = content;
    size_t name_len = strlen(prop_name);
    
    while ((p = strstr(p, prop_name))) {
        // Check start boundary (ensure not a suffix)
        if (p > content) {
            char prev = *(p - 1);
            if (isalnum(prev) || prev == '-' || prev == '_') {
                p += name_len;
                continue;
            }
        }
        
        // Check end boundary and look for '='
        const char *curr = p + name_len;
        while (isspace(*curr)) curr++;
        
        if (*curr == '=') {
            return (char*)p;
        }
        
        p += name_len;
    }
    return NULL;
}

// Simple string replacement (first occurrence)
void replace_str(char *str, const char *orig, const char *rep) {
    char buffer[MAX_BLOCK];
    char *p;

    if (!(p = strstr(str, orig)))
        return;

    strncpy(buffer, str, p - str);
    buffer[p - str] = '\0';

    sprintf(buffer + (p - str), "%s%s", rep, p + strlen(orig));
    strcpy(str, buffer);
}

// Extract hex/int property value (e.g., <0x123> or <123>)
unsigned long long get_prop_u64(const char *content, const char *prop_name) {
    char *p = find_prop(content, prop_name);
    if (!p) return 0;
    
    // Safety: Ensure we find < before ; or }
    char *end_stmt = strpbrk(p, ";}");
    char *start = strchr(p, '<');
    
    if (!start) return 0;
    if (end_stmt && start > end_stmt) return 0; // Found < but it's in next property
    
    start++; // skip <
    
    unsigned long long val = 0;
    // Handle hex and decimal
    while(isspace(*start)) start++;
    
    if (strstr(start, "0x") == start || strstr(start, "0X") == start) {
        sscanf(start, "%llx", &val);
    } else {
        sscanf(start, "%lld", &val);
    }
    return val;
}

// Update existing property value (u64/u32)
int update_prop_u64(char *content, const char *prop_name, unsigned long long new_val) {
    char *p = find_prop(content, prop_name);
    if (!p) {
        // printf("Warning: Property '%s' not found for update.\n", prop_name);
        return 0;
    }
    
    // Safety: Find ;
    char *end_stmt = strchr(p, ';');
    if (!end_stmt) return 0;
    
    char *start = strchr(p, '<'); // Find <
    char *end = strchr(p, '>');   // Find >
    
    // Bounds check
    if (!start || !end) return 0;
    if (start > end_stmt || end > end_stmt) return 0;
    
    // Construct new value string
    char new_str[64];
    sprintf(new_str, "<0x%llx>", new_val);
    int new_len = strlen(new_str);
    int old_len = end - start + 1;
    
    int shift = new_len - old_len;
    
    // If we need to shift memory
    if (shift != 0) {
        // Check buffer bounds (risky without knowing max size, but typically we operate on local large buffers)
        // Move the rest of the string including null terminator
        memmove(end + 1 + shift, end + 1, strlen(end + 1) + 1);
    }
    
    memcpy(start, new_str, new_len);
    return 1;
}

void update_prop_hex_or_str(char *content, const char *prop_name, unsigned long long new_val) {
    char *p = find_prop(content, prop_name);
    if (!p) return;

    // Safety: Find ;
    char *end_stmt = strchr(p, ';');
    if (!end_stmt) return;

    char *angle = strchr(p, '<');
    char *quote = strchr(p, '"');
    
    // Must be before ;
    if (angle && angle > end_stmt) angle = NULL;
    if (quote && quote > end_stmt) quote = NULL;
    
    if (angle) {
        update_prop_u64(content, prop_name, new_val);
        return;
    }
    if (!quote) return;

    char *endq = strchr(quote + 1, '"');
    if (!endq || endq > end_stmt) return;

    char new_str[64];
    sprintf(new_str, "0x%llx", new_val);
    int new_len = (int)strlen(new_str);
    int old_len = endq - (quote + 1);
    int shift = new_len - old_len;
    if (shift != 0) {
        memmove(endq + shift, endq, strlen(endq) + 1);
    }
    memcpy(quote + 1, new_str, new_len);
}

// Replaces the entire line containing prop_name with "prop_name = <0xHEX>;"
int replace_prop_line_u64(char *content, const char *prop_name, unsigned long long new_val) {
    char *p = find_prop(content, prop_name);
    if (!p) return 0;
    
    // Find line start (previous \n or start of string)
    char *line_start = p;
    while (line_start > content && *(line_start - 1) != '\n') {
        line_start--;
    }
    
    // Find line end (after ;)
    char *line_end = strchr(p, ';');
    if (!line_end) return 0;
    line_end++; // Include ;
    
    // Capture indentation
    char indent[64] = {0};
    int i = 0;
    char *k = line_start;
    while (k < p && isspace(*k) && i < 63) {
        indent[i++] = *k;
        k++;
    }
    indent[i] = 0;
    
    // Construct new line
    char new_line[256];
    sprintf(new_line, "%s%s = <0x%llx>;", indent, prop_name, new_val);
    
    int old_len = line_end - line_start;
    int new_len = strlen(new_line);
    
    int shift = new_len - old_len;
    if (shift != 0) {
        memmove(line_end + shift, line_end, strlen(line_end) + 1);
    }
    
    memcpy(line_start, new_line, new_len);
    return 1;
}

// Replaces ALL lines containing prop_name with "prop_name = <0xHEX>;"
int replace_all_prop_u64(char *content, const char *prop_name, unsigned long long new_val) {
    char *p = content;
    int count = 0;
    while ((p = find_prop(p, prop_name))) {
        // Find line start
        char *line_start = p;
        while (line_start > content && *(line_start - 1) != '\n') {
            line_start--;
        }
        
        // Find line end
        char *line_end = strchr(p, ';');
        if (!line_end) break;
        line_end++; // Include ;
        
        // Check indentation
        char indent[64] = {0};
        int i = 0;
        char *k = line_start;
        while (k < p && isspace(*k) && i < 63) {
            indent[i++] = *k;
            k++;
        }
        indent[i] = 0;
        
        // Construct new line
        char new_line[256];
        sprintf(new_line, "%s%s = <0x%llx>;", indent, prop_name, new_val);
        
        int old_len = line_end - line_start;
        int new_len = strlen(new_line);
        int shift = new_len - old_len;
        
        if (shift != 0) {
            memmove(line_end + shift, line_end, strlen(line_end) + 1);
        }
        memcpy(line_start, new_line, new_len);
        
        count++;
        // Advance pointer to avoid infinite loop on same line
        p = line_start + new_len;
    }
    if (count > 0) printf("Replaced %d occurrences of %s with 0x%llx\n", count, prop_name, new_val);
    return count;
}

// Get raw property string value (e.g. "<0x123>" or "\"B`0\"")
// Returns 1 if found, 0 otherwise
int get_prop_val_str(const char *content, const char *prop_name, char *out_val) {
    char *p = find_prop(content, prop_name);
    if (!p) return 0;
    
    char *end_stmt = strchr(p, ';');
    if (!end_stmt) return 0;
    
    char *val_start = strchr(p, '=');
    if (!val_start) return 0;
    val_start++; // skip =
    
    // Trim leading whitespace
    while (val_start < end_stmt && isspace(*val_start)) val_start++;
    if (val_start >= end_stmt) return 0;
    
    int len = end_stmt - val_start;
    if (len >= 63) len = 63;
    
    strncpy(out_val, val_start, len);
    out_val[len] = 0;
    return 1;
}

// Update property with raw string
int update_prop_val_str(char *content, const char *prop_name, const char *new_val) {
    char *p = find_prop(content, prop_name);
    if (!p) return 0;
    
    char *end_stmt = strchr(p, ';');
    if (!end_stmt) return 0;
    
    char *val_start = strchr(p, '=');
    if (!val_start) return 0;
    val_start++; // skip =
    
    while (val_start < end_stmt && isspace(*val_start)) val_start++;
    
    int old_len = end_stmt - val_start;
    int new_len = strlen(new_val);
    
    int shift = new_len - old_len;
    if (shift != 0) {
        memmove(end_stmt + shift, end_stmt, strlen(end_stmt) + 1);
    }
    memcpy(val_start, new_val, new_len);
    return 1;
}

/* Reproduce the historical RMX5200 LTPO workaround as an explicit A/B
 * transform. The 144Hz node is the source of the panel's high-refresh timing
 * envelope; only the node name, refresh value and original 60Hz cell-index are
 * changed. Do not recalculate clock/transfer here: the later stable fix kept
 * the 144Hz clock/transfer envelope intact. */
static int rmx5200_copy_wqhd_144_to_60(char *target, size_t target_capacity,
                                       const TimingNode *template,
                                       const char *original_cell_index) {
    char old_name[128];
    char old_header[160];
    char replacement[MAX_BLOCK];
    int written;

    if (!target || !template || !template->valid ||
        !template->content[0] || target_capacity < sizeof(replacement)) {
        return 0;
    }
    written = snprintf(replacement, sizeof(replacement), "%s",
                       template->content);
    if (written < 0 || (size_t)written >= sizeof(replacement)) return 0;
    if (sscanf(template->content, "%127s", old_name) != 1) return 0;
    {
        char *brace = strchr(old_name, '{');
        if (brace) *brace = '\0';
    }
    written = snprintf(old_header, sizeof(old_header), "%s {", old_name);
    if (written < 0 || (size_t)written >= sizeof(old_header)) return 0;
    replace_str(replacement, old_header, "timing@wqhd_sdc_60 {");
    if (original_cell_index && original_cell_index[0] &&
        !update_prop_val_str(replacement, "cell-index",
                             original_cell_index)) {
        return 0;
    }
    if (!update_prop_u64(replacement, "qcom,mdss-dsi-panel-framerate", 60)) {
        return 0;
    }
    if (strlen(replacement) + 1 > target_capacity) return 0;
    memcpy(target, replacement, strlen(replacement) + 1);
    return 1;
}

static char *find_exact_node_open(char *buffer, const char *node_name,
                                  char **node_start) {
    size_t name_len = strlen(node_name);
    char *candidate = buffer;

    while ((candidate = strstr(candidate, node_name))) {
        char *after = candidate + name_len;
        char before = candidate == buffer ? '\0' : candidate[-1];

        if (isalnum((unsigned char)before) || before == '_' || before == '-') {
            candidate += name_len;
            continue;
        }
        while (*after && isspace((unsigned char)*after)) after++;
        if (*after == '{') {
            if (node_start) *node_start = candidate;
            return after;
        }
        candidate += name_len;
    }
    return NULL;
}

static char *find_matching_node_close(char *open) {
    int depth = 0;
    int in_string = 0;
    int escaped = 0;

    for (char *p = open; *p; p++) {
        if (in_string) {
            if (escaped) {
                escaped = 0;
            } else if (*p == '\\') {
                escaped = 1;
            } else if (*p == '"') {
                in_string = 0;
            }
            continue;
        }
        if (*p == '"') {
            in_string = 1;
        } else if (*p == '{') {
            depth++;
        } else if (*p == '}' && --depth == 0) {
            return p;
        }
    }
    return NULL;
}

static int replace_buffer_range(char **buffer_ptr, size_t begin, size_t end,
                                const char *replacement) {
    char *buffer = *buffer_ptr;
    size_t old_len = strlen(buffer);
    size_t replacement_len = strlen(replacement);
    size_t removed_len;
    char *resized;

    if (begin > end || end > old_len) return 0;
    removed_len = end - begin;
    resized = realloc(buffer, old_len - removed_len + replacement_len + 1);
    if (!resized) return 0;
    memmove(resized + begin + replacement_len, resized + end,
            old_len - end + 1);
    memcpy(resized + begin, replacement, replacement_len);
    *buffer_ptr = resized;
    return 1;
}

static int enable_rmx5200_adfr_config(char **buffer_ptr,
                                      const char *config_value) {
    static const char panel_name[] =
        "qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02";
    static const char property[] = "oplus,adfr-config";
    char *buffer = *buffer_ptr;
    char *node_start = NULL;
    char *open = NULL;
    char *close = NULL;
    char *existing;
    char *search = buffer;

    while ((open = find_exact_node_open(search, panel_name, &node_start))) {
        char *panel_name_prop;
        char *timings_prop;

        close = find_matching_node_close(open);
        if (!close) return 0;
        panel_name_prop = find_prop(open + 1, "qcom,mdss-dsi-panel-name");
        timings_prop = strstr(open + 1, "qcom,mdss-dsi-display-timings");
        if (panel_name_prop && panel_name_prop < close &&
            timings_prop && timings_prop < close) {
            break;
        }
        search = open + 1;
        open = NULL;
        close = NULL;
    }

    if (!open || !close) return 0;

    existing = find_prop(open + 1, property);
    if (existing && existing < close) {
        char *equals = strchr(existing, '=');
        char *semicolon = strchr(existing, ';');
        char *value_start;

        if (!equals || !semicolon || semicolon > close) return 0;
        value_start = equals + 1;
        while (value_start < semicolon &&
               isspace((unsigned char)*value_start)) value_start++;
        return replace_buffer_range(buffer_ptr,
            (size_t)(value_start - buffer), (size_t)(semicolon - buffer),
            config_value);
    }

    {
        char *line_start = node_start;
        char indent[96] = {0};
        char fragment[192];
        size_t indent_len = 0;
        int written;

        while (line_start > buffer && line_start[-1] != '\n') line_start--;
        while (line_start[indent_len] == ' ' ||
               line_start[indent_len] == '\t') {
            if (indent_len + 1 >= sizeof(indent)) return 0;
            indent[indent_len] = line_start[indent_len];
            indent_len++;
        }
        written = snprintf(fragment, sizeof(fragment),
            "\n%s\toplus,adfr-config = %s;", indent, config_value);
        if (written < 0 || written >= (int)sizeof(fragment)) return 0;
        return replace_buffer_range(buffer_ptr,
            (size_t)(open + 1 - buffer), (size_t)(open + 1 - buffer),
            fragment);
    }
}

/* Bit 0 advertises ADFR; bit 8 makes the OPLUS command path skip the physical
 * DSI transaction. Keep this parser-only mode for A/B comparison. */
static int enable_rmx5200_adfr_dry_run(char **buffer_ptr) {
    return enable_rmx5200_adfr_config(buffer_ptr, "<0x101>");
}

/* The LTPO experiment keeps bit 0 but clears the dry-run guard so the command
 * sets attached to the WQHD timing can reach the panel driver. */
static int enable_rmx5200_adfr_ltpo(char **buffer_ptr) {
    return enable_rmx5200_adfr_config(buffer_ptr, "<0x1>");
}

static int inject_rmx5200_adfr_dry_run_mapping(char *target,
                                                size_t target_capacity,
                                                const char *node_indent) {
    char fragment[384];
    char property_indent[96];
    char mapping[128];
    char *existing;
    char *closing;
    size_t target_len;
    size_t fragment_len = 0;
    unsigned int refresh;
    int written;

    if (!target || !node_indent) return 0;
    refresh = (unsigned int)get_prop_u64(target,
        "qcom,mdss-dsi-panel-framerate");
    if (!refresh) return 0;

    if (refresh <= 60) {
        written = snprintf(mapping, sizeof(mapping), "%s",
                           g_rmx5200_adfr_profile.mapping_low);
    } else {
        written = snprintf(mapping, sizeof(mapping), "%u %s", refresh,
                           g_rmx5200_adfr_profile.mapping_high_suffix);
    }
    if (written < 0 || written >= (int)sizeof(mapping)) return 0;

    /* Generated 123Hz inherits the 120Hz template, so rewrite an existing
     * mapping instead of treating it as already complete. */
    existing = find_prop(target, "oplus,adfr-min-fps-mapping-table");
    if (existing) {
        char *value_start = strchr(existing, '<');
        char *value_end = value_start ? strchr(value_start, '>') : NULL;
        char *semicolon = strchr(existing, ';');
        size_t old_len;
        size_t new_len = strlen(mapping);

        if (!value_start || !value_end || !semicolon || value_end > semicolon)
            return 0;
        value_start++;
        old_len = (size_t)(value_end - value_start);
        target_len = strlen(target);
        if (new_len > old_len &&
            target_len + (new_len - old_len) + 1 > target_capacity) {
            return 0;
        }
        memmove(value_start + new_len, value_end,
                strlen(value_end) + 1);
        memcpy(value_start, mapping, new_len);
    }

    if (snprintf(property_indent, sizeof(property_indent), "%s\t",
                 node_indent) >= (int)sizeof(property_indent)) return 0;

    fragment[0] = '\0';
    if (!find_prop(target, "qcom,mdss-dsi-h-sync-skew")) {
        written = snprintf(fragment, sizeof(fragment),
            "\n%sqcom,mdss-dsi-h-sync-skew = <0>;", property_indent);
        if (written < 0 || written >= (int)sizeof(fragment)) return 0;
        fragment_len = (size_t)written;
    }
    if (!existing) {
        written = snprintf(fragment + fragment_len,
            sizeof(fragment) - fragment_len,
            "\n%soplus,adfr-min-fps-mapping-table = <%s>;",
            property_indent, mapping);
        if (written < 0 || (size_t)written >= sizeof(fragment) - fragment_len)
            return 0;
        fragment_len += (size_t)written;
    }
    if (!fragment_len) return 1;
    written = snprintf(fragment + fragment_len,
        sizeof(fragment) - fragment_len, "\n%s", node_indent);
    if (written < 0 || (size_t)written >= sizeof(fragment) - fragment_len)
        return 0;
    fragment_len += (size_t)written;

    target_len = strlen(target);
    closing = strrchr(target, '}');
    if (!closing || target_len + fragment_len + 1 > target_capacity)
        return 0;
    memmove(closing + fragment_len, closing,
            target_len - (size_t)(closing - target) + 1);
    memcpy(closing, fragment, fragment_len);
    return 1;
}

static int rmx5200_adfr_command_property_count(const char *target) {
    static const char *families[] = {
        "qcom,mdss-dsi-bigdc-adfr-min-fps-",
        "qcom,mdss-dsi-hpwm-adfr-min-fps-",
        "qcom,mdss-dsi-adfr-min-fps-"
    };
    char property[160];
    size_t family;
    int count = 0;
    int index;

    for (family = 0; family < sizeof(families) / sizeof(families[0]); family++) {
        for (index = 0; index < 6; index++) {
            snprintf(property, sizeof(property), "%s%d-command-state",
                     families[family], index);
            if (count_text_occurrences(target, property) == 1) count++;
            snprintf(property, sizeof(property), "%s%d-command =",
                     families[family], index);
            if (count_text_occurrences(target, property) == 1) count++;
        }
    }
    return count;
}

static int inject_rmx5200_adfr_ltpo_properties(char *target,
                                                size_t target_capacity,
                                                const char *node_indent) {
    char *closing;
    size_t insertion_len;
    size_t target_len;
    size_t indent_len;
    int present;

    if (!target || !node_indent || !g_rmx5200_adfr_commands_length ||
        !strstr(target, "timing@wqhd_sdc_")) {
        return 0;
    }
    if (!inject_rmx5200_adfr_dry_run_mapping(target, target_capacity,
                                              node_indent)) {
        return 0;
    }

    present = rmx5200_adfr_command_property_count(target);
    if (present == 36) return 1;
    if (present != 0) return 0;

    target_len = strlen(target);
    indent_len = strlen(node_indent);
    insertion_len = 1 + g_rmx5200_adfr_commands_length +
        (g_rmx5200_adfr_commands[g_rmx5200_adfr_commands_length - 1] == '\n'
            ? 0 : 1) + indent_len;
    closing = strrchr(target, '}');
    if (!closing || target_len + insertion_len + 1 > target_capacity) {
        return 0;
    }
    memmove(closing + insertion_len,
            closing, target_len - (size_t)(closing - target) + 1);
    *closing++ = '\n';
    memcpy(closing, g_rmx5200_adfr_commands,
           g_rmx5200_adfr_commands_length);
    closing += g_rmx5200_adfr_commands_length;
    if (closing[-1] != '\n') *closing++ = '\n';
    memcpy(closing, node_indent, indent_len);
    return 1;
}

/*
 * The PLK110 165Hz timing is a normal fixed-rate node in the stock DTBO and
 * therefore has no ADFR command sets.  The vendor's 60Hz timing is the only
 * local, panel-matched ADFR template we have.  Copy just its ADFR properties
 * into generated 170-199Hz nodes; never borrow commands from another panel.
 * This keeps the mapping and all three DDIC command families in sync.
 */
static int inject_plk110_adfr_properties(char *target, size_t target_capacity,
                                         const char *template,
                                         const char *node_indent) {
    const char *line;
    char fragment[16384] = {0};
    size_t fragment_len = 0;
    char property_indent[96];
    char *closing;
    size_t target_len;
    int selected = 0;

    if (!target || !template || !node_indent ||
        strstr(target, "oplus,adfr-min-fps-mapping-table")) {
        return 0;
    }

    if (snprintf(property_indent, sizeof(property_indent), "%s\t",
                 node_indent) >= (int)sizeof(property_indent)) {
        return 0;
    }

    line = template;
    while (*line) {
        const char *end = strchr(line, '\n');
        size_t line_len = end ? (size_t)(end - line) : strlen(line);
        const char *content = line;
        size_t content_len = line_len;
        char normalized[4096];
        int written;

        while (content_len && (*content == ' ' || *content == '\t')) {
            content++;
            content_len--;
        }
        while (content_len && (content[content_len - 1] == '\r' ||
                               content[content_len - 1] == ' ' ||
                               content[content_len - 1] == '\t')) {
            content_len--;
        }
        if (content_len && strstr(content, "adfr") &&
            content[content_len - 1] == ';') {
            if (content_len >= sizeof(normalized)) {
                return 0;
            }
            memcpy(normalized, content, content_len);
            normalized[content_len] = '\0';
            written = snprintf(fragment + fragment_len,
                               sizeof(fragment) - fragment_len,
                               "\n%s%s", property_indent, normalized);
            if (written < 0 || (size_t)written >= sizeof(fragment) - fragment_len) {
                return 0;
            }
            fragment_len += (size_t)written;
            selected++;
        }
        line = end ? end + 1 : line + line_len;
    }

    if (!selected) {
        return 0;
    }
    {
        int written = snprintf(fragment + fragment_len,
                               sizeof(fragment) - fragment_len,
                               "\n%s", node_indent);
        if (written < 0 ||
            (size_t)written >= sizeof(fragment) - fragment_len) {
            return 0;
        }
        fragment_len += (size_t)written;
    }
    target_len = strlen(target);
    closing = strrchr(target, '}');
    if (!closing || closing < target || (size_t)(closing - target) > target_len ||
        target_len + fragment_len + 1 > target_capacity) {
        return 0;
    }
    memmove(closing + fragment_len, closing,
            target_len - (size_t)(closing - target) + 1);
    memcpy(closing, fragment, fragment_len);
    return selected;
}

#define PANEL_GT8_PRO "qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02"
#define PANEL_ONEPLUS_15 "qcom,mdss_dsi_panel_AD296_P_3_A0020_dsc_cmd"
#define PANEL_ONEPLUS_12 "qcom,mdss_dsi_panel_AA545_P_3_A0005_dsc_cmd"

// Check if current position is inside a target panel node and return ID
// 0: None, 1: GT8 Pro, 2: OnePlus 15, 3: OnePlus 12
// Optional: out_panel_start returns the position of the panel's opening brace
int get_panel_id(const char *file_start, const char *current_pos, const char **out_panel_start) {
    // Search backwards for the last opened brace that hasn't been closed
    const char *p = current_pos;
    while (p > file_start) {
        if (*p == '{') {
            // Check the name preceding this brace
            const char *name_end = p;
            while (name_end > file_start && isspace(*(name_end - 1))) name_end--;
            
            const char *name_start = name_end;
            while (name_start > file_start && !isspace(*(name_start - 1)) && *(name_start - 1) != ';' && *(name_start - 1) != '}') {
                name_start--;
            }
            
            if (name_end > name_start) {
                char node_name[256];
                int len = name_end - name_start;
                if (len > 255) len = 255;
                strncpy(node_name, name_start, len);
                node_name[len] = 0;
                
                // Debug print for PJD110 relevant nodes
                if (g_current_model == MODEL_PJD110 && strstr(node_name, "panel")) {
                     // printf("Debug: Checking parent node: %s\n", node_name);
                }
                
                // Return start position if requested
                if (out_panel_start) *out_panel_start = p;

                // Explicitly ignore engineering panels (evt)
                if (strstr(node_name, "_evt")) {
                    return 0; 
                }

                // GT8 Pro Detection
                if (strcmp(node_name, PANEL_GT8_PRO) == 0) {
                    if (g_current_model == MODEL_RMX5200) {
                        return 1;
                    }
                    return 0;
                }
                
                // OnePlus 15 Detection
                if (strcmp(node_name, PANEL_ONEPLUS_15) == 0) {
                     if (g_current_model == MODEL_PLK110) {
                         return 2;
                     }
                     return 0;
                }

                // OnePlus 12 Detection
                if (strcmp(node_name, PANEL_ONEPLUS_12) == 0) {
                     if (g_current_model == MODEL_PJD110) {
                         printf("Match Found: OnePlus 12 Panel (%s)\n", node_name);
                         return 3;
                     }
                     return 0;
                }
                
                // Heuristic: If it starts with "qcom,mdss_dsi_panel_", it's a panel node.
                if (strstr(node_name, "qcom,mdss_dsi_panel_")) {
                    return 0; // It's a different panel, ignore it
                }
            }
        }
        p--;
    }
    return 0;
}

static const char *hmbird_type_for_model(void) {
    switch (g_current_model) {
        case MODEL_RMX5200:
        case MODEL_PLK110:
            return "HMBIRD_EXT";
        case MODEL_PJD110:
            return "HMBIRD_OGKI";
        default:
            return NULL;
    }
}

/* Return 1 when the expected node exists or was added, 0 when this DTS does
 * not contain the insertion anchor, and -1 for a conflicting/malformed node. */
static int apply_hmbird_node(char **buffer_ptr, const char *expected_type) {
    char *buffer = *buffer_ptr;
    char *existing;
    char *ins_point;
    char *line_start;
    char indent[64] = {0};
    char new_node[512];
    char expected_property[80];
    char *new_buffer;
    size_t prefix_len;
    size_t new_len;
    int i = 0;

    if (!buffer || !expected_type ||
        (strcmp(expected_type, "HMBIRD_EXT") != 0 &&
         strcmp(expected_type, "HMBIRD_OGKI") != 0)) {
        return -1;
    }

    existing = strstr(buffer, "oplus,hmbird");
    if (existing) {
        snprintf(expected_property, sizeof(expected_property),
                 "type = \"%s\"", expected_type);
        if (!strstr(existing, expected_property)) {
            printf("ERROR: existing HMBIRD node does not match %s.\n",
                   expected_type);
            return -1;
        }
        g_hmbird_patch_count++;
        printf("Reused existing HMBIRD node type=%s.\n", expected_type);
        return 1;
    }

    ins_point = strstr(buffer, "oplus_sim_detect");
    if (!ins_point) return 0;
    line_start = ins_point;
    while (line_start > buffer && *(line_start - 1) != '\n') line_start--;
    while (line_start + i < ins_point && isspace((unsigned char)line_start[i]) &&
           i < (int)sizeof(indent) - 1) {
        indent[i] = line_start[i];
        i++;
    }
    indent[i] = '\0';

    snprintf(new_node, sizeof(new_node),
             "%soplus,hmbird {\n%s\tconfig_type {\n%s\t\ttype = \"%s\";\n"
             "%s\t};\n%s};\n\n",
             indent, indent, indent, expected_type, indent, indent);
    prefix_len = (size_t)(line_start - buffer);
    new_len = strlen(buffer) + strlen(new_node) + 1;
    new_buffer = malloc(new_len);
    if (!new_buffer) return -1;
    memcpy(new_buffer, buffer, prefix_len);
    new_buffer[prefix_len] = '\0';
    strcat(new_buffer, new_node);
    strcat(new_buffer, line_start);
    free(buffer);
    *buffer_ptr = new_buffer;
    g_hmbird_patch_count++;
    printf("Applied HMBIRD node type=%s.\n", expected_type);
    return 1;
}

static int write_hmbird_only_file(const char *input_path, const char *buffer) {
    char temp_path[512];
    FILE *out;
    size_t length = strlen(buffer);

    snprintf(temp_path, sizeof(temp_path), "%s.tmp", input_path);
    out = fopen(temp_path, "w");
    if (!out) return 0;
    if (fwrite(buffer, 1, length, out) != length || fclose(out) != 0) {
        remove(temp_path);
        return 0;
    }
    if (rename(temp_path, input_path) != 0) {
        remove(temp_path);
        return 0;
    }
    return 1;
}

// Process single file
void process_file(const char *filename) {
    char input_path[512];
    int adfr_mapping_count = 0;
    int adfr_failed = 0;
    int rmx5200_extension_failed = 0;
    Rmx5200PanelExtensions rmx5200_extensions[MAX_RMX5200_PANEL_COPIES] = {{0}};
    size_t rmx5200_panel_count = 0;
    snprintf(input_path, sizeof(input_path), "%s/%s", DIR_NAME, filename);

    printf("Processing file: %s\n", input_path);

    FILE *in = fopen(input_path, "r");
    if (!in) {
        perror("Cannot open file");
        return;
    }

    // Read entire file into memory
    fseek(in, 0, SEEK_END);
    long fsize = ftell(in);
    fseek(in, 0, SEEK_SET);

    char *buffer = malloc(fsize + 1);
    if (!buffer) {
        perror("Memory allocation failed");
        fclose(in);
        return;
    }
    fread(buffer, 1, fsize, in);
    buffer[fsize] = 0;
    fclose(in);

    // Project ID Check & Enforcement
    unsigned long long file_prj_id = get_prop_u64(buffer, "oplus,project-id");
    
    // If file has no project ID, skip it (safety first)
    if (file_prj_id == 0) {
        printf("Skipping %s (No oplus,project-id found)\n", filename);
        free(buffer);
        return;
    }
    
    if (file_prj_id != g_target_project_id) {
        // Special relaxation for PJD110 (OnePlus 12)
        // Allow 0x595d even if device says 0x5929 (Common variant/region diff)
        int allowed = 0;
        if (g_current_model == MODEL_PJD110) {
            if (file_prj_id == 0x595d || file_prj_id == 0x5929) allowed = 1;
        }

        if (!allowed) {
            printf("Skipping %s (Project ID mismatch: File=0x%llx, Device=0x%llx)\n", 
                   filename, file_prj_id, g_target_project_id);
            free(buffer);
            return;
        } else {
             printf("Allowing File ID 0x%llx for Device ID 0x%llx (Compatible Variant)\n", file_prj_id, g_target_project_id);
        }
    }
    
    printf("Verified Project ID matches: 0x%llx in %s\n", file_prj_id, filename);

    if (g_pjd110_ko_support) {
        int hmbird_result = apply_hmbird_node(&buffer, "HMBIRD_OGKI");
        if (hmbird_result < 0) {
            g_processing_error = 1;
            free(buffer);
            return;
        }
        g_pjd110_batt_capacity_count += replace_all_prop_u64(
            buffer, "oplus,batt_capacity_mah", 0x1770);
        g_pjd110_vbat_threshold_count += replace_all_prop_u64(
            buffer, "oplus_spec,vbat_uv_thr_mv", 0xaf0);
        g_pjd110_reserve_soc_count += replace_all_prop_u64(
            buffer, "oplus,reserve_chg_soc", 0x1);
        if (!write_hmbird_only_file(input_path, buffer)) {
            printf("ERROR: failed to write PJD110 KO-support DTS %s.\n", filename);
            g_processing_error = 1;
        }
        free(buffer);
        return;
    }

    if (g_hmbird_only) {
        int hmbird_result = apply_hmbird_node(&buffer, g_hmbird_only_type);
        if (hmbird_result < 0) {
            g_processing_error = 1;
        } else if (hmbird_result > 0 &&
                   !write_hmbird_only_file(input_path, buffer)) {
            printf("ERROR: failed to write HMBIRD-only DTS %s.\n", filename);
            g_processing_error = 1;
        }
        free(buffer);
        return;
    }

    {
        const char *hmbird_type = hmbird_type_for_model();
        int hmbird_result = apply_hmbird_node(&buffer, hmbird_type);
        if (hmbird_result < 0) {
            g_processing_error = 1;
            free(buffer);
            return;
        }
    }

    if (g_current_model == MODEL_PJD110) {
        // Global Replacements for PJD110
        replace_all_prop_u64(buffer, "oplus,batt_capacity_mah", 0x1770);
        replace_all_prop_u64(buffer, "oplus_spec,vbat_uv_thr_mv", 0xaf0);
        replace_all_prop_u64(buffer, "oplus,reserve_chg_soc", 0x1);
        printf("Applied global battery config changes for PJD110\n");
    }

    if (g_rmx5200_adfr_dry_run) {
        if (!enable_rmx5200_adfr_dry_run(&buffer)) {
            printf("ERROR: failed to enable RMX5200 ADFR dry-run in %s; original DTS is unchanged.\n",
                   filename);
            g_processing_error = 1;
            free(buffer);
            return;
        }
        printf("Enabled RMX5200 ADFR parser dry-run (config 0x101).\n");
    } else if (g_rmx5200_adfr_ltpo) {
        if (!enable_rmx5200_adfr_ltpo(&buffer)) {
            printf("ERROR: failed to enable RMX5200 WQHD LTPO in %s; original DTS is unchanged.\n",
                   filename);
            g_processing_error = 1;
            free(buffer);
            return;
        }
        printf("Enabled RMX5200 WQHD LTPO command path (config 0x1).\n");
    }

    char temp_path[512];
    snprintf(temp_path, sizeof(temp_path), "%s/%s.tmp", DIR_NAME, filename);
    FILE *out = fopen(temp_path, "w");
    if (!out) {
        perror("Cannot create temp file");
        free(buffer);
        return;
    }

    // Pass 1: Find Templates
    // GT8 Templates
    TimingNode template_wqhd_120 = {0};
    TimingNode template_wqhd = {0};
    TimingNode template_fhd = {0};
    // New Model Templates
    TimingNode template_sdc_120 = {0};
    TimingNode template_sdc_144 = {0};
    TimingNode template_sdc_60 = {0};
    
    char *p = buffer;
    while ((p = strstr(p, "timing@"))) {
        char *block_start = p;
        char *block_end = strchr(block_start, '}');
        const char *template_panel_start = NULL;
        int template_panel_id;
        if (!block_end) break;
        block_end = strchr(block_end, ';'); // };
        if (!block_end) break;
        block_end++; // Include ;
        
        // Check if inside any target panel
        template_panel_id = get_panel_id(buffer, block_start,
                                         &template_panel_start);
        if (template_panel_id == 0) {
            p = block_end;
            continue;
        }
        
        int len = block_end - block_start;
        if (len >= MAX_BLOCK) { p++; continue; }
        
        char node_name[128];
        sscanf(block_start, "%127s", node_name);
        // Clean name (remove {)
        char *brace = strchr(node_name, '{');
        if (brace) *brace = 0;

        if (template_panel_id == 1 &&
            !is_rmx5200_stock_timing(node_name)) {
            Rmx5200PanelExtensions *extensions = rmx5200_panel_extensions(
                rmx5200_extensions, &rmx5200_panel_count,
                template_panel_start, 1);
            if (!rmx5200_store_extension(extensions, node_name,
                                         block_start, (size_t)len)) {
                printf("ERROR: failed to preserve RMX5200 extension node %s.\n",
                       node_name);
                rmx5200_extension_failed = 1;
            }
        }
        
        // GT8 Templates
        if (strcmp(node_name, "timing@wqhd_sdc_120") == 0) {
            strncpy(template_wqhd_120.content, block_start, len);
            template_wqhd_120.content[len] = 0;
            template_wqhd_120.clock = get_prop_u64(
                template_wqhd_120.content, "qcom,mdss-dsi-panel-clockrate");
            template_wqhd_120.fps = get_prop_u64(
                template_wqhd_120.content, "qcom,mdss-dsi-panel-framerate");
            template_wqhd_120.transfer_time = get_prop_u64(
                template_wqhd_120.content, "qcom,mdss-mdp-transfer-time-us");
            template_wqhd_120.valid = 1;
        }
        if (strstr(node_name, "wqhd_sdc_144")) {
            strncpy(template_wqhd.content, block_start, len);
            template_wqhd.content[len] = 0;
            template_wqhd.clock = get_prop_u64(template_wqhd.content, "qcom,mdss-dsi-panel-clockrate");
            template_wqhd.fps = get_prop_u64(template_wqhd.content, "qcom,mdss-dsi-panel-framerate");
            template_wqhd.transfer_time = get_prop_u64(template_wqhd.content, "qcom,mdss-mdp-transfer-time-us");
            template_wqhd.valid = 1;
            printf("Found GT8 WQHD Template: %s (Clock: 0x%llx)\n", node_name, template_wqhd.clock);
        }
        
        if (strstr(node_name, "fhd_sdc_144") || strstr(node_name, "fhd_sdc_120")) {
             unsigned int current_fps = (unsigned int)get_prop_u64(
                 block_start, "qcom,mdss-dsi-panel-framerate");
             if (current_fps > template_fhd.fps) {
                 strncpy(template_fhd.content, block_start, len);
                 template_fhd.content[len] = 0;
                 template_fhd.clock = get_prop_u64(template_fhd.content, "qcom,mdss-dsi-panel-clockrate");
                 template_fhd.fps = current_fps;
                 template_fhd.transfer_time = get_prop_u64(template_fhd.content, "qcom,mdss-mdp-transfer-time-us");
                 template_fhd.valid = 1;
                 printf("Found GT8 FHD Template: %s (FPS: %u)\n",
                        node_name, template_fhd.fps);
             }
        }

        // New Model Templates
        if (strstr(node_name, "timing@sdc_fhd_120")) {
            strncpy(template_sdc_120.content, block_start, len);
            template_sdc_120.content[len] = 0;
            template_sdc_120.clock = get_prop_u64(template_sdc_120.content, "qcom,mdss-dsi-panel-clockrate");
            template_sdc_120.fps = get_prop_u64(template_sdc_120.content, "qcom,mdss-dsi-panel-framerate");
            template_sdc_120.transfer_time = get_prop_u64(template_sdc_120.content, "qcom,mdss-mdp-transfer-time-us");
            template_sdc_120.valid = 1;
            printf("Found New 120Hz Template: %s\n", node_name);
        }
        if (strstr(node_name, "timing@sdc_fhd_144")) {
            strncpy(template_sdc_144.content, block_start, len);
            template_sdc_144.content[len] = 0;
            template_sdc_144.clock = get_prop_u64(template_sdc_144.content, "qcom,mdss-dsi-panel-clockrate");
            template_sdc_144.fps = get_prop_u64(template_sdc_144.content, "qcom,mdss-dsi-panel-framerate");
            template_sdc_144.transfer_time = get_prop_u64(template_sdc_144.content, "qcom,mdss-mdp-transfer-time-us");
            template_sdc_144.valid = 1;
            printf("Found New 144Hz Template: %s\n", node_name);
        }
        if (g_current_model == MODEL_PLK110 &&
            strstr(node_name, "timing@sdc_fhd_60")) {
            strncpy(template_sdc_60.content, block_start, len);
            template_sdc_60.content[len] = 0;
            template_sdc_60.valid = 1;
            printf("Found PLK110 ADFR 60Hz template: %s\n", node_name);
        }
        p = block_end;
    }

    if (rmx5200_extension_failed) {
        fclose(out);
        remove(temp_path);
        rmx5200_free_extensions(rmx5200_extensions, rmx5200_panel_count);
        free(buffer);
        g_processing_error = 1;
        return;
    }

    // Pass 2: Process and Write
    p = buffer;
    char *cursor = buffer;
    
    // Counter for PJD110 cell-index
    int pjd110_cell_index = 0;
    const char *last_panel_start = NULL;
    int rmx5200_cell_index = 0;
    const char *last_rmx5200_panel_start = NULL;
    int plk110_cell_index = 0;
    const char *last_plk110_panel_start = NULL;

    // Track generated nodes in this session to prevent duplicates
    int generated_fhd_high[16] = {0};

    while ((p = strstr(cursor, "timing@"))) {
        char *block_start = p;
        char *block_end = strchr(block_start, '}');
        if (!block_end) {
            fwrite(cursor, 1, (p + 1) - cursor, out);
            cursor = p + 1;
            continue;
        }
        block_end = strchr(block_end, ';');
        if (!block_end) {
            fwrite(cursor, 1, (p + 1) - cursor, out);
            cursor = p + 1;
            continue;
        }
        block_end++;
        
        int block_len = block_end - block_start;
        char current_block[MAX_BLOCK];
        if (block_len >= MAX_BLOCK) {
            fwrite(cursor, 1, p - cursor, out);
            fwrite(block_start, 1, block_len, out);
            cursor = block_end;
            continue;
        }
        
        strncpy(current_block, block_start, block_len);
        current_block[block_len] = 0;
        
        char node_name[128];
        sscanf(current_block, "%127s", node_name);
        char *brace = strchr(node_name, '{');
        if (brace) *brace = 0;

        // Check context
        const char *current_panel_start = NULL;
        int panel_id = get_panel_id(buffer, block_start, &current_panel_start);
        if (panel_id == 0) {
            // Just write original
            fwrite(cursor, 1, p - cursor, out);
            fputs(current_block, out);
            cursor = block_end;
            continue;
        }

        char indent[64];
        int indent_len = 0;
        char *ls = block_start;
        while (ls > buffer && *(ls - 1) != '\n') ls--;
        char *q = ls;
        while (*q == ' ' || *q == '\t') {
            if (indent_len < (int)sizeof(indent) - 1) {
                indent[indent_len++] = *q;
            }
            q++;
        }
        indent[indent_len] = 0;

        /* Existing default or custom RMX5200 extensions may come from a
         * previously patched DTBO. Defer them until the retained stock modes
         * have been emitted, then assign the selected canonical indices. */
        if (panel_id == 1 && !is_rmx5200_stock_timing(node_name)) {
            cursor = block_end;
            continue;
        }

        if (panel_id == 1 && g_rmx5200_drop_stock_fhd &&
            is_rmx5200_stock_fhd_timing(node_name)) {
            printf("Dropping duplicate RMX5200 stock FHD timing %s.\n",
                   node_name);
            cursor = block_end;
            continue;
        }

        if (panel_id == 1 && g_rmx5200_keep_stock_fhd60 &&
            is_rmx5200_stock_fhd_timing(node_name) &&
            strcmp(node_name, "timing@fhd_sdc_60") != 0) {
            printf("Dropping RMX5200 stock FHD timing while retaining 60Hz: %s.\n",
                   node_name);
            fwrite(cursor, 1, p - cursor, out);
            cursor = block_end;
            continue;
        }

        /* Pass 1 has already captured the native WQHD templates and all
         * existing extensions. Dropping here therefore keeps generation
         * ordered as requested: build the overclock table first, omit only
         * the four native WQHD records when serializing the final DTS. */
        if (panel_id == 1 && g_rmx5200_drop_stock_wqhd &&
            is_rmx5200_stock_wqhd_timing(node_name)) {
            printf("Dropping RMX5200 stock WQHD timing after template capture: %s.\n",
                   node_name);
            fwrite(cursor, 1, p - cursor, out);
            cursor = block_end;
            continue;
        }

        fwrite(cursor, 1, p - cursor, out);

        if (panel_id == 1 && g_rmx5200_adfr_dry_run) {
            if (!inject_rmx5200_adfr_dry_run_mapping(
                    current_block, sizeof(current_block), indent)) {
                printf("ERROR: failed to add RMX5200 ADFR dry-run mapping to %s.\n",
                       node_name);
                adfr_failed = 1;
            } else {
                adfr_mapping_count++;
            }
        } else if (panel_id == 1 && g_rmx5200_adfr_ltpo &&
                   strstr(node_name, "timing@wqhd_sdc_")) {
            if (!inject_rmx5200_adfr_ltpo_properties(
                    current_block, sizeof(current_block), indent)) {
                printf("ERROR: failed to add RMX5200 WQHD LTPO properties to %s.\n",
                       node_name);
                adfr_failed = 1;
            } else {
                adfr_mapping_count++;
            }
        }
        
        // Logic Dispatch
        if (panel_id == 1) {
            char original_cell_index[64] = {0};

            if (g_rmx5200_ltpo_template &&
                strcmp(node_name, "timing@wqhd_sdc_60") == 0) {
                /* Capture before the canonical renumbering below. */
                get_prop_val_str(current_block, "cell-index",
                                 original_cell_index);
            }
            /* Keep the stock table at indices 0..7 and append every extension
             * after it. This mirrors the DRM-KO transaction and avoids moving
             * vendor FHD records from their original private indices. */
            if (current_panel_start != last_rmx5200_panel_start) {
                rmx5200_cell_index = 0;
                last_rmx5200_panel_start = current_panel_start;
            }
            if (!update_prop_u64(current_block, "cell-index",
                                 rmx5200_cell_index)) {
                printf("ERROR: Failed to renumber RMX5200 cell-index for %s.\n",
                       node_name);
                g_processing_error = 1;
            } else {
                printf("Renumbering RMX5200 cell-index for %s to: %d\n",
                       node_name, rmx5200_cell_index);
            }
            rmx5200_cell_index++;

            // GT8 Logic: preserve the vendor's low-refresh nodes by default.
            // The explicit A/B flag restores the historical 144Hz-template
            // workaround for WQHD 60Hz only.
            if (strstr(node_name, "wqhd_sdc_60")) {
                if (g_rmx5200_ltpo_template && template_wqhd.valid) {
                    if (!rmx5200_copy_wqhd_144_to_60(
                            current_block, sizeof(current_block),
                            &template_wqhd, original_cell_index)) {
                        printf("ERROR: RMX5200 LTPO template copy failed for %s.\n",
                               node_name);
                        g_processing_error = 1;
                    } else {
                        printf("Applied RMX5200 historical LTPO template: WQHD 144Hz -> 60Hz.\n");
                    }
                }
                fputs(current_block, out);
            }
            else if (strstr(node_name, "wqhd_sdc_90")) {
                fputs(current_block, out);
            }
            else if (strstr(node_name, "wqhd_sdc_120") ||
                     (strstr(node_name, "wqhd_sdc_144") &&
                      !g_rmx5200_drop_stock_fhd &&
                      !g_rmx5200_keep_stock_fhd60)) {
                fputs(current_block, out);
            }
            else if ((!g_rmx5200_drop_stock_fhd &&
                      !g_rmx5200_keep_stock_fhd60 &&
                      strcmp(node_name, "timing@fhd_sdc_144") == 0) ||
                     ((g_rmx5200_drop_stock_fhd ||
                       g_rmx5200_keep_stock_fhd60) &&
                      strcmp(node_name, "timing@wqhd_sdc_144") == 0)) {
                Rmx5200PanelExtensions *extensions;
                size_t i;

                fputs(current_block, out);
                extensions = rmx5200_panel_extensions(
                    rmx5200_extensions, &rmx5200_panel_count,
                    current_panel_start, 0);

                /* Canonical defaults come first, then any Web-created custom
                 * timing blocks in their original relative order. */
                for (i = 0; i < g_display_mode_manifest.rmx5200_dtbo_count; i++) {
                    int target_fps =
                        (int)g_display_mode_manifest.rmx5200_dtbo_rates[i];
                    char target_name[128];
                    char new_block[MAX_BLOCK];
                    Rmx5200ExtensionNode *existing;

                    snprintf(target_name, sizeof(target_name),
                             "timing@wqhd_sdc_%d", target_fps);
                    existing = rmx5200_find_extension(extensions, target_name);
                    if (existing) {
                        snprintf(new_block, sizeof(new_block), "%s",
                                 existing->content);
                        existing->emitted = 1;
                        printf("Moving existing RMX5200 extension %s after stock modes.\n",
                               target_name);
                    } else {
                        TimingNode *source = target_fps == 123
                            ? &template_wqhd_120 : &template_wqhd;
                        char old_name[128];
                        char old_header[160];
                        char new_header[160];
                        unsigned long long new_clock;
                        unsigned int new_transfer;

                        if (!source->valid || source->fps == 0) {
                            printf("ERROR: missing RMX5200 source timing for %dHz.\n",
                                   target_fps);
                            g_processing_error = 1;
                            rmx5200_extension_failed = 1;
                            continue;
                        }
                        snprintf(new_block, sizeof(new_block), "%s",
                                 source->content);
                        sscanf(source->content, "%127s", old_name);
                        {
                            char *name_brace = strchr(old_name, '{');
                            if (name_brace) *name_brace = 0;
                        }
                        snprintf(old_header, sizeof(old_header), "%s {", old_name);
                        snprintf(new_header, sizeof(new_header), "%s {", target_name);
                        replace_str(new_block, old_header, new_header);
                        new_clock = source->clock * target_fps / source->fps;
                        new_transfer = source->transfer_time * source->fps /
                                       target_fps;
                        update_prop_u64(new_block,
                                        "qcom,mdss-dsi-panel-clockrate", new_clock);
                        update_prop_u64(new_block,
                                        "qcom,mdss-dsi-panel-framerate", target_fps);
                        update_prop_u64(new_block,
                                        "qcom,mdss-mdp-transfer-time-us", new_transfer);
                        printf("Generating appended RMX5200 extension %s.\n",
                               target_name);
                    }

                    if (!update_prop_u64(new_block, "cell-index",
                                         rmx5200_cell_index++)) {
                        printf("ERROR: failed to index RMX5200 extension %s.\n",
                               target_name);
                        g_processing_error = 1;
                        rmx5200_extension_failed = 1;
                    }
                    if (g_rmx5200_adfr_dry_run || g_rmx5200_adfr_ltpo) {
                        int injected = g_rmx5200_adfr_ltpo
                            ? inject_rmx5200_adfr_ltpo_properties(
                                new_block, sizeof(new_block), indent)
                            : inject_rmx5200_adfr_dry_run_mapping(
                                new_block, sizeof(new_block), indent);
                        if (!injected) {
                            printf("ERROR: failed to add RMX5200 ADFR properties to %s.\n",
                                   target_name);
                            adfr_failed = 1;
                        } else {
                            adfr_mapping_count++;
                        }
                    }
                    fputs("\n", out);
                    fputs(indent, out);
                    fputs(new_block, out);
                }

                if (extensions) {
                    for (i = 0; i < extensions->count; i++) {
                        char custom_block[MAX_BLOCK];
                        Rmx5200ExtensionNode *custom = &extensions->nodes[i];

                        if (custom->emitted) continue;
                        snprintf(custom_block, sizeof(custom_block), "%s",
                                 custom->content);
                        if (!update_prop_u64(custom_block, "cell-index",
                                             rmx5200_cell_index++)) {
                            printf("ERROR: failed to index custom RMX5200 extension %s.\n",
                                   custom->name);
                            g_processing_error = 1;
                            rmx5200_extension_failed = 1;
                        }
                        if ((g_rmx5200_adfr_dry_run || g_rmx5200_adfr_ltpo) &&
                            strstr(custom->name, "timing@wqhd_sdc_")) {
                            int injected = g_rmx5200_adfr_ltpo
                                ? inject_rmx5200_adfr_ltpo_properties(
                                    custom_block, sizeof(custom_block), indent)
                                : inject_rmx5200_adfr_dry_run_mapping(
                                    custom_block, sizeof(custom_block), indent);
                            if (!injected) {
                                printf("ERROR: failed to add RMX5200 ADFR properties to custom %s.\n",
                                       custom->name);
                                adfr_failed = 1;
                            } else {
                                adfr_mapping_count++;
                            }
                        }
                        custom->emitted = 1;
                        fputs("\n", out);
                        fputs(indent, out);
                        fputs(custom_block, out);
                    }
                }
            }
            else {
                // Keep original
                fputs(current_block, out);
            }
            cursor = block_end;
            continue;
        } else if (panel_id == 3) {
            // PJD110 Logic
            
            // Check for panel switch (reset cell-index)
            if (current_panel_start != last_panel_start) {
                if (last_panel_start != NULL) {
                     printf("New panel detected (Address change), resetting cell-index to 0.\n");
                }
                pjd110_cell_index = 0;
                last_panel_start = current_panel_start;
            }

            // 1. Remove 60Hz and 90Hz
            unsigned int fps = get_prop_u64(current_block, "qcom,mdss-dsi-panel-framerate");
            
            if (fps == 60 || fps == 90) {
                 printf("Removing %dHz node for PJD110: %s\n", fps, node_name);
                 cursor = block_end; // Skip writing
                 continue;
            }
            
            // 2. Renumber cell-index
            printf("Renumbering cell-index for %s to: %d\n", node_name, pjd110_cell_index);
            if (!update_prop_u64(current_block, "cell-index", pjd110_cell_index)) {
                printf("ERROR: Failed to update cell-index for %s. Property missing or malformed?\n", node_name);
                g_processing_error = 1;
                // Try to find it manually to see what's wrong
                char *debug_p = strstr(current_block, "cell-index");
                if (debug_p) {
                    char debug_buf[100];
                    strncpy(debug_buf, debug_p, 99);
                    debug_buf[99] = 0;
                    printf("DEBUG: Found string: %s\n", debug_buf);
                } else {
                    printf("DEBUG: 'cell-index' string not found in block.\n");
                }
            } else {
                pjd110_cell_index++;
            }
            
            fputs(current_block, out);
            cursor = block_end;
            continue;
        }
        else if (panel_id == 2) {
            // OnePlus 15 Logic
            printf("Processing OnePlus 15 Node: %s\n", node_name);
            if (current_panel_start != last_plk110_panel_start) {
                plk110_cell_index = 0;
                last_plk110_panel_start = current_panel_start;
            }
            
            // 1. Modify 120Hz -> 123Hz (Direct Replace)
            if (strstr(node_name, "timing@sdc_fhd_120")) {
                printf("Modifying 120Hz node to 123Hz (Direct Replace)...\n");
                char new_block[MAX_BLOCK];
                strcpy(new_block, current_block);
                
                replace_str(new_block, "timing@sdc_fhd_120 {", "timing@sdc_fhd_123 {");
                
                unsigned long long base_clock = get_prop_u64(current_block, "qcom,mdss-dsi-panel-clockrate");
                unsigned int base_fps = 120;
                int target_fps = 123;
                unsigned long long new_clock = base_clock * target_fps / base_fps;
                unsigned int base_transfer = get_prop_u64(current_block, "qcom,mdss-mdp-transfer-time-us");
                unsigned int new_transfer = 0;
                if (base_transfer > 0) new_transfer = base_transfer * base_fps / target_fps;
                
                update_prop_u64(new_block, "qcom,mdss-dsi-panel-clockrate", new_clock);
                update_prop_u64(new_block, "qcom,mdss-dsi-panel-framerate", target_fps);
                if (new_transfer > 0) update_prop_u64(new_block, "qcom,mdss-mdp-transfer-time-us", new_transfer);
                if (!update_prop_u64(new_block, "cell-index",
                                     plk110_cell_index++)) {
                    printf("ERROR: Failed to renumber PLK110 cell-index for %s.\n",
                           node_name);
                    g_processing_error = 1;
                }
                
                fputs(new_block, out);
                fputs("\n", out);
            }
            // 2. 165Hz -> Generate 170-199Hz
            else if (strstr(node_name, "timing@sdc_fhd_165")) {
                if (!update_prop_u64(current_block, "cell-index",
                                     plk110_cell_index++)) {
                    printf("ERROR: Failed to renumber PLK110 cell-index for %s.\n",
                           node_name);
                    g_processing_error = 1;
                }
                fputs(current_block, out);
                fputs("\n", out);
                
                for (size_t i = 1; i < g_display_mode_manifest.plk110_dtbo_count; i++) {
                    int target_fps = (int)g_display_mode_manifest.plk110_dtbo_rates[i];
                    char target_node_name[64];
                    sprintf(target_node_name, "timing@sdc_fhd_%d", target_fps);
                    
                    if (strstr(buffer, target_node_name) || generated_fhd_high[i]) {
                         printf("Node %s already exists, skipping generation.\n", target_node_name);
                         continue;
                    }

                    generated_fhd_high[i] = 1;
                    printf("Generating %dHz node (New)...\n", target_fps);
                    
                    char new_block[MAX_BLOCK];
                    strcpy(new_block, current_block);
                    
                    char header_new[128];
                    sprintf(header_new, "timing@sdc_fhd_%d {", target_fps);
                    replace_str(new_block, "timing@sdc_fhd_165 {", header_new);
                    
                    unsigned long long base_clock = get_prop_u64(current_block, "qcom,mdss-dsi-panel-clockrate");
                    unsigned int base_fps = 165;
                    unsigned long long new_clock = base_clock * target_fps / base_fps;
                    unsigned int base_transfer = get_prop_u64(current_block, "qcom,mdss-mdp-transfer-time-us");
                    unsigned int new_transfer = 0;
                    if (base_transfer > 0) new_transfer = base_transfer * base_fps / target_fps;
                    
                    update_prop_u64(new_block, "qcom,mdss-dsi-panel-clockrate", new_clock);
                    update_prop_u64(new_block, "qcom,mdss-dsi-panel-framerate", target_fps);
                    if (new_transfer > 0) update_prop_u64(new_block, "qcom,mdss-mdp-transfer-time-us", new_transfer);
                    if (!update_prop_u64(new_block, "cell-index",
                                         plk110_cell_index++)) {
                        printf("ERROR: Failed to assign PLK110 cell-index for %dHz.\n",
                               target_fps);
                        g_processing_error = 1;
                    }

                    if (template_sdc_60.valid) {
                        int copied = inject_plk110_adfr_properties(
                            new_block, sizeof(new_block),
                            template_sdc_60.content, indent);
                        if (!copied) {
                            printf("Warning: failed to copy PLK110 ADFR properties to %dHz node.\n",
                                   target_fps);
                        }
                    } else {
                        printf("Warning: PLK110 ADFR 60Hz template is missing; %dHz node has no ADFR.\n",
                               target_fps);
                    }
                    
                    fputs("\n", out);
                    fputs(indent, out);
                    fputs(new_block, out);
                    fputs("\n", out);
                }
            }
            // 3. Preserve the stock 60Hz node. Its LTPS/ADFR timing is
            // vendor-specific; copying the 165Hz template causes the same
            // low-refresh fallback and density instability seen on RMX5200.
            else if (strstr(node_name, "timing@sdc_fhd_60")) {
                if (!update_prop_u64(current_block, "cell-index",
                                     plk110_cell_index++)) {
                    printf("ERROR: Failed to renumber PLK110 cell-index for %s.\n",
                           node_name);
                    g_processing_error = 1;
                }
                fputs(current_block, out);
            }
            // 4. Delete specific nodes (sdc_fhd_90 & oplus_fhd_120)
            else if (strstr(node_name, "timing@sdc_fhd_90") || strstr(node_name, "timing@oplus_fhd_120")) {
                printf("Deleting node (Skipping): %s\n", node_name);
            }
            else {
                if (!update_prop_u64(current_block, "cell-index",
                                     plk110_cell_index++)) {
                    printf("ERROR: Failed to renumber PLK110 cell-index for %s.\n",
                           node_name);
                    g_processing_error = 1;
                }
                fputs(current_block, out);
            }
        }
        else {
            fputs(current_block, out);
        }
        
        cursor = block_end;
    }
    
    // Write remaining
    fprintf(out, "%s", cursor);

    fclose(out);
    rmx5200_free_extensions(rmx5200_extensions, rmx5200_panel_count);
    free(buffer);

    if (rmx5200_extension_failed) {
        remove(temp_path);
        printf("ERROR: RMX5200 extension reorder failed; original DTS is unchanged.\n");
        return;
    }

    if ((g_rmx5200_adfr_dry_run || g_rmx5200_adfr_ltpo) &&
        (adfr_failed || adfr_mapping_count == 0)) {
        remove(temp_path);
        printf("ERROR: RMX5200 ADFR validation failed (%d WQHD timings); original DTS is unchanged.\n",
               adfr_mapping_count);
        g_processing_error = 1;
        return;
    }
    if (g_rmx5200_adfr_dry_run) {
        printf("RMX5200 ADFR dry-run prepared with %d timing mappings and no ADFR DSI commands.\n",
               adfr_mapping_count);
    } else if (g_rmx5200_adfr_ltpo) {
        printf("RMX5200 WQHD LTPO prepared with %d timing mappings and 18 ADFR command sets per timing.\n",
               adfr_mapping_count);
    }

    if (rename(temp_path, input_path) != 0) {
        char cmd[1100];
        snprintf(cmd, sizeof(cmd), "mv -f \"%s\" \"%s\"",
                 temp_path, input_path);
        system(cmd);
    }
}

int main(int argc, char **argv) {
    int i;

    detect_device_model();

    if (!load_display_mode_manifest()) {
        return 1;
    }

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--rmx5200-adfr-dry-run") == 0 &&
            !g_rmx5200_adfr_dry_run) {
            g_rmx5200_adfr_dry_run = 1;
        } else if (strcmp(argv[i], "--rmx5200-adfr-ltpo") == 0) {
            printf("Error: --rmx5200-adfr-ltpo is disabled: the bundled "
                   "command payload is not verified for AE084 DVT02. "
                   "Use --rmx5200-adfr-dry-run for parser-only testing.\n");
            return 1;
        } else if (strcmp(argv[i], "--rmx5200-ltpo-template") == 0 &&
                   !g_rmx5200_ltpo_template) {
            g_rmx5200_ltpo_template = 1;
        } else if (strcmp(argv[i], "--rmx5200-drop-stock-fhd") == 0 &&
                   !g_rmx5200_drop_stock_fhd) {
            g_rmx5200_drop_stock_fhd = 1;
        } else if (strcmp(argv[i], "--rmx5200-drop-stock-wqhd") == 0 &&
                   !g_rmx5200_drop_stock_wqhd) {
            g_rmx5200_drop_stock_wqhd = 1;
        } else if (strcmp(argv[i], "--rmx5200-keep-stock-fhd60") == 0 &&
                   !g_rmx5200_keep_stock_fhd60) {
            g_rmx5200_keep_stock_fhd60 = 1;
        } else if (strncmp(argv[i], "--hmbird-only=", 14) == 0 &&
                   !g_hmbird_only) {
            const char *type = argv[i] + 14;
            if (strcmp(type, "HMBIRD_EXT") != 0 &&
                strcmp(type, "HMBIRD_OGKI") != 0) {
                printf("Error: unsupported HMBIRD type %s.\n", type);
                return 1;
            }
            g_hmbird_only = 1;
            snprintf(g_hmbird_only_type, sizeof(g_hmbird_only_type), "%s", type);
        } else if (strcmp(argv[i], "--pjd110-ko-support") == 0 &&
                   !g_pjd110_ko_support) {
            g_pjd110_ko_support = 1;
        } else {
            printf("Usage: %s [--rmx5200-adfr-dry-run|--rmx5200-adfr-ltpo|"
                    "--rmx5200-ltpo-template] "
                    "[--rmx5200-drop-stock-fhd|--rmx5200-drop-stock-wqhd|"
                    "--rmx5200-keep-stock-fhd60] [--hmbird-only=HMBIRD_EXT|HMBIRD_OGKI] "
                    "[--pjd110-ko-support]\n",
                    argv[0]);
            return 1;
        }
    }

    if (g_rmx5200_adfr_dry_run && g_rmx5200_adfr_ltpo) {
        printf("Error: RMX5200 ADFR dry-run and LTPO modes are mutually exclusive.\n");
        return 1;
    }
    if (g_hmbird_only &&
        (g_rmx5200_adfr_dry_run || g_rmx5200_adfr_ltpo ||
         g_rmx5200_ltpo_template || g_rmx5200_drop_stock_fhd ||
         g_rmx5200_drop_stock_wqhd || g_rmx5200_keep_stock_fhd60)) {
        printf("Error: HMBIRD-only mode cannot be combined with display modifications.\n");
        return 1;
    }
    if (g_pjd110_ko_support &&
        (g_hmbird_only || g_rmx5200_adfr_dry_run || g_rmx5200_adfr_ltpo ||
         g_rmx5200_ltpo_template || g_rmx5200_drop_stock_fhd ||
         g_rmx5200_drop_stock_wqhd || g_rmx5200_keep_stock_fhd60)) {
        printf("Error: PJD110 KO-support mode cannot be combined with other modifications.\n");
        return 1;
    }
    if (g_pjd110_ko_support && g_current_model != MODEL_PJD110) {
        printf("Error: PJD110 KO-support mode is restricted to PJD110.\n");
        return 1;
    }
    if (g_rmx5200_ltpo_template &&
        (g_rmx5200_adfr_dry_run || g_rmx5200_adfr_ltpo)) {
        printf("Error: RMX5200 LTPO template A/B is mutually exclusive with ADFR injection modes.\n");
        return 1;
    }
    if (g_rmx5200_drop_stock_wqhd &&
        (g_rmx5200_drop_stock_fhd || g_rmx5200_adfr_dry_run ||
         g_rmx5200_adfr_ltpo || g_rmx5200_ltpo_template)) {
        printf("Error: RMX5200 stock WQHD drop is an isolated mode-table A/B test.\n");
        return 1;
    }
    if (g_rmx5200_keep_stock_fhd60 &&
        (g_rmx5200_drop_stock_fhd || g_rmx5200_drop_stock_wqhd ||
         g_rmx5200_adfr_dry_run || g_rmx5200_adfr_ltpo ||
         g_rmx5200_ltpo_template)) {
        printf("Error: RMX5200 stock FHD60 retention is an isolated mode-table A/B test.\n");
        return 1;
    }
    if ((g_rmx5200_adfr_dry_run || g_rmx5200_adfr_ltpo ||
          g_rmx5200_ltpo_template || g_rmx5200_drop_stock_fhd ||
          g_rmx5200_drop_stock_wqhd || g_rmx5200_keep_stock_fhd60) &&
         g_current_model != MODEL_RMX5200) {
        printf("Error: RMX5200 experimental options are restricted to RMX5200.\n");
        return 1;
    }
    if (g_rmx5200_adfr_dry_run || g_rmx5200_adfr_ltpo) {
        if (!load_rmx5200_adfr_profile()) {
            return 1;
        }
    }
    if (g_rmx5200_adfr_ltpo && !load_rmx5200_adfr_commands()) {
        return 1;
    }
    if (g_rmx5200_drop_stock_fhd) {
        printf("RMX5200 experiment: dropping four stock FHD timings; "
               "dynamic FHD group remains.\n");
    }
    if (g_rmx5200_drop_stock_wqhd) {
        printf("RMX5200 experiment: generate overclock WQHD timings first, then "
               "drop the four stock WQHD timings; stock FHD remains.\n");
    }
    if (g_rmx5200_keep_stock_fhd60) {
        printf("RMX5200 experiment: retain stock FHD 60Hz only; drop stock FHD "
               "90/120/144Hz after generating WQHD overclock timings.\n");
    }
    if (g_rmx5200_ltpo_template) {
        printf("RMX5200 experiment: copying native WQHD 144Hz timing to WQHD 60Hz "
               "with the original 60Hz cell-index.\n");
    }
    if (g_hmbird_only) {
        printf("HMBIRD-only mode: preserving all display, ADFR, battery and index data; type=%s.\n",
               g_hmbird_only_type);
    }
    if (g_pjd110_ko_support) {
        printf("PJD110 KO-support mode: applying capacity unlock and HMBIRD_OGKI; "
               "preserving all display timings and indices.\n");
    }

    DIR *d;
    struct dirent *dir;

    d = opendir(DIR_NAME);
    if (d) {
        while ((dir = readdir(d)) != NULL) {
            char *dot = strrchr(dir->d_name, '.');
            if (dot && strcmp(dot, ".dts") == 0) {
                char full_path[512];
                snprintf(full_path, sizeof(full_path), "%s/%s", DIR_NAME, dir->d_name);
                if (is_regular_file(full_path)) {
                    // GT8 Pro specific filtering
                    if (g_current_model == MODEL_RMX5200) {
                        FILE *fp = fopen(full_path, "r");
                        if (fp) {
                            fseek(fp, 0, SEEK_END);
                            long sz = ftell(fp);
                            fseek(fp, 0, SEEK_SET);
                            char *buf = malloc(sz + 1);
                            if (buf) {
                                fread(buf, 1, sz, fp);
                                buf[sz] = 0;
                                if (strstr(buf, PANEL_GT8_PRO)) {
                                    printf("Target panel found in %s. Processing...\n", dir->d_name);
                                    process_file(dir->d_name);
                                } else {
                                    printf("Skipping %s (Target panel not found)\n", dir->d_name);
                                }
                                free(buf);
                            }
                            fclose(fp);
                        }
                    } else {
                        // Other models process all DTS files (with internal checks)
                        process_file(dir->d_name);
                    }
                }
            }
        }
        closedir(d);
    } else {
        printf("Cannot open directory %s\n", DIR_NAME);
        return 1;
    }
    if (g_hmbird_only && g_hmbird_patch_count == 0) {
        printf("ERROR: HMBIRD-only mode found no oplus_sim_detect insertion anchor.\n");
        return 1;
    }
    if (g_pjd110_ko_support &&
        (g_hmbird_patch_count == 0 || g_pjd110_batt_capacity_count == 0 ||
         g_pjd110_vbat_threshold_count == 0 ||
         g_pjd110_reserve_soc_count == 0)) {
        printf("ERROR: PJD110 KO-support DTBO is incomplete "
               "(hmbird=%d, capacity=%d, vbat=%d, reserve_soc=%d).\n",
               g_hmbird_patch_count, g_pjd110_batt_capacity_count,
               g_pjd110_vbat_threshold_count, g_pjd110_reserve_soc_count);
        return 1;
    }
    printf("All files processed.\n");
    return g_processing_error ? 1 : 0;
}
