package org.antirkn.antirkn_manager

import android.accounts.Account
import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.ClearTokenRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Scope
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Google owns account selection/consent and token renewal. No token on disk/logs. */
class GoogleAuthorizationBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val client = Identity.getAuthorizationClient(activity)
    private val channel = MethodChannel(messenger, "org.antirkn/google_authorization")
    private val handler = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var deadline: Runnable? = null
    private var lastToken: String? = null
    private var disposed = false
    private var requestedScopes = listOf(SCOPE)

    init {
        channel.setMethodCallHandler { call, result ->
            if (disposed) {
                result.error("google_unavailable", null, null)
            } else if (call.method == "clearToken") {
                val token = lastToken
                lastToken = null
                if (token == null) result.success(null)
                else client.clearToken(ClearTokenRequest.builder().setToken(token).build())
                    .addOnCompleteListener { result.success(null) }
            } else if (call.method != "authorize") {
                result.notImplemented()
            } else if (pending != null) {
                result.error("google_busy", null, null)
            } else {
                val interactive = call.argument<Boolean>("interactive") == true
                val email = call.argument<String>("email")
                if (email != null && (email.isEmpty() || email.length > 320)) {
                    result.error("google_configuration", null, null)
                    return@setMethodCallHandler
                }
                requestedScopes = if (call.argument<Boolean>("publications") == true) listOf(SCOPE, FILE_SCOPE) else listOf(SCOPE)
                val request = AuthorizationRequest.builder().setRequestedScopes(requestedScopes.map(::Scope))
                if (interactive) request.setPrompt(AuthorizationRequest.Prompt.SELECT_ACCOUNT)
                else if (email != null) request.setAccount(Account(email, "com.google"))
                else {
                    result.error("google_reauthorize", null, null)
                    return@setMethodCallHandler
                }
                pending = result
                deadline = Runnable { finish(error = "google_network") }
                handler.postDelayed(deadline!!, 60_000)
                try {
                    client.authorize(request.build()).addOnSuccessListener { authorization ->
                        if (pending !== result || disposed) return@addOnSuccessListener
                        if (authorization.hasResolution()) {
                            if (!interactive) finish(error = "google_reauthorize")
                            else {
                                deadline?.let(handler::removeCallbacks)
                                deadline = null
                                try {
                                    activity.startIntentSenderForResult(authorization.pendingIntent!!.intentSender,
                                        REQUEST_CODE, null, 0, 0, 0)
                                } catch (_: Exception) { finish(error = "google_unavailable") }
                            }
                        } else complete(authorization)
                    }.addOnFailureListener { error ->
                        if (pending === result) fail(error)
                    }
                } catch (_: Exception) { finish(error = "google_unavailable") }
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        if (pending == null || disposed) return true
        if (resultCode != Activity.RESULT_OK) { finish(); return true }
        try { complete(client.getAuthorizationResultFromIntent(data)) }
        catch (error: Exception) { fail(error) }
        return true
    }

    private fun complete(authorization: AuthorizationResult) {
        val token = authorization.accessToken
        if (token.isNullOrEmpty() || !authorization.grantedScopes.containsAll(requestedScopes)) {
            finish(error = "google_denied")
        } else {
            lastToken = token
            finish(token = token)
        }
    }

    private fun fail(error: Exception) {
        val status = (error as? ApiException)?.statusCode
        when (status) {
            CommonStatusCodes.CANCELED -> finish()
            CommonStatusCodes.NETWORK_ERROR, CommonStatusCodes.TIMEOUT -> finish(error = "google_network")
            CommonStatusCodes.DEVELOPER_ERROR -> finish(error = "google_configuration")
            else -> finish(error = "google_unavailable")
        }
    }

    private fun finish(token: String? = null, error: String? = null) {
        val result = pending ?: return
        pending = null
        deadline?.let(handler::removeCallbacks)
        deadline = null
        if (error == null) result.success(token) else result.error(error, null, null)
    }

    fun dispose() {
        disposed = true
        finish(error = "google_unavailable")
        lastToken = null
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val REQUEST_CODE = 7031
        private const val FILE_SCOPE = "https://www.googleapis.com/auth/drive.file"
        private const val SCOPE = "https://www.googleapis.com/auth/drive.appdata"
    }
}
