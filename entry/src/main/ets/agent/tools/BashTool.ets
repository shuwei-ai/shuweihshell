/*
 * Pi Bash Tool implementation for HarmonyOS.
 * Executes shell commands at uid 2000 (shell) via the native HDC bridge.
 */
import { BridgeController } from '../../common/BridgeController';
import { runPythonNative } from '../../common/NativeBridge';
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { SecurityGuardrail } from '../security/SecurityGuardrail';

export class BashTool {
  private static readonly DEFAULT_TIMEOUT_SECONDS = 30;
  private static readonly MAX_TIMEOUT_SECONDS = 300;

  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'command': new ToolProperty('string', 'The shell command to execute.'),
      'timeout_seconds': new ToolProperty(
        'number',
        'Optional timeout in seconds (1-300, default: 30). Increase for long operations or keep bounded commands (e.g. ping -c 4, hilog -x | tail -n 50).'
      )
    };
    const params = new ToolParameters(props, ['command']);
    const func = new ToolFunctionDefinition(
      'bash',
      'Execute a shell command on the HarmonyOS NEXT device with uid 2000 (shell). ' +
      'SUPPORTED CAPABILITIES: ' +
      '(1) aa: Ability lifecycle (aa start -a <ability> -b <bundle> [-u 100], aa force-stop <bundle>, aa stop-service); ' +
      '(2) bm: Package management (bm dump -a, bm dump -n <bundle>, bm install -p <hap> -r, bm uninstall, bm clean, bm get --udid); ' +
      '(3) uitest: UI layout & input (uitest dumpLayout -p /data/local/tmp/layout.json, uitest uiInput text \'<chinese>\', uitest uiInput click/swipe/keyEvent); ' +
      '(4) hidumper: System diagnostics (hidumper -s <service> -a, hidumper --mem <pid>, hidumper --cpu); ' +
      '(5) hilog: Logging (ALWAYS pass non-blocking -x: e.g. `hilog -x -P <pid> | tail -n 50`, `hilog -x -T <tag> | tail -n 50`); ' +
      '(6) param: System properties (param get <key>, param dump); ' +
      '(7) power-shell: Screen wakeup & power mode (power-shell wakeup); ' +
      '(8) toybox utilities: ps -ef, kill, ls, rm, mkdir -p, df (under /data/local/tmp/ or /proc). ' +
      'STRICT RESTRICTIONS: ' +
      'DO NOT use bash to write or create files (cat << EOF, echo > are strictly forbidden; use "write" tool instead). ' +
      'DO NOT run python, node, pip, npm (none exist in /system/bin; use "run_code" tool instead). ' +
      'DO NOT run curl or wget (use "fetch" tool instead). ' +
      'DO NOT access /data/storage/ (app sandbox is not mounted in host shell; use "read"/"write" tools).',
      params
    );
    return new ToolDefinition(func);
  }

  static clampTimeoutSeconds(rawTimeout?: number, rawTimeoutMs?: number): number {
    let seconds = BashTool.DEFAULT_TIMEOUT_SECONDS;
    if (typeof rawTimeout === 'number' && !Number.isNaN(rawTimeout) && Number.isFinite(rawTimeout)) {
      seconds = Math.round(rawTimeout);
    } else if (typeof rawTimeoutMs === 'number' && !Number.isNaN(rawTimeoutMs) && Number.isFinite(rawTimeoutMs)) {
      seconds = Math.max(1, Math.round(rawTimeoutMs / 1000));
    }
    if (seconds < 1) {
      return 1;
    }
    if (seconds > BashTool.MAX_TIMEOUT_SECONDS) {
      return BashTool.MAX_TIMEOUT_SECONDS;
    }
    return seconds;
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const command = (args['command'] as string) ?? '';
    if (!command || command.trim().length === 0) {
      return {
        toolCallId: toolCallId,
        toolName: 'bash',
        output: '',
        error: 'Command cannot be empty',
        isError: true
      };
    }

    // Intercept pip commands and route in-process to Python's pip package manager
    const trimmed = command.trim();
    if (trimmed.startsWith('pip ') || trimmed === 'pip' || trimmed.startsWith('pip3 ') || trimmed === 'pip3') {
      const parts = trimmed.split(/\s+/).slice(1);
      const pyCode = `import pip\npip.main(${JSON.stringify(parts)})\n`;
      try {
        const pyRes = await runPythonNative(pyCode, '', 60000);
        return {
          toolCallId: toolCallId,
          toolName: 'bash',
          output: pyRes.stdout.length > 0 ? pyRes.stdout : (pyRes.ok ? 'pip command executed successfully.' : ''),
          error: pyRes.stderr.length > 0 ? pyRes.stderr : (pyRes.ok ? undefined : 'pip command failed.'),
          isError: !pyRes.ok
        };
      } catch (err) {
        return {
          toolCallId: toolCallId,
          toolName: 'bash',
          output: '',
          error: `pip execution error: ${err}`,
          isError: true
        };
      }
    }

    const guardrailCheck = SecurityGuardrail.inspectCommand(command);
    if (guardrailCheck.isBlocked) {
      return {
        toolCallId: toolCallId,
        toolName: 'bash',
        output: '',
        error: `[SECURITY GUARDRAIL BLOCKED] ${guardrailCheck.reason}. This high-risk destructive action was blocked to protect device integrity. Please use a safer, bounded alternative.`,
        isError: true
      };
    }

    const timeoutSeconds = BashTool.clampTimeoutSeconds(
      args['timeout_seconds'] as number | undefined,
      args['timeout_ms'] as number | undefined
    );

    try {
      const result = await BridgeController.getInstance().exec(command, '', timeoutSeconds);
      if (result.ok) {
        return {
          toolCallId: toolCallId,
          toolName: 'bash',
          output: result.output,
          isError: false
        };
      } else {
        const isTimeout = result.exitCode === -124 || result.error.toLowerCase().includes('timed out');
        let errMsg = result.error.length > 0 ? result.error : `Exit code: ${result.exitCode}`;
        if (isTimeout) {
          errMsg += ' — Do NOT repeat an unbounded streaming command (e.g. use `hilog -x`, `ping -c 4`, or pass `timeout_seconds` up to 300 if genuinely long-running).';
        }
        return {
          toolCallId: toolCallId,
          toolName: 'bash',
          output: result.output,
          error: errMsg,
          isError: true
        };
      }
    } catch (err) {
      return {
        toolCallId: toolCallId,
        toolName: 'bash',
        output: '',
        error: `Execution error: ${err}`,
        isError: true
      };
    }
  }
}
