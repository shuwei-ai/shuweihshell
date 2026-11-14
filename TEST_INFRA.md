# Test Infrastructure & Quality Assurance Specification (TEST_INFRA)

## 1. Executive Summary & Architecture Overview

This document defines the comprehensive 4-tier test infrastructure and verification methodology for the **Strict Router + Workers Dual-Layer Agent Architecture** on HarmonyOS NEXT (PiHA - `shuweihshell`).

The test infrastructure is designed according to the architectural principles of **DeepSeek SuperAgent (DSH)** and **Aliyun AgentCore**, enforcing strict tool isolation, deterministic task state machines, non-blocking asynchronous event dispatch, inline-spill memory compaction, and anti-loop storm protection.

### 1.1 Dual-Tier Test Execution Pipeline
The verification suite operates across three primary environments:
1. **ArkTS Module & E2E Test Suite (`@ohos/hypium`)**:
   - Location: `entry/src/test/`
   - Runner: Hvigor Stage Mode Test Engine
   - Execution Command:
     ```bash
     DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
     /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw test \
     --mode module -p product=default -p module=entry@default --no-daemon
     ```
2. **Host-Side C++ Native & MicroPython Sandbox Test Harness**:
   - Location: `entry/src/main/cpp/test/`
   - Runner: Clang++ C++17 host test runner (`tools/run_tests.sh`)
   - Execution Command:
     ```bash
     ./tools/run_tests.sh
     ```
3. **Full Production HAP Build Validation**:
   - Verification Command:
     ```bash
     DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
     /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
     --mode module -p product=default -p module=entry@default --no-daemon
     ```

---

## 2. Feature Inventory Test Matrix (F1 – F18)

| Feature ID | Feature Name | Architecture Domain | Milestone | Primary Source | Test Suite File |
|------------|--------------|---------------------|-----------|----------------|-----------------|
| **F1** | Router Tool Stripping | Strict Tool Isolation | M1 | R1 | `StrictRouterIsolation.test.ets` |
| **F2** | Router Prompt Slimming | Prompt Governance | M1 | R1 | `StrictRouterIsolation.test.ets` |
| **F3** | Worker Tool Isolation | Star Topology Tooling | M1 | R1, R5 | `StrictRouterIsolation.test.ets` |
| **F4** | Ticket Data Model | Contract Modeling | M1 | R2 | `TicketStateMachine.test.ets` |
| **F5** | TicketStore Persistence | Storage & Recovery | M1 | R2 | `TicketStateMachine.test.ets` |
| **F6** | Ticket Startup Recovery | Crash / Reboot Recovery | M1 | R2 | `TicketStateMachine.test.ets` |
| **F7** | TicketEngine State Machine | Deterministic FSM | M1 | R2 | `TicketStateMachine.test.ets` |
| **F8** | Async Background Dispatch | Asynchronous Concurrency | M2 | R3 | `AsyncDispatchWaitOn.test.ets` |
| **F9** | Unblocked Router Conversation | Interactive UI Responsiveness | M2 | R3 | `AsyncDispatchWaitOn.test.ets` |
| **F10** | Live Worker Progress Streaming | Event Streaming | M2 | R3 | `AsyncDispatchWaitOn.test.ets` |
| **F11** | Wait-On Task Board (Pinned UI) | UI Presentation | M2 | R3 | `AsyncDispatchWaitOn.test.ets` |
| **F12** | One-Click Interactive Controls | Human-in-the-Loop | M2 | R3 | `AsyncDispatchWaitOn.test.ets` |
| **F13** | Float Window Synchronization | Multi-Window State Sync | M2 | R3 | `AsyncDispatchWaitOn.test.ets` |
| **F14** | Router Summary Wakeup Hook | Agent Inter-Communication | M2 | R3, R5 | `AsyncDispatchWaitOn.test.ets` |
| **F15** | Inline-Spill Mechanism | Context Compaction | M3 | R4 | `InlineSpillAntiLoop.test.ets` |
| **F16** | Anti-Loop Wakeup Storm Hard Lock | Loop & Storm Defense | M3 | R5 | `InlineSpillAntiLoop.test.ets` |
| **F17** | Worker @-Report Authority Restriction | Authority Boundary | M3 | R5 | `InlineSpillAntiLoop.test.ets` |
| **F18** | Unit Test Suite Extension | Regression & Unit Coverage | M3 | R6 | `SuperAgent.test.ets` |

