package com.murongchaopin.displayhook;

import android.app.Activity;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Build;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebView;
import android.window.BackEvent;
import android.window.OnBackAnimationCallback;
import android.window.OnBackInvokedDispatcher;

import java.lang.reflect.Method;
import java.util.Collections;
import java.util.Map;
import java.util.WeakHashMap;

/** Bridges Android predictive-back progress into KernelSU module WebUIs. */
final class KernelSuWebUiHooks {
    private static final String ACTIVITY =
            "me.weishu.kernelsu.ui.webui.WebUIActivity";
    private static final Map<Activity, OnBackAnimationCallback> CALLBACKS =
            Collections.synchronizedMap(new WeakHashMap<>());
    private static final Map<Activity, Boolean> OPAQUE_ACTIVITIES =
            Collections.synchronizedMap(new WeakHashMap<>());

    private KernelSuWebUiHooks() {
    }

    static void install(DisplaySettingsHook module, ClassLoader loader) throws Throwable {
        if (Build.VERSION.SDK_INT < 34) {
            module.info("KernelSU predictive back skipped below Android 14");
            return;
        }
        Class<?> owner = Class.forName(ACTIVITY, false, loader);
        Method onCreate = lifecycleMethod(owner, "onCreate", 1);
        Method onDestroy = lifecycleMethod(owner, "onDestroy", 0);
        if (onCreate == null) {
            throw new NoSuchMethodException(ACTIVITY + ".onCreate");
        }
        onCreate.setAccessible(true);
        module.intercept(onCreate, "ksu.webui.predictive.create", chain -> {
            Object result = chain.proceed();
            Object ownerObject = chain.getThisObject();
            if (ownerObject instanceof Activity) {
                Activity activity = (Activity) ownerObject;
                configureWindow(module, activity);
                activity.getWindow().getDecorView().post(() -> {
                    configureWindow(module, activity);
                    register(module, activity);
                });
            }
            return result;
        });
        if (onDestroy != null) {
            onDestroy.setAccessible(true);
            module.intercept(onDestroy, "ksu.webui.predictive.destroy", chain -> {
                Object ownerObject = chain.getThisObject();
                if (ownerObject instanceof Activity) {
                    unregister(module, (Activity) ownerObject);
                }
                return chain.proceed();
            });
        }
        module.info("KernelSU WebUI predictive-back hook installed");
    }

    private static Method lifecycleMethod(Class<?> owner, String name, int parameterCount) {
        for (Class<?> type = owner; type != null; type = type.getSuperclass()) {
            for (Method method : type.getDeclaredMethods()) {
                if (name.equals(method.getName())
                        && method.getParameterCount() == parameterCount) {
                    return method;
                }
            }
        }
        return null;
    }

    private static void register(DisplaySettingsHook module, Activity activity) {
        if (CALLBACKS.containsKey(activity)) {
            return;
        }
        try {
            OnBackAnimationCallback callback = new OnBackAnimationCallback() {
                private WebView webView;

                @Override
                public void onBackStarted(BackEvent event) {
                    webView = findWebView(activity.getWindow().getDecorView());
                    dispatch(webView, "start", event.getProgress(), event.getSwipeEdge());
                }

                @Override
                public void onBackProgressed(BackEvent event) {
                    if (webView == null) {
                        webView = findWebView(activity.getWindow().getDecorView());
                    }
                    dispatch(webView, "progress", event.getProgress(), event.getSwipeEdge());
                }

                @Override
                public void onBackCancelled() {
                    dispatch(webView, "cancel", 0f, BackEvent.EDGE_NONE);
                    webView = null;
                }

                @Override
                public void onBackInvoked() {
                    WebView target = webView != null
                            ? webView : findWebView(activity.getWindow().getDecorView());
                    dispatch(target, "invoke", 1f, BackEvent.EDGE_NONE);
                    webView = null;
                    if (target != null && target.canGoBack()) {
                        target.goBack();
                    } else {
                        activity.finish();
                        activity.overridePendingTransition(0, 0);
                    }
                }
            };
            activity.getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    OnBackInvokedDispatcher.PRIORITY_OVERLAY, callback);
            CALLBACKS.put(activity, callback);
            module.info("KernelSU WebUI predictive-back callback registered");
        } catch (Throwable error) {
            module.error("KernelSU WebUI predictive-back registration failed", error);
        }
    }

    private static void unregister(DisplaySettingsHook module, Activity activity) {
        OPAQUE_ACTIVITIES.remove(activity);
        OnBackAnimationCallback callback = CALLBACKS.remove(activity);
        if (callback == null) {
            return;
        }
        try {
            activity.getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(callback);
        } catch (Throwable error) {
            module.error("KernelSU WebUI predictive-back unregister failed", error);
        }
    }

    private static void configureWindow(DisplaySettingsHook module, Activity activity) {
        boolean dark = (activity.getResources().getConfiguration().uiMode
                & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        int background = Color.parseColor(dark ? "#171218" : "#FFF8FC");
        activity.getWindow().setBackgroundDrawable(new ColorDrawable(background));
        activity.getWindow().setWindowAnimations(0);
        activity.getWindow().getDecorView().setBackgroundColor(background);
        activity.overridePendingTransition(0, 0);
        WebView webView = findWebView(activity.getWindow().getDecorView());
        if (webView != null) {
            webView.setBackgroundColor(background);
        }
        if (!OPAQUE_ACTIVITIES.containsKey(activity)) {
            try {
                Method setTranslucent = Activity.class.getMethod("setTranslucent", boolean.class);
                Object result = setTranslucent.invoke(activity, false);
                if (Boolean.FALSE.equals(result)) {
                    Method convert = Activity.class.getDeclaredMethod("convertFromTranslucent");
                    convert.setAccessible(true);
                    convert.invoke(activity);
                }
                OPAQUE_ACTIVITIES.put(activity, Boolean.TRUE);
                module.info("KernelSU WebUI activity converted to opaque");
            } catch (Throwable error) {
                OPAQUE_ACTIVITIES.put(activity, Boolean.FALSE);
                module.error("KernelSU WebUI opaque conversion failed", error);
            }
        }
    }

    private static WebView findWebView(View view) {
        if (view instanceof WebView) {
            return (WebView) view;
        }
        if (!(view instanceof ViewGroup)) {
            return null;
        }
        ViewGroup group = (ViewGroup) view;
        for (int index = 0; index < group.getChildCount(); index++) {
            WebView found = findWebView(group.getChildAt(index));
            if (found != null) {
                return found;
            }
        }
        return null;
    }

    private static void dispatch(WebView webView, String type, float progress, int edge) {
        if (webView == null) {
            return;
        }
        float bounded = Math.max(0f, Math.min(1f, progress));
        String script = "window.__murongPredictiveBack&&window.__murongPredictiveBack('"
                + type + "'," + Float.toString(bounded) + "," + edge + ")";
        webView.evaluateJavascript(script, null);
    }
}
