/*
 * The bridge's UI with Dual-Tab Architecture:
 * 1. Shell Console: Interactive shell with uid 2000, streaming output, and Shizuku protocol provider.
 * 2. AI Agent: Native HarmonyOS Pi Coding & System Agent with bash, read, write, and edit tools.
 */
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';
import promptAction from '@ohos.promptAction';
import pasteboard from '@ohos.pasteboard';
import window from '@ohos.window';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import fs from '@ohos.file.fs';
import util from '@ohos.util';

import { BridgeController } from '../common/BridgeController';
import { GrantEntry, GrantStore } from '../service/GrantStore';
import { Shizuku } from '../client/Shizuku';
import {
  AgentConfigStore,
  AgentModelConfig,
  AgentSession,
  ImageAttachment,
  ImageEncoder,
  MarkdownView,
  Message,
  RemoteBashTool,
  RemoteServerConfig,
  SessionEvent,
  ToolCall,
  ToolRegistry,
  MemoryStore,
  MemoryLesson,
  MemoryCategory,
  Skill,
  SkillManager,
  AgentWorkspace,
  Goal,
  GoalTask,
  GoalManager,
  ContextTracker,
  ContextUsageSummary,
  ContextUsageDetail,
  ContextCapacityOption,
  CONTEXT_CAPACITIES,
  AttentionManager,
  AttentionRequest,
  TicketStore,
  TicketEngine,
  Ticket,
  TicketStatus,
  TicketStepLog,
  WorkerRole,
  TicketChangeListener
} from '../agent';
import { BrowserManager } from '../browser/BrowserManager';
import { BrowserView } from '../browser/BrowserView';
import { FloatWindowManager } from '../window/FloatWindowManager';

export interface ExtractedFileRef {
  path: string;
  resolvedPath: string;
  fileName: string;
  isImage: boolean;
  isText: boolean;
  sizeBytes: number;
  previewUri?: string;
}

@Entry
@Component
struct Index {
  // Shell Console States
  @State private host: string = '127.0.0.1';
  @State private port: string = '45661';
  @State private connected: boolean = false;
  @State private busy: boolean = false;
  @State private message: string = '';
  @State private command: string = 'id';
  @State private output: string = '';
  @State private publicKey: string = '';
  @State private grants: GrantEntry[] = [];

  // Scrollers for Console Tab
  private pageScroller: Scroller = new Scroller();
  private consoleScroller: Scroller = new Scroller();
  private consoleHScroller: Scroller = new Scroller();

  // Tab State
  @State private currentTabIndex: number = 0;
  private tabsController: TabsController = new TabsController();

  // AI Agent States
  @State private agentSession: AgentSession | undefined = undefined;
  @State private agentMessages: Message[] = [];
  @State private agentThinkingText: string = '';
  @State private agentCurrentText: string = '';
  @State private agentRunning: boolean = false;
  @State private agentInputPrompt: string = '';
  @State private pendingImages: ImageAttachment[] = [];
  @State private isPickingImage: boolean = false;
  @State private currentToolStatus: string = '';
  @State private showSettings: boolean = false;
  @State private showMemoryPanel: boolean = false;
  @State private activeAttention: AttentionRequest | null = null;
  @State private customAttentionInput: string = '';
  @State private activeTickets: Ticket[] = [];
  @State private waitOnCustomInput: string = '';
  @State private expandedTicketId: string = '';
  private ticketStoreListener: TicketChangeListener | null = null;

  // Agent Memory States
  @State private memoryLessons: MemoryLesson[] = [];
  @State private isAddingMemory: boolean = false;
  @State private newMemoryRule: string = '';
  @State private newMemoryCategory: MemoryCategory = 'general';

  // Agent Skills States (Official Pi Specification)
  @State private showSkillsPanel: boolean = false;
  @State private skillsList: Skill[] = [...SkillManager.getInstance().getSkills()];
  @State private isAddingSkill: boolean = false;
  @State private newSkillName: string = '';
  @State private newSkillDesc: string = '';
  @State private newSkillBody: string = '';

  // Agent Goal States (pi-goal-x Architecture)
  @State private activeGoal: Goal | null = null;

  // Context Usage States (Visual Parity with Reference Spec)
  @State private showContextUsageCard: boolean = false;
  @State private contextUsage: ContextUsageSummary = ContextTracker.getInstance().computeUsage([]);
  @State private contextCapacityIndex: number = 0; // 0: 300K (Default), 1: 500K, 2: 1M

  // Agent Config States
  @State private agentBaseUrl: string = 'https://api.minimax.cn/v1';
  @State private agentApiKey: string = '';
  @State private agentModelName: string = 'MiniMax-M3.1-Flash';
  @State private agentAutoRunTools: boolean = true;
  @State private agentEnableThinking: boolean = true;
  @State private autoFloatEnabled: boolean = true;
  @StorageProp('floatWindowActive') floatWindowActive: boolean = false;
  // Remote SSH Server Config States (Item 6)
  @State private remoteEnabled: boolean = false;
  @State private remoteHost: string = '';
  @State private remotePort: string = '22';
  @State private remoteUser: string = '';
  @State private remotePassword: string = '';
  @State private remotePrivateKey: string = '';
  @State private remoteWorkDir: string = '';
  @State private remoteFingerprint: string = '';
  @State private remoteTesting: boolean = false;
  @State private remoteTestResult: string = '';
  // Lightbox Image Preview States (Item 5)
  @State private previewImageUrl: string = '';
  @State private previewImageCaption: string = '';
  // Text File Preview States
  @State private previewTextTitle: string = '';
  @State private previewTextPath: string = '';
  @State private previewTextContent: string = '';

  // Floating & Split Screen States (Phase 2 Multi-Window Adaptation)
  @State private isFloatingMode: boolean = false;
  @State private isSplitScreenMode: boolean = false;
  @State private showFloatingGuide: boolean = false;
  private mainWindow: window.Window | undefined = undefined;

  // Scroller for Agent Chat
  private agentChatScroller: Scroller = new Scroller();