---

## 3. Tier 1: Feature Coverage (Category-Partition Methodology)

Each feature F1 through F18 is partitioned into equivalence classes with at least 5 distinct test cases per feature (>= 90 total test cases).

### Feature F1: Router Tool Stripping
- **T1-F1-01**: Router definitions contain `dispatch_worker` with valid JSON schema.
- **T1-F1-02**: Router definitions contain `ask_attention` with structured parameter specification.
- **T1-F1-03**: Router definitions strictly exclude low-level execution tools (`bash`, `ui`, `read`, `write`, `edit`).
- **T1-F1-04**: Router definitions strictly exclude code evaluation tools (`run_code`, `run_js`, `remote_bash`).
- **T1-F1-05**: Router definitions strictly exclude network browser tools (`browser`, `fetch`, `remember`, `goal`).

### Feature F2: Router Prompt Slimming
- **T1-F2-01**: `assembleRouterPrompt()` emits prompt focusing on user intent clarification.
- **T1-F2-02**: Router prompt instructs task decomposition and delegation via `dispatch_worker`.
- **T1-F2-03**: Router prompt contains zero bash command syntax or uinput scripting instructions.
- **T1-F2-04**: Router prompt includes instructions on structured attention request handling.
- **T1-F2-05**: Router prompt injects workspace boundary without raw sandbox filesystem manipulation commands.

### Feature F3: Worker Tool Isolation & Role Presets
- **T1-F3-01**: `ui_worker` receives `ui`, `bash`, `run_code`, `run_js`, `inspect_image`, `remember`.
- **T1-F3-02**: `diag_worker` receives `bash`, `read`, `run_code`, `run_js`, `remember`.
- **T1-F3-03**: `code_worker` receives `read`, `write`, `edit`, `bash`, `run_code`, `run_js`, `remote_bash`, `inspect_image`, `remember`.
- **T1-F3-04**: `web_worker` receives `browser`, `fetch`, `run_code`, `run_js`, `inspect_image`, `remember`.
- **T1-F3-05**: Custom ad-hoc worker role respects explicit `customAllowedTools` filtering list without granting unrequested tools.

### Feature F4: Ticket Data Model
- **T1-F4-01**: Ticket generation populates mandatory fields (`id`, `title`, `role`, `goal`, `status`, `timestamps`).
- **T1-F4-02**: Ticket creation timestamp `createdAt` is non-zero epoch milliseconds.
- **T1-F4-03**: Initial ticket state defaults strictly to `'Pending'`.
- **T1-F4-04**: Ticket supports optional `contextInfo` payload passed to worker.
- **T1-F4-05**: Ticket serializes to and deserializes from JSON without loss of fields.

### Feature F5: TicketStore Persistence
- **T1-F5-01**: `createTicket()` stores ticket in in-memory cache and returns complete object.
- **T1-F5-02**: `getTicket(id)` retrieves existing ticket in O(1) time complexity.
- **T1-F5-03**: `updateStatus()` updates ticket status and persists changes.
- **T1-F5-04**: `getAllTickets()` returns chronological list of all stored tickets.
- **T1-F5-05**: `deleteTicket(id)` purges ticket from cache and persistent storage.

### Feature F6: Ticket Startup Recovery
- **T1-F6-01**: On app restart, any ticket with `status === 'Running'` is sanitized to `'Failed'`.
- **T1-F6-02**: Interrupted running ticket records descriptive error: "Task interrupted by application shutdown/restart".
- **T1-F6-03**: On app restart, any ticket with `status === 'Pending'` is sanitized to `'Failed'`.
- **T1-F6-04**: On app restart, ticket with `status === 'WaitingHuman'` and valid attention request restores into `AttentionManager`.
- **T1-F6-05**: Terminal tickets (`Completed`, `Failed`) remain completely untouched during startup scan.

