/*
 * Pi-compatible Agent Session for HarmonyOS.
 * Orchestrates multi-turn conversation, streaming LLM completions,
 * Harness AgentLoop, semantic context compaction, and dynamic prompt assembly.
 * Inspired by DeepSeek Harness (dsh-agent-loop & dsh-system-prompt).
 */
import hilog from '@ohos.hilog';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { AgentModelConfig, ImageAttachment, Message, SessionEvent } from './types';
import { LlmClient } from './LlmClient';
import { GoalManager } from './goal/GoalManager';
import { ContextTracker, ContextUsageSummary } from './ContextTracker';
import { AgentLoop } from './harness/AgentLoop';
import { ContextCompactor } from './harness/ContextCompactor';
import { SystemPromptAssembler } from './harness/SystemPromptAssembler';
import { WorkerSession } from './superagent/WorkerSession';
import { ToolRegistry } from './tools/ToolRegistry';
import { AgentWorkspace } from './tools/AgentWorkspace';
import { TicketEngine } from './superagent/TicketEngine';
import { Ticket, WorkerRole } from './superagent/types';

const DOMAIN: number = 0x0001;
const TAG: string = 'AgentSession';

export type SessionEventListener = (event: SessionEvent) => void;

export class AgentSession {
  private config: AgentModelConfig;
  private messages: Message[] = [];
  private llmClient: LlmClient = new LlmClient();
  private agentLoop: AgentLoop;
  private listeners: SessionEventListener[] = [];
  private isRunning: boolean = false;
  private runEpoch: number = 0;
  private steeringQueue: Message[] = [];

  constructor(config: AgentModelConfig) {
    this.config = config;
    this.agentLoop = new AgentLoop(this.llmClient);
    this.messages = [
      {
        role: 'system',
        content: SystemPromptAssembler.assembleRouterPrompt(config.enableThinking, config.modelName)
      }
    ];
    this.initRouterWakeupHook();
  }

  /**
   * Wires TicketEngine router wakeup hook (F14).
   * When a background worker finishes or enters WaitingHuman,
   * generates an @专员汇报 message in the conversation timeline summarizing deliverables.
   */
  private initRouterWakeupHook(): void {
    TicketEngine.getInstance().setRouterWakeupCallback((ticket: Ticket) => {
      this.handleWorkerWakeup(ticket);
    });
  }

  private handleWorkerWakeup(ticket: Ticket): void {
    hilog.info(
      DOMAIN,
      TAG,
      'Router wakeup received for ticket %{public}s, role=%{public}s, status=%{public}s',
      ticket.id,
      ticket.role,
      ticket.status
    );

    const summaryContent = this.formatWorkerDeliverablesSummary(ticket);
    const reportMsg: Message = {
      role: 'assistant',
      content: summaryContent
    };

    const imageAttachments: ImageAttachment[] = [];
    if (ticket.artifacts && ticket.artifacts.length > 0) {
      for (const art of ticket.artifacts) {
        if (/\.(png|jpe?g|webp|bmp|gif|svg)$/i.test(art)) {
          let resolved = art;
          if (!resolved.startsWith('/') && !resolved.startsWith('file://')) {
            resolved = AgentWorkspace.getInstance().resolvePath(resolved);
          }
          const uri = resolved.startsWith('file://') ? resolved : 'file://' + resolved;
          imageAttachments.push({
            dataUrl: uri,
            previewUri: uri,
            sourcePath: resolved,
            detail: 'default'
          });
        }
      }
    }
    if (imageAttachments.length > 0) {
      reportMsg.images = imageAttachments;
    }

    this.messages.push(reportMsg);

    this.emit({
      type: 'worker_completed',
      workerRole: ticket.role
    });

    this.emit({
      type: 'turn_complete'
    });
  }

