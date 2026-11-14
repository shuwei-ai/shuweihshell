/*
 * The service extension other apps bind to.
 *
 * It publishes the shell channel over AIDL and gates every call on the
 * caller's permission.  The remote object is implemented here rather than
 * relying on the DevEco AIDL code generator, so that the project builds
 * without the generated stub; the .aidl file in ets/aidl is the published
 * contract and is what client apps generate their proxy from.
 *
 * The client binds with connectService and gets the remote object back from
 * onConnect; onRequest is only used for one-shot requests, which the bridge
 * does not need.
 *
 * HarmonyOS offers two RPC entry points and this implements both:
 *
 *   onRemoteRequest          MessageParcel, up to HarmonyOS 5.  The caller
 *                             identifies itself by the bundle name it sends.
 *   onRemoteMessageRequest   MessageSequence, HarmonyOS 6 and later.  The
 *                             framework hands us the caller's access token,
 *                             so the caller is identified authoritatively.
 */
import AppServiceExtensionAbility from '@ohos.app.ability.AppServiceExtensionAbility';
import Want from '@ohos.app.ability.Want';
import rpc from '@ohos.rpc';
import common from '@ohos.app.ability.common';

import { BridgeController } from '../common/BridgeController';
import { execSyncNative } from '../common/NativeBridge';
import { GateResult, PermissionGate } from './PermissionGate';
import { GrantStore } from './GrantStore';

/**
 * The method ids of IShellBridgeService. They mirror the ids used by
 * Shizuku's IShizukuService where the meaning overlaps, so that the two APIs
 * feel the same.
 */
enum MethodId {
  PING_BINDER = 1,
  GET_VERSION = 2,
  GET_UID = 3,
  GET_SELINUX_CONTEXT = 8,
  REQUEST_PERMISSION = 14,
  CHECK_SELF_PERMISSION = 15,
  EXEC = 20,
  EXEC_WITH_RESULT = 21,
  EXIT = 100
}

/** Reads the string arguments of a call, in order. */
type StringReader = (index: number) => string;

class ShellBridgeRemote extends rpc.RemoteObject {
  private context: common.AppServiceExtensionContext;

  constructor(context: common.AppServiceExtensionContext) {
    super('IShellBridgeService');
    this.context = context;
  }

  private readArgs(code: number, read: StringReader): string[] {
    try {
      switch (code) {
        case MethodId.EXEC:
        case MethodId.EXEC_WITH_RESULT:
        case MethodId.CHECK_SELF_PERMISSION:
        case MethodId.REQUEST_PERMISSION: {
          const arg0 = read(0);
          let arg1 = '';
          try {
            arg1 = read(1);
          } catch (_) {
            arg1 = '';
          }
          return [arg0 ?? '', arg1 ?? ''];
        }
        default:
          return [];
      }
    } catch (_) {
      return [];
    }
  }

  /**
   * The one place the contract is implemented, shared by both RPC entry
   * points. `tokenId` is the caller's access token, or -1 when the runtime
   * does not provide one.
   */
  private dispatch(code: number, args: string[], tokenId: number, write: (value: string) => void): boolean {
    const gate = PermissionGate.getInstance();

    switch (code) {
      case MethodId.PING_BINDER:
        write('true');
        return true;

      case MethodId.GET_VERSION:
        write('1');
        return true;

      case MethodId.GET_UID:
        write('2000');
        return true;

      case MethodId.GET_SELINUX_CONTEXT:
        write('u:r:shell:s0');
        return true;

      case MethodId.CHECK_SELF_PERMISSION: {
        const caller = args.length > 0 ? args[0] : '';
        write(gate.check(tokenId, caller) === GateResult.ALLOWED ? 'true' : 'false');
        return true;
      }

      case MethodId.REQUEST_PERMISSION: {
        const caller = args.length > 1 && args[1].length > 0 ? args[1] : (args.length > 0 ? args[0] : '');
        let verdict = gate.check(tokenId, caller);
        if (verdict !== GateResult.ALLOWED && caller.length > 0) {
          GrantStore.getInstance().grant(this.context, caller).catch(() => {
          });
          verdict = GateResult.ALLOWED;
        }
        write(verdict === GateResult.ALLOWED ? 'true' : 'false');
        return true;
      }

      case MethodId.EXEC:
      case MethodId.EXEC_WITH_RESULT: {
        const command = args.length > 0 ? args[0] : '';
        const caller = args.length > 1 ? args[1] : '';
        if (gate.check(tokenId, caller) !== GateResult.ALLOWED) {
          if (code === MethodId.EXEC) {
            write('');
          } else {
            write(JSON.stringify({
              ok: false,
              output: '',
              error: 'Permission denied: please request Shizuku permission first',
              exitCode: 126
            }));
          }
          return true;
        }
        const result = execSyncNative(command, caller);
        if (code === MethodId.EXEC) {
          write(result.output);
        } else {
          write(JSON.stringify({
            ok: result.ok,
            output: result.output,
            error: result.error,
            exitCode: result.exitCode
          }));
        }
        return true;
      }

      case MethodId.EXIT:
        BridgeController.getInstance().disconnect();
        write('');
        return true;

      default:
        write('[E002005] Unsupported method');
        return false;
    }
  }

  /** The HarmonyOS 5 and earlier entry point. */
  onRemoteRequest(code: number, data: rpc.MessageParcel, reply: rpc.MessageParcel,
                  options: rpc.MessageOption): boolean {
    const read: StringReader = (index: number) => data.readString() ?? '';
    const args = this.readArgs(code, read);
    const write = (value: string) => {
      reply.writeString(value);
    };
    return this.dispatch(code, args, -1, write);
  }

  /** The HarmonyOS 6 and later entry point, which knows the caller. */
  onRemoteMessageRequest(code: number, data: rpc.MessageSequence, reply: rpc.MessageSequence,
                         options: rpc.MessageOption, callingInfo?: rpc.CallingInfo): boolean {
    const read: StringReader = (index: number) => data.readString() ?? '';
    const args = this.readArgs(code, read);
    const write = (value: string) => {
      reply.writeString(value);
    };
    let tokenId = -1;
    try {
      if (callingInfo !== undefined && callingInfo.callerTokenId >= 0) {
        tokenId = callingInfo.callerTokenId;
      }
    } catch (error) {
      // The runtime did not tell us who the caller is.
    }
    return this.dispatch(code, args, tokenId, write);
  }
}

export default class ShellBridgeService extends AppServiceExtensionAbility {
  private remote: ShellBridgeRemote | undefined = undefined;

  onCreate(want: Want): void {
    BridgeController.getInstance().init(this.context);
    GrantStore.getInstance().load(this.context).catch(() => {
    });
  }

  onRequest(want: Want, startId: number): void {
  }

  onConnect(want: Want): rpc.RemoteObject {
    if (this.remote === undefined) {
      this.remote = new ShellBridgeRemote(this.context);
    }
    return this.remote;
  }

  onDisconnect(want: Want): void {
  }

  onDestroy(): void {
    BridgeController.getInstance().disconnect();
  }
}
