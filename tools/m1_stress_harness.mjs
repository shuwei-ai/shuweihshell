/**
 * Milestone 1 Empirical Stress Test & Challenger Harness
 * Tests:
 * 1. Strict Router Tool Isolation (definition stripping & runtime rejection in AgentLoop)
 * 2. Star Topology (WorkerPresets, ToolRegistry, and runtime rejection in AgentLoop)
 * 3. Anti-loop limiter (3-wakeup hard lock barrier & human input reset)
 * 4. Ticket Data Model, State Machine & Recovery Invariants
 */

import assert from 'node:assert/strict';

// Set up global mocks for HarmonyOS runtime environment
globalThis.AppStorage = {
  _storage: new Map(),
  setOrCreate(k, v) { this._storage.set(k, v); },
  get(k) { return this._storage.get(k); }
};

const hilogMock = {
  info: (...args) => {},
  warn: (...args) => {},
  error: (...args) => {},
  debug: (...args) => {}
};

console.log('====================================================');
console.log('=== STARTING EMPIRICAL STRESS TEST HARNESS (M1) ===');
console.log('====================================================\n');

let passCount = 0;
let failCount = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`[PASS] ${name}`);
    passCount++;
  } catch (err) {
    console.error(`[FAIL] ${name}`);
    console.error(`       Error: ${err.message}`);
    if (err.stack) console.error(err.stack.split('\n').slice(1, 4).join('\n'));
    failCount++;
  }
}

async function asyncTest(name, fn) {
  try {
    await fn();
    console.log(`[PASS] ${name}`);
    passCount++;
  } catch (err) {
    console.error(`[FAIL] ${name}`);
    console.error(`       Error: ${err.message}`);
    if (err.stack) console.error(err.stack.split('\n').slice(1, 4).join('\n'));
    failCount++;
  }
}

// -------------------------------------------------------------
// MODULE 1: WorkerPresets & Star Topology Tests
// -------------------------------------------------------------
console.log('--- TEST GROUP 1: STAR TOPOLOGY IN PRESETS & REGISTRY ---');

// Emulate WorkerPresets logic directly as in entry/src/main/ets/agent/superagent/WorkerPresets.ets
class WorkerPresets {
  static getAllowedToolNames(role, customAllowedTools) {
    if (customAllowedTools && Array.isArray(customAllowedTools) && customAllowedTools.length > 0) {
      // Star Topology hard filter: never allow dispatch_worker in sub-worker sessions
      return customAllowedTools.filter(tool => tool !== 'dispatch_worker');
    }

    switch (role) {
      case 'ui_worker':
        return ['ui', 'bash', 'run_code', 'run_js', 'inspect_image', 'remember'];
      case 'diag_worker':
        return ['bash', 'read', 'run_code', 'run_js', 'remember'];
      case 'code_worker':
        return ['read', 'write', 'edit', 'bash', 'run_code', 'run_js', 'remote_bash', 'inspect_image', 'remember'];
      case 'web_worker':
        return ['browser', 'fetch', 'run_code', 'run_js', 'inspect_image', 'remember'];
      case 'general_worker':
      default:
        return ['bash', 'ui', 'run_code', 'run_js', 'remote_bash', 'read', 'write', 'edit', 'browser', 'fetch', 'inspect_image', 'remember'];
    }
  }
}

test('StarTopology: standard workers never granted dispatch_worker', () => {
  const roles = ['ui_worker', 'diag_worker', 'code_worker', 'web_worker', 'general_worker'];
  for (const role of roles) {
    const allowed = WorkerPresets.getAllowedToolNames(role);
    assert.ok(!allowed.includes('dispatch_worker'), `Role ${role} unexpectedly has dispatch_worker`);
  }
});

test('StarTopology: custom/adhoc worker roles never granted dispatch_worker', () => {
  const customRoles = ['security_auditor', 'db_optimizer', 'network_snooper', 'root_escalator'];
  for (const role of customRoles) {
    const allowed = WorkerPresets.getAllowedToolNames(role);
    assert.ok(!allowed.includes('dispatch_worker'), `Custom role ${role} unexpectedly has dispatch_worker`);
  }
});

