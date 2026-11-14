/*
 * Central Browser Manager for HarmonyOS Pi-Agent.
 * Holds the WebviewController, manages CDP Loopback connection, and provides high-level browser actions.
 */
import webview from '@ohos.web.webview';
import hilog from '@ohos.hilog';
import promptAction from '@ohos.promptAction';
import { CdpClient } from './CdpClient';
import { WechatStyler } from './WechatStyler';

const DOMAIN: number = 0x0001;
const TAG: string = 'BrowserManager';

export interface InteractiveElement {
  idx: number;
  tag: string;
  type?: string;
  label?: string;
  href?: string;
}

export interface SnapshotData {
  title: string;
  url: string;
  text?: string;
  elements?: InteractiveElement[];
  error?: string;
}

export interface NavigateResult {
  url: string;
  title: string;
  durationMs: number;
}

export interface ActionResult {
  success: boolean;
  message: string;
}

export interface ClickOptions {
  selector?: string;
  index?: number;
  x?: number;
  y?: number;
}

export interface TypeOptions {
  selector?: string;
  index?: number;
  text: string;
}

export interface WechatArticleParams {
  title: string;
  content: string; // Markdown or HTML
  author?: string;
  summary?: string;
  themeColor?: string;
}

export interface WechatPublishResult {
  success: boolean;
  status: 'published' | 'need_login' | 'error';
  message: string;
  draftTitle?: string;
  token?: string;
}

export class BrowserManager {
  private static instance: BrowserManager | null = null;

  public controller: webview.WebviewController = new webview.WebviewController();
  public cdpClient: CdpClient = new CdpClient();

  public currentUrl: string = 'https://developer.huawei.com';
  public currentTitle: string = 'HarmonyOS Developer';
  public isLoading: boolean = false;
  public loadProgress: number = 0;
  public canGoBack: boolean = false;
  public canGoForward: boolean = false;
  public cdpPort: number = 9222;
  public cdpConnected: boolean = false;
  public isControllerAttached: boolean = false;

  private pageLoadDeferred: ((ok: boolean) => void) | null = null;
  private isInitialized: boolean = false;
  private controllerAttachedResolvers: Array<() => void> = [];

  public static getInstance(): BrowserManager {
    if (!BrowserManager.instance) {
      BrowserManager.instance = new BrowserManager();
    }
    return BrowserManager.instance;
  }

  public notifyControllerAttached(): void {
    if (!this.isControllerAttached) {
      hilog.info(DOMAIN, TAG, 'WebviewController successfully associated with Web component');
      this.isControllerAttached = true;
    }
    for (const resolve of this.controllerAttachedResolvers) {
      try {
        resolve();
      } catch (e) {
        // ignore
      }
    }
    this.controllerAttachedResolvers = [];
  }

