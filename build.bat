@echo off
set NDK_ROOT=D:\android-ndk-r27c
set CLANG="%NDK_ROOT%\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe"
set FLAGS=--target=aarch64-linux-android29 --sysroot="%NDK_ROOT%\toolchains\llvm\prebuilt\windows-x86_64\sysroot" -Wall -O3 -fPIE -pie -lc -lm

echo Creating directories...
if not exist "bin" mkdir bin
if not exist "bin\dtbo_dts" mkdir bin\dtbo_dts
if not exist "img" mkdir img

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
echo Building refresh_monitor.c...
%CLANG% %FLAGS% -o refresh_monitor refresh_monitor.c
if exist bin\refresh_monitor (
    echo refresh_monitor Built Successfully!
) else (
    echo refresh_monitor Build FAILED!
)

echo.
echo Copying tools...
if exist dtc copy dtc bin\
if exist mkdtimg copy mkdtimg bin\

echo.
echo Copying scripts...
copy customize.sh bin\customize.sh_backup

echo.
echo All builds finished.
echo Folder structure created in 'bin' and 'img'.
pause
