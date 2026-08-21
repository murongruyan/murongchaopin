package com.murongchaopin.displayhook;

import android.content.Context;
import android.provider.Settings;

/** Minimal cross-APK state reader used by the always-installed free hook. */
public final class PremiumGateBridge {
    static final String MEMC_ACTIVE_SETTING = "murong_vendor_memc_active";
    private static final Object CONTEXT_LOCK = new Object();
    private static volatile Context cachedContext;

    private PremiumGateBridge() {
    }

    /** Whether the separately installed premium module owns a vendor MEMC session. */
    public static boolean isVendorMemcActive() {
        Context context = systemContext();
        if (context == null) {
            return false;
        }
        try {
            return "1".equals(Settings.Global.getString(
                    context.getContentResolver(), MEMC_ACTIVE_SETTING));
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static Context systemContext() {
        Context context = cachedContext;
        if (context != null) {
            return context;
        }
        synchronized (CONTEXT_LOCK) {
            if (cachedContext != null) {
                return cachedContext;
            }
            try {
                Class<?> activityThread = Class.forName("android.app.ActivityThread");
                Object current = activityThread.getMethod("currentActivityThread").invoke(null);
                if (current == null) {
                    // Never reflect into systemMain() from a hook: it re-enters
                    // display code and can deadlock against DisplayManagerService
                    // while framework display locks are held.
                    return cachedContext;
                }
                Object value = activityThread.getMethod("getSystemContext").invoke(current);
                if (value instanceof Context) {
                    cachedContext = (Context) value;
                }
            } catch (Throwable ignored) {
                // The bridge stays inactive until a later warm-up succeeds.
            }
            return cachedContext;
        }
    }
}
