/*
 * ContextCompactor: Semantic Checkpoint Context Compactor for HarmonyOS Pi Harness.
 * Inspired by DeepSeek Harness (dsh-session durable history and state checkpointing).
 *
 * Prevents the "Sudden Amnesia" defect where naive message slicing wipes all intermediate
 * file contents, command results, error traces, and discoveries made by the agent.
 */
import { Message } from '../types';
import { estimateTokenCount } from '../ContextTracker';

export class ContextCompactor {
  /**
   * Determines whether semantic compaction is needed based on message count OR token budget ratio.
   */
  static shouldCompact(
    messages: Message[],
    maxTokens: number = 300000,
    thresholdRatio: number = 0.70,
    minTurnsThreshold: number = 14
  ): boolean {
    if (!messages || messages.length <= 6) {
      return false;
    }
    if (messages.length > minTurnsThreshold) {
      return true;
    }
    let totalTokens = 0;
    for (let i = 0; i < messages.length; i++) {
      totalTokens += estimateTokenCount(messages[i].content || '');
    }
    const tokenThreshold = maxTokens * thresholdRatio;
    return totalTokens > tokenThreshold;
  }

  /**
   * Compacts conversation history when it exceeds the message threshold.
   * Preserves system prompt (index 0), distills older turns into a high-density
   * Session Checkpoint, and keeps recent complete interaction turns untouched.
   */
  static compact(messages: Message[], targetKeepRecent: number = 8): Message[] {
    if (messages.length <= 14) {
      return [...messages];
    }

    const cutIndex = ContextCompactor.findSafeTurnBoundary(messages, targetKeepRecent);
    if (cutIndex <= 2 || cutIndex >= messages.length) {
      return [...messages];
    }

    const systemMessage = messages[0];
    const olderMessages = messages.slice(1, cutIndex);
    const recentMessages = messages.slice(cutIndex);
    if (recentMessages.length === 0) {
      return [...messages];
    }

    let initialObjective = '';
    const userObjectives: string[] = [];
    const filesModified: string[] = [];
    const filesRead: string[] = [];
    const urlsAccessed: string[] = [];
    const observations: string[] = [];
    const toolsUsedSet: Set<string> = new Set();

    for (const msg of olderMessages) {
      if (msg.role === 'user') {
        const text = (msg.content || '').trim();
        if (text.length === 0) {
          continue;
        }
        // Carry over prior primary objective if re-compacting a previous checkpoint
        if (text.startsWith('[SESSION CHECKPOINT')) {
          const objMatch = text.match(/• Primary Objective:\s*([^\r\n]+)/);
          if (objMatch && objMatch[1] && !initialObjective) {
            initialObjective = objMatch[1].trim();
          }
          continue;
        }
        if (text.startsWith('[Worker Mandate]')) {
          const goalMatch = text.match(/Assigned Goal:\s*([^\r\n]+)/);
          if (goalMatch && goalMatch[1]) {
            initialObjective = goalMatch[1].trim();
          }
        }
        if (!initialObjective) {
          initialObjective = text.length > 220 ? text.substring(0, 220) + '...' : text;
        } else if (!userObjectives.includes(text)) {
          const preview = text.length > 80 ? text.substring(0, 80) + '...' : text;
          userObjectives.push(preview);
        }
      } else if (msg.role === 'assistant') {
        if (msg.tool_calls && msg.tool_calls.length > 0) {
          for (const tc of msg.tool_calls) {
            toolsUsedSet.add(tc.function.name);
            try {
              const args = JSON.parse(tc.function.arguments) as Record<string, Object>;
              if (tc.function.name === 'write' || tc.function.name === 'edit') {
                const path = String(args['path'] || '');
                if (path && !filesModified.includes(path)) {
                  filesModified.push(path);
                }
              } else if (tc.function.name === 'read') {
                const path = String(args['path'] || '');
                if (path && !filesRead.includes(path)) {
                  filesRead.push(path);
                }
              } else if (tc.function.name === 'fetch' || tc.function.name === 'browser') {
                const url = String(args['url'] || '');
                if (url && !urlsAccessed.includes(url)) {
                  urlsAccessed.push(url);
                }
              } else if (tc.function.name === 'dispatch_worker') {
                const role = String(args['role'] || 'worker');
                const goal = String(args['goal'] || '').substring(0, 60);
                if (goal) {
                  observations.push(`Dispatched ${role}: ${goal}`);
                }
              }
            } catch (e) {
              // ignore
            }
          }
        }
      } else if (msg.role === 'tool') {
        const contentStr = msg.content || '';
        if (contentStr.includes('Error') || contentStr.includes('not found') || contentStr.includes('failed')) {
          const firstLine = contentStr.split('\n')[0].substring(0, 90);
          if (!observations.includes(firstLine)) {
            observations.push(`Observed issue in ${msg.name || 'tool'}: ${firstLine}`);
          }
        }
      }
    }

    // Build structured Session Checkpoint
    let checkpoint = '[SESSION CHECKPOINT - Context Budget Managed]\n';
    checkpoint += `• Primary Objective: ${initialObjective || 'System execution task'}\n`;
    if (userObjectives.length > 0) {
      checkpoint += `• Subsequent Instructions:\n  - ${userObjectives.slice(-3).join('\n  - ')}\n`;
    }
    if (toolsUsedSet.size > 0) {
      checkpoint += `• Tools Utilized: ${Array.from(toolsUsedSet).join(', ')}\n`;
    }
    if (filesRead.length > 0) {
      checkpoint += `• Files Examined: ${filesRead.slice(-5).join(', ')}\n`;
    }
    if (filesModified.length > 0) {
      checkpoint += `• Files Modified: ${filesModified.slice(-5).join(', ')}\n`;
    }
    if (urlsAccessed.length > 0) {
      checkpoint += `• URLs Accessed: ${urlsAccessed.slice(-5).join(', ')}\n`;
    }
    if (observations.length > 0) {
      checkpoint += `• Key Observations & Learned Diagnostics:\n  - ${observations.slice(-4).join('\n  - ')}\n`;
    }
    checkpoint += `• Instruction: Older dialogue rounds have been distilled above. Full execution details continue in recent messages.`;

    const distilledUserMsg: Message = {
      role: 'user',
      content: checkpoint
    };

    if (recentMessages[0].role === 'assistant') {
      // Recent window starts directly with an assistant turn: user(checkpoint) -> assistant(...)
      return [
        systemMessage,
        distilledUserMsg,
        ...recentMessages
      ];
    }

    const distilledAssistantMsg: Message = {
      role: 'assistant',
      content: 'Understood. I retain this distilled session checkpoint and will continue execution seamlessly.'
    };

    return [
      systemMessage,
      distilledUserMsg,
      distilledAssistantMsg,
      ...recentMessages
    ];
  }

