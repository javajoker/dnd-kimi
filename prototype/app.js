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
  inv: ["fatedie", "heal_potion"],
  gold: 50,
  bond: { "珂兰": 20, "老费": 10 },
  alignment: 50,
  xp: 0,
  level: 1
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
  Board.xp += n;
  runtime.settleBuf.push({ k: "经验", v: "+" + n });
  emit("xp.gain", { n });
}

/* ---------- 成长（11 文档 §6：300/700/1200 经验门槛） ---------- */
const XP_TABLE = [0, 300, 700, 1200];
function levelTarget() {
  let l = 1;
  for (let i = 1; i < XP_TABLE.length; i++) if (Board.xp >= XP_TABLE[i]) l = i + 1;
  return l;
}
function doLevelUp(attr) {
  if (Board.level >= levelTarget()) return;
  Board.level++;
  PACK.player.attrs[attr] = Math.min(3, PACK.player.attrs[attr] + 1);
  PACK.player.maxhp += 2; PACK.player.hp += 2;
  emit("level.up", { level: Board.level, attr });
  toast(`等级提升！Lv${Board.level}　${attr}+1　HP上限+2`);
  renderSettle();
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
        <button class="op-btn" onclick="go('history')"><div class="t">历史卷轴</div>
          <div class="d">事件流档案（${Events.length} 条）</div></button>
        <button class="op-btn" onclick="showCoach(HELP_PAGES,null)"><div class="t">帮助</div>
          <div class="d">手势图鉴 · 重学教程</div></button>
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
    <div id="room-track" title="房间序列推进条（下滑可回看已过房间）">${track}<button id="enc-menu" onclick="openEncMenu()" title="单局菜单">☰</button></div>
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
  attachGestures();
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
    h += `<button class="btn" onclick="doRest()">🔥 休整（恢复 HP 与技能次数）</button>`;
    h += `<button class="btn" onclick="showRumor()">👂 听听传闻</button>`;
  }
  h += node.edges.map(e =>
    `<button class="btn primary" onclick="gotoNode('${e.to}')">${e.label} →</button>`).join("");
  return h;
}
function showRumor() { toast("传闻：" + PACK.nodes["N1-1"].rumor); }
function doRest() {
  PACK.player.hp = PACK.player.maxhp;
  PACK.companions.forEach(c => c.hp = c.maxhp);
  addLog(`<b class="heal">休整</b>：HP 与技能次数全部恢复（休整态）。`);
  emit("rest", {});
  toast("休整完成：全队伍恢复");
  renderStatusBand();
}

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
    spec, round: 1, busy: false, over: false, fled: false,
    moved: false, bonusUsed: false,
    enemies: Array.from({ length: spec.count }, (_, i) => ({
      name: spec.name + (spec.count > 1 ? "·" + "甲乙"[i] : ""), hp: spec.hp, ac: spec.ac, atk: spec.atk, dmg: spec.dmg
    })),
    skillUses: {}
  };
  // 横屏网格占位坐标
  runtime.battle.pos = { allies: [[2, 4]], enemies: spec.count === 1 ? [[3, 1]] : [[2, 1], [4, 1]] };
  addLog(`<b class="hurt">遭遇战开始：${node.title}</b>（先攻：d20+敏，玩家先手）`);
  emit("battle.start", { id: node.encounter.id, enemy: spec.name });
  if (!localStorage.getItem("proto_tut_battle")) setTimeout(() => showCoach(TUT_BATTLE, "proto_tut_battle"), 400);
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
  let h = `<div class="check-hint">动作 + 附赠 + 移动　|　手势：拖动=移动 · 轨迹=施法 · 双击=结束回合 · 捏合=缩放</div>`;
  PACK.player.skills.forEach((s, i) => {
    const uses = s.uses ? (b.skillUses[s.id] || 0) : 0;
    const left = s.uses ? s.uses - uses : Infinity;
    h += `<button class="btn" ${left <= 0 ? "disabled" : ""} onclick="attack(${i})">⚔️ ${s.name}
      <span class="badge">${s.dmg}${s.uses ? " · 余 " + (left) : ""}</span></button>`;
  });
  h += battleItemButtons();
  h += `<button class="btn center" onclick="endTurn()">⏭ 结束回合（双击战场同效）</button>`;
  return h;
}
function battleItemButtons() {
  const b = runtime.battle;
  const usable = [...new Set(Board.inv)].filter(id => PACK.items[id].use);
  if (!usable.length) return "";
  return usable.map(id => {
    const it = PACK.items[id];
    return `<button class="btn" ${b && b.bonusUsed ? "disabled" : ""} onclick="useItemInBattle('${id}')">🧪 ${it.name}
      <span class="badge">附赠 · ${it.use.heal || ""}${b && b.bonusUsed ? " · 本回合已用附赠" : ""}</span></button>`;
  }).join("");
}
function useItemInBattle(id) {
  const b = runtime.battle, it = PACK.items[id];
  if (!it.use) return;
  if (b) { if (b.bonusUsed || b.busy || b.over) return; b.bonusUsed = true; }
  const heal = dmgRoll(it.use.heal);
  PACK.player.hp = Math.min(PACK.player.maxhp, PACK.player.hp + heal);
  if (it.use.consume) Board.inv.splice(Board.inv.indexOf(id), 1);
  addLog(`<b class="heal">使用「${it.name}」</b>（附赠动作）：恢复 <b class="heal">${heal}</b> HP → ${PACK.player.hp}/${PACK.player.maxhp}`);
  emit("item.use", { id, heal });
  renderStatusBand(); renderEncounter();
}
function endTurn() {
  const b = runtime.battle;
  if (!b || b.busy || b.over) return;
  addLog(`<b>你结束了回合</b>。`);
  b.busy = true; renderEncounter();
  setTimeout(enemyTurn, 600);
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
  b.round++; b.busy = false; b.moved = false; b.bonusUsed = false;
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
      <button id="enc-menu" onclick="openEncMenu()" title="单局菜单" style="background:none;border:1px solid var(--line);color:var(--dim);border-radius:4px;padding:2px 8px;margin-left:8px">☰</button>
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
  attachGestures();
}
function lsActionsHTML(node) {
  if (runtime.phase === "battle" && runtime.battle) {
    if (runtime.battle.over) return `<button class="btn primary act" onclick="winBattle()">结算 →</button>`;
    if (runtime.battle.busy) return `<div class="check-hint">敌方行动中…</div>`;
    return PACK.player.skills.map((s, i) => {
      const left = s.uses ? s.uses - (runtime.battle.skillUses[s.id] || 0) : Infinity;
      return `<button class="btn act" ${left <= 0 ? "disabled" : ""} onclick="attack(${i})">${s.name}<br><span style="font-size:10px;color:var(--dim)">${s.dmg}${s.uses ? " ·余" + left : ""}</span></button>`;
    }).join("") + battleItemButtons() + `<button class="btn act" onclick="endTurn()">结束回合</button>`;
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
  if (node.type === "hub") h += `<button class="btn act" onclick="openShop()">🛒 商店</button><button class="btn act" onclick="doRest()">🔥 休整</button><button class="btn act" onclick="showRumor()">👂 传闻</button>`;
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
    cells += `<div class="cell ${cls}" data-x="${x}" data-y="${y}">${label}${cls === "" ? `<span class="sub">${x},${y}</span>` : ""}</div>`;
  }
  return `<div id="grid-map" style="transform:scale(${runtime.zoom || 1})">${cells}</div>
    <div style="position:absolute;bottom:8px;font-size:10px;color:var(--dim)">战术格 8×5 · 拖动=移动 · 拖向敌人=施法 · 双击=结束回合 · 捏合=缩放</div>`;
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
  const canLevel = Board.level < levelTarget();
  host.innerHTML = `
  <div class="screen" id="settle-screen">
    <h2>结 算</h2>
    <div class="settle-lines">
      ${lines.map((l, i) => `<div class="settle-line" style="animation-delay:${i * 0.18}s">
        <span class="k">${l.k}</span><span class="v ${l.bad ? "bad" : ""}">${l.v}</span></div>`).join("")}
      <div class="settle-line" style="animation-delay:${lines.length * 0.18}s">
        <span class="k">新增卷轴条目</span><span class="v">${Events.length} 条事件流</span></div>
    </div>
    ${canLevel ? `
    <div class="card" style="width:100%;max-width:300px;border-color:var(--gold)">
      <div class="t">⬆ 成长加点（经验 ${Board.xp}，可升至 Lv${Board.level + 1}）</div>
      <div class="d" style="margin-bottom:6px">选择一项属性 +1（HP 上限 +2）：</div>
      <div style="display:flex;gap:6px">
        ${["力", "敏", "智"].map(a => `<button class="btn center" style="margin:0" onclick="doLevelUp('${a}')">${a} ${PACK.player.attrs[a]}→${PACK.player.attrs[a] + 1}</button>`).join("")}
      </div>
    </div>` : ""}
    <div style="width:100%;max-width:300px">
      <button class="btn primary center" onclick="runtime.consoleReturn='settle';go('history')">查看新增卷轴条目（复盘）</button>
      <button class="btn center" onclick="go('home')">回主屏（营地）</button>
    </div>
  </div>`;
}

