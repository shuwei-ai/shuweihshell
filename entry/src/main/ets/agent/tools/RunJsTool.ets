/*
 * Built-in Offline JavaScript Sandbox Tool (`run_js`).
 * Backwards-compatible facade over RunCodeTool for JavaScript evaluation.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { RunCodeTool } from './RunCodeTool';

export class RunJsTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'code': new ToolProperty(
        'string',
        'JavaScript (ES2023) code to evaluate inside an isolated offline V8/JSVM sandbox. Use `console.log(...)` for logs and finish with an expression or `return ...` for structured results. Pre-parsed `input` variable holds `input_json` if provided.'
      ),
      'input_json': new ToolProperty(
        'string',
        'Optional raw JSON string automatically parsed into global `input` before running `code`.'
      ),
      'timeout_ms': new ToolProperty(
        'number',
        'Optional execution time budget in milliseconds (100-60000, default: 5000).'
      )
    };
    const params = new ToolParameters(props, ['code']);
    const func = new ToolFunctionDefinition(
      'run_js',
      'Execute synchronous JavaScript offline in an isolated native JSVM sandbox for JSON parsing/transformation, data calculation, regex extraction, statistics, and text formatting when phone shell lacks python/node.',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const wrappedArgs: Record<string, Object> = {};
    const keys = Object.keys(args);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      wrappedArgs[k] = args[k];
    }
    wrappedArgs['language'] = 'javascript';
    const res = await RunCodeTool.execute(toolCallId, wrappedArgs);
    const finalRes: ToolResult = {
      toolCallId: res.toolCallId,
      toolName: 'run_js',
      output: res.output,
      error: res.error,
      isError: res.isError
    };
    return finalRes;
  }
}
