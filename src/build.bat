@echo off
setlocal EnableExtensions
set "USER_NDK_ROOT=%NDK_ROOT%"
set "FOUND_NDK_ROOT="
if defined ANDROID_NDK_ROOT (
    if exist "%ANDROID_NDK_ROOT%\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe" (
        set "FOUND_NDK_ROOT=%ANDROID_NDK_ROOT%"
    )
)
if not defined FOUND_NDK_ROOT (
    if defined USER_NDK_ROOT (
        if exist "%USER_NDK_ROOT%\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe" (
            set "FOUND_NDK_ROOT=%USER_NDK_ROOT%"
        )
    )
)
if not defined FOUND_NDK_ROOT (
    if exist "C:\android-ndk-r27d-windows\huanjing\android-ndk-r30-beta1\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe" (
        set "FOUND_NDK_ROOT=C:\android-ndk-r27d-windows\huanjing\android-ndk-r30-beta1"
    )
)
if not defined FOUND_NDK_ROOT (
    if exist "C:\android-ndk-r27d-windows\huanjing\android-ndk-r30\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe" (
        set "FOUND_NDK_ROOT=C:\android-ndk-r27d-windows\huanjing\android-ndk-r30"
    )
)
if not defined FOUND_NDK_ROOT (
    if exist "C:\android-ndk-r27d-windows\android-ndk-r27d\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe" (
        set "FOUND_NDK_ROOT=C:\android-ndk-r27d-windows\android-ndk-r27d"
    )
)
if not defined FOUND_NDK_ROOT (
    echo Build FAILED! Android NDK not found.
    echo Hint: set ANDROID_NDK_ROOT or NDK_ROOT first.
    exit /b 1
)
set "NDK_ROOT=%FOUND_NDK_ROOT%"
set "CLANG=%NDK_ROOT%\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe"
set "SYSROOT=%NDK_ROOT%\toolchains\llvm\prebuilt\windows-x86_64\sysroot"
set "FLAGS=--target=aarch64-linux-android29 --sysroot=%SYSROOT% -Wall -O3 -fPIE -pie -lc -lm"

echo.
echo Building process_dts...
"%CLANG%" %FLAGS% -o ..\bin\process_dts process_dts.c
if exist ..\bin\process_dts (
    echo process_dts Built Successfully!
) else (
    echo process_dts Build FAILED!
)

echo Building dts_tool...
"%CLANG%" %FLAGS% -o ..\bin\dts_tool dts_tool.c
if exist ..\bin\dts_tool (
    echo dts_tool Built Successfully!
) else (
    echo dts_tool Build FAILED!
)

echo.
echo Building pack_dtbo...
"%CLANG%" %FLAGS% -o ..\bin\pack_dtbo pack_dtbo.c
if exist ..\bin\pack_dtbo (
    echo pack_dtbo Built Successfully!
) else (
    echo pack_dtbo Build FAILED!
)

echo.
echo Building unpack_dtbo...
"%CLANG%" %FLAGS% -o ..\bin\unpack_dtbo unpack_dtbo.c
if exist ..\bin\unpack_dtbo (
    echo unpack_dtbo Built Successfully!
) else (
    echo unpack_dtbo Build FAILED!
)

echo.
echo Building rate_daemon...
"%CLANG%" %FLAGS% -o ..\bin\rate_daemon rate_daemon.c
if exist ..\bin\rate_daemon (
    echo rate_daemon Built Successfully!
) else (
    echo rate_daemon Build FAILED!
)
