import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一套皮肤 = 一份完整的色板。
///
/// 字段与原来的 AppColors 一一对应（连顺序都一致），
/// 这样 [AppColors._assign] 就是一个直白的赋值表，不会漏。
class AppPalette {
  const AppPalette({
    required this.name,
    required this.label,
    required this.isLight,
    required this.bg,
    required this.bgElevated,
    required this.surface,
    required this.surfaceHi,
    required this.divider,
    required this.border,
    required this.text,
    required this.textSub,
    required this.textWeak,
    required this.brand,
    required this.brand2,
    required this.online,
    required this.danger,
    required this.warn,
    required this.bubbleOther,
  });

  /// 存进 SharedPreferences 的键。
  ///
  /// 🔴 这两个老名字（'dark'/'light'）**必须继续认**：v0.28.5 就已经把
  ///    它们写进用户机器了，改名会让升级上来的用户皮肤被打回默认。
  final String name;

  /// 选择面板上给人看的名字。
  final String label;

  /// 明 / 暗。决定状态栏图标、ThemeData.brightness、AppSemantic 走哪套。
  ///
  /// 🔴 早期只有深浅两套，代码里到处写 `p == AppPalette.light` 来判断明暗。
  ///    现在浅色不止一套了，那种写法会把「纸白」「暖沙」误判成深色 ——
  ///    状态栏图标颜色反了、ThemeData 亮度反了。一律走这个字段。
  final bool isLight;

  // 背景层次（由深到浅）
  final Color bg;
  final Color bgElevated;
  final Color surface;
  final Color surfaceHi;

  // 分割线 / 描边
  final Color divider;
  final Color border;

  // 文字
  final Color text;
  final Color textSub;
  final Color textWeak;

  // 品牌色（青绿 → 青蓝，跟米聊/微信/QQ/钉钉/飞书的红蓝绿都明确区分）
  final Color brand;
  final Color brand2;

  // 语义色
  final Color online;
  final Color danger;
  final Color warn;

  // 气泡
  final Color bubbleOther;

  /// ① 极夜青（默认）。原来的 AppColors 常量的值原样搬到这里。
  static const dark = AppPalette(
    name: 'dark',
    label: '极夜青',
    isLight: false,
    bg: Color(0xFF0E1015),
    bgElevated: Color(0xFF141821),
    surface: Color(0xFF1A1F2A),
    surfaceHi: Color(0xFF232936),
    divider: Color(0xFF262C38),
    border: Color(0xFF2E3543),
    text: Color(0xFFE9ECF3),
    textSub: Color(0xFF98A1B3),
    textWeak: Color(0xFF6B7484),
    brand: Color(0xFF10B981),
    brand2: Color(0xFF06B6D4),
    online: Color(0xFF14B8A6),
    danger: Color(0xFFF4685E),
    warn: Color(0xFFE8A33D),
    bubbleOther: Color(0xFF212734),
  );

  /// ② 午夜蓝。底色偏蓝紫，品牌色换成靛蓝→紫，
  ///    跟极夜青的青绿明确区分 —— 两套都深色，靠品牌色辨认。
  static const midnight = AppPalette(
    name: 'midnight',
    label: '午夜蓝',
    isLight: false,
    bg: Color(0xFF0B1020),
    bgElevated: Color(0xFF111834),
    surface: Color(0xFF161E3D),
    surfaceHi: Color(0xFF1F294F),
    divider: Color(0xFF242E52),
    border: Color(0xFF2C3760),
    text: Color(0xFFE7EAF6),
    textSub: Color(0xFF9AA3C4),
    textWeak: Color(0xFF6C7597),
    brand: Color(0xFF6366F1),
    brand2: Color(0xFFA855F7),
    online: Color(0xFF22D3EE),
    danger: Color(0xFFFB7185),
    warn: Color(0xFFFBBF24),
    bubbleOther: Color(0xFF1C2547),
  );

