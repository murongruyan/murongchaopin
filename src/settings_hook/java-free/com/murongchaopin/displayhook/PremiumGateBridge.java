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

    /**
     * Resolve the system context once during module startup. Hooks that run
     * while framework display locks are held must never reflect into
     * ActivityThread.systemMain(), because that re-enters display code and can
     * deadlock against DisplayManagerService during boot.
     */
    public static void warmSystemContext() {
        systemContext();
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
                Object systemMain = activityThread.getMethod("systemMain").invoke(null);
                Object value = activityThread.getMethod("getSystemContext")
                        .invoke(systemMain);
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
