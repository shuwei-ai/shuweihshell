/*
 * TicketStore: Persistent task contract repository for SuperAgent.
 * Manages in-memory cache and dual persistence via @ohos.data.preferences (swshell_ticket_store)
 * and @ohos.file.fs sandbox backup.
 * Provides startup recovery for interrupted tasks and reactive listener subscriptions for ArkUI.
 */
import common from '@ohos.app.ability.common';
import dataPreferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import buffer from '@ohos.buffer';
import hilog from '@ohos.hilog';
import { AttentionManager } from './AttentionManager';
import { Ticket, TicketProgress, TicketStatus, TicketStepLog, WorkerRole } from './types';

const DOMAIN: number = 0x0001;
const TAG: string = 'TicketStore';
const PREF_STORE_NAME = 'swshell_ticket_store';
const KEY_TICKETS = 'tickets_data';
const BACKUP_FILE_NAME = 'tickets_backup.json';

export type TicketChangeListener = (tickets: Ticket[]) => void;

export class TicketStore {
  private static instance: TicketStore = new TicketStore();
  private context: common.Context | null = null;
  private prefStore: dataPreferences.Preferences | undefined = undefined;
  private tickets: Map<string, Ticket> = new Map();
  private listeners: TicketChangeListener[] = [];
  private isInitialized: boolean = false;
  private persistDebounceTimer: number | undefined = undefined;
  private isPersisting: boolean = false;
  private hasPendingPersist: boolean = false;
  private nextPersistPromise: Promise<void> | null = null;
  private nextPersistResolve: (() => void) | null = null;
  private nextPersistReject: ((err: Error) => void) | null = null;

  private constructor() {}

  static getInstance(): TicketStore {
    return TicketStore.instance;
  }

  /**
   * Initializes the persistent store and performs startup recovery:
   * 1. Interrupted 'Running' and 'Pending' tickets -> transitioned to 'Failed' with '[Interrupted by application restart]'.
   * 2. 'WaitingHuman' tickets -> re-registered into AttentionManager.
   */
  async init(context?: common.Context): Promise<void> {
    if (this.persistDebounceTimer !== undefined) {
      clearTimeout(this.persistDebounceTimer);
      this.persistDebounceTimer = undefined;
    }

    if (context) {
      this.context = context;
      try {
        this.prefStore = await dataPreferences.getPreferences(context, { name: PREF_STORE_NAME });
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to open preferences store: %{public}s. Falling back to fs/memory.', `${err}`);
      }
    }

    let loadedTickets: Ticket[] = [];
    let loadedFromPref = false;

    // 1. Try loading from Preferences
    if (this.prefStore) {
      try {
        const raw = (await this.prefStore.get(KEY_TICKETS, '')) as string;
        if (raw && raw.trim().length > 0) {
          loadedTickets = JSON.parse(raw) as Ticket[];
          loadedFromPref = true;
          hilog.info(DOMAIN, TAG, 'Loaded %{public}d tickets from Preferences', loadedTickets.length);
        }
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'Preferences read failed: %{public}s', `${err}`);
      }
    }

