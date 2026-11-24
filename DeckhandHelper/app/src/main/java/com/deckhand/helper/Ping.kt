package com.deckhand.helper

import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket

/** Asks the BootBar proxy for its `/ping` page. A bare connection proves nothing: `adb reverse` accepts it either way. */
object Ping {
    fun alive(host: String, port: Int): Boolean = try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), 800)
            socket.soTimeout = 800
            socket.getOutputStream().apply {
                write("GET http://bootbar.proxy/ping HTTP/1.1\r\nHost: bootbar.proxy\r\nConnection: close\r\n\r\n".toByteArray())
                flush()
            }
            BufferedReader(InputStreamReader(socket.getInputStream())).readLine()?.startsWith("HTTP/1.1 200") == true
        }
    } catch (_: Exception) {
        false
    }
}
