#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>

#define MAX_LINE 4096
#define MAX_BLOCK 65536
#define DIR_NAME "dtbo_dts"

// 检查是否是普通文件
int is_regular_file(const char *path) {
    struct stat path_stat;
    stat(path, &path_stat);
    return S_ISREG(path_stat.st_mode);
}

// 简单的字符串替换函数 (只替换第一次出现)
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

// 处理单个文件
void process_file(const char *filename) {
    char input_path[512];
    snprintf(input_path, sizeof(input_path), "%s/%s", DIR_NAME, filename);

    printf("正在处理文件: %s\n", input_path);

    FILE *in = fopen(input_path, "r");
    if (!in) {
        perror("无法打开文件");
        return;
    }

    char temp_path[512];
    snprintf(temp_path, sizeof(temp_path), "%s/%s.tmp", DIR_NAME, filename);
    FILE *out = fopen(temp_path, "w");
    if (!out) {
        perror("无法创建临时文件");
        fclose(in);
        return;
    }

    char line[MAX_LINE];
    int in_panel = 0;
    int panel_depth = 0;
    
    // 用于保存60Hz的cell-index
    char cell_index_60[64] = "";
    // 用于保存144Hz的内容 (以防60Hz在144Hz之后出现)
    char content_144[MAX_BLOCK] = "";

    while (fgets(line, sizeof(line), in)) {
        // 检查是否进入指定的panel块
        if (strstr(line, "qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02 {")) {
            in_panel = 1;
            panel_depth = 1;
            fputs(line, out);
            continue;
        }

        if (in_panel == 0) {
            fputs(line, out);
            continue;
        }

        // 在panel块中，精确跟踪深度
        if (strstr(line, "{")) {
            panel_depth++;
        } else if (strstr(line, "}")) {
            panel_depth--;
        }

        if (panel_depth == 0 && strstr(line, "}")) {
            in_panel = 0;
            fputs(line, out);
            continue;
        }

        // 检查 timing@wqhd_sdc_60 (删除并记录index)
        if (strstr(line, "timing@wqhd_sdc_60 {")) {
            printf("Found 60Hz node, removing and saving index...\n");
            
            char timing_line[MAX_LINE];
            int timing_depth = 1;

            while (fgets(timing_line, sizeof(timing_line), in)) {
                // Extract cell-index
                char *idx_ptr = strstr(timing_line, "cell-index = <");
                if (idx_ptr) {
                    char *end_ptr = strstr(idx_ptr, ">;");
                    if (end_ptr) {
                        size_t len = end_ptr - idx_ptr + 2;
                        if (len < sizeof(cell_index_60)) {
                            strncpy(cell_index_60, idx_ptr, len);
                            cell_index_60[len] = '\0';
                        }
                    }
                }

                if (strstr(timing_line, "{")) {
                    timing_depth++;
                } else if (strstr(timing_line, "}")) {
                    timing_depth--;
                }

                if (timing_depth == 0 && strstr(timing_line, "};")) {
                    break;
                }
            }

            // 如果已经读取过144Hz的内容，则在这里生成新的60Hz节点
            if (strlen(content_144) > 0) {
                char new_60[MAX_BLOCK];
                strcpy(new_60, content_144);
                
                replace_str(new_60, "timing@wqhd_sdc_144 {", "timing@wqhd_sdc_60 {");
                
                // 查找144Hz中的cell-index并替换为60Hz的
                char *idx_144_start = strstr(content_144, "cell-index = <");
                if (idx_144_start) {
                    char *idx_144_end = strstr(idx_144_start, ">;");
                    if (idx_144_end) {
                         char orig_index_str[64];
                         size_t len = idx_144_end - idx_144_start + 2;
                         strncpy(orig_index_str, idx_144_start, len);
                         orig_index_str[len] = '\0';
                         replace_str(new_60, orig_index_str, cell_index_60);
                    }
                }
                
                replace_str(new_60, "qcom,mdss-dsi-panel-framerate = <0x90>;", "qcom,mdss-dsi-panel-framerate = <0x3c>;");
                fputs(new_60, out);
                fputs("\n", out);
            }
            continue; // Skip writing original 60Hz to output
        }

        // 检查 timing@wqhd_sdc_120
        if (strstr(line, "timing@wqhd_sdc_120 {")) {
            fputs(line, out); // 输出原始行

            // 读取整个timing块
            char timing_content[MAX_BLOCK];
            strcpy(timing_content, line);
            
            char timing_line[MAX_LINE];
            int timing_depth = 1;

            while (fgets(timing_line, sizeof(timing_line), in)) {
                strcat(timing_content, timing_line);
                fputs(timing_line, out); // 输出原始内容

                if (strstr(timing_line, "{")) {
                    timing_depth++;
                } else if (strstr(timing_line, "}")) {
                    timing_depth--;
                }

                if (timing_depth == 0 && strstr(timing_line, "};")) {
                    break;
                }
            }
            
            fputs("\n", out); // 空行

            // 创建123版本
            char new_123[MAX_BLOCK];
            strcpy(new_123, timing_content);
            replace_str(new_123, "timing@wqhd_sdc_120 {", "timing@wqhd_sdc_123 {");
            replace_str(new_123, "cell-index = <0x0>;", "cell-index = <0x8>;");
            replace_str(new_123, "qcom,mdss-dsi-panel-clockrate = <0x568bc300>;", "qcom,mdss-dsi-panel-clockrate = <0x5a68d300>;");
            replace_str(new_123, "qcom,mdss-dsi-panel-framerate = <0x78>;", "qcom,mdss-dsi-panel-framerate = <0x7b>;");
            
            fputs(new_123, out);
            fputs("\n", out);
            continue;
        }

        // 检查 timing@wqhd_sdc_144
        if (strstr(line, "timing@wqhd_sdc_144 {")) {
            fputs(line, out);

            char timing_content[MAX_BLOCK];
            strcpy(timing_content, line);
            
            char timing_line[MAX_LINE];
            int timing_depth = 1;

            while (fgets(timing_line, sizeof(timing_line), in)) {
                strcat(timing_content, timing_line);
                fputs(timing_line, out);

                if (strstr(timing_line, "{")) {
                    timing_depth++;
                } else if (strstr(timing_line, "}")) {
                    timing_depth--;
                }

                if (timing_depth == 0 && strstr(timing_line, "};")) {
                    break;
                }
            }
            
            // 保存144Hz的内容，供60Hz逻辑使用
            strcpy(content_144, timing_content);

            // 如果之前已经遇到了60Hz节点（记录了index），则现在生成新的60Hz节点
            if (strlen(cell_index_60) > 0) {
                 char new_60[MAX_BLOCK];
                strcpy(new_60, timing_content);
                
                replace_str(new_60, "timing@wqhd_sdc_144 {", "timing@wqhd_sdc_60 {");
                
                char *idx_144_start = strstr(timing_content, "cell-index = <");
                if (idx_144_start) {
                    char *idx_144_end = strstr(idx_144_start, ">;");
                    if (idx_144_end) {
                         char orig_index_str[64];
                         size_t len = idx_144_end - idx_144_start + 2;
                         strncpy(orig_index_str, idx_144_start, len);
                         orig_index_str[len] = '\0';
                         replace_str(new_60, orig_index_str, cell_index_60);
                    }
                }
                
                replace_str(new_60, "qcom,mdss-dsi-panel-framerate = <0x90>;", "qcom,mdss-dsi-panel-framerate = <0x3c>;");
                fputs(new_60, out);
                fputs("\n", out);
            }

            fputs("\n", out);

            // 定义频率和对应的cell-index
            int freqs[] = {150, 155, 160, 165, 170, 175, 180};
            const char *indexes[] = {"0x9", "0x10", "0x11", "0x12", "0x13", "0x14", "0x15"};
            
            // 基础参数 (144Hz)
            unsigned long long base_clock = 0x568bc300;
            unsigned int base_transfer_time = 0x1a90; // 6800 us

            for (int i = 0; i < 7; i++) {
                int freq = freqs[i];
                
                // 计算新的时钟频率
                unsigned long long new_clock = base_clock * freq / 144;
                char clock_hex[32];
                sprintf(clock_hex, "0x%llx", new_clock);
                
                // 计算新的 Framerate (hex)
                char freq_hex[32];
                sprintf(freq_hex, "0x%x", freq);

                // 计算新的 Transfer Time
                // 公式: time = base_time * base_freq / new_freq
                unsigned int new_transfer_time = base_transfer_time * 144 / freq;
                char transfer_time_hex[32];
                sprintf(transfer_time_hex, "0x%x", new_transfer_time);

                char new_content[MAX_BLOCK];
                strcpy(new_content, timing_content);
                
                char replace_str_buf[64];
                
                // Replace name
                sprintf(replace_str_buf, "timing@wqhd_sdc_%d {", freq);
                replace_str(new_content, "timing@wqhd_sdc_144 {", replace_str_buf);
                
                // Replace cell-index
                sprintf(replace_str_buf, "cell-index = <%s>;", indexes[i]);
                replace_str(new_content, "cell-index = <0x3>;", replace_str_buf);
                
                // Replace clockrate
                sprintf(replace_str_buf, "qcom,mdss-dsi-panel-clockrate = <%s>;", clock_hex);
                replace_str(new_content, "qcom,mdss-dsi-panel-clockrate = <0x568bc300>;", replace_str_buf);
                
                // Replace framerate
                sprintf(replace_str_buf, "qcom,mdss-dsi-panel-framerate = <%s>;", freq_hex);
                replace_str(new_content, "qcom,mdss-dsi-panel-framerate = <0x90>;", replace_str_buf);

                // Replace transfer-time (Added as per request)
                // 只有当原文包含该行时才会替换
                sprintf(replace_str_buf, "qcom,mdss-mdp-transfer-time-us = <%s>;", transfer_time_hex);
                replace_str(new_content, "qcom,mdss-mdp-transfer-time-us = <0x1a90>;", replace_str_buf);
                
                fputs(new_content, out);
                fputs("\n", out);
            }
            continue;
        }

        fputs(line, out);
    }

    fclose(in);
    fclose(out);

    if (rename(temp_path, input_path) != 0) {
        perror("无法替换原文件");
        // 如果rename失败（例如跨文件系统），尝试复制后删除
        // 这里简化处理，直接报错
    } else {
        printf("文件 %s 处理完成\n", filename);
    }
}

int main() {
    DIR *d;
    struct dirent *dir;
    
    // 打开 dtbo_dts 目录
    d = opendir(DIR_NAME);
    if (d) {
        while ((dir = readdir(d)) != NULL) {
            // 简单的后缀检查
            char *dot = strrchr(dir->d_name, '.');
            if (dot && strcmp(dot, ".dts") == 0) {
                // 确保是普通文件（在某些系统上 d_type 可能不可用，最好用 stat）
                char full_path[512];
                snprintf(full_path, sizeof(full_path), "%s/%s", DIR_NAME, dir->d_name);
                if (is_regular_file(full_path)) {
                    process_file(dir->d_name);
                }
            }
        }
        closedir(d);
    } else {
        printf("无法打开目录 %s (请确保先运行解包脚本)\n", DIR_NAME);
        return 1;
    }
    printf("所有文件处理完成！\n");
    return 0;
}
