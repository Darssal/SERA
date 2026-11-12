import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {createHash,webcrypto} from 'node:crypto';

const source=readFileSync(new URL('../web/sera-sw.js',import.meta.url),'utf8');
function sharedWorkerStorage() {
  return {state:new Map(),cacheStores:new Map(),liveClients:[],locks:new Map()};
}
function worker({valid=true,manifest=null,files={},shared=sharedWorkerStorage(),locks=true}={}) {
  const {state,cacheStores}=shared;const events=new Map();const shown=[];const opened=[];const requests=[];
  let offline=false,failedPath=null,quotaPath=null;const pausedFetches=new Map();
  const navigator=locks?{locks:{request(name,options,callback){
    assert.equal(options.mode,'exclusive');
    const previous=shared.locks.get(name)||Promise.resolve();
    const pending=previous.catch(()=>{}).then(()=>callback({name,mode:options.mode}));
    shared.locks.set(name,pending.catch(()=>{}));return pending;
  }}}:{};
  const indexedDB={open(){const request={};queueMicrotask(()=>{
    request.result={createObjectStore(){},close(){},transaction(){const tx={};tx.objectStore=()=>({
      get(key){const req={};queueMicrotask(()=>{req.result=state.get(key);req.onsuccess?.();});return req;},
      put(value,key){state.set(key,value);queueMicrotask(()=>tx.oncomplete?.());},
    });return tx;}};request.onupgradeneeded?.();request.onsuccess?.();
  });return request;}};
  const self={registration:{scope:'https://sera.example/',getNotifications:async()=>[],showNotification:async(title,options)=>shown.push({title,options})},
    clients:{claim:async()=>{},matchAll:async()=>shared.liveClients,openWindow:async url=>opened.push(url)},
    addEventListener:(name,callback)=>events.set(name,callback),skipWaiting:async()=>{}};
  vm.runInNewContext(source,{self,indexedDB,navigator,URL,Date,Notification:{permission:'granted'},Response,crypto:webcrypto,
    caches:{open:async name=>{if(!cacheStores.has(name))cacheStores.set(name,new Map());const cache=cacheStores.get(name);return {put:async(request,response)=>{const url=request.url||String(request);if(quotaPath&&url.endsWith(quotaPath))throw new Error('QuotaExceededError');cache.set(url,response);},match:async request=>cache.get(request.url||String(request))?.clone()};},keys:async()=>[...cacheStores.keys()],delete:async name=>cacheStores.delete(name)},
    fetch:async(url)=>{requests.push(String(url.url||url));if(offline)throw new Error('offline');
      const relative=new URL(url.url||String(url)).pathname.slice(1);
      if(pausedFetches.has(relative)){const gate=pausedFetches.get(relative);pausedFetches.delete(relative);gate.enter();await gate.wait;}
      if(manifest&&relative==='sera-cache-manifest.json')return new Response(JSON.stringify(manifest),{status:200});
      if(relative===failedPath)return new Response('unavailable',{status:503});
      if(Object.hasOwn(files,relative))return new Response(files[relative],{status:200});
      return String(url).includes('/api/')?{ok:true,json:async()=>({valid,scope:'user-a'})}:new Response('cached-static-content',{status:200});}});
  async function emit(name,fields){let pending;events.get(name)({...fields,waitUntil:value=>pending=value});await pending;}
  async function scope(value){await emit('message',{data:{type:'set-scope',scope:value},ports:[{postMessage(){}}]});}
  const payload=(override={})=>({id:'task-1',title:'课程准备',body:'开始前提醒',scope:'user-a',generation:7,fireAt:Date.now()-1000,expiresAt:Date.now()+60000,
    quietStart:0,quietEnd:0,route:'/24?taskId=task-1',...override});
  return {state,events,shown,opened,requests,scope,payload,push:value=>emit('push',{data:{json:()=>value}}),emit,setOffline:value=>offline=value,
    cacheStores,setClients:value=>shared.liveClients=value,setManifest:(value,resources)=>{manifest=value;files=resources;},failPath:value=>failedPath=value,quotaPath:value=>quotaPath=value,
    pauseFetch:path=>{let enter,release;const entered=new Promise(resolve=>enter=resolve);const wait=new Promise(resolve=>release=resolve);pausedFetches.set(path,{enter,wait});return {entered,release};},
    prepare:async sourceId=>{let reply;await emit('message',{data:{type:'prepare-shell'},source:sourceId?{id:sourceId}:null,ports:[{postMessage:value=>reply=value}]});return reply;}};
}

