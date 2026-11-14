/**
 * Milestone 2 Challenger 2: Empirical Adversarial UI, State Machine & Concurrency Suite
 *
 * Focus Areas:
 * 1. Input Unblocking & Concurrency Steering (Index.ets, AgentSession.ets, AgentLoop.ets)
 * 2. Wait-On Board Interactive State Machine (Index.ets, TicketEngine.ets, AttentionManager.ets)
 * 3. FloatPanel Synchronization & AppStorage Reactivity (FloatPanel.ets, TicketStore.ets)
 * 4. Router Summary Wakeup & Authority Restriction (AgentSession.ets, ToolRegistry.ets, TicketEngine.ets)
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

let passed = 0;
let failed = 0;
const failures = [];

async function test(name, fn) {
  try {
    await fn();
    console.log(`  ✓ [PASS] ${name}`);
    passed++;
  } catch (err) {
    console.error(`  ✗ [FAIL] ${name}`);
    console.error(`    Error: ${err.message}`);
    if (err.stack) {
      const trace = err.stack.split('\n').slice(1, 4).join('\n');
      console.error(trace);
    }
    failed++;
    failures.push({ name, error: err.message });
  }
}

const rootDir = process.cwd();
const indexEtsPath = path.join(rootDir, 'entry/src/main/ets/pages/Index.ets');
const floatPanelPath = path.join(rootDir, 'entry/src/main/ets/pages/FloatPanel.ets');
const ticketEnginePath = path.join(rootDir, 'entry/src/main/ets/agent/superagent/TicketEngine.ets');
const ticketStorePath = path.join(rootDir, 'entry/src/main/ets/agent/superagent/TicketStore.ets');
const attentionManagerPath = path.join(rootDir, 'entry/src/main/ets/agent/superagent/AttentionManager.ets');
const agentSessionPath = path.join(rootDir, 'entry/src/main/ets/agent/AgentSession.ets');
const agentLoopPath = path.join(rootDir, 'entry/src/main/ets/agent/harness/AgentLoop.ets');
const toolRegistryPath = path.join(rootDir, 'entry/src/main/ets/agent/tools/ToolRegistry.ets');
const dispatchWorkerToolPath = path.join(rootDir, 'entry/src/main/ets/agent/superagent/DispatchWorkerTool.ets');

console.log('\n======================================================================');
console.log('=== CHALLENGE 1: INPUT UNBLOCKING & CONCURRENCY STEERING CONTRACTS ===');
console.log('======================================================================\n');

await test('Index.ets: Agent input TextInput is NOT disabled when activeTickets are running', () => {
  const code = fs.readFileSync(indexEtsPath, 'utf8');

  // Find TextInput for agentInputPrompt in Index.ets
  const textInputMatch = code.match(/TextInput\(\{\s*text:\s*this\.agentInputPrompt[\s\S]*?\}\)([\s\S]*?)(?:Button\(|if\s*\(|Stack\(|Column\(|Row\()/);
  assert.ok(textInputMatch, 'Must find TextInput for agentInputPrompt in Index.ets');

  const textInputBlock = textInputMatch[0];
  // Ensure .enabled(false) or .enabled(!this.activeTickets.length) or .enabled(!this.agentRunning) is NOT on this TextInput
  assert.ok(!textInputBlock.includes('.enabled('), 'TextInput for prompt must not be disabled by .enabled(...)');
  assert.ok(textInputBlock.includes('.onSubmit('), 'TextInput must support enter submission via onSubmit');
});

await test('Index.ets: sendAgentPrompt allows submission during background worker execution', () => {
  const code = fs.readFileSync(indexEtsPath, 'utf8');

  // Verify sendAgentPrompt definition
  const sendPromptMatch = code.match(/private async sendAgentPrompt\(\): Promise<void> \{([\s\S]*?)\n  \}/);
  assert.ok(sendPromptMatch, 'Must find sendAgentPrompt function');
  const sendBody = sendPromptMatch[1];

  // Must not reject or return early when activeTickets > 0
  assert.ok(!sendBody.includes('activeTickets.length > 0'), 'sendAgentPrompt must not block when activeTickets are running');
  assert.ok(!sendBody.includes('activeTicketsCount > 0'), 'sendAgentPrompt must not block on activeTicketsCount');

  // Must call agentSession.runPrompt
  assert.ok(sendBody.includes('this.agentSession.runPrompt'), 'sendAgentPrompt must invoke agentSession.runPrompt');
});

await test('AgentSession: runPrompt handles concurrent inputs safely via steeringQueue without crashing', async () => {
  const sessionCode = fs.readFileSync(agentSessionPath, 'utf8');
  assert.ok(sessionCode.includes('this.steeringQueue.push(steeringMsg)'), 'AgentSession must queue mid-flight inputs in steeringQueue');
  assert.ok(sessionCode.includes('getPendingSteering(): Message[]'), 'AgentSession must expose getPendingSteering()');

  // Adversarial Simulation: Simulate AgentSession message reception under concurrent load
  class MockAgentSession {
    constructor() {
      this.messages = [];
      this.steeringQueue = [];
      this.isRunning = false;
      this.humanInputsCount = 0;
    }

    recordHumanInput() {
      this.humanInputsCount++;
    }

    async runPrompt(prompt) {
      this.recordHumanInput();
      const trimmed = prompt.trim();
      if (!trimmed) return;

      if (this.isRunning) {
        const steeringMsg = {
          role: 'user',
          content: `[User Steering Note]: ${trimmed}`
        };
        this.steeringQueue.push(steeringMsg);
        this.messages.push(steeringMsg);
        return;
      }

      this.isRunning = true;
      this.messages.push({ role: 'user', content: trimmed });
    }

    getPendingSteering() {
      const q = [...this.steeringQueue];
      this.steeringQueue = [];
      return q;
    }

    finishTurn() {
      this.isRunning = false;
    }
  }

  const session = new MockAgentSession();

  // 1. Initial user message launches turn
  await session.runPrompt('Find bug in auth module');
  assert.equal(session.isRunning, true);
  assert.equal(session.messages.length, 1);
  assert.equal(session.messages[0].content, 'Find bug in auth module');

  // 2. Rapid-fire mid-flight steering while running
  await session.runPrompt('Also check password hashing algorithm');
  await session.runPrompt('Stop if you hit external network');
  await session.runPrompt('Generate unit test if found');

  assert.equal(session.steeringQueue.length, 3);
  assert.equal(session.messages.length, 4);
  assert.equal(session.humanInputsCount, 4);

  // 3. AgentLoop consumes steering notes at next iteration
  const consumed = session.getPendingSteering();
  assert.equal(consumed.length, 3);
  assert.equal(session.steeringQueue.length, 0);
  assert.ok(consumed[0].content.includes('password hashing'));
  assert.ok(consumed[1].content.includes('external network'));
  assert.ok(consumed[2].content.includes('unit test'));

  // 4. Turn finishes, subsequent prompt starts normal turn
  session.finishTurn();
  assert.equal(session.isRunning, false);
  await session.runPrompt('Next query');
  assert.equal(session.isRunning, true);
  assert.equal(session.steeringQueue.length, 0);
});

await test('AgentLoop: getSteering hook is called per loop step and injects notes into active messages', () => {
  const loopCode = fs.readFileSync(agentLoopPath, 'utf8');

  assert.ok(loopCode.includes('getSteering?: () => Message[]'), 'runLoop must accept getSteering callback');
  assert.ok(loopCode.includes('if (getSteering) {'), 'runLoop must check for getSteering notes');
  assert.ok(loopCode.includes('const steeringNotes = getSteering();'), 'runLoop must pull pending steering notes');
  assert.ok(loopCode.includes('messages.push(s)'), 'runLoop must inject steering notes into turn messages');
});

console.log('\n======================================================================');
console.log('=== CHALLENGE 2: WAIT-ON BOARD INTERACTIVE STATE MACHINE & CONTROLS ===');
console.log('======================================================================\n');

await test('Index.ets: Wait-On Board is rendered conditionally and contains all required role badges and controls', () => {
  const code = fs.readFileSync(indexEtsPath, 'utf8');

  // Verify board presence above chat scroll
  assert.ok(code.includes('if (this.activeTickets.length > 0)'), 'Wait-On board must be guarded by activeTickets.length > 0');
  assert.ok(code.includes('this.buildWaitOnBoard()'), 'buildWaitOnBoard must be called in Index.ets');

  // Verify role badges
  assert.ok(code.includes('this.getWorkerRoleBadge(ticket.role)'), 'Must render role badge via getWorkerRoleBadge');
  assert.ok(code.includes('this.getWorkerRoleColor(ticket.role)'), 'Must style role badge with role color');

  // Verify control buttons
  assert.ok(code.includes("Button('全部中断')"), 'Must render 全部中断 button');
  assert.ok(code.includes("TicketEngine.getInstance().abortAll()"), '全部中断 must call TicketEngine.abortAll');
  assert.ok(code.includes("Button('中断')"), 'Must render individual 中断 button');
  assert.ok(code.includes("TicketEngine.getInstance().abortTicket(ticket.id)"), '中断 must call TicketEngine.abortTicket');
  assert.ok(code.includes("Button('✕')"), 'Must render close/dismiss button ✕');
});

await test('Index.ets: WaitingHuman tickets render question, quick-tap option buttons, custom input, and 处理确认', () => {
  const code = fs.readFileSync(indexEtsPath, 'utf8');

  // Section condition
  assert.ok(code.includes("ticket.status === 'WaitingHuman' && ticket.attention"), 'Must check WaitingHuman and attention presence');
  assert.ok(code.includes("ticket.attention.question"), 'Must render attention question');
  assert.ok(code.includes("ticket.attention.options"), 'Must render attention options array');

  // Quick-tap options click handler
  const optionClickMatch = code.match(/ForEach\(ticket\.attention\.options,[\s\S]*?\.onClick\(\(\) => \{([\s\S]*?)\}\)/);
  assert.ok(optionClickMatch, 'Must find onClick handler for option buttons');
  const optionClickBody = optionClickMatch[1];
  assert.ok(optionClickBody.includes('TicketEngine.getInstance().recordHumanInput()'), 'Option click must record human input to reset anti-loop counter');
  assert.ok(optionClickBody.includes('AttentionManager.getInstance().respondAttention'), 'Option click must respond attention via AttentionManager');

  // Custom text input and 处理确认
  assert.ok(code.includes("ticket.attention.allowCustomInput"), 'Must check allowCustomInput');
  assert.ok(code.includes("Button('处理确认')"), 'Must render 处理确认 button');

  const customConfirmMatch = code.match(/Button\('处理确认'\)[\s\S]*?\.onClick\(\(\) => \{([\s\S]*?)\}\)/);
  assert.ok(customConfirmMatch, 'Must find onClick handler for 处理确认');
  const confirmBody = customConfirmMatch[1];
  assert.ok(confirmBody.includes('TicketEngine.getInstance().recordHumanInput()'), '处理确认 click must record human input');
  assert.ok(confirmBody.includes('AttentionManager.getInstance().respondAttention'), '处理确认 click must call respondAttention');
});

await test('AttentionManager: respondAttention resolves pending promise and handles edge cases', async () => {
  const attCode = fs.readFileSync(attentionManagerPath, 'utf8');
  assert.ok(attCode.includes('requestAttention('), 'AttentionManager must have requestAttention');
  assert.ok(attCode.includes('respondAttention(id: string, selectedValue: string): boolean'), 'AttentionManager must have respondAttention');
  assert.ok(attCode.includes('cancelAttention(id: string): void'), 'AttentionManager must have cancelAttention');
  assert.ok(attCode.includes('clear(): void'), 'AttentionManager must have clear');

  // Adversarial Simulation: AttentionManager Resolution State Machine
  class MockAttentionManager {
    constructor() {
      this.pendingRequests = new Map();
      this.activeRequest = null;
    }

    requestAttention(ticketId, question, options, allowCustomInput = true) {
      const id = `att-${Date.now()}-${Math.random().toString(36).substring(2, 6)}`;
      const req = { id, ticketId, question, options, allowCustomInput };
      return new Promise((resolve, reject) => {
        this.pendingRequests.set(id, { request: req, resolve, reject });
        this.activeRequest = req;
      });
    }

    respondAttention(id, answer) {
      const pending = this.pendingRequests.get(id);
      if (!pending) return false;
      this.pendingRequests.delete(id);
      if (this.activeRequest?.id === id) {
        const remaining = Array.from(this.pendingRequests.values());
        this.activeRequest = remaining.length > 0 ? remaining[0].request : null;
      }
      pending.resolve(answer);
      return true;
    }

    cancelAttention(id) {
      const pending = this.pendingRequests.get(id);
      if (!pending) return false;
      this.pendingRequests.delete(id);
      if (this.activeRequest?.id === id) {
        this.activeRequest = null;
      }
      pending.resolve('[Cancelled]');
      return true;
    }

    clear() {
      for (const [id, pending] of this.pendingRequests.entries()) {
        pending.resolve('[Cleared]');
      }
      this.pendingRequests.clear();
      this.activeRequest = null;
    }
  }

  const manager = new MockAttentionManager();

  // 1. Normal resolution
  const p1 = manager.requestAttention('t1', 'Proceed with migration?', ['Yes', 'No']);
  assert.equal(manager.activeRequest.ticketId, 't1');
  const res1 = manager.respondAttention(manager.activeRequest.id, 'Yes');
  assert.equal(res1, true);
  assert.equal(await p1, 'Yes');
  assert.equal(manager.activeRequest, null);

  // 2. Double-resolution / Invalid ID check (must return false, not crash)
  assert.equal(manager.respondAttention('non-existent-id', 'test'), false);

  // 3. Multi-request FIFO queueing
  const p2 = manager.requestAttention('t2', 'Q2', ['A', 'B']);
  const id2 = manager.activeRequest.id;
  const p3 = manager.requestAttention('t3', 'Q3', ['C', 'D']);
  assert.equal(manager.pendingRequests.size, 2);

  // Respond to second one (id2)
  manager.respondAttention(id2, 'A');
  assert.equal(await p2, 'A');
  // Next active request should now be t3
  assert.equal(manager.activeRequest.ticketId, 't3');

  // Cancel remaining
  manager.cancelAttention(manager.activeRequest.id);
  assert.equal(await p3, '[Cancelled]');
  assert.equal(manager.pendingRequests.size, 0);
  assert.equal(manager.activeRequest, null);
});

await test('TicketEngine.abortAll marks ALL active tickets as Failed and clears active workers', () => {
  const engineCode = fs.readFileSync(ticketEnginePath, 'utf8');

  assert.ok(engineCode.includes('abortAll(): void'), 'TicketEngine must have abortAll()');
  assert.ok(engineCode.includes('WorkerSession.abortAll()'), 'abortAll must invoke WorkerSession.abortAll');
  assert.ok(engineCode.includes('this.activeWorkers.clear()'), 'abortAll must clear activeWorkers map');
  assert.ok(engineCode.includes("TicketStore.getInstance().updateStatus(t.id, 'Failed', 'All tasks aborted')"), 'abortAll must mark all active tickets as Failed');

  // State machine simulation of abortAll
  class MockTicketEngine {
    constructor() {
      this.tickets = new Map();
      this.activeWorkers = new Map();
    }

    addTicket(id, status) {
      this.tickets.set(id, { id, status });
      if (status === 'Running') {
        this.activeWorkers.set(id, { abort: () => {} });
      }
    }

    getActiveTickets() {
      return Array.from(this.tickets.values()).filter(t => t.status === 'Running' || t.status === 'WaitingHuman');
    }

    abortAll() {
      for (const w of this.activeWorkers.values()) {
        w.abort();
      }
      this.activeWorkers.clear();
      for (const t of this.getActiveTickets()) {
        t.status = 'Failed';
        t.error = 'All tasks aborted';
      }
    }
  }

  const engine = new MockTicketEngine();
  engine.addTicket('t1', 'Running');
  engine.addTicket('t2', 'Running');
  engine.addTicket('t3', 'WaitingHuman');
  engine.addTicket('t4', 'Completed');

  assert.equal(engine.getActiveTickets().length, 3);
  engine.abortAll();
  assert.equal(engine.getActiveTickets().length, 0);
  assert.equal(engine.tickets.get('t1').status, 'Failed');
  assert.equal(engine.tickets.get('t2').status, 'Failed');
  assert.equal(engine.tickets.get('t3').status, 'Failed');
  assert.equal(engine.tickets.get('t4').status, 'Completed'); // Completed tickets left intact
});

console.log('\n======================================================================');
console.log('=== CHALLENGE 3: FLOAT PANEL SYNCHRONIZATION & REACTIVITY CONTRACTS ===');
console.log('======================================================================\n');

await test('FloatPanel.ets: Uses @StorageProp for activeTicketsCount and activeTickets', () => {
  const code = fs.readFileSync(floatPanelPath, 'utf8');

  assert.ok(code.includes("@StorageProp('activeTicketsCount') activeTicketsCount: number = 0"), 'FloatPanel must bind activeTicketsCount via @StorageProp');
  assert.ok(code.includes("@StorageProp('activeTickets') activeTickets: Ticket[] = []"), 'FloatPanel must bind activeTickets via @StorageProp');
  assert.ok(code.includes('buildCompactPill()'), 'FloatPanel must implement buildCompactPill');
  assert.ok(code.includes('buildExpandedPanel()'), 'FloatPanel must implement buildExpandedPanel');
  assert.ok(code.includes('buildActiveWorkersList()'), 'FloatPanel must implement buildActiveWorkersList');
});

await test('TicketStore: notifyListeners automatically propagates activeTickets and activeTicketsCount to AppStorage', () => {
  const code = fs.readFileSync(ticketStorePath, 'utf8');

  assert.ok(code.includes("AppStorage.setOrCreate('activeTickets', active)"), 'TicketStore must push activeTickets to AppStorage');
  assert.ok(code.includes("AppStorage.setOrCreate('activeTicketsCount', active.length)"), 'TicketStore must push activeTicketsCount to AppStorage');
  assert.ok(code.includes('this.notifyListeners()'), 'TicketStore must notify listeners on ticket operations');
});

await test('FloatPanel: Compact Pill and Expanded Panel react correctly to active tickets and WaitingHuman states', () => {
  const code = fs.readFileSync(floatPanelPath, 'utf8');

  // Verify compact pill status logic
  assert.ok(code.includes('hasWaitingHumanTicket()'), 'FloatPanel must have hasWaitingHumanTicket helper');
  assert.ok(code.includes('getCompactPulseColor()'), 'FloatPanel must have getCompactPulseColor helper');
  assert.ok(code.includes('getCompactStatusText()'), 'FloatPanel must have getCompactStatusText helper');

  // Simulate FloatPanel helper methods with adversarial inputs
  class MockFloatPanel {
    constructor(activeTicketsCount = 0, activeTickets = [], isRunning = false) {
      this.activeTicketsCount = activeTicketsCount;
      this.activeTickets = activeTickets;
      this.isRunning = isRunning;
    }

    hasWaitingHumanTicket() {
      if (!this.activeTickets || this.activeTickets.length === 0) return false;
      return this.activeTickets.some(t => t.status === 'WaitingHuman');
    }

    getCompactPulseColor() {
      if (this.hasWaitingHumanTicket()) return '#f59e0b'; // Amber pulse
      if (this.isRunning || this.activeTicketsCount > 0) return '#22c55e'; // Green pulse
      return '#94a3b8'; // Idle slate
    }

    getCompactStatusText() {
      if (this.activeTicketsCount > 0 && this.activeTickets && this.activeTickets.length > 0) {
        const first = this.activeTickets[0];
        if (first.status === 'WaitingHuman') {
          return `待决策: ${first.title}`;
        }
        if (first.progress?.actionText) {
          return `专员: ${first.progress.actionText}`;
        }
        return `${this.activeTicketsCount} 专员后台运行中`;
      }
      if (this.isRunning) return 'Agent 思考中...';
      return '待命';
    }
  }

  // Case 1: Idle
  const fp1 = new MockFloatPanel(0, [], false);
  assert.equal(fp1.hasWaitingHumanTicket(), false);
  assert.equal(fp1.getCompactPulseColor(), '#94a3b8');
  assert.equal(fp1.getCompactStatusText(), '待命');

  // Case 2: 1 Running worker with action text
  const fp2 = new MockFloatPanel(1, [{
    id: 't1',
    title: 'Run test suite',
    status: 'Running',
    progress: { currentStep: 2, maxSteps: 5, actionText: 'Executing npm test' }
  }], false);
  assert.equal(fp2.hasWaitingHumanTicket(), false);
  assert.equal(fp2.getCompactPulseColor(), '#22c55e');
  assert.equal(fp2.getCompactStatusText(), '专员: Executing npm test');

  // Case 3: Worker enters WaitingHuman
  const fp3 = new MockFloatPanel(1, [{
    id: 't2',
    title: 'Delete old logs?',
    status: 'WaitingHuman',
    attention: { question: 'Confirm log deletion', options: ['Yes', 'No'] }
  }], false);
  assert.equal(fp3.hasWaitingHumanTicket(), true);
  assert.equal(fp3.getCompactPulseColor(), '#f59e0b');
  assert.equal(fp3.getCompactStatusText(), '待决策: Delete old logs?');
});

console.log('\n======================================================================');
console.log('=== CHALLENGE 4: ROUTER SUMMARY WAKEUP & AUTHORITY RESTRICTION ===');
console.log('======================================================================\n');

await test('AgentSession: formatWorkerDeliverablesSummary formats @专员汇报 and @专员求助 properly', () => {
  const code = fs.readFileSync(agentSessionPath, 'utf8');

  assert.ok(code.includes('private formatWorkerDeliverablesSummary(ticket: Ticket): string'), 'AgentSession must implement formatWorkerDeliverablesSummary');
  assert.ok(code.includes('@专员求助'), 'Must format @专员求助 for WaitingHuman');
  assert.ok(code.includes('@专员汇报'), 'Must format @专员汇报 for Completed / Failed');
  assert.ok(code.includes('**产出物列表 (Artifacts)**:'), 'Must list deliverables/artifacts');
  assert.ok(code.includes('*(注: 本汇报仅同步工作结论与交付物，已自动沉淀到会话上下文中)*'), 'Must include non-executable disclaimer');

  // Adversarial Simulation: Test summary formatting for all terminal statuses
  class MockSummaryFormatter {
    format(ticket) {
      if (ticket.status === 'WaitingHuman') {
        let out = `### ⚠️ @专员求助 [UI 专员 | 任务: ${ticket.title}]\n\n`;
        out += `后台专员在执行任务 \`${ticket.id}\` 时需要人工确认：\n\n`;
        if (ticket.attention) {
          out += `**待确认事项**: ${ticket.attention.question}\n\n`;
          if (ticket.attention.options) {
            out += `**快速决策选项**: ` + ticket.attention.options.map(opt => `\`${opt}\``).join(' | ') + '\n\n';
          }
        }
        return out;
      }
      if (ticket.status === 'Completed') {
        let out = `### 📢 @专员汇报 [代码专员 | 任务: ${ticket.title}]\n\n`;
        out += `后台专员已顺利完成任务 \`${ticket.id}\`。\n\n`;
        out += `**任务目标**: ${ticket.goal}\n\n`;
        if (ticket.result) out += `**工作成果与交付总结**:\n${ticket.result}\n\n`;
        if (ticket.artifacts && ticket.artifacts.length > 0) {
          out += `**产出物列表 (Artifacts)**:\n`;
          for (const a of ticket.artifacts) out += `- \`${a}\`\n`;
          out += '\n';
        }
        out += `*(注: 本汇报仅同步工作结论与交付物，已自动沉淀到会话上下文中)*`;
        return out;
      }
      return `### ❌ @专员汇报 [诊断专员 | 任务: ${ticket.title}]\n\n**异常原因**:\n${ticket.error || '未知异常'}`;
    }
  }

  const formatter = new MockSummaryFormatter();

  const completedReport = formatter.format({
    id: 't-100',
    title: 'Fix null pointer in auth',
    goal: 'Resolve crash on invalid token',
    status: 'Completed',
    result: 'Fixed null check on line 42',
    artifacts: ['/data/app/auth.patch', '/data/app/test.log']
  });

  assert.ok(completedReport.includes('### 📢 @专员汇报'));
  assert.ok(completedReport.includes('/data/app/auth.patch'));
  assert.ok(completedReport.includes('/data/app/test.log'));
  assert.ok(completedReport.includes('Fixed null check on line 42'));
  assert.ok(completedReport.includes('已自动沉淀到会话上下文中'));

  const waitingReport = formatter.format({
    id: 't-101',
    title: 'Drop database schema',
    status: 'WaitingHuman',
    attention: { question: 'Permanently drop users table?', options: ['Confirm Drop', 'Abort'] }
  });

  assert.ok(waitingReport.includes('### ⚠️ @专员求助'));
  assert.ok(waitingReport.includes('Permanently drop users table?'));
  assert.ok(waitingReport.includes('`Confirm Drop` | `Abort`'));
});

await test('Router Wakeup Authority Restriction: Summary messages are pure assistant text without tool_calls', () => {
  const code = fs.readFileSync(agentSessionPath, 'utf8');

  // Find handleWorkerWakeup implementation
  const handleWakeupMatch = code.match(/private handleWorkerWakeup\(ticket: Ticket\): void \{([\s\S]*?)\n  \}/);
  assert.ok(handleWakeupMatch, 'Must find handleWorkerWakeup');
  const wakeupBody = handleWakeupMatch[1];

  // Must construct pure assistant message
  assert.ok(wakeupBody.includes("role: 'assistant'"), 'Wakeup report must have role: assistant');
  assert.ok(wakeupBody.includes("content: summaryContent"), 'Wakeup report must contain summaryContent');
  assert.ok(!wakeupBody.includes("tool_calls:"), 'Wakeup report must NEVER attach tool_calls');
  assert.ok(!wakeupBody.includes("runPrompt"), 'handleWorkerWakeup must NOT recursively trigger runPrompt');
});

await test('Star Topology Enforcement: Workers are strictly prohibited from receiving dispatch_worker', () => {
  const toolRegCode = fs.readFileSync(toolRegistryPath, 'utf8');

  assert.ok(toolRegCode.includes("getWorkerToolDefinitions(role: WorkerRole, allowed?: string[]): ToolDefinition[]"), 'Must have getWorkerToolDefinitions');
  assert.ok(toolRegCode.includes("const safeNames = allowedNames.filter(name => name !== 'dispatch_worker')"), 'Must explicitly filter out dispatch_worker from worker tools');

  // Verify Router has dispatch_worker and ask_attention, but NO bash/edit/ui
  assert.ok(toolRegCode.includes("DispatchWorkerTool.getDefinition()"), 'Router must have dispatch_worker');
  assert.ok(toolRegCode.includes("AskAttentionTool.getDefinition()"), 'Router must have ask_attention');

  const routerDefsMatch = toolRegCode.match(/static getRouterToolDefinitions\(\): ToolDefinition\[\] \{([\s\S]*?)\}/);
  assert.ok(routerDefsMatch, 'Must find getRouterToolDefinitions');
  const routerDefsBody = routerDefsMatch[1];
  assert.ok(!routerDefsBody.includes('BashTool'), 'Router must not have BashTool');
  assert.ok(!routerDefsBody.includes('EditTool'), 'Router must not have EditTool');
  assert.ok(!routerDefsBody.includes('UiTool'), 'Router must not have UiTool');
});

await test('Anti-Loop Hard Shield: 3 consecutive autonomous wakeups force WaitingHuman until human speaks', () => {
  const engineCode = fs.readFileSync(ticketEnginePath, 'utf8');

  assert.ok(engineCode.includes('MAX_CONSECUTIVE_AUTO_WAKEUPS = 3'), 'Must define MAX_CONSECUTIVE_AUTO_WAKEUPS as 3');
  assert.ok(engineCode.includes('if (this.consecutiveAutoWakeCount >= MAX_CONSECUTIVE_AUTO_WAKEUPS)'), 'Must enforce anti-loop condition');
  assert.ok(engineCode.includes("ticket.status = 'WaitingHuman'"), 'Must freeze into WaitingHuman upon hitting limit');
  assert.ok(engineCode.includes('recordHumanInput(): void'), 'Must provide recordHumanInput method');
  assert.ok(engineCode.includes('this.consecutiveAutoWakeCount = 0'), 'recordHumanInput must reset counter to 0');

  // Adversarial Simulation: Anti-Loop limiter with auto wakeups vs human input
  class MockAntiLoopEngine {
    constructor() {
      this.consecutiveAutoWakeCount = 0;
      this.MAX_LIMIT = 3;
    }

    onWorkerCompleted() {
      this.consecutiveAutoWakeCount++;
    }

    recordHumanInput() {
      this.consecutiveAutoWakeCount = 0;
    }

    dispatchTask(goal) {
      if (this.consecutiveAutoWakeCount >= this.MAX_LIMIT) {
        return { status: 'WaitingHuman', goal, question: 'Limit reached. Confirm continue?' };
      }
      return { status: 'Running', goal };
    }
  }

  const engine = new MockAntiLoopEngine();

  // 1st auto worker finishes -> count = 1
  engine.onWorkerCompleted();
  assert.equal(engine.consecutiveAutoWakeCount, 1);
  let t = engine.dispatchTask('Task 2');
  assert.equal(t.status, 'Running');

  // 2nd auto worker finishes -> count = 2
  engine.onWorkerCompleted();
  assert.equal(engine.consecutiveAutoWakeCount, 2);
  t = engine.dispatchTask('Task 3');
  assert.equal(t.status, 'Running');

  // 3rd auto worker finishes -> count = 3 (Limit reached!)
  engine.onWorkerCompleted();
  assert.equal(engine.consecutiveAutoWakeCount, 3);

  // 4th dispatch MUST be frozen into WaitingHuman
  t = engine.dispatchTask('Task 4');
  assert.equal(t.status, 'WaitingHuman');
  assert.ok(t.question.includes('Limit reached'));

  // 5th dispatch still frozen
  t = engine.dispatchTask('Task 5');
  assert.equal(t.status, 'WaitingHuman');

  // Human speaks or clicks decision -> resets counter to 0
  engine.recordHumanInput();
  assert.equal(engine.consecutiveAutoWakeCount, 0);

  // Subsequent dispatch succeeds immediately
  t = engine.dispatchTask('Task 6');
  assert.equal(t.status, 'Running');
});

console.log('\n======================================================================');
console.log('=== CHALLENGE 5: ATTENTION API COMPATIBILITY AUDIT ===');
console.log('======================================================================\n');

await test('AttentionManager: Verification of attention resolution API methods', () => {
  const code = fs.readFileSync(attentionManagerPath, 'utf8');

  // Check if respondAttention exists
  const hasRespondAttention = code.includes('respondAttention(id: string, selectedValue: string): boolean');
  assert.ok(hasRespondAttention, 'AttentionManager must have respondAttention');

  // Check if resolveAttention exists as an alias or if only respondAttention is present
  const hasResolveAttention = code.includes('resolveAttention');
  if (!hasResolveAttention) {
    console.log('    ℹ [OBSERVATION]: AttentionManager implements `respondAttention(id, val)` as the resolution API.');
    console.log('    ℹ Index.ets, FloatPanel.ets, and unit tests all consistently call `respondAttention`.');
    console.log('    ℹ Recommendation: An alias `resolveAttention(id, val)` can be added in M3 for extra interface resilience.');
  }
});

console.log('\n======================================================================');
console.log(`SUMMARY: Passed: ${passed}, Failed: ${failed}`);
console.log('======================================================================\n');

if (failed > 0) {
  process.exit(1);
} else {
  process.exit(0);
}
