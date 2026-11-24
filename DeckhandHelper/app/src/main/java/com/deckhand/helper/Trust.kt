package com.deckhand.helper

import android.os.Build
import java.security.KeyStore
import java.security.cert.X509Certificate

/** Whether apps on this device will accept the certificate Deckhand signs HTTPS with. */
enum class Trust {
    /** In the system store: every app trusts it. */
    SYSTEM,

    /** Only in the user store: browsers and debug builds trust it, most other apps do not. */
    USER,

    /** In neither, on a device that Deckhand can make trust it (adb can become root). */
    MISSING_ROOTABLE,

    /** In neither, on a device that cannot be rooted. */
    MISSING_LOCKED;

    companion object {
        fun read(): Trust {
            val found = found()
            if (found != null) return found
            return if (rootable()) MISSING_ROOTABLE else MISSING_LOCKED
        }

        /** The CAs the system lists carry the prefix of the store they come from: `system:` or `user:`. */
        private fun found(): Trust? {
            return try {
                val store = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
                var user = false
                for (alias in store.aliases()) {
                    val certificate = store.getCertificate(alias) as? X509Certificate ?: continue
                    if (!certificate.subjectX500Principal.name.contains("Deckhand Proxy CA")) continue
                    if (alias.startsWith("system:")) return SYSTEM
                    user = true
                }
                if (user) USER else null
            } catch (_: Exception) {
                null
            }
        }

        /** A build that lets adb run as root: an emulator without Google Play, or a userdebug device. */
        private fun rootable() = Build.TYPE != "user"
    }
}
