import base64
import glob
import os
from PIL import Image, ImageDraw

# 1. Install permanent Android signing keystore so all future APK updates succeed in-place
ks_dir = os.path.expanduser("~/.android")
os.makedirs(ks_dir, exist_ok=True)
raw_ks = open("signing_key.b64", encoding="utf-8").read()
open(os.path.join(ks_dir, "debug.keystore"), "wb").write(base64.b64decode("".join(raw_ks.split())))

# 2. Set Arabic App Name in AndroidManifest.xml
manifest_path = "app_build/android/app/src/main/AndroidManifest.xml"
ms = open(manifest_path, encoding="utf-8").read()
ms = ms.replace('android:label="daftar_el_cash"', 'android:label="دفتر الكاش"')
open(manifest_path, "w", encoding="utf-8").write(ms)

# 3. Inject Native Android File Backup/Restore & Share MethodChannel into MainActivity.kt
kt_files = glob.glob("app_build/android/app/src/main/**/MainActivity.kt", recursive=True)
assert kt_files, "MainActivity.kt not found!"
kt_path = kt_files[0]
pkg_lines = [ln.strip() for ln in open(kt_path, encoding="utf-8") if ln.strip().startswith("package ")]
pkg_decl = pkg_lines[0] if pkg_lines else "package com.daftarelcash.v2.daftar_el_cash"

kt_code = f"""{pkg_decl}

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {{
    private var pendingResult: MethodChannel.Result? = null
    private var pendingContent: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daftar_el_cash/backup")
            .setMethodCallHandler {{ call, result ->
                when (call.method) {{
                    "saveBackupFile" -> {{
                        if (pendingResult != null) {{
                            result.error("BUSY", "عملية أخرى قيد التنفيذ", null)
                            return@setMethodCallHandler
                        }}
                        val fileName = call.argument<String>("fileName") ?: "daftar_el_cash_backup.json"
                        pendingContent = call.argument<String>("content") ?: "{{}}"
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {{
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/json"
                            putExtra(Intent.EXTRA_TITLE, fileName)
                        }}
                        startActivityForResult(intent, 9001)
                    }}
                    "pickBackupFile" -> {{
                        if (pendingResult != null) {{
                            result.error("BUSY", "عملية أخرى قيد التنفيذ", null)
                            return@setMethodCallHandler
                        }}
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {{
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }}
                        startActivityForResult(intent, 9002)
                    }}
                    "shareText" -> {{
                        val text = call.argument<String>("text") ?: ""
                        val title = call.argument<String>("title") ?: "نسخة احتياطية - دفتر الكاش"
                        val sendIntent = Intent(Intent.ACTION_SEND).apply {{
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, title)
                            putExtra(Intent.EXTRA_TEXT, text)
                        }}
                        startActivity(Intent.createChooser(sendIntent, title))
                        result.success(true)
                    }}
                    else -> result.notImplemented()
                }}
            }}
    }}

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {{
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 9001) {{
            val res = pendingResult
            val body = pendingContent ?: "{{}}"
            pendingResult = null
            pendingContent = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {{
                try {{
                    val uri = data.data!!
                    val stream = runCatching {{ contentResolver.openOutputStream(uri, "wt") }}.getOrElse {{ contentResolver.openOutputStream(uri) }}
                    stream?.use {{ out -> out.write(body.toByteArray(Charsets.UTF_8)) }}
                    res?.success(true)
                }} catch (e: Exception) {{
                    res?.error("WRITE_ERR", e.message, null)
                }}
            }} else {{
                res?.success(false)
            }}
        }} else if (requestCode == 9002) {{
            val res = pendingResult
            pendingResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {{
                try {{
                    val text = contentResolver.openInputStream(data.data!!)?.bufferedReader(Charsets.UTF_8)?.use {{ it.readText() }}
                    res?.success(text)
                }} catch (e: Exception) {{
                    res?.error("READ_ERR", e.message, null)
                }}
            }} else {{
                res?.success(null)
            }}
        }}
    }}
}}
"""
open(kt_path, "w", encoding="utf-8").write(kt_code)

