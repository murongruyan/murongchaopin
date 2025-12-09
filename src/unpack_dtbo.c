#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

#define MAX_PATH 1024

int is_file_exist(const char *path) {
    return access(path, F_OK) == 0;
}

void ensure_dir(const char *path) {
    struct stat st = {0};
    if (stat(path, &st) == -1) {
        #ifdef _WIN32
        mkdir(path);
        #else
        mkdir(path, 0755);
        #endif
    }
}

int main(int argc, char *argv[]) {
    char input_img[MAX_PATH] = "./dtbo.img";
    
    // 如果提供了参数，使用参数作为输入文件路径
    if (argc > 1) {
        strncpy(input_img, argv[1], MAX_PATH - 1);
    }

    printf("开始解包DTBO镜像...\n");
    printf("输入文件: %s\n", input_img);

    if (!is_file_exist(input_img)) {
        printf("错误: 找不到输入文件 %s\n", input_img);
        return 1;
    }
    if (!is_file_exist("./dtc")) {
        printf("错误: 找不到 ./dtc 工具\n");
        return 1;
    }
    if (!is_file_exist("./mkdtimg")) {
        printf("错误: 找不到 ./mkdtimg 工具\n");
        return 1;
    }

    // 创建输出目录
    ensure_dir("dtbo_dts");

    printf("步骤1: 解包DTBO镜像...\n");
    // 使用 dtb_temp 前缀，生成 dtb_temp.0, dtb_temp.1 等
    char dump_cmd[MAX_PATH * 2];
    snprintf(dump_cmd, sizeof(dump_cmd), "./mkdtimg dump \"%s\" -b ./dtb_temp", input_img);
    
    if (system(dump_cmd) != 0) {
        printf("错误: 解包DTBO失败\n");
        return 1;
    }

    printf("步骤2: 转换DTB为DTS (输出到 dtbo_dts 目录)...\n");
    DIR *d = opendir(".");
    if (!d) {
        perror("无法打开当前目录");
        return 1;
    }

    struct dirent *dir;
    char cmd[MAX_PATH * 2];
    int count = 0;

    while ((dir = readdir(d)) != NULL) {
        if (strncmp(dir->d_name, "dtb_temp.", 9) == 0) {
            char dts_name[MAX_PATH];
            // Output to dtbo_dts directory
            snprintf(dts_name, sizeof(dts_name), "dtbo_dts/%s.dts", dir->d_name);
            
            printf("转换: %s -> %s\n", dir->d_name, dts_name);
            snprintf(cmd, sizeof(cmd), "./dtc -I dtb -O dts -o \"%s\" \"%s\"", dts_name, dir->d_name);
            
            if (system(cmd) != 0) {
                printf("警告: 转换 %s 失败\n", dir->d_name);
            } else {
                count++;
                // 转换成功后删除临时dtb文件
                remove(dir->d_name);
            }
        }
    }
    closedir(d);

    printf("解包完成!\n");
    printf("总共生成 %d 个DTS文件，保存在 dtbo_dts 目录中\n", count);
    return 0;
}
