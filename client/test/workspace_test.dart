import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaozhi_im_client/core/workspace.dart';

/// 服务器「工作区身份」（公司名 / 好友模式 / 品牌名）的单元测试。
///
/// 这个值决定**首页给哪些一级入口**，所以最怕的是"判断歪了"：
///   · 把普通模式当工作模式 → 家里用的账号长出用不到的工作台/组织通讯录；
///   · 把工作模式当普通模式 → 同事找不到打卡入口。
/// 两种都不会报错、只会让人找不到东西，所以必须钉住。
///
/// 品牌名（brand）单独成组的理由：它曾经**在登录页和主界面各拼了一遍**
/// （登录页 `'$name小智'`、主界面写死 `'小智 IM'`），于是管理台改了公司名
/// 就成了"登录页变了、登进去又变回来"，2026-09-18 被当成"改了没生效"报了回来。
/// 现在规则只在 [Workspace.brandOf] 一处，这几条断言就是防止它再分叉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Workspace.mode.value = Workspace.normal;
    Workspace.company.value = '';
    Workspace.brand.value = Workspace.brandOf('');
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

  test('mode 传空串不覆盖现状（一次失败请求不能把导航打回普通模式）', () async {
    await Workspace.apply(mode: Workspace.work, companyName: '某某厂');
    await Workspace.apply(mode: '');
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

  // ------------------------------------------------------------------
  // 品牌名：登录页标题 / 客户端顶部标题 / 电脑端窗口标题 / 托盘 全都读它
  // ------------------------------------------------------------------
  group('品牌名 brand', () {
    test('有公司名 →「××小智」；没有或只有空白 →「小智 IM」', () {
      expect(Workspace.brandOf('好又多'), '好又多小智');
      // 服务端存原文，管理台允许有前后空格，展示时必须 trim
      expect(Workspace.brandOf('  好又多  '), '好又多小智');
      expect(Workspace.brandOf(''), '小智 IM');
      expect(Workspace.brandOf('   '), '小智 IM');
    });

    test('apply 改公司名时 brand 同一处跟着变', () async {
      await Workspace.apply(companyName: '好又多');
      expect(Workspace.brand.value, '好又多小智');
      await Workspace.apply(companyName: '盛京');
      expect(Workspace.brand.value, '盛京小智');
    });

    test('companyName 传 null = 这次没拿到 → 保持现状（网络抖动清不掉公司名）', () async {
      await Workspace.apply(companyName: '好又多');
      await Workspace.apply(companyName: null);
      expect(Workspace.company.value, '好又多');
      expect(Workspace.brand.value, '好又多小智');
    });

    test('companyName 传空串 = 服务端明确清空 → 真的清掉并落盘', () async {
      await Workspace.apply(companyName: '好又多');
      await Workspace.apply(companyName: '');
      expect(Workspace.company.value, '');
      expect(Workspace.brand.value, '小智 IM');
      final p = await SharedPreferences.getInstance();
      expect(p.getString('xz_company_name'), '',
          reason: '清空必须落盘，否则重启又从缓存里长出旧公司名');
    });

    test('冷启动 load 会按缓存重算 brand（离线也显示对的名字）', () async {
      SharedPreferences.setMockInitialValues({'xz_company_name': '好又多'});
      Workspace.company.value = '';
      Workspace.brand.value = Workspace.brandOf('');
      await Workspace.load();
      expect(Workspace.brand.value, '好又多小智');
    });

    test('brand 变化会通知监听者（顶部标题靠它刷新）', () async {
      var fired = 0;
      void l() => fired++;
      Workspace.brand.addListener(l);
      addTearDown(() => Workspace.brand.removeListener(l));

      await Workspace.apply(companyName: '好又多');
      expect(fired, 1, reason: '管理台改了公司名，标题必须重建');
      await Workspace.apply(companyName: '好又多');
      expect(fired, 1, reason: '同一个值不该重复通知');
      await Workspace.apply(companyName: '');
      expect(fired, 2, reason: '清空公司名也要刷新成「小智 IM」');
    });
  });
}
