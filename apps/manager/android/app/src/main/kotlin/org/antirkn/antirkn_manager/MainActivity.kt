package org.antirkn.antirkn_manager

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val reader = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var pickingKey = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.antirkn/template_picker")
            .setMethodCallHandler { call, result ->
                if (call.method != "pick" && call.method != "pickKey") {
                    result.notImplemented()
                } else if (pending != null) {
                    result.error("picker_busy", null, null)
                } else {
                    pending = result
                    pickingKey = call.method == "pickKey"
                    // Providers report YAML as application/yaml, text/plain or octet-stream.
                    // Validate the returned display name before reading any content.
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    try {
                        startActivityForResult(intent, PICK_TEMPLATE)
                    } catch (_: Exception) {
                        finishPick(error = "template_read_error")
                    }
                }
            }
    }

    @Deprecated("Activity result bridge for the Flutter host")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_TEMPLATE || pending == null) return
        if (resultCode != Activity.RESULT_OK) {
            finishPick()
            return
        }
        val uri = data?.data
        if (uri == null) {
            finishPick(error = "template_read_error")
            return
        }
        reader.execute {
            try {
                val name = contentResolver.query(
                    uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
                )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
                if (name == null || (!pickingKey && name.substringAfterLast('.').lowercase(Locale.ROOT)
                    !in setOf("yml", "yaml"))) {
                    runOnUiThread { finishPick(error = "invalid_template_extension") }
                    return@execute
                }
                val bytes = contentResolver.openInputStream(uri)?.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (output.size() + count > MAX_BYTES) {
                            runOnUiThread { finishPick(error = "template_size_limit") }
                            return@execute
                        }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                } ?: throw IllegalStateException()
                runOnUiThread { finishPick(mapOf("name" to name, "bytes" to bytes)) }
            } catch (_: Exception) {
                runOnUiThread { finishPick(error = "template_read_error") }
            }
        }
    }

    private fun finishPick(value: Any? = null, error: String? = null) {
        val result = pending ?: return
        pending = null
        if (error == null) result.success(value) else result.error(error, null, null)
    }

    override fun onDestroy() {
        finishPick(error = "template_read_error")
        reader.shutdownNow()
        super.onDestroy()
    }

    companion object {
        private const val PICK_TEMPLATE = 7142
        private const val MAX_BYTES = 256 * 1024
    }
}
