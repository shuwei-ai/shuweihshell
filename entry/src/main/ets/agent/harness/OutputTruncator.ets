/*
 * OutputTruncator: Smart Head-Tail tool output truncator for HarmonyOS Pi Harness.
 * Inspired by DeepSeek Harness (dsh-tools output pipeline).
 *
 * Traditional tail-only truncation drops critical error codes, stack traces, and summaries
 * that appear at the end of command output. Head-Tail truncation retains both the initial
 * invocation context and the final error/exit state.
 */

import { AgentWorkspace } from '../tools/AgentWorkspace';

export interface SpillResult {
  preview: string;
  spillPath: string | null;
}

export class OutputTruncator {
  static readonly DEFAULT_MAX_CHARS: number = 10000;
  static readonly DEFAULT_HEAD_LINES: number = 40;
  static readonly DEFAULT_TAIL_LINES: number = 80;
  static readonly SPILL_THRESHOLD: number = 1500;

  /**
   * Truncates raw output while guaranteeing both head context and tail error/exit lines are preserved.
   */
  static truncate(
    rawOutput: string,
    maxChars: number = OutputTruncator.DEFAULT_MAX_CHARS,
    headLines: number = OutputTruncator.DEFAULT_HEAD_LINES,
    tailLines: number = OutputTruncator.DEFAULT_TAIL_LINES
  ): string {
    if (!rawOutput || rawOutput.length <= maxChars) {
      return rawOutput;
    }

    const lines = rawOutput.split('\n');
    const totalLines = lines.length;

    // Case 1: Few lines, but very long individual lines (e.g. minified json or single-line dumps)
    if (totalLines <= headLines + tailLines) {
      const headCharCount = Math.floor(maxChars * 0.35);
      const tailCharCount = Math.floor(maxChars * 0.65);
      const headPart = rawOutput.substring(0, headCharCount);
      const tailPart = rawOutput.substring(rawOutput.length - tailCharCount);
      const omittedChars = rawOutput.length - (headCharCount + tailCharCount);

      return `${headPart}\n\n[... Truncated ${omittedChars} characters to protect context window. Preserved initial context and error tail ...]\n\n${tailPart}`;
    }

    // Case 2: Multi-line terminal logs, layout dumps, or compile output
    const headPart = lines.slice(0, headLines).join('\n');
    const tailPart = lines.slice(totalLines - tailLines).join('\n');
    const omittedLines = totalLines - (headLines + tailLines);
    const retainedCharCount = headPart.length + tailPart.length;
    const omittedChars = rawOutput.length - retainedCharCount;

    return `${headPart}\n\n[... Truncated ${omittedLines} lines (${omittedChars} characters). Showing first ${headLines} lines of initial context and last ${tailLines} lines with exit/error context ...]\n\n${tailPart}`;
  }

  /**
   * Formats a structured tool feedback message with explicit status indicators.
   * This gives DeepSeek-R1 / V3 clear semantic tags to anchor reasoning branches.
   */
  static formatStructuredResult(
    toolName: string,
    output: string,
    isError: boolean,
    errorMsg?: string,
    durationMs?: number
  ): string {
    const statusTag = isError ? 'STATUS: ERROR' : 'STATUS: SUCCESS';
    const durationTag = durationMs !== undefined ? ` | DURATION: ${durationMs}ms` : '';
    const header = `[TOOL RESULT: ${toolName} | ${statusTag}${durationTag}]`;

    let body = output;
    if (isError && errorMsg && errorMsg.trim().length > 0) {
      if (!body.includes(errorMsg)) {
        body = body.length > 0 ? `${body}\nError Detail: ${errorMsg}` : `Error Detail: ${errorMsg}`;
      }
    }

    const truncatedBody = OutputTruncator.truncate(body);
    return `${header}\n${truncatedBody}`;
  }

  /**
   * Spills oversized tool outputs (> 1500 chars) to sandbox files in workspace/spill/
   * and returns an inline truncated preview with file reference, adhering to DSH-tools pipeline.
   */
  static spillToFile(
    rawOutput: string,
    toolName: string,
    threshold: number = OutputTruncator.SPILL_THRESHOLD
  ): SpillResult {
    if (!rawOutput || rawOutput.length <= threshold) {
      const res: SpillResult = {
        preview: rawOutput,
        spillPath: null
      };
      return res;
    }

    const timestamp = Date.now();
    const safeToolName = (toolName || 'tool').replace(/[^a-zA-Z0-9_-]/g, '_');
    const relativeSpillPath = `spill/tool_${safeToolName}_${timestamp}.txt`;
    let savedPath: string | null = null;

    try {
      AgentWorkspace.getInstance().writeFile(relativeSpillPath, rawOutput);
      savedPath = relativeSpillPath;
    } catch (_e) {
      // If disk write fails (e.g. testing or mock context), fallback to in-memory truncation
    }

    const preview = OutputTruncator.truncate(rawOutput, threshold, 20, 20);
    const notice = savedPath
      ? `\n\n[Full output (${rawOutput.length} chars) spilled to: ${savedPath}. Use 'read' tool to inspect full content.]`
      : `\n\n[Full output (${rawOutput.length} chars) truncated to protect context window.]`;

    const res: SpillResult = {
      preview: `${preview}${notice}`,
      spillPath: savedPath
    };
    return res;
  }
}
