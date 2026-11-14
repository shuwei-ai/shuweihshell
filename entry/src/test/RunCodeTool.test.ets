/*
 * Unit tests for RunCodeTool and RunJsTool.
 * Tests tool schemas, parameter validation, language routing, output formatting,
 * timeout handling, and ToolRegistry / ToolConcurrency integration.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { describe, it, expect } from '@ohos/hypium';
import { RunCodeTool } from '../main/ets/agent/tools/RunCodeTool';
import { RunJsTool } from '../main/ets/agent/tools/RunJsTool';
import { ToolRegistry } from '../main/ets/agent/tools/ToolRegistry';
import { ToolConcurrency } from '../main/ets/agent/tools/ToolConcurrency';
import { JsEvalNativeResult, PyEvalNativeResult } from '../main/ets/common/NativeBridge';

export default function runCodeToolTest() {
  describe('RunCodeToolTest', () => {

    it('RunCodeTool_definition_and_parameters', 0, () => {
      const def = RunCodeTool.getDefinition();
      expect(def.function.name).assertEqual('run_code');
      expect(def.function.parameters.properties['code'] !== undefined).assertTrue();
      expect(def.function.parameters.properties['path'] !== undefined).assertTrue();
      expect(def.function.parameters.properties['language'] !== undefined).assertTrue();
      expect(def.function.parameters.properties['input_json'] !== undefined).assertTrue();
      expect(def.function.parameters.properties['timeout_ms'] !== undefined).assertTrue();
    });

    it('RunJsTool_definition_backward_compatibility', 0, () => {
      const def = RunJsTool.getDefinition();
      expect(def.function.name).assertEqual('run_js');
      expect((def.function.parameters.required ?? []).includes('code')).assertTrue();
    });

    it('RunCodeTool_rejects_empty_code_and_path', 0, async (done: () => void) => {
      const res = await RunCodeTool.execute('call-1', { 'code': '   ' });
      expect(res.isError).assertTrue();
      expect(res.error).assertContain('Either "code" or "path" must be provided');
      done();
    });

    it('RunCodeTool_rejects_unsupported_language', 0, async (done: () => void) => {
      const res = await RunCodeTool.execute('call-2', { 'code': 'puts 1', 'language': 'ruby' });
      expect(res.isError).assertTrue();
      expect(res.error).assertContain('Unsupported language');
      done();
    });

    it('RunCodeTool_executes_python_via_custom_runner', 0, async (done: () => void) => {
      let capturedCode = '';
      let capturedJson = '';
      let capturedTimeout = 0;

      RunCodeTool.setCustomPyRunner(async (code: string, inputJson: string, timeoutMs: number): Promise<PyEvalNativeResult> => {
        capturedCode = code;
        capturedJson = inputJson;
        capturedTimeout = timeoutMs;
        const mockRes: PyEvalNativeResult = {
          ok: true,
          stdout: 'hello from python\n42',
          stderr: '',
          timedOut: false,
          elapsedMs: 12
        };
        return mockRes;
      });

      const res = await RunCodeTool.execute('call-3', {
        'code': 'print("hello from python")\nprint(42)',
        'language': 'python',
        'input_json': '{"key": "value"}',
        'timeout_ms': 3000
      });

      expect(res.isError).assertFalse();
      expect(res.output).assertContain('hello from python');
      expect(res.output).assertContain('42');
      expect(res.output).assertContain('Elapsed: 12ms');
      expect(capturedCode).assertContain('print("hello from python")');
      expect(capturedJson).assertEqual('{"key": "value"}');
      expect(capturedTimeout).assertEqual(3000);

      RunCodeTool.setCustomPyRunner(null);
      done();
    });

    it('RunCodeTool_handles_python_timeout', 0, async (done: () => void) => {
      RunCodeTool.setCustomPyRunner(async (_c: string, _j: string, timeoutMs: number): Promise<PyEvalNativeResult> => {
        const mockRes: PyEvalNativeResult = {
          ok: false,
          stdout: 'partial progress\n',
          stderr: `Execution timed out after ${timeoutMs}ms`,
          timedOut: true,
          elapsedMs: timeoutMs
        };
        return mockRes;
      });

      const res = await RunCodeTool.execute('call-4', {
        'code': 'while True: pass',
        'language': 'py', // Should normalize 'py' to 'python'
        'timeout_ms': 500
      });

      expect(res.isError).assertTrue();
      expect(res.error).assertContain('[Execution Timed Out]');
      expect(res.output).assertContain('partial progress');

      RunCodeTool.setCustomPyRunner(null);
      done();
    });

    it('RunCodeTool_handles_python_runtime_error', 0, async (done: () => void) => {
      RunCodeTool.setCustomPyRunner(async (_c: string, _j: string, _t: number): Promise<PyEvalNativeResult> => {
        const mockRes: PyEvalNativeResult = {
          ok: false,
          stdout: '',
          stderr: 'ZeroDivisionError: divide by zero',
          timedOut: false,
          elapsedMs: 5
        };
        return mockRes;
      });

      const res = await RunCodeTool.execute('call-5', {
        'code': '1 // 0',
        'language': 'python'
      });

      expect(res.isError).assertTrue();
      expect(res.error).assertContain('[Python Error]');
      expect(res.error).assertContain('ZeroDivisionError');

      RunCodeTool.setCustomPyRunner(null);
      done();
    });

    it('RunCodeTool_executes_javascript_via_custom_runner', 0, async (done: () => void) => {
      RunCodeTool.setCustomJsRunner(async (_c: string, _j: string, _t: number): Promise<JsEvalNativeResult> => {
        const mockRes: JsEvalNativeResult = {
          ok: true,
          result: '100',
          logs: 'log from js',
          error: '',
          elapsedMs: 8
        };
        return mockRes;
      });

      const res = await RunCodeTool.execute('call-6', {
        'code': 'console.log("log from js"); 50 * 2',
        'language': 'javascript'
      });

      expect(res.isError).assertFalse();
      expect(res.output).assertContain('log from js');
      expect(res.output).assertContain('100');

      RunCodeTool.setCustomJsRunner(null);
      done();
    });

    it('RunJsTool_delegates_to_RunCodeTool', 0, async (done: () => void) => {
      RunCodeTool.setCustomJsRunner(async (_c: string, _j: string, _t: number): Promise<JsEvalNativeResult> => {
        const mockRes: JsEvalNativeResult = {
          ok: true,
          result: '42',
          logs: '',
          error: '',
          elapsedMs: 3
        };
        return mockRes;
      });

      const res = await RunJsTool.execute('call-7', {
        'code': '40 + 2'
      });

      expect(res.toolName).assertEqual('run_js');
      expect(res.isError).assertFalse();
      expect(res.output).assertContain('42');

      RunCodeTool.setCustomJsRunner(null);
      done();
    });

    it('ToolRegistry_contains_run_code_and_run_js', 0, () => {
      const defs = ToolRegistry.getDefinitions();
      const names = defs.map(d => d.function.name);
      expect(names.includes('run_code')).assertTrue();
      expect(names.includes('run_js')).assertTrue();
    });

    it('ToolConcurrency_treats_run_code_as_read_only', 0, () => {
      expect(ToolConcurrency.isReadOnly('run_code')).assertTrue();
      expect(ToolConcurrency.isReadOnly('run_js')).assertTrue();
      expect(ToolConcurrency.isReadOnly('bash')).assertFalse();
    });

    it('RunCodeTool_handles_missing_path_file', 0, async (done: () => void) => {
      const res = await RunCodeTool.execute('call-path-err', {
        'path': 'non_existent_script.py'
      });
      expect(res.isError).assertTrue();
      expect(res.error).assertContain('Failed to load script file');
      done();
    });

  });
}
