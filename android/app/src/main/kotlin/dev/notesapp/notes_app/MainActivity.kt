package dev.notesapp.notes_app

import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore

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

        private const val SECURE_PREFS_NAME = "notes_secure"

        @JvmStatic
        private var securePrefs: SharedPreferences? = null

        /** Причина пересоздания хранилища; отдаётся Dart при ближайшем get. */
        @JvmStatic
        private var secureStorageResetReason: String? = null
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
            try {
                when (call.method) {
                    "get" -> {
                        val key = args?.get("key") as? String
                        val prefs = securePrefs()
                        val recovered = secureStorageResetReason
                        if (recovered != null) {
                            // Хранилище было пересоздано: токены потеряны,
                            // пользователю нужно войти заново. Сообщаем
                            // Dart об этом один раз, а не молча отдаём null.
                            secureStorageResetReason = null
                            result.error("SECURE_STORAGE_RESET", recovered, null)
                        } else {
                            result.success(prefs.getString(key, null))
                        }
                    }
                    "put" -> {
                        val key = args?.get("key") as? String
                        val value = args?.get("value") as? String
                        if (key == null || value == null) {
                            result.error("BAD_ARGS", "key/value required", null)
                        } else {
                            if (!securePrefs().edit().putString(key, value).commit()) {
                                result.error("WRITE_FAILED", "commit failed", null)
                            } else {
                                // Новая запись в пересозданном хранилище:
                                // сообщать о сбросе больше незачем.
                                secureStorageResetReason = null
                                result.success(null)
                            }
                        }
                    }
                    "remove" -> {
                        val key = args?.get("key") as? String
                        if (key != null) {
                            securePrefs().edit().remove(key).commit()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: GeneralSecurityException) {
                result.error("SECURE_STORAGE_ERROR", e.javaClass.simpleName, null)
            } catch (e: IOException) {
                result.error("SECURE_STORAGE_ERROR", e.javaClass.simpleName, null)
            }
        }
    }

    private fun createSecurePrefs(): SharedPreferences {
        val masterKey = MasterKey.Builder(this)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            this,
            SECURE_PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    /**
     * Keystore-ключ может быть инвалидирован (смена блокировки экрана,
     * восстановление из бэкапа): тогда файл настроек нечитаем
     * (GeneralSecurityException / AEADBadTagException). Удаляем файл и
     * мастер-ключ и создаём хранилище заново — пользователю придётся
     * войти снова, что корректно: токены не расшифровать.
     */
    private fun securePrefs(): SharedPreferences {
        val existing = securePrefs
        if (existing != null) return existing
        val prefs = try {
            createSecurePrefs()
        } catch (e: GeneralSecurityException) {
            resetSecureStorage(e)
            createSecurePrefs()
        } catch (e: IOException) {
            resetSecureStorage(e)
            createSecurePrefs()
        }
        securePrefs = prefs
        return prefs
    }

    private fun resetSecureStorage(cause: Exception) {
        Log.w("SecureStore", "secure storage reset: ${cause.javaClass.simpleName}")
        File(applicationInfo.dataDir, "shared_prefs/$SECURE_PREFS_NAME.xml").delete()
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        keyStore.deleteEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS)
        secureStorageResetReason = "secure storage reset: ${cause.javaClass.simpleName}"
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
