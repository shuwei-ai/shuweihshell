/*
 * SkillManager: Manages the discovery, lifecycle, and system prompt formatting
 * for Pi Agent Skills on HarmonyOS.
 * Modeled after @earendil-works/pi (packages/coding-agent/src/core/skills.ts).
 */
import common from '@ohos.app.ability.common';
import buffer from '@ohos.buffer';
import hilog from '@ohos.hilog';
import { BridgeController } from '../../common/BridgeController';
import { Skill } from './types';
import { SkillParser } from './SkillParser';

const DOMAIN: number = 0x0001;
const TAG: string = 'SkillManager';

function escapeXml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export const DEFAULT_BUILTIN_SKILLS: Skill[] = [
  {
    name: 'openharmony-diag',
    description: 'OpenHarmony 设备与系统服务状态深度诊断技能。基于官方调测工具（hidumper, hilog, param, power-shell）排查系统状态、窗口图层、进程内存/CPU占用、系统属性与崩溃故障。',
    filePath: '/data/local/tmp/skills/openharmony-diag/SKILL.md',
    baseDir: '/data/local/tmp/skills/openharmony-diag',
    isBuiltin: true
  },
  {
    name: 'hmos-app-control',
    description: 'OpenHarmony 应用管理与能力自动化调度工具。基于官方 aa（Ability助手）与 bm（包管理器）实现应用安装/卸载、生命周期调度、包信息查询与多开分身支持。',
    filePath: '/data/local/tmp/skills/hmos-app-control/SKILL.md',
    baseDir: '/data/local/tmp/skills/hmos-app-control',
    isBuiltin: true
  },
  {
    name: 'hmos-network-helper',
    description: 'OpenHarmony 端侧网络请求、路由排查与 API 调试指南。核心规则：系统终端基于 toybox 没有安装 curl 或 wget，所有网络请求必须使用原生 fetch 工具。',
    filePath: '/data/local/tmp/skills/hmos-network-helper/SKILL.md',
    baseDir: '/data/local/tmp/skills/hmos-network-helper',
    isBuiltin: true
  },
  {
    name: 'hmos-ui-automation',
    description: '基于 uitest 布局分析与中文文本输入、uinput 虚拟按键的鸿蒙高效自动化操作技能。当需要模拟点击、滑动屏幕、查找UI元素、输入中文文本或执行跨应用（如微信发送消息、小红书操作等）自动化任务时使用。',
    filePath: '/data/local/tmp/skills/hmos-ui-automation/SKILL.md',
    baseDir: '/data/local/tmp/skills/hmos-ui-automation',
    isBuiltin: true
  },
  {
    name: 'baoyu-post-to-wechat',
    description: '基于内置 ArkWeb 浏览器与 CDP 自动化协议的微信公众号（订阅号/服务号）文章排版与草稿自动发布技能。支持 Markdown 自动转为精美内联样式 HTML、智能填写标题/作者/摘要，并直接将文章保存到微信公众号草稿箱。使用触发词："发布公众号"、"post to wechat"、"微信公众号"、"公众号草稿"。',
    filePath: '/data/local/tmp/skills/baoyu-post-to-wechat/SKILL.md',
    baseDir: '/data/local/tmp/skills/baoyu-post-to-wechat',
    isBuiltin: true
  }
];

export class SkillManager {
  private static instance: SkillManager = new SkillManager();

  private context: common.Context | null = null;
  private skillsDir: string = '/data/local/tmp/skills';
  private skills: Skill[] = [...DEFAULT_BUILTIN_SKILLS];

  static getInstance(): SkillManager {
    return SkillManager.instance;
  }

  async init(context: common.Context): Promise<void> {
    this.context = context;
    // Primary skills store is /data/local/tmp/skills (accessible by shell uid 2000, Agent tools & host)
    this.skillsDir = '/data/local/tmp/skills';

    try {
      await BridgeController.getInstance().exec(`mkdir -p '${this.skillsDir}'`);
      await this.ensureDefaultSkills();
      await this.reloadSkills();
      hilog.info(DOMAIN, TAG, 'SkillManager initialized with %{public}d skills', this.skills.length);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to initialize SkillManager: %{public}s', JSON.stringify(err));
    }
  }

