/* ============================================================
 * 抄本纪元 · 交互原型
 * 架构与框架铁律同构（tech/01）：
 *   - Board：世界状态板，一切写入带溯源并进事件流
 *   - emit()：事件流唯一通道；界面/日志/历史卷轴只消费事件流
 *   - 遭遇六态：进场→探索/发现→战斗/对话→结算→休整→出场
 *   - 一核两壳：gotoNode/检定/战斗为核；竖屏三段与横屏五区是两壳
 * ============================================================ */

/* ---------- 世界状态板（framework/07） ---------- */
const Board = {
  flags: {},
  rep: { scriptorium: 0, uninked: 0, salvage: 0 },
  clock: 0,                       // 褪墨度 0~10
  inv: ["fatedie"],
  gold: 50,
  bond: { "珂兰": 20, "老费": 10 },
  alignment: 50
};

/* ---------- 事件流（append-only） ---------- */
const Events = [];
let seq = 0;
function emit(type, payload, opts = {}) {
  const ev = { id: ++seq, type, payload, node: runtime.node, key: !!opts.key };
  Events.push(ev);
  renderStatusBand();
  return ev;
}

/* ---------- 运行时 ---------- */
const runtime = {
  screen: "home",        // home|entry|encounter|events|inventory|character|history|settle
  mode: null,            // 战役模式：'space'|'time'（战役入口择定并锁定，F1.4）
  node: null,
  phase: "explore",      // 遭遇状态机当前态（驱动竖屏呼吸）
  tab: "action",         // 操作台 Tab
  battle: null,
  settleBuf: [],         // 本遭遇待结算清单（⑨ 结算界面念给玩家听）
  consoleReturn: null,   // 从功能界面返回何处
  sliceDone: false
};

const $ = (s) => document.querySelector(s);
const host = $("#screen-host");
const device = $("#device");

/* ---------- 写板原语（全部走事件流） ---------- */
function writeFlag(id, name) {
  Board.flags[id] = true;
  runtime.settleBuf.push({ k: "旗标点亮", v: name });
  emit("flag.write", { id, name });
}
function tickClock(d) {
  Board.clock = Math.max(0, Math.min(10, Board.clock + d));
  runtime.settleBuf.push({ k: "褪墨度", v: (d > 0 ? "+" : "") + d + " 格", bad: d > 0 });
  emit("clock.tick", { delta: d, now: Board.clock });
  if (Board.clock >= 2 && !Board.flags._inkrain_noticed) {
    Board.flags._inkrain_noticed = true;
    toast("时间边触发预告：墨雨夜袭（时钟 2 格）");
  }
}
function addRep(f, d) {
  Board.rep[f] = Math.max(-5, Math.min(5, Board.rep[f] + d));
  const names = { scriptorium: "誊写庭", uninked: "断墨会", salvage: "拾遗行会" };
  runtime.settleBuf.push({ k: "声望 · " + names[f], v: "+" + d });
  emit("rep.change", { faction: f, delta: d, now: Board.rep[f] });
}
function giveItem(id) {
  Board.inv.push(id);
  runtime.settleBuf.push({ k: "获得道具", v: PACK.items[id].name });
  emit("item.gain", { id, name: PACK.items[id].name });
}
function addXp(n) {
  runtime.settleBuf.push({ k: "经验", v: "+" + n });
  emit("xp.gain", { n });
}

/* ---------- 轻规则包 v1：检定与战斗 ---------- */
const DC = { easy: 8, medium: 12, hard: 16 };
const d20 = () => 1 + Math.floor(Math.random() * 20);
const dN = (n) => 1 + Math.floor(Math.random() * n);
function modOf(attr) { return PACK.player.attrs[attr] || 0; }
function profOf(skill) { return PACK.player.prof.includes(skill) ? 2 : 0; }
function dmgRoll(expr) {
  const m = expr.match(/(\d+)d(\d+)([+-]\d+)?/);
  let sum = 0;
  for (let i = 0; i < +m[1]; i++) sum += dN(+m[2]);
  return sum + (m[3] ? +m[3] : 0);
}

/* ============================================================
 * 渲染入口
 * ============================================================ */
function render() {
  renderStatusBand();
  const R = {
    home: renderHome, entry: renderEntry, encounter: renderEncounter,
    events: renderEvents, inventory: renderInventory, character: renderCharacter,
    history: renderHistory, settle: renderSettle
  };
  R[runtime.screen]();
}

function renderStatusBand() {
  // 纪元时间钟总览格（点按 → 时间边预告弹层）
  const pips = Array.from({ length: 10 }, (_, i) =>
    `<div class="pip ${i < Board.clock ? "on" : "off"}"></div>`).join("");
  $("#sb-clock").innerHTML = pips;
  const party = [PACK.player, ...PACK.companions].map(p =>
    `<div class="hp-chip"><div class="avatar">${p.name[0]}</div>
     <div class="hp-bar"><i style="width:${Math.max(0, p.hp / p.maxhp * 100)}%"></i></div></div>`).join("");
  $("#sb-party").innerHTML = party;
  $("#sb-progress").textContent = runtime.node
    ? nodeActTitle() + " · " + (PACK.nodes[runtime.node] || {}).title : "烬港 · 营地";
}
function nodeActTitle() {
  const act = PACK.acts.find(a => PACK.nodes[runtime.node] &&
    runtime.node.startsWith("N" + a.id.slice(3)));
  return act ? act.title : "";
}

