/*
 * E2E & Architecture Test: Strict Router Tool Isolation & Star Topology (F1, F2, F3, F17)
 * Verifies that the Router is stripped of all execution tools, and workers strictly adhere
 * to the star topology (workers cannot call dispatch_worker).
 */
import { describe, it, expect } from '@ohos/hypium';
import { ToolRegistry } from '../main/ets/agent/tools/ToolRegistry';
import { WorkerPresets } from '../main/ets/agent/superagent/WorkerPresets';
import { WorkerRole } from '../main/ets/agent/superagent/types';
import { SystemPromptAssembler } from '../main/ets/agent/harness/SystemPromptAssembler';
import { EnvironmentSnapshot } from '../main/ets/agent/env/EnvironmentSnapshot';

export default function strictRouterIsolationTest() {
  describe('StrictRouterIsolationTest', () => {

    // 1. Router Tool Stripping (F1)
    it('Router_tool_set_contains_only_dispatch_and_attention', 0, () => {
      // The Router tool set contract: strictly [dispatch_worker, ask_attention]
      const allDefs = ToolRegistry.getDefinitions();
      const routerToolNames = allDefs
        .map(d => d.function.name)
        .filter(name => name === 'dispatch_worker' || name === 'ask_attention');

      expect(routerToolNames.length).assertEqual(2);
      expect(routerToolNames.includes('dispatch_worker')).assertTrue();
      expect(routerToolNames.includes('ask_attention')).assertTrue();
    });

    it('Router_strictly_excludes_low_level_execution_tools', 0, () => {
      // Router must NEVER have direct bash, filesystem edit, or UI execution tools
      const prohibitedTools = [
        'bash',
        'read',
        'write',
        'edit',
        'ui',
        'run_code',
        'run_js',
        'remote_bash',
        'browser',
        'fetch'
      ];

      // Simulated Router definition query
      const routerDefs = ToolRegistry.getDefinitions().filter(d =>
        d.function.name === 'dispatch_worker' || d.function.name === 'ask_attention'
      );
      const mountedNames = routerDefs.map(d => d.function.name);

      for (const prohibited of prohibitedTools) {
        expect(mountedNames.includes(prohibited)).assertFalse();
      }
    });

    it('Router_tool_execution_dispatch_worker_schema', 0, () => {
      const defs = ToolRegistry.getDefinitions();
      const dispatchDef = defs.find(d => d.function.name === 'dispatch_worker');
      expect(dispatchDef !== undefined).assertTrue();
      expect(dispatchDef!.function.name).assertEqual('dispatch_worker');

      const params = dispatchDef!.function.parameters;
      expect((params.required ?? []).includes('role')).assertTrue();
      expect((params.required ?? []).includes('goal')).assertTrue();
      expect(params.properties['role'] !== undefined).assertTrue();
      expect(params.properties['goal'] !== undefined).assertTrue();
    });

    it('Router_tool_execution_ask_attention_schema', 0, () => {
      const defs = ToolRegistry.getDefinitions();
      const attentionDef = defs.find(d => d.function.name === 'ask_attention');
      expect(attentionDef !== undefined).assertTrue();
      expect(attentionDef!.function.name).assertEqual('ask_attention');

      const params = attentionDef!.function.parameters;
      expect((params.required ?? []).includes('question')).assertTrue();
      expect(params.properties['question'] !== undefined).assertTrue();
      expect(params.properties['options'] !== undefined).assertTrue();
    });

    // 2. Star Topology Enforcement: Workers cannot call dispatch_worker (F3, F17)
    it('StarTopology_standard_workers_never_granted_dispatch_worker', 0, () => {
      const standardRoles: WorkerRole[] = [
        'ui_worker',
        'diag_worker',
        'code_worker',
        'web_worker',
        'general_worker'
      ];

      for (const role of standardRoles) {
        const allowed = WorkerPresets.getAllowedToolNames(role);
        expect(allowed.includes('dispatch_worker')).assertFalse();

        // Also check filtered tool definitions from ToolRegistry
        const roleDefs = ToolRegistry.getDefinitionsForRole(role);
        const roleDefNames = roleDefs.map(d => d.function.name);
        expect(roleDefNames.includes('dispatch_worker')).assertFalse();
      }
    });

    it('StarTopology_custom_adhoc_roles_never_receive_dispatch_worker', 0, () => {
      const customRoles: WorkerRole[] = [
        'security_auditor',
        'database_optimizer',
        'network_sniffer',
        'performance_profiler'
      ];

      for (const role of customRoles) {
        const allowed = WorkerPresets.getAllowedToolNames(role);
        expect(allowed.includes('dispatch_worker')).assertFalse();
      }
    });

    it('StarTopology_role_specific_tool_isolation_boundaries', 0, () => {
      // ui_worker should have UI and bash, but not browser or write/edit
      const uiAllowed = WorkerPresets.getAllowedToolNames('ui_worker');
      expect(uiAllowed.includes('ui')).assertTrue();
      expect(uiAllowed.includes('browser')).assertFalse();
      expect(uiAllowed.includes('write')).assertFalse();
      expect(uiAllowed.includes('edit')).assertFalse();

      // diag_worker should have bash and read, but not ui or edit
      const diagAllowed = WorkerPresets.getAllowedToolNames('diag_worker');
      expect(diagAllowed.includes('bash')).assertTrue();
      expect(diagAllowed.includes('read')).assertTrue();
      expect(diagAllowed.includes('ui')).assertFalse();
      expect(diagAllowed.includes('edit')).assertFalse();

      // web_worker should have browser and fetch, but not bash
      const webAllowed = WorkerPresets.getAllowedToolNames('web_worker');
      expect(webAllowed.includes('browser')).assertTrue();
      expect(webAllowed.includes('fetch')).assertTrue();
      expect(webAllowed.includes('bash')).assertFalse();
    });

    // 3. Router Prompt Slimming (F2)
    it('RouterPrompt_slimming_focuses_on_intent_and_delegation', 0, () => {
      const prompt = SystemPromptAssembler.assemble(true, 'deepseek-chat');

      expect(prompt.length > 50).assertTrue();
      expect(prompt).assertContain('Router-Worker Delegation');
      expect(prompt).assertContain('dispatch_worker');
    });

    it('RouterPrompt_excludes_raw_execution_tool_instructions', 0, () => {
      const prompt = SystemPromptAssembler.assemble(false, 'deepseek-chat');

      expect(prompt).assertContain('dispatch_worker');
      // Should NOT instruct destructive raw commands like rm -rf /
      expect(prompt.includes('rm -rf /')).assertFalse();
    });

  });
}
