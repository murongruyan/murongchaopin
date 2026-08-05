#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <ctype.h>

#define MAX_LINE 4096
#define MAX_BLOCK 131072 // 128KB
#define DIR_NAME "dtbo_dts"

// Utils
int is_regular_file(const char *path) {
    struct stat path_stat;
    stat(path, &path_stat);
    return S_ISREG(path_stat.st_mode);
}

void replace_str(char *str, const char *orig, const char *rep) {
    char buffer[MAX_BLOCK];
    char *p;
    if (!(p = strstr(str, orig))) return;
    strncpy(buffer, str, p - str);
    buffer[p - str] = '\0';
    sprintf(buffer + (p - str), "%s%s", rep, p + strlen(orig));
    strcpy(str, buffer);
}

unsigned long long parse_hex_or_dec(const char *str) {
    if (strstr(str, "0x") || strstr(str, "0X")) {
        return strtoull(str, NULL, 16);
    }
    return strtoull(str, NULL, 10);
}

// Helper: Check if line starts a panel definition
// Matches "qcom,mdss_dsi_panel_..."
int is_panel_start(const char *line) {
    // Explicitly ignore engineering panels
    if (strstr(line, "_evt")) return 0;

    if (strstr(line, "qcom,mdss_dsi_panel_")) return 1;
    // Also support hyphens just in case
    if (strstr(line, "qcom,mdss-dsi-panel-")) return 1;
    return 0;
}

// Helper: Extract panel name from line
void extract_panel_name(const char *line, char *buffer) {
    const char *start = strstr(line, "qcom,mdss");
    if (!start) {
        buffer[0] = '\0';
        return;
    }
    
    // Find end of name (space, :, {, or newline)
    const char *p = start;
    while (*p && !isspace((unsigned char)*p) && *p != ':' && *p != '{') {
        p++;
    }
    
    int len = p - start;
    strncpy(buffer, start, len);
    buffer[len] = '\0';
}

// Helper: Check if file contains matching project-id
int check_project_id(const char *filepath, const char *target_id_str) {
    if (!target_id_str || strlen(target_id_str) == 0) return 1; // No check needed
    
    unsigned long long target_id = parse_hex_or_dec(target_id_str);
    FILE *fp = fopen(filepath, "r");
    if (!fp) return 0;
    
    char line[MAX_LINE];
    int matched = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        if (strstr(line, "oplus,project-id")) {
            char *start = strchr(line, '<');
            if (start) {
                start++;
                char *end = strchr(start, '>');
                if (end) {
                    *end = '\0';
                    char *token = strtok(start, " ");
                    while (token) {
                        unsigned long long id = parse_hex_or_dec(token);
                        if (id == target_id) {
                            matched = 1;
                            break;
                        }
                        token = strtok(NULL, " ");
                    }
                }
            }
        }
        if (matched) break;
    }
    
    fclose(fp);
    return matched;
}

typedef struct {
    char file[256];
    char node[256];
    unsigned long long fps;
    unsigned long long clock;
    unsigned long long transfer;
} NodeInfo;

