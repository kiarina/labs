// Writes fixture/prompt.txt, expected.json and tools.json (for the Python probes).
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildPrompt, expected, members } from './fixture.ts';
import { systemPrompt, tools } from './tools.ts';

const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixture');
mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, 'prompt.txt'), buildPrompt());
writeFileSync(join(dir, 'expected.json'), JSON.stringify(expected, null, 2) + '\n');
writeFileSync(join(dir, 'tools.json'), JSON.stringify({ systemPrompt, tools, members }, null, 2) + '\n');
console.log(`wrote ${dir}`);
