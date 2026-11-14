/*
 * TicketEngine: Deterministic State Machine & Concurrency Orchestrator for SuperAgent.
 * Enforces star-topology dispatch, per-task cancellation, human input tracking,
 * and the anti-loop 3-wakeup hard lock barrier.
 */
import hilog from '@ohos.hilog';
import { AgentModelConfig } from '../types';
import { TicketStore } from './TicketStore';
import { AttentionManager } from './AttentionManager';
import { WorkerSession } from './WorkerSession';
import { AttentionRequest, Ticket, TicketProgress, TicketStatus, WorkerProgressEvent, WorkerReport, WorkerRole } from './types';

const DOMAIN: number = 0x0001;
const TAG: string = 'TicketEngine';
const MAX_CONSECUTIVE_AUTO_WAKEUPS = 3;

interface ActiveWorkerContext {
  ticketId: string;
  abort: () => void;
}

export type RouterWakeupCallback = (ticket: Ticket) => void;

export class TicketEngine {
  private static instance: TicketEngine = new TicketEngine();
  private consecutiveAutoWakeCount: number = 0;
  private activeWorkers: Map<string, ActiveWorkerContext> = new Map();
  private routerWakeupCallback: RouterWakeupCallback | null = null;

  private constructor() {}

  static getInstance(): TicketEngine {
    return TicketEngine.instance;
  }

