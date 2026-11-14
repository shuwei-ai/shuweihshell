/*
 * Native ArkUI Markdown Renderer for HarmonyOS.
 * Renders structured markdown including:
 * - Code blocks with language tags and one-click copy button
 * - Formatted tabular data with headers, grid borders, and horizontal scrolling
 * - Headings (H1 - H4)
 * - Ordered & unordered lists
 * - Blockquotes with accent borders
 * - Inline formatting: bold (**), italic (*), and inline code (`)
 */
import promptAction from '@ohos.promptAction';
import pasteboard from '@ohos.pasteboard';

export class InlineSpan {
  text: string = '';
  isBold: boolean = false;
  isItalic: boolean = false;
  isCode: boolean = false;

  constructor(text: string, isBold: boolean = false, isItalic: boolean = false, isCode: boolean = false) {
    this.text = text;
    this.isBold = isBold;
    this.isItalic = isItalic;
    this.isCode = isCode;
  }
}

export class MarkdownBlock {
  type: string = 'paragraph';
  level: number = 0;
  spans: InlineSpan[] = [];
  language: string = '';
  codeLines: string[] = [];
  isOrdered: boolean = false;
  listNumber: number = 0;
  tableHeaders: InlineSpan[][] = [];
  tableRows: InlineSpan[][][] = [];
  tableAlignments: TextAlign[] = [];
  tableColWidths: number[] = [];
}