### Feature F7: TicketEngine State Machine
- **T1-F7-01**: Transition from `Pending` to `Running` sets `timestamps.startedAt`.
- **T1-F7-02**: Transition from `Running` to `Completed` sets `timestamps.completedAt` and `result`.
- **T1-F7-03**: Transition from `Running` to `Failed` sets `timestamps.completedAt` and `error`.
- **T1-F7-04**: Transition from `Running` to `WaitingHuman` attaches `AttentionRequest`.
- **T1-F7-05**: `abortTicket(id)` cancels in-flight task and transitions status to `'Failed'`.

### Feature F8: Async Background Dispatch
- **T1-F8-01**: `dispatchTask()` returns `Ticket` synchronously without waiting for LLM completion.
- **T1-F8-02**: Dispatch creates an unawaited background Promise executing `WorkerSession`.
- **T1-F8-03**: `DispatchWorkerTool.execute()` returns JSON confirmation containing `ticketId`, `role`, and `status: "dispatched"`.
- **T1-F8-04**: Concurrent dispatches generate distinct unique ticket IDs.
- **T1-F8-05**: Dispatched worker executes in isolated session context without contaminating Router memory.

### Feature F9: Unblocked Router Conversation
- **T1-F9-01**: Router agent loop terminates turn immediately following `dispatch_worker` return.
- **T1-F9-02**: User chat input bar remains fully enabled while worker is executing in background.
- **T1-F9-03**: User can submit new messages to Router while background tasks are active.
- **T1-F9-04**: Router handles conversational steering and interjections during active worker run.
- **T1-F9-05**: Router turn completion latency after dispatch is under 50ms.

### Feature F10: Live Worker Progress Streaming
- **T1-F10-01**: Worker progress step updates emit `WorkerProgressEvent` with current and max steps.
- **T1-F10-02**: `updateProgress()` updates `ticket.progress` in store (`currentStep`, `maxSteps`, `actionText`).
- **T1-F10-03**: Progress listener callbacks trigger on every step update.
- **T1-F10-04**: High-frequency progress updates are debounced before disk flush to prevent I/O blocking.
- **T1-F10-05**: Progress events preserve human-readable action text (e.g. "Dumping UI tree...", "Reading crash log...").

### Feature F11: Wait-On Task Board (Pinned UI)
- **T1-F11-01**: Task board displays all tickets where status is `'Running'` or `'WaitingHuman'`.
- **T1-F11-02**: Completed and Failed tickets are omitted from the active Wait-On board.
- **T1-F11-03**: Board displays worker role tag, task title, action text, and progress bar.
- **T1-F11-04**: When zero active tickets exist, the Wait-On board automatically collapses / hides.
- **T1-F11-05**: Board reactively updates whenever any ticket state or progress changes.

### Feature F12: One-Click Interactive Controls
- **T1-F12-01**: When ticket enters `WaitingHuman`, Wait-On board displays structured question and option buttons.
- **T1-F12-02**: Tapping an option button resolves `AttentionManager` and returns answer to waiting worker.
- **T1-F12-03**: An "中断" (Abort) button on each card triggers `TicketEngine.abortTicket()`.
- **T1-F12-04**: Custom text input is enabled when `allowCustomInput === true`.
- **T1-F12-05**: Dismiss button cleans up resolved / terminated cards.

### Feature F13: Float Window Synchronization
- **T1-F13-01**: Active tickets list syncs to `AppStorage` key `'ActiveTickets'`.
- **T1-F13-02**: Floating window (`FloatPanel.ets`) reflects real-time task counts and statuses.
- **T1-F13-03**: Status transitions in background worker immediately update floating window badge.
- **T1-F13-04**: Floating window abort action triggers identical state transition as main window.
- **T1-F13-05**: Window destruction does not corrupt TicketStore or running background workers.

### Feature F14: Router Summary Wakeup Hook
- **T1-F14-01**: Worker completion (`onWorkerCompleted`) invokes `routerWakeupCallback`.
- **T1-F14-02**: Router formats `@` report containing role, ticket ID, summary, and artifacts.
- **T1-F14-03**: Wakeup callback delivers ticket result to chat conversation timeline.
- **T1-F14-04**: Worker failure triggers failure notification summary to user.
- **T1-F14-05**: Multiple completing workers queue wakeups sequentially without race conditions.

