#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AUDIT_DIR=${RMX5200_AUDIT_DIR:-"$ROOT/work/rmx5200-user-backup-audit-20260809"}

extract_fragment() {
    audit_file=$1
    audit_fragment=$2
    audit_next=$3
    awk -v frag="$audit_fragment" -v next_frag="$audit_next" '
        $0 ~ "^[[:space:]]*fragment@" frag "[[:space:]]*\\{" {
            occurrence++
            if (occurrence == 2) active=1
        }
        active { print }
        active && $0 ~ "^[[:space:]]*fragment@" next_frag "[[:space:]]*\\{" { exit }
    ' "$audit_file"
}

assert_no_adfr() {
    audit_label=$1
    audit_text=$2
    if printf '%s\n' "$audit_text" | grep -Eiq 'adfr'; then
        echo "FAIL: $audit_label contains an ADFR property" >&2
        exit 1
    fi
}

assert_file() {
    [ -r "$1" ] || {
        echo "FAIL: missing audit DTS: $1" >&2
        exit 1
    }
}

for audit_file in \
    "$AUDIT_DIR/stock_o_dts/dtb_temp.0.dts" \
    "$AUDIT_DIR/stock_o_dts/dtb_temp.1.dts" \
    "$AUDIT_DIR/gt8_backup_dts/dtb_temp.0.dts" \
    "$AUDIT_DIR/gt8_backup_dts/dtb_temp.1.dts"; do
    assert_file "$audit_file"
    for audit_fragment in 198 202 206; do
        audit_next=$((audit_fragment + 2))
        audit_text=$(extract_fragment "$audit_file" "$audit_fragment" "$audit_next")
        [ -n "$audit_text" ] || {
            echo "FAIL: fragment@$audit_fragment was not found in $audit_file" >&2
            exit 1
        }
        assert_no_adfr "$audit_file fragment@$audit_fragment" "$audit_text"
    done
done

backup_dts="$AUDIT_DIR/gt8_backup_dts/dtb_temp.0.dts"
stock_dts="$AUDIT_DIR/stock_o_dts/dtb_temp.0.dts"
backup_dvt02=$(extract_fragment "$backup_dts" 202 204)
stock_dvt02=$(extract_fragment "$stock_dts" 202 204)

printf '%s\n' "$backup_dvt02" | grep -q 'timing@wqhd_sdc_123' || {
    echo "FAIL: backup DVT02 does not contain the expected 123Hz timing" >&2
    exit 1
}
printf '%s\n' "$backup_dvt02" | grep -q 'timing@wqhd_sdc_150' || {
    echo "FAIL: backup DVT02 does not contain the expected high-refresh timing" >&2
    exit 1
}
if printf '%s\n' "$stock_dvt02" | grep -q 'timing@wqhd_sdc_123'; then
    echo "FAIL: stock DVT02 unexpectedly contains the backup-only 123Hz timing" >&2
    exit 1
fi
printf '%s\n' "$backup_dvt02" | grep -Eiq 'f0[[:space:]]+55[[:space:]]+aa[[:space:]]+52' || {
    echo "FAIL: backup DVT02 did not retain its normal F0/55/AA/52 command family" >&2
    exit 1
}

ac180=$(extract_fragment "$backup_dts" 190 192)
printf '%s\n' "$ac180" | grep -q 'oplus,adfr-config = <0xe51>;' || {
    echo "FAIL: AC180 audit fixture lost its known ADFR config" >&2
    exit 1
}
adfr_command_count=$(printf '%s\n' "$ac180" |
    grep -Eic 'adfr-min-fps-[0-9]-command[[:space:]]*=' || true)
[ "$adfr_command_count" -eq 18 ] || {
    echo "FAIL: expected 18 AC180 normal/HPWM/BIGDC min-fps commands, got $adfr_command_count" >&2
    exit 1
}
printf '%s\n' "$ac180" |
    grep -Ei 'adfr-min-fps-[0-9]-command[[:space:]]*=' |
    grep -Eiq '5aa52d' || {
        echo "FAIL: AC180 ADFR command family is not FF/5A/A5/2D" >&2
        exit 1
    }
if printf '%s\n' "$ac180" |
    grep -Ei 'adfr-min-fps-[0-9]-command[[:space:]]*=' |
    grep -Eiq 'f0[[:space:]]+55[[:space:]]+aa[[:space:]]+52'; then
    echo "FAIL: AC180 ADFR command lines unexpectedly contain AE084 family" >&2
    exit 1
fi

echo "PASS: RMX5200 backup audit keeps AE084 high-refresh data separate from AC180 ADFR"