  /// ③ 墨玉。接近纯黑的中性灰阶 + 琥珀金强调色。
  ///    存在的理由：有人在 OLED 屏上嫌极夜青"发蓝发紫"，要一套不带色偏的黑。
  static const ink = AppPalette(
    name: 'ink',
    label: '墨玉',
    isLight: false,
    bg: Color(0xFF0A0A0A),
    bgElevated: Color(0xFF121212),
    surface: Color(0xFF171717),
    surfaceHi: Color(0xFF212121),
    divider: Color(0xFF262626),
    border: Color(0xFF333333),
    text: Color(0xFFF0F0F0),
    textSub: Color(0xFFA3A3A3),
    textWeak: Color(0xFF707070),
    brand: Color(0xFFF59E0B),
    brand2: Color(0xFFF97316),
    online: Color(0xFF10B981),
    danger: Color(0xFFEF4444),
    warn: Color(0xFFEAB308),
    bubbleOther: Color(0xFF1E1E1E),
  );

  /// ④ 晨光青。品牌色/语义色都刻意加深一档 —— 亮色在白底上原样用会发灰、
  ///    对比度不够，而按钮和警示必须一眼看清。
  static const light = AppPalette(
    name: 'light',
    label: '晨光青',
    isLight: true,
    bg: Color(0xFFF2F4F7),
    bgElevated: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceHi: Color(0xFFE9EDF2),
    divider: Color(0xFFE2E6EC),
    border: Color(0xFFD3D9E0),
    text: Color(0xFF1B2330),
    textSub: Color(0xFF5B6575),
    // 原 #8B94A3：在 #F2F4F7 底上对比度只有 2.78，低于 3.0 ——
    // 占位符/时间戳这类弱化文字在亮处会糊掉。加深两档到 #7C8595（3.38），
    // 肉眼仍是一眼"次要信息"的灰，但看得清了。
    textWeak: Color(0xFF7C8595),
    brand: Color(0xFF0DA46E),
    brand2: Color(0xFF0E93C2),
    online: Color(0xFF0E9384),
    danger: Color(0xFFD64541),
    warn: Color(0xFFC07A12),
    bubbleOther: Color(0xFFFFFFFF),
  );

  /// ⑤ 纸白。冷白纸感 + 靛蓝品牌色（与午夜蓝同一支色系，明暗成对）。
  static const paper = AppPalette(
    name: 'paper',
    label: '纸白',
    isLight: true,
    bg: Color(0xFFF4F6FA),
    bgElevated: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceHi: Color(0xFFE8ECF4),
    divider: Color(0xFFDFE5EF),
    border: Color(0xFFCBD3E1),
    text: Color(0xFF16203A),
    textSub: Color(0xFF55618A),
    // #8590AE 在 #F4F6FA 上只有 2.94，差 3.0 一点点。降到 #7E8AA8（3.19）。
    textWeak: Color(0xFF7E8AA8),
    brand: Color(0xFF4F46E5),
    brand2: Color(0xFF7C3AED),
    online: Color(0xFF059669),
    danger: Color(0xFFDC2626),
    warn: Color(0xFFD97706),
    bubbleOther: Color(0xFFFFFFFF),
  );

  /// ⑥ 暖沙。米黄纸底 + 赭橙。
  ///    存在的理由：户外强光下冷白底反光刺眼，暖底 + 稍低的对比更耐看。
  static const sand = AppPalette(
    name: 'sand',
    label: '暖沙',
    isLight: true,
    bg: Color(0xFFF7F3EC),
    bgElevated: Color(0xFFFFFDF8),
    surface: Color(0xFFFFFFFF),
    surfaceHi: Color(0xFFEFE8DA),
    divider: Color(0xFFE4DBC9),
    border: Color(0xFFD2C5AC),
    text: Color(0xFF2B2419),
    textSub: Color(0xFF6B5F4B),
    // #9A8C74 对比度 2.977，差 3.0 一丁点。降到 #94876F（3.19）。
    textWeak: Color(0xFF94876F),
    brand: Color(0xFFB45309),
    brand2: Color(0xFFD97706),
    online: Color(0xFF15803D),
    danger: Color(0xFFC0392B),
    warn: Color(0xFFB45309),
    bubbleOther: Color(0xFFFFFFFF),
  );

  /// 选择面板的展示顺序：**先深色后浅色**，各自内部按"由保守到特别"排。
  /// 默认项（dark）放在第一个，用户找不到想要的时候退回来最近。
  static const List<AppPalette> all = [
    dark,
    midnight,
    ink,
    light,
    paper,
    sand,
  ];

