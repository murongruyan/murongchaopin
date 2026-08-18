# ADFR evidence and implementation boundary

## Inputs

- `C:\android-ndk-r27d-windows\diaodu\apk\借鉴源码\完整adfr 1+15修改版.txt`
  SHA256 `79C7F5A2CD0735D2258F2E0CCAFE416CBED5C78B196A116D31CF05F17C80506F`
- `C:\android-ndk-r27d-windows\diaodu\apk\借鉴源码\1+15原装dtbo.img`
  SHA256 `81DDFD8C10E7797F94C19B5A617BA0F84AC351FFF72B016722AEB6EF70A1E96A`

## What the supplied text contains

The text contains 36 properties: the six `min-fps` command and command-state
pairs for each of the normal, HPWM, and BIGDC ADFR command families. A bytewise
comparison against the OnePlus 15 stock `timing@sdc_fhd_60` node shows that it
is exactly that node's ADFR command set. It changes no `min-fps-5` command. The
six `min-fps-1/0` values are the stock 60Hz values, one step above the stock
120Hz values.

The text does not contain `oplus,adfr-config`, qsync properties, a test-TE GPIO,
`oplus,adfr-min-fps-mapping-table`, or the parent dynamic-float-TE properties.
It is therefore a timing-node fragment, not a complete ADFR configuration.

## PLK110 use

The DTBO processor now copies ADFR properties from the same-panel stock 60Hz
timing into newly generated 170/175/180/185/190/195/199Hz nodes. The copied
fragment includes the required mapping table `<60 40 30 20 10 1>`. This is a
static DTBO change only; PLK110 has no real-device validation in this workspace.

The PLK110 runtime KO still clones parsed mode records and private timing data,
but it does not claim to synthesize ADFR command arrays after the panel parser
has run. Its source and binary are rebuilt from the same source revision.

## RMX5200 boundary

The RMX5200 `msm_drm` binary contains `oplus_adfr_parse_dtsi_config`,
`oplus_adfr_is_supported`, `oplus_adfr_min_fps_update`, and the ADFR sysfs
attributes. The live `adfr_config` value is `0x0`, and the active AE084 panel
nodes have no ADFR, qsync, or dynamic-float-TE properties. The alternate AC180
node has ADFR enabled, but its commands use the AC180 DDIC register page
`FF 5A A5 2D`; AE084 uses a different `F0 55 AA 52` command family and only
has fixed-rate switch commands around register `0x68`.

Consequently, the OnePlus/AD296 commands must not be sent to RMX5200. A real
RMX5200 1Hz mode requires AE084-specific DDIC command sequences (and evidence
that the panel hardware supports that scan rate). Adding only
`oplus,adfr-config` would make the parser report support while leaving the
command tables empty, which is not a valid 1Hz implementation.

## RMX5200 parser dry-run

The module now has an explicit, default-off RMX5200 DTBO validation mode. The
WebUI stores `off` or `dry-run` in `config/rmx5200_adfr_mode.txt`; only the
RMX5200 DTBO backend dispatches `process_dts --rmx5200-adfr-dry-run`. Switching
to DRM-KO leaves the preference visible but inactive and does not pass the
experimental flag to `process_dts`.

The processor locates the real AE084 DVT02 panel node by requiring both its
panel-name property and its display-timings child. This avoids a same-named
node under `__local_fixups__`. It then writes `oplus,adfr-config = <0x101>` and
adds an ADFR minimum-FPS mapping plus `qcom,mdss-dsi-h-sync-skew = <0>` to each
AE084 timing, including generated overclock timings. Bit 0 lets the OPLUS ADFR
parser take the path; bit 8 is the vendor driver's dry-run guard around panel
command transmission. No `adfr-min-fps-*-command` property is generated.
Each mapping has six entries to match the vendor `min-fps-0..5` layout: the
60Hz timing uses `<60 40 30 20 10 1>`, while higher timings use
`<timing-rate 60 30 20 10 1>`. This mirrors the shape of the stock AC180 and
AD296 mappings without copying either panel's DDIC commands.

This mode is deliberately a parser test, not a display feature. A successful
boot with `adfr_config=0x101` and a usable `min_fps` sysfs path proves that the
DTS parser and mode mappings were accepted. It does not prove a 1Hz scan rate,
because dry-run suppresses the DSI commands that would change the DDIC.

The stock RMX5200 DTBO was also exercised offline in
`/data/local/tmp/mcp_adfr_sixlevel2_20260809` without flashing. Both DTBO
entries matched the real AE084 node, received 16 six-level timing mappings
(including the generated 123Hz node), compiled with `dtc`, and round-tripped
back to DTS with `0x101` intact. The generated DTB hashes were:

- entry 0: `501657d574c9f3c94c447b8bd50d662099ea9f3fe158e0f977ec0d24342dac0d`
- entry 1: `e558374852a9945f96c179f225902d45576c054fc2acd68f0f69e0c5ef4d98d4`

The active DTBO partition remained byte-for-byte stock with SHA256
`0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e`,
and the running `adfr_config` remained `0x0` because nothing was flashed.

## Verification status

- Qualcomm ADFR symbols and live sysfs presence: verified read-only on RMX5200.
- OnePlus 15 DTBO ADFR comparison and generated-node source: verified locally.
  A test-only PLK110 build transformed the stock `0x611f` DTS on an RMX5200
  temporary directory. All seven generated nodes contained exactly the same
  37 ADFR properties as the stock 60Hz node, and `dtc` compiled the transformed
  DTS successfully. The output DTB SHA256 was
  `cc4d562b701cbc4410e73b75e3619d0a534923fc94731ec46503659dff8fdcac`.