  getSkills(): Skill[] {
    return [...this.skills];
  }

  getSkillsDirectory(): string {
    return this.skillsDir;
  }

  getSkillByName(name: string): Skill | undefined {
    return this.skills.find(s => s.name === name);
  }

  /**
   * Reloads skills from the app local skills directory and external shared paths.
   */
  async reloadSkills(): Promise<void> {
    const loaded: Map<string, Skill> = new Map();
    for (const b of DEFAULT_BUILTIN_SKILLS) {
      loaded.set(b.name, b);
    }

    const searchDirs = [this.skillsDir];
    for (const dir of searchDirs) {
      if (!dir) {
        continue;
      }
      try {
        const findRes = await BridgeController.getInstance().exec(
          `find '${dir}' -maxdepth 2 -name 'SKILL.md' 2>/dev/null`
        );
        if (!findRes.ok || !findRes.output) {
          continue;
        }

        const files = findRes.output.split('\n').map(l => l.trim()).filter(l => l.length > 0);
        for (const filePath of files) {
          const catRes = await BridgeController.getInstance().exec(`cat '${filePath}'`);
          if (catRes.ok && catRes.output) {
            const baseDir = filePath.substring(0, filePath.lastIndexOf('/'));
            const isBuiltin = ['openharmony-diag', 'hmos-app-control', 'hmos-network-helper', 'hmos-ui-automation', 'baoyu-post-to-wechat']
              .some(name => filePath.includes(`/${name}/`));

            const skill = SkillParser.parse(catRes.output, filePath, baseDir, isBuiltin);
            if (skill && !loaded.has(skill.name)) {
              loaded.set(skill.name, skill);
            }
          }
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'Error scanning skills in %{public}s: %{public}s', dir, JSON.stringify(e));
      }
    }

    this.skills = Array.from(loaded.values());
  }

  /**
   * Formats the active visible skills into the official Pi <available_skills> XML format.
   * Injected dynamically into the Agent's System Prompt.
   */
  formatSkillsForPrompt(fileReadTool: 'read' | 'bash' = 'read'): string {
    const visibleSkills = this.skills.filter(s => !s.disableModelInvocation);
    if (visibleSkills.length === 0) {
      return '';
    }

    const lines: string[] = [
      '\n\nThe following skills provide specialized instructions for specific tasks.',
      fileReadTool === 'read'
        ? 'Use the read tool to load a skill\'s file when the task matches its description.'
        : 'Use bash to load a skill\'s file when the task matches its description.',
      'When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.',
      '',
      '<available_skills>'
    ];

    for (const skill of visibleSkills) {
      lines.push('  <skill>');
      lines.push(`    <name>${escapeXml(skill.name)}</name>`);
      lines.push(`    <description>${escapeXml(skill.description)}</description>`);
      lines.push(`    <location>${escapeXml(skill.filePath)}</location>`);
      lines.push('  </skill>');
    }
    lines.push('</available_skills>');

    return lines.join('\n');
  }

  /**
   * Creates a new custom skill on the device.
   */
  async createSkill(name: string, description: string, markdownBody: string): Promise<boolean> {
    const sanitizedName = name.trim().toLowerCase().replace(/[^a-z0-9_-]/g, '-');
    if (!sanitizedName || !description.trim()) {
      return false;
    }

    const targetDir = `${this.skillsDir}/${sanitizedName}`;
    const targetFile = `${targetDir}/SKILL.md`;

    const fullContent = `---
name: ${sanitizedName}
description: ${description.trim().replace(/\n/g, ' ')}
---

${markdownBody.trim()}
`;

    try {
      await BridgeController.getInstance().exec(`mkdir -p '${targetDir}'`);
      const b64 = buffer.from(fullContent, 'utf-8').toString('base64');
      await BridgeController.getInstance().exec(`echo '${b64}' | base64 -d > '${targetFile}'`);
      await this.reloadSkills();
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Failed to create skill %{public}s: %{public}s', sanitizedName, JSON.stringify(e));
      return false;
    }
  }

