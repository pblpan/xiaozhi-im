/**
 * 应用中心（客户端「工作台」的注册表）
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么要有这一层
 * ─────────────────────────────────────────────────────────────
 * 钉钉 / 企业微信 / 飞书的共同点：客户端有一个「工作台」，里面既有官方应用
 * （考勤、审批、公告、日志），也有企业自建应用。本项目此前只有后者的一半
 * ——动态模块（app_modules，管理台拼 JSON 下发）。考勤这样的功能没法用 JSON 拼，
 * 它需要真正的数据表、统计口径和审批流。
 *
 * 所以这里补上前者：**内置应用**清单。两者在同一个列表里下发、在同一个
 * 「工作台」里渲染，用户看到的是"一个应用中心"，而不是"两个功能各管一摊"。
 *
 *   内置应用  = 随客户端安装包发布的、功能完备的一等公民（考勤是第一个）
 *   自定义应用 = 管理台用 JSON 拼出来、服务端下发的动态模块
 *
 * ─────────────────────────────────────────────────────────────
 * 两条刻意的设计约束
 * ─────────────────────────────────────────────────────────────
 * 1. **内置应用不接受"对谁显示"的开关**。入口可见性只由**业务状态**决定
 *    （没开工作模式就没有考勤、考勤关了就没有打卡），由 listFor() 算出来。
 *    留一个"按人/按角色显示"的开关必然会配出"入口在、点进去报错"的状态，
 *    而管理员根本不知道该去关哪个开关。
 *
 *    ⚠️ 与「整应用停用」的区别（v0.21.0 起由 appoverrides.js 提供）：
 *      · 业务状态（need）  = "这个功能此刻对这个人成不成立"，照样**不可覆盖**；
 *      · 整应用停用        = "这个功能这台服务器上先别用了"，是全局的，
 *                            而且**隐藏入口 + 后端每条接口都拦**（appguard.js），
 *                            所以不会造出"入口在、点进去报错"的状态。
 *    两者语义不重叠：一个是能不能用，一个是用不用。
 *
 * 2. **客户端不认识的应用 id 直接忽略，不报错**。这一条是给未来留的：
 *    服务端先上线一个新应用、客户端还是旧版本，旧客户端只会少一个图标，
 *    不会白屏也不会弹错。新增应用永远不需要"先升级客户端"。
 *
 * 客户端侧的落地见 client/lib/core/apps.dart（id → 页面构造器），
 * 两边都以本文件的 id 为准，id 一旦发布**不可改名**（改名等于老客户端丢入口）。
 */

/**
 * 分组：**出厂定义 + 可配覆盖**。
 *
 * work   工作 —— 与"上班"直接相关（考勤、申请、组织）
 * custom 自定义 —— 动态模块（管理台拼的）
 *
 * 🔴 v0.22.0 起 GROUPS 不再是简单的字符串数组，而是"出厂默认"。
 *    原因：钉钉 / 企业微信 / 飞书的工作台分组名是**企业自己改的**
 *    （"办公协同""人事管理""门店作业"……）。写死在最底下的源码里，
 *    管理员就永远改不了组名，只能改应用名 —— 那工作台看着就像个半成品。
 *
 * 覆盖存在 app_groups 表（见 appgroups.js），这里只是**出厂值**：
 *    · 改名（label）      → 组头显示什么字
 *    · 调序（sort）       → 组与组谁在上面
 *    · 隐藏（hidden）     → 整个组收起来（组里最后一个应用被移走前别用）
 *    · 新增自定义组       → 管理台加（加完把某些应用挪进去）
 *
 * ⚠️ 分组 key 一旦有应用在用就**别删**：删了那些应用会集体消失（它们找不到组）。
 */
const DEFAULT_GROUPS = [
  { key: 'work', label: '工作', sort: 10 },
  { key: 'custom', label: '自定义应用', sort: 20 },
];

/** 出厂分组 key（兼容旧引用；不要直接当"当前分组"用，当前分组要问 appgroups.list()） */
const GROUPS = DEFAULT_GROUPS.map((g) => g.key);

