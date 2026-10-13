import '../api.dart';
import '../models.dart';
import 'workspace.dart';

/// 群聊拉人候选名单（建群 / 群管理「添加成员」共用一份逻辑）。
///
/// 口径分模式：
///  · **普通模式**：只有好友。家用场景，拉陌生人进群没有社交基础；
///  · **工作模式**：好友 ∪ **组织全员**（含 org_id=NULL 的管理员账号）。
///
/// 为什么工作模式要放开到全员（2026-10-13 龙哥报的 bug「管理员在通讯录里
/// 看不到和不能被加入群聊」）：
/// 同事之间不一定互为好友 —— 自动互好友只覆盖「录入员工」那一刻在册的人，
/// 管理员账号不占编制、从来不在关系表里，后录的员工也可能漏。而拉群是工作
/// 场景的高频动作，钉钉/企业微信的口径都是"组织架构里的人都能拉"，不是
/// "只有互为好友的才能拉"。以前只列好友，结果是管理员在任何人的拉群列表里
/// 都消失，@人和建群全缺这一角。
///
/// 合并规则：好友在前（带 remark，显示名按"我看到的名称"），组织成员按 id
/// 去重后追加。组织拉取失败不阻塞 —— 至少还有好友可用（弱网、或老服务端
/// 没有 /orgs/my 接口时）。
Future<List<User>> loadGroupCandidates() async {
  final r = await ImApi().friends();
  final friends = ((r['friends'] as List?) ?? const [])
      .map((e) => User.fromJson(e as Map<String, dynamic>))
      .toList();
  if (!Workspace.isWork) return friends;

  final merged = List<User>.of(friends);
  final seen = merged.map((u) => u.id).toSet();
  try {
    final org = await ImApi().myOrg();
    final members = (org['members'] as List?) ?? const [];
    for (final m in members) {
      if (m is! Map) continue;
      final u = User.fromJson(m.cast<String, dynamic>());
      if (u.id <= 0 || seen.contains(u.id)) continue;
      seen.add(u.id);
      merged.add(u);
    }
  } catch (_) {
    // 组织数据拉不到：保留好友候选，静默降级
  }
  return merged;
}