function shellFixture(version='a') {
  const names=['index.html','flutter_bootstrap.js','main.dart.js','sera-platform.js','assets/FontManifest.json','assets/AssetManifest.bin','canvaskit/canvaskit.js','canvaskit/canvaskit.wasm','assets/assets/icons/icon-refresh.svg'];
  const files=Object.fromEntries(names.map(name=>[name,`${version}:${name}`]));
  return {manifest:{schemaVersion:1,version:version.repeat(64),resources:names.map(path=>({path,bytes:Buffer.byteLength(files[path]),sha256:createHash('sha256').update(files[path]).digest('hex')}))},files};
}
function upgradeFixture(first, changes) {
  const files={...first.files,...changes};
  const resources=Object.entries(files).map(([path,value])=>({path,bytes:Buffer.byteLength(value),sha256:createHash('sha256').update(value).digest('hex')}));
  return {files,manifest:{schemaVersion:1,version:'b'.repeat(64),resources}};
}

if(process.env.SERA_CACHE_BASELINE && process.env.SERA_CACHE_CANDIDATE) test('built release upgrade audit verifies all cached resources and reports actual artifact bytes',async()=>{
  function release(directory){const manifest=JSON.parse(readFileSync(join(directory,'sera-cache-manifest.json'),'utf8'));return {manifest,files:Object.fromEntries(manifest.resources.map(item=>[item.path,readFileSync(join(directory,item.path))]))};}
  const first=release(process.env.SERA_CACHE_BASELINE),next=release(process.env.SERA_CACHE_CANDIDATE);
  const timings=[];let result;
  for(let sample=0;sample<5;sample++){
    global.gc?.();
    const w=worker(first);let at=performance.now();await w.prepare('old');const cold=performance.now()-at;
    w.setClients([{id:'old'},{id:'new'}]);w.requests.length=0;w.setManifest(next.manifest,next.files);
    at=performance.now();result=await w.prepare('new');const upgrade=performance.now()-at;
    assert.equal(result.ready,true);assert.equal(result.usingCached,undefined);
    const oldByPath=new Map(first.manifest.resources.map(item=>[item.path,item]));
    const unchanged=next.manifest.resources.filter(item=>oldByPath.get(item.path)?.sha256===item.sha256&&oldByPath.get(item.path)?.bytes===item.bytes);
    assert.equal(result.reusedResources,unchanged.length);
    for(const item of unchanged)assert.equal(w.requests.includes('https://sera.example/'+item.path),false,item.path);
    assert.equal(result.reusedBytes+result.downloadedBytes,next.manifest.resources.reduce((sum,item)=>sum+item.bytes,0));
    timings.push({coldShellMs:Math.round(cold),upgradeShellMs:Math.round(upgrade),heapUsedBytes:process.memoryUsage().heapUsed,rssBytes:process.memoryUsage().rss});
  }
  const report={environment:'Node VM with in-memory CacheStorage/IndexedDB; real release bytes. Times and memory describe this test harness, not browser startup or Android profiling.',baselineVersion:first.manifest.version,candidateVersion:next.manifest.version,baselineBytes:first.manifest.resources.reduce((sum,item)=>sum+item.bytes,0),candidateBytes:result.reusedBytes+result.downloadedBytes,reusedResources:result.reusedResources,reusedBytes:result.reusedBytes,downloadedResources:result.downloadedResources,downloadedBytes:result.downloadedBytes,samples:timings};
  if(process.env.SERA_CACHE_REPORT)writeFileSync(process.env.SERA_CACHE_REPORT,JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report));
});