export function parseInlineSpans(text: string): InlineSpan[] {
  const result: InlineSpan[] = [];
  if (!text || text.length === 0) {
    return result;
  }

  const regex = /(`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*)/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null = null;

  while ((match = regex.exec(text)) !== null) {
    if (match.index > lastIndex) {
      result.push(new InlineSpan(text.substring(lastIndex, match.index), false, false, false));
    }

    const matchedStr = match[0];
    if (matchedStr.startsWith('`') && matchedStr.endsWith('`')) {
      result.push(new InlineSpan(matchedStr.substring(1, matchedStr.length - 1), false, false, true));
    } else if (matchedStr.startsWith('**') && matchedStr.endsWith('**')) {
      result.push(new InlineSpan(matchedStr.substring(2, matchedStr.length - 2), true, false, false));
    } else if (matchedStr.startsWith('*') && matchedStr.endsWith('*')) {
      result.push(new InlineSpan(matchedStr.substring(1, matchedStr.length - 1), false, true, false));
    }

    lastIndex = match.index + matchedStr.length;
  }

  if (lastIndex < text.length) {
    result.push(new InlineSpan(text.substring(lastIndex), false, false, false));
  }

  return result;
}

export function parseMarkdownBlocks(rawText: string): MarkdownBlock[] {
  const blocks: MarkdownBlock[] = [];
  if (!rawText || rawText.trim().length === 0) {
    return blocks;
  }

  const lines = rawText.split('\n');
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    // 1. Empty lines
    if (trimmed.length === 0) {
      i++;
      continue;
    }

    // 2. Fenced code block (```lang ... ```)
    if (trimmed.startsWith('```')) {
      const lang = trimmed.substring(3).trim();
      const codeLines: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        codeLines.push(lines[i]);
        i++;
      }
      if (i < lines.length) {
        i++; // skip closing ```
      }
      const b = new MarkdownBlock();
      b.type = 'code_block';
      b.language = lang.length > 0 ? lang : 'TEXT';
      b.codeLines = codeLines;
      blocks.push(b);
      continue;
    }

    // 3. Table detection (| col1 | col2 |)
    const isTableSeparator = (l: string): boolean => {
      const s = l.trim();
      return s.includes('|') && /^\|?[\s\-:]+(\|[\s\-:]+)+\|?$/.test(s);
    };

    if (trimmed.includes('|') && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      const headerLine = trimmed;
      const rawHeaderCells = headerLine.split('|');
      // Remove first/last empty elements from outer pipes
      if (rawHeaderCells.length > 0 && rawHeaderCells[0].trim().length === 0) {
        rawHeaderCells.shift();
      }
      if (rawHeaderCells.length > 0 && rawHeaderCells[rawHeaderCells.length - 1].trim().length === 0) {
        rawHeaderCells.pop();
      }

      const tableHeaders: InlineSpan[][] = rawHeaderCells.map((cell: string) => parseInlineSpans(cell.trim()));

      // Parse column alignments from separator line (lines[i + 1])
      const sepLine = lines[i + 1].trim();
      const rawSepCells = sepLine.split('|');
      if (rawSepCells.length > 0 && rawSepCells[0].trim().length === 0) {
        rawSepCells.shift();
      }
      if (rawSepCells.length > 0 && rawSepCells[rawSepCells.length - 1].trim().length === 0) {
        rawSepCells.pop();
      }

      const tableAlignments: TextAlign[] = rawSepCells.map((sep: string): TextAlign => {
        const s = sep.trim();
        const startsWithColon = s.startsWith(':');
        const endsWithColon = s.endsWith(':');
        if (startsWithColon && endsWithColon) {
          return TextAlign.Center;
        } else if (endsWithColon) {
          return TextAlign.End;
        }
        return TextAlign.Start;
      });

      i += 2; // skip header and separator line

      const tableRows: InlineSpan[][][] = [];
      while (i < lines.length) {
        const rowLine = lines[i].trim();
        if (rowLine.length === 0 || !rowLine.includes('|')) {
          break;
        }
        const rawRowCells = rowLine.split('|');
        if (rawRowCells.length > 0 && rawRowCells[0].trim().length === 0) {
          rawRowCells.shift();
        }
        if (rawRowCells.length > 0 && rawRowCells[rawRowCells.length - 1].trim().length === 0) {
          rawRowCells.pop();
        }

        const rowCells: InlineSpan[][] = rawRowCells.map((cell: string) => parseInlineSpans(cell.trim()));
        tableRows.push(rowCells);
        i++;
      }

      let maxCols = tableHeaders.length;
      for (let r = 0; r < tableRows.length; r++) {
        if (tableRows[r].length > maxCols) {
          maxCols = tableRows[r].length;
        }
      }

      const tableColWidths: number[] = [];
      for (let c = 0; c < maxCols; c++) {
        let maxLen = 0;
        if (c < rawHeaderCells.length && rawHeaderCells[c]) {
          maxLen = Math.max(maxLen, rawHeaderCells[c].trim().length);
        }
        for (let r = 0; r < tableRows.length; r++) {
          if (c < tableRows[r].length) {
            const cellText = tableRows[r][c].map((s: InlineSpan) => s.text).join('');
            if (cellText.length > maxLen) {
              maxLen = cellText.length;
            }
          }
        }
        // Approximate width: 12px per char + 24px padding, bounded between 80 and 320
        const colW = Math.max(80, Math.min(320, maxLen * 12 + 24));
        tableColWidths.push(colW);
      }

      const b = new MarkdownBlock();
      b.type = 'table';
      b.tableHeaders = tableHeaders;
      b.tableRows = tableRows;
      b.tableAlignments = tableAlignments;
      b.tableColWidths = tableColWidths;
      blocks.push(b);
      continue;
    }

    // 4. Horizontal dividers (---, ***, ___)
    if (/^(\-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      const b = new MarkdownBlock();
      b.type = 'divider';
      blocks.push(b);
      i++;
      continue;
    }

    // 5. Headings (# H1, ## H2, ### H3, #### H4)
    const headingMatch = /^(#{1,6})\s+(.*)$/.exec(trimmed);
    if (headingMatch) {
      const b = new MarkdownBlock();
      b.type = 'heading';
      b.level = headingMatch[1].length;
      b.spans = parseInlineSpans(headingMatch[2]);
      blocks.push(b);
      i++;
      continue;
    }

    // 6. Blockquote (> quote)
    const quoteMatch = /^>\s?(.*)$/.exec(trimmed);
    if (quoteMatch) {
      const b = new MarkdownBlock();
      b.type = 'blockquote';
      b.spans = parseInlineSpans(quoteMatch[1]);
      blocks.push(b);
      i++;
      continue;
    }

    // 7. Ordered List (1. item)
    const orderedMatch = /^(\d+)\.\s+(.*)$/.exec(trimmed);
    if (orderedMatch) {
      const b = new MarkdownBlock();
      b.type = 'list_item';
      b.isOrdered = true;
      b.listNumber = Number(orderedMatch[1]);
      b.spans = parseInlineSpans(orderedMatch[2]);
      blocks.push(b);
      i++;
      continue;
    }

    // 8. Unordered List (- item, * item, + item)
    const unorderedMatch = /^[\*\-\+]\s+(.*)$/.exec(trimmed);
    if (unorderedMatch) {
      const b = new MarkdownBlock();
      b.type = 'list_item';
      b.isOrdered = false;
      b.spans = parseInlineSpans(unorderedMatch[1]);
      blocks.push(b);
      i++;
      continue;
    }

    // 9. Regular Paragraph
    const b = new MarkdownBlock();
    b.type = 'paragraph';
    b.spans = parseInlineSpans(trimmed);
    blocks.push(b);
    i++;
  }

  return blocks;
}

