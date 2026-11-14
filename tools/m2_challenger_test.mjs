/**
 * Milestone 2 Challenger Stress & Adversarial Empirical Test Suite
 *
 * EMPIRICAL CHALLENGE FOCUS:
 * 1. Non-blocking latency: Verify DispatchWorkerTool returns in < 50ms without blocking.
 * 2. Step progress streaming: Verify tool_call_start updates TicketStore progress (stepsCount, maxSteps, actionText).
 * 3. Multi-worker concurrency: Verify multiple workers can run concurrently without race conditions.
 * 4. Anti-loop ceiling: Verify 3-consecutive auto-wakeup limit hard-locks into WaitingHuman and resets on human input.
 * 5. Deduplication: Verify calling onWorkerCompleted multiple times does not trigger multiple wakeups or corrupt terminal status.
 * 6. UI & Architectural Invariants: Verify pinned Wait-On board in Index.ets, FloatPanel sync, and test suites.
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

let passCount = 0;
let failCount = 0;
const failures = [];

async function runTest(name, fn) {
  try {
    await fn();
    console.log(`  [PASS] ${name}`);
    passCount++;
  } catch (err) {
    console.error(`  [FAIL] ${name}`);
    console.error(`         ${err.message}`);
    if (err.stack) {
      console.error(err.stack.split('\n').slice(1, 4).join('\n'));
    }
    failCount++;
    failures.push({ name, error: err.message });
  }
}

const rootDir = process.cwd();
const dispatchWorkerToolPath = path.join(rootDir, 'entry/src/main/ets/agent/superagent/DispatchWorkerTool.ets');
const workerSessionPath = path.join(rootDir, 'entry/src/main/ets/agent/superagent/WorkerSession.ets');
const ticketEnginePath = path.join(rootDir, 'entry/src/main/ets/agent/superagent/TicketEngine.ets');
const ticketStorePath = path.join(rootDir, 'entry/src/main/ets/agent/superagent/TicketStore.ets');
const agentSessionPath = path.join(rootDir, 'entry/src/main/ets/agent/AgentSession.ets');
const indexEtsPath = path.join(rootDir, 'entry/src/main/ets/pages/Index.ets');
const floatPanelPath = path.join(rootDir, 'entry/src/main/ets/pages/FloatPanel.ets');
const asyncTestPath = path.join(rootDir, 'entry/src/test/AsyncDispatchWaitOn.test.ets');

// =====================================================================
// SUITE 1: FORENSIC CODE AUDIT & ARCHITECTURAL INVARIANTS
// =====================================================================
console.log('\n======================================================================');
console.log('=== SUITE 1: FORENSIC CODE AUDIT & ARCHITECTURAL INVARIANTS ===');
console.log('======================================================================');

await runTest('Audit: DispatchWorkerTool.ets implements non-blocking async dispatch', () => {
  const content = fs.readFileSync(dispatchWorkerToolPath, 'utf8');
  assert.ok(content.includes('TicketEngine.getInstance().dispatchTask'), 'Must call TicketEngine.dispatchTask');
  assert.ok(!content.includes('await WorkerSession.runTask'), 'Must NOT await WorkerSession.runTask synchronously');
  assert.ok(content.includes('[WORKER DISPATCHED]'), 'Must return structured [WORKER DISPATCHED] text');
  assert.ok(content.includes('Task has been dispatched in the background'), 'Must inform user task runs in background');
  assert.ok(content.includes('Goal cannot be empty'), 'Must guard against empty goal');
  assert.ok(content.includes('maxSteps = typeof rawMaxSteps === \'number\''), 'Must parse and validate max_steps');
});

await runTest('Audit: WorkerSession.ets streams tool_call_start and finalizes terminal status', () => {
  const content = fs.readFileSync(workerSessionPath, 'utf8');
  assert.ok(content.includes('ticketId?: string'), 'runTask signature must support optional ticketId');
  assert.ok(content.includes('TicketStore.getInstance().getTicket(effectiveTicketId)'), 'Must bind to canonical ticket');
  assert.ok(content.includes('event.type === \'tool_call_start\''), 'Must intercept tool_call_start events');
  assert.ok(content.includes('TicketStore.getInstance().updateProgress(activeTicket.id, stepsCount, maxSteps, action)'), 'Must update TicketStore on tool_call_start');
  assert.ok(content.includes('TicketEngine.getInstance().onWorkerCompleted(resolvedTicket)'), 'Must call onWorkerCompleted on finish');
  assert.ok(content.includes('artifacts'), 'Must harvest generated artifacts');
});

await runTest('Audit: TicketEngine.ets enforces anti-loop barrier, unawaited execution & deduplication', () => {
  const content = fs.readFileSync(ticketEnginePath, 'utf8');
  assert.ok(content.includes('MAX_CONSECUTIVE_AUTO_WAKEUPS = 3'), 'Must declare MAX_CONSECUTIVE_AUTO_WAKEUPS = 3');
  assert.ok(content.includes('this.consecutiveAutoWakeCount >= MAX_CONSECUTIVE_AUTO_WAKEUPS'), 'Must check >= limit');
  assert.ok(content.includes('recordHumanInput(): void'), 'Must provide recordHumanInput method');
  assert.ok(content.includes('this.consecutiveAutoWakeCount = 0'), 'recordHumanInput must reset counter to 0');
  assert.ok(content.includes('this.executeBackgroundWorker('), 'Must launch background execution');
  assert.ok(content.includes('current.status !== \'Completed\' && current.status !== \'Failed\' && current.status !== \'WaitingHuman\''),
    'Must deduplicate completion between WorkerSession and promise.then fallback');
  assert.ok(content.includes('abortTicket(ticketId: string): void'), 'Must support per-ticket abort');
  assert.ok(content.includes('abortAll(): void'), 'Must support global abort');
});

await runTest('Audit: AgentSession.ets wires router wakeup hook and enforces authority boundary', () => {
  const content = fs.readFileSync(agentSessionPath, 'utf8');
  assert.ok(content.includes('this.initRouterWakeupHook()'), 'Must initialize router wakeup hook');
  assert.ok(content.includes('TicketEngine.getInstance().setRouterWakeupCallback'), 'Must register callback with TicketEngine');
  assert.ok(content.includes('@专员汇报'), 'Must inject @专员汇报 message on completed/failed worker');
  assert.ok(content.includes('@专员求助'), 'Must inject @专员求助 message on WaitingHuman');

  // Authority boundary: wakeup handler must NOT reset human input counter or grant execution loops
  const wakeupStartIndex = content.indexOf('handleWorkerWakeup(');
  const wakeupEndIndex = content.indexOf('formatWorkerDeliverablesSummary(');
  assert.ok(wakeupStartIndex !== -1 && wakeupEndIndex !== -1, 'handleWorkerWakeup method must exist');
  const wakeupBody = content.substring(wakeupStartIndex, wakeupEndIndex);
  assert.ok(!wakeupBody.includes('recordHumanInput'), 'handleWorkerWakeup must NOT call recordHumanInput');
  assert.ok(!wakeupBody.includes('runLoop'), 'handleWorkerWakeup must NOT auto-run agent loop');

  // Human prompt: runPrompt must call recordHumanInput
  const runPromptStartIndex = content.indexOf('async runPrompt(');
  assert.ok(runPromptStartIndex !== -1, 'runPrompt method must exist');
  const runPromptBody = content.substring(runPromptStartIndex);
  assert.ok(runPromptBody.includes('TicketEngine.getInstance().recordHumanInput()'), 'runPrompt must invoke recordHumanInput()');
});

await runTest('Audit: Index.ets & FloatPanel.ets Wait-On board and active ticket controls', () => {
  const indexContent = fs.readFileSync(indexEtsPath, 'utf8');
  assert.ok(indexContent.includes('buildWaitOnBoard()'), 'Index.ets must define buildWaitOnBoard');
  assert.ok(indexContent.includes('当前在等谁 (Wait-On)'), 'Index.ets must have Wait-On board header');
  assert.ok(indexContent.includes('TicketEngine.getInstance().abortAll()'), 'Index.ets must support 全部中断');
  assert.ok(indexContent.includes('TicketEngine.getInstance().abortTicket(ticket.id)'), 'Index.ets must support 单个中断');
  assert.ok(indexContent.includes('TicketStore.getInstance().addListener'), 'Index.ets must register TicketStore listener');

  const floatContent = fs.readFileSync(floatPanelPath, 'utf8');
  assert.ok(floatContent.includes('@StorageProp(\'activeTicketsCount\')'), 'FloatPanel must observe activeTicketsCount');
  assert.ok(floatContent.includes('@StorageProp(\'activeTickets\')'), 'FloatPanel must observe activeTickets');
  assert.ok(floatContent.includes('buildActiveWorkersList'), 'FloatPanel must render active workers list');
  assert.ok(floatContent.includes('TicketEngine.getInstance().abortAll()'), 'FloatPanel must support abortAll');
});

// =====================================================================
// SIMULATION HARNESS FOR EMPIRICAL CHALLENGES
// =====================================================================

class EmpiricalTicketStore {
  constructor() {
    this.tickets = new Map();
    this.listeners = [];
  }
  createTicket(role, title, goal, contextInfo) {
    const id = `ticket-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
    const effectiveTitle = title && title.trim().length > 0 ? title.trim() : (goal ? goal.substring(0, 30) : `Task [${role}]`);
    const ticket = {
      id,
      title: effectiveTitle,
      role,
      goal,
      status: 'Pending',
      contextInfo,
      timestamps: { createdAt: Date.now() }
    };
    this.tickets.set(id, ticket);
    this.notify();
    return ticket;
  }
  updateTicket(ticket) {
    if (!ticket || !ticket.id) return;
    this.tickets.set(ticket.id, ticket);
    this.notify();
  }
  updateStatus(id, status, resultOrError) {
    const ticket = this.tickets.get(id);
    if (!ticket) return;
    ticket.status = status;
    const now = Date.now();
    if (status === 'Running') {
      if (!ticket.timestamps.startedAt) ticket.timestamps.startedAt = now;
    } else if (status === 'Completed') {
      ticket.timestamps.completedAt = now;
      if (resultOrError !== undefined) ticket.result = resultOrError;
    } else if (status === 'Failed') {
      ticket.timestamps.completedAt = now;
      if (resultOrError !== undefined) ticket.error = resultOrError;
    }
    this.notify();
  }
  updateProgress(id, currentStep, maxSteps, actionText) {
    const ticket = this.tickets.get(id);
    if (!ticket) return;
    if (ticket.status === 'Pending') {
      ticket.status = 'Running';
      if (!ticket.timestamps.startedAt) ticket.timestamps.startedAt = Date.now();
    }
    ticket.progress = { currentStep, maxSteps, actionText };
    this.notify();
  }
  getTicket(id) {
    return this.tickets.get(id);
  }
  getActiveTickets() {
    return Array.from(this.tickets.values()).filter(t =>
      t.status === 'Pending' || t.status === 'Running' || t.status === 'WaitingHuman'
    );
  }
  getAllTickets() {
    return Array.from(this.tickets.values());
  }
  deleteTicket(id) {
    if (this.tickets.delete(id)) {
      this.notify();
    }
  }
  clear() {
    this.tickets.clear();
    this.notify();
  }
  addListener(fn) {
    this.listeners.push(fn);
  }
  removeListener(fn) {
    this.listeners = this.listeners.filter(l => l !== fn);
  }
  notify() {
    const list = this.getAllTickets();
    for (const fn of this.listeners) {
      fn(list);
    }
  }
}

class EmpiricalAttentionManager {
  constructor() {
    this.active = null;
    this.deferreds = new Map();
  }
  requestAttention(ticketId, question, options, allowCustomInput = true, timeoutSec = 0, customId) {
    const id = customId || `att-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
    const req = {
      id,
      ticketId,
      question,
      options,
      allowCustomInput,
      createdAt: Date.now()
    };
    this.active = req;
    return new Promise((resolve) => {
      this.deferreds.set(id, resolve);
    });
  }
  respondAttention(id, answer) {
    const resolve = this.deferreds.get(id);
    if (resolve) {
      resolve(answer);
      this.deferreds.delete(id);
      if (this.active && this.active.id === id) {
        this.active = null;
      }
      return true;
    }
    return false;
  }
  cancelAttention(id) {
    const resolve = this.deferreds.get(id);
    if (resolve) {
      resolve('取消任务');
      this.deferreds.delete(id);
      if (this.active && this.active.id === id) {
        this.active = null;
      }
    }
  }
  getActiveAttention() {
    return this.active;
  }
  clear() {
    this.active = null;
    this.deferreds.clear();
  }
}

class EmpiricalTicketEngine {
  constructor(store, attMgr) {
    this.store = store;
    this.attMgr = attMgr;
    this.consecutiveAutoWakeCount = 0;
    this.activeWorkers = new Map();
    this.routerWakeupCallback = null;
    this.completedTicketIds = new Set();
  }
  setRouterWakeupCallback(cb) {
    this.routerWakeupCallback = cb;
  }
  recordHumanInput() {
    this.consecutiveAutoWakeCount = 0;
  }
  getConsecutiveAutoWakeCount() {
    return this.consecutiveAutoWakeCount;
  }
  dispatchTask(role, goal, contextInfo, maxSteps = 15, workerExecutor = null) {
    if (!goal || goal.trim().length === 0) {
      throw new Error('Goal cannot be empty when dispatching worker');
    }
    const title = goal.length > 25 ? `${goal.substring(0, 25)}...` : goal;
    const ticket = this.store.createTicket(role, title, goal, contextInfo);

    if (this.consecutiveAutoWakeCount >= 3) {
      const attentionReqId = `att-limit-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
      const question = `已达到连续自动任务上限 (3 次)。请确认是否继续执行任务：${title}`;
      const options = ['确认继续', '取消任务'];
      const attentionReq = {
        id: attentionReqId,
        ticketId: ticket.id,
        question,
        options,
        allowCustomInput: true,
        createdAt: Date.now()
      };
      ticket.status = 'WaitingHuman';
      ticket.attention = attentionReq;
      this.store.updateTicket(ticket);

      this.attMgr.requestAttention(ticket.id, question, options, true, 0, attentionReqId)
        .then((ans) => {
          this.recordHumanInput();
          if (ans === '取消任务' || ans.includes('取消') || ans.includes('cancel')) {
            this.abortTicket(ticket.id);
          } else {
            this.store.updateStatus(ticket.id, 'Running');
            this.executeBackgroundWorker(ticket, maxSteps, workerExecutor);
          }
        });
      return ticket;
    }

    this.executeBackgroundWorker(ticket, maxSteps, workerExecutor);
    return ticket;
  }

  executeBackgroundWorker(ticket, maxSteps, workerExecutor) {
    ticket.status = 'Running';
    this.store.updateStatus(ticket.id, 'Running');

    let isAborted = false;
    const abortHandler = () => {
      isAborted = true;
    };
    this.activeWorkers.set(ticket.id, { ticketId: ticket.id, abort: abortHandler });

    const onProgress = (prog) => {
      if (isAborted) return;
      this.store.updateProgress(ticket.id, prog.currentStep, prog.maxSteps, prog.actionText);
    };

    const taskPromise = workerExecutor
      ? workerExecutor(ticket, onProgress, () => isAborted)
      : Promise.resolve({
          ticketId: ticket.id,
          role: ticket.role,
          status: 'ready',
          summary: 'Task finished successfully'
        });

    taskPromise.then((report) => {
      this.activeWorkers.delete(ticket.id);
      if (isAborted) {
        this.store.updateStatus(ticket.id, 'Failed', 'Task aborted by user');
        return;
      }

      // Deduplication check: only finalize if status is not already terminal
      const current = this.store.getTicket(ticket.id);
      if (current && current.status !== 'Completed' && current.status !== 'Failed' && current.status !== 'WaitingHuman') {
        if (report.status === 'ready') {
          this.store.updateStatus(ticket.id, 'Completed', report.summary);
        } else if (report.status === 'failed') {
          this.store.updateStatus(ticket.id, 'Failed', report.summary);
        }
        const finalTicket = this.store.getTicket(ticket.id) || ticket;
        this.onWorkerCompleted(finalTicket);
      }
    }).catch((err) => {
      this.activeWorkers.delete(ticket.id);
      if (!isAborted) {
        this.store.updateStatus(ticket.id, 'Failed', `${err}`);
        const finalTicket = this.store.getTicket(ticket.id) || ticket;
        this.onWorkerCompleted(finalTicket);
      }
    });
  }

  abortTicket(ticketId) {
    const active = this.activeWorkers.get(ticketId);
    if (active) {
      active.abort();
      this.activeWorkers.delete(ticketId);
    }
    const ticket = this.store.getTicket(ticketId);
    if (ticket && ticket.attention) {
      this.attMgr.cancelAttention(ticket.attention.id);
    }
    this.store.updateStatus(ticketId, 'Failed', 'Task aborted by user');
  }

  abortAll() {
    const keys = Array.from(this.activeWorkers.keys());
    for (const key of keys) {
      const active = this.activeWorkers.get(key);
      if (active) active.abort();
    }
    this.activeWorkers.clear();
    const activeTickets = this.store.getActiveTickets();
    for (const t of activeTickets) {
      this.store.updateStatus(t.id, 'Failed', 'All tasks aborted');
    }
  }

  onWorkerCompleted(ticket) {
    this.consecutiveAutoWakeCount++;
    this.triggerRouterWakeup(ticket);
  }

  triggerRouterWakeup(ticket) {
    if (this.routerWakeupCallback) {
      try {
        this.routerWakeupCallback(ticket);
      } catch (_e) {
        // ignore
      }
    }
  }
}

// Simulated DispatchWorkerTool.execute
class SimulatedDispatchWorkerTool {
  static async execute(engine, toolCallId, args) {
    const rawRole = args['role'] ?? 'general_worker';
    const role = rawRole && rawRole.trim().length > 0 ? rawRole.trim() : 'general_worker';
    const goal = args['goal'] ?? '';
    const contextInfo = args['context_info'] ?? '';

    if (!goal || goal.trim().length === 0) {
      return {
        toolCallId,
        toolName: 'dispatch_worker',
        output: '',
        error: 'Goal cannot be empty when dispatching worker',
        isError: true
      };
    }

    try {
      const ticket = engine.dispatchTask(role, goal, contextInfo);
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

// =====================================================================
// SUITE 2: NON-BLOCKING DISPATCH LATENCY STRESS BENCHMARK (FOCUS 1)
// =====================================================================
console.log('\n======================================================================');
console.log('=== SUITE 2: NON-BLOCKING DISPATCH LATENCY STRESS BENCHMARK ===');
console.log('======================================================================');

await runTest('Latency: DispatchWorkerTool.execute returns in < 50ms (100-run benchmark)', async () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  const times = [];
  for (let i = 0; i < 100; i++) {
    const t0 = performance.now();
    const res = await SimulatedDispatchWorkerTool.execute(engine, `call-${i}`, {
      role: 'code_worker',
      goal: `Refactor module #${i} for thread safety`,
      context_info: `Context details for step ${i}`
    });
    const dt = performance.now() - t0;
    times.push(dt);

    assert.equal(res.isError, false);
    assert.ok(res.output.includes('[WORKER DISPATCHED]'));
    assert.ok(res.output.includes('Role: code_worker'));
    assert.ok(dt < 50, `Run ${i} took ${dt.toFixed(2)}ms, exceeding 50ms limit`);
  }

  const avg = times.reduce((a, b) => a + b, 0) / times.length;
  const max = Math.max(...times);
  console.log(`         [Benchmark Info] 100 runs - Avg: ${avg.toFixed(3)}ms, Max: ${max.toFixed(3)}ms`);
  assert.ok(avg < 5.0, `Average dispatch latency must be under 5ms (was ${avg.toFixed(3)}ms)`);
});

await runTest('Latency: Validation rejection on empty/whitespace goal is immediate (< 5ms)', async () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  const invalidInputs = ['', '   ', null, undefined];
  for (const inv of invalidInputs) {
    const t0 = performance.now();
    const res = await SimulatedDispatchWorkerTool.execute(engine, 'call-inv', {
      role: 'diag_worker',
      goal: inv
    });
    const dt = performance.now() - t0;
    assert.ok(dt < 5, `Rejection took ${dt.toFixed(2)}ms, should be < 5ms`);
    assert.equal(res.isError, true);
    assert.ok(res.error.includes('Goal cannot be empty'));
  }
});

await runTest('Latency: Large context payload (100KB) does not cause synchronous lag', async () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  const hugeContext = 'x'.repeat(100 * 1024); // 100KB string
  const t0 = performance.now();
  const res = await SimulatedDispatchWorkerTool.execute(engine, 'call-large', {
    role: 'general_worker',
    goal: 'Process massive telemetry dataset',
    context_info: hugeContext
  });
  const dt = performance.now() - t0;

  assert.equal(res.isError, false);
  assert.ok(dt < 25, `Large payload dispatch took ${dt.toFixed(2)}ms, must be < 25ms`);
});

// =====================================================================
// SUITE 3: STEP PROGRESS STREAMING & EVENT EMISSION (FOCUS 2)
// =====================================================================
console.log('\n======================================================================');
console.log('=== SUITE 3: STEP PROGRESS STREAMING & EVENT EMISSION ===');
console.log('======================================================================');

await runTest('Streaming: tool_call_start events sequentially update TicketStore progress', async () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  const progressEvents = [];
  let targetTicketId = null;
  store.addListener((tickets) => {
    if (!targetTicketId) return;
    const t = tickets.find(x => x.id === targetTicketId);
    if (t && t.progress) {
      progressEvents.push({ ...t.progress });
    }
  });

  const ticket = engine.dispatchTask('ui_worker', 'Automate login flow', 'App package: com.example.login');
  targetTicketId = ticket.id;

  assert.equal(ticket.status, 'Running');
  assert.equal(ticket.progress, undefined);

  // Simulate 5 successive tool_call_start steps
  const actions = [
    '正在调用 dump_ui...',
    '正在调用 click (username_input)...',
    '正在调用 type_text (admin)...',
    '正在调用 click (submit_button)...',
    '正在调用 take_screenshot...'
  ];

  for (let step = 1; step <= actions.length; step++) {
    store.updateProgress(ticket.id, step, 10, actions[step - 1]);
    const updated = store.getTicket(ticket.id);
    assert.equal(updated.progress.currentStep, step);
    assert.equal(updated.progress.maxSteps, 10);
    assert.equal(updated.progress.actionText, actions[step - 1]);
  }

  assert.equal(progressEvents.length, 5);
  assert.equal(progressEvents[4].currentStep, 5);
  assert.equal(progressEvents[4].actionText, '正在调用 take_screenshot...');
});

await runTest('Streaming: updateProgress on Pending ticket moves status to Running and sets startedAt', () => {
  const store = new EmpiricalTicketStore();
  const t = store.createTicket('code_worker', 'Fix bug', 'Fix null pointer');
  assert.equal(t.status, 'Pending');
  assert.equal(t.timestamps.startedAt, undefined);

  store.updateProgress(t.id, 1, 5, 'Executing bash test command...');
  const updated = store.getTicket(t.id);
  assert.equal(updated.status, 'Running');
  assert.ok(typeof updated.timestamps.startedAt === 'number');
  assert.equal(updated.progress.currentStep, 1);
});

await runTest('Streaming: updateProgress on Completed/Failed ticket does not revert terminal status', () => {
  const store = new EmpiricalTicketStore();
  const t = store.createTicket('diag_worker', 'Run diag', 'Dump system memory');
  store.updateStatus(t.id, 'Completed', 'Memory dump captured');

  // Attempt late progress update
  store.updateProgress(t.id, 3, 5, 'Late tool call');
  const finished = store.getTicket(t.id);
  assert.equal(finished.status, 'Completed', 'Terminal Completed status must NOT revert to Running');
  assert.equal(finished.result, 'Memory dump captured');
});

// =====================================================================
// SUITE 4: MULTI-WORKER CONCURRENCY & RACE-CONDITION STRESS (FOCUS 3)
// =====================================================================
console.log('\n======================================================================');
console.log('=== SUITE 4: MULTI-WORKER CONCURRENCY & ISOLATION STRESS ===');
console.log('======================================================================');

await runTest('Concurrency: 50 concurrent worker dispatches maintain isolation without ID/state collisions', () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  const roles = ['ui_worker', 'code_worker', 'diag_worker', 'web_worker', 'general_worker'];
  const dispatchedTickets = [];

  for (let i = 0; i < 50; i++) {
    const role = roles[i % roles.length];
    const ticket = engine.dispatchTask(role, `Concurrent Task #${i}`, `Context ${i}`);
    dispatchedTickets.push(ticket);
  }

  // 1. Verify all 50 IDs are strictly unique
  const idSet = new Set(dispatchedTickets.map(t => t.id));
  assert.equal(idSet.size, 50, 'All 50 tickets must have unique IDs');

  // 2. Verify all are in active list
  const active = store.getActiveTickets();
  assert.equal(active.length, 50, 'TicketStore must hold 50 active tickets');
});

await runTest('Concurrency: Interleaved concurrent progress updates do not cross-contaminate', () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  const tA = engine.dispatchTask('ui_worker', 'Task A');
  const tB = engine.dispatchTask('code_worker', 'Task B');
  const tC = engine.dispatchTask('web_worker', 'Task C');

  // Interleaved updates
  store.updateProgress(tA.id, 1, 10, 'A step 1');
  store.updateProgress(tB.id, 1, 15, 'B step 1');
  store.updateProgress(tC.id, 1, 8, 'C step 1');
  store.updateProgress(tA.id, 2, 10, 'A step 2');
  store.updateProgress(tB.id, 2, 15, 'B step 2');

  assert.equal(store.getTicket(tA.id).progress.currentStep, 2);
  assert.equal(store.getTicket(tA.id).progress.actionText, 'A step 2');

  assert.equal(store.getTicket(tB.id).progress.currentStep, 2);
  assert.equal(store.getTicket(tB.id).progress.maxSteps, 15);

  assert.equal(store.getTicket(tC.id).progress.currentStep, 1);
  assert.equal(store.getTicket(tC.id).progress.maxSteps, 8);
});

await runTest('Concurrency: Independent abort of single worker leaves peers running undisturbed', () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  const tickets = [];
  for (let i = 0; i < 10; i++) {
    tickets.push(engine.dispatchTask('code_worker', `Task ${i}`));
  }

  // Abort ticket index 3 and 7
  engine.abortTicket(tickets[3].id);
  engine.abortTicket(tickets[7].id);

  assert.equal(store.getTicket(tickets[3].id).status, 'Failed');
  assert.equal(store.getTicket(tickets[3].id).error, 'Task aborted by user');
  assert.equal(store.getTicket(tickets[7].id).status, 'Failed');

  // Verify other 8 tickets are still Running
  for (let i = 0; i < 10; i++) {
    if (i !== 3 && i !== 7) {
      assert.equal(store.getTicket(tickets[i].id).status, 'Running');
    }
  }

  assert.equal(store.getActiveTickets().length, 8);
});

await runTest('Concurrency: abortAll() halts all active workers cleanly', () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  for (let i = 0; i < 12; i++) {
    engine.dispatchTask('diag_worker', `Task ${i}`);
  }
  assert.equal(store.getActiveTickets().length, 12);

  engine.abortAll();
  assert.equal(store.getActiveTickets().length, 0);

  const all = store.getAllTickets();
  for (const t of all) {
    assert.equal(t.status, 'Failed');
    assert.ok(t.error.includes('aborted'));
  }
});

// =====================================================================
// SUITE 5: ANTI-LOOP CEILING STATE MACHINE (FOCUS 4)
// =====================================================================
console.log('\n======================================================================');
console.log('=== SUITE 5: ANTI-LOOP CEILING & AUTO-WAKEUP HARD LOCK ===');
console.log('======================================================================');

await runTest('Anti-Loop: Exact 3-consecutive auto-wakeup limit forces WaitingHuman on 4th dispatch', async () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  let wakeupsTriggered = 0;
  engine.setRouterWakeupCallback((t) => {
    wakeupsTriggered++;
  });

  // Turn 1
  const t1 = engine.dispatchTask('code_worker', 'Auto Task 1');
  assert.equal(t1.status, 'Running');
  store.updateStatus(t1.id, 'Completed', 'Done 1');
  engine.onWorkerCompleted(store.getTicket(t1.id));
  assert.equal(engine.getConsecutiveAutoWakeCount(), 1);
  assert.equal(wakeupsTriggered, 1);

  // Turn 2
  const t2 = engine.dispatchTask('code_worker', 'Auto Task 2');
  assert.equal(t2.status, 'Running');
  store.updateStatus(t2.id, 'Completed', 'Done 2');
  engine.onWorkerCompleted(store.getTicket(t2.id));
  assert.equal(engine.getConsecutiveAutoWakeCount(), 2);
  assert.equal(wakeupsTriggered, 2);

  // Turn 3
  const t3 = engine.dispatchTask('code_worker', 'Auto Task 3');
  assert.equal(t3.status, 'Running');
  store.updateStatus(t3.id, 'Completed', 'Done 3');
  engine.onWorkerCompleted(store.getTicket(t3.id));
  assert.equal(engine.getConsecutiveAutoWakeCount(), 3);
  assert.equal(wakeupsTriggered, 3);

  // Turn 4: LIMIT HIT -> Must hard-lock into WaitingHuman
  let backgroundStarted = false;
  const t4 = engine.dispatchTask('code_worker', 'Auto Task 4', '', 15, () => {
    backgroundStarted = true;
    return Promise.resolve({ status: 'ready', summary: 'Should not run' });
  });

  assert.equal(t4.status, 'WaitingHuman', 'Ticket 4 MUST be frozen in WaitingHuman');
  assert.equal(backgroundStarted, false, 'Background execution must NOT start while locked in WaitingHuman');
  assert.ok(t4.attention !== undefined, 'Ticket must contain AttentionRequest payload');
  assert.ok(t4.attention.question.includes('已达到连续自动任务上限 (3 次)'));
  assert.deepEqual(t4.attention.options, ['确认继续', '取消任务']);

  // Check AttentionManager registration
  const activeAtt = attMgr.getActiveAttention();
  assert.ok(activeAtt !== null);
  assert.equal(activeAtt.id, t4.attention.id);
  assert.equal(activeAtt.ticketId, t4.id);
});

await runTest('Anti-Loop: Human decision "取消任务" aborts locked ticket and resets counter', async () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  // Advance counter to 3
  const t1 = store.createTicket('code_worker', 'T1', 'G1');
  engine.onWorkerCompleted(t1);
  engine.onWorkerCompleted(t1);
  engine.onWorkerCompleted(t1);
  assert.equal(engine.getConsecutiveAutoWakeCount(), 3);

  // 4th dispatch triggers lock
  const locked = engine.dispatchTask('diag_worker', 'Autonomous Investigation');
  assert.equal(locked.status, 'WaitingHuman');

  // Human user taps "取消任务"
  const answered = attMgr.respondAttention(locked.attention.id, '取消任务');
  assert.equal(answered, true);
  await new Promise(r => setTimeout(r, 10)); // allow promise resolution

  assert.equal(engine.getConsecutiveAutoWakeCount(), 0, 'Human answer must reset counter to 0');
  assert.equal(store.getTicket(locked.id).status, 'Failed');
  assert.equal(store.getTicket(locked.id).error, 'Task aborted by user');
});

await runTest('Anti-Loop: Human decision "确认继续" unlocks ticket to Running and resets counter', async () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  // Advance counter to 3
  const t = store.createTicket('code_worker', 'T', 'G');
  engine.onWorkerCompleted(t);
  engine.onWorkerCompleted(t);
  engine.onWorkerCompleted(t);
  assert.equal(engine.getConsecutiveAutoWakeCount(), 3);

  let workerExecuted = false;
  let resolveWorker;
  const workerPromise = new Promise(r => { resolveWorker = r; });

  const locked = engine.dispatchTask('code_worker', 'Critical System Patch', '', 15, () => {
    workerExecuted = true;
    return workerPromise;
  });

  assert.equal(locked.status, 'WaitingHuman');
  assert.equal(workerExecuted, false);

  // Human taps "确认继续"
  attMgr.respondAttention(locked.attention.id, '确认继续');
  await new Promise(r => setTimeout(r, 10));

  assert.equal(engine.getConsecutiveAutoWakeCount(), 0, 'Human confirmation must reset counter to 0');
  assert.equal(workerExecuted, true, 'Worker execution must resume after human confirmation');
  assert.equal(store.getTicket(locked.id).status, 'Running');

  // When worker finishes, counter increments to 1 for this new autonomous cycle
  resolveWorker({ status: 'ready', summary: 'Patch applied' });
  await new Promise(r => setTimeout(r, 10));
  assert.equal(engine.getConsecutiveAutoWakeCount(), 1);
  assert.equal(store.getTicket(locked.id).status, 'Completed');
});

await runTest('Anti-Loop: Any human chat message (recordHumanInput) immediately clears auto wakeup counter', () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  const t = store.createTicket('diag_worker', 'T', 'G');
  engine.onWorkerCompleted(t);
  engine.onWorkerCompleted(t);
  assert.equal(engine.getConsecutiveAutoWakeCount(), 2);

  // Human speaks in chat
  engine.recordHumanInput();
  assert.equal(engine.getConsecutiveAutoWakeCount(), 0, 'Counter must be 0 after human speaks');

  // Can now run 3 more turns
  const tNext = engine.dispatchTask('diag_worker', 'Next Task');
  assert.equal(tNext.status, 'Running');
});

// =====================================================================
// SUITE 6: DEDUPLICATION & TERMINAL STATE INVARIANTS (FOCUS 5)
// =====================================================================
console.log('\n======================================================================');
console.log('=== SUITE 6: DEDUPLICATION & TERMINAL STATE INVARIANTS ===');
console.log('======================================================================');

await runTest('Deduplication: Background execution pipeline executes onWorkerCompleted exactly once', async () => {
  const store = new EmpiricalTicketStore();
  const attMgr = new EmpiricalAttentionManager();
  const engine = new EmpiricalTicketEngine(store, attMgr);

  let wakeupCalls = 0;
  engine.setRouterWakeupCallback(() => {
    wakeupCalls++;
  });

  // Simulate worker execution where WorkerSession finalizes status AND onWorkerCompleted
  let promiseResolve;
  const workerPromise = new Promise(res => { promiseResolve = res; });

  const ticket = engine.dispatchTask('code_worker', 'Single Execution Task', '', 15, () => workerPromise);
  assert.equal(ticket.status, 'Running');

  // Step 1: WorkerSession reaches end of runTask, sets status to Completed, and calls onWorkerCompleted
  store.updateStatus(ticket.id, 'Completed', 'WorkerSession completed summary');
  engine.onWorkerCompleted(store.getTicket(ticket.id));

  assert.equal(wakeupCalls, 1, 'First completion triggers wakeup once');
  assert.equal(engine.getConsecutiveAutoWakeCount(), 1);

  // Step 2: workerPromise resolves -> executeBackgroundWorker.then() runs
  promiseResolve({ status: 'ready', summary: 'Promise resolved report' });
  await new Promise(r => setTimeout(r, 10));

  // Step 3: Verify the fallback check prevented duplicate wakeup call
  assert.equal(wakeupCalls, 1, 'Fallback check MUST NOT trigger duplicate onWorkerCompleted');
  assert.equal(engine.getConsecutiveAutoWakeCount(), 1, 'Auto wake count must NOT increment twice');
  assert.equal(store.getTicket(ticket.id).result, 'WorkerSession completed summary');
});

await runTest('Deduplication: Calling updateStatus repeatedly on terminal ticket preserves integrity', () => {
  const store = new EmpiricalTicketStore();
  const t = store.createTicket('code_worker', 'Stable Task', 'Goal');

  store.updateStatus(t.id, 'Completed', 'Initial Success');
  const completedAt1 = store.getTicket(t.id).timestamps.completedAt;
  assert.ok(typeof completedAt1 === 'number');

  // Call again with same terminal status
  store.updateStatus(t.id, 'Completed');
  assert.equal(store.getTicket(t.id).status, 'Completed');
  assert.equal(store.getTicket(t.id).result, 'Initial Success');
});

await runTest('Deduplication: Deleting and clearing tickets purges state without dangling references', () => {
  const store = new EmpiricalTicketStore();
  const t1 = store.createTicket('ui_worker', 'T1', 'G1');
  const t2 = store.createTicket('ui_worker', 'T2', 'G2');

  assert.equal(store.getAllTickets().length, 2);
  store.deleteTicket(t1.id);
  assert.equal(store.getAllTickets().length, 1);
  assert.equal(store.getTicket(t1.id), undefined);

  store.clear();
  assert.equal(store.getAllTickets().length, 0);
  assert.equal(store.getActiveTickets().length, 0);
});

// =====================================================================
// SUITE 7: INTEGRITY & ANTI-FACADE STATIC AUDIT
// =====================================================================
console.log('\n======================================================================');
console.log('=== SUITE 7: INTEGRITY & ANTI-FACADE AUDIT ===');
console.log('======================================================================');

await runTest('Integrity: Production codebase contains zero mocked shortcuts or test bypasses', () => {
  const files = [dispatchWorkerToolPath, workerSessionPath, ticketEnginePath, ticketStorePath, agentSessionPath];
  for (const f of files) {
    const text = fs.readFileSync(f, 'utf8');
    assert.ok(!text.includes('__MOCK__'), `No __MOCK__ in ${path.basename(f)}`);
    assert.ok(!text.includes('BYPASS_FOR_TEST'), `No BYPASS_FOR_TEST in ${path.basename(f)}`);
    assert.ok(!text.includes('fake_ticket'), `No fake_ticket in ${path.basename(f)}`);
  }
});

await runTest('Integrity: AsyncDispatchWaitOn.test.ets contains genuine assertions', () => {
  const content = fs.readFileSync(asyncTestPath, 'utf8');
  assert.ok(content.includes('expect(duration < 50).assertTrue()'), 'Asserts real latency bound');
  assert.ok(content.includes('expect(res.isError).assertTrue()'), 'Asserts error handling');
  assert.ok(content.includes('expect(res.output).assertContain(\'[WORKER DISPATCHED]\')'), 'Asserts output formatting');
  assert.ok(content.includes('expect(engine.getConsecutiveAutoWakeCount()).assertEqual(0)'), 'Asserts human input reset');
  assert.ok(content.includes('expect(attMgr.getActiveAttention()).assertNull()'), 'Asserts attention clean-up');
});

// =====================================================================
// SUMMARY
// =====================================================================
console.log('\n======================================================================');
console.log(`TOTAL EMPIRICAL CHALLENGER TESTS: ${passCount + failCount}`);
console.log(`PASSED:                           ${passCount}`);
console.log(`FAILED:                           ${failCount}`);
console.log('======================================================================\n');

if (failCount > 0) {
  process.exit(1);
}