const BUILTIN_APPS = [
  {
    id: 'attendance',
    title: '考勤打卡',
    icon: 'schedule',
    group: 'work',
    // 工作台图标底色（出厂品牌色）。钉钉/企微/飞书的应用图标**不是**一个模子
    // 里出来的灰方块，是每个应用自己的颜色 —— 一排同色图标员工扫一眼分不出
    // 哪个是打卡、哪个是盘点。管理台可在应用抽屉里覆盖（见 appoverrides 的 color）。
    color: '#2B6FE0',
    desc: '上下班打卡、我的考勤与统计',
    // 打卡是"员工对组织"的行为：必须有组织归属，且管理员账号不参与考勤
    // （管理员是系统角色，不在员工名册里；让管理员也打卡只会污染统计）
    need: { workMode: true, attendance: true, orgMember: true, role: 'employee' },
  },
  {
    id: 'my_requests',
    title: '我的申请',
    icon: 'task',
    group: 'work',
    color: '#12A594',
    desc: '请假、补卡、外出、加班的申请与进度',
    need: { workMode: true, attendance: true, orgMember: true, role: 'employee' },
  },
  {
    id: 'work_org',
    title: '组织通讯录',
    icon: 'people',
    group: 'work',
    color: '#475569',
    desc: '按部门查看同事、工号与岗位',
    // 管理员也能看（他要看全员），所以不限定 role
    need: { workMode: true, orgMember: true },
  },
  {
    id: 'att_admin',
    title: '考勤记录',
    icon: 'assessment',
    group: 'work',
    color: '#0E7490',
    desc: '查看今日出勤与缺卡，可代为补卡',
    // 管理员的考勤入口 —— **不是"我自己打卡"，而是"看别人打了没"**。
    //
    // 为什么和 attendance 分成两个应用而不是同一个页面两种形态：
    //   员工要的是"我这四张卡打了没"，管理员要的是"今天谁没打、我给他补上"。
    //   两者数据源不同（一个是自己的判定，一个是全员看板）、操作也不同
    //   （一个是打卡，一个是改别人的记录）。塞进一个 id 就必须在客户端按
    //   角色分叉渲染，而"我到底是不是管理员"客户端本来就不该自己判 ——
    //   可见性一律由服务端算（本文件开头的设计约束 1）。
    //
    // 同样不设开关，只认业务状态：没开工作模式 / 考勤被停用 / 还没建组织，
    // 这个入口就跟着消失，不会出现"点进去报错"的状态。
    need: { workMode: true, attendance: true, orgMember: true, adminOnly: true },
  },
  {
    id: 'stocktake',
    // 🔴 显示名是「扫码枪」，不是「盘点」——「盘点」这个名字留给真正的盘点模块
    //   （盘点位 / 库位货架位 / 初盘-复盘-抽盘三遍制 / 抽盘授权）。
    //   这个模块的本职只是"把条码快速扫成一笔账"：扫码 → 明细 → 导出 → 盈亏表。
    //   id 'stocktake' 发布后不可改名（改名等于老客户端丢入口），所以名字与 id
    //   在这里是故意不一致的，别按 id 去猜标题。
    title: '扫码枪',
    // 图标名必须落在 appmodules.js 的 ICONS 白名单（以及客户端
    // widgets/module_renderer.dart 的 kModuleIcons）里，否则会退化成通用图标。
    // 两处都有测试钉着（server/test/apps_icon_test.js）。
    icon: 'barcode',
    group: 'work',
    color: '#F0821E',
    desc: '扫码采集，离线可用，导出文档/表格 + 生成盈亏表',

    // 为什么只要求工作模式，不像考勤那样还要求 orgMember：
    //   盘点是**门店现场作业**，跟"这个人有没有被录进组织名册"是两回事 ——
    //   老板自己、临时来帮忙的人都要能盘。加 orgMember 会让"明明装了却看不到
    //   入口"这种最难查的问题再次出现（历史上在考勤上踩过：账号没录组织 →
    //   入口消失，现象是"功能没做"，实际是数据没录）。
    //   入口和权限必须是同一套判据：这里不需要额外权限，就别额外设限。
    need: { workMode: true },
  },
  {
    id: 'inventory',
    // 「盘点」——之前这个显示名被「扫码枪」占着（它的 id 也叫 stocktake），
    // v0.14.7 已经把名字腾出来了，这里才是真正的盘点：
    //   盘点位 / 库位货架位 / 初盘-复盘-抽盘三遍制 / 失误笔数。
    // 和 stocktake（扫码枪）的分工见 docs/盘点复刻与开放接口方案-v1.md §3.0。
    title: '盘点',
    icon: 'inventory',
    group: 'work',
    // 砖红不是"好看"，是**语义**：盘点最终看的是差异与盈亏，红色一进来就有
    // "这里要出数了"的暗示。和旁边的扫码枪（橙）、简易盘点（琥珀）也拉得开。
    color: '#C0392B',
    desc: '按盘点位与货架位清点：初盘、复盘、抽盘，自动算差异与失误笔数',
    // 和扫码枪同样的道理（见上一条）：盘点是**门店现场作业**，
    // 跟"这个人有没有被录进组织名册"是两回事 —— 老板、临时帮忙的人都要能盘。
    // 加 orgMember 会造出"装了却看不到入口"这种最难查的问题。
    need: { workMode: true },
  },
  {
    id: 'simple_stocktake',
    // 「简易盘点」—— 龙哥 2026-09-25 提的另一条通道：**导入清单 → 一趟一趟盘 → 导出全量**。
    //
    // 🔴 它和上面「盘点」不是同一件事，别合并：
    //    盘点(inventory) 是**制度型**（点位/货架位/三遍互比/失误笔数），给要审计的场景；
    //    简易盘点 是**干活型**（导入这一轮要盘的明细 → 节点式一趟趟扫 → 数量相加 →
    //    导出一张全量单，没盘到的出 0 行），给"今天把这批货点清楚"的场景。
    //    方案见 docs/简易盘点通道方案-v1.md。
    // 放在「盘点」后面紧挨着：两个都叫盘点，挨着放员工才分得清哪个是哪个。
    //
    // ⚠️ **服务端先注册、客户端页面还没做**（客户端 0.18.0 才出）。
    //    这是故意的，也是"库房减货"那次的教训：先注册等于把"客户端发了但入口
    //    没出来"这条坑提前拆掉 —— 老客户端认不出这个 id 会直接隐藏，
    //    所以现在注册它**不会**让任何人看到一张点不开的卡片。
    title: '简易盘点',
    icon: 'list',
    group: 'work',
    color: '#A9761A',
    desc: '导入要盘的清单，一趟趟扫，最后导出全量（没盘到的记 0）',
    need: { workMode: true },
  },
  {
    // 🔴 2026-10-04 龙哥定：库房减货、补货**不再是独立工作台应用** ——
    //    功能都在「盘点」页右上角的快捷入口里（open-deduct / open-replenish），
    //    工作台不再单独发图标（历史上它们各自占一格，龙哥反馈"图标还在，要去掉"）。
    //    减货的服务端接口（/api/deduct/*）归到 inventory 名下（appguard.js）；
    //    电子秤码参数（scaleCodeLen）也挪到 inventory 名下（appoverrides.js）。
    id: 'price_tag',
    // 「价签打印」—— 上完架顺手把标签打出来贴上去。
    //
    // 🔴 它**不是单据**：不打单、不落库、不上报，打完就贴在货上了。
    //    盘点/减货/补货之所以要做，是因为有第二方要认那张单；
    //    价签没有第二方，存下来只能用来"重打"，为此单开一张表是给自己加麻烦。
    //
    // 🔴 为什么要**单独占一个工作台入口**：和"库房减货"那次同一个道理 ——
    //    那个第一版塞在盘点页 AppBar 的小图标里，龙哥的原话是
    //    "我没找到你说的功能在哪里"。打价签是每天上架时的一趟活，
    //    凭什么要点进别的页面再找。
    //
    // ⚠️ Android 才有真实能力（经典蓝牙 SPP）。桌面端进得去、界面也在，
    //    但一按打印就出一段明说不支持的提示 —— 藏掉它反而更难找。
    title: '价签打印',
    // 图标必须落在 appmodules.js 的 ICONS 白名单里（apps_icon_test.js 钉着），
    // 且要与补货的 local_shipping、减货的 shopping_cart 一眼分得开。
    icon: 'receipt_long',
    group: 'work',
    color: '#C2185B',
    desc: '扫商品码改售价，用蓝牙价签机打印（经典蓝牙，不绑型号）',
    // 和扫码枪/盘点同一条口径：**门店现场作业，不加 orgMember**。
    need: { workMode: true },
  },
  {
    id: 'training',
    // 🔴 显示名就叫「培训中心」，不要写成「培训」「学习」「商学院」——
    //   龙哥指定的名字，客户端列表里看到的就是这四个字。
    title: '培训中心',
    icon: 'school',
    group: 'work',
    color: '#8250DF',
    desc: '看课程视频、记学习进度、参加章节考试',
    // 和扫码枪/盘点同样的道理：**门店现场的人都要能学**，
    // 包括还没录进组织名册的临促、新来的店长。加 orgMember 会造出
    // "装了却看不到入口"这种最难查的问题（历史上在考勤上踩过）。
    // 培训也不分角色：管理员也要看（他要盯完成率）。
    need: { workMode: true },
  },
  {
    id: 'assistant',
    // #314 智能助手（2026-10-11）：接管"系统怎么用"的问答。
    // 所有人可见 —— 帮助是给所有人用的，**刻意不加 orgMember/workMode**：
    // 普通模式（亲友群/家用）的人也会问"怎么传文件"，拦掉就变成
    // "装了却看不到入口"这种最难查的问题（考勤/培训都踩过同一坑）。
    title: '智能助手',
    icon: 'smart_toy',
    group: 'work',
    color: '#0EA5E9',
    desc: '有使用问题直接问：内置帮助知识库 + 可选 AI 大模型作答',
    need: {},
  },
];

