import 'package:flutter/material.dart';

/// 全局设计系统：颜色 / 圆角 / 间距 / 渐变。
/// 界面里不要再硬编码颜色，统一从这里取，方便整体换肤。
class AppColors {
  // 背景层次（由深到浅）
  static const bg = Color(0xFF0E1015);
  static const bgElevated = Color(0xFF141821);
  static const surface = Color(0xFF1A1F2A);
  static const surfaceHi = Color(0xFF232936);

  // 分割线 / 描边
  static const divider = Color(0xFF262C38);
  static const border = Color(0xFF2E3543);

  // 文字
  static const text = Color(0xFFE9ECF3);
  static const textSub = Color(0xFF98A1B3);
  static const textWeak = Color(0xFF6B7484);

  // 品牌色（青绿 → 青蓝，跟米聊/微信/QQ/钉钉/飞书的红蓝绿都明确区分）
  static const brand = Color(0xFF10B981);
  static const brand2 = Color(0xFF06B6D4);

  // 语义色
  static const online = Color(0xFF14B8A6);
  static const danger = Color(0xFFF4685E);

  // 气泡
  static const bubbleOther = Color(0xFF212734);

  const AppColors._();
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
  /// 品牌渐变（按钮、头像选中态、Logo 等）
  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.brand, AppColors.brand2],
  );

  /// 深色背景渐变（登录/注册等整页背景）
  static const bgGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF171B26), AppColors.bg],
  );

  static const cardBorder = BorderSide(color: AppColors.border, width: 1);

  static ThemeData dark() {
    final scheme = ColorScheme.dark(
      primary: AppColors.brand,
      onPrimary: Colors.white,
      secondary: AppColors.brand2,
      onSecondary: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.text,
      error: AppColors.danger,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      canvasColor: AppColors.bg,
      splashFactory: InkSparkle.splashFactory,

      // 深色下默认文字已为浅色，这里只统一正文字号密度
      textTheme: ThemeData(brightness: Brightness.dark).textTheme.apply(
            bodyColor: AppColors.text,
            displayColor: AppColors.text,
          ),

      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.bgElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.text,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: AppColors.textSub, size: 22),
      ),

      // 填充式圆角输入框，去掉默认描边
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: const TextStyle(color: AppColors.textWeak, fontSize: 15),
        labelStyle: const TextStyle(color: AppColors.textSub, fontSize: 14),
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
          borderSide: const BorderSide(color: AppColors.brand, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.4),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.brand,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.surfaceHi,
          disabledForegroundColor: AppColors.textWeak,
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
          foregroundColor: AppColors.brand,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.textSub,
          hoverColor: AppColors.surfaceHi,
          highlightColor: AppColors.surfaceHi,
        ),
      ),

      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.bgElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.text,
        ),
        contentTextStyle:
            const TextStyle(fontSize: 14, color: AppColors.textSub),
      ),

      dividerTheme: const DividerThemeData(
        color: AppColors.divider,
        thickness: 1,
        space: 1,
      ),

      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.textSub,
        textColor: AppColors.text,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceHi,
        contentTextStyle: const TextStyle(color: AppColors.text, fontSize: 14),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.brand,
        linearTrackColor: AppColors.surfaceHi,
        circularTrackColor: Colors.transparent,
      ),

      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(AppColors.surfaceHi),
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.all(6),
      ),
    );
  }

  const AppTheme._();
}
