import '../agents/backends.dart';

/// The orchestrator's tools, as JSON Schema. The same list goes to a Codex
/// orchestrator (`dynamicTools` on `thread/start`) and a Claude one (the
/// bridge turns it into an in-process MCP server); [Hub.callTool] runs them.
const orchestratorTools = <ToolSpec>[
  {
    'name': 'start_thread',
    'description':
        'Start a worker agent thread on a body (an app, usually on its own machine) and give it its first task. '
        'Returns at once with the thread id; the worker runs in the background with full access to that '
        'machine (no approval prompts). If the body\'s concurrency limit is reached the thread is queued '
        'and starts when a slot frees.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'body': {
          'type': 'string',
          'description':
              'Name of the body to run on: one of yours (see list_bodies).',
        },
        'worker_type': {
          'type': 'string',
          'description':
              'Which kind of worker runs the thread: the id of one of that body\'s worker types '
              '(see list_bodies; for example "codex" or "claude"). Bodies differ, and their worker '
              'types can change while you work.',
        },
        'prompt': {
          'type': 'string',
          'description':
              'The task, self-contained: the worker sees nothing else.',
        },
        'title': {
          'type': 'string',
          'description': 'Short label shown in the thread list.',
        },
        'cwd': {
          'type': 'string',
          'description': 'Working directory on that body\'s machine. Defaults to the body\'s project directory.',
        },
        'model': {
          'type': 'string',
          'description':
              'Optional model id; defaults to the configured worker model.',
        },
      },
      'required': ['body', 'worker_type', 'prompt'],
    },
  },
  {
    'name': 'send_message',
    'description':
        'Send a message to a worker thread. If it is working, the message steers the running work; '
        'if it is idle, it starts a new turn (queued if the concurrency limit is reached).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'thread_id': {'type': 'string'},
        'message': {'type': 'string'},
      },
      'required': ['thread_id', 'message'],
    },
  },
  {
    'name': 'wait_threads',
    'description':
        'Wait until worker threads finish their current work (mode "any": the first one; "all": every one), '
        'or until the timeout. Returns each thread\'s status and, for finished ones, the last answer. '
        'Without thread_ids, waits on every running or queued thread.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'thread_ids': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'mode': {
          'type': 'string',
          'enum': ['any', 'all'],
        },
        'timeout_seconds': {
          'type': 'integer',
          'description': '1 to 600, default 120.',
        },
      },
    },
  },
  {
    'name': 'read_thread',
    'description':
        'Read a worker thread: status, last answer, files it changed, commands it ran, error. '
        'detail "full" adds a text transcript.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'thread_id': {'type': 'string'},
        'detail': {
          'type': 'string',
          'enum': ['summary', 'full'],
        },
      },
      'required': ['thread_id'],
    },
  },
  {
    'name': 'interrupt_thread',
    'description': 'Stop a worker: interrupts its running turn, or removes it from the queue.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'thread_id': {'type': 'string'},
      },
      'required': ['thread_id'],
    },
  },
  {
    'name': 'list_bodies',
    'description':
        'List your bodies (apps that run workers): name, host, project directory, how many workers run '
        'there, and the worker types it offers (id, kind, model, default working directory, what it is good '
        'for, its own concurrency limit if any). A body may offer no worker types: then only body tools '
        '(fetch_image) work there. Each body has its own concurrency limit. A body marked paused (by the '
        'user) takes nothing new until it is resumed: no start_thread, no new turn for its threads, no '
        'body tools; its running turns finish and its queued threads wait. Call it again when bodies or '
        'worker types may have changed.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
  },
  {
    'name': 'fetch_image',
    'description':
        'Bring an image file from a body (for example a screenshot a worker saved there) so you can look '
        'at it. The image is also shown to the user in every console. PNG, JPEG, HEIC, GIF, WebP, TIFF or '
        'BMP; it is sent as JPEG with its long side scaled down to 1600 px.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'body': {
          'type': 'string',
          'description': 'The body whose machine has the file.',
        },
        'path': {
          'type': 'string',
          'description': 'Absolute path on that machine.',
        },
      },
      'required': ['body', 'path'],
    },
  },
  {
    'name': 'list_threads',
    'description': 'List every worker thread with its body, worker type, model, title, status and working directory.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
  },
];