/* ============================================================
 * ① 主屏（营地）
 * ============================================================ */
function renderHome() {
  device.className = "portrait";
  host.innerHTML = `
  <div class="screen" id="home">
    <div id="home-vista">
      <h1>烬 港</h1>
      <div class="sub">${Board.clock === 0 ? "潮水如常。但你怀里的空白比夜色更重。"
        : Board.clock < 3 ? "城里的地名又少了一个。人们学会了不去提。"
        : "褪墨在逼近。半座城已经想不起自己的过去。"}</div>
    </div>
    <div id="home-ops">
      <div id="home-broadcast">◈ 运营位：「命骰考」图鉴系列上新预告（框架级位，内容由投放决定）</div>
      <div class="grid">
        <button class="op-btn" onclick="go('entry')"><div class="t">战役入口</div>
          <div class="d">${runtime.node && !runtime.sliceDone ? "继续：《烬港残页》" : "《烬港残页》 · 待开始"}</div></button>
        <button class="op-btn" onclick="go('events')"><div class="t">事件中心${Board.clock >= 1 ? '<span class="corner"></span>' : ""}</div>
          <div class="d">世界正在发生什么</div></button>
        <button class="op-btn" onclick="go('inventory')"><div class="t">背包图鉴</div>
          <div class="d">${Board.inv.length} 件道具 · 四系列图鉴</div></button>
        <button class="op-btn" onclick="go('character')"><div class="t">角色</div>
          <div class="d">队伍 · 羁绊 · 配装</div></button>
        <button class="op-btn" style="grid-column:1/3" onclick="go('history')"><div class="t">历史卷轴</div>
          <div class="d">为什么会变成这样——事件流档案（${Events.length} 条）</div></button>
      </div>
    </div>
  </div>`;
}

/* ============================================================
 * ② 战役入口（模式分支选择点）
 * ============================================================ */
function renderEntry() {
  device.className = "portrait";
  const collected = Object.keys(Board.flags).filter(k => !k.startsWith("_")).length;
  host.innerHTML = `
  <div class="screen">
    <div class="page-head"><h3>战役入口</h3>
      <button class="back" onclick="go('home')">← 主屏</button></div>
    <div class="page-body">
      <div class="campaign-card">
        <h2>烬港残页</h2>
        <div class="meta">抄本纪元 · 第一篇　|　轻规则包 v1　|　推荐等级 1~4　|　预计 6~9 小时</div>
        <p>这座城市正在褪色：先是港口的地名，然后是一条街，然后是某个人的女儿。
        三个阵营同时找上了你——因为你手里那枚命骰，是这座城市最后一支笔。</p>
        <div class="meta" style="margin-top:8px">分支收集：已点亮旗标 ${collected} 枚　结局分型 0/4</div>
      </div>
      ${runtime.mode ? "" : `
      <div style="padding:0 14px 6px;color:var(--dim);font-size:12px">本战役为<b style="color:var(--gold)">双模式可选</b>——进入即一次分支选择（F1.2）：</div>
      <div class="mode-cards">
        <button class="mode-card" id="mc-space" onclick="pickMode('space')">
          <div class="t">横屏 · 空间战役</div>
          <div class="d">把战场摊开：战术格、站位、大战场。<br>适合：战术推演、横屏握持。</div>
          <div class="r"><span class="tag gold">推荐：终章 Boss</span></div>
        </button>
        <button class="mode-card" id="mc-time" onclick="pickMode('time')">
          <div class="t">竖屏 · 时间战役</div>
          <div class="d">把故事流过去：多房间、逐节拍、单手可达。<br>适合：通勤、碎片时间。</div>
          <div class="r"><span class="tag blue">推荐：叙事流</span></div>
        </button>
      </div>
      <div class="forced-note">注：序章与幕三为<b>强制竖屏时间形态</b>——这段历史已经残破，只能一间房一间房地回放（世界观 §8）。</div>`}
      ${runtime.mode ? `<div class="forced-note">模式已择定：${runtime.mode === "space" ? "横屏 · 空间战役" : "竖屏 · 时间战役"}（本战役期间锁定，F1.4）。另一形态可在二周目重玩。</div>` : ""}
      <div class="choices">
        <button class="btn primary center" ${runtime.mode ? "" : "disabled"}
          onclick="startCampaign()">${runtime.node && !runtime.sliceDone ? "▶ 继续战役" : "▶ 开始战役"}</button>
      </div>
    </div>
  </div>`;
}
function pickMode(m) {
  runtime.mode = m;
  emit("mode.pick", { mode: m });
  renderEntry();
}
function startCampaign() {
  if (!runtime.node || runtime.sliceDone) { runtime.node = "N0-1"; runtime.sliceDone = false; }
  runtime.screen = "encounter";
  enterNode(runtime.node);
}

/* ============================================================
 * ③④ 遭遇（一核两壳）
 * ============================================================ */
