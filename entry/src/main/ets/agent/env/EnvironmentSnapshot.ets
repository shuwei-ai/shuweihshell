/*
 * EnvironmentSnapshot: Provides real-time and static runtime environment context for HarmonyOS Pi Agent.
 * Inspired by DeepSeek Harness (dsh workspace and runtime context injection).
 *
 * Provides a strong "Environment Anchor" to eliminate hallucination about platform boundaries,
 * available binaries, device resolutions, and user privileges.
 */
import { AgentWorkspace } from '../tools/AgentWorkspace';

export interface ScreenResolution {
  width: number;
  height: number;
}

export interface DeviceEnvironmentInfo {
  platform: string;
  architecture: string;
  privilege: string;
  workspaceDir: string;
  systemTmpDir: string;
  screenWidth: number;
  screenHeight: number;
  timestampStr: string;
  networkConstraint: string;
  uiAutomationBridge: string;
}

export class EnvironmentSnapshot {
  private static cachedResolution: ScreenResolution = { width: 1256, height: 2760 };

  static updateResolution(width: number, height: number): void {
    if (width > 0 && height > 0) {
      EnvironmentSnapshot.cachedResolution = { width: width, height: height };
    }
  }

  static getSnapshot(): DeviceEnvironmentInfo {
    const now = new Date();
    const pad = (n: number): string => (n < 10 ? '0' + n : String(n));
    const timeStr = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;

    const info: DeviceEnvironmentInfo = {
      platform: 'HarmonyOS NEXT',
      architecture: 'aarch64',
      privilege: 'uid=2000(shell) gid=2000(shell) context=u:r:shell:s0 (Bypasses standard application sandbox)',
      workspaceDir: AgentWorkspace.getInstance().getWorkspaceRoot(),
      systemTmpDir: '/data/local/tmp',
      screenWidth: EnvironmentSnapshot.cachedResolution.width,
      screenHeight: EnvironmentSnapshot.cachedResolution.height,
      timestampStr: timeStr,
      networkConstraint: 'Device shell has NO curl, wget, python, or node/npm. Use "fetch" for HTTP, "run_code" (supports Python 3 and JavaScript) for offline data computation/JSON processing, and "remote_bash" for remote server tasks.',
      uiAutomationBridge: 'Structured "ui" tool (uitest/uinput + JSON layout parser) and ArkWeb CDP on 127.0.0.1:9222'
    };
    return info;
  }

  /**
   * Formats the environment snapshot into a crisp, high-density observation block for the system prompt.
   */
  static formatForPrompt(): string {
    const info = EnvironmentSnapshot.getSnapshot();
    return `[Current Runtime Environment]
- Host Platform: ${info.platform} (${info.architecture})
- Execution Privilege: ${info.privilege}
- Persistent App Workspace: ${info.workspaceDir} (relative paths in read/write/edit resolve here via native ArkTS @ohos.file.fs)
- System Tmp Directory: ${info.systemTmpDir} (for shell commands, bm, uitest dumps, and hidumper)
- Physical Screen Resolution: ${info.screenWidth}x${info.screenHeight}
- Current Local Time: ${info.timestampStr}
- Network Environment: ${info.networkConstraint}
- UI & Web Automation: ${info.uiAutomationBridge}`;
  }
}