  private formatWorkerDeliverablesSummary(ticket: Ticket): string {
    const roleName = this.formatRoleName(ticket.role);
    if (ticket.status === 'WaitingHuman') {
      let out = `### ⚠️ @专员求助 [${roleName} | 任务: ${ticket.title}]\n\n`;
      out += `后台专员在执行任务 \`${ticket.id}\` 时需要人工确认：\n\n`;
      if (ticket.attention) {
        out += `**待确认事项**: ${ticket.attention.question}\n\n`;
        if (ticket.attention.options && ticket.attention.options.length > 0) {
          out += `**快速决策选项**: ` + ticket.attention.options.map((opt: string) => `\`${opt}\``).join(' | ') + '\n\n';
        }
      } else {
        out += `**待确认事项**: 任务需要人工介入以继续。\n\n`;
      }
      out += `> 请在任务看板点击快速决策选项，或直接在聊天中输入您的决策指令。`;
      return out;
    }

    if (ticket.status === 'Completed') {
      let out = `### 📢 @专员汇报 [${roleName} | 任务: ${ticket.title}]\n\n`;
      out += `后台专员已顺利完成任务 \`${ticket.id}\`。\n\n`;
      out += `**任务目标**: ${ticket.goal}\n\n`;
      if (ticket.result && ticket.result.trim().length > 0) {
        out += `**工作成果与交付总结**:\n${ticket.result}\n\n`;
      }
      if (ticket.artifacts && ticket.artifacts.length > 0) {
        out += `**产出物列表 (Artifacts)**:\n`;
        for (const art of ticket.artifacts) {
          out += `- \`${art}\`\n`;
        }
        out += '\n';
      }
      out += `*(注: 本汇报仅同步工作结论与交付物，已自动沉淀到会话上下文中)*`;
      return out;
    }

    // Failed status
    let out = `### ❌ @专员汇报 [${roleName} | 任务: ${ticket.title}]\n\n`;
    out += `后台专员执行任务 \`${ticket.id}\` 遇到异常。\n\n`;
    out += `**任务目标**: ${ticket.goal}\n\n`;
    out += `**异常原因**:\n${ticket.error || ticket.result || '未知异常'}\n\n`;
    out += `> 您可以查看任务看板重试或重新下发任务。`;
    return out;
  }

  private formatRoleName(role: WorkerRole | string): string {
    switch (role) {
      case 'ui_worker':
        return 'UI 专员';
      case 'code_worker':
        return '代码专员';
      case 'diag_worker':
        return '诊断专员';
      case 'web_worker':
        return '网络专员';
      case 'general_worker':
        return '通用专员';
      default:
        return '专员';
    }
  }

  updateConfig(config: AgentModelConfig): void {
    this.config = config;
    this.refreshSystemPrompt();
  }

  refreshSystemPrompt(): void {
    if (this.messages.length > 0 && this.messages[0].role === 'system') {
      this.messages[0].content = SystemPromptAssembler.assembleRouterPrompt(this.config.enableThinking, this.config.modelName);
    }
  }

  addEventListener(listener: SessionEventListener): void {
    this.listeners.push(listener);
  }

  removeEventListener(listener: SessionEventListener): void {
    this.listeners = this.listeners.filter(l => l !== listener);
  }

