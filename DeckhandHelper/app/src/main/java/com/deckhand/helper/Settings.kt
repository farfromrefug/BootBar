package com.deckhand.helper

import android.content.Context

/** The proxy address Deckhand listens on (reached through `adb reverse`), and whether to follow Deckhand automatically. */
class Settings(context: Context) {
    private val preferences = context.getSharedPreferences("deckhand", Context.MODE_PRIVATE)

    var host: String
        get() = preferences.getString("host", "127.0.0.1") ?: "127.0.0.1"
        set(value) = preferences.edit().putString("host", value).apply()

    var port: Int
        get() = preferences.getInt("port", 8899)
        set(value) = preferences.edit().putInt("port", value).apply()

    /** Connect when Deckhand is capturing, disconnect when it stops. */
    var automatic: Boolean
        get() = preferences.getBoolean("automatic", false)
        set(value) = preferences.edit().putBoolean("automatic", value).apply()

    fun save(host: String, port: Int) {
        this.host = host
        this.port = port
    }
}
