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
    if exist "C:\android-ndk-r27d-windows\android-ndk-r30-beta2\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe" (
        set "FOUND_NDK_ROOT=C:\android-ndk-r27d-windows\android-ndk-r30-beta2"
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
    echo Build failed! Android NDK not found.
    echo Hint: set ANDROID_NDK_ROOT or NDK_ROOT first.
    exit /b 1
)
set "NDK_ROOT=%FOUND_NDK_ROOT%"
set "CLANG=%NDK_ROOT%\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe"
set "PREMIUM_SOURCE=%PREMIUM_SOURCE%"
if not defined PREMIUM_SOURCE set "PREMIUM_SOURCE=..\murongchaopin-premium\src\rate_daemon.c"
if not exist "%PREMIUM_SOURCE%" (
    echo Build failed! Premium daemon source not found: %PREMIUM_SOURCE%
    echo Set PREMIUM_SOURCE to the checked-out Premium src\rate_daemon.c.
    exit /b 1
)
if not exist "bin" mkdir "bin"
if not exist "packaging\paid-payload\bin" mkdir "packaging\paid-payload\bin"
if errorlevel 1 goto build_failed

set "COMMON_FLAGS=--target=aarch64-linux-android30 -O3 -static"

echo Compiling rate_daemon (free core build)...

"%CLANG%" ^
    %COMMON_FLAGS% ^
    -DMURONG_FREE_BUILD ^
    src\rate_daemon.c ^
    -o bin\rate_daemon
if errorlevel 1 goto build_failed

echo Compiling rate_daemon_premium (full build)...

"%CLANG%" ^
    %COMMON_FLAGS% ^
    "%PREMIUM_SOURCE%" ^
    -o packaging\paid-payload\bin\rate_daemon_premium
if errorlevel 1 goto build_failed

echo Compiling dts_tool...

"%CLANG%" ^
    %COMMON_FLAGS% ^
    src\dts_tool.c ^
    -o bin\dts_tool
if errorlevel 1 goto build_failed

echo Build successful! Output: bin\rate_daemon, packaging\paid-payload\bin\rate_daemon_premium, bin\dts_tool
exit /b 0

:build_failed
echo Build failed!
exit /b 1
