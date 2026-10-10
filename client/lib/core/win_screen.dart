import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'win_ps.dart';

/// 截全屏（含本窗口以外的部分）+ 屏幕文字 OCR（Windows）。
///
/// 截图用 System.Drawing.CopyFromScreen（自带 SetProcessDPIAware，拿到的是
/// 物理像素）；OCR 用 Windows.Media.Ocr（系统级离线 OCR，中文 Windows 自带
/// 中文模型，不需要联网）。两者都借道 PowerShell（见 win_ps.dart 的说明）。
class WinScreen {
  /// 截取整个虚拟屏幕（多显示器会截全部），落一个临时 PNG 并返回路径。
  /// 失败返回 null（功能不可用 / 被拦截）。
  static Future<String?> captureScreen() async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, 'screenshot_${DateTime.now().millisecondsSinceEpoch}.png');
    final script = '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class DpiFix { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[DpiFix]::SetProcessDPIAware() | Out-Null
\$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
\$bmp = New-Object System.Drawing.Bitmap \$vs.Width, \$vs.Height
\$g = [System.Drawing.Graphics]::FromImage(\$bmp)
\$g.CopyFromScreen(\$vs.X, \$vs.Y, 0, 0, \$bmp.Size)
\$g.Dispose()
\$bmp.Save('$path', [System.Drawing.Imaging.ImageFormat]::Png)
\$bmp.Dispose()
Write-Output 'OK'
''';
    final out = await runPowerShell(script, timeout: const Duration(seconds: 20));
    if (out != 'OK' || !File(path).existsSync()) return null;
    return path;
  }

  /// 识别图片里的文字（离线，Windows.Media.Ocr）。
  /// 返回识别文本；系统没有可用语言包 / 功能不可用 → 返回 null。
  static Future<String?> recognizeText(String imagePath) async {
    final winPath = imagePath.replaceAll('/', '\\');
    final script = '''
\$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
\$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
\$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
\$null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]

\$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  \$_.Name -eq 'AsTask' -and \$_.GetParameters().Count -eq 1 -and
  \$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await(\$op, \$t) {
  \$task = \$asTask.MakeGenericMethod(\$t).Invoke(\$null, @(\$op))
  \$task.Wait(-1) | Out-Null
  \$task.Result
}

\$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync('$winPath')) ([Windows.Storage.StorageFile])
\$stream = Await (\$file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
\$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync(\$stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
\$bitmap = Await (\$decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
\$ocr = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (\$null -eq \$ocr) { Write-Output '__NO_OCR__'; exit 0 }
\$result = Await (\$ocr.RecognizeAsync(\$bitmap)) ([Windows.Media.Ocr.OcrResult])
\$obj = @{ text = \$result.Text; lines = @(\$result.Lines | ForEach-Object { \$_.Text }) }
\$obj | ConvertTo-Json -Compress -Depth 3
''';
    final j = await runPowerShellJson(script, timeout: const Duration(seconds: 30));
    if (j == null) return null;
    if (j['text'] == null) return null;
    final text = j['text'].toString();
    return text;
  }
}
