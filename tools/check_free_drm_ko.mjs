import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = process.cwd();
const expected = {
  rmx5200_drm_modes: "6.12.23-android16-5-gb2a876903b49-ab14541642-4k",
  plk110_drm_modes: "6.12.23-android16-5-gb2a876903b49-ab14541642-4k",
  pjd110_drm_modes: "6.1.141-gd86625c3830b",
};

const expectedImports = {
  rmx5200_drm_modes: ["__fortify_panic", "__kmalloc_large_noprof", "__kmalloc_noprof", "__list_add_valid_or_report", "__list_del_entry_valid_or_report", "__stack_chk_fail", "_printk", "bcmp", "copy_from_kernel_nofault", "drm_kms_helper_connector_hotplug_event", "drm_kms_helper_hotplug_event", "drm_mode_destroy", "drm_mode_duplicate", "drm_mode_probed_add", "drm_mode_vrefresh", "get_main_display", "kfree", "kmemdup_noprof", "kmemdup_nul", "ksize", "kstrtouint", "kstrtoull", "mem_alloc_profiling_key", "memcpy", "memset", "mutex_lock", "mutex_unlock", "of_find_node_by_name", "of_find_property", "of_get_property", "param_ops_bool", "param_ops_string", "param_ops_uint", "param_ops_ullong", "scnprintf", "strchr", "strcmp", "strncmp", "strnlen", "strsep"],
  plk110_drm_modes: ["__fortify_panic", "__kmalloc_large_noprof", "__kmalloc_noprof", "__list_add_valid_or_report", "__list_del_entry_valid_or_report", "__stack_chk_fail", "_printk", "copy_from_kernel_nofault", "drm_kms_helper_connector_hotplug_event", "drm_kms_helper_hotplug_event", "drm_mode_destroy", "drm_mode_duplicate", "drm_mode_probed_add", "drm_mode_vrefresh", "get_main_display", "kfree", "kmemdup_noprof", "kmemdup_nul", "ksize", "kstrtouint", "kstrtoull", "mem_alloc_profiling_key", "memcpy", "memset", "mutex_lock", "mutex_unlock", "of_find_node_by_name", "of_get_property", "param_ops_bool", "param_ops_string", "param_ops_uint", "param_ops_ullong", "scnprintf", "strchr", "strncmp", "strnlen", "strsep"],
  pjd110_drm_modes: ["__kmalloc", "__list_add_valid", "__list_del_entry_valid", "__stack_chk_fail", "_printk", "copy_from_kernel_nofault", "drm_kms_helper_connector_hotplug_event", "drm_kms_helper_hotplug_event", "drm_mode_destroy", "drm_mode_duplicate", "drm_mode_probed_add", "drm_mode_vrefresh", "fortify_panic", "get_main_display", "kfree", "kmalloc_large", "kmemdup", "kmemdup_nul", "ksize", "kstrtouint", "kstrtoull", "memcpy", "memset", "mutex_lock", "mutex_unlock", "of_find_node_by_name", "of_get_property", "param_ops_bool", "param_ops_string", "param_ops_uint", "param_ops_ullong", "scnprintf", "strchr", "strncmp", "strnlen", "strsep"],
};

function sections(bytes) {
  if (bytes.length < 0x40 || bytes.toString("ascii", 0, 4) !== "\u007fELF" || bytes[4] !== 2 || bytes[5] !== 1) {
    throw new Error("KO is not an ELF64 little-endian object");
  }
  const offset = Number(bytes.readBigUInt64LE(0x28));
  const size = bytes.readUInt16LE(0x3a);
  const count = bytes.readUInt16LE(0x3c);
  const stringIndex = bytes.readUInt16LE(0x3e);
  if (size < 0x40 || count === 0 || stringIndex >= count || offset + size * count > bytes.length) throw new Error("invalid ELF sections");
  const header = index => offset + index * size;
  const data = index => {
    const start = Number(bytes.readBigUInt64LE(header(index) + 0x18));
    const length = Number(bytes.readBigUInt64LE(header(index) + 0x20));
    if (start + length > bytes.length) throw new Error("ELF section exceeds file");
    return bytes.subarray(start, start + length);
  };
  const names = data(stringIndex);
  const cstring = (buffer, start) => {
    const end = buffer.indexOf(0, start);
    if (start < 0 || end < start) throw new Error("invalid ELF string");
    return buffer.toString("utf8", start, end);
  };
  const result = new Map();
  for (let index = 0; index < count; index += 1) result.set(cstring(names, bytes.readUInt32LE(header(index))), {
    bytes: data(index),
    link: bytes.readUInt32LE(header(index) + 0x28),
  });
  return result;
}

function undefinedSymbols(map) {
  const symbol = map.get(".symtab");
  if (!symbol) throw new Error("KO is missing ELF symbol table");
  const stringSection = [...map.values()][symbol.link];
  const entrySize = 24;
  const names = [];
  for (let offset = 0; offset + entrySize <= symbol.bytes.length; offset += entrySize) {
    const nameOffset = symbol.bytes.readUInt32LE(offset);
    const sectionIndex = symbol.bytes.readUInt16LE(offset + 6);
    if (nameOffset !== 0 && sectionIndex === 0) {
      const end = stringSection.bytes.indexOf(0, nameOffset);
      names.push(stringSection.bytes.toString("utf8", nameOffset, end));
    }
  }
  return [...new Set(names)].sort();
}

for (const [module, release] of Object.entries(expected)) {
  const file = path.join(root, "bin", `${module}.ko`);
  const map = sections(await readFile(file));
  const modinfo = map.get(".modinfo")?.bytes.toString("utf8").split("\0") ?? [];
  const vermagic = modinfo.find(value => value.startsWith("vermagic="))?.slice("vermagic=".length);
  const wanted = `${release} SMP preempt mod_unload modversions aarch64`;
  if (vermagic !== wanted) throw new Error(`${module}: vermagic mismatch: ${vermagic ?? "missing"}`);
  if (!map.has("__versions") && !map.has("__version_ext_names")) throw new Error(`${module}: missing module version sections`);
  const actualImports = undefinedSymbols(map);
  if (actualImports.join("\n") !== [...expectedImports[module]].sort().join("\n")) throw new Error(`${module}: unresolved symbol set mismatch\nactual=${actualImports.join(",")}\nexpected=${[...expectedImports[module]].sort().join(",")}`);
  process.stdout.write(`verified ${module}: ${vermagic}\n`);
}
