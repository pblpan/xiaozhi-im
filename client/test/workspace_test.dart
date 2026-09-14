import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaozhi_im_client/core/workspace.dart';

/// 服务器「工作区身份」（公司名 / 好友模式）的单元测试。
///
/// 这个值决定**首页给哪些一级入口**，所以最怕的是"判断歪了"：
///   · 把普通模式当工作模式 → 家里用的账号长出用不到的工作台/组织通讯录；
///   · 把工作模式当普通模式 → 同事找不到打卡入口。
/// 两种都不会报错、只会让人找不到东西，所以必须钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Workspace.mode.value = Workspace.normal;
    Workspace.company.value = '';
  });

  test('默认是普通模式（没拿到服务端信息前不长出工作入口）', () {
    expect(Workspace.isWork, isFalse);
    expect(Workspace.mode.value, Workspace.normal);
  });

  test('apply 能切到工作模式并落盘', () async {
    await Workspace.apply(mode: Workspace.work, companyName: '某某厂');
    expect(Workspace.isWork, isTrue);
    expect(Workspace.company.value, '某某厂');

    final p = await SharedPreferences.getInstance();
    expect(p.getString('xz_friend_mode'), Workspace.work);
    expect(p.getString('xz_company_name'), '某某厂');
  });

  test('冷启动先吃缓存（离线也能定导航形态）', () async {
    SharedPreferences.setMockInitialValues({
      'xz_friend_mode': Workspace.work,
      'xz_company_name': '某某厂',
    });
    Workspace.mode.value = Workspace.normal; // 模拟"进程刚起来"的初始值
    Workspace.company.value = '';
    await Workspace.load();
    expect(Workspace.isWork, isTrue);
    expect(Workspace.company.value, '某某厂');
  });

  test('未知模式被忽略：不改变当前状态，也绝不被当成工作模式', () async {
    // 普通模式下收到未知值 → 仍是普通模式
    await Workspace.apply(mode: 'hybrid-future-mode');
    expect(Workspace.isWork, isFalse, reason: '未知值不能让普通模式长出工作入口');

    // 工作模式下收到未知值 → 保持工作模式（降级成普通会让人当场丢掉打卡入口）
    await Workspace.apply(mode: Workspace.work);
    expect(Workspace.isWork, isTrue);
    await Workspace.apply(mode: 'hybrid-future-mode');
    expect(Workspace.isWork, isTrue, reason: '不认识的模式不该改动当前状态');
  });

  test('空值/空公司名不覆盖已有状态（避免一次失败请求把导航打回普通模式）', () async {
    await Workspace.apply(mode: Workspace.work, companyName: '某某厂');
    await Workspace.apply(mode: '', companyName: '');
    expect(Workspace.isWork, isTrue);
    expect(Workspace.company.value, '某某厂');
  });

  test('模式变化会通知监听者（导航靠它重建）', () async {
    var fired = 0;
    void l() => fired++;
    Workspace.mode.addListener(l);
    addTearDown(() => Workspace.mode.removeListener(l));

    await Workspace.apply(mode: Workspace.work);
    expect(fired, 1);
    // 同一个值再设一次不该重复通知（否则导航会白重建，还会丢掉当前标签）
    await Workspace.apply(mode: Workspace.work);
    expect(fired, 1);
    await Workspace.apply(mode: Workspace.normal);
    expect(fired, 2);
  });
}
