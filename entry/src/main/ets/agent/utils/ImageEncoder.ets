/*
 * ImageEncoder: Decodes, resizes, and JPEG-compresses local URIs or shell-accessible
 * device images into data URLs suitable for multimodal OpenAI / MiniMax vision models.
 */
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import buffer from '@ohos.buffer';
import hilog from '@ohos.hilog';
import { BridgeController } from '../../common/BridgeController';
import { ImageAttachment, ImageDetailLevel } from '../types';

const DOMAIN: number = 0x0001;
const TAG: string = 'ImageEncoder';

const MAX_SHELL_IMAGE_BYTES = 15 * 1024 * 1024;
const MAX_PACKED_BYTES = 4 * 1024 * 1024;

export class ImageEncoder {
  /**
   * Returns target maximum long-side dimension and JPEG quality for a detail level.
   */
  private static getTargetSpec(detail: ImageDetailLevel): number[] {
    if (detail === 'low') {
      return [768, 75];
    }
    if (detail === 'high') {
      return [1920, 88];
    }
    return [1280, 82];
  }

  /**
   * Normalizes detail string to supported enum value.
   */
  static normalizeDetail(raw?: string): ImageDetailLevel {
    if (raw === 'low' || raw === 'high' || raw === 'default') {
      return raw;
    }
    return 'default';
  }

