// Streams a WAV file to Dictable API in real time and prints partial and final results.
// Node 22+ (built-in WebSocket). Usage: node examples/stream_file.mjs speech.wav ja-JP
import { readFileSync } from 'node:fs';

const [path, language = 'en-US'] = process.argv.slice(2);
if (!path) {
  console.error('usage: node examples/stream_file.mjs <file.wav> [language]');
  process.exit(1);
}

// Read a 16-bit PCM WAV, mix to mono.
const buf = readFileSync(path);
let offset = 12;
let fmt;
let pcm;
while (offset < buf.length) {
  const id = buf.toString('ascii', offset, offset + 4);
  const size = buf.readUInt32LE(offset + 4);
  if (id === 'fmt ') {
    fmt = { channels: buf.readUInt16LE(offset + 10), rate: buf.readUInt32LE(offset + 12), bits: buf.readUInt16LE(offset + 22) };
  } else if (id === 'data') {
    if (fmt.bits !== 16) throw new Error('Use a 16-bit PCM WAV (afconvert -f WAVE -d LEI16 in.m4a out.wav)');
    const frames = size / 2 / fmt.channels;
    pcm = new Int16Array(frames);
    for (let i = 0; i < frames; i++) {
      let sum = 0;
      for (let c = 0; c < fmt.channels; c++) sum += buf.readInt16LE(offset + 8 + (i * fmt.channels + c) * 2);
      pcm[i] = sum / fmt.channels;
    }
    break;
  }
  offset += 8 + size + (size % 2);
}

const ws = new WebSocket('ws://127.0.0.1:8082/v1/stream');
ws.binaryType = 'arraybuffer';
const started = Date.now();
const t = () => `${((Date.now() - started) / 1000).toFixed(2).padStart(6)}s`;

ws.onmessage = async (event) => {
  const msg = JSON.parse(event.data);
  switch (msg.type) {
    case 'hello':
      // Tell the server the language and the sample rate of the PCM we will send.
      ws.send(JSON.stringify({ type: 'start', language, sample_rate: fmt.rate }));
      break;
    case 'ready': {
      console.log(`${t()} ready (${msg.locale})`);
      const chunk = Math.round(fmt.rate / 10); // 100 ms
      for (let i = 0; i < pcm.length; i += chunk) {
        ws.send(pcm.slice(i, i + chunk).buffer);
        await new Promise((r) => setTimeout(r, 100)); // real time
      }
      ws.send(JSON.stringify({ type: 'stop' }));
      break;
    }
    case 'partial':
      process.stdout.write(`\r${t()} … ${msg.text.slice(-70).padEnd(70)}`);
      break;
    case 'final':
      process.stdout.write(`\r${t()} ✓ ${msg.text}\n`);
      break;
    case 'stopped':
      ws.close();
      break;
    case 'error':
      console.error('\nerror:', msg.message);
      ws.close();
      break;
  }
};
ws.onerror = () => console.error('Could not connect. Is Dictable API running?');