### Feature F15: Inline-Spill Mechanism
- **T1-F15-01**: Tool output <= 1500 characters remains completely inline without modification.
- **T1-F15-02**: Tool output > 1500 characters triggers truncation / spill.
- **T1-F15-03**: Truncated output preserves head lines, tail lines, and total character count notification.
- **T1-F15-04**: Spilled output persists full content to sandbox file (`workspace/spill/spill-<id>.log`).
- **T1-F15-05**: Inline text provides exact file path for workers to read on demand via `read` / `run_code`.

### Feature F16: Anti-Loop Wakeup Storm Hard Lock
- **T1-F16-01**: Initial auto-wakeup count starts at 0.
- **T1-F16-02**: Each autonomous worker-to-router wakeup increments `autoWakeupCount` by 1.
- **T1-F16-03**: Up to 3 consecutive autonomous wakeups proceed normally.
- **T1-F16-04**: Attempting a 4th consecutive autonomous wakeup triggers hard pause (`WaitingHuman`).
- **T1-F16-05**: Any human utterance (`recordHumanInput()`) immediately resets `autoWakeupCount` to 0.

### Feature F17: Worker @-Report Authority Restriction
- **T1-F17-01**: Worker report conveys only findings, deliverables, summary, and artifact paths.
- **T1-F17-02**: Worker report payload cannot grant or transfer execution tokens.
- **T1-F17-03**: Router never executes worker tools on behalf of worker reports.
- **T1-F17-04**: Star topology: worker report cannot re-invoke `dispatch_worker`.
- **T1-F17-05**: Malformed worker reports fall back gracefully with clear error notices.

### Feature F18: Unit Test Suite Extension
- **T1-F18-01**: Hypium unit tests compile and pass via `hvigorw test`.
- **T1-F18-02**: Tests cover role preset tool definitions and prompts.
- **T1-F18-03**: Tests cover attention request / response / cancellation lifecycles.
- **T1-F18-04**: Tests cover LlmClient HTTP retryable error classification.
- **T1-F18-05**: Tests cover OutputTruncator structured result formatting.

---

## 4. Tier 2: Boundary & Corner Cases (Boundary Value Analysis)

Each feature F1 through F18 is subjected to at least 5 extreme boundary conditions (>= 90 total boundary test cases).

### Feature F1: Router Tool Stripping Boundaries
- **T2-F1-01**: Router tool definitions called with null/empty parameters -> Returns clean validation error.
- **T2-F1-02**: Attempt to invoke stripped tool (`bash`) through Router -> Explicit "Unknown tool" rejection.
- **T2-F1-03**: Attempt to invoke stripped tool (`ui`) through Router -> Rejected with `isError: true`.
- **T2-F1-04**: Router definition list is strictly frozen/immutable; external mutation does not affect internal registry.
- **T2-F1-05**: Maximum allowable router tools: strictly 2 (`dispatch_worker`, `ask_attention`).

### Feature F2: Router Prompt Slimming Boundaries
- **T2-F2-01**: Empty environment snapshot provided -> Prompt assembler uses safe defaults without crashing.
- **T2-F2-02**: Oversized skills list (> 100 skills) -> Filtered / trimmed to fit prompt budget.
- **T2-F2-03**: Prompt assembler with undefined goals -> Omits goal section cleanly.
- **T2-F2-04**: Prompt containing special control characters (`\0`, unicode emojis, markdown injections) -> Escaped properly.
- **T2-F2-05**: Extreme context window pressure -> Prompt header remains intact with essential safety rules.

### Feature F3: Worker Tool Isolation Boundaries
- **T2-F3-01**: Custom role passed as empty string `""` -> Falls back to `general_worker` preset without `dispatch_worker`.
- **T2-F3-02**: Custom role passed as string containing SQL/Shell injection -> Handled safely as string literal.
- **T2-F3-03**: Custom allowed tools containing `'dispatch_worker'` -> Explicitly stripped/vetoed to protect star topology.
- **T2-F3-04**: Custom allowed tools containing non-existent tool names -> Filtered out silently or returned as rejected.
- **T2-F3-05**: Every standard role queried 1,000 times concurrently -> Tool permissions remain deterministic and leak-free.

