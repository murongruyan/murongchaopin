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
    private static final ExecutorService IO = Executors.newCachedThreadPool(runnable -> {
        Thread thread = new Thread(runnable, "MurongDisplayHookIo");
        thread.setDaemon(true);
        return thread;
    });
    private static final Object RATES_LOCK = new Object();
    private static final ConcurrentHashMap<String, CachedValue> READ_CACHE =
            new ConcurrentHashMap<>();
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

    static int globalRate() {
        return parseFpsResponse(request("GETGLOBAL"));
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
}
