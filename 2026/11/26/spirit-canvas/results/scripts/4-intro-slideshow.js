const slides = [
  {
    title: 'このアプリに住む精霊',
    body: 'おしゃべりしたり、話を聞いたり。\nここでのあなたの話し相手だよ。',
    accent: '#6334A0', tint: '#EBE1F7', pose: 'wave', expression: 'happy', weight: 0.65
  },
  {
    title: '一緒に考えるよ',
    body: '気になることを調べたり、\nアイデアを形にしたりできるよ。',
    accent: '#165C53', tint: '#DCEFE7', pose: 'think', expression: 'relaxed', weight: 0.4
  },
  {
    title: '遊びも集中も',
    body: 'クイズを出したり、\n集中タイムの終わりを知らせたり。',
    accent: '#873F19', tint: '#F4E5DB', pose: 'nod', expression: 'happy', weight: 0.65
  }
];
const slideDuration = 4000;
const lastIndex = slides.length - 1;
let activeIndex = 0;

function showSlide(index) {
  activeIndex = index;
  const slide = slides[index];
  sg.update('intro-title', {text: slide.title});
  sg.update('intro-body', {text: slide.body});
  sg.update('intro-label', {color: slide.accent, background: slide.tint});
  sg.update('intro-rule', {fill: slide.accent});
  sg.update('intro-avatar', {pose: slide.pose, expression: slide.expression, expression_weight: slide.weight});
  sg.update('intro-count', {text: `${index + 1} / ${slides.length}`});
  slides.forEach((_, step) => {
    sg.update(`intro-step${step}`, {fill: step === index ? slide.accent : '#DDD7CE'});
  });
  sg.update('intro-replay', {visible: index === lastIndex});
}

function play() {
  showSlide(0);
  sg.after(slideDuration, () => showSlide(1));
  sg.after(slideDuration * 2, () => showSlide(lastIndex));
}

sg.on('press', 'intro-replay', () => {
  if (activeIndex === lastIndex) play();
});
play();
