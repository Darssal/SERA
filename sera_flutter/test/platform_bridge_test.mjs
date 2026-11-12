import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

const source=readFileSync(new URL('../web/sera-platform.js',import.meta.url),'utf8');
function audioBridge({pendingPermission=false,deniedPermission=false}={}) {
  let permission;let stops=0;let closes=0;let node;
  const stream={getTracks:()=>[{stop(){stops++;}}]};
  const context={isSecureContext:true,URL,Uint8Array,setTimeout,clearTimeout,
    document:{baseURI:'https://sera.example/'},window:{addEventListener(){}},
    navigator:{mediaDevices:{getUserMedia:()=>deniedPermission?Promise.reject(Object.assign(new Error('Permission denied'),{name:'NotAllowedError'})):pendingPermission?new Promise(resolve=>permission=resolve):Promise.resolve(stream)}},
    AudioContext:class {constructor(){this.state='suspended';this.audioWorklet={addModule:async()=>{}};}
      createMediaStreamSource(){return {connect(){},disconnect(){}};}
      createGain(){return {gain:{value:1},connect(){},disconnect(){}};}
      async resume(){this.state='running';}async close(){this.state='closed';closes++;}},
    AudioWorkletNode:class {constructor(){node=this;this.port={onmessage:null,postMessage:()=>this.port.onmessage?.({data:{type:'stopped'}})};}
      connect(){}disconnect(){}},
  };
  vm.runInNewContext(source,context);
  return {api:context.seraPlatform,grant:()=>permission(stream),stops:()=>stops,closes:()=>closes,
    frame:bytes=>node.port.onmessage({data:{type:'pcm',bytes}})};
}
test('cancel while microphone permission is pending releases a later granted track',async()=>{
  const b=audioBridge({pendingPermission:true});let ended=0;
  const opening=b.api.startPcm(()=>{},()=>{},()=>ended++);
  await assert.rejects(b.api.startPcm(()=>{},()=>{},()=>{}),e=>e.code==='recording_busy');
  await b.api.stopPcm(true);b.grant();
  await assert.rejects(opening,e=>e.code==='cancelled');
  assert.equal(b.stops(),1);assert.equal(ended,1);
});
test('stream passes PCM bytes, stops microphone and can start again',async()=>{
  const b=audioBridge();const frames=[];let ended=0;
  const format=await b.api.startPcm(bytes=>frames.push(bytes),()=>{},()=>ended++);
  assert.equal(format.sampleRate,16000);assert.equal(format.encoding,'pcm_s16le');
  b.frame(Uint8Array.of(1,2,3,4).buffer);assert.deepEqual([...frames[0]],[1,2,3,4]);
  await b.api.stopPcm(false);assert.equal(b.stops(),1);assert.equal(b.closes(),1);assert.equal(ended,1);
  await b.api.startPcm(()=>{},()=>{},()=>ended++);await b.api.stopPcm(true);
  assert.equal(b.stops(),2);assert.equal(b.closes(),2);assert.equal(ended,2);
});
test('notification subscription cannot be enabled before account scope is bound',async()=>{
  const b=audioBridge();await assert.rejects(b.api.subscribePush('public-key'),e=>e.code==='not_authenticated');
});
test('denied microphone rejects with its cause before any normal stream-end callback',async()=>{
  const b=audioBridge({deniedPermission:true});let ended=0,frames=0;
  await assert.rejects(b.api.startPcm(()=>frames++,()=>{},()=>ended++),e=>e.code==='microphone_denied'&&e.message==='麦克风权限未开启，请在浏览器网站设置中允许，或改用文字输入。');
  assert.equal(ended,0,'Dart must receive the rejected bridge Promise before stream done');
  assert.equal(frames,0);assert.equal(b.stops(),0);assert.equal(b.closes(),0);
  await b.api.stopPcm(true);assert.equal(ended,0);
});