  /**
   * Deletes a custom skill from device storage.
   */
  async deleteSkill(name: string): Promise<boolean> {
    const sanitizedName = name.trim();
    const targetDir = `${this.skillsDir}/${sanitizedName}`;
    try {
      await BridgeController.getInstance().exec(`rm -rf '${targetDir}'`);
      await this.reloadSkills();
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Failed to delete skill %{public}s: %{public}s', sanitizedName, JSON.stringify(e));
      return false;
    }
  }

  /**
   * Ensures default high-value OpenHarmony/HarmonyOS skills are pre-installed.
   */
  async ensureDefaultSkills(): Promise<void> {
    // 1. openharmony-diag
    await this.installBuiltinSkill(
      'openharmony-diag',
      'OpenHarmony 设备与系统服务状态深度诊断技能。基于官方调测工具（hidumper, hilog, param, power-shell）排查系统状态、窗口图层、进程内存/CPU占用、系统属性与崩溃故障。',
      `# OpenHarmony 设备与服务状态诊断指南（官方调测规范）

当用户需要排查系统问题、崩溃、图层或资源占用时，请遵循以下标准流程：

## 1. 窗口与图层诊断 (hidumper)
使用 hidumper 查询窗口与图形子系统状态：
\`\`\`bash
# 查看所有已注册的系统能力 (System Abilities)
hidumper -l

# 导出窗口管理服务状态（核心：查找 focusWindow 焦点窗口与 windowMode 模式）
hidumper -s WindowManagerService -a -a | head -n 60

# 导出渲染服务帧率与图形渲染状态
hidumper -s RenderService -a "fps" 2>/dev/null || true
\`\`\`

## 2. 日志检索与实时诊断 (hilog)
- ⚠️ **核心避坑：在 Agent 终端中必须使用 \`hilog -x\` 非阻塞模式！** 直接执行 \`hilog\` 会一直挂起阻塞命令通道。
\`\`\`bash
# 按 PID 获取指定进程最近 50 条日志
hilog -x -P <pid> | tail -n 50

# 按 Tag 或 Domain 过滤关键日志
hilog -x -T <tag> | tail -n 50
hilog -x -D <domainId> | tail -n 50

# 清空日志缓冲区与查询缓冲区大小
hilog -r
hilog -g
\`\`\`

## 3. 内存与进程资源诊断
- 检查特定进程详细内存分配（Pss/Dirty/Heap/Stack）：\`hidumper --mem <pid>\`
- 检查系统整体内存与 CPU 负载：\`top -b -n 1\` 或 \`hidumper --cpu\`
- 检查特定服务或应用进程存活：\`pidof <bundleName>\` 或 \`ps -ef | grep <keyword>\`

## 4. 系统属性与参数工具 (param)
- 查询系统参数（如设备型号、系统版本、构建号）：
  \`\`\`bash
  param get const.product.model
  param get const.build.version
  param dump | grep -iE "model|version|brand"
  \`\`\`
- 设置系统参数（需具备写权限）：
  \`\`\`bash
  param set <key> <value>
  \`\`\`

## 5. 崩溃日志排查 (faultlog)
检查系统崩溃异常堆栈与 appfreeze：
\`\`\`bash
ls -lt /data/log/faultlog/temp/ | head -n 15
\`\`\`
如发现 cppcrash 或 appfreeze 文件，使用 \`read\` 工具查看堆栈定位 SIGSEGV、SIGABRT 或主线程卡死点。
`
    );

    // 2. hmos-app-control
    await this.installBuiltinSkill(
      'hmos-app-control',
      'OpenHarmony 应用管理与能力自动化调度工具。基于官方 aa（Ability助手）与 bm（包管理器）实现应用安装/卸载、生命周期调度、包信息查询与多开分身支持。',
      `# OpenHarmony 应用包管理与调度指南（官方调测规范）

## 1. 包管理器 (bm)
- 查询已安装应用包名：
  \`\`\`bash
  # 查询所有应用包名列表
  bm dump -a | head -n 40
  # 查询特定用户下的应用列表（分身用户通常为 101/128）
  bm dump -u <userId>
  \`\`\`
- 查询应用元数据、权限 TokenID 与组件信息：
  \`\`\`bash
  bm dump -n <bundleName>
  \`\`\`
- 安装与卸载应用：
  \`\`\`bash
  # 安装或覆盖安装 HAP
  bm install -p /data/local/tmp/app.hap -r
  # 卸载应用（-k 保留数据目录）
  bm uninstall -n <bundleName> [-k]
  \`\`\`
- 清理应用数据或缓存：
  \`\`\`bash
  # 清理应用全部数据与缓存
  bm clean -n <bundleName>
  # 仅清理应用缓存文件（-c）
  bm clean -n <bundleName> -c
  \`\`\`
- 获取设备唯一标识 UDID：
  \`\`\`bash
  bm get --udid
  \`\`\`

## 2. Ability 助手 (aa)
- 启动应用主界面：
  \`\`\`bash
  # 默认启动
  aa start -a EntryAbility -b <bundleName>
  # ⚠️ 关键避坑：存在分身多开时，必须指定 -u 100 拉起主身，避免触发「选择打开方式」弹窗
  aa start -a EntryAbility -b <bundleName> -u 100
  \`\`\`
- 隐式 Want / URI 启动第三方应用（避坑提示）：
  \`\`\`bash
  # ⚠️ 关键禁忌：严禁使用 aa start viewData 打开网页或公众号！系统已内置 ArkWeb 桌面浏览器，所有网页访问必须调用原生 browser 工具！
  # aa start -A ohos.want.action.viewData -U 'https://...' 仅用于测试外部系统浏览器唤起，正常任务禁止调用
  \`\`\`
- 强制停止应用进程：
  \`\`\`bash
  aa force-stop <bundleName>
  \`\`\`
- 停止后台服务扩展：
  \`\`\`bash
  aa stop-service -a <abilityName> -b <bundleName>
  \`\`\`
- 调试与预启动：
  \`\`\`bash
  # 进入或退出调试模式
  aa attach -b <bundleName>
  aa detach -b <bundleName>
  # 设置应用等待调试状态
  aa appdebug -p <bundleName>
  # 取消等待调试
  aa appdebug -c
  # 后台生命周期预启动
  aa pre-start -b <bundleName> -m <moduleName>
  \`\`\`
`
    );

    // 3. hmos-network-helper
    await this.installBuiltinSkill(
      'hmos-network-helper',
      'OpenHarmony 端侧网络请求、路由排查与 API 调试指南。核心规则：系统终端基于 toybox 没有安装 curl 或 wget，所有网络请求必须使用原生 fetch 工具。',
      `# OpenHarmony 网络请求与环境指南

## 1. 关键约束（重点避坑）
- ⚠️ 设备终端中 **没有 curl 或 wget** 命令！切勿在 bash 中执行 curl/wget。
- 所有 HTTP/HTTPS 请求请调用原生 **fetch** 工具：
  \`\`\`json
  {
    "url": "https://httpbin.org/get",
    "method": "GET"
  }
  \`\`\`

## 2. 网络状态与路由排查
- 查询当前设备公网路由与网卡：
  \`\`\`bash
  ifconfig
  netstat -rn
  \`\`\`
- 查询本地监听端口（如无线调试端口）：
  \`\`\`bash
  cat /proc/net/tcp | awk 'NR>1 {print $2}' | while read a; do p=$(echo $a | cut -d: -f2); echo $((16#$p)); done | sort -un
  \`\`\`
`
    );

    // 4. hmos-ui-automation
    await this.installBuiltinSkill(
      'hmos-ui-automation',
      '基于 uitest 布局分析与中文文本输入、uinput 虚拟按键的鸿蒙高效自动化操作技能。当需要模拟点击、滑动屏幕、查找UI元素、输入中文文本或执行跨应用（如微信发送消息、小红书操作等）自动化任务时使用。',
      `# 鸿蒙 UI 自动化与跨应用操作实战指南

## 1. 核心工具与原则（避坑准则）
- ⚠️ **中文文本输入：必须使用 \`uitest uiInput text\`，禁止使用 \`uinput -K -t\`！**
  - \`uinput -K -t\` 底层仅支持 ASCII 字符，输入中文会报错 \`The character of index 0 is invalid\`。
  - **输入中文标准指令**：
    \`\`\`bash
    # 针对当前聚焦的输入框直接注入文本（无需打开剪贴板，毫秒级响应）：
    uitest uiInput text '<中文内容>'
    # 或者点击指定坐标后输入文本：
    uitest uiInput inputText <x> <y> '<中文内容>'
    \`\`\`
  - ⚠️ **严禁使用 browser 加载 example.com 试图通过 navigator.clipboard.writeText 写入剪贴板**。ArkWeb 在后台或未聚焦状态下会触发 \`NotAllowedError\`，且带来巨大网络与解析开销。

## 2. 元素定位与布局诊断（严禁读取图片二进制）
- ⚠️ **严禁使用 read 工具读取 .jpeg / .png 等二进制图片文件**！会导致十万级字符乱码输出，严重耗尽 Token 上下文，拖慢 LLM 请求速度。
- **UI 结构与元素定位推荐做法**：使用 \`uitest dumpLayout\`：
  \`\`\`bash
  uitest dumpLayout -p /data/local/tmp/layout.json
  \`\`\`
  通过 grep 快速检索文本与坐标范围（bounds）：
  \`\`\`bash
  grep -o '"bounds":"[^"]*"[^}]*"text":"<关键词>"' /data/local/tmp/layout.json
  \`\`\`
  \`bounds\` 格式为 \`[left,top][right,bottom]\`。中心坐标计算：
  \`centerX = (left + right) / 2\`，\`centerY = (top + bottom) / 2\`。

## 3. 应用启动与分身应用避坑
- 启动应用：
  \`\`\`bash
  aa start -a EntryAbility -b <bundleName> -u 100
  \`\`\`
- **应用分身处理**：若设备开启了微信分身（微信与微信1），直接调用 \`aa start\` 会弹出「选择打开方式」模态对话框。
  - 推荐添加 \`-u 100\` 指定启动主身。
  - 若已出现弹窗，执行 \`uitest dumpLayout\` 获取「微信」项 bounds 并点击进入。

## 4. 模拟点击、滑动与按键
- 点击目标：
  \`\`\`bash
  uitest uiInput click <x> <y>
  \`\`\`
- 滑动屏幕：
  \`\`\`bash
  uitest uiInput swipe <fromX> <fromY> <toX> <toY> 600
  \`\`\`
- 物理返回键（Dismiss 弹窗/返回上级）：
  \`\`\`bash
  uinput -K -d 2 -u 2
  \`\`\`
- 删除输入框字符（Backspace）：
  \`\`\`bash
  uinput -K -d 2055 -u 2055
  \`\`\`

## 5. 微信发送消息标准化极速链路
1. **拉起微信主身**：
   \`\`\`bash
   aa start -a EntryAbility -b com.tencent.wechat -u 100
   \`\`\`
2. **定位并进入联系人会话**：
   通过 \`uitest dumpLayout -p /data/local/tmp/wx.json\` 检索联系人（如「李国玉」）并点击。
3. **输入内容**：
   点击输入框激活后直接执行：
   \`\`\`bash
   uitest uiInput text '心灵励志鸡汤内容...'
   \`\`\`
4. **定位绿色发送按钮并点击**：
   文本填入后，输入框右侧会动态显示「发送」按钮，执行 dumpLayout 提取 \`"text":"发送"\` 的 bounds 并点击，完成极速发送！
`
    );

    // 5. baoyu-post-to-wechat
    await this.installBuiltinSkill(
      'baoyu-post-to-wechat',
      '基于内置 ArkWeb 浏览器与 CDP 自动化协议的微信公众号（订阅号/服务号）文章排版与草稿自动发布技能。支持 Markdown 自动转为精美内联样式 HTML、智能填写标题/作者/摘要，并直接将文章保存到微信公众号草稿箱。使用触发词："发布公众号"、"post to wechat"、"微信公众号"、"公众号草稿"。',
      `# 微信公众号文章排版与草稿发布指南（ArkWeb CDP 自动化版）

当用户需要撰写文章并发布到微信公众号（订阅号/服务号）草稿箱时，请遵循以下流程：

## 1. 核心发布工具：browser (action: "wechat_publish")
直接调用原生 \`browser\` 工具的 \`wechat_publish\` 动作完成端侧自动化排版与草稿保存：
\`\`\`json
{
  "action": "wechat_publish",
  "title": "文章标题（精炼有力，最多64字）",
  "content": "# 一级标题\\n\\n正文内容，支持标准 Markdown 语法...",
  "author": "作者名称（可选）",
  "summary": "文章摘要（120字以内，可选）",
  "themeColor": "blue"
}
\`\`\`

## 2. ⚠️ 严禁使用外置浏览器（核心铁律）
- **严禁使用 bash 执行 \`aa start -A ohos.want.action.viewData\` 打开网页或公众号后台！**
- 本应用内置了完整的 PC 级 ArkWeb 浏览器组件并开启了 CDP 协议控制，所有网页交互、登录探测、DOM 操作与草稿注入**必须 100% 由内置 \`browser\` 工具完成**。
- 如果公众号未登录，\`wechat_publish\` 会自动在内置浏览器中加载登录页面，并引导用户切换到「网页浏览器」Tab 扫码登录。用户扫码完成后，会话长期保存在内置 ArkWeb 中，无需重复登录。

## 3. 参数与排版规范
- **title**：必填，文章标题，建议 15~30 字以内，吸引眼球。
- **content**：必填，正文 Markdown 或 HTML。
  - 内置微信排版引擎（WechatStyler），自动将 Markdown 标题、引用、列表、粗体、代码块编译为符合微信公众号规范的高品质内联样式（Inline Styles）。
  - 普通外链（[标题](url)）将自动在文末提取生成注脚引用列表（符合微信公众平台无外链跳转规范）。
- **author**：可选，作者栏名称。
- **summary**：可选，摘要，默认取第一段文本截断 120 字。
- **themeColor**：可选主题配色：
  - \`"blue"\`：经典优雅蓝（#2b5aed，默认推荐）
  - \`"green"\`：微信原生态绿（#07c160）
  - \`"orange"\`：活力暖橙（#ff8200）
  - \`"red"\` / \`"vermilion"\`：热烈中国红（#fa5151）
  - \`"purple"\`：科技紫（#722ed1）

## 3. 登录与会话管理
- 如果公众号后台未登录，工具会提示用户切换到底部导航栏的「浏览器」Tab。
- 用户可在手机/平板屏幕上直接通过微信扫码登录。
- ArkWeb 会自动持久化 Cookie 与 Session 会话，扫码一次后长期有效，下次发布无需再次扫码。
`
    );
  }

  private async installBuiltinSkill(name: string, description: string, body: string): Promise<void> {
    const targetDir = `${this.skillsDir}/${name}`;
    const targetFile = `${targetDir}/SKILL.md`;

    try {
      await BridgeController.getInstance().exec(`mkdir -p '${targetDir}'`);
      const fullContent = `---
name: ${name}
description: ${description}
---

${body.trim()}
`;
      const b64 = buffer.from(fullContent, 'utf-8').toString('base64');
      await BridgeController.getInstance().exec(`echo '${b64}' | base64 -d > '${targetFile}'`);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to install builtin skill %{public}s: %{public}s', name, JSON.stringify(e));
    }
  }
}
