/*
 * Native Network Request (Fetch) Tool for HarmonyOS Pi-Agent.
 * Uses @ohos.net.http to provide direct, fast HTTP/HTTPS requests (GET, POST, PUT, DELETE, HEAD, OPTIONS).
 * Replaces missing shell curl/wget with native HarmonyOS TLS and network capabilities.
 */
import http from '@ohos.net.http';
import hilog from '@ohos.hilog';
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';

const DOMAIN: number = 0x0001;
const TAG: string = 'FetchTool';

export class FetchTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'url': new ToolProperty('string', 'The target HTTP/HTTPS URL to request (e.g. "https://api.github.com/zen").'),
      'method': new ToolProperty('string', 'HTTP method: GET, POST, PUT, DELETE, HEAD, OPTIONS. Default is GET.'),
      'headers': new ToolProperty('object', 'Optional HTTP request headers as key-value pairs (e.g. {"Authorization": "Bearer ...", "Content-Type": "application/json"}).'),
      'body': new ToolProperty('string', 'Optional request payload/body string for POST or PUT requests.'),
      'timeoutMs': new ToolProperty('number', 'Timeout in milliseconds (default: 15000).')
    };

    const params = new ToolParameters(props, ['url']);
    const func = new ToolFunctionDefinition(
      'fetch',
      'Send direct HTTP/HTTPS requests using the native HarmonyOS network stack. Supports REST APIs, webhooks, JSON endpoints, and raw text downloads. Bypasses shell environment limits where curl/wget are unavailable.',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    let url = ((args['url'] as string) ?? '').trim();
    if (!url) {
      return {
        toolCallId: toolCallId,
        toolName: 'fetch',
        output: '',
        error: 'Missing required argument: url',
        isError: true
      };
    }

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://' + url;
    }

    const rawMethod = ((args['method'] as string) ?? 'GET').toUpperCase().trim();
    let method = http.RequestMethod.GET;
    switch (rawMethod) {
      case 'POST':
        method = http.RequestMethod.POST;
        break;
      case 'PUT':
        method = http.RequestMethod.PUT;
        break;
      case 'DELETE':
        method = http.RequestMethod.DELETE;
        break;
      case 'HEAD':
        method = http.RequestMethod.HEAD;
        break;
      case 'OPTIONS':
        method = http.RequestMethod.OPTIONS;
        break;
      default:
        method = http.RequestMethod.GET;
        break;
    }

    const timeout = typeof args['timeoutMs'] === 'number' ? (args['timeoutMs'] as number) : 15000;
    const headerMap: Record<string, string> = {
      'User-Agent': 'HarmonyOS-PiAgent/1.0 (Linux; HarmonyOS NEXT)',
      'Accept': '*/*'
    };

    if (rawMethod === 'PATCH') {
      method = http.RequestMethod.POST;
      headerMap['X-HTTP-Method-Override'] = 'PATCH';
    }

    // Parse custom headers if provided
    const rawHeaders = args['headers'] as Object | undefined;
    if (rawHeaders) {
      if (typeof rawHeaders === 'string') {
        const strHeaders = rawHeaders as string;
        if (strHeaders.trim().length > 0) {
          try {
            const parsed = JSON.parse(strHeaders) as Record<string, Object>;
            const keys = Object.keys(parsed);
            for (let i = 0; i < keys.length; i++) {
              headerMap[keys[i]] = String(parsed[keys[i]]);
            }
          } catch (e) {
            // ignore malformed custom headers
          }
        }
      } else if (typeof rawHeaders === 'object') {
        const rec = rawHeaders as Record<string, Object>;
        const keys = Object.keys(rec);
        for (let i = 0; i < keys.length; i++) {
          headerMap[keys[i]] = String(rec[keys[i]]);
        }
      }
    }

    // Body
    let bodyData: string | undefined = undefined;
    if (args['body'] !== undefined && args['body'] !== null) {
      if (typeof args['body'] === 'string') {
        bodyData = args['body'] as string;
      } else {
        bodyData = JSON.stringify(args['body']);
      }
    }

    const startTime = Date.now();
    const req = http.createHttp();

    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: headerMap,
        extraData: bodyData,
        readTimeout: timeout,
        connectTimeout: timeout
      };

      const res = await req.request(url, options);
      const durationMs = Date.now() - startTime;
      const statusCode = res.responseCode ?? 200;

      let resBody = '';
      if (typeof res.result === 'string') {
        resBody = res.result;
      } else if (res.result) {
        resBody = JSON.stringify(res.result);
      }

      // Format response headers summary
      let headerSummary = '';
      if (res.header) {
        const resHeader = res.header as Record<string, Object>;
        const contentType = resHeader['content-type'] ?? resHeader['Content-Type'];
        if (contentType) {
          headerSummary += `Content-Type: ${contentType}\n`;
        }
        const contentLength = resHeader['content-length'] ?? resHeader['Content-Length'];
        if (contentLength) {
          headerSummary += `Content-Length: ${contentLength}\n`;
        }
      }

      // Truncate excessively large response body to avoid overflowing LLM context
      let truncated = false;
      if (resBody.length > 12000) {
        resBody = resBody.substring(0, 12000);
        truncated = true;
      }

      let output = `HTTP ${statusCode} (${durationMs}ms)\n${headerSummary}\n${resBody}`;
      if (truncated) {
        output += `\n... [Response body truncated at 12000 characters]`;
      }

      return {
        toolCallId: toolCallId,
        toolName: 'fetch',
        output: output.trim(),
        error: statusCode >= 400 ? `HTTP Status ${statusCode}` : undefined,
        isError: statusCode >= 400
      };
    } catch (err) {
      const durationMs = Date.now() - startTime;
      hilog.error(DOMAIN, TAG, 'Fetch error for %{public}s: %{public}s', url, JSON.stringify(err));
      return {
        toolCallId: toolCallId,
        toolName: 'fetch',
        output: '',
        error: `Network request failed after ${durationMs}ms: ${err}`,
        isError: true
      };
    } finally {
      try {
        req.destroy();
      } catch (e) {
        // ignore
      }
    }
  }
}