// ---- Command: SCAN ----
void cmd_scan(const char *target_panel, const char *project_id) {
    DIR *d;
    struct dirent *dir;
    char path[512];
    FILE *fp;
    char line[MAX_LINE];
    
    NodeInfo nodes[512];
    int node_count = 0;
    int has_2k = 0;
    int scanned_any = 0;

    d = opendir(DIR_NAME);
    if (!d) {
        d = opendir(".");
    }

    if (d) {
        while ((dir = readdir(d)) != NULL) {
            if (!strstr(dir->d_name, ".dts")) continue;
            
            snprintf(path, sizeof(path), "%s/%s", DIR_NAME, dir->d_name);
            if (access(path, F_OK) != 0) snprintf(path, sizeof(path), "%s", dir->d_name);

            // Project ID Check
            if (!check_project_id(path, project_id)) {
                continue;
            }
            
            // Only scan one valid DTS file
            if (scanned_any) {
                 continue;
            }

            fp = fopen(path, "r");
            if (!fp) continue;

            char current_node[256] = "";
            unsigned long long fps = 0;
            unsigned long long clock = 0;
            unsigned long long transfer = 0;
            int in_timing = 0;
            int timing_brace_depth = 0;
            
            // Filtering vars
            int in_panel = 0;
            int panel_brace_depth = 0;

            while (fgets(line, sizeof(line), fp)) {
                // Check for Panel Block Entry
                if (!in_panel && is_panel_start(line)) {
                    if (target_panel && strlen(target_panel) > 0) {
                        char panel_name[256];
                        extract_panel_name(line, panel_name);
                        if (strcmp(panel_name, target_panel) != 0) {
                            // Skip this panel if it doesn't match target
                            continue;
                        }
                    }
                    in_panel = 1;
                    panel_brace_depth = 0;
                }

                // Track Panel Block Braces
                if (in_panel) {
                    char *p = line;
                    while (*p) {
                        if (*p == '{') panel_brace_depth++;
                        if (*p == '}') panel_brace_depth--;
                        p++;
                    }
                    
                    // If we closed the panel block
                    if (panel_brace_depth <= 0 && strstr(line, "};")) {
                        in_panel = 0;
                    }
                }

                // Only scan timings if inside panel
                if (in_panel) {
                    if (strstr(line, "timing@")) {
                        char *start = strstr(line, "timing@");
                        char *end = start + strlen("timing@");
                        
                        // Find end of node name (space, {, or newline)
                        while (*end && !isspace((unsigned char)*end) && *end != '{') {
                            end++;
                        }
                        
                        if (end > start) {
                            int len = end - start;
                            if (len >= sizeof(current_node)) len = sizeof(current_node) - 1;
                            strncpy(current_node, start, len);
                            current_node[len] = '\0';
                            
                            in_timing = 1;
                            timing_brace_depth = 0;
                            fps = 0; clock = 0; transfer = 0;
                        }
                    }

                    if (in_timing) {
                        char *p = line;
                        while (*p) {
                            if (*p == '{') timing_brace_depth++;
                            if (*p == '}') timing_brace_depth--;
                            p++;
                        }

                        char *val_start;
                        if ((val_start = strstr(line, "qcom,mdss-dsi-panel-framerate"))) {
                            char *v = strchr(val_start, '<');
                            if (v) fps = parse_hex_or_dec(v + 1);
                        }
                        if ((val_start = strstr(line, "qcom,mdss-dsi-panel-clockrate"))) {
                            char *v = strchr(val_start, '<');
                            if (v) clock = parse_hex_or_dec(v + 1);
                        }
                        if ((val_start = strstr(line, "qcom,mdss-mdp-transfer-time-us"))) {
                            char *v = strchr(val_start, '<');
                            if (v) transfer = parse_hex_or_dec(v + 1);
                        }

                        if (timing_brace_depth == 0 && strstr(line, "};")) {
                            // Filter 1: Only show standard display modes (WQHD/FHD/QHD) to avoid AOD/Test nodes
                            int is_display_mode = 0;
                            if (strstr(current_node, "wqhd") || strstr(current_node, "fhd") || strstr(current_node, "qhd")) {
                                is_display_mode = 1;
                            }

                            // Filter 2: Exclude low FPS (<48Hz)
                            if (is_display_mode && fps >= 48) {
                                if (node_count < 512) {
                                    strncpy(nodes[node_count].file, dir->d_name, 255);
                                    strncpy(nodes[node_count].node, current_node, 255);
                                    nodes[node_count].fps = fps;
                                    nodes[node_count].clock = clock;
                                    nodes[node_count].transfer = transfer;
                                    
                                    if (strstr(current_node, "wqhd") || strstr(current_node, "qhd")) {
                                        has_2k = 1;
                                    }
                                    node_count++;
                                }
                            }
                            
                            in_timing = 0;
                        }
                    }
                }
            }
            fclose(fp);
            scanned_any = 1;
        }
        closedir(d);
    }
    
    // Output JSON
    printf("[\n");
    int first = 1;
    for (int i = 0; i < node_count; i++) {
        int is_fhd = (strstr(nodes[i].node, "fhd") != NULL);
        
        // If 2K exists, hide FHD
        if (has_2k && is_fhd) {
            continue;
        }
        
        if (!first) printf(",\n");
        printf("  {\"file\": \"%s\", \"node\": \"%s\", \"fps\": %llu, \"clock\": %llu, \"transfer\": %llu}",
               nodes[i].file, nodes[i].node, nodes[i].fps, nodes[i].clock, nodes[i].transfer);
        first = 0;
    }
    printf("\n]\n");
}

