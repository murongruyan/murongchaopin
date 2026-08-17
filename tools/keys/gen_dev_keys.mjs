// gen_dev_keys.mjs - generate the development Ed25519 keypairs used by the
// local authorization gate. PRODUCTION KEYS MUST COME FROM A SECRET STORE.
//
// Outputs (tools/keys/):
//   dev-lease-public.hex   - 32-byte lease verification public key (ships in module)
//   dev-lease-private.hex  - 32-byte seed -> backend DISPLAY_LEASE_PRIVATE_KEY (DO NOT SHIP)
//   dev-package-public.hex - manifest verification public key (ships in module)
//   dev-package-private.hex- 32-byte seed -> backend DISPLAY_PACKAGE_PUBLIC_KEY (DO NOT SHIP)
//   key-ids.txt            - key ids to embed in the module and backend
//   probe-payload.bin / probe-signature.hex - self-check vector
import { createPrivateKey, createPublicKey, randomBytes, sign } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const outDir = resolve(process.argv[2] || join(dirname(fileURLToPath(import.meta.url)), '..', 'keys'));
mkdirSync(outDir, { recursive: true });

const PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

function derive(seed) {
  const privateKey = createPrivateKey({ key: Buffer.concat([PREFIX, seed]), format: 'der', type: 'pkcs8' });
  const publicKey = createPublicKey(privateKey);
  const rawPublic = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  return { privateKey, rawPublic };
}

const leaseSeed = randomBytes(32);
const pkgSeed = randomBytes(32);
const leasePair = derive(leaseSeed);
const pkgPair = derive(pkgSeed);

writeFileSync(join(outDir, 'dev-lease-public.hex'), leasePair.rawPublic.toString('hex') + '\n');
writeFileSync(join(outDir, 'dev-lease-private.hex'), leaseSeed.toString('hex') + '\n');
writeFileSync(join(outDir, 'dev-package-public.hex'), pkgPair.rawPublic.toString('hex') + '\n');
writeFileSync(join(outDir, 'dev-package-private.hex'), pkgSeed.toString('hex') + '\n');
writeFileSync(join(outDir, 'key-ids.txt'), [
  'dev-lease-key-id=dev-lease-2026-08',
  'dev-package-key-id=dev-package-2026-08',
  'dev-lease-public-hex=' + leasePair.rawPublic.toString('hex'),
  'dev-package-public-hex=' + pkgPair.rawPublic.toString('hex'),
  '',
].join('\n'));

// sanity: sign + verify round-trip (verified by verify_lease_sig later)
const probe = Buffer.from('{"probe":1}');
const sig = sign(null, probe, leasePair.privateKey);
writeFileSync(join(outDir, 'probe-payload.bin'), probe);
writeFileSync(join(outDir, 'probe-signature.hex'), sig.toString('hex') + '\n');

console.log('dev keys written to', outDir);
console.log('lease public hex  :', leasePair.rawPublic.toString('hex'));
console.log('package public hex:', pkgPair.rawPublic.toString('hex'));
