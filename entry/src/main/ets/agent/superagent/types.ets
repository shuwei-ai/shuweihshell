/*
 * Domain Types for SuperAgent (Router-Worker Architecture) on HarmonyOS NEXT.
 * Inspired by deepseek-ai/dsh-superagent-prototype.
 */

import { ImageAttachment, Message } from '../types';

export type WorkerRole =
  | 'ui_worker'       // UI automation: uitest, uinput, screenshot, app navigation
  | 'diag_worker'     // System diagnostics: hilog, hidumper, sys params, fault logs
  | 'code_worker'     // Workspace scripting: read, write, edit, local test execution
  | 'web_worker'      // Web retrieval: browser CDP, fetch HTTP APIs
  | 'general_worker'  // General purpose: all tools
  | string;           // Custom dynamic sub-agent role

export type WorkerStatus =
  | 'pending'
  | 'running'
  | 'ready'          // Successfully completed with deliverable result
  | 'blocked'        // Hit obstacle, cannot proceed without input
  | 'failed'         // Unrecoverable execution error
  | 'attention';     // Needs structured human decision

// --- Canonical Ticket State Machine Types (PROJECT.md R2) ---

export type TicketStatus = 'Pending' | 'Running' | 'WaitingHuman' | 'Completed' | 'Failed';

export interface TicketProgress {
  currentStep: number;
  maxSteps: number;
  actionText: string;
}

export interface TicketStepLog {
  step: number;
  tool: string;
  args?: string;
  output?: string;
  error?: string;
  timestamp: number;
}

export interface TicketTimestamps {
  createdAt: number;
  startedAt?: number;
  completedAt?: number;
}

export interface AttentionRequest {
  id: string;
  ticketId: string;
  question: string;
  options: string[];
  allowCustomInput: boolean;
  createdAt: number;
}

export interface Ticket {
  id: string;
  title: string;
  role: WorkerRole;
  goal: string;
  status: TicketStatus;
  contextInfo?: string;
  result?: string;
  error?: string;
  artifacts?: string[];
  timestamps: TicketTimestamps;
  progress?: TicketProgress;
  attention?: AttentionRequest;
  stepLogs?: TicketStepLog[];
  historyMessages?: Message[];
}

export interface WorkerReport {
  ticketId: string;
  role: WorkerRole;
  status: WorkerStatus;
  summary: string;
  artifacts?: string[];
  images?: ImageAttachment[];
  attention?: AttentionRequest;
  durationMs: number;
  stepsCount: number;
}

export interface WorkerProgressEvent {
  ticketId: string;
  role: WorkerRole;
  currentStep: number;
  maxSteps: number;
  actionText: string;
}
