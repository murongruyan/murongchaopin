package com.murongchaopin.displayhook;

import android.util.SparseArray;
import android.view.Display;

import java.lang.reflect.Method;

/** Keeps Framework's selected resolution group aligned without forcing a rate. */
final class FrameworkPhysicalEnvelopeHooks {
    private static final String DIRECTOR =
            "com.android.server.display.mode.DisplayModeDirector";
    private static final String DESIRED_SPECS = DIRECTOR + "$DesiredDisplayModeSpecs";
    private static final String VOTE = "com.android.server.display.mode.Vote";
    private static final int DEFAULT_DISPLAY = 0;
    private static final float RATE_EPSILON_HZ = 0.01f;

    private static volatile Method screenStateReader;
    private static String lastAdjustment = "";

    private FrameworkPhysicalEnvelopeHooks() {
    }

    static int install(DisplaySettingsHook module, ClassLoader loader) {
        String model = systemProperty("ro.product.vendor.model", "");
        if (!"RMX5200".equalsIgnoreCase(model)) {
            module.info("Framework physical envelope skipped model=" + model);
            return 0;
        }

        try {
            Class<?> properties = Class.forName("android.os.SystemProperties");
            Method getInt = properties.getDeclaredMethod("getInt", String.class, int.class);
            getInt.setAccessible(true);
            screenStateReader = getInt;
            Class<?> owner = Class.forName(DIRECTOR, false, loader);
            Class<?> specsClass = Class.forName(DESIRED_SPECS, false, loader);
            Class<?> voteClass = Class.forName(VOTE, false, loader);
            int userSizePriority = FrameworkResolutionVoteHooks
                    .optionalUserSizePriority(voteClass);
            int installed = 0;
            for (Method method : owner.getDeclaredMethods()) {
                if (!"getDesiredDisplayModeSpecs".equals(method.getName())
                        || method.getParameterCount() != 1
                        || method.getParameterTypes()[0] != int.class
                        || method.getReturnType() != specsClass) {
                    continue;
                }
                method.setAccessible(true);
                module.intercept(method, "framework.physical-envelope", chain -> {
                    Object result = chain.proceed();
                    int displayId = ((Number) chain.getArg(0)).intValue();
                    if (displayId == DEFAULT_DISPLAY && result != null) {
                        normalize(module, chain.getThisObject(), result,
                                displayId, userSizePriority);
                    }
                    return result;
                });
                installed++;
            }
            if (installed != 1) {
                throw new NoSuchMethodException("physical envelope hooks expected=1 actual="
                        + installed);
            }
            module.info("Framework physical envelope hooks installed=" + installed
                    + " model=" + model + " configuredModeSource=mode.txt"
                    + " userSizePriority=" + userSizePriority);
            return installed;
        } catch (Throwable error) {
            module.error("Framework physical envelope hook unavailable", error);
            return 0;
        }
    }

    private static void normalize(DisplaySettingsHook module, Object director,
                                  Object specs, int displayId,
                                  int userSizePriority) {
        if (!isScreenOn()) {
            return;
        }
        try {
            Display.Mode[] modes = appSupportedModes(director, displayId);
            int originalBaseId = numberField(specs, "baseModeId").intValue();
            Display.Mode base = findMode(modes, originalBaseId);
            int[] selected = FrameworkResolutionVoteHooks.selectedDisplayTarget();
            if (selected == null || selected.length != 3) {
                return;
            }

            Geometry preferred = new Geometry(selected[0], selected[1]);
            if (!preferred.validRmx5200()) {
                preferred = preferredGeometry(director, displayId,
                        userSizePriority);
            }
            Display.Mode target = base == null ? null
                    : findMode(modes, preferred, base.getRefreshRate());
            if (base == null || target == null) {
                return;
            }

            if (originalBaseId == target.getModeId()) {
                return;
            }

            Reflect.setField(specs, "baseModeId", target.getModeId());

            String adjustment = originalBaseId + "->" + target.getModeId()
                    + " " + preferred + " rate=" + base.getRefreshRate();
            logAdjustment(module, adjustment);
        } catch (Throwable error) {
            module.error("Framework physical envelope normalization failed", error);
        }
    }

