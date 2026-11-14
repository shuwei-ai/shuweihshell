/**
 * Empirical Challenger Adversarial Stress Harness for Milestone 1 Round 2
 * Tests:
 * - Defect 1: In-memory ticket recovery, idempotency, persistence coalescing mutex under concurrency
 * - Defect 2: Router prompt memory lessons, category filtering, defense-in-depth sanitization, prompt leaks
 * - Defect 3: Attention ID coordination, respondAttention resolution, abortTicket cancellation, human input reset
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';

console.log('===============================================================');
console.log('=== EMPIRICAL CHALLENGER ADVERSARIAL STRESS HARNESS (M1 R2) ===');
console.log('===============================================================\n');

let totalTests = 0;
let passedTests = 0;
let failedTests = 0;

function pass(name) {
  totalTests++;
  passedTests++;
  console.log(`[PASS] ${name}`);
}

function fail(name, err) {
  totalTests++;
  failedTests++;
  console.error(`[FAIL] ${name}`);
  console.error(`       Error: ${err.message}`);
  if (err.stack) console.error(err.stack.split('\n').slice(1, 4).join('\n'));
}

async function runTestCase(name, fn) {
  try {
    const res = fn();
    if (res && typeof res.then === 'function') {
      await res;
    }
    pass(name);
  } catch (err) {
    fail(name, err);
  }
}

// ============================================================================
// SUITE 1: DEFECT 1 - IN-MEMORY TICKET RECOVERY & PERSISTENCE MUTEX COALESCING
// ============================================================================
console.log('--- SUITE 1: DEFECT 1 (TicketStore In-Memory Recovery & Concurrency) ---');

// Mock implementation of TicketStore mirroring entry/src/main/ets/agent/superagent/TicketStore.ets exactly
class SimulatedTicketStore {
  constructor() {
    this.tickets = new Map();
    this.persistDebounceTimer = undefined;
    this.isPersisting = false;
    this.hasPendingPersist = false;
    this.nextPersistPromise = null;
    this.nextPersistResolve = null;
    this.nextPersistReject = null;
    this.persistExecutionCount = 0;
    this.prefStore = null;
    this.fsStorage = null;
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
    return ticket;
  }

  getTicket(id) {
    return this.tickets.get(id);
  }

  getAllTickets() {
    return Array.from(this.tickets.values());
  }

  getActiveTickets() {
    return this.getAllTickets().filter(t => t.status === 'Running' || t.status === 'Pending' || t.status === 'WaitingHuman');
  }

  updateStatus(id, status, resultOrError) {
    const ticket = this.tickets.get(id);
    if (!ticket) return;
    ticket.status = status;
    const now = Date.now();
    if (status === 'Running' && !ticket.timestamps.startedAt) {
      ticket.timestamps.startedAt = now;
    } else if (status === 'Completed') {
      ticket.timestamps.completedAt = now;
      if (resultOrError !== undefined) ticket.result = resultOrError;
    } else if (status === 'Failed') {
      ticket.timestamps.completedAt = now;
      if (resultOrError !== undefined) ticket.error = resultOrError;
    }
  }

  clear() {
    if (this.persistDebounceTimer !== undefined) {
      clearTimeout(this.persistDebounceTimer);
      this.persistDebounceTimer = undefined;
    }
    this.tickets.clear();
  }

  async init(context) {
    let loadedTickets = [];
    let loadedFromPref = false;

    // Simulate disk/pref load
    if (this.prefStore) {
      try {
        const raw = this.prefStore.get('tickets');
        if (raw && raw.trim().length > 0) {
          loadedTickets = JSON.parse(raw);
          loadedFromPref = true;
        }
      } catch (_e) {}
    }

    if (!loadedFromPref && this.fsStorage) {
      try {
        if (this.fsStorage.data && this.fsStorage.data.trim().length > 0) {
          loadedTickets = JSON.parse(this.fsStorage.data);
        }
      } catch (_e) {}
    }

    // Preserve in-memory tickets if no tickets loaded from disk
    if (loadedTickets.length === 0 && this.tickets.size > 0) {
      loadedTickets = Array.from(this.tickets.values());
    } else if (loadedTickets.length > 0 && this.tickets.size > 0) {
      const loadedIds = new Set(loadedTickets.map(t => t.id));
      for (const inMemTicket of this.tickets.values()) {
        if (inMemTicket && inMemTicket.id && !loadedIds.has(inMemTicket.id)) {
          loadedTickets.push(inMemTicket);
        }
      }
    }

    // Populate memory cache & perform Startup Recovery
    this.tickets.clear();
    const now = Date.now();

    for (const ticket of loadedTickets) {
      if (!ticket || !ticket.id) continue;
      if (!ticket.timestamps) {
        ticket.timestamps = { createdAt: now };
      }

      if (ticket.status === 'Running' || ticket.status === 'Pending') {
        ticket.status = 'Failed';
        ticket.error = '[Interrupted by application restart]';
        if (!ticket.timestamps.completedAt) {
          ticket.timestamps.completedAt = now;
        }
      }
      this.tickets.set(ticket.id, ticket);
    }
  }

  async persistImmediately() {
    if (this.persistDebounceTimer !== undefined) {
      clearTimeout(this.persistDebounceTimer);
      this.persistDebounceTimer = undefined;
    }

    if (this.isPersisting) {
      this.hasPendingPersist = true;
      if (!this.nextPersistPromise) {
        this.nextPersistPromise = new Promise((resolve, reject) => {
          this.nextPersistResolve = resolve;
          this.nextPersistReject = reject;
        });
      }
      return this.nextPersistPromise;
    }

    this.isPersisting = true;
    try {
      await this.executePersist();

      while (this.hasPendingPersist) {
        this.hasPendingPersist = false;
        const resolve = this.nextPersistResolve;
        const reject = this.nextPersistReject;
        this.nextPersistPromise = null;
        this.nextPersistResolve = null;
        this.nextPersistReject = null;

        try {
          await this.executePersist();
          if (resolve) resolve();
        } catch (err) {
          if (reject) reject(err);
        }
      }
    } finally {
      this.isPersisting = false;
      this.hasPendingPersist = false;
      if (this.nextPersistResolve) {
        this.nextPersistResolve();
        this.nextPersistPromise = null;
        this.nextPersistResolve = null;
        this.nextPersistReject = null;
      }
    }
  }

  async executePersist() {
    this.persistExecutionCount++;
    // Simulate non-trivial I/O delay
    await new Promise(r => setTimeout(r, 10));
    const serialized = JSON.stringify(Array.from(this.tickets.values()));
    if (this.prefStore) {
      this.prefStore.set('tickets', serialized);
    }
  }
}

await runTestCase('Defect 1: in-memory tickets survive init(undefined) and recover correctly', async () => {
  const store = new SimulatedTicketStore();
  const tRunning = store.createTicket('code_worker', 'Running Task', 'Code');
  store.updateStatus(tRunning.id, 'Running');

  const tPending = store.createTicket('diag_worker', 'Pending Task', 'Diag');
  // remains Pending

  const tCompleted = store.createTicket('ui_worker', 'Completed Task', 'UI');
  store.updateStatus(tCompleted.id, 'Completed', 'Result OK');

  const tWaiting = store.createTicket('general_worker', 'Waiting Task', 'Wait');
  store.updateStatus(tWaiting.id, 'WaitingHuman');

  // Call init(undefined)
  await store.init(undefined);

  // Assertions
  const recRunning = store.getTicket(tRunning.id);
  assert.ok(recRunning, 'Running ticket must not be deleted');
  assert.equal(recRunning.status, 'Failed');
  assert.ok(recRunning.error.includes('Interrupted by application restart'));
  assert.ok(recRunning.timestamps.completedAt > 0);

  const recPending = store.getTicket(tPending.id);
  assert.ok(recPending, 'Pending ticket must not be deleted');
  assert.equal(recPending.status, 'Failed');
  assert.ok(recPending.error.includes('Interrupted by application restart'));

  const recCompleted = store.getTicket(tCompleted.id);
  assert.ok(recCompleted, 'Completed ticket must survive');
  assert.equal(recCompleted.status, 'Completed');
  assert.equal(recCompleted.result, 'Result OK');

  const recWaiting = store.getTicket(tWaiting.id);
  assert.ok(recWaiting, 'WaitingHuman ticket must survive');
  assert.equal(recWaiting.status, 'WaitingHuman');
});

await runTestCase('Defect 1: multiple sequential init() calls are idempotent', async () => {
  const store = new SimulatedTicketStore();
  const t = store.createTicket('code_worker', 'Task', 'Test');
  store.updateStatus(t.id, 'Running');

  await store.init(undefined);
  const afterFirst = store.getTicket(t.id);
  assert.equal(afterFirst.status, 'Failed');

  // Second init call
  await store.init(undefined);
  const afterSecond = store.getTicket(t.id);
  assert.equal(afterSecond.status, 'Failed');
  assert.equal(afterSecond.id, t.id);
});

await runTestCase('Defect 1: merging in-memory tickets with disk tickets prevents loss of either', async () => {
  const store = new SimulatedTicketStore();
  store.prefStore = {
    _data: new Map(),
    get(k) { return this._data.get(k); },
    set(k, v) { this._data.set(k, v); }
  };

  // Disk has ticket-disk-1
  const diskTicket = {
    id: 'ticket-disk-1',
    title: 'Disk Task',
    role: 'diag_worker',
    goal: 'From Disk',
    status: 'Completed',
    timestamps: { createdAt: 1000, completedAt: 2000 },
    result: 'Disk Result'
  };
  store.prefStore.set('tickets', JSON.stringify([diskTicket]));

  // In-memory has ticket-mem-1
  const memTicket = store.createTicket('code_worker', 'Mem Task', 'In Memory');

  // Run init
  await store.init({});

  assert.equal(store.getAllTickets().length, 2, 'Must have both disk and in-memory tickets');
  const d = store.getTicket('ticket-disk-1');
  assert.ok(d);
  assert.equal(d.status, 'Completed');
  const m = store.getTicket(memTicket.id);
  assert.ok(m);
  assert.equal(m.status, 'Failed'); // Pending converted to Failed by restart recovery
});

await runTestCase('Defect 1: high concurrency persistImmediately coalescing under 50 simultaneous callers', async () => {
  const store = new SimulatedTicketStore();
  store.prefStore = {
    _data: new Map(),
    get(k) { return this._data.get(k); },
    set(k, v) { this._data.set(k, v); }
  };

  store.createTicket('code_worker', 'Heavy Task', 'Concurrency');

  // Fire 50 concurrent calls
  const promises = [];
  for (let i = 0; i < 50; i++) {
    promises.push(store.persistImmediately());
  }

  await Promise.all(promises);

  // Verify that all 50 resolved without error and execution was coalesced
  assert.ok(store.persistExecutionCount <= 3, `Coalesced executions should be <= 3, actual: ${store.persistExecutionCount}`);
  assert.ok(!store.isPersisting, 'isPersisting must be reset to false');
  assert.ok(!store.hasPendingPersist, 'hasPendingPersist must be reset to false');
  assert.equal(store.nextPersistPromise, null, 'nextPersistPromise must be cleared');
});

// ============================================================================
// SUITE 2: DEFECT 2 - ROUTER PROMPT MEMORY LESSONS & SANITIZATION
// ============================================================================
console.log('\n--- SUITE 2: DEFECT 2 (Router Prompt Memory Lessons & Stripping) ---');

// Mock MemoryStore logic
class SimulatedMemoryStore {
  constructor() {
    this.lessons = [
      {
        id: 'lesson_no_curl',
        category: 'network',
        rule: '鸿蒙系统终端 (toybox) 没有安装 curl 或 wget。所有 HTTP/HTTPS 网络请求必须使用原生 fetch 工具，禁止在 bash 中执行 curl/wget。',
        confidence: 1.0,
        occurrenceCount: 6
      },
      {
        id: 'lesson_uitest_chinese_input',
        category: 'tools',
        rule: '在鸿蒙端侧，uinput -K -t 仅支持 ASCII 字符。输入中文文本必须使用 uitest：`uitest uiInput text \'<中文文本>\'`。',
        confidence: 1.0,
        occurrenceCount: 5
      },
      {
        id: 'lesson_toybox_limits',
        category: 'shell',
        rule: '系统终端基于 toybox，缺少 tr、awk、column 等工具。',
        confidence: 0.95,
        occurrenceCount: 4
      }
    ];
  }

  addLesson(category, rule) {
    this.lessons.push({
      id: `lesson-${Date.now()}`,
      category,
      rule,
      confidence: 1.0,
      occurrenceCount: 10
    });
  }

  formatLessonsForPrompt(limit = 8, allowedCategories, excludeExecutionCommands = false) {
    if (this.lessons.length === 0) return '';
    let candidates = this.lessons;

    if (allowedCategories && allowedCategories.length > 0) {
      candidates = candidates.filter(l => allowedCategories.includes(l.category));
    }

    if (excludeExecutionCommands) {
      const EXEC_CMD_PATTERN = /(uitest|uinput|bash|toybox|dumpLayout|read\s|write\s|edit\s|run_code|curl|wget)/i;
      candidates = candidates.filter(l => !EXEC_CMD_PATTERN.test(l.rule));
    }

    if (candidates.length === 0) return '';

    const sorted = [...candidates].sort((a, b) => {
      const scoreA = (a.confidence * 10) + (a.occurrenceCount || 0);
      const scoreB = (b.confidence * 10) + (b.occurrenceCount || 0);
      return scoreB - scoreA;
    });

    const selected = sorted.slice(0, limit);
    let output = '<learned_lessons_and_constraints>\n';
    selected.forEach((l, idx) => {
      output += `${idx + 1}. [${l.category}] ${l.rule}\n`;
    });
    output += '</learned_lessons_and_constraints>';
    return output;
  }
}

await runTestCase('Defect 2: formatLessonsForPrompt with default lessons returns empty for router', () => {
  const mem = new SimulatedMemoryStore();
  const routerLessons = mem.formatLessonsForPrompt(4, ['general'], true);
  assert.equal(routerLessons, '', 'Default lessons have categories network/tools/shell, none in general');
});

await runTestCase('Defect 2: formatLessonsForPrompt excludes execution command patterns', () => {
  const mem = new SimulatedMemoryStore();
  // Add a general lesson with an execution command
  mem.addLesson('general', 'Always run bash command to check battery');
  // Add a clean general lesson
  mem.addLesson('general', 'Always verify user intent before making irreversible changes');

  const filtered = mem.formatLessonsForPrompt(4, ['general'], true);
  assert.ok(filtered.includes('Always verify user intent'), 'Clean lesson should be present');
  assert.ok(!filtered.includes('Always run bash command'), 'Execution command lesson must be filtered');
});

await runTestCase('Defect 2: Defense-in-depth sanitization strips if uitest/uinput/bash appears', () => {
  const mem = new SimulatedMemoryStore();
  mem.addLesson('general', 'Avoid uitest when possible');

  // Simulate SystemPromptAssembler lines 141-144
  let memoryBlock = mem.formatLessonsForPrompt(4, ['general'], false); // without excludeExecutionCommands
  if (memoryBlock && (memoryBlock.includes('uitest') || memoryBlock.includes('uinput') || memoryBlock.includes('bash'))) {
    memoryBlock = '';
  }

  assert.equal(memoryBlock, '', 'Defense-in-depth sanitization must blank out the block');
});

await runTestCase('Defect 2: Real source check on SystemPromptAssembler.ets', () => {
  const src = fs.readFileSync('entry/src/main/ets/agent/harness/SystemPromptAssembler.ets', 'utf-8');
  assert.ok(src.includes("formatLessonsForPrompt(4, ['general'], true)"), 'Must call formatLessonsForPrompt with general and excludeExecutionCommands');
  assert.ok(src.includes("memoryBlock.includes('uitest') || memoryBlock.includes('uinput') || memoryBlock.includes('bash')"), 'Must have defense-in-depth check');
});

// ============================================================================
// SUITE 3: DEFECT 3 - ATTENTION ID ALIGNMENT & RESOLUTION
// ============================================================================
console.log('\n--- SUITE 3: DEFECT 3 (Attention ID Coordination & Resolution) ---');

class SimulatedAttentionManager {
  constructor() {
    this.pendingRequests = new Map();
    this.activeRequest = null;
  }

  getActiveAttention() {
    return this.activeRequest;
  }

  requestAttention(ticketId, question, options, allowCustomInput = true, timeoutSeconds = 300, requestId) {
    const id = (requestId && requestId.trim().length > 0)
      ? requestId.trim()
      : `att-${Date.now()}-${Math.floor(Math.random() * 1000)}`;

    const request = {
      id,
      ticketId,
      question,
      options: (options && options.length > 0) ? options : ['确认', '取消'],
      allowCustomInput,
      createdAt: Date.now()
    };

    return new Promise((resolve, reject) => {
      this.pendingRequests.set(id, { request, resolve, reject });
      this.activeRequest = request;
    });
  }

  respondAttention(id, selectedValue) {
    const pending = this.pendingRequests.get(id);
    if (!pending) return false;

    this.pendingRequests.delete(id);
    if (this.activeRequest?.id === id) {
      const remaining = Array.from(this.pendingRequests.values());
      this.activeRequest = remaining.length > 0 ? remaining[0].request : null;
    }
    pending.resolve(selectedValue);
    return true;
  }

  cancelAttention(id) {
    const pending = this.pendingRequests.get(id);
    if (!pending) return;

    this.pendingRequests.delete(id);
    if (this.activeRequest?.id === id) {
      this.activeRequest = null;
    }
    pending.resolve('[User cancelled attention request]');
  }
}

await runTestCase('Defect 3: Attention ID coordination between ticket.attention and AttentionManager', async () => {
  const attMgr = new SimulatedAttentionManager();
  const ticketId = 'ticket-test-101';
  const customId = `att-limit-${Date.now()}-123`;

  let userChoice = null;
  const attPromise = attMgr.requestAttention(
    ticketId,
    '连续自动任务达到上限，是否继续？',
    ['确认继续', '取消任务'],
    true,
    0,
    customId
  ).then(answer => {
    userChoice = answer;
  });

  const activeAtt = attMgr.getActiveAttention();
  assert.ok(activeAtt, 'Active attention must exist');
  assert.equal(activeAtt.id, customId, 'Active attention ID must match coordinated ID');
  assert.equal(activeAtt.ticketId, ticketId);

  // User responds using ticket.attention.id
  const success = attMgr.respondAttention(customId, '确认继续');
  assert.equal(success, true, 'respondAttention must return true');

  await attPromise;
  assert.equal(userChoice, '确认继续', 'Resolver must receive the user choice');
  assert.equal(attMgr.getActiveAttention(), null, 'Active attention must be cleared after resolution');
});

await runTestCase('Defect 3: User cancellation path via respondAttention', async () => {
  const attMgr = new SimulatedAttentionManager();
  const ticketId = 'ticket-test-102';
  const customId = `att-limit-${Date.now()}-456`;

  let aborted = false;
  const attPromise = attMgr.requestAttention(
    ticketId,
    '连续自动任务达到上限，是否继续？',
    ['确认继续', '取消任务'],
    true,
    0,
    customId
  ).then(answer => {
    if (answer === '取消任务' || answer.includes('取消')) {
      aborted = true;
    }
  });

  const success = attMgr.respondAttention(customId, '取消任务');
  assert.equal(success, true);
  await attPromise;
  assert.equal(aborted, true, 'Must trigger abort path on cancel option');
});

await runTestCase('Defect 3: abortTicket cleanly cancels active AttentionRequest', async () => {
  const attMgr = new SimulatedAttentionManager();
  const ticketId = 'ticket-test-103';
  const customId = `att-limit-${Date.now()}-789`;

  let cancelResult = null;
  const attPromise = attMgr.requestAttention(
    ticketId,
    'Question?',
    ['A', 'B'],
    true,
    0,
    customId
  ).then(ans => { cancelResult = ans; });

  assert.equal(attMgr.getActiveAttention()?.id, customId);

  // Simulate abortTicket calling cancelAttention
  attMgr.cancelAttention(customId);

  assert.equal(attMgr.getActiveAttention(), null, 'Active attention should be cleared');
  await attPromise;
  assert.ok(cancelResult.includes('cancelled'), 'Pending promise should resolve with cancellation notice');
});

await runTestCase('Defect 3: Invalid attention ID gracefully rejected without crashing', () => {
  const attMgr = new SimulatedAttentionManager();
  const success = attMgr.respondAttention('non-existent-id-999', 'something');
  assert.equal(success, false, 'Non-existent ID must return false');
});

await runTestCase('Defect 3: Real source check on TicketEngine.ets and AttentionManager.ets', () => {
  const engineSrc = fs.readFileSync('entry/src/main/ets/agent/superagent/TicketEngine.ets', 'utf-8');
  assert.ok(engineSrc.includes('attentionReq.id'), 'TicketEngine must pass attentionReq.id');
  assert.ok(engineSrc.includes('AttentionManager.getInstance().cancelAttention(ticket.attention.id)'), 'abortTicket must cancel attention');

  const attSrc = fs.readFileSync('entry/src/main/ets/agent/superagent/AttentionManager.ets', 'utf-8');
  assert.ok(attSrc.includes('requestId?: string'), 'AttentionManager.requestAttention must accept requestId');
});

// ============================================================================
// SUMMARY
// ============================================================================
console.log('\n===============================================================');
console.log(`TOTAL CHALLENGER TESTS: ${totalTests}`);
console.log(`PASSED:                 ${passedTests}`);
console.log(`FAILED:                 ${failedTests}`);
console.log('===============================================================');

if (failedTests > 0) {
  process.exit(1);
}
