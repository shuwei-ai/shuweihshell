/*
 * Chrome DevTools Protocol (CDP) Client for ArkWeb on HarmonyOS.
 * Communicates with ArkWeb's Chromium DevTools server over local TCP Loopback (ws://127.0.0.1:port).
 */
import http from '@ohos.net.http';
import webSocket from '@ohos.net.webSocket';
import hilog from '@ohos.hilog';

const DOMAIN: number = 0x0001;
const TAG: string = 'CdpClient';

export interface CdpTarget {
  id: string;
  title: string;
  type: string;
  url: string;
  webSocketDebuggerUrl?: string;
}

export interface CdpResponse {
  id?: number;
  result?: Record<string, Object>;
  error?: Record<string, Object>;
  method?: string;
  params?: Record<string, Object>;
}

export class CdpClient {
  private ws: webSocket.WebSocket | null = null;
  private isConnected: boolean = false;
  private currentWsUrl: string = '';
  private nextRequestId: number = 1;
  private pendingRequests: Map<number, (resp: CdpResponse) => void> = new Map();
  private eventHandlers: Map<string, Array<(params: Record<string, Object>) => void>> = new Map();

  public isReady(): boolean {
    return this.isConnected && this.ws !== null;
  }

  public getWsUrl(): string {
    return this.currentWsUrl;
  }

  /**
   * Discover available DevTools targets from http://127.0.0.1:{port}/json/list
   */
  public async discoverTargets(port: number = 9222): Promise<CdpTarget[]> {
    const req = http.createHttp();
    try {
      const res = await req.request(`http://127.0.0.1:${port}/json/list`, {
        method: http.RequestMethod.GET,
        connectTimeout: 2000,
        readTimeout: 2000
      });

      if (res.responseCode === 200 && res.result) {
        const raw = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
        const list = JSON.parse(raw) as Array<Record<string, Object>>;
        const targets: CdpTarget[] = [];
        for (let i = 0; i < list.length; i++) {
          const item = list[i];
          targets.push({
            id: (item['id'] as string) ?? '',
            title: (item['title'] as string) ?? '',
            type: (item['type'] as string) ?? '',
            url: (item['url'] as string) ?? '',
            webSocketDebuggerUrl: item['webSocketDebuggerUrl'] as string | undefined
          });
        }
        return targets;
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'discoverTargets failed on port %{public}d: %{public}s', port, JSON.stringify(err));
    } finally {
      req.destroy();
    }
    return [];
  }

  /**
   * Connect to the first page target on the given DevTools port
   */
  public async connect(port: number = 9222): Promise<boolean> {
    if (this.isConnected) {
      return true;
    }

    const targets = await this.discoverTargets(port);
    let pageTarget: CdpTarget | undefined = undefined;
    for (let i = 0; i < targets.length; i++) {
      if (targets[i].type === 'page' && targets[i].webSocketDebuggerUrl) {
        pageTarget = targets[i];
        break;
      }
    }

    if (!pageTarget && targets.length > 0 && targets[0].webSocketDebuggerUrl) {
      pageTarget = targets[0];
    }

    if (!pageTarget || !pageTarget.webSocketDebuggerUrl) {
      hilog.warn(DOMAIN, TAG, 'no connectable CDP target found on port %{public}d', port);
      return false;
    }

    let wsUrl = pageTarget.webSocketDebuggerUrl;
    // Replace localhost with 127.0.0.1 to avoid local DNS resolve hiccups
    if (wsUrl.includes('localhost:')) {
      wsUrl = wsUrl.replace('localhost:', '127.0.0.1:');
    }

    return await this.connectWs(wsUrl);
  }

