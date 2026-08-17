// gen_golden.mjs - generate deterministic Ed25519 golden vectors for
// verify_lease_sig. Deterministic: uses a fixed 32-byte seed (hex below),
// so vectors are stable across runs and platforms (Node/Go/WSL gcc/NDK).
//
// Usage: node gen_golden.mjs [output_dir]
//   default output_dir: ./golden
//
// Outputs:
//   golden/public.hex        - 32-byte Ed25519 public key, lowercase hex
//   golden/case-ok/payload.bin - signed payload (valid lease claims JSON)
//   golden/case-ok/signature.hex - hex signature over payload.bin
//   golden/case-tampered/payload.bin - one byte changed
//   golden/case-tampered/signature.hex - original signature (must FAIL)
//   golden/case-otherkey/... - signed by a different key (must FAIL)
import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const outDir = resolve(process.argv[2] || join(dirname(fileURLToPath(import.meta.url)), 'golden'));

const SEED_HEX = '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
const OTHER_SEED_HEX = '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb';

function deriveKeypair(seed) {
  // Build a PKCS#8 DER wrapper (RFC 8410) around the 32-byte seed, then
  // import it so the Node crypto engine expands the seed to the keypair.
  const prefix = Buffer.from('302e020100300506032b657004220420', 'hex');
  const pkcs8 = Buffer.concat([prefix, seed]);
  const privateKey = createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
  return { privateKey, publicKey: createPublicKey(privateKey) };
}

function rawPublicKey(publicKey) {
  return publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
}

function signRaw(privateKey, payload) {
  return sign(null, payload, privateKey);
}

function write(file, data) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, data);
}

const payload = Buffer.from(JSON.stringify({
  scope: 'display.premium',
  license_id: 7,
  binding_id: 11,
  user_id: 42,
  device_id_hash: 'a'.repeat(64),
  features: ['custom_ltpo', 'adfr_disable', 'video_memc'],
  issued_at: 1755200000,
  expires_at: 1755459200,
  grace_until: 1756064000,
  key_id: 'prod-2026-08',
  nonce: 'Qw8Tv4n2Xk9sLm5pRz3',
}), 'utf8');

const primary = deriveKeypair(Buffer.from(SEED_HEX, 'hex'));
const other = deriveKeypair(Buffer.from(OTHER_SEED_HEX, 'hex'));

const pubHex = rawPublicKey(primary.publicKey).toString('hex');
const sigHex = signRaw(primary.privateKey, payload).toString('hex');

write(join(outDir, 'public.hex'), pubHex + '\n');
write(join(outDir, 'case-ok', 'payload.bin'), payload);
write(join(outDir, 'case-ok', 'signature.hex'), sigHex + '\n');

const tampered = Buffer.from(payload);
tampered[tampered.length - 20] ^= 0x01;
write(join(outDir, 'case-tampered', 'payload.bin'), tampered);
write(join(outDir, 'case-tampered', 'signature.hex'), sigHex + '\n');

const otherSig = signRaw(other.privateKey, payload).toString('hex');
write(join(outDir, 'case-otherkey', 'payload.bin'), payload);
write(join(outDir, 'case-otherkey', 'signature.hex'), otherSig + '\n');

// Cross-check with Node's own verify before writing out.
if (!verify(null, payload, primary.publicKey, Buffer.from(sigHex, 'hex'))) {
  throw new Error('primary self-verification failed');
}
if (verify(null, payload, other.publicKey, Buffer.from(sigHex, 'hex'))) {
  throw new Error('wrong-key verification unexpectedly passed');
}

const hash = createHash('sha256');
console.log('golden vectors written to', outDir);
console.log('public.hex', pubHex);
console.log('payload sha256', createHash('sha256').update(payload).digest('hex'));
console.log('signature.hex', sigHex);
console.log('tampered sha256', createHash('sha256').update(tampered).digest('hex'));
void hash;
