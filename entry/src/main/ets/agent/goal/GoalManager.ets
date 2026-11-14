/*
 * GoalManager: Core state machine and persistent manager for autonomous Pi Goals.
 * Modeled after @earendil-works/pi-goal-x.
 * Manages goal decomposition, active task tracking, idle boundary auto-continuation,
 * and completion auditing.
 */
import hilog from '@ohos.hilog';
import buffer from '@ohos.buffer';
import { BridgeController } from '../../common/BridgeController';
import { Goal, GoalPlanInput, GoalStatus, GoalTask, GoalTaskStatus } from './types';
import { AgentWorkspace } from '../tools/AgentWorkspace';

const DOMAIN: number = 0x0001;
const TAG: string = 'GoalManager';
const GOAL_SANDBOX_PATH: string = 'goals/active_goal.json';
const GOAL_PERSIST_PATH: string = '/data/local/tmp/goals/active_goal.json';

function escapeXml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export class GoalManager {
  private static instance: GoalManager = new GoalManager();

  private activeGoal: Goal | null = null;
  private isLoaded: boolean = false;

  static getInstance(): GoalManager {
    return GoalManager.instance;
  }

  /**
   * Initializes and restores any persisted active goal from local storage.
   */
  async init(): Promise<void> {
    if (this.isLoaded) {
      return;
    }

    const ws = AgentWorkspace.getInstance();
    // 1. Prioritize durable app sandbox workspace
    if (ws.fileExists(GOAL_SANDBOX_PATH)) {
      try {
        const text = ws.readFile(GOAL_SANDBOX_PATH);
        if (text && text.trim().length > 0) {
          const parsed = JSON.parse(text) as Goal;
          if (parsed && parsed.id && parsed.objective) {
            this.activeGoal = parsed;
            this.isLoaded = true;
            hilog.info(DOMAIN, TAG, 'Loaded active goal from app sandbox: %{public}s', parsed.id);
            return;
          }
        }
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to parse sandbox goal: %{public}s', `${err}`);
      }
    }

    // 2. Fall back to legacy shell path
    try {
      const res = await BridgeController.getInstance().exec(`cat '${GOAL_PERSIST_PATH}' 2>/dev/null`);
      if (res && res.output && res.output.trim().length > 0) {
        const parsed = JSON.parse(res.output) as Goal;
        if (parsed && parsed.id && parsed.objective) {
          this.activeGoal = parsed;
          await this.persist();
        }
      }
    } catch (err) {
      // ignore
    }
    this.isLoaded = true;
  }

  /**
   * Starts or initializes a new Goal.
   */
  startGoal(
    objective: string,
    tasks: string[] = [],
    acceptanceCriteria: string[] = [],
    maxAutonomousSteps: number = 30
  ): Goal {
    const now = Date.now();
    const goalId = `goal_${now}`;

    // If initial tasks are provided, convert them to GoalTask objects
    const initialTasks: GoalTask[] = tasks.map((t, idx) => {
      const task: GoalTask = {
        id: `task_${idx + 1}`,
        title: t.trim(),
        status: idx === 0 ? 'in_progress' : 'pending',
        startedAt: idx === 0 ? now : undefined
      };
      return task;
    });

    // Default acceptance criteria if none provided
    const criteria = acceptanceCriteria.length > 0 ? acceptanceCriteria : [
      '所有规划的子任务均已执行并验证完毕',
      '输出明确的执行结果分析或交付报告'
    ];

    const newGoal: Goal = {
      id: goalId,
      objective: objective.trim(),
      status: initialTasks.length > 0 ? 'active' : 'planning',
      tasks: initialTasks,
      acceptanceCriteria: criteria,
      currentStepIndex: 0,
      maxAutonomousSteps: Math.max(10, maxAutonomousSteps),
      autonomousStepCount: 0,
      createdAt: now,
      updatedAt: now
    };

    this.activeGoal = newGoal;
    this.persist();
    hilog.info(DOMAIN, TAG, 'Started new goal: %{public}s with %{public}d tasks', newGoal.id, newGoal.tasks.length);
    return newGoal;
  }

  getActiveGoal(): Goal | null {
    return this.activeGoal;
  }

  hasActiveGoal(): boolean {
    return this.activeGoal !== null && (this.activeGoal.status === 'active' || this.activeGoal.status === 'planning');
  }

  /**
   * Updates tasks list for the active goal (used during conversational planning).
   */
  setTasks(taskTitles: string[], criteria?: string[]): boolean {
    if (!this.activeGoal) {
      return false;
    }
    const now = Date.now();
    this.activeGoal.tasks = taskTitles.map((t, idx) => {
      const task: GoalTask = {
        id: `task_${idx + 1}`,
        title: t.trim(),
        status: idx === 0 ? 'in_progress' : 'pending',
        startedAt: idx === 0 ? now : undefined
      };
      return task;
    });
    if (criteria && criteria.length > 0) {
      this.activeGoal.acceptanceCriteria = criteria;
    }
    this.activeGoal.status = 'active';
    this.activeGoal.updatedAt = now;
    this.persist();
    return true;
  }

  /**
   * Updates the status of a specific task.
   */
  updateTaskStatus(taskId: string, status: GoalTaskStatus, result?: string): boolean {
    if (!this.activeGoal) {
      return false;
    }
    const task = this.activeGoal.tasks.find(t => t.id === taskId);
    if (!task) {
      return false;
    }

    const now = Date.now();
    task.status = status;
    if (result) {
      task.result = result;
    }
    if (status === 'in_progress' && !task.startedAt) {
      task.startedAt = now;
    } else if (status === 'completed' || status === 'failed') {
      task.completedAt = now;
    }

    // Auto-advance next pending task to in_progress if current was completed
    if (status === 'completed') {
      const nextPending = this.activeGoal.tasks.find(t => t.status === 'pending');
      if (nextPending) {
        nextPending.status = 'in_progress';
        nextPending.startedAt = now;
      }
    }

    this.activeGoal.updatedAt = now;

    // Check if all tasks completed
    if (this.areAllTasksCompleted()) {
      this.activeGoal.status = 'auditing';
    }

    this.persist();
    return true;
  }

  /**
   * Completes the entire goal with a final summary.
   */
  completeGoal(summary: string): boolean {
    if (!this.activeGoal) {
      return false;
    }
    const now = Date.now();
    this.activeGoal.status = 'completed';
    this.activeGoal.completionSummary = summary;
    this.activeGoal.updatedAt = now;
    // Mark all remaining tasks completed
    for (const t of this.activeGoal.tasks) {
      if (t.status !== 'completed') {
        t.status = 'completed';
        t.completedAt = now;
      }
    }
    this.persist();
    hilog.info(DOMAIN, TAG, 'Goal %{public}s marked COMPLETED', this.activeGoal.id);
    return true;
  }

  failGoal(reason: string): boolean {
    if (!this.activeGoal) {
      return false;
    }
    this.activeGoal.status = 'failed';
    this.activeGoal.completionSummary = `Goal failed: ${reason}`;
    this.activeGoal.updatedAt = Date.now();
    this.persist();
    return true;
  }

  pauseGoal(): void {
    if (this.activeGoal && this.activeGoal.status === 'active') {
      this.activeGoal.status = 'paused';
      this.activeGoal.updatedAt = Date.now();
      this.persist();
    }
  }

  resumeGoal(): void {
    if (this.activeGoal && this.activeGoal.status === 'paused') {
      this.activeGoal.status = 'active';
      this.activeGoal.updatedAt = Date.now();
      this.persist();
    }
  }

  clearGoal(): void {
    this.activeGoal = null;
    BridgeController.getInstance().exec(`rm -f '${GOAL_PERSIST_PATH}'`).catch(() => {});
  }

  areAllTasksCompleted(): boolean {
    if (!this.activeGoal || this.activeGoal.tasks.length === 0) {
      return false;
    }
    return this.activeGoal.tasks.every(t => t.status === 'completed');
  }

  getNextPendingTask(): GoalTask | null {
    if (!this.activeGoal) {
      return null;
    }
    return this.activeGoal.tasks.find(t => t.status === 'in_progress') ||
      this.activeGoal.tasks.find(t => t.status === 'pending') ||
      null;
  }

  incrementStep(): number {
    if (!this.activeGoal) {
      return 0;
    }
    this.activeGoal.autonomousStepCount++;
    this.activeGoal.updatedAt = Date.now();
    return this.activeGoal.autonomousStepCount;
  }

  /**
   * Formats the active goal status into an XML block for injection into the System Prompt.
   */
  formatGoalForPrompt(): string {
    const goal = this.activeGoal;
    if (!goal || goal.status === 'completed' || goal.status === 'failed') {
      return '';
    }

    const lines: string[] = [
      '<active_goal>',
      `  <id>${escapeXml(goal.id)}</id>`,
      `  <status>${goal.status}</status>`,
      `  <objective>${escapeXml(goal.objective)}</objective>`,
      `  <autonomous_steps>${goal.autonomousStepCount} / ${goal.maxAutonomousSteps}</autonomous_steps>`,
      '  <tasks>'
    ];

    for (const t of goal.tasks) {
      let taskLine = `    <task id="${escapeXml(t.id)}" status="${t.status}">${escapeXml(t.title)}`;
      if (t.result) {
        taskLine += ` [Result: ${escapeXml(t.result)}]`;
      }
      taskLine += '</task>';
      lines.push(taskLine);
    }
    lines.push('  </tasks>');

    if (goal.acceptanceCriteria.length > 0) {
      lines.push('  <acceptance_criteria>');
      for (const c of goal.acceptanceCriteria) {
        lines.push(`    <criterion>${escapeXml(c)}</criterion>`);
      }
      lines.push('  </acceptance_criteria>');
    }

    lines.push('  <instructions>');
    lines.push('    1. Execute one task at a time using appropriate tools (bash, read, write, edit, browser, fetch).');
    lines.push('    2. When a subtask finishes, call the `goal` tool with action "update_task" to record progress.');
    lines.push('    3. When ALL tasks and criteria are fully satisfied, call the `goal` tool with action "complete".');
    lines.push('    4. NEVER stop or say "I am done" before calling `goal` action "complete".');
    lines.push('  </instructions>');
    lines.push('</active_goal>');

    return lines.join('\n');
  }

  /**
   * Generates the autonomous continuation prompt when the model stops at an idle boundary
   * without having completed the active goal.
   */
  formatContinuationPrompt(): string | null {
    const goal = this.activeGoal;
    if (!goal || goal.status === 'completed' || goal.status === 'failed' || goal.status === 'paused') {
      return null;
    }

    const completedCount = goal.tasks.filter(t => t.status === 'completed').length;
    const totalCount = goal.tasks.length;
    const nextTask = this.getNextPendingTask();

    if (!nextTask && goal.status === 'auditing') {
      return `[Goal Supervisor] All ${totalCount} subtasks have been executed. Please audit the results against the acceptance criteria, then call the \`goal\` tool with action "complete" to finalize the goal and output your final delivery report.`;
    }

    if (!nextTask && totalCount === 0) {
      return `[Goal Supervisor] Goal objective "${goal.objective}" has no decomposed tasks yet. Please call the \`goal\` tool with action "plan" to decompose the objective into concrete tasks, or execute the first step immediately.`;
    }

    if (nextTask) {
      return `[Goal Supervisor] Autonomous Continuation: The active goal is NOT yet complete (${completedCount}/${totalCount} tasks finished).
Current active task: [${nextTask.id}] "${nextTask.title}".
Please execute this step now using tools (bash, read, write, edit, etc.). When this subtask is finished, call the \`goal\` tool with action="update_task", taskId="${nextTask.id}", taskStatus="completed", and result="<summary>" to mark it complete and advance to the next task. Do NOT stop prematurely.`;
    }

    return null;
  }

  private async persist(): Promise<void> {
    if (!this.activeGoal) {
      return;
    }
    try {
      const json = JSON.stringify(this.activeGoal, null, 2);
      AgentWorkspace.getInstance().writeFile(GOAL_SANDBOX_PATH, json);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to persist goal: %{public}s', `${err}`);
    }
  }
}
