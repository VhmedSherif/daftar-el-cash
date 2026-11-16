import base64
import glob
import os
from PIL import Image, ImageDraw

# 1. Install permanent Android signing keystore so all future APK updates succeed in-place
ks_dir = os.path.expanduser("~/.android")
os.makedirs(ks_dir, exist_ok=True)
raw_ks = open("signing_key.b64", encoding="utf-8").read()
open(os.path.join(ks_dir, "debug.keystore"), "wb").write(base64.b64decode("".join(raw_ks.split())))

# 2. Configure AndroidManifest.xml (Arabic label + <queries> visibility for old app + LegacyExtractorService)
manifest_path = "app_build/android/app/src/main/AndroidManifest.xml"
ms = open(manifest_path, encoding="utf-8").read()
ms = ms.replace('android:label="daftar_el_cash"', 'android:label="دفتر الكاش"')

queries_extra = """        <package android:name="com.daftarelcash.app.daftar_el_cash" />
        <intent>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent>"""

if "<queries>" in ms:
    ms = ms.replace("<queries>", "<queries>\n" + queries_extra, 1)
else:
    ms = ms.replace("</manifest>", "    <queries>\n" + queries_extra + "\n    </queries>\n</manifest>")

service_xml = """        <service
            android:name=".LegacyExtractorService"
            android:label="دفتر الكاش - سحب البيانات القديمة"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"
            android:exported="true">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService" />
            </intent-filter>
            <meta-data
                android:name="android.accessibilityservice"
                android:resource="@xml/legacy_extractor_config" />
        </service>
    </application>"""

ms = ms.replace("</application>", service_xml, 1)
open(manifest_path, "w", encoding="utf-8").write(ms)

# 3. Write AccessibilityService XML config & Arabic description resource
res_dir = "app_build/android/app/src/main/res"
os.makedirs(os.path.join(res_dir, "xml"), exist_ok=True)
os.makedirs(os.path.join(res_dir, "values"), exist_ok=True)

schema_url = "ht" + "tp://schemas.android.com/apk/res/android"
open(os.path.join(res_dir, "xml", "legacy_extractor_config.xml"), "w", encoding="utf-8").write(
    f'''<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="{schema_url}"
    android:accessibilityEventTypes="typeWindowStateChanged|typeWindowContentChanged|typeViewScrolled"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagReportViewIds|flagRetrieveInteractiveWindows|flagIncludeNotImportantViews"
    android:canRetrieveWindowContent="true"
    android:canPerformGestures="true"
    android:notificationTimeout="80"
    android:description="@string/extractor_desc" />
'''
)

