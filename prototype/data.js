// 数据切片：docs/story/campaign01 的序章 + 幕一（与内容包数据同构的简化内嵌版）
// 规则参数：framework/11-轻规则包-v1（DC 8/12/16，三段式行动经济）

const PACK = {
  id: "campaign01",
  name: "烬港残页",
  // 整备配置（09 §9.1 / tech02 §2.4）：限制由配置文件决定，框架只执行
  loadout: { enabled: true, item_slots: 2, skill_slots: 2, respec: false,
    // 系统预设（09 §9.3）：只是槽位选择记录，不含数值加成
    presets: [
      { id:"assault", name:"强攻", skills:["slash","inkbolt"],    items:["heal_potion"] },
      { id:"guard",   name:"稳守", skills:["slash","inkshield"],  items:["heal_potion"] },
      { id:"balance", name:"均衡", skills:["inkbolt","inkshield"],items:["heal_potion"] }
    ] },
  // 托管策略（09 §9.3）：代掷骰、技能优先级、道具阈值、节拍下限
  auto: { potion_below: 0.5, min_interval_ms: 800, speeds: [1, 2] },
  acts: [
    { id: "SL-0", title: "序章 · 潮醒", mode: "forced_time" },
    { id: "SL-1", title: "幕一 · 褪色的街", mode: "choice" }
  ],
  // 房间序列（竖屏推进条显示用）
  rooms: ["N0-1","N0-2","N0-3","N0-4","N1-1","N1-2","N1-3","N1-4","N1-7","N1-8"],
  nodes: {
    "N0-1": { type:"scene", title:"潮醒",
      text:"潮声。盐的味道。\n你在烬港的滩涂上醒来，怀里没有抄本——每个新生儿都该领到的、写着名字与死期的抄本。\n你什么都没有。你是白页者。",
      edges:[{ label:"撑起身体，望向港口", to:"N0-2" }] },
    "N0-2": { type:"check", title:"消失的码头名",
      text:"不远处的木牌上，「雾码头」三个字正在……褪色。笔画像被海水冲散的墨。\n——集中精神。这是你第一次向织卷掷出命骰。",
      check:{ skill:"感知", attr:"智", dc:8, key:true, keyReason:"首次命骰：改写现实的仪式" },
      success:"N0-3a", failure:"N0-3b" },
    "N0-3a": { type:"scene", title:"你看见墨迹正在褪",
      text:"命骰落定的一瞬，织卷为你留出了空白。\n你看得清清楚楚：墨迹从木牌上剥离、升起、消散。\n这不是你的幻觉。这座城市正在被撤销。",
      onEnter:[{ flag:"seen_fading", name:"眼见为实" }],
      edges:[{ label:"记下这一幕", to:"N0-4" }] },
    "N0-3b": { type:"scene", title:"路人惊恐的讲述",
      text:"你没看清变化的瞬间——但身旁老渔民的烟斗掉在了地上。\n「又一个……又一个地名没了。」他喃喃道，「先是地名，然后会是什么？」",
      onEnter:[{ xp:50 }],
      edges:[{ label:"扶起老人", to:"N0-4" }] },
    "N0-4": { type:"scene", title:"三方注视",
      text:"你起身时察觉到了：广场上，三道目光落在你身上。\n灰衣的修士。檐角的黑羽。拍卖行的掮客。\n他们都知道你怀里没有抄本——也都知道你手里有什么。",
      edges:[{ label:"走进烬港（幕一 · 褪色的街）", to:"N1-1" }] },

    "N1-1": { type:"hub", title:"自由市广场",
      text:"烬港最后的繁华都挤在这个广场上了。半座城的居民已被「撤销」，剩下的人守着一半的记忆生活。\n杂货铺的老板娘冲你招手——白页者的名声比你的脚步快。",
      shop:[{ item:"half_tide_table", price:30 }, { item:"heal_potion", price:15 }],
      rumor:"「听说了吗？昨晚又有一条街不见了。誊写庭的人把自己锁在档案馆里。」",
      edges:[{ label:"前往褪色现场调查", to:"N1-2" }] },
    "N1-2": { type:"check", title:"褪色现场调查",
      text:"这条街的边缘像被橡皮擦过的铅笔字。你蹲下身，寻找褪墨蔓延的规律。\n砖缝里残留着极细的金色粉末——这不在任何传闻里。",
      check:{ skill:"调查", attr:"智", dc:12, key:false },
      success:"N1-3", failure:"N1-2b" },
    "N1-2b": { type:"battle", title:"误入封锁巷",
      text:"追查金粉的走向时你拐错了弯——面前是誊写庭封锁线，和一队不由分说的墨魈。\n（调查失败的代价：惊动了褪墨中诞生的扭曲文本。）",
      encounter:{ id:"N1-2b", enemy:"inkimp", difficulty:"easy" },
      onWin:{ clock:1, note:"迟到：多花 1 格时间钟" },
      edges:[{ label:"突围，赶往褪色现场", to:"N1-3" }] },
    "N1-3": { type:"scene", title:"见证撤销",
      text:"你赶到时，那条街正在消失。\n不是坍塌，不是燃烧——是「撤销」。房屋、石板路、门牌，连同路人的目光一起，像被从书页上轻轻抹去的错字。\n有人在你身边跪下，哭着喊一个名字——然后连哭声也愣住了：他忘了自己在喊谁。",
      onEnter:[{ clock:1 }, { flag:"witnessed_revocation", name:"见证撤销" }],
      edges:[{ label:"接受灰衣修士的邀请", to:"N1-4" }] },
    "N1-4": { type:"dialog", title:"誊写庭接触",
      text:"「白页者。」灰衣修士的声音像翻动的纸页，「褪墨是卷轴的溃烂，而你是唯一完好的空白。誊写庭希望……借用你。」",
      options:[
        { label:"「借用？还是利用？」", rep:{ scriptorium:1 }, reply:"修士微微躬身：「愿称其为：互利的修复。」" },
        { label:"「修复一座城，要付出什么？」", rep:{ scriptorium:1 }, reply:"「墨。」他说，「很多墨。以及——代价。」他避开了你的目光。" }
      ],
      edges:[{ label:"离开（檐角有黑羽掠过）", to:"N1-5" }] },
    "N1-5": { type:"dialog", title:"断墨会接触",
      text:"黑羽落在你肩头，展开是一行字：「被写下的命，值得过吗？——断墨会，午夜，旧灯塔。」\n字迹在读完的瞬间自行烧尽。",
      options:[
        { label:"收起灰烬（记下邀约）", rep:{ uninked:1 }, reply:"灰烬在你掌心拼出最后一笔：一个向上的箭头。自由的方向。" },
        { label:"追问墨雨的真相", rep:{ uninked:1 }, reply:"风里有个声音笑了：「褪墨不是天灾，白页者。是有人先撕了第一页。」" }
      ],
      edges:[{ label:"离开（掮客已等候多时）", to:"N1-6" }] },
    "N1-6": { type:"dialog", title:"拾遗行会接触",
      text:"「生意人不说废话。」掮客递来烫金请柬，「褪墨卷走了半座城，也卷出了无数残篇。残篇值钱。而会走路的空白——更值钱。」",
      options:[
        { label:"接过请柬", rep:{ salvage:1 }, reply:"「明智。拍卖行随时为白页者留座。」" },
        { label:"「城都要没了，还谈生意？」", rep:{ salvage:1 }, reply:"掮客笑了：「城没了，账还在。这正是我们行会的规矩。」" }
      ],
      edges:[{ label:"夜幕降临——", to:"N1-7" }] },
    "N1-7": { type:"battle", title:"午夜墨雨",
      text:"午夜，墨色的雨。\n雨点落地成字，字扭曲着立起——墨魈，褪墨中诞生的扭曲文本，朝着广场上唯一的「空白」涌来。\n（教学 Boss 战）",
      encounter:{ id:"N1-7", enemy:"inkfiend", difficulty:"easy", boss:true },
      onWin:{ xp:250, item:"ink_core" },
      edges:[{ label:"雨停之后", to:"N1-8" }] },
    "N1-8": { type:"branch", title:"三份邀约",
      text:"天亮前，三份邀约摆在你面前：誊写庭的委托、断墨会的黑羽、拾遗行会的契约。\n——切片到此为止。完整战役的幕二「三支笔」将由此分岔。",
      edges:[{ label:"（原型切片完）查看结算", to:"END" }] }
  },

  items: {
    half_tide_table:{ name:"半页潮汐表", roles:["branch_key"], desc:"雾码头残缺的潮汐记录。边缘有行小字：『沉书阁的密道，随退潮显现。』（开启幕二打捞密道）" },
    heal_potion:{ name:"补给药水", roles:["stat"], desc:"行会配给的墨绿色药剂。\n【使用 · 附赠动作】恢复 1d4+2 点 HP，用后消耗。", use:{ timing:"bonus_action", heal:"1d4+2", consume:true } },
    ink_core:{ name:"墨核", roles:["stat"], desc:"墨魈消散后留下的凝块，仍微微搏动。可用于强化武器。" },
    fatedie:{ name:"命骰", roles:["codex"], quest:true, desc:"织命者遗留的二十面骨骰。只有白页者掷得出声音。" }
  },
  codexSeries: [
    { id:"weaver_fragments", name:"织命者残简", total:4, got:0, reward:"揭示褪墨真相的隐藏剧情线" },
    { id:"revoked_registry", name:"被撤销者名录", total:8, got:0, reward:"解锁「追忆」战役（强制竖屏）" },
    { id:"fatedie_study",   name:"命骰考",       total:6, got:1, reward:"骰子外观" },
    { id:"ashenport_local", name:"烬港风物志",   total:10, got:2, reward:"烬港声望与商店折扣" }
  ],

  // 轻规则包 v1 切片：敌人表
  enemies: {
    inkimp:  { name:"墨魈幼体", hp:8,  ac:10, atk:2, dmg:"1d4",   count:2 },
    inkfiend:{ name:"墨魈",     hp:16, ac:11, atk:3, dmg:"1d4+1", count:1, boss:true }
  },
  player: { name:"你（白页者）", hp:14, maxhp:14, ac:11,
    attrs:{ 力:2, 敏:1, 智:0 }, prof:["调查","运动"],
    skills:[
      { id:"slash",  name:"佩剑挥砍", kind:"attack", attr:"力", dmg:"1d6+2" },
      { id:"inkbolt",name:"墨术飞矢", kind:"attack", attr:"智", dmg:"1d6", uses:2, note:"每场 2 次" },
      { id:"inkshield",name:"墨盾格挡", kind:"utility", attr:"智", dmg:"AC+2", uses:1, note:"本场 AC+2" }
    ] },
  companions: [
    { id:"kelan", name:"珂兰", hp:10, maxhp:10, ac:11, attr:1, bond:20,
      note:"被写下的过去：誊写庭抄经役",
      skill:{ id:"kelan_bolt", name:"墨矢", dmg:"1d6+1" } },
    { id:"laofei", name:"老费", hp:12, maxhp:12, ac:12, attr:1, bond:10,
      note:"想改写的一页：被撤销的女儿",
      skill:{ id:"laofei_hook", name:"船钩", dmg:"1d6+1" } }
  ],
  eventsList: [
    { id:"dock_tales",   name:"码头异闻",   obj:"完成码头检定", state:"active" },
    { id:"fading_street",name:"消逝之街",   obj:"抵达褪色现场", state:"active" },
    { id:"three_callings",name:"三方拜帖",  obj:"接触三方势力", state:"active" },
    { id:"ink_rain_raid",name:"墨雨夜袭",   obj:"时间钟到 2 格触发", state:"pending" }
  ]
};