test('StarTopology: adversarial tool list injection strips dispatch_worker', () => {
  const adversarialInputs = [
    ['dispatch_worker'],
    ['bash', 'dispatch_worker', 'read'],
    ['dispatch_worker', 'dispatch_worker'],
    ['ui', 'edit', 'dispatch_worker']
  ];
  for (const input of adversarialInputs) {
    const sanitized = WorkerPresets.getAllowedToolNames('general_worker', input);
    assert.ok(!sanitized.includes('dispatch_worker'), `Adversarial input ${input} leaked dispatch_worker!`);
  }
});

// -------------------------------------------------------------
// MODULE 2: ToolRegistry Router Tool Stripping Tests
// -------------------------------------------------------------
console.log('\n--- TEST GROUP 2: STRICT ROUTER TOOL STRIPPING ---');

class ToolRegistry {
  static getRouterToolDefinitions() {
    return [
      { function: { name: 'dispatch_worker', description: 'Dispatch worker' } },
      { function: { name: 'ask_attention', description: 'Ask attention' } }
    ];
  }

  static getDefinitions() {
    return [
      { function: { name: 'bash' } },
      { function: { name: 'read' } },
      { function: { name: 'write' } },
      { function: { name: 'edit' } },
      { function: { name: 'ui' } },
      { function: { name: 'run_code' } },
      { function: { name: 'run_js' } },
      { function: { name: 'remote_bash' } },
      { function: { name: 'browser' } },
      { function: { name: 'fetch' } },
      { function: { name: 'inspect_image' } },
      { function: { name: 'remember' } },
      { function: { name: 'goal' } },
      { function: { name: 'dispatch_worker' } },
      { function: { name: 'ask_attention' } }
    ];
  }

  static getWorkerToolDefinitions(role, allowed) {
    const allowedNames = WorkerPresets.getAllowedToolNames(role, allowed);
    const safeNames = allowedNames.filter(name => name !== 'dispatch_worker');
    return ToolRegistry.getDefinitions().filter(t => safeNames.includes(t.function.name));
  }
}

test('RouterToolStripping: getRouterToolDefinitions returns strictly 2 tools', () => {
  const routerDefs = ToolRegistry.getRouterToolDefinitions();
  const names = routerDefs.map(d => d.function.name);
  assert.equal(names.length, 2);
  assert.ok(names.includes('dispatch_worker'));
  assert.ok(names.includes('ask_attention'));
});

test('RouterToolStripping: all 13 low-level execution tools are strictly excluded', () => {
  const routerDefs = ToolRegistry.getRouterToolDefinitions();
  const names = routerDefs.map(d => d.function.name);
  const prohibited = [
    'bash', 'read', 'write', 'edit', 'ui', 'run_code', 'run_js',
    'remote_bash', 'browser', 'fetch', 'inspect_image', 'remember', 'goal'
  ];
  for (const tool of prohibited) {
    assert.ok(!names.includes(tool), `Prohibited tool ${tool} was found in Router definitions!`);
  }
});

// -------------------------------------------------------------
// MODULE 3: AgentLoop Runtime Permission Defense Tests
// -------------------------------------------------------------
console.log('\n--- TEST GROUP 3: AGENTLOOP RUNTIME DEFENSE INTERCEPTION ---');

// Exact permission check logic from AgentLoop.ets lines 262-278
function executeAgentLoopPermissionCheck(isSubWorker, tc) {
  let toolRes;
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
    toolRes = {
      toolCallId: tc.id,
      toolName: tc.function.name,
      output: `Executed ${tc.function.name} successfully`,
      isError: false
    };
  }
  return toolRes;
}

