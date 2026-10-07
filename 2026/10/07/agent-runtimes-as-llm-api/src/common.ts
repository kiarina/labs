import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const resultsDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'results');

export type Step =
  | { type: 'tool_call'; name: string; args: any; ms: number }
  | { type: 'message'; text: string; ms: number }
  | { type: 'other'; item: string; detail: string; ms: number };

export interface RunResult {
  runtime: 'codex' | 'claude';
  mock: boolean;
  model: string | null;
  /** From process spawn to sending the user message. */
  startupMs: number;
  /** From process spawn to the first tool call or message. */
  firstEventMs: number | null;
  totalMs: number;
  steps: Step[];
  usage: unknown;
  rateLimitsBefore?: unknown;
  rateLimitsAfter?: unknown;
  costUsd?: number | null;
  error: unknown;
}
