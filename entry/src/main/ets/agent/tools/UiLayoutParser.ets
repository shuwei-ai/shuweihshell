/*
 * Pure ArkTS parser, filter, and formatter for HarmonyOS `uitest dumpLayout` JSON trees.
 * Kept isolated from native OS imports so layout parsing and matching can be unit-tested cleanly.
 */

export interface UiBounds {
  left: number;
  top: number;
  right: number;
  bottom: number;
  width: number;
  height: number;
  cx: number;
  cy: number;
  raw: string;
}

export interface UiNode {
  index: number;
  text: string;
  hint: string;
  description: string;
  id: string;
  type: string;
  bundleName: string;
  bounds: UiBounds;
  clickable: boolean;
  scrollable: boolean;
  enabled: boolean;
  visible: boolean;
  depth: number;
}

export interface UiNodeQuery {
  ref?: string | number;
  text?: string;
  containsText?: string;
  id?: string;
  nodeType?: string;
  clickableOnly?: boolean;
  scrollableOnly?: boolean;
}

export interface UiTreeParseResult {
  nodes: UiNode[];
  totalVisited: number;
  screenWidth: number;
  screenHeight: number;
}

export class UiLayoutParser {
  static parseBounds(boundsText: string): UiBounds | null {
    if (!boundsText || typeof boundsText !== 'string') {
      return null;
    }
    const m = boundsText.match(/\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\]\s*\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\]/);
    if (!m) {
      return null;
    }
    const left = parseInt(m[1], 10);
    const top = parseInt(m[2], 10);
    const right = parseInt(m[3], 10);
    const bottom = parseInt(m[4], 10);
    const width = right - left;
    const height = bottom - top;
    if (!Number.isFinite(left) || !Number.isFinite(top) || width <= 0 || height <= 0) {
      return null;
    }
    return {
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      cx: Math.round((left + right) / 2),
      cy: Math.round((top + bottom) / 2),
      raw: `[${left},${top}][${right},${bottom}]`
    };
  }

  private static readBool(attrs: Record<string, Object>, key: string, defaultVal: boolean): boolean {
    const val = attrs[key];
    if (typeof val === 'boolean') {
      return val;
    }
    if (typeof val === 'string') {
      const lower = val.trim().toLowerCase();
      if (lower === 'true' || lower === '1') {
        return true;
      }
      if (lower === 'false' || lower === '0') {
        return false;
      }
    }
    return defaultVal;
  }

  private static readStr(attrs: Record<string, Object>, key: string): string {
    const val = attrs[key];
    if (typeof val === 'string') {
      return val;
    }
    return '';
  }

  static extractTree(rawJson: string, includeUninteractive: boolean = false): UiTreeParseResult {
    const trimmed = (rawJson ?? '').trim();
    if (trimmed.length === 0) {
      throw new Error('Layout JSON output is empty');
    }
    const parsed = JSON.parse(trimmed) as Object;
    const nodes: UiNode[] = [];
    let totalVisited = 0;
    let screenWidth = 0;
    let screenHeight = 0;

    const visit = (item: Object, depth: number, inheritedBundleName: string = ''): void => {
      if (!item || typeof item !== 'object') {
        return;
      }
      totalVisited++;
      const obj = item as Record<string, Object>;
      const rawAttrs = obj['attributes'];
      const attrs: Record<string, Object> =
        (rawAttrs && typeof rawAttrs === 'object' && !Array.isArray(rawAttrs))
          ? (rawAttrs as Record<string, Object>)
          : obj;

      const rawBundle = (UiLayoutParser.readStr(attrs, 'bundleName') || UiLayoutParser.readStr(obj, 'bundleName')).trim();
      const currentBundle = rawBundle.length > 0 ? rawBundle : inheritedBundleName;

      const boundsStr = UiLayoutParser.readStr(attrs, 'bounds') || UiLayoutParser.readStr(obj, 'bounds');
      const bounds = UiLayoutParser.parseBounds(boundsStr);
      if (bounds !== null) {
        if (bounds.right > screenWidth) {
          screenWidth = bounds.right;
        }
        if (bounds.bottom > screenHeight) {
          screenHeight = bounds.bottom;
        }
        const visible = UiLayoutParser.readBool(attrs, 'visible', true);
        const enabled = UiLayoutParser.readBool(attrs, 'enabled', true);
        const clickable = UiLayoutParser.readBool(attrs, 'clickable', false);
        const scrollable = UiLayoutParser.readBool(attrs, 'scrollable', false);
        const text = UiLayoutParser.readStr(attrs, 'text').trim();
        const hint = UiLayoutParser.readStr(attrs, 'hint').trim();
        const description = (UiLayoutParser.readStr(attrs, 'description') ||
          UiLayoutParser.readStr(attrs, 'accessibilityText')).trim();
        const id = UiLayoutParser.readStr(attrs, 'id').trim();
        const nodeType = (UiLayoutParser.readStr(attrs, 'type') || 'Component').trim();

        const hasMeaningfulLabel = text.length > 0 || hint.length > 0 || description.length > 0 || id.length > 0;
        if (visible && (includeUninteractive || clickable || scrollable || hasMeaningfulLabel)) {
          nodes.push({
            index: nodes.length,
            text: text,
            hint: hint,
            description: description,
            id: id,
            type: nodeType,
            bundleName: currentBundle,
            bounds: bounds,
            clickable: clickable,
            scrollable: scrollable,
            enabled: enabled,
            visible: visible,
            depth: depth
          });
        }
      }

      const rawChildren = obj['children'];
      if (Array.isArray(rawChildren)) {
        for (let i = 0; i < rawChildren.length; i++) {
          visit(rawChildren[i] as Object, depth + 1, currentBundle);
        }
      }
    };

    if (Array.isArray(parsed)) {
      const list = parsed as Object[];
      for (let i = 0; i < list.length; i++) {
        visit(list[i], 0);
      }
    } else {
      visit(parsed, 0);
    }

    return {
      nodes: nodes,
      totalVisited: totalVisited,
      screenWidth: screenWidth > 0 ? screenWidth : 1080,
      screenHeight: screenHeight > 0 ? screenHeight : 2400
    };
  }

  private static labelMatchesExact(node: UiNode, targetLower: string): boolean {
    return node.text.toLowerCase() === targetLower ||
      node.hint.toLowerCase() === targetLower ||
      node.description.toLowerCase() === targetLower;
  }

  private static labelContains(node: UiNode, needleLower: string): boolean {
    return node.text.toLowerCase().includes(needleLower) ||
      node.hint.toLowerCase().includes(needleLower) ||
      node.description.toLowerCase().includes(needleLower);
  }

  static filterNodes(nodes: UiNode[], query: UiNodeQuery): UiNode[] {
    // Direct ref matching (@N or N) takes highest precedence
    if (query.ref !== undefined && query.ref !== null) {
      const rawRef = String(query.ref).trim().replace(/^@/, '');
      const refIndex = parseInt(rawRef, 10);
      if (Number.isFinite(refIndex)) {
        const direct = nodes.filter((n: UiNode) => n.index === refIndex);
        if (direct.length > 0) {
          return direct;
        }
      }
    }

    const exactText = (query.text ?? '').trim().toLowerCase();
    const containsText = (query.containsText ?? '').trim().toLowerCase();
    const targetId = (query.id ?? '').trim().toLowerCase();
    const targetType = (query.nodeType ?? '').trim().toLowerCase();

    const candidates = nodes.filter((node: UiNode) => {
      if (query.clickableOnly === true && !node.clickable) {
        return false;
      }
      if (query.scrollableOnly === true && !node.scrollable) {
        return false;
      }
      if (targetId.length > 0 && !node.id.toLowerCase().includes(targetId)) {
        return false;
      }
      if (targetType.length > 0 && !node.type.toLowerCase().includes(targetType)) {
        return false;
      }
      if (exactText.length > 0 && !UiLayoutParser.labelContains(node, exactText)) {
        return false;
      }
      if (containsText.length > 0 &&
        !UiLayoutParser.labelContains(node, containsText) &&
        !node.id.toLowerCase().includes(containsText)) {
        return false;
      }
      return true;
    });

    // Rank best interactive & exact matches first
    candidates.sort((a: UiNode, b: UiNode) => {
      const scoreNode = (n: UiNode): number => {
        let score = 0;
        if (exactText.length > 0 && UiLayoutParser.labelMatchesExact(n, exactText)) {
          score += 100;
        }
        if (targetId.length > 0 && n.id.toLowerCase() === targetId) {
          score += 80;
        }
        if (n.enabled) {
          score += 20;
        }
        if (n.clickable) {
          score += 15;
        }
        return score;
      };
      const diff = scoreNode(b) - scoreNode(a);
      if (diff !== 0) {
        return diff;
      }
      return a.index - b.index;
    });

    return candidates;
  }

  static formatNodeLine(node: UiNode): string {
    const parts: string[] = [`@${node.index}`, `[${node.type}]`];
    if (node.text.length > 0) {
      parts.push(`text="${node.text}"`);
    }
    if (node.hint.length > 0) {
      parts.push(`hint="${node.hint}"`);
    }
    if (node.description.length > 0) {
      parts.push(`desc="${node.description}"`);
    }
    if (node.id.length > 0) {
      parts.push(`id="${node.id}"`);
    }
    parts.push(`center=(${node.bounds.cx},${node.bounds.cy})`);
    parts.push(`bounds=${node.bounds.raw}`);
    const flags: string[] = [];
    if (node.clickable) {
      flags.push('clickable');
    }
    if (node.scrollable) {
      flags.push('scrollable');
    }
    if (!node.enabled) {
      flags.push('disabled');
    }
    if (flags.length > 0) {
      parts.push(flags.join(','));
    }
    return parts.join(' ');
  }

  static formatSummary(tree: UiTreeParseResult, filtered: UiNode[], maxItems: number = 100): string {
    const lines: string[] = [
      `Screen: ${tree.screenWidth}x${tree.screenHeight} | Matched nodes: ${filtered.length} (from ${tree.totalVisited} raw nodes)`
    ];
    if (filtered.length === 0) {
      lines.push('(No matching visible UI nodes found)');
      return lines.join('\n');
    }
    const cap = Math.min(filtered.length, Math.max(1, maxItems));
    for (let i = 0; i < cap; i++) {
      lines.push(UiLayoutParser.formatNodeLine(filtered[i]));
    }
    if (filtered.length > cap) {
      lines.push(`... (+${filtered.length - cap} more nodes truncated; refine with text/contains_text/id/clickable_only)`);
    }
    return lines.join('\n');
  }
}