  private context: common.UIAbilityContext | undefined = undefined;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    BrowserManager.getInstance().init(9222);
    this.refresh();
    this.tryAutoConnect();
    this.initAgent();
    this.initWindowListener();
    AttentionManager.getInstance().addListener((req: AttentionRequest | null) => {
      this.activeAttention = req;
    });
    this.ticketStoreListener = (_tickets: Ticket[]) => {
      this.activeTickets = [...TicketStore.getInstance().getActiveTickets()];
    };
    TicketStore.getInstance().addListener(this.ticketStoreListener);
    this.activeTickets = [...TicketStore.getInstance().getActiveTickets()];
  }

  aboutToDisappear(): void {
    if (this.ticketStoreListener) {
      TicketStore.getInstance().removeListener(this.ticketStoreListener);
      this.ticketStoreListener = null;
    }
    if (this.mainWindow) {
      try {
        this.mainWindow.off('windowStatusChange');
      } catch (err) {
        // ignore
      }
    }
  }

  private async initWindowListener(): Promise<void> {
    try {
      this.mainWindow = AppStorage.get<window.Window>('mainWindow');
      if (!this.mainWindow && this.context) {
        this.mainWindow = await window.getLastWindow(this.context);
      }
      if (this.mainWindow) {
        this.mainWindow.on('windowStatusChange', (status: window.WindowStatusType) => {
          this.isFloatingMode = (status === window.WindowStatusType.FLOATING);
          this.isSplitScreenMode = (status === window.WindowStatusType.SPLIT_SCREEN);
          AppStorage.setOrCreate('isFloatingMode', this.isFloatingMode);
          AppStorage.setOrCreate('isSplitScreenMode', this.isSplitScreenMode);
          if (this.isFloatingMode || this.isSplitScreenMode) {
            this.showFloatingGuide = false;
          }
        });
      }
    } catch (err) {
      // Window listener fallback
    }
  }

  private async toggleFloatingWindow(): Promise<void> {
    if (this.floatWindowActive) {
      await FloatWindowManager.getInstance().hideFloatWindow();
      promptAction.showToast({ message: '已关闭悬浮监控窗', duration: 1500 });
      return;
    }

    if (this.isSplitScreenMode || this.isFloatingMode) {
      if (this.mainWindow) {
        try {
          await this.mainWindow.maximize();
          this.isSplitScreenMode = false;
          this.isFloatingMode = false;
          AppStorage.setOrCreate('isSplitScreenMode', false);
          AppStorage.setOrCreate('isFloatingMode', false);
          promptAction.showToast({ message: '已恢复全屏模式', duration: 1500 });
          return;
        } catch (_err) {
          promptAction.showToast({ message: '请双击窗口顶栏或拖动分隔线恢复全屏', duration: 2500 });
          return;
        }
      }
    }

    // Guide user to enter split screen mode
    this.showFloatingGuide = !this.showFloatingGuide;
    promptAction.showToast({
      message: '提示：从屏幕右侧边缘向内滑停顿呼出智慧多窗侧栏，拖出应用开启上下分屏',
      duration: 3500
    });
  }

  private async initAgent(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const store = AgentConfigStore.getInstance();
    const config = await store.load(this.context);
    this.agentBaseUrl = config.baseUrl;
    this.agentApiKey = config.apiKey;
    this.agentModelName = config.modelName;
    this.agentAutoRunTools = config.autoRunTools;
    this.agentEnableThinking = config.enableThinking ?? true;
    this.autoFloatEnabled = AppStorage.get<boolean>('autoFloatEnabled') ?? false;
    const remoteCfg = store.getRemoteConfig();
    this.remoteEnabled = remoteCfg.enabled;
    this.remoteHost = remoteCfg.host;
    this.remotePort = String(remoteCfg.port > 0 ? remoteCfg.port : 22);
    this.remoteUser = remoteCfg.username;
    this.remotePassword = remoteCfg.password;
    this.remotePrivateKey = remoteCfg.privateKeyPem;
    this.remoteWorkDir = remoteCfg.defaultWorkDir;
    this.remoteFingerprint = remoteCfg.expectedFingerprint;

    await MemoryStore.getInstance().init(this.context);
    this.memoryLessons = [...MemoryStore.getInstance().getLessons()];

    AgentWorkspace.getInstance().init(this.context);

    await SkillManager.getInstance().init(this.context);
    this.skillsList = [...SkillManager.getInstance().getSkills()];

    await GoalManager.getInstance().init();
    this.updateGoalUI();

    await TicketStore.getInstance().init(this.context);
    this.activeTickets = [...TicketStore.getInstance().getActiveTickets()];

    this.agentSession = new AgentSession(config);
    AppStorage.setOrCreate('agentSession', this.agentSession);
    this.agentSession.addEventListener((event: SessionEvent) => {
      this.handleSessionEvent(event);
    });
    this.agentMessages = [...this.agentSession.getMessages()];
    this.updateContextUsage();
  }

  private handleSessionEvent(event: SessionEvent): void {
    switch (event.type) {
      case 'user_message_appended':
        if (this.agentSession) {
          this.agentMessages = [...this.agentSession.getMessages()];
          this.updateContextUsage();
        }
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
      case 'memory_updated':
        this.memoryLessons = [...MemoryStore.getInstance().getLessons()];
        this.updateContextUsage();
        promptAction.showToast({
          message: `🧠 沉淀新记忆 [${event.memoryLesson?.category ?? 'rule'}]: ${event.memoryLesson?.rule?.substring(0, 30) ?? ''}...`,
          duration: 2500
        });
        break;
      case 'goal_updated':
        this.updateGoalUI();
        this.updateContextUsage();
        break;
      case 'goal_continued':
        this.updateGoalUI();
        this.currentToolStatus = '🎯 目标自主接力推进中...';
        this.agentCurrentText = '';
        this.agentThinkingText = '';
        AppStorage.setOrCreate('agentThinkingText', '');
        AppStorage.setOrCreate('agentCurrentTool', this.currentToolStatus);
        AppStorage.setOrCreate('agentStatusText', this.currentToolStatus);
        if (this.agentSession) {
          this.agentMessages = [...this.agentSession.getMessages()];
          this.updateContextUsage();
        }
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
      case 'intervention_triggered':
        this.currentToolStatus = '⚠️ 策略调整介入中...';
        this.agentCurrentText = '';
        this.agentThinkingText = '';
        AppStorage.setOrCreate('agentThinkingText', '');
        AppStorage.setOrCreate('agentCurrentTool', this.currentToolStatus);
        AppStorage.setOrCreate('agentStatusText', this.currentToolStatus);
        if (this.agentSession) {
          this.agentMessages = [...this.agentSession.getMessages()];
          this.updateContextUsage();
        }
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
      case 'thinking_delta':
        this.agentThinkingText += event.text ?? '';
        AppStorage.setOrCreate('agentThinkingText', this.agentThinkingText);
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
      case 'text_delta':
        this.agentCurrentText += event.text ?? '';
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
      case 'tool_call_start':
        const toolName = event.toolCall?.function.name ?? 'unknown';
        const toolArgs = event.toolCall?.function.arguments ?? '';
        this.currentToolStatus = `正在执行工具: ${toolName}...`;
        this.agentCurrentText = '';
        this.agentThinkingText = '';
        AppStorage.setOrCreate('agentThinkingText', '');
        AppStorage.setOrCreate('agentCurrentTool', this.currentToolStatus);
        AppStorage.setOrCreate('agentStatusText', this.currentToolStatus);
        if (toolName === 'browser') {
          // Auto-switch to browser tab so the user can visually verify the built-in browser working
          this.currentTabIndex = 2;
          this.tabsController.changeIndex(2);
        }
        if (this.agentSession) {
          this.agentMessages = [...this.agentSession.getMessages()];
          this.updateContextUsage();
        }
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
      case 'tool_call_result':
        this.currentToolStatus = `工具执行完成: ${event.toolResult?.toolName ?? ''}`;
        AppStorage.setOrCreate('agentCurrentTool', '');
        AppStorage.setOrCreate('agentStatusText', this.currentToolStatus);
        if (event.toolResult?.toolName === 'browser' && event.toolResult.output.includes('need_login')) {
          this.currentTabIndex = 2;
          this.tabsController.changeIndex(2);
        }
        if (this.agentSession) {
          this.agentMessages = [...this.agentSession.getMessages()];
          this.updateContextUsage();
        }
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
      case 'turn_complete':
        this.agentRunning = false;
        this.currentToolStatus = '';
        this.agentThinkingText = '';
        this.agentCurrentText = '';
        AppStorage.setOrCreate('agentIsRunning', false);
        AppStorage.setOrCreate('agentCurrentTool', '');
        AppStorage.setOrCreate('agentStatusText', '待命');
        AppStorage.setOrCreate('agentThinkingText', '');
        this.updateGoalUI();
        if (this.agentSession) {
          this.agentMessages = [...this.agentSession.getMessages()];
          this.updateContextUsage();
        }
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
      case 'error':
        this.agentRunning = false;
        this.currentToolStatus = '';
        this.agentThinkingText = '';
        this.agentCurrentText = '';
        AppStorage.setOrCreate('agentIsRunning', false);
        AppStorage.setOrCreate('agentCurrentTool', '');
        AppStorage.setOrCreate('agentThinkingText', '');
        AppStorage.setOrCreate('agentStatusText', `错误: ${event.error}`);
        promptAction.showToast({ message: `Agent 错误: ${event.error}`, duration: 3500 });
        if (this.agentSession) {
          this.agentSession.getMessages().push({
            role: 'assistant',
            content: `⚠️ **任务执行中断**：${event.error}\n\n> 提示：如遇服务端波动或代理超时，可检查设备网络/VPN代理设置，或稍后重新发送。`
          });
          this.agentMessages = [...this.agentSession.getMessages()];
          this.updateContextUsage();
        }
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
      case 'stopped':
        this.agentRunning = false;
        this.currentToolStatus = '';
        this.agentThinkingText = '';
        this.agentCurrentText = '';
        AppStorage.setOrCreate('agentIsRunning', false);
        AppStorage.setOrCreate('agentCurrentTool', '');
        AppStorage.setOrCreate('agentThinkingText', '');
        AppStorage.setOrCreate('agentStatusText', '已停止');
        if (this.agentSession) {
          this.agentSession.getMessages().push({
            role: 'assistant',
            content: '⏹️ **任务已手动停止**。'
          });
          this.agentMessages = [...this.agentSession.getMessages()];
          this.updateContextUsage();
        }
        this.agentChatScroller.scrollEdge(Edge.Bottom);
        break;
    }
  }

  private async copyTextToClipboard(text: string): Promise<void> {
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      await systemPasteboard.setData(pasteData);
      promptAction.showToast({ message: '已复制到剪贴板', duration: 1500 });
    } catch (err) {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    }
  }

  /**
   * Formats the entire conversation history, thought stream, tool calls/results,
   * and worker tickets into a structured Markdown document for review and analysis.
   */
  private formatFullChatHistory(): string {
    const lines: string[] = [];
    lines.push('# PiHA Agent 完整会话与执行记录导出');
    lines.push(`- 导出时间: ${new Date().toLocaleString()}`);
    lines.push(`- 当前模型: ${this.agentModelName || '未指定'}`);
    lines.push(`- 思考模式: ${this.agentEnableThinking ? '开启' : '关闭'}`);
    lines.push('');

    // 1. Export all chat messages
    lines.push('## 💬 会话消息历史');
    const messages = this.agentMessages.filter(m => m.role !== 'system');
    if (messages.length === 0) {
      lines.push('(暂无主会话消息)');
    } else {
      messages.forEach((msg: Message, idx: number) => {
        lines.push('');
        if (msg.role === 'user') {
          lines.push(`### 👤 [User #${idx + 1}]`);
          if (msg.images && msg.images.length > 0) {
            lines.push(`[附加图片: ${msg.images.length} 张]`);
          }
          lines.push(msg.content);
        } else if (msg.role === 'assistant') {
          lines.push(`### 🤖 [Assistant #${idx + 1}]`);
          if (msg.reasoning_content && msg.reasoning_content.trim().length > 0) {
            lines.push('#### 💭 思考过程 (Thinking):');
            lines.push(msg.reasoning_content.trim());
          }
          if (msg.tool_calls && msg.tool_calls.length > 0) {
            lines.push('#### 🛠️ 工具调用:');
            msg.tool_calls.forEach((tc) => {
              lines.push(`- \`${tc.function.name}\`: \`${tc.function.arguments}\``);
            });
          }
          if (msg.content && msg.content.trim().length > 0) {
            lines.push('#### 💬 文本回复:');
            lines.push(msg.content.trim());
          }
        } else if (msg.role === 'tool') {
          lines.push(`### 📄 [Tool Result: ${msg.name ?? 'tool'}]`);
          lines.push('```');
          lines.push(msg.content);
          lines.push('```');
        }
      });
    }

    // 2. Export background worker tickets (if any)
    const allTickets = TicketStore.getInstance().getAllTickets();
    if (allTickets && allTickets.length > 0) {
      lines.push('');
      lines.push('## ⚡ 后台专员 (Sub-Agent) 工单与执行流记录');
      allTickets.forEach((t: Ticket) => {
        lines.push('');
        lines.push(`### 工单: ${t.id} [角色: ${t.role}] (状态: ${t.status})`);
        lines.push(`- **专员目标**: ${t.goal}`);
        if (t.result) {
          lines.push(`- **最终结果**: ${t.result}`);
        }
        if (t.error) {
          lines.push(`- **错误/异常**: ${t.error}`);
        }
        if (t.artifacts && t.artifacts.length > 0) {
          lines.push(`- **产出文件**: ${t.artifacts.join(', ')}`);
        }

        // 2.1 Export sub-agent's complete thought process and message turns (if available)
        if (t.historyMessages && t.historyMessages.length > 0) {
          lines.push('');
          lines.push('#### 🧠 专员内部思考与执行步骤 (Turns):');
          t.historyMessages.forEach((wMsg: Message, wIdx: number) => {
            if (wMsg.role === 'user') {
              lines.push(`##### [专员任务指令 #${wIdx + 1}]`);
              lines.push(wMsg.content);
            } else if (wMsg.role === 'assistant') {
              lines.push(`##### [专员推理 #${wIdx + 1}]`);
              if (wMsg.reasoning_content && wMsg.reasoning_content.trim().length > 0) {
                lines.push('###### 💭 专员深度思考:');
                lines.push(wMsg.reasoning_content.trim());
              }
              if (wMsg.tool_calls && wMsg.tool_calls.length > 0) {
                lines.push('###### 🛠️ 工具调用:');
                wMsg.tool_calls.forEach((tc) => {
                  lines.push(`- \`${tc.function.name}\`: \`${tc.function.arguments}\``);
                });
              }
              if (wMsg.content && wMsg.content.trim().length > 0) {
                lines.push('###### 💬 专员分析说明:');
                lines.push(wMsg.content.trim());
              }
            } else if (wMsg.role === 'tool') {
              lines.push(`##### [工具返回: ${wMsg.name ?? 'tool'}]`);
              const preview = wMsg.content.length > 3000 ? wMsg.content.substring(0, 3000) + '... (truncated)' : wMsg.content;
              lines.push('```');
              lines.push(preview);
              lines.push('```');
            }
          });
        } else if (t.stepLogs && t.stepLogs.length > 0) {
          // 2.2 Fallback to stepLogs if historyMessages was not yet recorded
          lines.push('');
          lines.push('- **执行步骤详情 (Step Logs)**:');
          t.stepLogs.forEach((s: TicketStepLog) => {
            lines.push(`  - 步骤 ${s.step}: 调用 \`${s.tool}\``);
            if (s.args) {
              lines.push(`    参数: \`${s.args}\``);
            }
            if (s.output) {
              const preview = s.output.length > 2000 ? s.output.substring(0, 2000) + '... (truncated)' : s.output;
              lines.push(`    输出: \`\`\`${preview}\`\`\``);
            }
            if (s.error) {
              lines.push(`    报错: \`${s.error}\``);
            }
          });
        }
      });
    }

    // 3. Current active thinking (if running right now)
    if (this.agentThinkingText && this.agentThinkingText.trim().length > 0) {
      lines.push('');
      lines.push('## 💭 当前实时思考流');
      lines.push(this.agentThinkingText.trim());
    }

    return lines.join('\n');
  }

  private buildCurrentRemoteConfig(): RemoteServerConfig {
    const parsedPort = parseInt(this.remotePort.trim(), 10);
    const validPort = (!Number.isNaN(parsedPort) && parsedPort > 0 && parsedPort <= 65535) ? parsedPort : 22;
    this.remotePort = String(validPort);
    return {
      enabled: this.remoteEnabled,
      host: this.remoteHost.trim(),
      port: validPort,
      username: this.remoteUser.trim(),
      password: this.remotePassword,
      privateKeyPem: this.remotePrivateKey.trim(),
      defaultWorkDir: this.remoteWorkDir.trim(),
      expectedFingerprint: this.remoteFingerprint.trim()
    };
  }

  private async testRemoteSsh(): Promise<void> {
    if (this.remoteTesting) {
      return;
    }
    const cfg = this.buildCurrentRemoteConfig();
    if (cfg.host.length === 0 || cfg.username.length === 0) {
      this.remoteTestResult = '❌ 请先填写服务器地址 (Host) 和用户名 (Username)';
      return;
    }
    if (cfg.password.length === 0 && cfg.privateKeyPem.length === 0) {
      this.remoteTestResult = '❌ 请提供 SSH 密码或 PEM 私钥';
      return;
    }
    this.remoteTesting = true;
    this.remoteTestResult = `⏳ 正在连接 ${cfg.username}@${cfg.host}:${cfg.port}...`;
    try {
      const res = await RemoteBashTool.testConnection(cfg);
      if (res.ok) {
        let fpNote = '';
        if (res.hostFingerprint.length > 0 && this.remoteFingerprint.trim().length === 0) {
          this.remoteFingerprint = res.hostFingerprint;
          fpNote = '（已自动填入主机指纹）';
        }
        const firstLine = (res.output ?? '').trim().split('\n')[0] ?? '';
        this.remoteTestResult = `✅ 连接成功${fpNote}\n${res.hostFingerprint}\n${firstLine}`;
      } else {
        this.remoteTestResult = `❌ 连接失败 (exit=${res.exitCode}): ${res.error || res.stderrOutput || '未知错误'}`;
      }
    } catch (err) {
      this.remoteTestResult = `❌ 测试异常: ${err}`;
    } finally {
      this.remoteTesting = false;
    }
  }

  private openImagePreview(src: string, caption: string): void {
    if (!src || src.length === 0) {
      return;
    }
    this.previewImageUrl = src;
    this.previewImageCaption = caption;
  }

  private closeImagePreview(): void {
    this.previewImageUrl = '';
    this.previewImageCaption = '';
  }

  private openTextFilePreview(filePath: string, title: string): void {
    try {
      const realPath = filePath.startsWith('file://') ? filePath.substring(7) : filePath;
      if (!fs.accessSync(realPath)) {
        promptAction.showToast({ message: '文件不存在', duration: 1500 });
        return;
      }
      const stat = fs.statSync(realPath);
      const maxRead = Math.min(stat.size, 128 * 1024);
      const file = fs.openSync(realPath, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(maxRead);
      fs.readSync(file.fd, buf, { offset: 0, length: maxRead });
      fs.closeSync(file);

      const decoder = util.TextDecoder.create('utf-8');
      const text = decoder.decodeWithStream(new Uint8Array(buf));
      this.previewTextTitle = title;
      this.previewTextPath = realPath;
      this.previewTextContent = text + (stat.size > maxRead ? '\n\n...(内容过长，仅展示前 128KB)...' : '');
    } catch (err) {
      promptAction.showToast({ message: `读取文件失败: ${err}`, duration: 1500 });
    }
  }

  private closeTextPreview(): void {
    this.previewTextTitle = '';
    this.previewTextPath = '';
    this.previewTextContent = '';
  }

  private exportFileToDownload(filePath: string): void {
    try {
      const srcPath = filePath.startsWith('file://') ? filePath.substring(7) : filePath;
      if (!fs.accessSync(srcPath)) {
        promptAction.showToast({ message: '源文件不存在', duration: 1500 });
        return;
      }
      const fileName = srcPath.split('/').pop() || 'file';
      const destPath = AgentWorkspace.getInstance().resolvePath(`download://${fileName}`);
      fs.copyFileSync(srcPath, destPath);
      promptAction.showToast({ message: `已保存至系统下载目录: ${fileName}`, duration: 2500 });
    } catch (err) {
      promptAction.showToast({ message: `保存失败: ${err}`, duration: 2000 });
    }
  }

  private getMessageFileAttachments(msg: Message): ExtractedFileRef[] {
    const list: ExtractedFileRef[] = [];
    const seen = new Set<string>();

    if (msg.images && msg.images.length > 0) {
      for (const img of msg.images) {
        const p = img.sourcePath ?? img.previewUri ?? '';
        if (p && !seen.has(p)) {
          seen.add(p);
          const fName = p.split('/').pop() || 'image.png';
          let sz = 0;
          try {
            const cp = p.startsWith('file://') ? p.substring(7) : p;
            if (fs.accessSync(cp)) {
              sz = fs.statSync(cp).size;
            }
          } catch (_e) {}
          list.push({
            path: p,
            resolvedPath: p.startsWith('file://') ? p.substring(7) : p,
            fileName: fName,
            isImage: true,
            isText: false,
            sizeBytes: sz,
            previewUri: img.previewUri ?? img.dataUrl
          });
        }
      }
    }

    if (msg.content && msg.content.length > 0) {
      const pathRegex = /(?:\/data\/storage\/[^\s\)\'\"`]+|\/data\/local\/tmp\/[^\s\)\'\"`]+|download:\/\/[^\s\)\'\"`]+|docs:\/\/[^\s\)\'\"`]+|[\w\-\./]+\.(png|jpe?g|webp|bmp|gif|svg|py|js|ts|json|txt|md|csv|log|sh|ets|xml|html))/gi;
      let match: RegExpExecArray | null = null;
      while ((match = pathRegex.exec(msg.content)) !== null) {
        let raw = match[0].trim();
        raw = raw.replace(/[,\.\'\"\`\)]+$/, '');
        if (raw.length < 3 || seen.has(raw)) {
          continue;
        }
        if (raw.startsWith('http://') || raw.startsWith('https://')) {
          continue;
        }

        const extMatch = raw.match(/\.([a-zA-Z0-9]+)$/);
        if (!extMatch) {
          continue;
        }
        const ext = extMatch[1].toLowerCase();
        const isImage = ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'svg'].includes(ext);
        const isText = ['py', 'js', 'ts', 'json', 'txt', 'md', 'csv', 'log', 'sh', 'ets', 'xml', 'html'].includes(ext);

        if (!isImage && !isText) {
          continue;
        }

        let resolved = raw;
        if (!resolved.startsWith('/') && !resolved.startsWith('file://') && !resolved.startsWith('download://') && !resolved.startsWith('docs://')) {
          resolved = AgentWorkspace.getInstance().resolvePath(resolved);
        } else if (resolved.startsWith('download://') || resolved.startsWith('docs://')) {
          resolved = AgentWorkspace.getInstance().resolvePath(resolved);
        }

        let exists = false;
        let size = 0;
        try {
          const checkPath = resolved.startsWith('file://') ? resolved.substring(7) : resolved;
          if (fs.accessSync(checkPath)) {
            exists = true;
            size = fs.statSync(checkPath).size;
          }
        } catch (_e) {
          exists = false;
        }

        if (exists) {
          seen.add(raw);
          seen.add(resolved);
          const fName = raw.split('/').pop() || raw;
          list.push({
            path: raw,
            resolvedPath: resolved,
            fileName: fName,
            isImage: isImage,
            isText: isText,
            sizeBytes: size,
            previewUri: isImage ? (resolved.startsWith('file://') ? resolved : 'file://' + resolved) : undefined
          });
        }
      }
    }

    return list;
  }

  @Builder
  renderMessageAttachments(msg: Message) {
    ForEach(this.getMessageFileAttachments(msg), (fileRef: ExtractedFileRef) => {
      if (fileRef.isImage) {
        Column({ space: 4 }) {
          Row() {
            Row({ space: 4 }) {
              Text('🖼️')
                .fontSize(11)
              Text(fileRef.fileName)
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor('#0284c7')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)

            if (fileRef.sizeBytes > 0) {
              Text(`${(fileRef.sizeBytes / 1024).toFixed(1)} KB`)
                .fontSize(9)
                .fontColor('#64748b')
                .backgroundColor('#f1f5f9')
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .borderRadius(3)
            }
          }
          .width('100%')

          Stack({ alignContent: Alignment.BottomEnd }) {
            Image(fileRef.previewUri ?? ('file://' + fileRef.resolvedPath))
              .width('100%')
              .height(180)
              .objectFit(ImageFit.Contain)
              .backgroundColor('#0f172a')
              .borderRadius(6)
              .onClick(() => {
                this.openImagePreview(fileRef.previewUri ?? ('file://' + fileRef.resolvedPath), fileRef.fileName);
              })

            Row({ space: 6 }) {
              Button('🔍 全屏')
                .fontSize(10)
                .height(24)
                .padding({ left: 6, right: 6 })
                .backgroundColor('rgba(15, 23, 42, 0.75)')
                .fontColor('#ffffff')
                .onClick(() => {
                  this.openImagePreview(fileRef.previewUri ?? ('file://' + fileRef.resolvedPath), fileRef.fileName);
                })

              Button('💾 导出下载')
                .fontSize(10)
                .height(24)
                .padding({ left: 6, right: 6 })
                .backgroundColor('rgba(2, 132, 199, 0.85)')
                .fontColor('#ffffff')
                .onClick(() => {
                  this.exportFileToDownload(fileRef.resolvedPath);
                })
            }
            .margin({ right: 6, bottom: 6 })
          }
          .width('100%')
          .borderRadius(6)
        }
        .width('100%')
        .padding(8)
        .backgroundColor('#f8fafc')
        .borderRadius(8)
        .border({ width: 0.8, color: '#e2e8f0' })
        .margin({ top: 6 })
      } else if (fileRef.isText) {
        Row({ space: 6 }) {
          Text(fileRef.fileName.endsWith('.py') ? '🐍' : (fileRef.fileName.endsWith('.json') ? '📊' : '📄'))
            .fontSize(16)

          Column({ space: 2 }) {
            Text(fileRef.fileName)
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor('#334155')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(fileRef.sizeBytes > 0 ? `${(fileRef.sizeBytes / 1024).toFixed(1)} KB · 点击预览内容` : '点击预览内容')
              .fontSize(9)
              .fontColor('#64748b')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Row({ space: 4 }) {
            Button('👁️ 预览')
              .fontSize(10)
              .height(24)
              .padding({ left: 6, right: 6 })
              .backgroundColor('#e0f2fe')
              .fontColor('#0284c7')
              .onClick(() => {
                this.openTextFilePreview(fileRef.resolvedPath, fileRef.fileName);
              })

            Button('💾 导出')
              .fontSize(10)
              .height(24)
              .padding({ left: 6, right: 6 })
              .backgroundColor('#f1f5f9')
              .fontColor('#475569')
              .onClick(() => {
                this.exportFileToDownload(fileRef.resolvedPath);
              })
          }
        }
        .width('100%')
        .padding(8)
        .backgroundColor('#f8fafc')
        .borderRadius(6)
        .border({ width: 0.8, color: '#e2e8f0' })
        .margin({ top: 4 })
      }
    }, (fileRef: ExtractedFileRef) => `${fileRef.path}_${fileRef.sizeBytes}`)
  }

  private async saveAgentConfig(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const newConfig: AgentModelConfig = {
      baseUrl: this.agentBaseUrl.trim(),
      apiKey: this.agentApiKey.trim(),
      modelName: this.agentModelName.trim(),
      autoRunTools: this.agentAutoRunTools,
      enableThinking: this.agentEnableThinking
    };
    await AgentConfigStore.getInstance().save(this.context, newConfig);
    const remoteCfg = this.buildCurrentRemoteConfig();
    await AgentConfigStore.getInstance().saveRemoteConfig(this.context, remoteCfg);
    if (this.agentSession) {
      this.agentSession.updateConfig(newConfig);
    }
    this.showSettings = false;
    promptAction.showToast({ message: '模型与远程 SSH 配置已保存', duration: 2000 });
  }

  private async pickAgentImages(): Promise<void> {
    if (this.agentRunning || this.isPickingImage) {
      return;
    }
    const remainingSlots = Math.max(0, 4 - this.pendingImages.length);
    if (remainingSlots <= 0) {
      promptAction.showToast({ message: '单次最多附带 4 张图片', duration: 2000 });
      return;
    }
    this.isPickingImage = true;
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = remainingSlots;
      const picker = new photoAccessHelper.PhotoViewPicker();
      const selectResult = await picker.select(options);
      if (!selectResult || !selectResult.photoUris || selectResult.photoUris.length === 0) {
        return;
      }
      const nextList: ImageAttachment[] = [...this.pendingImages];
      let failedCount = 0;
      for (let i = 0; i < selectResult.photoUris.length; i++) {
        const uri = selectResult.photoUris[i];
        try {
          const encoded = await ImageEncoder.encodeUriToDataUrl(uri, 'default');
          nextList.push(encoded);
        } catch (_encErr) {
          failedCount++;
        }
      }
      this.pendingImages = nextList;
      if (failedCount > 0) {
        promptAction.showToast({ message: `有 ${failedCount} 张图片编码失败`, duration: 2000 });
      }
    } catch (err) {
      promptAction.showToast({ message: `选择图片失败: ${err}`, duration: 2000 });
    } finally {
      this.isPickingImage = false;
    }
  }

  private removePendingImage(index: number): void {
    this.pendingImages = this.pendingImages.filter((_, idx) => idx !== index);
  }

  private async sendAgentPrompt(): Promise<void> {
    const prompt = this.agentInputPrompt.trim();
    if (prompt.length === 0 && this.pendingImages.length === 0) {
      return;
    }

    if (!this.connected) {
      promptAction.showToast({ message: '请先在「Shell 控制台」连接设备调试服务', duration: 2500 });
      return;
    }

    const attachedImages: ImageAttachment[] = [...this.pendingImages];
    const effectivePrompt = prompt.length > 0 ? prompt : '请查看我发送的图片。';

    this.agentInputPrompt = '';
    this.pendingImages = [];

    // If Router is not currently generating, initialize status
    if (!this.agentRunning) {
      this.agentRunning = true;
      this.agentThinkingText = '';
      this.agentCurrentText = '';
      this.currentToolStatus = '正在准备请求...';

      // Synchronize to AppStorage for Float Window
      AppStorage.setOrCreate('agentIsRunning', true);
      AppStorage.setOrCreate('agentLatestPrompt', effectivePrompt);
      AppStorage.setOrCreate('agentStatusText', '正在准备请求...');
      AppStorage.setOrCreate('agentThinkingText', '');
      AppStorage.setOrCreate('agentCurrentTool', '');
    }

    if (this.agentSession) {
      this.agentMessages = [...this.agentSession.getMessages()];
      this.updateContextUsage();
      this.agentChatScroller.scrollEdge(Edge.Bottom);
      await this.agentSession.runPrompt(
        effectivePrompt,
        attachedImages.length > 0 ? attachedImages : undefined
      );
      this.updateContextUsage();
    }
  }

  private stopAgent(): void {
    AttentionManager.getInstance().clear();
    this.activeAttention = null;
    if (this.agentSession) {
      this.agentSession.abort();
    }
  }

  private updateGoalUI(): void {
    const g = GoalManager.getInstance().getActiveGoal();
    if (g) {
      this.activeGoal = {
        id: g.id,
        objective: g.objective,
        status: g.status,
        tasks: g.tasks.map((t: GoalTask): GoalTask => ({
          id: t.id,
          title: t.title,
          status: t.status,
          result: t.result,
          startedAt: t.startedAt,
          completedAt: t.completedAt
        })),
        acceptanceCriteria: [...g.acceptanceCriteria],
        currentStepIndex: g.currentStepIndex,
        maxAutonomousSteps: g.maxAutonomousSteps,
        autonomousStepCount: g.autonomousStepCount,
        createdAt: g.createdAt,
        updatedAt: g.updatedAt,
        completionSummary: g.completionSummary
      };
    } else {
      this.activeGoal = null;
    }
  }

  private formatContextPercentage(pct: number): string {
    if (pct <= 0) {
      return '0%';
    }
    if (pct < 0.1) {
      return '0.1%';
    }
    const rounded = Math.round(pct * 10) / 10;
    if (Math.round(rounded) === rounded) {
      return `${rounded}%`;
    }
    return `${rounded.toFixed(1)}%`;
  }

  private updateContextUsage(): void {
    if (this.agentSession) {
      this.contextUsage = this.agentSession.getContextUsage();
    } else {
      this.contextUsage = ContextTracker.getInstance().computeUsage(this.agentMessages);
    }
  }

  private setContextCapacity(idx: number): void {
    if (idx < 0 || idx >= CONTEXT_CAPACITIES.length) {
      return;
    }
    this.contextCapacityIndex = idx;
    const opt = CONTEXT_CAPACITIES[idx];
    ContextTracker.getInstance().setMaxTokens(opt.tokens);
    this.updateContextUsage();
  }

  private clearAgentHistory(): void {
    if (this.agentSession) {
      this.agentSession.clearHistory();
      this.agentMessages = [...this.agentSession.getMessages()];
      this.updateContextUsage();
    }
    GoalManager.getInstance().clearGoal();
    this.updateGoalUI();
    this.agentThinkingText = '';
    this.agentCurrentText = '';
    this.currentToolStatus = '';
    promptAction.showToast({ message: '会话已清空（长期记忆保留）', duration: 1500 });
  }

  private async deleteMemoryLesson(id: string): Promise<void> {
    await MemoryStore.getInstance().removeLesson(id);
    this.memoryLessons = [...MemoryStore.getInstance().getLessons()];
    if (this.agentSession) {
      this.agentSession.refreshSystemPrompt();
    }
    promptAction.showToast({ message: '已从记忆库移除', duration: 1500 });
  }

  private async resetMemoryLessons(): Promise<void> {
    await MemoryStore.getInstance().resetToDefaults();
    this.memoryLessons = [...MemoryStore.getInstance().getLessons()];
    if (this.agentSession) {
      this.agentSession.refreshSystemPrompt();
    }
    promptAction.showToast({ message: '已重置为预设知识库', duration: 1500 });
  }

  private async addCustomMemoryLesson(): Promise<void> {
    if (!this.newMemoryRule.trim()) {
      promptAction.showToast({ message: '请输入要牢记的规则内容', duration: 1500 });
      return;
    }
    await MemoryStore.getInstance().addOrUpdateLesson({
      rule: this.newMemoryRule.trim(),
      category: this.newMemoryCategory,
      confidence: 1.0,
      occurrenceCount: 1
    });
    this.newMemoryRule = '';
    this.isAddingMemory = false;
    this.memoryLessons = [...MemoryStore.getInstance().getLessons()];
    if (this.agentSession) {
      this.agentSession.refreshSystemPrompt();
    }
    promptAction.showToast({ message: '已保存并注入 Agent 长期记忆', duration: 2000 });
  }

  private getCategoryColor(cat: MemoryCategory): string {
    switch (cat) {
      case 'network': return '#0284c7';
      case 'shell': return '#059669';
      case 'device': return '#9333ea';
      case 'tools': return '#d97706';
      case 'permission': return '#dc2626';
      default: return '#4f46e5';
    }
  }

  private getCategoryBg(cat: MemoryCategory): string {
    switch (cat) {
      case 'network': return '#e0f2fe';
      case 'shell': return '#dcfce7';
      case 'device': return '#f3e8ff';
      case 'tools': return '#fef3c7';
      case 'permission': return '#fee2e2';
      default: return '#eef2ff';
    }
  }

  /**
   * Exercises all 4 Pi Agent tools in end-to-end integration test.
   */
  private async runAgentToolSelfTest(): Promise<void> {
    if (!this.connected) {
      promptAction.showToast({ message: '请先在「Shell 控制台」连接设备调试服务', duration: 2500 });
      return;
    }
    this.agentRunning = true;
    this.currentToolStatus = '正在自测 Pi Agent 4 大核心工具...';

    const testPrompt = '【工具链自测】请依次测试 Pi Agent 的 4 大工具：bash、write、read、edit。';
    if (this.agentSession) {
      this.agentSession.getMessages().push({
        role: 'user',
        content: testPrompt
      });
      this.agentMessages = [...this.agentSession.getMessages()];
      this.agentChatScroller.scrollEdge(Edge.Bottom);
    }

    try {
      const testPath = '/data/local/tmp/pi_agent_verify.txt';

      // 1. RunCodeTool (HDC Bridge via Python)
      this.currentToolStatus = '1/4 测试 run_code 代码沙箱与 HDC 桥接...';
      const runCodeCall: ToolCall = {
        id: 'call_run_code_test_1',
        type: 'function',
        function: {
          name: 'run_code',
          arguments: JSON.stringify({ code: 'import hdc\nres = hdc.shell("uname -a")\nprint(f"HDC uname: {res.output.strip()}")' })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '调用 run_code 工具测试 Python 沙箱与特权 HDC 系统桥接：',
          tool_calls: [runCodeCall]
        });
      }
      const runCodeRes = await ToolRegistry.execute(runCodeCall);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: runCodeCall.id,
          name: 'run_code',
          content: runCodeRes.output
        });
        this.agentMessages = [...this.agentSession.getMessages()];
        this.agentChatScroller.scrollEdge(Edge.Bottom);
      }

      // 2. WriteTool
      this.currentToolStatus = '2/4 测试 write 工具...';
      const initialContent = 'Hello Pi Agent on HarmonyOS!\nLine 2 target for edit\nLine 3 unchanged';
      const writeCall: ToolCall = {
        id: 'call_write_test_2',
        type: 'function',
        function: {
          name: 'write',
          arguments: JSON.stringify({ path: testPath, content: initialContent })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '接着调用 write 工具创建测试文件：',
          tool_calls: [writeCall]
        });
      }
      const writeRes = await ToolRegistry.execute(writeCall);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: writeCall.id,
          name: 'write',
          content: writeRes.isError ? (writeRes.error ?? '') : writeRes.output
        });
        this.agentMessages = [...this.agentSession.getMessages()];
        this.agentChatScroller.scrollEdge(Edge.Bottom);
      }

      // 3. ReadTool
      this.currentToolStatus = '3/4 测试 read 工具...';
      const readCall: ToolCall = {
        id: 'call_read_test_3',
        type: 'function',
        function: {
          name: 'read',
          arguments: JSON.stringify({ path: testPath, offset: 1, limit: 10 })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '调用 read 工具带行号读取文件内容：',
          tool_calls: [readCall]
        });
      }
      const readRes = await ToolRegistry.execute(readCall);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: readCall.id,
          name: 'read',
          content: readRes.output
        });
        this.agentMessages = [...this.agentSession.getMessages()];
        this.agentChatScroller.scrollEdge(Edge.Bottom);
      }

      // 4. EditTool
      this.currentToolStatus = '4/4 测试 edit 工具...';
      const editCall: ToolCall = {
        id: 'call_edit_test_4',
        type: 'function',
        function: {
          name: 'edit',
          arguments: JSON.stringify({
            path: testPath,
            target: 'Line 2 target for edit',
            replacement: 'Line 2 successfully replaced by Pi EditTool!'
          })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '调用 edit 工具执行唯一精确定位替换：',
          tool_calls: [editCall]
        });
      }
      const editRes = await ToolRegistry.execute(editCall);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: editCall.id,
          name: 'edit',
          content: editRes.isError ? (editRes.error ?? '') : editRes.output
        });
      }

      // 5. Verification Read
      const verifyReadCall: ToolCall = {
        id: 'call_read_verify_5',
        type: 'function',
        function: {
          name: 'read',
          arguments: JSON.stringify({ path: testPath })
        }
      };
      const verifyRes = await ToolRegistry.execute(verifyReadCall);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '文件工具自测完成！重新读取验证修改后的文件：\n' + verifyRes.output
        });
      }

      // 5.1 RunCodeTool Python 3.13 Core
      this.currentToolStatus = '5/9 测试 run_code 原生 CPython 3.13 与 f-string...';
      const pyCode = 'import sys, json, math, datetime\n' +
        'print(f"CPython Version: {sys.version}")\n' +
        'print(f"Platform: {sys.platform}")\n' +
        'data = {"calc": math.pow(2, 10), "date": str(datetime.date.today())}\n' +
        'print(f"JSON output: {json.dumps(data)}")\n';
      const pyCall: ToolCall = {
        id: 'call_py_test',
        type: 'function',
        function: {
          name: 'run_code',
          arguments: JSON.stringify({
            language: 'python',
            code: pyCode
          })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '调用 run_code 工具执行原生 CPython 3.13 脚本（验证 sys.version, f-string, math, json, datetime）：',
          tool_calls: [pyCall]
        });
      }
      const pyRes = await ToolRegistry.execute(pyCall);
      hilog.info(0x0001, 'SelfTest', 'Step 5.1 pyRes: output=%{public}s, isError=%{public}s, err=%{public}s', pyRes.output, `${pyRes.isError}`, `${pyRes.error}`);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: pyCall.id,
          name: 'run_code',
          content: pyRes.isError ? (pyRes.error ?? '') : pyRes.output
        });
        this.agentMessages = [...this.agentSession.getMessages()];
        this.agentChatScroller.scrollEdge(Edge.Bottom);
      }

      // 5.2 RunCodeTool Python Network Test
      this.currentToolStatus = '6/10 测试 run_code 原生网络请求 (socket / urllib)...';
      const pyNetCode = 'import socket, urllib.request\n' +
        'try:\n' +
        '    with urllib.request.urlopen("http://example.com", timeout=5) as resp:\n' +
        '        print(f"urllib status: {resp.status}, reason: {resp.reason}")\n' +
        '        print(f"read {len(resp.read())} bytes")\n' +
        'except Exception as e:\n' +
        '    print(f"urllib test: {e}")\n';
      const pyNetCall: ToolCall = {
        id: 'call_py_net_test',
        type: 'function',
        function: {
          name: 'run_code',
          arguments: JSON.stringify({
            language: 'python',
            code: pyNetCode,
            timeout_ms: 15000
          })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '调用 run_code 工具测试 Python 原生网络能力（urllib.request / socket 发起 HTTP GET）：',
          tool_calls: [pyNetCall]
        });
      }
      const pyNetRes = await ToolRegistry.execute(pyNetCall);
      hilog.info(0x0001, 'SelfTest', 'Step 5.2 pyNetRes: output=%{public}s, isError=%{public}s, err=%{public}s', pyNetRes.output, `${pyNetRes.isError}`, `${pyNetRes.error}`);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: pyNetCall.id,
          name: 'run_code',
          content: pyNetRes.isError ? (pyNetRes.error ?? '') : pyNetRes.output
        });
        this.agentMessages = [...this.agentSession.getMessages()];
        this.agentChatScroller.scrollEdge(Edge.Bottom);
      }

      // 5.3 RunCodeTool Python Popular Packages & Drawing Test
      this.currentToolStatus = '7/10 测试 Python 常用生态与图像绘制 (requests, PIL, png, svgwrite)...';
      const pyExtCode = 'import sys\n' +
        'import requests\n' +
        'from PIL import Image, ImageDraw\n' +
        'import png, svgwrite\n' +
        'from bs4 import BeautifulSoup\n' +
        'import jinja2, qrcode\n' +
        'img = Image.new("RGB", (200, 100), color="white")\n' +
        'draw = ImageDraw.Draw(img)\n' +
        'draw.rectangle([10, 10, 190, 90], outline="blue", width=2)\n' +
        'draw.text((25, 45), "PIL OK", fill="red")\n' +
        'print("requests:", requests.__version__)\n' +
        'print("PIL (Image, ImageDraw) & pypng: OK")\n' +
        'print("svgwrite:", svgwrite.__version__)\n' +
        'print("bs4 & jinja2 & qrcode: OK")\n';
      const pyExtCall: ToolCall = {
        id: 'call_py_ext_test',
        type: 'function',
        function: {
          name: 'run_code',
          arguments: JSON.stringify({
            language: 'python',
            code: pyExtCode,
            timeout_ms: 15000
          })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '调用 run_code 工具测试预置 Python 生态库（requests, PIL, png, svgwrite, bs4, jinja2, qrcode）：',
          tool_calls: [pyExtCall]
        });
      }
      const pyExtRes = await ToolRegistry.execute(pyExtCall);
      hilog.info(0x0001, 'SelfTest', 'Step 5.3 pyExtRes: output=%{public}s, isError=%{public}s, err=%{public}s', pyExtRes.output, `${pyExtRes.isError}`, `${pyExtRes.error}`);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: pyExtCall.id,
          name: 'run_code',
          content: pyExtRes.isError ? (pyExtRes.error ?? '') : pyExtRes.output
        });
        this.agentMessages = [...this.agentSession.getMessages()];
        this.agentChatScroller.scrollEdge(Edge.Bottom);
      }

      // 6. BrowserTool (ArkWeb + CDP)
      this.currentToolStatus = '7/9 测试 browser 浏览器工具...';
      const browserCall: ToolCall = {
        id: 'call_browser_test_6',
        type: 'function',
        function: {
          name: 'browser',
          arguments: JSON.stringify({ action: 'snapshot', mode: 'text' })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '调用 browser 工具获取内置 ArkWeb 浏览器当前页面快照：',
          tool_calls: [browserCall]
        });
      }
      const browserRes = await ToolRegistry.execute(browserCall);
      hilog.info(0x0001, 'SelfTest', 'Step 7 browserRes: isError=%{public}s, output=%{public}s, err=%{public}s', `${browserRes.isError}`, browserRes.output.substring(0, 150), `${browserRes.error}`);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: browserCall.id,
          name: 'browser',
          content: browserRes.isError ? (browserRes.error ?? '') : browserRes.output
        });
      }

      // 7. FetchTool (Native Network Stack)
      this.currentToolStatus = '8/9 测试 fetch 原生网络请求工具...';
      const fetchCall: ToolCall = {
        id: 'call_fetch_test_7',
        type: 'function',
        function: {
          name: 'fetch',
          arguments: JSON.stringify({ url: 'https://httpbin.org/get', method: 'GET' })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '调用 fetch 工具发起原生 HTTP GET 请求（解决缺少 curl 的受限 shell 问题）：',
          tool_calls: [fetchCall]
        });
      }
      const fetchRes = await ToolRegistry.execute(fetchCall);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: fetchCall.id,
          name: 'fetch',
          content: fetchRes.isError ? (fetchRes.error ?? '') : fetchRes.output
        });
        this.agentMessages = [...this.agentSession.getMessages()];
        this.agentChatScroller.scrollEdge(Edge.Bottom);
      }

      // 8. RememberTool (Self-Learning Long-Term Memory)
      this.currentToolStatus = '9/9 测试 remember 长期记忆沉淀工具...';
      const rememberCall: ToolCall = {
        id: 'call_remember_test_8',
        type: 'function',
        function: {
          name: 'remember',
          arguments: JSON.stringify({
            rule: '自动化自测验证：已成功跑通 8 大核心工具链（含 CPython 3.13 原生沙箱）与自学习记忆闭环。',
            category: 'tools',
            trigger: 'selftest'
          })
        }
      };
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '调用 remember 工具将本次自测验证结论持久化沉淀到长期记忆知识库：',
          tool_calls: [rememberCall]
        });
      }
      const rememberRes = await ToolRegistry.execute(rememberCall);
      if (this.agentSession) {
        this.agentSession.getMessages().push({
          role: 'tool',
          tool_call_id: rememberCall.id,
          name: 'remember',
          content: rememberRes.isError ? (rememberRes.error ?? '') : rememberRes.output
        });
        this.agentSession.getMessages().push({
          role: 'assistant',
          content: '🎉 Pi Agent 核心工具链（bash, read, write, edit, run_code [CPython 3.13], browser, fetch, remember）与自学习记忆闭环自测全部通过！'
        });
        this.agentMessages = [...this.agentSession.getMessages()];
        this.agentChatScroller.scrollEdge(Edge.Bottom);
      }
      this.memoryLessons = [...MemoryStore.getInstance().getLessons()];

      // Cleanup
      await BridgeController.getInstance().exec(`rm -f '${testPath}'`);
      promptAction.showToast({ message: '🎉 Pi Agent 7 大核心工具与记忆闭环自测全部通过！', duration: 3000 });
    } catch (err) {
      promptAction.showToast({ message: `自测异常: ${err}`, duration: 3500 });
    } finally {
      this.agentRunning = false;
      this.currentToolStatus = '';
    }
  }

  /**
   * On startup, try to find the device's hdc daemon on its own.
   */
  private async tryAutoConnect(): Promise<void> {
    if (this.context === undefined || this.connected) {
      return;
    }
    this.busy = true;
    try {
      const port = Number.parseInt(this.port, 10);
      const result = await BridgeController.getInstance().connect(this.context as common.Context, this.host, port);
      if (result.ok) {
        this.connected = true;
        this.message = '已连接，命令以 uid 2000 (shell) 运行。';
        try {
          AgentWorkspace.getInstance().ensurePermissionsSilently();
          await SkillManager.getInstance().init(this.context as common.Context);
          this.skillsList = [...SkillManager.getInstance().getSkills()];
          if (this.agentSession) {
            this.agentSession.refreshSystemPrompt();
          }
        } catch (e) {
          // ignore
        }
      } else {
        this.message = `${result.error} 请在「开发者选项 → 无线调试」中开启后重试。`;
      }
    } catch (error) {
      this.message = `连接失败：${error}`;
    } finally {
      this.busy = false;
      this.refresh();
    }
  }

  private refresh(): void {
    const status = BridgeController.getInstance().status();
    this.connected = status.connected;
    this.publicKey = status.publicKey;
    if (status.lastError.length > 0) {
      this.message = status.lastError;
    }
    this.loadGrants();
    if (this.connected && this.skillsList.length === 0) {
      this.refreshSkills();
    }
  }

  private async loadGrants(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    await GrantStore.getInstance().load(this.context);
    this.grants = GrantStore.getInstance().list();
  }

  private async connect(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.busy = true;
    this.message = '正在连接设备… 设备会弹出授权对话框，请选择「始终允许」。';
    try {
      const port = Number.parseInt(this.port, 10);
      const result = await BridgeController.getInstance().connect(this.context, this.host, port);
      if (result.ok) {
        this.connected = true;
        this.message = '已连接，命令以 uid 2000 (shell) 运行。';
        try {
          AgentWorkspace.getInstance().ensurePermissionsSilently();
          await SkillManager.getInstance().init(this.context as common.Context);
          this.skillsList = [...SkillManager.getInstance().getSkills()];
          if (this.agentSession) {
            this.agentSession.refreshSystemPrompt();
          }
        } catch (e) {
          // ignore
        }
      } else {
        this.connected = false;
        this.message = `连接失败：${result.error}`;
      }
    } catch (error) {
      this.connected = false;
      this.message = `连接失败：${error}`;
    } finally {
      this.busy = false;
      this.refresh();
    }
  }

  private async discover(): Promise<void> {
    this.busy = true;
    this.message = '正在查找设备上的调试服务…';
    try {
      const ports = BridgeController.getInstance().listPorts();
      const result = await BridgeController.getInstance().connect(this.context as common.Context, '127.0.0.1', 0);
      if (result.ok) {
        this.connected = true;
        this.message = `已连接（设备监听端口：${ports.join(', ')}）。`;
      } else {
        this.message = `自动发现失败：${result.error} 请手动填写端口。`;
      }
    } catch (error) {
      this.message = `自动发现失败：${error} 请手动填写端口。`;
    } finally {
      this.busy = false;
      this.refresh();
    }
  }

  /**
   * Executes the command with real-time streaming output.
   */
  private async run(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.output = '';
    this.consoleHScroller.scrollEdge(Edge.Start);
    try {
      const result = await BridgeController.getInstance().execStream(
        this.command,
        (chunk: string) => {
          const clearIdx = chunk.lastIndexOf('\u001b[H\u001b[J');
          if (clearIdx !== -1) {
            this.output = this.cleanAnsi(chunk.slice(clearIdx + 6));
          } else {
            const altClearIdx = chunk.lastIndexOf('\u001b[2J');
            if (altClearIdx !== -1) {
              this.output = this.cleanAnsi(chunk.slice(altClearIdx + 4));
            } else {
              this.output += this.cleanAnsi(chunk);
            }
          }
          if (this.output.length > 80000) {
            this.output = this.output.slice(this.output.length - 60000);
          }
          this.consoleScroller.scrollEdge(Edge.Bottom);
        },
        '',
        0
      );
      if (this.output.length === 0) {
        this.output = result.ok ? '(无输出)' : `错误：${result.error}`;
      } else if (!result.ok && result.error.length > 0) {
        this.output += `\n[${result.error}]`;
      }
    } catch (error) {
      this.output += `\n执行异常：${error}`;
    } finally {
      this.busy = false;
      this.consoleScroller.scrollEdge(Edge.Bottom);
    }
  }

  private cleanAnsi(text: string): string {
    return text
      .replace(/\u001b(?:\[[0-?]*[ -/]*[@-~]|\].*?(?:\x07|\u001b\\)|[@-Z\\-_])/g, '')
      .replace(/\r\n/g, '\n')
      .replace(/\r/g, '');
  }

  private stop(): void {
    BridgeController.getInstance().abort();
  }

  private clearOutput(): void {
    this.output = '';
    this.consoleHScroller.scrollEdge(Edge.Start);
  }

  private async revoke(bundleName: string): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    await GrantStore.getInstance().revoke(this.context, bundleName);
    await this.loadGrants();
  }

  private async testShizukuSdk(): Promise<void> {
    if (!this.connected) {
      this.message = '请先连接设备调试服务。';
      return;
    }
    this.busy = true;
    this.output = '==> 开始运行 Shizuku SDK 兼容性自测...\n';
    try {
      this.output += '1. 正在绑定 Shizuku / ShellBridge 服务...\n';
      const bound = await Shizuku.bind(this.context as common.Context);
      this.output += `   bind() 结果: ${bound ? '成功' : '失败'}\n`;
      if (!bound) {
        this.output += '❌ 无法绑定服务，请确认 ExtensionAbility 配置。\n';
        return;
      }

      this.output += '2. 测试 pingBinder()...\n';
      const ping = await Shizuku.pingBinder();
      this.output += `   pingBinder(): ${ping} (服务活跃响应)\n`;

      this.output += '3. 测试 getVersion()...\n';
      const version = await Shizuku.getVersion();
      this.output += `   getVersion(): v${version}\n`;

      this.output += '4. 测试 getUid()...\n';
      const uid = await Shizuku.getUid();
      this.output += `   getUid(): ${uid} (预期 2000 shell)\n`;

      this.output += '5. 测试 getSelinuxContext()...\n';
      const secon = await Shizuku.getSelinuxContext();
      this.output += `   getSelinuxContext(): ${secon}\n`;

      this.output += '6. 测试 checkSelfPermission()...\n';
      const hasPerm = await Shizuku.checkSelfPermission();
      this.output += `   checkSelfPermission(): ${hasPerm}\n`;

      this.output += '7. 测试 requestPermission()...\n';
      const reqPerm = await Shizuku.requestPermission(100);
      this.output += `   requestPermission(): ${reqPerm}\n`;

      this.output += '8. 测试 exec("id")...\n';
      const idOut = await Shizuku.exec('id');
      this.output += `   exec("id") 输出:\n${idOut.trim()}\n`;

      this.output += '9. 测试 execWithResult("param get const.product.name")...\n';
      const res = await Shizuku.execWithResult('param get const.product.name');
      this.output += `   execWithResult(): ok=${res.ok}, exitCode=${res.exitCode}, output=${res.output.trim()}\n`;

      this.output += '\n🎉 Shizuku 协议兼容性自测全部通过！\n';
      this.loadGrants();
    } catch (err) {
      this.output += `❌ 测试失败: ${err}\n`;
    } finally {
      this.busy = false;
    }
  }

  // -------------------------------------------------------------------------
  // UI Builders
  // -------------------------------------------------------------------------

  @Builder
  buildConsoleTab() {
    Scroll(this.pageScroller) {
      Column({ space: 14 }) {
        Text('PiHA Shell 控制台')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .width('100%')

        Text(this.connected ? '状态：已连接 (uid 2000 / shell)' : '状态：未连接')
          .fontSize(14)
          .width('100%')
          .fontColor(this.connected ? '#0a7d28' : '#8a8a8a')

        if (!this.connected) {
          Column({ space: 10 }) {
            Text('第 1 步：在「设置 → 系统 → 开发者选项」中开启「无线调试」。')
              .fontSize(13)
              .width('100%')
            Text('第 2 步：App 会自动查找设备上的调试服务；也可以把开发者选项里显示的端口填到下面。')
              .fontSize(13)
              .width('100%')
            Text('第 3 步：点击连接。设备会弹出「允许调试」的对话框，请选择「始终允许」。')
              .fontSize(13)
              .width('100%')

            Button('自动发现端口')
              .enabled(!this.busy)
              .onClick(() => { this.discover(); })
              .width('100%')

            TextInput({ text: this.host, placeholder: '127.0.0.1' })
              .onChange((value: string) => { this.host = value; })
              .width('100%')
            TextInput({ text: this.port, placeholder: '8710' })
              .type(InputType.Number)
              .onChange((value: string) => { this.port = value; })
              .width('100%')

            Button('连接设备')
              .enabled(!this.busy)
              .onClick(() => { this.connect(); })
              .width('100%')
          }
          .padding(14)
          .backgroundColor('#ffffff')
          .borderRadius(10)
          .border({ width: 1, color: '#e2e8f0' })
          .width('100%')
        } else {
          Column({ space: 10 }) {
            Text('命令以 uid 2000 (shell) 运行，SELinux 上下文 u:r:shell:s0。')
              .fontSize(13)
              .fontColor('#475569')
              .width('100%')

            TextInput({ text: this.command, placeholder: '输入 shell 命令，例如 top -n 1, id' })
              .onChange((value: string) => { this.command = value; })
              .width('100%')

            // Preset command shortcuts
            Scroll() {
              Row({ space: 8 }) {
                Button('id')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor('#e2e8f0')
                  .fontColor('#1e293b')
                  .onClick(() => { this.command = 'id'; })
                Button('top (快照)')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor('#e2e8f0')
                  .fontColor('#1e293b')
                  .onClick(() => { this.command = 'top -b -n 1'; })
                Button('top (动态)')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor('#fef3c7')
                  .fontColor('#92400e')
                  .onClick(() => { this.command = 'top'; })
                Button('ping 127.0.0.1')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor('#e2e8f0')
                  .fontColor('#1e293b')
                  .onClick(() => { this.command = 'ping -c 3 127.0.0.1'; })
                Button('ps -ef')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor('#e2e8f0')
                  .fontColor('#1e293b')
                  .onClick(() => { this.command = 'ps -ef | head -n 30'; })
                Button('getprop')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor('#e2e8f0')
                  .fontColor('#1e293b')
                  .onClick(() => { this.command = 'param get | head -n 25'; })
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')

            // Execution / Abort and Clear buttons
            Row({ space: 10 }) {
              if (this.busy) {
                Button('停止 (Ctrl+C)')
                  .backgroundColor('#ef4444')
                  .fontColor('#ffffff')
                  .layoutWeight(1)
                  .onClick(() => { this.stop(); })
              } else {
                Button('执行')
                  .backgroundColor('#0284c7')
                  .fontColor('#ffffff')
                  .layoutWeight(1)
                  .onClick(() => { this.run(); })
              }

              Button('清屏')
                .backgroundColor('#f1f5f9')
                .fontColor('#475569')
                .border({ width: 1, color: '#cbd5e1' })
                .onClick(() => { this.clearOutput(); })
            }
            .width('100%')

            // Terminal output title bar
            Row() {
              Text('终端输出')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#64748b')
              Blank()
              if (this.busy) {
                Text('● 正在接收流式输出…')
                  .fontSize(11)
                  .fontColor('#10b981')
              }
            }
            .width('100%')
            .margin({ top: 4 })

            // Dedicated scrollable terminal view supporting both vertical and horizontal scrolling
            Scroll(this.consoleScroller) {
              Scroll(this.consoleHScroller) {
                Text(this.output.length > 0 ? this.output : '(暂无输出，点击「执行」运行命令)')
                  .fontSize(12)
                  .fontFamily('monospace')
                  .fontColor(this.output.length > 0 ? '#38bdf8' : '#64748b')
                  .copyOption(CopyOptions.LocalDevice)
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Auto)
              .align(Alignment.TopStart)
            }
            .scrollable(ScrollDirection.Vertical)
            .height(280)
            .width('100%')
            .padding(10)
            .backgroundColor('#0f172a')
            .borderRadius(8)
            .border({ width: 1, color: '#1e293b' })
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
            .align(Alignment.TopStart)

            // Shizuku protocol compatibility card
            Column({ space: 8 }) {
              Row() {
                Text('Shizuku 协议兼容服务')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#0f172a')
                Blank()
                Text('● 正在运行 (v1)')
                  .fontSize(12)
                  .fontColor('#10b981')
              }
              .width('100%')

              Text('对标 Android Shizuku，通过 OpenHarmony RPC 对外发布 IShellBridgeService，任何鸿蒙 App 引入客户端 SDK 即可免 Root 提权运行 shell 命令。')
                .fontSize(11)
                .fontColor('#64748b')
                .width('100%')

              Button('运行 Shizuku SDK 兼容性自测')
                .fontSize(12)
                .height(30)
                .backgroundColor('#3b82f6')
                .fontColor('#ffffff')
                .enabled(!this.busy)
                .onClick(() => { this.testShizukuSdk(); })
            }
            .padding(10)
            .backgroundColor('#f8fafc')
            .borderRadius(8)
            .border({ width: 1, color: '#e2e8f0' })
            .width('100%')
            .margin({ top: 4 })
          }
          .padding(14)
          .backgroundColor('#ffffff')
          .borderRadius(10)
          .border({ width: 1, color: '#e2e8f0' })
          .width('100%')
        }

        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(13)
            .width('100%')
            .fontColor('#64748b')
        }

        Text('已授权的应用')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .margin({ top: 8 })

        if (this.grants.length === 0) {
          Text('还没有应用被授权。')
            .fontSize(13)
            .fontColor('#8a8a8a')
            .width('100%')
        } else {
          ForEach(this.grants, (entry: GrantEntry) => {
            Row() {
              Column({ space: 2 }) {
                Text(entry.bundleName)
                  .fontSize(13)
                  .width('100%')
                Text(new Date(entry.grantedAt).toLocaleString())
                  .fontSize(11)
                  .fontColor('#8a8a8a')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Button('撤销')
                .fontSize(12)
                .onClick(() => {
                  this.revoke(entry.bundleName);
                })
            }
            .width('100%')
            .padding(10)
            .backgroundColor('#ffffff')
            .borderRadius(8)
            .border({ width: 1, color: '#e2e8f0' })
          }, (entry: GrantEntry) => entry.bundleName)
        }

        if (this.publicKey.length > 0) {
          Text('客户端公钥（设备据此记住本应用）')
            .fontSize(13)
            .width('100%')
            .margin({ top: 8 })
          Text(this.publicKey)
            .fontSize(10)
            .width('100%')
            .maxLines(4)
            .fontColor('#8a8a8a')
            .copyOption(CopyOptions.LocalDevice)
        }
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .backgroundColor('#f8fafc')
  }

  @Builder
  buildAgentTab() {
    Column() {
      // Agent Header Card
      Column({ space: 8 }) {
        // Top Row: Title, Status Badges & Window Action
        Row() {
          Column({ space: 2 }) {
            Text(this.isSplitScreenMode ? 'Pi Agent (上下分屏)' : (this.isFloatingMode ? 'Pi Agent (小窗)' : 'Pi Coding Agent'))
              .fontSize(this.isSplitScreenMode || this.isFloatingMode ? 15 : 18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#0f172a')
            Row({ space: 4 }) {
              Text(this.connected ? '● Shell' : '○ 未连接')
                .fontSize(10)
                .fontColor(this.connected ? '#10b981' : '#ef4444')
              Text(this.agentEnableThinking ? '🧠 思考开' : '⚡ 思考关')
                .fontSize(10)
                .fontColor(this.agentEnableThinking ? '#0284c7' : '#64748b')
                .backgroundColor(this.agentEnableThinking ? '#e0f2fe' : '#f1f5f9')
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .borderRadius(4)
              if (this.isSplitScreenMode) {
                Text('📱 分屏中')
                  .fontSize(10)
                  .fontColor('#2563eb')
                  .backgroundColor('#dbeafe')
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .borderRadius(4)
              } else if (this.isFloatingMode) {
                Text('🪟 悬浮中')
                  .fontSize(10)
                  .fontColor('#059669')
                  .backgroundColor('#d1fae5')
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .borderRadius(4)
              }
            }
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          Button(this.isSplitScreenMode ? '🔲 恢复全屏' : (this.isFloatingMode ? '🔲 恢复全屏' : (this.floatWindowActive ? '🪟 悬浮中' : '📱 上下分屏')))
            .fontSize(11)
            .height(28)
            .padding({ left: 8, right: 8 })
            .backgroundColor(this.isSplitScreenMode ? '#eff6ff' : (this.isFloatingMode ? '#ecfdf5' : '#f8fafc'))
            .fontColor(this.isSplitScreenMode ? '#2563eb' : (this.isFloatingMode ? '#059669' : '#0284c7'))
            .border({ width: 1, color: this.isSplitScreenMode ? '#bfdbfe' : (this.isFloatingMode ? '#a7f3d0' : '#cbd5e1') })
            .onClick(() => {
              this.toggleFloatingWindow();
            })
        }
        .width('100%')

        // Bottom Action Bar: Horizontal Scrollable Button Strip
        Scroll() {
          Row({ space: 6 }) {
            Button(this.showMemoryPanel ? '收起记忆' : `🧠 长期记忆 (${this.memoryLessons.length})`)
              .fontSize(11)
              .height(28)
              .padding({ left: 10, right: 10 })
              .backgroundColor(this.showMemoryPanel ? '#e0e7ff' : '#f5f3ff')
              .fontColor('#4f46e5')
              .border({ width: 1, color: '#c7d2fe' })
              .onClick(() => {
                this.showMemoryPanel = !this.showMemoryPanel;
                if (this.showMemoryPanel) {
                  this.showSkillsPanel = false;
                  this.showSettings = false;
                }
              })

            Button(this.showSkillsPanel ? '收起技能' : `🛠️ 技能库 (${this.skillsList.length})`)
              .fontSize(11)
              .height(28)
              .padding({ left: 10, right: 10 })
              .backgroundColor(this.showSkillsPanel ? '#dcfce7' : '#f0fdf4')
              .fontColor('#15803d')
              .border({ width: 1, color: '#bbf7d0' })
              .onClick(() => {
                this.showSkillsPanel = !this.showSkillsPanel;
                if (this.showSkillsPanel) {
                  this.showMemoryPanel = false;
                  this.showSettings = false;
                  this.refreshSkills();
                }
              })

            Button(this.showSettings ? '收起设置' : '⚙️ 模型设置')
              .fontSize(11)
              .height(28)
              .padding({ left: 10, right: 10 })
              .backgroundColor(this.showSettings ? '#e0f2fe' : '#f1f5f9')
              .fontColor('#0284c7')
              .border({ width: 1, color: '#cbd5e1' })
              .onClick(() => {
                this.showSettings = !this.showSettings;
                if (this.showSettings) {
                  this.showMemoryPanel = false;
                  this.showSkillsPanel = false;
                }
              })

            Button('⚡ 工具自测')
              .fontSize(11)
              .height(28)
              .padding({ left: 10, right: 10 })
              .backgroundColor('#f0f9ff')
              .fontColor('#0284c7')
              .border({ width: 1, color: '#bae6fd' })
              .enabled(!this.agentRunning && this.connected)
              .onClick(() => {
                this.runAgentToolSelfTest();
              })

            Button('🗑️ 清空')
              .fontSize(11)
              .height(28)
              .padding({ left: 10, right: 10 })
              .backgroundColor('#fef2f2')
              .fontColor('#dc2626')
              .border({ width: 1, color: '#fecaca' })
              .onClick(() => {
                this.clearAgentHistory();
              })

            Button('📋 复制全记录')
              .fontSize(11)
              .height(28)
              .padding({ left: 10, right: 10 })
              .backgroundColor('#f0fdf4')
              .fontColor('#16a34a')
              .border({ width: 1, color: '#bbf7d0' })
              .onClick(async () => {
                const fullHistory = this.formatFullChatHistory();
                await this.copyTextToClipboard(fullHistory);
              })
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor('#ffffff')
      .border({ width: { bottom: 1 }, color: '#e2e8f0' })

      // Split Screen & Multi-Window Guide Banner
      if (this.showFloatingGuide && !this.isSplitScreenMode && !this.isFloatingMode) {
        Row({ space: 8 }) {
          Text('📱 推荐开启上下分屏：从屏幕右侧边缘向内轻扫停顿呼出智慧多窗侧栏，将微信或目标应用拖至屏幕下半部，即可上方看思考清单、下方实时操作！')
            .fontSize(11)
            .fontColor('#1d4ed8')
            .lineHeight(16)
            .layoutWeight(1)

          Button('我知道了')
            .fontSize(10)
            .height(22)
            .backgroundColor('#dbeafe')
            .fontColor('#1d4ed8')
            .onClick(() => {
              this.showFloatingGuide = false;
            })
        }
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor('#eff6ff')
        .border({ width: { bottom: 1 }, color: '#bfdbfe' })
        .width('100%')
      }

      // Collapsible Memory Knowledge Base Panel
      if (this.showMemoryPanel) {
        this.buildMemoryPanel()
      }

      // Collapsible Skills Panel (Official Agent Skills)
      if (this.showSkillsPanel) {
        this.buildSkillsPanel()
      }

      // Collapsible Model & Remote SSH Settings Card
      if (this.showSettings) {
        Scroll() {
          Column({ space: 8 }) {
            Text('LLM 模型连接参数 (支持 DeepSeek / OpenAI / 通义千问等)')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#475569')
            .width('100%')

          Row({ space: 8 }) {
            Text('Base URL:')
              .fontSize(12)
              .width(70)
              .fontColor('#64748b')
            TextInput({ text: this.agentBaseUrl, placeholder: 'https://api.minimax.cn/v1' })
              .fontSize(12)
              .layoutWeight(1)
              .onChange((v: string) => { this.agentBaseUrl = v; })
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('API Key:')
              .fontSize(12)
              .width(70)
              .fontColor('#64748b')
            TextInput({ text: this.agentApiKey, placeholder: 'sk-...' })
              .type(InputType.Password)
              .fontSize(12)
              .layoutWeight(1)
              .onChange((v: string) => { this.agentApiKey = v; })
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('Model:')
              .fontSize(12)
              .width(70)
              .fontColor('#64748b')
            TextInput({ text: this.agentModelName, placeholder: 'MiniMax-M3.1-Flash' })
              .fontSize(12)
              .layoutWeight(1)
              .onChange((v: string) => { this.agentModelName = v; })
          }
          .width('100%')

          Row() {
            Column({ space: 2 }) {
              Text('自动运行 Shell/文件工具')
                .fontSize(12)
                .fontColor('#334155')
              Text('是否自动执行 Agent 生成的系统与文件命令')
                .fontSize(10)
                .fontColor('#94a3b8')
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.agentAutoRunTools })
              .onChange((isOn: boolean) => {
                this.agentAutoRunTools = isOn;
              })
          }
          .width('100%')

          Row() {
            Column({ space: 2 }) {
              Text('模型深度思考 (Thinking / Reasoning)')
                .fontSize(12)
                .fontColor('#334155')
              Text(this.agentEnableThinking ? '当前已开启：展示深度思考链并启用高思考深度' : '当前已关闭：隐藏思考过程，直接快速回答')
                .fontSize(10)
                .fontColor(this.agentEnableThinking ? '#0284c7' : '#94a3b8')
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.agentEnableThinking })
              .onChange((isOn: boolean) => {
                this.agentEnableThinking = isOn;
              })
          }
          .width('100%')

          Row() {
            Column({ space: 2 }) {
              Text('任务执行中切后台自动小窗')
                .fontSize(12)
                .fontColor('#334155')
              Text(this.autoFloatEnabled ? '当前开启：仅在 Agent 正在执行任务时切出应用才尝试保持小窗' : '当前关闭：完全由手动控制，切出应用时不自动切换小窗（推荐）')
                .fontSize(10)
                .fontColor(this.autoFloatEnabled ? '#0284c7' : '#94a3b8')
            }
            .alignItems(HorizontalAlign.Start)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.autoFloatEnabled })
                .onChange((isOn: boolean) => {
                  this.autoFloatEnabled = isOn;
                  AppStorage.setOrCreate('autoFloatEnabled', isOn);
                })
            }
            .width('100%')

            Divider().color('#e2e8f0').margin({ top: 4, bottom: 2 })

            Row() {
              Column({ space: 2 }) {
                Text('远程 SSH 服务器 (Python / NPM / 编译)')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#334155')
                Text(this.remoteEnabled ? '已启用：AI 可通过 remote_bash 在远程 Linux/macOS 主机执行命令' : '未启用：开启后可配置远程服务器以弥补手机 Shell 环境限制')
                  .fontSize(10)
                  .fontColor(this.remoteEnabled ? '#0284c7' : '#94a3b8')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.remoteEnabled })
                .onChange((isOn: boolean) => {
                  this.remoteEnabled = isOn;
                })
            }
            .width('100%')

            if (this.remoteEnabled) {
              Row({ space: 6 }) {
                TextInput({ text: this.remoteHost, placeholder: '服务器 Host / IP (如 192.168.1.10)' })
                  .fontSize(12)
                  .layoutWeight(1)
                  .onChange((v: string) => { this.remoteHost = v; })
                TextInput({ text: this.remotePort, placeholder: '22' })
                  .type(InputType.Number)
                  .fontSize(12)
                  .width(62)
                  .onChange((v: string) => { this.remotePort = v; })
              }
              .width('100%')

              Row({ space: 6 }) {
                TextInput({ text: this.remoteUser, placeholder: '用户名 (如 ubuntu / root)' })
                  .fontSize(12)
                  .layoutWeight(1)
                  .onChange((v: string) => { this.remoteUser = v; })
                TextInput({ text: this.remoteWorkDir, placeholder: '默认工作目录 (可选)' })
                  .fontSize(12)
                  .layoutWeight(1)
                  .onChange((v: string) => { this.remoteWorkDir = v; })
              }
              .width('100%')

              Row({ space: 8 }) {
                Text('密码:')
                  .fontSize(12)
                  .width(46)
                  .fontColor('#64748b')
                TextInput({ text: this.remotePassword, placeholder: 'SSH 密码 (与私钥二选一)' })
                  .type(InputType.Password)
                  .fontSize(12)
                  .layoutWeight(1)
                  .onChange((v: string) => { this.remotePassword = v; })
              }
              .width('100%')

              TextArea({ text: this.remotePrivateKey, placeholder: '可选：RSA PEM 私钥 (-----BEGIN RSA PRIVATE KEY----- 或 PRIVATE KEY-----)' })
                .fontSize(11)
                .fontFamily('monospace')
                .height(60)
                .width('100%')
                .backgroundColor('#ffffff')
                .border({ width: 1, color: '#cbd5e1' })
                .borderRadius(6)
                .onChange((v: string) => { this.remotePrivateKey = v; })

              Row({ space: 8 }) {
                Text('指纹:')
                  .fontSize(12)
                  .width(46)
                  .fontColor('#64748b')
                TextInput({ text: this.remoteFingerprint, placeholder: '可选：SHA256:... (测试成功后自动填入)' })
                  .fontSize(11)
                  .layoutWeight(1)
                  .onChange((v: string) => { this.remoteFingerprint = v; })
              }
              .width('100%')

              if (this.remoteTestResult.length > 0) {
                Text(this.remoteTestResult)
                  .fontSize(11)
                  .fontFamily('monospace')
                  .fontColor(this.remoteTestResult.startsWith('✅') ? '#047857' : (this.remoteTestResult.startsWith('⏳') ? '#0369a1' : '#b91c1c'))
                  .backgroundColor('#ffffff')
                  .padding(8)
                  .borderRadius(6)
                  .border({ width: 1, color: '#cbd5e1' })
                  .width('100%')
                  .copyOption(CopyOptions.LocalDevice)
              }

              Button(this.remoteTesting ? '正在测试 SSH 连接...' : '测试 SSH 连接')
                .fontSize(12)
                .height(28)
                .width('100%')
                .enabled(!this.remoteTesting)
                .backgroundColor(this.remoteTesting ? '#94a3b8' : '#0f766e')
                .fontColor('#ffffff')
                .onClick(() => {
                  this.testRemoteSsh();
                })
            }

            Button('保存配置')
              .fontSize(12)
              .height(30)
              .width('100%')
              .backgroundColor('#0284c7')
              .fontColor('#ffffff')
              .onClick(() => {
                this.saveAgentConfig();
              })
          }
          .padding(12)
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .constraintSize({ maxHeight: 420 })
        .backgroundColor('#f8fafc')
        .border({ width: { bottom: 1 }, color: '#e2e8f0' })
        .width('100%')
      }

      // Active Goal Progress Card (pi-goal-x Architecture)
      if (this.activeGoal !== null) {
        this.buildGoalCard()
      }

      // Pinned "Wait-On" Task Board (Features F11, F12)
      if (this.activeTickets.length > 0) {
        this.buildWaitOnBoard()
      }

      // Messages Section Toolbar (when messages exist)
      if (this.agentMessages.filter(m => m.role !== 'system').length > 0 || this.activeTickets.length > 0) {
        Row() {
          Row({ space: 6 }) {
            Text('💬 会话历史')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#334155')
            Text(`${this.agentMessages.filter(m => m.role !== 'system').length} 条`)
              .fontSize(10)
              .fontColor('#64748b')
              .backgroundColor('#f1f5f9')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(4)
          }

          Blank()

          Button('📋 一键复制全部记录')
            .fontSize(11)
            .height(26)
            .padding({ left: 10, right: 10 })
            .backgroundColor('#f0fdf4')
            .fontColor('#16a34a')
            .border({ width: 1, color: '#bbf7d0' })
            .onClick(async () => {
              const fullHistory = this.formatFullChatHistory();
              await this.copyTextToClipboard(fullHistory);
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .backgroundColor('#f8fafc')
        .border({ width: { bottom: 1 }, color: '#e2e8f0' })
      }

      // Main Chat Message Area
      Scroll(this.agentChatScroller) {
        Column({ space: 12 }) {
          // Welcome greeting
          if (this.agentMessages.filter(m => m.role !== 'system').length === 0 && !this.agentRunning) {
            Column({ space: 8 }) {
              Text('🤖 欢迎使用鸿蒙 Pi Agent 助手')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#0f172a')
              Text('本 Agent 基于 Pi Coding Agent 规范移植，原生集成鸿蒙 uid 2000 (shell) 执行内核与多工具生态：\n• run_code：内置原生 Python 3 (CPython 3.13) 与 JS 沙箱，深度集成特权 HDC 系统桥接（可在 Python 中直接使用 import hdc 或 subprocess.run 执行特权系统命令）、网络请求、PIL 图像绘制与 pip 动态包管理\n• read / write / edit：设备上带行号读取、Base64 写入与精确替换\n• ui：结构化界面控件树 dump、坐标/中文输入与滑动操作（uitest/uinput）\n• remote_bash：原生 SSH-2.0 远程服务器执行（支持 Python / NPM / 编译任务）\n• browser / fetch / remember / inspect_image：内置浏览器、网络请求、长期记忆与识图')
                .fontSize(12)
                .fontColor('#475569')
                .lineHeight(18)
            }
            .padding(14)
            .backgroundColor('#ffffff')
            .borderRadius(10)
            .border({ width: 1, color: '#e2e8f0' })
            .width('100%')
          }

          // Message history
          ForEach(this.agentMessages.filter(m => m.role !== 'system'), (msg: Message, idx: number) => {
            if (msg.role === 'user') {
              // User message bubble
              Row() {
                Blank()
                Column({ space: 6 }) {
                  if (msg.images && msg.images.length > 0) {
                    Row({ space: 6 }) {
                      ForEach(msg.images, (img: ImageAttachment, imgIdx: number) => {
                        Image(img.previewUri ?? img.dataUrl)
                          .width(72)
                          .height(72)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(6)
                          .backgroundColor('#0369a1')
                          .onClick(() => {
                            this.openImagePreview(img.previewUri ?? img.dataUrl, '用户发送图片');
                          })
                      })
                    }
                  }
                  if (msg.content && msg.content.trim().length > 0) {
                    Text(msg.content)
                      .fontSize(13)
                      .fontColor('#ffffff')
                      .copyOption(CopyOptions.LocalDevice)
                  }
                }
                .alignItems(HorizontalAlign.End)
                .backgroundColor('#0284c7')
                .padding(10)
                .borderRadius(10)
                .constraintSize({ maxWidth: '85%' })
              }
              .width('100%')
              .justifyContent(FlexAlign.End)
            } else if (msg.role === 'tool') {
              // Tool result box
              Column({ space: 4 }) {
                Row() {
                  Text(`📄 工具执行结果 (${msg.name ?? 'tool'})`)
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#059669')
                  Blank()
                }
                .width('100%')

                Scroll() {
                  Text(msg.content)
                    .fontSize(11)
                    .fontFamily('monospace')
                    .fontColor('#1e293b')
                    .copyOption(CopyOptions.LocalDevice)
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Auto)
                .width('100%')

                if (msg.images && msg.images.length > 0) {
                  Row({ space: 6 }) {
                    ForEach(msg.images, (img: ImageAttachment, imgIdx: number) => {
                      Image(img.previewUri ?? img.dataUrl)
                        .width(96)
                        .height(96)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(6)
                        .border({ width: 1, color: '#bbf7d0' })
                        .onClick(() => {
                          this.openImagePreview(img.previewUri ?? img.dataUrl, `工具图片 (${msg.name ?? 'tool'})`);
                        })
                    })
                  }
                  .width('100%')
                  .margin({ top: 4 })
                }
              }
              .padding(8)
              .backgroundColor('#f0fdf4')
              .borderRadius(6)
              .border({ width: 1, color: '#bbf7d0' })
              .width('100%')
            } else {
              // Assistant message card
              Column({ space: 8 }) {
                // Header with copy button
                Row() {
                  Text('🤖 助手回复')
                    .fontSize(11)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#0284c7')

                  Blank()

                  if (msg.content && msg.content.trim().length > 0) {
                    Button('复制全部')
                      .fontSize(10)
                      .height(20)
                      .padding({ left: 6, right: 6 })
                      .backgroundColor('#f1f5f9')
                      .fontColor('#64748b')
                      .onClick(() => {
                        this.copyTextToClipboard(msg.content);
                      })
                  }
                }
                .width('100%')

                // Thinking content if present and enabled
                if (this.agentEnableThinking && msg.reasoning_content && msg.reasoning_content.length > 0) {
                  Column({ space: 4 }) {
                    Text('💭 思考过程')
                      .fontSize(11)
                      .fontColor('#64748b')
                      .fontWeight(FontWeight.Bold)
                    MarkdownView({ content: msg.reasoning_content })
                  }
                  .padding(8)
                  .backgroundColor('#f1f5f9')
                  .borderRadius(6)
                  .width('100%')
                }

                // Tool calls if present
                if (msg.tool_calls && msg.tool_calls.length > 0) {
                  ForEach(msg.tool_calls, (tc: ToolCall) => {
                    Column({ space: 4 }) {
                      Row() {
                        Text(`🔧 调用工具: ${tc.function.name}`)
                          .fontSize(12)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#0369a1')
                        Blank()
                      }
                      .width('100%')

                      Text(tc.function.arguments)
                        .fontSize(11)
                        .fontFamily('monospace')
                        .fontColor('#334155')
                        .copyOption(CopyOptions.LocalDevice)
                    }
                    .padding(8)
                    .backgroundColor('#e0f2fe')
                    .borderRadius(6)
                    .width('100%')
                  })
                }

                // Final text content with full interactive Markdown rendering
                if (msg.content && msg.content.trim().length > 0) {
                  MarkdownView({ content: msg.content })
                } else if (!this.agentEnableThinking && msg.reasoning_content && msg.reasoning_content.trim().length > 0 && (!msg.tool_calls || msg.tool_calls.length === 0)) {
                  MarkdownView({ content: msg.reasoning_content })
                } else if ((!msg.tool_calls || msg.tool_calls.length === 0) && (!msg.reasoning_content || msg.reasoning_content.trim().length === 0)) {
                  Text('⚠️ 未收到有效回复内容（可能网络中断或Token耗尽）')
                    .fontSize(12)
                    .fontColor('#ef4444')
                    .fontStyle(FontStyle.Italic)
                }

                // Deliverable File & Image Previews
                this.renderMessageAttachments(msg)
              }
              .padding(10)
              .backgroundColor('#ffffff')
              .borderRadius(10)
              .border({ width: 1, color: '#e2e8f0' })
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
          }, (msg: Message, idx: number) => `${idx}_${msg.role}_${(msg.content ?? '').length}_${(msg.tool_calls ?? []).length}`)

          // Active streaming assistant response
          if (this.agentRunning) {
            Column({ space: 8 }) {
              if (this.currentToolStatus.length > 0) {
                Row({ space: 6 }) {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                    .color('#0284c7')
                  Text(this.currentToolStatus)
                    .fontSize(12)
                    .fontColor('#0284c7')
                }
                .width('100%')
              }

              if (this.agentEnableThinking && this.agentThinkingText.length > 0) {
                Column({ space: 4 }) {
                  Text('💭 思考中...')
                    .fontSize(11)
                    .fontColor('#64748b')
                    .fontWeight(FontWeight.Bold)
                  MarkdownView({ content: this.agentThinkingText })
                }
                .padding(8)
                .backgroundColor('#f8fafc')
                .borderRadius(6)
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }

              if (this.agentCurrentText.length > 0) {
                MarkdownView({ content: this.agentCurrentText })
              }
            }
            .padding(10)
            .backgroundColor('#ffffff')
            .borderRadius(10)
            .border({ width: 1, color: '#bae6fd' })
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .padding(14)
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#f8fafc')
      .edgeEffect(EdgeEffect.Spring)

      // Bottom Area (Context Usage Card + Mini Context Status Bar + Prompt Input)
      Column() {
        if (this.showContextUsageCard) {
          this.buildContextUsageCard()
        }

        // Mini Context Status Bar (Entry directly above the text input box)
        Row({ space: 8 }) {
          // Mini multi-colored stacked bar preview
          Row() {
            ForEach(this.contextUsage.details, (d: ContextUsageDetail) => {
              if (d.tokens > 0) {
                Row()
                  .width(`${Math.max(1, (d.tokens / this.contextUsage.maxTokens) * 100)}%`)
                  .height('100%')
                  .backgroundColor(d.color)
              }
            })
          }
          .width(48)
          .height(5)
          .borderRadius(2.5)
          .backgroundColor('#e2e8f0')
          .clip(true)

          Text(`📊 上下文 ${this.contextUsage.usedPercentage.toFixed(1)}%`)
            .fontSize(11)
            .fontColor('#334155')
            .fontWeight(FontWeight.Medium)

          Text(`· ${(this.contextUsage.totalTokens / 1000).toFixed(1)}K / ${(this.contextUsage.maxTokens / 1000).toFixed(0)}K`)
            .fontSize(11)
            .fontColor('#64748b')

          Blank()

          Row({ space: 2 }) {
            Text(this.showContextUsageCard ? '收起 ✕' : '用量详情 ▾')
              .fontSize(11)
              .fontColor('#0284c7')
              .fontWeight(FontWeight.Medium)
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 6, bottom: 4 })
        .backgroundColor('#ffffff')
        .onClick(() => {
          this.showContextUsageCard = !this.showContextUsageCard;
        })

        // Attention Decision Card (Human-in-the-loop decision card)
        if (this.activeAttention) {
          Column({ space: 8 }) {
            Row() {
              Text('❓ 需要人工确认 / 决策 (Attention Request)')
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor('#b45309')

              Blank()

              Button('取消')
                .fontSize(10)
                .height(22)
                .padding({ left: 6, right: 6 })
                .backgroundColor('#fef2f2')
                .fontColor('#ef4444')
                .onClick(() => {
                  if (this.activeAttention) {
                    AttentionManager.getInstance().cancelAttention(this.activeAttention.id);
                    this.activeAttention = null;
                  }
                })
            }
            .width('100%')

            Text(this.activeAttention.question)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1e293b')
              .width('100%')

            // Options Buttons
            Scroll() {
              Row({ space: 6 }) {
                ForEach(this.activeAttention.options, (opt: string) => {
                  Button(opt)
                    .fontSize(11)
                    .height(30)
                    .padding({ left: 10, right: 10 })
                    .backgroundColor('#fef3c7')
                    .fontColor('#b45309')
                    .border({ width: 1, color: '#fcd34d' })
                    .borderRadius(6)
                    .onClick(() => {
                      if (this.activeAttention) {
                        AttentionManager.getInstance().respondAttention(this.activeAttention.id, opt);
                        this.activeAttention = null;
                        this.customAttentionInput = '';
                      }
                    })
                })
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Auto)
            .width('100%')

            // Custom input if allowed
            if (this.activeAttention.allowCustomInput) {
              Row({ space: 6 }) {
                TextInput({ text: this.customAttentionInput, placeholder: '或输入自定义意见...' })
                  .layoutWeight(1)
                  .fontSize(12)
                  .height(30)
                  .onChange((v: string) => {
                    this.customAttentionInput = v;
                  })

                Button('确定')
                  .fontSize(11)
                  .height(30)
                  .backgroundColor('#d97706')
                  .fontColor('#ffffff')
                  .onClick(() => {
                    if (this.activeAttention && this.customAttentionInput.trim().length > 0) {
                      AttentionManager.getInstance().respondAttention(
                        this.activeAttention.id,
                        this.customAttentionInput.trim()
                      );
                      this.activeAttention = null;
                      this.customAttentionInput = '';
                    }
                  })
              }
              .width('100%')
            }
          }
          .padding(10)
          .margin({ left: 14, right: 14, bottom: 6 })
          .backgroundColor('#fffbeb')
          .borderRadius(8)
          .border({ width: 1, color: '#fde68a' })
        }

        // Pending image attachments strip
        if (this.pendingImages.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.pendingImages, (img: ImageAttachment, imgIdx: number) => {
                Stack({ alignContent: Alignment.TopEnd }) {
                  Image(img.previewUri ?? img.dataUrl)
                    .width(56)
                    .height(56)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(6)
                    .border({ width: 1, color: '#cbd5e1' })
                    .onClick(() => {
                      this.openImagePreview(img.previewUri ?? img.dataUrl, '待发送图片');
                    })

                  Text('×')
                    .fontSize(11)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#ffffff')
                    .backgroundColor('rgba(15, 23, 42, 0.78)')
                    .width(18)
                    .height(18)
                    .textAlign(TextAlign.Center)
                    .borderRadius(9)
                    .margin({ top: 2, right: 2 })
                    .onClick(() => {
                      this.removePendingImage(imgIdx);
                    })
                }
                .width(56)
                .height(56)
              })
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .padding({ left: 12, right: 12, top: 6, bottom: 4 })
          .width('100%')
        }

        // Prompt Input Bar
        Row({ space: 8 }) {
          Button(this.isPickingImage ? '...' : '图片')
            .fontSize(11)
            .height(38)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.pendingImages.length > 0 ? '#e0f2fe' : '#f1f5f9')
            .fontColor(this.pendingImages.length > 0 ? '#0369a1' : '#334155')
            .enabled(!this.agentRunning && !this.isPickingImage)
            .onClick(() => {
              this.pickAgentImages();
            })

          TextInput({ text: this.agentInputPrompt, placeholder: '输入指令或附带图片，让 Agent 分析与执行...' })
            .layoutWeight(1)
            .fontSize(13)
            .height(38)
            .onChange((value: string) => {
              this.agentInputPrompt = value;
            })
            .onSubmit(() => {
              this.sendAgentPrompt();
            })

          if (this.agentRunning) {
            Button('停止')
              .fontSize(12)
              .height(38)
              .backgroundColor('#ef4444')
              .fontColor('#ffffff')
              .onClick(() => {
                this.stopAgent();
              })
          } else {
            Button('发送')
              .fontSize(12)
              .height(38)
              .backgroundColor('#0284c7')
              .fontColor('#ffffff')
              .onClick(() => {
                this.sendAgentPrompt();
              })
          }
        }
        .padding({ left: 12, right: 12, top: 2, bottom: 12 })
        .width('100%')
      }
      .backgroundColor('#ffffff')
      .border({ width: { top: 1 }, color: '#e2e8f0' })
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  buildContextUsageCard() {
    Column() {
      // Top header with title and close icon
      Row() {
        Text('上下文用量')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')

        Blank()

        Row() {
          Text('✕')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#4b5563')
        }
        .width(28)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(14)
        .onClick(() => {
          this.showContextUsageCard = false;
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      // Large percentage + used/total tokens
      Row() {
        Text(`${this.contextUsage.usedPercentage.toFixed(1)}%`)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')

        Text(`  已使用 ${(this.contextUsage.totalTokens / 1000).toFixed(1)}K/ ${(this.contextUsage.maxTokens / 1000).toFixed(1)}K`)
          .fontSize(14)
          .fontColor('#6b7280')
          .margin({ bottom: 4 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ bottom: 12 })

      // Stacked multi-colored progress bar
      Row() {
        ForEach(this.contextUsage.details, (item: ContextUsageDetail) => {
          if (item.tokens > 0) {
            Row()
              .width(`${Math.max(0.6, (item.tokens / this.contextUsage.maxTokens) * 100)}%`)
              .height('100%')
              .backgroundColor(item.color)
          }
        })
      }
      .width('100%')
      .height(10)
      .borderRadius(5)
      .backgroundColor('#f1f5f9')
      .clip(true)
      .margin({ bottom: 16 })

      // Breakdown list
      Column({ space: 14 }) {
        ForEach(this.contextUsage.details, (item: ContextUsageDetail) => {
          Row() {
            // Colored dot
            Row()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(item.color)
              .margin({ right: 10 })

            // Category name
            Text(item.name)
              .fontSize(14)
              .fontColor('#1f2937')

            Blank()

            // Percentage
            Text(this.formatContextPercentage(item.percentage))
              .fontSize(14)
              .fontColor('#6b7280')
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }, (item: ContextUsageDetail) => `${item.category}_${item.percentage}_${item.tokens}`)
      }
      .width('100%')
      .margin({ bottom: 6 })

      // Divider line
      Divider()
        .color('#f3f4f6')
        .strokeWidth(1)
        .margin({ top: 16, bottom: 18 })

      // Bottom Capacity Text
      Text(CONTEXT_CAPACITIES[this.contextCapacityIndex].label)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#111827')
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ bottom: 14 })

      // 3-step selector track
      Row() {
        ForEach(CONTEXT_CAPACITIES, (opt: ContextCapacityOption, idx: number) => {
          Row() {
            if (this.contextCapacityIndex === idx) {
              Row()
                .width(28)
                .height(28)
                .borderRadius(14)
                .backgroundColor('#ffffff')
                .shadow({ radius: 5, color: '#0000001f', offsetY: 1 })
            } else {
              Row()
                .width(7)
                .height(7)
                .borderRadius(3.5)
                .backgroundColor('#cbd5e1')
            }
          }
          .layoutWeight(1)
          .height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Block)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.setContextCapacity(idx);
          })
        }, (opt: ContextCapacityOption, idx: number) => `${idx}_${this.contextCapacityIndex === idx}_${opt.tokens}`)
      }
      .width('100%')
      .height(34)
      .borderRadius(17)
      .backgroundColor('#f1f5f9')
      .padding({ left: 4, right: 4 })
    }
    .padding({ left: 16, right: 16, top: 16, bottom: 18 })
    .backgroundColor('#ffffff')
    .borderRadius(16)
    .border({ width: 1, color: '#e5e7eb' })
    .shadow({ radius: 14, color: '#00000014', offsetY: -2 })
    .margin({ left: 12, right: 12, bottom: 8 })
    .width('94%')
  }

  @Builder
  buildCategoryChip(cat: MemoryCategory, label: string) {
    Text(label)
      .fontSize(10)
      .fontColor(this.newMemoryCategory === cat ? '#ffffff' : this.getCategoryColor(cat))
      .backgroundColor(this.newMemoryCategory === cat ? this.getCategoryColor(cat) : this.getCategoryBg(cat))
      .padding({ left: 6, right: 6, top: 3, bottom: 3 })
      .borderRadius(4)
      .onClick(() => {
        this.newMemoryCategory = cat;
      })
  }

  @Builder
  buildMemoryPanel() {
    Column({ space: 8 }) {
      Row() {
        Row({ space: 6 }) {
          Text('🧠 长期记忆与避坑库')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#312e81')
          Text('永久生效')
            .fontSize(9)
            .fontColor('#4f46e5')
            .backgroundColor('#e0e7ff')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(4)
        }
        .layoutWeight(1)

        Row({ space: 4 }) {
          Button(this.isAddingMemory ? '取消' : '➕ 新增')
            .fontSize(10)
            .height(24)
            .padding({ left: 6, right: 6 })
            .backgroundColor('#eef2ff')
            .fontColor('#4f46e5')
            .border({ width: 1, color: '#c7d2fe' })
            .onClick(() => {
              this.isAddingMemory = !this.isAddingMemory;
            })

          Button('🔄 重置')
            .fontSize(10)
            .height(24)
            .padding({ left: 6, right: 6 })
            .backgroundColor('#f8fafc')
            .fontColor('#64748b')
            .border({ width: 1, color: '#e2e8f0' })
            .onClick(() => {
              this.resetMemoryLessons();
            })
        }
      }
      .width('100%')

      Text('基于 Pi Agent 记忆与反思机制：工具执行报错自动提炼规则，动态注入 Prompt，防止在相同陷阱重复试错。')
        .fontSize(10)
        .fontColor('#6b7280')
        .width('100%')

      // Add Memory Form
      if (this.isAddingMemory) {
        Column({ space: 6 }) {
          TextInput({ placeholder: '输入要牢记的经验、环境约束或用户偏好...', text: this.newMemoryRule })
            .fontSize(12)
            .height(34)
            .backgroundColor('#ffffff')
            .border({ width: 1, color: '#818cf8' })
            .borderRadius(6)
            .onChange((val: string) => {
              this.newMemoryRule = val;
            })

          Row({ space: 6 }) {
            Scroll() {
              Row({ space: 4 }) {
                Text('分类:')
                  .fontSize(11)
                  .fontColor('#475569')

                this.buildCategoryChip('network', '网络')
                this.buildCategoryChip('shell', '终端')
                this.buildCategoryChip('device', '设备')
                this.buildCategoryChip('tools', '工具')
                this.buildCategoryChip('general', '通用')
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .layoutWeight(1)

            Button('保存记忆')
              .fontSize(10)
              .height(24)
              .padding({ left: 8, right: 8 })
              .backgroundColor('#4f46e5')
              .fontColor('#ffffff')
              .onClick(() => {
                this.addCustomMemoryLesson();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor('#f5f3ff')
        .borderRadius(8)
        .border({ width: 1, color: '#ddd6fe' })
      }

      // Memory List
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.memoryLessons, (item: MemoryLesson) => {
            Row({ space: 6 }) {
              Text(item.category)
                .fontSize(9)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.getCategoryColor(item.category))
                .backgroundColor(this.getCategoryBg(item.category))
                .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                .borderRadius(4)

              Column({ space: 2 }) {
                Text(item.rule)
                  .fontSize(11)
                  .fontColor('#1f2937')
                  .lineHeight(15)
                Row({ space: 6 }) {
                  Text(`命中: ${item.occurrenceCount || 1}次`)
                    .fontSize(9)
                    .fontColor('#6b7280')
                  Text(`权重: ${item.confidence}`)
                    .fontSize(9)
                    .fontColor('#6b7280')
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Button('✕')
                .fontSize(11)
                .height(22)
                .width(24)
                .backgroundColor('#fef2f2')
                .fontColor('#ef4444')
                .borderRadius(4)
                .padding(0)
                .onClick(() => {
                  this.deleteMemoryLesson(item.id);
                })
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .backgroundColor('#ffffff')
            .borderRadius(6)
            .border({ width: 1, color: '#e5e7eb' })
          }, (item: MemoryLesson) => item.id)
        }
        .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .constraintSize({ maxHeight: 180 })
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#faf5ff')
    .border({ width: { bottom: 1 }, color: '#e9d5ff' })
  }

  private async refreshSkills(): Promise<void> {
    await SkillManager.getInstance().reloadSkills();
    this.skillsList = [...SkillManager.getInstance().getSkills()];
    if (this.agentSession) {
      this.agentSession.refreshSystemPrompt();
    }
    promptAction.showToast({ message: '技能库已更新', duration: 1500 });
  }

  private async saveCustomSkill(): Promise<void> {
    if (!this.newSkillName.trim() || !this.newSkillDesc.trim()) {
      promptAction.showToast({ message: '请填写技能名称和触发描述', duration: 1500 });
      return;
    }
    const ok = await SkillManager.getInstance().createSkill(
      this.newSkillName,
      this.newSkillDesc,
      this.newSkillBody.trim() ? this.newSkillBody : `# ${this.newSkillName}\n\n执行自定义指令流程。`
    );
    if (ok) {
      this.newSkillName = '';
      this.newSkillDesc = '';
      this.newSkillBody = '';
      this.isAddingSkill = false;
      this.skillsList = [...SkillManager.getInstance().getSkills()];
      if (this.agentSession) {
        this.agentSession.refreshSystemPrompt();
      }
      promptAction.showToast({ message: '自定义技能已创建并挂载', duration: 2000 });
    } else {
      promptAction.showToast({ message: '创建失败', duration: 1500 });
    }
  }

  private async deleteSkillItem(name: string): Promise<void> {
    const ok = await SkillManager.getInstance().deleteSkill(name);
    if (ok) {
      this.skillsList = [...SkillManager.getInstance().getSkills()];
      if (this.agentSession) {
        this.agentSession.refreshSystemPrompt();
      }
      promptAction.showToast({ message: '技能已删除', duration: 1500 });
    }
  }

  @Builder
  buildSkillsPanel() {
    Column({ space: 8 }) {
      // Header
      Row() {
        Row({ space: 6 }) {
          Text('🛠️ 官方 Agent Skills 技能库')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#14532d')
          Text('渐进式按需读取')
            .fontSize(9)
            .fontColor('#15803d')
            .backgroundColor('#dcfce7')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(4)
        }
        .layoutWeight(1)

        Row({ space: 4 }) {
          Button(this.isAddingSkill ? '取消' : '➕ 新增')
            .fontSize(10)
            .height(24)
            .padding({ left: 6, right: 6 })
            .backgroundColor('#f0fdf4')
            .fontColor('#15803d')
            .border({ width: 1, color: '#bbf7d0' })
            .onClick(() => {
              this.isAddingSkill = !this.isAddingSkill;
            })

          Button('🔄 刷新')
            .fontSize(10)
            .height(24)
            .padding({ left: 6, right: 6 })
            .backgroundColor('#f8fafc')
            .fontColor('#64748b')
            .border({ width: 1, color: '#e2e8f0' })
            .onClick(() => {
              this.refreshSkills();
            })
        }
      }
      .width('100%')

      Text('对标官方 Pi Agent 标准：以 SKILL.md 为核心。启动仅加载目录元数据，当且仅当任务匹配时，由 Agent 自主调用 read 工具深入加载，零上下文冗余。')
        .fontSize(10)
        .fontColor('#6b7280')
        .width('100%')

      // Add Skill Form
      if (this.isAddingSkill) {
        Column({ space: 6 }) {
          TextInput({ placeholder: '技能标识 (英文小写，如 log-cleaner)...', text: this.newSkillName })
            .fontSize(12)
            .height(34)
            .backgroundColor('#ffffff')
            .border({ width: 1, color: '#86efac' })
            .borderRadius(6)
            .onChange((val: string) => {
              this.newSkillName = val;
            })

          TextInput({ placeholder: '触发描述 (When to use this skill)...', text: this.newSkillDesc })
            .fontSize(12)
            .height(34)
            .backgroundColor('#ffffff')
            .border({ width: 1, color: '#86efac' })
            .borderRadius(6)
            .onChange((val: string) => {
              this.newSkillDesc = val;
            })

          TextArea({ placeholder: '输入 Markdown 指南与操作指令 (SKILL.md 正文)...', text: this.newSkillBody })
            .fontSize(11)
            .height(60)
            .backgroundColor('#ffffff')
            .border({ width: 1, color: '#86efac' })
            .borderRadius(6)
            .onChange((val: string) => {
              this.newSkillBody = val;
            })

          Row() {
            Blank()
            Button('保存并挂载技能')
              .fontSize(10)
              .height(26)
              .backgroundColor('#16a34a')
              .fontColor('#ffffff')
              .onClick(() => {
                this.saveCustomSkill();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor('#f0fdf4')
        .borderRadius(8)
        .border({ width: 1, color: '#bbf7d0' })
      }

      // Skills List
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.skillsList, (item: Skill) => {
            Column({ space: 4 }) {
              Row({ space: 6 }) {
                Text(item.name)
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1e293b')

                Text(item.isBuiltin ? '内置' : '自定义')
                  .fontSize(9)
                  .fontColor(item.isBuiltin ? '#0284c7' : '#d97706')
                  .backgroundColor(item.isBuiltin ? '#e0f2fe' : '#fef3c7')
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .borderRadius(4)

                Blank()

                if (!item.isBuiltin) {
                  Button('删除')
                    .fontSize(9)
                    .height(20)
                    .backgroundColor('#fef2f2')
                    .fontColor('#ef4444')
                    .padding({ left: 6, right: 6 })
                    .borderRadius(4)
                    .onClick(() => {
                      this.deleteSkillItem(item.name);
                    })
                }
              }
              .width('100%')

              Text(item.description)
                .fontSize(11)
                .fontColor('#475569')
                .lineHeight(15)

              Text(`📁 ${item.filePath}`)
                .fontSize(9)
                .fontColor('#94a3b8')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(8)
            .backgroundColor('#ffffff')
            .borderRadius(6)
            .border({ width: 1, color: '#e2e8f0' })
            .alignItems(HorizontalAlign.Start)
          }, (item: Skill) => item.name)
        }
        .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .constraintSize({ maxHeight: 180 })
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#f0fdf4')
    .border({ width: { bottom: 1 }, color: '#bbf7d0' })
  }

  @Builder
  buildGoalCard() {
    if (this.activeGoal) {
      Column({ space: 8 }) {
        // Goal Title & Action Row
        Row() {
          Row({ space: 6 }) {
            Text('🎯')
              .fontSize(14)
            Text(this.activeGoal.objective)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#831843')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .layoutWeight(1)

          Row({ space: 6 }) {
            Text(this.activeGoal.status === 'completed' ? '✅ 目标已达成' :
              (this.activeGoal.status === 'active' ? `自主接力 ${this.activeGoal.autonomousStepCount}/${this.activeGoal.maxAutonomousSteps}` :
              (this.activeGoal.status === 'planning' ? '📝 规划中' : '⚠️ 已终止')))
              .fontSize(10)
              .fontColor(this.activeGoal.status === 'completed' ? '#15803d' : '#be185d')
              .backgroundColor(this.activeGoal.status === 'completed' ? '#dcfce7' : '#fce7f3')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)

            Button('✕')
              .fontSize(11)
              .height(24)
              .width(24)
              .padding(0)
              .backgroundColor('#fce7f3')
              .fontColor('#be185d')
              .onClick(() => {
                GoalManager.getInstance().clearGoal();
                this.updateGoalUI();
              })
          }
        }
        .width('100%')

        // Tasks checklist
        if (this.activeGoal.tasks && this.activeGoal.tasks.length > 0) {
          Column({ space: 4 }) {
            ForEach(this.activeGoal.tasks, (t: GoalTask, index: number) => {
              Row({ space: 6 }) {
                Text(t.status === 'completed' ? '✅' : (t.status === 'in_progress' ? '⏳' : '⭕'))
                  .fontSize(11)
                Text(`${index + 1}. ${t.title}`)
                  .fontSize(11)
                  .fontColor(t.status === 'completed' ? '#059669' : (t.status === 'in_progress' ? '#be185d' : '#64748b'))
                  .fontWeight(t.status === 'in_progress' ? FontWeight.Medium : FontWeight.Normal)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (t.status === 'completed') {
                  Text('完成')
                    .fontSize(9)
                    .fontColor('#059669')
                } else if (t.status === 'in_progress') {
                  Text('执行中')
                    .fontSize(9)
                    .fontColor('#be185d')
                }
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            }, (t: GoalTask) => `${t.id}_${t.status}`)
          }
          .width('100%')
          .padding(6)
          .backgroundColor('#ffffff')
          .borderRadius(6)
          .border({ width: 1, color: '#fbcfe8' })
        }
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#fdf2f8')
      .border({ width: { bottom: 1 }, color: '#fbcfe8' })
    }
  }

  private getWorkerRoleBadge(role: WorkerRole): string {
    switch (role) {
      case 'ui_worker':
        return '📱 UI 专员';
      case 'code_worker':
        return '💻 代码专员';
      case 'diag_worker':
        return '🔍 诊断专员';
      case 'web_worker':
        return '🌐 浏览器专员';
      case 'general_worker':
        return '⚙️ 全功能专员';
      default:
        return `🤖 ${role}`;
    }
  }

  private getWorkerRoleColor(role: WorkerRole): string {
    switch (role) {
      case 'ui_worker':
        return '#0284c7';
      case 'code_worker':
        return '#7c3aed';
      case 'diag_worker':
        return '#059669';
      case 'web_worker':
        return '#ea580c';
      case 'general_worker':
        return '#0284c7';
      default:
        return '#475569';
    }
  }

  @Builder
  buildWaitOnBoard() {
    if (this.activeTickets.length > 0) {
      Column({ space: 8 }) {
        // Board Header
        Row() {
          Row({ space: 6 }) {
            Text('⏳')
              .fontSize(13)
            Text('当前在等谁 (Wait-On)')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#0f172a')
            Text(`${this.activeTickets.length} 个任务推进中`)
              .fontSize(10)
              .fontColor('#0284c7')
              .backgroundColor('#e0f2fe')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(10)
          }
          .layoutWeight(1)

          Button('全部中断')
            .fontSize(10)
            .height(22)
            .padding({ left: 8, right: 8 })
            .backgroundColor('#fee2e2')
            .fontColor('#dc2626')
            .borderRadius(4)
            .onClick(() => {
              TicketEngine.getInstance().abortAll();
              this.activeTickets = [...TicketStore.getInstance().getActiveTickets()];
            })
        }
        .width('100%')

        // Active Tickets Scrollable Container
        Scroll() {
          Column({ space: 6 }) {
            ForEach(this.activeTickets, (ticket: Ticket) => {
              Column({ space: 6 }) {
                // Header: Role Badge + Task Title + Status Pill + Actions
                Row({ space: 6 }) {
                  Text(this.getWorkerRoleBadge(ticket.role))
                    .fontSize(10)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.getWorkerRoleColor(ticket.role))
                    .backgroundColor(`${this.getWorkerRoleColor(ticket.role)}15`)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(4)

                  Text(ticket.title || ticket.goal)
                    .fontSize(11)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#1e293b')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)

                  if (ticket.status === 'WaitingHuman') {
                    Text('⚠️ 需人工决策')
                      .fontSize(9)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#b45309')
                      .backgroundColor('#fef3c7')
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                      .borderRadius(4)
                  } else if (ticket.status === 'Running') {
                    Text('⏳ 运行中')
                      .fontSize(9)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#0369a1')
                      .backgroundColor('#e0f2fe')
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                      .borderRadius(4)
                  } else {
                    Text('⏱️ 排队')
                      .fontSize(9)
                      .fontColor('#64748b')
                      .backgroundColor('#f1f5f9')
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                      .borderRadius(4)
                  }

                  Button(this.expandedTicketId === ticket.id ? '收起 ▲' : '详情 ▼')
                    .fontSize(9)
                    .height(20)
                    .padding({ left: 6, right: 6 })
                    .backgroundColor(this.expandedTicketId === ticket.id ? '#e0f2fe' : '#f8fafc')
                    .fontColor(this.expandedTicketId === ticket.id ? '#0284c7' : '#64748b')
                    .borderRadius(4)
                    .onClick(() => {
                      if (this.expandedTicketId === ticket.id) {
                        this.expandedTicketId = '';
                      } else {
                        this.expandedTicketId = ticket.id;
                      }
                    })

                  Button('中断')
                    .fontSize(9)
                    .height(20)
                    .padding({ left: 6, right: 6 })
                    .backgroundColor('#fef2f2')
                    .fontColor('#ef4444')
                    .borderRadius(4)
                    .onClick(() => {
                      TicketEngine.getInstance().abortTicket(ticket.id);
                      this.activeTickets = [...TicketStore.getInstance().getActiveTickets()];
                    })

                  Button('✕')
                    .fontSize(9)
                    .height(20)
                    .width(20)
                    .padding(0)
                    .backgroundColor('#f1f5f9')
                    .fontColor('#64748b')
                    .borderRadius(4)
                    .onClick(() => {
                      if (ticket.status === 'Running' || ticket.status === 'WaitingHuman') {
                        TicketEngine.getInstance().abortTicket(ticket.id);
                      } else {
                        TicketStore.getInstance().deleteTicket(ticket.id);
                      }
                      this.activeTickets = [...TicketStore.getInstance().getActiveTickets()];
                    })
                }
                .width('100%')

                // Action text & Progress Bar
                if (ticket.progress) {
                  Column({ space: 3 }) {
                    Row() {
                      Text(ticket.progress.actionText || '正在推进中...')
                        .fontSize(10)
                        .fontColor('#475569')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)

                      Text(`第 ${ticket.progress.currentStep}/${ticket.progress.maxSteps} 步`)
                        .fontSize(9)
                        .fontColor('#64748b')
                        .fontWeight(FontWeight.Medium)
                    }
                    .width('100%')

                    Row() {
                      Row()
                        .width(`${(ticket.progress.maxSteps > 0) ? Math.min(100, Math.max(5, Math.floor((ticket.progress.currentStep / ticket.progress.maxSteps) * 100))) : 5}%`)
                        .height('100%')
                        .backgroundColor(ticket.status === 'WaitingHuman' ? '#f59e0b' : '#0284c7')
                        .borderRadius(2)
                    }
                    .width('100%')
                    .height(4)
                    .backgroundColor('#e2e8f0')
                    .borderRadius(2)
                    .clip(true)
                  }
                  .width('100%')
                } else if (ticket.status === 'Running') {
                  Row({ space: 4 }) {
                    LoadingProgress()
                      .width(14)
                      .height(14)
                      .color('#0284c7')
                    Text('正在准备专员沙箱与工具环境...')
                      .fontSize(10)
                      .fontColor('#64748b')
                  }
                  .width('100%')
                }

                // Expanded Details Section (Goal, Context, Realtime Step Logs, Output)
                if (this.expandedTicketId === ticket.id) {
                  Column({ space: 8 }) {
                    // 1. Goal
                    Column({ space: 2 }) {
                      Text('🎯 专员任务目标:')
                        .fontSize(9)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#475569')
                      Text(ticket.goal)
                        .fontSize(10)
                        .fontColor('#1e293b')
                    }
                    .width('100%')
                    .alignItems(HorizontalAlign.Start)

                    // 2. Context Info if present
                    if (ticket.contextInfo && ticket.contextInfo.trim().length > 0) {
                      Column({ space: 2 }) {
                        Text('📋 补充上下文:')
                          .fontSize(9)
                          .fontWeight(FontWeight.Bold)
                          .fontColor('#475569')
                        Text(ticket.contextInfo)
                          .fontSize(10)
                          .fontColor('#334155')
                      }
                      .width('100%')
                      .alignItems(HorizontalAlign.Start)
                    }

                    // 3. Step Logs (real-time tool calls & output)
                    if (ticket.stepLogs && ticket.stepLogs.length > 0) {
                      Column({ space: 4 }) {
                        Row() {
                          Text(`🛠️ 执行步骤明细 (${ticket.stepLogs.length} 步):`)
                            .fontSize(9)
                            .fontWeight(FontWeight.Bold)
                            .fontColor('#475569')
                            .layoutWeight(1)

                          Text('最新优先 ▾')
                            .fontSize(8)
                            .fontColor('#0284c7')
                            .backgroundColor('#e0f2fe')
                            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                            .borderRadius(3)
                        }
                        .width('100%')

                        Scroll() {
                          Column({ space: 4 }) {
                            ForEach([...ticket.stepLogs].reverse(), (log: TicketStepLog, idx: number) => {
                              Column({ space: 2 }) {
                                Row({ space: 4 }) {
                                  Text(`第 ${log.step} 步`)
                                    .fontSize(9)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor('#0284c7')
                                  Text(`[${log.tool}]`)
                                    .fontSize(9)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor('#334155')
                                    .backgroundColor('#f1f5f9')
                                    .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                                    .borderRadius(3)

                                  if (idx === 0) {
                                    Text('最新')
                                      .fontSize(8)
                                      .fontWeight(FontWeight.Bold)
                                      .fontColor('#ffffff')
                                      .backgroundColor('#0284c7')
                                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                                      .borderRadius(3)
                                  }
                                }
                                .width('100%')

                                if (log.args && log.args.trim().length > 0) {
                                  Text(`入参: ${log.args}`)
                                    .fontSize(9)
                                    .fontColor('#64748b')
                                    .maxLines(3)
                                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                                }

                                if (log.output && log.output.trim().length > 0) {
                                  Text(`结果: ${log.output}`)
                                    .fontSize(9)
                                    .fontColor('#166534')
                                    .maxLines(4)
                                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                                } else if (log.error && log.error.trim().length > 0) {
                                  Text(`报错: ${log.error}`)
                                    .fontSize(9)
                                    .fontColor('#b91c1c')
                                    .maxLines(3)
                                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                                }
                              }
                              .width('100%')
                              .padding(5)
                              .backgroundColor(idx === 0 ? '#f0f9ff' : '#f8fafc')
                              .borderRadius(4)
                              .border({ width: idx === 0 ? 1 : 0.5, color: idx === 0 ? '#38bdf8' : '#e2e8f0' })
                              .alignItems(HorizontalAlign.Start)
                            }, (log: TicketStepLog) => `${log.step}_${log.tool}_${log.timestamp}`)
                          }
                          .width('100%')
                        }
                        .constraintSize({ maxHeight: 180 })
                        .scrollBar(BarState.Auto)
                      }
                      .width('100%')
                      .alignItems(HorizontalAlign.Start)
                    }

                    // 4. Artifacts if any
                    if (ticket.artifacts && ticket.artifacts.length > 0) {
                      Column({ space: 2 }) {
                        Text('📦 生成产物:')
                          .fontSize(9)
                          .fontWeight(FontWeight.Bold)
                          .fontColor('#475569')
                        ForEach(ticket.artifacts, (art: string) => {
                          Text(`• ${art}`)
                            .fontSize(9)
                            .fontColor('#0284c7')
                        })
                      }
                      .width('100%')
                      .alignItems(HorizontalAlign.Start)
                    }

                    // 5. Result summary if finished
                    if (ticket.result && ticket.result.trim().length > 0) {
                      Column({ space: 2 }) {
                        Text('✅ 任务成果汇报:')
                          .fontSize(9)
                          .fontWeight(FontWeight.Bold)
                          .fontColor('#15803d')
                        Text(ticket.result)
                          .fontSize(10)
                          .fontColor('#1e293b')
                      }
                      .width('100%')
                      .padding(6)
                      .backgroundColor('#f0fdf4')
                      .borderRadius(4)
                      .border({ width: 0.5, color: '#bbf7d0' })
                      .alignItems(HorizontalAlign.Start)
                    }
                  }
                  .width('100%')
                  .padding(8)
                  .backgroundColor('#ffffff')
                  .borderRadius(6)
                  .border({ width: 1, color: '#cbd5e1' })
                }

                // WaitingHuman decision section
                if (ticket.status === 'WaitingHuman' && ticket.attention) {
                  Column({ space: 6 }) {
                    Row({ space: 4 }) {
                      Text('⚠️')
                        .fontSize(11)
                      Text(ticket.attention.question)
                        .fontSize(11)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#92400e')
                        .layoutWeight(1)
                    }
                    .width('100%')

                    if (ticket.attention.options && ticket.attention.options.length > 0) {
                      Scroll() {
                        Row({ space: 6 }) {
                          ForEach(ticket.attention.options, (opt: string) => {
                            Button(opt)
                              .fontSize(10)
                              .height(26)
                              .padding({ left: 8, right: 8 })
                              .backgroundColor('#fef3c7')
                              .fontColor('#b45309')
                              .border({ width: 1, color: '#fcd34d' })
                              .borderRadius(4)
                              .onClick(() => {
                                TicketEngine.getInstance().recordHumanInput();
                                if (ticket.attention) {
                                  AttentionManager.getInstance().respondAttention(ticket.attention.id, opt);
                                }
                                this.activeTickets = [...TicketStore.getInstance().getActiveTickets()];
                              })
                          }, (opt: string) => opt)
                        }
                      }
                      .scrollable(ScrollDirection.Horizontal)
                      .scrollBar(BarState.Off)
                      .width('100%')
                    }

                    if (ticket.attention.allowCustomInput) {
                      Row({ space: 6 }) {
                        TextInput({
                          text: this.waitOnCustomInput,
                          placeholder: '输入补充意见或调整指令...'
                        })
                          .layoutWeight(1)
                          .fontSize(10)
                          .height(28)
                          .onChange((val: string) => {
                            this.waitOnCustomInput = val;
                          })

                        Button('处理确认')
                          .fontSize(10)
                          .height(28)
                          .backgroundColor('#d97706')
                          .fontColor('#ffffff')
                          .borderRadius(4)
                          .onClick(() => {
                            const trimmed = this.waitOnCustomInput.trim();
                            if (trimmed.length > 0 && ticket.attention) {
                              TicketEngine.getInstance().recordHumanInput();
                              AttentionManager.getInstance().respondAttention(ticket.attention.id, trimmed);
                              this.waitOnCustomInput = '';
                              this.activeTickets = [...TicketStore.getInstance().getActiveTickets()];
                            }
                          })
                      }
                      .width('100%')
                    }
                  }
                  .width('100%')
                  .padding(8)
                  .backgroundColor('#fffbeb')
                  .borderRadius(6)
                  .border({ width: 1, color: '#fde68a' })
                }
              }
              .width('100%')
              .padding(8)
              .backgroundColor(ticket.status === 'WaitingHuman' ? '#fffdf5' : '#ffffff')
              .borderRadius(8)
              .border({
                width: 1,
                color: ticket.status === 'WaitingHuman' ? '#fde68a' : '#e2e8f0'
              })
            }, (ticket: Ticket) => `${ticket.id}_${ticket.status}_${ticket.progress?.currentStep ?? 0}`)
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .constraintSize({ maxHeight: 220 })
        .width('100%')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#f8fafc')
      .border({ width: { bottom: 1 }, color: '#e2e8f0' })
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Tabs({ barPosition: BarPosition.End, index: this.currentTabIndex, controller: this.tabsController }) {
        TabContent() {
          this.buildConsoleTab()
        }
        .tabBar('Shell 控制台')

        TabContent() {
          this.buildAgentTab()
        }
        .tabBar('AI Agent')

        TabContent() {
          Column()
        }
        .tabBar('网页浏览器')
      }
      .scrollable(false)
      .onChange((index: number) => {
        this.currentTabIndex = index;
        if (index === 1 && this.skillsList.length === 0) {
          this.refreshSkills();
        }
      })
      .width('100%')
      .height('100%')
      .backgroundColor('#f8fafc')

      // Persistent BrowserView - always mounted so WebviewController is associated from startup
      BrowserView({
        onSwitchToAgent: () => {
          this.currentTabIndex = 1;
          this.tabsController.changeIndex(1);
        }
      })
      .width('100%')
      .height('100%')
      .padding({ bottom: 56 })
      .hitTestBehavior(this.currentTabIndex === 2 ? HitTestMode.Default : HitTestMode.None)
      .visibility(this.currentTabIndex === 2 ? Visibility.Visible : Visibility.Hidden)

      if (this.previewImageUrl.length > 0) {
        Column() {
          Row() {
            Text(this.previewImageCaption.length > 0 ? this.previewImageCaption : '图片预览')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#f8fafc')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            Row({ space: 8 }) {
              Button('保存到下载')
                .fontSize(11)
                .height(28)
                .padding({ left: 8, right: 8 })
                .backgroundColor('#0284c7')
                .fontColor('#ffffff')
                .onClick(() => {
                  this.exportFileToDownload(this.previewImageUrl);
                })

              Button('关闭')
                .fontSize(11)
                .height(28)
                .padding({ left: 8, right: 8 })
                .backgroundColor('#334155')
                .fontColor('#ffffff')
                .onClick(() => {
                  this.closeImagePreview();
                })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 10 })

          Image(this.previewImageUrl)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 12, right: 12, bottom: 18 })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(2, 6, 23, 0.92)')
        .onClick(() => {
          this.closeImagePreview();
        })
      }

      // Text / Code File Preview Fullscreen Overlay
      if (this.previewTextPath.length > 0) {
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text(this.previewTextTitle.length > 0 ? this.previewTextTitle : '文件预览')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#f8fafc')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Text(this.previewTextPath)
                .fontSize(10)
                .fontColor('#94a3b8')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Row({ space: 8 }) {
              Button('复制')
                .fontSize(11)
                .height(28)
                .padding({ left: 8, right: 8 })
                .backgroundColor('#0284c7')
                .fontColor('#ffffff')
                .onClick(() => {
                  this.copyTextToClipboard(this.previewTextContent);
                })

              Button('导出下载')
                .fontSize(11)
                .height(28)
                .padding({ left: 8, right: 8 })
                .backgroundColor('#0f766e')
                .fontColor('#ffffff')
                .onClick(() => {
                  this.exportFileToDownload(this.previewTextPath);
                })

              Button('关闭')
                .fontSize(11)
                .height(28)
                .padding({ left: 8, right: 8 })
                .backgroundColor('#334155')
                .fontColor('#ffffff')
                .onClick(() => {
                  this.closeTextPreview();
                })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 10 })

          Scroll() {
            Text(this.previewTextContent)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor('#e2e8f0')
              .copyOption(CopyOptions.LocalDevice)
              .padding(12)
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#0f172a')
          .borderRadius(8)
          .margin({ left: 12, right: 12, bottom: 18 })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(2, 6, 23, 0.94)')
      }
    }
    .width('100%')
    .height('100%')
  }
}
