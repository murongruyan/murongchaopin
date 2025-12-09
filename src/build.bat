@echo off
set NDK_ROOT=D:\android-ndk-r27c
set CLANG="%NDK_ROOT%\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe"
set FLAGS=--target=aarch64-linux-android29 --sysroot="%NDK_ROOT%\toolchains\llvm\prebuilt\windows-x86_64\sysroot" -Wall -O3 -fPIE -pie -lc -lm

echo.
echo Building process_dts...
%CLANG% %FLAGS% -o process_dts process_dts.c
if exist bin\process_dts (
    echo process_dts Built Successfully!
) else (
    echo process_dts Build FAILED!
)

echo.
echo Building pack_dtbo...
%CLANG% %FLAGS% -o pack_dtbo pack_dtbo.c
if exist bin\pack_dtbo (
    echo pack_dtbo Built Successfully!
) else (
    echo pack_dtbo Build FAILED!
)

echo.
echo Building unpack_dtbo...
%CLANG% %FLAGS% -o unpack_dtbo unpack_dtbo.c
if exist bin\unpack_dtbo (
    echo unpack_dtbo Built Successfully!
) else (
    echo unpack_dtbo Build FAILED!
)

echo.
echo Building rate_daemon...
%CLANG% %FLAGS% -o rate_daemon src\rate_daemon.c
if exist bin\rate_daemon (
    echo rate_daemon Built Successfully!
) else (
    echo rate_daemon Build FAILED!
)
