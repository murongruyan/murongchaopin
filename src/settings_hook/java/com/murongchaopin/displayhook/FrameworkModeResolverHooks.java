package com.murongchaopin.displayhook;

import android.util.SparseArray;
import android.view.Display;

import java.lang.reflect.Array;
import java.lang.reflect.Method;

/** Resolves integer refresh requests against Qualcomm's fractional mode values. */
final class FrameworkModeResolverHooks {
    private static final String LOCAL_DISPLAY_DEVICE =
            "com.android.server.display.LocalDisplayAdapter$LocalDisplayDevice";
    private static final float RATE_EPSILON_HZ = 0.01f;

    private FrameworkModeResolverHooks() {
    }

    static int install(DisplaySettingsHook module, ClassLoader loader) {
        String model = systemProperty("ro.product.vendor.model", "");
        if (!"RMX5200".equalsIgnoreCase(model)) {
            module.info("Framework mode resolver skipped model=" + model);
            return 0;
        }

        int installed = 0;
        try {
            Class<?> owner = Class.forName(LOCAL_DISPLAY_DEVICE, false, loader);
            for (Method method : owner.getDeclaredMethods()) {
                Class<?>[] parameters = method.getParameterTypes();
                if ("findMode".equals(method.getName())
                        && parameters.length == 3
                        && parameters[0] == int.class
                        && parameters[1] == int.class
                        && parameters[2] == float.class
                        && method.getReturnType() == Display.Mode.class) {
                    method.setAccessible(true);
                    module.intercept(method, "framework.mode.find", chain -> {
                        Object original = chain.proceed();
                        Display.Mode resolved = resolveMode(module, chain.getThisObject(),
                                ((Number) chain.getArg(0)).intValue(),
                                ((Number) chain.getArg(1)).intValue(),
                                ((Number) chain.getArg(2)).floatValue(),
                                "findMode", original);
                        return resolved == null ? original : resolved;
                    });
                    installed++;
                } else if ("findUserPreferredModeIdLocked".equals(method.getName())
                        && parameters.length == 1
                        && parameters[0] == Display.Mode.class
                        && method.getReturnType() == int.class) {
                    method.setAccessible(true);
                    module.intercept(method, "framework.mode.preferred-id", chain -> {
                        Object original = chain.proceed();
                        Object requested = chain.getArg(0);
                        if (!(requested instanceof Display.Mode)) return original;
                        Display.Mode requestedMode = (Display.Mode) requested;
                        Display.Mode resolved = resolveMode(module, chain.getThisObject(),
                                requestedMode.getPhysicalWidth(),
                                requestedMode.getPhysicalHeight(),
                                requestedMode.getRefreshRate(),
                                "preferredId", original);
                        return resolved == null ? original : resolved.getModeId();
                    });
                    installed++;
                } else if ("findSfDisplayModeIdLocked".equals(method.getName())
                        && parameters.length == 2
                        && parameters[0] == int.class
                        && parameters[1] == int.class
                        && method.getReturnType() == int.class) {
                    method.setAccessible(true);
                    module.intercept(method, "framework.mode.sf-id", chain -> {
                        Object original = chain.proceed();
                        Integer resolved = resolveSfModeId(module, chain.getThisObject(),
                                ((Number) chain.getArg(0)).intValue(),
                                ((Number) chain.getArg(1)).intValue(), original);
                        return resolved == null ? original : resolved;
                    });
                    installed++;
                } else if ("setDesiredDisplayModeSpecsLocked".equals(method.getName())
                        && parameters.length == 1
                        && method.getReturnType() == void.class) {
                    method.setAccessible(true);
                    module.intercept(method, "framework.mode.group-switch", chain -> {
                        enableCrossResolutionGroupSwitch(module, chain.getThisObject(),
                                chain.getArg(0));
                        return chain.proceed();
                    });
                    installed++;
                }
            }
        } catch (Throwable error) {
            module.error("Framework mode resolver unavailable", error);
        }
        module.info("Framework mode resolver hooks installed=" + installed
                + " model=" + model + " epsilon=" + RATE_EPSILON_HZ);
        return installed;
    }

