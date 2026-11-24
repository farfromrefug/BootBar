package com.bootbar.helper

import android.app.Activity
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.VpnService
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The screen, and the way BootBar drives the helper over adb:
 * `am start -n com.bootbar.helper/.MainActivity --es command watch --es host 127.0.0.1 --ei port 8899 --ez quiet true`
 * (`unwatch` turns it off; `start` and `stop` bring the VPN up or down once, without watching).
 */
class MainActivity : Activity() {
    private lateinit var status: StatusView
    private lateinit var title: TextView
    private lateinit var subtitle: TextView
    private lateinit var action: Button
    private lateinit var host: EditText
    private lateinit var port: EditText
    private var quiet = false
    private var pendingConsent: (() -> Unit)? = null
    private val listener: (Phase) -> Unit = { render(it) }

    private val night get() = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    private val screen get() = if (night) 0xFF0E1013.toInt() else 0xFFF3F4F7.toInt()
    private val surface get() = if (night) 0xFF1A1D22.toInt() else 0xFFFFFFFF.toInt()
    private val primary get() = if (night) 0xFFF2F3F5.toInt() else 0xFF14171A.toInt()
    private val secondary get() = if (night) 0xFF9AA1AB.toInt() else 0xFF6B7280.toInt()
    private val accent = 0xFF3B82F6.toInt()

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private fun rounded(color: Int, radius: Int, stroke: Int? = null) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
        if (stroke != null) setStroke(dp(1), stroke)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
                val settings = Settings(this)
        status = StatusView(this)
        title = TextView(this).apply {
            textSize = 28f; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(primary); gravity = Gravity.CENTER
        }
        subtitle = TextView(this).apply {
            textSize = 15f; setTextColor(secondary); gravity = Gravity.CENTER; setLineSpacing(0f, 1.15f)
        }
        action = Button(this).apply {
            isAllCaps = false; textSize = 16f; setTextColor(Color.WHITE)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            stateListAnimator = null
            setOnClickListener { onAction() }
        }
        host = field("Proxy address", settings.host, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        port = field("Port", settings.port.toString(), InputType.TYPE_CLASS_NUMBER)

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(surface, 20)
            setPadding(dp(20), dp(18), dp(20), dp(20))
            addView(TextView(context).apply {
                text = "Proxy on the computer"; textSize = 13f; setTextColor(secondary)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            })
            addView(host, margin(top = 10))
            addView(port, margin(top = 10))
            addView(TextView(context).apply {
                text = "BootBar sets this up itself. Change it only to use another proxy."
                textSize = 12f; setTextColor(secondary)
            }, margin(top = 10))
        }

