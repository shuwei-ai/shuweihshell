/*
 * Pi Goal Tool: Enables the Agent to autonomously plan, track, update,
 * and complete multi-step goals. Modeled after @earendil-works/pi-goal-x.
 */
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { GoalManager } from '../goal/GoalManager';
import { GoalTaskStatus } from '../goal/types';

export class GoalTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'action': new ToolProperty(
        'string',
        'Action to perform on the active goal: "plan" (decompose into subtasks), "update_task" (update subtask status), "complete" (mark entire goal achieved), or "status" (view goal progress).'
      ),
      'taskId': new ToolProperty(
        'string',
        'Required for action="update_task". The ID of the task to update (e.g. "task_1", "task_2").'
      ),
      'taskStatus': new ToolProperty(
        'string',
        'Required for action="update_task". Status: "in_progress", "completed", or "failed".'
      ),
      'result': new ToolProperty(
        'string',
        'Optional result summary for the task or completion details.'
      ),
      'tasks': new ToolProperty(
        'array',
        'Required for action="plan". List of subtask description strings.',
        { 'type': 'string' }
      ),
      'acceptanceCriteria': new ToolProperty(
        'array',
        'Optional for action="plan". List of acceptance criteria.',
        { 'type': 'string' }
      ),
      'summary': new ToolProperty(
        'string',
        'Required for action="complete". Final delivery summary proving all criteria are satisfied.'
      )
    };

    const params = new ToolParameters(props, ['action']);
    const func = new ToolFunctionDefinition(
      'goal',
      'Manage and track long-running autonomous goals. Allows decomposing objectives into tasks (action="plan"), updating subtask status (action="update_task"), auditing and finalizing (action="complete"), and viewing progress (action="status").',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const action = (args['action'] as string) ?? 'status';
    const goalMgr = GoalManager.getInstance();
    const activeGoal = goalMgr.getActiveGoal();

    if (!activeGoal && action !== 'plan') {
      return {
        toolCallId,
        toolName: 'goal',
        output: '',
        error: 'No active goal is currently running. Use action "plan" to start a new goal, or use /goal command.',
        isError: true
      };
    }

    switch (action) {
      case 'plan': {
        const tasksRaw = args['tasks'];
        const criteriaRaw = args['acceptanceCriteria'];
        const objective = (args['objective'] as string) || (activeGoal ? activeGoal.objective : 'Autonomous Task');

        let tasksList: string[] = [];
        if (Array.isArray(tasksRaw)) {
          tasksList = tasksRaw.map((t: Object) => `${t}`);
        }

        let criteriaList: string[] = [];
        if (Array.isArray(criteriaRaw)) {
          criteriaList = criteriaRaw.map((c: Object) => `${c}`);
        }

        if (tasksList.length === 0) {
          return {
            toolCallId,
            toolName: 'goal',
            output: '',
            error: 'action "plan" requires a non-empty `tasks` array of subtask strings.',
            isError: true
          };
        }

        if (!activeGoal) {
          goalMgr.startGoal(objective, tasksList, criteriaList);
        } else {
          goalMgr.setTasks(tasksList, criteriaList);
        }

        return {
          toolCallId,
          toolName: 'goal',
          output: `Goal planned successfully with ${tasksList.length} subtasks:\n` +
            tasksList.map((t, idx) => `  ${idx + 1}. [task_${idx + 1}] ${t}`).join('\n') +
            '\n\nNow executing task_1. Proceed with the necessary tools.',
          isError: false
        };
      }

      case 'update_task': {
        const taskId = (args['taskId'] || args['task_id'] || args['id']) as string;
        const taskStatus = ((args['taskStatus'] || args['task_status'] || args['status']) as string) as GoalTaskStatus;
        const resultSummary = (args['result'] || args['summary'] || args['output']) as string | undefined;

        if (!taskId || !taskStatus) {
          return {
            toolCallId,
            toolName: 'goal',
            output: '',
            error: 'action "update_task" requires both `taskId` and `taskStatus`.',
            isError: true
          };
        }

        const ok = goalMgr.updateTaskStatus(taskId, taskStatus, resultSummary);
        if (!ok) {
          return {
            toolCallId,
            toolName: 'goal',
            output: '',
            error: `Task with ID "${taskId}" not found in current goal.`,
            isError: true
          };
        }

        const next = goalMgr.getNextPendingTask();
        const nextMsg = next
          ? `Next active task: [${next.id}] "${next.title}". Please proceed with this task.`
          : 'All tasks completed! Please audit against criteria and call goal(action="complete").';

        return {
          toolCallId,
          toolName: 'goal',
          output: `Task "${taskId}" updated to "${taskStatus}".\n${nextMsg}`,
          isError: false
        };
      }

      case 'complete': {
        const summary = (args['summary'] as string) || (args['result'] as string) || 'Goal completed successfully.';
        goalMgr.completeGoal(summary);
        return {
          toolCallId,
          toolName: 'goal',
          output: `🎉 GOAL COMPLETE: "${activeGoal?.objective ?? ''}"\nSummary: ${summary}\nAll acceptance criteria verified.`,
          isError: false
        };
      }

      case 'status':
      default: {
        if (!activeGoal) {
          return {
            toolCallId,
            toolName: 'goal',
            output: 'No active goal is currently running.',
            isError: false
          };
        }
        const completed = activeGoal.tasks.filter(t => t.status === 'completed').length;
        const total = activeGoal.tasks.length;
        const lines = [
          `Goal: "${activeGoal.objective}" [Status: ${activeGoal.status}]`,
          `Progress: ${completed}/${total} tasks completed (Autonomous Step ${activeGoal.autonomousStepCount}/${activeGoal.maxAutonomousSteps})`,
          'Tasks:'
        ];
        for (const t of activeGoal.tasks) {
          lines.push(`  - [${t.status.toUpperCase()}] ${t.id}: ${t.title}${t.result ? ` (${t.result})` : ''}`);
        }
        return {
          toolCallId,
          toolName: 'goal',
          output: lines.join('\n'),
          isError: false
        };
      }
    }
  }
}
