package com.example.pattern_sensor_collector

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.graphics.Color
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.math.ceil

class MainActivity : FlutterActivity(), SensorEventListener {
    private lateinit var sensors: SensorManager
    private var accel: Sensor? = null
    private var gyro: Sensor? = null
    private var thread: HandlerThread? = null
    @Volatile private var armed = false
    private var gotAccel = false
    private var gotGyro = false
    private var pendingArm: MethodChannel.Result? = null
    private val lock = Any()
    private val samples = mutableListOf<Map<String, Any>>()
    private var sink: EventChannel.EventSink? = null
    private var start: Double? = null
    private var end: Double? = null
    private var maxClockErrorMs = 0.0
    private val mainHandler = Handler(Looper.getMainLooper())
    private var fixedT0: Double? = null
    private var fixedStart: Double? = null
    private var fixedEnd: Double? = null
    private var deadlineReached = false
    private var deadlineErrorMs = 0.0
    private var windowError: String? = null
    private var deadlineRunnable: Runnable? = null
    // v3 touch-bounded capture: sensors stay subscribed with a short rolling
    // buffer so an idle baseline can be retained before pointer down.
    @Volatile private var touchMode = false
    @Volatile private var lastAccelTime = 0.0
    @Volatile private var lastGyroTime = 0.0
    // v3.1 training-data import: system document picker for ZIP files.
    private var pendingPick: MethodChannel.Result? = null
    private val pickZipsRequest = 4107

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sensors = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        accel = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        gyro = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pattern_sensor/capture")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "arm" -> arm(result)
                    "finish" -> finish(result)
                    "startFixed" -> startFixed(result)
                    "finishFixed" -> finishFixed(result,
                        (call.arguments as? Map<*, *>)?.get("force") == true)
                    "pickZips" -> pickZips(result)
                    "armTouch" -> armTouch(result)
                    "finishTouch" -> finishTouch(result)
                    "cancel" -> { stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "pattern_sensor/touch")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
                override fun onCancel(arguments: Any?) { sink = null }
            })
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "pattern_sensor/touch_view", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
                    object : PlatformView {
                        private val touchView = object : View(context) {
                            init { setBackgroundColor(Color.TRANSPARENT) }
                            override fun onTouchEvent(event: MotionEvent): Boolean {
                                handleMotion(event, width.toDouble(), height.toDouble())
                                return true
                            }
                        }
                        override fun getView(): View = touchView
                        override fun dispose() {}
                    }
            })
    }

    private fun arm(result: MethodChannel.Result) {
        fixedT0 = null; fixedStart = null; fixedEnd = null
        if (accel == null || gyro == null) {
            result.error("NO_SENSOR", "Accelerometer and gyroscope are both required", null)
            return
        }
        stop()
        synchronized(lock) { samples.clear(); gotAccel = false; gotGyro = false }
        start = null; end = null; maxClockErrorMs = 0.0
        armed = true
        pendingArm = result
        thread = HandlerThread("pattern-sensors").also { it.start() }
        val handler = Handler(thread!!.looper)
        val a = sensors.registerListener(this, accel, 10_000, handler)
        val g = sensors.registerListener(this, gyro, 10_000, handler)
        if (!a || !g) {
            stop()
            result.error("REGISTER_FAILED", "Could not register both sensors", null)
            pendingArm = null
        }
    }
    private fun pickZips(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("BUSY", "A file picker is already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip",
                "application/x-zip-compressed", "application/octet-stream"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            startActivityForResult(intent, pickZipsRequest)
        } catch (e: Exception) {
            pendingPick = null
            result.error("NO_PICKER", e.message, null)
        }
    }
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickZipsRequest) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick ?: return
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Any>())
            return
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        else data.data?.let { uris.add(it) }
        // Copy each picked document into the app cache so Dart can read it.
        // The cache copy is deleted by Dart after import.
        Thread {
            val dir = java.io.File(cacheDir, "import_pick").apply { mkdirs() }
            val picked = mutableListOf<Map<String, Any>>()
            var failure: String? = null
            for ((i, uri) in uris.withIndex()) {
                try {
                    var name = "file_$i.zip"
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME),
                        null, null, null)?.use { c ->
                        if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
                    }
                    val out = java.io.File(dir, "${System.nanoTime()}_$i.zip")
                    contentResolver.openInputStream(uri)?.use { input ->
                        out.outputStream().use { input.copyTo(it) }
                    } ?: throw IllegalStateException("Cannot open $name")
                    picked.add(mapOf("name" to name, "path" to out.absolutePath))
                } catch (e: Exception) {
                    failure = e.message ?: "copy failed"
                }
            }
            mainHandler.post {
                if (picked.isEmpty() && failure != null) result.error("COPY_FAILED", failure, null)
                else result.success(picked)
            }
        }.start()
    }
    private fun armTouch(result: MethodChannel.Result) {
        arm(result)
        if (armed) {
            touchMode = true
            lastAccelTime = 0.0
            lastGyroTime = 0.0
        }
    }
    private fun finishTouch(result: MethodChannel.Result) {
        val down = start
        val up = end
        val giveUpAt = SystemClock.elapsedRealtimeNanos() / 1e9 + 0.3
        fun complete() {
            val drained = up != null && lastAccelTime > up && lastGyroTime > up
            armed = false
            touchMode = false
            if (::sensors.isInitialized) sensors.unregisterListener(this)
            thread?.quitSafely(); thread = null
            val copy = synchronized(lock) {
                if (down == null || up == null) emptyList()
                else samples.filter {
                    val t = it["time"] as Double
                    t >= down - 0.7 && t <= up
                }
            }
            result.success(mapOf("sensors" to copy, "start" to down, "end" to up,
                "drained" to drained, "clockErrorMs" to maxClockErrorMs,
                "sensorTimestampBasis" to "elapsedRealtimeNanos",
                "model" to Build.MODEL, "osVersion" to Build.VERSION.RELEASE))
        }
        // Sensor events up to the release time may still be queued; wait until
        // both sensors have reported a sample after touch up (max 300 ms).
        fun poll() {
            val now = SystemClock.elapsedRealtimeNanos() / 1e9
            if (up == null || (lastAccelTime > up && lastGyroTime > up) || now >= giveUpAt) {
                complete()
            } else mainHandler.postDelayed({ poll() }, 10)
        }
        poll()
    }
    private fun startFixed(result: MethodChannel.Result) {
        val t0 = SystemClock.elapsedRealtimeNanos() / 1e9
        stop()
        fixedT0 = t0; fixedStart = t0; fixedEnd = t0 + 5.0
        deadlineReached = false; deadlineErrorMs = 0.0; windowError = null
        synchronized(lock) { samples.clear(); gotAccel = false; gotGyro = false }
        start = null; end = null; maxClockErrorMs = 0.0
        armed = true
        if (accel == null || gyro == null) {
            windowError = "SENSOR_NOT_READY_IN_WINDOW"
        } else {
            thread = HandlerThread("pattern-sensors").also { it.start() }
            val handler = Handler(thread!!.looper)
            val a = sensors.registerListener(this, accel, 10_000, handler)
            val g = sensors.registerListener(this, gyro, 10_000, handler)
            if (!a || !g) windowError = "SENSOR_NOT_READY_IN_WINDOW"
        }
        val deadline = Runnable { closeFixedWindow() }
        deadlineRunnable = deadline
        mainHandler.postDelayed(deadline, ceil(((fixedEnd!! - SystemClock.elapsedRealtimeNanos() / 1e9)
            * 1000).coerceAtLeast(0.0)).toLong())
        result.success(mapOf("buttonT0" to t0, "captureStart" to fixedStart!!,
            "captureEnd" to fixedEnd!!,
            "nativeNow" to SystemClock.elapsedRealtimeNanos() / 1e9))
    }
    private fun closeFixedWindow() {
        if (deadlineReached || fixedEnd == null) return
        deadlineReached = true
        deadlineErrorMs = ((SystemClock.elapsedRealtimeNanos() / 1e9 - fixedEnd!!) * 1000)
            .coerceAtLeast(0.0)
        armed = false
        if (::sensors.isInitialized) sensors.unregisterListener(this)
        thread?.quitSafely()
        if (deadlineErrorMs > 100 && windowError == null) windowError = "WINDOW_DEADLINE_DELAY"
    }
    private fun finishFixed(result: MethodChannel.Result, force: Boolean) {
        val endAt = fixedEnd
        if (endAt == null) {
            result.success(mapOf("sensors" to emptyList<Any>(),"windowComplete" to false,
                "windowError" to "WINDOW_METADATA_INVALID","clockErrorMs" to maxClockErrorMs))
            return
        }
        val remainingMs = ceil(((endAt - SystemClock.elapsedRealtimeNanos() / 1e9) * 1000)
            .coerceAtLeast(0.0)).toLong()
        if (!force && remainingMs > 0) {
            mainHandler.postDelayed({ finishFixed(result, false) }, remainingMs)
            return
        }
        if (force && !deadlineReached) {
            windowError = "INTERRUPTED"
            deadlineRunnable?.let { mainHandler.removeCallbacks(it) }
            deadlineRunnable = null
            armed = false
            if (::sensors.isInitialized) sensors.unregisterListener(this)
            thread?.quitSafely()
        } else closeFixedWindow()
        val draining = thread
        thread = null
        Thread {
            draining?.join(1000)
            val drained = draining == null || !draining.isAlive
            val copy = synchronized(lock) { samples.toList() }
            mainHandler.post {
                result.success(mapOf("sensors" to copy,"start" to start,"end" to end,
                    "buttonT0" to fixedT0,"captureStart" to fixedStart,"captureEnd" to fixedEnd,
                    "windowComplete" to (deadlineReached && drained),
                    "windowError" to (if (drained) windowError else "BUFFER_DRAIN_TIMEOUT"),
                    "deadlineErrorMs" to deadlineErrorMs,"clockErrorMs" to maxClockErrorMs,
                    "model" to Build.MODEL,"osVersion" to Build.VERSION.RELEASE))
            }
        }.start()
    }
    override fun onSensorChanged(event: SensorEvent) {
        if (!armed) return
        if (fixedT0 != null && event.timestamp / 1e9 < fixedT0!!) return
        val type = when (event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> "ACCEL"
            Sensor.TYPE_GYROSCOPE -> "GYRO"
            else -> return
        }
        val item: Map<String, Any> = mapOf(
            "type" to type, "time" to event.timestamp / 1e9,
            "nativeTimestamp" to event.timestamp, "timebase" to "elapsedRealtimeNanos",
            "x" to event.values[0].toDouble(), "y" to event.values[1].toDouble(),
            "z" to event.values[2].toDouble())
        val time = event.timestamp / 1e9
        synchronized(lock) {
            samples.add(item)
            if (type == "ACCEL") lastAccelTime = time else lastGyroTime = time
            if (touchMode && start == null) {
                // Before the first touch keep only the most recent second.
                while (samples.isNotEmpty() && (samples[0]["time"] as Double) < time - 1.0) {
                    samples.removeAt(0)
                }
            }
            if (type == "ACCEL") gotAccel = true else gotGyro = true
            if (gotAccel && gotGyro && pendingArm != null) {
                val callback = pendingArm
                pendingArm = null
                mainHandler.post { callback?.success(mapOf("ready" to true)) }
            }
        }
    }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    private fun stop() {
        deadlineRunnable?.let { mainHandler.removeCallbacks(it) }
        deadlineRunnable = null
        armed = false
        touchMode = false
        if (::sensors.isInitialized) sensors.unregisterListener(this)
        thread?.quitSafely(); thread = null
        pendingArm?.let { it.error("CANCELLED", "Capture cancelled", null) }
        pendingArm = null
    }
    private fun finish(result: MethodChannel.Result) {
        sensors.unregisterListener(this)
        val draining = thread
        thread = null
        draining?.quitSafely()
        Thread {
            draining?.join(1000)
            armed = false
            val copy = synchronized(lock) { samples.toList() }
            mainHandler.post {
                result.success(mapOf("sensors" to copy, "start" to start, "end" to end,
                    "clockErrorMs" to maxClockErrorMs, "model" to Build.MODEL,
                    "osVersion" to Build.VERSION.RELEASE))
            }
        }.start()
    }
    private fun calibratedOffsetNs(): Long {
        val before = SystemClock.elapsedRealtimeNanos()
        val uptime = if (Build.VERSION.SDK_INT >= 35) SystemClock.uptimeNanos()
            else System.nanoTime()
        val after = SystemClock.elapsedRealtimeNanos()
        val uncertainty = (after - before) / 1e6
        maxClockErrorMs = maxOf(maxClockErrorMs, uncertainty +
            if (Build.VERSION.SDK_INT >= 34) 0.0 else 1.0)
        return (before + after) / 2 - uptime
    }
    private fun touchTime(uptimeNs: Long, offsetNs: Long): Double =
        (uptimeNs + offsetNs) / 1e9
    private fun handleMotion(event: MotionEvent, width: Double, height: Double) {
        if (!armed || width <= 0 || height <= 0) return
        val action = event.actionMasked
        val offsetNs = calibratedOffsetNs()
        if (action == MotionEvent.ACTION_POINTER_DOWN || event.pointerCount > 1) {
            emit("MULTITOUCH", touchTime(if (Build.VERSION.SDK_INT >= 34) event.eventTimeNanos else event.eventTime * 1_000_000L, offsetNs),
                event.x.toDouble()/width, event.y.toDouble()/height)
            end = touchTime(if (Build.VERSION.SDK_INT >= 34) event.eventTimeNanos else event.eventTime * 1_000_000L, offsetNs)
            return
        }
        if (action == MotionEvent.ACTION_MOVE) {
            for (i in 0 until event.historySize) {
                emit("MOVE", touchTime(if (Build.VERSION.SDK_INT >= 34) event.getHistoricalEventTimeNanos(i) else event.getHistoricalEventTime(i) * 1_000_000L, offsetNs),
                    event.getHistoricalX(i).toDouble()/width,
                    event.getHistoricalY(i).toDouble()/height)
            }
        }
        val type = when(action) {
            MotionEvent.ACTION_DOWN -> "DOWN"
            MotionEvent.ACTION_MOVE -> "MOVE"
            MotionEvent.ACTION_UP -> "UP"
            MotionEvent.ACTION_CANCEL -> "CANCEL"
            else -> return
        }
        val nanos = if (Build.VERSION.SDK_INT >= 34) event.eventTimeNanos
            else event.eventTime * 1_000_000L
        val time = touchTime(nanos, offsetNs)
        if (type == "DOWN") start = time
        if (type == "UP" || type == "CANCEL") end = time
        emit(type, time, event.x.toDouble()/width, event.y.toDouble()/height)
    }
    private fun emit(type: String, time: Double, x: Double, y: Double) {
        mainHandler.post { sink?.success(mapOf("type" to type, "time" to time, "x" to x, "y" to y)) }
    }
    override fun onPause() {
        if (fixedT0 != null && !deadlineReached && armed) {
            windowError = "INTERRUPTED"
            armed = false
            if (::sensors.isInitialized) sensors.unregisterListener(this)
            thread?.quitSafely()
            deadlineRunnable?.let { mainHandler.removeCallbacks(it) }
            deadlineRunnable = null
        }
        super.onPause()
    }
    override fun onDestroy() { stop(); super.onDestroy() }
}
