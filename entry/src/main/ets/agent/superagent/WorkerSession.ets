/*
 * WorkerSession: Isolated Sub-Agent Execution Sandbox.
 * Implements the Worker Executor pattern from deepseek-ai/dsh-superagent-prototype.
 * Runs in a separate context window to prevent massive tool outputs from polluting the Router.
 */
import hilog from '@ohos.hilog';
import { AgentModelConfig, ImageAttachment, Message, SessionEvent, ToolDefinition } from '../types';
import { LlmClient } from '../LlmClient';
import { AgentLoop } from '../harness/AgentLoop';
import { MemoryStore } from '../memory/MemoryStore';
import { SkillManager } from '../skills/SkillManager';
import { WorkerPresets } from './WorkerPresets';
import { TicketStore } from './TicketStore';
import { TicketEngine } from './TicketEngine';
import { Ticket, TicketStepLog, WorkerProgressEvent, WorkerReport, WorkerRole, WorkerStatus } from './types';
import { ToolRegistry } from '../tools/ToolRegistry';

const DOMAIN: number = 0x0001;
const TAG: string = 'WorkerSession';

export class WorkerSession {
  private static activeLoops: Set<AgentLoop> = new Set();

  /**
   * Aborts all currently active sub-worker loops and their in-flight LLM requests.
   */
  static abortAll(): void {
    const loops: AgentLoop[] = [];
    WorkerSession.activeLoops.forEach((loop: AgentLoop) => {
      loops.push(loop);
    });
    for (let i = 0; i < loops.length; i++) {
      loops[i].abort();
    }
  }

  /**
   * Spawns an isolated sub-worker session and executes the task to completion.
   */
  static async runTask(
    config: AgentModelConfig,
    role: WorkerRole,
    goal: string,
    contextInfo?: string,
    maxSteps: number = 15,
    onProgress?: (event: WorkerProgressEvent) => void,
    customSystemPrompt?: string,
    allowedTools?: string[],
    skillName?: string,
    ticketId?: string
  ): Promise<WorkerReport> {
    const effectiveTicketId = (ticketId && ticketId.trim().length > 0)
      ? ticketId.trim()
      : `worker-${Date.now()}-${Math.floor(Math.random() * 1000)}`;

    const existingTicket = TicketStore.getInstance().getTicket(effectiveTicketId);
    const title = goal.length > 25 ? `${goal.substring(0, 25)}...` : goal;
    const activeTicket: Ticket = existingTicket ? existingTicket : TicketStore.getInstance().createTicket(role, title, goal, contextInfo);
    TicketStore.getInstance().updateStatus(activeTicket.id, 'Running');

    const startTime = Date.now();
    let stepsCount = 0;

    hilog.info(
      DOMAIN,
      TAG,
      'Starting worker ticket: %{public}s, role=%{public}s, goal=%{public}s',
      activeTicket.id,
      role,
      goal
    );

    // 1. Obtain role-restricted or custom-filtered tool definitions
    const allowedNames = WorkerPresets.getAllowedToolNames(role, allowedTools);
    const allTools = ToolRegistry.getDefinitions();
    const workerTools: ToolDefinition[] = allTools.filter(t => allowedNames.includes(t.function.name));

    // 2. Build isolated message history with inherited device memory lessons and optional skill rules
    let systemPrompt = WorkerPresets.getSystemPrompt(role, customSystemPrompt);

    if (skillName && skillName.trim().length > 0) {
      const skill = SkillManager.getInstance().getSkillByName(skillName.trim());
      if (skill) {
        systemPrompt += `\n\n[Active Specialized Skill: ${skill.name}]\nDescription: ${skill.description}\nBase Directory: ${skill.baseDir}\nFile: ${skill.filePath}`;
      }
    }

    const inheritedLessons = MemoryStore.getInstance().formatLessonsForPrompt(6);
    if (inheritedLessons && inheritedLessons.trim().length > 0) {
      systemPrompt += '\n\n' + inheritedLessons;
    }
    const userPrompt = `[Worker Mandate]
Ticket ID: ${activeTicket.id}
Role: ${role}
Assigned Goal (IMMUTABLE): ${goal}
Context & Background: ${contextInfo && contextInfo.trim().length > 0 ? contextInfo : 'None'}

[GOAL ANCHOR & DYNAMIC REPLANNING PROTOCOL]
🎯 IMMUTABLE GOAL: "${goal}" (Your sole objective. Never substitute, drift, or declare success prematurely).

📋 INITIAL BASELINE CHECKLIST:
- [ ] 1. 确认前台界面处于目标应用（若遇双开选择或次级页面，动态恢复）
- [ ] 2. 定位并进入目标联系人/功能界面
- [ ] 3. 准备并输入目标内容（自动清除旧草稿，语音模式切键盘）
- [ ] 4. 点击发送并验证结果气泡已在屏幕上呈现

Execution Rules:
1. 目标不可变（Goal Invariance）：你的终极目标 "${goal}" 是绝对锁死的，绝不能因为中间读取到了其他内容就改变目标。
2. 动态任务清单调节（Dynamic Replanning）：在每一步执行前，对比最新屏幕状态，动态更新任务清单（[x] 已完成, [~] 进行中, [!] 动态插入补救, [ ] 待办）。
3. 异常分支自愈：若遇到非预期状态（如草稿拼接、弹窗、语音模式、软键盘遮挡），动态插入 [!] 补救子任务并使用原生 ui 工具解决，绝不卡死。
4. 严禁在 run_code 中编写 Python 循环脚本来操作 UI（会导致严重 IPC 超时），所有 UI 操作一律使用原生的 ui 工具。
5. 完成门禁（Evidence Before Assertion）：只有在屏幕上验证看到发送后的消息气泡，才能宣称成功并总结回报！`;

    const messages: Message[] = [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userPrompt }
    ];

