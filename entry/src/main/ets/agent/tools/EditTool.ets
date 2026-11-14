/*
 * Pi Edit Tool implementation for HarmonyOS.
 * Dual-engine surgical search-and-replace:
 * 1. For relative paths and app sandbox paths, reads and writes natively using @ohos.file.fs
 *    via AgentWorkspace and WriteTool.
 * 2. For external system paths (/data/local/tmp, etc.), falls back to uid-2000 shell execution.
 * Validates uniqueness of target string before modifying.
 */
import { BridgeController } from '../../common/BridgeController';
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { WriteTool } from './WriteTool';
import { AgentWorkspace } from './AgentWorkspace';

export class EditTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'path': new ToolProperty(
        'string',
        'The path of the file to edit. Relative paths resolve to the app sandbox workspace; paths starting with /data/local/tmp fall back to shell.'
      ),
      'target': new ToolProperty('string', 'The exact string to be replaced. Must match exactly once in the file.'),
      'replacement': new ToolProperty('string', 'The content to replace the target with.')
    };
    const params = new ToolParameters(props, ['path', 'target', 'replacement']);
    const func = new ToolFunctionDefinition(
      'edit',
      'Edit a file by replacing a unique exact target string with a replacement string. Works on both app sandbox workspace files and system files.',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rawPath = (args['path'] as string) ?? '';
    const target = (args['target'] as string) ?? '';
    const replacement = (args['replacement'] as string) ?? '';

    if (!rawPath || rawPath.trim().length === 0) {
      return {
        toolCallId: toolCallId,
        toolName: 'edit',
        output: '',
        error: 'Path cannot be empty',
        isError: true
      };
    }

    if (target.length === 0) {
      return {
        toolCallId: toolCallId,
        toolName: 'edit',
        output: '',
        error: 'Target string cannot be empty',
        isError: true
      };
    }

    const ws = AgentWorkspace.getInstance();
    let content = '';

    try {
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
                toolName: 'edit',
                output: '',
                error: `Failed to read sandbox file ${rawPath}: ${retryErr}`,
                isError: true
              };
            }
          } else {
            return {
              toolCallId: toolCallId,
              toolName: 'edit',
              output: '',
              error: `Failed to read sandbox file ${rawPath}: ${readErr}`,
              isError: true
            };
          }
        }
      } else {
        const safePath = rawPath.replace(/'/g, "'\\''");
        const readRes = await BridgeController.getInstance().exec(`cat '${safePath}'`);
        if (!readRes.ok) {
          return {
            toolCallId: toolCallId,
            toolName: 'edit',
            output: '',
            error: `Failed to read file ${rawPath}: ${readRes.error}`,
            isError: true
          };
        }
        content = readRes.output;
      }

      let count = 0;
      let firstPos = -1;
      let searchPos = 0;

      while (searchPos <= content.length) {
        const found = content.indexOf(target, searchPos);
        if (found === -1) {
          break;
        }
        count++;
        if (firstPos === -1) {
          firstPos = found;
        }
        searchPos = found + target.length;
      }

      if (count === 0) {
        return {
          toolCallId: toolCallId,
          toolName: 'edit',
          output: '',
          error: `Target string not found in ${rawPath}. Ensure target exactly matches the file content including leading whitespace.`,
          isError: true
        };
      }

      if (count > 1) {
        return {
          toolCallId: toolCallId,
          toolName: 'edit',
          output: '',
          error: `Target string matches ${count} times in ${rawPath}. Please include more surrounding context to uniquely identify the block to replace.`,
          isError: true
        };
      }

      const updated = content.substring(0, firstPos) + replacement + content.substring(firstPos + target.length);
      const writeRes = await WriteTool.writeContent(rawPath, updated);
      if (!writeRes.ok) {
        return {
          toolCallId: toolCallId,
          toolName: 'edit',
          output: '',
          error: `Failed to save edited file: ${writeRes.error}`,
          isError: true
        };
      }

      let destDesc = rawPath;
      if (ws.isPublicPath(rawPath)) {
        destDesc = `${ws.resolvePath(rawPath)} (System Public Directory, visible in Files Manager)`;
      } else if (ws.isSandboxPath(rawPath)) {
        destDesc = `${ws.resolvePath(rawPath)} (app workspace)`;
      }

      return {
        toolCallId: toolCallId,
        toolName: 'edit',
        output: `Successfully edited ${destDesc} (replaced 1 occurrence)`,
        isError: false
      };
    } catch (err) {
      return {
        toolCallId: toolCallId,
        toolName: 'edit',
        output: '',
        error: `Edit execution error: ${err}`,
        isError: true
      };
    }
  }
}
