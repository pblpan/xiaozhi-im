// 动态模块协议解析单测（SPEC-动态配置与模块.md 第二期）
//
// 这里测的是**客户端不可信输入处理**：服务端下发的 JSON 可能被篡改、可能来自
// 一个不校验的旧版本服务端。所以重点不是"正常能解析"，而是：
//   ① 任何畸形输入都不抛异常（抛了就是白屏）
//   ② 危险动作在客户端这一层就被拦住（纵深防御）
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/apps.dart';
import 'package:xiaozhi_im_client/core/module_schema.dart';
import 'package:xiaozhi_im_client/screens/inventory.dart';
import 'package:xiaozhi_im_client/screens/price_tag_print.dart';
import 'package:xiaozhi_im_client/screens/simple_stocktake.dart';

void main() {
  group('组件类型识别', () {
    test('8 种组件都能识别', () {
      const names = {
        'text': ModuleComponentType.text,
        'divider': ModuleComponentType.divider,
        'card': ModuleComponentType.card,
        'list': ModuleComponentType.list,
        'table': ModuleComponentType.table,
        'form': ModuleComponentType.form,
        'action': ModuleComponentType.action,
        'chart': ModuleComponentType.chart,
      };
      names.forEach((name, type) {
        final c = ModuleComponent.fromJson({'component': name});
        expect(c.type, type, reason: name);
      });
    });

    test('未知组件降级为 unknown 并保留原名（渲染占位块，不崩）', () {
      final c = ModuleComponent.fromJson({'component': 'video_player', 'src': 'x'});
      expect(c.type, ModuleComponentType.unknown);
      expect(c.rawType, 'video_player');
    });

    test('畸形输入不抛异常', () {
      for (final bad in <Object?>[
        null, 42, 'text', <int>[1, 2], {}, {'component': null}, {'component': 123},
      ]) {
        expect(() => ModuleComponent.fromJson(bad), returnsNormally,
            reason: '输入 $bad 不应抛异常');
        expect(() => ModuleDef.fromJson(bad), returnsNormally,
            reason: '输入 $bad 不应抛异常');
      }
    });
  });

  group('语义颜色（深色主题自适应）', () {
    test('合法枚举被识别', () {
      expect(semanticColorOf('primary'), SemanticColor.primary);
      expect(semanticColorOf('danger'), SemanticColor.danger);
      expect(semanticColorOf('success'), SemanticColor.success);
      expect(semanticColorOf('warning'), SemanticColor.warning);
      expect(semanticColorOf('muted'), SemanticColor.muted);
    });

    test('写死的色值不被接受（回落 default，由主题决定实际颜色）', () {
      expect(semanticColorOf('#ff0000'), SemanticColor.defaultColor);
      expect(semanticColorOf('red'), SemanticColor.defaultColor);
      expect(semanticColorOf(null), SemanticColor.defaultColor);
    });
  });

  group('动作安全校验（客户端二次校验）', () {
    ModuleAction a(String type, {String? path, String? url, String? page, String? text}) =>
        ModuleAction(type: type, path: path, url: url, page: page, text: text);

    test('api 只允许 /api/hooks/ 前缀 —— 防 SSRF', () {
      expect(a('api', path: '/api/hooks/stock/overview').canExecute, isTrue);
      expect(a('api', path: 'http://169.254.169.254/latest/meta-data').canExecute, isFalse);
      expect(a('api', path: '/api/admin/users').canExecute, isFalse);
      expect(a('api', path: 'https://evil.com/steal').canExecute, isFalse);
      expect(a('api').canExecute, isFalse);
    });

    test('openUrl 只允许 https —— 防中间人换成钓鱼页', () {
      expect(a('openUrl', url: 'https://example.com').canExecute, isTrue);
      expect(a('openUrl', url: 'http://example.com').canExecute, isFalse);
      expect(a('openUrl', url: 'javascript:alert(1)').canExecute, isFalse);
    });

    test('navigate 只允许内置页面', () {
      expect(a('navigate', page: 'settings').canExecute, isTrue);
      expect(a('navigate', page: 'conversations').canExecute, isTrue);
      expect(a('navigate', page: 'anything_else').canExecute, isFalse);
    });

    test('未知动作类型不可执行', () {
      expect(a('eval').known, isFalse);
      expect(a('eval').canExecute, isFalse);
      expect(a('noop').canExecute, isFalse);
    });

    test('copy 需要 text 或 dataPath', () {
      expect(a('copy', text: 'hi').canExecute, isTrue);
      expect(a('copy').canExecute, isFalse);
    });
  });

  group('版本闸门（客户端侧再卡一次）', () {
    ModuleDef m(String? min) => ModuleDef.fromJson({
          'moduleId': 'x', 'title': 'X', if (min != null) 'minClientVersion': min,
        });

    test('无 minClientVersion 一律通过', () {
      expect(m(null).supports('0.9.0'), isTrue);
    });

    test('低于最低版本不显示', () {
      expect(m('1.0.0').supports('0.9.0'), isFalse);
      expect(m('0.9.0').supports('0.9.0'), isTrue);
      expect(m('0.8.0').supports('0.9.0'), isTrue);
    });

    test('版本号非法 = 不满足（宁可不显示，也不显示一个跑不起来的页面）', () {
      expect(m('v1').supports('0.9.0'), isFalse);
      expect(m('1.0.0').supports(''), isFalse);
      expect(m('1.0.0').supports('最新版'), isFalse);
    });
  });

  // 工作台（应用列表）里只有 minVersion 字符串、没有完整 ModuleDef，
  // 所以它调的是抽出来的独立函数。**参数顺序是 (minVersion, clientVersion)**，
  // 反过来写不会报错、只会静默判反 —— 这条组就是拿来看住顺序的。
  group('clientSatisfiesVersion（工作台用的独立版本闸门）', () {
    test('没有最低版本要求 → 一律通过', () {
      expect(clientSatisfiesVersion(null, '0.11.0'), isTrue);
      expect(clientSatisfiesVersion('', '0.11.0'), isTrue);
    });

    test('参数顺序：第一个是最低要求，第二个才是本机版本', () {
      // 最低要 9.9.9、本机 0.11.0 → 不满足
      expect(clientSatisfiesVersion('9.9.9', '0.11.0'), isFalse);
      // 最低要 0.1.0、本机 0.11.0 → 满足
      // （若把两个参数写反，上面两条的结果正好会对调，所以这两条必须成对断言）
      expect(clientSatisfiesVersion('0.1.0', '0.11.0'), isTrue);
    });

    test('相等 / 更高都通过，低一个补丁号也拦住', () {
      expect(clientSatisfiesVersion('0.11.0', '0.11.0'), isTrue);
      expect(clientSatisfiesVersion('0.11.0', '0.12.0'), isTrue);
      expect(clientSatisfiesVersion('0.11.1', '0.11.0'), isFalse);
      expect(clientSatisfiesVersion('0.11.0', '0.10.9'), isFalse);
      expect(clientSatisfiesVersion('1.0.0', '0.99.99'), isFalse);
    });

    test('本机版本非法 = 不满足（不能因为读不到版本就把所有东西都放行）', () {
      expect(clientSatisfiesVersion('1.0.0', ''), isFalse);
      expect(clientSatisfiesVersion('1.0.0', 'dev'), isFalse);
      expect(clientSatisfiesVersion('1.0.0', '0.11'), isFalse);
    });

    test('最低版本写成非法值时也拦（服务端校验过，客户端不假设它一定对）', () {
      expect(clientSatisfiesVersion('v1', '0.11.0'), isFalse);
      expect(clientSatisfiesVersion('最新版', '0.11.0'), isFalse);
    });
  });

  group('内置应用注册表（core/apps.dart）', () {
    test('三个内置 id 都认识，且能取到页面构造器', () {
      for (final id in kBuiltinAppIds) {
        expect(isKnownBuiltinApp(id), isTrue, reason: id);
        expect(builtinAppPage(id), isNotNull, reason: id);
      }
    });

    test('id 与服务端 apps.js 对齐（改名 = 老客户端丢入口，发布后不可改）', () {
      // ⚠️ 这份期望值必须与服务端 server/src/apps.js 的 id 集合**逐字一致**。
      // 2026-09-16 补上 'att_admin'：它是 v0.13.3 加的管理员专属考勤记录应用，
      // 客户端 apps.dart 当时就跟着加了，但**这里的期望值漏改** —— 于是这条
      // 判据从 v0.13.3 起一直红着，没人跑 flutter test 就没人发现。
      // 一个长期红的判据等于没有判据（和"探针全绿其实没验"是同一类病），
      // 所以这里顺手补绿，并在两端各留一句注释。
      //
      // 2026-09-19 补上 'stocktake'（扫码枪；原名"门店盘点"，已改名让出"盘点"）。
      //
      // 2026-09-19 再补上 'inventory'（**盘点**本体，M1 落地）。⚠️ 这两个
      // id 极容易看混：`stocktake` 是扫码枪（把条码扫成一笔账的工具），
      // `inventory` 才是盘点（盘点位 / 货架位 / 初盘-复盘-抽盘）。
      // 区别见 docs/盘点复刻与开放接口方案-v1.md §3.0。
      //
      // 2026-09-20 补上 'training'（**培训中心**，M4）。名字必须叫「培训中心」——
      // 是龙哥定的，不要改成"培训管理""学习中心"之类。
      //
      // 2026-09-22 补上 'warehouse_deduct'（**库房减货**，M5 软件项）→
      //    🔴 2026-10-04 摘掉：0.17.1 那会儿它单独占工作台卡片，后来减货/补货/
      //      拣货/商档查询都收进「盘点」页的快捷入口（带文字，可发现性比
      //      无名小图标好），工作台不再放这两个图标 —— 龙哥 2026-10-04 定。
      //
      // 2026-09-25 补上 'simple_stocktake'（**简易盘点**，S1）。
      // ⚠️ 它和 'inventory'（盘点）是两个应用，名字极容易看混：
      //    盘点是**制度型**（点位/货架位/三遍互比），
      //    简易盘点是**干活型**（导入这一轮要盘的清单 → 一趟趟扫 → 导全量单）。
      //    在服务端 apps.js 里它俩是**紧挨着**排的（员工才分得清），
      //    这里也照同样的次序写。见 docs/简易盘点通道方案-v1.md §1。
      //
      // 2026-09-26 补上 'price_tag'（**价签打印**）。⚠️ 它**不落单**：
      //    打完就贴在货上，没有第二方认它，存表只为"重打"——所以 appdata.js 里
      //    它**刻意不给 metrics**，别为了"跟别的一致"给个空的"0 单 0 行"（那是句假话）。
      //
      // ⚠️ **以后每加一个内置应用要同步改五处**（清单写在 core/apps.dart 顶上）：
      //    kBuiltinAppIds / builtinAppPage / server 的 apps.js / appguard.js /
      //    appdata.js，再加上下面这份期望值。**加完请立刻跑 flutter test 和
      //    server/test/apps_admin_e2e.js**（服务端两处注册表都有自检拦着）。
      // 'replenish'（补货，生鲜/杂百分列，两套单位是龙哥定的：生鲜按公斤、
      // 杂百按最小单位，不做第三套）同日随库房减货一起摘掉。
      expect(kBuiltinAppIds, {
        'attendance',
        'my_requests',
        'work_org',
        'att_admin',
        'stocktake',
        'inventory',
        'simple_stocktake',
        // 🔴 'warehouse_deduct' / 'replenish' 2026-10-04 摘掉（龙哥定：工作台
        //    图标撤掉，功能收进盘点页的快捷入口）。别再加回来。
        'training',
        'price_tag',
        // #314 智能助手（2026-10-11）：接管帮助问答。所有人可见（不加
        // workMode/orgMember —— 普通模式的人也会问"怎么传文件"）。
        'assistant',
      });
    });

    test('🔴 库房减货/补货已撤工作台注册（2026-10-04，功能收进盘点页）', () {
      // 反向断言：注册加回来 = 工作台重新冒出独立图标，龙哥明确要去掉。
      expect(isKnownBuiltinApp('warehouse_deduct'), isFalse);
      expect(builtinAppPage('warehouse_deduct'), isNull);
      expect(isKnownBuiltinApp('replenish'), isFalse);
      expect(builtinAppPage('replenish'), isNull);
    });

    test('不认识的 id 返回 null，让调用方跳过而不是崩', () {
      // 服务端先上线一个新应用、客户端还是旧版本时的必经路径
      expect(isKnownBuiltinApp('some_future_app'), isFalse);
      expect(builtinAppPage('some_future_app'), isNull);
      expect(isKnownBuiltinApp(''), isFalse);
      expect(builtinAppPage(''), isNull);
    });

    test('🔴 「价签打印」认得出来，且点进去就是那一页', () {
      // 服务端 apps.js 先下发 id，客户端这一版才认得 → 装旧版的人看不到这个入口，
      // 装新版的人点进去必须是价签页（而不是某个"长得挺正常"但完全不对的页）。
      expect(isKnownBuiltinApp('price_tag'), isTrue);
      expect(builtinAppPage('price_tag'), isA<PriceTagPrintPage>());
    });

    test('🔴 「简易盘点」认得出来，且点进去就是那一页（不是「盘点」）', () {
      // ⚠️ 这里刻意同时断言"不是 InventoryPage"：两个 id 名字太像，
      //    把 simple_stocktake 路由到盘点页是**很容易犯、且很难发现**的错
      //    （点进去是个长得挺正常的页面，只是完全不是他要的功能）。
      expect(isKnownBuiltinApp('simple_stocktake'), isTrue);
      expect(builtinAppPage('simple_stocktake'), isA<SimpleStocktakePage>());
      expect(builtinAppPage('simple_stocktake'), isNot(isA<InventoryPage>()));
    });
  });

  group('dataPath 取值', () {
    final data = {
      'items': [
        {'name': 'A', 'qty': 3},
        {'name': 'B', 'qty': 5},
      ],
      'nested': {
        'deep': {'v': 'ok'},
      },
      'matrix': [
        [1, 2],
        [3, 4],
      ],
    };

    test('点路径与下标', () {
      expect(ModuleData.of(data, 'nested.deep.v'), 'ok');
      expect(ModuleData.of(data, 'matrix[1][0]'), 3);
      expect(ModuleData.of(data, 'items[0].name'), 'A');
      expect(ModuleData.of(data, 'items'), isA<List<dynamic>>());
    });

    test('取不到返回 null 而不抛异常', () {
      expect(ModuleData.of(data, 'nope'), isNull);
      expect(ModuleData.of(data, 'items[9].name'), isNull);
      expect(ModuleData.of(data, 'items.name'), isNull);
      expect(ModuleData.of(data, 'nested.deep.v.x'), isNull);
      expect(ModuleData.of(data, ''), isNull);
      expect(ModuleData.of(null, 'a.b'), isNull);
    });

    test('listOf 保证返回 List（UI 不必判空）', () {
      expect(ModuleData.listOf(data, 'items').length, 2);
      expect(ModuleData.listOf(data, 'nope'), isEmpty);
      expect(ModuleData.listOf(data, 'nested'), isEmpty);
    });
  });

  group('模板渲染', () {
    final item = {'name': '张三', 'qty': 12, 'desc': '待处理'};

    test('替换占位符', () {
      expect(renderTemplate('{{name}}', item), '张三');
      expect(renderTemplate('{{name}} / {{desc}}', item), '张三 / 待处理');
      expect(renderTemplate('{{ qty }} 件', item), '12 件');
    });

    test('取不到的字段原样保留（便于发现配置写错，而不是显示空白）', () {
      expect(renderTemplate('{{missing}}', item), '{{missing}}');
    });

    test('没有占位符时原样返回', () {
      expect(renderTemplate('固定文字', item), '固定文字');
    });
  });

  group('表单字段解析', () {
    test('select 的选项被解析出来', () {
      final f = ModuleField.fromJson({
        'key': 'level', 'label': '紧急程度', 'type': 'select', 'required': true,
        'options': [
          {'label': '一般', 'value': 'low'},
          {'label': '紧急', 'value': 'high'},
        ],
      });
      expect(f.key, 'level');
      expect(f.required, isTrue);
      expect(f.isSelect, isTrue);
      expect(f.options.length, 2);
      expect(f.options[1].value, 'high');
    });

    test('类型判定', () {
      expect(ModuleField.fromJson({'key': 'a', 'type': 'switch'}).isSwitch, isTrue);
      expect(ModuleField.fromJson({'key': 'a', 'type': 'number'}).isNumber, isTrue);
      expect(ModuleField.fromJson({'key': 'a', 'type': 'date'}).isDate, isTrue);
      expect(ModuleField.fromJson({'key': 'a', 'type': 'textarea'}).isTextarea, isTrue);
    });

    test('缺 key 的字段被丢弃（不生成无法提交的字段）', () {
      final c = ModuleComponent.fromJson({
        'component': 'form',
        'fields': [
          {'label': '没有 key'},
          {'key': 'ok', 'label': '正常', 'type': 'text'},
        ],
      });
      expect(c.fields.length, 1);
      expect(c.fields.first.key, 'ok');
    });

    test('动态下拉：optionsFrom/optionsPath/label/value 全解析', () {
      final f = ModuleField.fromJson({
        'key': 'shiftId', 'label': '班次', 'type': 'select', 'required': true,
        'optionsFrom': '/api/hooks/local/duty/shifts',
        'optionsPath': 'data.rows',
        'optionLabel': 'label',
        'optionValue': 'value',
      });
      expect(f.hasDynamicOptions, isTrue);
      expect(f.optionsFrom, '/api/hooks/local/duty/shifts');
      expect(f.optionsPath, 'data.rows');
      expect(f.optionLabel, 'label');
      expect(f.optionValue, 'value');
      // 配了动态源就不强制静态 options（服务端同款规则）
      expect(f.options, isEmpty);
    });

    test('动态下拉：默认值（optionsPath=data.rows、label/value）', () {
      final f = ModuleField.fromJson({
        'key': 'x', 'type': 'select', 'optionsFrom': '/api/hooks/local/a/b',
      });
      expect(f.optionsPath, 'data.rows');
      expect(f.optionLabel, 'label');
      expect(f.optionValue, 'value');
    });

    test('动态下拉：optionsFrom 不是 /api/hooks/ 前缀 → 丢弃（SSRF 纵深防御）', () {
      final f = ModuleField.fromJson({
        'key': 'x', 'type': 'select',
        'optionsFrom': 'https://evil.example.com/list',
      });
      expect(f.hasDynamicOptions, isFalse);
      expect(f.optionsFrom, isNull);
    });
  });

  group('完整模块解析', () {
    test('八组件模块全字段解析正确', () {
      final def = ModuleDef.fromJson({
        'moduleId': 'device_repair',
        'title': '设备报修',
        'icon': 'build',
        'minClientVersion': '0.9.0',
        'sort': 3,
        'enabled': true,
        'body': [
          {'component': 'text', 'text': '提交后维修班会收到通知', 'size': 13, 'color': 'muted'},
          {'component': 'divider'},
          {'component': 'card', 'title': '卡', 'accent': 'warning',
            'children': [{'component': 'text', 'text': '内'}]},
          {'component': 'list', 'dataPath': 'items',
            'itemTemplate': {'title': '{{name}}', 'subtitle': '{{desc}}', 'trailing': '{{qty}}'}},
          {'component': 'table', 'dataPath': 'rows',
            'columns': [{'key': 'name', 'label': '名称', 'width': 100}]},
          {'component': 'form', 'fields': [{'key': 'device', 'label': '设备', 'type': 'text', 'required': true}],
            'submit': {'action': 'api', 'method': 'POST', 'path': '/api/hooks/repair/create'}},
          {'component': 'action', 'label': '刷新',
            'onTap': {'action': 'api', 'path': '/api/hooks/repair/refresh', 'method': 'GET'}},
          {'component': 'chart', 'dataPath': 'rows', 'xKey': 'name', 'yKey': 'qty', 'kind': 'bar'},
        ],
      });
      expect(def.valid, isTrue);
      expect(def.title, '设备报修');
      expect(def.icon, 'build');
      expect(def.sort, 3);
      expect(def.body.length, 8);
      expect(def.body[2].children.length, 1);
      expect(def.body[2].accent, SemanticColor.warning);
      expect(def.body[4].columns.first.width, 100);
      expect(def.body[5].submit?.canExecute, isTrue);
      expect(def.body[6].onTap?.path, '/api/hooks/repair/refresh');
      expect(def.body[7].chartKind, 'bar');
    });

    test('moduleId 为空视为无效模块', () {
      expect(ModuleDef.fromJson({'title': '无 id'}).valid, isFalse);
      expect(ModuleDef.fromJson({'moduleId': 'x', 'title': 'X'}).valid, isTrue);
    });

    test('enabled=false 的模块仍能解析（由服务端负责过滤）', () {
      final d = ModuleDef.fromJson({'moduleId': 'x', 'title': 'X', 'enabled': false});
      expect(d.enabled, isFalse);
      expect(d.valid, isTrue);
    });
  });
}