        setContentView(android.widget.ScrollView(this).apply {
            setBackgroundColor(screen)
            isFillViewport = true
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(dp(24), dp(40), dp(24), dp(32))
                // below the status bar and above the navigation bar
                setOnApplyWindowInsetsListener { view, insets ->
                    val bars = insets.getInsets(WindowInsets.Type.systemBars())
                    view.setPadding(dp(24), bars.top + dp(40), dp(24), bars.bottom + dp(32))
                    insets
                }
                addView(status, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                addView(title, margin(top = 20))
                addView(subtitle, margin(top = 8, side = 16))
                addView(action, margin(top = 28, height = 52))
                addView(card, margin(top = 36))
            })
        })
        // dark icons in the status bar when the screen is light (needs the window's decor view, so after setContentView)
        window.insetsController?.setSystemBarsAppearance(
            if (night) 0 else WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
        handle(intent)
    }

    private fun field(hint: String, value: String, type: Int) = EditText(this).apply {
        setText(value); this.hint = hint; inputType = type; setSingleLine()
        textSize = 15f; setTextColor(primary); setHintTextColor(secondary)
        background = rounded(if (night) 0xFF23272E.toInt() else 0xFFF3F4F7.toInt(), 12)
        setPadding(dp(14), dp(12), dp(14), dp(12))
    }

    private fun margin(top: Int = 0, side: Int = 0, height: Int? = null) =
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height?.let { dp(it) } ?: ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(top); leftMargin = dp(side); rightMargin = dp(side)
        }

    override fun onStart() {
        super.onStart()
        Bridge.listen(listener)
        // the process may have been killed: bring the watcher back if it should be running
        if (Settings(this).automatic && !Bridge.watching) startWatching()
    }

    override fun onStop() {
        Bridge.unlisten(listener)
        saveAddress()
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    // MARK: Commands

    private fun handle(intent: Intent) {
        quiet = intent.getBooleanExtra("quiet", false)
        val settings = Settings(this)
        val address = intent.getStringExtra("host") ?: settings.host
        val number = intent.getIntExtra("port", settings.port)
        when (intent.getStringExtra("command")) {
            "watch" -> { settings.save(address, number); setAddress(address, number); settings.automatic = true; ensureConsent { startWatching() } }
            "unwatch" -> { settings.automatic = false; stopWatching() }
            "start" -> { settings.save(address, number); ensureConsent { startService(Intent(this, ProxyVpnService::class.java)) } }
            "stop" -> startService(Intent(this, ProxyVpnService::class.java).putExtra("stop", true))
            else -> return
        }
        if (quiet) window.decorView.postDelayed({ if (Bridge.phase != Phase.NEEDS_PERMISSION) finish() }, 700)
    }

    private fun startWatching() {
        startForegroundService(Intent(this, WatchService::class.java))
    }

    private fun stopWatching() {
        startService(Intent(this, WatchService::class.java).putExtra("stop", true))
    }

    /** Runs [then] once the system lets this app be a VPN, asking the user first when it has not been allowed yet. */
    private fun ensureConsent(then: () -> Unit) {
        val consent = VpnService.prepare(this)
        if (consent == null) {
            then()
        } else {
            pendingConsent = then
            startActivityForResult(consent, REQUEST_VPN)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_VPN && resultCode == RESULT_OK) pendingConsent?.invoke()
        pendingConsent = null
    }

    private fun onAction() {
        val settings = Settings(this)
        saveAddress()
        when (Bridge.phase) {
            Phase.OFF -> { settings.automatic = true; ensureConsent { startWatching() } }
            Phase.NEEDS_PERMISSION -> ensureConsent { startWatching() }
            else -> { settings.automatic = false; stopWatching() }
        }
    }

    private fun saveAddress() {
        val number = port.text.toString().toIntOrNull() ?: return
        val address = host.text.toString().trim()
        if (address.isNotEmpty()) Settings(this).save(address, number)
    }

    private fun setAddress(address: String, number: Int) {
        host.setText(address)
        port.setText(number.toString())
    }

    // MARK: Screen

    private fun render(phase: Phase) {
        val settings = Settings(this)
        status.phase = phase
        val (heading, detail, button) = when (phase) {
            Phase.OFF -> Triple("Off", "Turn it on and this device connects by itself whenever BootBar is capturing.", "Turn on")
            Phase.WAITING -> Triple("Waiting for BootBar", "Start capturing in BootBar. The VPN connects as soon as it does, and disconnects when it stops.", "Turn off")
            Phase.CONNECTING -> Triple("Connecting…", "Setting up the VPN to BootBar.", "Turn off")
            Phase.CONNECTED -> Triple("Connected", "Requests from this device go to BootBar at ${settings.host}:${settings.port}.", "Turn off")
            Phase.NEEDS_PERMISSION -> Triple("Allow the VPN", "Android needs your approval once before this app can set up its VPN.", "Allow")
        }
        title.text = heading
        subtitle.text = detail
        action.text = button
        action.background = rounded(if (phase == Phase.OFF || phase == Phase.NEEDS_PERMISSION) accent else if (night) 0xFF2A2F37.toInt() else 0xFF14171A.toInt(), 26)
        action.visibility = View.VISIBLE
    }

    private companion object {
        const val REQUEST_VPN = 1
    }
}
