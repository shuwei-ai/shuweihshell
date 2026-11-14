/*
 * Agent Self-Learning Memory Tool (remember) for HarmonyOS Pi Agent.
 * Allows the agent to consciously store and persist lessons, environment facts,
 * and user preferences across sessions.
 */
import hilog from '@ohos.hilog';
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult, MemoryCategory } from '../types';
import { MemoryStore } from '../memory/MemoryStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'RememberTool';

export class RememberTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'rule': new ToolProperty(
        'string',
        'The lesson, constraint, environment rule, or user preference to persist into long-term memory (e.g. "Do not run curl in bash; always use native fetch tool.").'
      ),
      'category': new ToolProperty(
        'string',
        'Category of the memory: "shell", "network", "permission", "tools", "device", or "general". Default is "general".'
      ),
      'trigger': new ToolProperty(
        'string',
        'Optional trigger keyword or error pattern associated with this lesson (e.g. "curl|wget").'
      )
    };

    const params = new ToolParameters(props, ['rule']);
    const func = new ToolFunctionDefinition(
      'remember',
      'Persist an actionable lesson, environmental constraint, or user guideline into permanent memory. Call this whenever you discover a device limitation, command quirk, or user preference so future sessions and tasks will avoid repeating mistakes.',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rule = ((args['rule'] as string) ?? '').trim();
    if (!rule) {
      return {
        toolCallId: toolCallId,
        toolName: 'remember',
        output: '',
        error: 'Missing required argument: rule',
        isError: true
      };
    }

    let category = ((args['category'] as string) ?? 'general').toLowerCase() as MemoryCategory;
    const validCategories: MemoryCategory[] = ['shell', 'network', 'permission', 'tools', 'device', 'general'];
    if (!validCategories.includes(category)) {
      category = 'general';
    }

    const trigger = ((args['trigger'] as string) ?? '').trim();

    try {
      const memoryStore = MemoryStore.getInstance();
      const lesson = await memoryStore.addOrUpdateLesson({
        category: category,
        rule: rule,
        triggerPattern: trigger.length > 0 ? trigger : undefined,
        confidence: 1.0,
        occurrenceCount: 1
      });

      hilog.info(DOMAIN, TAG, `Agent remembered lesson: [${lesson.category}] ${lesson.rule}`);

      return {
        toolCallId: toolCallId,
        toolName: 'remember',
        output: `Successfully saved lesson to long-term memory:\n[${lesson.category.toUpperCase()}] ${lesson.rule}\nThis rule has been incorporated into system memory and will guide all subsequent tasks.`,
        isError: false
      };
    } catch (err) {
      return {
        toolCallId: toolCallId,
        toolName: 'remember',
        output: '',
        error: `Failed to save memory: ${err}`,
        isError: true
      };
    }
  }
}
