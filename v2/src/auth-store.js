import { BufferJSON, initAuthCreds, proto } from 'baileys';
import { authClear, authGet, authSet, authSetMany } from './db.js';
import { decryptString, encryptString } from './crypto.js';

const serialize = value => encryptString(JSON.stringify(value, BufferJSON.replacer));
const deserialize = value => JSON.parse(decryptString(value), BufferJSON.reviver);

export function createSqliteAuthState() {
  const stored = authGet('creds', 'primary');
  const creds = stored ? deserialize(stored) : initAuthCreds();

  const keys = {
    get: async (type, ids) => {
      const result = {};
      for (const id of ids) {
        const storedValue = authGet(`key:${type}`, id);
        if (!storedValue) continue;
        let value = deserialize(storedValue);
        if (type === 'app-state-sync-key' && value) {
          value = proto.Message.AppStateSyncKeyData.fromObject(value);
        }
        result[id] = value;
      }
      return result;
    },
    set: async data => {
      const records = [];
      for (const [type, values] of Object.entries(data)) {
        for (const [id, value] of Object.entries(values || {})) {
          records.push({ bucket: `key:${type}`, itemKey: id, value: value == null ? null : serialize(value) });
        }
      }
      if (records.length) authSetMany(records);
    }
  };

  return {
    state: { creds, keys },
    saveCreds: async update => {
      // Baileys emits a partial AuthenticationCreds update. A database-backed
      // adapter must merge that payload before persisting; serializing only the
      // original object can leave `registered`, `me` and device identity stale.
      if (update && typeof update === 'object') Object.assign(creds, update);
      authSet('creds', 'primary', serialize(creds));
      return creds;
    },
    clear: async () => authClear()
  };
}
