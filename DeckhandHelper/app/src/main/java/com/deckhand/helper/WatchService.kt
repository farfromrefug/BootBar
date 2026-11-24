package com.deckhand.helper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.IBinder

/**
 * Follows BootBar: while its proxy answers (BootBar is capturing and `adb reverse` is in place) the VPN is up,
 * and when it stops answering the VPN is taken down again, so nothing is left pointing at a proxy that is gone.
 */
class WatchService : Service() {
    private var thread: Thread? = null
    @Volatile private var running = false
    private val phaseListener: (Phase) -> Unit = { notify(it) }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getBooleanExtra("stop", false) == true) {
            stopWatching()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, notification(Bridge.phase), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        if (!running) {
            running = true
            Bridge.watching = true
            if (Bridge.phase == Phase.OFF) Bridge.update(Phase.WAITING)
            Bridge.listen(phaseListener)
            thread = Thread(::watch, "bootbar-watch").also { it.isDaemon = true; it.start() }
        }
        return START_STICKY
    }

    private fun watch() {
        var misses = 0
        while (running) {
            val settings = Settings(this)
            val endpoint = "${settings.host}:${settings.port}"
            if (Ping.alive(settings.host, settings.port)) {
                misses = 0
                when {
                    Bridge.vpnEndpoint == endpoint -> Bridge.update(Phase.CONNECTED)
                    VpnService.prepare(this) != null -> Bridge.update(Phase.NEEDS_PERMISSION)
                    else -> {
                        Bridge.update(Phase.CONNECTING)
                        startService(Intent(this, ProxyVpnService::class.java))
                    }
                }
            } else if (++misses >= 2) {
                // two missed answers in a row: BootBar stopped capturing (one miss can be a busy proxy)
                if (Bridge.vpnEndpoint != null) {
                    startService(Intent(this, ProxyVpnService::class.java).putExtra("stop", true))
                } else {
                    Bridge.update(Phase.WAITING)
                }
            }
            try { Thread.sleep(1500) } catch (_: InterruptedException) { return }
        }
    }

    private fun stopWatching() {
        running = false
        thread?.interrupt()
        Bridge.watching = false
        Bridge.unlisten(phaseListener)
        startService(Intent(this, ProxyVpnService::class.java).putExtra("stop", true))
        Bridge.update(Phase.OFF)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        thread?.interrupt()
        Bridge.watching = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun notify(phase: Phase) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(phase))
    }

    private fun notification(phase: Phase): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "BootBar", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val text = when (phase) {
            Phase.CONNECTED -> "Connected: requests go to BootBar"
            Phase.CONNECTING -> "Connecting…"
            Phase.NEEDS_PERMISSION -> "Tap to allow the VPN"
            else -> "Waiting for BootBar to capture"
        }
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("BootBar")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private companion object {
        const val CHANNEL = "watch"
        const val NOTIFICATION_ID = 1
    }
}
