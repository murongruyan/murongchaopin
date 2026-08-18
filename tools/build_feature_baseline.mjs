import { createHash } from "node:crypto";
import { readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

function parseArgs(argv) {
  const result = {
    root: process.cwd(),
    manifest: "packaging/feature-components.json",
    output: "",
    capturedAt: "",
    check: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--check") {
      result.check = true;
    } else if (["--root", "--manifest", "--output", "--captured-at"].includes(arg)) {
      const value = argv[index + 1];
      if (!value) throw new Error(`${arg} requires a value`);
      index += 1;
      const key = arg.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
      result[key] = value;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return result;
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function normalizedRelativePath(value) {
  const normalized = value.replaceAll("\\", "/");
  if (!normalized || normalized.startsWith("/") || normalized.includes("../")) {
    throw new Error(`unsafe component path: ${value}`);
  }
  return normalized;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.root);
  const manifestPath = path.resolve(root, args.manifest);
  const manifestBytes = await readFile(manifestPath);
  const manifest = JSON.parse(manifestBytes.toString("utf8"));
  if (manifest.schema_version !== 1 || !Array.isArray(manifest.categories)) {
    throw new Error("unsupported feature component manifest");
  }

  const seenCategories = new Set();
  const seenPaths = new Map();
  const categories = [];
  for (const category of manifest.categories) {
    if (!category.id || seenCategories.has(category.id)) {
      throw new Error(`duplicate or empty category: ${category.id || "<empty>"}`);
    }
    seenCategories.add(category.id);
    if (!Array.isArray(category.components) || category.components.length === 0) {
      throw new Error(`category has no components: ${category.id}`);
    }

    const components = [];
    for (const component of category.components) {
      const relativePath = normalizedRelativePath(component.path);
      if (seenPaths.has(relativePath)) {
        throw new Error(
          `component ${relativePath} belongs to both ${seenPaths.get(relativePath)} and ${category.id}`,
        );
      }
      seenPaths.set(relativePath, category.id);
      const absolutePath = path.resolve(root, relativePath);
      if (!absolutePath.startsWith(`${root}${path.sep}`)) {
        throw new Error(`component escapes repository root: ${relativePath}`);
      }
      const fileStat = await stat(absolutePath);
      if (!fileStat.isFile()) throw new Error(`component is not a file: ${relativePath}`);
      const bytes = await readFile(absolutePath);
      components.push({
        path: relativePath,
        size: fileStat.size,
        sha256: sha256(bytes),
        note: component.note || "",
      });
    }
    components.sort((left, right) => left.path.localeCompare(right.path, "en"));
    categories.push({
      id: category.id,
      public_package: Boolean(category.public_package),
      feature: category.feature || null,
      description: category.description || "",
      components,
    });
  }
  categories.sort((left, right) => left.id.localeCompare(right.id, "en"));

  const output = {
    schema_version: 1,
    captured_at: args.capturedAt || new Date().toISOString(),
    source_manifest: path.relative(root, manifestPath).replaceAll("\\", "/"),
    source_manifest_sha256: sha256(manifestBytes),
    component_count: seenPaths.size,
    categories,
  };
  const serialized = `${JSON.stringify(output, null, 2)}\n`;

  if (args.output) {
    const outputPath = path.resolve(root, args.output);
    await writeFile(outputPath, serialized, "utf8");
  }
  const counts = Object.fromEntries(categories.map((item) => [item.id, item.components.length]));
  process.stdout.write(
    `${args.check ? "validated" : "captured"} ${seenPaths.size} components ${JSON.stringify(counts)}\n`,
  );
}

main().catch((error) => {
  process.stderr.write(`feature baseline failed: ${error.message}\n`);
  process.exitCode = 1;
});
