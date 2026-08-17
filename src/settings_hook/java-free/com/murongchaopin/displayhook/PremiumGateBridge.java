package com.murongchaopin.displayhook;

import android.content.Context;
import android.provider.Settings;

/** Minimal cross-APK state reader used by the always-installed free hook. */
public final class PremiumGateBridge {
    static final String MEMC_ACTIVE_SETTING = "murong_vendor_memc_active";

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
        try {
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object systemMain = activityThread.getMethod("systemMain").invoke(null);
            Object context = activityThread.getMethod("getSystemContext")
                    .invoke(systemMain);
            return context instanceof Context ? (Context) context : null;
        } catch (Throwable ignored) {
            return null;
        }
    }
}
