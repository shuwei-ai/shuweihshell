/*
 * Pi Read Tool implementation for HarmonyOS.
 * Dual-engine file reader:
 * 1. For relative paths and app sandbox paths, reads directly via @ohos.file.fs
 *    (instant, zero shell dependency, handles large text files cleanly).
 * 2. For external system paths (/data/local/tmp, /proc, /system, etc.), falls back
 *    to uid-2000 shell execution (cat).
 */
import { BridgeController } from '../../common/BridgeController';
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { AgentWorkspace } from './AgentWorkspace';

export class ReadTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'path': new ToolProperty(
        'string',
        'The path of the file to read. Relative paths read from app sandbox workspace; public prefixes (download://, docs://) read from system public directories; paths starting with /data/local/tmp fall back to shell.'
      ),
      'offset': new ToolProperty('number', 'Optional 1-indexed line number to start reading from.'),
      'limit': new ToolProperty('number', 'Optional maximum number of lines to read.')
    };
    const params = new ToolParameters(props, ['path']);
    const func = new ToolFunctionDefinition(
      'read',
      'Read the contents of a file on the device. Supports app workspace files, public directories (download://, docs://) via @ohos.file.fs and @ohos.file.environment, and shell paths.',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rawPath = (args['path'] as string) ?? '';
    const offset = args['offset'] !== undefined ? Number(args['offset']) : 1;
    const limit = args['limit'] !== undefined ? Number(args['limit']) : 0;

    if (!rawPath || rawPath.trim().length === 0) {
      return {
        toolCallId: toolCallId,
        toolName: 'read',
        output: '',
        error: 'Path cannot be empty',
        isError: true
      };
    }

    try {
      let content = '';
      const ws = AgentWorkspace.getInstance();
      if (ws.isPublicPath(rawPath)) {
        await ws.ensurePermissionsSilently();
      }
      if (ws.isSandboxPath(rawPath)) {
        try {
          content = ws.readFile(rawPath);
        } catch (readErr) {
          const errStr = `${readErr}`;
          if (errStr.includes('201') || errStr.toLowerCase().includes('permission')) {
            await ws.ensurePermissionsSilently();
            try {
              content = ws.readFile(rawPath);
            } catch (retryErr) {
              return {
                toolCallId: toolCallId,
                toolName: 'read',
                output: '',
                error: `Failed to read sandbox file ${rawPath}: ${retryErr}`,
                isError: true
              };
            }
          } else {
            return {
              toolCallId: toolCallId,
              toolName: 'read',
              output: '',
              error: `Failed to read sandbox file ${rawPath}: ${readErr}`,
              isError: true
            };
          }
        }
      } else {
        const safePath = rawPath.replace(/'/g, "'\\''");
        const res = await BridgeController.getInstance().exec(`cat '${safePath}'`);
        if (!res.ok) {
          return {
            toolCallId: toolCallId,
            toolName: 'read',
            output: res.output,
            error: res.error.length > 0 ? res.error : `Failed to read file (exit code ${res.exitCode})`,
            isError: true
          };
        }
        content = res.output;
      }

      const allLines = content.split('\n');
      const total = allLines.length;

      let start = Math.max(1, Math.floor(offset));
      if (start > total) {
        return {
          toolCallId: toolCallId,
          toolName: 'read',
          output: `[File has ${total} lines, start line ${start} is beyond end of file]`,
          isError: false
        };
      }

      let count = limit > 0 ? Math.floor(limit) : (total - start + 1);
      let end = Math.min(total, start + count - 1);

      const sliced = allLines.slice(start - 1, end);
      const numberedLines = sliced.map((line: string, idx: number) => {
        const lineNum = (start + idx).toString().padStart(4, ' ');
        return `${lineNum} | ${line}`;
      });

      let formattedOutput = numberedLines.join('\n');
      if (limit > 0 && end < total) {
        formattedOutput += `\n\n[Lines ${start}-${end} of ${total} lines shown]`;
      }

      return {
        toolCallId: toolCallId,
        toolName: 'read',
        output: formattedOutput,
        isError: false
      };
    } catch (err) {
      return {
        toolCallId: toolCallId,
        toolName: 'read',
        output: '',
        error: `Read execution error: ${err}`,
        isError: true
      };
    }
  }
}
