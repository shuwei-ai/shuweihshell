/*
 * FloatWindowManager: Manages the system-level native floating window (WindowType.TYPE_FLOAT).
 * Enables the Pi Agent to float above all other apps, display live reasoning and tool execution,
 * and provide continuous control when the user switches to background or other applications.
 */
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import display from '@ohos.display';
import hilog from '@ohos.hilog';
import promptAction from '@ohos.promptAction';
import { BridgeController } from '../common/BridgeController';

const DOMAIN: number = 0x3201;
const TAG: string = 'FloatWinMgr';

export class FloatWindowManager {
  private static instance: FloatWindowManager = new FloatWindowManager();

  private context: common.UIAbilityContext | null = null;
  private floatWindow: window.Window | null = null;
  private isShowing: boolean = false;
  private isCompact: boolean = false;
  private isAppForeground: boolean = true;

  private currentX: number = 40;
  private currentY: number = 180;
  private currentWidth: number = 900;
  private currentHeight: number = 700;

  static getInstance(): FloatWindowManager {
    return FloatWindowManager.instance;
  }

  init(context: common.UIAbilityContext): void {
    this.context = context;
    this.isAppForeground = true;
    AppStorage.setOrCreate('floatWindowActive', false);
    AppStorage.setOrCreate('floatWindowCompact', false);
    if (AppStorage.get<boolean>('autoFloatEnabled') === undefined) {
      AppStorage.setOrCreate('autoFloatEnabled', true);
    }

    // Try to ensure SYSTEM_FLOAT_WINDOW permission via shell bridge in background
    this.ensurePermissionSilently();
  }

