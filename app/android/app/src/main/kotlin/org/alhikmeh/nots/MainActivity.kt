package org.alhikmeh.nots

import android.content.Intent
import android.content.pm.PackageManager
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
