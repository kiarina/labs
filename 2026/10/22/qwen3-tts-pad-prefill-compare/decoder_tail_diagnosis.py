"""Decode identical saved generated codes with different reference decoder context."""
import argparse,hashlib,json
from pathlib import Path
import mlx.core as mx
import numpy as np
import soundfile as sf
from huggingface_hub import snapshot_download
from mlx_audio.tts.utils import load_model
from mlx_audio.utils import load_audio
from live import prepare_clone
from bench import MODEL,REV

p=argparse.ArgumentParser();p.add_argument('--reference',required=True);p.add_argument('--transcript-file',required=True);p.add_argument('--trace',required=True);p.add_argument('--original-wave',required=True);p.add_argument('--output',default='output-decoder-tail');args=p.parse_args()
out=Path(args.output);out.mkdir(parents=True,exist_ok=True)
model=load_model(snapshot_download(MODEL,revision=REV));prompt=prepare_clone(model,load_audio(args.reference,sample_rate=24000),Path(args.transcript_file).read_text().strip())
j=json.loads(Path(args.trace).read_text());codes=mx.array(j['trace']['codes']).T[None,:,:]
original,sr=sf.read(args.original_wave,dtype='float32');assert sr==24000
hashpcm=lambda x:hashlib.sha256(x.tobytes()).hexdigest()
rows=[]
for name,count in [('full',int(prompt.ref_codes.shape[2])),('tail16',16),('none',0)]:
 decoder=model.speech_tokenizer.decoder;decoder.reset_streaming_state()
 if count:mx.eval(decoder.streaming_step(prompt.ref_codes[:,:,-count:]))
 chunks=[]
 for i in range(0,codes.shape[2],4):
  a=decoder.streaming_step(codes[:,:,i:i+4]).squeeze(1)[0];mx.eval(a);chunks.append(np.array(a,dtype=np.float32))
 wave=np.concatenate(chunks);sf.write(out/f'{name}.wav',wave,24000,subtype='FLOAT')
 decoder.reset_streaming_state()
 row={'mode':name,'reference_prime_frames':count,'generated_frames':int(codes.shape[2]),'audio_s':len(wave)/24000,'pcm_sha256':hashpcm(wave),'matches_original_pcm':hashpcm(wave)==hashpcm(original),'peak':float(np.abs(wave).max())}
 rows.append(row);print(json.dumps(row),flush=True)
report={'model':MODEL,'revision':REV,'reference_sha256':hashlib.sha256(Path(args.reference).read_bytes()).hexdigest(),'generated_codes_sha256':hashlib.sha256(json.dumps(j['trace']['codes']).encode()).hexdigest(),'target_text':j['result']['text'],'reference_codec_frames':int(prompt.ref_codes.shape[2]),'reference_text_tokens':len(prompt.ref_text_ids),'codec_rows':int(prompt.codec_embeds.shape[1]),'pad_rows':int(prompt.codec_embeds.shape[1])-len(prompt.ref_text_ids),'rows':rows}
(out/'decode.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
