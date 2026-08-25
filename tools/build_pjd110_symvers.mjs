import { readFile, writeFile } from "node:fs/promises";
import process from "node:process";

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || !value) throw new Error("usage: build_pjd110_symvers.mjs --contract <file> --output <file>");
    args[key.slice(2)] = value;
  }
  if (!args.contract || !args.output) throw new Error("--contract and --output are required");
  return args;
}

function normalizeCrc(value, symbol) {
  if (!/^0x[0-9a-f]{8}$/i.test(value || "")) throw new Error(`invalid CRC for ${symbol}: ${value}`);
  return value.toLowerCase();
}

const args = parseArgs(process.argv.slice(2));
const contract = JSON.parse(await readFile(args.contract, "utf8"));
if (contract.schema_version !== 1 || contract.model !== "PJD110" || !contract.modules) throw new Error("unsupported PJD110 ABI contract");
const symbols = new Map();
for (const definition of Object.values(contract.modules)) {
  for (const [symbol, value] of Object.entries(definition.versions || {})) {
    const crc = normalizeCrc(value, symbol);
    if (symbols.has(symbol) && symbols.get(symbol) !== crc) throw new Error(`conflicting CRC for ${symbol}`);
    symbols.set(symbol, crc);
  }
}
if (!symbols.has("module_layout")) throw new Error("PJD110 ABI contract has no module_layout CRC");
const output = [...symbols.entries()].sort(([left], [right]) => left.localeCompare(right, "en")).map(([symbol, crc]) => `${crc}\t${symbol}\tvmlinux\tEXPORT_SYMBOL\t`).join("\n");
await writeFile(args.output, `${output}\n`, "utf8");
process.stdout.write(`wrote ${symbols.size} PJD110 device ABI symbols to ${args.output}\n`);