  private emit(event: SessionEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (err) {
        // ignore
      }
    }
  }

  getMessages(): Message[] {
    return this.messages;
  }

  setMessages(messages: Message[]): void {
    this.messages = messages;
    this.refreshSystemPrompt();
  }

  clearHistory(): void {
    this.messages = [
      {
        role: 'system',
        content: SystemPromptAssembler.assembleRouterPrompt(this.config.enableThinking, this.config.modelName)
      }
    ];
  }

  getContextUsage(): ContextUsageSummary {
    return ContextTracker.getInstance().computeUsage(this.messages);
  }

  manualCompact(): void {
    if (this.messages.length > 4) {
      const compacted = ContextCompactor.compact(this.messages);
      this.messages = compacted;
      this.refreshSystemPrompt();
    }
  }

  private closeTrailingToolCalls(fallbackText: string): void {
    if (this.messages.length === 0) {
      return;
    }
    const seenIds: Set<string> = new Set();
    let idx = this.messages.length - 1;
    while (idx >= 0 && this.messages[idx].role === 'tool') {
      const tid = this.messages[idx].tool_call_id;
      if (tid) {
        seenIds.add(tid);
      }
      idx--;
    }
    if (idx >= 0 && this.messages[idx].role === 'assistant') {
      const toolCalls = this.messages[idx].tool_calls;
      if (toolCalls && toolCalls.length > 0) {
        for (const tc of toolCalls) {
          if (!seenIds.has(tc.id)) {
            this.messages.push({
              role: 'tool',
              tool_call_id: tc.id,
              name: tc.function.name,
              content: fallbackText
            });
            seenIds.add(tc.id);
          }
        }
      }
    }
  }

  abort(): void {
    this.runEpoch++;
    this.agentLoop.abort();
    WorkerSession.abortAll();
    TicketEngine.getInstance().abortAll();
    // Detach a fresh LlmClient & AgentLoop so an unwinding old tool cannot be un-aborted by a new run
    this.llmClient = new LlmClient();
    this.agentLoop = new AgentLoop(this.llmClient);
    this.isRunning = false;
    this.closeTrailingToolCalls('[Cancelled by user]');
    this.emit({ type: 'stopped' });
  }

  getPendingSteering(): Message[] {
    const queued = [...this.steeringQueue];
    this.steeringQueue = [];
    return queued;
  }

  getIsRunning(): boolean {
    return this.isRunning;
  }

  async runPrompt(userPrompt: string, images?: ImageAttachment[]): Promise<void> {
    TicketEngine.getInstance().recordHumanInput();
    const trimmedPrompt = userPrompt ? userPrompt.trim() : '';
    const validImages: ImageAttachment[] | undefined =
      images && images.length > 0 ? images : undefined;
    if (trimmedPrompt.length === 0 && !validImages) {
      return;
    }
    const effectivePrompt = trimmedPrompt.length > 0 ? userPrompt : '请查看我发送的图片。';

    // If agent loop is already actively executing, enqueue as a mid-stream steering instruction
    if (this.isRunning) {
      const steeringMsg: Message = {
        role: 'user',
        content: `[User Steering Note]: ${effectivePrompt}`,
        images: validImages
      };
      this.steeringQueue.push(steeringMsg);
      this.messages.push(steeringMsg);
      this.emit({
        type: 'user_message_appended',
        text: `[Steering Note]: ${effectivePrompt}`,
        images: validImages
      });
      hilog.info(DOMAIN, TAG, 'Enqueued mid-flight steering note');
      return;
    }

    this.isRunning = true;
    const myEpoch = ++this.runEpoch;

    // Request transient background execution delay so OS does not freeze process if user switches apps
    let suspendDelayId: number = -1;
    try {
      const delayInfo = backgroundTaskManager.requestSuspendDelay('PiAgentTask', () => {
        hilog.warn(DOMAIN, TAG, 'Background suspend delay expired by system');
      });
      suspendDelayId = delayInfo.requestId;
    } catch (e) {
      // ignore if background task manager not permitted
    }

    // If user prompt starts with /goal, initialize autonomous goal
    if (trimmedPrompt.startsWith('/goal')) {
      const goalObjective = trimmedPrompt.substring(5).trim() || 'Autonomous System Task';
      GoalManager.getInstance().startGoal(goalObjective);
      this.emit({
        type: 'goal_updated',
        goal: GoalManager.getInstance().getActiveGoal() as Object
      });
    }

    // Repair any leftover interrupted tool-call chains before compaction or new turn
    this.messages = LlmClient.sanitizeMessages(this.messages);

    // Refresh dynamic waterfall system prompt
    this.refreshSystemPrompt();

    // Check if semantic context compaction is needed
    const maxCapacity = ContextTracker.getInstance().getMaxTokens();
    if (ContextCompactor.shouldCompact(this.messages, maxCapacity, 0.70)) {
      this.messages = ContextCompactor.compact(this.messages);
    }

    // Append user message
    this.messages.push({
      role: 'user',
      content: effectivePrompt,
      images: validImages
    });
    this.emit({
      type: 'user_message_appended',
      text: effectivePrompt,
      images: validImages
    });

    try {
      await this.agentLoop.runLoop(
        this.config,
        this.messages,
        (event: SessionEvent) => {
          if (this.runEpoch !== myEpoch) {
            return;
          }
          if (event.type === 'error') {
            this.closeTrailingToolCalls('[Tool execution interrupted]');
          }
          this.emit(event);
        },
        ToolRegistry.getRouterToolDefinitions(),
        false,
        undefined,
        () => this.getPendingSteering()
      );
    } catch (err) {
      if (this.runEpoch === myEpoch) {
        hilog.error(DOMAIN, TAG, 'Agent autonomous loop caught error: %{public}s', `${err}`);
        this.closeTrailingToolCalls('[Tool execution interrupted]');
        this.emit({
          type: 'error',
          error: `${err}`
        });
      }
    } finally {
      if (this.runEpoch === myEpoch) {
        this.isRunning = false;
      }
      if (suspendDelayId !== -1) {
        try {
          backgroundTaskManager.cancelSuspendDelay(suspendDelayId);
        } catch (e) {
          // ignore
        }
      }
    }
  }
}
