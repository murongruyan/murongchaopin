#!/bin/sh
set -eu

SOURCE=${1:-src/rate_daemon.c}

# A video SurfaceView fallback must remain package-neutral and must not regress
# into a Telegram-only allowlist.  Keep the checks source-level so the same
# guard is covered even when the device build is unavailable in CI.
grep -q 'dumpsys SurfaceFlinger --list' "$SOURCE"
grep -q 'SurfaceView\[%s/' "$SOURCE"
grep -q 'RMX5200_VIDEO_SURFACE_EXIT_GRACE_MS 1800' "$SOURCE"
grep -q 'RMX5200_VIDEO_SURFACE_MIN_REFRESH 60' "$SOURCE"
grep -q 'RMX5200 video SurfaceView detected' "$SOURCE"
grep -q 'RMX5200 video SurfaceView ended' "$SOURCE"
grep -q 'rmx5200_video_surface_probe(current_pkg)' "$SOURCE"
grep -q 'video_surface_active && !video_override_active' "$SOURCE"

if grep -Eq 'strcmp\(foreground_package, "(org\.telegram\.messenger|com\.ss\.android\.ugc\.aweme|tv\.danmaku\.bili)"\)' "$SOURCE"; then
    echo 'FAIL: video SurfaceView fallback regressed to an app-specific allowlist' >&2
    exit 1
fi

echo 'PASS: video SurfaceView fallback is package-neutral and keeps a 60Hz floor'
