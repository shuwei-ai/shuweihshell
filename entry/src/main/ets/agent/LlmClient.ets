/*
 * Streaming LLM client for OpenAI / DeepSeek / Qwen / MiniMax Chat Completions API.
 * Parses Server-Sent Events (SSE) including reasoning_content and tool_calls.
 * Features robust error interception, race-condition protection, and reasoning fallback.
 */
import http from '@ohos.net.http';
import buffer from '@ohos.buffer';
import hilog from '@ohos.hilog';
import { AgentModelConfig, ImageAttachment, Message, ToolCall, ToolDefinition } from './types';

const DOMAIN: number = 0x0001;
const TAG: string = 'LlmClient';

export interface StreamCallbacks {
  onThinkingDelta?: (text: string) => void;
  onContentDelta?: (text: string) => void;
  onToolCallDelta?: (toolCalls: ToolCall[]) => void;
  onRetry?: (attempt: number, maxRetries: number, delayMs: number, reason: string) => void;
}

export interface RetryDecision {
  isRetryable: boolean;
  reason: string;
  statusCode?: number;
}

export interface StreamResult {
  content: string;
  reasoning_content: string;
  tool_calls: ToolCall[];
}

export interface SseFunctionDelta {
  name?: string;
  arguments?: string;
}

export interface SseToolCallDelta {
  index?: number;
  id?: string;
  type?: string;
  function?: SseFunctionDelta;
}

export interface SseChoiceDelta {
  role?: string;
  content?: string;
  reasoning_content?: string;
  tool_calls?: SseToolCallDelta[];
}

export interface SseChoice {
  index: number;
  delta?: SseChoiceDelta;
  finish_reason?: string;
}

export interface SseChunk {
  id?: string;
  choices?: SseChoice[];
}

function findIncompleteUtf8ByteCount(bytes: Uint8Array): number {
  const len = bytes.length;
  if (len === 0) {
    return 0;
  }
  for (let i = 1; i <= Math.min(4, len); i++) {
    const b = bytes[len - i];
    if ((b & 0x80) === 0) {
      return 0;
    }
    if ((b & 0xE0) === 0xC0) {
      return i < 2 ? i : 0;
    }
    if ((b & 0xF0) === 0xE0) {
      return i < 3 ? i : 0;
    }
    if ((b & 0xF8) === 0xF0) {
      return i < 4 ? i : 0;
    }
  }
  return 0;
}

export class LlmClient {
  private activeRequest: http.HttpRequest | undefined = undefined;
  private abortRequested: boolean = false;
  private sleepResolve: (() => void) | undefined = undefined;

  abort(): void {
    this.abortRequested = true;
    if (this.sleepResolve !== undefined) {
      this.sleepResolve();
      this.sleepResolve = undefined;
    }
    if (this.activeRequest !== undefined) {
      try {
        this.activeRequest.destroy();
      } catch (err) {
        // ignore
      }
      this.activeRequest = undefined;
    }
  }