  /**
   * Reads a photo/app-sandbox URI or local path directly via @ohos.file.fs and encodes
   * it as a resized JPEG data URL.
   */
  static async encodeUriToDataUrl(
    uriOrPath: string,
    detail: ImageDetailLevel = 'default'
  ): Promise<ImageAttachment> {
    let openedFile: fs.File | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    try {
      openedFile = fs.openSync(uriOrPath, fs.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(openedFile.fd);
      return await ImageEncoder.encodeImageSource(imageSource, detail, uriOrPath, uriOrPath);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'encodeUriToDataUrl failed for %{public}s: %{public}s', uriOrPath, `${err}`);
      throw new Error(`Failed to read or encode image "${uriOrPath}": ${err}`);
    } finally {
      if (imageSource) {
        try {
          await imageSource.release();
        } catch (e) {
          // ignore
        }
      }
      if (openedFile) {
        try {
          fs.closeSync(openedFile);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /**
   * Reads an image file accessible by uid-2000 shell (e.g. /data/local/tmp/screen.jpeg)
   * over BridgeController and encodes it as a resized JPEG data URL.
   */
  static async encodeShellPathToDataUrl(
    shellPath: string,
    detail: ImageDetailLevel = 'default'
  ): Promise<ImageAttachment> {
    const escaped = shellPath.replace(/'/g, `'\\''`);
    const cmd =
      `P='${escaped}'; ` +
      `if [ ! -f "$P" ]; then echo '__IMG_ERR__:NOT_FOUND'; exit 0; fi; ` +
      `if [ ! -s "$P" ]; then echo '__IMG_ERR__:EMPTY'; exit 0; fi; ` +
      `SZ=$(stat -c %s "$P" 2>/dev/null || wc -c < "$P" 2>/dev/null); ` +
      `if [ "$SZ" -gt ${MAX_SHELL_IMAGE_BYTES} ] 2>/dev/null; then echo "__IMG_ERR__:TOO_LARGE:$SZ"; exit 0; fi; ` +
      `echo '___B64_START___'; ` +
      `base64 "$P" 2>/dev/null; ` +
      `echo '___B64_END___'`;

    const res = await BridgeController.getInstance().exec(cmd, '', 30);
    if (!res.ok) {
      throw new Error(`Shell image read failed (${res.exitCode}): ${res.error || res.output}`);
    }

    const rawOut = (res.output || '').trim();
    if (rawOut.includes('__IMG_ERR__:NOT_FOUND')) {
      throw new Error(`Image file not found on device: ${shellPath}`);
    }
    if (rawOut.includes('__IMG_ERR__:EMPTY')) {
      throw new Error(`Image file is empty: ${shellPath}`);
    }
    if (rawOut.includes('__IMG_ERR__:TOO_LARGE:')) {
      throw new Error(`Image file too large (> ${MAX_SHELL_IMAGE_BYTES} bytes): ${shellPath}`);
    }

    const startMarker = '___B64_START___';
    const endMarker = '___B64_END___';
    const startIdx = rawOut.indexOf(startMarker);
    const endIdx = rawOut.indexOf(endMarker);
    let payload = rawOut;
    if (startIdx >= 0 && endIdx > startIdx) {
      payload = rawOut.substring(startIdx + startMarker.length, endIdx);
    }
    const cleanBase64 = payload.replace(/[^A-Za-z0-9+/=]/g, '');
    if (cleanBase64.length === 0) {
      throw new Error(`Base64 output empty for image: ${shellPath}`);
    }

    const decodedBuf = buffer.from(cleanBase64, 'base64');
    if (decodedBuf.length < 16) {
      throw new Error(`Decoded image buffer too small (${decodedBuf.length} bytes) for: ${shellPath}`);
    }

    const rawArrayBuffer = decodedBuf.buffer.slice(
      decodedBuf.byteOffset,
      decodedBuf.byteOffset + decodedBuf.length
    );

    let imageSource: image.ImageSource | undefined = undefined;
    try {
      imageSource = image.createImageSource(rawArrayBuffer);
      return await ImageEncoder.encodeImageSource(imageSource, detail, undefined, shellPath);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'encodeShellPathToDataUrl decode failed for %{public}s: %{public}s', shellPath, `${err}`);
      throw new Error(`Failed to decode/encode shell image "${shellPath}": ${err}`);
    } finally {
      if (imageSource) {
        try {
          await imageSource.release();
        } catch (_e) {
          // ignore
        }
      }
    }
  }

  /**
   * Decodes an ImageSource to a scaled PixelMap and packs it into a JPEG data URL.
   */
  private static async encodeImageSource(
    imageSource: image.ImageSource,
    detail: ImageDetailLevel,
    previewUri: string | undefined,
    sourcePath: string
  ): Promise<ImageAttachment> {
    const spec = ImageEncoder.getTargetSpec(detail);
    const maxLongSide = spec[0];
    let quality = spec[1];

    const info = await imageSource.getImageInfo();
    const origW = info.size.width;
    const origH = info.size.height;
    let targetW = origW;
    let targetH = origH;

    const longSide = Math.max(origW, origH);
    if (longSide > maxLongSide && longSide > 0) {
      const scale = maxLongSide / longSide;
      targetW = Math.max(1, Math.round(origW * scale));
      targetH = Math.max(1, Math.round(origH * scale));
    }

    let pixelMap: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    try {
      const decodeOptions: image.DecodingOptions = {
        desiredSize: { width: targetW, height: targetH }
      };
      pixelMap = await imageSource.createPixelMap(decodeOptions);
      packer = image.createImagePacker();

      const packOptions: image.PackingOption = {
        format: 'image/jpeg',
        quality: quality
      };
      let packedBuffer = await packer.packToData(pixelMap, packOptions);

      // Second pass at lower quality if JPEG still exceeds threshold
      if (packedBuffer.byteLength > MAX_PACKED_BYTES && quality > 60) {
        const retryOptions: image.PackingOption = {
          format: 'image/jpeg',
          quality: 60
        };
        packedBuffer = await packer.packToData(pixelMap, retryOptions);
      }

      const b64 = buffer.from(packedBuffer).toString('base64');
      const dataUrl = `data:image/jpeg;base64,${b64}`;

      return {
        dataUrl: dataUrl,
        detail: detail,
        previewUri: previewUri ? previewUri : dataUrl,
        sourcePath: sourcePath,
        width: targetW,
        height: targetH,
        byteLength: packedBuffer.byteLength
      };
    } catch (encodeErr) {
      throw new Error(`Image scaling/packing failed: ${encodeErr}`);
    } finally {
      if (pixelMap) {
        try {
          await pixelMap.release();
        } catch (e) {
          // ignore
        }
      }
      if (packer) {
        try {
          await packer.release();
        } catch (e) {
          // ignore
        }
      }
    }
  }
}
