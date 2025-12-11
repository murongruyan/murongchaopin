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
    char search_str[256];
    sprintf(search_str, "%s =", prop_name);
    char *p = strstr(content, search_str);
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

void update_prop_u64(char *content, const char *prop_name, unsigned long long new_val) {
    char search_str[256];
    sprintf(search_str, "%s =", prop_name);
    char *p = strstr(content, search_str);
    if (!p) return;
    
    // Safety: Find ;
    char *end_stmt = strchr(p, ';');
    if (!end_stmt) return;
    
    char *start = strchr(p, '<');
    char *end = strchr(p, '>');
    
    // Bounds check
    if (!start || !end) return;
    if (start > end_stmt || end > end_stmt) return;
    
    // Construct new value string
    char new_str[64];
    sprintf(new_str, "<0x%llx>", new_val);
    int new_len = strlen(new_str);
    int old_len = end - start + 1;
    
    // Shift memory if lengths differ
    int shift = new_len - old_len;
    if (shift != 0) {
        memmove(end + 1 + shift, end + 1, strlen(end + 1) + 1);
    }
    
    // Copy new value
    memcpy(start, new_str, new_len);
}

void update_prop_hex_or_str(char *content, const char *prop_name, unsigned long long new_val) {
    char search_str[256];
    sprintf(search_str, "%s =", prop_name);
    char *p = strstr(content, search_str);
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
void replace_prop_line_u64(char *content, const char *prop_name, unsigned long long new_val) {
    char search_str[256];
    sprintf(search_str, "%s =", prop_name);
    char *p = strstr(content, search_str);
    if (!p) return;
    
    // Find line start (previous \n or start of string)
    char *line_start = p;
    while (line_start > content && *(line_start - 1) != '\n') {
        line_start--;
    }
    
    // Find line end (after ;)
    char *line_end = strchr(p, ';');
    if (!line_end) return;
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
}

// Get raw property string value (e.g. "<0x123>" or "\"B`0\"")
// Returns 1 if found, 0 otherwise
int get_prop_val_str(const char *content, const char *prop_name, char *out_val) {
    char search_str[256];
    sprintf(search_str, "%s =", prop_name);
    char *p = strstr(content, search_str);
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
void update_prop_val_str(char *content, const char *prop_name, const char *new_val) {
    char search_str[256];
    sprintf(search_str, "%s =", prop_name);
    char *p = strstr(content, search_str);
    if (!p) return;
    
    char *end_stmt = strchr(p, ';');
    if (!end_stmt) return;
    
    char *val_start = strchr(p, '=');
    if (!val_start) return;
    val_start++; // skip =
    
    while (val_start < end_stmt && isspace(*val_start)) val_start++;
    
    int old_len = end_stmt - val_start;
    int new_len = strlen(new_val);
    
    int shift = new_len - old_len;
    if (shift != 0) {
        memmove(end_stmt + shift, end_stmt, strlen(end_stmt) + 1);
    }
    memcpy(val_start, new_val, new_len);
}

#define TARGET_PANEL "qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02"

// Check if current position is inside the target panel node
int is_inside_target_panel(const char *file_start, const char *current_pos) {
    // Search backwards for the last opened brace that hasn't been closed
    // This is a simple heuristic: find the nearest "qcom,..." node definition above
    
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
                
                if (strstr(node_name, TARGET_PANEL)) {
                    return 1; // Found it!
                }
                
                // If we hit another timing node or unrelated node, keep searching up?
                // Actually, the panel node is usually the direct parent or grandparent.
                // Let's assume structure: panel_node { ... timing_node { ... } ... }
                // If we found a node that is NOT the target, but has { ... }, 
                // we might be inside a sibling of timing node, or the timing node itself.
                // But this function is called at the start of a timing node.
                // So the nearest '{' above 'timing@...' should be the panel node opening.
                
                // Heuristic: If it starts with "qcom,mdss_dsi_panel_", it's a panel node.
                if (strstr(node_name, "qcom,mdss_dsi_panel_")) {
                    return 0; // It's a different panel
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

    char temp_path[512];
    snprintf(temp_path, sizeof(temp_path), "%s/%s.tmp", DIR_NAME, filename);
    FILE *out = fopen(temp_path, "w");
    if (!out) {
        perror("Cannot create temp file");
        free(buffer);
        return;
    }

    // Pass 1: Find Templates (WQHD 144Hz, FHD 120/144Hz)
    TimingNode template_wqhd = {0};
    TimingNode template_fhd = {0};
    
    char *p = buffer;
    while ((p = strstr(p, "timing@"))) {
        char *block_start = p;
        char *block_end = strchr(block_start, '}');
        if (!block_end) break;
        block_end = strchr(block_end, ';'); // };
        if (!block_end) break;
        block_end++; // Include ;
        
        // Check if inside target panel
        if (!is_inside_target_panel(buffer, block_start)) {
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
        
        // Check for WQHD 144
        if (strstr(node_name, "wqhd_sdc_144")) {
            strncpy(template_wqhd.content, block_start, len);
            template_wqhd.content[len] = 0;
            template_wqhd.clock = get_prop_u64(template_wqhd.content, "qcom,mdss-dsi-panel-clockrate");
            template_wqhd.fps = get_prop_u64(template_wqhd.content, "qcom,mdss-dsi-panel-framerate");
            template_wqhd.transfer_time = get_prop_u64(template_wqhd.content, "qcom,mdss-mdp-transfer-time-us");
            template_wqhd.valid = 1;
            printf("Found WQHD Template: %s (Clock: 0x%llx)\n", node_name, template_wqhd.clock);
        }
        
        // Check for FHD (Prioritize 144, then 120)
        if (strstr(node_name, "fhd_sdc_144") || strstr(node_name, "fhd_sdc_120")) {
             int current_fps = get_prop_u64(block_start, "qcom,mdss-dsi-panel-framerate");
             if (current_fps > template_fhd.fps) {
                 strncpy(template_fhd.content, block_start, len);
                 template_fhd.content[len] = 0;
                 template_fhd.clock = get_prop_u64(template_fhd.content, "qcom,mdss-dsi-panel-clockrate");
                 template_fhd.fps = current_fps;
                 template_fhd.transfer_time = get_prop_u64(template_fhd.content, "qcom,mdss-mdp-transfer-time-us");
                 template_fhd.valid = 1;
                 printf("Found FHD Template: %s (FPS: %d)\n", node_name, template_fhd.fps);
             }
        }
        
        p = block_end;
    }

    // Pass 2: Process and Write
    p = buffer;
    char *cursor = buffer;
    
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

        // FILTER: Only process if inside TARGET_PANEL
        // We look for templates everywhere (to get the right 144Hz config), 
        // but we only APPLY changes to the target panel.
        // Wait, templates might come from other panels too? 
        // Assuming templates are universal or we use the ones found in file.
        // The previous template search (Pass 1) scans the whole file.
        
        // For Pass 2 (Modification), check context:
        if (!is_inside_target_panel(buffer, block_start)) {
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
        // 2. LTPO Fix for 60Hz (FHD) - "1080p DPI Fix"
        /*
        else if (strstr(node_name, "fhd_sdc_60")) {
            printf("Applying LTPO Fix to %s (Using WQHD Template + FHD Resolution)\n", node_name);
            
            // Extract raw values
            char orig_index_str[64] = {0};
            char orig_width_str[64] = {0};
            char orig_height_str[64] = {0};
            
            get_prop_val_str(current_block, "cell-index", orig_index_str);
            get_prop_val_str(current_block, "qcom,mdss-dsi-panel-width", orig_width_str);
            get_prop_val_str(current_block, "qcom,mdss-dsi-panel-height", orig_height_str);
            
            // MUST use WQHD Template as base (to get 2K clock/transfer)
            if (template_wqhd.valid) {
                char new_block[MAX_BLOCK];
                strcpy(new_block, template_wqhd.content);
                
                // Replace name safely
                char template_name[128];
                sscanf(template_wqhd.content, "%127s", template_name);
                char search_str[128];
                sprintf(search_str, "%s {", template_name);
                replace_str(new_block, search_str, "timing@fhd_sdc_60 {");
                
                // 1. Restore FHD Resolution
                if (strlen(orig_width_str) > 0) update_prop_val_str(new_block, "qcom,mdss-dsi-panel-width", orig_width_str);
                if (strlen(orig_height_str) > 0) update_prop_val_str(new_block, "qcom,mdss-dsi-panel-height", orig_height_str);
                
                // 2. Restore cell-index
                if (strlen(orig_index_str) > 0) update_prop_val_str(new_block, "cell-index", orig_index_str);
                
                // 3. Force Framerate 60
                replace_prop_line_u64(new_block, "qcom,mdss-dsi-panel-framerate", 60);
                
                fputs(new_block, out);
                fputs("\n", out);
            } else {
                // Fallback if no WQHD template (shouldn't happen based on reqs)
                printf("Warning: No WQHD template found for FHD fix!\n");
                fputs(current_block, out);
            }
        }
        */
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
            // Just write original
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
                    process_file(dir->d_name);
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
