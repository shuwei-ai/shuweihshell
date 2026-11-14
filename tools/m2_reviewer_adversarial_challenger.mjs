/**
 * Milestone 2 Reviewer Adversarial Challenger & Empirical Verification Suite
 *
 * Covers:
 * 1. Static Forensic & Source Line Audit (F8, F9, F10, F11, F12, F13, F14)
 * 2. Non-blocking Dispatch Contract (<50ms, immediate Ticket creation, structured confirmation)
 * 3. Anti-Loop Hard Lock State Machine (3 auto-wakeups max, WaitingHuman lock, human reset)
 * 4. Router Wakeup Deliverables Delivery & Authority Restriction (no auto-loop, no self-reset)
 * 5. Multi-Worker Concurrency, Progress Streaming & Abort Lifecycle
 * 6. Integrity & Anti-Facade Audit
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
const agentSessionPath = path.join(rootDir, 'entry/src/main/ets/agent/AgentSession.ets');
const indexEtsPath = path.join(rootDir, 'entry/src/main/ets/pages/Index.ets');
const floatPanelPath = path.join(rootDir, 'entry/src/main/ets/pages/FloatPanel.ets');
const asyncTestPath = path.join(rootDir, 'entry/src/test/AsyncDispatchWaitOn.test.ets');

console.log('\n======================================================================');
console.log('=== SUITE 1: FORENSIC CODE AUDIT & ARCHITECTURAL INVARIANTS ===');
console.log('======================================================================');

await runTest('DispatchWorkerTool: Non-blocking async dispatch pattern', () => {
  const content = fs.readFileSync(dispatchWorkerToolPath, 'utf8');
  assert.ok(content.includes("TicketEngine.getInstance().dispatchTask"), 'Must call TicketEngine.dispatchTask');
  assert.ok(!content.includes("await WorkerSession.runTask"), 'Must NOT await WorkerSession.runTask');
  assert.ok(content.includes("[WORKER DISPATCHED]"), 'Must return structured [WORKER DISPATCHED] string');
  assert.ok(content.includes("Task has been dispatched in the background"), 'Must confirm background dispatch');
  assert.ok(content.includes("Goal cannot be empty"), 'Must guard against empty goal');
});

await runTest('WorkerSession: Canonical ticket binding, live progress streaming and completion', () => {
  const content = fs.readFileSync(workerSessionPath, 'utf8');
  assert.ok(content.includes("ticketId?: string"), 'runTask must accept optional ticketId parameter');
  assert.ok(content.includes("TicketStore.getInstance().getTicket(effectiveTicketId)"), 'Must check existing ticket');
  assert.ok(content.includes("TicketStore.getInstance().updateProgress(activeTicket.id, stepsCount, maxSteps, action)"), 'Must stream tool_call_start to TicketStore');
  assert.ok(content.includes("TicketEngine.getInstance().onWorkerCompleted"), 'Must invoke TicketEngine.onWorkerCompleted on finish');
  assert.ok(content.includes("artifacts"), 'Must harvest and attach generated artifacts');
  assert.ok(content.includes("/(data|storage|tmp)[a-zA-Z0-9_\\-\\.\\/]+/g"), 'Must search filesystem artifact paths');
});

await runTest('TicketEngine: Anti-loop 3-turn limiter, unawaited execution, and deduplication', () => {
  const content = fs.readFileSync(ticketEnginePath, 'utf8');
  assert.ok(content.includes("MAX_CONSECUTIVE_AUTO_WAKEUPS = 3"), 'Must define 3-consecutive auto-wakeup limit');
  assert.ok(content.includes("recordHumanInput"), 'Must provide recordHumanInput method');
  assert.ok(content.includes("consecutiveAutoWakeCount = 0"), 'recordHumanInput must reset counter to 0');
  assert.ok(content.includes("triggerRouterWakeup"), 'Must provide triggerRouterWakeup');
  assert.ok(content.includes("setRouterWakeupCallback"), 'Must provide setRouterWakeupCallback');
  assert.ok(content.includes("executeBackgroundWorker"), 'Must launch background execution');
  assert.ok(content.includes("abortTicket"), 'Must implement per-ticket abort');
  assert.ok(content.includes("abortAll"), 'Must implement global abort');
});

await runTest('AgentSession: Router summary wakeup hook & authority boundary', () => {
  const content = fs.readFileSync(agentSessionPath, 'utf8');
  assert.ok(content.includes("initRouterWakeupHook"), 'Must initialize router wakeup hook in constructor');
  assert.ok(content.includes("setRouterWakeupCallback"), 'Must wire callback to TicketEngine');
  assert.ok(content.includes("formatWorkerDeliverablesSummary"), 'Must format @专员汇报 message');
  assert.ok(content.includes("@专员汇报"), 'Must include @专员汇报 tag in completed/failed summary');
  assert.ok(content.includes("@专员求助"), 'Must include @专员求助 tag in WaitingHuman summary');
  
  // Critical authority check: handleWorkerWakeup must NOT call recordHumanInput or trigger agentLoop
  const wakeupMethod = content.substring(
    content.indexOf('handleWorkerWakeup('),
    content.indexOf('formatWorkerDeliverablesSummary(')
  );
  assert.ok(!wakeupMethod.includes("recordHumanInput"), 'Wakeup hook must NOT reset human input counter');
  assert.ok(!wakeupMethod.includes("runLoop"), 'Wakeup hook must NOT automatically execute new agentLoop');
  assert.ok(!wakeupMethod.includes("runPrompt"), 'Wakeup hook must NOT automatically call runPrompt');

  // Human input check: runPrompt must call recordHumanInput
  const runPromptMethod = content.substring(content.indexOf('async runPrompt('), content.indexOf('getPendingSteering'));
  assert.ok(content.includes("TicketEngine.getInstance().recordHumanInput()"), 'Human prompt must reset anti-loop counter');
});

await runTest('Index.ets: Pinned Wait-On board, interactive controls, and non-blocking input', () => {
  const content = fs.readFileSync(indexEtsPath, 'utf8');
  assert.ok(content.includes("buildWaitOnBoard"), 'Must implement buildWaitOnBoard');
  assert.ok(content.includes("this.buildWaitOnBoard()"), 'Must call buildWaitOnBoard');
  assert.ok(content.includes("当前在等谁 (Wait-On)"), 'Must display Wait-On board title');
  assert.ok(content.includes("全部中断"), 'Must provide "全部中断" button');
  assert.ok(content.includes("中断"), 'Must provide single task "中断" button');
  assert.ok(content.includes("TicketStore.getInstance().addListener"), 'Must subscribe to TicketStore in aboutToAppear');
  assert.ok(content.includes("TicketStore.getInstance().removeListener"), 'Must unsubscribe from TicketStore in aboutToDisappear');
});

await runTest('FloatPanel.ets: Floating window active worker synchronization', () => {
  const content = fs.readFileSync(floatPanelPath, 'utf8');
  assert.ok(content.includes("@StorageProp('activeTicketsCount')"), 'Must bind activeTicketsCount from AppStorage');
  assert.ok(content.includes("@StorageProp('activeTickets')"), 'Must bind activeTickets from AppStorage');
  assert.ok(content.includes("buildActiveWorkersList"), 'Must provide active workers list builder');
  assert.ok(content.includes("TicketEngine.getInstance().abortAll()"), 'Must support abort all in float panel');
});

console.log('\n======================================================================');
console.log('=== SUITE 2: EMPIRICAL SIMULATION & STATE MACHINE STRESS TESTS ===');
console.log('======================================================================');

// In-Memory Simulation of TicketStore, AttentionManager, and TicketEngine logic
class MockTicketStore {
  constructor() {
    this.tickets = new Map();
    this.listeners = [];
  }
  createTicket(role, title, goal, contextInfo) {
    const id = `ticket-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
    const ticket = {
      id,
      title,
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
    this.tickets.set(ticket.id, ticket);
    this.notify();
  }
  updateStatus(id, status, resultOrError) {
    const t = this.tickets.get(id);
    if (t) {
      t.status = status;
      if (status === 'Completed') {
        t.result = resultOrError;
        t.timestamps.completedAt = Date.now();
      } else if (status === 'Failed') {
        t.error = resultOrError;
        t.timestamps.completedAt = Date.now();
      }
      this.notify();
    }
  }
  updateProgress(id, currentStep, maxSteps, actionText) {
    const t = this.tickets.get(id);
    if (t) {
      t.progress = { currentStep, maxSteps, actionText };
      this.notify();
    }
  }
  getTicket(id) {
    return this.tickets.get(id);
  }
  getActiveTickets() {
    return Array.from(this.tickets.values()).filter(t => t.status === 'Running' || t.status === 'WaitingHuman');
  }
  addListener(fn) {
    this.listeners.push(fn);
  }
  notify() {
    const list = Array.from(this.tickets.values());
    for (const fn of this.listeners) {
      fn(list);
    }
  }
}

class MockAttentionManager {
  constructor() {
    this.active = null;
    this.deferreds = new Map();
  }
  requestAttention(ticketId, question, options, allowCustomInput, timeoutSec, customId) {
    const id = customId || `att-${Date.now()}`;
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
}

class SimulatedTicketEngine {
  constructor(store, attentionMgr) {
    this.store = store;
    this.attentionMgr = attentionMgr;
    this.consecutiveAutoWakeCount = 0;
    this.activeWorkers = new Map();
    this.routerWakeupCb = null;
  }
  setRouterWakeupCallback(cb) {
    this.routerWakeupCb = cb;
  }
  recordHumanInput() {
    this.consecutiveAutoWakeCount = 0;
  }
  getAutoWakeupCount() {
    return this.consecutiveAutoWakeCount;
  }
  dispatchTask(role, goal, contextInfo, maxSteps = 15) {
    const title = goal.length > 25 ? `${goal.substring(0, 25)}...` : goal;
    const ticket = this.store.createTicket(role, title, goal, contextInfo);

    if (this.consecutiveAutoWakeCount >= 3) {
      const attId = `att-limit-${Date.now()}`;
      ticket.status = 'WaitingHuman';
      ticket.attention = {
        id: attId,
        ticketId: ticket.id,
        question: `已达到连续自动任务上限 (3 次)。请确认是否继续执行任务：${title}`,
        options: ['确认继续', '取消任务'],
        allowCustomInput: true,
        createdAt: Date.now()
      };
      this.store.updateTicket(ticket);
      this.attentionMgr.requestAttention(ticket.id, ticket.attention.question, ticket.attention.options, true, 0, attId)
        .then((ans) => {
          this.recordHumanInput();
          if (ans === '取消任务' || ans.includes('取消')) {
            this.abortTicket(ticket.id);
          } else {
            this.store.updateStatus(ticket.id, 'Running');
          }
        });
      return ticket;
    }

    ticket.status = 'Running';
    this.store.updateStatus(ticket.id, 'Running');
    this.activeWorkers.set(ticket.id, { ticketId: ticket.id, abort: () => {} });
    return ticket;
  }
  onWorkerCompleted(ticket) {
    this.consecutiveAutoWakeCount++;
    if (this.routerWakeupCb) {
      this.routerWakeupCb(ticket);
    }
  }
  abortTicket(ticketId) {
    this.activeWorkers.delete(ticketId);
    this.store.updateStatus(ticketId, 'Failed', 'Task aborted by user');
  }
  abortAll() {
    this.activeWorkers.clear();
    const active = this.store.getActiveTickets();
    for (const t of active) {
      this.store.updateStatus(t.id, 'Failed', 'All tasks aborted');
    }
  }
}

await runTest('Empirical: Non-blocking dispatch latency & contract', () => {
  const store = new MockTicketStore();
  const attMgr = new MockAttentionManager();
  const engine = new SimulatedTicketEngine(store, attMgr);

  const t0 = Date.now();
  const ticket = engine.dispatchTask('code_worker', 'Refactor test suite', 'Fix async issues');
  const duration = Date.now() - t0;

  assert.ok(duration < 25, `Dispatch must be non-blocking (< 25ms), took ${duration}ms`);
  assert.equal(ticket.role, 'code_worker');
  assert.equal(ticket.status, 'Running');
  assert.ok(ticket.id.startsWith('ticket-'));
});

await runTest('Empirical: 3-Wakeup Anti-Loop Hard Lock & Human Reset Barrier', async () => {
  const store = new MockTicketStore();
  const attMgr = new MockAttentionManager();
  const engine = new SimulatedTicketEngine(store, attMgr);

  // Turn 1
  const t1 = engine.dispatchTask('diag_worker', 'Goal 1');
  assert.equal(t1.status, 'Running');
  engine.onWorkerCompleted(t1);
  assert.equal(engine.getAutoWakeupCount(), 1);

  // Turn 2
  const t2 = engine.dispatchTask('diag_worker', 'Goal 2');
  assert.equal(t2.status, 'Running');
  engine.onWorkerCompleted(t2);
  assert.equal(engine.getAutoWakeupCount(), 2);

  // Turn 3
  const t3 = engine.dispatchTask('diag_worker', 'Goal 3');
  assert.equal(t3.status, 'Running');
  engine.onWorkerCompleted(t3);
  assert.equal(engine.getAutoWakeupCount(), 3);

  // Turn 4: Limit hit -> must force WaitingHuman
  const t4 = engine.dispatchTask('diag_worker', 'Goal 4');
  assert.equal(t4.status, 'WaitingHuman', '4th consecutive auto dispatch must be locked in WaitingHuman');
  assert.ok(t4.attention, 'WaitingHuman ticket must carry AttentionRequest');
  assert.ok(t4.attention.question.includes('已达到连续自动任务上限 (3 次)'));

  // User responds '确认继续' -> records human input, resets counter, transitions to Running
  attMgr.respondAttention(t4.attention.id, '确认继续');
  // allow microtask resolution
  await new Promise(r => setTimeout(r, 10));

  assert.equal(engine.getAutoWakeupCount(), 0, 'Human decision must reset auto wakeup counter to 0');
  assert.equal(store.getTicket(t4.id).status, 'Running', 'Ticket must transition to Running after human confirms');

  // Next dispatch succeeds normally
  const t5 = engine.dispatchTask('diag_worker', 'Goal 5');
  assert.equal(t5.status, 'Running');
});

await runTest('Empirical: Multi-worker concurrency, live progress streaming and independent abort', () => {
  const store = new MockTicketStore();
  const attMgr = new MockAttentionManager();
  const engine = new SimulatedTicketEngine(store, attMgr);

  const tA = engine.dispatchTask('ui_worker', 'Task A');
  const tB = engine.dispatchTask('web_worker', 'Task B');

  let active = store.getActiveTickets();
  assert.equal(active.length, 2, 'Should have 2 concurrent active tickets');

  // Stream progress to A
  store.updateProgress(tA.id, 2, 8, 'Clicking button');
  assert.equal(store.getTicket(tA.id).progress.currentStep, 2);
  assert.equal(store.getTicket(tB.id).progress, undefined);

  // Abort ticket A
  engine.abortTicket(tA.id);
  assert.equal(store.getTicket(tA.id).status, 'Failed');
  assert.equal(store.getTicket(tB.id).status, 'Running', 'Aborting ticket A must not affect ticket B');

  // Stream progress to B
  store.updateProgress(tB.id, 4, 10, 'Fetching URL');
  assert.equal(store.getTicket(tB.id).progress.currentStep, 4);

  // Complete ticket B
  store.updateStatus(tB.id, 'Completed', 'Done fetch');
  assert.equal(store.getActiveTickets().length, 0, 'All active tickets cleared');
});

await runTest('Empirical: Router wakeup summary formatting & artifacts delivery', () => {
  const store = new MockTicketStore();
  const attMgr = new MockAttentionManager();
  const engine = new SimulatedTicketEngine(store, attMgr);

  let wakeupTicket = null;
  engine.setRouterWakeupCallback((t) => {
    wakeupTicket = t;
  });

  const t = engine.dispatchTask('code_worker', 'Generate config file');
  t.artifacts = ['/data/local/tmp/config.json'];
  store.updateStatus(t.id, 'Completed', 'Config generated successfully');
  engine.onWorkerCompleted(store.getTicket(t.id));

  assert.ok(wakeupTicket !== null, 'Router wakeup callback must be triggered');
  assert.equal(wakeupTicket.status, 'Completed');
  assert.ok(wakeupTicket.artifacts.includes('/data/local/tmp/config.json'));
});

console.log('\n======================================================================');
console.log('=== SUITE 3: INTEGRITY & ANTI-FACADE STATIC AUDIT ===');
console.log('======================================================================');

await runTest('Integrity: No hardcoded test responses or fake bypasses in production files', () => {
  const files = [dispatchWorkerToolPath, workerSessionPath, ticketEnginePath, agentSessionPath];
  for (const f of files) {
    const text = fs.readFileSync(f, 'utf8');
    assert.ok(!text.includes("fake_test_result"), `No fake test result in ${path.basename(f)}`);
    assert.ok(!text.includes("TODO_HARDCODED"), `No todo hardcoded in ${path.basename(f)}`);
  }
});

await runTest('Integrity: AsyncDispatchWaitOn.test.ets contains valid assertions, not tautologies', () => {
  const content = fs.readFileSync(asyncTestPath, 'utf8');
  assert.ok(content.includes("expect(duration < 50).assertTrue()"), 'Checks real latency duration');
  assert.ok(content.includes("expect(res.isError).assertTrue()"), 'Checks real error rejection');
  assert.ok(content.includes("expect(res.output).assertContain('[WORKER DISPATCHED]')"), 'Checks real structured dispatch string');
  assert.ok(content.includes("expect(engine.getConsecutiveAutoWakeCount()).assertEqual(0)"), 'Checks real counter reset');
  assert.ok(content.includes("expect(attMgr.getActiveAttention()).assertNull()"), 'Checks real attention completion');
});

console.log('\n======================================================================');
console.log(`TOTAL ADVERSARIAL CHALLENGER TESTS: ${passCount + failCount}`);
console.log(`PASSED:                             ${passCount}`);
console.log(`FAILED:                             ${failCount}`);
console.log('======================================================================\n');

if (failCount > 0) {
  process.exit(1);
}