  private connectWs(url: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      try {
        if (this.ws) {
          try {
            this.ws.close();
          } catch (e) {
            // ignore
          }
        }

        this.currentWsUrl = url;
        this.ws = webSocket.createWebSocket();

        let resolved = false;
        const timeoutTimer = setTimeout(() => {
          if (!resolved) {
            resolved = true;
            hilog.warn(DOMAIN, TAG, 'WebSocket connection timeout to %{public}s', url);
            resolve(false);
          }
        }, 5000);

        this.ws.on('open', (err, value) => {
          if (!resolved) {
            resolved = true;
            clearTimeout(timeoutTimer);
            this.isConnected = true;
            hilog.info(DOMAIN, TAG, 'CDP WebSocket connected: %{public}s', url);
            // Enable default domains
            this.initDomains();
            resolve(true);
          }
        });

        this.ws.on('message', (err, value) => {
          this.handleMessage(value);
        });

        this.ws.on('error', (err) => {
          hilog.error(DOMAIN, TAG, 'CDP WebSocket error: %{public}s', JSON.stringify(err));
          if (!resolved) {
            resolved = true;
            clearTimeout(timeoutTimer);
            resolve(false);
          }
        });

        this.ws.on('close', (err, value) => {
          hilog.info(DOMAIN, TAG, 'CDP WebSocket closed');
          this.isConnected = false;
          this.ws = null;
        });

        this.ws.connect(url);
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'connectWs exception: %{public}s', JSON.stringify(err));
        resolve(false);
      }
    });
  }

  private async initDomains(): Promise<void> {
    try {
      await this.send('Page.enable');
      await this.send('Runtime.enable');
      await this.send('DOM.enable');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to enable some CDP domains: %{public}s', JSON.stringify(e));
    }
  }

  private handleMessage(data: string | ArrayBuffer): void {
    try {
      const text = typeof data === 'string' ? data : '';
      if (!text) {
        return;
      }

      const resp = JSON.parse(text) as CdpResponse;
      if (resp.id !== undefined && this.pendingRequests.has(resp.id)) {
        const handler = this.pendingRequests.get(resp.id);
        this.pendingRequests.delete(resp.id);
        if (handler) {
          handler(resp);
        }
        return;
      }

      if (resp.method) {
        const listeners = this.eventHandlers.get(resp.method);
        if (listeners && listeners.length > 0) {
          for (let i = 0; i < listeners.length; i++) {
            listeners[i](resp.params ?? {});
          }
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'handleMessage parse error: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * Send JSON-RPC CDP command
   */
  public send(method: string, params?: Record<string, Object>, timeoutMs: number = 8000): Promise<CdpResponse> {
    return new Promise<CdpResponse>((resolve, reject) => {
      if (!this.ws || !this.isConnected) {
        reject(new Error('CDP WebSocket is not connected'));
        return;
      }

      const id = this.nextRequestId++;
      const req: Record<string, Object> = {
        'id': id,
        'method': method
      };
      if (params) {
        req['params'] = params;
      }

      let timeoutTimer: number = -1;
      const callback = (resp: CdpResponse) => {
        if (timeoutTimer !== -1) {
          clearTimeout(timeoutTimer);
        }
        if (resp.error) {
          reject(new Error(`CDP Error (${method}): ${JSON.stringify(resp.error)}`));
        } else {
          resolve(resp);
        }
      };

      this.pendingRequests.set(id, callback);

      timeoutTimer = setTimeout(() => {
        if (this.pendingRequests.has(id)) {
          this.pendingRequests.delete(id);
          reject(new Error(`CDP command timeout after ${timeoutMs}ms: ${method}`));
        }
      }, timeoutMs);

      this.ws.send(JSON.stringify(req), (err) => {
        if (err) {
          this.pendingRequests.delete(id);
          if (timeoutTimer !== -1) {
            clearTimeout(timeoutTimer);
          }
          reject(new Error(`CDP send failed: ${JSON.stringify(err)}`));
        }
      });
    });
  }

  public on(method: string, handler: (params: Record<string, Object>) => void): void {
    if (!this.eventHandlers.has(method)) {
      this.eventHandlers.set(method, []);
    }
    this.eventHandlers.get(method)?.push(handler);
  }

  /**
   * Evaluate a JavaScript expression inside the page context
   */
  public async evaluate(expression: string, awaitPromise: boolean = true): Promise<Object | undefined> {
    const params: Record<string, Object> = {
      'expression': expression,
      'awaitPromise': awaitPromise,
      'returnByValue': true
    };
    const resp = await this.send('Runtime.evaluate', params);
    const resultObj = resp.result as Record<string, Object> | undefined;
    if (resultObj) {
      const remoteObj = resultObj['result'] as Record<string, Object> | undefined;
      if (remoteObj && remoteObj['value'] !== undefined) {
        return remoteObj['value'];
      }
      if (resultObj['exceptionDetails']) {
        throw new Error(`JS Exception: ${JSON.stringify(resultObj['exceptionDetails'])}`);
      }
    }
    return undefined;
  }

  /**
   * Dispatch mouse click (down + up) at viewport coordinates
   */
  public async dispatchClick(x: number, y: number): Promise<void> {
    const downParams: Record<string, Object> = {
      'type': 'mousePressed',
      'x': x,
      'y': y,
      'button': 'left',
      'clickCount': 1
    };
    await this.send('Input.dispatchMouseEvent', downParams);

    const upParams: Record<string, Object> = {
      'type': 'mouseReleased',
      'x': x,
      'y': y,
      'button': 'left',
      'clickCount': 1
    };
    await this.send('Input.dispatchMouseEvent', upParams);
  }

  /**
   * Insert text directly into the focused element
   */
  public async insertText(text: string): Promise<void> {
    const params: Record<string, Object> = {
      'text': text
    };
    await this.send('Input.insertText', params);
  }

  /**
   * Capture screenshot as base64 JPEG
   */
  public async captureScreenshot(quality: number = 80): Promise<string> {
    const params: Record<string, Object> = {
      'format': 'jpeg',
      'quality': quality
    };
    const resp = await this.send('Page.captureScreenshot', params);
    const res = resp.result as Record<string, Object> | undefined;
    if (res && typeof res['data'] === 'string') {
      return res['data'] as string;
    }
    return '';
  }

  public close(): void {
    if (this.ws) {
      try {
        this.ws.close();
      } catch (e) {
        // ignore
      }
      this.ws = null;
    }
    this.isConnected = false;
    this.pendingRequests.clear();
    this.eventHandlers.clear();
  }
}
