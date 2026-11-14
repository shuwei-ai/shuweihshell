/*
 * Types and definitions for the Pi Goal management engine.
 * Modeled after @earendil-works/pi-goal-x.
 * Supports persistent autonomous goal tracking, subtask decomposition, and verification.
 */

export type GoalTaskStatus = 'pending' | 'in_progress' | 'completed' | 'failed';

export type GoalStatus = 'planning' | 'active' | 'auditing' | 'completed' | 'failed' | 'paused';

export interface GoalTask {
  id: string;
  title: string;
  status: GoalTaskStatus;
  result?: string;
  startedAt?: number;
  completedAt?: number;
}

export interface Goal {
  id: string;
  objective: string;
  status: GoalStatus;
  tasks: GoalTask[];
  acceptanceCriteria: string[];
  currentStepIndex: number;
  maxAutonomousSteps: number;
  autonomousStepCount: number;
  createdAt: number;
  updatedAt: number;
  completionSummary?: string;
}

export interface GoalPlanInput {
  objective: string;
  tasks?: string[];
  acceptanceCriteria?: string[];
  maxSteps?: number;
}