- PLK110 KO compilation and static fail-closed checks: verified.
- RMX5200 stock-DTBO dry-run transformation, `dtc` rebuild, and DTS round-trip:
  verified offline on the connected RMX5200; no partition write was performed.
- RMX5200 ADFR parser behavior after booting `0x101`: not yet verified.
- RMX5200 physical 1Hz and PLK110 real-device ADFR behavior: not verified.
- No DTBO partition or live display command was written during this analysis.

## 2026-08-09 follow-up evidence

The updated shared profile was exercised on the connected RMX5200 without
writing a partition. The device decomposed both DTBO entries, generated 16
AE084 timing mappings per entry, and packed `new_dtbo.img`. The AE084 node
still had no newly generated `adfr-min-fps-*command` property; the `FF 5A A5
2D` command properties visible elsewhere belong to another panel node and were
not copied.

The official-AVB merge step refused the modified payload, as required. The
device reports `ro.boot.verifiedbootstate=green`,
`ro.boot.vbmeta.device_state=locked`, and `ro.boot.veritymode=enforcing`.
Reusing the stock VBMeta cannot authenticate a changed DTBO payload without
the vendor signing key, so no `flash_final` step was run and the active DTBO
hash remained `0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e`.

The new `0.12-rmx5200-ae084-profile-gate` DRM-KO was then side-loaded with a
one-time risk token. It appended the 8 runtime modes and reported
`adfr_profile_valid=Y`, `adfr_command_injection_supported=N`, and
`failure_code=0`; after switching back to DTBO and rebooting, the KO was not
loaded and the original 8 modes returned. This validates profile binding and
rollback, not physical 1Hz.

## 2026-08-09 exact AE084 command-table audit

Both entries from the restored stock RMX5200 DTBO were decomposed again and
the real panel nodes were selected by their node names and `display-timings`
children, avoiding the shallow Iris references with identical names. The
following nodes all contain zero properties whose names include `adfr`:

- `qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd`
- `qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02`
- `qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt03`

This result is identical in both DTBO entries. The only complete ADFR family
in this image is under the separate
`qcom,mdss_dsi_panel_AC180_P_3_A0020_dsc_cmd` node. Its six normal, HPWM, and
BIGDC command sets use `FF 5A A5 2D`, so they are neither AE084 payloads nor
valid candidates for the target panel.

The live RMX5200 was also asked to dump parsed command slots through
`/sys/kernel/oplus_display/dsi_cmd`. The dump reports the fixed-rate
`fps-switch-*` slots but no `adfr-min-fps-*` slots, while reading `min_fps`
returns `adfr is not supported`. The procedure used only the debug selector
and `dump`; it did not invoke `send` and transmitted no DSI payload. Vendor
and persist filesystem inspection found only AE084 color/LTM and Iris assets,
not an independent ADFR command table.

Together, this closes the available local-evidence path: a physical 1Hz
implementation still requires a trace or signed firmware source that supplies
the AE084-specific command sets, plus an AVB-valid path for a DTBO parser
test. The checked-in profile and KO therefore remain fail-closed.

## 2026-08-09 user-backup DTBO audit correction

The file found in the device user's storage at
`/data/media/0/备份/模块/gt8pro/dtbo.img` was pulled as
`work/rmx5200-user-backup-audit-20260809/gt8pro_backup_dtbo.img`.
Its SHA-256 is
`DE8AF4F7018BD057BFAC8FC87FEF412A574473E2EAAA774C8BCEDFBA4F517CCA`
and its size is 25,165,824 bytes. This image is not an independent ADFR
command source. A fragment-boundary comparison against both restored stock
entries shows:

- only `fragment@202/__overlay__/qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02`
  changes;
- the change adds `wqhd_sdc_123` and 150--180 Hz timing nodes and their normal
  `qcom,mdss-dsi-on-command`/`qcom,mdss-dsi-timing-switch-command` data;
- the DVT02 fragment still has zero `adfr` properties, zero
  `qcom,mdss-dsi-adfr-min-fps-*command` properties, and no six-level mapping;
- its `F0 55 AA 52` bytes are ordinary initialization/timing-switch data, not
  proof of ADFR min-fps payloads. The complete ADFR table remains only under
  the separate AC180 fragment and uses `FF 5A A5 2D`.

This distinction is now covered by an offline audit test. It prevents a future
template importer from treating a high-refresh overclock backup as a verified
AE084 1 Hz command template. No DTBO was flashed and no panel command was
sent as part of this audit.

## 2026-08-09 real-device dry-run round trip

The current `_a` DTBO partition was read back from the RMX5200 and hashed as
`0de4f26051248e1589e6813798b0c22ad58e17333ae5f20b04b94e1a70f60d8e`.
Using the ARM64 tools on the device, both entries were unpacked, transformed
with `process_dts --rmx5200-adfr-dry-run`, compiled back with `dtc`, and packed
with `mkdtimg`. The resulting raw payload
`work/rmx5200-dryrun-20260809/new_dtbo.img` has SHA-256
`40a08096a8187014f77c6925869c7ce2f7b59c05efc825a688e6f4c8f03ea742`.
The round trip produced 16 mapping-only updates per entry and no AE084 DSI
command property.

Before any write, `dtbo_apply_stock_avb` was run with the official image as the
metadata source. The device reports `ro.boot.flash.locked=1`,
`vbmeta.device_state=locked`, `green`, and `enforcing`; the helper rejected the
modified payload with an AVB hash-descriptor failure and did not create a final
image or touch either DTBO partition. This is a verified parser-only artifact,
not a booted or physical 1 Hz result.
