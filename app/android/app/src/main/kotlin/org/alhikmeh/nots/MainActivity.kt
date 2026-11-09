package org.alhikmeh.nots

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /// A Masdar link the app was opened with, until Dart asks for it.
    private var pendingLink: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLink = linkOf(intent)
    }

    /// A link opened or shared while the app is already running.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val link = linkOf(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("link", link) else pendingLink = link
    }

    /// The text of a link opened (VIEW) or of text shared (SEND).
    private fun linkOf(intent: Intent?): String? =
        when (intent?.action) {
            Intent.ACTION_VIEW -> intent.dataString
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nots/app")
        channel = ch
        ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeLink" -> {
                        result.success(pendingLink)
                        pendingLink = null
                    }
                    "openMasdarLink" -> {
                        // A page in the Masdar app; without it, the browser.
                        // Never this app, which also opens these links.
                        val uri = Uri.parse(call.argument<String>("url") ?: "")
                        val inMasdar = Intent(Intent.ACTION_VIEW, uri)
                            .setPackage(call.argument<String>("package"))
                        if (inMasdar.resolveActivity(packageManager) != null) {
                            startActivity(inMasdar)
                            result.success("masdar")
                        } else {
                            val browser = Intent(Intent.ACTION_VIEW, uri).apply {
                                selector = Intent.makeMainSelectorActivity(
                                    Intent.ACTION_MAIN,
                                    Intent.CATEGORY_APP_BROWSER,
                                )
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            try {
                                startActivity(browser)
                                result.success("browser")
                            } catch (_: Exception) {
                                result.success(null)
                            }
                        }
                    }
                    "hasGoogleServices" -> result.success(hasGoogleServices())
                    "hasCustomTabs" -> result.success(hasCustomTabs())
                    "deviceName" -> result.success(Build.MODEL)
                    "bringToFront" -> {
                        // Closes the sign-in tab, which sits above this
                        // activity in the app's task.
                        startActivity(
                            Intent(this, MainActivity::class.java).addFlags(
                                Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                            ),
                        )
                        result.success(null)
                    }
                    "openApp" -> {
                        // Opens another app (the Masdar app) when installed.
                        val pkg = call.argument<String>("package")
                        val intent = pkg?.let { packageManager.getLaunchIntentForPackage(it) }
                        if (intent != null) {
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasGoogleServices(): Boolean =
        try {
            packageManager.getPackageInfo("com.google.android.gms", 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }

    private fun hasCustomTabs(): Boolean =
        packageManager
            .queryIntentServices(
                Intent("android.support.customtabs.action.CustomTabsService"),
                0,
            ).isNotEmpty()
}
