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
 * 1. **内置应用不接受"显示/隐藏"开关**。入口可见性只由**业务状态**决定
 *    （没开工作模式就没有考勤、考勤关了就没有打卡），由 listFor() 算出来。
 *    留一个开关必然会配出"入口在、点进去报错"的状态，而管理员根本不知道
 *    该去关哪个开关。要临时停用就改业务状态（attendanceEnabled），语义唯一。
 *
 * 2. **客户端不认识的应用 id 直接忽略，不报错**。这一条是给未来留的：
 *    服务端先上线一个新应用、客户端还是旧版本，旧客户端只会少一个图标，
 *    不会白屏也不会弹错。新增应用永远不需要"先升级客户端"。
 *
 * 客户端侧的落地见 client/lib/core/apps.dart（id → 页面构造器），
 * 两边都以本文件的 id 为准，id 一旦发布**不可改名**（改名等于老客户端丢入口）。
 */

/**
 * 分组：客户端工作台按此分区显示。
 * work   工作 —— 与"上班"直接相关（考勤、申请、组织）
 * custom 自定义 —— 动态模块（管理台拼的）
 */
const GROUPS = ['work', 'custom'];

const BUILTIN_APPS = [
  {
    id: 'attendance',
    title: '考勤打卡',
    icon: 'schedule',
    group: 'work',
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
    desc: '请假、补卡、外出、加班的申请与进度',
    need: { workMode: true, attendance: true, orgMember: true, role: 'employee' },
  },
  {
    id: 'work_org',
    title: '组织通讯录',
    icon: 'people',
    group: 'work',
    desc: '按部门查看同事、工号与岗位',
    // 管理员也能看（他要看全员），所以不限定 role
    need: { workMode: true, orgMember: true },
  },
];

/**
 * 按当前服务器/用户状态过滤出可见应用。
 * 传进来的是**已算好的状态**，本函数不查库 —— 这样它可以被测试直接喂各种组合
 * （"工作模式但没组织""有组织但管理员"…），不用先搭一套数据库。
 */
function listFor({ friendMode, attendanceEnabled, hasOrg, role } = {}) {
  const isAdmin = role === 'admin';
  return BUILTIN_APPS.filter((a) => {
    const n = a.need || {};
    if (n.workMode && friendMode !== 'work') return false;
    if (n.attendance && attendanceEnabled === false) return false;
    if (n.orgMember && !hasOrg) return false;
    // role: 'employee' 表示"只有员工可见（管理员不可见）"
    if (n.role === 'employee' && isAdmin) return false;
    return true;
  }).map((a) => ({
    id: a.id,
    title: a.title,
    icon: a.icon,
    group: a.group,
    desc: a.desc,
    kind: 'builtin',
  }));
}

/** 全部内置应用的元信息（供管理台"应用中心"页展示只读清单） */
function catalog() {
  return BUILTIN_APPS.map((a) => ({
    id: a.id, title: a.title, icon: a.icon, group: a.group, desc: a.desc, need: a.need,
  }));
}

module.exports = { GROUPS, BUILTIN_APPS, listFor, catalog };
