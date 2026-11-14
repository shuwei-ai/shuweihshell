/*
 * Pi Write Tool implementation for HarmonyOS.
 * Dual-engine file writer:
 * 1. For relative paths and app sandbox paths, writes natively using @ohos.file.fs via AgentWorkspace
 *    (immune to shell line length limits, instant, persistent across reboots).
 * 2. For external system paths (/data/local/tmp, etc.), falls back to uid-2000 shell execution.
 */
import buffer from '@ohos.buffer';
import { BridgeController } from '../../common/BridgeController';
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { AgentWorkspace } from './AgentWorkspace';

export class WriteResult {
  ok: boolean = false;
  error: string = '';

  constructor(ok: boolean, error: string) {
    this.ok = ok;
    this.error = error;
  }
}

export class WriteTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'path': new ToolProperty(
        'string',
        'The path of the file to write. ' +
        '(1) Relative paths (e.g. "solution.py", "data/output.json") write to the persistent app sandbox workspace via @ohos.file.fs. ' +
        '(2) Public directory prefixes (e.g. "download://file.txt", "Download/file.txt", "docs://file.txt") write to system public directories via HarmonyOS system API (@ohos.file.environment), visible in system Files Manager. ' +
        '(3) Paths starting with /data/local/tmp fall back to shell.'
      ),
      'content': new ToolProperty('string', 'The exact content to write to the file.')
    };
    const params = new ToolParameters(props, ['path', 'content']);
    const func = new ToolFunctionDefinition(
      'write',
      'Create a new file or completely overwrite an existing file using native ArkTS system APIs (@ohos.file.fs and @ohos.file.environment). Supports app workspace files and system public directories (download://, docs://) visible in device Files Manager.',
      params
    );
    return new ToolDefinition(func);
  }

  static async writeContent(path: string, content: string): Promise<WriteResult> {
    if (!path || path.trim().length === 0) {
      return new WriteResult(false, 'Path cannot be empty');
    }

    const ws = AgentWorkspace.getInstance();
    if (ws.isPublicPath(path)) {
      await ws.ensurePermissionsSilently();
    }
    if (ws.isSandboxPath(path)) {
      try {
        ws.writeFile(path, content);
        return new WriteResult(true, '');
      } catch (err) {
        const errStr = `${err}`;
        if (errStr.includes('201') || errStr.toLowerCase().includes('permission')) {
          await ws.ensurePermissionsSilently();
          try {
            ws.writeFile(path, content);
            return new WriteResult(true, '');
          } catch (retryErr) {
            return new WriteResult(false, `Sandbox write error after permission retry: ${retryErr}`);
          }
        }
        return new WriteResult(false, `Sandbox write error: ${err}`);
      }
    }

    const safePath = path.replace(/'/g, "'\\''");
    const b64 = buffer.from(content, 'utf-8').toString('base64');

    // Build directory and pipe base64 through toybox base64 -d
    const cmd = `mkdir -p "$(dirname '${safePath}')" && echo '${b64}' | base64 -d > '${safePath}'`;
    const res = await BridgeController.getInstance().exec(cmd);
    if (!res.ok) {
      return new WriteResult(
        false,
        res.error.length > 0 ? res.error : `Write failed (exit code ${res.exitCode})`
      );
    }
    return new WriteResult(true, '');
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rawPath = (args['path'] as string) ?? '';
    const content = (args['content'] as string) ?? '';

    if (!rawPath || rawPath.trim().length === 0) {
      return {
        toolCallId: toolCallId,
        toolName: 'write',
        output: '',
        error: 'Path cannot be empty',
        isError: true
      };
    }

    try {
      const res = await WriteTool.writeContent(rawPath, content);
      if (res.ok) {
        const ws = AgentWorkspace.getInstance();
        let destDesc = rawPath;
        if (ws.isPublicPath(rawPath)) {
          destDesc = `${ws.resolvePath(rawPath)} (System Public Directory, visible in Files Manager)`;
        } else if (ws.isSandboxPath(rawPath)) {
          destDesc = `${ws.resolvePath(rawPath)} (app workspace)`;
        }
        return {
          toolCallId: toolCallId,
          toolName: 'write',
          output: `Successfully wrote ${content.length} characters to ${destDesc}`,
          isError: false
        };
      } else {
        return {
          toolCallId: toolCallId,
          toolName: 'write',
          output: '',
          error: res.error,
          isError: true
        };
      }
    } catch (err) {
      return {
        toolCallId: toolCallId,
        toolName: 'write',
        output: '',
        error: `Write execution error: ${err}`,
        isError: true
      };
    }
  }
}
