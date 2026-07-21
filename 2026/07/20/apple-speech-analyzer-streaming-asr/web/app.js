const startButton = document.querySelector("#startButton");
const stopButton = document.querySelector("#stopButton");
const clearButton = document.querySelector("#clearButton");
const transcript = document.querySelector("#transcript");
const status = document.querySelector("#status");
const timer = document.querySelector("#timer");
const meterFill = document.querySelector("#meterFill");
const consolePanel = document.querySelector(".console");
const microphoneSelect = document.querySelector("#microphoneSelect");
const deviceState = document.querySelector("#deviceState");

let socket;
let audioContext;
let mediaStream;
let processor;
let startedAt;
let timerHandle;
let captureSampleRate;
let analyzerSampleRate = 16000;
let finalText = "";
let partialText = "";

async function refreshMicrophones(preferredDeviceId = microphoneSelect.value) {
  const devices = await navigator.mediaDevices.enumerateDevices();
  const microphones = devices.filter((device) => device.kind === "audioinput");
  microphoneSelect.replaceChildren();

  const defaultOption = document.createElement("option");
  defaultOption.value = "";
  defaultOption.textContent = "システム既定のマイク";
  microphoneSelect.append(defaultOption);
  microphones
    .filter((device) => device.deviceId !== "default")
    .forEach((device, index) => {
      const option = document.createElement("option");
      option.value = device.deviceId;
      option.textContent = device.label || `マイク ${index + 1}`;
      microphoneSelect.append(option);
    });

  if ([...microphoneSelect.options].some((option) => option.value === preferredDeviceId)) {
    microphoneSelect.value = preferredDeviceId;
  }
}

function renderTranscript() {
  if (!finalText && !partialText) {
    transcript.innerHTML = '<span class="placeholder">マイクを開始して、日本語で話してください。</span>';
    return;
  }
  transcript.replaceChildren();
  const finalSpan = document.createElement("span");
  finalSpan.className = "final-text";
  finalSpan.textContent = finalText;
  const partialSpan = document.createElement("span");
  partialSpan.className = "partial-text";
  partialSpan.textContent = partialText;
  transcript.append(finalSpan, partialSpan);
}

function setStatus(text, recording = false) {
  status.textContent = text;
  consolePanel.classList.toggle("recording", recording);
}

function updateTimer() {
  const seconds = Math.floor((performance.now() - startedAt) / 1000);
  timer.textContent = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

async function startRecording() {
  startButton.disabled = true;
  microphoneSelect.disabled = true;
  setStatus("マイクの許可を待っています…");
  try {
    const audioConstraints = { channelCount: 1 };
    if (microphoneSelect.value) {
      audioConstraints.deviceId = { exact: microphoneSelect.value };
    }
    mediaStream = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints });
    const track = mediaStream.getAudioTracks()[0];
    if (!track) throw new Error("音声トラックを取得できませんでした");
    const trackSettings = track.getSettings();
    await refreshMicrophones(trackSettings.deviceId);
    deviceState.textContent = `${track.label || "名称不明のマイク"} · 接続中`;
    track.addEventListener("mute", () => { deviceState.textContent = `${track.label} · ミュート`; });
    track.addEventListener("unmute", () => { deviceState.textContent = `${track.label} · 接続中`; });
    track.addEventListener("ended", () => { deviceState.textContent = `${track.label} · 終了`; });

    audioContext = new AudioContext();
    captureSampleRate = audioContext.sampleRate;
    await audioContext.audioWorklet.addModule("processor.js?v=2");

    socket = new WebSocket("ws://127.0.0.1:8765");
    socket.binaryType = "arraybuffer";
    await new Promise((resolve, reject) => {
      socket.addEventListener("open", resolve, { once: true });
      socket.addEventListener("error", reject, { once: true });
    });
    socket.send(JSON.stringify({ sampleRate: captureSampleRate }));
    socket.addEventListener("message", handleServerMessage);
    socket.addEventListener("close", handleSocketClose);

    const source = audioContext.createMediaStreamSource(mediaStream);
    processor = new AudioWorkletNode(audioContext, "pcm-forwarder");
    const silent = audioContext.createGain();
    silent.gain.value = 0;
    processor.port.onmessage = ({ data }) => {
      if (data.type === "samples" && socket?.readyState === WebSocket.OPEN) {
        socket.send(data.samples.buffer);
      } else if (data.type === "level") {
        meterFill.style.width = `${Math.min(100, data.value * 550)}%`;
      }
    };
    source.connect(processor).connect(silent).connect(audioContext.destination);
    await audioContext.resume();
    if (audioContext.state !== "running") {
      throw new Error(`音声処理を開始できませんでした (${audioContext.state})`);
    }

    startedAt = performance.now();
    timerHandle = setInterval(updateTimer, 250);
    setStatus(`文字起こし中 · ${captureSampleRate / 1000}→16 kHz · 音声待ち`, true);
    stopButton.disabled = false;
  } catch (error) {
    setStatus(`開始できません: ${error.message}`);
    startButton.disabled = false;
    microphoneSelect.disabled = false;
    await releaseAudio();
  }
}

function handleServerMessage(event) {
  const message = JSON.parse(event.data);
  if (message.type === "ready") {
    analyzerSampleRate = message.sampleRate;
    setStatus(`文字起こし中 · ${captureSampleRate / 1000}→${analyzerSampleRate / 1000} kHz · 音声待ち`, true);
  } else if (message.type === "audio-stats") {
    const level = message.rmsDbfs <= -80 ? "無音" : `${message.rmsDbfs.toFixed(0)} dBFS`;
    setStatus(
      `文字起こし中 · ${captureSampleRate / 1000}→${analyzerSampleRate / 1000} kHz · ${message.audioSeconds.toFixed(1)}秒 · ${level}`,
      true,
    );
  } else if (message.type === "result") {
    if (message.final) {
      finalText += message.text;
      partialText = "";
    } else {
      partialText = message.text;
    }
    renderTranscript();
  } else if (message.type === "done") {
    setStatus("確定しました");
    resetControls();
  } else if (message.type === "error") {
    setStatus(`エラー: ${message.message}`);
    resetControls();
  }
}

function handleSocketClose() {
  if (!stopButton.disabled) {
    setStatus("接続が終了しました。デモを再起動して、もう一度お試しください。");
    void releaseAudio();
    resetControls();
  }
}

async function stopRecording() {
  stopButton.disabled = true;
  setStatus("最終結果を確定中…");
  await releaseAudio();
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "stop" }));
}

async function releaseAudio() {
  mediaStream?.getTracks().forEach((track) => track.stop());
  processor?.disconnect();
  if (audioContext && audioContext.state !== "closed") await audioContext.close();
  mediaStream = undefined;
  processor = undefined;
  audioContext = undefined;
  deviceState.textContent = "未接続";
  meterFill.style.width = "0";
  clearInterval(timerHandle);
}

function resetControls() {
  clearInterval(timerHandle);
  startButton.disabled = false;
  stopButton.disabled = true;
  microphoneSelect.disabled = false;
  socket?.close();
  socket = undefined;
}

startButton.addEventListener("click", startRecording);
stopButton.addEventListener("click", stopRecording);
clearButton.addEventListener("click", () => {
  finalText = "";
  partialText = "";
  timer.textContent = "00:00";
  renderTranscript();
});

navigator.mediaDevices.addEventListener("devicechange", () => {
  if (!microphoneSelect.disabled) void refreshMicrophones();
});
void refreshMicrophones();
