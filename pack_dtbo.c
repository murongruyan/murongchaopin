#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>

#define MAX_CMD 131072 // 128KB for command line
#define MAX_PATH 1024
#define INPUT_DIR "dtbo_dts"

int is_file_exist(const char *path) {
    return access(path, F_OK) == 0;
}

int main() {
    printf("开始打包DTBO镜像...\n");

    // 检查工具
    if (!is_file_exist("./dtc")) {
        printf("错误: 找不到 ./dtc 工具\n");
        return 1;
    }
    if (!is_file_exist("./mkdtimg")) {
        printf("错误: 找不到 ./mkdtimg 工具\n");
        return 1;
    }

    DIR *d;
    struct dirent *dir;
    char mkdtimg_cmd[MAX_CMD];
    snprintf(mkdtimg_cmd, sizeof(mkdtimg_cmd), "./mkdtimg create new_dtbo.img");

    d = opendir(INPUT_DIR);
    if (!d) {
        printf("错误: 无法打开目录 %s\n", INPUT_DIR);
        return 1;
    }

    int dtb_count = 0;
    char cmd[MAX_PATH * 2];

    printf("步骤1: 编译DTS为DTB...\n");

    while ((dir = readdir(d)) != NULL) {
        char *dot = strrchr(dir->d_name, '.');
        if (dot && strcmp(dot, ".dts") == 0) {
            char base_name[MAX_PATH];
            strncpy(base_name, dir->d_name, dot - dir->d_name);
            base_name[dot - dir->d_name] = '\0';

            // DTB 生成在当前目录
            char dtb_name[MAX_PATH];
            snprintf(dtb_name, sizeof(dtb_name), "%s.dtb", base_name);
            
            // DTS 路径
            char dts_path[MAX_PATH];
            snprintf(dts_path, sizeof(dts_path), "%s/%s", INPUT_DIR, dir->d_name);

            printf("编译: %s -> %s\n", dts_path, dtb_name);
            
            snprintf(cmd, sizeof(cmd), "./dtc -I dts -O dtb -o \"%s\" \"%s\"", dtb_name, dts_path);
            if (system(cmd) != 0) {
                printf("错误: 编译 %s 失败\n", dir->d_name);
                closedir(d);
                return 1;
            }

            // Append to mkdtimg command
            strncat(mkdtimg_cmd, " \"", sizeof(mkdtimg_cmd) - strlen(mkdtimg_cmd) - 1);
            strncat(mkdtimg_cmd, dtb_name, sizeof(mkdtimg_cmd) - strlen(mkdtimg_cmd) - 1);
            strncat(mkdtimg_cmd, "\"", sizeof(mkdtimg_cmd) - strlen(mkdtimg_cmd) - 1);
            dtb_count++;
        }
    }
    closedir(d);

    if (dtb_count == 0) {
        printf("错误: 没有找到DTS文件\n");
        return 1;
    }

    printf("步骤2: 打包DTB文件为DTBO镜像...\n");
    if (system(mkdtimg_cmd) != 0) {
        printf("错误: 打包DTBO失败\n");
        return 1;
    }

    printf("打包成功! 输出文件: new_dtbo.img\n");

    // 清理DTB文件
    printf("清理临时DTB文件...\n");
    // 我们只清理刚才生成的那些dtb
    // 由于我们不知道之前是否有名为 .dtb 的文件，最好只清理我们编译的。
    // 这里简单地重新扫描一遍 dts 目录来确定要删除哪些 dtb
    d = opendir(INPUT_DIR);
    if (d) {
        while ((dir = readdir(d)) != NULL) {
            char *dot = strrchr(dir->d_name, '.');
            if (dot && strcmp(dot, ".dts") == 0) {
                char base_name[MAX_PATH];
                strncpy(base_name, dir->d_name, dot - dir->d_name);
                base_name[dot - dir->d_name] = '\0';
                
                char dtb_name[MAX_PATH];
                snprintf(dtb_name, sizeof(dtb_name), "%s.dtb", base_name);
                remove(dtb_name);
            }
        }
        closedir(d);
    }

    printf("完成!\n");
    return 0;
}
