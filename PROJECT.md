# Project: Strict Router + Workers Production-Grade Agent Architecture

## Architecture
- **Model**: Pure 2-tier Star Topology Architecture (Strict Router + Workers) based on DeepSeek SuperAgent (DSH) and Aliyun AgentCore.
- **Router (Main Agent)**: Exclusively front-desk conversation, intent clarification, task decomposition, `dispatch_worker`, and `ask_attention`. Completely stripped of low-level tools (`bash`, `edit`, `write`, `read`, `ui`, etc.).
- **Workers**: Autonomous execution specialists (`ui_worker`, `diag_worker`, `code_worker`, `web_worker`, `general_worker`) running in isolated sessions with role-specific toolsets, dedicated `LlmClient`, and isolated context. Prohibited from calling `dispatch_worker`.
- **Ticket Engine & State Machine (`TicketStore` / `TicketEngine`)**: Deterministic task contract with states `Pending` -> `Running` -> `WaitingHuman` -> `Completed` | `Failed`. Persisted via `@ohos.data.preferences` and `@ohos.file.fs`. Interrupted tasks recover on app restart.
- **Asynchronous Event-Driven Execution & Wait-On UI**: `dispatch_worker` immediately creates Ticket and returns confirmation to Router. Router turn ends, leaving the user chat unblocked for continuous interaction and interjections. Live worker progress streams to the "当前在等谁 (Wait-On)" task board in `Index.ets` and `FloatPanel.ets`.
- **Inline-Spill Context Compaction**: Tool outputs exceeding 1500 chars are automatically spilled to `workspace/spill/` sandbox files; concise preview and file path are provided inline; workers pull details on demand via `read` / `run_code`.
- **Anti-Loop Hard Shield**: Maximum 3 consecutive autonomous wakeups between Worker and Router without human input; hitting limit triggers `WaitingHuman` hard pause. Counter resets immediately when a human sends any message. Worker `@` reports only transfer conclusions/artifacts, never execution authority.

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| F1 | Router Tool Stripping | Strip `bash`, `edit`, `ui`, `run_code`, `browser`, etc. from Router. Mount only `dispatch_worker` & `ask_attention`. | M1 | R1 |
| F2 | Router Prompt Slimming | Provide `assembleRouterPrompt()` stripping low-level execution instructions and focusing on intent clarification and delegation. | M1 | R1 |
| F3 | Worker Tool Isolation | Workers receive role-specific execution tools. No worker receives `dispatch_worker` (star topology). | M1 | R1, R5 |
| F4 | Ticket Data Model | Define canonical `Ticket` interface with IDs, roles, titles, states (`Pending`, `Running`, `WaitingHuman`, `Completed`, `Failed`), timestamps, progress, and artifacts. | M1 | R2 |
| F5 | TicketStore Persistence | Singleton store using `@ohos.data.preferences` with in-memory cache and atomic persistence. | M1 | R2 |
| F6 | Ticket Startup Recovery | On app launch, scan stored tickets: transition interrupted `Running` tickets to `Failed` (with retry info) and re-register `WaitingHuman` tickets into `AttentionManager`. | M1 | R2 |
| F7 | TicketEngine State Machine | Code-driven state transitions (`Pending` -> `Running` -> `WaitingHuman` -> `Completed`/`Failed`), cancel/abort controls. | M1 | R2 |
| F8 | Async Background Dispatch | `DispatchWorkerTool` creates Ticket, triggers worker in unawaited background Promise, and immediately returns confirmation to Router. | M2 | R3 |
| F9 | Unblocked Router Conversation | Router turn finishes immediately after dispatch, keeping chat input enabled for user typing, inquiries, or task steering. | M2 | R3 |
| F10 | Live Worker Progress Streaming | Background workers stream step updates to `TicketStore` and emit reactive events to UI. | M2 | R3 |
| F11 | Wait-On Task Board (Pinned UI) | Pinned status board above chat scroll in `Index.ets` displaying all active (`Running`/`WaitingHuman`) tickets with live action text and progress. | M2 | R3 |
| F12 | One-Click Interactive Controls | Quick-tap decision buttons, custom input, task abort (`中断`), and dismiss buttons on Wait-On board. | M2 | R3 |
| F13 | Float Window Synchronization | Sync active tickets and status in `FloatPanel.ets` via `AppStorage`. | M2 | R3 |
| F14 | Router Summary Wakeup Hook | When a worker finishes or enters `WaitingHuman`, wake up Router to post an `@汇报` summary in chat. | M2 | R3, R5 |
| F15 | Inline-Spill Mechanism | Spill tool outputs > 1500 chars to sandbox files in `workspace/spill/`, returning inline preview + path. Workers pull via `read`/`run_code`. | M3 | R4 |
| F16 | Anti-Loop Wakeup Storm Hard Lock | Hard lock after 3 consecutive auto-wakeups without human utterance. Trigger `WaitingHuman` pause. Reset counter to 0 on human speech. | M3 | R5 |
| F17 | Worker @-Report Authority Restriction | Worker `@` report conveys only findings, deliverables, and artifacts. It does not transfer or grant new execution authority. | M3 | R5 |
| F18 | Unit Test Suite Extension | Unit test coverage in `entry/src/test/SuperAgent.test.ets` for Ticket state machine, Router tool isolation, and 3-wakeup limiter. | M3 | R6 |
| F19 | E2E Testing Track & Verification | Comprehensive opaque-box test suite verifying all tiers (1-5), full `hvigorw assembleHap` production build validation. | M4 | R6, AC |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Phase 1: Ticket 状态机与 Router/Worker 工具严格剥离 | F1, F2, F3, F4, F5, F6, F7 | none | DONE |
| M2 | Phase 2: 全异步后台化流式事件机制与 Wait-On 界面看板 | F8, F9, F10, F11, F12, F13, F14 | M1 | DONE |
| M3 | Phase 3: Inline-Spill 上下文瘦身与防风暴硬熔断 | F15, F16, F17, F18 | M2 | DONE |
| M4 | Final Milestone: 100% E2E 测试通过与构建验证 | F19, Pass Tiers 1-5, Build Verification, Forensic Audit | M1, M2, M3 | DONE |

