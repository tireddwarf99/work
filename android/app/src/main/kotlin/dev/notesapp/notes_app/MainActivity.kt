package dev.notesapp.notes_app

import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Приём системного «Поделиться» (§8) и защищённое хранилище токенов (§9):
 * EncryptedSharedPreferences поверх Android Keystore.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val SHARE_CHANNEL = "dev.notesapp.notes/share"
        private const val SECURE_CHANNEL = "dev.notesapp.notes/secure"

        @JvmStatic
        var pendingSharedText: String? = null

        @JvmStatic
        private var shareChannel: MethodChannel? = null

        @JvmStatic
        private var securePrefs: SharedPreferences? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CHANNEL
        )
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingSharedText" -> {
                    result.success(pendingSharedText)
                    pendingSharedText = null
                }
                else -> result.notImplemented()
            }
        }

        val secureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_CHANNEL
        )
        secureChannel.setMethodCallHandler { call, result ->
            val args = call.arguments<Map<*, *>>()
            when (call.method) {
                "get" -> {
                    val key = args?.get("key") as? String
                    result.success(securePrefs().getString(key, null))
                }
                "put" -> {
                    val key = args?.get("key") as? String
                    val value = args?.get("value") as? String
                    if (key != null && value != null) {
                        securePrefs().edit().putString(key, value).apply()
                    }
                    result.success(null)
                }
                "remove" -> {
                    val key = args?.get("key") as? String
                    if (key != null) {
                        securePrefs().edit().remove(key).apply()
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun securePrefs(): SharedPreferences {
        val existing = securePrefs
        if (existing != null) return existing
        val masterKey = MasterKey.Builder(this)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        val prefs = EncryptedSharedPreferences.create(
            this,
            "notes_secure",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
        securePrefs = prefs
        return prefs
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleSendIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleSendIntent(intent)
    }

    private fun handleSendIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action != Intent.ACTION_SEND) return
        if (intent.type != "text/plain") return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
        pendingSharedText = text
        shareChannel?.invokeMethod("sharedText", text)
    }
}