    private static void logAdjustment(DisplaySettingsHook module, String adjustment) {
        synchronized (FrameworkPhysicalEnvelopeHooks.class) {
            if (!adjustment.equals(lastAdjustment)) {
                lastAdjustment = adjustment;
                module.info("Framework physical envelope applied " + adjustment);
            }
        }
    }

    private static Display.Mode[] appSupportedModes(Object director, int displayId)
            throws ReflectiveOperationException {
        Object value = Reflect.getField(director, "mAppSupportedModesByDisplay");
        if (!(value instanceof SparseArray<?>)) {
            return null;
        }
        Object modes = ((SparseArray<?>) value).get(displayId);
        return modes instanceof Display.Mode[] ? (Display.Mode[]) modes : null;
    }

    private static Geometry preferredGeometry(Object director, int displayId,
                                              int userSizePriority)
            throws ReflectiveOperationException {
        if (userSizePriority < 0) {
            return Geometry.INVALID;
        }
        Object storage = Reflect.getField(director, "mVotesStorage");
        Object value = Reflect.call(storage, "getVotes", displayId);
        if (!(value instanceof SparseArray<?>)) {
            return Geometry.INVALID;
        }
        Object vote = ((SparseArray<?>) value).get(userSizePriority);
        if (vote == null) {
            return Geometry.INVALID;
        }
        Object width = Reflect.getField(vote, "mWidth");
        Object height = Reflect.getField(vote, "mHeight");
        if (!(width instanceof Number) || !(height instanceof Number)) {
            return Geometry.INVALID;
        }
        return new Geometry(((Number) width).intValue(),
                ((Number) height).intValue());
    }

    private static Display.Mode findMode(Display.Mode[] modes, int modeId) {
        if (modes == null) {
            return null;
        }
        for (Display.Mode mode : modes) {
            if (mode != null && mode.getModeId() == modeId) {
                return mode;
            }
        }
        return null;
    }

    private static Display.Mode findMode(Display.Mode[] modes, Geometry geometry,
                                         float refreshRate) {
        Display.Mode selected = null;
        if (modes == null) {
            return null;
        }
        for (Display.Mode mode : modes) {
            if (mode == null
                    || mode.getPhysicalWidth() != geometry.width
                    || mode.getPhysicalHeight() != geometry.height
                    || Math.abs(mode.getRefreshRate() - refreshRate)
                    > RATE_EPSILON_HZ) {
                continue;
            }
            boolean extended = usesExtendedFhdGroup(mode);
            boolean selectedExtended = selected != null
                    && usesExtendedFhdGroup(selected);
            if (selected == null || (extended && !selectedExtended)
                    || (extended == selectedExtended
                    && mode.getModeId() < selected.getModeId())) {
                selected = mode;
            }
        }
        return selected;
    }

    private static boolean usesExtendedFhdGroup(Display.Mode mode) {
        if (mode == null || mode.getPhysicalWidth() != 1080
                || mode.getPhysicalHeight() != 2352) {
            return false;
        }
        for (float rate : mode.getAlternativeRefreshRates()) {
            if (rate > 144.0f + RATE_EPSILON_HZ) {
                return true;
            }
        }
        return mode.getRefreshRate() > 144.0f + RATE_EPSILON_HZ;
    }

    private static Number numberField(Object owner, String name)
            throws ReflectiveOperationException {
        Object value = Reflect.getField(owner, name);
        if (!(value instanceof Number)) {
            throw new IllegalStateException(name + " is not numeric");
        }
        return (Number) value;
    }

    private static boolean isScreenOn() {
        try {
            Method reader = screenStateReader;
            Object value = reader == null ? null : reader.invoke(null,
                    "debug.tracing.screen_state", 0);
            return value instanceof Number && ((Number) value).intValue() == 2;
        } catch (Throwable ignored) {
            return false;
        }
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

    private static final class Geometry {
        static final Geometry INVALID = new Geometry(-1, -1);

        final int width;
        final int height;

        Geometry(int width, int height) {
            this.width = width;
            this.height = height;
        }

        boolean validRmx5200() {
            return (width == 1080 && height == 2352)
                    || (width == 1440 && height == 3136);
        }

        @Override
        public String toString() {
            return width + "x" + height;
        }
    }
}
