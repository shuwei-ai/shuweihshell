/*
 * Central Tool Registry for the HarmonyOS Pi Agent.
 * Registers bash, read, write, edit, browser, fetch, remember, goal,
 * dispatch_worker, and ask_attention tools.
 * Dispatches all execution through the Harness ToolPipeline.
 */
import { ToolCall, ToolDefinition, ToolResult } from '../types';
import { BashTool } from './BashTool';
import { ReadTool } from './ReadTool';
import { WriteTool } from './WriteTool';
import { EditTool } from './EditTool';
import { UiTool } from './UiTool';
import { RunCodeTool } from './RunCodeTool';
import { RunJsTool } from './RunJsTool';
import { RemoteBashTool } from './RemoteBashTool';
import { BrowserTool } from './BrowserTool';
import { FetchTool } from './FetchTool';
import { InspectImageTool } from './InspectImageTool';
import { RememberTool } from './RememberTool';
import { GoalTool } from './GoalTool';
import { ToolPipeline } from './ToolPipeline';
import { DispatchWorkerTool } from '../superagent/DispatchWorkerTool';
import { AskAttentionTool } from '../superagent/AskAttentionTool';
import { WorkerPresets } from '../superagent/WorkerPresets';
import { WorkerRole } from '../superagent/types';

export class ToolRegistry {
  /**
   * Strictly returns tools available to the Router agent.
   * Strips all heavy execution tools (bash, edit, write, read, ui, run_code, browser, etc.).
   */
  static getRouterToolDefinitions(): ToolDefinition[] {
    return [
      DispatchWorkerTool.getDefinition(),
      AskAttentionTool.getDefinition()
    ];
  }

  /**
   * Returns role-specific execution tools for a specialized Worker agent.
   * Hardened Star Topology: NEVER includes 'dispatch_worker'.
   */
  static getWorkerToolDefinitions(role: WorkerRole, allowed?: string[]): ToolDefinition[] {
    const allowedNames = WorkerPresets.getAllowedToolNames(role, allowed);
    const safeNames = allowedNames.filter(name => name !== 'dispatch_worker');
    return ToolRegistry.getDefinitions().filter(t => safeNames.includes(t.function.name));
  }

  /**
   * Backwards-compatible alias for getWorkerToolDefinitions.
   */
  static getDefinitionsForRole(role?: WorkerRole): ToolDefinition[] {
    if (!role) {
      return ToolRegistry.getDefinitions();
    }
    return ToolRegistry.getWorkerToolDefinitions(role);
  }

  static getDefinitions(): ToolDefinition[] {
    return [
      ReadTool.getDefinition(),
      WriteTool.getDefinition(),
      EditTool.getDefinition(),
      UiTool.getDefinition(),
      RunCodeTool.getDefinition(),
      RunJsTool.getDefinition(),
      RemoteBashTool.getDefinition(),
      BrowserTool.getDefinition(),
      FetchTool.getDefinition(),
      InspectImageTool.getDefinition(),
      RememberTool.getDefinition(),
      GoalTool.getDefinition(),
      DispatchWorkerTool.getDefinition(),
      AskAttentionTool.getDefinition()
    ];
  }

  static async execute(toolCall: ToolCall): Promise<ToolResult> {
    return ToolPipeline.execute(toolCall, async (id: string, args: Record<string, Object>) => {
      const name = toolCall.function.name;
      switch (name) {
        case 'bash':
          return await BashTool.execute(id, args);
        case 'read':
          return await ReadTool.execute(id, args);
        case 'write':
          return await WriteTool.execute(id, args);
        case 'edit':
          return await EditTool.execute(id, args);
        case 'ui':
          return await UiTool.execute(id, args);
        case 'run_code':
          return await RunCodeTool.execute(id, args);
        case 'run_js':
          return await RunJsTool.execute(id, args);
        case 'remote_bash':
          return await RemoteBashTool.execute(id, args);
        case 'browser':
          return await BrowserTool.execute(id, args);
        case 'fetch':
          return await FetchTool.execute(id, args);
        case 'inspect_image':
          return await InspectImageTool.execute(id, args);
        case 'remember':
          return await RememberTool.execute(id, args);
        case 'goal':
          return await GoalTool.execute(id, args);
        case 'dispatch_worker':
          return await DispatchWorkerTool.execute(id, args);
        case 'ask_attention':
          return await AskAttentionTool.execute(id, args);
        default:
          return {
            toolCallId: id,
            toolName: name,
            output: '',
            error: `Unknown tool: ${name}`,
            isError: true
          };
      }
    });
  }
}