  /**
   * Auto-grants ohos.permission.SYSTEM_FLOAT_WINDOW via shell bridge if token ID is known.
   */
  async ensurePermissionSilently(): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const tokenId = this.context.applicationInfo.accessTokenId;
      if (tokenId && tokenId > 0) {
        await BridgeController.getInstance().exec(`atm perm -g -i ${tokenId} -p ohos.permission.SYSTEM_FLOAT_WINDOW`);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ensurePermissionSilently failed: %{public}s', JSON.stringify(err));
    }
  }

  isWindowShowing(): boolean {
    return this.isShowing && this.floatWindow !== null;
  }

  async showFloatWindow(compact: boolean = false): Promise<void> {
    if (!this.context) {
      hilog.warn(DOMAIN, TAG, 'cannot show float window: context is null');
      return;
    }

    if (this.floatWindow && this.isShowing) {
      if (this.isCompact !== compact) {
        await this.setCompactMode(compact);
      }
      return;
    }

    try {
      // Ensure permission first
      await this.ensurePermissionSilently();

      const config: window.Configuration = {
        name: 'agent_float_window',
        windowType: window.WindowType.TYPE_FLOAT,
        ctx: this.context
      };

      this.floatWindow = await window.createWindow(config);

      // Load float panel page
      await this.floatWindow.loadContent('pages/FloatPanel');
      await this.floatWindow.setWindowBackgroundColor('#00000000');

      // Calculate dimensions based on screen display
      const disp = display.getDefaultDisplaySync();
      const density = disp.densityPixels || 3.0;

      this.isCompact = compact;
      if (compact) {
        this.currentWidth = Math.floor(220 * density);
        this.currentHeight = Math.floor(54 * density);
      } else {
        this.currentWidth = Math.min(Math.floor(disp.width * 0.94), Math.floor(380 * density));
        this.currentHeight = Math.floor(300 * density);
      }

      this.currentX = Math.max(20, Math.floor((disp.width - this.currentWidth) / 2));
      this.currentY = Math.floor(90 * density);

      await this.floatWindow.resize(this.currentWidth, this.currentHeight);
      await this.floatWindow.moveWindowTo(this.currentX, this.currentY);
      await this.floatWindow.showWindow();

      this.isShowing = true;
      AppStorage.setOrCreate('floatWindowActive', true);
      AppStorage.setOrCreate('floatWindowCompact', this.isCompact);
      hilog.info(DOMAIN, TAG, 'Float window displayed successfully at (%{public}d, %{public}d)', this.currentX, this.currentY);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'TYPE_FLOAT creation returned code %{public}s; float overlay not supported on current system', JSON.stringify(err));
      this.isShowing = false;
      this.floatWindow = null;
      AppStorage.setOrCreate('floatWindowActive', false);
    }
  }

  /**
   * Prompts the user with HarmonyOS standard multi-window / split-screen guidance.
   * Avoids fragile touch injection gestures that can accidentally trigger Home/Exit.
   */
  async triggerSystemFloatingGesture(): Promise<void> {
    promptAction.showToast({
      message: '请从屏幕边缘向内轻扫停顿呼出智慧多窗侧栏，拖出应用开启上下分屏',
      duration: 3500
    });
  }

  async hideFloatWindow(): Promise<void> {
    if (!this.floatWindow) {
      this.isShowing = false;
      AppStorage.setOrCreate('floatWindowActive', false);
      return;
    }

    try {
      await this.floatWindow.destroyWindow();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to destroy float window: %{public}s', JSON.stringify(err));
    } finally {
      this.floatWindow = null;
      this.isShowing = false;
      AppStorage.setOrCreate('floatWindowActive', false);
    }
  }

  async toggleFloatWindow(): Promise<void> {
    if (this.isWindowShowing()) {
      await this.hideFloatWindow();
      return;
    }

    const isFloating = AppStorage.get<boolean>('isFloatingMode') ?? false;
    if (isFloating) {
      const mainWindow = AppStorage.get<window.Window>('mainWindow');
      if (mainWindow) {
        try {
          await mainWindow.maximize();
          AppStorage.setOrCreate('isFloatingMode', false);
          return;
        } catch (e) {
          // ignore
        }
      }
    }

    await this.showFloatWindow(false);
  }

  async setCompactMode(compact: boolean): Promise<void> {
    this.isCompact = compact;
    AppStorage.setOrCreate('floatWindowCompact', compact);

    if (!this.floatWindow) {
      return;
    }

    try {
      const disp = display.getDefaultDisplaySync();
      const density = disp.densityPixels || 3.0;

      if (compact) {
        this.currentWidth = Math.floor(220 * density);
        this.currentHeight = Math.floor(54 * density);
      } else {
        this.currentWidth = Math.min(Math.floor(disp.width * 0.94), Math.floor(380 * density));
        this.currentHeight = Math.floor(300 * density);
      }

      await this.floatWindow.resize(this.currentWidth, this.currentHeight);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to resize float window: %{public}s', JSON.stringify(err));
    }
  }

  async moveWindowBy(dx: number, dy: number): Promise<void> {
    if (!this.floatWindow) {
      return;
    }

    try {
      const disp = display.getDefaultDisplaySync();
      const maxX = Math.max(0, disp.width - this.currentWidth);
      const maxY = Math.max(0, disp.height - this.currentHeight);

      this.currentX = Math.max(0, Math.min(this.currentX + dx, maxX));
      this.currentY = Math.max(0, Math.min(this.currentY + dy, maxY));

      await this.floatWindow.moveWindowTo(Math.round(this.currentX), Math.round(this.currentY));
    } catch (err) {
      // ignore rapid drag move errors
    }
  }

  /**
   * Invoked when EntryAbility is backgrounded.
   * If Agent is actively running a task AND autoFloat is explicitly enabled by user,
   * try to display the float window.
   */
  async onAppBackground(): Promise<void> {
    this.isAppForeground = false;
    const isRunning = AppStorage.get<boolean>('agentIsRunning') ?? false;
    const autoFloat = AppStorage.get<boolean>('autoFloatEnabled') ?? false;

    if (!isRunning || !autoFloat) {
      hilog.info(DOMAIN, TAG, 'App backgrounded: no active agent task or autoFloat disabled, ignoring.');
      return;
    }

    hilog.info(DOMAIN, TAG, 'App backgrounded with active agent task (isRunning=true, autoFloat=true)');
    await this.showFloatWindow(true);
  }

  /**
   * Invoked when EntryAbility is foregrounded.
   */
  async onAppForeground(): Promise<void> {
    this.isAppForeground = true;
    // When main app returns to foreground, hide floating window to avoid visual clutter
    if (this.isWindowShowing()) {
      hilog.info(DOMAIN, TAG, 'App foregrounded: hiding float window');
      await this.hideFloatWindow();
    }
  }

  /**
   * Brings EntryAbility back to foreground and closes float window.
   */
  async bringAppToForeground(): Promise<void> {
    try {
      await BridgeController.getInstance().exec('aa start -a EntryAbility -b com.shuwei.shellbridge');
      await this.hideFloatWindow();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to bring app to foreground: %{public}s', JSON.stringify(err));
    }
  }

  destroy(): void {
    if (this.floatWindow) {
      try {
        this.floatWindow.destroyWindow();
      } catch (e) {
        // ignore
      }
      this.floatWindow = null;
      this.isShowing = false;
      AppStorage.setOrCreate('floatWindowActive', false);
    }
  }
}