  /// 按持久化名字取皮肤。
  ///
  /// 🔴 认不出的一律回落 [dark]，不抛 —— 老版本/手改配置/将来下线某套皮肤
  ///    都会走到这里，抛异常等于 App 起不来，不值当。
  static AppPalette byName(String? name) {
    if (name == null || name.isEmpty) return dark;
    for (final p in all) {
      if (p.name == name) return p;
    }
    return dark;
  }
}

/// 皮肤管理器：切换 + 持久化。
///
/// 🔴 换肤的原理：AppColors 的静态字段在 [apply] 里被**重新赋值**
///    （所以它们不是 const），根 widget 监听 [changed] 重建整棵树，
///    build 里读到的就是新色值。这样 1400 多处 `AppColors.bg`
///    一行都不用改 —— 全项目没有第二种"读当前主题色"的写法。
class AppSkin {
  AppSkin._();

  static const _kPref = 'xz_app_skin';

  /// 当前皮肤变化通知。根 MaterialApp 挂它重建。
  static final ValueNotifier<AppPalette> changed =
      ValueNotifier<AppPalette>(AppPalette.dark);

  static AppPalette get palette => changed.value;

  /// 当前是不是浅色皮肤。
  ///
  /// 🔴 早期写成 `palette == AppPalette.light`。浅色皮肤从 1 套变成 3 套之后，
  ///    那句对「纸白」「暖沙」会返回 false —— 状态栏图标、背景渐变方向
  ///    全跟着错。判断明暗只能看 [AppPalette.isLight]。
  static bool get isLight => palette.isLight;

  /// 启动时读持久化值。要在 runApp 之前调。
  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final name = p.getString(_kPref);
      apply(AppPalette.byName(name));
    } catch (_) {
      apply(AppPalette.dark);
    }
  }

  /// 切皮肤：改色板 + 写盘 + 通知重建。
  static Future<void> set(AppPalette p) async {
    if (identical(p, changed.value)) return;
    apply(p);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kPref, p.name);
    } catch (_) {}
  }

  /// 只改当前色板（不写盘）—— [load] 的冷启动路径用它。
  ///
  /// 🔴🔴 这里**必须**给 [changed] 赋值，否则换肤只生效一半。
  ///     v0.28.5 的 bug：apply 改了 AppColors 就收工，changed 一直是 dark。
  ///     于是 `AppSkin.palette` / `isLight` 永远返回深色，而根 MaterialApp
  ///     偏偏只听 changed —— 结果是「切了皮肤，只有正在看的那一页变色」。
  ///     那一页之所以会变，是因为它自己 setState 重建时读到了新的 AppColors；
  ///     其余页面（IndexedStack 里已经建好的、还没建过的）一概不动，
  ///     重启 App 才全变。桌面端一屏里同时铺着导航条 + 会话 + 聊天三块，
  ///     这个"只变一半"最难看，也最像"点了没反应"。
  static void apply(AppPalette p) {
    AppColors._assign(p);
    // Android 状态栏跟着换：深色皮肤用浅色图标，浅色皮肤用深色图标。
    // 只在 Android 上动 —— 桌面端系统没有这回事。
    if (Platform.isAndroid) {
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            p.isLight ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: p.bg,
        systemNavigationBarIconBrightness:
            p.isLight ? Brightness.dark : Brightness.light,
      ));
    }
    // 放最后：色值都就位了再广播，监听者重建时读到的才是这一套。
    changed.value = p;
  }
}

/// 全局设计系统：颜色 / 圆角 / 间距 / 渐变。
/// 界面里不要再硬编码颜色，统一从这里取，方便整体换肤。
///
/// 🔴 这些字段是 **static（非 const）**：换肤时由 [AppSkin.apply]
///    整体重写。所以本文件之外**没有任何 const 表达式可以含
///    `AppColors.`** —— 那会让 Dart 在编译期把色值焊死，换肤失效。
class AppColors {
  // 背景层次（由深到浅）
  static Color bg = AppPalette.dark.bg;
  static Color bgElevated = AppPalette.dark.bgElevated;
  static Color surface = AppPalette.dark.surface;
  static Color surfaceHi = AppPalette.dark.surfaceHi;

