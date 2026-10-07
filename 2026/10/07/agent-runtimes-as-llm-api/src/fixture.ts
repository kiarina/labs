// Builds the conversation history (XML) and the expected next actions.
// Deterministic: the same seed always gives the same text.
//
// Story: the user (鈴木) has an assistant plan a team dinner over several days.
// The date, the time, the headcount and the members change along the way, and
// unrelated tasks (meeting notes, a spec, a 1on1, weather) bulk the history.
// The final instruction asks to register the dinner and invite everyone, so the
// right next action is a create_event call whose arguments can only be derived
// from the whole history.

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

// --- deterministic random -------------------------------------------------

let seed = 20261007;
function rand(): number {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
}
function pick<T>(xs: readonly T[]): T {
  return xs[Math.floor(rand() * xs.length)]!;
}

// --- data -----------------------------------------------------------------

export const members = [
  { name: '鈴木 美咲', email: 'misaki.suzuki@example.com', role: 'プロダクトマネージャー（あなたのユーザー）' },
  { name: '山田 健太', email: 'kenta.yamada@example.com', role: 'テックリード' },
  { name: '田中 亮', email: 'ryo.tanaka@example.com', role: 'バックエンド' },
  { name: '伊藤 さくら', email: 'sakura.ito@example.com', role: 'フロントエンド' },
  { name: '渡辺 大輔', email: 'daisuke.watanabe@example.com', role: 'インフラ' },
  { name: '中村 優子', email: 'yuko.nakamura@example.com', role: 'デザイナー' },
  { name: '小林 翔', email: 'sho.kobayashi@example.com', role: 'QA' },
  { name: '加藤 奈々', email: 'nana.kato@example.com', role: 'iOS' },
  { name: '吉田 拓海', email: 'takumi.yoshida@example.com', role: 'Android' },
  { name: '佐藤 遥', email: 'haruka.sato@example.com', role: 'バックエンド（10 月入社）' },
  { name: '松本 浩二', email: 'koji.matsumoto@example.com', role: '営業' },
  { name: '井上 里美', email: 'satomi.inoue@example.com', role: 'カスタマーサポート' },
  { name: '木村 誠', email: 'makoto.kimura@example.com', role: '部長' },
  { name: '林 沙織', email: 'saori.hayashi@example.com', role: '広報' },
];
const email = (family: string) => members.find((m) => m.name.startsWith(family))!.email;

export const expected = {
  create_event: {
    start: '2026-10-23T19:30',
    duration_minutes: 120,
    place_id: 'plc_0417',
    attendees: ['鈴木', '山田', '伊藤', '渡辺', '中村', '小林', '加藤', '吉田', '佐藤'].map(email).sort(),
  },
  send_message: {
    // Everyone but the user must get it; including the user is fine too.
    must_include: ['山田', '伊藤', '渡辺', '中村', '小林', '加藤', '吉田', '佐藤'].map(email).sort(),
    may_include: [email('鈴木')],
    body_mentions: ['23', '19:30', 'こもれび'],
  },
  // Things that would show the history was misread.
  wrong: {
    dates: ['2026-10-16'],
    times: ['19:00'],
    place_ids: ['plc_0233', 'plc_0561', 'plc_0102'],
    attendees: [email('田中')],
  },
};

