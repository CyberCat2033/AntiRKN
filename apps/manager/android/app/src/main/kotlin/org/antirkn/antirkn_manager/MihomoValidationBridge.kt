package org.antirkn.antirkn_manager

import android.content.*
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MihomoValidationBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "org.antirkn/mihomo")
    private val handler = Handler(Looper.getMainLooper())
    private var active: Run? = null
    init {
        // Only stale private validator directories; no user files or vault.
        context.cacheDir.listFiles()?.filter {
            it.isDirectory && it.name.startsWith("mihomo-") &&
                System.currentTimeMillis() - it.lastModified() > 60_000
        }?.forEach { it.deleteRecursively() }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "validate" -> {
                    val id = call.argument<String>("id")
                    val path = call.argument<String>("path")
                    if (active != null || id == null || path == null) {
                        result.error("validator_busy", null, null)
                    } else {
                        val run = Run(id, path, result)
                        active = run
                        run.start()
                    }
                }
                "cancel" -> {
                    if (active?.id == call.argument<String>("id")) active?.cancel()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
    fun close() { active?.cancel(); channel.setMethodCallHandler(null) }

    private inner class Run(val id: String, val path: String, val result: MethodChannel.Result) : ServiceConnection {
        private var bound = false
        private var finished = false
        private var service: Messenger? = null
        private var response: String? = null
        private var cancelled = false
        private val timeout = Runnable { cancel() }
        private val death = IBinder.DeathRecipient { handler.postDelayed({ finish() }, 50) }
        private val reply = Messenger(object : Handler(Looper.getMainLooper()) {
            override fun handleMessage(message: Message) {
                if (active !== this@Run || finished) return
                response = message.data.getString("result")
            }
        })
        fun start() {
            handler.postDelayed(timeout, 18_000)
            try {
                bound = context.bindService(Intent(context, MihomoValidationService::class.java), this, Context.BIND_AUTO_CREATE)
                if (!bound) finish()
            } catch (_: Exception) { finish() }
        }
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            if (finished || cancelled) { finish(); return }
            try {
                binder.linkToDeath(death, 0)
                service = Messenger(binder)
                service!!.send(Message.obtain(null, 1).apply {
                    replyTo = reply
                    data = Bundle().apply { putString("path", path) }
                })
            } catch (_: Exception) { finish() }
        }
        override fun onServiceDisconnected(name: ComponentName) { handler.postDelayed({ finish() }, 50) }
        override fun onBindingDied(name: ComponentName) { finish() }
        override fun onNullBinding(name: ComponentName) { finish() }
        fun cancel() {
            cancelled = true
            try { service?.send(Message.obtain(null, 2)) } catch (_: Exception) { }
            finish()
        }
        private fun finish() {
            if (finished) return
            finished = true
            handler.removeCallbacks(timeout)
            if (bound) { bound = false; try { context.unbindService(this) } catch (_: Exception) { } }
            if (active === this) active = null
            val text = response
            if (!cancelled && text != null && text.length < 16_384) {
                try {
                    val json = JSONObject(text)
                    val values = mutableMapOf<String, Any?>()
                    for (key in listOf("status", "code", "version", "revision", "hash", "resourcesHash", "path")) {
                        if (json.has(key)) values[key] = json.getString(key)
                    }
                    result.success(values)
                } catch (_: Exception) { result.error("validator_failed", null, null) }
            } else { result.error(if (cancelled) "validator_cancelled" else "validator_failed", null, null) }
        }
    }
}