  // 分割线 / 描边
  static Color divider = AppPalette.dark.divider;
  static Color border = AppPalette.dark.border;

  // 文字
  static Color text = AppPalette.dark.text;
  static Color textSub = AppPalette.dark.textSub;
  static Color textWeak = AppPalette.dark.textWeak;

  // 品牌色（青绿 → 青蓝，跟米聊/微信/QQ/钉钉/飞书的红蓝绿都明确区分）
  static Color brand = AppPalette.dark.brand;
  static Color brand2 = AppPalette.dark.brand2;

  // 语义色
  static Color online = AppPalette.dark.online;
  static Color danger = AppPalette.dark.danger;
  static Color warn = AppPalette.dark.warn;

  // 气泡
  static Color bubbleOther = AppPalette.dark.bubbleOther;

  /// 换肤入口（只由 AppSkin 调）。
  static void _assign(AppPalette p) {
    bg = p.bg;
    bgElevated = p.bgElevated;
    surface = p.surface;
    surfaceHi = p.surfaceHi;
    divider = p.divider;
    border = p.border;
    text = p.text;
    textSub = p.textSub;
    textWeak = p.textWeak;
    brand = p.brand;
    brand2 = p.brand2;
    online = p.online;
    danger = p.danger;
    warn = p.warn;
    bubbleOther = p.bubbleOther;
  }

   AppColors._();
}

class AppRadii {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;
  static const double pill = 999;

  const AppRadii._();
}

class AppTheme {
  /// 品牌渐变（按钮、头像选中态、Logo 等）。
  /// getter 而不是 const —— 色值跟着当前皮肤走。
  static LinearGradient get brandGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppColors.brand, AppColors.brand2],
      );

  /// 整页背景渐变（登录/注册等）。深色皮肤"由浅入深"，
  /// 浅色皮肤反过来（由白入浅灰）—— 方向不能反，反了像光照错误。
  static LinearGradient get bgGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: AppSkin.isLight
            ? [Colors.white, AppColors.bg]
            : [const Color(0xFF171B26), AppColors.bg],
      );

  static BorderSide get cardBorder =>
      BorderSide(color: AppColors.border, width: 1);

  /// 按给定皮肤构造 ThemeData。
  ///
  /// 🔴 色值全部经参数 [p] 取，函数体里**不读 AppColors.\***（渐变 getter
  ///    除外）—— 换肤时 AppColors 与这个调用之间没有先后问题，
  ///    传进来的 [p] 就是"这一次 build 用的那一套"。
  static ThemeData build(AppPalette p) {
    final bright = p.isLight ? Brightness.light : Brightness.dark;
    final scheme = ColorScheme(
      brightness: bright,
      primary: p.brand,
      onPrimary: Colors.white,
      secondary: p.brand2,
      onSecondary: Colors.white,
      surface: p.surface,
      onSurface: p.text,
      error: p.danger,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: bright,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      splashFactory: InkSparkle.splashFactory,

      textTheme: ThemeData(brightness: bright).textTheme.apply(
            bodyColor: p.text,
            displayColor: p.text,
          ),

      appBarTheme: AppBarTheme(
        backgroundColor: p.bgElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: p.text,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: p.textSub, size: 22),
      ),

      // 填充式圆角输入框，去掉默认描边
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: TextStyle(color: p.textWeak, fontSize: 15),
        labelStyle: TextStyle(color: p.textSub, fontSize: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: AppColors.brand, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: p.danger, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: p.danger, width: 1.4),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.brand,
          foregroundColor: Colors.white,
          disabledBackgroundColor: p.surfaceHi,
          disabledForegroundColor: p.textWeak,
          elevation: 0,
          shadowColor: Colors.transparent,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.brand,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: p.textSub,
          hoverColor: p.surfaceHi,
          highlightColor: p.surfaceHi,
        ),
      ),

      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: p.bgElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
        ),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: p.text,
        ),
        contentTextStyle: TextStyle(fontSize: 14, color: p.textSub),
      ),

      dividerTheme: DividerThemeData(
        color: p.divider,
        thickness: 1,
        space: 1,
      ),

      listTileTheme: ListTileThemeData(
        iconColor: p.textSub,
        textColor: p.text,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.surfaceHi,
        contentTextStyle: TextStyle(color: p.text, fontSize: 14),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.brand,
        linearTrackColor: p.surfaceHi,
        circularTrackColor: Colors.transparent,
      ),

      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(p.surfaceHi),
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.all(6),
      ),

      // 动态模块用到的语义色令牌（见 AppSemantic 注释）。
      // 两套皮肤各自注册 —— Theme.of(context) 按当前主题解析。
      extensions: <ThemeExtension<dynamic>>[
        AppSemantic.forPalette(p),
      ],
    );
  }

  /// 旧入口（深色）。留着给测试和不想传参的调用点用。
  static ThemeData dark() => build(AppPalette.dark);

  const AppTheme._();
}