  /**
   * Finds a safe message index to partition older messages from recent messages.
   * Prefers a 'user' turn boundary; if none exists (e.g. single-prompt autonomous
   * tool loops), falls back to a safe 'assistant' turn boundary so that assistant
   * tool_calls and their corresponding 'tool' responses are never severed.
   */
  static findSafeTurnBoundary(messages: Message[], targetKeep: number): number {
    // 1. Prefer a 'user' turn boundary (keeps multi-turn tests and natural pauses clean)
    const userCut = ContextCompactor.findSafeUserTurnBoundary(messages, targetKeep);
    if (userCut >= 3) {
      return userCut;
    }

    // 2. Fallback for single-user-prompt autonomous loops: find an 'assistant' turn start
    const startSearch = Math.min(messages.length - 2, Math.max(3, messages.length - targetKeep));

    const isSafeAssistantCut = (idx: number): boolean => {
      if (idx < 3 || idx >= messages.length) {
        return false;
      }
      const cur = messages[idx];
      if (cur.role !== 'assistant') {
        return false;
      }
      const prev = messages[idx - 1];
      // Must not split consecutive assistant turns with pending tool calls
      if (prev.role === 'assistant' && prev.tool_calls && prev.tool_calls.length > 0) {
        return false;
      }
      // If followed by a 'tool' message, this assistant turn must own tool_calls
      if (idx + 1 < messages.length && messages[idx + 1].role === 'tool') {
        if (!cur.tool_calls || cur.tool_calls.length === 0) {
          return false;
        }
      }
      return true;
    };

    for (let i = startSearch; i >= 3; i--) {
      if (isSafeAssistantCut(i)) {
        return i;
      }
    }

    for (let i = startSearch + 1; i < messages.length - 1; i++) {
      if (isSafeAssistantCut(i)) {
        return i;
      }
    }

    return -1;
  }

  /**
   * Finds a safe 'user' turn boundary in messages[2..length-3].
   */
  static findSafeUserTurnBoundary(messages: Message[], targetKeep: number): number {
    const startSearch = Math.min(messages.length - 2, Math.max(2, messages.length - targetKeep));

    const isSafeUserCut = (idx: number): boolean => {
      if (messages[idx].role !== 'user') {
        return false;
      }
      if (idx + 1 < messages.length && messages[idx + 1].role === 'tool') {
        return false;
      }
      const prev = messages[idx - 1];
      if (prev.role === 'assistant' && prev.tool_calls && prev.tool_calls.length > 0) {
        return false;
      }
      return true;
    };

    // Search backwards for a safe 'user' message
    for (let i = startSearch; i >= 2; i--) {
      if (isSafeUserCut(i)) {
        return i;
      }
    }

    // If not found backwards, search forwards
    for (let i = startSearch + 1; i < messages.length - 2; i++) {
      if (isSafeUserCut(i)) {
        return i;
      }
    }

    return -1;
  }
}