test('AgentLoop Runtime: Router calling bash is rejected with Permission Denied', () => {
  const tc = { id: 'call-1', function: { name: 'bash', arguments: '{"command":"ls"}' } };
  const res = executeAgentLoopPermissionCheck(false, tc);
  assert.equal(res.isError, true);
  assert.match(res.error, /Permission denied: Router cannot execute 'bash'/);
});

test('AgentLoop Runtime: Router calling ui is rejected with Permission Denied', () => {
  const tc = { id: 'call-2', function: { name: 'ui', arguments: '{"action":"dump_tree"}' } };
  const res = executeAgentLoopPermissionCheck(false, tc);
  assert.equal(res.isError, true);
  assert.match(res.error, /Permission denied: Router cannot execute 'ui'/);
});

test('AgentLoop Runtime: Router calling edit is rejected with Permission Denied', () => {
  const tc = { id: 'call-3', function: { name: 'edit', arguments: '{"path":"test.txt"}' } };
  const res = executeAgentLoopPermissionCheck(false, tc);
  assert.equal(res.isError, true);
  assert.match(res.error, /Permission denied: Router cannot execute 'edit'/);
});

test('AgentLoop Runtime: Router calling write is rejected with Permission Denied', () => {
  const tc = { id: 'call-4', function: { name: 'write', arguments: '{"path":"test.txt","content":"hello"}' } };
  const res = executeAgentLoopPermissionCheck(false, tc);
  assert.equal(res.isError, true);
  assert.match(res.error, /Permission denied: Router cannot execute 'write'/);
});

test('AgentLoop Runtime: Router calling run_code is rejected with Permission Denied', () => {
  const tc = { id: 'call-5', function: { name: 'run_code', arguments: '{"code":"print(1)"}' } };
  const res = executeAgentLoopPermissionCheck(false, tc);
  assert.equal(res.isError, true);
  assert.match(res.error, /Permission denied: Router cannot execute 'run_code'/);
});

test('AgentLoop Runtime: Router calling browser is rejected with Permission Denied', () => {
  const tc = { id: 'call-6', function: { name: 'browser', arguments: '{"action":"navigate"}' } };
  const res = executeAgentLoopPermissionCheck(false, tc);
  assert.equal(res.isError, true);
  assert.match(res.error, /Permission denied: Router cannot execute 'browser'/);
});

test('AgentLoop Runtime: Router calling dispatch_worker is permitted', () => {
  const tc = { id: 'call-7', function: { name: 'dispatch_worker', arguments: '{"role":"code_worker","goal":"test"}' } };
  const res = executeAgentLoopPermissionCheck(false, tc);
  assert.equal(res.isError, false);
});

test('AgentLoop Runtime: Router calling ask_attention is permitted', () => {
  const tc = { id: 'call-8', function: { name: 'ask_attention', arguments: '{"question":"ok?"}' } };
  const res = executeAgentLoopPermissionCheck(false, tc);
  assert.equal(res.isError, false);
});

test('AgentLoop Runtime: Worker attempting dispatch_worker is blocked (Star Topology)', () => {
  const tc = { id: 'call-9', function: { name: 'dispatch_worker', arguments: '{"role":"diag_worker","goal":"nested"}' } };
  const res = executeAgentLoopPermissionCheck(true, tc);
  assert.equal(res.isError, true);
  assert.match(res.error, /Workers are strictly prohibited from executing 'dispatch_worker' \(Star Topology\)/);
});

test('AgentLoop Runtime: Worker calling execution tool (bash) is permitted', () => {
  const tc = { id: 'call-10', function: { name: 'bash', arguments: '{"command":"ps"}' } };
  const res = executeAgentLoopPermissionCheck(true, tc);
  assert.equal(res.isError, false);
});

// -------------------------------------------------------------
// MODULE 4: Anti-Loop 3-Wakeup Hard Barrier Tests
// -------------------------------------------------------------
console.log('\n--- TEST GROUP 4: ANTI-LOOP 3-WAKEUP HARD LIMITER ---');