/* ============================================================
 * 手势层（framework/12）：拖动=移动 · 轨迹=施法 · 双击=结束回合
 * 捏合=缩放 · 长按=详情 · 横滑=切 Tab。按钮永远有等价路径。
 * ============================================================ */
const gest = { down: null, line: null, pointers: new Map(), pinchD0: 0, zoom0: 1, lastTap: 0, pressTimer: null };

function svgLine() {
  let svg = $("#gesture-svg");
  if (!svg) {
    device.insertAdjacentHTML("beforeend",
      `<svg id="gesture-svg" style="position:absolute;inset:0;pointer-events:none;z-index:60"><line stroke="var(--gold)" stroke-width="2" stroke-dasharray="6 4"/></svg>`);
    svg = $("#gesture-svg");
  }
  return svg.querySelector("line");
}
function devicePos(e) {
  const r = device.getBoundingClientRect();
  return { x: e.clientX - r.left, y: e.clientY - r.top };
}
function drawPath(a, b) {
  const l = svgLine();
  l.setAttribute("x1", a.x); l.setAttribute("y1", a.y);
  l.setAttribute("x2", b.x); l.setAttribute("y2", b.y);
  l.style.display = "block";
}
function hidePath() { const l = svgLine(); l.style.display = "none"; }

function attachGestures() {
  if (runtime.screen !== "encounter") return;
  const field = $("#ls-center") || $("#vp-battle");
  // —— 竖屏：操作台横滑切 Tab ——
  const console_ = $("#vp-console");
  if (console_) {
    let sx = 0, sy = 0;
    console_.addEventListener("pointerdown", e => { sx = e.clientX; sy = e.clientY; });
    console_.addEventListener("pointerup", e => {
      const dx = e.clientX - sx, dy = e.clientY - sy;
      if (Math.abs(dx) > 60 && Math.abs(dy) < 30) {
        const tabs = ["action", "dice", "log", "char"];
        let i = tabs.indexOf(runtime.tab) + (dx < 0 ? 1 : -1);
        runtime.tab = tabs[(i + tabs.length) % tabs.length];
        renderEncounter();
      }
    });
  }
  if (!field || !runtime.battle || runtime.battle.over) return;

  // —— 战场：单位拖动（移动/施法轨迹）、双击结束回合、捏合缩放、长按详情 ——
  field.style.touchAction = "none";
  field.addEventListener("pointerdown", e => {
    gest.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (gest.pointers.size === 2) {                      // 捏合开始
      const [p, q] = [...gest.pointers.values()];
      gest.pinchD0 = Math.hypot(p.x - q.x, p.y - q.y);
      gest.zoom0 = runtime.zoom || 1;
      gest.down = null; hidePath();
      return;
    }
    const unitEl = e.target.closest(".unit.active, .cell.ally");
    if (unitEl) {
      gest.down = { kind: "unit", el: unitEl, x0: e.clientX, y0: e.clientY, moved: false };
    } else if (e.target.closest(".unit")) {
      // 长按敌方/任意单位 = 详情卡（12 §2）
      const u = e.target.closest(".unit");
      gest.pressTimer = setTimeout(() => showUnitInfo(u), 400);
    } else {
      // 空白处双击 = 结束回合
      const now = Date.now();
      if (now - gest.lastTap < 280) { gest.lastTap = 0; endTurn(); }
      else gest.lastTap = now;
    }
  });
  field.addEventListener("pointermove", e => {
    if (gest.pointers.has(e.pointerId)) gest.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (gest.pointers.size === 2 && gest.pinchD0) {      // 捏合缩放（12 §1：间距变化>20%）
      const [p, q] = [...gest.pointers.values()];
      const d = Math.hypot(p.x - q.x, p.y - q.y);
      runtime.zoom = Math.max(0.7, Math.min(1.6, gest.zoom0 * d / gest.pinchD0));
      const m = $("#grid-map") || document.querySelector("#vp-battle .lane");
      if (m) m.style.transform = `scale(${runtime.zoom})`;
      return;
    }
    if (!gest.down) return;
    clearTimeout(gest.pressTimer);
    if (Math.hypot(e.clientX - gest.down.x0, e.clientY - gest.down.y0) > 10) {
      gest.down.moved = true;
      drawPath(devicePos({ clientX: gest.down.x0, clientY: gest.down.y0 }), devicePos(e));
    }
  });
  field.addEventListener("pointerup", e => {
    gest.pointers.delete(e.pointerId);
    if (gest.pointers.size < 2) gest.pinchD0 = 0;
    clearTimeout(gest.pressTimer);
    hidePath();
    const b = runtime.battle, g = gest.down; gest.down = null;
    if (!g || !g.moved || !b || b.busy || b.over) return;
    const drop = document.elementFromPoint(e.clientX, e.clientY);
    const enemyEl = drop && drop.closest(".unit.enemy, .cell.enemy");
    if (enemyEl) {                                       // 轨迹终点=敌 → 施法
      const idx = PACK.player.skills.findIndex(s => s.id === "inkbolt");
      const left = PACK.player.skills[idx].uses - (b.skillUses.inkbolt || 0);
      if (left > 0) attack(idx); else toast("墨术飞矢次数已尽");
      return;
    }
    if (b.moved) { toast("本回合移动段已用"); return; }
    const cell = drop && drop.closest(".cell");
    if (cell && !cell.classList.contains("ally")) {      // 空格 → 移动（≤2 格）
      const [ax, ay] = b.pos.allies[0];
      const nx = +cell.dataset.x, ny = +cell.dataset.y;
      if (Math.abs(nx - ax) + Math.abs(ny - ay) <= 2) {
        b.pos.allies[0] = [nx, ny]; b.moved = true;
        addLog(`<b>移动</b>：(${ax},${ay}) → (${nx},${ny})（移动段）`);
        emit("battle.move", { from: [ax, ay], to: [nx, ny] });
        renderEncounter();
      } else toast("超出移动范围（≤2 格）");
      return;
    }
    if (drop && drop.closest("#vp-battle")) {            // 竖屏：纵向拖动=调整站位
      b.moved = true;
      addLog(`<b>移动</b>：${e.clientY < g.y0 ? "前压" : "后撤"}一步（移动段）`);
      emit("battle.move", { stance: e.clientY < g.y0 ? "forward" : "back" });
      renderEncounter();
    }
  });
  field.addEventListener("pointercancel", () => { gest.pointers.clear(); gest.pinchD0 = 0; gest.down = null; hidePath(); clearTimeout(gest.pressTimer); });
}
function showUnitInfo(u) {
  const b = runtime.battle;
  const isEnemy = u.classList.contains("enemy");
  const info = isEnemy
    ? `${b.spec.name}　HP ${b.spec.hp} · AC ${b.spec.ac} · 伤害 ${b.spec.dmg}`
    : `${PACK.player.name}　HP ${PACK.player.hp}/${PACK.player.maxhp} · AC ${PACK.player.ac}　力${PACK.player.attrs.力}/敏${PACK.player.attrs.敏}/智${PACK.player.attrs.智}`;
  host.insertAdjacentHTML("beforeend",
    `<div class="dim-mask" onclick="closeSheet()"></div>
     <div class="sheet"><button class="close" onclick="closeSheet()">✕</button>
     <div class="page-head" style="border:none;padding:0 0 8px"><h3>${isEnemy ? "敌方单位" : "己方单位"}</h3></div>
     <div class="card"><div class="d">${info}</div></div></div>`);
}