function enterNode(id) {
  const node = PACK.nodes[id];
  if (!node) return;
  runtime.node = id;
  runtime.settleBuf = [];
  // 强制模式：序章强制竖屏（战役书模式声明 forced.SL-0）
  const forcedTime = id.startsWith("N0");
  if (forcedTime && runtime.mode === "space") {
    toast("「这一段记忆只能以碎片的方式回放」——序章强制竖屏时间形态");
  }
  emit("node.enter", { id, title: node.title });
  (node.onEnter || []).forEach(e => {
    if (e.flag) writeFlag(e.flag, e.name);
    if (e.clock) tickClock(e.clock);
    if (e.xp) addXp(e.xp);
  });
  if (node.type === "battle") startBattle(node);
  else runtime.phase = node.type === "dialog" ? "dialog" : "explore";
  runtime.tab = "action";
  renderEncounter();
}

function gotoNode(id) {
  if (id === "END") {
    runtime.sliceDone = true;
    // 切片终局结算：把整场写板结果念给玩家听（09 §9 结算界面职责）
    const flagNames = { seen_fading: "眼见为实", witnessed_revocation: "见证撤销" };
    const buf = [];
    Object.keys(Board.flags).filter(k => !k.startsWith("_")).forEach(k =>
      buf.push({ k: "旗标点亮", v: flagNames[k] || k }));
    const repNames = { scriptorium: "誊写庭", uninked: "断墨会", salvage: "拾遗行会" };
    Object.entries(Board.rep).filter(([, v]) => v !== 0).forEach(([f, v]) =>
      buf.push({ k: "声望 · " + repNames[f], v: "+" + v }));
    if (Board.clock > 0) buf.push({ k: "褪墨度", v: Board.clock + " / 10 格", bad: true });
    Board.inv.filter(i => i !== "fatedie").forEach(i =>
      buf.push({ k: "持有道具", v: PACK.items[i].name }));
    runtime.settleBuf = buf;
    runtime.screen = "settle"; render(); return;
  }
  enterNode(id);
}

/* ---------- 竖屏壳：三段呼吸 ---------- */
function roomIcon(n) {
  return { scene: "✉", check: "✦", dialog: "☰", battle: "⚔️", hub: "⌂", branch: "⊞" }[n.type] || "·";
}
// 派生节点（N0-3a/b、N1-2b）归属主编号房间（tech/02 §12 V6 同款逻辑计数）
function roomKey(id) { return id.replace(/([a-z])$/, ""); }
function renderEncounter() {
  if (runtime.mode === "space" && !runtime.node.startsWith("N0")) renderEncounterLandscape();
  else renderEncounterPortrait();
}
function renderEncounterPortrait() {
  device.className = "portrait";
  const node = PACK.nodes[runtime.node];
  const idx = PACK.rooms.findIndex(r => r === roomKey(runtime.node));
  const track = PACK.rooms.map((r, i) => {
    const n = PACK.nodes[r] || PACK.nodes[r + "a"];
    const cls = i < idx ? "done" : i === idx ? "now" : "future";
    return `<div class="room-pip ${cls}">${i <= idx ? roomIcon(n) : "?"}</div>`;
  }).join("");
  host.innerHTML = `
  <div id="enc-portrait" class="screen st-${runtime.phase === "battle" ? "battle" : runtime.phase === "dialog" ? "dialog" : runtime.phase === "settle" ? "settle" : "explore"}">
    <div id="room-track" title="房间序列推进条（下滑可回看已过房间）">${track}</div>
    <div id="vp-view" class="scrolly">${viewHTML(node)}</div>
    <div id="vp-console">
      <div id="console-tabs">${["action", "dice", "log", "char"].map(t =>
        `<button class="tab ${runtime.tab === t ? "on" : ""}" onclick="setTab('${t}')">${{ action: "行动", dice: "骰子", log: "日志", char: "角色" }[t]}</button>`).join("")}
      </div>
      <div id="console-body">${consoleHTML(node)}</div>
    </div>
  </div>`;
  const log = $("#console-body");
  if (runtime.tab === "log" && log) log.scrollTop = log.scrollHeight;
}
function setTab(t) { runtime.tab = t; renderEncounter(); }

function viewHTML(node) {
  if (runtime.phase === "battle" && runtime.battle) return battleViewHTML();
  let h = `<div class="narrative"><div class="node-title">${node.title}</div>${node.text.replace(/\n/g, "<br>")}</div>`;
  if (runtime.phase === "dialog" && node.options) {
    // 对话选项放在操作台（对话态呼吸：操作台 42%）——此处仅留 NPC 演出区
  }
  return h;
}

function consoleHTML(node) {
  switch (runtime.tab) {
    case "action": return actionHTML(node);
    case "dice": return diceTrayHTML();
    case "log": return logHTML();
    case "char": return charCardMini();
  }
}
function actionHTML(node) {
  let h = "";
  if (runtime.phase === "battle" && runtime.battle) return battleActionsHTML();
  if (node.type === "check" && !node._rolled) {
    const c = node.check;
    h += `<div class="check-hint">检定：${c.skill}（${c.attr}）· ${c.dc <= 8 ? "易" : c.dc <= 12 ? "中" : "难"} DC ${c.dc}${c.key ? '　<span class="tag gold">关键判定</span>' : ""}</div>`;
    h += `<button class="btn primary center" onclick="doNodeCheck()">🎲 掷出命骰（d20+${modOf(c.attr) + profOf(c.skill)}）</button>`;
    return h;
  }
  if (runtime.phase === "dialog" && node.options && !node._replied) {
    h += node.options.map((o, i) =>
      `<button class="btn" onclick="pickOption(${i})">${o.label}<span class="badge">${o.rep ? "声望+" : ""}</span></button>`).join("");
    return h;
  }
  if (node.type === "hub") {
    h += `<button class="btn" onclick="openShop()">🛒 杂货铺（金币 ${Board.gold}）</button>`;
    h += `<button class="btn" onclick="showRumor()">👂 听听传闻</button>`;
  }
  h += node.edges.map(e =>
    `<button class="btn primary" onclick="gotoNode('${e.to}')">${e.label} →</button>`).join("");
  return h;
}
function showRumor() { toast("传闻：" + PACK.nodes["N1-1"].rumor); }

