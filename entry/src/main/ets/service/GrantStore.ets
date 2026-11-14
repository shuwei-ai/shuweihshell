/*
 * The list of apps the user has approved for the shell channel.
 *
 * The HarmonyOS permission itself is the real gate: the framework refuses to
 * bind the service to an app that does not hold it.  This store is the
 * bridge's own second layer, so the user can revoke one app from here
 * without touching system settings.
 *
 * The check has to be synchronous - rpc.RemoteObject.onRemoteRequest may not
 * await - so the list is kept in memory and mirrored to disk.
 */
import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

const STORE_NAME: string = 'swshell_grants';
const KEY_GRANTED: string = 'granted_apps';

export interface GrantEntry {
  bundleName: string;
  grantedAt: number;
}

export class GrantStore {
  private static instance: GrantStore = new GrantStore();
  private store: dataPreferences.Preferences | undefined = undefined;
  private cache: Map<string, GrantEntry> = new Map();
  private loaded: boolean = false;

  static getInstance(): GrantStore {
    return GrantStore.instance;
  }

  private async open(context: common.Context): Promise<dataPreferences.Preferences> {
    if (this.store === undefined) {
      this.store = await dataPreferences.getPreferences(context, { name: STORE_NAME });
    }
    return this.store;
  }

  /**
   * Loads the list from disk.  The service calls this once when it starts;
   * until it has run, the synchronous check finds nothing.
   */
  async load(context: common.Context): Promise<void> {
    const store = await this.open(context);
    const raw = await store.get(KEY_GRANTED, '[]') as string;
    this.cache.clear();
    try {
      const parsed = JSON.parse(raw) as GrantEntry[];
      for (const entry of parsed) {
        this.cache.set(entry.bundleName, entry);
      }
    } catch (error) {
      // A corrupt store is treated as "nothing granted".
    }
    this.loaded = true;
  }

  /** The apps that currently hold access, most recently granted first. */
  list(): GrantEntry[] {
    return Array.from(this.cache.values()).sort((a, b) => b.grantedAt - a.grantedAt);
  }

  /** The synchronous check the service uses. */
  isGranted(bundleName: string): boolean {
    return this.cache.has(bundleName);
  }

  async grant(context: common.Context, bundleName: string): Promise<void> {
    this.cache.set(bundleName, { bundleName: bundleName, grantedAt: Date.now() });
    await this.persist(context);
  }

  async revoke(context: common.Context, bundleName: string): Promise<void> {
    this.cache.delete(bundleName);
    await this.persist(context);
  }

  private async persist(context: common.Context): Promise<void> {
    const store = await this.open(context);
    await store.put(KEY_GRANTED, JSON.stringify(this.list()));
    await store.flush();
  }
}