/* ---------- ☰ 单局菜单（09 文档 §7） ---------- */
function openEncMenu() {
  host.insertAdjacentHTML("beforeend",
    `<div class="dim-mask" onclick="closeSheet()"></div>
     <div class="sheet"><button class="close" onclick="closeSheet()">✕</button>
     <div class="page-head" style="border:none;padding:0 0 8px"><h3>暂停</h3></div>
     <button class="btn" onclick="closeSheet()">继续</button>
     <button class="btn" id="btn-save-home" onclick="saveAndHome(this)">保存并回主屏</button>
     <div class="check-hint" style="padding:0 4px">遭遇进行中不存档：回到主屏后，本遭遇将从头开始（已写板的世界状态不受影响）。</div>
     <button class="btn" onclick="closeSheet();showCoach(HELP_PAGES,null)">手势帮助</button>
     </div>`);
}
function saveAndHome(btn) {
  if (!btn.dataset.armed) { btn.dataset.armed = "1"; btn.textContent = "确认：放弃本遭遇进度并回主屏"; return; }
  closeSheet();
  runtime.battle = null; runtime.phase = "explore";
  go("home");
  toast("已回到主屏——本遭遇将从头开始（07 文档 §4.2）");
}

/* ---------- 首进教程与帮助页（12 文档 §4） ---------- */
const TUT_HOME = [
  { t: "欢迎来到抄本纪元", d: "三个手势就够开局：<br><b>点按</b>＝选择与确认<br><b>长按</b>＝查看详情 / 跳过演出<br><b>横滑</b>＝切换操作台页签" },
  { t: "命骰", d: "关键判定会全屏演出——<b>长按可跳过</b>，结果永远写入日志与历史卷轴，跳过不丢信息。" },
  { t: "双形态", d: "进入战役时选择横屏空间或竖屏时间形态，整场锁定。顶部「形态对比」按钮是原型评审专用，正式版没有。" }
];
const TUT_BATTLE = [
  { t: "战斗手势", d: "<b>拖动己方单位</b>＝移动（移动段）<br><b>从自己拖到敌人</b>＝释放墨术飞矢（轨迹即弹道）<br><b>双击战场</b>＝结束回合<br><b>双指捏合</b>＝缩放战场<br>——按钮永远可用，手势只是更快。" }
];
const HELP_PAGES = [
  { t: "手势图鉴（1/2）", d: "<b>点按</b>＝选择/确认　<b>双击</b>＝结束回合/快掷<br><b>长按</b>＝详情/跳过演出　<b>横滑</b>＝切页签" },
  { t: "手势图鉴（2/2）", d: "<b>拖动</b>＝移动单位/滚动　<b>拖动轨迹</b>＝施法<br><b>双指捏合</b>＝缩放　<b>双指拖动</b>＝平移镜头<br>——完整规范见 framework/12-手势与交互规范.md" }
];
function showCoach(pages, flagKey) {
  let i = 0;
  const render = () => {
    document.querySelectorAll(".coach").forEach(e => e.remove());
    const p = pages[i];
    device.insertAdjacentHTML("beforeend",
      `<div class="coach"><div class="coach-card">
        <div class="t" style="color:var(--gold);font-size:16px;margin-bottom:8px">${p.t}</div>
        <div class="d" style="font-size:13px;line-height:2;color:var(--text)">${p.d}</div>
        <div style="display:flex;gap:8px;margin-top:14px">
          <button class="btn center" id="coach-skip" style="margin:0">跳过</button>
          <button class="btn primary center" id="coach-next" style="margin:0">${i < pages.length - 1 ? "下一条" : "知道了"}</button>
        </div></div></div>`);
    $("#coach-skip").onclick = done;
    $("#coach-next").onclick = () => { i++; i < pages.length ? render() : done(); };
  };
  const done = () => {
    document.querySelectorAll(".coach").forEach(e => e.remove());
    if (flagKey) localStorage.setItem(flagKey, "1");
  };
  render();
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
if (!localStorage.getItem("proto_tut_main")) showCoach(TUT_HOME, "proto_tut_main");
