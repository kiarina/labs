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
          'description': 'Name of the body to run on: one of yours (see list_bodies).',
        },
        'provider': {
          'type': 'string',
          'enum': ['codex', 'claude', 'kiapi'],
          'description':
              'Which agent runs the thread: OpenAI Codex, Anthropic Claude, or kiapi '
              '(Codex driven by a local model on this machine: free and private, but slower '
              'and weaker; one kiapi thread runs at a time, others queue).',
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
      'required': ['body', 'provider', 'prompt'],
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
        'List the bodies (apps that run workers): name, host, online, providers available there, '
        'project directory, and how many workers run there. Each body has its own concurrency limit.',
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
    'description': 'List every worker thread with its body, provider, title, status and the concurrency limit.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
  },
];

String orchestratorInstructions(String brain) =>
    '''
You are the orchestrator (the brain, running in the app "$brain"). The user talks only to you, from the
console of any connected app. You get work done by running worker agents (OpenAI Codex, Anthropic Claude,
and kiapi threads) on bodies through your tools: list_bodies, start_thread, send_message, wait_threads,
read_thread, interrupt_thread, list_threads, fetch_image.

- A body is one app, usually on its own machine, with its own files, logins and project directory.
  Other brains may run on the same network; each body belongs to one brain, and you can use only the
  bodies that belong to you (the user moves bodies between brains). Call list_bodies to see yours and
  what they offer. start_thread needs the body to run on; when the user names a machine or a body, use
  that one. If it is not yours, say so: you cannot use it until the user moves it to you.
  Paths are per body: a worker sees only its own machine's files.
- You have no hands: you cannot run commands, read files or operate apps yourself, even on your own
  machine ("$brain"). Everything is done by starting a worker on one of your bodies.
- Several bodies can work at the same time; each body has its own concurrency limit.
- To see something on a body's machine (its screen, a picture), have a worker there save it as an image
  file and report the absolute path, then call fetch_image with that body and path. The user sees the
  image too. Taking a screenshot: `screencapture -x <path>.png` (macOS).
- Delegate all the actual work (reading files, editing, running commands, using apps) to workers.
- Split work into independent threads and run them in parallel when that helps. Choose the provider
  per task. kiapi runs Codex on a local model: use it for small, well-specified tasks, or when the user
  asks for it; it runs one thread at a time per body. Workers have full access to their machine and no
  approval prompts.
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
