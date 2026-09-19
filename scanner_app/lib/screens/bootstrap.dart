import 'package:flutter/material.dart';

import '../core/builtin_master.dart';
import '../core/stock_master_repo.dart';
import '../core/theme.dart';

/// 开屏：把内置商品档案（好又多版）装进本地库，装完进主界面。
///
/// ── 为什么必须有这一屏 ────────────────────────────────────────
/// 内置档案 12.7 万条，解析 + 落库在手机上要跑十几秒。
/// 直接进主界面的话，员工打开 App、扫第一枪扫不出名字（库还没装完），
/// 他会认为"这 App 不认我们家的货"。所以开屏**把这件事做完再放行**。
///
/// ── 进度不是装饰 ──────────────────────────────────────────────
/// 十几秒没有任何反馈，正常人的反应是杀进程重装。所以每一步都要有数。
///
/// ── 失败必须能跳过 ────────────────────────────────────────────
/// 装载失败（安装包不完整、存储写不进去）**不能让 App 打不开**。
/// 给出「先进去」按钮：没有内置档案时照样能扫码，只是显示"未知条码"，
/// 员工还可以自己导 CSV —— 那是比"打不开"好得多的结果。
class BootstrapPage extends StatefulWidget {
  const BootstrapPage({super.key, required this.child});

  /// 装载完成后要去的主界面。
  final Widget child;

  @override
  State<BootstrapPage> createState() => _BootstrapPageState();
}

class _BootstrapPageState extends State<BootstrapPage> {
  String _msg = '正在准备…';
  double? _progress; // null = 还不知道总数（解析阶段）
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      // 问原生"APK 里有没有内置档案"（通用版没有 → 直接进）。
      // 不用构建参数判断的理由见 BuiltinMaster.hasBuiltin 的注释。
      if (!await BuiltinMaster.hasBuiltin()) {
        _go();
        return;
      }
      final n = await StockMasterRepo().countLocal();
      if (n > 0) {
        _go(); // 已经装过（或员工自己导过一份）：不重复装
        return;
      }

      if (!mounted) return;
      setState(() => _msg = '首次启动：正在读取商品档案…');

      final r = await BuiltinMaster.load(
        clearFirst: true,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _progress = total == 0 ? null : done / total;
            _msg = '正在装入商品档案  $done / $total';
          });
        },
      );

      if (!mounted) return;
      setState(() => _msg = '已装入 ${r.written} 个商品');
      // 让人看见"装完了"这句：立刻切走的话这屏一闪而过，
      // 员工会怀疑刚才那十几秒到底有没有装上。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _go();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _msg = '商品档案没装上';
      });
    }
  }

  void _go() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => widget.child),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inventory_2_outlined,
                  size: 56, color: AppColors.brand),
              const SizedBox(height: 24),
              Text(
                _msg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.text, fontSize: 15),
              ),
              const SizedBox(height: 20),
              if (_error == null)
                SizedBox(
                  width: 220,
                  child: LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: AppColors.bgElevated,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppColors.brand),
                  ),
                ),
              if (_error != null) ...[
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textWeak, fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 20),
                // 没有档案也能用：扫出来是"未知条码"，但可以自己导 CSV
                OutlinedButton(
                  onPressed: _go,
                  child: const Text('先进去（可稍后导入商档 CSV）'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
