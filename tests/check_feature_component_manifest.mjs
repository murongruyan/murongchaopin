import { readFile } from "node:fs/promises";

const manifest = JSON.parse(
  await readFile("packaging/feature-components.json", "utf8"),
);
const byId = new Map(manifest.categories.map((category) => [category.id, category]));

for (const required of [
  "free_core",
  "public_shell",
  "split_required",
  "paid_payload",
  "premium_ltpo",
  "premium_adfr",
  "premium_memc",
  "research_only",
]) {
  if (!byId.has(required)) throw new Error(`missing required category: ${required}`);
}

if (!byId.get("free_core").public_package || !byId.get("public_shell").public_package) {
  throw new Error("free_core and public_shell must remain public");
}
for (const id of [
  "split_required",
  "paid_payload",
  "premium_ltpo",
  "premium_adfr",
  "premium_memc",
  "research_only",
]) {
  if (byId.get(id).public_package) throw new Error(`${id} must not be public`);
}

const stopped = byId.get("research_only").components.map((item) => item.path);
if (!stopped.includes("src/settings_hook/java/com/murongchaopin/displayhook/BilibiliStoryHooks.java")) {
  throw new Error("the stopped Bilibili experiment must remain research-only");
}

// Post-split policy: distributable free outputs and the free Hook sources are
// free_core. Only rate_daemon remains a compile-time mixed source.
const freePaths = byId.get("free_core").components.map((item) => item.path);
const mixedPaths = byId.get("split_required").components.map((item) => item.path);
for (const path of [
  "bin/rate_daemon",
  "bin/display_settings_hook.apk",
  "scripts/coloros_config.sh",
  "scripts/web_handler.sh",
  "scripts/display_license_gate.sh",
  "scripts/surfaceflinger_ltps_vote_patch.sh",
  "bin/verify_lease_sig",
  "post-mount.sh",
  "late-load.sh",
]) {
  if (!freePaths.includes(path)) throw new Error(`free component missing from free_core: ${path}`);
  if (mixedPaths.includes(path)) throw new Error(`component must not stay in split_required: ${path}`);
}
for (const path of [
  "src/rate_daemon.c",
]) {
  if (!mixedPaths.includes(path)) throw new Error(`mixed source must remain in split_required: ${path}`);
}
for (const path of [
  "src/settings_hook/java/com/murongchaopin/displayhook/DisplaySettingsHook.java",
  "src/settings_hook/java/com/murongchaopin/displayhook/OplusServicesHooks.java",
  "src/surfaceflinger/rmx5200_stock_ltps_vote_filter.S",
  "src/settings_hook/java-free/com/murongchaopin/displayhook/PremiumGateBridge.java",
]) {
  if (!freePaths.includes(path)) throw new Error(`free Hook source missing from free_core: ${path}`);
  if (mixedPaths.includes(path)) throw new Error(`free Hook source must not remain split_required: ${path}`);
}

const paidPayloadPaths = byId.get("paid_payload").components.map((item) => item.path);
for (const path of [
  "packaging/paid-payload/bin/rate_daemon_premium",
  "packaging/paid-payload/hooks/display_premium_hook.apk",
  "packaging/paid-payload/scripts/premium_system_overlay.sh",
  "src/settings_hook/java-premium/com/murongchaopin/displayhook/PremiumDisplayHook.java",
  "src/settings_hook/java-premium/com/murongchaopin/displayhook/PremiumGateBridge.java",
  "src/settings_hook/java-premium/com/murongchaopin/displayhook/PremiumServiceHooks.java",
  "src/settings_hook/java-premium/com/murongchaopin/displayhook/GameAssistantHooks.java",
  "src/settings_hook/java-premium/com/murongchaopin/displayhook/SceneHooks.java",
  "src/settings_hook/java-premium/com/murongchaopin/displayhook/SettingsFrontPageHooks.java",
  "src/settings_hook/java-premium/com/murongchaopin/displayhook/SettingsHooks.java",
  "src/settings_hook/java-premium/com/murongchaopin/displayhook/SettingsResolutionHooks.java",
]) {
  if (!paidPayloadPaths.includes(path)) throw new Error(`premium Hook component missing: ${path}`);
}

process.stdout.write("feature component policy validated\n");
