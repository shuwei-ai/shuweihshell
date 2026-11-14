/*
 * AttentionManager: Human-in-the-loop structured decision coordinator.
 * Implements the Attention Protocol from deepseek-ai/dsh-superagent-prototype.
 */
import hilog from '@ohos.hilog';
import { AttentionRequest } from './types';

const DOMAIN: number = 0x0001;
const TAG: string = 'AttentionManager';

interface PendingAttention {
  request: AttentionRequest;
  resolve: (answer: string) => void;
  reject: (reason: Error) => void;
  timerId?: number;
}

export type AttentionEventListener = (request: AttentionRequest | null) => void;

export class AttentionManager {
  private static instance: AttentionManager;
  private pendingRequests: Map<string, PendingAttention> = new Map();
  private listeners: AttentionEventListener[] = [];
  private activeRequest: AttentionRequest | null = null;

  static getInstance(): AttentionManager {
    if (!AttentionManager.instance) {
      AttentionManager.instance = new AttentionManager();
    }
    return AttentionManager.instance;
  }

  addListener(listener: AttentionEventListener): void {
    this.listeners.push(listener);
    if (this.activeRequest) {
      listener(this.activeRequest);
    }
  }

  removeListener(listener: AttentionEventListener): void {
    this.listeners = this.listeners.filter(l => l !== listener);
  }

  private notifyListeners(): void {
    for (const listener of this.listeners) {
      try {
        listener(this.activeRequest);
      } catch (err) {
        // ignore
      }
    }
  }

  getActiveAttention(): AttentionRequest | null {
    return this.activeRequest;
  }

  /**
   * Dispatches an attention request and waits for human resolution.
   */
  requestAttention(
    ticketId: string,
    question: string,
    options: string[],
    allowCustomInput: boolean = true,
    timeoutSeconds: number = 300,
    requestId?: string
  ): Promise<string> {
    const id = (requestId && requestId.trim().length > 0)
      ? requestId.trim()
      : `att-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
    const request: AttentionRequest = {
      id,
      ticketId,
      question,
      options: (options && options.length > 0) ? options : ['确认', '取消'],
      allowCustomInput,
      createdAt: Date.now()
    };

    hilog.info(DOMAIN, TAG, 'Attention requested: id=%{public}s, question=%{public}s', id, question);

    return new Promise<string>((resolve, reject) => {
      let timerId: number | undefined = undefined;
      if (timeoutSeconds > 0) {
        timerId = setTimeout(() => {
          hilog.warn(DOMAIN, TAG, 'Attention request timed out: %{public}s', id);
          this.respondAttention(id, request.options[0] ?? '[Timeout: default accepted]');
        }, timeoutSeconds * 1000);
      }

      const pending: PendingAttention = {
        request,
        resolve,
        reject,
        timerId
      };

      this.pendingRequests.set(id, pending);
      this.activeRequest = request;
      this.notifyListeners();
    });
  }

  /**
   * Re-registers an existing AttentionRequest restored from persistent storage on startup.
   */
  restoreAttention(request: AttentionRequest, onResolved?: (answer: string) => void): void {
    if (!request || !request.id) {
      return;
    }
    const pending: PendingAttention = {
      request,
      resolve: (answer: string) => {
        if (onResolved) {
          onResolved(answer);
        }
      },
      reject: () => {},
      timerId: undefined
    };

    this.pendingRequests.set(request.id, pending);
    if (!this.activeRequest) {
      this.activeRequest = request;
    }
    hilog.info(DOMAIN, TAG, 'Attention restored from storage: id=%{public}s', request.id);
    this.notifyListeners();
  }

  /**
   * Called by UI when user selects an option or submits custom text.
   */
  respondAttention(id: string, selectedValue: string): boolean {
    const pending = this.pendingRequests.get(id);
    if (!pending) {
      hilog.warn(DOMAIN, TAG, 'No pending attention request found for id: %{public}s', id);
      return false;
    }

    if (pending.timerId !== undefined) {
      clearTimeout(pending.timerId);
    }

    this.pendingRequests.delete(id);
    if (this.activeRequest?.id === id) {
      // Find another active request or clear
      const remaining = Array.from(this.pendingRequests.values());
      this.activeRequest = remaining.length > 0 ? remaining[0].request : null;
      this.notifyListeners();
    }

    hilog.info(DOMAIN, TAG, 'Attention resolved: id=%{public}s, value=%{public}s', id, selectedValue);
    pending.resolve(selectedValue);
    return true;
  }

  /**
   * Cancel a pending attention request (e.g., when session aborted).
   */
  cancelAttention(id: string): void {
    const pending = this.pendingRequests.get(id);
    if (!pending) {
      return;
    }

    if (pending.timerId !== undefined) {
      clearTimeout(pending.timerId);
    }

    this.pendingRequests.delete(id);
    if (this.activeRequest?.id === id) {
      this.activeRequest = null;
      this.notifyListeners();
    }

    pending.resolve('[User cancelled attention request]');
  }

  /**
   * Clear all pending requests (e.g. on session reset).
   */
  clear(): void {
    const keys = Array.from(this.pendingRequests.keys());
    for (let i = 0; i < keys.length; i++) {
      const pending = this.pendingRequests.get(keys[i]);
      if (pending) {
        if (pending.timerId !== undefined) {
          clearTimeout(pending.timerId);
        }
        pending.resolve('[Attention cleared]');
      }
    }
    this.pendingRequests.clear();
    this.activeRequest = null;
    this.notifyListeners();
  }
}
