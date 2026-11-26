/// A hand-written scene that uses every element type, run through the same
/// tool handler as the spirit's calls (no model). The 見本 button and the
/// control port's /demo load it.
const List<(String, Map<String, dynamic>)> kDemoScene = [
  (
    'canvas_clear',
    {
      'background': '#1B2233',
      // Drawn for this size; scaled to the screen.
      'design': {'width': 1280, 'height': 800},
    },
  ),
  (
    'canvas_put',
    {
      'elements': [
        {
          'id': 'title',
          'type': 'text',
          'x': 40,
          'y': 28,
          'w': 760,
          'h': 60,
          'text': 'こんにちは！キャンバスの見本です',
          'size': 40,
          'weight': 'bold',
        },
        {
          'id': 'body',
          'type': 'vrm',
          'x': 40,
          'y': 110,
          'w': 420,
          'h': 520,
          'pose': 'wave',
          'expression': 'happy',
          'framing': 'bust',
        },
        {
          'id': 'photo',
          'type': 'image',
          'x': 500,
          'y': 110,
          'w': 360,
          'h': 240,
          'src': 'jpg/street_scene_1774x887_287kb.jpg',
          'fit': 'cover',
          'radius': 16,
        },
        {
          'id': 'clip',
          'type': 'video',
          'x': 880,
          'y': 110,
          'w': 360,
          'h': 240,
          'src': 'mp4/door_open_768x512_24fps_8s_302kb.mp4',
          'loop': true,
          'muted': true,
          'radius': 16,
        },
        {
          'id': 'sun',
          'type': 'svg',
          'x': 520,
          'y': 380,
          'w': 120,
          'h': 120,
          'markup':
              '<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">'
              '<circle cx="50" cy="50" r="22" fill="#FFC83D"/>'
              '<g stroke="#FFC83D" stroke-width="6" stroke-linecap="round">'
              '<line x1="50" y1="6" x2="50" y2="18"/><line x1="50" y1="82" x2="50" y2="94"/>'
              '<line x1="6" y1="50" x2="18" y2="50"/><line x1="82" y1="50" x2="94" y2="50"/>'
              '<line x1="19" y1="19" x2="27" y2="27"/><line x1="73" y1="73" x2="81" y2="81"/>'
              '<line x1="19" y1="81" x2="27" y2="73"/><line x1="73" y1="27" x2="81" y2="19"/>'
              '</g></svg>',
        },
        {
          'id': 'blink',
          'type': 'svg',
          'x': 680,
          'y': 380,
          'w': 120,
          'h': 120,
          'fps': 3,
          'frames': [
            '<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><circle cx="50" cy="50" r="40" fill="#8FD3FF"/><circle cx="36" cy="44" r="6" fill="#222"/><circle cx="64" cy="44" r="6" fill="#222"/><path d="M34 64 Q50 76 66 64" stroke="#222" stroke-width="4" fill="none"/></svg>',
            '<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><circle cx="50" cy="50" r="40" fill="#8FD3FF"/><rect x="30" y="43" width="12" height="3" fill="#222"/><rect x="58" y="43" width="12" height="3" fill="#222"/><path d="M34 64 Q50 76 66 64" stroke="#222" stroke-width="4" fill="none"/></svg>',
          ],
        },
        {
          'id': 'ball',
          'type': 'shape',
          'shape': 'ellipse',
          'x': 840,
          'y': 400,
          'w': 60,
          'h': 60,
          'fill': '#FF6B8B',
        },
        {
          'id': 'question',
          'type': 'choices',
          'x': 500,
          'y': 530,
          'w': 740,
          'h': 130,
          'label': '今日はなにをしたい？',
          'options': ['おしゃべり', '絵を描く', '音楽を聞く'],
        },
        {
          'id': 'name',
          'type': 'input',
          'x': 500,
          'y': 680,
          'w': 520,
          'h': 56,
          'placeholder': 'お名前を教えて',
        },
        {
          'id': 'ok',
          'type': 'button',
          'x': 1040,
          'y': 680,
          'w': 200,
          'h': 56,
          'label': 'はじめる',
        },
        {
          'id': 'voice',
          'type': 'audio',
          'x': 40,
          'y': 680,
          'w': 420,
          'h': 56,
          'src': 'mp3/conversation_2speaker_14s_16k.mp3',
          'autoplay': false,
          'label': '音声の見本',
        },
      ],
    },
  ),
  (
    'canvas_animate',
    {
      'id': 'ball',
      'keyframes': [
        {'y': 400},
        {'y': 470},
      ],
      'duration_ms': 600,
      'repeat': -1,
      'alternate': true,
      'easing': 'ease_in',
    },
  ),
  (
    'canvas_animate',
    {
      'id': 'sun',
      'keyframes': [
        {'rotation': 0},
        {'rotation': 360},
      ],
      'duration_ms': 6000,
      'repeat': -1,
      'easing': 'linear',
    },
  ),
];