/**
 * 按当前服务器/用户状态过滤出可见应用。
 *
 * 传进来的是**已算好的状态**，本函数不查库 —— 这样它可以被测试直接喂各种组合
 * （"工作模式但没组织""有组织但管理员"…），不用先搭一套数据库。
 * 覆盖层同理：`overrides` 是一个普通对象（`{ [id]: {title,icon,sort,disabled,params} }`），
 * 由调用方从 appoverrides.map() 取来传进来，本文件不 require 那个模块
 * （否则 apps.js 就会依赖 db，纯函数测试也就无从谈起了）。
 *
 * 第三参 `groupOverrides` 同理（appgroups.map()）：分组的改名/调序/隐藏在这里
 * 一起并进 `group` 字段一起下发，客户端不用再算一次"这个组现在叫什么"。
 */
function listFor({ friendMode, attendanceEnabled, hasOrg, role } = {}, overrides, groupOverrides) {
  const isAdmin = role === 'admin';
  const ovs = overrides || {};
  return BUILTIN_APPS
    .map((a, idx) => {
      const ov = ovs[a.id];
      return {
        def: a,
        // 出厂次序 = 数组序 × 10，留出空档让管理员插队（排序号 5 能插到前两个之间）
        sort: ov && ov.sort != null ? ov.sort : idx * 10,
        disabled: !!(ov && ov.disabled),
        title: (ov && ov.title) || a.title,
        icon: (ov && ov.icon) || a.icon,
        // 🔴 分组与配色也必须是**合并后**的值，不是出厂值。
        //    （曾经这里漏了，结果是"管理台把盘点挪到门店作业组、工作台一动不动"，
        //     而且不报错 —— 只会让人以为分组功能坏了。）
        group: (ov && ov.group) || a.group,
        color: (ov && ov.color) || a.color || null,
        params: (ov && ov.params) || {},
      };
    })
    .filter((x) => {
      // 整应用停用：直接不出现（后端也会拦它的接口，见 appguard.js）。
      // 与 need 不同的是，它排在 need 判断之前 —— 停用的应用不该再走一遍
      // "这个人有没有资格"的推理，因为答案对所有人都是"没有"。
      if (x.disabled) return false;
      const a = x.def;
      const n = a.need || {};
      if (n.workMode && friendMode !== 'work') return false;
      if (n.attendance && attendanceEnabled === false) return false;
      if (n.orgMember && !hasOrg) return false;
      // role: 'employee' = **员工专属**。管理员管的是"别人打了没"，
      // 让他也进"我的打卡"只会污染统计口径，所以这两项对他隐藏
      // （他要看的是 att_admin）。
      if (n.role === 'employee' && isAdmin) return false;
      // adminOnly = **管理员专属**（主管的看板与代补卡）。员工看到它没有意义，
      // 而且他点开也是 403 —— 入口和权限必须是同一套判据，不能靠"点了才知道"。
      if (n.adminOnly && !isAdmin) return false;
      return true;
    })
    .sort((p, q) => (p.sort - q.sort) || p.def.id.localeCompare(q.def.id))
    .map((x) => ({
      id: x.def.id,
      title: x.title,
      icon: x.icon,
      // x.group / x.color 是合并后的（见上一步），x.def 只是出厂定义
      group: x.group,
      // 分组的改名/调序在这里并进来：客户端直接显示，不用自己查分组表
      groupLabel: (groupOverrides && groupOverrides[x.group]?.label) || groupOf(x.group).label,
      desc: x.def.desc,
      sort: x.sort,
      kind: 'builtin',
      // 品牌色：客户端拿它画图标底色，没给就用通用渐变（见客户端 workbench 的兜底）
      color: x.color,
      // 参数随清单一起下发：客户端不装新包也能读到管理台改的值
      // （哪些参数客户端真的读，见 appoverrides.js 的 enforced 标注）
      params: x.params,
    }));
}

