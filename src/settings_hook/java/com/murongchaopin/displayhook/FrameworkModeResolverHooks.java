package com.murongchaopin.displayhook;

import android.util.SparseArray;
import android.view.Display;

import java.lang.reflect.Array;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

/** Resolves integer refresh requests against Qualcomm's fractional mode values. */
final class FrameworkModeResolverHooks {
    private static final String LOCAL_DISPLAY_DEVICE =
            "com.android.server.display.LocalDisplayAdapter$LocalDisplayDevice";
    private static final float RATE_EPSILON_HZ = 0.01f;
    /** The rate the stock LTPS algorithm asks for while the screen is idle. */
    private static final float LTPS_IDLE_RATE_HZ = 60.0f;
    /** Idle timer SF applies the low tier after. */
    private static final int IDLE_CONFIG_TIMEOUT_MS = 1000;
    private static volatile String lastRouteDecision = "";
    private static volatile String lastRouteTrace = "";
    private static volatile boolean idleConfigProbed = false;
    private static volatile String idleConfigApplied = null;

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
                        applyLtpoRoute(module, chain.getThisObject(), chain.getArg(0));
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

/**
     * Pure custom LTPO. The framework's own idle request is the stock 60Hz LTPS
     * tier; when the daemon publishes the node the panel should rest on, resolve
     * that same request against the injected low tier so the *system* selects
     * 1Hz. Nothing is forced while the vendor asks for a higher rate, so the
     * touch/animation rise keeps its stock behaviour.
     */
/** Field dump of a RefreshRateRanges-like object, for the LTPO audit. */
    private static String describeRanges(Object ranges) {
        if (ranges == null) {
            return "null";
        }
        StringBuilder builder = new StringBuilder();
        for (Field field : ranges.getClass().getDeclaredFields()) {
            if (Modifier.isStatic(field.getModifiers())) {
                continue;
            }
            try {
                field.setAccessible(true);
                Object value = field.get(ranges);
                if (builder.length() > 0) {
                    builder.append(' ');
                }
                builder.append(field.getName()).append('=');
                if (value instanceof float[]) {
                    float[] array = (float[]) value;
                    builder.append('[');
                    for (int i = 0; i < Math.min(array.length, 8); i++) {
                        if (i > 0) builder.append(',');
                        builder.append(array[i]);
                    }
                    builder.append(']');
                } else if (value instanceof int[]) {
                    int[] array = (int[]) value;
                    builder.append('[');
                    for (int i = 0; i < Math.min(array.length, 8); i++) {
                        if (i > 0) builder.append(',');
                        builder.append(array[i]);
                    }
                    builder.append(']');
                } else if (value == null || value instanceof Number
                        || value instanceof Boolean || value instanceof CharSequence) {
                    builder.append(value);
                } else {
                    builder.append(describeRangeFields(value));
                }
            } catch (Throwable ignored) {
                // field not readable: skip it
            }
        }
        return builder.toString();
    }

    /** One more level: RefreshRateRange keeps its bounds in inner objects. */
    private static String describeRangeFields(Object range) {
        StringBuilder builder = new StringBuilder();
        builder.append(range.getClass().getSimpleName()).append('{');
        for (Field field : range.getClass().getDeclaredFields()) {
            if (Modifier.isStatic(field.getModifiers())) {
                continue;
            }
            try {
                field.setAccessible(true);
                Object value = field.get(range);
                if (builder.charAt(builder.length() - 1) != '{') {
                    builder.append(' ');
                }
                builder.append(field.getName()).append('=');
                if (value == null || value instanceof Number
                        || value instanceof Boolean || value instanceof CharSequence) {
                    builder.append(value);
                } else {
                    builder.append(value.getClass().getSimpleName());
                }
            } catch (Throwable ignored) {
                // field not readable: skip it
            }
        }
        return builder.append('}').toString();
    }

