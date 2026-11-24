package com.deckhand.helper

import android.content.Intent
import android.net.ProxyInfo
import android.net.VpnService
import android.os.ParcelFileDescriptor

/**
 * A VPN that carries no traffic of its own. It exists to give the device a network whose HTTP proxy is BootBar,
 * which every app that respects the system proxy then uses, without a setting that adb has to change.
 */
class ProxyVpnService : VpnService() {
    private var tunnel: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getBooleanExtra("stop", false) == true) {
            // the system keeps the service bound while the VPN is up, so closing the tunnel is what ends it
            stopTunnel()
            stopSelf()
            return START_NOT_STICKY
        }
        val settings = Settings(this)
        val host = intent?.getStringExtra("host") ?: settings.host
        val port = intent?.getIntExtra("port", 0)?.takeIf { it > 0 } ?: settings.port
        settings.save(host, port)
        Bridge.update(Phase.CONNECTING)
        tunnel?.close()
        tunnel = try {
            Builder()
                .setSession("BootBar")
                // nothing is routed here but this documentation address, so the real network keeps working as it is
                .addAddress("10.255.255.1", 32)
                .addRoute("192.0.2.1", 32)
                .setHttpProxy(ProxyInfo.buildDirectProxy(host, port))
                .setMetered(false)
                .addDisallowedApplication(packageName)
                .establish()
        } catch (_: Exception) {
            null
        }
        if (tunnel != null) {
            Bridge.vpnEndpoint = "$host:$port"
            Bridge.update(Phase.CONNECTED)
        } else {
            Bridge.vpnEndpoint = null
            // establish() answers null when the user has not allowed this app to be a VPN
            Bridge.update(if (Bridge.watching) Phase.NEEDS_PERMISSION else Phase.OFF)
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun stopTunnel() {
        tunnel?.close()
        tunnel = null
        Bridge.vpnEndpoint = null
        Bridge.update(if (Bridge.watching) Phase.WAITING else Phase.OFF)
    }
}
