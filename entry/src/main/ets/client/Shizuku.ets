/*
 * Shizuku Client SDK for HarmonyOS.
 *
 * This client provides a Shizuku-compatible developer interface for HarmonyOS
 * NEXT applications to request permissions and run commands at uid 2000 (shell).
 */
import rpc from '@ohos.rpc';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import bundleManager from '@ohos.bundle.bundleManager';

export interface ShizukuExecResult {
  ok: boolean;
  output: string;
  error: string;
  exitCode: number;
}

export interface ShizukuRemoteProcess {
  waitFor(): Promise<ShizukuExecResult>;
  destroy(): void;
}

class ShizukuRemoteProcessImpl implements ShizukuRemoteProcess {
  private cmdStr: string;
  private callerBundle?: string;
  private promise: Promise<ShizukuExecResult> | null = null;

  constructor(cmdStr: string, callerBundle?: string) {
    this.cmdStr = cmdStr;
    this.callerBundle = callerBundle;
  }

  waitFor(): Promise<ShizukuExecResult> {
    if (!this.promise) {
      this.promise = Shizuku.execWithResult(this.cmdStr, this.callerBundle);
    }
    return this.promise;
  }

  destroy(): void {
    // Synchronous execution over RPC session
  }
}

class ShizukuDeathRecipient implements rpc.DeathRecipient {
  onRemoteDied(): void {
    Shizuku.onDied();
  }
}

class ShizukuConnectOptions implements common.ConnectOptions {
  private resolveCallback: (value: boolean) => void;

  constructor(resolveCallback: (value: boolean) => void) {
    this.resolveCallback = resolveCallback;
  }

  onConnect(elementName: bundleManager.ElementName, remote: rpc.IRemoteObject): void {
    Shizuku.onConnected(remote);
    this.resolveCallback(true);
  }

  onDisconnect(elementName: bundleManager.ElementName): void {
    Shizuku.onDisconnected();
  }

  onFailed(code: number): void {
    this.resolveCallback(false);
  }
}

export enum ShizukuMethodId {
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

export class Shizuku {
  public static readonly DEFAULT_BUNDLE_NAME: string = 'com.shuwei.shellbridge';
  public static readonly DEFAULT_ABILITY_NAME: string = 'ShellBridgeService';

  private static remote: rpc.IRemoteObject | undefined = undefined;
  private static connectId: number = -1;
  private static context: common.Context | undefined = undefined;
  private static targetBundleName: string = Shizuku.DEFAULT_BUNDLE_NAME;

  private static binderReceivedListeners: Array<() => void> = [];
  private static binderDeadListeners: Array<() => void> = [];
  private static deathRecipient: rpc.DeathRecipient | undefined = undefined;

  /**
   * Initializes and binds to the on-device Shizuku / ShellBridge service.
   */
  static async bind(context: common.Context, targetBundle?: string): Promise<boolean> {
    Shizuku.context = context;
    if (targetBundle && targetBundle.length > 0) {
      Shizuku.targetBundleName = targetBundle;
    }

    if (Shizuku.remote !== undefined) {
      return true;
    }

    return new Promise<boolean>((resolve) => {
      const want: Want = {
        bundleName: Shizuku.targetBundleName,
        abilityName: Shizuku.DEFAULT_ABILITY_NAME
      };

      const connection: common.ConnectOptions = new ShizukuConnectOptions(resolve);

      try {
        const id = (context as common.UIAbilityContext).connectServiceExtensionAbility(want, connection);
        Shizuku.connectId = id;
      } catch (err) {
        resolve(false);
      }
    });
  }

  static onConnected(remote: rpc.IRemoteObject): void {
    Shizuku.remote = remote;
    Shizuku.setupDeathRecipient(remote);
    for (const listener of Shizuku.binderReceivedListeners) {
      try {
        listener();
      } catch (_) {}
    }
  }

  static onDisconnected(): void {
    Shizuku.remote = undefined;
    for (const listener of Shizuku.binderDeadListeners) {
      try {
        listener();
      } catch (_) {}
    }
  }

  static onDied(): void {
    Shizuku.remote = undefined;
    for (const listener of Shizuku.binderDeadListeners) {
      try {
        listener();
      } catch (_) {}
    }
  }

  /**
   * Sets a directly acquired remote object (e.g. for intra-process or custom bridge binding).
   */
  static setRemote(remote: rpc.IRemoteObject | undefined): void {
    Shizuku.remote = remote;
    if (remote) {
      Shizuku.setupDeathRecipient(remote);
      for (const listener of Shizuku.binderReceivedListeners) {
        try {
          listener();
        } catch (_) {}
      }
    }
  }

  private static setupDeathRecipient(remote: rpc.IRemoteObject): void {
    if (Shizuku.deathRecipient) {
      try {
        remote.unregisterDeathRecipient(Shizuku.deathRecipient, 0);
      } catch (_) {}
    }
    const recipient: rpc.DeathRecipient = new ShizukuDeathRecipient();
    Shizuku.deathRecipient = recipient;
    try {
      remote.registerDeathRecipient(Shizuku.deathRecipient, 0);
    } catch (_) {}
  }

