/*
 * Types and definitions for the Pi Agent engine on HarmonyOS.
 * Modeled after @earendil-works/pi-coding-agent.
 */
import { AttentionRequest, WorkerReport, WorkerRole } from './superagent/types';

export type MessageRole = 'system' | 'user' | 'assistant' | 'tool';

export type ImageDetailLevel = 'low' | 'default' | 'high';

export interface ImageAttachment {
  dataUrl: string;
  detail?: ImageDetailLevel;
  previewUri?: string;
  sourcePath?: string;
  width?: number;
  height?: number;
  byteLength?: number;
}

export interface FunctionCallInfo {
  name: string;
  arguments: string;
}

export interface ToolCall {
  id: string;
  type: string;
  function: FunctionCallInfo;
}

export interface Message {
  role: MessageRole;
  content: string;
  images?: ImageAttachment[];
  reasoning_content?: string;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  name?: string;
}

export class ToolProperty {
  type: string = 'string';
  description: string = '';
  items?: Record<string, string>;

  constructor(type: string, description: string, items?: Record<string, string>) {
    this.type = type;
    this.description = description;
    this.items = items;
  }
}

export class ToolParameters {
  type: string = 'object';
  properties: Record<string, ToolProperty> = {};
  required?: string[];

  constructor(properties: Record<string, ToolProperty>, required?: string[]) {
    this.type = 'object';
    this.properties = properties;
    this.required = required;
  }
}

export class ToolFunctionDefinition {
  name: string = '';
  description: string = '';
  parameters: ToolParameters = new ToolParameters({});

  constructor(name: string, description: string, parameters: ToolParameters) {
    this.name = name;
    this.description = description;
    this.parameters = parameters;
  }
}

export class ToolDefinition {
  type: string = 'function';
  function: ToolFunctionDefinition;

  constructor(funcDef: ToolFunctionDefinition) {
    this.type = 'function';
    this.function = funcDef;
  }
}

export interface ToolResult {
  toolCallId: string;
  toolName: string;
  output: string;
  images?: ImageAttachment[];
  error?: string;
  isError: boolean;
}

export type SessionEventType =
  | 'user_message_appended'
  | 'thinking_delta'
  | 'text_delta'
  | 'tool_call_start'
  | 'tool_call_result'
  | 'turn_complete'
  | 'error'
  | 'stopped'
  | 'memory_updated'
  | 'goal_updated'
  | 'goal_continued'
  | 'intervention_triggered'
  | 'worker_progress'
  | 'worker_completed'
  | 'attention_requested'
  | 'attention_resolved';

export type MemoryCategory = 'shell' | 'network' | 'permission' | 'tools' | 'device' | 'general';

export interface MemoryLesson {
  id: string;
  category: MemoryCategory;
  rule: string;
  triggerPattern?: string;
  occurrenceCount: number;
  confidence: number;
  createdAt: number;
  lastUpdated: number;
}

export interface SessionEvent {
  type: SessionEventType;
  text?: string;
  images?: ImageAttachment[];
  toolCall?: ToolCall;
  toolResult?: ToolResult;
  error?: string;
  memoryLesson?: MemoryLesson;
  goal?: Object;
  attentionRequest?: AttentionRequest;
  workerReport?: WorkerReport;
  workerRole?: WorkerRole;
}

export interface AgentModelConfig {
  baseUrl: string;
  apiKey: string;
  modelName: string;
  autoRunTools: boolean;
  enableThinking: boolean;
}

export interface RemoteServerConfig {
  enabled: boolean;
  host: string;
  port: number;
  username: string;
  password: string;
  privateKeyPem: string;
  defaultWorkDir: string;
  expectedFingerprint: string;
}