    private static Display.Mode resolveMode(DisplaySettingsHook module, Object device,
                                            int width, int height, float refreshRate,
                                            String path, Object original) {
        if (width <= 0 || height <= 0 || refreshRate <= 0.0f) return null;

        Display.Mode selected = null;
        StringBuilder candidates = new StringBuilder();
        try {
            Object value = Reflect.getField(device, "mSupportedModes");
            if (!(value instanceof SparseArray<?>)) return null;
            SparseArray<?> records = (SparseArray<?>) value;
            for (int index = 0; index < records.size(); index++) {
                Object record = records.valueAt(index);
                Object modeValue = Reflect.getField(record, "mMode");
                if (!(modeValue instanceof Display.Mode)) continue;
                Display.Mode mode = (Display.Mode) modeValue;
                if (mode.getPhysicalWidth() != width
                        || mode.getPhysicalHeight() != height
                        || Math.abs(mode.getRefreshRate() - refreshRate)
                        > RATE_EPSILON_HZ) {
                    continue;
                }
                if (candidates.length() > 0) candidates.append(',');
                candidates.append(mode.getModeId());
                boolean extended = usesExtendedFhdGroup(mode);
                boolean selectedExtended = selected != null
                        && usesExtendedFhdGroup(selected);
                if (selected == null || (extended && !selectedExtended)
                        || (extended == selectedExtended
                        && mode.getModeId() < selected.getModeId())) {
                    selected = mode;
                }
            }
            if (selected != null) {
                module.info("Framework mode resolver path=" + path
                        + " request=" + width + "x" + height + "@" + refreshRate
                        + " original=" + original + " candidates=[" + candidates
                        + "] selected=" + selected.getModeId());
            }
        } catch (Throwable error) {
            module.error("Framework mode resolver failed path=" + path, error);
        }
        return selected;
    }

    private static Integer resolveSfModeId(DisplaySettingsHook module, Object device,
                                           int frameworkModeId, int requestedGroup,
                                           Object original) {
        try {
            Display.Mode target = frameworkMode(device, frameworkModeId);
            Object sfModes = Reflect.getField(device, "mSfDisplayModes");
            if (target == null || sfModes == null || !sfModes.getClass().isArray()) {
                return null;
            }

            int groupMatch = Integer.MAX_VALUE;
            int extendedGroupMatch = Integer.MAX_VALUE;
            int fallback = Integer.MAX_VALUE;
            int extendedGroup = extendedFhdGroup(target, sfModes);
            StringBuilder candidates = new StringBuilder();
            for (int index = 0; index < Array.getLength(sfModes); index++) {
                Object mode = Array.get(sfModes, index);
                if (!matches(target, mode)) {
                    continue;
                }
                int id = intField(mode, "id");
                int group = intField(mode, "group");
                if (id < 0) {
                    continue;
                }
                if (candidates.length() > 0) candidates.append(',');
                candidates.append(id).append("/g").append(group);
                fallback = Math.min(fallback, id);
                if (group == extendedGroup) {
                    extendedGroupMatch = Math.min(extendedGroupMatch, id);
                }
                if (group == requestedGroup) {
                    groupMatch = Math.min(groupMatch, id);
                }
            }
            int selected = extendedGroupMatch != Integer.MAX_VALUE
                    ? extendedGroupMatch
                    : groupMatch != Integer.MAX_VALUE ? groupMatch : fallback;
            if (selected == Integer.MAX_VALUE) {
                return null;
            }
            int originalId = original instanceof Number
                    ? ((Number) original).intValue() : -1;
            if (selected != originalId) {
                module.info("Framework SF mode corrected framework=" + frameworkModeId
                        + " target=" + describe(target)
                        + " requestedGroup=" + requestedGroup
                        + " extendedGroup=" + extendedGroup
                        + " original=" + originalId
                        + " candidates=[" + candidates + "] selected=" + selected);
            }
            return selected;
        } catch (Throwable error) {
            module.error("Framework SF mode resolver failed framework="
                    + frameworkModeId, error);
            return null;
        }
    }

