/*
 * The ArkTS view of the native library.
 *
 * The native module is libswshell.so (entry/src/main/cpp).  It speaks the HDC
 * wire protocol to the device's own hdcd daemon; everything above it in the
 * app is ordinary ArkTS.
 */
import swshell from 'libswshell.so';

export interface ShellExecResult {
  ok: boolean;
  output: string;
  error: string;
  exitCode: number;
}

export interface ShellConnectResult {
  ok: boolean;
  error: string;
}

export interface ShellDiscoveryResult {
  /** The port the device's hdc daemon is listening on, or 0. */
  port: number;
  error: string;
}

export interface JsEvalNativeResult {
  ok: boolean;
  result: string;
  logs: string;
  error: string;
  elapsedMs: number;
}

export interface PyEvalNativeResult {
  ok: boolean;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  elapsedMs: number;
}

export interface SshExecNativeRequest {
  host: string;
  port: number;
  username: string;
  password: string;
  privateKeyPem: string;
  command: string;
  expectedFingerprint: string;
  timeoutSeconds: number;
}

export interface SshExecNativeResult {
  ok: boolean;
  exitCode: number;
  output: string;
  stderrOutput: string;
  error: string;
  hostFingerprint: string;
}

/**
 * Points the native layer at the directory it keeps its client keypair in.
 * The keypair has to be stable: the device remembers our public key and only
 * skips its permit dialog when the same key comes back.
 */
export function initNative(keyDir: string): boolean {
  return swshell.init(keyDir);
}

/**
 * Connects to the device's hdcd daemon over the loopback interface and
 * completes the handshake.  The device shows its own permit dialog at this
 * point; the user has to allow it.
 */
export async function connectNative(host: string, port: number): Promise<ShellConnectResult> {
  const result = await swshell.connect(host, port) as ShellConnectResult;
  return result;
}

/**
 * The ports the device is listening on.  The hdc daemon gets a random port
 * when wireless debugging is switched on, and an app cannot read it, so the
 * bridge finds it by trying them.
 */
export function listPortsNative(): number[] {
  return swshell.listPorts() as number[];
}

export function disconnectNative(): boolean {
  return swshell.disconnect();
}

export function isConnectedNative(): boolean {
  return swshell.isConnected();
}

export type ChunkCallback = (chunk: string) => void;

/**
 * Runs one command on the device with streaming output callback.
 * If onData is passed, chunks are received in real time as they arrive.
 * If timeoutSeconds is 0, the command runs indefinitely until it exits
 * or abortNative() is called.
 */
export async function execStreamNative(
  command: string,
  bundleName: string = '',
  onData?: ChunkCallback,
  timeoutSeconds: number = 0
): Promise<ShellExecResult> {
  const result = await swshell.execStream(command, bundleName, onData, timeoutSeconds) as ShellExecResult;
  return result;
}

/**
 * Interrupts the currently executing command on the daemon.
 */
export function abortNative(): boolean {
  return swshell.abort() as boolean;
}

/**
 * Runs one command on the device and waits for it to finish.  The command
 * runs as uid 2000 (shell), which is what the device's hdc daemon runs shell
 * commands as.  If timeoutSeconds is > 0, aborts the channel after timeout.
 */
export async function execNative(
  command: string,
  bundleName: string = '',
  timeoutSeconds: number = 30
): Promise<ShellExecResult> {
  const result = await swshell.exec(command, bundleName, timeoutSeconds) as ShellExecResult;
  return result;
}

/**
 * The synchronous variant of exec.  The AIDL service needs it because
 * rpc.RemoteObject.onRemoteRequest may not await; the native session
 * already blocks until the command finishes, so this simply waits for it.
 */
export function execSyncNative(command: string, bundleName: string = ''): ShellExecResult {
  const result = swshell.execSync(command, bundleName) as ShellExecResult;
  return result;
}

/**
 * Asks the device's hdc daemon which port it is listening on.  This is the
 * on-device equivalent of `hdc target discover`: the daemon answers the
 * same broadcast and reports its TCP port.
 */
export async function discoverNative(): Promise<ShellDiscoveryResult> {
  return await swshell.discover() as ShellDiscoveryResult;
}

/** The client public key the device remembers, for diagnostics. */
export function publicKeyNative(): string {
  return swshell.publicKey();
}

/**
 * Evaluates a JavaScript snippet in an isolated HarmonyOS JSVM sandbox.
 */
export async function runJsNative(
  code: string,
  inputJson: string = '',
  timeoutMs: number = 5000
): Promise<JsEvalNativeResult> {
  const result = await swshell.runJs(code, inputJson, timeoutMs) as JsEvalNativeResult;
  return result;
}

/**
 * Evaluates a Python 3 snippet in an isolated native MicroPython sandbox.
 */
export async function runPythonNative(
  code: string,
  inputJson: string = '',
  timeoutMs: number = 5000,
  heapLimitBytes: number = 4 * 1024 * 1024
): Promise<PyEvalNativeResult> {
  const result = await swshell.runPython(code, inputJson, timeoutMs, heapLimitBytes) as PyEvalNativeResult;
  return result;
}

/**
 * Executes a shell command on a remote SSH-2.0 host natively over TCP + CryptoKit.
 */
export async function sshExecNative(req: SshExecNativeRequest): Promise<SshExecNativeResult> {
  const result = await swshell.sshExec(req) as SshExecNativeResult;
  return result;
}
