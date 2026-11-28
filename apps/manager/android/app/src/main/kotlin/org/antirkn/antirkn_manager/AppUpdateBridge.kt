package org.antirkn.antirkn_manager

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Self-update through PackageInstaller. Before a session is opened the
 * downloaded APK must be this package, carry exactly the versionCode of the
 * signed manifest (higher than the installed one) and be signed by the same
 * certificate set as the installed app, whose SHA-256 must also match the
 * manifest. Only error codes cross the channel.
 */
class AppUpdateBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "org.antirkn/app_update")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var receiver: BroadcastReceiver? = null
    private val action = "${activity.packageName}.APP_UPDATE_STATUS"

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(info())
                "openInstallSettings" -> result.success(openSettings())
                "verify", "install" -> {
                    val path = call.argument<String>("path")
                    val versionCode = call.argument<Number>("versionCode")?.toLong()
                    val cert = call.argument<String>("certSha256")
                    if (path == null || versionCode == null || cert == null) {
                        result.error("update_install_failed", null, null)
                    } else if (call.method == "verify") {
                        worker.execute {
                            val code = verify(path, versionCode, cert)
                            main.post { if (code == null) result.success(null) else result.error(code, null, null) }
                        }
                    } else {
                        install(path, versionCode, cert, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun info(): Map<String, Any> {
        val installed = packageInfo(activity.packageName)
        return mapOf(
            "versionCode" to versionCode(installed),
            "versionName" to (installed.versionName ?: ""),
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
        )
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    private fun openSettings(): Boolean = try {
        activity.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
        )
        true
    } catch (_: Exception) {
        false
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(name: String): PackageInfo {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES
        else PackageManager.GET_SIGNATURES
        return activity.packageManager.getPackageInfo(name, flags)
    }

    @Suppress("DEPRECATION")
    private fun archiveInfo(path: String): PackageInfo? {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES
        else PackageManager.GET_SIGNATURES
        val info = activity.packageManager.getPackageArchiveInfo(path, flags) ?: return null
        info.applicationInfo?.sourceDir = path
        info.applicationInfo?.publicSourceDir = path
        return info
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    /** SHA-256 of each signing certificate; empty when unknown. */
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return emptySet()
            if (signing.hasMultipleSigners()) signing.apkContentsSigners else signing.signingCertificateHistory
        } else {
            info.signatures
        } ?: return emptySet()
        return signatures.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }.toSet()
    }

    private fun verify(path: String, expectedVersionCode: Long, certSha256: String): String? = try {
        val file = File(path)
        val cache = activity.cacheDir.canonicalFile
        if (!file.canonicalFile.startsWith(cache) || !file.isFile) {
            "update_install_failed"
        } else {
            val archive = archiveInfo(path)
            val installed = packageInfo(activity.packageName)
            val archiveSigners = archive?.let { signers(it) } ?: emptySet()
            val installedSigners = signers(installed)
            when {
                archive == null || archive.packageName != activity.packageName -> "update_package_mismatch"
                versionCode(archive) != expectedVersionCode || versionCode(archive) <= versionCode(installed) ->
                    "update_version_code"
                installedSigners.isEmpty() || archiveSigners != installedSigners ||
                    !installedSigners.contains(certSha256.lowercase()) -> "update_signer_mismatch"
                else -> null
            }
        }
    } catch (_: Exception) {
        "update_install_failed"
    }

    private fun install(path: String, versionCode: Long, cert: String, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("update_install_failed", null, null)
            return
        }
        if (!canInstall()) {
            result.success(if (openSettings()) "permission" else "permission_unavailable")
            return
        }
        pending = result
        register()
        worker.execute {
            val code = verify(path, versionCode, cert)
            if (code != null) {
                main.post { finish(error = code) }
                return@execute
            }
            try {
                val installer = activity.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(activity.packageName)
                val file = File(path)
                params.setSize(file.length())
                val id = installer.createSession(params)
                installer.openSession(id).use { session ->
                    file.inputStream().use { input ->
                        session.openWrite("base.apk", 0, file.length()).use { output ->
                            input.copyTo(output, 64 * 1024)
                            session.fsync(output)
                        }
                    }
                    val intent = Intent(action).setPackage(activity.packageName)
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                    val sender = PendingIntent.getBroadcast(activity, id, intent, flags)
                    session.commit(sender.intentSender)
                }
            } catch (_: Exception) {
                main.post { finish(error = "update_install_failed") }
            }
        }
    }

    private fun register() {
        if (receiver != null) return
        val created = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        @Suppress("DEPRECATION")
                        val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        try {
                            confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            activity.startActivity(confirm)
                        } catch (_: Exception) {
                            finish(error = "update_install_failed")
                        }
                    }
                    PackageInstaller.STATUS_SUCCESS -> finish(value = "installed")
                    PackageInstaller.STATUS_FAILURE_ABORTED -> finish(error = "update_install_aborted")
                    else -> finish(error = "update_install_failed")
                }
            }
        }
        receiver = created
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(created, IntentFilter(action), Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(created, IntentFilter(action))
        }
    }

    private fun finish(value: String? = null, error: String? = null) {
        val result = pending ?: return
        pending = null
        receiver?.let { try { activity.unregisterReceiver(it) } catch (_: Exception) {} }
        receiver = null
        if (error != null) result.error(error, null, null) else result.success(value)
    }
}
