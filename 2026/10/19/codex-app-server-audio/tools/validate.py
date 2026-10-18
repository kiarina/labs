#!/usr/bin/env python3
import json
from pathlib import Path
root=Path(__file__).resolve().parent.parent
load=lambda p:json.loads((root/'results'/p).read_text())
checks=[]
for version in ['installed-0.159.3','stable-0.163.0']:
 disabled=load(f'{version}-experimental-false.json');assert 'experimentalApi'in disabled['start']['error']['message']
 enabled=load(f'{version}-experimental-true.json');assert enabled['account_type']=='chatgpt';assert enabled['start']['result']=={}
 assert any(x['method']=='thread/realtime/error'and x['params']['message']=='realtime conversation requires API key auth'for x in enabled['events'])
checks.append('both versions enforce experimental opt-in and API-key-free WebSocket rejection')
for mode in ['conversational','transcription']:
 r=load(f'mock-{mode}.json');assert r['forwarded_bytes_unchanged'];assert not r['normal_turn_started']
 assert [x for x in r['events']if x['method']=='thread/realtime/transcript/done'and x['params']['role']=='user'][0]['params']['text']=='fixture transcript'
 assert r['audio_config']['input']['format']=={'type':'audio/pcm','rate':24000}
 assert r['audio_config']['input']['transcription']['model']=='gpt-4o-mini-transcribe'
 assert r['upstream_types']==['session.update','input_audio_buffer.append']
checks.append('mock audio bytes are forwarded unchanged despite mismatched metadata; input/output notifications route')
r=load('mock-normal-turn.json');assert r['turn_completed']and not r['input_audio_present']and r['omission_marker_present']
assert all(x['inputModalities']==['text','image']for x in load('model-modalities.json')['models'])
checks.append('listed normal models omit audio; gpt-6-luna request replaces audio with omission marker')
r=load('live-conversational.json');assert r['started']and r['sent_bytes']==369984 and not r['normal_turn_started']
assert any(x['method']=='thread/realtime/transcript/done'and x['params']['role']=='user'and x['params']['text']=='Did you bring the map? Yes, it is right here.'for x in r['events'])
checks.append('live mini conversational session produces the fixture transcript')
for file,message in [('live-transcription.json','Passing a transcription session update to a realtime session is not allowed.'),('live-transcription-intent.json','You must not provide a model parameter for transcription sessions.')]:
 assert any(x['method']=='thread/realtime/error'and x['params']['message']==message for x in load(file)['events'])
checks.append('transcription configuration alone fails; intent workaround also fails with model query')
for version in ['v1','v2','v3']:
 r=load(f'live-chatgpt-webrtc-{version}.json');assert not r['answer_received']and not r['peer_connected']and not r['api_key_fallback'];assert any(x['method']=='thread/realtime/error'for x in r['events'])
checks.append('three explicit WebRTC configurations remain unconnected, not asserted universally unavailable')
r=load('webrtc-direct-chatgpt-audio.json')
assert r['auth_type']=='chatgpt'and not r['api_key_fallback']and not r['proxy_used']and not r['model_override']
assert r['peer_connected']and r['answer_received']and r['data_channel_open']
assert r['fixture_bytes_sent']==r['fixture_bytes_total']==321984 and not r['normal_turn_started']
assert r['received_audio']['audio_frames']>0 and r['received_audio']['audio_samples']>0
assert any(x['method']=='thread/realtime/transcript/done'and x['params'].get('role')=='user'and x['params']['text'].rstrip('.')=='Did you bring the map? Yes, it is right here'for x in r['events'])
assert any(x['method']=='thread/realtime/transcript/done'and x['params'].get('role')=='assistant'and x['params']['text'].strip()=='OK.'for x in r['events'])
checks.append('ChatGPT-only direct v3 WebRTC on wham connects, transcribes fixture and receives response audio')
r=load('webrtc-followup-wham-route.json');assert r['peer_connected']and r['requests'][0]['upstream_status']==201
for name in ['omit-model','empty-session','sdp-only','public-live-model','no-legacy-query']:
 r=load(f'webrtc-followup-{name}.json');assert not r['peer_connected']and r['requests'][0]['upstream_status']==400
checks.append('route-only relay comparison succeeds; model/schema/query edits on codex route do not')
r=load('transcript-only-text-modality.json');assert not r['peer_connected']
assert any(x['method']=='thread/realtime/error'and x['params']['message']=='text realtime output modality requires realtime v2'for x in r['events'])
for mode in ['spoken-control','listen-only']:
 r=load(f'transcript-only-{mode}.json');assert r['auth_type']=='chatgpt'and not r['api_key_fallback']and not r['proxy_used']and r['peer_connected']
 assert r['instrument_valid']and not r['audio_stats']['meter_errors']and r['audio_stats']['frames']>0
 assert r['fixture_bytes_sent']==r['fixture_bytes_total']and not r['normal_turn_started']
 texts={role:''.join(x['params']['delta']for x in r['events']if x['method']=='thread/realtime/transcript/delta'and x['params']['role']==role)for role in ['user','assistant']}
 assert texts['user'].count('Did you bring the map')==r['fixture_repetitions']
 if mode=='listen-only':
  assert not texts['assistant']and r['audio_stats']['nonzero_samples']==r['audio_stats']['peak_pcm16']==0
  assert r['fixture_repetitions']==2
 else:
  assert 'OK'in texts['assistant']and r['audio_stats']['frames_rms_ge_100']>0
for mode in ['spoken-control','listen-only']:assert load(f'transcript-only-initial-instrument-{mode}.json')['instrument_valid']is False
checks.append('listen-only prompt yields two input transcripts and zero nonzero PCM samples; spoken control validates meter; v3 text rejected')
assert load('real-microphone-validation.json')['ok']is True
checks.append('five-minute real microphone metrics pass the separate continuity and silence validator')
for p in (root/'results').glob('*.json'):
 s=p.read_text();assert '/Users/'not in s and 'sk-'not in s and 'Bearer 'not in s,p
print(json.dumps({'ok':True,'checks':checks,'live_runs_repeated':False},indent=2))
