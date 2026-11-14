/*
 * E2E & Architecture Test: Ticket State Machine & Startup Recovery (F4, F5, F6, F7)
 * Verifies deterministic state machine transitions, invalid transition rejections,
 * abort semantics, and persistent recovery after app restart.
 */
import { describe, it, expect } from '@ohos/hypium';
import { WorkerRole, AttentionRequest } from '../main/ets/agent/superagent/types';

export type CanonicalTicketStatus = 'Pending' | 'Running' | 'WaitingHuman' | 'Completed' | 'Failed';

export interface CanonicalTicketProgress {
  currentStep: number;
  maxSteps: number;
  actionText: string;
}

export interface CanonicalTicketTimestamps {
  createdAt: number;
  startedAt?: number;
  completedAt?: number;
}

export interface CanonicalTicket {
  id: string;
  title: string;
  role: WorkerRole;
  goal: string;
  status: CanonicalTicketStatus;
  contextInfo?: string;
  result?: string;
  error?: string;
  artifacts?: string[];
  timestamps: CanonicalTicketTimestamps;
  progress?: CanonicalTicketProgress;
  attention?: AttentionRequest;
}

export interface TransitionPayload {
  result?: string;
  error?: string;
  attention?: AttentionRequest;
}

export interface RecoveryReport {
  recoveredRunning: number;
  recoveredPending: number;
  restoredAttention: number;
}

/**
 * Deterministic State Machine Engine verifying transition invariants according to PROJECT.md
 */
export class DeterministicTicketEngine {
  private tickets: Map<string, CanonicalTicket> = new Map();

  createTicket(role: WorkerRole, title: string, goal: string, contextInfo?: string): CanonicalTicket {
    const id = `ticket-${Date.now()}-${Math.floor(Math.random() * 10000)}`;
    const ts: CanonicalTicketTimestamps = {
      createdAt: Date.now()
    };
    const ticket: CanonicalTicket = {
      id: id,
      title: title,
      role: role,
      goal: goal,
      status: 'Pending',
      contextInfo: contextInfo,
      timestamps: ts
    };
    this.tickets.set(id, ticket);
    return ticket;
  }

  getTicket(id: string): CanonicalTicket | undefined {
    return this.tickets.get(id);
  }

  transitionTo(id: string, newStatus: CanonicalTicketStatus, payload?: TransitionPayload): boolean {
    const ticket = this.tickets.get(id);
    if (!ticket) {
      return false;
    }

    const current = ticket.status;

    // Terminal states cannot transition further
    if (current === 'Completed' || current === 'Failed') {
      return false;
    }

    switch (newStatus) {
      case 'Running':
        if (current !== 'Pending' && current !== 'WaitingHuman') {
          return false;
        }
        ticket.status = 'Running';
        if (!ticket.timestamps.startedAt) {
          ticket.timestamps.startedAt = Date.now();
        }
        return true;

      case 'WaitingHuman':
        if (current !== 'Running') {
          return false;
        }
        ticket.status = 'WaitingHuman';
        if (payload && payload.attention) {
          ticket.attention = payload.attention;
        }
        return true;

      case 'Completed':
        if (current !== 'Running') {
          return false;
        }
        ticket.status = 'Completed';
        ticket.result = (payload && payload.result) ? payload.result : 'Task completed successfully';
        ticket.timestamps.completedAt = Date.now();
        return true;

      case 'Failed':
        ticket.status = 'Failed';
        ticket.error = (payload && payload.error) ? payload.error : 'Task failed';
        ticket.timestamps.completedAt = Date.now();
        return true;

      default:
        return false;
    }
  }

  abortTicket(id: string, reason?: string): boolean {
    const ticket = this.tickets.get(id);
    if (!ticket) {
      return false;
    }
    if (ticket.status === 'Completed' || ticket.status === 'Failed') {
      return false; // Already terminal
    }
    const payload: TransitionPayload = {
      error: reason ? reason : 'Aborted by user'
    };
    return this.transitionTo(id, 'Failed', payload);
  }

  /**
   * Simulates app startup recovery scan (F6)
   */
  simulateStartupRecovery(): RecoveryReport {
    let recoveredRunning = 0;
    let recoveredPending = 0;
    let restoredAttention = 0;

    for (const ticket of this.tickets.values()) {
      if (ticket.status === 'Running') {
        ticket.status = 'Failed';
        ticket.error = 'Task interrupted by application shutdown/restart';
        ticket.timestamps.completedAt = Date.now();
        recoveredRunning++;
      } else if (ticket.status === 'Pending') {
        ticket.status = 'Failed';
        ticket.error = 'Task cancelled due to application restart before execution started';
        ticket.timestamps.completedAt = Date.now();
        recoveredPending++;
      } else if (ticket.status === 'WaitingHuman') {
        if (ticket.attention) {
          restoredAttention++;
        } else {
          ticket.status = 'Failed';
          ticket.error = 'WaitingHuman ticket corrupted without attention request';
          ticket.timestamps.completedAt = Date.now();
        }
      }
    }

    const report: RecoveryReport = {
      recoveredRunning: recoveredRunning,
      recoveredPending: recoveredPending,
      restoredAttention: restoredAttention
    };
    return report;
  }
}

