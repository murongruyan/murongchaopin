package com.murongchaopin.displayhook;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.view.Display;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;

/**
 * Restores the refresh-rate choice in the ColorOS 17 Settings app.
 *
 * The realme RMX5200 build reports a single selectable rate, so the
 * "refresh rate setting" row exists but is inert and the modes published by
 * the DRM backend can never be selected.  The OnePlus builds of the same
 * ColorOS 17 Settings app expose the full list, and the vendor code path is
 * driven by {@code ScreenRefreshUtils.sShowRefreshRateList}.
 *
 * These hooks keep the vendor implementation (so every other part of the page
 * behaves normally) and only rebuild that list from the modes the panel really
 * reports, including the overclocked ones.  The index values follow the
 * ColorOS 17 controller constants: 50 -> 0, 90 -> 1, 60 -> 2, 120 -> 3,
 * 144 -> 4, 165 -> 7, 185 -> 8.
 */
final class SettingsRefreshRateHooks {
    private static final String UTILS =
            "com.oplus.settings.feature.display.ScreenRefreshUtils";
    private static final int[] RATES_HZ = { 50, 90, 60, 120, 144, 165, 185 };
    private static final int[] RATES_INDEX = { 0, 1, 2, 3, 4, 7, 8 };

    private SettingsRefreshRateHooks() {
    }

    static int install(DisplaySettingsHook module, ClassLoader loader) {
        int installed = 0;
        try {
            Class<?> utils = Class.forName(UTILS, false, loader);
            Method support = find(utils, "isSupportRefreshRate", Context.class);
            if (support != null) {
                module.intercept(support, "settings.refresh.support", chain -> {
                    Object original = chain.proceed();
                    Context context = (Context) chain.getArg(0);
                    ArrayList<Integer> list = supportedIndexes(context);
                    module.info("Settings refresh-rate support: vendor=" + original
                            + " rates=" + list);
                    if (!list.isEmpty()) {
                        publish(module, utils, list);
                    }
                    return Boolean.TRUE;
                });
                installed++;
            }
            Method current = find(utils, "isCurrentDisplaySupportRefreshRate");
            if (current != null) {
                module.intercept(current, "settings.refresh.current", chain ->
                        Boolean.TRUE);
                installed++;
            }
        } catch (Throwable error) {
            module.error("Settings refresh-rate hooks failed", error);
        }
        module.info("Settings refresh-rate hooks installed=" + installed);
        return installed;
    }

    private static Method find(Class<?> owner, String name, Class<?>... parameters) {
        try {
            Method method = owner.getDeclaredMethod(name, parameters);
            method.setAccessible(true);
            return method;
        } catch (Throwable ignored) {
            return null;
        }
    }

    /** Refresh-rate indexes for every mode the display reports. */
    private static ArrayList<Integer> supportedIndexes(Context context) {
        ArrayList<Integer> indexes = new ArrayList<>();
        try {
            DisplayManager manager = (DisplayManager) context
                    .getSystemService(Context.DISPLAY_SERVICE);
            Display display = manager == null ? null : manager.getDisplay(Display.DEFAULT_DISPLAY);
            Display.Mode[] modes = display == null ? null : display.getSupportedModes();
            if (modes == null) {
                return indexes;
            }
            for (Display.Mode mode : modes) {
                int rate = Math.round(mode.getRefreshRate());
                for (int i = 0; i < RATES_HZ.length; i++) {
                    if (RATES_HZ[i] == rate && !indexes.contains(RATES_INDEX[i])) {
                        indexes.add(RATES_INDEX[i]);
                    }
                }
            }
        } catch (Throwable ignored) {
            return indexes;
        }
        Collections.sort(indexes);
        return indexes;
    }

    /** Replace the vendor lists with the real set of selectable rates. */
    private static void publish(DisplaySettingsHook module, Class<?> utils,
                                ArrayList<Integer> indexes) {
        try {
            Field show = utils.getField("sShowRefreshRateList");
            Object value = show.get(null);
            if (value instanceof java.util.List) {
                @SuppressWarnings("unchecked")
                java.util.List<Integer> list = (java.util.List<Integer>) value;
                if (!new ArrayList<>(list).equals(indexes)) {
                    list.clear();
                    list.addAll(indexes);
                    module.info("Settings refresh-rate list published " + indexes);
                }
            }
            Field current = utils.getDeclaredField("sCurrentDisplayRefreshRateList");
            current.setAccessible(true);
            Object currentValue = current.get(null);
            if (currentValue instanceof ArrayList) {
                @SuppressWarnings("unchecked")
                ArrayList<Integer> list = (ArrayList<Integer>) currentValue;
                list.clear();
                list.addAll(indexes);
            }
        } catch (Throwable error) {
            module.error("Settings refresh-rate list publish failed", error);
        }
    }
}
