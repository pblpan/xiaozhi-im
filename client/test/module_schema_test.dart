// 动态模块协议解析单测（SPEC-动态配置与模块.md 第二期）
//
// 这里测的是**客户端不可信输入处理**：服务端下发的 JSON 可能被篡改、可能来自
// 一个不校验的旧版本服务端。所以重点不是"正常能解析"，而是：
//   ① 任何畸形输入都不抛异常（抛了就是白屏）
//   ② 危险动作在客户端这一层就被拦住（纵深防御）
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/apps.dart';
import 'package:xiaozhi_im_client/core/module_schema.dart';

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
      expect(kBuiltinAppIds, {'attendance', 'my_requests', 'work_org'});
    });

    test('不认识的 id 返回 null，让调用方跳过而不是崩', () {
      // 服务端先上线一个新应用、客户端还是旧版本时的必经路径
      expect(isKnownBuiltinApp('some_future_app'), isFalse);
      expect(builtinAppPage('some_future_app'), isNull);
      expect(isKnownBuiltinApp(''), isFalse);
      expect(builtinAppPage(''), isNull);
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