test('upgrade reuses hash-verified unchanged fonts and runtime without network requests',async()=>{
  const first=upgradeFixture(shellFixture('a'),{'assets/assets/fonts/chinese.ttf':'任意姓名与中文字符:𠮷','main.dart.js':'old-main'});
  first.manifest.version='a'.repeat(64);
  const w=worker(first);await w.prepare('old-tab');
  const next=upgradeFixture(first,{'main.dart.js':'new-main'});
  w.setClients([{id:'old-tab'},{id:'new-tab'}]);w.requests.length=0;w.setManifest(next.manifest,next.files);
  const result=await w.prepare('new-tab');
  assert.equal(result.ready,true);assert.equal(result.downloadedResources,1);
  assert.equal(result.reusedResources,next.manifest.resources.length-1);
  assert.equal(result.downloadedBytes,Buffer.byteLength('new-main'));
  assert.deepEqual(w.requests.map(url=>new URL(url).pathname),['/sera-cache-manifest.json','/main.dart.js']);
  assert.equal(await (await w.cacheStores.get(result.name).get('https://sera.example/assets/assets/fonts/chinese.ttf').clone()).text(),first.files['assets/assets/fonts/chinese.ttf']);
  const oldName=w.state.get('client-shell:old-tab');assert.notEqual(oldName,result.name);
  let response;w.events.get('fetch')({clientId:'old-tab',request:new Request('https://sera.example/main.dart.js'),respondWith:value=>response=value});
  assert.equal(await (await response).text(),'old-main');
});

test('cached bytes are verified against the new manifest before reuse',async()=>{
  const first=shellFixture('a');const w=worker(first);await w.prepare();
  const old=w.state.get('active-shell').name;
  w.cacheStores.get(old).set('https://sera.example/canvaskit/canvaskit.wasm',new Response('corrupted-cache'));
  const next=upgradeFixture(first,{'main.dart.js':'changed-main'});
  w.requests.length=0;w.setManifest(next.manifest,next.files);
  const result=await w.prepare();assert.equal(result.ready,true);assert.equal(result.downloadedResources,2);
  assert.ok(w.requests.some(url=>url.endsWith('canvaskit.wasm')));
  assert.equal(await w.cacheStores.get(result.name).get('https://sera.example/canvaskit/canvaskit.wasm').clone().text(),first.files['canvaskit/canvaskit.wasm']);
});

test('partial upgrade failure keeps old client bindings and removes the candidate after all writes',async()=>{
  for(const failure of ['offline','hash','quota']) {
    const first=shellFixture('a');const w=worker(first);w.setClients([{id:'old'}]);await w.prepare('old');
    const old=w.state.get('active-shell').name;const next=upgradeFixture(first,{'main.dart.js':'changed-main'});
    w.setManifest(next.manifest,next.files);
    if(failure==='offline')w.failPath('main.dart.js');
    if(failure==='hash')next.files['main.dart.js']='wrong-file';
    if(failure==='quota')w.quotaPath('canvaskit/canvaskit.wasm');
    const result=await w.prepare('new');
    assert.equal(result.usingCached,true,failure);assert.equal(w.state.get('active-shell').name,old,failure);
    assert.equal(w.state.get('client-shell:old'),old,failure);
    assert.equal([...w.cacheStores.keys()].some(name=>name.startsWith('sera-runtime-v5-'+next.manifest.version+'-')),false,failure);
  }
});
test('first install precaches full local Flutter runtime before first controlled request and survives offline reload',async()=>{
  const fixture=shellFixture();const w=worker(fixture);const prepared=await w.prepare();
  assert.equal(prepared.ready,true);assert.equal(w.state.get('active-shell').version,fixture.manifest.version);
  const cache=w.cacheStores.get(w.state.get('active-shell').name);
  assert.equal(cache.size,fixture.manifest.resources.length);
  w.setOffline(true);
  for(const path of ['flutter_bootstrap.js','main.dart.js','canvaskit/canvaskit.wasm','assets/FontManifest.json','assets/assets/icons/icon-refresh.svg']) {
    let response;const request=new Request('https://sera.example/'+path);
    w.events.get('fetch')({request,respondWith:value=>response=value});
    assert.equal(await (await response).text(),fixture.files[path]);
  }
  assert.equal((await w.prepare()).usingCached,true);
});
test('incomplete or hash-mismatched update never replaces or deletes the complete previous shell',async()=>{
  for(const failure of ['network','hash','quota']) {
    const first=shellFixture('a'),next=shellFixture('b');const w=worker(first);await w.prepare();const old=w.state.get('active-shell').name;
    w.setManifest(next.manifest,next.files);
    if(failure==='network')w.failPath('main.dart.js');
    if(failure==='hash')next.files['main.dart.js']='corrupted-deployment';
    if(failure==='quota')w.quotaPath('main.dart.js');
    const reply=await w.prepare();
    assert.equal(reply.usingCached,true,failure);assert.equal(w.state.get('active-shell').name,old,failure);
    assert.ok(w.cacheStores.has(old),failure);assert.ok(w.state.get('last-shell-error'),failure);
    assert.equal([...w.cacheStores.keys()].some(name=>name.startsWith('sera-runtime-v5-'+next.manifest.version+'-')),false,failure);
  }
});
test('complete new shell commits atomically and old live-client cache remains available until activation cleanup',async()=>{
  const first=shellFixture('a'),next=shellFixture('b');const w=worker(first);w.setClients([{id:'tab-a'}]);await w.prepare('tab-a');const old=w.state.get('active-shell').name;
  w.setManifest(next.manifest,next.files);w.setClients([{id:'tab-a'},{id:'tab-b'}]);await w.prepare('tab-b');assert.equal(w.state.get('active-shell').version,next.manifest.version);
  assert.ok(w.cacheStores.has(old));w.setClients([{id:'tab-b'}]);await w.emit('activate',{});assert.equal(w.cacheStores.has(old),false);
  assert.equal(w.cacheStores.get(w.state.get('active-shell').name).size,next.manifest.resources.length);
});
test('cold-start cache error reports failure and never advertises a partial shell as ready',async()=>{
  const fixture=shellFixture();const w=worker(fixture);w.quotaPath('main.dart.js');const reply=await w.prepare();
  assert.equal(reply.ok,false);assert.equal(w.state.has('active-shell'),false);assert.equal(w.cacheStores.size,0);
});