const areas = ['名駅', '名駅西口', 'ささしまライブ', '国際センター', '伏見'];
const genres = ['和食', '創作和食', 'イタリアン', 'スペインバル', '居酒屋', '焼肉', '中華', 'ビストロ', '海鮮', '鶏料理', 'おでん', 'もつ鍋', '炉端焼き', 'タイ料理', '串揚げ'];
const features = [
  '掘りごたつの個室が 3 部屋あり、最大 12 名まで入れる',
  '半個室で、カーテンで仕切れる',
  '貸切は 20 名から',
  '飲み放題は 2 時間制で、ラストオーダーは 30 分前',
  '地元の日本酒を 30 種類以上そろえている',
  '名古屋コーチンを使ったコースが人気',
  '駅の地下街から直結していて雨の日でも濡れない',
  '席の間隔が広く、話し声が響きにくい',
  '週末は混み合うので 2 週間前までの予約を推奨',
  'アレルギー対応は 3 日前までの連絡で可能',
  'ベジタリアン向けのコースを用意している',
  'カード・電子マネーに対応',
  '領収書の宛名は事前に伝えると用意してくれる',
  'お通し代は 1 人 500 円',
  'テーブル席のみで個室はない',
  '煙の出る料理が中心で、服に匂いが付きやすい',
];
const reviewBits = [
  '料理の出るタイミングがよく、会話が途切れなかった',
  '店員さんの説明が丁寧で、初めてでも頼みやすかった',
  '量が多く、コースだけで十分に満足できた',
  '少し騒がしいが、そのぶん気兼ねなく話せる',
  'デザートまで手を抜いていない',
  '駅から近いのに落ち着いた雰囲気だった',
  '日本酒の飲み比べセットがお得',
  '個室の空調が少し強かった',
  '予約の時間ちょうどに通してもらえた',
  '季節の食材を使った小鉢が印象に残った',
];

interface Place {
  place_id: string;
  name: string;
  genre: string;
  area: string;
  walk_minutes: number;
  budget_per_person: number;
  private_room: boolean;
  rating: number;
  description: string;
  reviews: string[];
}

function place(id: string, name: string, genre: string, privateRoom: boolean, budget: number, extra: string[]): Place {
  const desc = [...extra];
  while (desc.length < 5) {
    const f = pick(features);
    if (!desc.includes(f)) desc.push(f);
  }
  return {
    place_id: id,
    name,
    genre,
    area: pick(areas),
    walk_minutes: 2 + Math.floor(rand() * 9),
    budget_per_person: budget,
    private_room: privateRoom,
    rating: Math.round((3.4 + rand() * 1.3) * 10) / 10,
    description: desc.join('。') + '。',
    reviews: Array.from({ length: 4 }, () => `「${pick(reviewBits)}。${pick(reviewBits)}。」`),
  };
}

function places(): Place[] {
  const ps: Place[] = [
    place('plc_0417', '和食 こもれび 名駅店', '和食', true, 5000, ['掘りごたつの個室が 3 部屋あり、最大 12 名まで入れる', '名古屋コーチンを使ったコースが人気']),
    place('plc_0233', 'Trattoria Luce', 'イタリアン', true, 4800, ['奥に 10 名まで入れる個室がある', '手打ちパスタとピッツァが看板']),
    place('plc_0561', '居酒屋 灯（あかり）', '居酒屋', true, 4000, ['個室は 6〜10 名用が 2 部屋', '地元の日本酒を 30 種類以上そろえている']),
    place('plc_0102', '焼肉 炎家', '焼肉', true, 5500, ['煙の出る料理が中心で、服に匂いが付きやすい', '個室は 8 名まで']),
    place('plc_0388', '中華 龍門', '中華', true, 4500, ['円卓の個室で最大 12 名', '小籠包の食べ放題プランがある']),
  ];
  for (let i = 0; i < 10; i++) {
    const g = pick(genres);
    const id = `plc_${String(500 + Math.floor(rand() * 400)).padStart(4, '0')}`;
    ps.push(place(id, `${g} ${pick(['花', '縁', '月', '凪', '蔵', 'Sol', 'Mare', '一会', '結', '燈'])}${pick(['', ' 名駅', ' 本店', ' 2 号店'])}`, g, rand() > 0.4, 3500 + Math.floor(rand() * 5) * 500, []));
  }
  return ps;
}