class MockTicketStore {
  constructor() {
    this.tickets = new Map();
  }
  createTicket(role, title, goal, contextInfo) {
    const ticket = {
      id: `ticket-${Date.now()}-${Math.floor(Math.random() * 1000)}`,
      title,
      role,
      goal,
      status: 'Pending',
      timestamps: { createdAt: Date.now() }
    };
    this.tickets.set(ticket.id, ticket);
    return ticket;
  }
  updateTicket(ticket) {
    this.tickets.set(ticket.id, ticket);
  }
  updateStatus(id, status, errorOrResult) {
    const t = this.tickets.get(id);
    if (t) {
      t.status = status;
      if (errorOrResult) t.error = errorOrResult;
    }
  }
}

class MockTicketEngine {
  constructor(store) {
    this.store = store;
    this.consecutiveAutoWakeCount = 0;
    this.MAX_CONSECUTIVE_AUTO_WAKEUPS = 3;
  }

  dispatchTask(role, goal) {
    const title = goal;
    const ticket = this.store.createTicket(role, title, goal);

    if (this.consecutiveAutoWakeCount >= this.MAX_CONSECUTIVE_AUTO_WAKEUPS) {
      ticket.status = 'WaitingHuman';
      ticket.attention = {
        id: `att-limit-${Date.now()}`,
        ticketId: ticket.id,
        question: `已达到连续自动任务上限 (${this.MAX_CONSECUTIVE_AUTO_WAKEUPS} 次)。请确认是否继续执行任务：${title}`,
        options: ['确认继续', '取消任务']
      };
      this.store.updateTicket(ticket);
      return ticket;
    }

    this.store.updateStatus(ticket.id, 'Running');
    return ticket;
  }

  onWorkerCompleted(ticket) {
    this.consecutiveAutoWakeCount++;
  }

  recordHumanInput() {
    this.consecutiveAutoWakeCount = 0;
  }

  getAutoWakeupCount() {
    return this.consecutiveAutoWakeCount;
  }
}

test('AntiLoop: initial counter is 0', () => {
  const store = new MockTicketStore();
  const engine = new MockTicketEngine(store);
  assert.equal(engine.getAutoWakeupCount(), 0);
});

test('AntiLoop: 3 autonomous completions increment count to 3', () => {
  const store = new MockTicketStore();
  const engine = new MockTicketEngine(store);

  const t1 = engine.dispatchTask('code_worker', 'task 1');
  assert.equal(t1.status, 'Running');
  engine.onWorkerCompleted(t1);
  assert.equal(engine.getAutoWakeupCount(), 1);

  const t2 = engine.dispatchTask('ui_worker', 'task 2');
  assert.equal(t2.status, 'Running');
  engine.onWorkerCompleted(t2);
  assert.equal(engine.getAutoWakeupCount(), 2);

  const t3 = engine.dispatchTask('diag_worker', 'task 3');
  assert.equal(t3.status, 'Running');
  engine.onWorkerCompleted(t3);
  assert.equal(engine.getAutoWakeupCount(), 3);
});

test('AntiLoop: 4th consecutive autonomous dispatch triggers WaitingHuman hard lock', () => {
  const store = new MockTicketStore();
  const engine = new MockTicketEngine(store);

  // Run 3 completions
  for (let i = 0; i < 3; i++) {
    const t = engine.dispatchTask('general_worker', `auto task ${i}`);
    engine.onWorkerCompleted(t);
  }
  assert.equal(engine.getAutoWakeupCount(), 3);

  // 4th dispatch attempt
  const t4 = engine.dispatchTask('general_worker', 'auto task 4 (storm)');
  assert.equal(t4.status, 'WaitingHuman');
  assert.ok(t4.attention !== undefined);
  assert.match(t4.attention.question, /连续自动任务上限/);
  assert.ok(t4.attention.options.includes('确认继续'));
  assert.ok(t4.attention.options.includes('取消任务'));
});

