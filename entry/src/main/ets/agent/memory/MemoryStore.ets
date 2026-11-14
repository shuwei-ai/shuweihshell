/*
 * Long-Term & Episodic Memory Store for HarmonyOS Pi Agent.
 * Modeled after Pi Agent memory extensions (pi-self-learn and pi-memctx).
 * Persists learned rules, environment constraints, and failure avoidance lessons.
 */
import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';
import { MemoryCategory, MemoryLesson } from '../types';

const DOMAIN: number = 0x0001;
const TAG: string = 'MemoryStore';
const STORE_NAME = 'swshell_agent_memory';
const KEY_LESSONS = 'agent_memory_lessons';

export const DEFAULT_LESSONS: MemoryLesson[] = [
  {
    id: 'lesson_no_curl',
    category: 'network',
    rule: '鸿蒙系统终端 (toybox) 没有安装 curl 或 wget。所有 HTTP/HTTPS 网络请求必须使用原生 fetch 工具，禁止在 bash 中执行 curl/wget。',
    triggerPattern: 'curl|wget|command not found: curl|command not found: wget',
    occurrenceCount: 6,
    confidence: 1.0,
    createdAt: 1731100000000,
    lastUpdated: 1731100000000
  },
  {
    id: 'lesson_toybox_limits',
    category: 'shell',
    rule: '系统终端基于 toybox，缺少 tr、awk、column 等工具。文本处理优先使用 grep、sed、cut、cat 简单管道，或直接通过 read/edit 工具在内存中分析。',
    triggerPattern: 'command not found: tr|command not found: awk|command not found: column',
    occurrenceCount: 4,
    confidence: 0.95,
    createdAt: 1731100000000,
    lastUpdated: 1731100000000
  },
  {
    id: 'lesson_pura70_resolution',
    category: 'device',
    rule: '当前设备为华为 Pura 70，屏幕物理分辨率为 1256x2760。使用 uinput 注入手势或点击时，X 坐标在 0~1256 内，Y 坐标在 0~2760 内。底部系统手势条位于 Y=2740 附近。',
    triggerPattern: 'uinput|snapshot_display|2760|1256',
    occurrenceCount: 5,
    confidence: 1.0,
    createdAt: 1731100000000,
    lastUpdated: 1731100000000
  },
  {
    id: 'lesson_edit_strict_match',
    category: 'tools',
    rule: '使用 edit 工具时，old_string 必须逐字完全匹配目标文本（包括每一行的空格、制表符与换行），且目标文本在文件中必须唯一。修改前务必先使用 read 工具读取确切的文本内容。',
    triggerPattern: 'Target string not found in file|edit failed',
    occurrenceCount: 3,
    confidence: 0.95,
    createdAt: 1731100000000,
    lastUpdated: 1731100000000
  },
  {
    id: 'lesson_shell_uid_capabilities',
    category: 'permission',
    rule: '当前 bash 具备 uid 2000 (shell) 与 u:r:shell:s0 权限，可免沙箱写入 /data/local/tmp，并可调用系统命令: bm dump, param get/set, hidumper, aa start/stop, snapshot_display。',
    triggerPattern: 'bm dump|param get|hidumper|aa start|/data/local/tmp',
    occurrenceCount: 4,
    confidence: 0.95,
    createdAt: 1731100000000,
    lastUpdated: 1731100000000
  },
  {
    id: 'lesson_browser_cdp_loopback',
    category: 'tools',
    rule: 'browser 工具基于本机的 ArkWeb 与 CDP 127.0.0.1:9222 环回连接。网页交互使用 index 针对编号元素操作（如 click index=1 或 type index=2 text="hello"）。',
    triggerPattern: 'browser|CDP|9222',
    occurrenceCount: 2,
    confidence: 0.9,
    createdAt: 1731100000000,
    lastUpdated: 1731100000000
  },
  {
    id: 'lesson_uitest_chinese_input',
    category: 'tools',
    rule: '在鸿蒙端侧，uinput -K -t 仅支持 ASCII 字符，输入中文会报错 The character of index 0 is invalid。输入中文文本必须使用 uitest：`uitest uiInput text \'<中文文本>\'`（输入到聚焦框）或 `uitest uiInput inputText <x> <y> \'<中文文本>\'`。切勿通过 browser/clipboard 迂回写入。',
    triggerPattern: 'uinput -K -t|The character of index 0 is invalid|uitest|中文输入|发消息',
    occurrenceCount: 5,
    confidence: 1.0,
    createdAt: 1731200000000,
    lastUpdated: 1731200000000
  },
  {
    id: 'lesson_ui_layout_not_binary_read',
    category: 'tools',
    rule: '严禁使用 read 工具读取 .jpeg/.png 等二进制图片文件（会导致上下文爆炸与乱码）。UI 元素定位使用 `uitest dumpLayout -p /data/local/tmp/layout.json` 导出结构化树，通过 grep bounds 与 text 毫秒级精确定位控件。拉起多开应用时指定 -u 100 避开选择分身弹窗。',
    triggerPattern: 'read.*jpeg|read.*png|dumpLayout|snapshot_display|选择打开方式',
    occurrenceCount: 5,
    confidence: 1.0,
    createdAt: 1731200000000,
    lastUpdated: 1731200000000
  },
  {
    id: 'lesson_builtin_browser_mandatory',
    category: 'tools',
    rule: '访问网页、文章读取、微信公众号文章排版发布必须使用原生 browser 工具（action: "navigate" / "wechat_publish"），严禁使用 bash 执行 aa start -A ohos.want.action.viewData 拉起外置系统浏览器。',
    triggerPattern: 'browser|公众号|微信公众号|viewData|网页|文章|发布|wechat|草稿箱',
    occurrenceCount: 5,
    confidence: 1.0,
    createdAt: 1731200000000,
    lastUpdated: 1731200000000
  }
];

