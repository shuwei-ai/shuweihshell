/*
 * Unit tests for SuperAgent (Router-Worker Architecture) on HarmonyOS.
 * Modeled after deepseek-ai/dsh-superagent-prototype.
 */
import { describe, it, expect } from '@ohos/hypium';
import { WorkerPresets } from '../main/ets/agent/superagent/WorkerPresets';
import { AttentionManager } from '../main/ets/agent/superagent/AttentionManager';
import { WorkerSession } from '../main/ets/agent/superagent/WorkerSession';
import { AttentionRequest, Ticket, TicketStatus, TicketTimestamps, WorkerReport, WorkerRole } from '../main/ets/agent/superagent/types';
import { TicketStore } from '../main/ets/agent/superagent/TicketStore';
import { TicketEngine } from '../main/ets/agent/superagent/TicketEngine';
import { SystemPromptAssembler } from '../main/ets/agent/harness/SystemPromptAssembler';
import { ToolRegistry } from '../main/ets/agent/tools/ToolRegistry';
import { LlmClient } from '../main/ets/agent/LlmClient';
import { AgentModelConfig } from '../main/ets/agent/types';

export default function superAgentTest() {
  describe('SuperAgentArchitectureTest', () => {

    // 1. WorkerPresets Tests
    it('WorkerPresets_systemPrompts_contain_domain_guidelines', 0, () => {
      const roles: WorkerRole[] = ['ui_worker', 'diag_worker', 'code_worker', 'web_worker', 'general_worker'];

      for (const role of roles) {
        const prompt = WorkerPresets.getSystemPrompt(role);
        expect(prompt.length > 50).assertTrue();
      }

      // Check domain-specific keywords
      expect(WorkerPresets.getSystemPrompt('ui_worker')).assertContain('uitest');
      expect(WorkerPresets.getSystemPrompt('ui_worker')).assertContain('uinput');
      expect(WorkerPresets.getSystemPrompt('diag_worker')).assertContain('hilog');
      expect(WorkerPresets.getSystemPrompt('diag_worker')).assertContain('hidumper');
      expect(WorkerPresets.getSystemPrompt('code_worker')).assertContain('edit');
      expect(WorkerPresets.getSystemPrompt('web_worker')).assertContain('browser');
    });

    it('WorkerPresets_tools_filtering_and_recursion_protection', 0, () => {
      const uiTools = WorkerPresets.getAllowedToolNames('ui_worker');
      expect(uiTools.includes('ui')).assertTrue();
      expect(uiTools.includes('bash')).assertTrue();
      expect(uiTools.includes('remember')).assertTrue();
      expect(uiTools.includes('dispatch_worker')).assertFalse();

      const diagTools = WorkerPresets.getAllowedToolNames('diag_worker');
      expect(diagTools.includes('bash')).assertTrue();
      expect(diagTools.includes('read')).assertTrue();
      expect(diagTools.includes('remember')).assertTrue();
      expect(diagTools.includes('dispatch_worker')).assertFalse();

      const codeTools = WorkerPresets.getAllowedToolNames('code_worker');
      expect(codeTools.includes('read')).assertTrue();
      expect(codeTools.includes('write')).assertTrue();
      expect(codeTools.includes('edit')).assertTrue();
      expect(codeTools.includes('bash')).assertTrue();
      expect(codeTools.includes('dispatch_worker')).assertFalse();

      const webTools = WorkerPresets.getAllowedToolNames('web_worker');
      expect(webTools.includes('browser')).assertTrue();
      expect(webTools.includes('fetch')).assertTrue();
      expect(webTools.includes('remember')).assertTrue();
      expect(webTools.includes('dispatch_worker')).assertFalse();

      // None of the workers should be granted dispatch_worker to prevent infinite nesting
      const roles: WorkerRole[] = ['ui_worker', 'diag_worker', 'code_worker', 'web_worker', 'general_worker'];
      for (const role of roles) {
        const allowed = WorkerPresets.getAllowedToolNames(role);
        expect(allowed.includes('dispatch_worker')).assertFalse();
      }
    });

    // 2. ToolRegistry Role-specific Filtering Tests
    it('ToolRegistry_registers_superagent_tools', 0, () => {
      const defs = ToolRegistry.getDefinitions();
      const toolNames = defs.map(d => d.function.name);

      expect(toolNames.includes('dispatch_worker')).assertTrue();
      expect(toolNames.includes('ask_attention')).assertTrue();
    });

    it('ToolRegistry_getDefinitionsForRole_correctly_filters', 0, () => {
      const uiDefNames = ToolRegistry.getDefinitionsForRole('ui_worker').map(d => d.function.name);
      expect(uiDefNames.includes('ui')).assertTrue();
      expect(uiDefNames.includes('bash')).assertTrue();
      expect(uiDefNames.includes('dispatch_worker')).assertFalse();

      const codeDefNames = ToolRegistry.getDefinitionsForRole('code_worker').map(d => d.function.name);
      expect(codeDefNames.includes('read')).assertTrue();
      expect(codeDefNames.includes('write')).assertTrue();
      expect(codeDefNames.includes('edit')).assertTrue();
      expect(codeDefNames.includes('dispatch_worker')).assertFalse();
    });

    // 3. AttentionManager Tests
    it('AttentionManager_request_and_response_lifecycle', 0, async (done: () => void) => {
      const attMgr = AttentionManager.getInstance();
      attMgr.clear();

      expect(attMgr.getActiveAttention()).assertNull();

      const questionPromise = attMgr.requestAttention(
        'test-ticket-1',
        'Which app do you want to test?',
        ['App A', 'App B'],
        true,
        10
      );

      const activeReq = attMgr.getActiveAttention();
      expect(activeReq !== null).assertTrue();
      expect(activeReq?.question).assertEqual('Which app do you want to test?');
      expect(activeReq?.options).assertDeepEquals(['App A', 'App B']);

      // User responds
      const resolved = attMgr.respondAttention(activeReq!.id, 'App B');
      expect(resolved).assertTrue();

      const answer = await questionPromise;
      expect(answer).assertEqual('App B');
      expect(attMgr.getActiveAttention()).assertNull();
      done();
    });

    it('AttentionManager_cancellation', 0, async (done: () => void) => {
      const attMgr = AttentionManager.getInstance();
      attMgr.clear();

      const questionPromise = attMgr.requestAttention(
        'test-ticket-2',
        'Confirm deletion?',
        ['Yes', 'No'],
        false,
        10
      );

      const activeReq = attMgr.getActiveAttention();
      attMgr.cancelAttention(activeReq!.id);

      const answer = await questionPromise;
      expect(answer).assertEqual('[User cancelled attention request]');
      expect(attMgr.getActiveAttention()).assertNull();
      done();
    });

    // 4. WorkerSession Report Formatting Tests
    it('WorkerSession_formatReportOutput_structure', 0, () => {
      const report: WorkerReport = {
        ticketId: 'worker-12345',
        role: 'ui_worker',
        status: 'ready',
        summary: 'Successfully navigated to Settings and turned Bluetooth off.',
        artifacts: ['/data/local/tmp/screen_verify.png'],
        durationMs: 3200,
        stepsCount: 4
      };

      const formatted = WorkerSession.formatReportOutput(report);
      expect(formatted).assertContain('[WORKER REPORT: ui_worker | STATUS: READY]');
      expect(formatted).assertContain('Ticket: worker-12345');
      expect(formatted).assertContain('Duration: 3200ms');
      expect(formatted).assertContain('Tool Steps: 4');
      expect(formatted).assertContain('Successfully navigated to Settings and turned Bluetooth off.');
      expect(formatted).assertContain('Artifacts Produced:');
      expect(formatted).assertContain('/data/local/tmp/screen_verify.png');
    });

    // 5. LlmClient Retry Mechanism Tests
    it('LlmClient_checkRetryable_classifies_correctly', 0, () => {
      // 429 Rate Limit -> must retry
      const res429 = LlmClient.checkRetryable('HTTP Error status 429 from https://api.openai.com: Too many requests');
      expect(res429.isRetryable).assertTrue();
      expect(res429.statusCode).assertEqual(429);
      expect(res429.reason).assertContain('Rate limited');

      // 502 / 503 Server Error -> must retry
      const res503 = LlmClient.checkRetryable('HTTP Error status 503: Service Unavailable');
      expect(res503.isRetryable).assertTrue();
      expect(res503.statusCode).assertEqual(503);

      const res500 = LlmClient.checkRetryable('HTTP Error status 500: Internal server error');
      expect(res500.isRetryable).assertTrue();

      // Network Timeout & Socket -> must retry
      const resTimeout = LlmClient.checkRetryable('HTTP stream request failed: connect timeout');
      expect(resTimeout.isRetryable).assertTrue();

      const resClosed = LlmClient.checkRetryable('API connection closed without returning content or tool calls');
      expect(resClosed.isRetryable).assertTrue();

      // Client Errors (401, 404, 400) -> must NOT retry
      const res401 = LlmClient.checkRetryable('HTTP Error status 401: Invalid API key');
      expect(res401.isRetryable).assertFalse();

      const res404 = LlmClient.checkRetryable('HTTP Error status 404: Model not found');
      expect(res404.isRetryable).assertFalse();

      const res400 = LlmClient.checkRetryable('HTTP Error status 400: Bad Request');
      expect(res400.isRetryable).assertFalse();

      // User Abort -> must NOT retry
      const resAbort = LlmClient.checkRetryable('Request cancelled by user');
      expect(resAbort.isRetryable).assertFalse();
    });

    // 6. Router & Worker Tool Isolation Tests
    it('ToolRegistry_getRouterToolDefinitions_strictly_isolated', 0, () => {
      const routerDefs = ToolRegistry.getRouterToolDefinitions();
      const names = routerDefs.map(d => d.function.name);
      expect(names.length).assertEqual(2);
      expect(names.includes('dispatch_worker')).assertTrue();
      expect(names.includes('ask_attention')).assertTrue();
      expect(names.includes('bash')).assertFalse();
      expect(names.includes('edit')).assertFalse();
      expect(names.includes('write')).assertFalse();
      expect(names.includes('read')).assertFalse();
      expect(names.includes('ui')).assertFalse();
      expect(names.includes('run_code')).assertFalse();
      expect(names.includes('browser')).assertFalse();
    });

    it('ToolRegistry_getWorkerToolDefinitions_star_topology_enforced', 0, () => {
      const roles: WorkerRole[] = ['ui_worker', 'diag_worker', 'code_worker', 'web_worker', 'general_worker'];
      for (const role of roles) {
        const workerDefs = ToolRegistry.getWorkerToolDefinitions(role);
        const names = workerDefs.map(d => d.function.name);
        expect(names.includes('dispatch_worker')).assertFalse();
      }

      // Explicit injection of dispatch_worker must be stripped
      const forgedDefs = ToolRegistry.getWorkerToolDefinitions('general_worker', ['bash', 'dispatch_worker', 'read']);
      const forgedNames = forgedDefs.map(d => d.function.name);
      expect(forgedNames.includes('dispatch_worker')).assertFalse();
      expect(forgedNames.includes('bash')).assertTrue();
      expect(forgedNames.includes('read')).assertTrue();
    });

    // 7. SystemPromptAssembler Router Prompt Tests
    it('SystemPromptAssembler_assembleRouterPrompt_strips_low_level_tools', 0, () => {
      const routerPrompt = SystemPromptAssembler.assembleRouterPrompt(false, 'deepseek-chat');
      expect(routerPrompt).assertContain('Front-Desk Dispatch Router Agent');
      expect(routerPrompt).assertContain('dispatch_worker');
      expect(routerPrompt).assertContain('ask_attention');
      expect(routerPrompt).assertContain('STRICT ROUTER');
      // Verify stripped low-level execution details
      expect(routerPrompt.includes('bash: Execute shell commands')).assertFalse();
      expect(routerPrompt.includes('uitest uiInput text')).assertFalse();
      expect(routerPrompt.includes('edit: Surgical search-and-replace')).assertFalse();
      expect(routerPrompt.includes('NEVER run \'curl\'')).assertFalse();
    });

    // 8. TicketStore Lifecycle & State Machine Tests
    it('TicketStore_lifecycle_and_state_machine', 0, () => {
      const store = TicketStore.getInstance();
      store.clear();

      const ticket = store.createTicket('code_worker', 'Task 1', 'Write tests');
      expect(ticket.id.startsWith('ticket-')).assertTrue();
      expect(ticket.role).assertEqual('code_worker');
      expect(ticket.status).assertEqual('Pending');
      expect(ticket.timestamps.createdAt > 0).assertTrue();

      // Transition to Running
      store.updateStatus(ticket.id, 'Running');
      const running = store.getTicket(ticket.id);
      expect(running?.status).assertEqual('Running');
      expect((running?.timestamps.startedAt ?? 0) > 0).assertTrue();

      // Progress update
      store.updateProgress(ticket.id, 1, 5, 'Step 1 completed');
      const progressing = store.getTicket(ticket.id);
      expect(progressing?.progress?.currentStep).assertEqual(1);
      expect(progressing?.progress?.maxSteps).assertEqual(5);
      expect(progressing?.progress?.actionText).assertEqual('Step 1 completed');

      // Complete
      store.updateStatus(ticket.id, 'Completed', 'Done successfully');
      const completed = store.getTicket(ticket.id);
      expect(completed?.status).assertEqual('Completed');
      expect(completed?.result).assertEqual('Done successfully');
      expect((completed?.timestamps.completedAt ?? 0) > 0).assertTrue();

      // Active tickets should no longer include completed
      const active = store.getActiveTickets();
      expect(active.some(t => t.id === ticket.id)).assertFalse();
    });

    // 9. TicketStore Startup Recovery Tests
    it('TicketStore_startup_recovery_interrupted_tickets', 0, async (done: () => void) => {
      const store = TicketStore.getInstance();
      store.clear();

      // Setup interrupted tickets
      const t1 = store.createTicket('diag_worker', 'Interrupted Running', 'Analyze hilog');
      store.updateStatus(t1.id, 'Running');

      const t2 = store.createTicket('ui_worker', 'Interrupted Pending', 'Tap button');
      // remains Pending

      const t3 = store.createTicket('code_worker', 'Interrupted WaitingHuman', 'Refactor code');
      t3.status = 'WaitingHuman';
      const attReq: AttentionRequest = {
        id: 'att-test-recovery',
        ticketId: t3.id,
        question: 'Allow overwrite?',
        options: ['Yes', 'No'],
        allowCustomInput: false,
        createdAt: Date.now()
      };
      t3.attention = attReq;
      store.updateTicket(t3);

      // Trigger recovery via init (in-memory mode with undefined context)
      await store.init(undefined);

      const recovered1 = store.getTicket(t1.id);
      expect(recovered1?.status).assertEqual('Failed');
      expect(recovered1?.error).assertContain('Interrupted by application restart');

      const recovered2 = store.getTicket(t2.id);
      expect(recovered2?.status).assertEqual('Failed');
      expect(recovered2?.error).assertContain('Interrupted by application restart');

      const recovered3 = store.getTicket(t3.id);
      expect(recovered3?.status).assertEqual('WaitingHuman');
      const activeAtt = AttentionManager.getInstance().getActiveAttention();
      expect(activeAtt !== null).assertTrue();
      expect(activeAtt?.id).assertEqual('att-test-recovery');

      done();
    });

    // 10. TicketEngine Anti-Loop & Wakeup Tests
    it('TicketEngine_anti_loop_hard_limit_and_human_reset', 0, async (done: () => void) => {
      const engine = TicketEngine.getInstance();
      engine.recordHumanInput();
      expect(engine.getAutoWakeupCount()).assertEqual(0);

      // Simulate 3 autonomous worker completions
      const ts: TicketTimestamps = { createdAt: Date.now() };
      const mockTicket: Ticket = {
        id: 'ticket-mock-1',
        title: 'Mock Task',
        role: 'general_worker',
        goal: 'Mock Goal',
        status: 'Completed',
        timestamps: ts
      };

      engine.onWorkerCompleted(mockTicket);
      expect(engine.getAutoWakeupCount()).assertEqual(1);
      engine.onWorkerCompleted(mockTicket);
      expect(engine.getAutoWakeupCount()).assertEqual(2);
      engine.onWorkerCompleted(mockTicket);
      expect(engine.getAutoWakeupCount()).assertEqual(3);

      // Fourth dispatch must be hard-locked into WaitingHuman
      const testModelCfg: AgentModelConfig = {
        apiKey: 'test',
        baseUrl: 'test',
        modelName: 'test',
        autoRunTools: true,
        enableThinking: false
      };
      const lockedTicket = engine.dispatchTask(
        testModelCfg,
        'general_worker',
        'Run another autonomous step'
      );
      expect(lockedTicket.status).assertEqual('WaitingHuman');
      expect(lockedTicket.attention !== undefined).assertTrue();
      expect(lockedTicket.attention?.question).assertContain('连续自动任务上限');

      // Verify AttentionRequest ID coordination between TicketEngine and AttentionManager
      const activeAtt = AttentionManager.getInstance().getActiveAttention();
      expect(activeAtt !== null).assertTrue();
      expect(activeAtt?.id).assertEqual(lockedTicket.attention?.id);
      expect(activeAtt?.ticketId).assertEqual(lockedTicket.id);

      // Verify AttentionManager resolution via ticket.attention.id
      const resolved = AttentionManager.getInstance().respondAttention(lockedTicket.attention!.id, '取消任务');
      expect(resolved).assertTrue();
      expect(AttentionManager.getInstance().getActiveAttention()).assertNull();

      // Allow microtask to process then callback
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 10));

      expect(engine.getAutoWakeupCount()).assertEqual(0);
      const abortedTicket = TicketStore.getInstance().getTicket(lockedTicket.id);
      expect(abortedTicket?.status).assertEqual('Failed');

      // Human input resets counter to 0
      engine.onWorkerCompleted(mockTicket);
      expect(engine.getAutoWakeupCount()).assertEqual(1);
      engine.recordHumanInput();
      expect(engine.getAutoWakeupCount()).assertEqual(0);

      done();
    });

  });
}
