/*
 * AskAttentionTool: Tool that allows Router and Worker agents to request
 * structured decisions from the human operator.
 * Implements the Attention Protocol from deepseek-ai/dsh-superagent-prototype.
 */
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { AttentionManager } from './AttentionManager';

export class AskAttentionTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'question': new ToolProperty(
        'string',
        'The concrete question or decision to ask the user (e.g., "Which app would you like to test?", "Do you want to proceed with clearing app cache?").'
      ),
      'options': new ToolProperty(
        'array',
        'List of predefined selectable option strings (e.g. ["com.tencent.wechat", "com.huawei.hmos.settings"], ["Yes, proceed", "No, cancel"]).',
        { 'type': 'string' }
      ),
      'allow_custom_input': new ToolProperty(
        'boolean',
        'Optional. Whether the user is also allowed to type custom text in addition to selecting an option. Default true.'
      )
    };

    const params = new ToolParameters(props, ['question', 'options']);
    const func = new ToolFunctionDefinition(
      'ask_attention',
      'Pause execution and prompt the human user with a structured decision card with quick-tap option buttons. Use when facing ambiguous requirements, branch points, or sensitive operations requiring explicit user confirmation.',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const question = (args['question'] as string) ?? '';
    const rawOptions = args['options'] as Object[];
    const options: string[] = [];
    if (Array.isArray(rawOptions)) {
      for (const item of rawOptions) {
        if (typeof item === 'string') {
          options.push(item);
        } else if (item !== undefined && item !== null) {
          options.push(`${item}`);
        }
      }
    }

    const allowCustomInput = args['allow_custom_input'] !== false;

    if (!question || question.trim().length === 0) {
      return {
        toolCallId,
        toolName: 'ask_attention',
        output: '',
        error: 'Question cannot be empty',
        isError: true
      };
    }

    try {
      const selectedAnswer = await AttentionManager.getInstance().requestAttention(
        toolCallId,
        question,
        options,
        allowCustomInput
      );

      return {
        toolCallId,
        toolName: 'ask_attention',
        output: `[USER ATTENTION DECISION]\nQuestion: ${question}\nSelected Answer: ${selectedAnswer}`,
        isError: false
      };
    } catch (err) {
      return {
        toolCallId,
        toolName: 'ask_attention',
        output: '',
        error: `Attention request failed: ${err}`,
        isError: true
      };
    }
  }
}
