#!/system/bin/sh

# Shared mode manifest reader. This file is sourced by Web/boot helpers and
# deliberately uses only Android toybox-compatible POSIX utilities.

mode_manifest_value() {
    mm_key="$1"
    mm_file="${MODE_MANIFEST_FILE:-${MOD_DIR:-${MOD_PATH:-.}}/config/display_mode_manifest.txt}"
    [ -r "$mm_file" ] || return 1
    sed -n "s/^${mm_key}=//p" "$mm_file" 2>/dev/null | sed -n '1p'
}

mode_manifest_model_key() {
    case "$1" in
        RMX5200|rmx5200) printf '%s\n' rmx5200 ;;
        PLK110|plk110) printf '%s\n' plk110 ;;
        PJD110|pjd110) printf '%s\n' pjd110 ;;
        *) return 1 ;;
    esac
}

mode_manifest_rates() {
    mm_model=$(mode_manifest_model_key "$1") || return 1
    mm_backend="$2"
    case "$mm_backend" in
        dtbo|drm) ;;
        *) return 1 ;;
    esac
    mode_manifest_value "${mm_model}_${mm_backend}_rates"
}

mode_manifest_resolution() {
    mm_model=$(mode_manifest_model_key "$1") || return 1
    mm_width=$(mode_manifest_value "${mm_model}_width") || return 1
    mm_height=$(mode_manifest_value "${mm_model}_height") || return 1
    case "$mm_width:$mm_height" in
        *[!0-9:]*|:*) return 1 ;;
    esac
    printf '%sx%s\n' "$mm_width" "$mm_height"
}

mode_manifest_key_present() {
    mm_key="$1"
    mm_file="${MODE_MANIFEST_FILE:-${MOD_DIR:-${MOD_PATH:-.}}/config/display_mode_manifest.txt}"
    [ -r "$mm_file" ] || return 1
    grep -q "^${mm_key}=" "$mm_file" 2>/dev/null
}

mode_manifest_specs() {
    mm_model=$(mode_manifest_model_key "$1") || return 1
    mm_resolution=$(mode_manifest_resolution "$mm_model") || return 1
    mm_rates=$(mode_manifest_rates "$mm_model" "$2") || return 1
    [ -n "$mm_rates" ] || return 1
    printf '%s\n' "$mm_rates" | tr ',' '\n' | awk -v res="$mm_resolution" '
        BEGIN { first = 1 }
        /^[0-9]+$/ {
            if (!first) printf ";";
            printf "%s@%s", res, $0;
            first = 0;
        }
        END { if (!first) printf "\n" }
    '
}

mode_manifest_contains_rate() {
    mm_rate="$2"
    printf '%s\n' ",$(mode_manifest_rates "$1" "$3")," |
        grep -Fq ",${mm_rate},"
}

mode_manifest_validate() {
    [ "$(mode_manifest_value manifest_version)" = 1 ] || return 1
    # RMX5200 and PLK110 have predefined timing sets. PJD110 accepts WebUI
    # runtime specs, so its rate lists intentionally start empty.
    for mm_model in rmx5200 plk110; do
        mode_manifest_resolution "$mm_model" >/dev/null || return 1
        mm_dtbo_rates=$(mode_manifest_rates "$mm_model" dtbo) || return 1
        mm_drm_rates=$(mode_manifest_rates "$mm_model" drm) || return 1
        [ -n "$mm_dtbo_rates" ] && [ -n "$mm_drm_rates" ] || return 1
    done
    mode_manifest_resolution pjd110 >/dev/null || return 1
    mode_manifest_key_present pjd110_dtbo_rates || return 1
    mode_manifest_key_present pjd110_drm_rates || return 1
    [ -z "$(mode_manifest_value pjd110_dtbo_rates)" ] || return 1
    [ -z "$(mode_manifest_value pjd110_drm_rates)" ] || return 1
    [ "$(mode_manifest_value rmx5200_hmbird_dtbo)" = 1 ] || return 1
    [ "$(mode_manifest_value hmbird_ko_free)" = 0 ] || return 1
    [ "$(mode_manifest_value hmbird_ko_backends)" = dtbo ] || return 1
    [ "$(mode_manifest_value hmbird_ko_supported_socs)" = \
      SM8850,SM8850P,SM8845,SM8750,SM8750P,SM8650,SM8650P,MT6991,MT6993 ] || return 1
    [ "$(mode_manifest_value hmbird_ko_consumer_reinit)" = 0 ] || return 1
    [ "$(mode_manifest_value pjd110_hmbird_dtbo)" = 1 ] || return 1
    [ "$(mode_manifest_value pjd110_capacity_unlock_dtbo)" = 1 ] || return 1
}
