package org.antirkn.antirkn_manager

import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.media.AudioManager
import android.view.HapticFeedbackConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Uses the same semantic feedback as the eBookSender catalogue. */
class SelectionHaptics(activity: Activity, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "org.antirkn/haptics").setMethodCallHandler { call, result ->
            val kind = when (call.method) {
                "press" -> HapticFeedbackConstants.VIRTUAL_KEY
                "dragStart" -> HapticFeedbackConstants.LONG_PRESS
                "dragTick" -> HapticFeedbackConstants.CLOCK_TICK
                else -> { result.notImplemented(); return@setMethodCallHandler }
            }
            val notifications = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val quiet = notifications.currentInterruptionFilter !in setOf(
                NotificationManager.INTERRUPTION_FILTER_ALL,
                NotificationManager.INTERRUPTION_FILTER_UNKNOWN
            ) || audio.ringerMode == AudioManager.RINGER_MODE_SILENT
            if (!quiet || call.method != "press") {
                activity.window.decorView.performHapticFeedback(kind)
            }
            result.success(null)
        }
    }
}
