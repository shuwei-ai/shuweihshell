/*
 * Pi Inspect Image Tool for HarmonyOS.
 * Captures the current screen or reads device/photo/HTTP images and returns them
 * as multimodal ImageAttachment payloads for the vision-capable LLM.
 */
import { BridgeController } from '../../common/BridgeController';
import { AgentWorkspace } from './AgentWorkspace';
import {
  ImageAttachment,
  ImageDetailLevel,
  ToolDefinition,
  ToolFunctionDefinition,
  ToolParameters,
  ToolProperty,
  ToolResult
} from '../types';
import { ImageEncoder } from '../utils/ImageEncoder';

const DEFAULT_SCREENSHOT_PATH = '/data/local/tmp/_agent_view.jpeg';

export class InspectImageTool {
  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'source': new ToolProperty(
        'string',
        'Image source: "screen" (capture current device screen via uitest screenCap / snapshot_display), "file" (read image at device path or workspace relative path), or "url" (http/https image URL).'
      ),
      'path': new ToolProperty(
        'string',
        'Image path on device (e.g. "/data/local/tmp/screen.png", "workspace/chart.png", or "download://...") when source="file", or optional output path when source="screen".'
      ),
      'url': new ToolProperty(
        'string',
        'HTTP/HTTPS image URL when source="url".'
      ),
      'detail': new ToolProperty(
        'string',
        'Vision resolution detail: "low" (fast/low token), "default" (balanced), or "high" (fine text/UI details). Defaults to "default".'
      )
    };
    const params = new ToolParameters(props, ['source']);
    const func = new ToolFunctionDefinition(
      'inspect_image',
      'Inspect an image visually using the model vision capability. Use source="screen" to capture and view the current HarmonyOS screen via native uitest screenCap, source="file" to view an existing image file, or source="url" to view a web image URL.',
      params
    );
    return new ToolDefinition(func);
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const rawSource = ((args['source'] as string) ?? 'screen').trim().toLowerCase();
    const rawPath = ((args['path'] as string) ?? '').trim();
    const rawUrl = ((args['url'] as string) ?? '').trim();
    const detail: ImageDetailLevel = ImageEncoder.normalizeDetail((args['detail'] as string) ?? 'default');

    try {
      if (rawSource === 'screen') {
        const targetPath = rawPath.length > 0 ? rawPath : DEFAULT_SCREENSHOT_PATH;
        const escaped = targetPath.replace(/'/g, `'\\''`);

        // Prefer snapshot_display (instant ~100ms hardware capture, strictly requires .jpeg suffix)
        // Fallback to uitest screenCap if snapshot_display is unavailable or output extension differs
        const isJpeg = escaped.toLowerCase().endsWith('.jpeg');
        const snapCmd =
          `rm -f '${escaped}' && ` +
          (isJpeg
            ? `(snapshot_display -f '${escaped}' >/dev/null 2>&1 || uitest screenCap -p '${escaped}' >/dev/null 2>&1)`
            : `(uitest screenCap -p '${escaped}' >/dev/null 2>&1 || (snapshot_display -f /data/local/tmp/_snap_tmp.jpeg >/dev/null 2>&1 && mv /data/local/tmp/_snap_tmp.jpeg '${escaped}'))`) +
          ` && [ -s '${escaped}' ]`;

        const snapRes = await BridgeController.getInstance().exec(snapCmd, '', 15);
        if (!snapRes.ok) {
          const checkRes = await BridgeController.getInstance().exec(`ls -la '${escaped}' 2>&1`);
          return {
            toolCallId: toolCallId,
            toolName: 'inspect_image',
            output: '',
            error: `Screen capture failed: neither uitest screenCap nor snapshot_display produced a valid non-empty image file at ${targetPath}. Diagnostics: ${checkRes.output}`,
            isError: true
          };
        }

        const attachment = await ImageEncoder.encodeShellPathToDataUrl(targetPath, detail);
        const kb = attachment.byteLength ? Math.round(attachment.byteLength / 1024) : 0;
        const summary = `Captured screen to ${targetPath} (${attachment.width}x${attachment.height}, ${kb} KB JPEG, detail=${detail}). Image attached for visual inspection.`;
        return {
          toolCallId: toolCallId,
          toolName: 'inspect_image',
          output: summary,
          images: [attachment],
          isError: false
        };
      }

      if (rawSource === 'file') {
        let targetPath = rawPath.length > 0 ? rawPath : rawUrl;
        if (targetPath.length === 0) {
          return {
            toolCallId: toolCallId,
            toolName: 'inspect_image',
            output: '',
            error: 'Parameter "path" is required when source="file".',
            isError: true
          };
        }

        if (targetPath.startsWith('http://') || targetPath.startsWith('https://')) {
          const urlAttachment: ImageAttachment = {
            dataUrl: targetPath,
            detail: detail,
            previewUri: targetPath,
            sourcePath: targetPath
          };
          return {
            toolCallId: toolCallId,
            toolName: 'inspect_image',
            output: `Attached remote image URL ${targetPath} (detail=${detail}) for visual inspection.`,
            images: [urlAttachment],
            isError: false
          };
        }

        // Resolve workspace relative paths or download:// protocol
        if (!targetPath.startsWith('/') && !targetPath.startsWith('file://')) {
          targetPath = AgentWorkspace.getInstance().resolvePath(targetPath);
        }

        let attachment: ImageAttachment;
        if (targetPath.startsWith('file://') || targetPath.startsWith('/data/storage/') || targetPath.startsWith('/data/app/')) {
          try {
            attachment = await ImageEncoder.encodeUriToDataUrl(targetPath, detail);
          } catch (_uriErr) {
            attachment = await ImageEncoder.encodeShellPathToDataUrl(targetPath, detail);
          }
        } else {
          attachment = await ImageEncoder.encodeShellPathToDataUrl(targetPath, detail);
        }

        const kb = attachment.byteLength ? Math.round(attachment.byteLength / 1024) : 0;
        return {
          toolCallId: toolCallId,
          toolName: 'inspect_image',
          output: `Loaded image ${targetPath} (${attachment.width}x${attachment.height}, ${kb} KB JPEG, detail=${detail}) for visual inspection.`,
          images: [attachment],
          isError: false
        };
      }

      if (rawSource === 'url') {
        const targetUrl = rawUrl.length > 0 ? rawUrl : rawPath;
        if (!targetUrl.startsWith('http://') && !targetUrl.startsWith('https://')) {
          return {
            toolCallId: toolCallId,
            toolName: 'inspect_image',
            output: '',
            error: 'Parameter "url" must start with http:// or https:// when source="url".',
            isError: true
          };
        }
        const attachment: ImageAttachment = {
          dataUrl: targetUrl,
          detail: detail,
          previewUri: targetUrl,
          sourcePath: targetUrl
        };
        return {
          toolCallId: toolCallId,
          toolName: 'inspect_image',
          output: `Attached image URL ${targetUrl} (detail=${detail}) for visual inspection.`,
          images: [attachment],
          isError: false
        };
      }

      return {
        toolCallId: toolCallId,
        toolName: 'inspect_image',
        output: '',
        error: `Unsupported source "${rawSource}". Expected "screen", "file", or "url".`,
        isError: true
      };
    } catch (err) {
      return {
        toolCallId: toolCallId,
        toolName: 'inspect_image',
        output: '',
        error: `inspect_image error: ${err}`,
        isError: true
      };
    }
  }
}
