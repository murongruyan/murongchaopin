#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>

#define MAX_CMD 131072 // 128KB for command line
#define MAX_PATH 1024
#define INPUT_DIR "dtbo_dts"

void load_avb_config(char *partition_size, char *hash_alg, char *partition_name, 
                     char *salt, char *algorithm, char *rollback_index, 
                     char *release_string, char *prop);

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

    // AVB is applied later by scripts/dtbo_avb.sh using official metadata.
    // Keep the legacy block unreachable for source compatibility.
    if (0) {
    char partition_size[64] = "0";
    char hash_alg[64] = "";
    char partition_name[64] = "";
    char salt[256] = "";
    char algorithm[64] = "";
    char rollback_index[64] = "";
    char release_string[256] = "";
    char prop[1024] = "";
    
    load_avb_config(partition_size, hash_alg, partition_name, salt, algorithm, rollback_index, release_string, prop);
    
    if (strlen(algorithm) > 0) {
        printf("步骤3: 添加AVB签名...\n");
        
        // Ensure avbtool is executable
        system("chmod +x ./avbtool/avbtool");
        system("chmod +x ./openssl");

        // Key generation logic
        char key_file[256] = "";
        char gen_cmd[MAX_PATH];
        
        if (strcmp(algorithm, "SHA256_RSA2048") == 0) {
            strcpy(key_file, "./avbtool/auto_generated_rsa2048.pem");
            if (!is_file_exist(key_file)) {
                 printf("生成RSA2048密钥...\n");
                 snprintf(gen_cmd, sizeof(gen_cmd), "export LD_LIBRARY_PATH=$PWD/avbtool:$LD_LIBRARY_PATH && ./openssl genrsa -out %s 2048", key_file);
                 system(gen_cmd);
            }
        } else if (strcmp(algorithm, "SHA256_RSA4096") == 0) {
            strcpy(key_file, "./avbtool/auto_generated_rsa4096.pem");
             if (!is_file_exist(key_file)) {
                 printf("生成RSA4096密钥...\n");
                 snprintf(gen_cmd, sizeof(gen_cmd), "export LD_LIBRARY_PATH=$PWD/avbtool:$LD_LIBRARY_PATH && ./openssl genrsa -out %s 4096", key_file);
                 system(gen_cmd);
            }
        }
        
        if (strlen(key_file) > 0 && is_file_exist(key_file)) {
            char avb_cmd[MAX_PATH * 4];
            snprintf(avb_cmd, sizeof(avb_cmd), 
                "export PATH=$PWD:$PWD/bin:$PATH && export LD_LIBRARY_PATH=$PWD/avbtool:$LD_LIBRARY_PATH && ./avbtool/avbtool add_hash_footer "
                "--image new_dtbo.img "
                "--partition_size %s "
                "--partition_name %s "
                "--hash_algorithm %s "
                "--algorithm %s "
                "--key %s "
                "--salt %s "
                "--rollback_index %s "
                "--internal_release_string \"%s\"",
                partition_size, partition_name, hash_alg, algorithm, key_file, salt, rollback_index, release_string);
                
             if (strlen(prop) > 0) {
                 char prop_arg[1024];
                 snprintf(prop_arg, sizeof(prop_arg), " --prop \"%s\"", prop);
                 strcat(avb_cmd, prop_arg);
             }
             
             if (system(avb_cmd) == 0) {
                 printf("AVB签名添加成功!\n");
             } else {
                 printf("警告: AVB签名添加失败\n");
             }
        } else {
            printf("警告: 无法生成密钥或不支持的算法 %s，跳过签名。\n", algorithm);
        }
    }

    }

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

void load_avb_config(char *partition_size, char *hash_alg, char *partition_name, 
                     char *salt, char *algorithm, char *rollback_index, 
                     char *release_string, char *prop) {
    FILE *fp = fopen("dtbo_dts/avb_info.cfg", "r");
    if (!fp) {
        printf("提示: 未找到AVB配置文件，将跳过AVB签名。\n");
        return;
    }
    
    char line[1024];
    while (fgets(line, sizeof(line), fp)) {
        // Strip newline
        char *nl = strchr(line, '\n');
        if (nl) *nl = 0;
        
        if (strncmp(line, "PARTITION_SIZE=", 15) == 0) {
            strcpy(partition_size, line + 15);
        } else if (strncmp(line, "HASH_ALG=", 9) == 0) {
            strcpy(hash_alg, line + 9);
        } else if (strncmp(line, "PARTITION_NAME=", 15) == 0) {
            strcpy(partition_name, line + 15);
        } else if (strncmp(line, "SALT=", 5) == 0) {
            strcpy(salt, line + 5);
        } else if (strncmp(line, "ALGORITHM=", 10) == 0) {
            strcpy(algorithm, line + 10);
        } else if (strncmp(line, "ROLLBACK_INDEX=", 15) == 0) {
            strcpy(rollback_index, line + 15);
        } else if (strncmp(line, "RELEASE_STRING=", 15) == 0) {
            strcpy(release_string, line + 15);
        } else if (strncmp(line, "PROP=", 5) == 0) {
            strcpy(prop, line + 5);
        }
    }
    fclose(fp);
    printf("已加载AVB配置: Alg=%s, Size=%s\n", algorithm, partition_size);
}