# 4. Generate Custom Vector Launcher Icons (Legacy + Adaptive)
S = 1024
im = Image.new("RGB", (S, S), (15, 118, 110))
px = im.load()
for y in range(S):
    t = y / float(S - 1)
    c = (int(18 * (1 - t) + 9 * t), int(132 * (1 - t) + 84 * t), int(120 * (1 - t) + 77 * t))
    for x in range(S):
        px[x, y] = c

d = ImageDraw.Draw(im)
d.rounded_rectangle([266, 234, 666, 764], radius=64, fill=(7, 64, 58))
d.rounded_rectangle([396, 454, 734, 714], radius=52, fill=(7, 64, 58))
d.rounded_rectangle([250, 215, 650, 745], radius=60, fill=(212, 154, 58))
d.rounded_rectangle([312, 215, 645, 680], radius=48, fill=(248, 250, 252))
d.rectangle([302, 215, 318, 685], fill=(168, 112, 32))
d.rectangle([558, 215, 588, 395], fill=(224, 168, 72))
d.rounded_rectangle([282, 675, 632, 722], radius=22, fill=(226, 232, 240))
d.polygon([(335, 705), (378, 705), (378, 775), (356, 756), (335, 775)], fill=(230, 174, 76))

pts = [(455, 457), (555, 357), (598, 400), (702, 296)]
d.line(pts, fill=(238, 182, 82), width=42, joint="curve")
d.polygon([(655, 258), (772, 240), (754, 357)], fill=(238, 182, 82))

d.rounded_rectangle([382, 430, 715, 695], radius=48, fill=(13, 98, 90))
d.rounded_rectangle([398, 446, 705, 685], radius=42, fill=(248, 250, 252))
d.rounded_rectangle([398, 446, 556, 685], radius=42, fill=(222, 166, 70))
d.rectangle([490, 446, 556, 685], fill=(222, 166, 70))
d.rounded_rectangle([608, 530, 730, 606], radius=34, fill=(13, 98, 90))
d.rounded_rectangle([620, 542, 728, 594], radius=24, fill=(232, 178, 82))
d.ellipse([636, 555, 662, 581], fill=(162, 108, 30))

res_dir = "app_build/android/app/src/main/res"
resample = getattr(Image, "Resampling", Image).LANCZOS
bg_rgb = (15, 114, 104)

for folder, lsz, fsz in [
    ("mipmap-mdpi", 48, 108),
    ("mipmap-hdpi", 72, 162),
    ("mipmap-xhdpi", 96, 216),
    ("mipmap-xxhdpi", 144, 324),
    ("mipmap-xxxhdpi", 192, 432),
]:
    dp = os.path.join(res_dir, folder)
    os.makedirs(dp, exist_ok=True)
    im.resize((lsz, lsz), resample).save(os.path.join(dp, "ic_launcher.png"), format="PNG")
    fg = Image.new("RGB", (fsz, fsz), bg_rgb)
    isz = int(round(fsz * 0.78))
    fg.paste(im.resize((isz, isz), resample), ((fsz - isz) // 2, (fsz - isz) // 2))
    fg.save(os.path.join(dp, "ic_launcher_fg.png"), format="PNG")

os.makedirs(os.path.join(res_dir, "values"), exist_ok=True)
open(os.path.join(res_dir, "values", "ic_launcher_bg.xml"), "w", encoding="utf-8").write(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n  <color name="ic_launcher_bg">#0F7268</color>\n</resources>\n'
)
os.makedirs(os.path.join(res_dir, "mipmap-anydpi-v26"), exist_ok=True)
open(os.path.join(res_dir, "mipmap-anydpi-v26", "ic_launcher.xml"), "w", encoding="utf-8").write(
    '<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="ht' + 'tp://schemas.android.com/apk/res/android">\n  <background android:drawable="@color/ic_launcher_bg"/>\n  <foreground android:drawable="@mipmap/ic_launcher_fg"/>\n</adaptive-icon>\n'
)
