/*
 * LoopIntervention: Stuck, repetition, and oscillation detector for HarmonyOS Pi Harness.
 * Inspired by DeepSeek Harness (dsh-agent-loop stuck detection and intervention).
 *
 * Prevents the agent from endlessly retrying failing commands, repeating identical parameters,
 * or oscillating in failure loops without self-correcting.
 */

export interface ToolCallFingerprint {
  toolName: string;
  argsSignature: string;
  isError: boolean;
  errorSummary?: string;
  timestamp: number;
}

export class LoopIntervention {
  private history: ToolCallFingerprint[] = [];
  private consecutiveInterventions: number = 0;

  /**
   * Records a tool execution attempt.
   */
  record(
    toolName: string,
    args: Record<string, Object>,
    isError: boolean,
    error?: string
  ): void {
    let signature = '';
    try {
      signature = JSON.stringify(args);
    } catch (e) {
      signature = String(args);
    }

    const summary = error && error.length > 100 ? error.substring(0, 100) : error;

    this.history.push({
      toolName,
      argsSignature: signature,
      isError,
      errorSummary: summary,
      timestamp: Date.now()
    });

    // Retain only the most recent 12 calls to conserve memory
    if (this.history.length > 12) {
      this.history.shift();
    }
  }

  /**
   * Evaluates the execution trace and returns an intervention prompt if a stuck loop or oscillation is detected.
   */
  detectIntervention(): string | null {
    const len = this.history.length;
    if (len < 2) {
      return null;
    }

    const last = this.history[len - 1];
    const prev = this.history[len - 2];

    // Detection 1: Consecutive identical command execution failing twice
    if (
      last.toolName === prev.toolName &&
      last.argsSignature === prev.argsSignature &&
      last.isError &&
      prev.isError
    ) {
      this.consecutiveInterventions++;
      return `[HARNESS INTERVENTION] ⚠️ STUCK LOOP DETECTED: You executed tool '${last.toolName}' with the exact same arguments twice and both resulted in failure.
Rule: DO NOT execute the exact same command a third time.
Action: Stop, inspect the failure error message carefully, verify prerequisites with alternative commands, or modify your approach.`;
    }

    // Detection 2: Calling the same tool with identical arguments 3 times consecutively (looping)
    if (len >= 3) {
      const third = this.history[len - 3];
      if (
        last.toolName === prev.toolName &&
        last.toolName === third.toolName &&
        last.argsSignature === prev.argsSignature &&
        last.argsSignature === third.argsSignature
      ) {
        this.consecutiveInterventions++;
        return `[HARNESS INTERVENTION] ⚠️ REPETITIVE ACTION DETECTED: Tool '${last.toolName}' was called 3 consecutive times with identical parameters without changing strategy.
Action: Check if the desired state has already been reached, or check environment logs to verify effects.`;
      }
    }

    // Detection 3: High error oscillation (3 out of last 4 calls failed)
    if (len >= 4) {
      const recentCalls = this.history.slice(-4);
      const errorCount = recentCalls.filter(c => c.isError).length;
      if (errorCount >= 3) {
        this.consecutiveInterventions++;
        return `[HARNESS INTERVENTION] ⚠️ HIGH ERROR RATE ADVISORY: 3 of your last 4 tool actions failed.
Action: Re-evaluate your current hypothesis. Read relevant files or check system status before executing further state-mutating actions.`;
      }
    }

    return null;
  }

  detectStuckLoop(): string | null {
    return this.detectIntervention();
  }

  getConsecutiveInterventions(): number {
    return this.consecutiveInterventions;
  }

  reset(): void {
    this.history = [];
    this.consecutiveInterventions = 0;
  }
}
