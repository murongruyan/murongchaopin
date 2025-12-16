/*
 * Process DTS Tool
 * 
 * Modifications for 1080p DPI Flickering Fix & LTPO Stability:
 * 1. Automatic Clock Calculation:
 *    - Formula: New_Clock = Base_Clock * (Target_FPS / Base_FPS)
 *    - Applied to 123Hz and 150-180Hz modes.
 * 
 * 2. LTPO Fix for 60Hz (FHD/WQHD):
 *    - Issue: DPI flickering at 1080p 60Hz.
 *    - Fix: Use high-refresh rate (144Hz) config as a template.
 *    - Process:
 *      a) Find 144Hz template.
 *      b) Copy template to replace 60Hz node.
 *      c) Apply original 60Hz cell-index.
 *      d) Auto-calculate clock and transfer time for 60Hz based on template.
 *      e) Force framerate to 60.
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
#include <sys/system_properties.h>

#define MODEL_UNKNOWN 0
#define MODEL_RMX5200 1 // Realme GT8 Pro
#define MODEL_PLK110  2 // OnePlus 15 (PLK110)
#define MODEL_PJD110  3 // OnePlus 12 (PJD110)

int g_current_model = MODEL_UNKNOWN;
unsigned long long g_target_project_id = 0;
int g_has_project_id = 0;

void detect_device_model() {
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
}


#define MAX_LINE 4096
#define MAX_BLOCK 131072 // 128KB buffer for blocks
#define DIR_NAME "dtbo_dts"

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
void replace_all_prop_u64(char *content, const char *prop_name, unsigned long long new_val) {
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

// Process single file
void process_file(const char *filename) {
    char input_path[512];
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

    if (g_current_model == MODEL_PJD110) {
        // Global Replacements for PJD110
        replace_all_prop_u64(buffer, "oplus,batt_capacity_mah", 0x1770);
        replace_all_prop_u64(buffer, "oplus_spec,vbat_uv_thr_mv", 0xaf0);
        replace_all_prop_u64(buffer, "oplus,reserve_chg_soc", 0x1);
        printf("Applied global battery config changes for PJD110\n");
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
    TimingNode template_wqhd = {0};
    TimingNode template_fhd = {0};
    // New Model Templates
    TimingNode template_sdc_120 = {0};
    TimingNode template_sdc_144 = {0};
    TimingNode template_sdc_165 = {0};
    
    char *p = buffer;
    while ((p = strstr(p, "timing@"))) {
        char *block_start = p;
        char *block_end = strchr(block_start, '}');
        if (!block_end) break;
        block_end = strchr(block_end, ';'); // };
        if (!block_end) break;
        block_end++; // Include ;
        
        // Check if inside any target panel
        if (get_panel_id(buffer, block_start, NULL) == 0) {
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
        
        // GT8 Templates
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
             int current_fps = get_prop_u64(block_start, "qcom,mdss-dsi-panel-framerate");
             if (current_fps > template_fhd.fps) {
                 strncpy(template_fhd.content, block_start, len);
                 template_fhd.content[len] = 0;
                 template_fhd.clock = get_prop_u64(template_fhd.content, "qcom,mdss-dsi-panel-clockrate");
                 template_fhd.fps = current_fps;
                 template_fhd.transfer_time = get_prop_u64(template_fhd.content, "qcom,mdss-mdp-transfer-time-us");
                 template_fhd.valid = 1;
                 printf("Found GT8 FHD Template: %s (FPS: %d)\n", node_name, template_fhd.fps);
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
        if (strstr(node_name, "timing@sdc_fhd_165") || (g_current_model == MODEL_PLK110 && strstr(node_name, "_165"))) {
            strncpy(template_sdc_165.content, block_start, len);
            template_sdc_165.content[len] = 0;
            template_sdc_165.clock = get_prop_u64(template_sdc_165.content, "qcom,mdss-dsi-panel-clockrate");
            template_sdc_165.fps = get_prop_u64(template_sdc_165.content, "qcom,mdss-dsi-panel-framerate");
            template_sdc_165.transfer_time = get_prop_u64(template_sdc_165.content, "qcom,mdss-mdp-transfer-time-us");
            template_sdc_165.valid = 1;
            printf("Found New 165Hz Template: %s\n", node_name);
        }
        
        p = block_end;
    }

    // Pass 2: Process and Write
    p = buffer;
    char *cursor = buffer;
    
    // Counter for PJD110 cell-index
    int pjd110_cell_index = 0;
    const char *last_panel_start = NULL;

    while ((p = strstr(cursor, "timing@"))) {
        // Write everything before this block
        fwrite(cursor, 1, p - cursor, out);
        
        char *block_start = p;
        char *block_end = strchr(block_start, '}');
        if (!block_end) { cursor = p + 1; continue; } 
        block_end = strchr(block_end, ';');
        if (!block_end) { cursor = p + 1; continue; }
        block_end++;
        
        int block_len = block_end - block_start;
        char current_block[MAX_BLOCK];
        if (block_len >= MAX_BLOCK) {
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
        
        // Logic Dispatch
        if (panel_id == 1) {
            // GT8 Logic
            // 1. LTPO Fix for 60Hz (WQHD)
            if (strstr(node_name, "wqhd_sdc_60") && template_wqhd.valid) {
                printf("Applying LTPO Fix to %s\n", node_name);
                
                // Extract raw values from original 60Hz node to preserve them
                char orig_index_str[64] = {0};
                
                get_prop_val_str(current_block, "cell-index", orig_index_str);
                
                // Start with template
                char new_block[MAX_BLOCK];
                strcpy(new_block, template_wqhd.content);
                
                // Replace name safely
                char template_name[128];
                sscanf(template_wqhd.content, "%127s", template_name); 
                char search_str[128];
                sprintf(search_str, "%s {", template_name);
                replace_str(new_block, search_str, "timing@wqhd_sdc_60 {");
                
                // Restore original 60Hz cell-index ONLY. Use Template's Clock/Transfer!
                if (strlen(orig_index_str) > 0) update_prop_val_str(new_block, "cell-index", orig_index_str);
                
                // Force framerate to 60
                update_prop_u64(new_block, "qcom,mdss-dsi-panel-framerate", 60); 
                
                fputs(new_block, out);
                fputs("\n", out);
            } 
            // 3. WQHD 120Hz -> Add 123Hz (Auto Calc)
            else if (strstr(node_name, "wqhd_sdc_120")) {
                fputs(current_block, out);
                fputs("\n", out);
                
                // Generate 123Hz
                printf("Generating 123Hz node...\n");
                char new_block[MAX_BLOCK];
                strcpy(new_block, current_block);
                
                replace_str(new_block, "timing@wqhd_sdc_120 {", "timing@wqhd_sdc_123 {");
                
                unsigned long long base_clock = get_prop_u64(current_block, "qcom,mdss-dsi-panel-clockrate");
                unsigned int base_fps = get_prop_u64(current_block, "qcom,mdss-dsi-panel-framerate");
                if (base_fps < 110 || base_fps > 130) base_fps = 120;
                
                int target_fps = 123;
                unsigned long long new_clock = base_clock * target_fps / base_fps;
                unsigned int base_transfer = get_prop_u64(current_block, "qcom,mdss-mdp-transfer-time-us");
                unsigned int new_transfer = 0;
                if (base_transfer > 0) new_transfer = base_transfer * base_fps / target_fps;
                
                update_prop_u64(new_block, "qcom,mdss-dsi-panel-clockrate", new_clock);
                update_prop_u64(new_block, "qcom,mdss-dsi-panel-framerate", target_fps);
                if (new_transfer > 0) update_prop_u64(new_block, "qcom,mdss-mdp-transfer-time-us", new_transfer);
                update_prop_u64(new_block, "cell-index", 0x8);
                
                fputs("\n", out);
                fputs(indent, out);
                fputs(new_block, out);
                fputs("\n", out);
            }
            // 4. WQHD 144Hz -> Add 150-180Hz (Auto Calc)
            else if (strstr(node_name, "wqhd_sdc_144")) {
                fputs(current_block, out);
                fputs("\n", out);
                
                if (template_wqhd.valid) {
                    int freqs[] = {150, 155, 160, 165, 170, 175, 180};
                    int indexes[] = {0x9, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15};
                    
                    for (int i=0; i<7; i++) {
                        int target_fps = freqs[i];
                        printf("Generating %dHz node...\n", target_fps);
                        
                        char new_block[MAX_BLOCK];
                        strcpy(new_block, template_wqhd.content);
                        
                        char header_old[128], header_new[128];
                        sscanf(template_wqhd.content, "%127s", header_old);
                        char *b = strchr(header_old, '{'); if(b) *b=0;
                        sprintf(header_new, "timing@wqhd_sdc_%d {", target_fps);
                        
                        char header_old_full[128];
                        sprintf(header_old_full, "%s {", header_old);
                        replace_str(new_block, header_old_full, header_new);
                        
                        unsigned long long new_clock = template_wqhd.clock * target_fps / template_wqhd.fps;
                        unsigned int new_transfer = template_wqhd.transfer_time * template_wqhd.fps / target_fps;
                        
                        update_prop_u64(new_block, "qcom,mdss-dsi-panel-clockrate", new_clock);
                        update_prop_u64(new_block, "qcom,mdss-dsi-panel-framerate", target_fps);
                        update_prop_u64(new_block, "qcom,mdss-mdp-transfer-time-us", new_transfer);
                        update_prop_u64(new_block, "cell-index", indexes[i]);
                        
                        fputs("\n", out);
                        fputs(indent, out);
                        fputs(new_block, out);
                        fputs("\n", out);
                    }
                }
            }
            // 5. Force WQHD 90 clockrate to 2K template clock (Disabled FHD)
            else if (strstr(node_name, "wqhd_sdc_90")) {
                char mod_block[MAX_BLOCK];
                strcpy(mod_block, current_block);
                if (template_wqhd.valid) {
                    replace_prop_line_u64(mod_block, "qcom,mdss-dsi-panel-clockrate", template_wqhd.clock);
                }
                fputs(mod_block, out);
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
                
                fputs(new_block, out);
                fputs("\n", out);
            }
            // 2. 165Hz -> Generate 170-199Hz
            else if (strstr(node_name, "timing@sdc_fhd_165")) {
                fputs(current_block, out);
                fputs("\n", out);
                
                int freqs[] = {170, 175, 180, 185, 190, 195, 199};
                
                for (int i=0; i<7; i++) {
                    int target_fps = freqs[i];
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
                    
                    fputs("\n", out);
                    fputs(indent, out);
                    fputs(new_block, out);
                    fputs("\n", out);
                }
            }
            // 3. Replace 60Hz with 165Hz template (Force 60Hz FPS)
            else if (strstr(node_name, "timing@sdc_fhd_60")) {
                if (template_sdc_165.valid) {
                    printf("Replacing 60Hz with 165Hz Template (New)...\n");
                    char new_block[MAX_BLOCK];
                    strcpy(new_block, template_sdc_165.content);
                    
                    replace_str(new_block, "timing@sdc_fhd_165 {", "timing@sdc_fhd_60 {");
                    
                    update_prop_u64(new_block, "qcom,mdss-dsi-panel-framerate", 60);
                    
                    fputs(new_block, out);
                    fputs("\n", out);
                } else {
                    fputs(current_block, out);
                }
            }
            // 4. Delete specific nodes (sdc_fhd_90 & oplus_fhd_120)
            else if (strstr(node_name, "timing@sdc_fhd_90") || strstr(node_name, "timing@oplus_fhd_120")) {
                printf("Deleting node (Skipping): %s\n", node_name);
            }
            else {
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

    free(buffer);
    fclose(out);

    if (rename(temp_path, input_path) != 0) {
        char cmd[1024];
        sprintf(cmd, "mv -f \"%s\" \"%s\"", temp_path, input_path);
        system(cmd);
    }
}

int main() {
    detect_device_model();

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
    printf("All files processed.\n");
    return 0;
}
