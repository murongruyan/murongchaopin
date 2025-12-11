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
    
    p = strchr(p, '<');
    if (!p) return 0;
    p++; // skip <
    
    unsigned long long val = 0;
    // Handle hex and decimal
    while(isspace(*p)) p++;
    
    if (strstr(p, "0x") == p || strstr(p, "0X") == p) {
        sscanf(p, "%llx", &val);
    } else {
        sscanf(p, "%lld", &val);
    }
    return val;
}

// Helper to update a property in the content string (Safe In-Place Update)
void update_prop_u64(char *content, const char *prop_name, unsigned long long new_val) {
    char search_str[256];
    sprintf(search_str, "%s =", prop_name);
    char *p = strstr(content, search_str);
    if (!p) return;
    
    char *start = strchr(p, '<');
    char *end = strchr(p, '>');
    if (!start || !end) return;
    
    // Construct new value string
    char new_str[64];
    sprintf(new_str, "<0x%llx>", new_val);
    int new_len = strlen(new_str);
    int old_len = end - start + 1;
    
    // Shift memory if lengths differ
    int shift = new_len - old_len;
    if (shift != 0) {
        // Check buffer bounds? We assume MAX_BLOCK is enough.
        // memmove handles overlapping regions safely
        memmove(end + 1 + shift, end + 1, strlen(end + 1) + 1);
    }
    
    // Copy new value
    memcpy(start, new_str, new_len);
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
        
        // Logic Dispatch
        
        // 1. LTPO Fix for 60Hz (WQHD)
        if (strstr(node_name, "wqhd_sdc_60") && template_wqhd.valid) {
            printf("Applying LTPO Fix to %s\n", node_name);
            unsigned int orig_idx = get_prop_u64(current_block, "cell-index");
            
            // Start with template
            char new_block[MAX_BLOCK];
            strcpy(new_block, template_wqhd.content);
            
            // Replace name safely
            char template_name[128];
            sscanf(template_wqhd.content, "%127s", template_name); 
            char search_str[128];
            sprintf(search_str, "%s {", template_name);
            replace_str(new_block, search_str, "timing@wqhd_sdc_60 {");
            
            // Calculate new params
            unsigned long long new_clock = template_wqhd.clock * 60 / template_wqhd.fps;
            unsigned int new_transfer = template_wqhd.transfer_time * template_wqhd.fps / 60;
            
            update_prop_u64(new_block, "qcom,mdss-dsi-panel-clockrate", new_clock);
            update_prop_u64(new_block, "qcom,mdss-dsi-panel-framerate", 60); 
            update_prop_u64(new_block, "qcom,mdss-mdp-transfer-time-us", new_transfer);
            update_prop_u64(new_block, "cell-index", orig_idx); 
            
            fputs(new_block, out);
            fputs("\n", out);
        }
        // 2. LTPO Fix for 60Hz (FHD) - "1080p DPI Fix"
        else if (strstr(node_name, "fhd_sdc_60") && template_fhd.valid) {
            printf("Applying LTPO Fix to %s\n", node_name);
            unsigned int orig_idx = get_prop_u64(current_block, "cell-index");
            
            char new_block[MAX_BLOCK];
            strcpy(new_block, template_fhd.content);
            
            char template_name[128];
            sscanf(template_fhd.content, "%127s", template_name);
            char search_str[128];
            sprintf(search_str, "%s {", template_name);
            replace_str(new_block, search_str, "timing@fhd_sdc_60 {");
            
            unsigned long long new_clock = template_fhd.clock * 60 / template_fhd.fps;
            unsigned int new_transfer = template_fhd.transfer_time * template_fhd.fps / 60;
            
            update_prop_u64(new_block, "qcom,mdss-dsi-panel-clockrate", new_clock);
            update_prop_u64(new_block, "qcom,mdss-dsi-panel-framerate", 60);
            update_prop_u64(new_block, "qcom,mdss-mdp-transfer-time-us", new_transfer);
            update_prop_u64(new_block, "cell-index", orig_idx);
            
            fputs(new_block, out);
            fputs("\n", out);
        }
        // 3. WQHD 120Hz -> Add 123Hz (Auto Calc)
        else if (strstr(node_name, "wqhd_sdc_120")) {
            // Write original
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
            
            fputs(new_block, out);
            fputs("\n", out);
        }
        // 4. WQHD 144Hz -> Add 150-180Hz (Auto Calc)
        else if (strstr(node_name, "wqhd_sdc_144")) {
            // Write original
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
                    
                    fputs(new_block, out);
                    fputs("\n", out);
                }
            }
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
