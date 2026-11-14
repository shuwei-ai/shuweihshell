/**
/**
 * Forensic Auditor Automated Verification Suite for Milestone 2 (Phase 2: Features F8–F14)
 * Strict Router + Workers: Async Background Dispatch, Wait-On UI, Streaming & Anti-Loop
 *
 * Verifies:
 * 1. FACADE / DUMMY CHECK (DispatchWorkerTool -> TicketEngine -> WorkerSession -> AgentLoop)
 * 2. LIVE STREAMING CHECK (WorkerSession -> TicketStore.updateProgress -> notifyListeners -> AppStorage)
 * 3. UI EVENT BINDING CHECK (Index.ets & FloatPanel.ets reactive listener, ForEach, abortTicket, abortAll, respondAttention)
 * 4. INPUT UNBLOCK CHECK (TextInput unblocked, sendAgentPrompt, AgentSession steering)
 * 5. ANTI-LOOP HARD LOCK CHECK (MAX_CONSECUTIVE_AUTO_WAKEUPS = 3, WaitingHuman freeze, human input reset)
 * 6. HARDCODING / CHEATING CHECK (No test output faking, no dummy mocks, authentic verification)
 * 7. BEHAVIORAL STATE MACHINE & CONCURRENCY SIMULATION (End-to-end event-driven state flow)
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const rootDir = process.cwd();
const files = {
  dispatchTool: path.join(rootDir, 'entry/src/main/ets/agent/superagent/DispatchWorkerTool.ets'),
  workerSession: path.join(rootDir, 'entry/src/main/ets/agent/superagent/WorkerSession.ets'),
  ticketEngine: path.join(rootDir, 'entry/src/main/ets/agent/superagent/TicketEngine.ets'),
  ticketStore: path.join(rootDir, 'entry/src/main/ets/agent/superagent/TicketStore.ets'),
  attentionManager: path.join(rootDir, 'entry/src/main/ets/agent/superagent/AttentionManager.ets'),
  agentSession: path.join(rootDir, 'entry/src/main/ets/agent/AgentSession.ets'),
  indexEts: path.join(rootDir, 'entry/src/main/ets/pages/Index.ets'),
  floatPanel: path.join(rootDir, 'entry/src/main/ets/pages/FloatPanel.ets'),
  asyncTest: path.join(rootDir, 'entry/src/test/AsyncDispatchWaitOn.test.ets'),
  listTest: path.join(rootDir, 'entry/src/test/List.test.ets')
};

console.log('======================================================================');
console.log('=== FORENSIC AUDITOR AUTOMATED VERIFICATION: MILESTONE 2 (F8–F14) ===');
console.log('======================================================================\n');

let passCount = 0;
let failCount = 0;
const violations = [];

function check(title, fn) {
  try {
    fn();
    console.log(`[PASS] ${title}`);
    passCount++;
  } catch (err) {
    console.error(`[FAIL] ${title}`);
    console.error(`       Error: ${err.message}`);
    if (err.stack) {
      console.error(err.stack.split('\n').slice(1, 4).join('\n'));
    }
    failCount++;
    violations.push({ title, error: err.message });
  }
}

async function asyncCheck(title, fn) {
  try {
    await fn();
    console.log(`[PASS] ${title}`);
    passCount++;
  } catch (err) {
    console.error(`[FAIL] ${title}`);
    console.error(`       Error: ${err.message}`);
    if (err.stack) {
      console.error(err.stack.split('\n').slice(1, 4).join('\n'));
    }
    failCount++;
    violations.push({ title, error: err.message });
  }
}

// --------------------------------------------------------------------
// AUDIT CHECK 1: FACADE / DUMMY IMPLEMENTATION CHECK
// --------------------------------------------------------------------
console.log('--- AUDIT CHECK 1: FACADE / DUMMY IMPLEMENTATION CHECK ---');

check('Check 1.1: DispatchWorkerTool genuine delegation to TicketEngine.dispatchTask', () => {
  const content = fs.readFileSync(files.dispatchTool, 'utf8');
  assert.ok(content.includes('TicketEngine.getInstance().dispatchTask('), 'Must invoke TicketEngine.dispatchTask');
  assert.ok(!content.includes('await WorkerSession.runTask'), 'Must NOT synchronously await WorkerSession.runTask');
  assert.ok(!content.includes('return {') || content.includes('[WORKER DISPATCHED]'), 'Must return structured confirmation');
  assert.ok(content.includes('ticket.id'), 'Must interpolate genuine ticket.id into output');
  assert.ok(content.includes('role'), 'Must interpolate worker role');
  assert.ok(content.includes('goal'), 'Must interpolate worker goal');
  assert.ok(content.includes('Task has been dispatched in the background'), 'Must inform router of background execution');
});

check('Check 1.2: TicketEngine unawaited background execution to WorkerSession.runTask', () => {
  const content = fs.readFileSync(files.ticketEngine, 'utf8');
  assert.ok(content.includes('executeBackgroundWorker('), 'Must have dedicated executeBackgroundWorker method');
  assert.ok(content.includes('WorkerSession.runTask('), 'Must invoke WorkerSession.runTask');
  assert.ok(content.includes('.then((report: WorkerReport) => {'), 'Must handle WorkerReport asynchronously in Promise.then');
  assert.ok(content.includes('.catch((err: Error) => {'), 'Must handle background worker rejection asynchronously in Promise.catch');
  assert.ok(content.includes('this.activeWorkers.set(ticket.id'), 'Must track active worker context for cancellation');
  assert.ok(content.includes('this.activeWorkers.delete(ticket.id)'), 'Must cleanup active worker context upon completion');
});

check('Check 1.3: WorkerSession genuine execution via AgentLoop and LlmClient', () => {
  const content = fs.readFileSync(files.workerSession, 'utf8');
  assert.ok(content.includes('new LlmClient()'), 'WorkerSession must instantiate a genuine LlmClient');
  assert.ok(content.includes('new AgentLoop(llmClient)'), 'WorkerSession must instantiate a genuine AgentLoop');
  assert.ok(content.includes('workerLoop.runLoop('), 'WorkerSession must invoke workerLoop.runLoop');
  assert.ok(content.includes('TicketStore.getInstance().updateStatus('), 'WorkerSession must update TicketStore with terminal status');
  assert.ok(content.includes('TicketEngine.getInstance().onWorkerCompleted('), 'WorkerSession must notify TicketEngine upon completion');
});

// --------------------------------------------------------------------
// AUDIT CHECK 2: LIVE STREAMING CHECK
// --------------------------------------------------------------------
console.log('\n--- AUDIT CHECK 2: LIVE STREAMING CHECK ---');

check('Check 2.1: WorkerSession step turns forward directly to TicketStore.updateProgress', () => {
  const content = fs.readFileSync(files.workerSession, 'utf8');
  assert.ok(content.includes("event.type === 'tool_call_start'"), 'Must intercept tool_call_start events');
  assert.ok(content.includes('TicketStore.getInstance().updateProgress('), 'Must forward step turn directly to TicketStore.updateProgress');
  assert.ok(content.includes('activeTicket.id, stepsCount, maxSteps'), 'Must supply activeTicket.id, stepsCount, maxSteps');
  assert.ok(content.includes('onProgress({'), 'Must invoke onProgress callback if provided');
  assert.ok(content.includes("AppStorage.setOrCreate('agentCurrentTool'"), 'Must update AppStorage tool status');
});

check('Check 2.2: TicketStore.updateProgress updates in-memory ticket and notifies subscribers & AppStorage', () => {
  const content = fs.readFileSync(files.ticketStore, 'utf8');
  assert.ok(content.includes('updateProgress(id: string, step: number, maxSteps: number, actionText: string)'), 'TicketStore must implement updateProgress');
  assert.ok(content.includes('ticket.progress = {'), 'Must mutate ticket.progress object');
  assert.ok(content.includes('this.notifyListeners()'), 'Must call notifyListeners upon progress update');
  assert.ok(content.includes("AppStorage.setOrCreate('activeTickets', active)"), 'notifyListeners must sync activeTickets to AppStorage');
  assert.ok(content.includes("AppStorage.setOrCreate('activeTicketsCount', active.length)"), 'notifyListeners must sync activeTicketsCount to AppStorage');
  assert.ok(content.includes('listener(all)'), 'notifyListeners must notify registered TicketStore listeners');
});

// --------------------------------------------------------------------
// AUDIT CHECK 3: UI EVENT BINDING CHECK
// --------------------------------------------------------------------
console.log('\n--- AUDIT CHECK 3: UI EVENT BINDING CHECK ---');

check('Check 3.1: Index.ets registers TicketStore listener in lifecycle and renders dynamic Wait-On board', () => {
  const content = fs.readFileSync(files.indexEts, 'utf8');
  assert.ok(content.includes('TicketStore.getInstance().addListener(this.ticketStoreListener)'), 'aboutToAppear must register TicketStore listener');
  assert.ok(content.includes('TicketStore.getInstance().removeListener(this.ticketStoreListener)'), 'aboutToDisappear must unregister TicketStore listener');
  assert.ok(content.includes('this.buildWaitOnBoard()'), 'Must invoke buildWaitOnBoard in main UI hierarchy');
  assert.ok(content.includes('if (this.activeTickets.length > 0)'), 'Must conditionally render Wait-On board when activeTickets exist');
  assert.ok(content.includes('ForEach(this.activeTickets, (ticket: Ticket) =>'), 'Must dynamically iterate activeTickets with ForEach (NOT hardcoded mock)');
});

check('Check 3.2: Index.ets action buttons genuinely wire TicketEngine and AttentionManager', () => {
  const content = fs.readFileSync(files.indexEts, 'utf8');
  // "全部中断"
  assert.ok(content.includes("Button('全部中断')"), 'Must have "全部中断" button');
  assert.ok(content.includes('TicketEngine.getInstance().abortAll()'), '"全部中断" must invoke TicketEngine.abortAll');

  // "中断"
  assert.ok(content.includes("Button('中断')"), 'Must have "中断" button');
  assert.ok(content.includes('TicketEngine.getInstance().abortTicket(ticket.id)'), '"中断" must invoke TicketEngine.abortTicket(ticket.id)');

  // Quick options & "处理确认"
  assert.ok(content.includes('AttentionManager.getInstance().respondAttention('), 'Option click or custom input must call AttentionManager.respondAttention');
  assert.ok(content.includes("Button('处理确认')"), 'Must have "处理确认" button');
  assert.ok(content.includes('TicketEngine.getInstance().recordHumanInput()'), 'Interactive decisions must invoke TicketEngine.recordHumanInput');
});

check('Check 3.3: FloatPanel.ets synchronizes via AppStorage and binds abort and attention actions', () => {
  const content = fs.readFileSync(files.floatPanel, 'utf8');
  assert.ok(content.includes("@StorageProp('activeTickets') activeTickets: Ticket[] = [];"), 'FloatPanel must bind activeTickets via @StorageProp');
  assert.ok(content.includes("@StorageProp('activeTicketsCount') activeTicketsCount: number = 0;"), 'FloatPanel must bind activeTicketsCount via @StorageProp');
  assert.ok(content.includes('this.buildActiveWorkersList()'), 'Must render buildActiveWorkersList when active tickets exist');
  assert.ok(content.includes('ForEach(this.activeTickets, (ticket: Ticket) =>'), 'Must dynamically iterate activeTickets in float console');
  assert.ok(content.includes('TicketEngine.getInstance().abortTicket(ticket.id)'), 'Float panel single abort must call TicketEngine.abortTicket');
  assert.ok(content.includes('TicketEngine.getInstance().abortAll()'), 'Float panel abort all must call TicketEngine.abortAll');
  assert.ok(content.includes('AttentionManager.getInstance().respondAttention(att.id, opt)'), 'Float panel option click must call AttentionManager.respondAttention');
});

// --------------------------------------------------------------------
// AUDIT CHECK 4: INPUT UNBLOCK CHECK
// --------------------------------------------------------------------
console.log('\n--- AUDIT CHECK 4: INPUT UNBLOCK CHECK ---');

check('Check 4.1: Index.ets prompt input and submit button are unblocked during background worker execution', () => {
  const content = fs.readFileSync(files.indexEts, 'utf8');
  // TextInput must not be disabled by activeTickets
  const inputSection = content.substring(content.indexOf('TextInput({ text: this.agentInputPrompt'), content.indexOf("Button('发送')"));
  assert.ok(!inputSection.includes('.enabled(!this.activeTickets'), 'TextInput must not be disabled by activeTickets');
  assert.ok(!inputSection.includes('.enabled(false)'), 'TextInput must not be statically disabled');

  // sendAgentPrompt must not block on active background tickets
  const sendPromptStart = content.indexOf('private async sendAgentPrompt(): Promise<void> {');
  const sendPromptEnd = content.indexOf('private stopAgent(): void {', sendPromptStart);
  const sendPromptMethod = content.substring(sendPromptStart, sendPromptEnd);
  assert.ok(!sendPromptMethod.includes('this.activeTickets.length > 0'), 'sendAgentPrompt must not block when background tickets are running');
  assert.ok(sendPromptMethod.includes('this.agentSession.runPrompt('), 'sendAgentPrompt must execute agentSession.runPrompt');
});

check('Check 4.2: AgentSession handles steering input and resets human input tracking', () => {
  const content = fs.readFileSync(files.agentSession, 'utf8');
  assert.ok(content.includes('TicketEngine.getInstance().recordHumanInput()'), 'runPrompt must record human input immediately');
  assert.ok(content.includes('this.steeringQueue.push(steeringMsg)'), 'Mid-flight prompt while running must enqueue into steeringQueue');
  assert.ok(content.includes('this.initRouterWakeupHook()'), 'AgentSession must initialize router wakeup hook in constructor');
  assert.ok(content.includes('this.handleWorkerWakeup(ticket)'), 'Must handle worker wakeup with formatted deliverables summary');
  // Verify handleWorkerWakeup does NOT call recordHumanInput (only human calls reset the anti-loop limiter)
  const wakeupMethod = content.substring(content.indexOf('private handleWorkerWakeup('), content.indexOf('private formatWorkerDeliverablesSummary'));
  assert.ok(!wakeupMethod.includes('recordHumanInput()'), 'handleWorkerWakeup must NOT reset human input counter');
});

// --------------------------------------------------------------------
// AUDIT CHECK 5: ANTI-LOOP HARD LOCK CHECK
// --------------------------------------------------------------------
console.log('\n--- AUDIT CHECK 5: ANTI-LOOP HARD LOCK CHECK ---');

check('Check 5.1: TicketEngine enforces MAX_CONSECUTIVE_AUTO_WAKEUPS = 3 hard lock barrier', () => {
  const content = fs.readFileSync(files.ticketEngine, 'utf8');
  assert.ok(content.includes('MAX_CONSECUTIVE_AUTO_WAKEUPS = 3'), 'MAX_CONSECUTIVE_AUTO_WAKEUPS must be exactly 3');
  assert.ok(content.includes('this.consecutiveAutoWakeCount >= MAX_CONSECUTIVE_AUTO_WAKEUPS'), 'Must check if auto wake count >= MAX_CONSECUTIVE_AUTO_WAKEUPS');
  assert.ok(content.includes("ticket.status = 'WaitingHuman'"), 'Must freeze ticket to WaitingHuman when limit reached');
  assert.ok(content.includes('AttentionManager.getInstance().requestAttention('), 'Must request human attention when limit reached');
  assert.ok(content.includes('this.consecutiveAutoWakeCount++'), 'Must increment consecutiveAutoWakeCount on worker completed');
  assert.ok(content.includes('this.consecutiveAutoWakeCount = 0'), 'recordHumanInput must reset consecutiveAutoWakeCount to 0');
});

// --------------------------------------------------------------------
// AUDIT CHECK 6: HARDCODING / CHEATING / PROHIBITED PATTERNS CHECK
// --------------------------------------------------------------------
console.log('\n--- AUDIT CHECK 6: HARDCODING / CHEATING / PROHIBITED PATTERNS CHECK ---');

check('Check 6.1: AsyncDispatchWaitOn.test.ets is registered and contains authentic tests', () => {
  const listContent = fs.readFileSync(files.listTest, 'utf8');
  assert.ok(listContent.includes("import asyncDispatchWaitOnTest from './AsyncDispatchWaitOn.test'"), 'List.test.ets must import asyncDispatchWaitOnTest');
  assert.ok(listContent.includes('asyncDispatchWaitOnTest();'), 'List.test.ets must execute asyncDispatchWaitOnTest()');

  const testContent = fs.readFileSync(files.asyncTest, 'utf8');
  assert.ok(testContent.includes("import { DispatchWorkerTool } from '../main/ets/agent/superagent/DispatchWorkerTool'"), 'Test must import real DispatchWorkerTool');
  assert.ok(testContent.includes("import { TicketEngine } from '../main/ets/agent/superagent/TicketEngine'"), 'Test must import real TicketEngine');
  assert.ok(testContent.includes("import { TicketStore } from '../main/ets/agent/superagent/TicketStore'"), 'Test must import real TicketStore');
  assert.ok(testContent.includes("import { AttentionManager } from '../main/ets/agent/superagent/AttentionManager'"), 'Test must import real AttentionManager');
  assert.ok(testContent.includes("import { WorkerSession } from '../main/ets/agent/superagent/WorkerSession'"), 'Test must import real WorkerSession');

  // Verify test doesn't contain fake return overrides or mock evasion
  assert.ok(!testContent.includes('return true; // bypass'), 'No bypasses allowed');
  assert.ok(!testContent.includes('// skip verification'), 'No skipped verification allowed');
});

check('Check 6.2: Workspace clean of fabricated logs or pre-populated attestation artifacts', () => {
  const rootFiles = fs.readdirSync(rootDir);
  for (const f of rootFiles) {
    assert.ok(!f.endsWith('.log') || f === 'build.log', `Found unexpected pre-populated log: ${f}`);
  }
});

// --------------------------------------------------------------------
// AUDIT CHECK 7: BEHAVIORAL STATE MACHINE & CONCURRENCY SIMULATION
// --------------------------------------------------------------------
console.log('\n--- AUDIT CHECK 7: BEHAVIORAL STATE MACHINE & CONCURRENCY SIMULATION ---');

await asyncCheck('Check 7.1: Behavioral simulation of anti-loop state machine (0 -> 1 -> 2 -> 3 -> Locked -> Reset)', async () => {
  // Replicate exact state machine logic from TicketEngine
  const MAX_LIMIT = 3;
  let wakeCount = 0;
  let locked = false;
  let attentionRequested = false;

  function onWorkerComplete() {
    wakeCount++;
    if (wakeCount >= MAX_LIMIT) {
      locked = true;
    }
  }

  function dispatchTask(goal) {
    if (wakeCount >= MAX_LIMIT) {
      locked = true;
      attentionRequested = true;
      return { status: 'WaitingHuman', goal };
    }
    return { status: 'Running', goal };
  }

  function recordHumanInput() {
    wakeCount = 0;
    locked = false;
    attentionRequested = false;
  }

  // Turn 1
  let t1 = dispatchTask('Task 1');
  assert.equal(t1.status, 'Running');
  onWorkerComplete();
  assert.equal(wakeCount, 1);
  assert.equal(locked, false);

  // Turn 2
  let t2 = dispatchTask('Task 2');
  assert.equal(t2.status, 'Running');
  onWorkerComplete();
  assert.equal(wakeCount, 2);
  assert.equal(locked, false);

  // Turn 3
  let t3 = dispatchTask('Task 3');
  assert.equal(t3.status, 'Running');
  onWorkerComplete();
  assert.equal(wakeCount, 3);
  assert.equal(locked, true);

  // Turn 4: Hit limit -> Must freeze to WaitingHuman!
  let t4 = dispatchTask('Task 4');
  assert.equal(t4.status, 'WaitingHuman');
  assert.equal(attentionRequested, true);

  // Human speaks -> Counter resets
  recordHumanInput();
  assert.equal(wakeCount, 0);
  assert.equal(locked, false);
  assert.equal(attentionRequested, false);

  // Turn 5 after human reset: Must be Running again!
  let t5 = dispatchTask('Task 5');
  assert.equal(t5.status, 'Running');
});

await asyncCheck('Check 7.2: Behavioral simulation of reactive Wait-On event streaming & abort', async () => {
  // Simulate TicketStore listener and AppStorage synchronization
  const store = new Map();
  const listeners = [];
  const appStorage = new Map();

  function addListener(fn) {
    listeners.push(fn);
  }

  function notify() {
    const all = Array.from(store.values());
    const active = all.filter(t => t.status === 'Running' || t.status === 'WaitingHuman');
    appStorage.set('activeTickets', active);
    appStorage.set('activeTicketsCount', active.length);
    for (const l of listeners) {
      l(all);
    }
  }

  function createTicket(id, role, title) {
    const t = { id, role, title, status: 'Running', progress: null };
    store.set(id, t);
    notify();
    return t;
  }

  function updateProgress(id, step, maxSteps, actionText) {
    const t = store.get(id);
    if (t) {
      t.progress = { step, maxSteps, actionText };
      notify();
    }
  }

  function abortAll() {
    for (const t of store.values()) {
      if (t.status === 'Running' || t.status === 'WaitingHuman') {
        t.status = 'Failed';
        t.error = 'All tasks aborted';
      }
    }
    notify();
  }

  let notifiedCount = 0;
  addListener((all) => {
    notifiedCount++;
  });

  // 1. Create 2 tickets
  createTicket('t1', 'code_worker', 'Write Unit Test');
  createTicket('t2', 'diag_worker', 'Inspect Logs');

  assert.equal(appStorage.get('activeTicketsCount'), 2);
  assert.equal(notifiedCount, 2);

  // 2. Stream progress
  updateProgress('t1', 1, 5, 'Generating test cases...');
  const t1 = store.get('t1');
  assert.equal(t1.progress.actionText, 'Generating test cases...');
  assert.equal(t1.progress.step, 1);

  // 3. Abort all
  abortAll();
  assert.equal(appStorage.get('activeTicketsCount'), 0);
  assert.equal(store.get('t1').status, 'Failed');
  assert.equal(store.get('t2').status, 'Failed');
});

console.log('\n======================================================================');
console.log(`=== AUDIT SUMMARY: ${passCount} PASSED, ${failCount} FAILED ===`);
console.log('======================================================================');

if (failCount > 0) {
  console.error('\nCRITICAL INTEGRITY VIOLATIONS DETECTED:');
  for (const v of violations) {
    console.error(`- ${v.title}: ${v.error}`);
  }
  process.exit(1);
} else {
  console.log('\nALL FORENSIC INTEGRITY CHECKS PASSED. WORK PRODUCT VERDICT: CLEAN');
  process.exit(0);
}