/* ---------- 检定（含关键判定全屏演出，09 文档 §6） ---------- */
function doNodeCheck() {
  const node = PACK.nodes[runtime.node];
  const c = node.check;
  node._rolled = true;
  const roll = d20();
  const mod = modOf(c.attr) + profOf(c.skill);
  const total = roll + mod;
  const success = total >= c.dc;
  const crit = roll === 20, fumble = roll === 1;
  const finish = () => {
    emit("check.roll", { skill: c.skill, roll, mod, dc: c.dc, total, success, crit, fumble }, { key: c.key });
    addLog(`<b>${c.skill}检定</b>：d20=<b class="${crit ? "crit" : fumble ? "fail" : ""}">${roll}</b>+${mod} = <b>${total}</b> vs DC ${c.dc} → ${success ? '<b class="crit">成功</b>' : '<b class="fail">失败</b>'}${crit ? "（大成功！）" : fumble ? "（大失败）" : ""}`);
    lastRoll = { roll, mod, total, dc: c.dc, success };
    gotoNode(success ? node.success : node.failure);
  };
  if (c.key) keyRollShow(c, roll, mod, total, success, finish);
  else quickRollShow(finish);
}

let lastRoll = null;
function quickTrayAnimate(cb) { cb(); }
function keyRollShow(c, roll, mod, total, success, finish) {
  const ov = $("#dice-overlay"), die = $("#dice-die"), cap = $("#dice-caption");
  ov.classList.remove("hidden");
  die.textContent = "?"; die.classList.add("rolling");
  cap.innerHTML = `${c.keyReason || "关键判定"}：${c.skill}（d20+${mod} vs DC ${c.dc}）`;
  let skipped = false;
  const skip = () => { if (!skipped) { skipped = true; resolve(); } };
  let pressTimer;
  ov.onmousedown = () => { pressTimer = setTimeout(skip, 400); };   // 长按跳过（04 §④.7）
  ov.onmouseup = () => clearTimeout(pressTimer);
  const resolve = () => {
    die.classList.remove("rolling");
    die.textContent = roll;
    cap.innerHTML += `<br><span class="res">${roll}+${mod} = ${total}　${total >= c.dc ? "——织卷为你留白" : "——织卷不为所动"}</span>`;
    setTimeout(() => { ov.classList.add("hidden"); finish(); }, skipped ? 500 : 1400);
  };
  setTimeout(() => { if (!skipped) resolve(); }, 1700);
}
function quickRollShow(finish) { finish(); } // 普通检定：就地快速结算（≤0.5s 体感由日志呈现）

/* ---------- 对话选项 ---------- */
function pickOption(i) {
  const node = PACK.nodes[runtime.node];
  const o = node.options[i];
  node._replied = true;
  emit("dialog.pick", { node: node.title, label: o.label });
  if (o.rep) for (const f in o.rep) addRep(f, o.rep[f]);
  addLog(`<b>你</b>：${o.label}<br><b>对方</b>：${o.reply}`);
  runtime.tab = "log";
  renderEncounter();
  setTimeout(() => { runtime.tab = "action"; renderEncounter(); }, 1600);
}

/* ---------- 商店弹层（半屏弹层，04 §3.3） ---------- */
function openShop() {
  const shop = PACK.nodes["N1-1"].shop;
  const items = shop.map(s => {
    const it = PACK.items[s.item];
    const owned = Board.inv.includes(s.item);
    return `<div class="item-row"><div><b>${it.name}</b><br><span style="font-size:11px;color:var(--dim)">${it.desc}</span></div>
      <div class="roles">${s.price} 金</div>
      <button class="btn" style="width:auto;margin:0;padding:4px 10px" ${owned || Board.gold < s.price ? "disabled" : ""}
        onclick="buyItem('${s.item}',${s.price})">${owned ? "已持有" : "购买"}</button></div>`;
  }).join("");
  host.insertAdjacentHTML("beforeend",
    `<div class="dim-mask" onclick="closeSheet()"></div>
     <div class="sheet"><button class="close" onclick="closeSheet()">✕</button>
     <div class="page-head" style="border:none;padding:0 0 8px"><h3>杂货铺</h3><span style="color:var(--gold)">金币 ${Board.gold}</span></div>${items}</div>`);
}
function buyItem(id, price) {
  Board.gold -= price; giveItem(id);
  toast(`购得「${PACK.items[id].name}」——分支钥匙已入手`);
  closeSheet(); renderEncounter();
}
function closeSheet() {
  document.querySelectorAll(".sheet,.dim-mask").forEach(e => e.remove());
}