    private static boolean booleanField(Object owner, String name) {
        try {
            Object value = Reflect.getField(owner, name);
            return value instanceof Boolean && (Boolean) value;
        } catch (Throwable ignored) {
            return false;
        }
    }

/** One-shot dump of the "idle screen refresh rate" channel SF exposes. */
    private static void probeIdleConfig(DisplaySettingsHook module, Object device,
                                        Object specs) {
        if (idleConfigProbed) {
            return;
        }
        idleConfigProbed = true;
        try {
            java.lang.reflect.Field holder = specs.getClass()
                    .getDeclaredField("mIdleScreenRefreshRateConfig");

            holder.setAccessible(true);
            Object current = holder.get(specs);
            Class<?> type = holder.getType();
            if (type == Object.class && current != null) {
                type = current.getClass();
            }
            StringBuilder builder = new StringBuilder();
            builder.append("type=").append(type.getName());
            builder.append(" current=").append(current);
            builder.append(" fields=[");
            for (java.lang.reflect.Field field : type.getDeclaredFields()) {
                if (java.lang.reflect.Modifier.isStatic(field.getModifiers())) {
                    continue;
                }
                builder.append(field.getName()).append(':')
                        .append(field.getType().getSimpleName()).append(' ');
            }
            builder.append("] ctors=[");
            for (java.lang.reflect.Constructor<?> ctor : type.getDeclaredConstructors()) {
                builder.append('(');
                for (Class<?> param : ctor.getParameterTypes()) {
                    builder.append(param.getSimpleName()).append(',');
                }
                builder.append(") ");
            }
            builder.append(']');
            module.info("IDLECFG " + builder);
        } catch (Throwable error) {
            module.error("IDLECFG probe failed", error);
        }
    }

    private static void applyLtpoRoute(DisplaySettingsHook module, Object device,
                                       Object specs) {
        try {
            if (specs == null) {
                return;
            }
            BridgeClient.LtpoRoute route = BridgeClient.ltpoRoute();
            int baseId = intField(specs, "baseModeId");
            probeIdleConfig(module, device, specs);
            Display.Mode base = frameworkMode(device, baseId);
            float baseRate = base == null ? -1.0f : base.getRefreshRate();
            Integer routedId = null;
            if (route != null && base != null
                    && Math.abs(baseRate - LTPS_IDLE_RATE_HZ)
                        <= RATE_EPSILON_HZ) {
                routedId = frameworkModeIdForRate(device,
                        base.getPhysicalWidth(), base.getPhysicalHeight(),
                        route.targetFps);
            }
            String trace = "route=" + (route == null ? "none" : route.targetFps)
                    + " base=" + baseId + "@" + baseRate
                    + " routed=" + routedId
                    + " group=" + booleanField(specs, "allowGroupSwitching")
                    + " vrr=" + intField(specs, "vrrPolicy")
                    + " primary=[" + describeRanges(Reflect.getField(specs, "primary")) + "]"
                    + " app=[" + describeRanges(Reflect.getField(specs, "appRequest")) + "]";
            synchronized (FrameworkModeResolverHooks.class) {
                if (!trace.equals(lastRouteTrace)) {
                    lastRouteTrace = trace;
                    module.info("LTPO route trace " + trace);
                }
            }
            if (routedId == null && !applyIdleScreenConfig(module, specs, route)) {
                return;
            }
            if (routedId == null) {
                return;
            }
            if (routedId == null || routedId == baseId) {
                return;
            }
            Reflect.setField(specs, "baseModeId", routedId);
            String decision = "base=" + baseId + " -> " + routedId
                    + " (" + base.getPhysicalWidth() + "x"
                    + base.getPhysicalHeight() + "@" + route.targetFps + ")";
            synchronized (FrameworkModeResolverHooks.class) {
                if (!decision.equals(lastRouteDecision)) {
                    lastRouteDecision = decision;
                    module.info("LTPO route specs " + decision);
                }
            }
        } catch (Throwable error) {
            module.error("LTPO route specs failed", error);
        }
    }

/**
     * Pure custom LTPO. SurfaceFlinger has its own "idle screen refresh rate"
     * channel (SurfaceControl.IdleScreenRefreshRateConfig) which the stock
     * framework leaves null, so the vendor falls back to its 60Hz touch-idle
     * tier. Publish the idle configuration while the route asks for the low
     * tier and let SF's own idle machinery pick the rate.
     */
    private static boolean applyIdleScreenConfig(DisplaySettingsHook module,
                                                 Object specs,
                                                 BridgeClient.LtpoRoute route) {
        try {
            if (route == null || !route.isRouting() || route.targetFps > 10) {
                return false;
            }
            java.lang.reflect.Field holder = specs.getClass()
                    .getDeclaredField("mIdleScreenRefreshRateConfig");

            holder.setAccessible(true);
            Object current = holder.get(specs);
            String state = current == null ? "null" : current.toString();

            // Every specs rebuild starts from null, so re-apply instead of
            // treating "already seen null" as "already configured": otherwise
            // the panel drops back to the vendor 60Hz tier after ~30s.
            if (current != null) {
                if (!"seen".equals(idleConfigApplied)) {
                    idleConfigApplied = "seen";
                    module.info("LTPO idle screen config already=" + current
                            + " target=" + route.targetFps);
                }
                return true;
            }
            Class<?> type = holder.getType();
            Object instance = type.getDeclaredConstructor(int.class)
                    .newInstance(IDLE_CONFIG_TIMEOUT_MS);

            holder.set(specs, instance);
            if (!"set".equals(idleConfigApplied)) {
                idleConfigApplied = "set";
                module.info("LTPO idle screen config applied timeout="
                        + IDLE_CONFIG_TIMEOUT_MS + " target=" + route.targetFps);
            }
            return true;
        } catch (Throwable error) {
            module.error("LTPO idle screen config failed", error);
            return false;
        }
    }