### Feature F4: Ticket Data Model Boundaries
- **T4-F4-01**: Ticket title with 10,000 characters -> Truncated gracefully in UI title presentation.
- **T4-F4-02**: Ticket goal with unicode Chinese, Arabic, emojis -> Round-trips cleanly through JSON.
- **T4-F4-03**: Zero-step or negative step progress values -> Clamped to valid range `[0, maxSteps]`.
- **T4-F4-04**: Artifacts array containing 1,000 file paths -> Handled without memory overflow.
- **T4-F4-05**: Ticket with undefined optional fields -> Deserializes safely with undefined defaults.

### Feature F5: TicketStore Persistence Boundaries
- **T2-F5-01**: Concurrent insertion of 100 tickets simultaneously -> Unique IDs and zero key collisions.
- **T2-F5-02**: Updating a non-existent ticket ID -> No-op or throws descriptive error without corrupting store.
- **T2-F5-03**: Extremely large result payload (> 5MB) -> Safely written to disk without crashing Preferences.
- **T2-F5-04**: Corrupted preferences file on disk -> Falls back gracefully to FS backup or empty store.
- **T2-F5-05**: Store listeners throw an exception during broadcast -> Exception caught, other listeners still notified.

### Feature F6: Ticket Startup Recovery Boundaries
- **T2-F6-01**: Startup recovery when store has 0 tickets -> Finishes cleanly with empty list.
- **T2-F6-02**: Startup recovery when all tickets are already terminal -> No state modifications occur.
- **T2-F6-03**: Startup recovery with 50 interrupted `Running` tickets -> All 50 transitioned to `Failed` in single atomic pass.
- **T2-F6-04**: `WaitingHuman` ticket with corrupted/missing attention object -> Handled safely by failing ticket.
- **T2-F6-05**: Immediate crash during recovery execution -> Subsequent startup can re-run recovery idempotently.

### Feature F7: TicketEngine State Machine Boundaries
- **T2-F7-01**: Invalid transition: `Completed` -> `Running` -> Strictly prohibited and rejected.
- **T2-F7-02**: Invalid transition: `Failed` -> `Running` -> Strictly prohibited and rejected.
- **T2-F7-03**: Invalid transition: `Completed` -> `Failed` -> Strictly prohibited and rejected.
- **T2-F7-04**: Calling `abortTicket()` on already `Completed` ticket -> No-op, preserves completed result.
- **T2-F7-05**: `abortAll()` called when 0 tickets are running -> Completes instantly without side effects.

### Feature F8: Async Background Dispatch Boundaries
- **T2-F8-01**: Dispatch with `maxSteps = 0` or negative -> Clamped to minimum 1 step.
- **T2-F8-02**: Dispatching when system thread/task queue is saturated -> Handled with queued promise or error.
- **T2-F8-03**: Rapid dispatch of 20 workers in under 100ms -> All 20 receive distinct tickets and background handles.
- **T2-F8-04**: Abort signal fired immediately before first step execution -> Worker halts without running tools.
- **T2-F8-05**: Dispatch with invalid API key or offline network -> Worker transitions to `Failed` with error message.

### Feature F9: Unblocked Router Conversation Boundaries
- **T2-F9-01**: User submits message at exact instant worker dispatches -> Message handled without race conditions.
- **T2-F9-02**: User submits 10 messages in rapid succession while worker is executing -> Queue buffers smoothly.
- **T2-F9-03**: User types cancel/steer command -> Router processes intent and can invoke `abortTicket`.
- **T2-F9-04**: Network disconnect during user turn -> Local UI input remains responsive.
- **T2-F9-05**: Router turn finishes in 0ms if dispatch is synchronous tool call.

### Feature F10: Live Worker Progress Streaming Boundaries
- **T2-F10-01**: Progress step exceeds `maxSteps` -> Step capped or clamped gracefully.
- **T2-F10-02**: Progress text containing 5,000 characters -> Truncated in UI presentation.
- **T2-F10-03**: 1,000 progress updates per second -> UI throttles rendering without freezing main thread.
- **T2-F10-04**: Progress emitted after worker has already completed -> Dropped silently without state corrupt.
- **T2-F10-05**: Listener unregistered while event is in-flight -> No memory leak or dangling reference.

