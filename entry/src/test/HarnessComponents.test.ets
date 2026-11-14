/*
 * Unit tests for HarmonyOS Pi Harness Components.
 * Tests OutputTruncator, LoopIntervention, ContextCompactor, and SystemPromptAssembler.
 */
import { describe, it, expect } from '@ohos/hypium';
import { OutputTruncator } from '../main/ets/agent/harness/OutputTruncator';
import { LoopIntervention } from '../main/ets/agent/harness/LoopIntervention';
import { ContextCompactor } from '../main/ets/agent/harness/ContextCompactor';
import { EnvironmentSnapshot } from '../main/ets/agent/env/EnvironmentSnapshot';
import { SystemPromptAssembler } from '../main/ets/agent/harness/SystemPromptAssembler';
import { LlmClient } from '../main/ets/agent/LlmClient';
import { AgentModelConfig, Message, ToolDefinition } from '../main/ets/agent/types';

export default function harnessComponentsTest() {
  describe('HarnessComponentsTest', () => {

    // 1. OutputTruncator Tests
    it('OutputTruncator_short_output_unmodified', 0, () => {
      const shortText = 'uid=2000(shell) gid=2000(shell)';
      const result = OutputTruncator.truncate(shortText, 100);
      expect(result).assertEqual(shortText);
    });

    it('OutputTruncator_head_tail_preservation', 0, () => {
      // Create a 200-line string where head and tail have distinct markers
      const lines: string[] = [];
      for (let i = 1; i <= 200; i++) {
        lines.push(`Line ${i}: log message entry`);
      }
      lines[0] = 'START_OF_LOG_HEADER';
      lines[199] = 'CRITICAL_FINAL_ERROR: exit code 1';
      const fullText = lines.join('\n');

      const truncated = OutputTruncator.truncate(fullText, 500, 10, 10);
      expect(truncated).assertContain('START_OF_LOG_HEADER');
      expect(truncated).assertContain('CRITICAL_FINAL_ERROR: exit code 1');
      expect(truncated).assertContain('Truncated');
      expect(truncated).assertContain('Showing first 10 lines');
    });

    it('OutputTruncator_formatStructuredResult', 0, () => {
      const resSuccess = OutputTruncator.formatStructuredResult('bash', 'success output', false, undefined, 15);
      expect(resSuccess).assertContain('[TOOL RESULT: bash | STATUS: SUCCESS | DURATION: 15ms]');
      expect(resSuccess).assertContain('success output');

      const resError = OutputTruncator.formatStructuredResult('bash', 'fail output', true, 'command not found', 8);
      expect(resError).assertContain('[TOOL RESULT: bash | STATUS: ERROR | DURATION: 8ms]');
      expect(resError).assertContain('fail output');
      expect(resError).assertContain('Error Detail: command not found');
    });

    // 2. LoopIntervention Tests
    it('LoopIntervention_detects_consecutive_identical_failure', 0, () => {
      const intervention = new LoopIntervention();

      // Normal first call
      intervention.record('bash', { 'command': 'cat /nonexistent' }, true, 'No such file or directory');
      expect(intervention.detectIntervention()).assertNull();

      // Second identical failing call -> must trigger stuck loop warning
      intervention.record('bash', { 'command': 'cat /nonexistent' }, true, 'No such file or directory');
      const warning = intervention.detectIntervention();
      expect(warning !== null).assertTrue();
      expect(warning || '').assertContain('STUCK LOOP DETECTED');
      expect(warning || '').assertContain('DO NOT execute the exact same command');
    });

    it('LoopIntervention_detects_repetitive_loop_3_times', 0, () => {
      const intervention = new LoopIntervention();
      const args: Record<string, Object> = { 'action': 'status' };

      intervention.record('goal', args, false);
      expect(intervention.detectIntervention()).assertNull();

      intervention.record('goal', args, false);
      expect(intervention.detectIntervention()).assertNull();

      intervention.record('goal', args, false);
      const warning = intervention.detectIntervention();
      expect(warning !== null).assertTrue();
      expect(warning || '').assertContain('REPETITIVE ACTION DETECTED');
    });

    it('LoopIntervention_detects_high_error_oscillation', 0, () => {
      const intervention = new LoopIntervention();

      intervention.record('bash', { 'command': 'cmd1' }, true, 'err 1');
      intervention.record('read', { 'path': '/p1' }, false);
      intervention.record('bash', { 'command': 'cmd2' }, true, 'err 2');
      intervention.record('edit', { 'path': '/p2' }, true, 'err 3');

      const warning = intervention.detectIntervention();
      expect(warning !== null).assertTrue();
      expect(warning || '').assertContain('HIGH ERROR RATE ADVISORY');
    });

    // 3. ContextCompactor Tests
    it('ContextCompactor_short_history_no_compaction', 0, () => {
      const msgs: Message[] = [
        { role: 'system', content: 'system' },
        { role: 'user', content: 'hello' },
        { role: 'assistant', content: 'hi' }
      ];
      const result = ContextCompactor.compact(msgs);
      expect(result.length).assertEqual(3);
    });

    it('ContextCompactor_preserves_initial_objective_and_distills_facts', 0, () => {
      const msgs: Message[] = [
        { role: 'system', content: 'system prompt' },
        { role: 'user', content: 'Diagnose why ability fails to launch on HarmonyOS' },
        {
          role: 'assistant',
          content: 'I will inspect the log',
          tool_calls: [
            {
              id: 'call_1',
              type: 'function',
              function: { name: 'read', arguments: '{"path":"/data/local/tmp/app.log"}' }
            }
          ]
        },
        { role: 'tool', name: 'read', tool_call_id: 'call_1', content: 'log line 1\nlog line 2' },
        {
          role: 'assistant',
          content: 'I will check process status',
          tool_calls: [
            {
              id: 'call_2',
              type: 'function',
              function: { name: 'bash', arguments: '{"command":"ps -ef"}' }
            }
          ]
        },
        { role: 'tool', name: 'bash', tool_call_id: 'call_2', content: 'Error: process not found' },
        { role: 'user', content: 'Check permissions' },
        { role: 'assistant', content: 'Checking' },
        { role: 'user', content: 'Turn 4' },
        { role: 'assistant', content: 'Turn 4 reply' },
        { role: 'user', content: 'Turn 5' },
        { role: 'assistant', content: 'Turn 5 reply' },
        { role: 'user', content: 'Turn 6' },
        { role: 'assistant', content: 'Turn 6 reply' },
        { role: 'user', content: 'Turn 7' },
        { role: 'assistant', content: 'Turn 7 reply' }
      ];

      const compacted = ContextCompactor.compact(msgs, 4);
      expect(compacted[0].role).assertEqual('system');
      expect(compacted[1].role).assertEqual('user');
      expect(compacted[1].content).assertContain('SESSION CHECKPOINT');
      expect(compacted[1].content).assertContain('Diagnose why ability fails');
      expect(compacted[1].content).assertContain('/data/local/tmp/app.log');
      expect(compacted[2].role).assertEqual('assistant');
      expect(compacted[2].content).assertContain('distilled session checkpoint');
    });

    it('ContextCompactor_single_user_prompt_autonomous_tool_loop_compaction', 0, () => {
      // Simulates a single user prompt followed by 9 assistant+tool turns (20 messages total)
      const msgs: Message[] = [
        { role: 'system', content: 'system prompt' },
        { role: 'user', content: 'Fetch and analyze airbnb article via worker' }
      ];
      for (let i = 1; i <= 9; i++) {
        msgs.push({
          role: 'assistant',
          content: '',
          tool_calls: [
            {
              id: `call_${i}`,
              type: 'function',
              function: { name: 'fetch', arguments: `{"url":"https://example.com/${i}"}` }
            }
          ]
        });
        msgs.push({
          role: 'tool',
          name: 'fetch',
          tool_call_id: `call_${i}`,
          content: `Response chunk ${i}`
        });
      }

      const compacted = ContextCompactor.compact(msgs, 8);
      // Must NOT return empty or sever assistant->tool pairs
      expect(compacted.length > 0).assertTrue();
      expect(compacted !== msgs).assertTrue();
      expect(compacted[0].role).assertEqual('system');
      expect(compacted[1].role).assertEqual('user');
      expect(compacted[1].content).assertContain('SESSION CHECKPOINT');
      expect(compacted[1].content).assertContain('Fetch and analyze airbnb article');
      // Recent window starts cleanly with assistant turn after checkpoint user msg
      expect(compacted[2].role).assertEqual('assistant');
      expect(compacted[3].role).assertEqual('tool');
    });

    // 4. EnvironmentSnapshot & SystemPromptAssembler Tests
    it('EnvironmentSnapshot_contains_essential_anchors', 0, () => {
      const snap = EnvironmentSnapshot.formatForPrompt();
      expect(snap).assertContain('HarmonyOS NEXT');
      expect(snap).assertContain('uid=2000(shell)');
      expect(snap).assertContain('/data/local/tmp');
      expect(snap).assertContain('1256x2760');
    });

    it('SystemPromptAssembler_assembles_waterfall_sections', 0, () => {
      const prompt = SystemPromptAssembler.assemble(true, 'deepseek-chat');
      expect(prompt).assertContain('You are an expert AI system and coding automation agent');
      expect(prompt).assertContain('[Current Runtime Environment]');
      expect(prompt).assertContain('[Available Native Tools]');
      expect(prompt).assertContain('[Operational Protocol & Principles]');
      expect(prompt).assertContain('NEVER run \'curl\' or \'wget\' in bash');
      expect(prompt).assertContain('uitest uiInput text');
    });

    it('SystemPromptAssembler_adapts_for_deepseek_r1_reasoning', 0, () => {
      const promptR1 = SystemPromptAssembler.assemble(true, 'deepseek-reasoner');
      expect(promptR1).assertContain('DeepSeek-R1 native reasoning is active');
    });

    // 5. LlmClient Wire Protocol Sanitizer Tests (Prevent Error 2013)
    it('LlmClient_sanitizeMessages_repairs_stopped_and_delayed_tool', 0, () => {
      const broken: Message[] = [
        { role: 'system', content: 'sys' },
        { role: 'user', content: 'run bash' },
        {
          role: 'assistant',
          content: '',
          tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'bash', arguments: '{"command":"ls"}' } }]
        },
        { role: 'assistant', content: '⏹️ **任务已手动停止**。' },
        { role: 'tool', tool_call_id: 'call_1', name: 'bash', content: 'late output' },
        { role: 'user', content: 'retry please' }
      ];

      const fixed = LlmClient.sanitizeMessages(broken);
      // Expected: system -> user -> assistant(tc) -> tool(call_1 synthesized) -> assistant(stopped) -> user(retry)
      expect(fixed.length).assertEqual(6);
      expect(fixed[2].role).assertEqual('assistant');
      expect(fixed[3].role).assertEqual('tool');
      expect(fixed[3].tool_call_id).assertEqual('call_1');
      expect(fixed[4].role).assertEqual('assistant');
      expect(fixed[5].role).assertEqual('user');
    });

    it('LlmClient_sanitizeMessages_repairs_interleaved_multi_tool_intervention', 0, () => {
      const broken: Message[] = [
        { role: 'system', content: 'sys' },
        { role: 'user', content: 'check two urls' },
        {
          role: 'assistant',
          content: '',
          tool_calls: [
            { id: 'c1', type: 'function', function: { name: 'fetch', arguments: '{"url":"https://a.com"}' } },
            { id: 'c2', type: 'function', function: { name: 'fetch', arguments: '{"url":"https://b.com"}' } }
          ]
        },
        { role: 'tool', tool_call_id: 'c1', name: 'fetch', content: 'ok a' },
        { role: 'user', content: '[Loop Intervention]' },
        { role: 'tool', tool_call_id: 'c2', name: 'fetch', content: 'late b' }
      ];

      const fixed = LlmClient.sanitizeMessages(broken);
      // Expected: system -> user -> assistant(c1,c2) -> tool(c1: ok a) -> tool(c2 synthesized) -> user(intervention)
      expect(fixed.length).assertEqual(6);
      expect(fixed[3].role).assertEqual('tool');
      expect(fixed[3].tool_call_id).assertEqual('c1');
      expect(fixed[3].content).assertEqual('ok a');
      expect(fixed[4].role).assertEqual('tool');
      expect(fixed[4].tool_call_id).assertEqual('c2');
      expect(fixed[5].role).assertEqual('user');
    });

    it('LlmClient_sanitizeMessages_repairs_dangling_tool_call_before_user', 0, () => {
      const broken: Message[] = [
        { role: 'system', content: 'sys' },
        { role: 'user', content: 'do work' },
        {
          role: 'assistant',
          content: '',
          tool_calls: [{ id: 'c_miss', type: 'function', function: { name: 'bash', arguments: '{"command":"pwd"}' } }]
        },
        { role: 'user', content: 'continue' }
      ];

      const fixed = LlmClient.sanitizeMessages(broken);
      expect(fixed.length).assertEqual(5);
      expect(fixed[3].role).assertEqual('tool');
      expect(fixed[3].tool_call_id).assertEqual('c_miss');
      expect(fixed[4].role).assertEqual('user');
    });

    // 6. Multimodal Image Serialization & MiniMax Thinking Tests
    it('LlmClient_formats_multimodal_user_and_tool_messages_for_minimax', 0, () => {
      const cfg: AgentModelConfig = {
        baseUrl: 'https://api.minimax.cn/v1',
        apiKey: 'k',
        modelName: 'MiniMax-M3.1-Flash',
        autoRunTools: true,
        enableThinking: true
      };
      const msgs: Message[] = [
        { role: 'system', content: 'sys' },
        {
          role: 'user',
          content: 'Analyze this screenshot',
          images: [{ dataUrl: 'data:image/jpeg;base64,AAA', detail: 'high' }]
        },
        {
          role: 'assistant',
          content: '',
          tool_calls: [{ id: 'c_img', type: 'function', function: { name: 'inspect_image', arguments: '{"source":"screen"}' } }]
        },
        {
          role: 'tool',
          tool_call_id: 'c_img',
          name: 'inspect_image',
          content: 'Captured screen',
          images: [{ dataUrl: 'data:image/jpeg;base64,BBB', detail: 'default' }]
        }
      ];

      const payload = LlmClient.buildRequestPayload(cfg, msgs, ([] as ToolDefinition[]), true);
      expect(payload['reasoning_effort']).assertEqual('high');
      const wireMsgs = payload['messages'] as Record<string, Object>[];
      expect(wireMsgs.length).assertEqual(4);
      const userParts = wireMsgs[1]['content'] as Record<string, Object>[];
      expect(userParts.length).assertEqual(2);
      expect(userParts[1]['type']).assertEqual('image_url');
      const toolParts = wireMsgs[3]['content'] as Record<string, Object>[];
      expect(toolParts.length).assertEqual(2);
      expect(toolParts[1]['type']).assertEqual('image_url');
    });

    it('LlmClient_moves_tool_images_to_user_turn_for_non_minimax', 0, () => {
      const cfg: AgentModelConfig = {
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'k',
        modelName: 'gpt-4o',
        autoRunTools: true,
        enableThinking: false
      };
      const msgs: Message[] = [
        { role: 'system', content: 'sys' },
        {
          role: 'assistant',
          content: '',
          tool_calls: [
            { id: 'c1', type: 'function', function: { name: 'inspect_image', arguments: '{}' } },
            { id: 'c2', type: 'function', function: { name: 'bash', arguments: '{}' } }
          ]
        },
        {
          role: 'tool',
          tool_call_id: 'c1',
          name: 'inspect_image',
          content: 'screen',
          images: [{ dataUrl: 'data:image/jpeg;base64,CCC', detail: 'low' }]
        },
        {
          role: 'tool',
          tool_call_id: 'c2',
          name: 'bash',
          content: 'done'
        }
      ];

      const payload = LlmClient.buildRequestPayload(cfg, msgs, ([] as ToolDefinition[]), true);
      const wireMsgs = payload['messages'] as Record<string, Object>[];
      // Synthetic user image message must appear AFTER all sibling tool results close!
      expect(wireMsgs.length).assertEqual(5);
      expect(wireMsgs[2]['role']).assertEqual('tool');
      expect(typeof wireMsgs[2]['content']).assertEqual('string');
      expect(wireMsgs[3]['role']).assertEqual('tool');
      expect(wireMsgs[4]['role']).assertEqual('user');
    });

  });
}