test('two worker instances serialize preparation, binding and activation cleanup with the origin lock',async()=>{
  const shared=sharedWorkerStorage(),first=shellFixture('a'),next=shellFixture('b');
  const old=worker({...first,shared});old.setClients([{id:'old'},{id:'new-a'},{id:'new-b'}]);
  const original=await old.prepare('old');
  const a=worker({...next,shared}),b=worker({...next,shared});
  const gate=a.pauseFetch('main.dart.js');const preparing=a.prepare('new-a');await gate.entered;
  const candidate=[...shared.cacheStores.keys()].find(name=>name!==original.name);
  assert.ok(candidate.startsWith('sera-runtime-v5-'));
  let activated=false;
  const activation=b.emit('activate',{}).then(()=>activated=true);
  const following=b.prepare('new-b');
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(activated,false,'cleanup must wait for the other instance writer');
  assert.equal(b.requests.length,0,'the second prepare must not run before the first binding');
  assert.ok(shared.cacheStores.has(candidate));
  gate.release();
  const [prepared,second]=await Promise.all([preparing,following,activation]);
  assert.equal(prepared.name,candidate);assert.equal(second.name,candidate);
  assert.equal(shared.state.get('client-shell:new-a'),candidate);
  assert.equal(shared.state.get('client-shell:new-b'),candidate);
  assert.equal(shared.state.get('client-shell:old'),original.name);
  assert.equal(shared.cacheStores.get(candidate).size,next.manifest.resources.length);
  let response;b.events.get('fetch')({clientId:'old',request:new Request('https://sera.example/main.dart.js'),respondWith:value=>response=value});
  assert.equal(await (await response).text(),first.files['main.dart.js']);
});

