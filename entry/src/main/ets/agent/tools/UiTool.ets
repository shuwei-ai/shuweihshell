/*
 * Native HarmonyOS UI Automation Tool (`ui`).
 * Wraps `uitest` and `uinput` with structured layout tree parsing, coordinate calculation,
 * and UTF-8 / Chinese-safe text entry.
 */
import { BridgeController } from '../../common/BridgeController';
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { UiLayoutParser, UiNode, UiNodeQuery, UiTreeParseResult } from './UiLayoutParser';
import { VisualAffordanceEngine } from './VisualAffordanceEngine';
import { PhoneOcr, OcrResult } from '../ocr/PhoneOcr';
import { FloatWindowManager } from '../../window/FloatWindowManager';
import common from '@ohos.app.ability.common';
import type Want from '@ohos.app.ability.Want';
import { AbilityConstant, StartOptions } from '@kit.AbilityKit';
import hilog from '@ohos.hilog';

export class UiTool {
  private static readonly LAYOUT_DUMP_PATH = '/data/local/tmp/sw_ui_layout.json';

  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'action': new ToolProperty(
        'string',
        'UI action to perform: "dump_tree", "find_and_click", "click_point", "click_anchor", "input_text", "run_sequence", "ocr", "swipe", "back", "home", "launch_app", "hide_overlay", "show_overlay", or "minimize_overlay".'
      ),
      'use_ocr': new ToolProperty('boolean', 'For dump_tree or find_and_click: supplement or fallback to on-device CoreVision OCR when elements lack accessibility labels (default false, auto-activates on custom/canvas views).'),
      'ref': new ToolProperty('string', 'Direct element reference tag from dump_tree, e.g. "@4" or "4". Eliminates text ambiguity completely.'),
      'steps': new ToolProperty('array', 'For run_sequence: ordered list of steps to execute sequentially on device. Each item is an object: {op: "launch"|"tap"|"click_anchor"|"type"|"clear"|"scroll"|"swipe"|"key"|"back"|"wait"|"assert", ref?: string, target?: string, anchor?: string, text?: string, auto_send?: boolean, bundle_name?: string, direction?: string, when_text?: string, delay_ms?: number}.'),
      'anchor': new ToolProperty('string', 'Visual semantic anchor to click directly: "search" (top-right magnifying glass), "back" (top-left arrow), "more" (top-right menu), "chat_input" (bottom message bar), "voice_toggle" (bottom keyboard/voice switch), or "send" (bottom send button).'),
      'auto_send': new ToolProperty('boolean', 'For input_text: automatically click send button immediately after typing content (default false).'),
      'bundle_name': new ToolProperty(
        'string',
        'Target bundle name (e.g. "com.huawei.hmos.notepad"). For dump_tree/find_and_click/input_text: isolates layout dump to this app only, bypassing any floating windows. For launch_app: package name to start.'
      ),
      'ability_name': new ToolProperty(
        'string',
        'Target UIAbility name for launch_app (default: "EntryAbility").'
      ),
      'text': new ToolProperty('string', 'Exact or preferred visible text/hint/description to match (for dump_tree filter, find_and_click, or locating input target).'),
      'contains_text': new ToolProperty('string', 'Case-insensitive substring match against element text/hint/description/id.'),
      'id': new ToolProperty('string', 'Component resource id (exact or substring) to match.'),
      'type': new ToolProperty('string', 'Component type filter (e.g. "Button", "TextInput", "ListItem").'),
      'index': new ToolProperty('number', '0-based match index (or node index when no text/id filter is provided). Default: 0.'),
      'clickable_only': new ToolProperty('boolean', 'For dump_tree: only show clickable nodes (default false).'),
      'include_all': new ToolProperty('boolean', 'For dump_tree: include unlabeled/non-interactive container nodes (default false).'),
      'limit': new ToolProperty('number', 'For dump_tree: max nodes to return (default 100).'),
      'x': new ToolProperty('number', 'Screen X coordinate (for click_point or input_text target focus).'),
      'y': new ToolProperty('number', 'Screen Y coordinate (for click_point or input_text target focus).'),
      'click_mode': new ToolProperty('string', 'Optional click variant for find_and_click / click_point: "click" (default), "double", or "long".'),
      'content': new ToolProperty('string', 'Text string to type (supports Chinese/UTF-8 via uitest). Used by input_text.'),
      'clear_first': new ToolProperty('boolean', 'For input_text: whether to clear existing text in the input box before typing new content (default true).'),
      'direction': new ToolProperty('string', 'Swipe direction when using swipe without explicit coordinates: "up", "down", "left", or "right".'),
      'x1': new ToolProperty('number', 'Swipe start X (if not using direction).'),
      'y1': new ToolProperty('number', 'Swipe start Y (if not using direction).'),
      'x2': new ToolProperty('number', 'Swipe end X (if not using direction).'),
      'y2': new ToolProperty('number', 'Swipe end Y (if not using direction).'),
      'duration_ms': new ToolProperty('number', 'Swipe duration in milliseconds (default 350, range 100-3000).')
    };

    const params = new ToolParameters(props, ['action']);
    const func = new ToolFunctionDefinition(
      'ui',
      'High-level native HarmonyOS UI automation tool backed by uitest/uinput and in-process overlay management. Prefer this over raw bash commands: launches apps, yields floating overlays, dumps & filters visible elements with auto-calculated center coordinates, clicks by text/id, types Chinese text reliably, and handles directional swipes.',
      params
    );
    return new ToolDefinition(func);
  }

  private static fail(toolCallId: string, error: string, output: string = ''): ToolResult {
    return {
      toolCallId: toolCallId,
      toolName: 'ui',
      output: output,
      error: error,
      isError: true
    };
  }

  private static ok(toolCallId: string, output: string): ToolResult {
    return {
      toolCallId: toolCallId,
      toolName: 'ui',
      output: output,
      isError: false
    };
  }

  private static shellSingleQuote(value: string): string {
    return `'${value.replace(/'/g, "'\\''")}'`;
  }

  private static async dumpAndParse(includeAll: boolean = false, bundleName?: string): Promise<UiTreeParseResult> {
    // Note: Never pass '-b <bundle>' to uitest dumpLayout on HarmonyOS NEXT:
    // In multi-window, split-screen, or floating window modes, uitest dumpLayout -b returns an empty root with 0 children!
    // Instead, always dump the complete layout and perform rock-solid bundle filtering in memory.
    const cmd = `uitest dumpLayout -p ${UiTool.LAYOUT_DUMP_PATH} >/dev/null 2>&1 && cat ${UiTool.LAYOUT_DUMP_PATH}`;
    const res = await BridgeController.getInstance().exec(cmd, '', 15);
    if (!res.ok) {
      throw new Error(res.error.length > 0 ? res.error : `uitest dumpLayout failed (exit ${res.exitCode})`);
    }
    const fullTree = UiLayoutParser.extractTree(res.output, includeAll);
    if (bundleName && bundleName.trim().length > 0) {
      const targetBundle = bundleName.trim();
      const filtered = fullTree.nodes.filter(n => n.bundleName === targetBundle || n.bundleName.includes(targetBundle));
      if (filtered.length > 0) {
        return {
          nodes: filtered,
          totalVisited: fullTree.totalVisited,
          screenWidth: fullTree.screenWidth,
          screenHeight: fullTree.screenHeight
        };
      }
    }
    return fullTree;
  }

  private static buildQuery(args: Record<string, Object>): UiNodeQuery {
    const rawRef = args['ref'] !== undefined ? args['ref'] : undefined;
    const query: UiNodeQuery = {
      ref: rawRef !== undefined ? String(rawRef) : undefined,
      text: typeof args['text'] === 'string' ? args['text'] as string : undefined,
      containsText: typeof args['contains_text'] === 'string' ? args['contains_text'] as string : undefined,
      id: typeof args['id'] === 'string' ? args['id'] as string : undefined,
      nodeType: typeof args['type'] === 'string' ? args['type'] as string : undefined,
      clickableOnly: typeof args['clickable_only'] === 'boolean' ? args['clickable_only'] as boolean : undefined
    };
    return query;
  }

  private static async runUiClick(x: number, y: number, mode: string): Promise<string> {
    const rx = Math.round(x);
    const ry = Math.round(y);
    let subCmd = 'click';
    if (mode === 'double') {
      subCmd = 'doubleClick';
    } else if (mode === 'long') {
      subCmd = 'longClick';
    }
    const cmd = (subCmd === 'click')
      ? `uinput -T -c ${rx} ${ry} >/dev/null 2>&1; uitest uiInput click ${rx} ${ry} >/dev/null 2>&1`
      : `uitest uiInput ${subCmd} ${rx} ${ry}`;
    const res = await BridgeController.getInstance().exec(cmd, '', 10);
    if (!res.ok) {
      throw new Error(res.error.length > 0 ? res.error : `Command '${cmd}' failed (exit ${res.exitCode})`);
    }
    return `${subCmd} at (${rx}, ${ry})${res.output.trim().length > 0 ? ': ' + res.output.trim() : ''}`;
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const action = (typeof args['action'] === 'string' ? args['action'] as string : '').trim();
    if (action.length === 0) {
      return UiTool.fail(toolCallId, 'Parameter "action" is required');
    }

    try {
      switch (action) {
        case 'dump_tree':
          return await UiTool.handleDumpTree(toolCallId, args);
        case 'find_and_click':
          return await UiTool.handleFindAndClick(toolCallId, args);
        case 'click_point':
          return await UiTool.handleClickPoint(toolCallId, args);
        case 'click_anchor':
          return await UiTool.handleClickAnchor(toolCallId, args);
        case 'input_text':
          return await UiTool.handleInputText(toolCallId, args);
        case 'run_sequence':
          return await UiTool.handleRunSequence(toolCallId, args);
        case 'ocr':
          return await UiTool.handleOcr(toolCallId, args);
        case 'swipe':
          return await UiTool.handleSwipe(toolCallId, args);
        case 'back':
          return await UiTool.handleKeyEvent(toolCallId, 'Back', 2);
        case 'home':
          return await UiTool.handleKeyEvent(toolCallId, 'Home', 1);
        case 'launch_app':
          return await UiTool.handleLaunchApp(toolCallId, args);
        case 'hide_overlay':
          try {
            await FloatWindowManager.getInstance().hideFloatWindow();
          } catch (_e) {
            // ignore
          }
          return UiTool.ok(toolCallId, 'Float window overlay hidden. Target app interface is now completely unblocked.');
        case 'show_overlay':
          try {
            await FloatWindowManager.getInstance().showFloatWindow(false);
          } catch (_e) {
            // ignore
          }
          return UiTool.ok(toolCallId, 'Float window overlay restored.');
        case 'minimize_overlay':
          try {
            await FloatWindowManager.getInstance().setCompactMode(true);
          } catch (_e) {
            // ignore
          }
          return UiTool.ok(toolCallId, 'Float window overlay minimized to compact status pill.');
        default:
          return UiTool.fail(toolCallId, `Unknown ui action: ${action}`);
      }
    } catch (err) {
      return UiTool.fail(toolCallId, `UI automation error (${action}): ${err}`);
    }
  }

  private static async handleLaunchApp(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rawBundle = typeof args['bundle_name'] === 'string' ? (args['bundle_name'] as string).trim() : '';
    if (rawBundle.length === 0) {
      return UiTool.fail(toolCallId, 'launch_app requires non-empty "bundle_name" (e.g. "com.huawei.hmos.notepad").');
    }
    const ability = typeof args['ability_name'] === 'string' && (args['ability_name'] as string).trim().length > 0
      ? (args['ability_name'] as string).trim()
      : 'EntryAbility';

    // Top-Bottom Split-Screen Launch:
    // When executing cross-app automation, attempt to open the target app in split screen secondary mode
    // (WINDOW_MODE_SPLIT_SECONDARY) so PiHA remains visible in the top half while the target app is in the bottom half.
    let splitLaunched = false;
    const abilityContext = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (abilityContext && rawBundle !== 'com.shuwei.shellbridge') {
      try {
        const want: Want = {
          bundleName: rawBundle,
          abilityName: ability
        };
        const options: StartOptions = {
          windowMode: AbilityConstant.WindowMode.WINDOW_MODE_SPLIT_SECONDARY,
          withAnimation: true
        };
        await abilityContext.startAbility(want, options);
        splitLaunched = true;
        hilog.info(0x3201, 'UiTool', 'Successfully requested startAbility with WINDOW_MODE_SPLIT_SECONDARY for %{public}s', rawBundle);
      } catch (startErr) {
        hilog.warn(0x3201, 'UiTool', 'startAbility split mode failed: %{public}s, using standard start', JSON.stringify(startErr));
      }
    }

    if (!splitLaunched) {
      // HarmonyOS standard fallback: aa start -b <bundle> -a <ability> -u 100
      const cmd = `aa start -b ${UiTool.shellSingleQuote(rawBundle)} -a ${UiTool.shellSingleQuote(ability)} -u 100`;
      const res = await BridgeController.getInstance().exec(cmd, '', 15);
      if (!res.ok) {
        return UiTool.fail(
          toolCallId,
          `Failed to launch app ${rawBundle}/${ability}: ${res.error.length > 0 ? res.error : `exit ${res.exitCode}`}`,
          res.output
        );
      }
    }

    const feedback = await UiTool.getPostActionScreenFeedback(rawBundle);
    return UiTool.ok(
      toolCallId,
      `Successfully launched application ${rawBundle} (${ability})${splitLaunched ? ' in split-screen mode' : ''}.\n${feedback}`
    );
  }

  private static async handleDumpTree(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const includeAll = args['include_all'] === true;
    const bundleName = typeof args['bundle_name'] === 'string' ? (args['bundle_name'] as string).trim() : undefined;
    const rawLimit = typeof args['limit'] === 'number' ? Math.round(args['limit'] as number) : 100;
    const limit = Math.max(1, Math.min(300, rawLimit));
    const tree = await UiTool.dumpAndParse(includeAll, bundleName);
    const query = UiTool.buildQuery(args);
    const matched = UiLayoutParser.filterNodes(tree.nodes, query);
    let summary = UiLayoutParser.formatSummary(tree, matched, limit);

    if (args['use_ocr'] === true || (matched.length < 3 && args['text'] === undefined && args['contains_text'] === undefined)) {
      try {
        const ocrRes = await PhoneOcr.recognizeScreen();
        if (ocrRes.ok && ocrRes.lines.length > 0) {
          summary += `\n\n${PhoneOcr.formatSummary(ocrRes, 30)}`;
        }
      } catch (_e) {
        // ignore
      }
    }
    return UiTool.ok(toolCallId, summary);
  }

  private static selectMatchedNode(tree: UiTreeParseResult, args: Record<string, Object>): UiNode | null {
    // 0. Direct ref lookup takes immediate highest precedence (@N or N)
    if (args['ref'] !== undefined && args['ref'] !== null) {
      const rawRef = String(args['ref']).trim().replace(/^@/, '');
      const refIdx = parseInt(rawRef, 10);
      if (Number.isFinite(refIdx)) {
        const directNode = tree.nodes.find(n => n.index === refIdx);
        if (directNode) {
          return directNode;
        }
      }
    }

    const query = UiTool.buildQuery(args);
    const hasFilter = (query.text && query.text.trim().length > 0) ||
      (query.containsText && query.containsText.trim().length > 0) ||
      (query.id && query.id.trim().length > 0) ||
      (query.nodeType && query.nodeType.trim().length > 0);
    const index = typeof args['index'] === 'number' && Number.isFinite(args['index'] as number)
      ? Math.max(0, Math.round(args['index'] as number))
      : 0;

    if (!hasFilter) {
      if (args['index'] === undefined) {
        return null;
      }
      return index < tree.nodes.length ? tree.nodes[index] : null;
    }
    const matched = UiLayoutParser.filterNodes(tree.nodes, query);
    if (matched.length > 0) {
      // Prioritize non-input nodes (Text, ListItem, Button) over text inputs (TextInput, SearchField)
      // so searching for a name does NOT accidentally click the search box holding that name!
      if (!query.nodeType || !query.nodeType.toLowerCase().includes('textinput')) {
        matched.sort((a, b) => {
          const aIsInput = a.type === 'TextInput' || a.type === 'TextArea' || a.type === 'SearchField';
          const bIsInput = b.type === 'TextInput' || b.type === 'TextArea' || b.type === 'SearchField';
          if (aIsInput && !bIsInput) return 1;
          if (!aIsInput && bIsInput) return -1;
          return 0;
        });
      }
      if (index < matched.length) {
        return matched[index];
      }
    }

    // --- Smart Semantic Fallbacks using VisualAffordanceEngine ---
    const rawTargetText = (query.text || query.containsText || '').trim().toLowerCase();

    if (rawTargetText.includes('搜索') || rawTargetText.includes('search')) {
      const resolved = VisualAffordanceEngine.resolveAnchor(tree, 'search');
      if (resolved && resolved.matchedNode) {
        return resolved.matchedNode;
      }
      if (resolved) {
        return {
          index: -1,
          text: '搜索(VisualAnchor)',
          hint: '',
          description: '搜索',
          id: '',
          type: 'VisualAnchor',
          bundleName: 'com.tencent.wechat',
          bounds: {
            left: resolved.x - 40,
            top: resolved.y - 40,
            right: resolved.x + 40,
            bottom: resolved.y + 40,
            width: 80,
            height: 80,
            cx: resolved.x,
            cy: resolved.y,
            raw: `[${resolved.x - 40},${resolved.y - 40}][${resolved.x + 40},${resolved.y + 40}]`
          },
          clickable: true,
          scrollable: false,
          enabled: true,
          visible: true,
          depth: 5
        };
      }
    }

    if (rawTargetText.includes('返回') || rawTargetText.includes('back')) {
      const resolved = VisualAffordanceEngine.resolveAnchor(tree, 'back');
      if (resolved && resolved.matchedNode) {
        return resolved.matchedNode;
      }
      if (resolved) {
        return {
          index: -1,
          text: '返回(VisualAnchor)',
          hint: '',
          description: '返回',
          id: '',
          type: 'VisualAnchor',
          bundleName: 'com.tencent.wechat',
          bounds: {
            left: resolved.x - 40,
            top: resolved.y - 40,
            right: resolved.x + 40,
            bottom: resolved.y + 40,
            width: 80,
            height: 80,
            cx: resolved.x,
            cy: resolved.y,
            raw: `[${resolved.x - 40},${resolved.y - 40}][${resolved.x + 40},${resolved.y + 40}]`
          },
          clickable: true,
          scrollable: false,
          enabled: true,
          visible: true,
          depth: 5
        };
      }
    }

    // 3. Relaxed Substring Search (e.g. contact name with suffix/prefix)
    if (rawTargetText.length >= 2) {
      const relaxedMatch = tree.nodes.find(n =>
        n.text.toLowerCase().includes(rawTargetText) ||
        n.description.toLowerCase().includes(rawTargetText) ||
        n.hint.toLowerCase().includes(rawTargetText)
      );
      if (relaxedMatch) {
        return relaxedMatch;
      }
    }

    return null;
  }

  private static async handleFindAndClick(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const bundleName = typeof args['bundle_name'] === 'string' ? (args['bundle_name'] as string).trim() : undefined;
    const tree = await UiTool.dumpAndParse(false, bundleName);
    const target = UiTool.selectMatchedNode(tree, args);
    if (target === null) {
      const query = UiTool.buildQuery(args);
      const hasAnyFilter = Boolean(args['ref'] !== undefined || query.text || query.containsText || query.id || query.nodeType || args['index'] !== undefined);
      if (!hasAnyFilter) {
        return UiTool.fail(toolCallId, 'find_and_click requires at least one selector: ref, text, contains_text, id, type, or index.');
      }
      // On-Device Hardware OCR Fallback:
      // If accessibility tree is incomplete (custom Canvas, Flutter, Unity, or graphic buttons),
      // search for the text via CoreVisionKit OCR and click its exact visual center!
      const queryText = (query.text || query.containsText || '').trim().toLowerCase();
      if (queryText.length > 0) {
        try {
          const ocrRes = await PhoneOcr.recognizeScreen();
          if (ocrRes.ok && ocrRes.lines.length > 0) {
            const matchedLine = ocrRes.lines.find(l => l.text.toLowerCase().includes(queryText));
            if (matchedLine) {
              const mode = typeof args['click_mode'] === 'string' ? args['click_mode'] as string : 'click';
              const clickMsg = await UiTool.runUiClick(matchedLine.cx, matchedLine.cy, mode);
              const feedback = await UiTool.getPostActionScreenFeedback(bundleName, tree);
              return UiTool.ok(
                toolCallId,
                `[CoreVision OCR Match] Clicked text "${matchedLine.text}" at (${matchedLine.cx}, ${matchedLine.cy}) bounds=[${matchedLine.left},${matchedLine.top}][${matchedLine.right},${matchedLine.bottom}] -> ${clickMsg}${feedback}`
              );
            }
          }
        } catch (_ocrErr) {
          // ignore
        }
      }

      const clickablePreview = UiLayoutParser.formatSummary(
        tree,
        UiLayoutParser.filterNodes(tree.nodes, { clickableOnly: true }),
        20
      );
      return UiTool.fail(
        toolCallId,
        'No matching UI element found for find_and_click.' + (bundleName ? ` (filtered to bundle: ${bundleName})` : ''),
        clickablePreview
      );
    }

    const mode = typeof args['click_mode'] === 'string' ? args['click_mode'] as string : 'click';
    const isSendAction = target.text === '发送' || target.description === '发送';
    const clickMsg = await UiTool.runUiClick(target.bounds.cx, target.bounds.cy, mode);

    if (isSendAction) {
      // Dual-guarantee for chat Send buttons: inject hardware touch + soft keyboard Enter key
      // Ensures the message commits even if accessibility focus was held by the virtual keyboard
      try {
        await BridgeController.getInstance().exec(
          `uinput -T -c ${target.bounds.cx} ${target.bounds.cy} >/dev/null 2>&1; uitest uiInput keyEvent 2054 >/dev/null 2>&1`,
          '',
          5
        );
      } catch (_e) {
        // ignore
      }
    }

    const feedback = await UiTool.getPostActionScreenFeedback(bundleName, tree);
    return UiTool.ok(
      toolCallId,
      `Clicked matched node -> ${clickMsg}\nElement: ${UiLayoutParser.formatNodeLine(target)}${feedback}`
    );
  }

  private static async handleClickAnchor(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const anchor = (typeof args['anchor'] === 'string' ? args['anchor'] as string : '').trim();
    if (anchor.length === 0) {
      return UiTool.fail(toolCallId, 'click_anchor requires non-empty "anchor" string (e.g. "search", "back", "more", "chat_input", "voice_toggle", "send").');
    }
    const bundleName = typeof args['bundle_name'] === 'string' ? (args['bundle_name'] as string).trim() : undefined;
    const tree = await UiTool.dumpAndParse(false, bundleName);
    const resolved = VisualAffordanceEngine.resolveAnchor(tree, anchor, bundleName);
    if (!resolved) {
      return UiTool.fail(toolCallId, `Unable to resolve visual anchor "${anchor}" on current screen.`);
    }
    const mode = typeof args['click_mode'] === 'string' ? args['click_mode'] as string : 'click';
    const clickMsg = await UiTool.runUiClick(resolved.x, resolved.y, mode);
    if (anchor.includes('send') || anchor.includes('发送')) {
      try {
        await BridgeController.getInstance().exec('uitest uiInput keyEvent 2054 >/dev/null 2>&1', '', 3);
      } catch (_e) {
        // ignore
      }
    }
    const feedback = await UiTool.getPostActionScreenFeedback(bundleName, tree);
    return UiTool.ok(toolCallId, `[Visual Affordance] ${resolved.label} -> ${clickMsg}${feedback}`);
  }

  private static async handleClickPoint(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const x = args['x'];
    const y = args['y'];
    if (typeof x !== 'number' || typeof y !== 'number' || !Number.isFinite(x) || !Number.isFinite(y)) {
      return UiTool.fail(toolCallId, 'click_point requires numeric x and y coordinates.');
    }
    const bundleName = typeof args['bundle_name'] === 'string' ? (args['bundle_name'] as string).trim() : undefined;
    let beforeTree: UiTreeParseResult | null = null;
    try {
      beforeTree = await UiTool.dumpAndParse(false, bundleName);
    } catch (_e) {
      // ignore
    }
    const mode = typeof args['click_mode'] === 'string' ? args['click_mode'] as string : 'click';
    const clickMsg = await UiTool.runUiClick(x, y, mode);
    const feedback = await UiTool.getPostActionScreenFeedback(bundleName, beforeTree);
    return UiTool.ok(toolCallId, `${clickMsg}${feedback}`);
  }

  private static async handleInputText(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const content = typeof args['content'] === 'string'
      ? (args['content'] as string)
      : (typeof args['text'] === 'string' ? (args['text'] as string) : '');
    if (content.length === 0) {
      return UiTool.fail(toolCallId, 'input_text requires non-empty "content" string.');
    }

    const bundleName = typeof args['bundle_name'] === 'string' ? (args['bundle_name'] as string).trim() : undefined;
    let targetX: number | undefined = typeof args['x'] === 'number' && Number.isFinite(args['x'] as number)
      ? Math.round(args['x'] as number)
      : undefined;
    let targetY: number | undefined = typeof args['y'] === 'number' && Number.isFinite(args['y'] as number)
      ? Math.round(args['y'] as number)
      : undefined;
    let matchedSummary = '';
    let beforeTree: UiTreeParseResult | null = null;

    // Allow focusing an element by selector (text/contains_text/id/type) if x,y weren't passed directly
    if (targetX === undefined || targetY === undefined) {
      const hasSelector = args['ref'] !== undefined ||
        typeof args['id'] === 'string' ||
        typeof args['contains_text'] === 'string' ||
        typeof args['type'] === 'string' ||
        (typeof args['content'] === 'string' && typeof args['text'] === 'string');

      beforeTree = await UiTool.dumpAndParse(false, bundleName);
      const tree = beforeTree;

      if (hasSelector) {
        const node = UiTool.selectMatchedNode(tree, args);
        if (node !== null) {
          targetX = node.bounds.cx;
          targetY = node.bounds.cy;
          matchedSummary = ` into ${UiLayoutParser.formatNodeLine(node)}`;
        }
      }

      // If still no target coordinates, automatically inspect for voice-input mode or editable fields
      if (targetX === undefined || targetY === undefined) {
        const voiceNode = tree.nodes.find(n => n.text === '按住 说话' || n.text.includes('按住说话'));
        if (voiceNode) {
          // WeChat voice mode detected: switch to keyboard text input by clicking the icon to the left of "按住 说话"
          const switchNode = tree.nodes.find(n =>
            n.bounds.cy >= voiceNode.bounds.top - 80 &&
            n.bounds.cy <= voiceNode.bounds.bottom + 80 &&
            n.bounds.cx < voiceNode.bounds.left &&
            n.clickable
          );
          const switchX = switchNode ? switchNode.bounds.cx : Math.max(30, Math.round(voiceNode.bounds.left / 2));
          const switchY = switchNode ? switchNode.bounds.cy : voiceNode.bounds.cy;

          await UiTool.runUiClick(switchX, switchY, 'click');
          // Brief pause for UI transition to text mode
          await new Promise<void>((resolve) => setTimeout(resolve, 350));

          const newTree = await UiTool.dumpAndParse(false, bundleName);
          const inputNode = newTree.nodes.find(n =>
            n.type === 'TextInput' ||
            n.type === 'TextArea' ||
            n.type === 'SearchField' ||
            n.type === 'RichEditor' ||
            n.text.includes('发送消息') ||
            n.hint.includes('发送消息') ||
            (n.bounds.cy >= voiceNode.bounds.top - 80 && n.clickable && n.bounds.cx > 150)
          );
          if (inputNode) {
            targetX = inputNode.bounds.cx;
            targetY = inputNode.bounds.cy;
            matchedSummary = ` (switched from voice mode into ${UiLayoutParser.formatNodeLine(inputNode)})`;
          } else {
            targetX = voiceNode.bounds.cx;
            targetY = voiceNode.bounds.cy;
          }
        } else {
          // Auto-focus standard editable text field if present
          const inputNode = tree.nodes.find(n =>
            n.type === 'TextInput' ||
            n.type === 'TextArea' ||
            n.type === 'SearchField' ||
            n.type === 'RichEditor' ||
            n.id.toLowerCase().includes('editor') ||
            (n.hint && n.hint.length > 0)
          );
          if (inputNode) {
            targetX = inputNode.bounds.cx;
            targetY = inputNode.bounds.cy;
            matchedSummary = ` into auto-detected ${UiLayoutParser.formatNodeLine(inputNode)}`;
          } else {
            // Visual Affordance Fallback for bottom chat input area
            const resolvedAnchor = VisualAffordanceEngine.resolveAnchor(tree, 'chat_input', bundleName);
            if (resolvedAnchor) {
              targetX = resolvedAnchor.x;
              targetY = resolvedAnchor.y;
              matchedSummary = ` into ${resolvedAnchor.label}`;
            }
          }
        }
      }
    }

    const clearFirst = args['clear_first'] !== false;
    if (clearFirst && targetX !== undefined && targetY !== undefined) {
      try {
        // Focus the input field first
        await UiTool.runUiClick(targetX, targetY, 'click');
        await new Promise<void>((resolve) => setTimeout(resolve, 150));
        // Clear any existing text drafts: Ctrl+A then Delete, plus fallback backspace burst
        const clearCmd =
          `uitest uiInput keyEvent 2072 2017 >/dev/null 2>&1; ` +
          `uitest uiInput keyEvent 2055 >/dev/null 2>&1; ` +
          `for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do uitest uiInput keyEvent 2055 >/dev/null 2>&1; done`;
        await BridgeController.getInstance().exec(clearCmd, '', 5);
        await new Promise<void>((resolve) => setTimeout(resolve, 150));
      } catch (_e) {
        // ignore
      }
    }

    const sanitizedText = content.replace(/\r?\n/g, ' ');
    const quoted = UiTool.shellSingleQuote(sanitizedText);
    const cmd = (targetX !== undefined && targetY !== undefined)
      ? `uitest uiInput inputText ${targetX} ${targetY} ${quoted}`
      : `uitest uiInput text ${quoted}`;

    const res = await BridgeController.getInstance().exec(cmd, '', 15);
    if (!res.ok) {
      return UiTool.fail(
        toolCallId,
        res.error.length > 0 ? res.error : `uitest input failed (exit ${res.exitCode})`,
        res.output
      );
    }
    let autoSendMsg = '';
    if (args['auto_send'] === true) {
      await new Promise<void>((resolve) => setTimeout(resolve, 250));
      try {
        await BridgeController.getInstance().exec('uitest uiInput keyEvent 2054 >/dev/null 2>&1', '', 3);
      } catch (_e) {
        // ignore
      }
      try {
        const postTree = await UiTool.dumpAndParse(false, bundleName);
        const sendAnchor = VisualAffordanceEngine.resolveAnchor(postTree, 'send', bundleName);
        if (sendAnchor) {
          await UiTool.runUiClick(sendAnchor.x, sendAnchor.y, 'click');
          autoSendMsg = ` -> [Auto-Sent via ${sendAnchor.label}]`;
        }
      } catch (_e) {
        // ignore
      }
    }

    const coordInfo = (targetX !== undefined && targetY !== undefined) ? ` at (${targetX}, ${targetY})` : ' into focused field';
    const feedback = await UiTool.getPostActionScreenFeedback(bundleName, beforeTree);
    return UiTool.ok(toolCallId, `Typed ${sanitizedText.length} chars${coordInfo}${matchedSummary}${autoSendMsg}${feedback}`);
  }

  private static async handleSwipe(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rawDuration = typeof args['duration_ms'] === 'number' && Number.isFinite(args['duration_ms'] as number)
      ? Math.round(args['duration_ms'] as number)
      : 350;
    const durationMs = Math.max(100, Math.min(3000, rawDuration));

    let x1 = typeof args['x1'] === 'number' ? Math.round(args['x1'] as number) : -1;
    let y1 = typeof args['y1'] === 'number' ? Math.round(args['y1'] as number) : -1;
    let x2 = typeof args['x2'] === 'number' ? Math.round(args['x2'] as number) : -1;
    let y2 = typeof args['y2'] === 'number' ? Math.round(args['y2'] as number) : -1;
    let dirLabel = '';

    if (x1 < 0 || y1 < 0 || x2 < 0 || y2 < 0) {
      const direction = (typeof args['direction'] === 'string' ? args['direction'] as string : '').trim().toLowerCase();
      if (direction !== 'up' && direction !== 'down' && direction !== 'left' && direction !== 'right') {
        return UiTool.fail(toolCallId, 'swipe requires either "direction" (up/down/left/right) or explicit x1, y1, x2, y2.');
      }
      let w = 1080;
      let h = 2400;
      try {
        const tree = await UiTool.dumpAndParse(true);
        w = tree.screenWidth;
        h = tree.screenHeight;
      } catch (_err) {
        // Fallback to standard phone viewport if dumpLayout is temporarily blocked
      }
      if (direction === 'up') {
        x1 = Math.round(w * 0.5);
        y1 = Math.round(h * 0.78);
        x2 = Math.round(w * 0.5);
        y2 = Math.round(h * 0.25);
      } else if (direction === 'down') {
        x1 = Math.round(w * 0.5);
        y1 = Math.round(h * 0.25);
        x2 = Math.round(w * 0.5);
        y2 = Math.round(h * 0.78);
      } else if (direction === 'left') {
        x1 = Math.round(w * 0.85);
        y1 = Math.round(h * 0.5);
        x2 = Math.round(w * 0.15);
        y2 = Math.round(h * 0.5);
      } else {
        x1 = Math.round(w * 0.15);
        y1 = Math.round(h * 0.5);
        x2 = Math.round(w * 0.85);
        y2 = Math.round(h * 0.5);
      }
      dirLabel = ` (${direction} on ${w}x${h})`;
    }

    const cmd = `uinput -T -m ${x1} ${y1} ${x2} ${y2} ${durationMs}`;
    const res = await BridgeController.getInstance().exec(cmd, '', 10);
    if (!res.ok) {
      return UiTool.fail(toolCallId, res.error.length > 0 ? res.error : `Swipe failed (exit ${res.exitCode})`, res.output);
    }
    const bundleName = typeof args['bundle_name'] === 'string' ? (args['bundle_name'] as string).trim() : undefined;
    const feedback = await UiTool.getPostActionScreenFeedback(bundleName);
    return UiTool.ok(toolCallId, `Swiped (${x1},${y1}) -> (${x2},${y2}) in ${durationMs}ms${dirLabel}${feedback}`);
  }

  private static async handleKeyEvent(toolCallId: string, keyName: string, keyCode: number): Promise<ToolResult> {
    let beforeTree: UiTreeParseResult | null = null;
    try {
      beforeTree = await UiTool.dumpAndParse(false);
    } catch (_e) {
      // ignore
    }
    const cmd = `uitest uiInput keyEvent ${keyName} || uinput -K -d ${keyCode} -u ${keyCode}`;
    const res = await BridgeController.getInstance().exec(cmd, '', 10);
    if (!res.ok) {
      return UiTool.fail(toolCallId, res.error.length > 0 ? res.error : `${keyName} key event failed`, res.output);
    }
    const feedback = await UiTool.getPostActionScreenFeedback(undefined, beforeTree);
    return UiTool.ok(toolCallId, `Sent key event: ${keyName}${feedback}`);
  }

  /**
   * Computes the semantic effect of an action by comparing screen signatures before and after.
   * Directly inspired by Mika's Action Effect transition state feedback.
   */
  private static computeActionEffect(before: UiTreeParseResult | null, after: UiTreeParseResult): string {
    if (!before) {
      return '';
    }
    const beforeTexts: string[] = [];
    for (let i = 0; i < before.nodes.length; i++) {
      const t = before.nodes[i].text || before.nodes[i].description || before.nodes[i].hint;
      if (t && t.length > 0) {
        beforeTexts.push(t);
      }
    }

    const afterTexts: string[] = [];
    for (let i = 0; i < after.nodes.length; i++) {
      const t = after.nodes[i].text || after.nodes[i].description || after.nodes[i].hint;
      if (t && t.length > 0) {
        afterTexts.push(t);
      }
    }

    let beforeBundle = '';
    for (let i = 0; i < before.nodes.length; i++) {
      if (before.nodes[i].bundleName.length > 0) {
        beforeBundle = before.nodes[i].bundleName;
        break;
      }
    }
    let afterBundle = '';
    for (let i = 0; i < after.nodes.length; i++) {
      if (after.nodes[i].bundleName.length > 0) {
        afterBundle = after.nodes[i].bundleName;
        break;
      }
    }

    if (beforeBundle.length > 0 && afterBundle.length > 0 && beforeBundle !== afterBundle) {
      return `[ACTION EFFECT]: APP_SWITCHED (${beforeBundle} -> ${afterBundle})`;
    }

    const beforeCount = before.nodes.length;
    const afterCount = after.nodes.length;
    const countDiff = Math.abs(beforeCount - afterCount);

    let sameTextCount = 0;
    for (let i = 0; i < beforeTexts.length; i++) {
      if (afterTexts.includes(beforeTexts[i])) {
        sameTextCount++;
      }
    }
    const maxLen = Math.max(beforeTexts.length, afterTexts.length);
    const textSimilarity = maxLen === 0 ? 1.0 : (sameTextCount / maxLen);

    if (countDiff <= 1 && textSimilarity > 0.95) {
      return `[ACTION EFFECT]: NO_EFFECT (⚠️ 屏幕未发生明显变化！目标可能未响应、坐标稍有偏差或页面正在加载。请勿重复执行完全相同的点击，可尝试锚点、滑动或核对 ref)`;
    }

    if (countDiff > 4 || textSimilarity < 0.6) {
      return `[ACTION EFFECT]: TRANSITIONED (新页面/视图已加载，当前节点数: ${after.nodes.length})`;
    }

    return `[ACTION EFFECT]: CONTENT_UPDATED (界面局部更新/焦点切换)`;
  }

  /**
   * Captures immediate layout feedback after any mutating UI action.
   * Feeds the updated screen state straight back into the LLM context so it can
   * dynamically reassess the goal, verify the state transition, and decide the next step.
   */
  private static async getPostActionScreenFeedback(bundleName?: string, beforeTree?: UiTreeParseResult | null): Promise<string> {
    try {
      await new Promise<void>((resolve) => setTimeout(resolve, 350));
      const tree = await UiTool.dumpAndParse(false, bundleName);
      const interactiveNodes = UiLayoutParser.filterNodes(tree.nodes, { clickableOnly: true });
      const nodesToDisplay = interactiveNodes.length > 0 ? interactiveNodes : tree.nodes;
      const summary = UiLayoutParser.formatSummary(tree, nodesToDisplay, 25);
      const effect = beforeTree ? `\n\n${UiTool.computeActionEffect(beforeTree, tree)}` : '';
      return `${effect}\n\n[新界面实时状态感知 / Post-Action Screen State]:\n${summary}\n\n[动态任务清单调节闭环 / Dynamic Replanning Instruction]:\n动作已执行，屏幕已发生最新变化！请严格按以下步骤推进：\n1. 🎯 [终极目标锚点不变]：确认初始目标保持不变，绝不因中间状态或临时子页面改变目标！\n2. 📱 [核对当前真实状态]：对比上方最新节点与 [ACTION EFFECT]，判断上一步是否达到预期？若显示 NO_EFFECT，立即更换策略！\n3. 📋 [动态调节任务清单]：\n   - 若遇到阻碍（如文字拼接、弹窗），立即动态插入 [!] 补救子任务（例如调用 input_text 自动清空重输，或点击主实例），再收敛回主目标；\n   - 若顺利推进，标记 [x] 完成并推进到下一步 [ ]；\n4. ⚡ [执行下一步动作]：可继续单步推进，或调用 run_sequence 批量一键完成后续确定的动作链！`;
    } catch (_err) {
      return '';
    }
  }

  /**
   * Executes a locally pipelined sequence of UI actions without remote LLM roundtrips.
   * Directly inspired by Mika's phone_run architecture.
   */
  private static async handleRunSequence(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rawSteps = args['steps'];
    if (!Array.isArray(rawSteps) || rawSteps.length === 0) {
      return UiTool.fail(toolCallId, 'run_sequence requires a non-empty "steps" array');
    }
    const steps = rawSteps as Record<string, Object>[];
    if (steps.length > 25) {
      return UiTool.fail(toolCallId, 'run_sequence cannot exceed 25 steps per invocation');
    }

    const bundleName = typeof args['bundle_name'] === 'string' ? (args['bundle_name'] as string).trim() : undefined;
    const executedSteps: string[] = [];
    let stopReason: string | null = null;
    let initialTree: UiTreeParseResult | null = null;
    try {
      initialTree = await UiTool.dumpAndParse(false, bundleName);
    } catch (_e) {
      // ignore
    }

    for (let i = 0; i < steps.length; i++) {
      const step = steps[i];
      const op = typeof step['op'] === 'string' ? (step['op'] as string).trim().toLowerCase() : '';
      const whenText = typeof step['when_text'] === 'string' ? (step['when_text'] as string).trim() : undefined;
      const delayMs = typeof step['delay_ms'] === 'number' ? Math.max(50, Math.min(3000, step['delay_ms'] as number)) : 250;

      // Conditional assertion check before running this step
      if (whenText && whenText.length > 0) {
        try {
          const currentTree = await UiTool.dumpAndParse(false, bundleName);
          const hasText = currentTree.nodes.some(n =>
            n.text.toLowerCase().includes(whenText.toLowerCase()) ||
            n.description.toLowerCase().includes(whenText.toLowerCase()) ||
            n.hint.toLowerCase().includes(whenText.toLowerCase())
          );
          if (!hasText) {
            stopReason = `Step ${i + 1} (${op}) halted: condition 'when_text="${whenText}"' was not visible on screen.`;
            break;
          }
        } catch (e) {
          stopReason = `Step ${i + 1} (${op}) failed checking condition: ${String(e)}`;
          break;
        }
      }

      try {
        switch (op) {
          case 'launch': {
            const pkg = typeof step['bundle_name'] === 'string' ? (step['bundle_name'] as string).trim() : bundleName;
            if (!pkg) {
              stopReason = `Step ${i + 1} (launch) failed: missing bundle_name`;
              break;
            }
            await UiTool.handleLaunchApp(toolCallId, { 'bundle_name': pkg, 'ability_name': step['ability_name'] || 'EntryAbility' });
            executedSteps.push(`[${i + 1}] launch(${pkg}) -> OK`);
            break;
          }
          case 'tap': {
            const currentTree = await UiTool.dumpAndParse(false, bundleName);
            const nodeArgs: Record<string, Object> = {};
            const keys = Object.keys(step);
            for (let k = 0; k < keys.length; k++) {
              nodeArgs[keys[k]] = step[keys[k]];
            }
            if (step['target'] && !nodeArgs['text'] && !nodeArgs['contains_text']) {
              nodeArgs['contains_text'] = step['target'];
            }
            const targetNode = UiTool.selectMatchedNode(currentTree, nodeArgs);
            let clickX = 0;
            let clickY = 0;
            let tapLabel = '';
            if (targetNode) {
              clickX = targetNode.bounds.cx;
              clickY = targetNode.bounds.cy;
              tapLabel = targetNode.text || targetNode.description || targetNode.type;
            } else if (step['target']) {
              // OCR Fallback in run_sequence pipeline
              const targetText = String(step['target']).trim().toLowerCase();
              const ocrRes = await PhoneOcr.recognizeScreen();
              if (ocrRes.ok) {
                const matchedLine = ocrRes.lines.find(l => l.text.toLowerCase().includes(targetText));
                if (matchedLine) {
                  clickX = matchedLine.cx;
                  clickY = matchedLine.cy;
                  tapLabel = `OCR:"${matchedLine.text}"`;
                }
              }
            }
            if (clickX === 0 && clickY === 0) {
              stopReason = `Step ${i + 1} (tap) halted: target node '${step['target'] || step['ref'] || 'unknown'}' not found by tree or OCR.`;
              break;
            }
            await UiTool.runUiClick(clickX, clickY, 'click');
            executedSteps.push(`[${i + 1}] tap('${tapLabel}' @(${clickX},${clickY})) -> OK`);
            break;
          }
          case 'click_anchor': {
            const anchor = typeof step['anchor'] === 'string' ? (step['anchor'] as string).trim() : '';
            const currentTree = await UiTool.dumpAndParse(false, bundleName);
            const resolved = VisualAffordanceEngine.resolveAnchor(currentTree, anchor, bundleName);
            if (!resolved) {
              stopReason = `Step ${i + 1} (click_anchor) halted: anchor '${anchor}' could not be resolved.`;
              break;
            }
            await UiTool.runUiClick(resolved.x, resolved.y, 'click');
            executedSteps.push(`[${i + 1}] click_anchor('${anchor}' @(${resolved.x},${resolved.y})) -> OK`);
            break;
          }
          case 'type': {
            const content = typeof step['text'] === 'string' ? (step['text'] as string) : (typeof step['content'] === 'string' ? step['content'] as string : '');
            const autoSend = step['auto_send'] === true;
            const inputArgs: Record<string, Object> = {
              'content': content,
              'auto_send': autoSend,
              'clear_first': step['clear_first'] !== false
            };
            if (bundleName) {
              inputArgs['bundle_name'] = bundleName;
            }
            if (step['ref']) {
              inputArgs['ref'] = step['ref'];
            }
            if (step['target']) {
              inputArgs['contains_text'] = step['target'];
            }
            const res = await UiTool.handleInputText(toolCallId, inputArgs);
            if (res.isError) {
              stopReason = `Step ${i + 1} (type) failed: ${res.error}`;
              break;
            }
            executedSteps.push(`[${i + 1}] type("${content}", auto_send=${autoSend}) -> OK`);
            break;
          }
          case 'key': {
            const keyName = typeof step['key'] === 'string' ? (step['key'] as string).trim() : 'Back';
            await BridgeController.getInstance().exec(`uitest uiInput keyEvent ${keyName}`, '', 10);
            executedSteps.push(`[${i + 1}] key(${keyName}) -> OK`);
            break;
          }
          case 'back': {
            await BridgeController.getInstance().exec(`uitest uiInput keyEvent Back`, '', 10);
            executedSteps.push(`[${i + 1}] back() -> OK`);
            break;
          }
          case 'scroll': {
            const dir = typeof step['direction'] === 'string' ? (step['direction'] as string).toLowerCase() : 'down';
            await UiTool.handleSwipe(toolCallId, { 'direction': dir });
            executedSteps.push(`[${i + 1}] scroll(${dir}) -> OK`);
            break;
          }
          case 'wait': {
            const waitTarget = typeof step['target'] === 'string' ? (step['target'] as string).trim() : '';
            const timeoutMs = typeof step['timeout_ms'] === 'number' ? Math.max(100, Math.min(10000, step['timeout_ms'] as number)) : 2000;
            if (waitTarget.length > 0) {
              const startT = Date.now();
              let found = false;
              while (Date.now() - startT < timeoutMs) {
                await new Promise<void>((r) => setTimeout(r, 400));
                const tree = await UiTool.dumpAndParse(false, bundleName);
                if (tree.nodes.some(n => n.text.includes(waitTarget) || n.description.includes(waitTarget))) {
                  found = true;
                  break;
                }
              }
              if (!found) {
                stopReason = `Step ${i + 1} (wait) timed out waiting for '${waitTarget}'`;
                break;
              }
            } else {
              await new Promise<void>((r) => setTimeout(r, timeoutMs));
            }
            executedSteps.push(`[${i + 1}] wait(${waitTarget || timeoutMs + 'ms'}) -> OK`);
            break;
          }
          case 'assert': {
            const assertText = typeof step['target'] === 'string' ? (step['target'] as string) : (step['text'] as string || '');
            const currentTree = await UiTool.dumpAndParse(false, bundleName);
            const exists = currentTree.nodes.some(n => n.text.includes(assertText) || n.description.includes(assertText));
            if (!exists) {
              stopReason = `Step ${i + 1} (assert) failed: '${assertText}' is not visible on screen.`;
              break;
            }
            executedSteps.push(`[${i + 1}] assert('${assertText}') -> OK`);
            break;
          }
          default: {
            stopReason = `Step ${i + 1} unknown op: '${op}'`;
            break;
          }
        }
      } catch (err) {
        stopReason = `Step ${i + 1} (${op}) threw exception: ${String(err)}`;
        break;
      }

      if (stopReason) {
        break;
      }

      if (i < steps.length - 1 && delayMs > 0) {
        await new Promise<void>((r) => setTimeout(r, delayMs));
      }
    }

    const postFeedback = await UiTool.getPostActionScreenFeedback(bundleName, initialTree);
    const summaryHeader = stopReason
      ? `⚠️ [SEQUENCE STOPPED EARLY] ${stopReason}\nCompleted ${executedSteps.length} of ${steps.length} steps.`
      : `✅ [SEQUENCE COMPLETED] Successfully executed all ${steps.length} steps in 1 local turn!`;

    const fullOutput = `${summaryHeader}\n\nExecution Log:\n${executedSteps.join('\n')}${postFeedback}`;
    if (stopReason) {
      return UiTool.fail(toolCallId, stopReason, fullOutput);
    }
    return UiTool.ok(toolCallId, fullOutput);
  }

  private static async handleOcr(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rawLimit = typeof args['limit'] === 'number' ? Math.round(args['limit'] as number) : 60;
    const limit = Math.max(1, Math.min(200, rawLimit));
    const result = await PhoneOcr.recognizeScreen();
    if (!result.ok) {
      return UiTool.fail(toolCallId, result.error ?? 'CoreVision OCR recognition failed');
    }
    return UiTool.ok(toolCallId, PhoneOcr.formatSummary(result, limit));
  }
}
