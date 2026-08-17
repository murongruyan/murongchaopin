package com.murongchaopin.display;

import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;

/**
 * Runs through app_process as root and deliberately uses the same public
 * OplusDisplayModeManager calls that the Settings APK uses via reflection.
 */
public final class DisplaySettingsBridge {
    private static final String MANAGER = "com.oplus.screenmode.OplusDisplayModeManager";
    private static final String LIST_KEY = "RefreshRateList";
    private static final String SURFACE_COMPOSER_DESCRIPTOR =
            "android.gui.ISurfaceComposer";
    private static final int SCHEDULE_COMMIT_TRANSACTION = 66;

    private DisplaySettingsBridge() {
    }

    private static Object manager() throws ReflectiveOperationException {
        Class<?> cls = Class.forName(MANAGER);
        Constructor<?> constructor = cls.getDeclaredConstructor();
        constructor.setAccessible(true);
        return constructor.newInstance();
    }

    private static void dump() throws ReflectiveOperationException {
        Object instance = manager();
        Method method = instance.getClass().getDeclaredMethod("getAppOverrideRefreshRateList");
        method.setAccessible(true);
        Object result = method.invoke(instance);
        if (!(result instanceof Bundle)) {
            throw new IllegalStateException("getAppOverrideRefreshRateList returned no Bundle");
        }

        ArrayList<String> values = ((Bundle) result).getStringArrayList(LIST_KEY);
        if (values == null) {
            return;
        }
        Collections.sort(values);
        for (String value : values) {
            if (value == null) {
                continue;
            }
            int separator = value.lastIndexOf(',');
            if (separator <= 0 || separator == value.length() - 1) {
                continue;
            }
            String packageName = value.substring(0, separator);
            String mode = value.substring(separator + 1);
            if (packageName.matches("[A-Za-z0-9_.]+") && mode.matches("[0-9]+")) {
                System.out.println(packageName + "=" + mode);
            }
        }
    }

    private static void set(String packageName, int mode) throws ReflectiveOperationException {
        if (!packageName.matches("[A-Za-z0-9_.]+") || mode < 0 || mode > 15) {
            throw new IllegalArgumentException("invalid package or Oplus refresh mode");
        }
        Object instance = manager();
        Method method = instance.getClass().getDeclaredMethod(
                "setAppOverrideRefreshRate", String.class, Integer.TYPE, Integer.TYPE);
        method.setAccessible(true);
        method.invoke(instance, packageName, 3, mode);
        System.out.println("ok=" + packageName + ",mode=" + mode);
    }

    private static void get(String packageName) throws ReflectiveOperationException {
        if (!packageName.matches("[A-Za-z0-9_.]+")) {
            throw new IllegalArgumentException("invalid package");
        }
        Object instance = manager();
        Method method = instance.getClass().getDeclaredMethod(
                "getAppOverrideRefreshRate", String.class, Integer.TYPE);
        method.setAccessible(true);
        Object result = method.invoke(instance, packageName, 3);
        if (!(result instanceof Integer)) {
            throw new IllegalStateException("getAppOverrideRefreshRate returned no integer");
        }
        int raw = ((Integer) result).intValue();
        int mode = raw;
        if (raw != 0) {
            int high = raw >> 4;
            int low = raw & 15;
            mode = high == 0 ? low : high;
        }
        System.out.println(packageName + "=" + mode);
    }

    private static void clear() throws ReflectiveOperationException {
        Object instance = manager();
        Method method = instance.getClass().getDeclaredMethod("removeAllCustomizeRefreshRate");
        method.setAccessible(true);
        method.invoke(instance);
        System.out.println("ok=clear");
    }

    private static void scheduleCommit() throws Exception {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        Method getService = serviceManager.getDeclaredMethod("getService", String.class);
        getService.setAccessible(true);
        Object service = getService.invoke(null, "SurfaceFlinger");
        if (!(service instanceof IBinder)) {
            throw new IllegalStateException("SurfaceFlinger binder unavailable");
        }

        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(SURFACE_COMPOSER_DESCRIPTOR);
            if (!((IBinder) service).transact(SCHEDULE_COMMIT_TRANSACTION,
                    data, reply, 0)) {
                throw new IllegalStateException("scheduleCommit transaction unhandled");
            }
            reply.readException();
            System.out.println("ok=schedule-commit");
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    public static void main(String[] args) {
        try {
            if (args.length == 1 && "dump".equals(args[0])) {
                dump();
                return;
            }
            if (args.length == 3 && "set".equals(args[0])) {
                set(args[1], Integer.parseInt(args[2]));
                return;
            }
            if (args.length == 2 && "get".equals(args[0])) {
                get(args[1]);
                return;
            }
            if (args.length == 1 && "clear".equals(args[0])) {
                clear();
                return;
            }
            if (args.length == 1 && "schedule-commit".equals(args[0])) {
                scheduleCommit();
                return;
            }
            System.err.println("Usage: DisplaySettingsBridge dump | get <package> | "
                    + "set <package> <mode> | clear | schedule-commit");
            System.exit(64);
        } catch (Throwable error) {
            System.err.println("DisplaySettingsBridge: " + error.getClass().getSimpleName()
                    + ": " + error.getMessage());
            error.printStackTrace(System.err);
            System.exit(1);
        }
    }
}