@Component
export struct MarkdownView {
  @Prop @Watch('onContentChanged') content: string = '';
  @State private blocks: MarkdownBlock[] = [];

  aboutToAppear(): void {
    this.blocks = parseMarkdownBlocks(this.content);
  }

  onContentChanged(): void {
    this.blocks = parseMarkdownBlocks(this.content);
  }

  private async copyToClipboard(text: string): Promise<void> {
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      await systemPasteboard.setData(pasteData);
      promptAction.showToast({ message: '已复制到剪贴板', duration: 1500 });
    } catch (err) {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    }
  }

  private getTableColAlign(block: MarkdownBlock, colIdx: number): TextAlign {
    if (block.tableAlignments && colIdx < block.tableAlignments.length) {
      return block.tableAlignments[colIdx];
    }
    return TextAlign.Start;
  }

  private getTableColWidth(block: MarkdownBlock, colIdx: number): number {
    if (block.tableColWidths && colIdx < block.tableColWidths.length) {
      return block.tableColWidths[colIdx];
    }
    return 80;
  }

  build() {
    Column({ space: 4 }) {
      ForEach(this.blocks, (block: MarkdownBlock, idx: number) => {
        if (block.type === 'heading') {
          Row() {
            Text() {
              ForEach(block.spans, (span: InlineSpan, sIdx: number) => {
                Span(span.text)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#0f172a')
                  .fontSize(block.level === 1 ? 18 : (block.level === 2 ? 16 : 14))
              })
            }
          }
          .width('100%')
          .margin({ top: 6, bottom: 4 })
        } else if (block.type === 'code_block') {
          Column() {
            Row() {
              Text(block.language.toUpperCase())
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .fontColor('#94a3b8')

              Blank()

              Button('复制')
                .fontSize(10)
                .height(20)
                .padding({ left: 8, right: 8 })
                .backgroundColor('#334155')
                .fontColor('#f8fafc')
                .onClick(() => {
                  this.copyToClipboard(block.codeLines.join('\n'));
                })
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor('#0f172a')
            .borderRadius({ topLeft: 6, topRight: 6 })

            Scroll() {
              Text(block.codeLines.join('\n'))
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor('#38bdf8')
                .copyOption(CopyOptions.LocalDevice)
                .padding(10)
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Auto)
            .width('100%')
            .align(Alignment.TopStart)
          }
          .backgroundColor('#1e293b')
          .borderRadius(6)
          .width('100%')
          .margin({ top: 6, bottom: 6 })
        } else if (block.type === 'table') {
          Scroll() {
            Column() {
              if (block.tableHeaders.length > 0) {
                Row() {
                  ForEach(block.tableHeaders, (cellSpans: InlineSpan[], hIdx: number) => {
                    Text() {
                      ForEach(cellSpans, (span: InlineSpan) => {
                        Span(span.text)
                          .fontWeight(FontWeight.Bold)
                          .fontSize(11)
                          .fontColor('#1e293b')
                      })
                    }
                    .textAlign(this.getTableColAlign(block, hIdx))
                    .width(this.getTableColWidth(block, hIdx))
                    .padding(8)
                    .border({ width: { right: 1, bottom: 1 }, color: '#cbd5e1' })
                  })
                }
                .backgroundColor('#e2e8f0')
                .justifyContent(FlexAlign.Start)
              }

              ForEach(block.tableRows, (row: InlineSpan[][], rIdx: number) => {
                Row() {
                  ForEach(row, (cellSpans: InlineSpan[], cIdx: number) => {
                    Text() {
                      ForEach(cellSpans, (span: InlineSpan) => {
                        Span(span.text)
                          .fontWeight(span.isBold ? FontWeight.Bold : FontWeight.Normal)
                          .fontFamily(span.isCode ? 'monospace' : 'sans-serif')
                          .fontColor(span.isCode ? '#b91c1c' : '#1e293b')
                          .fontSize(11)
                      })
                    }
                    .textAlign(this.getTableColAlign(block, cIdx))
                    .width(this.getTableColWidth(block, cIdx))
                    .padding(8)
                    .border({ width: { right: 1, bottom: 1 }, color: '#e2e8f0' })
                  })
                }
                .backgroundColor(rIdx % 2 === 0 ? '#ffffff' : '#f8fafc')
                .justifyContent(FlexAlign.Start)
              })
            }
            .alignItems(HorizontalAlign.Start)
            .border({ width: { left: 1, top: 1 }, color: '#cbd5e1' })
            .borderRadius(4)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .width('100%')
          .align(Alignment.TopStart)
          .margin({ top: 6, bottom: 6 })
        } else if (block.type === 'list_item') {
          Row({ space: 6 }) {
            Text(block.isOrdered ? `${block.listNumber}.` : '•')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#0284c7')
              .margin({ top: 1 })

            Text() {
              ForEach(block.spans, (span: InlineSpan, sIdx: number) => {
                Span(span.text)
                  .fontWeight(span.isBold ? FontWeight.Bold : FontWeight.Normal)
                  .fontStyle(span.isItalic ? FontStyle.Italic : FontStyle.Normal)
                  .fontFamily(span.isCode ? 'monospace' : 'sans-serif')
                  .fontColor(span.isCode ? '#b91c1c' : '#1e293b')
                  .fontSize(13)
              })
            }
            .layoutWeight(1)
            .lineHeight(19)
            .copyOption(CopyOptions.LocalDevice)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ bottom: 4 })
        } else if (block.type === 'blockquote') {
          Row() {
            Column() {
              Text() {
                ForEach(block.spans, (span: InlineSpan, sIdx: number) => {
                  Span(span.text)
                    .fontWeight(span.isBold ? FontWeight.Bold : FontWeight.Normal)
                    .fontStyle(FontStyle.Italic)
                    .fontColor('#475569')
                    .fontSize(12)
                })
              }
              .lineHeight(18)
              .copyOption(CopyOptions.LocalDevice)
            }
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor('#f1f5f9')
            .border({ width: { left: 3 }, color: '#0284c7' })
            .borderRadius({ topRight: 4, bottomRight: 4 })
            .width('100%')
          }
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        } else if (block.type === 'divider') {
          Divider()
            .color('#e2e8f0')
            .strokeWidth(1)
            .margin({ top: 6, bottom: 6 })
        } else {
          // Regular paragraph
          Text() {
            ForEach(block.spans, (span: InlineSpan, sIdx: number) => {
              Span(span.text)
                .fontWeight(span.isBold ? FontWeight.Bold : FontWeight.Normal)
                .fontStyle(span.isItalic ? FontStyle.Italic : FontStyle.Normal)
                .fontFamily(span.isCode ? 'monospace' : 'sans-serif')
                .fontColor(span.isCode ? '#b91c1c' : '#1e293b')
                .fontSize(13)
            })
          }
          .width('100%')
          .lineHeight(20)
          .copyOption(CopyOptions.LocalDevice)
          .margin({ bottom: 4 })
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
