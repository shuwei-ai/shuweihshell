/*
 * Pi-Agent Browser Tool for HarmonyOS.
 * Provides web browsing, readability content extraction, interactive element inspection,
 * form typing, element clicking, and JavaScript evaluation via ArkWeb and Chrome DevTools Protocol.
 */
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { BrowserManager, ClickOptions, TypeOptions } from '../../browser/BrowserManager';

export class BrowserTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'action': new ToolProperty(
        'string',
        'Action to perform: "navigate" (open URL), "snapshot" (extract page content & elements), "click" (click element by index or selector), "type" (input text into form field), "evaluate" (run JS script), "extract_text" (quick clean text extraction), "wechat_publish" (format and publish article to WeChat Official Account draft via ArkWeb CDP).'
      ),
      'url': new ToolProperty('string', 'Target URL to visit (for action: "navigate").'),
      'mode': new ToolProperty('string', 'Snapshot mode: "text" (clean text only), "interactive" (numbered clickable/input elements), or "both" (default).'),
      'selector': new ToolProperty('string', 'CSS selector of the target element (for action: "click" or "type").'),
      'index': new ToolProperty('number', 'Numeric index of the element from previous snapshot [1], [2], ... (for action: "click" or "type").'),
      'text': new ToolProperty('string', 'Text to type into the field (for action: "type").'),
      'script': new ToolProperty('string', 'JavaScript code to execute in the page context (for action: "evaluate").'),
      'timeoutMs': new ToolProperty('number', 'Timeout in milliseconds for navigation (default: 15000).'),
      'title': new ToolProperty('string', 'Article title for WeChat Official Account (required for action: "wechat_publish", max 64 chars).'),
      'content': new ToolProperty('string', 'Article body in Markdown or HTML (required for action: "wechat_publish"). Auto-styled for WeChat.'),
      'author': new ToolProperty('string', 'Author name for the WeChat article (optional for action: "wechat_publish").'),
      'summary': new ToolProperty('string', 'Digest/summary for the WeChat article (optional for action: "wechat_publish", max 120 chars).'),
      'themeColor': new ToolProperty('string', 'Theme color for WeChat formatting (optional: "blue", "green", "orange", "purple", "vermilion", or hex like "#2b5aed").')
    };

    const params = new ToolParameters(props, ['action']);
    const func = new ToolFunctionDefinition(
      'browser',
      'Control the built-in ArkWeb browser on the device via CDP. Allows navigating to webpages, extracting high-signal readable text, listing clickable interactive elements, clicking buttons/links by index, filling form inputs, and evaluating JavaScript expressions.',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const action = ((args['action'] as string) ?? '').toLowerCase().trim();
    const bm = BrowserManager.getInstance();

    if (!action) {
      return {
        toolCallId: toolCallId,
        toolName: 'browser',
        output: '',
        error: 'Missing required argument: action ("navigate" | "snapshot" | "click" | "type" | "evaluate" | "extract_text")',
        isError: true
      };
    }

    try {
      switch (action) {
        case 'navigate': {
          const url = (args['url'] as string) ?? '';
          if (!url) {
            return {
              toolCallId: toolCallId,
              toolName: 'browser',
              output: '',
              error: 'Missing required "url" parameter for action "navigate"',
              isError: true
            };
          }
          const timeout = typeof args['timeoutMs'] === 'number' ? (args['timeoutMs'] as number) : 15000;
          const navResult = await bm.navigate(url, timeout);

          // After navigation, automatically take a text snapshot to provide immediate context to the model
          const snapshot = await bm.snapshot('both');
          let outputText = `Successfully navigated to: ${navResult.url}\nTitle: ${navResult.title}\nLoad time: ${navResult.durationMs}ms\n\n`;

          if (snapshot.text && snapshot.text.trim().length > 0) {
            outputText += `--- Page Content Summary ---\n${snapshot.text.substring(0, 4000)}\n\n`;
          }

          if (snapshot.elements && snapshot.elements.length > 0) {
            outputText += `--- Key Interactive Elements (${snapshot.elements.length} found) ---\n`;
            const maxShow = Math.min(snapshot.elements.length, 30);
            for (let i = 0; i < maxShow; i++) {
              const el = snapshot.elements[i];
              let desc = `[${el.idx}] <${el.tag}`;
              if (el.type) desc += ` type="${el.type}"`;
              desc += `> ${el.label || el.href || ''}`;
              outputText += `${desc}\n`;
            }
            if (snapshot.elements.length > maxShow) {
              outputText += `... and ${snapshot.elements.length - maxShow} more elements. Call action: "snapshot", mode: "interactive" to see all.\n`;
            }
          }

          return {
            toolCallId: toolCallId,
            toolName: 'browser',
            output: outputText.trim(),
            isError: false
          };
        }

        case 'snapshot':
        case 'extract_text': {
          let mode: 'text' | 'interactive' | 'both' = 'both';
          if (action === 'extract_text' || args['mode'] === 'text') {
            mode = 'text';
          } else if (args['mode'] === 'interactive') {
            mode = 'interactive';
          }

          const snapshot = await bm.snapshot(mode);
          if (snapshot.error) {
            return {
              toolCallId: toolCallId,
              toolName: 'browser',
              output: '',
              error: snapshot.error,
              isError: true
            };
          }

          let out = `Page: ${snapshot.title} (${snapshot.url})\n\n`;
          if (snapshot.text) {
            out += `--- Clean Text Content ---\n${snapshot.text}\n\n`;
          }

          if (snapshot.elements && snapshot.elements.length > 0) {
            out += `--- Interactive Elements (${snapshot.elements.length}) ---\n`;
            for (let i = 0; i < snapshot.elements.length; i++) {
              const el = snapshot.elements[i];
              let desc = `[${el.idx}] <${el.tag}`;
              if (el.type) desc += ` type="${el.type}"`;
              desc += `> ${el.label || el.href || ''}`;
              out += `${desc}\n`;
            }
          }

          return {
            toolCallId: toolCallId,
            toolName: 'browser',
            output: out.trim(),
            isError: false
          };
        }

        case 'click': {
          const selector = args['selector'] as string | undefined;
          const index = typeof args['index'] === 'number' ? (args['index'] as number) : undefined;
          const x = typeof args['x'] === 'number' ? (args['x'] as number) : undefined;
          const y = typeof args['y'] === 'number' ? (args['y'] as number) : undefined;

          const clickOpts: ClickOptions = {
            selector: selector,
            index: index,
            x: x,
            y: y
          };
          const res = await bm.click(clickOpts);
          return {
            toolCallId: toolCallId,
            toolName: 'browser',
            output: res.message,
            isError: !res.success
          };
        }

        case 'type': {
          const selector = args['selector'] as string | undefined;
          const index = typeof args['index'] === 'number' ? (args['index'] as number) : undefined;
          const text = (args['text'] as string) ?? '';

          if (text.length === 0) {
            return {
              toolCallId: toolCallId,
              toolName: 'browser',
              output: '',
              error: 'Missing "text" parameter for action "type"',
              isError: true
            };
          }

          const typeOpts: TypeOptions = {
            selector: selector,
            index: index,
            text: text
          };
          const res = await bm.type(typeOpts);
          return {
            toolCallId: toolCallId,
            toolName: 'browser',
            output: res.message,
            isError: !res.success
          };
        }

        case 'evaluate': {
          const script = (args['script'] as string) ?? '';
          if (!script) {
            return {
              toolCallId: toolCallId,
              toolName: 'browser',
              output: '',
              error: 'Missing "script" parameter for action "evaluate"',
              isError: true
            };
          }

          const res = await bm.evaluate(script);
          return {
            toolCallId: toolCallId,
            toolName: 'browser',
            output: typeof res === 'string' ? res : JSON.stringify(res),
            isError: false
          };
        }

        case 'wechat_publish': {
          const title = ((args['title'] as string) ?? '').trim();
          const content = (args['content'] as string) ?? '';
          const author = args['author'] as string | undefined;
          const summary = args['summary'] as string | undefined;
          const themeColor = args['themeColor'] as string | undefined;

          if (!title) {
            return {
              toolCallId: toolCallId,
              toolName: 'browser',
              output: '',
              error: 'Missing required "title" parameter for action "wechat_publish"',
              isError: true
            };
          }

          if (!content) {
            return {
              toolCallId: toolCallId,
              toolName: 'browser',
              output: '',
              error: 'Missing required "content" parameter for action "wechat_publish"',
              isError: true
            };
          }

          const pubRes = await bm.publishWechatArticle({
            title: title,
            content: content,
            author: author,
            summary: summary,
            themeColor: themeColor
          });

          return {
            toolCallId: toolCallId,
            toolName: 'browser',
            output: pubRes.message,
            isError: !pubRes.success && pubRes.status !== 'need_login'
          };
        }

        default:
          return {
            toolCallId: toolCallId,
            toolName: 'browser',
            output: '',
            error: `Unknown browser action: "${action}". Valid actions: "navigate", "snapshot", "click", "type", "evaluate", "extract_text", "wechat_publish"`,
            isError: true
          };
      }
    } catch (err) {
      return {
        toolCallId: toolCallId,
        toolName: 'browser',
        output: '',
        error: `Browser tool execution error: ${err}`,
        isError: true
      };
    }
  }
}
