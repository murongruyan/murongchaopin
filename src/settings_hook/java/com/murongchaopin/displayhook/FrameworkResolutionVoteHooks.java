package com.murongchaopin.displayhook;

import android.util.SparseArray;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;

/** Keeps stale app-size votes from overriding the RMX5200 resolution setting. */
final class FrameworkResolutionVoteHooks {
    private static final String VOTES_STORAGE =
            "com.android.server.display.mode.VotesStorage";
    private static final String VOTE = "com.android.server.display.mode.Vote";
    private static final String VOTE_SUMMARY =
            "com.android.server.display.mode.VoteSummary";
    private static final int DEFAULT_DISPLAY = 0;
    private static final int FHD_WIDTH = 1080;
    private static final int FHD_HEIGHT = 2352;
    private static final int QHD_WIDTH = 1440;
    private static final int QHD_HEIGHT = 3136;

    private static String lastRewrite = "";
    private static String lastAdjusted = "";
    private static volatile Geometry preferredGeometry = Geometry.INVALID;
    private static final ThreadLocal<Geometry> CALCULATION_GEOMETRY =
            new ThreadLocal<>();

    private FrameworkResolutionVoteHooks() {
    }

    static int install(DisplaySettingsHook module, ClassLoader loader) {
        String model = systemProperty("ro.product.vendor.model", "");
        if (!"RMX5200".equalsIgnoreCase(model)) {
            module.info("Framework resolution vote hook skipped model=" + model);
            return 0;
        }

        try {
            Class<?> storageClass = Class.forName(VOTES_STORAGE, false, loader);
            Class<?> voteClass = Class.forName(VOTE, false, loader);
            Class<?> summaryClass = Class.forName(VOTE_SUMMARY, false, loader);
            int appSizePriority = staticInt(voteClass,
                    "PRIORITY_APP_REQUEST_SIZE");
            int userSizePriority = staticInt(voteClass,
                    "PRIORITY_USER_SETTING_DISPLAY_PREFERRED_SIZE");

            int installed = 0;
            for (Method method : storageClass.getDeclaredMethods()) {
                if (!"getVotes".equals(method.getName())
                        || method.getParameterCount() != 1
                        || method.getParameterTypes()[0] != int.class
                        || !SparseArray.class.isAssignableFrom(method.getReturnType())) {
                    continue;
                }
                method.setAccessible(true);
                module.intercept(method, "framework.resolution-votes", chain -> {
                    Object original = chain.proceed();
                    if (!(original instanceof SparseArray<?>)) {
                        return original;
                    }
                    int displayId = ((Number) chain.getArg(0)).intValue();
                    if (displayId != DEFAULT_DISPLAY) {
                        return original;
                    }
                    alignAppSizeVote(module, (SparseArray<?>) original,
                            appSizePriority, userSizePriority);
                    return original;
                });
                installed++;
            }
            for (Method method : summaryClass.getDeclaredMethods()) {
                if (!"adjustSize".equals(method.getName())
                        || method.getParameterCount() != 2
                        || method.getReturnType() != void.class) {
                    continue;
                }
                method.setAccessible(true);
                module.intercept(method, "framework.resolution-summary", chain -> {
                    Object result = chain.proceed();
                    forcePreferredGeometry(module, chain.getThisObject());
                    return result;
                });
                installed++;
            }
            for (Method method : summaryClass.getDeclaredMethods()) {
                if (!"filterModes".equals(method.getName())
                        || method.getParameterCount() != 1
                        || !List.class.isAssignableFrom(method.getReturnType())) {
                    continue;
                }
                method.setAccessible(true);
                module.intercept(method, "framework.resolution-filter", chain -> {
                    forcePreferredGeometry(module, chain.getThisObject());
                    return chain.proceed();
                });
                installed++;
            }
            if (installed != 3) {
                throw new NoSuchMethodException("resolution hooks expected=3 actual="
                        + installed);
            }
            module.info("Framework resolution hooks installed=" + installed
                    + " model=" + model
                    + " appPriority=" + appSizePriority
                    + " userPriority=" + userSizePriority);
            return installed;
        } catch (Throwable error) {
            module.error("Framework resolution vote hook unavailable", error);
            return 0;
        }
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    private static void alignAppSizeVote(DisplaySettingsHook module,
                                         SparseArray<?> votes,
                                         int appPriority,
                                         int userPriority) {
        Object appVote = votes.get(appPriority);
        Object userVote = votes.get(userPriority);
        Geometry app = geometry(appVote);
        Geometry user = geometry(userVote);
        preferredGeometry = user.validRmx5200() ? user : Geometry.INVALID;
        CALCULATION_GEOMETRY.set(preferredGeometry);
        if (!app.validRmx5200() || !user.validRmx5200()
                || app.equals(user)) {
            return;
        }

        ((SparseArray) votes).put(appPriority, userVote);
        String rewrite = app + "->" + user;
        synchronized (FrameworkResolutionVoteHooks.class) {
            if (!rewrite.equals(lastRewrite)) {
                lastRewrite = rewrite;
                module.info("Framework resolution app-size vote aligned " + rewrite);
            }
        }
    }

    private static void forcePreferredGeometry(DisplaySettingsHook module,
                                               Object summary) {
        Geometry target = CALCULATION_GEOMETRY.get();
        if (target == null) {
            target = preferredGeometry;
        }
        if (!target.validRmx5200() || summary == null) {
            return;
        }
        try {
            Object widthValue = Reflect.getField(summary, "width");
            Object heightValue = Reflect.getField(summary, "height");
            if (!(widthValue instanceof Number) || !(heightValue instanceof Number)) {
                return;
            }
            Geometry adjusted = new Geometry(((Number) widthValue).intValue(),
                    ((Number) heightValue).intValue());
            if (target.equals(adjusted)) {
                return;
            }
            Reflect.setField(summary, "width", target.width);
            Reflect.setField(summary, "height", target.height);
            String change = adjusted + "->" + target;
            synchronized (FrameworkResolutionVoteHooks.class) {
                if (!change.equals(lastAdjusted)) {
                    lastAdjusted = change;
                    module.info("Framework resolution summary fixed " + change);
                }
            }
        } catch (ReflectiveOperationException error) {
            module.error("Framework resolution summary fix failed", error);
        }
    }

    private static Geometry geometry(Object vote) {
        if (vote == null) {
            return Geometry.INVALID;
        }
        try {
            Object width = Reflect.getField(vote, "mWidth");
            Object height = Reflect.getField(vote, "mHeight");
            if (width instanceof Number && height instanceof Number) {
                return new Geometry(((Number) width).intValue(),
                        ((Number) height).intValue());
            }
        } catch (ReflectiveOperationException ignored) {
            // Non-size votes are not candidates for alignment.
        }
        return Geometry.INVALID;
    }

    private static int staticInt(Class<?> owner, String name)
            throws ReflectiveOperationException {
        Field field = owner.getDeclaredField(name);
        field.setAccessible(true);
        return field.getInt(null);
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
            return (width == FHD_WIDTH && height == FHD_HEIGHT)
                    || (width == QHD_WIDTH && height == QHD_HEIGHT);
        }

        @Override
        public boolean equals(Object other) {
            if (!(other instanceof Geometry)) {
                return false;
            }
            Geometry geometry = (Geometry) other;
            return width == geometry.width && height == geometry.height;
        }

        @Override
        public int hashCode() {
            return 31 * width + height;
        }

        @Override
        public String toString() {
            return width + "x" + height;
        }
    }
}