/* ---------- 战斗态 ---------- */
function startBattle(node) {
  const spec = PACK.enemies[node.encounter.enemy];
  runtime.phase = "battle";
  runtime.battle = {
    spec, round: 1, busy: false, over: false,
    enemies: Array.from({ length: spec.count }, (_, i) => ({
      name: spec.name + (spec.count > 1 ? "·" + "甲乙"[i] : ""), hp: spec.hp, ac: spec.ac, atk: spec.atk, dmg: spec.dmg
    })),
    skillUses: {}
  };
  // 横屏网格占位坐标
  runtime.battle.pos = { allies: [[2, 4]], enemies: spec.count === 1 ? [[3, 1]] : [[2, 1], [4, 1]] };
  addLog(`<b class="hurt">遭遇战开始：${node.title}</b>（先攻：d20+敏，玩家先手）`);
  emit("battle.start", { id: node.encounter.id, enemy: spec.name });
}
function battleViewHTML() {
  const b = runtime.battle;
  const foes = b.enemies.map((e, i) =>
    `<div class="unit enemy ${e.hp <= 0 ? "" : ""}" style="${e.hp <= 0 ? "opacity:.3" : ""}">
      <div class="nm">${e.hp <= 0 ? "消散" : e.name}</div><div class="hp">HP ${Math.max(0, e.hp)}/${b.spec.hp} · AC ${e.ac}</div></div>`).join("");
  return `<div id="vp-battle"><div class="lane">
    <div class="unit-row">${foes}</div>
    <div class="vs-mark">— 竖向战场 · 第 ${b.round} 回合 —</div>
    <div class="unit-row"><div class="unit active"><div class="nm">${PACK.player.name}</div>
      <div class="hp">HP ${PACK.player.hp}/${PACK.player.maxhp} · AC ${PACK.player.ac}</div></div></div>
  </div></div>`;
}
function battleActionsHTML() {
  const b = runtime.battle;
  if (!b || b.over) return `<button class="btn primary" onclick="winBattle()">战斗结束 → 结算</button>`;
  if (b.busy) return `<div class="check-hint">敌方行动中……</div>`;
  let h = `<div class="check-hint">三段式行动经济：动作 + 附赠（移动已省略于切片）</div>`;
  PACK.player.skills.forEach((s, i) => {
    const uses = s.uses ? (b.skillUses[s.id] || 0) : 0;
    const left = s.uses ? s.uses - uses : Infinity;
    h += `<button class="btn" ${left <= 0 ? "disabled" : ""} onclick="attack(${i})">⚔️ ${s.name}
      <span class="badge">${s.dmg}${s.uses ? " · 余 " + (left) : ""}</span></button>`;
  });
  return h;
}
function attack(i) {
  const b = runtime.battle, s = PACK.player.skills[i];
  if (s.uses) b.skillUses[s.id] = (b.skillUses[s.id] || 0) + 1;
  const target = b.enemies.find(e => e.hp > 0);
  const roll = d20(), mod = modOf(s.attr), total = roll + mod;
  const hit = roll === 20 || (roll !== 1 && total >= target.ac);
  const dmg = hit ? dmgRoll(s.dmg) + (roll === 20 ? dmgRoll(s.dmg) : 0) : 0;
  if (hit) target.hp -= dmg;
  addLog(`<b>${s.name}</b>：d20=${roll}+${mod}=${total} vs AC ${target.ac} → ${hit ? `<b class="crit">命中</b>，伤害 <b>${dmg}</b>` : '<b class="fail">未命中</b>'}`);
  emit("battle.attack", { skill: s.name, roll, total, hit, dmg });
  if (b.enemies.every(e => e.hp <= 0)) { b.over = true; renderEncounter(); return; }
  b.busy = true; renderEncounter();
  setTimeout(enemyTurn, 900);
}
function enemyTurn() {
  const b = runtime.battle;
  b.enemies.filter(e => e.hp > 0).forEach(e => {
    const roll = d20(), total = roll + e.atk;
    const hit = roll !== 1 && total >= PACK.player.ac;
    const dmg = hit ? dmgRoll(e.dmg) : 0;
    if (hit) PACK.player.hp -= dmg;
    addLog(`<b class="hurt">${e.name}</b>反扑：d20=${roll}+${e.atk}=${total} vs AC ${PACK.player.ac} → ${hit ? `<b class="hurt">命中</b>，你受到 <b class="hurt">${dmg}</b> 伤害` : "被闪开"}`);
  });
  b.round++; b.busy = false;
  if (PACK.player.hp <= 0) { deathSave(); return; }
  renderEncounter();
}
function deathSave() {
  // 死亡豁免：框架恒定关键判定（09 §6），三局两胜简化为一次演示
  const c = { skill: "死亡豁免", dc: 10, key: true, keyReason: "死亡豁免：织卷前的最后一线" };
  const roll = d20();
  keyRollShow(c, roll, 0, roll, roll >= 10, () => {
    const ok = roll >= 10;
    emit("check.roll", { skill: "死亡豁免", roll, mod: 0, dc: 10, total: roll, success: ok }, { key: true });
    if (ok) {
      PACK.player.hp = 1;
      addLog(`<b class="crit">死亡豁免成功</b>（${roll}≥10）：你以 1 HP 稳住。`);
      runtime.battle.busy = false; runtime.battle.round++;
      renderEncounter();
    } else {
      addLog(`<b class="fail">死亡豁免失败</b>——但失败即分支：同伴把你拖出了战场。`);
      PACK.player.hp = 1; runtime.battle.over = true; runtime.battle.fled = true;
      renderEncounter();
    }
  });
}
function winBattle() {
  const node = PACK.nodes[runtime.node];
  const fled = runtime.battle && runtime.battle.fled;
  const w = node.encounter && node.onWin || {};
  if (!fled) {
    if (w.xp) addXp(w.xp);
    if (w.item) giveItem(w.item);
  }
  if (w.clock) tickClock(w.clock);
  emit("battle.end", { id: node.encounter.id, result: fled ? "fled" : "win" });
  addLog(fled ? `<b class="fail">被迫撤退</b>：经验与战利品留在了战场上。` : `<b class="crit">战斗胜利</b>${w.note ? "（" + w.note + "）" : ""}`);
  runtime.battle = null; runtime.phase = "settle";
  runtime.tab = "action";
  renderEncounter();
}

