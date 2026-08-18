// build_package.mjs - assemble and sign a paid display package staging dir.
//
// Usage:
//   node build_package.mjs --payload <payload-dir> --out <staging-dir> \
//     --version <x.y.z> --version-code <int> --feature-code <code> \
//     --min-base <x.y.z> --models RMX5200 --socs SM8750 --kernels 6.12 \
//     --backends drm,dtbo --channel stable --key-seed <hex seed>
//
// The staging dir receives manifest.json, manifest.sig and payload/.
// Zip the staging dir contents afterwards (WSL: zip -r out.zip .).
import { createHash, createPrivateKey, sign } from 'node:crypto';
import { copyFileSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

function arg(key, fallback) {
  const index = process.argv.indexOf(key);
  return index >= 0 && index + 1 < process.argv.length ? process.argv[index + 1] : fallback;
}

const payloadDir = arg('--payload');
const outDir = arg('--out');
const version = arg('--version', '1.0.0');
const versionCode = parseInt(arg('--version-code', '1'), 10);
const featureCode = arg('--feature-code', 'display_premium');
const minBase = arg('--min-base', '2.8');
const models = (arg('--models', 'RMX5200') || '').split(',').map((s) => s.trim()).filter(Boolean);
const socs = (arg('--socs', 'SM8750') || '').split(',').map((s) => s.trim()).filter(Boolean);
const kernels = (arg('--kernels', '6.12') || '').split(',').map((s) => s.trim()).filter(Boolean);
const backends = (arg('--backends', 'drm') || '').split(',').map((s) => s.trim()).filter(Boolean);
const channel = arg('--channel', 'stable');
const keySeedHex = arg('--key-seed');
const keyId = arg('--key-id', process.env.DISPLAY_PACKAGE_KEY_ID || 'display-package-2026-08-prod');

if (!payloadDir || !outDir || !keySeedHex) {
  console.error('missing required arguments');
  process.exit(2);
}

const PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const privateKey = createPrivateKey({
  key: Buffer.concat([PREFIX, Buffer.from(keySeedHex, 'hex')]),
  format: 'der',
  type: 'pkcs8',
});

function walk(dir, prefix) {
  const entries = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      entries.push(...walk(full, prefix + name + '/'));
    } else {
      entries.push({ path: prefix + name, full, size: stat.size });
    }
  }
  return entries;
}

const files = walk(payloadDir, '').map((entry) => {
  const normalized = entry.path.split(sep).join('/');
  const data = readFileSync(entry.full);
  const mode = normalized.startsWith('bin/') || normalized.startsWith('scripts/') ? '0755' : '0644';
  return {
    path: 'payload/' + normalized,
    sha256: createHash('sha256').update(data).digest('hex'),
    size: entry.size,
    mode,
    target_path: normalized,
  };
});

const manifest = {
  schema_version: 1,
  version,
  version_code: versionCode,
  channel,
  feature_code: featureCode,
  min_base_version: minBase,
  supported_models: models,
  supported_socs: socs,
  supported_kernels: kernels,
  supported_backends: backends,
  signature_key_id: keyId,
  files,
};

function prettyManifest(m) {
  const lines = [];
  lines.push('{');
  lines.push('  "schema_version": ' + m.schema_version + ',');
  lines.push('  "version": "' + m.version + '",');
  lines.push('  "version_code": ' + m.version_code + ',');
  lines.push('  "channel": "' + m.channel + '",');
  lines.push('  "feature_code": "' + m.feature_code + '",');
  lines.push('  "min_base_version": "' + m.min_base_version + '",');
  lines.push('  "supported_models": ' + JSON.stringify(m.supported_models) + ',');
  lines.push('  "supported_socs": ' + JSON.stringify(m.supported_socs) + ',');
  lines.push('  "supported_kernels": ' + JSON.stringify(m.supported_kernels) + ',');
  lines.push('  "supported_backends": ' + JSON.stringify(m.supported_backends) + ',');
  lines.push('  "signature_key_id": "' + m.signature_key_id + '",');
  lines.push('  "files": [');
  m.files.forEach((file, index) => {
    const comma = index === m.files.length - 1 ? '' : ',';
    lines.push('    { "path": "' + file.path + '", "sha256": "' + file.sha256 + '", "size": ' + file.size +
      ', "mode": "' + file.mode + '", "target_path": "' + file.target_path + '" }' + comma);
  });
  lines.push('  ]');
  lines.push('}');
  return lines.join('\n') + '\n';
}

const manifestText = prettyManifest(manifest);
const manifestBytes = Buffer.from(manifestText, 'utf8');
const signature = sign(null, manifestBytes, privateKey);

mkdirSync(join(outDir, 'payload'), { recursive: true });
writeFileSync(join(outDir, 'manifest.json'), manifestBytes);
writeFileSync(join(outDir, 'manifest.sig'), Buffer.from(signature).toString('base64url') + '\n');
for (const entry of files) {
  const source = join(payloadDir, entry.target_path.split('/').join(sep));
  const target = join(outDir, entry.path.split('/').join(sep));
  mkdirSync(join(target, '..'), { recursive: true });
  copyFileSync(source, target);
}

console.log('staging written to', outDir);
console.log('version', version, 'version_code', versionCode, 'files', files.length);
void relative;
