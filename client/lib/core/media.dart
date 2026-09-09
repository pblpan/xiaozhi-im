import 'dart:io';
import 'package:image/image.dart' as img;
import 'net.dart';

/// 上传前的图片处理：
/// - 内网（局域网）：原图直传，不压缩
/// - 外网/公网：缩到最长边 1600 + 重编码（jpeg q82 / png level6），没变小就用原图
class Media {
  static const int _maxSide = 1600;
  static const int _jpgQuality = 82;
  static const _imgExt = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};

  static Future<File> prepareForUpload(File f) async {
    if (Net.isLan) return f; // 内网：不压缩
    final ext = _ext(f.path);
    if (!isImageExt(ext)) return f; // 非图片不处理
    try {
      final bytes = await f.readAsBytes();
      final src = img.decodeImage(bytes);
      if (src == null) return f; // 解码不了（如 heic）就原样传

      img.Image out = src;
      if (src.width > _maxSide || src.height > _maxSide) {
        out = img.copyResize(
          src,
          width: src.width >= src.height ? _maxSide : null,
          height: src.height > src.width ? _maxSide : null,
        );
      }

      final List<int> data;
      final String newExt;
      if (ext == 'png') {
        data = img.encodePng(out, level: 6); // png 保留透明通道
        newExt = 'png';
      } else {
        data = img.encodeJpg(out, quality: _jpgQuality);
        newExt = 'jpg';
      }
      if (data.length >= bytes.length) return f; // 压缩没收益就用原图

      final tmp = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}xz_up_${DateTime.now().millisecondsSinceEpoch}.$newExt');
      await tmp.writeAsBytes(data);
      return tmp;
    } catch (_) {
      return f; // 压缩失败不阻塞上传
    }
  }

  static String _ext(String p) {
    final i = p.lastIndexOf('.');
    return i < 0 ? '' : p.substring(i + 1).toLowerCase();
  }

  static bool isImageExt(String ext) => _imgExt.contains(ext);

  /// mime 缺失时按扩展名兜底判断是否为图片
  static bool isImagePath(String p) => isImageExt(_ext(p));
}