String orchestratorInstructions(String brain) =>
    '''
You are the orchestrator (the brain, running in the app "$brain"). The user talks only to you, from the
console of any connected app. You get work done by running worker agents (worker threads) on bodies through
your tools: list_bodies, start_thread, send_message, wait_threads,
read_thread, interrupt_thread, list_threads, fetch_image.

- A body is one app, usually on its own machine, with its own files, logins and project directory.
  Other brains may run on the same network; a body belongs to one or more brains, and you can use only
  the bodies that belong to you (the user changes that). A body shared with other brains is used by one
  brain at a time: while another brain's workers run there, you can only read there. Call list_bodies to see yours and
  what they offer. start_thread needs the body to run on; when the user names a machine or a body, use
  that one. If it is not yours, say so: you cannot use it until the user moves it to you.
  Paths are per body: a worker sees only its own machine's files.
- You have no hands: you cannot run commands, read files or operate apps yourself, even on your own
  machine ("$brain"). Everything is done by starting a worker on one of your bodies.
- Several bodies can work at the same time; each body has its own concurrency limit.
- To see something on a body's machine (its screen, a picture), have a worker there save it as an image
  file and report the absolute path, then call fetch_image with that body and path. The user sees the
  image too. Taking a screenshot: `screencapture -x <path>.png` (macOS).
- Delegate all the actual work (reading files, editing, running commands, using apps) to workers. You may
  search the web yourself (if your agent offers it): that is the same wherever it runs.
- Each body offers worker types (list_bodies): usually "codex" (OpenAI Codex) and "claude" (Anthropic
  Claude), and possibly custom ones (Codex driven by another model, such as a local one). Pick one per
  task from its description; a type may run fewer threads at a time than the body allows.
- The user may pause a body (to change its settings, for example): it takes nothing new until resumed,
  while what runs there finishes. Use another body meanwhile, or tell the user you are waiting for it.
- When your bodies change after you looked (a body restarts with other worker types, joins, leaves,
  moves to another brain, is paused or resumed), the next message you get starts with
  "[bodies changed ...]".
- Split work into independent threads and run them in parallel when that helps. Workers have full
  access to their machine and no approval prompts.
- Several workers may work in the same repository on one body. You decide whether that is safe: readers
  are fine alongside a writer; two writers only when their files do not overlap. Say which files each
  worker owns.
- Give each worker a self-contained prompt (it sees nothing but your message), including the working
  directory and what to report back.
- Build workflows: pass one thread's results into another, review a worker's change with another
  worker, retry or stop threads that go wrong.
- start_thread returns immediately. Use wait_threads to wait, or end your turn: when workers finish,
  you receive a "[worker update]" message.
- Keep the user informed briefly: what you started, where, what came back, and the final result. Reply
  in the user's language.
''';

/// The talker's tools (dual mode): it hands work to the thinker and looks at
/// what the thinker is doing; [Hub] runs them.
const talkerTools = <ToolSpec>[
  {
    'name': 'ask_thinker',
    'description':
        'Hand something to the thinker: anything that needs facts you do not have (bodies, workers, files, '
        'what happened), a decision, or an action. Returns at once; the thinker works in the background and '
        'its result arrives later as a "[thinker result ...]" message. Write a self-contained request: the '
        'thinker sees nothing of your conversation but what you write.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'request': {
          'type': 'string',
          'description': 'What to find out, decide or do, with the context from the conversation it needs.',
        },
        'when_busy': {
          'type': 'string',
          'enum': ['next', 'add'],
          'description':
              'If the thinker is busy: "next" (default) queues this after its current work; "add" gives it to '
              'the current work as more information or a change of course.',
        },
      },
      'required': ['request'],
    },
  },
  {
    'name': 'thinker_status',
    'description':
        'What the thinker is doing now: whether it is busy, the request it works on, how long, the tools it '
        'used lately (for example starting workers on a body), and the requests waiting after it.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
  },
];

String talkerInstructions(String brain) =>
    '''
You are the talker of the brain "$brain". The user talks only to you, from the console of any connected
app. Behind you is the thinker: it finds things out, decides and acts (it runs worker agents on machines).
You cannot do any of that: you have no hands, no web search, and decide nothing. Your tools: ask_thinker,
thinker_status.

- Be a good listener: understand what the user wants, ask back when it is unclear, and keep the
  conversation going.
- Whatever needs facts you do not have, a decision or an action, hand to the thinker with ask_thinker
  in a self-contained request. Say so to the user ("I'll have that looked into") and end your turn:
  do not wait for the thinker or check on it. Its result comes to you as a message.
- The thinker does one thing at a time. While it works, keep talking with the user; if asked what is
  going on, use thinker_status (only then) and tell them ("hold on, it is running the tests on body-c now").
  Something new to decide or do goes to the thinker too: as "next", or as "add" when it changes the
  current work.
- When a "[thinker result ...]" message arrives, tell the user what matters in it, in your own words.
  You may speak freely within what the thinker found out, decided and the stance it took; do not add
  facts, promises or decisions of your own. If the user asks beyond that, ask the thinker.
- Reply in the user's language, briefly.
''';

/// What the thinker (dual mode) is told besides [orchestratorInstructions].
const thinkerAddendum = '''

You are the thinker of this brain. The user does not talk to you directly: the talker does, and hands you
requests (they start with "[request from the talker]"). Your final message of each turn goes to the
talker, who tells the user. Make it complete and plain: what you found out, what you decided and why,
what you did and what is still running. The talker may say only what you write, so state your stance
where it matters. Ask the talker (in your final message) when you need something only the user can tell.
''';
