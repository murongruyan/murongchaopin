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
#include <errno.h>

#define MAX_MODES 50
#define MAX_APPS 200
#define MAX_PKG_LEN 128

typedef struct {
    int id;
    int fps;
    int width;
    int height;
} DisplayMode;

typedef struct {
    char package[MAX_PKG_LEN];
    int mode_id;
} AppConfig;

DisplayMode modes[MAX_MODES];
int mode_count = 0;

AppConfig app_configs[MAX_APPS];
int app_config_count = 0;
int default_mode_id = 1;

int current_mode_id = -1;

// Function Prototypes
void set_surface_flinger(int id);
void sync_android_settings(int id);
int get_mode_width(int id);
void get_sorted_fps_modes(int width, int *out_ids, int *out_count);
int is_valid_mode(int id);

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

// 解析 dumpsys SurfaceFlinger 获取模式
void init_display_modes() {
    FILE *fp;
    char line[1024];
    
    // 直接读取 dumpsys SurfaceFlinger 输出，手动解析以提高兼容性
    fp = popen("dumpsys SurfaceFlinger", "r");
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
        log_msg("ID: %d, FPS: %d, Res: %dx%d", modes[i].id, modes[i].fps, modes[i].width, modes[i].height);
    }
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
            // 第一行：全局默认ID
            default_mode_id = atoi(trimmed);
        } else {
            // 后续行：包名 模式ID
            // 支持 pkg=id 或 pkg id 格式
            char *eq = strchr(trimmed, '=');
            if (eq) *eq = ' '; // 将等号替换为空格以便 sscanf 解析

            char pkg[MAX_PKG_LEN];
            int mid;
            if (sscanf(trimmed, "%s %d", pkg, &mid) == 2) {
                if (app_config_count < MAX_APPS) {
                    strncpy(app_configs[app_config_count].package, pkg, MAX_PKG_LEN);
                    app_configs[app_config_count].mode_id = mid;
                    app_config_count++;
                }
            }
        }
    }
    fclose(fp);
    log_msg("Config loaded / 配置已加载. Default: %d, Apps: %d", default_mode_id, app_config_count);
}

// 获取当前系统模式ID
int get_current_system_mode() {
    // 匹配 HWC 输出的当前活动配置
    // HWC 通常不直接标记 "mActiveMode"，我们需要找到 config=... 或类似的
    // 但 service call 需要的 ID 就是 HWC ID
    // 简单起见，我们假设 dumpsys SurfaceFlinger 中 activeConfig=ID
    // 或者直接返回 -1 让 smooth_switch 初始化
    
    // 尝试解析 dumpsys SurfaceFlinger | grep "activeConfig"
    // 示例: activeConfig=0
    FILE *fp = popen("dumpsys SurfaceFlinger | grep \"activeConfig=\"", "r");
    if (fp) {
        char line[64];
        if (fgets(line, sizeof(line), fp)) {
            int id;
            if (sscanf(line, "activeConfig=%d", &id) == 1) {
                pclose(fp);
                // 此时获取的是 config ID (即 HWC ID)
                // 我们的 modes[i].id 也是 HWC ID，所以直接返回
                return id;
            }
        }
        pclose(fp);
    }
    
    // 如果找不到 activeConfig，尝试旧方法或直接返回 -1
    // 旧方法: dumpsys display | grep mActiveMode (针对 Android Framework 层 ID)
    // 注意：Framework ID = HWC ID + 1 (通常)
    // 如果我们现在全面转为 HWC ID，则需要小心
    
    return -1;
}

// 平滑切换核心逻辑
void smooth_switch(int target_id) {
    if (current_mode_id == -1) {
        // 首次启动，尝试获取当前系统状态
        int actual = get_current_system_mode();
        if (actual != -1) {
            current_mode_id = actual;
            log_msg("Initialized current mode from system / 从系统初始化当前模式: %d", current_mode_id);
        } else {
            // 获取失败，直接设置并假设成功
            log_msg("First switch (unknown current) / 首次切换 (当前未知): -> %d", target_id);
            set_surface_flinger(target_id);
            sync_android_settings(target_id);
            current_mode_id = target_id;
            return;
        }
    }

    if (current_mode_id == target_id) return;
    
    int current_width = get_mode_width(current_mode_id);
    int target_width = get_mode_width(target_id);
    
    // 如果无法获取宽度（无效ID），直接切换
    if (current_width == 0 || target_width == 0) {
        log_msg("Invalid width / 无效宽度 (curr=%d, target=%d). Direct switch / 直接切换.", current_width, target_width);
        set_surface_flinger(target_id);
        sync_android_settings(target_id);
        current_mode_id = target_id;
        return;
    }

    if (current_width != target_width) {
        log_msg("Resolution change / 分辨率变更: %d -> %d. Direct switch / 直接切换.", current_mode_id, target_id);
        set_surface_flinger(target_id);
        sync_android_settings(target_id);
        current_mode_id = target_id;
        return;
    }

    log_msg("Smooth Switch / 平滑切换: %d -> %d", current_mode_id, target_id);

    // 获取按 FPS 排序的模式列表
    int sorted_ids[MAX_MODES];
    int count = 0;
    get_sorted_fps_modes(target_width, sorted_ids, &count);
    
    // 查找当前和目标在排序列表中的位置
    int idx_curr = -1;
    int idx_target = -1;
    
    for (int i=0; i<count; i++) {
        if (sorted_ids[i] == current_mode_id) idx_curr = i;
        if (sorted_ids[i] == target_id) idx_target = i;
    }
    
    if (idx_curr == -1) {
        log_msg("Current mode %d not in sorted list / 当前模式不在排序列表中. Direct switch / 直接切换.", current_mode_id);
        set_surface_flinger(target_id);
        sync_android_settings(target_id);
        current_mode_id = target_id;
        return;
    }
    
    if (idx_target == -1) {
        log_msg("Target mode %d not in sorted list / 目标模式不在排序列表中. Direct switch / 直接切换.", target_id);
        set_surface_flinger(target_id);
        sync_android_settings(target_id);
        current_mode_id = target_id;
        return;
    }
    
    // 逐步切换
    if (idx_target > idx_curr) {
        // 升频: current -> target
        for (int i = idx_curr + 1; i <= idx_target; i++) {
            log_msg("Step UP / 升频: %d", sorted_ids[i]); 
            set_surface_flinger(sorted_ids[i]);
            usleep(50000); // 50ms
        }
    } else {
        // 降频: current -> target
        for (int i = idx_curr - 1; i >= idx_target; i--) {
            log_msg("Step DOWN / 降频: %d", sorted_ids[i]); 
            set_surface_flinger(sorted_ids[i]);
            usleep(50000); // 50ms
        }
    }
    
    current_mode_id = target_id;
    sync_android_settings(target_id);
}

