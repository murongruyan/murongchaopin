package com.murongchaopin.displayhook;

import android.view.View;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

final class Reflect {
    private Reflect() {
    }

    static Object getField(Object owner, String name) throws ReflectiveOperationException {
        if (owner == null) {
            return null;
        }
        for (Class<?> type = owner.getClass(); type != null; type = type.getSuperclass()) {
            try {
                Field field = type.getDeclaredField(name);
                field.setAccessible(true);
                return field.get(owner);
            } catch (NoSuchFieldException ignored) {
                // Continue through the hierarchy.
            }
        }
        throw new NoSuchFieldException(name);
    }

    static void setField(Object owner, String name, Object value)
            throws ReflectiveOperationException {
        for (Class<?> type = owner.getClass(); type != null; type = type.getSuperclass()) {
            try {
                Field field = type.getDeclaredField(name);
                field.setAccessible(true);
                field.set(owner, value);
                return;
            } catch (NoSuchFieldException ignored) {
                // Continue through the hierarchy.
            }
        }
        throw new NoSuchFieldException(name);
    }

    static Object fieldByTypeName(Object owner, String typeName) {
        if (owner == null) {
            return null;
        }
        for (Class<?> type = owner.getClass(); type != null; type = type.getSuperclass()) {
            for (Field field : type.getDeclaredFields()) {
                if (!typeName.equals(field.getType().getName())) {
                    continue;
                }
                try {
                    field.setAccessible(true);
                    return field.get(owner);
                } catch (ReflectiveOperationException ignored) {
                    // Try the next matching field.
                }
            }
        }
        return null;
    }

    static Object fieldAssignableTo(Object owner, Class<?> wanted) {
        if (owner == null) {
            return null;
        }
        for (Class<?> type = owner.getClass(); type != null; type = type.getSuperclass()) {
            for (Field field : type.getDeclaredFields()) {
                if (!wanted.isAssignableFrom(field.getType())
                        || Modifier.isStatic(field.getModifiers())) {
                    continue;
                }
                try {
                    field.setAccessible(true);
                    Object value = field.get(owner);
                    if (value != null) {
                        return value;
                    }
                } catch (ReflectiveOperationException ignored) {
                    // Try the next matching field.
                }
            }
        }
        return null;
    }

    static Object staticFieldAssignableTo(Class<?> owner, Class<?> wanted) {
        for (Class<?> type = owner; type != null; type = type.getSuperclass()) {
            for (Field field : type.getDeclaredFields()) {
                if (!Modifier.isStatic(field.getModifiers())
                        || !wanted.isAssignableFrom(field.getType())) {
                    continue;
                }
                try {
                    field.setAccessible(true);
                    Object value = field.get(null);
                    if (value != null) {
                        return value;
                    }
                } catch (ReflectiveOperationException ignored) {
                    // Try the next singleton field.
                }
            }
        }
        return null;
    }

    static Object call(Object owner, String name, Object... args)
            throws ReflectiveOperationException {
        if (owner == null) {
            throw new NullPointerException(name);
        }
        Method method = findMethod(owner.getClass(), name, args, false);
        method.setAccessible(true);
        return method.invoke(owner, args);
    }

    static Object callStatic(Class<?> owner, String name, Object... args)
            throws ReflectiveOperationException {
        Method method = findMethod(owner, name, args, true);
        method.setAccessible(true);
        return method.invoke(null, args);
    }

    static Object newInstance(Class<?> owner, Object... args)
            throws ReflectiveOperationException {
        for (Constructor<?> constructor : owner.getDeclaredConstructors()) {
            if (compatible(constructor.getParameterTypes(), args)) {
                constructor.setAccessible(true);
                return constructor.newInstance(args);
            }
        }
        throw new NoSuchMethodException(owner.getName() + ".<init>");
    }

    static View findView(Object owner, int id) {
        if (owner == null || id == 0) {
            return null;
        }
        if (owner instanceof View) {
            View found = ((View) owner).findViewById(id);
            if (found != null) {
                return found;
            }
        }
        for (Class<?> type = owner.getClass(); type != null; type = type.getSuperclass()) {
            for (Field field : type.getDeclaredFields()) {
                if (!View.class.isAssignableFrom(field.getType())) {
                    continue;
                }
                try {
                    field.setAccessible(true);
                    Object value = field.get(owner);
                    if (value instanceof View) {
                        View found = ((View) value).findViewById(id);
                        if (found != null) {
                            return found;
                        }
                    }
                } catch (ReflectiveOperationException ignored) {
                    // Try the next view field.
                }
            }
        }
        return null;
    }

    private static Method findMethod(Class<?> owner, String name, Object[] args,
                                     boolean requireStatic) throws NoSuchMethodException {
        for (Class<?> type = owner; type != null; type = type.getSuperclass()) {
            for (Method method : type.getDeclaredMethods()) {
                if (name.equals(method.getName())
                        && (!requireStatic || Modifier.isStatic(method.getModifiers()))
                        && compatible(method.getParameterTypes(), args)) {
                    return method;
                }
            }
        }
        throw new NoSuchMethodException(owner.getName() + "." + name);
    }

    private static boolean compatible(Class<?>[] parameters, Object[] args) {
        if (parameters.length != args.length) {
            return false;
        }
        for (int index = 0; index < parameters.length; index++) {
            if (args[index] == null) {
                if (parameters[index].isPrimitive()) {
                    return false;
                }
                continue;
            }
            Class<?> parameter = wrap(parameters[index]);
            if (!parameter.isAssignableFrom(args[index].getClass())) {
                return false;
            }
        }
        return true;
    }

    private static Class<?> wrap(Class<?> type) {
        if (!type.isPrimitive()) {
            return type;
        }
        if (type == boolean.class) return Boolean.class;
        if (type == byte.class) return Byte.class;
        if (type == short.class) return Short.class;
        if (type == int.class) return Integer.class;
        if (type == long.class) return Long.class;
        if (type == float.class) return Float.class;
        if (type == double.class) return Double.class;
        if (type == char.class) return Character.class;
        return Void.class;
    }
}
