package org.antirkn.antirkn_manager

import android.app.Service
import android.content.Intent
import android.os.*
import java.io.File

/** One offline parser per process. Never starts a VPN service or applies YAML. */
class MihomoValidationService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var started = false
    private val messenger = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            if (message.what == 2) { terminate(); return }
            if (message.what != 1 || started) return
            started = true
            val reply = message.replyTo ?: run { terminate(); return }
            val path = message.data.getString("path") ?: run { terminate(); return }
            handler.postDelayed({ terminate() }, 16_000)
            Thread {
                val result = try {
                    val file = File(path).canonicalFile
                    val directory = file.parentFile!!
                    require(directory.parentFile == cacheDir.canonicalFile)
                    require(directory.name.startsWith("mihomo-") && file.name == "request.json")
                    require(file.length() <= 16 * 1024 * 1024)
                    System.loadLibrary("antirkn_mihomo")
                    val bytes = file.readBytes()
                    try { validateNative(bytes, File(directory, "core").path) }
                    finally { bytes.fill(0) }
                } catch (_: Throwable) { null }
                try {
                    reply.send(Message.obtain(null, 1).apply {
                        data = Bundle().apply { putString("result", result) }
                    })
                } catch (_: Exception) { /* Host is gone. */ }
                // Host waits for binder death before allowing the next run.
                handler.postDelayed({ terminate() }, 50)
            }.start()
        }
    })
    private external fun validateNative(request: ByteArray, directory: String): String?
    override fun onBind(intent: Intent): IBinder = messenger.binder
    override fun onDestroy() { terminate() }
    private fun terminate() { android.os.Process.killProcess(android.os.Process.myPid()) }
}
