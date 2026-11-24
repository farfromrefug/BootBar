package com.deckhand.helper

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.View
import android.view.animation.LinearInterpolator
import kotlin.math.min

/** A large round indicator: a coloured disc with a halo, and a glyph for what the helper is doing. */
class StatusView(context: Context) : View(context) {
    var phase = Phase.OFF
        set(value) {
            field = value
            if (value == Phase.CONNECTING || value == Phase.WAITING) {
                if (!pulse.isRunning) pulse.start()
            } else {
                pulse.cancel()
            }
            invalidate()
        }

    private var progress = 0f
    private val pulse = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 1500
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { progress = it.animatedValue as Float; invalidate() }
    }
    private val halo = Paint(Paint.ANTI_ALIAS_FLAG)
    private val disc = Paint(Paint.ANTI_ALIAS_FLAG)
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    override fun onDetachedFromWindow() {
        pulse.cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = min(width, height) / 2f * 0.52f
        val color = color(phase)

        halo.color = color
        if (phase == Phase.CONNECTING || phase == Phase.WAITING) {
            halo.alpha = ((1 - progress) * 90).toInt()
            canvas.drawCircle(cx, cy, r * (1.1f + 0.45f * progress), halo)
        }
        halo.color = color
        halo.alpha = 36
        canvas.drawCircle(cx, cy, r * 1.3f, halo)
        disc.color = color
        canvas.drawCircle(cx, cy, r, disc)

        glyph.strokeWidth = r * 0.14f
        when (phase) {
            Phase.CONNECTED -> canvas.drawPath(Path().apply {
                moveTo(cx - r * 0.38f, cy + r * 0.02f)
                lineTo(cx - r * 0.1f, cy + r * 0.3f)
                lineTo(cx + r * 0.4f, cy - r * 0.28f)
            }, glyph)
            Phase.WAITING -> {
                canvas.drawLine(cx - r * 0.2f, cy - r * 0.3f, cx - r * 0.2f, cy + r * 0.3f, glyph)
                canvas.drawLine(cx + r * 0.2f, cy - r * 0.3f, cx + r * 0.2f, cy + r * 0.3f, glyph)
            }
            Phase.CONNECTING -> canvas.drawArc(
                RectF(cx - r * 0.38f, cy - r * 0.38f, cx + r * 0.38f, cy + r * 0.38f),
                progress * 360f, 250f, false, glyph)
            Phase.NEEDS_PERMISSION -> {
                canvas.drawLine(cx, cy - r * 0.4f, cx, cy + r * 0.08f, glyph)
                glyph.strokeWidth = r * 0.2f
                canvas.drawPoint(cx, cy + r * 0.38f, glyph)
            }
            Phase.OFF -> canvas.drawLine(cx - r * 0.3f, cy, cx + r * 0.3f, cy, glyph)
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = (170 * resources.displayMetrics.density).toInt()
        setMeasuredDimension(size, size)
    }

    companion object {
        fun color(phase: Phase): Int = when (phase) {
            Phase.CONNECTED -> 0xFF22C55E.toInt()
            Phase.CONNECTING -> 0xFF3B82F6.toInt()
            Phase.WAITING -> 0xFFF59E0B.toInt()
            Phase.NEEDS_PERMISSION -> 0xFFEF4444.toInt()
            Phase.OFF -> 0xFF8A9099.toInt()
        }
    }
}
