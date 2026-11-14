/*
 * WechatStyler: Formats Markdown or plain text into WeChat Official Account compatible HTML with inline styles.
 * Adapted from baoyu-post-to-wechat (baoyu-md theme system) for HarmonyOS ArkWeb / ProseMirror editor.
 */

export interface WechatThemeConfig {
  primaryColor: string;
  secondaryColor: string;
  textColor: string;
  bgColor: string;
  quoteBg: string;
  codeBg: string;
}

export interface WechatCitation {
  index: number;
  text: string;
  url: string;
}

export interface InlineTypographyResult {
  html: string;
  citationsAdded: number;
}

export class WechatStyler {
  /**
   * Resolves a named color preset or hex code to a standard hex color string.
   */
  static resolveColor(nameOrHex?: string): string {
    if (!nameOrHex) {
      return '#2b5aed'; // WeChat classic blue
    }
    const val = nameOrHex.trim().toLowerCase();
    if (val.startsWith('#')) {
      return val;
    }
    switch (val) {
      case 'green':
        return '#07c160'; // WeChat classic green
      case 'blue':
        return '#2b5aed'; // Elegant blue
      case 'sky':
        return '#0284c7'; // Sky blue
      case 'vermilion':
      case 'red':
        return '#fa5151'; // Vibrant red
      case 'orange':
        return '#ff8200'; // Warm orange
      case 'yellow':
        return '#e6a23c'; // Gold yellow
      case 'purple':
        return '#722ed1'; // Tech purple
      case 'rose':
        return '#e11d48'; // Rose
      case 'black':
        return '#1f2937'; // Slate black
      case 'gray':
        return '#4b5563'; // Cool gray
      default:
        return '#2b5aed';
    }
  }

  /**
   * Generates a complete inline-styled HTML string ready for injection into WeChat's ProseMirror editor.
   */
  static markdownToWechatHtml(markdown: string, colorPresetOrHex?: string): string {
    if (!markdown || markdown.trim().length === 0) {
      return '<p></p>';
    }

    const primaryColor = WechatStyler.resolveColor(colorPresetOrHex);

    // If input is already full HTML, wrap with consistent WeChat container
    if (markdown.trim().startsWith('<section') || markdown.trim().startsWith('<div') || markdown.trim().startsWith('<article')) {
      return markdown.trim();
    }

    const lines = markdown.split('\n');
    const htmlParts: string[] = [];
    const citations: WechatCitation[] = [];
    let citeCounter = 1;

    let inCodeBlock = false;
    let codeLanguage = '';
    let codeBuffer: string[] = [];

    let inList = false;
    let listType: 'ul' | 'ol' = 'ul';
    let listBuffer: string[] = [];

    const flushList = () => {
      if (inList && listBuffer.length > 0) {
        const tag = listType;
        const listItemsHtml = listBuffer.map(item =>
          `<li style="margin: 6px 0; line-height: 1.75; font-size: 15px; color: #3f3f3f;">${item}</li>`
        ).join('');
        htmlParts.push(`<${tag} style="margin: 14px 0 14px 24px; padding-left: 0; color: #3f3f3f;">${listItemsHtml}</${tag}>`);
        listBuffer = [];
        inList = false;
      }
    };

    const flushCodeBlock = () => {
      if (inCodeBlock) {
        const rawCode = codeBuffer.join('\n');
        const escapedCode = WechatStyler.escapeHtml(rawCode);
        htmlParts.push(
          `<pre style="background: #282c34; color: #abb2bf; padding: 14px 16px; border-radius: 8px; margin: 16px 0; font-family: Consolas, Monaco, 'Courier New', monospace; font-size: 13px; line-height: 1.6; overflow-x: auto; white-space: pre-wrap; word-break: break-all;"><code>${escapedCode}</code></pre>`
        );
        codeBuffer = [];
        inCodeBlock = false;
      }
    };

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Code block toggles
      if (trimmed.startsWith('```')) {
        flushList();
        if (inCodeBlock) {
          flushCodeBlock();
        } else {
          inCodeBlock = true;
          codeLanguage = trimmed.substring(3).trim();
          codeBuffer = [];
        }
        continue;
      }

      if (inCodeBlock) {
        codeBuffer.push(line);
        continue;
      }

      // Empty lines
      if (trimmed.length === 0) {
        flushList();
        continue;
      }

      // Headings
      if (trimmed.startsWith('#')) {
        flushList();
        let level = 0;
        while (level < trimmed.length && trimmed[level] === '#') {
          level++;
        }
        const text = trimmed.substring(level).trim();
        const styledText = WechatStyler.formatInlineTypography(text, primaryColor, citations, citeCounter);
        citeCounter += styledText.citationsAdded;

        if (level === 1) {
          htmlParts.push(
            `<h1 style="font-size: 22px; font-weight: bold; color: #111827; margin: 28px 0 16px 0; padding-bottom: 8px; border-bottom: 2px solid ${primaryColor}; line-height: 1.4;">${styledText.html}</h1>`
          );
        } else if (level === 2) {
          htmlParts.push(
            `<h2 style="display: flex; align-items: center; font-size: 18px; font-weight: bold; color: #1f2937; margin: 24px 0 14px 0; line-height: 1.4;"><span style="display: inline-block; width: 4px; height: 18px; background-color: ${primaryColor}; border-radius: 2px; margin-right: 8px;"></span><span>${styledText.html}</span></h2>`
          );
        } else if (level === 3) {
          htmlParts.push(
            `<h3 style="font-size: 16px; font-weight: bold; color: ${primaryColor}; margin: 20px 0 10px 0; line-height: 1.4;">${styledText.html}</h3>`
          );
        } else {
          htmlParts.push(
            `<h4 style="font-size: 15px; font-weight: bold; color: #374151; margin: 16px 0 8px 0; line-height: 1.4;">${styledText.html}</h4>`
          );
        }
        continue;
      }

      // Blockquotes
      if (trimmed.startsWith('>')) {
        flushList();
        const quoteText = trimmed.substring(1).trim();
        const styledText = WechatStyler.formatInlineTypography(quoteText, primaryColor, citations, citeCounter);
        citeCounter += styledText.citationsAdded;
        htmlParts.push(
          `<blockquote style="border-left: 4px solid ${primaryColor}; background: #f8fafc; padding: 12px 16px; margin: 16px 0; color: #475569; font-size: 14px; line-height: 1.7; border-radius: 0 6px 6px 0;">${styledText.html}</blockquote>`
        );
        continue;
      }

      // Horizontal rules
      if (trimmed === '---' || trimmed === '***' || trimmed === '___') {
        flushList();
        htmlParts.push(
          `<hr style="border: none; border-top: 1px dashed #cbd5e1; margin: 24px 0;" />`
        );
        continue;
      }

      // Unordered list
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || trimmed.startsWith('+ ')) {
        if (!inList || listType !== 'ul') {
          flushList();
          inList = true;
          listType = 'ul';
        }
        const itemText = trimmed.substring(2).trim();
        const styled = WechatStyler.formatInlineTypography(itemText, primaryColor, citations, citeCounter);
        citeCounter += styled.citationsAdded;
        listBuffer.push(styled.html);
        continue;
      }

