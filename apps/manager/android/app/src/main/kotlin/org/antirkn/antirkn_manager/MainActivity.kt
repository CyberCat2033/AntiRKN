package org.antirkn.antirkn_manager

import android.app.Activity
import android.content.Intent
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.Future

class MainActivity : FlutterActivity() {
    private val reader = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var pickingKey = false
    private val handler = Handler(Looper.getMainLooper())
    private var requestId = 7142
    private var readTask: Future<*>? = null
    private var readSignal: CancellationSignal? = null
    private var deadline: Runnable? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.antirkn/template_picker")
            .setMethodCallHandler { call, result ->
                if (call.method == "cancelKey") {
                    if (pickingKey) finishPick(requestId)
                    result.success(null)
                } else if (call.method != "pick" && call.method != "pickKey") {
                    result.notImplemented()
                } else if (pending != null) {
                    result.error("picker_busy", null, null)
                } else {
                    pending = result
                    pickingKey = call.method == "pickKey"
                    requestId = if (requestId == 65534) 7142 else requestId + 1
                    // Providers report YAML as application/yaml, text/plain or octet-stream.
                    // Validate the returned display name before reading any content.
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    try {
                        startActivityForResult(intent, requestId)
                    } catch (_: Exception) {
                        finishPick(requestId, error = "template_read_error")
                    }
                }
            }
    }

    @Deprecated("Activity result bridge for the Flutter host")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != requestId || pending == null) return
        if (resultCode != Activity.RESULT_OK) {
            finishPick(requestCode)
            return
        }
        val uri = data?.data
        if (uri == null) {
            finishPick(requestCode, error = "template_read_error")
            return
        }
        // Only the provider read is timed: browsing the system picker may take
        // as long as the user needs. Stale callbacks cannot finish a new request.
        val isKey = pickingKey
        val signal = CancellationSignal()
        readSignal = signal
        deadline = Runnable { finishPick(requestCode, error = "template_read_error") }
        handler.postDelayed(deadline!!, 20_000)
        readTask = reader.submit {
            try {
                val name = contentResolver.query(
                    uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null, signal
                )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
                if (name == null || (!isKey && name.substringAfterLast('.').lowercase(Locale.ROOT)
                    !in setOf("yml", "yaml"))) {
                    runOnUiThread { finishPick(requestCode, error = "invalid_template_extension") }
                    return@submit
                }
                val bytes = contentResolver.openAssetFileDescriptor(uri, "r", signal)?.use { descriptor ->
                  descriptor.createInputStream().use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        signal.throwIfCanceled()
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (output.size() + count > MAX_BYTES) {
                            runOnUiThread { finishPick(requestCode, error = "template_size_limit") }
                            return@submit
                        }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                  }
                } ?: throw IllegalStateException()
                runOnUiThread {
                    try {
                        finishPick(requestCode, mapOf("name" to name, "bytes" to bytes))
                    } finally {
                        bytes.fill(0)
                    }
                }
            } catch (_: Exception) {
                runOnUiThread { finishPick(requestCode, error = "template_read_error") }
            }
        }
    }

    private fun finishPick(id: Int, value: Any? = null, error: String? = null) {
        if (id != requestId) return
        val result = pending ?: return
        pending = null
        pickingKey = false
        deadline?.let(handler::removeCallbacks)
        deadline = null
        readSignal?.cancel()
        readSignal = null
        readTask?.cancel(true)
        readTask = null
        if (error == null) result.success(value) else result.error(error, null, null)
    }

    override fun onDestroy() {
        finishPick(requestId, error = "template_read_error")
        reader.shutdownNow()
        super.onDestroy()
    }

    companion object {
        private const val MAX_BYTES = 256 * 1024
    }
}