// 获取前台应用 (使用用户提供的优化逻辑)
void get_foreground_app(char *buffer, int size) {
    // 优先尝试 dumpsys window | grep mCurrentFocus
    FILE* fp = popen("dumpsys window | grep mCurrentFocus", "r");
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

// 执行 SurfaceFlinger 调用
void set_surface_flinger(int id) {
    char cmd[64];
    // 现在的 ID 直接来自 HWC (dumpsys SurfaceFlinger)，不需要 -1
    // service call SurfaceFlinger 1035 i32 <HWC_ID>
    int sf_id = id; 
    
    snprintf(cmd, sizeof(cmd), "service call SurfaceFlinger 1035 i32 %d > /dev/null", sf_id);
    system(cmd);
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
        snprintf(cmd, sizeof(cmd), 
            "settings put secure support_highfps 1;"
            "settings put system peak_refresh_rate %d;"
            "settings put system user_refresh_rate %d;"
            "settings put system min_refresh_rate %d;"
            "settings put system default_refresh_rate %d;"
            "settings put global debug.cpurend.vsync true;"
            "settings put global hwui.disable_vsync false",
            fps, fps, fps, fps);
        system(cmd);
        log_msg("Synced system settings to %dHz / 已同步系统设置到 %dHz", fps, fps);
    }
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



int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s <module_path>\n", argv[0]);
        return 1;
    }
    
    char *base_path = argv[1];
    printf("Rate Daemon started. Path: %s\n", base_path);
    
    // 1. 初始化
    init_display_modes();
    if (mode_count == 0) {
        printf("Error: No display modes found.\n");
        // 如果失败，尝试稍后重试或退出
        return 1;
    }

    // 2. 初始加载配置
    load_config(base_path);
    
    // 3. 初始设置
    if (is_valid_mode(default_mode_id)) {
        smooth_switch(default_mode_id);
    } else {
        if (mode_count > 0) {
            default_mode_id = modes[0].id;
            smooth_switch(default_mode_id);
        }
    }

    char last_pkg[MAX_PKG_LEN] = "";
    
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
        // 使用 select 实现 "等待事件 或 超时"
        if (inotify_fd >= 0) {
            fd_set fds;
            FD_ZERO(&fds);
            FD_SET(inotify_fd, &fds);

            struct timeval timeout;
            timeout.tv_sec = 1;  // 1秒超时，用于检查前台应用
            timeout.tv_usec = 0;

            int ret = select(inotify_fd + 1, &fds, NULL, NULL, &timeout);

            if (ret > 0 && FD_ISSET(inotify_fd, &fds)) {
                // 有文件变化事件
                char buffer[1024];
                // 读取事件以清空缓冲区
                int len = read(inotify_fd, buffer, sizeof(buffer));
                // 只要有变动就重载配置 (简单粗暴但有效)
                // 实际生产中可以解析 buffer 里的 struct inotify_event 检查是否是 mode.txt
                // 但这里目录里没别的东西，直接重载也没问题
                if (len > 0) {
                    log_msg("Config change detected via inotify / 检测到配置变更.");
                    load_config(base_path);
                    // 稍微延时一点点，防止文件写入未完成
                    usleep(10000); 
                }
            }
            // 如果 ret == 0 (超时)，则继续执行下方的应用检查
        } else {
            // 降级模式：简单的 sleep
            sleep(1);
            // 只有在轮询模式下才需要定时检查配置
            static time_t last_config_check = 0;
            time_t now = time(NULL);
            if (now - last_config_check > 5) {
                load_config(base_path);
                last_config_check = now;
            }
        }

        // 获取前台应用
        char current_pkg[MAX_PKG_LEN] = "";
        get_foreground_app(current_pkg, sizeof(current_pkg));

        if (strlen(current_pkg) > 0) {
            // 记录应用切换
            if (strcmp(current_pkg, last_pkg) != 0) {
                 log_msg("Detected App Change / 检测到应用切换: %s", current_pkg);
                 strncpy(last_pkg, current_pkg, MAX_PKG_LEN);
            }

            // 总是检查是否需要切换，因为可能配置变了但应用没变
            int target_id = default_mode_id;
            for (int i=0; i<app_config_count; i++) {
                if (strcmp(app_configs[i].package, current_pkg) == 0) {
                    target_id = app_configs[i].mode_id;
                    break;
                }
            }
            
                if (is_valid_mode(target_id) && target_id != current_mode_id) {
                     smooth_switch(target_id);
                }
            
        }
    }
    // while loop end
    
    // Cleanup (unreachable usually)
    if (inotify_fd >= 0) close(inotify_fd);
    
    return 0;
}