test('a failed locked worker settles every writer before a second instance commits its own candidate',async()=>{
  const shared=sharedWorkerStorage(),first=shellFixture('a'),next=shellFixture('b');
  const old=worker({...first,shared});old.setClients([{id:'old'},{id:'failed'},{id:'success'}]);
  const original=await old.prepare('old');
  const a=worker({...next,shared}),b=worker({...next,shared});
  a.failPath('main.dart.js');
  const failing=a.pauseFetch('main.dart.js'),delayed=a.pauseFetch('sera-platform.js');
  let finished=false;
  const preparing=a.prepare('failed').then(value=>{finished=true;return value;});
  await Promise.all([failing.entered,delayed.entered]);
  const candidate=[...shared.cacheStores.keys()].find(name=>name!==original.name);
  const following=b.prepare('success');failing.release();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(finished,false);assert.equal(b.requests.length,0);
  assert.ok(shared.cacheStores.has(candidate),'a still-running writer owns its candidate until settled');
  delayed.release();
  const [failed,success]=await Promise.all([preparing,following]);
  assert.equal(failed.usingCached,true);assert.notEqual(success.name,candidate);
  assert.equal(shared.cacheStores.has(candidate),false);
  assert.equal(shared.state.get('active-shell').name,success.name);
  assert.equal(shared.state.get('client-shell:failed'),original.name);
  assert.equal(shared.cacheStores.get(success.name).size,next.manifest.resources.length);
});

test('without Web Locks a late failure only deletes its unique candidate and preserves another worker commit',async()=>{
  const shared=sharedWorkerStorage(),first=shellFixture('a'),next=shellFixture('b');
  const old=worker({...first,shared,locks:false});old.setClients([{id:'old'},{id:'failed'},{id:'success'}]);
  const original=await old.prepare('old');
  const a=worker({...next,shared,locks:false}),b=worker({...next,shared,locks:false});
  a.failPath('main.dart.js');const gate=a.pauseFetch('main.dart.js');
  const preparing=a.prepare('failed');await gate.entered;
  const failedCandidate=[...shared.cacheStores.keys()].find(name=>name!==original.name);
  const success=await b.prepare('success');
  assert.notEqual(success.name,failedCandidate);assert.equal(shared.state.get('active-shell').name,success.name);
  await b.emit('activate',{});
  assert.ok(shared.cacheStores.has(failedCandidate),'uncoordinated cleanup must retain another writer candidate');
  gate.release();const failed=await preparing;
  assert.equal(failed.usingCached,true);assert.equal(shared.cacheStores.has(failedCandidate),false);
  assert.ok(shared.cacheStores.has(original.name));assert.equal(shared.state.get('active-shell').name,success.name);
  b.setOffline(true);
  let response;b.events.get('fetch')({clientId:'success',request:new Request('https://sera.example/main.dart.js'),respondWith:value=>response=value});
  assert.equal(await (await response).text(),next.files['main.dart.js']);
  old.setClients([]);await b.emit('activate',{});
  assert.ok(shared.cacheStores.has(original.name),'fallback conservatively retains complete old caches');
});

test('v5 candidate is outside legacy cleanup namespace and old v4 client bindings remain readable',async()=>{
  const shared=sharedWorkerStorage(),first=shellFixture('a'),next=shellFixture('b');
  const legacy='sera-shell-v4-'+first.manifest.version;
  shared.cacheStores.set(legacy,new Map(Object.entries(first.files).map(([path,value])=>['https://sera.example/'+path,new Response(value)])));
  shared.state.set('active-shell',{name:legacy,version:first.manifest.version});shared.state.set('client-shell:old',legacy);
  const w=worker({...next,shared});w.setClients([{id:'old'},{id:'new'}]);
  const gate=w.pauseFetch('main.dart.js');const preparing=w.prepare('new');await gate.entered;
  const candidate=[...shared.cacheStores.keys()].find(name=>name!==legacy);
  // Reproduce the previous worker's cleanup selector while v5 is installing.
  for(const name of [...shared.cacheStores.keys()])if(name.startsWith('sera-shell-')&&name!==legacy)shared.cacheStores.delete(name);
  assert.ok(shared.cacheStores.has(candidate));gate.release();const ready=await preparing;
  assert.equal(ready.name,candidate);assert.ok(shared.cacheStores.has(legacy));
  let response;w.events.get('fetch')({clientId:'old',request:new Request('https://sera.example/main.dart.js'),respondWith:value=>response=value});
  assert.equal(await (await response).text(),first.files['main.dart.js']);
});

