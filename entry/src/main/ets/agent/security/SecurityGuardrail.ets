/*
 * SecurityGuardrail: Deep Inspection & Protection Engine for HarmonyOS Shell Execution.
 * Intercepts high-risk destructive commands (rm -rf /, format, raw partition dd, reboot, init kill)
 * executed with uid-2000 shell privileges, preventing irreversible system damage from hallucinations.
 */

export interface GuardrailCheckResult {
  isBlocked: boolean;
  riskLevel: string;
  reason: string;
  matchedPattern: string;
}

export class GuardrailPatternItem {
  regex: RegExp;
  reason: string;

  constructor(regex: RegExp, reason: string) {
    this.regex = regex;
    this.reason = reason;
  }
}

export class SecurityGuardrail {
  private static enabled: boolean = true;

  static setEnabled(enabled: boolean): void {
    SecurityGuardrail.enabled = enabled;
  }

  static isEnabled(): boolean {
    return SecurityGuardrail.enabled;
  }

  /**
   * Dangerous patterns that pose irreversible system destruction risks.
   */
  private static readonly CRITICAL_PATTERNS: GuardrailPatternItem[] = [
    new GuardrailPatternItem(
      /\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*)\s+(\/|\/\*|\/system|\/data|\/data\/storage|\/data\/app|\/vendor)(\s|$)/i,
      'Attempted catastrophic recursive deletion of root or critical system/data partitions'
    ),
    new GuardrailPatternItem(
      /\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*)\s+(\*|\.\.|\.\/.*)(\s|$)/i,
      'Unbounded wildcard or parent directory recursive deletion'
    ),
    new GuardrailPatternItem(
      /\bdd\s+.*of=\/dev\/(block\/.*|[a-z0-9]+)/i,
      'Direct raw block device overwriting via dd'
    ),
    new GuardrailPatternItem(
      /\b(mkfs|mke2fs|mkdosfs|fdisk|parted|wipefs)\b/i,
      'Filesystem formatting or partition alteration tool detected'
    ),
    new GuardrailPatternItem(
      /\b(reboot|poweroff|shutdown|halt)\b/i,
      'System power control or reboot command executed directly in autonomous loop'
    ),
    new GuardrailPatternItem(
      /\bkill\s+-9\s+1\b|\bpkill\s+-9\s+(init|appspawn)\b/i,
      'Attempt to terminate PID 1 or core init/appspawn system daemons'
    ),
    new GuardrailPatternItem(
      /:\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/,
      'Shell fork bomb pattern detected'
    ),
    new GuardrailPatternItem(
      /\bchmod\s+-R\s+000\s+(\/|\/data|\/system)/i,
      'Destructive recursive zero-permission change on system or data partition'
    )
  ];

  /**
   * Evaluates a shell command string against safety rules.
   */
  static inspectCommand(command: string): GuardrailCheckResult {
    if (!SecurityGuardrail.enabled || !command || command.trim().length === 0) {
      return {
        isBlocked: false,
        riskLevel: 'safe',
        reason: '',
        matchedPattern: ''
      };
    }

    const trimmed = command.trim();

    for (let i = 0; i < SecurityGuardrail.CRITICAL_PATTERNS.length; i++) {
      const item = SecurityGuardrail.CRITICAL_PATTERNS[i];
      if (item.regex.test(trimmed)) {
        return {
          isBlocked: true,
          riskLevel: 'dangerous',
          reason: item.reason,
          matchedPattern: item.regex.source
        };
      }
    }

    return {
      isBlocked: false,
      riskLevel: 'safe',
      reason: '',
      matchedPattern: ''
    };
  }
}