    // 3. Instantiate dedicated LlmClient and AgentLoop
    const llmClient = new LlmClient();
    const workerLoop = new AgentLoop(llmClient);
    WorkerSession.activeLoops.add(workerLoop);

    let lastError: string | undefined = undefined;
    const capturedImages: ImageAttachment[] = [];

    try {
      AppStorage.setOrCreate('agentIsRunning', true);
      AppStorage.setOrCreate('agentLatestPrompt', `[${role}] ${goal}`);
      AppStorage.setOrCreate('agentThinkingText', '');
    } catch (_e) {
      // Ignore in headless test runner
    }

    try {
      await workerLoop.runLoop(
        config,
        messages,
        (event: SessionEvent) => {
          if (event.type === 'thinking_delta' && event.text) {
            try {
              const cur = AppStorage.get<string>('agentThinkingText') || '';
              AppStorage.setOrCreate('agentThinkingText', cur + event.text);
            } catch (_e) {
              // Ignore
            }
          } else if (event.type === 'tool_call_start' && event.toolCall) {
            stepsCount++;
            const action = `[${role}] 正在调用 ${event.toolCall.function.name}...`;

            // Forward tool_call_start step events directly to TicketStore (F10)
            TicketStore.getInstance().updateProgress(activeTicket.id, stepsCount, maxSteps, action);

            const stepLog: TicketStepLog = {
              step: stepsCount,
              tool: event.toolCall.function.name,
              args: event.toolCall.function.arguments,
              timestamp: Date.now()
            };
            TicketStore.getInstance().addStepLog(activeTicket.id, stepLog);

            const statusText = `🛠️ [${role} ${stepsCount}/${maxSteps}] ${action}`;
            try {
              AppStorage.setOrCreate('agentCurrentTool', statusText);
              AppStorage.setOrCreate('agentStatusText', statusText);
            } catch (_e) {
              // Ignore in headless test runner
            }

            if (onProgress) {
              onProgress({
                ticketId: activeTicket.id,
                role,
                currentStep: stepsCount,
                maxSteps,
                actionText: action
              });
            }
          } else if (event.type === 'tool_call_result' && event.toolResult) {
            TicketStore.getInstance().updateLastStepLog(
              activeTicket.id,
              event.toolResult.output,
              event.toolResult.error
            );
            if (event.toolResult.images) {
              for (const img of event.toolResult.images) {
                capturedImages.push(img);
                if (capturedImages.length > 2) {
                  capturedImages.shift();
                }
              }
            }
          } else if (event.type === 'error' && event.error) {
            lastError = event.error;
          }
        },
        workerTools,
        true, // isSubWorker = true (keeps system prompt, disables auto-continuation)
        maxSteps
      );
    } catch (loopErr) {
      hilog.error(DOMAIN, TAG, 'Worker execution caught exception: %{public}s', `${loopErr}`);
      lastError = `${loopErr}`;
    } finally {
      WorkerSession.activeLoops.delete(workerLoop);
      if (WorkerSession.activeLoops.size === 0) {
        try {
          AppStorage.setOrCreate('agentIsRunning', false);
          AppStorage.setOrCreate('agentThinkingText', '');
        } catch (_e) {
          // Ignore
        }
      }
    }

