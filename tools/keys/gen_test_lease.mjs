// gen_test_lease.mjs - build SignedLease fixtures for the authorization gate.
//
// Usage:
//   node gen_test_lease.mjs <private-seed-hex> <device-id-hash> <case> <out-file.json> [key-id]
//   case: valid | grace | expired | tampered | wrong-device | noltpo
//
// The signed payload byte-for-byte matches what the Go backend would emit for
// the same claims (compact JSON). The whole lease JSON is written to the out
// file, and its base64url form is printed to stdout.
import { createPrivateKey, sign } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const [, , seedHex, deviceHash, testCase, outFile, keyIdArg] = process.argv;
if (!seedHex || !deviceHash || !testCase || !outFile) {
  console.error('usage: node gen_test_lease.mjs <seed-hex> <device-hash> <case> <out.json> [key-id]');
  process.exit(2);
}

const PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const privateKey = createPrivateKey({ key: Buffer.concat([PREFIX, Buffer.from(seedHex, 'hex')]), format: 'der', type: 'pkcs8' });

const now = Math.floor(Date.now() / 1000);
const KEY_ID = keyIdArg || process.env.DISPLAY_LEASE_KEY_ID || 'dev-lease-2026-08';

function claims(features, expiresAt, graceUntil, hash) {
  return {
    scope: 'display.premium',
    license_id: 7,
    binding_id: 11,
    user_id: 42,
    device_id_hash: hash,
    features,
    issued_at: now - 60,
    expires_at: expiresAt,
    grace_until: graceUntil,
    key_id: KEY_ID,
    nonce: 'Qw8Tv4n2Xk9sLm5pRz3',
  };
}

let c;
switch (testCase) {
  case 'valid':
    c = claims(['custom_ltpo', 'adfr_disable', 'video_memc'], now + 259200, now + 864000, deviceHash);
    break;
  case 'grace':
    c = claims(['custom_ltpo', 'adfr_disable', 'video_memc'], now - 86400, now + 864000, deviceHash);
    break;
  case 'expired':
    c = claims(['custom_ltpo', 'adfr_disable', 'video_memc'], now - 900000, now - 604800, deviceHash);
    break;
  case 'tampered':
    c = claims(['custom_ltpo', 'adfr_disable', 'video_memc'], now + 259200, now + 864000, deviceHash);
    break;
  case 'wrong-device':
    c = claims(['custom_ltpo', 'adfr_disable', 'video_memc'], now + 259200, now + 864000, 'f'.repeat(64));
    break;
  case 'noltpo':
    c = claims(['video_memc'], now + 259200, now + 864000, deviceHash);
    break;
  default:
    console.error('unknown case: ' + testCase);
    process.exit(2);
}

let payload = Buffer.from(JSON.stringify(c), 'utf8');
let signature = sign(null, payload, privateKey);
if (testCase === 'tampered') {
  signature = Buffer.from(signature);
  signature[5] ^= 0xff;
}

const lease = {
  algorithm: 'Ed25519',
  key_id: KEY_ID,
  claims: c,
  payload: payload.toString('base64url'),
  signature: Buffer.from(signature).toString('base64url'),
};

writeFileSync(outFile, JSON.stringify(lease) + '\n');
console.log(Buffer.from(JSON.stringify(lease), 'utf8').toString('base64url'));
