import { readFile, writeFile } from "node:fs/promises";
import process from "node:process";

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key.startsWith("--") || !value) {
      throw new Error("usage: build_rmx5200_symvers.mjs --contract <file> --output <file>");
    }
    args[key.slice(2)] = value;
    index += 1;
  }
  if (!args.contract || !args.output) {
    throw new Error("--contract and --output are required");
  }
  return args;
}

function normalizeCrc(value, symbol) {
  if (!/^0x[0-9a-f]{8}$/i.test(value || "")) {
    throw new Error(`invalid CRC for ${symbol}: ${value}`);
  }
  return value.toLowerCase();
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const contract = JSON.parse(await readFile(args.contract, "utf8"));
  if (contract.schema_version !== 1 || !contract.modules || !contract.kernel_release) {
    throw new Error("unsupported RMX5200 ABI contract");
  }

  const symbols = new Map();
  for (const [module, definition] of Object.entries(contract.modules)) {
    const versions = definition.versions || {};
    for (const [symbol, rawCrc] of Object.entries(versions)) {
      const crc = normalizeCrc(rawCrc, symbol);
      const previous = symbols.get(symbol);
      if (previous && previous !== crc) {
        throw new Error(`conflicting device CRC for ${symbol}: ${previous} vs ${crc} (${module})`);
      }
      symbols.set(symbol, crc);
    }
  }
  if (!symbols.has("module_layout")) {
    throw new Error("device ABI contract has no module_layout CRC");
  }

  const output = [...symbols.entries()]
    .sort(([left], [right]) => left.localeCompare(right, "en"))
    // Linux 6.12's modpost parser requires the namespace column even when
    // the target export is in the global namespace.
    .map(([symbol, crc]) => `${crc}\t${symbol}\tvmlinux\tEXPORT_SYMBOL\t`)
    .join("\n");
  await writeFile(args.output, `${output}\n`, "utf8");
  process.stdout.write(`wrote ${symbols.size} RMX5200 device ABI symbols to ${args.output}\n`);
}

main().catch((error) => {
  process.stderr.write(`RMX5200 ABI contract error: ${error.message}\n`);
  process.exitCode = 1;
});