/* ---------- 横屏壳：五区布局 ---------- */
function renderEncounterLandscape() {
  device.className = "landscape";
  const node = PACK.nodes[runtime.node];
  const inBattle = runtime.phase === "battle" && runtime.battle;
  const center = inBattle ? gridHTML()
    : `<div class="narrative" style="max-width:78%"><div class="node-title">${node.title}</div>${node.text.replace(/\n/g, "<br>")}</div>`;
  host.innerHTML = `
  <div id="enc-landscape" class="screen">
    <div id="ls-top">
      <span style="color:var(--gold)">${node.title}</span>
      <span style="color:var(--dim)">${nodeActTitle()}</span>
      <div id="ls-top-init">${inBattle ? `<span class="init-chip on">你</span>` + runtime.battle.enemies.map(e => `<span class="init-chip">${e.name}</span>`).join("") : ""}</div>
    </div>
    <div id="ls-mid">
      <div id="ls-left">${lsActionsHTML(node)}</div>
      <div id="ls-center">${center}</div>
      <div id="ls-right">${lsDiceHTML()}</div>
    </div>
    <div id="ls-bottom" onclick="this.classList.toggle('open')" title="上滑/点击展开半屏日志">📜 ${lastLogLine()} <span style="float:right;color:var(--gold-dim)">点击展开</span></div>
  </div>`;
  const btm = $("#ls-bottom");
  if (btm.classList.contains("open")) btm.innerHTML = logHTML();
}
function lsActionsHTML(node) {
  if (runtime.phase === "battle" && runtime.battle) {
    if (runtime.battle.over) return `<button class="btn primary act" onclick="winBattle()">结算 →</button>`;
    if (runtime.battle.busy) return `<div class="check-hint">敌方行动中…</div>`;
    return PACK.player.skills.map((s, i) => {
      const left = s.uses ? s.uses - (runtime.battle.skillUses[s.id] || 0) : Infinity;
      return `<button class="btn act" ${left <= 0 ? "disabled" : ""} onclick="attack(${i})">${s.name}<br><span style="font-size:10px;color:var(--dim)">${s.dmg}${s.uses ? " ·余" + left : ""}</span></button>`;
    }).join("");
  }
  if (node.type === "check" && !node._rolled) {
    const c = node.check;
    return `<div class="check-hint">${c.skill}·DC${c.dc}${c.key ? "<br><span class='tag gold'>关键</span>" : ""}</div>
      <button class="btn primary act" onclick="doNodeCheck()">🎲 检定</button>`;
  }
  if (runtime.phase === "dialog" && node.options && !node._replied) {
    return node.options.map((o, i) => `<button class="btn act" onclick="pickOption(${i})">${o.label}</button>`).join("");
  }
  let h = "";
  if (node.type === "hub") h += `<button class="btn act" onclick="openShop()">🛒 商店</button><button class="btn act" onclick="showRumor()">👂 传闻</button>`;
  h += node.edges.map(e => `<button class="btn primary act" onclick="gotoNode('${e.to}')">${e.label}</button>`).join("");
  return h;
}
function lsDiceHTML() {
  return `<div class="d20" id="ls-die">${lastRoll ? lastRoll.roll : "20"}</div>
    <div class="roll-result">${lastRoll ? `d20=<b>${lastRoll.roll}</b>+${lastRoll.mod}=${lastRoll.total}<br>vs DC ${lastRoll.dc} → ${lastRoll.success ? '<b class="crit">成功</b>' : '<b class="fail">失败</b>'}` : "D20 待命"}</div>`;
}
function gridHTML() {
  const b = runtime.battle;
  let cells = "";
  for (let y = 0; y < 5; y++) for (let x = 0; x < 8; x++) {
    let cls = "", label = "";
    if (b.pos.allies.some(([ax, ay]) => ax === x && ay === y)) { cls = "ally"; label = "你"; }
    b.pos.enemies.forEach(([ex, ey], i) => {
      if (ex === x && ey === y && b.enemies[i].hp > 0) { cls = "enemy"; label = "墨"; }
    });
    cells += `<div class="cell ${cls}">${label}${cls === "" ? `<span class="sub">${x},${y}</span>` : ""}</div>`;
  }
  return `<div id="grid-map">${cells}</div>
    <div style="position:absolute;bottom:8px;font-size:10px;color:var(--dim)">战术格 8×5 · 同屏单位 ≤8 · 弹道线/威胁范围以描边表达</div>`;
}

