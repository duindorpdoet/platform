import {createECDH,randomBytes,randomUUID} from 'node:crypto';

/** Storage/claim fixtures only. These synthetic tokens are never sent to a provider. */
export function syntheticPushMaterial(id=randomUUID()) {
  if(!/^[a-f0-9-]{36}$/.test(id))throw new Error('INVALID_SYNTHETIC_DEVICE_ID');
  const key=createECDH('prime256v1');key.generateKeys();
  return {endpoint:`https://fcm.googleapis.com/fcm/send/isolated-${id}`,
    p256dh:key.getPublicKey().toString('base64url'),auth:randomBytes(16).toString('base64url')};
}