/** 取某个分组的出厂定义（分组 key 是出厂就定好的，本文件不需要查库） */
function groupOf(key) {
  return DEFAULT_GROUPS.find((g) => g.key === key) || { key, label: key, sort: 999 };
}

/** 全部内置应用的元信息（供管理台"应用中心"页展示只读清单） */
function catalog(overrides, groupOverrides) {
  const ovs = overrides || {};
  return BUILTIN_APPS.map((a, idx) => {
    const ov = ovs[a.id];
    return {
      id: a.id, title: a.title, icon: a.icon, group: a.group, desc: a.desc, need: a.need,
      color: a.color || null,
      defaultSort: idx * 10,
      // 生效值（管理台的列表列直接显示这个，不用自己再合一次）
      effective: {
        title: (ov && ov.title) || a.title,
        icon: (ov && ov.icon) || a.icon,
        group: (ov && ov.group) || a.group,
        color: (ov && ov.color) || a.color || null,
        sort: ov && ov.sort != null ? ov.sort : idx * 10,
        disabled: !!(ov && ov.disabled),
      },
    };
  });
}

/**
 * 动态模块（自定义应用）的图标底色。
 *
 * 🔴 背景（2026-09-27 线上实测抓到的）：`daily_sales` 这种动态模块**没有 color**，
 *    客户端 `workbenchAppColor` 会退回品牌色 —— 于是"所有没配色的模块长得一模一样"，
 *    正是这一轮要消灭的"一排同色图标"。管理台又不强制填色（填了才好看），
 *    所以得有个不依赖人去填的兜底。
 *
 * 三条规则，按优先级：
 *   ① 模块自己写了 `#RRGGBB`（管理台编辑器的语义枚举之外的自由填色）→ 用它；
 *   ② 模块写了语义色（primary / danger / success / warning …）→ 映射到对应的十六进制；
 *   ③ 都没写 → 按 moduleId **稳定地**取色板里一个（同一个模块每次都是同一个颜色，
 *      不会刷新一次变一个色 —— 变色的图标比没有图标更让人找不到）。
 */
