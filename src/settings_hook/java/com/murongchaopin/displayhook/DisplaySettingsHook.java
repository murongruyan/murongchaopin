package com.murongchaopin.displayhook;

import android.util.Log;

import java.lang.reflect.Executable;

import io.github.libxposed.api.XposedInterface;
import io.github.libxposed.api.XposedModule;

/** API 102 entry point for the free display-policy base and KernelSU WebUI. */
public class DisplaySettingsHook extends XposedModule {
    static final String ANDROID = "android";
    static final String SYSTEM = "system";
    static final String SETTINGS = "com.android.settings";
    static final String GAMES = "com.oplus.games";
    static final String SCENE = "com.omarea.vtools";
    static final String KERNELSU = "me.weishu.kernelsu";
    static final String SYSTEM_UI = "com.android.systemui";
    static final String COLOROS_VIDEO = "com.coloros.video";
    private static final String TAG = "MurongDisplayHook";

    protected String processName = "";
    private boolean oplusServicesInstalled;

    @Override
    public void onModuleLoaded(ModuleLoadedParam param) {
        processName = param.getProcessName();
        info("loaded process=" + processName + " framework=" + getFrameworkName()
                + " api=" + getApiVersion());
    }

    @Override
    public void onPackageReady(PackageReadyParam param) {
        String packageName = param.getPackageName();
        if (!param.isFirstPackage()) {
            return;
        }
        if (isSystemServerProcess()) {
            info("system package ready=" + packageName);
        }
        try {
            if ((ANDROID.equals(packageName) || SYSTEM.equals(packageName))
                    && isSystemServerProcess()) {
                installOplusServices(param.getClassLoader(), "package-ready:" + packageName);
            } else if (!packageName.equals(processName)) {
                return;
            } else if (KERNELSU.equals(packageName)) {
                KernelSuWebUiHooks.install(this, param.getClassLoader());
            } else if (SYSTEM_UI.equals(packageName)) {
                SystemUiStabilityHooks.install(this, param.getClassLoader());
            }
        } catch (Throwable error) {
            error("scope initialization failed for " + packageName, error);
        }
    }

    @Override
    public void onSystemServerStarting(SystemServerStartingParam param) {
        if (!isSystemServerProcess()) {
            return;
        }
        try {
            installOplusServices(param.getClassLoader(), "system-server-starting");
        } catch (Throwable error) {
            error("system-server initialization failed", error);
        }
    }

    private synchronized void installOplusServices(ClassLoader loader, String source) {
        if (oplusServicesInstalled) {
            return;
        }
        int installed = OplusServicesHooks.install(this, loader);
        oplusServicesInstalled = installed > 0;
        info("Oplus services lifecycle=" + source + " hooks=" + installed);
    }

    protected boolean isSystemServerProcess() {
        return "system".equals(processName) || "system_server".equals(processName);
    }

    void intercept(Executable executable, String id, XposedInterface.Hooker hooker) {
        hook(executable)
                .setId(id)
                .setExceptionMode(XposedInterface.ExceptionMode.PROTECTIVE)
                .intercept(hooker);
    }

    void info(String message) {
        log(Log.INFO, TAG, message);
    }

    void error(String message, Throwable error) {
        log(Log.ERROR, TAG, message, error);
    }
}
