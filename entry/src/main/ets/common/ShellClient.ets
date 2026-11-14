/*
 * The client side of the bridge.
 *
 * An app that wants to run shell commands on HarmonyOS through PiHA
 * copies this file (or depends on it), asks for the USE_SHELL permission,
 * binds to the service and calls exec().
 *
 *   import { ShellBridgeClient } from './ShellClient';
 *
 *   const client = new ShellBridgeClient();
 *   await client.connect(this.context);
 *   const output = await client.exec('id');
 */
import { common, Want } from '@kit.AbilityKit';
import { rpc } from '@kit.IPCKit';

const DEFAULT_BRIDGE_BUNDLE: string = 'com.shuwei.shellbridge';
const DEFAULT_BRIDGE_MODULE: string = 'entry';
const BRIDGE_ABILITY: string = 'ShellBridgeService';

/** The method ids of IShellBridgeService. */
export enum ShellBridgeMethod {
  GET_VERSION = 2,
  GET_UID = 3,
  GET_SELINUX_CONTEXT = 8,
  CHECK_SELF_PERMISSION = 15,
  REQUEST_PERMISSION = 14,
  EXEC = 20,
  EXEC_WITH_RESULT = 21,
  EXIT = 100
}

export interface ShellExecResult {
  ok: boolean;
  output: string;
  error: string;
  exitCode: number;
}

export class ShellBridgeClient {
  private bundleName: string = DEFAULT_BRIDGE_BUNDLE;
  private moduleName: string = DEFAULT_BRIDGE_MODULE;
  private remote: rpc.RemoteObject | undefined = undefined;
  private connectionId: number = -1;
  private ownBundleName: string = '';

  constructor(bundleName: string = DEFAULT_BRIDGE_BUNDLE) {
    this.bundleName = bundleName;
  }

  /**
   * Binds to the bridge's service.  The call fails unless this app holds
   * com.shuwei.shellbridge.permission.USE_SHELL.
   */
  async connect(context: common.UIAbilityContext): Promise<void> {
    this.ownBundleName = context.abilityInfo.bundleName;

    const want: Want = {
      bundleName: this.bundleName,
      moduleName: this.moduleName,
      abilityName: BRIDGE_ABILITY
    };

    await new Promise<void>((resolve, reject) => {
      const options: rpc.ConnectOptions = {
        onConnect: (elementName: rpc.ElementName, remote: rpc.IRemoteObject): void => {
          this.remote = remote as rpc.RemoteObject;
          resolve();
        },
        onDisconnect: (): void => {
          this.remote = undefined;
        },
        onDie: (): void => {
          this.remote = undefined;
        }
      };
      try {
        this.connectionId = context.connectServiceExtensionAbility(want, options);
      } catch (error) {
        reject(error);
      }
    });
  }

  /** Releases the binding. */
  disconnect(context: common.UIAbilityContext): void {
    if (this.connectionId >= 0) {
      context.disconnectServiceExtensionAbility(this.connectionId).catch(() => {
      });
      this.connectionId = -1;
    }
    this.remote = undefined;
  }

  private async call(code: number, args: string[]): Promise<string> {
    const remote = this.remote;
    if (remote === undefined) {
      throw new Error('not connected to the shell bridge');
    }
    const data = rpc.MessageSequence.create();
    const reply = rpc.MessageSequence.create();
    for (const arg of args) {
      data.writeString(arg);
    }
    const result = await remote.sendMessageRequest(code, data, reply, new rpc.MessageOption());
    const value = result.readString();
    data.reclaim();
    reply.reclaim();
    return value;
  }

  /** Whether this app may use the bridge. */
  async checkSelfPermission(): Promise<boolean> {
    return await this.call(ShellBridgeMethod.CHECK_SELF_PERMISSION, [this.ownBundleName]) === 'true';
  }

  /** Asks the user to grant this app the use permission. */
  async requestPermission(): Promise<boolean> {
    return await this.call(ShellBridgeMethod.REQUEST_PERMISSION, ['0', this.ownBundleName]) === 'true';
  }

  /** The uid the commands run as - 2000 (shell). */
  async getUid(): Promise<number> {
    return Number.parseInt(await this.call(ShellBridgeMethod.GET_UID, []), 10);
  }

  /** Runs a command and returns its standard output. */
  async exec(command: string): Promise<string> {
    return await this.call(ShellBridgeMethod.EXEC, [command, this.ownBundleName]);
  }

  /** Runs a command and returns the full result. */
  async execWithResult(command: string): Promise<ShellExecResult> {
    const raw = await this.call(ShellBridgeMethod.EXEC_WITH_RESULT, [command, this.ownBundleName]);
    if (raw.length === 0) {
      return { ok: false, output: '', error: 'the bridge refused the command', exitCode: -1 };
    }
    return JSON.parse(raw) as ShellExecResult;
  }
}