### Feature F11: Wait-On Task Board Boundaries
- **T2-F11-01**: 50 simultaneous active tickets -> Task board renders scrollable list without crashing.
- **T2-F11-02**: Window resize / orientation change -> Task board layout recalculates without state loss.
- **T2-F11-03**: All tickets complete simultaneously -> Task board smoothly transitions to collapsed state.
- **T2-F11-04**: Ticket with empty actionText -> Renders default status message.
- **T2-F11-05**: Rapid add/remove of cards -> Zero ghost cards or incorrect index references.

### Feature F12: One-Click Interactive Controls Boundaries
- **T2-F12-01**: User clicks option button twice rapidly -> First click consumed, second click ignored.
- **T2-F12-02**: User clicks abort button while attention is pending -> Attention cancelled, ticket aborted.
- **T2-F12-03**: Custom input submitted with whitespace-only -> Trimmed or rejected if required.
- **T2-F12-04**: Question with 0 options provided -> Falls back to custom text input or confirmation.
- **T2-F12-05**: Attention request timed out -> Automatically falls back to default action or cancel.

### Feature F13: Float Window Synchronization Boundaries
- **T2-F13-01**: Float window opened before main window initializes -> Handled gracefully.
- **T2-F13-02**: Float window dragged offscreen -> Clamped to visible screen coordinates.
- **T2-F13-03**: Float window minimized during active worker -> Background worker continues uninterrupted.
- **T2-F13-04**: `AppStorage` key update failure -> State falls back to direct query.
- **T2-F13-05**: Rapid toggling of float window visibility -> Zero memory leaks or orphaned observers.

### Feature F14: Router Summary Wakeup Hook Boundaries
- **T2-F14-01**: Worker completes while Router is currently processing user utterance -> Wakeup queued until turn ends.
- **T2-F14-02**: Summary text exceeds 10,000 characters -> Rendered with markdown folding.
- **T2-F14-03**: Worker completes with 0 artifacts -> Summary omits artifact section cleanly.
- **T2-F14-04**: 5 workers complete at the identical millisecond -> Summaries presented sequentially in chat.
- **T2-F14-05**: Router session destroyed before worker completes -> Result saved to ticket without crashing.

### Feature F15: Inline-Spill Mechanism Boundaries
- **T2-F15-01**: Tool output exactly 1,500 characters -> Remains 100% inline (threshold edge).
- **T2-F15-02**: Tool output exactly 1,501 characters -> Spills to file and emits inline preview (threshold edge).
- **T2-F15-03**: Tool output of 10MB (large log dump) -> Streamed to disk; prompt receives concise summary.
- **T2-F15-04**: Output containing binary / unprintable characters -> Encoded safely.
- **T2-F15-05**: Disk full when writing spill file -> Falls back to inline truncation with warning message.

### Feature F16: Anti-Loop Wakeup Storm Boundaries
- **T2-F16-01**: Auto-wakeup count at 2 -> Next autonomous wakeup succeeds (count becomes 3).
- **T2-F16-02**: Auto-wakeup count at 3 -> Next autonomous wakeup BLOCKED, triggers `WaitingHuman`.
- **T2-F16-03**: Human sends single space character " " -> Counter immediately resets to 0.
- **T2-F16-04**: Multiple workers completing concurrently -> Counter increments per wakeup event.
- **T2-F16-05**: `recordHumanInput()` called when count is already 0 -> Remains 0 (safe idempotent call).

### Feature F17: Worker @-Report Boundaries
- **T2-F17-01**: Worker report containing prompt injection attempting to command Router -> Treated as inert data.
- **T2-F17-02**: Worker report with missing status field -> Validated and assigned default `'ready'`.
- **T2-F17-03**: Worker report with non-existent artifact file path -> Recorded as string, not auto-opened.
- **T2-F17-04**: Worker report with negative duration -> Clamped to 0ms.
- **T2-F17-05**: Malformed JSON in worker report -> Caught by parser and wrapped into error report.

