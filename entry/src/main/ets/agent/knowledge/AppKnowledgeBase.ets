/*
 * AppKnowledgeBase provides structured application knowledge profiles for popular HarmonyOS NEXT apps.
 * Inspired by Mika's knowledge base architecture (e.g. knowledge/apps/{app}/APP.md).
 * Contains package names, UI structure quirks (e.g. RichEditor vs TextInput), navigation traps,
 * and high-efficiency fast-path execution sequence recipes.
 */

export interface RecipeStep {
  op: string;
  bundle_name?: string;
  anchor?: string;
  text?: string;
  auto_send?: boolean;
  target?: string;
}

export interface AppProfile {
  bundleName: string;
  displayName: string;
  aliases: string[];
  description: string;
  uiQuirks: string[];
  fastRecipes: Record<string, RecipeStep[]>;
}

const WECHAT_SEND_RECIPE: RecipeStep[] = [
  { op: 'launch', bundle_name: 'com.tencent.wechat' },
  { op: 'click_anchor', anchor: 'search' },
  { op: 'type', text: '{CONTACT}', auto_send: false },
  { op: 'tap', target: '{CONTACT}' },
  { op: 'click_anchor', anchor: 'chat_input' },
  { op: 'type', text: '{MESSAGE}', auto_send: true }
];

const NOTEPAD_CREATE_RECIPE: RecipeStep[] = [
  { op: 'launch', bundle_name: 'com.huawei.hmos.notepad' },
  { op: 'tap', target: '新建笔记' },
  { op: 'type', text: '{CONTENT}' }
];

const SETTINGS_SEARCH_RECIPE: RecipeStep[] = [
  { op: 'launch', bundle_name: 'com.huawei.hmos.settings' },
  { op: 'click_anchor', anchor: 'search' },
  { op: 'type', text: '{SETTING_KEYWORD}', auto_send: false }
];

export class AppKnowledgeBase {
  private static getWechatProfile(): AppProfile {
    const recipes: Record<string, RecipeStep[]> = {
      'send_message': WECHAT_SEND_RECIPE
    };
    return {
      bundleName: 'com.tencent.wechat',
      displayName: '微信 (HarmonyOS NEXT)',
      aliases: ['微信', 'wechat', 'wx'],
      description: '腾讯微信 HarmonyOS NEXT 原生版。主要界面包括聊天列表、通讯录、发现、我。',
      uiQuirks: [
        '【关键】微信聊天输入框是 ArkUI RichEditor 组件，未聚焦前在普通 TextInput 过滤中可能不可见。请直接调用 action: "click_anchor", anchor: "chat_input" 或在 run_sequence 中使用该锚点聚焦。',
        '【关键】微信右上角搜索图标无 text/description 标签。请直接调用 action: "click_anchor", anchor: "search" 即可精准点击。',
        '【语音切换】若输入框显示为“按住 说话”，说明处于语音输入模式。点击左侧语音/键盘切换图标（anchor: "voice_toggle"）切回键盘输入。',
        '【一键发送】输入文字后右下角会弹出绿色“发送”按钮。调用 input_text 时指定 auto_send: true 或在 run_sequence 中使用 type 并设 auto_send: true，可直接一步完成输入加点击发送！',
        '【搜索联系人防误触】在搜索结果中点击联系人时，优先使用 @ref 索引或 target 明确指定联系人昵称，避免误点到搜索输入框本身。'
      ],
      fastRecipes: recipes
    };
  }

  private static getNotepadProfile(): AppProfile {
    const recipes: Record<string, RecipeStep[]> = {
      'create_note': NOTEPAD_CREATE_RECIPE
    };
    return {
      bundleName: 'com.huawei.hmos.notepad',
      displayName: '华为备忘录',
      aliases: ['备忘录', '便签', 'notepad', 'notes'],
      description: '华为系统备忘录应用。用于记录笔记、待办事项和速记。',
      uiQuirks: [
        '【新建笔记】主界面底部中心有新建笔记悬浮按钮（通常包含“+”或“新建笔记”图标）。',
        '【标题与正文】进入编辑页后，顶部是标题输入框，下方大区域是正文输入框。',
        '【完成保存】编辑完成后点击右上角勾选图标或发送 Back 键即可自动保存。'
      ],
      fastRecipes: recipes
    };
  }