const MODULE_COLOR_PALETTE = [
  '#2E8BC0', '#8250DF', '#C2185B', '#1F7A3D',
  '#E07B00', '#0E7490', '#7A4FD1', '#B4332E',
];

const SEMANTIC_COLORS = {
  primary: '#10B981', muted: '#64748B', danger: '#F4685E',
  success: '#14B8A6', warning: '#E8A33D', default: '#475569',
};

function moduleColorOf(raw, moduleId) {
  const v = String(raw == null ? '' : raw).trim();
  if (/^#[0-9A-Fa-f]{6}$/.test(v)) return v;
  if (SEMANTIC_COLORS[v]) return SEMANTIC_COLORS[v];
  // ③ 稳定散列：别用随机，也不要用数组下标（模块一排序颜色就跟着跳）
  let h = 0;
  for (let i = 0; i < String(moduleId || '').length; i++) {
    h = (h * 31 + String(moduleId).charCodeAt(i)) >>> 0;
  }
  return MODULE_COLOR_PALETTE[h % MODULE_COLOR_PALETTE.length];
}

module.exports = {
  GROUPS, DEFAULT_GROUPS, groupOf,
  BUILTIN_APPS, listFor, catalog,
  MODULE_COLOR_PALETTE, moduleColorOf,
};
