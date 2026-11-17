package com.guozhigq.pilipala

import android.net.Uri
import android.speech.tts.TextToSpeech
import android.webkit.CookieManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : AudioServiceActivity() {
    private val asrOrigin = "https://asr.ieeio.com"
    private var tts: TextToSpeech? = null
    private var ttsReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        tts = TextToSpeech(applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                ttsReady = true
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
    }

    override fun onDestroy() {
        tts?.stop()
        tts?.shutdown()
        tts = null
        super.onDestroy()
    }
}