void cmd_remove(const char *target_node, const char *target_panel, const char *project_id) {
    DIR *d;
    struct dirent *dir;
    char path[512];
    char temp_path[512];
    
    d = opendir(DIR_NAME);
    if (!d) d = opendir(".");

    if (d) {
        while ((dir = readdir(d)) != NULL) {
            if (!strstr(dir->d_name, ".dts")) continue;
            
            snprintf(path, sizeof(path), "%s/%s", DIR_NAME, dir->d_name);
            if (access(path, F_OK) != 0) snprintf(path, sizeof(path), "%s", dir->d_name);
            
            // Project ID Check
            if (!check_project_id(path, project_id)) {
                continue;
            }

            snprintf(temp_path, sizeof(temp_path), "%s.tmp", path);

            FILE *in = fopen(path, "r");
            FILE *out = fopen(temp_path, "w");
            if (!in || !out) continue;

            char line[MAX_LINE];
            int skipping = 0;
            int brace_depth = 0; 
            int modified = 0;
            
            // Scope filtering
            int in_panel = 0;
            int panel_brace_depth = 0;
            int panel_matched = 1; // Default to match if no target_panel
            int current_index = 0;

            while (fgets(line, sizeof(line), in)) {
                if (!in_panel && is_panel_start(line)) {
                    if (target_panel && strlen(target_panel) > 0) {
                        char panel_name[256];
                        extract_panel_name(line, panel_name);
                        if (strcmp(panel_name, target_panel) != 0) {
                            panel_matched = 0;
                        } else {
                            panel_matched = 1;
                        }
                    } else {
                        panel_matched = 1;
                    }

                    in_panel = 1;
                    panel_brace_depth = 0;
                    current_index = 0;
                }

                if (in_panel) {
                    char *p = line;
                    while (*p) {
                        if (*p == '{') panel_brace_depth++;
                        if (*p == '}') panel_brace_depth--;
                        p++;
                    }
                    if (panel_brace_depth <= 0 && strstr(line, "};")) {
                        in_panel = 0;
                        panel_matched = 0; // Reset match status outside panel
                    }
                }

                if (!skipping) {
                    int match = 0;
                    // Only match nodes if we are inside the CORRECT panel
                    if (in_panel && panel_matched) {
                        char *loc = strstr(line, target_node);
                        if (loc) {
                            char *after = loc + strlen(target_node);
                            int is_valid_end = 0;
                            while (*after && isspace((unsigned char)*after)) after++;
                            if (*after == '{' || *after == '\0' || *after == '\r' || *after == '\n') {
                                is_valid_end = 1;
                            }
                            if (is_valid_end) {
                                match = 1;
                            }
                        }
                    }

                    if (match) {
                        skipping = 1;
                        brace_depth = 0;
                        char *p = line;
                        while (*p) {
                            if (*p == '{') brace_depth++;
                            if (*p == '}') brace_depth--;
                            p++;
                        }
                        if (brace_depth <= 0 && strstr(line, "};")) {
                            skipping = 0; 
                        }
                        modified = 1;
                        printf("Removing node: %s from %s (Panel Match: Yes)\n", target_node, dir->d_name);
                        continue; 
                    }
                    
                    // Re-indexing logic for REMOVE
                    if (in_panel && panel_matched && strstr(line, "cell-index")) {
                        char *start = strchr(line, '<');
                        if (start) {
                            char *end = strchr(start, '>');
                            if (end) {
                                *end = '\0';
                                char prefix[MAX_LINE];
                                strncpy(prefix, line, start - line + 1);
                                prefix[start - line + 1] = '\0';
                                
                                char suffix[MAX_LINE];
                                strcpy(suffix, end + 1);
                                
                                fprintf(out, "%s0x%x>%s", prefix, current_index++, suffix);
                                continue; 
                            }
                        }
                    }
                } else {
                    char *p = line;
                    while (*p) {
                        if (*p == '{') brace_depth++;
                        if (*p == '}') brace_depth--;
                        p++;
                    }
                    if (brace_depth <= 0 && strstr(line, "};")) {
                        skipping = 0;
                    }
                    continue; 
                }

                fputs(line, out);
            }

            fclose(in);
            fclose(out);

            if (modified) {
                remove(path); 
                rename(temp_path, path);
            } else {
                remove(temp_path);
            }
        }
        closedir(d);
    }
}

