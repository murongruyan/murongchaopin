package com.murongchaopin.displayhook;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Display;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;

/** Communicates only with the root daemon bound to the device loopback address. */
final class BridgeClient {
    static final int PORT = 49721;
    private static final String TOKEN =
            "api102-6d85e308abce16567fdd668dcd12ebadf5f82bdaa78dc6023f04fcee9795f6c4";
    private static final int TIMEOUT_MS = 400;
    private static final int MODE_TIMEOUT_MS = 4000;
    private static final int RESOLUTION_TIMEOUT_MS = 8000;
    private static final long RATES_TTL_MS = 15000L;
    private static final long PING_TTL_MS = 10000L;
    private static final long STATE_TTL_MS = 1200L;
    private static final long LTPO_TTL_MS = 250L;
    private static final long LTPO_FAIL_TTL_MS = 2000L;
    private static final int LTPO_TIMEOUT_MS = 200;
    private static final long LTPO_HOLD_MS = 3000L;
    /**
     * Failure backoff shared by the background refreshers. A daemon that is
     * unavailable or timing out must not turn every framework callback into a
     * fresh connect() attempt.
     */
    static final long FAIL_BACKOFF_MS = 5000L;
    /** How long a background-refreshed rate snapshot stays fresh. */
    private static final long GLOBAL_RATE_TTL_MS = 5000L;
    private static final ExecutorService IO = Executors.newCachedThreadPool(runnable -> {
        Thread thread = new Thread(runnable, "MurongDisplayHookIo");
        thread.setDaemon(true);
        return thread;
    });
    /**
     * Single background refresher for the values the framework hooks read. Its
     * tasks may block on the loopback socket; the hooks never wait for them and
     * only read the volatile snapshots declared here.
     */
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "MurongBridgeRefresh");
        thread.setDaemon(true);
        return thread;
    });
    private static final AtomicBoolean GLOBAL_RATE_REFRESH = new AtomicBoolean();
    private static final AtomicBoolean LTPO_REFRESH = new AtomicBoolean();
    private static volatile int cachedGlobalRate = -1;
    private static volatile long cachedGlobalRateAt;
    private static volatile long bridgeFailureAt;
    private static volatile long ltpoRouteRefreshAt;
    private static final Object RATES_LOCK = new Object();
    private static final ConcurrentHashMap<String, CachedValue> READ_CACHE =
            new ConcurrentHashMap<>();
    private static volatile LtpoRoute ltpoRouteCache;
    private static volatile long ltpoRouteCachedAt;
    private static volatile long ltpoRouteLastGoodAt;
    private static volatile List<Integer> hwcRatesCache;
    private static volatile long hwcRatesCachedAt;
    private static volatile boolean ratesLoading;

    private BridgeClient() {
    }

    static List<Integer> displayRates(Context context) {
        List<Integer> base = baseRates(context);
        List<Integer> hwc = hwcRatesCache;
        if (hwc != null && SystemClock.elapsedRealtime() - hwcRatesCachedAt
                < RATES_TTL_MS) {
            return mergeRates(base, hwc);
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            // Never block the Settings/Game UI main thread with a loopback
            // round trip. Return the Display-backed list immediately and let
            // the HWC list warm up in the background.
            warmRatesAsync();
            return base;
        }
        return mergeRates(base, fetchHwcRates());
    }

    private static List<Integer> baseRates(Context context) {
        if (context == null) {
            return Collections.emptyList();
        }
        DisplayManager manager = (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
        Display display = manager == null ? null : manager.getDisplay(Display.DEFAULT_DISPLAY);
        if (display == null) {
            return Collections.emptyList();
        }

        Display.Mode activeMode = display.getMode();
        int activeWidth = activeMode.getPhysicalWidth();
        int activeHeight = activeMode.getPhysicalHeight();
        LinkedHashSet<Integer> rates = new LinkedHashSet<>();
        for (Display.Mode mode : display.getSupportedModes()) {
            if (mode.getPhysicalWidth() != activeWidth
                    || mode.getPhysicalHeight() != activeHeight) {
                continue;
            }
            int fps = Math.round(mode.getRefreshRate());
            if (fps >= 30 && fps <= 1000) {
                rates.add(fps);
            }
        }
        ArrayList<Integer> sorted = new ArrayList<>(rates);
        Collections.sort(sorted);
        return sorted;
    }

    private static List<Integer> mergeRates(List<Integer> base, List<Integer> hwc) {
        if (hwc == null || hwc.isEmpty()) {
            return base;
        }
        LinkedHashSet<Integer> merged = new LinkedHashSet<>(base);
        for (int fps : hwc) {
            if (fps >= 30 && fps <= 1000) {
                merged.add(fps);
            }
        }
        ArrayList<Integer> sorted = new ArrayList<>(merged);
        Collections.sort(sorted);
        return sorted;
    }

    private static List<Integer> fetchHwcRates() {
        String response = requestSocket("LISTRATES", TIMEOUT_MS);
        ArrayList<Integer> parsed = new ArrayList<>();
        if (response.startsWith("RATES ")) {
            String[] fields = response.substring(6).trim().split("\\s+");
            for (String field : fields) {
                try {
                    int fps = Integer.parseInt(field);
                    if (fps >= 30 && fps <= 1000) {
                        parsed.add(fps);
                    }
                } catch (NumberFormatException ignored) {
                    // Ignore a malformed bridge field and keep valid Display modes.
                }
            }
            Collections.sort(parsed);
            if (!parsed.isEmpty()) {
                synchronized (RATES_LOCK) {
                    hwcRatesCache = parsed;
                    hwcRatesCachedAt = SystemClock.elapsedRealtime();
                }
            }
        }
        return parsed;
    }

    private static void warmRatesAsync() {
        synchronized (RATES_LOCK) {
            if (ratesLoading) {
                return;
            }
            ratesLoading = true;
        }
        IO.execute(() -> {
            try {
                fetchHwcRates();
            } finally {
                synchronized (RATES_LOCK) {
                    ratesLoading = false;
                }
            }
        });
    }

    static boolean setAppRate(String packageName, int fps) {
        if (!validPackage(packageName) || fps < 30 || fps > 1000) {
            return false;
        }
        return request("SET " + packageName + " " + fps).startsWith("OK ");
    }

    /** Persist an app override with the exact geometry visible to Settings. */
    static boolean setAppMode(String packageName, int width, int height, int fps) {
        if (!validPackage(packageName) || !validDisplaySize(width, height)
                || fps < 30 || fps > 1000) {
            return false;
        }
        return request("SETAPP " + packageName + " " + width + " " + height + " " + fps,
                MODE_TIMEOUT_MS).startsWith("OK ");
    }

    static boolean isAvailable() {
        return request("PING").startsWith("OK API ");
    }

    static boolean setGlobalRate(int fps) {
        if (fps < 30 || fps > 1000) {
            return false;
        }
        return request("SETGLOBAL " + fps, MODE_TIMEOUT_MS).startsWith("OK ");
    }

    static boolean setGlobalResolution(int width) {
        if (!validDisplayWidth(width)) {
            return false;
        }
        return request("SETRES " + width, RESOLUTION_TIMEOUT_MS)
                .startsWith("OK ");
    }

    static int prepareGlobalResolution(int width) {
        if (width < 480 || width > 10000) {
            return -1;
        }
        return parseOkIntResponse(request("PREPRES " + width, 2000));
    }

    static boolean adoptGlobalResolution(int targetWidth, int sourceWidth,
                                         long generation) {
        if (!validDisplayWidth(targetWidth)
                || !validDisplayWidth(sourceWidth)
                || generation <= 0) {
            return false;
        }
        return request("ADOPTRES " + targetWidth + " " + sourceWidth + " "
                        + generation,
                RESOLUTION_TIMEOUT_MS).startsWith("OK ");
    }

    static boolean setGlobalMode(int width, int fps) {
        if (!validDisplayWidth(width) || fps < 30 || fps > 1000) {
            return false;
        }
        return request("SETMODE " + width + " " + fps,
                RESOLUTION_TIMEOUT_MS)
                .startsWith("OK ");
    }

    static boolean startVideoModeFollow() {
        return request("VIDEOSTART FOLLOW", RESOLUTION_TIMEOUT_MS).startsWith("OK ");
    }

    static boolean startVideoMode(int fps) {
        return fps >= 30 && fps <= 1000
                && request("VIDEOSTART " + fps, RESOLUTION_TIMEOUT_MS).startsWith("OK ");
    }

    static boolean startVideoModeVendorOwned() {
        return request("VIDEOSTART VENDOR", RESOLUTION_TIMEOUT_MS).startsWith("OK ");
    }

    static boolean endVideoMode() {
        return request("VIDEOEND", RESOLUTION_TIMEOUT_MS).startsWith("OK ");
    }

    static boolean boostLtpo() {
        return request("LTPOBOOST", 1000).startsWith("OK ");
    }

    static boolean signalStoryPageEvent(String phase) {
        if (!("PREPARE".equals(phase) || "FIRST_FRAME".equals(phase))) {
            return false;
        }
        return request("STORYPAGE " + phase + " " + SystemClock.elapsedRealtime(),
                1200).startsWith("OK ");
    }

    static int displayWidth(Context context) {
        Display display = defaultDisplay(context);
        return display == null ? -1 : display.getMode().getPhysicalWidth();
    }

    static boolean setGlobalAuto() {
        return request("SETAUTO").startsWith("OK ");
    }

    /**
     * Blocking global-rate read, kept for worker or user-initiated callers.
     * Hook callbacks that run on a framework thread must use
     * {@link #globalRateSnapshot()} together with
     * {@link #refreshGlobalRateAsync()} instead: those never wait for the
     * daemon.
     */
    static int globalRate() {
        return parseFpsResponse(request("GETGLOBAL"));
    }

    /**
     * Last global rate a background refresh observed, or -1 while the daemon
     * never answered. Reading it is a single volatile load, so a Hooker may
     * call it while holding a framework lock without stalling the system.
     */
    static int globalRateSnapshot() {
        return cachedGlobalRate;
    }

    /**
     * Seed the global-rate snapshot from the calling thread.
     *
     * <p>Hook install runs on an LSPosed worker before the first framework
     * callback, so one blocking GETGLOBAL here is safe. It is also required:
     * {@link #refreshGlobalRateAsync()} returns before its answer lands, so the
     * first setAppRequest of a fresh process used to read -1, skip the override
     * and leave the vendor ceiling in place (field report: the game assistant
     * kept its stock rate after the non-blocking change).
     */
    static int primeGlobalRate() {
        int value = parseFpsResponse(request("GETGLOBAL"));
        long at = SystemClock.elapsedRealtime();
        if (value >= 30) {
            cachedGlobalRate = value;
            cachedGlobalRateAt = at;
            bridgeFailureAt = 0L;
        } else {
            bridgeFailureAt = at;
        }
        return value;
    }

    /**
     * Posts at most one background GETGLOBAL. The snapshot keeps its previous
     * value until a new answer lands, and {@link #FAIL_BACKOFF_MS} keeps an
     * unavailable daemon from being reconnected once per framework callback.
     */
    static void refreshGlobalRateAsync() {
        long now = SystemClock.elapsedRealtime();
        if (now - cachedGlobalRateAt < GLOBAL_RATE_TTL_MS) {
            return;
        }
        if (now - bridgeFailureAt < FAIL_BACKOFF_MS) {
            return;
        }
        if (!GLOBAL_RATE_REFRESH.compareAndSet(false, true)) {
            return;
        }
        WORKER.execute(() -> {
            try {
                int value = parseFpsResponse(requestSocket("GETGLOBAL", TIMEOUT_MS));
                long at = SystemClock.elapsedRealtime();
                if (value >= 30) {
                    cachedGlobalRate = value;
                    cachedGlobalRateAt = at;
                    bridgeFailureAt = 0L;
                } else {
                    bridgeFailureAt = at;
                }
            } finally {
                GLOBAL_RATE_REFRESH.set(false);
            }
        });
    }

    /**
     * Tells the daemon which package currently owns the foreground window.
     *
     * <p>The daemon used to run `dumpsys window` every two seconds just to learn
     * this. That dump executes inside system_server and holds
     * WindowManagerGlobalLock for its entire duration, which is the same lock the
     * system gesture listener needs -- a swipe that lands inside the dump is
     * delayed, and a chain of dumps starves input outright (field ANR:
     * "Input dispatching timed out ... Waited 5000ms for MotionEvent").
     *
     * <p>This must only be called from a bridge worker. It hands the write to the
     * cached IO pool and returns immediately, so even a stalled daemon cannot
     * delay the caller, and it is never retried: the daemon keeps its previous
     * foreground answer and its dumpsys fallback covers a missed push.
     */
    static void pushForegroundApp(String packageName) {
        if (!validPackage(packageName)) {
            return;
        }
        IO.execute(() -> requestSocket("FRONTAPP " + packageName, TIMEOUT_MS));
    }

    static ModeState globalMode() {
        return parseModeState(request("GETGLOBALSTATE"), 4);
    }

    static int globalModeId() {
        return parseModeId(request("GETGLOBALID"));
    }

    static int appRate(String packageName) {
        if (!validPackage(packageName)) {
            return -1;
        }
        String response = request("GET " + packageName);
        if (!response.startsWith("FPS ")) {
            return -1;
        }
        return parseFpsResponse(response);
    }

    static int appModeId(String packageName) {
        if (!validPackage(packageName)) {
            return -1;
        }
        return parseModeId(request("GETID " + packageName));
    }

    static boolean removeAppRate(String packageName) {
        return validPackage(packageName)
                && request("UNSET " + packageName).startsWith("OK ");
    }

    static boolean clearAppRates() {
        return request("CLEARAPPS").startsWith("OK ");
    }

    private static int parseFpsResponse(String response) {
        if (response == null || !response.startsWith("FPS ")) {
            return -1;
        }
        try {
            return Integer.parseInt(response.substring(4).trim());
        } catch (NumberFormatException ignored) {
            return -1;
        }
    }

    private static int parseOkIntResponse(String response) {
        if (response == null || !response.startsWith("OK ")) {
            return -1;
        }
        try {
            return Integer.parseInt(response.substring(3).trim());
        } catch (NumberFormatException ignored) {
            return -1;
        }
    }

    private static int parseModeId(String response) {
        if (response == null || !response.startsWith("MODE ")) {
            return -1;
        }
        String[] fields = response.trim().split("\\s+");
        if (fields.length < 2) {
            return -1;
        }
        try {
            return Integer.parseInt(fields[1]);
        } catch (NumberFormatException ignored) {
            return -1;
        }
    }

    private static ModeState parseModeState(String response, int expectedFields) {
        if (response == null || !response.startsWith("MODE ")) {
            return ModeState.INVALID;
        }
        String[] fields = response.trim().split("\\s+");
        if (fields.length != expectedFields + 1) {
            return ModeState.INVALID;
        }
        try {
            return new ModeState(Integer.parseInt(fields[1]), Integer.parseInt(fields[2]),
                    Integer.parseInt(fields[3]), Integer.parseInt(fields[4]));
        } catch (NumberFormatException ignored) {
            return ModeState.INVALID;
        }
    }

    static final class ModeState {
        static final ModeState INVALID = new ModeState(-1, -1, -1, -1);

        final int id;
        final int width;
        final int height;
        final int fps;

        ModeState(int id, int width, int height, int fps) {
            this.id = id;
            this.width = width;
            this.height = height;
            this.fps = fps;
        }

        boolean isValid() {
            return id >= 0 && width > 0 && height > 0 && fps >= 30;
        }
    }

    static String request(String command) {
        return request(command, TIMEOUT_MS);
    }

    /**
     * LTPS/LTPO route target published by the root daemon for the pure
     * "custom LTPO" policy. The daemon owns the activity decision; the hook
     * only needs this value to place the final mode id on the injected
     * low-rate node. Returns null when the module is not routing, so callers
     * keep their stock behaviour.
     *
     * <p>Never blocks. Every caller is installed on a framework path that runs
     * under WindowManagerGlobalLock (setDesiredDisplayModeSpecsLocked,
     * getModeId, getFinalDisplayModeIdLocked), so a stale cache only posts a
     * refresh on the bridge worker and the last known route is served until
     * the answer arrives ({@link #LTPO_HOLD_MS}).
     */
    static LtpoRoute ltpoRoute() {
        long now = SystemClock.elapsedRealtime();
        // The daemon also mirrors the route into a system property. Reading it
        // never blocks and does not depend on its main loop being free to serve
        // the socket, which is what made the bridge answer look "not routing"
        // while the daemon had already published a target.
        // Exactly one owner acts on the refresh rate. The daemon keeps
        // ownership by default (it enacts the node itself); it hands the route
        // over only when asked, so the framework path can never fight it.
        if (!"framework".equals(systemProperty(
                "murong.ltpo.route.owner", "daemon"))) {
            return null;
        }
        String mirrored = systemProperty("murong.ltpo.route", "");
        LtpoRoute cached = ltpoRouteCache;

        if (!mirrored.isEmpty()) {
            LtpoRoute property = LtpoRoute.parse("LTPO " + mirrored);

            if (property != LtpoRoute.INACTIVE || mirrored.startsWith("0 ")) {
                ltpoRouteCache = property;
                ltpoRouteCachedAt = now;
                ltpoRouteLastGoodAt = now;
                return property.isRouting() ? property : null;
            }
        }
        if (cached != null) {
            long ttl = cached.isRouting() ? LTPO_TTL_MS : LTPO_FAIL_TTL_MS;

            if (now - ltpoRouteCachedAt < ttl) {
                return cached.isRouting() ? cached : null;
            }
        }
        // The cached answer expired. This method is called from inside the
        // window manager's global lock (setDesiredDisplayModeSpecsLocked,
        // getModeId, getFinalDisplayModeIdLocked), so it must never wait for
        // the daemon: ask the refresh worker for a new answer and keep serving
        // the last known route until it lands.
        refreshLtpoRouteAsync(now);
        if (cached != null && now - ltpoRouteLastGoodAt < LTPO_HOLD_MS) {
            ltpoRouteCache = cached;
            ltpoRouteCachedAt = now;
            return cached.isRouting() ? cached : null;
        }
        return null;
    }

    /**
     * Posts at most one background GETLTPO. The daemon serves the bridge in
     * the same loop that shells out to dumpsys, so a query can time out; the
     * shared failure backoff then keeps the next framework callback from
     * reconnecting until the daemon had a chance to recover.
     */
    private static void refreshLtpoRouteAsync(long now) {
        if (now - ltpoRouteRefreshAt < LTPO_TTL_MS) {
            return;
        }
        if (now - bridgeFailureAt < FAIL_BACKOFF_MS) {
            return;
        }
        if (!LTPO_REFRESH.compareAndSet(false, true)) {
            return;
        }
        ltpoRouteRefreshAt = now;
        WORKER.execute(() -> {
            try {
                String response = requestSocket("GETLTPO", LTPO_TIMEOUT_MS);
                long at = SystemClock.elapsedRealtime();
                if (response == null || response.isEmpty()) {
                    // Transport hiccup: keep the last published route and stop
                    // reconnecting for the backoff window.
                    bridgeFailureAt = at;
                    return;
                }
                LtpoRoute parsed = LtpoRoute.parse(response);
                ltpoRouteCache = parsed;
                ltpoRouteCachedAt = at;
                ltpoRouteLastGoodAt = at;
                bridgeFailureAt = 0L;
            } finally {
                LTPO_REFRESH.set(false);
            }
        });
    }

    static final class LtpoRoute {
        static final LtpoRoute INACTIVE = new LtpoRoute(false, 0, false);

        final boolean routing;
        final int targetFps;
        final boolean active;

        LtpoRoute(boolean routing, int targetFps, boolean active) {
            this.routing = routing;
            this.targetFps = targetFps;
            this.active = active;
        }

        boolean isRouting() {
            return routing && targetFps > 0 && targetFps <= 240;
        }

        static LtpoRoute parse(String response) {
            if (response == null) {
                return INACTIVE;
            }
            String[] fields = response.trim().split("\\s+");

            if (fields.length < 4 || !"LTPO".equals(fields[0])) {
                return INACTIVE;
            }
            try {
                return new LtpoRoute(Integer.parseInt(fields[1]) != 0,
                        Integer.parseInt(fields[2]),
                        Integer.parseInt(fields[3]) != 0);
            } catch (NumberFormatException ignored) {
                return INACTIVE;
            }
        }
    }

    private static String request(String command, int timeoutMs) {
        String cached = cachedRead(command);
        if (cached != null) {
            return cached;
        }
        String response;
        // Settings and game UI callbacks run on the main thread. Android rejects
        // network I/O there for targetSdk >= 11, so perform the short loopback
        // transaction on a daemon worker and keep the existing bounded timeout.
        if (Looper.myLooper() == Looper.getMainLooper()) {
            Future<String> future = IO.submit(() -> requestSocket(command, timeoutMs));
            try {
                response = future.get(timeoutMs + 150L, TimeUnit.MILLISECONDS);
            } catch (TimeoutException timeout) {
                future.cancel(true);
                response = "";
            } catch (Exception ignored) {
                response = "";
            }
        } else {
            response = requestSocket(command, timeoutMs);
        }
        cacheRead(command, response);
        return response;
    }

    private static long readTtl(String command) {
        if (command.startsWith("PING")) {
            return PING_TTL_MS;
        }
        if (command.startsWith("GETGLOBAL") || command.startsWith("GET ")
                || command.startsWith("GETID ")) {
            return STATE_TTL_MS;
        }
        return 0L;
    }

    private static String cachedRead(String command) {
        long ttl = readTtl(command);
        if (ttl <= 0L) {
            return null;
        }
        CachedValue value = READ_CACHE.get(command);
        if (value != null && SystemClock.elapsedRealtime() - value.at < ttl) {
            return value.value;
        }
        return null;
    }

    private static void cacheRead(String command, String response) {
        if (response == null || response.isEmpty()) {
            return;
        }
        long ttl = readTtl(command);
        if (ttl > 0L) {
            READ_CACHE.put(command, new CachedValue(response,
                    SystemClock.elapsedRealtime()));
            return;
        }
        // A write (SET/SETGLOBAL/...) invalidates read caches so a follow-up
        // GET observes the new state instead of a stale snapshot.
        if (!READ_CACHE.isEmpty()) {
            READ_CACHE.clear();
        }
    }

    private static final class CachedValue {
        final String value;
        final long at;

        CachedValue(String value, long at) {
            this.value = value;
            this.at = at;
        }
    }

    private static String requestSocket(String command, int timeoutMs) {
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress("127.0.0.1", PORT), TIMEOUT_MS);
            socket.setSoTimeout(timeoutMs);
            BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(
                    socket.getOutputStream(), StandardCharsets.UTF_8));
            BufferedReader reader = new BufferedReader(new InputStreamReader(
                    socket.getInputStream(), StandardCharsets.UTF_8));
            writer.write("AUTH ");
            writer.write(TOKEN);
            writer.write(' ');
            writer.write(command);
            writer.write('\n');
            writer.flush();
            String response = reader.readLine();
            return response == null ? "" : response;
        } catch (Exception ignored) {
            return "";
        }
    }

    private static String systemProperty(String key, String fallback) {
        try {
            Class<?> properties = Class.forName("android.os.SystemProperties");
            java.lang.reflect.Method get = properties.getDeclaredMethod(
                    "get", String.class, String.class);
            get.setAccessible(true);
            Object value = get.invoke(null, key, fallback);
            return value instanceof String ? (String) value : fallback;
        } catch (Throwable ignored) {
            return fallback;
        }
    }

    static boolean validPackage(String packageName) {
        return packageName != null && packageName.matches("[A-Za-z0-9_.]+")
                && packageName.indexOf('.') > 0;
    }

    private static Display defaultDisplay(Context context) {
        if (context == null) {
            return null;
        }
        DisplayManager manager = (DisplayManager) context.getSystemService(
                Context.DISPLAY_SERVICE);
        return manager == null ? null : manager.getDisplay(Display.DEFAULT_DISPLAY);
    }

    private static boolean validDisplayWidth(int width) {
        return width >= 480 && width <= 10000;
    }

    private static boolean validDisplaySize(int width, int height) {
        return validDisplayWidth(width) && height >= 480 && height <= 20000;
    }
}