  public async ensureControllerAttached(timeoutMs: number = 6000): Promise<boolean> {
    if (this.isControllerAttached) {
      return true;
    }
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        hilog.warn(DOMAIN, TAG, 'Timed out waiting for WebviewController to associate with Web component (%{public}dms)', timeoutMs);
        resolve(this.isControllerAttached);
      }, timeoutMs);

      this.controllerAttachedResolvers.push(() => {
        clearTimeout(timer);
        resolve(true);
      });
    });
  }

  /**
   * Enable Web debugging and listen on port 9222
   */
  public init(port: number = 9222): void {
    if (this.isInitialized) {
      return;
    }
    this.cdpPort = port;
    try {
      webview.WebviewController.setWebDebuggingAccess(true, this.cdpPort);
      hilog.info(DOMAIN, TAG, 'setWebDebuggingAccess(true, %{public}d) enabled', this.cdpPort);
      this.isInitialized = true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWebDebuggingAccess failed: %{public}s, retrying default...', JSON.stringify(err));
      try {
        webview.WebviewController.setWebDebuggingAccess(true);
        this.isInitialized = true;
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'Fallback setWebDebuggingAccess failed: %{public}s', JSON.stringify(e));
      }
    }
  }

  /**
   * Attempt to establish the CDP WebSocket connection
   */
  public async ensureCdpConnected(): Promise<boolean> {
    if (this.cdpClient.isReady()) {
      this.cdpConnected = true;
      return true;
    }
    try {
      const ok = await this.cdpClient.connect(this.cdpPort);
      this.cdpConnected = ok;
      if (ok) {
        try {
          await this.cdpClient.send('Emulation.clearDeviceMetricsOverride', {});
          await this.cdpClient.send('Emulation.setTouchEmulationEnabled', { 'enabled': true });
        } catch (e) {
          // ignore
        }
      }
      return ok;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ensureCdpConnected error: %{public}s', JSON.stringify(err));
      this.cdpConnected = false;
      return false;
    }
  }

  /**
   * Called by Web component onPageBegin
   */
  public onPageBegin(url: string): void {
    this.isLoading = true;
    this.currentUrl = url;
  }

  /**
   * Called by Web component onPageEnd
   */
  public onPageEnd(url: string): void {
    this.isLoading = false;
    this.currentUrl = url;
    try {
      this.currentTitle = this.controller.getTitle();
      this.canGoBack = this.controller.accessBackward();
      this.canGoForward = this.controller.accessForward();
    } catch (err) {
      // ignore
    }

    // Try auto-connecting CDP after page initial render
    if (!this.cdpConnected) {
      this.ensureCdpConnected();
    }

    if (this.pageLoadDeferred) {
      const cb = this.pageLoadDeferred;
      this.pageLoadDeferred = null;
      cb(true);
    }
  }

  /**
   * Called by Web component onErrorReceive
   */
  public onError(err: Object): void {
    this.isLoading = false;
    if (this.pageLoadDeferred) {
      const cb = this.pageLoadDeferred;
      this.pageLoadDeferred = null;
      cb(false);
    }
  }

  /**
   * Navigate to a URL and wait for page load
   */
  public async navigate(url: string, timeoutMs: number = 15000): Promise<NavigateResult> {
    const attached = await this.ensureControllerAttached(6000);
    if (!attached) {
      throw new Error('WebviewController is not associated with Web component');
    }

    let target = url.trim();
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      target = 'https://' + target;
    }

    const start = Date.now();
    this.isLoading = true;

    const loadPromise = new Promise<boolean>((resolve) => {
      this.pageLoadDeferred = resolve;
      const timer = setTimeout(() => {
        if (this.pageLoadDeferred) {
          this.pageLoadDeferred = null;
          resolve(true); // timed out, but resolve to allow reading whatever loaded
        }
      }, timeoutMs);
    });

    try {
      this.controller.loadUrl(target);
    } catch (err) {
      this.isLoading = false;
      throw new Error(`Failed to load URL ${target}: ${err}`);
    }

    await loadPromise;
    this.isLoading = false;

    // Small delay to let initial JS / DOM hydration settle
    await new Promise<void>((r) => setTimeout(r, 600));

    let title = '';
    try {
      title = this.controller.getTitle();
    } catch (e) {
      // ignore
    }

    const res: NavigateResult = {
      url: this.currentUrl,
      title: title || this.currentTitle,
      durationMs: Date.now() - start
    };
    return res;
  }

  /**
   * Extract readable text and interactive elements
   */
  public async snapshot(mode: 'text' | 'interactive' | 'both' = 'both'): Promise<SnapshotData> {
    const script = `
      (() => {
        try {
          const getCleanText = () => {
            const clone = document.body ? document.body.cloneNode(true) : null;
            if (!clone) return '';
            const toRemove = ['script', 'style', 'noscript', 'svg', 'iframe', 'canvas', 'template'];
            toRemove.forEach(t => clone.querySelectorAll(t).forEach(e => e.remove()));
            return (clone.innerText || clone.textContent || '')
              .replace(/[ \\t]+/g, ' ')
              .replace(/\\n\\s*\\n/g, '\\n')
              .trim();
          };

          const getInteractive = () => {
            const candidates = Array.from(document.querySelectorAll('a, button, input, textarea, select, [role="button"], [onclick]'));
            const items = [];
            let idx = 1;
            for (const el of candidates) {
              const rect = el.getBoundingClientRect();
              const style = window.getComputedStyle(el);
              if (rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0') {
                let label = (el.innerText || el.getAttribute('placeholder') || el.getAttribute('aria-label') || el.getAttribute('title') || el.value || '').trim();
                if (label.length > 60) label = label.substring(0, 57) + '...';
                const tag = el.tagName.toLowerCase();
                const type = el.getAttribute('type') || '';
                const href = el.getAttribute('href') || '';
                el.setAttribute('data-pi-idx', String(idx));
                items.push({
                  idx: idx,
                  tag: tag,
                  type: type || undefined,
                  label: label || undefined,
                  href: href && !href.startsWith('javascript:') ? href : undefined
                });
                idx++;
                if (idx > 100) break;
              }
            }
            return items;
          };

          return JSON.stringify({
            title: document.title || '',
            url: window.location.href || '',
            text: getCleanText().substring(0, 10000),
            elements: getInteractive()
          });
        } catch (err) {
          return JSON.stringify({ error: String(err) });
        }
      })()
    `;

    const rawJson = await this.evaluate(script);
    try {
      const data = JSON.parse(rawJson) as SnapshotData;
      if (mode === 'text') {
        data.elements = undefined;
      } else if (mode === 'interactive') {
        data.text = undefined;
      }
      return data;
    } catch (err) {
      const fallback: SnapshotData = {
        title: this.currentTitle,
        url: this.currentUrl,
        error: `Failed to parse page snapshot: ${err}. Raw: ${rawJson}`
      };
      return fallback;
    }
  }

  /**
   * Click an element by index, selector, or (x, y) coordinates
   */
  public async click(options: ClickOptions): Promise<ActionResult> {
    if (options.x !== undefined && options.y !== undefined && this.cdpClient.isReady()) {
      await this.cdpClient.dispatchClick(options.x, options.y);
      const res: ActionResult = {
        success: true,
        message: `Clicked at coordinates (${options.x}, ${options.y}) via CDP`
      };
      return res;
    }

    let clickScript = '';
    if (options.index !== undefined) {
      clickScript = `
        (() => {
          const el = document.querySelector('[data-pi-idx="${options.index}"]');
          if (!el) return 'Element with index [${options.index}] not found';
          el.scrollIntoView({ behavior: 'instant', block: 'center' });
          el.click();
          return 'OK';
        })()
      `;
    } else if (options.selector) {
      const selEscaped = options.selector.replace(/"/g, '\\"');
      clickScript = `
        (() => {
          const el = document.querySelector("${selEscaped}");
          if (!el) return 'Element matching selector "${selEscaped}" not found';
          el.scrollIntoView({ behavior: 'instant', block: 'center' });
          el.click();
          return 'OK';
        })()
      `;
    } else {
      const errRes: ActionResult = {
        success: false,
        message: 'Must provide either index, selector, or (x, y)'
      };
      return errRes;
    }

    const res = await this.evaluate(clickScript);
    if (res.includes('OK')) {
      const okRes: ActionResult = {
        success: true,
        message: 'Click executed successfully'
      };
      return okRes;
    } else {
      const failRes: ActionResult = {
        success: false,
        message: res
      };
      return failRes;
    }
  }

  /**
   * Type text into an input element
   */
  public async type(options: TypeOptions): Promise<ActionResult> {
    const textEscaped = options.text.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
    let typeScript = '';

    if (options.index !== undefined) {
      typeScript = `
        (() => {
          const el = document.querySelector('[data-pi-idx="${options.index}"]');
          if (!el) return 'Element [${options.index}] not found';
          el.focus();
          el.value = "${textEscaped}";
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'OK';
        })()
      `;
    } else if (options.selector) {
      const selEscaped = options.selector.replace(/"/g, '\\"');
      typeScript = `
        (() => {
          const el = document.querySelector("${selEscaped}");
          if (!el) return 'Element "${selEscaped}" not found';
          el.focus();
          el.value = "${textEscaped}";
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'OK';
        })()
      `;
    } else {
      const errRes: ActionResult = {
        success: false,
        message: 'Must provide either index or selector to type into'
      };
      return errRes;
    }

    const res = await this.evaluate(typeScript);
    if (res.includes('OK')) {
      const okRes: ActionResult = {
        success: true,
        message: 'Typed into element successfully'
      };
      return okRes;
    } else {
      const failRes: ActionResult = {
        success: false,
        message: res
      };
      return failRes;
    }
  }

  /**
   * Evaluate JS inside page, using CDP if connected, otherwise fallback to WebviewController.runJavaScript
   */
  public async evaluate(script: string): Promise<string> {
    const attached = await this.ensureControllerAttached(6000);
    if (!attached) {
      throw new Error('Init error. The WebviewController must be associated with a Web component');
    }

    if (this.cdpClient.isReady()) {
      try {
        const val = await this.cdpClient.evaluate(script);
        if (typeof val === 'string') {
          return val;
        }
        return JSON.stringify(val);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'CDP evaluate error, falling back to runJavaScript: %{public}s', JSON.stringify(err));
      }
    }

    try {
      const res = await this.controller.runJavaScript(script);
      if (res && res.startsWith('"') && res.endsWith('"')) {
        try {
          return JSON.parse(res) as string;
        } catch (e) {
          return res;
        }
      }
      return res ?? '';
    } catch (err) {
      throw new Error(`JavaScript evaluation failed: ${err}`);
    }
  }

  /**
   * Clear browser cache, history, and cookies
   */
  public async clearCacheAndCookies(): Promise<void> {
    try {
      webview.WebCookieManager.clearAllCookiesSync();
      this.controller.removeCache(true);
      this.controller.clearHistory();
      hilog.info(DOMAIN, TAG, 'Browser cache and cookies cleared successfully');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to clear some browser data: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * Automates publishing an article to WeChat Official Account via ArkWeb and CDP.
   * Ported and adapted from baoyu-post-to-wechat (wechat-article.ts) for HarmonyOS NEXT.
   */
  public async publishWechatArticle(params: WechatArticleParams): Promise<WechatPublishResult> {
    const title = (params.title ?? '').trim();
    if (!title) {
      return {
        success: false,
        status: 'error',
        message: '发布失败：必须提供文章标题 (title)'
      };
    }

    if (!params.content || params.content.trim().length === 0) {
      return {
        success: false,
        status: 'error',
        message: '发布失败：必须提供文章正文 (content)'
      };
    }

    // 1. Ensure CDP connected & configure desktop environment
    await this.ensureCdpConnected();
    const desktopUa = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
    try {
      this.controller.setCustomUserAgent(desktopUa);
    } catch (e) {
      // ignore
    }

    if (this.cdpClient.isReady()) {
      try {
        // Clear any rigid metrics override so native touch scrolling and responsive layout are preserved
        await this.cdpClient.send('Emulation.clearDeviceMetricsOverride', {});
        await this.cdpClient.send('Emulation.setTouchEmulationEnabled', {
          'enabled': true
        });
        await this.cdpClient.send('Network.setUserAgentOverride', {
          'userAgent': desktopUa
        });
      } catch (e) {
        // ignore
      }
    }

    // 2. Check if currently on mp.weixin.qq.com
    if (!this.currentUrl.includes('mp.weixin.qq.com')) {
      hilog.info(DOMAIN, TAG, 'Navigating to mp.weixin.qq.com...');
      await this.navigate('https://mp.weixin.qq.com/', 15000);
      await new Promise<void>(r => setTimeout(r, 2000));
    }

    // 3. Inspect login status
    const loginStatusScript = `
      (() => {
        try {
          const href = window.location.href;
          const body = document.body ? document.body.innerText : '';
          const hasToken = href.match(/token=([0-9a-zA-Z_-]+)/);
          const isTimeout = body.includes('登录超时') || body.includes('请重新登录') || body.includes('扫码登录');
          const isHome = href.includes('/cgi-bin/home') || (href.includes('/cgi-bin/') && !!hasToken && !isTimeout);
          return JSON.stringify({
            href: href,
            isLoggedIn: isHome,
            token: hasToken ? hasToken[1] : '',
            hasQr: !!document.querySelector('.login__type__container__scan img, .login_img img, .qrcode img, #login_container img, canvas')
          });
        } catch (e) {
          return JSON.stringify({ error: String(e) });
        }
      })()
    `;

    const statusRaw = await this.evaluate(loginStatusScript);
    let statusObj: Record<string, Object> = {};
    try {
      statusObj = JSON.parse(statusRaw) as Record<string, Object>;
    } catch (e) {
      // ignore
    }

    const isLoggedIn = !!statusObj['isLoggedIn'];
    let token = (statusObj['token'] as string) ?? '';

    if (!isLoggedIn || !token) {
      try {
        promptAction.showToast({
          message: '请切换至「浏览器」页面扫码登录微信公众号',
          duration: 3500
        });
      } catch (e) {
        // ignore
      }
      return {
        success: false,
        status: 'need_login',
        message: '微信公众平台尚未登录。已为您打开公众号登录页面，请点击底部导航栏切换至「浏览器」Tab，使用微信 App 扫码登录。登录成功后再次下达发布指令即可直接保存草稿！'
      };
    }

    // 4. Navigate directly to Editor if not already in editor
    const isAlreadyEditing = this.currentUrl.includes('appmsg_edit_v2') || this.currentUrl.includes('appmsg_edit');
    if (!isAlreadyEditing) {
      const editorUrl = `https://mp.weixin.qq.com/cgi-bin/appmsg?t=media/appmsg_edit_v2&action=edit&isNew=1&type=77&createType=0&token=${token}&lang=zh_CN`;
      hilog.info(DOMAIN, TAG, 'Navigating to WeChat editor: %{public}s', editorUrl);
      await this.navigate(editorUrl, 20000);
      await new Promise<void>(r => setTimeout(r, 2500));
    }

    // 5. Wait for Editor elements (#title and .ProseMirror)
    const checkEditorLoadedScript = `
      (() => {
        const titleEl = document.querySelector('#title');
        const editor = document.querySelector('.rich_media_content .ProseMirror, .ProseMirror');
        return !!(titleEl && editor);
      })()
    `;

    let editorReady = false;
    const startWait = Date.now();
    while (Date.now() - startWait < 25000) {
      const checkRes = await this.evaluate(checkEditorLoadedScript);
      if (checkRes.includes('true')) {
        editorReady = true;
        break;
      }
      await new Promise<void>(r => setTimeout(r, 800));
    }

    if (!editorReady) {
      return {
        success: false,
        status: 'error',
        message: '微信公众号文章编辑器加载超时。请检查网络或在「浏览器」页面查看页面是否被弹窗阻挡。'
      };
    }

    // 6. Convert Markdown content to WeChat styled HTML
    const formattedHtml = WechatStyler.markdownToWechatHtml(params.content, params.themeColor);

    // 7. Fill Title, Author, Summary into page DOM
    const safeTitle = title.length > 64 ? title.substring(0, 64) : title;
    const safeAuthor = (params.author ?? '').trim();
    const safeSummary = (params.summary ?? '').trim();

    const fillMetadataScript = `
      (() => {
        try {
          // 1. Title
          const titleEl = document.querySelector('#title');
          if (titleEl) {
            titleEl.focus();
            titleEl.value = ${JSON.stringify(safeTitle)};
            titleEl.dispatchEvent(new Event('input', { bubbles: true }));
            titleEl.dispatchEvent(new Event('change', { bubbles: true }));
          }

          // 2. Author
          const authorVal = ${JSON.stringify(safeAuthor)};
          if (authorVal) {
            const authorEl = document.querySelector('#author');
            if (authorEl) {
              authorEl.focus();
              authorEl.value = authorVal;
              authorEl.dispatchEvent(new Event('input', { bubbles: true }));
              authorEl.dispatchEvent(new Event('change', { bubbles: true }));
            }
          }

          // 3. Summary / Description
          const summaryVal = ${JSON.stringify(safeSummary)};
          if (summaryVal) {
            const descEl = document.querySelector('#js_description');
            if (descEl) {
              descEl.focus();
              descEl.value = summaryVal;
              descEl.dispatchEvent(new Event('input', { bubbles: true }));
              descEl.dispatchEvent(new Event('change', { bubbles: true }));
            }
          }

          return JSON.stringify({ ok: true });
        } catch (err) {
          return JSON.stringify({ ok: false, error: String(err) });
        }
      })()
    `;
    await this.evaluate(fillMetadataScript);
    await new Promise<void>(r => setTimeout(r, 500));

    // 8. Inject formatted HTML into ProseMirror editor
    const injectHtmlScript = `
      (() => {
        try {
          const editor = document.querySelector('.rich_media_content .ProseMirror, .ProseMirror');
          if (!editor) {
            return JSON.stringify({ ok: false, error: 'ProseMirror editor container not found' });
          }

          editor.focus();
          const selection = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(editor);
          range.deleteContents();
          range.collapse(true);
          selection.removeAllRanges();
          selection.addRange(range);

          const inserted = document.execCommand('insertHTML', false, ${JSON.stringify(formattedHtml)});
          editor.dispatchEvent(new InputEvent('input', {
            bubbles: true,
            inputType: 'insertHTML',
            data: editor.innerText || ''
          }));

          return JSON.stringify({
            ok: inserted || (editor.innerText || '').trim().length > 0,
            textLength: (editor.innerText || '').trim().length
          });
        } catch (err) {
          return JSON.stringify({ ok: false, error: String(err) });
        }
      })()
    `;

    const injectRes = await this.evaluate(injectHtmlScript);
    let injectOk = false;
    try {
      const parsed = JSON.parse(injectRes) as Record<string, Object>;
      injectOk = !!parsed['ok'];
    } catch (e) {
      // ignore
    }

    if (!injectOk) {
      return {
        success: false,
        status: 'error',
        message: `向微信编辑器注入正文失败：${injectRes}`
      };
    }

    await new Promise<void>(r => setTimeout(r, 1200));

    // 9. Click Save Draft button
    const clickSaveDraftScript = `
      (() => {
        try {
          const btns = Array.from(document.querySelectorAll('button, #js_submit, .js_save_draft, .weui-desktop-btn'));
          let saveBtn = btns.find(b => {
            const txt = (b.innerText || '').trim();
            return txt === '保存为草稿' || txt === '保存草稿' || txt.includes('保存为草稿');
          });

          if (!saveBtn) {
            saveBtn = document.querySelector('#js_submit') || document.querySelector('.js_save_draft');
          }

          if (!saveBtn) {
            return JSON.stringify({ ok: false, error: 'Save draft button (#js_submit) not found' });
          }

          saveBtn.scrollIntoView({ behavior: 'instant', block: 'center' });
          saveBtn.click();
          return JSON.stringify({ ok: true });
        } catch (err) {
          return JSON.stringify({ ok: false, error: String(err) });
        }
      })()
    `;
    await this.evaluate(clickSaveDraftScript);

    // 10. Wait for save confirmation toast or appmsgid
    const pollSaveStatusScript = `
      (() => {
        try {
          const toasts = Array.from(document.querySelectorAll('.weui-desktop-toast, .weui-desktop-toast__content, .toast, .js_toast'));
          const toastTexts = toasts.map(t => (t.innerText || '').trim()).filter(Boolean);
          const hasSuccess = toastTexts.some(t => /已保存|保存成功|Saved/i.test(t));
          const hasFail = toastTexts.some(t => /保存.*失败|草稿.*失败/i.test(t));
          const href = window.location.href;
          const matchId = href.match(/appmsgid=([0-9a-zA-Z_-]+)/);

          return JSON.stringify({
            hasSuccess: hasSuccess,
            hasFail: hasFail,
            toasts: toastTexts,
            appmsgid: matchId ? matchId[1] : ''
          });
        } catch (e) {
          return JSON.stringify({ error: String(e) });
        }
      })()
    `;

    let saveSuccess = false;
    let savedAppMsgId = '';
    const pollStart = Date.now();
    while (Date.now() - pollStart < 15000) {
      const pollRaw = await this.evaluate(pollSaveStatusScript);
      try {
        const pollObj = JSON.parse(pollRaw) as Record<string, Object>;
        if (pollObj['hasSuccess'] || pollObj['appmsgid']) {
          saveSuccess = true;
          savedAppMsgId = (pollObj['appmsgid'] as string) ?? '';
          break;
        }
        if (pollObj['hasFail']) {
          const toasts = (pollObj['toasts'] as string[]) ?? [];
          return {
            success: false,
            status: 'error',
            message: `微信公众号草稿保存失败：${toasts.join('; ')}`
          };
        }
      } catch (e) {
        // ignore
      }
      await new Promise<void>(r => setTimeout(r, 600));
    }

    try {
      promptAction.showToast({
        message: '微信公众号文章已成功保存至草稿箱！',
        duration: 3000
      });
    } catch (e) {
      // ignore
    }

    return {
      success: true,
      status: 'published',
      message: `文章《${safeTitle}》已成功完成排版并保存至微信公众号草稿箱！${savedAppMsgId ? ` (草稿ID: ${savedAppMsgId})` : ''}\n您可以在微信公众平台「内容与互动 → 草稿箱」直接查看预览或群发。`,
      draftTitle: safeTitle,
      token: token
    };
  }
}