    // 2. Fallback to FS backup if Preferences was empty or failed
    if (!loadedFromPref && this.context) {
      try {
        const backupPath = `${this.context.filesDir}/${BACKUP_FILE_NAME}`;
        if (fs.accessSync(backupPath)) {
          const stat = fs.statSync(backupPath);
          if (stat.size > 0) {
            const opened = fs.openSync(backupPath, fs.OpenMode.READ_ONLY);
            const buf = new ArrayBuffer(stat.size);
            const bytesRead = fs.readSync(opened.fd, buf);
            fs.closeSync(opened);
            const raw = buffer.from(buf, 0, bytesRead).toString('utf-8');
            loadedTickets = JSON.parse(raw) as Ticket[];
            hilog.info(DOMAIN, TAG, 'Loaded %{public}d tickets from FS backup', loadedTickets.length);
          }
        }
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'FS backup read failed: %{public}s', `${err}`);
      }
    }

    // 3. Preserve in-memory tickets if no tickets were loaded from persistent storage,
    //    or merge in-memory tickets that do not yet exist on disk
    if (loadedTickets.length === 0 && this.tickets.size > 0) {
      loadedTickets = Array.from(this.tickets.values());
      hilog.info(DOMAIN, TAG, 'Preserving %{public}d in-memory tickets for recovery (no disk tickets loaded)', loadedTickets.length);
    } else if (loadedTickets.length > 0 && this.tickets.size > 0) {
      const loadedIds = new Set(loadedTickets.map(t => t.id));
      for (const inMemTicket of this.tickets.values()) {
        if (inMemTicket && inMemTicket.id && !loadedIds.has(inMemTicket.id)) {
          loadedTickets.push(inMemTicket);
        }
      }
    }

    // 4. Populate memory cache & perform Startup Recovery (PROJECT.md F6)
    this.tickets.clear();
    const now = Date.now();
    let hasRecoveredChanges = false;

    for (const ticket of loadedTickets) {
      if (!ticket || !ticket.id) {
        continue;
      }

      if (!ticket.timestamps) {
        ticket.timestamps = { createdAt: now };
      }

      if (ticket.status === 'Running' || ticket.status === 'Pending') {
        ticket.status = 'Failed';
        ticket.error = '[Interrupted by application restart]';
        if (!ticket.timestamps.completedAt) {
          ticket.timestamps.completedAt = now;
        }
        hasRecoveredChanges = true;
        hilog.warn(DOMAIN, TAG, 'Recovered interrupted ticket to Failed: id=%{public}s, prevStatus=%{public}s', ticket.id, ticket.status);
      } else if (ticket.status === 'WaitingHuman') {
        if (ticket.attention) {
          AttentionManager.getInstance().restoreAttention(ticket.attention, (answer: string) => {
            this.updateStatus(ticket.id, 'Running');
            hilog.info(DOMAIN, TAG, 'Restored attention resolved for ticket %{public}s with: %{public}s', ticket.id, answer);
          });
          hilog.info(DOMAIN, TAG, 'Restored WaitingHuman attention for ticket: %{public}s', ticket.id);
        } else {
          ticket.status = 'Failed';
          ticket.error = '[Interrupted without attention request payload]';
          ticket.timestamps.completedAt = now;
          hasRecoveredChanges = true;
        }
      }

      this.tickets.set(ticket.id, ticket);
    }

    this.isInitialized = true;
    if (hasRecoveredChanges) {
      await this.persistImmediately();
    }
    this.notifyListeners();
  }

  createTicket(role: WorkerRole, title: string, goal: string, contextInfo?: string): Ticket {
    const id = `ticket-${Date.now()}-${Math.floor(Math.random() * 10000)}`;
    const effectiveTitle = title && title.trim().length > 0 ? title.trim() : (goal ? goal.substring(0, 30) : `Task [${role}]`);
    const ticket: Ticket = {
      id,
      title: effectiveTitle,
      role,
      goal,
      status: 'Pending',
      contextInfo,
      timestamps: {
        createdAt: Date.now()
      }
    };

    this.tickets.set(id, ticket);
    this.notifyListeners();
    this.schedulePersist();
    hilog.info(DOMAIN, TAG, 'Created ticket %{public}s: role=%{public}s, title=%{public}s', id, role, effectiveTitle);
    return ticket;
  }

  updateTicket(ticket: Ticket): void {
    if (!ticket || !ticket.id) {
      return;
    }
    this.tickets.set(ticket.id, ticket);
    this.notifyListeners();
    this.schedulePersist();
  }

  updateStatus(id: string, status: TicketStatus, resultOrError?: string): void {
    const ticket = this.tickets.get(id);
    if (!ticket) {
      hilog.warn(DOMAIN, TAG, 'Ticket not found for updateStatus: %{public}s', id);
      return;
    }

    ticket.status = status;
    const now = Date.now();

    if (status === 'Running') {
      if (!ticket.timestamps.startedAt) {
        ticket.timestamps.startedAt = now;
      }
    } else if (status === 'Completed') {
      ticket.timestamps.completedAt = now;
      if (resultOrError !== undefined) {
        ticket.result = resultOrError;
      }
    } else if (status === 'Failed') {
      ticket.timestamps.completedAt = now;
      if (resultOrError !== undefined) {
        ticket.error = resultOrError;
      }
    }

    this.notifyListeners();
    // Terminal state transitions persist immediately
    if (status === 'Completed' || status === 'Failed' || status === 'WaitingHuman') {
      this.persistImmediately().catch(() => {});
    } else {
      this.schedulePersist();
    }
  }

  updateProgress(id: string, step: number, maxSteps: number, actionText: string): void {
    const ticket = this.tickets.get(id);
    if (!ticket) {
      return;
    }

    if (ticket.status === 'Pending') {
      ticket.status = 'Running';
      if (!ticket.timestamps.startedAt) {
        ticket.timestamps.startedAt = Date.now();
      }
    }

    ticket.progress = {
      currentStep: step,
      maxSteps: maxSteps,
      actionText: actionText
    };

    this.notifyListeners();
    this.schedulePersist();
  }

  addStepLog(id: string, stepLog: TicketStepLog): void {
    const ticket = this.tickets.get(id);
    if (!ticket) {
      return;
    }
    if (!ticket.stepLogs) {
      ticket.stepLogs = [];
    }
    ticket.stepLogs.push(stepLog);
    if (ticket.stepLogs.length > 50) {
      ticket.stepLogs.shift();
    }
    this.notifyListeners();
  }

  updateLastStepLog(id: string, output?: string, error?: string): void {
    const ticket = this.tickets.get(id);
    if (!ticket || !ticket.stepLogs || ticket.stepLogs.length === 0) {
      return;
    }
    const last = ticket.stepLogs[ticket.stepLogs.length - 1];
    if (output !== undefined) {
      last.output = output;
    }
    if (error !== undefined) {
      last.error = error;
    }
    this.notifyListeners();
  }

  updateTicketProgress(id: string, step: number, maxSteps: number, actionText: string): void {
    this.updateProgress(id, step, maxSteps, actionText);
  }

  getTicket(id: string): Ticket | undefined {
    return this.tickets.get(id);
  }

  getActiveTickets(): Ticket[] {
    const list: Ticket[] = [];
    this.tickets.forEach((t) => {
      if (t.status === 'Pending' || t.status === 'Running' || t.status === 'WaitingHuman') {
        list.push(t);
      }
    });
    return list.sort((a, b) => b.timestamps.createdAt - a.timestamps.createdAt);
  }

  getAllTickets(): Ticket[] {
    const list = Array.from(this.tickets.values());
    return list.sort((a, b) => b.timestamps.createdAt - a.timestamps.createdAt);
  }

  deleteTicket(id: string): void {
    if (this.tickets.delete(id)) {
      this.notifyListeners();
      this.schedulePersist();
    }
  }

  clear(): void {
    if (this.persistDebounceTimer !== undefined) {
      clearTimeout(this.persistDebounceTimer);
      this.persistDebounceTimer = undefined;
    }
    this.tickets.clear();
    this.notifyListeners();
    this.schedulePersist();
  }

  addListener(listener: TicketChangeListener): void {
    this.listeners.push(listener);
    // Initial emission
    try {
      listener(this.getAllTickets());
    } catch (_e) {
      // ignore
    }
  }

  removeListener(listener: TicketChangeListener): void {
    this.listeners = this.listeners.filter(l => l !== listener);
  }

  private notifyListeners(): void {
    const all = this.getAllTickets();
    const active = this.getActiveTickets();

    try {
      AppStorage.setOrCreate('activeTickets', active);
      AppStorage.setOrCreate('activeTicketsCount', active.length);
    } catch (_e) {
      // ignore in headless test runner
    }

    for (const listener of this.listeners) {
      try {
        listener(all);
      } catch (_e) {
        // ignore listener errors
      }
    }
  }

  private schedulePersist(): void {
    if (this.persistDebounceTimer !== undefined) {
      clearTimeout(this.persistDebounceTimer);
    }
    this.persistDebounceTimer = setTimeout(() => {
      this.persistImmediately().catch(() => {});
    }, 200);
  }

  async persistImmediately(): Promise<void> {
    // 1. Cancel pending debounce timer to prevent redundant duplicate flushes
    if (this.persistDebounceTimer !== undefined) {
      clearTimeout(this.persistDebounceTimer);
      this.persistDebounceTimer = undefined;
    }

    // 2. If a persistence write is currently in progress, coalesce this request
    if (this.isPersisting) {
      this.hasPendingPersist = true;
      if (!this.nextPersistPromise) {
        this.nextPersistPromise = new Promise<void>((resolve, reject) => {
          this.nextPersistResolve = resolve;
          this.nextPersistReject = reject;
        });
      }
      return this.nextPersistPromise;
    }

    this.isPersisting = true;
    try {
      await this.executePersist();

      // Loop while there are pending persist requests that queued up during executePersist
      while (this.hasPendingPersist) {
        this.hasPendingPersist = false;
        const resolve = this.nextPersistResolve;
        const reject = this.nextPersistReject;
        this.nextPersistPromise = null;
        this.nextPersistResolve = null;
        this.nextPersistReject = null;

        try {
          await this.executePersist();
          if (resolve) {
            resolve();
          }
        } catch (err) {
          if (reject) {
            reject(err as Error);
          }
        }
      }
    } finally {
      this.isPersisting = false;
      this.hasPendingPersist = false;
      if (this.nextPersistResolve) {
        this.nextPersistResolve();
        this.nextPersistPromise = null;
        this.nextPersistResolve = null;
        this.nextPersistReject = null;
      }
    }
  }

  private async executePersist(): Promise<void> {
    let jsonStr: string;
    try {
      const ticketsArray = Array.from(this.tickets.values());
      jsonStr = JSON.stringify(ticketsArray);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to serialize tickets: %{public}s', `${err}`);
      return;
    }

    // 1. Preferences
    if (this.prefStore) {
      try {
        await this.prefStore.put(KEY_TICKETS, jsonStr);
        await this.prefStore.flush();
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'Failed to flush tickets to Preferences: %{public}s', `${err}`);
      }
    }

    // 2. FS Sandbox backup
    if (this.context) {
      try {
        const backupPath = `${this.context.filesDir}/${BACKUP_FILE_NAME}`;
        const opened = fs.openSync(
          backupPath,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
        );
        fs.writeSync(opened.fd, jsonStr);
        fs.closeSync(opened);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to save tickets backup to FS: %{public}s', `${err}`);
      }
    }
  }
}
