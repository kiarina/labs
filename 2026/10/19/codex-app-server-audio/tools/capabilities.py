#!/usr/bin/env python3
import asyncio,json
from pathlib import Path
from probe import Client
async def main():
 c=await Client('work/cli/node_modules/.bin/codex').start()
 try:
  r=await c.call('model/list',{'includeHidden':False,'limit':100})
  models=[{'id':x['id'],'inputModalities':x.get('inputModalities')}for x in r.get('result',{}).get('data',[])]
  Path('results/model-modalities.json').write_text(json.dumps({'models':models},indent=2)+'\n');print(models)
 finally:await c.close()
if __name__=='__main__':asyncio.run(main())