      // Ordered list
      const numMatch = trimmed.match(/^(\d+)\.\s+(.*)$/);
      if (numMatch) {
        if (!inList || listType !== 'ol') {
          flushList();
          inList = true;
          listType = 'ol';
        }
        const itemText = numMatch[2].trim();
        const styled = WechatStyler.formatInlineTypography(itemText, primaryColor, citations, citeCounter);
        citeCounter += styled.citationsAdded;
        listBuffer.push(styled.html);
        continue;
      }

      // Normal paragraph
      flushList();
      const styledParagraph = WechatStyler.formatInlineTypography(trimmed, primaryColor, citations, citeCounter);
      citeCounter += styledParagraph.citationsAdded;
      htmlParts.push(
        `<p style="margin: 14px 0; line-height: 1.8; font-size: 15px; color: #333333; letter-spacing: 0.5px; text-align: justify; word-break: break-word;">${styledParagraph.html}</p>`
      );
    }

    // Flush any pending blocks
    flushList();
    flushCodeBlock();

    // Append citations / footnotes if any external links were discovered
    if (citations.length > 0) {
      htmlParts.push(
        `<div style="margin-top: 36px; padding-top: 16px; border-top: 1px solid #e2e8f0; font-size: 13px; color: #64748b;">` +
        `<p style="font-weight: bold; margin-bottom: 8px; color: #334155;">参考链接：</p>` +
        citations.map(c =>
          `<p style="margin: 4px 0; word-break: break-all;">[${c.index}] ${WechatStyler.escapeHtml(c.text)}: <span style="color: ${primaryColor};">${WechatStyler.escapeHtml(c.url)}</span></p>`
        ).join('') +
        `</div>`
      );
    }

    return `<section style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; max-width: 100%; box-sizing: border-box; overflow-wrap: break-word;">${htmlParts.join('\n')}</section>`;
  }

  /**
   * Formats inline Markdown patterns: bold (**), italic (*), code (`), and links ([text](url)).
   */
  private static formatInlineTypography(
    text: string,
    primaryColor: string,
    citations: WechatCitation[],
    startCiteIndex: number
  ): InlineTypographyResult {
    let result = WechatStyler.escapeHtml(text);
    let currentCite = startCiteIndex;
    let added = 0;

    // Inline code: `code`
    result = result.replace(new RegExp('`([^`]+)`', 'g'), (match: string, p1: string): string => {
      return `<code style="background-color: #f1f5f9; color: #e11d48; padding: 2px 5px; margin: 0 2px; border-radius: 4px; font-family: Consolas, Monaco, monospace; font-size: 13px;">${p1}</code>`;
    });

    // Bold: **text**
    result = result.replace(new RegExp('\\*\\*([^*]+)\\*\\*', 'g'), (match: string, p1: string): string => {
      return `<strong style="font-weight: bold; color: #111827;">${p1}</strong>`;
    });

    // Italic: *text*
    result = result.replace(new RegExp('\\*([^*]+)\\*', 'g'), (match: string, p1: string): string => {
      return `<em style="font-style: italic; color: #475569;">${p1}</em>`;
    });

    // Links: [label](url) -> converted to citation footnote for WeChat compliance
    result = result.replace(new RegExp('\\[([^\\]]+)\\]\\(([^)]+)\\)', 'g'), (match: string, label: string, url: string): string => {
      const cit: WechatCitation = { index: currentCite, text: label, url: url };
      citations.push(cit);
      const footnote = `<sup style="color: ${primaryColor}; font-weight: bold; margin-left: 2px;">[${currentCite}]</sup>`;
      currentCite++;
      added++;
      return `<span style="color: ${primaryColor}; text-decoration: underline; text-underline-offset: 3px;">${label}</span>${footnote}`;
    });

    const res: InlineTypographyResult = { html: result, citationsAdded: added };
    return res;
  }

  private static escapeHtml(str: string): string {
    return str
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }
}