    if (workerLoop.isAborted() && !lastError) {
      lastError = 'Task aborted by user';
    }

    const durationMs = Date.now() - startTime;

    // 4. Synthesize final outcome from isolated history
    const lastMessage = messages.length > 0 ? messages[messages.length - 1] : undefined;
    let summary = '';

    // Check if the final message in the worker loop is a conclusive assistant text response (no pending tool calls)
    if (
      lastMessage &&
      lastMessage.role === 'assistant' &&
      (!lastMessage.tool_calls || lastMessage.tool_calls.length === 0) &&
      lastMessage.content &&
      lastMessage.content.trim().length > 0
    ) {
      summary = lastMessage.content.trim();
    }

    // Check if the final assistant message only contained reasoning_content
    if (!summary && lastMessage && lastMessage.role === 'assistant' && (!lastMessage.tool_calls || lastMessage.tool_calls.length === 0)) {
      if (lastMessage.reasoning_content && lastMessage.reasoning_content.trim().length > 0) {
        summary = lastMessage.reasoning_content.trim();
      }
    }

    // If sub-worker performed tool calls and terminated at a tool result (e.g. step limit reached)
    // without outputting a final report, trigger a fast 1-turn synthesis with tools=[]
    if (!summary && stepsCount > 0 && !lastError) {
      try {
        hilog.info(DOMAIN, TAG, 'Triggering worker final synthesis turn for ticket: %{public}s', ticketId);
        const synthConfig: AgentModelConfig = {
          baseUrl: config.baseUrl,
          apiKey: config.apiKey,
          modelName: config.modelName,
          autoRunTools: config.autoRunTools,
          enableThinking: false
        };
        messages.push({
          role: 'user',
          content: 'Please provide a clear and concise summary of your completed findings, extracted content, and results based on the tool executions above.'
        });
        const synthRes = await llmClient.streamChat(synthConfig, messages, [], {}, 1);
        if (synthRes.content && synthRes.content.trim().length > 0) {
          summary = synthRes.content.trim();
        }
      } catch (synthErr) {
        hilog.warn(DOMAIN, TAG, 'Worker synthesis request failed: %{public}s', `${synthErr}`);
      }
    }

    // Fallback: extract from latest tool execution output or earlier assistant notes
    if (!summary) {
      const toolMessages = messages.filter(m => m.role === 'tool');
      if (toolMessages.length > 0) {
        const lastTool = toolMessages[toolMessages.length - 1];
        const snippet = lastTool.content.trim();
        summary = `Sub-worker completed actions. Latest output from ${lastTool.name || 'tool'}:\n${snippet.substring(0, 1500)}`;
      } else {
        const assistantMessages = messages.filter(m => m.role === 'assistant');
        for (let i = assistantMessages.length - 1; i >= 0; i--) {
          if (assistantMessages[i].content && assistantMessages[i].content.trim().length > 0) {
            summary = assistantMessages[i].content.trim();
            break;
          }
        }
      }
      if (!summary) {
        if (lastError) {
          summary = `Execution failed with error: ${lastError}`;
        } else {
          summary = 'Sub-worker completed execution turns.';
        }
      }
    }