/* ---------- 日志（事件流视图） ---------- */
function addLog(html) {
  emit("log", { html });
  if (runtime.screen === "encounter" && runtime.tab === "log") renderEncounter();
}
function lastLogLine() {
  const e = [...Events].reverse().find(e => e.type === "log");
  return e ? e.payload.html.replace(/<[^>]+>/g, "") : "……";
}
function logHTML() {
  const lines = Events.filter(e => e.type === "log").map(e => `<div class="log-line">${e.payload.html}</div>`);
  return lines.length ? lines.join("") : `<div class="log-line">日志为空。</div>`;
}
function charCardMini() {
  const p = PACK.player;
  return `<div class="card"><div class="t">${p.name}</div>
    <div class="d">HP ${p.hp}/${p.maxhp} · AC ${p.ac}　|　力 ${p.attrs.力} · 敏 ${p.attrs.敏} · 智 ${p.attrs.智}<br>
    熟练：${p.prof.join("、")}　|　技能：${p.skills.map(s => s.name).join("、")}</div></div>
    <button class="btn center" onclick="go('character')">上滑：完整角色卡 →</button>`;
}

/* ============================================================
 * ⑤ 事件中心
 * ============================================================ */
function renderEvents() {
  host.innerHTML = `
  <div class="screen">
    <div class="page-head"><h3>事件中心</h3><span style="font-size:11px;color:var(--dim)">世界正在发生什么</span>
      <button class="back" onclick="go('home')">← 主屏</button></div>
    <div class="page-body">
      ${Board.clock >= 1 ? `<div class="card"><div class="t"><span class="new-dot">●</span> 新旗标点亮</div>
        <div class="d">${Object.entries(Board.flags).filter(([k]) => !k.startsWith("_")).map(([k]) => ({ seen_fading: "眼见为实", witnessed_revocation: "见证撤销" })[k]).filter(Boolean).join("、") || "——"}</div></div>` : ""}
      ${PACK.eventsList.map(e => `
      <div class="card"><div class="t">${e.name}
        <span class="tag ${e.state === "active" ? "gold" : ""}">${e.state === "active" ? "进行中" : "待触发"}</span></div>
        <div class="d">目标：${e.obj}${e.id === "ink_rain_raid" ? `　<span class="tag red">时间钟 ${Board.clock}/2 格</span>` : ""}</div></div>`).join("")}
    </div>
  </div>`;
}

/* ============================================================
 * ⑥ 背包图鉴
 * ============================================================ */
let invTab = "bag";
function renderInventory() {
  const bag = Board.inv.map(id => {
    const it = PACK.items[id];
    return `<div class="item-row"><div><b>${it.name}</b><br><span style="font-size:11px;color:var(--dim)">${it.desc}</span></div>
      <div class="roles">${it.roles.map(r => `<span class="tag">${{ stat: "数值", check_mod: "检定", branch_key: "钥匙", codex: "图鉴" }[r]}</span>`).join("")}</div></div>`;
  }).join("");
  const codex = PACK.codexSeries.map(s =>
    `<div class="card"><div class="t">${s.name}　<span class="tag gold">${s.got}/${s.total}</span></div>
      <div class="d">集齐奖励：${s.reward}</div></div>`).join("");
  host.innerHTML = `
  <div class="screen">
    <div class="page-head"><h3>背包图鉴</h3><span style="color:var(--gold);font-size:12px">金币 ${Board.gold}</span>
      <button class="back" onclick="go('home')">← 主屏</button></div>
    <div class="subtabs">
      <button class="tab ${invTab === "bag" ? "on" : ""}" onclick="invTab='bag';render()">背包</button>
      <button class="tab ${invTab === "codex" ? "on" : ""}" onclick="invTab='codex';render()">图鉴</button>
    </div>
    <div class="page-body">${invTab === "bag" ? bag : codex}</div>
  </div>`;
}

/* ============================================================
 * ⑦ 角色
 * ============================================================ */
function renderCharacter() {
  const p = PACK.player;
  const bonds = PACK.companions.map(c =>
    `<div class="card"><div class="t">${c.name}　<span class="tag">羁绊 ${Board.bond[c.name]}</span></div>
    <div class="d">${c.note}<br>HP ${c.hp}/${c.maxhp}　·　羁绊 ≥60 解锁个人任务线</div></div>`).join("");
  host.innerHTML = `
  <div class="screen">
    <div class="page-head"><h3>角色</h3><button class="back" onclick="go('home')">← 主屏</button></div>
    <div class="page-body">
      <div class="card"><div class="t">${p.name}（白页者 · 1 级）</div>
        <div class="attr-row"><b>力</b>+${p.attrs.力}　<b>敏</b>+${p.attrs.敏}　<b>智</b>+${p.attrs.智}</div>
        <div class="d">HP ${p.hp}/${p.maxhp} · AC ${p.ac}　|　熟练：${p.prof.join("、")}（+2）<br>
        技能（次数制）：${p.skills.map(s => `${s.name} ${s.dmg}${s.uses ? " ×" + s.uses : ""}`).join("　")}</div></div>
      <div class="card"><div class="t">抉择倾向</div><div class="d">
        留白 0 ←——　<b style="color:var(--gold)">${Board.alignment}</b>　——→ 100 墨守<br>
        结局分型由终章时的倾向值决定（战役书 §9）</div></div>
      ${bonds}
    </div>
  </div>`;
}