## Interface Contracts
### `Ticket` Contract (`entry/src/main/ets/agent/superagent/types.ets`)
```typescript
export type TicketStatus = 'Pending' | 'Running' | 'WaitingHuman' | 'Completed' | 'Failed';

export interface TicketProgress {
  currentStep: number;
  maxSteps: number;
  actionText: string;
}

export interface TicketTimestamps {
  createdAt: number;
  startedAt?: number;
  completedAt?: number;
}

export interface Ticket {
  id: string;
  title: string;
  role: WorkerRole;
  goal: string;
  status: TicketStatus;
  contextInfo?: string;
  result?: string;
  error?: string;
  artifacts?: string[];
  timestamps: TicketTimestamps;
  progress?: TicketProgress;
  attention?: AttentionRequest;
}
```

### `TicketStore` Contract (`entry/src/main/ets/agent/superagent/TicketStore.ets`)
```typescript
export class TicketStore {
  static getInstance(): TicketStore;
  init(context?: common.Context): Promise<void>;
  createTicket(role: WorkerRole, title: string, goal: string, contextInfo?: string): Ticket;
  updateTicket(ticket: Ticket): void;
  updateStatus(id: string, status: TicketStatus, resultOrError?: string): void;
  updateProgress(id: string, step: number, maxSteps: number, actionText: string): void;
  getTicket(id: string): Ticket | undefined;
  getActiveTickets(): Ticket[];
  getAllTickets(): Ticket[];
  deleteTicket(id: string): void;
  clear(): void;
  addListener(listener: (tickets: Ticket[]) => void): void;
  removeListener(listener: (tickets: Ticket[]) => void): void;
  persistImmediately(): Promise<void>;
}
```

### `TicketEngine` Contract (`entry/src/main/ets/agent/superagent/TicketEngine.ets`)
```typescript
export class TicketEngine {
  static getInstance(): TicketEngine;
  dispatchTask(config: AgentModelConfig, role: WorkerRole, goal: string, contextInfo?: string, maxSteps?: number, customPrompt?: string, allowedTools?: string[]): Ticket;
  abortTicket(ticketId: string): void;
  abortAll(): void;
  onWorkerCompleted(ticket: Ticket): void;
  recordHumanInput(): void; // resets autoWakeupCount to 0
  getAutoWakeupCount(): number;
  setRouterWakeupCallback(cb: (ticket: Ticket) => void): void;
}
```

### `ToolRegistry` Contract (`entry/src/main/ets/agent/tools/ToolRegistry.ets`)
```typescript
export class ToolRegistry {
  static getRouterToolDefinitions(): ToolDefinition[]; // returns [dispatch_worker, ask_attention]
  static getWorkerToolDefinitions(role: WorkerRole, allowed?: string[]): ToolDefinition[];
  static getDefinitions(): ToolDefinition[];
  static execute(call: ToolCall, context?: Context): Promise<ToolResult>;
}
```

## Code Layout
- `entry/src/main/ets/agent/superagent/types.ets`: Domain types and Ticket data model. (Owned by M1 - DONE)
- `entry/src/main/ets/agent/superagent/TicketStore.ets`: Preferences + FS persistent ticket store. (Owned by M1 - DONE)
- `entry/src/main/ets/agent/superagent/TicketEngine.ets`: State machine, background concurrency manager, anti-loop limiter. (Owned by M1, M2, M3)
- `entry/src/main/ets/agent/superagent/WorkerPresets.ets`: Tool configuration per worker role (star topology). (Owned by M1 - DONE)
- `entry/src/main/ets/agent/tools/ToolRegistry.ets`: Router vs Worker tool partition. (Owned by M1 - DONE)
- `entry/src/main/ets/agent/harness/SystemPromptAssembler.ets`: Specialized Router prompt assembly. (Owned by M1 - DONE)
- `entry/src/main/ets/agent/AgentSession.ets`: Router orchestration, tool mounting, wakeup handling, and reset on human input. (Owned by M1, M2, M3)
- `entry/src/main/ets/agent/superagent/DispatchWorkerTool.ets`: Non-blocking async ticket dispatch. (Owned by M2)
- `entry/src/main/ets/agent/superagent/WorkerSession.ets`: Streaming progress and completion hooks. (Owned by M2)
- `entry/src/main/ets/pages/Index.ets`: "当前在等谁 (Wait-On)" task board, one-click controls, non-blocking input bar. (Owned by M2)
- `entry/src/main/ets/pages/FloatPanel.ets`: Floating window active tickets sync. (Owned by M2)
- `entry/src/main/ets/agent/harness/OutputTruncator.ets`: Inline-Spill logic for large tool outputs to sandbox files. (Owned by M3)
- `entry/src/main/ets/agent/index.ets`: Public exports barrel. (Owned by M1 - DONE)
- `entry/src/test/SuperAgent.test.ets`: Unit test suite. (Owned by M1, M3, M4)