  private static getSettingsProfile(): AppProfile {
    const recipes: Record<string, RecipeStep[]> = {
      'search_setting': SETTINGS_SEARCH_RECIPE
    };
    return {
      bundleName: 'com.huawei.hmos.settings',
      displayName: '系统设置',
      aliases: ['设置', '系统设置', 'settings'],
      description: 'HarmonyOS NEXT 系统设置，控制网络、蓝牙、显示、权限等核心选项。',
      uiQuirks: [
        '【顶部搜索】设置首页顶部常驻全局搜索栏，查找具体配置项（如 Wi-Fi、蓝牙、应用管理）优先在搜索栏输入关键词直达，避免盲目长距离滚动。'
      ],
      fastRecipes: recipes
    };
  }

  private static getAlipayProfile(): AppProfile {
    const recipes: Record<string, RecipeStep[]> = {};
    return {
      bundleName: 'com.eg.android.AlipayGphone',
      displayName: '支付宝',
      aliases: ['支付宝', 'alipay'],
      description: '蚂蚁集团支付宝，包含扫一扫、付款码、搜索生活号与小程序。',
      uiQuirks: [
        '【顶部功能区】顶部横排包含扫一扫、收付款、出行等快捷图标。',
        '【搜索框】顶部中心常驻搜索框，进入小程序或生活号最快捷路径是搜索。'
      ],
      fastRecipes: recipes
    };
  }

  private static getAllProfiles(): AppProfile[] {
    return [
      AppKnowledgeBase.getWechatProfile(),
      AppKnowledgeBase.getNotepadProfile(),
      AppKnowledgeBase.getSettingsProfile(),
      AppKnowledgeBase.getAlipayProfile()
    ];
  }

  /**
   * Finds the best matching app profile given a bundle name or user query string.
   */
  static findProfile(query: string): AppProfile | null {
    if (!query) {
      return null;
    }
    const q = query.trim().toLowerCase();
    const profiles = AppKnowledgeBase.getAllProfiles();

    for (let i = 0; i < profiles.length; i++) {
      const p = profiles[i];
      if (p.bundleName.toLowerCase() === q) {
        return p;
      }
      for (let j = 0; j < p.aliases.length; j++) {
        if (q.includes(p.aliases[j].toLowerCase())) {
          return p;
        }
      }
    }

    return null;
  }

  /**
   * Formats application knowledge guidance to be injected into agent / worker prompts.
   */
  static getKnowledgePrompt(bundleOrQuery?: string): string {
    if (bundleOrQuery) {
      const match = AppKnowledgeBase.findProfile(bundleOrQuery);
      if (match) {
        return AppKnowledgeBase.formatProfile(match);
      }
    }

    const profiles = AppKnowledgeBase.getAllProfiles();
    const sections: string[] = ['### 📱 高频应用专属认知库 (App Knowledge Base)'];
    for (let i = 0; i < profiles.length; i++) {
      sections.push(AppKnowledgeBase.formatProfile(profiles[i]));
    }
    return sections.join('\n\n');
  }

  private static formatProfile(profile: AppProfile): string {
    const lines: string[] = [
      `#### 📦 应用: ${profile.displayName} (\`${profile.bundleName}\`)`,
      `- **说明**: ${profile.description}`,
      `- **界面特征与避坑要点**:`
    ];
    for (let i = 0; i < profile.uiQuirks.length; i++) {
      lines.push(`  * ${profile.uiQuirks[i]}`);
    }

    const recipeNames = Object.keys(profile.fastRecipes);
    if (recipeNames.length > 0) {
      lines.push(`- **推荐极速连续操作流水线 (run_sequence Recipes)**:`);
      for (let i = 0; i < recipeNames.length; i++) {
        const recipe = profile.fastRecipes[recipeNames[i]];
        lines.push(`  * \`${recipeNames[i]}\`:\n\`\`\`json\n${JSON.stringify(recipe, null, 2)}\n\`\`\``);
      }
    }
    return lines.join('\n');
  }
}
