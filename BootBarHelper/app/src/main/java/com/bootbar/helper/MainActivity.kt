package com.bootbar.helper

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Starts and stops the proxy VPN, from the screen or from adb:
 * `am start -n com.bootbar.helper/.MainActivity --es command start --es host 127.0.0.1 --ei port 8899`
 * (`--es command stop` to stop). Pass `--ez quiet true` to leave the screen again at once.
 */
class MainActivity : Activity() {
    private lateinit var host: EditText
    private lateinit var port: EditText
    private lateinit var status: TextView
    private var pending: Intent? = null
    private var quiet = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val settings = Settings(this)
        host = EditText(this).apply { setText(settings.host); hint = "Proxy address"; setSingleLine() }
        port = EditText(this).apply {
            setText(settings.port.toString()); hint = "Port"; inputType = InputType.TYPE_CLASS_NUMBER
        }
        status = TextView(this).apply { textSize = 16f; setPadding(0, 32, 0, 32) }
        val start = Button(this).apply { text = "Start"; setOnClickListener { start(host.text.toString(), port.text.toString().toIntOrNull() ?: 8899) } }
        val stop = Button(this).apply { text = "Stop"; setOnClickListener { stop() } }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(48, 96, 48, 48)
            addView(TextView(context).apply { text = "BootBar proxy"; textSize = 22f })
            addView(host)
            addView(port)
            addView(start)
            addView(stop)
            addView(status)
        })
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun handle(intent: Intent) {
        quiet = intent.getBooleanExtra("quiet", false)
        when (intent.getStringExtra("command")) {
            "start" -> start(intent.getStringExtra("host") ?: Settings(this).host, intent.getIntExtra("port", Settings(this).port))
            "stop" -> stop()
        }
    }

    private fun start(host: String, port: Int) {
        val intent = Intent(this, ProxyVpnService::class.java).putExtra("host", host).putExtra("port", port)
        val consent = VpnService.prepare(this)
        if (consent == null) {
            launch(intent)
        } else {
            pending = intent
            startActivityForResult(consent, REQUEST_VPN)
        }
    }

    private fun launch(intent: Intent) {
        startService(intent)
        status.postDelayed({ refresh(); if (quiet) finish() }, 500)
    }

    private fun stop() {
        stopService(Intent(this, ProxyVpnService::class.java))
        status.postDelayed({ refresh(); if (quiet) finish() }, 300)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_VPN && resultCode == RESULT_OK) pending?.let { launch(it) }
        else if (quiet) finish()
        pending = null
    }

    private fun refresh() {
        val settings = Settings(this)
        status.text = if (settings.running) "Active: ${settings.host}:${settings.port}" else "Stopped"
    }

    private companion object {
        const val REQUEST_VPN = 1
    }
}