### Feature F18: Unit Test Suite Boundaries
- **T2-F18-01**: Hypium runner executes async tests with 15s timeout boundary.
- **T2-F18-02**: Zero tests skipped or orphaned in suite index.
- **T2-F18-03**: Mock objects clean up state after every spec (`afterEach` boundary).
- **T2-F18-04**: Memory leaks during test run -> Isolated per test case.
- **T2-F18-05**: Cross-test contamination -> Zero dependency on execution order.

---

## 5. Tier 3: Cross-Feature Interactions (Pairwise Combinations)

The pairwise matrix validates integration seams between interconnected modules.

| Pair | Features | Interaction Contract Under Test | Expected Behavior |
|------|----------|--------------------------------|-------------------|
| **P1** | **F1 x F8** | Router executes `dispatch_worker` without having execution tools | Router creates ticket via `dispatch_worker` successfully; has no access to `bash`/`ui`. |
| **P2** | **F3 x F17** | Worker attempts to call `dispatch_worker` in @-report | Star topology enforced: worker lacks tool; report only conveys deliverables. |
| **P3** | **F4 x F5** | Ticket model instantiated and stored in `TicketStore` | Full ticket serializes and restores with identical fields, status, and timestamps. |
| **P4** | **F5 x F6** | Interrupted active tickets restored on app restart | Stored `Running` tickets sanitized to `Failed`; `WaitingHuman` re-registered. |
| **P5** | **F7 x F16** | Ticket state transition triggers autonomous wakeup limiter | 3 consecutive wakeups succeed; 4th forces transition to `WaitingHuman`. |
| **P6** | **F8 x F9** | Asynchronous dispatch leaves Router chat unblocked | Dispatch returns in < 50ms; chat input bar remains responsive for immediate typing. |
| **P7** | **F8 x F10** | Worker execution streams progress into TicketStore | Live steps appear in store and notify reactive UI listeners. |
| **P8** | **F10 x F11** | Progress events update pinned Wait-On task board | Task board cards update step number, progress bar, and action text smoothly. |
| **P9** | **F11 x F12** | Wait-On card triggers one-click user decision | User clicks option button; card responds and resolves worker attention promise. |
| **P10** | **F11 x F13** | Float window synchronizes with main Wait-On board | Both windows display identical active ticket list and progress state. |
| **P11** | **F12 x F14** | Human decision resolves ticket and triggers Router summary | Completed ticket triggers Router wakeup to summarize deliverables to user. |
| **P12** | **F15 x F17** | Tool output > 1500 chars spilled during worker execution | Full output written to `workspace/spill/`; worker @-report references spill path. |
| **P13** | **F16 x F9** | Anti-loop lock reached; human types message in unblocked chat | Human message resets counter to 0 and unlocks agent execution. |
| **P14** | **F7 x F12** | User clicks "中断" (Abort) on Wait-On card | `TicketEngine.abortTicket()` halts worker and marks state `'Failed'`. |
| **P15** | **F6 x F12** | Restart restores `WaitingHuman` ticket with options | Option buttons re-render on Wait-On board immediately after reboot. |

---

## 6. Tier 4: Real-World Workload Scenarios (End-to-End Applications)

### Scenario S1: Multi-Step System Diagnostics with Log Spill
- **Persona**: Developer investigating an intermittent app crash.
- **Workflow**:
  1. User asks Router: "帮我排查最近的系统崩溃日志并分析原因".
  2. Router clarifies intent, decomposes task, calls `dispatch_worker(role="diag_worker", goal="Check fault logs and grep crash stack")`.
  3. Router immediately returns confirmation to user: "已指派诊断专员执行排查，请稍候...". Turn ends; input bar remains open.
  4. Wait-On task board displays `diag_worker` card with "Pending" -> "Running".
  5. Worker executes `bash(command="cat /data/log/faultlog/faultlogger/cppcrash-*")`.
  6. Crash log is 80,000 characters (> 1500 chars). OutputTruncator spills log to `workspace/spill/spill-179439.log` and returns 1,200 char preview.
  7. Worker analyzes stack trace using `run_code` (Python regex extraction).
  8. Worker completes, sets ticket `result="Crash caused by SIGSEGV in librender.so at offset 0x4a12"` and status `'Completed'`.
  9. Router summary hook wakes up Router, presenting structured summary and artifact link to user in chat.