  private sleepWithAbort(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      let timer: number = -1;
      this.sleepResolve = () => {
        if (timer !== -1) {
          clearTimeout(timer);
        }
        resolve();
      };
      timer = setTimeout(() => {
        this.sleepResolve = undefined;
        resolve();
      }, ms);
    });
  }

  /**
   * Sanitizes conversation messages so every assistant(tool_calls) turn is immediately
   * followed by matching 'tool' messages for all declared tool_call_ids, and drops any
   * orphaned/duplicate 'tool' messages that would trigger API error 2013.
   */
  static sanitizeMessages(messages: Message[]): Message[] {
    const result: Message[] = [];
    let syntheticCounter = 0;

    let i = 0;
    while (i < messages.length) {
      const m = messages[i];

      if (m.role === 'tool') {
        // Orphaned tool message without an immediately preceding matching assistant(tool_calls)
        i++;
        continue;
      }

      if (m.role === 'assistant' && m.tool_calls && m.tool_calls.length > 0) {
        const validCalls: ToolCall[] = [];
        const expectedIds: Set<string> = new Set();

        for (let k = 0; k < m.tool_calls.length; k++) {
          const origTc = m.tool_calls[k];
          const fnName = origTc.function && origTc.function.name ? origTc.function.name.trim() : '';
          if (fnName.length === 0) {
            continue;
          }
          let callId = origTc.id ? origTc.id.trim() : '';
          if (callId.length === 0 || expectedIds.has(callId)) {
            syntheticCounter++;
            callId = `call_repaired_${i}_${k}_${syntheticCounter}`;
          }
          expectedIds.add(callId);
          validCalls.push({
            id: callId,
            type: origTc.type && origTc.type.length > 0 ? origTc.type : 'function',
            function: {
              name: fnName,
              arguments: origTc.function && origTc.function.arguments !== undefined
                ? origTc.function.arguments
                : '{}'
            }
          });
        }

        if (validCalls.length === 0) {
          const fallbackText = m.content && m.content.trim().length > 0
            ? m.content
            : '[Interrupted malformed tool call]';
          result.push({
            role: 'assistant',
            content: fallbackText,
            reasoning_content: m.reasoning_content
          });
          i++;
          continue;
        }

        result.push({
          role: 'assistant',
          content: m.content ?? '',
          reasoning_content: m.reasoning_content,
          tool_calls: validCalls
        });

        const answeredIds: Set<string> = new Set();
        let j = i + 1;
        while (j < messages.length && messages[j].role === 'tool') {
          const toolMsg = messages[j];
          const tid = toolMsg.tool_call_id ? toolMsg.tool_call_id.trim() : '';

          if (tid.length > 0 && expectedIds.has(tid) && !answeredIds.has(tid)) {
            answeredIds.add(tid);
            result.push({
              role: 'tool',
              tool_call_id: tid,
              name: toolMsg.name,
              content: toolMsg.content ?? '',
              images: toolMsg.images
            });
          } else if (
            tid.length === 0 &&
            validCalls.length === 1 &&
            !answeredIds.has(validCalls[0].id)
          ) {
            answeredIds.add(validCalls[0].id);
            result.push({
              role: 'tool',
              tool_call_id: validCalls[0].id,
              name: toolMsg.name || validCalls[0].function.name,
              content: toolMsg.content ?? '',
              images: toolMsg.images
            });
          }
          j++;
        }

        for (let k = 0; k < validCalls.length; k++) {
          const tc = validCalls[k];
          if (!answeredIds.has(tc.id)) {
            answeredIds.add(tc.id);
            result.push({
              role: 'tool',
              tool_call_id: tc.id,
              name: tc.function.name,
              content: '[Tool execution interrupted or cancelled]'
            });
          }
        }

        i = j;
        continue;
      }

      result.push({
        role: m.role,
        content: m.content ?? '',
        images: m.images,
        reasoning_content: m.reasoning_content,
        name: m.name
      });
      i++;
    }

    return result;
  }

  static checkRetryable(err: Object | string): RetryDecision {
    const msg = typeof err === 'string' ? err : String((err as Error).message || err);
    const lower = msg.toLowerCase();

    if (lower.includes('cancel') || lower.includes('abort')) {
      return { isRetryable: false, reason: 'Request cancelled by user' };
    }

    const statusMatch = msg.match(/(?:status|status code|response code|http_code["']?)\s*[:=]?\s*["']?(\d{3})["']?/i);
    let code: number | undefined = undefined;
    if (statusMatch && statusMatch[1]) {
      code = parseInt(statusMatch[1], 10);
    }

    if (code !== undefined) {
      if (code === 429) {
        return { isRetryable: true, reason: 'Rate limited (HTTP 429)', statusCode: code };
      }
      if (code >= 500 && code <= 599) {
        return { isRetryable: true, reason: `Server error (HTTP ${code})`, statusCode: code };
      }
      if (code === 400 || code === 401 || code === 403 || code === 404 || code === 422) {
        return { isRetryable: false, reason: `Client error (HTTP ${code})`, statusCode: code };
      }
    }

    if (
      lower.includes('bad_request_error') ||
      lower.includes('invalid params') ||
      lower.includes('authentication_error') ||
      lower.includes('invalid_api_key') ||
      lower.includes('insufficient_balance')
    ) {
      return { isRetryable: false, reason: 'Client parameter or authentication error', statusCode: code };
    }

    if (
      lower.includes('timeout') ||
      lower.includes('timed out') ||
      lower.includes('econnreset') ||
      lower.includes('etimedout') ||
      lower.includes('enotfound') ||
      lower.includes('socket') ||
      lower.includes('closed without returning') ||
      lower.includes('closed before returning') ||
      lower.includes('stream request failed') ||
      lower.includes('network')
    ) {
      return { isRetryable: true, reason: 'Network connection or stream glitch', statusCode: code };
    }

    return { isRetryable: true, reason: 'Transient API glitch', statusCode: code };
  }

  async streamChat(
    config: AgentModelConfig,
    messages: Message[],
    tools: ToolDefinition[],
    callbacks: StreamCallbacks,
    maxRetries: number = 3
  ): Promise<StreamResult> {
    this.abortRequested = false;
    let attempt = 0;
    let delayMs = 1000;

    while (!this.abortRequested) {
      attempt++;
      try {
        return await this.executeSingleStreamRequest(config, messages, tools, callbacks);
      } catch (err) {
        const errorToThrow = (err instanceof Error) ? err : new Error(`${err}`);
        if (this.abortRequested) {
          throw errorToThrow;
        }

        const decision = LlmClient.checkRetryable(err);
        if (!decision.isRetryable || attempt > maxRetries) {
          hilog.error(
            DOMAIN,
            TAG,
            'LLM stream failed permanently (attempt %{public}d/%{public}d, retryable=%{public}s): %{public}s',
            attempt,
            maxRetries + 1,
            String(decision.isRetryable),
            `${err}`
          );
          throw errorToThrow;
        }

        const jitter = Math.floor(Math.random() * 300);
        const waitMs = delayMs + jitter;

        hilog.warn(
          DOMAIN,
          TAG,
          'LLM stream transient failure (attempt %{public}d/%{public}d): %{public}s. Retrying in %{public}dms...',
          attempt,
          maxRetries + 1,
          decision.reason,
          waitMs
        );

        if (callbacks.onRetry) {
          callbacks.onRetry(attempt, maxRetries + 1, waitMs, decision.reason);
        }

        await this.sleepWithAbort(waitMs);
        if (this.abortRequested) {
          throw new Error('LLM request cancelled by user during retry backoff');
        }

        delayMs = Math.min(delayMs * 2, 8000);
      }
    }

    throw new Error('LLM request aborted by user');
  }

  /**
   * Detects MiniMax endpoints or models where OpenAI-compatible multimodal tool messages
   * and MiniMax thinking / reasoning_effort parameters apply.
   */
  static isMiniMaxEndpoint(config: AgentModelConfig): boolean {
    const base = (config.baseUrl || '').toLowerCase();
    const model = (config.modelName || '').toLowerCase();
    return base.includes('minimax') || base.includes('minimaxi') || model.includes('minimax');
  }

  /**
   * Builds OpenAI / MiniMax multimodal content parts array combining text and image_url blocks.
   */
  static buildImageContentParts(text: string, images: ImageAttachment[]): Object[] {
    const parts: Record<string, Object>[] = [];
    const safeText = text && text.trim().length > 0
      ? text
      : 'Please inspect the attached image(s).';
    const textPart: Record<string, Object> = {
      'type': 'text',
      'text': safeText
    };
    parts.push(textPart);

    for (let i = 0; i < images.length; i++) {
      const img = images[i];
      if (!img.dataUrl || img.dataUrl.trim().length === 0) {
        continue;
      }
      const imageUrlObj: Record<string, Object> = {
        'url': img.dataUrl
      };
      if (img.detail === 'low' || img.detail === 'default' || img.detail === 'high') {
        imageUrlObj['detail'] = img.detail;
      }
      const imgPart: Record<string, Object> = {
        'type': 'image_url',
        'image_url': imageUrlObj as Object
      };
      parts.push(imgPart);
    }
    return parts as Object[];
  }

  /**
   * Formats conversation history into OpenAI / MiniMax Chat Completions JSON message objects.
   * Keeps up to the newest 8 image-bearing messages on the wire to stay well below payload limits,
   * and moves tool images into follow-up user messages when targeting non-MiniMax endpoints.
   */
  static formatMessagesForWire(messages: Message[], isMiniMax: boolean): Record<string, Object>[] {
    const cleanMessages = LlmClient.sanitizeMessages(messages);

    const MAX_WIRE_IMAGE_MESSAGES = 8;
    const imageMsgIndices: number[] = [];
    for (let idx = 0; idx < cleanMessages.length; idx++) {
      const imgs = cleanMessages[idx].images;
      if (imgs && imgs.length > 0) {
        imageMsgIndices.push(idx);
      }
    }
    const activeImageCutoff = imageMsgIndices.length > MAX_WIRE_IMAGE_MESSAGES
      ? imageMsgIndices[imageMsgIndices.length - MAX_WIRE_IMAGE_MESSAGES]
      : 0;

    const formattedMessages: Record<string, Object>[] = [];
    let deferredToolImages: ImageAttachment[] = [];

    const flushDeferredToolImages = (): void => {
      if (deferredToolImages.length === 0) {
        return;
      }
      const userImgMsg: Record<string, Object> = {
        'role': 'user',
        'content': LlmClient.buildImageContentParts(
          'Visual image output returned by the preceding tool execution:',
          deferredToolImages
        ) as Object
      };
      formattedMessages.push(userImgMsg);
      deferredToolImages = [];
    };

    for (let idx = 0; idx < cleanMessages.length; idx++) {
      const m = cleanMessages[idx];
      if (m.role !== 'tool') {
        flushDeferredToolImages();
      }

      const item: Record<string, Object> = {
        'role': m.role
      };

      const hasToolCalls = m.tool_calls && m.tool_calls.length > 0;
      const rawContent = m.content ? m.content.trim() : '';
      const hasImages = m.images && m.images.length > 0;
      const keepImages = hasImages && idx >= activeImageCutoff;
      const activeImages: ImageAttachment[] = keepImages && m.images ? m.images : [];

      let textContent = m.content ?? '';
      if (hasImages && !keepImages) {
        const omitNote = '[Earlier attached image(s) omitted to conserve request budget]';
        textContent = rawContent.length > 0 ? `${textContent}\n${omitNote}` : omitNote;
      }

      if (hasToolCalls) {
        item['tool_calls'] = m.tool_calls as Object;
        if (textContent.trim().length > 0) {
          item['content'] = textContent;
        }
      } else if (m.role === 'tool' && activeImages.length > 0) {
        if (isMiniMax) {
          item['content'] = LlmClient.buildImageContentParts(textContent, activeImages) as Object;
        } else {
          const note = '[Image output attached in the immediately following user message]';
          item['content'] = textContent.trim().length > 0 ? `${textContent}\n${note}` : note;
          for (let k = 0; k < activeImages.length; k++) {
            deferredToolImages.push(activeImages[k]);
          }
        }
      } else if (m.role === 'user' && activeImages.length > 0) {
        item['content'] = LlmClient.buildImageContentParts(textContent, activeImages) as Object;
      } else {
        item['content'] = textContent.trim().length > 0 ? textContent : '(no content)';
      }

      if (m.tool_call_id) {
        item['tool_call_id'] = m.tool_call_id;
      }
      if (m.name) {
        item['name'] = m.name;
      }
      formattedMessages.push(item);
    }

    flushDeferredToolImages();

    // Safety Guard: OpenAI/MiniMax returns error 2013 if messages array is empty
    if (formattedMessages.length === 0) {
      hilog.error(DOMAIN, TAG, 'formatMessagesForWire produced 0 messages! Injecting emergency prompt.');
      formattedMessages.push({
        'role': 'user',
        'content': 'Please proceed with the current task.'
      });
    }

    return formattedMessages;
  }

  /**
   * Builds the full Chat Completions request payload object for OpenAI / MiniMax APIs.
   */
  static buildRequestPayload(
    config: AgentModelConfig,
    messages: Message[],
    tools: ToolDefinition[],
    stream: boolean = true
  ): Record<string, Object> {
    const isMiniMax = LlmClient.isMiniMaxEndpoint(config);
    const formattedMessages = LlmClient.formatMessagesForWire(messages, isMiniMax);

    const payloadObj: Record<string, Object> = {
      'model': config.modelName,
      'messages': formattedMessages as Object,
      'stream': stream
    };

    const mLower = (config.modelName || '').toLowerCase();
    if (isMiniMax) {
      if (mLower.includes('m3.1-flash')) {
        // MiniMax-M3.1-Flash forces thinking ON ('disabled'/'none' returns HTTP 400); adjust via reasoning_effort
        payloadObj['reasoning_effort'] = config.enableThinking ? 'high' : 'low';
      } else if (mLower.includes('minimax-m3')) {
        const thinkingObj: Record<string, Object> = {
          'type': config.enableThinking ? 'adaptive' : 'disabled'
        };
        payloadObj['thinking'] = thinkingObj as Object;
      }
    } else if (mLower.includes('o1') || mLower.includes('o3')) {
      payloadObj['reasoning_effort'] = config.enableThinking ? 'high' : 'low';
    }

    if (tools.length > 0) {
      payloadObj['tools'] = tools as Object;
    }

    return payloadObj;
  }

  private async executeSingleStreamRequest(
    config: AgentModelConfig,
    messages: Message[],
    tools: ToolDefinition[],
    callbacks: StreamCallbacks
  ): Promise<StreamResult> {
    if (this.activeRequest !== undefined) {
      try {
        this.activeRequest.destroy();
      } catch (err) {
        // ignore
      }
      this.activeRequest = undefined;
    }

    let fullContent = '';
    let fullReasoning = '';
    const toolCallsMap: Map<number, ToolCall> = new Map();

    let url = config.baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.endsWith('/chat/completions')) {
      url = `${url}/chat/completions`;
    }

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream'
    };
    if (config.apiKey && config.apiKey.trim().length > 0) {
      headers['Authorization'] = `Bearer ${config.apiKey.trim()}`;
    }

    const payloadObj = LlmClient.buildRequestPayload(config, messages, tools, true);
    const payloadJson = JSON.stringify(payloadObj);
    const httpRequest = http.createHttp();
    this.activeRequest = httpRequest;

    return new Promise<StreamResult>((resolve, reject) => {
      let pendingBuffer = '';
      let isDone = false;
      let httpStatusCode = 0;
      let hasValidSseChunk = false;
      let rawResponseText = '';
      let errorSafetyTimer: number = -1;

      const finishSuccess = () => {
        if (isDone) {
          return;
        }
        isDone = true;
        if (errorSafetyTimer !== -1) {
          clearTimeout(errorSafetyTimer);
          errorSafetyTimer = -1;
        }
        this.activeRequest = undefined;
        try {
          httpRequest.destroy();
        } catch (e) {
          // ignore
        }

        const sortedCalls: ToolCall[] = [];
        const keys = Array.from(toolCallsMap.keys()).sort((a, b) => a - b);
        for (const k of keys) {
          const call = toolCallsMap.get(k);
          if (call !== undefined) {
            sortedCalls.push(call);
          }
        }

        // Reasoning fallback: if model only output reasoning_content and zero content/tools,
        // use reasoning as content so UI never renders an empty blank card!
        let finalContent = fullContent;
        if (finalContent.trim().length === 0 && sortedCalls.length === 0 && fullReasoning.trim().length > 0) {
          hilog.info(DOMAIN, TAG, 'Model content is empty, promoting reasoning_content to primary content');
          finalContent = fullReasoning;
        }

        resolve({
          content: finalContent,
          reasoning_content: fullReasoning,
          tool_calls: sortedCalls
        });
      };

      const finishError = (errMessage: string) => {
        if (isDone) {
          return;
        }
        isDone = true;
        if (errorSafetyTimer !== -1) {
          clearTimeout(errorSafetyTimer);
          errorSafetyTimer = -1;
        }
        this.activeRequest = undefined;
        try {
          httpRequest.destroy();
        } catch (e) {
          // ignore
        }
        hilog.error(DOMAIN, TAG, 'LLM stream error rejected: %{public}s', errMessage);
        reject(new Error(errMessage));
      };

      const processLine = (line: string) => {
        const trimmed = line.trim();
        if (trimmed.length === 0) {
          return;
        }
        if (trimmed === 'data: [DONE]') {
          finishSuccess();
          return;
        }
        if (!trimmed.startsWith('data:')) {
          return;
        }

        const jsonStr = trimmed.substring(5).trim();
        if (jsonStr.length === 0) {
          return;
        }

        try {
          const chunk = JSON.parse(jsonStr) as SseChunk;
          if (!chunk.choices || chunk.choices.length === 0) {
            return;
          }
          const delta = chunk.choices[0].delta;
          if (!delta) {
            return;
          }

          // Handle DeepSeek / R1 / MiniMax reasoning_content
          if (delta.reasoning_content && delta.reasoning_content.length > 0) {
            hasValidSseChunk = true;
            fullReasoning += delta.reasoning_content;
            if (config.enableThinking && callbacks.onThinkingDelta) {
              callbacks.onThinkingDelta(delta.reasoning_content);
            }
          }

          // Handle content
          if (delta.content && delta.content.length > 0) {
            hasValidSseChunk = true;
            fullContent += delta.content;
            if (callbacks.onContentDelta) {
              callbacks.onContentDelta(delta.content);
            }
          }

          // Handle tool calls
          if (delta.tool_calls && delta.tool_calls.length > 0) {
            hasValidSseChunk = true;
            for (const tc of delta.tool_calls) {
              const trimmedId = tc.id ? tc.id.trim() : '';
              const hasValidId = trimmedId.length > 0;
              let idx = tc.index;
              if (idx === undefined) {
                if (hasValidId) {
                  let matchedIdx = -1;
                  toolCallsMap.forEach((existingCall: ToolCall, mapIdx: number) => {
                    if (existingCall.id === trimmedId) {
                      matchedIdx = mapIdx;
                    }
                  });
                  if (matchedIdx !== -1) {
                    idx = matchedIdx;
                  } else {
                    idx = toolCallsMap.has(0) ? toolCallsMap.size : 0;
                  }
                } else {
                  idx = toolCallsMap.size > 0 ? toolCallsMap.size - 1 : 0;
                }
              }

              let currentCall = toolCallsMap.get(idx);
              if (currentCall === undefined) {
                currentCall = {
                  id: hasValidId ? trimmedId : `call_${idx}_${Date.now()}`,
                  type: tc.type ?? 'function',
                  function: {
                    name: tc.function?.name ?? '',
                    arguments: tc.function?.arguments ?? ''
                  }
                };
                toolCallsMap.set(idx, currentCall);
              } else {
                if (hasValidId) {
                  currentCall.id = trimmedId;
                }
                if (tc.type) {
                  currentCall.type = tc.type;
                }
                if (tc.function?.name) {
                  currentCall.function.name += tc.function.name;
                }
                if (tc.function?.arguments) {
                  currentCall.function.arguments += tc.function.arguments;
                }
              }
            }

            if (callbacks.onToolCallDelta) {
              const currentList: ToolCall[] = [];
              const keys = Array.from(toolCallsMap.keys()).sort((a, b) => a - b);
              for (const k of keys) {
                const call = toolCallsMap.get(k);
                if (call !== undefined) {
                  currentList.push(call);
                }
              }
              callbacks.onToolCallDelta(currentList);
            }
          }
        } catch (e) {
          // Ignore incomplete JSON chunks
        }
      };

      let leftoverBytes: Uint8Array = new Uint8Array(0);

      httpRequest.on('dataReceive', (data: ArrayBuffer) => {
        try {
          const incoming = new Uint8Array(data);
          let combined: Uint8Array;
          if (leftoverBytes.length > 0) {
            combined = new Uint8Array(leftoverBytes.length + incoming.length);
            combined.set(leftoverBytes, 0);
            combined.set(incoming, leftoverBytes.length);
          } else {
            combined = incoming;
          }

          const incompleteCount = findIncompleteUtf8ByteCount(combined);
          const completeLen = combined.length - incompleteCount;
          const completeBytes = combined.subarray(0, completeLen);
          leftoverBytes = combined.subarray(completeLen);

          const textChunk = buffer.from(completeBytes.buffer, completeBytes.byteOffset, completeBytes.byteLength).toString('utf-8');
          rawResponseText += textChunk;
          pendingBuffer += textChunk;
          const lines = pendingBuffer.split('\n');
          pendingBuffer = lines.pop() ?? '';
          for (const l of lines) {
            processLine(l);
          }
        } catch (e) {
          // ignore chunk decoding error
        }
      });

      httpRequest.on('dataEnd', () => {
        if (leftoverBytes.length > 0) {
          try {
            const finalChunk = buffer.from(leftoverBytes.buffer, leftoverBytes.byteOffset, leftoverBytes.byteLength).toString('utf-8');
            pendingBuffer += finalChunk;
          } catch (e) {
            // ignore
          }
          leftoverBytes = new Uint8Array(0);
        }
        if (pendingBuffer.length > 0) {
          processLine(pendingBuffer);
          pendingBuffer = '';
        }

        // 1. Guard against HTTP error status codes (e.g. 400, 401, 429, 500)
        if (httpStatusCode >= 400) {
          const detail = rawResponseText.trim().substring(0, 300);
          finishError(`HTTP Error status ${httpStatusCode} from ${url}${detail ? `: ${detail}` : ''}`);
          return;
        }

        // 2. Guard against aborted/empty responses without valid data
        if (fullContent.length === 0 && toolCallsMap.size === 0 && fullReasoning.length === 0) {
          if (rawResponseText.trim().length > 0) {
            finishError(`API error: ${rawResponseText.trim().substring(0, 300)}`);
            return;
          }
          finishError('API connection closed before returning content or tool calls');
          return;
        }

        finishSuccess();
      });

      const requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: payloadJson,
        connectTimeout: 30000,
        readTimeout: 120000
      };

      httpRequest.requestInStream(url, requestOptions, (err, responseCode) => {
        if (err) {
          finishError(`HTTP stream request failed: ${JSON.stringify(err)}`);
          return;
        }
        httpStatusCode = responseCode;
        if (responseCode >= 400) {
          // Wait briefly for dataReceive/dataEnd to deliver the error payload.
          // If dataEnd does not fire within 2500ms, force trigger finishError.
          errorSafetyTimer = setTimeout(() => {
            const detail = rawResponseText.trim().substring(0, 300);
            finishError(`HTTP Error status ${responseCode} from ${url}${detail ? `: ${detail}` : ''}`);
          }, 2500);
        }
      });
    });
  }
}
