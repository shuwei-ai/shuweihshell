/*
 * AgentWorkspace: Manages the native application sandbox workspace and file operations
 * for HarmonyOS Pi Agent via @ohos.file.fs.
 *
 * Provides a reliable, persistent filesystem workspace rooted at context.filesDir + '/workspace'.
 * Relative paths (e.g. 'main.js', 'data/output.json') resolve into this workspace, avoiding
 * shell command-line size limits (E2BIG), escaping issues, and /data/local/tmp volatility.
 * External system paths (/data/local/tmp, /proc, etc.) seamlessly fall back to shell execution.
 */
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import buffer from '@ohos.buffer';
import hilog from '@ohos.hilog';
import environment from '@ohos.file.environment';
import zlib from '@ohos.zlib';
import { BridgeController } from '../../common/BridgeController';

const DOMAIN: number = 0x0001;
const TAG: string = 'AgentWorkspace';

export class AgentWorkspace {
  private static instance: AgentWorkspace = new AgentWorkspace();

  private context: common.Context | null = null;
  private workspaceRoot: string = '/data/storage/el2/base/haps/entry/files/workspace';

  static getInstance(): AgentWorkspace {
    return AgentWorkspace.instance;
  }

  /**
   * Initializes the persistent workspace using the application context.
   */
  init(context: common.Context): void {
    this.context = context;
    if (context && context.filesDir) {
      this.workspaceRoot = `${context.filesDir}/workspace`;
    }
    this.ensureDir(this.workspaceRoot);
    hilog.info(DOMAIN, TAG, 'AgentWorkspace initialized at %{public}s', this.workspaceRoot);
    // Proactively grant public directory permissions in background
    this.ensurePermissionsSilently();
    // Ensure CPython 3.13 standard library zip is deployed
    this.ensurePythonZip();
  }