// ---- Command: ADD (Internal) ----
// custom_clock / custom_transfer 为可选参数：>0 时覆盖自动计算（自定义优先），
// 否则沿用自动计算预设（base_clock*target/base_fps、base_transfer*base_fps/target_fps）。
void internal_add_node(const char *filename, const char *base_node, int target_fps, const char *target_panel,
                       unsigned long long custom_clock, unsigned long long custom_transfer) {
    char path[512];
    char temp_path[512];
    snprintf(path, sizeof(path), "%s/%s", DIR_NAME, filename);
    if (access(path, F_OK) != 0) snprintf(path, sizeof(path), "%s", filename);
    snprintf(temp_path, sizeof(temp_path), "%s.tmp", path);

    FILE *in = fopen(path, "r");
    if (!in) return;

    // 1. Capture Base Node Content
    char base_content[MAX_BLOCK] = "";
    unsigned long long base_clock = 0;
    unsigned long long base_transfer = 0;
    unsigned long long base_fps = 0;
    
    char line[MAX_LINE];
    int capturing = 0;
    int brace_depth = 0;
    int found_base = 0;
    
    int in_panel = 0;
    int panel_brace_depth = 0;
    int panel_matched = 1;

    int target_exists = 0;
    char target_node_name[128];
    
    // Predict target node name based on base_node
    strcpy(target_node_name, base_node);
    char *last_underscore = strrchr(target_node_name, '_');
    if (last_underscore) {
        sprintf(last_underscore + 1, "%d", target_fps);
    } else {
        sprintf(target_node_name, "%s_%d", base_node, target_fps);
    }

    // Pre-check for existence
    FILE *pre_check = fopen(path, "r");
    if (pre_check) {
        char pre_buf[MAX_LINE];
        while (fgets(pre_buf, sizeof(pre_buf), pre_check)) {
             if (strstr(pre_buf, "timing@") && strstr(pre_buf, target_node_name)) {
                 target_exists = 1;
                 break;
             }
        }
        fclose(pre_check);
    }

    if (target_exists) {
        printf("Skipping: %s already exists in %s\n", target_node_name, filename);
        fclose(in);
        return;
    }

    while (fgets(line, sizeof(line), in)) {
        if (!in_panel && is_panel_start(line)) {
            if (target_panel && strlen(target_panel) > 0) {
                char panel_name[256];
                extract_panel_name(line, panel_name);
                if (strcmp(panel_name, target_panel) != 0) {
                    panel_matched = 0;
                } else {
                    panel_matched = 1;
                }
            } else {
                panel_matched = 1;
            }

            in_panel = 1;
            panel_brace_depth = 0;
        }

        if (in_panel) {
            char *p = line;
            while (*p) {
                if (*p == '{') panel_brace_depth++;
                if (*p == '}') panel_brace_depth--;
                p++;
            }
            if (panel_brace_depth <= 0 && strstr(line, "};")) {
                in_panel = 0;
                panel_matched = 0;
            }
        }
        
        // Only process if we are in the correct panel
        if (in_panel && panel_matched) {
            if (strstr(line, base_node)) {
                char *loc = strstr(line, base_node);
                 if (loc) {
                     char *after = loc + strlen(base_node);
                     while (*after && isspace((unsigned char)*after)) after++;
                     if (*after == '{' || *after == '\0' || *after == '\r' || *after == '\n') {
                         capturing = 1;
                         found_base = 1;
                         
                         // Fix target node name to match base node pattern
                         strcpy(target_node_name, base_node);
                         char *last_underscore = strrchr(target_node_name, '_');
                         if (last_underscore) {
                             sprintf(last_underscore + 1, "%d", target_fps);
                         } else {
                             // Fallback
                             sprintf(target_node_name, "%s_%d", base_node, target_fps);
                         }
                     }
                 }
            }
        }
        
        if (capturing) {
            if (strlen(base_content) + strlen(line) < MAX_BLOCK) {
                strcat(base_content, line);
            }
            
            char *p = line;
            while (*p) {
                if (*p == '{') brace_depth++;
                if (*p == '}') brace_depth--;
                p++;
            }

            char *val;
            if ((val = strstr(line, "qcom,mdss-dsi-panel-framerate"))) {
                char *v = strchr(val, '<'); if(v) base_fps = parse_hex_or_dec(v+1);
            }
            if ((val = strstr(line, "qcom,mdss-dsi-panel-clockrate"))) {
                char *v = strchr(val, '<'); if(v) base_clock = parse_hex_or_dec(v+1);
            }
            if ((val = strstr(line, "qcom,mdss-mdp-transfer-time-us"))) {
                char *v = strchr(val, '<'); if(v) base_transfer = parse_hex_or_dec(v+1);
            }

            if (brace_depth <= 0 && strstr(line, "};")) {
                capturing = 0;
            }
        }
    }
    rewind(in); 

    if (!found_base) {
        // printf("Error: Base node %s not found in %s (or wrong panel)\n", base_node, filename);
        fclose(in);
        remove(temp_path);
        return;
    }

    // 2. Write new file with appended node
    FILE *out = fopen(temp_path, "w");
    if (!out) { fclose(in); return; }

    int inserted = 0;
    in_panel = 0;
    panel_brace_depth = 0;
    panel_matched = 1;
    
    int in_base_node = 0;
    int base_node_brace_depth = 0;
    int current_index = 0;

    while (fgets(line, sizeof(line), in)) {
        if (!in_panel && is_panel_start(line)) {
            if (target_panel && strlen(target_panel) > 0) {
                char panel_name[256];
                extract_panel_name(line, panel_name);
                if (strcmp(panel_name, target_panel) != 0) {
                    panel_matched = 0;
                } else {
                    panel_matched = 1;
                }
            } else {
                panel_matched = 1;
            }

            in_panel = 1;
            panel_brace_depth = 0;
            current_index = 0;
        }

        if (in_panel) {
            char *p = line;
            while (*p) {
                if (*p == '{') panel_brace_depth++;
                if (*p == '}') panel_brace_depth--;
                p++;
            }
            if (panel_brace_depth <= 0 && strstr(line, "};")) {
                in_panel = 0;
                // panel_matched reset below
            }
        }

        // Auto-sort cell-index for existing nodes
        if (in_panel && panel_matched && strstr(line, "cell-index")) {
            char *start = strchr(line, '<');
            if (start) {
                char *end = strchr(start, '>');
                if (end) {
                    *end = '\0';
                    char prefix[MAX_LINE];
                    strncpy(prefix, line, start - line + 1);
                    prefix[start - line + 1] = '\0';
                    
                    char suffix[MAX_LINE];
                    strcpy(suffix, end + 1);
                    
                    fprintf(out, "%s0x%x>%s", prefix, current_index++, suffix);
                    
                    // Logic to insert AFTER the base node closes (check if this was the base node's cell-index - usually inside node)
                    // We handle insertion check below
                    // BUT we must continue to skip fputs
                    goto check_insertion;
                }
            }
        }

        fputs(line, out);

check_insertion:
        // Logic to insert AFTER the base node closes
        if (in_panel && panel_matched && !inserted && found_base) {
            if (!in_base_node) {
                 if (strstr(line, base_node)) {
                     char *loc = strstr(line, base_node);
                     char *after = loc + strlen(base_node);
                     while (*after && isspace((unsigned char)*after)) after++;
                     if (*after == '{' || *after == '\0' || *after == '\r' || *after == '\n') {
                         in_base_node = 1;
                         base_node_brace_depth = 0;
                     }
                 }
            }
            
            if (in_base_node) {
                 char *p = line;
                 while (*p) {
                     if (*p == '{') base_node_brace_depth++;
                     if (*p == '}') base_node_brace_depth--;
                     p++;
                 }
                 
                 if (base_node_brace_depth <= 0 && strstr(line, "};")) {
                    // Base node closed. Insert new node here.
                    
                    // Generate New Node Content
                    replace_str(base_content, base_node, target_node_name);
                    
                    // Calc new values：自定义参数覆盖自动计算
                    if (base_fps > 0) {
                        unsigned long long new_clock;
                        unsigned long long new_transfer;
                        if (custom_clock > 0) {
                            new_clock = custom_clock;
                        } else {
                            new_clock = base_clock * target_fps / base_fps;
                        }
                        if (custom_transfer > 0) {
                            new_transfer = custom_transfer;
                        } else {
                            new_transfer = base_transfer * base_fps / target_fps;
                        }
                        
                        // Line-by-line replacement for safety and correctness
                        char *ptr = base_content;
                        char new_block[MAX_BLOCK] = "";
                        char line_buf[MAX_LINE];
                        
                        while (ptr && *ptr) {
                            char *eol = strchr(ptr, '\n');
                            int len;
                            if (eol) {
                                len = eol - ptr + 1;
                            } else {
                                len = strlen(ptr);
                            }
                            
                            strncpy(line_buf, ptr, len);
                            line_buf[len] = '\0';
                            
                            // Check for keys to replace
                            if (strstr(line_buf, "qcom,mdss-dsi-panel-clockrate")) {
                                char *start = strchr(line_buf, '<');
                                if (start) {
                                    char *end = strchr(start, '>');
                                    if (end) {
                                        *end = '\0';
                                        char prefix[MAX_LINE];
                                        strncpy(prefix, line_buf, start - line_buf + 1);
                                        prefix[start - line_buf + 1] = '\0';
                                        
                                        char suffix[MAX_LINE];
                                        strcpy(suffix, end + 1);
                                        
                                        sprintf(line_buf, "%s%llu>%s", prefix, new_clock, suffix);
                                    }
                                }
                            } else if (strstr(line_buf, "qcom,mdss-dsi-panel-framerate")) {
                                char *start = strchr(line_buf, '<');
                                if (start) {
                                    char *end = strchr(start, '>');
                                    if (end) {
                                        *end = '\0';
                                        char prefix[MAX_LINE];
                                        strncpy(prefix, line_buf, start - line_buf + 1);
                                        prefix[start - line_buf + 1] = '\0';
                                        
                                        char suffix[MAX_LINE];
                                        strcpy(suffix, end + 1);
                                        
                                        sprintf(line_buf, "%s0x%x>%s", prefix, target_fps, suffix);
                                    }
                                }
                            } else if (strstr(line_buf, "qcom,mdss-mdp-transfer-time-us")) {
                                char *start = strchr(line_buf, '<');
                                if (start) {
                                    char *end = strchr(start, '>');
                                    if (end) {
                                        *end = '\0';
                                        char prefix[MAX_LINE];
                                        strncpy(prefix, line_buf, start - line_buf + 1);
                                        prefix[start - line_buf + 1] = '\0';
                                        
                                        char suffix[MAX_LINE];
                                        strcpy(suffix, end + 1);
                                        
                                        sprintf(line_buf, "%s%llu>%s", prefix, new_transfer, suffix);
                                    }
                                }
                            } else if (strstr(line_buf, "cell-index")) {
                                // Already handled? No, we need to handle it here too for the new node content
                                char *start = strchr(line_buf, '<');
                                if (start) {
                                    char *end = strchr(start, '>');
                                    if (end) {
                                        *end = '\0';
                                        char prefix[MAX_LINE];
                                        strncpy(prefix, line_buf, start - line_buf + 1);
                                        prefix[start - line_buf + 1] = '\0';
                                        
                                        char suffix[MAX_LINE];
                                        strcpy(suffix, end + 1);
                                        
                                        sprintf(line_buf, "%s0x%x>%s", prefix, current_index++, suffix);
                                    }
                                }
                            }

                            strcat(new_block, line_buf);
                            
                            if (eol) ptr = eol + 1;
                            else break;
                        }
                        strcpy(base_content, new_block);
                    }
                    
                    fprintf(out, "\n%s", base_content);
                    inserted = 1;
                    printf("Added node %s (%dHz) to %s (Panel Match: Yes)\n", target_node_name, target_fps, filename);
                    
                    in_base_node = 0;
                 }
            }
        }
    }
    
    fclose(in);
    fclose(out);
    
    remove(path);
    rename(temp_path, path);
}


