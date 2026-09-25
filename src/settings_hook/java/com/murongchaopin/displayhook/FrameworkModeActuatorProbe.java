package com.murongchaopin.displayhook;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

/**
 * Read-only diagnostic. Finds the framework call that actually hands a mode or
 * a DisplayModeSpecs to the display device, so the custom-LTPO route can be
 * applied where the framework decides instead of poking SurfaceFlinger.
 */
final class FrameworkModeActuatorProbe {
    private static final String LOCAL_DISPLAY_DEVICE =
            "com.android.server.display.LocalDisplayAdapter$LocalDisplayDevice";
    private static volatile String lastSpecs = "";
    private static volatile String lastPreferred = "";

    private FrameworkModeActuatorProbe() {
    }

    static int install(DisplaySettingsHook module, ClassLoader loader) {
        int installed = 0;
        try {
            Class<?> owner = Class.forName(LOCAL_DISPLAY_DEVICE, false, loader);
            for (Method method : owner.getDeclaredMethods()) {
                String name = method.getName();
                Class<?>[] params = method.getParameterTypes();

                if (!name.startsWith("set")) {
                    continue;
                }
                StringBuilder signature = new StringBuilder();
                for (Class<?> param : params) {
                    signature.append(' ').append(param.getSimpleName());
                }
                module.info("MODEACTUATOR method=" + name + " returns="
                        + method.getReturnType().getSimpleName() + " args="
                        + params.length + signature);
                if (params.length != 1 || method.getReturnType() != void.class) {
                    continue;
                }
                if (name.contains("DesiredDisplayModeSpecs")) {
                    method.setAccessible(true);
                    module.intercept(method, "mode.actuator.specs", chain -> {
                        describe(module, name, chain.getArg(0), true);
                        return chain.proceed();
                    });
                    installed++;
                } else if (name.contains("PreferredDisplayMode")) {
                    method.setAccessible(true);
                    module.intercept(method, "mode.actuator.preferred", chain -> {
                        describe(module, name, chain.getArg(0), false);
                        return chain.proceed();
                    });
                    installed++;
                }
            }
        } catch (Throwable error) {
            module.error("MODEACTUATOR probe unavailable", error);
        }
        module.info("MODEACTUATOR probe installed=" + installed);
        return installed;
    }

    private static void describe(DisplaySettingsHook module, String name,
                                 Object argument, boolean dumpFields) {
        try {
            String text;

            if (argument == null) {
                text = "arg=null";
            } else if (!dumpFields) {
                text = "arg=" + argument.getClass().getName();
            } else {
                StringBuilder builder = new StringBuilder();
                Class<?> type = argument.getClass();

                builder.append("class=").append(type.getName());
                for (Field field : type.getDeclaredFields()) {
                    if (Modifier.isStatic(field.getModifiers())) {
                        continue;
                    }
                    field.setAccessible(true);
                    Object value = field.get(argument);
                    builder.append(' ').append(field.getName()).append('=');
                    if (value == null) {
                        builder.append("null");
                    } else if (value instanceof int[]) {
                        int[] array = (int[]) value;
                        builder.append('[');
                        for (int i = 0; i < Math.min(array.length, 16); i++) {
                            if (i > 0) builder.append(',');
                            builder.append(array[i]);
                        }
                        builder.append(']');
                    } else if (value instanceof Object[]) {
                        builder.append("len=").append(((Object[]) value).length);
                    } else if (value instanceof Number || value instanceof Boolean
                            || value instanceof CharSequence) {
                        builder.append(value);
                    } else {
                        builder.append(value.getClass().getSimpleName());
                    }
                }
                text = builder.toString();
            }
            String previous = dumpFields ? lastSpecs : lastPreferred;

            if (!text.equals(previous)) {
                if (dumpFields) {
                    lastSpecs = text;
                } else {
                    lastPreferred = text;
                }
                module.info("MODEACTUATOR " + name + " " + text);
            }
        } catch (Throwable error) {
            module.error("MODEACTUATOR describe failed", error);
        }
    }
}