    /** Framework mode id whose geometry and rate match, or null. */
    private static Integer frameworkModeIdForRate(Object device, int width,
                                                  int height, float refreshRate) {
        try {
            return frameworkModeIdForRateLocked(device, width, height, refreshRate);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static Integer frameworkModeIdForRateLocked(Object device, int width,
                                                        int height,
                                                        float refreshRate)
            throws ReflectiveOperationException {
        Object value = Reflect.getField(device, "mSupportedModes");
        if (!(value instanceof SparseArray<?>)) {
            return null;
        }
        SparseArray<?> records = (SparseArray<?>) value;
        Integer selected = null;
        for (int index = 0; index < records.size(); index++) {
            Object record = records.valueAt(index);
            Object modeValue = Reflect.getField(record, "mMode");
            if (!(modeValue instanceof Display.Mode)) {
                continue;
            }
            Display.Mode mode = (Display.Mode) modeValue;
            if (mode.getPhysicalWidth() != width
                    || mode.getPhysicalHeight() != height
                    || Math.abs(mode.getRefreshRate() - refreshRate)
                        > RATE_EPSILON_HZ) {
                continue;
            }
            int modeId = mode.getModeId();
            if (selected == null || modeId < selected) {
                selected = modeId;
            }
        }
        return selected;
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
            boolean relaxed = false;
            if (selected == Integer.MAX_VALUE) {
                /* An injected low tier is cloned from the native 60Hz timing, so
                 * the vendor often keeps vsyncRate=60 while peakRefreshRate
                 * carries the injected rate. The strict matcher then finds
                 * nothing, the request falls through to the vendor's stale
                 * answer and the panel stays on 60. Retry on the peak rate. */
                int relaxedMatch = Integer.MAX_VALUE;
                for (int index = 0; index < Array.getLength(sfModes); index++) {
                    Object mode = Array.get(sfModes, index);
                    if (intField(mode, "width") != target.getPhysicalWidth()
                            || intField(mode, "height") != target.getPhysicalHeight()
                            || Math.abs(floatField(mode, "peakRefreshRate")
                                - target.getRefreshRate()) > RATE_EPSILON_HZ) {
                        continue;
                    }
                    int id = intField(mode, "id");
                    if (id >= 0 && id < relaxedMatch) {
                        relaxedMatch = id;
                    }
                }
                if (relaxedMatch != Integer.MAX_VALUE) {
                    selected = relaxedMatch;
                    relaxed = true;
                }
            }
            boolean lowRate = target.getRefreshRate() <= 5.0f;
            if (lowRate) {
                StringBuilder detail = new StringBuilder();
                for (int index = 0; index < Array.getLength(sfModes); index++) {
                    Object mode = Array.get(sfModes, index);
                    if (intField(mode, "width") != target.getPhysicalWidth()
                            || intField(mode, "height") != target.getPhysicalHeight()) {
                        continue;
                    }
                    detail.append(detail.length() > 0 ? ',' : ' ')
                            .append(intField(mode, "id")).append("/g")
                            .append(intField(mode, "group")).append('@')
                            .append(floatField(mode, "peakRefreshRate"))
                            .append('/').append(floatField(mode, "vsyncRate"));
                }
                module.info("Framework SF low-rate mapping framework=" + frameworkModeId
                        + " target=" + describe(target) + " requestedGroup="
                        + requestedGroup + " sf=[" + detail.toString().trim() + "]"
                        + " selected=" + (selected == Integer.MAX_VALUE ? -1 : selected)
                        + " relaxed=" + relaxed);
            }
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
