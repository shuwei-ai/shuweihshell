/*
 * Real-Time Lesson Reflector for HarmonyOS Pi Agent.
 * Analyzes tool execution traces, errors, and failure outputs to extract
 * actionable avoidance rules, update memory scores, or synthesize new lessons.
 */
import hilog from '@ohos.hilog';
import { MemoryLesson, ToolResult } from '../types';
import { MemoryStore } from './MemoryStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'LessonReflector';

export class LessonReflector {
  private static instance: LessonReflector = new LessonReflector();

  static getInstance(): LessonReflector {
    return LessonReflector.instance;
  }

  /**
   * Evaluates a completed tool call and its result.
   * If an error or failure signature is recognized, reinforces existing memory
   * or records a newly learned constraint.
   */
  async reflectOnToolResult(
    toolName: string,
    args: Record<string, Object>,
    result: ToolResult
  ): Promise<MemoryLesson | undefined> {
    const memoryStore = MemoryStore.getInstance();
    const isError = result.isError;
    const output = (result.output || '') + '\n' + (result.error || '');

    // 1. Bash Tool Reflection
    if (toolName === 'bash') {
      const command = (args['command'] as string || '').trim();

      // Detection: curl or wget attempts in bash
      if (
        command.includes('curl ') ||
        command.includes('wget ') ||
        output.includes('not found: curl') ||
        output.includes('not found: wget') ||
        output.includes('command not found: curl') ||
        output.includes('command not found: wget')
      ) {
        hilog.warn(DOMAIN, TAG, 'Detected curl/wget failure in bash; reinforcing lesson_no_curl');
        await memoryStore.recordOccurrence('lesson_no_curl');
        return memoryStore.getLesson('lesson_no_curl');
      }

      // Detection: Missing toybox utilities (tr, awk, column, etc.)
      const missingUtilMatch = output.match(/command not found:\s*([a-zA-Z0-9_\-]+)/i) ||
        output.match(/([a-zA-Z0-9_\-]+):\s*not found/i);
      if (missingUtilMatch) {
        const utilName = missingUtilMatch[1].trim();
        if (utilName === 'tr' || utilName === 'awk' || utilName === 'column') {
          await memoryStore.recordOccurrence('lesson_toybox_limits');
          return memoryStore.getLesson('lesson_toybox_limits');
        } else if (utilName !== 'curl' && utilName !== 'wget') {
          // Dynamically learn that this specific command is unavailable on the device
          const newLesson = await memoryStore.addOrUpdateLesson({
            id: `lesson_cmd_missing_${utilName}`,
            category: 'shell',
            rule: `设备终端缺少命令 '${utilName}'。请勿在 bash 中执行 '${utilName}'，改用系统其他工具或 native 工具替代。`,
            triggerPattern: `not found: ${utilName}|command not found: ${utilName}|${utilName}`,
            confidence: 0.85,
            occurrenceCount: 1
          });
          hilog.info(DOMAIN, TAG, `Dynamically synthesized new lesson for missing command: ${utilName}`);
          return newLesson;
        }
      }

      // Detection: Permission denied or sandbox restriction
      if (output.includes('Permission denied') || output.includes('Operation not permitted')) {
        await memoryStore.recordOccurrence('lesson_shell_uid_capabilities');
        return memoryStore.getLesson('lesson_shell_uid_capabilities');
      }

      // Detection: uinput gesture out-of-bounds coordinates
      if (command.includes('uinput') && command.includes('-m')) {
        const coords = command.match(/-m\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/);
        if (coords) {
          const y1 = parseInt(coords[2], 10);
          const y2 = parseInt(coords[4], 10);
          if (y1 > 2760 || y2 > 2760) {
            hilog.warn(DOMAIN, TAG, 'Detected out-of-bounds Y coordinate in uinput command');
            await memoryStore.recordOccurrence('lesson_pura70_resolution');
            return memoryStore.getLesson('lesson_pura70_resolution');
          }
        }
      }
    }

    // 2. Edit Tool Reflection
    if (toolName === 'edit' && isError) {
      if (output.includes('Target string not found') || output.includes('multiple times')) {
        hilog.warn(DOMAIN, TAG, 'Detected edit tool string mismatch; reinforcing lesson_edit_strict_match');
        await memoryStore.recordOccurrence('lesson_edit_strict_match');
        return memoryStore.getLesson('lesson_edit_strict_match');
      }
    }

    // 3. Browser Tool Reflection
    if (toolName === 'browser' && isError) {
      if (output.includes('ECONNREFUSED') || output.includes('not connected')) {
        await memoryStore.recordOccurrence('lesson_browser_cdp_loopback');
        return memoryStore.getLesson('lesson_browser_cdp_loopback');
      }
    }

    return undefined;
  }
}
