const duration = 60_000;
const trackWidth = 520;
let phase = 'ready';
let deadline = 0;
let lastClock = '';
let lastRemaining = 60;

function twoDigits(value) {
  return String(value).padStart(2, '0');
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
    sg.update('timer-display', {text: `${twoDigits(Math.floor(remaining / 60))}:${twoDigits(remaining % 60)}`});
    sg.update('track-fill', {
      w: Math.max(1, trackWidth * remaining / 60),
      visible: remaining > 0
    });
    lastRemaining = remaining;
  }

  if (remaining === 0) {
    phase = 'done';
    sg.update('timer-display', {color: '#F4CD79'});
    sg.update('focus-status', {text: '1分経ったよ。おつかれさま！'});
    sg.notify('集中タイムの1分が終了しました。ユーザーに終了を伝えてください。', {wake: true});
  }
}

sg.on('press', 'focus-start', () => {
  if (phase !== 'ready') return;
  deadline = sg.now() + duration;
  phase = 'running';
  sg.update('focus-start', {visible: false});
  sg.update('focus-status', {text: '集中タイム中', visible: true, color: '#F4CD79'});
  tick();
});

tick();
sg.every(200, tick);
