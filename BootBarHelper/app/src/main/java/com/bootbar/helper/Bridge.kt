package com.bootbar.helper

import android.os.Handler
import android.os.Looper

enum class Phase { OFF, WAITING, CONNECTING, CONNECTED, NEEDS_PERMISSION }

/** What the helper is doing, shared by the screen, the watcher and the VPN. They all live in one process. */
object Bridge {
    @Volatile var phase = Phase.OFF
        private set

    /** The VPN is up, and for which proxy. */
    @Volatile var vpnEndpoint: String? = null

    /** The watcher is running. */
    @Volatile var watching = false

    private val main = Handler(Looper.getMainLooper())
    private val listeners = mutableListOf<(Phase) -> Unit>()

    fun update(new: Phase) {
        if (new == phase) return
        phase = new
        main.post { listeners.toList().forEach { it(new) } }
    }

    fun listen(listener: (Phase) -> Unit) {
        main.post { listeners += listener; listener(phase) }
    }

    fun unlisten(listener: (Phase) -> Unit) {
        main.post { listeners -= listener }
    }
}
