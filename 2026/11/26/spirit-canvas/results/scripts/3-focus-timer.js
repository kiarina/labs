const durationSeconds = 180;
const trackWidth = 520;
let phase = 'ready';
let deadline = 0;
let lastClock = '';
let lastRemaining = durationSeconds;

function twoDigits(value) {
  return String(value).padStart(2, '0');
}

function formatRemaining(seconds) {
  return `${twoDigits(Math.floor(seconds / 60))}:${twoDigits(seconds % 60)}`;
}

function tick() {
  const now = new Date();
  const clock = [now.getHours(), now.getMinutes(), now.getSeconds()].map(twoDigits).join(':');
  if (clock !== lastClock) {
    sg.update('wall-clock', {text: clock});
    lastClock = clock;
  }

  if (phase !== 'running') return;
  const remaining = Math.max(0, Math.ceil((deadline - sg.now()) / 1000));
  if (remaining !== lastRemaining) {
    sg.update('timer-display', {text: formatRemaining(remaining)});
    sg.update('track-fill', {
      w: Math.max(1, trackWidth * remaining / durationSeconds),
      visible: remaining > 0
    });
    lastRemaining = remaining;
  }

  if (remaining === 0) {
    phase = 'done';
    sg.update('timer-display', {color: '#F4CD79'});
    sg.update('focus-status', {text: '3分経ったよ。おつかれさま！'});
    sg.notify('集中タイムの3分が終了しました。ユーザーに終了を伝えてください。', {wake: true});
  }
}

sg.on('press', 'focus-start', () => {
  if (phase !== 'ready') return;
  deadline = sg.now() + durationSeconds * 1000;
  phase = 'running';
  sg.update('focus-start', {visible: false});
  sg.update('focus-status', {text: '集中タイム中', visible: true, color: '#F4CD79'});
  tick();
});

sg.update('wall-clock', {color: '#FFAA60'});
sg.update('timer-display', {text: formatRemaining(durationSeconds), color: '#F3F6FA'});
sg.update('track-fill', {w: trackWidth, visible: true});
sg.update('focus-start', {visible: true});
sg.update('focus-status', {text: '', visible: false});
tick();
sg.every(200, tick);
