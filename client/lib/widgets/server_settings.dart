import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/settings.dart';
import 'package:xiaozhi_im_client/core/theme.dart';

/// 服务器地址设置弹窗。
/// 返回 true 表示地址被修改（调用方需处理重连 / 重新登录）。
Future<bool?> showServerSettings(BuildContext context) {
  final ctrl = TextEditingController(text: Config.baseUrl);
  String? testResult;
  bool testing = false;

  return showDialog<bool>(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
        contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
        title: const Text('服务器设置'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: '192.168.31.44:3602',
                  helperText: '支持 http / https，不带 http:// 会自动补上',
                  helperStyle:
                      const TextStyle(fontSize: 11.5, color: AppColors.textWeak),
                  prefixIcon: const Icon(Icons.dns_rounded,
                      size: 19, color: AppColors.textWeak),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '打包内置：${Config.builtInBaseUrl}',
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textWeak),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      ctrl.text = Config.builtInBaseUrl;
                      set(() => testResult = null);
                    },
                    child: const Text('用内置地址', style: TextStyle(fontSize: 12.5)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: testing
                    ? null
                    : () async {
                        set(() {
                          testing = true;
                          testResult = null;
                        });
                        try {
                          await ImApi.testServer(ctrl.text);
                          if (c.mounted) set(() => testResult = 'ok');
                        } catch (e) {
                          if (c.mounted) {
                            set(() => testResult = e
                                .toString()
                                .replaceFirst('Exception: ', ''));
                          }
                        } finally {
                          if (c.mounted) set(() => testing = false);
                        }
                      },
                icon: testing
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering_rounded, size: 17),
                label: const Text('测试连接'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.brand,
                  side: const BorderSide(color: AppColors.border),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.sm)),
                ),
              ),
              if (testResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(
                        testResult == 'ok'
                            ? Icons.check_circle_outline_rounded
                            : Icons.error_outline_rounded,
                        size: 16,
                        color: testResult == 'ok'
                            ? AppColors.online
                            : AppColors.danger,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          testResult == 'ok' ? '连接正常' : testResult!,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: testResult == 'ok'
                                ? AppColors.online
                                : AppColors.danger,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final next = Config.normalize(ctrl.text);
              if (next.isEmpty) return;
              final isSame = next == Config.baseUrl;
              if (isSame) {
                Navigator.pop(d, false);
                return;
              }
              await Settings.setServer(next);
              Config.baseUrl = next;
              if (d.mounted) Navigator.pop(d, true);
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brand,
              foregroundColor: Colors.white,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}