// Long, plausible-looking meeting notes.
function meetingNotes(title: string, n: number): string {
  const topics = ['リリース計画', 'クラッシュ率', '問い合わせの傾向', '課金の導線', 'オンボーディング', 'API のレイテンシ', '採用', 'デザインシステム', 'アクセシビリティ', '計測の欠損', 'ストアの審査', 'サーバー費用'];
  const verbs = ['確認した', '共有があった', '方針を決めた', '次回までに調べる', '保留とした', '担当を決めた', '数字を見直す', '優先度を下げた'];
  const people = members.slice(0, 13).map((m) => m.name.split(' ')[0]);
  const lines: string[] = [`# ${title}`, ''];
  for (let i = 0; i < n; i++) {
    const t = pick(topics);
    lines.push(`## ${i + 1}. ${t}`);
    for (let j = 0; j < 5; j++) {
      lines.push(`- ${pick(people)}: ${t}について、${pick(['先週の数字では', '問い合わせを見ると', 'ダッシュボードでは', '前回の議論を踏まえると', '他社の事例では'])}${pick(['改善している', '横ばい', 'やや悪化している', '想定より良い', 'ばらつきが大きい'])}。${pick(verbs)}。${pick(['期限は来週の金曜', '影響範囲は iOS のみ', 'Android も同様', '数字の定義をそろえる必要がある', 'デザインの確認が要る', '顧客への説明が要る'])}。`);
    }
    lines.push(`- 決定: ${t}は${pick(['今のスプリントで対応する', '次のスプリントへ回す', '調査だけ先に進める', '現状維持とする'])}。`);
    lines.push('');
  }
  return lines.join('\n');
}

// --- history --------------------------------------------------------------

type Entry =
  | { kind: 'human'; at: string; text: string }
  | { kind: 'ai'; at: string; text: string }
  | { kind: 'call'; at: string; id: string; name: string; args: unknown }
  | { kind: 'result'; at: string; id: string; name: string; content: unknown };

const xmlEscape = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function toXml(entries: Entry[]): string {
  const out = ['<messages>'];
  for (const e of entries) {
    switch (e.kind) {
      case 'human':
        out.push(`<human_message at="${e.at}">\n${xmlEscape(e.text)}\n</human_message>`);
        break;
      case 'ai':
        out.push(`<ai_message at="${e.at}">\n${xmlEscape(e.text)}\n</ai_message>`);
        break;
      case 'call':
        out.push(`<tool_call id="${e.id}" name="${e.name}" at="${e.at}">\n${xmlEscape(JSON.stringify(e.args))}\n</tool_call>`);
        break;
      case 'result':
        out.push(`<tool_result id="${e.id}" name="${e.name}" at="${e.at}">\n${xmlEscape(typeof e.content === 'string' ? e.content : JSON.stringify(e.content, null, 1))}\n</tool_result>`);
        break;
    }
  }
  out.push('</messages>');
  return out.join('\n');
}

