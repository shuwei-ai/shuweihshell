/*
 * ToolConcurrency: Classifies tools by side-effect safety and batches tool calls
 * for parallel or serialized execution in AgentLoop.
 *
 * - Read-only / idempotent tools (read, fetch, run_js, inspect_image, remember)
 *   can be executed in parallel via Promise.all, reducing end-to-end turn latency.
 * - Mutating tools (bash, ui, write, edit, browser, remote_bash, dispatch_worker, goal, ask_attention)
 *   modify state, trigger physical clicks, or execute shell commands, and are serialized.
 */
import { ToolCall } from '../types';

export class ToolConcurrency {
  /**
   * Set of tools known to be side-effect free, read-only, or isolated compute.
   */
  private static readonly READ_ONLY_TOOLS: Set<string> = new Set([
    'read',
    'fetch',
    'run_code',
    'run_js',
    'inspect_image',
    'remember'
  ]);

  /**
   * Returns true if the tool call is safe to run concurrently with other read-only tools.
   */
  static isReadOnly(toolName: string): boolean {
    return ToolConcurrency.READ_ONLY_TOOLS.has(toolName);
  }

  /**
   * Partitions an array of tool calls into consecutive batches.
   * Contiguous read-only tool calls are grouped together in a single batch (to be executed in parallel).
   * Any mutating tool call forms its own isolated batch of size 1 (to be executed sequentially).
   */
  static partitionBatches(toolCalls: ToolCall[]): ToolCall[][] {
    if (!toolCalls || toolCalls.length === 0) {
      return [];
    }

    const batches: ToolCall[][] = [];
    let currentReadOnlyBatch: ToolCall[] = [];

    for (let i = 0; i < toolCalls.length; i++) {
      const tc = toolCalls[i];
      const isReadOnly = ToolConcurrency.isReadOnly(tc.function.name);

      if (isReadOnly) {
        currentReadOnlyBatch.push(tc);
      } else {
        if (currentReadOnlyBatch.length > 0) {
          batches.push(currentReadOnlyBatch);
          currentReadOnlyBatch = [];
        }
        batches.push([tc]);
      }
    }

    if (currentReadOnlyBatch.length > 0) {
      batches.push(currentReadOnlyBatch);
    }

    return batches;
  }
}
