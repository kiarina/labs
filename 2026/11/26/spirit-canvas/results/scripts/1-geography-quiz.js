const questions = [
  { text: '日本でいちばん長い川はどれ？', options: ['利根川', '信濃川', '石狩川', '木曽川'], answer: 1 },
  { text: '日本で面積がいちばん大きい湖はどれ？', options: ['霞ヶ浦', 'サロマ湖', '猪苗代湖', '琵琶湖'], answer: 3 },
  { text: '日本海と太平洋の両方に面する県はどこ？', options: ['青森県', '岩手県', '秋田県', '山形県'], answer: 0 }
];
const letters = ['A', 'B', 'C', 'D'];
const colors = {
  neutral: '#E9F1EC', ink: '#173B31', muted: '#426757', faint: '#F2F5F2',
  correct: '#DDEECC', correctInk: '#234D27', wrong: '#F8DFD9', wrongInk: '#812F28',
  current: '#DCEDAA'
};
let index = 0;
let score = 0;
let locked = false;

function showQuestion() {
  const question = questions[index];
  locked = false;
  sg.update('counter', {text: `第${index + 1}問  /  全${questions.length}問`});
  sg.update('question', {text: question.text});
  sg.update(`mark${index}`, {text: String(index + 1), background: colors.current, color: colors.ink});
  question.options.forEach((option, choice) => {
    sg.update(`option${choice}`, {label: `${letters[choice]}   ${option}`, color: colors.neutral, text_color: colors.ink});
  });
  sg.update('feedback-bg', {fill: colors.faint});
  sg.update('feedback-title', {text: '答えをひとつ選んでね', color: colors.muted});
  sg.update('feedback-detail', {text: ''});
  sg.update('completion', {text: ''});
  sg.update('next', {visible: false});
}

function answer(choice) {
  if (locked) return;
  locked = true;
  const question = questions[index];
  const correct = choice === question.answer;
  const tone = correct ? colors.correct : colors.wrong;
  const ink = correct ? colors.correctInk : colors.wrongInk;
  if (correct) score += 1;
  sg.update('score', {text: `${score} / ${questions.length}`});
  sg.update('answered', {text: `回答済み  ${index + 1} / ${questions.length}`});
  sg.update(`mark${index}`, {text: correct ? '○' : '×', color: ink, background: tone});
  sg.update('feedback-bg', {fill: tone});
  sg.update('feedback-title', {text: correct ? '○ 正解！' : '× 不正解', color: ink});
  sg.update('feedback-detail', {text: `正解は ${letters[question.answer]}  ${question.options[question.answer]}`});
  sg.update(`option${question.answer}`, {color: colors.correct, text_color: colors.correctInk});
  if (!correct) sg.update(`option${choice}`, {color: colors.wrong, text_color: colors.wrongInk});
  if (index + 1 === questions.length) {
    sg.update('completion', {text: `全${questions.length}問終了！  ${questions.length}問中${score}問正解`});
  } else {
    sg.update('next', {visible: true});
  }
}

letters.forEach((_, choice) => sg.on('press', `option${choice}`, () => answer(choice)));
sg.on('press', 'next', () => {
  if (!locked || index + 1 >= questions.length) return;
  index += 1;
  showQuestion();
});
showQuestion();