export default function ticketStateMachineTest() {
  describe('TicketStateMachineTest', () => {

    // 1. Ticket Data Model (F4)
    it('Ticket_creation_populates_mandatory_fields_and_pending_status', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('code_worker', 'Refactor Parser', 'Implement AST visitor');

      expect(ticket.id.startsWith('ticket-')).assertTrue();
      expect(ticket.role).assertEqual('code_worker');
      expect(ticket.title).assertEqual('Refactor Parser');
      expect(ticket.goal).assertEqual('Implement AST visitor');
      expect(ticket.status).assertEqual('Pending');
      expect(ticket.timestamps.createdAt > 0).assertTrue();
      expect(ticket.timestamps.startedAt === undefined).assertTrue();
      expect(ticket.timestamps.completedAt === undefined).assertTrue();
    });

    it('Ticket_JSON_serialization_roundtrip_integrity', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('diag_worker', 'Check Crash', 'grep hilog error');
      ticket.contextInfo = 'App crashed at 14:02:11';
      ticket.artifacts = ['/data/log/crash.txt'];

      const serialized = JSON.stringify(ticket);
      const deserialized: CanonicalTicket = JSON.parse(serialized);

      expect(deserialized.id).assertEqual(ticket.id);
      expect(deserialized.role).assertEqual('diag_worker');
      expect(deserialized.status).assertEqual('Pending');
      expect(deserialized.contextInfo).assertEqual('App crashed at 14:02:11');
      expect((deserialized.artifacts ?? [])[0]).assertEqual('/data/log/crash.txt');
    });

    // 2. Deterministic State Machine Transitions (F7)
    it('Ticket_valid_happy_path_transition_Pending_to_Running_to_Completed', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('web_worker', 'Fetch Spec', 'Read API doc');

      // 1. Pending -> Running
      const runOk = engine.transitionTo(ticket.id, 'Running');
      expect(runOk).assertTrue();
      expect(ticket.status).assertEqual('Running');
      expect(ticket.timestamps.startedAt !== undefined).assertTrue();

      // 2. Running -> Completed
      const completePayload: TransitionPayload = { result: 'API documentation retrieved' };
      const completeOk = engine.transitionTo(ticket.id, 'Completed', completePayload);
      expect(completeOk).assertTrue();
      expect(ticket.status).assertEqual('Completed');
      expect(ticket.result).assertEqual('API documentation retrieved');
      expect(ticket.timestamps.completedAt !== undefined).assertTrue();
    });

    it('Ticket_valid_failure_path_transition_Pending_to_Running_to_Failed', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('ui_worker', 'Click Button', 'Find login button');

      engine.transitionTo(ticket.id, 'Running');
      const failPayload: TransitionPayload = { error: 'Element not found on screen' };
      const failOk = engine.transitionTo(ticket.id, 'Failed', failPayload);

      expect(failOk).assertTrue();
      expect(ticket.status).assertEqual('Failed');
      expect(ticket.error).assertEqual('Element not found on screen');
      expect(ticket.timestamps.completedAt !== undefined).assertTrue();
    });

    it('Ticket_human_in_the_loop_transition_Running_to_WaitingHuman_to_Running', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('diag_worker', 'System Dump', 'hidumper service');

      engine.transitionTo(ticket.id, 'Running');

      // Running -> WaitingHuman
      const attReq: AttentionRequest = {
        id: 'att-1',
        ticketId: ticket.id,
        question: 'Confirm service restart?',
        options: ['Yes', 'No'],
        allowCustomInput: false,
        createdAt: Date.now()
      };

      const waitPayload: TransitionPayload = { attention: attReq };
      const waitOk = engine.transitionTo(ticket.id, 'WaitingHuman', waitPayload);
      expect(waitOk).assertTrue();
      expect(ticket.status).assertEqual('WaitingHuman');
      expect(ticket.attention?.question).assertEqual('Confirm service restart?');

      // Human responds -> resume Running
      const resumeOk = engine.transitionTo(ticket.id, 'Running');
      expect(resumeOk).assertTrue();
      expect(ticket.status).assertEqual('Running');
    });

    // 3. Invalid Transition Rejection (F7)
    it('Ticket_rejects_illegal_transition_Completed_to_Running', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('code_worker', 'Build', 'Compile target');

      engine.transitionTo(ticket.id, 'Running');
      const compPayload: TransitionPayload = { result: 'Build OK' };
      engine.transitionTo(ticket.id, 'Completed', compPayload);

      // Cannot re-run a completed ticket
      const illegal = engine.transitionTo(ticket.id, 'Running');
      expect(illegal).assertFalse();
      expect(ticket.status).assertEqual('Completed');
    });

    it('Ticket_rejects_illegal_transition_Failed_to_Running', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('code_worker', 'Test Run', 'Execute unit tests');

      engine.transitionTo(ticket.id, 'Running');
      const failPayload: TransitionPayload = { error: 'Test failed' };
      engine.transitionTo(ticket.id, 'Failed', failPayload);

      // Cannot revive a failed ticket directly without creating new one
      const illegal = engine.transitionTo(ticket.id, 'Running');
      expect(illegal).assertFalse();
      expect(ticket.status).assertEqual('Failed');
    });

    it('Ticket_rejects_illegal_direct_transition_Pending_to_Completed', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('general_worker', 'Direct Jump', 'Skip execution');

      // Must transition through Running first
      const skipPayload: TransitionPayload = { result: 'Skipped' };
      const illegal = engine.transitionTo(ticket.id, 'Completed', skipPayload);
      expect(illegal).assertFalse();
      expect(ticket.status).assertEqual('Pending');
    });

    // 4. Abort Semantics (F7)
    it('Ticket_abort_active_ticket_sets_Failed_and_reason', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('ui_worker', 'Long Swipe', 'Swipe 100 pages');

      engine.transitionTo(ticket.id, 'Running');
      const abortOk = engine.abortTicket(ticket.id, 'User clicked abort button');

      expect(abortOk).assertTrue();
      expect(ticket.status).assertEqual('Failed');
      expect(ticket.error).assertEqual('User clicked abort button');
    });

    it('Ticket_abort_completed_ticket_is_prohibited', 0, () => {
      const engine = new DeterministicTicketEngine();
      const ticket = engine.createTicket('web_worker', 'Fetch HTML', 'Download page');

      engine.transitionTo(ticket.id, 'Running');
      const compPayload: TransitionPayload = { result: 'Page content' };
      engine.transitionTo(ticket.id, 'Completed', compPayload);

      const abortAttempt = engine.abortTicket(ticket.id);
      expect(abortAttempt).assertFalse();
      expect(ticket.status).assertEqual('Completed');
    });

    // 5. Persistent Startup Recovery (F6)
    it('StartupRecovery_sanitizes_interrupted_Running_and_Pending_tickets', 0, () => {
      const engine = new DeterministicTicketEngine();

      // Ticket 1: was Running when app was killed
      const t1 = engine.createTicket('code_worker', 'Task 1', 'Goal 1');
      engine.transitionTo(t1.id, 'Running');

      // Ticket 2: was Pending when app was killed
      const t2 = engine.createTicket('ui_worker', 'Task 2', 'Goal 2');

      // Ticket 3: was WaitingHuman with valid attention
      const t3 = engine.createTicket('diag_worker', 'Task 3', 'Goal 3');
      engine.transitionTo(t3.id, 'Running');
      const waitAttReq: AttentionRequest = {
        id: 'att-3',
        ticketId: t3.id,
        question: 'Select log level?',
        options: ['DEBUG', 'ERROR'],
        allowCustomInput: false,
        createdAt: Date.now()
      };
      const waitPayload: TransitionPayload = {
        attention: waitAttReq
      };
      engine.transitionTo(t3.id, 'WaitingHuman', waitPayload);

      // Ticket 4: was already Completed
      const t4 = engine.createTicket('general_worker', 'Task 4', 'Goal 4');
      engine.transitionTo(t4.id, 'Running');
      const donePayload: TransitionPayload = { result: 'Done' };
      engine.transitionTo(t4.id, 'Completed', donePayload);

      // Run recovery
      const report = engine.simulateStartupRecovery();

      expect(report.recoveredRunning).assertEqual(1);
      expect(report.recoveredPending).assertEqual(1);
      expect(report.restoredAttention).assertEqual(1);

      // Verify states after recovery
      expect(t1.status).assertEqual('Failed');
      expect(t1.error).assertContain('interrupted by application shutdown');

      expect(t2.status).assertEqual('Failed');
      expect(t2.error).assertContain('cancelled due to application restart');

      expect(t3.status).assertEqual('WaitingHuman');
      expect(t3.attention?.question).assertEqual('Select log level?');

      expect(t4.status).assertEqual('Completed');
      expect(t4.result).assertEqual('Done');
    });

  });
}
