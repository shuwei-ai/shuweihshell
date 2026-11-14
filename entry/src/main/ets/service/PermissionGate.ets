/*
 * Who may use the shell channel.
 *
 * Two layers have to agree before a command runs:
 *
 *   1. the caller must hold com.shuwei.shellbridge.permission.USE_SHELL.
 *      That is the permission the user granted through the system dialog, and
 *      the framework enforces it when the app binds to the service;
 *   2. the caller's bundle must be in the bridge's own grant store, so the
 *      user can revoke one app from the bridge's own UI.
 *
 * The check has to be synchronous - rpc.RemoteObject.onRemoteRequest may not
 * await - so everything here is synchronous.  The caller is identified by its
 * access token where the runtime provides one (HarmonyOS 6 and later), and
 * by the bundle name it declares otherwise.
 */
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { Permissions } from '@kit.AbilityKit';

import { GrantStore } from './GrantStore';

export const PERMISSION_USE_SHELL: string = 'com.shuwei.shellbridge.permission.USE_SHELL';

export enum GateResult {
  /** The caller holds the permission and is in the grant store. */
  ALLOWED,
  /** The caller does not hold the HarmonyOS permission yet. */
  NEEDS_PERMISSION,
  /** The caller holds the permission but the user revoked it here. */
  REVOKED
}

export class PermissionGate {
  private static instance: PermissionGate = new PermissionGate();
  private atManager: abilityAccessCtrl.AtManager =
    abilityAccessCtrl.createAtManager();

  static getInstance(): PermissionGate {
    return PermissionGate.instance;
  }

  /**
   * Whether the given token holds the shell permission at the system level.
   */
  hasSystemPermission(tokenId: number): boolean {
    if (tokenId < 0) {
      return false;
    }
    try {
      const state = this.atManager.checkAccessTokenSync(
        tokenId, PERMISSION_USE_SHELL as Permissions);
      return state === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      return false;
    }
  }

  /**
   * The full check.
   *
   * `tokenId` is the caller's access token, or -1 when the runtime does not
   * provide one. `declaredBundle` is the bundle name the caller sent.
   */
  check(tokenId: number, declaredBundle: string): GateResult {
    const bundleName = declaredBundle ? declaredBundle.trim() : '';
    if (bundleName.length > 0 && GrantStore.getInstance().isGranted(bundleName)) {
      return GateResult.ALLOWED;
    }
    if (tokenId >= 0 && this.hasSystemPermission(tokenId)) {
      return GateResult.ALLOWED;
    }
    return GateResult.NEEDS_PERMISSION;
  }
}