  /**
   * Checks whether the remote service is alive and responsive.
   */
  static async pingBinder(): Promise<boolean> {
    if (Shizuku.remote === undefined) {
      return false;
    }
    try {
      const reply = await Shizuku.callRpc(ShizukuMethodId.PING_BINDER, []);
      return reply === 'true' || reply === '1';
    } catch (_) {
      return false;
    }
  }

  /**
   * Gets the service version.
   */
  static async getVersion(): Promise<number> {
    const raw = await Shizuku.callRpc(ShizukuMethodId.GET_VERSION, []);
    return Number.parseInt(raw, 10) || 1;
  }

  /**
   * Gets the execution UID (2000 for shell).
   */
  static async getUid(): Promise<number> {
    const raw = await Shizuku.callRpc(ShizukuMethodId.GET_UID, []);
    return Number.parseInt(raw, 10) || 2000;
  }

  /**
   * Gets the execution SELinux context.
   */
  static async getSelinuxContext(): Promise<string> {
    return await Shizuku.callRpc(ShizukuMethodId.GET_SELINUX_CONTEXT, []);
  }

  /**
   * Checks if this client has permission to execute commands.
   */
  static async checkSelfPermission(callerBundle?: string): Promise<boolean> {
    const bundle = callerBundle ?? (Shizuku.context ? Shizuku.context.applicationInfo.name : '');
    const raw = await Shizuku.callRpc(ShizukuMethodId.CHECK_SELF_PERMISSION, [bundle]);
    return raw === 'true';
  }

  /**
   * Requests permission to use the shell channel.
   */
  static async requestPermission(requestCode: number = 0, callerBundle?: string): Promise<boolean> {
    const bundle = callerBundle ?? (Shizuku.context ? Shizuku.context.applicationInfo.name : '');
    const raw = await Shizuku.callRpc(ShizukuMethodId.REQUEST_PERMISSION, [`${requestCode}`, bundle]);
    return raw === 'true';
  }

  /**
   * Executes a shell command and returns stdout directly.
   */
  static async exec(command: string, callerBundle?: string): Promise<string> {
    const bundle = callerBundle ?? (Shizuku.context ? Shizuku.context.applicationInfo.name : '');
    return await Shizuku.callRpc(ShizukuMethodId.EXEC, [command, bundle]);
  }

  /**
   * Executes a shell command and returns detailed result including exitCode.
   */
  static async execWithResult(command: string, callerBundle?: string): Promise<ShizukuExecResult> {
    const bundle = callerBundle ?? (Shizuku.context ? Shizuku.context.applicationInfo.name : '');
    const raw = await Shizuku.callRpc(ShizukuMethodId.EXEC_WITH_RESULT, [command, bundle]);
    try {
      return JSON.parse(raw) as ShizukuExecResult;
    } catch (_) {
      const fallbackResult: ShizukuExecResult = {
        ok: false,
        output: raw,
        error: 'Failed to parse JSON response',
        exitCode: -1
      };
      return fallbackResult;
    }
  }

  /**
   * Runs a command as a process handle with waitFor support.
   */
  static newProcess(command: string | string[], callerBundle?: string): ShizukuRemoteProcess {
    const cmdStr = Array.isArray(command) ? command.join(' ') : command;
    return new ShizukuRemoteProcessImpl(cmdStr, callerBundle);
  }

  /**
   * Disconnects from the bridge service.
   */
  static unbind(): void {
    if (Shizuku.context && Shizuku.connectId >= 0) {
      try {
        (Shizuku.context as common.UIAbilityContext).disconnectServiceExtensionAbility(Shizuku.connectId);
      } catch (_) {}
      Shizuku.connectId = -1;
    }
    Shizuku.remote = undefined;
  }

  static addBinderReceivedListener(listener: () => void): void {
    Shizuku.binderReceivedListeners.push(listener);
    if (Shizuku.remote !== undefined) {
      try {
        listener();
      } catch (_) {}
    }
  }

  static removeBinderReceivedListener(listener: () => void): void {
    const idx = Shizuku.binderReceivedListeners.indexOf(listener);
    if (idx !== -1) {
      Shizuku.binderReceivedListeners.splice(idx, 1);
    }
  }

  static addBinderDeadListener(listener: () => void): void {
    Shizuku.binderDeadListeners.push(listener);
  }

  static removeBinderDeadListener(listener: () => void): void {
    const idx = Shizuku.binderDeadListeners.indexOf(listener);
    if (idx !== -1) {
      Shizuku.binderDeadListeners.splice(idx, 1);
    }
  }

  private static async callRpc(code: number, args: string[]): Promise<string> {
    if (Shizuku.remote === undefined) {
      throw new Error('Shizuku is not connected. Call Shizuku.bind() first.');
    }

    const data = rpc.MessageSequence.create();
    const reply = rpc.MessageSequence.create();
    const option = new rpc.MessageOption();

    for (const arg of args) {
      data.writeString(arg);
    }

    const result = await Shizuku.remote.sendMessageRequest(code, data, reply, option);
    if (result.errCode !== 0) {
      throw new Error(`RPC request failed with code: ${result.errCode}`);
    }

    return reply.readString() ?? '';
  }
}