/* ============================================================
 * ⑧ 历史卷轴
 * ============================================================ */
function renderHistory() {
  const names = { "check.roll": "检定", "flag.write": "旗标", "clock.tick": "时间钟", "rep.change": "声望",
    "item.gain": "道具", "xp.gain": "经验", "battle.start": "战斗", "battle.attack": "攻击", "battle.end": "战斗结束",
    "dialog.pick": "对话", "node.enter": "节点", "mode.pick": "模式", "log": "日志" };
  const items = [...Events].reverse().filter(e => e.type !== "log").map(e => {
    const p = e.payload; let line = "", detail = "";
    if (e.type === "check.roll") {
      line = `${p.skill}检定：${p.total} vs DC ${p.dc} → ${p.success ? "成功" : "失败"}`;
      detail = `骰值 ${p.roll} + 修正 ${p.mod} = ${p.total}${p.crit ? " · 大成功" : ""}${p.fumble ? " · 大失败" : ""}`;
    } else if (e.type === "flag.write") { line = `旗标点亮：「${p.name}」`; detail = `由事件 #${e.id} 写入（旗标追溯：谁点亮了它）`; }
    else if (e.type === "clock.tick") line = `褪墨度 ${p.delta > 0 ? "+" : ""}${p.delta} → ${p.now} 格`;
    else if (e.type === "rep.change") line = `声望变化：${{ scriptorium: "誊写庭", uninked: "断墨会", salvage: "拾遗行会" }[p.faction]} ${p.delta > 0 ? "+" : ""}${p.delta}`;
    else if (e.type === "item.gain") line = `获得道具：「${p.name}」`;
    else if (e.type === "xp.gain") line = `经验 +${p.n}`;
    else if (e.type === "battle.start") line = `遭遇战开始：${p.enemy}`;
    else if (e.type === "battle.end") line = `战斗结束：${p.result === "win" ? "胜利" : "撤退"}`;
    else if (e.type === "mode.pick") line = `战役模式择定：${p.mode === "space" ? "横屏 · 空间" : "竖屏 · 时间"}`;
    else if (e.type === "battle.attack") { line = `${p.skill}：${p.hit ? "命中 " + p.dmg + " 伤害" : "未命中"}`; detail = `d20=${p.roll} 总计 ${p.total}`; }
    else if (e.type === "node.enter") line = `进入节点：${p.title}`;
    else line = names[e.type] ? names[e.type] + " · " + JSON.stringify(p).slice(0, 40) : e.type;
    return `<div class="hist-item ${e.key ? "key" : ""}" onclick="this.classList.toggle('open')">
      <div class="t">#${e.id} ${line}${e.key ? ' <span class="tag gold">关键</span>' : ""}</div>
      <div class="detail">${detail || "（无明细）"}</div>
      <div class="src">来源：${e.node || "系统"}　类型：${names[e.type] || e.type}</div></div>`;
  }).join("");
  host.innerHTML = `
  <div class="screen">
    <div class="page-head"><h3>历史卷轴</h3><span style="font-size:11px;color:var(--dim)">事件流档案 · 点击条目展开明细</span>
      <button class="back" onclick="go(runtime.consoleReturn||'home')">← 返回</button></div>
    <div class="page-body">${items || '<div class="log-line">卷轴还是空白——去玩一局。</div>'}</div>
  </div>`;
}

/* ============================================================
 * ⑨ 结算界面
 * ============================================================ */
function renderSettle() {
  const lines = runtime.settleBuf.length ? runtime.settleBuf : [{ k: "切片完成", v: "《烬港残页》序章+幕一" }];
  host.innerHTML = `
  <div class="screen" id="settle-screen">
    <h2>结 算</h2>
    <div class="settle-lines">
      ${lines.map((l, i) => `<div class="settle-line" style="animation-delay:${i * 0.18}s">
        <span class="k">${l.k}</span><span class="v ${l.bad ? "bad" : ""}">${l.v}</span></div>`).join("")}
      <div class="settle-line" style="animation-delay:${lines.length * 0.18}s">
        <span class="k">新增卷轴条目</span><span class="v">${Events.length} 条事件流</span></div>
    </div>
    <div style="width:100%;max-width:300px">
      <button class="btn primary center" onclick="runtime.consoleReturn='settle';go('history')">查看新增卷轴条目</button>
      <button class="btn center" onclick="go('home')">回主屏（营地）</button>
    </div>
  </div>`;
}

/* ---------- 通用 ---------- */
function go(s) { runtime.screen = s; render(); }
function toast(msg) {
  const t = document.createElement("div");
  t.className = "toast"; t.textContent = msg;
  device.appendChild(t);
  setTimeout(() => t.remove(), 2600);
}
$("#sb-clock").addEventListener("click", () => {
  toast(`褪墨度 ${Board.clock}/10　·　逼近的时间边：墨雨夜袭（2 格）${Board.clock >= 2 ? "——已触发" : ""}`);
});
$("#btn-mode-compare").addEventListener("click", () => {
  if (runtime.screen !== "encounter") { toast("进入遭遇后可对比形态"); return; }
  runtime.mode = runtime.mode === "space" ? "time" : "space";
  toast("（原型调试）切换为" + (runtime.mode === "space" ? "横屏 · 空间" : "竖屏 · 时间") + "形态——同一事件流，两套渲染");
  renderEncounter();
});

render();