/// 语义色令牌 —— 专门给「动态模块」用。
///
/// 为什么要有这个类：动态页面（由服务端 JSON 描述）里**不允许写死色值**，
/// 只能写 `primary/muted/danger/success/warning` 这样的语义名。具体是哪个色，
/// 由这里按当前主题翻译。这样将来加亮色主题时，服务端一个字节都不用改，
/// 所有动态页面自动跟着主题走 —— 这就是 SPEC §4.3 拍板项 3 的落地方式。
///
/// 用 ThemeExtension 而不是直接读 AppColors：ThemeExtension 会被 Theme.of()
/// 按主题解析，将来 AppTheme.light() 注册自己的 AppSemantic.light 即可。
@immutable
class AppSemantic extends ThemeExtension<AppSemantic> {
  final Color success;
  final Color warning;
  final Color muted;      // 次要文字
  final Color cardBg;     // 卡片底色
  final Color cardBorder; // 卡片描边

  const AppSemantic({
    required this.success,
    required this.warning,
    required this.muted,
    required this.cardBg,
    required this.cardBorder,
  });

  /// 深色皮肤令牌。
  /// 🔴 不能是 const —— AppColors 的字段现在是运行时值（换肤要重写）。
  ///    但这两个实例本身的内容是固定的（直接引 AppPalette 常量），
  ///    所以照旧在类加载时算一次，之后不再变。
  static final dark = AppSemantic(
    success: AppPalette.dark.online,
    warning: AppPalette.dark.warn,
    muted: AppPalette.dark.textSub,
    cardBg: AppPalette.dark.surface,
    cardBorder: AppPalette.dark.border,
  );

  /// 浅色皮肤令牌（AppTheme.build 按当前皮肤注册）。
  static final light = AppSemantic(
    success: AppPalette.light.online,
    warning: AppPalette.light.warn,
    muted: AppPalette.light.textSub,
    cardBg: AppPalette.light.surface,
    cardBorder: AppPalette.light.border,
  );

  /// 按任意一套皮肤生成令牌。
  ///
  /// 🔴 早期只有两套，build 里直接三元选 dark/light。加到六套之后那种写法
  ///    会把四套新皮肤全错配成深色令牌 —— 动态模块的卡片底色、次要文字
  ///    在浅色皮肤上会变成深底浅字，等于动态页面换肤失效。
  ///    令牌内容本来就全部派生自 [AppPalette]，直接从 p 取即可，不需要注册表。
  static AppSemantic forPalette(AppPalette p) => AppSemantic(
        success: p.online,
        warning: p.warn,
        muted: p.textSub,
        cardBg: p.surface,
        cardBorder: p.border,
      );

  /// 取令牌；主题没注册时回落到深色（App 目前只有深色，行为不变）
  static AppSemantic of(BuildContext context) =>
      Theme.of(context).extension<AppSemantic>() ?? dark;

  @override
  AppSemantic copyWith({
    Color? success,
    Color? warning,
    Color? muted,
    Color? cardBg,
    Color? cardBorder,
  }) =>
      AppSemantic(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        muted: muted ?? this.muted,
        cardBg: cardBg ?? this.cardBg,
        cardBorder: cardBorder ?? this.cardBorder,
      );

  @override
  AppSemantic lerp(ThemeExtension<AppSemantic>? other, double t) {
    if (other is! AppSemantic) return this;
    return AppSemantic(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      cardBg: Color.lerp(cardBg, other.cardBg, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
    );
  }
}
