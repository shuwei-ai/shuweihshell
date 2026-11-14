/*
 * The bridge's shared state: the device connection, and the commands that
 * run on it.
 *
 * The UI and the service extension both use this, so there is exactly one
 * native session in the process.
 */
import common from '@ohos.app.ability.common';

import {
  abortNative,
  connectNative,
  disconnectNative,
  discoverNative,
  execNative,
  execStreamNative,
  initNative,
  isConnectedNative,
  listPortsNative,
  publicKeyNative,
  ShellConnectResult,
  ShellDiscoveryResult,
  ShellExecResult
} from './NativeBridge';

export interface BridgeStatus {
  connected: boolean;
  host: string;
  port: number;
  lastError: string;
  publicKey: string;
}

export class BridgeController {
  private static instance: BridgeController = new BridgeController();
  private initialized: boolean = false;
  private host: string = '127.0.0.1';
  private port: number = 8710;
  private lastError: string = '';

  static getInstance(): BridgeController {
    return BridgeController.instance;
  }

  /**
   * Prepares the native layer.  The keypair lives in the app's own files
   * directory: the device remembers the public key, so a stable keypair is
   * what keeps the permit dialog from appearing on every connect.
   */
  init(context: common.Context): boolean {
    if (this.initialized) {
      return true;
    }
    const ok = initNative(context.filesDir);
    this.initialized = ok;
    if (!ok) {
      this.lastError = 'failed to initialise the native library';
    }
    return ok;
  }

  status(): BridgeStatus {
    return {
      connected: isConnectedNative(),
      host: this.host,
      port: this.port,
      lastError: this.lastError,
      publicKey: publicKeyNative()
    };
  }

  /**
   * Asks the device which port its hdc daemon is listening on.  The user
   * can still type the port instead - this only saves them the trouble.
   */
  async discover(): Promise<ShellDiscoveryResult> {
    return await discoverNative();
  }

  /** The TCP ports the device is listening on. */
  listPorts(): number[] {
    return listPortsNative();
  }

  /**
   * Connects to the device's hdc daemon.  The device shows its own permit
   * dialog during the handshake - the user has to allow it.
   */
  async connect(context: common.Context, host: string, port: number): Promise<ShellConnectResult> {
    if (!this.init(context)) {
      return { ok: false, error: this.lastError };
    }
    this.host = host;
    this.port = port;
    const result = await connectNative(host, port);
    if (!result.ok) {
      this.lastError = result.error;
    } else {
      this.lastError = '';
    }
    return result;
  }

  disconnect(): void {
    disconnectNative();
  }

  /**
   * Runs a command on the device with streaming output.
   * onData is called as chunks arrive in real time.
   */
  async execStream(
    command: string,
    onData?: (chunk: string) => void,
    bundleName: string = '',
    timeoutSeconds: number = 0
  ): Promise<ShellExecResult> {
    return execStreamNative(command, bundleName, onData, timeoutSeconds);
  }

  /**
   * Interrupts the currently executing command on the daemon.
   */
  abort(): boolean {
    return abortNative();
  }

  /**
   * Runs a command on the device.  The command executes as uid 2000 (shell).
   * Defaults to a 30s timeout to prevent infinite hangs on blocking tools.
   */
  async exec(
    command: string,
    bundleName: string = '',
    timeoutSeconds: number = 30
  ): Promise<ShellExecResult> {
    return execNative(command, bundleName, timeoutSeconds);
  }
}
