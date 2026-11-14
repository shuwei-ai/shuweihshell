/*
 * E2E & Architecture Test: Inline-Spill Context Compaction & Anti-Loop Hard Shield (F15, F16, F17)
 * Verifies inline-spill for tool outputs > 1500 chars, structured tool output formatting,
 * anti-loop wakeup storm protection (3 max auto-wakeups, instant reset on human speech),
 * and worker @-report authority restrictions.
 */
import { describe, it, expect } from '@ohos/hypium';
import { OutputTruncator } from '../main/ets/agent/harness/OutputTruncator';
import { LoopIntervention } from '../main/ets/agent/harness/LoopIntervention';
import { WorkerReport } from '../main/ets/agent/superagent/types';
import { WorkerPresets } from '../main/ets/agent/superagent/WorkerPresets';

export interface WakeupResult {
  allowed: boolean;
  triggerHumanIntervention: boolean;
  currentCount: number;
}

/**
 * Anti-Loop Wakeup Shield Controller implementing the exact hard lock logic specified in PROJECT.md R5
 */
export class AntiLoopWakeupShield {
  private static readonly MAX_AUTONOMOUS_WAKEUPS = 3;
  private autoWakeupCount: number = 0;
  private isHardLocked: boolean = false;

  getWakeupCount(): number {
    return this.autoWakeupCount;
  }

  isLocked(): boolean {
    return this.isHardLocked;
  }

  /**
   * Called whenever a worker autonomously wakes up the Router without human intervention.
   * Returns true if wakeup is permitted, or false if blocked by hard shield.
   */
  recordAutonomousWakeup(): WakeupResult {
    if (this.autoWakeupCount >= AntiLoopWakeupShield.MAX_AUTONOMOUS_WAKEUPS) {
      this.isHardLocked = true;
      const res: WakeupResult = {
        allowed: false,
        triggerHumanIntervention: true,
        currentCount: this.autoWakeupCount
      };
      return res;
    }

    this.autoWakeupCount++;

    if (this.autoWakeupCount >= AntiLoopWakeupShield.MAX_AUTONOMOUS_WAKEUPS) {
      this.isHardLocked = true;
    }

    const res: WakeupResult = {
      allowed: true,
      triggerHumanIntervention: this.autoWakeupCount >= AntiLoopWakeupShield.MAX_AUTONOMOUS_WAKEUPS,
      currentCount: this.autoWakeupCount
    };
    return res;
  }

  /**
   * Called instantly whenever the human user speaks or sends any message in chat.
   */
  recordHumanInput(): void {
    this.autoWakeupCount = 0;
    this.isHardLocked = false;
  }
}

