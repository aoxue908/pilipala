package com.guozhigq.pilipala

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class JapaneseReadingBridge(messenger: BinaryMessenger) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "pilipala/japanese_reading")
    private var tokenizer: JapaneseTokenizer? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "analyze") {
                result.notImplemented()
            } else {
                val text = call.argument<String>("text") ?: ""
                if (text.length > 4096) {
                    result.error("TOO_LONG", "Sentence too long", null)
                } else {
                    executor.execute {
                        try {
                            val engine = tokenizer ?: JapaneseTokenizer().also { tokenizer = it }
                            val tokens = engine.analyze(text)
                            main.post { result.success(tokens) }
                        } catch (error: Exception) {
                            main.post { result.error("ANALYSIS_FAILED", error.javaClass.simpleName, null) }
                        }
                    }
                }
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
