package org.alhikmeh.nots

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nots/app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