function pushBridge(previousScope,{unsubscribeSuccess=true,existingSubscription=true,pendingSubscribe=false}={}) {
  let owner=previousScope,unsubscribed=0,subscribed=0,shown=0;let existing,grant;
  const makeSubscription=()=>({toJSON:()=>({endpoint:'https://push.example/endpoint'}),unsubscribe:async()=>{unsubscribed++;if(unsubscribeSuccess)existing=null;return unsubscribeSuccess;}});
  if(existingSubscription)existing=makeSubscription();
  const reg={active:{postMessage(message,ports){
    if(message.type==='get-scope'){ports[0].postMessage({ok:true,activeScope:owner});return;}
    assert.equal(message.type,'set-scope');const previous=owner;owner=message.scope;ports[0].postMessage({ok:true,previousScope:previous});}},
    showNotification:async()=>{shown++;},getNotifications:async()=>[],pushManager:{getSubscription:async()=>existing,subscribe:async()=>{subscribed++;return pendingSubscribe?new Promise(resolve=>grant=()=>{existing=makeSubscription();resolve(existing);}):(existing=makeSubscription());}}};
  class Port {postMessage(data){queueMicrotask(()=>this.other.onmessage?.({data}));}close(){}}
  class Channel {constructor(){this.port1=new Port();this.port2=new Port();this.port1.other=this.port2;this.port2.other=this.port1;}}
  const page=()=>{const context={isSecureContext:true,URL,Uint8Array,setTimeout,clearTimeout,MessageChannel:Channel,PushManager:class{},atob,Notification:{permission:'granted'},
    document:{baseURI:'https://sera.example/'},window:{addEventListener(){}},navigator:{serviceWorker:{register:async()=>reg}}};
  vm.runInNewContext(source,context);
  return context.seraPlatform;};
  return {api:page(),newPage:page,unsubscribed:()=>unsubscribed,subscribed:()=>subscribed,shown:()=>shown,owner:()=>owner,grant:()=>grant()};
}
test('fresh page preserves a subscription when persisted account scope is unchanged',async()=>{
  const b=pushBridge('user-a');await b.api.setAccountScope('user-a');
  assert.equal(b.unsubscribed(),0);assert.ok(await b.api.subscription());
});
test('fresh page retires previous account subscription on different login or logout',async()=>{
  for(const next of ['user-b','signed-out']) {
    const b=pushBridge('user-a');await b.api.setAccountScope(next);
    assert.equal(b.unsubscribed(),1);assert.equal(b.owner(),next);assert.equal(await b.api.subscription(),null);
  }
});
test('failed retirement is an actionable error and never reports old account as subscribed',async()=>{
  const b=pushBridge('user-a',{unsubscribeSuccess:false});
  await assert.rejects(b.api.setAccountScope('user-b'),e=>e.code==='unsubscribe_failed');
  await assert.rejects(b.api.subscription(),e=>e.code==='scope_unavailable');
});
test('account change waits for pending subscribe then retires its stale result',async()=>{
  const b=pushBridge('user-a',{existingSubscription:false,pendingSubscribe:true});await b.api.setAccountScope('user-a');
  const publicKey=Buffer.from([4,...new Uint8Array(64)]).toString('base64url');
  const opening=b.api.subscribePush(publicKey);
  await new Promise(resolve=>setImmediate(resolve));
  const rejected=assert.rejects(opening,e=>e.code==='stale_account');
  const switching=b.api.setAccountScope('user-b');
  b.grant();await rejected;await switching;
  assert.equal(b.owner(),'user-b');assert.equal(b.unsubscribed(),1);assert.equal(await b.api.subscription(),null);
});
test('stale page cannot display notifications or inspect, change or retire another tab account subscription',async()=>{
  const publicKey=Buffer.from([4,...new Uint8Array(64)]).toString('base64url');
  for(const operation of ['notification','subscribe','unsubscribe','subscription']) {
    const b=pushBridge('user-a');await b.api.setAccountScope('user-a');
    const accountB=b.newPage();await accountB.setAccountScope('user-b');
    await accountB.subscribePush(publicKey);
    const baseline={unsubscribed:b.unsubscribed(),subscribed:b.subscribed()};
    const staleOperation={
      notification:()=>b.api.showNotification('A reminder','Synthetic QA','/27','a'),
      subscribe:()=>b.api.subscribePush(publicKey),
      unsubscribe:()=>b.api.unsubscribePush(),
      subscription:()=>b.api.subscription(),
    }[operation];
    await assert.rejects(staleOperation(),e=>e.code==='stale_account',operation);
    assert.equal(b.shown(),0,operation);
    assert.equal(b.unsubscribed(),baseline.unsubscribed,operation);
    assert.equal(b.subscribed(),baseline.subscribed,operation);
    assert.equal(b.owner(),'user-b',operation);
    assert.ok(await accountB.subscription(),operation);
    await assert.rejects(b.api.subscription(),e=>e.code==='scope_unavailable',operation);
  }
});
