/*
 * ToolPipeline: Execution middleware pipeline for HarmonyOS Pi Agent tools.
 * Inspired by DeepSeek Harness (dsh-tools pipeline: validation, timing, sandboxing, and output normalization).
 */
import hilog from '@ohos.hilog';
import { ToolCall, ToolResult } from '../types';
import { OutputTruncator } from '../harness/OutputTruncator';

const DOMAIN: number = 0x0001;
const TAG: string = 'ToolPipeline';

export type ToolExecutor = (toolCallId: string, parsedArgs: Record<string, Object>) => Promise<ToolResult>;

export class ToolPipeline {
  /**
   * Executes a tool through the pipeline: parameter parsing, execution timing,
   * exception interception, smart head-tail truncation, and structured formatting.
   */
  static async execute(
    toolCall: ToolCall,
    executor: ToolExecutor
  ): Promise<ToolResult> {
    const startTime = Date.now();
    const name = toolCall.function.name;
    const rawArgs = toolCall.function.arguments;

    let parsedArgs: Record<string, Object> = {};
    if (rawArgs && rawArgs.trim().length > 0) {
      try {
        parsedArgs = JSON.parse(rawArgs) as Record<string, Object>;
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'Tool %{public}s failed JSON argument parsing: %{public}s', name, `${err}`);
        return {
          toolCallId: toolCall.id,
          toolName: name,
          output: OutputTruncator.formatStructuredResult(
            name,
            '',
            true,
            `Failed to parse tool arguments JSON: ${err}. Please provide valid JSON parameters.`,
            Date.now() - startTime
          ),
          error: `Failed to parse tool arguments JSON: ${err}`,
          isError: true
        };
      }
    }

    let result: ToolResult;
    try {
      result = await executor(toolCall.id, parsedArgs);
    } catch (toolEx) {
      hilog.error(DOMAIN, TAG, 'Tool %{public}s threw unexpected exception: %{public}s', name, `${toolEx}`);
      result = {
        toolCallId: toolCall.id,
        toolName: name,
        output: '',
        error: `Tool exception: ${toolEx}`,
        isError: true
      };
    }

    const durationMs = Date.now() - startTime;

    // Apply smart Head-Tail truncation and structured result formatting
    const structuredOutput = OutputTruncator.formatStructuredResult(
      name,
      result.output,
      result.isError,
      result.error,
      durationMs
    );

    return {
      toolCallId: result.toolCallId,
      toolName: result.toolName,
      output: structuredOutput,
      images: result.images,
      error: result.error,
      isError: result.isError
    };
  }
}
