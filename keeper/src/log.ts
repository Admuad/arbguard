/**
 * log.ts — structured JSON logs (PHASE3-SPEC.md §1.6).
 *
 * One JSON line per watched policy per poll cycle, appended to
 * keeper/decisions.log and to stdout, with exactly the spec's fields.
 * No line ever contains the private key.
 */
import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { Decision } from './triggers.js';

export interface DecisionLine {
  ts: string;
  chainId: number;
  guard: string;
  policyId: number;
  mode: string;
  decision: Decision;
  reason: string;
  hourUsePct: number;
  dayUsePct: number;
  blockUsePct: number;
  dryRun: boolean;
  txHash: string | null;
}

export class DecisionLog {
  private readonly filePath: string;

  constructor(logFile: string) {
    // Resolved relative to keeper/ (the process working directory).
    this.filePath = resolve(process.cwd(), logFile);
  }

  get path(): string {
    return this.filePath;
  }

  append(line: DecisionLine): void {
    const text = JSON.stringify(line);
    // Stdout first (always visible), then the append-only file.
    console.log(text);
    try {
      appendFileSync(this.filePath, text + '\n', { encoding: 'utf8' });
    } catch (err) {
      console.error(`failed to append to decisions log ${this.filePath}: ${(err as Error).message}`);
    }
  }

  /** Non-decision JSON line (startup config, errors). Stdout only. */
  info(obj: Record<string, unknown>): void {
    console.log(JSON.stringify({ ts: new Date().toISOString(), ...obj }));
  }
}