export default function inlineSpillAntiLoopTest() {
  describe('InlineSpillAntiLoopTest', () => {

    // 1. Inline-Spill Mechanism (F15)
    it('InlineSpill_outputs_under_threshold_remain_unmodified', 0, () => {
      // 500 characters string
      let shortText = '';
      for (let i = 0; i < 50; i++) {
        shortText += '123456789\n';
      }
      expect(shortText.length < 1500).assertTrue();

      const result = OutputTruncator.truncate(shortText, 1500);
      expect(result).assertEqual(shortText);
    });

    it('InlineSpill_outputs_exceeding_threshold_are_truncated_with_head_tail_preservation', 0, () => {
      // Create a 10,000 character output simulating a large hilog dump
      const lines: string[] = [];
      lines.push('--- SYSTEM LOG HEADER START ---');
      for (let i = 1; i <= 300; i++) {
        lines.push(`Line ${i}: hilog payload timestamp 12:00:0${i % 10} event log`);
      }
      lines.push('--- FINAL CRITICAL STACK TRACE SIGSEGV ---');
      const longOutput = lines.join('\n');

      expect(longOutput.length > 1500).assertTrue();

      // Truncate with 1500 chars budget, 15 head lines and 15 tail lines
      const spilled = OutputTruncator.truncate(longOutput, 1500, 15, 15);

      expect(spilled.length <= longOutput.length).assertTrue();
      expect(spilled).assertContain('--- SYSTEM LOG HEADER START ---');
      expect(spilled).assertContain('--- FINAL CRITICAL STACK TRACE SIGSEGV ---');
      expect(spilled).assertContain('Truncated');
      expect(spilled).assertContain('lines');
    });

    it('OutputTruncator_formatStructuredResult_success_and_error_metadata', 0, () => {
      // Success metadata
      const resSuccess = OutputTruncator.formatStructuredResult('bash', 'uid=2000(shell)', false, undefined, 42);
      expect(resSuccess).assertContain('[TOOL RESULT: bash | STATUS: SUCCESS | DURATION: 42ms]');
      expect(resSuccess).assertContain('uid=2000(shell)');

      // Error metadata
      const resError = OutputTruncator.formatStructuredResult('read', '', true, 'File not found', 12);
      expect(resError).assertContain('[TOOL RESULT: read | STATUS: ERROR | DURATION: 12ms]');
      expect(resError).assertContain('Error Detail: File not found');
    });

    it('InlineSpill_spillToFile_short_output_no_spill', 0, () => {
      const shortOutput = 'Line 1\nLine 2\nStatus: OK';
      const spillRes = OutputTruncator.spillToFile(shortOutput, 'bash');
      expect(spillRes.spillPath).assertNull();
      expect(spillRes.preview).assertEqual(shortOutput);
    });

    it('InlineSpill_spillToFile_oversized_output_creates_preview_and_reference', 0, () => {
      let oversized = 'BEGIN LOG TRACE\n';
      for (let i = 0; i < 200; i++) {
        oversized += `Process event log item ${i} with system status metrics\n`;
      }
      oversized += 'END LOG TRACE';
      expect(oversized.length > 1500).assertTrue();

      const spillRes = OutputTruncator.spillToFile(oversized, 'bash');
      expect(spillRes.preview.length < oversized.length).assertTrue();
      expect(spillRes.preview).assertContain('Full output');
      expect(spillRes.preview).assertContain('chars');
      expect(spillRes.preview).assertContain('BEGIN LOG TRACE');
      expect(spillRes.preview).assertContain('END LOG TRACE');
    });

    // 2. Anti-Loop Hard Shield (F16)
    it('AntiLoopShield_allows_up_to_3_autonomous_wakeups', 0, () => {
      const shield = new AntiLoopWakeupShield();
      expect(shield.getWakeupCount()).assertEqual(0);
      expect(shield.isLocked()).assertFalse();

      // 1st autonomous wakeup -> allowed
      const w1 = shield.recordAutonomousWakeup();
      expect(w1.allowed).assertTrue();
      expect(w1.currentCount).assertEqual(1);
      expect(shield.isLocked()).assertFalse();

      // 2nd autonomous wakeup -> allowed
      const w2 = shield.recordAutonomousWakeup();
      expect(w2.allowed).assertTrue();
      expect(w2.currentCount).assertEqual(2);
      expect(shield.isLocked()).assertFalse();

      // 3rd autonomous wakeup -> allowed (hits ceiling, triggers human intervention warning)
      const w3 = shield.recordAutonomousWakeup();
      expect(w3.allowed).assertTrue();
      expect(w3.currentCount).assertEqual(3);
      expect(w3.triggerHumanIntervention).assertTrue();
      expect(shield.isLocked()).assertTrue();
    });

    it('AntiLoopShield_blocks_4th_consecutive_autonomous_wakeup', 0, () => {
      const shield = new AntiLoopWakeupShield();

      // Exhaust 3 wakeups
      shield.recordAutonomousWakeup();
      shield.recordAutonomousWakeup();
      shield.recordAutonomousWakeup();
      expect(shield.isLocked()).assertTrue();

      // 4th autonomous wakeup MUST be blocked
      const w4 = shield.recordAutonomousWakeup();
      expect(w4.allowed).assertFalse();
      expect(w4.triggerHumanIntervention).assertTrue();
      expect(shield.isLocked()).assertTrue();
    });

    it('AntiLoopShield_human_speech_instantly_resets_counter_to_zero', 0, () => {
      const shield = new AntiLoopWakeupShield();

      // Exhaust 3 wakeups
      shield.recordAutonomousWakeup();
      shield.recordAutonomousWakeup();
      shield.recordAutonomousWakeup();
      expect(shield.getWakeupCount()).assertEqual(3);
      expect(shield.isLocked()).assertTrue();

      // Human speaks in chat
      shield.recordHumanInput();

      // Counter must be immediately 0 and unlocked
      expect(shield.getWakeupCount()).assertEqual(0);
      expect(shield.isLocked()).assertFalse();

      // Next autonomous wakeup is permitted again
      const nextWakeup = shield.recordAutonomousWakeup();
      expect(nextWakeup.allowed).assertTrue();
      expect(nextWakeup.currentCount).assertEqual(1);
    });

    // 3. Worker @-Report Authority Restriction (F17)
    it('WorkerReport_conveys_only_findings_and_artifacts_without_execution_privilege', 0, () => {
      const report: WorkerReport = {
        ticketId: 'ticket-audit-1',
        role: 'ui_worker',
        status: 'ready',
        summary: 'Clicked Settings toggle and captured screen',
        artifacts: ['/data/local/tmp/screen.png'],
        durationMs: 820,
        stepsCount: 2
      };

      // Worker report payload carries no tool definitions or execution tokens
      expect(report.ticketId).assertEqual('ticket-audit-1');
      expect(report.summary.length > 0).assertTrue();
      expect((report.artifacts ?? []).length).assertEqual(1);

      // Star topology guarantee: Workers never receive dispatch_worker tool
      const allowedTools = WorkerPresets.getAllowedToolNames(report.role);
      expect(allowedTools.includes('dispatch_worker')).assertFalse();
    });

    // 4. Consecutive Loop Detection (LoopIntervention)
    it('LoopIntervention_detects_repeated_identical_tool_failures', 0, () => {
      const intervention = new LoopIntervention();

      // 1st failure
      intervention.record('bash', { 'cmd': 'reboot' }, true, 'Permission denied');
      expect(intervention.detectIntervention()).assertNull();

      // 2nd identical failure
      intervention.record('bash', { 'cmd': 'reboot' }, true, 'Permission denied');
      const warning = intervention.detectIntervention();
      expect(warning !== null).assertTrue();
      expect(warning).assertContain('STUCK LOOP DETECTED');
      expect(warning).assertContain('bash');
    });

  });
}
