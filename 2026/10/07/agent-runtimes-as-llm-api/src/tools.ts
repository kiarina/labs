// The app's tools, shared by both runtimes (JSON Schema), and canned results.
// Only the names, descriptions and schemas reach the model; the handlers stand
// in for the app.

import { members } from './fixture.ts';

export interface ToolDef {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

const str = { type: 'string' };

export const tools: ToolDef[] = [
  {
    name: 'read_document',
    description: 'Read a document (meeting notes, specs) by its ID.',
    inputSchema: { type: 'object', properties: { doc_id: str }, required: ['doc_id'] },
  },
  {
    name: 'get_team_members',
    description: "List the user's team members with their emails.",
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'search_places',
    description: 'Search restaurants and venues.',
    inputSchema: {
      type: 'object',
      properties: {
        area: str,
        keywords: { type: 'array', items: str },
        party_size: { type: 'integer' },
        budget_per_person: { type: 'integer' },
      },
      required: ['area'],
    },
  },
  {
    name: 'check_availability',
    description: 'Check whether a place has a table at the given date and time.',
    inputSchema: {
      type: 'object',
      properties: { place_id: str, date: { type: 'string', description: 'YYYY-MM-DD' }, time: { type: 'string', description: 'HH:MM' }, party_size: { type: 'integer' } },
      required: ['place_id', 'date', 'time', 'party_size'],
    },
  },
  {
    name: 'get_weather',
    description: 'Weather forecast for a city and date.',
    inputSchema: { type: 'object', properties: { city: str, date: str }, required: ['city', 'date'] },
  },
  {
    name: 'create_event',
    description: "Add an event to the user's calendar and invite the attendees.",
    inputSchema: {
      type: 'object',
      properties: {
        title: str,
        start: { type: 'string', description: 'Local date and time, YYYY-MM-DDTHH:MM' },
        duration_minutes: { type: 'integer' },
        place_id: { type: 'string', description: 'Optional place ID from search_places' },
        attendees: { type: 'array', items: { type: 'string', description: 'Email' } },
        note: str,
      },
      required: ['title', 'start', 'duration_minutes', 'attendees'],
    },
  },
  {
    name: 'send_message',
    description: 'Send a message (chat/email) to people.',
    inputSchema: {
      type: 'object',
      properties: { to: { type: 'array', items: { type: 'string', description: 'Email' } }, subject: str, body: str },
      required: ['to', 'body'],
    },
  },
];

export const systemPrompt = `あなたは、アプリに組み込まれたユーザー（鈴木 美咲）の個人アシスタントです。
ユーザーとのこれまでの会話は <messages> に XML で渡されます。human_message はユーザー、ai_message はあなた、tool_call と tool_result はあなたが呼んだツールとその結果です。
会話の続きとして、最後の指示に応えてください。操作が要るときは、渡されたツールを呼んでください（ツールの呼び出しを文章や XML で書かないでください）。
今日は 2026-10-07 です。`;

let eventSeq = 9000;

/** What the app returns for a call. */
export function handle(name: string, args: Record<string, any>): unknown {
  switch (name) {
    case 'create_event':
      return { event_id: `evt_${++eventSeq}`, status: 'created' };
    case 'send_message':
      return { status: 'sent', recipients: Array.isArray(args.to) ? args.to.length : 0 };
    case 'get_team_members':
      return members;
    case 'check_availability':
      return { available: true };
    default:
      return { error: `${name} is not available in this test` };
  }
}