    private static void enableCrossResolutionGroupSwitch(DisplaySettingsHook module,
                                                         Object device,
                                                         Object specs) {
        if (device == null || specs == null) {
            return;
        }
        try {
            if (Boolean.TRUE.equals(Reflect.getField(specs, "allowGroupSwitching"))) {
                return;
            }
            Object baseModeValue = Reflect.getField(specs, "baseModeId");
            if (!(baseModeValue instanceof Number)) {
                return;
            }
            int frameworkModeId = ((Number) baseModeValue).intValue();
            Display.Mode target = frameworkMode(device, frameworkModeId);
            Object active = Reflect.getField(device, "mActiveSfDisplayMode");
            if (target == null || active == null) {
                return;
            }
            int activeWidth = intField(active, "width");
            int activeHeight = intField(active, "height");
            if (target.getPhysicalWidth() == activeWidth
                    && target.getPhysicalHeight() == activeHeight) {
                return;
            }

            Reflect.setField(specs, "allowGroupSwitching", true);
            module.info("Framework cross-resolution group switch enabled active="
                    + activeWidth + "x" + activeHeight
                    + " target=" + describe(target)
                    + " framework=" + frameworkModeId);
        } catch (Throwable error) {
            module.error("Framework cross-resolution group switch failed", error);
        }
    }

    private static Display.Mode frameworkMode(Object device, int frameworkModeId)
            throws ReflectiveOperationException {
        Object value = Reflect.getField(device, "mSupportedModes");
        if (!(value instanceof SparseArray<?>)) {
            return null;
        }
        Object record = ((SparseArray<?>) value).get(frameworkModeId);
        Object mode = Reflect.getField(record, "mMode");
        return mode instanceof Display.Mode ? (Display.Mode) mode : null;
    }

    private static boolean matches(Display.Mode target, Object sfMode)
            throws ReflectiveOperationException {
        return target.getPhysicalWidth() == intField(sfMode, "width")
                && target.getPhysicalHeight() == intField(sfMode, "height")
                && Math.abs(target.getRefreshRate()
                - floatField(sfMode, "peakRefreshRate")) <= RATE_EPSILON_HZ
                && Math.abs(displayVsyncRate(target)
                - floatField(sfMode, "vsyncRate")) <= RATE_EPSILON_HZ;
    }

    private static boolean usesExtendedFhdGroup(Display.Mode mode) {
        if (mode == null || mode.getPhysicalWidth() != 1080) {
            return false;
        }
        for (float rate : mode.getAlternativeRefreshRates()) {
            if (rate > 144.0f + RATE_EPSILON_HZ) {
                return true;
            }
        }
        return mode.getRefreshRate() > 144.0f + RATE_EPSILON_HZ;
    }

    private static int extendedFhdGroup(Display.Mode target, Object sfModes)
            throws ReflectiveOperationException {
        if (!usesExtendedFhdGroup(target) || sfModes == null
                || !sfModes.getClass().isArray()) {
            return -1;
        }
        for (int index = 0; index < Array.getLength(sfModes); index++) {
            Object mode = Array.get(sfModes, index);
            if (intField(mode, "width") == target.getPhysicalWidth()
                    && intField(mode, "height") == target.getPhysicalHeight()
                    && floatField(mode, "peakRefreshRate")
                    > 144.0f + RATE_EPSILON_HZ) {
                return intField(mode, "group");
            }
        }
        return -1;
    }

    private static float displayVsyncRate(Display.Mode mode) {
        try {
            Object value = Reflect.call(mode, "getVsyncRate");
            if (value instanceof Number) {
                return ((Number) value).floatValue();
            }
        } catch (ReflectiveOperationException ignored) {
            // Older public framework stubs expose only the peak refresh rate.
        }
        return mode.getRefreshRate();
    }

    private static int intField(Object owner, String name)
            throws ReflectiveOperationException {
        Object value = Reflect.getField(owner, name);
        return value instanceof Number ? ((Number) value).intValue() : -1;
    }

    private static float floatField(Object owner, String name)
            throws ReflectiveOperationException {
        Object value = Reflect.getField(owner, name);
        return value instanceof Number ? ((Number) value).floatValue() : Float.NaN;
    }

    private static String describe(Display.Mode mode) {
        return mode.getPhysicalWidth() + "x" + mode.getPhysicalHeight()
                + "@" + mode.getRefreshRate();
    }

    private static String systemProperty(String key, String fallback) {
        try {
            Class<?> properties = Class.forName("android.os.SystemProperties");
            Method get = properties.getDeclaredMethod("get", String.class, String.class);
            get.setAccessible(true);
            Object value = get.invoke(null, key, fallback);
            return value instanceof String ? (String) value : fallback;
        } catch (Throwable ignored) {
            return fallback;
        }
    }
}
