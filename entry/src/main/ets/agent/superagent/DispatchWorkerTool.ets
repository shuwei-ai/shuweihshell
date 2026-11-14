/*
 * DispatchWorkerTool: Allows the Router Agent to dispatch specialized or dynamically
 * configured sub-worker agents in isolated execution sandboxes.
 * Implements the Router-Worker pattern from deepseek-ai/dsh-superagent-prototype.
 */
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { AgentConfigStore } from '../AgentConfigStore';
import { TicketEngine } from './TicketEngine';
import { Ticket, WorkerRole } from './types';

export class DispatchWorkerTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'role': new ToolProperty(
        'string',
        'Sub-worker role: "ui_worker", "diag_worker", "code_worker", "web_worker", "general_worker", or any custom role name (e.g. "data_worker", "git_worker").'
      ),
      'goal': new ToolProperty(
        'string',
        'The clear, concrete objective the sub-worker must achieve.'
      ),
      'custom_system_prompt': new ToolProperty(
        'string',
        'Optional custom system prompt/persona for the sub-worker defining specialized rules, algorithmic constraints, or instructions.'
      ),
      'allowed_tools': new ToolProperty(
        'array',
        'Optional explicit list of tool names the sub-worker is allowed to call (e.g. ["read", "run_js", "write"]). Restricts the sub-worker to a safe sandbox subset.'
      ),
      'skill': new ToolProperty(
        'string',
        'Optional registered skill name (e.g. "openharmony-diag", "baoyu-post-to-wechat") to equip the sub-worker with.'
      ),
      'context_info': new ToolProperty(
        'string',
        'Optional. Relevant background information, bundle names, file paths, parameters, or previous findings.'
      ),
      'max_steps': new ToolProperty(
        'number',
        'Optional. Maximum autonomous tool steps the sub-worker is allowed to execute. Default 200.'
      )
    };

    const params = new ToolParameters(props, ['role', 'goal']);
    const func = new ToolFunctionDefinition(
      'dispatch_worker',
      'Dispatch a specialized or dynamically created sub-worker agent to execute an objective in an isolated context sandbox. The sub-worker executes its own tool turns and returns only a synthesized WorkerReport, preventing massive tool outputs from polluting your conversation context.',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rawRole = (args['role'] as string) ?? 'general_worker';
    const role: WorkerRole = rawRole && rawRole.trim().length > 0 ? rawRole.trim() : 'general_worker';

    const goal = (args['goal'] as string) ?? '';
    const contextInfo = (args['context_info'] as string) ?? '';
    const customSystemPrompt = (args['custom_system_prompt'] as string) ?? undefined;
    const skillName = (args['skill'] as string) ?? undefined;

    let allowedTools: string[] | undefined = undefined;
    if (Array.isArray(args['allowed_tools'])) {
      allowedTools = (args['allowed_tools'] as Object[]).map(t => String(t));
    }

    const rawMaxSteps = args['max_steps'] as number;
    const maxSteps = typeof rawMaxSteps === 'number' && rawMaxSteps > 0 ? Math.min(rawMaxSteps, 200) : 200;

    if (!goal || goal.trim().length === 0) {
      return {
        toolCallId,
        toolName: 'dispatch_worker',
        output: '',
        error: 'Goal cannot be empty when dispatching worker',
        isError: true
      };
    }

    const config = AgentConfigStore.getInstance().getConfig();

    try {
      const ticket: Ticket = TicketEngine.getInstance().dispatchTask(
        config,
        role,
        goal,
        contextInfo,
        maxSteps,
        customSystemPrompt,
        allowedTools,
        skillName
      );

      const status = ticket.status || 'Running';
      const outputText = `[WORKER DISPATCHED]\nTicket ID: ${ticket.id}\nRole: ${role}\nGoal: ${goal}\nStatus: ${status}\nTask has been dispatched in the background. Inform the user and remain ready for input.`;

      return {
        toolCallId,
        toolName: 'dispatch_worker',
        output: outputText,
        isError: false
      };
    } catch (err) {
      return {
        toolCallId,
        toolName: 'dispatch_worker',
        output: '',
        error: `Failed to dispatch worker task: ${err}`,
        isError: true
      };
    }
  }
}
