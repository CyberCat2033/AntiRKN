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
    private var googleAuthorization: GoogleAuthorizationBridge? = null
    private var ipDiagnostics: IpDiagnosticsBridge? = null
    private var mihomoValidation: MihomoValidationBridge? = null
    private val reader = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var pickingKey = false
    private var backup = false
    private var exporting: ByteArray? = null
    private val handler = Handler(Looper.getMainLooper())
    private var requestId = 7142
    private var readTask: Future<*>? = null
    private var readSignal: CancellationSignal? = null
    private var deadline: Runnable? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        googleAuthorization = GoogleAuthorizationBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        SelectionHaptics(this, flutterEngine.dartExecutor.binaryMessenger)
        ipDiagnostics = IpDiagnosticsBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        mihomoValidation = MihomoValidationBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        AppUpdateBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.antirkn/template_picker")
            .setMethodCallHandler { call, result ->
                if (call.method == "cancelKey") {
                    if (pickingKey) finishPick(requestId)
                    result.success(null)
                } else if (call.method !in setOf("pick", "pickKey", "saveProfile", "pickBackup", "saveBackup")) {
                    result.notImplemented()
                } else if (pending != null) {
                    result.error("picker_busy", null, null)
                } else {
                    pending = result
                    pickingKey = call.method == "pickKey"
                    backup = call.method == "pickBackup" || call.method == "saveBackup"
                    val save = call.method == "saveProfile" || call.method == "saveBackup"
                    exporting = if (save) call.argument<ByteArray>("bytes") else null
                    if (save && (exporting == null || exporting!!.size > (if (backup) BACKUP_BYTES else 4 * 1024 * 1024))) {
                        finishPick(requestId, error = "template_size_limit")
                        return@setMethodCallHandler
                    }
                    requestId = if (requestId == 65534) 7142 else requestId + 1
                    // Providers report YAML as application/yaml, text/plain or octet-stream.
                    // Validate the returned display name before reading any content.
                    val intent = Intent(if (save) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = if (save && backup) "application/octet-stream" else if (save) "application/yaml" else "*/*"
                        if (save) putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
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
        if (googleAuthorization?.onActivityResult(requestCode, resultCode, data) == true) return
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
        val isBackup = backup
        val outputBytes = exporting?.copyOf()
        val signal = CancellationSignal()
        readSignal = signal
        deadline = Runnable { finishPick(requestCode, error = "template_read_error") }
        handler.postDelayed(deadline!!, if (isBackup) 120_000 else 20_000)
        readTask = reader.submit {
            try {
                if (outputBytes != null) {
                    contentResolver.openAssetFileDescriptor(uri, "wt", signal)?.use { descriptor ->
                        descriptor.createOutputStream().use { output ->
                            signal.throwIfCanceled()
                            output.write(outputBytes)
                            output.flush()
                        }
                    } ?: throw IllegalStateException()
                    runOnUiThread { finishPick(requestCode, true) }
                    return@submit
                }
                val name = contentResolver.query(
                    uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null, signal
                )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
                if (name == null || (!isKey && !isBackup && name.substringAfterLast('.').lowercase(Locale.ROOT)
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
                        if (output.size() + count > (if (isBackup) BACKUP_BYTES else MAX_BYTES)) {
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
            } finally {
                outputBytes?.fill(0)
            }
        }
    }

    private fun finishPick(id: Int, value: Any? = null, error: String? = null) {
        if (id != requestId) return
        val result = pending ?: return
        pending = null
        pickingKey = false
        backup = false
        exporting?.fill(0)
        exporting = null
        deadline?.let(handler::removeCallbacks)
        deadline = null
        readSignal?.cancel()
        readSignal = null
        readTask?.cancel(true)
        readTask = null
        if (error == null) result.success(value) else result.error(error, null, null)
    }

    override fun onDestroy() {
        mihomoValidation?.close()
        ipDiagnostics?.close()
        googleAuthorization?.dispose()
        googleAuthorization = null
        finishPick(requestId, error = "template_read_error")
        reader.shutdownNow()
        super.onDestroy()
    }

    companion object {
        private const val MAX_BYTES = 256 * 1024
        private const val BACKUP_BYTES = 64 * 1024 * 1024
    }
}