void cmd_add(const char *base_node, int target_fps, const char *target_panel, const char *project_id,
             unsigned long long custom_clock, unsigned long long custom_transfer) {
    DIR *d;
    struct dirent *dir;
    char path[512];
    d = opendir(DIR_NAME);
    if (!d) d = opendir(".");
    if (d) {
        while ((dir = readdir(d)) != NULL) {
            if (!strstr(dir->d_name, ".dts")) continue;
            snprintf(path, sizeof(path), "%s/%s", DIR_NAME, dir->d_name);
            if (access(path, F_OK) != 0) snprintf(path, sizeof(path), "%s", dir->d_name);
            
            // Project ID Check
            if (!check_project_id(path, project_id)) {
                continue;
            }
            
            internal_add_node(dir->d_name, base_node, target_fps, target_panel, custom_clock, custom_transfer);
        }

        closedir(d);
    }
}

// ---- Command: SMART ADD ----
void cmd_smart_add(int target_fps, const char *target_panel, const char *project_id,
                   unsigned long long custom_clock, unsigned long long custom_transfer) {
    // 1. Scan for best base node
    DIR *d;
    struct dirent *dir;
    char path[512];
    
    char best_base_node[128] = "";
    unsigned long long best_diff = 999999;
    char best_file[256] = "";

    d = opendir(DIR_NAME);
    if (!d) d = opendir(".");
    if (d) {
        while ((dir = readdir(d)) != NULL) {
            if (!strstr(dir->d_name, ".dts")) continue;
            snprintf(path, sizeof(path), "%s/%s", DIR_NAME, dir->d_name);
            if (access(path, F_OK) != 0) snprintf(path, sizeof(path), "%s", dir->d_name);
            
            // Project ID Check
            if (!check_project_id(path, project_id)) {
                continue;
            }
            
            FILE *fp = fopen(path, "r");
            if (!fp) continue;
            
            char line[MAX_LINE];
            int in_panel = 0;
            int panel_brace_depth = 0;
            int in_timing = 0;
            int timing_brace_depth = 0;
            char current_node[256];
            unsigned long long fps = 0;
            int panel_matched = 1;

            while (fgets(line, sizeof(line), fp)) {
                if (!in_panel && is_panel_start(line)) {
                    if (target_panel && strlen(target_panel) > 0) {
                        char panel_name[256];
                        extract_panel_name(line, panel_name);
                        if (strcmp(panel_name, target_panel) != 0) {
                            panel_matched = 0;
                        } else {
                            panel_matched = 1;
                        }
                    } else {
                        panel_matched = 1;
                    }

                    in_panel = 1;
                    panel_brace_depth = 0;
                }
                
                if (in_panel) {
                    char *p = line;
                    while (*p) {
                        if (*p == '{') panel_brace_depth++;
                        if (*p == '}') panel_brace_depth--;
                        p++;
                    }
                    if (panel_brace_depth <= 0 && strstr(line, "};")) {
                        in_panel = 0;
                        panel_matched = 0;
                    }
                }
                
                // Only scan timings if in correct panel
                if (in_panel && panel_matched) {
                     if (strstr(line, "timing@")) {
                        char *start = strstr(line, "timing@");
                        char *end = start + strlen("timing@");
                        while (*end && !isspace((unsigned char)*end) && *end != '{') end++;
                        if (end > start) {
                            int len = end - start;
                            if (len >= sizeof(current_node)) len = sizeof(current_node) - 1;
                            strncpy(current_node, start, len);
                            current_node[len] = '\0';
                            
                            in_timing = 1;
                            timing_brace_depth = 0;
                            fps = 0;
                        }
                    }

                    if (in_timing) {
                        char *p = line;
                        while (*p) {
                            if (*p == '{') timing_brace_depth++;
                            if (*p == '}') timing_brace_depth--;
                            p++;
                        }
                        
                        char *val_start;
                        if ((val_start = strstr(line, "qcom,mdss-dsi-panel-framerate"))) {
                            char *v = strchr(val_start, '<');
                            if (v) fps = parse_hex_or_dec(v + 1);
                        }
                        
                        if (timing_brace_depth == 0 && strstr(line, "};")) {
                            // Candidate found
                            if (fps > 0) {
                                long long diff = (long long)fps - target_fps;
                                if (diff < 0) diff = -diff;
                                
                                // Prefer WQHD/FHD nodes
                                // int bonus = 0;
                                // if (strstr(current_node, "wqhd")) bonus = 50;
                                // if (strstr(current_node, "fhd")) bonus = 30;
                                
                                // Heuristic: Find closest FPS, prefer standard nodes
                                if (diff < best_diff) { // Simple logic for now
                                    best_diff = diff;
                                    strcpy(best_base_node, current_node);
                                    strcpy(best_file, dir->d_name);
                                }
                            }
                            in_timing = 0;
                        }
                    }
                }
            }
            fclose(fp);
        }
        closedir(d);
    }
    
    if (strlen(best_base_node) > 0) {
        printf("Smart Add: Best base node %s found in %s\n", best_base_node, best_file);
        
        // Apply to ALL matching files, not just the best file
        // Re-scan directory to find all matching files and apply
        DIR *d2 = opendir(DIR_NAME);
        if (!d2) d2 = opendir(".");
        if (d2) {
            struct dirent *dir2;
            char path2[512];
            while ((dir2 = readdir(d2)) != NULL) {
                if (!strstr(dir2->d_name, ".dts")) continue;
                snprintf(path2, sizeof(path2), "%s/%s", DIR_NAME, dir2->d_name);
                if (access(path2, F_OK) != 0) snprintf(path2, sizeof(path2), "%s", dir2->d_name);
                
                if (check_project_id(path2, project_id)) {
                    internal_add_node(dir2->d_name, best_base_node, target_fps, target_panel, custom_clock, custom_transfer);
                }
            }
            closedir(d2);
        }
    } else {
        printf("Smart Add: No suitable base node found.\n");
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s <command> [args]\n", argv[0]);
        printf("Commands:\n");
        printf("  scan [target_panel] [project_id]\n");
        printf("  add <base_node> <fps> [target_panel] [project_id] [clock] [transfer]\n");
        printf("  smart_add <fps> [target_panel] [project_id] [clock] [transfer]\n");
        printf("  remove <node_name> [target_panel] [project_id]\n");
        return 1;
    }

    if (strcmp(argv[1], "scan") == 0) {
        const char *panel = (argc >= 3) ? argv[2] : NULL;
        const char *prj = (argc >= 4) ? argv[3] : NULL;
        cmd_scan(panel, prj);
    } else if (strcmp(argv[1], "add") == 0) {
        if (argc < 4) {
            printf("Usage: add <base_node> <fps> [target_panel] [project_id] [clock] [transfer]\n");
            return 1;
        }
        const char *panel = (argc >= 5) ? argv[4] : NULL;
        const char *prj = (argc >= 6) ? argv[5] : NULL;
        unsigned long long cclock = (argc >= 7 && argv[6][0]) ? strtoull(argv[6], NULL, 10) : 0;
        unsigned long long ctransfer = (argc >= 8 && argv[7][0]) ? strtoull(argv[7], NULL, 10) : 0;
        cmd_add(argv[2], atoi(argv[3]), panel, prj, cclock, ctransfer);
    } else if (strcmp(argv[1], "smart_add") == 0) {
        if (argc < 3) {
            printf("Usage: smart_add <fps> [target_panel] [project_id] [clock] [transfer]\n");
            return 1;
        }
        const char *panel = (argc >= 4) ? argv[3] : NULL;
        const char *prj = (argc >= 5) ? argv[4] : NULL;
        unsigned long long cclock = (argc >= 6 && argv[5][0]) ? strtoull(argv[5], NULL, 10) : 0;
        unsigned long long ctransfer = (argc >= 7 && argv[6][0]) ? strtoull(argv[6], NULL, 10) : 0;
        cmd_smart_add(atoi(argv[2]), panel, prj, cclock, ctransfer);
    } else if (strcmp(argv[1], "remove") == 0) {
        if (argc < 3) {
            printf("Usage: remove <node_name> [target_panel] [project_id]\n");
            return 1;
        }
        const char *panel = (argc >= 4) ? argv[3] : NULL;
        const char *prj = (argc >= 5) ? argv[4] : NULL;
        cmd_remove(argv[2], panel, prj);
    } else {
        printf("Unknown command: %s\n", argv[1]);
        return 1;
    }

    return 0;
}
