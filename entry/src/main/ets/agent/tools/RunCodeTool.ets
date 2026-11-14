/*
 * Built-in Unified Offline Code Execution Tool (`run_code`).
 * Executes Python 3 (backed by native MicroPython Embed) and JavaScript (backed by HarmonyOS JSVM V8)
 * in isolated native sandboxes. Enables the Agent to parse complex JSON, perform mathematical computations,
 * execute regex extractions, and transform data offline without relying on phone shell packages.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { JsEvalNativeResult, PyEvalNativeResult, runJsNative, runPythonNative } from '../../common/NativeBridge';
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { AgentWorkspace } from './AgentWorkspace';

export type PySandboxRunner = (
  code: string,
  inputJson: string,
  timeoutMs: number,
  heapLimitBytes?: number
) => Promise<PyEvalNativeResult>;

export type JsSandboxRunner = (
  code: string,
  inputJson: string,
  timeoutMs: number
) => Promise<JsEvalNativeResult>;

export class RunCodeTool {
  private static customPyRunner: PySandboxRunner | null = null;
  private static customJsRunner: JsSandboxRunner | null = null;

  static setCustomPyRunner(runner: PySandboxRunner | null): void {
    RunCodeTool.customPyRunner = runner;
  }

  static setCustomJsRunner(runner: JsSandboxRunner | null): void {
    RunCodeTool.customJsRunner = runner;
  }

  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'path': new ToolProperty(
        'string',
        'Optional relative or sandbox path of the script file to execute (e.g. "solution.py", "scripts/test.js"). Either `code` or `path` must be provided.'
      ),
      'code': new ToolProperty(
        'string',
        'Optional source code string to execute directly. Either `code` or `path` must be provided. For Python: To execute system commands with uid 2000 shell privileges, use `import hdc; res = hdc.shell("cmd")` (returns HdcResult with .ok, .exit_code, .output, .error) or standard `import subprocess; subprocess.run("cmd", shell=True)`. Use `print(...)` to output results; `__input__` holds parsed `input_json`. For JavaScript: use `console.log(...)` or return value.'
      ),
      'language': new ToolProperty(
        'string',
        'Programming language to execute: "python" (default) or "javascript". Auto-detected from file extension if path is specified.'
      ),
      'input_json': new ToolProperty(
        'string',
        'Optional raw JSON string automatically parsed and bound into runtime context (`__input__` in Python, `input` in JavaScript).'
      ),
      'timeout_ms': new ToolProperty(
        'number',
        'Optional execution time budget in milliseconds (100-60000, default: 15000).'
      )
    };
    const params = new ToolParameters(props);
    const func = new ToolFunctionDefinition(
      'run_code',
      'Execute Python 3 or JavaScript offline in an isolated native sandbox. Fully supports executing privileged HarmonyOS HDC shell commands (uid 2000, e.g. snapshot_display, uitest, uinput, aa, bm, hidumper, hilog) via `import hdc; res = hdc.shell("cmd")` or standard `import subprocess; subprocess.run("cmd", shell=True)`. Also supports data manipulation, regex parsing, graphics with PIL, and dynamic package installation via `import pip; pip.install("pkg")`.',
      params
    );
    return new ToolDefinition(func);
  }

  static clampTimeoutMs(raw?: number): number {
    if (typeof raw !== 'number' || Number.isNaN(raw) || !Number.isFinite(raw)) {
      return 15000;
    }
    const rounded = Math.round(raw);
    if (rounded < 100) {
      return 100;
    }
    if (rounded > 60000) {
      return 60000;
    }
    return rounded;
  }

  private static formatJsOutput(res: JsEvalNativeResult): string {
    const parts: string[] = [];
    const logs = (res.logs ?? '').trimEnd();
    const result = (res.result ?? '').trim();
    if (logs.length > 0) {
      parts.push(`[Console Output]\n${logs}`);
    }
    if (result.length > 0) {
      parts.push(`[Return Value]\n${result}`);
    }
    if (parts.length === 0) {
      parts.push('(Script completed with no console output and undefined return value)');
    }
    parts.push(`[Elapsed: ${res.elapsedMs}ms]`);
    return parts.join('\n\n');
  }

  private static formatPyOutput(res: PyEvalNativeResult): string {
    const parts: string[] = [];
    const stdout = (res.stdout ?? '').trimEnd();
    if (stdout.length > 0) {
      parts.push(stdout);
    } else {
      parts.push('(Script executed successfully with no stdout output. Use print() to emit results.)');
    }
    parts.push(`[Elapsed: ${res.elapsedMs}ms]`);
    return parts.join('\n\n');
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    let code = typeof args['code'] === 'string' ? (args['code'] as string) : '';
    const rawPath = typeof args['path'] === 'string' ? (args['path'] as string).trim() : '';

    if (code.trim().length === 0 && rawPath.length === 0) {
      return {
        toolCallId: toolCallId,
        toolName: 'run_code',
        output: '',
        error: 'Either "code" or "path" must be provided to run_code.',
        isError: true
      };
    }

    // Auto-detect language if not explicitly provided
    let rawLang = typeof args['language'] === 'string' ? (args['language'] as string).toLowerCase().trim() : '';
    if (!rawLang && rawPath.length > 0) {
      if (rawPath.endsWith('.py')) {
        rawLang = 'python';
      } else if (rawPath.endsWith('.js') || rawPath.endsWith('.ts')) {
        rawLang = 'javascript';
      }
    }
    if (!rawLang || rawLang === 'py') {
      rawLang = 'python';
    } else if (rawLang === 'js') {
      rawLang = 'javascript';
    }

    // If path is specified and code is omitted, load script content from sandbox workspace
    if (code.trim().length === 0 && rawPath.length > 0) {
      try {
        code = AgentWorkspace.getInstance().readFile(rawPath);
      } catch (readErr) {
        return {
          toolCallId: toolCallId,
          toolName: 'run_code',
          output: '',
          error: `Failed to load script file "${rawPath}" from workspace: ${readErr}`,
          isError: true
        };
      }
    }

    let inputJson = '';
    const rawInput = args['input_json'];
    if (typeof rawInput === 'string') {
      inputJson = rawInput;
    } else if (rawInput !== undefined && rawInput !== null) {
      try {
        inputJson = JSON.stringify(rawInput);
      } catch (_err) {
        return {
          toolCallId: toolCallId,
          toolName: 'run_code',
          output: '',
          error: 'Failed to serialize non-string input_json argument.',
          isError: true
        };
      }
    }

    const timeoutMs = RunCodeTool.clampTimeoutMs(args['timeout_ms'] as number | undefined);

    if (rawLang === 'python') {
      try {
        const runner: PySandboxRunner = RunCodeTool.customPyRunner ?? runPythonNative;
        const res = await runner(code, inputJson, timeoutMs);
        if (res.ok) {
          return {
            toolCallId: toolCallId,
            toolName: 'run_code',
            output: RunCodeTool.formatPyOutput(res),
            isError: false
          };
        }
        if (res.timedOut) {
          return {
            toolCallId: toolCallId,
            toolName: 'run_code',
            output: res.stdout.length > 0 ? `[Output Before Timeout]\n${res.stdout}` : '',
            error: `[Execution Timed Out] ${res.stderr || `Exceeded ${timeoutMs}ms budget`}`,
            isError: true
          };
        }
        return {
          toolCallId: toolCallId,
          toolName: 'run_code',
          output: res.stdout.length > 0 ? `[Stdout]\n${res.stdout}` : '',
          error: res.stderr.length > 0 ? `[Python Error]\n${res.stderr}` : 'Python script execution failed.',
          isError: true
        };
      } catch (err) {
        return {
          toolCallId: toolCallId,
          toolName: 'run_code',
          output: '',
          error: `run_code (python) error: ${err}`,
          isError: true
        };
      }
    } else if (rawLang === 'javascript') {
      try {
        const runner: JsSandboxRunner = RunCodeTool.customJsRunner ?? runJsNative;
        const evalRes = await runner(code, inputJson, timeoutMs);
        if (evalRes.ok) {
          return {
            toolCallId: toolCallId,
            toolName: 'run_code',
            output: RunCodeTool.formatJsOutput(evalRes),
            isError: false
          };
        }
        const logs = (evalRes.logs ?? '').trimEnd();
        return {
          toolCallId: toolCallId,
          toolName: 'run_code',
          output: logs.length > 0 ? `[Console Before Error]\n${logs}` : '',
          error: evalRes.error.length > 0 ? evalRes.error : 'JavaScript execution failed.',
          isError: true
        };
      } catch (err) {
        return {
          toolCallId: toolCallId,
          toolName: 'run_code',
          output: '',
          error: `run_code (javascript) error: ${err}`,
          isError: true
        };
      }
    } else {
      return {
        toolCallId: toolCallId,
        toolName: 'run_code',
        output: '',
        error: `Unsupported language: "${rawLang}". Supported: "python", "javascript".`,
        isError: true
      };
    }
  }
}
