package com.guozhigq.pilipala

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.speech.tts.TextToSpeech
import android.webkit.CookieManager
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : AudioServiceActivity() {
    private val asrOrigin = "https://asr.ieeio.com"
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val mlKitTranslators = ConcurrentHashMap<String, Translator>()
    private val mlKitExecutor = Executors.newFixedThreadPool(2)
    private val mediaStoreExecutor = Executors.newSingleThreadExecutor()
    private var japaneseReadingBridge: JapaneseReadingBridge? = null

    private fun normalizeMlKitLanguage(raw: String?, textForDetection: String? = null): String {
        val lang = raw?.trim()?.lowercase(Locale.ROOT)?.replace('_', '-') ?: ""
        if (lang.isNotEmpty() && lang != "auto") {
            if (lang.startsWith("zh") || lang.startsWith("cmn") || lang.startsWith("yue")) return "zh"
            val base = lang.split("-")[0]
            return when (base) {
                "fil" -> "tl"
                "iw" -> "he"
                "nb" -> "no"
                else -> base
            }
        }
        if (textForDetection != null && textForDetection.isNotEmpty()) {
            if (Regex("[\\u3040-\\u309F\\u30A0-\\u30FF]").containsMatchIn(textForDetection)) return "ja"
            if (Regex("[\\uAC00-\\uD7AF]").containsMatchIn(textForDetection)) return "ko"
            if (Regex("[\\u0400-\\u04FF]").containsMatchIn(textForDetection)) return "ru"
            if (Regex("[\\u0E00-\\u0E7F]").containsMatchIn(textForDetection)) return "th"
            if (Regex("[\\u0600-\\u06FF]").containsMatchIn(textForDetection)) return "ar"
            if (Regex("[\\u4E00-\\u9FA5]").containsMatchIn(textForDetection)) return "zh"
        }
        return "en"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        japaneseReadingBridge = JapaneseReadingBridge(flutterEngine.dartExecutor.binaryMessenger)

        tts = TextToSpeech(applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                ttsReady = true
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pilipala/mlkit_translate")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(true)
                    "getDownloadedModels" -> {
                        mlKitExecutor.execute {
                            try {
                                val manager = RemoteModelManager.getInstance()
                                val models = Tasks.await(manager.getDownloadedModels(TranslateRemoteModel::class.java), 10, TimeUnit.SECONDS)
                                val list = ArrayList<String>()
                                for (m in models) {
                                    list.add(m.language)
                                }
                                runOnUiThread { result.success(list) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("MODEL_ERROR", e.message, null) }
                            }
                        }
                    }
                    "isModelDownloaded" -> {
                        val lang = normalizeMlKitLanguage(call.argument<String>("lang"))
                        mlKitExecutor.execute {
                            try {
                                val manager = RemoteModelManager.getInstance()
                                val model = TranslateRemoteModel.Builder(lang).build()
                                val isDownloaded = Tasks.await(manager.isModelDownloaded(model), 10, TimeUnit.SECONDS)
                                runOnUiThread { result.success(isDownloaded) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("MODEL_ERROR", e.message, null) }
                            }
                        }
                    }
                    "downloadModel" -> {
                        val lang = normalizeMlKitLanguage(call.argument<String>("lang"))
                        val wifiOnly = call.argument<Boolean>("wifiOnly") ?: false
                        mlKitExecutor.execute {
                            try {
                                val manager = RemoteModelManager.getInstance()
                                val model = TranslateRemoteModel.Builder(lang).build()
                                val conditions = DownloadConditions.Builder()
                                if (wifiOnly) {
                                    conditions.requireWifi()
                                }
                                Tasks.await(manager.download(model, conditions.build()), 120, TimeUnit.SECONDS)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("DOWNLOAD_ERROR", e.message, null) }
                            }
                        }
                    }
                    "deleteModel" -> {
                        val lang = normalizeMlKitLanguage(call.argument<String>("lang"))
                        mlKitExecutor.execute {
                            try {
                                val it = mlKitTranslators.entries.iterator()
                                while (it.hasNext()) {
                                    val entry = it.next()
                                    if (entry.key.startsWith("${lang}_") || entry.key.endsWith("_${lang}")) {
                                        try { entry.value.close() } catch (_: Exception) {}
                                        it.remove()
                                    }
                                }
                                val manager = RemoteModelManager.getInstance()
                                val model = TranslateRemoteModel.Builder(lang).build()
                                Tasks.await(manager.deleteDownloadedModel(model), 10, TimeUnit.SECONDS)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("DELETE_ERROR", e.message, null) }
                            }
                        }
                    }
                    "translate" -> {
                        val text = call.argument<String>("text") ?: ""
                        if (text.isBlank()) {
                            result.success(text)
                            return@setMethodCallHandler
                        }
                        val source = normalizeMlKitLanguage(call.argument<String>("source"), text)
                        val target = normalizeMlKitLanguage(call.argument<String>("target") ?: "zh", null)
                        if (source == target) {
                            result.success(text)
                            return@setMethodCallHandler
                        }
                        val downloadIfNeeded = call.argument<Boolean>("downloadIfNeeded") ?: false
                        mlKitExecutor.execute {
                            try {
                                val key = "${source}_${target}"
                                var translator = mlKitTranslators[key]
                                if (translator == null) {
                                    val options = TranslatorOptions.Builder()
                                        .setSourceLanguage(source)
                                        .setTargetLanguage(target)
                                        .build()
                                    translator = Translation.getClient(options)
                                    mlKitTranslators[key] = translator
                                }
                                val manager = RemoteModelManager.getInstance()
                                if (downloadIfNeeded) {
                                    val conditions = DownloadConditions.Builder().build()
                                    Tasks.await(translator.downloadModelIfNeeded(conditions), 60, TimeUnit.SECONDS)
                                } else {
                                    for (code in arrayOf(source, target)) {
                                        if (code != "en") {
                                            val model = TranslateRemoteModel.Builder(code).build()
                                            val isDownloaded = Tasks.await(manager.isModelDownloaded(model), 5, TimeUnit.SECONDS)
                                            if (!isDownloaded) {
                                                throw IllegalStateException("MODEL_NOT_DOWNLOADED:$code")
                                            }
                                        }
                                    }
                                }
                                val translated = Tasks.await(translator.translate(text), 15, TimeUnit.SECONDS)
                                runOnUiThread { result.success(translated) }
                            } catch (e: Exception) {
                                val msg = e.message ?: e.toString()
                                runOnUiThread { result.error("TRANSLATION_ERROR", msg, null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pilipala/native_tts")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speak" -> {
                        val text = call.argument<String>("text") ?: ""
                        val lang = call.argument<String>("lang") ?: "zh-HK"
                        if (tts != null && text.isNotEmpty()) {
                            val locale = when (lang.lowercase()) {
                                "yue", "zh-hk", "zh_hk" -> {
                                    val yueLocale = Locale("yue", "HK")
                                    val zhHkLocale = Locale("zh", "HK")
                                    val yueCheck = tts?.isLanguageAvailable(yueLocale)
                                    val zhHkCheck = tts?.isLanguageAvailable(zhHkLocale)
                                    if (yueCheck == TextToSpeech.LANG_AVAILABLE || yueCheck == TextToSpeech.LANG_COUNTRY_AVAILABLE) {
                                        yueLocale
                                    } else if (zhHkCheck == TextToSpeech.LANG_AVAILABLE || zhHkCheck == TextToSpeech.LANG_COUNTRY_AVAILABLE) {
                                        zhHkLocale
                                    } else {
                                        // 手机系统 TTS 未安装粤语语音包，禁止回退成普通话！避免发出普通话发音让用户困惑
                                        result.success(false)
                                        return@setMethodCallHandler
                                    }
                                }
                                "en-gb", "uk" -> Locale.UK
                                "en-us", "us", "en" -> Locale.US
                                "ja", "ja-jp" -> Locale.JAPANESE
                                "ko", "ko-kr" -> Locale.KOREAN
                                "fr", "fr-fr" -> Locale.FRENCH
                                "de", "de-de" -> Locale.GERMAN
                                "it", "it-it" -> Locale.ITALIAN
                                "zh", "zh-cn" -> Locale.CHINESE
                                else -> {
                                    val custom = Locale(lang)
                                    val check = tts?.isLanguageAvailable(custom)
                                    if (check == TextToSpeech.LANG_AVAILABLE || check == TextToSpeech.LANG_COUNTRY_AVAILABLE) {
                                        custom
                                    } else {
                                        Locale.CHINESE
                                    }
                                }
                            }
                            tts?.language = locale
                            tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "pilipala_tts")
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        tts?.stop()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pilipala/ieeio_login")
            .setMethodCallHandler { call, result ->
                val manager = CookieManager.getInstance()
                val cookies = manager.getCookie(asrOrigin).orEmpty()
                    .split(';')
                    .map { it.trim().split('=', limit = 2) }
                    .filter {
                        it.size == 2 && it[1].isNotEmpty() &&
                            (it[0] == "token" || it[0] == "workflowToken")
                    }
                when (call.method) {
                    "readLoginToken" -> {
                        val token = cookies.firstOrNull { it[0] == "token" }
                            ?: cookies.firstOrNull { it[0] == "workflowToken" }
                        result.success(token?.get(1))
                    }
                    "clearRejectedLoginToken" -> {
                        val rejected = call.arguments as? String
                        val names = cookies.groupBy { it[0] }
                            .filterValues { values ->
                                values.all { Uri.decode(it[1]) == rejected }
                            }.keys
                        var remaining = names.size
                        if (remaining == 0) {
                            result.success(null)
                        } else {
                            for (name in names) {
                                manager.setCookie(asrOrigin, "$name=; Max-Age=0; Path=/; Secure") {
                                    if (--remaining == 0) result.success(null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pilipala/media_store")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exportToMediaStore" -> {
                        val filePath = call.argument<String>("filePath").orEmpty()
                        val displayName = call.argument<String>("displayName").orEmpty()
                        val subDir = call.argument<String>("subDir") ?: "PiliPala"
                        val kind = call.argument<String>("kind") ?: "video"
                        mediaStoreExecutor.execute {
                            try {
                                val saved = exportToMediaStore(filePath, displayName, subDir, kind)
                                runOnUiThread { result.success(saved?.let { mapOf("path" to it) }) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("MEDIA_STORE_ERROR", e.message, null) }
                            }
                        }
                    }
                    "deleteFromMediaStore" -> {
                        val targetPath = call.argument<String>("path").orEmpty()
                        mediaStoreExecutor.execute {
                            try {
                                val deleted = deleteFromMediaStore(targetPath)
                                runOnUiThread { result.success(mapOf("deleted" to deleted)) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("MEDIA_STORE_ERROR", e.message, null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        tts?.stop()
        tts?.shutdown()
        tts = null
        for (t in mlKitTranslators.values) {
            try { t.close() } catch (_: Exception) {}
        }
        mlKitTranslators.clear()
        mlKitExecutor.shutdown()
        mediaStoreExecutor.shutdown()
        japaneseReadingBridge?.close()
        super.onDestroy()
    }

    // region 公共媒体库登记（MediaStore）

    private fun mediaCollectionUri(kind: String): Uri {
        val volume = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.VOLUME_EXTERNAL_PRIMARY
        } else {
            MediaStore.VOLUME_EXTERNAL
        }
        return when (kind) {
            "audio" -> MediaStore.Audio.Media.getContentUri(volume)
            else -> MediaStore.Video.Media.getContentUri(volume)
        }
    }

    private fun mimeTypeFor(name: String, kind: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (kind) {
            "audio" -> when (ext) {
                "m4a", "aac" -> "audio/mp4"
                "opus" -> "audio/ogg"
                "flac" -> "audio/flac"
                "ec3", "eac3" -> "audio/eac3"
                "mp3" -> "audio/mpeg"
                else -> "audio/*"
            }
            else -> when (ext) {
                "mp4" -> "video/mp4"
                "m4s" -> "video/iso.segment"
                "webm" -> "video/webm"
                "mov" -> "video/quicktime"
                else -> "video/mp4"
            }
        }
    }

    /// 在公共媒体库中按文件名查找已存在记录，返回其 DATA 路径。
    private fun findExistingUri(collection: Uri, displayName: String): String? {
        return try {
            val projection = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DATA)
            val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ?"
            val selectionArgs = arrayOf(displayName)
            contentResolver.query(collection, projection, selection, selectionArgs, null)?.use { c ->
                if (c.moveToFirst()) {
                    val data = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                    if (data >= 0) c.getString(data) else null
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }

    /// 把私有目录下的源文件复制登记到公共 MediaStore，返回公共存储下的真实路径。
    /// 失败抛异常，由通道层回退为 null（保留私有目录原文件）。
    private fun exportToMediaStore(
        filePath: String,
        displayName: String,
        subDir: String,
        kind: String,
    ): String? {
        val source = File(filePath)
        if (!source.exists() || source.length() == 0L) return null

        val collection = mediaCollectionUri(kind)
        val mimeType = mimeTypeFor(displayName, kind)
        // RELATIVE_PATH 必须带合法媒体根目录前缀。注意：本机/该分区存储策略下
        // 视频集合只允许 DCIM / Movies / Pictures（不接受 Videos），音频用 Music。
        val baseRoot = if (kind == "audio") "Music" else "Movies"
        val trimmed = subDir.trim('/')
        val relativePath = if (trimmed.isNotBlank()) "$baseRoot/$trimmed/" else "$baseRoot/"

        // 已存在同名记录：直接复用，避免重复拷贝。
        findExistingUri(collection, displayName)?.let { return it }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        val uri: Uri = contentResolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert failed")

        try {
            contentResolver.openOutputStream(uri)?.use { out ->
                source.inputStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    var count: Int
                    while (input.read(buffer).also { count = it } > 0) {
                        out.write(buffer, 0, count)
                    }
                }
                out.flush()
            } ?: throw IllegalStateException("Open output stream failed")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val completed = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                contentResolver.update(uri, completed, null, null)
            }
        } catch (e: Exception) {
            // 登记失败要清理半成品，避免媒体库里留下打不开的占位文件。
            try { contentResolver.delete(uri, null, null) } catch (_: Exception) {}
            throw e
        }

        // 回读真实落盘路径（DATA 列），供 App 内离线播放/删除使用。
        val projection = arrayOf(MediaStore.MediaColumns.DATA)
        return contentResolver.query(uri, projection, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val idx = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                if (idx >= 0) c.getString(idx) else null
            } else null
        }
    }

    // endregion

    /// 按公共存储路径（DATA 列）从 MediaStore 删除记录及其文件。
    /// 同时检索视频、音频两个集合；找不到记录返回 false。
    private fun deleteFromMediaStore(targetPath: String): Boolean {
        if (targetPath.isBlank()) return false
        val collections = listOf(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
        )
        var deleted = 0
        for (collection in collections) {
            try {
                deleted += contentResolver.delete(
                    collection,
                    "${MediaStore.MediaColumns.DATA} = ?",
                    arrayOf(targetPath),
                )
            } catch (_: Exception) {}
        }
        return deleted > 0
    }
}
