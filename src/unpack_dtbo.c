#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <ctype.h>

#define MAX_PATH 1024

void trim(char *s);
void extract_avb_info(const char *image_path);

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

    // Extract AVB Info
    extract_avb_info(input_img);

    return 0;
}

void trim(char *s) {
    char *p = s;
    int l = strlen(p);

    while(l > 0 && isspace(p[l - 1])) p[--l] = 0;
    while(*p && isspace(*p)) p++;

    memmove(s, p, l + 1);
}

void extract_avb_info(const char *image_path) {
    printf("步骤3: 提取AVB信息...\n");
    
    // Ensure avbtool is executable
    system("chmod +x ./avbtool/avbtool");
    
    char cmd[MAX_PATH * 2];
    snprintf(cmd, sizeof(cmd), "export LD_LIBRARY_PATH=$PWD/avbtool:$LD_LIBRARY_PATH && ./avbtool/avbtool info_image --image \"%s\" > avb_info.tmp", image_path);
    
    if (system(cmd) != 0) {
        printf("警告: 提取AVB信息失败，可能不是AVB签名的镜像或avbtool缺失。\n");
        return;
    }
    
    FILE *in = fopen("avb_info.tmp", "r");
    if (!in) {
        printf("警告: 无法读取临时AVB信息文件。\n");
        return;
    }
    
    FILE *out = fopen("dtbo_dts/avb_info.cfg", "w");
    if (!out) {
        printf("警告: 无法创建配置文件 dtbo_dts/avb_info.cfg\n");
        fclose(in);
        return;
    }
    
    char line[1024];
    
    // Get actual file size of the input image to use as PARTITION_SIZE
    struct stat st;
    if (stat(image_path, &st) == 0) {
        fprintf(out, "PARTITION_SIZE=%lld\n", (long long)st.st_size);
    } else {
        printf("警告: 无法获取文件大小，PARTITION_SIZE可能不正确。\n");
    }

    while (fgets(line, sizeof(line), in)) {
        // Simple parsing logic based on avbtool output format
        if (strstr(line, "Original image size:")) {
            // Ignore Original image size from avbtool, use file size instead
            continue;
        }
        else if (strstr(line, "Hash Algorithm:")) {
            char *p = strchr(line, ':');
            if (p) { trim(p+1); fprintf(out, "HASH_ALG=%s\n", p + 1); }
        }
        else if (strstr(line, "Partition Name:")) {
            char *p = strchr(line, ':');
            if (p) { trim(p+1); fprintf(out, "PARTITION_NAME=%s\n", p + 1); }
        }
        else if (strstr(line, "Salt:")) {
            char *p = strchr(line, ':');
            if (p) { trim(p+1); fprintf(out, "SALT=%s\n", p + 1); }
        }
        else if (strstr(line, "Algorithm:")) {
            char *p = strchr(line, ':');
            if (p) { trim(p+1); fprintf(out, "ALGORITHM=%s\n", p + 1); }
        }
        else if (strstr(line, "Rollback Index:")) {
            char *p = strchr(line, ':');
            if (p) { trim(p+1); fprintf(out, "ROLLBACK_INDEX=%s\n", p + 1); }
        }
        else if (strstr(line, "Release String:")) {
            char *p = strchr(line, ':');
            if (p) {
                char *val = p + 1;
                trim(val);
                // Remove single quotes
                if (val[0] == '\'') val++;
                int len = strlen(val);
                if (len > 0 && val[len-1] == '\'') val[len-1] = 0;
                fprintf(out, "RELEASE_STRING=%s\n", val);
            }
        }
        else if (strstr(line, "Prop:")) {
            char *p = strchr(line, ':');
            if (p) { trim(p+1); fprintf(out, "PROP=%s\n", p + 1); }
        }
    }
    
    fclose(in);
    fclose(out);
    remove("avb_info.tmp");
    printf("AVB信息已保存至 dtbo_dts/avb_info.cfg\n");
}
