// 冒烟测试：验证房间中继、上下线通知、以及不串房。
// 用 Node 22 自带的全局 WebSocket，无需装包。
const URL = 'ws://127.0.0.1:18080/ws';

const open = (room, role) => new Promise((resolve, reject) => {
  const ws = new WebSocket(`${URL}?room=${room}&role=${role}`);
  ws._msgs = [];
  ws.onmessage = (e) => ws._msgs.push(JSON.parse(e.data));
  ws.onopen = () => resolve(ws);
  ws.onerror = (e) => reject(new Error('ws error ' + role));
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const phone = await open('ctrl-dev001', 'phone');
  const pc = await open('ctrl-dev001', 'pc');
  const other = await open('ctrl-dev002', 'pc');   // 不该收到任何消息
  await sleep(300);

  const joined = phone._msgs.filter((m) => m.type === '_peerJoined');
  console.log('peerJoined 通知:', joined.length === 1 ? 'PASS' : 'FAIL(' + joined.length + ')');

  pc._msgs.length = 0;
  other._msgs.length = 0;

  pc.send(JSON.stringify({ t: 'd', x: 0.31, y: 0.72 }));
  phone.send(JSON.stringify({ t: 'ack' }));
  await sleep(400);

  const pcGotAck = pc._msgs.some((m) => m.t === 'ack');
  const phoneGotTap = phone._msgs.some((m) => m.t === 'd');
  const otherSilent = other._msgs.filter((m) => m.type !== '_peerJoined').length === 0;

  console.log('浏览器->手机 指令:', phoneGotTap ? 'PASS' : 'FAIL');
  console.log('手机->浏览器 回执:', pcGotAck ? 'PASS' : 'FAIL');
  console.log('跨房隔离:', otherSilent ? 'PASS' : 'FAIL(收到 ' + other._msgs.length + ' 条)');

  // 下线通知
  pc._msgs.length = 0;
  phone.close();
  await sleep(400);
  console.log('peerLeft 通知:', pc._msgs.some((m) => m.type === '_peerLeft') ? 'PASS' : 'FAIL');

  const rooms = await (await fetch('http://127.0.0.1:18080/api/rooms')).json();
  console.log('房间统计:', JSON.stringify(rooms));

  pc.close(); other.close();
  process.exit(0);
})().catch((e) => { console.error('FAIL', e.message); process.exit(1); });
