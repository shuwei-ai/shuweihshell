/*
 * VisualAffordanceEngine: Spatial and visual UI affordance resolver for HarmonyOS.
 * Maps high-level visual/spatial intent (e.g. "search icon", "back button", "send button", "input bar")
 * to precise coordinates and nodes, bypassing incomplete accessibility text dumps.
 */
import { UiNode, UiTreeParseResult } from './UiLayoutParser';

export interface VisualAnchorResult {
  x: number;
  y: number;
  matchedNode?: UiNode;
  label: string;
}

export class VisualAffordanceEngine {
  /**
   * Resolves a semantic visual anchor into screen coordinates,
   * taking into account active window bounds (split-screen secondary or full-screen).
   */
  static resolveAnchor(tree: UiTreeParseResult, anchorName: string, bundleName?: string): VisualAnchorResult | null {
    const rawName = (anchorName ?? '').trim().toLowerCase();
    if (rawName.length === 0) {
      return null;
    }

    // 1. Determine active window boundaries from tree nodes
    let winLeft = 0;
    let winTop = 0;
    let winRight = tree.screenWidth;
    let winBottom = tree.screenHeight;

    if (bundleName) {
      const bundleNodes = tree.nodes.filter(n => n.bundleName === bundleName && n.bounds.width > 200 && n.bounds.height > 300);
      if (bundleNodes.length > 0) {
        winLeft = Math.min(...bundleNodes.map(n => n.bounds.left));
        winTop = Math.min(...bundleNodes.map(n => n.bounds.top));
        winRight = Math.max(...bundleNodes.map(n => n.bounds.right));
        winBottom = Math.max(...bundleNodes.map(n => n.bounds.bottom));
      }
    }

    const winWidth = Math.max(100, winRight - winLeft);
    const winHeight = Math.max(100, winBottom - winTop);

    // 2. Map semantic visual anchors based on mobile UI layout standards
    switch (rawName) {
      case 'search':
      case 'nav_search':
      case '放大镜':
      case '搜索':
      case '搜索图标': {
        // Visual ROI: top navigation bar, right side (typically 75% ~ 88% of width, top 12% of height)
        const roiLeft = winLeft + winWidth * 0.72;
        const roiRight = winLeft + winWidth * 0.88;
        const roiTop = winTop;
        const roiBottom = winTop + Math.min(350, winHeight * 0.15);

        // Find candidate nodes inside this ROI
        const candidates = tree.nodes.filter(n =>
          n.bounds.cx >= roiLeft && n.bounds.cx <= roiRight &&
          n.bounds.cy >= roiTop && n.bounds.cy <= roiBottom &&
          n.bounds.width < 250 && n.bounds.height < 250
        );
        if (candidates.length > 0) {
          const best = candidates.find(c => c.clickable || c.type === 'Image') || candidates[0];
          return {
            x: best.bounds.cx,
            y: best.bounds.cy,
            matchedNode: best,
            label: `Visual Anchor [search] -> ${best.type} at (${best.bounds.cx}, ${best.bounds.cy})`
          };
        }
        // Fallback to geometric centroid of the search icon ROI
        const cx = Math.round(winLeft + winWidth * 0.81);
        const cy = Math.round(winTop + Math.min(200, winHeight * 0.075));
        return {
          x: cx,
          y: cy,
          label: `Visual Anchor [search] geometric ROI at (${cx}, ${cy})`
        };
      }

      case 'back':
      case 'nav_back':
      case '返回':
      case '返回键': {
        // Visual ROI: top navigation bar, left side (0% ~ 18% of width)
        const roiLeft = winLeft;
        const roiRight = winLeft + winWidth * 0.18;
        const roiTop = winTop;
        const roiBottom = winTop + Math.min(350, winHeight * 0.15);

        const candidates = tree.nodes.filter(n =>
          n.bounds.cx >= roiLeft && n.bounds.cx <= roiRight &&
          n.bounds.cy >= roiTop && n.bounds.cy <= roiBottom &&
          n.bounds.width < 250 && n.bounds.height < 250
        );
        if (candidates.length > 0) {
          const best = candidates.find(c =>
            c.clickable ||
            c.type === 'Image' ||
            c.description.includes('返回') ||
            c.text.includes('返回')
          ) || candidates[0];
          return {
            x: best.bounds.cx,
            y: best.bounds.cy,
            matchedNode: best,
            label: `Visual Anchor [back] -> ${best.type} at (${best.bounds.cx}, ${best.bounds.cy})`
          };
        }
        const cx = Math.round(winLeft + winWidth * 0.06);
        const cy = Math.round(winTop + Math.min(200, winHeight * 0.075));
        return {
          x: cx,
          y: cy,
          label: `Visual Anchor [back] geometric ROI at (${cx}, ${cy})`
        };
      }

      case 'more':
      case 'nav_more':
      case '更多':
      case '加号': {
        // Visual ROI: top navigation bar, far right (88% ~ 100% of width)
        const roiLeft = winLeft + winWidth * 0.88;
        const roiRight = winRight;
        const roiTop = winTop;
        const roiBottom = winTop + Math.min(350, winHeight * 0.15);

        const candidates = tree.nodes.filter(n =>
          n.bounds.cx >= roiLeft && n.bounds.cx <= roiRight &&
          n.bounds.cy >= roiTop && n.bounds.cy <= roiBottom &&
          n.bounds.width < 250 && n.bounds.height < 250
        );
        if (candidates.length > 0) {
          const best = candidates.find(c => c.clickable || c.type === 'Image') || candidates[0];
          return {
            x: best.bounds.cx,
            y: best.bounds.cy,
            matchedNode: best,
            label: `Visual Anchor [more] -> ${best.type} at (${best.bounds.cx}, ${best.bounds.cy})`
          };
        }
        const cx = Math.round(winLeft + winWidth * 0.94);
        const cy = Math.round(winTop + Math.min(200, winHeight * 0.075));
        return {
          x: cx,
          y: cy,
          label: `Visual Anchor [more] geometric ROI at (${cx}, ${cy})`
        };
      }

      case 'voice_toggle':
      case '键盘切换':
      case '语音切换': {
        // Visual ROI: bottom bar far left (0% ~ 15% width, bottom 10% height)
        const cx = Math.round(winLeft + winWidth * 0.06);
        const cy = Math.round(winBottom - Math.min(180, winHeight * 0.065));
        return {
          x: cx,
          y: cy,
          label: `Visual Anchor [voice_toggle] at (${cx}, ${cy})`
        };
      }

      case 'chat_input':
      case '输入框':
      case '聊天输入': {
        // Look for text input node near bottom
        const inputNode = tree.nodes.find(n =>
          (n.type === 'TextInput' || n.type === 'TextArea' || n.text.includes('发送消息') || n.hint.includes('发送消息')) &&
          n.bounds.cy > winBottom - Math.min(500, winHeight * 0.25)
        );
        if (inputNode) {
          return {
            x: inputNode.bounds.cx,
            y: inputNode.bounds.cy,
            matchedNode: inputNode,
            label: `Visual Anchor [chat_input] -> ${inputNode.type} at (${inputNode.bounds.cx}, ${inputNode.bounds.cy})`
          };
        }
        const cx = Math.round(winLeft + winWidth * 0.45);
        const cy = Math.round(winBottom - Math.min(180, winHeight * 0.065));
        return {
          x: cx,
          y: cy,
          label: `Visual Anchor [chat_input] geometric ROI at (${cx}, ${cy})`
        };
      }

      case 'send':
      case '发送': {
        // Look for exact '发送' text node
        const sendNode = tree.nodes.find(n => n.text === '发送' || n.description === '发送');
        if (sendNode) {
          return {
            x: sendNode.bounds.cx,
            y: sendNode.bounds.cy,
            matchedNode: sendNode,
            label: `Visual Anchor [send] -> ${sendNode.type} at (${sendNode.bounds.cx}, ${sendNode.bounds.cy})`
          };
        }
        // Fallback: bottom right of chat bar
        const cx = Math.round(winLeft + winWidth * 0.92);
        const cy = Math.round(winBottom - Math.min(180, winHeight * 0.065));
        return {
          x: cx,
          y: cy,
          label: `Visual Anchor [send] geometric ROI at (${cx}, ${cy})`
        };
      }

      default:
        return null;
    }
  }
}