open(os.path.join(res_dir, "values", "extractor_strings.xml"), "w", encoding="utf-8").write(
    '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="extractor_desc">تقرأ هذه الخدمة معاملاتك وأرصدة الآجل من النسخة القديمة لتطبيق دفتر الكاش وتنقلها للنسخة الجديدة تلقائياً بأمان تام وبدون مسح أي شيء.</string>
</resources>
'''
)

# 4. Write LegacyExtractorService.kt and MainActivity.kt
kt_files = glob.glob("app_build/android/app/src/main/**/MainActivity.kt", recursive=True)
assert kt_files, "MainActivity.kt not found!"
kt_path = kt_files[0]
kt_dir = os.path.dirname(kt_path)
pkg_lines = [ln.strip() for ln in open(kt_path, encoding="utf-8") if ln.strip().startswith("package ")]
pkg_decl = pkg_lines[0] if pkg_lines else "package com.daftarelcash.v2.daftar_el_cash"

extractor_kt = f"""{pkg_decl}

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

class LegacyExtractorService : AccessibilityService() {{

    companion object {{
        private const val PREFS = "daftar_extractor"
        private const val KEY_FRAMES = "frames_json"

        @Volatile var autoSessionActive: Boolean = false
        @Volatile var targetDays: Int = 6

        fun startAutoSession(ctx: Context, days: Int = 6) {{
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_FRAMES, "[]")
                .apply()
            targetDays = days
            autoSessionActive = true
        }}

        fun readStoredFrames(ctx: Context): String {{
            return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_FRAMES, "[]") ?: "[]"
        }}

        fun clearStoredFrames(ctx: Context) {{
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_FRAMES, "[]")
                .apply()
        }}
    }}

    private val handler = Handler(Looper.getMainLooper())
    private val capturedFrames = ArrayList<JSONObject>()
    private var lastSavedSnapshotHash: Int = 0

    private var phase: Int = 0
    private var daysScanned: Int = 0
    private var scrollSteps: Int = 0
    private var lastMotionSig: String = ""
    private val expandedCustomers = HashSet<String>()
    private var loopRunning: Boolean = false

    private val months = listOf(
        "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
        "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"
    )
    private val weekdays = listOf(
        "الإثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت", "الأحد"
    )

    private fun isTargetOldApp(pkg: String?): Boolean {{
        if (pkg.isNullOrEmpty()) return false
        if (pkg == applicationContext.packageName) return false
        return pkg.contains("daftar_el_cash") || pkg.contains("daftarelcash")
    }}

    override fun onServiceConnected() {{
        super.onServiceConnected()
        Toast.makeText(applicationContext, "تم تفعيل خدمة سحب بيانات دفتر الكاش ✓", Toast.LENGTH_SHORT).show()
    }}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {{
        val root = rootInActiveWindow ?: return
        val pkg = root.packageName?.toString() ?: event?.packageName?.toString() ?: ""
        if (!isTargetOldApp(pkg)) return

        captureSnapshot(root)

        if (autoSessionActive && !loopRunning) {{
            beginAutoLoop()
        }}
    }}

    override fun onInterrupt() {{}}

    private fun beginAutoLoop() {{
        loopRunning = true
        phase = 0
        daysScanned = 0
        scrollSteps = 0
        lastMotionSig = ""
        expandedCustomers.clear()
        Toast.makeText(applicationContext, "جاري سحب معاملات وأرصدة النسخة القديمة تلقائياً... لا تلمس الشاشة لثوانٍ", Toast.LENGTH_LONG).show()
        handler.postDelayed(tickRunnable, 1300L)
    }}

    private val tickRunnable = object : Runnable {{
        override fun run() {{
            if (!autoSessionActive) {{
                loopRunning = false
                return
            }}
            val root = rootInActiveWindow
            val pkg = root?.packageName?.toString() ?: ""
            if (root == null || !isTargetOldApp(pkg)) {{
                handler.postDelayed(this, 700L)
                return
            }}

            val curSig = captureSnapshot(root)
            val dm = resources.displayMetrics
            val sw = dm.widthPixels.coerceAtLeast(720)
            val sh = dm.heightPixels.coerceAtLeast(1280)

            when (phase) {{
                0 -> {{
                    phase = 1
                    scrollSteps = 0
                    lastMotionSig = ""
                    handler.postDelayed(this, 450L)
                }}
                1 -> {{
                    if (scrollSteps >= 1 && (curSig == lastMotionSig || scrollSteps >= 12)) {{
                        daysScanned++
                        if (daysScanned < targetDays) {{
                            phase = 2
                            scrollSteps = 0
                            lastMotionSig = ""
                        }} else {{
                            phase = 3
                        }}
                        handler.postDelayed(this, 500L)
                    }} else {{
                        lastMotionSig = curSig
                        scrollSteps++
                        scrollScreen(root, forward = true, sw = sw, sh = sh)
                        handler.postDelayed(this, 750L)
                    }}
                }}
                2 -> {{
                    val dateNode = findDayHeaderNode(root, sh)
                    if (dateNode != null) {{
                        val dr = Rect()
                        dateNode.getBoundsInScreen(dr)
                        val prevBtn = findPrevDayButton(root, dr)
                        if (prevBtn != null) {{
                            clickNodeOrBounds(prevBtn)
                            phase = 1
                            scrollSteps = 0
                            lastMotionSig = ""
                            handler.postDelayed(this, 800L)
                        }} else {{
                            tapScreen((sw * 0.88f), dr.centerY().toFloat())
                            phase = 1
                            scrollSteps = 0
                            lastMotionSig = ""
                            handler.postDelayed(this, 800L)
                        }}
                    }} else if (scrollSteps < 10) {{
                        scrollSteps++
                        scrollScreen(root, forward = false, sw = sw, sh = sh)
                        handler.postDelayed(this, 650L)
                    }} else {{
                        phase = 3
                        handler.postDelayed(this, 500L)
                    }}
                }}
                3 -> {{
                    val debtsTab = findNodeByPredicate(root) {{ txt, r ->
                        txt.contains("الآجل والديون") && r.centerY() > sh * 0.78
                    }}
                    if (debtsTab != null) {{
                        clickNodeOrBounds(debtsTab)
                    }} else {{
                        tapScreen(sw * 0.50f, sh * 0.94f)
                    }}
                    phase = 4
                    scrollSteps = 0
                    lastMotionSig = ""
                    handler.postDelayed(this, 900L)
                }}
                4 -> {{
                    captureSnapshot(root)
                    val allChip = findNodeByPredicate(root) {{ txt, _ ->
                        txt.trim() == "الكل"
                    }}
                    if (allChip != null) {{
                        clickNodeOrBounds(allChip)
                    }}
                    phase = 5
                    scrollSteps = 0
                    lastMotionSig = ""
                    handler.postDelayed(this, 800L)
                }}
                5 -> {{
                    val expandedOne = tryExpandOneHistoryOnScreen(root)
                    if (expandedOne) {{
                        handler.postDelayed(this, 650L)
                    }} else if (scrollSteps >= 1 && (curSig == lastMotionSig || scrollSteps >= 22)) {{
                        phase = 6
                        handler.postDelayed(this, 450L)
                    }} else {{
                        lastMotionSig = curSig
                        scrollSteps++
                        scrollScreen(root, forward = true, sw = sw, sh = sh)
                        handler.postDelayed(this, 800L)
                    }}
                }}
                6 -> {{
                    autoSessionActive = false
                    loopRunning = false
                    persistFrames()
                    Toast.makeText(applicationContext, "اكتمل سحب البيانات بنجاح ✓ جاري فتح النسخة الجديدة...", Toast.LENGTH_LONG).show()
                    val backIntent = packageManager.getLaunchIntentForPackage(applicationContext.packageName)
                    if (backIntent != null) {{
                        backIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                        startActivity(backIntent)
                    }}
                }}
            }}
        }}
    }}

    private fun nodeLabel(n: AccessibilityNodeInfo): String {{
        val t = n.text?.toString()?.trim() ?: ""
        val cd = n.contentDescription?.toString()?.trim() ?: ""
        return when {{
            t.isNotEmpty() && cd.isNotEmpty() && t != cd -> "$cd\\n$t"
            cd.isNotEmpty() -> cd
            else -> t
        }}
    }}

    private fun isDayHeaderLabel(s: String): Boolean {{
        val clean = s.trim()
        if (clean.length > 45 || clean.contains("الباقي") || clean.contains("•") || clean.contains("←")) return false
        if (clean.startsWith("اليوم -")) return true
        val hasMonth = months.any {{ clean.contains(it) }}
        val hasWeekday = weekdays.any {{ clean.contains(it) }}
        return hasMonth && hasWeekday
    }}

    private fun findDayHeaderNode(root: AccessibilityNodeInfo, sh: Int): AccessibilityNodeInfo? {{
        return findNodeByPredicate(root) {{ txt, r ->
            r.centerY() in 60..(sh / 2) && isDayHeaderLabel(txt)
        }}
    }}

    private fun findPrevDayButton(root: AccessibilityNodeInfo, dateRect: Rect): AccessibilityNodeInfo? {{
        var best: AccessibilityNodeInfo? = null
        var bestDist = Int.MAX_VALUE
        fun walk(n: AccessibilityNodeInfo?, depth: Int) {{
            if (n == null || depth > 50) return
            if (n.isVisibleToUser && n.isClickable) {{
                val r = Rect()
                n.getBoundsInScreen(r)
                if (abs(r.centerY() - dateRect.centerY()) < 75 && r.centerX() > dateRect.right) {{
                    val dist = r.centerX() - dateRect.right
                    if (dist < bestDist) {{
                        bestDist = dist
                        best = n
                    }}
                }}
            }}
            for (i in 0 until n.childCount) {{
                walk(n.getChild(i), depth + 1)
            }}
        }}
        walk(root, 0)
        return best
    }}

    private fun findNodeByPredicate(
        root: AccessibilityNodeInfo,
        pred: (String, Rect) -> Boolean
    ): AccessibilityNodeInfo? {{
        var found: AccessibilityNodeInfo? = null
        fun walk(n: AccessibilityNodeInfo?, depth: Int) {{
            if (n == null || found != null || depth > 55) return
            if (n.isVisibleToUser) {{
                val lbl = nodeLabel(n)
                if (lbl.isNotEmpty()) {{
                    val r = Rect()
                    n.getBoundsInScreen(r)
                    if (pred(lbl, r)) {{
                        found = n
                        return
                    }}
                }}
            }}
            for (i in 0 until n.childCount) {{
                walk(n.getChild(i), depth + 1)
            }}
        }}
        walk(root, 0)
        return found
    }}

    private fun tryExpandOneHistoryOnScreen(root: AccessibilityNodeInfo): Boolean {{
        val custHeaders = ArrayList<Pair<String, Int>>()
        val histButtons = ArrayList<Pair<AccessibilityNodeInfo, Int>>()

        fun walk(n: AccessibilityNodeInfo?, depth: Int) {{
            if (n == null || depth > 55) return
            if (n.isVisibleToUser) {{
                val lbl = nodeLabel(n)
                if (lbl.isNotEmpty()) {{
                    val r = Rect()
                    n.getBoundsInScreen(r)
                    if (lbl.contains("(ليا عنده)") || lbl.contains("(عليا ليه)")) {{
                        custHeaders.add(Pair(lbl.lines().firstOrNull()?.trim() ?: lbl, r.centerY()))
                    }}
                    for (line in lbl.lines()) {{
                        val tl = line.trim()
                        if (tl.startsWith("الحركات (") && tl != "الحركات (0)") {{
                            histButtons.add(Pair(n, r.centerY()))
                        }}
                    }}
                }}
            }}
            for (i in 0 until n.childCount) {{
                walk(n.getChild(i), depth + 1)
            }}
        }}
        walk(root, 0)

        for ((btnNode, btnY) in histButtons) {{
            val owner = custHeaders
                .filter {{ it.second <= btnY + 20 }}
                .maxByOrNull {{ it.second }}
                ?.first ?: "y_$btnY"
            if (!expandedCustomers.contains(owner)) {{
                expandedCustomers.add(owner)
                if (clickNodeOrBounds(btnNode)) {{
                    return true
                }}
            }}
        }}
        return false
    }}

    private fun clickNodeOrBounds(node: AccessibilityNodeInfo): Boolean {{
        var cur: AccessibilityNodeInfo? = node
        var hops = 0
        while (cur != null && hops < 6) {{
            if (cur.isClickable && cur.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {{
                return true
            }}
            cur = cur.parent
            hops++
        }}
        val r = Rect()
        node.getBoundsInScreen(r)
        if (r.width() > 0 && r.height() > 0) {{
            return tapScreen(r.centerX().toFloat(), r.centerY().toFloat())
        }}
        return false
    }}

    private fun findScrollable(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {{
        var found: AccessibilityNodeInfo? = null
        fun walk(n: AccessibilityNodeInfo?, depth: Int) {{
            if (n == null || found != null || depth > 50) return
            if (n.isVisibleToUser && n.isScrollable) {{
                found = n
                return
            }}
            for (i in 0 until n.childCount) {{
                walk(n.getChild(i), depth + 1)
            }}
        }}
        walk(root, 0)
        return found
    }}

    private fun scrollScreen(root: AccessibilityNodeInfo, forward: Boolean, sw: Int, sh: Int) {{
        val sc = findScrollable(root)
        val action = if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        if (sc != null && sc.performAction(action)) {{
            return
        }}
        if (Build.VERSION.SDK_INT >= 24) {{
            val path = Path()
            val x = sw * 0.5f
            if (forward) {{
                path.moveTo(x, sh * 0.72f)
                path.lineTo(x, sh * 0.28f)
            }} else {{
                path.moveTo(x, sh * 0.32f)
                path.lineTo(x, sh * 0.76f)
            }}
            val stroke = GestureDescription.StrokeDescription(path, 0L, 300L)
            dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
        }}
    }}

    private fun tapScreen(x: Float, y: Float): Boolean {{
        if (Build.VERSION.SDK_INT < 24) return false
        val path = Path()
        path.moveTo(x, y)
        val stroke = GestureDescription.StrokeDescription(path, 0L, 60L)
        return dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }}

    private fun captureSnapshot(root: AccessibilityNodeInfo): String {{
        val arr = JSONArray()
        val sigBuilder = StringBuilder()

        fun walk(n: AccessibilityNodeInfo?, depth: Int) {{
            if (n == null || depth > 55) return
            if (n.isVisibleToUser) {{
                val lbl = nodeLabel(n)
                if (lbl.isNotEmpty()) {{
                    val r = Rect()
                    n.getBoundsInScreen(r)
                    if (r.width() > 0 && r.height() > 0) {{
                        val obj = JSONObject()
                        obj.put("t", lbl)
                        obj.put("x", r.centerX())
                        obj.put("y", r.centerY())
                        obj.put("top", r.top)
                        obj.put("bot", r.bottom)
                        arr.put(obj)
                        sigBuilder.append(lbl).append("@").append(r.top / 12).append("|")
                    }}
                }}
            }}
            for (i in 0 until n.childCount) {{
                walk(n.getChild(i), depth + 1)
            }}
        }}
        walk(root, 0)

        val sig = sigBuilder.toString()
        val h = sig.hashCode()
        if (arr.length() > 0 && h != lastSavedSnapshotHash && capturedFrames.size < 300) {{
            lastSavedSnapshotHash = h
            val frame = JSONObject()
            frame.put("nodes", arr)
            capturedFrames.add(frame)
            persistFrames()
        }}
        return sig
    }}

    private fun persistFrames() {{
        val out = JSONArray()
        for (f in capturedFrames) {{
            out.put(f)
        }}
        applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_FRAMES, out.toString())
            .apply()
    }}
}}
"""

main_activity_kt = f"""{pkg_decl}

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {{
    private var pendingResult: MethodChannel.Result? = null
    private var pendingContent: String? = null

    private fun isExtractorAccessibilityEnabled(): Boolean {{
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
        val full = "$packageName/${{LegacyExtractorService::class.java.name}}"
        val shortName = "$packageName/.LegacyExtractorService"
        return enabled.contains(full, ignoreCase = true) || enabled.contains(shortName, ignoreCase = true)
    }}

    private fun findOldAppLaunchIntent(): Intent? {{
        val direct = packageManager.getLaunchIntentForPackage("com.daftarelcash.app.daftar_el_cash")
        if (direct != null) return direct

        val mainIntent = Intent(Intent.ACTION_MAIN, null).apply {{
            addCategory(Intent.CATEGORY_LAUNCHER)
        }}
        val list = packageManager.queryIntentActivities(mainIntent, 0)
        for (ri in list) {{
            val pkg = ri.activityInfo.packageName ?: continue
            if (pkg == packageName) continue
            val lbl = ri.loadLabel(packageManager)?.toString() ?: ""
            if (pkg.contains("daftar_el_cash") || pkg.contains("daftarelcash") || lbl.contains("دفتر الكاش")) {{
                return packageManager.getLaunchIntentForPackage(pkg)
            }}
        }}
        return null
    }}

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daftar_el_cash/backup")
            .setMethodCallHandler {{ call, result ->
                when (call.method) {{
                    "isExtractorEnabled" -> {{
                        result.success(isExtractorAccessibilityEnabled())
                    }}
                    "openAccessibilitySettings" -> {{
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {{
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }}
                        startActivity(intent)
                        result.success(true)
                    }}
                    "openAppInfoSettings" -> {{
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {{
                            data = Uri.fromParts("package", packageName, null)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }}
                        startActivity(intent)
                        result.success(true)
                    }}
                    "launchOldAppAutoExtract" -> {{
                        val days = call.argument<Int>("days") ?: 6
                        val launch = findOldAppLaunchIntent()
                        if (launch == null) {{
                            result.success("NOT_FOUND")
                        }} else {{
                            LegacyExtractorService.startAutoSession(applicationContext, days)
                            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(launch)
                            result.success("STARTED")
                        }}
                    }}
                    "readExtractedFrames" -> {{
                        result.success(LegacyExtractorService.readStoredFrames(applicationContext))
                    }}
                    "clearExtractedFrames" -> {{
                        LegacyExtractorService.clearStoredFrames(applicationContext)
                        result.success(true)
                    }}
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
                    val bytes = contentResolver.openInputStream(data.data!!)?.use {{ it.readBytes() }}
                    if (bytes == null) {{
                        res?.success(null)
                    }} else if (bytes.size >= 16 && String(bytes, 0, 15, Charsets.US_ASCII) == "SQLite format 3") {{
                        val tmp = File(cacheDir, "import_legacy_${{System.currentTimeMillis()}}.db")
                        tmp.writeBytes(bytes)
                        res?.success("__SQLITE_FILE__:${{tmp.absolutePath}}")
                    }} else {{
                        res?.success(String(bytes, Charsets.UTF_8))
                    }}
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

open(os.path.join(kt_dir, "LegacyExtractorService.kt"), "w", encoding="utf-8").write(extractor_kt)
open(kt_path, "w", encoding="utf-8").write(main_activity_kt)

# 5. Generate Custom Vector Launcher Icons (Legacy + Adaptive)
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

open(os.path.join(res_dir, "values", "ic_launcher_bg.xml"), "w", encoding="utf-8").write(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n  <color name="ic_launcher_bg">#0F7268</color>\n</resources>\n'
)
os.makedirs(os.path.join(res_dir, "mipmap-anydpi-v26"), exist_ok=True)
open(os.path.join(res_dir, "mipmap-anydpi-v26", "ic_launcher.xml"), "w", encoding="utf-8").write(
    f'<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="{schema_url}">\n  <background android:drawable="@color/ic_launcher_bg"/>\n  <foreground android:drawable="@mipmap/ic_launcher_fg"/>\n</adaptive-icon>\n'
)