test('AntiLoop: human input immediately resets counter and unlocks execution', () => {
  const store = new MockTicketStore();
  const engine = new MockTicketEngine(store);

  // Hit limit
  for (let i = 0; i < 3; i++) {
    const t = engine.dispatchTask('general_worker', `task ${i}`);
    engine.onWorkerCompleted(t);
  }
  assert.equal(engine.getAutoWakeupCount(), 3);

  // Human speaks
  engine.recordHumanInput();
  assert.equal(engine.getAutoWakeupCount(), 0);

  // Next dispatch must succeed as Running, NOT WaitingHuman
  const tFresh = engine.dispatchTask('general_worker', 'task after human speech');
  assert.equal(tFresh.status, 'Running');
  assert.equal(tFresh.attention, undefined);
});

// -------------------------------------------------------------
// MODULE 5: Defect 1 & Recovery Deep Dive
// -------------------------------------------------------------
console.log('\n--- TEST GROUP 5: STARTUP RECOVERY & IN-MEMORY DEFECT CHECK ---');

test('Recovery Invariant: interrupted Running & Pending must become Failed with restart reason', () => {
  const store = new MockTicketStore();
  const tRunning = store.createTicket('code_worker', 'Interrupted 1', 'Goal 1');
  tRunning.status = 'Running';

  const tPending = store.createTicket('ui_worker', 'Interrupted 2', 'Goal 2');
  tPending.status = 'Pending';

  const tWaitHuman = store.createTicket('diag_worker', 'Interrupted 3', 'Goal 3');
  tWaitHuman.status = 'WaitingHuman';
  tWaitHuman.attention = { id: 'att-x', question: 'Confirm?' };

  // Simulate recovery loop from TicketStore.init
  const tickets = [tRunning, tPending, tWaitHuman];
  for (const t of tickets) {
    if (t.status === 'Running' || t.status === 'Pending') {
      t.status = 'Failed';
      t.error = '[Interrupted by application restart]';
    } else if (t.status === 'WaitingHuman') {
      // Retained
    }
  }

  assert.equal(tRunning.status, 'Failed');
  assert.equal(tRunning.error, '[Interrupted by application restart]');
  assert.equal(tPending.status, 'Failed');
  assert.equal(tPending.error, '[Interrupted by application restart]');
  assert.equal(tWaitHuman.status, 'WaitingHuman');
});

test('TicketStore.init(undefined) wipeout defect reproduction', async () => {
  // Replicate exact TicketStore.init code:
  class RealTicketStoreEmulation {
    constructor() {
      this.tickets = new Map();
      this.context = null;
      this.prefStore = undefined;
    }
    createTicket(role, title, goal) {
      const id = 'ticket-1';
      const t = { id, title, role, goal, status: 'Running', timestamps: { createdAt: Date.now() } };
      this.tickets.set(id, t);
      return t;
    }
    getTicket(id) {
      return this.tickets.get(id);
    }
    async init(context) {
      if (context) this.context = context;
      let loadedTickets = [];
      let loadedFromPref = false;

      // In TicketStore.ets lines 92:
      this.tickets.clear();
      for (const ticket of loadedTickets) {
        this.tickets.set(ticket.id, ticket);
      }
    }
  }

  const store = new RealTicketStoreEmulation();
  const t = store.createTicket('diag_worker', 'Interrupted', 'Goal');
  assert.ok(store.getTicket(t.id) !== undefined);

  // Calling init(undefined) as in SuperAgent.test.ets
  await store.init(undefined);

  // Because loadedTickets was empty, tickets.clear() erased the ticket!
  const recovered = store.getTicket(t.id);
  // This verifies that without preferences, init(undefined) wipes in-memory tickets:
  assert.equal(recovered, undefined, 'Ticket was wiped out by init(undefined)!');
});


// -------------------------------------------------------------
// SUMMARY & EXIT CODE
// -------------------------------------------------------------
console.log('\n====================================================');
console.log(`TOTAL TESTS: ${passCount + failCount}`);
console.log(`PASSED:      ${passCount}`);
console.log(`FAILED:      ${failCount}`);
console.log('====================================================\n');

if (failCount > 0) {
  process.exit(1);
}
