/*
 * AgentLoop: Discrete Turn Execution Engine for HarmonyOS Pi Harness.
 * Inspired by DeepSeek Harness (dsh-agent-loop turn driver, stuck detection, and safe convergence).
 */
import hilog from '@ohos.hilog';
import { AgentModelConfig, Message, SessionEvent, ToolCall, ToolDefinition, ToolResult } from '../types';
import { LlmClient, StreamCallbacks, StreamResult } from '../LlmClient';
import { ToolRegistry } from '../tools/ToolRegistry';
import { ToolConcurrency } from '../tools/ToolConcurrency';
import { ContextCompactor } from './ContextCompactor';
import { LoopIntervention } from './LoopIntervention';
import { OutputTruncator } from './OutputTruncator';
import { SystemPromptAssembler } from './SystemPromptAssembler';
import { LessonReflector } from '../memory/LessonReflector';
import { GoalManager } from '../goal/GoalManager';
import { AttentionManager } from '../superagent/AttentionManager';

const DOMAIN: number = 0x0001;
const TAG: string = 'AgentLoop';

export type SessionEventEmitter = (event: SessionEvent) => void;

export interface ExecutedToolItem {
  tc: ToolCall;
  toolRes: ToolResult;
}

export class AgentLoop {
  private llmClient: LlmClient;
  private loopIntervention: LoopIntervention = new LoopIntervention();
  private abortRequested: boolean = false;
  private runCounter: number = 0;

  constructor(llmClient: LlmClient) {
    this.llmClient = llmClient;
  }

  abort(): void {
    this.abortRequested = true;
    this.llmClient.abort();
    AttentionManager.getInstance().clear();
  }

  isAborted(): boolean {
    return this.abortRequested;
  }

  reset(): void {
    this.abortRequested = false;
    this.loopIntervention.reset();
  }

  /**
   * Ensures an assistant(tool_calls) turn still sitting at the active tail of messages
   * has matching 'tool' messages for every tool_call_id before leaving runLoop.
   * Never appends after subsequent non-tool messages (e.g., stopped banner or next user turn).
   */
  private closePendingToolCallsAtTail(messages: Message[], assistantMsg: Message, fallbackText: string): void {
    if (!assistantMsg.tool_calls || assistantMsg.tool_calls.length === 0) {
      return;
    }
    const idx = messages.lastIndexOf(assistantMsg);
    if (idx === -1) {
      return;
    }
    const recordedIds: Set<string> = new Set();
    for (let i = idx + 1; i < messages.length; i++) {
      if (messages[i].role !== 'tool') {
        // Another turn/banner already follows this assistant message; do not append trailing tool results here.
        return;
      }
      const tid = messages[i].tool_call_id;
      if (tid) {
        recordedIds.add(tid);
      }
    }
    for (const tc of assistantMsg.tool_calls) {
      if (!recordedIds.has(tc.id)) {
        messages.push({
          role: 'tool',
          tool_call_id: tc.id,
          name: tc.function.name,
          content: fallbackText
        });
        recordedIds.add(tc.id);
      }
    }
  }