  /**
   * Dispatches a worker task asynchronously. Creates the ticket in TicketStore,
   * checks the anti-loop limiter, kicks off unawaited execution, and immediately returns the Ticket.
   */
  dispatchTask(
    config: AgentModelConfig,
    role: WorkerRole,
    goal: string,
    contextInfo?: string,
    maxSteps: number = 15,
    customPrompt?: string,
    allowedTools?: string[],
    skillName?: string
  ): Ticket {
    const title = goal.length > 25 ? `${goal.substring(0, 25)}...` : goal;
    const ticket = TicketStore.getInstance().createTicket(role, title, goal, contextInfo);

    hilog.info(
      DOMAIN,
      TAG,
      'Dispatching task: ticketId=%{public}s, role=%{public}s, consecutiveAutoWakeCount=%{public}d',
      ticket.id,
      role,
      this.consecutiveAutoWakeCount
    );

    // Anti-loop hard lock: if autonomous wakeup count reached limit, freeze into WaitingHuman
    if (this.consecutiveAutoWakeCount >= MAX_CONSECUTIVE_AUTO_WAKEUPS) {
      hilog.warn(
        DOMAIN,
        TAG,
        'Anti-loop limit hit (%{public}d). Forcing WaitingHuman for ticket: %{public}s',
        this.consecutiveAutoWakeCount,
        ticket.id
      );

      const attentionReqId = `att-limit-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
      const question = `已达到连续自动任务上限 (${MAX_CONSECUTIVE_AUTO_WAKEUPS} 次)。请确认是否继续执行任务：${title}`;
      const options = ['确认继续', '取消任务'];

      const attentionReq: AttentionRequest = {
        id: attentionReqId,
        ticketId: ticket.id,
        question: question,
        options: options,
        allowCustomInput: true,
        createdAt: Date.now()
      };

      ticket.status = 'WaitingHuman';
      ticket.attention = attentionReq;
      TicketStore.getInstance().updateTicket(ticket);

      AttentionManager.getInstance().requestAttention(
        ticket.id,
        attentionReq.question,
        attentionReq.options,
        true,
        0,
        attentionReq.id
      ).then((answer: string) => {
        this.recordHumanInput();
        if (answer === '取消任务' || answer.includes('取消') || answer.includes('cancel')) {
          this.abortTicket(ticket.id);
        } else {
          TicketStore.getInstance().updateStatus(ticket.id, 'Running');
          this.executeBackgroundWorker(ticket, config, maxSteps, customPrompt, allowedTools, skillName);
        }
      }).catch((_e: Error) => {
        this.abortTicket(ticket.id);
      });

      // Synchronize ticket.attention with AttentionManager registered active request
      const active = AttentionManager.getInstance().getActiveAttention();
      if (active && active.id === attentionReq.id) {
        ticket.attention = active;
      }

      return ticket;
    }

    // Launch unawaited background worker Promise
    this.executeBackgroundWorker(ticket, config, maxSteps, customPrompt, allowedTools, skillName);
    return ticket;
  }

  private executeBackgroundWorker(
    ticket: Ticket,
    config: AgentModelConfig,
    maxSteps: number,
    customPrompt?: string,
    allowedTools?: string[],
    skillName?: string
  ): void {
    ticket.status = 'Running';
    TicketStore.getInstance().updateStatus(ticket.id, 'Running');

    let isAborted = false;
    const abortHandler = () => {
      isAborted = true;
    };

    this.activeWorkers.set(ticket.id, {
      ticketId: ticket.id,
      abort: abortHandler
    });

    const onProgress = (prog: WorkerProgressEvent) => {
      if (isAborted) {
        return;
      }
      TicketStore.getInstance().updateProgress(
        ticket.id,
        prog.currentStep,
        prog.maxSteps,
        prog.actionText
      );
    };

    // Unawaited background promise
    WorkerSession.runTask(
      config,
      ticket.role,
      ticket.goal,
      ticket.contextInfo,
      maxSteps,
      onProgress,
      customPrompt,
      allowedTools,
      skillName,
      ticket.id
    ).then((report: WorkerReport) => {
      this.activeWorkers.delete(ticket.id);

      if (isAborted) {
        TicketStore.getInstance().updateStatus(ticket.id, 'Failed', 'Task aborted by user');
        return;
      }

      // WorkerSession already updates TicketStore and calls onWorkerCompleted.
      // Safety fallback: only if WorkerSession did NOT set a terminal state, finalize here.
      const current = TicketStore.getInstance().getTicket(ticket.id);
      if (current && current.status !== 'Completed' && current.status !== 'Failed' && current.status !== 'WaitingHuman') {
        if (report.status === 'ready') {
          current.artifacts = report.artifacts;
          TicketStore.getInstance().updateTicket(current);
          TicketStore.getInstance().updateStatus(ticket.id, 'Completed', report.summary);
        } else if (report.status === 'failed') {
          TicketStore.getInstance().updateStatus(ticket.id, 'Failed', report.summary);
        } else if (report.status === 'blocked' || report.status === 'attention') {
          current.status = 'WaitingHuman';
          current.attention = report.attention;
          TicketStore.getInstance().updateTicket(current);
        }
        const finalTicket = TicketStore.getInstance().getTicket(ticket.id) || ticket;
        this.onWorkerCompleted(finalTicket);
      }
    }).catch((err: Error) => {
      this.activeWorkers.delete(ticket.id);
      if (!isAborted) {
        TicketStore.getInstance().updateStatus(ticket.id, 'Failed', `${err}`);
        const finalTicket = TicketStore.getInstance().getTicket(ticket.id) || ticket;
        this.onWorkerCompleted(finalTicket);
      }
    });
  }

  updateTicketStatus(ticketId: string, status: TicketStatus, resultOrError?: string): void {
    TicketStore.getInstance().updateStatus(ticketId, status, resultOrError);
  }

  updateTicketProgress(ticketId: string, step: number, maxSteps: number, actionText: string): void {
    TicketStore.getInstance().updateProgress(ticketId, step, maxSteps, actionText);
  }

  abortTicket(ticketId: string): void {
    const active = this.activeWorkers.get(ticketId);
    if (active) {
      active.abort();
      this.activeWorkers.delete(ticketId);
    }
    const ticket = TicketStore.getInstance().getTicket(ticketId);
    if (ticket && ticket.attention) {
      AttentionManager.getInstance().cancelAttention(ticket.attention.id);
    }
    TicketStore.getInstance().updateStatus(ticketId, 'Failed', 'Task aborted by user');
    hilog.info(DOMAIN, TAG, 'Aborted ticket: %{public}s', ticketId);
  }

  abortAll(): void {
    const keys = Array.from(this.activeWorkers.keys());
    for (const key of keys) {
      const active = this.activeWorkers.get(key);
      if (active) {
        active.abort();
      }
    }
    this.activeWorkers.clear();
    WorkerSession.abortAll();

    const activeTickets = TicketStore.getInstance().getActiveTickets();
    for (const t of activeTickets) {
      TicketStore.getInstance().updateStatus(t.id, 'Failed', 'All tasks aborted');
    }
    hilog.info(DOMAIN, TAG, 'All active tasks aborted');
  }

  /**
   * Triggers the registered Router wakeup callback with the specified ticket.
   */
  triggerRouterWakeup(ticket: Ticket): void {
    if (!this.routerWakeupCallback) {
      hilog.info(DOMAIN, TAG, 'No router wakeup callback registered for ticket %{public}s', ticket.id);
      return;
    }
    try {
      hilog.info(DOMAIN, TAG, 'Triggering router wakeup for ticket: %{public}s, status=%{public}s', ticket.id, ticket.status);
      this.routerWakeupCallback(ticket);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Router wakeup callback threw error: %{public}s', `${err}`);
    }
  }

  onWorkerCompleted(ticket: Ticket): void {
    this.consecutiveAutoWakeCount++;
    hilog.info(
      DOMAIN,
      TAG,
      'Worker finished ticket %{public}s. Incremented consecutiveAutoWakeCount=%{public}d',
      ticket.id,
      this.consecutiveAutoWakeCount
    );

    this.triggerRouterWakeup(ticket);
  }

  /**
   * Resets the anti-loop auto-wakeup counter to 0 immediately when a human speaks or interacts.
   */
  recordHumanInput(): void {
    const prev = this.consecutiveAutoWakeCount;
    this.consecutiveAutoWakeCount = 0;
    if (prev > 0) {
      hilog.info(DOMAIN, TAG, 'Human input recorded: consecutiveAutoWakeCount reset from %{public}d to 0', prev);
    }
  }

  getAutoWakeupCount(): number {
    return this.consecutiveAutoWakeCount;
  }

  getConsecutiveAutoWakeCount(): number {
    return this.consecutiveAutoWakeCount;
  }

  setRouterWakeupCallback(cb: RouterWakeupCallback | null): void {
    this.routerWakeupCallback = cb;
  }
}
