package com.murongchaopin.displayhook;

import java.lang.reflect.Method;

/**
 * Stabilizes ColorOS SystemUI against a stock crash: the status-bar network
 * speed view can occupy a status bar icon slot, and OPlus' signal policy then
 * drives IconManager.onSetIcon which blindly casts the child view to
 * StatusBarIconView. The ClassCastException propagates through the icon
 * controller's coroutine and kills SystemUI. Hook the cast site and drop the
 * update for that slot instead of crashing the system UI.
 */
final class SystemUiStabilityHooks {
    private static final String ICON_MANAGER =
            "com.android.systemui.statusbar.phone.ui.IconManager";

    private SystemUiStabilityHooks() {
    }

    static int install(DisplaySettingsHook module, ClassLoader loader) {
        int count = 0;
        try {
            Class<?> owner = Class.forName(ICON_MANAGER, false, loader);
            for (Method method : owner.getDeclaredMethods()) {
                if (!"onSetIcon".equals(method.getName())
                        || method.getParameterCount() != 2
                        || method.getParameterTypes()[0] != int.class) {
                    continue;
                }
                method.setAccessible(true);
                final String id = "systemui.icon-set." + count++;
                module.intercept(method, id, chain -> {
                    try {
                        return chain.proceed();
                    } catch (ClassCastException error) {
                        module.info("SystemUI suppressed non-icon slot view");
                        return null;
                    }
                });
            }
            if (count == 0) {
                throw new NoSuchMethodException("IconManager.onSetIcon API changed");
            }
            module.info("SystemUI stability hooks installed=" + count);
            return count;
        } catch (Throwable error) {
            module.error("SystemUI stability hooks unavailable", error);
            return 0;
        }
    }
}
