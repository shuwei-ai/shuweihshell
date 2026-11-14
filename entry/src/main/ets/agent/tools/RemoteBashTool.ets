/*
 * Remote SSH Execution Tool (`remote_bash`).
 * Executes Linux/macOS shell commands on the user's configured remote server over native SSH-2.0,
 * offloading Python, Node/npm, compilation, git, or heavy workloads from the constrained phone shell.
 */
import { SshExecNativeRequest, SshExecNativeResult, sshExecNative } from '../../common/NativeBridge';
import { AgentConfigStore } from '../AgentConfigStore';
import { RemoteServerConfig, ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';

export type RemoteSshRunner = (req: SshExecNativeRequest) => Promise<SshExecNativeResult>;

export class RemoteBashTool {
  private static customRunner: RemoteSshRunner | null = null;

  static setCustomRunner(runner: RemoteSshRunner | null): void {
    RemoteBashTool.customRunner = runner;
  }

  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'command': new ToolProperty(
        'string',
        'The shell command to execute on the configured remote SSH server (supports python3, node, npm, git, compilers, etc.).'
      ),
      'work_dir': new ToolProperty(
        'string',
        'Optional working directory on the remote server (overrides default configured workDir).'
      ),
      'timeout_seconds': new ToolProperty(
        'number',
        'Optional SSH connect + command execution timeout in seconds (3-300, default: 30).'
      )
    };
    const params = new ToolParameters(props, ['command']);
    const func = new ToolFunctionDefinition(
      'remote_bash',
      'Execute commands on the configured remote SSH server (Linux/macOS host) over SSH-2.0. Use when tasks require Python, Node.js/npm, build toolchains, git repos, or desktop utilities unavailable on the HarmonyOS phone shell.',
      params
    );
    return new ToolDefinition(func);
  }

  static clampTimeoutSeconds(raw?: number): number {
    if (typeof raw !== 'number' || Number.isNaN(raw) || !Number.isFinite(raw)) {
      return 30;
    }
    const rounded = Math.round(raw);
    if (rounded < 3) {
      return 3;
    }
    if (rounded > 300) {
      return 300;
    }
    return rounded;
  }

  static wrapCommandWithWorkDir(command: string, workDir: string): string {
    const trimmedDir = (workDir ?? '').trim();
    if (trimmedDir.length === 0) {
      return command;
    }
    const safeDir = trimmedDir.replace(/'/g, "'\\''");
    return `cd '${safeDir}' && (${command})`;
  }

  static formatRemoteResult(host: string, port: number, res: SshExecNativeResult): string {
    const parts: string[] = [];
    const out = (res.output ?? '').trimEnd();
    const errOut = (res.stderrOutput ?? '').trimEnd();
    if (out.length > 0) {
      parts.push(out);
    }
    if (errOut.length > 0) {
      parts.push(`[stderr]\n${errOut}`);
    }
    const meta = `[SSH ${host}:${port} | Exit: ${res.exitCode}${res.hostFingerprint ? ' | ' + res.hostFingerprint : ''}]`;
    parts.push(meta);
    return parts.join('\n\n');
  }

  static async testConnection(cfg: RemoteServerConfig): Promise<SshExecNativeResult> {
    const runner: RemoteSshRunner = RemoteBashTool.customRunner ?? sshExecNative;
    const req: SshExecNativeRequest = {
      host: cfg.host.trim(),
      port: cfg.port > 0 && cfg.port <= 65535 ? cfg.port : 22,
      username: cfg.username.trim(),
      password: cfg.password,
      privateKeyPem: cfg.privateKeyPem,
      command: 'uname -a && pwd && id',
      expectedFingerprint: cfg.expectedFingerprint.trim(),
      timeoutSeconds: 12
    };
    return await runner(req);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const command = typeof args['command'] === 'string' ? (args['command'] as string) : '';
    if (command.trim().length === 0) {
      return {
        toolCallId: toolCallId,
        toolName: 'remote_bash',
        output: '',
        error: 'Parameter "command" cannot be empty.',
        isError: true
      };
    }

    const cfg = AgentConfigStore.getInstance().getRemoteConfig();
    if (!cfg.enabled) {
      return {
        toolCallId: toolCallId,
        toolName: 'remote_bash',
        output: '',
        error: 'Remote SSH execution is disabled. Ask the user to enable and configure "远程 SSH 服务器" in ⚙️ 模型设置 (Host, Port, Username, Password/PEM Key).',
        isError: true
      };
    }
    if (!cfg.host || cfg.host.trim().length === 0 || !cfg.username || cfg.username.trim().length === 0) {
      return {
        toolCallId: toolCallId,
        toolName: 'remote_bash',
        output: '',
        error: 'Remote SSH host or username is missing. Please configure them in ⚙️ 模型设置 -> 远程 SSH 服务器.',
        isError: true
      };
    }
    if ((!cfg.password || cfg.password.length === 0) && (!cfg.privateKeyPem || cfg.privateKeyPem.trim().length === 0)) {
      return {
        toolCallId: toolCallId,
        toolName: 'remote_bash',
        output: '',
        error: 'Remote SSH credentials are empty. Provide either an SSH password or PEM private key in ⚙️ 模型设置 -> 远程 SSH 服务器.',
        isError: true
      };
    }

    const argWorkDir = typeof args['work_dir'] === 'string' ? (args['work_dir'] as string).trim() : '';
    const effectiveWorkDir = argWorkDir.length > 0 ? argWorkDir : cfg.defaultWorkDir;
    const finalCommand = RemoteBashTool.wrapCommandWithWorkDir(command, effectiveWorkDir);
    const timeoutSeconds = RemoteBashTool.clampTimeoutSeconds(args['timeout_seconds'] as number | undefined);
    const effectivePort = cfg.port > 0 && cfg.port <= 65535 ? cfg.port : 22;

    try {
      const runner: RemoteSshRunner = RemoteBashTool.customRunner ?? sshExecNative;
      const sshRes = await runner({
        host: cfg.host.trim(),
        port: effectivePort,
        username: cfg.username.trim(),
        password: cfg.password,
        privateKeyPem: cfg.privateKeyPem,
        command: finalCommand,
        expectedFingerprint: cfg.expectedFingerprint.trim(),
        timeoutSeconds: timeoutSeconds
      });

      const formatted = RemoteBashTool.formatRemoteResult(cfg.host.trim(), effectivePort, sshRes);
      if (sshRes.ok) {
        return {
          toolCallId: toolCallId,
          toolName: 'remote_bash',
          output: formatted,
          isError: false
        };
      }
      return {
        toolCallId: toolCallId,
        toolName: 'remote_bash',
        output: formatted,
        error: sshRes.error.length > 0 ? sshRes.error : `Remote command failed with exit code ${sshRes.exitCode}`,
        isError: true
      };
    } catch (err) {
      return {
        toolCallId: toolCallId,
        toolName: 'remote_bash',
        output: '',
        error: `SSH execution error: ${err}`,
        isError: true
      };
    }
  }
}