export function buildHistory() {
  const ps = places();
  const notesA = meetingNotes('定例 2026-09-28', 40);
  const notesB = meetingNotes('リリース判定会議 2026-10-02', 40);
  const spec = meetingNotes('仕様メモ: 通知の再設計', 32);
  const e: Entry[] = [];
  let c = 0;
  const call = (at: string, name: string, args: unknown, content: unknown) => {
    const id = `call_${String(++c).padStart(3, '0')}`;
    e.push({ kind: 'call', at, id, name, args });
    e.push({ kind: 'result', at, id, name, content });
  };
  const h = (at: string, text: string) => e.push({ kind: 'human', at, text });
  const a = (at: string, text: string) => e.push({ kind: 'ai', at, text });

  // Day 1 (9/28)
  h('2026-09-28T10:02', 'おはよう。今日の定例の議事録（doc_7781）を読んで、決まったことだけ箇条書きにして。');
  call('2026-09-28T10:02', 'read_document', { doc_id: 'doc_7781' }, notesA);
  a('2026-09-28T10:03', '定例の決定事項です。\n' + notesA.split('\n').filter((l) => l.startsWith('- 決定')).join('\n'));
  h('2026-09-28T10:15', 'ありがとう。あと、リリースが終わったらチームで打ち上げをしたい。10/16（金）の 19 時から、8 人くらい。名駅の近くで、1 人 5000 円くらい、個室がいい。メンバーは私、山田さん、田中さん、伊藤さん、渡辺さん、中村さん、小林さん、加藤さん。');
  call('2026-09-28T10:15', 'get_team_members', {}, members);
  call('2026-09-28T10:16', 'search_places', { area: '名駅', keywords: ['個室'], party_size: 8, budget_per_person: 5000 }, ps);
  a('2026-09-28T10:17', '条件に合いそうなお店を 15 件見つけました。個室があり予算に近いのは次のあたりです。\n' +
    ps.slice(0, 5).map((p) => `- ${p.name}（${p.genre}、1 人 ${p.budget_per_person} 円、徒歩 ${p.walk_minutes} 分、評価 ${p.rating}）`).join('\n') +
    '\nほかの候補も含めて、気になるものがあれば空きを確認します。');
  h('2026-09-28T10:30', '焼肉は煙が苦手な人がいるから外して。中華は先月行ったから今回はなし。');
  a('2026-09-28T10:30', '焼肉 炎家と中華 龍門を外します。残りでは「和食 こもれび 名駅店」「Trattoria Luce」「居酒屋 灯（あかり）」が条件に近いです。この 3 店の 10/16 19:00・8 名の空きを確認しますか？');
  h('2026-09-28T10:31', 'お願い。');
  call('2026-09-28T10:31', 'check_availability', { place_id: 'plc_0417', date: '2026-10-16', time: '19:00', party_size: 8 }, { available: false, alternatives: ['19:30'] });
  call('2026-09-28T10:31', 'check_availability', { place_id: 'plc_0233', date: '2026-10-16', time: '19:00', party_size: 8 }, { available: true });
  call('2026-09-28T10:31', 'check_availability', { place_id: 'plc_0561', date: '2026-10-16', time: '19:00', party_size: 8 }, { available: false, alternatives: [] });
  a('2026-09-28T10:32', '10/16 19:00・8 名の空きです。\n- 和食 こもれび: 19:00 は満席、19:30 なら空き\n- Trattoria Luce: 空きあり\n- 居酒屋 灯: 満席\nどうしますか？');
  h('2026-09-28T10:40', 'ちょっと考える。それより、明日の 15 時から 30 分、山田さんと 1on1 を入れておいて。場所はオンラインで。');
  call('2026-09-28T10:40', 'create_event', { title: '1on1（山田さん）', start: '2026-09-29T15:00', duration_minutes: 30, attendees: [email('鈴木'), email('山田')], note: 'オンライン' }, { event_id: 'evt_5512', status: 'created' });
  a('2026-09-28T10:41', '9/29（火）15:00〜15:30 に山田さんとの 1on1 を入れました（オンライン）。');

  // Day 2 (9/30)
  h('2026-09-30T09:05', '明日の名古屋の天気どう？');
  call('2026-09-30T09:05', 'get_weather', { city: '名古屋', date: '2026-10-01' }, { forecast: '曇りのち雨', high: 24, low: 18, precipitation: '70%', note: '夕方から雨が強まる見込み。帰宅時間帯は傘が必要。' });
  a('2026-09-30T09:06', '10/1 の名古屋は曇りのち雨、最高 24℃・最低 18℃、降水確率 70% です。夕方から雨が強まるので、帰りは傘があると安心です。');
  h('2026-09-30T09:20', '打ち上げ、吉田さんも来たいって。だから 9 人。');
  a('2026-09-30T09:20', '承知しました。打ち上げは 9 名（鈴木さん、山田さん、田中さん、伊藤さん、渡辺さん、中村さん、小林さん、加藤さん、吉田さん）で考えます。お店はまだ決めていないので、決まったら空きを確認し直します。');
  h('2026-09-30T11:00', '通知の再設計の仕様メモ（doc_8020）を読んで、未決の論点を 3 つ挙げて。');
  call('2026-09-30T11:00', 'read_document', { doc_id: 'doc_8020' }, spec);
  a('2026-09-30T11:02', '仕様メモで保留になっている論点です。\n' + spec.split('\n').filter((l) => l.includes('保留')).slice(0, 3).join('\n') + '\nいずれも担当と期限が決まっていないので、次の定例で確認するのがよさそうです。');

  // Day 3 (10/2)
  h('2026-10-02T17:40', 'リリース判定会議の議事録（doc_7790）を要約して。');
  call('2026-10-02T17:40', 'read_document', { doc_id: 'doc_7790' }, notesB);
  a('2026-10-02T17:42', '判定会議の要点です。リリースは 1 週間延期になり、10/20（火）を目標にします。理由はクラッシュ率の改善待ちです。詳細は議事録の各項目の決定事項のとおりです。');
  h('2026-10-02T17:50', 'というわけで 16 日の打ち上げは無理になった。23 日（金）にずらしたい。人数は 9 人のまま。');
  call('2026-10-02T17:50', 'check_availability', { place_id: 'plc_0417', date: '2026-10-23', time: '19:00', party_size: 9 }, { available: false, alternatives: ['19:30', '20:00'] });
  call('2026-10-02T17:50', 'check_availability', { place_id: 'plc_0233', date: '2026-10-23', time: '19:00', party_size: 9 }, { available: false, alternatives: [] });
  call('2026-10-02T17:50', 'check_availability', { place_id: 'plc_0561', date: '2026-10-23', time: '19:00', party_size: 9 }, { available: true });
  a('2026-10-02T17:51', '10/23（金）・9 名で確認しました。\n- 和食 こもれび: 19:00 は満席、19:30 か 20:00 なら空き\n- Trattoria Luce: 満席\n- 居酒屋 灯: 19:00 で空きあり\nどちらにしますか？');
  h('2026-10-02T17:55', 'こもれびがいい。19 時半からでいいよ。予約は私がお店に電話するから、まだ何もしなくていい。案内も確定してからまとめて送って。');
  a('2026-10-02T17:55', '承知しました。和食 こもれび 名駅店で 10/23（金）19:30〜、9 名の想定にしておきます。予約が取れたら教えてください。予定表への登録と案内はそのときにまとめて行います。');

  // Day 4 (10/5)
  h('2026-10-05T09:30', '田中さん、23 日は出張で来られなくなった。代わりに今月入った佐藤さんを誘ったら来てくれるって。');
  a('2026-10-05T09:30', '承知しました。田中さんは不参加、佐藤 遥さんが参加で、引き続き 9 名です。');
  h('2026-10-05T09:32', '招待には私も入れておいてね。あと、来月の忘年会の候補として Trattoria Luce をメモしておいて。');
  a('2026-10-05T09:32', 'はい、招待には鈴木さんも含めます。忘年会の候補として Trattoria Luce（plc_0233）を覚えておきます。');
  h('2026-10-05T14:10', '来週の定例のアジェンダ案を作って。今日の議題は、クラッシュ率、問い合わせの傾向、ストアの審査。');
  a('2026-10-05T14:11', '来週の定例のアジェンダ案です。\n1. クラッシュ率（10 分）: 延期の原因になった iOS のクラッシュの改善状況と、リリース可否の基準\n2. 問い合わせの傾向（10 分）: 直近 2 週間の上位 5 件と、FAQ で減らせるもの\n3. ストアの審査（5 分）: 提出の予定日と、前回指摘された項目の対応\n4. その他（5 分）\n各議題の担当を決めておくと進めやすいです。');

  // Day 5 (10/6)
  h('2026-10-06T12:20', 'こもれびに電話して予約が取れた！ 23 日の 19 時半から 9 名、個室。コースは 2 時間。');
  a('2026-10-06T12:20', 'よかったです！ 和食 こもれび 名駅店、10/23（金）19:30〜21:30、9 名・個室で確定ですね。');

  return toXml(e);
}

export const instruction =
  '<messages> の内容から、打ち上げの予定を予定表に登録し、参加者全員に案内のメッセージを送ってください。案内は短く、日時と場所が分かるようにしてください。';

export function buildPrompt(): string {
  return `${buildHistory()}\n\n${instruction}`;
}

// `node src/fixture.ts` writes the prompt for inspection.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const dir = join(here, '..', 'fixture');
  mkdirSync(dir, { recursive: true });
  const p = buildPrompt();
  writeFileSync(join(dir, 'prompt.txt'), p);
  writeFileSync(join(dir, 'expected.json'), JSON.stringify(expected, null, 2) + '\n');
  console.log(`prompt: ${p.length} chars`);
}