test('same-version legacy shell migrates into the protected namespace without redownloading files',async()=>{
  const shared=sharedWorkerStorage(),fixture=shellFixture('a');
  const legacy='sera-shell-v4-'+fixture.manifest.version;
  shared.cacheStores.set(legacy,new Map(Object.entries(fixture.files).map(([path,value])=>['https://sera.example/'+path,new Response(value)])));
  shared.state.set('active-shell',{name:legacy,version:fixture.manifest.version});
  const w=worker({...fixture,shared});const ready=await w.prepare('new');
  assert.ok(ready.name.startsWith('sera-runtime-v5-'));
  assert.equal(ready.reusedResources,fixture.manifest.resources.length);
  assert.equal(ready.downloadedResources,0);
  assert.deepEqual(w.requests,['https://sera.example/sera-cache-manifest.json']);
  assert.equal(shared.state.get('active-shell').name,ready.name);
});

test('get-scope RPC reads persisted identity without switching the account',async()=>{
  const w=worker();let reply;
  const getScope=async()=>{await w.emit('message',{data:{type:'get-scope'},ports:[{postMessage:value=>reply=value}]});return reply.activeScope;};
  assert.equal(await getScope(),'signed-out');
  await w.scope('user-a');assert.equal(await getScope(),'user-a');
  await w.scope('user-b');assert.equal(await getScope(),'user-b');
  assert.equal(w.state.get('active-scope'),'user-b');
});
test('push validates latest authenticated state and preserves follow-up route',async()=>{
  const w=worker();await w.scope('user-a');await w.push(w.payload());
  assert.equal(w.shown.length,1);assert.equal(w.shown[0].options.data.route,'/24?taskId=task-1');
  assert.match(w.requests[0],/\/api\/v1\/push\/validate\?id=task-1&generation=7$/);
});
test('signed out and another account never show a previous user payload',async()=>{
  const w=worker();await w.scope('signed-out');await w.push(w.payload());await w.scope('user-b');await w.push(w.payload());
  assert.equal(w.shown.length,0);assert.equal(w.requests.length,0);
});
test('expired, early and quiet-hours pushes do not display',async()=>{
  const w=worker();await w.scope('user-a');
  await w.push(w.payload({expiresAt:Date.now()-1}));await w.push(w.payload({fireAt:Date.now()+60000}));
  const now=new Date();const minute=now.getHours()*60+now.getMinutes();
  await w.push(w.payload({quietStart:(minute+1439)%1440,quietEnd:(minute+1)%1440}));
  assert.equal(w.shown.length,0);
});
test('push quiet hours follow account IANA timezone',async()=>{
  const w=worker();await w.scope('user-a');
  const parts=new Intl.DateTimeFormat('en-GB',{timeZone:'America/Los_Angeles',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date());
  const minute=Number(parts.find(p=>p.type==='hour').value)*60+Number(parts.find(p=>p.type==='minute').value);
  await w.push(w.payload({timeZone:'America/Los_Angeles',quietStart:(minute+1439)%1440,quietEnd:(minute+1)%1440}));
  assert.equal(w.shown.length,0);assert.equal(w.state.get('last-push').status,'quiet-hours');
});
test('malformed account timezone is rejected instead of using the device clock',async()=>{
  const w=worker();await w.scope('user-a');await w.push(w.payload({timeZone:'Invalid/Zone',quietStart:1,quietEnd:2}));
  assert.equal(w.shown.length,0);assert.equal(w.state.get('last-push').status,'invalid-time-zone');
});
test('server invalidation suppresses in-flight obsolete notifications',async()=>{
  const w=worker({valid:false});await w.scope('user-a');await w.push(w.payload());
  assert.equal(w.shown.length,0);assert.equal(w.state.get('last-push').status,'invalidated');
});
test('payload cannot bypass authenticated server validation',async()=>{
  const w=worker({valid:false});await w.scope('user-a');await w.push(w.payload({validate:false}));
  assert.equal(w.requests.length,1);assert.equal(w.shown.length,0);
});
test('same generation is idempotent and lower generations cannot replace newer ones',async()=>{
  const w=worker();await w.scope('user-a');await w.push(w.payload({generation:8}));await w.push(w.payload({generation:8}));await w.push(w.payload({generation:7}));
  assert.equal(w.shown.length,1);
});
test('a newer workspace snapshot cancels already queued old generations',async()=>{
  const w=worker();await w.scope('user-a');await w.emit('message',{data:{type:'reminder-snapshot',scope:'user-a',snapshot:{revision:9}},ports:[{postMessage(){}}]});
  await w.push(w.payload({generation:8}));assert.equal(w.shown.length,0);
});
test('registered generation-zero test push still validates after a workspace snapshot',async()=>{
  const w=worker();await w.scope('user-a');await w.emit('message',{data:{type:'reminder-snapshot',scope:'user-a',snapshot:{revision:9}},ports:[{postMessage(){}}]});
  await w.push(w.payload({id:'server-test',kind:'test',generation:0}));
  assert.equal(w.shown.length,1);assert.match(w.requests[0],/generation=0$/);
  const blocked=worker({valid:false});await blocked.scope('user-a');await blocked.push(blocked.payload({kind:'test',generation:0}));assert.equal(blocked.shown.length,0);
});
test('unsafe routes are replaced with reminders page',async()=>{
  const w=worker();await w.scope('user-a');await w.push(w.payload({route:'https://evil.example/'}));
  assert.equal(w.shown[0].options.data.route,'/27');
});
test('notification click after sign-out does not open the previous task',async()=>{
  const w=worker();await w.scope('user-b');let closed=false;
  await w.emit('notificationclick',{notification:{close(){closed=true;},data:{sera:true,scope:'user-a',route:'/18?taskId=private'}}});
  assert.equal(closed,true);assert.equal(w.opened.length,0);
});
test('worker never caches API, health, auth headers or writes',()=>{
  const w=worker();let intercepted=0;
  for(const request of [{url:'https://sera.example/api/v1/workspace',method:'GET'},
    {url:'https://sera.example/health',method:'GET'}, {url:'https://sera.example/main.dart.js',method:'POST'},
    {url:'https://sera.example/private.js',method:'GET',auth:true}]) {
    w.events.get('fetch')({request:{...request,headers:{has:()=>!!request.auth}},respondWith(){intercepted++;}});
  }
  assert.equal(intercepted,0);
});
test('Flutter binary asset manifest and icon fonts remain available offline after first visit',async()=>{
  const w=worker();
  for(const path of ['assets/AssetManifest.bin','assets/fonts/MaterialIcons-Regular.otf']) {
    const request=new Request(`https://sera.example/${path}`);let response;
    w.setOffline(false);w.events.get('fetch')({request,respondWith:value=>response=value});
    assert.equal(await (await response).text(),'cached-static-content');
    w.setOffline(true);w.events.get('fetch')({request,respondWith:value=>response=value});
    assert.equal(await (await response).text(),'cached-static-content');
  }
});

const pcmSource=readFileSync(new URL('../web/sera-pcm-worklet.js',import.meta.url),'utf8');
function pcmProcessor(rate) {
  let Processor;const output=[];
  class Base {constructor(){this.port={onmessage:null,postMessage:value=>output.push(value)};}}
  vm.runInNewContext(pcmSource,{AudioWorkletProcessor:Base,sampleRate:rate,registerProcessor:(_,value)=>Processor=value});
  return {processor:new Processor(),output};
}
for(const rate of [16000,44100,48000])test(`AudioWorklet ${rate} Hz produces real 16 kHz mono s16le frames`,()=>{
  const {processor,output}=pcmProcessor(rate);const samples=Math.round(rate/10);
  const input=Float32Array.from({length:samples},(_,i)=>0.5*Math.sin(2*Math.PI*1000*i/rate));
  processor.process([[input]],[[]]);
  assert.equal(output.length,1);const data=Buffer.from(output[0].bytes);assert.equal(data.length,3200);
  let sum=0;for(let i=0;i<data.length;i+=2)sum+=data.readInt16LE(i)**2;
  assert.ok(Math.sqrt(sum/1600)>8000,'PCM must contain captured waveform, not fabricated silence');
});
test('AudioWorklet stop flushes valid partial PCM and cancellation discards it',()=>{
  for(const cancel of [false,true]) {
    const {processor,output}=pcmProcessor(48000);processor.process([[new Float32Array(480).fill(0.2)]],[[]]);
    processor.port.onmessage({data:{type:'stop',cancel}});
    assert.equal(output.filter(e=>e.type==='pcm').length,cancel?0:1);
    assert.equal(output.at(-1).type,'stopped');
  }
});
