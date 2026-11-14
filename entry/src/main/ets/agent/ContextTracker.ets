/*
 * ContextTracker: Accurately estimates token usage across:
 * - System Prompt (base prompt & active goal)
 * - Tools & Function Definitions (JSON schema)
 * - Conversation Messages (user, assistant, tool responses)
 * - Memory & Connectors (Memory lessons & Bridge)
 * - Skills (Skill descriptions & files)
 */
import { Message } from './types';
import { ToolRegistry } from './tools/ToolRegistry';
import { MemoryStore } from './memory/MemoryStore';
import { SkillManager } from './skills/SkillManager';
import { GoalManager } from './goal/GoalManager';

export interface ContextUsageDetail {
  category: string;
  name: string;
  color: string;
  tokens: number;
  percentage: number;
}

export interface ContextUsageSummary {
  totalTokens: number;
  maxTokens: number;
  usedPercentage: number;
  systemPrompt: ContextUsageDetail;
  tools: ContextUsageDetail;
  messages: ContextUsageDetail;
  memory: ContextUsageDetail;
  skills: ContextUsageDetail;
  details: ContextUsageDetail[];
}

export interface ContextCapacityOption {
  label: string;
  tokens: number;
}

export const CONTEXT_CAPACITIES: ContextCapacityOption[] = [
  { label: '300K 上下文 · 默认', tokens: 300000 },
  { label: '500K 上下文', tokens: 500000 },
  { label: '1M 上下文', tokens: 1000000 }
];

export function estimateTokenCount(text: string): number {
  if (!text || text.length === 0) {
    return 0;
  }
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    // CJK characters
    if ((code >= 0x4e00 && code <= 0x9fa5) || (code >= 0x3400 && code <= 0x4dbf) || code > 0xff) {
      count += 1.4;
    } else if (code <= 0x20) {
      count += 0.2;
    } else {
      count += 0.35;
    }
  }
  return Math.max(1, Math.ceil(count));
}

export class ContextTracker {
  private static instance: ContextTracker = new ContextTracker();
  private maxTokens: number = 300000; // Default 300K context window

  static getInstance(): ContextTracker {
    return ContextTracker.instance;
  }

  getMaxTokens(): number {
    return this.maxTokens;
  }

  setMaxTokens(max: number): void {
    this.maxTokens = Math.max(32000, max);
  }

  computeUsage(messages: Message[]): ContextUsageSummary {
    // 1. System Prompt (Base + Goal)
    let sysText = 'You are a helpful and expert AI coding and system agent running directly on a HarmonyOS NEXT device. You have access to native shell execution with uid 2000...';
    const goalBlock = GoalManager.getInstance().formatGoalForPrompt();
    if (goalBlock) {
      sysText += '\n' + goalBlock;
    }
    const sysTokens = Math.max(1200, estimateTokenCount(sysText) + 800);

    // 2. Tools & Function schemas (Tool definitions passed to LLM API)
    const toolDefs = ToolRegistry.getDefinitions();
    const toolsText = JSON.stringify(toolDefs);
    const toolsTokens = Math.max(2500, estimateTokenCount(toolsText));

    // 3. Conversation Messages
    let msgText = '';
    let imageTokens = 0;
    for (const m of messages) {
      if (m.role !== 'system') {
        msgText += (m.content || '') + ' ' + (m.reasoning_content || '') + ' ';
        if (m.tool_calls) {
          msgText += JSON.stringify(m.tool_calls);
        }
        if (m.images && m.images.length > 0) {
          for (const img of m.images) {
            if (img.detail === 'low') {
              imageTokens += 600;
            } else if (img.detail === 'high') {
              imageTokens += 6000;
            } else {
              imageTokens += 2000;
            }
          }
        }
      }
    }
    const msgTokens = estimateTokenCount(msgText) + imageTokens;

    // 4. Memory & Connectors
    const memBlock = MemoryStore.getInstance().formatLessonsForPrompt(8);
    const memTokens = estimateTokenCount(memBlock || '') + 220; // Bridge & HDC context

    // 5. Skills
    const skillsBlock = SkillManager.getInstance().formatSkillsForPrompt('read');
    const skillsTokens = estimateTokenCount(skillsBlock || '') + 450;

    const totalTokens = sysTokens + toolsTokens + msgTokens + memTokens + skillsTokens;
    const max = this.maxTokens;
    const usedPercentage = Math.min(100, Math.round((totalTokens / max) * 1000) / 10);

    const calcPct = (tokens: number): number => {
      return Math.min(100, Math.round((tokens / max) * 1000) / 10);
    };

    const sysDetail: ContextUsageDetail = {
      category: 'system',
      name: '系统提示词',
      color: '#6366f1',
      tokens: sysTokens,
      percentage: calcPct(sysTokens)
    };

    const toolsDetail: ContextUsageDetail = {
      category: 'tools',
      name: '工具及子智能体',
      color: '#10b981',
      tokens: toolsTokens,
      percentage: calcPct(toolsTokens)
    };

    const msgDetail: ContextUsageDetail = {
      category: 'messages',
      name: '对话消息',
      color: '#f59e0b',
      tokens: msgTokens,
      percentage: calcPct(msgTokens)
    };

    const memDetail: ContextUsageDetail = {
      category: 'memory',
      name: '连接器及MCP',
      color: '#8b5cf6',
      tokens: memTokens,
      percentage: calcPct(memTokens)
    };

    const skillsDetail: ContextUsageDetail = {
      category: 'skills',
      name: '技能',
      color: '#ec4899',
      tokens: skillsTokens,
      percentage: calcPct(skillsTokens)
    };

    return {
      totalTokens,
      maxTokens: max,
      usedPercentage,
      systemPrompt: sysDetail,
      tools: toolsDetail,
      messages: msgDetail,
      memory: memDetail,
      skills: skillsDetail,
      details: [sysDetail, toolsDetail, msgDetail, memDetail, skillsDetail]
    };
  }
}