  /**
   * Drives the iterative agent loop for the session.
   */
  async runLoop(
    config: AgentModelConfig,
    messages: Message[],
    emit: SessionEventEmitter,
    overrideTools?: ToolDefinition[],
    isSubWorker: boolean = false,
    customMaxSteps?: number,
    getSteering?: () => Message[]
  ): Promise<void> {
    this.reset();
    const runId = ++this.runCounter;
    let step = 0;

    while (!this.abortRequested) {
      step++;

      // Check for mid-flight user steering notes before starting the turn
      if (getSteering) {
        const steeringNotes = getSteering();
        if (steeringNotes && steeringNotes.length > 0) {
          for (const s of steeringNotes) {
            if (!messages.includes(s)) {
              messages.push(s);
            }
          }
          hilog.info(DOMAIN, TAG, 'Injected %{public}d user steering messages into turn', steeringNotes.length);
        }
      }

      let maxLoopSteps = 40;
      if (isSubWorker) {
        maxLoopSteps = customMaxSteps && customMaxSteps > 0 ? customMaxSteps : 200;
      } else {
        const currentGoal = GoalManager.getInstance().getActiveGoal();
        maxLoopSteps = currentGoal ? Math.max(120, currentGoal.maxAutonomousSteps * 4) : 40;
      }

      if (step > maxLoopSteps) {
        emit({
          type: 'text_delta',
          text: '\n\n[Agent reached maximum loop step limit]'
        });
        emit({ type: 'turn_complete' });
        break;
      }

      // 1. Semantic Context Budget Management (Router + long Sub-Worker runs)
      const compactThreshold = isSubWorker ? 28 : 18;
      const keepRecentTurns = isSubWorker ? 12 : 8;
      if (ContextCompactor.shouldCompact(messages, 300000, 0.75, compactThreshold)) {
        const compacted = ContextCompactor.compact(messages, keepRecentTurns);
        if (compacted && compacted !== messages && compacted.length > 0) {
          messages.length = 0;
          messages.push(...compacted);
        }
      }

      // 2. Refresh dynamic waterfall system prompt (Router only)
      if (!isSubWorker && messages.length > 0 && messages[0].role === 'system') {
        messages[0].content = SystemPromptAssembler.assembleRouterPrompt(config.enableThinking, config.modelName);
      }

      const tools = overrideTools ?? (isSubWorker ? ToolRegistry.getDefinitions() : ToolRegistry.getRouterToolDefinitions());

      const callbacks: StreamCallbacks = {
        onThinkingDelta: (text: string) => {
          emit({ type: 'thinking_delta', text: text });
        },
        onContentDelta: (text: string) => {
          emit({ type: 'text_delta', text: text });
        },
        onToolCallDelta: (toolCalls: ToolCall[]) => {},
        onRetry: (attempt: number, maxRetries: number, delayMs: number, reason: string) => {
          const waitSec = (delayMs / 1000).toFixed(1);
          const msg = `⚠️ 网络连接或服务端波动 [${reason}]，正在进行第 ${attempt}/${maxRetries} 次重试 (等待 ${waitSec}s)...`;
          // Do not emit text_delta into permanent speech bubbles; update live tool & status indicators
          AppStorage.setOrCreate('agentCurrentTool', msg);
          AppStorage.setOrCreate('agentStatusText', msg);
        }
      };

      let result: StreamResult;
      try {
        result = await this.llmClient.streamChat(config, messages, tools, callbacks);
      } catch (streamErr) {
        if (!this.abortRequested) {
          hilog.error(DOMAIN, TAG, 'LLM stream error: %{public}s', `${streamErr}`);
          emit({ type: 'error', error: `${streamErr}` });
        }
        break;
      }

      if (this.abortRequested || this.runCounter !== runId) {
        break;
      }

      // 3. Guard against completely empty model responses
      let finalContent = result.content;
      if (finalContent.trim().length === 0 && result.tool_calls.length === 0) {
        if (result.reasoning_content && result.reasoning_content.trim().length > 0) {
          finalContent = result.reasoning_content;
        } else {
          hilog.warn(DOMAIN, TAG, 'Received completely empty response from LLM, stopping turn without creating empty card');
          emit({
            type: 'error',
            error: '模型未返回有效回复内容（可能网络异常或Token耗尽），请检查网络后重试'
          });
          break;
        }
      }

      if (this.abortRequested || this.runCounter !== runId) {
        break;
      }

      // 4. Append Assistant Message
      const assistantMessage: Message = {
        role: 'assistant',
        content: finalContent,
        reasoning_content: (config.enableThinking && result.reasoning_content.length > 0)
          ? result.reasoning_content
          : undefined,
        tool_calls: result.tool_calls.length > 0 ? result.tool_calls : undefined
      };
      messages.push(assistantMessage);

      // 5. No Tool Calls: Evaluate Autonomous Continuation vs Turn Complete
      if (result.tool_calls.length === 0) {
        if (isSubWorker) {
          emit({ type: 'turn_complete' });
          break;
        }

        const continuation = GoalManager.getInstance().formatContinuationPrompt();
        const curGoal = GoalManager.getInstance().getActiveGoal();
        const maxAutoSteps = curGoal ? curGoal.maxAutonomousSteps : 30;
        const autoSteps = curGoal ? curGoal.autonomousStepCount : 0;

        if (continuation && !this.abortRequested && this.runCounter === runId && autoSteps < maxAutoSteps) {
          GoalManager.getInstance().incrementStep();
          emit({
            type: 'goal_continued',
            text: continuation
          });
          messages.push({
            role: 'user',
            content: continuation
          });
          continue;
        } else {
          emit({ type: 'turn_complete' });
          break;
        }
      }

      // 5. Execute Tool Calls with Safety Stubs, Parallel Batching & Loop Intervention
      let pendingIntervention: string | null = null;
      try {
        const batches = ToolConcurrency.partitionBatches(result.tool_calls);

        for (const batch of batches) {
          if (this.abortRequested || this.runCounter !== runId) {
            break;
          }

          // Execute batch concurrently via Promise.all
          const executedBatch = await Promise.all(batch.map(async (tc: ToolCall) => {
            emit({ type: 'tool_call_start', toolCall: tc });

            let toolRes: ToolResult;
            if (!isSubWorker && tc.function.name !== 'dispatch_worker' && tc.function.name !== 'ask_attention') {
              toolRes = {
                toolCallId: tc.id,
                toolName: tc.function.name,
                output: '',
                error: `Permission denied: Router cannot execute '${tc.function.name}'. Delegate to a specialized worker via 'dispatch_worker'.`,
                isError: true
              };
            } else if (isSubWorker && tc.function.name === 'dispatch_worker') {
              toolRes = {
                toolCallId: tc.id,
                toolName: tc.function.name,
                output: '',
                error: `Permission denied: Workers are strictly prohibited from executing 'dispatch_worker' (Star Topology).`,
                isError: true
              };
            } else {
              try {
                toolRes = await ToolRegistry.execute(tc);
              } catch (toolEx) {
                toolRes = {
                  toolCallId: tc.id,
                  toolName: tc.function.name,
                  output: `[TOOL RESULT: ${tc.function.name} | STATUS: EXCEPTION]\n${toolEx}`,
                  error: `Tool exception: ${toolEx}`,
                  isError: true
                };
              }
            }

            emit({ type: 'tool_call_result', toolResult: toolRes });
            const item: ExecutedToolItem = { tc: tc, toolRes: toolRes };
            return item;
          }));

          // Check again after await: if user stopped or a newer run started while tools ran
          if (this.abortRequested || this.runCounter !== runId) {
            if (this.runCounter === runId) {
              this.closePendingToolCallsAtTail(
                messages,
                assistantMessage,
                '[Cancelled by user]'
              );
            }
            break;
          }

          for (const item of executedBatch) {
            const tc = item.tc;
            const toolRes = item.toolRes;

            // Parse args for reflection and intervention tracking
            let parsedArgs: Record<string, Object> = {};
            if (tc.function.arguments && tc.function.arguments.trim().length > 0) {
              try {
                parsedArgs = JSON.parse(tc.function.arguments) as Record<string, Object>;
              } catch (e) {
                // ignore
              }
            }

            // 6. Record in Loop Intervention and check for stuck loops / failure oscillations
            this.loopIntervention.record(tc.function.name, parsedArgs, toolRes.isError, toolRes.error);
            const intervention: string | null = this.loopIntervention.detectStuckLoop();
            if (intervention) {
              pendingIntervention = intervention;
            }

            // 7. Dynamic Memory Reflection
            try {
              const reflectedLesson = await LessonReflector.getInstance().reflectOnToolResult(
                tc.function.name,
                parsedArgs,
                toolRes
              );
              if (reflectedLesson && !this.abortRequested && this.runCounter === runId) {
                emit({ type: 'memory_updated', memoryLesson: reflectedLesson });
              }
            } catch (reflEx) {
              // reflection failure should never break agent execution
            }

            // 8. If tool was goal, notify UI
            if (tc.function.name === 'goal') {
              emit({
                type: 'goal_updated',
                goal: GoalManager.getInstance().getActiveGoal() as Object
              });
            }

            // 9. Append Tool Result Message to history (apply Inline-Spill for context compaction)
            const assistantIdx = messages.lastIndexOf(assistantMessage);
            const canAppendAtTail = assistantIdx !== -1 &&
              messages.slice(assistantIdx + 1).every(m => m.role === 'tool');
            if (canAppendAtTail) {
              const spillRes = OutputTruncator.spillToFile(toolRes.output, tc.function.name);
              messages.push({
                role: 'tool',
                tool_call_id: tc.id,
                name: tc.function.name,
                content: spillRes.preview,
                images: toolRes.images
              });
            }
          }
        }
      } finally {
        if (this.runCounter === runId) {
          this.closePendingToolCallsAtTail(
            messages,
            assistantMessage,
            this.abortRequested ? '[Cancelled by user]' : '[Tool execution interrupted]'
          );
        }
      }

      if (this.abortRequested || this.runCounter !== runId) {
        break;
      }

      // 10. Inject Intervention Directive AFTER all tool responses in this turn are recorded
      if (pendingIntervention) {
        hilog.warn(DOMAIN, TAG, 'Loop intervention triggered: %{public}s', pendingIntervention);
        emit({
          type: 'intervention_triggered',
          text: pendingIntervention
        });
        messages.push({
          role: 'user',
          content: pendingIntervention
        });
      }
    }
  }
}
