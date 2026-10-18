#!/usr/bin/env python3
"""Validate stored delegation evidence without model/network calls."""
import json
from pathlib import Path
root=Path(__file__).resolve().parent.parent
r=json.loads((root/'results/thinker-delegation-roundtrip.json').read_text());inventory=json.loads((root/'fixtures/delegation-inventory.json').read_text())['items']['A17'];expected=inventory['stock']-inventory['reserved'];timeline=r['timeline']
checks={
 'chatgpt_only':r['voice_auth']==r['thinker_auth']=='chatgpt'and not r['api_key_fallback'],
 'audio_request_complete':not r['physical_microphone_used']and r['fixture_bytes_sent']==r['fixture_bytes_total']>0 and r['peer_connected'],
 'real_model_delegation_event':len(r['delegations'])==1 and any(x['kind']=='delegation_received'for x in timeline),
 'application_owns_routing':r['voice_builtin_turns']==0 and not r['delegations'][0]['forwarded_to_builtin_codex'],
 'independent_thinker_tool':r['thinker_model']=='gpt-6-luna'and len(r['tool_calls'])==1 and r['tool_calls'][0]['tool']=='lookup_inventory'and r['tool_calls'][0]['arguments']['product_code']=='A17'and r['tool_calls'][0]['result']['stock']==inventory['stock']and r['tool_calls'][0]['result']['reserved']==inventory['reserved'],
 'result_computed_by_thinker':str(expected)in r['thinker_result']and str(expected)not in r['synthetic_request']and str(expected)not in r['voice_input_transcript'],
 'same_delegation_reply':r['delegations'][0]['returned_to_same_delegation'],
 'voice_uses_result':str(expected)in r['voice_output_after_result']and r['audio_stats']['nonzero_samples_after_result']>0 and 'meter_error'not in r['audio_stats'],
 'no_runtime_errors':not r['errors'],
}
order=[next(x['at_seconds']for x in timeline if x['kind']==k)for k in ['delegation_received','thinker_started','inventory_tool_called','thinker_completed','result_returned']];checks['causal_order']=order==sorted(order)
print(json.dumps({'ok':all(checks.values()),'checks':checks,'expected_available':expected,'thinker_processing_seconds':round(order[-2]-order[1],3),'wall_seconds':r['wall_seconds'],'scope':'One synthetic request; real ChatGPT voice, separate real low-effort Codex Thinker and read-only application tool; custom sideband adapter required'},indent=2));raise SystemExit(0 if all(checks.values())else 1)
