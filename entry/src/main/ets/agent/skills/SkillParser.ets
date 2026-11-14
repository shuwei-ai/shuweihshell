/*
 * SkillParser: Parses YAML Frontmatter from SKILL.md files.
 * Adheres to the Agent Skills standard used by @earendil-works/pi and Claude Code.
 */
import { Skill } from './types';

export class SkillParser {
  /**
   * Parses the text content of a SKILL.md file.
   * Returns a Skill object if valid YAML frontmatter containing name and description is present.
   */
  static parse(content: string, filePath: string, baseDir: string, isBuiltin: boolean = false): Skill | null {
    if (!content) {
      return null;
    }

    // Strip UTF-8 BOM if present
    let raw = content;
    if (raw.charCodeAt(0) === 0xFEFF) {
      raw = raw.substring(1);
    }
    raw = raw.trimStart();

    if (!raw.startsWith('---')) {
      return null;
    }

    // Find closing ---
    const secondDelim = raw.indexOf('\n---', 3);
    if (secondDelim === -1) {
      return null;
    }

    const frontmatterText = raw.substring(3, secondDelim).trim();
    const lines = frontmatterText.split('\n');

    let name = '';
    let description = '';
    let license = '';
    let compatibility = '';
    let disableModelInvocation = false;

    let currentKey = '';
    let multiLineValue: string[] = [];

    const commitCurrentKey = () => {
      if (currentKey === 'description' && multiLineValue.length > 0) {
        description = multiLineValue.join(' ').trim();
      }
      currentKey = '';
      multiLineValue = [];
    };

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Check if continuation of multi-line value
      if (currentKey && (line.startsWith('  ') || line.startsWith('\t'))) {
        multiLineValue.push(trimmed);
        continue;
      } else {
        commitCurrentKey();
      }

      if (trimmed.startsWith('#') || trimmed.length === 0) {
        continue;
      }

      const colonIdx = trimmed.indexOf(':');
      if (colonIdx === -1) {
        continue;
      }

      const key = trimmed.substring(0, colonIdx).trim().toLowerCase();
      let value = trimmed.substring(colonIdx + 1).trim();

      // Strip surrounding quotes
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1).trim();
      }

      if (key === 'name') {
        name = value;
      } else if (key === 'description') {
        if (value === '>' || value === '|' || value.length === 0) {
          currentKey = 'description';
        } else {
          description = value;
        }
      } else if (key === 'license') {
        license = value;
      } else if (key === 'compatibility') {
        compatibility = value;
      } else if (key === 'disablemodelinvocation') {
        disableModelInvocation = value.toLowerCase() === 'true';
      }
    }
    commitCurrentKey();

    if (!name || !description) {
      return null;
    }

    return {
      name,
      description,
      filePath,
      baseDir,
      license: license ? license : undefined,
      compatibility: compatibility ? compatibility : undefined,
      disableModelInvocation,
      isBuiltin
    };
  }
}
