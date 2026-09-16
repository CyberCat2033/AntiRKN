package org.antirkn.antirkn_manager

import android.app.Activity
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.ConnectException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLException
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/** Only per-socket binding; never changes the process route or bypasses a VPN. */
class IpDiagnosticsBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "org.antirkn/ip_diagnostics")
    private val connectivity = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val workers = Executors.newFixedThreadPool(4)
    private val epoch = AtomicInteger()
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()

    private fun networkInfo(): Map<String, Any> {
        val network = connectivity.activeNetwork ?: throw IllegalStateException("network_unavailable")
        val capabilities = connectivity.getNetworkCapabilities(network)
        val links = connectivity.getLinkProperties(network)
        val vpn = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        val kind = when {
            vpn -> "vpn"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "wifi"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "mobile"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "ethernet"
            else -> "system"
        }
        val identity = "${network.networkHandle}|${links?.interfaceName}|${links?.linkAddresses?.map { it.toString() }?.sorted()}|${links?.routes?.map { it.toString() }?.sorted()}|$vpn"
        return mapOf("identity" to identity, "kind" to kind, "vpn" to vpn, "bound" to true)
    }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "cancel") {
                cancel(); result.success(null)
            } else if (call.method == "network") {
                try { result.success(networkInfo()) } catch (_: Exception) { result.error("network_unavailable", null, null) }
            } else if (call.method == "probe") {
                val generation = epoch.get()
                val ip = call.argument<String>("ip") ?: ""
                val port = call.argument<Int>("port") ?: 0
                val mode = call.argument<String>("kind") ?: ""
                val host = call.argument<String>("host") ?: ""
                val expected = call.argument<String>("network") ?: ""
                val timeout = (call.argument<Int>("timeout") ?: 3000).coerceIn(100, 10000)
                if (!ip.matches(Regex("[0-9a-fA-F:.]{2,45}")) || port !in 1..65535 ||
                    mode !in setOf("tcp", "tls", "ssh", "http") || host.length > 253 ||
                    host.isNotEmpty() && !host.matches(Regex("[a-zA-Z0-9.-]+")) || mode == "tls" && host.isEmpty()) {
                    result.error("invalid_probe", null, null); return@setMethodCallHandler
                }
                workers.execute {
                    val started = SystemClock.elapsedRealtime()
                    var socket: Socket? = null
                    var status = "unavailable"
                    fun remaining(): Int = (timeout - (SystemClock.elapsedRealtime() - started)).toInt().let {
                        if (it <= 0) throw SocketTimeoutException() else it
                    }
                    try {
                        if (generation != epoch.get()) throw IllegalStateException("cancelled")
                        if (networkInfo()["identity"] != expected) throw IllegalStateException("network_changed")
                        val network = connectivity.activeNetwork ?: throw IllegalStateException("network_changed")
                        socket = network.socketFactory.createSocket()
                        sockets.add(socket)
                        if (generation != epoch.get()) throw IllegalStateException("cancelled")
                        socket.connect(InetSocketAddress(InetAddress.getByName(ip), port), remaining())
                        socket.soTimeout = remaining()
                        if (mode == "tls") {
                            val plain = socket
                            val secure = (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(plain, host, port, true) as SSLSocket
                            socket = secure
                            sockets.remove(plain); sockets.add(secure)
                            secure.sslParameters = secure.sslParameters.apply {
                                endpointIdentificationAlgorithm = "HTTPS"
                                serverNames = listOf(SNIHostName(host))
                            }
                            secure.soTimeout = remaining()
                            secure.startHandshake()
                        } else if (mode == "ssh" || mode == "http") {
                            if (mode == "http") {
                                socket.getOutputStream().write("GET /0 HTTP/1.0\r\nHost: ${host.ifEmpty { ip }}\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                            }
                            val input = socket.getInputStream()
                            val text = StringBuilder()
                            var valid = false
                            for (i in 0 until 8192) {
                                socket.soTimeout = remaining()
                                val value = input.read()
                                if (value < 0) break
                                text.append(value.toChar())
                                if (value == 10) {
                                    valid = if (mode == "http") text.startsWith("HTTP/1.1 200 ") || text.startsWith("HTTP/1.0 200 ")
                                        else Regex("(^|\\n)SSH-(2\\.0|1\\.99)-[^\\r\\n]+\\r?\\n").containsMatchIn(text)
                                    if (valid || mode == "http") break
                                }
                            }
                            if (!valid) throw IllegalArgumentException("protocol_error")
                        }
                        status = "reachable"
                    } catch (_: SocketTimeoutException) { status = "timeout"
                    } catch (_: SSLException) { status = "tlsError"
                    } catch (_: ConnectException) { status = "refused"
                    } catch (_: IllegalArgumentException) { status = "protocolError"
                    } catch (e: IllegalStateException) { status = if (e.message == "network_changed") "network_changed" else "unavailable"
                    } catch (_: Exception) { status = "unavailable"
                    } finally {
                        socket?.let { sockets.remove(it); try { it.close() } catch (_: Exception) {} }
                    }
                    val response = mapOf("status" to status, "ms" to (SystemClock.elapsedRealtime() - started).toInt())
                    activity.runOnUiThread { result.success(response) }
                }
            } else { result.notImplemented() }
        }
    }
    private fun cancel() {
        epoch.incrementAndGet()
        for (socket in sockets) { try { socket.close() } catch (_: Exception) {} }
        sockets.clear()
    }
    fun close() { cancel(); workers.shutdownNow(); channel.setMethodCallHandler(null) }
}