    // 5. Detect generated file artifacts (e.g. paths in /data/local/tmp/)
    const artifacts: string[] = [];
    const pathRegex = /\/(data|storage|tmp)[a-zA-Z0-9_\-\.\/]+/g;
    for (const msg of messages) {
      if (msg.role === 'tool' || msg.role === 'assistant') {
        const matches = msg.content.match(pathRegex);
        if (matches) {
          for (const match of matches) {
            if (!artifacts.includes(match) && (match.endsWith('.png') || match.endsWith('.json') || match.endsWith('.log') || match.endsWith('.txt') || match.endsWith('.sh'))) {
              artifacts.push(match);
            }
          }
        }
      }
    }

    // 6. Determine final status
    let status: WorkerStatus = 'ready';
    if (lastError !== undefined || summary.startsWith('Execution failed') || summary.startsWith('子任务执行失败')) {
      status = 'failed';
    } else if (summary.startsWith('Blocked:') || summary.startsWith('无法继续:')) {
      status = 'blocked';
    }

    const report: WorkerReport = {
      ticketId: activeTicket.id,
      role,
      status,
      summary,
      artifacts: artifacts.length > 0 ? artifacts : undefined,
      images: capturedImages.length > 0 ? capturedImages : undefined,
      durationMs,
      stepsCount
    };

    // Update TicketStore with terminal status & artifacts, and invoke TicketEngine.onWorkerCompleted
    const finalTicket = TicketStore.getInstance().getTicket(activeTicket.id) || activeTicket;
    finalTicket.historyMessages = messages;
    if (artifacts.length > 0) {
      finalTicket.artifacts = artifacts;
    }
    TicketStore.getInstance().updateTicket(finalTicket);

    const isAborted = workerLoop.isAborted();
    if (isAborted) {
      TicketStore.getInstance().updateStatus(activeTicket.id, 'Failed', 'Task aborted by user');
    } else {
      if (status === 'ready') {
        TicketStore.getInstance().updateStatus(activeTicket.id, 'Completed', summary);
      } else if (status === 'failed') {
        TicketStore.getInstance().updateStatus(activeTicket.id, 'Failed', summary);
      } else if (status === 'blocked' || status === 'attention') {
        finalTicket.status = 'WaitingHuman';
        finalTicket.attention = report.attention;
        TicketStore.getInstance().updateTicket(finalTicket);
      }

      const resolvedTicket = TicketStore.getInstance().getTicket(activeTicket.id) || finalTicket;
      TicketEngine.getInstance().onWorkerCompleted(resolvedTicket);
    }

    hilog.info(
      DOMAIN,
      TAG,
      'Worker finished ticket %{public}s in %{public}dms, steps=%{public}d, status=%{public}s',
      activeTicket.id,
      durationMs,
      stepsCount,
      status
    );

    return report;
  }

  /**
   * Formats a structured WorkerReport into a clean, concise result string for the Router.
   */
  static formatReportOutput(report: WorkerReport): string {
    const statusUpper = report.status.toUpperCase();
    let out = `[WORKER REPORT: ${report.role} | STATUS: ${statusUpper}]\n`;
    out += `Ticket: ${report.ticketId} | Duration: ${report.durationMs}ms | Tool Steps: ${report.stepsCount}\n\n`;
    out += `Execution Summary:\n${report.summary}`;

    if (report.artifacts && report.artifacts.length > 0) {
      out += `\n\nArtifacts Produced:\n- ` + report.artifacts.join('\n- ');
    }
    return out;
  }
}
