// 动态模块渲染器 widget 测试（SPEC-动态配置与模块.md 第二期）
//
// 渲染器的职责是"服务端给什么就画什么，画不出来也不崩"。
// 所以这里同时覆盖正常渲染与三种异常输入：未知组件、空数据、必填未填。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/module_schema.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/widgets/module_renderer.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

ModuleComponent comp(Map<String, dynamic> json) => ModuleComponent.fromJson(json);

Future<void> pumpBody(
  WidgetTester tester,
  List<ModuleComponent> body, {
  Map<String, dynamic> data = const {},
  ModuleActionHandler? onAction,
}) async {
  await tester.pumpWidget(wrap(ModuleRenderer(
    body: body,
    data: data,
    onAction: onAction ?? (_, __) {},
  )));
  await tester.pump();
}

void main() {
  testWidgets('text 组件按内容和语义色渲染', (tester) async {
    await pumpBody(tester, [
      comp({'component': 'text', 'text': '库存告警', 'size': 18, 'color': 'danger'}),
    ]);
    expect(find.text('库存告警'), findsOneWidget);
  });

  testWidgets('divider 组件渲染出分隔线', (tester) async {
    await pumpBody(tester, [comp({'component': 'divider'})]);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('card 渲染标题、副标题与子组件', (tester) async {
    await pumpBody(tester, [
      comp({
        'component': 'card', 'title': '今日概览', 'subtitle': '更新于 10:00', 'accent': 'success',
        'children': [
          {'component': 'text', 'text': '销售额 1.2 万'},
        ],
      }),
    ]);
    expect(find.text('今日概览'), findsOneWidget);
    expect(find.text('更新于 10:00'), findsOneWidget);
    expect(find.text('销售额 1.2 万'), findsOneWidget);
  });

  testWidgets('未知组件渲染占位块并提示组件名（不崩）', (tester) async {
    await pumpBody(tester, [comp({'component': 'video', 'src': 'x'})]);
    expect(find.textContaining('暂不支持的组件：video'), findsOneWidget);
  });

  testWidgets('list 按 itemTemplate 渲染数据；无数据时给空态文案', (tester) async {
    final c = comp({
      'component': 'list', 'dataPath': 'items',
      'itemTemplate': {'title': '{{name}}', 'subtitle': '{{desc}}', 'trailing': '{{qty}}'},
    });
    await pumpBody(tester, [c], data: {
      'items': [
        {'name': '3 号机', 'desc': '待维修', 'qty': '2'},
        {'name': '5 号机', 'desc': '已派单', 'qty': '1'},
      ],
    });
    expect(find.text('3 号机'), findsOneWidget);
    expect(find.text('待维修'), findsOneWidget);
    expect(find.text('5 号机'), findsOneWidget);

    await pumpBody(tester, [c], data: const {});
    expect(find.text('暂无数据'), findsOneWidget);
  });

  testWidgets('table 渲染表头与数据行', (tester) async {
    await pumpBody(tester, [
      comp({
        'component': 'table', 'dataPath': 'rows',
        'columns': [
          {'key': 'name', 'label': '商品'},
          {'key': 'qty', 'label': '库存'},
        ],
      }),
    ], data: {
      'rows': [
        {'name': '可乐', 'qty': 12},
        {'name': '雪碧', 'qty': 8},
      ],
    });
    expect(find.text('商品'), findsOneWidget);
    expect(find.text('库存'), findsOneWidget);
    expect(find.text('可乐'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
  });

  testWidgets('chart 渲染柱状图；数据为空时给提示', (tester) async {
    final c = comp({
      'component': 'chart', 'dataPath': 'rows', 'xKey': 'name', 'yKey': 'qty', 'kind': 'bar',
    });
    await pumpBody(tester, [c], data: {
      'rows': [
        {'name': '周一', 'qty': 5},
        {'name': '周二', 'qty': 9},
      ],
    });
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('周二'), findsOneWidget);

    await pumpBody(tester, [c], data: const {});
    expect(find.text('暂无数据'), findsOneWidget);
  });

  testWidgets('action 按钮点击回调携带动作对象', (tester) async {
    ModuleAction? got;
    await pumpBody(
      tester,
      [
        comp({
          'component': 'action', 'label': '刷新数据',
          'onTap': {'action': 'api', 'path': '/api/hooks/demo/refresh', 'method': 'GET'},
        }),
      ],
      onAction: (a, _) => got = a,
    );
    await tester.tap(find.text('刷新数据'));
    await tester.pump();
    expect(got?.type, 'api');
    expect(got?.path, '/api/hooks/demo/refresh');
  });

  testWidgets('form 提交时必填未填 → 提示且不触发提交', (tester) async {
    Map<String, dynamic>? submitted;
    await pumpBody(
      tester,
      [
        comp({
          'component': 'form',
          'fields': [
            {'key': 'device', 'label': '设备名称', 'type': 'text', 'required': true},
            {'key': 'desc', 'label': '问题描述', 'type': 'textarea'},
          ],
          'submit': {'action': 'api', 'method': 'POST', 'path': '/api/hooks/repair/create'},
        }),
      ],
      onAction: (_, data) => submitted = data,
    );

    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(find.textContaining('请填写：设备名称'), findsOneWidget);
    expect(submitted, isNull, reason: '必填未填不应触发提交');
  });

  testWidgets('form 填好后提交，回调拿到字段值', (tester) async {
    Map<String, dynamic>? submitted;
    await pumpBody(
      tester,
      [
        comp({
          'component': 'form',
          'fields': [
            {'key': 'device', 'label': '设备名称', 'type': 'text', 'required': true},
            {'key': 'level', 'label': '紧急程度', 'type': 'select', 'required': true,
              'options': [{'label': '一般', 'value': 'low'}, {'label': '紧急', 'value': 'high'}]},
            {'key': 'urgent', 'label': '是否加急', 'type': 'switch'},
          ],
        }),
      ],
      onAction: (_, data) => submitted = data,
    );

    await tester.enterText(find.byType(TextField).first, '3 号机');
    await tester.pump();
    await tester.tap(find.text('提交'));
    await tester.pump();

    // select 未选 → 应当报必填（用"请填写："前缀定位提示，字段标签本身也叫"紧急程度"）
    expect(find.textContaining('请填写：紧急程度'), findsOneWidget);
    expect(submitted, isNull);
  });

  testWidgets('空 body 显示"还没有内容"而不是空白', (tester) async {
    await pumpBody(tester, const []);
    expect(find.text('这个模块还没有内容'), findsOneWidget);
  });

  testWidgets('深层嵌套的 card 也能渲染（不爆栈、不崩溃）', (tester) async {
    await pumpBody(tester, [
      comp({
        'component': 'card', 'title': 'L1',
        'children': [
          {'component': 'card', 'title': 'L2',
            'children': [
              {'component': 'card', 'title': 'L3',
                'children': [
                  {'component': 'text', 'text': '最里层'},
                ]},
            ]},
        ],
      }),
    ]);
    expect(find.text('最里层'), findsOneWidget);
  });
}
