/*
 * Browser UI View for the 3rd Tab in shuweihshell.
 * Renders the ArkWeb instance with an interactive navigation bar, progress indicator, and CDP status badge.
 */
import webview from '@ohos.web.webview';
import promptAction from '@ohos.promptAction';
import { BrowserManager } from './BrowserManager';

@Component
export struct BrowserView {
  onSwitchToAgent?: () => void = undefined;
  @State private urlInput: string = 'https://developer.huawei.com';
  @State private pageTitle: string = 'HarmonyOS Developer';
  @State private isLoading: boolean = false;
  @State private progressValue: number = 0;
  @State private canGoBack: boolean = false;
  @State private canGoForward: boolean = false;
  @State private cdpConnected: boolean = false;

  private browserManager: BrowserManager = BrowserManager.getInstance();

  aboutToAppear(): void {
    this.browserManager.init(9222);
    this.urlInput = this.browserManager.currentUrl;
    this.pageTitle = this.browserManager.currentTitle;
    this.cdpConnected = this.browserManager.cdpConnected;

    // Check CDP connection
    this.checkCdpConnection();
  }

  private async checkCdpConnection(): Promise<void> {
    const ok = await this.browserManager.ensureCdpConnected();
    this.cdpConnected = ok;
  }

  private loadUrl(url: string): void {
    let target = url.trim();
    if (!target) return;
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      target = 'https://' + target;
    }
    this.urlInput = target;
    try {
      this.browserManager.controller.loadUrl(target);
    } catch (err) {
      promptAction.showToast({ message: `加载失败: ${err}`, duration: 2500 });
    }
  }

  build() {
    Column() {
      // 1. Navigation Toolbar
      Row({ space: 6 }) {
        Button('◀', { type: ButtonType.Normal })
          .fontSize(12)
          .height(28)
          .width(28)
          .padding(0)
          .borderRadius(6)
          .backgroundColor(this.canGoBack ? '#f1f5f9' : '#f8fafc')
          .fontColor(this.canGoBack ? '#0f172a' : '#cbd5e1')
          .enabled(this.canGoBack)
          .onClick(() => {
            try {
              if (this.browserManager.controller.accessBackward()) {
                this.browserManager.controller.backward();
              }
            } catch (e) {
              // ignore
            }
          })

        Button('▶', { type: ButtonType.Normal })
          .fontSize(12)
          .height(28)
          .width(28)
          .padding(0)
          .borderRadius(6)
          .backgroundColor(this.canGoForward ? '#f1f5f9' : '#f8fafc')
          .fontColor(this.canGoForward ? '#0f172a' : '#cbd5e1')
          .enabled(this.canGoForward)
          .onClick(() => {
            try {
              if (this.browserManager.controller.accessForward()) {
                this.browserManager.controller.forward();
              }
            } catch (e) {
              // ignore
            }
          })

        Button('↻', { type: ButtonType.Normal })
          .fontSize(13)
          .height(28)
          .width(28)
          .padding(0)
          .borderRadius(6)
          .backgroundColor('#f1f5f9')
          .fontColor('#0284c7')
          .onClick(() => {
            try {
              this.browserManager.controller.refresh();
            } catch (e) {
              // ignore
            }
          })

        TextInput({ text: this.urlInput, placeholder: '输入网址或搜索内容' })
          .height(30)
          .layoutWeight(1)
          .fontSize(12)
          .backgroundColor('#f8fafc')
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 0, bottom: 0 })
          .border({ width: 1, color: '#e2e8f0' })
          .onChange((val: string) => {
            this.urlInput = val;
          })
          .onSubmit(() => {
            this.loadUrl(this.urlInput);
          })

        Button('前往', { type: ButtonType.Normal })
          .fontSize(11)
          .height(28)
          .padding({ left: 10, right: 10, top: 0, bottom: 0 })
          .backgroundColor('#0284c7')
          .fontColor('#ffffff')
          .borderRadius(6)
          .onClick(() => {
            this.loadUrl(this.urlInput);
          })

        if (this.onSwitchToAgent !== undefined) {
          Button('🤖 Agent', { type: ButtonType.Normal })
            .fontSize(11)
            .height(28)
            .padding({ left: 8, right: 8, top: 0, bottom: 0 })
            .backgroundColor('#f1f5f9')
            .fontColor('#0284c7')
            .borderRadius(6)
            .onClick(() => {
              if (this.onSwitchToAgent) {
                this.onSwitchToAgent();
              }
            })
        }
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor('#ffffff')
      .border({ width: { bottom: 1 }, color: '#e2e8f0' })

      // 2. Loading Progress Bar
      if (this.isLoading) {
        Progress({ value: this.progressValue, total: 100, type: ProgressType.Linear })
          .color('#0284c7')
          .height(2)
          .width('100%')
      }

      // 3. Web Component Viewport
      Web({ src: this.browserManager.currentUrl, controller: this.browserManager.controller })
        .onControllerAttached(() => {
          this.browserManager.notifyControllerAttached();
          this.checkCdpConnection();
        })
        .onAppear(() => {
          this.browserManager.notifyControllerAttached();
        })
        .userAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36')
        .domStorageAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .javaScriptAccess(true)
        .onlineImageAccess(true)
        .databaseAccess(true)
        .multiWindowAccess(true)
        .mixedMode(MixedMode.All)
        .zoomAccess(true)
        .overviewModeAccess(true)
        .metaViewport(true)
        .horizontalScrollBarAccess(true)
        .verticalScrollBarAccess(true)
        .overScrollMode(OverScrollMode.ALWAYS)
        .nestedScroll({
          scrollForward: NestedScrollMode.SELF_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
        .width('100%')
        .layoutWeight(1)
        .onWindowNew((event) => {
          if (event && event.handler) {
            // Prevent ArkWeb from delegating target="_blank" or window.open to external system browser!
            if (event.targetUrl && event.targetUrl.trim().length > 0 && event.targetUrl !== 'about:blank') {
              this.urlInput = event.targetUrl;
            }
            try {
              // Direct all new window requests into our built-in controller
              event.handler.setWebController(this.browserManager.controller);
            } catch (e) {
              // ignore
            }
          }
        })
        .onPageBegin((event) => {
          if (event) {
            this.isLoading = true;
            this.urlInput = event.url;
            this.browserManager.onPageBegin(event.url);
          }
        })
        .onProgressChange((event) => {
          if (event) {
            this.progressValue = event.newProgress;
            if (event.newProgress >= 100) {
              this.isLoading = false;
            }
          }
        })
        .onTitleReceive((event) => {
          if (event && event.title) {
            this.pageTitle = event.title;
            this.browserManager.currentTitle = event.title;
          }
        })
        .onPageEnd((event) => {
          if (event) {
            this.isLoading = false;
            this.urlInput = event.url;
            this.browserManager.onPageEnd(event.url);
            try {
              this.canGoBack = this.browserManager.controller.accessBackward();
              this.canGoForward = this.browserManager.controller.accessForward();
              this.pageTitle = this.browserManager.controller.getTitle();
            } catch (e) {
              // ignore
            }

            // Inject anti-popup & touch-scroll script: ensures smooth multi-directional scrolling and pinch-zoom
            try {
              const antiPopupScript = `
                (() => {
                  try {
                    window.open = function(url) {
                      if (url && typeof url === 'string' && url !== 'about:blank') {
                        window.location.href = url;
                      }
                      return window;
                    };
                    document.addEventListener('click', function(e) {
                      var el = e.target;
                      while (el && el.tagName !== 'A' && el !== document.body) {
                        el = el.parentElement;
                      }
                      if (el && el.tagName === 'A' && el.getAttribute('target') === '_blank') {
                        el.removeAttribute('target');
                      }
                    }, true);

                    // Ensure document root allows full touch scrolling in X & Y directions
                    if (!document.getElementById('piha_touch_scroll_style')) {
                      var st = document.createElement('style');
                      st.id = 'piha_touch_scroll_style';
                      st.textContent = 'html, body { overflow-x: auto !important; overflow-y: auto !important; -webkit-overflow-scrolling: touch !important; touch-action: pan-x pan-y pinch-zoom !important; }';
                      document.head.appendChild(st);
                    }
                  } catch(e) {}
                })()
              `;
              this.browserManager.controller.runJavaScript(antiPopupScript);
            } catch (err) {
              // ignore
            }

            this.checkCdpConnection();
          }
        })
        .onErrorReceive((event) => {
          if (event) {
            this.isLoading = false;
            this.browserManager.onError(event);
          }
        })

      // 4. Bottom Status & CDP Bar
      Row({ space: 8 }) {
        Text(this.pageTitle ? this.pageTitle : '准备就绪')
          .fontSize(11)
          .fontColor('#64748b')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Button('清缓存', { type: ButtonType.Normal })
          .fontSize(10)
          .height(22)
          .padding({ left: 6, right: 6, top: 0, bottom: 0 })
          .backgroundColor('#f1f5f9')
          .fontColor('#64748b')
          .borderRadius(4)
          .onClick(async () => {
            await this.browserManager.clearCacheAndCookies();
            promptAction.showToast({ message: '浏览器缓存与 Cookie 已清空', duration: 2000 });
          })

        Text(this.cdpConnected ? '● CDP 9222' : '○ CDP 未连')
          .fontSize(10)
          .fontColor(this.cdpConnected ? '#10b981' : '#f59e0b')
          .backgroundColor(this.cdpConnected ? '#ecfdf5' : '#fef3c7')
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .borderRadius(4)
          .onClick(() => {
            this.checkCdpConnection();
            promptAction.showToast({
              message: this.cdpConnected ? 'CDP 协议连接正常 (TCP 127.0.0.1:9222)' : '正在尝试重连 CDP 调试端点...',
              duration: 2000
            });
          })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 4, bottom: 6 })
      .backgroundColor('#f8fafc')
      .border({ width: { top: 1 }, color: '#e2e8f0' })
    }
    .width('100%')
    .height('100%')
  }
}