### Scenario S2: UI Automation with Human Disambiguation & Quick Decision
- **Persona**: User automating app configuration.
- **Workflow**:
  1. User asks: "帮我打开设置并将蓝牙关闭".
  2. Router dispatches `ui_worker` with goal.
  3. `ui_worker` navigates UI via `ui(action="dump_tree")` and finds two Bluetooth toggles (e.g. system vs BLE).
  4. `ui_worker` calls `ask_attention(question="检测到两个蓝牙开关，请选择要关闭的目标", options=["系统主蓝牙", "低功耗BLE分享"])`.
  5. Ticket transitions to `WaitingHuman`. Wait-On board surfaces question and two option buttons.
  6. User taps "系统主蓝牙".
  7. Attention resolves; worker resumes execution, taps toggle, verifies via `ui(action="dump_tree")`.
  8. Ticket completes; Router reports success with screenshot artifact.

### Scenario S3: Process Interruption & Seamless Startup Recovery
- **Persona**: User experiencing sudden app termination during long-running code task.
- **Workflow**:
  1. `code_worker` is running a 10-step refactoring task. Ticket is at Step 4, status `'Running'`.
  2. Application process is killed (simulating low memory or OS restart).
  3. App launches fresh. `TicketStore.init(context)` scans persisted tickets.
  4. Interrupted running ticket is detected. Status is sanitized to `'Failed'` with diagnostic error: "Task interrupted by application shutdown/restart".
  5. UI displays clean state without orphan background processes; user can tap "重试" (Retry) with 1 click.

### Scenario S4: Recursive Loop Storm Hard Shield & Reset
- **Persona**: Complex task encountering recursive worker-router loop.
- **Workflow**:
  1. Autonomous loop begins: Worker 1 completes -> Router receives -> Router auto-dispatches Worker 2 -> Worker 2 completes -> Router auto-dispatches Worker 3.
  2. `autoWakeupCount` increments: 1, 2, 3.
  3. Worker 3 completes. Router attempts to auto-dispatch Worker 4 without human utterance.
  4. Anti-loop hard lock activates: `autoWakeupCount >= 3`.
  5. Dispatch is locked; task transitions to `WaitingHuman` with prompt: "已达到连续3次自主唤醒上限，请确认是否继续执行".
  6. System pauses safely, preventing infinite token consumption and billing runaway.
  7. User types "继续执行". `recordHumanInput()` fires, immediately resetting counter to 0. Execution proceeds safely.

### Scenario S5: Multi-Worker Concurrent Execution on Wait-On Board
- **Persona**: Power user delegating web research and log analysis simultaneously.
- **Workflow**:
  1. Router dispatches `web_worker` for API docs search, and `diag_worker` for syslog monitoring.
  2. Two distinct tickets are active simultaneously (`Running`).
  3. Pinned Wait-On board displays two stacked progress cards, updating concurrently.
  4. Floating window displays badge `2` with active status.
  5. `web_worker` completes first -> card clears from active board, Router posts partial summary.
  6. `diag_worker` completes second -> board automatically collapses.

---

## 7. Test Verification & Runner Execution Commands

### 7.1 Full ArkTS Hypium Test Suite
```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw test \
--mode module -p product=default -p module=entry@default --no-daemon
```

### 7.2 Full Production HAP Build Validation
```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
--mode module -p product=default -p module=entry@default --no-daemon
```

### 7.3 Host Native C++ Shims & MicroPython Harness
```bash
./tools/run_tests.sh
```

---

## 8. Quality Gates & Acceptance Thresholds

1. **Compilation Gate**: 100% clean compilation of ArkTS source and test suites with zero syntax or typecheck errors under Stage Mode.
2. **Execution Gate**: 100% pass rate across all Hypium test cases in `entry/src/test/List.test.ets`. Zero failed assertions. Zero unhandled promise rejections.
3. **Isolation Gate**: Strict verification that Router tool set contains exactly `[dispatch_worker, ask_attention]` and workers never contain `dispatch_worker`.
4. **Resilience Gate**: Verification that simulated app restarts sanitize all non-terminal tickets and restore human attention requests cleanly.
5. **Anti-Storm Gate**: Verification that 4th consecutive autonomous wakeups are hard-blocked and reset immediately on human speech.