export class MemoryStore {
  private static instance: MemoryStore = new MemoryStore();
  private store: dataPreferences.Preferences | undefined = undefined;
  private lessons: MemoryLesson[] = [];
  private isInitialized: boolean = false;

  private constructor() {
    this.lessons = [...DEFAULT_LESSONS];
  }

  static getInstance(): MemoryStore {
    return MemoryStore.instance;
  }

  async init(context: common.Context): Promise<void> {
    if (this.isInitialized && this.store !== undefined) {
      return;
    }

    try {
      this.store = await dataPreferences.getPreferences(context, { name: STORE_NAME });
      const raw = (await this.store.get(KEY_LESSONS, '')) as string;
      if (raw && raw.trim().length > 0) {
        try {
          const parsed = JSON.parse(raw) as MemoryLesson[];
          if (Array.isArray(parsed) && parsed.length > 0) {
            this.lessons = parsed;
            let hasNew = false;
            for (const def of DEFAULT_LESSONS) {
              if (!this.lessons.some(l => l.id === def.id)) {
                this.lessons.push(def);
                hasNew = true;
              }
            }
            if (hasNew) {
              await this.persist();
            }
            hilog.info(DOMAIN, TAG, `Loaded ${this.lessons.length} lessons from persistent store`);
          } else {
            this.lessons = [...DEFAULT_LESSONS];
            await this.persist();
          }
        } catch (e) {
          hilog.error(DOMAIN, TAG, `Failed to parse saved lessons JSON, resetting to defaults: ${e}`);
          this.lessons = [...DEFAULT_LESSONS];
          await this.persist();
        }
      } else {
        this.lessons = [...DEFAULT_LESSONS];
        await this.persist();
      }
      this.isInitialized = true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Failed to initialize MemoryStore: ${err}`);
      this.lessons = [...DEFAULT_LESSONS];
    }
  }

  private async persist(): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    try {
      const json = JSON.stringify(this.lessons);
      await this.store.put(KEY_LESSONS, json);
      await this.store.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Failed to persist lessons: ${err}`);
    }
  }

  getLessons(): MemoryLesson[] {
    return this.lessons;
  }

  getLesson(id: string): MemoryLesson | undefined {
    return this.lessons.find(l => l.id === id);
  }

  async addOrUpdateLesson(lesson: Partial<MemoryLesson>): Promise<MemoryLesson> {
    const now = Date.now();
    let target: MemoryLesson;

    if (lesson.id) {
      const existing = this.lessons.find(l => l.id === lesson.id);
      if (existing) {
        if (lesson.rule) existing.rule = lesson.rule;
        if (lesson.category) existing.category = lesson.category;
        if (lesson.triggerPattern !== undefined) existing.triggerPattern = lesson.triggerPattern;
        if (lesson.confidence !== undefined) existing.confidence = lesson.confidence;
        existing.occurrenceCount = (existing.occurrenceCount || 1) + 1;
        existing.lastUpdated = now;
        await this.persist();
        return existing;
      }
    }

    // Check if duplicate rule already exists
    const duplicate = this.lessons.find(l =>
      lesson.rule && (l.rule.trim() === lesson.rule.trim() ||
      (l.triggerPattern && lesson.triggerPattern && l.triggerPattern === lesson.triggerPattern))
    );

    if (duplicate) {
      duplicate.occurrenceCount = (duplicate.occurrenceCount || 1) + 1;
      duplicate.lastUpdated = now;
      if (lesson.confidence && lesson.confidence > duplicate.confidence) {
        duplicate.confidence = lesson.confidence;
      }
      await this.persist();
      return duplicate;
    }

    const newId = lesson.id || `lesson_${now}_${Math.floor(Math.random() * 1000)}`;
    target = {
      id: newId,
      category: lesson.category || 'general',
      rule: lesson.rule || '',
      triggerPattern: lesson.triggerPattern || '',
      occurrenceCount: lesson.occurrenceCount || 1,
      confidence: lesson.confidence ?? 0.9,
      createdAt: now,
      lastUpdated: now
    };

    this.lessons.push(target);
    await this.persist();
    hilog.info(DOMAIN, TAG, `Added new memory lesson [${target.category}] ${target.id}: ${target.rule}`);
    return target;
  }

  async recordOccurrence(idOrPattern: string): Promise<void> {
    let matched = false;
    const now = Date.now();
    for (const lesson of this.lessons) {
      if (lesson.id === idOrPattern || (lesson.triggerPattern && new RegExp(lesson.triggerPattern, 'i').test(idOrPattern))) {
        lesson.occurrenceCount = (lesson.occurrenceCount || 0) + 1;
        lesson.lastUpdated = now;
        matched = true;
      }
    }
    if (matched) {
      await this.persist();
    }
  }

  async removeLesson(id: string): Promise<boolean> {
    const initialLen = this.lessons.length;
    this.lessons = this.lessons.filter(l => l.id !== id);
    if (this.lessons.length !== initialLen) {
      await this.persist();
      return true;
    }
    return false;
  }

  async resetToDefaults(): Promise<void> {
    this.lessons = [...DEFAULT_LESSONS];
    await this.persist();
  }

  findMatchingLessons(text: string): MemoryLesson[] {
    if (!text || text.trim().length === 0) {
      return [];
    }
    const matches: MemoryLesson[] = [];
    for (const lesson of this.lessons) {
      if (lesson.triggerPattern && lesson.triggerPattern.length > 0) {
        try {
          const reg = new RegExp(lesson.triggerPattern, 'i');
          if (reg.test(text)) {
            matches.push(lesson);
          }
        } catch (e) {
          if (text.toLowerCase().includes(lesson.triggerPattern.toLowerCase())) {
            matches.push(lesson);
          }
        }
      }
    }
    return matches;
  }

  /**
   * Formats top lessons into a concise prompt block for system prompt injection.
   * Scored by (confidence * 10 + occurrenceCount) descending.
   *
   * @param limit Maximum number of lessons to include
   * @param allowedCategories Whitelist of categories to include (e.g. ['general'])
   * @param excludeExecutionCommands If true, filters out low-level shell/tool execution commands
   */
  formatLessonsForPrompt(
    limit: number = 8,
    allowedCategories?: MemoryCategory[],
    excludeExecutionCommands: boolean = false
  ): string {
    if (this.lessons.length === 0) {
      return '';
    }

    let candidates = this.lessons;

    // 1. Whitelist category filter (if specified)
    if (allowedCategories && allowedCategories.length > 0) {
      candidates = candidates.filter(l => allowedCategories.includes(l.category));
    }

    // 2. Command pattern exclusion (for Router prompt slimming)
    if (excludeExecutionCommands) {
      const EXEC_CMD_PATTERN = /(uitest|uinput|bash|toybox|dumpLayout|read\s|write\s|edit\s|run_code|curl|wget)/i;
      candidates = candidates.filter(l => !EXEC_CMD_PATTERN.test(l.rule));
    }

    if (candidates.length === 0) {
      return '';
    }

    const sorted = [...candidates].sort((a, b) => {
      const scoreA = (a.confidence * 10) + (a.occurrenceCount || 0);
      const scoreB = (b.confidence * 10) + (b.occurrenceCount || 0);
      return scoreB - scoreA;
    });

    const selected = sorted.slice(0, limit);
    let output = '<learned_lessons_and_constraints>\n';
    output += 'The following environmental constraints and lessons were learned from past device tasks and failures. Strictly follow them to prevent repeating errors:\n';

    selected.forEach((l, idx) => {
      output += `${idx + 1}. [${l.category}] ${l.rule}\n`;
    });

    output += '</learned_lessons_and_constraints>';
    return output;
  }
}
