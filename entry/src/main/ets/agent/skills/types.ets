/*
 * Types and interfaces for the Pi Agent Skills Specification on HarmonyOS.
 * Modeled after packages/coding-agent/src/core/skills.ts in @earendil-works/pi.
 */

export interface Skill {
  name: string;
  description: string;
  filePath: string;           // Absolute path to SKILL.md
  baseDir: string;            // Directory containing SKILL.md
  license?: string;
  compatibility?: string;
  disableModelInvocation?: boolean;
  isBuiltin?: boolean;
}

export interface SkillLoadResult {
  skills: Skill[];
  errors: string[];
}