  /**
   * Unpacks python313.zip from rawfile to filesDir so CPython can load standard modules.
   */
  ensurePythonZip(): void {
    if (!this.context || !this.context.filesDir) {
      return;
    }
    try {
      const zipDest = `${this.context.filesDir}/python313.zip`;
      const rawContent = this.context.resourceManager.getRawFileContentSync('python313.zip');
      const rawSize = rawContent.byteLength;
      let needExtract = true;
      try {
        if (fs.accessSync(zipDest)) {
          const stat = fs.statSync(zipDest);
          if (stat.size === rawSize) {
            needExtract = false;
          }
        }
      } catch (_e) {
        needExtract = true;
      }

      if (needExtract) {
        hilog.info(DOMAIN, TAG, 'Extracting python313.zip from rawfile (size: %{public}d)...', rawSize);
        const opened = fs.openSync(zipDest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(opened.fd, rawContent.buffer);
        fs.closeSync(opened);
        hilog.info(DOMAIN, TAG, 'python313.zip successfully deployed at %{public}s', zipDest);
      }

      const libDir = `${this.context.filesDir}/lib/python3.13`;
      let needDecompress = needExtract;
      if (!needDecompress) {
        try {
          if (!fs.accessSync(`${libDir}/encodings`)) {
            needDecompress = true;
          }
        } catch (_e) {
          needDecompress = true;
        }
      }

      if (needDecompress) {
        hilog.info(DOMAIN, TAG, 'Decompressing python313.zip to %{public}s...', libDir);
        try {
          fs.mkdirSync(`${this.context.filesDir}/lib`);
        } catch (_m) {}
        try {
          fs.mkdirSync(libDir);
        } catch (_m2) {}
        zlib.decompressFile(zipDest, libDir).then(() => {
          hilog.info(DOMAIN, TAG, 'python313 stdlib decompressed successfully to %{public}s', libDir);
        }).catch((err: Object) => {
          hilog.warn(DOMAIN, TAG, 'decompressFile failed: %{public}s', `${err}`);
        });
      }

      // Ensure site-packages exists for custom user or agent libraries
      const sitePackagesDir = `${this.context.filesDir}/site-packages`;
      try {
        if (!fs.accessSync(sitePackagesDir)) {
          fs.mkdirSync(sitePackagesDir);
        }
      } catch (_e) {
        try { fs.mkdirSync(sitePackagesDir); } catch (_e2) {}
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ensurePythonZip failed: %{public}s', `${err}`);
    }
  }

  /**
   * Auto-grants public directory access permissions via shell bridge if token ID is known.
   * - ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY
   * - ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY
   */
  async ensurePermissionsSilently(): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const tokenId = this.context.applicationInfo.accessTokenId;
      if (tokenId && tokenId > 0) {
        await BridgeController.getInstance().exec(`atm perm -g -i ${tokenId} -p ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY`);
        await BridgeController.getInstance().exec(`atm perm -g -i ${tokenId} -p ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY`);
        hilog.info(DOMAIN, TAG, 'Successfully ensured public directory permissions for token %{public}d', tokenId);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ensurePermissionsSilently failed: %{public}s', JSON.stringify(err));
    }
  }

  getWorkspaceRoot(): string {
    return this.workspaceRoot;
  }

  setWorkspaceRoot(root: string): void {
    if (root && root.trim().length > 0) {
      this.workspaceRoot = this.normalizePath(root.trim());
      this.ensureDir(this.workspaceRoot);
    }
  }

  /**
   * Determines whether a given path belongs to the application sandbox workspace
   * or requires external shell uid-2000 access.
   */
  isSandboxPath(rawPath: string): boolean {
    if (!rawPath || rawPath.trim().length === 0) {
      return false;
    }
    const trimmed = rawPath.trim();

    // Public system storage directories (Download/Docs/Desktop via @ohos.file.environment)
    if (this.isPublicPath(trimmed)) {
      return true;
    }

    // Any relative path belongs to the agent persistent sandbox workspace
    if (!trimmed.startsWith('/')) {
      return true;
    }

    // Explicit path under workspaceRoot
    if (this.workspaceRoot.length > 0 && trimmed.startsWith(this.workspaceRoot)) {
      return true;
    }

    // Application context directories
    if (this.context) {
      if (this.context.filesDir && trimmed.startsWith(this.context.filesDir)) {
        return true;
      }
      if (this.context.cacheDir && trimmed.startsWith(this.context.cacheDir)) {
        return true;
      }
      if (this.context.tempDir && trimmed.startsWith(this.context.tempDir)) {
        return true;
      }
    }

    // Standard OpenHarmony application sandbox mount points
    if (trimmed.startsWith('/data/storage/el2/') ||
        trimmed.startsWith('/data/storage/el1/') ||
        trimmed.startsWith('/data/app/el2/') ||
        trimmed.startsWith('/data/service/el2/')) {
      return true;
    }

    // External system paths accessible by shell uid 2000 (/data/local/tmp, /proc, /sys, /system, etc.)
    return false;
  }

  /**
   * Determines whether the given path explicitly targets the public user directory
   * (e.g. download://..., public://download/..., Download/..., docs://..., Documents/..., Desktop/...,
   * or common system paths like /storage/Users/currentUser/..., /storage/media/100/local/files/..., /sdcard/...).
   */
  isPublicPath(rawPath: string): boolean {
    if (!rawPath || rawPath.trim().length === 0) {
      return false;
    }
    const lower = rawPath.trim().toLowerCase();
    if (lower.startsWith('download://') ||
        lower.startsWith('public://download/') ||
        lower.startsWith('public://docs/') ||
        lower.startsWith('public://documents/') ||
        lower.startsWith('docs://') ||
        lower.startsWith('documents://') ||
        lower.startsWith('desktop://') ||
        lower.startsWith('public://desktop/') ||
        lower.startsWith('download/') ||
        lower.startsWith('docs/') ||
        lower.startsWith('documents/') ||
        lower.startsWith('desktop/')) {
      return true;
    }

    const stripped = lower.startsWith('/') ? lower.substring(1) : lower;
    if (stripped.startsWith('storage/users/') ||
        stripped.startsWith('storage/media/100/local/files/') ||
        stripped.startsWith('storage/emulated/0/download') ||
        stripped.startsWith('storage/emulated/0/documents') ||
        stripped.startsWith('storage/emulated/0/document') ||
        stripped.startsWith('sdcard/download') ||
        stripped.startsWith('sdcard/documents') ||
        stripped.startsWith('sdcard/document')) {
      return true;
    }

    return false;
  }

  getPublicDownloadDir(): string {
    try {
      const dir = environment.getUserDownloadDir();
      if (dir && dir.length > 0) {
        return dir;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getUserDownloadDir failed: %{public}s', `${e}`);
    }
    return '/storage/media/100/local/files/Docs/Download';
  }

  getPublicDocumentDir(): string {
    try {
      const dir = environment.getUserDocumentDir();
      if (dir && dir.length > 0) {
        return dir;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getUserDocumentDir failed: %{public}s', `${e}`);
    }
    return '/storage/media/100/local/files/Docs';
  }

  getPublicDesktopDir(): string {
    try {
      const dir = environment.getUserDesktopDir();
      if (dir && dir.length > 0) {
        return dir;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getUserDesktopDir failed: %{public}s', `${e}`);
    }
    return '/storage/media/100/local/files/Desktop';
  }

  /**
   * Resolves a public directory protocol URI or path to the absolute system storage path
   * via @ohos.file.environment.
   */
  resolvePublicPath(rawPath: string): string {
    const trimmed = rawPath.trim();
    const lower = trimmed.toLowerCase();

    let subPath = trimmed;
    let baseDir = '';

    if (lower.startsWith('download://')) {
      subPath = trimmed.substring('download://'.length);
      baseDir = this.getPublicDownloadDir();
    } else if (lower.startsWith('public://download/')) {
      subPath = trimmed.substring('public://download/'.length);
      baseDir = this.getPublicDownloadDir();
    } else if (lower.startsWith('download/')) {
      subPath = trimmed.substring('download/'.length);
      baseDir = this.getPublicDownloadDir();
    } else if (lower.startsWith('docs://')) {
      subPath = trimmed.substring('docs://'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('documents://')) {
      subPath = trimmed.substring('documents://'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('public://docs/')) {
      subPath = trimmed.substring('public://docs/'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('public://documents/')) {
      subPath = trimmed.substring('public://documents/'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('docs/')) {
      subPath = trimmed.substring('docs/'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('documents/')) {
      subPath = trimmed.substring('documents/'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('desktop://')) {
      subPath = trimmed.substring('desktop://'.length);
      baseDir = this.getPublicDesktopDir();
    } else if (lower.startsWith('public://desktop/')) {
      subPath = trimmed.substring('public://desktop/'.length);
      baseDir = this.getPublicDesktopDir();
    } else if (lower.startsWith('desktop/')) {
      subPath = trimmed.substring('desktop/'.length);
      baseDir = this.getPublicDesktopDir();
    } else {
      const norm = lower.startsWith('/') ? lower.substring(1) : lower;
      const origNorm = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;

      if (norm.startsWith('storage/users/currentuser/download/') || norm === 'storage/users/currentuser/download') {
        subPath = origNorm.substring('storage/users/currentuser/download'.length);
        baseDir = this.getPublicDownloadDir();
      } else if (norm.startsWith('storage/users/download/') || norm === 'storage/users/download') {
        subPath = origNorm.substring('storage/users/download'.length);
        baseDir = this.getPublicDownloadDir();
      } else if (norm.startsWith('storage/users/currentuser/documents/') || norm === 'storage/users/currentuser/documents') {
        subPath = origNorm.substring('storage/users/currentuser/documents'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/users/currentuser/document/') || norm === 'storage/users/currentuser/document') {
        subPath = origNorm.substring('storage/users/currentuser/document'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/users/documents/') || norm === 'storage/users/documents') {
        subPath = origNorm.substring('storage/users/documents'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/users/document/') || norm === 'storage/users/document') {
        subPath = origNorm.substring('storage/users/document'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/users/currentuser/desktop/') || norm === 'storage/users/currentuser/desktop') {
        subPath = origNorm.substring('storage/users/currentuser/desktop'.length);
        baseDir = this.getPublicDesktopDir();
      } else if (norm.startsWith('storage/users/desktop/') || norm === 'storage/users/desktop') {
        subPath = origNorm.substring('storage/users/desktop'.length);
        baseDir = this.getPublicDesktopDir();
      } else if (norm.startsWith('storage/media/100/local/files/docs/download/') || norm === 'storage/media/100/local/files/docs/download') {
        subPath = origNorm.substring('storage/media/100/local/files/docs/download'.length);
        baseDir = this.getPublicDownloadDir();
      } else if (norm.startsWith('storage/media/100/local/files/desktop/') || norm === 'storage/media/100/local/files/desktop') {
        subPath = origNorm.substring('storage/media/100/local/files/desktop'.length);
        baseDir = this.getPublicDesktopDir();
      } else if (norm.startsWith('storage/media/100/local/files/docs/') || norm === 'storage/media/100/local/files/docs') {
        subPath = origNorm.substring('storage/media/100/local/files/docs'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/emulated/0/download/') || norm === 'storage/emulated/0/download' ||
                 norm.startsWith('sdcard/download/') || norm === 'sdcard/download') {
        const pLen = norm.startsWith('sdcard/') ? 'sdcard/download'.length : 'storage/emulated/0/download'.length;
        subPath = origNorm.substring(pLen);
        baseDir = this.getPublicDownloadDir();
      } else if (norm.startsWith('storage/emulated/0/documents/') || norm === 'storage/emulated/0/documents' ||
                 norm.startsWith('storage/emulated/0/document/') || norm === 'storage/emulated/0/document' ||
                 norm.startsWith('sdcard/documents/') || norm === 'sdcard/documents' ||
                 norm.startsWith('sdcard/document/') || norm === 'sdcard/document') {
        const pLen = norm.startsWith('sdcard/documents') ? 'sdcard/documents'.length :
          (norm.startsWith('sdcard/document') ? 'sdcard/document'.length :
            (norm.startsWith('storage/emulated/0/documents') ? 'storage/emulated/0/documents'.length : 'storage/emulated/0/document'.length));
        subPath = origNorm.substring(pLen);
        baseDir = this.getPublicDocumentDir();
      } else {
        baseDir = this.getPublicDownloadDir();
      }
    }

    subPath = subPath.replace(/^[\/\\]+/, '');
    return this.normalizePath(`${baseDir}/${subPath}`);
  }

  /**
   * Resolves relative paths into absolute workspace paths and normalizes directory segments.
   */
  resolvePath(rawPath: string): string {
    const trimmed = rawPath.trim();
    if (this.isPublicPath(trimmed)) {
      return this.resolvePublicPath(trimmed);
    }
    if (trimmed.startsWith('/')) {
      return this.normalizePath(trimmed);
    }
    return this.normalizePath(`${this.workspaceRoot}/${trimmed}`);
  }

  /**
   * Reads the entire UTF-8 content of a sandbox file synchronously.
   */
  readFile(rawPath: string): string {
    const absPath = this.resolvePath(rawPath);
    let stat: fs.Stat;
    try {
      stat = fs.statSync(absPath);
    } catch (err) {
      throw new Error(`File does not exist: ${rawPath} (${absPath})`);
    }

    if (stat.size === 0) {
      return '';
    }

    let opened: fs.File | null = null;
    try {
      opened = fs.openSync(absPath, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const bytesRead = fs.readSync(opened.fd, buf);
      return buffer.from(buf, 0, bytesRead).toString('utf-8');
    } finally {
      if (opened) {
        try {
          fs.closeSync(opened);
        } catch (_e) {
          // ignore close error
        }
      }
    }
  }

  /**
   * Writes or overwrites a sandbox file with UTF-8 content synchronously.
   * Automatically creates intermediate directories.
   */
  writeFile(rawPath: string, content: string): void {
    const absPath = this.resolvePath(rawPath);
    const lastSlash = absPath.lastIndexOf('/');
    if (lastSlash > 0) {
      const parentDir = absPath.substring(0, lastSlash);
      this.ensureDir(parentDir);
    }

    let opened: fs.File | null = null;
    try {
      opened = fs.openSync(
        absPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      fs.writeSync(opened.fd, content);
    } finally {
      if (opened) {
        try {
          fs.closeSync(opened);
        } catch (_e) {
          // ignore close error
        }
      }
    }
  }

  /**
   * Checks whether a file exists in the sandbox.
   */
  fileExists(rawPath: string): boolean {
    const absPath = this.resolvePath(rawPath);
    try {
      return fs.accessSync(absPath);
    } catch (_e) {
      return false;
    }
  }

  /**
   * Deletes a file in the sandbox.
   */
  deleteFile(rawPath: string): boolean {
    const absPath = this.resolvePath(rawPath);
    try {
      fs.unlinkSync(absPath);
      return true;
    } catch (_e) {
      return false;
    }
  }

  /**
   * Lists filenames inside a sandbox directory.
   */
  listFiles(rawPath?: string): string[] {
    const target = rawPath ? this.resolvePath(rawPath) : this.workspaceRoot;
    try {
      return fs.listFileSync(target);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'listFileSync failed for %{public}s: %{public}s', target, `${err}`);
      return [];
    }
  }

  /**
   * Ensures a directory path exists recursively.
   */
  ensureDir(dirPath: string): void {
    if (!dirPath || dirPath === '/' || dirPath === '.') {
      return;
    }
    const cleanDir = this.normalizePath(dirPath);
    if (!cleanDir || cleanDir === '/' || cleanDir === '.') {
      return;
    }

    try {
      if (fs.accessSync(cleanDir)) {
        return;
      }
    } catch (_e) {
      // accessSync throws if path does not exist
    }

    const lastSlash = cleanDir.lastIndexOf('/');
    if (lastSlash > 0) {
      const parent = cleanDir.substring(0, lastSlash);
      if (parent && parent.length > 0 && parent !== cleanDir) {
        this.ensureDir(parent);
      }
    }

    try {
      fs.mkdirSync(cleanDir);
    } catch (_e) {
      // Ignore if created concurrently or already exists
    }
  }

  /**
   * Cleans path components and resolves '.' and '..'.
   */
  normalizePath(p: string): string {
    const isAbs = p.startsWith('/');
    const segments = p.split('/');
    const stack: string[] = [];
    for (let i = 0; i < segments.length; i++) {
      const s = segments[i].trim();
      if (s.length === 0 || s === '.') {
        continue;
      }
      if (s === '..') {
        if (stack.length > 0 && stack[stack.length - 1] !== '..') {
          stack.pop();
        } else if (!isAbs) {
          stack.push('..');
        }
      } else {
        stack.push(s);
      }
    }
    const joined = stack.join('/');
    return isAbs ? '/' + joined : (joined.length > 0 ? joined : '.');
  }
}
