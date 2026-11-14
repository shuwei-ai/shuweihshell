import UIAbility from '@ohos.app.ability.UIAbility';
import type Want from '@ohos.app.ability.Want';
import type window from '@ohos.window';
import { AbilityConstant } from '@kit.AbilityKit';
import hilog from '@ohos.hilog';
import { BridgeController } from '../common/BridgeController';
import { FloatWindowManager } from '../window/FloatWindowManager';
import { AgentWorkspace } from '../agent/tools/AgentWorkspace';

const TAG: string = 'SwShell';
const DOMAIN: number = 0x3201;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('abilityContext', this.context);
    BridgeController.getInstance().init(this.context);
    FloatWindowManager.getInstance().init(this.context);
    AgentWorkspace.getInstance().init(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppStorage.setOrCreate('windowStage', windowStage);
    windowStage.getMainWindow().then((win: window.Window) => {
      AppStorage.setOrCreate('mainWindow', win);
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'failed to get main window: %{public}s', JSON.stringify(err));
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'failed to load the index page: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'index page loaded');
    });
  }

  onDestroy(): void {
    FloatWindowManager.getInstance().destroy();
  }

  onForeground(): void {
    FloatWindowManager.getInstance().onAppForeground();
  }

  onBackground(): void {
    FloatWindowManager.getInstance().onAppBackground();
  }
}
